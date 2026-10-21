# res://scripts/android/touch_controls.gd
# FORGEFALL — Worker 9 (Android + touch)
#
# Mobile HUD: dynamic left stick, independent look fingers, and fire-drag aim.
# Gameplay uses action state; event-driven commands also receive InputEventAction.
# Menu mouse emulation is owned by MouseCapture, never by the gameplay dispatcher.
extends CanvasLayer

#region TUNABLES
const JOY_RADIUS := 90.0          # px, knob travel from dynamic origin
const JOY_KNOB := 46.0            # px, knob diameter
const JOY_DEADZONE := 0.15        # stick magnitude below this = no input
const JOY_SPRINT_AT := 0.92       # stick magnitude >= this presses "sprint"
const JOY_ZONE_FRAC := 0.40       # left 40% of screen starts the joystick
const LOOK_GAIN := 0.0022        # radians of view per dragged pixel (matches player LOOK_SENS)
const BTN_ALPHA := 0.55          # button background opacity
const HINT_SHOW_SEC := 10.0      # first-time hints stay up this long, then fade
const HINT_FADE_SEC := 1.0       # hint fade-out duration
#endregion

@export var look_sensitivity := 1.0  # wired to the options menu later
@export var force_show := false      # debug: show touch UI on non-touch devices

const _ACTIONS_MOVE := ["move_forward", "move_back", "move_left", "move_right"]

var _touch_active := false
var _interactive := true
var _view_size := Vector2.ZERO

var _touches := {}            # touch index (int) -> String assignment
var _btn_by_touch := {}       # touch index (int) -> int index into _btn_defs
var _look_last := {}          # touch index (int) -> Vector2 last position for
                              # "look" touches. Look deltas are computed HERE
                              # (pos - last_pos per touch index), never from
                              # InputEventScreenDrag.relative: on some mobile
                              # browsers the engine's relative mixes touches,
                              # which reads as the view "jumping to random
                              # places" the moment a second finger is down.
                              # Manual per-touch deltas are correct under every
                              # engine behavior.
var _joy_radius := JOY_RADIUS
var _joy_knob_size := JOY_KNOB
var _joy_origin := Vector2.ZERO
var _joy_vec := Vector2.ZERO  # reused, no per-event allocs
var _joy_touch := -1
var _look_vec := Vector2.ZERO # reused
var _ads_on := false

var _player: Node = null
var _sfx: Node = null
var _speech: Node = null

var _btn_defs: Array = []     # Array[Dictionary]
var _joy_base: Panel
var _joy_knob: Panel

# First-time hints (C3): two labels shown once per session, first 10s of the
# first match, then faded. Session-only flag — no file persistence.
var _hint_grapple: Label
var _hint_wallrun: Label
var _hints_shown := false
var _hints_timer := 0.0
var _hints_fading := false


func _ready() -> void:
	layer = 10
	add_to_group("touch_controls")
	_touch_active = force_show or DisplayServer.is_touchscreen_available() \
		or OS.has_feature("android") or OS.has_feature("ios") \
		or OS.has_feature("web")  # WEB PORT: always on in browsers (touch devices)
	visible = _touch_active
	_sfx = get_node_or_null("/root/Sfx")
	_speech = SpeechInput.new()
	_speech.name = "SpeechInput"
	add_child(_speech)
	_build_ui()
	_layout()
	Preferences.apply.call_deferred()
	get_viewport().size_changed.connect(_layout)
	get_tree().call_group("hud", "set_touch_mode", _touch_active)


