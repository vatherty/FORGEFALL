extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _button(index: int) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = index
	event.pressed = true
	return event

func _run() -> void:
	var settings_path := ProjectSettings.globalize_path("user://studio_settings.cfg")
	var had_settings := FileAccess.file_exists(settings_path)
	var original_settings := FileAccess.get_file_as_string(settings_path) if had_settings else ""
	var scene: PackedScene = load("res://main.tscn")
	var studio: Control = scene.instantiate()
	root.add_child(studio)
	var fixture := ProjectSettings.globalize_path("user://control_fixture_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(fixture)
	var file := FileAccess.open(fixture.path_join("project.godot"), FileAccess.WRITE)
	file.store_string("config_version=5\n[application]\nconfig/name=\"Forgefall\"\n")
	file.close()
	studio._open_project(fixture)
	studio._new_map()
	studio._input(_button(studio.gamepad_buttons["palette"]))
	assert(studio.tool_palette.visible)
	studio._input(_button(studio.gamepad_buttons["activate"]))
	assert(not studio.tool_palette.visible)
	assert(studio.map_doc["instances"].size() == 1)
	studio._input(_button(studio.gamepad_buttons["undo"]))
	assert(studio.map_doc["instances"].is_empty())
	studio._input(_button(studio.gamepad_buttons["redo"]))
	assert(studio.map_doc["instances"].size() == 1)
	var original_undo: int = studio.gamepad_buttons["undo"]
	studio._set_gamepad_button("undo", 16)
	assert(studio.gamepad_buttons["undo"] == 16)
	studio._input(_button(16))
	assert(studio.map_doc["instances"].is_empty())
	studio._set_gamepad_button("undo", original_undo)
	studio._input(_button(studio.gamepad_buttons["redo"]))
	studio._add_block()
	var first_id: String = studio.map_doc["instances"][0]["id"]
	studio._input(_button(studio.gamepad_buttons["select_previous"]))
	assert(studio.selected_id == first_id)
	studio._input(_button(studio.gamepad_buttons["palette"]))
	studio._input(_button(studio.gamepad_buttons["next"]))
	assert(studio.palette_index == 1)
	studio._input(_button(studio.gamepad_buttons["close"]))
	assert(not studio.tool_palette.visible)
	var yaw: float = studio.camera_yaw
	var drag := InputEventScreenDrag.new()
	drag.relative = Vector2(15, 0)
	studio._viewport_input(drag)
	assert(studio.camera_yaw != yaw)
	var distance: float = studio.camera_distance
	var magnify := InputEventMagnifyGesture.new()
	magnify.factor = 1.5
	studio._viewport_input(magnify)
	assert(studio.camera_distance < distance)
	var focus: Vector3 = studio.camera_focus
	var pan := InputEventPanGesture.new()
	pan.delta = Vector2(5, 0)
	studio._viewport_input(pan)
	assert(studio.camera_focus != focus)
	studio._toggle_hierarchy_panel()
	assert(not studio.hierarchy_panel.visible)
	studio._reset_layout()
	assert(studio.hierarchy_panel.visible and studio.inspector_panel.visible)
	studio.free()
	if had_settings:
		var restore := FileAccess.open(settings_path, FileAccess.WRITE)
		restore.store_string(original_settings)
		restore.close()
	else:
		DirAccess.remove_absolute(settings_path)
	print("Controls test passed: gamepad palette, remap, selection, undo/redo, touch gestures, layout")
	quit()
