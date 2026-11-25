extends RefCounted

const VERSION := 1
const TYPES := ["ready", "interact", "timer", "wait", "toggle_visible", "play_animation", "area_damage", "emit_event"]

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
		nodes[id] = entry
	for edge in doc["edges"]:
		if not edge is Dictionary:
			return "Invalid graph edge."
		var a := str(edge.get("from", ""))
		var b := str(edge.get("to", ""))
		if not nodes.has(a) or not nodes.has(b) or a == b:
			return "Edge points to a missing or identical node."
		if out.has(a):
			return "Each node may have one outgoing flow."
		if ["ready", "interact", "timer"].has(str(nodes[b]["type"])):
			return "An event cannot be an action target."
		out[a] = b
	for id in nodes:
		var visited := {}
		var cursor: String = id
		while out.has(cursor):
			if visited.has(cursor):
				return "Behavior flow contains a cycle."
			visited[cursor] = true
			cursor = out[cursor]
	return ""

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
	return "%08x-%08x-%08x-%08x" % [randi(), randi(), randi(), randi()]
