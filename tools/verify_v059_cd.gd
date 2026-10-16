# tools/verify_v059_cd.gd — Worker CD verification for FORGEFALL v0.5.9
# (EDIT INSTALLED MODS + take_damage HOOK).
# Usage: godot --headless --path <project> --script res://tools/verify_v059_cd.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# IMPORTANT: this script must NOT reference game classes statically
# (no `ModCreator.foo` / `ModLoader.bar` in code). A --script file is
# compiled before autoloads register, so a static reference forces
# compiling that class + transitive deps without Sfx etc. -> a
# cascade of "Identifier not found: Sfx" and broken enemy scripts
# (and a failed .call() FATALLY aborts the caller in 4.7.2). All
# game classes are loaded at runtime via load() + .call()/.new(),
# exactly like tools/verify_hook_scripts.gd does.
#
# Coverage:
#  (1) EDIT: install v1.0 block mod -> edit_context seeds name/categories/
#      visual/logic/payload -> ChatSession begin_edit + preamble carry the
#      original payload -> diff shows Version 1.0 -> 1.1 + the field
#      change -> install_update writes v1.1, ONE record, old version gone
#      -> Discard (clear_edit) leaves the installed mod untouched ->
#      a failed update (script whose get_block_info is bad) rolls back
#      to the original files -> bump_version table.
#  (2) take_damage on ENEMIES: shield absorbs (pool drains), vulnerable
#      multiplies (incl. vulnerable x shield order), thorns reflects
#      to the attacker, petrified nullifies + pins, a take_damage data
#      hook granting shield absorbs THIS hit, a take_damage code hook
#      returning damage_mult scales THIS hit, DOT ticks never reflect
#      via thorns, petrified + thorns reflects nothing.
#  (3) take_damage on the PLAYER (real player.tscn): shield, vulnerable,
#      thorns (attacker = enemy), petrified, equipped-weapon
#      take_damage hook.
#  (4) Forbidden-API scan still blocks bad hooks (take_damage code hook
#      calling OS.execute rejected; script candidate with OS.execute
#      refused by validate_generated_mod) + an existing hook kind
#      (on_hit slow) still works.
#
# Isolation: user://mods/ + user://mods_enabled.json +
# user://chat_session.json are backed up to user://_v059_verify_backup_*
# at start, wiped for the run, and restored in _cleanup() on EVERY exit.
extends SceneTree

var _fails := 0
var _passes := 0
var _frame := 0
var _phase := 0
var _cleaned_up := false

var _user_dir := ""
var _mods_abs := ""
var _backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _chat_abs := ""
var _chat_backup_abs := ""
var _had_mods := false
var _had_enabled := false
var _had_chat := false

# Runtime-loaded game scripts (never static references — see header).
var _creator_script: GDScript = null
var _loader_script: GDScript = null
var _chat_script: GDScript = null
var _hook_script: GDScript = null
var _registry_script: GDScript = null
var _status_script: GDScript = null
var _api_script: GDScript = null
var _grunt_script: GDScript = null

var _enemy: Node = null
var _attacker: Node = null
var _player: Node = null


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
	else:
		_fails += 1
		printerr("VERIFY_V059 FAIL: " + label)


