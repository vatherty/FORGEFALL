# scripts/ui/main_menu.gd
# FORGEFALL — main menu (Worker 6: HUD/UI).
# Dark military menu: stencil FORGEFALL title, voxel-cube motif strip,
# SINGLE PLAYER / MULTIPLAYER / LOADOUTS (persistent loadout picker, Goal 6) /
# OPTIONS / QUIT. Options: sensitivity, master + music volume, gyro toggle
# (stub), quality -> viewport scale.
# LAYOUT (Deck screenshot fix): ONE vertical flow — a VBoxContainer inside
# a ScrollContainer. No fixed overlapping offsets: every row gets its own
# band from the container, so rows can never overlap at any resolution.
# _layout_stack() (also on resize) sizes the stack to at least the viewport
# so the spacers center the menu + pin the footer; if content is taller
# than the viewport, the stack grows to content height and the menu
# scrolls instead of colliding. (Previously the centered buttons box had a
# fixed 300px anchor rect but ~590px of content, so it overflowed into
# the tagline above and the footer below — the footer text
# "…Colin's playtest build" landed on top of the LOADOUT button.)
# Settings persist to user://forge_settings.cfg (NOT the DeepSeek config).
#
# Gameplay Rework (menu + TDM worker): the menu is a START MENU with
# two top entries — SINGLE PLAYER and MULTIPLAYER — each opening a
# MODE SELECT (SP: Tower Defense / TDM / Zombies; MP: the multiplayer
# versions). Mode entries route through the GameModeManager REGISTRY
# (GameModeManager.modes_for_scope / is_implemented): an entry whose
# implementation has not landed shows NOT AVAILABLE (disabled, never
# a crash, never a silent fallback). TDM's row shows the active
# loadout (weapons + exactly-one traversal tool) with a CHANGE
# LOADOUT button into the shared loadout picker. TD's START opens the
# TD worker's TowerDefenseSetup overlay; CONFIRM starts the TD run.
# The old DEPLOY + legacy MODE selector (survival/domination/endless)
# are gone: legacy modes still run via Main.start_game() for the
# integration suites, but the menu no longer offers them.
extends Control

const SETTINGS_PATH := "user://forge_settings.cfg"

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


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_stack()


