extends Control

const Store = preload("res://shared/document_store.gd")
const Asset = preload("res://shared/asset_document.gd")
const Mesher = preload("res://shared/voxel_mesh.gd")
const History = preload("res://command_history.gd")

var project_path := ""
var asset_doc: Dictionary = {}
var saved_text := ""
var history := History.new()
var recovery_candidate: Dictionary = {}
var tool := "Place"
var material_index := 0
var stroke_cells: Array[Vector3i] = []
var stroke_active := false
var brush_shape := "Box"
var brush_radius := 0
var brush_strength := 3.0
var symmetry := Vector3i.ZERO
var layer_index := 0
var attachment_index := -1
var collision_box_index := -1
var deform_offset := Vector3i.UP
var camera_distance := 3.0
var camera_yaw := 0.7
var camera_pitch := 0.5

var title: Label
var status: Label
var count_label: Label
var viewport: SubViewport
var viewport_panel: SubViewportContainer
var world: Node3D
var camera: Camera3D
var preview: Node3D
var palette: OptionButton
var picker: ColorPickerButton
var axis_inputs: Array[SpinBox] = []
var open_dialog: FileDialog
var recovery_dialog: ConfirmationDialog
var shape_picker: OptionButton
var radius_input: SpinBox
var layer_picker: OptionButton
var layer_name_input: LineEdit
var deform_picker: OptionButton
var strength_input: SpinBox
var collision_picker: OptionButton
var box_picker: OptionButton
var box_min_inputs: Array[SpinBox] = []
var box_size_inputs: Array[SpinBox] = []
var attachment_input: LineEdit
var attachment_picker: OptionButton
var reference_dialog: FileDialog
var reference_preview: TextureRect

func _ready() -> void:
	_build_ui()
	_new_asset()
	_check_recovery()

