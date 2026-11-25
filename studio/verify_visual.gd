extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 800))
	var scene: PackedScene = load("res://main.tscn")
	var studio: Control = scene.instantiate()
	root.add_child(studio)
	studio._open_project(ProjectSettings.globalize_path("res://.."))
	studio._new_map()
	studio._add_block()
	await create_timer(1.0).timeout
	var capture: Image = root.get_texture().get_image()
	var result := capture.save_png("/tmp/forgefall-studio-visual.png")
	print("Visual capture: ", result, " size=", capture.get_size())
	quit()
