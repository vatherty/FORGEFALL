extends RefCounted

# One exposed-face mesh per 16-voxel chunk. No body or draw call per voxel.
const CHUNK := 16
const FACE_DIRECTIONS := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const FACE_CORNERS := [
	[Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
	[Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)],
	[Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0), Vector3(0, 1, 0)],
	[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)],
	[Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)],
	[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)]
]

static func build_chunks(doc: Dictionary) -> Dictionary:
	var filled := {}
	var chunks := {}
	for voxel in doc["voxels"]:
		filled[Vector3i(int(voxel["x"]), int(voxel["y"]), int(voxel["z"]))] = true
		var chunk := Vector3i(floori(float(voxel["x"]) / CHUNK), floori(float(voxel["y"]) / CHUNK), floori(float(voxel["z"]) / CHUNK))
		if not chunks.has(chunk):
			chunks[chunk] = []
		chunks[chunk].append(voxel)
	var output := {}
	for chunk in chunks:
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var colors := PackedColorArray()
		var indices := PackedInt32Array()
		for voxel in chunks[chunk]:
			var x: int = voxel["x"]
			var y: int = voxel["y"]
			var z: int = voxel["z"]
			var color := Color(str(doc["palette"][int(voxel["material"])]))
			for face in 6:
				var direction: Vector3i = FACE_DIRECTIONS[face]
				if filled.has(Vector3i(x + direction.x, y + direction.y, z + direction.z)):
					continue
				var first := vertices.size()
				for corner in FACE_CORNERS[face]:
					vertices.append((Vector3(x, y, z) + corner) * float(doc["pitch"]) - Vector3(float(doc["origin"][0]), float(doc["origin"][1]), float(doc["origin"][2])))
					normals.append(Vector3(direction))
					colors.append(color)
				indices.append_array(PackedInt32Array([first, first + 1, first + 2, first, first + 2, first + 3]))
		if vertices.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh.surface_set_material(0, material)
		output[chunk] = mesh
	return output

static func build_node(doc: Dictionary, with_collision: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "VoxelAsset"
	var chunks: Dictionary = build_chunks(doc)
	for chunk in chunks:
		var visual := MeshInstance3D.new()
		visual.name = "Chunk_%d_%d_%d" % [chunk.x, chunk.y, chunk.z]
		visual.mesh = chunks[chunk]
		root.add_child(visual)
		visual.owner = root
	if with_collision and str(doc.get("collision", "static")) == "static":
		var collision_doc: Dictionary = doc.duplicate(true)
		var collidable := []
		var layers: Array = doc.get("layers", [{"collision": true}])
		for voxel in doc["voxels"]:
			if layers[int(voxel.get("layer", 0))].get("collision", true):
				collidable.append(voxel)
		collision_doc["voxels"] = collidable
		var collision_chunks: Dictionary = build_chunks(collision_doc)
		for chunk in collision_chunks:
			var body := StaticBody3D.new()
			body.name = "Collision_%d_%d_%d" % [chunk.x, chunk.y, chunk.z]
			root.add_child(body)
			body.owner = root
			var shape := CollisionShape3D.new()
			shape.shape = collision_chunks[chunk].create_trimesh_shape()
			body.add_child(shape)
			shape.owner = root
	for attachment in doc.get("attachments", []):
		var marker := Marker3D.new()
		marker.name = str(attachment["name"]).validate_node_name()
		var position: Array = attachment["position"]
		var pivot: Array = doc["origin"]
		marker.position = Vector3(float(position[0]) - float(pivot[0]), float(position[1]) - float(pivot[1]), float(position[2]) - float(pivot[2]))
		root.add_child(marker)
		marker.owner = root
	return root
