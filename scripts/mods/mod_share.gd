# FORGEFALL — ModShare (v0.5.10: mod sharing, Worker A2)
# Export / import pipeline for Create-a-Mod share codes. All-static API;
# the Import/Export tab (scripts/ui/mod_creator_menu.gd, Worker B) calls
# these names — the menu owns NO encode/decode/validation of its own.
#
# CONTRACT (exactly what the menu + Worker C's suite call):
#   export_mod(ref) -> {ok, code, mod_id, block_id, name, kind, version,
#       code_chars, asset_count, error}. ref = a mod id OR a block_id.
#       Refuses broken mods. Export reads ONLY installed-mod fields —
#       never forge_config.json, any secret store, paths, or enabled
#       state — and asserts a structured-key denylist over Dictionary
#       KEYS (never string values) at export AND import.
#   import_code(code) -> {ok, kind: "candidate"|"conflict"|"error",
#       error, candidate, candidate_keep_both, existing, existing_id,
#       resolutions, conflict, hooks, hook_summary, hook_files,
#       summary, asset_count, identical}. NEVER writes anything
#       (no mod files, no asset cache, no rescan writes). Accepts a
#       MOD1- prefix or a bare body. candidate = the ModCreator
#       candidate shape (+ block_id, hook_files, assets, spell_school).
#       hooks = ModHook.preview_hooks_for_candidate output (+ the
#       hook-file records, which preview cannot see). hook_summary =
#       approval lines, one per hook file included. existing = the
#       conflicting installed mod (load_installed shape) or {}. The
#       resolutions list carries one entry per available resolution
#       ({action, mod_id}); keep_both is OMITTED when it cannot apply
#       (e.g. a script whose block_id is computed) and
#       keep_both_unavailable_reason explains why.
#   install_import_result(result, resolution) /
#   install_imported(candidate, resolution, existing_mod_id="") ->
#       {ok, mod_id, block_id, version, replaced, error}. The ONLY write
#       paths; the UI calls one of these on the Install tap.
#       install_import_result reads existing_id / existing from the
#       result it receives — the menu annotates a COPY of the result
#       with its resolved conflict context (including backstop-detected
#       folder collisions), so Replace targets THAT mod. Resolutions:
#       "" / "fresh" (fresh install), "replace", "keep_both"
#       ("keepboth" spelling also accepted).
#
# CODE FORMAT: `MOD1-` + base64url([4-byte big-endian uncompressed
# length] + DEFLATE(JSON envelope)), padding stripped. Envelope:
# {"format": 1, "mod": "<JSON string of package>", "sha256": "<sha256
# of that exact string>"}. Package fields ONLY: mod_id, name, kind,
# version, author, manifest (sanitized to the generation-manifest
# allowlist), payload (exact installed bytes), spell_school, hook_files
# (folder-manifest .gd sources), assets (embedded voxel arrays).
# Size caps: 1M code chars, 2MB uncompressed package, 20k total voxels
# / 5k per asset, 8 hook files, 20k chars per hook file.
#
# VALIDATION ON IMPORT (same as generation): ModCreator.validate() ->
# ModLoader.validate_generated_mod() (schema + forbidden-API scan) +
# ModHook allowlist + compile for hook code, PLUS hook-file validation
# (allowlist + compile + get_hook_info(), mirroring
# ModLoader._load_hook_file on in-memory source), hook-id uniqueness
# across MERGED hook sources (manifest + payload/get_hooks + hook
# files), asset shape + cache-key binding, and a script-compile check
# via in-memory get_block_info(). Tampered codes fail with a VISIBLE
# reason: bad prefix (incl. FORGE1- mis-paste), bad base64, bad
# checksum / decompression, checksum mismatch, schema failure,
# forbidden API + the violation.
#
# REPLACE / KEEP BOTH: import detects BOTH a block_id clash AND a
# folder-id clash with a different mod. Replace overwrites the
# existing mod's folder in place, version bump via
# ModCreator.bump_version (1.0 -> 1.1). Old files are snapshotted;
# rollback on verification failure. `identical` is set when the
# incoming mod is byte-identical to the installed one. Keep Both
# installs a renamed copy: BLOCK mods use the menu-compatible
# "<id>_copy", "<id>_copy_2", ... scheme (Worker C's UI suite asserts
# the _copy id for a block Keep Both through the menu); SCRIPT mods
# use "<id>_2", "<id>_3", ... (the same suite asserts the _2 id for a
# script Keep Both candidate + installed copy). Block mods: payload
# block_id rewritten on a block_id clash. Script mods: quoted block_id
# literals rewritten in script + hook-file sources, then VERIFIED by
# compiling the rewritten script in memory and reading
# get_block_info(). Folder-only conflicts keep block_id and rename
# only the folder. A script whose block_id is computed (e.g.
# "probe_" + "comp") gets NO Keep Both — the resolution explains why.
# Install always writes folder form, rescans, verifies the installed
# record is error-free with the expected block_id; failures roll back
# (folder removed / originals restored).
#
# VOXEL ASSETS (exact reproduction): export resolves each visual
# description the mod carries (manifest description, block
# description, every hook projectile visual) via VoxelAssetGenerator
# and embeds the voxel arrays; install writes them back to
# user://mods/assets/<key>.json (embedded bytes win).
extends RefCounted
class_name ModShare

const PREFIX := "MOD1-"
const FORMAT_VERSION := 1
const MAX_CODE_CHARS := 1000000
const MAX_PACKAGE_BYTES := 2000000
const MAX_ENVELOPE_BYTES := 4000000
const MAX_VOXELS_TOTAL := 20000
const MAX_VOXELS_PER_ASSET := 5000
const MAX_HOOK_FILES := 8
const MAX_HOOK_FILE_CHARS := 20000
const MAX_KEEP_BOTH_ATTEMPTS := 1000

const PACKAGE_KEYS := ["mod_id", "name", "kind", "version", "author",
	"manifest", "payload", "spell_school", "hook_files", "assets"]
const MANIFEST_KEYS := ["name", "kind", "version", "author", "description", "hooks"]

## Structured-key denylist (Dictionary KEYS only — never string
## values). A mod whose description literally contains "arcane token
## of deepseek api_key bearer" still exports fine: values are never
## scanned. Matching is bounded: a term matches a key only as the whole
## key or as a whole "_"-separated token ("author" does NOT match
## "auth"; "deepseek_api_key" matches "deepseek" and "api_key").
const KEY_DENYLIST := ["deepseek", "api_key", "apikey", "bearer", "token",
	"secret", "password", "passwd", "forge_config", "credential",
	"private_key", "auth", "session", "cookie"]

const B64URL_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"


# --- Public API ---------------------------------------------------------------

