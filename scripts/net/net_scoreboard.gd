# scripts/net/net_scoreboard.gd
# FORGEFALL — Goal 4 MULTIPLAYER (Worker C: match modes).
# Scoreboard DATA + overlay for online matches. Host-authoritative: only the
# host writes via record_kill(); clients receive the whole table through
# apply_snapshot() (NetMatch broadcasts a snapshot on every kill). The data
# is plain dictionaries, so a snapshot is one RPC and convergence is trivial
# to verify: host.serialize() == client.serialize() after any kill.
#
# UI: a standalone Control (StencilStyle panel, UiScale fonts). The
# coordinator adds it to the HUD layer; it starts hidden and toggles with
# TAB (polled raw — there is NO "scoreboard" action in project.godot and
# this file must not rebind existing keys). Touch / gamepad: call
# toggle_scoreboard() / set_scoreboard_visible() from a button.
# Single-player is untouched: this node is only instanced for net matches.
class_name NetScoreboard
extends Control

signal scoreboard_visibility_changed(visible: bool)
signal score_updated()

const TEAM_NAMES := ["ALPHA", "BRAVO"]
const TEAM_COLORS := [Color(1.0, 0.48, 0.11), Color(0.25, 0.6, 1.0)]
const MAX_ROWS := 12

## peer_id -> {name: String, team: int, kills: int, deaths: int,
##             score: int, alive: bool}
var _rows: Dictionary = {}
var _team_scores: Array[int] = [0, 0]

var _panel: PanelContainer
var _rows_box: VBoxContainer
var _team_label: Label
var _visible_scoreboard := false


func _ready() -> void:
	StencilStyle.install_menu(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	# TAB toggles. _unhandled_input (not _input) so a focused LineEdit
	# (Forge console) keeps its keystrokes; the HUD never eats Tab.
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.keycode == KEY_TAB and ke.pressed and not ke.echo:
			toggle_scoreboard()
			get_viewport().set_input_as_handled()


# --- data (host writes, clients apply snapshots) ---------------------------

func register_player(peer_id: int, player_name: String, team: int) -> void:
	_rows[int(peer_id)] = {
		"name": player_name,
		"team": clampi(team, 0, 1),
		"kills": 0,
		"deaths": 0,
		"score": 0,
		"alive": true,
	}
	_rebuild()


## Host-only. One kill: killer +1 kill / +1 score / +1 team score,
## victim +1 death. Returns false for unknown ids (never crashes on a
## stale RPC).
func record_kill(killer_id: int, victim_id: int) -> bool:
	if not _rows.has(killer_id) or not _rows.has(victim_id):
		return false
	var k: Dictionary = _rows[killer_id]
	var v: Dictionary = _rows[victim_id]
	k["kills"] = int(k["kills"]) + 1
	k["score"] = int(k["score"]) + 1
	v["deaths"] = int(v["deaths"]) + 1
	v["alive"] = false
	var team := int(k["team"])
	_team_scores[team] = int(_team_scores[team]) + 1
	_rebuild()
	score_updated.emit()
	return true


func mark_alive(peer_id: int, alive: bool) -> void:
	if _rows.has(peer_id):
		_rows[peer_id]["alive"] = alive
		_rebuild()


## Delegated mode (NetManager owns scores): mirror one player's stats
## verbatim — kills/deaths/score come from NetManager's score_changed,
## never recomputed here. Creates the row (neutral defaults) if the
## player was never registered; never overwrites name/team/alive.
func apply_player_stats(peer_id: int, kills: int, deaths: int, score: int) -> void:
	if not _rows.has(peer_id):
		_rows[int(peer_id)] = {
			"name": "PLAYER %d" % int(peer_id),
			"team": 0,
			"kills": 0,
			"deaths": 0,
			"score": 0,
			"alive": true,
		}
	var r: Dictionary = _rows[peer_id]
	r["kills"] = kills
	r["deaths"] = deaths
	r["score"] = score
	_rebuild()
	score_updated.emit()


func set_hp_state(_peer_id: int, _hp: float) -> void:
	pass  # HP lives in NetMatch; kept as a no-op hook for future per-row HP.


func row_for(peer_id: int) -> Dictionary:
	if not _rows.has(peer_id):
		return {}
	return (_rows[peer_id] as Dictionary).duplicate()


func get_rows_sorted() -> Array:
	# Score desc, kills desc, name asc. Deterministic for the result screen.
	var arr: Array = []
	for pid in _rows.keys():
		var r := (_rows[pid] as Dictionary).duplicate()
		r["peer_id"] = int(pid)
		arr.append(r)
	arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["score"]) != int(b["score"]):
			return int(a["score"]) > int(b["score"])
		if int(a["kills"]) != int(b["kills"]):
			return int(a["kills"]) > int(b["kills"])
		return str(a["name"]) < str(b["name"]))
	return arr


