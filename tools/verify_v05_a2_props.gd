# verify_v05_a2_props.gd — A2 Dustline dressing-props validation (headless).
# Usage: godot --headless --path <project> --script res://tools/verify_v05_a2_props.gd
# Asserts: props scene instantiates cleanly, prop count within cap, every
# solid prop has a collision shape nearby, all collision within arena bounds,
# no collision near player spawns / spawn doors / rooftop stair routes,
# draw-call growth small (<= 3 MultiMeshInstance3D nodes). Exit 0 = PASS.
extends SceneTree

const ARENA_HALF := 35.0
const MAX_PROPS := 40
const MAX_MULTIMESH_NODES := 3
const SPAWN_CLEAR := 2.0
const DOOR_CLEAR := 2.0

# Mirrored from dustline_builder.gd (read-only reference).
const PLAYER_SPAWNS := [
	Vector3(-30, 0.3, -30), Vector3(30, 0.3, -30), Vector3(-30, 0.3, 30),
	Vector3(30, 0.3, 30), Vector3(0, 0.3, 29),
]
const SPAWN_DOORS := [
	Vector3(-24, 0, -33.6), Vector3(-8, 0, -33.6), Vector3(8, 0, -33.6),
	Vector3(24, 0, -33.6), Vector3(-16, 0, 33.6), Vector3(16, 0, 33.6),
	Vector3(33.6, 0, 0),
]
# Rooftop stair routes: +x side steps of the four 3 m roof shacks.
# Each entry: [min_x, max_x, min_z, max_z] footprint to keep clear (with margin).
const STAIR_ZONES := [
	[-9.2, -5.6, -23.2, -20.8],  # shack (-11,-22)
	[-4.2, -0.6, 20.8, 23.2],  # shack (-6,22)
	[-24.2, -20.6, -7.2, -4.8],  # shack (-26,-6)
	[28.6, 32.0, 2.8, 5.2],  # shack (26,4)
]

var _failures: Array = []


func _initialize() -> void:
	var ps := load("res://scenes/maps/dustline_props.tscn") as PackedScene
	if ps == null:
		_fail("props scene failed to load")
		_report()
		quit(1)
		return
	var props := ps.instantiate()
	root.add_child(props)
	# _ready() runs on add_child; verify in the next frame via _process.
	_props = props
	_frame = 0


var _props: Node = null
var _frame := 0


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 2:
		return false
	_check(_props)
	_report()
	quit(1 if _failures.size() > 0 else 0)
	return true


func _check(props: Node) -> void:
	if props == null:
		_fail("props instance is null")
		return
	if props.get_script() == null:
		_fail("props instance has no script — props script failed to load (see SCRIPT ERROR above)")
		return
	# Prop count within cap (untyped reads: a broken script yields Nil).
	var prop_count = props.get("prop_count")
	var collision_count = props.get("collision_count")
	var mm_total = props.get("multimesh_instance_total")
	if prop_count == null or collision_count == null or mm_total == null:
		_fail("props script did not expose prop_count/collision_count/multimesh_instance_total")
		return
	print("PROPS: prop_count=", prop_count, " collision_shapes=", collision_count,
		" multimesh_instances=", mm_total)
	if prop_count <= 0:
		_fail("prop_count is 0 — props did not build")
	if prop_count > MAX_PROPS:
		_fail("prop_count %d exceeds cap %d" % [prop_count, MAX_PROPS])
	if collision_count < prop_count:
		_fail("collision shapes (%d) fewer than solid props (%d)" % [collision_count, prop_count])

	# Draw-call growth: count MultiMeshInstance3D nodes.
	var acc := {"mm": 0, "bodies": 0}
	var shapes: Array = []
	_collect(props, acc, shapes)
	var mm_nodes: int = acc["mm"]
	var bodies: int = acc["bodies"]
	print("PROPS: multimesh_nodes=", mm_nodes, " static_bodies=", bodies,
		" collision_shapes_found=", shapes.size())
	if mm_nodes > MAX_MULTIMESH_NODES:
		_fail("multimesh nodes %d exceed cap %d" % [mm_nodes, MAX_MULTIMESH_NODES])
	if shapes.size() != collision_count:
		_fail("shape walk found %d but script reported %d" % [shapes.size(), collision_count])
	if mm_total <= 0:
		_fail("multimesh_instance_total is 0 — no prop visuals built")

	# Every solid prop center must have a collision shape nearby (<= 1.5 m).
	var centers: Array = props.get("solid_centers")
	for c in centers:
		var center: Vector3 = c
		var ok := false
		for s in shapes:
			var cs: CollisionShape3D = s
			if cs.global_position.distance_to(center) <= 1.5:
				ok = true
				break
		if not ok:
			_fail("solid prop at %s has no collision shape nearby" % str(center))

	# Every collision shape: inside arena, clear of spawns / doors / stairs.
	for s in shapes:
		var cs: CollisionShape3D = s
		var p: Vector3 = cs.global_position
		if absf(p.x) > ARENA_HALF or absf(p.z) > ARENA_HALF:
			_fail("collision at %s outside arena bounds" % str(p))
		for sp in PLAYER_SPAWNS:
			var d := Vector2(p.x - sp.x, p.z - sp.z).length()
			if d < SPAWN_CLEAR:
				_fail("collision at %s within %.1f m of player spawn %s" % [str(p), SPAWN_CLEAR, str(sp)])
		for dp in SPAWN_DOORS:
			var d := Vector2(p.x - dp.x, p.z - dp.z).length()
			if d < DOOR_CLEAR:
				_fail("collision at %s within %.1f m of spawn door %s" % [str(p), DOOR_CLEAR, str(dp)])
		for z in STAIR_ZONES:
			if p.x >= z[0] and p.x <= z[1] and p.z >= z[2] and p.z <= z[3]:
				_fail("collision at %s inside rooftop stair zone %s" % [str(p), str(z)])


func _collect(node: Node, acc: Dictionary, shapes: Array) -> void:
	if node is MultiMeshInstance3D:
		acc["mm"] += 1
	if node is StaticBody3D:
		acc["bodies"] += 1
	if node is CollisionShape3D:
		shapes.append(node)
	for child in node.get_children():
		_collect(child, acc, shapes)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("PROPS FAIL: ", msg)


func _report() -> void:
	if _failures.size() == 0:
		print("PROPS: PASS — all checks green")
	else:
		print("PROPS: FAIL — ", _failures.size(), " failure(s)")
