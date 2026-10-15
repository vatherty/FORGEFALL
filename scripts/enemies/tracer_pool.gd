# FORGEFALL — scripts/enemies/tracer_pool.gd
# Worker 4 (enemy AI + waves).
#
# Pooled hitscan tracers: thin emissive boxes that stretch from muzzle to hit
# point and fade over ~0.09s. Instanced once by WaveManager (add as child);
# enemies call the static EnemyTracerPool.spawn(). No per-frame allocations: fixed
# arrays, free-list indices. Fade uses GeometryInstance3D.transparency so
# materials stay shared per color.

class_name EnemyTracerPool
extends Node

static var instance: EnemyTracerPool = null

const POOL_SIZE := 24
const TRACER_LIFE := 0.09
const TRACER_WIDTH := 0.035

var _tracers: Array[MeshInstance3D] = []
var _life: Array[float] = []
var _free: Array[int] = []
var _mesh: BoxMesh
var _mats := {}


func _ready() -> void:
	instance = self
	_mesh = BoxMesh.new()
	_mesh.size = Vector3(TRACER_WIDTH, TRACER_WIDTH, 1.0)
	for i in POOL_SIZE:
		var t := MeshInstance3D.new()
		t.mesh = _mesh
		t.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		t.visible = false
		add_child(t)
		_tracers.append(t)
		_life.append(0.0)
		_free.append(i)


static func spawn(a: Vector3, b: Vector3, color: Color) -> void:
	if instance == null:
		return
	instance._spawn(a, b, color)


func _mat_for(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if _mats.has(key):
		return _mats[key] as StandardMaterial3D
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	_mats[key] = m
	return m


func _spawn(a: Vector3, b: Vector3, color: Color) -> void:
	var idx := -1
	if not _free.is_empty():
		idx = _free.pop_back()
	else:
		# Pool exhausted: steal the oldest active tracer.
		var oldest := 0
		for i in _tracers.size():
			if _life[i] < _life[oldest]:
				oldest = i
		idx = oldest
	var t := _tracers[idx]
	var d: Vector3 = b - a
	var dist := d.length()
	if dist < 0.05:
		_free.append(idx)
		return
	t.global_position = a + d * 0.5
	var up := Vector3.UP
	if absf(d.normalized().y) > 0.98:
		up = Vector3.RIGHT
	t.look_at(b, up)
	t.scale = Vector3(1, 1, dist)
	t.set_surface_override_material(0, _mat_for(color))
	t.transparency = 0.0
	t.visible = true
	_life[idx] = TRACER_LIFE


func _process(delta: float) -> void:
	for i in _tracers.size():
		if _life[i] <= 0.0:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			_tracers[i].visible = false
			_free.append(i)
		else:
			_tracers[i].transparency = 1.0 - _life[i] / TRACER_LIFE
