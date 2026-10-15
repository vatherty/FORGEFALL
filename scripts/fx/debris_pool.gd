# scripts/fx/debris_pool.gd
# FORGEFALL — DebrisPool (Worker 5: Map).
#
# Autoload-free pooled physics cubes for destruction effects. No scene-tree
# setup required: the pool initializes lazily on first use and parents itself
# to the current scene root.
#
# Usage:
#     DebrisPool.burst(burst_pos, [Color("8a4b2a"), Color("23262a")], 12, 5.0)
#
# Contract (frozen): DebrisPool.burst(pos: Vector3, colors: Array, count: int,
# speed: float) -> void. Pooled RigidBody3D cubes, cap ~120 active; oldest are
# reused when the cap is hit. Cubes collide with the world (mask 1) but live
# on layer 0 so they never block the player or enemies.
class_name DebrisPool
extends RefCounted

#region TUNABLES
const MAX_ACTIVE := 120       # hard cap on live debris cubes
const POOL_SIZE := 120        # bodies pre-created on first ensure
const DESPAWN_TIME := 2.5     # seconds a cube stays alive
const FADE_TIME := 0.45       # scale-out at end of life
const MIN_CUBE := 0.10        # cube edge range (m)
const MAX_CUBE := 0.24
#endregion

static var _pool: Array[RigidBody3D] = []
static var _active: Array[RigidBody3D] = []  # activation order, oldest first
static var _holder: Node3D = null
static var _mats: Dictionary = {}           # Color.to_html() -> StandardMaterial3D
static var _tweens: Dictionary = {}         # instance_id -> Tween
static var _unit_mesh: BoxMesh = null
static var _unit_shape: BoxShape3D = null
static var _phys_mat: PhysicsMaterial = null


static func _lazy_init() -> void:
	if _holder != null and is_instance_valid(_holder):
		return
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return
	var tree := loop as SceneTree
	var root: Node = tree.current_scene
	if root == null:
		root = tree.root
	if root == null:
		return
	_holder = Node3D.new()
	_holder.name = "DebrisPool"
	root.add_child(_holder)
	if _unit_mesh == null:
		_unit_mesh = BoxMesh.new()
		_unit_mesh.size = Vector3.ONE
	if _unit_shape == null:
		_unit_shape = BoxShape3D.new()
		_unit_shape.size = Vector3.ONE
	if _phys_mat == null:
		_phys_mat = PhysicsMaterial.new()
		_phys_mat.bounce = 0.35
		_phys_mat.friction = 0.8


static func _make_body() -> RigidBody3D:
	var body := RigidBody3D.new()
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.visible = false
	body.can_sleep = true
	body.mass = 0.4
	body.linear_damp = 0.4
	body.angular_damp = 1.2
	body.physics_material_override = _phys_mat
	body.collision_layer = 0  # never blocks player/enemies...
	body.collision_mask = 1   # ...but still bounces off the world
	body.position = Vector3(0, -200, 0)
	var mi := MeshInstance3D.new()
	mi.mesh = _unit_mesh
	body.add_child(mi)
	body.set_meta("mi", mi)
	var cs := CollisionShape3D.new()
	cs.shape = _unit_shape
	body.add_child(cs)
	_holder.add_child(body)
	return body


## Pre-create pooled bodies so the first fracture never hitches.
static func ensure_pool(count: int = POOL_SIZE) -> void:
	_lazy_init()
	if _holder == null:
		return
	while _pool.size() < count:
		_pool.append(_make_body())


static func _mat_for(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	_mats[key] = m
	return m


static func _kill_tween(body: RigidBody3D) -> void:
	var id := body.get_instance_id()
	if _tweens.has(id):
		var tw: Tween = _tweens[id]
		if tw != null and tw.is_valid():
			tw.kill()
		_tweens.erase(id)


static func _next_body() -> RigidBody3D:
	for b in _pool:
		if is_instance_valid(b) and not _active.has(b):
			return b
	# Cap hit: steal the oldest active cube.
	var oldest: RigidBody3D = _active.pop_front()
	_deactivate_body(oldest)
	return oldest


static func _deactivate_body(body: RigidBody3D) -> void:
	if not is_instance_valid(body):
		return
	_kill_tween(body)
	_active.erase(body)
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.freeze = true
	body.visible = false
	body.scale = Vector3.ONE
	body.global_position = Vector3(0, -200, 0)


## Fire a burst of physics cubes. Safe to call any time; no-ops if no SceneTree.
static func burst(pos: Vector3, colors: Array, count: int, speed: float) -> void:
	if colors.is_empty() or count <= 0:
		return
	_lazy_init()
	if _holder == null:
		return
	ensure_pool(POOL_SIZE)
	var tree := Engine.get_main_loop() as SceneTree
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var n := mini(count, MAX_ACTIVE)
	for i in n:
		var body := _next_body()
		_kill_tween(body)
		_active.erase(body)
		var mi := body.get_meta("mi") as MeshInstance3D
		mi.material_override = _mat_for(colors[rng.randi_range(0, colors.size() - 1)])
		var s := rng.randf_range(MIN_CUBE, MAX_CUBE)
		body.scale = Vector3(s, s, s)
		body.global_position = pos + Vector3(
			rng.randf_range(-0.3, 0.3), rng.randf_range(0.0, 0.4), rng.randf_range(-0.3, 0.3))
		body.visible = true
		body.freeze = false
		var dir := Vector3(
			rng.randf_range(-1.0, 1.0), rng.randf_range(0.4, 1.2), rng.randf_range(-1.0, 1.0)).normalized()
		body.linear_velocity = dir * speed * rng.randf_range(0.5, 1.4)
		body.angular_velocity = Vector3(
			rng.randf_range(-8.0, 8.0), rng.randf_range(-8.0, 8.0), rng.randf_range(-8.0, 8.0))
		_active.append(body)
		if tree != null:
			var tw := body.create_tween()
			tw.tween_interval(maxf(0.0, DESPAWN_TIME - FADE_TIME))
			tw.tween_property(body, "scale", Vector3(0.01, 0.01, 0.01), FADE_TIME)
			tw.tween_callback(_deactivate_body.bind(body))
			_tweens[body.get_instance_id()] = tw