func _initialize() -> void:
	_creator_script = load("res://scripts/mods/mod_creator.gd") as GDScript
	_loader_script = load("res://scripts/mods/mod_loader.gd") as GDScript
	_chat_script = load("res://scripts/mods/chat_session.gd") as GDScript
	_hook_script = load("res://scripts/mods/mod_hook.gd") as GDScript
	_registry_script = load("res://scripts/mods/mod_hook_registry.gd") as GDScript
	_status_script = load("res://scripts/mods/mod_status_effects.gd") as GDScript
	_api_script = load("res://scripts/mods/mod_api.gd") as GDScript
	_grunt_script = load("res://scripts/enemies/grunt.gd") as GDScript
	_backup_and_stage()
	_phase = 1


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame > 120:
		print("VERIFY_V059: WATCHDOG — stuck at phase %d after 120 frames" % _phase)
		_cleanup()
		quit(1)
		return false
	match _phase:
		1:
			_test_edit()
			_phase = 2
		2:
			# Spawn the enemy; _ready needs a frame before activate().
			_enemy = _grunt_script.new()
			_enemy.name = "V059Enemy"
			root.add_child(_enemy)
			_attacker = _FakeAttacker.new()
			_attacker.name = "V059Attacker"
			root.add_child(_attacker)
			_phase = 3
		3:
			# Guard: a failed .call() fatally aborts the caller in 4.7.2,
			# so never call a method that does not exist — fail loudly
			# and quit instead of hanging.
			if not _enemy.has_method("activate") or not _enemy.has_method("take_damage"):
				_check(false, "enemy exposes activate + take_damage (scripts compiled clean)")
				_cleanup()
				print("VERIFY_V059: %d passed, %d failed" % [_passes, _fails])
				quit(1)
				return false
			_enemy.call("activate", Vector3(0, 0, 0), 1, {})
			_test_enemy_take_damage()
			_phase = 4
		4:
			var ps: PackedScene = load("res://scenes/player.tscn") as PackedScene
			_player = ps.instantiate()
			_player.name = "V059Player"
			root.add_child(_player)
			_phase = 5
		5:
			if not _player.has_method("take_damage"):
				_check(false, "player exposes take_damage (scripts compiled clean)")
				_cleanup()
				print("VERIFY_V059: %d passed, %d failed" % [_passes, _fails])
				quit(1)
				return false
			_test_player_take_damage()
			_test_existing_hooks()
			_cleanup()
			print("VERIFY_V059: %d passed, %d failed" % [_passes, _fails])
			quit(1 if _fails > 0 else 0)
	return false


# --- EDIT -----------------------------------------------------------------

func _block_payload(factor: float, duration: float) -> String:
	return JSON.stringify({
		"block": {
			"block_id": "v059_bubble",
			"target": "weapon",
			"cost": 250,
			"display_name": "V059 Bubble",
			"description": "An LMG that shoots slowing bubbles.",
			"base_weapon_id": "lmg",
		},
		"hooks": [
			{"hook_id": "bubble_slow", "hook_point": "on_hit",
				"display_name": "Bubble Slow", "description": "Bubbles slow the hit target.",
				"effects": [{"kind": "slow", "factor": factor, "duration_sec": duration}]},
		],
	})


func _block_candidate(payload: String) -> Dictionary:
	return {"mod_id": "v059_bubble", "name": "V059 Bubble", "kind": "block",
		"manifest": {"name": "V059 Bubble", "kind": "block", "version": "1.0"},
		"payload": payload, "summary": "V059 Bubble", "spell_school": "", "error": ""}


