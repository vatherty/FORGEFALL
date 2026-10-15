# verify_progression.gd — headless verification for FORGEFALL Goal 6 (PROGRESSION).
# Usage: godot --headless --path <project> --script res://tools/verify_progression.gd
#
# Worker D (Verification). Owns ONLY this file. Never fixes game code: bugs
# found here are reported with file + line, not patched.
#
# Coverage (discovery-based, NOT hardcoded to worker file names — the checks
# probe the live tree / live objects, so Worker A/B/C landings are judged on
# what actually exists):
#   P0 DISCOVERY: progression / loadouts / stats implementation files exist.
#   P1 XP: fabricated events through the real Progression API award XP —
#      kills, Domination captures/holds, match wins, wave survival, puzzle
#      completion. XP never decreases from zero/negative awards.
#   P2 LEVELS/UNLOCKS: level thresholds are monotonic; boundary checks at
#      just-below / at / just-above each probed unlock level; locked content
#      stays locked below its level and stays unlocked above it.
#   P3 LOADOUTS: save/load round-trip, overwrite, persistence across a
#      simulated restart (fresh instance, same user:// file), selected
#      loadout round-trip when the API has one.
#   P4 MENU: main-menu LOADOUT button opens a picker; NO visible
#      "COMING SOON" state remains anywhere on the main-menu path.
#   P5 STATS: counters accumulate, persist across a simulated restart, and
#      old (partial-key) / missing / malformed save files load gracefully
#      (no crash, sane defaults).
#   P6 INTEGRATION: Progression / Loadouts / Stats registered as autoloads
#      in project.godot; save files live under user://.
#
# API COMPATIBILITY: the workers' exact method names were not frozen when
# this suite was written, so every capability is probed through an ALIAS
# LIST (e.g. award_xp / add_xp / grant_xp / award_event). A capability
# counts as present if ANY alias answers. Calls are arity-aware (via
# get_method_list) so a probed call never errors on argument count.
#
# HONEST REPORTING (never faked as passes):
#   - A feature whose file/API is absent is reported as MISSING (counts as
#     a failure with a MISSING label + the evidence: file absent / API
#     absent) — not as a crash, not as a pass.
#   - Autoload registration is expected to be MISSING on the first run:
#     the coordinator registers the new autoloads at integration AFTER
#     this suite runs, and re-runs the suite then.
#   - Loadout validation (bogus weapon id / empty name rejected) is WARN
#     only: the spec requires save/load/persist, not a particular
#     validation policy. A bogus id that later crashes equip is still
#     worth flagging.
#   - Real on-device feel (does the picker feel right on the S23, does XP
#     pacing feel rewarding) is Colin's verdict — headless checks prove
#     the math and the persistence, not the feel.
#
# Exit 0 = all checks pass. Any FAIL / MISSING prints and exits 1.
extends SceneTree

var _pass := 0
var _fail := 0
var _missing := 0
var _warns := 0
var _sec: Dictionary = {}
var _frames := 0
var _stage := 0

# Discovery results (res:// paths, "" when absent).
var _prog_path := ""
var _loadouts_path := ""
var _stats_path := ""
var _prog_source := ""
var _loadouts_source := ""
var _stats_source := ""
var _menu: Control = null
var _menu_picker_found := false
var _menu_script_ok := false
var _backups: Dictionary = {}  # user:// path -> original bytes (String) or null


# ---------------------------------------------------------------- helpers

func _check(section: String, cond: bool, label: String) -> void:
	var c: Array = _sec.get(section, [0, 0])
	if cond:
		_pass += 1
		c[0] += 1
		print("PASS [%s]: %s" % [section, label])
	else:
		_fail += 1
		c[1] += 1
		printerr("FAIL [%s]: %s" % [section, label])
	_sec[section] = c


func _check_missing(section: String, label: String) -> void:
	_missing += 1
	_check(section, false, "MISSING: " + label)


func _warn(section: String, label: String) -> void:
	_warns += 1
	print("WARN [%s]: %s" % [section, label])


func _skip(section: String, label: String) -> void:
	print("SKIP [%s]: %s" % [section, label])


