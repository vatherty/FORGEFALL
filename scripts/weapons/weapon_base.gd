# FORGEFALL — WeaponBase
# MW2-style hitscan weapon core. Subclasses / data-driven instances provide
# stats (via Arsenal) and voxel viewmodels; this class owns the gunplay:
# fire modes (auto/semi/bolt/pump), RPM gating, hitscan with hip/ADS spread
# + movement penalty, linear damage falloff, headshots x2, per-weapon recoil
# patterns with recovery, staged reloads (mag_out -> mag_in -> chamber),
# muzzle flash (light + emissive quad, 40ms), pooled tracers, pooled shell
# eject, idle sway + walk bob (suppressed in ADS), raise/lower timing.
#
# Camera kick goes through player.add_look(relative). Contract (v0.1.5):
# add_look takes RADIANS — recoil_pattern values are already radians.
# +x = look right, +y = look down. Muzzle rise is therefore a NEGATIVE y.
# Recoil pattern entries are stored as Vector2(yaw_kick, pitch_up_kick) in
# "look-up is positive" space and converted at apply time.
class_name WeaponBase
extends Node3D

#region TUNABLES
const RECOIL_RECOVER_TIME := 0.20   # seconds to recover applied kick (fallback; per-weapon recoil_recover wins)
const RECOIL_SETTLE_DELAY := 0.045  # Goal 1: kick holds briefly before recovery starts, so it READS
const RECOIL_VM_KICK_Z := 0.55      # viewmodel backward kick per unit of pattern pitch
const RECOIL_VM_KICK_PITCH := 0.75  # viewmodel muzzle-rise rotation per unit of pattern pitch
const RECOIL_VM_DECAY := 11.0       # viewmodel kick spring-back rate (1/s)
const MUZZLE_FLASH_TIME := 0.04     # 40ms flash
const SHELL_POOL_SIZE := 10
const SHELL_LIFE := 1.4
const SHELL_GRAVITY := 9.8
const SWAY_AMOUNT := 0.010          # idle sway amplitude (radians-ish)
const SWAY_SPEED := 1.6
const BOB_AMOUNT := 0.022           # walk bob amplitude (meters)
const BOB_FREQ := 9.0
const ADS_SPREAD_MULT := 0.35
const ADS_RECOIL_MULT := 0.7
const ADS_SWAY_MULT := 0.25
const ADS_BOB_MULT := 0.20
const HIP_POS := Vector3(0.24, -0.20, -0.50)
const ADS_POS := Vector3(0.0, -0.148, -0.38)
const HIP_ROT := Vector3(0.0, -0.07, 0.0)
const ADS_ROT := Vector3.ZERO
const MAX_HITSCAN_RANGE := 400.0
const MOVE_SPREAD_REF_SPEED := 6.0  # speed (m/s) at which move penalty maxes
#endregion

enum FireMode { AUTO, SEMI, BOLT, PUMP, BURST }
enum _ReloadStage { NONE, MAG_OUT, MAG_IN, CHAMBER }

signal ammo_changed(mag: int, reserve: int)
signal fired

# --- Stats (filled by setup() from Arsenal.WEAPONS) ---
var weapon_id: String = ""
var display_name: String = "WEAPON"
var fire_mode: int = FireMode.AUTO
var burst_size: int = 3       # Goal 3: rounds per burst (BURST mode only)
var rpm: float = 600.0
var damage: float = 20.0
var headshot_mult: float = 2.0
var mag_size: int = 30
var mag: int = 30
var reserve: int = 120
var pellets: int = 1
var spread_hip: float = 0.030      # radians, cone half-angle-ish
var spread_move: float = 0.030    # added at full move speed
var near_range: float = 20.0      # full damage inside this
var far_range: float = 60.0       # min damage beyond this
var falloff_min: float = 0.5      # damage multiplier at far_range
var recoil_pattern: Array = []   # Array[Vector2(yaw, pitch_up)] radians
var recoil_recover_time: float = RECOIL_RECOVER_TIME # Goal 1: per-weapon recovery (Arsenal "recoil_recover")
var muzzle_flash_time: float = MUZZLE_FLASH_TIME    # Goal 1: per-weapon flash duration
var muzzle_flash_energy: float = 4.0                 # Goal 1: per-weapon flash brightness
var raise_time: float = 0.35
var lower_time: float = 0.25
var reload_stages: Array = [0.45, 0.85, 0.35] # mag_out, mag_in, chamber
var cycle_time: float = 0.0      # bolt/pump re-chamber lockout
var sfx_fire: String = "shot"

