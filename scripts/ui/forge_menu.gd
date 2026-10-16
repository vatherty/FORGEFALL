# scripts/ui/forge_menu.gd
# FORGEFALL — Forge menu (B1: real menu UI, not just a text field).
# A Control scene (scenes/ui/forge_menu.tscn). The coordinator instantiates
# it and wires it to the HUD's FORGE button; open()/close() are the API.
#
# Tabs: Build / Weapons / Events / Killstreaks, each with preset buttons.
# Tapping a preset FILLS the prompt field and shows the cost preview; the
# CONFIRM ("FORGE IT") button submits via Forge.submit_prompt — so the user
# always sees the cost before anything is spent.
#
# BACKEND DEGRADATION: only Forge.submit_prompt + Forge.get_budget exist
# today. preview_cost / undo_last / get_history are called ONLY behind
# has_method guards:
#   - no preview_cost -> preview line shows budget only ("COST: —").
#   - no undo_last -> the Undo button is hidden.
#   - no get_history -> history falls back to prompts submitted through
#     this menu this session (local list, capped at 8).
# Results come from the existing Forge.forge_result signal when present;
# otherwise a generic "Command sent" toast is shown.
#
# PAUSE: this menu deliberately does NOT pause the tree. The pause menu
# freezes the game loop (and with it the HUD); the Forge menu is a
# build-phase console over a live game, like the HUD's forge panel. Its
# process_mode is ALWAYS so it stays responsive regardless.
# Never grabs input focus on open (HUD lesson: focus routes WASD into the
# LineEdit and pops the phone keyboard); the user taps the field to type.
extends Control

const HISTORY_CAP := 8
const TOAST_HOLD_SEC := 4.0

# Preset prompts are worded to hit the offline keyword fallback in
# ForgeLLM (read-only contract): "wall"/"tower"/"turret"/"ammo"/"health"/
# "sniper"/"shotgun"/"smg"/"uav"/"airstrike"/"chopper"/"smoke"/"supply".
# NOTE: "Spawn enemies" is intentionally NOT a preset — player requisitions
# may only weaken enemies (ForgeManager validation rejects the rest), so a
# spawn-enemies button would silently become an improvised supply drop.
# "Weaken Enemies" is the honest equivalent.
const PRESETS := {
	"Build": [
		["Wall", "Build a wall in front of me"],
		["Tower", "Build a tower"],
		["Turret", "Spawn a turret"],
		["Bridge", "Build a bridge wall in front of me"],
		["Bunker", "Build a bunker wall"],
		["Watchtower", "Build a watchtower"],
		["Ammo Depot", "Spawn an ammo depot"],
		["Stairs", "Build stairs"],
		["Ramp", "Build a ramp"],
		["Jump Pad", "Build a jump pad"],
		["Cover Piece", "Build a cover piece"],
		["Sniper Nest", "Build a sniper nest"],
	],
	"Weapons": [
		["Sniper", "Give me a sniper rifle"],
		["Shotgun", "Give me a shotgun"],
		["SMG", "Give me an smg"],
		["Assault Rifle", "Give me an assault rifle"],
		["LMG", "Give me a machine gun"],
		["Burst Rifle", "Give me a burst rifle"],
		["Judge", "Give me a judge"],
	],
	"Events": [
		["Weaken Enemies", "Weaken the enemies"],
		["Smoke", "Deploy a smoke screen"],
		["Supply Drop", "Call a supply drop"],
		["Health Cache", "Send a health cache"],
	],
	"Killstreaks": [
		["UAV", "Call a UAV"],
		["Airstrike", "Call an airstrike"],
		["Chopper", "Call a chopper gunship"],
	],
}

const DEFAULT_TOAST := "Tap a preset, then FORGE IT — or type your own requisition."

var _tabs: TabContainer
var _budget_label: Label
var _prompt_input: LineEdit
var _confirm_button: Button
var _preview_label: Label
var _history_list: VBoxContainer
var _history_search_input: LineEdit
var _code_input: LineEdit
var _placed_list: VBoxContainer
## Pending spec while a ghost preview is active (Forge batch item 2):
## the position is filled from the ghost at confirm time.
var _pending_ghost_spec := {}
var _code_build_button: Button
var _code_copy_button: Button
var _undo_button: Button
var _toast_label: Label
var _key_input: LineEdit
var _key_status: Label
var _toast_t := 0.0
var _local_history: Array[String] = []
var _wired := false
var _mic_button: Button
var _speech: SpeechInput
# v0.5.3 Forge MAKE (session-scoped creation): ONE prompt box. MAKE
# calls the same ModCreator.generate() entry point the Create-a-Mod
# menu uses, but NEVER install() — the made thing lives in this match
# only and nothing is written to user://mods/.
var _spawn_label: Label
var _make_panel: PanelContainer
var _make_title: Label
var _make_explainer: Label
var _make_input: LineEdit
var _make_button: Button
var _make_status: Label
var _make_creator: ModCreator
var _make_generating := false
# v0.6.1 UiScale refs: every size/font in the menu is (re)applied from
# these in _apply_scale(), which runs at build, on open, and on viewport
# resize — _build itself carries no hardcoded pixel sizes.
var _panel: PanelContainer
var _root_box: VBoxContainer
var _content_box: VBoxContainer
var _header_box: HBoxContainer
var _title_label: Label
var _close_button: Button
var _prompt_row: HBoxContainer
var _key_row: HBoxContainer
var _key_label: Label
var _hist_title: Label
var _hist_scroll: ScrollContainer
var _footer_box: HBoxContainer
var _save_key_button: Button
var _clear_key_button: Button
var _grids: Array[GridContainer] = []
var _menu_buttons: Array[Button] = []
# v0.7 MODS TAB: rows are rebuilt by _refresh_mods(); _mods_rows holds the
# per-mod row wrappers so _apply_scale() can re-size them after a rebuild.
var _mods_list: VBoxContainer
var _mods_scroll: ScrollContainer
var _mods_path_label: Label
var _mods_rescan_button: Button
var _mods_tab_idx := -1
var _mods_rows: Array[Control] = []
# Create-Mod now lives in the standalone Mod Creator menu (main menu ->
# CREATE A MOD). The Mods tab keeps list / enable / disable / Rescan only.


func _ready() -> void:
	add_to_group("forge_menu")
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()
	# v0.6.1: recompute all scaled sizes when the viewport resizes
	# (rotation, split-screen, different phones).
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)
	_wire_forge()