func _build_ui() -> void:
	# Buttons are visual-only; all press logic lives in _input().
	_add_btn("portal_blue", "BLU", "portal_blue", "hold", Vector2(60, 60), 18)
	_add_btn("portal_orange", "ORG", "portal_orange", "hold", Vector2(60, 60), 18)
	_add_btn("forge", "FORGE", "forge_console", "tap", Vector2(132, 56), 20)
	_add_btn("mic", "MIC", "", "mic", Vector2(56, 56), 16)
	_add_btn("ks1", "K1", "killstreak_1", "tap", Vector2(52, 52), 16)
	_add_btn("ks2", "K2", "killstreak_2", "tap", Vector2(52, 52), 16)
	_add_btn("ks3", "K3", "killstreak_3", "tap", Vector2(52, 52), 16)
	_add_btn("pause", "II", "pause", "event", Vector2(52, 52), 18)
	_add_btn("fire", "FIRE", "fire", "hold", Vector2(174, 174), 24)
	_add_btn("jump", "JUMP", "jump", "hold", Vector2(120, 120), 20)
	_add_btn("ads", "ADS", "ads", "toggle", Vector2(116, 116), 20)
	_add_btn("crouch", "CRCH", "crouch", "hold", Vector2(108, 108), 18)
	_add_btn("grapple", "HOOK", "grapple", "hold", Vector2(108, 108), 18)
	_add_btn("reload", "RLD", "reload", "tap", Vector2(100, 100), 18)

	_add_btn("interact", "PLACE / USE", "interact", "event", Vector2(160, 70), 20)
	_add_btn("cancel", "CANCEL", "ui_cancel", "event", Vector2(130, 70), 20)
	_add_btn("weapon", "SWAP", "weapon_next", "tap", Vector2(120, 70), 20)

	_joy_base = _make_disc(JOY_RADIUS * 2.0, Color(0.02, 0.03, 0.04, 0.40))
	_joy_base.visible = false
	add_child(_joy_base)
	var arrows := preload("res://scripts/android/touch_action_icon.gd").new()
	arrows.action = "move"
	arrows.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_joy_base.add_child(arrows)
	_joy_knob = _make_disc(JOY_KNOB, Color(1, 1, 1, 0.35))
	_joy_knob.visible = false
	add_child(_joy_knob)
	_build_hints()


func _build_hints() -> void:
	# Non-interactive labels (mouse_filter IGNORE): they never steal touches.
	_hint_grapple = _make_hint("HOOK: tap to grapple, tap again to release")
	_hint_wallrun = _make_hint("Jump next to a wall while moving to wall-run")
	add_child(_hint_grapple)
	add_child(_hint_wallrun)


func _make_hint(text: String) -> Label:
	var l := Label.new()
	l.name = "Hint_" + text.left(6)
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size",
		UiScale.scaled_font(20.0, get_viewport().get_visible_rect().size))
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.03, 0.05, 0.62)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	l.add_theme_stylebox_override("normal", sb)
	l.visible = false
	return l


func _process(_delta: float) -> void:
	var preview := false
	for placement in get_tree().get_nodes_in_group("forge_placement"):
		preview = preview or placement.has_preview()
	for d in _btn_defs:
		if d["id"] == "cancel":
			d["btn"].visible = preview
		elif d["id"] == "interact":
			d["btn"].text = "PLACE" if preview else "USE"
	# First match detection: the player group appears when a run starts.
	# Hints show once, on the first run, then fade after HINT_SHOW_SEC.
	if not _hints_shown and _touch_active:
		if get_tree().get_first_node_in_group("player") != null:
			show_hints()
	if _hints_timer > 0.0:
		_hints_timer -= _delta
		if _hints_timer <= 0.0:
			dismiss_hints()


## Show both first-time hints (starts the 10s auto-fade timer).
func show_hints() -> void:
	_hints_shown = true
	_hints_timer = HINT_SHOW_SEC
	_hints_fading = false
	for h in [_hint_grapple, _hint_wallrun]:
		if h != null:
			h.modulate.a = 1.0
			h.visible = true
	_position_hints()


## Fade the hints out (auto-called after HINT_SHOW_SEC; also callable directly).
func dismiss_hints() -> void:
	_hints_timer = 0.0
	if _hints_fading:
		return
	_hints_fading = true
	for h in [_hint_grapple, _hint_wallrun]:
		if h == null or not h.visible:
			continue
		var tw := create_tween()
		tw.tween_property(h, "modulate:a", 0.0, HINT_FADE_SEC)
		tw.tween_callback(h.hide)


func hints_visible() -> bool:
	return (_hint_grapple != null and _hint_grapple.visible) \
		or (_hint_wallrun != null and _hint_wallrun.visible)


func hints_shown() -> bool:
	return _hints_shown


