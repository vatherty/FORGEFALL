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
	],
	"Weapons": [
		["Sniper", "Give me a sniper rifle"],
		["Shotgun", "Give me a shotgun"],
		["SMG", "Give me an smg"],
		["Assault Rifle", "Give me an assault rifle"],
		["LMG", "Give me a machine gun"],
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
var _undo_button: Button
var _toast_label: Label
var _key_input: LineEdit
var _key_status: Label
var _toast_t := 0.0
var _local_history: Array[String] = []
var _wired := false
var _mic_button: Button
var _speech: SpeechInput
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
# v0.8 CREATE MOD: one panel + approval area inside the Mods tab.
# Generation/validation NEVER write anything; install() (Worker A's
# ModCreator) is the only write path and runs only on the Install tap.
var _mods_create_button: Button
var _create_panel: VBoxContainer
var _create_idea_input: LineEdit
var _create_generate_button: Button
var _create_regenerate_button: Button
var _create_close_button: Button
var _create_status: Label
var _approval_panel: VBoxContainer
var _approval_summary: Label
var _approval_code: TextEdit
var _approval_status: Label
var _approval_install_button: Button
var _approval_discard_button: Button
var _approval_regenerate_button: Button
var _mod_creator: Object
var _pending_candidate: Dictionary = {}
var _pending_idea: String = ""
var _create_generating := false


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
	_preview_label = Label.new()
	_preview_label.name = "PreviewLabel"
	_preview_label.text = "COST: —"
	content.add_child(_preview_label)

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
	if _tabs != null:
		_tabs.custom_minimum_size = Vector2(0, UiScale.scaled_size(250, vp))
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
	if _create_idea_input != null and _create_idea_input.has_focus():
		_create_idea_input.release_focus()
	# v0.8: never leak a pending candidate across menu sessions — the
	# approval panel hides and the candidate is dropped, uninstalled.
	_clear_create_mod_state()
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


# ------------------------------------------------------------------ refresh
func _refresh_budget() -> void:
	var forge := _get_forge()
	var amount := -1
	if forge != null and forge.has_method("get_budget"):
		amount = int(forge.call("get_budget"))
	if amount >= 0:
		_budget_label.text = "BUDGET: %d" % amount
	else:
		_budget_label.text = "BUDGET: —"


func _refresh_undo_visibility() -> void:
	var forge := _get_forge()
	_undo_button.visible = forge != null and forge.has_method("undo_last")


func _refresh_history() -> void:
	for child in _history_list.get_children():
		child.queue_free()
	var entries: Array[String] = []
	var forge := _get_forge()
	if forge != null and forge.has_method("get_history"):
		var raw: Variant = forge.call("get_history")
		if raw is Array:
			for item in raw:
				entries.append(str(item))
	else:
		entries = _local_history.duplicate()
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
		_preview_label.text = "COST: %d" % int(d.get("cost", 0))
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
	var scroll := ScrollContainer.new()
	scroll.name = "Mods"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	_mods_tab_idx = _tabs.get_tab_count() - 1
	if not _tabs.tab_changed.is_connected(_on_tab_changed):
		_tabs.tab_changed.connect(_on_tab_changed)
	var box := VBoxContainer.new()
	box.name = "ModsBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
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
	# v0.8 CREATE MOD: opens the idea -> generate -> approval flow below.
	_mods_create_button = Button.new()
	_mods_create_button.name = "ModsCreateModButton"
	_mods_create_button.text = "CREATE MOD"
	StencilStyle.style_button(_mods_create_button)
	_mods_create_button.pressed.connect(_on_create_mod_pressed)
	rescan_row.add_child(_mods_create_button)
	var hint := Label.new()
	hint.name = "ModsHintLabel"
	hint.text = "Drop a mod folder in, then Rescan."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(hint, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
	rescan_row.add_child(hint)
	# v0.8 CREATE MOD panel (hidden until CREATE MOD is tapped).
	_create_panel = VBoxContainer.new()
	_create_panel.name = "CreateModPanel"
	_create_panel.visible = false
	box.add_child(_create_panel)
	var create_title := Label.new()
	create_title.name = "CreateModTitle"
	create_title.text = "CREATE MOD — describe it, review the code, then Install."
	create_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(create_title, UiScale.scaled_font(18, _vp_size()), StencilStyle.TEXT, 2)
	_create_panel.add_child(create_title)
	_create_idea_input = LineEdit.new()
	_create_idea_input.name = "CreateModIdeaInput"
	_create_idea_input.placeholder_text = "Describe your mod idea… e.g. a railgun that fires explosive rounds"
	_create_idea_input.clear_button_enabled = true
	_create_idea_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_create_idea_input)
	# Same focus rule as the prompt field: keyboard only on tap.
	_create_idea_input.focus_mode = Control.FOCUS_CLICK
	_create_idea_input.text_submitted.connect(_on_create_generate_submitted)
	_create_panel.add_child(_create_idea_input)
	var create_btn_row := HBoxContainer.new()
	create_btn_row.name = "CreateModButtonRow"
	_create_panel.add_child(create_btn_row)
	_create_generate_button = Button.new()
	_create_generate_button.name = "CreateModGenerateButton"
	_create_generate_button.text = "GENERATE"
	StencilStyle.style_button(_create_generate_button)
	_create_generate_button.pressed.connect(_on_create_generate_pressed)
	create_btn_row.add_child(_create_generate_button)
	_create_regenerate_button = Button.new()
	_create_regenerate_button.name = "CreateModRegenerateButton"
	_create_regenerate_button.text = "REGENERATE"
	_create_regenerate_button.visible = false
	StencilStyle.style_button(_create_regenerate_button)
	_create_regenerate_button.pressed.connect(_on_create_regenerate_pressed)
	create_btn_row.add_child(_create_regenerate_button)
	_create_close_button = Button.new()
	_create_close_button.name = "CreateModCloseButton"
	_create_close_button.text = "CLOSE"
	StencilStyle.style_button(_create_close_button)
	_create_close_button.pressed.connect(_on_create_close_pressed)
	create_btn_row.add_child(_create_close_button)
	_create_status = Label.new()
	_create_status.name = "CreateModStatus"
	_create_status.text = ""
	_create_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_create_status, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
	_create_panel.add_child(_create_status)
	# v0.8 APPROVAL panel: plain-language summary + FULL generated code
	# (scrollable, read-only) + Install / Discard / Regenerate. Nothing
	# is installed until the Install tap.
	_approval_panel = VBoxContainer.new()
	_approval_panel.name = "CreateModApprovalPanel"
	_approval_panel.visible = false
	box.add_child(_approval_panel)
	var approval_title := Label.new()
	approval_title.name = "ApprovalTitle"
	approval_title.text = "REVIEW — nothing is installed until you tap Install."
	approval_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(approval_title, UiScale.scaled_font(18, _vp_size()), StencilStyle.ORANGE, 2)
	_approval_panel.add_child(approval_title)
	_approval_summary = Label.new()
	_approval_summary.name = "ApprovalSummary"
	_approval_summary.text = ""
	_approval_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_summary, UiScale.scaled_font(18, _vp_size()), StencilStyle.TEXT, 2)
	_approval_panel.add_child(_approval_summary)
	_approval_code = TextEdit.new()
	_approval_code.name = "ApprovalCode"
	_approval_code.editable = false
	_approval_code.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_approval_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_approval_code.custom_minimum_size = Vector2(0, UiScale.scaled_size(240, _vp_size()))
	_approval_panel.add_child(_approval_code)
	_approval_status = Label.new()
	_approval_status.name = "ApprovalStatus"
	_approval_status.text = ""
	_approval_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_status, UiScale.scaled_font(17, _vp_size()), StencilStyle.RED, 2)
	_approval_panel.add_child(_approval_status)
	var approval_btn_row := HBoxContainer.new()
	approval_btn_row.name = "ApprovalButtonRow"
	_approval_panel.add_child(approval_btn_row)
	_approval_install_button = Button.new()
	_approval_install_button.name = "ApprovalInstallButton"
	_approval_install_button.text = "INSTALL"
	StencilStyle.style_button(_approval_install_button)
	_approval_install_button.pressed.connect(_on_approval_install_pressed)
	approval_btn_row.add_child(_approval_install_button)
	_approval_discard_button = Button.new()
	_approval_discard_button.name = "ApprovalDiscardButton"
	_approval_discard_button.text = "DISCARD"
	StencilStyle.style_button(_approval_discard_button)
	_approval_discard_button.pressed.connect(_on_approval_discard_pressed)
	approval_btn_row.add_child(_approval_discard_button)
	_approval_regenerate_button = Button.new()
	_approval_regenerate_button.name = "ApprovalRegenerateButton"
	_approval_regenerate_button.text = "REGENERATE"
	StencilStyle.style_button(_approval_regenerate_button)
	_approval_regenerate_button.pressed.connect(_on_approval_regenerate_pressed)
	approval_btn_row.add_child(_approval_regenerate_button)
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
	# v0.8 CREATE MOD + approval controls scale with the rest of the menu.
	if _mods_create_button != null:
		_mods_create_button.custom_minimum_size = Vector2(UiScale.scaled_size(200, vp), UiScale.scaled_size(56, vp))
		_mods_create_button.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _create_idea_input != null:
		_create_idea_input.custom_minimum_size = Vector2(0, UiScale.scaled_size(56, vp))
		_create_idea_input.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	for _cb in [_create_generate_button, _create_regenerate_button, _create_close_button,
			_approval_install_button, _approval_discard_button, _approval_regenerate_button]:
		if _cb != null:
			(_cb as Button).custom_minimum_size = Vector2(UiScale.scaled_size(180, vp), UiScale.scaled_size(56, vp))
			(_cb as Button).add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _create_status != null:
		_create_status.add_theme_font_size_override("font_size", UiScale.scaled_font(17, vp))
	if _approval_summary != null:
		_approval_summary.add_theme_font_size_override("font_size", UiScale.scaled_font(18, vp))
	if _approval_code != null:
		_approval_code.custom_minimum_size = Vector2(0, UiScale.scaled_size(240, vp))
		_approval_code.add_theme_font_size_override("font_size", UiScale.scaled_font(17, vp))
	if _approval_status != null:
		_approval_status.add_theme_font_size_override("font_size", UiScale.scaled_font(17, vp))
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


