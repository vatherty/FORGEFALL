# scripts/puzzles/room_base.gd
# FORGEFALL — Goal 5 (Worker B): shared base for portal puzzle rooms.
#
# A room is a small hand-built arena of plain nodes: static geometry,
# white portal panels, pressure plates, pushable blocks, a sliding door
# and an exit zone. Rooms are built in code (no .tscn) so they load
# headlessly with zero scene dependencies.
#
# VISUAL LANGUAGE (readable at a glance, same in every room):
#   WHITE panels  = portal-able surfaces. Shoot portals here.
#   DARK / RUST / CONCRETE = NOT portal-able. Portals never stick here.
#   ORANGE slab   = pressure plate (needs a block on it to hold a door).
#   ORANGE block  = pushable block (also teleports through portals).
#   GREEN frame   = exit zone. Walk in to finish the room.
#
# PLACEMENT VALIDITY: portal-able panels live on their own StaticBody3D
# (_portal_solids, group "portalable", meta portalable=true); EVERY other
# solid lives on _solids (group "non_portalable", meta portalable=false).
# The portal emitter (Worker C) can therefore refuse non-portal-able
# surfaces with one check: `hit.collider.is_in_group("portalable")`.
# NOTE: this file only MARKS surfaces; the emitter change is Worker C's.
#
# MOMENTUM REQUIREMENT (Worker C): rooms assume the Portal 2 ejection
# contract — a body entering a portal exits moving along +exit normal at
# entry speed (Worker D's M1/M2 contract). The CURRENT emitter code
# rotates velocity instead, which sends the body back into the exit
# surface; until C lands the ejection fix, fling rooms are solvable in
# theory (scripted solver) but not by a live player walk-through.
#
# DEPENDENCIES: none on autoloads (no Sfx / Game references), so rooms
# load under `--script` headless verification. Visuals use VoxelBuilder
# (autoload-free) to keep the voxel "Modern Voxfare 2" style.
#
# SCRIPTED SOLVER: solve() in each room subclass drives the REAL signal
# handlers (press_plate / _on_exit_body_entered) synchronously with the
# same arguments physics would pass, so completion goes through the real
# goal path. No `await` — the solver must finish in one call.
class_name RoomBase
extends Node3D

signal room_done(room_id: String)

# Set by the subclass in _init().
var room_id: String = ""
var room_title: String = ""
var room_objective: String = ""

const PANEL_COLOR := Color(0.96, 0.96, 0.93)  # near-white: portal-able
const WALL_COLOR := Color(0.45, 0.42, 0.38)   # concrete: NOT portal-able
const DARK_COLOR := Color(0.20, 0.20, 0.22)   # gunmetal: NOT portal-able
const RUST_COLOR := Color(0.54, 0.29, 0.16)   # rust: NOT portal-able
const PLATE_COLOR := Color(1.0, 0.48, 0.11)   # forge orange: plate / block
const EXIT_COLOR := Color(0.25, 1.0, 0.45)    # green: exit zone
const GRAVITY := 9.8

var _done: bool = false
var _solids: StaticBody3D = null        # every NON-portal-able collider
var _portal_solids: StaticBody3D = null  # ONLY white-panel colliders
var _plates: Array = []   # Area3D
var _plate_bodies: Dictionary = {}  # plate instance id -> Array[Node3D]
var _plate_tops: Dictionary = {}    # plate instance id -> MeshInstance3D
var _doors: Array = []    # Dictionary {node, body, slab, plates, open}
var _blocks: Array = []   # RigidBody3D
var _block_spawns: Dictionary = {}  # block instance id -> Vector3
var _exit_zone_area: Area3D = null
var _panel_records: Array = []  # {center, normal, size}
var _solid_records: Array = []  # {center, size, color}
var _status_label: Label = null


func _ready() -> void:
	_solids = StaticBody3D.new()
	_solids.name = "Solids"
	_solids.collision_layer = 1
	_solids.collision_mask = 0
	_solids.add_to_group("non_portalable")
	_solids.set_meta("portalable", false)
	add_child(_solids)
	_portal_solids = StaticBody3D.new()
	_portal_solids.name = "PortalPanels"
	_portal_solids.collision_layer = 1
	_portal_solids.collision_mask = 0
	_portal_solids.add_to_group("portalable")
	_portal_solids.set_meta("portalable", true)
	add_child(_portal_solids)
	_build_objective_ui()
	_build_layout()
	_refresh_all()


