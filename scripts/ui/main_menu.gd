# FORGEFALL menus: industrial home, mode cards, and mission deployment.
# Containers own all sizing; short/narrow screens scroll instead of overlapping.
extends Control

const SETTINGS_PATH := "user://forge_settings.cfg"

var _options_dim: ColorRect
var _options_panel: PanelContainer
var _options_vb: VBoxContainer
var _sens: HSlider
var _sens_val: Label
var _master: HSlider
var _music: HSlider
var _gyro: CheckButton
var _quality: OptionButton
var _update_status: Label
var _map_select: OptionButton
const MAP_KEYS := ["dustline", "foundry", "outpost", "cinder_city", "tower_defense", "factory"]
# Goal 6 PROGRESSION (Worker B): persistent loadout picker overlay scene.
const LOADOUT_PICKER_SCENE := "res://scenes/ui/loadout_picker.tscn"
# Mode-select overlay (Gameplay Rework): one overlay reused for the
# SP and MP selects; rows are rebuilt on every open from the registry.
var _mode_overlay: PanelContainer
var _mode_overlay_scope: String = "sp"
var _mode_overlay_rows: VBoxContainer
var _mode_status_label: Label
# TD pre-run setup overlay (TD worker's TowerDefenseSetup) + its BACK
# button (the setup itself has no cancel path; this button is the
# menu's, added on top of the setup so the player can back out).
var _td_setup: Control = null
var _td_setup_back: Button = null
# Menu-stack layout refs (see _layout_stack).
var _scroll: ScrollContainer
var _stack: VBoxContainer
var _title_label: Label
var _menu_buttons: Array[Button] = []
var _title_fall: Label
var _selected_mode := "tdm"
var _deploy_panel: PanelContainer
var _deploy_columns: GridContainer
var _deploy_title: Label
var _deploy_desc: Label
var _deploy_loadout: Button
var _deploy_tool: OptionButton
var _deploy_status: Label
var _deploy_mode: OptionButton
var _deploy_preview_label: Label
var _deploy_preview: TextureRect
const DEPLOY_TOOLS := ["grapple", "jetpack", "portal", "none"]


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_stack()


## Sizes the menu stack to at least the viewport so the EXPAND spacers
## center the menu and pin the footer; if content is taller, the stack
## grows to content height and the ScrollContainer scrolls. Also rescales
## the title + button heights to the viewport so the stack fits short
## screens (Deck 1280x800) without scrolling.
func _layout_stack() -> void:
	if _title_label == null:
		return
	var title_size := clampi(int(size.x * 0.065), 48, 88)
	_title_label.add_theme_font_size_override("font_size", title_size)
	_title_fall.add_theme_font_size_override("font_size", title_size)
	_size_options_panel()
	if _mode_overlay_rows != null and _mode_overlay_rows.get_child_count() > 0:
		var grid := _mode_overlay_rows.get_child(0) as GridContainer
		if grid != null:
			grid.columns = 1
	if _deploy_columns != null:
		_deploy_columns.columns = 1
		_deploy_columns.custom_minimum_size.x = minf(470, maxf(300, size.x - 96))
		_deploy_desc.custom_minimum_size.x = minf(470, maxf(300, size.x - 96))


