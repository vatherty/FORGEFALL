# progression.gd — FORGEFALL Goal 6 (Progression, Worker A): XP + levels + unlocks.
#
# Autoload "Progression" (registered by the coordinator in project.godot;
# NO class_name here — Godot rejects a class_name identical to an autoload).
# Gameplay code reports events with ONE guarded line at each real event site:
#   if is_inside_tree(): var _prog = get_node_or_null("/root/Progression"); if _prog != null: _prog.report_event("kill", {...})
# The guard keeps every hook site safe when the autoload is absent (headless
# probes, Worker D suites) and when the caller is not inside the tree.
#
# XP SOURCES (all additive; nothing playable today is locked — unlocks are
# additions, never removals):
#   kill              100 (+50 headshot, +100 brute/juggernaut, +400 warlord)
#   mp_kill           same as kill (coordinator-applied hook in net_match)
#   wave_cleared      100 + 25 * wave
#   domination_capture 150
#   domination_hold    5 per point per scored point (1 event per point-sec)
#   match_end         win 500 / draw 150 / loss 50
#   match_win         500 (alias for match_end with won=true)
#   endless_run_over  200 + 25 * wave reached (+250 on a new best)
#   puzzle_complete   300, FIRST completion of each chamber only (replays 0)
#
# LEVEL CURVE — cost to go from level L to L+1 (first levels fast, later
# levels longer). Cumulative XP to REACH level N is get_xp_for_level(N):
#   L 1-4  -> 500 each    (reach L5 at 2,000)
#   L 5-9  -> 1,000 each  (reach L10 at 7,000)
#   L 10-19 -> 1,500 each (reach L20 at 22,000)
#   L 20-29 -> 2,500 each (reach L30 at 47,000)
#   L 30-49 -> 4,000 each (reach L50 at 127,000)
#   L 50+  -> 5,000 each (no level cap; unlocks stop at L50)
#
# UNLOCKS (gated by level; see UNLOCKS table): titles, emblems, camos,
# extra custom-loadout slots. Camos are voxel RECOLORS ONLY — a
# {primary, accent} color pair the viewmodel code applies via
# VoxelBuilder materials; no new models, no stat changes. The 5 preset
# loadouts (Assault/Marksman/Breacher/Raptor/Burst) stay free at all
# levels; "loadout_slot" unlocks add CUSTOM slots on top of the 2 base ones.
#
# PERSISTENCE: user://progression.json, version-tolerant. A missing file
# starts fresh; a corrupt file / wrong-typed fields fall back to defaults
# field-by-field — loading NEVER crashes.
#
# STATS: every reported event is forwarded to the Stats autoload (Worker B)
# via get_node_or_null("/root/Stats") + has_method("record_event"), with the
# computed xp_awarded added to the forwarded data. Stats may not exist yet;
# the guard makes absence safe.
extends Node

signal xp_changed(total_xp: int, level: int)
signal level_up(new_level: int, new_unlocks: Array)
signal unlock_earned(unlock_id: String)
signal equipped_changed(kind: String, id: String)

const SAVE_PATH := "user://progression.json"
const SAVE_VERSION := 1

#region TUNABLES — XP values

const XP_KILL := 100
const XP_KILL_HEADSHOT_BONUS := 50
const XP_KILL_BRUTE_BONUS := 100
const XP_KILL_WARLORD_BONUS := 400
const XP_WAVE_BASE := 100
const XP_WAVE_PER_WAVE := 25
const XP_DOMINATION_CAPTURE := 150
const XP_DOMINATION_HOLD_PER_POINT := 5
const XP_MATCH_WIN := 500
const XP_MATCH_DRAW := 150
const XP_MATCH_LOSS := 50
const XP_ENDLESS_BASE := 200
const XP_ENDLESS_PER_WAVE := 25
const XP_ENDLESS_NEW_BEST_BONUS := 250
const XP_PUZZLE_FIRST_CLEAR := 300

## Cost to advance from level L to L+1, by segment (see header curve).
## get_xp_for_level(N) sums these for L = 1 .. N-1.
#endregion

#region TUNABLES — unlock catalogue

