# FORGEFALL — scripts/enemies/enemy_base.gd
# Worker 4 (enemy AI + waves).
#
# Shared base class for all voxel militia enemies. Subclasses (Grunt, Rusher,
# Marksman, Brute) implement `_configure()` (stats) and `_ai_physics(delta)`
# (state machine). This base handles: health/take_damage (headshot x2 applied
# HERE), hit flash, flinch + knockback, death (voxel debris + collapse + pool
# recycle), perception (cached LOS raycast), nav-or-steer locomotion,
# separation, hitscan firing with pooled tracers.
#
# v0.5.9 take_damage INTERCEPTION: take_damage() runs this enemy's
# take_damage hooks (mod_hooks, [] by default) then resolves the
# defensive states (shield / vulnerable / thorns / petrified) via
# ModStatusEffects.resolve_incoming_damage() BEFORE damage lands —
# same choke point as the player. fire_hitscan passes self as the
# attacker so the player's thorns reflects to the shooter.
#
# ENEMIES REWORK (2026-10-16): unified attack telegraph
# (begin_telegraph / is_winding_up / telegraph_progress) — every
# attack in every subclass announces its wind-up through this one
# channel, and VoxelSoldier.animate_full renders it (pose + lamp).
# Shared melee resolution (melee_hit / melee_blast) so slash, bash
# and slam all use the same frontal-arc / falloff rules. Behaviour
# tags (behaviour_tags) describe each type's real AI for verifiers.
# Spawn / damage / D&D interfaces are UNCHANGED.
#
# Collision-layer contract (coordinate with worker 1 project.godot):
#   layer 1 = world geometry, layer 2 = enemies, layer 3 = player.
# Enemies collide physically ONLY with the world (mask 1). Enemy-enemy
# separation is manual, enemy-player contact never blocks (damage is hitscan).
#
# Headshots: the head Area3D (+ its CollisionShape3D) lives in group
# "enemy_head". The WEAPON worker must raycast with collide_with_areas=true
# and treat a hit whose collider is_in_group("enemy_head") as a headshot,
# then call take_damage(amount, hit_pos, true). Body hits: collider is the
# CharacterBody3D itself (group "enemy") -> take_damage(amount, pos, false).
#
# Navigation: each enemy owns a NavigationAgent3D. If the map provides a baked
# navmesh (WaveManager.detect_nav, re-checked every wave), agents steer along
# paths; otherwise they fall back to direct steering with a cheap forward
# obstacle probe. See report for the bake-API verification notes.

class_name EnemyBase
extends CharacterBody3D

#region TUNABLES
const HEADSHOT_MULT := 2.0        # damage multiplier applied here when is_headshot
const FLINCH_TIME := 0.25        # seconds of stagger on non-lethal hit (legacy default; scaling below wins)
const FLINCH_KNOCKBACK := 3.5    # impulse applied away from the hit (legacy default; scaling below wins)
# Goal 1 FEEL — damage-scaled hit reactions. Light hits = brief twitch,
# heavy hits = long stagger + real shove. Headshots hit harder.
const FLINCH_BASE := 0.16         # flinch floor (s) for any damaging hit
const FLINCH_PER_DAMAGE := 0.0016 # +s of flinch per point of effective damage
const FLINCH_MAX := 0.50          # flinch ceiling (s)
const FLINCH_HEADSHOT_MULT := 1.25
const KB_BASE := 2.0              # knockback floor (impulse)
const KB_PER_DAMAGE := 0.055      # +impulse per point of effective damage
const KB_MAX := 10.0              # knockback ceiling (impulse)
const KB_HEADSHOT_MULT := 1.30
const KB_MASS_MIN := 0.40         # heavy enemies (high base_hp) resist shove
const KB_MASS_MAX := 1.35         # light enemies (low base_hp) fly further
const KB_BURST_DIMINISH := 0.55   # each recent hit within the window shrinks the next shove
const KB_WINDOW_DECAY := 6.0      # recent-hit counter decay (per second)
const FLASH_BASE := 0.06          # hit-flash floor (s)
const FLASH_PER_DAMAGE := 0.0005  # +s of flash per point of effective damage
const FLASH_MAX := 0.14           # hit-flash ceiling (s)
const SIGHT_RANGE := 48.0        # metres
const SIGHT_HALF_ANGLE_COS := 0.35  # cos(half-angle); 0.35 ~= 69 deg half cone
const HEAR_RADIUS := 20.0
const SEPARATION_RADIUS := 1.7    # push apart when closer than this
const SEPARATION_FORCE := 7.0
const GRAVITY := 22.0
const EYE_HEIGHT := 1.62
const NAV_RETARGET_INTERVAL := 0.35  # seconds between path retargets
const PERCEPTION_INTERVAL := 0.2     # LOS raycast cadence (staggered)
const FLASH_TIME := 0.09      # legacy default; live flash is flash_time_for() (Goal 1 scaling)
const SPAWN_TELEGRAPH_TIME := 0.5  # visible glow + sound before the enemy can act
const BRUTE_STEP_DISTANCE := 3.0  # metres of brute travel per heavy footstep
const TELEGRAPH_GLOW_SIZE := Vector3(1.1, 2.6, 1.1)
const DEATH_TIP_TIME := 0.3      # tip-over duration before sinking
const DEATH_SINK_TIME := 0.55
const ENEMY_LAYER := 4           # collision_layer value 4 (layer 3): player=2, world=1
const WORLD_MASK := 1            # collide physically with world only
const LOS_MASK := 3              # world (1) + player (2) for sight/fire rays
#endregion