## Sizes the menu stack to at least the viewport so the EXPAND spacers
## center the menu and pin the footer; if content is taller, the stack
## grows to content height and the ScrollContainer scrolls. Also rescales
## the title + button heights to the viewport so the stack fits short
## screens (Deck 1280x800) without scrolling.
func _layout_stack() -> void:
	if _stack == null or _title_label == null:
		return
	var vp := size
	if vp.x <= 0 or vp.y <= 0:
		return
	# Forge batch: 8 menu buttons + header rows overflow 800px-tall
	# screens (measured stack min 827 at 1280x800). Buttons are
	# floored at 56px by the theme, so the win comes from the title
	# + stack gaps: shrink the title and drop gaps on short screens.
	var title_factor := 0.095 if vp.y >= 900 else 0.075
	var title_px := clampi(int(minf(vp.y * title_factor, vp.x * 0.12)), 48, 110)
	StencilStyle.apply_title(_title_label, title_px, StencilStyle.TEXT, 10)
	# Button custom-min below the 56px theme floor is a no-op (the
	# theme min wins); 56 documents the real floor on short screens.
	var btn_h := 64 if vp.y >= 900 else 56
	# Forge batch: 8 menu buttons (CREATE A MOD added). Tighten further
	# on short screens so the stack fits 800px-tall viewports again
	# (separation 0 on short screens saves 16px of gaps).
	_stack.add_theme_constant_override("separation", 5 if vp.y >= 900 else 0)
	for b in _menu_buttons:
		b.custom_minimum_size.y = btn_h
	_stack.custom_minimum_size = Vector2.ZERO
	var content_min := _stack.get_minimum_size()
	_stack.custom_minimum_size = Vector2(maxf(vp.x, content_min.x), maxf(vp.y, content_min.y))
	_size_options_panel()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	InputBindings.ensure_loaded()
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
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.025, 0.03, 1.0)
	add_child(bg)

	# Root layout: ONE vertical flow inside a ScrollContainer (see header).
	_scroll = ScrollContainer.new()
	_scroll.name = "MenuScroll"
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_scroll)
	_stack = VBoxContainer.new()
	_stack.name = "MenuStack"
	_stack.alignment = BoxContainer.ALIGNMENT_CENTER
	_stack.add_theme_constant_override("separation", 5)
	_scroll.add_child(_stack)

	# Spacer pair: splits free space above/below the content, so the menu
	# centers vertically on tall screens and the footer pins to the bottom.
	# Zero height when content exceeds the viewport (menu scrolls instead).
	var spacer_top := Control.new()
	spacer_top.name = "SpacerTop"
	spacer_top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack.add_child(spacer_top)

	# Voxel-cube motif: a strip of chunky squares, orange on gunmetal.
	var motif := HBoxContainer.new()
	motif.name = "Motif"
	motif.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	motif.alignment = BoxContainer.ALIGNMENT_CENTER
	motif.add_theme_constant_override("separation", 6)
	motif.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.add_child(motif)
	var cols := [
		Color(0.23, 0.25, 0.27), Color(0.23, 0.25, 0.27), Color(1.0, 0.48, 0.11),
		Color(0.23, 0.25, 0.27), Color(0.35, 0.30, 0.20), Color(1.0, 0.48, 0.11),
		Color(0.23, 0.25, 0.27), Color(0.23, 0.25, 0.27), Color(1.0, 0.48, 0.11),
		Color(0.23, 0.25, 0.27),
	]
	for c in cols:
		var q := ColorRect.new()
		q.custom_minimum_size = Vector2(44, 44)
		q.color = c
		q.mouse_filter = Control.MOUSE_FILTER_IGNORE
		motif.add_child(q)

	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.text = "FORGEFALL"
	StencilStyle.apply_title(_title_label, 110, StencilStyle.TEXT, 10)
	_stack.add_child(_title_label)

	var sub := Label.new()
	sub.name = "Tagline"
	sub.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_body(sub, 24, StencilStyle.ORANGE, 5)
	sub.text = "PROVING GROUND // BUILD. FIGHT. SURVIVE."
	_stack.add_child(sub)

	# Map selector (Goal 3, Worker A): minimal row reusing the menu button
	# style. Selection flows to Main.set_selected_map() immediately, so
	# DEPLOY loads the chosen map; it also persists via _save_settings().
	var map_row := HBoxContainer.new()
	map_row.name = "MapRow"
	map_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	map_row.add_theme_constant_override("separation", 12)
	map_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_stack.add_child(map_row)
	var map_label := Label.new()
	StencilStyle.apply_body(map_label, 20, StencilStyle.TEXT, 2)
	map_label.text = "MAP"
	map_row.add_child(map_label)
	_map_select = OptionButton.new()
	_map_select.add_item("DUSTLINE", 0)
	_map_select.add_item("FOUNDRY", 1)
	_map_select.add_item("OUTPOST", 2)
	_map_select.add_item("CINDER CITY", 3)
	_map_select.add_item("TOWER DEFENSE", 4)
	_map_select.add_item("FACTORY", 5)
	_map_select.selected = 0
	StencilStyle.style_button(_map_select)
	_map_select.item_selected.connect(_on_map_selected)
	map_row.add_child(_map_select)

	# Gameplay Rework: the two top entries. SINGLE PLAYER opens the SP
	# mode select (Tower Defense / TDM / Zombies); MULTIPLAYER opens
	# the MP mode select (the multiplayer versions).
	var single_player := _menu_button("SINGLE PLAYER")
	single_player.name = "SinglePlayerButton"
	single_player.pressed.connect(_on_single_player)
	_stack.add_child(single_player)
	_menu_buttons.append(single_player)
	var multiplayer := _menu_button("MULTIPLAYER")
	multiplayer.name = "MultiplayerButton"
	multiplayer.pressed.connect(_on_multiplayer)
	_stack.add_child(multiplayer)
	_menu_buttons.append(multiplayer)
	# Goal 5 Worker B: puzzle-room entry (chambers are portal puzzles,
	# not combat maps). Wiring for THIS button only; menu otherwise untouched.
	var puzzles := _menu_button("PUZZLE CHAMBERS")
	puzzles.name = "PuzzlesButton"
	puzzles.pressed.connect(_on_puzzles)
	_stack.add_child(puzzles)
	_menu_buttons.append(puzzles)
	# Goal 6 PROGRESSION (Worker B): LOADOUTS opens the persistent
	# loadout picker (a self-contained overlay scene). The picker owns
	# its own layout; this button only instantiates it and frees it
	# when it closes. No placeholder state remains anywhere.
	var loadouts := _menu_button("LOADOUTS")
	loadouts.name = "LoadoutButton"
	loadouts.pressed.connect(_on_loadouts)
	_stack.add_child(loadouts)
	_menu_buttons.append(loadouts)
	# Goal 6 PROGRESSION (coordinator): STATS opens the persistent
	# stats screen (a self-contained overlay scene, like the picker).
	var stats := _menu_button("STATS")
	stats.name = "StatsButton"
	stats.pressed.connect(_on_stats)
	_stack.add_child(stats)
	_menu_buttons.append(stats)
	# CREATE A MOD (Forge batch, Worker D): opens the standalone Mod
	# Creator menu — CREATE / MODS / IMPORT-EXPORT tabs. This button is
	# the menu's only addition to main_menu.gd.
	var create_mod := _menu_button("CREATE A MOD")
	create_mod.name = "CreateAModButton"
	create_mod.pressed.connect(_on_create_mod)
	_stack.add_child(create_mod)
	_menu_buttons.append(create_mod)
	var options := _menu_button("OPTIONS")
	options.name = "OptionsButton"
	options.pressed.connect(_on_options)
	_stack.add_child(options)
	_menu_buttons.append(options)
	var quit := _menu_button("QUIT")
	quit.name = "QuitButton"
	quit.pressed.connect(_on_quit)
	_stack.add_child(quit)
	_menu_buttons.append(quit)

	var spacer_bottom := Control.new()
	spacer_bottom.name = "SpacerBottom"
	spacer_bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack.add_child(spacer_bottom)

	var footer := Label.new()
	footer.name = "Footer"
	footer.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_body(footer, 16, StencilStyle.TEXT_DIM, 2)
	# No hardcoded version here — it went stale at v0.1 and would again.
	footer.text = "FORGEFALL — Colin's playtest build"
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.add_child(footer)

	_build_options()
	_build_mode_overlay()
	_layout_stack()


