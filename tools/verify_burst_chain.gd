# tools/verify_burst_chain.gd — v0.5.11 verification: burst + chain + hooks-nesting schema fix.
# Usage: godot --headless --path <project> --script res://tools/verify_burst_chain.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Verifies with MOCKED generation only (ModCreator.mock_generation) — no
# network, no real key, no silent fallback anywhere on these paths.
#
# Coverage:
# (1) SCHEMA: the payload shapes the prompt documents ALL validate for
#     EVERY target (weapon/cover/structure/turret/pickup): wrapper with
#     top-level hooks, wrapper with hooks NESTED inside the block (the
#     shape that failed Colin with "unknown block field 'hooks' for
#     target 'weapon'"), wrapper with hooks in BOTH places (deduped),
#     and a flat block with a top-level hooks key. This is the
#     schema/prompt consistency check: every shape the prompt
#     advertises is accepted by the validator for every target.
#     Negatives: unknown block fields still rejected; bad fire_mode /
#     burst_size / chain_* / element still rejected; forbidden-API
#     hook code still rejected with the API named.
#     Prompt consistency (source-level): the BLOCK SCHEMA + the hooks
#     addendum document the canonical hooks placement, fire_mode /
#     burst_size, and the chain fields.
# (2) END-TO-END (mocked generation, nested-hooks shape): "3-round
#     burst lightning gun, fast, chains to nearby enemies" via the
#     Create tab path (generate) AND the chat path
#     (generate_with_context) -> candidate validates -> install ->
#     record error-free with fire_mode burst + burst_size 3 + the
#     chain projectile spec. Approval preview lists the hook.
# (3) IN-GAME: Arsenal make_weapon("mod:burst_lightning") carries
#     fire_mode BURST + burst_size 3 + the chain spec (Arsenal path);
#     the Forge grant path applies fire_mode/burst_size too; ONE
#     trigger press fires exactly 3 projectiles; each hits dummy1
#     for 30 and chains to dummy2 for 15 (30 * 0.5 falloff).
#
# Isolation: user://mods/ + user://mods_enabled.json are backed up to
# user://_v0511_verify_backup_* at start, wiped for the run, and
# restored in _cleanup() on EVERY exit path. ModCreator.mock_generation
# is reset to {} before quit.
extends SceneTree


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
var _wm_script: GDScript = null

var _cam: Camera3D = null
var _player: FakePlayer = null
var _wm: Node = null
var _dummy1: Dummy = null
var _dummy2: Dummy = null

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _had_mods := false
var _had_enabled := false


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


# --- Backup / restore (same pattern as verify_invented_hooks.gd) ----------

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
	_backup_abs = _user_dir.path_join("_v0511_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v0511_verify_backup_enabled.json")
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


# --- Mock generation: the burst lightning gun, hooks NESTED in the block ---

