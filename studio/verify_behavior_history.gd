extends SceneTree

# Behavior workspace transaction verification:
# - Add/delete/connect/disconnect/properties all commit through the shared
#   CommandHistory (duplicate -> validate -> execute), so each is a single
#   undoable/redoable entry.
# - A node drag produces exactly ONE history entry (press snapshot -> release
#   commit), however many position_offset_changed signals fire in between.
# - Ctrl+Z / Ctrl+Y drive undo/redo.
# - A document mutated outside the history (stale chain head) makes undo a
#   no-op instead of applying a stale snapshot.
# - History persists alongside the behavior document: save, reopen in a fresh
#   workspace, and undo still applies.

const Document = preload("res://behavior_document.gd")

var _failures := 0
var _project := "/tmp/forgefall-behavior-history"

func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)

func _past(workspace: Control) -> int:
	return workspace.history.to_dict()["past"].size()

func _node(workspace: Control, id: String) -> Dictionary:
	for entry in workspace.document["nodes"]:
		if entry["id"] == id:
			return entry
	return {}

func _key(keycode: Key, ctrl: bool, shift: bool = false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	return event

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var workspace: Control = load("res://behavior_workspace.tscn").instantiate()
	workspace.project_path = _project
	root.add_child(workspace)
	workspace.load_template("Animated Door")
	_check(workspace.document["nodes"].size() == 2 and workspace.document["edges"].size() == 1, "template starts with 2 nodes and 1 edge")
	_check(not workspace.history.can_undo(), "template load starts with an empty history")
	var source_id := str(workspace.document["nodes"][0]["id"])
	var action_id := str(workspace.document["nodes"][1]["id"])

	# Add node is one undoable entry.
	workspace.type_picker.select(Document.TYPES.find("wait"))
	workspace._add_node()
	_check(workspace.document["nodes"].size() == 3 and _past(workspace) == 1, "add node commits one history entry")
	var wait_id := str(workspace.document["nodes"][2]["id"])
	workspace._undo()
	_check(workspace.document["nodes"].size() == 2 and not workspace.history.can_undo() and workspace.history.can_redo(), "undo removes the added node")
	workspace._redo()
	_check(workspace.document["nodes"].size() == 3 and _past(workspace) == 1, "redo restores the added node")

	# Connect/disconnect are single entries each.
	workspace._connect_nodes(StringName(wait_id), 0, StringName(action_id), 0)
	_check(workspace.document["edges"].size() == 2 and _past(workspace) == 2, "connect commits one history entry")
	workspace._disconnect_nodes(StringName(wait_id), 0, StringName(action_id), 0)
	_check(workspace.document["edges"].size() == 1 and _past(workspace) == 3, "disconnect commits one history entry")
	workspace._connect_nodes(StringName(wait_id), 0, StringName(action_id), 0)
	_check(workspace.document["edges"].size() == 2 and _past(workspace) == 4, "reconnect commits one history entry")

	# Properties apply is one entry; Ctrl+Y redoes after a button undo.
	workspace._select_node(wait_id)
	workspace.properties_input.text = JSON.stringify({"seconds": 2.5})
	workspace._apply_properties()
	_check(float(_node(workspace, wait_id)["properties"].get("seconds", -1.0)) == 2.5 and _past(workspace) == 5, "properties apply commits one history entry")
	workspace._undo()
	_check(float(_node(workspace, wait_id)["properties"].get("seconds", -1.0)) != 2.5 and _past(workspace) == 4, "undo reverts the properties edit")
	workspace._unhandled_key_input(_key(KEY_Y, true))
	_check(float(_node(workspace, wait_id)["properties"].get("seconds", -1.0)) == 2.5 and _past(workspace) == 5, "Ctrl+Y redoes the properties edit")

	# A drag is grouped into exactly one entry.
	var position_before: Array = _node(workspace, wait_id)["position"].duplicate()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	workspace._on_node_input(press, wait_id)
	var graph_node := workspace.graph.get_node_or_null(NodePath(wait_id)) as GraphNode
	_check(graph_node != null, "graph node exists for the drag")
	graph_node.position_offset = Vector2(111.0, 222.0)
	graph_node.position_offset = Vector2(133.0, 244.0)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	workspace._input(release)
	_check(_past(workspace) == 6, "one drag produces exactly one history entry")
	_check(_node(workspace, wait_id)["position"] == [133.0, 244.0], "drag commits the final node position")
	workspace._unhandled_key_input(_key(KEY_Z, true))
	_check(_node(workspace, wait_id)["position"] == position_before and _past(workspace) == 5, "Ctrl+Z undoes the whole drag at once")
	workspace._redo()
	_check(_node(workspace, wait_id)["position"] == [133.0, 244.0] and _past(workspace) == 6, "redo reapplies the drag")

	# Delete removes the node and its edges as one entry.
	workspace._select_node(wait_id)
	workspace._delete_node()
	_check(workspace.document["nodes"].size() == 2 and workspace.document["edges"].size() == 1 and _past(workspace) == 7, "delete node commits one history entry")
	workspace._undo()
	_check(workspace.document["nodes"].size() == 3 and workspace.document["edges"].size() == 2 and _past(workspace) == 6, "undo restores the deleted node and its edge")

	# Stale rejection: mutate outside the history, undo must be a no-op.
	workspace.document["name"] = "Outside Edit"
	workspace._undo()
	_check(str(workspace.document["name"]) == "Outside Edit" and _past(workspace) == 6 and workspace.history.can_undo(), "stale undo is rejected and history is kept")
	workspace.document["name"] = "Animated Door"
	workspace._redo()
	_check(workspace.document["nodes"].size() == 2 and _past(workspace) == 7, "redo applies again once the document is back at the chain head")
	workspace._undo()
	_check(workspace.document["nodes"].size() == 3 and _past(workspace) == 6, "undo after the stale check still applies")

	# Persistence: save, reopen in a fresh workspace, undo still applies.
	workspace.save_graph()
	_check(workspace.status.text == "Behavior saved.", "behavior graph saves for the persistence check")
	var behavior_id := str(workspace.document["id"])
	var reopened: Control = load("res://behavior_workspace.tscn").instantiate()
	reopened.project_path = _project
	root.add_child(reopened)
	reopened.graph_id_input.text = behavior_id
	reopened.open_graph()
	_check(str(reopened.document.get("id", "")) == behavior_id, "reopened workspace loads the saved behavior")
	_check(reopened.history.can_undo() and _past(reopened) == 6, "history survives save and reopen")
	var before_undo := JSON.stringify(reopened.document)
	reopened._undo()
	_check(JSON.stringify(reopened.document) != before_undo, "undo applies after reopen")
	_check(_node(reopened, wait_id)["position"] == position_before, "undo after reopen reverts the drag to the pre-drag position")
	root.remove_child(reopened)
	reopened.free()
	root.remove_child(workspace)
	workspace.free()

	if _failures == 0:
		print("Behavior history test passed: add/delete/connect/disconnect/properties entries, drag grouping, keyboard undo/redo, stale rejection, persistence")
		quit(0)
	else:
		printerr("Behavior history test FAILED: %d check(s)" % _failures)
		quit(1)