func _build() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	# v0.6.1 TRUE FULL-SCREEN MODAL: the old PRESET_CENTER box with
	# hardcoded ±560/±330 offsets (a fixed 1120x660 box) clipped on
	# phones. The panel now fills the viewport minus a ~2% margin on
	# each side; exact offsets are set in _apply_scale().
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	add_child(panel)
	_panel = panel

	var root := VBoxContainer.new()
	root.name = "Root"
	panel.add_child(root)
	_root_box = root

	# Header: title + live budget + close.
	var header := HBoxContainer.new()
	header.name = "Header"
	root.add_child(header)
	_header_box = header
	var title := Label.new()
	title.text = "FORGE MENU"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_title_label = title
	_budget_label = Label.new()
	_budget_label.name = "BudgetLabel"
	_budget_label.text = "BUDGET: —"
	# Directive A: budget enforcement is OFF (Forge manager
	# BUDGET_ENABLED = false) — the budget UI is HIDDEN, not deleted:
	# the label stays in the tree so a re-enable only flips visibility.
	_budget_label.visible = false
	header.add_child(_budget_label)
	var close_btn := Button.new()
	close_btn.name = "CloseButton"
	close_btn.text = "X"
	StencilStyle.style_button(close_btn)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)
	_close_button = close_btn

	# Everything below the header lives in ONE outer ScrollContainer so
	# the bottom rows (DeepSeek key row, UNDO LAST, hint line) stay
	# reachable on short screens instead of clipping off the panel.
	var content_scroll := ScrollContainer.new()
	content_scroll.name = "ContentScroll"
	content_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content_scroll)
	var content := VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.add_child(content)
	_content_box = content

	# SPAWN section header: the preset tabs + the typed requisition
	# below build from the fixed catalog. MAKE (further down) is the
	# separate, session-scoped creation path — never confuse the two.
	_spawn_label = Label.new()
	_spawn_label.name = "SpawnSectionLabel"
	_spawn_label.text = "SPAWN — build from the catalog"
	content.add_child(_spawn_label)

	# Category tabs with preset buttons.
	_tabs = TabContainer.new()
	_tabs.name = "TabContainer"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_tabs)
	for tab_name in ["Build", "Weapons", "Events", "Killstreaks"]:
		var scroll := ScrollContainer.new()
		scroll.name = tab_name
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_tabs.add_child(scroll)
		var grid := GridContainer.new()
		grid.columns = 2
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(grid)
		_grids.append(grid)
		for preset in PRESETS[tab_name]:
			var label_text: String = preset[0]
			var prompt: String = preset[1]
			var b := Button.new()
			b.name = label_text.replace(" ", "_")
			b.text = label_text.to_upper()
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			StencilStyle.style_button(b)
			b.set_meta("forge_prompt", prompt)
			b.pressed.connect(_on_preset_pressed.bind(prompt, label_text))
			grid.add_child(b)
			_menu_buttons.append(b)

	# v0.6 LOADOUTS (free gear — no Forge budget cost): 4 presets.
	_build_loadouts_tab()

	# v0.7 MODS tab (6th tab): installed user mods from ModLoader.
	_build_mods_tab()

	# v0.5.3 MAKE (session-scoped creation): ONE prompt box. MAKE calls
	# the same ModCreator.generate() entry point the Create-a-Mod menu
	# uses, but NEVER install() — the made thing lives in this match
	# only and nothing is written to user://mods/.
	_build_make_section()

	# Placed structures (Forge batch item 2): move / rotate / repair /
	# delete after placing. Refreshed on open() and after every action.
	var placed_title := Label.new()
	placed_title.text = "PLACED STRUCTURES"
	content.add_child(placed_title)
	_placed_list = VBoxContainer.new()
	_placed_list.name = "PlacedStructuresList"
	content.add_child(_placed_list)

	# Free-text prompt + confirm.
	var prompt_row := HBoxContainer.new()
	prompt_row.name = "PromptRow"
	content.add_child(prompt_row)
	_prompt_row = prompt_row
	_prompt_input = LineEdit.new()
	_prompt_input.name = "PromptInput"
	_prompt_input.placeholder_text = "Type a requisition... (e.g. build a wall)"
	_prompt_input.clear_button_enabled = true
	_prompt_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_prompt_input)
	# v0.5.1 FIX 6: focus on click ONLY — never via nav/auto. FOCUS_CLICK
	# means the phone keyboard appears ONLY when the user taps the
	# LineEdit itself; opening the menu or tabbing never focuses it.
	_prompt_input.focus_mode = Control.FOCUS_CLICK
	_prompt_input.text_changed.connect(_on_prompt_text_changed)
	_prompt_input.text_submitted.connect(_on_prompt_submitted)
	prompt_row.add_child(_prompt_input)
	_confirm_button = Button.new()
	_confirm_button.name = "ConfirmButton"
	_confirm_button.text = "FORGE IT"
	StencilStyle.style_button(_confirm_button)
	_confirm_button.pressed.connect(_on_confirm_pressed)
	prompt_row.add_child(_confirm_button)
	# v0.6.0 MIC: voice input inside the Forge menu. Same path as the
	# touch-layer MIC button: SpeechInput.listen() transcribes via the
	# ForgeSpeech plugin when available, else falls back to the typed
	# console + toast (the v0.5.1 floor — never removed). The fallback
	# does NOT press forge_console here (listen(..., false)): the menu
	# already shows a text field, and forge_console would toggle the
	# menu closed.
	_mic_button = Button.new()
	_mic_button.name = "MicButton"
	_mic_button.text = "MIC"
	StencilStyle.style_button(_mic_button)
	_mic_button.pressed.connect(_on_mic_pressed)
	prompt_row.add_child(_mic_button)
	if _speech == null:
		_speech = SpeechInput.new()
		_speech.name = "SpeechInput"
		add_child(_speech)

	# Cost preview (budget-only when preview_cost is absent).
	# Directive A: costs are still computed + shown, but building is
	# free — the "(free)" suffix says so, and nothing here blocks.
	_preview_label = Label.new()
	_preview_label.name = "PreviewLabel"
	_preview_label.text = "COST: —"
	content.add_child(_preview_label)

	# History search: filters the history list by text (case-insensitive).
	_history_search_input = LineEdit.new()
	_history_search_input.name = "HistorySearchInput"
	_history_search_input.placeholder_text = "Search history…"
	_history_search_input.clear_button_enabled = true
	_history_search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_history_search_input)
	_history_search_input.focus_mode = Control.FOCUS_CLICK
	_history_search_input.text_changed.connect(_on_history_search_changed)
	content.add_child(_history_search_input)

	# Prompt history.
	var hist_title := Label.new()
	hist_title.text = "RECENT — TAP TO RE-SEND"
	content.add_child(hist_title)
	_hist_title = hist_title
	var hist_scroll := ScrollContainer.new()
	hist_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(hist_scroll)
	_hist_scroll = hist_scroll
	_history_list = VBoxContainer.new()
	_history_list.name = "HistoryList"
	hist_scroll.add_child(_history_list)

	# Shareable build codes: paste a code to rebuild the exact spec it
	# encodes, or copy the last successful build's code to send to a
	# friend. Codes are validated like any spec before building.
	var code_row := HBoxContainer.new()
	code_row.name = "CodeRow"
	content.add_child(code_row)
	_code_input = LineEdit.new()
	_code_input.name = "CodeInput"
	_code_input.placeholder_text = "Paste a build code…"
	_code_input.clear_button_enabled = true
	_code_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_code_input)
	_code_input.focus_mode = Control.FOCUS_CLICK
	_code_input.text_submitted.connect(_on_code_build_submitted)
	code_row.add_child(_code_input)
	_code_build_button = Button.new()
	_code_build_button.name = "CodeBuildButton"
	_code_build_button.text = "BUILD FROM CODE"
	StencilStyle.style_button(_code_build_button)
	_code_build_button.pressed.connect(_on_code_build_pressed)
	code_row.add_child(_code_build_button)
	_code_copy_button = Button.new()
	_code_copy_button.name = "CodeCopyButton"
	_code_copy_button.text = "COPY LAST CODE"
	StencilStyle.style_button(_code_copy_button)
	_code_copy_button.pressed.connect(_on_code_copy_pressed)
	code_row.add_child(_code_copy_button)

	# DeepSeek key entry (v0.6 LLM wiring): the key lives ONLY in
	# user://forge_config.json on this device, placed by the player here.
	# The field is secret-masked and cleared after save; the status line
	# reports present/absent ONLY — the key value is never displayed,
	# logged, or echoed anywhere.
	var key_row := HBoxContainer.new()
	key_row.name = "KeyRow"
	content.add_child(key_row)
	_key_row = key_row
	var key_label := Label.new()
	key_label.text = "DEEPSEEK KEY"
	key_row.add_child(key_label)
	_key_label = key_label
	_key_input = LineEdit.new()
	_key_input.name = "KeyInput"
	_key_input.placeholder_text = "Paste DeepSeek key (stays on this device)"
	_key_input.secret = true
	_key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_key_input)
	# Same focus rule as the prompt field: keyboard only on tap.
	_key_input.focus_mode = Control.FOCUS_CLICK
	_key_input.text_submitted.connect(_on_save_key_pressed)
	key_row.add_child(_key_input)
	var save_key_btn := Button.new()
	save_key_btn.name = "SaveKeyButton"
	save_key_btn.text = "SAVE KEY"
	StencilStyle.style_button(save_key_btn)
	save_key_btn.pressed.connect(_on_save_key_pressed)
	key_row.add_child(save_key_btn)
	_save_key_button = save_key_btn
	var clear_key_btn := Button.new()
	clear_key_btn.name = "ClearKeyButton"
	clear_key_btn.text = "CLEAR"
	StencilStyle.style_button(clear_key_btn)
	clear_key_btn.pressed.connect(_on_clear_key_pressed)
	key_row.add_child(clear_key_btn)
	_clear_key_button = clear_key_btn
	_key_status = Label.new()
	_key_status.name = "KeyStatusLabel"
	_key_status.text = "LLM: —"
	content.add_child(_key_status)

	# Footer: undo + toast/feedback.
	var footer := HBoxContainer.new()
	footer.name = "Footer"
	content.add_child(footer)
	_footer_box = footer
	_undo_button = Button.new()
	_undo_button.name = "UndoButton"
	_undo_button.text = "UNDO LAST"
	StencilStyle.style_button(_undo_button)
	_undo_button.pressed.connect(_on_undo_pressed)
	footer.add_child(_undo_button)
	_toast_label = Label.new()
	_toast_label.name = "ToastLabel"
	_toast_label.text = DEFAULT_TOAST
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_toast_label)

	# Apply resolution-scaled sizes/fonts to everything built above.
	_apply_scale()