func _mock_burst_lightning() -> Dictionary:
	var hook := {"hook_id": "burst_chain_lightning", "hook_point": "projectile_spawn",
		"display_name": "Burst Chain Lightning",
		"description": "Fires fast 3-round bursts of chaining lightning bolts.",
		"projectile": {"visual": "glowing lightning bolt", "shape": "beam",
			"speed": 60.0, "damage": 30.0, "range": 120.0, "size": 1.0,
			"gravity": 0.0, "pierce": false, "explodes_on_impact": false,
			"element": "lightning", "chain_targets": 2, "chain_radius": 4.0,
			"chain_falloff": 0.5}}
	# NESTED hooks: the exact shape that failed Colin ("unknown block
	# field 'hooks' for target 'weapon'"). The payload is the wrapper
	# {"block": {...}} with hooks INSIDE the block object.
	var block := {"block_id": "burst_lightning", "target": "weapon", "cost": 300,
		"display_name": "Burst Lightning",
		"description": "3-round burst lightning gun, fast, chains to nearby enemies.",
		"base_weapon_id": "lmg", "damage_mult": 1.0, "mag_mult": 1.0,
		"range_mult": 1.0, "fire_mode": "burst", "burst_size": 3,
		"hooks": [hook]}
	return {"manifest": {"name": "Burst Lightning", "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify({"block": block}),
		"summary": "3-round burst lightning gun. Adds hook: burst_chain_lightning (projectile_spawn, chains to 2 nearby enemies)."}


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


func _find_projectiles(node: Node, out: Array) -> void:
	for c in node.get_children():
		var scr: Variant = c.get_script()
		if scr is GDScript and str((scr as GDScript).resource_path).ends_with("mod_projectile.gd"):
			out.append(c)
		_find_projectiles(c, out)


func _reset_dummies() -> void:
	for d in [_dummy1, _dummy2]:
		d.hp = 100.0
		d.dead = false
		d.last_damage = 0.0


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
	_wm_script = load("res://scripts/weapons/weapon_manager.gd")

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
	# Dummy1: primary target, dead ahead. Dummy2: chain target — offset
	# in X AND Z so the -Z ray hits dummy1 first (nearer front face),
	# and within chain_radius 4 of dummy1. Both in group "enemy" so
	# the chain scan finds them.
	_dummy1 = Dummy.new()
	_dummy1.name = "Dummy1"
	_dummy1.position = Vector3(0, 0, -5)
	_dummy1.add_to_group("enemy")
	root.add_child(_dummy1)
	_dummy2 = Dummy.new()
	_dummy2.name = "Dummy2"
	_dummy2.position = Vector3(1.5, 0, -6)
	_dummy2.add_to_group("enemy")
	root.add_child(_dummy2)

	_creator = _creator_script.new()
	root.add_child(_creator)
	_creator.connect("generation_ready", _on_generation_ready)

	_phase = 1
	_sub = 0


# --- Phase 1: schema matrix + negatives + prompt consistency ----------------

func _block_for_target(target: String) -> Dictionary:
	match target:
		"weapon":
			return {"block_id": "probe_weapon", "target": "weapon", "cost": 100,
				"display_name": "Probe Weapon", "description": "Probe.",
				"base_weapon_id": "p9"}
		"cover":
			return {"block_id": "probe_cover", "target": "cover", "cost": 100,
				"display_name": "Probe Cover", "description": "Probe.",
				"shape": "wall", "size_voxels": [4, 3, 1], "hp": 200.0}
		"structure":
			return {"block_id": "probe_structure", "target": "structure", "cost": 100,
				"display_name": "Probe Structure", "description": "Probe.",
				"shape": "bridge", "property": "standard"}
		"turret":
			return {"block_id": "probe_turret", "target": "turret", "cost": 100,
				"display_name": "Probe Turret", "description": "Probe.",
				"duration_sec": 30.0}
		"pickup":
			return {"block_id": "probe_pickup", "target": "pickup", "cost": 100,
				"display_name": "Probe Pickup", "description": "Probe.",
				"kind": "ammo", "amount": 50}
	return {}


func _phase1() -> void:
	var manifest := {"name": "Probe", "kind": "block", "version": "1.0"}
	var hook := {"hook_id": "schema_probe", "hook_point": "on_hit",
		"display_name": "Probe", "description": "Probe.",
		"effects": [{"kind": "announce", "title": "Hit", "subtitle": "Probe"}]}
	# Schema/prompt consistency: every payload shape the prompt
	# documents validates for EVERY target.
	for target in ["weapon", "cover", "structure", "turret", "pickup"]:
		var base := _block_for_target(target)
		# Shape 1: wrapper, hooks at TOP level (prompt-canonical).
		var p1 := {"block": base.duplicate(true), "hooks": [hook.duplicate(true)]}
		var e1: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify(p1))
		_check(e1 == "", "schema(1): %s wrapper-top-hooks validates (error='%s')" % [target, e1])
		# Shape 2: wrapper, hooks NESTED inside the block (Colin's failure).
		var b2 := base.duplicate(true)
		b2["hooks"] = [hook.duplicate(true)]
		var p2 := {"block": b2}
		var e2: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify(p2))
		_check(e2 == "", "schema(1): %s wrapper-nested-hooks validates (error='%s')" % [target, e2])
		# Shape 3: wrapper, hooks in BOTH places (identical — deduped).
		var b3 := base.duplicate(true)
		b3["hooks"] = [hook.duplicate(true)]
		var p3 := {"block": b3, "hooks": [hook.duplicate(true)]}
		var e3: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify(p3))
		_check(e3 == "", "schema(1): %s wrapper-both-hooks validates, deduped (error='%s')" % [target, e3])
		# Shape 4: flat block with a top-level hooks key.
		var p4 := base.duplicate(true)
		p4["hooks"] = [hook.duplicate(true)]
		var e4: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify(p4))
		_check(e4 == "", "schema(1): %s flat-with-hooks validates (error='%s')" % [target, e4])
	# Negatives: the allowlist still bites on genuinely bad input.
	var bad_block := _block_for_target("weapon")
	bad_block["frobnicate"] = 1
	var eb: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify({"block": bad_block}))
	_check(eb != "" and eb.contains("frobnicate"),
		"schema(1): unknown block field still rejected ('%s')" % eb)
	var bad_fm := _block_for_target("weapon")
	bad_fm["fire_mode"] = "hyper"
	var efm: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify({"block": bad_fm}))
	_check(efm != "" and efm.contains("fire_mode"),
		"schema(1): bad fire_mode still rejected ('%s')" % efm)
	var bad_bs := _block_for_target("weapon")
	bad_bs["burst_size"] = 11
	var ebs: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify({"block": bad_bs}))
	_check(ebs != "" and ebs.contains("burst_size"),
		"schema(1): burst_size 11 still rejected ('%s')" % ebs)
	var bad_chain := _block_for_target("weapon")
	bad_chain["hooks"] = [{"hook_id": "bad_chain", "hook_point": "projectile_spawn",
		"display_name": "Bad", "description": "Bad.",
		"projectile": {"visual": "x", "chain_targets": 6}}]
	var ech: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify({"block": bad_chain}))
	_check(ech != "" and ech.contains("chain_targets"),
		"schema(1): chain_targets 6 still rejected ('%s')" % ech)
	var bad_radius := _block_for_target("weapon")
	bad_radius["hooks"] = [{"hook_id": "bad_radius", "hook_point": "projectile_spawn",
		"display_name": "Bad", "description": "Bad.",
		"projectile": {"visual": "x", "chain_radius": 20.0}}]
	var era: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify({"block": bad_radius}))
	_check(era != "" and era.contains("chain_radius"),
		"schema(1): chain_radius 20 still rejected ('%s')" % era)
	var bad_falloff := _block_for_target("weapon")
	bad_falloff["hooks"] = [{"hook_id": "bad_falloff", "hook_point": "projectile_spawn",
		"display_name": "Bad", "description": "Bad.",
		"projectile": {"visual": "x", "chain_falloff": 2.0}}]
	var efo: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify({"block": bad_falloff}))
	_check(efo != "" and efo.contains("chain_falloff"),
		"schema(1): chain_falloff 2.0 still rejected ('%s')" % efo)
	var bad_elem := _block_for_target("weapon")
	bad_elem["hooks"] = [{"hook_id": "bad_elem", "hook_point": "projectile_spawn",
		"display_name": "Bad", "description": "Bad.",
		"projectile": {"visual": "x", "element": "plasma"}}]
	var eel: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify({"block": bad_elem}))
	_check(eel != "" and eel.contains("element"),
		"schema(1): element 'plasma' still rejected ('%s')" % eel)
	var bad_code := _block_for_target("weapon")
	bad_code["hooks"] = [{"hook_id": "bad_code", "hook_point": "on_kill",
		"display_name": "Bad", "description": "Bad.",
		"code": "extends ModHook\nfunc run(api, ctx):\n\tvar f = FileAccess.open(\"x\", FileAccess.WRITE)\n\treturn {}\n"}]
	var eco: String = _loader_script.call("validate_generated_mod", manifest, JSON.stringify({"block": bad_code}))
	_check(eco != "" and eco.contains("FileAccess"),
		"schema(1): forbidden-API hook code still rejected, API named ('%s')" % eco)
	# Prompt consistency (source-level): the prompt documents the
	# canonical placement + the new fields, so the model is never told
	# about a field the validator rejects.
	var llm_src := FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	# Note: forge_llm.gd's SYSTEM_PROMPT is a quoted string, so its
	# source carries escaped quotes (\"hooks\"); the runtime prompt
	# the model sees is clean. Check the placement rule by its
	# unquoted words, not by exact quote characters.
	_check(llm_src.contains("NEVER put") and llm_src.contains("ALWAYS lives OUTSIDE")
		and llm_src.contains("fire_mode") and llm_src.contains("burst_size"),
		"prompt(1): BLOCK SCHEMA documents hooks placement + fire_mode + burst_size")
	var creator_src := FileAccess.get_file_as_string("res://scripts/mods/mod_creator.gd")
	_check(creator_src.contains("NEVER put \"hooks\" inside the \"block\" object")
		and creator_src.contains("chain_targets") and creator_src.contains("chain_falloff")
		and creator_src.contains("element"),
		"prompt(1): hooks addendum documents hooks placement + chain fields + element")
	_phase = 2
	_sub = 0