## Exports an installed mod (ref = mod id OR block_id) to one
## self-contained share code. Refuses broken mods. Reads ONLY
## installed-mod fields.
static func export_mod(ref: String) -> Dictionary:
	ModLoader.rescan()
	var clean_ref := str(ref).strip_edges()
	if clean_ref.is_empty():
		return _export_fail("export needs a mod id or block_id")
	var rec := ModLoader.find_mod(clean_ref, false)
	if rec.is_empty():
		return _export_fail("no installed mod '%s'" % clean_ref)
	var mod_id := str(rec.get("id", ""))
	if str(rec.get("error", "")) != "":
		return _export_fail("cannot export broken mod '%s': %s" % [mod_id, str(rec.get("error", ""))])
	var loaded := ModCreator.load_installed(mod_id)
	if str(loaded.get("error", "")) != "":
		return _export_fail("cannot export '%s': %s" % [mod_id, str(loaded.get("error", ""))])
	var kind := str(loaded.get("kind", "block"))
	var name := str(loaded.get("name", mod_id))
	var version := str(loaded.get("version", "1.0"))
	var manifest_in: Dictionary = loaded.get("manifest", {})
	var author := str(manifest_in.get("author", rec.get("author", "")))
	# Block id: block mods read it from the payload; script mods from
	# an in-memory compile of get_block_info().
	var block_id := ""
	if kind == "block":
		block_id = _block_id_of_block_payload(str(loaded.get("payload", "")))
		if block_id.is_empty():
			return _export_fail("cannot export '%s': block payload has no block_id" % mod_id)
	else:
		var compiled := _compile_script_mod(str(loaded.get("payload", "")))
		if str(compiled.get("error", "")) != "":
			return _export_fail("cannot export '%s': %s" % [mod_id, str(compiled.get("error", ""))])
		var info: Dictionary = compiled.get("block_info", {})
		block_id = str(info.get("block_id", ""))
		if block_id.is_empty():
			return _export_fail("cannot export '%s': get_block_info() has no block_id" % mod_id)
	# Manifest, sanitized to the generation-manifest allowlist, rebuilt
	# from known fields so manifest name/kind always match the package.
	var manifest := _sanitized_manifest(manifest_in, name, kind, version, author)
	# Hook files (folder-manifest .gd sources).
	var hook_files: Variant = _read_installed_hook_files(loaded)
	if hook_files is Dictionary and str((hook_files as Dictionary).get("error", "")) != "":
		return _export_fail("cannot export '%s': %s" % [mod_id, str((hook_files as Dictionary).get("error", ""))])
	var hook_list: Array = []
	if hook_files is Array:
		hook_list = hook_files as Array
	# Voxel assets for every visual description the mod carries.
	var asset_res := _assets_for_export(loaded, kind, manifest, hook_list)
	if str(asset_res.get("error", "")) != "":
		return _export_fail("cannot export '%s': %s" % [mod_id, str(asset_res.get("error", ""))])
	var assets: Array = asset_res.get("assets", [])
	var package := {
		"mod_id": mod_id,
		"name": name,
		"kind": kind,
		"version": version,
		"author": author,
		"manifest": manifest,
		"payload": str(loaded.get("payload", "")),
		"spell_school": SpellSchools.normalize(SpellSchools.parse_from_payload(str(loaded.get("payload", "")))),
		"hook_files": hook_list,
		"assets": assets,
	}
	var key_err := _check_key_denylist(package)
	if key_err != "":
		return _export_fail("cannot export '%s': %s" % [mod_id, key_err])
	var mod_json := JSON.stringify(package)
	if mod_json.length() > MAX_PACKAGE_BYTES:
		return _export_fail("cannot export '%s': package is %d bytes (max %d)" % [mod_id, mod_json.length(), MAX_PACKAGE_BYTES])
	var envelope := {"format": FORMAT_VERSION, "mod": mod_json, "sha256": mod_json.sha256_text()}
	var envelope_json := JSON.stringify(envelope)
	var raw := envelope_json.to_utf8_buffer()
	var deflated := raw.compress(FileAccess.COMPRESSION_DEFLATE)
	var framed := _be32(raw.size()) + deflated
	var code := PREFIX + _b64url_encode(framed)
	if code.length() > MAX_CODE_CHARS:
		return _export_fail("cannot export '%s': share code is %d chars (max %d)" % [mod_id, code.length(), MAX_CODE_CHARS])
	return {"ok": true, "code": code, "mod_id": mod_id, "block_id": block_id,
		"name": name, "kind": kind, "version": version,
		"code_chars": code.length(), "asset_count": assets.size(), "error": ""}


## Imports a share code. NEVER writes anything. Accepts a MOD1- prefix
## or a bare body.
static func import_code(code: String) -> Dictionary:
	ModLoader.rescan()
	var raw := _strip_all_whitespace(str(code))
	if raw.is_empty():
		return _import_error("share code is empty — paste a MOD1-... code")
	if raw.length() > MAX_CODE_CHARS:
		return _import_error("share code exceeds %d chars" % MAX_CODE_CHARS)
	var body := raw
	if raw.begins_with(PREFIX):
		body = raw.substr(PREFIX.length())
	elif raw.begins_with("FORGE1-"):
		return _import_error("bad prefix: this is a FORGE1- build code, not a mod share code — share codes start with MOD1-")
	elif _looks_like_version_prefix(raw):
		# A valid bare body never carries a version prefix; try the
		# whole string as a bare body first so a genuine code is
		# never rejected for looking prefix-like.
		var attempt := _decode_body(raw)
		if str(attempt.get("error", "")) == "":
			body = raw
		else:
			return _import_error("bad prefix: share codes start with MOD1- (got '%s')" % raw.left(12))
	if body.is_empty():
		return _import_error("share code has no payload after MOD1-")
	var decoded := _decode_body(body)
	if str(decoded.get("error", "")) != "":
		return _import_error(str(decoded.get("error", "")))
	var package: Dictionary = decoded.get("package", {})
	var perr := _validate_package_shape(package)
	if perr != "":
		return _import_error(perr)
	# Candidate (ModCreator shape + block_id / hook_files / assets /
	# spell_school). Summary is synthesized — the package carries no
	# summary field.
	var manifest: Dictionary = (package.get("manifest", {}) as Dictionary).duplicate(true)
	var candidate := {
		"mod_id": str(package.get("mod_id", "")),
		"name": str(package.get("name", "")),
		"kind": str(package.get("kind", "")),
		"manifest": manifest,
		"payload": str(package.get("payload", "")),
		"summary": _make_summary(str(package.get("name", "")), str(package.get("kind", "")),
			str(package.get("version", "1.0"))),
		"error": "",
		"block_id": "",
		"hook_files": (package.get("hook_files", []) as Array).duplicate(true),
		"assets": (package.get("assets", []) as Array).duplicate(true),
		"spell_school": SpellSchools.normalize(str(package.get("spell_school", ""))),
	}
	# Generation-equivalent validation.
	var creator := ModCreator.new()
	var verr := creator.validate(candidate)
	if verr != "":
		return _import_error(verr)
	var kind := str(candidate.get("kind", ""))
	var manifest_hooks: Array = []
	if manifest.has("hooks"):
		if not (manifest["hooks"] is Array):
			return _import_error("manifest 'hooks' must be an array")
		manifest_hooks = (manifest["hooks"] as Array).duplicate(true)
	var payload_hooks: Array = []
	var hook_file_records: Array = []
	if kind == "block":
		if not (candidate.get("hook_files", []) as Array).is_empty():
			return _import_error("hook_files require kind 'script'")
		var split := ModLoader._split_block_and_hooks(JSON.parse_string(str(candidate.get("payload", ""))))
		if str(split.get("error", "")) != "":
			return _import_error(str(split.get("error", "")))
		var block: Dictionary = split.get("block", {})
		candidate["block_id"] = str(block.get("block_id", ""))
		payload_hooks = split.get("hooks", [])
	else:
		# Script-compile check via in-memory get_block_info().
		var compiled := _compile_script_mod(str(candidate.get("payload", "")))
		if str(compiled.get("error", "")) != "":
			return _import_error(str(compiled.get("error", "")))
		var info: Dictionary = compiled.get("block_info", {})
		candidate["block_id"] = str(info.get("block_id", ""))
		var gh: Variant = compiled.get("hooks", null)
		if not (gh is Array):
			return _import_error("get_hooks() did not return an Array")
		payload_hooks = gh
		for hf in (candidate.get("hook_files", []) as Array):
			if not (hf is Dictionary):
				return _import_error("hook file entry is not an object")
			var frec := _validate_hook_file_source(str((hf as Dictionary).get("file", "")),
				str((hf as Dictionary).get("source", "")))
			if str(frec.get("error", "")) != "":
				return _import_error(str(frec.get("error", "")))
			hook_file_records.append(frec.get("record", {}))
	# Hook-id uniqueness across MERGED hook sources.
	var merged := _validate_merged_hooks(manifest_hooks, payload_hooks, hook_file_records)
	if str(merged.get("error", "")) != "":
		return _import_error(str(merged.get("error", "")))
	# Asset shape + cache-key binding.
	var aerr := _validate_assets(candidate.get("assets", []))
	if aerr != "":
		return _import_error(aerr)
	# Conflict detection: BOTH a block_id clash AND a folder-id clash.
	var by_mod := ModLoader.find_mod(str(candidate.get("mod_id", "")), false)
	var by_block := by_mod
	if str(candidate.get("block_id", "")) != str(candidate.get("mod_id", "")):
		by_block = ModLoader.find_mod(str(candidate.get("block_id", "")), false)
	var folder_clash := not by_mod.is_empty()
	var block_clash := not by_block.is_empty()
	var conflict := folder_clash or block_clash
	var existing := {}
	var existing_id := ""
	var identical := false
	var resolutions: Array = []
	var candidate_keep_both := {}
	var kb_reason := ""
	if conflict:
		var target_rec := by_mod if folder_clash else by_block
		existing_id = str(target_rec.get("id", ""))
		existing = _installed_view(existing_id)
		identical = _is_identical(candidate, existing, hook_file_records)
		resolutions.append({"action": "replace", "mod_id": existing_id})
		var kb := _compute_keep_both(candidate, folder_clash, block_clash)
		if bool(kb.get("available", false)):
			candidate_keep_both = kb.get("candidate", {})
			resolutions.append({"action": "keep_both", "mod_id": str(candidate_keep_both.get("mod_id", ""))})
		else:
			kb_reason = str(kb.get("reason", "Keep Both is unavailable for this import"))
	# Hooks / hook summary for the approval screen.
	var hooks := ModHook.preview_hooks_for_candidate(candidate)
	for rec in hook_file_records:
		var hr: Dictionary = (rec as Dictionary).duplicate(true)
		hr.erase("_instance")
		hooks.append(hr)
	for h in hooks:
		if h is Dictionary:
			(h as Dictionary).erase("_instance")
	var hook_summary := ModHook.summarize_hooks(hooks)
	# Manifest hooks preview misses (it reads payload/get_hooks only):
	# add one line per manifest hook not already listed.
	for mh in manifest_hooks:
		if mh is Dictionary:
			var mid := str((mh as Dictionary).get("hook_id", ""))
			var found := false
			for h in hooks:
				if h is Dictionary and str((h as Dictionary).get("hook_id", "")) == mid:
					found = true
					break
			if not found:
				var mcopy: Dictionary = (mh as Dictionary).duplicate(true)
				hook_summary.append_array(ModHook.summarize_hooks([mcopy]))
	for rec in hook_file_records:
		var r := rec as Dictionary
		var line := "Hook file '%s' adds a new hook: %s (hook point: %s)" % [
			str(r.get("file", "?")), str(r.get("hook_id", "?")), str(r.get("hook_point", "?"))]
		var desc := str(r.get("description", "")).strip_edges()
		if not desc.is_empty():
			line += " — " + desc
		hook_summary.append(line)
	if hook_summary.is_empty():
		hook_summary = ["No new hooks — this mod uses existing blocks only."]
	var out := {
		"ok": true,
		"kind": "conflict" if conflict else "candidate",
		"error": "",
		"candidate": candidate,
		"candidate_keep_both": candidate_keep_both,
		"existing": existing,
		"existing_id": existing_id,
		"resolutions": resolutions,
		"conflict": conflict,
		"hooks": hooks,
		"hook_summary": hook_summary,
		"hook_files": candidate.get("hook_files", []),
		"summary": str(candidate.get("summary", "")),
		"asset_count": (candidate.get("assets", []) as Array).size(),
		"identical": identical,
	}
	if not kb_reason.is_empty():
		out["keep_both_unavailable_reason"] = kb_reason
	return out


