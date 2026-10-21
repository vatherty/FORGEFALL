# Shared, persistent preferences. Never stores API credentials.
extends Node

const PATH := "user://forge_settings.cfg"
const DEFAULTS := {
	"sensitivity": 1.0, "touch_sensitivity": 1.0, "ads_sensitivity": 0.45,
	"invert_y": false, "fov": 90.0, "master_vol": 0.9, "music_vol": 0.7,
	"sfx_vol": 1.0, "ui_vol": 1.0, "quality": 2, "vsync": true,
	"fullscreen": false, "haptics": true, "touch_opacity": 0.8,
}
var values: Dictionary = DEFAULTS.duplicate()

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for key in DEFAULTS:
			values[key] = cfg.get_value("ui", key, DEFAULTS[key])
	apply.call_deferred()
	get_tree().node_added.connect(func(node: Node):
		if node.has_method("add_look") or node.is_in_group("touch_controls"):
			apply.call_deferred())

func change(key: String, value: Variant) -> Error:
	if not DEFAULTS.has(key):
		return ERR_INVALID_PARAMETER
	values[key] = value
	apply()
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	for name in values:
		cfg.set_value("ui", name, values[name])
	return cfg.save(PATH)

func reset() -> Error:
	values = DEFAULTS.duplicate()
	return change("sensitivity", DEFAULTS.sensitivity)

func apply() -> void:
	for bus in {"Master": "master_vol", "Music": "music_vol", "SFX": "sfx_vol", "UI": "ui_vol"}:
		var index := AudioServer.get_bus_index(bus)
		if index >= 0:
			var value := clampf(float(values[{"Master": "master_vol", "Music": "music_vol", "SFX": "sfx_vol", "UI": "ui_vol"}[bus]]), 0, 1)
			AudioServer.set_bus_mute(index, value <= 0)
			AudioServer.set_bus_volume_db(index, linear_to_db(maxf(value, 0.001)))
	get_viewport().scaling_3d_scale = [0.7, 0.85, 1.0][clampi(int(values.quality), 0, 2)]
	if not OS.has_feature("web") and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if values.vsync else DisplayServer.VSYNC_DISABLED)
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if values.fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)
	for player in get_tree().get_nodes_in_group("player"):
		if player.has_method("apply_preferences"):
			player.apply_preferences(values)
	for touch in get_tree().get_nodes_in_group("touch_controls"):
		touch.set_look_sensitivity(float(values.touch_sensitivity))
		for definition in touch.get("_btn_defs"):
			definition.btn.self_modulate.a = float(values.touch_opacity)
