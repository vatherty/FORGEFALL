# scripts/progression/loadouts.gd
# FORGEFALL — Persistent custom loadouts (Goal 6 PROGRESSION, Worker B).
# Autoload-ready: the coordinator registers this as autoload "Loadouts"
# (NO class_name here — Godot rejects a class_name identical to an
# autoload singleton name; same rule that forced class_name off NetManager).
#
# THE SHARED STORE: this file (user://loadouts.json) is the ONE loadout
# store. The main-menu picker (scripts/ui/loadout_picker.gd) reads/writes
# it through this script. The in-Forge Loadouts tab (forge_menu.gd) has
# NO store of its own — its 5 presets are hardcoded buttons that equip
# directly — so there is nothing to diverge: the 5 seeded entries below
# mirror those exact presets (same names, same weapon ids). A future
# forge_menu change should read via /root/Loadouts instead of adding a
# second file; it must never invent its own loadouts.json writer.
#
# ENTRY SHAPE: {name, primary, secondary, forge_preset, traversal}
#   primary/secondary: Arsenal weapon ids (validated against Arsenal when
#     it loads, else the built-in mirror — see ARSENAL COUPLING below).
#   forge_preset: a Forge menu preset PROMPT string ("" = none). Stored as
#     the prompt because that is the actionable value (submit to Forge);
#     the picker shows the preset's label via get_forge_preset_label().
#   The active loadout is the one Deploy uses (coordinator wires
#     Main._wire_player to call apply_active_to(weapon_manager)).
#   traversal: EXACTLY ONE traversal tool id for the run —
#     "grapple" | "jetpack" | "portal" (Gameplay Rework: the choice
#     is part of the loadout in TDM; TD keeps its own pre-run setup in
#     TowerDefenseSetup). "portal" is canonical (player.gd's
#     enforcement side); the legacy id "portal_gun" from older saves
#     migrates to "portal" on sanitize. Invalid / missing values
#     sanitize to "grapple". The id set matches the TD worker's
#     landed contract in TowerDefenseSetup.TOOLS; the player applies
#     it through the movement worker's set_traversal_tool() API.
#
# SLOT GATING: additional slots are gated by Progression unlocks, read via
# get_node_or_null("/root/Progression") + has_method("get_max_loadout_slots").
# Progression absent (or without that method) -> DEFAULT_MAX_SLOTS. The cap
# gates CREATION only: already-saved loadouts are never truncated, even
# if the cap later shrinks — user data is preserved.
#
# VERSION-TOLERANT LOADING: missing file -> seed defaults + save. Corrupt
# JSON / wrong shape / unknown weapon ids -> sanitize (unknown weapons fall
# back to ar7/p9; unrecoverable entries dropped; empty result -> defaults).
# Never crashes on an old/missing file. Loads never auto-save over a
# corrupt file; the next successful mutation saves the sanitized state.
extends Node

signal loadouts_changed
signal active_changed(active_name: String)

const SAVE_PATH := "user://loadouts.json"
const SAVE_VERSION := 1
const DEFAULT_MAX_SLOTS := 5
const MAX_NAME_LEN := 24
const FALLBACK_PRIMARY := "ar7"
const FALLBACK_SECONDARY := "p9"
const DEFAULT_TRAVERSAL := "grapple"
## Traversal tool ids (Gameplay Rework). Mirrors TowerDefenseSetup.TOOLS
## and player.gd's enforcement ids: "portal", NOT "portal_gun".
const TRAVERSAL_TOOLS: Array[String] = ["grapple", "jetpack", "portal"]
const TRAVERSAL_NAMES := {
	"grapple": "Grapple Hook",
	"jetpack": "Jetpack",
	"portal": "Portal Gun",
}

