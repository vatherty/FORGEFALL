# FORGEFALL — verify_status_effects (v0.5.5: status effects for invented hooks)
# The Bubble Blaster gap: "slow" was expressible nowhere — not in the
# effect catalog, not in the sandbox, not in-game. This suite proves
# the fix end-to-end: a slow-bubble mod validates, its approval lists
# slow, the sandbox reports SLOWED with factor + duration, and a real
# enemy's speed actually drops for the duration, then recovers.
# Run: godot --headless --path . --script res://tools/verify_status_effects.gd
# Exit code 0 = all checks passed.
extends SceneTree

var _fails := 0
var _checks := 0
var _ran := false
# Game scripts are load()ed at runtime (NOT referenced as globals):
# parse-time global references would force compilation before the
# autoloads exist (Sfx), printing compile errors. This is the
# verify_invented_hooks pattern.
var _ModHook: GDScript
var _ModAPI: GDScript
var _ModStatus: GDScript
var _Sandbox: GDScript
var _Registry: GDScript


class BurnDummy extends CharacterBody3D:
	var hp := 100.0
	var dead := false
	func take_damage(amount: float, _pos: Vector3, _head: bool) -> void:
		hp -= amount
		if hp <= 0.0:
			dead = true
	func is_dead() -> bool:
		return dead


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % label)
	else:
		_fails += 1
		print("FAIL: %s" % label)


func _init() -> void:
	pass


## Tests run on the first process frame, NOT in _init: nodes added in
## _init report is_inside_tree() == false, and scripts referencing
## autoload globals (EnemyBase -> Sfx) only compile once the tree is
## running, so EnemyBase is load()ed at runtime here.
func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_ModHook = load("res://scripts/mods/mod_hook.gd")
	_ModAPI = load("res://scripts/mods/mod_api.gd")
	_ModStatus = load("res://scripts/mods/mod_status_effects.gd")
	_Sandbox = load("res://scripts/ui/sandbox_test_room.gd")
	_Registry = load("res://scripts/mods/mod_hook_registry.gd")
	_test_validation()
	_test_prompt_catalog()
	_test_approval_summary()
	_test_registry_apply()
	_test_status_system()
	_test_sandbox()
	_test_enemy_slow()
	_test_player_contract()
	print("verify_status_effects: %d checks, %d failures" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
	return true


func _test_validation() -> void:
	var hook := {"hook_id": "bubble_splat", "hook_point": "on_hit",
		"display_name": "Bubble Splat", "description": "Bubbles pop on hit, briefly slowing enemies.",
		"effects": [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0},
			{"kind": "smoke", "duration_sec": 3.0},
			{"kind": "announce", "title": "Pop!", "subtitle": "Bubble splat"}]}
	_check(_ModHook.call("validate_hook_data", hook) == "", "validation: on_hit slow hook validates (was unexpressible)")
	var fire_hook := {"hook_id": "bad_slow", "hook_point": "projectile_spawn",
		"effects": [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0}]}
	_check(_ModHook.call("validate_hook_data", fire_hook) != "", "validation: slow on a fire point is rejected (no target)")
	var bad_factor := {"hook_id": "bad_factor", "hook_point": "on_hit",
		"effects": [{"kind": "slow", "factor": 2.0, "duration_sec": 3.0}]}
	_check(_ModHook.call("validate_hook_data", bad_factor) != "", "validation: slow factor > 1 rejected")
	for kind in ["freeze", "burn", "knockback"]:
		var params := {}
		if kind == "freeze":
			params = {"duration_sec": 2.0}
		elif kind == "burn":
			params = {"damage_per_sec": 10.0, "duration_sec": 5.0}
		else:
			params = {"force": 12.0}
		var h := {"hook_id": "k_" + kind, "hook_point": "on_hit",
			"effects": [dict_merge({"kind": kind}, params)]}
		_check(_ModHook.call("validate_hook_data", h) == "", "validation: %s effect validates" % kind)


func _test_prompt_catalog() -> void:
	var creator_src := FileAccess.get_file_as_string("res://scripts/mods/mod_creator.gd")
	_check(creator_src.contains("\"slow\"") and creator_src.contains("bubble that slows"),
		"prompt: HOOK_PROMPT_ADDENDUM documents slow with the bubble example")
	_check(creator_src.contains("\"freeze\"") and creator_src.contains("\"burn\"") and creator_src.contains("\"knockback\""),
		"prompt: addendum documents freeze / burn / knockback")
	var menu_src := FileAccess.get_file_as_string("res://scripts/ui/mod_creator_menu.gd")
	_check(menu_src.contains("STATUS EFFECTS") and menu_src.contains("slow"),
		"prompt: creator-menu technical notes document status effects")