func _test_edit() -> void:
	var creator: Node = _creator_script.new()
	root.add_child(creator)
	# Install v1.0.
	var err := str(creator.call("install", _block_candidate(_block_payload(0.5, 3.0))))
	_check(err == "", "EDIT install v1.0 succeeds (err='%s')" % err)
	var rec: Dictionary = _loader_script.call("find_mod", "v059_bubble", false)
	_check(not rec.is_empty(), "EDIT installed record exists")
	_check(str(rec.get("version", "")) == "1.0", "EDIT installed version is 1.0")
	# bump_version table.
	_check(str(_creator_script.call("bump_version", "1.0")) == "1.1", "bump 1.0 -> 1.1")
	_check(str(_creator_script.call("bump_version", "1.1")) == "1.2", "bump 1.1 -> 1.2")
	_check(str(_creator_script.call("bump_version", "2.3.4")) == "2.3.5", "bump 2.3.4 -> 2.3.5")
	_check(str(_creator_script.call("bump_version", "1")) == "2", "bump 1 -> 2")
	_check(str(_creator_script.call("bump_version", "")) == "1.1", "bump '' -> 1.1")
	# Edit context seeds name / categories / visual / logic / payload.
	var ctx: Dictionary = _creator_script.call("edit_context_for", "v059_bubble")
	_check(str(ctx.get("error", "")) == "", "edit_context loads (err='%s')" % str(ctx.get("error", "")))
	_check(str(ctx.get("name", "")) == "V059 Bubble", "edit_context name")
	_check("Weapon" in (ctx.get("categories", []) as Array), "edit_context infers Weapon")
	_check("Effect" in (ctx.get("categories", []) as Array), "edit_context infers Effect (hooks)")
	_check(str(ctx.get("visual", "")).contains("slowing bubbles"), "edit_context visual from description")
	_check(str(ctx.get("logic", "")).contains("bubble_slow"), "edit_context logic mentions hook")
	_check(str(ctx.get("payload", "")).contains("bubble_slow"), "edit_context carries payload")
	_check(str(ctx.get("version", "")) == "1.0", "edit_context version 1.0")
	# ChatSession seeding + preamble.
	var session: RefCounted = _chat_script.new()
	_check(not bool(session.call("is_editing")), "session starts unedited")
	session.call("begin_edit", ctx)
	_check(bool(session.call("is_editing")), "session is_editing after begin_edit")
	_check(str(session.call("get_edit_mod_id")) == "v059_bubble", "session edit mod id")
	var preamble := str(_chat_script.call("edit_preamble", session.call("get_edit_context")))
	_check(preamble.contains("v059_bubble") and preamble.contains("bubble_slow"),
		"edit preamble carries mod id + original payload")
	_check(preamble.contains("EDIT AN EXISTING MOD"), "edit preamble says EDIT, not fresh")
	# Persistence: a fresh session loads the edit context.
	var session2: RefCounted = _chat_script.new()
	_check(bool(session2.call("is_editing")) and str(session2.call("get_edit_mod_id")) == "v059_bubble",
		"edit context persists across ChatSession loads")
	# Diff: bigger bubble (stronger slow 0.5 -> 0.3, longer 3.0 -> 5.0).
	var updated := _block_candidate(_block_payload(0.3, 5.0))
	var loaded: Dictionary = _creator_script.call("load_installed", "v059_bubble")
	var diff: Array = _creator_script.call("diff_candidate_vs_installed", updated, loaded)
	var diff_text := "\n".join(diff)
	_check(diff_text.contains("Version: 1.0 -> 1.1"), "diff shows version bump")
	_check(diff_text.contains("0.5 -> 0.3") or diff_text.contains("0.5->0.3"),
		"diff shows the factor change (got: %s)" % diff_text.left(400))
	# install_update: v1.1, ONE record, old version gone.
	err = str(creator.call("install_update", updated, "v059_bubble"))
	_check(err == "", "install_update succeeds (err='%s')" % err)
	var mods: Array = _loader_script.call("get_mods")
	var matches := 0
	for m in mods:
		if str((m as Dictionary).get("id", "")) == "v059_bubble":
			matches += 1
			_check(str((m as Dictionary).get("version", "")) == "1.1", "updated record is v1.1")
	_check(matches == 1, "exactly ONE v059_bubble record after update (old version gone)")
	rec = _loader_script.call("find_mod", "v059_bubble", false)
	var rec_payload := ""
	var folder: String = "user://mods".path_join("v059_bubble")
	if FileAccess.file_exists(folder.path_join("block.json")):
		rec_payload = FileAccess.get_file_as_string(folder.path_join("block.json"))
	_check(rec_payload.contains("0.3"), "updated payload on disk has factor 0.3")
	# Discard: begin_edit then clear_edit leaves the installed mod untouched.
	session.call("begin_edit", _creator_script.call("edit_context_for", "v059_bubble"))
	session.call("clear_edit")
	_check(not bool(session.call("is_editing")), "clear_edit drops the edit")
	rec = _loader_script.call("find_mod", "v059_bubble", false)
	_check(str(rec.get("version", "")) == "1.1", "discard leaves installed v1.1 untouched")
	# Failed update rolls back: script candidate whose get_block_info
	# is bad passes text validation but fails install-time rescan
	# (missing cost) — the write happens, then rollback restores.
	var bad_script := "extends ModBlock\nfunc get_block_info() -> Dictionary:\n\treturn {\"block_id\": \"x\", \"target\": \"weapon\"}\nfunc apply(api: ModAPI, params: Dictionary) -> String:\n\treturn \"ok\"\n"
	var bad_cand := {"mod_id": "v059_bubble", "name": "V059 Bubble", "kind": "script",
		"manifest": {"name": "V059 Bubble", "kind": "script", "version": "1.1"},
		"payload": bad_script, "summary": "bad", "spell_school": "", "error": ""}
	err = str(creator.call("install_update", bad_cand, "v059_bubble"))
	_check(err != "", "bad update is refused (err='%s')" % err)
	rec = _loader_script.call("find_mod", "v059_bubble", false)
	_check(str(rec.get("version", "")) == "1.1" and str(rec.get("error", "")) == "",
		"failed update rolls back: v1.1 error-free")
	var after_payload := ""
	if FileAccess.file_exists(folder.path_join("block.json")):
		after_payload = FileAccess.get_file_as_string(folder.path_join("block.json"))
	_check(after_payload.contains("0.3"), "failed update restores original payload bytes")
	_check(not FileAccess.file_exists(folder.path_join("mod.gd")),
		"failed update leaves no stale mod.gd")
	# Cleanup: session state for later phases.
	session.call("clear")
	creator.queue_free()


