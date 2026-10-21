# One settings screen shared by the main menu and paused gameplay.
extends CanvasLayer

signal closed
var _panel: PanelContainer
var _title: Label
var _body: VBoxContainer
var _key: LineEdit
var _status: Label
var _controls: Dictionary = {}
var _key_saved := false
var _key_state: Label
var _reset_armed := false

static func open_in(parent: Node) -> Node:
	var existing := parent.get_node_or_null("SettingsMenu")
	if existing != null:
		return existing
	var menu: Node = load("res://scripts/ui/settings_menu.gd").new()
	menu.name = "SettingsMenu"
	parent.add_child(menu)
	return menu

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	MouseCapture.set_menu()
	var panel := PanelContainer.new()
	_panel = panel
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("15191f")
	style.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	StencilStyle.install_menu(panel)
	panel.theme = panel.theme.duplicate()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var title := Label.new()
	_title = title
	title.text = "SETTINGS"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 30)
	header.add_child(title)
	var back := _button(header, "BACK", _close)
	back.grab_focus.call_deferred()
	var tabs := TabContainer.new()
	tabs.name = "SettingsTabs"
	tabs.clip_tabs = true
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(tabs)
	for category in ["CONTROLS", "AUDIO", "DISPLAY", "MOBILE", "FORGE AI"]:
		var scroll := ScrollContainer.new()
		scroll.name = category
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		tabs.add_child(scroll)
		_body = VBoxContainer.new()
		_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_body.add_theme_constant_override("separation", 18)
		scroll.add_child(_body)
		match category:
			"CONTROLS":
				_slider("Look sensitivity", "sensitivity", 0.2, 3.0, 0.05)
				_slider("ADS sensitivity multiplier", "ads_sensitivity", 0.1, 1.0, 0.05)
				_toggle("Invert vertical aim", "invert_y")
				_button(_body, "KEYBOARD / CONTROLLER BINDINGS", func(): RebindMenu.open_in(self))
			"AUDIO":
				for pair in [["Master volume", "master_vol"], ["Music / ambience", "music_vol"], ["Sound effects", "sfx_vol"], ["Menu sounds", "ui_vol"]]:
					_slider(pair[0], pair[1], 0, 1, 0.01)
			"DISPLAY":
				_slider("Field of view", "fov", 65, 110, 1)
				var quality := OptionButton.new()
				for label in ["LOW · 70% resolution", "MEDIUM · 85% resolution", "HIGH · 100% resolution"]:
					quality.add_item(label)
				quality.selected = int(Preferences.values.quality)
				quality.custom_minimum_size.y = 52
				_body.add_child(quality)
				_controls.quality = quality
				quality.item_selected.connect(func(index: int): _save("quality", index))
				_toggle("Vertical sync", "vsync", OS.has_feature("web"))
				_toggle("Fullscreen", "fullscreen", OS.has_feature("web"))
				_note("In browsers, use your browser's fullscreen and display controls." if OS.has_feature("web") else "Display changes apply immediately.")
			"MOBILE":
				_slider("Touch look sensitivity", "touch_sensitivity", 0.2, 3, 0.05)
				_slider("Action button opacity", "touch_opacity", 0.3, 1, 0.05)
				_toggle("Vibration (supported devices)", "haptics")
				_note("Drag FIRE to aim while shooting. ADS toggles aim. USE becomes PLACE when previewing a structure.")
			"FORGE AI":
				_build_ai()
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_button(column, "RESET GAME SETTINGS", _reset)
	get_viewport().size_changed.connect(_layout)
	_layout.call_deferred()

func _note(message: String) -> Label:
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(label)
	return label

func _slider(label: String, key: String, minimum: float, maximum: float, step: float) -> void:
	var value := Label.new()
	_body.add_child(value)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = float(Preferences.values[key])
	slider.custom_minimum_size.y = 48
	_body.add_child(slider)
	_controls[key] = slider
	var update := func(number: float): value.text = "%s: %.2f" % [label, number]
	update.call(slider.value)
	slider.value_changed.connect(func(number: float): update.call(number); _save(key, number))

