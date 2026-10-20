# Desktop rendering preview of the mobile HUD (not a browser/device test).
# DISPLAY=:99 godot --path . --rendering-method gl_compatibility --script res://tools/capture_mobile_hud.gd
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
	var hud: Node = load("res://scenes/ui/hud.tscn").instantiate()
	root.add_child(hud)
	var touch: Node = load("res://scenes/ui/touch_controls.tscn").instantiate()
	touch.force_show = true
	root.add_child(touch)
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/mobile-hud.png")
	quit()
