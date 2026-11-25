extends SceneTree

# Runs inside the selected Forgefall source project:
# godot --headless --path <forgefall> --script res://tools/studio_generate.gd -- <map-id>
const Store = preload("res://studio/shared/document_store.gd")
const Asset = preload("res://studio/shared/asset_document.gd")
const Mesher = preload("res://studio/shared/voxel_mesh.gd")
const BASE := "res://assets/studio"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() == 2 and args[0] == "asset" and _safe_id(args[1]):
		_publish_asset(args[1])
		return
	if args.size() != 1 or not _safe_id(args[0]):
		fail("Expected a map ID or asset <ID>")
		return
	_publish_map(args[0])

func _publish_map(id: String) -> void:
	var source := BASE + "/maps/" + id + ".json"
	if not FileAccess.file_exists(source):
		fail("Map not found: " + source)
		return
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(source))
	if not doc is Dictionary or doc.get("id") != id:
		fail("Mismatched map document")
		return
	var validation: String = Store.validate_map(doc)
	if validation != "":
		fail(validation)
		return
	var destination := BASE + "/generated/maps/" + id + ".tscn"
	var catalog_path := BASE + "/generated/catalog.json"
	var catalog: Dictionary = _read_catalog(catalog_path)
	if FileAccess.file_exists(catalog_path) and catalog.is_empty():
		fail("Existing catalog is invalid; refusing to overwrite")
		return
	if catalog.is_empty():
		catalog = {"version": 1, "maps": {}, "assets": {}}
	if not catalog.has("assets"):
		catalog["assets"] = {}
	var old_entry: Dictionary = catalog["maps"].get(id, {})
	if FileAccess.file_exists(destination):
		if old_entry.is_empty() or old_entry.get("sha256", "") != FileAccess.get_sha256(destination):
			fail("Generated scene changed outside Studio; refusing to overwrite")
			return
	var root := Node3D.new()
	root.name = _safe_node_name(str(doc.get("name", "StudioMap")))
	var used := {}
	for item in doc["instances"]:
		if not item is Dictionary or not _safe_id(str(item.get("id", ""))) or used.has(item["id"]):
			fail("Invalid or duplicate instance ID")
			root.free()
			return
		used[item["id"]] = true
		var behavior_id := str(item.get("behavior_id", ""))
		if behavior_id != "":
			var behavior_path := BASE + "/generated/behaviors/" + behavior_id + ".gd"
			if not _safe_id(behavior_id) or not FileAccess.file_exists(behavior_path):
				fail("Map references an unpublished behavior: " + behavior_id)
				root.free()
				return
		if item.get("kind") == "asset":
			var asset_id := str(item.get("asset_id", ""))
			if not _safe_id(asset_id) or not catalog["assets"].has(asset_id):
				fail("Map references an unpublished asset: " + asset_id)
				root.free()
				return
			if not _valid_vec(item.get("position")):
				fail("Invalid asset position")
				root.free()
				return
			var asset_scene_path: String = catalog["assets"][asset_id]["scene"]
			var asset_scene: PackedScene = load(asset_scene_path)
			if asset_scene == null:
				fail("Published asset scene is missing: " + asset_id)
				root.free()
				return
			var asset_node := asset_scene.instantiate() as Node3D
			asset_node.name = "Asset_" + str(item["id"]).replace("-", "_")
			asset_node.position = Vector3(item["position"][0], item["position"][1], item["position"][2])
			_apply_transform(asset_node, item)
			_apply_metadata(asset_node, item)
			root.add_child(asset_node)
			asset_node.owner = root
			continue
		if item.get("kind") in ["light", "volume", "marker", "navigation"]:
			if not _valid_vec(item.get("position")) or not _valid_vec(item.get("size", [1, 1, 1])):
				fail("Invalid map feature transform")
				root.free()
				return
			var feature: Node3D = _build_feature(item, catalog)
			if feature == null:
				fail("Invalid map feature: " + str(item.get("name", "")))
				root.free()
				return
			feature.name = _safe_node_name(str(item.get("name", "Feature"))) + "_" + str(item["id"]).replace("-", "_")
			feature.position = Vector3(item["position"][0], item["position"][1], item["position"][2])
			_apply_transform(feature, item)
			_apply_metadata(feature, item)
			root.add_child(feature)
			feature.owner = root
			for child in feature.get_children():
				child.owner = root
			continue
		if item.get("kind") != "block":
			fail("Unsupported instance kind: " + str(item.get("kind")))
			root.free()
			return
		if not _valid_vec(item.get("position")) or not _valid_vec(item.get("size")):
			fail("Invalid block transform")
			root.free()
			return
		var size := Vector3(item["size"][0], item["size"][1], item["size"][2])
		if size.x <= 0 or size.y <= 0 or size.z <= 0:
			fail("Block size must be positive")
			root.free()
			return
		var body := StaticBody3D.new()
		body.name = "Block_" + str(item["id"]).replace("-", "_")
		body.position = Vector3(item["position"][0], item["position"][1] + size.y * 0.5, item["position"][2])
		_apply_transform(body, item)
		_apply_metadata(body, item)
		root.add_child(body)
		body.owner = root
		var visual := MeshInstance3D.new()
		visual.name = "Visual"
		var mesh := BoxMesh.new()
		mesh.size = size
		visual.mesh = mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(str(item.get("color", "#d39456")))
		visual.material_override = material
		body.add_child(visual)
		visual.owner = root
		var collision := CollisionShape3D.new()
		collision.name = "Collision"
		var shape := BoxShape3D.new()
		shape.size = size
		collision.shape = shape
		body.add_child(collision)
		collision.owner = root
	var scene := PackedScene.new()
	if scene.pack(root) != OK:
		fail("Could not pack map scene")
		root.free()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination.get_base_dir()))
	var temp := destination + ".tmp.tscn"
	var result := ResourceSaver.save(scene, temp)
	root.free()
	if result != OK:
		fail("Could not save map scene: " + error_string(result))
		return
	var absolute_destination := ProjectSettings.globalize_path(destination)
	var backup := absolute_destination + ".previous"
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(destination):
		result = DirAccess.rename_absolute(absolute_destination, backup)
		if result != OK:
			fail("Could not preserve previous map scene: " + error_string(result))
			return
	result = DirAccess.rename_absolute(ProjectSettings.globalize_path(temp), absolute_destination)
	if result != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, absolute_destination)
		fail("Could not publish map scene: " + error_string(result))
		return
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	catalog["maps"][id] = {"name": str(doc.get("name", id)), "scene": destination, "sha256": FileAccess.get_sha256(destination)}
	result = _write_catalog(catalog_path, catalog)
	if result != OK:
		fail("Scene saved but catalog update failed: " + error_string(result))
		return
	print("Published map: " + destination)
	quit(0)

