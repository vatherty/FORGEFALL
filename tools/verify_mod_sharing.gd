# tools/verify_mod_sharing.gd — WORKER C verification for FORGEFALL v0.5.10
# (mod SHARING for Create-a-Mod: Workers A + B).
# Usage: godot --headless --path <project> --script res://tools/verify_mod_sharing.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Contract under test (per the v0.5.10 brief + Worker B's menu contract):
#   export_mod(block_id) -> {ok, code, error} producing ONE self-contained
#       code (versioned prefix + compressed base64url, e.g. MOD1-...)
#       holding the full mod payload (JSON + hook scripts + voxel asset).
#   import_code(code) -> {ok, candidate, conflict, existing_id,
#       existing, error} running full validation (schema + forbidden-API
#       scan + hook-script allowlist) and flagging duplicate block_ids.
#   Import NEVER installs without approval: install happens only through
#       the import-approval Install path (fresh = ModCreator.install,
#       Replace = ModCreator.install_update, Keep Both = rename to
#       "<id>_copy" + install). Exported package contains NO key/secret.
#
# ADAPTIVE DISCOVERY: Workers A + B land in parallel with this suite, so
# the suite does NOT assume a file or method name for the PIPELINE. It
# probes in the menu's resolution order: mod_share.gd,
# mod_import_export.gd, mod_sharing.gd, mod_code.gd, mod_export.gd, then
# ModCreator (instance), then ModLoader. If NO sharing API exists, every
# sharing check FAILs with "sharing API not landed" (a clear signal, not
# a crash) — the suite never passes vacuously. Return shapes are
# normalized: a bare String export is a code; a bare candidate-shaped
# Dictionary import is a candidate.
#
# INSTALL PATHS: the suite prefers the REAL UI import flow (ImportInput
# -> IMPORT -> import-approval -> REPLACE/KEEP BOTH toggle -> INSTALL)
# and falls back to the pipeline + ModCreator calls when the menu script
# cannot load (said plainly per check). The Keep Both fallback mirrors
# the menu's rename scheme ("<id>_copy", " (copy)" display name).
#
# Isolation: user://mods/ + user://mods_enabled.json +
# user://forge_config.json are backed up to
# user://_v0510_verify_backup_* at start, wiped for the run, and
# restored in _cleanup() on EVERY exit path. No network, no real key,
# no live LLM anywhere on these paths (the secret-leak check uses a
# DUMMY key value written to a backed-up forge_config.json).
#
# Coverage:
#  (1) Round-trip x3 (table-effects mod, hook-script mod, custom-voxel-
#      asset mod): export -> import into a CLEAN mod state -> imported
#      candidate EQUALS the original exactly (payload fields, hook
#      script source-identical, voxel asset identical) -> import
#      approval Install -> installed record EQUALS the original.
#  (2) Tampered code rejected with a visible reason: flipped middle
#      character, truncated, bad prefix, bad base64 (pipeline level +
#      one UI-level case).
#  (3) Import of an existing block_id offers Replace AND Keep Both;
#      Replace bumps version + swaps content; Keep Both installs a
#      renamed copy that loads cleanly; the original is untouched.
#  (4) Import NEVER installs without approval (import alone writes no
#      mod file; install happens only through the approval Install path).
#  (5) Exported package contains NO key/secret (dummy DeepSeek key /
#      forge_config contents must not appear in the code).
#  (6) Edge cases: importing a code for a DISABLED mod (conflict, no
#      silent overwrite; Keep Both works, original stays disabled);
#      re-importing after the original was removed (no conflict).
#  (7) UI: the Import/Export tab renders the REAL tab (not the
#      placeholder), the export picker lists mods, EXPORT produces the
#      same code as the pipeline, the code field is readable (no
#      1-char-wide vertical-text layout bug), and the import flow
#      reaches approval (summary + payload + hook script + conflict
#      diff + Discard).
extends SceneTree

const DUMMY_KEY := "DUMMY_DEEPSEEK_KEY_7f3a9c2e_verify_only"
const VOXEL_DESC := "a glowing emerald crystal tower with amber trim"

var _fails := 0
var _passes := 0
var _frames := 0
var _ran_all := false
var _rect_pending := false
var _tab_switch_frame := -1
var _pending_rect_field: TextEdit = null
var _started := false
var _setup_frame := -1
var _cleaned_up := false

var _creator_script: GDScript = null
var _loader_script: GDScript = null
var _hook_script: GDScript = null
var _asset_script: GDScript = null
var _creator: Node = null
var _menu: Control = null
var _menu_script_ok := false

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _config_abs := ""
var _config_backup_abs := ""
var _had_mods := false
var _had_enabled := false
var _had_config := false

# --- Sharing-API discovery --------------------------------------------------
var _share_script: GDScript = null
var _share_host := ""  # "script" | "creator" | "loader" | ""
var _export_fn := ""
var _import_fn := ""
var _decode_fn := ""

# Same resolution order as ModCreatorMenu._share_target().
const _SHARE_PATHS := [
	"res://scripts/mods/mod_share.gd",
	"res://scripts/mods/mod_import_export.gd",
	"res://scripts/mods/mod_sharing.gd",
	"res://scripts/mods/mod_code.gd",
	"res://scripts/mods/mod_export.gd",
]
const _EXPORT_NAMES := ["export_mod", "export_code", "encode_mod", "share_export",
	"export_share_code", "make_share_code", "create_share_code"]
const _IMPORT_NAMES := ["import_code", "import_mod", "decode_mod", "decode_mod_code",
	"parse_share_code", "import_share_code", "decode_share_code"]
const _DECODE_NAMES := ["decode_mod", "decode_mod_code", "decode_share_code",
	"parse_share_code", "unpack_mod", "unpack_share_code"]


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


## A check that could not run (blocked by a missing/unusable dependency,
## e.g. the menu script failing to parse). Not a pass, not a fail —
## the blocker itself is a FAIL elsewhere, and the gap is reported.
func _skip(label: String, reason: String) -> void:
	print("SKIP: ", label, " (", reason, ")")


# --- Backup / restore -------------------------------------------------------

func _copy_file(src: String, dst: String) -> void:
	var text := FileAccess.get_file_as_string(src)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _copy_recursive(src: String, dst: String) -> void:
	var dir := DirAccess.open(src)
	if dir == null:
		return
	DirAccess.make_dir_recursive_absolute(dst)
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var s := src.path_join(entry)
		var d := dst.path_join(entry)
		if dir.current_is_dir():
			_copy_recursive(s, d)
		else:
			_copy_file(s, d)
		entry = dir.get_next()
	dir.list_dir_end()


