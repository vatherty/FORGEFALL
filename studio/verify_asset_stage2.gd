extends SceneTree
const Asset = preload("res://shared/asset_document.gd")
const Mesher = preload("res://shared/voxel_mesh.gd")
const Store = preload("res://shared/document_store.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# --- Continuous deformation brush: smoothstep falloff over many cells ---
	var doc: Dictionary = Asset.create("Brush")
	for x in range(5):
		doc = Asset.set_voxel(doc, x, 0, 0, 0, 0)
	doc["layers"].append({"name": "Cap", "visible": true, "collision": true})
	doc = Asset.set_voxel(doc, 2, 0, 1, 0, 1) # Other layer inside the radius: must not move.
	var brushed: Dictionary = Asset.deform_brush(doc, Vector3i(2, 0, 0), 2, Vector3i.UP, 3.0, 0)
	assert(Asset.validate(brushed) == "")
	assert(Asset.find_index(brushed, 2, 3, 0) >= 0) # Center: falloff 1 -> +3 cells.
	assert(Asset.find_index(brushed, 1, 2, 0) >= 0) # Distance 1: falloff 0.5 -> round(1.5) = +2.
	assert(Asset.find_index(brushed, 3, 2, 0) >= 0)
	assert(Asset.find_index(brushed, 0, 0, 0) >= 0) # Edge: falloff 0 -> stays.
	assert(Asset.find_index(brushed, 4, 0, 0) >= 0)
	assert(Asset.find_index(brushed, 2, 0, 1) >= 0) # Other layer untouched.
	assert(Asset.find_index(doc, 2, 0, 0) >= 0) # Source document untouched.
	# All-or-nothing: a stationary voxel on another layer blocks the center target.
	var blocked: Dictionary = Asset.set_voxel(doc, 2, 3, 0, 0, 1)
	assert(Asset.same(Asset.deform_brush(blocked, Vector3i(2, 0, 0), 2, Vector3i.UP, 3.0, 0), blocked))
	assert(Asset.same(Asset.deform_brush(doc, Vector3i(2, 0, 0), 2, Vector3i.UP, 0.0, 0), doc))
	assert(Asset.same(Asset.deform_brush(doc, Vector3i(2, 0, 0), 2, Vector3i.ZERO, 3.0, 0), doc))

	# --- A brush stroke through the workshop undoes as ONE history step ---
	var workshop: Control = load("res://asset_workshop.tscn").instantiate()
	workshop.project_path = ProjectSettings.globalize_path("user://stage2_fixture_" + str(Time.get_ticks_usec()))
	root.add_child(workshop)
	for x in range(1, 5):
		workshop.asset_doc = Asset.set_voxel(workshop.asset_doc, x, 0, 0, 0, 0)
	workshop._set_tool("Deform Brush")
	workshop.brush_radius = 2
	workshop.brush_strength = 3.0
	workshop.deform_offset = Vector3i.UP
	workshop.stroke_cells.append(Vector3i(2, 0, 0))
	workshop._finish_stroke()
	assert(Asset.find_index(workshop.asset_doc, 2, 3, 0) >= 0)
	assert(Asset.find_index(workshop.asset_doc, 1, 2, 0) >= 0)
	workshop._undo()
	assert(Asset.find_index(workshop.asset_doc, 2, 0, 0) >= 0)
	assert(Asset.find_index(workshop.asset_doc, 2, 3, 0) < 0)
	assert(Asset.find_index(workshop.asset_doc, 1, 0, 0) >= 0)

	# --- Workshop collision-box controls switch the asset to custom mode ---
	workshop.box_min_inputs[0].value = 0.0
	workshop.box_min_inputs[1].value = 0.0
	workshop.box_min_inputs[2].value = 0.0
	workshop.box_size_inputs[0].value = 0.5
	workshop.box_size_inputs[1].value = 0.25
	workshop.box_size_inputs[2].value = 0.5
	workshop._add_collision_box()
	assert(workshop.asset_doc["collision"] == "custom")
	assert(workshop.asset_doc["collision_boxes"].size() == 1)
	workshop._delete_collision_box() # Refused: custom mode needs at least one box.
	assert(workshop.asset_doc["collision_boxes"].size() == 1)
	assert(workshop.status.text == "Custom collision needs at least one box.")

	# --- Custom collision boxes: validation ---
	var boxed: Dictionary = Asset.create("Boxed")
	boxed = Asset.set_voxel(boxed, 0, 0, 0, 0)
	boxed = Asset.set_voxel(boxed, 8, 0, 0, 0)
	boxed["collision"] = "custom"
	assert(Asset.validate(boxed) == "Custom collision needs at least one box.")
	boxed = Asset.add_collision_box(boxed, Vector3(0, 0, 0), Vector3(0.25, 0.125, 0.125))
	boxed = Asset.add_collision_box(boxed, Vector3(0.875, 0, 0), Vector3(0.375, 0.25, 0.5))
	assert(Asset.validate(boxed) == "")
	assert(Asset.validate(Asset.set_collision_box(boxed, 0, Vector3.ZERO, Vector3(0, 1, 1))) != "") # Zero size.
	assert(Asset.validate(Asset.set_collision_box(boxed, 0, Vector3(NAN, 0, 0), Vector3.ONE)) != "") # Non-finite min.
	assert(Asset.validate(Asset.set_collision_box(boxed, 0, Vector3.ZERO, Vector3(64, 1, 1))) != "") # Oversize.
	assert(Asset.same(Asset.set_collision_box(boxed, 5, Vector3.ZERO, Vector3.ONE), boxed)) # Bad index: no-op.
	boxed = Asset.set_collision_box(boxed, 1, Vector3(1.0, 0, 0), Vector3(0.25, 0.25, 0.25))
	assert(is_equal_approx(float(boxed["collision_boxes"][1]["min"][0]), 1.0))

	# --- Boxes survive a save/reload round trip ---
	var dir := ProjectSettings.globalize_path("user://stage2_boxes_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(dir)
	var json_path := dir.path_join("boxed.json")
	assert(Store.write_json(json_path, boxed) == OK)
	var reloaded: Dictionary = Store.read_json(json_path)
	assert(Asset.validate(reloaded) == "")
	assert(reloaded["collision"] == "custom")
	assert(reloaded["collision_boxes"].size() == 2)
	# Field-level comparison: Asset.same() cannot be used here because JSON
	# parsing turns the integer "version" into 1.0 (a pre-existing quirk).
	for i in 2:
		for field in ["min", "size"]:
			for axis in 3:
				assert(is_equal_approx(float(reloaded["collision_boxes"][i][field][axis]), float(boxed["collision_boxes"][i][field][axis])))

	# --- Built/published collision matches the boxes, not the voxel shape ---
	var node: Node3D = Mesher.build_node(boxed, true)
	assert(node.get_node_or_null("Collision_0_0_0") == null) # No per-chunk trimesh body.
	var body := node.get_node_or_null("CollisionCustom") as StaticBody3D
	assert(body != null)
	assert(body.get_child_count() == 2)
	var first := body.get_child(0) as CollisionShape3D
	var second := body.get_child(1) as CollisionShape3D
	assert(first.shape is BoxShape3D)
	assert((first.shape as BoxShape3D).size == Vector3(0.25, 0.125, 0.125))
	assert(first.position == Vector3(0.125, 0.0625, 0.0625)) # min + size/2 - origin.
	assert((second.shape as BoxShape3D).size == Vector3(0.25, 0.25, 0.25))
	assert(second.position == Vector3(1.125, 0.125, 0.125))
	# Pack and reload exactly like tools/studio_generate.gd publishes an asset.
	var packed := PackedScene.new()
	assert(packed.pack(node) == OK)
	var scene_path := dir.path_join("boxed.tscn")
	assert(ResourceSaver.save(packed, scene_path) == OK)
	node.free()
	var loaded: Node3D = (load(scene_path) as PackedScene).instantiate()
	var loaded_body := loaded.get_node_or_null("CollisionCustom") as StaticBody3D
	assert(loaded_body != null and loaded_body.get_child_count() == 2)
	assert(((loaded_body.get_child(0) as CollisionShape3D).shape as BoxShape3D).size == Vector3(0.25, 0.125, 0.125))
	assert((loaded_body.get_child(1) as CollisionShape3D).position == Vector3(1.125, 0.125, 0.125))
	loaded.free()
	boxed = Asset.remove_collision_box(boxed, 0)
	assert(boxed["collision_boxes"].size() == 1)
	print("Stage 2 completion test passed: deform brush falloff, single-step stroke undo, collision box validation, save/reload, published collision matches boxes")
	quit()
