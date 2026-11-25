extends Node

## CharacterMotion — procedural walk cycle + patrol/chase AI for Studio
## characters. Added as a child of the character CharacterBody3D by
## content_runtime.build_character.
##
## The Studio rig is a tree of named box parts, not a skeleton, so there is
## nothing to skin: the walk cycle is procedural joint animation. Joints
## classified as legs swing around their authored pivot, arms counter-swing,
## and body parts bob, all driven by the body's actual horizontal speed with
## an amplitude blend so idle eases back to the authored pose.
##
## AI states: idle -> patrol (map "waypoint" markers) -> chase (nearest
## "player" inside sight_range) -> return (home, then resume patrol).
## Legacy adapter note: when the body already has a movement script (the
## game's studio_character.gd), that script drives the body while it can see
## a player; this component only drives when no player is seen, and never
## calls move_and_slide otherwise, so the two never fight over the body.

@export var move_speed := 2.5
@export var sight_range := 25.0
@export var stride_length := 0.7
@export var swing_degrees := 28.0
@export var idle_duration := 1.0
@export var lose_delay := 2.0
@export var arrive_distance := 0.6

var state := "idle"
var walk_phase := 0.0
var current_waypoint_index := 0
var patrol_waypoints: Array = []
var limb_roles: Dictionary = {}

const _EXCLUDE_NAMES := ["Visual", "Collision", "Muzzle", "VoxelVisual", "Weapon", "NavigationAgent3D"]
const _CHASE_STOP_DISTANCE := 1.4

var _body: CharacterBody3D
var _agent: NavigationAgent3D
var _home := Vector3.ZERO
var _joints: Array = []
var _amplitude := 0.0
var _idle_timer := 0.0
var _lose_timer := 0.0
var _agent_timer := 0.0
var _target := Vector3.ZERO
var _player: Node3D
var _seen := false
var _last_seen_position := Vector3.ZERO
var _restored := true

func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	if _body == null:
		return
	_home = _body.global_position
	_target = _home
	_agent = _body.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	if patrol_waypoints.is_empty():
		_fill_waypoints()
	_collect_joints(_body)

func _fill_waypoints() -> void:
	var nodes := get_tree().get_nodes_in_group("waypoint")
	nodes.sort_custom(func(a: Node, b: Node) -> bool:
		if a.name != b.name:
			return String(a.name) < String(b.name)
		var pa := (a as Node3D).global_position
		var pb := (b as Node3D).global_position
		if not is_equal_approx(pa.x, pb.x):
			return pa.x < pb.x
		return pa.z < pb.z)
	for node in nodes:
		if node is Node3D:
			patrol_waypoints.append((node as Node3D).global_position)

func _collect_joints(node: Node) -> void:
	for child in node.get_children():
		if child == self or not child is Node3D:
			continue
		var joint := child as Node3D
		if _EXCLUDE_NAMES.has(String(joint.name)):
			continue
		var role := _classify(String(joint.name))
		if role != "":
			_joints.append({"node": joint, "role": role, "base_pos": joint.position, "base_rot": joint.rotation})
		_collect_joints(joint)

func _classify(part_name: String) -> String:
	if limb_roles.has(part_name):
		return str(limb_roles[part_name])
	var low := part_name.to_lower()
	var side := ""
	if low.contains("left"):
		side = "left"
	elif low.contains("right"):
		side = "right"
	if low.contains("leg"):
		if side == "":
			side = "left" if _count_role("leg_left") <= _count_role("leg_right") else "right"
		return "leg_" + side
	if low.contains("arm"):
		if side == "":
			side = "left" if _count_role("arm_left") <= _count_role("arm_right") else "right"
		return "arm_" + side
	if low.contains("body") or low.contains("torso"):
		return "body"
	return ""

func _count_role(role: String) -> int:
	var count := 0
	for joint in _joints:
		if joint["role"] == role:
			count += 1
	return count

func _physics_process(delta: float) -> void:
	if _body == null:
		return
	_update_ai(delta)
	_drive(delta)
	_animate(delta)
	_face_movement(delta)

func _set_state(next: String) -> void:
	if state == next:
		return
	state = next
	_idle_timer = 0.0
	_lose_timer = 0.0

func _update_ai(delta: float) -> void:
	_player = _nearest_player()
	_seen = false
	if _player != null:
		var distance := _body.global_position.distance_to(_player.global_position)
		_seen = distance <= sight_range
		if _seen:
			_last_seen_position = _player.global_position
	match state:
		"idle":
			if _seen:
				_set_state("chase")
			else:
				_idle_timer += delta
				if _idle_timer >= idle_duration and not patrol_waypoints.is_empty():
					_set_state("patrol")
		"patrol":
			if _seen:
				_set_state("chase")
			elif not patrol_waypoints.is_empty():
				var waypoint: Vector3 = patrol_waypoints[current_waypoint_index]
				if _horizontal_distance(waypoint) <= arrive_distance:
					current_waypoint_index = (current_waypoint_index + 1) % patrol_waypoints.size()
		"chase":
			if _seen:
				_lose_timer = 0.0
			else:
				_lose_timer += delta
				if _lose_timer >= lose_delay:
					if not patrol_waypoints.is_empty() or _horizontal_distance(_home) > arrive_distance:
						_set_state("return")
					else:
						_set_state("idle")
		"return":
			if _seen:
				_set_state("chase")
			elif _horizontal_distance(_home) <= arrive_distance:
				if not patrol_waypoints.is_empty():
					current_waypoint_index = _nearest_waypoint_index()
					_set_state("patrol")
				else:
					_set_state("idle")
	_target = _current_target()