# Live-enemy registry for cheap separation steering (pooled bodies stay listed).
static var all: Array[EnemyBase] = []

# --- stats (set by subclass _configure, scaled by wave at activate()) ---
var type_id := "grunt"
var display_name := "Militia Grunt"
# v0.5.8 D&D: creature type + ability scores. creature_type is the 5e
# type tag (default "humanoid" — every existing enemy is militia).
# base_creature_type is the _configure() value; Forge spawn-by-type
# overrides creature_type per-spawn (activate() applies the override,
# _recycle() restores the base). ability_scores is the stat block
# (DnDTypes); the class system (Worker B) reads/writes it.
var creature_type := "humanoid"
var base_creature_type := "humanoid"
var ability_scores := DnDTypes.default_ability_scores()
# Last typed-damage call, for verifiers / info display.
var last_damage_type := ""
var last_damage_multiplier := 1.0
var base_hp := 100.0
var base_speed := 4.0
var base_damage := 10.0
var base_accuracy := 0.5        # 0..1, maps to hitscan spread
var preferred_range := 15.0
var flinch_immune := false
var body_radius := 0.34
var body_height := 1.7
var body_scale := Vector3.ONE

# --- runtime state ---
var active := false             # false = parked in the wave-manager pool
var dead := false
var max_hp := 100.0
var hp := 100.0
var speed := 4.0
var damage := 10.0
var accuracy := 0.5
var wave_number := 1
var headshot_last := false
var director_mods: Dictionary = {}
var use_nav := false

# Locomotion intents, written by the subclass state machine every physics tick.
var wish_dir := Vector3.ZERO   # desired horizontal direction (may be zero)
var wish_speed := 0.0           # 0 = use `speed`
var face_target := Vector3.ZERO # world point to face; ZERO = keep heading
var aiming := false             # drives the soldier's aim pose

# Perception cache (refreshed on PERCEPTION_INTERVAL, not every frame).
var last_seen_pos := Vector3.ZERO
var last_seen_age := 999.0

# Burst-fire helper state.
var gun_burst_left := 0
var gun_burst_t := 0.0

var soldier: VoxelSoldier
var rig: Dictionary = {}
var nav_agent: NavigationAgent3D
## take_damage hooks attached to THIS enemy (v0.5.9). [] by default —
## enemies carry no mod weapons, so no hooks run unless a flow sets
## this (tests, future Forge enemy-mod attach). The take_damage hook
## point runs in take_damage() below; defensive STATES
## (shield/vulnerable/thorns/petrified) apply regardless of hooks —
## they are resolved from ModStatusEffects for every hit.
var mod_hooks: Array = []

var _player: Node3D = null
var _can_see := false
var _percep_t := 0.0
var _flinch := 0.0
var _kb_hits := 0.0           # Goal 1: recent hits in the knockback window (burst diminish)
var last_hit_damage := 0.0    # Goal 1: effective damage of the most recent hit (verifier-readable)
var last_hit_flinch := 0.0    # Goal 1: flinch duration the most recent hit applied
var _flash := 0.0
var _nav_retarget := 0.0
var _death_t := 0.0
var _separation := Vector3.ZERO
var _flash_mat: StandardMaterial3D
var _meshes: Array[MeshInstance3D] = []
var _spawn_pop_t := 0.0
var _death_tween: Tween = null
# Spawn telegraph (C1): glowing column + sound for SPAWN_TELEGRAPH_TIME
# after activate(). Enemy cannot move, aim, or fire while telegraphing.
var _telegraph_t := 0.0
# --- rework: unified ATTACK telegraph (distinct from the spawn telegraph
# above) + procedural-animation drivers, written by subclasses / take_damage.
# Subclasses call begin_telegraph() when an attack starts winding up;
# _physics_process decays it; the soldier renders telegraph_progress().
var attack_telegraph_t := 0.0
var attack_telegraph_total := 0.0
var attack_telegraph_kind := ""
var anim_strike := 0.0   # 1.0 on the strike frame, decays over ~0.25s
var anim_flinch := 0.0   # 1.0 on a damaging hit, decays over ~0.2s
var anim_crouch := 0.0   # 1.0 while crouched (marksman aim)
var anim_strafe := 0.0   # -1..1 lateral velocity vs facing (computed per tick)
var aim_offset := Vector3.ZERO  # added to fire_hitscan's aim point (suppressor sweep)
var _brute_step_accum := 0.0  # Goal 2: distance accumulator for brute footsteps
var _telegraph_glow: MeshInstance3D
var _telegraph_mat: StandardMaterial3D


func is_spawn_telegraphing() -> bool:
	return _telegraph_t > 0.0


func can_attack() -> bool:
	return active and not dead and _telegraph_t <= 0.0


# --- rework: unified attack telegraph + shared melee ---------------------
## Start an attack wind-up of `duration` seconds. The soldier renders
## telegraph_progress() as pose + lamp; is_winding_up() is the
## verifier / AI read-out. duration <= 0 clears the telegraph.
func begin_telegraph(duration: float, kind: String) -> void:
	if duration <= 0.0:
		attack_telegraph_t = 0.0
		attack_telegraph_total = 0.0
		attack_telegraph_kind = ""
		return
	attack_telegraph_t = duration
	attack_telegraph_total = duration
	attack_telegraph_kind = kind


