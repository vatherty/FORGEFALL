# tools/verify_hook_scripts.gd — WORKER C verification for FORGEFALL v0.5.6
# (Route B hook scripts, Workers A + B).
# Usage: godot --headless --path <project> --script res://tools/verify_hook_scripts.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Verifies with MOCKED generation only (ModCreator.mock_generation) + hand-written
# script fixtures — no network, no real key, no live LLM anywhere on these paths.
# Verifies, does not fix: game code is never modified here.
#
# Coverage:
#  (1) Pull/vortex end-to-end (the behaviour the effect-kinds table CANNOT
#      express — knockback only pushes AWAY): mocked generation invents an
#      on_hit hook carrying the prompt's few-shot pull script -> allowlist
#      validation accepts it -> approval preview lists it AND the approval
#      screen shows the script (label + full source) -> the sandbox runs
#      it for real and reports what it did (status applied) -> install
#      works -> in-game a hitscan shot actually pulls the dummy TOWARD
#      the player (velocity gains a toward-player component; a plain
#      knockback would push it away).
#  (2) Forbidden calls REJECTED with named violations + NO file written:
#      OS, FileAccess, load, ClassDB, GDScript.new, raw node access
#      (.position, get_node, .queue_free), `while` loops, `await`,
#      recursion / call cycles (direct + mutual), `api` properties
#      (api.last_spawned, api.last_spawned_position), range() > 1000.
#      Each case is checked at the validator (error names the violation)
#      AND at install() (refused, user://mods/ tree unchanged).
#  (3) Runaway hook: a `for i in range(1000): api.announce(...)` hook
#      blows the 200-call step budget -> run_hooks reports
#      budget_exceeded -> the mod is DISABLED VISIBLY (record carries a
#      budget error, enabled=false) -> a later dispatch skips the hook.
#      The suite itself completing proves no hang / crash. (Honest
#      limit, verified as a limit: a tight loop with NO api calls cannot
#      be preempted by the engine — the guard for that vector is
#      validation rejecting `while`, covered in (2).)
#  (4) Table effect kinds unchanged: a pure table-effects mod (on_hit
#      slow) validates, approves WITHOUT any script section, and
#      functions (registry run slows a real dummy; sandbox reports the
#      slow with factor + speed drop and runs NO hook scripts).
#  (5) Approval script-section polarity: script mods show the labelled
#      script section; pure table-effects mods show none.
#  (6) Sandbox reporting: hook-script actions land in
#      hook_script_reports ("hook script ran: vortex_pull — status
#      applied ..."); the sandbox writes nothing to the mod list.
#
# Isolation: user://mods/ + user://mods_enabled.json are backed up to
# user://_v056_verify_backup_* at start, wiped for the run, and restored
# in _cleanup() on EVERY exit path. ModCreator.mock_generation is reset
# to {} before quit.
extends SceneTree

# --- Fake actors ------------------------------------------------------------

class FakePlayer extends Node3D:
	var _hp := 100.0

	func heal(amount: float) -> void:
		_hp = minf(_hp + amount, 100.0)


class PullDummy extends CharacterBody3D:
	var hp := 1000.0
	var dead := false

	func _init() -> void:
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4, 4, 1)
		cs.shape = box
		add_child(cs)

	func take_damage(dmg: float, _pos: Vector3, _head: bool) -> void:
		hp -= dmg
		if hp <= 0.0:
			dead = true

	func is_dead() -> bool:
		return dead


var _fails := 0
var _passes := 0
var _frames := 0
var _started := false
var _phase := 1
var _waiting := false
var _gen_wait := 0
var _gen_next := -1
var _got := false
var _candidate: Dictionary = {}
var _cleaned_up := false

var _creator_script: GDScript = null
var _creator: Node = null
var _loader_script: GDScript = null
var _hook_script: GDScript = null
var _registry_script: GDScript = null
var _builder_script: GDScript = null
var _llm_script: GDScript = null
var _arsenal_script: GDScript = null
var _sandbox_script: GDScript = null
var _api_script: GDScript = null
var _status_script: GDScript = null
var _wm_script: GDScript = null

var _cam: Camera3D = null
var _player: FakePlayer = null
var _wm: Node = null
var _menu: Control = null
var _table_dummy: PullDummy = null
var _sandbox_dummy: PullDummy = null
var _sandbox_player: Node3D = null
var _pull_dummy: PullDummy = null

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _had_mods := false
var _had_enabled := false