func _position_hints() -> void:
	# Centered, upper-middle of the screen — clear of the button clusters.
	if _hint_grapple == null or _hint_wallrun == null:
		return
	var w := _view_size.x
	var h := _view_size.y
	if w <= 0.0 or h <= 0.0:
		return
	var gs := _hint_grapple.get_combined_minimum_size()
	var ws := _hint_wallrun.get_combined_minimum_size()
	_hint_grapple.size = gs
	_hint_wallrun.size = ws
	_hint_grapple.position = Vector2(w * 0.5 - gs.x * 0.5, h * 0.28)
	_hint_wallrun.position = Vector2(w * 0.5 - ws.x * 0.5, h * 0.28 + gs.y + 8.0)


func _add_btn(id: String, label: String, action: String, mode: String,
		size: Vector2, font: int) -> void:
	var b := Button.new()
	b.name = "Btn_" + id
	b.text = label
	if id in ["fire", "ads", "reload", "jump", "crouch", "grapple"]:
		b.text = ""
		var icon := preload("res://scripts/android/touch_action_icon.gd").new()
		icon.action = id
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		b.add_child(icon)
		b.tooltip_text = label
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE  # visual only; _input() dispatches
	b.add_theme_font_size_override("font_size", font)
	b.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	var r := int(minf(size.x, size.y) * 0.5)
	var normal := _disc_style(Color(0.06, 0.07, 0.09, BTN_ALPHA),
		Color(1, 1, 1, 0.35), r)
	var pressed := _disc_style(Color(1.0, 0.55, 0.12, 0.80),
		Color(1, 1, 1, 0.65), r)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("disabled", normal)
	if mode == "toggle":
		b.toggle_mode = true
	add_child(b)
	_btn_defs.append({
		"id": id, "label": label, "action": action, "mode": mode,
		"size": size, "base_size": size, "base_font": font,
		"pos": Vector2.ZERO, "btn": b,
	})


func _disc_style(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(radius)
	return sb


func _make_disc(diameter: float, color: Color) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.border_color = Color(1, 1, 1, 0.45)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(diameter * 0.5))
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(diameter, diameter)
	p.size = Vector2(diameter, diameter)
	return p


func _layout() -> void:
	_release_all()
	var vp_size := get_viewport().get_visible_rect().size
	_view_size = vp_size
	# Reference-sized action targets; never recursively shrink the controls.
	var k := clampf(minf(vp_size.x / 1280.0, vp_size.y / 720.0), 0.65, 1.8)
	_joy_radius = JOY_RADIUS * k
	_joy_knob_size = JOY_KNOB * k
	_joy_base.custom_minimum_size = Vector2.ONE * _joy_radius * 2.0
	_joy_base.size = _joy_base.custom_minimum_size
	_joy_knob.custom_minimum_size = Vector2.ONE * _joy_knob_size
	_joy_knob.size = _joy_knob.custom_minimum_size
	_place_buttons(vp_size, k)
	_position_hints()
	_reset_joy_visual()


func _place_buttons(vp_size: Vector2, k: float) -> void:
	# Utility controls at the top, combat controls in a right-side arc.
	var w := vp_size.x
	var m := 16.0 * k
	var gap := 12.0 * k
	var s := {}  # id -> scaled Vector2 size
	# A hard 48-unit floor keeps every target reachable on small screens.
	for d in _btn_defs:
		var base: Vector2 = d["base_size"]
		s[String(d["id"])] = Vector2(
			maxf(base.x * k * 0.67, maxf(48.0, 72.0 * k)),
			maxf(base.y * k * 0.67, maxf(48.0, 72.0 * k)))
	var p := {}  # id -> Vector2 position
	# Top-left: portals.
	p["portal_blue"] = Vector2(m, m)
	p["portal_orange"] = Vector2(m + s["portal_blue"].x + gap, m)
	# Top-center: one centered row (forge, mic, killstreaks).
	var row := ["forge", "mic", "ks1", "ks2", "ks3"]
	var total := 0.0
	for id in row:
		total += s[id].x
	total += gap * (row.size() - 1)
	var x := w * 0.5 - total * 0.5
	for id in row:
		p[id] = Vector2(x, m)
		x += s[id].x + gap
	# Top-right: pause.
	p["pause"] = Vector2(w - m - s["pause"].x, m)
	# Right thumb arc, leaving the center clear for aiming.
	var centers := {
		"fire": Vector2(0.94, 0.63), "ads": Vector2(0.875, 0.45),
		"grapple": Vector2(0.80, 0.55), "reload": Vector2(0.85, 0.75),
		"jump": Vector2(0.95, 0.84), "crouch": Vector2(0.83, 0.92),
		"interact": Vector2(0.53, 0.78), "cancel": Vector2(0.66, 0.78),
		"weapon": Vector2(0.53, 0.93),
	}
	for id in centers:
		p[id] = vp_size * centers[id] - s[id] * 0.5
	for d in _btn_defs:
		var id := String(d["id"])
		d["size"] = s[id]
		d["pos"] = p[id]
		var b: Button = d["btn"]
		b.position = p[id]
		b.size = s[id]
		for style_name in ["normal", "pressed"]:
			var style := b.get_theme_stylebox(style_name) as StyleBoxFlat
			if style != null:
				style.set_corner_radius_all(int(minf(s[id].x, s[id].y) * 0.5))
		# v0.6.1: button label fonts scale with resolution too.
		# v0.6.6 intake: back to the exact UiScale derivation (the
		# standing contract — verify_v061 locks touch FIRE font ==
		# UiScale(24), and base_font values are already UiScale bases;
		# GPT's local k * 0.8 formula drifted from it at phone sizes).
		b.add_theme_font_size_override("font_size",
			UiScale.scaled_font(float(d["base_font"]), vp_size))


