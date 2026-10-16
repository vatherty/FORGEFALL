# verify_v059_base_defense.gd — headless checks for FORGEFALL v0.5.9
# Worker A: BASE DEFENSE mode.
# Usage: godot --headless --path <project> --script res://tools/verify_v059_base_defense.gd
# Covers:
#   1. Registration: GameModeManager.MODES has "base_defense"; main_menu.gd
#      lists it in all three mode arrays (build / select / load).
#   2. Pure assault math: assault_split() values for no-defense,
#      fully-absorbed, and partial-overflow cases.
#   3. Full loop via Game signals: build phase -> combat wave -> core
#      takes damage -> wave cleared -> build phase again.
#   4. The point of the mode: a run WITH Forge structures (4 walls)
#      outlasts a run WITHOUT building, measured with the real tick
#      (_tick_assault) + real ForgeStructure nodes (structures soak
#      damage, core untouched while absorption holds, then falls).
#   5. Defeat: core at 0 -> phase "over" + end screen visible.
#   6. Retry: core restored, end screen hidden, phase back to build.
#   7. Player death redeploys (run does NOT end on player death).
#   8. GameModeManager.start("base_defense") spawns a BaseDefenseMode child.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# NOTE: game scripts are load()ed at runtime (like check_scripts.gd),
# never referenced as parse-time class names: a SceneTree --script is
# compiled before autoload globals exist, so parse-time dependencies
# on scripts that mention `Game` fail to compile in this context.
extends SceneTree

class FakeEnemy extends Node3D:
	var active := true
	var dead := false

class FakePlayer extends Node3D:
	var respawn_called := false
	var respawn_pos := Vector3.ZERO

	func respawn(pos: Vector3) -> void:
		respawn_called = true
		respawn_pos = pos

var _fails := 0
var _phase := 0
var _wait := 0
var _bd: Node = null
var _fakes: Array[Node] = []
var _walls: Array[Node] = []
var _fake_player: FakePlayer = null
var _sim_a_time := 0.0
var _sim_b_time := 0.0
var _mgr: Node = null
var _game: Node = null
var _bd_script: Script = null
var _mgr_script: Script = null
var _forge_script: Script = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _make_bd() -> Node:
	var bd: Node = _bd_script.new()
	root.add_child(bd)
	return bd


func _add_fakes(count: int) -> void:
	for i in count:
		var f := FakeEnemy.new()
		f.position = Vector3(5, 0, 5)
		root.add_child(f)
		f.add_to_group("enemy")
		_fakes.append(f)


func _add_walls(count: int) -> void:
	for i in count:
		var w: Node = _forge_script.new()
		w.call("setup", "wall", 400.0, Vector3(6.0, 3.0, 0.6))
		w.position = Vector3(2, 0, 2)
		root.add_child(w)
		_walls.append(w)


func _free_fakes() -> void:
	for f in _fakes:
		if is_instance_valid(f):
			(f as Node).queue_free()
	_fakes.clear()


func _free_walls() -> void:
	for w in _walls:
		if is_instance_valid(w):
			(w as Node).queue_free()
	_walls.clear()


func _free_bd() -> void:
	if _bd != null and is_instance_valid(_bd):
		_bd.queue_free()
	_bd = null