# ------------------------------------------------------------------ v0.8 CREATE MOD
# Idea -> Generate -> approval (summary + FULL code) -> Install/Discard.
# The ModCreator script (Worker A: scripts/mods/mod_creator.gd) is loaded
# the same defensive way as ModLoader — no hard class reference — so this
# menu still parses and opens when the creator has not landed yet: the
# panel then reports creation unavailable instead of breaking the menu.
# Contract (exact, per the v0.8 chunk-2 spec):
#   generate(idea: String) -> void, async, emits generation_ready(candidate)
#   install(candidate: Dictionary) -> String ("" = OK, else error)
#   candidate = {mod_id, name, kind ["block"/"script"], manifest,
#                payload (JSON block text or GDScript source),
#                summary (plain-language), error ("" when valid)}
# install() is the ONLY write path in this flow; generation and
# validation alone write nothing, and Install is the only call site.

const MOD_CREATOR_PATH := "res://scripts/mods/mod_creator.gd"


func _on_create_mod_pressed() -> void:
	if _create_panel == null:
		return
	var show := not _create_panel.visible
	_create_panel.visible = show
	if not show:
		# Hiding the create panel drops any pending approval too — the
		# candidate is only meaningful inside this flow.
		_clear_create_candidate()
	elif _create_status != null and _create_status.text.is_empty():
		_create_status.text = "Describe your mod idea, then tap GENERATE."
	_play("ui_click")


