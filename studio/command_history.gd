extends RefCounted

var _past: Array[Dictionary] = []
var _future: Array[Dictionary] = []
const MAX_COMMANDS := 100

# The shared transaction history for every Studio document kind (map, asset,
# behavior, character, weapon). Commands form a chain: each command's
# "before" must equal the previous command's "after". A surface that mutates
# its document outside execute() breaks the chain, and execute/undo/redo
# then reject the operation (returning the document unchanged) instead of
# silently applying a stale snapshot or recording a corrupt history that
# load_dict would later have to discard wholesale.

# Documents cross JSON boundaries constantly (the document file and the
# history file are separate JSON stores), and JSON turns ints into floats.
# Dictionary == treats 1 and 1.0 as different, so every chain comparison
# goes through a canonical form where integral floats become ints.
static func _canonical(value: Variant) -> Variant:
	if value is float:
		var f := float(value)
		if is_finite(f) and f == floor(f) and absf(f) < 9007199254740992.0:
			return int(f)
		return f
	if value is Dictionary:
		var out := {}
		for key in value:
			out[key] = _canonical(value[key])
		return out
	if value is Array:
		var out := []
		for item in value:
			out.append(_canonical(item))
		return out
	return value

static func _same(a: Variant, b: Variant) -> bool:
	return _canonical(a) == _canonical(b)

func _chain_head() -> Dictionary:
	if not _past.is_empty():
		return _past[-1]["after"]
	if not _future.is_empty():
		return _future[-1]["before"]
	return {}

func _is_chain_head(doc: Dictionary) -> bool:
	var head := _chain_head()
	return head.is_empty() or _same(head, doc)

func execute(doc: Dictionary, name: String, next_doc: Dictionary) -> Dictionary:
	if _same(doc, next_doc):
		return doc
	if not _is_chain_head(doc):
		return doc
	var command := {"name": name, "before": doc.duplicate(true), "after": next_doc.duplicate(true)}
	if not _valid_command(command):
		return doc
	_past.append(command)
	if _past.size() > MAX_COMMANDS:
		_past.pop_front()
	_future.clear()
	return next_doc.duplicate(true)

func undo(doc: Dictionary) -> Dictionary:
	if _past.is_empty():
		return doc
	if not _same(doc, _past[-1]["after"]):
		return doc
	var command: Dictionary = _past.pop_back()
	_future.append(command)
	return command["before"].duplicate(true)

func redo(doc: Dictionary) -> Dictionary:
	if _future.is_empty():
		return doc
	if not _same(doc, _future[-1]["before"]):
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
		if not _same(_past[i - 1]["after"], _past[i]["before"]):
			_clear()
			return
	for i in range(_future.size() - 1, 0, -1):
		if not _same(_future[i]["after"], _future[i - 1]["before"]):
			_clear()
			return
	if not _past.is_empty() and not _future.is_empty() and not _same(_past[-1]["after"], _future[-1]["before"]):
		_clear()
		return
	if not current_doc.is_empty():
		if not _past.is_empty() and not _same(_past[-1]["after"], current_doc):
			_clear()
			return
		if not _future.is_empty() and not _same(_future[-1]["before"], current_doc):
			_clear()
			return

func _clear() -> void:
	_past.clear()
	_future.clear()

func _valid_command(command: Variant) -> bool:
	if not command is Dictionary or not command.get("name") is String or not command.get("before") is Dictionary or not command.get("after") is Dictionary:
		return false
	var before: Dictionary = command["before"]
	var after: Dictionary = command["after"]
	var kind: Variant = before.get("kind")
	return kind is String and not (kind as String).is_empty() and after.get("kind") == kind and before.get("id") == after.get("id")