func _buttons_overlap() -> bool:
	for i in _btn_defs.size():
		var a := Rect2(_btn_defs[i]["pos"], _btn_defs[i]["size"])
		for j in range(i + 1, _btn_defs.size()):
			var b := Rect2(_btn_defs[j]["pos"], _btn_defs[j]["size"])
			if a.intersects(b):
				return true
	return false


func _input(event: InputEvent) -> void:
	if not _touch_active or not _interactive or not visible:
		return
	# VOICE V2: while the voice CONFIRM prompt is open, its buttons own
	# the screen — the manual dispatcher below does not respect Control
	# mouse_filter, so gate it or taps on CONFIRM/RETRY/CANCEL would
	# also fire game buttons underneath. LISTENING is not gated: the
	# player must keep moving/looking while holding MIC to talk.
	if _voice_confirm_open():
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_touch_begin(t.index, t.position)
		else:
			_touch_end(t.index)
	elif event is InputEventScreenDrag:
		var dr := event as InputEventScreenDrag
		# NOTE: dr.relative is deliberately IGNORED — _touch_move()
		# recomputes per-touch deltas from tracked positions (see
		# _look_last). Engine relative is unreliable for multi-touch
		# on mobile browsers.
		_touch_move(dr.index, dr.position)


func _touch_begin(index: int, pos: Vector2) -> void:
	# Buttons first (topmost = last created).
	for i in range(_btn_defs.size() - 1, -1, -1):
		var d: Dictionary = _btn_defs[i]
		var rect := Rect2(d["pos"], d["size"])
		if d["btn"].visible and rect.has_point(pos):
			_touches[index] = "btn"
			_btn_by_touch[index] = i
			if d["id"] == "fire":
				_look_last[index] = pos
			_btn_down(d)
			return
	if pos.x < _view_size.x * JOY_ZONE_FRAC:
		# Single-owner joystick: the FIRST touch in the zone owns the
		# stick. A second finger landing in the zone while the stick is
		# held is tracked but ignored ("joy_wait") — letting it steal
		# _joy_origin mid-drag used to make movement jump wildly.
		if _joy_touch != -1:
			_touches[index] = "joy_wait"
			return
		_touches[index] = "joy"
		_joy_touch = index
		_joy_origin = pos
		_joy_vec = Vector2.ZERO
		_joy_base.position = pos - Vector2(_joy_radius, _joy_radius)
		_joy_base.visible = true
		_joy_knob.position = pos - Vector2(_joy_knob_size, _joy_knob_size) * 0.5
		_joy_knob.visible = true
	else:
		_touches[index] = "look"
		_look_last[index] = pos


