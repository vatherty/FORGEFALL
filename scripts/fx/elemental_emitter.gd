# FORGEFALL — ElementalEmitter (v0.5.8 Worker C: elemental emitters)
# A persistent area emitter: voxel particles + ONE elemental damage type +
# radius + duration, enforced in-game. Enemies inside the radius take the
# element's damage/effect on every tick (0.5 s); the emitter frees itself
# when its duration expires.
#
# ELEMENTS (10) — the damage types an emitter can carry. Eight map onto
# ModStatusEffects typed_damage (instant damage + the type's rider, the
# same table the v0.5.7 effect expansion uses). Two have no typed_damage
# entry and are handled directly (documented, not silently renamed):
#   force -> direct damage + knockback (pure kinetic shove; there is no
#            "force" typed_damage kind, so the emitter deals damage
#            itself and applies the knockback status).
#   water -> small direct damage + slow + extinguishes burn + WET (see
#            below). Water is not a D&D damage type; it is a utility
#            element with real mechanics.
#
# WATER (exact behavior — nothing more, nothing less):
#   - deals its damage_per_sec as direct water damage (small by design);
#   - slows every enemy in the radius (slow x0.6, refreshed each tick);
#   - EXTINGUISHES burn on every enemy in the radius (clears the burn
#     status via ModStatusEffects.clear_status_effect — the cure
#     primitive). It does NOT clear poison, bleed, or any other DOT.
#   - marks every enemy in the radius WET for 4 s (node metadata
#     "elemental_wet_until"). Wet is visible only through lightning:
#   - CONDUCTIVITY: lightning damage against a WET target deals x1.5
#     damage and chains to the nearest other enemy within 3 m for 50%
#     damage. Lightning against a dry target is unchanged. Wet does
#     nothing else (no interaction with fire/cold/acid/...).
#
# SCOPE: emitters damage ENEMIES ONLY (nodes in the "enemy"/"enemies"
# groups with take_damage). They never hurt the player, turrets, or
# structures — same friendly-fire rule as the Forge turret. A dead
# target is skipped.
#
# INVOCATION (three paths, all real):
#   Forge structure:  target "emitter" spec {element, position, radius,
#     duration_sec, damage_per_sec} — a free-standing emitter pylon.
#   Forge turret:     turret params {"element": ...} — an elemental
#     turret ("a lightning emitter turret"): every shot deals its full
#     damage AS that element instead of plain damage.
#   Forge weapon:     weapon params {"element": ...} — elemental ammo:
#     every hitscan hit deals its full damage AS that element.
#   Mods:             ModAPI.spawn_elemental_emitter(...) (ModBlock
#     scripts AND hook scripts — it is in HOOK_ALLOWED_API_METHODS) and
#     ModAPI.fire_effect("elemental", ...) for a one-shot burst.
# Data-hook effects CANNOT spawn emitters (the effect-kinds table is
# untouched — the validator/loader is out of scope for this worker);
# a mod that wants an emitter uses a hook script or a ModBlock script.
#
# VISUALS (voxel, "Modern Voxfare 2"): a small voxel pylon (darkmetal
# base + emissive element-colored crystal cube) + a GPUParticles3D
# cloud of element-colored VOXEL CUBES (BoxMesh draw pass, not billboard
# quads) + a faint translucent sphere shell showing the radius + a
# point light in the element color. No per-tick allocations beyond the
# enemy scan; the particle system is created once in _ready.
extends Node3D
class_name ElementalEmitter

## All emitter elements.
const ELEMENTS := ["fire", "cold", "lightning", "acid", "poison", "radiant",
	"necrotic", "thunder", "force", "water"]
## Elements that map onto a ModStatusEffects typed_damage damage_type.
const TYPED_ELEMENTS := ["fire", "cold", "lightning", "acid", "poison",
	"radiant", "necrotic", "thunder"]
## Tick cadence (s) — damage/effects re-apply this often.
const TICK_SEC := 0.5
## How long water's WET mark lasts (s, wall clock via Time ticks).
const WET_SEC := 4.0
## Lightning damage multiplier against a WET target.
const LIGHTNING_WET_MULT := 1.5
## Lightning chain range from a wet target (m).
const CHAIN_RADIUS := 3.0
## Lightning chain damage as a fraction of the triggering hit.
const CHAIN_MULT := 0.5
## Node metadata key for the wet-until timestamp (seconds, Time ticks).
const META_WET := "elemental_wet_until"
## Water slow factor (refreshed every tick while inside).
const WATER_SLOW_FACTOR := 0.6
## Water slow duration applied per tick (s).
const WATER_SLOW_SEC := 1.5
## Force knockback force.
const FORCE_KNOCKBACK := 6.0
## Rider duration for typed_damage applications (s).
const TYPED_RIDER_SEC := 2.0

