# scripts/ui/stats_screen.gd
# FORGEFALL — STATS screen (Goal 6 PROGRESSION, Worker C).
# Lifetime + per-mode stats, rendered from the Stats autoload when it
# exists, else from a user://stats.json snapshot (so the screen works
# standalone in probes and before the coordinator registers the autoload).
#
# OPENING (coordinator wiring — main_menu.gd is NOT touched by this worker):
#   var screen := StatsScreen.open_in(parent)   # static helper; reuses an
#   existing StatsScreen child of `parent` if one is already there
#   screen.open() / screen.close()              # show / hide (+ `closed`)
# `closed` fires on BACK. close() hides but does NOT free the node, so
# the coordinator can keep one instance around and re-open it.
#
# Layout: full-screen modal (2%-viewport margins, UiScale fonts, the
# v0.6.1 convention) over a dim background, ONE vertical flow in a
# ScrollContainer — nothing clips, nothing overlaps. Sections:
# LIFETIME / PER-WEAPON KILLS (sorted desc) / PER-MODE / BEST ENDLESS.
# RESET is two-tap (arm -> confirm) so a stray tap can't wipe a record.
class_name StatsScreen
extends Control

signal closed

const STATS_SCENE := "res://scenes/ui/stats_screen.tscn"
const STATS_SCRIPT := "res://scripts/progression/stats.gd"

var _lifetime_label: Label
var _weapons_label: Label
var _modes_label: Label
var _endless_label: Label
var _reset_button: Button
var _reset_armed: bool = false
var _section_labels: Array[Label] = []


## Load the scene, add it to `parent` (reusing an existing StatsScreen
## child), open it, and return the instance. Null if the scene is missing.
static func open_in(parent: Node) -> Node:
	if parent == null:
		push_warning("StatsScreen.open_in: null parent.")
		return null
	var existing := parent.get_node_or_null("StatsScreen")
	if existing != null and existing.has_method("open"):
		existing.call("open")
		return existing
	if not ResourceLoader.exists(STATS_SCENE):
		push_warning("StatsScreen: scene missing at %s." % STATS_SCENE)
		return null
	var screen := (load(STATS_SCENE) as PackedScene).instantiate()
	screen.name = "StatsScreen"
	parent.add_child(screen)
	if screen.has_method("open"):
		screen.call("open")
	return screen


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()
	_connect_stats()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_apply_scale()


func open() -> void:
	visible = true
	_reset_armed = false
	if _reset_button != null:
		_reset_button.text = "RESET STATS"
	_refresh()
	_apply_scale()


func close() -> void:
	visible = false
	closed.emit()


func _connect_stats() -> void:
	var stats: Node = get_node_or_null("/root/Stats")
	if stats != null and stats.has_signal("stats_changed"):
		if not stats.is_connected("stats_changed", _on_stats_changed):
			stats.connect("stats_changed", _on_stats_changed)


func _on_stats_changed() -> void:
	if visible:
		_refresh()


## Snapshot source: live autoload when present, else the stats file.
func _snapshot() -> Dictionary:
	var stats: Node = get_node_or_null("/root/Stats")
	if stats != null and stats.has_method("get_stats"):
		var snap: Variant = stats.call("get_stats")
		if snap is Dictionary:
			return snap as Dictionary
	var script := load(STATS_SCRIPT) as GDScript
	if script != null and script.has_method("load_snapshot"):
		var snap2: Variant = script.call("load_snapshot")
		if snap2 is Dictionary:
			return snap2 as Dictionary
	return {}


