extends RefCounted

static func _content() -> GDScript:
	return load("res://studio/content_document.gd") if ResourceLoader.exists("res://studio/content_document.gd") else load("res://content_document.gd")

static func _motion() -> GDScript:
	return load("res://studio/character_motion.gd") if ResourceLoader.exists("res://studio/character_motion.gd") else load("res://character_motion.gd")

static func decorate_asset(node: Node3D, doc: Dictionary) -> String:
	var animations: Variant = doc.get("animations", [])
	var problem: String = _content().validate_animations(animations)
	if problem != "":
		return problem
	if animations.is_empty():
		return ""
	# Keep the placed asset root at its authored map transform. Move only its
	# generated visual, collision, and attachments inside a local animation pivot.
	var animated_body := Node3D.new()
	animated_body.name = "AnimatedBody"
	var generated_children := node.get_children()
	node.add_child(animated_body)
	animated_body.owner = node.owner if node.owner != null else node
	for child in generated_children:
		_clear_owner_tree(child)
		child.reparent(animated_body, false)
		_own_generated_tree(child, node.owner if node.owner != null else node)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	player.root_node = NodePath("..")
	var library := AnimationLibrary.new()
	for entry in animations:
		var animation := Animation.new()
		var keys: Array = entry["keys"]
		animation.length = maxf(0.001, float(keys[-1]["time"]))
		animation.loop_mode = Animation.LOOP_LINEAR if bool(entry.get("loop", false)) else Animation.LOOP_NONE
		var track := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(track, NodePath("AnimatedBody:position"))
		animation.value_track_set_update_mode(track, Animation.UPDATE_CONTINUOUS)
		for key in keys:
			var position: Array = key["position"]
			animation.track_insert_key(track, float(key["time"]), Vector3(float(position[0]), float(position[1]), float(position[2])))
		var err := library.add_animation(str(entry["name"]), animation)
		if err != OK:
			return "Cannot register animation."
	player.add_animation_library("", library)
	node.add_child(player)
	player.owner = node.owner if node.owner != null else node
	return ""

static func build_character(doc: Dictionary, visual: PackedScene = null, weapon: PackedScene = null) -> Node3D:
	if _content().validate(doc) != "" or doc["kind"] != "character":
		return null
	var root := CharacterBody3D.new()
	root.name = "Character"
	root.set_script(load("res://scripts/studio/studio_character.gd"))
	root.set("max_health", float(doc["health"]))
	root.set("auto_fire", bool(doc.get("auto_fire", true)))
	root.set("sight_range", float(doc.get("sight_range", 25.0)))
	root.set("move_speed", float(doc.get("move_speed", 2.5)))
	var navigation := NavigationAgent3D.new()
	navigation.name = "NavigationAgent3D"
	navigation.path_desired_distance = 0.4
	navigation.target_desired_distance = 1.4
	root.add_child(navigation)
	navigation.owner = root
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	collision.shape = capsule
	collision.position.y = 0.9
	root.add_child(collision)
	collision.owner = root
	root.add_to_group("studio_character", true)
	root.set_meta("studio_health", float(doc["health"]))
	var part_nodes := {}
	for part in doc["parts"]:
		var joint := Node3D.new()
		joint.name = str(part["name"])
		var pos: Array = part["position"]
		joint.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		part_nodes[part["name"]] = joint
	for part in doc["parts"]:
		var joint: Node3D = part_nodes[part["name"]]
		var parent: Node3D = part_nodes.get(str(part.get("parent", "")), root)
		parent.add_child(joint)
		joint.owner = root
		var visual_part := MeshInstance3D.new()
		visual_part.name = "Visual"
		var mesh := BoxMesh.new()
		var size: Array = part["size"]
		mesh.size = Vector3(float(size[0]), float(size[1]), float(size[2]))
		visual_part.mesh = mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(str(part["color"]))
		visual_part.material_override = material
		joint.add_child(visual_part)
		visual_part.owner = root
	# Procedural walk cycle + patrol/chase AI. The motion component collects
	# the rig joints built above when the character enters the tree.
	var motion_script := _motion()
	if motion_script != null:
		var motion := Node.new()
		motion.name = "CharacterMotion"
		motion.set_script(motion_script)
		motion.set("move_speed", float(doc.get("move_speed", 2.5)))
		motion.set("sight_range", float(doc.get("sight_range", 25.0)))
		motion.set("stride_length", float(doc.get("stride_length", 0.7)))
		motion.set("swing_degrees", float(doc.get("swing_degrees", 28.0)))
		var roles := {}
		for part in doc["parts"]:
			if str(part.get("limb", "")) != "":
				roles[str(part["name"])] = str(part["limb"])
		motion.set("limb_roles", roles)
		root.add_child(motion)
		motion.owner = root
	if visual != null:
		var instance := visual.instantiate()
		instance.name = "VoxelVisual"
		root.add_child(instance)
		_set_owner_recursive(instance, root)
	if weapon != null:
		var instance := weapon.instantiate()
		instance.name = "Weapon"
		var hand: Node3D = part_nodes.get("Hand", root)
		hand.add_child(instance)
		_set_owner_recursive(instance, root)
	return root

static func build_weapon(doc: Dictionary, visual: PackedScene = null) -> Node3D:
	if _content().validate(doc) != "" or doc["kind"] != "weapon":
		return null
	var root := Node3D.new()
	root.name = "Weapon"
	root.set_script(load("res://scripts/studio/studio_weapon.gd"))
	root.set("damage", float(doc["damage"]))
	root.set("max_range", float(doc["range"]))
	root.set("cooldown", float(doc["cooldown"]))
	root.set("magazine_size", int(doc["magazine"]))
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	var position: Array = doc["muzzle"]
	muzzle.position = Vector3(float(position[0]), float(position[1]), float(position[2]))
	root.add_child(muzzle)
	muzzle.owner = root
	if visual != null:
		var instance := visual.instantiate()
		instance.name = "VoxelVisual"
		root.add_child(instance)
		_set_owner_recursive(instance, root)
	return root

static func build_character_spawn(item: Dictionary, catalog: Dictionary) -> Node3D:
	var id := str(item.get("character_id", ""))
	if not _content().safe_id(id) or not catalog.get("characters", {}).has(id):
		return null
	var path := str(catalog["characters"][id].get("scene", ""))
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var marker := Marker3D.new()
	marker.add_to_group("character_spawn", true)
	marker.set_meta("character_id", id)
	var character := scene.instantiate()
	character.name = "Character"
	marker.add_child(character)
	character.owner = marker
	return marker

static func _set_owner_recursive(node: Node, root: Node) -> void:
	# Packed subscenes already own their descendants. Owning those descendants
	# again duplicates them in the containing scene and can orphan nodes on load.
	node.owner = root

static func _own_generated_tree(node: Node, root: Node) -> void:
	node.owner = root
	for child in node.get_children():
		_own_generated_tree(child, root)

static func _clear_owner_tree(node: Node) -> void:
	for child in node.get_children():
		_clear_owner_tree(child)
	node.owner = null