func _wipe_contents(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_wipe_contents(full)
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _list_recursive(abs: String, rel: String, out: Array) -> void:
	var dir := DirAccess.open(abs)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			# The voxel-asset cache (user://mods/assets/) is NOT a mod.
			if entry == "assets" and dir.current_is_dir() and rel.is_empty():
				entry = dir.get_next()
				continue
			var r := entry if rel.is_empty() else rel + "/" + entry
			if dir.current_is_dir():
				_list_recursive(abs.path_join(entry), r, out)
			else:
				out.append(r)
		entry = dir.get_next()
	dir.list_dir_end()


func _list_mods_tree() -> Array:
	var out: Array = []
	_list_recursive(_mods_abs, "", out)
	out.sort()
	return out


func _backup_and_stage() -> void:
	_user_dir = OS.get_user_data_dir()
	_mods_abs = _user_dir.path_join("mods")
	_backup_abs = _user_dir.path_join("_v0510_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v0510_verify_backup_enabled.json")
	_config_abs = _user_dir.path_join("forge_config.json")
	_config_backup_abs = _user_dir.path_join("_v0510_verify_backup_forge_config.json")
	_wipe_contents(_backup_abs)
	DirAccess.remove_absolute(_backup_abs)
	if FileAccess.file_exists(_enabled_backup_abs):
		DirAccess.remove_absolute(_enabled_backup_abs)
	if FileAccess.file_exists(_config_backup_abs):
		DirAccess.remove_absolute(_config_backup_abs)
	_had_mods = DirAccess.dir_exists_absolute(_mods_abs)
	if _had_mods:
		_copy_recursive(_mods_abs, _backup_abs)
	_had_enabled = FileAccess.file_exists(_enabled_abs)
	if _had_enabled:
		_copy_file(_enabled_abs, _enabled_backup_abs)
	_had_config = FileAccess.file_exists(_config_abs)
	if _had_config:
		_copy_file(_config_abs, _config_backup_abs)
	DirAccess.make_dir_recursive_absolute(_mods_abs)
	_wipe_contents(_mods_abs)
	if FileAccess.file_exists(_enabled_abs):
		DirAccess.remove_absolute(_enabled_abs)
	if FileAccess.file_exists(_config_abs):
		DirAccess.remove_absolute(_config_abs)


func _cleanup() -> void:
	if _cleaned_up:
		return
	_cleaned_up = true
	_wipe_contents(_mods_abs)
	if _had_mods:
		_copy_recursive(_backup_abs, _mods_abs)
		_wipe_contents(_backup_abs)
		DirAccess.remove_absolute(_backup_abs)
	elif DirAccess.dir_exists_absolute(_mods_abs):
		DirAccess.remove_absolute(_mods_abs)
	if _had_enabled:
		_copy_file(_enabled_backup_abs, _enabled_abs)
		if FileAccess.file_exists(_enabled_backup_abs):
			DirAccess.remove_absolute(_enabled_backup_abs)
	elif FileAccess.file_exists(_enabled_abs):
		DirAccess.remove_absolute(_enabled_abs)
	if _had_config:
		_copy_file(_config_backup_abs, _config_abs)
		if FileAccess.file_exists(_config_backup_abs):
			DirAccess.remove_absolute(_config_backup_abs)
	elif FileAccess.file_exists(_config_abs):
		DirAccess.remove_absolute(_config_abs)
	if _loader_script != null:
		_loader_script.call("rescan")


# --- Discovery --------------------------------------------------------------

func _method_names(script: GDScript) -> Array:
	var out: Array = []
	if script == null:
		return out
	for m in script.get_script_method_list():
		if m is Dictionary:
			out.append(str((m as Dictionary).get("name", "")))
	return out


func _method_argc(script: GDScript, method_name: String) -> int:
	if script == null:
		return -1
	for m in script.get_script_method_list():
		if m is Dictionary and str((m as Dictionary).get("name", "")) == method_name:
			var args: Variant = (m as Dictionary).get("args", [])
			if args is Array:
				return (args as Array).size()
	return -1


func _discover_sharing() -> void:
	# 1) Dedicated sharing script, if one landed.
	for path in _SHARE_PATHS:
		if ResourceLoader.exists(path):
			var scr := load(path) as GDScript
			if scr != null:
				_share_script = scr
				break
	if _share_script != null:
		var names := _method_names(_share_script)
		for n in _EXPORT_NAMES:
			if n in names:
				_export_fn = n
				_share_host = "script"
				break
		for n in _IMPORT_NAMES:
			if n in names:
				_import_fn = n
				_share_host = "script"
				break
		for n in _DECODE_NAMES:
			if n in names:
				_decode_fn = n
				break
	# 2) ModCreator (instance methods + statics).
	if _export_fn.is_empty() or _import_fn.is_empty():
		var cnames := _method_names(_creator_script)
		if _creator != null:
			for n in _EXPORT_NAMES:
				if _export_fn.is_empty() and (_creator.has_method(n) or n in cnames):
					_export_fn = n
					_share_host = "creator"
			for n in _IMPORT_NAMES:
				if _import_fn.is_empty() and (_creator.has_method(n) or n in cnames):
					_import_fn = n
					_share_host = "creator"
			for n in _DECODE_NAMES:
				if _decode_fn.is_empty() and (_creator.has_method(n) or n in cnames):
					_decode_fn = n
	# 3) ModLoader (statics).
	if _export_fn.is_empty() or _import_fn.is_empty():
		var lnames := _method_names(_loader_script)
		for n in _EXPORT_NAMES:
			if _export_fn.is_empty() and n in lnames:
				_export_fn = n
				_share_host = "loader"
		for n in _IMPORT_NAMES:
			if _import_fn.is_empty() and n in lnames:
				_import_fn = n
				_share_host = "loader"
		for n in _DECODE_NAMES:
			if _decode_fn.is_empty() and n in lnames:
				_decode_fn = n


func _sharing_available() -> bool:
	return not _export_fn.is_empty() and not _import_fn.is_empty()


## Calls a discovered method on its host with `args` (falling back to
## fewer args when the method declares none). Returns null on no host.
func _call_discovered(host: String, script: GDScript, instance: Node,
		method_name: String, args: Array) -> Variant:
	if method_name.is_empty():
		return null
	var argc := -1
	if host == "script" or host == "loader":
		argc = _method_argc(script, method_name)
	elif host == "creator" and instance != null:
		argc = _method_argc(_creator_script, method_name)
		if argc < 0:
			argc = args.size()
	var call_args: Array = args
	if argc >= 0 and argc < args.size():
		call_args = args.slice(0, argc)
	if host == "script" or host == "loader":
		return script.callv(method_name, call_args)
	if host == "creator" and instance != null:
		return instance.callv(method_name, call_args)
	return null


# --- Normalized export / import ---------------------------------------------

func _norm_export(res: Variant) -> Dictionary:
	# {ok, code, error}
	if res is String:
		var s := str(res)
		if s.is_empty():
			return {"ok": false, "code": "", "error": "export returned an empty string"}
		return {"ok": true, "code": s, "error": ""}
	if res is Dictionary:
		var d := res as Dictionary
		var err := str(d.get("error", d.get("reason", "")))
		if d.has("ok") and not bool(d.get("ok", false)):
			return {"ok": false, "code": "", "error": err if not err.is_empty() else "export returned ok=false"}
		var code := str(d.get("code", d.get("share_code", d.get("data", ""))))
		if code.is_empty():
			return {"ok": false, "code": "", "error": "export returned no code (error='%s')" % err}
		return {"ok": true, "code": code, "error": ""}
	return {"ok": false, "code": "", "error": "export returned unexpected type %s" % typeof(res)}


func _export_mod(mod_id: String) -> Dictionary:
	var host_script: GDScript = _loader_script
	if _share_host == "script":
		host_script = _share_script
	elif _share_host == "creator":
		host_script = _creator_script
	var res: Variant = _call_discovered(_share_host, host_script, _creator, _export_fn, [mod_id])
	return _norm_export(res)


func _looks_like_candidate(d: Dictionary) -> bool:
	return d.has("mod_id") and d.has("payload") and d.has("manifest")


func _norm_import(res: Variant) -> Dictionary:
	# {ok, error, kind, candidate, candidate_keep_both, conflict,
	#  existing_id, existing, options, resolutions, identical, asset_count}
	# Pipeline shape (ModShare.import_code): kind "candidate"|"conflict"|
	# "error" + candidate + candidate_keep_both + existing + resolutions.
	# Legacy shape (menu contract): conflict bool + existing_id.
	# NOTE: an EMPTY "existing" {} does NOT mean conflict — the pipeline
	# returns existing={} for a clean candidate too.
	var out := {"ok": false, "error": "", "kind": "", "candidate": {},
		"candidate_keep_both": {}, "conflict": false, "existing_id": "",
		"existing": {}, "options": [], "resolutions": [], "identical": false,
		"asset_count": -1}
	if res is String:
		var s := str(res)
		if s.is_empty():
			out["error"] = "import returned an empty string"
		else:
			# A bare string return is treated as an error message (the
			# import APIs return candidate-shaped Dictionaries on success).
			out["error"] = s
		return out
	if not (res is Dictionary):
		out["error"] = "import returned unexpected type %s" % typeof(res)
		return out
	var d := res as Dictionary
	if _looks_like_candidate(d):
		out["ok"] = true
		out["candidate"] = d
		out["kind"] = "candidate"
		if str(d.get("error", "")) != "":
			out["ok"] = false
			out["error"] = str(d.get("error", ""))
		return out
	var err := str(d.get("error", d.get("reason", "")))
	out["error"] = err
	var kind := str(d.get("kind", ""))
	out["kind"] = kind
	if kind == "error":
		out["ok"] = false
	elif kind == "conflict":
		out["ok"] = true
		out["conflict"] = true
	elif kind == "candidate":
		out["ok"] = true
	elif d.has("ok"):
		out["ok"] = bool(d.get("ok", false))
	elif err.is_empty() and (d.has("candidate") or d.has("conflict") or d.has("status")):
		out["ok"] = true
	var cand: Variant = d.get("candidate", d.get("mod", {}))
	if cand is Dictionary:
		out["candidate"] = cand as Dictionary
		if str((cand as Dictionary).get("error", "")) != "" and out["ok"] and not bool(out["conflict"]):
			out["ok"] = false
			out["error"] = str((cand as Dictionary).get("error", ""))
	var kb: Variant = d.get("candidate_keep_both", {})
	if kb is Dictionary:
		out["candidate_keep_both"] = kb as Dictionary
	var existing: Variant = d.get("existing", {})
	if existing is Dictionary:
		out["existing"] = existing as Dictionary
		if not (existing as Dictionary).is_empty():
			out["conflict"] = true
	if d.has("conflict") and bool(d.get("conflict", false)):
		out["conflict"] = true
	if str(d.get("status", "")) == "conflict":
		out["conflict"] = true
	out["existing_id"] = str(d.get("existing_id", d.get("existing_mod_id", "")))
	if out["existing_id"].is_empty() and out["existing"] is Dictionary:
		out["existing_id"] = str((out["existing"] as Dictionary).get("mod_id", ""))
	var resols: Variant = d.get("resolutions", [])
	if resols is Array:
		out["resolutions"] = resols as Array
		# Resolutions double as the options list (action labels).
		var opts: Array = []
		for r in (resols as Array):
			if r is Dictionary:
				opts.append(str((r as Dictionary).get("action", "")))
		out["options"] = opts
	else:
		var opts2: Variant = d.get("options", d.get("choices", d.get("actions", [])))
		if opts2 is Array:
			out["options"] = opts2 as Array
	out["identical"] = bool(d.get("identical", false))
	if d.has("asset_count"):
		out["asset_count"] = int(d.get("asset_count", -1))
	if not out["ok"] and err.is_empty() and not bool(out["conflict"]):
		out["error"] = "import failed with no reason"
	return out


func _import_code(code: String) -> Dictionary:
	var host_script: GDScript = _loader_script
	if _share_host == "script":
		host_script = _share_script
	elif _share_host == "creator":
		host_script = _creator_script
	var res: Variant = _call_discovered(_share_host, host_script, _creator, _import_fn, [code])
	return _norm_import(res)


## Best-effort decode of a share code (import is the authority; decode
## only feeds extra package-content checks when the API exposes it).
func _decode_code(code: String) -> Dictionary:
	if _decode_fn.is_empty() or _decode_fn == _import_fn:
		return {}
	var host_script: GDScript = _loader_script
	if _share_host == "script":
		host_script = _share_script
	elif _share_host == "creator":
		host_script = _creator_script
	var res: Variant = _call_discovered(_share_host, host_script, _creator, _decode_fn, [code])
	if res is Dictionary:
		return res as Dictionary
	return {}


# --- Fixtures -----------------------------------------------------------------

func _vortex_code() -> String:
	return (
		"extends ModHook\n" +
		"func run(api: ModAPI, ctx: Dictionary) -> Dictionary:\n" +
		"\tvar tgt = ctx.get(\"target\", null)\n" +
		"\tif not (tgt is Node3D):\n" +
		"\t\treturn {}\n" +
		"\tvar hit = ctx.get(\"hit_position\", api.get_player_position())\n" +
		"\tvar player_pos = api.get_player_position()\n" +
		"\tvar away = hit - player_pos\n" +
		"\tif away.length_squared() < 0.001:\n" +
		"\t\treturn {}\n" +
		"\tvar origin = hit + away\n" +
		"\tvar pulled = api.apply_status_effect(tgt, \"knockback\", {\"force\": 8.0}, origin)\n" +
		"\treturn {\"status_applied\": pulled}\n")


func _candidate(mod_id: String, display: String, block: Dictionary, hooks: Array) -> Dictionary:
	var payload := JSON.stringify({"block": block, "hooks": hooks})
	return {"mod_id": mod_id, "name": display, "kind": "block",
		"manifest": {"name": display, "kind": "block", "version": "1.0", "author": "verify"},
		"payload": payload, "summary": display + " (verify fixture).", "error": ""}


func _table_candidate(mod_id: String = "verify_share_table", cost: int = 200, desc: String = "A weapon that slows hit enemies.") -> Dictionary:
	var block := {"block_id": mod_id, "target": "weapon", "cost": cost,
		"display_name": "Verify Share Table", "description": desc, "base_weapon_id": "p9"}
	var hooks := [{"hook_id": "verify_share_slow", "hook_point": "on_hit",
		"display_name": "Verify Share Slow", "description": "Slows the hit target.",
		"effects": [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0}]}]
	return _candidate(mod_id, "Verify Share Table", block, hooks)