func _ready() -> void:
	StencilStyle.install_menu(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	InputBindings.ensure_loaded()
	TowerDefenseSetup.load_selection()
	_build()
	_load_settings()
	_hook_updater()
	# Controller: menus need an initial focus owner or D-pad nav has
	# nowhere to move FROM (Godot focus starts on nothing). Single
	# Player is the first entry.
	if not _menu_buttons.is_empty():
		_menu_buttons[0].grab_focus()


func _hook_updater() -> void:
	var updater := _active_updater()
	if updater == null:
		return
	if updater.has_signal("notice"):
		updater.connect("notice", _on_updater_notice)
	# Updater.State.DISABLED == 0: no update URL configured on this build.
	if int(updater.get("state")) == 0 and _update_status != null:
		_update_status.text = "updates not configured on this build"


## On Windows/Linux the PC updater owns updates (see UpdaterPC); the
## Android manager is handed off to DISABLED at boot on those platforms,
## so routing manual checks to it would do nothing. Everywhere else
## (Android) the Android manager is the active one.
func _active_updater() -> Node:
	if OS.has_feature("web"):
		return null  # WEB PORT: no update channel in a browser build.
	if OS.get_name() == "Windows" or OS.get_name() == "Linux":
		var pc := get_node_or_null("/root/UpdaterPC")
		if pc != null:
			return pc
	return get_node_or_null("/root/Updater")


func _on_updater_notice(msg: String) -> void:
	if _update_status != null and is_instance_valid(_update_status):
		_update_status.text = msg


func _on_check_updates() -> void:
	_click()
	var updater := _active_updater()
	if updater != null and updater.has_method("check_for_updates"):
		updater.call("check_for_updates", true)
	elif _update_status != null:
		_update_status.text = "updater missing on this build"


func _build() -> void:
	var art := _art()
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(art)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.02, 0.03, 0.04, 0.25)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	_scroll = ScrollContainer.new()
	_scroll.name = "MenuScroll"
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	var margin := MarginContainer.new()
	margin.name = "MainMargin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 36)
	_scroll.add_child(margin)
	_stack = VBoxContainer.new()
	_stack.name = "MenuStack"
	_stack.add_theme_constant_override("separation", 10)
	margin.add_child(_stack)
	_stack.add_child(_label("■   FORGE INDUSTRIAL  /  PROVING GROUND", 14, StencilStyle.ORANGE))
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 0)
	_stack.add_child(title_row)
	_title_label = _label("FORGE", 72)
	_title_label.name = "Title"
	title_row.add_child(_title_label)
	_title_fall = _label("FALL", 72, StencilStyle.ORANGE)
	title_row.add_child(_title_fall)
	var tagline := _label("BUILD. FIGHT. SURVIVE.", 15, Color(0.75, 0.78, 0.8))
	tagline.name = "Tagline"
	_stack.add_child(tagline)
	var gap := Control.new()
	gap.custom_minimum_size.y = 16
	_stack.add_child(gap)
	var entries := [
		["SinglePlayerButton", "▸   PLAY", _on_single_player],
		["MultiplayerButton", "⇄   MULTIPLAYER", _on_multiplayer],
		["LoadoutButton", "▣   LOADOUTS", _on_loadouts],
		["CreateAModButton", "+   CREATE A MOD", _on_create_mod],
		["PuzzlesButton", "◇   PUZZLE CHAMBERS", _on_puzzles],
		["StatsButton", "≡   STATS", _on_stats],
		["OptionsButton", "⚙   SETTINGS", _on_options],
		["QuitButton", "↳   QUIT", _on_quit],
	]
	for entry in entries:
		var b := _menu_button(entry[1])
		b.name = entry[0]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.pressed.connect(entry[2])
		if _menu_buttons.is_empty():
			_paint_button(b, StencilStyle.ORANGE, true)
		_stack.add_child(b)
		_menu_buttons.append(b)
	# WEB PORT (2026-10-19): browsers cannot do ENet networking. The
	# MULTIPLAYER entry is disabled outright with a visible note instead of
	# letting the player reach a screen that fails obscurely. (_open_mode_select
	# with scope "mp" is only reachable through this button, so this gate is complete.)
	if OS.has_feature("web"):
		for b in _menu_buttons:
			if b is Button and b.name == "MultiplayerButton":
				b.disabled = true
				b.text = "⇄   MULTIPLAYER (APP VERSION ONLY)"
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack.add_child(spacer)
	var footer := _label("A  SELECT     B  BACK     /     FORGEFALL", 14, Color(0.7, 0.74, 0.77))
	footer.name = "Footer"
	_stack.add_child(footer)
	_build_options()
	_build_mode_overlay()
	_build_deploy()
	_layout_stack()


func _label(text: String, px: int = 20, color: Color = StencilStyle.TEXT) -> Label:
	var l := Label.new()
	l.text = text
	if px >= 22:
		l.add_theme_font_override("font", preload("res://assets/ui/fonts/BarlowCondensed-Bold.ttf"))
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _art() -> TextureRect:
	var t := TextureRect.new()
	t.texture = preload("res://assets/ui/industrial_backdrop.png")
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


func _paint_button(b: Button, accent: Color = StencilStyle.ORANGE, solid: bool = false) -> void:
	var normal := StencilStyle.panel(accent if solid else Color(0.055, 0.07, 0.085, 0.96), Color(0.25, 0.3, 0.34), 0)
	var hover := StencilStyle.panel(accent, accent, 2)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	var focus := StencilStyle.panel(Color(0, 0, 0, 0), accent, 3)
	b.add_theme_stylebox_override("focus", focus)
	b.add_theme_color_override("font_hover_color", Color(0.03, 0.05, 0.07))
	b.add_theme_color_override("font_color", Color(0.03, 0.05, 0.07) if solid else StencilStyle.TEXT)
	b.add_theme_color_override("font_focus_color", StencilStyle.TEXT)


