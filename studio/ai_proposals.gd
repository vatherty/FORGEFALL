extends RefCounted

const Store = preload("res://shared/document_store.gd")
const MAX_ACTIONS := 32
const MAX_TEXT := 2000

static func parse_response(raw: String, current: Dictionary) -> Dictionary:
	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary:
		return {"error": "Provider response must be a JSON object."}
	if parsed.has("proposal") and parsed["proposal"] is Dictionary:
		parsed = parsed["proposal"]
	var actions: Variant = parsed.get("actions", [])
	if not actions is Array or actions.is_empty() or actions.size() > MAX_ACTIONS:
		return {"error": "Proposal needs 1 to 32 actions."}
	var next_doc: Dictionary = current.duplicate(true)
	var summary: Array[String] = []
	for action in actions:
		var error := _apply_action(next_doc, action, summary)
		if error != "":
			return {"error": error}
	var validation := Store.validate_map(next_doc)
	if validation != "":
		return {"error": validation}
	return {"error": "", "document": next_doc, "summary": "\n".join(summary), "base": JSON.stringify(current)}

static func _apply_action(doc: Dictionary, action: Variant, summary: Array[String]) -> String:
	if not action is Dictionary:
		return "Each action must be an object."
	var kind := str(action.get("type", ""))
	if kind == "add_block":
		var position := _vector(action.get("position"), false)
		var size := _vector(action.get("size", [1, 1, 1]), true)
		var color := str(action.get("color", "#d39456"))
		if position.is_empty() or size.is_empty() or not _color_valid(color):
			return "Invalid block position, size, or color."
		var name := _short_name(action.get("name", "Block"))
		if name == "":
			return "Block name is invalid."
		var item := Store.new_instance(name, Vector3(position[0], position[1], position[2]))
		item["size"] = size
		item["color"] = color
		doc["instances"].append(item)
		summary.append("Add block %s at %s" % [name, str(position)])
		return ""
	if kind == "move_instance" or kind == "recolor_instance" or kind == "rename_instance":
		var id := str(action.get("id", ""))
		for item in doc["instances"]:
			if str(item.get("id", "")) != id:
				continue
			if kind == "move_instance":
				var position := _vector(action.get("position"), false)
				if position.is_empty():
					return "Invalid position for " + id
				item["position"] = position
				summary.append("Move %s to %s" % [str(item.get("name", id)), str(position)])
			elif kind == "recolor_instance":
				if str(item.get("kind", "")) != "block":
					return "Only blocks can be recolored."
				var color := str(action.get("color", ""))
				if not _color_valid(color):
					return "Invalid color for " + id
				item["color"] = color
				summary.append("Recolor " + str(item.get("name", id)) + " to " + color)
			else:
				var name := _short_name(action.get("name", ""))
				if name == "":
					return "Invalid name for " + id
				item["name"] = name
				summary.append("Rename instance to " + name)
			return ""
		return "Unknown instance ID: " + id
	return "Unsupported action: " + kind

static func _vector(value: Variant, positive: bool) -> Array:
	if not value is Array or value.size() != 3:
		return []
	var result := []
	for component in value:
		if not component is float and not component is int:
			return []
		var number := float(component)
		if not is_finite(number) or absf(number) > 10000.0 or (positive and number <= 0.0):
			return []
		result.append(snappedf(number, 0.125))
	return result

static func _color_valid(value: String) -> bool:
	if value.length() != 7 or not value.begins_with("#"):
		return false
	for character in value.substr(1):
		if not character.to_lower() in "0123456789abcdef":
			return false
	return true

static func _short_name(value: Variant) -> String:
	var name := str(value).strip_edges()
	if name.is_empty() or name.length() > 64 or "\n" in name or "\r" in name:
		return ""
	return name