func _hook_candidate(mod_id: String = "verify_share_hook") -> Dictionary:
	var block := {"block_id": mod_id, "target": "weapon", "cost": 250,
		"display_name": "Verify Share Hook", "description": "A weapon that drags hit enemies toward you.",
		"base_weapon_id": "p9"}
	var hooks := [{"hook_id": "verify_share_vortex", "hook_point": "on_hit",
		"display_name": "Verify Share Vortex", "description": "Drags the hit target toward the player.",
		"code": _vortex_code()}]
	return _candidate(mod_id, "Verify Share Hook", block, hooks)


func _script_candidate(mod_id: String = "verify_share_script") -> Dictionary:
	# Minimal script mod: the block_id appears as a QUOTED literal in
	# get_block_info(), which is what the pipeline's Keep Both rewrite
	# needs (unquoted/substring occurrences are never rewritten).
	var script := (
		"extends ModBlock\n" +
		"func get_block_info() -> Dictionary:\n" +
		"\treturn {\"block_id\": \"" + mod_id + "\", \"target\": \"cover\", \"cost\": 100, \"display_name\": \"Verify Share Script\", \"description\": \"Script-mod fixture.\", \"shape\": \"wall\", \"size_voxels\": [2, 2, 1], \"hp\": 100.0}\n" +
		"func apply(api: ModAPI, params: Dictionary) -> String:\n" +
		"\treturn \"built\"\n")
	return {"mod_id": mod_id, "name": "Verify Share Script", "kind": "script",
		"manifest": {"name": "Verify Share Script", "kind": "script", "version": "1.0", "author": "verify"},
		"payload": script, "summary": "Verify Share Script (verify fixture).", "error": ""}


func _voxel_candidate(mod_id: String = "verify_share_voxel") -> Dictionary:
	var block := {"block_id": mod_id, "target": "cover", "cost": 150,
		"display_name": "Verify Share Voxel", "description": VOXEL_DESC,
		"shape": "tower", "size_voxels": [2, 3, 2], "hp": 200.0, "property": "standard"}
	return _candidate(mod_id, "Verify Share Voxel", block, [])


func _deep_equal(a: Variant, b: Variant) -> bool:
	if a is Dictionary and b is Dictionary:
		var da := a as Dictionary
		var db := b as Dictionary
		if da.size() != db.size():
			return false
		for k in da.keys():
			if not db.has(k) or not _deep_equal(da[k], db[k]):
				return false
		return true
	if a is Array and b is Array:
		var aa := a as Array
		var ab := b as Array
		if aa.size() != ab.size():
			return false
		for i in range(aa.size()):
			if not _deep_equal(aa[i], ab[i]):
				return false
		return true
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return a == b


func _parsed_payload(candidate: Dictionary) -> Variant:
	return JSON.parse_string(str(candidate.get("payload", "")))


## Candidate-level equality: same mod identity + same manifest + same
## payload JSON (block fields, hooks, hook-script source byte-identical).
## Payload equality ignoring ONLY the block payload's block_id (Keep
## Both renames it by design — the copy's block_id becomes the copy id).
func _payloads_equal_ignoring_block_id(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary and b is Dictionary):
		return _deep_equal(a, b)
	var da: Dictionary = (a as Dictionary).duplicate(true)
	var db: Dictionary = (b as Dictionary).duplicate(true)
	for d in [da, db]:
		if d.has("block") and (d["block"] is Dictionary):
			(d["block"] as Dictionary)["block_id"] = "IGNORED"
		elif d.has("block_id"):
			d["block_id"] = "IGNORED"
	return _deep_equal(da, db)


func _candidates_equal(a: Dictionary, b: Dictionary) -> bool:
	if str(a.get("mod_id", "")) != str(b.get("mod_id", "")):
		return false
	if str(a.get("name", "")) != str(b.get("name", "")):
		return false
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return false
	# Script payloads are GDScript source, not JSON: compare the
	# source strings exactly (a JSON parse would be null == null,
	# a vacuous pass).
	if str(a.get("kind", "")) == "script":
		return str(a.get("payload", "")) == str(b.get("payload", ""))
	var ma: Variant = a.get("manifest", {})
	var mb: Variant = b.get("manifest", {})
	if ma is Dictionary and mb is Dictionary:
		for k in ["name", "kind", "version"]:
			if str((ma as Dictionary).get(k, "")) != str((mb as Dictionary).get(k, "")):
				return false
	var pa: Variant = _parsed_payload(a)
	var pb: Variant = _parsed_payload(b)
	return _deep_equal(pa, pb)


func _install_fixture(candidate: Dictionary) -> bool:
	var err: String = _creator.call("install", candidate)
	_check(err == "", "fixture: install('%s') succeeds ('%s')" % [str(candidate.get("mod_id", "")), err])
	if err != "":
		return false
	_loader_script.call("rescan")
	var rec: Dictionary = _loader_script.call("find_mod", str(candidate.get("mod_id", "")), false)
	_check(not (rec as Dictionary).is_empty() and str((rec as Dictionary).get("error", "")) == "",
		"fixture: installed record for '%s' is error-free" % str(candidate.get("mod_id", "")))
	return not (rec as Dictionary).is_empty()


func _wipe_clean() -> void:
	_wipe_contents(_mods_abs)
	DirAccess.make_dir_recursive_absolute(_mods_abs)
	_loader_script.call("rescan")
	_check(_loader_script.call("get_mods").is_empty(),
		"clean state: no mods registered after wipe")


func _asset_voxels_for(desc: String) -> Array:
	var asset: Dictionary = _asset_script.call("get_or_generate", desc)
	return asset.get("voxels", []) as Array


# --- Menu helpers ---------------------------------------------------------------

func _menu_usable() -> bool:
	return _menu != null and _menu_script_ok


func _menu_node(name: String) -> Node:
	if _menu == null:
		return null
	return _menu.find_child(name, true, false)


func _menu_control(name: String) -> Control:
	var n := _menu_node(name)
	if n is Control:
		return n as Control
	return null


func _menu_label_text(name: String) -> String:
	var n := _menu_node(name)
	if n is Label:
		return (n as Label).text
	return ""


func _menu_textedit_text(name: String) -> String:
	var n := _menu_node(name)
	if n is TextEdit:
		return (n as TextEdit).text
	return ""