# --- take_damage: ENEMY -----------------------------------------------------

func _enemy_hp() -> float:
	return float(_enemy.get("hp"))


func _reset_enemy(hp: float) -> void:
	_enemy.call("activate", Vector3(0, 0, 0), 1, {})
	_enemy.set("hp", hp)
	_enemy.set("mod_hooks", [])
	_status_script.call("clear_status_effect", _enemy, "all")
	_status_script.call("clear_status_effect", _attacker, "all")
	_attacker.set("hp", 1000.0)


func _test_enemy_take_damage() -> void:
	var pos := Vector3(0, 0, 0)
	# SHIELD absorbs; pool drains.
	_reset_enemy(1000.0)
	_check(bool(_status_script.call("apply_status", _enemy, "shield", {"amount": 30.0, "duration_sec": 10.0}, pos)),
		"enemy shield applies")
	_enemy.call("take_damage", 50.0, pos, false)
	_check(is_equal_approx(_enemy_hp(), 980.0), "enemy shield absorbs 30 of 50 (hp=%.1f)" % _enemy_hp())
	_check(is_equal_approx(float(_status_script.call("get_shield_remaining", _enemy)), 0.0),
		"enemy shield pool drained to 0")
	_enemy.call("take_damage", 10.0, pos, false)
	_check(is_equal_approx(_enemy_hp(), 970.0), "enemy unshielded hit lands fully (hp=%.1f)" % _enemy_hp())
	# SHIELD stacks (re-apply adds to the pool).
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _enemy, "shield", {"amount": 20.0, "duration_sec": 10.0}, pos)
	_status_script.call("apply_status", _enemy, "shield", {"amount": 15.0, "duration_sec": 10.0}, pos)
	_check(is_equal_approx(float(_status_script.call("get_shield_remaining", _enemy)), 35.0),
		"enemy shield re-apply stacks pool to 35")
	# VULNERABLE multiplies.
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _enemy, "vulnerable", {"factor": 2.0, "duration_sec": 10.0}, pos)
	_enemy.call("take_damage", 10.0, pos, false)
	_check(is_equal_approx(_enemy_hp(), 980.0), "enemy vulnerable x2 (hp=%.1f)" % _enemy_hp())
	_check(is_equal_approx(float(_status_script.call("get_damage_taken_multiplier", _enemy)), 2.0),
		"enemy damage-taken multiplier reads 2.0 while vulnerable")
	# VULNERABLE x SHIELD order: 20 x2 = 40, shield eats 30, final 10.
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _enemy, "vulnerable", {"factor": 2.0, "duration_sec": 10.0}, pos)
	_status_script.call("apply_status", _enemy, "shield", {"amount": 30.0, "duration_sec": 10.0}, pos)
	_enemy.call("take_damage", 20.0, pos, false)
	_check(is_equal_approx(_enemy_hp(), 990.0), "enemy vulnerable-then-shield order (hp=%.1f)" % _enemy_hp())
	# THORNS reflects to the attacker.
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _enemy, "thorns", {"reflect_mult": 0.5, "duration_sec": 10.0}, pos)
	_enemy.call("take_damage", 40.0, pos, false, _attacker)
	_check(is_equal_approx(_enemy_hp(), 960.0), "enemy thorns hit lands (hp=%.1f)" % _enemy_hp())
	_check(is_equal_approx(float(_attacker.get("hp")), 980.0),
		"enemy thorns reflects 0.5 x 40 = 20 to attacker (attacker hp=%.1f)" % float(_attacker.get("hp")))
	# THORNS vs THORNS: no ping-pong (attacker also thorny).
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _enemy, "thorns", {"reflect_mult": 1.0, "duration_sec": 10.0}, pos)
	_status_script.call("apply_status", _attacker, "thorns", {"reflect_mult": 1.0, "duration_sec": 10.0}, pos)
	_enemy.call("take_damage", 40.0, pos, false, _attacker)
	_check(is_equal_approx(_enemy_hp(), 960.0), "thorns ping-pong guard: enemy takes once (hp=%.1f)" % _enemy_hp())
	_check(is_equal_approx(float(_attacker.get("hp")), 960.0),
		"thorns ping-pong guard: attacker takes once (hp=%.1f)" % float(_attacker.get("hp")))
	_status_script.call("clear_status_effect", _attacker, "all")
	# PETRIFIED nullifies + pins.
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _enemy, "petrified", {"duration_sec": 10.0}, pos)
	_check(is_equal_approx(float(_status_script.call("get_damage_taken_multiplier", _enemy)), 0.0),
		"petrified damage-taken multiplier reads 0.0")
	_check(is_equal_approx(float(_status_script.call("speed_multiplier", _enemy)), 0.0),
		"petrified pins speed to 0")
	_enemy.call("take_damage", 100.0, pos, false, _attacker)
	_check(is_equal_approx(_enemy_hp(), 1000.0), "petrified nullifies 100 damage (hp=%.1f)" % _enemy_hp())
	_check(is_equal_approx(float(_attacker.get("hp")), 1000.0),
		"petrified + thorns reflects nothing (no damage taken)")
	_status_script.call("clear_status_effect", _enemy, "petrified")
	_enemy.call("take_damage", 10.0, pos, false)
	_check(is_equal_approx(_enemy_hp(), 990.0), "damage lands after petrified clears (hp=%.1f)" % _enemy_hp())
	# PETRIFIED + THORNS: nullified hit reflects nothing.
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _enemy, "petrified", {"duration_sec": 10.0}, pos)
	_status_script.call("apply_status", _enemy, "thorns", {"reflect_mult": 1.0, "duration_sec": 10.0}, pos)
	_enemy.call("take_damage", 50.0, pos, false, _attacker)
	_check(is_equal_approx(_enemy_hp(), 1000.0), "petrified+thorns: hp untouched")
	_check(is_equal_approx(float(_attacker.get("hp")), 1000.0), "petrified+thorns: attacker untouched")
	# take_damage DATA hook granting shield absorbs THIS hit.
	_reset_enemy(1000.0)
	_enemy.set("mod_hooks", [{"hook_id": "ward", "hook_point": "take_damage",
		"effects": [{"kind": "shield", "amount": 25.0, "duration_sec": 10.0}]}])
	_enemy.call("take_damage", 40.0, pos, false)
	_check(is_equal_approx(_enemy_hp(), 985.0),
		"take_damage hook shield absorbs THIS hit (hp=%.1f)" % _enemy_hp())
	# take_damage CODE hook returning damage_mult scales THIS hit.
	_reset_enemy(1000.0)
	var code := "extends ModHook\nfunc run(api: ModAPI, ctx: Dictionary) -> Dictionary:\n\treturn {\"damage_mult\": 0.5}\n"
	var hook := {"hook_id": "halve", "hook_point": "take_damage", "code": code}
	_check(str(_hook_script.call("validate_hook_data", hook)) == "", "take_damage code hook validates")
	_enemy.set("mod_hooks", [hook])
	_enemy.call("take_damage", 40.0, pos, false)
	_check(is_equal_approx(_enemy_hp(), 980.0),
		"take_damage code hook damage_mult 0.5 halves THIS hit (hp=%.1f)" % _enemy_hp())
	# DOT ticks never reflect via thorns.
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _enemy, "thorns", {"reflect_mult": 1.0, "duration_sec": 10.0}, pos)
	_status_script.call("apply_status", _enemy, "burn", {"damage_per_sec": 10.0, "duration_sec": 5.0}, pos)
	_status_script.call("tick_target", _enemy, 1.0)
	_check(is_equal_approx(_enemy_hp(), 990.0), "burn DOT tick deals 10 (hp=%.1f)" % _enemy_hp())
	_check(is_equal_approx(float(_attacker.get("hp")), 1000.0),
		"burn DOT tick does NOT reflect via thorns (attacker hp=%.1f)" % float(_attacker.get("hp")))
	# take_damage hook that deals damage does NOT recurse (nested
	# dispatch suppressed): typed_damage effect inside a take_damage hook.
	_reset_enemy(1000.0)
	_enemy.set("mod_hooks", [{"hook_id": "retort", "hook_point": "take_damage",
		"effects": [{"kind": "typed_damage", "damage_type": "fire", "amount": 5.0, "duration_sec": 1.0}]}])
	_enemy.call("take_damage", 10.0, pos, false)
	_check(is_equal_approx(_enemy_hp(), 985.0),
		"take_damage hook typed_damage lands once, no recursion (hp=%.1f)" % _enemy_hp())


