# FORGEFALL — ModCreatorMenu (Forge batch, Worker D: Mod Creator redesign)
# CREATE-A-MOD is its own MAIN-MENU widget now (main menu -> CREATE A MOD),
# not a panel inside the Forge menu. Dedicated menu, three tabs:
#   CREATE — structured form (NOT one text box): multi-choice CATEGORIES
#     checkboxes (Weapon / Block-Structure / Enemy / Effect / Gameplay —
#     a mod can be several at once), NAME, VISUAL DESCRIPTION, LOGIC.
#     GENERATE composes ONE stable prompt from the form and feeds the
#     EXISTING generation -> strict validation -> approval pipeline
#     (ModCreator): summary + FULL payload -> Install / Discard /
#     Regenerate. Approval also offers TEST IN SANDBOX.
#   MODS — the same installed-mods list (ModLoader data, no second list):
#     list / enable / disable / Rescan. The Forge menu's Mods tab keeps
#     the same list — one create flow, no duplicates.
#   IMPORT/EXPORT — PLACEHOLDER / DISABLED tab ONLY, no functionality.
#     FOR LATER: the tab exists so the layout is stable; both buttons
#     are disabled and nothing is wired.
#
# VOXEL ASSETS: after a candidate arrives, the menu generates the voxel
# asset from the VISUAL DESCRIPTION via VoxelAssetGenerator (local,
# keyword-driven, cached by hash of the normalized description) and shows
# the cache HIT/MISS + voxel count on the approval screen.
#
# SANDBOX: TEST IN SANDBOX opens SandboxTestRoom with the candidate +
# asset. The sandbox simulates the mod's declared behaviour and writes
# NOTHING to the real mod list or progression. Install stays available
# on the approval screen whether or not the sandbox was used.
#
# NOTHING installs except the Install tap (ModCreator.install is the only
# write path, same as the old in-Forge flow). Closing the menu drops the
# pending candidate, uninstalled.
extends Control
class_name ModCreatorMenu

signal creator_closed

const CATEGORIES := ["Weapon", "Block/Structure", "Enemy", "Effect", "Gameplay"]
const CREATOR_TABS := ["CREATE", "MODS", "IMPORT/EXPORT"]

var _tabs: TabContainer
var _category_checks: Dictionary = {}
var _name_input: LineEdit
var _visual_input: TextEdit
var _logic_input: TextEdit
var _generate_button: Button
var _status: Label
var _approval_panel: VBoxContainer
var _approval_summary: Label
var _approval_code: TextEdit
var _asset_info: Label
var _approval_status: Label
var _install_button: Button
var _discard_button: Button
var _regenerate_button: Button
var _sandbox_button: Button
var _mods_list: VBoxContainer
var _mods_path_label: Label
var _mods_rescan_button: Button
var _creator: ModCreator
var _pending_candidate: Dictionary = {}
var _pending_prompt: String = ""
var _pending_asset: Dictionary = {}
var _generating := false
var _last_sandbox_result: Dictionary = {}


## Composes ONE stable prompt from the structured form. Fixed section
## order + fixed technical-notes text, so the same form always yields the
## same prompt (and the LLM's stable-prefix cache sees a stable shape).
## The technical notes steer the model to the EXISTING validated path:
## custom visuals via api.spawn_voxel_box, impact explosions via
## api.fire_effect("explosion", ...), ModAPI only, no forbidden code.
static func compose_prompt(categories: Array, mod_name: String, visual: String, logic: String) -> String:
	var lines: Array[String] = []
	lines.append("Create a mod.")
	lines.append("Categories: " + ", ".join(categories))
	lines.append("Name: " + mod_name.strip_edges())
	lines.append("Visual description: " + visual.strip_edges())
	lines.append("Logic: " + logic.strip_edges())
	lines.append("Technical notes (follow exactly): represent any custom projectile or visual with api.spawn_voxel_box calls using voxel-sized cubes in the visual description's colours; trigger impact explosions with api.fire_effect(\"explosion\", position, radius, damage); build only through the ModAPI methods; never emit filesystem, network, OS, eval, or code-loading code.")
	return "\n".join(lines)


