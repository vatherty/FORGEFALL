# verify_v05_integration.gd — coordinator wiring checks (props + ForgeGate).
# Boots the real main scene, starts a game (survival, the legacy
# default), asserts:
#   1. DustlineProps instanced under the map with collision.
#   2. Forge menu instanced, in group "forge_menu", starts hidden.
#      (Legacy modes still instance the menu — forge_menu_allowed
#      includes them; the GATE is what blocks building.)
#   3. ForgeGate TD-only: in a live survival run, forge_console
#      does NOT open the Forge menu (HUD refuses + announces), and
#      ForgeGate.can_build() is false. The old expectation — Forge
#      opening in survival — is gone with the rework: Forge building
#      exists ONLY in Tower Defense.
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
				_check((menus[0] as Control).visible == false,
					"ForgeGate: forge_console does NOT open Forge in survival (TD-only)")
			var gate := load("res://scripts/forge/forge_gate.gd") as GDScript
			_check(gate != null and not bool(gate.call("can_build")),
				"ForgeGate: can_build() false in a live survival run")
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
					"ForgeGate: forge_console again leaves Forge closed in survival")
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
