# scripts/ui/hud.gd
# FORGEFALL — MW2-style HUD (Worker 6: HUD/UI).
# CanvasLayer holding: crosshair, hitmarker, ammo, health bar + readout,
# damage vignette + directional indicator, killfeed, wave banner,
# killstreak pips (with icons + ready state), minimap, UAV overlay,
# forge console panel, score/wave topbar, touch-mode hints.
#
# CONTRACT (frozen) — other workers call these on the node in group "hud":
#   show_hitmarker(kill: bool, headshot: bool)
#   add_killfeed(text: String)
#   announce(title: String, subtitle: String)
#   set_killstreak_pips(unlocked: Array)
#   damage_flash(direction: Vector3)   # direction TOWARD the damage source
#   set_spread(px: float)
#   set_touch_mode(on: bool)
#   set_uav(duration: float)           # legacy entry point used by Killstreaks
# UAV DISPLAY CONTRACT — read ONLY via the killstreaks object (Forge child /
# group "killstreaks"), all guarded with has_signal/has_method so the HUD
# works with or without it: signals uav_started(duration), uav_ended();
# get_uav_targets() -> Array[Vector3]. Missing object/signals = skip UAV.
# Self-wires to Game/Sfx/Forge autoloads plus player + weapon-manager signals
# when a node in group "player" exposes them (checked via has_signal).
extends CanvasLayer

#region TUNABLES
const HITMARKER_TIME := 0.22        # seconds the hitmarker stays up (incl. fade)
const HITMARKER_FADE := 0.10         # seconds of fade-out at the end
const HIT_PUNCH_TIME := 0.07        # Goal 1: hitmarker overshoot punch duration
const HIT_PUNCH_HIT := 0.30         # Goal 1: punch overshoot, plain hit (+30%)
const HIT_PUNCH_HEADSHOT := 0.38    # Goal 1: punch overshoot, headshot
const HIT_PUNCH_KILL := 0.45        # Goal 1: punch overshoot, kill
const HIT_SOUND_MIN_GAP := 0.05     # Goal 1: min gap between hit ticks (dedupes same-frame doubles)
const KILLFEED_FADE_AFTER := 4.0    # seconds before a killfeed entry fades
const KILLFEED_FADE_TIME := 0.5
const KILLFEED_POOL := 4            # hard cap: never more than 4 visible entries
const KILLFEED_VISIBLE := 4
const BANNER_HOLD := 2.4            # seconds the wave banner stays up
const BANNER_SLIDE := 0.35
const MINIMAP_RANGE := 45.0         # meters; enemies beyond this are hidden
const MINIMAP_SIZE := 180.0         # px
const MINIMAP_BLIP := 3.0           # enemy dot size in meters
const MINIMAP_PLAYER_BLIP := 5.0    # player triangle size in meters
const MINIMAP_ENEMY_POOL := 24
const ENEMY_LIST_REFRESH := 0.5     # seconds between group("enemies") lookups
const LOW_HP_FRAC := 0.30           # below this -> persistent vignette + heartbeat
const HEARTBEAT_INTERVAL := 1.1
const LOW_MAG_RED := 5              # mag <= this -> red tint (and 0 -> RELOAD)
const DAMAGE_VIGNETTE_MAX := 0.55
const DAMAGE_VIGNETTE_IN := 0.08    # quick ramp-in (no harsh pop)
const DAMAGE_VIGNETTE_OUT := 0.9    # smooth fade-out
const DIR_IND_IN := 0.06
const DIR_IND_OUT := 1.1
const HEALTH_BAR_W := 280.0
const UAV_REFRESH := 0.25           # seconds between get_uav_targets() polls
const UAV_BIND_RETRY := 1.0         # seconds between killstreaks bind retries
const BANNER_TOP := 132.0              # resting y-offset of the wave banner
# SFX ids (audio worker owns generation; retarget here if names change).
const SFX_HIT := "hitmarker"
const SFX_KILL := "headshot_ding"
const SFX_HEARTBEAT := "heartbeat"
const SFX_STREAK := "killstreak_ready"
const SFX_WAVE := "wave_start"
const SFX_BUILD := "forge_open"
const SFX_SUBMIT := "forge_submit"
const SFX_RESULT_OK := "forge_success"
const SFX_RESULT_FAIL := "forge_fail"
const SFX_UI := "ui_click"
#endregion

const STREAK_NAMES := ["UAV", "AIRSTRIKE", "CHOPPER"]
const STREAK_KEYS := ["4", "5", "6"]
const STREAK_ICONS := ["◎", "▼", "▲"]  # UAV sweep / airstrike inbound / chopper
const FORGE_CHIPS := ["Build a wall", "Spawn turret", "Need ammo", "UAV now", "Smoke screen"]

# --- built nodes ---
var _crosshair: Control
var _ch_lines: Array[ColorRect] = []
var _ch_dot: ColorRect
# Goal 5: portal pair pips (blue = left, orange = right) under the crosshair.
var _portal_pip_blue: ColorRect
var _portal_pip_orange: ColorRect
var _spread := 0.0
var _ads := false
var _dead := false

var _hit_lines: Array[ColorRect] = []
var _hit_dot: ColorRect
var _hit_root_node: Control
var _hit_t := 0.0
var _hit_base_color := Color(1, 1, 1, 0.95)
# Goal 1: hitmarker punch state. The SETTLED scale is applied at call time
# (callers/verifiers read it synchronously); the overshoot ramps in on the
# next _process frame and eases back to the settled scale.
var _hit_base_scale := 1.0
var _hit_punch := 0.0
var _hit_punch_t := 0.0
var _hit_snd_t := 0.0

var _ammo_caption: Label
var _ammo_label: Label
var _weapon_label: Label
var _reload_label: Label
var _reload_t := 0.0

var _hp_caption: Label
var _hp_label: Label
var _hp_bar_bg: ColorRect
var _hp_bar_fill: ColorRect

var _vignette: ColorRect            # fullscreen damage pulse
var _vignette_tw: Tween
var _lowhp: ColorRect               # persistent low-hp vignette
var _dir_ind: ColorRect             # directional damage arc
var _dir_tw: Tween
var _hp := 100.0
var _max_hp := 100.0
var _heartbeat_t := 0.0
var _lowhp_phase := 0.0

var _killfeed_box: VBoxContainer
var _kf_labels: Array[Label] = []
var _kf_age: Array[float] = []
var _kf_next := 0

var _banner: Control
var _banner_title: Label
var _banner_sub: Label
var _banner_tw: Tween

var _pips: Array[Panel] = []
var _pip_names: Array[Label] = []
var _pip_icons: Array[Label] = []
var _pip_keys: Array[Label] = []  # status line: "[4] READY" / "[4] —" (touch: no key)
var _pip_flash: Array[float] = []
var _pip_unlocked := [false, false, false]

# UAV display (contract-guarded; see header). Never assumed to exist.
var _uav_label: Label
var _uav_active := false
var _uav_remaining := 0.0
var _uav_refresh_t := 0.0
var _uav_bind_t := 0.0
var _killstreaks_obj: Object = null
var _uav_targets_cache: Array = []

var _topbar: Label

var _map_frame: PanelContainer
var _map_container: SubViewportContainer
var _map_view: SubViewport
var _map_root: Node3D
var _map_cam: Camera3D
var _player_blip: MeshInstance3D
var _enemy_blips: Array[MeshInstance3D] = []
var _enemies_cache: Array = []
var _enemy_refresh_t := 0.0
var _player_node: Node3D

var _forge_btn: Button
var _forge_panel: PanelContainer
var _forge_input: LineEdit
var _forge_feed: RichTextLabel
var _forge_budget_label: Label
var _forge_entries: Array[String] = []
var _forge_open := false
var _forge_action := false

var _touch_hints: Label
var _pause_btn: Button
var _touch_mode := false

# Windows mouse capture (Worker A): CAPTURED only during gameplay, VISIBLE
# in every menu. _sync_mouse_mode() is the single decision point, called
# from _process (unpaused) and from the ALWAYS watchdog below (paused —
# HUD._process itself freezes under get_tree().paused, so the watchdog is
# what releases capture when pause opens via ESC). MouseCapture is the
# only writer of Input.mouse_mode and the mouse-button InputMap bindings;
# this HUD only decides which state. See mouse_capture.gd for why binding
# erase/restore (not action_release) is the suppression mechanism.
var _mouse_watchdog: Node = null
var _focus_lost := false
# Set on focus-out, cleared on the first mouse-button press after
# focus-in. While set, _sync_mouse_mode() must NOT restore the mouse
# bindings: restoring on focus-in itself would let the refocus click
# fire. The press consumes itself (binding gone at parse) and restores
# via _input, so the NEXT click fires.
var _focus_click_pending := false

# v0.6.1: Forge-menu HUD hiding. While the Forge menu (or the legacy
# fallback panel) is open, every overlapping HUD node is hidden and its
# prior visibility is saved, so restore is exact (e.g. the minimap only
# comes back if UAV was active). _forge_open stays the toggle state.
var _hud_hidden := false
var _hud_hidden_prev: Dictionary = {}
# v0.6.1: resolution-scaled health-bar width (base HEALTH_BAR_W at 1920x1080).
var _health_bar_w := HEALTH_BAR_W
var _hp_bar: Control

