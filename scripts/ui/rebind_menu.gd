# scripts/ui/rebind_menu.gd
# FORGEFALL — Controls / rebind screen (v0.6.1, Workstream A).
# Overlay opened from Options (main menu + pause menu). One row per
# gameplay action: [label | keyboard button | gamepad button].
# Click a binding button (or focus it + Confirm) to capture: the next
# key / mouse button / gamepad button / stick-or-trigger deflection
# becomes the new binding. Esc cancels a capture; Back (Esc/B) closes.
# Conflicts overwrite LOUDLY: InputBindings returns the replaced action
# labels and this screen shows them — two actions never silently share
# one binding (except the three documented intentional shares).
# Look is analog (mouse / right stick, not an InputMap action): shown as
# a fixed informational row. Dead zone is a slider here, persisted
# with the bindings. process_mode ALWAYS so it works from the pause
# menu while the tree is paused.
extends Control
class_name RebindMenu

signal closed

var _rows: Dictionary = {}  # action -> {"kb": Button, "pad": Button}
var _capturing_action := ""
var _capturing_kind := ""
var _capture_label: Label
var _warn_label: Label
var _deadzone_label: Label


## Opens the rebind overlay as a child of `parent`. Returns the instance.
static func open_in(parent: Node) -> RebindMenu:
	var menu := RebindMenu.new()
	menu.name = "RebindMenu"
	parent.add_child(menu)
	return menu


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	InputBindings.ensure_loaded()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh_all()
	InputBindings.grab_first_focus(self)


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "RebindPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	var vp := size
	if vp.x <= 0 or vp.y <= 0:
		vp = get_viewport().get_visible_rect().size if get_viewport() != null else Vector2(1280, 720)
	var pw := minf(860.0, vp.x * 0.94)
	var ph := minf(720.0, vp.y * 0.94)
	panel.offset_left = -pw / 2.0
	panel.offset_right = pw / 2.0
	panel.offset_top = -ph / 2.0
	panel.offset_bottom = ph / 2.0
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.name = "RebindStack"
	vb.alignment = BoxContainer.ALIGNMENT_BEGIN
	vb.add_theme_constant_override("separation", 6)
	vb.custom_minimum_size = Vector2(maxf(0.0, pw - 28.0), 0.0)
	scroll.add_child(vb)

	var head := Label.new()
	StencilStyle.apply_title(head, 30, StencilStyle.ORANGE, 4)
	head.text = "CONTROLS"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(head)

	var pad_lbl := Label.new()
	pad_lbl.name = "PadStatus"
	StencilStyle.apply_body(pad_lbl, 18, StencilStyle.TEXT_DIM, 2)
	pad_lbl.text = InputBindings.connected_pad_label()
	pad_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pad_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(pad_lbl)

	# Dead zone slider (the one tunable, persisted with the bindings).
	var dz_row := HBoxContainer.new()
	dz_row.add_theme_constant_override("separation", 12)
	vb.add_child(dz_row)
	var dz_lbl := Label.new()
	StencilStyle.apply_body(dz_lbl, 20, StencilStyle.TEXT, 2)
	dz_lbl.text = "STICK DEAD ZONE"
	dz_lbl.custom_minimum_size = Vector2(220, 0)
	dz_row.add_child(dz_lbl)
	var dz := HSlider.new()
	dz.min_value = 0.0
	dz.max_value = 0.5
	dz.step = 0.05
	dz.value = InputBindings.deadzone
	dz.custom_minimum_size = Vector2(280, 30)
	dz.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_slider(dz)
	dz.value_changed.connect(_on_deadzone_changed)
	dz_row.add_child(dz)
	_deadzone_label = Label.new()
	StencilStyle.apply_body(_deadzone_label, 20, StencilStyle.TEXT, 2)
	_deadzone_label.text = "%.2f" % InputBindings.deadzone
	dz_row.add_child(_deadzone_label)

	var hint := Label.new()
	StencilStyle.apply_body(hint, 18, StencilStyle.TEXT_DIM, 2)
	hint.text = "Select a binding, then press the new key / button. Esc cancels."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)

	_capture_label = Label.new()
	_capture_label.name = "CaptureLabel"
	StencilStyle.apply_body(_capture_label, 20, StencilStyle.ORANGE, 2)
	_capture_label.text = ""
	_capture_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_capture_label)
	_warn_label = Label.new()
	_warn_label.name = "WarnLabel"
	StencilStyle.apply_body(_warn_label, 18, StencilStyle.ORANGE, 2)
	_warn_label.text = ""
	_warn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warn_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_warn_label)

	# Header row.
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 12)
	vb.add_child(hdr)
	var h0 := Label.new()
	StencilStyle.apply_body(h0, 18, StencilStyle.TEXT_DIM, 2)
	h0.text = "ACTION"
	h0.custom_minimum_size = Vector2(280, 0)
	hdr.add_child(h0)
	for txt in ["KEYBOARD", "GAMEPAD"]:
		var hh := Label.new()
		StencilStyle.apply_body(hh, 18, StencilStyle.TEXT_DIM, 2)
		hh.text = txt
		hh.custom_minimum_size = Vector2(220, 0)
		hh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hdr.add_child(hh)

	var last_cat := ""
	for action in InputBindings.ACTIONS:
		var cat := str(InputBindings.CATEGORIES.get(action, ""))
		if cat != last_cat:
			last_cat = cat
			var cat_lbl := Label.new()
			StencilStyle.apply_body(cat_lbl, 18, StencilStyle.ORANGE, 2)
			cat_lbl.text = cat
			vb.add_child(cat_lbl)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.add_child(row)
		var lbl := Label.new()
		StencilStyle.apply_body(lbl, 20, StencilStyle.TEXT, 2)
		lbl.text = InputBindings.label_for(action)
		lbl.custom_minimum_size = Vector2(280, 0)
		row.add_child(lbl)
		var kb_btn := _bind_button(action, "kb")
		row.add_child(kb_btn)
		var pad_btn := _bind_button(action, "pad")
		row.add_child(pad_btn)
		_rows[action] = {"kb": kb_btn, "pad": pad_btn}

	# Look: analog, not rebindable — informational row so the screen
	# honestly covers every input, not just the InputMap ones.
	var look_row := HBoxContainer.new()
	look_row.add_theme_constant_override("separation", 12)
	vb.add_child(look_row)
	var look_lbl := Label.new()
	StencilStyle.apply_body(look_lbl, 20, StencilStyle.TEXT_DIM, 2)
	look_lbl.text = "Look (analog)"
	look_lbl.custom_minimum_size = Vector2(280, 0)
	look_row.add_child(look_lbl)
	var look_mouse := Label.new()
	StencilStyle.apply_body(look_mouse, 20, StencilStyle.TEXT_DIM, 2)
	look_mouse.text = "Mouse"
	look_mouse.custom_minimum_size = Vector2(220, 0)
	look_mouse.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	look_row.add_child(look_mouse)
	var look_pad := Label.new()
	StencilStyle.apply_body(look_pad, 20, StencilStyle.TEXT_DIM, 2)
	look_pad.text = "Right Stick (fixed)"
	look_pad.custom_minimum_size = Vector2(220, 0)
	look_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	look_row.add_child(look_pad)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(btn_row)
	var reset := Button.new()
	reset.text = "RESET TO DEFAULTS"
	reset.custom_minimum_size = Vector2(280, 56)
	StencilStyle.style_button(reset)
	reset.add_theme_font_size_override("font_size", 20)
	reset.pressed.connect(_on_reset)
	btn_row.add_child(reset)
	var back := Button.new()
	back.name = "BackButton"
	back.text = "BACK"
	back.custom_minimum_size = Vector2(200, 56)
	StencilStyle.style_button(back)
	back.add_theme_font_size_override("font_size", 20)
	back.pressed.connect(close)
	btn_row.add_child(back)


