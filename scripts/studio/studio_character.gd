extends CharacterBody3D

signal damaged(amount: float)
signal defeated()

@export var max_health := 100.0
@export var auto_fire := true
@export var sight_range := 25.0
@export var move_speed := 2.5

var health := -1.0
var _repath_time := 0.0

func _ready() -> void:
	if health < 0.0:
		health = max_health

func _physics_process(delta: float) -> void:
	if health <= 0.0:
		return
	var closest: Node3D
	var closest_distance := sight_range
	for candidate in get_tree().get_nodes_in_group("player"):
		if candidate is Node3D:
			var distance := global_position.distance_to(candidate.global_position)
			if distance < closest_distance:
				closest = candidate
				closest_distance = distance
	_update_movement(delta, closest, closest_distance)
	if not auto_fire or closest == null:
		return
	var weapon := get_node_or_null("Body/Hand/Weapon") as Node3D
	if weapon == null or not weapon.has_method("fire"):
		return
	var muzzle := weapon.get_node_or_null("Muzzle") as Node3D
	var origin: Vector3 = muzzle.global_position if muzzle != null else weapon.global_position
	var direction: Vector3 = closest.global_position + Vector3.UP * 0.8 - origin
	if direction.length_squared() < 0.0001:
		return
	weapon.global_basis = Basis.looking_at(direction.normalized(), Vector3.UP)
	weapon.call("fire")

func _update_movement(delta: float, target: Node3D, distance: float) -> void:
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	velocity.y -= gravity * delta if not is_on_floor() else 0.0
	if target == null or move_speed <= 0.0 or distance <= 1.5:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 4.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 4.0 * delta)
		move_and_slide()
		return
	var navigation := get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	var destination := target.global_position
	if navigation != null:
		_repath_time -= delta
		if _repath_time <= 0.0:
			navigation.target_position = target.global_position
			_repath_time = 0.5
		if not navigation.is_navigation_finished():
			var waypoint := navigation.get_next_path_position()
			if waypoint.distance_squared_to(global_position) > 0.04:
				destination = waypoint
	var direction := destination - global_position
	direction.y = 0.0
	if direction.length_squared() > 0.01:
		direction = direction.normalized()
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	move_and_slide()

func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool, _attacker: Node = null) -> void:
	if health <= 0.0:
		return
	health = maxf(0.0, health - maxf(0.0, amount))
	damaged.emit(amount)
	if health <= 0.0:
		defeated.emit()
		queue_free()