# scratch (no per-frame allocs)
var _tmp_v2 := Vector2.ZERO
var _tmp_v3 := Vector3.ZERO


func _ready() -> void:
	add_to_group("hud")
	layer = 10
	_build_all()
	_apply_ui_scale()
	get_viewport().size_changed.connect(_apply_ui_scale)
	_wire_game()
	_bind_uav()
	_bind_player_deferred()
	refresh_topbar()
	set_killstreak_pips(_game_get("killstreaks_unlocked", []))
	if _game_get("forge_budget", 0) is int:
		_update_forge_budget(int(_game_get("forge_budget", 0)))
	_init_mouse_capture()


# ------------------------------------------------------------------ build ---
func _build_all() -> void:
	# v0.6.1: resolution-scaled health-bar width (recomputed on resize
	# in _apply_ui_scale, which also re-runs _update_health_display).
	_health_bar_w = _scaled_size(HEALTH_BAR_W)
	_build_crosshair()
	_build_hitmarker()
	_build_ammo()
	_build_health()
	_build_vignettes()
	_build_killfeed()
	_build_banner()
	_build_pips()
	_build_topbar()
	_build_minimap()
	_build_uav()
	_build_forge()
	_build_touch_hints()
	_build_pause_button()


func _full() -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(c)
	return c


func _build_crosshair() -> void:
	_crosshair = Control.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 200x200 box centered on screen; lines positioned around its middle.
	_crosshair.offset_left = -100
	_crosshair.offset_top = -100
	_crosshair.offset_right = 100
	_crosshair.offset_bottom = 100
	var root := _full()
	root.add_child(_crosshair)
	_ch_lines.clear()
	for i in 4:
		var r := ColorRect.new()
		r.color = Color(1, 1, 1, 0.95)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_crosshair.add_child(r)
		_ch_lines.append(r)
	_ch_dot = ColorRect.new()
	_ch_dot.color = Color(1, 1, 1, 0.95)
	_ch_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ch_dot.size = Vector2(3, 3)
	_ch_dot.position = Vector2(98.5, 98.5)
	_crosshair.add_child(_ch_dot)
	# Goal 5: portal pair pips — lit when that portal disc is live.
	_portal_pip_blue = ColorRect.new()
	_portal_pip_blue.color = Color(0.2, 0.6, 1.0, 1.0)
	_portal_pip_blue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portal_pip_blue.position = Vector2(78, 128)
	_portal_pip_blue.size = Vector2(8, 3)
	_portal_pip_blue.visible = false
	_crosshair.add_child(_portal_pip_blue)
	_portal_pip_orange = ColorRect.new()
	_portal_pip_orange.color = Color(1.0, 0.55, 0.1, 1.0)
	_portal_pip_orange.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portal_pip_orange.position = Vector2(114, 128)
	_portal_pip_orange.size = Vector2(8, 3)
	_portal_pip_orange.visible = false
	_crosshair.add_child(_portal_pip_orange)
	_layout_crosshair()


func _layout_crosshair() -> void:
	# No allocs: repositions the 4 lines + dot from _spread.
	var len := 14.0
	var gap := 6.0 + _spread
	var cx := 100.0
	var cy := 100.0
	# 0: top, 1: bottom, 2: left, 3: right
	_ch_lines[0].position = Vector2(cx - 1, cy - gap - len)
	_ch_lines[0].size = Vector2(2, len)
	_ch_lines[1].position = Vector2(cx - 1, cy + gap)
	_ch_lines[1].size = Vector2(2, len)
	_ch_lines[2].position = Vector2(cx - gap - len, cy - 1)
	_ch_lines[2].size = Vector2(len, 2)
	_ch_lines[3].position = Vector2(cx + gap, cy - 1)
	_ch_lines[3].size = Vector2(len, 2)


func _build_hitmarker() -> void:
	var mk := Control.new()
	mk.name = "Hitmarker"
	mk.set_anchors_preset(Control.PRESET_FULL_RECT)
	mk.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mk.visible = false
	add_child(mk)
	_hit_root_node = mk
	_hit_lines.clear()
	for i in 4:
		var r := ColorRect.new()
		r.color = Color(1, 1, 1, 0.95)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Manual center anchors (deterministic: set_anchors_preset may reset size).
		r.anchor_left = 0.5
		r.anchor_top = 0.5
		r.anchor_right = 0.5
		r.anchor_bottom = 0.5
		r.offset_left = -10.0
		r.offset_top = -1.5
		r.offset_right = 10.0
		r.offset_bottom = 1.5
		r.pivot_offset = Vector2(10, 1.5)
		r.rotation = PI / 4 if i % 2 == 0 else -PI / 4
		# offset each line out along its diagonal
		var d := Vector2(14, 14)
		if i == 1:
			d = Vector2(-14, 14)
		elif i == 2:
			d = Vector2(14, -14)
		elif i == 3:
			d = Vector2(-14, -14)
		r.position += d
		mk.add_child(r)
		_hit_lines.append(r)
	# Center dot: kill variant only — crisp kill confirmation.
	_hit_dot = ColorRect.new()
	_hit_dot.color = StencilStyle.RED
	_hit_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_dot.anchor_left = 0.5
	_hit_dot.anchor_top = 0.5
	_hit_dot.anchor_right = 0.5
	_hit_dot.anchor_bottom = 0.5
	_hit_dot.offset_left = -4.0
	_hit_dot.offset_top = -4.0
	_hit_dot.offset_right = 4.0
	_hit_dot.offset_bottom = 4.0
	_hit_dot.visible = false
	mk.add_child(_hit_dot)
	_hit_t = 0.0


func _hit_root() -> Control:
	if _hit_root_node != null and is_instance_valid(_hit_root_node):
		return _hit_root_node
	_hit_root_node = get_node_or_null("Hitmarker") as Control
	return _hit_root_node


func _build_ammo() -> void:
	# v0.5.1 FIX 2: ammo block moved ABOVE the right-side touch cluster
	# (FIRE/ADS/JUMP/RLD/CRCH/HOOK, whose top edge is ~-252 from bottom at
	# full scale). Bottom edge at -270 leaves an 18px gap; top at -410 fits
	# the bumped font sizes. X range unchanged.
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	box.offset_left = -320
	box.offset_top = -410
	box.offset_right = -28
	box.offset_bottom = -270
	box.alignment = BoxContainer.ALIGNMENT_END
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full().add_child(box)
	_weapon_label = Label.new()
	_weapon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	StencilStyle.apply_hud_body(_weapon_label, _scaled_font(26), StencilStyle.TEXT_DIM, 3)
	_weapon_label.text = "—"
	box.add_child(_weapon_label)
	_ammo_caption = Label.new()
	_ammo_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	StencilStyle.apply_hud_body(_ammo_caption, _scaled_font(20), StencilStyle.TEXT_DIM, 3)
	_ammo_caption.text = "AMMO"
	box.add_child(_ammo_caption)
	_ammo_label = Label.new()
	_ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	StencilStyle.apply_title(_ammo_label, _scaled_font(56), StencilStyle.TEXT, 3)
	_ammo_label.text = "-- | --"
	box.add_child(_ammo_label)
	_reload_label = Label.new()
	_reload_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	StencilStyle.apply_title(_reload_label, _scaled_font(30), StencilStyle.ORANGE, 4)
	_reload_label.text = "RELOAD"
	_reload_label.visible = false
	box.add_child(_reload_label)


func _build_health() -> void:
	# Bottom-left, above the FORGE button: caption + big numeric + bar.
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	box.offset_left = 16
	box.offset_top = -178
	box.offset_right = 316
	box.offset_bottom = -96
	box.alignment = BoxContainer.ALIGNMENT_BEGIN
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full().add_child(box)
	_hp_caption = Label.new()
	StencilStyle.apply_hud_body(_hp_caption, _scaled_font(20), StencilStyle.TEXT_DIM, 3)
	_hp_caption.text = "HEALTH"
	box.add_child(_hp_caption)
	_hp_label = Label.new()
	StencilStyle.apply_title(_hp_label, _scaled_font(40), StencilStyle.TEXT, 3)
	_hp_label.text = "100 / 100"
	box.add_child(_hp_label)
	var bar := Control.new()
	bar.custom_minimum_size = Vector2(_health_bar_w, 16)
	_hp_bar = bar
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bar)
	_hp_bar_bg = ColorRect.new()
	_hp_bar_bg.color = Color(0.05, 0.06, 0.07, 0.9)
	_hp_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_bar_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.add_child(_hp_bar_bg)
	_hp_bar_fill = ColorRect.new()
	_hp_bar_fill.color = StencilStyle.GREEN
	_hp_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_bar_fill.position = Vector2.ZERO
	_hp_bar_fill.size = Vector2(_health_bar_w, 16)
	bar.add_child(_hp_bar_fill)
	_update_health_display()


func _update_health_display() -> void:
	if _hp_label == null or _hp_bar_fill == null:
		return
	_hp_label.text = "%d / %d" % [maxi(0, ceili(_hp)), maxi(1, ceili(_max_hp))]
	var frac := clampf(_hp / _max_hp, 0.0, 1.0)
	_hp_bar_fill.size.x = _health_bar_w * frac
	_hp_bar_fill.color = StencilStyle.health_color(frac)
	_hp_label.add_theme_color_override("font_color",
		StencilStyle.RED if frac < LOW_HP_FRAC else StencilStyle.TEXT)