func _screen(name_: String, color: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = name_
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := StencilStyle.panel(Color.TRANSPARENT, Color.TRANSPARENT, 0)
	style.content_margin_left = 48
	style.content_margin_right = 48
	style.content_margin_top = 48
	style.content_margin_bottom = 32
	panel.add_theme_stylebox_override("panel", style)
	panel.visible = false
	add_child(panel)
	StencilStyle.cinematic_background(panel)
	return panel


func _menu_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(340, 52)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	StencilStyle.style_button(b)
	b.add_theme_font_override("font", preload("res://assets/ui/fonts/BarlowCondensed-Bold.ttf"))
	b.add_theme_font_size_override("font_size", 24)
	_paint_button(b)
	return b


func _size_options_panel() -> void:
	if _options_panel == null:
		return
	_options_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _options_vb != null:
		_options_vb.custom_minimum_size = Vector2(0, maxf(0, size.y - 96))
		for row in _options_vb.find_children("*", "HBoxContainer", true, false):
			if row.has_meta("settings_row"):
				row.custom_minimum_size.x = minf(580, maxf(300, size.x - 96))


func _build_options() -> void:
	_options_dim = ColorRect.new()
	_options_dim.name = "OptionsDim"
	_options_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_options_dim.color = Color(0, 0, 0, 0.0)
	_options_dim.visible = false
	add_child(_options_dim)
	_options_panel = PanelContainer.new()
	_options_panel.name = "OptionsPanel"
	_options_panel.visibility_changed.connect(func() -> void: _options_dim.visible = _options_panel.visible)
	_options_panel.set_anchors_preset(Control.PRESET_CENTER)
	var options_style := StencilStyle.panel(Color.TRANSPARENT, Color.TRANSPARENT, 0)
	options_style.content_margin_left = 48
	options_style.content_margin_right = 48
	options_style.content_margin_top = 48
	options_style.content_margin_bottom = 32
	_options_panel.add_theme_stylebox_override("panel", options_style)
	_options_panel.visible = false
	add_child(_options_panel)
	StencilStyle.cinematic_background(_options_panel, "armory")
	var opt_scroll := ScrollContainer.new()
	opt_scroll.name = "OptionsScroll"
	opt_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_options_panel.add_child(opt_scroll)
	var vb := VBoxContainer.new()
	vb.name = "OptionsStack"
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.alignment = BoxContainer.ALIGNMENT_BEGIN
	vb.add_theme_constant_override("separation", 20)
	opt_scroll.add_child(vb)
	_options_vb = vb

	var head := Label.new()
	StencilStyle.apply_title(head, 48, StencilStyle.TEXT, 0)
	head.text = "SETTINGS"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vb.add_child(head)


	_sens = _slider_row(vb, "SENSITIVITY", 0.5, 3.0, 0.05, 1.0)
	_sens.value_changed.connect(func(_v: float) -> void: _save_settings())
	_master = _slider_row(vb, "MASTER VOL", 0.0, 1.0, 0.01, 0.9)
	_master.value_changed.connect(func(_v: float) -> void: _apply_volumes(); _save_settings())
	_music = _slider_row(vb, "MUSIC VOL", 0.0, 1.0, 0.01, 0.7)
	_music.value_changed.connect(func(_v: float) -> void: _apply_volumes(); _save_settings())

	var gyro_row := HBoxContainer.new()
	gyro_row.set_meta("settings_row", true)
	gyro_row.custom_minimum_size.x = 580
	gyro_row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	vb.add_child(gyro_row)
	var gl := Label.new()
	StencilStyle.apply_body(gl, 20, StencilStyle.TEXT, 2)
	gl.text = "GYRO AIM"
	gl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gyro_row.add_child(gl)
	_gyro = CheckButton.new()
	_gyro.disabled = true  # STRETCH: gyro aim not wired (android worker owns input)
	_gyro.tooltip_text = "STRETCH — gyro aim not wired yet"
	gyro_row.add_child(_gyro)

	var q_row := HBoxContainer.new()
	q_row.set_meta("settings_row", true)
	q_row.custom_minimum_size.x = 580
	q_row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	vb.add_child(q_row)
	var ql := Label.new()
	StencilStyle.apply_body(ql, 20, StencilStyle.TEXT, 2)
	ql.text = "QUALITY"
	ql.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	q_row.add_child(ql)
	_quality = OptionButton.new()
	_quality.add_item("LOW", 0)
	_quality.add_item("MEDIUM", 1)
	_quality.add_item("HIGH", 2)
	_quality.selected = 2
	StencilStyle.style_button(_quality)
	_quality.item_selected.connect(_on_quality)
	q_row.add_child(_quality)

	var upd_head := Label.new()
	StencilStyle.apply_body(upd_head, 20, StencilStyle.ORANGE, 2)
	upd_head.text = "GAME UPDATES"
	upd_head.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vb.add_child(upd_head)

	var upd_row := HBoxContainer.new()
	upd_row.set_meta("settings_row", true)
	upd_row.custom_minimum_size.x = 580
	upd_row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	upd_row.add_theme_constant_override("separation", 12)
	vb.add_child(upd_row)
	var ub := Button.new()
	ub.text = "CHECK FOR UPDATES"
	ub.custom_minimum_size = Vector2(300, 54)
	StencilStyle.style_button(ub)
	ub.add_theme_font_size_override("font_size", 20)
	ub.pressed.connect(_on_check_updates)
	upd_row.add_child(ub)
	_update_status = Label.new()
	StencilStyle.apply_body(_update_status, 18, StencilStyle.TEXT_DIM, 2)
	_update_status.text = "update check ready"
	_update_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_update_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_update_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	upd_row.add_child(_update_status)
	# WEB PORT (2026-10-19): no update channel in browsers — hide the row
	# entirely instead of showing a dead button. (The Android Updater is also
	# parked in DISABLED by UpdaterPC on web.)
	upd_row.visible = not OS.has_feature("web")

	# CONTROLS: full keyboard + gamepad remapping (v0.6.1). Opens the
	# RebindMenu overlay; BACK returns here.
	var controls := _menu_button("CONTROLS...")
	controls.custom_minimum_size = Vector2(280, 54)
	controls.pressed.connect(_on_controls)
	var cc := HBoxContainer.new()
	cc.add_child(controls)
	vb.add_child(cc)

	var back := _menu_button("BACK")
	back.custom_minimum_size = Vector2(200, 54)
	back.pressed.connect(func() -> void: _options_panel.visible = false; _focus_menu_button("OptionsButton"))
	var bc := HBoxContainer.new()
	bc.add_child(back)
	vb.add_child(bc)
	StencilStyle.navigation_button(back)
	back.text = "‹  BACK"
	var tabs := TabContainer.new()
	tabs.name = "SettingsTabs"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(tabs)
	vb.move_child(tabs, 1)
	var audio := VBoxContainer.new()
	audio.name = "AUDIO"
	audio.add_theme_constant_override("separation", 24)
	tabs.add_child(audio)
	var display := VBoxContainer.new()
	display.name = "DISPLAY"
	display.add_theme_constant_override("separation", 24)
	tabs.add_child(display)
	var input := VBoxContainer.new()
	input.name = "CONTROLS"
	input.add_theme_constant_override("separation", 24)
	tabs.add_child(input)
	_master.get_parent().reparent(audio)
	_music.get_parent().reparent(audio)
	q_row.reparent(display)
	upd_head.reparent(display)
	upd_row.reparent(display)
	_sens.get_parent().reparent(input)
	gyro_row.reparent(input)
	cc.reparent(input)
	vb.move_child(bc, vb.get_child_count() - 1)



func _slider_row(parent: Control, label_text: String, mn: float, mx: float, step: float, val: float) -> HSlider:
	var row := HBoxContainer.new()
	row.set_meta("settings_row", true)
	row.custom_minimum_size.x = 580
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	parent.add_child(row)
	var l := Label.new()
	StencilStyle.apply_body(l, 20, StencilStyle.TEXT, 2)
	l.text = label_text
	l.custom_minimum_size = Vector2(190, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(140, 30)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_slider(s)
	row.add_child(s)
	return s


func _on_map_selected(index: int) -> void:
	_click()
	var main := get_tree().current_scene
	if main != null and main.has_method("set_selected_map"):
		main.set_selected_map(MAP_KEYS[index])
	_save_settings()


## SINGLE PLAYER top entry: opens the SP mode select (Tower Defense
## / TDM / Zombies). Rows route through the GameModeManager registry.
func _on_single_player() -> void:
	_click()
	_open_mode_select("sp")


## MULTIPLAYER top entry: opens the MP mode select (the multiplayer
## versions of the modes). mp_tdm routes to the existing MP menu.
func _on_multiplayer() -> void:
	_click()
	_open_mode_select("mp")


## TD pre-run setup: the traversal-choice overlay (TowerDefenseSetup,
## built in code — no scene). CONFIRM saves the choice and starts the
## run via _on_td_setup_confirmed. The menu-shell worker owns this
## menu's overall shape; this branch is the TD plug-in point.
func _open_td_setup() -> void:
	var existing := get_node_or_null("TDSetup")
	if existing != null and is_instance_valid(existing):
		_td_setup = existing as Control
		if existing.has_method("open"):
			existing.call("open")
	else:
		var setup := TowerDefenseSetup.new()
		setup.name = "TDSetup"
		add_child(setup)
		_td_setup = setup
		if setup.has_signal("setup_confirmed") and not setup.is_connected("setup_confirmed", _on_td_setup_confirmed):
			setup.connect("setup_confirmed", _on_td_setup_confirmed)
		if setup.has_method("open"):
			setup.call("open")
	# BACK: the setup itself has no cancel path. This button is the
	# menu's (added after the setup so it draws on top); it closes the
	# setup and returns to the SP mode select.
	if _td_setup_back == null or not is_instance_valid(_td_setup_back):
		_td_setup_back = Button.new()
		_td_setup_back.name = "TDSetupBackButton"
		_td_setup_back.text = "BACK"
		_td_setup_back.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_td_setup_back.offset_left = 16
		_td_setup_back.offset_top = 16
		_td_setup_back.offset_right = 156
		_td_setup_back.offset_bottom = 72
		StencilStyle.style_button(_td_setup_back)
		_td_setup_back.add_theme_font_size_override("font_size", 22)
		_td_setup_back.pressed.connect(_on_td_setup_back)
		add_child(_td_setup_back)
	_td_setup_back.visible = true


func _on_td_setup_back() -> void:
	_click()
	_close_td_setup()


func _close_td_setup() -> void:
	if _td_setup != null and is_instance_valid(_td_setup):
		_td_setup.queue_free()
	_td_setup = null
	if _td_setup_back != null and is_instance_valid(_td_setup_back):
		_td_setup_back.queue_free()
	_td_setup_back = null


func _on_td_setup_confirmed(_tool: String) -> void:
	var main := get_tree().current_scene
	if main != null and main.has_method("start_sp_mode"):
		# start_sp_mode frees this menu on success. On refusal (map
		# missing) the menu stays: close the setup, keep the select.
		if bool(main.call("start_sp_mode", "tower_defense")):
			return
		_close_td_setup()
		return
	if main != null and main.has_method("start_game"):
		main.start_game()
	else:
		get_tree().change_scene_to_file("res://scenes/main.tscn")


# --- Mode select overlay (Gameplay Rework) --------------------------------
# One overlay for the SP and MP selects. Rows are rebuilt from the
# GameModeManager registry on every open, so a mode that lands later
# (Zombies / MP co-op) flips from NOT AVAILABLE to START with no menu
# change. NOT AVAILABLE entries are disabled, never a crash, never a
# silent fallback into another mode.

func _build_mode_overlay() -> void:
	_mode_overlay = _screen("ModeSelectOverlay", Color("101f2c"))
	var scroll := ScrollContainer.new()
	scroll.name = "ModeSelectScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_mode_overlay.add_child(scroll)
	var root := VBoxContainer.new()
	root.name = "ModeSelectRoot"
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 20)
	scroll.add_child(root)
	root.add_child(_label("FORGEFALL / PLAY", 13, StencilStyle.TEXT_DIM))
	var title := _label("SINGLE PLAYER", 48)
	title.name = "ModeSelectTitle"
	root.add_child(title)
	_mode_overlay_rows = VBoxContainer.new()
	_mode_overlay_rows.name = "ModeRows"
	_mode_overlay_rows.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_mode_overlay_rows.custom_minimum_size.x = 440
	_mode_overlay_rows.add_theme_constant_override("separation", 8)
	root.add_child(_mode_overlay_rows)
	_mode_status_label = _label("Your squad against enemy bots.", 18, StencilStyle.TEXT_DIM)
	_mode_status_label.custom_minimum_size.x = 440
	_mode_status_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_mode_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_mode_status_label)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)
	var actions := HBoxContainer.new()
	root.add_child(actions)
	var back := _menu_button("‹  BACK")
	back.name = "ModeBackButton"
	back.custom_minimum_size.x = 150
	StencilStyle.navigation_button(back)
	back.pressed.connect(_close_mode_select)
	actions.add_child(back)
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(fill)
	var next := _menu_button("CONTINUE  ›")
	next.name = "ModeContinueButton"
	next.custom_minimum_size.x = 220
	StencilStyle.primary_button(next)
	next.pressed.connect(func() -> void: _on_mode_start_pressed(_selected_mode))
	actions.add_child(next)