func _menu_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(380, 64)
	# SHRINK_CENTER: menu buttons stay 380 wide and centered. Without
	# this the default FILL flag stretches them to the full stack width.
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	StencilStyle.style_button(b)
	b.add_theme_font_size_override("font_size", 26)
	return b


func _size_options_panel() -> void:
	if _options_panel == null:
		return
	# Viewport-sized, centered — never fixed 600x560, so it cannot clip on
	# short screens (Deck windowed) or hang off a portrait phone.
	var vp := size
	if vp.x <= 0 or vp.y <= 0:
		return
	var pw := minf(600.0, vp.x * 0.92)
	var ph := minf(560.0, vp.y * 0.92)
	_options_panel.offset_left = -pw / 2.0
	_options_panel.offset_right = pw / 2.0
	_options_panel.offset_top = -ph / 2.0
	_options_panel.offset_bottom = ph / 2.0
	if _options_vb != null:
		# Fill the panel so the VBox's CENTER alignment centers the
		# options; if content is taller, the VBox grows past this and the
		# ScrollContainer scrolls instead of clipping.
		_options_vb.custom_minimum_size = Vector2(maxf(0.0, pw - 28.0), maxf(0.0, ph - 20.0))


func _build_options() -> void:
	_options_panel = PanelContainer.new()
	_options_panel.name = "OptionsPanel"
	_options_panel.set_anchors_preset(Control.PRESET_CENTER)
	_options_panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	_options_panel.visible = false
	add_child(_options_panel)
	var opt_scroll := ScrollContainer.new()
	opt_scroll.name = "OptionsScroll"
	_options_panel.add_child(opt_scroll)
	var vb := VBoxContainer.new()
	vb.name = "OptionsStack"
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	opt_scroll.add_child(vb)
	_options_vb = vb

	var head := Label.new()
	StencilStyle.apply_title(head, 30, StencilStyle.ORANGE, 4)
	head.text = "OPTIONS"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(head)

	_sens = _slider_row(vb, "SENSITIVITY", 0.5, 3.0, 0.05, 1.0)
	_sens.value_changed.connect(func(_v: float) -> void: _save_settings())
	_master = _slider_row(vb, "MASTER VOL", 0.0, 1.0, 0.01, 0.9)
	_master.value_changed.connect(func(_v: float) -> void: _apply_volumes(); _save_settings())
	_music = _slider_row(vb, "MUSIC VOL", 0.0, 1.0, 0.01, 0.7)
	_music.value_changed.connect(func(_v: float) -> void: _apply_volumes(); _save_settings())

	var gyro_row := HBoxContainer.new()
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
	upd_head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(upd_head)

	var upd_row := HBoxContainer.new()
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

	# CONTROLS: full keyboard + gamepad remapping (v0.6.1). Opens the
	# RebindMenu overlay; BACK returns here.
	var controls := _menu_button("CONTROLS...")
	controls.custom_minimum_size = Vector2(280, 54)
	controls.pressed.connect(_on_controls)
	var cc := CenterContainer.new()
	cc.add_child(controls)
	vb.add_child(cc)

	var back := _menu_button("BACK")
	back.custom_minimum_size = Vector2(200, 54)
	back.pressed.connect(func() -> void: _options_panel.visible = false; _focus_menu_button("OptionsButton"))
	var bc := CenterContainer.new()
	bc.add_child(back)
	vb.add_child(bc)