## Behaviour flags for the sandbox, derived from the form + payload.
## Never executes the candidate — the sandbox simulates this behaviour.
static func behavior_for(categories: Array, logic: String, payload: String) -> Dictionary:
	var l := logic.to_lower()
	var p := payload.to_lower()
	var projectile := categories.has("Weapon") or l.contains("shoot") or l.contains("projectile") or l.contains("fire") or l.contains("launch") or p.contains("spawn_voxel_box")
	var explodes := l.contains("explod") or p.contains("explosion") or p.contains("fire_effect")
	return {"projectile": projectile, "explodes_on_impact": explodes}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh_mods()


func _build() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	add_child(panel)
	var vb := VBoxContainer.new()
	vb.name = "CreatorStack"
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)
	var head_row := HBoxContainer.new()
	vb.add_child(head_row)
	var head := Label.new()
	StencilStyle.apply_title(head, 30, StencilStyle.ORANGE, 4)
	head.text = "CREATE A MOD"
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(head)
	var close := Button.new()
	close.name = "CloseButton"
	close.text = "X"
	StencilStyle.style_button(close)
	close.pressed.connect(_on_close_pressed)
	head_row.add_child(close)
	_tabs = TabContainer.new()
	_tabs.name = "CreatorTabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_tab_changed)
	vb.add_child(_tabs)
	_build_create_tab()
	_build_mods_tab()
	_build_import_export_tab()


func _tab_scroll(tab_name: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	return scroll


func _section_label(text: String) -> Label:
	var lbl := Label.new()
	StencilStyle.apply_body(lbl, 20, StencilStyle.ORANGE, 2)
	lbl.text = text
	return lbl


# --- CREATE tab ---------------------------------------------------------------

func _build_create_tab() -> void:
	var scroll := _tab_scroll("CreateTab")
	_tabs.set_tab_title(0, CREATOR_TABS[0])
	var box := VBoxContainer.new()
	box.name = "CreateBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	# (1) CATEGORIES — MULTI-CHOICE checkboxes, never single-select.
	box.add_child(_section_label("CATEGORIES — pick all that apply"))
	var cat_row := HBoxContainer.new()
	cat_row.name = "CategoryRow"
	box.add_child(cat_row)
	for cat in CATEGORIES:
		var cb := CheckButton.new()
		cb.name = "Category" + cat.replace("/", "").replace(" ", "")
		cb.text = cat
		cb.add_theme_font_size_override("font_size", 18)
		cat_row.add_child(cb)
		_category_checks[cat] = cb
	# (2) NAME.
	box.add_child(_section_label("NAME"))
	_name_input = LineEdit.new()
	_name_input.name = "ModNameInput"
	_name_input.placeholder_text = "e.g. Watermelon LMG"
	_name_input.clear_button_enabled = true
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_name_input)
	_name_input.focus_mode = Control.FOCUS_CLICK
	box.add_child(_name_input)
	# (3) VISUAL DESCRIPTION.
	box.add_child(_section_label("VISUAL DESCRIPTION — what it looks like"))
	_visual_input = TextEdit.new()
	_visual_input.name = "VisualInput"
	_visual_input.placeholder_text = "e.g. a green watermelon with dark stripes and a red interior"
	_visual_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_visual_input.custom_minimum_size = Vector2(0, 90)
	box.add_child(_visual_input)
	# (4) LOGIC.
	box.add_child(_section_label("LOGIC — what it does"))
	_logic_input = TextEdit.new()
	_logic_input.name = "LogicInput"
	_logic_input.placeholder_text = "e.g. an LMG that shoots watermelons. The watermelons explode on impact."
	_logic_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_logic_input.custom_minimum_size = Vector2(0, 110)
	box.add_child(_logic_input)
	_generate_button = Button.new()
	_generate_button.name = "GenerateButton"
	_generate_button.text = "GENERATE"
	StencilStyle.style_button(_generate_button)
	_generate_button.pressed.connect(_on_generate_pressed)
	box.add_child(_generate_button)
	_status = Label.new()
	_status.name = "CreateStatus"
	_status.text = ""
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_status, 17, StencilStyle.TEXT_DIM, 2)
	box.add_child(_status)
	# Approval: summary + FULL payload + asset info + Install / Discard /
	# Regenerate / TEST IN SANDBOX. Nothing installs until Install.
	_approval_panel = VBoxContainer.new()
	_approval_panel.name = "ApprovalPanel"
	_approval_panel.visible = false
	box.add_child(_approval_panel)
	var approval_title := Label.new()
	approval_title.text = "REVIEW — nothing is installed until you tap Install."
	approval_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(approval_title, 18, StencilStyle.ORANGE, 2)
	_approval_panel.add_child(approval_title)
	_approval_summary = Label.new()
	_approval_summary.name = "ApprovalSummary"
	_approval_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_summary, 18, StencilStyle.TEXT, 2)
	_approval_panel.add_child(_approval_summary)
	_approval_code = TextEdit.new()
	_approval_code.name = "ApprovalCode"
	_approval_code.editable = false
	_approval_code.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_approval_code.custom_minimum_size = Vector2(0, 240)
	_approval_panel.add_child(_approval_code)
	_asset_info = Label.new()
	_asset_info.name = "AssetInfo"
	_asset_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_asset_info, 17, StencilStyle.TEXT, 2)
	_approval_panel.add_child(_asset_info)
	_approval_status = Label.new()
	_approval_status.name = "ApprovalStatus"
	_approval_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_status, 17, StencilStyle.RED, 2)
	_approval_panel.add_child(_approval_status)
	var btn_row := HBoxContainer.new()
	btn_row.name = "ApprovalButtonRow"
	_approval_panel.add_child(btn_row)
	_install_button = Button.new()
	_install_button.name = "ApprovalInstallButton"
	_install_button.text = "INSTALL"
	StencilStyle.style_button(_install_button)
	_install_button.pressed.connect(_on_install_pressed)
	btn_row.add_child(_install_button)
	_discard_button = Button.new()
	_discard_button.name = "ApprovalDiscardButton"
	_discard_button.text = "DISCARD"
	StencilStyle.style_button(_discard_button)
	_discard_button.pressed.connect(_on_discard_pressed)
	btn_row.add_child(_discard_button)
	_regenerate_button = Button.new()
	_regenerate_button.name = "ApprovalRegenerateButton"
	_regenerate_button.text = "REGENERATE"
	StencilStyle.style_button(_regenerate_button)
	_regenerate_button.pressed.connect(_on_regenerate_pressed)
	btn_row.add_child(_regenerate_button)
	_sandbox_button = Button.new()
	_sandbox_button.name = "SandboxButton"
	_sandbox_button.text = "TEST IN SANDBOX"
	StencilStyle.style_button(_sandbox_button)
	_sandbox_button.pressed.connect(_on_sandbox_pressed)
	btn_row.add_child(_sandbox_button)