func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _scan_dir(dir_path: String, needles: Array, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		if not f.ends_with(".gd"):
			continue
		var low := f.to_lower()
		for n in needles:
			if low.contains(str(n)):
				out.append(dir_path + "/" + f)
				break
	for sub in d.get_directories():
		if sub == ".godot" or sub == ".git":
			continue
		_scan_dir(dir_path + "/" + sub, needles, out)


func _method_arity(obj: Object, method: String) -> int:
	for m in obj.get_method_list():
		if str(m.get("name", "")) == method:
			var args: Array = m.get("args", [])
			return args.size()
	return -1


## Calls `method` if it exists, trimming/padding args to the declared arity.
## Returns [called: bool, result].
func _call_ar(obj: Object, method: String, args: Array) -> Array:
	if obj == null or not obj.has_method(method):
		return [false, null]
	var arity := _method_arity(obj, method)
	if arity < 0:
		return [false, null]
	var use: Array = args.duplicate()
	while use.size() > arity:
		use.pop_back()
	while use.size() < arity:
		use.append(_default_for_arg(obj, method, use.size()))
	return [true, obj.callv(method, use)]


func _default_for_arg(obj: Object, method: String, idx: int) -> Variant:
	for m in obj.get_method_list():
		if str(m.get("name", "")) == method:
			var args: Array = m.get("args", [])
			if idx < args.size():
				var t: int = int(args[idx].get("type", TYPE_NIL))
				match t:
					TYPE_BOOL:
						return false
					TYPE_INT:
						return 0
					TYPE_FLOAT:
						return 0.0
					TYPE_STRING, TYPE_STRING_NAME:
						return ""
					TYPE_VECTOR2:
						return Vector2.ZERO
					TYPE_VECTOR3:
						return Vector3.ZERO
					TYPE_ARRAY:
						return []
					TYPE_DICTIONARY:
						return {}
	return 0


func _first_method(obj: Object, aliases: Array) -> String:
	for a in aliases:
		if obj.has_method(str(a)):
			return str(a)
	return ""


func _get_prop(obj: Object, names: Array) -> Array:
	# Returns [found: bool, value]. Property access via get() is safe for
	# missing properties (returns null) — but null is ambiguous, so also
	# check the property list.
	var props := {}
	for p in obj.get_property_list():
		props[str(p.get("name", ""))] = true
	for n in names:
		if props.has(str(n)):
			return [true, obj.get(str(n))]
	return [false, null]


func _set_prop(obj: Object, names: Array, value: Variant) -> bool:
	var props := {}
	for p in obj.get_property_list():
		props[str(p.get("name", ""))] = true
	for n in names:
		if props.has(str(n)):
			obj.set(str(n), value)
			return true
	return false


## Instantiate a script manually (simulates autoload registration, which
## the coordinator does AFTER this suite's first run). Returns null when
## the file is absent or fails to load / instantiate.
func _instantiate(path: String, node_name: String) -> Object:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var scr = load(path)
	if scr == null:
		return null
	var inst = (scr as Script).new()
	if inst == null:
		return null
	if inst is Node:
		(inst as Node).name = node_name
		root.add_child(inst as Node)
	return inst


func _free_inst(inst: Object) -> void:
	if inst == null:
		return
	if inst is Node:
		var n := inst as Node
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.free()
	# RefCounted instances drop with the last reference.


func _backup_user_file(path: String) -> void:
	if path.is_empty() or _backups.has(path):
		return
	if FileAccess.file_exists(path):
		_backups[path] = _read_file(path)
	else:
		_backups[path] = null


func _restore_user_files() -> void:
	for path in _backups.keys():
		_restore_user_file(str(path))
	_backups.clear()


func _restore_user_file(path: String) -> void:
	if not _backups.has(path):
		return
	var orig = _backups[path]
	if orig == null:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	else:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(str(orig))
	_backups.erase(path)


## Delete a user:// save file (state isolation: every probe that sets an
## ABSOLUTE value must start from a clean file, because worker
## implementations auto-load on _ready and auto-save on mutation — a
## "fresh" instance otherwise inherits the previous probe's state).
func _clear_save_file(path: String) -> void:
	if path.is_empty():
		return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## First user:// save path mentioned in a worker's source (their SAVE_PATH).
func _save_path_from_source(source: String) -> String:
	var re := RegEx.new()
	re.compile("user://[A-Za-z0-9_\\-./]+\\.(json|cfg|tres|dat)")
	var m := re.search(source)
	if m != null:
		return m.get_string(0)
	return ""


## Delete the save file, then instantiate: a guaranteed-fresh probe.
func _fresh_instance(path: String, node_name: String, save_path: String) -> Object:
	_clear_save_file(save_path)
	return _instantiate(path, node_name)


func _write_user_file(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)


func _find_user_path(obj: Object, source: String, candidates: Array) -> String:
	# 1. Live API: get_save_path() / save_path property / SAVE_PATH const.
	var r := _call_ar(obj, "get_save_path", [])
	if r[0] and r[1] is String and str(r[1]).begins_with("user://"):
		return str(r[1])
	var pr := _get_prop(obj, ["save_path", "SAVE_PATH", "save_file", "SAVE_FILE"])
	if pr[0] and pr[1] is String and str(pr[1]).begins_with("user://"):
		return str(pr[1])
	# 2. Source scan for a user:// literal.
	var re := RegEx.new()
	re.compile("user://[A-Za-z0-9_\\-./]+\\.(json|cfg|tres|dat)")
	var m := re.search(source)
	if m != null:
		return m.get_string(0)
	# 3. First candidate that already exists on disk.
	for c in candidates:
		if FileAccess.file_exists(str(c)):
			return str(c)
	return ""


# ---------------------------------------------------------------- P0 discovery

func _discover() -> void:
	var prog_hits: Array = []
	var load_hits: Array = []
	var stat_hits: Array = []
	_scan_dir("res://scripts", ["progression"], prog_hits)
	_scan_dir("res://scripts", ["loadout"], load_hits)
	_scan_dir("res://scripts", ["stats", "player_stats", "stat_tracker"], stat_hits)
	_scan_dir("res://scripts", ["xp", "unlock"], prog_hits)
	var prog_candidates := [
		"res://scripts/core/progression.gd",
		"res://scripts/progression/progression.gd",
		"res://scripts/core/progression_system.gd",
		"res://scripts/progression.gd",
	]
	var load_candidates := [
		"res://scripts/core/loadouts.gd",
		"res://scripts/loadouts/loadouts.gd",
		"res://scripts/core/loadout_manager.gd",
		"res://scripts/ui/loadout_picker.gd",
		"res://scenes/ui/loadout_picker.tscn",
	]
	var stat_candidates := [
		"res://scripts/core/stats.gd",
		"res://scripts/stats/stats.gd",
		"res://scripts/core/player_stats.gd",
		"res://scripts/core/stats_tracker.gd",
	]
	for c in prog_candidates:
		if FileAccess.file_exists(c) and not prog_hits.has(c):
			prog_hits.append(c)
	for c in load_candidates:
		if FileAccess.file_exists(c) and not load_hits.has(c):
			load_hits.append(c)
	for c in stat_candidates:
		if FileAccess.file_exists(c) and not stat_hits.has(c):
			stat_hits.append(c)
	_prog_path = str(prog_hits[0]) if not prog_hits.is_empty() else ""
	_loadouts_path = str(load_hits[0]) if not load_hits.is_empty() else ""
	_stats_path = str(stat_hits[0]) if not stat_hits.is_empty() else ""
	if not _prog_path.is_empty() and _prog_path.ends_with(".gd"):
		_prog_source = _read_file(_prog_path)
	if not _loadouts_path.is_empty() and _loadouts_path.ends_with(".gd"):
		_loadouts_source = _read_file(_loadouts_path)
	if not _stats_path.is_empty() and _stats_path.ends_with(".gd"):
		_stats_source = _read_file(_stats_path)
	if _prog_path.is_empty():
		_check_missing("discovery", "no progression implementation file (looked for scripts/**/progression*.gd, *xp*.gd, *unlock*.gd)")
	else:
		_check("discovery", true, "progression file found: " + _prog_path)
	if _loadouts_path.is_empty():
		_check_missing("discovery", "no loadouts implementation file (looked for scripts/**/loadout*.gd, scenes/ui/loadout_picker.tscn)")
	else:
		_check("discovery", true, "loadouts file found: " + _loadouts_path)
	if _stats_path.is_empty():
		_check_missing("discovery", "no stats implementation file (looked for scripts/**/stats*.gd, *player_stats*.gd)")
	else:
		_check("discovery", true, "stats file found: " + _stats_path)


# ---------------------------------------------------------------- P1 XP

const _XP_EVENT_ALIASES := {
	"kill": ["award_kill", "on_kill", "record_kill", "award_kill_xp", "on_enemy_killed", "add_kill_xp"],
	"headshot_kill": ["award_headshot", "on_headshot_kill", "record_headshot", "award_headshot_xp"],
	"capture": ["award_capture", "on_capture", "record_capture", "award_capture_xp", "on_point_captured"],
	"hold": ["award_hold", "on_hold", "record_hold", "award_hold_xp", "on_point_held"],
	"match_win": ["award_match_win", "on_match_win", "record_win", "award_win_xp", "on_match_won", "on_victory"],
	"wave_survived": ["award_wave", "on_wave_survived", "record_wave_clear", "award_wave_xp", "on_wave_cleared", "on_wave_complete"],
	"puzzle_complete": ["award_puzzle", "on_puzzle_complete", "record_puzzle_complete", "award_puzzle_xp", "on_chamber_complete"],
}
const _XP_EVENT_NAMES := {
	"kill": ["kill", "enemy_kill", "kill_enemy"],
	"headshot_kill": ["headshot", "headshot_kill"],
	"capture": ["capture", "domination_capture", "point_capture"],
	"hold": ["hold", "domination_hold", "point_hold"],
	"match_win": ["match_win", "win", "victory", "match_victory"],
	"wave_survived": ["wave_survived", "wave_clear", "wave_complete", "survive_wave", "wave"],
	"puzzle_complete": ["puzzle_complete", "puzzle", "chamber_complete", "puzzle_solved"],
}


func _get_xp(obj: Object) -> Array:
	var r := _call_ar(obj, "get_xp", [])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	r = _call_ar(obj, "get_total_xp", [])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	r = _call_ar(obj, "get_experience", [])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	var pr := _get_prop(obj, ["xp", "total_xp", "experience", "current_xp"])
	if pr[0] and (pr[1] is int or pr[1] is float):
		return [true, int(pr[1])]
	return [false, 0]


func _set_xp(obj: Object, value: int) -> bool:
	var r := _call_ar(obj, "set_xp", [value])
	if r[0]:
		return true
	r = _call_ar(obj, "set_total_xp", [value])
	if r[0]:
		return true
	r = _call_ar(obj, "set_experience", [value])
	if r[0]:
		return true
	if _set_prop(obj, ["xp", "total_xp", "experience", "current_xp"], value):
		return true
	return false


## Award one event of `category` on a FRESH progression instance and return
## the XP delta. Tries specific methods, then generic add/award, then
## event-name dispatch. Returns -1 when no award API answers at all.
func _award_event_delta(category: String) -> int:
	var inst := _fresh_instance(_prog_path, "ProgProbe", _save_path_from_source(_prog_source))
	if inst == null:
		return -1
	var before := _get_xp(inst)
	if not before[0]:
		_free_inst(inst)
		return -1
	var awarded := false
	for m in _XP_EVENT_ALIASES.get(category, []):
		var r := _call_ar(inst, str(m), [])
		if r[0]:
			awarded = true
			break
	if not awarded:
		for m in ["award_xp", "add_xp", "grant_xp", "add_experience", "award_experience", "give_xp"]:
			var r := _call_ar(inst, m, [100])
			if r[0]:
				awarded = true
				break
			r = _call_ar(inst, m, [100, category])
			if r[0]:
				awarded = true
				break
	if not awarded:
		for m in ["award_event", "record_event", "award_for_event", "on_event"]:
			for ev_name in _XP_EVENT_NAMES.get(category, []):
				var r := _call_ar(inst, m, [str(ev_name)])
				if r[0]:
					awarded = true
					break
			if awarded:
				break
	var after := _get_xp(inst)
	_free_inst(inst)
	if not awarded or not after[0]:
		return -1
	return int(after[1]) - int(before[1])


func _check_xp() -> void:
	if _prog_path.is_empty():
		for ev in ["kill", "capture", "hold", "match_win", "wave_survived", "puzzle_complete"]:
			_check_missing("xp", "XP award for '%s' — no progression implementation to call" % ev)
		_check_missing("xp", "XP never decreases on zero/negative award — no progression implementation")
		return
	var any_api := false
	for ev in ["kill", "capture", "hold", "match_win", "wave_survived", "puzzle_complete"]:
		var delta := _award_event_delta(ev)
		if delta < 0:
			_check_missing("xp", "XP award for '%s' — no award API answered (file: %s)" % [ev, _prog_path])
		else:
			any_api = true
			_check("xp", delta > 0, "XP award for '%s' increases XP (delta=%d)" % [ev, delta])
	_check_xp_exact()
	if any_api:
		# Headshot should pay at least as much as a plain kill when the API
		# distinguishes them; if it does not distinguish, both deltas come
		# from the same generic path and this check is skipped.
		var has_specific_headshot := false
		var probe := _instantiate(_prog_path, "ProgProbeHS")
		if probe != null:
			for m in _XP_EVENT_ALIASES.get("headshot_kill", []):
				if probe.has_method(str(m)):
					has_specific_headshot = true
					break
			_free_inst(probe)
		if has_specific_headshot:
			var d_kill := _award_event_delta("kill")
			var d_hs := _award_event_delta("headshot_kill")
			_check("xp", d_hs >= d_kill, "headshot kill XP (%d) >= plain kill XP (%d)" % [d_hs, d_kill])
		else:
			_skip("xp", "headshot-vs-kill comparison (no headshot-specific award API)")
		# Zero / negative awards must not reduce XP (generic path only).
		var inst := _fresh_instance(_prog_path, "ProgProbeNeg", _save_path_from_source(_prog_source))
		if inst != null:
			var before := _get_xp(inst)
			var generic := _first_method(inst, ["award_xp", "add_xp", "grant_xp", "add_experience", "award_experience", "give_xp"])
			if before[0] and not generic.is_empty():
				_call_ar(inst, generic, [0])
				_call_ar(inst, generic, [-50])
				var after := _get_xp(inst)
				_check("xp", after[0] and int(after[1]) == int(before[1]), "zero/negative award does not reduce XP (before=%d after=%d)" % [int(before[1]), int(after[1]) if after[0] else -1])
			else:
				_skip("xp", "zero/negative award guard (no generic add API to abuse)")
			_free_inst(inst)


## Exact XP amounts through the real event intake (report_event), when the
## worker exposes it. Amounts are the worker's documented XP SOURCES.
## Each probe uses a fresh instance (clean save file) so deltas are exact.
func _check_xp_exact() -> void:
	var probe := _instantiate(_prog_path, "ProgExactProbe")
	if probe == null:
		return
	var has_report := probe.has_method("report_event")
	_free_inst(probe)
	if not has_report:
		_skip("xp", "exact per-event amounts (no report_event intake)")
		return
	var table: Array = [
		["kill", {}, 100],
		["kill", {"headshot": true}, 150],
		["kill", {"enemy_type": "brute"}, 200],
		["kill", {"enemy_type": "warlord"}, 500],
		["domination_capture", {}, 150],
		["domination_hold", {"points": 3}, 15],
		["match_win", {}, 500],
		["match_end", {"won": true}, 500],
		["match_end", {"draw": true}, 150],
		["match_end", {}, 50],
		["wave_cleared", {"wave": 2}, 150],
		["endless_run_over", {"wave": 4}, 300],
		["puzzle_complete", {"room_id": "chamber_01"}, 300],
		["nonsense_xyz", {}, 0],
	]
	for row in table:
		var ev: String = str(row[0])
		var data: Dictionary = row[1] as Dictionary
		var expected: int = int(row[2])
		var inst := _fresh_instance(_prog_path, "ProgExact", _save_path_from_source(_prog_source))
		if inst == null:
			_check_missing("xp", "exact XP for '%s' — instance failed" % ev)
			continue
		var before := _get_xp(inst)
		_call_ar(inst, "report_event", [ev, data])
		var after := _get_xp(inst)
		_free_inst(inst)
		if not before[0] or not after[0]:
			_check_missing("xp", "exact XP for '%s' — no XP getter" % ev)
			continue
		var delta := int(after[1]) - int(before[1])
		_check("xp", delta == expected, "report_event('%s', %s) awards exactly %d XP (got %d)" % [ev, str(data), expected, delta])
	# Puzzle replay pays 0: same instance, same room twice.
	var inst2 := _fresh_instance(_prog_path, "ProgReplay", _save_path_from_source(_prog_source))
	if inst2 != null:
		_call_ar(inst2, "report_event", ["puzzle_complete", {"room_id": "chamber_02"}])
		var mid := _get_xp(inst2)
		_call_ar(inst2, "report_event", ["puzzle_complete", {"room_id": "chamber_02"}])
		var end := _get_xp(inst2)
		_free_inst(inst2)
		if mid[0] and end[0]:
			_check("xp", int(end[1]) - int(mid[1]) == 0, "puzzle replay (same chamber) awards 0 XP")


# ---------------------------------------------------------------- P2 levels / unlocks

func _get_level(obj: Object) -> Array:
	var r := _call_ar(obj, "get_level", [])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	r = _call_ar(obj, "current_level", [])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	var pr := _get_prop(obj, ["level", "current_level", "player_level"])
	if pr[0] and (pr[1] is int or pr[1] is float):
		return [true, int(pr[1])]
	return [false, 0]


func _threshold_for_level(obj: Object, level: int) -> Array:
	var r := _call_ar(obj, "get_xp_for_level", [level])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	r = _call_ar(obj, "xp_for_level", [level])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	r = _call_ar(obj, "xp_needed_for_level", [level])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	r = _call_ar(obj, "xp_to_level", [level])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	var pr := _get_prop(obj, ["XP_PER_LEVEL", "LEVEL_XP", "XP_PER_LEVEL_UP"])
	if pr[0] and (pr[1] is int or pr[1] is float) and int(pr[1]) > 0:
		# Level 1 starts at 0 XP; reaching level L needs (L-1) steps.
		return [true, (level - 1) * int(pr[1])]
	return [false, 0]


func _level_at_xp_via_set(xp_value: int) -> Array:
	var inst := _fresh_instance(_prog_path, "ProgLevel", _save_path_from_source(_prog_source))
	if inst == null:
		return [false, 0]
	var ok := _set_xp(inst, xp_value)
	var lv := _get_level(inst)
	_free_inst(inst)
	if not ok or not lv[0]:
		return [false, 0]
	return [true, int(lv[1])]


func _level_at_xp_via_award(xp_value: int) -> Array:
	# Fresh instance, award exactly xp_value through the generic path.
	var inst := _fresh_instance(_prog_path, "ProgLevelAward", _save_path_from_source(_prog_source))
	if inst == null:
		return [false, 0]
	var generic := _first_method(inst, ["award_xp", "add_xp", "grant_xp", "add_experience", "award_experience", "give_xp"])
	if generic.is_empty():
		_free_inst(inst)
		return [false, 0]
	_call_ar(inst, generic, [xp_value])
	var lv := _get_level(inst)
	_free_inst(inst)
	if not lv[0]:
		return [false, 0]
	return [true, int(lv[1])]


func _level_at_xp(xp_value: int) -> Array:
	var r := _level_at_xp_via_set(xp_value)
	if r[0]:
		return r
	return _level_at_xp_via_award(xp_value)


func _check_levels() -> void:
	if _prog_path.is_empty():
		_check_missing("levels", "level thresholds / boundaries — no progression implementation")
		_check_missing("unlocks", "unlock gating — no progression implementation")
		return
	var probe := _instantiate(_prog_path, "ProgLevelProbe")
	if probe == null:
		_check_missing("levels", "progression script at %s failed to instantiate" % _prog_path)
		return
	var has_level = _get_level(probe)[0]
	var has_threshold = _threshold_for_level(probe, 2)[0]
	_free_inst(probe)
	if not has_level:
		_check_missing("levels", "no level query API (get_level / level property) on %s" % _prog_path)
		return
	# Monotonic thresholds when the API exposes them.
	if has_threshold:
		var mono := true
		var prev := -1
		for lv in [1, 2, 3, 4, 5]:
			# Threshold calls are stateless; use a fresh instance each time.
			var inst2 := _instantiate(_prog_path, "ProgThresh")
			if inst2 == null:
				mono = false
				break
			var tt := _threshold_for_level(inst2, lv)
			_free_inst(inst2)
			if not tt[0]:
				mono = false
				break
			if int(tt[1]) <= prev:
				mono = false
			prev = int(tt[1])
		_check("levels", mono, "level XP thresholds strictly increase (levels 1..5)")
		# Boundary checks for levels 2 and 3: below / at / above.
		for lv in [2, 3]:
			var inst3 := _instantiate(_prog_path, "ProgThresh2")
			if inst3 == null:
				continue
			var th := _threshold_for_level(inst3, lv)
			_free_inst(inst3)
			if not th[0]:
				continue
			var tval := int(th[1])
			var below := _level_at_xp(maxi(0, tval - 1))
			var at := _level_at_xp(tval)
			var above := _level_at_xp(tval + 1)
			if below[0]:
				_check("levels", int(below[1]) < lv, "level %d boundary: %d XP -> level %d (< %d)" % [lv, maxi(0, tval - 1), int(below[1]), lv])
			else:
				_skip("levels", "level %d below-boundary (cannot set XP)" % lv)
			if at[0]:
				_check("levels", int(at[1]) >= lv, "level %d boundary: %d XP -> level %d (>= %d)" % [lv, tval, int(at[1]), lv])
			else:
				_skip("levels", "level %d at-boundary (cannot set XP)" % lv)
			if above[0] and tval > 0:
				_check("levels", int(above[1]) == lv, "level %d boundary: %d XP -> level %d (== %d, no early jump)" % [lv, tval + 1, int(above[1]), lv])
	else:
		_skip("levels", "threshold API absent — probing first level-up via award")
		# Generic probe: award increasing XP until the level moves, then
		# verify just-below stays at base level.
		var base_inst := _instantiate(_prog_path, "ProgBase")
		var base_lv := -1
		if base_inst != null:
			var bl := _get_level(base_inst)
			if bl[0]:
				base_lv = int(bl[1])
			_free_inst(base_inst)
		if base_lv >= 0:
			var found := -1
			var step := 50
			var acc := 0
			while acc <= 20000:
				acc += step
				var lv := _level_at_xp_via_award(acc)
				if lv[0] and int(lv[1]) > base_lv:
					found = acc
					break
			if found > 0:
				var below := _level_at_xp_via_award(found - 1)
				_check("levels", below[0] and int(below[1]) == base_lv, "first level-up boundary: %d XP stays level %d, %d XP levels up" % [found - 1, base_lv, found])
			else:
				_check_missing("levels", "level never increases after awarding 20000 XP (level stuck?)")
	_check_unlocks()


func _unlock_entries() -> Array:
	# Returns Array of {"id": String, "level": int} when a table is exposed.
	var inst := _fresh_instance(_prog_path, "ProgUnlockTable", _save_path_from_source(_prog_source))
	if inst == null:
		return []
	var out: Array = []
	var r := _call_ar(inst, "get_unlocks", [])
	if not r[0]:
		r = _call_ar(inst, "get_unlock_table", [])
	if not r[0]:
		r = _call_ar(inst, "get_all_unlocks", [])
	var raw = null
	if r[0]:
		raw = r[1]
	else:
		var pr := _get_prop(inst, ["unlocks", "UNLOCK_TABLE", "unlock_table", "UNLOCKS"])
		if pr[0]:
			raw = pr[1]
	_free_inst(inst)
	if raw is Array:
		for entry in raw:
			if entry is Dictionary:
				var id := str(entry.get("id", entry.get("item", entry.get("name", ""))))
				var lv := int(entry.get("level", entry.get("required_level", entry.get("unlock_level", -1))))
				if not id.is_empty() and lv >= 0:
					out.append({"id": id, "level": lv})
	elif raw is Dictionary:
		for k in raw.keys():
			var v = raw[k]
			if v is int:
				out.append({"id": str(k), "level": int(v)})
			elif v is Array:
				for item in v:
					if item is Dictionary:
						var id2 := str(item.get("id", item.get("item", item.get("name", ""))))
						if not id2.is_empty():
							out.append({"id": id2, "level": int(k)})
					else:
						out.append({"id": str(item), "level": int(k)})
	return out


func _is_unlocked_at_xp(item_id: String, xp_value: int) -> Array:
	var inst := _fresh_instance(_prog_path, "ProgUnlock", _save_path_from_source(_prog_source))
	if inst == null:
		return [false, false]
	var ok := _set_xp(inst, xp_value)
	if not ok:
		# Fall back to awarding.
		var generic := _first_method(inst, ["award_xp", "add_xp", "grant_xp", "add_experience", "award_experience", "give_xp"])
		if generic.is_empty():
			_free_inst(inst)
			return [false, false]
		_call_ar(inst, generic, [xp_value])
	var r := _call_ar(inst, "is_unlocked", [item_id])
	if not r[0]:
		r = _call_ar(inst, "is_item_unlocked", [item_id])
	if not r[0]:
		r = _call_ar(inst, "check_unlock", [item_id])
	if not r[0]:
		r = _call_ar(inst, "has_unlock", [item_id])
	_free_inst(inst)
	if not r[0] or not (r[1] is bool):
		return [false, false]
	return [true, bool(r[1])]


func _check_unlocks() -> void:
	var probe := _instantiate(_prog_path, "ProgUnlockProbe")
	if probe == null:
		_check_missing("unlocks", "progression script failed to instantiate for unlock checks")
		return
	var has_is_unlocked := probe.has_method("is_unlocked") or probe.has_method("is_item_unlocked") or probe.has_method("check_unlock") or probe.has_method("has_unlock")
	_free_inst(probe)
	if not has_is_unlocked:
		_check_missing("unlocks", "no unlock query API (is_unlocked / is_item_unlocked / check_unlock) on %s" % _prog_path)
		return
	var entries := _unlock_entries()
	if not entries.is_empty():
		# Test a spread: lowest-level, a mid, and the highest-level entry.
		entries.sort_custom(func(a, b): return int(a["level"]) < int(b["level"]))
		var picks: Array = []
		picks.append(entries[0])
		if entries.size() > 2:
			picks.append(entries[entries.size() / 2])
		if entries.size() > 1:
			picks.append(entries[entries.size() - 1])
		for pick in picks:
			var item_id: String = str(pick["id"])
			var req_lv: int = int(pick["level"])
			# XP for the required level: threshold API if present, else
			# approximate via the level-boundary probe is not available
			# here — use xp_for_level on a fresh instance.
			var th_inst := _instantiate(_prog_path, "ProgThreshU")
			var th := [false, 0]
			if th_inst != null:
				th = _threshold_for_level(th_inst, req_lv)
				_free_inst(th_inst)
			if not th[0]:
				_skip("unlocks", "'%s' boundary (no threshold for level %d)" % [item_id, req_lv])
				continue
			var tval := int(th[1])
			var below := [false, false]
			if tval > 0:
				below = _is_unlocked_at_xp(item_id, maxi(0, tval - 1))
			else:
				_skip("unlocks", "'%s' below-check (level %d unlocks at 0 XP — nothing below level 1)" % [item_id, req_lv])
			var at := _is_unlocked_at_xp(item_id, tval)
			var above := _is_unlocked_at_xp(item_id, tval + 100000)
			if below[0]:
				_check("unlocks", not bool(below[1]), "'%s' stays LOCKED below its unlock (level %d, %d XP)" % [item_id, req_lv, maxi(0, tval - 1)])
			if at[0]:
				_check("unlocks", bool(at[1]), "'%s' UNLOCKS at its unlock (level %d, %d XP)" % [item_id, req_lv, tval])
			if above[0]:
				_check("unlocks", bool(above[1]), "'%s' STAYS unlocked well above its unlock" % [item_id])
	else:
		_skip("unlocks", "no unlock table exposed — probing candidate item ids")
		var candidates := ["ar7", "lr8", "sg12", "smg9", "p9", "raptor", "br3", "hv44", "uav", "airstrike", "chopper", "loadout_2", "loadout_3"]
		var locked_at_zero: Array = []
		for cid in candidates:
			var r0 := _is_unlocked_at_xp(cid, 0)
			if r0[0] and not bool(r0[1]):
				locked_at_zero.append(cid)
		_check("unlocks", not locked_at_zero.is_empty(), "at least one candidate item is locked at 0 XP (gating exists): %s" % [locked_at_zero])
		for cid in locked_at_zero:
			var r_big := _is_unlocked_at_xp(str(cid), 1000000)
			if r_big[0]:
				_check("unlocks", bool(r_big[1]), "'%s' unlocks at very high XP" % [str(cid)])


# ---------------------------------------------------------------- P3 loadouts

func _loadout_get(inst: Object, lname: String) -> Array:
	var r := _call_ar(inst, "get_loadout", [lname])
	if not r[0]:
		r = _call_ar(inst, "get_loadout_by_name", [lname])
	if not r[0]:
		r = _call_ar(inst, "load_loadout", [lname])
	if r[0] and r[1] is Dictionary:
		return [true, r[1]]
	# Split getters.
	var rp := _call_ar(inst, "get_loadout_primary", [lname])
	var rs := _call_ar(inst, "get_loadout_secondary", [lname])
	if rp[0] or rs[0]:
		var d := {}
		if rp[0]:
			d["primary"] = rp[1]
		if rs[0]:
			d["secondary"] = rs[1]
		return [true, d]
	return [false, {}]


func _loadout_primary(d: Dictionary) -> String:
	for k in ["primary", "primary_id", "primary_weapon", "primary_weapon_id", "slot_1", "weapon_1"]:
		if d.has(k):
			return str(d[k])
	return ""


func _loadout_secondary(d: Dictionary) -> String:
	for k in ["secondary", "secondary_id", "secondary_weapon", "secondary_weapon_id", "slot_2", "weapon_2"]:
		if d.has(k):
			return str(d[k])
	return ""


## Create a loadout. Returns [called, accepted]: `accepted` is the worker's
## own bool result — a creation that the worker REJECTS (duplicate name,
## slot cap, unknown weapon) is [true, false], NOT a success.
func _loadout_save(inst: Object, lname: String, primary: String, secondary: String) -> Array:
	for m in ["save_loadout", "create_loadout", "set_loadout", "add_loadout", "store_loadout"]:
		if not inst.has_method(m):
			continue
		var arity := _method_arity(inst, m)
		var r: Array = [false, null]
		if arity >= 3:
			r = _call_ar(inst, m, [lname, primary, secondary])
		elif arity == 2:
			r = _call_ar(inst, m, [lname, {"primary": primary, "secondary": secondary}])
		elif arity == 1:
			r = _call_ar(inst, m, [{"name": lname, "primary": primary, "secondary": secondary}])
		else:
			continue
		if r[0]:
			if r[1] is bool:
				return [true, bool(r[1])]
			return [true, true]
	return [false, null]


## Update an existing loadout's weapons. Same [called, accepted] shape.
func _loadout_update(inst: Object, lname: String, primary: String, secondary: String) -> Array:
	for m in ["update_loadout", "edit_loadout", "set_loadout_weapons"]:
		if not inst.has_method(m):
			continue
		var r := _call_ar(inst, m, [lname, primary, secondary])
		if r[0]:
			if r[1] is bool:
				return [true, bool(r[1])]
			return [true, true]
	return [false, null]


func _loadout_save_all(inst: Object) -> void:
	for m in ["save", "save_loadouts", "save_all", "persist"]:
		if inst.has_method(m):
			_call_ar(inst, m, [])
			return


func _loadout_load_all(inst: Object) -> void:
	for m in ["load", "load_loadouts", "load_all", "reload"]:
		if inst.has_method(m):
			_call_ar(inst, m, [])
			return


func _loadout_delete(inst: Object, lname: String) -> void:
	for m in ["delete_loadout", "remove_loadout", "clear_loadout", "erase_loadout"]:
		if inst.has_method(m):
			_call_ar(inst, m, [lname])
			return


func _check_loadouts() -> void:
	if _loadouts_path.is_empty():
		_check_missing("loadouts", "save/load/persist — no loadouts implementation file")
		_check_missing("loadouts", "selected-loadout round-trip — no loadouts implementation file")
		return
	# Back up BEFORE any probe instantiation: the worker seeds + SAVES
	# defaults on _ready when the file is missing, so a backup taken
	# after the first probe would capture suite-generated data.
	var src_save := _save_path_from_source(_loadouts_source)
	if not src_save.is_empty():
		_backup_user_file(src_save)
	var probe := _instantiate(_loadouts_path, "LoadoutsProbe")
	if probe == null:
		_check_missing("loadouts", "loadouts script at %s failed to instantiate" % _loadouts_path)
		return
	var save_path := _find_user_path(probe, _loadouts_source, ["user://loadouts.json", "user://loadouts.cfg", "user://player_loadouts.json"])
	_free_inst(probe)
	# Start from a CLEAN store (missing file -> worker seeds its defaults).
	_clear_save_file(save_path)
	# --- save/load round-trip on one instance.
	var inst := _instantiate(_loadouts_path, "LoadoutsA")
	if inst == null:
		_check_missing("loadouts", "loadouts script failed to instantiate for round-trip")
		return
	# The worker seeds N defaults under a slot cap: a full store must
	# reject one more creation (cap is real), then we free one slot so
	# the suite's own entries can be created.
	var count_now := -1
	var cap_now := -1
	var lc := _call_ar(inst, "get_loadouts", [])
	if lc[0] and lc[1] is Array:
		count_now = (lc[1] as Array).size()
	var cap_r := _call_ar(inst, "get_max_loadout_slots", [])
	if cap_r[0] and (cap_r[1] is int or cap_r[1] is float):
		cap_now = int(cap_r[1])
	if count_now >= 0 and cap_now >= 0 and count_now >= cap_now:
		var over := _loadout_save(inst, "__verify_over__", "ar7", "p9")
		_check("loadouts", over[0] and not bool(over[1]), "creation beyond the slot cap (%d/%d) is rejected" % [count_now, cap_now])
		# Free one slot for the suite's own entries (file is restored later).
		var first_name := ""
		if lc[0] and lc[1] is Array and not (lc[1] as Array).is_empty():
			first_name = str(((lc[1] as Array)[0] as Dictionary).get("name", ""))
		if not first_name.is_empty():
			_loadout_delete(inst, first_name)
	var s1 := _loadout_save(inst, "__verify_a__", "ar7", "p9")
	_check("loadouts", s1[0] and bool(s1[1]), "create_loadout('__verify_a__', ar7/p9) accepted")
	var g1 := _loadout_get(inst, "__verify_a__")
	_check("loadouts", g1[0] and _loadout_primary(g1[1]) == "ar7" and _loadout_secondary(g1[1]) == "p9", "get_loadout('__verify_a__') returns ar7/p9 (got primary='%s' secondary='%s')" % [_loadout_primary(g1[1]) if g1[0] else "?", _loadout_secondary(g1[1]) if g1[0] else "?"])
	# --- duplicate create rejected; overwrite goes through update.
	var dup := _loadout_save(inst, "__verify_a__", "lr8", "smg9")
	if dup[0]:
		_check("loadouts", not bool(dup[1]), "duplicate create of '__verify_a__' is rejected")
	var s2 := _loadout_update(inst, "__verify_a__", "lr8", "smg9")
	if s2[0] and bool(s2[1]):
		var g2 := _loadout_get(inst, "__verify_a__")
		_check("loadouts", g2[0] and _loadout_primary(g2[1]) == "lr8" and _loadout_secondary(g2[1]) == "smg9", "update_loadout('__verify_a__') overwrites to lr8/smg9")
	else:
		_skip("loadouts", "overwrite (no update_loadout API)")
	# --- list contains the entry when a list API exists.
	var has_list_api := false
	var listed := false
	for m in ["get_loadout_names", "list_loadouts", "get_loadouts", "get_all_loadouts"]:
		if inst.has_method(m):
			has_list_api = true
			var r := _call_ar(inst, m, [])
			if r[0]:
				if r[1] is Array:
					# Entries may be Strings (names) or Dictionaries —
					# compare element-wise, never Array.has() on a
					# TypedArray[Dictionary] (errors on a String probe).
					for entry in (r[1] as Array):
						if entry is String and str(entry) == "__verify_a__":
							listed = true
							break
						if entry is Dictionary and str(entry.get("name", "")) == "__verify_a__":
							listed = true
							break
				elif r[1] is Dictionary and (r[1] as Dictionary).has("__verify_a__"):
					listed = true
			break
	if has_list_api:
		# NOTE: entries are Dictionaries — compare entry["name"], never
		# Array.has(name) (TypedArray[Dictionary].has(String) errors).
		_check("loadouts", listed, "loadout list API exposes '__verify_a__'")
	else:
		_skip("loadouts", "list API (no get_loadout_names / list_loadouts)")
	# --- selected-loadout round-trip when the API has one.
	var sel_set := _first_method(inst, ["set_active", "set_active_loadout", "select_loadout", "set_selected_loadout", "activate_loadout"])
	var sel_get := _first_method(inst, ["get_active_name", "get_active_loadout", "get_selected_loadout", "active_loadout"])
	if not sel_set.is_empty() and not sel_get.is_empty():
		_call_ar(inst, sel_set, ["__verify_a__"])
		var rg := _call_ar(inst, sel_get, [])
		var sel_ok := false
		if rg[0]:
			if rg[1] is String:
				sel_ok = str(rg[1]) == "__verify_a__"
			elif rg[1] is Dictionary:
				sel_ok = _loadout_primary(rg[1]) == "lr8"
		_check("loadouts", sel_ok, "selected-loadout round-trip returns '__verify_a__'/lr8")
	else:
		_skip("loadouts", "selected-loadout round-trip (no select/get-active API)")
	# --- validation is WARN-only (see header).
	var bad := _loadout_save(inst, "__verify_bad__", "not_a_weapon", "also_bogus")
	if bad[0] and bool(bad[1]):
		_warn("loadouts", "bogus weapon ids accepted into a saved loadout (may crash equip later)")
		_loadout_delete(inst, "__verify_bad__")
	var empty_name := _loadout_save(inst, "", "ar7", "p9")
	if empty_name[0] and bool(empty_name[1]):
		_warn("loadouts", "empty loadout name accepted")
		_loadout_delete(inst, "")
	# --- persistence across a simulated restart.
	# Free a slot first: the store may be at its cap (creation then fails).
	_loadout_delete(inst, "__verify_a__")
	_loadout_save(inst, "__verify_persist__", "sg12", "smg9")
	_loadout_save_all(inst)
	_free_inst(inst)
	var inst2 := _instantiate(_loadouts_path, "LoadoutsB")
	if inst2 == null:
		_check_missing("loadouts", "fresh instance for persistence check failed to instantiate")
	else:
		_loadout_load_all(inst2)
		var gp := _loadout_get(inst2, "__verify_persist__")
		_check("loadouts", gp[0] and _loadout_primary(gp[1]) == "sg12" and _loadout_secondary(gp[1]) == "smg9", "fresh instance loads persisted '__verify_persist__' as sg12/smg9")
		_loadout_delete(inst2, "__verify_a__")
		_loadout_delete(inst2, "__verify_persist__")
		_loadout_save_all(inst2)
		_free_inst(inst2)
	if not save_path.is_empty():
		_restore_user_file(save_path)


# ---------------------------------------------------------------- P4 menu

func _collect_text_controls(node: Node, out: Array) -> void:
	if node is Label:
		out.append(node as Control)
	if node is Button:
		out.append(node as Control)
	for ch in node.get_children():
		_collect_text_controls(ch, out)


func _find_loadout_button(node: Node) -> Button:
	if node is Button:
		var t := (node as Button).text.to_upper()
		if t.contains("LOADOUT"):
			return node as Button
	for ch in node.get_children():
		var found := _find_loadout_button(ch)
		if found != null:
			return found
	return null


func _find_picker(node: Node, exclude: Node) -> bool:
	if node != exclude and node is Control and (node as Control).is_visible_in_tree():
		var nm := node.name.to_lower()
		if nm.contains("loadout") and not (node is Button):
			return true
		if node is Label and (node as Label).text.to_upper().contains("LOADOUT"):
			return true
		if node is Button and (node as Button).text.to_upper().contains("LOADOUT"):
			# A picker-internal button (e.g. a preset row) counts; the
			# main-menu button itself is excluded via `exclude`.
			return true
	for ch in node.get_children():
		if _find_picker(ch, exclude):
			return true
	return false


func _menu_stage_build() -> void:
	# Pinpoint: if the menu script itself fails to parse, the scene
	# instantiates WITHOUT it (zero buttons built) — report that root
	# cause directly instead of only its symptoms below.
	var scr = load("res://scripts/ui/main_menu.gd")
	_menu_script_ok = scr != null
	_check("menu", _menu_script_ok, "main_menu.gd parses/loads (GameModeManager resolution)")
	if not FileAccess.file_exists("res://scenes/ui/main_menu.tscn"):
		_check_missing("menu", "main-menu scene res://scenes/ui/main_menu.tscn absent")
		_stage = 99
		return
	_menu = (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate() as Control
	if _menu == null:
		_check_missing("menu", "main-menu scene failed to instantiate")
		_stage = 99
		return
	_menu.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	_menu.position = Vector2.ZERO
	_menu.size = Vector2(1280, 800)
	root.add_child(_menu)


func _menu_stage_press() -> void:
	if _menu == null or not is_instance_valid(_menu):
		return
	var btn := _find_loadout_button(_menu)
	if btn == null:
		_check_missing("menu", "no LOADOUT button on the main menu (still COMING SOON?)")
		# Still verify COMING SOON below in the final stage.
		return
	_check("menu", not btn.disabled, "main-menu LOADOUT button is enabled")
	btn.emit_signal("pressed")
	# Some menus open the picker via a named method instead of / in
	# addition to the button signal; the button press above is the real
	# user path, so no method call is needed here.


func _menu_stage_final() -> void:
	if _menu == null or not is_instance_valid(_menu):
		return
	# COMING SOON must be gone from every visible control on the menu path.
	# A menu that built ZERO buttons (script failed to load) must NOT pass
	# this vacuously — it built nothing at all.
	var controls: Array = []
	_collect_text_controls(_menu, controls)
	var button_count := 0
	for c in controls:
		if c is Button:
			button_count += 1
	if not _menu_script_ok or button_count == 0:
		_check("menu", false, "menu built %d buttons (script did not load — no menu state to verify)" % button_count)
	else:
		var coming_soon_seen := false
		for c in controls:
			var t := ""
			if c is Label:
				t = (c as Label).text
			elif c is Button:
				t = (c as Button).text
			if t.to_upper().contains("COMING SOON"):
				coming_soon_seen = true
		_check("menu", not coming_soon_seen, "no visible 'COMING SOON' text anywhere on the main menu")
	var btn := _find_loadout_button(_menu)
	# Picker: any visible loadout-named control beyond the menu button, or
	# a new top-level control on the root (popup / swapped scene).
	var picker := false
	if btn != null:
		picker = _find_picker(_menu, btn)
	if not picker:
		for ch in root.get_children():
			if ch != _menu and _find_picker(ch, btn):
				picker = true
				break
	if btn == null:
		_check_missing("menu", "LOADOUT button press could not open a picker — no LOADOUT button")
	elif picker:
		_check("menu", true, "LOADOUT button opens a loadout picker")
	else:
		_check("menu", false, "LOADOUT button pressed but no loadout picker became visible")
	_menu.queue_free()
	_menu = null


# ---------------------------------------------------------------- P5 stats

func _stat_get(inst: Object, key: String) -> Array:
	var r := _call_ar(inst, "get_stat", [key])
	if r[0] and (r[1] is int or r[1] is float):
		return [true, int(r[1])]
	var pr := _get_prop(inst, [key])
	if pr[0] and (pr[1] is int or pr[1] is float):
		return [true, int(pr[1])]
	var all := _call_ar(inst, "get_stats", [])
	if all[0] and all[1] is Dictionary and (all[1] as Dictionary).has(key):
		var v = (all[1] as Dictionary)[key]
		if v is int or v is float:
			return [true, int(v)]
	var pr2 := _get_prop(inst, ["stats", "counters", "totals"])
	if pr2[0] and pr2[1] is Dictionary and (pr2[1] as Dictionary).has(key):
		var v2 = (pr2[1] as Dictionary)[key]
		if v2 is int or v2 is float:
			return [true, int(v2)]
	return [false, 0]


## Type-correct arguments for one call of `method`: String -> "ar7"
## (a plausible weapon id), int -> `count`, float -> float(count),
## bool -> false, Dictionary -> {}. Used for record_* probes so a
## typed String parameter (e.g. record_kill(weapon_id)) never receives
## an int and aborts the call (Godot callv does NOT coerce int->String).
func _typed_args_for(inst: Object, method: String, count: int) -> Array:
	var out: Array = []
	for m in inst.get_method_list():
		if str(m.get("name", "")) == method:
			for a in (m.get("args", []) as Array):
				var t: int = int(a.get("type", TYPE_NIL))
				match t:
					TYPE_STRING, TYPE_STRING_NAME:
						out.append("ar7")
					TYPE_INT:
						out.append(count)
					TYPE_FLOAT:
						out.append(float(count))
					TYPE_BOOL:
						out.append(false)
					TYPE_DICTIONARY:
						out.append({})
					TYPE_ARRAY:
						out.append([])
					_:
						out.append(0)
			break
	return out


func _stat_record(inst: Object, key: String, count: int) -> bool:
	# Singular FIRST (workers record "kill"/"death"/"shot"/"hit"; plural
	# forms are aliases at best, unknown event types at worst), then the
	# generic record_event with the SINGULAR event name, then the raw key.
	# record_*/track_* record ONE event per call (loop `count` times);
	# add_*/increment_* take a count argument (call once).
	var singular := key
	if key.ends_with("s"):
		singular = key.substr(0, key.length() - 1)
	for m in ["record_" + singular, "record_" + key, "track_" + singular, "track_" + key]:
		if inst.has_method(m):
			var args := _typed_args_for(inst, m, 1)
			for i in count:
				_call_ar(inst, m, args)
			return true
	for m in ["add_" + singular, "add_" + key, "increment_" + singular, "increment_" + key]:
		if inst.has_method(m):
			var args2 := _typed_args_for(inst, m, count)
			_call_ar(inst, m, args2)
			return true
	for ev_name in [singular, key]:
		if inst.has_method("record_event"):
			for i in count:
				_call_ar(inst, "record_event", [ev_name])
			return true
	for m in ["record", "increment_stat", "add_stat"]:
		if inst.has_method(m):
			for i in count:
				_call_ar(inst, m, [singular])
			return true
	return false


func _stat_save(inst: Object) -> void:
	for m in ["save", "save_stats", "persist"]:
		if inst.has_method(m):
			_call_ar(inst, m, [])
			return


func _stat_load(inst: Object) -> void:
	for m in ["load", "load_stats", "reload"]:
		if inst.has_method(m):
			_call_ar(inst, m, [])
			return


func _stat_reset(inst: Object) -> void:
	for m in ["reset", "reset_stats", "clear", "clear_stats"]:
		if inst.has_method(m):
			_call_ar(inst, m, [])
			return


func _check_stats() -> void:
	if _stats_path.is_empty():
		_check_missing("stats", "accumulate/persist — no stats implementation file")
		_check_missing("stats", "graceful load of old/missing/malformed files — no stats implementation")
		return
	# Back up BEFORE any probe instantiation (same seed-on-_ready hazard
	# as loadouts — a backup taken after the first probe is not clean).
	var stats_src_save := _save_path_from_source(_stats_source)
	if not stats_src_save.is_empty():
		_backup_user_file(stats_src_save)
	var probe := _instantiate(_stats_path, "StatsProbe")
	if probe == null:
		_check_missing("stats", "stats script at %s failed to instantiate" % _stats_path)
		return
	var save_path := _find_user_path(probe, _stats_source, ["user://stats.json", "user://player_stats.json", "user://stats.cfg", "user://progression.json"])
	_free_inst(probe)
	# Start from a CLEAN file (missing file -> defaults).
	_clear_save_file(save_path)
	# --- accumulate.
	var inst := _instantiate(_stats_path, "StatsA")
	if inst == null:
		_check_missing("stats", "stats script failed to instantiate for accumulate check")
		return
	_stat_reset(inst)
	_stat_save(inst)
	var rec_kills := _stat_record(inst, "kills", 3)
	var rec_deaths := _stat_record(inst, "deaths", 1)
	_check("stats", rec_kills, "stats API records kills (record_kills / add_kills / record_event)")
	_check("stats", rec_deaths, "stats API records deaths")
	if rec_kills:
		var k := _stat_get(inst, "kills")
		_check("stats", k[0] and int(k[1]) == 3, "kills counter == 3 after 3 records (got %s)" % [str(k[1]) if k[0] else "?"])
	if rec_deaths:
		var d := _stat_get(inst, "deaths")
		_check("stats", d[0] and int(d[1]) == 1, "deaths counter == 1 after 1 record (got %s)" % [str(d[1]) if d[0] else "?"])
	# Accuracy: record shots/hits when the API has them; a computed
	# accuracy in [0,1] must follow if it is exposed.
	var rec_shots := _stat_record(inst, "shots", 10)
	var rec_hits := _stat_record(inst, "hits", 4)
	if rec_shots and rec_hits:
		var acc := _call_ar(inst, "get_accuracy", [])
		if not acc[0]:
			acc = _call_ar(inst, "accuracy", [])
		if acc[0] and (acc[1] is float or acc[1] is int):
			_check("stats", absf(float(acc[1]) - 0.4) < 0.001, "accuracy == 0.4 after 4/10 hits (got %s)" % [str(acc[1])])
		else:
			var acc_prop := _get_prop(inst, ["accuracy", "hit_accuracy"])
			if acc_prop[0] and (acc_prop[1] is float or acc_prop[1] is int):
				_check("stats", float(acc_prop[1]) >= 0.0 and float(acc_prop[1]) <= 1.0, "accuracy property in [0,1] after 4/10 hits")
			else:
				_skip("stats", "accuracy (no get_accuracy / accuracy property)")
	else:
		_skip("stats", "accuracy (no shots/hits record API)")
	# --- persist across a simulated restart.
	_stat_save(inst)
	_free_inst(inst)
	var inst2 := _instantiate(_stats_path, "StatsB")
	if inst2 == null:
		_check_missing("stats", "fresh instance for persistence check failed to instantiate")
	else:
		_stat_load(inst2)
		var k2 := _stat_get(inst2, "kills")
		_check("stats", k2[0] and int(k2[1]) == 3, "fresh instance loads persisted kills == 3")
		_free_inst(inst2)
	# --- missing file -> sane defaults, no crash.
	if not save_path.is_empty():
		if FileAccess.file_exists(save_path):
			DirAccess.remove_absolute(save_path)
		var inst3 := _instantiate(_stats_path, "StatsMissing")
		if inst3 != null:
			_stat_load(inst3)
			var k3 := _stat_get(inst3, "kills")
			_check("stats", (not k3[0]) or int(k3[1]) == 0, "missing save file -> kills defaults to 0 (no crash)")
			_free_inst(inst3)
		# --- malformed file -> sane defaults, no crash.
		_write_user_file(save_path, "{{{{ this is not valid {{{{")
		var inst4 := _instantiate(_stats_path, "StatsBad")
		if inst4 != null:
			_stat_load(inst4)
			var k4 := _stat_get(inst4, "kills")
			_check("stats", (not k4[0]) or int(k4[1]) == 0, "malformed save file -> kills defaults to 0 (no crash)")
			_free_inst(inst4)
		# --- old / partial file -> known keys load, missing keys default.
		var is_cfg := _stats_source.contains("ConfigFile")
		if is_cfg:
			_write_user_file(save_path, "[stats]\nkills = 7\n")
		else:
			_write_user_file(save_path, "{\"kills\": 7}")
		var inst5 := _instantiate(_stats_path, "StatsOld")
		if inst5 != null:
			_stat_load(inst5)
			var k5 := _stat_get(inst5, "kills")
			var d5 := _stat_get(inst5, "deaths")
			_check("stats", k5[0] and int(k5[1]) == 7, "partial (old-format) file -> kills == 7 preserved")
			_check("stats", (not d5[0]) or int(d5[1]) == 0, "partial (old-format) file -> missing deaths defaults to 0")
			_free_inst(inst5)
	else:
		_skip("stats", "missing/malformed/partial file tests (save path not discoverable)")
	if not save_path.is_empty():
		_restore_user_file(save_path)


# ---------------------------------------------------------------- P6 integration

func _check_integration() -> void:
	var proj := _read_file("res://project.godot")
	for entry in ["Progression", "Loadouts", "Stats"]:
		if proj.contains(entry):
			_check("integration", true, "autoload '%s' registered in project.godot" % entry)
		else:
			_check_missing("integration", "autoload '%s' not registered in project.godot (coordinator registers at integration; suite re-runs then)" % entry)
	for label in [["progression", _prog_source], ["loadouts", _loadouts_source], ["stats", _stats_source]]:
		var src: String = str(label[1])
		if src.is_empty():
			continue
		if src.contains("user://"):
			_check("integration", true, "%s persists under user://" % str(label[0]))
		else:
			_warn("integration", "%s source has no user:// reference — persistence path unverified" % str(label[0]))
	# Main-menu source must not reintroduce COMING SOON as a live button
	# label (behavioral check in P4 is authoritative; this is a tripwire).
	var menu_src := _read_file("res://scripts/ui/main_menu.gd")
	if menu_src.contains("\"COMING SOON\""):
		_warn("integration", "main_menu.gd still contains the literal \"COMING SOON\" (check it is comment-only)")


# ---------------------------------------------------------------- driver

func _process(_delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			_discover()
			# Back up the real progression save BEFORE any probe writes it;
			# restored at the end so the suite never pollutes player data.
			var prog_save := _save_path_from_source(_prog_source)
			if not prog_save.is_empty():
				_backup_user_file(prog_save)
			_check_xp()
			_check_levels()
			_stage = 1
		1:
			_check_loadouts()
			_menu_stage_build()
			_frames = 0
			_stage = 2
		2:
			if _frames >= 3:
				_menu_stage_press()
				_frames = 0
				_stage = 3
		3:
			if _frames >= 3:
				_menu_stage_final()
				_stage = 4
		4:
			_check_stats()
			_check_integration()
			_stage = 5
		5:
			_restore_user_files()
			print("PROGRESSION SUMMARY: %d passed, %d failed (%d missing), %d warnings" % [_pass, _fail, _missing, _warns])
			for s in _sec.keys():
				var c: Array = _sec[s]
				print("  [%s]: %d passed, %d failed" % [str(s), int(c[0]), int(c[1])])
			quit(0 if _fail == 0 else 1)
			return true
	return false
