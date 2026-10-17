# verify_creator_redesign.gd — headless checks for Worker D (Mod Creator redesign):
# main-menu CREATE A MOD button, standalone creator menu (CREATE / MODS /
# IMPORT/EXPORT real tab), structured form, voxel asset generator + cache,
# sandbox test room, old in-Forge create panel removal, watermelon-LMG E2E.
# Usage: godot --headless --path <project> --script res://tools/verify_creator_redesign.gd
# Tests NEVER call the real DeepSeek API: ModCreator.mock_generation is armed
# before any generate() call. Fixtures live in user://mods/ only via
# ModCreator.install(); the pre-run mods tree is snapshotted + restored.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _passes := 0
var _skips := 0
var _cleaned_up := false

var _gen_script: GDScript
var _menu_script: GDScript
var _sandbox_script: GDScript
var _creator_script: GDScript
var _loader_script: GDScript
var _builder_script: GDScript
var _main_menu: Control
var _creator_menu: Control
var _forge_menu: Control
var _arena: Node3D
var _phase := 0
var _step := "wait"
var _wait := 0

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _had_mods := false
var _had_enabled := false
var _snapshot_before_sandbox: Array = []
var _asset_a: Dictionary = {}


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


# --- Helpers ---------------------------------------------------------------

func _call_script(script: GDScript, method: String, args: Array) -> Variant:
	if script == null:
		return null
	# Poisoned-cache guard: when this suite runs via --script, the
	# engine's early compile pass can fail on autoload identifiers
	# (e.g. Sfx) and cache a BROKEN copy of Sfx-dependent scripts
	# (forge_builder.gd) — a later callv then fails with "Method not
	# found" even though the code is fine (proven by a clean probe).
	# Re-load with CACHE_MODE_REPLACE so the copy we call was
	# compiled AFTER autoloads registered. Instances created from
	# the old copy (e.g. the creator menu) keep working — this only
	# affects the handle used for this call.
	if not script.resource_path.is_empty():
		var fresh := ResourceLoader.load(script.resource_path, "GDScript",
			ResourceLoader.CACHE_MODE_REPLACE) as GDScript
		if fresh != null:
			script = fresh
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


func _find_named(n: Node, name: String) -> Node:
	if n.name == name and not n.is_queued_for_deletion():
		return n
	for c in n.get_children():
		var found := _find_named(c, name)
		if found != null:
			return found
	return null


func _press(button_name: String, scope: Node) -> bool:
	var b := _find_named(scope, button_name) as Button
	if b == null:
		return false
	b.pressed.emit()
	return true


func _mod_by_id(mods: Array, mod_id: String) -> Dictionary:
	for m in mods:
		if m is Dictionary and str((m as Dictionary).get("id", "")) == mod_id:
			return m as Dictionary
	return {}


# --- Fixture staging ----------------------------------------------------------

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
	_backup_abs = _user_dir.path_join("_v09_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v09_verify_backup_enabled.json")
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
	if _creator_script != null:
		_creator_script.set("mock_generation", {})
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
	if _loader_script != null:
		_call_script(_loader_script, "scan_mods", [])


# --- Mock generation: watermelon LMG script mod -------------------------------
# Through the EXISTING validated path only: ModAPI give_weapon /
# spawn_voxel_box (watermelon visual) / fire_effect("explosion", ...).
# No forbidden API (no OS/FileAccess/load/call/.new).

func _mock_watermelon_lmg() -> Dictionary:
	var script_text := (
		"extends ModBlock\n" +
		"\n" +
		"func get_block_info() -> Dictionary:\n" +
		"\treturn {\"block_id\": \"watermelon_lmg\", \"target\": \"weapon\", \"cost\": 300, \"display_name\": \"Watermelon LMG\", \"description\": \"An LMG that shoots watermelons. The watermelons explode on impact.\", \"base_weapon_id\": \"lmg\", \"damage_mult\": 1.5, \"mag_mult\": 1.0, \"range_mult\": 1.0}\n" +
		"\n" +
		"func apply(api: ModAPI, params: Dictionary) -> String:\n" +
		"\tapi.give_weapon(\"lmg\", 1.5, 1.0, 1.0)\n" +
		"\tvar at: Vector3 = api.get_player_position()\n" +
		"\tvar rind: Color = Color(0.35, 0.66, 0.24)\n" +
		"\tvar flesh: Color = Color(0.91, 0.23, 0.31)\n" +
		"\tapi.spawn_voxel_box(Vector3(0.25, 0.25, 0.25), rind, at, false)\n" +
		"\tapi.spawn_voxel_box(Vector3(0.15, 0.15, 0.15), flesh, at + Vector3(0, 0.2, 0), false)\n" +
		"\tapi.fire_effect(\"explosion\", at, 4.0, 60.0, 20.0)\n" +
		"\treturn \"Forge fabricated: Watermelon LMG (mod).\"\n")
	return {
		"manifest": {"name": "Watermelon LMG", "kind": "script",
			"version": "1.0", "author": "verify",
			"description": "An LMG that shoots exploding watermelons."},
		"payload": script_text,
		"summary": "An LMG that shoots watermelons. The watermelons explode on impact.",
	}


