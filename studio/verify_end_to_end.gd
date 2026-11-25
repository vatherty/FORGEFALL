extends SceneTree

# Combined end-to-end acceptance scenario (plan.md stage 3 / end-to-end):
# one run that authors and publishes a voxel library asset, a weapon and a
# character, builds a map in the editor using the gizmo handles, a behavior,
# lights/volumes/markers/navigation and an AI proposal, saves, publishes,
# reopens, and then functionally probes the published scene inside the
# target project (behavior fires, character spawns, weapon hits a target).

const Store = preload("res://shared/document_store.gd")
const Asset = preload("res://shared/asset_document.gd")
const Content = preload("res://content_document.gd")

var failures: Array[String] = []
var passes: Array[String] = []

const PROBE_SOURCE := """
extends SceneTree

var failures: Array[String] = []
var passes: Array[String] = []

func _check(condition: bool, label: String) -> void:
	if condition:
		passes.append(label)
		print("PROBE PASS: " + label)
	else:
		failures.append(label)
		printerr("PROBE FAIL: " + label)

func _find_class(node: Node, klass: String) -> Node:
	if node.is_class(klass):
		return node
	for child in node.get_children():
		var found := _find_class(child, klass)
		if found != null:
			return found
	return null

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var map_id := str(args[0])
	var char_health := float(args[1])
	var weapon_damage := float(args[2])
	var scene := load("res://assets/studio/generated/maps/" + map_id + ".tscn") as PackedScene
	_check(scene != null, "published map scene loads")
	if scene == null:
		_done()
		return
	var map := scene.instantiate()
	root.add_child(map)
	await physics_frame
	await physics_frame
	var asset_node: Node3D = null
	for child in map.get_children():
		if child.name.begins_with("Asset_"):
			asset_node = child
	_check(asset_node != null, "published voxel library asset instance present")
	if asset_node != null:
		_check(absf(asset_node.rotation_degrees.y - 45.0) < 0.01, "gizmo rotation baked into published asset (Y = 45)")
		_check(absf(asset_node.scale.x - 2.0) < 0.01, "gizmo scale baked into published asset (X = 2)")
		var has_body := false
		for child in asset_node.get_children():
			if child is StaticBody3D:
				has_body = true
		_check(has_body, "asset collision body present")
	var interactables := get_nodes_in_group("studio_interactable")
	_check(not interactables.is_empty(), "behavior node baked into studio_interactable group")
	if not interactables.is_empty():
		var behavior_node: Node = interactables[0]
		behavior_node.call("interact")
		_check(bool(behavior_node.get_meta("used", false)), "attached behavior fires on interact()")
	_check(_find_class(map, "OmniLight3D") != null, "light baked as OmniLight3D")
	var area := _find_class(map, "Area3D")
	_check(area != null and str(area.get_meta("volume_type", "")) == "trigger", "volume baked as Area3D trigger")
	_check(not get_nodes_in_group("player_spawn").is_empty(), "player_spawn marker baked")
	_check(_find_class(map, "NavigationRegion3D") != null, "navigation region baked")
	var spawns := get_nodes_in_group("character_spawn")
	_check(not spawns.is_empty(), "character_spawn marker baked")
	var character: Node3D = null
	var weapon: Node3D = null
	if not spawns.is_empty():
		character = spawns[0].get_node_or_null("Character")
	_check(character != null, "authored character spawned at marker")
	if character != null:
		_check(character.is_in_group("studio_character"), "character in studio_character group")
		_check(absf(float(character.get_meta("studio_health", 0.0)) - char_health) < 0.01, "character health matches authored document")
		weapon = character.get_node_or_null("Body/Hand/Weapon")
		_check(weapon != null and weapon.has_method("fire"), "authored weapon in character hand with fire()")
	if character != null and weapon != null:
		var target: CharacterBody3D = load("res://scripts/e2e_target.gd").new()
		target.name = "E2ETarget"
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 0.6
		shape.shape = sphere
		shape.position.y = 0.9
		target.add_child(shape)
		target.add_to_group("player")
		target.position = character.global_position + Vector3(0, 0, -4)
		root.add_child(target)
		var frames := 0
		while float(target.get("total")) <= 0.0 and frames < 600:
			await physics_frame
			frames += 1
		_check(float(target.get("total")) >= weapon_damage, "character auto-fired authored weapon and damaged target (total " + str(target.get("total")) + ")")
		_check(int(weapon.get("ammunition")) < int(weapon.get("magazine_size")), "weapon ammunition consumed by firing")
	_done()

func _done() -> void:
	if failures.is_empty():
		print("E2E PROBE PASS: " + str(passes.size()) + " checks")
		quit(0)
	else:
		printerr("E2E PROBE FAILED: " + str(failures))
		quit(1)
"""