## Installs an import_code result. The ONLY write path (with
## install_imported). Reads existing_id / existing from the result it
## receives — the menu annotates a COPY with its resolved conflict
## context, so Replace targets THAT mod.
static func install_import_result(result: Dictionary, resolution: String) -> Dictionary:
	ModLoader.rescan()
	var res := _normalize_resolution(resolution)
	if res.is_empty():
		return _install_fail("unknown resolution '%s'" % str(resolution))
	if result.is_empty():
		return _install_fail("no import result to install")
	if result.has("ok") and not bool(result.get("ok", false)):
		return _install_fail(str(result.get("error", "import failed")))
	var candidate: Variant = result.get("candidate", null)
	if not (candidate is Dictionary) or (candidate as Dictionary).is_empty():
		return _install_fail("import result has no candidate")
	var cand := candidate as Dictionary
	if str(cand.get("error", "")) != "":
		return _install_fail(str(cand.get("error", "")))
	var existing_id := str(result.get("existing_id", ""))
	var existing: Variant = result.get("existing", null)
	if existing_id.is_empty() and existing is Dictionary and not (existing as Dictionary).is_empty():
		existing_id = str((existing as Dictionary).get("mod_id", (existing as Dictionary).get("id", "")))
	if res == "fresh":
		return _install_fresh(cand)
	if res == "replace":
		if existing_id.is_empty():
			return _install_fail("Replace needs an existing mod id — re-import the code and choose Replace again")
		return _install_replace(cand, existing_id)
	# keep_both: prefer the import's pre-rewritten candidate; recompute
	# when it is missing (menu backstop case) or now taken.
	var kb: Variant = result.get("candidate_keep_both", null)
	if kb is Dictionary and not (kb as Dictionary).is_empty() and not _candidate_collides(kb as Dictionary):
		return _install_fresh(kb as Dictionary)
	var recomputed := _recompute_keep_both(cand, existing_id)
	if (recomputed.get("candidate", {}) as Dictionary).is_empty():
		return _install_fail(str(recomputed.get("reason", "Keep Both is unavailable for this import")))
	return _install_fresh(recomputed.get("candidate", {}) as Dictionary)


## Installs an already-resolved candidate. `candidate` is the exact
## candidate to write (for keep_both, the caller passes the renamed
## candidate); `existing_mod_id` is the Replace target.
static func install_imported(candidate: Dictionary, resolution: String, existing_mod_id: String = "") -> Dictionary:
	ModLoader.rescan()
	var res := _normalize_resolution(resolution)
	if res.is_empty():
		return _install_fail("unknown resolution '%s'" % str(resolution))
	if candidate.is_empty():
		return _install_fail("no candidate to install")
	if str(candidate.get("error", "")) != "":
		return _install_fail(str(candidate.get("error", "")))
	if res == "fresh":
		return _install_fresh(candidate)
	if res == "replace":
		if str(existing_mod_id).strip_edges().is_empty():
			return _install_fail("Replace needs an existing mod id")
		return _install_replace(candidate, str(existing_mod_id))
	# keep_both: the candidate is already renamed by the caller.
	return _install_fresh(candidate)


# --- Result shapes ------------------------------------------------------------

static func _export_fail(msg: String) -> Dictionary:
	return {"ok": false, "code": "", "mod_id": "", "block_id": "", "name": "",
		"kind": "", "version": "", "code_chars": 0, "asset_count": 0, "error": msg}


static func _import_error(msg: String) -> Dictionary:
	return {"ok": false, "kind": "error", "error": msg, "candidate": {},
		"candidate_keep_both": {}, "existing": {}, "existing_id": "",
		"resolutions": [], "conflict": false, "hooks": [], "hook_summary": [],
		"hook_files": [], "summary": "", "asset_count": 0, "identical": false}


static func _install_fail(msg: String) -> Dictionary:
	return {"ok": false, "mod_id": "", "block_id": "", "version": "",
		"replaced": false, "error": msg}


static func _normalize_resolution(resolution: String) -> String:
	var r := str(resolution).strip_edges().to_lower().replace("-", "_")
	if r.is_empty() or r == "fresh":
		return "fresh"
	if r == "replace":
		return "replace"
	if r == "keep_both" or r == "keepboth":
		return "keep_both"
	return ""


static func _make_summary(name: String, kind: String, version: String) -> String:
	var n := str(name).strip_edges()
	if n.length() > 100:
		n = n.left(97) + "..."
	var s := "Shared mod '%s' (%s, v%s) — imported from a share code." % [n, kind, version]
	if s.length() > 300:
		s = s.left(297) + "..."
	return s


# --- Encoding / decoding ------------------------------------------------------