func is_winding_up() -> bool:
	return attack_telegraph_t > 0.0


## 0..1 elapsed fraction of the current wind-up (0 when none).
func telegraph_progress() -> float:
	if attack_telegraph_total <= 0.0:
		return 0.0
	return clampf(1.0 - attack_telegraph_t / attack_telegraph_total, 0.0, 1.0)


## Call on the strike frame: drives the soldier's chop / lunge pose.
func trigger_strike() -> void:
	anim_strike = 1.0


## Behaviour tags describing this type's real AI (overridden per type).
## Used by verifiers to prove the types do NOT all just run at the
## player. The base default is honest: no subclass may return it.
func behaviour_tags() -> Array:
	return ["run_at_player"]


## Frontal-arc melee hit (shredder slash, bulwark bash): connects only
## when the player is within `arc_range` AND inside the frontal cone
## (`arc_dot` = min forward dot). Misses play the whiff sound.
## Returns true on a connecting hit. Damage scales with director_mods.
func melee_hit(arc_range: float, arc_dot: float, dmg: float) -> bool:
	var p := _player_node()
	if p == null or not p.has_method("take_damage"):
		return false
	var to_p: Vector3 = p.global_position - global_position
	to_p.y = 0.0
	var dist := to_p.length()
	if dist > arc_range:
		Sfx.play_3d("slide_whoosh", global_position, -2.0)
		return false
	var fwd := -global_transform.basis.z
	if dist > 0.01 and fwd.dot(to_p.normalized()) < arc_dot:
		Sfx.play_3d("slide_whoosh", global_position, -2.0)
		return false
	p.take_damage(dmg * float(director_mods.get("dmg_mult", 1.0)),
		global_position + fwd * 1.5, false)
	Sfx.play_3d("impact_flesh", global_position)
	return true


## Radial melee blast (brute slam): damage falls off linearly to ZERO
## at the edge — sprinting out during the wind-up avoids it entirely.
## No facing requirement (it is a ground shockwave, not a swing).
func melee_blast(radius: float, max_dmg: float) -> void:
	trigger_strike()
	if ClassDB.class_exists("DebrisPool"):
		DebrisPool.burst(global_position + Vector3(0, 0.3, 0),
			_debris_colors(), 16, 5.0)
	Sfx.play_3d("impact_flesh", global_position)
	var p := _player_node()
	if p == null or not p.has_method("take_damage"):
		return
	var d: float = p.global_position.distance_to(global_position)
	if d < radius:
		var fall := 1.0 - d / radius
		p.take_damage(max_dmg * fall * float(director_mods.get("dmg_mult", 1.0)),
			global_position, false)


func _telegraph_color() -> Color:
	match type_id:
		"rusher":
			return Color(1.0, 0.35, 0.1)   # hot orange: fast threat coming
		"marksman":
			return Color(0.4, 0.85, 1.0)   # cyan: long-range threat
		"brute":
			return Color(1.0, 0.15, 0.15)   # red: juggernaut
		"shredder":
			return Color(1.0, 0.2, 0.6)    # magenta: fast melee threat
		"suppressor":
			return Color(0.7, 0.3, 1.0)    # violet: long-range suppression
		"bulwark":
			return Color(0.4, 1.0, 0.3)    # lime: shielded wall
		"warlord":
			return Color(1.0, 0.85, 0.1)   # gold: BOSS
		_:
			return Color(1.0, 0.75, 0.2)   # amber: grunt


func _ready() -> void:
	_configure()
	# v0.5.8 D&D: capture the _configure() creature type as the base
	# (spawn-by-type overrides are per-spawn, never sticky) and make
	# sure the stat block is complete even if a subclass set it partial.
	base_creature_type = creature_type if DnDTypes.is_creature_type(creature_type) else "humanoid"
	creature_type = base_creature_type
	ability_scores = DnDTypes.normalize_ability_scores(ability_scores)
	_build_body()
	add_to_group("enemy")
	EnemyBase.all.append(self)
	# Park in pool until WaveManager.activate().
	visible = false
	active = false
	set_physics_process(false)
	position = Vector3(0, -60, 0)


# --- subclass hooks -------------------------------------------------------
func _configure() -> void:
	pass


func _on_activated() -> void:
	pass


func _ai_physics(_delta: float) -> void:
	pass


func _on_damaged() -> void:
	pass


func _debris_colors() -> Array:
	return [Color(0.35, 0.42, 0.24), Color(0.23, 0.25, 0.27), Color(0.76, 0.66, 0.47)]


# --- construction ---------------------------------------------------------
func _build_body() -> void:
	collision_layer = ENEMY_LAYER
	collision_mask = WORLD_MASK
	floor_snap_length = 0.4

	var col := CollisionShape3D.new()
	col.name = "Body"
	var cap := CapsuleShape3D.new()
	cap.radius = body_radius
	cap.height = body_height
	col.shape = cap
	col.position = Vector3(0, body_height * 0.5, 0)
	add_child(col)

	nav_agent = NavigationAgent3D.new()
	nav_agent.name = "NavAgent"
	nav_agent.max_speed = base_speed
	nav_agent.path_desired_distance = 0.6
	nav_agent.target_desired_distance = 0.8
	nav_agent.navigation_layers = 1
	add_child(nav_agent)

	soldier = VoxelSoldier.new()
	soldier.name = "Soldier"
	soldier.scale = body_scale
	add_child(soldier)
	rig = soldier.build(type_id)

	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.albedo_color = Color(1, 1, 1)
	for n in soldier.find_children("*", "MeshInstance3D", true, false):
		_meshes.append(n as MeshInstance3D)
	# Spawn-telegraph glow: unshaded pulsing column, shown at activate().
	_telegraph_mat = StandardMaterial3D.new()
	_telegraph_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_telegraph_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_telegraph_mat.albedo_color = Color(1, 0.75, 0.2, 0.6)
	_telegraph_glow = MeshInstance3D.new()
	_telegraph_glow.name = "SpawnTelegraph"
	var glow_mesh := BoxMesh.new()
	glow_mesh.size = TELEGRAPH_GLOW_SIZE
	_telegraph_glow.mesh = glow_mesh
	_telegraph_glow.material_override = _telegraph_mat
	_telegraph_glow.position = Vector3(0, body_height * 0.55, 0)
	_telegraph_glow.visible = false
	add_child(_telegraph_glow)


