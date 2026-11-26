extends Control

const Store = preload("res://shared/document_store.gd")
const Asset = preload("res://shared/asset_document.gd")
const Mesher = preload("res://shared/voxel_mesh.gd")
const History = preload("res://command_history.gd")
const McpServer = preload("res://mcp_server.gd")

var project_path := ""
var map_doc: Dictionary = {}
var saved_text := ""
var disk_text := ""
var history := History.new()
var selected_id := ""
var drag_start: Vector3 = Vector3.ZERO
var drag_current: Vector3 = Vector3.ZERO
var dragging_instance := false
var drag_mouse_start := Vector2.ZERO
var gizmo_mode := "move"
var drag_kind := ""
var drag_axis := -1
var drag_property := ""
var drag_start_values: Array = []
var drag_current_values: Array = []
var mode := "Edit"
var camera_distance := 10.0
var camera_yaw := 0.6
var camera_pitch := 0.5
var camera_focus := Vector3.ZERO
var navigation_mode := false
var settings := ConfigFile.new()
var shortcut_keys := {"save": KEY_S, "undo": KEY_Z, "redo": KEY_Y, "delete": KEY_DELETE, "focus": KEY_F}
var pending_shortcut := ""
var shortcut_buttons := {}
var gamepad_buttons := {"palette": JOY_BUTTON_LEFT_SHOULDER, "previous": JOY_BUTTON_DPAD_LEFT, "next": JOY_BUTTON_DPAD_RIGHT, "select_previous": JOY_BUTTON_DPAD_UP, "select_next": JOY_BUTTON_DPAD_DOWN, "activate": JOY_BUTTON_A, "close": JOY_BUTTON_B, "undo": JOY_BUTTON_X, "redo": JOY_BUTTON_Y, "focus": JOY_BUTTON_RIGHT_SHOULDER}
var pending_gamepad := ""
var gamepad_binding_buttons := {}
var tool_palette: PanelContainer
var tool_grid: GridContainer
var tool_actions: Array[Dictionary] = []
var palette_index := 0

var web_map_window: Window
var controls_dialog: AcceptDialog
var outer_split: HSplitContainer
var inner_split: HSplitContainer
var hierarchy_panel: VBoxContainer
var inspector_panel: ScrollContainer

var status: Label
var title: Label
var hierarchy: ItemList
var inspector: VBoxContainer
var viewport: SubViewport
var camera: Camera3D
var world: Node3D
var viewport_panel: SubViewportContainer
var folder_dialog: FileDialog
var map_dialog: FileDialog
var asset_dialog: FileDialog
var recovery_dialog: ConfirmationDialog
var autosave_timer: Timer
var mcp_server: Node

func _ready() -> void:
	settings.load("user://studio_settings.cfg")
	navigation_mode = bool(settings.get_value("workspace", "navigation_mode", false))
	for action in shortcut_keys:
		shortcut_keys[action] = int(settings.get_value("shortcuts", action, shortcut_keys[action]))
	for action in gamepad_buttons:
		gamepad_buttons[action] = int(settings.get_value("gamepad", action, gamepad_buttons[action]))
	_build_ui()
	_update_camera()
	_refresh()
	autosave_timer = Timer.new()
	autosave_timer.wait_time = 15.0
	autosave_timer.autostart = true
	autosave_timer.timeout.connect(_autosave)
	add_child(autosave_timer)
	_setup_mcp_server()

func _build_ui() -> void:
	var studio_theme := Theme.new()
	studio_theme.default_font_size = 16
	theme = studio_theme
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var toolbar := HFlowContainer.new()
	root.add_child(toolbar)
	if OS.has_feature("web"):
		_button(toolbar, "Web Map", _open_web_map)
		_button(toolbar, "Save JSON", _save_web_map)
	else:
		_button(toolbar, "Open Project", _choose_project)
		_button(toolbar, "New Map", _new_map)
		_button(toolbar, "Open Map", _choose_map)
		_button(toolbar, "Save", _save)
		_button(toolbar, "Save As", _save_as)
		_button(toolbar, "Publish", _publish_map)
		_button(toolbar, "Workshop", _open_workshop)
		_button(toolbar, "Behaviors", _open_behavior_workspace)
		_button(toolbar, "Content", _open_content_workshop)
	_button(toolbar, "AI Assist", _open_ai_assistant)
	if not OS.has_feature("web"):
		_button(toolbar, "MCP: Off", _toggle_mcp_server)
	_button(toolbar, "Undo", _undo)
	_button(toolbar, "Redo", _redo)
	_button(toolbar, "+ Block", _add_block)
	if not OS.has_feature("web"):
		_button(toolbar, "+ Asset", _choose_asset)
	_button(toolbar, "+ Marker", _add_feature.bind("marker"))
	_button(toolbar, "+ Light", _add_feature.bind("light"))
	_button(toolbar, "+ Volume", _add_feature.bind("volume"))
	_button(toolbar, "+ Nav", _add_feature.bind("navigation"))
	_button(toolbar, "Group", _group_selected)
	_button(toolbar, "Gizmo: Move", _cycle_gizmo_mode)
	_button(toolbar, "Delete", _delete_selected)
	_button(toolbar, "Focus", _focus_selected)	
	_button(toolbar, "Mode: " + ("Navigate" if navigation_mode else "Edit"), _toggle_navigation_mode)
	_button(toolbar, "Deck Controls", _show_controls)
	_button(toolbar, "Hierarchy Panel", _toggle_hierarchy_panel)
	_button(toolbar, "Inspector Panel", _toggle_inspector_panel)
	_button(toolbar, "Reset Layout", _reset_layout)	
	title = Label.new()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(title)
	var content := HSplitContainer.new()
	outer_split = content
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)
	var left := VBoxContainer.new()
	hierarchy_panel = left
	left.visible = bool(settings.get_value("workspace", "hierarchy_visible", true))
	left.custom_minimum_size.x = 205
	content.add_child(left)
	left.add_child(_label("Hierarchy"))
	hierarchy = ItemList.new()
	hierarchy.select_mode = ItemList.SELECT_MULTI
	hierarchy.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hierarchy.item_selected.connect(_select_index)
	left.add_child(hierarchy)
	var center_right := HSplitContainer.new()
	inner_split = center_right
	center_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(center_right)
	viewport_panel = SubViewportContainer.new()
	viewport_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport_panel.stretch = true
	viewport_panel.gui_input.connect(_viewport_input)
	center_right.add_child(viewport_panel)
	viewport = SubViewport.new()
	viewport.size = Vector2i(700, 600)
	viewport.size_2d_override_stretch = true
	viewport.transparent_bg = false
	viewport_panel.add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	camera = Camera3D.new()
	camera.current = true
	world.add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	world.add_child(light)
	var grid := MeshInstance3D.new()
	var floor := PlaneMesh.new()
	floor.size = Vector2(80, 80)
	grid.mesh = floor
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color("#303a45")
	ground_mat.roughness = 1.0
	grid.material_override = ground_mat
	world.add_child(grid)
	var grid_mesh := ImmediateMesh.new()
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.albedo_color = Color("#5b6774")
	grid_mesh.surface_begin(Mesh.PRIMITIVE_LINES, line_material)
	for i in range(-20, 21):
		grid_mesh.surface_add_vertex(Vector3(i, 0.015, -20))
		grid_mesh.surface_add_vertex(Vector3(i, 0.015, 20))
		grid_mesh.surface_add_vertex(Vector3(-20, 0.015, i))
		grid_mesh.surface_add_vertex(Vector3(20, 0.015, i))
	grid_mesh.surface_end()
	var grid_lines := MeshInstance3D.new()
	grid_lines.mesh = grid_mesh
	world.add_child(grid_lines)
	var right := ScrollContainer.new()
	inspector_panel = right
	right.visible = bool(settings.get_value("workspace", "inspector_visible", true))
	right.custom_minimum_size.x = 255
	center_right.add_child(right)
	inspector = VBoxContainer.new()
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(inspector)
	status = _label("Select a Forgefall source directory to begin.")
	root.add_child(status)
	_build_tool_palette()
	folder_dialog = FileDialog.new()
	folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	folder_dialog.dir_selected.connect(_open_project)
	add_child(folder_dialog)
	map_dialog = FileDialog.new()
	map_dialog.access = FileDialog.ACCESS_FILESYSTEM
	map_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	map_dialog.add_filter("*.json", "Studio map")
	map_dialog.file_selected.connect(_open_map)
	add_child(map_dialog)
	asset_dialog = FileDialog.new()
	asset_dialog.access = FileDialog.ACCESS_FILESYSTEM
	asset_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	asset_dialog.add_filter("*.json", "Studio voxel asset")
	asset_dialog.file_selected.connect(_place_asset)
	add_child(asset_dialog)
	recovery_dialog = ConfirmationDialog.new()
	recovery_dialog.title = "Recover unsaved map?"
	recovery_dialog.dialog_text = "An autosave is newer than the saved map. Restore it?"
	recovery_dialog.confirmed.connect(_restore_recovery)
	add_child(recovery_dialog)
	controls_dialog = AcceptDialog.new()
	controls_dialog.title = "Steam Deck and keyboard controls"
	controls_dialog.dialog_text = "Default Deck controls: LB opens the 3 × 3 tool palette, D-pad moves through tools, A activates, and B closes. Outside the palette, D-pad up/down selects map instances; X/Y undo/redo and RB focuses. Left stick moves the camera focus in Navigate mode, and right stick orbits.

