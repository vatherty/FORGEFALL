# tools/verify_invented_hooks.gd — WORKER C verification for FORGEFALL v0.5.3
# (invented hooks, Worker A + Forge MAKE mode, Worker B).
# Usage: godot --headless --path <project> --script res://tools/verify_invented_hooks.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Verifies with MOCKED generation only (ModCreator.mock_generation) — no
# network, no real key, no silent fallback anywhere on these paths.
# Verifies, does not fix: game code is never modified here.
#
# Coverage:
#  (1) Custom projectile hook fires in-game headlessly: installed Long
#      Laser Pistol (p9 + projectile_spawn hook, beam visual) built
#      through the REAL gate (ForgeLLM.validate_modspec) + build
#      (ForgeBuilder.build) pair -> weapon carries the mod's hooks +
#      projectile spec -> _attempt_fire spawns a ModProjectile with the
#      mod's voxel visual + speed + damage -> it flies, hits a dummy,
#      lands its damage. Watermelon LMG variant: explodes on impact
#      (ModProjectile._exploded set, dummy takes the spec damage).
#  (2) Invented-hook case: "a weapon that heals me on kill" -> mocked
#      generation invents an on_kill heal hook -> validator accepts it
#      -> approval preview lists it explicitly -> install works -> it
#      functions in the sandbox (SandboxTestRoom.simulate_test: healed)
#      AND in-game (hitscan kill -> player HP +15). A script mod's
#      get_hooks() path is covered too, plus a CODE hook (extends
#      ModHook, run via ModAPI) that heals.
#  (3) Forbidden-API still blocked: an invented hook carrying hook
#      "code" with FileAccess is REJECTED with a visible error naming
#      the forbidden API; a script mod with OS.execute in its hook
#      code is likewise REJECTED; install() refuses both and NO file
#      is written to user://mods/.
#  (4) Forge MAKE one-box: a mocked cover-block candidate applied via
#      ForgeSessionMake.apply_candidate builds a session node and
#      writes NO file to user://mods/ (tree snapshot before/after).
#      A script candidate is REFUSED with a visible message naming
#      Create-a-Mod; forge_menu.gd calls .install() nowhere on the
#      MAKE path. MAKE weapon check: a MAKE'd weapon mod's hooks must
#      survive (ForgeSessionMake header: a MAKE'd block behaves
#      identically to an installed one for this match) — see result.
#  (5) Creator still saves permanent mods: installed test mods survive
#      ModLoader.rescan(); generate-without-install writes nothing;
#      empty idea -> visible error, no candidate, no write; an error
#      candidate applied via MAKE returns the error, never a preset.
#  (6) Documented limits (verified as limits, NOT failures): no builtin
#      Long Laser Pistol shipped; on_damage_taken damage_mult > 1 is
#      ignored by the WeaponManager HP-drop poll (mult < 1 heals back
#      the reduced portion); turret damage hooks not wired
#      (forge_turret.gd has no ModHook references); forge_llm.gd has
#      no ModHook references (hooks live in ModCreator's addendum).
#  Entry point preserved: ModCreator.generate(idea: String) + signal
#  generation_ready(candidate); HOOK_PROMPT_ADDENDUM is appended on
#  the network path (source-level: the mock path is unaffected).
#
# Isolation: user://mods/ + user://mods_enabled.json are backed up to
# user://_v053_verify_backup_* at start, wiped for the run, and
# restored in _cleanup() on EVERY exit path. ModCreator.mock_generation
# is reset to {} before quit.
extends SceneTree

# --- Fake actors ------------------------------------------------------------

class FakePlayer extends Node3D:
	var _hp := 100.0
	var _look := Vector2.ZERO

	func heal(amount: float) -> void:
		_hp = minf(_hp + amount, 100.0)

	func add_look(v: Vector2) -> void:
		_look += v


class Dummy extends StaticBody3D:
	var hp := 100.0
	var dead := false
	var last_damage := 0.0

	func _init() -> void:
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4, 4, 1)
		cs.shape = box
		add_child(cs)

	func take_damage(dmg: float, _pos: Vector3, _head: bool) -> void:
		last_damage = dmg
		hp -= dmg
		if hp <= 0.0:
			dead = true

	func is_dead() -> bool:
		return dead


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
var _hook_script: GDScript = null
var _registry_script: GDScript = null
var _builder_script: GDScript = null
var _llm_script: GDScript = null
var _arsenal_script: GDScript = null
var _session_make_script: GDScript = null
var _sandbox_script: GDScript = null
var _wm_script: GDScript = null