func _refresh() -> void:
	var snap := _snapshot()
	if snap.is_empty():
		snap = _empty_snapshot()
	var kills := _as_int(snap.get("kills", 0))
	var deaths := _as_int(snap.get("deaths", 0))
	var wins := _as_int(snap.get("wins", 0))
	var losses := _as_int(snap.get("losses", 0))
	var draws := _as_int(snap.get("draws", 0))
	var shots := _as_int(snap.get("shots", 0))
	var hits := _as_int(snap.get("hits", 0))
	var kd := float(kills) / float(deaths) if deaths > 0 else float(kills)
	var acc := (float(hits) / float(shots) * 100.0) if shots > 0 else 0.0
	var time_text := _format_time(float(snap.get("time_played_s", 0.0)))
	if _lifetime_label != null:
		_lifetime_label.text = "\n".join([
			"K / D            %.2f  (%d KILLS / %d DEATHS)" % [kd, kills, deaths],
			"WINS / LOSSES    %d W / %d L / %d D" % [wins, losses, draws],
			"ACCURACY         %.1f%%  (%d HITS / %d SHOTS)" % [acc, hits, shots],
			"TIME PLAYED      %s" % time_text,
			"CAPTURES         %d" % _as_int(snap.get("captures", 0)),
			"DOMINATION HOLD  %d PTS" % _as_int(snap.get("domination_hold_points", 0)),
			"WAVES CLEARED    %d" % _as_int(snap.get("waves_completed", 0)),
			"PUZZLES SOLVED   %d" % _as_int(snap.get("puzzles_completed", 0)),
			"HEADSHOT KILLS   %d" % _as_int(snap.get("headshot_kills", 0)),
		])
	if _weapons_label != null:
		_weapons_label.text = _weapons_text(snap.get("per_weapon_kills", {}))
	if _modes_label != null:
		_modes_label.text = _modes_text(snap.get("per_mode", {}))
	if _endless_label != null:
		var wave := _as_int(snap.get("best_endless_wave", 0))
		var score := _as_int(snap.get("best_endless_score", 0))
		if wave > 0 or score > 0:
			_endless_label.text = "BEST WAVE %d  ·  BEST SCORE %d" % [wave, score]
		else:
			_endless_label.text = "NO ENDLESS RUNS YET"


func _weapons_text(raw: Variant) -> String:
	if not (raw is Dictionary):
		return "NO KILLS YET"
	var weapons := raw as Dictionary
	if weapons.is_empty():
		return "NO KILLS YET"
	var rows: Array = []
	for wid in weapons:
		rows.append([str(wid).to_upper(), _as_int(weapons[wid], 0)])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return int(a[1]) > int(b[1]))
	var lines: Array[String] = []
	for r in rows:
		lines.append("%s — %d" % [str(r[0]), int(r[1])])
	return "\n".join(lines)


func _modes_text(raw: Variant) -> String:
	if not (raw is Dictionary):
		return "NO MATCHES YET"
	var modes := raw as Dictionary
	if modes.is_empty():
		return "NO MATCHES YET"
	var keys: Array = modes.keys()
	keys.sort()
	var lines: Array[String] = []
	for m in keys:
		if not (modes[m] is Dictionary):
			continue
		var entry := modes[m] as Dictionary
		var d := _as_int(entry.get("draws", 0))
		var wl := "%dW / %dL" % [_as_int(entry.get("wins", 0)), _as_int(entry.get("losses", 0))]
		if d > 0:
			wl += " / %dD" % d
		lines.append("%s — %d MATCHES · %s" % [
			str(m).to_upper(),
			_as_int(entry.get("matches", 0)),
			wl,
		])
	if lines.is_empty():
		return "NO MATCHES YET"
	return "\n".join(lines)


func _on_reset_pressed() -> void:
	if not _reset_armed:
		_reset_armed = true
		if _reset_button != null:
			_reset_button.text = "TAP AGAIN TO CONFIRM RESET"
		# Auto-disarm after 3 s so the armed state can't linger.
		await get_tree().create_timer(3.0).timeout
		_reset_armed = false
		if _reset_button != null and visible:
			_reset_button.text = "RESET STATS"
		return
	_reset_armed = false
	if _reset_button != null:
		_reset_button.text = "RESET STATS"
	var stats: Node = get_node_or_null("/root/Stats")
	if stats != null and stats.has_method("reset_stats"):
		stats.call("reset_stats")
	else:
		var script := load(STATS_SCRIPT) as GDScript
		if script != null and script.has_method("reset_file"):
			script.call("reset_file")
	_refresh()