func _open_mode_select(scope: String) -> void:
	_mode_overlay_scope = scope
	var mp_script := load("res://scripts/net/mp_modes.gd") as GDScript
	if mp_script != null:
		mp_script.call("ensure_registered")
	var title := _mode_overlay.get_node("ModeSelectScroll/ModeSelectRoot/ModeSelectTitle") as Label
	title.text = "SINGLE PLAYER" if scope == "sp" else "MULTIPLAYER"
	_mode_status_label.text = "Your squad against enemy bots."
	_selected_mode = "tdm" if scope == "sp" else "mp_tdm"
	_rebuild_mode_rows()
	_scroll.visible = false
	_mode_overlay.visible = true
	var selected := _mode_overlay_rows.find_child("ModeStart_" + _selected_mode, true, false) as Button
	if selected != null:
		selected.grab_focus()


func _close_mode_select() -> void:
	_click()
	_mode_overlay.visible = false
	_scroll.visible = true
	_focus_menu_button("MultiplayerButton" if _mode_overlay_scope == "mp" else "SinglePlayerButton")


func _rebuild_mode_rows() -> void:
	for child in _mode_overlay_rows.get_children():
		_mode_overlay_rows.remove_child(child)
		child.queue_free()
	var grid := GridContainer.new()
	grid.name = "ModeCards"
	grid.columns = 1
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	_mode_overlay_rows.add_child(grid)
	var mode_ids := GameModeManager.modes_for_scope(_mode_overlay_scope)
	var first := "tdm" if _mode_overlay_scope == "sp" else "mp_tdm"
	if first in mode_ids:
		mode_ids.erase(first)
		mode_ids.push_front(first)
	for mode_id in mode_ids:
		grid.add_child(_build_mode_row(mode_id))