# --- Runtime state ---
var _player: Node = null
var _camera: Camera3D = null
var _viewmodel: Node3D = null
var _muzzle: Marker3D = null
var _eject: Marker3D = null
var _cooldown: float = 0.0
var _cycle_t: float = 0.0
var _cycle_sfx_done: bool = true
var _reload_stage: int = _ReloadStage.NONE
var _reload_t: float = 0.0
var _raise_t: float = 999.0
var _lowering: bool = false
var _ads_pos := ADS_POS # per-weapon ADS target; Y = -Arsenal.sight_height(id)
var _ads: bool = false
var _ads_blend: float = 0.0
var _shot_index: int = 0
var _burst_left: int = 0   # Goal 3: rounds remaining in the current burst
var _recoil_debt := Vector2.ZERO
var _recoil_settle_t := 0.0    # Goal 1: recovery holds while this runs
var _vm_kick_z := 0.0          # Goal 1: transient viewmodel backward kick (m)
var _vm_kick_pitch := 0.0      # Goal 1: transient viewmodel muzzle-rise (rad)
var _kick_mag := 0.0           # Goal 1: mean pattern pitch — scales the VM kick
var _sway_t: float = 0.0
var _bob_t: float = 0.0
var _dry_fired: bool = false
var _flash_t: float = 0.0
var _flash_light: OmniLight3D = null
var _flash_quad: MeshInstance3D = null
var _shells: Array = [] # {node, vel, life}


func setup(stats: Dictionary) -> void:
	weapon_id = str(stats.get("weapon_id", "unknown"))
	display_name = str(stats.get("name", "WEAPON"))
	fire_mode = int(stats.get("fire_mode", FireMode.AUTO))
	burst_size = int(stats.get("burst_size", 3))
	rpm = float(stats.get("rpm", 600.0))
	damage = float(stats.get("damage", 20.0))
	headshot_mult = float(stats.get("headshot_mult", 2.0))
	mag_size = int(stats.get("mag_size", 30))
	mag = mag_size
	reserve = int(stats.get("reserve", 120))
	pellets = int(stats.get("pellets", 1))
	spread_hip = float(stats.get("spread_hip", 0.030))
	spread_move = float(stats.get("spread_move", 0.030))
	near_range = float(stats.get("near_range", 20.0))
	far_range = float(stats.get("far_range", 60.0))
	falloff_min = float(stats.get("falloff_min", 0.5))
	recoil_pattern = (stats.get("recoil_pattern", []) as Array).duplicate()
	recoil_recover_time = float(stats.get("recoil_recover", RECOIL_RECOVER_TIME))
	muzzle_flash_time = float(stats.get("muzzle_flash_time", MUZZLE_FLASH_TIME))
	muzzle_flash_energy = float(stats.get("muzzle_flash_energy", 4.0))
	# Mean pattern pitch drives the viewmodel kick so each gun's visual
	# punch matches its camera kick (sniper thumps, SMG buzzes).
	_kick_mag = 0.0
	for k in recoil_pattern:
		_kick_mag += float((k as Vector2).y)
	if not recoil_pattern.is_empty():
		_kick_mag /= float(recoil_pattern.size())
	raise_time = float(stats.get("raise_time", 0.35))
	lower_time = float(stats.get("lower_time", 0.25))
	reload_stages = (stats.get("reload_stages", [0.45, 0.85, 0.35]) as Array).duplicate()
	cycle_time = float(stats.get("cycle_time", 0.0))
	sfx_fire = str(stats.get("sfx_fire", "shot"))
	# ADS target: shift the viewmodel so this weapon's sight line
	# (Arsenal.sight_height) lands exactly on the camera's -Z axis, i.e.
	# the sight sits centered on screen. Shared ADS_POS is the fallback.
	_ads_pos = Vector3(0.0, -Arsenal.sight_height(weapon_id), ADS_POS.z)
	_viewmodel = Arsenal.build_viewmodel(weapon_id)
	add_child(_viewmodel)
	_muzzle = _viewmodel.get_node_or_null("Muzzle") as Marker3D
	_eject = _viewmodel.get_node_or_null("Eject") as Marker3D
	_build_flash()
	_build_shell_pool()