# ------------------------------------------------------------------ v0.5.3 MAKE
# MAKE (this match only — not saved): ONE prompt box. The player types a
# single idea ("a chunky concrete wall"); MAKE feeds it verbatim to the
# EXISTING generation pipeline (ModCreator.generate — the exact entry
# point the Create-a-Mod menu uses) and applies a validated BLOCK
# candidate in-session via ForgeSessionMake. Create-a-Mod remains the
# ONLY path that saves a permanent mod: MAKE never calls install() and
# never writes to user://mods/. A generated SCRIPT candidate cannot run
# in-session (running unsaved code would need a disk file or dynamic
# code loading, both blocked) — MAKE shows that visibly and points at
# Create-a-Mod instead of silently falling back to a preset.
func _build_make_section() -> void:
	var panel := PanelContainer.new()
	panel.name = "MakePanel"
	# Gold border + warm dark fill: visually distinct from the SPAWN
	# presets (orange accent) and from Create-a-Mod (standalone menu).
	panel.add_theme_stylebox_override("panel", StencilStyle.panel(Color(0.09, 0.07, 0.03, 0.94), StencilStyle.GOLD, 2))
	_content_box.add_child(panel)
	_make_panel = panel
	var box := VBoxContainer.new()
	box.name = "MakeBox"
	panel.add_child(box)
	_make_title = Label.new()
	_make_title.name = "MakeTitleLabel"
	_make_title.text = "MAKE (this match only — not saved)"
	box.add_child(_make_title)
	_make_explainer = Label.new()
	_make_explainer.name = "MakeExplainerLabel"
	_make_explainer.text = "Describe ONE thing — MAKE creates it NOW for this match only. Nothing is saved. To keep something forever, use CREATE A MOD in the main menu."
	_make_explainer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_make_explainer)
	var row := HBoxContainer.new()
	row.name = "MakeRow"
	box.add_child(row)
	_make_input = LineEdit.new()
	_make_input.name = "MakePromptInput"
	_make_input.placeholder_text = "Make something new... (e.g. a chunky concrete wall)"
	_make_input.clear_button_enabled = true
	_make_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_make_input)
	# Same focus rule as the other fields: keyboard only on tap.
	_make_input.focus_mode = Control.FOCUS_CLICK
	_make_input.text_submitted.connect(_on_make_pressed)
	row.add_child(_make_input)
	_make_button = Button.new()
	_make_button.name = "MakeButton"
	_make_button.text = "MAKE IT"
	StencilStyle.style_button(_make_button)
	_make_button.pressed.connect(_on_make_pressed)
	row.add_child(_make_button)
	_make_status = Label.new()
	_make_status.name = "MakeStatusLabel"
	_make_status.text = "MAKE creates something new for this match only — nothing is saved."
	_make_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_make_status)


# ------------------------------------------------------------------ scaling
func _vp_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(1920.0, 1080.0)
	return vp.get_visible_rect().size


func _on_viewport_resized() -> void:
	if not is_inside_tree():
		return
	_apply_scale()


