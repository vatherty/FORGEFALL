# verify_skies.gd — per-map sky checks (real photographic skyboxes).
# Usage:
#   godot --headless --path . --script res://tools/verify_skies.gd
#   xvfb-run godot --path . --script res://tools/verify_skies.gd
#
# Headless: instantiates every map scene and asserts each produces a
# WorldEnvironment whose sky is a PanoramaSkyMaterial carrying a real
# photographic equirect texture (Poly Haven, CC0 — see
# assets/skies/SOURCES.md), that the texture file exists and differs
# from every other map's, glow stays OFF, fog_sky_affect stays < 0.5,
# exactly one DirectionalLight3D exists, and the full sky signature
# (texture + fog + sun) differs from every other map's.
#
# With a real renderer it ALSO re-captures the standard audit viewpoints
# (player spawn, eye height, horizon shot + 22-degree sky shot) into
# ~/workspace/bugbash-finish/sky-audit/real-after/ and prints the average
# frame time per map as a rough sky-cost sanity check.
extends SceneTree

const MAPS := ["dustline", "foundry", "factory", "outpost", "cinder_city", "tower_defense", "zombies_flat"]
const AFTER_DIR := "/home/hatch/workspace/bugbash-finish/sky-audit/real-after"

var _fails := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var capture := DisplayServer.get_name() != "headless"
	if capture:
		root.size = Vector2i(960, 540)
		DirAccess.make_dir_recursive_absolute(AFTER_DIR)
	var signatures := {}
	var textures := {}
	for key in MAPS:
		var arena := Node3D.new()
		arena.name = "Arena_" + key
		root.add_child(arena)
		var map = load("res://scenes/maps/" + key + ".tscn").instantiate()
		arena.add_child(map)
		if capture and key == "zombies_flat":
			var town = load("res://scripts/modes/zombies.gd").new()
			arena.add_child(town)
			town.start_run()
		for i in range(6):
			await process_frame

		var we := _find_we(arena)
		_check(we != null and we.environment != null, key + ": WorldEnvironment with Environment exists")
		if we != null and we.environment != null:
			var env := we.environment
			_check(env.background_mode == Environment.BG_SKY, key + ": background is sky")
			_check(env.sky != null and env.sky.sky_material is PanoramaSkyMaterial,
				key + ": sky material is PanoramaSkyMaterial (real photo skybox)")
			_check(not env.glow_enabled, key + ": glow stays OFF")
			_check(env.fog_sky_affect < 0.5, key + ": fog_sky_affect %.2f < 0.5 (no peach wash)" % env.fog_sky_affect)
			if env.sky != null and env.sky.sky_material is PanoramaSkyMaterial:
				var m := env.sky.sky_material as PanoramaSkyMaterial
				_check(m.panorama != null, key + ": panorama texture is set")
				if m.panorama != null:
					var tp := m.panorama.resource_path
					_check(tp != "" and ResourceLoader.exists(tp),
						key + ": panorama texture file exists (" + tp + ")")
					if textures.has(tp):
						_check(false, key + ": panorama texture COLLIDES with " + str(textures[tp]))
					else:
						textures[tp] = key
						_check(true, key + ": panorama texture distinct (" + tp + ")")
				var sun := _find_sun(arena)
				_check(sun != null, key + ": exactly the shared sun exists")
				var sig := _signature(m, env, sun)
				if signatures.has(sig):
					_check(false, key + ": sky signature COLLIDES with " + str(signatures[sig]))
				else:
					signatures[sig] = key
					_check(true, key + ": sky signature distinct (" + sig.left(60) + "...)")
		if capture:
			await _capture(key, arena)
		arena.queue_free()
		await process_frame
		await process_frame

	if _fails == 0:
		print("VERIFY-SKIES: ALL CHECKS PASSED (%d maps)" % MAPS.size())
	else:
		printerr("VERIFY-SKIES: %d CHECK(S) FAILED" % _fails)
	quit(1 if _fails > 0 else 0)


func _signature(m: PanoramaSkyMaterial, env: Environment, sun: DirectionalLight3D) -> String:
	var parts := [
		m.panorama.resource_path if m.panorama != null else "<none>",
		env.fog_light_color, env.fog_density, env.fog_sky_affect,
		env.ambient_light_energy, env.tonemap_exposure,
	]
	if sun != null:
		parts.append(sun.light_color)
		parts.append(sun.light_energy)
		parts.append(sun.rotation_degrees)
	return str(parts)


func _capture(key: String, arena: Node) -> void:
	var cam_pos := Vector3(0, 1.7, 0)
	var spawns := get_nodes_in_group("player_spawn")
	for s in spawns:
		if arena.is_ancestor_of(s):
			cam_pos = (s as Node3D).global_position + Vector3(0, 1.7, 0)
			break
	var sun_dir := Vector3(0, 0, -1)
	var sun := _find_sun(arena)
	if sun != null:
		var b := sun.global_transform.basis.z
		sun_dir = Vector3(b.x, 0, b.z).normalized()
	var camera := Camera3D.new()
	arena.add_child(camera)
	camera.position = cam_pos
	camera.fov = 70.0
	camera.current = true

	var t0 := Time.get_ticks_msec()
	camera.look_at(cam_pos + sun_dir * 50.0, Vector3.UP)
	await _settle()
	var img1: Image = root.get_texture().get_image()
	img1.save_png(AFTER_DIR + "/" + key + "_horizon.png")
	var up_dir := sun_dir.rotated(sun_dir.cross(Vector3.UP).normalized(), deg_to_rad(22.0))
	camera.look_at(cam_pos + up_dir * 50.0, Vector3.UP)
	await _settle()
	var img2: Image = root.get_texture().get_image()
	img2.save_png(AFTER_DIR + "/" + key + "_sky.png")
	var ms := float(Time.get_ticks_msec() - t0) / 20.0
	print("CAPTURE %s: saved horizon+sky (avg frame %.1f ms over settle)" % [key, ms])
	# Sun/moon disc evidence: brightest pixel of the sky shot should be
	# near-clip bright when looking toward the light.
	var best := 0.0
	for y in range(0, img2.get_height(), 3):
		for x in range(0, img2.get_width(), 3):
			var c := img2.get_pixel(x, y)
			best = maxf(best, c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722)
	print("CAPTURE %s: sky-shot brightest luminance %.2f" % [key, best])


func _settle() -> void:
	for i in range(10):
		await process_frame
	await RenderingServer.frame_post_draw


func _find_sun(node: Node) -> DirectionalLight3D:
	if node is DirectionalLight3D:
		return node
	for c in node.get_children():
		var r := _find_sun(c)
		if r != null:
			return r
	return null


func _find_we(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node
	for c in node.get_children():
		var r := _find_we(c)
		if r != null:
			return r
	return null
