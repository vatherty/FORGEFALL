extends SceneTree

# Native end-to-end acceptance: Studio document -> native scenes/catalog ->
# Forgefall deploy -> player collision probe -> visible screenshot -> cleanup.
const Store = preload("res://studio/shared/document_store.gd")
const Asset = preload("res://studio/shared/asset_document.gd")
const CATALOG := "res://assets/studio/generated/catalog.json"
const CAPTURE := "/tmp/forgefall-studio-house.png"
const INTERIOR_CAPTURE := "/tmp/forgefall-studio-house-interior.png"

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("House acceptance needs a visible renderer for screenshots; run without --headless.")
		quit(1)
		return
	call_deferred("_run")

func _block(name: String, position: Array, size: Array, color: String) -> Dictionary:
	var item: Dictionary = Store.new_instance(name, Vector3(position[0], position[1], position[2]))
	item["position"] = position
	item["size"] = size
	item["color"] = color
	return item

func _run() -> void:
	var id := "house-acceptance-" + str(Time.get_ticks_usec())
	var asset_id := id + "-lift"
	var source := "res://assets/studio/maps/" + id + ".json"
	var asset_source := "res://assets/studio/assets/" + asset_id + ".json"
	var map_scene := "res://assets/studio/generated/maps/" + id + ".tscn"
	var asset_scene := "res://assets/studio/generated/assets/" + asset_id + ".tscn"
	var catalog_before := FileAccess.get_file_as_string(CATALOG) if FileAccess.file_exists(CATALOG) else ""
	var issues: Array[String] = []
	var catalog_ok := true
	if catalog_before != "":
		var parsed: Variant = JSON.parse_string(catalog_before)
		catalog_ok = parsed is Dictionary and parsed.get("version") == 1 and parsed.get("maps") is Dictionary
	if not catalog_ok:
		printerr("House test refused invalid existing Studio catalog.")
		quit(1)
		return
	var lift: Dictionary = Asset.create("Animated House Lift")
	lift["id"] = asset_id
	lift["palette"] = ["#e3ac5e"]
	for x in 8:
		for z in 8:
			lift["voxels"].append({"x": x, "y": 0, "z": z, "material": 0, "layer": 0})
	lift["animations"] = [{"name": "rise", "loop": true, "keys": [
		{"time": 0.0, "position": [0.0, 0.0, 0.0]},
		{"time": 2.0, "position": [0.0, 1.5, 0.0]},
		{"time": 4.0, "position": [0.0, 0.0, 0.0]}
	]}]
	if Asset.validate(lift) != "":
		issues.append("lift asset invalid: " + Asset.validate(lift))
	else:
		var write_error: Error = Store.write_json(ProjectSettings.globalize_path(asset_source), lift)
		if write_error != OK:
			issues.append("lift asset write failed")
	var map: Dictionary = Store.new_map("Studio Walkable House")
	map["id"] = id
	map["instances"] = [
		_block("Floor", [0.0, -0.5, 0.0], [8.0, 0.5, 8.0], "#738394"),
		_block("North Wall Left", [-2.5, 0.0, -4.0], [3.0, 3.0, 0.25], "#d5b68a"),
		_block("North Wall Right", [2.5, 0.0, -4.0], [3.0, 3.0, 0.25], "#d5b68a"),
		_block("South Wall", [0.0, 0.0, 4.0], [8.0, 3.0, 0.25], "#d5b68a"),
		_block("West Wall", [-4.0, 0.0, 0.0], [0.25, 3.0, 8.0], "#bd926d"),
		_block("East Wall", [4.0, 0.0, 0.0], [0.25, 3.0, 8.0], "#bd926d"),
		_block("Roof Left", [-2.0, 3.0, 0.0], [4.0, 0.25, 8.0], "#6c4a3a"),
		_block("Roof Right", [2.0, 3.0, 0.0], [4.0, 0.25, 8.0], "#6c4a3a")
	]
	var spawn: Dictionary = Store.new_instance("Player Spawn", Vector3(0, 1.0, 2.0))
	spawn["kind"] = "marker"
	spawn["marker_type"] = "player_spawn"
	spawn["position"] = [0.0, 1.0, 2.0]
	map["instances"].append(spawn)
	var lamp: Dictionary = Store.new_instance("Ceiling Light", Vector3(0, 2.5, 0))
	lamp["kind"] = "light"
	lamp["position"] = [0.0, 2.5, 0.0]
	lamp["size"] = [7.0, 1.0, 1.0]
	lamp["color"] = "#ffe4ab"
	map["instances"].append(lamp)
	var exterior: Dictionary = Store.new_instance("Exterior Light", Vector3(0, 7, -6))
	exterior["kind"] = "light"
	exterior["position"] = [0.0, 7.0, -6.0]
	exterior["size"] = [20.0, 1.0, 1.0]
	exterior["energy"] = 8.0
	exterior["color"] = "#fff1dc"
	map["instances"].append(exterior)
	var linked: Dictionary = Store.new_instance("Linked Animated Lift", Vector3(2.5, 0.1, 2.5))
	linked["kind"] = "asset"
	linked["asset_id"] = asset_id
	linked["position"] = [2.5, 0.1, 2.5]
	map["instances"].append(linked)
	if Store.validate_map(map) != "":
		issues.append("house map invalid: " + Store.validate_map(map))
	else:
		var write_error: Error = Store.write_json(ProjectSettings.globalize_path(source), map)
		if write_error != OK:
			issues.append("house map write failed")
	if issues.is_empty():
		var command := OS.get_executable_path()
		var output: Array = []
		var code := OS.execute(command, ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tools/studio_generate.gd", "--", "asset", asset_id], output, true)
		if code != 0:
			issues.append("asset publish failed: " + str(output))
		output.clear()
		if issues.is_empty():
			code = OS.execute(command, ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tools/studio_generate.gd", "--", id], output, true)
			if code != 0:
				issues.append("map publish failed: " + str(output))
	if issues.is_empty():
		var reopened: Dictionary = Store.read_json(ProjectSettings.globalize_path(source))
		if reopened.get("id") != id or reopened.get("instances", []).size() != 12:
			issues.append("Studio map failed reopen")
		var catalog: Dictionary = Store.read_json(ProjectSettings.globalize_path(CATALOG))
		if not catalog.get("maps", {}).has(id) or not catalog.get("assets", {}).has(asset_id):
			issues.append("published catalog missing map or linked asset")
	if issues.is_empty():
		var scene_error := change_scene_to_file("res://scenes/main.tscn")
		await process_frame
		await process_frame
		if scene_error != OK or current_scene == null:
			issues.append("Forgefall main scene failed")
		else:
			var main := current_scene
			main.set_selected_map("studio:" + id)
			if not main.start_sp_mode("tdm"):
				issues.append("native deploy refused Studio house")
			else:
				for frame in 160:
					await process_frame
					if main.state == main.State.PLAYING:
						break
				if main.state != main.State.PLAYING:
					issues.append("native deploy did not reach PLAYING")
				else:
					var house: Node3D = main.get_node_or_null("Studio Walkable House")
					if house == null:
						issues.append("published house scene missing at runtime")
					else:
						var player := house.get_node_or_null("Player") as CharacterBody3D
						var lift_node := house.get_node_or_null("Asset_" + linked["id"].replace("-", "_"))
						if player == null:
							issues.append("player missing")
						else:
							var camera := Camera3D.new()
							camera.name = "HouseAcceptanceCamera"
							camera.position = Vector3(8.0, 6.0, -10.0)
							house.add_child(camera)
							camera.look_at(Vector3.ZERO + Vector3.UP * 1.4)
							camera.current = true
							await create_timer(0.5).timeout
							var capture: Image = root.get_texture().get_image()
							if capture.save_png(CAPTURE) != OK:
								issues.append("visible screenshot failed")
							else:
								print("HOUSE_SCREENSHOT: " + CAPTURE + " " + str(capture.get_size()))
							camera.global_position = Vector3(0.0, 1.8, -1.0)
							camera.look_at(Vector3(2.5, 0.8, 2.5))
							await process_frame
							await process_frame
							if root.get_texture().get_image().save_png(INTERIOR_CAPTURE) == OK:
								print("HOUSE_INTERIOR_SCREENSHOT: " + INTERIOR_CAPTURE)
							player.set_physics_process(false)
							player.set_process(false)
							player.global_position = Vector3(0, 1.0, 2.0)
							var floor_hit := player.move_and_collide(Vector3(0, -4, 0))
							var floor_ok := floor_hit != null and player.global_position.y > -0.1 and player.global_position.y < 0.4
							print("HOUSE_FLOOR: hit=", floor_hit != null, " y=", player.global_position.y)
							player.global_position = Vector3(0, 1.0, 2.0)
							for step in 35:
								player.move_and_collide(Vector3(0, 0, -0.22))
							var doorway_ok := player.global_position.z < -4.5
							player.global_position = Vector3(2.5, 1.0, 2.0)
							var wall_hit := false
							for step in 35:
								if player.move_and_collide(Vector3(0, 0, -0.22)) != null:
									wall_hit = true
							var wall_ok := wall_hit and player.global_position.z > -3.9
							var animated_ok := lift_node != null and lift_node.get_node_or_null("AnimationPlayer") != null
							var lift_moves := false
							var lift_anchor_stays := false
							if animated_ok:
								var lift_body := lift_node.get_node_or_null("AnimatedBody") as Node3D
								var lift_player := lift_node.get_node("AnimationPlayer") as AnimationPlayer
								if lift_body != null and lift_player.has_animation("rise"):
									var anchor_before: Vector3 = lift_node.global_position
									lift_player.play("rise")
									await create_timer(0.5).timeout
									lift_moves = lift_body.position.y > 0.1
									lift_anchor_stays = lift_node.global_position.distance_to(anchor_before) < 0.01
							print("HOUSE_PHYSICS: floor=", floor_ok, " doorway=", doorway_ok, " wall=", wall_ok, " lift_moves=", lift_moves, " lift_anchor_stays=", lift_anchor_stays)
							if not floor_ok or not doorway_ok or not wall_ok or not lift_moves or not lift_anchor_stays:
								issues.append("house traversal, collision, or linked animation check failed")
			main.quit_to_menu()
			await process_frame
			await process_frame
			main.queue_free()
			await process_frame
			await process_frame
	# Restore preexisting catalog and remove all temporary source/generated files.
	for path in [source, asset_source, map_scene, asset_scene]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if catalog_before == "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CATALOG))
	else:
		var restore := FileAccess.open(CATALOG, FileAccess.WRITE)
		restore.store_string(catalog_before)
		restore.close()
	call_deferred("_finish", issues)

func _finish(issues: Array[String]) -> void:
	await create_timer(1.0).timeout
	if issues.is_empty():
		print("HOUSE_ACCEPTANCE: PASS")
		quit(0)
	else:
		for issue in issues:
			printerr("HOUSE_ACCEPTANCE: " + issue)
		quit(1)