func _apply_transform(node: Node3D, item: Dictionary) -> void:
	var rotation_value: Variant = item.get("rotation", [0, 0, 0])
	if _valid_vec(rotation_value):
		node.rotation_degrees = Vector3(rotation_value[0], rotation_value[1], rotation_value[2])
	if item.get("kind") == "asset":
		var scale_value: Variant = item.get("scale", [1, 1, 1])
		if _valid_vec(scale_value) and minf(minf(float(scale_value[0]), float(scale_value[1])), float(scale_value[2])) > 0:
			node.scale = Vector3(scale_value[0], scale_value[1], scale_value[2])

func _apply_metadata(node: Node3D, item: Dictionary) -> void:
	if str(item.get("group_id", "")) != "":
		node.set_meta("studio_group", str(item["group_id"]))
	if str(item.get("behavior_id", "")) != "":
		var id := str(item["behavior_id"])
		if _safe_id(id):
			var path := BASE + "/generated/behaviors/" + id + ".gd"
			if ResourceLoader.exists(path):
				node.set_script(load(path))
				node.add_to_group("studio_interactable", true)
			else:
				push_warning("Studio behavior not published: " + id)

func _build_feature(item: Dictionary, catalog: Dictionary) -> Node3D:
	var kind := str(item.get("kind"))
	var dimensions := Vector3(item["size"][0], item["size"][1], item["size"][2])
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0:
		return null
	if kind == "light":
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(str(item.get("color", "#ffffff")))
		lamp.light_energy = clampf(float(item.get("energy", 1.0)), 0.0, 16.0)
		lamp.omni_range = clampf(dimensions.x, 0.1, 100.0)
		return lamp
	if kind == "marker":
		var marker := Marker3D.new()
		var marker_type := str(item.get("marker_type", "player_spawn"))
		if marker_type == "character_spawn":
			if not FileAccess.file_exists("res://studio/content_runtime.gd"):
				return null
			var content_runtime: GDScript = load("res://studio/content_runtime.gd")
			return content_runtime.build_character_spawn(item, catalog)
		if marker_type not in ["player_spawn", "spawn_door", "objective_point", "waypoint"]:
			return null
		marker.add_to_group(marker_type, true)
		return marker
	if kind == "volume":
		var area := Area3D.new()
		area.monitoring = true
		area.add_to_group("studio_volume", true)
		area.set_meta("volume_type", str(item.get("volume_type", "trigger")))
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = dimensions
		shape.shape = box
		area.add_child(shape)
		return area
	if kind == "navigation":
		var region := NavigationRegion3D.new()
		var mesh := NavigationMesh.new()
		var half_x := dimensions.x * 0.5
		var half_z := dimensions.z * 0.5
		mesh.vertices = PackedVector3Array([
			Vector3(-half_x, 0, -half_z), Vector3(half_x, 0, -half_z),
			Vector3(half_x, 0, half_z), Vector3(-half_x, 0, half_z)])
		mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
		region.navigation_mesh = mesh
		return region
	return null

