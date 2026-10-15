# verify_v08_a_creator.gd — headless checks for FORGEFALL v0.8 chunk 2,
# WORKER A (generation): ForgeLLM generation template + request,
# ModCreator (generate / validate / install), ModLoader.validate_generated_mod.
# Usage: godot --headless --path <project> --script res://tools/verify_v08_a_creator.gd
#
# Same isolation pattern as verify_v07_mods.gd: snapshots the real
# user://mods/ tree + user://mods_enabled.json, stages an empty mods dir,
# restores the snapshot in _cleanup() on EVERY exit path. Never leaves
# test mods behind. Never calls the real DeepSeek API (mock_generation
# for ModCreator; the no-key path is tested only when no key is stored).
#
# Asserts:
#   (0) Static: GENERATION_SYSTEM_PROMPT carries the full ModAPI list,
#       the ModBlock contract, the manifest schema, both few-shot
#       examples, the never-emit-code rule — with the script example's
#       payload correctly JSON-escaped (no raw newlines inside it).
#       SYSTEM_PROMPT / spec_ready / request_spec untouched.
#   (1) Mocked valid block generation -> candidate (exact shape, error ""),
#       block_id normalized to mod_id, generation alone writes NOTHING,
#       validate "" , install "" , installed mod error-free + in catalog.
#   (2) Installing the same candidate again -> collision suffix _2.
#   (3) Mocked valid script generation -> candidate, install, error-free.
#   (4) Bad block (unknown field) -> candidate error, install refuses,
#       nothing written.
#   (5) Forbidden-API script -> candidate error names "forbidden",
#       install refuses, nothing written.
#   (6) Script without `extends ModBlock` -> candidate error, no write.
#   (7) Generation {error: ...} -> candidate carries the error, install
#       refuses with it.
#   (8) Garbage generation (no manifest) -> candidate error.
#   (9) Empty idea -> error candidate, no network.
#  (10) validate() shape checks: bad mod_id, error-field passthrough,
#       kind mismatch, >300-char summary.
#  (11) No-key path (only when no key is stored): ForgeLLM emits the
#       exact NO_KEY_ERROR, ModCreator surfaces it as a candidate error.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _passes := 0
var _frames := 0
var _phase := 1
var _issued := false
var _cleaned_up := false

var _loader_script: GDScript = null
var _llm_script: GDScript = null
var _creator_script: GDScript = null
var _config_script: GDScript = null
var _creator: Object = null
var _creator2: Object = null
var _llm: Object = null

var _last_candidate: Dictionary = {}
var _got_candidate := false
var _last_llm_result: Dictionary = {}
var _got_llm := false
var _saved_candidate: Dictionary = {}
var _no_key := false

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _had_mods := false
var _had_enabled := false

const NO_KEY_EXPECTED := "DeepSeek key required — add it in the Forge menu"


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


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


# --- Fixture staging (backup / restore) --------------------------------------

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


func _backup_and_stage() -> void:
	_user_dir = OS.get_user_data_dir()
	_mods_abs = _user_dir.path_join("mods")
	_backup_abs = _user_dir.path_join("_v08_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v08_verify_backup_enabled.json")
	_wipe_contents(_backup_abs)
	DirAccess.remove_absolute(_backup_abs)
	if FileAccess.file_exists(_enabled_backup_abs):
		DirAccess.remove_absolute(_enabled_backup_abs)
	_had_mods = DirAccess.dir_exists_absolute(_mods_abs)
	if _had_mods:
		_copy_recursive(_mods_abs, _backup_abs)
	_had_enabled = FileAccess.file_exists(_enabled_abs)
	if _had_enabled:
		_copy_file(_enabled_abs, _enabled_backup_abs)
	DirAccess.make_dir_recursive_absolute(_mods_abs)
	_wipe_contents(_mods_abs)
	if FileAccess.file_exists(_enabled_abs):
		DirAccess.remove_absolute(_enabled_abs)


func _cleanup() -> void:
	if _cleaned_up:
		return
	_cleaned_up = true
	if _mods_abs.is_empty():
		return
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
	# Leave no mock behind for any other test in this process.
	if _creator_script != null:
		_creator_script.set("mock_generation", {})


