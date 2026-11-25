extends RefCounted

var _past: Array[Dictionary] = []
var _future: Array[Dictionary] = []
const MAX_COMMANDS := 100

func execute(doc: Dictionary, name: String, next_doc: Dictionary) -> Dictionary:
	if doc == next_doc:
		return doc
	_past.append({"name": name, "before": doc.duplicate(true), "after": next_doc.duplicate(true)})
	if _past.size() > MAX_COMMANDS:
		_past.pop_front()
	_future.clear()
	return next_doc.duplicate(true)

func undo(doc: Dictionary) -> Dictionary:
	if _past.is_empty():
		return doc
	var command: Dictionary = _past.pop_back()
	_future.append(command)
	return command["before"].duplicate(true)

func redo(doc: Dictionary) -> Dictionary:
	if _future.is_empty():
		return doc
	var command: Dictionary = _future.pop_back()
	_past.append(command)
	return command["after"].duplicate(true)

func can_undo() -> bool:
	return not _past.is_empty()

func can_redo() -> bool:
	return not _future.is_empty()

func to_dict() -> Dictionary:
	return {"past": _past.duplicate(true), "future": _future.duplicate(true)}

func load_dict(value: Dictionary, current_doc: Dictionary = {}) -> void:
	_clear()
	var past: Variant = value.get("past", [])
	var future: Variant = value.get("future", [])
	if not past is Array or not future is Array or past.size() > MAX_COMMANDS or future.size() > MAX_COMMANDS:
		return
	for command in past:
		if not _valid_command(command):
			_clear()
			return
		_past.append(command.duplicate(true))
	for command in future:
		if not _valid_command(command):
			_clear()
			return
		_future.append(command.duplicate(true))
	for i in range(1, _past.size()):
		if _past[i - 1]["after"] != _past[i]["before"]:
			_clear()
			return
	for i in range(_future.size() - 1, 0, -1):
		if _future[i]["after"] != _future[i - 1]["before"]:
			_clear()
			return
	if not current_doc.is_empty():
		if not _past.is_empty() and _past[-1]["after"] != current_doc:
			_clear()
			return
		if not _future.is_empty() and _future[-1]["before"] != current_doc:
			_clear()
			return

func _clear() -> void:
	_past.clear()
	_future.clear()

func _valid_command(command: Variant) -> bool:
	return command is Dictionary and command.get("name") is String and command.get("before") is Dictionary and command.get("after") is Dictionary and command["before"].get("kind") == "map" and command["after"].get("kind") == "map" and command["before"].get("id") == command["after"].get("id")