func _on_create_close_pressed() -> void:
	if _create_panel != null:
		_create_panel.visible = false
	_clear_create_candidate()
	_play("ui_click")


func _on_create_generate_submitted(_text: String) -> void:
	_on_create_generate_pressed()


func _on_create_generate_pressed() -> void:
	var idea := ""
	if _create_idea_input != null:
		idea = _create_idea_input.text.strip_edges()
	if idea.is_empty():
		if _create_status != null:
			_create_status.text = "Describe your mod idea first."
		return
	_pending_idea = idea
	_start_generation(idea)
	_play("ui_click")


func _on_create_regenerate_pressed() -> void:
	var idea := _pending_idea
	if idea.is_empty() and _create_idea_input != null:
		idea = _create_idea_input.text.strip_edges()
		_pending_idea = idea
	if idea.is_empty():
		if _create_status != null:
			_create_status.text = "Describe your mod idea first."
		return
	_start_generation(idea)
	_play("ui_click")


## Disables Generate, hides any stale approval, and fires the async
## generation. The result arrives via _on_generation_ready.
func _start_generation(idea: String) -> void:
	if _create_generating:
		return
	var creator := _mod_creator_instance()
	if creator == null or not creator.has_method("generate"):
		if _create_status != null:
			_create_status.text = "Mod creation unavailable — creator not found."
		return
	_create_generating = true
	if _create_generate_button != null:
		_create_generate_button.disabled = true
	if _create_regenerate_button != null:
		_create_regenerate_button.visible = false
	if _approval_panel != null:
		_approval_panel.visible = false
	if _create_status != null:
		_create_status.text = "Generating…"
	creator.callv("generate", [idea])


