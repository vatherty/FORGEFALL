extends SceneTree

const Store = preload("res://shared/document_store.gd")
const Proposals = preload("res://ai_proposals.gd")
const History = preload("res://command_history.gd")

func _initialize() -> void:
	var original: Dictionary = Store.new_map("AI test")
	var block: Dictionary = Store.new_instance("Old", Vector3.ZERO)
	original["instances"].append(block)
	var raw := JSON.stringify({"actions": [
		{"type": "add_block", "name": "New", "position": [2, 0, 1], "size": [1, 2, 1], "color": "#abcdef"},
		{"type": "move_instance", "id": block["id"], "position": [1, 0, 0]},
		{"type": "recolor_instance", "id": block["id"], "color": "#123456"}
	]})
	var proposal: Dictionary = Proposals.parse_response(raw, original)
	_check(proposal.get("error", "") == "", "valid proposal")
	_check(proposal["document"]["instances"].size() == 2, "new block")
	_check(original["instances"][0]["position"] == [0.0, 0.0, 0.0], "original untouched")
	var history := History.new()
	var applied: Dictionary = history.execute(original, "Apply AI proposal", proposal["document"])
	_check(history.undo(applied) == original, "single-step undo")
	_check(history.redo(original) == applied, "single-step redo")
	_check(Proposals.parse_response("{\"actions\":[{\"type\":\"delete_instance\"}]}", original).get("error", "") != "", "unsupported action rejected")
	_check(Proposals.parse_response("{\"actions\":[{\"type\":\"add_block\",\"position\":[1,2,3],\"color\":\"oops\"}]}", original).get("error", "") != "", "invalid color rejected")
	_check(Proposals.parse_response("{\"actions\":[{\"type\":\"move_instance\",\"id\":\"missing\",\"position\":[1,2,3]}]}", original).get("error", "") != "", "unknown ID rejected")
	var scene: PackedScene = load("res://ai_assistant.tscn")
	_check(scene != null, "assistant scene loads")
	print("PASS AI proposals, validation, undo/redo, and assistant scene")
	quit(0)

func _check(condition: bool, name: String) -> void:
	if not condition:
		push_error("FAIL: " + name)
		quit(1)
