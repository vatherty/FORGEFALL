# verify_v07_mods.gd — headless checks for FORGEFALL v0.7 chunk 1,
# WORKER C (verification): user mods system (Worker A) + turret multipliers
# (Worker B) + Mods tab regression (Worker B's verifier, run separately).
# Usage: godot --headless --path <project> --script res://tools/verify_v07_mods.gd
#
# NOTE on test isolation: ModLoader hardcodes user://mods/ (no override),
# so fixtures MUST live there during the run. This verifier snapshots the
# real user://mods/ tree + user://mods_enabled.json to a backup dir,
# installs fixtures, and restores the snapshot in _cleanup() on EVERY exit
# path (pass or fail). It never leaves test mods behind.
#
# Asserts:
#   (1) Valid JSON block mod loads, registers, appears in the LLM catalog,
#       and Forge can build from it.
#   (2) Invalid JSON / bad schema -> mod disabled + error recorded, no
#       crash, not in catalog.
#   (3) Valid GDScript ModBlock mod loads, registers, callable via ModAPI.
#   (4) Broken script (syntax error / forbidden API) -> disabled + error,
#       no crash, not in catalog.
#   (5) Enable/disable toggle persists and removes/adds the mod from the
#       catalog.
#   (6) Turret ammo multipliers change live turret damage/range.
#   (7) Base catalog + prompt structure unchanged (stable SYSTEM_PROMPT
#       still first; user mods in their own section after it).
#   (8) REGRESSION TRAP: a JSON pickup block with "amount": 50 must LOAD
#       (Godot's JSON parser returns numbers as float; an int-strict range
#       check would wrongly reject it).
#   (9) Mods tab still present (forge_menu.gd has the Mods tab builder);
#       the full tab behaviour is covered by verify_v07_b_mods_turret.gd.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _passes := 0
var _frames := 0
var _phase := 0
var _arena: Node3D = null
var _turret: Node = null
var _foe: Node3D = null
var _cleaned_up := false
var _loader_script: GDScript = null
var _llm_script: GDScript = null
var _builder_script: GDScript = null
var _api_script: GDScript = null

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _had_mods := false
var _had_enabled := false

const WALL_ID := "v07verify_wall"
const CACHE_ID := "v07verify_cache"
const TURRET_ID := "v07verify_turret"
const BEACON_ID := "v07verify_beacon"
const BAD_ID := "v07verify_bad"
const MALFORMED_ID := "v07verify_malformed"
const BROKEN_ID := "v07verify_broken"
const FORBIDDEN_ID := "v07verify_forbidden"


class MockFoe extends Node3D:
	var dead := false
	var damage_taken := 0.0

	func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool) -> void:
		damage_taken += amount


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


## Calls `method` on a loaded script resource: static methods on the
## resource itself, instance methods on a fresh instance. (Class-name
## references like ForgeLLM.foo would force eager compilation of those
## scripts before autoloads register and fail; runtime load() + this
## helper is the pattern the other verifiers use.)
func _call_script(script: GDScript, method: String, args: Array) -> Variant:
	if script == null:
		return null
	var is_static := true
	var found := false
	for m in script.get_script_method_list():
		if str(m.get("name", "")) == method:
			found = true
			is_static = (int(m.get("flags", 0)) & 32) != 0
			break
	if not found:
		return null
	if is_static:
		return script.callv(method, args)
	var inst: Object = script.new()
	var result: Variant = inst.callv(method, args)
	if inst is Node:
		(inst as Node).free()
	return result


func _mod_by_id(mods: Array, mod_id: String) -> Dictionary:
	for m in mods:
		if m is Dictionary and str((m as Dictionary).get("id", "")) == mod_id:
			return m as Dictionary
	return {}


# --- Fixture staging (backup / install / restore) ---------------------------

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


