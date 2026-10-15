# camera_check.gd — validates the 2026-10-12 black-viewport hotfix.
# Boots the real main scene, calls start_game(), and asserts a Player node
# with a CURRENT Camera3D exists in the tree. Exit 0 + "CAMERA OK" = fixed.
extends SceneTree

var _main: Node = null
var _frames := 0

func _initialize() -> void:
	var ps := load("res://scenes/main.tscn") as PackedScene
	_main = ps.instantiate()
	root.add_child(_main)
	current_scene = _main
	print("CAMCHECK: booted to menu")

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 5:
		_main.call("start_game")
		print("CAMCHECK: start_game called")
	if _frames == 60:
		var players := get_nodes_in_group("player")
		print("CAMCHECK: player nodes in group: ", players.size())
		var cam: Camera3D = root.get_camera_3d()
		print("CAMCHECK: viewport camera_3d: ", cam)
		if cam != null:
			print("CAMCHECK: camera current: ", cam.current, ", global pos: ", cam.global_position)
		if players.size() > 0 and cam != null and cam.current:
			print("CAMCHECK: CAMERA OK — black viewport bug is fixed")
		else:
			printerr("CAMCHECK: FAIL — no player and/or no current camera")
		return true
	return false
