# scripts/progression/stats.gd
# FORGEFALL — persistent per-player stats (Goal 6 PROGRESSION, Worker C).
# Autoload "Stats" — registered by the coordinator in project.godot
# (this file deliberately has NO class_name: Godot rejects a class_name
# identical to an autoload singleton name, same as NetManager).
#
# WHAT IT TRACKS (lifetime, persisted to user://stats.json):
# kills / deaths / K-D / wins / losses / accuracy (shots + hits) /
# time played / best Endless wave + score / per-weapon kills /
# per-mode matches (+ wins/losses per mode) / captures / waves cleared /
# puzzles solved / headshot kills.
#
# EVENT API (the only way stats change):
#   record_event(type, data) — type is one of:
#     "kill" / "mp_kill"  data: {"weapon_id": String, "headshot": bool}
#     "death"         (no data)
#     "win" / "match_win" / "loss"  data: {"mode": String} (optional;
#                     falls back to the active match's mode)
#     "match_start"   data: {"mode": String} — counts one match played
#                     for the mode immediately (abandoned matches count).
#     "match_end"     data: {"mode": String, "won": bool, "draw": bool}
#                     — counts the win/loss/draw; same as "win"/"loss"
#                     but explicit. A draw counts neither win nor loss.
#     "capture" / "domination_capture"  (no data) — Domination point captured.
#     "domination_hold"  data: {"points": int} — Domination hold ticks
#                     (1 event per point-sec); accumulates separately,
#                     NOT as captures.
#     "wave_complete" / "wave_cleared"  data: {"wave": int, "mode": String,
#                     "score": int} — best Endless wave/score update only
#                     when the mode is "endless" (from data or the active
#                     match). "wave_cleared" is Progression's survival-wave
#                     name for the same event.
#     "endless_run_over"  data: {"wave": int} — Endless best-wave signal
#                     (best = max(best, wave)); no score carried.
#     "puzzle_complete" (no data)
#     "shot" / "hit"  data: {"weapon_id": String} — accuracy = hits/shots.
#                     Callers record ONE shot per round fired and ONE hit
#                     per round that damaged at least one enemy (not per
#                     pellet), so accuracy = rounds that hit / rounds fired.
#   Plural aliases ("kills", "deaths", "shots", "hits", "wins", "losses",
#   "captures") map to their singular event — Worker D's suite records
#   through record_event("kills") etc. Progression.report_event forwards
#   its own vocabulary (mp_kill, wave_cleared, domination_*, match_win,
#   match_end with draw, endless_run_over) and every forwarded event is
#   accepted here; unknown types warn + return.
# Progression.report_event forwards gameplay events here; weapon/player
# hooks feed shots/hits/deaths directly. Unknown event types are ignored
# with a warning — never a crash. Malformed data is coerced or ignored.
#
# TIME PLAYED: accumulated in _process (in-memory only) and flushed to
# disk at most once per SAVE_INTERVAL_S, on match end, and on quit —
# never a per-frame disk write.
#
# PERSISTENCE: user://stats.json, SCHEMA_VERSION 1. Loading is
# version-tolerant: a missing / malformed / old file falls back to
# defaults field-by-field (unknown keys ignored, missing keys defaulted),
# so an old save can never crash the game.
extends Node

signal stats_changed

const SAVE_PATH := "user://stats.json"
const SCHEMA_VERSION := 1
## Flush at most this often while the game runs (seconds).
const SAVE_INTERVAL_S := 60.0
## Modes the per-mode table tracks; anything else buckets to "other"
## so a garbage mode string can never grow the save file unboundedly.
const KNOWN_MODES := ["survival", "domination", "endless", "tdm", "puzzle", "multiplayer"]
const MAX_WEAPON_ENTRIES := 64
const MAX_ID_LEN := 64

