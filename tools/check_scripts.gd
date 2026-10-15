# check_scripts.gd — FORGEFALL script compile check (coordinator validation).
# Usage: godot --headless --path <project> --script res://tools/check_scripts.gd
# Loads every .gd in the project; load() compiles the script, so parse/type
# errors surface here. Autoloads resolve because --path loads project settings.
extends SceneTree

var _checked := 0
var _failed := 0

func _initialize() -> void:
	_walk("res://")
	print("CHECK_SCRIPTS: checked %d scripts, %d failed" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)

func _walk(dir: String) -> void:
	for sub in DirAccess.get_directories_at(dir):
		if sub != ".godot" and not sub.begins_with("."):
			_walk(dir.path_join(sub))
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".gd"):
			_checked += 1
			var path := dir.path_join(file)
			var script := load(path) as Script
			if script == null or not script.can_instantiate():
				_failed += 1
				printerr("CHECK_SCRIPTS FAIL: ", path)
