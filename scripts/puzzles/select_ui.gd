# scripts/puzzles/select_ui.gd
# FORGEFALL — Goal 5 (Worker B): room-select screen.
# Lists the four rooms from CompletionStore with a completion tick,
# plus a Back button. Picking a room asks Main (group "game_root") to
# start it; with no Main present (headless verification) buttons no-op.
# No autoload dependencies.
class_name RoomSelect
extends Control


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.025, 0.03, 1.0)
	add_child(bg)

	var title := Label.new()
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.offset_left = -400
	title.offset_right = 400
	title.offset_top = 80
	title.offset_bottom = 150
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text = "PORTAL CHAMBERS"
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(1, 1, 1))
	add_child(title)

	var sub := Label.new()
	sub.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sub.offset_left = -400
	sub.offset_right = 400
	sub.offset_top = 155
	sub.offset_bottom = 190
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.text = "White panels take portals. Orange blocks hold plates. Green exits finish rooms."
	sub.add_theme_font_size_override("font_size", 20)
	sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(sub)

	var buttons := VBoxContainer.new()
	buttons.set_anchors_preset(Control.PRESET_CENTER)
	buttons.offset_left = -260
	buttons.offset_right = 260
	buttons.offset_top = -140
	buttons.offset_bottom = 220
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 14)
	add_child(buttons)

	var done := CompletionStore.all_done()
	for r in CompletionStore.ROOMS:
		var tick := "  ✓" if bool(done.get(str(r["id"]), false)) else ""
		var b := Button.new()
		b.text = str(r["title"]) + tick
		b.custom_minimum_size = Vector2(520, 64)
		b.add_theme_font_size_override("font_size", 24)
		var rid: String = str(r["id"])
		b.pressed.connect(_on_pick.bind(rid))
		buttons.add_child(b)
		var desc := Label.new()
		desc.text = str(r["teaches"])
		desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc.add_theme_font_size_override("font_size", 18)
		desc.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		buttons.add_child(desc)

	var back := Button.new()
	back.text = "BACK"
	back.custom_minimum_size = Vector2(300, 56)
	back.add_theme_font_size_override("font_size", 22)
	back.pressed.connect(_on_back)
	buttons.add_child(back)


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