func _build_vignettes() -> void:
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.color = Color(0.6, 0.02, 0.02, 0.0)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full().add_child(_vignette)
	_lowhp = ColorRect.new()
	_lowhp.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lowhp.color = Color(0.55, 0.03, 0.03, 0.0)
	_lowhp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full().add_child(_lowhp)
	# Directional damage arc: a short red bar placed on a ring around center.
	_dir_ind = ColorRect.new()
	_dir_ind.anchor_left = 0.5
	_dir_ind.anchor_top = 0.5
	_dir_ind.anchor_right = 0.5
	_dir_ind.anchor_bottom = 0.5
	_dir_ind.size = Vector2(120, 22)
	_dir_ind.pivot_offset = Vector2(60, 11)
	_dir_ind.color = Color(0.85, 0.08, 0.06, 0.0)
	_dir_ind.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full().add_child(_dir_ind)


func _build_killfeed() -> void:
	# Hard cap: KILLFEED_POOL == KILLFEED_VISIBLE == 4 pooled labels, reused
	# round-robin — entries can never stack unbounded.
	_killfeed_box = VBoxContainer.new()
	_killfeed_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_killfeed_box.offset_left = -420
	_killfeed_box.offset_top = 84
	_killfeed_box.offset_right = -20
	_killfeed_box.offset_bottom = 320
	_killfeed_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_killfeed_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_killfeed_box.add_theme_constant_override("separation", 4)
	_full().add_child(_killfeed_box)
	_kf_labels.clear()
	_kf_age.clear()
	for i in KILLFEED_POOL:
		var l := Label.new()
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		StencilStyle.apply_hud_body(l, _scaled_font(22), StencilStyle.TEXT, 2)
		l.modulate.a = 0.0
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_killfeed_box.add_child(l)
		_kf_labels.append(l)
		_kf_age.append(999.0)


func _build_banner() -> void:
	_banner = Control.new()
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.offset_left = -500
	_banner.offset_right = 500
	_banner.offset_top = BANNER_TOP
	_banner.offset_bottom = BANNER_TOP + 130.0
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.modulate.a = 0.0
	_full().add_child(_banner)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(vb)
	_banner_title = Label.new()
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_title(_banner_title, _scaled_font(64), StencilStyle.TEXT, 6)
	vb.add_child(_banner_title)
	_banner_sub = Label.new()
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_hud_body(_banner_sub, _scaled_font(28), StencilStyle.ORANGE, 4)
	vb.add_child(_banner_sub)


func _build_pips() -> void:
	var hb := HBoxContainer.new()
	hb.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hb.offset_left = -210
	hb.offset_right = 210
	hb.offset_top = -150
	hb.offset_bottom = -40
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 12)
	_full().add_child(hb)
	_pips.clear()
	_pip_names.clear()
	_pip_icons.clear()
	_pip_keys.clear()
	_pip_flash.clear()
	for i in 3:
		var p := Panel.new()
		p.custom_minimum_size = Vector2(_scaled_size(128), _scaled_size(104))
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(p)
		_pips.append(p)
		_pip_flash.append(0.0)
		var vb := VBoxContainer.new()
		vb.set_anchors_preset(Control.PRESET_FULL_RECT)
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(vb)
		var ic := Label.new()
		ic.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		StencilStyle.apply_hud_body(ic, _scaled_font(32), StencilStyle.TEXT_DIM, 0)
		ic.text = STREAK_ICONS[i]
		vb.add_child(ic)
		_pip_icons.append(ic)
		var nm := Label.new()
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		StencilStyle.apply_hud_body(nm, _scaled_font(20), StencilStyle.TEXT_DIM, 2)
		nm.text = STREAK_NAMES[i]
		vb.add_child(nm)
		_pip_names.append(nm)
		var ky := Label.new()
		ky.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		StencilStyle.apply_hud_body(ky, _scaled_font(20), StencilStyle.TEXT_DIM, 2)
		ky.name = "StatusHint"
		vb.add_child(ky)
		_pip_keys.append(ky)
		_style_pip(i, false)


func _style_pip(i: int, unlocked: bool) -> void:
	_pips[i].add_theme_stylebox_override("panel", StencilStyle.pip_style(unlocked))
	var col := StencilStyle.ORANGE if unlocked else StencilStyle.TEXT_DIM
	_pip_names[i].add_theme_color_override("font_color", col)
	_pip_icons[i].add_theme_color_override("font_color", col)
	_refresh_pip_status(i)


func _refresh_pip_status(i: int) -> void:
	# Ready state at a glance: READY (orange) vs locked (dim dash).
	# Desktop shows the hotkey; touch hides keys (set_touch_mode refreshes).
	var ready: bool = _pip_unlocked[i]
	if _touch_mode:
		_pip_keys[i].text = "READY" if ready else "LOCKED"
	else:
		_pip_keys[i].text = "[%s] READY" % STREAK_KEYS[i] if ready else "[%s] —" % STREAK_KEYS[i]
	_pip_keys[i].add_theme_color_override("font_color",
		StencilStyle.ORANGE if ready else StencilStyle.TEXT_DIM)


func _build_topbar() -> void:
	# v0.5.1 FIX 2: topbar sits BELOW the top-center touch row (FORGE/MIC/
	# K1-K3 ends at y≈72 at full scale) instead of under it. 80..114 leaves
	# an 8px gap; the banner moved to BANNER_TOP=132 so it clears this too.
	_topbar = Label.new()
	_topbar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_topbar.offset_left = -400
	_topbar.offset_right = 400
	_topbar.offset_top = 80
	_topbar.offset_bottom = 114
	_topbar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_hud_body(_topbar, _scaled_font(26), StencilStyle.TEXT, 3)
	_topbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full().add_child(_topbar)


func _blip_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	return m


func _build_minimap() -> void:
	# v0.5.1 FIX 2: minimap is HIDDEN unless UAV is active (no more black
	# void), and when shown it sits BELOW the top-left portal buttons
	# (BLU/ORG end at y≈76) instead of under them. Visibility is synced to
	# _uav_active in _update_uav() and toggled in the UAV handlers.
	# v0.6.1: frame size scales with resolution (build-time only; the
	# SubViewport is not rebuilt on resize).
	var map_size := _scaled_size(MINIMAP_SIZE)
	var frame := PanelContainer.new()
	_map_frame = frame
	frame.visible = false
	frame.set_anchors_preset(Control.PRESET_TOP_LEFT)
	frame.offset_left = 16
	frame.offset_top = 84
	frame.offset_right = 16 + map_size + 8
	frame.offset_bottom = 84 + map_size + 8
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", StencilStyle.panel(Color(0.02, 0.03, 0.04, 0.9), StencilStyle.GUNMETAL, 2))
	_full().add_child(frame)
	_map_container = SubViewportContainer.new()
	_map_container.stretch = true
	_map_container.custom_minimum_size = Vector2(map_size, map_size)
	_map_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_map_container)
	_map_view = SubViewport.new()
	_map_view.size = Vector2i(int(map_size), int(map_size))
	_map_view.own_world_3d = true
	_map_view.transparent_bg = false
	_map_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_map_container.add_child(_map_view)
	_map_root = Node3D.new()
	_map_root.name = "MapRoot"
	_map_view.add_child(_map_root)
	# Dark backdrop so blips read on any terrain.
	var bg := MeshInstance3D.new()
	var bgm := PlaneMesh.new()
	bgm.size = Vector2(MINIMAP_RANGE * 2.4, MINIMAP_RANGE * 2.4)
	bg.mesh = bgm
	bg.material_override = _blip_material(Color(0.03, 0.045, 0.06, 1.0))
	bg.position = Vector3(0, -1, 0)
	_map_root.add_child(bg)
	_map_cam = Camera3D.new()
	_map_cam.position = Vector3(0, 60, 0)
	_map_cam.rotation_degrees = Vector3(-90, 0, 0)
	_map_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_map_cam.size = MINIMAP_RANGE * 2.0
	_map_cam.current = true
	_map_root.add_child(_map_cam)
	# Player triangle (built once).
	_player_blip = MeshInstance3D.new()
	_player_blip.mesh = _make_triangle_mesh(MINIMAP_PLAYER_BLIP)
	_player_blip.material_override = _blip_material(Color(0.25, 0.9, 0.35, 1.0))
	_map_root.add_child(_player_blip)
	# Pooled enemy dots.
	_enemy_blips.clear()
	var dot := PlaneMesh.new()
	dot.size = Vector2(MINIMAP_BLIP, MINIMAP_BLIP)
	for i in MINIMAP_ENEMY_POOL:
		var b := MeshInstance3D.new()
		b.mesh = dot
		b.material_override = _blip_material(Color(0.9, 0.15, 0.12, 1.0))
		b.visible = false
		_map_root.add_child(b)
		_enemy_blips.append(b)


func _build_uav() -> void:
	# Countdown readout under the minimap; visible only while UAV is active.
	# Minimap frame now sits at y 84..272, so this moves to 280..312.
	_uav_label = Label.new()
	_uav_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_uav_label.offset_left = 16
	_uav_label.offset_top = 280
	_uav_label.offset_right = 316
	_uav_label.offset_bottom = 312
	StencilStyle.apply_hud_body(_uav_label, _scaled_font(24), StencilStyle.ORANGE, 3)
	_uav_label.text = "UAV ACTIVE"
	_uav_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_uav_label.visible = false
	_full().add_child(_uav_label)


