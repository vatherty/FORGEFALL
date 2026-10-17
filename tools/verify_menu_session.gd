# Actual mode -> pause -> quit -> next mode regression.
extends SceneTree
var fails := 0
func check(ok: bool, label: String) -> void:
	print("PASS: " if ok else "FAIL: ", label)
	if not ok:
		fails += 1
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame
	for mode in ["tdm", "tower_defense", "zombies", "tdm"]:
		check(main.start_sp_mode(mode), "start " + mode)
		await physics_frame
		main.toggle_pause()
		check(paused and main.state == main.State.PAUSED and main._pause_menu.visible, "pause screen visible: " + mode)
		main._pause_menu.toggle_pause()
		check(not paused and main.state == main.State.PLAYING, "resume synchronizes controller state: " + mode)
		main.toggle_pause()
		main._pause_menu._on_quit_to_menu()
		await process_frame
		await process_frame
		check(current_scene == main, "bootstrap retained after " + mode)
		check(not paused and main.state == main.State.MENU, "unpaused menu after " + mode)
		check(is_instance_valid(main._menu), "fresh interactive menu after " + mode)
		check(get_nodes_in_group("player").is_empty(), "no old player after " + mode)
		check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "cursor released after " + mode)
	main.queue_free()
	await process_frame
	print("MENU_SESSION failures: ", fails)
	quit(1 if fails else 0)