## Every unlock: {id, type, name, desc, required_level, ...type extras}.
## Types: "title" | "emblem" | "camo" (primary/accent Colors) |
## "loadout_slot" (slot_index int). Ordered by required_level.
const UNLOCKS: Array = [
	{"id": "title_recruit", "type": "title", "name": "RECRUIT",
		"desc": "Starting title.", "required_level": 1},
	{"id": "emblem_rank", "type": "emblem", "name": "RANK",
		"desc": "Starting emblem: plain chevron.", "required_level": 1},
	{"id": "title_grunt", "type": "title", "name": "GRUNT",
		"desc": "Seen a few waves.", "required_level": 3},
	{"id": "camo_desert", "type": "camo", "name": "DESERT",
		"desc": "Sand-tan voxel recolor for any weapon.",
		"required_level": 4,
		"primary": Color(0.76, 0.68, 0.45), "accent": Color(0.45, 0.38, 0.28)},
	{"id": "emblem_skull", "type": "emblem", "name": "SKULL",
		"desc": "You collect them now.", "required_level": 5},
	{"id": "slot_3", "type": "loadout_slot", "name": "CUSTOM SLOT 3",
		"desc": "A third custom loadout slot.", "required_level": 6, "slot_index": 2},
	{"id": "camo_arctic", "type": "camo", "name": "ARCTIC",
		"desc": "Snow-white / ice-blue voxel recolor for any weapon.",
		"required_level": 7,
		"primary": Color(0.92, 0.95, 0.97), "accent": Color(0.45, 0.75, 0.95)},
	{"id": "title_veteran", "type": "title", "name": "VETERAN",
		"desc": "Survived long enough to know better.", "required_level": 8},
	{"id": "camo_jungle", "type": "camo", "name": "JUNGLE",
		"desc": "Olive-drab voxel recolor for any weapon.",
		"required_level": 10,
		"primary": Color(0.32, 0.42, 0.22), "accent": Color(0.18, 0.25, 0.12)},
	{"id": "emblem_flame", "type": "emblem", "name": "FLAME",
		"desc": "Still burning.", "required_level": 12},
	{"id": "slot_4", "type": "loadout_slot", "name": "CUSTOM SLOT 4",
		"desc": "A fourth custom loadout slot.", "required_level": 14, "slot_index": 3},
	{"id": "title_elite", "type": "title", "name": "ELITE",
		"desc": "Top of the food chain.", "required_level": 15},
	{"id": "camo_crimson", "type": "camo", "name": "CRIMSON",
		"desc": "Dark-red / black voxel recolor for any weapon.",
		"required_level": 18,
		"primary": Color(0.55, 0.08, 0.08), "accent": Color(0.10, 0.10, 0.12)},
	{"id": "emblem_crown", "type": "emblem", "name": "CROWN",
		"desc": "Owns the arena.", "required_level": 20},
	{"id": "slot_5", "type": "loadout_slot", "name": "CUSTOM SLOT 5",
		"desc": "A fifth custom loadout slot.", "required_level": 22, "slot_index": 4},
	{"id": "title_warlord_slayer", "type": "title", "name": "WARLORD SLAYER",
		"desc": "The boss fell to you.", "required_level": 25},
	{"id": "camo_gold", "type": "camo", "name": "GOLD",
		"desc": "Gold / black prestige voxel recolor for any weapon.",
		"required_level": 30,
		"primary": Color(0.85, 0.68, 0.15), "accent": Color(0.12, 0.12, 0.12)},
	{"id": "slot_6", "type": "loadout_slot", "name": "CUSTOM SLOT 6",
		"desc": "A sixth custom loadout slot.", "required_level": 32, "slot_index": 5},
	{"id": "emblem_diamond", "type": "emblem", "name": "DIAMOND",
		"desc": "Unbreakable.", "required_level": 35},
	{"id": "title_legend", "type": "title", "name": "LEGEND",
		"desc": "They tell stories about you.", "required_level": 40},
	{"id": "camo_void", "type": "camo", "name": "VOID",
		"desc": "Near-black / violet voxel recolor for any weapon.",
		"required_level": 45,
		"primary": Color(0.08, 0.05, 0.12), "accent": Color(0.45, 0.15, 0.65)},
	{"id": "emblem_apex", "type": "emblem", "name": "APEX",
		"desc": "Nothing above you.", "required_level": 50},
	{"id": "title_mythic", "type": "title", "name": "MYTHIC",
		"desc": "Beyond legend.", "required_level": 50},
]

## Custom loadout slots available at level 1 (before any slot unlock).
const BASE_CUSTOM_LOADOUT_SLOTS := 2
const DEFAULT_TITLE := "title_recruit"
const DEFAULT_EMBLEM := "emblem_rank"

#endregion

var _loaded: bool = false
var _total_xp: int = 0
var _equipped_title: String = DEFAULT_TITLE
var _equipped_emblem: String = DEFAULT_EMBLEM
## weapon_id -> camo unlock id ("" / absent = no camo).
var _equipped_camos: Dictionary = {}
## Chamber ids completed at least once (first-clear XP only).
var _completed_puzzles: Array = []


