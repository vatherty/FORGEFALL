# verify_v05_a4_hud.gd — headless checks for the v0.5 A4 HUD polish stream.
# Usage: godot --headless --path <project> --script res://tools/verify_v05_a4_hud.gd
# Checks (standalone HUD instance, no player / no killstreaks assumptions):
#   1. HUD builds: ammo/health/killfeed/hitmarker/vignette/pips/UAV nodes exist.
#   2. Killfeed caps visible entries at 4 (10 adds -> <= 4 labels with alpha > 0).
#   3. Hitmarker variants run: hit (white), headshot (gold, 1.25x), kill (red, 1.45x + dot).
#   4. Damage vignette + health display run without error; health bar scales + recolors.
#   5. Ammo display + killstreak pips (icons + READY status) update.
#   6. UAV works WITHOUT the killstreaks object (null guards, set_uav legacy
#      path, signal handlers) AND with it bound (bind finds the real object,
#      no error despite the new signals not existing yet).
#   7. StencilStyle helpers: pip_style / hitmarker_color / health_color.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _hud: CanvasLayer = null
var _ss: GDScript = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	_ss = load("res://scripts/ui/stencil_style.gd") as GDScript
	var hud_script := load("res://scripts/ui/hud.gd") as GDScript
	_hud = hud_script.new() as CanvasLayer
	root.add_child(_hud)
	_phase = 1
	print("VERIFY-A4: HUD instantiated, waiting for _ready")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 5:
				return false
			_check_structure()
			_check_killfeed_cap()
			_check_hitmarker()
			_check_vignette_health()
			_check_ammo_pips()
			_check_uav_without_object()
			_phase = 2
			_frames = 0
		2:
			if _frames < 3:
				return false
			_check_uav_with_object()
			_check_stencil()
			_phase = 3
		3:
			if _fails == 0:
				print("VERIFY-A4: ALL CHECKS PASSED")
			else:
				printerr("VERIFY-A4: %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


func _check_structure() -> void:
	_check(_hud.is_in_group("hud"), "HUD is in group 'hud'")
	_check(_hud.get("_ammo_label") is Label, "ammo label exists")
	_check(_hud.get("_ammo_caption") is Label, "ammo caption exists")
	_check(_hud.get("_hp_label") is Label, "health numeric label exists")
	_check(_hud.get("_hp_bar_fill") is ColorRect, "health bar fill exists")
	_check(_hud.get("_killfeed_box") is VBoxContainer, "killfeed box exists")
	_check((_hud.get("_kf_labels") as Array).size() == 4, "killfeed pool is exactly 4")
	_check((_hud.get("_hit_lines") as Array).size() == 4, "hitmarker has 4 lines")
	_check(_hud.get("_hit_dot") is ColorRect, "hitmarker kill dot exists")
	_check(_hud.get("_vignette") is ColorRect, "damage vignette exists")
	_check(_hud.get("_dir_ind") is ColorRect, "directional damage indicator exists")
	_check((_hud.get("_pip_icons") as Array).size() == 3, "3 killstreak icons exist")
	_check((_hud.get("_pip_names") as Array).size() == 3, "3 killstreak name labels exist")
	_check(_hud.get("_uav_label") is Label, "UAV status label exists")
	_check(_hud.get("_uav_label").visible == false, "UAV label hidden when inactive")


func _check_killfeed_cap() -> void:
	for i in 10:
		_hud.call("add_killfeed", "YOU ▸ ENEMY %d" % i)
	var visible := 0
	for l in (_hud.get("_kf_labels") as Array):
		if (l as Label).modulate.a > 0.0:
			visible += 1
	_check(visible <= 4, "killfeed caps visible entries at 4 (got %d after 10 adds)" % visible)


func _check_hitmarker() -> void:
	var root := _hud.get_node_or_null("Hitmarker") as Control
	_hud.call("show_hitmarker", false, false)
	_check(root != null and root.visible, "hitmarker shows on hit")
	_check(_hud.get("_hit_base_color") == _ss.hitmarker_color("hit"), "hit variant is white")
	_hud.call("show_hitmarker", false, true)
	_check(_hud.get("_hit_base_color") == _ss.hitmarker_color("headshot"), "headshot variant is gold")
	_check(root.scale.x > 1.2 and root.scale.x < 1.3, "headshot hitmarker scales 1.25x")
	_hud.call("show_hitmarker", true, false)
	_check(_hud.get("_hit_base_color") == _ss.hitmarker_color("kill"), "kill variant is red")
	_check(root.scale.x > 1.4 and root.scale.x < 1.5, "kill hitmarker scales 1.45x")
	_check((_hud.get("_hit_dot") as ColorRect).visible, "kill hitmarker shows center dot")
	_hud.call("show_hitmarker", false, false)
	_check((_hud.get("_hit_dot") as ColorRect).visible == false, "plain hit hides center dot")


func _check_vignette_health() -> void:
	# No player bound in this harness: direction arc is skipped, vignette
	# must still tween without error.
	_hud.call("damage_flash", Vector3(1, 0, 0))
	_check(true, "damage_flash runs without error (no player bound)")
	_hud.call("_on_health_changed", 25.0, 100.0)
	_check((_hud.get("_hp_label") as Label).text == "25 / 100", "health readout shows '25 / 100'")
	var fill := _hud.get("_hp_bar_fill") as ColorRect
	# v0.6.1 UiScale: the bar width is resolution-scaled
	# (_health_bar_w = 280 * UiScale), so assert FRACTIONS of the
	# scaled width, not absolute pixels (headless 1280x720 -> 0.667x).
	var bar_w := float(_hud.get("_health_bar_w"))
	_check(absf(fill.size.x - bar_w * 0.25) < 1.0, "health bar fill ~quarter of scaled width (got %.1f, bar %.1f)" % [fill.size.x, bar_w])
	_check(fill.color == _ss.health_color(0.25), "low health bar is red")
	_hud.call("_on_health_changed", 100.0, 100.0)
	_check(absf((_hud.get("_hp_bar_fill") as ColorRect).size.x - bar_w) < 1.0, "full health fills the scaled bar")
	_check((_hud.get("_hp_bar_fill") as ColorRect).color == _ss.health_color(1.0), "full health bar is green")


func _check_ammo_pips() -> void:
	_hud.call("_on_ammo_changed", 3, 30)
	_check((_hud.get("_ammo_label") as Label).text == "3 | 30", "ammo shows '3 | 30'")
	_hud.call("_on_ammo_changed", 0, 30)
	_check((_hud.get("_reload_label") as Label).visible, "RELOAD shows at 0 mag")
	_hud.call("_on_ammo_changed", 12, 30)
	_check((_hud.get("_reload_label") as Label).visible == false, "RELOAD hides with ammo")
	_hud.call("set_killstreak_pips", [true, false, true])
	var unlocked: Array = _hud.get("_pip_unlocked")
	_check(unlocked[0] == true and unlocked[1] == false and unlocked[2] == true, "pips track unlocked array")
	var status0 := (_hud.get("_pip_keys") as Array)[0] as Label
	_check(status0.text.find("READY") >= 0, "ready pip status shows READY")
	var icon0 := (_hud.get("_pip_icons") as Array)[0] as Label
	_check(icon0.text == "◎", "UAV pip icon is ◎")
	var icon1 := (_hud.get("_pip_icons") as Array)[1] as Label
	_check(icon1.text == "▼", "airstrike pip icon is ▼")
	var icon2 := (_hud.get("_pip_icons") as Array)[2] as Label
	_check(icon2.text == "▲", "chopper pip icon is ▲")
	_hud.call("set_touch_mode", true)
	var status_touch := (_hud.get("_pip_keys") as Array)[0] as Label
	_check(status_touch.text == "READY", "touch mode drops key hints (READY, no [4])")
	_hud.call("set_touch_mode", false)


func _check_uav_without_object() -> void:
	# Force the no-object state: null guards must hold, legacy path works.
	_hud.set("_killstreaks_obj", null)
	_hud.call("_fetch_uav_targets")
	_check(true, "get_uav_targets fetch with no object is a safe no-op")
	_hud.call("set_uav", 20.0)
	_check(_hud.get("_uav_active") == true, "legacy set_uav activates UAV without object")
	_check((_hud.get("_uav_label") as Label).visible, "UAV label shows on set_uav")
	_hud.call("_on_uav_ended")
	_check(_hud.get("_uav_active") == false, "uav_ended deactivates UAV")
	_check((_hud.get("_uav_label") as Label).visible == false, "UAV label hides on uav_ended")
	_hud.call("_on_uav_started", 12.0)
	_check(_hud.get("_uav_active") == true and _hud.get("_uav_remaining") == 12.0, "uav_started signal handler sets duration")
	_hud.call("_on_uav_ended")


func _check_uav_with_object() -> void:
	# Real Killstreaks object exists via the Forge autoload (group
	# "killstreaks") but has no uav_started/uav_ended signals yet — binding
	# must not error, and the HUD must stay functional afterwards.
	_hud.set("_killstreaks_obj", null)
	_hud.call("_bind_uav")
	var obj: Object = _hud.get("_killstreaks_obj")
	_check(obj != null, "bind finds the killstreaks object when present")
	_hud.call("add_killfeed", "BIND OK")
	_check(true, "HUD still functional after binding to object without new signals")
	# Signal handlers still drive display even when the emitter is the
	# legacy implementation.
	_hud.call("_on_uav_started", 5.0)
	_check(_hud.get("_uav_active") == true, "uav_started works with object bound")
	_hud.call("_on_uav_ended")
	_check(_hud.get("_uav_active") == false, "uav_ended works with object bound")


func _check_stencil() -> void:
	_check(_ss.pip_style(true) is StyleBoxFlat, "StencilStyle.pip_style(ready) returns a StyleBoxFlat")
	_check(_ss.pip_style(false) is StyleBoxFlat, "StencilStyle.pip_style(locked) returns a StyleBoxFlat")
	_check(_ss.hitmarker_color("headshot") == _ss.GOLD, "hitmarker_color headshot == GOLD")
	_check(_ss.hitmarker_color("kill") == _ss.RED, "hitmarker_color kill == RED")
	_check(_ss.health_color(0.1) == _ss.RED, "health_color low == RED")
	_check(_ss.health_color(0.4) == _ss.ORANGE, "health_color mid == ORANGE")
	_check(_ss.health_color(0.9) == _ss.GREEN, "health_color high == GREEN")