func _publish_asset(id: String) -> void:
	var source := BASE + "/assets/" + id + ".json"
	var doc: Dictionary = Store.read_json(ProjectSettings.globalize_path(source))
	if doc.get("id") != id:
		fail("Asset ID does not match source path")
		return
	var validation: String = Asset.validate(doc)
	if validation != "":
		fail(validation)
		return
	var destination := BASE + "/generated/assets/" + id + ".tscn"
	var catalog_path := BASE + "/generated/catalog.json"
	var catalog: Dictionary = _read_catalog(catalog_path)
	if FileAccess.file_exists(catalog_path) and catalog.is_empty():
		fail("Existing catalog is invalid; refusing to overwrite")
		return
	if catalog.is_empty():
		catalog = {"version": 1, "maps": {}, "assets": {}}
	if not catalog.has("assets"):
		catalog["assets"] = {}
	var old_entry: Dictionary = catalog["assets"].get(id, {})
	if FileAccess.file_exists(destination):
		if old_entry.is_empty() or old_entry.get("sha256", "") != FileAccess.get_sha256(destination):
			fail("Generated asset scene changed outside Studio; refusing to overwrite")
			return
	var node: Node3D = Mesher.build_node(doc, true)
	if FileAccess.file_exists("res://studio/content_runtime.gd"):
		var content_runtime: GDScript = load("res://studio/content_runtime.gd")
		var content_error: String = content_runtime.decorate_asset(node, doc)
		if content_error != "":
			fail(content_error)
			node.free()
			return
	node.name = _safe_node_name(str(doc.get("name", "VoxelAsset")))
	var scene := PackedScene.new()
	if scene.pack(node) != OK:
		fail("Could not pack voxel asset")
		node.free()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination.get_base_dir()))
	var temp := destination + ".tmp.tscn"
	var result := ResourceSaver.save(scene, temp)
	node.free()
	if result != OK:
		fail("Could not save voxel asset: " + error_string(result))
		return
	var absolute_destination := ProjectSettings.globalize_path(destination)
	var backup := absolute_destination + ".previous"
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(destination):
		result = DirAccess.rename_absolute(absolute_destination, backup)
		if result != OK:
			fail("Could not preserve previous asset scene")
			return
	result = DirAccess.rename_absolute(ProjectSettings.globalize_path(temp), absolute_destination)
	if result != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, absolute_destination)
		fail("Could not publish voxel asset")
		return
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	catalog["assets"][id] = {"name": str(doc.get("name", id)), "scene": destination, "sha256": FileAccess.get_sha256(destination)}
	result = _write_catalog(catalog_path, catalog)
	if result != OK:
		fail("Asset saved but catalog update failed")
		return
	print("Published asset: " + destination)
	quit(0)

func _safe_id(value: String) -> bool:
	if value.is_empty() or value.length() > 80:
		return false
	for character in value:
		if not (character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"):
			return false
	return true

func _safe_node_name(value: String) -> String:
	return value.replace("/", "_").replace("@", "_").replace(":", "_").substr(0, 60)

func _valid_vec(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for number in value:
		if not (number is float or number is int) or not is_finite(float(number)):
			return false
	return true

func _read_catalog(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or parsed.get("version") != 1 or not parsed.get("maps") is Dictionary:
		return {}
	return parsed

func _write_catalog(path: String, data: Dictionary) -> Error:
	var absolute := ProjectSettings.globalize_path(path)
	var temp := absolute + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t") + "\n")
	file.close()
	if FileAccess.file_exists(absolute):
		var backup := absolute + ".previous"
		if FileAccess.file_exists(backup):
			DirAccess.remove_absolute(backup)
		var previous_result := DirAccess.rename_absolute(absolute, backup)
		if previous_result != OK:
			return previous_result
		var result := DirAccess.rename_absolute(temp, absolute)
		if result != OK:
			DirAccess.rename_absolute(backup, absolute)
			return result
		DirAccess.remove_absolute(backup)
		return OK
	return DirAccess.rename_absolute(temp, absolute)

func fail(message: String) -> void:
	printerr("Studio publish error: " + message)
	quit(1)
