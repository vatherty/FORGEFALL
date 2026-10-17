# tools/verify_forge_unified.gd — v0.5.12 verification: ONE Forge box
# (resolve-or-make) + "weapon_id missing" root-cause fix + script-mod
# weapons in Loadouts.
# Usage: godot --headless --path <project> --script res://tools/verify_forge_unified.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Coverage:
# (1) ROOT CAUSE: ForgeManager._validate_spec (the lenient legacy
#     check) accepts a mod_block weapon spec — before the fix it
#     returned "weapon_id missing" for EVERY mod_block weapon spec,
#     so "give me the taquito launcher" resolved to the installed mod
#     and still never built (preview_cost showed the same error).
#     preview_cost("give me the taquito launcher") is ok, and
#     parse_offline resolves the installed JSON mod by name.
# (2) TAQUITO (JSON mod) END-TO-END via the Forge pipeline:
#     install via Create-a-Mod (mocked generation) -> Forge
#     parse_offline -> ForgeBuilder.build -> the INSTALLED mod is
#     given (same mod_id, same hooks), no regeneration, no error.
# (3) SCRIPT MOD in LOADOUTS: a loadout with a JSON mod (primary) +
#     a script mod (secondary) equips both — the script mod lands in
#     SECONDARY via the same ForgeBuilder path Forge uses (slot
#     threading), primary is NOT clobbered, and the script weapon
#     carries the mod's hooks. A script mod's Forge-pipeline
#     resolution is checked via parse_offline on its block_id name.
# (4) DISABLED MOD: disabling the script mod makes has_weapon false
#     and the Loadouts store sanitize it to the fallback; the JSON
#     mod is unaffected.
# (5) ONE BOX (structural): the Forge menu has EXACTLY ONE prompt
#     input (PromptInput), zero MakePromptInput, and the MAKE panel
#     holds no LineEdit at all.
# (6) RESOLVE-OR-MAKE: a forge_result "Don't know ..." for the
#     pending prompt starts MAKE generation with the same prompt
#     (session-scoped: no file written to user://mods/, nothing
#     installed). A refusal ("Can't do that...") does NOT fall back.
# (7) FALLBACK ELIGIBILITY: is_make_fallback_message is true only
#     for "Don't know" messages — refusals, cooldown, busy, and
#     validation rejections never trigger a generation.
#
# Isolation: user://mods/ + user://mods_enabled.json +
# user://loadouts.json are backed up to user://_v0512_verify_backup_*
# at start, wiped for the run, and restored in _cleanup() on EVERY
# exit path. ModCreator.mock_generation is reset to {} before quit.
extends SceneTree


class FakePlayer extends Node3D:
	var _hp := 100.0
	var _look := Vector2.ZERO

	func heal(amount: float) -> void:
		_hp = minf(_hp + amount, 100.0)

	func add_look(v: Vector2) -> void:
		_look += v


var _fails := 0
var _passes := 0
var _frames := 0
var _started := false
var _phase := 0
var _sub := 0
var _waiting := false
var _gen_wait := 0
var _gen_next := -1
var _got := false
var _candidate: Dictionary = {}
var _cleaned_up := false

var _creator_script: GDScript = null
var _creator: Node = null
var _loader_script: GDScript = null
var _builder_script: GDScript = null
var _llm_script: GDScript = null
var _arsenal_script: GDScript = null
var _wm_script: GDScript = null
var _manager_script: GDScript = null
var _manager: Node = null
var _loadouts_script: GDScript = null
var _loadouts: Node = null
var _menu_script: GDScript = null
var _menu: Control = null

var _cam: Camera3D = null
var _player: FakePlayer = null
var _wm: Node = null

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _loadouts_abs := ""
var _loadouts_backup_abs := ""
var _had_mods := false
var _had_enabled := false
var _had_loadouts := false
var _mods_before_make: Array[String] = []


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


# --- Backup / restore (same pattern as verify_burst_chain.gd) ----------

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