Right mouse drag orbits, middle drag pans, and wheel zooms. Touch drag orbits; supported magnify and pan gestures zoom and pan. Default keyboard shortcuts: Ctrl+S save, Ctrl+Z undo, Ctrl+Y redo, Delete remove, F focus. Select a binding below and press a new key or gamepad button. Steam Input still supplies trackpad and rear-button mappings. Use Steam+X for text entry."
	add_child(controls_dialog)
	var shortcut_panel := VBoxContainer.new()
	controls_dialog.add_child(shortcut_panel)
	for action in shortcut_keys:
		var row := HBoxContainer.new()
		shortcut_panel.add_child(row)
		row.add_child(_label(action.capitalize() + " (Ctrl for Save, Undo, Redo)" if action in ["save", "undo", "redo"] else action.capitalize()))
		var binding := Button.new()
		binding.text = OS.get_keycode_string(shortcut_keys[action])
		binding.pressed.connect(_capture_shortcut.bind(action))
		row.add_child(binding)
		shortcut_buttons[action] = binding
	shortcut_panel.add_child(_label("Gamepad: select a button, then press the new gamepad button."))
	for action in gamepad_buttons:
		var row := HBoxContainer.new()
		shortcut_panel.add_child(row)
		row.add_child(_label(action.replace("_", " ").capitalize()))
		var binding := Button.new()
		binding.text = _gamepad_button_name(gamepad_buttons[action])
		binding.pressed.connect(_capture_gamepad.bind(action))
		row.add_child(binding)
		gamepad_binding_buttons[action] = binding
	var saved_outer := int(settings.get_value("workspace", "outer_split", 260))
	var saved_inner := int(settings.get_value("workspace", "inner_split", -270))
	call_deferred("_restore_layout", saved_outer, saved_inner)

func _restore_layout(outer_offset: int, inner_offset: int) -> void:
	outer_split.split_offset = outer_offset
	inner_split.split_offset = inner_offset

func _toggle_hierarchy_panel() -> void:
	hierarchy_panel.visible = not hierarchy_panel.visible
	settings.set_value("workspace", "hierarchy_visible", hierarchy_panel.visible)
	settings.save("user://studio_settings.cfg")

func _toggle_inspector_panel() -> void:
	inspector_panel.visible = not inspector_panel.visible
	settings.set_value("workspace", "inspector_visible", inspector_panel.visible)
	settings.save("user://studio_settings.cfg")

func _reset_layout() -> void:
	hierarchy_panel.visible = true
	inspector_panel.visible = true
	_restore_layout(260, -270)
	settings.set_value("workspace", "hierarchy_visible", true)
	settings.set_value("workspace", "inspector_visible", true)
	settings.set_value("workspace", "outer_split", 260)
	settings.set_value("workspace", "inner_split", -270)
	settings.save("user://studio_settings.cfg")

func _toggle_navigation_mode() -> void:
	navigation_mode = not navigation_mode
	settings.set_value("workspace", "navigation_mode", navigation_mode)
	settings.save("user://studio_settings.cfg")
	for child in get_tree().get_nodes_in_group("mode_toggle"):
		if child is Button:
			child.text = "Mode: " + ("Navigate" if navigation_mode else "Edit")
	status.text = "Navigation mode enabled; left stick moves the camera focus." if navigation_mode else "Edit mode enabled."

func _cycle_gizmo_mode() -> void:
	var order := ["move", "rotate", "scale"]
	_set_gizmo_mode(order[(order.find(gizmo_mode) + 1) % order.size()])

func _set_gizmo_mode(next_mode: String) -> void:
	if next_mode not in ["move", "rotate", "scale"] or next_mode == gizmo_mode:
		return
	gizmo_mode = next_mode
	drag_kind = ""
	drag_axis = -1
	for child in get_tree().get_nodes_in_group("gizmo_toggle"):
		if child is Button:
			child.text = "Gizmo: " + gizmo_mode.capitalize()
	status.text = "Gizmo: " + gizmo_mode + " — drag a coloured handle in the viewport (W/E/R switch mode)."
	_refresh_geometry()

# Circle points around center in the plane perpendicular to axis
# (0=X uses Y/Z plane, 1=Y uses X/Z, 2=Z uses X/Y), for line-strip drawing.
static func _gizmo_ring_points(center: Vector3, axis: int, radius: float, segments: int = 48) -> PackedVector3Array:
	var points := PackedVector3Array()
	var count := maxi(segments, 3)
	for i in range(count + 1):
		var angle := TAU * float(i) / float(count)
		var c := cos(angle) * radius
		var s := sin(angle) * radius
		var offset := Vector3.ZERO
		match axis:
			0:
				offset = Vector3(0.0, c, s)
			1:
				offset = Vector3(c, 0.0, s)
			_:
				offset = Vector3(c, s, 0.0)
		points.append(center + offset)
	return points

