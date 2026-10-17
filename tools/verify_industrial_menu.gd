# Responsive layout and menu routing at desktop, Deck, and narrow sizes.
extends SceneTree
var fails := 0
func check(ok: bool, label: String) -> void:
	print("PASS: " if ok else "FAIL: ", label)
	if not ok:
		fails += 1
func _initialize() -> void:
	call_deferred("run")
func settle() -> void:
	for i in range(4):
		await process_frame
func run() -> void:
	var menu = load("res://scenes/ui/main_menu.tscn").instantiate()
	root.add_child(menu)
	menu.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	for resolution in [Vector2(1280, 800), Vector2(960, 540), Vector2(540, 960)]:
		menu.size = resolution
		await settle()
		menu._open_mode_select("sp")
		await settle()
		var grid = menu._mode_overlay_rows.get_child(0)
		check(grid.get_child_count() == 3, "all single player modes appear at " + str(resolution))
		check(grid.columns == (3 if resolution.x >= 900 else 1), "mode cards adapt to width " + str(resolution))
		check(not menu._scroll.visible, "home navigation hidden during selection")
		for card in grid.get_children():
			check(card.size.x >= 240, "card has readable width: " + card.name)
			check(card.get_global_rect().end.x <= menu.get_global_rect().end.x + 1, "card stays inside screen: " + card.name)
		menu._on_mode_start_pressed("tdm")
		await settle()
		check(menu._deploy_panel.visible and not menu._mode_overlay.visible, "continue opens deployment")
		check(menu._deploy_columns.columns == (2 if resolution.x >= 900 else 1), "deployment adapts to width")
		check(not menu._deploy_tool.disabled, "TDM traversal selectable")
		menu._selected_mode = "zombies"
		menu._refresh_deploy()
		check(menu._map_select.disabled and menu._deploy_tool.disabled, "Zombies locks its mode-owned map and traversal")
		menu._selected_mode = "tower_defense"
		menu._refresh_deploy()
		check(menu._map_select.disabled and not menu._deploy_tool.disabled and menu._deploy_tool.is_item_disabled(3), "TD locks map and requires one traversal tool")
		menu._close_deploy()
		menu._close_mode_select()
		check(menu._scroll.visible, "back restores main menu")
	menu.queue_free()
	await process_frame
	print("INDUSTRIAL_MENU failures: ", fails)
	quit(1 if fails else 0)