# --- pooling --------------------------------------------------------------
func activate(spawn_pos: Vector3, wave: int, mods: Dictionary) -> void:
	wave_number = wave
	director_mods = mods
	# v0.5.8 D&D: Forge spawn-by-type override (mods["creature_type"])
	# applies for this spawn only; wave spawns reset to the base type.
	var override_type := str(mods.get("creature_type", ""))
	if not override_type.is_empty() and DnDTypes.is_creature_type(override_type):
		creature_type = override_type
	else:
		creature_type = base_creature_type
	max_hp = base_hp * (1.0 + 0.08 * float(wave - 1)) * float(mods.get("hp_mult", 1.0))
	hp = max_hp
	speed = base_speed * minf(1.0 + 0.02 * float(wave), 1.3) * float(mods.get("speed_mult", 1.0))
	damage = base_damage * (1.0 + 0.05 * float(wave - 1))
	accuracy = clampf(base_accuracy + 0.02 * float(wave - 1), 0.05, 0.95)
	dead = false
	headshot_last = false
	_flinch = 0.0
	attack_telegraph_t = 0.0
	attack_telegraph_total = 0.0
	attack_telegraph_kind = ""
	anim_strike = 0.0
	anim_flinch = 0.0
	anim_crouch = 0.0
	anim_strafe = 0.0
	aim_offset = Vector3.ZERO
	soldier.reset_pose()
	_kb_hits = 0.0
	last_hit_damage = 0.0
	last_hit_flinch = 0.0
	_flash = 0.0
	_death_t = 0.0
	_brute_step_accum = 0.0
	_nav_retarget = 0.0
	_percep_t = randf() * PERCEPTION_INTERVAL
	_can_see = false
	last_seen_age = 999.0
	_player = null
	velocity = Vector3.ZERO
	wish_dir = Vector3.ZERO
	wish_speed = 0.0
	face_target = Vector3.ZERO
	aiming = false
	gun_burst_left = 0
	collision_layer = ENEMY_LAYER
	collision_mask = WORLD_MASK
	global_position = spawn_pos
	rotation = Vector3(0, randf() * TAU, 0)
	soldier.rotation = Vector3.ZERO
	soldier.reset_pose()
	soldier.scale = Vector3.ONE * 0.01  # spawn pop-in
	_spawn_pop_t = 0.0
	visible = true
	active = true
	use_nav = WaveManager.nav_available
	# Spawn telegraph: glow + sound, enemy cannot act until it expires.
	_telegraph_t = SPAWN_TELEGRAPH_TIME
	if _telegraph_glow != null and is_instance_valid(_telegraph_glow):
		_telegraph_mat.albedo_color = _telegraph_color()
		_telegraph_glow.visible = true
		_telegraph_glow.transparency = 0.25
	if type_id == "brute":
		Sfx.play_3d("juggernaut_horn", spawn_pos)
	else:
		# Goal 2: distinct spawn telegraph — a rising chirp that says
		# "enemy incoming" without borrowing the portal sound.
		Sfx.play_3d("spawn_telegraph", spawn_pos, -4.0)
	set_physics_process(true)
	_on_activated()


func _recycle() -> void:
	if _death_tween != null and _death_tween.is_valid():
		_death_tween.kill()
	_death_tween = null
	# v0.5.8 D&D: a recycled body is a fresh body — the spawn-by-type
	# override never sticks to the pooled instance.
	creature_type = base_creature_type
	last_damage_type = ""
	last_damage_multiplier = 1.0
	_telegraph_t = 0.0
	attack_telegraph_t = 0.0
	attack_telegraph_total = 0.0
	attack_telegraph_kind = ""
	anim_strike = 0.0
	anim_flinch = 0.0
	anim_crouch = 0.0
	anim_strafe = 0.0
	aim_offset = Vector3.ZERO
	soldier.reset_pose()
	if _telegraph_glow != null and is_instance_valid(_telegraph_glow):
		_telegraph_glow.visible = false
	active = false
	dead = false
	visible = false
	set_physics_process(false)
	position = Vector3(0, -60, 0)
	rotation = Vector3.ZERO
	soldier.rotation = Vector3.ZERO


# --- damage ---------------------------------------------------------------
## Goal 1 FEEL — damage-scaled hit reactions (pure functions, verifier-friendly).
static func flinch_time_for(effective_damage: float, is_headshot: bool) -> float:
	var t := FLINCH_BASE + effective_damage * FLINCH_PER_DAMAGE
	if is_headshot:
		t *= FLINCH_HEADSHOT_MULT
	return clampf(t, FLINCH_BASE, FLINCH_MAX)