# Rotation in degrees while dragging a rotate handle:
# 0.5 degrees per horizontal pixel, snapped to whole degrees.
static func _gizmo_drag_rotation(start_degrees: float, mouse_delta_x: float) -> float:
	return roundf(start_degrees + mouse_delta_x * 0.5)

# Scale/size value while dragging a scale handle: right or up increases,
# 0.01 per pixel, snapped to 0.125 steps, minimum 0.125.
static func _gizmo_drag_scale(start_value: float, mouse_delta: Vector2) -> float:
	return maxf(snappedf(start_value + (mouse_delta.x - mouse_delta.y) * 0.01, 0.125), 0.125)

# True for the plain-block branch of _refresh_geometry: those instances are
# drawn with their mesh centred half a height above "position" (position is
# the block's base centre), unlike guides/assets whose node origin already
# is their visual centre.
func _is_block_kind(item: Dictionary) -> bool:
	return not (item.get("kind") in ["asset", "light", "marker", "volume", "navigation"])

func _gizmo_center() -> Vector3:
	var selected := _selected()
	if selected.is_empty():
		return Vector3.ZERO
	var center := Vector3(selected["position"][0], selected["position"][1], selected["position"][2])
	# Anchor the gizmo to the block's visual centre, not its base. Anchored
	# at the base, the X/Z scale handles sat on the floor at the block's
	# feet — half-buried in the ground plane and, for larger blocks, inside
	# the mesh — leaving only the Y handle visible and grabbable.
	if _is_block_kind(selected):
		var size: Array = selected.get("size", [1.0, 1.0, 1.0])
		center.y += float(size[1]) * 0.5
	return center

# Half-extents of the selected instance around the gizmo centre, so handle
# offsets can clear the mesh instead of ending inside it.
func _gizmo_half_extents() -> Vector3:
	var item := _selected()
	if item.is_empty() or item.get("kind") == "asset":
		return Vector3.ZERO
	if item.get("kind") in ["light", "marker"]:
		return Vector3.ONE * 0.25
	var size: Array = item.get("size", [1.0, 1.0, 1.0])
	return Vector3(float(size[0]), float(size[1]), float(size[2])) * 0.5

# Distance of a scale handle from the centre along its axis: at least the
# classic 1.5, but always clear of the instance's face on that axis.
func _gizmo_scale_reach(axis: int) -> float:
	return maxf(1.5, _gizmo_half_extents()[axis] + 0.6)

# Rotate ring radius: at least the classic 1.25, but clear of the whole
# instance so the ring and its handles are not buried inside a big block.
func _gizmo_rotate_radius() -> float:
	var extents := _gizmo_half_extents()
	return maxf(1.25, maxf(extents.x, maxf(extents.y, extents.z)) + 0.6)

# World-space pick points for the active gizmo mode's handles, keyed by axis.
func _gizmo_handle_positions() -> Dictionary:
	var center := _gizmo_center()
	var handles := {}
	if gizmo_mode == "rotate":
		for axis in 3:
			var ring_dir := Vector3.ZERO
			match axis:
				0:
					ring_dir = Vector3(0.0, cos(PI / 4.0), sin(PI / 4.0))
				1:
					ring_dir = Vector3(cos(PI / 4.0), 0.0, sin(PI / 4.0))
				_:
					ring_dir = Vector3(cos(PI / 4.0), sin(PI / 4.0), 0.0)
			handles[axis] = center + ring_dir * _gizmo_rotate_radius()
	elif gizmo_mode == "scale":
		var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
		for axis in 3:
			handles[axis] = center + axes[axis] * _gizmo_scale_reach(axis)
	return handles

func _start_handle_drag(kind: String, axis: int, mouse_pos: Vector2) -> void:
	var item := _selected()
	if item.is_empty():
		return
	drag_kind = kind
	drag_axis = axis
	drag_mouse_start = mouse_pos
	drag_property = "rotation" if kind == "rotate" else ("scale" if item.get("kind") == "asset" else "size")
	var fallback: Array = [0.0, 0.0, 0.0] if drag_property == "rotation" else [1.0, 1.0, 1.0]
	drag_start_values = (item.get(drag_property, fallback) as Array).duplicate()
	drag_current_values = drag_start_values.duplicate()

func _update_handle_drag(mouse_pos: Vector2) -> void:
	if drag_axis < 0 or drag_start_values.size() != 3:
		return
	var mouse_delta: Vector2 = mouse_pos - drag_mouse_start
	if drag_kind == "rotate":
		drag_current_values[drag_axis] = _gizmo_drag_rotation(float(drag_start_values[drag_axis]), mouse_delta.x)
	elif drag_kind == "scale":
		drag_current_values[drag_axis] = _gizmo_drag_scale(float(drag_start_values[drag_axis]), mouse_delta)
	else:
		return
	for child in world.get_children():
		if child.get_meta("studio_instance", "") == selected_id and not bool(child.get_meta("studio_gizmo", false)):
			if child is Node3D:
				if drag_kind == "rotate":
					(child as Node3D).rotation_degrees = Vector3(drag_current_values[0], drag_current_values[1], drag_current_values[2])
				elif _selected().get("kind") == "asset":
					(child as Node3D).scale = Vector3(drag_current_values[0], drag_current_values[1], drag_current_values[2])
				else:
					(child as Node3D).scale = Vector3(
						drag_current_values[0] / maxf(float(drag_start_values[0]), 0.001),
						drag_current_values[1] / maxf(float(drag_start_values[1]), 0.001),
						drag_current_values[2] / maxf(float(drag_start_values[2]), 0.001))
			break

func _finish_handle_drag() -> void:
	if drag_kind == "" or drag_axis < 0:
		drag_kind = ""
		return
	var kind := drag_kind
	var property := drag_property
	var changed := drag_current_values != drag_start_values
	drag_kind = ""
	drag_axis = -1
	if not changed:
		_refresh_geometry()
		return
	var next_doc: Dictionary = map_doc.duplicate(true)
	for item in next_doc["instances"]:
		if item["id"] == selected_id:
			item[property] = drag_current_values.duplicate()
	_apply("Rotate instance" if kind == "rotate" else "Scale instance", next_doc)

func _show_controls() -> void:
	controls_dialog.popup_centered(Vector2i(760, 750))

func _gamepad_button_name(button_index: int) -> String:
	var names := {JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y", JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB", JOY_BUTTON_DPAD_UP: "D-pad Up", JOY_BUTTON_DPAD_DOWN: "D-pad Down", JOY_BUTTON_DPAD_LEFT: "D-pad Left", JOY_BUTTON_DPAD_RIGHT: "D-pad Right"}
	return str(names.get(button_index, "Button " + str(button_index)))

func _capture_gamepad(action: String) -> void:
	pending_gamepad = action
	gamepad_binding_buttons[action].text = "Press gamepad button..."

func _set_gamepad_button(action: String, button_index: int) -> void:
	for other in gamepad_buttons:
		if other != action and gamepad_buttons[other] == button_index:
			gamepad_binding_buttons[action].text = _gamepad_button_name(gamepad_buttons[action])
			pending_gamepad = ""
			status.text = "This gamepad button is already assigned to " + other + "."
			return
	gamepad_buttons[action] = button_index
	settings.set_value("gamepad", action, button_index)
	settings.save("user://studio_settings.cfg")
	gamepad_binding_buttons[action].text = _gamepad_button_name(button_index)
	pending_gamepad = ""


