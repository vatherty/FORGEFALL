# Deterministic GPU test: run its .tscn with Compatibility, or export it as a Web main scene.
# Changes test dictionaries only; does not save user preferences.
extends Node3D
var _failures := 0
var _checks := 0
var _effects: Node
var _values: Dictionary

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print(("PASS: " if condition else "FAIL: ") + label)

func _ready() -> void:
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4
	camera.position = Vector3(0, 0, 5)
	add_child(camera)
	camera.current = true
	var environment := WorldEnvironment.new()
	var background := Environment.new()
	background.background_mode = Environment.BG_COLOR
	background.background_color = Color(0.12, 0.18, 0.30)
	background.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.environment = background
	add_child(environment)
	for index in 9:
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.85, 0.85, 0.3)
		mesh.mesh = box
		mesh.position = Vector3((index % 3 - 1) * 1.1, (index / 3 - 1) * 1.1, 0)
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = [Color(0.9, 0.2, 0.1), Color(0.1, 0.85, 0.3), Color(0.2, 0.3, 0.9)][index % 3]
		mesh.material_override = material
		add_child(mesh)
	# A normal canvas HUD marker, above layer -1, must remain exactly magenta.
	var hud := ColorRect.new()
	hud.color = Color(1, 0, 1)
	hud.position = Vector2(4, 4)
	hud.size = Vector2(90, 50)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	add_child(load("res://tools/mock_look_player.gd").new())
	_effects = get_node("/root/ScreenEffects")
	_values = Preferences.values.duplicate()
	await _frames()
	await _run()

func _frames() -> void:
	for index in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

func _capture() -> Image:
	return get_viewport().get_texture().get_image()

func _difference(a: Image, b: Image) -> float:
	var difference := 0.0
	var samples := 0
	for y in range(64, a.get_height(), 24):
		for x in range(0, a.get_width(), 24):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			difference += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			samples += 1
	return difference / maxf(1, samples * 3)

func _run() -> void:
	_values.effects_enabled = false
	_effects.configure(_values)
	await _frames()
	var baseline := _capture()
	_values.effects_enabled = true
	_values.effects_strength = 1.0
	_values.effects_grain = false
	for index in 5:
		_values.effects_look = index
		_effects.configure(_values)
		await _frames()
		var filtered := _capture()
		var difference := _difference(baseline, filtered)
		_check(difference > 0.003, "%s changes the rendered world (difference %.4f)" % [ScreenEffects.LOOK_NAMES[index], difference])
		_check(filtered.get_pixel(20, 20).is_equal_approx(baseline.get_pixel(20, 20)), "HUD stays unchanged with look %d" % index)
	_values.effects_look = 0
	_values.effects_chromatic = true
	_values.effects_lightweight = false
	_effects.configure(_values)
	await _frames()
	_check(_difference(baseline, _capture()) > 0.003, "full Bodycam branch renders with color fringing")
	_values.effects_strength = 0.0
	_effects.configure(_values)
	await _frames()
	_check(_difference(baseline, _capture()) < 0.001, "zero intensity returns the original image")
	_values.effects_enabled = false
	_effects.configure(_values)
	await _frames()
	_check(_difference(baseline, _capture()) < 0.001, "off returns the original image")
	print("EFFECTS_RENDER: %d checks, %d failures" % [_checks, _failures])
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.forgeEffectsResult = " + JSON.stringify({"checks": _checks, "failures": _failures, "renderer": RenderingServer.get_current_rendering_method()}) + ";")
	else:
		get_tree().quit(1 if _failures else 0)
