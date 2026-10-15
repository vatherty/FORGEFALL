# FORGEFALL — TracerPool
# Shared pooled tracer visuals for hitscan weapons. Thin emissive stretched
# boxes from muzzle to hit point, ~60ms life. Static spawn() API; the pool
# root attaches itself to the current scene on first use. No per-spawn
# allocations beyond the preallocated pool.
class_name TracerPool
extends Node3D

#region TUNABLES
const POOL_SIZE := 28
const TRACER_LIFE := 0.10
const TRACER_WIDTH := 0.024
const TRACER_COLOR := Color(1.0, 0.82, 0.35)
#endregion

static var _inst: TracerPool = null
static var _mesh: BoxMesh = null
static var _mat: StandardMaterial3D = null

var _pool: Array = [] # Array of Dictionary {node: MeshInstance3D, life: float}


static func _ensure() -> TracerPool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	if _inst != null and not is_instance_valid(_inst):
		_inst = null
	if _inst == null:
		if _mesh == null:
			_mesh = BoxMesh.new()
			_mesh.size = Vector3(TRACER_WIDTH, TRACER_WIDTH, 1.0)
		if _mat == null:
			_mat = StandardMaterial3D.new()
			_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_mat.albedo_color = TRACER_COLOR
			_mat.emission_enabled = true
			_mat.emission = TRACER_COLOR
			_mat.emission_energy_multiplier = 6.0
		_inst = TracerPool.new()
		_inst.name = "TracerPool"
		var scene := tree.current_scene
		if scene != null:
			scene.add_child(_inst)
		else:
			tree.root.add_child(_inst)
		_inst._build_pool()
	return _inst


func _build_pool() -> void:
	for i in POOL_SIZE:
		var mi := MeshInstance3D.new()
		mi.mesh = _mesh
		mi.material_override = _mat
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_pool.append({"node": mi, "life": 0.0})


## Fire a tracer from -> to. Safe to call before the scene is ready (no-op).
static func spawn(from: Vector3, to: Vector3) -> void:
	var pool := TracerPool._ensure()
	if pool == null:
		return
	var dist := from.distance_to(to)
	if dist < 0.5:
		return
	for entry in pool._pool:
		if entry["life"] <= 0.0:
			var mi: MeshInstance3D = entry["node"]
			mi.global_position = (from + to) * 0.5
			_aim(mi, to)
			mi.scale = Vector3(1.0, 1.0, dist)
			mi.visible = true
			entry["life"] = TRACER_LIFE
			return
	# Pool exhausted: steal the oldest slot (index 0) rather than allocating.
	var entry0: Dictionary = pool._pool[0]
	var mi0: MeshInstance3D = entry0["node"]
	mi0.global_position = (from + to) * 0.5
	_aim(mi0, to)
	mi0.scale = Vector3(1.0, 1.0, dist)
	mi0.visible = true
	entry0["life"] = TRACER_LIFE


## Point the tracer's -Z at the target, avoiding the degenerate up vector
## when the shot is (near-)vertical.
static func _aim(mi: MeshInstance3D, to: Vector3) -> void:
	var d: Vector3 = to - mi.global_position
	if d.length_squared() < 0.0001:
		return
	var up := Vector3.UP
	if absf(d.normalized().y) > 0.98:
		up = Vector3.FORWARD
	mi.look_at(to, up)


func _process(delta: float) -> void:
	for entry in _pool:
		var life: float = entry["life"]
		if life > 0.0:
			life -= delta
			entry["life"] = life
			if life <= 0.0:
				(entry["node"] as MeshInstance3D).visible = false