func _build_ui() -> void:
	var studio_theme := Theme.new()
	studio_theme.default_font_size = 16
	theme = studio_theme
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var toolbar := HBoxContainer.new()
	root.add_child(toolbar)
	_button(toolbar, "← Map", _close)
	_button(toolbar, "New Asset", _new_asset)
	_button(toolbar, "Open", _choose_asset)
	_button(toolbar, "Save", _save)
	_button(toolbar, "Publish", _publish)
	_button(toolbar, "Undo", _undo)
	_button(toolbar, "Redo", _redo)
	title = Label.new()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(title)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 270
	split.add_child(scroll)
	var controls := VBoxContainer.new()
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(controls)
	controls.add_child(_label("Voxel Asset Workshop"))
	controls.add_child(_label("0.125 m per voxel"))
	count_label = _label("0 voxels")
	controls.add_child(count_label)
	for action in ["Place", "Erase", "Paint", "Sculpt", "Fill", "Smooth", "Deform", "Deform Brush"]:
		_button(controls, action, _set_tool.bind(action))
	controls.add_child(_label("Selected material"))
	palette = OptionButton.new()
	palette.item_selected.connect(_select_material)
	controls.add_child(palette)
	picker = ColorPickerButton.new()
	picker.text = "Edit material color"
	picker.color_changed.connect(_change_color)
	controls.add_child(picker)
	controls.add_child(_label("Coordinates (or click the model)"))
	for label in ["X", "Y", "Z"]:
		var row := HBoxContainer.new()
		controls.add_child(row)
		row.add_child(_label(label))
		var input := SpinBox.new()
		input.min_value = -Asset.MAX_COORD
		input.max_value = Asset.MAX_COORD
		input.step = 1
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(input)
		axis_inputs.append(input)
	_button(controls, "Apply at XYZ", _apply_coordinates)
	controls.add_child(_label("Brush shape / radius"))
	shape_picker = OptionButton.new()
	for value in ["Box", "Sphere", "Cylinder"]:
		shape_picker.add_item(value)
	shape_picker.item_selected.connect(func(index: int) -> void: brush_shape = shape_picker.get_item_text(index))
	controls.add_child(shape_picker)
	radius_input = SpinBox.new()
	radius_input.min_value = 0
	radius_input.max_value = 8
	radius_input.value_changed.connect(func(value: float) -> void: brush_radius = int(value))
	controls.add_child(radius_input)
	controls.add_child(_label("Deform direction"))
	deform_picker = OptionButton.new()
	for value in ["+X", "-X", "+Y", "-Y", "+Z", "-Z"]:
		deform_picker.add_item(value)
	deform_picker.select(2)
	deform_picker.item_selected.connect(_select_deform_direction)
	controls.add_child(deform_picker)
	controls.add_child(_label("Deform brush strength (cells at center)"))
	strength_input = SpinBox.new()
	strength_input.min_value = 0.5
	strength_input.max_value = 8.0
	strength_input.step = 0.5
	strength_input.value = brush_strength
	strength_input.value_changed.connect(func(value: float) -> void: brush_strength = value)
	controls.add_child(strength_input)
	controls.add_child(_label("Mirror across coordinate zero"))
	for axis in 3:
		var mirror := CheckBox.new()
		mirror.text = ["X", "Y", "Z"][axis]
		mirror.toggled.connect(_toggle_symmetry.bind(axis))
		controls.add_child(mirror)
	controls.add_child(_label("Layer"))
	layer_picker = OptionButton.new()
	layer_picker.item_selected.connect(func(index: int) -> void: layer_index = index)
	controls.add_child(layer_picker)
	layer_name_input = LineEdit.new()
	layer_name_input.placeholder_text = "Layer name"
	controls.add_child(layer_name_input)
	_button(controls, "Add Layer", _add_layer)
	_button(controls, "Rename Layer", _rename_layer)
	_button(controls, "Move Layer Up", _move_layer.bind(-1))
	_button(controls, "Move Layer Down", _move_layer.bind(1))
	_button(controls, "Merge into Previous Layer", _merge_layer)
	_button(controls, "Toggle Layer Visibility", _toggle_layer)
	_button(controls, "Toggle Layer Collision", _toggle_layer_collision)
	_button(controls, "Set Pivot at XYZ", _set_pivot)
	controls.add_child(_label("Collision"))
	collision_picker = OptionButton.new()
	collision_picker.add_item("Static")
	collision_picker.add_item("None")
	collision_picker.add_item("Custom")
	collision_picker.item_selected.connect(_set_collision)
	controls.add_child(collision_picker)
	controls.add_child(_label("Custom collision boxes (meters)"))
	box_picker = OptionButton.new()
	box_picker.item_selected.connect(_select_collision_box)
	controls.add_child(box_picker)
	controls.add_child(_label("Box min corner X / Y / Z"))
	var min_row := HBoxContainer.new()
	controls.add_child(min_row)
	for axis in 3:
		var min_input := SpinBox.new()
		min_input.min_value = -Asset.MAX_COORD * Asset.PITCH
		min_input.max_value = Asset.MAX_COORD * Asset.PITCH
		min_input.step = Asset.PITCH
		min_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		min_row.add_child(min_input)
		box_min_inputs.append(min_input)
	controls.add_child(_label("Box size X / Y / Z"))
	var size_row := HBoxContainer.new()
	controls.add_child(size_row)
	for axis in 3:
		var size_input := SpinBox.new()
		size_input.min_value = Asset.PITCH
		size_input.max_value = Asset.MAX_COORD * Asset.PITCH
		size_input.step = Asset.PITCH
		size_input.value = 0.25
		size_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_row.add_child(size_input)
		box_size_inputs.append(size_input)
	_button(controls, "Add Collision Box", _add_collision_box)
	_button(controls, "Update Selected Box", _update_collision_box)
	_button(controls, "Delete Selected Box", _delete_collision_box)
	attachment_picker = OptionButton.new()
	attachment_picker.item_selected.connect(_select_attachment)
	controls.add_child(attachment_picker)
	attachment_input = LineEdit.new()
	attachment_input.placeholder_text = "Attachment name"
	controls.add_child(attachment_input)
	_button(controls, "Add Attachment at XYZ", _add_attachment)
	_button(controls, "Update Selected Attachment", _update_attachment)
	_button(controls, "Delete Selected Attachment", _delete_attachment)
	_button(controls, "Add Reference Image", _choose_reference)
	reference_preview = TextureRect.new()
	reference_preview.custom_minimum_size = Vector2(180, 120)
	reference_preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	controls.add_child(reference_preview)
	_button(controls, "Save Thumbnail", _save_thumbnail)
	controls.add_child(_label("Left drag: brush stroke\nRight drag: orbit\nWheel: zoom"))

	viewport_panel = SubViewportContainer.new()
	viewport_panel.stretch = true
	viewport_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport_panel.gui_input.connect(_viewport_input)
	split.add_child(viewport_panel)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(700, 600)
	viewport_panel.add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#303a45")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.8
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)
	camera = Camera3D.new()
	camera.current = true
	world.add_child(camera)
	_update_camera()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	world.add_child(light)
	var grid_mesh := ImmediateMesh.new()
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.albedo_color = Color("#586675")
	grid_mesh.surface_begin(Mesh.PRIMITIVE_LINES, line_material)
	for i in range(-10, 11):
		var v := float(i) * Asset.PITCH
		grid_mesh.surface_add_vertex(Vector3(v, -0.003, -1.25))
		grid_mesh.surface_add_vertex(Vector3(v, -0.003, 1.25))
		grid_mesh.surface_add_vertex(Vector3(-1.25, -0.003, v))
		grid_mesh.surface_add_vertex(Vector3(1.25, -0.003, v))
	grid_mesh.surface_end()
	var grid := MeshInstance3D.new()
	grid.mesh = grid_mesh
	world.add_child(grid)
	status = _label("Place voxels to build an asset.")
	root.add_child(status)
	open_dialog = FileDialog.new()
	open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.add_filter("*.json", "Studio voxel asset")
	open_dialog.file_selected.connect(_open_asset)
	add_child(open_dialog)
	reference_dialog = FileDialog.new()
	reference_dialog.access = FileDialog.ACCESS_FILESYSTEM
	reference_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	reference_dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp", "Reference image")
	reference_dialog.file_selected.connect(_add_reference)
	add_child(reference_dialog)
	recovery_dialog = ConfirmationDialog.new()
	recovery_dialog.title = "Recover voxel asset?"
	recovery_dialog.dialog_text = "An unsaved asset was found. Restore it?"
	recovery_dialog.confirmed.connect(_restore)
	add_child(recovery_dialog)
	var timer := Timer.new()
	timer.wait_time = 15.0
	timer.autostart = true
	timer.timeout.connect(_autosave)
	add_child(timer)

