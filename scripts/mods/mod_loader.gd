# FORGEFALL — ModLoader (v0.7 chunk 1: user mods, Worker A)
# Scans user://mods/ at startup, validates every mod, and registers the
# survivors for the Forge LLM catalog + ForgeBuilder. Broken mods are
# recorded with an error and EXCLUDED — never a crash, never a load of a
# mod that failed validation.
#
# Layout: user://mods/<mod-id>/  (folder mod) or user://mods/<mod-id>.json
# / user://mods/<mod-id>.gd (single-file mod). The mod id is the stable
# folder/file name. Enabled state persists in user://mods_enabled.json
# (Dictionary mod_id -> bool); new mods default to enabled=true.
#
# TWO MOD KINDS:
# (a) JSON BLOCKS (data-only): a manifest + a "block" object (see
#     JSON BLOCK SCHEMA below). Every field is schema-validated (types,
#     ranges, references to known assets/blocks) BEFORE registration.
# (b) GDScript SCRIPTS: must `extend ModBlock`, talk to the game ONLY via
#     ModAPI, and pass a forbidden-API text scan BEFORE load (see
#     FORBIDDEN_SNIPPETS). The scan is a guardrail, not a sandbox — a mod
#     script runs with game trust, so only install mods you trust.
#     HOOK CODE inside a script mod (a hook dict's "code" string, or a
#     hook_files entry) is held to the STRICTER allowlist instead:
#     ModHook.validate_hook_code() — only ModAPI + safe builtins, with
#     the violation named, and call cycles rejected (the engine
#     synthesizes a default return on abort, so cycles are the
#     run-time-abort vector validation must close). A hook that errors
#     at LOAD, or exceeds its step/time budget at run, DISABLES THE MOD
#     VISIBLY (note_hook_runtime_failure), never crashes. (Recoverable
#     run-time errors print to the engine log and the hook completes —
#     see ModHookRegistry header for the honest limits.)
#
# Records: internal records carry the 8 public keys (id, name, kind,
# version, author, enabled, error, path) PLUS block_info (the validated
# block dict — for JSON mods, the "block" object; for script mods, the
# get_block_info() result), script_path ("" for JSON mods), and hooks
# (validated invented hooks, see ModHook — [] when the mod adds none).
# get_mods() returns ONLY the 8 public keys; find_mod() returns the full
# record for the catalog / builder / gate, which need block_info + hooks.
extends RefCounted
class_name ModLoader

const MODS_DIR := "user://mods/"
const STATE_PATH := "user://mods_enabled.json"

## Per-target fields a JSON/script block may declare, on top of the common
## block_id/target/cost/display_name/description.
const WEAPON_BLOCK_FIELDS := ["base_weapon_id", "damage_mult", "mag_mult", "range_mult", "ammo_type"]
const COVER_BLOCK_FIELDS := ["shape", "size_voxels", "hp", "property", "color"]
const STRUCTURE_BLOCK_FIELDS := ["shape", "property"]
const TURRET_BLOCK_FIELDS := ["duration_sec", "damage_mult", "range_mult", "ammo_type"]
const PICKUP_BLOCK_FIELDS := ["kind", "amount"]

const BASE_WEAPON_IDS := ["manticore", "longeye", "breacher", "hornet", "p9", "raptor", "lmg", "trident", "judge"]
const AMMO_TYPES := ["standard", "sniper", "armor_piercing", "buckshot"]
const BLOCK_PROPERTIES := ["standard", "reinforced"]

## Forbidden substrings in mod SCRIPT source. Checked BEFORE load; any hit
## disables the mod with an error. Fail-closed by design (e.g. "load(" also
## matches "download(" — rename such helpers). This list is the floor, not
## the ceiling: ModBlock's contract is ModAPI-only, full stop.
const FORBIDDEN_SNIPPETS := [
	"OS.execute", "OS.shell_open", "OS.create_process", "OS.",
	"FileAccess", "DirAccess",
	"Engine.get_singleton",
	"Expression", "GDScript.new",
	"load(", "ResourceLoader", "preload(",
	"ClassDB", "JavaScriptBridge",
	"HTTPRequest", "HTTPClient", "TCPServer", "TCPStreamPeer",
	"UDPServer", "PacketPeerUDP", "WebSocketPeer",
	"Thread", "Semaphore", "Mutex",
	".new(", "call(", "call_deferred(",
	"@tool",
]

static var _mods: Array = []
static var _enabled: Dictionary = {}
static var _scanned := false

## Max hooks one mod may carry (bounds dispatch work per shot).
const MAX_HOOKS_PER_MOD := 32


## Stamps each validated hook dict with its owning mod's id
## ("_mod_id", an internal key ModHook.validate_hook_data() accepts).
## The registry uses it to gate a hook on its mod's live record: a
## mod disabled at run time (load/run error, budget) stops running.
## Session MAKE hooks are never stamped (no ModLoader record) and are
## therefore never gated — they run for their session only.
static func _stamp_hook_mod_ids(hooks: Array, mod_id: String) -> void:
	for h in hooks:
		if h is Dictionary:
			(h as Dictionary)["_mod_id"] = mod_id

