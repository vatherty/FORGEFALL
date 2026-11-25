extends Control

const Store = preload("res://shared/document_store.gd")
const Asset = preload("res://shared/asset_document.gd")
const Content = preload("res://content_document.gd")
const Mesher = preload("res://shared/voxel_mesh.gd")

var project_path := ""
var document: Dictionary = {}
var saved_text := ""
var content_type := "character"
var editor: TextEdit
var status: Label
var title: Label
var open_dialog: FileDialog
var timeline_panel: VBoxContainer
var timeline_name: LineEdit
var duration: SpinBox
var offset_inputs: Array[SpinBox] = []
var preview_viewport: SubViewport
var preview_world: Node3D
var preview_node: Node3D
var preview_player: AnimationPlayer
var scrub: HSlider
var scrub_guard := false
var form_rows: Dictionary = {}
var content_name: LineEdit
var visual_asset: LineEdit
var equipped_weapon: LineEdit
var part_name: LineEdit
var part_parent: LineEdit
var part_select: OptionButton
var part_values: Array[SpinBox] = []
var part_color: ColorPickerButton
var weapon_values: Array[SpinBox] = []
var muzzle_values: Array[SpinBox] = []
var auto_fire_control: CheckBox
var sight_control: SpinBox
var move_control: SpinBox
var stride_control: SpinBox
var swing_control: SpinBox

func _ready() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var bar := HBoxContainer.new()
	root.add_child(bar)
	_button(bar, "← Map", func() -> void: queue_free())
	_button(bar, "New Character", _new.bind("character"))
	_button(bar, "New Weapon", _new.bind("weapon"))
	_button(bar, "Open", _choose)
	_button(bar, "Save", _save)
	_button(bar, "Publish", _publish)
	title = Label.new()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	var control_scroll := ScrollContainer.new()
	control_scroll.custom_minimum_size.x = 320
	control_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(control_scroll)
	var controls := VBoxContainer.new()
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control_scroll.add_child(controls)
	var instructions := Label.new()
	instructions.text = "Edit rig parts and weapon values below.\nJSON remains available for advanced fields.\nPublish a weapon before its character."
	controls.add_child(instructions)
	timeline_panel = VBoxContainer.new()
	controls.add_child(timeline_panel)
	timeline_panel.add_child(_label("Asset machinery timeline"))
	timeline_panel.add_child(_label("Open a voxel asset JSON to add a lift/door travel track."))
	_button(timeline_panel, "Open Voxel Asset", _choose_asset)
	timeline_name = LineEdit.new()
	timeline_name.placeholder_text = "Animation name, e.g. Open"
	timeline_panel.add_child(timeline_name)
	duration = SpinBox.new()
	duration.min_value = 0.1
	duration.max_value = 120.0
	duration.step = 0.1
	duration.value = 1.0
	timeline_panel.add_child(_label("Duration (seconds)"))
	timeline_panel.add_child(duration)
	for axis in ["X", "Y", "Z"]:
		timeline_panel.add_child(_label("End offset " + axis + " (meters)"))
		var spin := SpinBox.new()
		spin.min_value = -100.0
		spin.max_value = 100.0
		spin.step = 0.1
		timeline_panel.add_child(spin)
		offset_inputs.append(spin)
	_button(timeline_panel, "Add/Replace 2-Key Track", _add_timeline)
	_button(timeline_panel, "Play Current Track", _play_timeline)
	_button(timeline_panel, "Stop", _stop_timeline)
	scrub = HSlider.new()
	scrub.min_value = 0.0
	scrub.max_value = 1.0
	scrub.step = 0.01
	scrub.custom_minimum_size.y = 28
	scrub.value_changed.connect(_scrub_timeline)
	timeline_panel.add_child(_label("Scrub timeline"))
	timeline_panel.add_child(scrub)
	_build_visual_forms(controls)
	var right := VSplitContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	editor = TextEdit.new()
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.text_changed.connect(_on_text_changed)
	right.add_child(editor)
	_build_preview(right)
	status = _label("Create content or open an existing document.")
	root.add_child(status)
	open_dialog = FileDialog.new()
	open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.add_filter("*.json", "Studio content document")
	open_dialog.file_selected.connect(_open)
	add_child(open_dialog)
	_new("character")