var _cam: Camera3D = null
var _player: FakePlayer = null
var _wm: Node = null
var _dummy: Dummy = null

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _had_mods := false
var _had_enabled := false

var _cand_laser: Dictionary = {}
var _cand_vampire: Dictionary = {}
var _laser_proj: Node = null
var _melon_proj: Node = null
var _proj_frames := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


# --- Backup / restore (same pattern as verify_v08_create.gd) ---------------

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
	_backup_abs = _user_dir.path_join("_v053_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v053_verify_backup_enabled.json")
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


# --- Mock generations (RAW generation shape, as the LLM would return) -----

func _mock_laser() -> Dictionary:
	var block := {
		"block_id": "placeholder_block", "target": "weapon", "cost": 300,
		"display_name": "Long Laser Pistol",
		"description": "A pistol that fires a glowing laser beam.",
		"base_weapon_id": "p9",
	}
	var hooks := [{
		"hook_id": "laser_beam_shot", "hook_point": "projectile_spawn",
		"display_name": "Laser Beam Shot",
		"description": "Fires a glowing laser beam instead of bullets.",
		"projectile": {"visual": "glowing laser beam", "shape": "beam",
			"speed": 60.0, "damage": 45.0, "range": 120.0, "size": 1.0,
			"gravity": 0.0, "pierce": false, "explodes_on_impact": false},
	}]
	return {"manifest": {"name": "Long Laser Pistol", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify({"block": block, "hooks": hooks}),
		"summary": "A pistol that fires a glowing laser beam. Adds a new hook: laser_beam_shot (projectile_spawn)."}


func _mock_melon() -> Dictionary:
	var block := {
		"block_id": "placeholder_block", "target": "weapon", "cost": 350,
		"display_name": "Watermelon LMG",
		"description": "An LMG that lobs exploding watermelons.",
		"base_weapon_id": "lmg",
	}
	var hooks := [{
		"hook_id": "watermelon_rounds", "hook_point": "projectile_spawn",
		"display_name": "Watermelon Rounds",
		"description": "Fires watermelons that explode on impact.",
		"projectile": {"visual": "watermelon", "shape": "sphere",
			"speed": 28.0, "damage": 40.0, "range": 90.0, "size": 1.0,
			"gravity": 0.0, "pierce": false, "explodes_on_impact": true,
			"explosion_radius": 4.0, "explosion_damage": 60.0},
	}]
	return {"manifest": {"name": "Watermelon LMG", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify({"block": block, "hooks": hooks}),
		"summary": "An LMG that fires exploding watermelons."}


func _mock_vampire() -> Dictionary:
	var block := {
		"block_id": "placeholder_block", "target": "weapon", "cost": 280,
		"display_name": "Vampire Fang",
		"description": "A weapon that heals me on kill.",
		"base_weapon_id": "p9",
	}
	var hooks := [{
		"hook_id": "vampire_heal", "hook_point": "on_kill",
		"display_name": "Vampire Heal",
		"description": "Heals the wielder when a shot kills its target.",
		"effects": [{"kind": "heal", "amount": 15.0}],
	}]
	return {"manifest": {"name": "Vampire Fang", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify({"block": block, "hooks": hooks}),
		"summary": "A weapon that heals me on kill. Adds a new hook: vampire_heal (on_kill)."}


func _mock_script_hooks() -> Dictionary:
	var script_text := (
		"extends ModBlock\n" +
		"\n" +
		"func get_block_info() -> Dictionary:\n" +
		"\treturn {\"block_id\": \"verify_script_hooks\", \"target\": \"weapon\", \"cost\": 200, \"display_name\": \"Verify Script Hooks\", \"description\": \"Script mod with get_hooks.\", \"base_weapon_id\": \"p9\"}\n" +
		"\n" +
		"func get_hooks() -> Array:\n" +
		"\treturn [{\"hook_id\": \"script_heal\", \"hook_point\": \"on_kill\", \"display_name\": \"Script Heal\", \"description\": \"Heal on kill from script.\", \"effects\": [{\"kind\": \"heal\", \"amount\": 10.0}]}]\n" +
		"\n" +
		"func apply(api: ModAPI, params: Dictionary) -> String:\n" +
		"\treturn \"built\"\n")
	return {"manifest": {"name": "Verify Script Hooks", "kind": "script",
			"version": "1.0", "author": "verify"},
		"payload": script_text,
		"summary": "A script mod whose get_hooks() returns a heal-on-kill hook."}


func _mock_forbidden_hook_code() -> Dictionary:
	var hook_code := (
		"extends ModHook\n" +
		"func run(api: ModAPI, ctx: Dictionary) -> Dictionary:\n" +
		"\tvar f = FileAccess.open(\"user://evil.txt\", FileAccess.WRITE)\n" +
		"\treturn {}\n")
	var block := {
		"block_id": "placeholder_block", "target": "weapon", "cost": 100,
		"display_name": "Verify Evil Hook",
		"description": "Hook code tries the filesystem.",
		"base_weapon_id": "p9",
	}
	var hooks := [{
		"hook_id": "evil_hook", "hook_point": "on_kill",
		"display_name": "Evil Hook",
		"description": "Tries to touch the filesystem.",
		"code": hook_code,
	}]
	return {"manifest": {"name": "Verify Evil Hook", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify({"block": block, "hooks": hooks}),
		"summary": "A mod whose invented hook code touches the filesystem."}


func _mock_forbidden_script() -> Dictionary:
	var script_text := (
		"extends ModBlock\n" +
		"\n" +
		"func get_block_info() -> Dictionary:\n" +
		"\treturn {\"block_id\": \"verify_evil_script\", \"target\": \"weapon\", \"cost\": 100, \"display_name\": \"Verify Evil Script\", \"description\": \"Forbidden.\", \"base_weapon_id\": \"p9\"}\n" +
		"\n" +
		"func get_hooks() -> Array:\n" +
		"\treturn [{\"hook_id\": \"evil_script_hook\", \"hook_point\": \"on_kill\", \"display_name\": \"Evil\", \"description\": \"Runs a shell command.\", \"code\": \"extends ModHook\\nfunc run(api, ctx):\\n\\tOS.execute(\\\"echo\\\", [])\\n\\treturn {}\"}]\n" +
		"\n" +
		"func apply(api: ModAPI, params: Dictionary) -> String:\n" +
		"\treturn \"should never run\"\n")
	return {"manifest": {"name": "Verify Evil Script", "kind": "script",
			"version": "1.0", "author": "verify"},
		"payload": script_text,
		"summary": "A script mod whose hook code tries to run a shell command."}


func _mock_make_wall() -> Dictionary:
	var block := {
		"block_id": "placeholder_block", "target": "cover", "cost": 120,
		"display_name": "Chunky Concrete Wall",
		"description": "A chunky concrete wall for this match only.",
		"shape": "wall", "size_voxels": [4, 3, 1], "hp": 200.0,
	}
	return {"manifest": {"name": "Chunky Concrete Wall", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify(block),
		"summary": "A chunky concrete wall."}


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


func _current_weapon() -> Node:
	var weapons: Dictionary = _wm.get("_weapons")
	return weapons.get("primary")


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


func _fire_current() -> void:
	var w := _current_weapon()
	w.set("_raise_t", 999.0)
	w.set("_cooldown", 0.0)
	w.call("_attempt_fire")


func _find_projectile(node: Node) -> Node:
	for c in node.get_children():
		var scr: Variant = c.get_script()
		if scr is GDScript and str((scr as GDScript).resource_path).ends_with("mod_projectile.gd"):
			return c
		var found := _find_projectile(c)
		if found != null:
			return found
	return null


func _reset_dummy(hp: float) -> void:
	_dummy.hp = hp
	_dummy.dead = false
	_dummy.last_damage = 0.0


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
	_session_make_script = load("res://scripts/forge/forge_session_make.gd")
	_sandbox_script = load("res://scripts/ui/sandbox_test_room.gd")
	_wm_script = load("res://scripts/weapons/weapon_manager.gd")

	# Entry-point contract (source-level): generate + signal intact.
	var creator_src := FileAccess.get_file_as_string("res://scripts/mods/mod_creator.gd")
	_check(creator_src.contains("func generate(idea: String)"),
		"contract: ModCreator.generate(idea: String) signature preserved")
	_check(creator_src.contains("signal generation_ready(candidate"),
		"contract: ModCreator.generation_ready(candidate) signal preserved")
	_check(creator_src.contains("HOOK_PROMPT_ADDENDUM") and creator_src.contains("request_generation(clean"),
		"contract: HOOK_PROMPT_ADDENDUM appended on the network path")

	# No builtin Long Laser Pistol shipped (documented limit).
	_loader_script.call("rescan")
	var pre: Dictionary = _loader_script.call("find_mod", "long_laser_pistol", false)
	_check((pre as Dictionary).is_empty(),
		"limit: no builtin 'long_laser_pistol' mod ships (find_mod empty before install)")

	# Camera + fake player + WeaponManager + dummy, all under the root.
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
	_dummy = Dummy.new()
	_dummy.name = "Dummy"
	_dummy.position = Vector3(0, 0, -5)
	root.add_child(_dummy)

	_creator = _creator_script.new()
	root.add_child(_creator)
	_creator.connect("generation_ready", _on_generation_ready)

	_phase = 1
	_sub = 0


# --- Phase 1: Long Laser Pistol — generate + validate + install ------------

func _phase1() -> void:
	if _sub == 0:
		_sub = 1
		_request_generate(_mock_laser(), 1)
		return
	# _sub == 1: candidate arrived.
	var err := str(_candidate.get("error", ""))
	_check(err == "", "laser(1): candidate validates (error='%s')" % err)
	_cand_laser = _candidate.duplicate(true)
	var hooks: Array = _hook_script.call("preview_hooks_for_candidate", _candidate)
	_check(hooks.size() == 1 and str((hooks[0] as Dictionary).get("hook_id", "")) == "laser_beam_shot",
		"laser(1): approval preview finds exactly the invented hook 'laser_beam_shot'")
	var lines: Array = _hook_script.call("summarize_hooks", hooks)
	var joined := "\n".join(lines)
	_check(joined.contains("laser_beam_shot") and joined.contains("projectile_spawn"),
		"laser(1): approval lists the hook explicitly ('%s')" % joined)
	var verr: String = _creator.call("validate", _candidate)
	_check(verr == "", "laser(1): ModCreator.validate() == '' (%s)" % verr)
	var snap_before := _list_mods_tree()
	var ierr: String = _creator.call("install", _candidate)
	_check(ierr == "", "laser(1): install() succeeds ('%s')" % ierr)
	_check(not _list_mods_tree().is_empty(), "laser(1): install() wrote the mod to user://mods/")
	var rec := _mod_record("long_laser_pistol")
	_check(not (rec as Dictionary).is_empty() and str((rec as Dictionary).get("error", "")) == "",
		"laser(1): installed record is error-free")
	var rec_hooks: Array = (rec as Dictionary).get("hooks", [])
	_check(rec_hooks.size() == 1,
		"laser(1): installed record carries 1 validated hook (got %d)" % rec_hooks.size())
	_phase = 2
	_sub = 0


# --- Phase 2: Long Laser Pistol — gate+build, fire, impact ------------------

func _phase2() -> void:
	if _sub == 0:
		_sub = 1
		# Explicit attach API also works (direct, no gate pair).
		var fresh = _arsenal_script.call("make_weapon", "p9")
		var attached: bool = _registry_script.call("attach_mod_to_weapon", fresh, "long_laser_pistol")
		_check(attached and str(fresh.get("mod_id")) == "long_laser_pistol",
			"laser(2): attach_mod_to_weapon() attaches hooks to a fresh weapon")
		fresh.queue_free()
		if not _gate_and_build("long_laser_pistol"):
			_phase = 3
			_sub = 0
			return
		var w := _current_weapon()
		_check(str(w.get("mod_id")) == "long_laser_pistol",
			"laser(2): gate+build weapon carries mod_id 'long_laser_pistol' (got '%s')" % str(w.get("mod_id")))
		var w_hooks: Array = w.get("mod_hooks")
		_check(w_hooks.size() == 1,
			"laser(2): gate+build weapon carries 1 hook (got %d)" % w_hooks.size())
		var pspec: Dictionary = _registry_script.call("resolve_projectile_spec", w)
		_check(str(pspec.get("visual", "")) == "glowing laser beam"
			and is_equal_approx(float(pspec.get("speed", 0.0)), 60.0)
			and is_equal_approx(float(pspec.get("damage", 0.0)), 45.0),
			"laser(2): projectile spec = beam visual, speed 60, damage 45 (got %s)" % str(pspec))
		_reset_dummy(100.0)
		_fire_current()
		_laser_proj = _find_projectile(root)
		_check(_laser_proj != null, "laser(2): firing spawns a ModProjectile in-game")
		if _laser_proj == null:
			_phase = 3
			_sub = 0
			return
		var ps: Dictionary = _laser_proj.get("spec")
		_check(str(ps.get("visual", "")) == "glowing laser beam"
			and is_equal_approx(float(_laser_proj.get("_speed")), 60.0)
			and is_equal_approx(float(_laser_proj.get("_damage")), 45.0),
			"laser(2): spawned projectile carries the mod's visual/speed/damage")
		var visual: Node = _laser_proj.get_node_or_null("ModProjectileVisual")
		_check(visual != null, "laser(2): projectile has a voxel visual node")
		if visual != null:
			_check(is_equal_approx(float((visual as Node3D).scale.z), 2.0),
				"laser(2): beam visual is stretched along flight (scale.z == 2.0, got %s)" % str((visual as Node3D).scale))
		_proj_frames = 0
		return
	# _sub == 1: drive the projectile until it dies.
	_proj_frames += 1
	if _laser_proj != null and is_instance_valid(_laser_proj):
		for i in 30:
			if bool(_laser_proj.get("_dead")):
				break
			_laser_proj.call("step", 0.016)
	var dead := _laser_proj == null or not is_instance_valid(_laser_proj) or bool(_laser_proj.get("_dead"))
	if not dead and _proj_frames < 10:
		return
	_check(dead, "laser(2): projectile finishes (impact or range) within 10 frames")
	_check(is_equal_approx(_dummy.last_damage, 45.0),
		"laser(2): dummy took the mod's 45 damage (got %.1f)" % _dummy.last_damage)
	_check(not bool(_laser_proj.get("_exploded")) if _laser_proj != null and is_instance_valid(_laser_proj) else true,
		"laser(2): non-exploding beam does not detonate")
	if _laser_proj != null and is_instance_valid(_laser_proj):
		_laser_proj.queue_free()
	_laser_proj = null
	_phase = 3
	_sub = 0


# --- Phase 3: Watermelon LMG — exploding projectile --------------------------

func _phase3() -> void:
	if _sub == 0:
		_sub = 1
		_request_generate(_mock_melon(), 3)
		return
	if _sub == 1:
		var err := str(_candidate.get("error", ""))
		_check(err == "", "melon(3): candidate validates (error='%s')" % err)
		var ierr: String = _creator.call("install", _candidate)
		_check(ierr == "", "melon(3): install() succeeds ('%s')" % ierr)
		_sub = 2
		return
	if _sub == 2:
		_sub = 3
		if not _gate_and_build("watermelon_lmg"):
			_phase = 4
			_sub = 0
			return
		var w := _current_weapon()
		var pspec: Dictionary = _registry_script.call("resolve_projectile_spec", w)
		_check(bool(pspec.get("explodes_on_impact", false))
			and is_equal_approx(float(pspec.get("explosion_radius", 0.0)), 4.0),
			"melon(3): projectile spec explodes on impact, radius 4 (got %s)" % str(pspec))
		_reset_dummy(100.0)
		_fire_current()
		_melon_proj = _find_projectile(root)
		_check(_melon_proj != null, "melon(3): firing spawns a ModProjectile in-game")
		if _melon_proj == null:
			_phase = 4
			_sub = 0
			return
		_proj_frames = 0
		return
	# _sub == 3: drive the projectile until it dies.
	_proj_frames += 1
	if _melon_proj != null and is_instance_valid(_melon_proj):
		for i in 30:
			if bool(_melon_proj.get("_dead")):
				break
			_melon_proj.call("step", 0.016)
	var dead := _melon_proj == null or not is_instance_valid(_melon_proj) or bool(_melon_proj.get("_dead"))
	if not dead and _proj_frames < 10:
		return
	_check(dead, "melon(3): projectile finishes within 10 frames")
	_check(is_equal_approx(_dummy.last_damage, 40.0),
		"melon(3): dummy took the mod's 40 damage (got %.1f)" % _dummy.last_damage)
	var exploded := false
	if _melon_proj != null and is_instance_valid(_melon_proj):
		exploded = bool(_melon_proj.get("_exploded"))
		_melon_proj.queue_free()
	_melon_proj = null
	_check(exploded, "melon(3): projectile detonated on impact (_exploded set)")
	_phase = 4
	_sub = 0


# --- Phase 4: heal-on-kill — sandbox + in-game + script get_hooks() --------

func _phase4() -> void:
	if _sub == 0:
		_sub = 1
		_request_generate(_mock_vampire(), 4)
		return
	if _sub == 1:
		var err := str(_candidate.get("error", ""))
		_check(err == "", "vampire(4): candidate validates (error='%s')" % err)
		_cand_vampire = _candidate.duplicate(true)
		var hooks: Array = _hook_script.call("preview_hooks_for_candidate", _candidate)
		var lines: Array = _hook_script.call("summarize_hooks", hooks)
		var joined := "\n".join(lines)
		_check(joined.contains("vampire_heal") and joined.contains("on_kill"),
			"vampire(4): approval lists invented hook 'vampire_heal (on_kill)' explicitly")
		var ierr: String = _creator.call("install", _candidate)
		_check(ierr == "", "vampire(4): install() succeeds ('%s')" % ierr)
		# Sandbox: the invented hook is EXERCISED, not just declared.
		var behavior := {"projectile": true, "hooks": hooks,
			"projectile_spec": {"visual": "fang", "speed": 30.0, "damage": 22.0,
				"explodes_on_impact": false}}
		var sim: Dictionary = _sandbox_script.call("simulate_test", {}, {"voxel_count": 6}, behavior)
		_check(bool(sim.get("hit", false)) and bool(sim.get("healed", false))
			and is_equal_approx(float(sim.get("heal_on_kill", 0.0)), 15.0)
			and "vampire_heal" in (sim.get("hooks_run", []) as Array),
			"vampire(4): sandbox exercises the hook (hit, healed +15, hooks_run has vampire_heal)")
		_check(not bool(sim.get("wrote_to_mod_list", true)),
			"vampire(4): sandbox writes nothing to the mod list")
		_sub = 2
		return
	if _sub == 2:
		_sub = 3
		# Code hook (extends ModHook, ModAPI-only) heals through the registry.
		var code_hook := {"hook_id": "code_heal", "hook_point": "on_kill",
			"display_name": "Code Heal", "description": "Heals via hook code.",
			"code": "extends ModHook\nfunc run(api: ModAPI, ctx: Dictionary) -> Dictionary:\n\tapi.heal_player(5.0)\n\treturn {\"healed\": 5.0}\n"}
		var code_err: String = _hook_script.call("validate_hook_data", code_hook)
		_check(code_err == "", "vampire(4): code hook (extends ModHook, ModAPI-only) validates ('%s')" % code_err)
		if code_err == "":
			_player._hp = 50.0
			var api_script := load("res://scripts/mods/mod_api.gd")
			var api = api_script.new(_player, root)
			var res: Dictionary = _registry_script.call("run_hooks", [code_hook], "on_kill", api, {})
			_check(is_equal_approx(float(res.get("healed", 0.0)), 5.0)
				and is_equal_approx(_player._hp, 55.0),
				"vampire(4): code hook runs through the registry (healed 5, HP 50 -> 55)")
		if not _gate_and_build("vampire_fang"):
			_phase = 5
			_sub = 0
			return
		_player._hp = 50.0
		_reset_dummy(10.0)
		_fire_current()
		_check(_dummy.dead, "vampire(4): in-game hitscan shot kills the dummy")
		_check(is_equal_approx(_player._hp, 65.0),
			"vampire(4): in-game on_kill hook heals +15 (HP 50 -> %.1f)" % _player._hp)
		_sub = 4
		return
	if _sub == 4:
		_sub = 5
		_request_generate(_mock_script_hooks(), 4)
		return
	# _sub == 5: script-mod candidate arrived.
	var err2 := str(_candidate.get("error", ""))
	_check(err2 == "", "vampire(4): script-mod candidate validates (error='%s')" % err2)
	var ierr2: String = _creator.call("install", _candidate)
	_check(ierr2 == "", "vampire(4): script-mod install() succeeds ('%s')" % ierr2)
	var rec := _mod_record("verify_script_hooks")
	var rec_hooks: Array = (rec as Dictionary).get("hooks", [])
	_check(rec_hooks.size() == 1 and str((rec_hooks[0] as Dictionary).get("hook_id", "")) == "script_heal",
		"vampire(4): script mod's get_hooks() hook lands on the installed record")
	_phase = 5
	_sub = 0


# --- Phase 5: forbidden API rejected + empty idea ---------------------------

func _phase5() -> void:
	if _sub == 0:
		_sub = 1
		_request_generate(_mock_forbidden_hook_code(), 5)
		return
	if _sub == 1:
		var err := str(_candidate.get("error", ""))
		_check(err != "" and err.to_lower().contains("forbidden"),
			"forbidden(5): hook code with FileAccess REJECTED with a visible error ('%s')" % err)
		_check(err.contains("FileAccess"),
			"forbidden(5): rejection names the forbidden API ('%s')" % err)
		var snap := _list_mods_tree()
		var ierr: String = _creator.call("install", _candidate)
		_check(ierr != "", "forbidden(5): install() refuses the rejected candidate ('%s')" % ierr)
		_check(_list_mods_tree() == snap,
			"forbidden(5): rejected candidate writes NO file to user://mods/")
		_sub = 2
		return
	if _sub == 2:
		_sub = 3
		_request_generate(_mock_forbidden_script(), 5)
		return
	if _sub == 3:
		var err := str(_candidate.get("error", ""))
		_check(err != "" and err.to_lower().contains("forbidden"),
			"forbidden(5): script mod with OS.execute REJECTED ('%s')" % err)
		var ierr: String = _creator.call("install", _candidate)
		_check(ierr != "", "forbidden(5): install() refuses the OS.execute candidate")
		_sub = 4
		return
	if _sub == 4:
		_sub = 5
		# Empty idea, no mock: visible error, never a silent fallback.
		_creator_script.set("mock_generation", {})
		_got = false
		_candidate = {}
		_gen_wait = 0
		_gen_next = 5
		_waiting = true
		_creator.call("generate", "")
		return
	# _sub == 5: empty-idea candidate arrived.
	var err := str(_candidate.get("error", ""))
	_check(err != "" and err.contains("describe the mod"),
		"forbidden(5): empty idea -> visible error, no silent fallback ('%s')" % err)
	_phase = 6
	_sub = 0


# --- Phase 6: Forge MAKE ----------------------------------------------------

func _phase6() -> void:
	if _sub == 0:
		_sub = 1
		_request_generate(_mock_make_wall(), 6)
		return
	if _sub == 1:
		var err := str(_candidate.get("error", ""))
		_check(err == "", "make(6): MAKE cover candidate validates (error='%s')" % err)
		var snap_before := _list_mods_tree()
		var before_count := root.get_child_count()
		var result: Dictionary = _session_make_script.call("apply_candidate", _candidate, _player, root)
		_check(bool(result.get("ok", false)),
			"make(6): MAKE builds the session cover in-match ('%s')" % str(result.get("message", "")))
		_check(_list_mods_tree() == snap_before,
			"make(6): MAKE writes NO file to user://mods/ (tree unchanged)")
		var built: Variant = _builder_script.get("last_built_node")
		_check(built != null and is_instance_valid(built),
			"make(6): MAKE produced a live session node (last_built_node set)")
		_sub = 2
		return
	if _sub == 2:
		_sub = 3
		# v0.5.9: script candidates BUILD in-session (session code
		# loading) — the old "MAKE refuses script mods" refusal is gone.
		# A bare "extends ModBlock" candidate still fails, but for a
		# CONTENT reason (validation/compile), never a blanket refusal
		# to run scripts.
		var script_cand := {"mod_id": "verify_script_hooks", "name": "Verify Script Hooks",
			"kind": "script", "manifest": {}, "payload": "extends ModBlock",
			"summary": "script", "error": ""}
		var result: Dictionary = _session_make_script.call("apply_candidate", script_cand, _player, root)
		_check(not str(result.get("message", "")).to_lower().contains("can't run script mods")
			and not str(result.get("message", "")).to_lower().contains("refuses script"),
			"make(6): no blanket script refusal remains ('%s')" % str(result.get("message", "")))
		# An error candidate is reported, never silently replaced.
		var err_cand := {"mod_id": "", "name": "", "kind": "block", "manifest": {},
			"payload": "", "summary": "", "error": "generation exploded"}
		var result2: Dictionary = _session_make_script.call("apply_candidate", err_cand, _player, root)
		_check(not bool(result2.get("ok", false))
			and str(result2.get("message", "")).contains("generation exploded"),
			"make(6): MAKE surfaces an error candidate's message, no silent preset fallback")
		# Unknown target: visible failure, no build.
		var bad_cand := {"mod_id": "x", "name": "X", "kind": "block",
			"manifest": {}, "payload": JSON.stringify({"block_id": "x", "target": "nope",
				"cost": 0, "display_name": "X"}),
			"summary": "x", "error": ""}
		var result3: Dictionary = _session_make_script.call("apply_candidate", bad_cand, _player, root)
		_check(not bool(result3.get("ok", false)),
			"make(6): MAKE rejects an unknown target ('%s')" % str(result3.get("message", "")))
		# Menu-level: the MAKE path never calls install(), and no
		# script refusal text remains (v0.5.9 session loading).
		var menu_src := FileAccess.get_file_as_string("res://scripts/ui/forge_menu.gd")
		_check(not menu_src.contains(".install("),
			"make(6): forge_menu.gd contains no .install() call (MAKE never installs)")
		_check(not menu_src.contains("MAKE can't run script mods"),
			"make(6): forge_menu.gd carries no script-refusal text")
		_check(menu_src.contains("MAKE (this match only"),
			"make(6): MAKE UI is labeled 'MAKE (this match only — not saved)'")
		_sub = 4
		return
	if _sub == 4:
		# MAKE'd weapon mod: hooks must survive, per the ForgeSessionMake
		# header (a MAKE'd block behaves identically to an installed one).
		_loader_script.call("clear_find_history")
		var result: Dictionary = _session_make_script.call("apply_candidate", _cand_laser, _player, root)
		_check(bool(result.get("ok", false)),
			"make(6): MAKE builds the session laser weapon ('%s')" % str(result.get("message", "")))
		var w := _current_weapon()
		var w_hooks: Array = w.get("mod_hooks")
		_check(w_hooks.size() == 1 and str(w.get("mod_id")) == "long_laser_pistol",
			"make(6): MAKE'd weapon keeps its mod hooks (hooks=%d, mod_id='%s')" % [w_hooks.size(), str(w.get("mod_id"))])
		var pspec: Dictionary = _registry_script.call("resolve_projectile_spec", w)
		_check(str(pspec.get("visual", "")) == "glowing laser beam",
			"make(6): MAKE'd weapon resolves the mod projectile spec (got %s)" % str(pspec))
		_phase = 7
		_sub = 0


# --- Phase 7: documented limits + persistence + no silent fallback ----------

func _phase7() -> void:
	# on_damage_taken poll: damage_mult > 1 ignored; < 1 heals back.
	var wm = _wm_script.new()
	var vuln_hooks := [{"hook_id": "vuln", "hook_point": "on_damage_taken",
		"display_name": "Vuln", "description": "x",
		"effects": [{"kind": "damage_mult", "value": 2.0}]}]
	var w = _arsenal_script.call("make_weapon", "p9")
	w.call("set_mod", "vuln_test", {}, vuln_hooks)
	wm.set("_player", _player)
	wm.set("_current", w)
	_player._hp = 60.0
	wm.set("_last_player_hp", 80.0)
	wm.call("_poll_damage_taken")
	_check(is_equal_approx(_player._hp, 60.0),
		"limit(7): on_damage_taken damage_mult > 1 ignored by the poll (HP stays 60, got %.1f)" % _player._hp)
	var guard_hooks := [{"hook_id": "guard", "hook_point": "on_damage_taken",
		"display_name": "Guard", "description": "x",
		"effects": [{"kind": "damage_mult", "value": 0.5}]}]
	w.call("set_mod", "guard_test", {}, guard_hooks)
	_player._hp = 60.0
	wm.set("_last_player_hp", 80.0)
	wm.call("_poll_damage_taken")
	_check(is_equal_approx(_player._hp, 70.0),
		"limit(7): on_damage_taken damage_mult 0.5 heals back half the drop (HP 60 -> %.1f)" % _player._hp)
	wm.free()
	w.queue_free()

	# Turret damage hooks not wired (documented limit, source-level).
	var turret_src := FileAccess.get_file_as_string("res://scripts/forge/forge_turret.gd")
	_check(not turret_src.contains("ModHook") and not turret_src.contains("mod_hooks"),
		"limit(7): turret damage hooks not wired (forge_turret.gd has no ModHook references)")
	# forge_llm.gd untouched by the hooks work (source-level).
	var llm_src := FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	_check(not llm_src.contains("ModHook"),
		"limit(7): forge_llm.gd untouched (no ModHook references)")
	# ModAPI hook surface exists.
	var api_src := FileAccess.get_file_as_string("res://scripts/mods/mod_api.gd")
	_check(api_src.contains("func get_player_health") and api_src.contains("func heal_player")
		and api_src.contains("func spawn_projectile"),
		"limit(7): ModAPI hook surface present (get_player_health / heal_player / spawn_projectile)")
	# Creator still saves permanent mods: installed mods survive rescan.
	_loader_script.call("rescan")
	for mid in ["long_laser_pistol", "watermelon_lmg", "vampire_fang", "verify_script_hooks"]:
		var rec := _mod_record(mid)
		_check(not (rec as Dictionary).is_empty() and str((rec as Dictionary).get("error", "")) == "",
			"persist(7): '%s' still installed + error-free after rescan" % mid)
	# Approval lists hooks in the creator menu (source-level wiring).
	var menu_src := FileAccess.get_file_as_string("res://scripts/ui/mod_creator_menu.gd")
	_check(menu_src.contains("summarize_hooks") and menu_src.contains("_approval_hooks.text"),
		"persist(7): creator menu approval wires summarize_hooks into _approval_hooks")
	_phase = 8


func _finish() -> void:
	_cleanup()
	print("INVENTED_HOOKS VERIFY: %d checks, %d passes, %d failures" % [_passes + _fails, _passes, _fails])
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
			# Fall through to run the continuation phase this frame.
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
		3:
			_phase3()
		4:
			_phase4()
		5:
			_phase5()
		6:
			_phase6()
		7:
			_phase7()
			_finish()
			return true
		_:
			_finish()
			return true
	return false
