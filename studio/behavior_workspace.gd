extends Control

const Document = preload("res://behavior_document.gd")
const Compiler = preload("res://behavior_compiler.gd")
const Source = preload("res://behavior_source.gd")
const Store = preload("res://shared/document_store.gd")

var project_path := ""
var document: Dictionary = Document.create("New Behavior")
var source_workspace = Source.new()
var graph: GraphEdit
var editor: CodeEdit
var status: Label
var path_input: LineEdit
var type_picker: OptionButton
var properties_input: LineEdit
var selected_id := ""
var saved_graph_snapshot := ""
var graph_id_input: LineEdit

func _ready() -> void:
	_build_ui()
	_render_graph()

func _build_ui() -> void:
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layout)
	var bar := HBoxContainer.new()
	layout.add_child(bar)
	for template_name in ["Animated Door", "Timed Lift", "Explosive Barrel"]:
		var button := Button.new()
		button.text = template_name
		button.pressed.connect(func() -> void: load_template(template_name))
		bar.add_child(button)
	type_picker = OptionButton.new()
	for type in Document.TYPES:
		type_picker.add_item(type)
	bar.add_child(type_picker)
	_add_button(bar, "+ Node", _add_node)
	_add_button(bar, "Delete Node", _delete_node)
	graph_id_input = LineEdit.new()
	graph_id_input.placeholder_text = "Behavior ID"
	graph_id_input.custom_minimum_size.x = 160.0
	bar.add_child(graph_id_input)
	_add_button(bar, "Open Graph", open_graph)
	_add_button(bar, "Save Graph", save_graph)
	_add_button(bar, "Publish Script", publish_graph)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(tabs)
	var graph_panel := VBoxContainer.new()
	graph_panel.name = "Graph"
	tabs.add_child(graph_panel)
	graph = GraphEdit.new()
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.connection_request.connect(_connect_nodes)
	graph.disconnection_request.connect(_disconnect_nodes)
	graph_panel.add_child(graph)
	var property_bar := HBoxContainer.new()
	graph_panel.add_child(property_bar)
	var hint := Label.new()
	hint.text = "Selected node properties (JSON):"
	property_bar.add_child(hint)
	properties_input = LineEdit.new()
	properties_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	property_bar.add_child(properties_input)
	_add_button(property_bar, "Apply", _apply_properties)
	var source_panel := VBoxContainer.new()
	source_panel.name = "GDScript"
	tabs.add_child(source_panel)
	var source_bar := HBoxContainer.new()
	source_panel.add_child(source_bar)
	path_input = LineEdit.new()
	path_input.placeholder_text = "scripts/my_behavior.gd"
	path_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_bar.add_child(path_input)
	_add_button(source_bar, "Open", open_source)
	_add_button(source_bar, "Check", check_source)
	_add_button(source_bar, "Save Source", save_source)
	editor = CodeEdit.new()
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.gutters_draw_line_numbers = true
	editor.gutters_draw_breakpoints_gutter = true
	editor.gutters_draw_executing_lines = true
	editor.gutter_clicked.connect(_on_gutter_clicked)
	source_panel.add_child(editor)
	status = Label.new()
	status.text = "Select a Forgefall project before saving."
	layout.add_child(status)