func _test_approval_summary() -> void:
	var hooks := [{"hook_id": "bubble_splat", "hook_point": "on_hit",
		"description": "Bubbles pop on hit, briefly slowing enemies.",
		"effects": [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0}]}]
	var lines: Variant = _ModHook.call("summarize_hooks", hooks)
	_check(not lines.is_empty() and str(lines[0]).contains("slow x0.50 for 3.0s"),
		"approval: summarize_hooks shows 'slow x0.50 for 3.0s' (got '%s')" % (str(lines[0]) if not lines.is_empty() else "<none>"))


func _test_registry_apply() -> void:
	var player := Node3D.new()
	player.name = "FakePlayer"
	root.add_child(player)
	var api: Variant = _ModAPI.new(player, root)
	var target := Node3D.new()
	target.name = "RegTarget"
	root.add_child(target)
	var hooks := [{"hook_id": "bubble_splat", "hook_point": "on_hit",
		"effects": [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0}]}]
	var ctx := {"position": Vector3.ZERO, "hit_position": Vector3.ZERO,
		"damage": 18.0, "target": target}
	var res: Variant = _Registry.call("run_hooks", hooks, "on_hit", api, ctx)
	_check(bool(res.get("status_applied", false)), "registry: on_hit slow reports status_applied")
	_check(is_equal_approx(_ModStatus.call("speed_multiplier", target), 0.5),
		"registry: target speed multiplier is 0.5 after slow")
	# on_damage_taken falls back to the player when ctx has no target.
	var dt_hooks := [{"hook_id": "thorns_slow", "hook_point": "on_damage_taken",
		"effects": [{"kind": "slow", "factor": 0.25, "duration_sec": 2.0}]}]
	var dt_res: Variant = _Registry.call("run_hooks", dt_hooks, "on_damage_taken", api, {"position": Vector3.ZERO})
	_check(bool(dt_res.get("status_applied", false)), "registry: on_damage_taken slow falls back to the player")
	_check(is_equal_approx(_ModStatus.call("speed_multiplier", player), 0.25),
		"registry: player speed multiplier is 0.25 after on_damage_taken slow")


func _test_status_system() -> void:
	var dummy := BurnDummy.new()
	dummy.name = "BurnDummy"
	dummy.hp = 100.0
	root.add_child(dummy)
	# Slow: refresh keeps the strongest factor + longest duration.
	_check(_ModStatus.call("apply_status", dummy, "slow", {"factor": 0.5, "duration_sec": 3.0}, Vector3.ZERO),
		"status: slow applies")
	_check(is_equal_approx(_ModStatus.call("speed_multiplier", dummy), 0.5),
		"status: multiplier 0.5 after slow")
	_ModStatus.call("apply_status", dummy, "slow", {"factor": 0.8, "duration_sec": 5.0}, Vector3.ZERO)
	_check(is_equal_approx(_ModStatus.call("speed_multiplier", dummy), 0.5),
		"status: re-apply keeps the strongest (lowest) slow factor")
	# Freeze forces 0; expiry restores.
	_ModStatus.call("apply_status", dummy, "freeze", {"duration_sec": 1.0}, Vector3.ZERO)
	_check(is_equal_approx(_ModStatus.call("speed_multiplier", dummy), 0.0),
		"status: freeze forces multiplier 0")
	_ModStatus.call("tick_target", dummy, 1.1)
	_check(is_equal_approx(_ModStatus.call("speed_multiplier", dummy), 0.5),
		"status: freeze expiry restores the surviving slow")
	_ModStatus.call("tick_target", dummy, 5.0)
	_check(is_equal_approx(_ModStatus.call("speed_multiplier", dummy), 1.0),
		"status: slow expiry restores full speed")
	var ticker := dummy.get_node_or_null("ModStatusTicker")
	_check(ticker == null or (ticker as Node).is_queued_for_deletion(),
		"status: ticker frees itself when effects empty")
	# Burn: 2.5s at 10 dps = exactly 25 damage (partial final tick).
	_ModStatus.call("apply_status", dummy, "burn", {"damage_per_sec": 10.0, "duration_sec": 2.5}, Vector3.ZERO)
	_ModStatus.call("tick_target", dummy, 1.0)
	_ModStatus.call("tick_target", dummy, 1.0)
	_ModStatus.call("tick_target", dummy, 1.0)
	_check(is_equal_approx(dummy.hp, 75.0), "status: 2.5s burn at 10 dps deals exactly 25 (hp %.1f)" % dummy.hp)
	# Knockback: impulse away from origin.
	var kb_target := BurnDummy.new()
	kb_target.name = "KBDummy"
	kb_target.position = Vector3(0, 0, 0)
	root.add_child(kb_target)
	_check(_ModStatus.call("apply_status", kb_target, "knockback", {"force": 12.0}, Vector3(0, 0, 5)),
		"status: knockback applies")
	_check(kb_target.velocity.length() > 11.0, "status: knockback impulse has force magnitude (%.1f)" % kb_target.velocity.length())
	# Null / freed / unknown-kind safety.
	_check(not _ModStatus.call("apply_status", null, "slow", {"factor": 0.5, "duration_sec": 1.0}, Vector3.ZERO),
		"status: null target is a safe no-op")
	_check(not _ModStatus.call("apply_status", dummy, "stun", {}, Vector3.ZERO),
		"status: unknown kind 'stun' is a safe no-op (not a real kind)")