## Recent find_mod calls ({"ref": String, "at_msec": int}, oldest first,
## capped at 8). ModHookRegistry's pending-attach rule reads this: a
## real build calls find_mod for the same ref twice in quick succession
## (gate + build), while speculative lookups (catalog listing, offline
## name matching) never produce two consecutive same-ref calls.
static var _find_history: Array = []


## Scan user://mods/, validate, register. Safe to call repeatedly.
static func scan_mods() -> void:
	_mods = []
	_enabled = _load_enabled_state()
	_ensure_dir()
	var dir := DirAccess.open(MODS_DIR)
	if dir == null:
		_scanned = true
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		# "assets" is the voxel-asset cache (VoxelAssetGenerator), not a
		# mod — skip it here so it never shows as a broken mod entry
		# (missing manifest) in the Forge Mods tab.
		if not entry.begins_with(".") and entry != "assets":
			var full := MODS_DIR.path_join(entry)
			if dir.current_is_dir():
				_scan_folder(entry, full)
			elif entry.ends_with(".json") or entry.ends_with(".gd"):
				_scan_file(entry, full)
		entry = dir.get_next()
	dir.list_dir_end()
	_scanned = true


## Re-scan (same as scan_mods, callable from UI).
static func rescan() -> void:
	scan_mods()


## One Dictionary per mod, EXACT keys: id, name, kind, version, author,
## enabled, error ("" when OK), path. Includes broken/disabled mods.
static func get_mods() -> Array:
	_ensure_scanned()
	var out: Array = []
	for rec in _mods:
		out.append(_public_record(rec))
	return out


## Enabled AND error-free mods (the catalog / builder view), same shape.
static func get_enabled_mods() -> Array:
	_ensure_scanned()
	var out: Array = []
	for rec in _mods:
		if bool(rec.get("enabled", false)) and str(rec.get("error", "")) == "":
			out.append(_public_record(rec))
	return out


## Full internal record for `ref` (a mod id, or a block_id declared by a
## mod) — public keys PLUS block_info + script_path + hooks. {} when not
## found. Prefer exact mod-id matches; fall back to block_id matches.
## `track_history` (default true) records the lookup for
## ModHookRegistry's pending-attach pair rule; pass false for internal /
## re-reads that must not count as a build lookup.
static func find_mod(ref: String, track_history: bool = true) -> Dictionary:
	_ensure_scanned()
	if track_history:
		_find_history.append({"ref": ref, "at_msec": Time.get_ticks_msec()})
		while _find_history.size() > 8:
			_find_history.pop_front()
	for rec in _mods:
		if str(rec.get("id", "")) == ref:
			return rec
	for rec in _mods:
		var info: Dictionary = rec.get("block_info", {})
		if str(info.get("block_id", "")) == ref:
			return rec
	return {}


## Recent find_mod history (see _find_history). A copy; callers must
## not mutate the registry's view of it.
static func get_find_history() -> Array:
	return _find_history.duplicate(true)


## Clears the find_mod history (called when a pending attach is
## consumed, so a stale pair can never attach a second weapon).
static func clear_find_history() -> void:
	_find_history = []


## Records that a hook of an installed mod failed at RUN time (or
## exceeded its step/time budget). The mod is DISABLED VISIBLY: its
## record carries the error (the Forge Mods tab shows it) and its hooks
## stop running (ModHookRegistry gates on the record's error). Never a
## crash, never silent. NOT persisted: a rescan re-validates from disk
## and gives the mod a fresh chance. A record that already has an error
## keeps its FIRST error (no overwrite by a later failure).
static func note_hook_runtime_failure(mod_id: String, hook_id: String, reason: String) -> void:
	_ensure_scanned()
	for rec in _mods:
		if str(rec.get("id", "")) == mod_id:
			if str(rec.get("error", "")) != "":
				return
			rec["error"] = "hook '%s' failed at run time: %s — mod disabled" % [hook_id, reason]
			rec["enabled"] = false
			return


## Updates enabled state AND persists it to user://mods_enabled.json.
## Unknown ids are ignored.
static func set_mod_enabled(mod_id: String, enabled: bool) -> void:
	_ensure_scanned()
	for rec in _mods:
		if str(rec.get("id", "")) == mod_id:
			rec["enabled"] = enabled
			_enabled[mod_id] = enabled
			_persist_enabled()
			return


# --- Scanning ---------------------------------------------------------------

static func _ensure_scanned() -> void:
	if not _scanned:
		scan_mods()


static func _ensure_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	if not dir.dir_exists("mods"):
		dir.make_dir("mods")


static func _base_record(mod_id: String, path: String) -> Dictionary:
	return {
		"id": mod_id,
		"name": mod_id,
		"kind": "block",
		"version": "1.0",
		"author": "",
		"enabled": bool(_enabled.get(mod_id, true)),
		"error": "",
		"path": path,
		"spell_school": "",
		"block_info": {},
		"script_path": "",
		"hooks": [],
	}


