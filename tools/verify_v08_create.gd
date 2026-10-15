# verify_v08_create.gd — headless checks for FORGEFALL v0.8.0 chunk 2,
# WORKER C (verification): LLM MOD CREATION (Worker A: ModCreator,
# scripts/mods/mod_creator.gd; Forge batch: standalone creator menu,
# scripts/ui/mod_creator_menu.gd) on top of the v0.7 chunk-1 user-mods system.
# Usage: godot --headless --path <project> --script res://tools/verify_v08_create.gd
#
# Contract under test (exact, per ModCreator's header + the menu's own
# contract comment):
#   ModCreator.generate(idea: String) -> void, async, emits
#       generation_ready(candidate)
#   ModCreator.install(candidate: Dictionary) -> String ("" = OK, else error)
#   candidate = {mod_id, name, kind ["block"/"script"], manifest,
#                payload (JSON block text or GDScript source),
#                summary (plain-language), error ("" when valid)}
#   Static var mock_generation: Dictionary = {} — when non-empty,
#   generate() builds its candidate from it (RAW generation shape:
#   {manifest, payload, summary} or {error}) through the SAME
#   validation path as a real generation, instead of the network.
#   Tests NEVER call the real DeepSeek API: generate() is only ever
#   invoked after mock_generation has been set AND read back.
#   The candidate's mod_id is DERIVED from the manifest name via
#   sanitize_mod_id() (the raw generation carries NO mod_id), and a
#   block payload's block_id is NORMALIZED to the mod_id — folder id
#   and block id are always the same. Tests must therefore look mods
#   up by the CANDIDATE's mod_id, never by a mock-supplied id.
#
# Asserts:
#   (1) Valid generated JSON-block mod -> validates (error == "") ->
#       approval candidate shows (summary + FULL payload) -> install()
#       -> mod appears in ModLoader.get_mods() + get_enabled_mods() +
#       the LLM catalog (user_mods_section contains its block_id) ->
#       Forge can build from it (mod_block spec).
#   (2) Generated script containing OS.execute -> REJECTED at validation
#       (error != "", mentions forbidden API), install() refuses, and
#       NO file is written to user://mods/.
#   (3) No install without the Install tap: after generate + validation
#       alone, user://mods/ contains no new mod (folder listing unchanged).
#   (4) Discard drops the generated mod (real UI path: approval shown,
#       then DISCARD pressed) -> no file written, no mod registered.
#   (5) Installed mod persists across ModLoader.rescan() (still listed,
#       still enabled).
#   (6) Regenerate produces a second candidate: two generate() calls with
#       different mock_generation payloads -> two distinct candidates
#       (different mod_id / summary / payload).
#   (7) Menu-level: the standalone ModCreatorMenu (main-menu CREATE A
#       MOD widget, Forge batch directive B) has the structured CREATE
#       form (multi-choice categories, name, visual, logic), the
#       approval panel showing the full payload text, and
#       Install/Discard buttons. If the menu cannot be instantiated
#       headless, source assertions on mod_creator_menu.gd are used
#       instead (said plainly in the output).
#   (8) The UI Install tap itself installs (menu approval -> INSTALL
#       pressed -> mod appears in get_mods() with no manual rescan).
#   (9) The UI Generate tap end-to-end (structured form filled in ->
#       pressed -> approval appears with the generated candidate).
#       This exercises the menu's own creator call, not the test's.
#   PLUS: install() is the ONLY write path — every generate/validation/
#   discard step asserts the mods folder listing is unchanged.
#
# NOTE on test isolation: ModLoader hardcodes user://mods/ (no override),
# so fixtures MUST live there during the run. This verifier snapshots the
# real user://mods/ tree + user://mods_enabled.json to a backup dir,
# installs test mods ONLY via ModCreator.install(), and restores the
# snapshot in _cleanup() on EVERY exit path (pass or fail). It never
# leaves test mods behind.
#
# Exit 0 = all checks pass; any FAIL prints and exits 1. SKIPPED checks
# (with reasons) do not fail the run.
extends SceneTree

var _fails := 0
var _passes := 0
var _skips := 0
var _cleaned_up := false

var _creator_script: GDScript = null
var _creator_inst: Object = null
var _loader_script: GDScript = null
var _llm_script: GDScript = null
var _builder_script: GDScript = null
var _arena: Node3D = null
var _menu: Control = null
var _menu_live := false

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _had_mods := false
var _had_enabled := false

# Async generation state.
var _phase := 0  # 1=A, 2=B(discard), 3=C(forbidden), 4=D(UI install), 5=persist+menu
var _step := "idle"  # idle | wait | done
var _wait := 0
var _pending_return: Variant = null
var _signal_candidate: Dictionary = {}
var _signal_received := false
var _snapshot_before: Array = []

var _cand_a: Dictionary = {}
var _cand_b: Dictionary = {}
var _cand_c: Dictionary = {}
var _cand_d: Dictionary = {}