# --- MODS tab (same ModLoader list as the Forge menu) --------------------------

func _build_mods_tab() -> void:
	var scroll := _tab_scroll("ModsTab")
	_tabs.set_tab_title(1, CREATOR_TABS[1])
	var box := VBoxContainer.new()
	box.name = "ModsBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	_mods_path_label = Label.new()
	_mods_path_label.name = "ModsPathLabel"
	_mods_path_label.text = "Mods folder: " + OS.get_user_data_dir() + "/mods"
	_mods_path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_mods_path_label, 17, StencilStyle.TEXT_DIM, 2)
	box.add_child(_mods_path_label)
	var row := HBoxContainer.new()
	box.add_child(row)
	_mods_rescan_button = Button.new()
	_mods_rescan_button.name = "ModsRescanButton"
	_mods_rescan_button.text = "RESCAN"
	StencilStyle.style_button(_mods_rescan_button)
	_mods_rescan_button.pressed.connect(_on_mods_rescan_pressed)
	row.add_child(_mods_rescan_button)
	var hint := Label.new()
	hint.text = "Same installed mods as the Forge menu — list / enable / disable / Rescan."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(hint, 17, StencilStyle.TEXT_DIM, 2)
	row.add_child(hint)
	var list_scroll := ScrollContainer.new()
	list_scroll.name = "ModsListScroll"
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(list_scroll)
	_mods_list = VBoxContainer.new()
	_mods_list.name = "ModsList"
	_mods_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_mods_list)


# --- IMPORT/EXPORT tab: PLACEHOLDER ONLY, no functionality ---------------------