## Single place where EVERY pixel size / font size in the menu is set,
## all derived from UiScale base values x the viewport scale factor.
## Runs at build, on open, and on viewport resize.
func _apply_scale() -> void:
	if _panel == null:
		return
	var vp := _vp_size()
	var m := UiScale.panel_margin(vp)
	_panel.offset_left = m.x
	_panel.offset_right = -m.x
	_panel.offset_top = m.y
	_panel.offset_bottom = -m.y
	if _root_box != null:
		_root_box.add_theme_constant_override("separation", int(UiScale.scaled_size(8, vp)))
	if _content_box != null:
		_content_box.add_theme_constant_override("separation", int(UiScale.scaled_size(8, vp)))
	if _header_box != null:
		_header_box.add_theme_constant_override("separation", int(UiScale.scaled_size(12, vp)))
	if _title_label != null:
		StencilStyle.apply_title(_title_label, UiScale.scaled_font(26, vp), StencilStyle.ORANGE, 3)
	if _budget_label != null:
		StencilStyle.apply_body(_budget_label, UiScale.scaled_font(20, vp), StencilStyle.TEXT, 2)
	if _close_button != null:
		_close_button.custom_minimum_size = Vector2(UiScale.scaled_size(56, vp), UiScale.scaled_size(56, vp))
		_close_button.add_theme_font_size_override("font_size", UiScale.scaled_font(22, vp))
	if _spawn_label != null:
		StencilStyle.apply_body(_spawn_label, UiScale.scaled_font(20, vp), StencilStyle.ORANGE, 2)
	if _tabs != null:
		_tabs.custom_minimum_size = Vector2(0, UiScale.scaled_size(250, vp))
	if _make_title != null:
		StencilStyle.apply_title(_make_title, UiScale.scaled_font(22, vp), StencilStyle.GOLD, 3)
	if _make_explainer != null:
		StencilStyle.apply_body(_make_explainer, UiScale.scaled_font(17, vp), StencilStyle.TEXT_DIM, 2)
	if _make_input != null:
		_make_input.custom_minimum_size = Vector2(0, UiScale.scaled_size(56, vp))
		_make_input.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _make_button != null:
		_make_button.custom_minimum_size = Vector2(UiScale.scaled_size(200, vp), UiScale.scaled_size(56, vp))
		_make_button.add_theme_font_size_override("font_size", UiScale.scaled_font(22, vp))
	if _make_status != null:
		StencilStyle.apply_body(_make_status, UiScale.scaled_font(17, vp), StencilStyle.TEXT, 2)
	for grid in _grids:
		grid.add_theme_constant_override("h_separation", int(UiScale.scaled_size(10, vp)))
		grid.add_theme_constant_override("v_separation", int(UiScale.scaled_size(10, vp)))
	for b in _menu_buttons:
		b.custom_minimum_size = Vector2(0, UiScale.scaled_size(64, vp))
		b.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _prompt_row != null:
		_prompt_row.add_theme_constant_override("separation", int(UiScale.scaled_size(10, vp)))
	if _prompt_input != null:
		_prompt_input.custom_minimum_size = Vector2(0, UiScale.scaled_size(56, vp))
		_prompt_input.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _confirm_button != null:
		_confirm_button.custom_minimum_size = Vector2(UiScale.scaled_size(200, vp), UiScale.scaled_size(56, vp))
		_confirm_button.add_theme_font_size_override("font_size", UiScale.scaled_font(22, vp))
	if _mic_button != null:
		_mic_button.custom_minimum_size = Vector2(UiScale.scaled_size(96, vp), UiScale.scaled_size(56, vp))
		_mic_button.add_theme_font_size_override("font_size", UiScale.scaled_font(22, vp))
	if _preview_label != null:
		StencilStyle.apply_body(_preview_label, UiScale.scaled_font(19, vp), StencilStyle.ORANGE, 2)
	if _history_search_input != null:
		_history_search_input.custom_minimum_size = Vector2(0, UiScale.scaled_size(56, vp))
		_history_search_input.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _code_input != null:
		_code_input.custom_minimum_size = Vector2(0, UiScale.scaled_size(56, vp))
		_code_input.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	for _cb in [_code_build_button, _code_copy_button]:
		if _cb != null:
			(_cb as Button).custom_minimum_size = Vector2(UiScale.scaled_size(200, vp), UiScale.scaled_size(56, vp))
			(_cb as Button).add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _hist_title != null:
		StencilStyle.apply_body(_hist_title, UiScale.scaled_font(18, vp), StencilStyle.TEXT_DIM, 2)
	if _hist_scroll != null:
		_hist_scroll.custom_minimum_size = Vector2(0, UiScale.scaled_size(92, vp))
	if _history_list != null:
		_history_list.add_theme_constant_override("separation", int(UiScale.scaled_size(6, vp)))
		for child in _history_list.get_children():
			if child is Button:
				(child as Button).custom_minimum_size = Vector2(0, UiScale.scaled_size(48, vp))
				(child as Button).add_theme_font_size_override("font_size", UiScale.scaled_font(18, vp))
			elif child is Label:
				StencilStyle.apply_body(child as Label, UiScale.scaled_font(17, vp), StencilStyle.TEXT_DIM, 2)
	if _key_row != null:
		_key_row.add_theme_constant_override("separation", int(UiScale.scaled_size(10, vp)))
	if _key_label != null:
		StencilStyle.apply_body(_key_label, UiScale.scaled_font(18, vp), StencilStyle.TEXT_DIM, 2)
	if _key_input != null:
		_key_input.custom_minimum_size = Vector2(0, UiScale.scaled_size(56, vp))
		_key_input.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _save_key_button != null:
		_save_key_button.custom_minimum_size = Vector2(UiScale.scaled_size(180, vp), UiScale.scaled_size(56, vp))
		_save_key_button.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _clear_key_button != null:
		_clear_key_button.custom_minimum_size = Vector2(UiScale.scaled_size(140, vp), UiScale.scaled_size(56, vp))
		_clear_key_button.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _key_status != null:
		StencilStyle.apply_body(_key_status, UiScale.scaled_font(17, vp), StencilStyle.TEXT_DIM, 2)
	_scale_mods_rows(vp)
	if _footer_box != null:
		_footer_box.add_theme_constant_override("separation", int(UiScale.scaled_size(10, vp)))
	if _undo_button != null:
		_undo_button.custom_minimum_size = Vector2(UiScale.scaled_size(180, vp), UiScale.scaled_size(56, vp))
		_undo_button.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _toast_label != null:
		StencilStyle.apply_body(_toast_label, UiScale.scaled_font(18, vp), StencilStyle.TEXT, 2)


func _wire_forge() -> void:
	if _wired:
		return
	_wired = true
	var forge := _get_forge()
	if forge != null:
		if forge.has_signal("forge_result") and not forge.is_connected("forge_result", _on_forge_result):
			forge.connect("forge_result", _on_forge_result)
		if forge.has_signal("budget_changed") and not forge.is_connected("budget_changed", _on_budget_changed):
			forge.connect("budget_changed", _on_budget_changed)
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_signal("forge_budget_changed") and not game.is_connected("forge_budget_changed", _on_budget_changed):
		game.connect("forge_budget_changed", _on_budget_changed)


func _get_forge() -> Node:
	return get_node_or_null("/root/Forge")


# ------------------------------------------------------------------ API
func open() -> void:
	# Windows mouse capture: menu open -> cursor VISIBLE + erase mouse
	# bindings so menu clicks can't fire. (HUD's watchdog re-syncs the
	# mode + bindings every frame, so this is belt-and-braces for the
	# direct open() call.)
	MouseCapture.set_menu()
	MouseCapture.erase_mouse_bindings()
	visible = true
	_apply_scale()
	_wire_forge()
	_refresh_budget()
	_refresh_undo_visibility()
	_refresh_history()
	_refresh_key_status()
	_refresh_mods()
	_refresh_placed()
	_update_preview()
	# v0.5.1 FIX 6: NEVER grab focus on open — grabbing focus pops the
	# phone keyboard and routes WASD into the LineEdit. Re-assert
	# FOCUS_CLICK (in case anything reset it) and release any focus the
	# viewport currently holds, so no control has keyboard focus after open.
	_prompt_input.focus_mode = Control.FOCUS_CLICK
	var vp := get_viewport()
	if vp != null:
		var focused := vp.gui_get_focus_owner()
		if focused != null:
			focused.release_focus()
	_play("ui_click")


func close() -> void:
	# Windows mouse capture: menu closed (incl. the X button, which calls
	# close() directly) -> re-capture + restore mouse bindings. If pause
	# is open the HUD watchdog corrects the mode back to VISIBLE on its
	# next tick, and the bindings stay erased until pause closes.
	MouseCapture.set_gameplay()
	if not get_tree().paused:
		MouseCapture.restore_mouse_bindings()
	visible = false
	# Dismiss the keyboard if the prompt or key field held focus.
	if _prompt_input != null and _prompt_input.has_focus():
		_prompt_input.release_focus()
	if _key_input != null and _key_input.has_focus():
		_key_input.release_focus()
	if _make_input != null and _make_input.has_focus():
		_make_input.release_focus()
	if _code_input != null and _code_input.has_focus():
		_code_input.release_focus()
	if _history_search_input != null and _history_search_input.has_focus():
		_history_search_input.release_focus()
	_play("ui_click")


func is_open() -> bool:
	return visible


# ------------------------------------------------------------------ input
func _on_preset_pressed(prompt: String, _label_text: String) -> void:
	# Fill + preview; the user confirms with FORGE IT (cost before spend).
	_prompt_input.text = prompt
	_update_preview()
	_play("ui_click")
	_show_toast("Preset ready — press FORGE IT to confirm.")