func attach(p_player: Node, p_camera: Camera3D) -> void:
	_player = p_player
	_camera = p_camera


## Called by WeaponManager when this weapon becomes active.
func on_equip() -> void:
	_raise_t = 0.0
	_lowering = false
	_reload_stage = _ReloadStage.NONE
	if _viewmodel != null:
		if _viewmodel.get_parent() != null:
			_viewmodel.get_parent().remove_child(_viewmodel)
		if _camera != null:
			_camera.add_child(_viewmodel)
		else:
			add_child(_viewmodel)
		_viewmodel.position = HIP_POS
		_viewmodel.rotation = HIP_ROT
		# If we have no camera yet (first frames), stay hidden until the
		# manager re-equips us onto the real camera.
		_viewmodel.visible = _camera != null
	emit_ammo()


## Called by WeaponManager when switching away: park the viewmodel back on
## the weapon node and hide it so only the active gun renders.
func on_unequip() -> void:
	_lowering = false
	_burst_left = 0
	_reload_stage = _ReloadStage.NONE
	_ads = false
	_ads_blend = 0.0
	if _viewmodel != null:
		if _viewmodel.get_parent() != null:
			_viewmodel.get_parent().remove_child(_viewmodel)
		add_child(_viewmodel)
		_viewmodel.position = Vector3.ZERO
		_viewmodel.visible = false


## Called by WeaponManager before switching away.
func begin_lower() -> void:
	_lowering = true
	_reload_stage = _ReloadStage.NONE


func is_ready() -> bool:
	return (_raise_t >= raise_time and not _lowering
		and _reload_stage == _ReloadStage.NONE and _cycle_t <= 0.0)


func set_ads(active: bool) -> void:
	_ads = active


func emit_ammo() -> void:
	ammo_changed.emit(mag, reserve)


func add_reserve(n: int) -> void:
	reserve += n
	emit_ammo()


# --- Input (driven by WeaponManager) ---

func trigger_pressed() -> void:
	_dry_fired = false
	if fire_mode == FireMode.BURST:
		# Goal 3: queue one burst; rounds fire in _process as the RPM
		# cooldown clears. Re-pressing mid-burst does NOT restart it.
		if _burst_left <= 0:
			_burst_left = maxi(burst_size, 1)
	elif fire_mode != FireMode.AUTO:
		_attempt_fire()


func trigger_held() -> void:
	if fire_mode == FireMode.AUTO:
		_attempt_fire()


func trigger_released() -> void:
	_dry_fired = false


func try_reload() -> void:
	if _reload_stage != _ReloadStage.NONE:
		return
	if mag >= mag_size or reserve <= 0:
		return
	_reload_stage = _ReloadStage.MAG_OUT
	_reload_t = float(reload_stages[0])
	# Goal 2: ONE per-weapon reload file played once at reload start
	# (clicks sit at this weapon's stage boundaries). Previously all three
	# stages played the same 1.9 s reload_ar file, stacking 3x.
	Sfx.play_2d(_reload_sfx(), 0.0, _reload_pitch())


# --- Goal 2 (SOUND) helpers: fire / reload / impact sound selection ---
# No gameplay numbers here — these only pick which WAV plays.

## Fire sound: the LMG has its own shot_lmg file (arsenal.gd maps it too).
## Kept explicit here so the LMG never falls back to the AR sound.
func _fire_sfx() -> String:
	if weapon_id == "lmg":
		return "shot_lmg"
	return sfx_fire


## Reload sound: dedicated staged files for sniper/shotgun/LMG; AR's file
## pitched up for the shorter SMG/pistol reloads; AR as-is. Raptor never
## reaches here (its try_reload is overridden: drop only).
func _reload_sfx() -> String:
	match weapon_id:
		"lr8":
			return "reload_sniper"
		"sg12":
			return "reload_shotgun"
		"lmg":
			return "reload_lmg"
		"br3":
			return "reload_burst"
		"hv44":
			return "reload_revolver"
	return "reload_ar"


## Reload pitch: SMG/pistol reuse reload_ar pitched to their shorter
## reloads (SMG ~1.45 s, pistol ~1.30 s vs AR 1.65 s).
func _reload_pitch() -> float:
	match weapon_id:
		"smg9":
			return 1.1
		"p9":
			return 1.25
	return 1.0