## Subclasses override this to lay out their room. Base version = empty.
func _build_layout() -> void:
	pass


func _physics_process(_delta: float) -> void:
	_refresh_all()


# ---------------------------------------------------------------- builders

## Solid box. portalable=false (default): dark, on _solids.
## Portal-able panels go through _panel(), never this.
func _box(center: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var vis := VoxelBuilder.cube(size, color, center)
	add_child(vis)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = center
	_solids.add_child(shape)
	_solid_records.append({"center": center, "size": size, "color": color})
	return vis


## White portal-able panel. `normal` is the outward surface normal;
## `size` is the full box (thickness along the normal should be ~0.1).
## The panel sits ON the surface it belongs to.
func _panel(center: Vector3, size: Vector3, normal: Vector3) -> MeshInstance3D:
	var vis := VoxelBuilder.cube(size, PANEL_COLOR, center)
	add_child(vis)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = center
	_portal_solids.add_child(shape)
	_panel_records.append({"center": center, "normal": normal, "size": size})
	return vis


## Pressure plate at floor level. `center` is the plate centre (y ~ 0.05).
## Pressed while a player or a block stands on it.
func _plate(center: Vector3) -> Area3D:
	var area := Area3D.new()
	area.name = "PressurePlate"
	area.position = center
	area.collision_layer = 0
	area.collision_mask = 3  # layer 1 = blocks, layer 2 = player
	area.monitoring = true
	area.add_to_group("pressure_plate")
	area.add_to_group("puzzle_button")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.6, 0.6, 1.6)
	shape.shape = box
	area.add_child(shape)
	add_child(area)
	# Visual: dark base + orange top slab (brightens when pressed).
	var base := VoxelBuilder.cube(Vector3(1.8, 0.12, 1.8), DARK_COLOR, center)
	add_child(base)
	var top := VoxelBuilder.cube(Vector3(1.5, 0.1, 1.5), PLATE_COLOR, center + Vector3(0, 0.1, 0))
	add_child(top)
	_plates.append(area)
	_plate_bodies[area.get_instance_id()] = []
	_plate_tops[area.get_instance_id()] = top
	area.body_entered.connect(_on_plate_entered.bind(area))
	area.body_exited.connect(_on_plate_exited.bind(area))
	return area


## Pushable block (also teleports through portals: RigidBody3D).
func _block(center: Vector3) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.name = "PuzzleBlock"
	rb.position = center
	rb.mass = 5.0
	rb.linear_damp = 0.4
	rb.angular_damp = 0.6
	# Never sleep: a sleeping block teleported (solver / portal) would
	# hang mid-air instead of falling onto its plate. One or two blocks
	# per room makes the cost negligible.
	rb.can_sleep = false
	rb.collision_layer = 1
	rb.collision_mask = 3  # statics (1) + player (2): pushable by walking
	rb.add_to_group("puzzle_cube")
	rb.add_to_group("cube")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.9, 0.9, 0.9)
	shape.shape = box
	rb.add_child(shape)
	var vis := VoxelBuilder.cube(Vector3(0.9, 0.9, 0.9), PLATE_COLOR, Vector3.ZERO)
	rb.add_child(vis)
	add_child(rb)
	_blocks.append(rb)
	_block_spawns[rb.get_instance_id()] = center
	return rb


## Sliding door slab blocking `center`/`size`, held open while every
## plate in `plates` is pressed. Door collision is its own StaticBody3D
## (group non_portalable) so it can be disabled independently.
func _door(center: Vector3, size: Vector3, plates: Array) -> Dictionary:
	var node := Node3D.new()
	node.name = "Door"
	node.position = center
	add_child(node)
	var slab := VoxelBuilder.cube(size, RUST_COLOR, Vector3.ZERO)
	node.add_child(slab)
	var body := StaticBody3D.new()
	body.name = "DoorBody"
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("non_portalable")
	body.set_meta("portalable", false)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	node.add_child(body)
	# Hazard chevrons: emissive strip so the closed door reads as a gate.
	var strip := VoxelBuilder.cube(Vector3(size.x * 0.8, 0.25, 0.12), PLATE_COLOR, Vector3(0, size.y * 0.35, 0))
	node.add_child(strip)
	var rec := {"node": node, "body": body, "slab": slab, "plates": plates, "open": false}
	_doors.append(rec)
	return rec