# --- Main flow -----------------------------------------------------------------

func _initialize() -> void:
	_backup_and_stage()
	_gen_script = load("res://scripts/mods/voxel_asset_generator.gd") as GDScript
	_menu_script = load("res://scripts/ui/mod_creator_menu.gd") as GDScript
	_sandbox_script = load("res://scripts/ui/sandbox_test_room.gd") as GDScript
	_creator_script = load("res://scripts/mods/mod_creator.gd") as GDScript
	_loader_script = load("res://scripts/mods/mod_loader.gd") as GDScript
	_builder_script = load("res://scripts/forge/forge_builder.gd") as GDScript
	_check(_gen_script != null, "D: voxel_asset_generator.gd loads (no parse errors)")
	_check(_menu_script != null, "D: mod_creator_menu.gd loads (no parse errors)")
	_check(_sandbox_script != null, "D: sandbox_test_room.gd loads (no parse errors)")
	_check(_creator_script != null, "D: mod_creator.gd loads (no parse errors)")
	_check(_loader_script != null, "D: mod_loader.gd loads (no parse errors)")
	_check(_builder_script != null, "D: forge_builder.gd loads (no parse errors)")
	_arena = Node3D.new()
	_arena.name = "VerifyArena"
	root.add_child(_arena)
	# Main menu (its _ready builds the CREATE A MOD button).
	if ResourceLoader.exists("res://scenes/ui/main_menu.tscn"):
		var ps := load("res://scenes/ui/main_menu.tscn") as PackedScene
		_main_menu = ps.instantiate() as Control
		root.add_child(_main_menu)
	_phase = 0
	_wait = 0
	_step = "menu_wait"


func _process(_delta: float) -> bool:
	match _phase:
		0:
			_wait += 1
			if _wait < 3:
				return false
			_phase = 1
			_run_unit_checks()
			_run_menu_structure_checks()
			_start_e2e()
			_step = "wait_gen"
			_wait = 0
			return false
		1:
			# Waiting for the menu's async generation (mock path, deferred emit).
			_wait += 1
			var pending: Dictionary = {}
			if _creator_menu != null and _creator_menu.has_method("get_pending_candidate"):
				pending = _creator_menu.call("get_pending_candidate")
			if not pending.is_empty():
				_phase = 2
				_run_approval_checks(pending)
				_snapshot_before_sandbox = _list_mods_tree()
				_press("SandboxButton", _creator_menu)
				_step = "wait_sandbox"
				_wait = 0
			elif _wait >= 120:
				_check(false, "D E2E: menu Generate produced a candidate (timed out)")
				_phase = 4
				_step = "done"
			return false
		2:
			_wait += 1
			if _wait < 3:
				return false
			_phase = 3
			_run_sandbox_checks()
			# Close the sandbox, then Install.
			_press("SandboxCloseButton", _creator_menu)
			_check(_list_mods_tree() == _snapshot_before_sandbox,
				"D(8): sandbox writes nothing to the real mod list (tree unchanged)")
			_press("ApprovalInstallButton", _creator_menu)
			_run_install_checks()
			_phase = 4
			_run_forge_menu_checks()
			_finish()
			return true
	return false


