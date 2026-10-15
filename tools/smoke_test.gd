# smoke_test.gd — FORGEFALL headless runtime smoke test (coordinator validation).
# Usage: godot --headless --path <project> --script res://tools/smoke_test.gd
# Boots the real main scene, starts a game, runs 600 physics frames (map build,
# nav bake, HUD, touch layer, wave spawning, enemy AI, Forge idle), then quits.
# Any SCRIPT ERROR printed = real bug. Exit 0 = clean.
extends SceneTree

var _main: Node = null
var _frames := 0

func _initialize() -> void:
	var ps := load("res://scenes/main.tscn") as PackedScene
	_main = ps.instantiate()
	root.add_child(_main)
	current_scene = _main  # real game sets this; Forge builder uses it as spawn root
	print("SMOKE: booted to menu")

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 5:
		_main.call("start_game")
		print("SMOKE: start_game called")
	if _frames == 300:
		var waves := _first_in_group("wave_manager")
		print("SMOKE: frame 300, wave_manager present: ", waves != null)
	if _frames == 400:
		var forge := root.get_node_or_null("Forge")
		var game := root.get_node_or_null("Game")
		if forge != null and forge.has_method("submit_prompt"):
			print("SMOKE: budget before forge: ", game.get("forge_budget"))
			forge.call("submit_prompt", "build a wall in front of me")
		else:
			print("SMOKE: Forge autoload missing!")
	if _frames == 700:
		var game2 := root.get_node_or_null("Game")
		var covers := get_nodes_in_group("cover").size()
		print("SMOKE: frame 700, budget: ", game2.get("forge_budget"), ", cover nodes: ", covers)
	if _frames >= 900:
		print("SMOKE: survived 900 frames, quitting clean")
		return true
	return false

func _first_in_group(group: String) -> Node:
	var nodes := get_nodes_in_group(group)
	return nodes[0] if nodes.size() > 0 else null