# --- Lifetime totals -------------------------------------------------------
var kills: int = 0
var deaths: int = 0
var wins: int = 0
var losses: int = 0
var draws: int = 0
var shots: int = 0
var hits: int = 0
var captures: int = 0
var domination_hold_points: int = 0
var waves_completed: int = 0
var puzzles_completed: int = 0
var headshot_kills: int = 0
var time_played_s: float = 0.0
var best_endless_wave: int = 0
var best_endless_score: int = 0
## {weapon_id: kills}
var per_weapon_kills: Dictionary = {}
## {mode: {"matches": int, "wins": int, "losses": int, "draws": int}}
var per_mode: Dictionary = {}

# --- Session state (not persisted) -----------------------------------------
var _save_timer: float = 0.0
var _dirty: bool = false
var _match_active: bool = false
var _match_mode: String = ""


func _ready() -> void:
	_load()


func _process(delta: float) -> void:
	time_played_s += maxf(delta, 0.0)
	_save_timer += maxf(delta, 0.0)
	if _dirty and _save_timer >= SAVE_INTERVAL_S:
		save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _dirty:
			save()


# --- Event API -------------------------------------------------------------

## Record one gameplay event. Never crashes on bad input: unknown types
## warn + return, malformed data is coerced or ignored.
func record_event(type: String, data: Dictionary = {}) -> void:
	# Plural aliases (see header).
	match type:
		"kills":
			type = "kill"
		"deaths":
			type = "death"
		"shots":
			type = "shot"
		"hits":
			type = "hit"
		"wins":
			type = "win"
		"losses":
			type = "loss"
		"captures":
			type = "capture"
	match type:
		"kill", "mp_kill":
			kills += 1
			var wid := _weapon_id(data)
			per_weapon_kills[wid] = int(per_weapon_kills.get(wid, 0)) + 1
			if bool(data.get("headshot", false)):
				headshot_kills += 1
		"death":
			deaths += 1
		"win", "match_win":
			wins += 1
			_end_match_record(true, _event_mode(data))
		"loss":
			losses += 1
			_end_match_record(false, _event_mode(data))
		"match_start":
			_begin_match(_event_mode(data))
		"match_end":
			if bool(data.get("draw", false)):
				draws += 1
				_end_match_record_draw(_event_mode(data))
			elif bool(data.get("won", false)):
				wins += 1
				_end_match_record(true, _event_mode(data))
			else:
				losses += 1
				_end_match_record(false, _event_mode(data))
		"capture", "domination_capture":
			captures += 1
		"domination_hold":
			domination_hold_points += maxi(0, _as_int(data.get("points", 0), 0))
		"wave_complete", "wave_cleared":
			waves_completed += 1
			var mode := _event_mode(data)
			if mode == "endless":
				var wave := _as_int(data.get("wave", 0), 0)
				if wave > best_endless_wave:
					best_endless_wave = wave
				if data.has("score"):
					var score := _as_int(data.get("score", 0), 0)
					if score > best_endless_score:
						best_endless_score = score
		"endless_run_over":
			var run_wave := _as_int(data.get("wave", 0), 0)
			if run_wave > best_endless_wave:
				best_endless_wave = run_wave
		"puzzle_complete":
			puzzles_completed += 1
		"shot":
			shots += 1
		"hit":
			hits += 1
		_:
			push_warning("Stats: ignoring unknown event type '%s'." % type)
			return
	_mark_dirty()


## Convenience wrappers (same as record_event with the matching type).
func record_kill(weapon_id: String, headshot: bool = false) -> void:
	record_event("kill", {"weapon_id": weapon_id, "headshot": headshot})


## Count-based recorders (Worker D's suite calls record_kills(n) etc.).
func record_kills(count: int = 1) -> void:
	for i in maxi(count, 0):
		record_event("kill", {"weapon_id": "unknown"})


func record_deaths(count: int = 1) -> void:
	for i in maxi(count, 0):
		record_event("death")


func record_shots(count: int = 1) -> void:
	for i in maxi(count, 0):
		record_event("shot", {"weapon_id": "unknown"})


func record_hits(count: int = 1) -> void:
	for i in maxi(count, 0):
		record_event("hit", {"weapon_id": "unknown"})


func record_death() -> void:
	record_event("death")


func record_shot(weapon_id: String) -> void:
	record_event("shot", {"weapon_id": weapon_id})