func _on_generation_ready(candidate: Dictionary) -> void:
	_create_generating = false
	if _create_generate_button != null:
		_create_generate_button.disabled = false
	var err := str(candidate.get("error", ""))
	if not err.is_empty():
		# Error path: nothing is installed, the stale approval (if any)
		# stays hidden, and REGENERATE re-runs for the same idea.
		_pending_candidate = {}
		if _approval_panel != null:
			_approval_panel.visible = false
		if _create_status != null:
			_create_status.text = "Generation failed: " + err
		if _create_regenerate_button != null:
			_create_regenerate_button.visible = true
		_show_toast("Mod generation failed — nothing installed.")
		return
	_pending_candidate = candidate
	if _create_status != null:
		_create_status.text = "Review the mod below — nothing is installed until you tap Install."
	if _create_regenerate_button != null:
		_create_regenerate_button.visible = false
	_show_approval(candidate)


## Fills the approval panel: plain-language summary + kind/ID + key
## manifest stats, and the ENTIRE payload in the read-only code area.
func _show_approval(candidate: Dictionary) -> void:
	if _approval_panel == null:
		return
	var lines: Array[String] = []
	var name_txt := str(candidate.get("name", ""))
	var mod_id := str(candidate.get("mod_id", ""))
	var kind := str(candidate.get("kind", ""))
	if not name_txt.is_empty():
		lines.append("Name: " + name_txt)
	if not mod_id.is_empty():
		lines.append("ID: " + mod_id)
	if not kind.is_empty():
		lines.append("Kind: " + kind)
	var manifest: Variant = candidate.get("manifest", {})
	if manifest is Dictionary:
		for key in (manifest as Dictionary).keys():
			if lines.size() >= 16:
				break
			var v: Variant = (manifest as Dictionary)[key]
			if v is String or v is int or v is float or v is bool:
				lines.append("%s: %s" % [str(key), str(v)])
	var summary := str(candidate.get("summary", ""))
	if not summary.is_empty():
		lines.append("")
		lines.append(summary)
	if _approval_summary != null:
		_approval_summary.text = "\n".join(lines)
	if _approval_code != null:
		_approval_code.text = str(candidate.get("payload", ""))
		_approval_code.scroll_vertical = 0
		_approval_code.scroll_horizontal = 0
	if _approval_status != null:
		_approval_status.text = ""
	_approval_panel.visible = true