static func _public_record(rec: Dictionary) -> Dictionary:
	return {
		"id": str(rec.get("id", "")),
		"name": str(rec.get("name", "")),
		"kind": str(rec.get("kind", "")),
		"version": str(rec.get("version", "")),
		"author": str(rec.get("author", "")),
		"enabled": bool(rec.get("enabled", false)),
		"error": str(rec.get("error", "")),
		"path": str(rec.get("path", "")),
		"spell_school": str(rec.get("spell_school", "")),
	}


## Folder mod: <folder>/manifest.json (+ payload file, or an inline
## "block" object in the manifest for JSON blocks).
static func _scan_folder(mod_id: String, folder: String) -> void:
	var rec := _base_record(mod_id, folder)
	var manifest_path := folder.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path):
		rec["kind"] = _infer_kind(folder)
		rec["error"] = "missing manifest.json"
		_mods.append(rec)
		return
	var manifest: Variant = _parse_json_file(manifest_path)
	if not (manifest is Dictionary):
		rec["error"] = "manifest.json is not a JSON object"
		_mods.append(rec)
		return
	_apply_manifest(rec, manifest)
	if rec["error"] != "":
		_mods.append(rec)
		return
	var kind := str(rec.get("kind", "block"))
	# v0.5.3 INVENTED HOOKS: a folder manifest may carry data hooks
	# ("hooks") and, for script mods, hook-code files ("hook_files").
	var manifest_hooks: Array = []
	var manifest_hook_files: Array = []
	if (manifest as Dictionary).has("hooks"):
		if not ((manifest as Dictionary)["hooks"] is Array):
			rec["error"] = "manifest 'hooks' must be an array"
			_mods.append(rec)
			return
		manifest_hooks = ((manifest as Dictionary)["hooks"] as Array).duplicate(true)
	if (manifest as Dictionary).has("hook_files"):
		if kind != "script":
			rec["error"] = "manifest 'hook_files' requires kind 'script'"
			_mods.append(rec)
			return
		if not ((manifest as Dictionary)["hook_files"] is Array):
			rec["error"] = "manifest 'hook_files' must be an array"
			_mods.append(rec)
			return
		manifest_hook_files = ((manifest as Dictionary)["hook_files"] as Array).duplicate(true)
	if kind == "block" and (manifest as Dictionary).has("block") and (manifest as Dictionary)["block"] is Dictionary:
		_finish_json_block(rec, (manifest as Dictionary)["block"], manifest_hooks)
		return
	var payload := str((manifest as Dictionary).get("file", ""))
	if payload.is_empty():
		payload = _infer_payload(folder, kind, manifest)
	if payload.is_empty() or not FileAccess.file_exists(folder.path_join(payload)):
		rec["error"] = "payload file '%s' not found" % payload
		_mods.append(rec)
		return
	if kind == "block":
		var data: Variant = _parse_json_file(folder.path_join(payload))
		_finish_json_block(rec, data, manifest_hooks)
	else:
		_finish_script_mod(rec, folder.path_join(payload), manifest_hooks, manifest_hook_files, folder)


## Single-file mod: <id>.json (manifest + block inline) or <id>.gd
## (script; an optional <id>.json next to it supplies name/version/author).
static func _scan_file(entry: String, full: String) -> void:
	var mod_id := entry.get_basename()
	var rec := _base_record(mod_id, full)
	if entry.ends_with(".json"):
		var data: Variant = _parse_json_file(full)
		if not (data is Dictionary):
			rec["error"] = "not a JSON object"
			_mods.append(rec)
			return
		_apply_manifest(rec, data)
		if rec["error"] != "":
			_mods.append(rec)
			return
		if str(rec.get("kind", "block")) != "block":
			rec["error"] = "single-file .json mod must be kind 'block'"
			_mods.append(rec)
			return
		_finish_json_block(rec, data)
		return
	# .gd single file: companion <id>.json may carry manifest fields.
	var companion := full.get_basename() + ".json"
	var companion_hooks: Array = []
	var companion_hook_files: Array = []
	if FileAccess.file_exists(companion):
		var m: Variant = _parse_json_file(companion)
		if m is Dictionary:
			_apply_manifest(rec, m)
			if rec["error"] != "":
				_mods.append(rec)
				return
			if (m as Dictionary).has("hooks") and (m as Dictionary)["hooks"] is Array:
				companion_hooks = ((m as Dictionary)["hooks"] as Array).duplicate(true)
			if (m as Dictionary).has("hook_files") and (m as Dictionary)["hook_files"] is Array:
				companion_hook_files = ((m as Dictionary)["hook_files"] as Array).duplicate(true)
	# A lone .gd is a script mod regardless of what the companion said.
	rec["kind"] = "script"
	_finish_script_mod(rec, full, companion_hooks, companion_hook_files, MODS_DIR)