var _table_candidate: Dictionary = {}


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


# --- Backup / restore (same pattern as verify_invented_hooks.gd) -----------

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
	_backup_abs = _user_dir.path_join("_v056_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v056_verify_backup_enabled.json")
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
	if _loader_script != null:
		_loader_script.call("rescan")


# --- Fixtures ---------------------------------------------------------------

## The prompt's few-shot pull/vortex hook script, verbatim.
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


## Mocked LLM generation for "a weapon that drags hit enemies toward me"
## (RAW generation shape, as the LLM would return).
func _mock_vortex() -> Dictionary:
	var block := {
		"block_id": "placeholder_block", "target": "weapon", "cost": 250,
		"display_name": "Vortex Pull",
		"description": "A weapon that drags hit enemies toward you.",
		"base_weapon_id": "p9",
	}
	var hooks := [{
		"hook_id": "vortex_pull", "hook_point": "on_hit",
		"display_name": "Vortex Pull",
		"description": "Drags the hit target toward the player.",
		"code": _vortex_code(),
	}]
	return {"manifest": {"name": "Vortex Pull", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify({"block": block, "hooks": hooks}),
		"summary": "A weapon that drags hit enemies toward you with a vortex pull hook."}


## Pure table-effects candidate (hand-built, NOT via generation): on_hit
## slow — fully expressible via the effect-kinds table, no script.
func _make_table_candidate() -> Dictionary:
	var block := {
		"block_id": "verify_bubble_slow", "target": "weapon", "cost": 200,
		"display_name": "Bubble Slow",
		"description": "A weapon that slows hit enemies.",
		"base_weapon_id": "p9",
	}
	var hooks := [{
		"hook_id": "bubble_slow", "hook_point": "on_hit",
		"display_name": "Bubble Slow",
		"description": "Slows the hit target.",
		"effects": [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0}],
	}]
	var payload := JSON.stringify({"block": block, "hooks": hooks})
	return {"mod_id": "verify_bubble_slow", "name": "Bubble Slow",
		"kind": "block", "manifest": {"name": "Bubble Slow", "kind": "block"},
		"payload": payload, "summary": "A weapon that slows hit enemies.", "error": ""}


## Hand-built block candidate carrying ONE hook-code string (for the
## forbidden / runaway cases). error is "" so install()'s own validation
## is what must refuse it.
func _code_candidate(hook_code: String, hook_id: String = "verify_hook_code") -> Dictionary:
	var block := {
		"block_id": "verify_forbidden", "target": "weapon", "cost": 100,
		"display_name": "Verify Forbidden",
		"description": "Hook-code fixture.",
		"base_weapon_id": "p9",
	}
	var hooks := [{
		"hook_id": hook_id, "hook_point": "on_hit",
		"display_name": "Verify Hook Code",
		"description": "Hook-code fixture.",
		"code": hook_code,
	}]
	var payload := JSON.stringify({"block": block, "hooks": hooks})
	return {"mod_id": "verify_forbidden", "name": "Verify Forbidden",
		"kind": "block", "manifest": {"name": "Verify Forbidden", "kind": "block"},
		"payload": payload, "summary": "Hook-code fixture.", "error": ""}


func _runaway_code() -> String:
	return (
		"extends ModHook\n" +
		"func run(api: ModAPI, ctx: Dictionary) -> Dictionary:\n" +
		"\tfor i in range(1000):\n" +
		"\t\tapi.announce(\"Spam\", \"x\")\n" +
		"\treturn {}\n")