static func _b64url_encode(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").rstrip("=")


static func _b64url_decode(body: String) -> Dictionary:
	for ch in body:
		if not B64URL_CHARS.contains(ch):
			return {"ok": false, "bytes": PackedByteArray(), "error": "bad base64: share code contains invalid character '%s' — codes use only A-Z, a-z, 0-9, '-' and '_'" % ch}
	var s := body.replace("-", "+").replace("_", "/")
	while s.length() % 4 != 0:
		s += "="
	var raw := Marshalls.base64_to_raw(s)
	if raw.is_empty():
		return {"ok": false, "bytes": PackedByteArray(), "error": "bad base64: share code could not be decoded"}
	return {"ok": true, "bytes": raw, "error": ""}


static func _be32(n: int) -> PackedByteArray:
	var out := PackedByteArray([0, 0, 0, 0])
	out[0] = (n >> 24) & 0xFF
	out[1] = (n >> 16) & 0xFF
	out[2] = (n >> 8) & 0xFF
	out[3] = n & 0xFF
	return out


static func _strip_all_whitespace(s: String) -> String:
	var out := ""
	for i in range(s.length()):
		var ch := s[i]
		if ch != " " and ch != "\t" and ch != "\n" and ch != "\r":
			out += ch
	return out


## True when `s` starts with a version-prefix shape ("XXXX-..."):
## 1-8 uppercase/digit chars, first one a letter, then "-".
static func _looks_like_version_prefix(s: String) -> bool:
	var dash := s.find("-")
	if dash < 1 or dash > 8:
		return false
	for i in range(dash):
		var ch := s[i]
		if not "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains(ch):
			return false
	return "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(s[0])


## Decodes one code body (no MOD1- prefix) into its package.
## {ok, package} or {ok: false, error}.
static func _decode_body(body: String) -> Dictionary:
	var dec := _b64url_decode(body)
	if not bool(dec.get("ok", false)):
		return {"ok": false, "package": {}, "error": str(dec.get("error", ""))}
	var framed: PackedByteArray = dec.get("bytes", PackedByteArray())
	if framed.size() < 5:
		return {"ok": false, "package": {}, "error": "code too short — a share code holds a compressed mod package"}
	var declared := (framed[0] << 24) | (framed[1] << 16) | (framed[2] << 8) | framed[3]
	if declared <= 0 or declared > MAX_ENVELOPE_BYTES:
		return {"ok": false, "package": {}, "error": "decompression failed: declared uncompressed length %d is out of range" % declared}
	var deflated := framed.slice(4)
	var plain := deflated.decompress(declared, FileAccess.COMPRESSION_DEFLATE)
	if plain.is_empty() or plain.size() != declared:
		return {"ok": false, "package": {}, "error": "decompression failed: the code was corrupted or truncated"}
	var envelope_text := plain.get_string_from_utf8()
	var envelope: Variant = JSON.parse_string(envelope_text)
	if not (envelope is Dictionary):
		return {"ok": false, "package": {}, "error": "code is not a valid share envelope"}
	var env := envelope as Dictionary
	if int(env.get("format", -1)) != FORMAT_VERSION:
		return {"ok": false, "package": {}, "error": "unsupported share format %s (expected %d)" % [str(env.get("format", "?")), FORMAT_VERSION]}
	var mod_str: Variant = env.get("mod", null)
	var sha: Variant = env.get("sha256", null)
	if not (mod_str is String) or not (sha is String):
		return {"ok": false, "package": {}, "error": "checksum mismatch: the share envelope is missing its checksum"}
	if str(mod_str).sha256_text() != str(sha):
		return {"ok": false, "package": {}, "error": "checksum mismatch: the code was corrupted or tampered with"}
	if str(mod_str).length() > MAX_PACKAGE_BYTES:
		return {"ok": false, "package": {}, "error": "package exceeds %d bytes uncompressed" % MAX_PACKAGE_BYTES}
	var package: Variant = JSON.parse_string(str(mod_str))
	if not (package is Dictionary):
		return {"ok": false, "package": {}, "error": "schema failure: package is not a JSON object"}
	return {"ok": true, "package": package as Dictionary, "error": ""}


# --- Package schema / denylist --------------------------------------------------

## "" = package shape OK, else a visible reason.
static func _validate_package_shape(package: Dictionary) -> String:
	for k in package.keys():
		if str(k) not in PACKAGE_KEYS:
			return "schema failure: unknown package field '%s'" % str(k)
	for req in ["mod_id", "name", "kind", "manifest", "payload"]:
		if not package.has(req):
			return "schema failure: package is missing '%s'" % req
	var mod_id := str(package.get("mod_id", ""))
	if mod_id.is_empty() or mod_id != ModCreator.sanitize_mod_id(mod_id) or mod_id.length() > 48:
		return "schema failure: package mod_id '%s' is not a valid [a-z0-9_] id" % mod_id
	if str(package.get("name", "")).strip_edges().is_empty():
		return "schema failure: package name is empty"
	if str(package.get("kind", "")) not in ["block", "script"]:
		return "schema failure: package kind must be 'block' or 'script'"
	if not (package.get("manifest", null) is Dictionary):
		return "schema failure: package manifest is not an object"
	var manifest: Dictionary = package.get("manifest", {})
	for k in manifest.keys():
		if str(k) not in MANIFEST_KEYS:
			return "schema failure: unknown manifest field '%s'" % str(k)
	if not (package.get("payload", null) is String) or str(package.get("payload", "")).strip_edges().is_empty():
		return "schema failure: package payload is empty"
	if package.has("version") and not (package["version"] is String):
		return "schema failure: package version must be a string"
	if package.has("author") and not (package["author"] is String):
		return "schema failure: package author must be a string"
	if package.has("spell_school") and not (package["spell_school"] is String):
		return "schema failure: package spell_school must be a string"
	if package.has("hook_files"):
		if not (package["hook_files"] is Array):
			return "schema failure: package hook_files must be an array"
		if (package["hook_files"] as Array).size() > MAX_HOOK_FILES:
			return "schema failure: package has %d hook files (max %d)" % [(package["hook_files"] as Array).size(), MAX_HOOK_FILES]
		for hf in (package["hook_files"] as Array):
			if not (hf is Dictionary):
				return "schema failure: hook file entry is not an object"
			for k in (hf as Dictionary).keys():
				if str(k) not in ["file", "source"]:
					return "schema failure: unknown hook file field '%s'" % str(k)
			if not ((hf as Dictionary).get("file", null) is String) or not ((hf as Dictionary).get("source", null) is String):
				return "schema failure: hook file needs 'file' and 'source' strings"
			if str((hf as Dictionary).get("source", "")).length() > MAX_HOOK_FILE_CHARS:
				return "schema failure: hook file '%s' exceeds %d chars" % [str((hf as Dictionary).get("file", "")), MAX_HOOK_FILE_CHARS]
	if package.has("assets") and not (package["assets"] is Array):
		return "schema failure: package assets must be an array"
	var derr := _check_key_denylist(package)
	if derr != "":
		return derr
	return ""


## Structured-key denylist over Dictionary KEYS (recursive, into Arrays
## and nested Dictionaries). Values are NEVER inspected. "" = clean.
static func _check_key_denylist(v: Variant) -> String:
	if v is Dictionary:
		for k in (v as Dictionary).keys():
			var key := str(k)
			var norm := key.to_lower().replace("-", "_")
			for term in KEY_DENYLIST:
				if norm == term or norm.begins_with(term + "_") or norm.ends_with("_" + term) or norm.contains("_" + term + "_"):
					return "package contains forbidden key '%s' (matches denylisted term '%s')" % [key, term]
			var sub := _check_key_denylist((v as Dictionary)[k])
			if sub != "":
				return sub
	elif v is Array:
		for item in (v as Array):
			var sub2 := _check_key_denylist(item)
			if sub2 != "":
				return sub2
	return ""


## Rebuilds the package manifest from known fields only (the
## generation-manifest allowlist), so manifest name/kind always match
## the package.
static func _sanitized_manifest(manifest_in: Dictionary, name: String, kind: String, version: String, author: String) -> Dictionary:
	var out := {"name": name, "kind": kind, "version": version, "author": author}
	if manifest_in.has("description") and manifest_in["description"] is String:
		out["description"] = str(manifest_in["description"])
	if manifest_in.has("hooks") and manifest_in["hooks"] is Array:
		out["hooks"] = (manifest_in["hooks"] as Array).duplicate(true)
	return out


# --- Script / hook compilation (in-memory) --------------------------------------

## Compiles a ModBlock script in memory (nothing written). Returns
## {instance, block_info, hooks, error}. Instantiation runs the
## script's _init, which must stay side-effect free per the ModBlock
## contract (the loader does the same at scan time).
static func _compile_script_mod(source: String) -> Dictionary:
	var scr := GDScript.new()
	scr.source_code = source
	var err := scr.reload()
	if err != OK:
		return {"instance": null, "block_info": {}, "hooks": [], "error": "script failed to compile: %s" % error_string(err)}
	if not scr.can_instantiate():
		return {"instance": null, "block_info": {}, "hooks": [], "error": "script cannot instantiate"}
	var inst: Variant = scr.new()
	if not (inst is ModBlock):
		return {"instance": null, "block_info": {}, "hooks": [], "error": "script does not extend ModBlock"}
	var block_info: Variant = (inst as ModBlock).get_block_info()
	if not (block_info is Dictionary):
		return {"instance": null, "block_info": {}, "hooks": [], "error": "get_block_info() did not return a Dictionary"}
	var berr := ModLoader._validate_block(block_info as Dictionary, false)
	if berr != "":
		return {"instance": null, "block_info": {}, "hooks": [], "error": berr}
	var hooks: Variant = (inst as ModBlock).get_hooks()
	if not (hooks is Array):
		return {"instance": null, "block_info": {}, "hooks": [], "error": "get_hooks() did not return an Array"}
	return {"instance": inst as ModBlock, "block_info": block_info as Dictionary,
		"hooks": hooks as Array, "error": ""}


## Validates ONE hook-code file's in-memory source (mirrors
## ModLoader._load_hook_file without touching disk). Returns
## {record, error}; record = {file, source, hook_id, hook_point,
## code, display_name?, description?}.
static func _validate_hook_file_source(file: String, source: String) -> Dictionary:
	if file.strip_edges().is_empty():
		return {"record": {}, "error": "hook file name must be a non-empty string"}
	if ".." in file or file.begins_with("/") or file.begins_with("user://") or "/" in file:
		return {"record": {}, "error": "bad hook file path '%s'" % file}
	if not file.ends_with(".gd"):
		return {"record": {}, "error": "hook file '%s' must be a .gd file" % file}
	if source.length() > MAX_HOOK_FILE_CHARS:
		return {"record": {}, "error": "hook file '%s' exceeds %d chars" % [file, MAX_HOOK_FILE_CHARS]}
	var cerr := ModHook.validate_hook_code(source)
	if cerr != "":
		return {"record": {}, "error": cerr}
	var compiled := ModHook.compile_hook_code(source)
	if str(compiled.get("error", "")) != "":
		return {"record": {}, "error": str(compiled.get("error", ""))}
	var inst: Variant = compiled.get("instance", null)
	if not (inst is ModHook):
		return {"record": {}, "error": "hook file '%s': compiled code does not extend ModHook" % file}
	var info: Variant = (inst as ModHook).get_hook_info()
	if not (info is Dictionary):
		return {"record": {}, "error": "hook file '%s': get_hook_info() did not return a Dictionary" % file}
	var hid: Variant = (info as Dictionary).get("hook_id", null)
	var point: Variant = (info as Dictionary).get("hook_point", null)
	if not (hid is String) or str(hid).strip_edges().is_empty():
		return {"record": {}, "error": "hook file '%s': get_hook_info() has no hook_id" % file}
	var norm_point := ModHook.normalize_hook_point(str(point)) if point is String else ""
	if norm_point.is_empty():
		return {"record": {}, "error": "hook file '%s': get_hook_info() has unknown hook_point '%s'" % [file, str(point)]}
	var record := {"file": file, "source": source, "hook_id": str(hid),
		"hook_point": norm_point, "code": source}
	if (info as Dictionary).has("display_name"):
		record["display_name"] = str((info as Dictionary).get("display_name", ""))
	if (info as Dictionary).has("description"):
		record["description"] = str((info as Dictionary).get("description", ""))
	return {"record": record, "error": ""}


## Validates a MERGED hook list (manifest + payload/get_hooks + hook
## files). Each hook is validated on a copy (validate_hook_data
## normalizes hook_point and compiles code hooks). Returns
## {hooks, error}. Duplicate hook_ids across sources are rejected.
static func _validate_merged_hooks(manifest_hooks: Array, payload_hooks: Array, hook_file_records: Array) -> Dictionary:
	var out: Array = []
	var seen := {}
	var sources := [manifest_hooks, payload_hooks]
	for src in sources:
		for h in (src as Array):
			if not (h is Dictionary):
				return {"hooks": [], "error": "hook is not an object"}
			var copy: Dictionary = (h as Dictionary).duplicate(true)
			var err := ModHook.validate_hook_data(copy)
			if err != "":
				return {"hooks": [], "error": err}
			var hid := str(copy.get("hook_id", ""))
			if seen.has(hid):
				return {"hooks": [], "error": "duplicate hook_id '%s' across merged hook sources" % hid}
			seen[hid] = true
			out.append(copy)
	for rec in hook_file_records:
		if not (rec is Dictionary):
			return {"hooks": [], "error": "hook file record is not an object"}
		var copy2: Dictionary = (rec as Dictionary).duplicate(true)
		copy2.erase("file")
		copy2.erase("source")
		var err2 := ModHook.validate_hook_data(copy2)
		if err2 != "":
			return {"hooks": [], "error": err2}
		var hid2 := str(copy2.get("hook_id", ""))
		if seen.has(hid2):
			return {"hooks": [], "error": "duplicate hook_id '%s' across merged hook sources" % hid2}
		seen[hid2] = true
		out.append(copy2)
	if out.size() > ModLoader.MAX_HOOKS_PER_MOD:
		return {"hooks": [], "error": "mod carries %d hooks (max %d)" % [out.size(), ModLoader.MAX_HOOKS_PER_MOD]}
	return {"hooks": out, "error": ""}


# --- Assets ---------------------------------------------------------------------

## "" = assets valid, else a visible reason. Checks shape + cache-key
## binding (key == sha256 of the normalized description).
static func _validate_assets(assets: Variant) -> String:
	if not (assets is Array):
		return "package assets must be an array"
	var total := 0
	for a in (assets as Array):
		if not (a is Dictionary):
			return "asset entry is not an object"
		for k in ["key", "description", "voxels"]:
			if not (a as Dictionary).has(k):
				return "asset is missing '%s'" % k
		var key := str((a as Dictionary).get("key", ""))
		var desc := str((a as Dictionary).get("description", ""))
		if desc.strip_edges().is_empty():
			return "asset description is empty"
		if key.length() != 64:
			return "asset key must be a 64-char sha256"
		var norm := VoxelAssetGenerator.normalize_description(desc)
		if VoxelAssetGenerator.cache_key(norm) != key:
			return "asset key does not match its description (cache-key binding failed)"
		var vox: Variant = (a as Dictionary).get("voxels", null)
		if not (vox is Array):
			return "asset voxels must be an array"
		if (vox as Array).size() > MAX_VOXELS_PER_ASSET:
			return "asset for '%s' has %d voxels (max %d per asset)" % [desc, (vox as Array).size(), MAX_VOXELS_PER_ASSET]
		total += (vox as Array).size()
		for v in (vox as Array):
			if not (v is Dictionary):
				return "asset voxel is not an object"
			var p: Variant = (v as Dictionary).get("p", null)
			var c: Variant = (v as Dictionary).get("c", null)
			if not (p is Array) or (p as Array).size() != 3:
				return "asset voxel 'p' must be [x, y, z]"
			for coord in (p as Array):
				if not (coord is int or coord is float):
					return "asset voxel 'p' coordinates must be numbers"
			if not (c is String) or not _is_hex_color(str(c)):
				return "asset voxel 'c' must be a '#rrggbb' color"
	if total > MAX_VOXELS_TOTAL:
		return "assets carry %d voxels total (max %d)" % [total, MAX_VOXELS_TOTAL]
	return ""


## Accepts "#rrggbb" or "rrggbb[aa]" (VoxelAssetGenerator's
## Color.to_html() emits 8-char rrggbbaa with no "#").
static func _is_hex_color(s: String) -> bool:
	var hex := s.trim_prefix("#")
	if hex.length() != 6 and hex.length() != 8:
		return false
	for ch in hex:
		if not "0123456789abcdefABCDEF".contains(ch):
			return false
	return true


## Reads an installed mod's hook files (folder-manifest .gd sources,
## or the companion manifest for single-file mods). Returns an Array
## of {file, source} or {error}.
static func _read_installed_hook_files(loaded: Dictionary) -> Variant:
	var names: Array = []
	var folder := ""
	if bool(loaded.get("is_folder", false)):
		folder = str(loaded.get("path", ""))
		var mpath := folder.path_join("manifest.json")
		if FileAccess.file_exists(mpath):
			var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(mpath))
			if m is Dictionary and (m as Dictionary).has("hook_files") and (m as Dictionary)["hook_files"] is Array:
				names = ((m as Dictionary)["hook_files"] as Array).duplicate(true)
	else:
		folder = ModLoader.MODS_DIR
		var companion := str(loaded.get("path", "")).get_basename() + ".json"
		if FileAccess.file_exists(companion):
			var m2: Variant = JSON.parse_string(FileAccess.get_file_as_string(companion))
			if m2 is Dictionary and (m2 as Dictionary).has("hook_files") and (m2 as Dictionary)["hook_files"] is Array:
				names = ((m2 as Dictionary)["hook_files"] as Array).duplicate(true)
	var out: Array = []
	for n in names:
		if not (n is String):
			return {"error": "hook file name is not a string"}
		var fname := str(n)
		if ".." in fname or fname.begins_with("/") or fname.begins_with("user://"):
			return {"error": "bad hook file path '%s'" % fname}
		var path := folder.path_join(fname)
		if not FileAccess.file_exists(path):
			return {"error": "hook file '%s' not found" % fname}
		out.append({"file": fname, "source": FileAccess.get_file_as_string(path)})
	return out


