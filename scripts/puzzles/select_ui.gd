# scripts/puzzles/select_ui.gd
# FORGEFALL — Goal 5 (Worker B): room-select screen.
# Lists the four rooms from CompletionStore with a completion tick,
# plus a Back button. Picking a room asks Main (group "game_root") to
# start it; with no Main present (headless verification) buttons no-op.
# No autoload dependencies.
class_name RoomSelect
extends Control

var _selected_room := ""


func _ready() -> void:
	StencilStyle.install_menu(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	StencilStyle.cinematic_background(self, "chambers", 0.08)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 48)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 24)
	scroll.add_child(content)
	StencilStyle.section_header(content, "PORTAL CHAMBERS")
	var gap := Control.new()
	gap.custom_minimum_size.y = 24
	content.add_child(gap)
	var list := VBoxContainer.new()
	list.name = "ChamberList"
	list.custom_minimum_size.x = 430
	list.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	content.add_child(list)
	var description := Label.new()
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.custom_minimum_size.x = 430
	description.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	StencilStyle.apply_body(description, 18, StencilStyle.TEXT_DIM)
	var done := CompletionStore.all_done()
	_selected_room = str(CompletionStore.ROOMS[0]["id"])
	description.text = str(CompletionStore.ROOMS[0]["teaches"])
	for room in CompletionStore.ROOMS:
		var button := Button.new()
		button.text = str(room["title"]) + ("  ✓" if bool(done.get(str(room["id"]), false)) else "")
		button.custom_minimum_size.y = 58
		button.set_meta("room_id", str(room["id"]))
		StencilStyle.navigation_button(button, str(room["id"]) == _selected_room)
		button.pressed.connect(func() -> void:
			_selected_room = str(room["id"])
			description.text = str(room["teaches"])
			for child in list.get_children():
				StencilStyle.navigation_button(child, child.get_meta("room_id") == _selected_room))
		list.add_child(button)
	content.add_child(description)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(fill)
	var actions := HBoxContainer.new()
	content.add_child(actions)
	var back := Button.new()
	back.text = "‹  BACK"
	back.custom_minimum_size = Vector2(150, 52)
	StencilStyle.navigation_button(back)
	back.pressed.connect(_on_back)
	actions.add_child(back)
	var space := Control.new()
	space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(space)
	var enter := Button.new()
	enter.text = "ENTER  ›"
	enter.custom_minimum_size = Vector2(210, 52)
	StencilStyle.primary_button(enter)
	enter.pressed.connect(func() -> void: _on_pick(_selected_room))
	actions.add_child(enter)
	InputBindings.grab_first_focus(self)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_back()


func _on_pick(id: String) -> void:
	var main: Node = get_tree().get_first_node_in_group("game_root")
	if main != null and main.has_method("start_puzzle"):
		main.start_puzzle(id)


func _on_back() -> void:
	var main: Node = get_tree().get_first_node_in_group("game_root")
	if main != null and main.has_method("on_puzzle_select_back"):
		main.on_puzzle_select_back()
	else:
		queue_free()