func _bind_button(action: String, kind: String) -> Button:
	var b := Button.new()
	b.name = "Bind_%s_%s" % [action, kind]
	b.text = InputBindings.binding_label(action, kind)
	b.custom_minimum_size = Vector2(220, 48)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_button(b)
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(_on_bind_pressed.bind(action, kind))
	return b


func _on_bind_pressed(action: String, kind: String) -> void:
	_capturing_action = action
	_capturing_kind = kind
	if _capture_label != null:
		_capture_label.text = "PRESS %s FOR %s — Esc to cancel" % [
			"ANY KEY / MOUSE BUTTON" if kind == "kb" else "ANY BUTTON / STICK / TRIGGER",
			InputBindings.label_for(action).to_upper()]
	if _warn_label != null:
		_warn_label.text = ""
	_click()


func _input(event: InputEvent) -> void:
	if _capturing_action.is_empty():
		# Back out with Esc / B (gamepad) when not capturing.
		if event.is_action_pressed("ui_cancel"):
			close()
			get_viewport().set_input_as_handled()
		return
	# Capturing: Esc cancels (Esc itself is never a bindable gameplay key
	# here — it is Pause / Menu Back, and binding it away would trap the
	# player). Every other first press binds.
	if event is InputEventKey and (event as InputEventKey).keycode == KEY_ESCAPE and event.is_pressed():
		_cancel_capture()
		get_viewport().set_input_as_handled()
		return
	if not event.is_pressed() or (event is InputEventKey and (event as InputEventKey).echo):
		return
	var dict := {}
	if _capturing_kind == "kb":
		if event is InputEventKey or event is InputEventMouseButton:
			dict = InputBindings.event_to_dict(event)
	elif _capturing_kind == "pad":
		if event is InputEventJoypadButton:
			dict = InputBindings.event_to_dict(event)
		elif event is InputEventJoypadMotion:
			# Stick / trigger: only a deliberate deflection counts.
			if absf((event as InputEventJoypadMotion).axis_value) < 0.7:
				return
			dict = InputBindings.event_to_dict(event)
			# Capture the direction, not the exact deflection.
			dict["axis_value"] = 1.0 if float(dict.get("axis_value", 0.0)) > 0.0 else -1.0
	if dict.is_empty():
		return
	var res: Dictionary = InputBindings.set_binding(_capturing_action, _capturing_kind, dict)
	_capturing_action = ""
	_capturing_kind = ""
	if _capture_label != null:
		_capture_label.text = ""
	if _warn_label != null:
		var replaced: Array = res.get("replaced", [])
		if not replaced.is_empty():
			_warn_label.text = "Replaced binding on: %s — rebind them if needed." % ", ".join(replaced)
		else:
			_warn_label.text = ""
	_refresh_all()
	_click()
	get_viewport().set_input_as_handled()


func _cancel_capture() -> void:
	_capturing_action = ""
	_capturing_kind = ""
	if _capture_label != null:
		_capture_label.text = ""


func _on_deadzone_changed(v: float) -> void:
	InputBindings.set_deadzone(v)
	if _deadzone_label != null:
		_deadzone_label.text = "%.2f" % v


func _on_reset() -> void:
	InputBindings.reset_to_defaults()
	if _warn_label != null:
		_warn_label.text = "Bindings reset to defaults."
	_refresh_all()
	_click()


func _refresh_all() -> void:
	for action in _rows.keys():
		var rec: Dictionary = _rows[action]
		(rec["kb"] as Button).text = InputBindings.binding_label(action, "kb")
		(rec["pad"] as Button).text = InputBindings.binding_label(action, "pad")


func close() -> void:
	closed.emit()
	queue_free()


func _click() -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d("ui_click")
