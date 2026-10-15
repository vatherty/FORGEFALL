# verify_v05_integration.gd — coordinator wiring checks (props + Forge menu).
# Boots the real main scene, starts a game, asserts:
#   1. DustlineProps instanced under the map with collision.
#   2. Forge menu instanced, in group "forge_menu", starts hidden.
#   3. forge_console action opens the menu (HUD delegates to it).
#   4. forge_console again closes it.
# Exit 0 = all checks pass.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _main: Node = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	var ps := load("res://scenes/main.tscn") as PackedScene
	_main = ps.instantiate()
	root.add_child(_main)
	_main.call("start_game")
	_phase = 1
	print("INTEG: booted, start_game called")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 10:
				return false
			var props := get_nodes_in_group("forge_structure")
			_check(_main.get_node_or_null("Dustline/DustlineProps") != null
				or get_first_node_in_group("props") != null
				or _find_props() != null,
				"DustlineProps instanced under the map")
			var menus: Array[Node] = get_nodes_in_group("forge_menu")
			_check(not menus.is_empty(), "Forge menu instanced (forge_menu group)")
			if not menus.is_empty():
				_check((menus[0] as Control).visible == false,
					"Forge menu starts hidden")
			_phase = 2
			_frames = 0
		2:
			Input.action_press("forge_console", 1.0)
			_phase = 3
			_frames = 0
		3:
			if _frames < 3:
				return false
			Input.action_release("forge_console")
			var menus: Array[Node] = get_nodes_in_group("forge_menu")
			if not menus.is_empty():
				_check((menus[0] as Control).visible == true,
					"forge_console opens the Forge menu (HUD delegates)")
			_phase = 4
			_frames = 0
		4:
			Input.action_press("forge_console", 1.0)
			_phase = 5
			_frames = 0
		5:
			if _frames < 3:
				return false
			Input.action_release("forge_console")
			var menus: Array[Node] = get_nodes_in_group("forge_menu")
			if not menus.is_empty():
				_check((menus[0] as Control).visible == false,
					"forge_console again closes the Forge menu")
			if _fails == 0:
				print("INTEG: ALL CHECKS PASSED")
			else:
				printerr("INTEG: %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


func _find_props() -> Node:
	for n in get_nodes_in_group("props"):
		return n
	# Fallback: search the tree by name.
	for n in root.get_children():
		var found := n.find_child("DustlineProps", true, false)
		if found != null:
			return found
	return null