## Manifest fields (name/kind/version/author) + basic manifest validation.
## Sets rec["error"] on a manifest problem; otherwise leaves it "".
static func _apply_manifest(rec: Dictionary, manifest: Dictionary) -> void:
	if manifest.has("name"):
		if not (manifest["name"] is String) or str(manifest["name"]).strip_edges().is_empty():
			rec["error"] = "manifest 'name' must be a non-empty string"
			return
		rec["name"] = str(manifest["name"])
	if manifest.has("kind"):
		var kind := str(manifest["kind"])
		if kind not in ["block", "script"]:
			rec["error"] = "manifest 'kind' must be 'block' or 'script'"
			return
		rec["kind"] = kind
	if manifest.has("version"):
		if not (manifest["version"] is String):
			rec["error"] = "manifest 'version' must be a string"
			return
		rec["version"] = str(manifest["version"])
	if manifest.has("author"):
		if not (manifest["author"] is String):
			rec["error"] = "manifest 'author' must be a string"
			return
		rec["author"] = str(manifest["author"])


static func _infer_kind(folder: String) -> String:
	for f in DirAccess.get_files_at(folder):
		if f.ends_with(".gd"):
			return "script"
	return "block"


## Default payload filename when the manifest names none: block.json /
## mod.gd, else the first other .json / .gd in the folder.
static func _infer_payload(folder: String, kind: String, manifest: Dictionary) -> String:
	var files := DirAccess.get_files_at(folder)
	var preferred := "block.json" if kind == "block" else "mod.gd"
	if preferred in files:
		return preferred
	for f in files:
		if f == "manifest.json":
			continue
		if kind == "block" and f.ends_with(".json"):
			return f
		if kind == "script" and f.ends_with(".gd"):
			return f
	return ""


# --- JSON blocks ------------------------------------------------------------
#
# JSON BLOCK SCHEMA (manifest + block object):
#   manifest: {"name": str, "kind": "block", "version": str, "author": str?}
#   block: {"block_id": "my_wall", "target": "weapon"|"cover"|"structure"|"turret"|"pickup",
#           "cost": 0-2000 int, "display_name": str, "description": str?,
#           ...per-target fields...}
#   weapon:    base_weapon_id (a base Forge weapon id), damage_mult 0.1-5?,
#              mag_mult 0.25-4?, range_mult 0.1-5?, ammo_type?
#   cover:     shape wall|tower|barricade, size_voxels [1-12]^3,
#              hp 50-500, property standard|reinforced?, color?
#              (color = a VoxelBuilder palette name, or "#rrggbb" hex)
#   structure: shape bridge|bunker|watchtower|ammo_depot,
#              property standard|reinforced?
#   turret:    duration_sec 5-120, damage_mult 0.1-5?, range_mult 0.1-3?,
#              ammo_type?
#   pickup:    kind ammo|health, amount 1-500
# Unknown block fields are rejected (no silent typos). The LLM references a
# block via params {"mod_block": "<mod id or block_id>"}; the game looks
# the block up and recomputes cost from its declared cost.

static func _finish_json_block(rec: Dictionary, data: Variant, manifest_hooks: Array = []) -> void:
	var split := _split_block_and_hooks(data)
	if str(split.get("error", "")) != "":
		rec["error"] = str(split.get("error", ""))
		_mods.append(rec)
		return
	var block: Variant = split.get("block", null)
	if not (block is Dictionary):
		rec["error"] = "block payload is not a JSON object"
		_mods.append(rec)
		return
	var err := _validate_block(block)
	if err != "":
		rec["error"] = err
		_mods.append(rec)
		return
	var bid := str((block as Dictionary).get("block_id", ""))
	if _block_id_taken(bid, str(rec.get("id", ""))):
		rec["error"] = "duplicate block_id '%s'" % bid
		_mods.append(rec)
		return
	# v0.5.3 INVENTED HOOKS: manifest hooks + payload hooks, merged.
	# A bad hook disables the whole mod with a visible error.
	var hooks_raw: Array = []
	hooks_raw.append_array(manifest_hooks)
	hooks_raw.append_array(split.get("hooks", []))
	var validated := _validate_hook_list(hooks_raw)
	if str(validated.get("error", "")) != "":
		rec["error"] = str(validated.get("error", ""))
		_mods.append(rec)
		return
	rec["hooks"] = validated.get("hooks", [])
	_stamp_hook_mod_ids(rec["hooks"], str(rec.get("id", "")))
	rec["block_info"] = block
	# v0.5.8 spell schools: school lives OUTSIDE the block object, as a
	# top-level payload field (wrapper form {"block": {...},
	# "spell_school": ...}). Pure-block payloads carry no school.
	if data is Dictionary and (data as Dictionary).has("block"):
		rec["spell_school"] = SpellSchools.normalize(str((data as Dictionary).get("spell_school", "")))
	_mods.append(rec)