func _ready() -> void:
	_ensure_loaded()


# --- event intake ----------------------------------------------------------

## Central event intake. `type` is one of the XP SOURCES in the header;
## `data` carries the event fields (see each hook site). Unknown types are
## still forwarded to Stats (xp_awarded 0) and otherwise ignored.
func report_event(type: String, data: Dictionary) -> void:
	_ensure_loaded()
	var d: Dictionary = data.duplicate()
	var awarded: int = _xp_for_event(type, d)
	d["xp_awarded"] = awarded
	_forward_to_stats(type, d)
	if type == "puzzle_complete":
		var room_id: String = str(d.get("room_id", ""))
		if awarded > 0 and room_id != "" and not _completed_puzzles.has(room_id):
			_completed_puzzles.append(room_id)
	if awarded > 0:
		add_xp(awarded, type)


## Pure XP calculation for one event (no state changes, no saves).
func _xp_for_event(type: String, d: Dictionary) -> int:
	match type:
		"kill", "mp_kill":
			var xp: int = XP_KILL
			if bool(d.get("headshot", false)):
				xp += XP_KILL_HEADSHOT_BONUS
			var enemy_type: String = str(d.get("enemy_type", ""))
			if enemy_type == "warlord":
				xp += XP_KILL_WARLORD_BONUS
			elif enemy_type == "brute":
				xp += XP_KILL_BRUTE_BONUS
			return xp
		"wave_cleared":
			return XP_WAVE_BASE + XP_WAVE_PER_WAVE * maxi(int(d.get("wave", 1)), 1)
		"domination_capture":
			return XP_DOMINATION_CAPTURE
		"domination_hold":
			return XP_DOMINATION_HOLD_PER_POINT * maxi(int(d.get("points", 0)), 0)
		"match_win":
			return XP_MATCH_WIN
		"match_end":
			if bool(d.get("won", false)):
				return XP_MATCH_WIN
			if bool(d.get("draw", false)):
				return XP_MATCH_DRAW
			return XP_MATCH_LOSS
		"endless_run_over":
			var total: int = XP_ENDLESS_BASE + XP_ENDLESS_PER_WAVE * maxi(int(d.get("wave", 1)), 1)
			if bool(d.get("is_new_best", false)):
				total += XP_ENDLESS_NEW_BEST_BONUS
			return total
		"puzzle_complete":
			var room_id: String = str(d.get("room_id", ""))
			if room_id == "" or _completed_puzzles.has(room_id):
				return 0
			return XP_PUZZLE_FIRST_CLEAR
		_:
			return 0


## Forward every reported event to the Stats autoload (Worker B), if it
## exists. Guarded: Stats may not be registered yet — absence is safe.
func _forward_to_stats(type: String, data: Dictionary) -> void:
	if not is_inside_tree():
		return
	var stats: Node = get_node_or_null("/root/Stats")
	if stats != null and stats.has_method("record_event"):
		stats.call("record_event", type, data)


# --- XP / levels -----------------------------------------------------------

## Add XP from `source` (an event type or "debug"/"test"). Emits xp_changed
## always, level_up + unlock_earned for each newly crossed level's unlocks.
func add_xp(amount: int, source: String) -> void:
	_ensure_loaded()
	if amount <= 0:
		return
	var old_level: int = get_level()
	_total_xp += amount
	var new_level: int = get_level()
	_save()
	xp_changed.emit(_total_xp, new_level)
	if new_level > old_level:
		var fresh: Array = []
		for u in UNLOCKS:
			var req: int = int((u as Dictionary).get("required_level", 1))
			if req > old_level and req <= new_level:
				fresh.append(str((u as Dictionary).get("id", "")))
				unlock_earned.emit(str((u as Dictionary).get("id", "")))
		level_up.emit(new_level, fresh)
	# `source` is kept in the signature for future Stats/debug use.


## Current level from total XP (level 1 at 0 XP).
func get_level() -> int:
	_ensure_loaded()
	var level: int = 1
	while _total_xp >= get_xp_for_level(level + 1):
		level += 1
	return level


## Lifetime total XP.
func get_xp() -> int:
	_ensure_loaded()
	return _total_xp


## XP earned toward the NEXT level (0 at a fresh level-up).
func get_xp_into_level() -> int:
	_ensure_loaded()
	return _total_xp - get_xp_for_level(get_level())


## XP still needed to reach the next level.
func get_xp_to_next_level() -> int:
	_ensure_loaded()
	return get_xp_for_level(get_level() + 1) - _total_xp


