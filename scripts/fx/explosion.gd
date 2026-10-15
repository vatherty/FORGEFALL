# FORGEFALL — ExplosionFX
# Radial damage + juice for explosions (barrels, killstreaks, heavy Raptor
# throws). detonate(): sphere-query damage with linear falloff, camera
# trauma via the "camera_shake" group (guarded — the player/HUD worker may
# or may not implement add_trauma), pooled voxel debris via DebrisPool
# (guarded with ClassDB.class_exists since the FX worker delivers it in
# parallel), a pooled flash light + scaling fireball, pooled smoke via
# ImpactFX.spawn_smoke, and Sfx.play_3d.
# detonate_light(): visuals + tiny shake only, no damage.
class_name ExplosionFX

#region TUNABLES
const FLASH_TIME := 0.15
const FLASH_POOL_SIZE := 4
const FIREBALL_POOL_SIZE := 4
const DEBRIS_COUNT := 26
const DEBRIS_SPEED := 10.0
const SHAKE_RADIUS_MULT := 3.0
#endregion

static var _root: Node3D = null
static var _flashes: Array = []   # {light: OmniLight3D, busy_until: int}
static var _fireballs: Array = [] # {node: MeshInstance3D, t: float, dur: float, max_r: float}
static var _debris_colors: Array = [Color("8a4b2a"), Color("3a3f44"), Color("ff7b1c")]


static func _ensure(tree: SceneTree) -> bool:
	if _root != null and not is_instance_valid(_root):
		_root = null
		_flashes.clear()
		_fireballs.clear()
	if _root == null:
		var scene := tree.current_scene
		if scene == null:
			return false
		_root = Node3D.new()
		_root.name = "ExplosionFXRoot"
		scene.add_child(_root)
		for i in FLASH_POOL_SIZE:
			var light := OmniLight3D.new()
			light.light_color = Color(1.0, 0.55, 0.18)
			light.light_energy = 0.0
			light.omni_range = 12.0
			light.shadow_enabled = false
			light.visible = false
			_root.add_child(light)
			_flashes.append({"light": light, "busy_until": 0})
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 12
		sphere.rings = 8
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1.0, 0.55, 0.15, 0.85)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.45, 0.10)
		mat.emission_energy_multiplier = 3.0
		for i in FIREBALL_POOL_SIZE:
			var mi := MeshInstance3D.new()
			mi.mesh = sphere
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visible = false
			_root.add_child(mi)
			_fireballs.append({"node": mi, "t": 1.0, "dur": 0.25, "max_r": 1.0})
	return true


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## Full explosion: damage + shake + debris + flash + fireball + sound.
## sound_id (Goal 2): which explosion variant plays — "explosion_big"
## default (barrels / generic), grenades pass "explosion_small".
static func detonate(pos: Vector3, radius: float, damage: float,
		sound_id: String = "explosion_big") -> void:
	var tree := _tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null:
		return
	# Radial damage with linear falloff (min 30% at edge).
	var params := PhysicsShapeQueryParameters3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	params.shape = shape
	params.transform = Transform3D(Basis(), pos)
	var space := tree.root.world_3d.direct_space_state
	var hits := space.intersect_shape(params, 48)
	for h in hits:
		var collider: Object = h.get("collider")
		if collider != null and collider.has_method("take_damage"):
			var at := pos
			if collider is Node3D:
				at = (collider as Node3D).global_position
			var dist := pos.distance_to(at)
			var fall := 1.0 - clampf(dist / maxf(radius, 0.001), 0.0, 1.0) * 0.7
			collider.take_damage(damage * fall, at, false)
	_apply_shake(tree, pos, radius, 1.0)
	_spawn_debris(pos)
	_flash(tree, pos, radius)
	_fireball(pos, radius)
	ImpactFX.spawn_smoke(pos, radius)
	Sfx.play_3d(sound_id, pos)


