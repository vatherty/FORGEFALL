extends SceneTree
const Asset = preload("res://shared/asset_document.gd")
const Mesher = preload("res://shared/voxel_mesh.gd")
func _initialize() -> void:
	var doc: Dictionary = Asset.create("Two voxels")
	doc = Asset.set_voxel(doc, 0, 0, 0, 0)
	doc = Asset.set_voxel(doc, 1, 0, 0, 1)
	assert(Asset.validate(doc) == "")
	var chunks: Dictionary = Mesher.build_chunks(doc)
	assert(chunks.size() == 1)
	var mesh: ArrayMesh = chunks.values()[0]
	assert(mesh.surface_get_array_index_len(0) == 60)
	var node: Node3D = Mesher.build_node(doc, true)
	assert(node.get_child_count() == 2)
	node.free()
	doc = Asset.erase_voxel(doc, 1, 0, 0)
	assert(doc["voxels"].size() == 1)
	print("Voxel test passed: schema, exposed faces, chunk collision, erase")
	quit()
