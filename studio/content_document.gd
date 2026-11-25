extends RefCounted

const Store = preload("shared/document_store.gd")

static func new_character(name: String) -> Dictionary:
	return {"version": 1, "kind": "character", "id": _id(), "name": name, "asset_id": "", "weapon_id": "", "health": 100.0, "auto_fire": true, "sight_range": 25.0, "move_speed": 2.5, "stride_length": 0.7, "swing_degrees": 28.0, "parts": [{"name": "Body", "parent": "", "position": [0.0, 0.9, 0.0], "size": [0.5, 1.2, 0.3], "color": "#8298a8"}, {"name": "Hand", "parent": "Body", "position": [0.35, 0.15, -0.1], "size": [0.15, 0.15, 0.15], "color": "#d5b595"}]}

static func new_weapon(name: String) -> Dictionary:
	return {"version": 1, "kind": "weapon", "id": _id(), "name": name, "asset_id": "", "damage": 12.0, "range": 30.0, "cooldown": 0.25, "magazine": 12, "muzzle": [0.0, 0.0, -0.3]}

static func path(project: String, doc: Dictionary) -> String:
	return project.path_join("assets/studio/%ss" % str(doc.get("kind", ""))).path_join(str(doc.get("id", "")) + ".json")

static func validate(doc: Dictionary) -> String:
	if doc.get("version") != 1 or not str(doc.get("kind", "")) in ["character", "weapon"]:
		return "Unsupported content document."
	if not safe_id(str(doc.get("id", ""))):
		return "Invalid content ID."
	if str(doc.get("name", "")).strip_edges().is_empty():
		return "Content needs a name."
	if not _optional_id(doc.get("asset_id", "")):
		return "Invalid visual asset ID."
	if doc["kind"] == "weapon":
		for field in ["damage", "range", "cooldown"]:
			if not _finite_positive(doc.get(field, -1.0)):
				return "Invalid weapon " + field + "."
		if not _finite_positive(doc.get("magazine", -1)) or not is_equal_approx(float(doc["magazine"]), roundf(float(doc["magazine"]))) or int(doc["magazine"]) > 10000:
			return "Invalid magazine size."
		if not valid_vec(doc.get("muzzle")):
			return "Invalid muzzle position."
	else:
		if not _optional_id(doc.get("weapon_id", "")) or not _finite_positive(doc.get("health", -1.0)):
			return "Invalid character weapon or health."
		if not doc.get("auto_fire", true) is bool or not _finite_positive(doc.get("sight_range", 25.0)) or float(doc.get("sight_range", 25.0)) > 1000.0:
			return "Invalid character firing settings."
		if not _finite_nonnegative(doc.get("move_speed", 2.5)) or float(doc.get("move_speed", 2.5)) > 20.0:
			return "Invalid character movement speed."
		if not _finite_positive(doc.get("stride_length", 0.7)) or float(doc.get("stride_length", 0.7)) > 5.0:
			return "Invalid character stride length."
		if not _finite_nonnegative(doc.get("swing_degrees", 28.0)) or float(doc.get("swing_degrees", 28.0)) > 80.0:
			return "Invalid character swing angle."
		var parts: Variant = doc.get("parts")
		if not parts is Array or parts.is_empty() or parts.size() > 32:
			return "Character needs 1 to 32 rig parts."
		var names := {}
		for part in parts:
			if not part is Dictionary:
				return "Invalid rig part."
			var name := str(part.get("name", ""))
			if not safe_name(name) or names.has(name) or not valid_vec(part.get("position")) or not valid_vec(part.get("size")):
				return "Invalid or duplicate rig part."
			for size in part["size"]:
				if float(size) <= 0:
					return "Rig part size must be positive."
			if not Color.html_is_valid(str(part.get("color", ""))):
				return "Invalid rig color."
			if not str(part.get("limb", "")) in ["", "leg_left", "leg_right", "arm_left", "arm_right", "body"]:
				return "Invalid rig limb role."
			names[name] = true
		for part in parts:
			var parent := str(part.get("parent", ""))
			if parent != "" and (not names.has(parent) or parent == part["name"]):
				return "Rig parent is missing or self-referential."
			var visited := {str(part["name"]): true}
			while parent != "":
				if visited.has(parent):
					return "Rig has a parent cycle."
				visited[parent] = true
				for candidate in parts:
					if candidate["name"] == parent:
						parent = str(candidate.get("parent", ""))
						break
	return ""

static func validate_animations(animations: Variant) -> String:
	if not animations is Array or animations.size() > 16:
		return "Invalid asset animations."
	var names := {}
	for animation in animations:
		if not animation is Dictionary or not safe_name(str(animation.get("name", ""))) or names.has(animation.get("name")):
			return "Invalid or duplicate animation name."
		names[animation["name"]] = true
		var keys: Variant = animation.get("keys")
		if not keys is Array or keys.size() < 2 or keys.size() > 64:
			return "Animation needs 2 to 64 keys."
		var last := -1.0
		for key in keys:
			if not key is Dictionary or not _finite_nonnegative(key.get("time", -1.0)) or not valid_vec(key.get("position")):
				return "Invalid animation key."
			var time := float(key["time"])
			if time <= last or time > 120.0:
				return "Animation key times must increase and stay within 120 seconds."
			last = time
	return ""

static func valid_vec(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for element in value:
		if not (element is int or element is float) or not is_finite(float(element)) or absf(float(element)) > 1000.0:
			return false
	return true

static func safe_id(value: String) -> bool:
	return not value.is_empty() and value.is_valid_filename() and not value.contains("/") and not value.contains("\\") and not value.contains("..")

static func safe_name(value: String) -> bool:
	return not value.is_empty() and value.is_valid_identifier()

static func _optional_id(value: Variant) -> bool:
	return str(value) == "" or safe_id(str(value))

static func _finite_nonnegative(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0

static func _finite_positive(value: Variant) -> bool:
	return _finite_nonnegative(value) and float(value) > 0.0

static func _id() -> String:
	return Store.new_id()
