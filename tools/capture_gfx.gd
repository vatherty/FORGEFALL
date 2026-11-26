# capture_gfx.gd — BB-9 before/after capture harness.
# Usage (real renderer — xvfb-run locally):
#   xvfb-run godot --path . --script res://tools/capture_gfx.gd -- \
#       --capture-label=low --gfx-tier=low
#   xvfb-run godot --path . --script res://tools/capture_gfx.gd -- \
#       --capture-label=high --gfx-tier=high
# Optional: --capture-map=<key> (default: cinder_city, dustline,
# zombies_flat).
#
# Per map, three 960x540 viewpoints into
# ~/workspace/bugbash-finish/gfx-audit/<label>/:
#   <map>_horizon.png — player spawn at eye height, looking along the
#     sun azimuth (the sky-audit viewpoint: sky + skyline + shadows).
#   <map>_ground.png  — spawn at eye height looking at the arena heart
#     (gameplay view: buildings, grounding, decals).
#   <map>_closeup.png — halfway from spawn to the centre, low camera
#     looking at the centre mass (grit/AO on near walls + ground).
extends SceneTree

const OUT_ROOT := "/home/hatch/workspace/bugbash-finish/gfx-audit"
var _label := "low"
var _maps := ["cinder_city", "dustline", "zombies_flat"]


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture-label="):
			_label = a.trim_prefix("--capture-label=")
		elif a.begins_with("--capture-map="):
			_maps = [a.trim_prefix("--capture-map=")]
	call_deferred("run")


func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("CAPTURE: headless display — nothing to capture. Use xvfb-run.")
		quit(2)
		return
	root.size = Vector2i(960, 540)
	GfxSettings.apply_msaa(root)
	var out_dir := OUT_ROOT + "/" + _label
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("CAPTURE label=%s gfx[%s]" % [_label, GfxSettings.describe()])
	for key in _maps:
		var arena := Node3D.new()
		arena.name = "Cap_" + key
		root.add_child(arena)
		var map = load("res://scenes/maps/" + key + ".tscn").instantiate()
		arena.add_child(map)
		for i in range(6):
			await process_frame

		var spawn := Vector3(0, 0, 24)
		for s in get_nodes_in_group("player_spawn"):
			if arena.is_ancestor_of(s):
				spawn = (s as Node3D).global_position
				break
		var sun_dir := Vector3(0, 0, -1)
		var sun := _find_sun(arena)
		if sun != null:
			var b := sun.global_transform.basis.z
			sun_dir = Vector3(b.x, 0, b.z).normalized()

		var camera := Camera3D.new()
		arena.add_child(camera)
		camera.fov = 70.0
		camera.current = true

		var eye := spawn + Vector3(0, 1.7, 0)
		await _shot(camera, eye, eye + sun_dir * 50.0, out_dir + "/" + key + "_horizon.png")
		await _shot(camera, eye, Vector3(0, 1.6, 0), out_dir + "/" + key + "_ground.png")
		var mid := eye.lerp(Vector3(0, 1.4, 0), 0.55)
		await _shot(camera, mid, Vector3(0, 2.4, 0), out_dir + "/" + key + "_closeup.png")
		arena.queue_free()
		await process_frame
		await process_frame
	print("CAPTURE: done -> ", out_dir)
	quit(0)


func _shot(camera: Camera3D, pos: Vector3, target: Vector3, path: String) -> void:
	camera.position = pos
	camera.look_at(target, Vector3.UP)
	for i in range(10):
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	img.save_png(path)
	print("CAPTURE saved ", path)


func _find_sun(node: Node) -> DirectionalLight3D:
	if node is DirectionalLight3D:
		return node
	for c in node.get_children():
		var r := _find_sun(c)
		if r != null:
			return r
	return null