func _slider_row(parent: Control, label_text: String, mn: float, mx: float, step: float, val: float) -> HSlider:
	var row := HBoxContainer.new()
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
	s.custom_minimum_size = Vector2(280, 30)
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
	_mode_overlay = PanelContainer.new()
	_mode_overlay.name = "ModeSelectOverlay"
	_mode_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mode_overlay.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	_mode_overlay.visible = false
	add_child(_mode_overlay)
	var scroll := ScrollContainer.new()
	scroll.name = "ModeSelectScroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mode_overlay.add_child(scroll)
	var root := VBoxContainer.new()
	root.name = "ModeSelectRoot"
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 10)
	scroll.add_child(root)
	var title := Label.new()
	title.name = "ModeSelectTitle"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_title(title, 36, StencilStyle.ORANGE, 4)
	root.add_child(title)
	var sub := Label.new()
	sub.name = "ModeSelectSubtitle"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_body(sub, 18, StencilStyle.TEXT_DIM, 2)
	sub.text = "CHOOSE A MODE"
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(sub)
	_mode_overlay_rows = VBoxContainer.new()
	_mode_overlay_rows.name = "ModeRows"
	_mode_overlay_rows.add_theme_constant_override("separation", 12)
	root.add_child(_mode_overlay_rows)
	_mode_status_label = Label.new()
	_mode_status_label.name = "ModeStatus"
	_mode_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_mode_status_label, 18, StencilStyle.ORANGE, 2)
	root.add_child(_mode_status_label)
	var back := _menu_button("BACK")
	back.name = "ModeBackButton"
	back.pressed.connect(_close_mode_select)
	root.add_child(back)


func _open_mode_select(scope: String) -> void:
	_mode_overlay_scope = scope
	if _mode_overlay == null:
		_build_mode_overlay()
	# MP worker: flip the MP modes to implemented through the
	# registry (MPModes.ensure_registered) so the MP select reads
	# AVAILABLE as soon as the implementations exist. Runtime load
	# (never a bare MPModes reference): this file must parse before
	# the new script lands in the class cache.
	var mp_script := load("res://scripts/net/mp_modes.gd") as GDScript
	if mp_script != null:
		mp_script.call("ensure_registered")
	var title := _mode_overlay.get_node_or_null("ModeSelectScroll/ModeSelectRoot/ModeSelectTitle") as Label
	if title != null:
		title.text = "SINGLE PLAYER" if scope == "sp" else "MULTIPLAYER"
	if _mode_status_label != null:
		_mode_status_label.text = ""
	_rebuild_mode_rows()
	_mode_overlay.visible = true
	InputBindings.grab_first_focus(_mode_overlay)


func _close_mode_select() -> void:
	_click()
	if _mode_overlay != null:
		_mode_overlay.visible = false
	_focus_menu_button("MultiplayerButton" if _mode_overlay_scope == "mp" else "SinglePlayerButton")


func _rebuild_mode_rows() -> void:
	if _mode_overlay_rows == null:
		return
	for child in _mode_overlay_rows.get_children():
		_mode_overlay_rows.remove_child(child)
		child.queue_free()
	for mode_id in GameModeManager.modes_for_scope(_mode_overlay_scope):
		_mode_overlay_rows.add_child(_build_mode_row(mode_id))


