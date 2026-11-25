extends SceneTree

const Store = preload("res://shared/document_store.gd")
const Mesher = preload("res://shared/voxel_mesh.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var voxels := []
	for x in 32:
		for y in 32:
			for z in 32:
				voxels.append({"x": x, "y": y, "z": z, "material": 0})
	var asset := {"voxels": voxels, "palette": ["#ffffff"], "pitch": 0.125, "origin": [0, 0, 0]}
	var start := Time.get_ticks_usec()
	var chunks: Dictionary = Mesher.build_chunks(asset)
	var mesh_ms := float(Time.get_ticks_usec() - start) / 1000.0
	if chunks.size() != 8:
		push_error("Expected eight 16-voxel chunks")
		quit(1)
		return
	var map := Store.new_map("Performance fixture")
	for index in 500:
		map["instances"].append(Store.new_instance("Block", Vector3(index % 25, 0, index / 25)))
	var editor: Control = load("res://main.tscn").instantiate()
	root.add_child(editor)
	editor.map_doc = map
	start = Time.get_ticks_usec()
	editor._refresh()
	var refresh_ms := float(Time.get_ticks_usec() - start) / 1000.0
	print("PERF 32768 solid voxels -> %d chunks in %.1f ms; 500 block map refresh in %.1f ms" % [chunks.size(), mesh_ms, refresh_ms])
	quit(0)
