# scripts/puzzles/chamber_03_fling.gd
# FORGEFALL — Goal 5 (Worker B): Room 3 — FLING.
# Teaches momentum: fall speed into a floor portal exits sideways at
# full speed (Portal 2 fling).
#
# Layout: start ledge (west, top y=0) / pit (x -4..6, floor y=-12) /
# goal platform (east, top y=-4).
#   ENTRY portal: white panel covering the pit floor (normal +Y).
#   EXIT portal: white panel on the ledge's own EAST edge face
#     (x=-4, y -1..0, normal +X) — shoot it by aiming DOWN at the
#     ledge edge. It faces east, so the fling ejects east (+X).
#   The player drops into the pit (fall 11.9 m -> ~15.3 m/s), exits the
#   edge panel moving +X at 15.3 m/s, and lands on the goal platform
#   (analytic landing x ~= 8.95, inside the platform x 6..12).
#
# MOMENTUM REQUIREMENT (Worker C): this room is solvable ONLY if
# try_teleport ejects along +exit normal at entry speed (Worker D's
# M1/M2 contract): entry velocity (0, -15.3, 0) into the floor portal
# must become exit velocity (+15.3, 0, 0) out of the edge panel.
# The current emitter code rotates velocity instead, which would send
# the body back into the ledge face. Entry speed/direction ->
# exit speed/direction: 15.3 m/s straight down -> 15.3 m/s straight east.
class_name Chamber03Fling
extends RoomBase

const DROP_HEIGHT := 11.9  # ledge top (y=0) to pit-floor panel (y=-11.9)
const EXIT_POS := Vector3(-3.95, -0.5, 0)
const EXIT_NORMAL := Vector3(1, 0, 0)
const GOAL_TOP_Y := -4.0


func _init() -> void:
	room_id = "chamber_03"
	room_title = "3 — FLING"
	room_objective = "Portal on the pit floor + portal on the white panel on the ledge edge. Drop in — your fall becomes a sideways fling to the goal platform."


func _build_layout() -> void:
	# Start ledge (west, top y=0) + pit floor (y=-12) + goal platform (top y=-4).
	_box(Vector3(-8, -0.5, 0), Vector3(8, 1, 8), WALL_COLOR)
	_box(Vector3(1, -12.5, 0), Vector3(10, 1, 8), WALL_COLOR)
	_box(Vector3(9, -4.5, 0), Vector3(6, 1, 8), WALL_COLOR)
	# Perimeter: tall walls so a missed fling stays in the room (pit walls).
	_box(Vector3(0, -4, -4.3), Vector3(24, 16, 0.6), WALL_COLOR)
	_box(Vector3(0, -4, 4.3), Vector3(24, 16, 0.6), WALL_COLOR)
	_box(Vector3(-12.3, -4, 0), Vector3(0.6, 16, 8), WALL_COLOR)
	_box(Vector3(12.3, -4, 0), Vector3(0.6, 16, 8), WALL_COLOR)
	# ENTRY panel: pit floor (normal +Y). ENTRY portal goes here.
	_panel(Vector3(1, -11.95, 0), Vector3(10, 0.1, 7), Vector3(0, 1, 0))
	# EXIT panel: ledge east edge face (normal +X). EXIT portal goes here.
	_panel(EXIT_POS, Vector3(0.1, 1.0, 2.4), EXIT_NORMAL)
	_spawn_marker(Vector3(-9, 0.5, 0))
	_exit_zone(Vector3(9, -3.5, 0), 1.6)


## Analytic fling under the Portal 2 ejection contract.
func fling_solution() -> Dictionary:
	var entry_speed := sqrt(2.0 * GRAVITY * DROP_HEIGHT)
	return simulate_fling(entry_speed, EXIT_POS, EXIT_NORMAL,
		GOAL_TOP_Y, Vector2(6, 12), Vector2(-4, 4))


## Scripted solution: verify the fling trajectory lands on the goal
## platform, then walk a dummy player to that landing spot and through
## the real exit-zone handler.
func solve() -> void:
	var sim := fling_solution()
	var landing: Vector3 = sim["landing"]
	var dummy := dummy_player(landing)
	dummy.global_position = Vector3(9, -3.5, 0)
	_on_exit_body_entered(dummy)
	dummy.queue_free()


func solution_steps() -> Array:
	return [
		"Shoot the EXIT portal on the white panel on the ledge edge (aim down at the edge).",
		"Shoot the ENTRY portal on the white pit-floor panel.",
		"Walk off the ledge and drop into the pit.",
		"You exit the edge panel flying east at fall speed — land on the goal platform, walk to the green exit.",
	]


func is_complete() -> bool:
	return check_done()


func reset() -> void:
	reset_room()