func _build_tool_palette() -> void:
	tool_actions = [
		{"name": "Add block", "call": _add_block},
		{"name": "Place asset", "call": _choose_asset},
		{"name": "Marker", "call": _add_feature.bind("marker")},
		{"name": "Light", "call": _add_feature.bind("light")},
		{"name": "Volume", "call": _add_feature.bind("volume")},
		{"name": "Navigation", "call": _add_feature.bind("navigation")},
		{"name": "Group", "call": _group_selected},
		{"name": "Delete", "call": _delete_selected},
		{"name": "Focus", "call": _focus_selected},
	]
	tool_palette = PanelContainer.new()
	tool_palette.visible = false
	add_child(tool_palette)
	tool_grid = GridContainer.new()
	tool_grid.columns = 3
	tool_palette.add_child(tool_grid)
	for i in tool_actions.size():
		var button := Button.new()
		button.text = tool_actions[i]["name"]
		button.custom_minimum_size = Vector2(150, 52)
		button.pressed.connect(_activate_palette_tool.bind(i))
		tool_grid.add_child(button)

func _show_tool_palette() -> void:
	if tool_palette.visible:
		tool_palette.hide()
		return
	tool_palette.position = (size - Vector2(490, 180)) * 0.5
	tool_palette.show()
	_select_palette_tool(palette_index)

func _select_palette_tool(index: int) -> void:
	palette_index = posmod(index, tool_actions.size())
	for i in tool_grid.get_child_count():
		var button: Button = tool_grid.get_child(i)
		button.modulate = Color("#ffe099") if i == palette_index else Color.WHITE
	status.text = "Tool: " + str(tool_actions[palette_index]["name"]) + " — press A to use."

func _activate_palette_tool(index: int) -> void:
	tool_palette.hide()
	tool_actions[index]["call"].call()

func _select_hierarchy_step(step: int) -> void:
	var count: int = map_doc.get("instances", []).size()
	if count == 0:
		return
	var current := 0
	for i in count:
		if map_doc["instances"][i]["id"] == selected_id:
			current = i
			break
	_select_index(posmod(current + step, count))

func _handle_gamepad_button(button_index: int) -> void:
	if button_index == gamepad_buttons["palette"]:
		_show_tool_palette()
	elif button_index == gamepad_buttons["close"]:
		if tool_palette.visible:
			tool_palette.hide()
	elif tool_palette.visible:
		if button_index == gamepad_buttons["previous"]:
			_select_palette_tool(palette_index - 1)
		elif button_index == gamepad_buttons["next"]:
			_select_palette_tool(palette_index + 1)
		elif button_index == gamepad_buttons["select_previous"]:
			_select_palette_tool(palette_index - 3)
		elif button_index == gamepad_buttons["select_next"]:
			_select_palette_tool(palette_index + 3)
		elif button_index == gamepad_buttons["activate"]:
			_activate_palette_tool(palette_index)
	else:
		if button_index == gamepad_buttons["select_previous"]:
			_select_hierarchy_step(-1)
		elif button_index == gamepad_buttons["select_next"]:
			_select_hierarchy_step(1)
		elif button_index == gamepad_buttons["undo"]:
			_undo()
		elif button_index == gamepad_buttons["redo"]:
			_redo()
		elif button_index == gamepad_buttons["focus"]:
			_focus_selected()

func _capture_shortcut(action: String) -> void:
	pending_shortcut = action
	shortcut_buttons[action].text = "Press a key..."

func _set_shortcut(action: String, keycode: int) -> void:
	if keycode == KEY_NONE:
		return
	for other in shortcut_keys:
		if other != action and shortcut_keys[other] == keycode and (other in ["save", "undo", "redo"]) == (action in ["save", "undo", "redo"]):
			shortcut_buttons[action].text = OS.get_keycode_string(shortcut_keys[action])
			pending_shortcut = ""
			status.text = "This shortcut is already assigned to " + other + "."
			return
	shortcut_keys[action] = keycode
	settings.set_value("shortcuts", action, keycode)
	settings.save("user://studio_settings.cfg")
	shortcut_buttons[action].text = OS.get_keycode_string(keycode)
	pending_shortcut = ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if outer_split != null and inner_split != null:
			settings.set_value("workspace", "outer_split", outer_split.split_offset)
			settings.set_value("workspace", "inner_split", inner_split.split_offset)
			settings.save("user://studio_settings.cfg")