# --- take_damage: PLAYER ------------------------------------------------------

func _test_player_take_damage() -> void:
	var pos := Vector3(0, 0, 0)
	var get_hp := func() -> float: return float(_player.get("_hp"))
	# Baseline: whatever the scene-default class's max HP is (125).
	var base: float = get_hp.call()
	_check(is_equal_approx(base, float(_player.call("get_max_hp"))),
		"player starts at full HP (hp=%.1f)" % base)
	# SHIELD.
	_status_script.call("apply_status", _player, "shield", {"amount": 30.0, "duration_sec": 10.0}, pos)
	_player.call("take_damage", 50.0, pos, false)
	_check(is_equal_approx(get_hp.call(), base - 20.0), "player shield absorbs 30 of 50 (hp=%.1f)" % get_hp.call())
	# VULNERABLE.
	_status_script.call("apply_status", _player, "vulnerable", {"factor": 2.0, "duration_sec": 10.0}, pos)
	_player.call("take_damage", 10.0, pos, false)
	_check(is_equal_approx(get_hp.call(), base - 40.0), "player vulnerable x2 (hp=%.1f)" % get_hp.call())
	_status_script.call("clear_status_effect", _player, "vulnerable")
	# THORNS: attacker is the enemy; reflected hit lands on it.
	_player.call("heal", 100.0)
	_reset_enemy(1000.0)
	_status_script.call("apply_status", _player, "thorns", {"reflect_mult": 0.5, "duration_sec": 10.0}, pos)
	_player.call("take_damage", 40.0, pos, false, _enemy)
	_check(is_equal_approx(get_hp.call(), base - 40.0), "player thorns hit lands (hp=%.1f)" % get_hp.call())
	_check(is_equal_approx(_enemy_hp(), 980.0),
		"player thorns reflects 20 to enemy attacker (enemy hp=%.1f)" % _enemy_hp())
	# PETRIFIED.
	_status_script.call("apply_status", _player, "petrified", {"duration_sec": 10.0}, pos)
	_player.call("take_damage", 100.0, pos, false)
	_check(is_equal_approx(get_hp.call(), base - 40.0), "player petrified nullifies 100 (hp=%.1f)" % get_hp.call())
	_status_script.call("clear_status_effect", _player, "petrified")
	_status_script.call("clear_status_effect", _player, "thorns")
	# Equipped-weapon take_damage hook: halve THIS hit.
	var wm := _player.get_node_or_null("WeaponManager")
	var cur: Variant = wm.get("_current") if wm != null else null
	_check(cur is Node, "player has a current weapon")
	if cur is Node:
		(cur as Node).set("mod_hooks", [{"hook_id": "ward_hook", "hook_point": "take_damage",
			"effects": [{"kind": "shield", "amount": 25.0, "duration_sec": 10.0}]}])
		_player.call("take_damage", 40.0, pos, false)
		_check(is_equal_approx(get_hp.call(), base - 55.0),
			"player equipped-weapon take_damage hook shield absorbs THIS hit (hp=%.1f)" % get_hp.call())
		(cur as Node).set("mod_hooks", [])