func record_hit(weapon_id: String) -> void:
	record_event("hit", {"weapon_id": weapon_id})


func start_match(mode: String) -> void:
	record_event("match_start", {"mode": mode})


func end_match(won: bool, mode: String = "") -> void:
	record_event("match_end", {"mode": mode, "won": won})


# --- Derived values ----------------------------------------------------------

## Kills / deaths. Zero deaths => returns kills (never inf / NaN).
func kd_ratio() -> float:
	if deaths <= 0:
		return float(kills)
	return float(kills) / float(deaths)


## Hits / shots as a 0.0–1.0 fraction. Zero shots => 0.0 (never NaN).
func accuracy() -> float:
	if shots <= 0:
		return 0.0
	return float(hits) / float(shots)


## Alias for accuracy() (Worker D's suite probes get_accuracy).
func get_accuracy() -> float:
	return accuracy()


## Single-counter lookup by key ("kills", "deaths", "wins", ...).
## Unknown keys return 0. Backs Worker D's get_stat probe; UI code
## should prefer the typed properties / get_stats().
func get_stat(key: String) -> int:
	match key:
		"kills":
			return kills
		"deaths":
			return deaths
		"wins":
			return wins
		"losses":
			return losses
		"draws":
			return draws
		"shots":
			return shots
		"hits":
			return hits
		"captures":
			return captures
		"domination_hold_points":
			return domination_hold_points
		"waves_completed":
			return waves_completed
		"puzzles_completed":
			return puzzles_completed
		"headshot_kills":
			return headshot_kills
		"time_played_s":
			return int(time_played_s)
		"best_endless_wave":
			return best_endless_wave
		"best_endless_score":
			return best_endless_score
		_:
			return 0


## Where stats persist (Worker D's suite probes get_save_path).
func get_save_path() -> String:
	return SAVE_PATH


## Re-read user://stats.json into memory (defaults on any bad file).
## The autoload already loads on _ready; this is for probes / UI refresh.
func load_stats() -> void:
	_load()


## Deep copy of the full stats snapshot (safe to hand to UI).
func get_stats() -> Dictionary:
	return _snapshot()


func get_per_weapon_kills() -> Dictionary:
	return per_weapon_kills.duplicate(true)


func get_per_mode() -> Dictionary:
	return per_mode.duplicate(true)


## "12h 34m" / "45m 10s" / "3m 05s" / "42s". Static so UI can format
## a snapshot without an autoload instance.
static func format_time(seconds: float) -> String:
	var total := maxi(0, int(seconds))
	var h := total / 3600
	var m := (total % 3600) / 60
	var s := total % 60
	if h > 0:
		return "%dh %02dm" % [h, m]
	if m > 0:
		return "%dm %02ds" % [m, s]
	return "%ds" % s


## Reset everything to defaults and persist immediately.
func reset_stats() -> void:
	_apply_snapshot(default_stats())
	_match_active = false
	_match_mode = ""
	save()
	_mark_dirty()


# --- Persistence -------------------------------------------------------------

## Write the current stats to user://stats.json. Never crashes: a failed
## write warns and the in-memory stats stay live.
func save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("Stats: could not open %s for writing." % SAVE_PATH)
		return
	f.store_string(JSON.stringify(_snapshot()))
	_dirty = false
	_save_timer = 0.0


## Flush pending changes to disk now (no-op when nothing changed).
func flush() -> void:
	if _dirty:
		save()


## Read user://stats.json and return a sanitized snapshot. Works without
## an autoload instance, so the stats screen can render even if Stats
## was never registered. Missing / malformed / old file => defaults.
static func load_snapshot() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return default_stats()
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return default_stats()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return sanitize(parsed)


## Delete the stats file (used by the stats screen's RESET when no
## autoload instance exists). Missing file is fine.
static func reset_file() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var err := DirAccess.remove_absolute(SAVE_PATH)
		if err != OK:
			push_warning("Stats: could not delete %s (err %d)." % [SAVE_PATH, err])