## The 5 base presets. Names + weapon ids mirror WeaponManager.LOADOUTS
## and forge_menu.gd LOADOUT_PRESETS exactly — keep all three in sync.
const DEFAULT_LOADOUTS: Array[Dictionary] = [
	{"name": "Assault", "primary": "ar7", "secondary": "p9", "forge_preset": "", "traversal": "grapple"},
	{"name": "Marksman", "primary": "lr8", "secondary": "p9", "forge_preset": "", "traversal": "grapple"},
	{"name": "Breacher", "primary": "sg12", "secondary": "smg9", "forge_preset": "", "traversal": "grapple"},
	{"name": "Raptor", "primary": "raptor", "secondary": "smg9", "forge_preset": "", "traversal": "grapple"},
	{"name": "Burst", "primary": "br3", "secondary": "hv44", "forge_preset": "", "traversal": "grapple"},
]

## Forge preset options: [label, prompt] pairs, mirroring forge_menu.gd
## PRESETS (same labels, same prompt strings, same tab order). The Forge
## menu owns the canonical list; this mirror exists so the picker can
## offer the choices without depending on the Forge menu scene.
const FORGE_PRESET_OPTIONS: Array[Array] = [
	["Wall", "Build a wall in front of me"],
	["Tower", "Build a tower"],
	["Turret", "Spawn a turret"],
	["Bridge", "Build a bridge wall in front of me"],
	["Bunker", "Build a bunker wall"],
	["Watchtower", "Build a watchtower"],
	["Ammo Depot", "Spawn an ammo depot"],
	["Sniper", "Give me a sniper rifle"],
	["Shotgun", "Give me a shotgun"],
	["SMG", "Give me an smg"],
	["Assault Rifle", "Give me an assault rifle"],
	["LMG", "Give me a machine gun"],
	["Weaken Enemies", "Weaken the enemies"],
	["Smoke", "Deploy a smoke screen"],
	["Supply Drop", "Call a supply drop"],
	["Health Cache", "Send a health cache"],
	["UAV", "Call a UAV"],
	["Airstrike", "Call an airstrike"],
	["Chopper", "Call a chopper gunship"],
]

# ARSENAL COUPLING: weapon ids/names are read from Arsenal when its
# script loads (source of truth), via ResourceLoader + load() — NOT a hard
# class reference — so this store still parses and runs when Arsenal (or
# a script it depends on) is mid-landing / broken: the MIRROR table below
# is the fallback. Same defensive pattern forge_menu.gd uses for
# ModLoader/ModCreator. The mirror is fallback-only; when Arsenal loads,
# Arsenal wins (see _arsenal() / get_weapon_ids()).
const ARSENAL_SCRIPT := "res://scripts/weapons/arsenal.gd"
const MIRROR_WEAPONS := {
	"ar7": "AR-7 MANTICORE",
	"lr8": "LR-8 LONGEYE",
	"sg12": "SG-12 BREACHER",
	"smg9": "SMG-9 HORNET",
	"lmg": "LMG-9 ANVIL",
	"p9": "P9 SIDEARM",
	"br3": "BR-3 TRIDENT",
	"hv44": "HV-44 JUDGE",
	"raptor": "RAPTOR CLAW",
}

var _loadouts: Array[Dictionary] = []
var _active_name: String = ""
var _arsenal_script: GDScript = null
var _arsenal_checked: bool = false


func _ready() -> void:
	_load()


func get_save_path() -> String:
	return SAVE_PATH


# ------------------------------------------------------------------ queries
## Deep copies — callers can never mutate internal state through these.
func get_loadouts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Dictionary in _loadouts:
		out.append(entry.duplicate(true))
	return out


func get_loadout(loadout_name: String) -> Dictionary:
	for entry: Dictionary in _loadouts:
		if str(entry.get("name", "")) == loadout_name:
			return entry.duplicate(true)
	return {}


func has_loadout(loadout_name: String) -> bool:
	for entry: Dictionary in _loadouts:
		if str(entry.get("name", "")).to_lower() == loadout_name.to_lower():
			return true
	return false


func get_active_name() -> String:
	return _active_name


func get_active_loadout() -> Dictionary:
	return get_loadout(_active_name)


## Traversal tool of the ACTIVE loadout (sanitized; "grapple" when the
## active entry predates the field). TDM / Main read this at run start.
## Alias for get_active_traversal(): the TD worker's Main._wire_player
## block calls get_active_traversal_tool(). Both names return the same
## value — keep them in sync (this one forwards).
func get_active_traversal_tool() -> String:
	return get_active_traversal()