func _on_back_pressed() -> void:
	_click()
	close()


func _click() -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d("ui_click")


# --- Layout (built in code; .tscn is a thin shell) ---------------------------

func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.025, 0.03, 0.97)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_BEGIN
	vb.add_theme_constant_override("separation", 14)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	var title := Label.new()
	title.name = "Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text = "SERVICE RECORD"
	StencilStyle.apply_title(title, 44, StencilStyle.ORANGE, 4)
	vb.add_child(title)

	var sub := Label.new()
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_body(sub, 20, StencilStyle.TEXT_DIM, 2)
	sub.text = "LIFETIME STATS // FORGEFALL"
	vb.add_child(sub)

	_lifetime_label = _section(vb, "LIFETIME", "")
	_weapons_label = _section(vb, "PER-WEAPON KILLS", "")
	_modes_label = _section(vb, "PER-MODE", "")
	_endless_label = _section(vb, "BEST ENDLESS", "")

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vb.add_child(btn_row)

	_reset_button = Button.new()
	_reset_button.text = "RESET STATS"
	_reset_button.custom_minimum_size = Vector2(280, 56)
	StencilStyle.style_button(_reset_button)
	_reset_button.pressed.connect(_on_reset_pressed)
	btn_row.add_child(_reset_button)

	var back := Button.new()
	back.text = "BACK"
	back.custom_minimum_size = Vector2(280, 56)
	StencilStyle.style_button(back)
	back.pressed.connect(_on_back_pressed)
	btn_row.add_child(back)

	_apply_scale()


func _section(parent: VBoxContainer, heading: String, body: String) -> Label:
	var head := Label.new()
	StencilStyle.apply_body(head, 24, StencilStyle.ORANGE, 3)
	head.text = heading
	parent.add_child(head)
	var label := Label.new()
	label.name = heading.replace(" ", "_")
	StencilStyle.apply_body(label, 22, StencilStyle.TEXT, 2)
	label.text = body
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	_section_labels.append(label)
	return label


func _apply_scale() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0:
		return
	var f := UiScale.scale_factor(vp)
	for l in _section_labels:
		if is_instance_valid(l):
			l.add_theme_font_size_override("font_size", maxi(10, int(round(22 * f))))
	# Margin tracks ~2% of the viewport (v0.6.1 full-screen-modal rule).
	# Guard: a resize can fire before _build() has added the children.
	if get_child_count() < 2:
		return
	var m := get_child(1) as MarginContainer
	if m != null:
		var px := int(vp.x * 0.02)
		var py := int(vp.y * 0.02)
		m.add_theme_constant_override("margin_left", px)
		m.add_theme_constant_override("margin_top", py)
		m.add_theme_constant_override("margin_right", px)
		m.add_theme_constant_override("margin_bottom", py)


func _empty_snapshot() -> Dictionary:
	var script := load(STATS_SCRIPT) as GDScript
	if script != null and script.has_method("default_stats"):
		var d: Variant = script.call("default_stats")
		if d is Dictionary:
			return d as Dictionary
	return {}


func _as_int(v: Variant, fallback: int = 0) -> int:
	if v is int:
		return v as int
	if v is float:
		return int(v as float)
	if v is String and (v as String).is_valid_int():
		return int(v as String)
	return fallback


func _format_time(seconds: float) -> String:
	var script := load(STATS_SCRIPT) as GDScript
	if script != null and script.has_method("format_time"):
		var t: Variant = script.call("format_time", seconds)
		if t is String:
			return t as String
	var total := maxi(0, int(seconds))
	return "%ds" % total