func _label(value: String) -> Label:
	var label := Label.new()
	label.text = value
	return label

func _button(parent: Node, value: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 40
	button.pressed.connect(callback)
	parent.add_child(button)

func _new_asset() -> void:
	_autosave()
	asset_doc = Asset.create("Untitled Asset")
	asset_doc = Asset.set_voxel(asset_doc, 0, 0, 0, 0)
	saved_text = ""
	history = History.new()
	_load_history()
	_refresh()

func _choose_asset() -> void:
	open_dialog.current_dir = project_path.path_join("assets/studio/assets")
	open_dialog.popup_centered_ratio(0.8)

func _open_asset(path: String) -> void:
	if not path.begins_with(project_path.path_join("assets/studio/assets") + "/"):
		status.text = "Choose an asset in this Forgefall project's assets/studio/assets."
		return
	var candidate: Dictionary = Store.read_json(path)
	var problem: String = Asset.validate(candidate)
	if problem != "":
		status.text = problem
		return
	_autosave()
	asset_doc = candidate
	saved_text = JSON.stringify(asset_doc)
	history = History.new()
	_load_history()
	_refresh()

func _save() -> bool:
	var problem: String = Asset.validate(asset_doc)
	if problem != "":
		status.text = problem
		return false
	var path: String = Asset.path(project_path, asset_doc["id"])
	if FileAccess.file_exists(path):
		if saved_text == "" or not Asset.same(Store.read_json(path), JSON.parse_string(saved_text)):
			status.text = "Asset changed on disk; refusing to overwrite."
			return false
	var result: Error = Store.write_json(path, asset_doc)
	if result != OK:
		status.text = "Save failed: " + error_string(result)
		return false
	saved_text = JSON.stringify(asset_doc)
	var recovery_index: Dictionary = Store.read_json(ProjectSettings.globalize_path(_recovery_index_path()))
	if recovery_index.get("asset_id", "") == asset_doc["id"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_recovery_path()))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_recovery_index_path()))
	status.text = "Saved asset to library: " + path
	_refresh()
	return true