func _select_mode(mode_id: String) -> void:
	_selected_mode = mode_id
	_mode_status_label.text = str(GameModeManager.MODES[mode_id]["desc"])
	_rebuild_mode_rows()
	var selected := _mode_overlay_rows.find_child("ModeStart_" + mode_id, true, false) as Button
	if selected != null:
		selected.grab_focus()


func _build_mode_row(mode_id: String) -> Control:
	var button := Button.new()
	button.name = "ModeStart_" + mode_id
	button.text = str(GameModeManager.MODES[mode_id]["name"])
	button.custom_minimum_size = Vector2(440, 62)
	button.disabled = not GameModeManager.is_implemented(mode_id)
	StencilStyle.navigation_button(button, mode_id == _selected_mode)
	button.pressed.connect(_select_mode.bind(mode_id))
	return button


## One-line summary of the active loadout for the TDM row: name,
## weapons, and the exactly-one traversal tool. Guarded: no Loadouts
## autoload (headless / bare tree) -> a dash, never a crash.
func _tdm_loadout_line() -> String:
	var lo := get_node_or_null("/root/Loadouts")
	if lo == null or not lo.has_method("get_active_loadout"):
		return "LOADOUT: —"
	var entry: Dictionary = lo.call("get_active_loadout")
	if entry.is_empty():
		return "LOADOUT: —"
	var primary := str(entry.get("primary", ""))
	var secondary := str(entry.get("secondary", ""))
	if lo.has_method("get_weapon_display_name"):
		var ptxt := str(lo.call("get_weapon_display_name", primary))
		if not ptxt.is_empty():
			primary = ptxt
		var stxt := str(lo.call("get_weapon_display_name", secondary))
		if not stxt.is_empty():
			secondary = stxt
	var trav := str(entry.get("traversal", "grapple"))
	if lo.has_method("get_traversal_display_name"):
		var ttxt := str(lo.call("get_traversal_display_name", trav))
		if not ttxt.is_empty():
			trav = ttxt
	return "LOADOUT: %s — %s / %s · Traversal: %s" % [str(entry.get("name", "?")), primary, secondary, trav]


