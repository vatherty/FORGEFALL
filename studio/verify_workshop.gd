extends SceneTree
const Asset = preload("res://shared/asset_document.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var fixture := ProjectSettings.globalize_path("user://workshop_fixture_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(fixture)
	var scene: PackedScene = load("res://asset_workshop.tscn")
	var workshop: Control = scene.instantiate()
	workshop.project_path = fixture
	root.add_child(workshop)
	assert(workshop.asset_doc["voxels"].size() == 1)
	workshop.axis_inputs[0].value = 1
	workshop._apply_coordinates()
	assert(workshop.asset_doc["voxels"].size() == 2)
	workshop._undo()
	assert(workshop.asset_doc["voxels"].size() == 1)
	workshop._redo()
	assert(workshop.asset_doc["voxels"].size() == 2)
	workshop._set_tool("Erase")
	workshop._apply_coordinates()
	assert(workshop.asset_doc["voxels"].size() == 1)
	assert(Asset.validate(workshop.asset_doc) == "")
	workshop._save()
	assert(FileAccess.file_exists(Asset.path(fixture, workshop.asset_doc["id"])))
	assert(not workshop.title.text.begins_with("●"))
	workshop._set_tool("Place")
	await physics_frame
	workshop._click_model(workshop.viewport_panel.size * 0.5)
	assert(workshop.asset_doc["voxels"].size() == 2)
	print("Workshop test passed: place, erase, undo/redo, save, viewport click")
	quit()