func _make_triangle_mesh(s: float) -> ArrayMesh:
	# Apex points -Z (player forward). Built once; no per-frame allocs.
	var h := s * 0.5
	var verts := PackedVector3Array([
		Vector3(-h, 0, h * 0.7),
		Vector3(h, 0, h * 0.7),
		Vector3(0, 0, -h),
	])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


func _build_forge() -> void:
	# Gameplay Rework: Forge building exists ONLY in Tower Defense.
	# The Forge button + panel are not built at all for the new
	# non-TD modes (TDM / Zombies / MP / puzzles) — ForgeGate would
	# refuse their builds anyway, and Main never instances the Forge
	# menu for them. Legacy modes keep the button (ForgeGate refuses
	# their live submits per the TD worker's gate).
	if not GameModeManager.forge_menu_allowed(GameModeManager.selected_mode):
		return
	_forge_btn = Button.new()
	_forge_btn.text = "FORGE"
	_forge_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_forge_btn.offset_left = 16
	_forge_btn.offset_top = -84
	_forge_btn.offset_right = 148
	_forge_btn.offset_bottom = -16
	StencilStyle.style_button(_forge_btn)
	_forge_btn.pressed.connect(_toggle_forge)
	_full().add_child(_forge_btn)

	_forge_panel = PanelContainer.new()
	_forge_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_forge_panel.offset_left = 16
	_forge_panel.offset_top = -540
	_forge_panel.offset_right = 516
	_forge_panel.offset_bottom = -96
	_forge_panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	_forge_panel.visible = false
	_full().add_child(_forge_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_forge_panel.add_child(vb)

	var header := HBoxContainer.new()
	vb.add_child(header)
	var title := Label.new()
	StencilStyle.apply_title(title, _scaled_font(22), StencilStyle.ORANGE, 3)
	title.text = "FORGE CONSOLE"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_forge_budget_label = Label.new()
	# Forge budget is OFF (directive A: "remove budget for now").
	# The label stays wired (hidden) so re-enabling budget later is a
	# one-line change; costs are still computed and shown in Forge.
	_forge_budget_label.visible = false
	StencilStyle.apply_hud_body(_forge_budget_label, _scaled_font(20), StencilStyle.TEXT, 2)
	header.add_child(_forge_budget_label)

	_forge_input = LineEdit.new()
	_forge_input.placeholder_text = "Describe a build... (ENTER to forge)"
	_forge_input.clear_button_enabled = true
	StencilStyle.style_lineedit(_forge_input)
	_forge_input.text_submitted.connect(_on_forge_submitted)
	vb.add_child(_forge_input)

	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 6)
	vb.add_child(chips)
	for ctext in FORGE_CHIPS:
		var chip := Button.new()
		chip.text = ctext.to_upper()
		chip.add_theme_stylebox_override("normal", StencilStyle.chip())
		chip.add_theme_stylebox_override("hover", StencilStyle.chip())
		chip.add_theme_stylebox_override("pressed", StencilStyle.chip())
		chip.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		chip.add_theme_color_override("font_color", StencilStyle.TEXT_DIM)
		chip.add_theme_color_override("font_hover_color", StencilStyle.ORANGE)
		chip.add_theme_font_size_override("font_size", _scaled_font(15))
		chip.add_theme_font_override("font", StencilStyle.tracking_font(1))
		chip.pressed.connect(_on_forge_chip.bind(ctext))
		chips.add_child(chip)

	_forge_feed = RichTextLabel.new()
	_forge_feed.bbcode_enabled = true
	_forge_feed.scroll_following = true
	_forge_feed.custom_minimum_size = Vector2(0, 220)
	_forge_feed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_forge_feed.add_theme_font_size_override("normal_font_size", _scaled_font(17))
	_forge_feed.add_theme_color_override("default_color", StencilStyle.TEXT)
	_forge_feed.add_theme_stylebox_override("normal", StencilStyle.panel(Color(0.02, 0.025, 0.03, 0.95), StencilStyle.GUNMETAL, 1))
	vb.add_child(_forge_feed)
	_push_forge_entry("Forge online. Describe cover, turrets, traps.", true)


func _build_touch_hints() -> void:
	# v0.5.1 FIX 2: the persistent hint line is REMOVED. It overlapped the
	# killstreak cards and never went away. First-time hints live in the
	# touch layer (touch_controls.gd), which shows them briefly then fades
	# them. This node is kept (hidden, empty) only so _touch_hints stays a
	# valid reference; it is never shown.
	_touch_hints = Label.new()
	_touch_hints.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_touch_hints.offset_left = -400
	_touch_hints.offset_right = 400
	_touch_hints.offset_top = -160
	_touch_hints.offset_bottom = -120
	_touch_hints.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_hud_body(_touch_hints, _scaled_font(18), StencilStyle.TEXT_DIM, 2)
	_touch_hints.text = ""
	_touch_hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_touch_hints.visible = false
	_full().add_child(_touch_hints)


func _build_pause_button() -> void:
	_pause_btn = Button.new()
	_pause_btn.text = "II"
	_pause_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_pause_btn.offset_left = -68
	_pause_btn.offset_top = 16
	_pause_btn.offset_right = -20
	_pause_btn.offset_bottom = 64
	StencilStyle.style_button(_pause_btn)
	_pause_btn.pressed.connect(_on_pause_pressed)
	_full().add_child(_pause_btn)


# ------------------------------------------------------------------ wiring ---
func _game_get(varname: String, fallback: Variant) -> Variant:
	# Defensive: autoload vars may not exist yet if worker 1 hasn't landed.
	var g := get_node_or_null("/root/Game")
	if g == null:
		return fallback
	var v: Variant = g.get(varname)
	return fallback if v == null else v


func _wire_game() -> void:
	var g := get_node_or_null("/root/Game")
	if g != null:
		_connect_safe(g, "wave_started", _on_wave_started)
		_connect_safe(g, "wave_cleared", _on_wave_cleared)
		_connect_safe(g, "build_phase_started", _on_build_phase)
		_connect_safe(g, "enemy_killed", _on_enemy_killed)
		_connect_safe(g, "player_died", _on_player_died)
		_connect_safe(g, "killstreak_ready", _on_killstreak_ready)
		_connect_safe(g, "killstreak_used", _on_killstreak_used)
		_connect_safe(g, "forge_budget_changed", _on_budget_changed)
	var f := get_node_or_null("/root/Forge")
	if f != null:
		_connect_safe(f, "forge_result", _on_forge_result)


func _connect_safe(obj: Object, sig: String, fn: Callable) -> void:
	if obj.has_signal(sig) and not obj.is_connected(sig, fn):
		obj.connect(sig, fn)


# ------------------------------------------------------------ UAV contract
# Killstreaks object lookup: Forge child named "Killstreaks" first, then the
# "killstreaks" group. Everything guarded — a missing object, missing
# signals, or a missing get_uav_targets() simply means "no UAV display".
func _bind_uav() -> void:
	if _killstreaks_obj != null and is_instance_valid(_killstreaks_obj):
		return
	_killstreaks_obj = null
	var obj: Object = null
	var forge := get_node_or_null("/root/Forge")
	if forge != null:
		obj = forge.get_node_or_null("Killstreaks")
	if obj == null:
		obj = get_tree().get_first_node_in_group("killstreaks")
	if obj == null:
		return
	_killstreaks_obj = obj
	_connect_safe(obj, "uav_started", _on_uav_started)
	_connect_safe(obj, "uav_ended", _on_uav_ended)


func _on_uav_started(duration: float) -> void:
	_uav_active = true
	_uav_remaining = maxf(0.0, duration)
	_uav_refresh_t = 0.0
	# v0.6.1: never re-show over the Forge menu; restore re-syncs.
	if _map_frame != null and not _hud_hidden:
		_map_frame.visible = true
	if _uav_label != null and not _hud_hidden:
		_uav_label.visible = true
		_uav_label.text = "UAV ACTIVE  %d" % ceili(_uav_remaining)


func _on_uav_ended() -> void:
	_uav_active = false
	_uav_remaining = 0.0
	_uav_targets_cache.clear()
	# v0.6.1: visibility writes stay suppressed while the menu is open;
	# the stored prev-visibility restores the correct state on close.
	if _map_frame != null and not _hud_hidden:
		_map_frame.visible = false
	if _uav_label != null and not _hud_hidden:
		_uav_label.visible = false


func set_uav(duration: float) -> void:
	# Legacy entry point: the current Killstreaks implementation calls
	# hud.set_uav(duration) when the UAV fires (no signals yet). Same state
	# as the uav_started signal so both paths render identically.
	_on_uav_started(duration)


func _fetch_uav_targets() -> void:
	var obj := _killstreaks_obj
	if obj == null or not is_instance_valid(obj):
		return
	if not obj.has_method("get_uav_targets"):
		return
	var res: Variant = obj.call("get_uav_targets")
	if res is Array:
		_uav_targets_cache = res


