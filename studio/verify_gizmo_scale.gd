extends SceneTree

# Reproduction / regression verify for the scale-gizmo report (2026-11-25):
# "in Scale mode (R) I could only scale the Y axis — X and Z didn't work."
#
# Unlike verify_end_to_end.gd (which calls _start_handle_drag directly and
# therefore never exercises picking), this verify drives the REAL input
# path in two ways per axis:
#   Test A — a synthetic press fed to _viewport_input at the handle's exact
#            unprojected (viewport-space) position, then _update_handle_drag
#            + _finish_handle_drag; asserts only that axis's size changed.
#   Test B — a full pipeline click: Input.parse_input_event at the position
#            where the knob is actually DISPLAYED (panel/window space, via
#            the SubViewportContainer with stretch=true), so whatever
#            coordinate space gui_input really delivers is what picking
#            consumes; asserts the drag starts on that axis and the release
#            commits only that axis.
# It also measures the geometry: where the gizmo center and handles sit
# relative to the block's drawn AABB (a handle whose centre is inside the
# block volume or under the floor is a handle the user cannot see or aim
# at), and probes which coordinate space gui_input delivers under stretch.

const Store = preload("res://shared/document_store.gd")

var failures: Array[String] = []
var passes: Array[String] = []
var probe_positions: Array = []

func _check(condition: bool, label: String) -> void:
	if condition:
		passes.append(label)
		print("GIZMO PASS: " + label)
	else:
		failures.append(label)
		printerr("GIZMO FAIL: " + label)

func _initialize() -> void:
	call_deferred("_run")