# --- Main flow ---------------------------------------------------------------

func _initialize() -> void:
	_backup_and_stage()
	_loader_script = load("res://scripts/mods/mod_loader.gd") as GDScript
	_llm_script = load("res://scripts/forge/forge_llm.gd") as GDScript
	_creator_script = load("res://scripts/mods/mod_creator.gd") as GDScript
	_config_script = load("res://scripts/forge/forge_config.gd") as GDScript
	_check(_loader_script != null, "v08a: mod_loader.gd loads (no parse errors)")
	_check(_llm_script != null, "v08a: forge_llm.gd loads (no parse errors)")
	_check(_creator_script != null, "v08a: mod_creator.gd loads (no parse errors)")
	_check(_config_script != null, "v08a: forge_config.gd loads (no parse errors)")
	if _loader_script == null or _llm_script == null or _creator_script == null or _config_script == null:
		_finish()
		return
	_creator = _creator_script.new()
	_creator.connect("generation_ready", Callable(self, "_on_candidate"))
	_no_key = str(_call_script(_config_script, "load_key", [])).is_empty()
	if not _no_key:
		print("VERIFY_V08_A_CREATOR: NOTE: a DeepSeek key is stored; no-key phase will SKIP (no network is ever called)")
	_run_static()
	_phase = 1
	_frames = 0
	print("VERIFY_V08_A_CREATOR: static checks done, async phases start")


func _process(_delta: float) -> bool:
	if _phase > 11:
		_finish()
		return true
	_frames += 1
	if not _issued:
		_issue_phase(_phase)
		_issued = true
		_frames = 0
		return false
	if _frames < 3:
		return false
	_check_phase(_phase)
	_phase += 1
	_issued = false
	_frames = 0
	return false


func _finish() -> void:
	_cleanup()
	if _fails == 0:
		print("VERIFY_V08_A_CREATOR: ALL CHECKS PASSED (%d checks)" % _passes)
	else:
		printerr("VERIFY_V08_A_CREATOR: %d CHECK(S) FAILED (%d passed)" % [_fails, _passes])
	quit(_fails)


func _on_candidate(cand: Dictionary) -> void:
	_last_candidate = cand
	_got_candidate = true


func _on_llm_result(res: Dictionary) -> void:
	_last_llm_result = res
	_got_llm = true


func _set_mock(mock: Dictionary) -> bool:
	_creator_script.set("mock_generation", mock)
	var back: Variant = _creator_script.get("mock_generation")
	if back is Dictionary and (back as Dictionary).size() == mock.size():
		return true
	_creator.set("mock_generation", mock)
	back = _creator.get("mock_generation")
	if back is Dictionary and (back as Dictionary).size() == mock.size():
		return true
	return false


# --- Static checks -------------------------------------------------------------