func _write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _backup_and_stage() -> void:
	_user_dir = OS.get_user_data_dir()
	_mods_abs = _user_dir.path_join("mods")
	_backup_abs = _user_dir.path_join("_v07_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v07_verify_backup_enabled.json")
	# Drop any stale backup from a crashed earlier run.
	_wipe_contents(_backup_abs)
	DirAccess.remove_absolute(_backup_abs)
	if FileAccess.file_exists(_enabled_backup_abs):
		DirAccess.remove_absolute(_enabled_backup_abs)
	# Snapshot real state.
	_had_mods = DirAccess.dir_exists_absolute(_mods_abs)
	if _had_mods:
		_copy_recursive(_mods_abs, _backup_abs)
	_had_enabled = FileAccess.file_exists(_enabled_abs)
	if _had_enabled:
		_copy_file(_enabled_abs, _enabled_backup_abs)
	# Fresh fixture dir + fresh enabled state (all fixtures default on).
	DirAccess.make_dir_recursive_absolute(_mods_abs)
	_wipe_contents(_mods_abs)
	if FileAccess.file_exists(_enabled_abs):
		DirAccess.remove_absolute(_enabled_abs)
	_write_file(_mods_abs.path_join(WALL_ID + ".json"), JSON.stringify({
		"name": "Verify Wall", "kind": "block", "version": "1.0", "author": "verify",
		"block": {"block_id": WALL_ID, "target": "cover", "cost": 120,
			"display_name": "Verify Wall", "description": "A test wall.",
			"shape": "wall", "size_voxels": [3, 2, 1], "hp": 200},
	}))
	# (8) REGRESSION TRAP: "amount": 50 in JSON text. Godot's JSON parser
	# returns it as float 50.0; an int-strict check would reject this mod.
	_write_file(_mods_abs.path_join(CACHE_ID + ".json"), JSON.stringify({
		"name": "Verify Cache", "kind": "block", "version": "1.0", "author": "verify",
		"block": {"block_id": CACHE_ID, "target": "pickup", "cost": 30,
			"display_name": "Verify Cache", "kind": "ammo", "amount": 50},
	}))
	_write_file(_mods_abs.path_join(TURRET_ID + ".json"), JSON.stringify({
		"name": "Verify Turret", "kind": "block", "version": "1.0", "author": "verify",
		"block": {"block_id": TURRET_ID, "target": "turret", "cost": 200,
			"display_name": "Verify Turret", "duration_sec": 60,
			"damage_mult": 2.0, "range_mult": 1.0},
	}))
	# (2) Bad schema: unknown field "jetpack" must be rejected.
	_write_file(_mods_abs.path_join(BAD_ID + ".json"), JSON.stringify({
		"name": "Bad Mod", "kind": "block", "version": "1.0", "author": "verify",
		"block": {"block_id": BAD_ID, "target": "cover", "cost": 100,
			"display_name": "Bad", "shape": "wall", "size_voxels": [2, 2, 1],
			"hp": 100, "jetpack": true},
	}))
	# (2) Malformed JSON: not parseable at all.
	_write_file(_mods_abs.path_join(MALFORMED_ID + ".json"), "{ this is not json")
	# (3) Valid script mod: ModBlock, ModAPI-only.
	_write_file(_mods_abs.path_join(BEACON_ID + ".gd"),
		"extends ModBlock\n" +
		"\n" +
		"func get_block_info() -> Dictionary:\n" +
		"\treturn {\"block_id\": \"" + BEACON_ID + "\", \"target\": \"cover\", \"cost\": 100, \"display_name\": \"Verify Beacon\", \"description\": \"A script-built marker.\", \"shape\": \"wall\", \"size_voxels\": [2, 2, 1], \"hp\": 100.0}\n" +
		"\n" +
		"func apply(api: ModAPI, params: Dictionary) -> String:\n" +
		"\tvar at: Vector3 = params.get(\"_position\", Vector3.ZERO)\n" +
		"\tvar node: Node3D = api.spawn_voxel_box(Vector3(1, 1, 1), Color(1, 0.5, 0), at, false)\n" +
		"\tif node == null:\n" +
		"\t\treturn \"\"\n" +
		"\treturn \"Forge fabricated: Verify Beacon (mod).\"\n")
	# (4) Broken script: syntax error.
	_write_file(_mods_abs.path_join(BROKEN_ID + ".gd"),
		"extends ModBlock\n" +
		"func get_block_info() -> Dictionary:\n" +
		"\treturn { broken\n")
	# (4) Forbidden API: OS.execute must be caught by the text scan.
	_write_file(_mods_abs.path_join(FORBIDDEN_ID + ".gd"),
		"extends ModBlock\n" +
		"\n" +
		"func get_block_info() -> Dictionary:\n" +
		"\treturn {\"block_id\": \"" + FORBIDDEN_ID + "\", \"target\": \"cover\", \"cost\": 100, \"display_name\": \"Forbidden\", \"shape\": \"wall\", \"size_voxels\": [2, 2, 1], \"hp\": 100.0}\n" +
		"\n" +
		"func apply(api: ModAPI, params: Dictionary) -> String:\n" +
		"\tOS.execute(\"echo\", [])\n" +
		"\treturn \"should never run\"\n")


