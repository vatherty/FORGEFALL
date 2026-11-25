extends SceneTree


func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var base := "res://assets/studio/generated"
	var catalog_path := base + "/catalog.json"
	var id := "studio-native-test-" + str(Time.get_ticks_usec())
	var scene_path := base + "/maps/" + id + ".tscn"
	var behavior_path := base + "/behaviors/" + id + ".gd"
	var previous := FileAccess.get_file_as_string(catalog_path) if FileAccess.file_exists(catalog_path) else ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base + "/maps"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base + "/behaviors"))
	var behavior_file := FileAccess.open(behavior_path, FileAccess.WRITE)
	behavior_file.store_string("extends Node3D\nfunc interact() -> void:\n\tset_meta(\"studio_used\", true)\n")
	behavior_file.close()
	var map := Node3D.new()
	map.name = "StudioNativeTest"
	var spawn := Marker3D.new()
	spawn.name = "Spawn"
	spawn.position = Vector3(2, 3, 4)
	spawn.add_to_group("player_spawn", true)
	map.add_child(spawn)
	spawn.owner = map
	var body := StaticBody3D.new()
	body.name = "Block"
	body.position = Vector3(2, 0, 4)
	body.set_script(load(behavior_path))
	body.add_to_group("studio_interactable", true)
	map.add_child(body)
	body.owner = map
	var shape := CollisionShape3D.new()
	shape.name = "Collision"
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	shape.owner = map
	var scene := PackedScene.new()
	var error := scene.pack(map)
	if error == OK:
		error = ResourceSaver.save(scene, scene_path)
	map.free()
	var catalog := {"version": 1, "maps": {}, "assets": {}}
	if previous != "":
		var parsed: Variant = JSON.parse_string(previous)
		if parsed is Dictionary and parsed.get("maps") is Dictionary:
			catalog = parsed
	catalog["maps"][id] = {"name": "Studio Native Test", "scene": scene_path, "sha256": FileAccess.get_sha256(scene_path)}
	var file := FileAccess.open(catalog_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(catalog))
		file.close()
	var main_script: GDScript = load("res://scripts/core/main.gd")
	var game: Node = main_script.new()
	var entry: Dictionary = game._map_entry("studio:" + id)
	var listed: Array[Dictionary] = game.available_maps()
	game.set_selected_map("studio:" + id)
	var selected := str(game.selected_map_key)
	var found := false
	for item in listed:
		if item["key"] == "studio:" + id:
			found = true
	var generated: Node3D = (load(scene_path) as PackedScene).instantiate()
	root.add_child(generated)
	var markers := get_nodes_in_group("player_spawn")
	var collision := generated.get_node_or_null("Block/Collision")
	var collision_present := collision != null
	generated.queue_free()
	game.free()
	var scene_error := change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var main := current_scene
	var launched := false
	var playing := false
	var player_present := false
	var spawned_at_marker := false
	var interacted := false
	var prompt_visible := false
	if scene_error == OK and main != null:
		main.set_selected_map("studio:" + id)
		launched = main.start_sp_mode("tdm")
		for frame in 100:
			await process_frame
			if main.state == main.State.PLAYING:
				break
		playing = main.state == main.State.PLAYING
		var runtime_map := main.get_node_or_null("StudioNativeTest")
		if runtime_map != null:
			var player := runtime_map.get_node_or_null("Player")
			player_present = player != null
			if player != null:
				spawned_at_marker = Vector2(player.global_position.x, player.global_position.z).distance_to(Vector2(2, 4)) < 0.05
				await process_frame
				prompt_visible = main._studio_prompt.visible
				var interact_event := InputEventAction.new()
				interact_event.action = "interact"
				interact_event.pressed = true
				main._unhandled_input(interact_event)
				interacted = bool(runtime_map.get_node("Block").get_meta("studio_used", false))
	if main != null:
		main.quit_to_menu()
		await process_frame
		await process_frame
		main.queue_free()
		await process_frame
		await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(scene_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(behavior_path))
	if previous == "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(catalog_path))
	else:
		var restore := FileAccess.open(catalog_path, FileAccess.WRITE)
		restore.store_string(previous)
		restore.close()
	var success: bool = error == OK and file != null and found and selected == "studio:" + id and entry.get("scene") == scene_path and markers.size() == 1 and collision_present and launched and playing and player_present and spawned_at_marker and interacted and prompt_visible
	var detail := "error=%s file=%s found=%s selected=%s entry=%s markers=%s collision=%s launched=%s playing=%s player=%s spawn=%s interact=%s prompt=%s" % [error, file != null, found, selected, entry, markers.size(), collision_present, launched, playing, player_present, spawned_at_marker, interacted, prompt_visible]
	# Let this coroutine return and release its PackedScene/GDScript references
	# before quitting Godot. Quitting in this stack can report false leaks.
	call_deferred("_finish", success, detail)

func _finish(success: bool, detail: String) -> void:
	# The PC updater autoload starts an HTTPS check on boot. This playtest
	# does not use updates; cancel its request before shutting the tree down.
	var updater := root.get_node_or_null("UpdaterPC")
	if updater != null:
		updater.set("suppress_auto_check", true)
		var check_http := updater.get("_check_http") as HTTPRequest
		if check_http != null:
			check_http.cancel_request()
	# Scene teardown includes deferred audio/network work; immediate SceneTree
	# exit leaves engine-owned resources alive even for a menu-only boot.
	await create_timer(1.0).timeout
	if success:
		print("Studio game test passed: catalog selection, native deploy, collision, player spawn, behavior interaction")
	else:
		printerr("Studio game test failed: " + detail)
	quit(0 if success else 1)