func _build_import_export_tab() -> void:
	var scroll := _tab_scroll("ImportExportTab")
	_tabs.set_tab_title(2, CREATOR_TABS[2])
	var box := VBoxContainer.new()
	box.name = "ImportExportBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	scroll.add_child(box)
	var note := Label.new()
	note.name = "ImportExportNote"
	note.text = "IMPORT / EXPORT — coming in a later update.\nShare mods as files and bring in mods from other players."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_body(note, 20, StencilStyle.TEXT_DIM, 2)
	box.add_child(note)
	var import_btn := Button.new()
	import_btn.name = "ImportButton"
	import_btn.text = "IMPORT MOD"
	import_btn.disabled = true
	StencilStyle.style_button(import_btn)
	box.add_child(import_btn)
	var export_btn := Button.new()
	export_btn.name = "ExportButton"
	export_btn.text = "EXPORT MOD"
	export_btn.disabled = true
	StencilStyle.style_button(export_btn)
	box.add_child(export_btn)


# --- Form state -----------------------------------------------------------------

func get_selected_categories() -> Array:
	var out: Array = []
	for cat in CATEGORIES:
		var cb: CheckButton = _category_checks.get(cat)
		if cb != null and cb.button_pressed:
			out.append(cat)
	return out


func get_pending_candidate() -> Dictionary:
	return _pending_candidate


func get_pending_asset() -> Dictionary:
	return _pending_asset


func get_last_sandbox_result() -> Dictionary:
	return _last_sandbox_result


func _on_tab_changed(tab: int) -> void:
	if tab == 1:
		_refresh_mods()


func _on_close_pressed() -> void:
	_pending_candidate = {}
	creator_closed.emit()
	queue_free()


# --- Generation -> approval -------------------------------------------------------

func _on_generate_pressed() -> void:
	var cats := get_selected_categories()
	if cats.is_empty():
		_status.text = "Pick at least one category."
		return
	if _name_input.text.strip_edges().is_empty():
		_status.text = "Give the mod a name."
		return
	if _visual_input.text.strip_edges().is_empty():
		_status.text = "Describe what it looks like."
		return
	if _logic_input.text.strip_edges().is_empty():
		_status.text = "Describe what it does."
		return
	_pending_prompt = compose_prompt(cats, _name_input.text, _visual_input.text, _logic_input.text)
	_start_generation(_pending_prompt)


func _on_regenerate_pressed() -> void:
	if _pending_prompt.is_empty():
		return
	_start_generation(_pending_prompt)


func _start_generation(prompt: String) -> void:
	if _generating:
		return
	var creator := _creator_instance()
	if creator == null:
		_status.text = "Mod creation unavailable — creator not found."
		return
	_generating = true
	_generate_button.disabled = true
	_approval_panel.visible = false
	_status.text = "Generating…"
	creator.generate(prompt)


func _on_generation_ready(candidate: Dictionary) -> void:
	_generating = false
	_generate_button.disabled = false
	var err := str(candidate.get("error", ""))
	if not err.is_empty():
		_pending_candidate = {}
		_approval_panel.visible = false
		_status.text = "Generation failed: " + err
		return
	_pending_candidate = candidate
	# Voxel asset from the VISUAL DESCRIPTION (local, cached).
	_pending_asset = VoxelAssetGenerator.get_or_generate(_visual_input.text)
	_status.text = "Review the mod below — nothing is installed until you tap Install."
	_show_approval(candidate)


func _show_approval(candidate: Dictionary) -> void:
	var lines: Array[String] = []
	for key in ["name", "mod_id", "kind"]:
		var v := str(candidate.get(key, ""))
		if not v.is_empty():
			lines.append("%s: %s" % [key.capitalize(), v])
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
	_approval_summary.text = "\n".join(lines)
	_approval_code.text = str(candidate.get("payload", ""))
	_approval_code.scroll_vertical = 0
	_approval_code.scroll_horizontal = 0
	_asset_info.text = "Voxel asset: " + VoxelAssetGenerator.summarize(_pending_asset) + " — visual: " + _visual_input.text.strip_edges().left(120)
	_approval_status.text = ""
	_approval_panel.visible = true


func _creator_instance() -> ModCreator:
	if _creator != null and is_instance_valid(_creator):
		return _creator
	_creator = ModCreator.new()
	_creator.generation_ready.connect(_on_generation_ready)
	add_child(_creator)
	return _creator


# --- Approval actions -------------------------------------------------------------

func _on_install_pressed() -> void:
	if _pending_candidate.is_empty():
		return
	var creator := _creator_instance()
	var err := creator.install(_pending_candidate)
	if err.is_empty():
		_pending_candidate = {}
		_approval_panel.visible = false
		_status.text = "Installed."
		_refresh_mods()
	else:
		_approval_status.text = "Install failed: " + err