const TARGET_SOURCE := """
extends CharacterBody3D

var total := 0.0

func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool) -> void:
	total += amount
"""

func _check(condition: bool, label: String) -> void:
	if condition:
		passes.append(label)
		print("E2E PASS: " + label)
	else:
		failures.append(label)
		printerr("E2E FAIL: " + label)

func _godot() -> String:
	var executable := OS.get_environment("GODOT_EDITOR_PATH")
	return executable if executable != "" else OS.get_executable_path()

func _run_generator(fixture: String, script: String, args: Array) -> int:
	var output := []
	var full_args := ["--headless", "--path", fixture, "--script", script, "--"]
	full_args.append_array(args)
	var code := OS.execute(_godot(), full_args, output, true)
	if code != 0:
		printerr("Generator failed (" + script + "): " + (str(output[0]) if not output.is_empty() else ""))
	return code

func _copy_into(fixture: String, source: String, destination: String) -> void:
	DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
	var file := FileAccess.open(destination, FileAccess.WRITE)
	file.store_string(FileAccess.get_file_as_string(ProjectSettings.globalize_path(source)))
	file.close()

func _move_selected(studio: Control, x: float, y: float, z: float) -> void:
	studio._edit_axis(str(x), 0)
	studio._edit_axis(str(y), 1)
	studio._edit_axis(str(z), 2)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var fixture := ProjectSettings.globalize_path("user://studio_e2e_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(fixture.path_join("assets/studio/generated/behaviors"))
	var config := FileAccess.open(fixture.path_join("project.godot"), FileAccess.WRITE)
	config.store_string("config_version=5\n[application]\nconfig/name=\"Forgefall\"\n")
	config.close()
	for name in ["document_store.gd", "asset_document.gd", "voxel_mesh.gd"]:
		_copy_into(fixture, "res://shared/" + name, fixture.path_join("studio/shared/" + name))
	for name in ["content_document.gd", "content_runtime.gd"]:
		_copy_into(fixture, "res://" + name, fixture.path_join("studio/" + name))
	for name in ["studio_generate.gd", "studio_content_generate.gd"]:
		_copy_into(fixture, "res://../tools/" + name, fixture.path_join("tools/" + name))
	for name in ["studio_character.gd", "studio_weapon.gd", "studio_catalog.gd"]:
		_copy_into(fixture, "res://../scripts/studio/" + name, fixture.path_join("scripts/studio/" + name))
	var probe_file := FileAccess.open(fixture.path_join("tools/e2e_probe.gd"), FileAccess.WRITE)
	probe_file.store_string(PROBE_SOURCE)
	probe_file.close()
	var target_file := FileAccess.open(fixture.path_join("scripts/e2e_target.gd"), FileAccess.WRITE)
	target_file.store_string(TARGET_SOURCE)
	target_file.close()

	# --- Author and publish a voxel library asset -------------------------
	var asset: Dictionary = Asset.create("E2E Crate")
	asset["voxels"] = [
		{"x": 0, "y": 0, "z": 0, "material": 0, "layer": 0},
		{"x": 1, "y": 0, "z": 0, "material": 1, "layer": 0},
		{"x": 0, "y": 1, "z": 0, "material": 2, "layer": 0},
	]
	_check(Store.write_json(Asset.path(fixture, str(asset["id"])), asset) == OK, "voxel asset document written")
	_check(_run_generator(fixture, "res://tools/studio_generate.gd", ["asset", str(asset["id"])]) == 0, "voxel asset published via studio_generate")
	var catalog: Dictionary = Store.read_json(fixture.path_join("assets/studio/generated/catalog.json"))
	_check(catalog.get("assets", {}).has(str(asset["id"])), "asset present in catalog")

	# --- Author and publish a weapon, then a character holding it ---------
	var weapon: Dictionary = Content.new_weapon("E2E Blaster")
	weapon["damage"] = 22.0
	_check(Content.validate(weapon) == "", "weapon document valid")
	_check(Store.write_json(Content.path(fixture, weapon), weapon) == OK, "weapon document written")
	_check(_run_generator(fixture, "res://tools/studio_content_generate.gd", ["weapon", str(weapon["id"])]) == 0, "weapon published via studio_content_generate")
	var character: Dictionary = Content.new_character("E2E Guard")
	character["weapon_id"] = str(weapon["id"])
	character["health"] = 80.0
	character["move_speed"] = 0.0
	_check(Content.validate(character) == "", "character document valid")
	_check(Store.write_json(Content.path(fixture, character), character) == OK, "character document written")
	_check(_run_generator(fixture, "res://tools/studio_content_generate.gd", ["character", str(character["id"])]) == 0, "character published via studio_content_generate")
	catalog = Store.read_json(fixture.path_join("assets/studio/generated/catalog.json"))
	_check(catalog.get("weapons", {}).has(str(weapon["id"])), "weapon present in catalog")
	_check(catalog.get("characters", {}).has(str(character["id"])), "character present in catalog")

	# --- Publish a behavior script the map will attach --------------------
	var behavior_file := FileAccess.open(fixture.path_join("assets/studio/generated/behaviors/e2e-behavior.gd"), FileAccess.WRITE)
	behavior_file.store_string("extends Node3D\nfunc interact() -> void:\n\tset_meta(\"used\", true)\n")
	behavior_file.close()

	# --- Build the map in the editor --------------------------------------
	var studio: Control = load("res://main.tscn").instantiate()
	root.add_child(studio)
	studio._open_project(fixture)
	_check(studio.project_path == fixture, "editor opened fixture project")
	studio._new_map()
	studio._place_asset(Asset.path(fixture, str(asset["id"])))
	_check(studio.map_doc["instances"].size() == 1, "library asset placed in map")
	_check(str(studio.map_doc["instances"][0].get("asset_id", "")) == str(asset["id"]), "placed instance references published asset")
	_move_selected(studio, 3, 0, 3)

	# Gizmo rotate: drag the Y handle 90 px -> +45 degrees, one undoable command.
	studio._set_gizmo_mode("rotate")
	_check(studio.gizmo_mode == "rotate", "gizmo mode switched to rotate")
	_check(studio._gizmo_handle_positions().size() == 3, "rotate gizmo exposes three axis handles")
	studio._start_handle_drag("rotate", 1, Vector2(100, 100))
	studio._update_handle_drag(Vector2(190, 100))
	_check(is_equal_approx(float(studio.drag_current_values[1]), 45.0), "rotate drag previews 45 degrees")
	studio._finish_handle_drag()
	_check(is_equal_approx(float(studio.map_doc["instances"][0]["rotation"][1]), 45.0), "rotate gizmo committed rotation to document")
	studio._undo()
	_check(is_equal_approx(float(studio.map_doc["instances"][0].get("rotation", [0, 0, 0])[1]), 0.0), "rotate gizmo edit undone through command history")
	studio._redo()
	_check(is_equal_approx(float(studio.map_doc["instances"][0]["rotation"][1]), 45.0), "rotate gizmo edit redone through command history")

	# Gizmo scale: drag the X handle 100 px -> asset scale X 1.0 to 2.0.
	studio._set_gizmo_mode("scale")
	studio._start_handle_drag("scale", 0, Vector2(100, 100))
	studio._update_handle_drag(Vector2(200, 100))
	studio._finish_handle_drag()
	_check(is_equal_approx(float(studio.map_doc["instances"][0]["scale"][0]), 2.0), "scale gizmo committed asset scale to document")

	# Block with the behavior attached; gizmo-scale its size on Z.
	studio._add_block()
	studio._edit_property("e2e-behavior", "behavior_id")
	_check(str(studio.map_doc["instances"][1].get("behavior_id", "")) == "e2e-behavior", "behavior attached to block")
	studio._start_handle_drag("scale", 2, Vector2.ZERO)
	studio._update_handle_drag(Vector2(0, -50))
	studio._finish_handle_drag()
	_check(is_equal_approx(float(studio.map_doc["instances"][1]["size"][2]), 1.5), "scale gizmo committed block size to document")
	_move_selected(studio, 4, 0, -3)

	studio._add_feature("light")
	_move_selected(studio, -4, 2, -4)
	studio._add_feature("volume")
	_move_selected(studio, 0, 0, 6)
	studio._add_feature("marker")
	_move_selected(studio, 2, 0, 0)
	studio._add_feature("marker")
	studio._edit_property("character_spawn", "marker_type")
	studio._edit_property(str(character["id"]), "character_id")
	_move_selected(studio, -3, 0, -2)
	studio._add_feature("navigation")
	_check(studio.map_doc["instances"].size() == 7, "map holds asset, block, light, volume, two markers, navigation")

	# AI proposal through the normal preview/apply path (pasted JSON).
	studio._open_ai_assistant()
	var assistant: Window = studio.get_node("AIProposals")
	_check(assistant != null, "AI assistant opened from editor")
	assistant.response_edit.text = "{\"actions\":[{\"type\":\"add_block\",\"name\":\"E2E AI Block\",\"position\":[6,0,6]}]}"
	assistant._preview()
	_check(not assistant.apply_button.disabled, "AI proposal preview accepted without mutating map")
	_check(studio.map_doc["instances"].size() == 7, "AI preview left map untouched")
	assistant._apply()
	_check(studio.map_doc["instances"].size() == 8, "AI proposal applied through command path")
	var ai_found := false
	for item in studio.map_doc["instances"]:
		if str(item.get("name", "")) == "E2E AI Block":
			ai_found = true
	_check(ai_found, "AI-added block present in document")

	# --- Save, publish, reopen --------------------------------------------
	var map_id: String = studio.map_doc["id"]
	_check(studio._save(), "map saved")
	studio._publish_map()
	_check(studio.status.text.contains("Published"), "map published (" + studio.status.text + ")")
	var scene_path := fixture.path_join("assets/studio/generated/maps/" + map_id + ".tscn")
	_check(FileAccess.file_exists(scene_path), "published map scene exists")
	var scene_text := FileAccess.get_file_as_string(scene_path)
	for needle in ["studio_interactable", "e2e-behavior", "OmniLight3D", "Area3D", "NavigationRegion3D", "player_spawn", "character_spawn", "StaticBody3D"]:
		_check(scene_text.contains(needle), "published scene contains " + needle)
	catalog = Store.read_json(fixture.path_join("assets/studio/generated/catalog.json"))
	_check(str(catalog["maps"][map_id]["scene"]) == "res://assets/studio/generated/maps/" + map_id + ".tscn", "catalog maps entry points at published scene")

	studio._open_map(Store.map_path(fixture, map_id))
	_check(studio.map_doc["instances"].size() == 8, "reopened map keeps all eight instances")
	var reopened_asset: Dictionary = {}
	var reopened_block: Dictionary = {}
	var reopened_spawn: Dictionary = {}
	var reopened_ai := false
	for item in studio.map_doc["instances"]:
		if str(item.get("asset_id", "")) == str(asset["id"]):
			reopened_asset = item
		if str(item.get("behavior_id", "")) == "e2e-behavior":
			reopened_block = item
		if str(item.get("marker_type", "")) == "character_spawn":
			reopened_spawn = item
		if str(item.get("name", "")) == "E2E AI Block":
			reopened_ai = true
	_check(not reopened_asset.is_empty() and is_equal_approx(float(reopened_asset["rotation"][1]), 45.0), "reopened asset keeps gizmo rotation")
	_check(not reopened_asset.is_empty() and is_equal_approx(float(reopened_asset["scale"][0]), 2.0), "reopened asset keeps gizmo scale")
	_check(not reopened_block.is_empty() and is_equal_approx(float(reopened_block["size"][2]), 1.5), "reopened block keeps gizmo size and behavior")
	_check(str(reopened_spawn.get("character_id", "")) == str(character["id"]), "reopened character spawn keeps character reference")
	_check(reopened_ai, "reopened map keeps AI-added block")

	# --- Functional probe inside the target project ------------------------
	var probe_output := []
	var probe_code := OS.execute(_godot(), ["--headless", "--path", fixture, "--script", "res://tools/e2e_probe.gd", "--", map_id, "80.0", "22.0"], probe_output, true)
	for line in probe_output:
		print(line)
	_check(probe_code == 0, "functional probe exited 0")
	_check(not probe_output.is_empty() and str(probe_output[0]).contains("E2E PROBE PASS"), "functional probe passed all runtime checks")

	if failures.is_empty():
		print("End-to-end test passed: " + str(passes.size()) + " checks — asset, weapon, character, gizmo rotate/scale, behavior, light, volume, markers, navigation, AI proposal, save, publish, reopen, runtime probe")
		quit(0)
	else:
		printerr("End-to-end FAILED (" + str(failures.size()) + "): " + str(failures))
		quit(1)