func _publish() -> void:
	if not _save():
		return
	var executable := OS.get_environment("GODOT_EDITOR_PATH")
	if executable.is_empty():
		executable = OS.get_executable_path()
	var output := []
	var code := OS.execute(executable, ["--headless", "--path", project_path, "--script", "res://tools/studio_generate.gd", "--", "asset", str(asset_doc["id"])], output, true)
	if code == 0:
		status.text = "Published voxel asset with chunk collision."
	else:
		status.text = "Publish failed (" + str(code) + "): " + (str(output[0]) if not output.is_empty() else "Check Godot output.")

func _recovery_index_path() -> String:
	return "user://recovery/asset_" + project_path.sha256_text().substr(0, 16) + "_latest.json"

func _recovery_path() -> String:
	return "user://recovery/asset_" + project_path.sha256_text().substr(0, 16) + "_" + str(asset_doc.get("id", "")) + ".json"

func _autosave() -> void:
	if asset_doc.is_empty() or JSON.stringify(asset_doc) == saved_text:
		return
	Store.write_json(ProjectSettings.globalize_path(_recovery_path()), asset_doc)
	Store.write_json(ProjectSettings.globalize_path(_recovery_index_path()), {"asset_id": asset_doc["id"]})

func _check_recovery() -> void:
	var index: Dictionary = Store.read_json(ProjectSettings.globalize_path(_recovery_index_path()))
	if not index.has("asset_id"):
		return
	var recovery := "user://recovery/asset_" + project_path.sha256_text().substr(0, 16) + "_" + str(index["asset_id"]) + ".json"
	recovery_candidate = Store.read_json(ProjectSettings.globalize_path(recovery))
	if Asset.validate(recovery_candidate) == "":
		recovery_dialog.popup_centered()

func _restore() -> void:
	asset_doc = recovery_candidate
	saved_text = ""
	history = History.new()
	_load_history()
	status.text = "Recovered unsaved asset. Save to keep it."
	_refresh()

func _close() -> void:
	_autosave()
	queue_free()

func _set_tool(value: String) -> void:
	tool = value
	status.text = value + " tool selected."

func _select_material(index: int) -> void:
	material_index = index
	picker.color = Color(str(asset_doc["palette"][index]))

func _change_color(color: Color) -> void:
	var next_doc: Dictionary = asset_doc.duplicate(true)
	next_doc["palette"][material_index] = "#" + color.to_html(false)
	_commit("Edit material", next_doc)

func _apply_coordinates() -> void:
	var cell := Vector3i(int(axis_inputs[0].value), int(axis_inputs[1].value), int(axis_inputs[2].value))
	_apply_cell(cell)