## 0..1 progress toward the next level.
func get_progress_to_next() -> float:
	_ensure_loaded()
	var span: int = get_xp_for_level(get_level() + 1) - get_xp_for_level(get_level())
	if span <= 0:
		return 1.0
	return clampf(float(get_xp_into_level()) / float(span), 0.0, 1.0)


## Cumulative XP required to REACH level `n` (level 1 needs 0).
## Cost segments: L1-4: 500, L5-9: 1000, L10-19: 1500, L20-29: 2500,
## L30-49: 4000, L50+: 5000.
func get_xp_for_level(n: int) -> int:
	if n <= 1:
		return 0
	var total: int = 0
	for lvl in range(1, n):
		total += _cost_to_next(lvl)
	return total


func _cost_to_next(level: int) -> int:
	if level < 5:
		return 500
	if level < 10:
		return 1000
	if level < 20:
		return 1500
	if level < 30:
		return 2500
	if level < 50:
		return 4000
	return 5000


# --- unlocks ---------------------------------------------------------------

## All unlock entries, each with a live "unlocked" flag for the UI.
func get_unlocks() -> Array:
	_ensure_loaded()
	var level: int = get_level()
	var out: Array = []
	for u in UNLOCKS:
		var entry: Dictionary = (u as Dictionary).duplicate()
		entry["unlocked"] = level >= int(entry.get("required_level", 1))
		out.append(entry)
	return out


## Ids of all currently unlocked entries.
func get_unlocked_ids() -> Array:
	_ensure_loaded()
	var level: int = get_level()
	var out: Array = []
	for u in UNLOCKS:
		var entry: Dictionary = u as Dictionary
		if level >= int(entry.get("required_level", 1)):
			out.append(str(entry.get("id", "")))
	return out


## True when the unlock exists AND the player's level meets its requirement.
func is_unlocked(id: String) -> bool:
	_ensure_loaded()
	var u: Dictionary = _unlock_for_id(id)
	if u.is_empty():
		return false
	return get_level() >= int(u.get("required_level", 1))


func _unlock_for_id(id: String) -> Dictionary:
	for u in UNLOCKS:
		if str((u as Dictionary).get("id", "")) == id:
			return u as Dictionary
	return {}


# --- equipped cosmetics ----------------------------------------------------

## Equip a title. Must exist, be type "title", and be unlocked. Returns true.
func equip_title(id: String) -> bool:
	_ensure_loaded()
	var u: Dictionary = _unlock_for_id(id)
	if u.is_empty() or str(u.get("type", "")) != "title" or not is_unlocked(id):
		return false
	_equipped_title = id
	_save()
	equipped_changed.emit("title", id)
	return true


## Equip an emblem. Must exist, be type "emblem", and be unlocked.
func equip_emblem(id: String) -> bool:
	_ensure_loaded()
	var u: Dictionary = _unlock_for_id(id)
	if u.is_empty() or str(u.get("type", "")) != "emblem" or not is_unlocked(id):
		return false
	_equipped_emblem = id
	_save()
	equipped_changed.emit("emblem", id)
	return true


## Equip a camo on one weapon ("" clears it). The camo must exist, be type
## "camo", and be unlocked. Weapon ids are NOT validated here — Arsenal owns
## the weapon list, and an unknown weapon simply never queries its camo.
func equip_camo(weapon_id: String, camo_id: String) -> bool:
	_ensure_loaded()
	if camo_id == "":
		_equipped_camos.erase(weapon_id)
		_save()
		equipped_changed.emit("camo", weapon_id)
		return true
	var u: Dictionary = _unlock_for_id(camo_id)
	if u.is_empty() or str(u.get("type", "")) != "camo" or not is_unlocked(camo_id):
		return false
	_equipped_camos[weapon_id] = camo_id
	_save()
	equipped_changed.emit("camo", weapon_id)
	return true


func get_equipped_title() -> String:
	_ensure_loaded()
	return _equipped_title


func get_equipped_emblem() -> String:
	_ensure_loaded()
	return _equipped_emblem


## Equipped camo unlock id for a weapon, or "" when none.
func get_equipped_camo(weapon_id: String) -> String:
	_ensure_loaded()
	return str(_equipped_camos.get(weapon_id, ""))


