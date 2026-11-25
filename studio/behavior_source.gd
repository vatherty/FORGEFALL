extends RefCounted

# The editor keeps handwritten scripts separate from generated behavior scripts.
# Call open_file, edit, diagnose, then save. Saves reject external changes.
var project_path := ""
var file_path := ""
var source := ""
var saved_source := ""
var breakpoints: Array[int] = []

func open_file(project: String, relative_path: String) -> String:
	if not relative_path.begins_with("scripts/") or not relative_path.ends_with(".gd") or relative_path.contains("..") or relative_path.begins_with("/"):
		return "Choose a .gd file inside scripts/."
	var absolute := project.path_join(relative_path).simplify_path()
	if not absolute.begins_with(project.path_join("scripts/")):
		return "Script path escapes the project."
	project_path = project
	file_path = absolute
	source = FileAccess.get_file_as_string(file_path) if FileAccess.file_exists(file_path) else "extends Node\n"
	saved_source = source
	breakpoints.clear()
	return ""

func edit(text: String) -> void:
	source = text

func is_dirty() -> bool:
	return source != saved_source

func diagnose() -> Dictionary:
	# Check an unsaved copy in a separate Godot process so parser output retains
	# the source line number. The temporary copy is removed after every check.
	var temporary := ProjectSettings.globalize_path("user://studio_source_check_%d.gd" % Time.get_ticks_usec())
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "line": 0, "message": "Cannot create diagnostic copy."}
	file.store_string(source)
	file.close()
	var target_project := project_path if FileAccess.file_exists(project_path.path_join("project.godot")) else ProjectSettings.globalize_path("res://")
	var output: Array = []
	var status := OS.execute(OS.get_executable_path(), ["--headless", "--path", target_project, "--check-only", "--script", temporary], output, true)
	DirAccess.remove_absolute(temporary)
	if status == 0:
		return {"ok": true, "line": 0, "message": "No parser errors."}
	var details := str(output[0]) if not output.is_empty() else ""
	var line := 0
	var line_pattern := RegEx.new()
	line_pattern.compile("\\.gd:(\\d+)\\)")
	var match_line := line_pattern.search(details)
	if match_line != null:
		line = int(match_line.get_string(1))
	var summary := "GDScript check failed."
	for text_line in details.split("\n"):
		if text_line.begins_with("SCRIPT ERROR:"):
			summary = text_line.trim_prefix("SCRIPT ERROR: ").strip_edges()
			break
	return {"ok": false, "line": line, "message": "%s (line %d)" % [summary, line] if line > 0 else summary}

func save() -> String:
	if file_path.is_empty():
		return "Open a script first."
	var on_disk := FileAccess.get_file_as_string(file_path) if FileAccess.file_exists(file_path) else "extends Node\n"
	if on_disk != saved_source:
		return "Script changed outside Studio. Reopen it before saving."
	var directory_error := DirAccess.make_dir_recursive_absolute(file_path.get_base_dir())
	if directory_error != OK:
		return "Cannot create script directory."
	var file := FileAccess.open(file_path + ".tmp", FileAccess.WRITE)
	if file == null:
		return "Cannot write script."
	file.store_string(source)
	file.flush()
	file.close()
	var backup := file_path + ".previous"
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(file_path):
		var backup_error := DirAccess.rename_absolute(file_path, backup)
		if backup_error != OK:
			return "Cannot back up the original script."
	var rename_error := DirAccess.rename_absolute(file_path + ".tmp", file_path)
	if rename_error != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, file_path)
		return "Cannot replace script."
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	saved_source = source
	return ""

func toggle_breakpoint(line: int) -> void:
	if line < 1:
		return
	if breakpoints.has(line):
		breakpoints.erase(line)
	else:
		breakpoints.append(line)
		breakpoints.sort()