func _on_approval_install_pressed() -> void:
	if _pending_candidate.is_empty():
		return
	var creator := _mod_creator_instance()
	if creator == null or not creator.has_method("install"):
		if _approval_status != null:
			_approval_status.text = "Mod creation unavailable — creator not found."
		return
	var result: Variant = creator.callv("install", [_pending_candidate])
	var err := ""
	if result is String:
		err = result as String
	if err.is_empty():
		_pending_candidate = {}
		if _approval_panel != null:
			_approval_panel.visible = false
		if _create_panel != null:
			_create_panel.visible = false
		if _create_status != null:
			_create_status.text = ""
		_refresh_mods()
		_show_toast("mod installed")
		_play("ui_click")
	else:
		if _approval_status != null:
			_approval_status.text = "Install failed: " + err


func _on_approval_discard_pressed() -> void:
	# Discard drops the candidate — nothing was written, nothing to undo.
	_pending_candidate = {}
	if _approval_panel != null:
		_approval_panel.visible = false
	if _create_status != null:
		_create_status.text = "Discarded — nothing installed."
	_play("ui_click")


func _on_approval_regenerate_pressed() -> void:
	var idea := _pending_idea
	if idea.is_empty() and _create_idea_input != null:
		idea = _create_idea_input.text.strip_edges()
		_pending_idea = idea
	if idea.is_empty():
		if _approval_status != null:
			_approval_status.text = "Describe your mod idea first."
		return
	# The old candidate is replaced by the fresh generation, never kept.
	_pending_candidate = {}
	if _approval_panel != null:
		_approval_panel.visible = false
	_start_generation(idea)
	_play("ui_click")


## The ModCreator instance, or null when its file has not landed yet.
## Cached; a Node instance is added to the tree so async work (HTTP,
## awaits) can run. The generation_ready signal is wired once here.
func _mod_creator_instance() -> Object:
	if _mod_creator != null and is_instance_valid(_mod_creator):
		return _mod_creator
	if not ResourceLoader.exists(MOD_CREATOR_PATH):
		return null
	var script: GDScript = load(MOD_CREATOR_PATH) as GDScript
	if script == null:
		return null
	var inst: Object = script.new()
	if inst == null:
		return null
	if inst.has_signal("generation_ready") and not inst.is_connected("generation_ready", _on_generation_ready):
		inst.connect("generation_ready", _on_generation_ready)
	if inst is Node and not (inst as Node).is_inside_tree():
		add_child(inst as Node)
	_mod_creator = inst
	return inst


## Drops the pending candidate + hides the approval panel + resets the
## Generate button. Called on Discard-equivalent exits (panel close,
## menu close, CREATE MOD toggle-off). Never writes anything.
func _clear_create_candidate() -> void:
	_pending_candidate = {}
	if _approval_panel != null:
		_approval_panel.visible = false
	if _approval_summary != null:
		_approval_summary.text = ""
	if _approval_code != null:
		_approval_code.text = ""
	if _approval_status != null:
		_approval_status.text = ""
	if _create_regenerate_button != null:
		_create_regenerate_button.visible = false
	if _create_generate_button != null:
		_create_generate_button.disabled = false
	_create_generating = false


## Full Create-Mod reset for menu close: candidate + idea + panels.
func _clear_create_mod_state() -> void:
	_clear_create_candidate()
	_pending_idea = ""
	if _create_panel != null:
		_create_panel.visible = false
	if _create_status != null:
		_create_status.text = ""
	if _create_idea_input != null:
		_create_idea_input.text = ""