func _apply_cell(cell: Vector3i) -> void:
	if absi(cell.x) > Asset.MAX_COORD or absi(cell.y) > Asset.MAX_COORD or absi(cell.z) > Asset.MAX_COORD:
		return
	var next_doc: Dictionary
	if tool == "Fill":
		next_doc = Asset.flood_fill(asset_doc, cell, material_index)
	elif tool == "Smooth":
		next_doc = Asset.smooth(asset_doc, cell, brush_radius, material_index, layer_index)
	elif tool == "Deform":
		next_doc = Asset.deform(asset_doc, cell, brush_radius, deform_offset, layer_index)
	elif tool == "Deform Brush":
		next_doc = Asset.deform_brush(asset_doc, cell, brush_radius, deform_offset, brush_strength, layer_index)
	elif tool == "Erase":
		next_doc = Asset.stamp(asset_doc, cell, brush_shape, brush_radius, material_index, layer_index, true, symmetry)
	else:
		next_doc = Asset.stamp(asset_doc, cell, brush_shape, brush_radius, material_index, layer_index, false, symmetry)
	_commit(tool + " voxel", next_doc)

func _commit(name: String, next_doc: Dictionary) -> void:
	if JSON.stringify(next_doc) == JSON.stringify(asset_doc):
		return
	asset_doc = history.execute(asset_doc, name, next_doc)
	_persist_history()
	_refresh()

func _undo() -> void:
	asset_doc = history.undo(asset_doc)
	_persist_history()
	_refresh()

func _redo() -> void:
	asset_doc = history.redo(asset_doc)
	_persist_history()
	_refresh()

func _history_path() -> String:
	return "user://history/asset_" + project_path.sha256_text().substr(0, 16) + "_" + str(asset_doc.get("id", "")) + ".json"

func _persist_history() -> void:
	if project_path.is_empty() or asset_doc.is_empty():
		return
	Store.write_json(ProjectSettings.globalize_path(_history_path()), history.to_dict())

func _load_history() -> void:
	if project_path.is_empty() or asset_doc.is_empty():
		return
	history.load_dict(Store.read_json(ProjectSettings.globalize_path(_history_path())), asset_doc)

func _refresh() -> void:
	if title == null:
		return
	title.text = ("● " if JSON.stringify(asset_doc) != saved_text else "") + str(asset_doc["name"])
	count_label.text = str(asset_doc["voxels"].size()) + " voxels"
	palette.clear()
	for i in asset_doc["palette"].size():
		palette.add_item("Material " + str(i + 1), i)
	material_index = mini(material_index, asset_doc["palette"].size() - 1)
	palette.select(material_index)
	picker.color = Color(str(asset_doc["palette"][material_index]))
	layer_picker.clear()
	for i in asset_doc.get("layers", [{"name": "Base", "visible": true}]).size():
		var layer: Dictionary = asset_doc.get("layers", [{"name": "Base", "visible": true}])[i]
		layer_picker.add_item(("👁 " if layer.get("visible", true) else "× ") + ("▣ " if layer.get("collision", true) else "□ ") + str(layer["name"]))
	layer_index = mini(layer_index, layer_picker.item_count - 1)
	layer_picker.select(layer_index)
	layer_name_input.text = str(asset_doc.get("layers", [{"name": "Base"}])[layer_index]["name"])
	attachment_picker.clear()
	for attachment in asset_doc.get("attachments", []):
		attachment_picker.add_item(str(attachment["name"]))
	attachment_index = mini(attachment_index, attachment_picker.item_count - 1)
	if attachment_index >= 0:
		attachment_picker.select(attachment_index)
	collision_picker.select({"static": 0, "none": 1, "custom": 2}.get(str(asset_doc.get("collision", "static")), 0))
	box_picker.clear()
	for i in asset_doc.get("collision_boxes", []).size():
		var box: Dictionary = asset_doc["collision_boxes"][i]
		box_picker.add_item("Box %d: min %s size %s" % [i + 1, str(box["min"]), str(box["size"])])
	collision_box_index = mini(collision_box_index, box_picker.item_count - 1)
	if collision_box_index >= 0:
		box_picker.select(collision_box_index)
	reference_preview.texture = null
	var references: Array = asset_doc.get("references", [])
	if not references.is_empty():
		var path := project_path.path_join(str(references[-1]["path"]).trim_prefix("res://"))
		var image := Image.new()
		if image.load(path) == OK:
			reference_preview.texture = ImageTexture.create_from_image(image)
	if preview != null:
		preview.queue_free()
	var visible_doc: Dictionary = asset_doc.duplicate(true)
	var visible_voxels := []
	for voxel in visible_doc["voxels"]:
		var index := int(voxel.get("layer", 0))
		if visible_doc.get("layers", [{"visible": true}])[index].get("visible", true):
			visible_voxels.append(voxel)
	visible_doc["voxels"] = visible_voxels
	preview = Mesher.build_node(visible_doc, true)
	world.add_child(preview)

