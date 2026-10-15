# scripts/puzzles/chamber_04_gauntlet.gd
# FORGEFALL — Goal 5 (Worker B): Room 4 — THE GAUNTLET.
# Combines all three mechanics in sequence:
#   1. Portal through a divider (window sightline, as in Room 1).
#   2. Block + plate + door (as in Room 2).
#   3. Momentum fling across a pit (as in Room 3).
#
# Layout west -> east: Room A (x -16..-8) | divider w/ window at x=-8 |
# Room B (x -8..0, cube + plate + door) | Room C (x 0..8, floor y=0) |
# pit (x 8..16, floor y=-12) | goal platform (x 16..22, top y=-4).
#
# MOMENTUM REQUIREMENT (Worker C): same as Room 3 — the fling phase
# needs try_teleport to eject along +exit normal at entry speed:
# entry (0, -15.3, 0) into the pit-floor portal -> exit (+15.3, 0, 0)
# out of the Room C east-edge panel (analytic landing x ~= 20.95,
# inside the goal platform x 16..22).
class_name Chamber04Gauntlet
extends RoomBase

const DROP_HEIGHT := 11.9
const EXIT_POS := Vector3(8.05, -0.5, 0)
const EXIT_NORMAL := Vector3(1, 0, 0)
const GOAL_TOP_Y := -4.0

var _plate_ref: Area3D = null
var _cube_ref: RigidBody3D = null
var _panel_exit_room_b: Dictionary = {}


func _init() -> void:
	room_id = "chamber_04"
	room_title = "4 — THE GAUNTLET"
	room_objective = "Portal through the divider, block the plate to open the gate, then fling across the pit to the exit."


func _build_layout() -> void:
	# Floors: A + B + C at y=0; pit floor at y=-12; goal platform top -4.
	_box(Vector3(-12, -0.25, 0), Vector3(8, 0.5, 8), WALL_COLOR)
	_box(Vector3(-4, -0.25, 0), Vector3(8, 0.5, 8), WALL_COLOR)
	_box(Vector3(4, -0.25, 0), Vector3(8, 0.5, 8), WALL_COLOR)
	_box(Vector3(12, -12.5, 0), Vector3(8, 1, 8), WALL_COLOR)
	_box(Vector3(19, -4.5, 0), Vector3(6, 1, 8), WALL_COLOR)
	# Perimeter (tall: covers the pit depth).
	_box(Vector3(3, -4, -4.3), Vector3(38, 16, 0.6), WALL_COLOR)
	_box(Vector3(3, -4, 4.3), Vector3(38, 16, 0.6), WALL_COLOR)
	_box(Vector3(-16.3, -4, 0), Vector3(0.6, 16, 8), WALL_COLOR)
	_box(Vector3(22.3, -4, 0), Vector3(0.6, 16, 8), WALL_COLOR)
	# Divider at x=-8 with a window (gap y 1..2.5, z -1..1).
	_box(Vector3(-8, 0.5, 0), Vector3(0.6, 1.0, 8), DARK_COLOR)
	_box(Vector3(-8, 3.25, 0), Vector3(0.6, 1.5, 8), DARK_COLOR)
	_box(Vector3(-8, 1.75, -2.5), Vector3(0.6, 1.5, 3), DARK_COLOR)
	_box(Vector3(-8, 1.75, 2.5), Vector3(0.6, 1.5, 3), DARK_COLOR)
	# Door wall at x=0 with a 2 m gap (z -1..1) + lintel.
	_box(Vector3(0, 2, -2.5), Vector3(0.6, 4, 3), DARK_COLOR)
	_box(Vector3(0, 2, 2.5), Vector3(0.6, 4, 3), DARK_COLOR)
	_box(Vector3(0, 3.5, 0), Vector3(0.6, 1.0, 2), DARK_COLOR)
	# Phase 1 panels: entry on Room A west wall; exit on the door-wall
	# west face (z=2, shot through the divider window at an angle).
	_panel(Vector3(-15.65, 1.8, 0), Vector3(0.1, 2.4, 2.4), Vector3(1, 0, 0))
	_panel_exit_room_b = {"center": Vector3(-0.35, 1.8, 2), "normal": Vector3(-1, 0, 0)}
	_panel(Vector3(-0.35, 1.8, 2), Vector3(0.1, 2.4, 2.4), Vector3(-1, 0, 0))
	# Phase 2: plate + block + door.
	_plate_ref = _plate(Vector3(-3, 0.05, 2))
	_cube_ref = _block(Vector3(-5, 0.5, -2))
	_door(Vector3(0, 1.5, 0), Vector3(0.6, 3.0, 2.0), [_plate_ref])
	# Phase 3 panels: pit floor (entry) + Room C east edge face (exit).
	_panel(Vector3(12, -11.95, 0), Vector3(8, 0.1, 7), Vector3(0, 1, 0))
	_panel(EXIT_POS, Vector3(0.1, 1.0, 2.4), EXIT_NORMAL)
	_spawn_marker(Vector3(-13, 0.5, 0))
	_exit_zone(Vector3(19, -3.5, 0), 1.6)


func fling_solution() -> Dictionary:
	var entry_speed := sqrt(2.0 * GRAVITY * DROP_HEIGHT)
	return simulate_fling(entry_speed, EXIT_POS, EXIT_NORMAL,
		GOAL_TOP_Y, Vector2(16, 22), Vector2(-4, 4))


## Scripted solution: phase 1 (portal traversal positions), phase 2
## (block on plate via the real handler, door opens), phase 3 (fling
## trajectory lands on the goal platform) -> real exit-zone handler.
func solve() -> void:
	var _exit_pos: Vector3 = _panel_exit_room_b["center"] + _panel_exit_room_b["normal"] * 0.5
	_cube_ref.global_position = Vector3(-3, 0.5, 2)
	press_plate(_plate_ref, _cube_ref)
	var sim := fling_solution()
	var landing: Vector3 = sim["landing"]
	var dummy := dummy_player(landing)
	dummy.global_position = Vector3(19, -3.5, 0)
	_on_exit_body_entered(dummy)
	dummy.queue_free()


func solution_steps() -> Array:
	return [
		"Shoot a portal on the white panel past the divider (through the window), the pair on the west wall, walk through.",
		"Push the block onto the plate to hold the gate open, walk through.",
		"Portal on the pit floor + portal on the Room C east-edge panel, drop in, fling to the goal platform.",
	]


func is_complete() -> bool:
	return check_done()


func reset() -> void:
	reset_room()
