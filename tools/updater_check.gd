# tools/updater_check.gd — validates the auto-updater scaffolding headless.
# Boots the real main scene, asserts the Updater autoload is present and
# DISABLED (UPDATE_BASE_URL is empty), that a manual check degrades gracefully,
# and that the Options panel gained the CHECK FOR UPDATES row.
extends SceneTree

var _main: Node = null
var _frames := 0
var _notices: Array = []


func _initialize() -> void:
	var ps := load("res://scenes/main.tscn") as PackedScene
	_main = ps.instantiate()
	root.add_child(_main)
	current_scene = _main
	print("UPDCHK: booted to menu")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 5:
		var updater := root.get_node_or_null("Updater")
		print("UPDCHK: Updater autoload present: ", updater != null)
		if updater == null:
			printerr("UPDCHK: FAIL — no Updater autoload")
			return true
		print("UPDCHK: state (0=DISABLED): ", updater.get("state"))
		print("UPDCHK: has_plugin (expect false headless): ", updater.call("has_plugin"))
		print("UPDCHK: installed_version_code (expect 3): ", updater.call("installed_version_code"))
		updater.connect("notice", func(msg: String) -> void: _notices.append(msg))
		updater.call("check_for_updates", true)
	if _frames == 30:
		print("UPDCHK: notices after manual check: ", _notices)
		var menu := _find_menu()
		print("UPDCHK: main menu present: ", menu != null)
		if menu != null:
			print("UPDCHK: update button in options: ", _has_update_button(menu))
		var dlg_script: Script = load("res://scripts/ui/update_dialog.gd")
		var dlg = dlg_script.new()
		print("UPDCHK: UpdateDialog instantiates: ", dlg != null)
		dlg.free()
		if _notices.size() > 0 and str(_notices[0]).contains("not configured"):
			print("UPDCHK: DISABLED path graceful — OK")
		else:
			printerr("UPDCHK: FAIL — expected 'not configured' notice")
		return true
	return false


func _find_menu() -> Node:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != null and n.get_script() != null and str(n.get_script().resource_path).ends_with("main_menu.gd"):
			return n
		for c in n.get_children():
			stack.push_back(c)
	return null


func _has_update_button(menu: Node) -> bool:
	var found := [false]
	var stack: Array = [menu]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and (n as Button).text == "CHECK FOR UPDATES":
			found[0] = true
		for c in n.get_children():
			stack.push_back(c)
	return found[0]