func _update_camera() -> void:
	if camera == null:
		return
	var direction := Vector3(cos(camera_pitch) * sin(camera_yaw), sin(camera_pitch), cos(camera_pitch) * cos(camera_yaw))
	var focus := Vector3.ONE * (Asset.PITCH * 0.5)
	camera.position = focus + direction * camera_distance
	camera.look_at(focus, Vector3.UP)

func _viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera_distance = maxf(0.5, camera_distance - 0.25)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera_distance = minf(20.0, camera_distance + 0.25)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				stroke_active = true
				stroke_cells.clear()
				_record_stroke(event.position)
			else:
				_finish_stroke()
		_update_camera()
	elif event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			camera_yaw -= event.relative.x * 0.01
			camera_pitch = clampf(camera_pitch - event.relative.y * 0.01, 0.1, 1.4)
			_update_camera()
		elif stroke_active:
			_record_stroke(event.position)

func _click_model(position: Vector2) -> void:
	var cell: Variant = _pick_cell(position)
	if cell != null:
		_apply_cell(cell)

func _pick_cell(position: Vector2) -> Variant:
	var viewport_point := position * Vector2(viewport.size) / viewport_panel.size
	var origin := camera.project_ray_origin(viewport_point)
	var end := origin + camera.project_ray_normal(viewport_point) * 50.0
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	var world_3d := viewport.find_world_3d()
	if world_3d == null:
		return
	var hit := world_3d.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var offset: Vector3 = hit["normal"] * (Asset.PITCH * 0.2)
	if tool in ["Erase", "Paint", "Fill", "Smooth", "Deform", "Deform Brush"]:
		offset = -offset
	var point: Vector3 = hit["position"] + offset
	var cell := Vector3i(floori(point.x / Asset.PITCH), floori(point.y / Asset.PITCH), floori(point.z / Asset.PITCH))
	return cell

func _record_stroke(position: Vector2) -> void:
	var cell: Variant = _pick_cell(position)
	if cell != null and not stroke_cells.has(cell):
		stroke_cells.append(cell)

func _finish_stroke() -> void:
	stroke_active = false
	if stroke_cells.is_empty():
		return
	var next_doc: Dictionary = asset_doc.duplicate(true)
	for cell in stroke_cells:
		if tool == "Fill":
			next_doc = Asset.flood_fill(next_doc, cell, material_index)
		elif tool == "Smooth":
			next_doc = Asset.smooth(next_doc, cell, brush_radius, material_index, layer_index)
		elif tool == "Deform":
			next_doc = Asset.deform(next_doc, cell, brush_radius, deform_offset, layer_index)
		elif tool == "Deform Brush":
			next_doc = Asset.deform_brush(next_doc, cell, brush_radius, deform_offset, brush_strength, layer_index)
		else:
			next_doc = Asset.stamp(next_doc, cell, brush_shape, brush_radius, material_index, layer_index, tool == "Erase", symmetry)
	stroke_cells.clear()
	_commit(tool + " stroke", next_doc)

func _toggle_symmetry(enabled: bool, axis: int) -> void:
	symmetry[axis] = 1 if enabled else 0

func _select_deform_direction(index: int) -> void:
	deform_offset = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD][index]

func _add_layer() -> void:
	var next_doc: Dictionary = asset_doc.duplicate(true)
	if next_doc.get("layers", []).size() >= 32:
		return
	if not next_doc.has("layers"):
		next_doc["layers"] = [{"name": "Base", "visible": true}]
	next_doc["layers"].append({"name": "Layer " + str(next_doc["layers"].size() + 1), "visible": true, "collision": true})
	layer_index = next_doc["layers"].size() - 1
	_commit("Add layer", next_doc)