static func knockback_for(effective_damage: float, base_hp_value: float, is_headshot: bool, recent_hits: float) -> float:
	var kb := KB_BASE + effective_damage * KB_PER_DAMAGE
	# Mass: heavier base HP resists the shove (grunt = 1.0, rusher = 1.35, marksman = 1.25).
	kb *= clampf(100.0 / maxf(base_hp_value, 1.0), KB_MASS_MIN, KB_MASS_MAX)
	if is_headshot:
		kb *= KB_HEADSHOT_MULT
	# Burst diminish: a shotgun's 8 pellets shove hard once, not 8x.
	kb /= 1.0 + KB_BURST_DIMINISH * maxf(recent_hits, 0.0)
	return clampf(kb, 0.0, KB_MAX)


static func flash_time_for(effective_damage: float) -> float:
	return clampf(FLASH_BASE + effective_damage * FLASH_PER_DAMAGE, FLASH_BASE, FLASH_MAX)


func take_damage(amount: float, hit_position: Vector3, is_headshot: bool, attacker: Node = null) -> void:
	if dead or not active:
		return
	var mult := HEADSHOT_MULT if is_headshot else 1.0
	mult *= float(director_mods.get("taken_mult", 1.0))
	var effective := amount * mult
	# v0.5.9 take_damage INTERCEPTION (ONE hook point, no refactor):
	#   1. take_damage hooks on this enemy run first (they may apply
	#      shield/vulnerable/thorns/petrified to this enemy, or return
	#      damage_mult for THIS hit).
	#   2. ModStatusEffects.resolve_incoming_damage() applies the
	#      active defensive states (petrified nullifies, vulnerable
	#      multiplies, shield absorbs, thorns reflects).
	#   3. Only the final damage lands. A fully absorbed / nullified
	#      hit deals no damage: no HP loss, no flash, no flinch, no
	#      knockback.
	#   4. Thorns reflection (if any) is delivered to the attacker as
	#      a plain hit — it passes through the attacker's own
	#      defensive states but never reflects again (reflection guard).
	var reflected := 0.0
	var reflected_target: Node = null
	if effective > 0.0:
		if not mod_hooks.is_empty():
			var root: Node = null
			if is_inside_tree():
				var tree := get_tree()
				if tree != null:
					root = tree.current_scene
			var api := ModAPI.new(_player_node() as Node3D, root)
			var ctx := {"damage": effective, "target": self, "attacker": attacker,
				"hit_position": hit_position, "position": global_position,
				"headshot": is_headshot}
			var res := ModHookRegistry.run_take_damage(mod_hooks, api, ctx)
			effective *= float(res.get("damage_mult", 1.0))
		var resolved := ModStatusEffects.resolve_incoming_damage(self, effective, attacker)
		effective = float(resolved.get("final_damage", effective))
		reflected = float(resolved.get("reflected", 0.0))
		var rt: Variant = resolved.get("reflected_target", null)
		if rt is Node:
			reflected_target = rt as Node
	if effective <= 0.0:
		return
	hp -= effective
	headshot_last = is_headshot
	last_hit_damage = effective
	last_hit_flinch = 0.0
	_flash = flash_time_for(effective)
	for m in _meshes:
		m.material_override = _flash_mat
	if hp <= 0.0:
		# Thorns still reflects the killing blow's damage (it WAS
		# taken — hp went to/below 0), so reflect before dying.
		if reflected > 0.0 and reflected_target != null and is_instance_valid(reflected_target) \
				and reflected_target.has_method("take_damage"):
			ModStatusEffects.begin_reflection()
			reflected_target.call("take_damage", reflected, global_position, false)
			ModStatusEffects.end_reflection()
		die()
		return
	if not flinch_immune:
		# Flinch refreshes to the NEW hit's duration (never stacks longer
		# than the single hardest hit — no pellet stunlock).
		var fl := flinch_time_for(effective, is_headshot)
		_flinch = maxf(_flinch, fl)
		anim_flinch = 1.0  # rework: drives the soldier's hit-reaction pose
		last_hit_flinch = fl
		var kb_mag := knockback_for(effective, base_hp, is_headshot, _kb_hits)
		_kb_hits += 1.0
		var kb: Vector3 = global_position - hit_position
		kb.y = 0.0
		if kb.length_squared() > 0.001:
			velocity += kb.normalized() * kb_mag
	if reflected > 0.0 and reflected_target != null and is_instance_valid(reflected_target) \
			and reflected_target.has_method("take_damage"):
		ModStatusEffects.begin_reflection()
		reflected_target.call("take_damage", reflected, global_position, false)
		ModStatusEffects.end_reflection()
	_on_damaged()


# --- D&D 5e: creature type + ability scores (v0.5.8) ----------------------
## Sets the creature type (validated). False when `t` is not one of the
## 14 types — the current type is left untouched. This changes the LIVE
## type, not the base: _recycle() restores base_creature_type.
func set_creature_type(t: String) -> bool:
	if not DnDTypes.is_creature_type(t):
		return false
	creature_type = t
	return true


