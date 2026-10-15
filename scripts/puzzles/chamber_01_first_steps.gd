# scripts/puzzles/chamber_01_first_steps.gd
# FORGEFALL — Goal 5 (Worker B): Room 1 — FIRST STEPS.
# Teaches portal basics: place a pair, walk through.
#
# Layout: start room (west) / goal room (east), split by a divider with
# a WINDOW in it (gap y 1..2.5, z -1..1 — 1.5 m tall, so the 1.7 m
# player capsule can never walk through it; it is a sightline only).
# Through the window the player can see + shoot the white panel on the
# goal room's EAST wall. The entry panel is on the start room's WEST
# wall. Walk into the west-wall portal -> exit at the east-wall panel,
# now standing in the goal room -> walk to the green exit.
# The divider itself is dark / non-portal-able: portals never stick to it.
class_name Chamber01FirstSteps
extends RoomBase

var _panel_entry: Dictionary = {}
var _panel_exit: Dictionary = {}


func _init() -> void:
	room_id = "chamber_01"
	room_title = "1 — FIRST STEPS"
	room_objective = "Shoot one portal on the white panel ahead (through the window), the other on the white panel behind you, then walk through it."


func _build_layout() -> void:
	# Floor + perimeter (dark, non-portal-able).
	_box(Vector3(0, -0.25, 0), Vector3(26, 0.5, 12), WALL_COLOR)
	_box(Vector3(0, 2, -6), Vector3(26, 4, 0.6), WALL_COLOR)
	_box(Vector3(0, 2, 6), Vector3(26, 4, 0.6), WALL_COLOR)
	_box(Vector3(-13, 2, 0), Vector3(0.6, 4, 12), WALL_COLOR)
	_box(Vector3(13, 2, 0), Vector3(0.6, 4, 12), WALL_COLOR)
	# Divider at x = 0 with a window (see header). Four segments.
	_box(Vector3(0, 0.5, 0), Vector3(0.6, 1.0, 12), DARK_COLOR)      # below window
	_box(Vector3(0, 3.25, 0), Vector3(0.6, 1.5, 12), DARK_COLOR)     # above window
	_box(Vector3(0, 1.75, -3.5), Vector3(0.6, 1.5, 5), DARK_COLOR)    # left of window
	_box(Vector3(0, 1.75, 3.5), Vector3(0.6, 1.5, 5), DARK_COLOR)     # right of window
	# Entry panel: start room's west wall, faces east (+X, toward player).
	_panel_entry = {"center": Vector3(-12.65, 1.8, 0), "normal": Vector3(1, 0, 0)}
	_panel(Vector3(-12.65, 1.8, 0), Vector3(0.1, 2.4, 2.4), Vector3(1, 0, 0))
	# Exit panel: goal room's east wall, faces west (-X). Shot THROUGH the window.
	_panel_exit = {"center": Vector3(12.65, 1.8, 0), "normal": Vector3(-1, 0, 0)}
	_panel(Vector3(12.65, 1.8, 0), Vector3(0.1, 2.4, 2.4), Vector3(-1, 0, 0))
	# Dressing crates (dark, non-portal-able).
	_box(Vector3(-9, 0.5, -4.5), Vector3(1, 1, 1), RUST_COLOR)
	_box(Vector3(9, 0.5, 4.5), Vector3(1, 1, 1), RUST_COLOR)
	_spawn_marker(Vector3(-9, 0.5, 0))
	_exit_zone(Vector3(9, 0.5, 0), 1.6)


## Scripted solution: enter the west-wall portal, exit at the east-wall
## panel (position = panel centre + normal * body offset), walk to the
## exit. Completion goes through the real exit-zone handler.
func solve() -> void:
	var exit_pos: Vector3 = _panel_exit["center"] + _panel_exit["normal"] * 0.5
	var dummy := dummy_player(exit_pos)
	dummy.global_position = Vector3(9, 0.5, 0)
	_on_exit_body_entered(dummy)
	dummy.queue_free()


func solution_steps() -> Array:
	return [
		"Shoot a portal on the east-wall white panel, through the divider window.",
		"Shoot the paired portal on the west-wall white panel behind you.",
		"Walk into the west-wall portal; you exit at the east-wall panel, in the goal room.",
		"Walk to the green exit.",
	]


func is_complete() -> bool:
	return check_done()


func reset() -> void:
	reset_room()