## Per-element table: particle/crystal color + D&D damage type ("" when
## the element has no typed_damage entry — force / water) + the
## one-line behavior the prompts quote.
const ELEMENT_INFO := {
	"fire": {"color": Color(1.0, 0.45, 0.1), "damage_type": "fire",
		"blurb": "fire damage + burn rider (damage over time)"},
	"cold": {"color": Color(0.5, 0.85, 1.0), "damage_type": "cold",
		"blurb": "cold damage + slow rider (x0.6 speed)"},
	"lightning": {"color": Color(1.0, 0.95, 0.4), "damage_type": "lightning",
		"blurb": "lightning damage + knockback rider; x1.5 + chain vs WET targets"},
	"acid": {"color": Color(0.55, 1.0, 0.2), "damage_type": "acid",
		"blurb": "acid damage + weaken rider (damage dealt x0.7)"},
	"poison": {"color": Color(0.6, 0.2, 0.9), "damage_type": "poison",
		"blurb": "poison damage + poison rider (damage over time + slow x0.85)"},
	"radiant": {"color": Color(1.0, 0.9, 0.55), "damage_type": "radiant",
		"blurb": "radiant damage + blind rider (accuracy x0.5)"},
	"necrotic": {"color": Color(0.35, 0.1, 0.5), "damage_type": "necrotic",
		"blurb": "necrotic damage + +1 exhaustion level per hit"},
	"thunder": {"color": Color(0.75, 0.85, 1.0), "damage_type": "thunder",
		"blurb": "thunder damage + heavy knockback + brief prone"},
	"force": {"color": Color(0.9, 0.7, 1.0), "damage_type": "",
		"blurb": "force damage (direct) + knockback — pure kinetic shove"},
	"water": {"color": Color(0.25, 0.6, 1.0), "damage_type": "",
		"blurb": "small water damage + slow x0.6 + EXTINGUISHES burn + marks WET (lightning conducts: x1.5 + chain)"},
}

var element := "fire"
var radius := 4.0
var duration_sec := 10.0
var damage_per_sec := 10.0

var _time_left := 0.0
var _tick_timer := 0.0
var _burst := false
var _particles: GPUParticles3D = null


## True when `s` names an emitter element.
static func is_element(s: String) -> bool:
	return str(s) in ELEMENTS


## One-line behavior blurb for an element ("" when unknown).
static func element_blurb(s: String) -> String:
	if not is_element(s):
		return ""
	return str((ELEMENT_INFO[str(s)] as Dictionary).get("blurb", ""))


## Emitter color for an element (white fallback for unknown).
static func element_color(s: String) -> Color:
	if not is_element(s):
		return Color.WHITE
	return (ELEMENT_INFO[str(s)] as Dictionary).get("color", Color.WHITE) as Color


## Runtime catalog text (one line per element). The two LLM prompts
## carry the same catalog as literal text (prompt constants cannot call
## functions) — keep them in sync with ELEMENT_INFO when editing.
static func catalog_text() -> String:
	var lines: Array[String] = []
	lines.append("ELEMENTAL EMITTERS — voxel particles + one elemental damage type + radius + duration. Emitters damage ENEMIES ONLY (never the player).")
	for e in ELEMENTS:
		lines.append("- %s: %s." % [e, element_blurb(e)])
	lines.append("WATER: small damage + slow x0.6 + EXTINGUISHES burn + marks WET 4s. Lightning vs WET: x1.5 damage + chains to the nearest other enemy within 3 m for 50%.")
	return "\n".join(lines)


## Spawns a persistent field emitter at `pos`. Returns the node, or
## null for an unknown element / null root. Clamps: radius 1-10,
## duration 3-60, damage_per_sec 1-100.
static func spawn_field(root: Node, p_element: String, pos: Vector3,
		p_radius: float, p_duration: float, p_dps: float) -> Node:
	if root == null or not is_element(p_element):
		return null
	var e := ElementalEmitter.new()
	e.element = p_element
	e.radius = clampf(p_radius, 1.0, 10.0)
	e.duration_sec = clampf(p_duration, 3.0, 60.0)
	e.damage_per_sec = clampf(p_dps, 1.0, 100.0)
	e.position = pos
	root.add_child(e)
	return e