func _update_uav(delta: float) -> void:
	if _killstreaks_obj == null or not is_instance_valid(_killstreaks_obj):
		_killstreaks_obj = null
		_uav_bind_t -= delta
		if _uav_bind_t <= 0.0:
			_uav_bind_t = UAV_BIND_RETRY
			_bind_uav()
	elif _uav_active:
		_uav_refresh_t -= delta
		if _uav_refresh_t <= 0.0:
			_uav_refresh_t = UAV_REFRESH
			_fetch_uav_targets()
	if _uav_active:
		_uav_remaining -= delta
		if _uav_remaining <= 0.0:
			_on_uav_ended()
		elif _uav_label != null:
			_uav_label.text = "UAV ACTIVE  %d" % ceili(_uav_remaining)
	# v0.5.1 FIX 2: keep the minimap frame in sync with UAV state even if
	# a start/end signal was missed (e.g. HUD built after the streak fired).
	# v0.6.1: suppressed while the Forge menu is open.
	if _map_frame != null and not _hud_hidden:
		_map_frame.visible = _uav_active


func _bind_player_deferred() -> void:
	# Player may spawn after the HUD. Retry cheaply until bound.
	_try_bind_player()


func _try_bind_player() -> bool:
	var p := get_tree().get_first_node_in_group("player")
	if p == null:
		return false
	_player_node = p as Node3D
	_connect_safe(p, "health_changed", _on_health_changed)
	_connect_safe(p, "damaged", _on_damaged)
	_connect_safe(p, "died", _on_died)
	_connect_safe(p, "ads_changed", _on_ads_changed)
	_connect_safe(p, "ammo_changed", _on_ammo_changed)
	_connect_safe(p, "weapon_changed", _on_weapon_changed)
	# Goal 5: portal crosshair verdict (tint + pair pips) from the emitter.
	var emitter = p.get("portal_emitter")
	if emitter != null:
		_connect_safe(emitter, "aim_state_changed", _on_portal_aim_state)
	# Weapon manager might be its own node (contract doesn't pin a group).
	var wm := get_tree().get_first_node_in_group("weapon_manager")
	if wm != null and wm != p:
		_connect_safe(wm, "ammo_changed", _on_ammo_changed)
		_connect_safe(wm, "weapon_changed", _on_weapon_changed)
	return true


# ------------------------------------------------------- CONTRACT: hitmarker
func show_hitmarker(kill: bool, headshot: bool) -> void:
	var root := _hit_root()
	if root == null:
		return
	# Distinct variants: hit = white 1.0x, headshot = gold 1.25x,
	# kill = red 1.45x + center dot. Scaling pivots on screen center so the
	# marker stays centered. Fade-out handled in _process.
	var kind := "hit"
	if kill:
		kind = "kill"
	elif headshot:
		kind = "headshot"
	_hit_base_color = StencilStyle.hitmarker_color(kind)
	var scale := 1.0
	if kind == "headshot":
		scale = 1.25
	elif kind == "kill":
		scale = 1.45
	root.pivot_offset = get_viewport().get_visible_rect().size * 0.5
	root.scale = Vector2(scale, scale)
	# Goal 1: punch overshoot — armed here, applied next frame in _process
	# (so the settled scale above is what a synchronous read sees).
	_hit_base_scale = scale
	_hit_punch = HIT_PUNCH_KILL if kind == "kill" else (HIT_PUNCH_HEADSHOT if kind == "headshot" else HIT_PUNCH_HIT)
	_hit_punch_t = HIT_PUNCH_TIME
	for r in _hit_lines:
		r.color = _hit_base_color
	if _hit_dot != null:
		_hit_dot.visible = kill
		_hit_dot.color = _hit_base_color
	# v0.6.1: no hitmarker over the Forge menu (transient; skipped, not queued).
	if not _hud_hidden:
		root.visible = true
	_hit_t = HITMARKER_TIME
	# Goal 1: one tick per hit, deduped. The kill path calls this twice
	# in one frame (weapon hit + Game enemy_killed) and a shotgun's 8
	# pellets call it 8x — without the gap those stack into a buzz.
	# Full-auto (700rpm = 86ms, 850rpm = 70ms) still ticks every shot.
	if _hit_snd_t <= 0.0:
		_hit_snd_t = HIT_SOUND_MIN_GAP
		if kill or headshot:
			_play(SFX_KILL)
		else:
			_play(SFX_HIT)


# --------------------------------------------------------- CONTRACT: killfeed
func add_killfeed(text: String) -> void:
	var l := _kf_labels[_kf_next]
	l.text = text.to_upper()
	l.modulate.a = 1.0
	_kf_age[_kf_next] = 0.0
	_kf_next = (_kf_next + 1) % KILLFEED_POOL


# ---------------------------------------------------------- CONTRACT: banner
func announce(title: String, subtitle: String) -> void:
	_banner_title.text = title.to_upper()
	_banner_sub.text = subtitle.to_upper()
	# Juggernaut (and KIA) banners go red — keyword check keeps the frozen
	# two-arg signature while letting other workers flag danger.
	var danger := title.to_upper().find("JUGGERNAUT") >= 0 or title.to_upper() == "K.I.A."
	_banner_title.add_theme_color_override("font_color", StencilStyle.RED if danger else StencilStyle.TEXT)
	if _banner_tw != null and _banner_tw.is_valid():
		_banner_tw.kill()
	_banner.modulate.a = 0.0
	_banner.position.y = BANNER_TOP - 28.0
	_banner_tw = create_tween()
	_banner_tw.set_parallel(true)
	_banner_tw.tween_property(_banner, "modulate:a", 1.0, BANNER_SLIDE)
	_banner_tw.tween_property(_banner, "position:y", BANNER_TOP, BANNER_SLIDE).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_banner_tw.set_parallel(false)
	_banner_tw.tween_interval(BANNER_HOLD)
	_banner_tw.tween_property(_banner, "modulate:a", 0.0, 0.5)


# ------------------------------------------------------------ CONTRACT: pips
func set_killstreak_pips(unlocked: Array) -> void:
	for i in 3:
		var on := i < unlocked.size() and bool(unlocked[i])
		_pip_unlocked[i] = on
		_style_pip(i, on)


# ---------------------------------------------------- CONTRACT: damage flash
func damage_flash(direction: Vector3) -> void:
	# direction: world-space vector TOWARD the damage source.
	# Smooth two-stage vignette: quick ramp-in (no harsh pop) then a long
	# eased fade-out. Tweens start from the current alpha, so overlapping
	# hits blend instead of snapping.
	if _vignette_tw != null and _vignette_tw.is_valid():
		_vignette_tw.kill()
	_vignette_tw = create_tween()
	_vignette_tw.tween_property(_vignette, "color:a", DAMAGE_VIGNETTE_MAX, DAMAGE_VIGNETTE_IN).set_ease(Tween.EASE_OUT)
	_vignette_tw.tween_property(_vignette, "color:a", 0.0, DAMAGE_VIGNETTE_OUT).set_ease(Tween.EASE_OUT)
	# Directional arc: project source direction into screen space, rotate via
	# the shortest arc (no full spins on wrap-around), same smooth envelope.
	if _player_node != null and _player_node.is_inside_tree():
		var src := direction
		src.y = 0.0
		if src.length_squared() > 0.001:
			src = src.normalized()
			var basis_t := _player_node.global_transform.basis
			var fwd := -basis_t.z
			fwd.y = 0.0
			fwd = fwd.normalized()
			var right := basis_t.x
			right.y = 0.0
			right = right.normalized()
			var ang := atan2(src.dot(right), src.dot(fwd))
			var center := get_viewport().get_visible_rect().size * 0.5
			var radius := 190.0
			_tmp_v2 = Vector2(sin(ang), -cos(ang)) * radius
			_dir_ind.position = center + _tmp_v2 - Vector2(60, 11)
			var target_rot := _dir_ind.rotation + wrapf(ang - _dir_ind.rotation, -PI, PI)
			if _dir_tw != null and _dir_tw.is_valid():
				_dir_tw.kill()
			_dir_tw = create_tween()
			_dir_tw.set_parallel(true)
			_dir_tw.tween_property(_dir_ind, "rotation", target_rot, 0.12).set_ease(Tween.EASE_OUT)
			_dir_tw.tween_property(_dir_ind, "color:a", 0.95, DIR_IND_IN).set_ease(Tween.EASE_OUT)
			_dir_tw.set_parallel(false)
			_dir_tw.tween_property(_dir_ind, "color:a", 0.0, DIR_IND_OUT).set_ease(Tween.EASE_OUT)


# ----------------------------------------------------- CONTRACT: spread/touch
func set_spread(px: float) -> void:
	_spread = px
	_layout_crosshair()


func set_touch_mode(on: bool) -> void:
	_touch_mode = on
	# v0.5.1 FIX 2: the persistent hint line is gone — never show it, even
	# on touch. First-time hints are owned by the touch layer (brief + fade).
	if _touch_hints != null:
		_touch_hints.visible = false
	# v0.5.1 FIX 2: on touch, the touch layer owns the top-right pause
	# button; hide the HUD's duplicate so the two never stack.
	# v0.6.1: never re-show over the Forge menu.
	if _pause_btn != null and not _hud_hidden:
		_pause_btn.visible = not on
	# Desktop key hints ([4]/[5]/[6]) become plain READY/LOCKED on touch.
	for i in 3:
		_refresh_pip_status(i)