func _run_static() -> void:
	var methods: Array = []
	for m in _creator_script.get_script_method_list():
		methods.append(str(m.get("name", "")))
	for mname in ["generate", "validate", "install"]:
		_check(mname in methods, "v08a(0): ModCreator exposes instance method '%s'" % mname)
	var creator_src := FileAccess.get_file_as_string("res://scripts/mods/mod_creator.gd")
	_check(creator_src.contains("static var mock_generation"), "v08a(0): ModCreator has static var mock_generation test seam")
	var prompt: String = _llm_script.GENERATION_SYSTEM_PROMPT
	for api_fn in ["get_player()", "get_root()", "get_player_position()", "get_aim_point()",
			"spawn_voxel_box(", "spawn_cover(", "spawn_pickup(", "spawn_turret(",
			"give_weapon(", "fire_effect(", "announce("]:
		_check(prompt.contains(api_fn), "v08a(0): generation prompt documents ModAPI '%s'" % api_fn)
	_check(prompt.contains("extends ModBlock"), "v08a(0): generation prompt states the ModBlock contract (extends ModBlock)")
	_check(prompt.contains("get_block_info()") and prompt.contains("apply(api: ModAPI"), "v08a(0): generation prompt requires get_block_info() + apply(api, params)")
	_check(prompt.contains("MANIFEST SCHEMA") and prompt.contains("\"kind\""), "v08a(0): generation prompt carries the manifest schema")
	_check(prompt.contains("BLOCK SCHEMA"), "v08a(0): generation prompt carries the block schema")
	_check(prompt.contains("Chunky Wall") and prompt.contains("Aim Beacon"), "v08a(0): generation prompt has both few-shot examples (block + script)")
	_check(prompt.contains("NEVER emit") and prompt.contains("FileAccess"), "v08a(0): generation prompt forbids filesystem/network/OS/eval code")
	_check(prompt.contains("\"summary\"") and prompt.contains("max 300 chars"), "v08a(0): generation prompt pins the summary contract (max 300 chars)")
	# Escaping: the script example's payload must be ONE JSON string —
	# no raw newlines inside it, backslash escapes intact.
	var payload_start := prompt.find("\"payload\": \"extends ModBlock")
	_check(payload_start >= 0, "v08a(0): generation prompt script example has a string payload")
	if payload_start >= 0:
		var summary_pos := prompt.find("\", \"summary\"", payload_start)
		_check(summary_pos > payload_start, "v08a(0): generation prompt script example payload is terminated by the summary field")
		if summary_pos > payload_start:
			var seg := prompt.substr(payload_start, summary_pos - payload_start)
			_check(not seg.contains("\n"), "v08a(0): script example payload has no raw newline (all newlines JSON-escaped)")
			_check(seg.contains("\\\""), "v08a(0): script example payload escapes its quotes (\\\")")
			_check(seg.contains("\\n"), "v08a(0): script example payload escapes its newlines (\\n)")
			# The example itself must be extractable: wrap it as a full
			# generation object and parse it.
			var obj_start := prompt.rfind("Player idea:", payload_start)
			var example_json := prompt.substr(obj_start, summary_pos - obj_start)
			example_json = example_json.substr(example_json.find("->") + 2).strip_edges()
			example_json += "\", \"summary\": \"x\"}"
			var parsed: Variant = JSON.parse_string(example_json)
			_check(parsed is Dictionary and (parsed as Dictionary).has("manifest") and (parsed as Dictionary).has("payload"),
				"v08a(0): script few-shot example parses as a generation object (payload is one JSON string)")
	_check(int(_llm_script.GENERATION_MAX_TOKENS) == 2000, "v08a(0): generation uses max_tokens 2000, not the 400-token build budget (got %s)" % str(_llm_script.GENERATION_MAX_TOKENS))
	# Build path untouched.
	_check(str(_llm_script.SYSTEM_PROMPT).begins_with("You are the FORGE"), "v08a(0): SYSTEM_PROMPT still starts with the stable base prompt")
	_check(str(_llm_script.SYSTEM_PROMPT).contains("REFUSAL") and str(_llm_script.SYSTEM_PROMPT).contains("COMPOSITION"),
		"v08a(0): SYSTEM_PROMPT still carries REFUSAL + COMPOSITION")
	_check(not str(_llm_script.SYSTEM_PROMPT).contains("ModAPI"), "v08a(0): SYSTEM_PROMPT has no generation content baked in (stays cache-stable)")
	var llm_src := FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	_check(llm_src.contains("signal generation_ready"), "v08a(0): ForgeLLM has its own generation_ready signal")
	_check(llm_src.contains("func request_generation"), "v08a(0): ForgeLLM has a separate request_generation path")
	_check(llm_src.contains("signal spec_ready") and llm_src.contains("func request_spec"), "v08a(0): ForgeLLM still has the untouched spec_ready / request_spec build path")
	_check(llm_src.contains("GENERATION_SYSTEM_PROMPT") and llm_src.contains("GENERATION_MAX_TOKENS"),
		"v08a(0): ForgeLLM generation path uses its own template + token budget")
	_check(_creator_script.NO_KEY_ERROR == NO_KEY_EXPECTED, "v08a(0): NO_KEY_ERROR is the exact contract string")
	var loader_src := FileAccess.get_file_as_string("res://scripts/mods/mod_loader.gd")
	_check(loader_src.contains("func validate_generated_mod"), "v08a(0): ModLoader has the additive validate_generated_mod wrapper")
	# Direct wrapper checks (no filesystem, no scan state).
	var good_block := JSON.stringify({"block_id": "direct_check", "target": "cover", "cost": 100,
		"display_name": "Direct", "shape": "wall", "size_voxels": [2, 2, 1], "hp": 100})
	_check(str(_call_script(_loader_script, "validate_generated_mod",
		[{"name": "Direct", "kind": "block", "version": "1.0"}, good_block])) == "",
		"v08a(0): validate_generated_mod accepts a valid block")
	_check(str(_call_script(_loader_script, "validate_generated_mod",
		[{"name": "X", "kind": "block", "bogus": 1}, good_block])).contains("unknown manifest field"),
		"v08a(0): validate_generated_mod rejects an unknown manifest field")
	_check(str(_call_script(_loader_script, "validate_generated_mod",
		[{"name": "X", "kind": "script"}, "extends ModBlock\nfunc get_block_info() -> Dictionary:\n\treturn {}\nfunc apply(api, params):\n\tOS.execute(\"echo\", [])\n"])).contains("forbidden"),
		"v08a(0): validate_generated_mod rejects a forbidden-API script")