## Damage of a D&D damage type, with the creature-type table ENFORCED:
## immune = 0 damage (no flinch/flash/damage at all), resist = half,
## vulnerable = double. Unknown damage types and physical types
## (bludgeoning/piercing/slashing) pass through at 1.0x. Plain
## take_damage() stays UNTYPED — existing hitscan/explosion callers
## are unchanged. Callers with a known type (typed_damage hooks,
## future elemental weapons) MUST use this entry point.
## `attacker` forwards to take_damage (thorns reflection target).
func take_typed_damage(amount: float, damage_type: String, hit_position: Vector3, is_headshot: bool, attacker: Node = null) -> void:
	if dead or not active:
		return
	last_damage_type = str(damage_type).to_lower()
	last_damage_multiplier = DnDTypes.damage_multiplier(creature_type, last_damage_type)
	if last_damage_multiplier == 0.0:
		# Immune: the hit does nothing — no HP loss, no flinch, no
		# flash, no last_hit_damage. The immunity is observable:
		# last_damage_multiplier == 0.0 and hp unchanged.
		last_hit_damage = 0.0
		return
	take_damage(amount * last_damage_multiplier, hit_position, is_headshot, attacker)


## Game-code status-effect entry point, gated by creature-type
## condition immunity: returns false and applies NOTHING when the
## creature is immune to the condition the kind expresses (e.g.
## poison on a construct/undead, sleep on an undead, exhaustion on a
## construct). Mod hooks call ModStatusEffects directly (mod file,
## off-limits here) — those are caught by _sweep_immune_effects().
func apply_status_effect(kind: String, params: Dictionary, origin: Vector3) -> bool:
	if DnDTypes.is_status_immune(creature_type, kind):
		return false
	return ModStatusEffects.apply_status(self, kind, params, origin)


## Sweeps status effects this creature is immune to (arrived via a path
## that bypassed apply_status_effect, e.g. a mod hook). Runs every
## physics tick: DOT effects tick in 1.0s chunks and clear_status_effect
## does NOT flush partial accum, so a swept poison effect deals 0
## damage — the immunity is real, not cosmetic. Sleep/restrained/prone
## never get a frame to pin the creature in a way the player can see:
## the sweep runs before AI/locomotion each tick.
func _sweep_immune_effects() -> void:
	for eff in ModStatusEffects.active_effects(self):
		if eff is Dictionary and DnDTypes.is_status_immune(creature_type, str((eff as Dictionary).get("kind", ""))):
			ModStatusEffects.clear_status_effect(self, str((eff as Dictionary).get("kind", "")))


## Ability-score getter (Worker B's class system reads this).
func get_ability_score(ability: String) -> int:
	return DnDTypes.get_ability(ability_scores, ability)


## Ability-modifier getter (floor((score-10)/2)).
func get_ability_modifier(ability: String) -> int:
	return DnDTypes.get_ability_modifier(ability_scores, ability)


## Display name of this enemy's creature type ("Undead").
func creature_type_display() -> String:
	return DnDTypes.creature_display_name(creature_type)


## Enemy-info line: name + creature type + stat block + enforced
## immunities. HUD / Forge info panels read this (no HUD change here —
## the API is the deliverable; the HUD worker wires the display).
func info_string() -> String:
	var imm := DnDTypes.type_summary(creature_type)
	var lore := DnDTypes.unenforced_condition_immunities(creature_type)
	var lore_note := "" if lore.is_empty() else " (lore-only: immune to %s — no game mechanic)" % ", ".join(PackedStringArray(lore))
	return "%s — %s | %s | %s%s" % [display_name, creature_type_display(),
		DnDTypes.format_stat_block(ability_scores), imm, lore_note]


func is_flinching() -> bool:
	return _flinch > 0.0


func die() -> void:
	if dead:
		return
	dead = true
	collision_layer = 0
	collision_mask = 0
	aiming = false
	wish_dir = Vector3.ZERO
	if ClassDB.class_exists("DebrisPool"):
		var torso_pos: Vector3 = global_position + Vector3(0, 1.2 * body_scale.y, 0)
		DebrisPool.burst(torso_pos, _debris_colors(), 14, 4.5)
	Game.register_kill(headshot_last, display_name)
	if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("kill", {"headshot": headshot_last, "victim": display_name, "enemy_type": type_id})
	# Goal 2: death crumble — one-shot, once per enemy (die() is guarded
	# by the dead flag). A death event, not a hit: the HUD still solely
	# owns the hit tick, so this never doubles a hit sound.
	Sfx.play_3d("enemy_death", global_position, -4.0)
	# Death animation is code-driven in VoxelSoldier (knees buckle ->
	# tip face-down -> settle), advanced by _death_tick through
	# animate_full's death param; the sink is in _death_tick. No tween.
	var mgr := get_parent()
	if mgr != null and mgr.has_method("on_enemy_died"):
		mgr.call("on_enemy_died", self)


func _death_tick(delta: float) -> void:
	_death_t += delta
	if _death_t > DEATH_TIP_TIME:
		position.y -= (1.4 / DEATH_SINK_TIME) * delta
	if _death_t >= DEATH_TIP_TIME + DEATH_SINK_TIME:
		_recycle()


# --- perception -----------------------------------------------------------
func _player_node() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	var ps := get_tree().get_nodes_in_group("player")
	if not ps.is_empty():
		_player = ps[0] as Node3D
	return _player


func player_pos() -> Vector3:
	var p := _player_node()
	if p != null:
		return p.global_position
	return last_seen_pos


func dist_to_player() -> float:
	return global_position.distance_to(player_pos())


func can_see_player() -> bool:
	return _can_see


func player_audible() -> bool:
	return dist_to_player() < HEAR_RADIUS