func _rename_layer() -> void:
	_commit("Rename layer", Asset.rename_layer(asset_doc, layer_index, layer_name_input.text))

func _move_layer(direction: int) -> void:
	var next_doc: Dictionary = Asset.move_layer(asset_doc, layer_index, direction)
	if JSON.stringify(next_doc) != JSON.stringify(asset_doc):
		layer_index += direction
		_commit("Move layer", next_doc)

func _merge_layer() -> void:
	var next_doc: Dictionary = Asset.merge_layer_down(asset_doc, layer_index)
	if JSON.stringify(next_doc) != JSON.stringify(asset_doc):
		layer_index -= 1
		_commit("Merge layer", next_doc)

func _toggle_layer_collision() -> void:
	var next_doc: Dictionary = asset_doc.duplicate(true)
	if not next_doc.has("layers"):
		next_doc["layers"] = [{"name": "Base", "visible": true, "collision": true}]
	next_doc["layers"][layer_index]["collision"] = not next_doc["layers"][layer_index].get("collision", true)
	_commit("Toggle layer collision", next_doc)

func _toggle_layer() -> void:
	var next_doc: Dictionary = asset_doc.duplicate(true)
	if not next_doc.has("layers"):
		next_doc["layers"] = [{"name": "Base", "visible": true, "collision": true}]
	next_doc["layers"][layer_index]["visible"] = not next_doc["layers"][layer_index]["visible"]
	_commit("Toggle layer", next_doc)

func _set_pivot() -> void:
	var next_doc: Dictionary = asset_doc.duplicate(true)
	next_doc["origin"] = [axis_inputs[0].value * Asset.PITCH, axis_inputs[1].value * Asset.PITCH, axis_inputs[2].value * Asset.PITCH]
	_commit("Set pivot", next_doc)

func _set_collision(index: int) -> void:
	var next_doc: Dictionary = asset_doc.duplicate(true)
	next_doc["collision"] = ["static", "none", "custom"][index]
	var problem: String = Asset.validate(next_doc)
	if problem != "":
		status.text = problem
		_refresh()
		return
	_commit("Set collision", next_doc)

func _box_from_inputs() -> Array:
	var min_corner := Vector3(box_min_inputs[0].value, box_min_inputs[1].value, box_min_inputs[2].value)
	var size := Vector3(box_size_inputs[0].value, box_size_inputs[1].value, box_size_inputs[2].value)
	return [min_corner, size]

func _select_collision_box(index: int) -> void:
	collision_box_index = index
	if index < 0 or index >= asset_doc.get("collision_boxes", []).size():
		return
	var box: Dictionary = asset_doc["collision_boxes"][index]
	for axis in 3:
		box_min_inputs[axis].value = float(box["min"][axis])
		box_size_inputs[axis].value = float(box["size"][axis])

func _add_collision_box() -> void:
	var parts := _box_from_inputs()
	var next_doc: Dictionary = Asset.add_collision_box(asset_doc, parts[0], parts[1])
	next_doc["collision"] = "custom"
	var problem: String = Asset.validate(next_doc)
	if problem != "":
		status.text = problem
		return
	collision_box_index = next_doc["collision_boxes"].size() - 1
	_commit("Add collision box", next_doc)

func _update_collision_box() -> void:
	if collision_box_index < 0 or collision_box_index >= asset_doc.get("collision_boxes", []).size():
		return
	var parts := _box_from_inputs()
	var next_doc: Dictionary = Asset.set_collision_box(asset_doc, collision_box_index, parts[0], parts[1])
	var problem: String = Asset.validate(next_doc)
	if problem != "":
		status.text = problem
		return
	_commit("Update collision box", next_doc)