func get_active_traversal() -> String:
	var entry: Dictionary = get_active_loadout()
	return _sanitize_traversal(str(entry.get("traversal", DEFAULT_TRAVERSAL)))


## Traversal options for pickers: [[id, display name], ...] in UI order.
func get_traversal_options() -> Array[Array]:
	var out: Array[Array] = []
	for tool: String in TRAVERSAL_TOOLS:
		out.append([tool, str(TRAVERSAL_NAMES.get(tool, tool))])
	return out


## Display name for a traversal id ("" when unknown).
func get_traversal_display_name(tool: String) -> String:
	return str(TRAVERSAL_NAMES.get(tool, ""))


## Slot cap: Progression unlocks raise it; absent Progression -> default.
## Never crashes when Progression is missing.
func get_max_loadout_slots() -> int:
	if is_inside_tree():
		var prog: Node = get_node_or_null("/root/Progression")
		if prog != null and prog.has_method("get_max_loadout_slots"):
			var v: int = int(prog.call("get_max_loadout_slots"))
			return maxi(1, v)
	return DEFAULT_MAX_SLOTS


func can_create_more() -> bool:
	return _loadouts.size() < get_max_loadout_slots()


## The Forge preset options ([label, prompt] pairs) for pickers.
func get_forge_preset_options() -> Array[Array]:
	var out: Array[Array] = []
	for pair: Array in FORGE_PRESET_OPTIONS:
		out.append(pair.duplicate())
	return out


## All known weapon ids (Arsenal.all_weapon_ids() when Arsenal loads:
## base ids + live mod-weapon ids "mod:<mod_id>", else the WEAPONS const,
## else the mirror). Sorted; the picker builds its dropdowns from this.
## A mod id listed here passes _has_weapon, so create/update_loadout
## accept it and it persists in user://loadouts.json exactly like a base
## weapon id; a mod that later goes stale is sanitized to the fallback
## by _sanitize_entry on the next load.
func get_weapon_ids() -> Array[String]:
	var ids: Array[String] = []
	var script: GDScript = _arsenal()
	if script != null:
		# Same defensive method-list check forge_menu.gd uses for
		# ModLoader: call all_weapon_ids() only when it exists.
		var has_all := false
		for m in script.get_script_method_list():
			if str(m.get("name", "")) == "all_weapon_ids":
				has_all = true
				break
		if has_all:
			var all_ids: Variant = script.call("all_weapon_ids")
			if all_ids is Array:
				for wid: Variant in all_ids:
					ids.append(str(wid))
				ids.sort()
				return ids
		var consts: Dictionary = script.get_script_constant_map()
		if consts.has("WEAPONS") and consts.get("WEAPONS") is Dictionary:
			for key: Variant in (consts.get("WEAPONS") as Dictionary).keys():
				ids.append(str(key))
			ids.sort()
			return ids
	for key: String in MIRROR_WEAPONS.keys():
		ids.append(key)
	ids.sort()
	return ids


## Display name for a weapon id ("" when unknown).
func get_weapon_display_name(weapon_id: String) -> String:
	if not _has_weapon(weapon_id):
		return ""
	var script: GDScript = _arsenal()
	if script != null:
		var stats: Variant = script.call("get_stats", weapon_id)
		if stats is Dictionary:
			return str((stats as Dictionary).get("name", weapon_id))
	return str(MIRROR_WEAPONS.get(weapon_id, weapon_id))


## Label for a stored forge_preset prompt ("" -> "None", unknown -> itself).
func get_forge_preset_label(prompt: String) -> String:
	if prompt.is_empty():
		return "None"
	for pair: Array in FORGE_PRESET_OPTIONS:
		if str(pair[1]) == prompt:
			return str(pair[0])
	return prompt


