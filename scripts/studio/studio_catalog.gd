# Runtime access to Studio's generated map catalog. No Studio application dependency.
extends RefCounted

const CATALOG := "res://assets/studio/generated/catalog.json"

static func list_maps() -> Array[Dictionary]:
	if not FileAccess.file_exists(CATALOG):
		return []
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	if not data is Dictionary or data.get("version") != 1 or not data.get("maps") is Dictionary:
		return []
	var result: Array[Dictionary] = []
	for id in data["maps"]:
		var entry: Variant = data["maps"][id]
		if entry is Dictionary and str(entry.get("scene", "")).begins_with("res://assets/studio/generated/maps/"):
			result.append({"id": id, "name": str(entry.get("name", id)), "scene": entry["scene"]})
	return result

static func load_map(id: String) -> Node3D:
	for entry in list_maps():
		if entry["id"] == id and ResourceLoader.exists(entry["scene"]):
			var scene: PackedScene = load(entry["scene"])
			return scene.instantiate() as Node3D
	return null

static func list_assets() -> Array[Dictionary]:
	if not FileAccess.file_exists(CATALOG):
		return []
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	if not data is Dictionary or data.get("version") != 1 or not data.get("assets") is Dictionary:
		return []
	var result: Array[Dictionary] = []
	for id in data["assets"]:
		var entry: Variant = data["assets"][id]
		if entry is Dictionary and str(entry.get("scene", "")).begins_with("res://assets/studio/generated/assets/"):
			result.append({"id": id, "name": str(entry.get("name", id)), "scene": entry["scene"]})
	return result

static func load_asset(id: String) -> Node3D:
	for entry in list_assets():
		if entry["id"] == id and ResourceLoader.exists(entry["scene"]):
			var scene: PackedScene = load(entry["scene"])
			return scene.instantiate() as Node3D
	return null
