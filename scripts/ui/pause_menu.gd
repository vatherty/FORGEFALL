# scripts/ui/pause_menu.gd
# FORGEFALL — pause menu (Worker 6: HUD/UI).
# RESUME / RESTART RUN / quick OPTIONS / QUIT TO MENU. Pauses the tree while
# open (root runs PROCESS_MODE_ALWAYS so buttons stay alive). Toggle with
# ui_cancel (Esc) or the HUD's pause button; other workers can call
# toggle_pause() via group "pause_menu".
extends Control

var _options_box: VBoxContainer
var _sens: HSlider
var _master: HSlider
var _resume_button: Button


func _ready() -> void:
	add_to_group("pause_menu")
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = true
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.015, 0.025, 0.035, 0.95)
	add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 32)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var buttons := VBoxContainer.new()
	buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.size_flags_vertical = Control.SIZE_EXPAND_FILL
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	scroll.add_child(buttons)
	var title := Label.new()
	title.text = "PAUSED"
	title.add_theme_font_override("font", preload("res://assets/ui/fonts/BarlowCondensed-Bold.ttf"))
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", StencilStyle.ORANGE)
	buttons.add_child(title)
	var sub := Label.new()
	sub.text = "CATCH YOUR BREATH, OPERATOR"
	sub.add_theme_color_override("font_color", StencilStyle.TEXT_DIM)
	buttons.add_child(sub)
	_resume_button = _menu_button("RESUME")
	_resume_button.pressed.connect(toggle_pause)
	buttons.add_child(_resume_button)
	var restart := _menu_button("RESTART RUN")
	restart.pressed.connect(_on_restart)
	buttons.add_child(restart)
	var options := _menu_button("SETTINGS")
	options.pressed.connect(_on_options)
	buttons.add_child(options)
	var quit := _menu_button("QUIT TO MENU")
	quit.pressed.connect(_on_quit_to_menu)
	buttons.add_child(quit)
	_options_box = VBoxContainer.new()
	_options_box.visible = false
	_options_box.add_theme_constant_override("separation", 8)
	buttons.add_child(_options_box)
	_sens = _slider_row("SENSITIVITY", 0.5, 3.0, 0.05, _read_setting("sensitivity", 1.0))
	_master = _slider_row("MASTER VOL", 0.0, 1.0, 0.01, _read_setting("master_vol", 0.9))
	_master.value_changed.connect(_on_master_vol)
	var controls := _menu_button("CONTROLS...")
	controls.pressed.connect(_on_controls)
	_options_box.add_child(controls)
	_resume_button.grab_focus()


func _menu_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_button(b)
	b.add_theme_font_override("font", preload("res://assets/ui/fonts/BarlowCondensed-Bold.ttf"))
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_stylebox_override("focus", StencilStyle.panel(Color(0, 0, 0, 0), StencilStyle.ORANGE, 2))
	return b


func _slider_row(label_text: String, mn: float, mx: float, step: float, val: float) -> HSlider:
	var row := HBoxContainer.new()
	_options_box.add_child(row)
	var l := Label.new()
	StencilStyle.apply_body(l, 18, StencilStyle.TEXT, 2)
	l.text = label_text
	l.custom_minimum_size = Vector2(160, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(170, 28)
	StencilStyle.style_slider(s)
	row.add_child(s)
	return s


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# The rebind screen owns the press while open (its own B/Esc
		# closes it); otherwise B would close the rebind screen AND
		# resume the game on the same press.
		if get_node_or_null("RebindMenu") != null:
			return
		toggle_pause()
		get_viewport().set_input_as_handled()


func toggle_pause() -> void:
	var main := get_tree().get_first_node_in_group("game_root")
	if main != null and main.has_method("resume"):
		main.resume()
	else:
		get_tree().paused = not get_tree().paused
		visible = get_tree().paused
		if visible:
			_resume_button.grab_focus()


func _on_restart() -> void:
	_click()
	get_tree().paused = false
	var g := get_node_or_null("/root/Game")
	if g != null and g.has_method("reset_run"):
		g.reset_run()
	get_tree().reload_current_scene()


func _on_options() -> void:
	_click()
	_options_box.visible = not _options_box.visible


func _on_controls() -> void:
	_click()
	var menu := RebindMenu.open_in(self)
	if menu.has_signal("closed"):
		menu.connect("closed", _on_rebind_closed)


func _on_rebind_closed() -> void:
	# Back from CONTROLS: focus returns to the pause menu.
	if _resume_button != null and visible:
		_resume_button.grab_focus()


func _on_quit_to_menu() -> void:
	_click()
	get_tree().paused = false
	var main := get_tree().get_first_node_in_group("game_root")
	if main != null and main.has_method("quit_to_menu"):
		main.quit_to_menu()
	else:
		get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_master_vol(v: float) -> void:
	var mi := AudioServer.get_bus_index("Master")
	if mi >= 0:
		AudioServer.set_bus_volume_db(mi, linear_to_db(maxf(0.001, v)))


func _read_setting(key: String, fallback: float) -> float:
	var cfg := ConfigFile.new()
	if cfg.load("user://forge_settings.cfg") != OK:
		return fallback
	return float(cfg.get_value("ui", key, fallback))


func _click() -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d("ui_click")