func _button(parent: Node, caption: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size.y = 38
	button.pressed.connect(callback)
	parent.add_child(button)

func _label(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _new(kind: String) -> void:
	content_type = kind
	document = Content.new_character("New Character") if kind == "character" else Content.new_weapon("New Weapon")
	saved_text = ""
	editor.text = JSON.stringify(document, "\t")
	editor.clear_undo_history()
	_refresh_title()
	_sync_fields()
	_refresh_preview()

func _choose() -> void:
	open_dialog.current_dir = project_path.path_join("assets/studio")
	open_dialog.popup_centered_ratio(0.8)

func _choose_asset() -> void:
	open_dialog.current_dir = project_path.path_join("assets/studio/assets")
	open_dialog.popup_centered_ratio(0.8)

func _open(path: String) -> void:
	var base := project_path.path_join("assets/studio") + "/"
	if not path.begins_with(base):
		status.text = "Choose a file inside this Forgefall project."
		return
	var candidate := Store.read_json(path)
	var kind := str(candidate.get("kind", ""))
	var problem := Asset.validate(candidate) if kind == "asset" else Content.validate(candidate)
	if problem != "":
		status.text = problem
		return
	content_type = kind
	document = candidate
	saved_text = JSON.stringify(document)
	editor.text = JSON.stringify(document, "\t")
	editor.clear_undo_history()
	_refresh_title()
	_sync_fields()
	_refresh_preview()
	status.text = "Opened " + path

func _parse() -> Dictionary:
	var parsed: Variant = JSON.parse_string(editor.text)
	if not parsed is Dictionary:
		status.text = "Document must be a JSON object."
		return {}
	var problem := Asset.validate(parsed) if content_type == "asset" else Content.validate(parsed)
	if problem != "":
		status.text = problem
		return {}
	if parsed.get("id") != document.get("id") or parsed.get("kind") != content_type:
		status.text = "Content ID and kind cannot be changed in this editor."
		return {}
	if content_type == "asset":
		problem = Content.validate_animations(parsed.get("animations", []))
		if problem != "":
			status.text = problem
			return {}
	return parsed

func _save() -> bool:
	var parsed := _parse()
	if parsed.is_empty():
		return false
	var path := Asset.path(project_path, parsed["id"]) if content_type == "asset" else Content.path(project_path, parsed)
	if FileAccess.file_exists(path) and (saved_text == "" or JSON.stringify(Store.read_json(path)) != saved_text):
		status.text = "Document changed on disk; refusing overwrite."
		return false
	var error := Store.write_json(path, parsed)
	if error != OK:
		status.text = "Save failed: " + error_string(error)
		return false
	document = parsed
	saved_text = JSON.stringify(document)
	status.text = "Saved " + path
	_refresh_title()
	return true

func _publish() -> void:
	if not _save():
		return
	var executable := OS.get_environment("GODOT_EDITOR_PATH")
	if executable.is_empty():
		executable = OS.get_executable_path()
	var arguments := ["--headless", "--path", project_path, "--script", "res://tools/studio_generate.gd", "--", "asset", str(document["id"])] if content_type == "asset" else ["--headless", "--path", project_path, "--script", "res://tools/studio_content_generate.gd", "--", content_type, str(document["id"])]
	var output := []
	var code := OS.execute(executable, arguments, output, true)
	status.text = "Published " + content_type + "." if code == 0 else "Publish failed (%d): %s" % [code, str(output[0]) if not output.is_empty() else "See Godot output."]

func _add_timeline() -> void:
	if content_type != "asset":
		status.text = "Open a voxel asset first."
		return
	var parsed := _parse()
	if parsed.is_empty():
		return
	var name := timeline_name.text.strip_edges()
	if not Content.safe_name(name):
		status.text = "Animation name must be a valid identifier."
		return
	var animation := {"name": name, "loop": false, "keys": [{"time": 0.0, "position": [0.0, 0.0, 0.0]}, {"time": duration.value, "position": [offset_inputs[0].value, offset_inputs[1].value, offset_inputs[2].value]}]}
	var animations: Array = parsed.get("animations", [])
	var replaced := false
	for i in animations.size():
		if animations[i]["name"] == name:
			animations[i] = animation
			replaced = true
	if not replaced:
		animations.append(animation)
	parsed["animations"] = animations
	var problem := Content.validate_animations(animations)
	if problem != "":
		status.text = problem
		return
	editor.text = JSON.stringify(parsed, "\t")
	_refresh_preview()
	status.text = "Timeline added. Drag the scrubber or press Play to preview."

func _play_timeline() -> void:
	if preview_player == null:
		status.text = "Open an animated voxel asset first."
		return
	var name := timeline_name.text.strip_edges()
	if name == "" and preview_player.get_animation_list().size() > 0:
		name = str(preview_player.get_animation_list()[0])
	if not preview_player.has_animation(name):
		status.text = "No matching timeline."
		return
	preview_player.play(name)
	scrub.max_value = preview_player.get_animation(name).length
	status.text = "Playing " + name

func _stop_timeline() -> void:
	if preview_player != null:
		preview_player.stop()

func _scrub_timeline(value: float) -> void:
	if scrub_guard or preview_player == null:
		return
	var name := timeline_name.text.strip_edges()
	if name == "" and preview_player.get_animation_list().size() > 0:
		name = str(preview_player.get_animation_list()[0])
	if preview_player.has_animation(name):
		preview_player.play(name)
		preview_player.seek(value, true)
		preview_player.pause()

func _process(_delta: float) -> void:
	if preview_player != null and preview_player.is_playing():
		scrub_guard = true
		scrub.value = preview_player.current_animation_position
		scrub_guard = false

func _refresh_title() -> void:
	if title != null:
		title.text = ("● " if JSON.stringify(document) != saved_text or editor.text != JSON.stringify(document, "\t") else "") + str(document.get("name", "Content"))

func _build_visual_forms(parent: VBoxContainer) -> void:
	parent.add_child(_label("Visual content controls"))
	content_name = _line(parent, "Name")
	visual_asset = _line(parent, "Voxel asset ID (optional)")
	equipped_weapon = _line(parent, "Equipped weapon ID")
	form_rows["equipped_weapon"] = equipped_weapon
	auto_fire_control = CheckBox.new()
	auto_fire_control.text = "Auto fire at player"
	parent.add_child(auto_fire_control)
	form_rows["auto_fire"] = auto_fire_control
	sight_control = _spin(parent, "Sight range", 0.0, 1000.0, 0.5)
	form_rows["sight"] = sight_control
	move_control = _spin(parent, "Move speed (0 = stationary)", 0.0, 20.0, 0.1)
	form_rows["move"] = move_control
	stride_control = _spin(parent, "Stride length (walk cycle)", 0.05, 5.0, 0.05)
	form_rows["stride"] = stride_control
	swing_control = _spin(parent, "Swing (degrees, walk cycle)", 0.0, 80.0, 1.0)
	form_rows["swing"] = swing_control
	_button(parent, "Apply Name / Links / AI", _apply_common_fields)
	var part_header := _label("Character rig parts")
	parent.add_child(part_header)
	form_rows["part_header"] = part_header
	part_select = OptionButton.new()
	part_select.item_selected.connect(_select_part)
	parent.add_child(part_select)
	form_rows["part_select"] = part_select
	part_name = _line(parent, "Part name")
	part_parent = _line(parent, "Parent part (empty = root)")
	form_rows["part_name"] = part_name
	form_rows["part_parent"] = part_parent
	for caption in ["Part X", "Part Y", "Part Z", "Width", "Height", "Depth"]:
		var spin := _spin(parent, caption, -100.0 if part_values.size() < 3 else 0.0, 100.0, 0.05)
		part_values.append(spin)
		form_rows["part_value_%d" % (part_values.size() - 1)] = spin
	part_color = ColorPickerButton.new()
	part_color.text = "Part color"
	parent.add_child(part_color)
	form_rows["part_color"] = part_color
	var part_apply := Button.new()
	part_apply.text = "Add / Update Part"
	part_apply.pressed.connect(_apply_part)
	parent.add_child(part_apply)
	form_rows["part_apply"] = part_apply
	var part_delete := Button.new()
	part_delete.text = "Delete Selected Part"
	part_delete.pressed.connect(_delete_part)
	parent.add_child(part_delete)
	form_rows["part_delete"] = part_delete
	var weapon_header := _label("Weapon settings")
	parent.add_child(weapon_header)
	form_rows["weapon_header"] = weapon_header
	for caption in ["Damage", "Range", "Cooldown", "Magazine"]:
		var spin := _spin(parent, caption, 0.0 if caption != "Magazine" else 1.0, 10000.0, 1.0 if caption == "Magazine" else 0.05)
		weapon_values.append(spin)
		form_rows["weapon_value_%d" % (weapon_values.size() - 1)] = spin
	for axis in ["X", "Y", "Z"]:
		var spin := _spin(parent, "Muzzle " + axis, -100.0, 100.0, 0.05)
		muzzle_values.append(spin)
		form_rows["muzzle_%d" % (muzzle_values.size() - 1)] = spin
	var weapon_apply := Button.new()
	weapon_apply.text = "Apply Weapon Settings"
	weapon_apply.pressed.connect(_apply_weapon_fields)
	parent.add_child(weapon_apply)
	form_rows["weapon_apply"] = weapon_apply

func _line(parent: Node, placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	parent.add_child(field)
	return field

func _spin(parent: Node, caption: String, minimum: float, maximum: float, increment: float) -> SpinBox:
	parent.add_child(_label(caption))
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = increment
	spin.allow_greater = false
	spin.allow_lesser = false
	parent.add_child(spin)
	return spin

func _build_preview(parent: Node) -> void:
	var panel := SubViewportContainer.new()
	panel.custom_minimum_size.y = 300
	panel.stretch = true
	parent.add_child(panel)
	preview_viewport = SubViewport.new()
	preview_viewport.size = Vector2i(640, 320)
	preview_viewport.own_world_3d = true
	panel.add_child(preview_viewport)
	preview_world = Node3D.new()
	preview_viewport.add_child(preview_world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("#293443")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.9
	preview_world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -30, 0)
	preview_world.add_child(light)
	var camera := Camera3D.new()
	camera.position = Vector3(1.45, 1.55, 2.1)
	preview_world.add_child(camera)
	camera.look_at(Vector3(0, 0.8, 0))
	camera.current = true

func _on_text_changed() -> void:
	_refresh_title()
	_refresh_preview()

func _sync_fields() -> void:
	var parsed: Variant = JSON.parse_string(editor.text)
	if not parsed is Dictionary:
		return
	content_name.text = str(parsed.get("name", ""))
	visual_asset.text = str(parsed.get("asset_id", ""))
	var character_mode := content_type == "character"
	var weapon_mode := content_type == "weapon"
	timeline_panel.visible = content_type == "asset"
	for key in form_rows:
		var key_string := str(key)
		var show: bool = (character_mode and (key_string.begins_with("part_") or key_string in ["equipped_weapon", "auto_fire", "sight", "move", "stride", "swing"])) or (weapon_mode and (key_string.begins_with("weapon_") or key_string.begins_with("muzzle_")))
		var control: Control = form_rows[key]
		control.visible = show
		if control is SpinBox:
			var sibling_index := control.get_index() - 1
			if sibling_index >= 0 and control.get_parent().get_child(sibling_index) is Label:
				control.get_parent().get_child(sibling_index).visible = show
	if character_mode:
		equipped_weapon.text = str(parsed.get("weapon_id", ""))
		auto_fire_control.button_pressed = bool(parsed.get("auto_fire", true))
		sight_control.value = float(parsed.get("sight_range", 25.0))
		move_control.value = float(parsed.get("move_speed", 2.5))
		stride_control.value = float(parsed.get("stride_length", 0.7))
		swing_control.value = float(parsed.get("swing_degrees", 28.0))
		part_select.clear()
		for part in parsed.get("parts", []):
			part_select.add_item(str(part.get("name", "Part")))
		if part_select.item_count > 0:
			part_select.select(0)
			_select_part(0)
	elif weapon_mode:
		for i in 4:
			weapon_values[i].value = float(parsed.get(["damage", "range", "cooldown", "magazine"][i], 1.0))
		var muzzle: Array = parsed.get("muzzle", [0, 0, 0])
		if muzzle.size() == 3:
			for i in 3:
				muzzle_values[i].value = float(muzzle[i])

func _select_part(index: int) -> void:
	var parsed: Variant = JSON.parse_string(editor.text)
	if not parsed is Dictionary or not parsed.get("parts", []) is Array or index >= parsed["parts"].size():
		return
	var part: Dictionary = parsed["parts"][index]
	part_name.text = str(part.get("name", ""))
	part_parent.text = str(part.get("parent", ""))
	var values: Array = part.get("position", [0, 0, 0]) + part.get("size", [1, 1, 1])
	for i in mini(6, values.size()):
		part_values[i].value = float(values[i])
	part_color.color = Color(str(part.get("color", "#ffffff")))

func _apply_common_fields() -> void:
	var parsed := _parse()
	if parsed.is_empty():
		return
	parsed["name"] = content_name.text.strip_edges()
	if content_type in ["character", "weapon"]:
		parsed["asset_id"] = visual_asset.text.strip_edges()
	if content_type == "character":
		parsed["weapon_id"] = equipped_weapon.text.strip_edges()
		parsed["auto_fire"] = auto_fire_control.button_pressed
		parsed["sight_range"] = sight_control.value
		parsed["move_speed"] = move_control.value
		parsed["stride_length"] = stride_control.value
		parsed["swing_degrees"] = swing_control.value
	_commit_form(parsed, "Updated content fields.")

func _apply_part() -> void:
	if content_type != "character":
		return
	var parsed := _parse()
	if parsed.is_empty():
		return
	var previous := part_select.get_item_text(part_select.selected) if part_select.selected >= 0 else ""
	var part := {"name": part_name.text.strip_edges(), "parent": part_parent.text.strip_edges(), "position": [part_values[0].value, part_values[1].value, part_values[2].value], "size": [part_values[3].value, part_values[4].value, part_values[5].value], "color": "#" + part_color.color.to_html(false)}
	var index := -1
	for i in parsed["parts"].size():
		if parsed["parts"][i]["name"] == previous and previous == part["name"]:
			index = i
	if index >= 0:
		parsed["parts"][index] = part
	else:
		parsed["parts"].append(part)
	_commit_form(parsed, "Rig part updated.")

func _delete_part() -> void:
	if content_type != "character" or part_select.selected < 0:
		return
	var parsed := _parse()
	if parsed.is_empty():
		return
	var name := part_select.get_item_text(part_select.selected)
	for part in parsed["parts"]:
		if part.get("parent", "") == name:
			status.text = "Reparent child parts before deleting this part."
			return
	for i in parsed["parts"].size():
		if parsed["parts"][i]["name"] == name:
			parsed["parts"].remove_at(i)
			break
	_commit_form(parsed, "Rig part deleted.")

func _apply_weapon_fields() -> void:
	if content_type != "weapon":
		return
	var parsed := _parse()
	if parsed.is_empty():
		return
	for i in 4:
		parsed[["damage", "range", "cooldown", "magazine"][i]] = int(weapon_values[i].value) if i == 3 else weapon_values[i].value
	parsed["muzzle"] = [muzzle_values[0].value, muzzle_values[1].value, muzzle_values[2].value]
	_commit_form(parsed, "Weapon settings updated.")

func _commit_form(parsed: Dictionary, message: String) -> void:
	var problem := Asset.validate(parsed) if content_type == "asset" else Content.validate(parsed)
	if problem != "":
		status.text = problem
		return
	editor.text = JSON.stringify(parsed, "\t")
	_sync_fields()
	_refresh_preview()
	status.text = message

func _refresh_preview() -> void:
	if preview_world == null:
		return
	if preview_node != null:
		preview_world.remove_child(preview_node)
		preview_node.free()
	preview_node = Node3D.new()
	preview_world.add_child(preview_node)
	preview_player = null
	var parsed: Variant = JSON.parse_string(editor.text)
	if not parsed is Dictionary:
		return
	if content_type == "asset" and Asset.validate(parsed) == "" and Content.validate_animations(parsed.get("animations", [])) == "":
		var model: Node3D = Mesher.build_node(parsed, false)
		preview_node.add_child(model)
		var runtime: GDScript = load("res://content_runtime.gd")
		if runtime.decorate_asset(model, parsed) == "":
			preview_player = model.get_node_or_null("AnimationPlayer") as AnimationPlayer
			if preview_player != null and preview_player.get_animation_list().size() > 0:
				var name := timeline_name.text.strip_edges()
				if not preview_player.has_animation(name):
					name = str(preview_player.get_animation_list()[0])
				scrub.max_value = preview_player.get_animation(name).length
	elif content_type == "character" and Content.validate(parsed) == "":
		var nodes := {}
		for part in parsed["parts"]:
			var joint := Node3D.new()
			joint.name = str(part["name"])
			var pos: Array = part["position"]
			joint.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
			nodes[part["name"]] = joint
		for part in parsed["parts"]:
			var joint: Node3D = nodes[part["name"]]
			var parent: Node3D = nodes.get(str(part.get("parent", "")), preview_node)
			parent.add_child(joint)
			var mesh := BoxMesh.new()
			var size: Array = part["size"]
			mesh.size = Vector3(float(size[0]), float(size[1]), float(size[2]))
			var visual := MeshInstance3D.new()
			visual.mesh = mesh
			var material := StandardMaterial3D.new()
			material.albedo_color = Color(str(part["color"]))
			visual.material_override = material
			joint.add_child(visual)
	elif content_type == "weapon" and Content.validate(parsed) == "":
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.18, 0.16, 0.6)
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("#7b8794")
		visual.material_override = material
		preview_node.add_child(visual)
		var muzzle := MeshInstance3D.new()
		muzzle.mesh = SphereMesh.new()
		muzzle.scale = Vector3.ONE * 0.06
		var pos: Array = parsed["muzzle"]
		muzzle.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		preview_node.add_child(muzzle)
