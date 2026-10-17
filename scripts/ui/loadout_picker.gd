# scripts/ui/loadout_picker.gd
# FORGEFALL — Persistent loadout picker (Goal 6 PROGRESSION, Worker B).
# A self-contained Control overlay: scenes/ui/loadout_picker.tscn is a thin
# shell; ALL UI is built in code here (same pattern as forge_menu.gd).
# Opened from the main menu's LOADOUTS button; does NOT depend on the
# main menu's layout. close() hides + emits picker_closed (the opener
# frees the picker); the picker never frees itself, so it stays reusable.
#
# What it does: view / select / create / rename / delete loadouts and pick
# the ACTIVE one used on Deploy. All data goes through /root/Loadouts
# (scripts/progression/loadouts.gd, the ONE shared store in
# user://loadouts.json) — this picker keeps no loadout state of its own.
# Mod weapons ("mod:<mod_id>") are offered like base weapons: the store
# lists them, validates them, and persists them in a loadout exactly like
# a base weapon id; a stale one shows as (MOD UNAVAILABLE) in the list.
# When the Loadouts autoload is absent (standalone probe), it instantiates
# the script directly as a fallback child; either way the same file is
# read/written, so the Forge tab and the picker can never diverge.
#
# Slot gating is owned by Loadouts.get_max_loadout_slots() (Progression
# unlocks, or the default when Progression is missing) — this picker
# never touches /root/Progression itself, so it never crashes when
# Progression is absent.
extends Control

signal picker_closed

const LOADOUTS_SCRIPT := "res://scripts/progression/loadouts.gd"
# Must match Arsenal.MOD_PREFIX: mod-weapon ids are "mod:<mod_id>".
const MOD_PREFIX := "mod:"

var _loadouts_node: Node = null
var _fallback_owned: bool = false

var _panel: PanelContainer
var _title_label: Label
var _slots_label: Label
var _info_label: Label
var _list_box: VBoxContainer
var _list_scroll: ScrollContainer
var _new_button: Button
var _close_button: Button
var _status_label: Label
# Editor (hidden until NEW / EDIT).
var _editor: VBoxContainer
var _editor_title: Label
var _name_input: LineEdit
var _primary_select: OptionButton
var _secondary_select: OptionButton
var _forge_select: OptionButton
var _traversal_select: OptionButton
var _traversal_ids: Array[String] = []
var _save_button: Button
var _cancel_button: Button
var _editing_name: String = ""
var _editor_forge_prompts: Array[String] = []
var _weapon_ids: Array[String] = []


func _ready() -> void:
	add_to_group("loadout_picker")
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)


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
	_panel = panel

	var root := VBoxContainer.new()
	root.name = "Root"
	panel.add_child(root)

	var header := HBoxContainer.new()
	header.name = "Header"
	root.add_child(header)
	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.text = "LOADOUTS"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)
	_slots_label = Label.new()
	_slots_label.name = "SlotsLabel"
	_slots_label.text = "SLOTS: —"
	header.add_child(_slots_label)
	_close_button = Button.new()
	_close_button.name = "CloseButton"
	_close_button.text = "X"
	StencilStyle.style_button(_close_button)
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	_info_label = Label.new()
	_info_label.name = "InfoLabel"
	_info_label.text = "Pick the loadout used on Deploy. Select one to make it active."
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_info_label)

	_list_scroll = ScrollContainer.new()
	_list_scroll.name = "ListScroll"
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_list_scroll)
	_list_box = VBoxContainer.new()
	_list_box.name = "ListBox"
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.add_child(_list_box)

	var new_row := HBoxContainer.new()
	new_row.name = "NewRow"
	root.add_child(new_row)
	_new_button = Button.new()
	_new_button.name = "NewButton"
	_new_button.text = "NEW LOADOUT"
	StencilStyle.style_button(_new_button)
	_new_button.pressed.connect(_on_new_pressed)
	new_row.add_child(_new_button)
	var new_hint := Label.new()
	new_hint.name = "NewHint"
	new_hint.text = "More slots unlock through Progression."
	new_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(new_hint, 17, StencilStyle.TEXT_DIM, 2)
	new_row.add_child(new_hint)

	_build_editor(root)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = ""
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status_label)

	_apply_scale()