## Impact sound by what the bullet hit. Group-based heuristic: enemies
## (flesh) > turret (metal) > cover (concrete) > name hints (dirt/metal)
## > default concrete (most of Dustline is concrete/rubble).
func _impact_sfx(collider: Object) -> String:
	var n := collider as Node
	if n != null:
		if n.is_in_group("enemy") or n.is_in_group("enemies") or n.is_in_group("enemy_head"):
			return "impact_flesh"
		if n.is_in_group("turret"):
			return "impact_metal"
		if n.is_in_group("cover"):
			return "impact_concrete"
		var lname := n.name.to_lower()
		if "dirt" in lname or "ground" in lname or "terrain" in lname or "sand" in lname:
			return "impact_dirt"
		if "metal" in lname or "barrel" in lname or "turret" in lname:
			return "impact_metal"
	return "impact_concrete"


# --- Core ---

## Goal 6 (Progression): report a stats event to the Stats autoload.
## No-op when the autoload isn't registered yet (coordinator wires it).
func _record_stat(type: String, data: Dictionary = {}) -> void:
	var stats: Node = get_node_or_null("/root/Stats")
	if stats != null and stats.has_method("record_event"):
		stats.call("record_event", type, data)


func _attempt_fire() -> void:
	if _lowering or _raise_t < raise_time:
		return
	if _reload_stage != _ReloadStage.NONE or _cycle_t > 0.0 or _cooldown > 0.0:
		return
	if mag <= 0:
		if not _dry_fired:
			_dry_fired = true
			Sfx.play_2d("dryfire")
		try_reload() # auto-reload prompt behavior
		return
	mag -= 1
	# Goal 6 (Progression): one shot per round fired (not per pellet).
	_record_stat("shot", {"weapon_id": weapon_id})
	_cooldown = 60.0 / maxf(rpm, 1.0)
	_fire_hitscan()
	_apply_recoil()
	_show_muzzle_flash()
	_eject_shell()
	Sfx.play_2d(_fire_sfx())
	fired.emit()
	emit_ammo()
	if cycle_time > 0.0:
		_cycle_t = cycle_time
		_cycle_sfx_done = false
	if mag <= 0:
		try_reload()


func _current_spread() -> float:
	var s := spread_hip
	if _ads:
		s *= ADS_SPREAD_MULT
	var speed := _player_speed()
	if speed > 0.5:
		s += spread_move * clampf(speed / MOVE_SPREAD_REF_SPEED, 0.0, 1.0)
	return s


func _player_speed() -> float:
	if _player == null or not is_instance_valid(_player):
		return 0.0
	var v: Variant = _player.get("velocity")
	if v is Vector3:
		return (v as Vector3).length()
	return 0.0


func _spread_dir(spread: float) -> Vector3:
	var basis_t: Basis = _camera.global_transform.basis
	var dir := -basis_t.z
	var a := randf() * TAU
	var r := spread * sqrt(randf())
	dir = (dir + basis_t.x * cos(a) * r + basis_t.y * sin(a) * r).normalized()
	return dir


func _fire_hitscan() -> void:
	if _camera == null:
		return
	var space := _camera.get_world_3d().direct_space_state
	var from: Vector3 = _camera.global_position
	var spread := _current_spread()
	var exclude: Array[RID] = []
	if _player is CollisionObject3D:
		exclude.append((_player as CollisionObject3D).get_rid())
	var muzzle_pos: Vector3 = _muzzle.global_position if _muzzle != null else from + _spread_dir(0.0) * 0.6
	# Goal 6: one hit per round that damaged at least one enemy (not per
	# pellet) so accuracy = rounds that hit / rounds fired.
	var hit_enemy_this_round := false
	for i in maxi(pellets, 1):
		var dir := _spread_dir(spread)
		var query := PhysicsRayQueryParameters3D.create(from, from + dir * MAX_HITSCAN_RANGE, 0xFFFFFFFF, exclude)
		var hit := space.intersect_ray(query)
		var hit_pos: Vector3 = hit.get("position", from + dir * MAX_HITSCAN_RANGE)
		TracerPool.spawn(muzzle_pos, hit_pos)
		# FX-only hook (no fire-logic change): dust puff where the bullet
		# lands. Misses (empty hit) get no puff.
		var collider: Object = hit.get("collider")
		var hit_enemy: bool = collider != null and collider.has_method("take_damage")
		if not hit.is_empty():
			ImpactFX.spawn(hit_pos, hit.get("normal", Vector3.UP))
			# Goal 2: bullet-impact sound by surface, under the gunfire
			# (mix table: impacts at -6 dB, voice-capped at 4).
			Sfx.play_3d(_impact_sfx(collider), hit_pos, -6.0)
			# Goal 1: heavy rounds (sniper) kick up a bigger impact cloud
			# on world surfaces. Enemy hits already get flash + flinch.
			if not hit_enemy and damage >= 60.0:
				ImpactFX.spawn_smoke(hit_pos, 0.7)
		if collider != null and collider.has_method("take_damage"):
			var dist := from.distance_to(hit_pos)
			var dmg := _falloff_damage(dist)
			var head := _is_headshot(collider)
			if head:
				dmg *= headshot_mult
			collider.take_damage(dmg, hit_pos, head)
			hit_enemy_this_round = true
			_notify_hit(collider, head)


	if hit_enemy_this_round:
		_record_stat("hit", {"weapon_id": weapon_id})