func _on_change_loadout_pressed() -> void:
	_click()
	_on_loadouts()


func _launch_mode(mode_id: String) -> void:
	_click()
	if not GameModeManager.is_implemented(mode_id):
		if _mode_status_label != null:
			_mode_status_label.text = "NOT AVAILABLE YET."
		return
	match mode_id:
		"tower_defense":
			_on_td_setup_confirmed(TowerDefenseSetup.get_tool())
		"tdm":
			var main := get_tree().current_scene
			if main != null and main.has_method("start_sp_mode"):
				if bool(main.call("start_sp_mode", "tdm")):
					return
				if _mode_status_label != null:
					_deploy_status.text = "COULD NOT START TDM — SEE LOG."
			elif _mode_status_label != null:
				_deploy_status.text = "COULD NOT START TDM — MAIN MISSING."
		"zombies":
			var main_z := get_tree().current_scene
			if main_z != null and main_z.has_method("start_sp_mode"):
				if bool(main_z.call("start_sp_mode", "zombies")):
					return
				if _mode_status_label != null:
					_deploy_status.text = "COULD NOT START ZOMBIES — SEE LOG."
			elif _mode_status_label != null:
				_deploy_status.text = "COULD NOT START ZOMBIES — MAIN MISSING."
		"mp_tdm":
			var main := get_tree().current_scene
			if main != null and main.has_method("open_multiplayer_menu"):
				main.open_multiplayer_menu("mp_tdm")
		"mp_tower_defense":
			var main_td := get_tree().current_scene
			if main_td != null and main_td.has_method("open_multiplayer_menu"):
				main_td.open_multiplayer_menu("mp_tower_defense")
		"mp_zombies":
			var main_z2 := get_tree().current_scene
			if main_z2 != null and main_z2.has_method("open_multiplayer_menu"):
				main_z2.open_multiplayer_menu("mp_zombies")
		_:
			if _mode_status_label != null:
				_mode_status_label.text = "NOT AVAILABLE YET."


# Goal 5 Worker B: puzzle-room entry (menu wiring for THIS button only).
func _on_puzzles() -> void:
	_click()
	var main := get_tree().current_scene
	if main != null and main.has_method("open_puzzle_select"):
		main.open_puzzle_select()


# Goal 6 PROGRESSION (Worker B): loadout picker entry (menu wiring for
# THIS button only). The picker is a self-contained overlay; closing it
# frees it. Missing scene -> no-op, never a crash.
func _on_loadouts() -> void:
	_click()
	if not ResourceLoader.exists(LOADOUT_PICKER_SCENE):
		return
	var picker: Node = (load(LOADOUT_PICKER_SCENE) as PackedScene).instantiate()
	picker.name = "LoadoutPicker"
	add_child(picker)
	if picker.has_signal("picker_closed"):
		picker.connect("picker_closed", _on_loadout_picker_closed.bind(picker))
	if picker.has_method("open"):
		picker.call("open")


func _on_loadout_picker_closed(picker: Node) -> void:
	if picker != null and is_instance_valid(picker):
		picker.queue_free()
	if _mode_overlay != null and _mode_overlay.visible:
		_rebuild_mode_rows()
	if _deploy_panel.visible:
		_refresh_deploy()


# Goal 6 PROGRESSION (coordinator): stats screen entry (menu wiring for
# THIS button only). The screen is a self-contained overlay.
func _on_stats() -> void:
	_click()
	var main := get_tree().current_scene
	if main != null and main.has_method("open_stats_screen"):
		main.open_stats_screen()


# CREATE A MOD (Forge batch, Worker D): opens the standalone Mod Creator
# menu (a self-contained overlay scene, like the picker). Closing it
# frees it. Missing scene -> no-op, never a crash.
func _on_create_mod() -> void:
	_click()
	if not ResourceLoader.exists("res://scenes/ui/mod_creator_menu.tscn"):
		return
	var menu: Node = (load("res://scenes/ui/mod_creator_menu.tscn") as PackedScene).instantiate()
	menu.name = "ModCreatorMenu"
	add_child(menu)
	if menu.has_signal("creator_closed"):
		menu.connect("creator_closed", _on_creator_menu_closed.bind(menu))


func _on_creator_menu_closed(menu: Node) -> void:
	if menu != null and is_instance_valid(menu):
		menu.queue_free()