func _run_unit_checks() -> void:
	# VoxelAssetGenerator: normalize + keys.
	var norm: Variant = _call_script(_gen_script, "normalize_description", ["  Green WATERMELON!! "])
	_check(str(norm) == "green watermelon",
		"D: normalize_description collapses case/punct/space (got '%s')" % str(norm))
	var k1: Variant = _call_script(_gen_script, "cache_key", ["green watermelon"])
	var k2: Variant = _call_script(_gen_script, "cache_key", ["green watermelon"])
	var k3: Variant = _call_script(_gen_script, "cache_key", ["red watermelon"])
	_check(str(k1) == str(k2) and str(k1) != str(k3) and str(k1).length() == 64,
		"D: cache_key deterministic, 64-hex, differs per description")
	# Watermelon voxels: rind green + red interior + black seeds.
	var entries: Variant = _call_script(_gen_script, "generate_voxels", ["green watermelon with dark stripes and red interior"])
	var has_green := false
	var has_red := false
	var has_seed := false
	if entries is Array:
		for e in (entries as Array):
			var col: Color = (e as Array)[1]
			if col.to_html() in ["58a83cff", "1e6b2aff"]:
				has_green = true
			if col.to_html() == "e83a4eff":
				has_red = true
			if col.to_html() == "141414ff":
				has_seed = true
	_check(not (entries as Array).is_empty() and has_green and has_red and has_seed,
		"D: watermelon voxels have green rind + red interior + black seeds (%d voxels)" % (entries as Array).size())
	# Cache: MISS then HIT, same voxels; different description -> new asset.
	var a1: Variant = _call_script(_gen_script, "get_or_generate", ["green watermelon with dark stripes"])
	var a2: Variant = _call_script(_gen_script, "get_or_generate", ["green watermelon with dark stripes"])
	var a3: Variant = _call_script(_gen_script, "get_or_generate", ["blue crystal orb"])
	_check(a1 is Dictionary and not bool((a1 as Dictionary).get("cache_hit", true)),
		"D: first get_or_generate is a cache MISS (generates)")
	_check(a2 is Dictionary and bool((a2 as Dictionary).get("cache_hit", false)),
		"D: second get_or_generate for the same description is a cache HIT (reuses)")
	_check(a2 is Dictionary and a1 is Dictionary and str((a2 as Dictionary).get("cache_key", "")) == str((a1 as Dictionary).get("cache_key", "")) and int((a2 as Dictionary).get("voxel_count", -1)) == int((a1 as Dictionary).get("voxel_count", -2)),
		"D: cache HIT returns the same key + voxel count (no regeneration)")
	_check(a3 is Dictionary and str((a3 as Dictionary).get("cache_key", "")) != str((a1 as Dictionary).get("cache_key", "")) and not bool((a3 as Dictionary).get("cache_hit", true)),
		"D: different description generates a new asset (different key, MISS)")
	_check(a1 is Dictionary and FileAccess.file_exists(str((a1 as Dictionary).get("path", ""))),
		"D: asset cache file written under user://mods/assets/")
	_asset_a = a1 as Dictionary
	# Generic fallback: unknown description still yields voxels.
	var generic: Variant = _call_script(_gen_script, "generate_voxels", ["a purple floating orb of mystery"])
	_check(generic is Array and not (generic as Array).is_empty(),
		"D: unknown description falls back to a generic voxel shape (non-empty)")
	# compose_prompt: stable + carries all four form fields.
	var p1: Variant = _call_script(_menu_script, "compose_prompt",
		[["Weapon", "Effect"], "Watermelon LMG", "green watermelon", "an LMG that shoots watermelons. The watermelons explode on impact."])
	var p2: Variant = _call_script(_menu_script, "compose_prompt",
		[["Weapon", "Effect"], "Watermelon LMG", "green watermelon", "an LMG that shoots watermelons. The watermelons explode on impact."])
	_check(p1 is String and str(p1) == str(p2) and str(p1).contains("Weapon") and str(p1).contains("Effect") and str(p1).contains("Watermelon LMG") and str(p1).contains("green watermelon") and str(p1).contains("explode on impact"),
		"D(C): compose_prompt is stable and carries categories + name + visual + logic")
	# behavior_for: watermelon logic -> projectile + explodes.
	var beh: Variant = _call_script(_menu_script, "behavior_for",
		[["Weapon", "Effect"], "an LMG that shoots watermelons. The watermelons explode on impact.", "api.fire_effect(\"explosion\", at, 4.0, 60.0)"])
	_check(beh is Dictionary and bool((beh as Dictionary).get("projectile", false)) and bool((beh as Dictionary).get("explodes_on_impact", false)),
		"D: behavior_for(watermelon logic) = projectile + explodes_on_impact")
	# Sandbox simulate_test: pure logic, no writes.
	var sim: Variant = _call_script(_sandbox_script, "simulate_test", [{}, _asset_a, beh])
	_check(sim is Dictionary and bool((sim as Dictionary).get("hit", false)) and bool((sim as Dictionary).get("explosion_fired", false)) and int((sim as Dictionary).get("steps", 0)) > 0 and not bool((sim as Dictionary).get("wrote_to_mod_list", true)) and not bool((sim as Dictionary).get("wrote_to_progression", true)),
		"D(8): sandbox simulate_test: HIT + explosion fired, no writes (steps=%d)" % int((sim as Dictionary).get("steps", -1)))
	var sim_block: Variant = _call_script(_sandbox_script, "simulate_test", [{}, _asset_a, {"projectile": false, "explodes_on_impact": false}])
	_check(sim_block is Dictionary and bool((sim_block as Dictionary).get("placed", false)) and not bool((sim_block as Dictionary).get("hit", true)),
		"D(8): sandbox simulate_test for a block mod reports placed (no projectile)")
	# Sandbox build_room: flat room + two dummies under a caller-owned root.
	var room: Variant = _call_script(_sandbox_script, "build_room", [_arena])
	_check(room is Dictionary and (room as Dictionary).get("dummies") is Array and ((room as Dictionary).get("dummies") as Array).size() == 2 and (room as Dictionary).get("spawn_point") == SandboxTestRoom.SHOOTER_POS,
		"D(8): build_room creates a flat room with two dummies under the given root")
	for child in _arena.get_children():
		_arena.remove_child(child)
		child.queue_free()