## Splits a JSON block payload into its block dict + its hooks array.
## Accepts {"block": {...}, "hooks": [...]} and a pure block dict with
## a top-level "hooks" key. Returns {"block", "hooks", "error"}.
static func _split_block_and_hooks(data: Variant) -> Dictionary:
	if not (data is Dictionary):
		return {"block": null, "hooks": [], "error": "block payload is not a JSON object"}
	var d := data as Dictionary
	if d.has("block") and d["block"] is Dictionary:
		var hooks: Variant = d.get("hooks", null)
		if hooks != null and not (hooks is Array):
			return {"block": null, "hooks": [], "error": "payload 'hooks' must be an array"}
		return {"block": (d["block"] as Dictionary).duplicate(true),
			"hooks": (hooks as Array).duplicate(true) if hooks is Array else [], "error": ""}
	var block := d.duplicate(true)
	var hooks2: Variant = block.get("hooks", null)
	if hooks2 != null:
		if not (hooks2 is Array):
			return {"block": null, "hooks": [], "error": "payload 'hooks' must be an array"}
		block.erase("hooks")
		return {"block": block, "hooks": (hooks2 as Array).duplicate(true), "error": ""}
	return {"block": block, "hooks": [], "error": ""}


## Validates a merged hook list (data hooks from any source). Returns
## {"hooks": Array (validated, in order), "error": String}. "" error = OK.
## Duplicate hook_ids are rejected; a hook that fails validation
## rejects the whole list (the mod is disabled with the error).
## At most MAX_HOOKS_PER_MOD hooks (bounds dispatch work).
static func _validate_hook_list(raw: Array) -> Dictionary:
	if raw.size() > MAX_HOOKS_PER_MOD:
		return {"hooks": [], "error": "mod carries %d hooks (max %d)" % [raw.size(), MAX_HOOKS_PER_MOD]}
	var out: Array = []
	var seen := {}
	for item in raw:
		if not (item is Dictionary):
			return {"hooks": [], "error": "hook is not an object"}
		var copy: Dictionary = (item as Dictionary).duplicate(true)
		var err := ModHook.validate_hook_data(copy)
		if err != "":
			return {"hooks": [], "error": err}
		var hid := str(copy.get("hook_id", ""))
		if seen.has(hid):
			return {"hooks": [], "error": "duplicate hook_id '%s'" % hid}
		seen[hid] = true
		out.append(copy)
	return {"hooks": out, "error": ""}


## Loads ONE hook-code file (a folder manifest "hook_files" entry) into
## a hook record {"hook_id", "hook_point", "display_name"?, "description"?,
## "code"}. The file must extend ModHook, pass the allowlist validator
## (ModHook.validate_hook_code), compile, and declare its id/point via
## get_hook_info(). Returns {"record": Dictionary, "error": String}.
static func _load_hook_file(folder: String, name: Variant) -> Dictionary:
	if not (name is String) or str(name).strip_edges().is_empty():
		return {"record": {}, "error": "hook file name must be a non-empty string"}
	var fname := str(name)
	if ".." in fname or fname.begins_with("/") or fname.begins_with("user://"):
		return {"record": {}, "error": "bad hook file path '%s'" % fname}
	if not fname.ends_with(".gd"):
		return {"record": {}, "error": "hook file '%s' must be a .gd file" % fname}
	var path := folder.path_join(fname)
	if not FileAccess.file_exists(path):
		return {"record": {}, "error": "hook file '%s' not found" % fname}
	var text := FileAccess.get_file_as_string(path)
	var cerr := ModHook.validate_hook_code(text)
	if cerr != "":
		return {"record": {}, "error": cerr}
	var compiled := ModHook.compile_hook_code(text)
	if str(compiled.get("error", "")) != "":
		return {"record": {}, "error": str(compiled.get("error", ""))}
	var inst := compiled.get("instance") as ModHook
	var info: Variant = inst.get_hook_info()
	if not (info is Dictionary):
		return {"record": {}, "error": "hook file '%s': get_hook_info() did not return a Dictionary" % fname}
	var hid: Variant = (info as Dictionary).get("hook_id", null)
	var point: Variant = (info as Dictionary).get("hook_point", null)
	if not (hid is String) or str(hid).strip_edges().is_empty():
		return {"record": {}, "error": "hook file '%s': get_hook_info() has no hook_id" % fname}
	if not (point is String) or str(point).strip_edges().is_empty():
		return {"record": {}, "error": "hook file '%s': get_hook_info() has no hook_point" % fname}
	var record := {"hook_id": str(hid), "hook_point": str(point), "code": text}
	if (info as Dictionary).has("display_name"):
		record["display_name"] = str((info as Dictionary).get("display_name", ""))
	if (info as Dictionary).has("description"):
		record["description"] = str((info as Dictionary).get("description", ""))
	return {"record": record, "error": ""}