## One-shot burst: applies `damage` of `element` ONCE to enemies in
## `radius` around `pos`, plus a short-lived voxel-particle pop.
## Returns the visual node (frees itself), or null.
static func spawn_burst(root: Node, p_element: String, pos: Vector3,
		p_radius: float, damage: float) -> Node:
	var e := spawn_visual_burst(root, p_element, pos, p_radius)
	if e == null:
		return null
	e._tick_burst(damage)
	return e


## Particles-only burst: the voxel-particle pop with NO damage.
## Turret / weapon elemental hits use this for the impact visual —
## the damage itself is applied separately via apply_to_target, so a
## damaging burst here would double-apply. Returns the visual node
## (frees itself), or null.
static func spawn_visual_burst(root: Node, p_element: String, pos: Vector3,
		p_radius: float) -> Node:
	if root == null or not is_element(p_element):
		return null
	var e := ElementalEmitter.new()
	e.element = p_element
	e.radius = clampf(p_radius, 1.0, 10.0)
	e.duration_sec = 0.8
	e.damage_per_sec = 0.0
	e._burst = true
	e.position = pos
	root.add_child(e)
	return e


## Applies ONE hit of `element` dealing `damage` to `target` — the
## single-hit path turrets and elemental weapons use. Typed elements
## go through typed_damage (instant damage + rider). Force = direct
## damage + knockback. Water = direct damage + slow + extinguish burn
## + wet. No-op for unknown elements / null / freed / dead targets.
## Returns true when something was applied.
static func apply_to_target(target: Node, p_element: String, damage: float, origin: Vector3) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not is_element(p_element):
		return false
	if _is_dead(target):
		return false
	var dmg := clampf(damage, 0.0, 1000.0)
	match p_element:
		"force":
			_damage_target(target, dmg)
			if _is_dead(target):
				return true
			ModStatusEffects.apply_status(target, "knockback", {"force": FORCE_KNOCKBACK}, origin)
			return true
		"water":
			_damage_target(target, dmg)
			if _is_dead(target):
				return true
			# Slow (refreshed by every emitter tick / weapon hit).
			ModStatusEffects.apply_status(target, "slow",
				{"factor": WATER_SLOW_FACTOR, "duration_sec": WATER_SLOW_SEC}, origin)
			# Extinguish: burn goes out. Poison / bleed / other DOTs
			# are NOT cleared — water puts out fire, not venom.
			ModStatusEffects.clear_status_effect(target, "burn")
			target.set_meta(META_WET, Time.get_ticks_msec() / 1000.0 + WET_SEC)
			return true
		_:
			# Typed elements: lightning conducts on wet targets.
			var amount := dmg
			if p_element == "lightning" and is_wet(target):
				amount = dmg * LIGHTNING_WET_MULT
			var dtype := str((ELEMENT_INFO[p_element] as Dictionary).get("damage_type", ""))
			if dtype.is_empty():
				return false
			return ModStatusEffects.apply_status(target, "typed_damage",
				{"damage_type": dtype, "amount": amount, "duration_sec": TYPED_RIDER_SEC}, origin)