# --- Async phases ---------------------------------------------------------------

func _block_payload(block_id: String, extra: Dictionary = {}) -> String:
	var b := {"block_id": block_id, "target": "cover", "cost": 150,
		"display_name": "Chunky Wall", "description": "A thick concrete wall.",
		"shape": "wall", "size_voxels": [8, 6, 3], "hp": 500}
	for k in extra.keys():
		b[k] = extra[k]
	return JSON.stringify(b)


func _script_payload(body: String = "") -> String:
	var src := "extends ModBlock\n" + "\n" + "func get_block_info() -> Dictionary:\n"
	src += "\treturn {\"block_id\": \"aim_beacon\", \"target\": \"cover\", \"cost\": 100, \"display_name\": \"Aim Beacon\", \"description\": \"Drops a glowing marker.\", \"shape\": \"wall\", \"size_voxels\": [1, 1, 1], \"hp\": 100.0}\n"
	src += "\n" + "func apply(api: ModAPI, params: Dictionary) -> String:\n"
	if body.is_empty():
		src += "\tvar at: Vector3 = params.get(\"_position\", Vector3.ZERO)\n"
		src += "\tvar node: Node3D = api.spawn_voxel_box(Vector3(1, 1, 1), Color(1, 0.8, 0), at, false)\n"
		src += "\tif node == null:\n\t\treturn \"\"\n"
		src += "\treturn \"Forge fabricated: Aim Beacon (mod).\"\n"
	else:
		src += body
	return src