## Validates + normalizes a block dict in place (cost -> int, color ->
## "#rrggbb" or palette name). Returns "" when valid, else an error.
## require_data=true (JSON blocks): per-target data fields are REQUIRED —
## the block IS the data. require_data=false (script mods): the script's
## apply() decides what to build, so per-target fields are OPTIONAL, but
## any that ARE present are still type/range-checked.
static func _validate_block(block: Dictionary, require_data: bool = true) -> String:
	var bid: Variant = block.get("block_id", null)
	if not (bid is String) or str(bid).is_empty():
		return "block 'block_id' must be a non-empty string"
	if not _is_block_id(str(bid)):
		return "block_id '%s' must use only [a-z0-9_]" % str(bid)
	var target: Variant = block.get("target", null)
	if not (target is String) or str(target) not in ["weapon", "cover", "structure", "turret", "pickup"]:
		return "block 'target' must be weapon|cover|structure|turret|pickup"
	var cost: Variant = block.get("cost", null)
	if not (cost is int or cost is float) or float(cost) < 0.0 or float(cost) > 2000.0:
		return "block 'cost' must be a number 0-2000"
	block["cost"] = int(cost)
	var disp: Variant = block.get("display_name", null)
	if not (disp is String) or str(disp).strip_edges().is_empty() or str(disp).length() > 80:
		return "block 'display_name' must be a non-empty string (max 80 chars)"
	if block.has("description") and not (block["description"] is String):
		return "block 'description' must be a string"
	if block.has("description") and str(block["description"]).length() > 300:
		return "block 'description' must be at most 300 chars"
	var allowed: Array = ["block_id", "target", "cost", "display_name", "description"]
	match str(target):
		"weapon":
			allowed += WEAPON_BLOCK_FIELDS
		"cover":
			allowed += COVER_BLOCK_FIELDS
		"structure":
			allowed += STRUCTURE_BLOCK_FIELDS
		"turret":
			allowed += TURRET_BLOCK_FIELDS
		"pickup":
			allowed += PICKUP_BLOCK_FIELDS
	for k in block.keys():
		if str(k) not in allowed:
			return "unknown block field '%s' for target '%s'" % [str(k), str(target)]
	match str(target):
		"weapon":
			var base: Variant = block.get("base_weapon_id", null)
			if base != null or require_data:
				if not (base is String) or str(base) not in BASE_WEAPON_IDS:
					return "weapon block 'base_weapon_id' must be a known weapon id"
			if block.has("ammo_type") and str(block["ammo_type"]) not in AMMO_TYPES:
				return "bad ammo_type '%s'" % str(block["ammo_type"])
			for field in ["damage_mult", "range_mult"]:
				if block.has(field) and not _is_num_in(block[field], 0.1, 5.0):
					return "weapon block '%s' out of range 0.1-5" % field
			if block.has("mag_mult") and not _is_num_in(block["mag_mult"], 0.25, 4.0):
				return "weapon block 'mag_mult' out of range 0.25-4"
		"cover":
			if block.has("shape") or require_data:
				if not (str(block.get("shape", "")) in ["wall", "tower", "barricade"]):
					return "cover block 'shape' must be wall|tower|barricade"
			if block.has("size_voxels") or require_data:
				if not _is_size_voxels(block.get("size_voxels", null)):
					return "cover block 'size_voxels' must be [x,y,z] each 1-12"
			if block.has("hp") or require_data:
				if not _is_num_in(block.get("hp", null), 50.0, 500.0):
					return "cover block 'hp' out of range 50-500"
			if block.has("property") and str(block["property"]) not in BLOCK_PROPERTIES:
				return "bad cover block property '%s'" % str(block["property"])
			if block.has("color"):
				var cerr := _normalize_color(block)
				if cerr != "":
					return cerr
		"structure":
			if block.has("shape") or require_data:
				if not (str(block.get("shape", "")) in ["bridge", "bunker", "watchtower", "ammo_depot"]):
					return "structure block 'shape' must be bridge|bunker|watchtower|ammo_depot"
			if block.has("property") and str(block["property"]) not in BLOCK_PROPERTIES:
				return "bad structure block property '%s'" % str(block["property"])
		"turret":
			if block.has("duration_sec") or require_data:
				if not _is_num_in(block.get("duration_sec", null), 5.0, 120.0):
					return "turret block 'duration_sec' out of range 5-120"
			if block.has("damage_mult") and not _is_num_in(block["damage_mult"], 0.1, 5.0):
				return "turret block 'damage_mult' out of range 0.1-5"
			if block.has("range_mult") and not _is_num_in(block["range_mult"], 0.1, 3.0):
				return "turret block 'range_mult' out of range 0.1-3"
			if block.has("ammo_type") and str(block["ammo_type"]) not in AMMO_TYPES:
				return "bad ammo_type '%s'" % str(block["ammo_type"])
		"pickup":
			if block.has("kind") or require_data:
				if not (str(block.get("kind", "")) in ["ammo", "health"]):
					return "pickup block 'kind' must be ammo|health"
			if block.has("amount") or require_data:
				if not _is_int_in(block.get("amount", null), 1, 500):
					return "pickup block 'amount' out of range 1-500"
	return ""


## Palette name or "#rrggbb" hex. Normalizes hex to "#rrggbb" in place.
static func _normalize_color(block: Dictionary) -> String:
	var c: Variant = block.get("color", null)
	if not (c is String):
		return "cover block 'color' must be a palette name or '#rrggbb'"
	var s := str(c).strip_edges()
	if s in VoxelBuilder.PALETTE:
		return ""
	var hex := s.trim_prefix("#")
	if hex.length() != 6:
		return "cover block 'color' must be a palette name or '#rrggbb'"
	for ch in hex:
		if not ("0123456789abcdefABCDEF".contains(ch)):
			return "cover block 'color' must be a palette name or '#rrggbb'"
	block["color"] = "#" + hex.to_lower()
	return ""


