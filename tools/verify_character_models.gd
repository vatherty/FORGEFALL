extends SceneTree
var _frames := 0
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	var soldier_script = load("res://scripts/enemies/voxel_soldier.gd")
	var failures := 0
	for id in ["grunt", "rusher", "marksman", "brute", "shredder", "suppressor", "bulwark", "warlord"]:
		var soldier: Node3D = soldier_script.new()
		root.add_child(soldier)
		var rig: Dictionary = soldier.call("build", id)
		var visible_count := 0
		for mesh in soldier.find_children("*", "MeshInstance3D", true, false):
			if (mesh as MeshInstance3D).visible:
				visible_count += 1
		if rig.get("head_hitbox") == null or rig.get("muzzle") == null or soldier.find_child("Authored_BodyRoot", true, false) == null or visible_count < 6:
			printerr("FAIL ", id, " rig/visual missing; visible meshes=", visible_count)
			failures += 1
		elif id != "shredder" and soldier.find_child("AuthoredGun", true, false) == null:
			printerr("FAIL ", id, " authored gun missing")
			failures += 1
		else:
			print("PASS ", id, " authored body/gun bound to animated rig; visible meshes=", visible_count)
		soldier.call("animate_full", 0.1, {"speed": 2.0, "aiming": true, "windup": 0.4})
		var muzzle: Node3D = rig["muzzle"]
		var forward := muzzle.global_transform.basis * Vector3.FORWARD
		var body_forward := soldier.global_transform.basis * Vector3.FORWARD
		if forward.normalized().dot(body_forward.normalized()) < 0.9:
			printerr("FAIL ", id, " muzzle tips away from target when aiming")
			failures += 1
		soldier.free()
	quit(1 if failures > 0 else 0)
	return true
