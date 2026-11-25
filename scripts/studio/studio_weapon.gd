extends Node3D

signal fired(hit: Object)
signal empty()

@export var damage := 12.0
@export var max_range := 30.0
@export var cooldown := 0.25
@export var magazine_size := 12

var ammunition := -1
var last_fire_time := -1000.0

func _ready() -> void:
	if ammunition < 0:
		ammunition = magazine_size

func reload() -> void:
	ammunition = magazine_size

func fire() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now - last_fire_time < cooldown:
		return false
	if ammunition <= 0:
		empty.emit()
		return false
	last_fire_time = now
	ammunition -= 1
	var muzzle := get_node_or_null("Muzzle") as Marker3D
	var origin := muzzle.global_position if muzzle != null else global_position
	var direction := -global_transform.basis.z.normalized()
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_range)
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is CollisionObject3D:
			query.exclude.append(ancestor.get_rid())
		ancestor = ancestor.get_parent()
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var collider: Object = hit["collider"]
		if collider.has_method("take_damage"):
			collider.call("take_damage", damage, hit["position"], false)
		fired.emit(collider)
	else:
		fired.emit(null)
	return true