## Resolves every visual description an installed mod carries and
## embeds the voxel arrays. Descriptions: manifest description, block
## description, every hook projectile visual (payload + manifest
## hooks; for script mods, get_hooks() via an in-memory compile).
static func _assets_for_export(loaded: Dictionary, kind: String, manifest: Dictionary, hook_list: Array) -> Dictionary:
	var descriptions: Array = []
	var seen_norm := {}
	var add_desc := func(desc: String) -> void:
		var d := str(desc).strip_edges()
		if d.is_empty():
			return
		var norm := VoxelAssetGenerator.normalize_description(d)
		if norm.is_empty() or seen_norm.has(norm):
			return
		seen_norm[norm] = true
		descriptions.append(d)
	add_desc.call(str(manifest.get("description", "")))
	var payload := str(loaded.get("payload", ""))
	var hooks: Array = []
	if manifest.has("hooks") and manifest["hooks"] is Array:
		hooks.append_array(manifest["hooks"] as Array)
	if kind == "block":
		var data: Variant = JSON.parse_string(payload)
		if data is Dictionary:
			var d := data as Dictionary
			var block: Variant = d.get("block", null)
			if block is Dictionary:
				add_desc.call(str((block as Dictionary).get("description", "")))
			var ph: Variant = d.get("hooks", null)
			if ph is Array:
				hooks.append_array(ph as Array)
	else:
		var compiled := _compile_script_mod(payload)
		if str(compiled.get("error", "")) != "":
			return {"assets": [], "error": str(compiled.get("error", ""))}
		add_desc.call(str((compiled.get("block_info", {}) as Dictionary).get("description", "")))
		hooks.append_array(compiled.get("hooks", []))
	for h in hooks:
		if h is Dictionary and (h as Dictionary).has("projectile"):
			var proj: Variant = (h as Dictionary).get("projectile", null)
			if proj is Dictionary:
				add_desc.call(str((proj as Dictionary).get("visual", "")))
	var assets: Array = []
	var total := 0
	for desc in descriptions:
		var asset := VoxelAssetGenerator.get_or_generate(str(desc))
		# Normalize: a cache HIT returns JSON-parsed voxels (float
		# coords) while a MISS returns fresh ints — JSON.stringify
		# prints those differently ("1.0" vs "1"), so an
		# un-normalized export is non-deterministic. Canonicalize
		# coords to ints so EXPORT always yields the same code.
		var voxels: Array = []
		for v in (asset.get("voxels", []) as Array):
			if v is Dictionary:
				var p: Variant = (v as Dictionary).get("p", [])
				if p is Array and (p as Array).size() == 3:
					voxels.append({"p": [int((p as Array)[0]), int((p as Array)[1]), int((p as Array)[2])],
						"c": str((v as Dictionary).get("c", ""))})
		if voxels.size() > MAX_VOXELS_PER_ASSET:
			return {"assets": [], "error": "voxel asset for '%s' has %d voxels (max %d per asset)" % [str(desc), voxels.size(), MAX_VOXELS_PER_ASSET]}
		total += voxels.size()
		if total > MAX_VOXELS_TOTAL:
			return {"assets": [], "error": "voxel assets carry %d voxels total (max %d)" % [total, MAX_VOXELS_TOTAL]}
		assets.append({"key": str(asset.get("cache_key", "")),
			"description": str(asset.get("normalized", "")),
			"voxels": voxels})
	return {"assets": assets, "error": ""}