func _on_prompt_text_changed(_new_text: String) -> void:
	_update_preview()


func _on_prompt_submitted(text: String) -> void:
	_submit_prompt(text)


func _on_confirm_pressed() -> void:
	_submit_prompt(_prompt_input.text)


func _on_mic_pressed() -> void:
	# Voice → transcript submits through the same _submit_prompt path
	# as typed input (cost preview / history / forge_result all apply).
	# No plugin or no mic permission → SpeechInput falls back to the
	# typed console + "Voice input isn't available yet" toast.
	if _speech == null:
		_speech = SpeechInput.new()
		_speech.name = "SpeechInput"
		add_child(_speech)
	_speech.listen(_on_voice_text, false)


func _on_voice_text(text: String) -> void:
	var transcript := text.strip_edges()
	if transcript.is_empty():
		_show_toast("Didn't catch that — type your prompt.")
		return
	_submit_prompt(transcript)


func _on_history_pressed(prompt: String) -> void:
	# History entries re-submit directly (the tap IS the confirm).
	_submit_prompt(prompt)


func _on_undo_pressed() -> void:
	var forge := _get_forge()
	if forge == null or not forge.has_method("undo_last"):
		_show_toast("Undo is not available yet.")
		return
	var result: Variant = forge.call("undo_last")
	var msg := ""
	if result is Dictionary:
		msg = str((result as Dictionary).get("message", ""))
		if msg.is_empty():
			msg = "Undone." if bool((result as Dictionary).get("ok", false)) else "Nothing to undo."
	else:
		msg = "Undone."
	_show_toast(msg)
	_refresh_budget()
	_refresh_history()
	_play("ui_click")


# ------------------------------------------------------------------ key
func _on_save_key_pressed(_text: String = "") -> void:
	var key := _key_input.text.strip_edges()
	if key.is_empty():
		_show_toast("Paste a key first — or CLEAR to go offline-only.")
		return
	ForgeConfig.save_key(key)
	_key_input.clear()
	_refresh_key_status()
	_show_toast("DeepSeek key saved on this device. Forge will use the LLM.")
	_play("ui_click")


func _on_clear_key_pressed() -> void:
	ForgeConfig.save_key("")
	_key_input.clear()
	_refresh_key_status()
	_show_toast("DeepSeek key cleared. Forge works offline.")
	_play("ui_click")


## Status reports present/absent ONLY — the key value is never shown.
func _refresh_key_status() -> void:
	if _key_status == null:
		return
	if ForgeConfig.load_key().is_empty():
		_key_status.text = "LLM: no key — Forge works offline."
	else:
		_key_status.text = "LLM: key saved — Forge uses DeepSeek."


# ------------------------------------------------------------------ submit
func _submit_prompt(text: String) -> void:
	var prompt := text.strip_edges()
	if prompt.is_empty():
		_show_toast("Enter a requisition first.")
		return
	var forge := _get_forge()
	if forge == null or not forge.has_method("submit_prompt"):
		_show_toast("Forge system offline.")
		return
	_record_local_history(prompt)
	# Structure prompts get a ghost preview instead of an instant
	# build (Forge batch item 2). _try_ghost_prompt returns true when
	# it took the prompt (menu closes, ghost shows); non-structure
	# prompts keep the instant path below.
	if _try_ghost_prompt(prompt):
		_prompt_input.clear()
		_update_preview()
		_refresh_history()
		return
	forge.submit_prompt(prompt)
	_prompt_input.clear()
	_update_preview()
	_refresh_history()
	# The real outcome arrives via forge_result; if the backend never
	# emits it (older build), still give immediate feedback.
	_show_toast("Command sent: %s" % prompt)


func _record_local_history(prompt: String) -> void:
	_local_history.erase(prompt)
	_local_history.push_front(prompt)
	while _local_history.size() > HISTORY_CAP:
		_local_history.pop_back()


# ------------------------------------------------------------------ v0.5.3 MAKE
# MAKE calls the EXISTING generation pipeline read-only:
# ModCreator.generate(single-box prompt) -> generation_ready(candidate).
# install() is NEVER called from this path — the candidate is applied
# in-session (blocks) or refused visibly (scripts / errors). No silent
# fallback to a preset, ever.
func _make_creator_instance() -> ModCreator:
	if _make_creator != null and is_instance_valid(_make_creator):
		return _make_creator
	_make_creator = ModCreator.new()
	_make_creator.generation_ready.connect(_on_make_generation_ready)
	add_child(_make_creator)
	return _make_creator


func _on_make_pressed(_text: String = "") -> void:
	if _make_generating:
		_show_make_status("Already making something — wait for it.")
		return
	var prompt := "" if _make_input == null else _make_input.text.strip_edges()
	if prompt.is_empty():
		_show_make_error("Type what you want to make first.")
		return
	var forge := _get_forge()
	if forge != null and forge.has_method("is_busy") and bool(forge.call("is_busy")):
		_show_make_error("Forge is busy fabricating — try again in a moment.")
		return
	var creator := _make_creator_instance()
	if creator == null:
		_show_make_error("MAKE unavailable — creator not found.")
		return
	_make_generating = true
	if _make_button != null:
		_make_button.disabled = true
	_show_make_status("Making… (this match only — nothing is saved)")
	# The single-box prompt goes to the pipeline VERBATIM — no form, no
	# composition, no preset substitution.
	creator.generate(prompt)


func _on_make_generation_ready(candidate: Dictionary) -> void:
	_make_generating = false
	if _make_button != null:
		_make_button.disabled = false
	if not (candidate is Dictionary):
		_show_make_error("MAKE failed: generation returned nothing.")
		return
	var err := str(candidate.get("error", ""))
	if not err.is_empty():
		_show_make_error("MAKE failed: " + err)
		return
	# Defense in depth: the pipeline already validated the candidate
	# before emitting it; re-check read-only before applying.
	var creator := _make_creator_instance()
	if creator != null:
		var verr := creator.validate(candidate)
		if not verr.is_empty():
			_show_make_error("MAKE failed: " + verr)
			return
	var kind := str(candidate.get("kind", ""))
	if kind == "script":
		# Session scope cannot run unsaved code: instantiating a script
		# mod needs its file on disk (ModLoader) or dynamic code loading
		# (blocked in scripts/forge/*). Visible error, no fallback.
		_show_make_error("MAKE can't run script mods in-session — custom code must be installed before it can run. Use CREATE A MOD in the main menu to install '" + str(candidate.get("name", "")) + "'. Nothing was saved.")
		return
	if kind != "block":
		_show_make_error("MAKE failed: unknown mod kind '%s'." % kind)
		return
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var root := get_tree().current_scene
	var result := ForgeSessionMake.apply_candidate(candidate, player, root)
	if bool(result.get("ok", false)):
		var msg := str(result.get("message", "Made."))
		_show_make_status(msg + " — this match only, not saved.")
		_show_toast(msg + " (MAKE: this match only)")
		_refresh_placed()
		_play("forge_success")
	else:
		_show_make_error("MAKE failed: " + str(result.get("message", "unknown error")))


func _show_make_status(text: String) -> void:
	if _make_status == null:
		return
	_make_status.text = text
	StencilStyle.apply_body(_make_status, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT, 2)


func _show_make_error(text: String) -> void:
	if _make_status == null:
		_show_toast(text)
		return
	_make_status.text = text
	StencilStyle.apply_body(_make_status, UiScale.scaled_font(17, _vp_size()), StencilStyle.RED, 2)
	_show_toast(text)
	_play("forge_fail")