func _input(event: InputEvent) -> void:
	if get_node_or_null("SettingsMenu") != null:
		return
	if event.is_action_pressed("ui_cancel"):
		# The rebind screen / an open picker owns the press when open.
		if get_node_or_null("RebindMenu") != null:
			return
		var picker := get_node_or_null("LoadoutPicker")
		if picker != null and picker is Control and (picker as Control).visible and picker.has_method("close"):
			picker.call("close")
			get_viewport().set_input_as_handled()
			return
		if _td_setup != null and is_instance_valid(_td_setup):
			return  # TD setup owns its own BACK button.
		if _deploy_panel != null and _deploy_panel.visible:
			_close_deploy()
			get_viewport().set_input_as_handled()
			return
		if _options_panel != null and _options_panel.visible:
			_options_panel.visible = false
			_focus_menu_button("OptionsButton")
			get_viewport().set_input_as_handled()
			return
		if _mode_overlay != null and _mode_overlay.visible:
			_close_mode_select()
			get_viewport().set_input_as_handled()
			return


func _focus_menu_button(btn_name: String) -> void:
	for b in _menu_buttons:
		if b.name == btn_name:
			b.grab_focus()
			return


func _on_options() -> void:
	_click()
	var menu := preload("res://scripts/ui/settings_menu.gd").open_in(self)
	menu.closed.connect(func(): _focus_menu_button("OptionsButton"), CONNECT_ONE_SHOT)


func _on_controls() -> void:
	_click()
	var menu := RebindMenu.open_in(self)
	if menu.has_signal("closed"):
		menu.connect("closed", _on_rebind_closed)


func _on_rebind_closed() -> void:
	# Back from CONTROLS: focus returns to the Options panel.
	if _options_panel != null and _options_panel.visible:
		InputBindings.grab_first_focus(_options_panel)
	else:
		_focus_menu_button("OptionsButton")


func _on_quit() -> void:
	_click()
	get_tree().quit()


func _on_quality(index: int) -> void:
	_click()
	# Perf scaler (android worker) may override; this is the menu-side default.
	match index:
		0:
			get_viewport().scaling_3d_scale = 0.7
		1:
			get_viewport().scaling_3d_scale = 0.85
		_:
			get_viewport().scaling_3d_scale = 1.0
	_save_settings()


func _apply_volumes() -> void:
	var mi := AudioServer.get_bus_index("Master")
	if mi >= 0:
		AudioServer.set_bus_volume_db(mi, linear_to_db(maxf(0.001, _master.value)))
	var mu := AudioServer.get_bus_index("Music")
	if mu >= 0:
		AudioServer.set_bus_volume_db(mu, linear_to_db(maxf(0.001, _music.value)))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("ui", "map", _map_select.selected if _map_select != null else 0)
	cfg.set_value("game", "mode", GameModeManager.selected_mode)
	cfg.save(SETTINGS_PATH)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_sens.value = float(cfg.get_value("ui", "sensitivity", 1.0))
	_master.value = float(cfg.get_value("ui", "master_vol", 0.9))
	_music.value = float(cfg.get_value("ui", "music_vol", 0.7))
	_quality.selected = int(cfg.get_value("ui", "quality", 2))
	_map_select.selected = clampi(int(cfg.get_value("ui", "map", 0)), 0, MAP_KEYS.size() - 1)
	_on_map_selected(_map_select.selected)
	_apply_volumes()
	_on_quality(_quality.selected)


func _click() -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d("ui_click")


func _build_deploy() -> void:
	_deploy_panel = _screen("DeployPanel", Color.TRANSPARENT)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_deploy_panel.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 24)
	scroll.add_child(vb)
	_deploy_title = _label("PREPARE TO DEPLOY", 48)
	vb.add_child(_deploy_title)
	var gap := Control.new()
	gap.custom_minimum_size.y = 32
	vb.add_child(gap)
	_deploy_columns = GridContainer.new()
	_deploy_columns.columns = 1
	_deploy_columns.custom_minimum_size.x = 470
	_deploy_columns.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	vb.add_child(_deploy_columns)
	var controls := VBoxContainer.new()
	controls.add_theme_constant_override("separation", 12)
	_deploy_columns.add_child(controls)
	_deploy_mode = OptionButton.new()
	_deploy_mode.name = "DeployMode"
	for id in ["tdm", "tower_defense", "zombies"]:
		_deploy_mode.add_item(str(GameModeManager.MODES[id]["name"]))
	_deploy_mode.item_selected.connect(func(i: int) -> void:
		_selected_mode = ["tdm", "tower_defense", "zombies"][i]
		_refresh_deploy())
	_deploy_row(controls, "MODE", _deploy_mode)
	_map_select = OptionButton.new()
	_map_select.name = "DeployMap"
	for key in MAP_KEYS:
		_map_select.add_item(key.replace("_", " ").to_upper())
	_map_select.item_selected.connect(func(i: int) -> void:
		_on_map_selected(i)
		_refresh_deploy())
	_deploy_row(controls, "MAP", _map_select)
	_deploy_loadout = Button.new()
	_deploy_loadout.name = "DeployLoadout"
	_deploy_loadout.text = "ASSAULT  ›"
	_deploy_loadout.pressed.connect(_on_loadouts)
	_deploy_row(controls, "LOADOUT", _deploy_loadout)
	_deploy_tool = OptionButton.new()
	_deploy_tool.name = "DeployTraversal"
	for tool in DEPLOY_TOOLS:
		_deploy_tool.add_item(tool.replace("grapple", "grapple hook").to_upper())
	_deploy_tool.item_selected.connect(_set_deploy_tool)
	_deploy_row(controls, "TRAVERSAL", _deploy_tool)
	_deploy_preview_label = _label("", 16, StencilStyle.TEXT_DIM)
	_deploy_desc = _label("", 18, StencilStyle.TEXT_DIM)
	_deploy_desc.custom_minimum_size.x = 470
	_deploy_desc.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_deploy_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_deploy_desc)
	_deploy_preview = _map_art("factory")
	_deploy_preview.visible = false
	vb.add_child(_deploy_preview)
	vb.add_child(_deploy_preview_label)
	_deploy_status = _label("", 17, StencilStyle.ORANGE)
	_deploy_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_deploy_status)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(fill)
	var actions := HBoxContainer.new()
	vb.add_child(actions)
	var back := _menu_button("‹  BACK")
	back.custom_minimum_size.x = 150
	StencilStyle.navigation_button(back)
	back.pressed.connect(_close_deploy)
	actions.add_child(back)
	var space := Control.new()
	space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(space)
	var deploy := _menu_button("DEPLOY  ›")
	deploy.name = "DeployButton"
	deploy.custom_minimum_size.x = 210
	StencilStyle.primary_button(deploy)
	deploy.pressed.connect(func() -> void:
		_set_deploy_tool(_deploy_tool.selected)
		_launch_mode(_selected_mode))
	actions.add_child(deploy)