# --- Phase 2: mock generation (nested hooks) -> install ---------------------

func _phase2() -> void:
	if _sub == 0:
		_sub = 1
		_request_generate(_mock_burst_lightning(), 2)
		return
	# _sub == 1: candidate arrived (Create-tab path: generate()).
	var err := str(_candidate.get("error", ""))
	_check(err == "", "gen(2): Create-tab candidate validates (error='%s')" % err)
	var hooks: Array = _hook_script.call("preview_hooks_for_candidate", _candidate)
	_check(hooks.size() == 1 and str((hooks[0] as Dictionary).get("hook_id", "")) == "burst_chain_lightning",
		"gen(2): approval preview finds the invented hook 'burst_chain_lightning' (got %d)" % hooks.size())
	var lines: Array = _hook_script.call("summarize_hooks", hooks)
	var joined := "\n".join(lines)
	_check(joined.contains("burst_chain_lightning") and joined.contains("projectile_spawn"),
		"gen(2): approval lists the hook explicitly ('%s')" % joined)
	var ierr: String = _creator.call("install", _candidate)
	_check(ierr == "", "gen(2): install() succeeds ('%s')" % ierr)
	var rec := _mod_record("burst_lightning")
	_check(not (rec as Dictionary).is_empty() and str((rec as Dictionary).get("error", "")) == "",
		"gen(2): installed record is error-free")
	var info: Dictionary = (rec as Dictionary).get("block_info", {})
	_check(str(info.get("fire_mode", "")) == "burst" and int(info.get("burst_size", 0)) == 3,
		"gen(2): installed block_info carries fire_mode burst + burst_size 3 (got %s)" % str(info))
	var rec_hooks: Array = (rec as Dictionary).get("hooks", [])
	var pspec_ok := false
	if rec_hooks.size() == 1:
		var proj: Dictionary = (rec_hooks[0] as Dictionary).get("projectile", {})
		pspec_ok = int(proj.get("chain_targets", -1)) == 2 and str(proj.get("element", "")) == "lightning" \
			and is_equal_approx(float(proj.get("chain_falloff", 0.0)), 0.5)
	_check(pspec_ok,
		"gen(2): installed hook carries chain_targets 2 + lightning + falloff 0.5 (got %s)" % str(rec_hooks))
	# Chat path: generate_with_context with a real conversation must
	# produce the same validating candidate (same validator, same fix).
	_creator_script.set("mock_generation", _mock_burst_lightning())
	_got = false
	_candidate = {}
	_gen_wait = 0
	_gen_next = 2
	_waiting = true
	_sub = 2
	_creator.call("generate_with_context",
		[{"role": "user", "text": "burst but fast, like 3 round"},
		{"role": "user", "text": "Can u make a lightning gun, like an lmg?"}],
		"3-round burst lightning gun, fast, chains to nearby enemies")
	return


