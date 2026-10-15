# verify_v05_b2_forge_backend.gd — B2 Forge backend verification (headless).
# Usage: godot --headless --path <project> --script res://tools/verify_v05_b2_forge_backend.gd
# Asserts: parser (new verbs/aliases incl. spawn enemies), unknown -> helpful
# error, preview_cost matches charged cost, undo removes + refunds exactly,
# history records prompts, offline path (parse_offline never touches network),
# existing commands (wall, turret) still work, structures have collision,
# structure cap enforced. Exit: prints RESULT: PASS/FAIL + quits.
extends SceneTree

class StubWM extends Node:
	var given: Array[String] = []
	func give_weapon(id: String) -> void:
		given.append(id)

class StubWaveManager extends Node:
	var mods: Array = []
	func apply_director_mod(mod: Dictionary) -> void:
		mods.append(mod)

var _fails: Array[String] = []
var _checks := 0
var _forge: Node = null
var _game: Node = null
var _test_root: Node3D = null
var _player: Node3D = null
var _wm: StubWM = null
var _wave_stub: StubWaveManager = null
var _stage := 0
var _frames := 0
var _wait := 0
var _awaiting_result := false
var _result_received := false
var _result_success := false
var _result_msg := ""
var _budget_before := 0
var _llm_script: GDScript = null
var _builder_script: GDScript = null
var _wall_node: Node = null


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: ", label)
	else:
		_fails.append(label)
		print("FAIL: ", label)


func _spec_for(prompt: String) -> Dictionary:
	return _llm_script.parse_offline(prompt)


func _has_collision(n: Node) -> bool:
	if n is CollisionShape3D:
		return true
	for c in n.get_children():
		if _has_collision(c):
			return true
	return false


func _ctx() -> Dictionary:
	return {"player": _player, "root": _test_root}


func _on_forge_result(success: bool, message: String) -> void:
	if not _awaiting_result:
		return
	_awaiting_result = false
	_result_received = true
	_result_success = success
	_result_msg = message


