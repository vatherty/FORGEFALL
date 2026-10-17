# Interaction regressions for the atmospheric menu redesign.
extends SceneTree
var failures := 0
func check(ok: bool, label: String) -> void:
	print("PASS: " if ok else "FAIL: ", label)
	if not ok:
		failures += 1
func _initialize() -> void:
	call_deferred("run")
func settle() -> void:
	for i in range(4):
		await process_frame
func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await settle()
	var menu = main._menu
	menu._open_mode_select("sp")
	menu._select_mode("zombies")
	check(menu._selected_mode == "zombies", "mode selection updates without starting a match")
	menu.find_child("ModeContinueButton", true, false).pressed.emit()
	check(menu._deploy_panel.visible and main.state == main.State.MENU, "continue opens setup before deployment")
	menu._close_deploy()
	menu._close_mode_select()
	menu._on_options()
	var settings = menu.find_child("SettingsTabs", true, false)
	check(settings != null and settings.get_tab_count() == 3, "settings has Audio, Display and Controls")
	settings.current_tab = 2
	await settle()
	check(menu._sens.is_visible_in_tree() and not menu._master.is_visible_in_tree(), "settings pages expose their own controls")
	menu._options_panel.visible = false
	menu._on_loadouts()
	var picker = menu.get_node("LoadoutPicker")
	picker._on_new_pressed()
	await settle()
	check(picker._editor.is_visible_in_tree() and not picker._list_scroll.visible, "loadout editing has a dedicated form")
	check(picker._close_button.is_visible_in_tree(), "loadout editor keeps a visible Back button")
	picker._cancel_button.pressed.emit()
	check(picker._list_scroll.visible and not picker._editor.visible, "cancel restores loadout navigation without saving")
	picker.close()
	await settle()
	var forge = load("res://scenes/ui/forge_menu.tscn").instantiate()
	root.add_child(forge)
	forge.open()
	await settle()
	check(forge._prompt_input.is_visible_in_tree(), "Forge prompt stays visible in the simple view")
	check(not forge._advanced_details.visible, "Forge details start collapsed")
	forge.find_child("ForgeDetailsButton", true, false).button_pressed = true
	check(forge._key_input.is_visible_in_tree() and forge._history_search_input.is_visible_in_tree(), "history and key setup remain reachable")
	forge.queue_free()
	await settle()
	var mp = load("res://scenes/multiplayer_menu.tscn").instantiate()
	root.add_child(mp)
	await settle()
	mp._network_tabs.get_child(1).pressed.emit()
	check(mp._join_panel.visible and not mp._host_panel.visible, "Join tab exposes server list and direct-IP controls")
	mp._network_tabs.get_child(0).pressed.emit()
	check(mp._host_panel.visible and not mp._join_panel.visible, "Host tab restores map and mode controls")
	mp.queue_free()
	await settle()
	var stats = load("res://scenes/ui/stats_screen.tscn").instantiate()
	root.add_child(stats)
	stats.open()
	check(stats._metric_kills.text == str(stats._snapshot().get("kills", 0)), "service record hero value uses real saved statistics")
	stats.queue_free()
	await settle()
	main.start_sp_mode("tdm")
	await settle()
	main.toggle_pause()
	check(main._pause_menu.find_child("SceneArt", true, false) == null, "pause overlays the actual match instead of replacing its view")
	main.quit_to_menu()
	await settle()
	main.queue_free()
	await settle()
	print("CINEMATIC_UI failures: ", failures)
	quit(1 if failures else 0)