## Drives the menu's real import flow (ImportInput -> IMPORT) and
## returns whether the import-approval panel is showing.
func _drive_menu_import(code: String) -> bool:
	if not _menu_usable():
		return false
	var input := _menu_node("ImportInput")
	if input is TextEdit:
		(input as TextEdit).text = code
	else:
		return false
	_menu.call("_on_import_pressed")
	var panel := _menu_control("ImportApprovalPanel")
	return panel != null and panel.visible


## Collision-free copy id, mirroring the menu's scheme:
## "<base>_copy", then "<base>_copy_2", ...
func _unique_copy_id(base: String) -> String:
	var first := base + "_copy"
	if (_loader_script.call("find_mod", first, false) as Dictionary).is_empty():
		return first
	for n in range(2, 100):
		var cand := "%s_copy_%d" % [base, n]
		if (_loader_script.call("find_mod", cand, false) as Dictionary).is_empty():
			return cand
	return first


## Pipeline install (no menu): re-import (pure) + install_import_result
## when the pipeline exposes it, else install_imported, else the
## ModCreator calls with the menu's rename scheme. "" = installed.
## mode: "fresh" | "replace" | "keepboth".
func _install_imported_pipeline(code: String, mode: String) -> String:
	var imp := _import_code(code)
	if not bool(imp.get("ok", false)):
		return "import failed: '%s'" % str(imp.get("error", ""))
	var resolution := "" if mode == "fresh" else ("replace" if mode == "replace" else "keep_both")
	var host_script: GDScript = _loader_script
	if _share_host == "script":
		host_script = _share_script
	elif _share_host == "creator":
		host_script = _creator_script
	# 1) install_import_result(result, resolution) — authoritative:
	# picks the right candidate per resolution.
	if host_script != null and "install_import_result" in _method_names(host_script):
		var res: Variant = _call_discovered(_share_host, host_script, _creator,
			"install_import_result", [imp, resolution])
		if res is Dictionary:
			if bool((res as Dictionary).get("ok", false)):
				return ""
			return str((res as Dictionary).get("error", "install_import_result failed"))
		return "install_import_result returned unexpected type"
	# 2) install_imported(candidate, resolution, existing_mod_id).
	if host_script != null and "install_imported" in _method_names(host_script):
		var cand2: Variant = imp.get("candidate_keep_both", {}) if resolution == "keep_both" else imp.get("candidate", {})
		if not (cand2 is Dictionary) or (cand2 as Dictionary).is_empty():
			return "import returned no candidate for resolution '%s'" % resolution
		var existing_id := str(imp.get("existing_id", ""))
		var res2: Variant = _call_discovered(_share_host, host_script, _creator,
			"install_imported", [cand2, resolution, existing_id])
		if res2 is Dictionary:
			if bool((res2 as Dictionary).get("ok", false)):
				return ""
			return str((res2 as Dictionary).get("error", "install_imported failed"))
		return "install_imported returned unexpected type"
	# 3) ModCreator fallback (same semantics: fresh = install,
	# replace = install_update, keepboth = "<id>_copy" rename + install).
	var cand: Dictionary = imp.get("candidate", {})
	if (cand as Dictionary).is_empty():
		return "import returned no candidate"
	if mode == "fresh":
		return _creator.call("install", cand)
	if mode == "replace":
		var existing := str(imp.get("existing_id", ""))
		if existing.is_empty():
			existing = str(cand.get("mod_id", ""))
		return _creator.call("install_update", cand, existing)
	var renamed: Dictionary = cand.duplicate(true)
	renamed["mod_id"] = _unique_copy_id(str(cand.get("mod_id", "mod")))
	var nm := str(renamed.get("name", ""))
	if not nm.ends_with(" (copy)"):
		nm += " (copy)"
		renamed["name"] = nm
		var m: Dictionary = (renamed.get("manifest", {}) as Dictionary).duplicate(true)
		m["name"] = nm
		renamed["manifest"] = m
	return _creator.call("install", renamed)


## Installs an imported code through the REAL import-approval path.
## mode: "fresh" | "replace" | "keepboth". "" = installed, else error.
## Menu path when the menu script loads; otherwise the pipeline
## install (_install_imported_pipeline).
func _install_imported(code: String, mode: String) -> String:
	if _menu_usable():
		if not _drive_menu_import(code):
			var status := _menu_label_text("ImportStatus")
			return "import approval did not appear (status='%s')" % status
		if mode != "fresh":
			var toggle_name := "ImportReplaceButton" if mode == "replace" else "ImportKeepBothButton"
			var toggle := _menu_node(toggle_name)
			if toggle is Button:
				(toggle as Button).button_pressed = true
			else:
				return "conflict toggle '%s' missing" % toggle_name
			var install_btn := _menu_node("ImportApprovalInstallButton")
			if install_btn is Button and (install_btn as Button).disabled:
				return "Install still disabled after choosing %s" % mode
		_menu.call("_on_import_install_pressed")
		var panel := _menu_control("ImportApprovalPanel")
		if panel != null and panel.visible:
			return "approval still showing after Install: '%s'" % _menu_label_text("ImportApprovalStatus")
		var done := _menu_label_text("ImportStatus")
		if done.contains("Installed") or done.contains("Replaced"):
			return ""
		return "unexpected import status after Install: '%s'" % done
	# Fallback: the pipeline's own install (menu script did not load).
	return _install_imported_pipeline(code, mode)


# --- Setup ---------------------------------------------------------------------

func _setup() -> void:
	_backup_and_stage()
	_creator_script = load("res://scripts/mods/mod_creator.gd")
	_loader_script = load("res://scripts/mods/mod_loader.gd")
	_hook_script = load("res://scripts/mods/mod_hook.gd")
	_asset_script = load("res://scripts/mods/voxel_asset_generator.gd")
	_check(_creator_script != null, "setup: mod_creator.gd loads")
	_check(_loader_script != null, "setup: mod_loader.gd loads")
	_check(_asset_script != null, "setup: voxel_asset_generator.gd loads")
	_creator = _creator_script.new()
	root.add_child(_creator)
	_loader_script.call("rescan")
	_discover_sharing()
	if _share_script != null:
		print("SHARING: dedicated script found; export='", _export_fn, "' import='", _import_fn, "' host='", _share_host, "'")
	else:
		print("SHARING: no dedicated sharing script; export='", _export_fn, "' import='", _import_fn, "' host='", _share_host, "'")
	var scene := load("res://scenes/ui/mod_creator_menu.tscn") as PackedScene
	_menu = null
	if scene != null:
		_menu = scene.instantiate() as Control
	_menu_script_ok = _menu != null and _menu.get_script() != null
	_check(_menu_script_ok, "setup: ModCreatorMenu script parses + loads (menu usable)")
	if _menu != null:
		root.add_child(_menu)
		root.size = Vector2(1280, 720)
		_menu.size = Vector2(1280, 720)
	_setup_frame = _frames


# --- Main test body --------------------------------------------------------------

func _run_all() -> void:
	# --- (0) API presence (fail-clear, never vacuous) ----------------------
	_check(not _export_fn.is_empty(), "sharing API: an export function exists (export_mod / export_code / encode_mod / ...)")
	_check(not _import_fn.is_empty(), "sharing API: an import function exists (import_code / import_mod / decode_mod / ...)")
	if not _sharing_available():
		_check(false, "sharing API: NOT LANDED — Workers A/B pipeline (export_mod/import_code) is absent; all sharing checks below cannot run")
		_check(false, "round-trip: table-effects mod (blocked — no sharing API)")
		_check(false, "round-trip: hook-script mod (blocked — no sharing API)")
		_check(false, "round-trip: voxel-asset mod (blocked — no sharing API)")
		_check(false, "round-trip: script mod (blocked — no sharing API)")
		_check(false, "tamper: flipped character rejected (blocked — no sharing API)")
		_check(false, "tamper: truncated code rejected (blocked — no sharing API)")
		_check(false, "tamper: bad prefix rejected (blocked — no sharing API)")
		_check(false, "tamper: bad base64 rejected (blocked — no sharing API)")
		_check(false, "conflict: Replace AND Keep Both offered (blocked — no sharing API)")
		_check(false, "conflict: Replace bumps version + swaps content (blocked — no sharing API)")
		_check(false, "conflict: Keep Both installs a renamed copy that loads cleanly (blocked — no sharing API)")
		_check(false, "script-keepboth: pipeline Keep Both rewrites a script mod's block_id (blocked — no sharing API)")
		_check(false, "import installs nothing without approval (blocked — no sharing API)")
		_check(false, "secret: exported package contains no key/secret (blocked — no sharing API)")
		_check(false, "edge: import for a disabled mod offers conflict, no silent overwrite (blocked — no sharing API)")
		_check(false, "edge: re-import after removal has no conflict (blocked — no sharing API)")
		_run_ui_checks("")
		return

	# --- (1) Round-trips ------------------------------------------------------
	_run_round_trip(_table_candidate(), "table-effects")
	_run_round_trip(_hook_candidate(), "hook-script")
	_run_round_trip(_voxel_candidate(), "voxel-asset")
	_run_round_trip(_script_candidate(), "script-mod")

	# --- (2) Tamper ------------------------------------------------------------
	_run_tamper()

	# --- (3) Conflict: Replace + Keep Both --------------------------------------
	_run_conflict()
	_run_script_keepboth()

	# --- (5) Secret leak ---------------------------------------------------------
	_run_secret()

	# --- (6) Edge cases -----------------------------------------------------------
	_run_edge_disabled()
	_run_edge_reimport_after_removal()

	# --- (7) UI --------------------------------------------------------------------
	# Export a fresh code for the UI import-flow check.
	var ui_cand := _table_candidate("verify_share_ui", 210, "UI import-flow fixture.")
	if _install_fixture(ui_cand):
		var exp := _export_mod("verify_share_ui")
		if bool(exp.get("ok", false)):
			_run_ui_checks(str(exp.get("code", "")))
		else:
			_check(false, "ui: export for the UI import-flow check succeeds ('%s')" % str(exp.get("error", "")))
			_run_ui_checks("")
		_wipe_clean()
	else:
		_run_ui_checks("")