func _list_files_recursive(dir_path: String, out: Array[String]) -> void:
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
			_list_files_recursive(full, out)
		else:
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _backup_and_stage() -> void:
	_user_dir = OS.get_user_data_dir()
	_mods_abs = _user_dir.path_join("mods")
	_backup_abs = _user_dir.path_join("_v0512_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v0512_verify_backup_enabled.json")
	_loadouts_abs = _user_dir.path_join("loadouts.json")
	_loadouts_backup_abs = _user_dir.path_join("_v0512_verify_backup_loadouts.json")
	_wipe_contents(_backup_abs)
	DirAccess.remove_absolute(_backup_abs)
	if FileAccess.file_exists(_enabled_backup_abs):
		DirAccess.remove_absolute(_enabled_backup_abs)
	if FileAccess.file_exists(_loadouts_backup_abs):
		DirAccess.remove_absolute(_loadouts_backup_abs)
	_had_mods = DirAccess.dir_exists_absolute(_mods_abs)
	if _had_mods:
		_copy_recursive(_mods_abs, _backup_abs)
	_had_enabled = FileAccess.file_exists(_enabled_abs)
	if _had_enabled:
		_copy_file(_enabled_abs, _enabled_backup_abs)
	_had_loadouts = FileAccess.file_exists(_loadouts_abs)
	if _had_loadouts:
		_copy_file(_loadouts_abs, _loadouts_backup_abs)
	DirAccess.make_dir_recursive_absolute(_mods_abs)
	_wipe_contents(_mods_abs)
	if FileAccess.file_exists(_enabled_abs):
		DirAccess.remove_absolute(_enabled_abs)
	if FileAccess.file_exists(_loadouts_abs):
		DirAccess.remove_absolute(_loadouts_abs)


func _cleanup() -> void:
	if _cleaned_up:
		return
	_cleaned_up = true
	if _creator_script != null:
		_creator_script.set("mock_generation", {})
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
	if _had_loadouts:
		_copy_file(_loadouts_backup_abs, _loadouts_abs)
		if FileAccess.file_exists(_loadouts_backup_abs):
			DirAccess.remove_absolute(_loadouts_backup_abs)
	elif FileAccess.file_exists(_loadouts_abs):
		DirAccess.remove_absolute(_loadouts_abs)
	if _loader_script != null:
		_loader_script.call("rescan")


# --- Mocks ---------------------------------------------------------------

