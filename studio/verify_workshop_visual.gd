extends SceneTree
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var scene: PackedScene = load("res://asset_workshop.tscn")
	var workshop: Control = scene.instantiate()
	workshop.project_path = ProjectSettings.globalize_path("res://..")
	root.add_child(workshop)
	for x in range(-2, 3):
		for z in range(-2, 3):
			workshop.asset_doc = workshop.Asset.set_voxel(workshop.asset_doc, x, 0, z, 0)
	workshop._refresh()
	await create_timer(1.0).timeout
	var image: Image = root.get_texture().get_image()
	print("Workshop visual capture: ", image.save_png("/tmp/forgefall-workshop-visual.png"), " size=", image.get_size())
	quit()
