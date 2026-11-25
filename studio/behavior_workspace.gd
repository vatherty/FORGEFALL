extends Control

const Document = preload("res://behavior_document.gd")
const Compiler = preload("res://behavior_compiler.gd")
const Source = preload("res://behavior_source.gd")
const Store = preload("res://shared/document_store.gd")
const History = preload("res://command_history.gd")

var project_path := ""
var document: Dictionary = Document.create("New Behavior")
var history := History.new()
var undo_button: Button
var redo_button: Button
var _drag_active := false
var _drag_snapshot: Dictionary = {}
var _drag_dirty := false
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
	undo_button = _add_history_button(bar, "Undo", _undo)
	redo_button = _add_history_button(bar, "Redo", _redo)
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

func _add_history_button(parent: Control, label: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func load_template(template_name: String) -> void:
	_abort_drag()
	document = Document.template(template_name)
	history = History.new()
	saved_graph_snapshot = ""
	graph_id_input.text = str(document["id"])
	selected_id = ""
	_render_graph()
	status.text = "Loaded %s template." % template_name

# Every document mutation goes through here: the caller has already built and
# validated next_doc, so execute() only has to keep the history chain honest.
# A stale document (mutated outside this path) makes execute() a no-op, which
# is the shared CommandHistory contract for all Studio document kinds.
func _commit(name: String, next_doc: Dictionary) -> void:
	document = history.execute(document, name, next_doc)
	_persist_history()
	_render_graph()

func _undo() -> void:
	_abort_drag()
	if not history.can_undo():
		return
	document = history.undo(document)
	_persist_history()
	_sync_selection()
	_render_graph()

func _redo() -> void:
	_abort_drag()
	if not history.can_redo():
		return
	document = history.redo(document)
	_persist_history()
	_sync_selection()
	_render_graph()

func _sync_selection() -> void:
	if selected_id.is_empty():
		return
	for entry in document["nodes"]:
		if entry["id"] == selected_id:
			properties_input.text = JSON.stringify(entry["properties"])
			return
	selected_id = ""
	properties_input.text = ""

func _history_path() -> String:
	return "user://history/behavior_" + project_path.sha256_text().substr(0, 16) + "_" + str(document.get("id", "")) + ".json"

func _persist_history() -> void:
	if project_path.is_empty() or document.is_empty():
		return
	Store.write_json(ProjectSettings.globalize_path(_history_path()), history.to_dict())

func _load_history() -> void:
	if project_path.is_empty() or document.is_empty():
		return
	history.load_dict(Store.read_json(ProjectSettings.globalize_path(_history_path())), document)

func _add_node() -> void:
	var type := type_picker.get_item_text(type_picker.selected)
	var entry: Dictionary = Document.node(type)
	entry["position"] = [graph.scroll_offset.x + 200.0, graph.scroll_offset.y + 150.0]
	var next_doc: Dictionary = document.duplicate(true)
	next_doc["nodes"].append(entry)
	var problem := Document.validate(next_doc)
	if not problem.is_empty():
		status.text = problem
		return
	_commit("Add node", next_doc)

func _delete_node() -> void:
	if selected_id.is_empty():
		return
	var next_doc: Dictionary = document.duplicate(true)
	for index in range(next_doc["nodes"].size() - 1, -1, -1):
		if next_doc["nodes"][index]["id"] == selected_id:
			next_doc["nodes"].remove_at(index)
	for index in range(next_doc["edges"].size() - 1, -1, -1):
		var edge: Dictionary = next_doc["edges"][index]
		if edge["from"] == selected_id or edge["to"] == selected_id:
			next_doc["edges"].remove_at(index)
	var problem := Document.validate(next_doc)
	if not problem.is_empty():
		status.text = problem
		return
	selected_id = ""
	_commit("Delete node", next_doc)

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
		if entry["type"] == "condition":
			# Slot 0 carries the flow in and the "true" branch out; slot 1 is
			# the "false" branch. Colors keep the two outputs apart at a glance.
			node.set_slot_enabled_left(1, false)
			node.set_slot_enabled_right(1, true)
			node.set_slot_color_right(0, Color(0.45, 0.95, 0.55))
			node.set_slot_color_right(1, Color(0.98, 0.45, 0.4))
			var false_label := Label.new()
			false_label.text = "false branch"
			node.add_child(false_label)
		node.gui_input.connect(_on_node_input.bind(str(entry["id"])))
		node.position_offset_changed.connect(_record_positions)
		graph.add_child(node)
	for edge in document["edges"]:
		var port := 0
		if str(edge.get("port", "")) == "false":
			port = 1
		graph.connect_node(str(edge["from"]), port, str(edge["to"]), 0)
	if undo_button != null:
		undo_button.disabled = not history.can_undo()
	if redo_button != null:
		redo_button.disabled = not history.can_redo()

func _select_node(id: String) -> void:
	selected_id = id
	for entry in document["nodes"]:
		if entry["id"] == id:
			properties_input.text = JSON.stringify(entry["properties"])
			break

func _on_node_input(event: InputEvent, id: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_select_node(id)
		_begin_drag()

# A GraphEdit drag fires position_offset_changed continuously, and there is
# no drag-begin/drag-end signal for node movement. The press on a node opens
# a transaction (snapshot of the document); position changes are written into
# the document live while dragging, and the mouse release commits exactly one
# history entry from the snapshot to the final positions. A position change
# with no drag in progress (programmatic nudge) commits as its own entry.
func _begin_drag() -> void:
	if _drag_active:
		return
	_drag_active = true
	_drag_dirty = false
	_drag_snapshot = document.duplicate(true)

func _end_drag() -> void:
	if not _drag_active:
		return
	_drag_active = false
	if not _drag_dirty:
		_drag_snapshot = {}
		return
	_drag_dirty = false
	var next_doc: Dictionary = document.duplicate(true)
	var before: Dictionary = _drag_snapshot
	_drag_snapshot = {}
	document = history.execute(before, "Move node", next_doc)
	_persist_history()
	_render_graph()

func _abort_drag() -> void:
	if not _drag_active:
		return
	_drag_active = false
	_drag_dirty = false
	if not _drag_snapshot.is_empty():
		document = _drag_snapshot
	_drag_snapshot = {}

func _input(event: InputEvent) -> void:
	if _drag_active and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_end_drag()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_end_drag()

func _record_positions() -> void:
	if not _drag_active:
		_begin_drag()
		_copy_positions()
		_end_drag()
		return
	_copy_positions()
	_drag_dirty = true

func _copy_positions() -> void:
	for entry in document["nodes"]:
		var graph_node := graph.get_node_or_null(NodePath(str(entry["id"]))) as GraphNode
		if graph_node != null:
			entry["position"] = [graph_node.position_offset.x, graph_node.position_offset.y]

func _node_type(id: String) -> String:
	for entry in document["nodes"]:
		if entry["id"] == id:
			return str(entry["type"])
	return ""

func _connect_nodes(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	var next_doc: Dictionary = document.duplicate(true)
	var branching := _node_type(str(from_node)) == "condition"
	var port := "false" if from_port == 1 else "true"
	for index in range(next_doc["edges"].size() - 1, -1, -1):
		var existing: Dictionary = next_doc["edges"][index]
		if str(existing["from"]) != str(from_node):
			continue
		# Plain nodes replace their single flow; conditions replace one branch.
		if not branching or str(existing.get("port", "")) == port:
			next_doc["edges"].remove_at(index)
	var edge := {"from": str(from_node), "to": str(to_node)}
	if branching:
		edge["port"] = port
	next_doc["edges"].append(edge)
	var problem := Document.validate(next_doc)
	if not problem.is_empty():
		status.text = problem
		return
	_commit("Connect nodes", next_doc)

func _disconnect_nodes(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	var port := "false" if from_port == 1 else "true"
	var next_doc: Dictionary = document.duplicate(true)
	for index in range(next_doc["edges"].size() - 1, -1, -1):
		var edge: Dictionary = next_doc["edges"][index]
		if edge["from"] == str(from_node) and edge["to"] == str(to_node) and (not edge.has("port") or str(edge["port"]) == port):
			next_doc["edges"].remove_at(index)
	var problem := Document.validate(next_doc)
	if not problem.is_empty():
		status.text = problem
		return
	_commit("Disconnect nodes", next_doc)

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
	_commit("Edit properties", next_doc)
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
	_abort_drag()
	document = data
	history = History.new()
	_load_history()
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
		_persist_history()
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
		editor.clear_undo_history()

func check_source() -> void:
	source_workspace.edit(editor.text)
	var result: Dictionary = source_workspace.diagnose()
	status.text = result["message"]
	if not result["ok"] and int(result.get("line", 0)) > 0:
		var row := clampi(int(result["line"]) - 1, 0, editor.get_line_count() - 1)
		var column := clampi(int(result.get("column", 0)) - 1, 0, editor.get_line(row).length())
		editor.set_caret_line(row)
		editor.set_caret_column(column)
		editor.select(row, column, row, editor.get_line(row).length())
		editor.grab_focus()

func save_source() -> void:
	source_workspace.edit(editor.text)
	var problem: String = source_workspace.save()
	status.text = problem if not problem.is_empty() else "GDScript saved."

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.ctrl_pressed and event.keycode == KEY_Z and event.shift_pressed:
			_redo()
		elif event.ctrl_pressed and event.keycode == KEY_Z:
			_undo()
		elif event.ctrl_pressed and event.keycode == KEY_Y:
			_redo()

func _on_gutter_clicked(line: int, gutter: int) -> void:
	if gutter < 0:
		return
	source_workspace.toggle_breakpoint(line + 1)
	editor.set_line_as_breakpoint(line, editor.is_line_breakpointed(line) == false)
