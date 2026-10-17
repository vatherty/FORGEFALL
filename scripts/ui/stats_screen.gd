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

var _details_box: VBoxContainer
var _metric_kills: Label
var _metric_wins: Label
var _metric_accuracy: Label
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
	StencilStyle.install_menu(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()
	_connect_stats()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_apply_scale()


func open() -> void:
	visible = true
	InputBindings.grab_first_focus(self)
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
	if _metric_kills != null:
		_metric_kills.text = str(kills)
		_metric_wins.text = str(wins)
		_metric_accuracy.text = "%.0f%%" % acc
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
	StencilStyle.cinematic_background(self, "armory")
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 48)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 28)
	scroll.add_child(content)
	StencilStyle.section_header(content, "SERVICE RECORD")
	var gap := Control.new()
	gap.custom_minimum_size.y = 32
	content.add_child(gap)
	var metrics := HBoxContainer.new()
	metrics.add_theme_constant_override("separation", 32)
	content.add_child(metrics)
	_metric_kills = _metric(metrics, "KILLS")
	_metric_wins = _metric(metrics, "WINS")
	_metric_accuracy = _metric(metrics, "ACCURACY")
	var details := VBoxContainer.new()
	_details_box = details
	details.custom_minimum_size.x = 600
	details.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	details.add_theme_constant_override("separation", 16)
	content.add_child(details)
	_lifetime_label = _section(details, "COMBAT SUMMARY", "")
	_weapons_label = _section(details, "WEAPON RECORD", "")
	_modes_label = _section(details, "MATCH HISTORY", "")
	_endless_label = _section(details, "ENDLESS RECORD", "")
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(fill)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 24)
	content.add_child(actions)
	var back := Button.new()
	back.text = "‹  BACK"
	back.custom_minimum_size = Vector2(160, 52)
	StencilStyle.navigation_button(back)
	back.pressed.connect(_on_back_pressed)
	actions.add_child(back)
	_reset_button = Button.new()
	_reset_button.text = "RESET STATS"
	StencilStyle.style_button(_reset_button)
	_reset_button.pressed.connect(_on_reset_pressed)
	actions.add_child(_reset_button)
	_apply_scale()


func _metric(parent: Control, caption: String) -> Label:
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 96
	parent.add_child(column)
	var value := Label.new()
	StencilStyle.apply_title(value, 64)
	value.text = "0"
	column.add_child(value)
	var label := Label.new()
	label.text = caption
	StencilStyle.apply_body(label, 16, StencilStyle.TEXT_DIM)
	column.add_child(label)
	return value


func _section(parent: VBoxContainer, heading: String, body: String) -> Label:
	var head := Label.new()
	StencilStyle.apply_body(head, 24, StencilStyle.ORANGE, 3)
	head.text = heading
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	parent.add_child(stack)
	stack.add_child(head)
	var label := Label.new()
	label.name = heading.replace(" ", "_")
	StencilStyle.apply_body(label, 22, StencilStyle.TEXT, 2)
	label.text = body
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(label)
	label.visible = heading == "WEAPON RECORD"
	if heading != "WEAPON RECORD":
		var toggle := Button.new()
		toggle.text = heading + "  +"
		toggle.toggle_mode = true
		StencilStyle.navigation_button(toggle)
		toggle.add_theme_font_size_override("font_size", 22)
		toggle.toggled.connect(func(pressed: bool) -> void: label.visible = pressed)
		stack.add_child(toggle)
		stack.move_child(toggle, 0)
		head.visible = false
	_section_labels.append(label)
	return label


func _apply_scale() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0:
		return
	if _details_box != null:
		_details_box.custom_minimum_size.x = minf(600, maxf(280, vp.x - 96))
	for metric in [_metric_kills, _metric_wins, _metric_accuracy]:
		if metric != null:
			metric.add_theme_font_size_override("font_size", clampi(int(vp.x * 0.05), 32, 64))
	for l in _section_labels:
		if is_instance_valid(l):
			l.add_theme_font_size_override("font_size", StencilStyle.menu_font(22, vp))
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