# -------------------------------------------------------------- game signals
func _on_wave_started(n: int) -> void:
	_play(SFX_WAVE)
	announce("WAVE %d" % n, "HOSTILES INBOUND")
	refresh_topbar()


func _on_wave_cleared(n: int) -> void:
	announce("WAVE %d CLEARED" % n, "HOSTILES DOWN — CATCH YOUR BREATH")
	refresh_topbar()


func _on_build_phase(seconds: int) -> void:
	_play(SFX_BUILD)
	announce("BUILD PHASE", "Forge console open")
	_open_forge(true)
	refresh_topbar()


func _on_enemy_killed(points: int, headshot: bool, victim_name: String) -> void:
	show_hitmarker(true, headshot)
	var tag := " [HEADSHOT]" if headshot else ""
	add_killfeed("YOU ▸ %s%s  +%d" % [victim_name.to_upper(), tag, points])
	refresh_topbar()


func _on_player_died() -> void:
	_dead = true
	_update_crosshair_visibility()
	announce("K.I.A.", "REDEPLOYING...")


func _on_killstreak_ready(index: int) -> void:
	_play(SFX_STREAK)
	if index >= 0 and index < 3:
		_pip_unlocked[index] = true
		_style_pip(index, true)
		_pip_flash[index] = 1.6


func _on_killstreak_used(index: int) -> void:
	if index >= 0 and index < 3:
		_pip_unlocked[index] = false
		_style_pip(index, false)


func _on_budget_changed(amount: int) -> void:
	_update_forge_budget(amount)
	refresh_topbar()


func refresh_topbar() -> void:
	var wave: int = int(_game_get("wave", 0))
	var score: int = int(_game_get("score", 0))
	# Budget display removed (directive A: budget OFF — building is
	# free). The topbar shows wave + score only; the budget value still
	# exists in game state for a future re-enable.
	_topbar.text = "WAVE %d   —   SCORE %d" % [wave, score]


# ------------------------------------------------------------ player signals
func _on_health_changed(hp: float, max_hp: float) -> void:
	_hp = hp
	_max_hp = maxf(1.0, max_hp)
	_update_health_display()
	if hp > 0.0 and _dead:
		_dead = false
		_update_crosshair_visibility()


func _on_damaged(direction: Vector3) -> void:
	damage_flash(direction)


func _on_died() -> void:
	_on_player_died()


func _on_ads_changed(active: bool) -> void:
	_ads = active
	_update_crosshair_visibility()


func _update_crosshair_visibility() -> void:
	# v0.6.1: stays hidden while the Forge menu is open.
	if not _hud_hidden:
		_crosshair.visible = not _ads and not _dead


# Goal 5: portal crosshair verdict from PortalEmitter.aim_state_changed.
# Tint: valid = white, invalid surface = red, out of range = amber,
# no target = white. Pips show which portal discs are live.
func _on_portal_aim_state(state: Dictionary) -> void:
	if _crosshair == null:
		return
	var tint := Color(1, 1, 1, 0.95)
	match str(state.get("aim", "no_target")):
		"invalid":
			tint = Color(1.0, 0.2, 0.2, 0.95)
		"out_of_range":
			tint = Color(1.0, 0.75, 0.2, 0.95)
	for line in _ch_lines:
		line.color = tint
	if _ch_dot != null:
		_ch_dot.color = tint
	if _portal_pip_blue != null:
		_portal_pip_blue.visible = bool(state.get("blue_active", false))
	if _portal_pip_orange != null:
		_portal_pip_orange.visible = bool(state.get("orange_active", false))


func _on_ammo_changed(mag: int, reserve: int) -> void:
	_ammo_label.text = "%d | %d" % [mag, reserve]
	# v0.6.1: RELOAD label stays hidden over the Forge menu.
	if _hud_hidden:
		return
	if mag == 0:
		_ammo_label.add_theme_color_override("font_color", StencilStyle.RED)
		_reload_label.visible = true
		_reload_t = 0.0
	elif mag <= LOW_MAG_RED:
		_ammo_label.add_theme_color_override("font_color", StencilStyle.RED)
		_reload_label.visible = false
	else:
		_ammo_label.add_theme_color_override("font_color", StencilStyle.TEXT)
		_reload_label.visible = false


func _on_weapon_changed(wname: String) -> void:
	_weapon_label.text = wname.to_upper()


# ------------------------------------------------------------------ process
func _process(delta: float) -> void:
	# Mouse capture state machine (Windows port): re-sync every frame so
	# no transition can leave the mode stuck (see _sync_mouse_mode).
	_sync_mouse_mode()
	# Bind player lazily (allocation-free after first bind).
	if _player_node == null or not is_instance_valid(_player_node):
		_player_node = null
		_try_bind_player()

	# Hitmarker lifetime: full-strength hold, then a short fade (no pop-off).
	if _hit_snd_t > 0.0:
		_hit_snd_t -= delta
	# Goal 1: punch overshoot — scale swells past the settled value then
	# eases back to it over HIT_PUNCH_TIME, then stays settled for the fade.
	if _hit_punch_t > 0.0:
		_hit_punch_t -= delta
		var proot := _hit_root()
		if proot != null:
			if _hit_punch_t <= 0.0:
				proot.scale = Vector2(_hit_base_scale, _hit_base_scale)
			else:
				var k := clampf(_hit_punch_t / HIT_PUNCH_TIME, 0.0, 1.0)
				proot.scale = Vector2(_hit_base_scale, _hit_base_scale) * (1.0 + _hit_punch * k)
	if _hit_t > 0.0:
		_hit_t -= delta
		if _hit_t <= 0.0:
			var root := _hit_root()
			if root != null:
				root.visible = false
		elif _hit_t < HITMARKER_FADE:
			var a := clampf(_hit_t / HITMARKER_FADE, 0.0, 1.0)
			var c := _hit_base_color
			c.a = _hit_base_color.a * a
			for r in _hit_lines:
				r.color = c
			if _hit_dot != null:
				_hit_dot.color = c

	# RELOAD blink.
	if _reload_label.visible:
		_reload_t += delta
		_reload_label.modulate.a = 0.35 + 0.65 * absf(sin(_reload_t * 6.0))

	# Killfeed fades.
	for i in KILLFEED_POOL:
		if _kf_age[i] < 900.0:
			_kf_age[i] += delta
			var a := _kf_age[i]
			if a > KILLFEED_FADE_AFTER:
				var k := 1.0 - (a - KILLFEED_FADE_AFTER) / KILLFEED_FADE_TIME
				_kf_labels[i].modulate.a = clampf(k, 0.0, 1.0)

	# Pip ready-flash.
	for i in 3:
		if _pip_flash[i] > 0.0:
			_pip_flash[i] -= delta
			_pips[i].modulate.a = 0.45 + 0.55 * absf(sin(_pip_flash[i] * 14.0))
			if _pip_flash[i] <= 0.0:
				_pips[i].modulate.a = 1.0

	# Low-HP heartbeat + vignette pulse.
	var low := _hp > 0.0 and _hp / _max_hp < LOW_HP_FRAC
	if low:
		_lowhp_phase += delta
		_lowhp.color.a = 0.22 + 0.14 * sin(_lowhp_phase * 5.0)
		_heartbeat_t -= delta
		if _heartbeat_t <= 0.0:
			_heartbeat_t = HEARTBEAT_INTERVAL
			_play(SFX_HEARTBEAT)
	elif _lowhp.color.a > 0.0:
		_lowhp.color.a = 0.0

	# Forge toggle action (worker 1 defines "forge_console"; button always works).
	if _forge_action and Input.is_action_just_pressed("forge_console"):
		_toggle_forge()
	# v0.6.1: catch Forge UI closes the HUD didn't initiate (the menu's
	# own X button calls menu.close() directly). If the UI is gone but
	# the HUD is still hidden, restore everything and re-sync the toggle.
	if _hud_hidden and not _forge_ui_open():
		_forge_open = false
		_set_hud_hidden(false)

	_update_uav(delta)
	_update_minimap(delta)


func _update_minimap(delta: float) -> void:
	if _player_node == null or not _player_node.is_inside_tree():
		return
	var pp := _player_node.global_position
	_map_root.global_position = Vector3(pp.x, 0.0, pp.z)
	_player_blip.position = Vector3.ZERO
	_player_blip.rotation.y = _player_node.global_rotation.y
	_player_blip.visible = true
	# Refresh the enemy list on an interval (get_nodes_in_group allocs).
	_enemy_refresh_t -= delta
	if _enemy_refresh_t <= 0.0:
		_enemy_refresh_t = ENEMY_LIST_REFRESH
		_enemies_cache = get_tree().get_nodes_in_group("enemies")
	var used := 0
	# UAV active + targets available: draw the contract-provided blips
	# (orange, clamped to the minimap edge) instead of the group scan.
	if _uav_active and _uav_targets_cache.size() > 0:
		for pos in _uav_targets_cache:
			if used >= MINIMAP_ENEMY_POOL:
				break
			if not (pos is Vector3):
				continue
			_tmp_v3 = (pos as Vector3) - pp
			_tmp_v3.y = 0.0
			var d := _tmp_v3.length()
			if d > MINIMAP_RANGE:
				_tmp_v3 = _tmp_v3 * (MINIMAP_RANGE * 0.95 / d)
			var b := _enemy_blips[used]
			b.position = _tmp_v3
			b.visible = true
			var m := b.material_override as StandardMaterial3D
			if m != null:
				m.albedo_color = StencilStyle.ORANGE
			used += 1
	else:
		for e in _enemies_cache:
			if used >= MINIMAP_ENEMY_POOL:
				break
			var n := e as Node3D
			if n == null or not is_instance_valid(n):
				continue
			_tmp_v3 = n.global_position - pp
			_tmp_v3.y = 0.0
			if _tmp_v3.length() > MINIMAP_RANGE:
				continue
			var b := _enemy_blips[used]
			b.position = _tmp_v3
			b.visible = true
			var m := b.material_override as StandardMaterial3D
			if m != null:
				m.albedo_color = Color(0.9, 0.15, 0.12, 1.0)
			used += 1
	for i in range(used, MINIMAP_ENEMY_POOL):
		_enemy_blips[i].visible = false