# ------------------------------------------------------------------ ghost preview + placed structures (Forge batch item 2)

## Try to route a structure prompt through the ghost preview:
## parse offline, show the ghost, close the menu. True when the ghost
## took the prompt. The spec's position is filled from the ghost at
## confirm time; the build then goes through the manager (history +
## MP sync + undo), never straight to the builder.
func _try_ghost_prompt(prompt: String) -> bool:
	var spec: Dictionary = ForgeLLM.parse_offline(prompt)
	if spec.is_empty() or str(spec.get("target", "")) != "structure":
		return false
	# v0.5.7 Part B: a LABELED approximation ("Closest I can build:
	# ...") is stripped before the ghost path — the strict gate rejects
	# unknown top-level keys — and shown as a toast NOW, so the ghost
	# preview of the substitute shape is explicitly labeled.
	var approx_note := ""
	if spec.has("_approximation"):
		approx_note = str(spec["_approximation"])
		spec.erase("_approximation")
	var params: Dictionary = spec.get("params", {})
	var shape := str(params.get("shape", ""))
	if shape.is_empty():
		return false
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var root := get_tree().current_scene
	if player == null or root == null:
		return false
	var placement := ForgePlacement.attach_to(root)
	if placement == null or not placement.start_preview(shape, params, player, root):
		return false
	_pending_ghost_spec = spec.duplicate(true)
	if not approx_note.is_empty():
		_show_toast(approx_note + " Place it with INTERACT.")
	if not placement.is_connected("preview_confirm_requested", _on_ghost_confirm_requested):
		placement.connect("preview_confirm_requested", _on_ghost_confirm_requested)
	if not placement.is_connected("preview_cancelled", _on_ghost_cancelled):
		placement.connect("preview_cancelled", _on_ghost_cancelled)
	close()
	return true


## Ghost confirm (interact key): build the pending spec at the ghost
## position through the manager. The placement node clears its own
## ghost before the build runs.
func _on_ghost_confirm_requested(pos: Vector3) -> void:
	var spec := _pending_ghost_spec
	_pending_ghost_spec = {}
	if spec.is_empty():
		return
	var params: Dictionary = spec.get("params", {})
	params["position"] = [pos.x, pos.y, pos.z]
	spec["params"] = params
	var root := get_tree().current_scene
	if root != null:
		var placement := ForgePlacement.attach_to(root)
		if placement != null:
			placement.cancel_preview()
	var forge := _get_forge()
	if forge != null and forge.has_method("build_spec_direct"):
		forge.call("build_spec_direct", spec)
	_show_toast("Structure placed.")


## Ghost cancel (ESC): reopen the Forge menu.
func _on_ghost_cancelled() -> void:
	_pending_ghost_spec = {}
	open()


## Rebuild the PLACED STRUCTURES list from group "forge_structure".
func _refresh_placed() -> void:
	if _placed_list == null:
		return
	for c in _placed_list.get_children():
		c.queue_free()
	var structures := get_tree().get_nodes_in_group("forge_structure")
	for node in structures:
		var row := HBoxContainer.new()
		var shape := str(node.get("structure_shape"))
		if shape.is_empty():
			shape = str(node.get_meta("shape", "structure"))
		var lbl := Label.new()
		lbl.text = "%s  (%d / %d HP)" % [shape, ForgeStructure.hp_of(node), ForgeStructure.max_hp_of(node)]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		for action in ["MOVE", "ROTATE", "REPAIR", "DELETE"]:
			var b := Button.new()
			b.text = action
			StencilStyle.style_button(b)
			match action:
				"MOVE":
					b.pressed.connect(_on_placed_move.bind(node))
				"ROTATE":
					b.pressed.connect(_on_placed_rotate.bind(node))
				"REPAIR":
					b.pressed.connect(_on_placed_repair.bind(node))
				"DELETE":
					b.pressed.connect(_on_placed_delete.bind(node))
			row.add_child(b)
		_placed_list.add_child(row)


func _on_placed_move(node: Node) -> void:
	if not is_instance_valid(node):
		return
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var root := get_tree().current_scene
	if player == null or root == null:
		return
	var placement := ForgePlacement.attach_to(root)
	if placement != null and placement.start_move_preview(node, player, root):
		if not placement.is_connected("preview_cancelled", _on_ghost_cancelled):
			placement.connect("preview_cancelled", _on_ghost_cancelled)
		close()


func _on_placed_rotate(node: Node) -> void:
	if not is_instance_valid(node):
		return
	ForgePlacement.rotate_structure(node, 45.0)
	_show_toast("Rotated 45°.")
	_refresh_placed()


func _on_placed_repair(node: Node) -> void:
	if not is_instance_valid(node):
		return
	ForgePlacement.repair_structure(node)
	_show_toast("Structure repaired.")
	_refresh_placed()


func _on_placed_delete(node: Node) -> void:
	if not is_instance_valid(node):
		return
	ForgePlacement.delete_structure(node)
	_show_toast("Structure deleted.")
	_refresh_placed()


func _on_history_search_changed(_new_text: String) -> void:
	_refresh_history()


func _on_code_build_submitted(_text: String) -> void:
	_on_code_build_pressed()


func _on_code_build_pressed() -> void:
	var forge := _get_forge()
	if forge == null or not forge.has_method("build_from_code"):
		_show_toast("Build codes unavailable.")
		return
	var code := ""
	if _code_input != null:
		code = _code_input.text.strip_edges()
	if code.is_empty():
		_show_toast("Paste a build code first.")
		return
	forge.call("build_from_code", code)
	_play("ui_click")


func _on_code_copy_pressed() -> void:
	var forge := _get_forge()
	var code := ""
	if forge != null and forge.has_method("get_last_build_code"):
		code = str(forge.call("get_last_build_code"))
	if code.is_empty():
		_show_toast("No build to copy yet — forge something first.")
		return
	DisplayServer.clipboard_set(code)
	if _code_input != null:
		_code_input.text = code
	_show_toast("Build code copied to clipboard.")
	_play("ui_click")


# ------------------------------------------------------------------ refresh
func _refresh_budget() -> void:
	# Directive A: the budget label stays HIDDEN while budget
	# enforcement is off. The text is still refreshed behind the scenes
	# so flipping the manager's BUDGET_ENABLED back on only needs the
	# visibility flip in _build.
	var forge := _get_forge()
	var amount := -1
	if forge != null and forge.has_method("get_budget"):
		amount = int(forge.call("get_budget"))
	if amount >= 0:
		_budget_label.text = "BUDGET: %d" % amount
	else:
		_budget_label.text = "BUDGET: —"
	_budget_label.visible = false


func _refresh_undo_visibility() -> void:
	var forge := _get_forge()
	_undo_button.visible = forge != null and forge.has_method("undo_last")


func _refresh_history() -> void:
	for child in _history_list.get_children():
		child.queue_free()
	var query := "" if _history_search_input == null else _history_search_input.text.strip_edges()
	var entries: Array[String] = []
	var forge := _get_forge()
	if forge != null and forge.has_method("search_history"):
		var raw: Variant = forge.call("search_history", query)
		if raw is Array:
			for item in raw:
				entries.append(str(item))
	elif forge != null and forge.has_method("get_history"):
		var raw: Variant = forge.call("get_history")
		if raw is Array:
			for item in raw:
				entries.append(str(item))
		entries = _filter_history(entries, query)
	else:
		entries = _filter_history(_local_history.duplicate(), query)
	if entries.is_empty():
		var empty := Label.new()
		StencilStyle.apply_body(empty, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
		empty.text = "No recent requisitions yet."
		_history_list.add_child(empty)
		return
	for entry in entries:
		if entry.is_empty():
			continue
		var b := Button.new()
		b.text = entry
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, UiScale.scaled_size(48, _vp_size()))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		StencilStyle.style_button(b)
		b.add_theme_font_size_override("font_size", UiScale.scaled_font(18, _vp_size()))
		b.set_meta("forge_prompt", entry)
		b.pressed.connect(_on_history_pressed.bind(entry))
		_history_list.add_child(b)