func _run_menu_structure_checks() -> void:
	if _main_menu == null:
		_skip("D(B): main-menu CREATE A MOD button", "main menu did not instantiate headless")
		_skip("D(B): creator menu tabs", "main menu did not instantiate headless")
		return
	var btn := _find_named(_main_menu, "CreateAModButton") as Button
	_check(btn != null and btn.text == "CREATE A MOD",
		"D(B): main menu has a CREATE A MOD button (text 'CREATE A MOD')")
	_check(_press("CreateAModButton", _main_menu), "D(B): CREATE A MOD button press emits")
	_creator_menu = _find_named(_main_menu, "ModCreatorMenu") as Control
	_check(_creator_menu != null, "D(B): CREATE A MOD opens the standalone creator menu")
	if _creator_menu == null:
		_skip("D(B): creator menu tabs", "creator menu did not open")
		_skip("D(C): structured form", "creator menu did not open")
		_skip("D(B): IMPORT/EXPORT placeholder", "creator menu did not open")
		return
	var tabs := _find_named(_creator_menu, "CreatorTabs") as TabContainer
	_check(tabs != null and tabs.get_tab_count() == 4 and tabs.get_tab_title(0) == "CREATE" and tabs.get_tab_title(1) == "CHAT" and tabs.get_tab_title(2) == "MODS" and tabs.get_tab_title(3) == "IMPORT/EXPORT",
		"D(B): creator menu has four tabs CREATE / CHAT / MODS / IMPORT/EXPORT")
	# Structured form: 5 multi-choice category checkboxes + name + visual + logic.
	var cats_ok := true
	for n in ["CategoryWeapon", "CategoryBlockStructure", "CategoryEnemy", "CategoryEffect", "CategoryGameplay"]:
		if _find_named(_creator_menu, n) == null:
			cats_ok = false
	_check(cats_ok, "D(C): CREATE tab has 5 multi-choice category checkboxes")
	_check(_find_named(_creator_menu, "ModNameInput") != null, "D(C): CREATE tab has a NAME field")
	_check(_find_named(_creator_menu, "VisualInput") != null, "D(C): CREATE tab has a VISUAL DESCRIPTION field")
	_check(_find_named(_creator_menu, "LogicInput") != null, "D(C): CREATE tab has a LOGIC field")
	_check(_find_named(_creator_menu, "GenerateButton") != null, "D(C): CREATE tab has a GENERATE button")
	# Multi-choice: two categories at once.
	var w := _find_named(_creator_menu, "CategoryWeapon") as CheckButton
	var e := _find_named(_creator_menu, "CategoryEffect") as CheckButton
	if w != null and e != null:
		w.button_pressed = true
		e.button_pressed = true
		var sel: Variant = _creator_menu.call("get_selected_categories")
		_check(sel is Array and (sel as Array).has("Weapon") and (sel as Array).has("Effect"),
			"D(C): categories are MULTI-CHOICE (Weapon + Effect both selected)")
	else:
		_check(false, "D(C): categories are MULTI-CHOICE (Weapon + Effect both selected)")
	# IMPORT/EXPORT: REAL since v0.5.10 (mod sharing) — no placeholder
	# note, both buttons enabled. (verify_mod_sharing covers the
	# full Export/Import flow; here we assert the tab is live.)
	_check(_find_named(_creator_menu, "ImportExportNote") == null,
		"D(B): IMPORT/EXPORT tab has NO placeholder note (tab is real)")
	var ib := _find_named(_creator_menu, "ImportButton") as Button
	var eb := _find_named(_creator_menu, "ExportButton") as Button
	# Import is always live; Export disables only when the export
	# picker is empty (no installed mods) — correct empty-state, not
	# a placeholder. The real widgets (HowTo + picker + code field)
	# prove the tab is wired.
	_check(ib != null and not ib.disabled,
		"D(B): IMPORT button exists and is ENABLED (real tab)")
	_check(eb != null and _find_named(_creator_menu, "ExportPicker") != null \
			and _find_named(_creator_menu, "ImportExportHowTo") != null \
			and _find_named(_creator_menu, "ExportCode") != null,
		"D(B): EXPORT button + picker + HowTo + code field exist (real tab, no placeholder)")
	# MODS tab: same-list widgets.
	_check(_find_named(_creator_menu, "ModsList") != null and _find_named(_creator_menu, "ModsRescanButton") != null,
		"D(B): MODS tab has the installed-mods list + Rescan (ModLoader data)")


