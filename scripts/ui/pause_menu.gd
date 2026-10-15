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


func _ready() -> void:
	add_to_group("pause_menu")
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	add_child(dim)

	var title := Label.new()
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.offset_left = -400
	title.offset_right = 400
	title.offset_top = 120
	title.offset_bottom = 200
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text = "PAUSED"
	StencilStyle.apply_title(title, 72, StencilStyle.TEXT, 8)
	add_child(title)

	var sub := Label.new()
	sub.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sub.offset_left = -400
	sub.offset_right = 400
	sub.offset_top = 205
	sub.offset_bottom = 240
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_body(sub, 20, StencilStyle.ORANGE, 4)
	sub.text = "CATCH YOUR BREATH, OPERATOR"
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sub)

	var buttons := VBoxContainer.new()
	buttons.set_anchors_preset(Control.PRESET_CENTER)
	buttons.offset_left = -170
	buttons.offset_right = 170
	buttons.offset_top = -80
	buttons.offset_bottom = 200
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	add_child(buttons)

	var resume := _menu_button("RESUME")
	resume.pressed.connect(toggle_pause)
	buttons.add_child(resume)
	var restart := _menu_button("RESTART RUN")
	restart.pressed.connect(_on_restart)
	buttons.add_child(restart)
	var options := _menu_button("OPTIONS")
	options.pressed.connect(_on_options)
	buttons.add_child(options)
	var quit := _menu_button("QUIT TO MENU")
	quit.pressed.connect(_on_quit_to_menu)
	buttons.add_child(quit)

	# Quick options: sensitivity + master volume, collapsed by default.
	_options_box = VBoxContainer.new()
	_options_box.visible = false
	_options_box.add_theme_constant_override("separation", 8)
	buttons.add_child(_options_box)
	_sens = _slider_row("SENSITIVITY", 0.5, 3.0, 0.05, _read_setting("sensitivity", 1.0))
	_master = _slider_row("MASTER VOL", 0.0, 1.0, 0.01, _read_setting("master_vol", 0.9))
	_master.value_changed.connect(_on_master_vol)


func _menu_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(340, 60)
	StencilStyle.style_button(b)
	b.add_theme_font_size_override("font_size", 24)
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
		toggle_pause()
		get_viewport().set_input_as_handled()


func toggle_pause() -> void:
	if get_tree().paused:
		get_tree().paused = false
		visible = false
	else:
		get_tree().paused = true
		visible = true


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


func _on_quit_to_menu() -> void:
	_click()
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


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