func _delete_collision_box() -> void:
	if collision_box_index < 0 or collision_box_index >= asset_doc.get("collision_boxes", []).size():
		return
	var next_doc: Dictionary = Asset.remove_collision_box(asset_doc, collision_box_index)
	var problem: String = Asset.validate(next_doc)
	if problem != "":
		status.text = problem
		return
	collision_box_index = mini(collision_box_index, next_doc["collision_boxes"].size() - 1)
	_commit("Delete collision box", next_doc)

func _add_attachment() -> void:
	var name := attachment_input.text.strip_edges()
	if name.is_empty() or asset_doc.get("attachments", []).size() >= 64:
		return
	var next_doc: Dictionary = asset_doc.duplicate(true)
	next_doc["attachments"].append({"name": name, "position": [axis_inputs[0].value * Asset.PITCH, axis_inputs[1].value * Asset.PITCH, axis_inputs[2].value * Asset.PITCH]})
	var problem: String = Asset.validate(next_doc)
	if problem != "":
		status.text = problem
		return
	attachment_index = next_doc["attachments"].size() - 1
	_commit("Add attachment", next_doc)
	attachment_input.clear()

func _select_attachment(index: int) -> void:
	attachment_index = index
	var attachment: Dictionary = asset_doc["attachments"][index]
	attachment_input.text = str(attachment["name"])
	var position: Array = attachment["position"]
	for axis in 3:
		axis_inputs[axis].value = float(position[axis]) / Asset.PITCH

func _update_attachment() -> void:
	if attachment_index < 0 or attachment_index >= asset_doc["attachments"].size():
		return
	var next_doc: Dictionary = asset_doc.duplicate(true)
	next_doc["attachments"][attachment_index] = {"name": attachment_input.text.strip_edges(), "position": [axis_inputs[0].value * Asset.PITCH, axis_inputs[1].value * Asset.PITCH, axis_inputs[2].value * Asset.PITCH]}
	var problem: String = Asset.validate(next_doc)
	if problem != "":
		status.text = problem
		return
	_commit("Update attachment", next_doc)

func _delete_attachment() -> void:
	if attachment_index < 0 or attachment_index >= asset_doc["attachments"].size():
		return
	var next_doc: Dictionary = asset_doc.duplicate(true)
	next_doc["attachments"].remove_at(attachment_index)
	attachment_index = mini(attachment_index, next_doc["attachments"].size() - 1)
	_commit("Delete attachment", next_doc)

func _choose_reference() -> void:
	reference_dialog.popup_centered_ratio(0.8)

func _add_reference(path: String) -> void:
	var extension := path.get_extension().to_lower()
	if not extension in ["png", "jpg", "jpeg", "webp"]:
		return
	var folder := project_path.path_join("assets/studio/references")
	DirAccess.make_dir_recursive_absolute(folder)
	var destination := folder.path_join(asset_doc["id"] + "_" + str(Time.get_ticks_usec()) + "." + extension)
	if DirAccess.copy_absolute(path, destination) != OK:
		status.text = "Reference copy failed."
		return
	var next_doc: Dictionary = asset_doc.duplicate(true)
	if not next_doc.has("references"):
		next_doc["references"] = []
	next_doc["references"].append({"path": "res://assets/studio/references/" + destination.get_file()})
	_commit("Add reference", next_doc)

func _save_thumbnail() -> void:
	if DisplayServer.get_name() == "headless":
		status.text = "Thumbnail capture needs a visible window."
		return
	var folder := project_path.path_join("assets/studio/thumbnails")
	DirAccess.make_dir_recursive_absolute(folder)
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		status.text = "Thumbnail capture unavailable."
		return
	var result := image.save_png(folder.path_join(asset_doc["id"] + ".png"))
	status.text = "Thumbnail saved." if result == OK else "Thumbnail save failed."

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.ctrl_pressed and event.keycode == KEY_S:
			_save()
		elif event.ctrl_pressed and event.keycode == KEY_Z:
			_undo()
		elif event.ctrl_pressed and event.keycode == KEY_Y:
			_redo()