func _current_target() -> Vector3:
	match state:
		"patrol":
			if not patrol_waypoints.is_empty():
				return patrol_waypoints[current_waypoint_index]
		"chase":
			return _player.global_position if _seen and _player != null else _last_seen_position
		"return":
			return _home
	return _body.global_position

func _nearest_player() -> Node3D:
	var best: Node3D
	var best_distance := INF
	for candidate in get_tree().get_nodes_in_group("player"):
		if candidate is Node3D:
			var distance := _body.global_position.distance_to((candidate as Node3D).global_position)
			if distance < best_distance:
				best_distance = distance
				best = candidate
	return best

func _nearest_waypoint_index() -> int:
	var best := 0
	var best_distance := INF
	for i in patrol_waypoints.size():
		var distance := _body.global_position.distance_to(patrol_waypoints[i])
		if distance < best_distance:
			best_distance = distance
			best = i
	return best

func _horizontal_distance(target: Vector3) -> float:
	return Vector2(target.x - _body.global_position.x, target.z - _body.global_position.z).length()

func _should_drive() -> bool:
	# The legacy game adapter drives the body itself while it sees a player.
	# In every other situation (and always, when no adapter script loaded)
	# this component is the driver.
	return _body.get_script() == null or not _seen

func _drive(delta: float) -> void:
	if not _should_drive():
		return
	var velocity := _body.velocity
	var desired := Vector2.ZERO
	if state != "idle" and move_speed > 0.0:
		var stop_distance := _CHASE_STOP_DISTANCE if state == "chase" else arrive_distance
		if _horizontal_distance(_target) > stop_distance or state == "patrol":
			var direction := _steer(delta)
			desired = Vector2(direction.x, direction.z) * move_speed
	if desired == Vector2.ZERO:
		var decay := move_speed * 4.0 * delta
		velocity.x = move_toward(velocity.x, 0.0, decay)
		velocity.z = move_toward(velocity.z, 0.0, decay)
	else:
		velocity.x = desired.x
		velocity.z = desired.y
	if not _body.is_on_floor():
		velocity.y -= float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * delta
	_body.velocity = velocity
	_body.move_and_slide()

func _steer(delta: float) -> Vector3:
	if _agent != null:
		var map := _agent.get_navigation_map()
		if NavigationServer3D.map_get_regions(map).size() > 0:
			_agent_timer -= delta
			if _agent_timer <= 0.0:
				_agent.target_position = _target
				_agent_timer = 0.5
			if not _agent.is_navigation_finished():
				var next := _agent.get_next_path_position()
				var offset := Vector3(next.x - _body.global_position.x, 0.0, next.z - _body.global_position.z)
				if offset.length() > 0.05:
					return offset.normalized()
	var direct := Vector3(_target.x - _body.global_position.x, 0.0, _target.z - _body.global_position.z)
	return direct.normalized() if direct.length() > 0.001 else Vector3.ZERO

func _animate(delta: float) -> void:
	var speed := Vector2(_body.velocity.x, _body.velocity.z).length()
	if stride_length > 0.0:
		walk_phase = fposmod(walk_phase + (speed * delta / stride_length) * PI, TAU)
	var target_amplitude := clampf(speed / maxf(move_speed, 0.01), 0.0, 1.0)
	_amplitude = lerpf(_amplitude, target_amplitude, clampf(8.0 * delta, 0.0, 1.0))
	if _amplitude < 0.001 and speed < 0.01:
		if not _restored:
			for joint in _joints:
				(joint["node"] as Node3D).position = joint["base_pos"]
				(joint["node"] as Node3D).rotation = joint["base_rot"]
			_restored = true
		return
	_restored = false
	var swing := deg_to_rad(swing_degrees) * _amplitude
	for joint in _joints:
		var node := joint["node"] as Node3D
		var base_pos: Vector3 = joint["base_pos"]
		var base_rot: Vector3 = joint["base_rot"]
		match joint["role"]:
			"leg_left":
				node.rotation = Vector3(base_rot.x + sin(walk_phase) * swing, base_rot.y, base_rot.z)
			"leg_right":
				node.rotation = Vector3(base_rot.x + sin(walk_phase + PI) * swing, base_rot.y, base_rot.z)
			"arm_left":
				node.rotation = Vector3(base_rot.x + sin(walk_phase + PI) * swing, base_rot.y, base_rot.z)
			"arm_right":
				node.rotation = Vector3(base_rot.x + sin(walk_phase) * swing, base_rot.y, base_rot.z)
			"body":
				node.position = Vector3(base_pos.x, base_pos.y + absf(sin(walk_phase)) * 0.035 * _amplitude, base_pos.z)
				node.rotation = Vector3(base_rot.x + sin(walk_phase * 2.0) * 0.03 * _amplitude, base_rot.y, base_rot.z)

func _face_movement(delta: float) -> void:
	var velocity := _body.velocity
	if Vector2(velocity.x, velocity.z).length() <= 0.1:
		return
	var yaw := atan2(-velocity.x, -velocity.z)
	_body.rotation.y = lerp_angle(_body.rotation.y, yaw, clampf(10.0 * delta, 0.0, 1.0))
