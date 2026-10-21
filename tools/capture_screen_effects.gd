# Render the actual player/map/HUD with each look, without saving preferences.
# DISPLAY=:99 godot --path . --rendering-method gl_compatibility --script res://tools/capture_screen_effects.gd
extends SceneTree
func _initialize() -> void:
	call_deferred("capture")
func capture() -> void:
	root.size = Vector2i(1280, 720)
	var arena := Node3D.new()
	root.add_child(arena)
	arena.add_child(load("res://scenes/maps/dustline.tscn").instantiate())
	var player: Node3D = load("res://scenes/player.tscn").instantiate()
	player.position = Vector3(14, 2, 14)
	player.rotation.y = PI / 4.0
	arena.add_child(player)
	root.add_child(load("res://scenes/ui/hud.tscn").instantiate())
	var touch: Node = load("res://scenes/ui/touch_controls.tscn").instantiate()
	touch.force_show = true
	root.add_child(touch)
	for frame in 8:
		await process_frame
	player.set_physics_process(false)
	player.set_process(false)
	touch.dismiss_hints()
	for frame in 65:
		await process_frame
	var values: Dictionary = root.get_node("Preferences").values.duplicate()
	values.effects_enabled = true
	values.effects_strength = 0.85
	values.effects_grain = false
	var effects: Node = root.get_node("ScreenEffects")
	for index in range(-1, 5):
		values.effects_enabled = index >= 0
		values.effects_look = maxi(index, 0)
		effects.configure(values)
		for frame in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/effects-%s.png" % ["off", "bodycam", "cinematic", "retro", "monochrome", "night-vision"][index + 1])
	quit()