## Loads + instantiates a script mod's ModBlock (fresh instance per call).
## Returns null when the script fails to load/compile/instantiate or is
## not a ModBlock. The caller (scan-time validation, build-time apply)
## checks the return. Kept here — NOT in ForgeBuilder — because the
## project's no-exec check forbids dynamic load() calls in scripts/forge/*.
static func instantiate_script_mod(rec: Dictionary) -> ModBlock:
	var script_path := str(rec.get("script_path", ""))
	if script_path.is_empty():
		return null
	var scr := ResourceLoader.load(script_path) as GDScript
	if scr == null or not scr.can_instantiate():
		return null
	# Instantiation runs the mod's _init (must stay side-effect free per
	# the ModBlock contract).
	var inst: Variant = scr.new()
	if not (inst is ModBlock):
		return null
	return inst as ModBlock


# --- GDScript mods ----------------------------------------------------------

static func _finish_script_mod(rec: Dictionary, script_path: String, manifest_hooks: Array = [], hook_files: Array = [], hook_folder: String = "") -> void:
	rec["script_path"] = script_path
	if not FileAccess.file_exists(script_path):
		rec["error"] = "script file not found"
		_mods.append(rec)
		return
	var text := FileAccess.get_file_as_string(script_path)
	if text.strip_edges().is_empty():
		rec["error"] = "script file is empty"
		_mods.append(rec)
		return
	var forbidden := _scan_forbidden(text)
	if forbidden != "":
		rec["error"] = "forbidden API in script: %s" % forbidden
		_mods.append(rec)
		return
	# v0.5.8 spell schools: script mods carry "# spell_school: <school>".
	rec["spell_school"] = SpellSchools.parse_from_payload(text)
	if not _extends_mod_block(text):
		rec["error"] = "script must 'extend ModBlock'"
		_mods.append(rec)
		return
	var inst := instantiate_script_mod(rec)
	if inst == null:
		rec["error"] = "script failed to load/compile"
		_mods.append(rec)
		return
	var info: Variant = (inst as ModBlock).get_block_info()
	if not (info is Dictionary):
		rec["error"] = "get_block_info() did not return a Dictionary"
		_mods.append(rec)
		return
	var err := _validate_block(info, false)
	if err != "":
		rec["error"] = err
		_mods.append(rec)
		return
	var bid := str((info as Dictionary).get("block_id", ""))
	if _block_id_taken(bid, str(rec.get("id", ""))):
		rec["error"] = "duplicate block_id '%s'" % bid
		_mods.append(rec)
		return
	# v0.5.3 INVENTED HOOKS: manifest data hooks + get_hooks() +
	# hook-code files, merged. A bad hook disables the whole mod.
	var hooks_raw: Array = []
	hooks_raw.append_array(manifest_hooks)
	var gh: Variant = (inst as ModBlock).get_hooks()
	if not (gh is Array):
		rec["error"] = "get_hooks() did not return an Array"
		_mods.append(rec)
		return
	hooks_raw.append_array(gh)
	var folder := hook_folder if not hook_folder.is_empty() else MODS_DIR
	for fname in hook_files:
		var loaded := _load_hook_file(folder, fname)
		if str(loaded.get("error", "")) != "":
			rec["error"] = str(loaded.get("error", ""))
			_mods.append(rec)
			return
		hooks_raw.append(loaded.get("record", {}))
	var validated := _validate_hook_list(hooks_raw)
	if str(validated.get("error", "")) != "":
		rec["error"] = str(validated.get("error", ""))
		_mods.append(rec)
		return
	rec["hooks"] = validated.get("hooks", [])
	_stamp_hook_mod_ids(rec["hooks"], str(rec.get("id", "")))
	rec["block_info"] = info
	_mods.append(rec)


## First forbidden snippet found in the script source, or "".
static func _scan_forbidden(text: String) -> String:
	for bad in FORBIDDEN_SNIPPETS:
		if text.contains(bad):
			return bad
	return ""


## True when the script's extends line is exactly "extends ModBlock".
## (A script with no extends line defaults to RefCounted — rejected.)
static func _extends_mod_block(text: String) -> bool:
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("extends "):
			return line == "extends ModBlock"
		if line.begins_with("extends\t"):
			return line == "extends\tModBlock"
	return false


static func _block_id_taken(block_id: String, exclude_mod_id: String) -> bool:
	for rec in _mods:
		if str(rec.get("id", "")) == exclude_mod_id:
			continue
		var info: Dictionary = rec.get("block_info", {})
		if str(info.get("block_id", "")) == block_id and block_id != "":
			return true
	return false


# --- Persistence ------------------------------------------------------------

static func _load_enabled_state() -> Dictionary:
	if not FileAccess.file_exists(STATE_PATH):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
	if not (data is Dictionary):
		return {}
	var out: Dictionary = {}
	for k in (data as Dictionary).keys():
		if (data as Dictionary)[k] is bool:
			out[str(k)] = bool((data as Dictionary)[k])
	return out