func _run_round_trip(original: Dictionary, label: String) -> void:
	var mod_id := str(original.get("mod_id", ""))
	_wipe_clean()
	if not _install_fixture(original):
		_check(false, "round-trip (%s): fixture installs, so export can run" % label)
		return
	var exp := _export_mod(mod_id)
	_check(bool(exp.get("ok", false)), "round-trip (%s): export_mod('%s') succeeds ('%s')" % [label, mod_id, str(exp.get("error", ""))])
	if not bool(exp.get("ok", false)):
		return
	var code := str(exp.get("code", ""))
	_check(not code.is_empty(), "round-trip (%s): exported code is non-empty" % label)
	_check(code.begins_with("MOD1-") or code.contains("-"),
		"round-trip (%s): exported code carries a versioned prefix (got '%s...')" % [label, code.left(12)])
	# Voxel fixture: capture the ORIGINAL asset voxels before the wipe.
	var orig_voxels: Array = []
	if label == "voxel-asset":
		orig_voxels = _asset_voxels_for(VOXEL_DESC)
		_check(not orig_voxels.is_empty(), "round-trip (voxel-asset): original voxel asset has voxels")
	# Import into a CLEAN mod state. The snapshot is taken AFTER the
	# wipe (the clean-state tree), so "import writes nothing" compares
	# against the empty tree, not the pre-wipe fixture files.
	_wipe_clean()
	var snap := _list_mods_tree()
	var imp := _import_code(code)
	_check(bool(imp.get("ok", false)), "round-trip (%s): import_code succeeds in clean state ('%s')" % [label, str(imp.get("error", ""))])
	if int(imp.get("asset_count", -1)) >= 0 and label == "voxel-asset":
		_check(int(imp.get("asset_count", 0)) >= 1,
			"round-trip (voxel-asset): import reports embedded assets (asset_count=%s)" % str(imp.get("asset_count", "?")))
	_check(not bool(imp.get("conflict", false)), "round-trip (%s): import into clean state reports NO conflict" % label)
	var cand: Dictionary = imp.get("candidate", {})
	_check(not (cand as Dictionary).is_empty(), "round-trip (%s): import returns a candidate" % label)
	if (cand as Dictionary).is_empty():
		return
	# (4) Import alone installs NOTHING.
	_check(_list_mods_tree() == snap, "round-trip (%s): import alone writes NO mod file (tree unchanged)" % label)
	_check((_loader_script.call("find_mod", mod_id, false) as Dictionary).is_empty(),
		"round-trip (%s): import alone registers NO mod" % label)
	# Candidate EQUALS the original exactly.
	_check(_candidates_equal(cand, original),
		"round-trip (%s): imported candidate EQUALS the original (mod_id, manifest, payload incl. hook source)" % label)
	if label == "hook-script":
		var op: Variant = _parsed_payload(original)
		var cp: Variant = _parsed_payload(cand)
		var ocode := ""
		var ccode := ""
		if op is Dictionary and (op as Dictionary).has("hooks"):
			var oh: Array = (op as Dictionary)["hooks"]
			if not oh.is_empty():
				ocode = str((oh[0] as Dictionary).get("code", ""))
		if cp is Dictionary and (cp as Dictionary).has("hooks"):
			var ch: Array = (cp as Dictionary)["hooks"]
			if not ch.is_empty():
				ccode = str((ch[0] as Dictionary).get("code", ""))
		_check(not ocode.is_empty() and ocode == ccode,
			"round-trip (hook-script): hook script source is byte-identical after round-trip")
	if label == "voxel-asset":
		# (a) Embedded asset data in the decoded package / candidate, when exposed.
		var embedded: Array = []
		var decoded := _decode_code(code)
		for key in ["asset", "voxel_asset", "voxels"]:
			if decoded.has(key):
				var v: Variant = decoded[key]
				if v is Dictionary and (v as Dictionary).has("voxels"):
					embedded = (v as Dictionary)["voxels"]
				elif v is Array:
					embedded = v
		if embedded.is_empty() and cand.has("asset"):
			var av: Variant = cand.get("asset", {})
			if av is Dictionary and (av as Dictionary).has("voxels"):
				embedded = (av as Dictionary)["voxels"]
		if not embedded.is_empty():
			_check(_deep_equal(embedded, orig_voxels),
				"round-trip (voxel-asset): embedded voxel asset is identical to the original")
		else:
			print("SHARING: voxel asset not exposed in decoded package/candidate — checking re-derived asset instead")
		# (b) The imported mod's description re-derives the identical asset
		# (the generator is deterministic, so a description-carried asset
		# round-trips exactly even when the package stores the description).
		var cparsed: Variant = _parsed_payload(cand)
		var cdesc := ""
		if cparsed is Dictionary and (cparsed as Dictionary).has("block"):
			cdesc = str(((cparsed as Dictionary)["block"] as Dictionary).get("description", ""))
		_check(cdesc == VOXEL_DESC, "round-trip (voxel-asset): imported description preserved ('%s')" % cdesc)
		var rederived := _asset_voxels_for(cdesc)
		_check(not rederived.is_empty() and _deep_equal(rederived, orig_voxels),
			"round-trip (voxel-asset): voxel asset identical after round-trip (%d voxels)" % rederived.size())
	# Import-approval Install path -> installed record EQUALS the original.
	var install_err := _install_imported(code, "fresh")
	_check(install_err == "", "round-trip (%s): import-approval Install installs the imported candidate ('%s')" % [label, install_err])
	if install_err == "":
		var loaded: Dictionary = _creator_script.call("load_installed", mod_id)
		_check(str(loaded.get("error", "")) == "", "round-trip (%s): installed mod loads ('%s')" % [label, str(loaded.get("error", ""))])
		if str(original.get("kind", "")) == "script":
			_check(str(loaded.get("payload", "")) == str(original.get("payload", "")),
				"round-trip (%s): installed script payload EQUALS the original script" % label)
		else:
			var lp: Variant = JSON.parse_string(str(loaded.get("payload", "")))
			var op2: Variant = _parsed_payload(original)
			_check(_deep_equal(lp, op2), "round-trip (%s): installed payload EQUALS the original payload" % label)
		var rec: Dictionary = _loader_script.call("find_mod", mod_id, false)
		_check(str((rec as Dictionary).get("error", "")) == "",
			"round-trip (%s): installed record is error-free" % label)
	_wipe_clean()


func _run_tamper() -> void:
	var original := _table_candidate("verify_share_tamper", 200, "Tamper fixture.")
	_wipe_clean()
	if not _install_fixture(original):
		_check(false, "tamper: fixture installs, so export can run")
		return
	var exp := _export_mod("verify_share_tamper")
	if not bool(exp.get("ok", false)):
		_check(false, "tamper: export succeeds ('%s')" % str(exp.get("error", "")))
		return
	var code := str(exp.get("code", ""))
	_wipe_clean()
	# Flipped middle character.
	var mid := code.length() / 2
	var mid_ch := code.substr(mid, 1)
	var repl := "A" if mid_ch != "A" else "B"
	var flipped := code.substr(0, mid) + repl + code.substr(mid + 1)
	var r1 := _import_code(flipped)
	_check(not bool(r1.get("ok", false)) and str(r1.get("error", "")) != "",
		"tamper: flipped middle character REJECTED with a visible reason ('%s')" % str(r1.get("error", "")))
	_check(_list_mods_tree().is_empty(), "tamper: flipped code installs nothing")
	# Truncated.
	var trunc := code.left(code.length() / 2)
	var r2 := _import_code(trunc)
	_check(not bool(r2.get("ok", false)) and str(r2.get("error", "")) != "",
		"tamper: truncated code REJECTED with a visible reason ('%s')" % str(r2.get("error", "")))
	_check(_list_mods_tree().is_empty(), "tamper: truncated code installs nothing")
	# Bad prefix.
	var bad_prefix := ""
	if code.begins_with("MOD1-"):
		bad_prefix = "XXXX-" + code.substr(5)
	else:
		bad_prefix = "BAD!" + code
	var r3 := _import_code(bad_prefix)
	_check(not bool(r3.get("ok", false)) and str(r3.get("error", "")) != "",
		"tamper: bad prefix REJECTED with a visible reason ('%s')" % str(r3.get("error", "")))
	_check(_list_mods_tree().is_empty(), "tamper: bad-prefix code installs nothing")
	# Bad base64 (illegal character in the payload body).
	var bad_b64 := code.substr(0, mid) + "!" + code.substr(mid + 1)
	var r4 := _import_code(bad_b64)
	_check(not bool(r4.get("ok", false)) and str(r4.get("error", "")) != "",
		"tamper: bad base64 REJECTED with a visible reason ('%s')" % str(r4.get("error", "")))
	_check(_list_mods_tree().is_empty(), "tamper: bad-base64 code installs nothing")
	# UI level: a tampered code pasted into the menu is rejected and
	# the import approval never appears.
	if _menu_usable():
		var shown := _drive_menu_import(flipped)
		_check(not shown, "tamper (UI): flipped code pasted into the menu does NOT reach approval")
		_check(_menu_label_text("ImportStatus").to_lower().contains("reject"),
			"tamper (UI): menu shows the rejection reason ('%s')" % _menu_label_text("ImportStatus"))
		_check(_list_mods_tree().is_empty(), "tamper (UI): flipped code pasted into the menu installs nothing")
	else:
		_skip("tamper (UI): flipped code pasted into the menu does NOT reach approval",
			"menu script did not load")
	_wipe_clean()


