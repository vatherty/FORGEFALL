# FORGEFALL — Forge Turret (Worker 8: Forge system)
# Player-built voxel sentry gun. Base + column + pivoting head with a gun
# barrel, all VoxelBuilder cubes. Scans the "enemy" (and legacy "enemies")
# groups for targets within 30 m with line of sight, fires hitscan bursts
# (15 dmg, 300 rpm) with a muzzle flash, tracer beam, and Sfx "shot_turret".
# HP 150 — enemies can hurt it (group "turret", take_damage). When its ttl
# expires (or it is destroyed) it powers down: sinks into the ground, frees.
extends Node3D

#region TUNABLES
const RANGE_M := 30.0
const DAMAGE := 15.0
const SHOT_INTERVAL := 0.2 ## 300 rpm
const BURST_SIZE := 4
const BURST_PAUSE := 0.9
const MAX_HP := 150.0
const SCAN_INTERVAL := 0.25
const HEAD_TURN_SPEED := 7.0
const FLASH_TIME := 0.06
const BEAM_TIME := 0.09
const SINK_DEPTH := 1.5
const SINK_TIME := 1.6
#endregion

var ttl_seconds := 45.0

# v0.7: composition multipliers recorded as metadata by ForgeBuilder
# (_apply_turret_ammo: damage_mult / range_mult, from ammo_type).
# Read in _ready (the builder sets them BEFORE add_child) and re-read
# on every acquire/fire, so a meta set or changed after _ready still
# takes effect. Default 1.0 when absent.
var _damage_mult := 1.0
var _range_mult := 1.0

var _hp := MAX_HP
var _time_left := 0.0
var _dead := false
var _target = null ## untyped: duck-typed take_damage calls
var _scan_timer := 0.0
var _shot_timer := 0.0
var _burst_left := BURST_SIZE
var _head: Node3D = null
var _muzzle: Node3D = null
var _flash: MeshInstance3D = null
var _flash_timer := 0.0
var _beam: MeshInstance3D = null
var _beam_timer := 0.0
var _body: StaticBody3D = null


func _ready() -> void:
	add_to_group("turret")
	_time_left = ttl_seconds
	_read_mults()
	_build_voxels()
	_build_collision()


## Damage per hit after the ammo composition multiplier.
func get_damage() -> float:
	return DAMAGE * _damage_mult


## Acquisition range after the ammo composition multiplier.
func get_range() -> float:
	return RANGE_M * _range_mult


func _read_mults() -> void:
	if has_meta("damage_mult"):
		_damage_mult = maxf(0.0, float(get_meta("damage_mult")))
	if has_meta("range_mult"):
		_range_mult = maxf(0.0, float(get_meta("range_mult")))


func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool) -> void:
	if _dead:
		return
	_hp -= amount
	if _hp <= 0.0:
		_power_down()


func _process(delta: float) -> void:
	if _dead:
		return
	_time_left -= delta
	if _time_left <= 0.0:
		_power_down()
		return
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = SCAN_INTERVAL
		_acquire_target()
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0 and is_instance_valid(_flash):
			_flash.visible = false
	if _beam_timer > 0.0:
		_beam_timer -= delta
		if _beam_timer <= 0.0 and is_instance_valid(_beam):
			_beam.visible = false
	if _target != null and not is_instance_valid(_target):
		_target = null
	if _target == null:
		return
	_aim(delta)
	_shot_timer -= delta
	if _shot_timer <= 0.0:
		_fire()
		_burst_left -= 1
		if _burst_left <= 0:
			_burst_left = BURST_SIZE
			_shot_timer = BURST_PAUSE
		else:
			_shot_timer = SHOT_INTERVAL


func _build_voxels() -> void:
	var gunmetal: Color = VoxelBuilder.PALETTE["gunmetal"]
	var darkmetal: Color = VoxelBuilder.PALETTE["darkmetal"]
	var orange: Color = VoxelBuilder.PALETTE["forge_orange"]
	add_child(VoxelBuilder.cube(Vector3(0.9, 0.3, 0.9), darkmetal, Vector3(0, 0.15, 0)))
	add_child(VoxelBuilder.cube(Vector3(0.35, 0.55, 0.35), gunmetal, Vector3(0, 0.57, 0)))
	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(0, 0.95, 0)
	add_child(_head)
	_head.add_child(VoxelBuilder.cube(Vector3(0.55, 0.35, 0.6), gunmetal, Vector3.ZERO))
	_head.add_child(VoxelBuilder.cube(Vector3(0.55, 0.1, 0.62), orange, Vector3(0, 0.2, 0)))
	_head.add_child(VoxelBuilder.cube(Vector3(0.12, 0.12, 0.95), darkmetal, Vector3(0, 0.02, -0.72)))
	_muzzle = Node3D.new()
	_muzzle.name = "Muzzle"
	_muzzle.position = Vector3(0, 0.02, -1.22)
	_head.add_child(_muzzle)
	_flash = VoxelBuilder.cube(Vector3(0.26, 0.26, 0.26), Color(1.0, 0.6, 0.15))
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.albedo_color = Color(1.0, 0.55, 0.1)
	_flash.material_override = fmat
	_flash.visible = false
	_muzzle.add_child(_flash)
	# Tracer beam: unit box stretched between muzzle and target, top-level so
	# turret motion never skews it.
	_beam = MeshInstance3D.new()
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3.ONE
	_beam.mesh = beam_mesh
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bmat.albedo_color = Color(1.0, 0.65, 0.2, 0.75)
	_beam.material_override = bmat
	_beam.visible = false
	add_child(_beam)
	_beam.top_level = true


