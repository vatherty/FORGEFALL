# FORGEFALL — ForgeEnemyPressure (Forge batch, Worker B: item 3)
# How enemies damage Forge structures WITHOUT touching enemy code.
#
# Enemy hitscan (enemy_base.gd) only ever damages the player: its ray
# uses LOS_MASK (world + player) and damages the collider only when it is
# in group "player". Structures are world geometry, so enemy fire stops
# at them but never hurts them — and the turret's take_damage() has no
# enemy caller at all. Rather than rewiring every enemy subclass, the
# pressure lives on the structure side:
#
# - ForgeStructure ticks apply_pressure() on itself in _physics_process.
# - Covers / turrets get a ForgeEnemyPressure child node (attached by
#   ForgeBuilder) that ticks apply_pressure() on its parent.
#
# Every PRESSURE_INTERVAL, at most ONE engaged enemy with line of sight
# to the structure lands one hit for its own damage value (times its
# director dmg_mult). "Engaged" = it can see the player, or the player
# is close — so idle enemies across the map do not chew on forts, but
# enemies fighting around a fortification batter it down.
extends Node
class_name ForgeEnemyPressure

const PRESSURE_INTERVAL := 0.9
const PRESSURE_RANGE := 20.0
const EYE_HEIGHT := 1.4
const FALLBACK_DAMAGE := 10.0


func _physics_process(delta: float) -> void:
	var p := get_parent()
	if p == null or not is_instance_valid(p):
		return
	apply_pressure(p, delta)


## One pressure tick for `structure`. Safe to call on any node: nodes
## without take_damage(), destroyed nodes, and non-Node3D nodes are
## no-ops. The per-structure timer lives in metadata so the static
## function needs no per-node state of its own.
static func apply_pressure(structure: Node, delta: float) -> void:
	if structure == null or not is_instance_valid(structure):
		return
	if not (structure is Node3D):
		return
	if _is_dead_structure(structure):
		return
	if not structure.has_method("take_damage"):
		return
	var acc := float(structure.get_meta("pressure_timer", 0.0)) + delta
	if acc < PRESSURE_INTERVAL:
		structure.set_meta("pressure_timer", acc)
		return
	structure.set_meta("pressure_timer", 0.0)
	var foe := _nearest_engaged_foe(structure as Node3D)
	if foe == null:
		return
	var dmg := FALLBACK_DAMAGE
	if foe.get("damage") != null:
		dmg = float(foe.get("damage"))
	var mods: Variant = foe.get("director_mods")
	if mods is Dictionary:
		dmg *= float((mods as Dictionary).get("dmg_mult", 1.0))
	structure.call("take_damage", dmg, (foe as Node3D).global_position, false)


static func _is_dead_structure(structure: Node) -> bool:
	# ForgeStructure._destroyed / turret._dead / DestructibleCover._broken.
	if structure.get("_destroyed") == true:
		return true
	if structure.get("_dead") == true:
		return true
	if structure.get("_broken") == true:
		return true
	if structure.has_method("is_broken") and bool(structure.call("is_broken")):
		return true
	return false


static func _nearest_engaged_foe(structure: Node3D) -> Node3D:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var center := structure.global_position + Vector3(0, _structure_half_height(structure), 0)
	var best: Node3D = null
	var best_d := PRESSURE_RANGE
	var seen := {}
	for group in ["enemy", "enemies"]:
		for e in tree.get_nodes_in_group(group):
			if e == null or not is_instance_valid(e):
				continue
			var id := (e as Node).get_instance_id()
			if seen.has(id):
				continue
			seen[id] = true
			if not (e is Node3D):
				continue
			var foe := e as Node3D
			if foe.get("dead") == true:
				continue
			# Pooled / inactive enemies (EnemyBase.active == false) never
			# attack. Nodes without an `active` var (test doubles) pass.
			if foe.get("active") == false:
				continue
			var d := center.distance_to(foe.global_position)
			if d > best_d:
				continue
			if not _is_engaged(foe):
				continue
			if not _has_los(foe, center, structure):
				continue
			best = foe
			best_d = d
	return best


static func _structure_half_height(structure: Node3D) -> float:
	if structure.get("bounds_size") != null:
		return float((structure.get("bounds_size") as Vector3).y) * 0.5
	if structure.get("vox_size") != null:
		var vs: Vector3i = structure.get("vox_size")
		var pitch := 0.25
		if structure.get("pitch") != null:
			pitch = float(structure.get("pitch"))
		return float(vs.y) * pitch * 0.5
	return 1.0


static func _is_engaged(foe: Node3D) -> bool:
	if foe.has_method("can_see_player") and bool(foe.call("can_see_player")):
		return true
	if foe.has_method("dist_to_player"):
		return float(foe.call("dist_to_player")) < 25.0
	# No perception API (test doubles): treat as engaged.
	return true


static func _has_los(foe: Node3D, to: Vector3, structure: Node3D) -> bool:
	var world := foe.get_world_3d()
	if world == null:
		return true
	var space := world.direct_space_state
	if space == null:
		return true
	var from := foe.global_position + Vector3(0, EYE_HEIGHT, 0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	if foe is CollisionObject3D:
		query.exclude = [(foe as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider: Object = hit.get("collider")
	if collider == null:
		return true
	if collider == structure:
		return true
	if collider is Node and structure.is_ancestor_of(collider as Node):
		return true
	return false