## Local history filter (fallback when the backend has no
## search_history): case-insensitive substring. "" = everything.
func _filter_history(entries: Array[String], query: String) -> Array[String]:
	var q := query.strip_edges().to_lower()
	if q.is_empty():
		return entries
	var out: Array[String] = []
	for entry in entries:
		if entry.to_lower().contains(q):
			out.append(entry)
	return out


func _update_preview() -> void:
	var prompt := _prompt_input.text.strip_edges()
	var forge := _get_forge()
	if prompt.is_empty() or forge == null or not forge.has_method("preview_cost"):
		_preview_label.text = "COST: —"
		return
	var raw: Variant = forge.call("preview_cost", prompt)
	if not (raw is Dictionary):
		_preview_label.text = "COST: —"
		return
	var d := raw as Dictionary
	if bool(d.get("ok", false)):
		# Directive A: cost computed + shown, but building is free.
		_preview_label.text = "COST: %d (free)" % int(d.get("cost", 0))
		# v0.5.7 Part B: a LABELED approximation ("Closest I can
		# build: ...") shows in the preview BEFORE the player confirms,
		# so an approximation is never a surprise at build time.
		var approx := str(d.get("approximation", ""))
		if not approx.is_empty():
			_preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_preview_label.text += " — " + approx
	else:
		var err := str(d.get("error", ""))
		_preview_label.text = "COST: —  %s" % err if not err.is_empty() else "COST: —"


# ------------------------------------------------------------------ signals
func _on_forge_result(success: bool, message: String) -> void:
	_show_toast(message)
	_refresh_budget()
	_refresh_history()
	_play("forge_success" if success else "forge_fail")


func _on_budget_changed(_amount: int) -> void:
	_refresh_budget()


func _show_toast(text: String) -> void:
	_toast_label.text = text
	_toast_t = TOAST_HOLD_SEC


## Public wrapper for _show_toast so other systems (e.g. SpeechInput's
## voice-unavailable notice) can reuse the menu's visible feedback without
## reaching into a private method.
func show_feedback(text: String) -> void:
	_show_toast(text)


func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast_label.text = DEFAULT_TOAST


func _play(id: String) -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d(id)


# ------------------------------------------------------------------ v0.6 LOADOUTS
const LOADOUT_PRESETS := {
	"Assault": ["ar7", "p9"],
	"Marksman": ["lr8", "p9"],
	"Breacher": ["sg12", "smg9"],
	"Raptor": ["raptor", "smg9"],
	# Goal 3 CONTENT: burst rifle + heavy revolver.
	"Burst": ["br3", "hv44"],
}


func _build_loadouts_tab() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Loadouts"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	_grids.append(grid)
	for loadout_name in LOADOUT_PRESETS:
		var preset: Array = LOADOUT_PRESETS[loadout_name]
		var b := Button.new()
		b.name = "Loadout_" + loadout_name
		b.text = loadout_name.to_upper()
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		StencilStyle.style_button(b)
		b.pressed.connect(_on_loadout_pressed.bind(loadout_name, str(preset[0]), str(preset[1])))
		grid.add_child(b)
		_menu_buttons.append(b)


func _on_loadout_pressed(loadout_name: String, primary_id: String, secondary_id: String) -> void:
	var wm := _get_weapon_manager()
	if wm == null or not wm.has_method("equip_loadout"):
		_show_toast("Loadouts unavailable.")
		return
	wm.call("equip_loadout", primary_id, secondary_id)
	_show_toast("%s loadout equipped — free." % loadout_name)
	_play("ui_click")


func _get_weapon_manager() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var nodes := tree.get_nodes_in_group("weapon_manager")
	if nodes.is_empty():
		return null
	return nodes[0]


# ------------------------------------------------------------------ v0.7 MODS
# 6th tab: lists installed user mods from ModLoader (Worker A:
# scripts/mods/mod_loader.gd, class_name ModLoader). The loader is
# resolved via ResourceLoader + load() — NOT a hard class reference — so
# this menu still parses and opens when the loader file is absent (fresh
# checkout, loader not landed yet): the tab then shows an unavailable
# note instead of breaking the whole Forge menu.
# Interface (exact, per the v0.7 chunk-1 contract):
#   ModLoader.get_mods() -> Array of Dictionaries
#     {id, name, kind ["block"/"script"], version, author, enabled, error, path}
#   ModLoader.set_mod_enabled(mod_id: String, enabled: bool) -> void
#   ModLoader.rescan() -> void

const MOD_LOADER_PATH := "res://scripts/mods/mod_loader.gd"


func _build_mods_tab() -> void:
	# NOTE: NO outer ScrollContainer here (mirrors the creator-menu fix):
	# a wrapping ScrollContainer sizes this VBox to its content minimum,
	# which leaves the EXPAND list ScrollContainer at 0px tall — an
	# invisible list. The mod list itself scrolls (ModsScroll), and this
	# box is the direct TabContainer child so it gets the full tab area.
	# The box is named "Mods" (not "ModsBox") so the tab keeps its
	# existing name/title — verify_v07_b asserts the 6 tab child names.
	var box := VBoxContainer.new()
	box.name = "Mods"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(box)
	_mods_tab_idx = _tabs.get_tab_count() - 1
	_tabs.set_tab_title(_mods_tab_idx, "Mods")
	if not _tabs.tab_changed.is_connected(_on_tab_changed):
		_tabs.tab_changed.connect(_on_tab_changed)
	# Where to drop mods (user://mods/ == OS.get_user_data_dir() + "/mods").
	_mods_path_label = Label.new()
	_mods_path_label.name = "ModsPathLabel"
	_mods_path_label.text = "Mods folder: " + OS.get_user_data_dir() + "/mods"
	_mods_path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_mods_path_label, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
	box.add_child(_mods_path_label)
	var rescan_row := HBoxContainer.new()
	rescan_row.name = "ModsRescanRow"
	box.add_child(rescan_row)
	_mods_rescan_button = Button.new()
	_mods_rescan_button.name = "ModsRescanButton"
	_mods_rescan_button.text = "RESCAN"
	StencilStyle.style_button(_mods_rescan_button)
	_mods_rescan_button.pressed.connect(_on_mods_rescan_pressed)
	rescan_row.add_child(_mods_rescan_button)
	var hint := Label.new()
	hint.name = "ModsHintLabel"
	hint.text = "Drop a mod folder in, then Rescan."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# EXPAND_FILL is REQUIRED (creator-menu fix): without it the HBox
	# gives this autowrap label its minimum size (1px wide, ~1617px
	# tall wrapped), rendering one character per line and squeezing
	# the mod list to 0px tall. It was already present here — kept.
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(hint, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
	rescan_row.add_child(hint)
	# Create-Mod lives in the standalone Mod Creator menu (main menu -> CREATE A MOD).
	_mods_scroll = ScrollContainer.new()
	_mods_scroll.name = "ModsScroll"
	_mods_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_mods_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_mods_scroll)
	_mods_list = VBoxContainer.new()
	_mods_list.name = "ModsList"
	_mods_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mods_scroll.add_child(_mods_list)
	_refresh_mods()