## The block_id of a block payload (wrapper or pure block form).
static func _block_id_of_block_payload(payload: String) -> String:
	var data: Variant = JSON.parse_string(payload)
	if not (data is Dictionary):
		return ""
	var d := data as Dictionary
	if d.has("block") and d["block"] is Dictionary:
		return str((d["block"] as Dictionary).get("block_id", ""))
	return str(d.get("block_id", ""))


## Rewrites a block payload's block_id to `new_id` (wrapper-preserving).
## "" when the payload is not a JSON object.
static func _rewrite_block_payload_id(payload: String, new_id: String) -> String:
	var data: Variant = JSON.parse_string(payload)
	if not (data is Dictionary):
		return ""
	var d := data as Dictionary
	if d.has("block") and d["block"] is Dictionary:
		(d["block"] as Dictionary)["block_id"] = new_id
	else:
		d["block_id"] = new_id
	return JSON.stringify(d)


## Rewrites QUOTED block_id literals in script source ("old" / 'old'
## -> "new" / 'new'). Unquoted / computed occurrences are untouched
## (that is what makes a computed block_id detectable).
static func _rewrite_quoted_literal(source: String, old_id: String, new_id: String) -> String:
	return source.replace("\"" + old_id + "\"", "\"" + new_id + "\"").replace("'" + old_id + "'", "'" + new_id + "'")


# --- Installed view / identical ---------------------------------------------------

## load_installed shape for an installed mod (the shape the menu's
## backstop produces for `existing`). Falls back to a record-shaped
## view when the mod cannot be loaded.
static func _installed_view(mod_id: String) -> Dictionary:
	var loaded := ModCreator.load_installed(mod_id)
	if str(loaded.get("error", "")) == "":
		return loaded
	var rec := ModLoader.find_mod(mod_id, false)
	if rec.is_empty():
		return {}
	return {"mod_id": str(rec.get("id", mod_id)), "name": str(rec.get("name", "")),
		"kind": str(rec.get("kind", "")), "version": str(rec.get("version", "1.0")),
		"manifest": {}, "payload": "", "path": str(rec.get("path", "")),
		"is_folder": false, "error": str(rec.get("error", ""))}


## True when the incoming candidate is byte-identical to the installed
## mod: same payload bytes, same (file-stripped) manifest, same hook
## files, same spell school.
static func _is_identical(candidate: Dictionary, existing: Dictionary, hook_file_records: Array) -> bool:
	if existing.is_empty():
		return false
	if str(candidate.get("payload", "")) != str(existing.get("payload", "")):
		return false
	var cm: Dictionary = (candidate.get("manifest", {}) as Dictionary).duplicate(true)
	var em: Dictionary = (existing.get("manifest", {}) as Dictionary).duplicate(true)
	cm.erase("file")
	em.erase("file")
	em.erase("hook_files")
	if not _deep_equal(cm, em):
		return false
	if SpellSchools.normalize(str(candidate.get("spell_school", ""))) != SpellSchools.parse_from_payload(str(existing.get("payload", ""))):
		return false
	var existing_files: Variant = _read_installed_hook_files(existing)
	if existing_files is Dictionary:
		return false
	var a := _sorted_hook_files(candidate.get("hook_files", []))
	var b := _sorted_hook_files(existing_files)
	return _deep_equal(a, b)


static func _sorted_hook_files(files: Variant) -> Array:
	var arr: Array = []
	if files is Array:
		for f in (files as Array):
			if f is Dictionary:
				arr.append({"file": str((f as Dictionary).get("file", "")),
					"source": str((f as Dictionary).get("source", ""))})
	arr.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return str(x.get("file", "")) < str(y.get("file", "")))
	return arr


static func _deep_equal(a: Variant, b: Variant) -> bool:
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


# --- Keep Both --------------------------------------------------------------------

## First free Keep Both id for `base`. Block mods: <base>_copy,
## <base>_copy_2, ... (menu-compatible). Script mods: <base>_2,
## <base>_3, ... (the script rewrite is verified against this id).
static func _first_free_id(base: String, kind: String) -> String:
	for n in range(MAX_KEEP_BOTH_ATTEMPTS):
		var c := ""
		if kind == "block":
			c = base + "_copy" if n == 0 else "%s_copy_%d" % [base, n + 1]
		else:
			c = "%s_%d" % [base, n + 2]
		if ModLoader.find_mod(c, false).is_empty() and not _folder_exists(c):
			return c
	return ""


static func _folder_exists(mod_id: String) -> bool:
	var dir := DirAccess.open(ModLoader.MODS_DIR)
	if dir == null:
		return false
	return dir.dir_exists(mod_id)