## True when `target` is currently WET (water mark not yet expired).
static func is_wet(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not target.has_meta(META_WET):
		return false
	return Time.get_ticks_msec() / 1000.0 < float(target.get_meta(META_WET))


func _ready() -> void:
	_time_left = duration_sec
	_build_visuals()


func _process(delta: float) -> void:
	_time_left -= delta
	if _time_left <= 0.0:
		queue_free()
		return
	if _burst:
		return
	_tick_timer -= delta
	if _tick_timer <= 0.0:
		_tick_timer = TICK_SEC
		_tick_field()


## Field tick: every enemy in the radius takes damage_per_sec * TICK
## of the element. Lightning chains off wet targets.
func _tick_field() -> void:
	var foes := _foes_in_radius()
	for foe in foes:
		var at := (foe as Node3D).global_position if foe is Node3D else global_position
		var was_wet := is_wet(foe)
		apply_to_target(foe, element, damage_per_sec * TICK_SEC, global_position)
		# Lightning conductivity: a wet target chains to its nearest
		# other enemy within CHAIN_RADIUS for half damage.
		if element == "lightning" and was_wet and not _is_dead(foe):
			var nxt := _nearest_other_foe(foe, at, CHAIN_RADIUS)
			if nxt != null:
				apply_to_target(nxt, element, damage_per_sec * TICK_SEC * CHAIN_MULT, at)


## Burst tick: one immediate application at full `damage`.
func _tick_burst(damage: float) -> void:
	for foe in _foes_in_radius():
		apply_to_target(foe, element, damage, global_position)


## Enemies (groups "enemy"/"enemies") within radius of the emitter.
func _foes_in_radius() -> Array:
	var out: Array = []
	for e in _all_foes():
		if not (e is Node3D):
			continue
		if (e as Node3D).global_position.distance_to(global_position) > radius:
			continue
		if _is_dead(e):
			continue
		out.append(e)
	return out


## All enemies, regardless of distance (the lightning chain scans
## beyond the emitter radius — a wet target can arc to a foe standing
## just outside the field).
func _all_foes() -> Array:
	var out: Array = []
	var seen := {}
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return out
	for group in ["enemy", "enemies"]:
		for e in tree.get_nodes_in_group(group):
			if e == null or not is_instance_valid(e):
				continue
			var id := (e as Node).get_instance_id()
			if seen.has(id):
				continue
			seen[id] = true
			out.append(e)
	return out


## Nearest foe to `from` within `max_dist`, excluding `exclude`.
## Scans ALL enemies, not just in-radius ones (see _all_foes).
func _nearest_other_foe(exclude: Node, from: Vector3, max_dist: float) -> Node:
	var best: Node = null
	var best_d := max_dist
	for foe in _all_foes():
		if foe == exclude:
			continue
		if not (foe is Node3D):
			continue
		if _is_dead(foe):
			continue
		var d := (foe as Node3D).global_position.distance_to(from)
		if d < best_d:
			best_d = d
			best = foe
	return best


## Voxel pylon + voxel-particle cloud + radius shell + element light.
func _build_visuals() -> void:
	var col := element_color(element)
	# Pylon: darkmetal base + emissive element crystal (voxel cubes).
	var base := VoxelBuilder.cube(Vector3(0.5, 0.3, 0.5),
		VoxelBuilder.PALETTE["darkmetal"], Vector3(0, 0.15, 0))
	add_child(base)
	var crystal := MeshInstance3D.new()
	var cmesh := BoxMesh.new()
	cmesh.size = Vector3(0.3, 0.3, 0.3)
	crystal.mesh = cmesh
	var cmat := StandardMaterial3D.new()
	cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmat.albedo_color = col
	cmat.emission_enabled = true
	cmat.emission = col
	cmat.emission_energy_multiplier = 2.0
	crystal.material_override = cmat
	crystal.position = Vector3(0, 0.55, 0)
	add_child(crystal)
	# Radius shell: faint translucent sphere so the AoE is readable.
	var shell := MeshInstance3D.new()
	var smesh := SphereMesh.new()
	smesh.radius = radius
	smesh.height = radius * 2.0
	smesh.radial_segments = 16
	smesh.rings = 10
	shell.mesh = smesh
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	smat.albedo_color = Color(col, 0.06)
	shell.material_override = smat
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shell.position = Vector3(0, 0.4, 0)
	add_child(shell)
	# Voxel-particle cloud: GPUParticles3D with a BOX draw pass —
	# real voxel cubes, not billboard quads.
	var p := GPUParticles3D.new()
	p.amount = 48
	p.lifetime = 0.9
	p.preprocess = 0.5
	p.explosiveness = 0.0
	p.randomness = 0.6
	p.visibility_aabb = AABB(Vector3(-radius, -1, -radius),
		Vector3(radius * 2, radius * 2 + 2, radius * 2))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius * 0.8
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 60.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.0
	pm.gravity = Vector3(0, -0.5, 0)
	pm.damping_min = 0.5
	pm.damping_max = 1.0
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	pm.color = col
	p.process_material = pm
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.12, 0.12)
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.albedo_color = col
	bmat.emission_enabled = true
	bmat.emission = col
	bmat.emission_energy_multiplier = 1.5
	box.material = bmat
	p.draw_pass_1 = box
	p.position = Vector3(0, 0.4, 0)
	add_child(p)
	_particles = p
	p.emitting = true
	# Element light.
	var light := OmniLight3D.new()
	light.light_color = col
	light.light_energy = 1.2
	light.omni_range = radius + 2.0
	light.position = Vector3(0, 0.8, 0)
	add_child(light)


## Direct damage through take_damage (mirrors ModStatusEffects).
static func _damage_target(target: Node, amount: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if target.has_method("take_damage") and not _is_dead(target):
		var pos := Vector3.ZERO
		if target is Node3D:
			pos = (target as Node3D).global_position
		target.call("take_damage", amount, pos, false)


static func _is_dead(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return true
	if target.has_method("is_dead"):
		return bool(target.call("is_dead"))
	var dead_v: Variant = target.get("dead")
	if dead_v is bool:
		return dead_v
	var hp_v: Variant = target.get("hp")
	if hp_v is int or hp_v is float:
		return float(hp_v) <= 0.0
	return false