func _button(parent: Node, caption: String, action: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size.y = 42
	button.pressed.connect(action)	
	if caption.begins_with("Mode:"):
		button.add_to_group("mode_toggle")
	if caption.begins_with("Gizmo:"):
		button.add_to_group("gizmo_toggle")
	if caption.begins_with("MCP:"):
		button.add_to_group("mcp_toggle")
	parent.add_child(button)

func _label(value: String) -> Label:
	var label := Label.new()
	label.text = value
	return label

func _choose_project() -> void:
	folder_dialog.popup_centered_ratio(0.8)

func _open_project(path: String) -> void:
	var error: String = Store.validate_target(path)
	if error != "":
		status.text = error
		return
	_autosave()
	project_path = path
	map_doc = {}
	saved_text = ""
	disk_text = ""
	selected_id = ""
	history = History.new()
	status.text = "Opened " + path
	_refresh()
	_check_project_recovery()

func _new_map() -> void:
	if project_path.is_empty():
		status.text = "Open a Forgefall source project first."
		return
	_autosave()
	map_doc = Store.new_map("Untitled Map")
	saved_text = ""
	disk_text = ""
	selected_id = ""
	history = History.new()
	_load_history()
	status.text = "New map. Add a block, then save."
	_refresh()

func _choose_map() -> void:
	if project_path.is_empty():
		status.text = "Open a Forgefall source project first."
		return
	map_dialog.current_dir = project_path.path_join("assets/studio/maps")
	map_dialog.popup_centered_ratio(0.8)

func _open_map(path: String) -> void:
	if not path.begins_with(project_path.path_join("assets/studio/maps") + "/"):
		status.text = "Choose a map inside the selected project's assets/studio/maps."
		return
	var candidate: Dictionary = Store.read_json(path)
	var error: String = Store.validate_map(candidate)
	if error != "":
		status.text = error
		return
	_autosave()
	map_doc = candidate
	saved_text = JSON.stringify(map_doc)
	disk_text = saved_text
	history = History.new()
	_load_history()
	selected_id = ""
	status.text = "Opened " + path.get_file()
	_refresh()
	_check_recovery()

func _save() -> bool:
	if map_doc.is_empty():
		status.text = "Create or open a map first."
		return false
	var error: String = Store.validate_map(map_doc)
	if error != "":
		status.text = error
		return false
	var path: String = Store.map_path(project_path, map_doc["id"])
	if FileAccess.file_exists(path):
		var on_disk: Dictionary = Store.read_json(path)
		if disk_text == "" or JSON.stringify(on_disk) != disk_text:
			status.text = "Map changed on disk. Open it or use Save As to keep both versions."
			return false
	var result: Error = Store.write_json(path, map_doc)
	if result != OK:
		status.text = "Save failed: " + error_string(result)
		return false
	saved_text = JSON.stringify(map_doc)
	disk_text = JSON.stringify(Store.read_json(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_recovery_path()))
	status.text = "Saved " + path
	_refresh()
	return true

func _open_workshop() -> void:
	if project_path.is_empty():
		status.text = "Open a Forgefall source project first."
		return
	_autosave()
	var workshop: Control = load("res://asset_workshop.tscn").instantiate()
	workshop.project_path = project_path
	workshop.tree_exited.connect(_refresh)
	add_child(workshop)

func _open_behavior_workspace() -> void:
	if project_path.is_empty():
		status.text = "Open a Forgefall source project first."
		return
	var workspace: Control = load("res://behavior_workspace.tscn").instantiate()
	workspace.project_path = project_path
	add_child(workspace)

func _open_content_workshop() -> void:
	if project_path.is_empty():
		status.text = "Open a Forgefall source project first."
		return
	if not ResourceLoader.exists("res://content_workshop.tscn"):
		status.text = "Content workshop is not installed."
		return
	var workshop: Control = load("res://content_workshop.tscn").instantiate()
	workshop.project_path = project_path
	add_child(workshop)

func _open_ai_assistant() -> void:
	if map_doc.is_empty():
		status.text = "Create or open a map first."
		return
	var assistant: Window = load("res://ai_assistant.tscn").instantiate()
	assistant.editor = self
	add_child(assistant)
	assistant.popup_centered()

# --- MCP server (Studio as an MCP endpoint for external AI agents) ----------

func _setup_mcp_server() -> void:
	_ensure_mcp_server()
	_update_mcp_button()
	# Agent-driven sessions can opt in via the environment: setting
	# FORGEFALL_STUDIO_MCP_PORT also auto-starts the server on launch.
	if OS.get_environment("FORGEFALL_STUDIO_MCP_PORT").strip_edges() != "":
		var error: Error = mcp_server.start(_mcp_port())
		if error != OK:
			push_warning("MCP server failed to auto-start on port %d: %s" % [_mcp_port(), error_string(error)])
		_update_mcp_button()
		if mcp_server.is_running():
			status.text = _mcp_on_message()

func _ensure_mcp_server() -> void:
	if mcp_server == null:
		mcp_server = McpServer.new()
		mcp_server.editor = self
		add_child(mcp_server)

func _mcp_port() -> int:
	var env := OS.get_environment("FORGEFALL_STUDIO_MCP_PORT").strip_edges()
	if env.is_valid_int():
		var parsed := int(env)
		if parsed > 0 and parsed <= 65535:
			return parsed
	return clampi(int(settings.get_value("workspace", "mcp_port", 8772)), 1, 65535)

func _mcp_on_message() -> String:
	return "MCP server on http://127.0.0.1:%d/mcp — any local MCP client can edit the open map" % mcp_server.port()

func _toggle_mcp_server() -> void:
	_ensure_mcp_server()
	if mcp_server.is_running():
		mcp_server.stop()
		status.text = "MCP server off."
	else:
		var error: Error = mcp_server.start(_mcp_port())
		if error != OK:
			status.text = "MCP server failed to start on port %d: %s" % [_mcp_port(), error_string(error)]
		else:
			status.text = _mcp_on_message()
	_update_mcp_button()

func _update_mcp_button() -> void:
	var running: bool = mcp_server != null and mcp_server.is_running()
	for child in get_tree().get_nodes_in_group("mcp_toggle"):
		if child is Button:
			child.text = "MCP: On :%d" % mcp_server.port() if running else "MCP: Off"

func _open_web_map() -> void:
	if web_map_window != null and is_instance_valid(web_map_window):
		web_map_window.popup_centered()
		return
	if not ResourceLoader.exists("res://web_maps.tscn"):
		status.text = "Web map exchange is not installed."
		return
	web_map_window = load("res://web_maps.tscn").instantiate()
	web_map_window.editor = self
	add_child(web_map_window)
	web_map_window.popup_centered()

func _save_web_map() -> void:
	_open_web_map()
	if web_map_window != null and is_instance_valid(web_map_window):
		web_map_window._download()

func _publish_map() -> void:
	if map_doc.is_empty() or project_path.is_empty():
		status.text = "Open a Forgefall project and map first."
		return
	if not _save():
		return
	if _is_dirty() or not FileAccess.file_exists(Store.map_path(project_path, map_doc["id"])):
		return
	var executable := OS.get_environment("GODOT_EDITOR_PATH")
	if executable.is_empty():
		executable = OS.get_executable_path()
	var output := []
	var code := OS.execute(executable, ["--headless", "--path", project_path, "--script", "res://tools/studio_generate.gd", "--", str(map_doc["id"])], output, true)
	if code == 0:
		status.text = "Published native map scene and catalog entry."
	else:
		status.text = "Publish failed (" + str(code) + "): " + (str(output[0]) if not output.is_empty() else "Check Godot output.")

func _save_as() -> void:
	if map_doc.is_empty():
		return
	var previous_doc: Dictionary = map_doc
	var previous_saved := saved_text
	var previous_disk := disk_text
	var previous_history := history
	var copy: Dictionary = map_doc.duplicate(true)
	copy["id"] = Store.new_map("copy")["id"]
	copy["name"] = str(copy["name"]) + " Copy"
	map_doc = copy
	saved_text = ""
	disk_text = ""
	history = History.new()
	if not _save():
		map_doc = previous_doc
		saved_text = previous_saved
		disk_text = previous_disk
		history = previous_history
		_refresh()

func _history_path() -> String:
	return "user://history/" + project_path.sha256_text().substr(0, 16) + "_" + str(map_doc.get("id", "")) + ".json"

func _persist_history() -> void:
	if project_path.is_empty() or map_doc.is_empty():
		return
	Store.write_json(ProjectSettings.globalize_path(_history_path()), history.to_dict())

func _load_history() -> void:
	if project_path.is_empty() or map_doc.is_empty():
		return
	history.load_dict(Store.read_json(ProjectSettings.globalize_path(_history_path())), map_doc)

func _recovery_path() -> String:
	var project_key := project_path.sha256_text().substr(0, 16)
	return "user://recovery/" + project_key + "_" + str(map_doc.get("id", "")) + ".json"

func _autosave() -> void:
	if map_doc.is_empty() or not _is_dirty():
		return
	Store.write_json(ProjectSettings.globalize_path(_recovery_path()), map_doc)
	Store.write_json(ProjectSettings.globalize_path(_recovery_index_path()), {"map_id": map_doc["id"]})

func _recovery_index_path() -> String:
	return "user://recovery/" + project_path.sha256_text().substr(0, 16) + "_latest.json"

func _check_project_recovery() -> void:
	var index: Dictionary = Store.read_json(ProjectSettings.globalize_path(_recovery_index_path()))
	if not index.has("map_id"):
		return
	var id := str(index["map_id"])
	var recovery := ProjectSettings.globalize_path("user://recovery/" + project_path.sha256_text().substr(0, 16) + "_" + id + ".json")
	var candidate: Dictionary = Store.read_json(recovery)
	if Store.validate_map(candidate) != "":
		return
	var disk: Dictionary = Store.read_json(Store.map_path(project_path, id))
	if JSON.stringify(candidate) != JSON.stringify(disk):
		map_doc = disk if not disk.is_empty() else Store.new_map("Untitled Map")
		if disk.is_empty():
			map_doc["id"] = id
		saved_text = JSON.stringify(disk) if not disk.is_empty() else ""
		disk_text = saved_text
		selected_id = ""
		history = History.new()
		_load_history()
		_check_recovery()
		_refresh()

func _check_recovery() -> void:
	var path := ProjectSettings.globalize_path(_recovery_path())
	if not FileAccess.file_exists(path):
		return
	var candidate: Dictionary = Store.read_json(path)
	if Store.validate_map(candidate) == "" and JSON.stringify(candidate) != saved_text:
		recovery_dialog.popup_centered()

func _restore_recovery() -> void:
	map_doc = Store.read_json(ProjectSettings.globalize_path(_recovery_path()))
	history = History.new()
	_load_history()
	status.text = "Recovered unsaved map. Save to keep it."
	_refresh()

func _is_dirty() -> bool:
	return not map_doc.is_empty() and JSON.stringify(map_doc) != saved_text

func _apply(name: String, next_doc: Dictionary) -> void:
	map_doc = history.execute(map_doc, name, next_doc)
	_persist_history()
	_refresh()

func _add_block() -> void:
	if map_doc.is_empty():
		status.text = "Create or open a map first."
		return
	var next_doc: Dictionary = map_doc.duplicate(true)
	var instance: Dictionary = Store.new_instance("Block", camera_focus.snapped(Vector3.ONE))
	next_doc["instances"].append(instance)
	selected_id = instance["id"]
	_apply("Add block", next_doc)

func _add_feature(kind: String) -> void:
	if map_doc.is_empty():
		status.text = "Create or open a map first."
		return
	var item: Dictionary = Store.new_instance(kind.capitalize(), camera_focus.snapped(Vector3.ONE))
	item["kind"] = kind
	item["size"] = [4.0, 2.0, 4.0] if kind in ["volume", "navigation"] else [8.0, 1.0, 1.0]
	if kind == "marker":
		item["marker_type"] = "player_spawn"
	elif kind == "volume":
		item["volume_type"] = "trigger"
	var next_doc: Dictionary = map_doc.duplicate(true)
	next_doc["instances"].append(item)
	selected_id = item["id"]
	_apply("Add " + kind, next_doc)

func _group_selected() -> void:
	if selected_id.is_empty():
		return
	var next_doc: Dictionary = map_doc.duplicate(true)
	var selected_indices := hierarchy.get_selected_items()
	var group_id := selected_id
	if selected_indices.size() > 0:
		group_id = str(next_doc["instances"][selected_indices[0]].get("group_id", group_id))
	for index in selected_indices:
		next_doc["instances"][index]["group_id"] = group_id
	if selected_indices.is_empty():
		for item in next_doc["instances"]:
			if item["id"] == selected_id:
				item["group_id"] = group_id
	_apply("Group instances", next_doc)

func _edit_property(value: String, property: String) -> void:
	if selected_id.is_empty():
		return
	var next_doc: Dictionary = map_doc.duplicate(true)
	for item in next_doc["instances"]:
		if item["id"] == selected_id:
			item[property] = value.strip_edges()
	_apply("Edit " + property, next_doc)

func _edit_vector_component(value: String, property: String, axis: int) -> void:
	if not value.is_valid_float():
		return
	var next_doc: Dictionary = map_doc.duplicate(true)
	for item in next_doc["instances"]:
		if item["id"] == selected_id:
			if not item.has(property):
				item[property] = [0.0, 0.0, 0.0] if property == "rotation" else [1.0, 1.0, 1.0]
			item[property][axis] = snappedf(float(value), 0.125)
	_apply("Edit " + property, next_doc)

func _nudge_selected(axis: int, delta: float) -> void:
	if selected_id.is_empty():
		return
	var item := _selected()
	_edit_axis(str(float(item["position"][axis]) + delta), axis)

func _choose_asset() -> void:
	if map_doc.is_empty():
		status.text = "Create or open a map first."
		return
	asset_dialog.current_dir = project_path.path_join("assets/studio/assets")
	asset_dialog.popup_centered_ratio(0.8)

func _place_asset(path: String) -> void:
	if not path.begins_with(project_path.path_join("assets/studio/assets") + "/"):
		status.text = "Choose an asset in this Forgefall project's library."
		return
	var asset: Dictionary = Store.read_json(path)
	var problem: String = Asset.validate(asset)
	if problem != "":
		status.text = problem
		return
	var next_doc: Dictionary = map_doc.duplicate(true)
	var instance: Dictionary = Store.new_instance(str(asset["name"]), camera_focus.snapped(Vector3.ONE * Asset.PITCH))
	instance["kind"] = "asset"
	instance["asset_id"] = asset["id"]
	next_doc["instances"].append(instance)
	selected_id = instance["id"]
	_apply("Place library asset", next_doc)

func _delete_selected() -> void:
	if selected_id.is_empty():
		return
	var next_doc: Dictionary = map_doc.duplicate(true)
	for i in range(next_doc["instances"].size() - 1, -1, -1):
		if next_doc["instances"][i]["id"] == selected_id:
			next_doc["instances"].remove_at(i)
	selected_id = ""
	_apply("Delete instance", next_doc)

func _undo() -> void:
	if not history.can_undo():
		return
	map_doc = history.undo(map_doc)
	_persist_history()
	_refresh()

func _redo() -> void:
	if not history.can_redo():
		return
	map_doc = history.redo(map_doc)
	_persist_history()
	_refresh()

func _select_index(index: int) -> void:
	if index < map_doc.get("instances", []).size():
		selected_id = map_doc["instances"][index]["id"]
		_refresh_inspector()
		_refresh_geometry()

func _selected() -> Dictionary:
	for item in map_doc.get("instances", []):
		if item["id"] == selected_id:
			return item
	return {}

func _edit_axis(text_value: String, axis: int) -> void:
	if not text_value.is_valid_float():
		return
	var next_doc: Dictionary = map_doc.duplicate(true)
	for item in next_doc["instances"]:
		if item["id"] == selected_id:
			item["position"][axis] = snappedf(float(text_value), 0.125)
	_apply("Move instance", next_doc)

func _refresh() -> void:
	title.text = ("● " if _is_dirty() else "") + str(map_doc.get("name", "No map")) + (" — " + project_path.get_file() if project_path != "" else "")
	hierarchy.clear()
	for item in map_doc.get("instances", []):
		var label := str(item.get("name", "Instance"))
		if str(item.get("group_id", "")) != "":
			label += "  [group]"
		hierarchy.add_item(label)
		if item["id"] == selected_id:
			hierarchy.select(hierarchy.item_count - 1, false)
	_refresh_inspector()
	_refresh_geometry()

func _refresh_inspector() -> void:
	for child in inspector.get_children():
		child.queue_free()
	inspector.add_child(_label("Inspector"))
	var item := _selected()
	if item.is_empty():
		inspector.add_child(_label("Select an instance."))
		return
	inspector.add_child(_label(str(item["name"]) + "\nID: " + str(item["id"]).substr(0, 8)))
	for axis in 3:
		var row := HBoxContainer.new()
		inspector.add_child(row)
		row.add_child(_label(["X", "Y", "Z"][axis]))
		var edit := LineEdit.new()
		edit.text = str(item["position"][axis])
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.text_submitted.connect(_edit_axis.bind(axis))
		row.add_child(edit)
	for property in ["rotation", "size" if item.get("kind") != "asset" else "scale"]:
		inspector.add_child(_label(property.capitalize()))
		var values: Array = item.get(property, [0, 0, 0] if property == "rotation" else [1, 1, 1])
		var row := HBoxContainer.new()
		inspector.add_child(row)
		for axis in 3:
			var edit := LineEdit.new()
			edit.placeholder_text = ["X", "Y", "Z"][axis]
			edit.text = str(values[axis])
			edit.custom_minimum_size.x = 58
			edit.text_submitted.connect(_edit_vector_component.bind(property, axis))
			row.add_child(edit)
	for property in ["group_id", "behavior_id"]:
		var edit := LineEdit.new()
		edit.placeholder_text = property
		edit.text = str(item.get(property, ""))
		edit.text_submitted.connect(_edit_property.bind(property))
		inspector.add_child(edit)
	if item.get("kind") == "marker":
		var selector := OptionButton.new()
		for marker_type in ["player_spawn", "spawn_door", "objective_point", "waypoint", "character_spawn"]:
			selector.add_item(marker_type)
		selector.select(maxi(0, ["player_spawn", "spawn_door", "objective_point", "waypoint", "character_spawn"].find(str(item.get("marker_type", "player_spawn")))))
		selector.item_selected.connect(func(index: int) -> void: _edit_property(selector.get_item_text(index), "marker_type"))
		inspector.add_child(selector)
	if item.get("kind") == "marker" and item.get("marker_type") == "character_spawn":
		var character := LineEdit.new()
		character.placeholder_text = "published character ID"
		character.text = str(item.get("character_id", ""))
		character.text_submitted.connect(_edit_property.bind("character_id"))
		inspector.add_child(character)
	if item.get("kind") == "volume":
		var volume := LineEdit.new()
		volume.placeholder_text = "volume type"
		volume.text = str(item.get("volume_type", "trigger"))
		volume.text_submitted.connect(_edit_property.bind("volume_type"))
		inspector.add_child(volume)
	var nudge_row := HBoxContainer.new()
	inspector.add_child(nudge_row)
	for axis in 3:
		for sign in [-1.0, 1.0]:
			_button(nudge_row, ["X", "Y", "Z"][axis] + ("-" if sign < 0 else "+"), _nudge_selected.bind(axis, sign * 0.125))
	inspector.add_child(_label("Drag in viewport to move on X/Z.\nPosition snaps to 0.125 m.\nGizmo (toolbar or W/E/R): Move, Rotate\nor Scale — drag a coloured handle;\nthe edit is one undoable command."))

func _refresh_geometry() -> void:
	for child in world.get_children():
		if child.has_meta("studio_instance"):
			child.queue_free()
	for item in map_doc.get("instances", []):
		if item.get("kind") == "asset":
			var asset_doc: Dictionary = Store.read_json(Asset.path(project_path, str(item.get("asset_id", ""))))
			if Asset.validate(asset_doc) == "":
				var asset_node: Node3D = Mesher.build_node(asset_doc)
				asset_node.position = Vector3(item["position"][0], item["position"][1], item["position"][2])
				asset_node.rotation_degrees = Vector3(item.get("rotation", [0, 0, 0])[0], item.get("rotation", [0, 0, 0])[1], item.get("rotation", [0, 0, 0])[2])
				asset_node.scale = Vector3(item.get("scale", [1, 1, 1])[0], item.get("scale", [1, 1, 1])[1], item.get("scale", [1, 1, 1])[2])
				asset_node.set_meta("studio_instance", item["id"])
				world.add_child(asset_node)
			continue
		var node := MeshInstance3D.new()
		node.set_meta("studio_instance", item["id"])
		if item.get("kind") in ["light", "marker", "volume", "navigation"]:
			var guide: PrimitiveMesh = SphereMesh.new() if item.get("kind") in ["light", "marker"] else BoxMesh.new()
			if guide is SphereMesh:
				(guide as SphereMesh).radius = 0.25
				(guide as SphereMesh).height = 0.5
			else:
				(guide as BoxMesh).size = Vector3(item["size"][0], item["size"][1], item["size"][2])
			node.mesh = guide
			node.position = Vector3(item["position"][0], item["position"][1], item["position"][2])
			var guide_mat := StandardMaterial3D.new()
			guide_mat.albedo_color = Color("#ffdd66" if item.get("kind") == "light" else "#55dfff")
			guide_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			guide_mat.albedo_color.a = 0.45
			node.material_override = guide_mat
			world.add_child(node)
			continue
		var mesh := BoxMesh.new()
		mesh.size = Vector3(item["size"][0], item["size"][1], item["size"][2])
		node.mesh = mesh
		node.position = Vector3(item["position"][0], item["position"][1] + item["size"][1] * 0.5, item["position"][2])
		node.rotation_degrees = Vector3(item.get("rotation", [0, 0, 0])[0], item.get("rotation", [0, 0, 0])[1], item.get("rotation", [0, 0, 0])[2])
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(item["color"])
		if item["id"] == selected_id:
			material.emission_enabled = true
			material.emission = Color("#536e8f")
		node.material_override = material
		world.add_child(node)
	var selected := _selected()
	if not selected.is_empty():
		var center := _gizmo_center()
		var gizmo := ImmediateMesh.new()
		var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
		var axis_colors := [Color.RED, Color.GREEN, Color.BLUE]
		if gizmo_mode == "rotate":
			for axis in 3:
				var material := StandardMaterial3D.new()
				material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				material.albedo_color = axis_colors[axis]
				gizmo.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
				for point in _gizmo_ring_points(center, axis, _gizmo_rotate_radius()):
					gizmo.surface_add_vertex(point)
				gizmo.surface_end()
		else:
			for axis in 3:
				var reach := _gizmo_scale_reach(axis) if gizmo_mode == "scale" else 1.25
				var material := StandardMaterial3D.new()
				material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				material.albedo_color = axis_colors[axis]
				gizmo.surface_begin(Mesh.PRIMITIVE_LINES, material)
				gizmo.surface_add_vertex(center)
				gizmo.surface_add_vertex(center + axes[axis] * reach)
				gizmo.surface_end()
		var guide := MeshInstance3D.new()
		guide.mesh = gizmo
		guide.set_meta("studio_instance", selected_id)
		guide.set_meta("studio_gizmo", true)
		world.add_child(guide)
		# Draggable handle knobs for the rotate/scale modes, at the same
		# world positions _gizmo_handle_positions() offers for picking.
		for axis in _gizmo_handle_positions():
			var knob := MeshInstance3D.new()
			var knob_mesh: PrimitiveMesh = SphereMesh.new() if gizmo_mode == "rotate" else BoxMesh.new()
			if knob_mesh is SphereMesh:
				(knob_mesh as SphereMesh).radius = 0.12
				(knob_mesh as SphereMesh).height = 0.24
			else:
				(knob_mesh as BoxMesh).size = Vector3.ONE * 0.24
			knob.mesh = knob_mesh
			knob.position = _gizmo_handle_positions()[axis]
			var knob_material := StandardMaterial3D.new()
			knob_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			knob_material.albedo_color = axis_colors[axis]
			knob.material_override = knob_material
			knob.set_meta("studio_instance", selected_id)
			knob.set_meta("studio_gizmo", true)
			knob.set_meta("gizmo_axis", axis)
			world.add_child(knob)

func _focus_selected() -> void:
	var item := _selected()
	if not item.is_empty():
		camera_focus = Vector3(item["position"][0], item["position"][1], item["position"][2])
		_update_camera()

func _update_camera() -> void:
	if camera == null:
		return
	var direction := Vector3(cos(camera_pitch) * sin(camera_yaw), sin(camera_pitch), cos(camera_pitch) * cos(camera_yaw))
	camera.position = camera_focus + direction * camera_distance
	camera.look_at(camera_focus, Vector3.UP)

func _viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed and drag_kind != "":
			_finish_handle_drag()
			return
		if event.pressed and not navigation_mode:
			# Rotate/scale handle picking takes priority over instance picking.
			if gizmo_mode in ["rotate", "scale"] and not _selected().is_empty():
				var handle_axis := -1
				var handle_distance := 30.0
				for axis in _gizmo_handle_positions():
					var handle_pos: Vector3 = _gizmo_handle_positions()[axis]
					if camera.is_position_behind(handle_pos):
						continue
					var distance := camera.unproject_position(handle_pos).distance_to(event.position)
					if distance < handle_distance:
						handle_distance = distance
						handle_axis = axis
				if handle_axis >= 0:
					_start_handle_drag(gizmo_mode, handle_axis, event.position)
					return
			var closest := 40.0
			for item in map_doc.get("instances", []):
				var world_pos := Vector3(item["position"][0], item["position"][1], item["position"][2])
				if camera.is_position_behind(world_pos):
					continue
				var distance := camera.unproject_position(world_pos).distance_to(event.position)
				if distance < closest:
					closest = distance
					selected_id = str(item["id"])
			if closest < 40.0:
				var current := _selected()
				drag_start = Vector3(current["position"][0], current["position"][1], current["position"][2])
				drag_current = drag_start
				drag_mouse_start = event.position
				dragging_instance = true
				_refresh()
		elif not event.pressed and dragging_instance:
			dragging_instance = false
			if drag_current != drag_start:
				var next_doc: Dictionary = map_doc.duplicate(true)
				for item in next_doc["instances"]:
					if item["id"] == selected_id:
						item["position"] = [drag_current.x, drag_current.y, drag_current.z]
				_apply("Drag instance", next_doc)
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera_distance = maxf(2.0, camera_distance - 1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera_distance = minf(80.0, camera_distance + 1.0)
		_update_camera()
	elif event is InputEventMouseMotion:
		if drag_kind in ["rotate", "scale"]:
			_update_handle_drag(event.position)
		elif dragging_instance:
			var right := camera.global_transform.basis.x
			var forward := -camera.global_transform.basis.z
			var motion: Vector2 = event.position - drag_mouse_start
			var delta: Vector3 = (right * motion.x - forward * motion.y) * camera_distance * 0.002
			drag_current = (drag_start + Vector3(delta.x, 0, delta.z)).snapped(Vector3.ONE * 0.125)
			for child in world.get_children():
				if child.get_meta("studio_instance", "") == selected_id:
					child.position += drag_current - Vector3(child.get_meta("last_drag", [drag_start.x, drag_start.y, drag_start.z])[0], child.get_meta("last_drag", [drag_start.x, drag_start.y, drag_start.z])[1], child.get_meta("last_drag", [drag_start.x, drag_start.y, drag_start.z])[2])
					child.set_meta("last_drag", [drag_current.x, drag_current.y, drag_current.z])
					break
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			camera_yaw -= event.relative.x * 0.01
			camera_pitch = clampf(camera_pitch - event.relative.y * 0.01, 0.1, 1.4)
			_update_camera()
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			_pan_camera(Vector2(event.relative.x, event.relative.y))
	elif event is InputEventScreenDrag:
		camera_yaw -= event.relative.x * 0.008
		camera_pitch = clampf(camera_pitch - event.relative.y * 0.008, 0.1, 1.4)
		_update_camera()
	elif event is InputEventMagnifyGesture:
		camera_distance = clampf(camera_distance / event.factor, 2.0, 80.0)
		_update_camera()
	elif event is InputEventPanGesture:
		_pan_camera(event.delta * 18.0)

func _pan_camera(delta: Vector2) -> void:
	var right := camera.global_transform.basis.x
	var up := camera.global_transform.basis.y
	camera_focus += (-right * delta.x + up * delta.y) * camera_distance * 0.0015
	_update_camera()

func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.pressed:
		if controls_dialog.visible and pending_gamepad == "":
			return
		if pending_gamepad == "" and not gamepad_buttons.values().has(event.button_index):
			return
		if pending_gamepad != "":
			_set_gamepad_button(pending_gamepad, event.button_index)
		else:
			_handle_gamepad_button(event.button_index)
		get_viewport().set_input_as_handled()
		return
	if pending_shortcut != "" and event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_ESCAPE:
			shortcut_buttons[pending_shortcut].text = OS.get_keycode_string(shortcut_keys[pending_shortcut])
			pending_shortcut = ""
		else:
			_set_shortcut(pending_shortcut, event.keycode)
		get_viewport().set_input_as_handled()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.ctrl_pressed and event.keycode == shortcut_keys["save"]:
			_save()
		elif event.ctrl_pressed and event.keycode == shortcut_keys["undo"]:
			_undo()
		elif event.ctrl_pressed and event.keycode == shortcut_keys["redo"]:
			_redo()
		elif event.keycode == shortcut_keys["delete"]:
			_delete_selected()
		elif event.keycode == shortcut_keys["focus"]:
			_focus_selected()
		elif event.keycode == KEY_W:
			_set_gizmo_mode("move")
		elif event.keycode == KEY_E:
			_set_gizmo_mode("rotate")
		elif event.keycode == KEY_R:
			_set_gizmo_mode("scale")

func _process(delta: float) -> void:
	var stick := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if stick.length() > 0.2:
		camera_yaw -= stick.x * delta * 1.7
		camera_pitch = clampf(camera_pitch - stick.y * delta * 1.7, 0.1, 1.4)
		_update_camera()
	if navigation_mode:
		var move := Vector2(Input.get_joy_axis(0, JOY_AXIS_LEFT_X), Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
		if move.length() > 0.2:
			var direction := camera.global_transform.basis.x * move.x + camera.global_transform.basis.z * move.y
			camera_focus += direction * delta * camera_distance * 0.8
			_update_camera()