func _mock_taquito_json() -> Dictionary:
	var hook := {"hook_id": "taquito_boom", "hook_point": "projectile_spawn",
		"display_name": "Taquito Boom",
		"description": "Launches an exploding taquito.",
		"projectile": {"visual": "taquito", "shape": "sphere",
			"speed": 30.0, "damage": 25.0, "range": 90.0, "size": 1.0,
			"gravity": 0.0, "pierce": false, "explodes_on_impact": true,
			"explosion_radius": 3.0, "explosion_damage": 40.0}}
	var block := {"block_id": "taquito_launcher", "target": "weapon", "cost": 300,
		"display_name": "Taquito Launcher",
		"description": "Launches exploding taquitos.",
		"base_weapon_id": "manticore", "damage_mult": 1.0, "mag_mult": 1.0,
		"range_mult": 1.0}
	return {"manifest": {"name": "Taquito Launcher", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify({"block": block, "hooks": [hook]}),
		"summary": "Launches exploding taquitos. Adds hook: taquito_boom (projectile_spawn, exploding taquito projectile)."}


func _script_taquito_source() -> String:
	# A script weapon mod: apply() grants the base weapon through
	# ModAPI (the Forge/Loadouts give path), and get_hooks() carries
	# the mod's behaviour. No forbidden substrings anywhere (the
	# scan rejects load(, .new(, call(, OS., ... even in comments).
	return "extends ModBlock\n" \
		+ "func get_block_info() -> Dictionary:\n" \
		+ "\treturn {\"block_id\": \"taquito_launcher_script\", \"target\": \"weapon\", \"cost\": 300, \"display_name\": \"Taquito Launcher Script\", \"description\": \"Launches exploding taquitos, script-built.\"}\n" \
		+ "func get_hooks() -> Array:\n" \
		+ "\treturn [{\"hook_id\": \"taquito_script_boom\", \"hook_point\": \"on_hit\", \"effects\": [{\"kind\": \"explosion\", \"radius\": 3.0, \"damage\": 30.0}]}]\n" \
		+ "func apply(api: ModAPI, params: Dictionary) -> String:\n" \
		+ "\tvar ok: bool = api.give_weapon(\"manticore\", 1.0, 1.0, 1.0)\n" \
		+ "\tif not ok:\n" \
		+ "\t\treturn \"\"\n" \
		+ "\treturn \"Taquito Launcher Script armed.\"\n"


func _mock_taquito_script() -> Dictionary:
	return {"manifest": {"name": "Taquito Launcher Script", "kind": "script",
			"version": "1.0", "author": "verify"},
		"payload": _script_taquito_source(),
		"summary": "Script-built taquito launcher. Adds hook: taquito_script_boom (on_hit, explosion)."}


func _mock_flibberty() -> Dictionary:
	# A thing that does NOT exist: the unified box must MAKE it.
	var block := {"block_id": "flibberty_gibbet", "target": "weapon", "cost": 100,
		"display_name": "Flibberty Gibbet",
		"description": "A made-up test weapon.",
		"base_weapon_id": "p9", "damage_mult": 1.0, "mag_mult": 1.0,
		"range_mult": 1.0}
	return {"manifest": {"name": "Flibberty Gibbet", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify({"block": block, "hooks": []}),
		"summary": "A made-up test weapon."}


# --- Helpers ---------------------------------------------------------------

func _on_generation_ready(candidate: Dictionary) -> void:
	_candidate = candidate
	_got = true


func _request_generate(mock: Dictionary, next_phase: int) -> void:
	_creator_script.set("mock_generation", mock)
	_got = false
	_candidate = {}
	_gen_wait = 0
	_gen_next = next_phase
	_waiting = true
	_creator.call("generate", "mocked idea — payload comes from mock_generation")


func _install_candidate(label: String) -> bool:
	if not (_candidate is Dictionary) or _candidate.is_empty():
		_check(false, label + ": no candidate generated")
		return false
	var err := str(_candidate.get("error", ""))
	_check(err.is_empty(), label + ": generation error-free (got '%s')" % err)
	if not err.is_empty():
		return false
	var verr := str(_creator.call("validate", _candidate))
	_check(verr.is_empty(), label + ": candidate validates (got '%s')" % verr)
	if not verr.is_empty():
		return false
	var ierr := str(_creator.call("install", _candidate))
	_check(ierr.is_empty(), label + ": install succeeds (got '%s')" % ierr)
	return ierr.is_empty()


func _collect_line_edits(node: Node, out: Array[Node]) -> void:
	if node is LineEdit:
		out.append(node)
	for child in node.get_children():
		_collect_line_edits(child, out)


func _find_named(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find_named(child, node_name)
		if found != null:
			return found
	return null


# --- Main ------------------------------------------------------------------

func _process(_delta: float) -> bool:
	_frames += 1
	if not _started:
		_started = true
		_backup_and_stage()
		_creator_script = load("res://scripts/mods/mod_creator.gd")
		_loader_script = load("res://scripts/mods/mod_loader.gd")
		_builder_script = load("res://scripts/forge/forge_builder.gd")
		_llm_script = load("res://scripts/forge/forge_llm.gd")
		_arsenal_script = load("res://scripts/weapons/arsenal.gd")
		_wm_script = load("res://scripts/weapons/weapon_manager.gd")
		_manager_script = load("res://scripts/forge/forge_manager.gd")
		_loadouts_script = load("res://scripts/progression/loadouts.gd")
		_menu_script = load("res://scripts/ui/forge_menu.gd")
		_creator = _creator_script.new()
		_creator.name = "ModCreator"
		_creator.connect("generation_ready", _on_generation_ready)
		var root := get_root()
		root.add_child(_creator)
		_cam = Camera3D.new()
		_cam.name = "TestCamera"
		root.add_child(_cam)
		_player = FakePlayer.new()
		_player.name = "FakePlayer"
		_player.add_to_group("player")
		root.add_child(_player)
		_wm = _wm_script.new()
		_wm.name = "WeaponManager"
		_player.add_child(_wm)
		_manager = _manager_script.new()
		_manager.name = "ForgeManagerProbe"
		_loadouts = _loadouts_script.new()
		_loadouts.name = "LoadoutsProbe"
		root.add_child(_loadouts)
		_phase = 1
		_request_generate(_mock_taquito_json(), 2)
		return false
	if _waiting:
		_gen_wait += 1
		if _got:
			_waiting = false
			_phase = _gen_next
			_sub = 0
		elif _gen_wait > 120:
			_waiting = false
			_check(false, "generation completed within 120 frames (phase %d)" % _gen_next)
			_phase = _gen_next
			_sub = 0
		return false
	match _phase:
		2:
			# Install the JSON taquito mod.
			if _install_candidate("JSON taquito"):
				var rec: Dictionary = _loader_script.call("find_mod", "taquito_launcher", false)
				_check(not rec.is_empty() and str(rec.get("error", "")) == "", "JSON taquito record error-free after install")
			_phase = 3
			_request_generate(_mock_taquito_script(), 4)
		4:
			# Install the script taquito mod.
			if _install_candidate("script taquito"):
				var rec: Dictionary = _loader_script.call("find_mod", "taquito_launcher_script", false)
				_check(not rec.is_empty() and str(rec.get("error", "")) == "", "script taquito record error-free after install")
				_check(str(rec.get("kind", "")) == "script", "script taquito kind is script")
			_phase = 5
			_sub = 0
		5:
			# (1) Root cause: the legacy lenient check + preview.
			var spec := {"spec_version": 1, "action": "spawn", "target": "weapon",
				"params": {"mod_block": "taquito_launcher"}, "cost": 300, "ttl": 0}
			var verdict: Array = _manager.call("_validate_spec", spec)
			_check(bool(verdict[0]), "legacy _validate_spec accepts mod_block weapon spec (was 'weapon_id missing')")
			_check(str(verdict[1]) != "weapon_id missing", "legacy check never says 'weapon_id missing' for a mod_block spec")
			var preview: Dictionary = _manager.call("preview_cost", "give me the taquito launcher")
			_check(bool(preview.get("ok", false)), "preview_cost('give me the taquito launcher') is ok (was 'weapon_id missing')")
			_check(not str(preview.get("error", "")).contains("weapon_id missing"), "preview error has no 'weapon_id missing'")
			var off: Dictionary = _llm_script.call("parse_offline", "give me the taquito launcher")
			_check(str(off.get("target", "")) == "weapon" and str((off.get("params", {}) as Dictionary).get("mod_block", "")) == "taquito_launcher", "parse_offline resolves 'give me the taquito launcher' to the installed JSON mod")
			var off_script: Dictionary = _llm_script.call("parse_offline", "give me the taquito launcher script")
			_check(str((off_script.get("params", {}) as Dictionary).get("mod_block", "")) == "taquito_launcher_script", "parse_offline resolves 'give me the taquito launcher script' to the installed script mod")
			_phase = 6
		6:
			# (2) Forge pipeline gives the INSTALLED JSON mod.
			var spec: Dictionary = _llm_script.call("parse_offline", "give me the taquito launcher")
			var msg: String = _builder_script.call("build", spec, {"player": _player, "root": get_root()})
			_check(not msg.begins_with("FAIL"), "Forge build of installed JSON mod succeeds (got '%s')" % msg)
			_check(msg.contains("Taquito Launcher"), "Forge build message names the installed mod")
			var primary: Node = _wm.call("get_slot_weapon", "primary")
			_check(primary != null and str(primary.get("mod_id")) == "taquito_launcher", "Forge gives the INSTALLED mod (mod_id == taquito_launcher, not a fresh generation)")
			_check(primary != null and not (primary.get("mod_hooks") as Array).is_empty(), "Forge-given mod weapon carries its hooks")
			_phase = 7
		7:
			# (3) Loadout with JSON (primary) + script (secondary).
			var updated: bool = bool(_loadouts.call("update_loadout", "Assault", "mod:taquito_launcher", "mod:taquito_launcher_script"))
			_check(updated, "loadout update accepts JSON + script mod ids")
			var entry: Dictionary = _loadouts.call("get_loadout", "Assault")
			_check(str(entry.get("primary", "")) == "mod:taquito_launcher" and str(entry.get("secondary", "")) == "mod:taquito_launcher_script", "loadout persists mod:<id> for both mods")
			var applied: bool = bool(_loadouts.call("apply_loadout_to", "Assault", _wm))
			_check(applied, "loadout with script mod applies")
			var prim: Node = _wm.call("get_slot_weapon", "primary")
			var sec: Node = _wm.call("get_slot_weapon", "secondary")
			_check(prim != null and str(prim.get("weapon_id")) == "mod:taquito_launcher", "loadout primary is still the JSON mod (not clobbered by the script build)")
			_check(sec != null and str(sec.get("weapon_id")) == "ar7", "script mod weapon lands in SECONDARY as its granted base weapon")
			_check(sec != null and str(sec.get("mod_id")) == "taquito_launcher_script", "script mod weapon carries the script mod_id")
			_check(sec != null and not (sec.get("mod_hooks") as Array).is_empty(), "script mod weapon carries its hooks")
			var mod_weapons: Array = _arsenal_script.call("get_mod_weapons")
			var saw_script := false
			var saw_json := false
			for m in mod_weapons:
				if m is Dictionary:
					if str((m as Dictionary).get("weapon_id", "")) == "mod:taquito_launcher_script":
						saw_script = true
					if str((m as Dictionary).get("weapon_id", "")) == "mod:taquito_launcher":
						saw_json = true
			_check(saw_json and saw_script, "Arsenal lists BOTH the JSON and the script mod weapon")
			_phase = 8
		8:
			# (4) Disabled script mod fails safe; JSON mod unaffected.
			_loader_script.call("set_mod_enabled", "taquito_launcher_script", false)
			_check(not bool(_arsenal_script.call("has_weapon", "mod:taquito_launcher_script")), "disabled script mod: has_weapon false")
			_check(bool(_arsenal_script.call("has_weapon", "mod:taquito_launcher")), "JSON mod still live after script mod disabled")
			var sanitized: Dictionary = _loadouts.call("_sanitize_entry", {"name": "X", "primary": "mod:taquito_launcher", "secondary": "mod:taquito_launcher_script"})
			_check(str(sanitized.get("secondary", "")) == "p9" and str(sanitized.get("primary", "")) == "mod:taquito_launcher", "Loadouts sanitize falls back the disabled script mod to p9, keeps the JSON mod")
			_loader_script.call("set_mod_enabled", "taquito_launcher_script", true)
			_check(bool(_arsenal_script.call("has_weapon", "mod:taquito_launcher_script")), "re-enabled script mod is live again")
			_phase = 9
			_sub = 0
		9:
			# (5) ONE BOX (structural) + (7) fallback eligibility.
			if _sub == 0:
				_sub = 1
				_menu = _menu_script.new()
				_menu.name = "ForgeMenuProbe"
				get_root().add_child(_menu)
				return false
			# One frame for _ready/_build.
			var edits: Array[Node] = []
			_collect_line_edits(_menu, edits)
			var prompt_inputs := 0
			var make_inputs := 0
			for e in edits:
				if e.name == "PromptInput":
					prompt_inputs += 1
				if e.name == "MakePromptInput":
					make_inputs += 1
			_check(prompt_inputs == 1, "Forge menu has EXACTLY ONE prompt input (found %d)" % prompt_inputs)
			_check(make_inputs == 0, "Forge menu has ZERO MakePromptInput (old second box is gone)")
			var make_panel := _find_named(_menu, "MakePanel")
			var panel_edits: Array[Node] = []
			if make_panel != null:
				_collect_line_edits(make_panel, panel_edits)
			_check(make_panel != null and panel_edits.is_empty(), "MAKE panel holds no text input at all")
			_check(bool(_menu_script.call("is_make_fallback_message", "Don't know 'flibberty' — try: build a wall")), "fallback eligible: 'Don't know' message")
			_check(not bool(_menu_script.call("is_make_fallback_message", "Can't do that with the available blocks (dome) — try: build a wall")), "fallback NOT eligible: refusal")
			_check(not bool(_menu_script.call("is_make_fallback_message", "Forge cooling down: 1.0s.")), "fallback NOT eligible: cooldown")
			_check(not bool(_menu_script.call("is_make_fallback_message", "Forge is already fabricating — one requisition at a time.")), "fallback NOT eligible: busy")
			_check(not bool(_menu_script.call("is_make_fallback_message", "Forge rejected the spec: bad weapon_id 'x'.")), "fallback NOT eligible: validation rejection")
			_phase = 10
			_sub = 0
		10:
			# (6) Resolve-or-make: "Don't know" -> MAKE starts.
			if _sub == 0:
				_sub = 1
				_mods_before_make = []
				_list_files_recursive(_mods_abs, _mods_before_make)
				_menu.set("_unified_pending_prompt", "flibberty gibbet")
				_menu.set("_unified_awaiting_result", true)
				_menu.set("_unified_make_attempted", false)
				_creator_script.set("mock_generation", _mock_flibberty())
				_menu.call("_on_forge_result", false, "Don't know 'flibberty gibbet' — try: build a wall, give me a shotgun")
				_check(bool(_menu.get("_make_generating")), "unified fallback: 'Don't know' starts MAKE generation")
				_check(str(_menu.get("_make_pending_prompt")) == "flibberty gibbet", "unified fallback: MAKE uses the same prompt verbatim")
				_gen_wait = 0
				return false
			# Wait for the menu's MAKE generation to apply (the menu
			# owns its creator; the candidate flows through
			# _on_make_generation_ready -> ForgeSessionMake).
			_gen_wait += 1
			if _gen_wait > 120:
				_check(false, "unified MAKE applied within 120 frames")
				_phase = 11
				return false
			var prim2: Node = _wm.call("get_slot_weapon", "primary")
			if prim2 != null and str(prim2.get("mod_id")) == "flibberty_gibbet":
				_check(true, "unified MAKE applied the generated weapon in-session (mod_id == flibberty_gibbet)")
				var after: Array[String] = []
				_list_files_recursive(_mods_abs, after)
				_check(after == _mods_before_make, "unified MAKE wrote NO file to user://mods/ (session-scoped)")
				var rec: Dictionary = _loader_script.call("find_mod", "flibberty_gibbet", false)
				_check(rec.is_empty(), "unified MAKE installed NOTHING (no ModLoader record)")
				_phase = 11
		11:
			# (6b) Refusal does NOT fall back to MAKE.
			_menu.set("_unified_pending_prompt", "build a dome")
			_menu.set("_unified_awaiting_result", true)
			_menu.set("_unified_make_attempted", false)
			_menu.call("_on_forge_result", false, "Can't do that with the available blocks (can't build that geometry: dome) — try: build a wall")
			_check(not bool(_menu.get("_make_generating")), "refusal does NOT start MAKE generation")
			_phase = 12
		12:
			_cleanup()
			print("verify_forge_unified: %d passed, %d failed" % [_passes, _fails])
			quit(0 if _fails == 0 else 1)
	return false