func _conflict_offers_both_via_ui() -> bool:
	# The import approval shows the conflict row with BOTH toggles.
	var row := _menu_control("ImportConflictRow")
	var rep := _menu_node("ImportReplaceButton")
	var kb := _menu_node("ImportKeepBothButton")
	return row != null and row.visible and rep is Button and kb is Button


func _run_conflict() -> void:
	var mod_id := "verify_share_conflict"
	var v1 := _table_candidate(mod_id, 200, "Conflict v1.")
	var v2 := _table_candidate(mod_id, 300, "Conflict v2.")
	_wipe_clean()
	if not _install_fixture(v1):
		_check(false, "conflict: v1 installs")
		return
	var exp := _export_mod(mod_id)
	if not bool(exp.get("ok", false)):
		_check(false, "conflict: export of v1 succeeds ('%s')" % str(exp.get("error", "")))
		return
	var code := str(exp.get("code", ""))
	# Make the installed copy DIFFER (v2) so Replace must swap content.
	var up_err: String = _creator.call("install_update", v2, mod_id)
	_check(up_err == "", "conflict: setup — v2 installed as an update ('%s')" % up_err)
	_loader_script.call("rescan")
	var before_rec: Dictionary = _loader_script.call("find_mod", mod_id, false)
	var before_version := str((before_rec as Dictionary).get("version", ""))
	var loaded_v2: Dictionary = _creator_script.call("load_installed", mod_id)
	var before_payload: Variant = JSON.parse_string(str(loaded_v2.get("payload", "")))
	# Import v1 code while v2 is installed -> conflict.
	var imp := _import_code(code)
	_check(bool(imp.get("ok", false)) or bool(imp.get("conflict", false)),
		"conflict: import of an existing block_id does not hard-error ('%s')" % str(imp.get("error", "")))
	_check(bool(imp.get("conflict", false)), "conflict: import of an existing block_id reports a conflict")
	var cand: Dictionary = imp.get("candidate", {})
	if (cand as Dictionary).is_empty():
		_check(false, "conflict: import returns a candidate to resolve")
		return
	# Import alone must NOT have overwritten v2.
	var still_v2: Dictionary = _creator_script.call("load_installed", mod_id)
	_check(_deep_equal(JSON.parse_string(str(still_v2.get("payload", ""))), before_payload),
		"conflict: import alone does NOT overwrite the installed mod")
	# Offers Replace AND Keep Both — pipeline level: the import
	# resolutions. Keep Both counts only when it carries a renamed
	# candidate (the pipeline lists it as unavailable with an empty
	# mod_id when it cannot offer one).
	var resols: Array = imp.get("resolutions", [])
	var pipe_replace := false
	var pipe_keep := false
	for r in resols:
		if r is Dictionary:
			if str((r as Dictionary).get("action", "")) == "replace":
				pipe_replace = true
			if str((r as Dictionary).get("action", "")) == "keep_both" and str((r as Dictionary).get("mod_id", "")) != "":
				pipe_keep = true
	if resols.is_empty():
		# Legacy pipeline without resolutions: fall back to options.
		for o in imp.get("options", []):
			var s := str(o).to_lower()
			if s.contains("replace"):
				pipe_replace = true
			if s.contains("keep") or s.contains("both") or s.contains("duplicate") or s.contains("copy"):
				pipe_keep = true
	_check(pipe_replace and pipe_keep,
		"conflict: import resolutions offer Replace AND Keep Both (resolutions=%s)" % str(resols))
	# UI level: the import approval shows both toggles.
	if _menu_usable():
		var ui_offers := _drive_menu_import(code) and _conflict_offers_both_via_ui()
		_check(ui_offers, "conflict: import approval offers Replace AND Keep Both toggles")
		# Leave the approval up: _install_imported re-drives import.
	else:
		_skip("conflict: import approval offers Replace AND Keep Both toggles",
			"menu script did not load")
	# --- Replace: bumps version + swaps content -------------------------
	var rep_err := _install_imported(code, "replace")
	_check(rep_err == "", "conflict: Replace resolves ('%s')" % rep_err)
	_loader_script.call("rescan")
	var after_rec: Dictionary = _loader_script.call("find_mod", mod_id, false)
	var after_version := str((after_rec as Dictionary).get("version", ""))
	var expected_version: String = str(_creator_script.call("bump_version", before_version))
	_check(after_version == expected_version,
		"conflict: Replace bumps version %s -> %s (expected %s)" % [before_version, after_version, expected_version])
	_check(str((after_rec as Dictionary).get("error", "")) == "",
		"conflict: Replace leaves an error-free record")
	var loaded_v1: Dictionary = _creator_script.call("load_installed", mod_id)
	_check(_deep_equal(JSON.parse_string(str(loaded_v1.get("payload", ""))), _parsed_payload(v1)),
		"conflict: Replace swaps content back to the imported v1 payload")
	# --- Keep Both: renamed copy that loads cleanly -----------------------
	var imp2 := _import_code(code)
	_check(bool(imp2.get("conflict", false)), "conflict: second import still reports a conflict (v1 installed)")
	var ids_before: Array = []
	for m in _loader_script.call("get_mods"):
		ids_before.append(str((m as Dictionary).get("id", "")))
	var kb_err := _install_imported(code, "keepboth")
	_check(kb_err == "", "conflict: Keep Both resolves ('%s')" % kb_err)
	_loader_script.call("rescan")
	var ids_after: Array = []
	for m in _loader_script.call("get_mods"):
		ids_after.append(str((m as Dictionary).get("id", "")))
	var new_ids: Array = []
	for id in ids_after:
		if id not in ids_before:
			new_ids.append(id)
	_check(new_ids.size() == 1, "conflict: Keep Both installs exactly ONE renamed copy (new ids=%s)" % str(new_ids))
	if new_ids.size() == 1:
		var copy_id := str(new_ids[0])
		_check(copy_id != mod_id, "conflict: Keep Both copy has a RENAMED id ('%s')" % copy_id)
		_check(copy_id == mod_id + "_2" or copy_id == mod_id + "_copy" or copy_id.begins_with(mod_id + "_"),
			"conflict: Keep Both copy uses a rename scheme ('%s' — pipeline '<id>_2' or menu '<id>_copy')" % copy_id)
		var copy_rec: Dictionary = _loader_script.call("find_mod", copy_id, false)
		_check(not (copy_rec as Dictionary).is_empty() and str((copy_rec as Dictionary).get("error", "")) == "",
			"conflict: Keep Both copy loads cleanly (error-free)")
		var copy_loaded: Dictionary = _creator_script.call("load_installed", copy_id)
		var copy_payload: Variant = JSON.parse_string(str(copy_loaded.get("payload", "")))
		_check(_payloads_equal_ignoring_block_id(copy_payload, _parsed_payload(v1)),
			"conflict: Keep Both copy carries the imported v1 content (modulo its renamed block_id)")
		var copy_block_id := ""
		if copy_payload is Dictionary and (copy_payload as Dictionary).has("block"):
			copy_block_id = str(((copy_payload as Dictionary)["block"] as Dictionary).get("block_id", ""))
		_check(copy_block_id == copy_id,
			"conflict: Keep Both copy's block_id == its copy id ('%s')" % copy_block_id)
	# Original untouched by Keep Both.
	var orig_after: Dictionary = _creator_script.call("load_installed", mod_id)
	_check(_deep_equal(JSON.parse_string(str(orig_after.get("payload", ""))), _parsed_payload(v1)),
		"conflict: original still holds the v1 content after Keep Both")
	_wipe_clean()