func _build_editor(parent: VBoxContainer) -> void:
	_editor = VBoxContainer.new()
	_editor.name = "Editor"
	_editor.visible = false
	parent.add_child(_editor)
	_editor_title = Label.new()
	_editor_title.name = "EditorTitle"
	_editor_title.text = "NEW LOADOUT"
	_editor.add_child(_editor_title)

	var name_row := HBoxContainer.new()
	name_row.name = "NameRow"
	_editor.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "NAME"
	StencilStyle.apply_body(name_lbl, 18, StencilStyle.TEXT_DIM, 2)
	name_row.add_child(name_lbl)
	_name_input = LineEdit.new()
	_name_input.name = "NameInput"
	_name_input.placeholder_text = "Loadout name (e.g. Sniper Nest)"
	_name_input.max_length = 24
	_name_input.clear_button_enabled = true
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_name_input)
	# Same focus rule as the Forge menu: keyboard only on tap.
	_name_input.focus_mode = Control.FOCUS_CLICK
	name_row.add_child(_name_input)

	_primary_select = _weapon_row("PRIMARY")
	_secondary_select = _weapon_row("SECONDARY")
	_forge_select = _forge_row()
	_traversal_select = _traversal_row()
	var trav_hint := Label.new()
	trav_hint.name = "TraversalHint"
	trav_hint.text = "Exactly ONE traversal tool is active in the run. Jetpack (fuel-based thrust) lands with the movement worker — your choice is stored and applies once it lands."
	trav_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(trav_hint, 16, StencilStyle.TEXT_DIM, 2)
	_editor.add_child(trav_hint)

	var btn_row := HBoxContainer.new()
	btn_row.name = "EditorButtons"
	_editor.add_child(btn_row)
	_save_button = Button.new()
	_save_button.name = "SaveButton"
	_save_button.text = "SAVE"
	StencilStyle.style_button(_save_button)
	_save_button.pressed.connect(_on_save_pressed)
	btn_row.add_child(_save_button)
	_cancel_button = Button.new()
	_cancel_button.name = "CancelButton"
	_cancel_button.text = "CANCEL"
	StencilStyle.style_button(_cancel_button)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(_cancel_button)


## One weapon dropdown row (label + OptionButton). Weapon ids come from
## the Loadouts store (Arsenal when it loads, mirror fallback) so the
## picker can never offer a stale id.
func _weapon_row(label_text: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.name = label_text + "Row"
	_editor.add_child(row)
	var lbl := Label.new()
	lbl.text = label_text
	StencilStyle.apply_body(lbl, 18, StencilStyle.TEXT_DIM, 2)
	row.add_child(lbl)
	var sel := OptionButton.new()
	sel.name = label_text + "Select"
	StencilStyle.style_button(sel)
	sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sel)
	return sel


## Forge-preset dropdown row: NONE + every Forge menu preset label.
func _forge_row() -> OptionButton:
	var row := HBoxContainer.new()
	row.name = "ForgeRow"
	_editor.add_child(row)
	var lbl := Label.new()
	lbl.text = "FORGE PRESET"
	StencilStyle.apply_body(lbl, 18, StencilStyle.TEXT_DIM, 2)
	row.add_child(lbl)
	var sel := OptionButton.new()
	sel.name = "ForgeSelect"
	StencilStyle.style_button(sel)
	sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sel)
	return sel


