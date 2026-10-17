# Run with a graphics display: godot --path . --script res://tools/capture_map_previews.gd
extends SceneTree
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	root.size = Vector2i(960, 540)
	for key in ["dustline", "foundry", "outpost", "cinder_city", "tower_defense", "factory", "zombies_flat"]:
		var arena := Node3D.new()
		root.add_child(arena)
		var map = load("res://scenes/maps/" + key + ".tscn").instantiate()
		arena.add_child(map)
		if key == "zombies_flat":
			var town = load("res://scripts/modes/zombies.gd").new()
			arena.add_child(town)
			town.start_run()
		_preview_lighting(arena)
		var camera := Camera3D.new()
		arena.add_child(camera)
		camera.position = Vector3(34, 26, 34) if key != "cinder_city" else Vector3(60, 48, 60)
		camera.look_at(Vector3(0, 2, 0))
		camera.current = true
		camera.fov = 65
		for i in range(8):
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://assets/ui/maps/" + key + ".png")
		arena.queue_free()
		await process_frame
	quit()

# Neutral, repeatable thumbnail lighting; leaves gameplay scenes untouched.
func _preview_lighting(node: Node) -> void:
	if node is WorldEnvironment:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color("263646")
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color("b7c8db")
		env.ambient_light_energy = 0.55
		(node as WorldEnvironment).environment = env
	if node is DirectionalLight3D:
		(node as DirectionalLight3D).light_energy = 0.9
		(node as DirectionalLight3D).light_color = Color("ffe0b2")
	for child in node.get_children():
		_preview_lighting(child)