## Visual-only pop for heavy Raptor impacts: flash + small shake, no damage.
static func detonate_light(pos: Vector3) -> void:
	var tree := _tree()
	if tree == null:
		return
	_apply_shake(tree, pos, 4.0, 0.35)
	_flash(tree, pos, 4.0)
	_fireball(pos, 1.2)
	ImpactFX.spawn_smoke(pos, 1.2)
	Sfx.play_3d("explosion_small", pos)


## Airstrike blast (Goal 2): same visuals as detonate_light, no damage,
## but the biggest explosion sound — explosion_airstrike.
static func detonate_airstrike(pos: Vector3) -> void:
	var tree := _tree()
	if tree == null:
		return
	_apply_shake(tree, pos, 8.0, 1.0)
	_flash(tree, pos, 8.0)
	_fireball(pos, 4.0)
	ImpactFX.spawn_smoke(pos, 4.0)
	Sfx.play_3d("explosion_airstrike", pos)


static func _apply_shake(tree: SceneTree, pos: Vector3, radius: float, strength: float) -> void:
	for n in tree.get_nodes_in_group("camera_shake"):
		if n.has_method("add_trauma"):
			var dist := radius * SHAKE_RADIUS_MULT
			if n is Node3D:
				dist = pos.distance_to((n as Node3D).global_position)
			var trauma := clampf(1.0 - dist / (radius * SHAKE_RADIUS_MULT), 0.0, 1.0) * strength
			n.add_trauma(maxf(trauma, 0.12 * strength))


static func _spawn_debris(pos: Vector3) -> void:
	# NOTE (worker 8): ClassDB only covers native classes; script global
	# classes must be checked against the project's global class list.
	var found := false
	for e in ProjectSettings.get_global_class_list():
		if (e as Dictionary).get("class") == "DebrisPool":
			found = true
			break
	if found:
		DebrisPool.burst(pos, _debris_colors, DEBRIS_COUNT, DEBRIS_SPEED)


static func _flash(tree: SceneTree, pos: Vector3, radius: float) -> void:
	if not _ensure(tree):
		return
	var now := Time.get_ticks_msec()
	for entry in _flashes:
		if int(entry["busy_until"]) <= now:
			var light: OmniLight3D = entry["light"]
			light.global_position = pos
			light.omni_range = radius * 2.0
			light.light_energy = 6.0
			light.visible = true
			entry["busy_until"] = now + int(FLASH_TIME * 1000.0)
			tree.create_timer(FLASH_TIME).timeout.connect(_on_flash_done.bind(light))
			return


static func _on_flash_done(light: OmniLight3D) -> void:
	if is_instance_valid(light):
		light.light_energy = 0.0
		light.visible = false


static func _fireball(pos: Vector3, radius: float) -> void:
	var tree := _tree()
	if tree == null or not _ensure(tree):
		return
	for entry in _fireballs:
		if float(entry["t"]) >= float(entry["dur"]):
			var mi: MeshInstance3D = entry["node"]
			mi.global_position = pos
			mi.visible = true
			entry["t"] = 0.0
			entry["dur"] = 0.25
			entry["max_r"] = radius * 0.55
			_tick_fireballs(tree)
			return


static var _fireball_ticking := false


static func _tick_fireballs(tree: SceneTree) -> void:
	if _fireball_ticking:
		return
	_fireball_ticking = true
	var last := Time.get_ticks_msec() / 1000.0
	while true:
		await tree.process_frame
		if _root == null or not is_instance_valid(_root):
			_fireball_ticking = false
			return
		var now := Time.get_ticks_msec() / 1000.0
		var dt := now - last
		last = now
		var any := false
		for entry in _fireballs:
			var t := float(entry["t"])
			var dur := float(entry["dur"])
			if t < dur:
				any = true
				t = minf(t + dt, dur)
				entry["t"] = t
				var k := t / dur
				var mi: MeshInstance3D = entry["node"]
				var r := lerpf(0.3, float(entry["max_r"]), 1.0 - pow(1.0 - k, 2.0))
				mi.scale = Vector3(r, r, r)
				if t >= dur:
					mi.visible = false
		if not any:
			_fireball_ticking = false
			return
