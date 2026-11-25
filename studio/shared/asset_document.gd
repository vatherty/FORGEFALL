extends RefCounted

const Store = preload("document_store.gd")

const VERSION := 1
const PITCH := 0.125
const MAX_COORD := 256
const MAX_VOXELS := 100000
const MAX_COLLISION_BOXES := 32

static func create(name: String) -> Dictionary:
	return {"version": VERSION, "kind": "asset", "id": _id(), "name": name, "pitch": PITCH, "origin": [0.0, 0.0, 0.0], "palette": ["#d39456", "#687d90", "#d9d4c7"], "voxels": [], "layers": [{"name": "Base", "visible": true, "collision": true}], "parts": [], "attachments": [], "references": [], "animations": [], "collision": "static", "collision_boxes": []}

static func validate(doc: Dictionary) -> String:
	if doc.get("version") != VERSION or doc.get("kind") != "asset":
		return "Unsupported asset version or kind."
	if str(doc.get("id", "")).is_empty():
		return "Asset has no ID."
	if not is_equal_approx(float(doc.get("pitch", 0.0)), PITCH):
		return "Unsupported voxel pitch."
	if not doc.get("palette") is Array or doc["palette"].is_empty():
		return "Asset palette is empty."
	if not _valid_position(doc.get("origin", [])):
		return "Invalid pivot."
	var layers: Array = doc.get("layers", [{"name": "Base", "visible": true, "collision": true}])
	if layers.is_empty() or layers.size() > 32:
		return "Invalid layers."
	for layer in layers:
		if not layer is Dictionary or str(layer.get("name", "")).strip_edges().is_empty() or not layer.get("visible", true) is bool or not layer.get("collision", true) is bool:
			return "Invalid layer."
	if not str(doc.get("collision", "static")) in ["static", "none", "custom"]:
		return "Invalid collision mode."
	var box_problem := _validate_collision_boxes(doc)
	if box_problem != "":
		return box_problem
	if not doc.get("attachments", []) is Array or doc.get("attachments", []).size() > 64:
		return "Invalid attachments."
	var attachment_names := {}
	for attachment in doc.get("attachments", []):
		if not attachment is Dictionary or str(attachment.get("name", "")).strip_edges().is_empty() or not _valid_position(attachment.get("position", [])):
			return "Invalid attachment."
		var name := str(attachment["name"]).validate_node_name()
		if name.is_empty() or attachment_names.has(name):
			return "Duplicate or invalid attachment name."
		attachment_names[name] = true
	if not doc.get("references", []) is Array:
		return "Invalid references."
	for reference in doc.get("references", []):
		if not reference is Dictionary:
			return "Invalid reference."
		var reference_path := str(reference.get("path", ""))
		if not reference_path.begins_with("res://assets/studio/references/") or reference_path.get_file().is_empty() or reference_path.contains(".."):
			return "Invalid reference."
	if not doc.get("voxels") is Array or doc["voxels"].size() > MAX_VOXELS:
		return "Invalid voxel count."
	var seen := {}
	for voxel in doc["voxels"]:
		if not voxel is Dictionary:
			return "Invalid voxel entry."
		for axis in ["x", "y", "z"]:
			if not _integer(voxel.get(axis)) or absi(int(voxel[axis])) > MAX_COORD:
				return "Voxel coordinate out of range."
		if not _integer(voxel.get("material")) or int(voxel["material"]) < 0 or int(voxel["material"]) >= doc["palette"].size():
			return "Voxel palette reference is invalid."
		if not _integer(voxel.get("layer", 0)) or int(voxel.get("layer", 0)) < 0 or int(voxel.get("layer", 0)) >= layers.size():
			return "Voxel layer reference is invalid."
		var key := key_for(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))
		if seen.has(key):
			return "Duplicate voxel coordinate."
		seen[key] = true
	return ""

static func _valid_box_extent(value: Variant, positive: bool) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for axis in value:
		if not (axis is int or axis is float) or not is_finite(float(axis)) or absf(float(axis)) > MAX_COORD * PITCH:
			return false
		if positive and float(axis) <= 0.0:
			return false
	return true