func _build_mode_row(mode_id: String) -> Control:
	var wrap := VBoxContainer.new()
	wrap.name = "ModeRow_" + mode_id
	wrap.add_theme_constant_override("separation", 4)
	var row := HBoxContainer.new()
	row.name = "ModeRowInner_" + mode_id
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	wrap.add_child(row)
	var name_lbl := Label.new()
	name_lbl.name = "ModeName_" + mode_id
	name_lbl.text = str(GameModeManager.MODES[mode_id]["name"])
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(name_lbl, 22, StencilStyle.TEXT, 2)
	row.add_child(name_lbl)
	var implemented := GameModeManager.is_implemented(mode_id)
	var status := Label.new()
	status.name = "ModeStatus_" + mode_id
	status.text = "AVAILABLE" if implemented else "NOT AVAILABLE"
	StencilStyle.apply_body(status, 18, StencilStyle.GREEN if implemented else StencilStyle.TEXT_DIM, 2)
	row.add_child(status)
	var btn := Button.new()
	btn.name = "ModeStart_" + mode_id
	if not implemented:
		btn.text = "NOT AVAILABLE"
		btn.disabled = true
		btn.tooltip_text = "This mode's implementation has not landed yet."
	elif mode_id == "tdm":
		btn.text = "START MATCH"
	else:
		btn.text = "START"
	StencilStyle.style_button(btn)
	btn.add_theme_font_size_override("font_size", 20)
	btn.custom_minimum_size = Vector2(220, 54)
	btn.pressed.connect(_on_mode_start_pressed.bind(mode_id))
	row.add_child(btn)
	var desc := Label.new()
	desc.name = "ModeDesc_" + mode_id
	desc.text = str(GameModeManager.MODES[mode_id]["desc"])
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(desc, 17, StencilStyle.TEXT_DIM, 2)
	wrap.add_child(desc)
	if _mode_overlay_scope == "sp" and mode_id == "tdm":
		var lrow := HBoxContainer.new()
		lrow.name = "TdmLoadoutRow"
		lrow.add_theme_constant_override("separation", 12)
		lrow.alignment = BoxContainer.ALIGNMENT_CENTER
		wrap.add_child(lrow)
		var llabel := Label.new()
		llabel.name = "TdmLoadoutLabel"
		llabel.text = _tdm_loadout_line()
		llabel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		StencilStyle.apply_body(llabel, 18, StencilStyle.TEXT, 2)
		lrow.add_child(llabel)
		var change := Button.new()
		change.name = "ModeLoadoutChange"
		change.text = "CHANGE LOADOUT"
		StencilStyle.style_button(change)
		change.add_theme_font_size_override("font_size", 18)
		change.custom_minimum_size = Vector2(220, 54)
		change.pressed.connect(_on_change_loadout_pressed)
		lrow.add_child(change)
	return wrap


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


func _on_mode_start_pressed(mode_id: String) -> void:
	_click()
	if not GameModeManager.is_implemented(mode_id):
		if _mode_status_label != null:
			_mode_status_label.text = "NOT AVAILABLE YET."
		return
	match mode_id:
		"tower_defense":
			_open_td_setup()
		"tdm":
			var main := get_tree().current_scene
			if main != null and main.has_method("start_sp_mode"):
				if bool(main.call("start_sp_mode", "tdm")):
					return
				if _mode_status_label != null:
					_mode_status_label.text = "COULD NOT START TDM — SEE LOG."
			elif _mode_status_label != null:
				_mode_status_label.text = "COULD NOT START TDM — MAIN MISSING."
		"zombies":
			var main_z := get_tree().current_scene
			if main_z != null and main_z.has_method("start_sp_mode"):
				if bool(main_z.call("start_sp_mode", "zombies")):
					return
				if _mode_status_label != null:
					_mode_status_label.text = "COULD NOT START ZOMBIES — SEE LOG."
			elif _mode_status_label != null:
				_mode_status_label.text = "COULD NOT START ZOMBIES — MAIN MISSING."
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
	_options_panel.visible = not _options_panel.visible
	if _options_panel.visible:
		InputBindings.grab_first_focus(_options_panel)
	else:
		_focus_menu_button("OptionsButton")


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
	# Sliders/options are built in _build_options(), which runs after the
	# mode/map rows — guard so an early save (mode/map pick) can't null-deref.
	if _sens != null:
		cfg.set_value("ui", "sensitivity", _sens.value)
	if _master != null:
		cfg.set_value("ui", "master_vol", _master.value)
	if _music != null:
		cfg.set_value("ui", "music_vol", _music.value)
	if _quality != null:
		cfg.set_value("ui", "quality", _quality.selected)
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
	_map_select.selected = int(cfg.get_value("ui", "map", 0))
	_on_map_selected(_map_select.selected)
	_apply_volumes()
	_on_quality(_quality.selected)


func _click() -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d("ui_click")