func _run_script_keepboth() -> void:
	# Script-mod Keep Both: the pipeline rewrites the script's QUOTED
	# block_id literal to <id>_2 and verifies the rewritten script
	# reports the new id. This leg uses the PIPELINE install path
	# deliberately: the menu's Keep Both only renames the folder id,
	# which cannot rewrite a script literal (flagged to the
	# coordinator — the menu path for script Keep Both is NOT covered
	# here).
	var mod_id := "verify_share_script_kb"
	var original := _script_candidate(mod_id)
	_wipe_clean()
	if not _install_fixture(original):
		_check(false, "script-keepboth: fixture installs")
		return
	var exp := _export_mod(mod_id)
	if not bool(exp.get("ok", false)):
		_check(false, "script-keepboth: export succeeds ('%s')" % str(exp.get("error", "")))
		return
	var code := str(exp.get("code", ""))
	var imp := _import_code(code)
	_check(bool(imp.get("conflict", false)), "script-keepboth: import reports a conflict")
	var kb: Dictionary = imp.get("candidate_keep_both", {})
	_check(not (kb as Dictionary).is_empty(), "script-keepboth: import provides a Keep Both candidate")
	if (kb as Dictionary).is_empty():
		return
	_check(str((kb as Dictionary).get("block_id", "")) == mod_id + "_2",
		"script-keepboth: Keep Both candidate block_id is '%s_2' (got '%s')" % [mod_id, str((kb as Dictionary).get("block_id", ""))])
	_check(str((kb as Dictionary).get("payload", "")).contains("\"" + mod_id + "_2\""),
		"script-keepboth: Keep Both script rewrites the quoted block_id literal")
	var install_err := _install_imported_pipeline(code, "keepboth")
	_check(install_err == "", "script-keepboth: pipeline Keep Both installs ('%s')" % install_err)
	_loader_script.call("rescan")
	var copy_rec: Dictionary = _loader_script.call("find_mod", mod_id + "_2", false)
	_check(not (copy_rec as Dictionary).is_empty() and str((copy_rec as Dictionary).get("error", "")) == "",
		"script-keepboth: renamed script copy loads cleanly (error-free)")
	if not (copy_rec as Dictionary).is_empty():
		var copy_info: Dictionary = (copy_rec as Dictionary).get("block_info", {})
		_check(str(copy_info.get("block_id", "")) == mod_id + "_2",
			"script-keepboth: copy's installed block_id is the renamed id")
	var orig_rec: Dictionary = _loader_script.call("find_mod", mod_id, false)
	_check(not (orig_rec as Dictionary).is_empty(),
		"script-keepboth: original still installed after Keep Both")
	_wipe_clean()


func _run_secret() -> void:
	# Dummy key material in a backed-up forge_config.json (restored by
	# _cleanup; the DUMMY value is the only key material ever asserted).
	var cfg := FileAccess.open(_config_abs, FileAccess.WRITE)
	if cfg != null:
		cfg.store_string(JSON.stringify({"deepseek_api_key": DUMMY_KEY, "model": "deepseek-flash"}))
		cfg.close()
	var original := _table_candidate("verify_share_secret", 200, "Secret-leak fixture.")
	_wipe_clean()
	# Re-write the dummy config: the wipe only clears mods/.
	cfg = FileAccess.open(_config_abs, FileAccess.WRITE)
	if cfg != null:
		cfg.store_string(JSON.stringify({"deepseek_api_key": DUMMY_KEY, "model": "deepseek-flash"}))
		cfg.close()
	if not _install_fixture(original):
		_check(false, "secret: fixture installs")
		return
	var exp := _export_mod("verify_share_secret")
	_check(bool(exp.get("ok", false)), "secret: export succeeds ('%s')" % str(exp.get("error", "")))
	if bool(exp.get("ok", false)):
		var code := str(exp.get("code", ""))
		_check(not code.contains(DUMMY_KEY), "secret: exported code does NOT contain the dummy DeepSeek key")
		_check(not code.contains("DUMMY_DEEPSEEK"), "secret: exported code does NOT contain dummy key material")
		_check(not code.contains("forge_config"), "secret: exported code does NOT contain forge_config contents")
		_check(not code.contains("deepseek_api_key"), "secret: exported code does NOT name the key field")
	if FileAccess.file_exists(_config_abs):
		DirAccess.remove_absolute(_config_abs)
	_wipe_clean()


func _run_edge_disabled() -> void:
	var mod_id := "verify_share_disabled"
	var original := _table_candidate(mod_id, 200, "Disabled-mod fixture.")
	_wipe_clean()
	if not _install_fixture(original):
		_check(false, "edge/disabled: fixture installs")
		return
	var exp := _export_mod(mod_id)
	if not bool(exp.get("ok", false)):
		_check(false, "edge/disabled: export succeeds ('%s')" % str(exp.get("error", "")))
		return
	var code := str(exp.get("code", ""))
	_loader_script.call("set_mod_enabled", mod_id, false)
	_loader_script.call("rescan")
	var dis_rec: Dictionary = _loader_script.call("find_mod", mod_id, false)
	_check(not bool((dis_rec as Dictionary).get("enabled", true)),
		"edge/disabled: setup — mod is disabled before import")
	# Import a code for a DISABLED mod: conflict, no silent overwrite.
	var imp := _import_code(code)
	_check(bool(imp.get("conflict", false)), "edge/disabled: import for a disabled mod reports a conflict (no silent overwrite)")
	var cand: Dictionary = imp.get("candidate", {})
	if (cand as Dictionary).is_empty():
		_check(false, "edge/disabled: import returns a candidate")
		return
	var dis_after: Dictionary = _loader_script.call("find_mod", mod_id, false)
	_check(not bool((dis_after as Dictionary).get("enabled", true)),
		"edge/disabled: import alone does NOT re-enable the disabled mod")
	# Keep Both: the copy installs + loads cleanly; the original stays disabled.
	var ids_before: Array = []
	for m in _loader_script.call("get_mods"):
		ids_before.append(str((m as Dictionary).get("id", "")))
	var kb_err := _install_imported(code, "keepboth")
	_check(kb_err == "", "edge/disabled: Keep Both resolves ('%s')" % kb_err)
	_loader_script.call("rescan")
	var ids_after: Array = []
	for m in _loader_script.call("get_mods"):
		ids_after.append(str((m as Dictionary).get("id", "")))
	var new_ids: Array = []
	for id in ids_after:
		if id not in ids_before:
			new_ids.append(id)
	_check(new_ids.size() == 1, "edge/disabled: Keep Both installs exactly one copy (new ids=%s)" % str(new_ids))
	if new_ids.size() == 1:
		var copy_rec: Dictionary = _loader_script.call("find_mod", str(new_ids[0]), false)
		_check(not (copy_rec as Dictionary).is_empty() and str((copy_rec as Dictionary).get("error", "")) == "",
			"edge/disabled: Keep Both copy loads cleanly")
		var copy_loaded: Dictionary = _creator_script.call("load_installed", str(new_ids[0]))
		_check(_payloads_equal_ignoring_block_id(JSON.parse_string(str(copy_loaded.get("payload", ""))), _parsed_payload(original)),
			"edge/disabled: Keep Both copy carries the imported content (modulo its renamed block_id)")
	var orig_after: Dictionary = _loader_script.call("find_mod", mod_id, false)
	_check(not bool((orig_after as Dictionary).get("enabled", true)),
		"edge/disabled: original stays DISABLED after Keep Both")
	_wipe_clean()


func _run_edge_reimport_after_removal() -> void:
	var mod_id := "verify_share_removed"
	var original := _table_candidate(mod_id, 200, "Removed-then-reimported fixture.")
	_wipe_clean()
	if not _install_fixture(original):
		_check(false, "edge/removed: fixture installs")
		return
	var exp := _export_mod(mod_id)
	if not bool(exp.get("ok", false)):
		_check(false, "edge/removed: export succeeds ('%s')" % str(exp.get("error", "")))
		return
	var code := str(exp.get("code", ""))
	# Remove the original entirely.
	_wipe_clean()
	var imp := _import_code(code)
	_check(bool(imp.get("ok", false)), "edge/removed: re-import after removal succeeds ('%s')" % str(imp.get("error", "")))
	_check(not bool(imp.get("conflict", false)), "edge/removed: re-import after removal reports NO conflict")
	var cand: Dictionary = imp.get("candidate", {})
	_check(not (cand as Dictionary).is_empty() and _candidates_equal(cand, original),
		"edge/removed: re-imported candidate EQUALS the removed original")
	if not (cand as Dictionary).is_empty():
		var install_err := _install_imported(code, "fresh")
		_check(install_err == "", "edge/removed: re-imported candidate installs through approval ('%s')" % install_err)
	_wipe_clean()