## Exit zone: a green-framed sphere. Any player body entering finishes.
func _exit_zone(center: Vector3, radius: float = 1.6) -> Area3D:
	var area := Area3D.new()
	area.name = "ExitZone"
	area.position = center
	area.collision_layer = 0
	area.collision_mask = 2  # player layer only: blocks must NOT finish
	area.monitoring = true
	area.add_to_group("puzzle_goal")
	area.add_to_group("goal")
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape.shape = sphere
	area.add_child(shape)
	add_child(area)
	# Green voxel frame ring (4 corner cubes + emissive centre marker).
	for off in [Vector3(-radius, 0, 0), Vector3(radius, 0, 0), Vector3(0, radius, 0), Vector3(0, -radius, 0)]:
		add_child(VoxelBuilder.cube(Vector3(0.3, 0.3, 0.3), EXIT_COLOR, center + off))
	var marker := VoxelBuilder.cube(Vector3(0.4, 0.4, 0.4), EXIT_COLOR, center)
	add_child(marker)
	_exit_zone_area = area
	area.body_entered.connect(_on_exit_body_entered)
	return area


## Player spawn marker (Main spawns the player at a "player_spawn" marker).
func _spawn_marker(pos: Vector3) -> Marker3D:
	var m := Marker3D.new()
	m.name = "PlayerSpawn"
	m.position = pos
	m.add_to_group("player_spawn")
	add_child(m)
	return m


# ---------------------------------------------------------------- plate/door logic

func _on_plate_entered(body: Node3D, plate: Area3D) -> void:
	press_plate(plate, body)


func _on_plate_exited(body: Node3D, plate: Area3D) -> void:
	release_plate(plate, body)


## Same code path the body_entered signal calls — the scripted solver
## invokes this directly (synchronous) with the same arguments.
func press_plate(plate: Area3D, body: Node3D) -> void:
	if not _is_plate_body(body):
		return
	var arr: Array = _plate_bodies.get(plate.get_instance_id(), [])
	if not arr.has(body):
		arr.append(body)
		_plate_bodies[plate.get_instance_id()] = arr
	_refresh_all()


## Same code path the body_exited signal calls.
func release_plate(plate: Area3D, body: Node3D) -> void:
	var arr: Array = _plate_bodies.get(plate.get_instance_id(), [])
	arr.erase(body)
	_plate_bodies[plate.get_instance_id()] = arr
	_refresh_all()


func _is_plate_body(body: Node3D) -> bool:
	return body.is_in_group("player") or body.is_in_group("puzzle_cube")


func is_plate_pressed(plate: Area3D) -> bool:
	var arr: Array = _plate_bodies.get(plate.get_instance_id(), [])
	return not arr.is_empty()


func _refresh_all() -> void:
	for plate in _plates:
		var top: MeshInstance3D = _plate_tops.get(plate.get_instance_id())
		if top != null:
			# Pressed-in look: the slab sinks when a body stands on it.
			# (Position, not material — VoxelBuilder materials are shared.)
			top.position.y = 0.05 if is_plate_pressed(plate) else 0.1
	for d in _doors:
		var should_open := true
		for plate in (d["plates"] as Array):
			if not is_plate_pressed(plate):
				should_open = false
				break
		if should_open != bool(d["open"]):
			d["open"] = should_open
			var body: StaticBody3D = d["body"]
			var slab: MeshInstance3D = d["slab"]
			if should_open:
				body.collision_layer = 0
				slab.visible = false
			else:
				body.collision_layer = 1
				slab.visible = true


func door_open(door_idx: int) -> bool:
	if door_idx < 0 or door_idx >= _doors.size():
		return false
	return bool(_doors[door_idx]["open"])


# ---------------------------------------------------------------- completion

func _on_exit_body_entered(body: Node3D) -> void:
	# Only the player finishes a room. Blocks are RigidBody3D and never
	# carry the "player" group, so a block tossed into the exit does not
	# complete anything.
	if body.is_in_group("player"):
		_finish_room()


func _finish_room() -> void:
	if _done:
		return
	_done = true
	CompletionStore.mark_done(room_id)
	if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("puzzle_complete", {"room_id": room_id})
	if _status_label != null:
		_status_label.text = "ROOM COMPLETE  ✓"
		_status_label.modulate = EXIT_COLOR
	room_done.emit(room_id)


