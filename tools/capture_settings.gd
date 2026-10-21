# Desktop preview only. Run with an X display and gl_compatibility.
extends SceneTree
func _initialize() -> void:
	call_deferred("capture")
func capture() -> void:
	root.size = Vector2i(1280, 720)
	var menu: Node = load("res://scripts/ui/settings_menu.gd").open_in(root)
	var tabs: TabContainer = menu.find_child("SettingsTabs", true, false)
	tabs.current_tab = 4
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/settings-ai.png")
	root.size = Vector2i(844, 390)
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/settings-mobile.png")
	quit()