## {code, token} forbidden cases. `token` is the substring the rejection
## must name (the violation, not a generic error).
func _forbidden_cases() -> Array:
	var run_head := "extends ModHook\nfunc run(api: ModAPI, ctx: Dictionary) -> Dictionary:\n"
	return [
		{"name": "OS", "token": "OS.execute",
			"code": run_head + "\tOS.execute(\"echo\", [])\n\treturn {}\n"},
		{"name": "FileAccess", "token": "FileAccess",
			"code": run_head + "\tvar f = FileAccess.open(\"user://evil.txt\", FileAccess.WRITE)\n\treturn {}\n"},
		{"name": "load", "token": "load",
			"code": run_head + "\tvar x = load(\"res://foo.tres\")\n\treturn {}\n"},
		{"name": "ClassDB", "token": "ClassDB",
			"code": run_head + "\tvar ok = ClassDB.class_exists(\"Node\")\n\treturn {}\n"},
		{"name": "GDScript.new", "token": "GDScript.new",
			"code": run_head + "\tvar s = GDScript.new()\n\treturn {}\n"},
		{"name": ".position", "token": "position",
			"code": run_head + "\tvar tgt = ctx.get(\"target\", null)\n\tvar p = tgt.position\n\treturn {}\n"},
		{"name": "get_node", "token": "get_node",
			"code": run_head + "\tvar tgt = ctx.get(\"target\", null)\n\tvar n = tgt.get_node(\"Foo\")\n\treturn {}\n"},
		{"name": ".queue_free", "token": "queue_free",
			"code": run_head + "\tvar tgt = ctx.get(\"target\", null)\n\ttgt.queue_free()\n\treturn {}\n"},
		{"name": "while", "token": "while",
			"code": run_head + "\twhile true:\n\t\tpass\n\treturn {}\n"},
		{"name": "await", "token": "await",
			"code": run_head + "\tawait api.announce(\"Hi\", \"x\")\n\treturn {}\n"},
		{"name": "direct recursion", "token": "call cycle",
			"code": run_head + "\treturn run(api, ctx)\n"},
		{"name": "mutual recursion", "token": "call cycle",
			"code": run_head + "\treturn helper_a(api, ctx)\n" +
				"func helper_a(api: ModAPI, ctx: Dictionary) -> Dictionary:\n\treturn helper_b(api, ctx)\n" +
				"func helper_b(api: ModAPI, ctx: Dictionary) -> Dictionary:\n\treturn helper_a(api, ctx)\n"},
		{"name": "api.last_spawned", "token": "last_spawned",
			"code": run_head + "\tvar n = api.last_spawned\n\treturn {}\n"},
		{"name": "api.last_spawned_position", "token": "last_spawned_position",
			"code": run_head + "\tvar p = api.last_spawned_position\n\treturn {}\n"},
		{"name": "range over cap", "token": "range",
			"code": run_head + "\tfor i in range(1001):\n\t\tapi.announce(\"Spam\", \"x\")\n\treturn {}\n"},
	]


# --- Helpers ---------------------------------------------------------------

func _on_generation_ready(candidate: Dictionary) -> void:
	_candidate = candidate
	_got = true


func _request_generate(mock: Dictionary, next_phase: int) -> void:
	_creator_script.set("mock_generation", mock)
	var back: Variant = _creator_script.get("mock_generation")
	_check(back is Dictionary and not (back as Dictionary).is_empty(),
		"mock_generation set + reads back before generate()")
	_got = false
	_candidate = {}
	_gen_wait = 0
	_gen_next = next_phase
	_waiting = true
	_creator.call("generate", "mocked idea — payload comes from mock_generation")


func _mod_record(mod_id: String) -> Dictionary:
	return _loader_script.call("find_mod", mod_id, false)