## Rebuilds the mod rows from ModLoader.get_mods(). Called on open, on
## switching to the Mods tab, after toggle, and after rescan.
func _refresh_mods() -> void:
	if _mods_list == null:
		return
	# remove_child FIRST: queue_free() alone is deferred, so a stale row
	# would still occupy its name when the rebuild adds a same-named row
	# and Godot would auto-rename the new one (@Label@N). Removing the
	# child frees the name immediately; the deferred free keeps a toggle
	# button emitting `pressed` alive until its emission finishes.
	for child in _mods_list.get_children():
		_mods_list.remove_child(child)
		child.queue_free()
	_mods_rows.clear()
	var mods_path := OS.get_user_data_dir() + "/mods"
	if _mods_path_label != null:
		_mods_path_label.text = "Mods folder: " + mods_path
	var loader := _mod_loader_script()
	if loader == null:
		_add_mods_note("ModsEmptyLabel", "Mod system unavailable — no mod loader found.")
		return
	var mods: Variant = _mod_call(loader, "get_mods", [])
	if not (mods is Array):
		_add_mods_note("ModsEmptyLabel", "Mod system unavailable — could not list mods.")
		return
	if (mods as Array).is_empty():
		_add_mods_note("ModsEmptyLabel",
			"No mods installed — drop a mod folder into %s and tap Rescan." % mods_path)
		return
	var idx := 0
	for m in mods:
		if m is Dictionary:
			_add_mod_row(m as Dictionary, idx)
			idx += 1


func _add_mods_note(node_name: String, text: String) -> void:
	var lbl := Label.new()
	lbl.name = node_name
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(lbl, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
	_mods_list.add_child(lbl)


func _add_mod_row(mod: Dictionary, idx: int) -> void:
	var mod_id := str(mod.get("id", ""))
	var enabled := bool(mod.get("enabled", false))
	var error := str(mod.get("error", ""))
	var wrap := VBoxContainer.new()
	wrap.name = "ModRow_%d" % idx
	_mods_list.add_child(wrap)
	_mods_rows.append(wrap)
	var row := HBoxContainer.new()
	row.name = "ModRow"
	wrap.add_child(row)
	var name_lbl := Label.new()
	name_lbl.name = "ModName"
	name_lbl.text = str(mod.get("name", mod_id if not mod_id.is_empty() else "unknown"))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(name_lbl, UiScale.scaled_font(19, _vp_size()), StencilStyle.TEXT, 2)
	row.add_child(name_lbl)
	var kind_lbl := Label.new()
	kind_lbl.name = "ModKind"
	kind_lbl.text = "Script" if str(mod.get("kind", "")) == "script" else "Block"
	StencilStyle.apply_body(kind_lbl, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
	row.add_child(kind_lbl)
	var status_lbl := Label.new()
	status_lbl.name = "ModStatus"
	status_lbl.text = "ENABLED" if enabled else "DISABLED"
	StencilStyle.apply_body(status_lbl, UiScale.scaled_font(17, _vp_size()),
		StencilStyle.GREEN if enabled else StencilStyle.TEXT_DIM, 2)
	row.add_child(status_lbl)
	var toggle := Button.new()
	toggle.name = "ModToggle"
	toggle.text = "DISABLE" if enabled else "ENABLE"
	StencilStyle.style_button(toggle)
	toggle.pressed.connect(_on_mod_toggle.bind(mod_id, not enabled))
	row.add_child(toggle)
	if not error.is_empty():
		var err_lbl := Label.new()
		err_lbl.name = "ModError"
		err_lbl.text = "Error: " + error
		err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		StencilStyle.apply_body(err_lbl, UiScale.scaled_font(16, _vp_size()), StencilStyle.RED, 2)
		wrap.add_child(err_lbl)


func _on_tab_changed(tab: int) -> void:
	# Refresh on entry so mods dropped in since the menu opened show up
	# without the user hunting for Rescan (Rescan still picks up files
	# the loader hasn't seen, and stays the explicit refresh path).
	if tab == _mods_tab_idx:
		_refresh_mods()


func _on_mods_rescan_pressed() -> void:
	var loader := _mod_loader_script()
	if loader == null:
		_show_toast("Mod system unavailable.")
		return
	_mod_call(loader, "rescan", [])
	_refresh_mods()
	_show_toast("Mods rescanned.")
	_play("ui_click")


func _on_mod_toggle(mod_id: String, enable: bool) -> void:
	var loader := _mod_loader_script()
	if loader == null:
		_show_toast("Mod system unavailable.")
		return
	_mod_call(loader, "set_mod_enabled", [mod_id, enable])
	_refresh_mods()
	_play("ui_click")


## The ModLoader GDScript, or null when its file is not present.
func _mod_loader_script() -> GDScript:
	if not ResourceLoader.exists(MOD_LOADER_PATH):
		return null
	return load(MOD_LOADER_PATH) as GDScript


## Calls a ModLoader method per the chunk-1 contract. The contract calls
## the methods on the class (static), but a worker may land them as
## instance methods instead — the script method flags say which, so the
## call goes to the class for static methods and to a fresh instance
## otherwise. Synchronous either way; a Node instance is freed after.
func _mod_call(loader: GDScript, method: String, args: Array) -> Variant:
	if loader == null:
		return null
	var is_static := true
	var found := false
	for m in loader.get_script_method_list():
		if str(m.get("name", "")) == method:
			found = true
			# METHOD_FLAG_STATIC == 32 (Godot 4 method flags).
			is_static = (int(m.get("flags", 0)) & 32) != 0
			break
	if not found:
		# Loader present but broken / mid-landing (parse errors leave the
		# method list empty): treat as unavailable, never callv into it.
		return null
	if is_static:
		return loader.callv(method, args)
	var inst: Object = loader.new()
	var result: Variant = inst.callv(method, args)
	if inst is Node:
		(inst as Node).free()
	return result


## Re-applies UiScale sizes/fonts to the (rebuilt) mod rows. Colors are
## set at row build time (status green/dim, error red) and left alone
## here so a rescale never clobbers them.
func _scale_mods_rows(vp: Vector2) -> void:
	if _mods_rescan_button != null:
		_mods_rescan_button.custom_minimum_size = Vector2(UiScale.scaled_size(180, vp), UiScale.scaled_size(56, vp))
		_mods_rescan_button.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _mods_list == null:
		return
	for wrap in _mods_rows:
		if not is_instance_valid(wrap):
			continue
		for child in wrap.get_children():
			if child is HBoxContainer:
				for cell in (child as HBoxContainer).get_children():
					if cell is Button:
						(cell as Button).custom_minimum_size = Vector2(UiScale.scaled_size(140, vp), UiScale.scaled_size(56, vp))
						(cell as Button).add_theme_font_size_override("font_size", UiScale.scaled_font(18, vp))
					elif cell is Label and (cell as Label).name == "ModName":
						(cell as Label).add_theme_font_size_override("font_size", UiScale.scaled_font(19, vp))
					elif cell is Label:
						(cell as Label).add_theme_font_size_override("font_size", UiScale.scaled_font(17, vp))
			elif child is Label and (child as Label).name == "ModError":
				(child as Label).add_theme_font_size_override("font_size", UiScale.scaled_font(16, vp))


