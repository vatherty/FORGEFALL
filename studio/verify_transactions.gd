extends SceneTree

# Transaction-coverage verification (Stage 1):
# - CommandHistory is the shared transaction layer for every document kind,
#   not just maps: persisted histories for asset/behavior documents must
#   survive a to_dict/load_dict round trip.
# - Stale operations are rejected: if a surface's document no longer matches
#   the head of the history chain (it was mutated outside execute), then
#   execute/undo/redo return the document unchanged instead of applying a
#   stale snapshot or recording a corrupt command.
# - Behavior workspace disconnect uses the same duplicate/validate/assign
#   discipline as connect (no direct in-place document mutation).
# - Content workshop: opening/new documents clear the text editor's undo
#   history (undo cannot cross a document replacement), while form commits
#   remain single undoable transactions in the editor.
# - Web maps: document replacement is refused while the open map has
#   undownloaded edits, and replacement resets the editor history.

const Store = preload("res://shared/document_store.gd")
const Asset = preload("res://shared/asset_document.gd")
const Behavior = preload("res://behavior_document.gd")
const History = preload("res://command_history.gd")

var _failures := 0

func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_history_semantics()
	_behavior_workspace()
	_content_workshop()
	_web_maps()
	if _failures == 0:
		print("Transaction test passed: shared history for all document kinds, stale rejection, behavior disconnect discipline, content undo boundaries, web map replacement")
		quit(0)
	else:
		printerr("Transaction test FAILED: %d check(s)" % _failures)
		quit(1)

func _history_semantics() -> void:
	var map_doc: Dictionary = Store.new_map("Tx Test")
	var history := History.new()
	var added: Dictionary = map_doc.duplicate(true)
	added["instances"].append(Store.new_instance("Block", Vector3.ZERO))
	map_doc = history.execute(map_doc, "Add block", added)
	_check(map_doc["instances"].size() == 1 and history.can_undo(), "map execute records a command")
	var stale: Dictionary = map_doc.duplicate(true)
	stale["name"] = "Mutated outside history"
	_check(history.undo(stale) == stale and history.can_undo(), "stale undo is rejected and history is kept")
	_check(history.execute(stale, "Sneak edit", added) == stale and history.to_dict()["past"].size() == 1, "stale execute is rejected")
	map_doc = history.undo(map_doc)
	_check(map_doc["instances"].is_empty(), "undo at the chain head applies")
	var stale_redo: Dictionary = map_doc.duplicate(true)
	stale_redo["name"] = "Mutated outside history"
	_check(history.redo(stale_redo) == stale_redo and history.can_redo(), "stale redo is rejected and future is kept")
	map_doc = history.redo(map_doc)
	_check(map_doc["instances"].size() == 1, "redo at the chain head applies")
	map_doc = history.undo(map_doc)
	var branch: Dictionary = map_doc.duplicate(true)
	branch["instances"].append(Store.new_instance("Light", Vector3.ONE))
	map_doc = history.execute(map_doc, "Branch", branch)
	_check(not history.can_redo() and str(map_doc["instances"][0]["name"]) == "Light", "execute after undo branches and clears redo")

	var asset_doc: Dictionary = Asset.create("Tx Asset")
	var asset_history := History.new()
	asset_doc = asset_history.execute(asset_doc, "Place voxel", Asset.set_voxel(asset_doc, 1, 0, 0, 0))
	var asset_reopened := History.new()
	asset_reopened.load_dict(asset_history.to_dict(), asset_doc)
	_check(asset_reopened.can_undo(), "asset history survives to_dict/load_dict round trip")
	_check(asset_reopened.undo(asset_doc)["voxels"].is_empty(), "asset undo applies after reload")

	var behavior_doc: Dictionary = Behavior.create("Tx Behavior")
	var behavior_history := History.new()
	var with_node: Dictionary = behavior_doc.duplicate(true)
	with_node["nodes"].append(Behavior.node("ready"))
	behavior_doc = behavior_history.execute(behavior_doc, "Add node", with_node)
	var behavior_reopened := History.new()
	behavior_reopened.load_dict(behavior_history.to_dict(), behavior_doc)
	_check(behavior_reopened.can_undo() and behavior_reopened.undo(behavior_doc)["nodes"].is_empty(), "behavior history persists and undoes after reload")

	var mismatched := {"past": [{"name": "x", "before": Store.new_map("A"), "after": Asset.create("B")}], "future": []}
	var strict := History.new()
	strict.load_dict(mismatched, behavior_doc)
	_check(not strict.can_undo(), "load_dict rejects a kind-mismatched command")

func _behavior_workspace() -> void:
	var workspace: Control = load("res://behavior_workspace.tscn").instantiate()
	root.add_child(workspace)
	workspace.load_template("Animated Door")
	_check(workspace.document["edges"].size() == 1, "behavior template starts with one edge")
	var edge: Dictionary = workspace.document["edges"][0]
	workspace._disconnect_nodes(StringName(str(edge["from"])), 0, StringName(str(edge["to"])), 0)
	_check(workspace.document["edges"].is_empty() and Behavior.validate(workspace.document) == "", "disconnect removes the edge and the document stays valid")
	workspace._connect_nodes(StringName(str(edge["from"])), 0, StringName(str(edge["to"])), 0)
	_check(workspace.document["edges"].size() == 1, "connect restores the edge after disconnect")
	root.remove_child(workspace)
	workspace.free()

func _content_workshop() -> void:
	var workshop: Control = load("res://content_workshop.tscn").instantiate()
	workshop.project_path = "/tmp/forgefall-tx-workshop"
	root.add_child(workshop)
	workshop._new("weapon")
	_check(not workshop.editor.has_undo(), "content editor undo history is cleared on New")
	var before_text: String = workshop.editor.text
	workshop.weapon_values[0].value = 33.0
	workshop._apply_weapon_fields()
	_check(float(JSON.parse_string(workshop.editor.text)["damage"]) == 33.0, "weapon form commit applies")
	_check(workshop.editor.has_undo(), "form commit is recorded as an undoable transaction")
	workshop.editor.undo()
	_check(workshop.editor.text == before_text, "one undo reverts the whole form commit")
	workshop.editor.redo()
	_check(float(JSON.parse_string(workshop.editor.text)["damage"]) == 33.0, "redo reapplies the form commit")
	root.remove_child(workshop)
	workshop.free()

func _web_maps() -> void:
	var editor: Control = load("res://main.tscn").instantiate()
	root.add_child(editor)
	var web_maps: Window = load("res://web_maps.tscn").instantiate()
	web_maps.editor = editor
	root.add_child(web_maps)
	web_maps._new_map()
	_check(editor.map_doc.get("kind") == "map" and not editor.history.can_undo(), "web new map replaces the document with a fresh history")
	editor._add_block()
	_check(editor.map_doc["instances"].size() == 1 and editor.history.can_undo(), "web editor edits go through the transaction history")
	web_maps._new_map()
	_check(editor.map_doc["instances"].size() == 1, "web replacement is refused while the map has undownloaded edits")
	editor.saved_text = JSON.stringify(editor.map_doc)
	web_maps.json_edit.text = JSON.stringify(Store.new_map("Imported Web"))
	web_maps._import_json()
	_check(str(editor.map_doc.get("name", "")) == "Imported Web" and editor.map_doc["instances"].is_empty() and not editor.history.can_undo(), "web import replaces the document and resets history")
	root.remove_child(web_maps)
	web_maps.free()
	root.remove_child(editor)
	editor.free()
