extends RefCounted

const Store = preload("shared/document_store.gd")

const VERSION := 1
const TYPES := ["ready", "interact", "timer", "wait", "toggle_visible", "play_animation", "area_damage", "emit_event", "condition"]
const CONDITION_OPERATORS := ["==", "!=", ">", ">=", "<", "<="]
const CONDITION_PORTS := ["true", "false"]

static func create(title: String) -> Dictionary:
	return {"version": VERSION, "kind": "behavior", "id": _id(), "name": title, "nodes": [], "edges": []}

static func node(type: String, properties: Dictionary = {}) -> Dictionary:
	return {"id": _id(), "type": type, "properties": properties.duplicate(true), "position": [0.0, 0.0]}

static func template(name: String) -> Dictionary:
	var result := create(name)
	var source: Dictionary
	var action: Dictionary
	match name:
		"Animated Door":
			source = node("interact")
			action = node("play_animation", {"target": "AnimationPlayer", "animation": "open"})
		"Timed Lift":
			source = node("timer", {"seconds": 3.0, "repeat": true})
			action = node("play_animation", {"target": "AnimationPlayer", "animation": "lift"})
		"Explosive Barrel":
			source = node("interact")
			action = node("area_damage", {"radius": 3.0, "amount": 50.0})
		_:
			return result
	result["nodes"] = [source, action]
	result["edges"] = [{"from": source["id"], "to": action["id"]}]
	return result

static func validate(doc: Dictionary) -> String:
	if doc.get("version") != VERSION or doc.get("kind") != "behavior":
		return "Unsupported behavior document."
	if not _safe_id(str(doc.get("id", ""))):
		return "Behavior ID is invalid."
	if not doc.get("nodes") is Array or not doc.get("edges") is Array:
		return "Nodes and edges must be arrays."
	if doc["nodes"].size() > 128 or doc["edges"].size() > 128:
		return "Behavior graph exceeds 128 nodes or edges."
	var nodes := {}
	var out := {}
	for entry in doc["nodes"]:
		if not entry is Dictionary:
			return "Invalid graph node."
		var id := str(entry.get("id", ""))
		var type := str(entry.get("type", ""))
		if not _safe_id(id) or nodes.has(id) or not TYPES.has(type):
			return "Invalid or duplicate graph node ID/type."
		if not entry.get("properties") is Dictionary:
			return "Node properties must be an object."
		if type == "timer" or type == "wait":
			var seconds: Variant = entry["properties"].get("seconds", 1.0)
			if not (seconds is int or seconds is float) or not is_finite(float(seconds)) or float(seconds) <= 0.0 or float(seconds) > 3600.0:
				return "Timer duration must be between 0 and 3600 seconds."
		if type == "area_damage":
			var radius: Variant = entry["properties"].get("radius", 3.0)
			if not (radius is int or radius is float) or not is_finite(float(radius)) or float(radius) <= 0.0 or float(radius) > 100.0:
				return "Damage radius is invalid."
			var amount: Variant = entry["properties"].get("amount", 0.0)
			if not (amount is int or amount is float) or not is_finite(float(amount)) or float(amount) < 0.0 or float(amount) > 100000.0:
				return "Damage amount is invalid."
		if type == "condition":
			var problem := _validate_condition(entry["properties"])
			if not problem.is_empty():
				return problem
		nodes[id] = entry
	# The compiler names generated variables after node IDs with unsafe
	# characters folded to "_" (a-b and a_b both become a_b); two IDs that
	# fold to the same name would generate unparseable GDScript, so the
	# document must reject them here instead of publishing broken code.
	var safe_names := {}
	for id in nodes:
		var safe := ""
		for character in id:
			safe += character if character.is_valid_identifier() or character.is_valid_int() else "_"
		if safe_names.has(safe):
			return "Graph node IDs '%s' and '%s' collide when compiled." % [safe_names[safe], id]
		safe_names[safe] = id
	var adjacency := {}
	for id in nodes:
		adjacency[id] = []
	var ports := {}
	for edge in doc["edges"]:
		if not edge is Dictionary:
			return "Invalid graph edge."
		var a := str(edge.get("from", ""))
		var b := str(edge.get("to", ""))
		if not nodes.has(a) or not nodes.has(b) or a == b:
			return "Edge points to a missing or identical node."
		if ["ready", "interact", "timer"].has(str(nodes[b]["type"])):
			return "An event cannot be an action target."
		if str(nodes[a]["type"]) == "condition":
			var port: Variant = edge.get("port", "")
			if not port is String or not CONDITION_PORTS.has(port):
				return "Condition outputs must be labeled \"true\" or \"false\"."
			var used: Dictionary = ports.get(a, {})
			if used.has(port):
				return "A condition output may have one outgoing flow."
			used[port] = true
			ports[a] = used
		else:
			if edge.has("port"):
				return "Only condition nodes have labeled outputs."
			if out.has(a):
				return "Each node may have one outgoing flow."
			out[a] = b
		adjacency[a].append(b)
	# Cycle check over the full multi-edge graph (iterative DFS, gray = on stack).
	var color := {}
	for id in nodes:
		color[id] = 0
	for start in nodes:
		if color[start] != 0:
			continue
		color[start] = 1
		var stack: Array = [[start, 0]]
		while not stack.is_empty():
			var frame: Array = stack[stack.size() - 1]
			var cursor: String = frame[0]
			var neighbors: Array = adjacency[cursor]
			if int(frame[1]) >= neighbors.size():
				color[cursor] = 2
				stack.pop_back()
				continue
			frame[1] = int(frame[1]) + 1
			var following: String = neighbors[int(frame[1]) - 1]
			if color[following] == 1:
				return "Behavior flow contains a cycle."
			if color[following] == 0:
				color[following] = 1
				stack.append([following, 0])
	return ""

static func _validate_condition(properties: Dictionary) -> String:
	var target: Variant = properties.get("target", ".")
	if not target is String or str(target).length() > 256:
		return "Condition target must be a node path string."
	var property: Variant = properties.get("property", "visible")
	if not property is String or not _is_identifier(str(property)):
		return "Condition property must be a property name."
	var operator: Variant = properties.get("operator", "==")
	if not operator is String or not CONDITION_OPERATORS.has(operator):
		return "Condition operator must be one of ==, !=, >, >=, <, <=."
	var value: Variant = properties.get("value", false)
	if value is String:
		if str(value).length() > 128:
			return "Condition comparison text is too long."
	elif value is int or value is float:
		if not is_finite(float(value)):
			return "Condition comparison value must be finite."
	elif not value is bool:
		return "Condition comparison value must be a boolean, number, or text."
	return ""

static func _is_identifier(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for index in value.length():
		var character := value[index]
		if character == "_" or character.to_lower() in "abcdefghijklmnopqrstuvwxyz":
			continue
		if index > 0 and character.is_valid_int():
			continue
		return false
	return true

static func _safe_id(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for character in value:
		if not (character.is_valid_int() or character.to_lower() in "abcdefghijklmnopqrstuvwxyz" or character == "-" or character == "_"):
			return false
	return true

static func path(project: String, id: String) -> String:
	return project.path_join("assets/studio/behaviors").path_join(id + ".json")

static func _id() -> String:
	return Store.new_id()