func _falloff_damage(dist: float) -> float:
	if dist <= near_range:
		return damage
	if dist >= far_range:
		return damage * falloff_min
	var t := (dist - near_range) / maxf(far_range - near_range, 0.001)
	return damage * lerpf(1.0, falloff_min, t)


func _is_headshot(collider: Object) -> bool:
	var n := collider as Node
	if n == null:
		return false
	if n.is_in_group("enemy_head"):
		return true
	var p := n.get_parent()
	return p != null and p.is_in_group("enemy_head")


func _notify_hit(collider: Object, headshot: bool) -> void:
	var killed := false
	if collider.has_method("is_dead"):
		killed = bool(collider.call("is_dead"))
	var hud := get_tree().get_first_node_in_group("hud")
	var hud_shown := false
	if hud != null and hud.has_method("show_hitmarker"):
		hud.show_hitmarker(killed, headshot)
		hud_shown = true
	# Goal 1: the HUD owns the hit sound (it plays exactly one tick per
	# show_hitmarker, deduped for same-frame doubles). The weapon only
	# plays a fallback when no HUD exists — previously BOTH played, so
	# every hit sounded twice and shotgun pellets stacked 8 ticks.
	if not hud_shown:
		if headshot:
			Sfx.play_2d("headshot_ding")
		else:
			Sfx.play_2d("hitmarker")


func _apply_recoil() -> void:
	if _player == null or not is_instance_valid(_player) or not _player.has_method("add_look"):
		return
	if recoil_pattern.is_empty():
		return
	var kick: Vector2 = recoil_pattern[_shot_index % recoil_pattern.size()]
	_shot_index += 1
	var mult := ADS_RECOIL_MULT if _ads else 1.0
	kick *= mult
	# add_look convention: +x right, +y down -> muzzle rise is -y.
	var look := Vector2(kick.x, -kick.y)
	_player.add_look(look)
	_recoil_debt += look
	# Goal 1: the kick HOLDS for a beat before recovery starts (settle
	# delay), and the viewmodel punches back + up in sync with the camera.
	_recoil_settle_t = RECOIL_SETTLE_DELAY
	_vm_kick_z += _kick_mag * RECOIL_VM_KICK_Z * mult
	_vm_kick_pitch += _kick_mag * RECOIL_VM_KICK_PITCH * mult


func _recover_recoil(delta: float) -> void:
	if _recoil_debt.length_squared() < 0.0000001:
		return
	if _player == null or not is_instance_valid(_player) or not _player.has_method("add_look"):
		_recoil_debt = Vector2.ZERO
		return
	# Goal 1: settle delay first (kick reads), then exponential recovery
	# with a per-weapon time constant — fast guns snap back, the sniper
	# and shotgun settle slowly. ~95% recovered in recoil_recover_time.
	if _recoil_settle_t > 0.0:
		_recoil_settle_t -= delta
		return
	var tau := maxf(recoil_recover_time / 3.0, 0.02)
	var k := 1.0 - exp(-delta / tau)
	var step := _recoil_debt * k
	_player.add_look(-step)
	_recoil_debt -= step
	if _recoil_debt.length_squared() < 0.0000001:
		_recoil_debt = Vector2.ZERO