## Full defaults for every field (the migration target for old saves).
static func default_stats() -> Dictionary:
	return {
		"version": SCHEMA_VERSION,
		"kills": 0,
		"deaths": 0,
		"wins": 0,
		"losses": 0,
		"draws": 0,
		"shots": 0,
		"hits": 0,
		"captures": 0,
		"domination_hold_points": 0,
		"waves_completed": 0,
		"puzzles_completed": 0,
		"headshot_kills": 0,
		"time_played_s": 0.0,
		"best_endless_wave": 0,
		"best_endless_score": 0,
		"per_weapon_kills": {},
		"per_mode": {},
	}


## Validate + migrate one raw parsed-JSON value into a full snapshot.
## Anything non-Dictionary => defaults. Unknown keys ignored, missing
## keys defaulted, wrong-typed values coerced or defaulted, negatives
## clamped to 0. Never crashes on hostile input.
static func sanitize(raw: Variant) -> Dictionary:
	var out := default_stats()
	if not (raw is Dictionary):
		return out
	var d := raw as Dictionary
	for key in ["kills", "deaths", "wins", "losses", "draws", "shots", "hits",
			"captures", "domination_hold_points", "waves_completed",
			"puzzles_completed", "headshot_kills", "best_endless_wave",
			"best_endless_score"]:
		if d.has(key):
			out[key] = maxi(0, _as_int(d.get(key), 0))
	if d.has("time_played_s"):
		out["time_played_s"] = maxf(0.0, _as_float(d.get("time_played_s"), 0.0))
	if d.get("per_weapon_kills") is Dictionary:
		var weapons := d["per_weapon_kills"] as Dictionary
		var clean_weapons: Dictionary = {}
		for wid in weapons:
			if clean_weapons.size() >= MAX_WEAPON_ENTRIES:
				break
			var wkey := str(wid).strip_edges()
			if wkey.is_empty():
				continue
			clean_weapons[wkey.left(MAX_ID_LEN)] = maxi(0, _as_int(weapons[wid], 0))
		out["per_weapon_kills"] = clean_weapons
	if d.get("per_mode") is Dictionary:
		var modes := d["per_mode"] as Dictionary
		var clean_modes: Dictionary = {}
		for m in modes:
			var mkey := _norm_mode_static(m)
			if mkey.is_empty() or clean_modes.has(mkey):
				continue
			if not (modes[m] is Dictionary):
				continue
			var entry := modes[m] as Dictionary
			clean_modes[mkey] = {
				"matches": maxi(0, _as_int(entry.get("matches", 0), 0)),
				"wins": maxi(0, _as_int(entry.get("wins", 0), 0)),
				"losses": maxi(0, _as_int(entry.get("losses", 0), 0)),
				"draws": maxi(0, _as_int(entry.get("draws", 0), 0)),
			}
		out["per_mode"] = clean_modes
	return out


# --- Internals ---------------------------------------------------------------

func _load() -> void:
	_apply_snapshot(load_snapshot())


func _apply_snapshot(snap: Dictionary) -> void:
	kills = _as_int(snap.get("kills", 0), 0)
	deaths = _as_int(snap.get("deaths", 0), 0)
	wins = _as_int(snap.get("wins", 0), 0)
	losses = _as_int(snap.get("losses", 0), 0)
	draws = _as_int(snap.get("draws", 0), 0)
	shots = _as_int(snap.get("shots", 0), 0)
	hits = _as_int(snap.get("hits", 0), 0)
	captures = _as_int(snap.get("captures", 0), 0)
	domination_hold_points = _as_int(snap.get("domination_hold_points", 0), 0)
	waves_completed = _as_int(snap.get("waves_completed", 0), 0)
	puzzles_completed = _as_int(snap.get("puzzles_completed", 0), 0)
	headshot_kills = _as_int(snap.get("headshot_kills", 0), 0)
	time_played_s = _as_float(snap.get("time_played_s", 0.0), 0.0)
	best_endless_wave = _as_int(snap.get("best_endless_wave", 0), 0)
	best_endless_score = _as_int(snap.get("best_endless_score", 0), 0)
	per_weapon_kills = (snap.get("per_weapon_kills", {}) as Dictionary).duplicate(true)
	per_mode = (snap.get("per_mode", {}) as Dictionary).duplicate(true)
	_dirty = false
	_save_timer = 0.0