func _perception_tick() -> void:
	_player_node()
	_can_see = _los_check()
	if _can_see:
		var p := _player_node()
		if p != null:
			last_seen_pos = p.global_position
		last_seen_age = 0.0
	else:
		last_seen_age += PERCEPTION_INTERVAL


func _eye_pos() -> Vector3:
	return global_position + Vector3(0, EYE_HEIGHT * body_scale.y, 0)


func _los_check() -> bool:
	var p := _player_node()
	if p == null:
		return false
	var target: Vector3 = p.global_position + Vector3(0, 1.2, 0)
	var to: Vector3 = target - _eye_pos()
	var dist := to.length()
	if dist > SIGHT_RANGE:
		return false
	if dist > 3.0:
		var fwd := -global_transform.basis.z
		if fwd.dot(to / dist) < SIGHT_HALF_ANGLE_COS:
			return false
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(_eye_pos(), target, LOS_MASK)
	var ex: Array[RID] = [get_rid()]
	query.exclude = ex
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return false
	var col: Object = hit.get("collider")
	return col is Node and (col as Node).is_in_group("player")


# --- locomotion ------------------------------------------------------------
func nav_direction_to(target: Vector3, delta: float) -> Vector3:
	"""Steer toward target: navmesh path when available, else direct + probe."""
	if use_nav and nav_agent != null:
		_nav_retarget -= delta
		if _nav_retarget <= 0.0:
			_nav_retarget = NAV_RETARGET_INTERVAL
			nav_agent.target_position = target
		if not nav_agent.is_target_reachable():
			return _direct_direction_to(target)
		# Docs: get_next_path_position() must be called every physics frame
		# to keep the agent's internal path logic updated.
		if not nav_agent.is_navigation_finished():
			var next: Vector3 = nav_agent.get_next_path_position()
			var d: Vector3 = next - global_position
			d.y = 0.0
			if d.length() > 0.12:
				return d.normalized()
		return Vector3.ZERO
	return _direct_direction_to(target)


func _direct_direction_to(target: Vector3) -> Vector3:
	var d: Vector3 = target - global_position
	d.y = 0.0
	if d.length() < 0.4:
		return Vector3.ZERO
	var dir := d.normalized()
	# Cheap obstacle probe: one short ray ahead; veer if blocked.
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0, 0.9, 0),
		global_position + Vector3(0, 0.9, 0) + dir * 1.4, WORLD_MASK)
	var ex: Array[RID] = [get_rid()]
	query.exclude = ex
	if not space.intersect_ray(query).is_empty():
		dir = dir.rotated(Vector3.UP, 0.9)  # veer right; alternate via sign flip
	return dir


func _compute_separation() -> void:
	var push := Vector3.ZERO
	for e in EnemyBase.all:
		if e == self or not is_instance_valid(e):
			continue
		if not e.active or e.dead:
			continue
		var d: Vector3 = global_position - e.global_position
		d.y = 0.0
		var dist := d.length()
		if dist > 0.001 and dist < SEPARATION_RADIUS:
			push += d.normalized() * (1.0 - dist / SEPARATION_RADIUS)
	_separation = push * SEPARATION_FORCE


func _apply_locomotion(delta: float) -> void:
	var hv := Vector2(velocity.x, velocity.z)
	if _flinch > 0.0:
		# Let the knockback impulse decay naturally; AI is interrupted.
		hv = hv.move_toward(Vector2.ZERO, 14.0 * delta)
	else:
		var sp := wish_speed if wish_speed > 0.0 else speed
		# v0.5.5: mod status effects (slow / freeze) — the hook system
		# multiplies the speed the enemy actually moves at.
		sp *= ModStatusEffects.speed_multiplier(self)
		var target_v := Vector2(wish_dir.x, wish_dir.z) * sp
		target_v += Vector2(_separation.x, _separation.z)
		hv = hv.move_toward(target_v, 30.0 * delta)
	velocity.x = hv.x
	velocity.z = hv.y
	velocity.y -= GRAVITY * delta
	move_and_slide()
	if face_target != Vector3.ZERO:
		var d: Vector3 = face_target - global_position
		d.y = 0.0
		if d.length_squared() > 0.04:
			var target_yaw := atan2(-d.x, -d.z)
			rotation.y = lerp_angle(rotation.y, target_yaw, minf(1.0, 10.0 * delta))


# --- firing ---------------------------------------------------------------
func combat_spread(dist: float) -> float:
	"""Hitscan spread in degrees from accuracy + range falloff."""
	var s := lerpf(9.0, 1.6, accuracy)
	s += maxf(0.0, dist - preferred_range) * 0.08
	return s