## Goal 1: viewmodel kick spring-back (exponential, faster than the
## camera recovery so the gun visually leads the settle).
func _tick_vm_kick(delta: float) -> void:
	if _vm_kick_z == 0.0 and _vm_kick_pitch == 0.0:
		return
	var k := exp(-RECOIL_VM_DECAY * delta)
	_vm_kick_z *= k
	_vm_kick_pitch *= k
	if absf(_vm_kick_z) < 0.0002:
		_vm_kick_z = 0.0
	if absf(_vm_kick_pitch) < 0.0002:
		_vm_kick_pitch = 0.0


# --- Muzzle flash / shells (preallocated, no per-shot allocs) ---

func _build_flash() -> void:
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.62, 0.2)
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 6.0
	_flash_light.omni_attenuation = 1.0
	_flash_light.shadow_enabled = false
	_flash_quad = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.28, 0.28)
	_flash_quad.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(1.0, 0.7, 0.25)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.15)
	mat.emission_energy_multiplier = 4.0
	_flash_quad.material_override = mat
	_flash_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash_quad.visible = false
	_flash_light.visible = false
	# Parent to the VIEWMODEL, not the weapon node: _show_muzzle_flash sets
	# positions in viewmodel-local coords (Muzzle marker space), and the
	# viewmodel gets reparented onto the camera on equip — children follow.
	# (Previously the light lived in weapon-node space, so the flash could
	# appear offset from the muzzle / fail to track the camera.)
	if _viewmodel != null:
		_viewmodel.add_child(_flash_light)
		_viewmodel.add_child(_flash_quad)
	else:
		add_child(_flash_light)
		add_child(_flash_quad)


func _show_muzzle_flash() -> void:
	if _muzzle == null:
		return
	var mp := _muzzle.position
	_flash_light.position = mp
	_flash_quad.position = mp
	_flash_light.light_energy = muzzle_flash_energy
	_flash_light.visible = true
	_flash_quad.visible = true
	# Goal 1: per-shot flash variance — no two shots look identical.
	_flash_quad.scale = Vector3.ONE * randf_range(0.9, 1.35)
	_flash_t = muzzle_flash_time


func _build_shell_pool() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.76, 0.62, 0.30)
	mat.roughness = 0.35
	mat.metallic = 0.85
	for i in SHELL_POOL_SIZE:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.012, 0.012, 0.03)
		mi.mesh = bm
		mi.material_override = mat
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_shells.append({"node": mi, "vel": Vector3.ZERO, "life": 0.0})


func _eject_shell() -> void:
	if _eject == null:
		return
	for entry in _shells:
		if entry["life"] <= 0.0:
			var mi: MeshInstance3D = entry["node"]
			mi.global_position = _eject.global_position
			var basis_t: Basis = _eject.global_transform.basis
			var vel: Vector3 = (basis_t.x * randf_range(0.8, 1.4)
				+ basis_t.y * randf_range(1.2, 2.0)
				- basis_t.z * randf_range(0.2, 0.6)) * 1.6
			entry["vel"] = vel
			entry["life"] = SHELL_LIFE
			mi.visible = true
			return


# --- Per-frame ---

func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	# Goal 3 BURST: spend queued burst rounds as the RPM cooldown clears.
	# Empty mag cancels the burst (dry-fire + auto-reload come from
	# _attempt_fire's own path, so stop here to avoid a dry-fire loop).
	if _burst_left > 0:
		if mag <= 0:
			_burst_left = 0
		elif _cooldown <= 0.0 and not _lowering and _raise_t >= raise_time \
				and _reload_stage == _ReloadStage.NONE and _cycle_t <= 0.0:
			_burst_left -= 1
			_attempt_fire()
	if _cycle_t > 0.0:
		_cycle_t -= delta
		if not _cycle_sfx_done and _cycle_t <= cycle_time * 0.35:
			_cycle_sfx_done = true
			Sfx.play_2d("pump_cycle" if fire_mode == FireMode.PUMP else "bolt_cycle")
	_recover_recoil(delta)
	_tick_vm_kick(delta)
	_tick_reload(delta)
	_tick_raise_lower(delta)
	_tick_flash(delta)
	_tick_shells(delta)
	_tick_sway_bob(delta)