func _start_e2e() -> void:
	if _creator_menu == null:
		return
	# Arm the mock generation (verified read-back; never generate() without it).
	_creator_script.set("mock_generation", _mock_watermelon_lmg())
	var back: Variant = _creator_script.get("mock_generation")
	_check(back is Dictionary and (back as Dictionary).has("manifest"),
		"D E2E: mock_generation armed + reads back (mock path, no network)")
	# Fill the structured form with Colin's watermelon example.
	var name_in := _find_named(_creator_menu, "ModNameInput") as LineEdit
	var vis_in := _find_named(_creator_menu, "VisualInput") as TextEdit
	var log_in := _find_named(_creator_menu, "LogicInput") as TextEdit
	if name_in != null:
		name_in.text = "Watermelon LMG"
	if vis_in != null:
		vis_in.text = "green watermelon with dark stripes and red interior"
	if log_in != null:
		log_in.text = "an LMG that shoots watermelons. The watermelons explode on impact."
	_check(_press("GenerateButton", _creator_menu), "D E2E: GENERATE button press emits")


func _run_approval_checks(candidate: Dictionary) -> void:
	_creator_script.set("mock_generation", {})
	_check(str(candidate.get("error", "?")) == "",
		"D E2E: watermelon-LMG candidate validates (error == '') (got '%s')" % str(candidate.get("error", "?")))
	_check(str(candidate.get("mod_id", "")) == "watermelon_lmg",
		"D E2E: candidate mod_id derived from the form name (got '%s')" % str(candidate.get("mod_id", "")))
	_check(_find_named(_creator_menu, "ApprovalPanel") != null and (_find_named(_creator_menu, "ApprovalPanel") as Control).visible,
		"D E2E: approval panel shows for the generated candidate")
	var code := _find_named(_creator_menu, "ApprovalCode") as TextEdit
	_check(code != null and code.text == str(candidate.get("payload", "")),
		"D E2E: approval shows the FULL payload text")
	var summ := _find_named(_creator_menu, "ApprovalSummary") as Label
	_check(summ != null and summ.text.contains(str(candidate.get("summary", ""))),
		"D E2E: approval shows the plain-language summary")
	var asset_info := _find_named(_creator_menu, "AssetInfo") as Label
	_check(asset_info != null and asset_info.text.contains("voxels") and asset_info.text.contains("watermelon"),
		"D: approval shows the generated voxel asset info (voxels + visual)")
	var asset: Dictionary = {}
	if _creator_menu.has_method("get_pending_asset"):
		asset = _creator_menu.call("get_pending_asset")
	_check(not asset.is_empty() and int(asset.get("voxel_count", 0)) > 0,
		"D: pending asset generated from the visual description (%d voxels)" % int(asset.get("voxel_count", 0)))
	_check(_find_named(_creator_menu, "SandboxButton") != null and (_find_named(_creator_menu, "SandboxButton") as Button).text == "TEST IN SANDBOX",
		"D(8): approval offers a TEST IN SANDBOX button")