static func _validate_collision_boxes(doc: Dictionary) -> String:
	var boxes: Variant = doc.get("collision_boxes", [])
	if not boxes is Array or boxes.size() > MAX_COLLISION_BOXES:
		return "Invalid collision boxes."
	for box in boxes:
		if not box is Dictionary or not _valid_box_extent(box.get("min", []), false) or not _valid_box_extent(box.get("size", []), true):
			return "Invalid collision box."
	if str(doc.get("collision", "static")) == "custom" and boxes.is_empty():
		return "Custom collision needs at least one box."
	return ""

static func add_collision_box(doc: Dictionary, min_corner: Vector3, size: Vector3) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	if not next_doc.has("collision_boxes"):
		next_doc["collision_boxes"] = []
	if next_doc["collision_boxes"].size() >= MAX_COLLISION_BOXES:
		return next_doc
	next_doc["collision_boxes"].append({"min": [min_corner.x, min_corner.y, min_corner.z], "size": [size.x, size.y, size.z]})
	return next_doc

static func remove_collision_box(doc: Dictionary, index: int) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	if not next_doc.has("collision_boxes") or index < 0 or index >= next_doc["collision_boxes"].size():
		return next_doc
	next_doc["collision_boxes"].remove_at(index)
	return next_doc

static func set_collision_box(doc: Dictionary, index: int, min_corner: Vector3, size: Vector3) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	if not next_doc.has("collision_boxes") or index < 0 or index >= next_doc["collision_boxes"].size():
		return next_doc
	next_doc["collision_boxes"][index] = {"min": [min_corner.x, min_corner.y, min_corner.z], "size": [size.x, size.y, size.z]}
	return next_doc

static func _valid_position(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for axis in value:
		if not (axis is int or axis is float) or not is_finite(float(axis)) or absf(float(axis)) > MAX_COORD * PITCH:
			return false
	return true

static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and is_equal_approx(float(value), roundf(float(value)))

static func same(left: Dictionary, right: Dictionary) -> bool:
	return JSON.stringify(_canonical(left)) == JSON.stringify(_canonical(right))

static func _canonical(doc: Dictionary) -> Dictionary:
	var result: Dictionary = doc.duplicate(true)
	if result.get("origin") is Array:
		for i in result["origin"].size():
			result["origin"][i] = float(result["origin"][i])
	if result.get("voxels") is Array:
		for voxel in result["voxels"]:
			for axis in ["x", "y", "z", "material", "layer"]:
				if voxel.has(axis) and _integer(voxel[axis]):
					voxel[axis] = int(voxel[axis])
	return result

static func key_for(x: int, y: int, z: int) -> String:
	return "%d:%d:%d" % [x, y, z]

static func find_index(doc: Dictionary, x: int, y: int, z: int) -> int:
	var wanted := key_for(x, y, z)
	for i in doc["voxels"].size():
		var voxel: Dictionary = doc["voxels"][i]
		if key_for(int(voxel["x"]), int(voxel["y"]), int(voxel["z"])) == wanted:
			return i
	return -1

static func set_voxel(doc: Dictionary, x: int, y: int, z: int, material: int, layer: int = 0) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	var index := find_index(next_doc, x, y, z)
	if index == -1:
		next_doc["voxels"].append({"x": x, "y": y, "z": z, "material": material, "layer": layer})
	else:
		next_doc["voxels"][index]["material"] = material
		next_doc["voxels"][index]["layer"] = layer
	return next_doc

static func erase_voxel(doc: Dictionary, x: int, y: int, z: int) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	var index := find_index(next_doc, x, y, z)
	if index >= 0:
		next_doc["voxels"].remove_at(index)
	return next_doc

static func stamp(doc: Dictionary, center: Vector3i, shape: String, radius: int, material: int, layer: int = 0, erase: bool = false, symmetry: Vector3i = Vector3i.ZERO) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	var by_key := {}
	var order := []
	for voxel in next_doc["voxels"]:
		var key := key_for(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))
		by_key[key] = voxel
		order.append(key)
	radius = clampi(radius, 0, 8)
	for x in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			for z in range(-radius, radius + 1):
				var included := shape == "Box" or shape == "Sphere" and x*x + y*y + z*z <= radius*radius or shape == "Cylinder" and x*x + z*z <= radius*radius
				if not included:
					continue
				for point in _mirrors(center + Vector3i(x, y, z), symmetry):
					if absi(point.x) > MAX_COORD or absi(point.y) > MAX_COORD or absi(point.z) > MAX_COORD:
						continue
					var key := key_for(point.x, point.y, point.z)
					if erase:
						by_key.erase(key)
					elif by_key.has(key):
						by_key[key]["material"] = material
						by_key[key]["layer"] = layer
					elif by_key.size() < MAX_VOXELS:
						by_key[key] = {"x": point.x, "y": point.y, "z": point.z, "material": material, "layer": layer}
						order.append(key)
	var voxels := []
	for key in order:
		if by_key.has(key):
			voxels.append(by_key[key])
	next_doc["voxels"] = voxels
	return next_doc