func _tick_reload(delta: float) -> void:
	if _reload_stage == _ReloadStage.NONE:
		return
	_reload_t -= delta
	if _reload_t > 0.0:
		return
	match _reload_stage:
		_ReloadStage.MAG_OUT:
			_reload_stage = _ReloadStage.MAG_IN
			_reload_t = float(reload_stages[1])
		_ReloadStage.MAG_IN:
			var need := mag_size - mag
			var take := mini(need, reserve)
			mag += take
			reserve -= take
			emit_ammo()
			_reload_stage = _ReloadStage.CHAMBER
			_reload_t = float(reload_stages[2])
		_ReloadStage.CHAMBER:
			_reload_stage = _ReloadStage.NONE


func _tick_raise_lower(delta: float) -> void:
	if _viewmodel == null:
		return
	if _lowering:
		_viewmodel.position.y = lerpf(_viewmodel.position.y, HIP_POS.y - 0.25, clampf(delta * 14.0, 0.0, 1.0))
		return
	if _raise_t < raise_time:
		_raise_t += delta
		var t := clampf(_raise_t / maxf(raise_time, 0.001), 0.0, 1.0)
		var e := 1.0 - pow(1.0 - t, 3.0) # ease-out cubic
		var target := HIP_POS.lerp(_ads_pos, _ads_blend)
		var start := HIP_POS + Vector3(0.0, -0.22, 0.06)
		_viewmodel.position = start.lerp(target, e)


func _tick_flash(delta: float) -> void:
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_flash_light.light_energy = 0.0
			_flash_light.visible = false
			_flash_quad.visible = false


func _tick_shells(delta: float) -> void:
	for entry in _shells:
		var life: float = entry["life"]
		if life <= 0.0:
			continue
		life -= delta
		entry["life"] = life
		var mi: MeshInstance3D = entry["node"]
		if life <= 0.0:
			mi.visible = false
			continue
		var vel: Vector3 = entry["vel"]
		vel.y -= SHELL_GRAVITY * delta
		entry["vel"] = vel
		mi.global_position += vel * delta
		mi.rotation += Vector3(9.0, 7.0, 5.0) * delta
		if life < 0.3:
			var s := clampf(life / 0.3, 0.05, 1.0)
			mi.scale = Vector3(s, s, s)
		else:
			mi.scale = Vector3.ONE


func _tick_sway_bob(delta: float) -> void:
	if _viewmodel == null or _camera == null:
		return
	_sway_t += delta
	var ads_mult := ADS_SWAY_MULT if _ads else 1.0
	# ADS blend: 0 = hip, 1 = ads.
	_ads_blend = move_toward(_ads_blend, 1.0 if _ads else 0.0, delta * 10.0)
	var target_pos := HIP_POS.lerp(_ads_pos, _ads_blend)
	var target_rot := HIP_ROT.lerp(ADS_ROT, _ads_blend)
	var speed := _player_speed()
	if speed > 0.8 and not _ads:
		_bob_t += delta * (2.0 + speed * 0.6)
	var bob_mult := ADS_BOB_MULT if _ads else 1.0
	var bob := Vector3(
		cos(_bob_t * BOB_FREQ) * BOB_AMOUNT * 0.6,
		sin(_bob_t * BOB_FREQ * 2.0) * BOB_AMOUNT * 0.5,
		0.0) * bob_mult * clampf(speed / 3.0, 0.0, 1.0)
	# Don't fight the raise/lower animation: sway only drives rotation then.
	var animating := _raise_t < raise_time or _lowering
	if not animating:
		# Goal 1: viewmodel recoil kick rides on top of bob (backward +Z,
		# since forward is -Z). Decays in _tick_vm_kick.
		_viewmodel.position = target_pos + bob + Vector3(0.0, 0.0, _vm_kick_z)
	var sway := Vector3(
		sin(_sway_t * SWAY_SPEED * 1.7) * SWAY_AMOUNT,
		sin(_sway_t * SWAY_SPEED * 1.3) * SWAY_AMOUNT * 1.2,
		0.0) * ads_mult
	# Don't fight the raise animation: blend sway in as raise completes.
	var raise_blend := clampf(_raise_t / maxf(raise_time, 0.001), 0.0, 1.0)
	_viewmodel.rotation = target_rot + sway * raise_blend + Vector3(_vm_kick_pitch, 0.0, 0.0)