func _toggle(label: String, key: String, disabled := false) -> void:
	var toggle := CheckButton.new()
	toggle.text = label
	toggle.button_pressed = bool(Preferences.values[key])
	toggle.custom_minimum_size.y = 52
	toggle.disabled = disabled
	_body.add_child(toggle)
	_controls[key] = toggle
	toggle.toggled.connect(func(value: bool): _save(key, value))

func _button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 52
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _save(key: String, value: Variant) -> void:
	var result := Preferences.change(key, value)
	if _status != null:
		_status.text = "Settings saved" if result == OK else "Applied for this session; settings could not be saved."

func _build_ai() -> void:
	_note("DEEPSEEK API KEY\nOne key enables online Forge prompts and AI mod creation. Forge's offline presets work without a key.")
	_key = LineEdit.new()
	_key.name = "DeepSeekKey"
	_key.secret = true
	_key.placeholder_text = "Paste your DeepSeek API key"
	_key.custom_minimum_size.y = 56
	_body.add_child(_key)
	_key_saved = not ForgeConfig.load_key().is_empty()
	_key_state = _note("Saved key available on this device." if _key_saved else "No key saved on this device.")
	var reveal := CheckButton.new()
	reveal.text = "Show entered key"
	reveal.custom_minimum_size.y = 52
	reveal.toggled.connect(func(show: bool): _key.secret = not show)
	_body.add_child(reveal)
	_button(_body, "SAVE KEY", _save_key)
	_button(_body, "REMOVE SAVED KEY", _remove_key)
	_note("The key is saved on this device/browser and sent to api.deepseek.com for AI requests. It is not encrypted; avoid shared devices. Browser storage can be cleared. DeepSeek usage may incur charges. Saving a key does not verify it with DeepSeek.")

func _save_key() -> void:
	var value := _key.text.strip_edges()
	if value.is_empty() or value.contains(" ") or value.contains("\n"):
		_status.text = "Paste a non-empty key without spaces."
		return
	if ForgeConfig.save_key(value) != OK:
		_status.text = "Could not save the key."
		return
	_key.clear()
	_key_state.text = "Saved key available on this device."
	_status.text = "Key saved. Forge and mod creation use it on the next AI request."

func _remove_key() -> void:
	if ForgeConfig.save_key("") != OK:
		_status.text = "Could not remove the saved key."
		return
	_key.clear()
	_key_state.text = "No key saved on this device."
	_status.text = "Key removed. Online mod creation needs a key; offline Forge remains available."

func _reset() -> void:
	if not _reset_armed:
		_reset_armed = true
		_status.text = "Press RESET GAME SETTINGS again to confirm. Your API key and bindings will be kept."
		return
	var result := Preferences.reset()
	for key in _controls:
		var control: Control = _controls[key]
		if control is Range:
			control.value = float(Preferences.values[key])
		elif control is CheckButton:
			control.set_pressed_no_signal(bool(Preferences.values[key]))
		elif control is OptionButton:
			control.selected = int(Preferences.values[key])
	_reset_armed = false
	_status.text = "Game settings reset." if result == OK else "Reset applied, but could not save settings."

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and get_node_or_null("RebindMenu") == null:
		get_viewport().set_input_as_handled()
		_close()

func _close() -> void:
	_key.clear()
	closed.emit()
	queue_free()


func _layout() -> void:
	# Compensate for the project's 1280-wide stretch canvas on phones.
	var scale := get_viewport().get_screen_transform().get_scale()
	var factor := 1.0 / clampf(minf(scale.x, scale.y), 0.35, 1.0)
	for type in ["Label", "LineEdit", "CheckButton", "PopupMenu"]:
		_panel.theme.set_font_size("font_size", type, int(18 * factor))
	for type in ["Button", "OptionButton", "TabBar", "TabContainer"]:
		_panel.theme.set_font_size("font_size", type, int(22 * factor))
	_title.add_theme_font_size_override("font_size", int(30 * factor))
	for button in _panel.find_children("*", "BaseButton", true, false):
		button.custom_minimum_size.y = 52 * factor
	for slider in _panel.find_children("*", "HSlider", true, false):
		slider.custom_minimum_size.y = 48 * factor
	_key.custom_minimum_size.y = 56 * factor