func _test_sandbox() -> void:
	var behavior := {"projectile": true, "explodes_on_impact": false,
		"projectile_spec": {"visual": "round pastel-pink bubble", "speed": 22.0, "damage": 18.0},
		"hooks": [{"hook_id": "bubble_projectile", "hook_point": "projectile_spawn",
			"projectile": {"visual": "round pastel-pink bubble", "speed": 22.0, "damage": 18.0}},
			{"hook_id": "bubble_splat", "hook_point": "on_hit",
			"effects": [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0},
				{"kind": "smoke", "duration_sec": 3.0},
				{"kind": "announce", "title": "Pop!", "subtitle": "Bubble splat"}]}],
		"heal_on_kill": 0.0}
	var res: Variant = _Sandbox.call("simulate_test", {}, {"voxel_count": 81}, behavior)
	_check(bool(res.get("hit", false)), "sandbox: bubble projectile hits dummy 0")
	var st: Variant = res.get("status_effects", [])
	_check(st is Array and (st as Array).size() == 1 and str(((st as Array)[0] as Dictionary).get("kind", "")) == "slow",
		"sandbox: slow effect parsed from on_hit hooks")
	_check(is_equal_approx(float(res.get("dummy_speed_before", 0.0)), 4.0)
		and is_equal_approx(float(res.get("dummy_speed_after", 0.0)), 2.0),
		"sandbox: dummy speed readout 4.0 -> 2.0 m/s under slow (got %.1f -> %.1f)" % [
			float(res.get("dummy_speed_before", 0.0)), float(res.get("dummy_speed_after", 0.0))])
	_check(is_equal_approx(float(((st as Array)[0] as Dictionary).get("duration_sec", 0.0)), 3.0),
		"sandbox: slow duration 3.0s reported")


func _test_enemy_slow() -> void:
	# Runtime load: enemy_base.gd references the Sfx autoload, which
	# only exists once the tree is running (see _process note above).
	var enemy_script: GDScript = load("res://scripts/enemies/enemy_base.gd")
	var enemy: CharacterBody3D = enemy_script.new()
	enemy.name = "SlowTestEnemy"
	root.add_child(enemy)
	enemy.speed = 4.0
	enemy.base_speed = 4.0
	enemy.wish_dir = Vector3(1, 0, 0)
	enemy.wish_speed = 0.0
	# Baseline: full speed.
	for _i in range(10):
		enemy._apply_locomotion(0.1)
	var base_h := Vector2(enemy.velocity.x, enemy.velocity.z).length()
	_check(base_h > 3.5, "enemy: baseline locomotion reaches full speed (%.2f)" % base_h)
	# Slowed: half speed, then recover after expiry.
	_ModStatus.call("apply_status", enemy, "slow", {"factor": 0.5, "duration_sec": 3.0}, Vector3.ZERO)
	for _i in range(10):
		enemy._apply_locomotion(0.1)
	var slow_h := Vector2(enemy.velocity.x, enemy.velocity.z).length()
	_check(slow_h > 1.5 and slow_h < 2.5, "enemy: slowed locomotion ~half speed (%.2f)" % slow_h)
	_ModStatus.call("tick_target", enemy, 3.1)
	for _i in range(10):
		enemy._apply_locomotion(0.1)
	var rec_h := Vector2(enemy.velocity.x, enemy.velocity.z).length()
	_check(rec_h > 3.5, "enemy: speed recovers after slow expires (%.2f)" % rec_h)
	enemy.queue_free()


func _test_player_contract() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/player/player.gd")
	_check(src.contains("ModStatusEffects.speed_multiplier(self)"),
		"player: ground movement multiplies speed by ModStatusEffects (contract)")
	var esrc := FileAccess.get_file_as_string("res://scripts/enemies/enemy_base.gd")
	_check(esrc.contains("ModStatusEffects.speed_multiplier(self)"),
		"enemy: _apply_locomotion multiplies speed by ModStatusEffects (contract)")


static func dict_merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate(true)
	for k in b.keys():
		out[k] = b[k]
	return out
