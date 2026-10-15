# scripts/ui/main_menu.gd
# FORGEFALL — main menu (Worker 6: HUD/UI).
# Dark military menu: stencil FORGEFALL title, voxel-cube motif strip,
# DEPLOY / MULTIPLAYER / LOADOUTS (persistent loadout picker, Goal 6) /
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
# Goal 3 CONTENT: game-mode selector (Survival / Domination / Endless).
var _mode_select: OptionButton
var _mode_desc: Label
var _mode_best: Label
var _map_select: OptionButton
const MAP_KEYS := ["dustline", "foundry", "outpost"]
# Goal 6 PROGRESSION (Worker B): persistent loadout picker overlay scene.
const LOADOUT_PICKER_SCENE := "res://scenes/ui/loadout_picker.tscn"
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
	_build()
	_load_settings()
	_hook_updater()


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
	_map_select.selected = 0
	StencilStyle.style_button(_map_select)
	_map_select.item_selected.connect(_on_map_selected)
	map_row.add_child(_map_select)

	# Mode selector (Goal 3, Worker C): same row pattern as the map picker.
	# Selection flows to GameModeManager.selected_mode immediately, so
	# DEPLOY starts the chosen mode; it also persists via _save_settings().
	var mode_row := HBoxContainer.new()
	mode_row.name = "ModeRow"
	mode_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mode_row.add_theme_constant_override("separation", 12)
	mode_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_stack.add_child(mode_row)
	var mode_label := Label.new()
	StencilStyle.apply_body(mode_label, 20, StencilStyle.TEXT, 2)
	mode_label.text = "MODE"
	mode_row.add_child(mode_label)
	_mode_select = OptionButton.new()
	for mid in ["survival", "domination", "endless"]:
		_mode_select.add_item(str(GameModeManager.MODES[mid]["name"]))
	StencilStyle.style_button(_mode_select)
	_mode_select.item_selected.connect(_on_mode_selected)
	mode_row.add_child(_mode_select)
	_mode_desc = Label.new()
	_mode_desc.name = "ModeDesc"
	_mode_desc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	StencilStyle.apply_body(_mode_desc, 18, StencilStyle.TEXT_DIM, 2)
	_mode_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_desc.custom_minimum_size = Vector2(380, 0)
	_stack.add_child(_mode_desc)
	_mode_best = Label.new()
	_mode_best.name = "ModeBest"
	_mode_best.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	StencilStyle.apply_body(_mode_best, 18, StencilStyle.ORANGE, 2)
	_mode_best.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stack.add_child(_mode_best)
	# Labels only here — _on_mode_selected() would _save_settings() before
	# the Options sliders exist (built later in _build_options()).
	_mode_desc.text = str(GameModeManager.MODES["survival"]["desc"])
	_mode_best.text = ""
	# Empty best label takes no space — hidden labels are skipped by the
	# VBox, which keeps the stack fitting short screens (Deck 1280x800).
	_mode_best.visible = false

	var deploy := _menu_button("DEPLOY")
	deploy.name = "DeployButton"
	deploy.pressed.connect(_on_deploy)
	_stack.add_child(deploy)
	_menu_buttons.append(deploy)
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

	var back := _menu_button("BACK")
	back.custom_minimum_size = Vector2(200, 54)
	back.pressed.connect(func() -> void: _options_panel.visible = false)
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


func _on_mode_selected(index: int) -> void:
	_click()
	var ids := ["survival", "domination", "endless"]
	var mid: String = ids[clampi(index, 0, ids.size() - 1)]
	GameModeManager.selected_mode = mid
	if _mode_desc != null:
		_mode_desc.text = str(GameModeManager.MODES[mid]["desc"])
	if _mode_best != null:
		if mid == "endless":
			var best := GameModeManager.load_best()
			var bs: int = int(best.get("best_score", 0))
			_mode_best.text = ("ENDLESS BEST: %d  (WAVE %d)" % [bs, int(best.get("best_wave", 0))]) if bs > 0 else "ENDLESS BEST: —"
		else:
			_mode_best.text = ""
		_mode_best.visible = not _mode_best.text.is_empty()
	_save_settings()


func _on_deploy() -> void:
	_click()
	var main := get_tree().current_scene
	if main != null and main.has_method("start_game"):
		main.start_game()
	else:
		# Fallback: worker 1's main scene. Coordinator: keep this path in sync.
		get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_multiplayer() -> void:
	_click()
	var main := get_tree().current_scene
	if main != null and main.has_method("open_multiplayer_menu"):
		main.open_multiplayer_menu()


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


func _on_options() -> void:
	_click()
	_options_panel.visible = not _options_panel.visible


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
	var saved_mode := str(cfg.get_value("game", "mode", "survival"))
	var ids := ["survival", "domination", "endless"]
	var midx := ids.find(saved_mode)
	if midx >= 0:
		_mode_select.selected = midx
		_on_mode_selected(midx)
	_apply_volumes()
	_on_quality(_quality.selected)


func _click() -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d("ui_click")
