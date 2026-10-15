# verify_v05_c2_killstreaks.gd — C2 killstreaks end-to-end (headless).
# Usage: godot --headless --path <project> --script res://tools/verify_v05_c2_killstreaks.gd
# Drives UAV / airstrike / chopper through the real Forge path
# (ForgeBuilder.build killstreak spec, as produced by a Forge prompt) with
# lightweight test doubles for player/enemies. Exit 0 = all checks pass.
#
# NOTE: Killstreaks / ForgeBuilder are resolved via runtime load() and the
# Forge autoload's own Killstreaks instance (group "killstreaks"), NOT via
# compile-time class references. A SceneTree script that names those classes
# forces them to compile before the Game/Sfx autoloads are registered, which
# fails with "Identifier not found: Game/Sfx" even though the same scripts
# compile fine when loaded via the main scene (see smoke_test.gd).
extends SceneTree

class TestFoe extends Node3D:
	var dead := false
	var hp := 100.0
	var damage_taken := 0.0
	func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool) -> void:
		if dead:
			return
		damage_taken += amount
		hp -= amount
		if hp <= 0.0:
			dead = true

class TestPlayer extends Node3D:
	var damage_taken := 0.0
	func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool) -> void:
		damage_taken += amount

var _root: Node3D = null
var _builder = null
var _ks = null
var _player: TestPlayer = null
var _foe1: TestFoe = null
var _foe2: TestFoe = null
var _foe_dead: TestFoe = null
var _foe3: TestFoe = null
var _stage := 0
var _stage_t := 0.0
var _failures: Array[String] = []
var _uav_started_count := 0
var _uav_started_dur := 0.0
var _uav_ended_count := 0
var _done := false


func _initialize() -> void:
	_root = Node3D.new()
	_root.name = "C2TestWorld"
	root.add_child(_root)
	current_scene = _root
	_builder = load("res://scripts/forge/forge_builder.gd")
	_player = TestPlayer.new()
	_player.name = "TestPlayer"
	_player.add_to_group("player")
	_player.position = Vector3.ZERO
	_root.add_child(_player)
	_foe1 = _make_foe("Foe1", Vector3(0, 0, -5), 100.0)
	_foe2 = _make_foe("Foe2", Vector3(50, 0, 50), 100.0)
	_foe_dead = _make_foe("FoeDead", Vector3(5, 0, 5), 100.0)
	_foe_dead.dead = true
	_stage = 0
	print("C2: setup done, waiting for Forge autoload Killstreaks")


func _make_foe(name: String, pos: Vector3, hp: float) -> TestFoe:
	var f := TestFoe.new()
	f.name = name
	f.add_to_group("enemy")
	f.position = pos  # local == global here (test root at origin); global_position before add_child errors
	f.hp = hp
	_root.add_child(f)
	return f


func _on_uav_started(duration: float) -> void:
	_uav_started_count += 1
	_uav_started_dur = duration


func _on_uav_ended() -> void:
	_uav_ended_count += 1


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("C2 FAIL: ", msg)
	_stage = 99


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("C2 OK: ", msg)
	else:
		_fail(msg)


func _set_stage(s: int) -> void:
	_stage = s
	_stage_t = 0.0