## Builds the Keep Both candidate for a conflict. Returns
## {available, reason, candidate}. folder_clash / block_clash say
## which kind of conflict was detected.
static func _compute_keep_both(candidate: Dictionary, folder_clash: bool, block_clash: bool) -> Dictionary:
	var kind := str(candidate.get("kind", ""))
	var new_id := _first_free_id(str(candidate.get("mod_id", "")), kind)
	if new_id.is_empty():
		return {"available": false, "reason": "Keep Both is unavailable — no free copy id", "candidate": {}}
	var kb: Dictionary = candidate.duplicate(true)
	kb["mod_id"] = new_id
	var nm := str(kb.get("name", ""))
	if not nm.ends_with(" (copy)"):
		nm += " (copy)"
		kb["name"] = nm
		var m: Dictionary = (kb.get("manifest", {}) as Dictionary).duplicate(true)
		m["name"] = nm
		kb["manifest"] = m
	if block_clash:
		if kind == "block":
			var rewritten := _rewrite_block_payload_id(str(kb.get("payload", "")), new_id)
			if rewritten.is_empty():
				return {"available": false, "reason": "Keep Both is unavailable — block payload is not a JSON object", "candidate": {}}
			kb["payload"] = rewritten
			kb["block_id"] = new_id
		else:
			# Script mods: rewrite quoted block_id literals in the
			# script + hook-file sources, then VERIFY by compiling
			# the rewritten script in memory and reading
			# get_block_info().
			var old_id := str(candidate.get("block_id", ""))
			kb["payload"] = _rewrite_quoted_literal(str(kb.get("payload", "")), old_id, new_id)
			var new_hook_files: Array = []
			for hf in (kb.get("hook_files", []) as Array):
				if not (hf is Dictionary):
					continue
				var nhf: Dictionary = (hf as Dictionary).duplicate(true)
				nhf["source"] = _rewrite_quoted_literal(str(nhf.get("source", "")), old_id, new_id)
				var frec := _validate_hook_file_source(str(nhf.get("file", "")), str(nhf.get("source", "")))
				if str(frec.get("error", "")) != "":
					return {"available": false, "reason": "Keep Both is unavailable — rewritten hook file '%s': %s" % [str(nhf.get("file", "")), str(frec.get("error", ""))], "candidate": {}}
				new_hook_files.append(nhf)
			kb["hook_files"] = new_hook_files
			var compiled := _compile_script_mod(str(kb.get("payload", "")))
			if str(compiled.get("error", "")) != "":
				return {"available": false, "reason": "Keep Both is unavailable — rewritten script: %s" % str(compiled.get("error", "")), "candidate": {}}
			var new_block_id := str((compiled.get("block_info", {}) as Dictionary).get("block_id", ""))
			if new_block_id != new_id:
				return {"available": false, "reason": "Keep Both is unavailable — this script computes its block_id instead of declaring it as a quoted literal, so the copy cannot be renamed safely", "candidate": {}}
			kb["block_id"] = new_id
	# Folder-only conflicts keep block_id and rename only the folder
	# (payload untouched) — handled by leaving kb payload/block_id as-is.
	var creator := ModCreator.new()
	var verr := creator.validate(kb)
	if verr != "":
		return {"available": false, "reason": "Keep Both is unavailable — %s" % verr, "candidate": {}}
	return {"available": true, "reason": "", "candidate": kb}


## Recomputes Keep Both from a candidate + the annotated conflict
## context (menu-backstop case: the import result carried no
## candidate_keep_both). Returns {candidate, reason}.
static func _recompute_keep_both(candidate: Dictionary, existing_id: String) -> Dictionary:
	if existing_id.is_empty():
		return {"candidate": {}, "reason": "Keep Both is unavailable — no conflict context was supplied with this import"}
	var folder_clash := str(candidate.get("mod_id", "")) == existing_id
	var existing_block_id := ""
	var rec := ModLoader.find_mod(existing_id, false)
	if not rec.is_empty():
		existing_block_id = str((rec.get("block_info", {}) as Dictionary).get("block_id", ""))
	var block_clash := str(candidate.get("block_id", "")) == existing_block_id and not existing_block_id.is_empty()
	if not folder_clash and not block_clash:
		return {"candidate": {}, "reason": "Keep Both is unavailable — no conflict was found for this import"}
	var kb := _compute_keep_both(candidate, folder_clash, block_clash)
	if not bool(kb.get("available", false)):
		return {"candidate": {}, "reason": str(kb.get("reason", "Keep Both is unavailable for this import"))}
	return {"candidate": kb.get("candidate", {}), "reason": ""}


# --- Install ----------------------------------------------------------------------

## True when `candidate` would collide with an installed mod (folder
## id, block_id) or an existing folder.
static func _candidate_collides(candidate: Dictionary) -> bool:
	var mid := str(candidate.get("mod_id", ""))
	if mid.is_empty():
		return true
	if not ModLoader.find_mod(mid, false).is_empty():
		return true
	if _folder_exists(mid):
		return true
	var bid := str(candidate.get("block_id", ""))
	if not bid.is_empty() and bid != mid:
		if not ModLoader.find_mod(bid, false).is_empty():
			return true
	return false


## Fresh install of an already-resolved candidate (fresh or Keep
## Both). Never renames: a collision is an error.
static func _install_fresh(candidate: Dictionary) -> Dictionary:
	var work: Dictionary = candidate.duplicate(true)
	if str(work.get("summary", "")) == "" and not work.has("summary"):
		work["summary"] = ""
	if not work.has("error"):
		work["error"] = ""
	var creator := ModCreator.new()
	var verr := creator.validate(work)
	if verr != "":
		return _install_fail(verr)
	if _candidate_collides(work):
		return _install_fail("mod '%s' is already installed — choose Replace or Keep Both" % str(work.get("mod_id", "")))
	var version := str((work.get("manifest", {}) as Dictionary).get("version", "1.0"))
	if version.is_empty():
		version = "1.0"
	return _install_verified(work, str(work.get("mod_id", "")), version,
		str(work.get("block_id", "")), null, false)


## Replace: overwrite the existing mod's folder in place, version
## bumped, snapshot + rollback on failure.
static func _install_replace(candidate: Dictionary, existing_id: String) -> Dictionary:
	var loaded := ModCreator.load_installed(existing_id)
	if str(loaded.get("error", "")) != "":
		return _install_fail("cannot replace '%s': %s" % [existing_id, str(loaded.get("error", ""))])
	var work: Dictionary = candidate.duplicate(true)
	if not work.has("summary"):
		work["summary"] = ""
	if not work.has("error"):
		work["error"] = ""
	if str(work.get("kind", "")) == "block":
		var rewritten := _rewrite_block_payload_id(str(work.get("payload", "")), existing_id)
		if rewritten.is_empty():
			return _install_fail("block payload is not a JSON object")
		work["payload"] = rewritten
	var creator := ModCreator.new()
	var verr := creator.validate(work)
	if verr != "":
		return _install_fail(verr)
	var version := ModCreator.bump_version(str(loaded.get("version", "1.0")))
	var snapshot := _snapshot_existing(existing_id, loaded)
	var expected := existing_id if str(work.get("kind", "")) == "block" else str(work.get("block_id", ""))
	return _install_verified(work, existing_id, version, expected, snapshot, true)


## Writes the candidate into user://mods/<target_id>/ (folder form),
## rescans, verifies the installed record is error-free with the
## expected block_id. `snapshot` is non-null for Replace (rollback +
## stale-file removal). Returns the install result dict.
static func _install_verified(candidate: Dictionary, target_id: String, version: String, expected_block_id: String, snapshot: Variant, replaced: bool) -> Dictionary:
	var written := _write_install_files(candidate, target_id, version)
	if str(written.get("error", "")) != "":
		_rollback(target_id, snapshot)
		ModLoader.rescan()
		return _install_fail(str(written.get("error", "")))
	ModLoader.rescan()
	var check := _verify_installed(target_id, expected_block_id)
	if check != "":
		_rollback(target_id, snapshot)
		ModLoader.rescan()
		return _install_fail(check)
	if snapshot != null:
		_remove_stale_files(target_id, snapshot, written.get("files", []))
		ModLoader.rescan()
		var check2 := _verify_installed(target_id, expected_block_id)
		if check2 != "":
			_rollback(target_id, snapshot)
			ModLoader.rescan()
			return _install_fail(check2)
	var rec := ModLoader.find_mod(target_id, false)
	var installed_block := str((rec.get("block_info", {}) as Dictionary).get("block_id", expected_block_id))
	return {"ok": true, "mod_id": target_id, "block_id": installed_block,
		"version": version, "replaced": replaced, "error": ""}