func _phase2_chat() -> void:
	var err := str(_candidate.get("error", ""))
	_check(err == "", "gen(2): chat-path candidate validates (error='%s')" % err)
	_phase = 3
	_sub = 0


# --- Phase 3: in-game burst + chain -----------------------------------------

func _phase3() -> void:
	# Arsenal path: make_weapon("mod:burst_lightning") picks up the
	# block's fire_mode + burst_size through _mod_stats -> setup().
	var aw = _arsenal_script.call("make_weapon", "mod:burst_lightning")
	_check(int(aw.get("fire_mode")) == 4,
		"arsenal(3): make_weapon mod fire_mode == BURST (got %s)" % str(aw.get("fire_mode")))
	_check(int(aw.get("burst_size")) == 3,
		"arsenal(3): make_weapon mod burst_size == 3 (got %s)" % str(aw.get("burst_size")))
	var aw_hooks: Array = aw.get("mod_hooks")
	_check(aw_hooks.size() == 1,
		"arsenal(3): make_weapon mod carries 1 hook (got %d)" % aw_hooks.size())
	var aw_spec: Dictionary = _registry_script.call("resolve_projectile_spec", aw)
	_check(int(aw_spec.get("chain_targets", -1)) == 2 and str(aw_spec.get("element", "")) == "lightning",
		"arsenal(3): resolve_projectile_spec carries chain + lightning (got %s)" % str(aw_spec))
	aw.queue_free()
	# Forge grant path + burst fire + chain.
	if not _gate_and_build("burst_lightning"):
		_phase = 4
		_sub = 0
		return
	var w := _current_weapon()
	_check(int(w.get("fire_mode")) == 4,
		"forge(3): grant-path weapon fire_mode == BURST (got %s)" % str(w.get("fire_mode")))
	_check(int(w.get("burst_size")) == 3,
		"forge(3): grant-path weapon burst_size == 3 (got %s)" % str(w.get("burst_size")))
	w.set("spread_hip", 0.0)
	w.set("spread_move", 0.0)
	w.set("_raise_t", 999.0)
	w.set("_cooldown", 0.0)
	_reset_dummies()
	w.call("trigger_pressed")
	# ONE trigger press must produce exactly 3 projectiles.
	var projs: Array = []
	for i in 90:
		w.call("_process", 0.016)
		projs = []
		_find_projectiles(root, projs)
		if projs.size() >= 3:
			break
	_check(projs.size() == 3,
		"burst(3): one trigger press fires exactly 3 projectiles (got %d)" % projs.size())
	# Drive each projectile into the dummies.
	for p in projs:
		for i in 60:
			if bool(p.get("_dead")):
				break
			p.call("step", 0.016)
	_check(is_equal_approx(_dummy1.hp, 10.0) and is_equal_approx(_dummy1.last_damage, 30.0),
		"chain(3): dummy1 took 3x30 primary damage (hp %.1f, last %.1f)" % [_dummy1.hp, _dummy1.last_damage])
	_check(is_equal_approx(_dummy2.hp, 55.0) and is_equal_approx(_dummy2.last_damage, 15.0),
		"chain(3): dummy2 took 3x15 chain damage (30 * 0.5 falloff) (hp %.1f, last %.1f)" % [_dummy2.hp, _dummy2.last_damage])
	_phase = 4
	_sub = 0


func _finish() -> void:
	_cleanup()
	print("BURST_CHAIN VERIFY: %d checks, %d passes, %d failures" % [_passes + _fails, _passes, _fails])
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
			if _sub == 2:
				_phase2_chat()
			else:
				_phase2()
		3:
			_phase3()
			_finish()
			return true
		_:
			_finish()
			return true
	return false