func _cleanup() -> void:
	if _cleaned_up:
		return
	_cleaned_up = true
	if _mods_abs.is_empty():
		return
	# Remove fixtures, restore the real snapshot (or leave no mods behind).
	_wipe_contents(_mods_abs)
	if _had_mods:
		_copy_recursive(_backup_abs, _mods_abs)
		_wipe_contents(_backup_abs)
		DirAccess.remove_absolute(_backup_abs)
	else:
		DirAccess.remove_absolute(_mods_abs)
	if FileAccess.file_exists(_enabled_abs):
		DirAccess.remove_absolute(_enabled_abs)
	if _had_enabled:
		_copy_file(_enabled_backup_abs, _enabled_abs)
		DirAccess.remove_absolute(_enabled_backup_abs)


# --- Main flow ---------------------------------------------------------------

func _initialize() -> void:
	_backup_and_stage()
	_loader_script = load("res://scripts/mods/mod_loader.gd") as GDScript
	_llm_script = load("res://scripts/forge/forge_llm.gd") as GDScript
	_builder_script = load("res://scripts/forge/forge_builder.gd") as GDScript
	_api_script = load("res://scripts/mods/mod_api.gd") as GDScript
	_check(_loader_script != null, "v07mods: mod_loader.gd loads (no parse errors)")
	_check(_llm_script != null, "v07mods: forge_llm.gd loads (no parse errors)")
	_check(_builder_script != null, "v07mods: forge_builder.gd loads (no parse errors)")
	_check(_api_script != null, "v07mods: mod_api.gd loads (no parse errors)")
	if _loader_script == null or _llm_script == null or _builder_script == null or _api_script == null:
		_finish()
		return
	_arena = Node3D.new()
	_arena.name = "V07VerifyArena"
	root.add_child(_arena)
	_call_script(_loader_script, "scan_mods", [])
	_check_static()
	_phase = 1
	_frames = 0
	print("VERIFY_V07_MODS: fixtures staged, static checks done")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 2:
				return false
			_check_builds()
			_phase = 2
			_frames = 0
			return false
		2:
			if _frames < 15:
				return false
			_check_turret_live()
			_finish()
			return true
	return false


func _finish() -> void:
	_cleanup()
	if _fails == 0:
		print("VERIFY_V07_MODS: ALL CHECKS PASSED (%d checks)" % _passes)
	else:
		printerr("VERIFY_V07_MODS: %d CHECK(S) FAILED (%d passed)" % [_fails, _passes])
	quit(_fails)


# --- Static checks: loader, catalog, gate, toggle, prompt structure ---------

