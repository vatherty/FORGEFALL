# tools/mock_look_player.gd — test double for the touch aim verifier.
# Lives in the "player" group and records every add_look(relative) call
# (radians) so the test can assert exactly what the look path produced.
extends Node

var look_calls: Array = []


func _ready() -> void:
	add_to_group("player")


func add_look(relative: Vector2) -> void:
	look_calls.append(relative)


func look_sum() -> Vector2:
	var s := Vector2.ZERO
	for v in look_calls:
		s += v
	return s


func reset() -> void:
	look_calls.clear()