# --- Existing hooks + forbidden scan -----------------------------------------

func _test_existing_hooks() -> void:
	# on_hit slow (existing kind) still works through the registry.
	var dummy := Node3D.new()
	dummy.name = "V059Dummy"
	root.add_child(dummy)
	var api: RefCounted = _api_script.new(null, null)
	var ctx := {"position": Vector3.ZERO, "hit_position": Vector3.ZERO,
		"damage": 10.0, "target": dummy, "headshot": false, "weapon_id": "p9"}
	var res: Dictionary = _registry_script.call("run_hooks",
		[{"hook_id": "slow_hit", "hook_point": "on_hit",
			"effects": [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0}]}],
		"on_hit", api, ctx)
	_check(bool(res.get("status_applied", false)), "existing on_hit slow still applies")
	_check(bool(_status_script.call("has_status_effect", dummy, "slow")), "existing on_hit slow lands on target")
	# take_damage hook_point validates; forbidden API rejected.
	var bad_code := "extends ModHook\nfunc run(api: ModAPI, ctx: Dictionary) -> Dictionary:\n\tOS.execute(\"x\", [])\n\treturn {}\n"
	var bad_hook := {"hook_id": "bad", "hook_point": "take_damage", "code": bad_code}
	var verr := str(_hook_script.call("validate_hook_data", bad_hook))
	_check(verr != "" and verr.contains("OS.execute"), "take_damage hook with OS.execute rejected (err='%s')" % verr)
	# Script candidate with forbidden API refused at validation.
	var bad_script := "extends ModBlock\nfunc get_block_info() -> Dictionary:\n\treturn {}\nfunc apply(api: ModAPI, params: Dictionary) -> String:\n\tOS.execute(\"x\", [])\n\treturn \"\"\n"
	var gerr := str(_loader_script.call("validate_generated_mod", {"name": "Bad", "kind": "script"}, bad_script))
	_check(gerr != "" and gerr.contains("OS.execute"), "script candidate with OS.execute refused (err='%s')" % gerr)
	# New effect kinds validate; a status kind on a fire point is rejected.
	var shield_hook := {"hook_id": "s", "hook_point": "take_damage",
		"effects": [{"kind": "shield", "amount": 10.0, "duration_sec": 5.0}]}
	_check(str(_hook_script.call("validate_hook_data", shield_hook)) == "", "take_damage shield hook validates")
	var fire_shield := {"hook_id": "s", "hook_point": "on_fire",
		"effects": [{"kind": "shield", "amount": 10.0, "duration_sec": 5.0}]}
	_check(str(_hook_script.call("validate_hook_data", fire_shield)) != "", "shield on a fire point rejected (needs a target)")
	dummy.queue_free()


