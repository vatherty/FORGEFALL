# scripts/ui/killfeed.gd
# FORGEFALL — Goal 4 MULTIPLAYER (Worker C: match modes).
# Online killfeed: "A killed B (weapon)" entries. Standalone Control the
# coordinator adds to the HUD layer; it does NOT touch the HUD's own
# killfeed (hud.gd keeps its "YOU ▸ ENEMY" feed). Placed BELOW the HUD
# killfeed (which occupies roughly y 84..320, top-right) so the two never
# overlap. Entries are team-coloured via RichTextLabel bbcode, fade after
# FADE_AFTER seconds, max MAX_ENTRIES pooled labels (round-robin reuse,
# same pattern as the HUD feed — entries can never stack unbounded).
# Dumb by design: NetMatch emits kill_confirmed(...) with display-ready
# args in exactly this method's parameter order, so the coordinator wires
# it with one connect:  match.kill_confirmed.connect(killfeed.add_entry).
class_name NetKillfeed
extends Control

const MAX_ENTRIES := 6
const FADE_AFTER := 4.0
const FADE_TIME := 0.5

const TEAM_COLORS := [Color(1.0, 0.48, 0.11), Color(0.25, 0.6, 1.0)]

var _box: VBoxContainer
var _labels: Array[RichTextLabel] = []
var _ages: Array[float] = []
var _next := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()


func _build_ui() -> void:
	_box = VBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_box.offset_left = -420
	_box.offset_top = 330
	_box.offset_right = -20
	_box.offset_bottom = 560
	_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_theme_constant_override("separation", 4)
	add_child(_box)
	_labels.clear()
	_ages.clear()
	for i in MAX_ENTRIES:
		var l := RichTextLabel.new()
		l.bbcode_enabled = true
		l.scroll_active = false
		# NOTE: RichTextLabel has no fit_content_height in Godot 4.7 —
		# assigning it aborts _build_ui (and leaves the pool empty).
		# Fixed row height instead; entries are single-line.
		l.custom_minimum_size = Vector2(380, 26)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_font_override("normal_font", StencilStyle.tracking_font(2))
		l.add_theme_font_size_override("normal_font_size",
			UiScale.scaled_font(20, _viewport_size()))
		l.add_theme_color_override("default_color", StencilStyle.TEXT)
		l.modulate.a = 0.0
		_box.add_child(l)
		_labels.append(l)
		_ages.append(999.0)


func _viewport_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(1280, 720)
	return vp.get_visible_rect().size


## Display-ready entry. Parameter order matches NetMatch.kill_confirmed
## so the coordinator can connect the signal directly to this method.
## suicide is always false in TDM v1 (self-damage is rejected by the host)
## but the slot exists for future fall/environmental deaths.
func add_entry(killer_name: String, victim_name: String, weapon_display: String,
		killer_team: int, victim_team: int, headshot: bool = false,
		suicide: bool = false) -> void:
	if _labels.is_empty():
		_build_ui()
	var l := _labels[_next]
	var kt := clampi(killer_team, 0, 1)
	var vt := clampi(victim_team, 0, 1)
	var kc: String = (TEAM_COLORS[kt] as Color).to_html(false)
	var vc: String = (TEAM_COLORS[vt] as Color).to_html(false)
	var text: String
	if suicide:
		text = "[color=%s]%s[/color] ☠ SELF" % [vc, victim_name.to_upper()]
	else:
		text = "[color=%s]%s[/color] ▸ [color=%s]%s[/color]  %s" % [
			kc, killer_name.to_upper(), vc, victim_name.to_upper(),
			weapon_display.to_upper()]
		if headshot:
			text += "  [HEADSHOT]"
	l.text = text
	l.modulate.a = 1.0
	_ages[_next] = 0.0
	_next = (_next + 1) % MAX_ENTRIES


func clear() -> void:
	for i in _labels.size():
		_labels[i].text = ""
		_labels[i].modulate.a = 0.0
		_ages[i] = 999.0
	_next = 0


func entry_count_visible() -> int:
	var n := 0
	for i in _labels.size():
		if _ages[i] < 900.0 and _labels[i].modulate.a > 0.01:
			n += 1
	return n


func _process(delta: float) -> void:
	for i in _labels.size():
		if _ages[i] < 900.0:
			_ages[i] += delta
			if _ages[i] > FADE_AFTER:
				var k := 1.0 - (_ages[i] - FADE_AFTER) / FADE_TIME
				_labels[i].modulate.a = clampf(k, 0.0, 1.0)