func _touch_move(index: int, pos: Vector2) -> void:
	var kind := String(_touches.get(index, ""))
	match kind:
		"joy":
			_update_joy(pos)
		"joy_wait":
			pass  # second finger in the stick zone: tracked, ignored.
		"look":
			# Per-touch delta from OUR tracked last position — the move
			# stick's touch (or any other finger) can never leak into
			# look, and a bogus engine relative can never jump the view.
			var last: Vector2 = _look_last.get(index, pos)
			_look_last[index] = pos
			_apply_look(pos - last)
		"btn":
			if _look_last.has(index):
				var last: Vector2 = _look_last[index]
				_look_last[index] = pos
				_apply_look(pos - last)
		# Buttons stay engaged even if the finger slides off.
		# unknown index (stale drag): ignored.


func _touch_end(index: int) -> void:
	var kind := String(_touches.get(index, ""))
	_touches.erase(index)
	_look_last.erase(index)
	match kind:
		"joy":
			# Defensive: only the owning touch releases the stick. A
			# "joy_wait" touch ending here would otherwise kill a stick
			# another finger is still holding.
			if index == _joy_touch:
				_release_joy()
		"joy_wait":
			pass  # was ignored the whole time; nothing to release.
		"btn":
			var bi := int(_btn_by_touch.get(index, -1))
			_btn_by_touch.erase(index)
			if bi >= 0 and not _btn_by_touch.values().has(bi):
				_btn_up(_btn_defs[bi])
		# "look": nothing to release (last-pos already erased above).
		# unknown index: nothing was tracked.


func _update_joy(pos: Vector2) -> void:
	_joy_vec = pos - _joy_origin
	var len := _joy_vec.length()
	if len > _joy_radius:
		_joy_vec *= _joy_radius / len
		len = _joy_radius
	var mag := len / _joy_radius
	if mag < JOY_DEADZONE:
		_set_move(0.0, 0.0, 0.0)
	else:
		var nx := _joy_vec.x / _joy_radius
		var ny := _joy_vec.y / _joy_radius
		_set_move(nx, ny, mag)
	_update_joy_visual()


func _set_move(nx: float, ny: float, mag: float) -> void:
	# Screen up (-y) = forward. Strength per axis = deflection magnitude,
	# so the player controller gets analog speed for free.
	_set_action_strength("move_forward", maxf(0.0, -ny))
	_set_action_strength("move_back", maxf(0.0, ny))
	_set_action_strength("move_left", maxf(0.0, -nx))
	_set_action_strength("move_right", maxf(0.0, nx))
	# Full deflection = sprint (MW2-style auto-sprint on the stick).
	_set_action_strength("sprint", 1.0 if mag >= JOY_SPRINT_AT else 0.0)


func _set_action_strength(action: StringName, strength: float) -> void:
	# VERIFIED: Input.action_press(action, strength) sets pressed state with
	# 0..1 strength; Input.action_release(action) clears it. Works with
	# is_action_pressed() / is_action_just_pressed() / get_action_strength().
	if strength > 0.001:
		Input.action_press(action, clampf(strength, 0.0, 1.0))
	else:
		Input.action_release(action)


func _release_joy() -> void:
	_joy_touch = -1
	_reset_joy_visual()
	for a in _ACTIONS_MOVE:
		Input.action_release(a)
	Input.action_release("sprint")


func _update_joy_visual() -> void:
	var c := _joy_origin + _joy_vec
	_joy_knob.position = c - Vector2(_joy_knob_size, _joy_knob_size) * 0.5


func _apply_look(relative: Vector2) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	if _player == null:
		return
	_look_vec = relative * (LOOK_GAIN * look_sensitivity)
	# Contract: player.add_look() takes RADIANS (v0.1.5). _look_vec is already
	# pixels -> radians via LOOK_GAIN; the player applies look_sensitivity/ADS.
	if _player.has_method("add_look"):
		_player.call("add_look", _look_vec)


func _btn_down(d: Dictionary) -> void:
	var b: Button = d["btn"]
	var mode := String(d["mode"])
	_click_feedback()
	match mode:
		"hold":
			b.modulate = Color(1.35, 1.35, 1.35)
			Input.action_press(StringName(d["action"]), 1.0)
		"event":
			var press := InputEventAction.new()
			press.action = d["action"]
			press.pressed = true
			Input.parse_input_event(press)
		"tap":
			b.modulate = Color(1.35, 1.35, 1.35)
			Input.action_press(StringName(d["action"]), 1.0)
		"toggle":
			_ads_on = not _ads_on
			b.button_pressed = _ads_on
			_set_action_strength("ads", 1.0 if _ads_on else 0.0)
		"mic":
			b.modulate = Color(1.35, 1.35, 1.35)
			_speech.listen(_on_voice_text)