func _deploy_row(parent: Control, text: String, control: Button) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	parent.add_child(row)
	var label := _label(text, 17, StencilStyle.TEXT_DIM)
	label.custom_minimum_size.x = 120
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	_deploy_control(row, control)


func _deploy_control(parent: Control, control: Button) -> void:
	control.custom_minimum_size = Vector2(0, 52)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.add_theme_font_size_override("font_size", 19)
	StencilStyle.style_button(control)
	parent.add_child(control)


func _on_mode_start_pressed(mode_id: String) -> void:
	if not GameModeManager.is_implemented(mode_id):
		_mode_status_label.text = "THIS MODE IS NOT AVAILABLE."
		return
	if mode_id.begins_with("mp_"):
		_launch_mode(mode_id)
		return
	_selected_mode = mode_id
	_mode_overlay.visible = false
	_deploy_panel.visible = true
	_refresh_deploy()
	_layout_stack()
	InputBindings.grab_first_focus(_deploy_panel)


func _refresh_deploy() -> void:
	_deploy_mode.select(["tdm", "tower_defense", "zombies"].find(_selected_mode))
	_deploy_desc.text = str(GameModeManager.MODES[_selected_mode]["desc"])
	var forced := _selected_mode != "tdm"
	_map_select.disabled = forced
	_deploy_preview_label.text = ("TOWER DEFENSE" if _selected_mode == "tower_defense" else "ZOMBIES TOWN") if forced else MAP_KEYS[_map_select.selected].replace("_", " ").to_upper()
	var preview_key: String = MAP_KEYS[_map_select.selected]
	if forced:
		preview_key = "tower_defense" if _selected_mode == "tower_defense" else "zombies_flat"
	_deploy_preview.texture = load("res://assets/ui/maps/" + preview_key + ".png")
	var entry := Loadouts.get_active_loadout()
	_deploy_loadout.text = str(entry.get("name", "Assault")).to_upper() + "  ›"
	_deploy_loadout.disabled = _selected_mode == "tower_defense"
	var tool := TowerDefenseSetup.get_tool() if _selected_mode == "tower_defense" else str(entry.get("traversal", "grapple"))
	_deploy_tool.select(maxi(0, DEPLOY_TOOLS.find(tool)))
	_deploy_tool.set_item_disabled(3, _selected_mode == "tower_defense")
	_deploy_tool.disabled = _selected_mode == "zombies"
	if _selected_mode == "zombies":
		_deploy_tool.select(3)
	_deploy_status.text = "Zombies uses its own starting gear. Traversal is disabled by default." if _selected_mode == "zombies" else ""


func _set_deploy_tool(index: int) -> void:
	if _selected_mode == "zombies":
		return
	var tool: String = DEPLOY_TOOLS[index]
	if _selected_mode == "tower_defense":
		TowerDefenseSetup.set_tool(tool)
		TowerDefenseSetup.save_selection()
	else:
		var entry := Loadouts.get_active_loadout()
		if not entry.is_empty():
			Loadouts.update_loadout(str(entry["name"]), str(entry["primary"]), str(entry["secondary"]), str(entry.get("forge_preset", "")), tool)


func _close_deploy() -> void:
	_deploy_panel.visible = false
	_mode_overlay.visible = true
	_rebuild_mode_rows()
	InputBindings.grab_first_focus(_mode_overlay)


func _map_art(key: String) -> TextureRect:
	var art := _art()
	art.texture = load("res://assets/ui/maps/" + key + ".png")
	return art
