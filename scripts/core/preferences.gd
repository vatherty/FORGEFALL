# Shared, persistent preferences. Never stores API credentials.
extends Node

const PATH := "user://forge_settings.cfg"
const DEFAULTS := {
	"sensitivity": 1.0, "touch_sensitivity": 1.0, "ads_sensitivity": 0.45,
	"invert_y": false, "fov": 90.0, "master_vol": 0.9, "music_vol": 0.7,
	"sfx_vol": 1.0, "ui_vol": 1.0, "quality": 2, "vsync": true,
	"fullscreen": false, "haptics": true, "touch_opacity": 0.8,
	"effects_enabled": false, "effects_look": 0, "effects_strength": 0.65,
	"effects_lightweight": true, "effects_lens": true, "effects_grain": true,
	"effects_vignette": true, "effects_chromatic": false, "effects_scanlines": true,
	# BB-8: TDM bot difficulty tier (BotFighter.SKILL_TIERS id). Set
	# from the DEPLOY panel's BOT LEVEL selector; read by BotTDM.
	"bot_difficulty": "regular",
	# BB-9: graphics tier + per-feature overrides, resolved by
	# GfxSettings (scripts/core/gfx_settings.gd). gfx_tier: 0 = Low
	# (today's phone-safe look), 1 = High (all features on).
	# gfx_<feature>: -1 = follow tier, 0 = force off, 1 = force on.
	"gfx_tier": 0,
	"gfx_shadows": -1, "gfx_grading": -1, "gfx_glow": -1, "gfx_grit": -1,
	"gfx_ao": -1, "gfx_decals": -1, "gfx_msaa": -1,
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
	var effects := get_node_or_null("/root/ScreenEffects")
	if effects != null:
		effects.configure(values)
	for bus in {"Master": "master_vol", "Music": "music_vol", "SFX": "sfx_vol", "UI": "ui_vol"}:
		var index := AudioServer.get_bus_index(bus)
		if index >= 0:
			var value := clampf(float(values[{"Master": "master_vol", "Music": "music_vol", "SFX": "sfx_vol", "UI": "ui_vol"}[bus]]), 0, 1)
			AudioServer.set_bus_mute(index, value <= 0)
			AudioServer.set_bus_volume_db(index, linear_to_db(maxf(value, 0.001)))
	get_viewport().scaling_3d_scale = [0.7, 0.85, 1.0][clampi(int(values.quality), 0, 2)]
	GfxSettings.apply_msaa(get_viewport())  # BB-9: MSAA follows the gfx flags
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