func _on_discard_pressed() -> void:
	_pending_candidate = {}
	_pending_asset = {}
	_approval_panel.visible = false
	_status.text = "Discarded — nothing installed."


func _on_sandbox_pressed() -> void:
	if _pending_candidate.is_empty():
		return
	var behavior := behavior_for(get_selected_categories(), _logic_input.text, str(_pending_candidate.get("payload", "")))
	var sandbox: SandboxTestRoom
	if ResourceLoader.exists("res://scenes/ui/sandbox_test_room.tscn"):
		var ps := load("res://scenes/ui/sandbox_test_room.tscn") as PackedScene
		sandbox = ps.instantiate() as SandboxTestRoom
	else:
		sandbox = SandboxTestRoom.new()
	sandbox.name = "SandboxTestRoom"
	add_child(sandbox)
	sandbox.sandbox_closed.connect(_on_sandbox_closed)
	sandbox.open(_pending_candidate, _pending_asset, behavior)


func _on_sandbox_closed(result: Dictionary) -> void:
	_last_sandbox_result = result
	if bool(result.get("hit", false)) and bool(result.get("explosion_fired", false)):
		_status.text = "Sandbox: HIT — projectile exploded on impact. Install still available."
	elif bool(result.get("hit", false)):
		_status.text = "Sandbox: HIT — no explosion. Install still available."
	elif bool(result.get("placed", false)):
		_status.text = "Sandbox: block placed in the test room. Install still available."
	elif not result.is_empty():
		_status.text = "Sandbox: no hit. Install still available."


# --- MODS tab ----------------------------------------------------------------------

func _refresh_mods() -> void:
	if _mods_list == null:
		return
	for child in _mods_list.get_children():
		_mods_list.remove_child(child)
		child.queue_free()
	if _mods_path_label != null:
		_mods_path_label.text = "Mods folder: " + OS.get_user_data_dir() + "/mods"
	# Same source as the Forge menu: ModLoader.get_mods(). No second list.
	# "assets" is the voxel-asset cache dir, not a mod — filtered out.
	var mods := ModLoader.get_mods()
	if mods.is_empty():
		var lbl := Label.new()
		lbl.text = "No mods installed — create one on the CREATE tab."
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		StencilStyle.apply_body(lbl, 17, StencilStyle.TEXT_DIM, 2)
		_mods_list.add_child(lbl)
		return
	for m in mods:
		if not (m is Dictionary):
			continue
		var mod := m as Dictionary
		if str(mod.get("id", "")) == "assets":
			continue
		_add_mod_row(mod)


func _add_mod_row(mod: Dictionary) -> void:
	var mod_id := str(mod.get("id", ""))
	var wrap := VBoxContainer.new()
	wrap.name = "ModRow_" + mod_id
	_mods_list.add_child(wrap)
	var row := HBoxContainer.new()
	wrap.add_child(row)
	var name_lbl := Label.new()
	name_lbl.name = "ModName"
	name_lbl.text = str(mod.get("name", mod_id))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(name_lbl, 19, StencilStyle.TEXT, 2)
	row.add_child(name_lbl)
	var kind_lbl := Label.new()
	kind_lbl.text = str(mod.get("kind", ""))
	StencilStyle.apply_body(kind_lbl, 17, StencilStyle.TEXT_DIM, 2)
	row.add_child(kind_lbl)
	var toggle := CheckButton.new()
	toggle.name = "ModToggle"
	toggle.text = "ON"
	toggle.button_pressed = bool(mod.get("enabled", false))
	toggle.toggled.connect(_on_mod_toggle.bind(mod_id))
	row.add_child(toggle)
	var err := str(mod.get("error", ""))
	if not err.is_empty():
		var err_lbl := Label.new()
		err_lbl.name = "ModError"
		err_lbl.text = err
		err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		StencilStyle.apply_body(err_lbl, 16, StencilStyle.RED, 2)
		wrap.add_child(err_lbl)


func _on_mod_toggle(mod_id: String, enable: bool) -> void:
	ModLoader.set_mod_enabled(mod_id, enable)
	_refresh_mods()


func _on_mods_rescan_pressed() -> void:
	ModLoader.rescan()
	_refresh_mods()