func _issue_phase(phase: int) -> void:
	_got_candidate = false
	_got_llm = false
	_last_candidate = {}
	_last_llm_result = {}
	match phase:
		1:
			_check(_set_mock({"manifest": {"name": "Chunky Wall", "kind": "block", "version": "1.0", "description": "A thick concrete wall."},
				"payload": _block_payload("stale_id"), "summary": "A thick concrete wall with 500 HP for 150."}),
				"v08a(1): mock_generation set for block generation")
			_creator.callv("generate", ["a chunky concrete wall"])
		2:
			# No generation needed: the check reinstalls the phase-1
			# candidate to exercise collision suffixing. Clear the mock
			# so nothing stale leaks into later phases.
			_creator_script.set("mock_generation", {})
		3:
			_check(_set_mock({"manifest": {"name": "Aim Beacon", "kind": "script", "version": "1.0", "description": "Drops a glowing marker at the aim point."},
				"payload": _script_payload(), "summary": "Drops a glowing marker at your aim point."}),
				"v08a(3): mock_generation set for script generation")
			_creator.callv("generate", ["a beacon that drops a glowing marker"])
		4:
			_check(_set_mock({"manifest": {"name": "Bad Mod", "kind": "block", "version": "1.0"},
				"payload": _block_payload("bad_mod", {"jetpack": true}), "summary": "Bad."}),
				"v08a(4): mock_generation set for bad-block generation")
			_creator.callv("generate", ["bad mod"])
		5:
			_check(_set_mock({"manifest": {"name": "Forbidden Mod", "kind": "script", "version": "1.0"},
				"payload": _script_payload("\tOS.execute(\"echo\", [])\n\treturn \"should never run\"\n"), "summary": "Forbidden."}),
				"v08a(5): mock_generation set for forbidden-script generation")
			_creator.callv("generate", ["forbidden mod"])
		6:
			_check(_set_mock({"manifest": {"name": "No Extends", "kind": "script", "version": "1.0"},
				"payload": "func get_block_info() -> Dictionary:\n\treturn {}\n\nfunc apply(api, params):\n\treturn \"x\"\n", "summary": "No extends."}),
				"v08a(6): mock_generation set for no-extends generation")
			_creator.callv("generate", ["no extends mod"])
		7:
			_check(_set_mock({"error": "boom"}), "v08a(7): mock_generation set for error generation")
			_creator.callv("generate", ["error mod"])
		8:
			_check(_set_mock({"nonsense": 1}), "v08a(8): mock_generation set for garbage generation")
			_creator.callv("generate", ["garbage mod"])
		9:
			_creator_script.set("mock_generation", {})
			_creator.callv("generate", ["   "])
		10:
			pass  # synchronous validate() checks run in _check_phase
		11:
			if not _no_key:
				return
			_creator_script.set("mock_generation", {})
			_llm = _llm_script.new()
			root.add_child(_llm as Node)
			_llm.connect("generation_ready", Callable(self, "_on_llm_result"))
			_llm.callv("request_generation", ["anything"])
			_creator2 = _creator_script.new()
			root.add_child(_creator2 as Node)
			_creator2.connect("generation_ready", Callable(self, "_on_candidate"))
			_creator2.callv("generate", ["anything"])