func _process(delta: float) -> bool:
	if _done:
		return true
	_stage_t += delta
	match _stage:
		0:
			# Use the Forge autoload's own Killstreaks instance (the real one).
			var found = get_first_node_in_group("killstreaks")
			if found == null:
				if _stage_t > 5.0:
					_fail("no node in group 'killstreaks' (Forge autoload missing?)")
				return false
			_ks = found
			_ks.uav_started.connect(_on_uav_started)
			_ks.uav_ended.connect(_on_uav_ended)
			print("C2: Killstreaks acquired, stage 1 (UAV via Forge builder)")
			_set_stage(1)
		1:
			# UAV via the Forge prompt path (builder killstreak spec).
			var msg: String = _builder.build(
				{"action": "event", "target": "killstreak",
				 "params": {"streak": "uav", "target": "auto"}},
				{"player": _player, "root": _root})
			print("C2: UAV builder msg: ", msg)
			_check(_uav_started_count == 1, "UAV emitted uav_started once")
			_check(_uav_started_dur == 20.0, "UAV started duration is 20s")
			var targets: Array[Vector3] = _ks.get_uav_targets()
			_check(targets.size() == 2, "UAV targets = 2 live foes (dead excluded), got %d" % targets.size())
			# Fast-forward expiry (white-box): never wait 20 real seconds.
			_ks._uav_remaining = 0.05
			_set_stage(2)
		2:
			if not _ks.is_uav_active() and _uav_ended_count == 1:
				_check(_ks.get_uav_targets().is_empty(), "UAV targets [] after uav_ended")
				_set_stage(3)
			elif _stage_t > 2.0:
				_fail("UAV did not end after expiry fast-forward")
		3:
			# Airstrike via the Forge prompt path, auto mode. Foe1 at
			# (0,0,-5) is the nearest live enemy; player at origin is 5m
			# from the blast centre (inside the 8m radius) — if damage
			# leaked to the player, this test catches it.
			_foe1.hp = 100.0
			_foe1.dead = false
			_foe1.damage_taken = 0.0
			_foe2.hp = 100.0
			_player.damage_taken = 0.0
			var msg2: String = _builder.build(
				{"action": "event", "target": "killstreak",
				 "params": {"streak": "airstrike", "target": "auto"}},
				{"player": _player, "root": _root})
			print("C2: airstrike builder msg: ", msg2)
			_check(get_nodes_in_group("airstrike_marker").size() == 1,
				"airstrike warning marker spawned")
			_set_stage(4)
		4:
			if _stage_t >= 4.0:
				_check(_foe1.dead and _foe1.damage_taken > 0.0,
					"airstrike damaged/killed foe in radius (dmg %.1f)" % _foe1.damage_taken)
				_check(_player.damage_taken == 0.0,
					"airstrike NEVER damaged the player (dmg %.1f)" % _player.damage_taken)
				_check(_foe2.hp == 100.0, "airstrike left far foe untouched")
				_check(get_nodes_in_group("airstrike_marker").is_empty(),
					"airstrike marker cleaned up after blasts")
				_set_stage(5)
		5:
			# Chopper via the Forge prompt path.
			_foe3 = _make_foe("Foe3", Vector3(10, 0, 0), 200.0)
			var msg3: String = _builder.build(
				{"action": "event", "target": "killstreak",
				 "params": {"streak": "chopper", "target": "auto"}},
				{"player": _player, "root": _root})
			print("C2: chopper builder msg: ", msg3)
			_check(get_nodes_in_group("chopper").size() == 1, "chopper spawned")
			_set_stage(6)
		6:
			if _stage_t >= 2.5:
				_check(_foe3.damage_taken > 0.0,
					"chopper fired at nearest enemy (dmg %.1f)" % _foe3.damage_taken)
				# Force-expire (white-box): never wait the full 45s.
				var choppers := get_nodes_in_group("chopper")
				if choppers.size() == 1:
					choppers[0]._t = 0.05
					_set_stage(7)
				else:
					_fail("chopper missing before forced expiry")
		7:
			if _stage_t >= 4.5:
				_check(get_nodes_in_group("chopper").is_empty(),
					"chopper despawned after leaving")
				_check(_root.find_children("ChopperTracer", "", true, false).is_empty(),
					"no lingering chopper tracers")
				_check(get_nodes_in_group("airstrike_marker").is_empty(),
					"no lingering airstrike markers")
				_check(not _ks.is_uav_active(), "UAV inactive at end")
				_set_stage(99)
		99:
			if _failures.is_empty():
				print("C2: ALL CHECKS PASSED")
			else:
				print("C2: %d FAILURE(S)" % _failures.size())
				for f in _failures:
					print("C2: - ", f)
			_done = true
			quit(1 if not _failures.is_empty() else 0)
			return true
	return false