func _build_collision() -> void:
	_body = StaticBody3D.new()
	_body.add_child(VoxelBuilder.collision_box(Vector3(0.9, 1.3, 0.9)))
	_body.position = Vector3(0, 0.65, 0)
	add_child(_body)


func _foes() -> Array:
	var out: Array = []
	var seen := {}
	for group in ["enemy", "enemies"]:
		for e in get_tree().get_nodes_in_group(group):
			var id := (e as Node).get_instance_id()
			if not seen.has(id):
				seen[id] = true
				out.append(e)
	return out


func _acquire_target() -> void:
	_read_mults()
	var best = null
	var best_d := get_range()
	var from := _muzzle.global_position if _muzzle != null else global_position + Vector3(0, 1, 0)
	for e in _foes():
		var foe = e
		if not (foe is Node3D):
			continue
		if bool(foe.get("dead")):
			continue
		if not foe.has_method("take_damage"):
			continue
		var d := from.distance_to((foe as Node3D).global_position)
		if d > best_d:
			continue
		if not _has_los(from, (foe as Node3D).global_position + Vector3(0, 0.9, 0), foe):
			continue
		best = foe
		best_d = d
	_target = best


func _has_los(from: Vector3, to: Vector3, target) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	if _body != null:
		q.exclude = [_body.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	return hit.get("collider") == target


func _aim(delta: float) -> void:
	var to: Vector3 = _target.global_position + Vector3(0, 0.9, 0) - _head.global_position
	if to.length() < 0.5:
		return
	var k := clampf(HEAD_TURN_SPEED * delta, 0.0, 1.0)
	var want_yaw := atan2(-to.x, -to.z)
	var horiz := Vector2(to.x, to.z).length()
	var want_pitch := atan2(to.y, horiz)
	_head.rotation = Vector3(
		lerp_angle(_head.rotation.x, want_pitch, k),
		lerp_angle(_head.rotation.y, want_yaw, k),
		0.0)


func _fire() -> void:
	if _target == null or not is_instance_valid(_target):
		_target = null
		return
	_read_mults()
	var from := _muzzle.global_position
	var aim: Vector3 = _target.global_position + Vector3(0, 0.9, 0)
	if not _has_los(from, aim, _target):
		return
	# v0.5.8 elemental emitters: a turret built with an "element" meta
	# ("a lightning emitter turret") deals its FULL shot damage AS that
	# element — typed_damage + rider, or force/water handling — instead
	# of plain damage, plus an element-colored voxel burst at impact.
	var element := str(get_meta("element", "")) if has_meta("element") else ""
	if ElementalEmitter.is_element(element):
		ElementalEmitter.apply_to_target(_target, element, get_damage(), from)
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.current_scene != null:
			ElementalEmitter.spawn_visual_burst(tree.current_scene, element, aim, 1.2)
	else:
		_target.take_damage(get_damage(), aim, false)
	_flash.visible = true
	_flash_timer = FLASH_TIME
	_show_beam(from, aim)
	Sfx.play_3d("shot_turret", from)


func _show_beam(from: Vector3, to: Vector3) -> void:
	var dist := from.distance_to(to)
	if dist < 0.1:
		return
	_beam.visible = true
	_beam.global_position = (from + to) * 0.5
	_beam.look_at(to, Vector3.UP)
	_beam.scale = Vector3(0.05, 0.05, dist)
	_beam_timer = BEAM_TIME


func _power_down() -> void:
	if _dead:
		return
	_dead = true
	_target = null
	if is_instance_valid(_flash):
		_flash.visible = false
	if is_instance_valid(_beam):
		_beam.visible = false
	var tw := create_tween()
	tw.tween_property(self, "position:y", position.y - SINK_DEPTH, SINK_TIME)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)