func get_team_scores() -> Array[int]:
	return _team_scores.duplicate()


func serialize() -> Dictionary:
	# Snapshot wire format. Keys are strings (JSON/RPC-safe); NetMatch
	# passes it straight through _rpc_sync_scoreboard.
	var players: Array = []
	for pid in _rows.keys():
		var r := (_rows[pid] as Dictionary).duplicate()
		r["peer_id"] = int(pid)
		players.append(r)
	return {"players": players, "team_scores": _team_scores.duplicate()}


func apply_snapshot(data: Dictionary) -> void:
	_rows.clear()
	_team_scores = [0, 0]
	for entry in data.get("players", []):
		if not (entry is Dictionary):
			continue
		var pid := int(entry.get("peer_id", -1))
		if pid < 0:
			continue
		_rows[pid] = {
			"name": str(entry.get("name", "PLAYER %d" % pid)),
			"team": clampi(int(entry.get("team", 0)), 0, 1),
			"kills": int(entry.get("kills", 0)),
			"deaths": int(entry.get("deaths", 0)),
			"score": int(entry.get("score", 0)),
			"alive": bool(entry.get("alive", true)),
		}
	var ts: Variant = data.get("team_scores", [])
	if ts is Array and ts.size() >= 2:
		_team_scores = [int(ts[0]), int(ts[1])]
	_rebuild()
	score_updated.emit()


func reset() -> void:
	_rows.clear()
	_team_scores = [0, 0]
	_rebuild()


func player_count() -> int:
	return _rows.size()


# --- visibility -------------------------------------------------------------

func toggle_scoreboard() -> void:
	set_scoreboard_visible(not _visible_scoreboard)


func set_scoreboard_visible(on: bool) -> void:
	_visible_scoreboard = on
	visible = on
	scoreboard_visibility_changed.emit(on)


func is_scoreboard_visible() -> bool:
	return _visible_scoreboard


# --- UI ---------------------------------------------------------------------

func _viewport_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(1280, 720)
	return vp.get_visible_rect().size


func _build_ui() -> void:
	StencilStyle.cinematic_background(self, "staging", 0.18, get_viewport().get_camera_3d() != null)
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -340
	_panel.offset_right = 340
	_panel.offset_top = -280
	_panel.offset_bottom = 280
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	add_child(_panel)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	_panel.add_child(vb)
	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	StencilStyle.apply_title(title, StencilStyle.menu_font(30, _viewport_size()),
		StencilStyle.ORANGE, 4)
	title.text = "SCOREBOARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	_team_label = Label.new()
	_team_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	StencilStyle.apply_body(_team_label, StencilStyle.menu_font(24, _viewport_size()),
		StencilStyle.TEXT, 2)
	_team_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_team_label)
	_rows_box = VBoxContainer.new()
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_box.add_theme_constant_override("separation", 4)
	vb.add_child(_rows_box)
	var hint := Label.new()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	StencilStyle.apply_body(hint, StencilStyle.menu_font(16, _viewport_size()),
		StencilStyle.TEXT_DIM, 2)
	hint.text = "TAB TO CLOSE"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)
	_rebuild()


func _rebuild() -> void:
	if _team_label == null or _rows_box == null:
		return
	_team_label.text = "%s %d  —  %d %s" % [
		TEAM_NAMES[0], _team_scores[0], _team_scores[1], TEAM_NAMES[1]]
	for child in _rows_box.get_children():
		child.queue_free()
	var shown := 0
	for r in get_rows_sorted():
		if shown >= MAX_ROWS:
			break
		shown += 1
		var hb := HBoxContainer.new()
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_theme_constant_override("separation", 12)
		_rows_box.add_child(hb)
		var team := int(r["team"])
		var name_l := Label.new()
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		StencilStyle.apply_body(name_l, StencilStyle.menu_font(22, _viewport_size()),
			TEAM_COLORS[team], 2)
		var dead_tag := "" if bool(r["alive"]) else "  [DOWN]"
		name_l.text = (str(r["name"]) + dead_tag).to_upper()
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(name_l)
		for key in ["kills", "deaths", "score"]:
			var col := Label.new()
			col.mouse_filter = Control.MOUSE_FILTER_IGNORE
			StencilStyle.apply_body(col, StencilStyle.menu_font(22, _viewport_size()),
				StencilStyle.TEXT, 2)
			col.text = str(int(r[key]))
			col.custom_minimum_size = Vector2(64, 0)
			col.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			hb.add_child(col)