func _check_static() -> void:
	var mods: Variant = _call_script(_loader_script, "get_mods", [])
	_check(mods.size() == 8, "v07mods: get_mods() lists all 8 fixtures (got %d)" % mods.size())
	# (1) Valid JSON block mod: loads, registers, error-free, enabled.
	var wall := _mod_by_id(mods, WALL_ID)
	_check(not wall.is_empty(), "v07mods(1): valid JSON mod '%s' registered" % WALL_ID)
	_check(str(wall.get("error", "?")) == "", "v07mods(1): valid JSON mod has no error (got '%s')" % str(wall.get("error", "?")))
	_check(bool(wall.get("enabled", false)), "v07mods(1): valid JSON mod defaults to enabled")
	_check(str(wall.get("kind", "")) == "block", "v07mods(1): valid JSON mod kind is 'block'")
	# (3) Valid script mod: loads, registers, error-free, enabled.
	var beacon := _mod_by_id(mods, BEACON_ID)
	_check(not beacon.is_empty(), "v07mods(3): valid script mod '%s' registered" % BEACON_ID)
	_check(str(beacon.get("error", "?")) == "", "v07mods(3): valid script mod has no error (got '%s')" % str(beacon.get("error", "?")))
	_check(bool(beacon.get("enabled", false)), "v07mods(3): valid script mod defaults to enabled")
	_check(str(beacon.get("kind", "")) == "script", "v07mods(3): valid script mod kind is 'script'")
	# (8) Pickup trap: amount 50 (JSON float 50.0) must LOAD.
	var cache := _mod_by_id(mods, CACHE_ID)
	_check(not cache.is_empty(), "v07mods(8): pickup mod '%s' registered" % CACHE_ID)
	_check(str(cache.get("error", "?")) == "", "v07mods(8): pickup mod with amount 50 loads (error '%s')" % str(cache.get("error", "?")))
	var cache_rec: Variant = _call_script(_loader_script, "find_mod", [CACHE_ID])
	var cache_info: Dictionary = cache_rec.get("block_info", {})
	_check(is_equal_approx(float(cache_info.get("amount", -1)), 50.0),
		"v07mods(8): pickup block_info amount == 50 (got %s)" % str(cache_info.get("amount", null)))
	# (2) Invalid JSON / bad schema: disabled + error, no crash.
	for bad_id in [BAD_ID, MALFORMED_ID]:
		var bad := _mod_by_id(mods, bad_id)
		_check(not bad.is_empty(), "v07mods(2): broken JSON mod '%s' still listed (not crashed away)" % bad_id)
		_check(str(bad.get("error", "")) != "", "v07mods(2): broken JSON mod '%s' has an error recorded (got '%s')" % [bad_id, str(bad.get("error", ""))])
	# (4) Broken scripts: disabled + error, no crash.
	for bad_id in [BROKEN_ID, FORBIDDEN_ID]:
		var bad := _mod_by_id(mods, bad_id)
		_check(not bad.is_empty(), "v07mods(4): broken script mod '%s' still listed (not crashed away)" % bad_id)
		_check(str(bad.get("error", "")) != "", "v07mods(4): broken script mod '%s' has an error recorded (got '%s')" % [bad_id, str(bad.get("error", ""))])
	_check(str(_mod_by_id(mods, FORBIDDEN_ID).get("error", "")).contains("forbidden"),
		"v07mods(4): forbidden-API mod error names the forbidden API (got '%s')" % str(_mod_by_id(mods, FORBIDDEN_ID).get("error", "")))
	# Enabled view: exactly the 4 good mods.
	var enabled: Variant = _call_script(_loader_script, "get_enabled_mods", [])
	_check(enabled.size() == 4, "v07mods: get_enabled_mods() has exactly the 4 good mods (got %d)" % enabled.size())
	for good_id in [WALL_ID, CACHE_ID, TURRET_ID, BEACON_ID]:
		_check(not _mod_by_id(enabled, good_id).is_empty(), "v07mods: enabled list contains '%s'" % good_id)
	for bad_id in [BAD_ID, MALFORMED_ID, BROKEN_ID, FORBIDDEN_ID]:
		_check(_mod_by_id(enabled, bad_id).is_empty(), "v07mods: enabled list excludes broken '%s'" % bad_id)
	# find_mod resolves both mod ids and block_ids.
	_check(not _call_script(_loader_script, "find_mod", [WALL_ID]).is_empty(), "v07mods: find_mod() resolves mod id '%s'" % WALL_ID)
	_check(not _call_script(_loader_script, "find_mod", [CACHE_ID]).is_empty(), "v07mods: find_mod() resolves mod id '%s'" % CACHE_ID)
	_check(str(_call_script(_loader_script, "find_mod", [CACHE_ID]).get("id", "")) == CACHE_ID, "v07mods: find_mod() by block_id maps back to mod '%s'" % CACHE_ID)
	# (1) Catalog: good mods appear, broken mods never do.
	var section: Variant = _call_script(_llm_script, "user_mods_section", [])
	for good_id in [WALL_ID, CACHE_ID, TURRET_ID, BEACON_ID]:
		_check(section.contains(good_id), "v07mods(1): catalog section lists '%s'" % good_id)
	for bad_id in [BAD_ID, MALFORMED_ID, BROKEN_ID, FORBIDDEN_ID]:
		_check(not section.contains(bad_id), "v07mods(2/4): catalog section excludes broken '%s'" % bad_id)
	# Gate: valid mod_block spec accepted with recomputed cost; unknown rejected.
	var good_spec := {"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"mod_block": WALL_ID, "position": [10, 0, 10]}, "cost": 0, "ttl": 0}
	var verdict: Variant = _call_script(_llm_script, "validate_modspec", [good_spec])
	_check(bool(verdict[0]), "v07mods(1): gate accepts valid mod_block spec (%s)" % str(verdict[1]))
	_check(int(good_spec.get("cost", -1)) == 120, "v07mods(1): gate recomputes mod_block cost to declared 120 (got %s)" % str(good_spec.get("cost", null)))
	var unknown_spec := {"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"mod_block": "no_such_mod", "position": [10, 0, 10]}, "cost": 0, "ttl": 0}
	_check(not bool(_call_script(_llm_script, "validate_modspec", [unknown_spec])[0]), "v07mods: gate rejects unknown mod_block")
	# (5) Toggle persists and removes/adds the mod from the catalog.
	_call_script(_loader_script, "set_mod_enabled", [WALL_ID, false])
	_check(_mod_by_id(_call_script(_loader_script, "get_enabled_mods", []), WALL_ID).is_empty(),
		"v07mods(5): disabling '%s' removes it from enabled list" % WALL_ID)
	_check(not _call_script(_llm_script, "user_mods_section", []).contains(WALL_ID),
		"v07mods(5): disabling '%s' removes it from the catalog" % WALL_ID)
	_check(FileAccess.get_file_as_string(_enabled_abs).contains("\"" + WALL_ID + "\":false"),
		"v07mods(5): disabled state persisted to mods_enabled.json")
	_call_script(_loader_script, "scan_mods", [])
	_check(_mod_by_id(_call_script(_loader_script, "get_mods", []), WALL_ID).get("enabled", true) == false,
		"v07mods(5): disabled state survives a rescan (persisted, not in-memory only)")
	_call_script(_loader_script, "set_mod_enabled", [WALL_ID, true])
	_check(not _mod_by_id(_call_script(_loader_script, "get_enabled_mods", []), WALL_ID).is_empty(),
		"v07mods(5): re-enabling '%s' restores it to enabled list" % WALL_ID)
	_check(_call_script(_llm_script, "user_mods_section", []).contains(WALL_ID),
		"v07mods(5): re-enabling '%s' restores it to the catalog" % WALL_ID)
	# (7) Base catalog + prompt structure.
	_check(_llm_script.SYSTEM_PROMPT.begins_with("You are the FORGE"),
		"v07mods(7): SYSTEM_PROMPT still starts with the stable base prompt")
	_check(_llm_script.SYSTEM_PROMPT.contains("REFUSAL") and _llm_script.SYSTEM_PROMPT.contains("COMPOSITION"),
		"v07mods(7): SYSTEM_PROMPT still carries REFUSAL + COMPOSITION blocks")
	_check(not _llm_script.SYSTEM_PROMPT.contains("USER MODS") and not _llm_script.SYSTEM_PROMPT.contains(WALL_ID),
		"v07mods(7): base SYSTEM_PROMPT has no user-mods content baked in (stays cache-stable)")
	var llm_src := FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	var base_pos := llm_src.find("{\"role\": \"system\", \"content\": SYSTEM_PROMPT}")
	var mods_pos := llm_src.find("{\"role\": \"system\", \"content\": user_mods_section()}")
	_check(base_pos >= 0 and mods_pos > base_pos,
		"v07mods(7): request messages send SYSTEM_PROMPT first, user-mods section second (base=%d mods=%d)" % [base_pos, mods_pos])
	_check(llm_src.contains("USER MODS: none installed."),
		"v07mods(7): empty-mods section is a fixed one-liner (stable when no mods)")
	_check(section.strip_edges().begins_with("USER MODS"),
		"v07mods(7): user mods live in their own section after the base prompt")
	# (9) Mods tab still present (full behaviour: verify_v07_b_mods_turret.gd).
	var menu_src := FileAccess.get_file_as_string("res://scripts/ui/forge_menu.gd")
	_check(menu_src.contains("_build_mods_tab") and menu_src.contains("\"Mods\""),
		"v07mods(9): forge_menu.gd still builds the Mods tab")


# --- Build checks: Forge can build from mods --------------------------------

func _check_builds() -> void:
	var ctx := {"player": null, "root": _arena}
	# (1) JSON cover mod builds.
	var wall_msg: String = _call_script(_builder_script, "build", [
		{"spec_version": 1, "action": "spawn", "target": "cover",
			"params": {"mod_block": WALL_ID, "position": [10, 0, 10]}, "cost": 120, "ttl": 0}, ctx])
	_check(wall_msg is String and not wall_msg.is_empty() and not wall_msg.begins_with(_builder_script.FAIL_PREFIX),
		"v07mods(1): Forge builds from JSON mod '%s' (%s)" % [WALL_ID, wall_msg])
	_check(_builder_script.last_built_valid, "v07mods(1): JSON mod build registered a live node")
	# (3) Script mod builds via ModAPI (direct apply + Forge path).
	var beacon_rec: Variant = _call_script(_loader_script, "find_mod", [BEACON_ID])
	var inst: Variant = _call_script(_loader_script, "instantiate_script_mod", [beacon_rec])
	_check(inst != null and inst.has_method("apply") and inst.has_method("get_block_info"), "v07mods(3): script mod instantiates as a ModBlock")
	if inst != null:
		var api: Variant = _api_script.new(null, _arena)
		var direct := str(inst.call("apply", api, {"_position": Vector3(20, 0, 10), "_target": "cover"}))
		_check(not direct.is_empty(), "v07mods(3): script mod apply() via ModAPI returns success ('%s')" % direct)
		_check(api.last_spawned != null and is_instance_valid(api.last_spawned),
			"v07mods(3): script mod apply() spawned a node via ModAPI")
	var beacon_msg: String = _call_script(_builder_script, "build", [
		{"spec_version": 1, "action": "spawn", "target": "cover",
			"params": {"mod_block": BEACON_ID, "position": [24, 0, 10]}, "cost": 100, "ttl": 0}, ctx])
	_check(beacon_msg is String and not beacon_msg.is_empty() and not beacon_msg.begins_with(_builder_script.FAIL_PREFIX) and beacon_msg.contains("Verify Beacon"),
		"v07mods(3): Forge builds from script mod '%s' (%s)" % [BEACON_ID, beacon_msg])
	# (8) Pickup trap: Forge builds the amount-50 pickup; amount lands as 50.
	var cache_msg: String = _call_script(_builder_script, "build", [
		{"spec_version": 1, "action": "spawn", "target": "pickup",
			"params": {"mod_block": CACHE_ID, "position": [30, 0, 10]}, "cost": 30, "ttl": 0}, ctx])
	_check(cache_msg is String and not cache_msg.is_empty() and not cache_msg.begins_with(_builder_script.FAIL_PREFIX),
		"v07mods(8): Forge builds pickup mod '%s' (%s)" % [CACHE_ID, cache_msg])
	var pickup_node: Variant = _builder_script.last_built_node
	_check(pickup_node != null and is_instance_valid(pickup_node) and int(pickup_node.get("amount")) == 50,
		"v07mods(8): built pickup amount == 50 (got %s)" % str(pickup_node.get("amount") if pickup_node != null else null))
	# (6) Turret mod builds; multipliers land as metadata.
	var turret_msg: String = _call_script(_builder_script, "build", [
		{"spec_version": 1, "action": "spawn", "target": "turret",
			"params": {"mod_block": TURRET_ID, "position": [0, 0, 40]}, "cost": 200, "ttl": 0}, ctx])
	_check(turret_msg is String and not turret_msg.is_empty() and not turret_msg.begins_with(_builder_script.FAIL_PREFIX),
		"v07mods(6): Forge builds turret mod '%s' (%s)" % [TURRET_ID, turret_msg])
	_turret = _builder_script.last_built_node
	_check(_turret != null and is_instance_valid(_turret), "v07mods(6): turret mod build registered a live node")
	if _turret != null:
		_check(is_equal_approx(float(_turret.get_meta("damage_mult", -1)), 2.0),
			"v07mods(6): turret mod damage_mult metadata == 2.0 (got %s)" % str(_turret.get_meta("damage_mult", null)))
		_check(is_equal_approx(float(_turret.get_meta("range_mult", -1)), 1.0),
			"v07mods(6): turret mod range_mult metadata == 1.0 (got %s)" % str(_turret.get_meta("range_mult", null)))
		_foe = MockFoe.new()
		_foe.name = "V07VerifyFoe"
		_foe.position = Vector3(10, 0, 40)
		_foe.add_to_group("enemy")
		_arena.add_child(_foe)
	# Disabled / unknown mod_block builds fail gracefully, never crash.
	_call_script(_loader_script, "set_mod_enabled", [WALL_ID, false])
	var disabled_msg: String = _call_script(_builder_script, "build", [
		{"spec_version": 1, "action": "spawn", "target": "cover",
			"params": {"mod_block": WALL_ID, "position": [10, 0, 10]}, "cost": 120, "ttl": 0}, ctx])
	_check(disabled_msg is String and disabled_msg.begins_with(_builder_script.FAIL_PREFIX),
		"v07mods(5): building from a disabled mod fails gracefully (%s)" % disabled_msg)
	_call_script(_loader_script, "set_mod_enabled", [WALL_ID, true])
	var unknown_msg: String = _call_script(_builder_script, "build", [
		{"spec_version": 1, "action": "spawn", "target": "cover",
			"params": {"mod_block": "no_such_mod", "position": [10, 0, 10]}, "cost": 0, "ttl": 0}, ctx])
	_check(unknown_msg is String and unknown_msg.begins_with(_builder_script.FAIL_PREFIX),
		"v07mods: building from an unknown mod_block fails gracefully (%s)" % unknown_msg)


# --- Live turret check (needs frames: acquire re-reads the multipliers) ------

func _check_turret_live() -> void:
	if _turret == null or not is_instance_valid(_turret):
		_check(false, "v07mods(6): turret node survived to live check")
		return
	_check(is_equal_approx(float(_turret.get("_damage_mult")), 2.0),
		"v07mods(6): live turret _damage_mult == 2.0 after acquire re-read (got %s)" % str(_turret.get("_damage_mult")))
	_check(is_equal_approx(float(_turret.call("get_damage")), 30.0),
		"v07mods(6): live turret get_damage() == 30.0 (15 x 2.0, got %s)" % str(_turret.call("get_damage")))
	_check(is_equal_approx(float(_turret.call("get_range")), 30.0),
		"v07mods(6): live turret get_range() == 30.0 (30 x 1.0, got %s)" % str(_turret.call("get_range")))
	if _foe != null and is_instance_valid(_foe):
		var taken := float((_foe as MockFoe).damage_taken)
		_check(taken >= 30.0 - 0.001,
			"v07mods(6): foe in range took >= 30.0 damage from mod turret (got %.1f)" % taken)
		_check(is_equal_approx(taken / 30.0, roundf(taken / 30.0)) and taken >= 30.0,
			"v07mods(6): foe damage is a whole number of 30.0 hits (%.1f total)" % taken)
	else:
		_check(false, "v07mods(6): foe survived to live check")
