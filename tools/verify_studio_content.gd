extends SceneTree

const Content = preload("res://studio/content_document.gd")
const Runtime = preload("res://studio/content_runtime.gd")
const Asset = preload("res://studio/shared/asset_document.gd")
const Store = preload("res://studio/shared/document_store.gd")

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# Keep the game audio autoload from starting ambient wind for this test player.
	var sfx := root.get_node_or_null("Sfx")
	if sfx != null:
		sfx.set("_ambient_poll", 999999.0)
	var animation_asset := Asset.create("Lift")
	animation_asset["animations"] = [{"name": "Open", "loop": false, "keys": [{"time": 0.0, "position": [0.0, 0.0, 0.0]}, {"time": 0.25, "position": [0.0, 2.0, 0.0]}]}]
	_check(Content.validate_animations(animation_asset["animations"]) == "", "animation schema")
	var animated := Node3D.new()
	_check(Runtime.decorate_asset(animated, animation_asset) == "", "compile animation")
	var animation_scene := PackedScene.new()
	_check(animation_scene.pack(animated) == OK, "pack animation")
	_check(ResourceSaver.save(animation_scene, "user://studio_animation_test.tscn") == OK, "save animation")
	animated.free()
	var reopened_animation := load("user://studio_animation_test.tscn") as PackedScene
	_check(reopened_animation != null, "reopen animation")
	if reopened_animation != null:
		var instance := reopened_animation.instantiate()
		root.add_child(instance)
		var player := instance.get_node_or_null("AnimationPlayer") as AnimationPlayer
		_check(player != null and player.has_animation("Open"), "reopened timeline")
		if player != null:
			player.play("Open")
			player.seek(0.25, true)
			_check(absf(instance.get_node("AnimatedBody").position.y - 2.0) < 0.01, "lift travel")
			_check(instance.position == Vector3.ZERO, "animation preserves asset root")
			instance.position = Vector3(3.0, 0.5, -2.0)
			player.seek(0.0, true)
			player.seek(0.25, true)
			_check(instance.position == Vector3(3.0, 0.5, -2.0), "offset map placement remains fixed")
			_check(instance.get_node("AnimatedBody").global_position.distance_to(Vector3(3.0, 2.5, -2.0)) < 0.01, "animated body moves relative to placement")
		root.remove_child(instance)
		instance.free()
	var weapon_doc := Content.new_weapon("Test Weapon")
	_check(Content.validate(weapon_doc) == "", "weapon schema")
	var weapon := Runtime.build_weapon(weapon_doc)
	_check(weapon != null, "build weapon")
	if weapon != null:
		var weapon_scene := PackedScene.new()
		_check(weapon_scene.pack(weapon) == OK, "pack weapon")
		_check(ResourceSaver.save(weapon_scene, "user://studio_weapon_test.tscn") == OK, "save weapon")
		weapon.free()
		var reopened_weapon := load("user://studio_weapon_test.tscn") as PackedScene
		_check(reopened_weapon != null, "reopen weapon")
		if reopened_weapon != null:
			var equipped := reopened_weapon.instantiate()
			root.add_child(equipped)
			var target := StaticBody3D.new()
			target.position = Vector3(0, 0, -3)
			var collider := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3.ONE
			collider.shape = box
			target.add_child(collider)
			root.add_child(target)
			var hits: Array = []
			equipped.fired.connect(func(hit: Object) -> void: hits.append(hit))
			await physics_frame
			_check(equipped.has_method("fire") and equipped.call("fire"), "fire saved weapon")
			_check(int(equipped.get("ammunition")) == int(weapon_doc["magazine"]) - 1, "weapon uses ammunition")
			_check(hits.size() == 1 and hits[0] == target, "weapon ray hits target")
			root.remove_child(target)
			target.free()
			root.remove_child(equipped)
			equipped.free()
	var character_doc := Content.new_character("Test Character")
	_check(Content.validate(character_doc) == "", "character schema")
	var character := Runtime.build_character(character_doc, null, load("user://studio_weapon_test.tscn") as PackedScene)
	_check(character != null and character.get_script() != null, "build character adapter")
	if character != null:
		var character_scene := PackedScene.new()
		_check(character_scene.pack(character) == OK, "pack character")
		_check(ResourceSaver.save(character_scene, "user://studio_character_test.tscn") == OK, "save character")
		character.free()
		var reopened_character := load("user://studio_character_test.tscn") as PackedScene
		_check(reopened_character != null, "reopen character")
		if reopened_character != null:
			var spawned := reopened_character.instantiate()
			root.add_child(spawned)
			_check(spawned.get_node_or_null("Body/Hand/Weapon") != null, "weapon attached to hand")
			var player_target := StaticBody3D.new()
			player_target.position = Vector3(0, 0, -4)
			var player_shape := CollisionShape3D.new()
			player_shape.shape = BoxShape3D.new()
			player_target.add_child(player_shape)
			player_target.add_to_group("player")
			root.add_child(player_target)
			await physics_frame
			await physics_frame
			var mounted_weapon := spawned.get_node("Body/Hand/Weapon")
			_check(int(mounted_weapon.get("ammunition")) < int(weapon_doc["magazine"]), "character AI fires authored weapon")
			for frame in 12:
				await physics_frame
			_check(spawned.position.z < -0.05, "character moves toward player")
			_check(float(spawned.get("health")) > 0.0, "weapon excludes its owning character")
			root.remove_child(player_target)
			player_target.free()
			root.remove_child(spawned)
			spawned.free()
	var invalid := animation_asset.duplicate(true)
	invalid["animations"][0]["keys"][1]["time"] = 0.0
	_check(Content.validate_animations(invalid["animations"]) != "", "reject non-increasing timeline")
	for name in ["studio_animation_test.tscn", "studio_weapon_test.tscn", "studio_character_test.tscn"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + name))
	_check(Node.get_orphan_node_ids().is_empty(), "no orphaned content nodes")
	print("Studio content checks: %d failure(s)" % failures)
	call_deferred("_finish")

func _finish() -> void:
	quit(0 if failures == 0 else 1)

func _check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error(label)