## "" = installed record is error-free with the expected block_id.
static func _verify_installed(target_id: String, expected_block_id: String) -> String:
	var rec := ModLoader.find_mod(target_id, false)
	if rec.is_empty():
		return "install verification failed for '%s'" % target_id
	var rec_err := str(rec.get("error", ""))
	if rec_err != "":
		return rec_err
	var installed_block := str((rec.get("block_info", {}) as Dictionary).get("block_id", ""))
	if installed_block != expected_block_id:
		return "installed block_id '%s' does not match expected '%s'" % [installed_block, expected_block_id]
	return ""


## Writes manifest.json + payload + hook files + assets for an install.
## Assets are best-effort (a failed cache write never fails the
## install — the generator regenerates on demand).
static func _write_install_files(candidate: Dictionary, target_id: String, version: String) -> Dictionary:
	_ensure_mods_dir()
	var folder := ModLoader.MODS_DIR.path_join(target_id)
	var dir := DirAccess.open(ModLoader.MODS_DIR)
	if dir == null:
		return {"error": "could not open user://mods/", "files": []}
	if dir.make_dir(target_id) != OK and not dir.dir_exists(target_id):
		return {"error": "could not create mod folder '%s'" % target_id}
	var kind := str(candidate.get("kind", ""))
	var payload_file := "block.json" if kind == "block" else "mod.gd"
	var manifest: Dictionary = (candidate.get("manifest", {}) as Dictionary).duplicate(true)
	manifest["name"] = str(candidate.get("name", ""))
	manifest["kind"] = kind
	manifest["version"] = version
	manifest["file"] = payload_file
	var hook_files: Array = candidate.get("hook_files", [])
	if not hook_files.is_empty():
		var names: Array = []
		for hf in hook_files:
			if hf is Dictionary:
				names.append(str((hf as Dictionary).get("file", "")))
		manifest["hook_files"] = names
	else:
		manifest.erase("hook_files")
	var files: Array = ["manifest.json", payload_file]
	var mf := FileAccess.open(folder.path_join("manifest.json"), FileAccess.WRITE)
	if mf == null:
		return {"error": "could not write manifest.json", "files": []}
	mf.store_string(JSON.stringify(manifest))
	mf.close()
	var pf := FileAccess.open(folder.path_join(payload_file), FileAccess.WRITE)
	if pf == null:
		return {"error": "could not write %s" % payload_file, "files": files}
	pf.store_string(str(candidate.get("payload", "")))
	pf.close()
	for hf in hook_files:
		if not (hf is Dictionary):
			continue
		var fname := str((hf as Dictionary).get("file", ""))
		var hfile := FileAccess.open(folder.path_join(fname), FileAccess.WRITE)
		if hfile == null:
			return {"error": "could not write hook file '%s'" % fname, "files": files}
		hfile.store_string(str((hf as Dictionary).get("source", "")))
		hfile.close()
		files.append(fname)
	_write_assets(candidate.get("assets", []))
	return {"error": "", "files": files}


## Writes embedded voxel assets back to the asset cache (embedded
## bytes win over any cached file).
static func _write_assets(assets: Variant) -> void:
	if not (assets is Array) or (assets as Array).is_empty():
		return
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	if not dir.dir_exists("mods"):
		dir.make_dir("mods")
	var mods_dir := DirAccess.open(ModLoader.MODS_DIR)
	if mods_dir == null:
		return
	if not mods_dir.dir_exists("assets"):
		mods_dir.make_dir("assets")
	for a in (assets as Array):
		if not (a is Dictionary):
			continue
		var key := str((a as Dictionary).get("key", ""))
		var desc := str((a as Dictionary).get("description", ""))
		if key.is_empty():
			continue
		var path := VoxelAssetGenerator.ASSETS_DIR + key + ".json"
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"version": VoxelAssetGenerator.CACHE_VERSION,
				"description": desc, "key": key,
				"voxels": (a as Dictionary).get("voxels", [])}))
			f.close()


static func _ensure_mods_dir() -> void:
	var user_dir := DirAccess.open("user://")
	if user_dir == null:
		return
	if not user_dir.dir_exists("mods"):
		user_dir.make_dir("mods")


# --- Snapshot / rollback ---------------------------------------------------------

## Snapshots an installed mod's files for Replace rollback. Folder
## mods: every file in the folder. Single-file mods: the file +
## companion .json.
static func _snapshot_existing(existing_id: String, loaded: Dictionary) -> Dictionary:
	var snap := {"is_folder": bool(loaded.get("is_folder", false)),
		"folder": ModLoader.MODS_DIR.path_join(existing_id),
		"folder_files": {}, "single_path": "", "single_content": "",
		"has_single": false, "companion_path": "", "companion_content": "",
		"has_companion": false}
	if bool(loaded.get("is_folder", false)):
		var folder := str(loaded.get("path", ModLoader.MODS_DIR.path_join(existing_id)))
		snap["folder"] = folder
		var files := {}
		for f in DirAccess.get_files_at(folder):
			files[str(f)] = FileAccess.get_file_as_string(folder.path_join(str(f)))
		snap["folder_files"] = files
	else:
		var p := str(loaded.get("path", ""))
		snap["single_path"] = p
		if not p.is_empty() and FileAccess.file_exists(p):
			snap["single_content"] = FileAccess.get_file_as_string(p)
			snap["has_single"] = true
		var companion := p.get_basename() + ".json"
		snap["companion_path"] = companion
		if FileAccess.file_exists(companion):
			snap["companion_content"] = FileAccess.get_file_as_string(companion)
			snap["has_companion"] = true
	return snap


## Rolls an install back. Fresh: the folder is removed. Replace:
## original files are restored (a converted single-file mod's folder
## is removed and its single file + companion restored).
static func _rollback(target_id: String, snapshot: Variant) -> void:
	var folder := ModLoader.MODS_DIR.path_join(target_id)
	if snapshot == null:
		_remove_folder_all(folder)
		return
	var snap := snapshot as Dictionary
	if bool(snap.get("is_folder", false)):
		var snap_folder := str(snap.get("folder", folder))
		for f in DirAccess.get_files_at(snap_folder):
			_remove_file(snap_folder.path_join(str(f)))
		for fname in (snap.get("folder_files", {}) as Dictionary).keys():
			var f := FileAccess.open(snap_folder.path_join(str(fname)), FileAccess.WRITE)
			if f != null:
				f.store_string(str((snap.get("folder_files", {}) as Dictionary)[fname]))
				f.close()
	else:
		_remove_folder_all(folder)
		if bool(snap.get("has_single", false)):
			var f2 := FileAccess.open(str(snap.get("single_path", "")), FileAccess.WRITE)
			if f2 != null:
				f2.store_string(str(snap.get("single_content", "")))
				f2.close()
		if bool(snap.get("has_companion", false)):
			var f3 := FileAccess.open(str(snap.get("companion_path", "")), FileAccess.WRITE)
			if f3 != null:
				f3.store_string(str(snap.get("companion_content", "")))
				f3.close()


## Removes stale files after a verified Replace: snapshot files that
## are not among the newly written files (old payload filename, old
## hook files, other-kind payload), plus a converted single-file
## mod's old file + companion.
static func _remove_stale_files(target_id: String, snapshot: Dictionary, new_files: Array) -> void:
	if bool(snapshot.get("is_folder", false)):
		var folder := str(snapshot.get("folder", ModLoader.MODS_DIR.path_join(target_id)))
		for fname in (snapshot.get("folder_files", {}) as Dictionary).keys():
			if str(fname) not in new_files:
				_remove_file(folder.path_join(str(fname)))
	else:
		var sp := str(snapshot.get("single_path", ""))
		if not sp.is_empty() and FileAccess.file_exists(sp):
			_remove_file(sp)
		var cp := str(snapshot.get("companion_path", ""))
		if not cp.is_empty() and FileAccess.file_exists(cp):
			_remove_file(cp)


static func _remove_folder_all(folder: String) -> void:
	for f in DirAccess.get_files_at(folder):
		_remove_file(folder.path_join(str(f)))
	DirAccess.remove_absolute(_abs_path(folder))


static func _remove_file(user_path: String) -> void:
	DirAccess.remove_absolute(_abs_path(user_path))


static func _abs_path(user_path: String) -> String:
	if str(user_path).begins_with("user://"):
		return OS.get_user_data_dir().path_join(str(user_path).substr("user://".length()))
	return str(user_path)