# --- Backup / cleanup --------------------------------------------------------

func _backup_and_stage() -> void:
	_user_dir = OS.get_user_data_dir()
	_mods_abs = _user_dir.path_join("mods")
	_backup_abs = _user_dir.path_join("_v059_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v059_verify_backup_enabled.json")
	_chat_abs = _user_dir.path_join("chat_session.json")
	_chat_backup_abs = _user_dir.path_join("_v059_verify_backup_chat.json")
	_wipe_contents(_backup_abs)
	DirAccess.remove_absolute(_backup_abs)
	if FileAccess.file_exists(_enabled_backup_abs):
		DirAccess.remove_absolute(_enabled_backup_abs)
	if FileAccess.file_exists(_chat_backup_abs):
		DirAccess.remove_absolute(_chat_backup_abs)
	_had_mods = DirAccess.dir_exists_absolute(_mods_abs)
	if _had_mods:
		_copy_recursive(_mods_abs, _backup_abs)
	_had_enabled = FileAccess.file_exists(_enabled_abs)
	if _had_enabled:
		_copy_file(_enabled_abs, _enabled_backup_abs)
	_had_chat = FileAccess.file_exists(_chat_abs)
	if _had_chat:
		_copy_file(_chat_abs, _chat_backup_abs)
	DirAccess.make_dir_recursive_absolute(_mods_abs)
	_wipe_contents(_mods_abs)
	if FileAccess.file_exists(_enabled_abs):
		DirAccess.remove_absolute(_enabled_abs)
	if FileAccess.file_exists(_chat_abs):
		DirAccess.remove_absolute(_chat_abs)
	_loader_script.call("rescan")


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
	if _had_chat:
		_copy_file(_chat_backup_abs, _chat_abs)
		if FileAccess.file_exists(_chat_backup_abs):
			DirAccess.remove_absolute(_chat_backup_abs)
	elif FileAccess.file_exists(_chat_abs):
		DirAccess.remove_absolute(_chat_abs)
	_loader_script.call("rescan")


func _wipe_contents(abs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	for f in DirAccess.get_files_at(abs_dir):
		DirAccess.remove_absolute(abs_dir.path_join(f))
	for d in DirAccess.get_directories_at(abs_dir):
		_wipe_contents(abs_dir.path_join(d))
		DirAccess.remove_absolute(abs_dir.path_join(d))


func _copy_recursive(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	for f in DirAccess.get_files_at(src):
		_copy_file(src.path_join(f), dst.path_join(f))
	for d in DirAccess.get_directories_at(src):
		_copy_recursive(src.path_join(d), dst.path_join(d))


func _copy_file(src: String, dst: String) -> void:
	if not FileAccess.file_exists(src):
		return
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(FileAccess.get_file_as_string(src))
	f.close()


## Fake attacker: a CharacterBody3D with a 3-arg take_damage + hp, so
## thorns reflections have a real target that records the damage.
class _FakeAttacker extends CharacterBody3D:
	var hp := 1000.0

	func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool) -> void:
		hp -= amount