# ------------------------------------------------------------------ mutations
## Creates a loadout. Fails (false) on empty/duplicate name, slot cap, or
## unknown weapon ids. New loadouts do NOT become active automatically.
func create_loadout(loadout_name: String, primary_id: String, secondary_id: String, forge_preset: String = "", traversal: String = DEFAULT_TRAVERSAL) -> bool:
	var clean_name: String = _clean_name(loadout_name)
	if clean_name.is_empty() or has_loadout(clean_name):
		return false
	if not can_create_more():
		return false
	if not _has_weapon(primary_id) or not _has_weapon(secondary_id):
		return false
	var entry: Dictionary = {"name": clean_name, "primary": primary_id, "secondary": secondary_id, "forge_preset": forge_preset, "traversal": _sanitize_traversal(traversal)}
	_loadouts.append(entry)
	if _save():
		loadouts_changed.emit()
		return true
	_loadouts.pop_back()
	return false


## Updates weapons / Forge preset of an existing loadout (name unchanged).
func update_loadout(loadout_name: String, primary_id: String, secondary_id: String, forge_preset: String = "", traversal: String = "") -> bool:
	if not _has_weapon(primary_id) or not _has_weapon(secondary_id):
		return false
	for entry: Dictionary in _loadouts:
		if str(entry.get("name", "")) == loadout_name:
			entry["primary"] = primary_id
			entry["secondary"] = secondary_id
			entry["forge_preset"] = forge_preset
			if not traversal.is_empty():
				entry["traversal"] = _sanitize_traversal(traversal)
			if _save():
				loadouts_changed.emit()
				return true
			return false
	return false


## Renames a loadout. The active pointer follows the rename. Fails on
## empty/duplicate target name or unknown source.
func rename_loadout(old_name: String, new_name: String) -> bool:
	var clean_new: String = _clean_name(new_name)
	if clean_new.is_empty():
		return false
	if clean_new.to_lower() == old_name.to_lower():
		return true  # no-op rename (same name modulo case/whitespace)
	if has_loadout(clean_new):
		return false
	for entry: Dictionary in _loadouts:
		if str(entry.get("name", "")) == old_name:
			entry["name"] = clean_new
			if _active_name == old_name:
				_active_name = clean_new
			if _save():
				loadouts_changed.emit()
				if _active_name == clean_new:
					active_changed.emit(_active_name)
				return true
			return false
	return false


## Deletes a loadout. Refuses to delete the last one (the game always has
## at least one loadout). Deleting the active loadout moves active to the
## first remaining entry.
func delete_loadout(loadout_name: String) -> bool:
	if _loadouts.size() <= 1:
		return false
	for i: int in range(_loadouts.size()):
		var entry: Dictionary = _loadouts[i]
		if str(entry.get("name", "")) == loadout_name:
			var was_active: bool = (_active_name == loadout_name)
			_loadouts.remove_at(i)
			if was_active:
				_active_name = str(_loadouts[0].get("name", ""))
			if _save():
				loadouts_changed.emit()
				if was_active:
					active_changed.emit(_active_name)
				return true
			return false
	return false


## Sets the active loadout (the one Deploy uses). Fails on unknown name.
func set_active(loadout_name: String) -> bool:
	if not has_loadout(loadout_name):
		return false
	# Resolve to the stored casing (names are matched case-insensitively).
	for entry: Dictionary in _loadouts:
		if str(entry.get("name", "")).to_lower() == loadout_name.to_lower():
			_active_name = str(entry.get("name", ""))
			break
	if _save():
		active_changed.emit(_active_name)
		return true
	return false


## Equips a named loadout on a WeaponManager (via equip_loadout). Returns
## false when the name is unknown or the node has no equip_loadout.
func apply_loadout_to(loadout_name: String, wm: Node) -> bool:
	var entry: Dictionary = get_loadout(loadout_name)
	if entry.is_empty():
		return false
	if wm == null or not wm.has_method("equip_loadout"):
		return false
	wm.call("equip_loadout", str(entry.get("primary", "")), str(entry.get("secondary", "")))
	return true


## Equips the ACTIVE loadout on a WeaponManager. Deploy path.
func apply_active_to(wm: Node) -> bool:
	return apply_loadout_to(_active_name, wm)


## Test/support hook: restore the 5 base presets + first active.
func reset_to_defaults() -> void:
	_seed_defaults()
	_save()
	loadouts_changed.emit()
	active_changed.emit(_active_name)