func _gate_and_build(mod_id: String) -> bool:
	var spec := {"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"mod_block": mod_id}, "cost": 0, "ttl": 0}
	var verdict: Array = _llm_script.call("validate_modspec", spec)
	_check(bool(verdict[0]), "gate: validate_modspec accepts spec for '%s' (%s)" % [mod_id, str(verdict[1])])
	if not bool(verdict[0]):
		return false
	var ctx := {"player": _player, "root": root}
	var msg: String = _builder_script.call("build", spec, ctx)
	_check(not msg.begins_with("FORGE_FAIL"), "build: ForgeBuilder.build('%s') succeeds (%s)" % [mod_id, msg])
	return not msg.begins_with("FORGE_FAIL")


func _current_weapon() -> Node:
	var weapons: Dictionary = _wm.get("_weapons")
	return weapons.get("primary")


func _fire_current() -> void:
	var w := _current_weapon()
	w.set("_raise_t", 999.0)
	w.set("_cooldown", 0.0)
	w.call("_attempt_fire")


## Approval-screen script section for `candidate`, via the real menu.
## Returns {"label_visible": bool, "toggle_visible": bool,
## "script_visible": bool, "script_text": String, "label_text": String,
## "hooks_text": String}.
func _approval_script_section(candidate: Dictionary) -> Dictionary:
	_menu.call("_show_approval", candidate)
	var label := _menu.find_child("ApprovalScriptLabel", true, false) as Label
	var toggle := _menu.find_child("ApprovalScriptToggle", true, false) as Button
	var script := _menu.find_child("ApprovalScript", true, false) as TextEdit
	var hooks_lbl := _menu.find_child("ApprovalHooks", true, false) as Label
	return {
		"label_visible": label.visible if label != null else false,
		"toggle_visible": toggle.visible if toggle != null else false,
		"script_visible": script.visible if script != null else false,
		"script_text": script.text if script != null else "",
		"label_text": label.text if label != null else "",
		"hooks_text": hooks_lbl.text if hooks_lbl != null else "",
	}


# --- Setup ------------------------------------------------------------------

func _setup() -> void:
	_backup_and_stage()
	_creator_script = load("res://scripts/mods/mod_creator.gd")
	_loader_script = load("res://scripts/mods/mod_loader.gd")
	_hook_script = load("res://scripts/mods/mod_hook.gd")
	_registry_script = load("res://scripts/mods/mod_hook_registry.gd")
	_builder_script = load("res://scripts/forge/forge_builder.gd")
	_llm_script = load("res://scripts/forge/forge_llm.gd")
	_arsenal_script = load("res://scripts/weapons/arsenal.gd")
	_sandbox_script = load("res://scripts/ui/sandbox_test_room.gd")
	_api_script = load("res://scripts/mods/mod_api.gd")
	_status_script = load("res://scripts/mods/mod_status_effects.gd")
	_wm_script = load("res://scripts/weapons/weapon_manager.gd")

	# The generation prompt documents the pull/vortex example (few-shot).
	var creator_src := FileAccess.get_file_as_string("res://scripts/mods/mod_creator.gd")
	_check(creator_src.contains("FEW-SHOT EXAMPLE") and creator_src.contains("vortex"),
		"prompt: HOOK_PROMPT_ADDENDUM documents the pull/vortex few-shot example")

	_loader_script.call("rescan")
	var pre: Dictionary = _loader_script.call("find_mod", "vortex_pull", false)
	_check((pre as Dictionary).is_empty(),
		"setup: no builtin 'vortex_pull' mod ships (find_mod empty before install)")

	_cam = Camera3D.new()
	_cam.current = true
	root.add_child(_cam)
	_player = FakePlayer.new()
	_player.name = "FakePlayer"
	_player.position = Vector3.ZERO
	root.add_child(_player)
	_wm = _wm_script.new()
	_wm.name = "WeaponManager"
	_player.add_child(_wm)

	# Table-test dummy: off the firing axis so it never intercepts shots.
	_table_dummy = PullDummy.new()
	_table_dummy.name = "TableDummy"
	_table_dummy.position = Vector3(10, 0, 10)
	root.add_child(_table_dummy)
	# In-game pull target: on the firing axis, in front of the player.
	_pull_dummy = PullDummy.new()
	_pull_dummy.name = "PullDummy"
	_pull_dummy.position = Vector3(0, 0, -5)
	root.add_child(_pull_dummy)

	_creator = _creator_script.new()
	root.add_child(_creator)
	_creator.connect("generation_ready", _on_generation_ready)

	_menu = load("res://scenes/ui/mod_creator_menu.tscn").instantiate() as Control
	root.add_child(_menu)


# --- Phase 1 (sync): forbidden + table + runaway ----------------------------

func _phase1() -> void:
	# --- (2) Forbidden calls: validator names the violation -------------
	for c in _forbidden_cases():
		var d := c as Dictionary
		var err: String = _hook_script.call("validate_hook_code", str(d.get("code", "")))
		_check(err != "" and err.contains(str(d.get("token", ""))),
			"forbidden: '%s' REJECTED naming '%s' ('%s')" % [str(d.get("name", "")), str(d.get("token", "")), err])
	# --- (2) Forbidden calls: install() refuses + NO file written --------
	for c in _forbidden_cases():
		var d := c as Dictionary
		var snap := _list_mods_tree()
		var cand := _code_candidate(str(d.get("code", "")))
		var ierr: String = _creator.call("install", cand)
		_check(ierr != "" and ierr.contains(str(d.get("token", ""))),
			"forbidden: install() refuses '%s' naming '%s' ('%s')" % [str(d.get("name", "")), str(d.get("token", "")), ierr])
		_check(_list_mods_tree() == snap,
			"forbidden: rejected '%s' writes NO file to user://mods/" % str(d.get("name", "")))

	# --- (4) Table effect kinds still work --------------------------------
	_table_candidate = _make_table_candidate()
	var verr: String = _creator.call("validate", _table_candidate)
	_check(verr == "", "table: pure table-effects mod validates (error='%s')" % verr)
	var preview: Array = _hook_script.call("preview_hooks_for_candidate", _table_candidate)
	_check(preview.size() == 1 and not (preview[0] as Dictionary).has("code"),
		"table: preview finds 1 hook with NO code (pure table effects)")
	var tlines: Array = _hook_script.call("summarize_hooks", preview)
	_check("\n".join(tlines).contains("bubble_slow") and "\n".join(tlines).contains("slow x0.50"),
		"table: approval lists the slow hook ('%s')" % "\n".join(tlines))
	# Approval shows NO script section for the pure table-effects mod.
	var tsec := _approval_script_section(_table_candidate)
	_check(not bool(tsec.get("script_visible", true))
		and not bool(tsec.get("label_visible", true))
		and not bool(tsec.get("toggle_visible", true)),
		"table: approval shows NO script section (script/label/toggle all hidden)")
	# Table hook FUNCTIONS through the registry: a real dummy is slowed.
	var tapi = _api_script.new(_player, root)
	var tctx := {"position": Vector3(10, 0, 10), "hit_position": Vector3(10, 0, 10),
		"damage": 10.0, "target": _table_dummy, "headshot": false, "weapon_id": "verify"}
	var tres: Dictionary = _registry_script.call("run_hooks", preview, "on_hit", tapi, tctx)
	_check(bool(tres.get("status_applied", false)),
		"table: registry run applies the slow (status_applied)")
	var mult: float = _status_script.call("speed_multiplier", _table_dummy)
	_check(is_equal_approx(mult, 0.5),
		"table: slowed dummy speed multiplier is 0.5 (got %.2f)" % mult)
	# Sandbox: table hook reports the slow, runs NO hook scripts.
	var tsim: Dictionary = _sandbox_script.call("simulate_test", {}, {"voxel_count": 6},
		{"projectile": true, "hooks": preview})
	_check((tsim.get("status_effects", []) as Array).size() == 1
		and str(((tsim.get("status_effects", []) as Array)[0] as Dictionary).get("kind", "")) == "slow"
		and is_equal_approx(float(tsim.get("dummy_speed_after", 0.0)), 2.0),
		"table: sandbox reports slow + dummy speed 4.0 -> 2.0")
	_check((tsim.get("hook_scripts_run", []) as Array).is_empty()
		and (tsim.get("hook_script_reports", []) as Array).is_empty(),
		"table: sandbox runs NO hook scripts for a table-effects mod")
	_check(not bool(tsim.get("wrote_to_mod_list", true)),
		"table: sandbox writes nothing to the mod list")

	# --- (3) Runaway hook: budget aborts + mod disabled visibly ----------
	var run_cand := _code_candidate(_runaway_code(), "verify_runaway")
	# The runaway hook itself must VALIDATE (bounded for-loop, allowlist
	# calls only) — the budget catches it at RUN time, not validation.
	var run_preview: Array = _hook_script.call("preview_hooks_for_candidate", run_cand)
	_check(run_preview.size() == 1 and str((run_preview[0] as Dictionary).get("error", "")) == "",
		"runaway: 1000-iteration announce hook validates (budget is a run-time guard)")
	var run_ierr: String = _creator.call("install", run_cand)
	_check(run_ierr == "", "runaway: install() succeeds ('%s')" % run_ierr)
	var run_rec := _mod_record("verify_forbidden")
	_check(not (run_rec as Dictionary).is_empty() and str((run_rec as Dictionary).get("error", "")) == "",
		"runaway: installed record is error-free before the run")
	var run_hooks: Array = (run_rec as Dictionary).get("hooks", [])
	_check(run_hooks.size() == 1, "runaway: installed record carries 1 hook")
	var rapi = _api_script.new(_player, root)
	var rres: Dictionary = _registry_script.call("run_hooks", run_hooks, "on_hit", rapi, {})
	_check(bool(rres.get("budget_exceeded", false)),
		"runaway: run_hooks reports budget_exceeded (1000 announce calls > 200 cap)")
	var run_rec2 := _mod_record("verify_forbidden")
	_check(str((run_rec2 as Dictionary).get("error", "")).to_lower().contains("budget")
		and not bool((run_rec2 as Dictionary).get("enabled", true)),
		"runaway: mod DISABLED VISIBLY after budget blowout (error='%s')" % str((run_rec2 as Dictionary).get("error", "")))
	var public: Array = _loader_script.call("get_mods")
	var pub_err := ""
	for m in public:
		if str((m as Dictionary).get("id", "")) == "verify_forbidden":
			pub_err = str((m as Dictionary).get("error", ""))
	_check(pub_err != "" and pub_err.to_lower().contains("budget"),
		"runaway: public mod list shows the budget error (visible disable)")
	var rres2: Dictionary = _registry_script.call("run_hooks", run_hooks, "on_hit", rapi, {})
	_check(not bool(rres2.get("budget_exceeded", false)),
		"runaway: later dispatch SKIPS the disabled mod's hook (no second blowout)")
	var run_rec3 := _mod_record("verify_forbidden")
	_check(str((run_rec3 as Dictionary).get("error", "")) == str((run_rec2 as Dictionary).get("error", "")),
		"runaway: first error kept (no overwrite by the skipped dispatch)")

	# --- (1) Vortex: generation (async) -----------------------------------
	_request_generate(_mock_vortex(), 2)


# --- Phase 2: vortex candidate -> approval -> sandbox -> install -> game ---

func _phase2() -> void:
	# --- Generation -> allowlist validation ------------------------------
	var err := str(_candidate.get("error", ""))
	_check(err == "", "vortex: candidate validates (error='%s')" % err)
	var hooks: Array = _hook_script.call("preview_hooks_for_candidate", _candidate)
	_check(hooks.size() == 1 and str((hooks[0] as Dictionary).get("hook_id", "")) == "vortex_pull",
		"vortex: approval preview finds exactly the invented hook 'vortex_pull'")
	_check(str((hooks[0] as Dictionary).get("code", "")).contains("extends ModHook")
		and str((hooks[0] as Dictionary).get("code", "")).contains("apply_status_effect"),
		"vortex: previewed hook carries the hook-script source (extends ModHook + apply_status_effect)")
	var lines: Array = _hook_script.call("summarize_hooks", hooks)
	var joined := "\n".join(lines)
	_check(joined.contains("vortex_pull") and joined.contains("on_hit"),
		"vortex: approval lists the hook explicitly ('%s')" % joined)
	# --- Approval shows script (label + source) ---------------------------
	var sec := _approval_script_section(_candidate)
	_check(bool(sec.get("script_visible", false)),
		"vortex: approval SHOWS the hook-script section")
	_check(bool(sec.get("label_visible", false))
		and str(sec.get("label_text", "")).contains("LLM-AUTHORED"),
		"vortex: approval script section is labelled LLM-AUTHORED ('%s')" % str(sec.get("label_text", "")).left(80))
	_check(bool(sec.get("toggle_visible", false)),
		"vortex: approval script section has its show/hide toggle")
	_check(str(sec.get("script_text", "")).contains("Hook script: vortex_pull (on_hit)")
		and str(sec.get("script_text", "")).contains("extends ModHook")
		and str(sec.get("script_text", "")).contains("apply_status_effect"),
		"vortex: approval script section shows label + full source")
	# --- Sandbox runs it + reports what it did ----------------------------
	_sandbox_dummy = PullDummy.new()
	_sandbox_dummy.name = "SandboxDummy"
	_sandbox_dummy.position = Vector3(0, 0, -5)
	root.add_child(_sandbox_dummy)
	_sandbox_player = Node3D.new()
	_sandbox_player.name = "SandboxPlayer"
	_sandbox_player.position = Vector3.ZERO
	root.add_child(_sandbox_player)
	var sapi = _api_script.new(_sandbox_player, root)
	var sctx := {"position": Vector3(0, 0, -5), "hit_position": Vector3(0, 0, -5),
		"damage": 10.0, "target": _sandbox_dummy, "headshot": false, "weapon_id": "sandbox"}
	var sim: Dictionary = _sandbox_script.call("simulate_test", {}, {"voxel_count": 6},
		{"projectile": true, "hooks": hooks,
			"projectile_spec": {"visual": "vortex", "speed": 30.0, "damage": 10.0,
				"explodes_on_impact": false}},
		{"api": sapi, "ctx": sctx})
	_check(bool(sim.get("hit", false)), "vortex: sandbox shot hits")
	_check("vortex_pull" in (sim.get("hook_scripts_run", []) as Array),
		"vortex: sandbox RAN the hook script (hook_scripts_run has vortex_pull)")
	var reports := "\n".join(sim.get("hook_script_reports", []) as Array)
	_check(reports.contains("hook script ran: vortex_pull") and reports.contains("status applied"),
		"vortex: sandbox REPORTS what the script did ('%s')" % reports)
	_check(str(sim.get("hook_error", "")) == "" and not bool(sim.get("candidate_disabled", true)),
		"vortex: sandbox does NOT disable the valid candidate")
	_check(not bool(sim.get("wrote_to_mod_list", true)),
		"vortex: sandbox writes nothing to the mod list")
	# The sandbox dummy was PULLED: velocity points TOWARD the player
	# (player at origin, dummy at z=-5: toward-player is +z). A plain
	# knockback from the hit point would push it AWAY (-z).
	_check(_sandbox_dummy.velocity.z > 4.0 and _sandbox_dummy.velocity.y > 0.0,
		"vortex: sandbox dummy pulled toward player (velocity=%s)" % str(_sandbox_dummy.velocity))
	# Sandbox dummy must not intercept the in-game shot below.
	root.remove_child(_sandbox_dummy)
	_sandbox_dummy.queue_free()
	_sandbox_dummy = null
	root.remove_child(_sandbox_player)
	_sandbox_player.queue_free()
	_sandbox_player = null
	# --- Install ------------------------------------------------------------
	var ierr: String = _creator.call("install", _candidate)
	_check(ierr == "", "vortex: install() succeeds ('%s')" % ierr)
	var rec := _mod_record("vortex_pull")
	_check(not (rec as Dictionary).is_empty() and str((rec as Dictionary).get("error", "")) == "",
		"vortex: installed record is error-free")
	var rec_hooks: Array = (rec as Dictionary).get("hooks", [])
	_check(rec_hooks.size() == 1 and (rec_hooks[0] as Dictionary).has("code"),
		"vortex: installed record carries the 1 code hook")
	# --- Works in-game: gate+build, fire, dummy pulled --------------------
	if not _gate_and_build("vortex_pull"):
		_phase = 99
		return
	var w := _current_weapon()
	_check(str(w.get("mod_id")) == "vortex_pull",
		"vortex: gate+build weapon carries mod_id 'vortex_pull' (got '%s')" % str(w.get("mod_id")))
	var w_hooks: Array = w.get("mod_hooks")
	_check(w_hooks.size() == 1,
		"vortex: gate+build weapon carries 1 hook (got %d)" % w_hooks.size())
	var hp_before := _pull_dummy.hp
	_pull_dummy.velocity = Vector3.ZERO
	_fire_current()
	_check(_pull_dummy.hp < hp_before,
		"vortex: in-game shot landed (dummy HP %.0f -> %.0f)" % [hp_before, _pull_dummy.hp])
	_check(_pull_dummy.velocity.z > 4.0 and _pull_dummy.velocity.y > 0.0,
		"vortex: in-game dummy PULLED toward player (velocity=%s)" % str(_pull_dummy.velocity))
	_phase = 99


func _finish() -> void:
	_cleanup()
	print("HOOK_SCRIPTS VERIFY: %d checks, %d passes, %d failures" % [_passes + _fails, _passes, _fails])
	quit(1 if _fails > 0 else 0)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	if not _started:
		_started = true
		_setup()
		return false
	if _waiting:
		_gen_wait += 1
		if _got:
			_waiting = false
			_got = false
			_phase = _gen_next
		elif _gen_wait > 120:
			_check(false, "generate() timed out waiting for generation_ready (120 frames)")
			_waiting = false
			_candidate = {}
			_phase = _gen_next
			return false
		else:
			return false
	match _phase:
		1:
			_phase1()
		2:
			_phase2()
			_finish()
			return true
		_:
			_finish()
			return true
	return false
