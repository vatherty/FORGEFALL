extends SceneTree

const Store = preload("res://studio/shared/document_store.gd")
const Content = preload("res://studio/content_document.gd")
const Runtime = preload("res://studio/content_runtime.gd")
const BASE := "res://assets/studio"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or not str(args[0]) in ["character", "weapon"] or not Content.safe_id(str(args[1])):
		_fail("Expected character|weapon <ID>")
		return
	_publish(str(args[0]), str(args[1]))

func _publish(kind: String, id: String) -> void:
	var source := BASE + "/" + kind + "s/" + id + ".json"
	var doc := Store.read_json(ProjectSettings.globalize_path(source))
	if doc.get("kind") != kind or doc.get("id") != id:
		_fail("Content document missing or mismatched.")
		return
	var problem := Content.validate(doc)
	if problem != "":
		_fail(problem)
		return
	var catalog_path := BASE + "/generated/catalog.json"
	var catalog := Store.read_json(ProjectSettings.globalize_path(catalog_path))
	if FileAccess.file_exists(catalog_path) and (catalog.is_empty() or catalog.get("version") != 1):
		_fail("Existing catalog is invalid; refusing overwrite.")
		return
	if catalog.is_empty():
		catalog = {"version": 1, "maps": {}, "assets": {}}
	var visual: PackedScene = null
	var asset_id := str(doc.get("asset_id", ""))
	if asset_id != "":
		visual = _catalog_scene(catalog, "assets", asset_id)
		if visual == null:
			_fail("Publish the visual voxel asset first: " + asset_id)
			return
	var weapon: PackedScene = null
	if kind == "character" and str(doc.get("weapon_id", "")) != "":
		weapon = _catalog_scene(catalog, "weapons", str(doc["weapon_id"]))
		if weapon == null:
			_fail("Publish the weapon first: " + str(doc["weapon_id"]))
			return
	var root: Node3D = Runtime.build_weapon(doc, visual) if kind == "weapon" else Runtime.build_character(doc, visual, weapon)
	if root == null:
		_fail("Cannot build content scene.")
		return
	var destination := BASE + "/generated/" + kind + "s/" + id + ".tscn"
	var old_entry: Dictionary = catalog.get(kind + "s", {}).get(id, {})
	if FileAccess.file_exists(destination) and (old_entry.is_empty() or old_entry.get("sha256", "") != FileAccess.get_sha256(destination)):
		root.free()
		_fail("Generated scene changed outside Studio; refusing overwrite.")
		return
	var scene := PackedScene.new()
	if scene.pack(root) != OK:
		root.free()
		_fail("Cannot pack content scene.")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination.get_base_dir()))
	var temporary := destination + ".tmp.tscn"
	var error := ResourceSaver.save(scene, temporary)
	root.free()
	if error != OK:
		_fail("Cannot save content scene: " + error_string(error))
		return
	var absolute := ProjectSettings.globalize_path(destination)
	var backup := absolute + ".previous"
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(absolute):
		error = DirAccess.rename_absolute(absolute, backup)
		if error != OK:
			_fail("Cannot preserve old content scene.")
			return
	error = DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), absolute)
	if error != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, absolute)
		_fail("Cannot replace content scene.")
		return
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if not catalog.has(kind + "s"):
		catalog[kind + "s"] = {}
	catalog[kind + "s"][id] = {"name": doc["name"], "scene": destination, "sha256": FileAccess.get_sha256(destination)}
	error = Store.write_json(ProjectSettings.globalize_path(catalog_path), catalog)
	if error != OK:
		_fail("Scene saved but catalog update failed: " + error_string(error))
		return
	print("Published " + kind + ": " + destination)
	quit(0)

func _catalog_scene(catalog: Dictionary, bucket: String, id: String) -> PackedScene:
	if not catalog.get(bucket, {}).has(id):
		return null
	var path := str(catalog[bucket][id].get("scene", ""))
	if not path.begins_with(BASE + "/generated/") or not path.ends_with(".tscn"):
		return null
	return load(path) as PackedScene

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