func _run_ui_checks(code: String) -> void:
	if not _menu_usable():
		# The menu-script parse failure is already a FAIL in _setup;
		# the dependent UI checks are SKIPs, not 12 more FAILs.
		_skip("ui: CreatorTabs TabContainer exists", "menu script did not load")
		_skip("ui: an IMPORT/EXPORT tab exists", "menu script did not load")
		_skip("ui: Import/Export tab is the REAL tab, not the placeholder", "menu script did not load")
		_skip("ui: export picker lists mods", "menu script did not load")
		_skip("ui: EXPORT produces the pipeline's code", "menu script did not load")
		_skip("ui: code field readable, no 1-char-wide layout bug", "menu script did not load")
		_skip("ui: IMPORT button exists and is enabled", "menu script did not load")
		_skip("ui: EXPORT button exists and is enabled", "menu script did not load")
		_skip("ui: import flow reaches approval", "menu script did not load")
		_skip("ui: import approval shows summary + payload + hooks", "menu script did not load")
		_skip("ui: Discard drops the import with nothing installed", "menu script did not load")
		return
	_check(true, "ui: ModCreatorMenu script parses + loads (menu usable)")
	var tabs: TabContainer = _menu.find_child("CreatorTabs", true, false) as TabContainer
	_check(tabs != null, "ui: CreatorTabs TabContainer exists")
	var import_tab := -1
	if tabs != null:
		for i in range(tabs.get_tab_count()):
			if str(tabs.get_tab_title(i)).to_lower().contains("import"):
				import_tab = i
	_check(import_tab >= 0, "ui: an IMPORT/EXPORT tab exists")
	# Placeholder vs real tab: the real tab has no ImportExportNote.
	var note := _menu_node("ImportExportNote")
	var is_placeholder := note != null and str((note as Label).text).to_lower().contains("coming in a later update")
	_check(not is_placeholder, "ui: Import/Export tab is the REAL tab, not the 'coming in a later update' placeholder")
	if is_placeholder:
		_check(false, "ui: export picker lists mods (blocked — placeholder tab)")
		_check(false, "ui: EXPORT produces the pipeline's code (blocked — placeholder tab)")
		_check(false, "ui: code field readable (blocked — placeholder tab)")
		_check(false, "ui: import flow reaches approval (blocked — placeholder tab)")
		return
	if tabs != null and import_tab >= 0:
		tabs.current_tab = import_tab
		_tab_switch_frame = _frames
	# Export picker lists mods.
	_menu.call("_refresh_export_picker")
	var picker := _menu_node("ExportPicker")
	_check(picker is OptionButton, "ui: export picker exists (ExportPicker OptionButton)")
	var picker_items: Array = []
	if picker is OptionButton:
		var ob := picker as OptionButton
		for i in range(ob.get_item_count()):
			picker_items.append(ob.get_item_text(i))
	var lists_ui_mod := false
	var ui_idx := -1
	for i in range(picker_items.size()):
		if str(picker_items[i]).contains("verify_share_ui"):
			lists_ui_mod = true
			ui_idx = i
	_check(not picker_items.is_empty(), "ui: export picker is non-empty (items=%s)" % str(picker_items))
	_check(lists_ui_mod, "ui: export picker lists installed mods (items=%s)" % str(picker_items))
	# EXPORT through the menu produces the SAME code as the pipeline.
	if code.is_empty():
		_check(false, "ui: EXPORT produces the pipeline's code (blocked — no share code)")
	else:
		if picker is OptionButton and ui_idx >= 0:
			(picker as OptionButton).select(ui_idx)
			_menu.call("_on_export_pressed")
			var menu_code := _menu_textedit_text("ExportCode")
			_check(menu_code == code,
				"ui: EXPORT produces the pipeline's code (menu code == direct export)")
			_check(_menu_label_text("ExportStatus").to_lower().contains("ready"),
				"ui: EXPORT status confirms the code is ready ('%s')" % _menu_label_text("ExportStatus"))
		else:
			_check(false, "ui: EXPORT produces the pipeline's code (blocked — picker has no UI mod)")
	# Code field readable — no 1-char-wide vertical-text layout bug.
	var code_field := _menu_control("ExportCode")
	_check(code_field is TextEdit, "ui: share-code field exists (ExportCode TextEdit)")
	if code_field is TextEdit:
		var te := code_field as TextEdit
		var structural_ok := bool(te.size_flags_horizontal & Control.SIZE_EXPAND_FILL) and te.wrap_mode != TextEdit.LINE_WRAPPING_NONE and te.custom_minimum_size.y >= 100.0
		_check(structural_ok,
			"ui: code field structural width OK (EXPAND_FILL + wrapping + min-height >= 100 — the 1-char-wide bug is a missing EXPAND_FILL)")
		# Rect read must wait for layout after the tab switch; _process runs
		# it two frames later via _check_rect(). Reading it here (same frame
		# as the switch) returns the pre-layout 8px rect.
		_rect_pending = true
		_pending_rect_field = te
	# Buttons enabled.
	var import_btn := _menu_node("ImportButton")
	var export_btn := _menu_node("ExportButton")
	_check(import_btn is Button and not (import_btn as Button).disabled, "ui: IMPORT button exists and is enabled")
	_check(export_btn is Button and not (export_btn as Button).disabled, "ui: EXPORT button exists and is enabled")
	if code.is_empty():
		_check(false, "ui: import flow reaches approval (blocked — no share code)")
		return
	# Import flow reaches approval — with chat-style wrapped input
	# (spaces + newlines), which the menu must strip.
	var snap := _list_mods_tree()
	var wrapped := "  " + code.substr(0, code.length() / 2) + "\n" + code.substr(code.length() / 2) + "  \n"
	var shown := _drive_menu_import(wrapped)
	_check(shown, "ui: import flow reaches approval (whitespace-wrapped code accepted)")
	_check(_list_mods_tree() == snap, "ui: import approval shows WITHOUT installing (tree unchanged)")
	if shown:
		var summary := _menu_label_text("ImportApprovalSummary")
		_check(summary.contains("Verify Share Table") and summary.contains("verify_share_ui"),
			"ui: import approval shows summary with the mod name/id")
		var payload_text := _menu_textedit_text("ImportApprovalPayload")
		_check(not payload_text.is_empty() and payload_text.contains("verify_share_ui"),
			"ui: import approval shows the FULL payload")
		var hooks_text := _menu_label_text("ImportApprovalHooks")
		_check(hooks_text.contains("verify_share_slow"),
			"ui: import approval lists the mod's hooks ('%s')" % hooks_text.left(80))
		# Conflict (the UI mod IS installed): diff + both toggles +
		# Install dead until a choice is made.
		var diff := _menu_control("ImportApprovalDiff")
		_check(diff != null and diff.visible and _menu_label_text("ImportApprovalDiff").contains("CONFLICT"),
			"ui: import approval shows the CONFLICT diff for an installed mod")
		var row := _menu_control("ImportConflictRow")
		var rep := _menu_node("ImportReplaceButton")
		var kb := _menu_node("ImportKeepBothButton")
		_check(row != null and row.visible and rep is Button and kb is Button,
			"ui: conflict approval offers Replace AND Keep Both toggles")
		var install_btn := _menu_node("ImportApprovalInstallButton")
		_check(install_btn is Button and (install_btn as Button).disabled,
			"ui: Install is DISABLED until a conflict choice is made")
		# Keep Both through the UI: installs the _copy, original untouched.
		if kb is Button:
			(kb as Button).button_pressed = true
			_check(install_btn is Button and not (install_btn as Button).disabled,
				"ui: choosing KEEP BOTH enables Install")
			_menu.call("_on_import_install_pressed")
			var copy_rec: Dictionary = _loader_script.call("find_mod", "verify_share_ui_copy", false)
			_check(not (copy_rec as Dictionary).is_empty() and str((copy_rec as Dictionary).get("error", "")) == "",
				"ui: KEEP BOTH installs 'verify_share_ui_copy' (error-free)")
			var orig_rec: Dictionary = _loader_script.call("find_mod", "verify_share_ui", false)
			_check(not (orig_rec as Dictionary).is_empty(),
				"ui: original still installed after KEEP BOTH")
		else:
			_check(false, "ui: KEEP BOTH installs a copy (blocked — toggle missing)")
		# Discard drops the import with nothing installed.
		var snap2 := _list_mods_tree()
		var shown2 := _drive_menu_import(code)
		_check(shown2, "ui: Discard check — import reaches approval again")
		if shown2:
			_menu.call("_on_import_discard_pressed")
			var panel := _menu_control("ImportApprovalPanel")
			_check(panel == null or not panel.visible,
				"ui: Discard hides the import approval")
			_check(_list_mods_tree() == snap2,
				"ui: Discard drops the import with nothing installed")
			_check(_menu_label_text("ImportStatus").to_lower().contains("discard"),
				"ui: Discard confirms nothing was installed ('%s')" % _menu_label_text("ImportStatus"))


func _finish() -> void:
	_cleanup()
	print("MOD_SHARING VERIFY: %d checks, %d passes, %d failures" % [_passes + _fails, _passes, _fails])
	quit(1 if _fails > 0 else 0)


# Deferred rect check: runs two frames after the Import/Export tab switch,
# once layout has actually run. See the _rect_pending assignment in _run_all.
func _check_rect() -> void:
	var te := _pending_rect_field
	if te == null or not is_instance_valid(te):
		_check(false, "ui: code field readable (field gone before deferred rect check)")
		return
	var rect_w := te.get_global_rect().size.x
	if rect_w > 0.0:
		_check(rect_w >= 100.0,
			"ui: code field is readable — rendered width %.0fpx, not 1-char-wide" % rect_w)
	else:
		print("SHARING: code-field global rect is 0 headless — structural check above stands in")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	if not _started:
		_started = true
		_setup()
		return false
	# Let the menu lay out at the target viewport size for a few frames
	# before the layout-sensitive UI checks read real rects.
	if _setup_frame >= 0 and _frames - _setup_frame < 4:
		return false
	if not _ran_all:
		_run_all()
		_ran_all = true
	if _rect_pending:
		if _frames - _tab_switch_frame >= 2:
			_check_rect()
			_rect_pending = false
			_finish()
			return true
		return false
	_finish()
	return true