## Recolor pair for a weapon's equipped camo: {primary: Color, accent: Color},
## or {} when no camo is equipped. The viewmodel code applies these via
## VoxelBuilder materials (recolor only — no new models).
func get_equipped_camo_colors(weapon_id: String) -> Dictionary:
	_ensure_loaded()
	var camo_id: String = get_equipped_camo(weapon_id)
	if camo_id == "":
		return {}
	var u: Dictionary = _unlock_for_id(camo_id)
	if u.is_empty():
		return {}
	return {"primary": u.get("primary"), "accent": u.get("accent")}


# --- custom loadout slots --------------------------------------------------

## Total custom loadout slots: 2 base + 1 per unlocked loadout_slot entry.
## (The 5 preset loadouts are always available and are NOT counted here.)
func get_loadout_slot_count() -> int:
	_ensure_loaded()
	var count: int = BASE_CUSTOM_LOADOUT_SLOTS
	for u in UNLOCKS:
		var entry: Dictionary = u as Dictionary
		if str(entry.get("type", "")) == "loadout_slot" and is_unlocked(str(entry.get("id", ""))):
			count += 1
	return count


## Total loadout slots (what Loadouts probes via get_max_loadout_slots):
## the 5 Forge-tab presets (always available, not counted as custom)
## + custom slots. Keep the 5 in sync with the Forge tab's preset count.
func get_max_loadout_slots() -> int:
	return 5 + get_loadout_slot_count()


## Unlocked custom slot indices: [0 .. count-1].
func get_unlocked_loadout_slots() -> Array:
	var out: Array = []
	for i in get_loadout_slot_count():
		out.append(i)
	return out


## Chamber ids completed at least once (first-clear XP already paid).
func get_completed_puzzle_ids() -> Array:
	_ensure_loaded()
	return _completed_puzzles.duplicate()


# --- persistence -----------------------------------------------------------

func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_load()


## Version-tolerant load: every field is type-checked with a default;
## a missing / corrupt / wrong-shaped file just means fresh defaults.
func _load() -> void:
	_total_xp = 0
	_equipped_title = DEFAULT_TITLE
	_equipped_emblem = DEFAULT_EMBLEM
	_equipped_camos = {}
	_completed_puzzles = []
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_warning("Progression: save file is not a JSON object; starting fresh.")
		return
	var data: Dictionary = parsed as Dictionary
	var xp_val: Variant = data.get("total_xp", 0)
	if xp_val is float or xp_val is int:
		_total_xp = maxi(int(xp_val), 0)
	var title_val: Variant = data.get("equipped_title", DEFAULT_TITLE)
	if title_val is String and _unlock_for_id(str(title_val)) is Dictionary \
			and not (_unlock_for_id(str(title_val))).is_empty() \
			and str((_unlock_for_id(str(title_val))).get("type", "")) == "title":
		_equipped_title = str(title_val)
	var emblem_val: Variant = data.get("equipped_emblem", DEFAULT_EMBLEM)
	if emblem_val is String and not (_unlock_for_id(str(emblem_val))).is_empty() \
			and str((_unlock_for_id(str(emblem_val))).get("type", "")) == "emblem":
		_equipped_emblem = str(emblem_val)
	var camos_val: Variant = data.get("equipped_camos", {})
	if camos_val is Dictionary:
		var camos: Dictionary = camos_val as Dictionary
		for weapon_id in camos.keys():
			var camo_val: Variant = camos[weapon_id]
			if camo_val is String and not (_unlock_for_id(str(camo_val))).is_empty() \
					and str((_unlock_for_id(str(camo_val))).get("type", "")) == "camo":
				_equipped_camos[str(weapon_id)] = str(camo_val)
	var puzzles_val: Variant = data.get("completed_puzzles", [])
	if puzzles_val is Array:
		for p in (puzzles_val as Array):
			if p is String and not _completed_puzzles.has(str(p)):
				_completed_puzzles.append(str(p))


func _save() -> void:
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("Progression: could not save to %s." % SAVE_PATH)
		return
	f.store_string(JSON.stringify({
		"version": SAVE_VERSION,
		"total_xp": _total_xp,
		"equipped_title": _equipped_title,
		"equipped_emblem": _equipped_emblem,
		"equipped_camos": _equipped_camos,
		"completed_puzzles": _completed_puzzles,
	}))


## Debug/test only: wipe in-memory + on-disk progress back to fresh defaults.
func reset_progress() -> void:
	_total_xp = 0
	_equipped_title = DEFAULT_TITLE
	_equipped_emblem = DEFAULT_EMBLEM
	_equipped_camos = {}
	_completed_puzzles = []
	_loaded = true
	var dir: DirAccess = DirAccess.open("user://")
	if dir != null and dir.file_exists("progression.json"):
		dir.remove("progression.json")