static func _mirrors(point: Vector3i, axes: Vector3i) -> Array[Vector3i]:
	var points: Array[Vector3i] = [point]
	for axis in 3:
		if axes[axis] == 0:
			continue
		var existing := points.duplicate()
		for source in existing:
			var reflected: Vector3i = source
			reflected[axis] = -source[axis]
			if not points.has(reflected):
				points.append(reflected)
	return points

static func rename_layer(doc: Dictionary, index: int, name: String) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	if not next_doc.has("layers"):
		next_doc["layers"] = [{"name": "Base", "visible": true, "collision": true}]
	if index < 0 or index >= next_doc["layers"].size() or name.strip_edges().is_empty():
		return next_doc
	next_doc["layers"][index]["name"] = name.strip_edges()
	return next_doc

static func move_layer(doc: Dictionary, index: int, direction: int) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	if not next_doc.has("layers"):
		next_doc["layers"] = [{"name": "Base", "visible": true, "collision": true}]
	var target := index + direction
	if index < 0 or target < 0 or target >= next_doc["layers"].size():
		return next_doc
	var old: Dictionary = next_doc["layers"][index]
	next_doc["layers"][index] = next_doc["layers"][target]
	next_doc["layers"][target] = old
	for voxel in next_doc["voxels"]:
		if int(voxel.get("layer", 0)) == index:
			voxel["layer"] = target
		elif int(voxel.get("layer", 0)) == target:
			voxel["layer"] = index
	return next_doc

static func merge_layer_down(doc: Dictionary, index: int) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	if not next_doc.has("layers"):
		next_doc["layers"] = [{"name": "Base", "visible": true, "collision": true}]
	if index <= 0 or index >= next_doc["layers"].size():
		return next_doc
	next_doc["layers"].remove_at(index)
	for voxel in next_doc["voxels"]:
		var old_layer := int(voxel.get("layer", 0))
		if old_layer == index:
			voxel["layer"] = index - 1
		elif old_layer > index:
			voxel["layer"] = old_layer - 1
	return next_doc

static func smooth(doc: Dictionary, center: Vector3i, radius: int, material: int, layer: int) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	var occupied := {}
	for voxel in doc["voxels"]:
		occupied[Vector3i(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))] = voxel
	var remove := {}
	var add := []
	for x in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			for z in range(-radius, radius + 1):
				if x*x + y*y + z*z > radius*radius:
					continue
				var point := center + Vector3i(x, y, z)
				if absi(point.x) > MAX_COORD or absi(point.y) > MAX_COORD or absi(point.z) > MAX_COORD:
					continue
				var neighbors := 0
				for offset in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]:
					if occupied.has(point + offset):
						neighbors += 1
				if occupied.has(point):
					if int(occupied[point].get("layer", 0)) == layer and neighbors <= 1:
						remove[point] = true
				elif neighbors >= 5:
					add.append(point)
	var voxels := []
	for voxel in next_doc["voxels"]:
		if not remove.has(Vector3i(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))):
			voxels.append(voxel)
	for point in add:
		if voxels.size() >= MAX_VOXELS:
			break
		voxels.append({"x": point.x, "y": point.y, "z": point.z, "material": material, "layer": layer})
	next_doc["voxels"] = voxels
	return next_doc