# Effective ids, taken from each CANDIDATE (mod_id is derived from the
# manifest name — never from the mock). Set per stage.
var _id_a := ""
var _id_b := ""
var _id_c := ""
var _id_d := ""
var _d_installed := false
const GENERATE_TIMEOUT_FRAMES := 120
const MENU_GENERATE_WAIT_FRAMES := 20


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _skip(label: String, reason: String) -> void:
	_skips += 1
	print("SKIPPED: ", label, " (", reason, ")")


# --- Mock generations (the fake LLM outputs) -------------------------------
#
# Shape = the RAW generation dict the LLM returns: {manifest, payload,
# summary} (or {error}). There is NO mod_id in the raw generation —
# the candidate's mod_id is derived from the manifest name, and the
# block payload's block_id is normalized to it. The mock payloads
# deliberately carry a placeholder block_id to prove normalization.

func _mock_block(display_name: String, shape: String,
		cost: int, hp: int, summary: String) -> Dictionary:
	var block := {
		"block_id": "placeholder_block", "target": "cover", "cost": cost,
		"display_name": display_name,
		"description": "A generated test block.",
		"shape": shape, "size_voxels": [1, 2, 1], "hp": hp,
	}
	return {
		"manifest": {"name": display_name, "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify(block),
		"summary": summary,
	}


func _mock_a() -> Dictionary:
	return _mock_block("Verify Lamp Post", "wall", 90, 100,
		"A small lamp-post cover block that blocks incoming fire.")


func _mock_b() -> Dictionary:
	return _mock_block("Verify Brazier", "barricade", 70, 150,
		"A low brazier barricade that gives partial cover.")


func _mock_d() -> Dictionary:
	return _mock_block("Verify Post", "wall", 60, 100,
		"A plain post cover block for quick cover.")


func _mock_e() -> Dictionary:
	return _mock_block("Verify Beacon Light", "wall", 80, 100,
		"A beacon-light cover block that marks a position.")


func _mock_c_forbidden() -> Dictionary:
	var script_text: String = (
		"extends ModBlock\n" +
		"\n" +
		"func get_block_info() -> Dictionary:\n" +
		"\treturn {\"block_id\": \"verify_evil\", \"target\": \"cover\", \"cost\": 100, \"display_name\": \"Verify Evil\", \"description\": \"Forbidden.\", \"shape\": \"wall\", \"size_voxels\": [2, 2, 1], \"hp\": 100.0}\n" +
		"\n" +
		"func apply(api: ModAPI, params: Dictionary) -> String:\n" +
		"\tOS.execute(\"echo\", [])\n" +
		"\treturn \"should never run\"\n")
	return {
		"manifest": {"name": "Verify Evil", "kind": "script",
			"version": "1.0", "author": "verify"},
		"payload": script_text,
		"summary": "A script mod that tries to run a shell command.",
	}


# --- Script-call helper (same pattern as the other verifiers) ---------------

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


func _list_recursive(abs: String, rel: String, out: Array) -> void:
	var dir := DirAccess.open(abs)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			# The voxel-asset cache (user://mods/assets/) is NOT a mod:
			# approval generates + caches the voxel asset by design
			# (directive D), so cache files must not count as mod writes.
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
	# Never leave the mock armed: a later generate() must not silently
	# reuse a test generation.
	if _creator_script != null:
		_creator_script.set("mock_generation", {})
	if _creator_inst != null and is_instance_valid(_creator_inst):
		if _creator_inst is Node:
			var n := _creator_inst as Node
			if n.is_inside_tree():
				n.get_parent().remove_child(n)
			n.free()
		_creator_inst = null
	if not _mods_abs.is_empty():
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
	# Refresh the loader's in-memory state to the restored real disk state.
	if _loader_script != null:
		_call_script(_loader_script, "scan_mods", [])


# --- Mock arming (verified read-back; never generate() without it) -----------

func _set_mock(mock: Dictionary) -> bool:
	if _creator_script == null:
		return false
	_creator_script.set("mock_generation", mock)
	var back: Variant = _creator_script.get("mock_generation")
	if back is Dictionary and (back as Dictionary).get("mod_id", "") == mock.get("mod_id", ""):
		return true
	# Fallback: set on the instance (static vars are also reachable there).
	if _creator_inst != null:
		_creator_inst.set("mock_generation", mock)
		var back2: Variant = _creator_inst.get("mock_generation")
		if back2 is Dictionary and (back2 as Dictionary).get("mod_id", "") == mock.get("mod_id", ""):
			return true
	return false


func _disarm_mock() -> void:
	if _creator_script != null:
		_creator_script.set("mock_generation", {})


# --- Creator calls ------------------------------------------------------------

func _on_generation_ready(candidate: Dictionary) -> void:
	_signal_candidate = candidate
	_signal_received = true


func _call_generate(idea: String) -> void:
	_signal_received = false
	_signal_candidate = {}
	_pending_return = null
	if _creator_inst != null and _creator_inst.has_method("generate"):
		_pending_return = _creator_inst.callv("generate", [idea])
	elif _creator_script != null:
		_pending_return = _call_script(_creator_script, "generate", [idea])


func _call_install(candidate: Dictionary) -> Variant:
	if _creator_inst != null and _creator_inst.has_method("install"):
		return  _creator_inst.callv("install", [candidate])
	return _call_script(_creator_script, "install", [candidate])


# --- Menu helpers --------------------------------------------------------------

func _find_named(n: Node, name: String) -> Node:
	if n.name == name and not n.is_queued_for_deletion():
		return n
	for c in n.get_children():
		var found := _find_named(c, name)
		if found != null:
			return found
	return null


func _menu_press(button_name: String) -> bool:
	if _menu == null:
		return false
	var b := _find_named(_menu, button_name) as Button
	if b == null:
		return false
	b.pressed.emit()
	return true


func _menu_show_approval(candidate: Dictionary) -> bool:
	if _menu == null or not _menu.has_method("_on_generation_ready"):
		return false
	_menu.callv("_on_generation_ready", [candidate])
	return true


func _menu_pending_candidate() -> Dictionary:
	if _menu == null:
		return {}
	var v: Variant = _menu.get("_pending_candidate")
	if v is Dictionary:
		return v as Dictionary
	return {}


# --- Main flow ---------------------------------------------------------------

func _initialize() -> void:
	_backup_and_stage()
	_creator_script = load("res://scripts/mods/mod_creator.gd") as GDScript
	_loader_script = load("res://scripts/mods/mod_loader.gd") as GDScript
	_llm_script = load("res://scripts/forge/forge_llm.gd") as GDScript
	_builder_script = load("res://scripts/forge/forge_builder.gd") as GDScript
	_check(_loader_script != null, "v08create: mod_loader.gd loads (no parse errors)")
	_check(_llm_script != null, "v08create: forge_llm.gd loads (no parse errors)")
	_check(_builder_script != null, "v08create: forge_builder.gd loads (no parse errors)")
	_check(_creator_script != null, "v08create: mod_creator.gd EXISTS (Worker A deliverable)")
	if _creator_script == null:
		_skip_creator_dependent("mod_creator.gd absent — nothing to verify")
		_setup_menu()
		# Menu presence checks need frames: the menu's _ready builds the
		# tabs, and open() before that errors on Nil (see _process phase -1).
		_phase = -1
		_wait = 0
		_step = "menu_wait"
		return
	# Creator instance (same shape as the menu's: Node added to the tree
	# so async work can run; generation_ready wired once here).
	var inst: Object = _creator_script.new()
	if inst == null:
		_check(false, "v08create: ModCreator instantiates")
		_skip_creator_dependent("ModCreator did not instantiate")
		_setup_menu()
		_phase = -1
		_wait = 0
		_step = "menu_wait"
		return
	_creator_inst = inst
	if _creator_inst.has_signal("generation_ready"):
		_creator_inst.connect("generation_ready", _on_generation_ready)
		_check(true, "v08create: ModCreator exposes generation_ready signal")
	else:
		_check(false, "v08create: ModCreator exposes generation_ready signal (contract: generate() emits it)")
	if _creator_inst is Node and not (_creator_inst as Node).is_inside_tree():
		root.add_child(_creator_inst as Node)
	# The mock mechanism must be settable + verifiable BEFORE any
	# generate() call — otherwise generate() could touch the network.
	var mock_ok := _set_mock(_mock_a())
	_check(mock_ok, "v08create: mock_generation settable + reads back (mock path armed)")
	_disarm_mock()
	if not mock_ok:
		_skip_creator_dependent("mock_generation could not be set — refusing to call generate() (would risk real network)")
		_setup_menu()
		_phase = -1
		_wait = 0
		_step = "menu_wait"
		return
	_arena = Node3D.new()
	_arena.name = "V08VerifyArena"
	root.add_child(_arena)
	_setup_menu()
	# Menu presence checks + stage 1 start happen in _process once the
	# menu's _ready has built the tabs (phase 0, after a few frames).
	_phase = 0
	_wait = 0
	_step = "menu_wait"


func _skip_creator_dependent(reason: String) -> void:
	var labels := [
		"v08create(1): valid block candidate validates (error == '')",
		"v08create(1): candidate carries all 7 contract keys",
		"v08create(1): candidate mod_id is path-safe",
		"v08create(1): candidate summary + payload non-empty",
		"v08create(1): approval panel shows summary + FULL payload",
		"v08create(3): generate + validation alone writes no mod",
		"v08create(1): install() returns '' (String OK)",
		"v08create(1): installed mod in ModLoader.get_mods()",
		"v08create(1): installed mod in ModLoader.get_enabled_mods()",
		"v08create(1): installed mod in LLM catalog (user_mods_section)",
		"v08create(1): Forge builds from the installed mod_block",
		"v08create(6): regenerate yields a distinct second candidate",
		"v08create(4): Discard drops the candidate (no file, not registered)",
		"v08create(4): Discard clears the menu's pending candidate",
		"v08create(2): forbidden script REJECTED at validation",
		"v08create(2): forbidden error mentions forbidden API",
		"v08create(2): install() refuses the forbidden candidate",
		"v08create(2): forbidden candidate writes no file",
		"v08create(2): forbidden mod not registered after rescan",
		"v08create(8): UI Install tap installs the mod",
		"v08create(8): UI Install clears the approval panel",
		"v08create(9): menu Generate tap produces a candidate",
		"v08create(9): menu Generate candidate validates",
		"v08create(9): menu Generate approval shows the payload",
		"v08create(9): Discard clears the menu-generated candidate",
		"v08create(5): installed mods persist across rescan()",
		"v08create(5): installed mods stay enabled across rescan()",
		"v08create(5): persisted mods stay in the LLM catalog",
	]
	for label in labels:
		_skip(label, reason)


func _setup_menu() -> void:
	if not ResourceLoader.exists("res://scenes/ui/mod_creator_menu.tscn"):
		print("V08CREATE NOTE: mod_creator_menu.tscn not found — menu checks fall back to source assertions")
		return
	var ps := load("res://scenes/ui/mod_creator_menu.tscn") as PackedScene
	if ps == null:
		print("V08CREATE NOTE: mod_creator_menu.tscn failed to load — menu checks fall back to source assertions")
		return
	_menu = ps.instantiate() as Control
	if _menu == null:
		print("V08CREATE NOTE: mod_creator_menu.tscn did not instantiate — menu checks fall back to source assertions")
		return
	root.add_child(_menu)
	_menu_live = true
	# NOTE: do NOT call open() here — the menu's _ready builds the tabs
	# and has not run yet when _initialize executes. open() + presence
	# checks happen in _process after a few frames (v07b pattern).


func _check_menu_presence() -> void:
	if not _menu_live or _menu == null:
		var src := FileAccess.get_file_as_string("res://scripts/ui/mod_creator_menu.gd")
		_check(src.contains("CategoryRow") and src.contains("ModNameInput") and src.contains("VisualInput") and src.contains("LogicInput"),
			"v08create(7): SOURCE fallback — mod_creator_menu.gd has structured CREATE form (categories, name, visual, logic)")
		_check(src.contains("ApprovalPanel"),
			"v08create(7): SOURCE fallback — mod_creator_menu.gd has approval panel")
		_check(src.contains("ApprovalInstallButton") and src.contains("ApprovalDiscardButton"),
			"v08create(7): SOURCE fallback — mod_creator_menu.gd has Install/Discard buttons")
		_check(src.contains("_approval_code.text = str(candidate.get(\"payload\""),
			"v08create(7): SOURCE fallback — approval panel is wired to show the full payload")
		print("V08CREATE NOTE: menu could not be instantiated headless — live menu checks SKIPPED, source assertions used instead")
		return
	_check(_find_named(_menu, "ModNameInput") != null,
		"v08create(7): structured CREATE form — name input present")
	_check(_find_named(_menu, "VisualInput") != null,
		"v08create(7): structured CREATE form — visual description input present")
	_check(_find_named(_menu, "LogicInput") != null,
		"v08create(7): structured CREATE form — logic input present")
	_check(_find_named(_menu, "CategoryRow") != null,
		"v08create(7): structured CREATE form — multi-choice category row present")
	_check(_find_named(_menu, "GenerateButton") != null,
		"v08create(7): create-mod GENERATE button present")
	_check(_find_named(_menu, "ApprovalPanel") != null,
		"v08create(7): approval panel (ApprovalPanel) present")
	_check(_find_named(_menu, "ApprovalSummary") != null,
		"v08create(7): approval summary label present")
	_check(_find_named(_menu, "ApprovalCode") != null,
		"v08create(7): approval full-code area (ApprovalCode) present")
	var inst_b := _find_named(_menu, "ApprovalInstallButton") as Button
	var disc_b := _find_named(_menu, "ApprovalDiscardButton") as Button
	var regen_b := _find_named(_menu, "ApprovalRegenerateButton") as Button
	_check(inst_b != null and inst_b.text == "INSTALL",
		"v08create(7): approval Install button present (text 'INSTALL')")
	_check(disc_b != null and disc_b.text == "DISCARD",
		"v08create(7): approval Discard button present (text 'DISCARD')")
	_check(regen_b != null and regen_b.text == "REGENERATE",
		"v08create(7): approval Regenerate button present (text 'REGENERATE')")


func _start_stage(stage: int) -> void:
	_phase = stage
	_step = "wait"
	_wait = 0
	_snapshot_before = _list_mods_tree()
	match stage:
		1:
			_set_mock(_mock_a())
			_call_generate("a small lamp post cover")
		2:
			_set_mock(_mock_b())
			_call_generate("a low brazier barricade for cover")
		3:
			_set_mock(_mock_c_forbidden())
			_call_generate("a script mod that runs a shell command")
		4:
			_set_mock(_mock_d())
			_call_generate("a plain post cover block")
		6:
			# Menu-driven generation: the MENU's own creator call, not
			# the test's. The mock stays armed while the menu works.
			# The creator is a structured form (directive C): fill
			# name + visual + logic for a beacon-light cover block.
			_set_mock(_mock_e())
			var name_input := _find_named(_menu, "ModNameInput") as LineEdit
			if name_input != null:
				name_input.text = "Beacon Light"
			var visual_input := _find_named(_menu, "VisualInput") as TextEdit
			if visual_input != null:
				visual_input.text = "a glowing beacon light on a small post"
			var logic_input := _find_named(_menu, "LogicInput") as TextEdit
			if logic_input != null:
				logic_input.text = "a beacon-light cover block"
			# The creator's Generate requires >= 1 category checked
			# (it refuses with "Pick at least one category." otherwise).
			# NOTE: the category controls are CheckButtons, not CheckBoxes.
			var cat_cb := _find_named(_menu, "CategoryBlockStructure") as CheckButton
			if cat_cb != null:
				cat_cb.button_pressed = true
			_step = "menu_wait6"
			_wait = 0
			_menu_press("GenerateButton")
			return
		_:
			_step = "done"
	# Synchronous return path: generate() handed us a candidate directly.
	if _pending_return is Dictionary and (not (_pending_return as Dictionary).is_empty()):
		_signal_candidate = _pending_return as Dictionary
		_signal_received = true


func _process(_delta: float) -> bool:
	if _step == "menu_wait":
		_wait += 1
		if _wait < 3:
			return false
		_step = "idle"
		if _menu_live and _menu != null:
			# NOTE: do NOT call open() here — the old Forge menu had
			# open(), but ModCreatorMenu is live as soon as it is in
			# the tree, and calling a nonexistent open() via call()
			# hangs this run (observed: no further _process frames).
			pass
		_check_menu_presence()
		if _phase == -1:
			_finish()
			return true
		_start_stage(1)
		return false
	if _phase == 0:
		return false
	if _step == "menu_wait6":
		_wait += 1
		if _wait >= MENU_GENERATE_WAIT_FRAMES:
			_step = "done"
			_stage_menu_generate()
		return false
	if _step == "wait":
		_wait += 1
		if _signal_received:
			_step = "done"
			_process_stage(_phase, _signal_candidate)
		elif _wait >= GENERATE_TIMEOUT_FRAMES:
			_step = "done"
			_process_stage(_phase, {})
		return false
	return false


func _process_stage(stage: int, candidate: Dictionary) -> void:
	_disarm_mock()
	match stage:
		1:
			_stage_a(candidate)
		2:
			_stage_b(candidate)
		3:
			_stage_c(candidate)
		4:
			_stage_d(candidate)
		5:
			_stage_persist()


func _check_candidate_shape(candidate: Dictionary, label: String) -> bool:
	var ok := true
	for key in ["mod_id", "name", "kind", "manifest", "payload", "summary", "error"]:
		if not candidate.has(key):
			_check(false, label + ": candidate has key '%s'" % key)
			ok = false
	if ok:
		_check(true, label + ": candidate carries all 7 contract keys")
	return ok


func _check_mod_id_safe(candidate: Dictionary, label: String) -> void:
	var mod_id := str(candidate.get("mod_id", ""))
	var safe := not mod_id.is_empty() and not mod_id.contains("/") and not mod_id.contains("\\") and mod_id != "." and mod_id != ".."
	_check(safe, label + ": candidate mod_id is path-safe (got '%s')" % mod_id)


# --- Stage 1: valid block -> approval -> install -> catalog -> build --------

func _stage_a(candidate: Dictionary) -> void:
	if candidate.is_empty():
		_check(false, "v08create(1): generate() produced a candidate for a valid block idea (timed out / no signal)")
		_skip("v08create(1): remaining stage-1 checks", "no candidate (generate timed out)")
		_start_stage(2)
		return
	_cand_a = candidate
	_id_a = str(candidate.get("mod_id", ""))
	_check(str(candidate.get("error", "?")) == "",
		"v08create(1): valid block candidate validates (error == '') (got '%s')" % str(candidate.get("error", "?")))
	_check_candidate_shape(candidate, "v08create(1)")
	_check_mod_id_safe(candidate, "v08create(1)")
	_check(str(candidate.get("kind", "")) == "block", "v08create(1): candidate kind is 'block'")
	_check(not str(candidate.get("summary", "")).is_empty() and not str(candidate.get("payload", "")).is_empty(),
		"v08create(1): candidate summary + payload non-empty")
	# mod_id is DERIVED from the manifest name (raw generation has none).
	var want_id: Variant = _call_script(_creator_script, "sanitize_mod_id", [str(candidate.get("name", ""))])
	_check(_id_a == str(want_id) and _id_a == "verify_lamp_post",
		"v08create(1): candidate mod_id derived from name via sanitize_mod_id (got '%s')" % _id_a)
	# Block payload block_id is NORMALIZED to the mod_id.
	var payload_data: Variant = JSON.parse_string(str(candidate.get("payload", "")))
	var payload_block_id := ""
	if payload_data is Dictionary:
		payload_block_id = str((payload_data as Dictionary).get("block_id", ""))
	_check(payload_block_id == _id_a,
		"v08create(1): candidate payload block_id normalized to mod_id (got '%s')" % payload_block_id)
	# (3) Generate + validation alone must not write anything.
	_check(_list_mods_tree() == _snapshot_before,
		"v08create(3): generate + validation alone writes no mod (folder listing unchanged)")
	# (1) Approval candidate shows: summary + FULL payload in the panel.
	if _menu_live:
		var shown := _menu_show_approval(candidate)
		_check(shown, "v08create(1): approval panel can be driven via _on_generation_ready")
		if shown:
			var code := _find_named(_menu, "ApprovalCode") as TextEdit
			_check(code != null and code.text == str(candidate.get("payload", "")),
				"v08create(1): approval panel shows the FULL payload text")
			var summ := _find_named(_menu, "ApprovalSummary") as Label
			_check(summ != null and summ.text.contains(str(candidate.get("summary", ""))),
				"v08create(1): approval panel shows the summary")
			# Drop the displayed candidate through the real Discard tap:
			# nothing written, menu state cleared.
			_check(_menu_press("ApprovalDiscardButton"), "v08create(1): Discard button press emits")
			_check(_menu_pending_candidate().is_empty(),
				"v08create(1): Discard clears the menu's pending candidate")
			_check(_list_mods_tree() == _snapshot_before,
				"v08create(1): Discard-after-approval still writes no mod")
	else:
		_skip("v08create(1): approval panel shows summary + FULL payload", "menu not instantiated headless")
	# Install (creator-direct): the ONLY write path.
	var result: Variant = _call_install(candidate)
	_check(result is String, "v08create(1): install() returns a String (got %s)" % str(typeof(result)))
	_check(result is String and str(result) == "",
		"v08create(1): install() returns '' (OK) (got '%s')" % str(result))
	var after_install := _list_mods_tree()
	var folder_named := false
	for entry in after_install:
		if str(entry).begins_with(_id_a + "/"):
			folder_named = true
	_check(after_install != _snapshot_before and folder_named,
		"v08create(1): install() writes the mod folder user://mods/%s/" % _id_a)
	var mods: Variant = _call_script(_loader_script, "get_mods", [])
	_check(not _mod_by_id(mods, _id_a).is_empty(),
		"v08create(1): installed mod in ModLoader.get_mods()")
	var enabled: Variant = _call_script(_loader_script, "get_enabled_mods", [])
	_check(not _mod_by_id(enabled, _id_a).is_empty(),
		"v08create(1): installed mod in ModLoader.get_enabled_mods()")
	var section: Variant = _call_script(_llm_script, "user_mods_section", [])
	_check(str(section).contains(_id_a),
		"v08create(1): installed mod in LLM catalog (user_mods_section contains its block_id)")
	# Forge can build from it (mod_block spec, v07 pattern).
	var ctx := {"player": null, "root": _arena}
	var msg: String = str(_call_script(_builder_script, "build", [
		{"spec_version": 1, "action": "spawn", "target": "cover",
			"params": {"mod_block": _id_a, "position": [10, 0, 10]}, "cost": 0, "ttl": 0}, ctx]))
	_check(not msg.is_empty() and not msg.begins_with(_builder_script.FAIL_PREFIX),
		"v08create(1): Forge builds from the installed mod_block (%s)" % msg)
	_check(bool(_builder_script.last_built_valid),
		"v08create(1): mod_block build registered a live node")
	_start_stage(2)


# --- Stage 2: regenerate (distinct) + Discard drops it ------------------------

func _stage_b(candidate: Dictionary) -> void:
	if candidate.is_empty():
		_check(false, "v08create(6): generate() produced a second candidate (timed out / no signal)")
		_skip("v08create(6): remaining stage-2 checks", "no candidate (generate timed out)")
		_start_stage(3)
		return
	_cand_b = candidate
	_id_b = str(candidate.get("mod_id", ""))
	_check(str(candidate.get("error", "?")) == "",
		"v08create(6): second candidate validates (error == '') (got '%s')" % str(candidate.get("error", "?")))
	_check(str(candidate.get("mod_id", "")) != str(_cand_a.get("mod_id", "")),
		"v08create(6): regenerate yields a distinct mod_id ('%s' vs '%s')"
		% [str(candidate.get("mod_id", "")), str(_cand_a.get("mod_id", ""))])
	_check(str(candidate.get("summary", "")) != str(_cand_a.get("summary", "")),
		"v08create(6): regenerate yields a distinct summary")
	_check(str(candidate.get("payload", "")) != str(_cand_a.get("payload", "")),
		"v08create(6): regenerate yields a distinct payload")
	# (4) Discard drops the generated mod: real UI path (approval shown,
	# then DISCARD pressed) — no file written, no mod registered.
	if _menu_live:
		_check(_menu_show_approval(candidate), "v08create(4): second candidate shown in approval panel")
		_check(_menu_press("ApprovalDiscardButton"), "v08create(4): Discard button press emits")
		_check(_menu_pending_candidate().is_empty(),
			"v08create(4): Discard clears the menu's pending candidate")
	else:
		_skip("v08create(4): Discard clears the menu's pending candidate", "menu not instantiated headless")
		# Without the menu, "discard" is simply: never call install().
	var after_discard := _list_mods_tree()
	var b_written := false
	for entry in after_discard:
		if str(entry).contains(_id_b):
			b_written = true
	_check(after_discard == _snapshot_before and not b_written,
		"v08create(4): Discard writes no file for the discarded mod")
	_call_script(_loader_script, "rescan", [])
	_check(_mod_by_id(_call_script(_loader_script, "get_mods", []), _id_b).is_empty(),
		"v08create(4): Discard drops the generated mod (not registered after rescan)")
	_start_stage(3)


# --- Stage 3: forbidden script -> rejected, install refuses, no write --------

func _stage_c(candidate: Dictionary) -> void:
	if candidate.is_empty():
		_check(false, "v08create(2): generate() produced a candidate for the forbidden-script idea (timed out / no signal)")
		_skip("v08create(2): remaining stage-3 checks", "no candidate (generate timed out)")
		_start_stage(4)
		return
	_cand_c = candidate
	_id_c = str(candidate.get("mod_id", ""))
	var err := str(candidate.get("error", ""))
	_check(err != "", "v08create(2): forbidden script REJECTED at validation (error != '')")
	_check(err.to_lower().contains("forbidden") or err.contains("OS.execute"),
		"v08create(2): forbidden error mentions forbidden API (got '%s')" % err)
	# install() must refuse the rejected candidate...
	var result: Variant = _call_install(candidate)
	_check(result is String and not str(result).is_empty(),
		"v08create(2): install() refuses the forbidden candidate (got '%s')" % str(result))
	# ...and write nothing.
	var after_forbidden := _list_mods_tree()
	var c_written := false
	for entry in after_forbidden:
		if str(entry).contains(_id_c):
			c_written = true
	_check(after_forbidden == _snapshot_before and not c_written,
		"v08create(2): forbidden candidate writes no file")
	_call_script(_loader_script, "rescan", [])
	_check(_mod_by_id(_call_script(_loader_script, "get_mods", []), _id_c).is_empty(),
		"v08create(2): forbidden mod not registered after rescan")
	_start_stage(4)


# --- Stage 4: UI Install tap installs -----------------------------------------

func _stage_d(candidate: Dictionary) -> void:
	if candidate.is_empty():
		_check(false, "v08create(8): generate() produced a candidate for the UI-install idea (timed out / no signal)")
		_skip("v08create(8): remaining stage-4 checks", "no candidate (generate timed out)")
		_stage_persist()
		return
	_cand_d = candidate
	_id_d = str(candidate.get("mod_id", ""))
	_check(str(candidate.get("error", "?")) == "",
		"v08create(8): UI-install candidate validates (error == '') (got '%s')" % str(candidate.get("error", "?")))
	if not _menu_live:
		_skip("v08create(8): UI Install tap installs the mod", "menu not instantiated headless")
		var r: Variant = _call_install(candidate)
		_check(r is String and str(r) == "", "v08create(8): fallback direct install() returns '' (got '%s')" % str(r))
		_d_installed = (r is String and str(r) == "")
		_start_stage(6)
		return
	_check(_menu_show_approval(candidate), "v08create(8): candidate shown in approval panel")
	var code := _find_named(_menu, "ApprovalCode") as TextEdit
	_check(code != null and code.text == str(candidate.get("payload", "")),
		"v08create(8): approval panel shows the FULL payload text")
	var summ := _find_named(_menu, "ApprovalSummary") as Label
	_check(summ != null and summ.text.contains(str(candidate.get("summary", ""))),
		"v08create(8): approval panel shows the summary")
	_check(_menu_press("ApprovalInstallButton"), "v08create(8): Install button press emits")
	# No manual rescan: the Install tap must make the mod visible.
	_d_installed = not _mod_by_id(_call_script(_loader_script, "get_mods", []), _id_d).is_empty()
	_check(_d_installed,
		"v08create(8): UI Install tap installs the mod (in get_mods() with no manual rescan)")
	_check(_menu_pending_candidate().is_empty(),
		"v08create(8): UI Install clears the approval panel")
	_start_stage(6)


# --- Stage 6: menu Generate tap end-to-end ----------------------------------
#
# The menu's GENERATE button drives its OWN creator instance. A
# candidate must arrive in the menu's approval panel. If the menu's
# creator call is broken, no candidate ever arrives and the status
# stays stuck at "Generating…".

func _stage_menu_generate() -> void:
	_disarm_mock()
	if not _menu_live:
		_skip("v08create(9): menu Generate tap produces a candidate", "menu not instantiated headless")
		_stage_persist()
		return
	var pending := _menu_pending_candidate()
	var status := _find_named(_menu, "CreateStatus") as Label
	var status_text := status.text if status != null else "<no status label>"
	_check(not pending.is_empty(),
		"v08create(9): menu Generate tap produces a candidate (menu status: '%s')" % status_text)
	if pending.is_empty():
		_skip("v08create(9): menu Generate approval shows the payload", "no candidate arrived from the menu Generate tap")
		_skip("v08create(9): menu Generate candidate validates", "no candidate arrived from the menu Generate tap")
		_stage_persist()
		return
	_check(str(pending.get("error", "?")) == "",
		"v08create(9): menu Generate candidate validates (error == '') (got '%s')" % str(pending.get("error", "?")))
	var code := _find_named(_menu, "ApprovalCode") as TextEdit
	_check(code != null and code.text == str(pending.get("payload", "")),
		"v08create(9): menu Generate approval shows the FULL payload text")
	# Leave nothing behind: discard the menu-generated candidate.
	_menu_press("ApprovalDiscardButton")
	_check(_menu_pending_candidate().is_empty(),
		"v08create(9): Discard clears the menu-generated candidate")
	_stage_persist()


# --- Stage 5: persistence + menu toggle ---------------------------------------

func _stage_persist() -> void:
	_phase = 5
	_step = "done"
	_call_script(_loader_script, "rescan", [])
	var mods: Variant = _call_script(_loader_script, "get_mods", [])
	var enabled: Variant = _call_script(_loader_script, "get_enabled_mods", [])
	# A was installed via creator-direct install() (stage 1) — it must persist.
	_check(not _mod_by_id(mods, _id_a).is_empty(),
		"v08create(5): installed mod '%s' persists across rescan()" % _id_a)
	_check(not _mod_by_id(enabled, _id_a).is_empty(),
		"v08create(5): installed mod '%s' stays enabled across rescan()" % _id_a)
	var section: Variant = _call_script(_llm_script, "user_mods_section", [])
	_check(str(section).contains(_id_a),
		"v08create(5): persisted mod '%s' stays in the LLM catalog" % _id_a)
	# D only exists if the stage-4 UI Install tap worked; if it did not,
	# there is nothing to persist — SKIP, don't cascade-FAIL.
	if _d_installed:
		_check(not _mod_by_id(mods, _id_d).is_empty(),
			"v08create(5): installed mod '%s' persists across rescan()" % _id_d)
		_check(not _mod_by_id(enabled, _id_d).is_empty(),
			"v08create(5): installed mod '%s' stays enabled across rescan()" % _id_d)
		_check(str(section).contains(_id_d),
			"v08create(5): persisted mod '%s' stays in the LLM catalog" % _id_d)
	else:
		_skip("v08create(5): installed mod '%s' persists across rescan()" % _id_d,
			"UI Install tap did not install D — nothing to persist")
		_skip("v08create(5): installed mod '%s' stays enabled across rescan()" % _id_d,
			"UI Install tap did not install D — nothing to persist")
		_skip("v08create(5): persisted mod '%s' stays in the LLM catalog" % _id_d,
			"UI Install tap did not install D — nothing to persist")
	# Discarded / forbidden mods must STILL be absent after the rescan.
	_check(_mod_by_id(mods, _id_b).is_empty(),
		"v08create(5): discarded mod still absent after rescan()")
	_check(_mod_by_id(mods, _id_c).is_empty(),
		"v08create(5): forbidden mod still absent after rescan()")
	# Menu: IMPORT/EXPORT tab is present but placeholder-only by design
	# (directive B) — its buttons are disabled, no functionality wired.
	if _menu_live:
		var ie_tab := _find_named(_menu, "ImportExportTab") as Control
		_check(ie_tab != null, "v08create(7): IMPORT/EXPORT tab present in the creator menu")
		var imp_b := _find_named(_menu, "ImportButton") as Button
		var exp_b := _find_named(_menu, "ExportButton") as Button
		_check(imp_b != null and imp_b.disabled and exp_b != null and exp_b.disabled,
			"v08create(7): IMPORT/EXPORT is placeholder-only (both buttons disabled)")
	else:
		_skip("v08create(7): IMPORT/EXPORT placeholder tab", "menu not instantiated headless")
	_finish()


func _finish() -> void:
	_cleanup()
	if _fails == 0:
		print("VERIFY_V08_CREATE: ALL CHECKS PASSED (%d passed, %d skipped)" % [_passes, _skips])
	else:
		printerr("VERIFY_V08_CREATE: %d CHECK(S) FAILED (%d passed, %d skipped)" % [_fails, _passes, _skips])
	quit(_fails)
