extends SceneTree

## Headless exercise of character_motion.gd: a built character patrols
## between two "waypoint" markers over a navigation region, its box rig
## visibly walks (leg swing, counter-phase, body bob, phase progression),
## chases a player that steps into sight, returns home when the player
## vanishes, resumes patrol, and eases back to the authored pose at rest.

const Content = preload("res://content_document.gd")
const Runtime = preload("res://content_runtime.gd")

var failures := 0
var transitions: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# Document schema: walk parameters validated, limb roles validated.
	var doc: Dictionary = Content.new_character("Walker")
	doc["parts"] = [
		{"name": "Body", "parent": "", "position": [0.0, 0.95, 0.0], "size": [0.5, 0.7, 0.3], "color": "#8298a8"},
		{"name": "LegLeft", "parent": "", "position": [-0.15, 0.55, 0.0], "size": [0.18, 0.55, 0.2], "color": "#5a6a76", "limb": "leg_left"},
		{"name": "LegRight", "parent": "", "position": [0.15, 0.55, 0.0], "size": [0.18, 0.55, 0.2], "color": "#5a6a76", "limb": "leg_right"},
		{"name": "ArmLeft", "parent": "Body", "position": [-0.35, 0.25, 0.0], "size": [0.14, 0.5, 0.16], "color": "#8298a8"},
		{"name": "ArmRight", "parent": "Body", "position": [0.35, 0.25, 0.0], "size": [0.14, 0.5, 0.16], "color": "#8298a8"},
		{"name": "Hand", "parent": "Body", "position": [0.35, -0.2, -0.1], "size": [0.15, 0.15, 0.15], "color": "#d5b595"},
	]
	_check(Content.validate(doc) == "", "character schema with walk params and limb roles")
	var bad := doc.duplicate(true)
	bad["stride_length"] = -1.0
	_check(Content.validate(bad) != "", "reject negative stride length")
	bad = doc.duplicate(true)
	bad["parts"][1]["limb"] = "tail"
	_check(Content.validate(bad) != "", "reject unknown limb role")

	# World: floor, navigation region, two patrol markers, distant player.
	var world := Node3D.new()
	root.add_child(world)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(60, 1, 60)
	floor_shape.shape = floor_box
	floor_shape.position.y = -0.5
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)
	var nav_mesh := NavigationMesh.new()
	nav_mesh.vertices = PackedVector3Array([Vector3(-25, 0, -25), Vector3(-25, 0, 25), Vector3(25, 0, 25), Vector3(25, 0, -25)])
	nav_mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	var region := NavigationRegion3D.new()
	region.navigation_mesh = nav_mesh
	world.add_child(region)
	for marker_data in [["WaypointA", Vector3(-6, 0, 0)], ["WaypointB", Vector3(6, 0, 0)]]:
		var marker := Marker3D.new()
		marker.name = marker_data[0]
		marker.position = marker_data[1]
		marker.add_to_group("waypoint")
		world.add_child(marker)
	var player := Node3D.new()
	player.name = "Player"
	player.position = Vector3(0, 0, 100)
	player.add_to_group("player")
	world.add_child(player)

	var character := Runtime.build_character(doc)
	_check(character != null, "build character")
	var motion: Node = character.get_node_or_null("CharacterMotion")
	_check(motion != null, "character has CharacterMotion component")
	motion.set("idle_duration", 0.2)
	motion.set("lose_delay", 0.3)
	character.position = Vector3(0, 0.1, 0)
	world.add_child(character)
	var leg_left := character.get_node("LegLeft") as Node3D
	var leg_right := character.get_node("LegRight") as Node3D
	var body_part := character.get_node("Body") as Node3D
	_watch(motion)
	for frame in 5:
		await physics_frame
		_watch(motion)
	_check(motion.get("state") == "idle", "starts idle (got %s)" % motion.get("state"))
	_check((motion.get("patrol_waypoints") as Array).size() == 2, "patrol waypoints collected from markers")

	# idle -> patrol, then the rig must visibly walk while it moves.
	_check(await _until(motion, "patrol", 120), "idle -> patrol")
	var start_position := character.global_position
	var phase_start := float(motion.get("walk_phase"))
	var leg_min := INF
	var leg_max := -INF
	var bob_min := INF
	var bob_max := -INF
	var counter_phase_ok := false
	for frame in 90:
		await physics_frame
		_watch(motion)
		leg_min = minf(leg_min, leg_left.rotation.x)
		leg_max = maxf(leg_max, leg_left.rotation.x)
		bob_min = minf(bob_min, body_part.position.y)
		bob_max = maxf(bob_max, body_part.position.y)
		if absf(leg_left.rotation.x) > 0.05 and absf(leg_left.rotation.x + leg_right.rotation.x) < 0.05:
			counter_phase_ok = true
	_check(character.global_position.distance_to(start_position) > 1.5, "character patrols (moved %.2f m)" % character.global_position.distance_to(start_position))
	_check(leg_max - leg_min > 0.1, "leg swing varies (range %.3f rad)" % (leg_max - leg_min))
	_check(counter_phase_ok, "legs swing in counter-phase")
	_check(bob_max - bob_min > 0.005, "body bobs while walking (range %.4f m)" % (bob_max - bob_min))
	_check(float(motion.get("walk_phase")) != phase_start, "walk phase progresses with movement")

	# patrol -> chase when the player steps into sight.
	player.position = character.global_position + Vector3(3, 0, 0)
	_check(await _until(motion, "chase", 60), "patrol -> chase on sight")
	var chase_from := character.global_position.distance_to(player.position)
	for frame in 45:
		await physics_frame
		_watch(motion)
	_check(character.global_position.distance_to(player.position) < chase_from - 0.5, "character closes on player")

	# chase -> return when the player vanishes, then return -> patrol.
	player.position = Vector3(0, 0, 200)
	_check(await _until(motion, "return", 120), "chase -> return after losing player")
	_check(await _until(motion, "patrol", 1200), "return -> patrol at home")
	var order := ["idle", "patrol", "chase", "return", "patrol"]
	var cursor := 0
	for seen_state in transitions:
		if cursor < order.size() and seen_state == order[cursor]:
			cursor += 1
	_check(cursor == order.size(), "state sequence idle->patrol->chase->return->patrol (saw %s)" % str(transitions))

	# At rest the rig eases back to the authored pose.
	motion.set("patrol_waypoints", [])
	motion.set("state", "idle")
	for frame in 90:
		await physics_frame
	_check(absf(leg_left.rotation.x) < 0.02 and absf(leg_right.rotation.x) < 0.02, "rig restores authored pose at rest")
	_check(absf(body_part.position.y - 0.95) < 0.01, "body restores authored height at rest")

	world.free()
	_check(Node.get_orphan_node_ids().is_empty(), "no orphaned nodes")
	print("Character motion checks: %d failure(s)" % failures)
	call_deferred("_finish")

func _until(motion: Node, wanted: String, max_frames: int) -> bool:
	for frame in max_frames:
		await physics_frame
		_watch(motion)
		if motion.get("state") == wanted:
			return true
	return false

func _watch(motion: Node) -> void:
	var current := str(motion.get("state"))
	if transitions.is_empty() or transitions[-1] != current:
		transitions.append(current)

func _finish() -> void:
	quit(0 if failures == 0 else 1)

func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		failures += 1
		push_error("FAIL: " + label)