## Traversal dropdown row (Gameplay Rework): exactly one tool —
## Grapple Hook / Jetpack / Portal Gun. Options come from the
## Loadouts store so the picker can never offer a stale id.
func _traversal_row() -> OptionButton:
	var row := HBoxContainer.new()
	row.name = "TraversalRow"
	_editor.add_child(row)
	var lbl := Label.new()
	lbl.text = "TRAVERSAL"
	StencilStyle.apply_body(lbl, 18, StencilStyle.TEXT_DIM, 2)
	row.add_child(lbl)
	var sel := OptionButton.new()
	sel.name = "TraversalSelect"
	StencilStyle.style_button(sel)
	sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel.tooltip_text = "Exactly one traversal tool is active in the run."
	row.add_child(sel)
	return sel


func _vp_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(1920.0, 1080.0)
	return vp.get_visible_rect().size


func _on_viewport_resized() -> void:
	if is_inside_tree():
		_apply_scale()


func _apply_scale() -> void:
	if _panel == null:
		return
	var vp := _vp_size()
	var m := UiScale.panel_margin(vp)
	_panel.offset_left = m.x
	_panel.offset_right = -m.x
	_panel.offset_top = m.y
	_panel.offset_bottom = -m.y
	if _title_label != null:
		StencilStyle.apply_title(_title_label, UiScale.scaled_font(26, vp), StencilStyle.ORANGE, 3)
	if _slots_label != null:
		StencilStyle.apply_body(_slots_label, UiScale.scaled_font(20, vp), StencilStyle.TEXT, 2)
	if _close_button != null:
		_close_button.custom_minimum_size = Vector2(UiScale.scaled_size(56, vp), UiScale.scaled_size(56, vp))
		_close_button.add_theme_font_size_override("font_size", UiScale.scaled_font(22, vp))
	if _info_label != null:
		StencilStyle.apply_body(_info_label, UiScale.scaled_font(18, vp), StencilStyle.TEXT, 2)
	if _new_button != null:
		_new_button.custom_minimum_size = Vector2(UiScale.scaled_size(200, vp), UiScale.scaled_size(56, vp))
		_new_button.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	if _status_label != null:
		StencilStyle.apply_body(_status_label, UiScale.scaled_font(17, vp), StencilStyle.TEXT_DIM, 2)
	if _editor_title != null:
		StencilStyle.apply_body(_editor_title, UiScale.scaled_font(20, vp), StencilStyle.ORANGE, 2)
	if _name_input != null:
		_name_input.custom_minimum_size = Vector2(0, UiScale.scaled_size(56, vp))
		_name_input.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	for sel: OptionButton in [_primary_select, _secondary_select, _forge_select, _traversal_select]:
		if sel != null:
			sel.custom_minimum_size = Vector2(0, UiScale.scaled_size(56, vp))
			sel.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))
	for btn: Button in [_save_button, _cancel_button]:
		if btn != null:
			btn.custom_minimum_size = Vector2(UiScale.scaled_size(180, vp), UiScale.scaled_size(56, vp))
			btn.add_theme_font_size_override("font_size", UiScale.scaled_font(20, vp))


# ------------------------------------------------------------------ API
func open() -> void:
	visible = true
	_refresh()
	_play("ui_click")
	# Controller (v0.6.1): focus the first button (X close) so D-pad +
	# Confirm navigate the picker with no mouse. Text fields are skipped
	# (focus there would pop the phone keyboard).
	InputBindings.grab_first_focus(self)


func close() -> void:
	visible = false
	_editor.visible = false
	if _name_input != null and _name_input.has_focus():
		_name_input.release_focus()
	picker_closed.emit()
	_play("ui_click")


func is_open() -> bool:
	return visible


# ------------------------------------------------------------------ data
## The Loadouts node: the /root/Loadouts autoload when present, else a
## fallback instance of the same script (same file, same data — the two
## can never diverge into separate stores).
func _store() -> Node:
	if _loadouts_node != null and is_instance_valid(_loadouts_node):
		return _loadouts_node
	var autoload_node: Node = get_node_or_null("/root/Loadouts")
	if autoload_node != null:
		_loadouts_node = autoload_node
		_fallback_owned = false
		return _loadouts_node
	if not ResourceLoader.exists(LOADOUTS_SCRIPT):
		return null
	var fallback: Node = (load(LOADOUTS_SCRIPT) as GDScript).new()
	fallback.name = "LoadoutsFallback"
	add_child(fallback)
	_loadouts_node = fallback
	_fallback_owned = true
	return _loadouts_node