# ------------------------------------------------------------------- forge
# v0.6.1 helpers: resolution scaling + Forge-menu HUD hiding.
func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func _scaled_font(base: float) -> int:
	return UiScale.scaled_font(base, _viewport_size())


func _scaled_size(base: float) -> float:
	return UiScale.scaled_size(base, _viewport_size())


# v0.6.1: re-apply resolution-scaled fonts/sizes after a viewport resize
# (rotation, window resize). Same base sizes as the _build_* functions.
# Build-time only (not re-applied here): minimap frame/SubViewport (would
# need a viewport rebuild), banner/crosshair geometry, and the legacy
# Forge panel's local labels (title/chips).
func _apply_ui_scale() -> void:
	if _weapon_label == null:
		return
	_health_bar_w = _scaled_size(HEALTH_BAR_W)
	if _hp_bar != null:
		_hp_bar.custom_minimum_size = Vector2(_health_bar_w, 16)
	StencilStyle.apply_hud_body(_weapon_label, _scaled_font(26), StencilStyle.TEXT_DIM, 3)
	StencilStyle.apply_hud_body(_ammo_caption, _scaled_font(20), StencilStyle.TEXT_DIM, 3)
	StencilStyle.apply_title(_ammo_label, _scaled_font(56), StencilStyle.TEXT, 3)
	StencilStyle.apply_title(_reload_label, _scaled_font(30), StencilStyle.ORANGE, 4)
	StencilStyle.apply_hud_body(_hp_caption, _scaled_font(20), StencilStyle.TEXT_DIM, 3)
	StencilStyle.apply_title(_hp_label, _scaled_font(40), StencilStyle.TEXT, 3)
	for l in _kf_labels:
		StencilStyle.apply_hud_body(l, _scaled_font(22), StencilStyle.TEXT, 2)
	StencilStyle.apply_title(_banner_title, _scaled_font(64), StencilStyle.TEXT, 6)
	StencilStyle.apply_hud_body(_banner_sub, _scaled_font(28), StencilStyle.ORANGE, 4)
	for i in 3:
		_pips[i].custom_minimum_size = Vector2(_scaled_size(128), _scaled_size(104))
		StencilStyle.apply_hud_body(_pip_icons[i], _scaled_font(32), StencilStyle.TEXT_DIM, 0)
		StencilStyle.apply_hud_body(_pip_names[i], _scaled_font(20), StencilStyle.TEXT_DIM, 2)
		StencilStyle.apply_hud_body(_pip_keys[i], _scaled_font(20), StencilStyle.TEXT_DIM, 2)
		_style_pip(i, _pip_unlocked[i])
	StencilStyle.apply_hud_body(_topbar, _scaled_font(26), StencilStyle.TEXT, 3)
	StencilStyle.apply_hud_body(_uav_label, _scaled_font(24), StencilStyle.ORANGE, 3)
	if _forge_budget_label != null:
		StencilStyle.apply_hud_body(_forge_budget_label, _scaled_font(20), StencilStyle.TEXT, 2)
	if _forge_feed != null:
		_forge_feed.add_theme_font_size_override("normal_font_size", _scaled_font(17))
	StencilStyle.apply_hud_body(_touch_hints, _scaled_font(18), StencilStyle.TEXT_DIM, 2)
	_update_health_display()


# All HUD nodes that can overlap the Forge menu. The legacy fallback panel
# (_forge_panel) is deliberately NOT here — it IS the Forge UI when the
# full menu scene is absent. Touch buttons live in the touch layer and are
# hidden via group "touch_controls" -> set_menu_open().
func _hud_hide_nodes() -> Array[Control]:
	var nodes: Array[Control] = []
	for n in [_crosshair, _hit_root(), _weapon_label, _ammo_caption,
			_ammo_label, _reload_label, _hp_caption, _hp_label,
			_hp_bar_bg, _hp_bar_fill, _vignette, _lowhp, _dir_ind,
			_killfeed_box, _banner, _topbar, _map_frame, _uav_label,
			_forge_btn, _pause_btn, _touch_hints]:
		if n != null:
			nodes.append(n)
	for p in _pips:
		if p != null:
			nodes.append(p)
	return nodes


func _set_hud_hidden(hidden: bool) -> void:
	if hidden == _hud_hidden:
		return
	_hud_hidden = hidden
	if hidden:
		_hud_hidden_prev.clear()
		for n in _hud_hide_nodes():
			_hud_hidden_prev[n] = n.visible
			n.visible = false
	else:
		for n in _hud_hide_nodes():
			if _hud_hidden_prev.has(n):
				n.visible = bool(_hud_hidden_prev[n])
		_hud_hidden_prev.clear()
	# Touch layer (FORGE/MIC/K1-K3/FIRE/ADS/JUMP/HOOK/RLD/CRCH + hints).
	# No-op on desktop where the layer never joined the group.
	get_tree().call_group("touch_controls", "set_menu_open", hidden)


# Is any Forge UI currently open? Prefers the full menu scene when it
# exists; otherwise the legacy fallback panel. Used by the _process poll
# that catches menu closes the HUD didn't initiate (e.g. the menu's own
# X button calls menu.close() directly — forge_menu.gd has no close
# signal, so polling is the only way to observe it).
func _forge_ui_open() -> bool:
	var menus := get_tree().get_nodes_in_group("forge_menu")
	if not menus.is_empty() and is_instance_valid(menus[0]):
		var m := menus[0] as Control
		if m != null:
			return m.visible
	# No Forge panel in this mode (see _build_forge) -> nothing open.
	if _forge_panel == null:
		return false
	return _forge_panel.visible


func _toggle_forge() -> void:
	# No Forge button in this mode (see _build_forge) -> no-op, never
	# a null deref from the forge_console action or the touch layer.
	if _forge_btn == null:
		return
	_play(SFX_UI)
	# v0.5.1: never auto-focus the prompt — grabbing focus pops the phone
	# keyboard on open. The keyboard appears ONLY when the user taps the
	# LineEdit itself.
	_open_forge(not _forge_open, false)


func _open_forge(open: bool, focus_input: bool = false) -> void:
	# Forge gate (Gameplay Rework): building exists ONLY in Tower
	# Defense. Refuse + announce instead of opening (the menu's own
	# open() and the ForgeManager pipeline enforce the same gate).
	if open and not ForgeGate.can_build():
		_forge_open = false
		announce("FORGE LOCKED", ForgeGate.BLOCK_MESSAGE.to_upper())
		return
	# No Forge panel in this mode (see _build_forge) -> refuse quietly
	# (close path with nothing built must not null-deref below).
	if _forge_panel == null:
		return
	_forge_open = open
	# Windows mouse capture: menu open -> VISIBLE + erase mouse bindings
	# (menu clicks can't fire); menu closed -> re-capture + restore
	# (the watchdog corrects this back to VISIBLE if pause is open, and
	# _sync restores only when no menu is open). The Forge menu's own
	# open()/close() do the same, so the X-button path is covered even
	# if this call is bypassed.
	if open:
		MouseCapture.set_menu()
		MouseCapture.erase_mouse_bindings()
	else:
		MouseCapture.set_gameplay()
		if not _pause_open():
			MouseCapture.restore_mouse_bindings()
	# v0.6.1: hide every overlapping HUD element (and the touch layer)
	# while any Forge UI is open; restore on close. Pausing untouched.
	_set_hud_hidden(open)
	# v0.5: prefer the full Forge menu (B1) when the coordinator instanced
	# it; the legacy inline panel below is the fallback if the menu scene
	# failed to load. The menu manages its own focus (never grabs it).
	var menus := get_tree().get_nodes_in_group("forge_menu")
	if not menus.is_empty() and menus[0].has_method("open") and menus[0].has_method("close"):
		if open:
			menus[0].call("open")
		else:
			menus[0].call("close")
		_forge_panel.visible = false
		return
	_forge_panel.visible = open
	if open:
		_update_forge_budget(int(_game_get("forge_budget", 0)))
		# v0.5.1: never auto-focus. Grabbing focus would route WASD into the
		# LineEdit and pop the phone keyboard. The keyboard appears ONLY
		# when the user taps the LineEdit itself. focus_input is kept as a
		# parameter for API compatibility but is intentionally ignored.
		if focus_input:
			_forge_input.grab_focus()