func _add_button(parent: Control, label: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.pressed.connect(callback)
	parent.add_child(button)

func load_template(template_name: String) -> void:
	document = Document.template(template_name)
	saved_graph_snapshot = ""
	graph_id_input.text = str(document["id"])
	selected_id = ""
	_render_graph()
	status.text = "Loaded %s template." % template_name

func _add_node() -> void:
	var type := type_picker.get_item_text(type_picker.selected)
	var entry: Dictionary = Document.node(type)
	entry["position"] = [graph.scroll_offset.x + 200.0, graph.scroll_offset.y + 150.0]
	document["nodes"].append(entry)
	_render_graph()

func _delete_node() -> void:
	if selected_id.is_empty():
		return
	for index in range(document["nodes"].size() - 1, -1, -1):
		if document["nodes"][index]["id"] == selected_id:
			document["nodes"].remove_at(index)
	for index in range(document["edges"].size() - 1, -1, -1):
		var edge: Dictionary = document["edges"][index]
		if edge["from"] == selected_id or edge["to"] == selected_id:
			document["edges"].remove_at(index)
	selected_id = ""
	_render_graph()

func _render_graph() -> void:
	if graph == null:
		return
	graph.clear_connections()
	for child in graph.get_children():
		if child is GraphNode:
			graph.remove_child(child)
			child.queue_free()
	for entry in document["nodes"]:
		var node := GraphNode.new()
		node.name = str(entry["id"])
		node.title = str(entry["type"])
		var pos: Array = entry.get("position", [0.0, 0.0])
		node.position_offset = Vector2(float(pos[0]), float(pos[1]))
		node.set_slot_enabled_left(0, not ["ready", "interact", "timer"].has(entry["type"]))
		node.set_slot_enabled_right(0, true)
		var label := Label.new()
		label.text = JSON.stringify(entry.get("properties", {}))
		node.add_child(label)
		node.gui_input.connect(_on_node_input.bind(str(entry["id"])))
		node.position_offset_changed.connect(_record_positions)
		graph.add_child(node)
	for edge in document["edges"]:
		graph.connect_node(str(edge["from"]), 0, str(edge["to"]), 0)

func _select_node(id: String) -> void:
	selected_id = id
	for entry in document["nodes"]:
		if entry["id"] == id:
			properties_input.text = JSON.stringify(entry["properties"])
			break

func _on_node_input(event: InputEvent, id: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_select_node(id)

func _record_positions() -> void:
	for entry in document["nodes"]:
		var graph_node := graph.get_node_or_null(NodePath(str(entry["id"]))) as GraphNode
		if graph_node != null:
			entry["position"] = [graph_node.position_offset.x, graph_node.position_offset.y]

func _connect_nodes(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	var next_doc: Dictionary = document.duplicate(true)
	for index in range(next_doc["edges"].size() - 1, -1, -1):
		if str(next_doc["edges"][index]["from"]) == str(from_node):
			next_doc["edges"].remove_at(index)
	next_doc["edges"].append({"from": str(from_node), "to": str(to_node)})
	var problem := Document.validate(next_doc)
	if not problem.is_empty():
		status.text = problem
		return
	document = next_doc
	_render_graph()

func _disconnect_nodes(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	for index in range(document["edges"].size() - 1, -1, -1):
		var edge: Dictionary = document["edges"][index]
		if edge["from"] == str(from_node) and edge["to"] == str(to_node):
			document["edges"].remove_at(index)
	_render_graph()

func _apply_properties() -> void:
	var parsed: Variant = JSON.parse_string(properties_input.text)
	if not parsed is Dictionary:
		status.text = "Properties must be a JSON object."
		return
	var next_doc: Dictionary = document.duplicate(true)
	for entry in next_doc["nodes"]:
		if entry["id"] == selected_id:
			entry["properties"] = parsed
			break
	var problem := Document.validate(next_doc)
	if not problem.is_empty():
		status.text = problem
		return
	document = next_doc
	_render_graph()
	status.text = "Node properties updated."

func open_graph() -> void:
	if project_path.is_empty():
		status.text = "Select a Forgefall project first."
		return
	var id := graph_id_input.text.strip_edges()
	if id.is_empty() or not id.is_valid_filename():
		status.text = "Enter a valid behavior ID."
		return
	var path := Document.path(project_path, id)
	var data := Store.read_json(path)
	var problem := Document.validate(data)
	if not problem.is_empty() or str(data.get("id", "")) != id:
		status.text = "Cannot open behavior: %s" % (problem if not problem.is_empty() else "ID mismatch")
		return
	document = data
	saved_graph_snapshot = FileAccess.get_file_as_string(path)
	selected_id = ""
	_render_graph()
	status.text = "Opened behavior %s." % id

func save_graph() -> void:
	if project_path.is_empty():
		status.text = "Select a Forgefall project first."
		return
	var problem := Document.validate(document)
	if not problem.is_empty():
		status.text = problem
		return
	var path := Document.path(project_path, str(document["id"]))
	var disk := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	if disk != saved_graph_snapshot:
		status.text = "Behavior changed outside Studio. Reopen before saving."
		return
	var error := Store.write_json(path, document)
	if error == OK:
		saved_graph_snapshot = FileAccess.get_file_as_string(path)
		graph_id_input.text = str(document["id"])
	status.text = "Behavior saved." if error == OK else "Save failed: %s" % error_string(error)

func publish_graph() -> void:
	if project_path.is_empty():
		status.text = "Select a Forgefall project first."
		return
	save_graph()
	if status.text != "Behavior saved.":
		return
	var result := Compiler.publish(project_path, document)
	status.text = "Published %s" % result.get("path", "") if result["error"].is_empty() else result["error"]

func open_source() -> void:
	var problem: String = source_workspace.open_file(project_path, path_input.text)
	status.text = problem if not problem.is_empty() else "Opened %s" % path_input.text
	if problem.is_empty():
		editor.text = source_workspace.source

func check_source() -> void:
	source_workspace.edit(editor.text)
	var result: Dictionary = source_workspace.diagnose()
	status.text = result["message"]
	if not result["ok"] and int(result.get("line", 0)) > 0:
		var row := clampi(int(result["line"]) - 1, 0, editor.get_line_count() - 1)
		editor.set_caret_line(row)
		editor.set_caret_column(0)
		editor.select(row, 0, row, editor.get_line(row).length())
		editor.grab_focus()

func save_source() -> void:
	source_workspace.edit(editor.text)
	var problem: String = source_workspace.save()
	status.text = problem if not problem.is_empty() else "GDScript saved."

func _on_gutter_clicked(line: int, gutter: int) -> void:
	if gutter < 0:
		return
	source_workspace.toggle_breakpoint(line + 1)
	editor.set_line_as_breakpoint(line, editor.is_line_breakpointed(line) == false)