func _refresh() -> void:
	_refresh_slots()
	_refresh_list()
	_refresh_editor_options()


func _refresh_slots() -> void:
	var store: Node = _store()
	if store == null:
		_slots_label.text = "SLOTS: —"
		return
	var total: int = int((store.call("get_loadouts") as Array).size())
	var cap: int = int(store.call("get_max_loadout_slots"))
	_slots_label.text = "SLOTS: %d/%d" % [total, cap]
	_new_button.disabled = total >= cap
	if total >= cap:
		_new_button.tooltip_text = "No free loadout slots — more unlock through Progression."
	else:
		_new_button.tooltip_text = ""


func _refresh_list() -> void:
	for child: Node in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	var store: Node = _store()
	if store == null:
		_add_note("Loadout system unavailable.")
		return
	var entries: Array = store.call("get_loadouts")
	var active_name: String = str(store.call("get_active_name"))
	if entries.is_empty():
		_add_note("No loadouts yet — create one.")
		return
	for raw: Variant in entries:
		if raw is Dictionary:
			_add_row(raw as Dictionary, active_name, store, entries.size() <= 1)


func _add_note(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(lbl, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
	_list_box.add_child(lbl)


func _add_row(entry: Dictionary, active_name: String, store: Node, only_one: bool) -> void:
	var loadout_name: String = str(entry.get("name", ""))
	var wrap := VBoxContainer.new()
	wrap.name = "LoadoutRow_" + loadout_name
	_list_box.add_child(wrap)
	var row := HBoxContainer.new()
	row.name = "Row"
	wrap.add_child(row)
	var name_lbl := Label.new()
	name_lbl.name = "LoadoutName"
	name_lbl.text = loadout_name
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(name_lbl, UiScale.scaled_font(19, _vp_size()), StencilStyle.TEXT, 2)
	row.add_child(name_lbl)
	var is_active: bool = (loadout_name == active_name)
	if is_active:
		var badge := Label.new()
		badge.name = "ActiveBadge"
		badge.text = "ACTIVE"
		StencilStyle.apply_body(badge, UiScale.scaled_font(17, _vp_size()), StencilStyle.GREEN, 2)
		row.add_child(badge)
	var select_btn := Button.new()
	select_btn.name = "SelectButton"
	select_btn.text = "SELECT"
	select_btn.disabled = is_active
	StencilStyle.style_button(select_btn)
	select_btn.pressed.connect(_on_select_pressed.bind(loadout_name))
	row.add_child(select_btn)
	var edit_btn := Button.new()
	edit_btn.name = "EditButton"
	edit_btn.text = "EDIT"
	StencilStyle.style_button(edit_btn)
	edit_btn.pressed.connect(_on_edit_pressed.bind(loadout_name))
	row.add_child(edit_btn)
	var del_btn := Button.new()
	del_btn.name = "DeleteButton"
	del_btn.text = "DELETE"
	del_btn.disabled = only_one
	if only_one:
		del_btn.tooltip_text = "Cannot delete the last loadout."
	StencilStyle.style_button(del_btn)
	del_btn.pressed.connect(_on_delete_pressed.bind(loadout_name))
	row.add_child(del_btn)
	var detail := Label.new()
	detail.name = "LoadoutDetail"
	var primary_id: String = str(entry.get("primary", ""))
	var secondary_id: String = str(entry.get("secondary", ""))
	var primary_txt: String = str(store.call("get_weapon_display_name", primary_id))
	if primary_txt.is_empty():
		primary_txt = primary_id
		# A stale mod id (disabled/removed since the loadout was saved)
		# shows as unavailable instead of a dangling entry; the store
		# sanitizes it to the fallback on the next load.
		if primary_id.begins_with(MOD_PREFIX):
			primary_txt += " (MOD UNAVAILABLE)"
	elif primary_id.begins_with(MOD_PREFIX):
		primary_txt += " (MOD)"
	var secondary_txt: String = str(store.call("get_weapon_display_name", secondary_id))
	if secondary_txt.is_empty():
		secondary_txt = secondary_id
		if secondary_id.begins_with(MOD_PREFIX):
			secondary_txt += " (MOD UNAVAILABLE)"
	elif secondary_id.begins_with(MOD_PREFIX):
		secondary_txt += " (MOD)"
	var forge_txt: String = str(store.call("get_forge_preset_label", str(entry.get("forge_preset", ""))))
	var trav_txt: String = str(store.call("get_traversal_display_name", str(entry.get("traversal", "grapple"))))
	if trav_txt.is_empty():
		trav_txt = str(entry.get("traversal", "grapple"))
	detail.text = "%s  /  %s   ·   Forge: %s   ·   Traversal: %s" % [primary_txt, secondary_txt, forge_txt, trav_txt]
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(detail, UiScale.scaled_font(17, _vp_size()), StencilStyle.TEXT_DIM, 2)
	wrap.add_child(detail)


## (Re)builds the editor dropdowns. Weapon ids/names from the Loadouts
## store (Arsenal when it loads, mirror fallback); Forge presets from
## Loadouts.get_forge_preset_options() (index 0 = NONE).
func _refresh_editor_options() -> void:
	_weapon_ids = []
	var store_ids: Node = _store()
	if store_ids != null:
		_weapon_ids = store_ids.call("get_weapon_ids")
	for sel: OptionButton in [_primary_select, _secondary_select]:
		if sel == null:
			continue
		sel.clear()
		for wid: String in _weapon_ids:
			var disp: String = wid
			if store_ids != null:
				var got: String = str(store_ids.call("get_weapon_display_name", wid))
				if not got.is_empty():
					disp = got
			# Mod weapons are first-class picks — marked so they are
			# distinguishable from base weapons in the dropdown.
			if wid.begins_with(MOD_PREFIX):
				disp += " (MOD)"
			sel.add_item(disp)
	_editor_forge_prompts = [""]
	if _forge_select != null:
		_forge_select.clear()
		_forge_select.add_item("NONE")
		var store: Node = _store()
		if store != null:
			var opts: Array = store.call("get_forge_preset_options")
			for pair: Variant in opts:
				if pair is Array and (pair as Array).size() >= 2:
					_forge_select.add_item(str((pair as Array)[0]))
					_editor_forge_prompts.append(str((pair as Array)[1]))

	# Traversal options (exactly one tool) from the store.
	_traversal_ids = []
	if _traversal_select != null:
		_traversal_select.clear()
		var store_t: Node = _store()
		if store_t != null and store_t.has_method("get_traversal_options"):
			var opts_t: Array = store_t.call("get_traversal_options")
			for pair_t: Variant in opts_t:
				if pair_t is Array and (pair_t as Array).size() >= 2:
					_traversal_ids.append(str((pair_t as Array)[0]))
					_traversal_select.add_item(str((pair_t as Array)[1]))


func _select_traversal(tool: String) -> void:
	if _traversal_select == null:
		return
	var idx: int = _traversal_ids.find(tool)
	_traversal_select.selected = idx if idx >= 0 else 0



func _select_weapon(sel: OptionButton, weapon_id: String) -> void:
	if sel == null:
		return
	var idx: int = _weapon_ids.find(weapon_id)
	sel.selected = idx if idx >= 0 else 0


func _select_forge(prompt: String) -> void:
	if _forge_select == null:
		return
	var idx: int = _editor_forge_prompts.find(prompt)
	_forge_select.selected = idx if idx >= 0 else 0


# ------------------------------------------------------------------ input
func _on_select_pressed(loadout_name: String) -> void:
	var store: Node = _store()
	if store == null:
		return
	if bool(store.call("set_active", loadout_name)):
		_set_status("%s is now active — used on Deploy." % loadout_name)
		_refresh()
		_play("ui_click")
	else:
		_set_status("Could not select %s." % loadout_name)


func _on_edit_pressed(loadout_name: String) -> void:
	var store: Node = _store()
	if store == null:
		return
	var entry: Dictionary = store.call("get_loadout", loadout_name)
	if entry.is_empty():
		return
	_editing_name = loadout_name
	_editor_title.text = "EDIT LOADOUT"
	_name_input.text = loadout_name
	_select_weapon(_primary_select, str(entry.get("primary", "")))
	_select_weapon(_secondary_select, str(entry.get("secondary", "")))
	_select_forge(str(entry.get("forge_preset", "")))
	_select_traversal(str(entry.get("traversal", "grapple")))
	_editor.visible = true
	_apply_scale()


func _on_new_pressed() -> void:
	_editing_name = ""
	_editor_title.text = "NEW LOADOUT"
	_name_input.text = ""
	_select_weapon(_primary_select, "ar7")
	_select_weapon(_secondary_select, "p9")
	_select_forge("")
	_select_traversal("grapple")
	_editor.visible = true
	_apply_scale()


func _on_cancel_pressed() -> void:
	_editor.visible = false
	_editing_name = ""
	_play("ui_click")


func _on_save_pressed() -> void:
	var store: Node = _store()
	if store == null:
		return
	var new_name: String = _name_input.text.strip_edges()
	if new_name.is_empty():
		_set_status("Give the loadout a name first.")
		return
	var primary_id: String = _weapon_ids[_primary_select.selected] if _primary_select != null and _primary_select.selected >= 0 and _primary_select.selected < _weapon_ids.size() else ""
	var secondary_id: String = _weapon_ids[_secondary_select.selected] if _secondary_select != null and _secondary_select.selected >= 0 and _secondary_select.selected < _weapon_ids.size() else ""
	var forge_prompt: String = _editor_forge_prompts[_forge_select.selected] if _forge_select != null and _forge_select.selected >= 0 and _forge_select.selected < _editor_forge_prompts.size() else ""
	var traversal_id: String = _traversal_ids[_traversal_select.selected] if _traversal_select != null and _traversal_select.selected >= 0 and _traversal_select.selected < _traversal_ids.size() else "grapple"
	if primary_id.is_empty() or secondary_id.is_empty():
		_set_status("Pick a weapon for both slots.")
		return
	if _editing_name.is_empty():
		# CREATE path.
		if bool(store.call("create_loadout", new_name, primary_id, secondary_id, forge_prompt, traversal_id)):
			_editor.visible = false
			_editing_name = ""
			_set_status("%s created." % new_name)
			_refresh()
			_play("ui_click")
		else:
			_set_status("Could not create %s — name taken or no free slots." % new_name)
		return
	# EDIT path: rename first (no-op when the name is unchanged), then update.
	var target_name: String = _editing_name
	if new_name.to_lower() != _editing_name.to_lower():
		if not bool(store.call("rename_loadout", _editing_name, new_name)):
			_set_status("Could not rename — that name is taken.")
			return
		target_name = new_name
	if bool(store.call("update_loadout", target_name, primary_id, secondary_id, forge_prompt, traversal_id)):
		_editor.visible = false
		_editing_name = ""
		_set_status("%s saved." % target_name)
		_refresh()
		_play("ui_click")
	else:
		_set_status("Could not save %s." % target_name)


func _on_delete_pressed(loadout_name: String) -> void:
	var store: Node = _store()
	if store == null:
		return
	if bool(store.call("delete_loadout", loadout_name)):
		if _editing_name == loadout_name:
			_editor.visible = false
			_editing_name = ""
		_set_status("%s deleted." % loadout_name)
		_refresh()
		_play("ui_click")
	else:
		_set_status("Could not delete %s." % loadout_name)


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _play(id: String) -> void:
	var s: Node = get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.call("play_2d", id)