func _btn_up(d: Dictionary) -> void:
	var b: Button = d["btn"]
	var mode := String(d["mode"])
	match mode:
		"event":
			var release := InputEventAction.new()
			release.action = d["action"]
			release.pressed = false
			Input.parse_input_event(release)
		"hold", "tap":
			b.modulate = Color.WHITE
			Input.action_release(StringName(d["action"]))
		"toggle":
			pass  # stays latched until tapped again
		"mic":
			b.modulate = Color.WHITE
			# VOICE V2 push-to-talk release: arms the confirm step.
			# Nothing is sent on release — the transcript still waits
			# for CONFIRM. SpeechInput handles its own lifecycle.
			if _speech != null and _speech.has_method("end_ptt"):
				_speech.call("end_ptt")


func _click_feedback() -> void:
	Haptics.ui()
	if _sfx != null and _sfx.has_method("play_2d"):
		_sfx.call("play_2d", "ui_click")


## VOICE V2: true while SpeechInput's CONFIRM prompt is open. The
## confirm overlay is modal — _input() returns early while it is up.
func _voice_confirm_open() -> bool:
	if _speech == null or not _speech.has_method("is_confirm_open"):
		return false
	return bool(_speech.call("is_confirm_open"))


func _on_voice_text(text: String) -> void:
	# Plugin path delivered a CONFIRMED transcription: SpeechInput only
	# calls this after the player tapped CONFIRM on the heard text, so
	# hand it straight to the Forge. Empty transcripts never submit
	# (SpeechInput already filters them; this is defense-in-depth so a
	# stray "" can't become an empty prompt).
	var transcript := text.strip_edges()
	if transcript.is_empty():
		return
	var forge := get_node_or_null("/root/Forge")
	if forge != null and forge.has_method("submit_prompt"):
		forge.call("submit_prompt", transcript)
	else:
		push_warning("[TouchControls] Forge autoload not ready; voice text dropped.")


# --- public API -----------------------------------------------------------

## Let the HUD (worker 6) mute touch input while modal panels are up,
## without hiding the layer.
## v0.6.1: hide/show the whole touch layer while the Forge menu is open.
## Called by the HUD via group "touch_controls". Hiding also mutes input
## (releases any held action) so no touch can leak through the menu;
## restoring brings back exactly the pre-menu state (visible iff touch).
func set_menu_open(open: bool) -> void:
	if _interactive == not open:
		return
	if open:
		visible = false
		set_interactive(false)
	else:
		visible = _touch_active
		set_interactive(true)


func set_interactive(on: bool) -> void:
	_interactive = on
	if not on:
		_release_all()

func is_touch_active() -> bool:
	return _touch_active

func set_look_sensitivity(v: float) -> void:
	look_sensitivity = maxf(0.1, v)


func _release_all() -> void:
	# Safety: never leave a stuck action if the layer is muted mid-gesture.
	if _joy_touch != -1:
		_release_joy()
	for d in _btn_defs:
		var b: Button = d["btn"]
		b.modulate = Color.WHITE
		if String(d["mode"]) == "toggle":
			_ads_on = false
			b.button_pressed = false
			Input.action_release(StringName(d["action"]))
		elif String(d["mode"]) == "mic" and _speech != null and _speech.has_method("end_ptt"):
			_speech.call("end_ptt")
		elif not String(d["action"]).is_empty():
			# Buttons with no InputMap action (mode "mic" passes "") have
			# nothing to release — releasing "" logs `InputMap action ""`.
			Input.action_release(StringName(d["action"]))
	_touches.clear()
	_btn_by_touch.clear()
	_look_last.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_release_all()


func _reset_joy_visual() -> void:
	if _joy_base == null or _joy_knob == null:
		return
	_joy_vec = Vector2.ZERO
	_joy_origin = _view_size * Vector2(0.12, 0.70)
	_joy_base.position = _joy_origin - Vector2.ONE * _joy_radius
	_joy_base.visible = true
	_joy_knob.visible = true
	_update_joy_visual()