func _on_forge_chip(text: String) -> void:
	_forge_input.text = text
	# v0.5.1: no grab_focus() — chips fill the prompt but the keyboard
	# appears only when the user taps the LineEdit itself.
	_forge_input.set_caret_column(text.length())


func _on_forge_submitted(text: String) -> void:
	var prompt := text.strip_edges()
	if prompt.is_empty():
		return
	var f := get_node_or_null("/root/Forge")
	if f != null and f.has_method("submit_prompt"):
		_play(SFX_SUBMIT)
		_push_forge_entry("[SENT] " + prompt, true)
		f.submit_prompt(prompt)
	else:
		_push_forge_entry("[FAIL] Forge system offline.", false)
	_forge_input.clear()


func _on_forge_result(success: bool, message: String) -> void:
	_play(SFX_RESULT_OK if success else SFX_RESULT_FAIL)
	_push_forge_entry(("[OK] " if success else "[FAIL] ") + message, success)


func _push_forge_entry(entry: String, ok: bool) -> void:
	_forge_entries.append(entry)
	while _forge_entries.size() > 8:
		_forge_entries.pop_front()
	_forge_feed.clear()
	for e in _forge_entries:
		var col := "e8e9ea"
		if e.begins_with("[SENT]"):
			col = "ffb066"
		elif e.begins_with("[OK]"):
			col = "7dff8a"
		elif e.begins_with("[FAIL]"):
			col = "ff6b5e"
		_forge_feed.append_text("[color=#%s]%s[/color]\n" % [col, e.xml_escape()])


func _update_forge_budget(amount: int) -> void:
	if _forge_budget_label != null:
		_forge_budget_label.text = "BUDGET: %d" % amount


# ------------------------------------------------------------------- misc
func _on_pause_pressed() -> void:
	_play(SFX_UI)
	# Route through Main (group "game_root") — it owns the PLAYING/PAUSED
	# state machine and instantiates/frees the pause menu. The old code
	# toggled a pause_menu node that does not exist until Main creates it,
	# so the button did nothing on first press and never synced Main.state.
	var root := get_tree().get_first_node_in_group("game_root")
	if root != null and root.has_method("toggle_pause"):
		root.call("toggle_pause")
	else:
		var pm := get_tree().get_first_node_in_group("pause_menu")
		if pm != null and pm.has_method("toggle_pause"):
			pm.call("toggle_pause")
	# Main instantiates the pause menu invisible (pause_menu._ready hides
	# it and Main never shows it) — show it now. The ALWAYS watchdog also
	# enforces this for the ESC path, where this button is not involved.
	_sync_pause_menu_visibility()
	_sync_mouse_mode()


func _play(id: String, vol_db: float = 0.0) -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d(id, vol_db)


func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		_forge_action = InputMap.has_action("forge_console")
	# Window focus backup: the Window signals (connected in
	# _init_mouse_capture) are primary; these notifications cover the
	# case where the connection was missed. Both call the same handlers.
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_on_window_focus_in()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_on_window_focus_out()


func _exit_tree() -> void:
	# HUD is freed on quit-to-menu / scene reload: never leave the cursor
	# captured or the mouse bindings erased in the main menu (no HUD
	# exists there to restore them).
	MouseCapture.set_menu()
	MouseCapture.restore_mouse_bindings()


# ------------------------------------------------------- mouse capture ----
# Windows port (Worker A). The mode decision lives ONLY in
# _sync_mouse_mode(), fed by three facts: window focus, pause state, Forge
# state. Every transition in the game funnels through it:
#   game start (HUD._ready) -> CAPTURED (no menu open)
#   Forge open/close (HUD._open_forge + forge_menu.open/close, incl. X)
#       -> VISIBLE / CAPTURED
#   pause open/close (ESC via Main/pause_menu, HUD button, touch button)
#       -> VISIBLE / CAPTURED (watchdog covers the paused frames)
#   focus-out (alt-tab) -> VISIBLE; focus-in -> CAPTURED + suppression
#   ESC gameplay -> Main opens pause -> VISIBLE (watchdog, tree paused)
#   ESC in pause -> pause_menu resumes -> CAPTURED (poll, tree running)
# ESC never quits: pause_menu._input toggles pause on ui_cancel, and Main
# only toggles pause on the "pause" action — neither path calls quit.
func _init_mouse_capture() -> void:
	# Safety: a previous run (hot reload, scene reload) must not leave
	# the mouse bindings erased in a fresh game.
	MouseCapture.restore_mouse_bindings()
	# Watchdog: PROCESS_MODE_ALWAYS child so the mode still syncs while
	# the tree is paused (HUD._process itself freezes under pause).
	if _mouse_watchdog == null:
		var w := _MouseWatchdog.new()
		w._hud = self
		w.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(w)
		_mouse_watchdog = w
	var win := get_window()
	if win != null:
		if not win.focus_entered.is_connected(_on_window_focus_in):
			win.focus_entered.connect(_on_window_focus_in)
		if not win.focus_exited.is_connected(_on_window_focus_out):
			win.focus_exited.connect(_on_window_focus_out)
	_sync_mouse_mode()


## Single decision point for the mouse mode + mouse bindings. Idempotent:
## MouseCapture early-returns / no-ops when already in the requested
## state, so calling this every frame (and from the watchdog while
## paused) is cheap.
##   menu open / focus lost -> VISIBLE + bindings erased (menu clicks
##     and the refocus click cannot fire).
##   gameplay -> CAPTURED + bindings restored, EXCEPT while
##     _focus_click_pending: restoring on focus-in itself would let the
##     refocus click fire — the press restores via _input instead. This
##     branch also covers keyboard-closed menus (pending already false).
func _sync_mouse_mode() -> void:
	# The pause menu is ALSO forced visible here (watchdog path): Main
	# instantiates it invisible, so without this ESC-pause would freeze
	# the game with no pause UI to click.
	_sync_pause_menu_visibility()
	if _focus_lost or _pause_open() or _forge_open_or_ui():
		MouseCapture.set_menu()
		MouseCapture.erase_mouse_bindings()
	else:
		MouseCapture.set_gameplay()
		if not _focus_click_pending:
			MouseCapture.restore_mouse_bindings()


func _pause_open() -> bool:
	if get_tree().paused:
		return true
	var pm := get_tree().get_first_node_in_group("pause_menu")
	if pm is Control:
		return (pm as Control).visible
	return false


func _forge_open_or_ui() -> bool:
	return _forge_open or _forge_ui_open()


## Main instantiates the pause menu invisible (pause_menu._ready hides it
## and Main never shows it). While the tree is paused and a pause menu
## exists, force it visible so the player gets a Resume button. Never
## hides: resume paths (pause_menu.toggle_pause / Main.resume) own hiding.
func _sync_pause_menu_visibility() -> void:
	if not get_tree().paused:
		return
	var pm := get_tree().get_first_node_in_group("pause_menu")
	if pm is Control and not (pm as Control).visible:
		(pm as Control).visible = true


func _on_window_focus_in() -> void:
	_focus_lost = false
	# Recapture only into real gameplay: with a menu open the mouse stays
	# VISIBLE and the click belongs to the menu. Bindings stay erased in
	# both cases: the first mouse press after focus-in restores them via
	# _input (or _sync, once the pending press is consumed) — restoring
	# here would let the refocus click fire.
	if _pause_open() or _forge_open_or_ui():
		MouseCapture.set_menu()
		return
	MouseCapture.set_gameplay()


func _on_window_focus_out() -> void:
	# Alt-tab / click-away: release capture + erase mouse bindings so the
	# refocus click cannot fire, and arm the pending-press gate so _sync
	# does not restore the bindings before that click arrives.
	_focus_lost = true
	_focus_click_pending = true
	MouseCapture.set_menu()
	MouseCapture.erase_mouse_bindings()


func _input(event: InputEvent) -> void:
	# Focus-click + menu-click must not fire. WeaponManager polls
	# Input.is_action_just_pressed("fire") in _process, and neither
	# marking an event handled nor Input.action_release() in _input
	# clears that polled state (probe-verified) — the binding-erase in
	# MouseCapture is the only ordering-proof suppression. So on a
	# mouse-button press while bindings are erased:
	#   - gameplay (no menu open) -> restore the bindings. This press
	#     still cannot fire (its binding was gone when it was parsed);
	#     it is the consumed recapture click. The NEXT click fires.
	#   - menu open -> keep erased (later menu clicks can't fire either).
	# Either way the pending-press gate clears: the refocus click is over.
	# The event is deliberately NOT marked handled: GUI buttons still
	# need the click. Normal gameplay clicks pass through untouched.
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		return
	if MouseCapture.mouse_bindings_erased():
		_focus_click_pending = false
		if not (_pause_open() or _forge_open_or_ui()):
			MouseCapture.restore_mouse_bindings()


## PROCESS_MODE_ALWAYS watchdog: HUD._process freezes while the tree is
## paused, so this child is what releases capture (and shows the pause
## menu) when pause opens via ESC. It does nothing else.
class _MouseWatchdog:
	extends Node
	var _hud: CanvasLayer = null

	func _process(_delta: float) -> void:
		if _hud != null and is_instance_valid(_hud) and _hud.has_method("_sync_mouse_mode"):
			_hud.call("_sync_mouse_mode")