static func deform(doc: Dictionary, center: Vector3i, radius: int, offset: Vector3i, layer: int) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	var moving := {}
	var stationary := {}
	for voxel in doc["voxels"]:
		var point := Vector3i(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))
		if int(voxel.get("layer", 0)) == layer and (point - center).length_squared() <= radius * radius:
			moving[point] = true
		else:
			stationary[point] = true
	for point in moving:
		var target: Vector3i = point + offset
		if absi(target.x) > MAX_COORD or absi(target.y) > MAX_COORD or absi(target.z) > MAX_COORD or stationary.has(target):
			return next_doc
	for voxel in next_doc["voxels"]:
		var point := Vector3i(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))
		if moving.has(point):
			var target := point + offset
			voxel["x"] = target.x
			voxel["y"] = target.y
			voxel["z"] = target.z
	return next_doc

## Continuous deformation brush: voxels of one layer inside the radius move
## along `direction` by round(strength * smoothstep falloff) whole cells, so a
## drag raises a smooth bump instead of the one-cell step of deform(). Like
## deform(), the stroke is all-or-nothing: any target out of bounds, occupied
## by a voxel that stays put, or claimed by two moving voxels aborts it.
static func deform_brush(doc: Dictionary, center: Vector3i, radius: int, direction: Vector3i, strength: float, layer: int) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	radius = clampi(radius, 0, 16)
	if direction == Vector3i.ZERO or strength <= 0.0:
		return next_doc
	var unit := Vector3i(clampi(direction.x, -1, 1), clampi(direction.y, -1, 1), clampi(direction.z, -1, 1))
	var steps_by_point := {}
	var stationary := {}
	for voxel in doc["voxels"]:
		var point := Vector3i(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))
		var distance_squared: int = (point - center).length_squared()
		if int(voxel.get("layer", 0)) != layer or distance_squared > radius * radius:
			stationary[point] = true
			continue
		var falloff := 1.0
		if radius > 0:
			var t := clampf(sqrt(float(distance_squared)) / float(radius), 0.0, 1.0)
			falloff = 1.0 - t * t * (3.0 - 2.0 * t)
		var steps := int(round(strength * falloff))
		if steps <= 0:
			stationary[point] = true
		else:
			steps_by_point[point] = steps
	if steps_by_point.is_empty():
		return next_doc
	var targets := {}
	for point in steps_by_point:
		var target: Vector3i = point + unit * steps_by_point[point]
		if absi(target.x) > MAX_COORD or absi(target.y) > MAX_COORD or absi(target.z) > MAX_COORD or stationary.has(target) or targets.has(target):
			return next_doc
		targets[target] = true
	for voxel in next_doc["voxels"]:
		var point := Vector3i(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))
		if steps_by_point.has(point):
			var target: Vector3i = point + unit * steps_by_point[point]
			voxel["x"] = target.x
			voxel["y"] = target.y
			voxel["z"] = target.z
	return next_doc

static func flood_fill(doc: Dictionary, start: Vector3i, material: int) -> Dictionary:
	var next_doc: Dictionary = doc.duplicate(true)
	var first := find_index(next_doc, start.x, start.y, start.z)
	if first < 0:
		return next_doc
	var source_material: int = next_doc["voxels"][first]["material"]
	if source_material == material:
		return next_doc
	var by_key := {}
	for i in next_doc["voxels"].size():
		var voxel: Dictionary = next_doc["voxels"][i]
		by_key[key_for(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))] = i
	var queue: Array[Vector3i] = [start]
	var visited := {}
	var cursor := 0
	while cursor < queue.size():
		var point := queue[cursor]
		cursor += 1
		var key := key_for(point.x, point.y, point.z)
		if visited.has(key) or not by_key.has(key):
			continue
		visited[key] = true
		var voxel: Dictionary = next_doc["voxels"][by_key[key]]
		if int(voxel["material"]) != source_material:
			continue
		voxel["material"] = material
		for offset in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]:
			queue.append(point + offset)
	return next_doc

static func path(project: String, id: String) -> String:
	return project.path_join("assets/studio/assets").path_join(id + ".json")

static func _id() -> String:
	return Store.new_id()