func _run_sandbox_checks() -> void:
	var sandbox := _find_named(_creator_menu, "SandboxTestRoom") as Control
	_check(sandbox != null, "D(8): TEST IN SANDBOX opens the sandbox test room")
	if sandbox == null:
		return
	_check(_find_named(sandbox, "SandboxFireButton") != null and _find_named(sandbox, "SandboxCloseButton") != null,
		"D(8): sandbox has FIRE TEST SHOT + CLOSE controls")
	var cand: Dictionary = _creator_menu.call("get_pending_candidate")
	var asset: Dictionary = _creator_menu.call("get_pending_asset")
	var beh: Dictionary = _call_script(_menu_script, "behavior_for",
		[["Weapon", "Effect"], "an LMG that shoots watermelons. The watermelons explode on impact.", str(cand.get("payload", ""))])
	var sim: Variant = _call_script(_sandbox_script, "simulate_test", [cand, asset, beh])
	_check(sim is Dictionary and bool((sim as Dictionary).get("hit", false)) and bool((sim as Dictionary).get("explosion_fired", false)) and int((sim as Dictionary).get("projectile_voxels", 0)) == int(asset.get("voxel_count", -1)),
		"D(8): sandbox test of the watermelon mod: HIT + explosion, projectile uses the generated voxel visual (%d voxels)" % int((sim as Dictionary).get("projectile_voxels", -1)))


func _run_install_checks() -> void:
	_check(_creator_menu.call("get_pending_candidate").is_empty(),
		"D E2E: Install clears the pending candidate")
	var mods: Variant = _call_script(_loader_script, "get_mods", [])
	_check(not _mod_by_id(mods, "watermelon_lmg").is_empty(),
		"D E2E: installed watermelon mod appears in ModLoader.get_mods()")
	var row := _find_named(_creator_menu, "ModRow_watermelon_lmg")
	_check(row != null, "D E2E: installed mod appears in the creator menu MODS tab (same list)")
	# The mod WORKS through the existing validated path: Forge builds from it.
	# NOTE: the --script early-compile pass can cache a BROKEN
	# forge_builder (Sfx autoload not yet registered at that point);
	# force a fresh compile here — the builder has no live instances
	# in this suite, so reload() is safe.
	_builder_script.reload()
	var ctx := {"player": null, "root": _arena}
	var before := _arena.get_child_count()
	var msg: String = str(_call_script(_builder_script, "build", [
		{"spec_version": 1, "action": "spawn", "target": "weapon",
			"params": {"mod_block": "watermelon_lmg"}, "cost": 0, "ttl": 0}, ctx]))
	_check(not msg.is_empty() and not msg.begins_with(_builder_script.FAIL_PREFIX),
		"D E2E: Forge builds from the installed watermelon mod_block (%s)" % msg)
	_check(_arena.get_child_count() > before,
		"D E2E: installed mod's apply() spawned its watermelon visual via ModAPI (arena gained nodes)")


func _run_forge_menu_checks() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/ui/forge_menu.gd")
	_check(not src.contains("CreateModPanel") and not src.contains("ModsCreateModButton") and not src.contains("CreateModIdeaInput") and not src.contains("CreateModApprovalPanel") and not src.contains("_pending_candidate"),
		"D: old in-Forge create panel + wiring are GONE from forge_menu.gd (source)")
	if not ResourceLoader.exists("res://scenes/ui/forge_menu.tscn"):
		_skip("D: live Forge menu has no create panel", "forge_menu.tscn missing")
		return
	var ps := load("res://scenes/ui/forge_menu.tscn") as PackedScene
	_forge_menu = ps.instantiate() as Control
	root.add_child(_forge_menu)
	_forge_menu.call("open")
	_check(_find_named(_forge_menu, "CreateModPanel") == null and _find_named(_forge_menu, "ModsCreateModButton") == null and _find_named(_forge_menu, "CreateModApprovalPanel") == null,
		"D: live Forge menu has no create panel / CREATE MOD button / approval panel")
	_check(_find_named(_forge_menu, "ModsRescanButton") != null and _find_named(_forge_menu, "ModsList") != null,
		"D: Forge menu Mods tab keeps list + Rescan (list/enable/disable only)")


func _finish() -> void:
	_cleanup()
	if _fails == 0:
		print("VERIFY_CREATOR_REDESIGN: ALL CHECKS PASSED (%d passed, %d skipped)" % [_passes, _skips])
	else:
		printerr("VERIFY_CREATOR_REDESIGN: %d CHECK(S) FAILED (%d passed, %d skipped)" % [_fails, _passes, _skips])
	quit(_fails)