func _process(_delta: float) -> bool:
	if _wait > 0:
		_wait -= 1
		return false
	match _phase:
		0:
			# --- Load game scripts at runtime; registration + pure math ---
			_bd_script = load("res://scripts/modes/base_defense.gd") as Script
			_mgr_script = load("res://scripts/core/game_mode.gd") as Script
			_forge_script = load("res://scripts/forge/forge_structure.gd") as Script
			_game = root.get_node_or_null("Game")
			_check(_game != null, "Game autoload present as root child")
			_check(_bd_script != null and _bd_script.can_instantiate(), "base_defense.gd loads + instantiates")
			_check(_mgr_script != null and _mgr_script.can_instantiate(), "game_mode.gd loads + instantiates")
			var modes: Dictionary = _mgr_script.get("MODES")
			_check(modes.has("base_defense"), "MODES registers base_defense")
			_check(str((modes.get("base_defense", {}) as Dictionary).get("name", "")) == "BASE DEFENSE", "MODES base_defense name is BASE DEFENSE")
			var src := ""
			var f := FileAccess.open("res://scripts/ui/main_menu.gd", FileAccess.READ)
			if f != null:
				src = f.get_as_text()
			_check(src.count("base_defense") >= 3, "main_menu.gd lists base_defense in build/select/load arrays (>=3 hits)")
			var s0: Dictionary = _bd_script.assault_split(5, 1, 0)
			_check(is_equal_approx(float(s0["incoming"]), 30.0) and is_equal_approx(float(s0["absorbed"]), 0.0) and is_equal_approx(float(s0["overflow"]), 30.0), "assault_split: 5 enemies, 0 structures -> 30 incoming, 0 absorbed, 30 overflow")
			var s1: Dictionary = _bd_script.assault_split(5, 1, 4)
			_check(is_equal_approx(float(s1["absorbed"]), 30.0) and is_equal_approx(float(s1["overflow"]), 0.0) and is_equal_approx(float(s1["per_structure"]), 7.5), "assault_split: 5 enemies, 4 structures -> fully absorbed, 7.5 per structure")
			var s2: Dictionary = _bd_script.assault_split(10, 1, 2)
			_check(is_equal_approx(float(s2["incoming"]), 60.0) and is_equal_approx(float(s2["absorbed"]), 16.0) and is_equal_approx(float(s2["overflow"]), 44.0) and is_equal_approx(float(s2["per_structure"]), 8.0), "assault_split: 10 enemies, 2 structures -> 16 absorbed, 44 overflow, 8.0 per structure")
			var s3: Dictionary = _bd_script.assault_split(5, 3, 0)
			_check(is_equal_approx(float(s3["incoming"]), 33.0), "assault_split: wave 3 scales DPS +10% (5 x 6.6 = 33)")
			# --- Standalone start state ---
			_bd = _make_bd()
			_check(str(_bd.get("phase")) == "build", "standalone BaseDefense starts in build phase")
			_check(is_equal_approx(float(_bd.get("core_hp")), float(_bd_script.get("CORE_MAX_HP"))), "core starts at full HP (1000)")
			_check(_bd.get_node_or_null("BaseCore") != null, "core node spawned")
			_phase = 1
		1:
			# --- Full loop via Game signals ---
			_game.build_phase_started.emit(20)
			_check(str(_bd.get("phase")) == "build", "build_phase_started -> build phase")
			_game.wave_started.emit(1)
			_check(str(_bd.get("phase")) == "combat" and int(_bd.get("wave")) == 1, "wave_started(1) -> combat phase, wave 1")
			_add_fakes(5)
			for i in 10:
				_bd.call("_tick_assault", 0.5)
			_check(is_equal_approx(float(_bd.get("core_hp")), 850.0), "5 enemies x 5s unopposed assault -> core 1000 -> 850 (30 dps)")
			_game.wave_cleared.emit(1)
			_check(int(_bd.get("waves_survived")) == 1, "wave_cleared(1) -> waves_survived 1")
			_game.build_phase_started.emit(20)
			_check(str(_bd.get("phase")) == "build", "next build_phase_started -> build phase again")
			_free_fakes()
			_free_bd()
			_wait = 2
			_phase = 2
		2:
			# --- Sim A: NO building ---
			_bd = _make_bd()
			_add_fakes(5)
			var iters := 0
			while float(_bd.get("core_hp")) > 0.0 and iters < 300:
				_bd.call("_tick_assault", 0.5)
				iters += 1
			_sim_a_time = iters * 0.5
			_check(str(_bd.get("phase")) == "over", "no-building run: core falls -> phase over")
			_check(_bd.get_node_or_null("BaseDefenseEndScreen") != null and (_bd.get_node_or_null("BaseDefenseEndScreen") as Control).visible, "no-building run: defeat end screen visible")
			print("SIM A (no building): core fell after %.1fs of assault" % _sim_a_time)
			_free_fakes()
			_free_bd()
			_wait = 2
			_phase = 3
		3:
			# --- Sim B: WITH building (4 walls) ---
			_bd = _make_bd()
			_add_walls(4)
			_add_fakes(5)
			for i in 4:
				_bd.call("_tick_assault", 0.5)
			_check(is_equal_approx(float(_bd.get("core_hp")), float(_bd_script.get("CORE_MAX_HP"))), "with 4 walls: core untouched after 2s (fully absorbed)")
			var wall_hp: float = float(_forge_script.hp_of(_walls[0])) if not _walls.is_empty() else -1.0
			_check(wall_hp < 400.0 and wall_hp > 300.0, "with 4 walls: structures soak the damage (wall HP dropped below 400)")
			var iters2 := 4
			while float(_bd.get("core_hp")) > 0.0 and iters2 < 400:
				_bd.call("_tick_assault", 0.5)
				iters2 += 1
			_sim_b_time = iters2 * 0.5
			_check(str(_bd.get("phase")) == "over", "with-building run: core eventually falls -> phase over")
			print("SIM B (4 walls): core fell after %.1fs of assault" % _sim_b_time)
			_check(_sim_b_time > _sim_a_time + 20.0, "WITH building outlasts WITHOUT by >20s (%.1fs vs %.1fs)" % [_sim_b_time, _sim_a_time])
			_phase = 4
		4:
			# --- Retry ---
			_bd.call("_on_retry")
			_check(is_equal_approx(float(_bd.get("core_hp")), float(_bd_script.get("CORE_MAX_HP"))), "retry: core restored to full")
			_check(str(_bd.get("phase")) == "build" and int(_bd.get("waves_survived")) == 0, "retry: phase build, waves_survived reset")
			var scr := _bd.get_node_or_null("BaseDefenseEndScreen") as Control
			_check(scr == null or not scr.visible, "retry: end screen hidden")
			_phase = 5
		5:
			# --- Player death redeploys; run continues ---
			_fake_player = FakePlayer.new()
			_fake_player.position = Vector3(0, 1, 0)
			root.add_child(_fake_player)
			_fake_player.add_to_group("player")
			_game.player_died.emit()
			_bd.call("_process", 3.5)
			_check(_fake_player.respawn_called, "player death -> redeploy respawn called after delay")
			_check(str(_bd.get("phase")) != "over", "player death does NOT end the base-defense run")
			_free_walls()
			_free_fakes()
			if is_instance_valid(_fake_player):
				_fake_player.queue_free()
			_fake_player = null
			_free_bd()
			_wait = 2
			_phase = 6
		6:
			# --- GameModeManager hook ---
			_mgr = _mgr_script.new()
			root.add_child(_mgr)
			_mgr.call("start", "base_defense")
			var found := false
			for c in _mgr.get_children():
				if (c as Node).get_script() == _bd_script:
					found = true
			_check(found, "GameModeManager.start('base_defense') spawns a BaseDefenseMode child")
			if is_instance_valid(_mgr):
				_mgr.queue_free()
			_mgr = null
			_phase = 7
		7:
			print("verify_v059_base_defense: %d FAILURES (A=%.1fs B=%.1fs)" % [_fails, _sim_a_time, _sim_b_time])
			quit(0 if _fails == 0 else 1)
	return false