## The Arsenal GDScript when it loads, else null. Cached (including null)
## so a broken Arsenal prints its load errors once, not per call.
func _arsenal() -> GDScript:
	if _arsenal_checked:
		return _arsenal_script
	_arsenal_checked = true
	if not ResourceLoader.exists(ARSENAL_SCRIPT):
		return null
	var loaded: Resource = load(ARSENAL_SCRIPT)
	if loaded is GDScript:
		_arsenal_script = loaded as GDScript
	return _arsenal_script


## Weapon-id validity: Arsenal.has_weapon when Arsenal loads, else the mirror.
func _has_weapon(weapon_id: String) -> bool:
	var script: GDScript = _arsenal()
	if script != null:
		return bool(script.call("has_weapon", weapon_id))
	return MIRROR_WEAPONS.has(weapon_id)


# ------------------------------------------------------------------ persistence
func _seed_defaults() -> void:
	_loadouts.clear()
	for entry: Dictionary in DEFAULT_LOADOUTS:
		_loadouts.append(entry.duplicate(true))
	_active_name = str(DEFAULT_LOADOUTS[0].get("name", ""))


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		_seed_defaults()
		_save()
		return
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		_seed_defaults()
		return
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	var raw_list: Array = []
	var raw_active: String = ""
	if parsed is Dictionary:
		var d: Dictionary = parsed as Dictionary
		if d.get("loadouts") is Array:
			raw_list = d.get("loadouts") as Array
		raw_active = str(d.get("active", ""))
	elif parsed is Array:
		# Legacy shape: bare array of loadout entries.
		raw_list = parsed as Array
	else:
		# Corrupt JSON / wrong top-level type -> defaults, in memory only.
		_seed_defaults()
		return
	var seen: Dictionary = {}
	var cleaned: Array[Dictionary] = []
	for raw: Variant in raw_list:
		var entry: Dictionary = _sanitize_entry(raw)
		if entry.is_empty():
			continue
		var key: String = str(entry.get("name", "")).to_lower()
		if seen.has(key):
			continue
		seen[key] = true
		cleaned.append(entry)
	if cleaned.is_empty():
		_seed_defaults()
		return
	_loadouts = cleaned
	_active_name = ""
	for entry: Dictionary in _loadouts:
		if str(entry.get("name", "")) == raw_active:
			_active_name = raw_active
			break
	if _active_name.is_empty():
		_active_name = str(_loadouts[0].get("name", ""))


## One entry -> sanitized entry, or {} when unrecoverable. Unknown weapon
## ids fall back (never drop a named loadout for a stale weapon id).
func _sanitize_entry(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var d: Dictionary = raw as Dictionary
	var clean_name: String = _clean_name(str(d.get("name", "")))
	if clean_name.is_empty():
		return {}
	var primary: String = str(d.get("primary", ""))
	if not _has_weapon(primary):
		primary = FALLBACK_PRIMARY
	var secondary: String = str(d.get("secondary", ""))
	if not _has_weapon(secondary):
		secondary = FALLBACK_SECONDARY
	var out: Dictionary = {
		"name": clean_name,
		"primary": primary,
		"secondary": secondary,
		"forge_preset": str(d.get("forge_preset", "")),
		"traversal": _sanitize_traversal(str(d.get("traversal", DEFAULT_TRAVERSAL))),
	}
	return out


## Traversal ids outside the known three sanitize to the default —
## except the legacy "portal_gun" id, which migrates to the canonical
## "portal" so older saves keep their Portal Gun choice instead of
## silently dropping to grapple.
func _sanitize_traversal(raw: String) -> String:
	if raw == "portal_gun":
		return "portal"
	if TRAVERSAL_TOOLS.has(raw):
		return raw
	return DEFAULT_TRAVERSAL


func _save() -> bool:
	var data: Dictionary = {
		"version": SAVE_VERSION,
		"active": _active_name,
		"loadouts": _loadouts,
	}
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("FORGEFALL Loadouts: could not write %s" % SAVE_PATH)
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true


func _clean_name(raw: String) -> String:
	var clean: String = raw.strip_edges()
	if clean.length() > MAX_NAME_LEN:
		clean = clean.substr(0, MAX_NAME_LEN).strip_edges()
	return clean
