# Run using isolated preference storage, as verify_settings.gd does.
extends SceneTree
var failures := 0
var checks := 0
func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
	print(("PASS: " if condition else "FAIL: ") + label)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	if not OS.get_user_data_dir().begins_with("/tmp/forge-effects-verification/"):
		printerr("Use XDG_DATA_HOME=/tmp/forge-effects-verification for this test.")
		quit(1)
		return
	var prefs: Node = root.get_node("Preferences")
	var effects: Node = root.get_node("ScreenEffects")
	prefs.reset()
	check(not effects.is_effect_active() and effects._copy.copy_mode == BackBufferCopy.COPY_MODE_DISABLED, "off by default: no filter draw or screen copy")
	var player: Node = load("res://tools/mock_look_player.gd").new()
	root.add_child(player)
	await process_frame
	prefs.change("effects_enabled", true)
	check(effects.is_effect_active(), "enabling during a run takes effect immediately")
	check(effects.layer < 0 and effects._rect.mouse_filter == Control.MOUSE_FILTER_IGNORE, "effect stays below all UI and never captures touch")
	check(effects._copy.copy_mode == BackBufferCopy.COPY_MODE_VIEWPORT, "active effect gets a fresh screen copy")
	for look in 5:
		prefs.change("effects_look", look)
		check(effects._material.get_shader_parameter("look") == look + 1, "look %d selects the correct single-pass treatment" % look)
	prefs.change("effects_strength", 0.0)
	check(not effects.is_effect_active() and effects._copy.copy_mode == BackBufferCopy.COPY_MODE_DISABLED, "zero intensity bypasses both filter and copy")
	prefs.change("effects_strength", 0.8)
	check(effects.is_effect_active() and is_equal_approx(effects._material.get_shader_parameter("strength"), 0.8), "strength resumes effect live")
	for pair in {"effects_lens": "lens_enabled", "effects_grain": "grain_enabled", "effects_vignette": "vignette_enabled", "effects_chromatic": "chromatic_enabled", "effects_scanlines": "scanlines_enabled", "effects_lightweight": "lightweight"}:
		prefs.change(pair, false)
	var all_disabled := true
	for param in ["lens_enabled", "grain_enabled", "vignette_enabled", "chromatic_enabled", "scanlines_enabled", "lightweight"]:
		all_disabled = all_disabled and effects._material.get_shader_parameter(param) == false
	check(all_disabled, "individual controls reach the shader")
	var cfg := ConfigFile.new()
	cfg.load(prefs.PATH)
	check(cfg.get_value("ui", "effects_enabled") and cfg.get_value("ui", "effects_look") == 4, "selected treatment persists")
	prefs.change("effects_enabled", false)
	check(not effects.is_effect_active() and effects._copy.copy_mode == BackBufferCopy.COPY_MODE_DISABLED, "master off fully bypasses processing")
	prefs.change("effects_enabled", true)
	player.free()
	await process_frame
	check(not effects.is_effect_active(), "leaving the run removes the effect")
	check(ProjectSettings.get_setting("rendering/renderer/rendering_method.web") == "gl_compatibility", "Web exports explicitly use Compatibility")
	prefs.reset()
	print("SCREEN EFFECTS: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