func _check_phase(phase: int) -> void:
	match phase:
		1:
			_check(_got_candidate, "v08a(1): generate() emitted a candidate")
			if not _got_candidate:
				return
			_check(_last_candidate.get("error", "?") == "", "v08a(1): valid block candidate has no error (got '%s')" % str(_last_candidate.get("error", "?")))
			_check(str(_last_candidate.get("mod_id", "")) == "chunky_wall", "v08a(1): candidate mod_id sanitized from name ('%s')" % str(_last_candidate.get("mod_id", "")))
			_check(str(_last_candidate.get("kind", "")) == "block" and str(_last_candidate.get("name", "")) == "Chunky Wall",
				"v08a(1): candidate kind/name match the manifest")
			for key in ["mod_id", "name", "kind", "manifest", "payload", "summary", "error"]:
				_check(_last_candidate.has(key), "v08a(1): candidate has exact key '%s'" % key)
			var parsed: Variant = JSON.parse_string(str(_last_candidate.get("payload", "")))
			_check(parsed is Dictionary and str((parsed as Dictionary).get("block_id", "")) == "chunky_wall",
				"v08a(1): block payload block_id normalized to mod_id (was 'stale_id')")
			_check(not DirAccess.dir_exists_absolute(_mods_abs.path_join("chunky_wall")),
				"v08a(1): generation + validation alone wrote NOTHING to user://mods/")
			_check(str(_creator.callv("validate", [_last_candidate])) == "", "v08a(1): validate(candidate) == ''")
			_saved_candidate = _last_candidate.duplicate(true)
			_check(str(_creator.callv("install", [_last_candidate])) == "", "v08a(1): install(candidate) == ''")
			_check(DirAccess.dir_exists_absolute(_mods_abs.path_join("chunky_wall")), "v08a(1): install wrote user://mods/chunky_wall/")
			var written: Variant = JSON.parse_string(FileAccess.get_file_as_string(_mods_abs.path_join("chunky_wall").path_join("manifest.json")))
			_check(written is Dictionary and str((written as Dictionary).get("file", "")) == "block.json",
				"v08a(1): installed manifest.json names payload file 'block.json'")
			var rec: Variant = _call_script(_loader_script, "find_mod", ["chunky_wall"])
			_check(not rec.is_empty() and str(rec.get("error", "?")) == "", "v08a(1): installed mod record is error-free (got '%s')" % str(rec.get("error", "?")))
			_check(str(_call_script(_llm_script, "user_mods_section", [])).contains("chunky_wall"),
				"v08a(1): installed mod appears in the LLM catalog")
		2:
			# Second install of the SAME candidate -> collision suffix.
			_check(str(_creator.callv("install", [_saved_candidate])) == "", "v08a(2): reinstalling the same candidate succeeds via collision suffix")
			_check(str(_saved_candidate.get("mod_id", "")) == "chunky_wall", "v08a(2): install() did not mutate the candidate's mod_id")
			var rec2: Variant = _call_script(_loader_script, "find_mod", ["chunky_wall_2"])
			_check(not rec2.is_empty() and str(rec2.get("error", "?")) == "", "v08a(2): collision install landed as 'chunky_wall_2' (got '%s')" % str(rec2.get("error", "?")))
		3:
			_check(_got_candidate, "v08a(3): generate() emitted a script candidate")
			if not _got_candidate:
				return
			_check(_last_candidate.get("error", "?") == "", "v08a(3): valid script candidate has no error (got '%s')" % str(_last_candidate.get("error", "?")))
			_check(str(_last_candidate.get("mod_id", "")) == "aim_beacon" and str(_last_candidate.get("kind", "")) == "script",
				"v08a(3): script candidate mod_id/kind correct")
			_check(str(_creator.callv("install", [_last_candidate])) == "", "v08a(3): install(script candidate) == ''")
			var rec3: Variant = _call_script(_loader_script, "find_mod", ["aim_beacon"])
			_check(not rec3.is_empty() and str(rec3.get("error", "?")) == "", "v08a(3): installed script mod record is error-free (got '%s')" % str(rec3.get("error", "?")))
			var info3: Dictionary = rec3.get("block_info", {})
			_check(str(info3.get("target", "")) == "cover", "v08a(3): script mod block_info target is 'cover'")
			_check(str(_mod_by_id(_call_script(_loader_script, "get_mods", []), "aim_beacon").get("kind", "")) == "script",
				"v08a(3): installed mod lists kind 'script'")
			var written3: Variant = JSON.parse_string(FileAccess.get_file_as_string(_mods_abs.path_join("aim_beacon").path_join("manifest.json")))
			_check(written3 is Dictionary and str((written3 as Dictionary).get("file", "")) == "mod.gd",
				"v08a(3): installed manifest.json names payload file 'mod.gd'")
		4:
			_check(_got_candidate, "v08a(4): generate() emitted a candidate for the bad block")
			if not _got_candidate:
				return
			_check(str(_last_candidate.get("error", "")) != "", "v08a(4): bad block candidate has an error (got '%s')" % str(_last_candidate.get("error", "")))
			_check(str(_last_candidate.get("error", "")).contains("jetpack"), "v08a(4): bad block error names the unknown field 'jetpack'")
			_check(str(_creator.callv("install", [_last_candidate])) != "", "v08a(4): install() refuses the failed candidate")
			_check(not DirAccess.dir_exists_absolute(_mods_abs.path_join("bad_mod")), "v08a(4): refused install wrote NOTHING")
		5:
			_check(_got_candidate, "v08a(5): generate() emitted a candidate for the forbidden script")
			if not _got_candidate:
				return
			_check(str(_last_candidate.get("error", "")).contains("forbidden"), "v08a(5): forbidden-script candidate error names 'forbidden' (got '%s')" % str(_last_candidate.get("error", "")))
			_check(str(_creator.callv("install", [_last_candidate])) != "", "v08a(5): install() refuses the forbidden candidate")
			_check(not DirAccess.dir_exists_absolute(_mods_abs.path_join("forbidden_mod")), "v08a(5): refused install wrote NOTHING")
		6:
			_check(_got_candidate, "v08a(6): generate() emitted a candidate for the no-extends script")
			if not _got_candidate:
				return
			_check(str(_last_candidate.get("error", "")).contains("extend ModBlock"), "v08a(6): no-extends candidate error demands 'extend ModBlock' (got '%s')" % str(_last_candidate.get("error", "")))
			_check(str(_creator.callv("install", [_last_candidate])) != "", "v08a(6): install() refuses the no-extends candidate")
			_check(not DirAccess.dir_exists_absolute(_mods_abs.path_join("no_extends")), "v08a(6): refused install wrote NOTHING")
		7:
			_check(_got_candidate, "v08a(7): generate() emitted a candidate for the error generation")
			if not _got_candidate:
				return
			_check(str(_last_candidate.get("error", "")) == "boom", "v08a(7): error generation becomes a candidate with error 'boom'")
			_check(str(_creator.callv("install", [_last_candidate])) == "boom", "v08a(7): install() refuses with the generation error")
		8:
			_check(_got_candidate, "v08a(8): generate() emitted a candidate for garbage generation")
			if not _got_candidate:
				return
			_check(str(_last_candidate.get("error", "")).contains("manifest"), "v08a(8): garbage generation becomes a candidate error about the manifest (got '%s')" % str(_last_candidate.get("error", "")))
		9:
			_check(_got_candidate, "v08a(9): generate('') emitted a candidate")
			if not _got_candidate:
				return
			_check(str(_last_candidate.get("error", "")).contains("describe"), "v08a(9): empty idea yields a 'describe' error candidate (got '%s')" % str(_last_candidate.get("error", "")))
		10:
			var bad_id := {"mod_id": "Bad Id!", "name": "X", "kind": "block", "manifest": {"name": "X", "kind": "block"},
				"payload": _block_payload("ok_mod"), "summary": "", "error": ""}
			_check(str(_creator.callv("validate", [bad_id])) != "", "v08a(10): validate() rejects a non-[a-z0-9_] mod_id")
			var pre_failed := {"mod_id": "ok_mod", "name": "X", "kind": "block", "manifest": {"name": "X", "kind": "block"},
				"payload": _block_payload("ok_mod"), "summary": "", "error": "pre-existing"}
			_check(str(_creator.callv("validate", [pre_failed])) == "pre-existing", "v08a(10): validate() returns a candidate's own error field (error passthrough)")
			var mismatch := {"mod_id": "ok_mod", "name": "X", "kind": "block", "manifest": {"name": "X", "kind": "script"},
				"payload": _script_payload(), "summary": "", "error": ""}
			_check(str(_creator.callv("validate", [mismatch])) != "", "v08a(10): validate() rejects a candidate whose kind mismatches its manifest")
			var long_summary := {"mod_id": "ok_mod", "name": "X", "kind": "block", "manifest": {"name": "X", "kind": "block"},
				"payload": _block_payload("ok_mod"), "summary": "x".repeat(301), "error": ""}
			_check(str(_creator.callv("validate", [long_summary])).contains("summary"), "v08a(10): validate() rejects a >300-char summary")
		11:
			if not _no_key:
				print("VERIFY_V08_A_CREATOR: SKIP v08a(11) no-key phase — a key is stored (no network called)")
				return
			_check(_got_llm, "v08a(11): ForgeLLM emitted generation_ready for the no-key request")
			if _got_llm:
				_check(str(_last_llm_result.get("error", "")) == NO_KEY_EXPECTED, "v08a(11): no-key generation result is the exact NO_KEY_ERROR (got '%s')" % str(_last_llm_result.get("error", "")))
			_check(_got_candidate, "v08a(11): ModCreator emitted a candidate for the no-key generate")
			if _got_candidate:
				_check(str(_last_candidate.get("error", "")) == NO_KEY_EXPECTED, "v08a(11): no-key ModCreator candidate carries NO_KEY_ERROR (got '%s')" % str(_last_candidate.get("error", "")))