static func _persist_enabled() -> void:
	var file := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("ModLoader: could not write %s" % STATE_PATH)
		return
	file.store_string(JSON.stringify(_enabled))
	file.close()


# --- Helpers ----------------------------------------------------------------

static func _parse_json_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return null
	return JSON.parse_string(text)


static func _is_block_id(s: String) -> bool:
	if s.length() > 48:
		return false
	for ch in s:
		if not ("abcdefghijklmnopqrstuvwxyz0123456789_".contains(ch)):
			return false
	return true


static func _is_num_in(v: Variant, lo: float, hi: float) -> bool:
	return (v is int or v is float) and float(v) >= lo and float(v) <= hi


## Accepts int, or a float with an integral value (Godot's JSON parser
## returns ALL numbers as float, so a JSON block's 4 arrives as 4.0).
static func _is_int_in(v: Variant, lo: int, hi: int) -> bool:
	if v is int:
		return int(v) >= lo and int(v) <= hi
	if v is float and float(v) == floor(float(v)):
		return int(v) >= lo and int(v) <= hi
	return false


static func _is_size_voxels(v: Variant) -> bool:
	if not (v is Array) or (v as Array).size() != 3:
		return false
	for item in (v as Array):
		if not _is_int_in(item, 1, 12):
			return false
	return true


# --- Generated mods (v0.8 chunk 2, Worker A) ---------------------------------
# ADDITIVE ONLY: this wrapper validates a GENERATED mod (manifest +
# payload) WITHOUT touching the filesystem or the scan state. "" = OK,
# else an error string. Used by ModCreator for pre-install validation;
# the scan-time validators above remain the authority once installed.
# Never repairs: anything outside the manifest/block schema or the
# forbidden-API scan is a rejection. For script mods, the get_block_info()
# result itself is verified at install time (ModCreator writes, rescans,
# and rolls the install back when the installed record has an error).

static func validate_generated_mod(manifest: Dictionary, payload: String) -> String:
	for k in manifest.keys():
		if str(k) not in ["name", "kind", "version", "description", "author", "file", "hooks"]:
			return "unknown manifest field '%s'" % str(k)
	var mname: Variant = manifest.get("name", null)
	if not (mname is String) or str(mname).strip_edges().is_empty():
		return "manifest 'name' must be a non-empty string"
	var kind: Variant = manifest.get("kind", null)
	if not (kind is String) or str(kind) not in ["block", "script"]:
		return "manifest 'kind' must be 'block' or 'script'"
	if manifest.has("version") and not (manifest["version"] is String):
		return "manifest 'version' must be a string"
	if manifest.has("description"):
		if not (manifest["description"] is String):
			return "manifest 'description' must be a string"
		if str(manifest["description"]).length() > 300:
			return "manifest 'description' must be at most 300 chars"
	if manifest.has("author") and not (manifest["author"] is String):
		return "manifest 'author' must be a string"
	if manifest.has("file") and not (manifest["file"] is String):
		return "manifest 'file' must be a string"
	# v0.5.3: manifest-level data hooks (folder mods) validate here too.
	if manifest.has("hooks"):
		if not (manifest["hooks"] is Array):
			return "manifest 'hooks' must be an array"
		var merr := _validate_hook_list(manifest["hooks"] as Array)
		if str(merr.get("error", "")) != "":
			return str(merr.get("error", ""))
	if payload.strip_edges().is_empty():
		return "mod payload is empty"
	if str(kind) == "block":
		var data: Variant = JSON.parse_string(payload)
		if not (data is Dictionary):
			return "block payload is not a JSON object"
		var split := _split_block_and_hooks(data as Dictionary)
		if str(split.get("error", "")) != "":
			return str(split.get("error", ""))
		var block: Variant = split.get("block", null)
		if not (block is Dictionary):
			return "block payload is not a JSON object"
		var berr := _validate_block(block as Dictionary)
		if berr != "":
			return berr
		# v0.5.3 INVENTED HOOKS: payload "hooks" validate here; a bad
		# hook rejects the generation (install-time rescan re-checks).
		var herr := _validate_hook_list(split.get("hooks", []))
		if str(herr.get("error", "")) != "":
			return str(herr.get("error", ""))
		return ""
	# Script: same gates as scan-time, minus the load (the script is not
	# on disk yet — install() re-verifies via rescan after writing).
	# Hook code embedded in the script's get_hooks() data is covered by
	# the whole-payload forbidden scan below (forbidden substrings in a
	# hook's "code" string trip it exactly like top-level code).
	var forbidden := _scan_forbidden(payload)
	if forbidden != "":
		return "forbidden API in script: %s" % forbidden
	if not _extends_mod_block(payload):
		return "script must 'extend ModBlock'"
	if not payload.contains("func get_block_info"):
		return "script must implement get_block_info()"
	if not payload.contains("func apply"):
		return "script must implement apply()"
	return ""