func _make_fixture() -> String:
	var fixture := ProjectSettings.globalize_path("user://studio_gizmo_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(fixture)
	var config := FileAccess.open(fixture.path_join("project.godot"), FileAccess.WRITE)
	config.store_string("config_version=5\n[application]\nconfig/name=\"Forgefall\"\n")
	config.close()
	return fixture

# Reset through _apply so the command-history chain stays valid (writing
# map_doc directly desyncs the chain head and history.execute then refuses
# later edits — including the gizmo's own commit).
func _reset_block(studio: Control, size: Array) -> void:
	var next_doc: Dictionary = studio.map_doc.duplicate(true)
	for item in next_doc["instances"]:
		if item["id"] == studio.selected_id:
			item["size"] = [float(size[0]), float(size[1]), float(size[2])]
			item["position"] = [0.0, 0.0, 0.0]
	studio._apply("verify setup", next_doc)

func _block_aabb(studio: Control) -> AABB:
	var item: Dictionary = studio._selected()
	var pos := Vector3(item["position"][0], item["position"][1], item["position"][2])
	var size := Vector3(item["size"][0], item["size"][1], item["size"][2])
	# Matches _refresh_geometry: block mesh node sits at pos + (0, size.y/2, 0)
	# with a centred BoxMesh of the instance size.
	return AABB(pos - Vector3(size.x, 0.0, size.z) * 0.5, size)

func _press_event(at: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	return event

func _run() -> void:
	var fixture := _make_fixture()
	var studio: Control = load("res://main.tscn").instantiate()
	root.add_child(studio)
	await process_frame
	await process_frame
	await process_frame

	var panel_size: Vector2 = studio.viewport_panel.size
	var vp_size := Vector2(studio.viewport.size)
	var stretch := Vector2(panel_size.x / vp_size.x, panel_size.y / vp_size.y)
	var screen_xform := root.get_screen_transform()
	print("GIZMO MEASURE: root window=", root.size, " panel size=", panel_size, " viewport size=", studio.viewport.size, " stretch factor=", stretch, " screen xform scale=", screen_xform.get_scale())

	# --- Probe: which coordinate space does gui_input deliver under stretch?
	studio.viewport_panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			probe_positions.append(event.position))
	var panel_rect: Rect2 = studio.viewport_panel.get_global_rect()
	var probe_local: Vector2 = panel_size * 0.5
	var probe_window: Vector2 = screen_xform * (panel_rect.position + probe_local)
	var probe_event := _press_event(probe_window)
	probe_event.global_position = probe_window
	Input.parse_input_event(probe_event)
	await process_frame
	await process_frame
	if probe_positions.is_empty():
		print("GIZMO PROBE: no gui_input event delivered via parse_input_event (inconclusive)")
	else:
		var delivered: Vector2 = probe_positions[0]
		var as_viewport: Vector2 = probe_local / stretch
		print("GIZMO PROBE: clicked panel-local=", probe_local, " gui_input delivered=", delivered,
			" | container-space candidate=", probe_local, " viewport-space candidate=", as_viewport)
		if delivered.distance_to(probe_local) < 2.0:
			print("GIZMO PROBE VERDICT: gui_input delivers CONTAINER-space positions")
		elif delivered.distance_to(as_viewport) < 2.0:
			print("GIZMO PROBE VERDICT: gui_input delivers VIEWPORT-space positions")
		else:
			print("GIZMO PROBE VERDICT: delivered position matches neither candidate")

	studio._open_project(fixture)
	studio._new_map()
	studio._add_block()
	_check(studio.map_doc["instances"].size() == 1, "one block in map")
	studio._set_gizmo_mode("scale")
	_check(studio.gizmo_mode == "scale", "gizmo mode is scale")

	for config in [[1.0, 1.0, 1.0], [4.0, 2.0, 4.0]]:
		_reset_block(studio, config)
		studio._focus_selected()
		var aabb := _block_aabb(studio)
		var center: Vector3 = studio._gizmo_center()
		var handles: Dictionary = studio._gizmo_handle_positions()
		var cam: Camera3D = studio.camera
		var center_screen := cam.unproject_position(center)
		print("GIZMO MEASURE: block size=", config, " AABB=", aabb, " gizmo center=", center,
			" (visual centre=", aabb.get_center(), ") center screen=", center_screen)
		for axis in 3:
			var handle_pos: Vector3 = handles[axis]
			var handle_screen := cam.unproject_position(handle_pos)
			var inside := aabb.grow(-0.001).has_point(handle_pos)
			print("GIZMO MEASURE: size=", config, " axis=", axis,
				" handle world=", handle_pos, " screen=", handle_screen,
				" dist-to-centre=", snappedf(handle_screen.distance_to(center_screen), 0.1), "px",
				" height-above-block-base=", snappedf(handle_pos.y - aabb.position.y, 0.01),
				" INSIDE-BLOCK=", inside)

		# --- Test A: press in viewport space, exactly on the handle --------
		for axis in 3:
			_reset_block(studio, config)
			studio._focus_selected()
			var handle_screen := cam.unproject_position(studio._gizmo_handle_positions()[axis])
			studio._viewport_input(_press_event(handle_screen))
			_check(studio.drag_axis == axis and studio.drag_kind == "scale",
				"A size=%s axis=%d: viewport-space press on handle starts %s drag (drag_axis=%d)" % [str(config), axis, "XYZ"[axis], studio.drag_axis])
			if studio.drag_axis == axis:
				studio._update_handle_drag(handle_screen + Vector2(60, -20))
				studio._finish_handle_drag()
				var size: Array = studio._selected()["size"]
				var grew := float(size[axis]) >= float(config[axis]) + 0.5
				var others_same := true
				for other in 3:
					if other != axis and not is_equal_approx(float(size[other]), float(config[other])):
						others_same = false
				_check(grew and others_same,
					"A size=%s axis=%d: drag changed only %s (size now %s)" % [str(config), axis, "XYZ"[axis], str(size)])
			else:
				studio._finish_handle_drag()

		# --- Test B: full pipeline click where the knob is displayed -------
		for axis in 3:
			_reset_block(studio, config)
			studio._focus_selected()
			var handle_screen := cam.unproject_position(studio._gizmo_handle_positions()[axis])
			var click_local: Vector2 = handle_screen * stretch
			var click_window: Vector2 = screen_xform * (panel_rect.position + click_local)
			var pos_before: Array = (studio._selected()["position"] as Array).duplicate()
			var press := _press_event(click_window)
			press.global_position = click_window
			Input.parse_input_event(press)
			await process_frame
			await process_frame
			_check(studio.drag_axis == axis and studio.drag_kind == "scale",
				"B size=%s axis=%d: real click on displayed knob starts %s drag (drag_axis=%d, fell_through_to_instance_drag=%s)" % [str(config), axis, "XYZ"[axis], studio.drag_axis, str(studio.dragging_instance)])
			var motion := InputEventMouseMotion.new()
			motion.position = click_window + screen_xform.basis_xform(Vector2(60, -20))
			motion.global_position = motion.position
			Input.parse_input_event(motion)
			await process_frame
			var release := InputEventMouseButton.new()
			release.button_index = MOUSE_BUTTON_LEFT
			release.pressed = false
			release.position = motion.position
			release.global_position = motion.position
			Input.parse_input_event(release)
			await process_frame
			await process_frame
			var item: Dictionary = studio._selected()
			var size: Array = item["size"]
			var grew := float(size[axis]) >= float(config[axis]) + 0.5
			var others_same := true
			for other in 3:
				if other != axis and not is_equal_approx(float(size[other]), float(config[other])):
					others_same = false
			_check(grew and others_same,
				"B size=%s axis=%d: real drag changed only %s (size now %s, position untouched=%s)" % [str(config), axis, "XYZ"[axis], str(size), str(item["position"] == pos_before)])
			studio.dragging_instance = false
			studio.drag_kind = ""
			studio.drag_axis = -1

	print("GIZMO SUMMARY: ", passes.size(), " passed, ", failures.size(), " failed")
	if failures.is_empty():
		quit(0)
	else:
		for failure in failures:
			printerr("GIZMO FAILED: " + failure)
		quit(1)