func fire_hitscan(dmg: float, spread_deg: float, sound_id: String, tracer_color: Color) -> void:
	# Never fire during the spawn telegraph — deaths must feel fair.
	if _telegraph_t > 0.0:
		return
	var p := _player_node()
	if p == null:
		return
	var muzzle: Vector3 = global_position + Vector3(0, 1.4 * body_scale.y, 0)
	if rig.has("muzzle") and is_instance_valid(rig["muzzle"]):
		muzzle = (rig["muzzle"] as Node3D).global_position
	# aim_offset (suppressor sweep) shifts the aim point laterally.
	var aim_point: Vector3 = p.global_position + Vector3(0, 1.15, 0) + aim_offset
	var dir: Vector3 = (aim_point - muzzle).normalized()
	var sr := deg_to_rad(spread_deg)
	dir = dir.rotated(Vector3.UP, randf_range(-sr, sr))
	var right := dir.cross(Vector3.UP)
	if right.length_squared() > 0.0001:
		dir = dir.rotated(right.normalized(), randf_range(-sr, sr))
	var end: Vector3 = muzzle + dir * 90.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(muzzle, end, LOS_MASK)
	var ex: Array[RID] = [get_rid()]
	query.exclude = ex
	var hit := space.intersect_ray(query)
	var hit_pos := end
	if not hit.is_empty():
		hit_pos = hit["position"]
		var col: Object = hit.get("collider")
		if col is Node and (col as Node).is_in_group("player"):
			var pdmg := dmg * float(director_mods.get("dmg_mult", 1.0))
			if p.has_method("take_damage"):
				# Attacker = self: the player's thorns reflects to
				# THIS enemy, and take_damage hooks see the attacker.
				p.take_damage(pdmg, hit_pos, false, self)
	EnemyTracerPool.spawn(muzzle, hit_pos, tracer_color)
	Sfx.play_3d(sound_id, muzzle)


func gun_trigger(count: int) -> void:
	gun_burst_left = count
	gun_burst_t = 0.0


func gun_update(delta: float, dmg: float, spread_deg: float, sound_id: String, tracer_color: Color) -> void:
	if gun_burst_left <= 0:
		return
	gun_burst_t -= delta
	if gun_burst_t <= 0.0:
		gun_burst_t = 0.13
		gun_burst_left -= 1
		fire_hitscan(dmg, spread_deg, sound_id, tracer_color)


# --- main loop --------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if not active:
		return
	# Attack-telegraph / anim decays run FIRST: the spawn-telegraph
	# block below returns early, and a wind-up must still expire while
	# the enemy is spawn-telegraphing.
	if attack_telegraph_t > 0.0:
		attack_telegraph_t -= delta
	if anim_strike > 0.0:
		anim_strike = maxf(anim_strike - 4.0 * delta, 0.0)
	if anim_flinch > 0.0:
		anim_flinch = maxf(anim_flinch - 5.0 * delta, 0.0)
	if dead:
		_death_tick(delta)
		# Code-driven death crumple, driven by _death_t progress.
		if active and dead:
			var death_p := clampf(_death_t / (DEATH_TIP_TIME + DEATH_SINK_TIME), 0.0, 1.0)
			soldier.animate_full(delta, {"death": death_p})
		return
	# v0.5.8 D&D: sweep immunity-violating status effects before AI.
	_sweep_immune_effects()
	# Spawn telegraph: pulse the glow, stay frozen (no AI, no fire).
	# Gravity still settles the body via locomotion with zero wish.
	if _telegraph_t > 0.0:
		_telegraph_t -= delta
		if _telegraph_glow != null and is_instance_valid(_telegraph_glow):
			var pulse := 0.5 + 0.5 * sin(_telegraph_t * 28.0)
			_telegraph_glow.transparency = 0.15 + 0.45 * pulse
			_telegraph_glow.scale = Vector3.ONE * (0.85 + 0.25 * pulse)
			if _telegraph_t <= 0.0:
				_telegraph_glow.visible = false
		wish_dir = Vector3.ZERO
		wish_speed = 0.0
		aiming = false
		_apply_locomotion(delta)
		return
	# Spawn pop-in.
	if _spawn_pop_t < 0.35:
		_spawn_pop_t += delta
		var k := minf(1.0, _spawn_pop_t / 0.35)
		soldier.scale = body_scale * lerpf(0.01, 1.0, k)
	# Timers.
	if _flinch > 0.0:
		_flinch -= delta
	# Goal 1: knockback-window counter decays so the next burst shoves full again.
	if _kb_hits > 0.0:
		_kb_hits = maxf(_kb_hits - KB_WINDOW_DECAY * delta, 0.0)
	if _flash > 0.0:
		_flash -= delta
		if _flash <= 0.0:
			for m in _meshes:
				m.material_override = null
	_percep_t -= delta
	if _percep_t <= 0.0:
		_percep_t = PERCEPTION_INTERVAL + randf() * 0.05
		_perception_tick()
	_compute_separation()
	_ai_physics(delta)
	_apply_locomotion(delta)
	# Goal 2: brute footsteps — heavy thuds, distance-gated (every
	# BRUTE_STEP_DISTANCE metres, ~1.25 s at brute speed). Brute-only:
	# a footstep layer for all types would stack with up to 10 alive.
	if type_id == "brute" and _telegraph_t <= 0.0:
		_brute_step_accum += Vector2(velocity.x, velocity.z).length() * delta
		if _brute_step_accum >= BRUTE_STEP_DISTANCE:
			_brute_step_accum = 0.0
			Sfx.play_3d("footstep_brute", global_position, -5.0)
	var planar := Vector2(velocity.x, velocity.z).length()
	# Strafe lean: lateral velocity relative to facing, -1..1.
	anim_strafe = 0.0
	if planar > 0.5:
		var fwd := -global_transform.basis.z
		var right := fwd.cross(Vector3.UP)
		if right.length_squared() > 0.001:
			anim_strafe = clampf(velocity.dot(right.normalized()) / maxf(speed, 0.1), -1.0, 1.0)
	var windup := telegraph_progress() if is_winding_up() else 0.0
	soldier.animate_full(delta, {"speed": planar, "aiming": aiming,
		"windup": windup, "strike": anim_strike, "flinch": anim_flinch,
		"strafe": anim_strafe, "crouch": anim_crouch, "death": 0.0})