func _snapshot() -> Dictionary:
	return {
		"version": SCHEMA_VERSION,
		"kills": kills,
		"deaths": deaths,
		"wins": wins,
		"losses": losses,
		"draws": draws,
		"shots": shots,
		"hits": hits,
		"captures": captures,
		"domination_hold_points": domination_hold_points,
		"waves_completed": waves_completed,
		"puzzles_completed": puzzles_completed,
		"headshot_kills": headshot_kills,
		"time_played_s": time_played_s,
		"best_endless_wave": best_endless_wave,
		"best_endless_score": best_endless_score,
		"per_weapon_kills": per_weapon_kills.duplicate(true),
		"per_mode": per_mode.duplicate(true),
	}


func _mark_dirty() -> void:
	_dirty = true
	stats_changed.emit()


## Mode for an event: explicit data["mode"] wins, else the active match's
## mode, else "" (no per-mode attribution).
func _event_mode(data: Dictionary) -> String:
	if data.has("mode"):
		var m := _norm_mode(data.get("mode", ""))
		if not m.is_empty():
			return m
	return _match_mode


func _begin_match(mode: String) -> void:
	var m := _norm_mode(mode)
	if m.is_empty():
		m = "other"
	_match_active = true
	_match_mode = m
	var entry: Dictionary = _mode_entry(m)
	entry["matches"] = int(entry.get("matches", 0)) + 1
	per_mode[m] = entry


func _end_match_record(won: bool, mode: String) -> void:
	var m := _norm_mode(mode)
	if m.is_empty():
		if _match_active:
			m = _match_mode
		else:
			_match_active = false
			return
	var entry: Dictionary = _mode_entry(m)
	if won:
		entry["wins"] = int(entry.get("wins", 0)) + 1
	else:
		entry["losses"] = int(entry.get("losses", 0)) + 1
	per_mode[m] = entry
	_match_active = false
	_match_mode = ""


func _mode_entry(mode: String) -> Dictionary:
	if per_mode.get(mode) is Dictionary:
		var existing := (per_mode[mode] as Dictionary).duplicate()
		# Pre-draws saves lack "draws" — default it so increments work.
		if not existing.has("draws"):
			existing["draws"] = 0
		return existing
	return {"matches": 0, "wins": 0, "losses": 0, "draws": 0}


## Draw variant of _end_match_record: per-mode draws += 1, lifetime
## draws already counted by the caller.
func _end_match_record_draw(mode: String) -> void:
	var m := _norm_mode(mode)
	if m.is_empty():
		if _match_active:
			m = _match_mode
		else:
			_match_active = false
			return
	var entry: Dictionary = _mode_entry(m)
	entry["draws"] = int(entry.get("draws", 0)) + 1
	per_mode[m] = entry
	_match_active = false
	_match_mode = ""


func _weapon_id(data: Dictionary) -> String:
	var wid := str(data.get("weapon_id", "unknown")).strip_edges()
	if wid.is_empty():
		wid = "unknown"
	return wid.left(MAX_ID_LEN)


func _norm_mode(raw: Variant) -> String:
	return _norm_mode_static(raw)


## Lowercase + strip; known modes pass through, anything else non-empty
## buckets to "other", empty stays empty (caller decides the fallback).
static func _norm_mode_static(raw: Variant) -> String:
	var m := str(raw).strip_edges().to_lower()
	if m.is_empty():
		return ""
	if m in KNOWN_MODES:
		return m
	return "other"


static func _as_int(v: Variant, fallback: int) -> int:
	if v is int:
		return v as int
	if v is float:
		return int(v as float)
	if v is String:
		if (v as String).is_valid_int():
			return int(v as String)
	return fallback


static func _as_float(v: Variant, fallback: float) -> float:
	if v is float:
		return v as float
	if v is int:
		return float(v as int)
	if v is String:
		if (v as String).is_valid_float():
			return float(v as String)
	return fallback