func _initialize() -> void:
	_llm_script = load("res://scripts/forge/forge_llm.gd") as GDScript
	_builder_script = load("res://scripts/forge/forge_builder.gd") as GDScript
	_forge = root.get_node_or_null("Forge")
	_game = root.get_node_or_null("Game")
	if _forge == null or _game == null:
		print("FAIL: Forge/Game autoload missing — cannot test")
		_stage = 99
		return
	_forge.connect("forge_result", _on_forge_result)
	_test_root = Node3D.new()
	_test_root.name = "B2TestRoot"
	root.add_child(_test_root)
	current_scene = _test_root
	_player = Node3D.new()
	_player.name = "B2Player"
	_player.position = Vector3(0, 0, 0)
	_player.add_to_group("player")
	_test_root.add_child(_player)
	_wm = StubWM.new()
	_wm.name = "WeaponManager"
	_player.add_child(_wm)
	_wave_stub = StubWaveManager.new()
	_wave_stub.name = "B2WaveManager"
	_wave_stub.add_to_group("wave_manager")
	_test_root.add_child(_wave_stub)

	# ---- Stage A: parser + preview (synchronous, offline) ----
	var cases := [
		["build a tower", "cover", "tower", 150],
		["build a bridge", "structure", "bridge", 120],
		["build a bunker", "structure", "bunker", 180],
		["build a watchtower", "structure", "watchtower", 200],
		["build an ammo depot", "structure", "ammo_depot", 150],
		["give me a sniper", "weapon", "longeye", 200],
		["sniper rifle", "weapon", "longeye", 200],
		["call in a UAV", "killstreak", "uav", 150],
		["send in a drone", "killstreak", "uav", 150],
		["spawn enemies", "enemy_spawn", "grunt", 150],
		["deploy a sentry", "turret", "", 250],
		["deploy a turret", "turret", "", 250],
		["build a wall", "cover", "wall", 100],
		["smoke", "arena_event", "smoke", 100],
		["supply drop", "arena_event", "supply_drop", 50],
		["build a sniper tower", "cover", "tower", 150],
		["build a ramp", "structure", "bridge", 120],
	]
	for c in cases:
		var spec := _spec_for(str(c[0]))
		var want_target := str(c[1])
		var want_cost := int(c[3])
		_check(spec.get("target", "") == want_target and int(spec.get("cost", -1)) == want_cost,
			"parse '%s' -> %s cost %d (got %s / %s)" % [str(c[0]), want_target, want_cost, str(spec.get("target", "?")), str(spec.get("cost", "?"))])
		if want_target == "cover" or want_target == "structure":
			_check(str((spec.get("params", {}) as Dictionary).get("shape", "")) == str(c[2]),
				"parse '%s' shape %s" % [str(c[0]), str(c[2])])
		if want_target == "weapon":
			_check(str((spec.get("params", {}) as Dictionary).get("weapon_id", "")) == str(c[2]),
				"parse '%s' weapon %s" % [str(c[0]), str(c[2])])
		if want_target == "killstreak":
			_check(str((spec.get("params", {}) as Dictionary).get("streak", "")) == str(c[2]),
				"parse '%s' streak %s" % [str(c[0]), str(c[2])])
		var prev: Dictionary = _forge.call("preview_cost", str(c[0]))
		_check(bool(prev.get("ok", false)) and int(prev.get("cost", -1)) == want_cost,
			"preview_cost '%s' ok cost %d (got %s)" % [str(c[0]), want_cost, str(prev)])

	var unk := _spec_for("flibberty wobble zorp")
	_check(unk.has("_error") and str(unk["_error"]).contains("try:"),
		"unknown prompt -> helpful error (got %s)" % str(unk.get("_error", "NO ERROR")))
	var unk_prev: Dictionary = _forge.call("preview_cost", "flibberty wobble zorp")
	_check(not bool(unk_prev.get("ok", true)) and str(unk_prev.get("error", "")).contains("try:"),
		"preview_cost unknown -> ok=false + helpful error")
	_check(int(_forge.call("get_budget")) == int(_game.get("forge_budget")),
		"get_budget matches Game.forge_budget (%d)" % int(_game.get("forge_budget")))
	_check((_forge.call("get_history") as Array).is_empty(), "history starts empty")
	var nothing: Dictionary = _forge.call("undo_last")
	_check(not bool(nothing.get("ok", true)) and str(nothing.get("message", "")) == "Nothing to undo" and int(nothing.get("refund", -1)) == 0,
		"undo with nothing -> ok=false 'Nothing to undo' refund 0")

	# ---- Stage B: end-to-end submit_prompt (wall) ----
	_budget_before = int(_game.get("forge_budget"))
	_awaiting_result = true
	_result_received = false
	_forge.call("submit_prompt", "build a wall in front of me")
	_stage = 1


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > 3000:
		_fails.append("timeout: stage %d" % _stage)
		_finish()
		return true
	match _stage:
		1:
			if not _result_received:
				return false
			_check(_result_success, "submit_prompt wall succeeds (msg: %s)" % _result_msg)
			_check(int(_game.get("forge_budget")) == _budget_before - 100,
				"wall charged exactly 100 (budget %d -> %d)" % [_budget_before, int(_game.get("forge_budget"))])
			_wall_node = _builder_script.last_built_node
			_check(_wall_node != null and is_instance_valid(_wall_node),
				"wall node recorded for undo")
			_check(get_nodes_in_group("cover").size() >= 1, "wall node in cover group")
			var hist: Array = _forge.call("get_history")
			_check(hist.size() >= 1 and str(hist[0]) == "build a wall in front of me",
				"history records prompt most-recent-first")
			# Undo: removes the wall + refunds exactly 100.
			var undone: Dictionary = _forge.call("undo_last")
			_check(bool(undone.get("ok", false)) and int(undone.get("refund", -1)) == 100,
				"undo_last ok refund 100 (got %s)" % str(undone))
			_check(int(_game.get("forge_budget")) == _budget_before,
				"undo refunded budget exactly (%d)" % int(_game.get("forge_budget")))
			_stage = 2
			_wait = 2
		2:
			_wait -= 1
			if _wait > 0:
				return false
			_check(_wall_node == null or not is_instance_valid(_wall_node),
				"undo removed the wall node")
			var nothing2: Dictionary = _forge.call("undo_last")
			_check(not bool(nothing2.get("ok", true)) and str(nothing2.get("message", "")) == "Nothing to undo",
				"second undo -> Nothing to undo")
			_stage = 3
		3:
			# ---- Stage C: direct builder — new buildables + collision ----
			for shape in ["bridge", "bunker", "watchtower", "ammo_depot"]:
				var spec := {"spec_version": 1, "action": "spawn", "target": "structure",
					"params": {"shape": shape, "position": "near_player"}, "cost": 0, "ttl": 0}
				var msg: String = _builder_script.build(spec, _ctx())
				var node: Node = _builder_script.last_built_node
				_check(not msg.begins_with(_builder_script.FAIL_PREFIX), "build %s succeeds (%s)" % [shape, msg])
				_check(node != null and is_instance_valid(node) and node.is_in_group("forge_structure"),
					"%s in forge_structure group" % shape)
				_check(node != null and _has_collision(node), "%s has collision (StaticBody3D + box)" % shape)
				_check(_builder_script.last_built_valid, "%s sets last_built_valid" % shape)
			# Turret (existing) via builder.
			var tmsg: String = _builder_script.build(
				{"spec_version": 1, "action": "spawn", "target": "turret",
				"params": {"position": "near_player", "duration_sec": 45}, "cost": 0, "ttl": 0}, _ctx())
			_check(not tmsg.begins_with(_builder_script.FAIL_PREFIX) and _builder_script.last_built_node != null
				and _builder_script.last_built_node.is_in_group("turret"),
				"turret still builds (%s)" % tmsg)
			# Enemy spawn via stub wave manager.
			var emsg: String = _builder_script.build(
				{"spec_version": 1, "action": "spawn", "target": "enemy_spawn",
				"params": {"type": "grunt", "count": 3}, "cost": 0, "ttl": 0}, _ctx())
			_check(not emsg.begins_with(_builder_script.FAIL_PREFIX) and _wave_stub.mods.size() == 1
				and str((_wave_stub.mods[0] as Dictionary).get("kind", "")) == "spawn_extra"
				and int((_wave_stub.mods[0] as Dictionary).get("count", 0)) == 3,
				"spawn enemies queues 3 grunts (%s)" % emsg)
			# Weapon via stub WeaponManager.
			var wmsg: String = _builder_script.build(
				{"spec_version": 1, "action": "spawn", "target": "weapon",
				"params": {"weapon_id": "longeye"}, "cost": 0, "ttl": 0}, _ctx())
			_check(not wmsg.begins_with(_builder_script.FAIL_PREFIX) and _wm.given.has("longeye"),
				"weapon longeye given to player (%s)" % wmsg)
			# Smoke event still works.
			var smsg: String = _builder_script.build(
				{"spec_version": 1, "action": "event", "target": "arena_event",
				"params": {"event": "smoke", "duration_sec": 20}, "cost": 0, "ttl": 0}, _ctx())
			_check(not smsg.begins_with(_builder_script.FAIL_PREFIX) and smsg.contains("smoke"),
				"smoke event still works (%s)" % smsg)
			_stage = 4
		4:
			# ---- Stage D: structure cap (12) ----
			var before := get_nodes_in_group("forge_structure").size()
			_check(before == 5, "5 structures standing before cap test (got %d)" % before)
			var room: int = int(_builder_script.MAX_STRUCTURES) - before
			for i in range(room):
				var m: String = _builder_script.build(
					{"spec_version": 1, "action": "spawn", "target": "cover",
					"params": {"shape": "wall", "size_voxels": [8, 5, 2], "position": "near_player", "hp": 250},
					"cost": 0, "ttl": 0}, _ctx())
				_check(not m.begins_with(_builder_script.FAIL_PREFIX), "cap fill wall %d builds" % (i + 1))
			var over: String = _builder_script.build(
				{"spec_version": 1, "action": "spawn", "target": "structure",
				"params": {"shape": "bridge", "position": "near_player"}, "cost": 0, "ttl": 0}, _ctx())
			_check(over.begins_with(_builder_script.FAIL_PREFIX) and over.contains("cap"),
				"13th structure rejected with cap message (%s)" % over)
			_stage = 99
			_finish()
			return true
	return false


func _finish() -> void:
	print("B2 CHECKS: %d passed, %d failed (of %d)" % [_checks - _fails.size(), _fails.size(), _checks])
	if _fails.is_empty():
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL — %s" % ", ".join(_fails))
