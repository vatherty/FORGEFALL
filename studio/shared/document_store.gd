extends RefCounted

const VERSION := 1
const ROOT := "assets/studio"

static func new_map(title: String) -> Dictionary:
	return {"version": VERSION, "kind": "map", "id": _id(), "name": title, "instances": [], "environment": {"clear_color": "#252d39"}}

static func new_instance(label: String, position: Vector3) -> Dictionary:
	return {"id": _id(), "name": label, "kind": "block", "position": [position.x, position.y, position.z], "size": [1.0, 1.0, 1.0], "color": "#d39456", "visible": true, "locked": false}

static func validate_target(path: String) -> String:
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		return "Select an existing Forgefall source directory."
	if not FileAccess.file_exists(path.path_join("project.godot")):
		return "No project.godot in selected directory."
	var config := ConfigFile.new()
	if config.load(path.path_join("project.godot")) != OK:
		return "Cannot read target project.godot."
	if str(config.get_value("application", "config/name", "")).to_lower() != "forgefall":
		return "This is not a Forgefall source project."
	return ""

static func validate_map(doc: Dictionary) -> String:
	if doc.get("version") != VERSION or doc.get("kind") != "map":
		return "Unsupported map document version or kind."
	if not doc.get("instances") is Array:
		return "Map instances must be an array."
	var ids := {}
	for item in doc["instances"]:
		if not item is Dictionary or str(item.get("id", "")).is_empty():
			return "An instance has no stable ID."
		if ids.has(item["id"]):
			return "Duplicate instance ID."
		ids[item["id"]] = true
	return ""

static func map_path(project: String, map_id: String) -> String:
	return project.path_join(ROOT).path_join("maps").path_join(map_id + ".json")

static func write_json(path: String, doc: Dictionary) -> Error:
	var directory := path.get_base_dir()
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return error
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(doc, "\t") + "\n")
	file.flush()
	file.close()
	var backup := path + ".previous"
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(path):
		error = DirAccess.rename_absolute(path, backup)
		if error != OK:
			return error
	error = DirAccess.rename_absolute(temporary, path)
	if error != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, path)
		return error
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	return OK

static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else {}

static func new_id() -> String:
	return "%08x-%08x-%08x-%08x" % [randi(), randi(), randi(), randi()]

static func _id() -> String:
	return new_id()
