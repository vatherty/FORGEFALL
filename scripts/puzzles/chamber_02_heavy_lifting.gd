# scripts/puzzles/chamber_02_heavy_lifting.gd
# FORGEFALL — Goal 5 (Worker B): Room 2 — HEAVY LIFTING.
# Teaches blocks + pressure plates: a door stays open ONLY while a block
# holds its plate. A player standing on the plate opens the door too —
# but stepping off to walk through closes it, so the block is required.
# The two white panels are in the START room only, so portals can move
# the player / block around the start room but can never bypass the door
# (no portal-able surface exists past it).
class_name Chamber02HeavyLifting
extends RoomBase

var _plate_ref: Area3D = null
var _cube_ref: RigidBody3D = null
var _door_idx := 0


func _init() -> void:
	room_id = "chamber_02"
	room_title = "2 — HEAVY LIFTING"
	room_objective = "Push the orange block onto the orange plate to hold the door open, then walk through to the green exit."


func _build_layout() -> void:
	_box(Vector3(0, -0.25, 0), Vector3(26, 0.5, 12), WALL_COLOR)
	_box(Vector3(0, 2, -6), Vector3(26, 4, 0.6), WALL_COLOR)
	_box(Vector3(0, 2, 6), Vector3(26, 4, 0.6), WALL_COLOR)
	_box(Vector3(-13, 2, 0), Vector3(0.6, 4, 12), WALL_COLOR)
	_box(Vector3(13, 2, 0), Vector3(0.6, 4, 12), WALL_COLOR)
	# Door wall at x = 2 with a 2 m gap (z -1..1) + lintel above it.
	_box(Vector3(2, 2, -3.5), Vector3(0.6, 4, 5), DARK_COLOR)
	_box(Vector3(2, 2, 3.5), Vector3(0.6, 4, 5), DARK_COLOR)
	_box(Vector3(2, 3.5, 0), Vector3(0.6, 1.0, 2), DARK_COLOR)
	# Panels: start room only (west wall + door-wall west face).
	_panel(Vector3(-12.65, 1.8, 0), Vector3(0.1, 2.4, 2.4), Vector3(1, 0, 0))
	_panel(Vector3(1.65, 1.8, -3), Vector3(0.1, 2.4, 2.4), Vector3(-1, 0, 0))
	# Plate + block + door. Door opens while the plate is held.
	_plate_ref = _plate(Vector3(-2, 0.05, 3))
	_cube_ref = _block(Vector3(-6, 0.5, -3))
	_door_idx = doors_list().size()
	_door(Vector3(2, 1.5, 0), Vector3(0.6, 3.0, 2.0), [_plate_ref])
	_spawn_marker(Vector3(-9, 0.5, 0))
	_exit_zone(Vector3(9, 0.5, 0), 1.6)


## Scripted solution: put the block on the plate (real plate handler),
## confirm the door opens, walk a dummy player through to the exit
## (real exit-zone handler).
func solve() -> void:
	_cube_ref.global_position = Vector3(-2, 0.5, 3)
	press_plate(_plate_ref, _cube_ref)
	var dummy := dummy_player(Vector3(9, 0.5, 0))
	_on_exit_body_entered(dummy)
	dummy.queue_free()


func solution_steps() -> Array:
	return [
		"Push the orange block onto the orange plate.",
		"The door opens while the block holds the plate — do not move the block off.",
		"Walk through the door to the green exit.",
	]


func is_complete() -> bool:
	return check_done()


func reset() -> void:
	reset_room()