func check_done() -> bool:
	return _done


## Reset for replay: completion clears, blocks return to spawn, doors close.
func reset_room() -> void:
	_done = false
	for plate in _plates:
		_plate_bodies[plate.get_instance_id()] = []
	for rb in _blocks:
		var home: Vector3 = _block_spawns.get(rb.get_instance_id(), Vector3.ZERO)
		rb.global_position = home
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		rb.global_rotation = Vector3.ZERO
	if _status_label != null:
		_status_label.text = "INCOMPLETE"
		_status_label.modulate = Color(1, 1, 1)
	_refresh_all()


# ---------------------------------------------------------------- queries (verify + solver)

func panels() -> Array:
	return _panel_records.duplicate()


func solid_records() -> Array:
	return _solid_records.duplicate()


func plates_list() -> Array:
	return _plates.duplicate()


func doors_list() -> Array:
	return _doors.duplicate()


func blocks_list() -> Array:
	return _blocks.duplicate()


func exit_zone() -> Area3D:
	return _exit_zone_area


## Dummy player body for the scripted solver: a CharacterBody3D in the
## "player" group, so it passes the same exit-zone check a real player
## would. Added to the room so global transforms resolve.
func dummy_player(pos: Vector3) -> CharacterBody3D:
	var b := CharacterBody3D.new()
	b.name = "SolverPlayer"
	b.global_position = pos
	b.add_to_group("player")
	add_child(b)
	return b


## Ballistic fling under the Portal 2 ejection contract:
## entry_speed (fall speed into the entry portal) becomes exit speed along
## +exit_normal. Returns {exit_velocity, flight_time, landing, reaches}.
## `goal_top_y` / `goal_x_range` / `goal_z_range` describe the landing pad.
func simulate_fling(entry_speed: float, exit_pos: Vector3, exit_normal: Vector3,
		goal_top_y: float, goal_x_range: Vector2, goal_z_range: Vector2) -> Dictionary:
	var exit_vel := exit_normal * entry_speed
	# Analytic landing: solve y(t) = goal_top_y for the falling branch.
	var dy := exit_pos.y - goal_top_y
	var t: float = 0.0
	if dy >= 0.0:
		t = sqrt(2.0 * dy / GRAVITY)
	else:
		# Exit below the pad: rises first — not a supported fling shape.
		t = 0.0
	var landing := exit_pos + exit_vel * t + Vector3(0, -0.5 * GRAVITY * t * t, 0)
	var reaches := landing.x >= goal_x_range.x and landing.x <= goal_x_range.y \
		and landing.z >= goal_z_range.x and landing.z <= goal_z_range.y
	return {"exit_velocity": exit_vel, "flight_time": t, "landing": landing, "reaches": reaches}


# ---------------------------------------------------------------- objective UI

func _build_objective_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ObjectiveUI"
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var title := Label.new()
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 18
	title.offset_bottom = 58
	title.offset_left = 18
	title.offset_right = 700
	title.text = room_title
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1, 1, 1))
	root.add_child(title)
	var obj := Label.new()
	obj.set_anchors_preset(Control.PRESET_TOP_WIDE)
	obj.offset_top = 58
	obj.offset_bottom = 110
	obj.offset_left = 18
	obj.offset_right = 900
	obj.text = room_objective
	obj.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	obj.add_theme_font_size_override("font_size", 20)
	obj.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	root.add_child(obj)
	_status_label = Label.new()
	_status_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_status_label.offset_top = 18
	_status_label.offset_bottom = 58
	_status_label.offset_left = -260
	_status_label.offset_right = -18
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_label.text = "INCOMPLETE"
	_status_label.add_theme_font_size_override("font_size", 22)
	root.add_child(_status_label)
	var back := Button.new()
	back.text = "BACK TO MENU"
	back.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	back.offset_left = 18
	back.offset_bottom = -18
	back.offset_top = -62
	back.offset_right = 230
	back.add_theme_font_size_override("font_size", 20)
	back.pressed.connect(_on_back_to_menu)
	root.add_child(back)


func _on_back_to_menu() -> void:
	var main: Node = get_tree().get_first_node_in_group("game_root")
	if main != null and main.has_method("quit_to_menu"):
		main.quit_to_menu()
