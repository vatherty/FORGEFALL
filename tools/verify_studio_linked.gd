extends SceneTree
const Catalog = preload("res://scripts/studio/studio_catalog.gd")
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		quit(1)
		return
	var map: Node3D = Catalog.load_map(args[0])
	if map == null or map.get_child_count() != 1:
		quit(2)
		return
	var asset: Node3D = map.get_child(0)
	var visual: MeshInstance3D = asset.get_node_or_null("Chunk_0_0_0")
	if visual == null or visual.mesh.surface_get_array_index_len(0) != int(args[1]):
		quit(3)
		return
	map.free()
	print("Linked asset refreshed without republishing map")
	quit()
