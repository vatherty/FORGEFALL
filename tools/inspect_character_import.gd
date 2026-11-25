extends SceneTree
var _frames := 0
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	for id in ["grunt", "brute"]:
		var scene := load("res://assets/models/characters/%s.glb" % id) as PackedScene
		var root := scene.instantiate()
		print(id, " root ", root.name)
		for name in ["BodyRoot", "HipL", "HipR", "ShoulderL", "ShoulderR", "Head"]:
			var part := root.find_child(name, true, false) as Node3D
			print(name, " ", part.get_path() if part != null else "MISSING", " ", part.position if part != null else "")
		root.free()
	quit()
	return true
