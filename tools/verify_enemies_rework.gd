# FORGEFALL — verify_enemies_rework (ENEMIES REWORK, 2026-10-16)
#
# Verifies the full enemy redo through the REAL APIs:
#   BEHAVIOUR: each of the 8 chassis has distinct AI (behaviour_tags —
#     none returns the base ["run_at_player"]); approach patterns are
#     driven tick-by-tick (_ai_physics with an injected dummy player):
#     grunt bounding overwatch, rusher feint jukes + telegraphed blast,
#     marksman crouch-aim, brute ground slam, shredder lunge slash,
#     suppressor sweeping burst, bulwark shield bash, warlord slam.
#   TELEGRAPHS: every attack announces its wind-up through the unified
#     begin_telegraph / is_winding_up / telegraph_progress channel.
#   ANIMATION: VoxelSoldier.animate_full advances limb swing while
#     moving, wind-up / strike / flinch / crouch / strafe / idle-scan
#     poses, and the code-driven death crumple; a lethal hit drives the
#     crumple through _physics_process.
#   D&D: creature-type resistances / immunities still enforced through
#     take_typed_damage; condition gating still enforced.
#   COMPAT: WaveManager spawn queue, Forge enemy_spawn, take_damage /
#     take_typed_damage signatures, creature types, ability scores.
#
# Run: godot --headless --path . --script res://tools/verify_enemies_rework.gd
# Exit code 0 = all checks passed.
extends SceneTree

var _fails := 0
var _checks := 0
var _ran := false

var _Grunt: GDScript
var _Rusher: GDScript
var _Marksman: GDScript
var _Brute: GDScript
var _Shredder: GDScript
var _Suppressor: GDScript
var _Bulwark: GDScript
var _Warlord: GDScript
var _Soldier: GDScript
var _WaveManager: GDScript
var _ForgeBuilder: GDScript
var _DnDTypes: GDScript


class DummyPlayer extends CharacterBody3D:
	var hp := 1000.0
	var hits: Array = []
	var total_damage := 0.0
	func take_damage(amount: float, _pos: Vector3, _head: bool, _attacker: Node = null) -> void:
		hp -= amount
		total_damage += amount
		hits.append(amount)


class FakeWaveManager extends Node:
	var received: Array = []
	func apply_director_mod(mod: Dictionary) -> void:
		received.append(mod)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % label)
	else:
		_fails += 1
		print("FAIL: %s" % label)


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_Grunt = load("res://scripts/enemies/grunt.gd")
	_Rusher = load("res://scripts/enemies/rusher.gd")
	_Marksman = load("res://scripts/enemies/marksman.gd")
	_Brute = load("res://scripts/enemies/brute.gd")
	_Shredder = load("res://scripts/enemies/shredder.gd")
	_Suppressor = load("res://scripts/enemies/suppressor.gd")
	_Bulwark = load("res://scripts/enemies/bulwark.gd")
	_Warlord = load("res://scripts/enemies/warlord.gd")
	_Soldier = load("res://scripts/enemies/voxel_soldier.gd")
	_WaveManager = load("res://scripts/enemies/wave_manager.gd")
	_ForgeBuilder = load("res://scripts/forge/forge_builder.gd")
	_DnDTypes = load("res://scripts/data/dnd_types.gd")
	var root: Window = self.root
	var arena := Node3D.new()
	arena.name = "EnemiesReworkArena"
	root.add_child(arena)
	var dummy := DummyPlayer.new()
	dummy.name = "DummyPlayer"
	dummy.global_position = Vector3(0, 0, 10)
	arena.add_child(dummy)
	dummy.add_to_group("player")

	_test_tags(arena)
	_test_telegraph_api(arena)
	_test_grunt_bounding(arena, dummy)
	_test_rusher(arena, dummy)
	_test_marksman(arena, dummy)
	_test_brute_slam(arena, dummy)
	_test_shredder(arena, dummy)
	_test_suppressor_sweep(arena, dummy)
	_test_bulwark(arena, dummy)
	_test_warlord(arena, dummy)
	_test_animation()
	_test_death_crumple(arena)
	_test_dnd(arena)
	_test_compat(root, arena)
	arena.free()
	print("== verify_enemies_rework: %d checks, %d failures ==" % [_checks, _fails])
	quit(0 if _fails == 0 else 1)
	return true


# --- helpers ---------------------------------------------------------------
func _make_enemy(script: GDScript, arena: Node3D, pos: Vector3) -> CharacterBody3D:
	var e: CharacterBody3D = script.new()
	arena.add_child(e)
	e.call("activate", pos, 1, {})
	return e


func _face(e: Node3D, target: Vector3) -> void:
	var d: Vector3 = target - e.global_position
	e.rotation.y = atan2(-d.x, -d.z)


func _drive(e: CharacterBody3D, seconds: float, step: float = 0.016) -> void:
	var t := 0.0
	while t < seconds:
		e.call("_ai_physics", step)
		t += step


# --- 1. distinct behaviour tags --------------------------------------------
func _test_tags(arena: Node3D) -> void:
	var scripts := {"grunt": _Grunt, "rusher": _Rusher, "marksman": _Marksman,
		"brute": _Brute, "shredder": _Shredder, "suppressor": _Suppressor,
		"bulwark": _Bulwark, "warlord": _Warlord}
	var seen: Array = []
	for type_id in scripts.keys():
		var e: CharacterBody3D = (scripts[type_id] as GDScript).new()
		arena.add_child(e)
		_check(str(e.get("type_id")) == type_id, "%s: type_id intact" % type_id)
		var tags: Array = e.call("behaviour_tags")
		_check(tags.size() >= 3, "%s: >=3 behaviour tags (%s)" % [type_id, str(tags)])
		_check(not (tags.size() == 1 and str(tags[0]) == "run_at_player"),
			"%s: does NOT just run at the player" % type_id)
		_check(not seen.has(str(tags)), "%s: behaviour tags distinct from other types" % type_id)
		seen.append(str(tags))
		_check(str(e.get("creature_type")) == "humanoid", "%s: base creature type humanoid" % type_id)
		var scores: Dictionary = e.get("ability_scores")
		_check(scores.size() == 6, "%s: ability scores intact (6 abilities)" % type_id)
		e.free()


# --- 2. unified telegraph API ------------------------------------------------
func _test_telegraph_api(arena: Node3D) -> void:
	var g := _make_enemy(_Grunt, arena, Vector3(0, 0.5, 0))
	_check(not bool(g.call("is_winding_up")), "telegraph: idle enemy is not winding up")
	_check(is_equal_approx(float(g.call("telegraph_progress")), 0.0), "telegraph: progress 0 when idle")
	g.call("begin_telegraph", 1.0, "aim")
	_check(bool(g.call("is_winding_up")), "telegraph: winding up after begin_telegraph")
	_check(str(g.get("attack_telegraph_kind")) == "aim", "telegraph: kind recorded")
	_check(is_equal_approx(float(g.call("telegraph_progress")), 0.0), "telegraph: progress 0 at wind-up start")
	g.call("_physics_process", 0.5)
	_check(absf(float(g.call("telegraph_progress")) - 0.5) < 0.05,
		"telegraph: progress ~0.5 halfway (%.2f)" % float(g.call("telegraph_progress")))
	var g2 := _make_enemy(_Grunt, arena, Vector3(5, 0.5, 0))
	g2.call("begin_telegraph", 0.4, "aim")
	g2.call("_physics_process", 0.5)
	_check(not bool(g2.call("is_winding_up")), "telegraph: expires after its duration")
	g.free()
	g2.free()


# --- 3. grunt bounding overwatch + fire telegraph ---------------------------
func _test_grunt_bounding(arena: Node3D, dummy: DummyPlayer) -> void:
	var g := _make_enemy(_Grunt, arena, Vector3(0, 0.5, 0))
	dummy.global_position = Vector3(0, 0.5, 25)
	g.set("_can_see", true)
	g.set("state", 1)  # ADVANCE
	var saw_moving := false
	var saw_planted := false
	for i in 80:  # 4s at 0.05s
		g.call("_ai_physics", 0.05)
		var w: Vector3 = g.get("wish_dir")
		if w.length() > 0.1:
			saw_moving = true
		if w.length() < 0.05:
			saw_planted = true
	_check(saw_moving, "grunt: bounding advance includes a MOVING bound")
	_check(saw_planted, "grunt: bounding advance includes a PLANTED (firing) bound")
	# Fire telegraph from COMBAT.
	g.set("state", 2)  # COMBAT
	g.set("_fire_t", 0.0)
	g.set("_aim_t", 0.0)
	g.call("_ai_physics", 0.016)
	_check(bool(g.call("is_winding_up")), "grunt: fires only after a telegraphed aim")
	_check(str(g.get("attack_telegraph_kind")) == "aim", "grunt: aim telegraph kind")
	g.free()


# --- 4. rusher jukes + telegraphed blast -----------------------------------
func _test_rusher(arena: Node3D, dummy: DummyPlayer) -> void:
	# Jukes: hard lateral cuts during the charge.
	var r := _make_enemy(_Rusher, arena, Vector3(0, 0.5, 0))
	dummy.global_position = Vector3(20, 0.5, 0)
	r.set("_can_see", true)
	r.set("state", 1)  # CHARGE
	var max_perp := 0.0
	for i in 60:  # 3s at 0.05s
		r.call("_ai_physics", 0.05)
		var w: Vector3 = r.get("wish_dir")
		max_perp = maxf(max_perp, absf(w.z))  # perp to +X approach is Z
	_check(max_perp > 0.7, "rusher: feint juke cuts hard sideways (max perp %.2f)" % max_perp)
	r.free()
	# Telegraphed blast: CHARGE -> WINDUP -> BLAST, never instant.
	var r2 := _make_enemy(_Rusher, arena, Vector3(0, 0.5, 0))
	dummy.global_position = Vector3(3, 0.5, 0)
	r2.set("_can_see", true)
	r2.set("state", 1)  # CHARGE
	r2.call("_ai_physics", 0.016)
	_check(int(r2.get("state")) == 2, "rusher: enters WINDUP in blast range (no instant blast)")
	_check(bool(r2.call("is_winding_up")), "rusher: blast wind-up telegraphed")
	_check(str(r2.get("attack_telegraph_kind")) == "blast", "rusher: blast telegraph kind")
	_drive(r2, 0.45)
	_check(int(r2.get("state")) == 3, "rusher: wind-up resolves into BLAST strafe")
	r2.free()


# --- 5. marksman crouch-aim --------------------------------------------------
func _test_marksman(arena: Node3D, dummy: DummyPlayer) -> void:
	var m := _make_enemy(_Marksman, arena, Vector3(0, 0.5, 0))
	dummy.global_position = Vector3(28, 0.5, 0)
	m.set("_can_see", true)
	m.set("state", 1)  # HOLD
	m.set("_fire_t", 0.0)
	m.set("_aim_t", 0.0)
	m.call("_ai_physics", 0.016)
	_check(bool(m.call("is_winding_up")), "marksman: long aim telegraphed")
	_check(str(m.get("attack_telegraph_kind")) == "snipe", "marksman: snipe telegraph kind")
	m.call("_ai_physics", 0.016)  # second tick: now inside the aim, crouch applies
	_check(is_equal_approx(float(m.get("anim_crouch")), 1.0), "marksman: crouches into the shot")
	_drive(m, 1.2)
	_check(is_equal_approx(float(m.get("anim_crouch")), 0.0), "marksman: stands after the shot")
	m.free()


# --- 6. brute ground slam ------------------------------------------------------
func _test_brute_slam(arena: Node3D, dummy: DummyPlayer) -> void:
	var b := _make_enemy(_Brute, arena, Vector3(0, 0.5, 0))
	dummy.total_damage = 0.0
	dummy.global_position = Vector3(2.5, 0.5, 0)
	b.set("_can_see", true)
	b.set("_slam_cooldown", 0.0)
	b.set("state", 1)  # ADVANCE
	b.call("_ai_physics", 0.016)
	_check(int(b.get("state")) == 3, "brute: close-in player triggers SLAM wind-up")
	_check(bool(b.call("is_winding_up")), "brute: slam telegraphed")
	_check(str(b.get("attack_telegraph_kind")) == "slam", "brute: slam telegraph kind")
	_drive(b, 0.95)
	_check(int(b.get("state")) == 4, "brute: slam resolves into RECOVER")
	_check(dummy.total_damage > 0.0, "brute: slam shockwave damages (%.1f)" % dummy.total_damage)
	_check(dummy.total_damage < 30.0, "brute: slam falloff applies at 2.5m (%.1f < 30)" % dummy.total_damage)
	b.free()


# --- 7. shredder lunge slash ---------------------------------------------------
func _test_shredder(arena: Node3D, dummy: DummyPlayer) -> void:
	var s := _make_enemy(_Shredder, arena, Vector3(0, 0.5, 0))
	dummy.total_damage = 0.0
	dummy.global_position = Vector3(0, 0.5, -2)  # in front (facing -Z)
	_face(s, dummy.global_position)
	s.set("_can_see", true)
	s.set("state", 1)  # CHARGE
	s.call("_ai_physics", 0.016)
	_check(int(s.get("state")) == 2, "shredder: enters WINDUP in melee range")
	_check(bool(s.call("is_winding_up")), "shredder: slash telegraphed")
	_drive(s, 0.55)
	_check(int(s.get("state")) == 3, "shredder: slash resolves into RECOVER")
	_check(is_equal_approx(dummy.total_damage, 18.0), "shredder: frontal slash lands 18 (%.1f)" % dummy.total_damage)
	s.free()
	# Behind the shredder: the slash whiffs.
	var s2 := _make_enemy(_Shredder, arena, Vector3(0, 0.5, 0))
	dummy.total_damage = 0.0
	dummy.global_position = Vector3(0, 0.5, 2)  # behind
	_face(s2, Vector3(0, 0.5, -10))  # faces away from the player
	s2.set("_can_see", true)
	s2.set("state", 1)
	s2.call("_ai_physics", 0.016)
	_drive(s2, 0.55)
	_check(is_equal_approx(dummy.total_damage, 0.0), "shredder: slash whiffs from behind")
	s2.free()


# --- 8. suppressor sweeping burst ----------------------------------------------
func _test_suppressor_sweep(arena: Node3D, dummy: DummyPlayer) -> void:
	var s := _make_enemy(_Suppressor, arena, Vector3(0, 0.5, 0))
	dummy.global_position = Vector3(35, 0.5, 0)
	s.set("_can_see", true)
	s.set("state", 1)  # HOLD
	s.set("_fire_t", 0.0)
	s.set("_aim_t", 0.0)
	var saw_sweep := false
	for i in 100:  # 1.6s at 0.016s
		s.call("_ai_physics", 0.016)
		if (s.get("aim_offset") as Vector3).length() > 0.5:
			saw_sweep = true
	_check(bool(s.call("is_winding_up")) or saw_sweep, "suppressor: telegraphed pre-burst aim")
	_check(saw_sweep, "suppressor: burst SWEEPS laterally (aim_offset moves)")
	s.free()


# --- 9. bulwark shield + bash ---------------------------------------------------
func _test_bulwark(arena: Node3D, dummy: DummyPlayer) -> void:
	# Shield rule: frontal body 25%, headshot bypass, rear full.
	var b := _make_enemy(_Bulwark, arena, Vector3(0, 0.5, 0))
	b.rotation.y = 0.0  # faces -Z
	var hp0: float = b.get("hp")
	b.call("take_damage", 100.0, Vector3(0, 0.5, -2), false)  # frontal body
	_check(is_equal_approx(hp0 - float(b.get("hp")), 25.0), "bulwark: frontal body shot shielded to 25%%")
	b.call("take_damage", 100.0, Vector3(0, 0.5, 2), false)  # rear body
	_check(is_equal_approx(hp0 - 25.0 - float(b.get("hp")), 100.0), "bulwark: rear shot deals full damage")
	# Frontal headshot: bypasses the shield (full damage) AND takes the
	# base x2 headshot multiplier: 40 -> 80.
	b.call("take_damage", 40.0, Vector3(0, 0.5, -2), true)  # frontal headshot
	_check(is_equal_approx(hp0 - 25.0 - 100.0 - float(b.get("hp")), 80.0), "bulwark: headshot bypasses the shield (40 -> 80)")
	b.free()
	# Bash: close-in player triggers the telegraphed bash.
	var b2 := _make_enemy(_Bulwark, arena, Vector3(0, 0.5, 0))
	dummy.total_damage = 0.0
	dummy.global_position = Vector3(0, 0.5, -2)  # in front
	_face(b2, dummy.global_position)
	b2.set("_can_see", true)
	b2.set("_bash_cooldown", 0.0)
	b2.set("state", 1)  # ADVANCE
	b2.call("_ai_physics", 0.016)
	_check(int(b2.get("state")) == 3, "bulwark: close-in player triggers BASH wind-up")
	_check(str(b2.get("attack_telegraph_kind")) == "bash", "bulwark: bash telegraph kind")
	_drive(b2, 0.75)
	_check(int(b2.get("state")) == 4, "bulwark: bash resolves into RECOVER")
	_check(is_equal_approx(dummy.total_damage, 16.0), "bulwark: bash lands 16 (%.1f)" % dummy.total_damage)
	b2.free()


# --- 10. warlord slam ------------------------------------------------------------
func _test_warlord(arena: Node3D, dummy: DummyPlayer) -> void:
	var w := _make_enemy(_Warlord, arena, Vector3(0, 0.5, 0))
	dummy.total_damage = 0.0
	dummy.global_position = Vector3(5, 0.5, 0)
	w.set("hp", float(w.get("max_hp")) * 0.2)  # phase 3
	w.set("_slam_cooldown", 0.0)
	w.set("_can_see", true)
	w.set("state", 1)  # ADVANCE
	_check(int(w.call("phase")) == 3, "warlord: phase 3 at 20%% HP")
	w.call("_ai_physics", 0.016)
	_check(int(w.get("state")) == 3, "warlord: phase-3 close-in triggers SLAM_TELEGRAPH")
	_check(bool(w.call("is_winding_up")), "warlord: slam telegraphed")
	_drive(w, 1.2)
	_check(int(w.get("state")) == 4, "warlord: slam resolves into SLAM_RECOVER")
	_check(dummy.total_damage > 0.0, "warlord: slam damages with falloff (%.1f)" % dummy.total_damage)
	w.free()


# --- 11. procedural animation -------------------------------------------------------
func _test_animation() -> void:
	var soldier: Node3D = _Soldier.new()
	# One soldier per type: rig contract + model mass.
	for type_id in ["grunt", "rusher", "marksman", "brute", "shredder", "suppressor", "bulwark", "warlord"]:
		var s: Node3D = _Soldier.new()
		var rig: Dictionary = s.call("build", type_id)
		_check(rig.has("leg_l") and rig.has("leg_r") and rig.has("arm_l") and rig.has("arm_r")
			and rig.has("head") and rig.has("muzzle") and rig.has("head_hitbox") and rig.has("body_root"),
			"model: %s rig has every pivot (legs/arms/head/muzzle/headbox)" % type_id)
		var headbox: Area3D = rig["head_hitbox"]
		_check(headbox.is_in_group("enemy_head"), "model: %s head hitbox in enemy_head group" % type_id)
		var meshes := s.find_children("*", "MeshInstance3D", true, false)
		_check(meshes.size() > 20, "model: %s rebuilt with dressing (%d meshes)" % [type_id, meshes.size()])
		s.free()
	# Limb swing while moving.
	soldier.call("build", "grunt")
	var leg_l: Node3D = soldier.get("_leg_l")
	var leg_r: Node3D = soldier.get("_leg_r")
	var arm_r: Node3D = soldier.get("_arm_r")
	var body: Node3D = soldier.get("_body_root")
	var head: Node3D = soldier.get("_head_pivot")
	var lo := 999.0
	var hi := -999.0
	for i in 12:
		soldier.call("animate_full", 0.05, {"speed": 4.0})
		lo = minf(lo, leg_l.rotation.x)
		hi = maxf(hi, leg_l.rotation.x)
	_check(hi - lo > 0.2, "anim: legs swing while moving (range %.2f)" % (hi - lo))
	# Wind-up: arms draw back + lamp brightens.
	soldier.call("reset_pose")
	for i in 10:
		soldier.call("animate_full", 0.05, {"aiming": true, "windup": 0.0})
	var arm_idle: float = arm_r.rotation.x
	soldier.call("reset_pose")
	for i in 10:
		soldier.call("animate_full", 0.05, {"aiming": true, "windup": 1.0})
	_check(arm_r.rotation.x < arm_idle - 0.3, "anim: wind-up draws the weapon back (%.2f -> %.2f)" % [arm_idle, arm_r.rotation.x])
	var lamp_mat: StandardMaterial3D = soldier.get("_lamp_mat")
	_check(lamp_mat.albedo_color.r > 0.5, "anim: telegraph lamp brightens on wind-up (r=%.2f)" % lamp_mat.albedo_color.r)
	soldier.call("reset_pose")
	for i in 10:
		soldier.call("animate_full", 0.05, {"aiming": true, "windup": 0.0})
	_check((soldier.get("_lamp_mat") as StandardMaterial3D).albedo_color.r < 0.3, "anim: lamp dims at rest")
	# Strike: torso lunges forward.
	soldier.call("reset_pose")
	for i in 5:
		soldier.call("animate_full", 0.05, {"strike": 1.0})
	_check(body.rotation.x < -0.1, "anim: strike lunges the torso forward (%.2f)" % body.rotation.x)
	# Hit reaction: torso snaps back.
	soldier.call("reset_pose")
	for i in 5:
		soldier.call("animate_full", 0.05, {"flinch": 1.0})
	_check(body.rotation.x > 0.1, "anim: flinch snaps the torso back (%.2f)" % body.rotation.x)
	# Crouch: body drops.
	soldier.call("reset_pose")
	for i in 5:
		soldier.call("animate_full", 0.05, {"crouch": 1.0})
	_check(body.position.y < -0.2, "anim: crouch drops the body (%.2f)" % body.position.y)
	# Strafe: body tilts into the strafe.
	soldier.call("reset_pose")
	for i in 5:
		soldier.call("animate_full", 0.05, {"strafe": 1.0})
	_check(body.rotation.z < -0.05, "anim: strafe tilts the body (%.2f)" % body.rotation.z)
	# Idle: head scans.
	soldier.call("reset_pose")
	var hlo := 999.0
	var hhi := -999.0
	for i in 20:
		soldier.call("animate_full", 0.05, {"speed": 0.0})
		hlo = minf(hlo, head.rotation.y)
		hhi = maxf(hhi, head.rotation.y)
	_check(hhi - hlo > 0.05, "anim: idle head scans (range %.2f)" % (hhi - hlo))
	# Death crumple: knees buckle, body tips face-down.
	soldier.call("reset_pose")
	soldier.call("animate_full", 0.05, {"death": 0.9})
	_check(body.rotation.x < -1.0, "anim: death tips the body face-down (%.2f)" % body.rotation.x)
	_check(body.position.y < -0.2, "anim: death buckles the knees (y=%.2f)" % body.position.y)
	# reset_pose restores the bind pose.
	soldier.call("reset_pose")
	_check(is_equal_approx(leg_l.rotation.x, 0.0) and is_equal_approx(body.rotation.x, 0.0)
		and is_equal_approx(body.position.y, 0.0), "anim: reset_pose restores the bind pose")
	soldier.free()


# --- 12. death crumple through the live loop ------------------------------------
func _test_death_crumple(arena: Node3D) -> void:
	var g := _make_enemy(_Grunt, arena, Vector3(0, 0.5, 0))
	g.call("take_damage", 10000.0, Vector3(0, 0.5, 2), false)
	_check(bool(g.get("dead")), "death: lethal hit kills")
	for i in 6:
		g.call("_physics_process", 0.1)
	var body: Node3D = (g.get("soldier") as Node3D).get("_body_root")
	_check(body.rotation.x < -0.5, "death: crumple tips the body through the live loop (%.2f)" % body.rotation.x)
	g.free()


# --- 13. D&D enforcement -----------------------------------------------------------
func _test_dnd(arena: Node3D) -> void:
	var e := _make_enemy(_Grunt, arena, Vector3(0, 0.5, 0))
	var hp0: float = e.get("hp")
	_check(bool(e.call("set_creature_type", "construct")), "dnd: set_creature_type(construct)")
	e.call("take_typed_damage", 40.0, "poison", Vector3(0, 0.5, 2), false)
	_check(is_equal_approx(float(e.get("hp")), hp0), "dnd: construct immune to poison (hp unchanged)")
	_check(is_equal_approx(float(e.get("last_damage_multiplier")), 0.0), "dnd: poison multiplier 0 on construct")
	e.call("take_typed_damage", 40.0, "psychic", Vector3(0, 0.5, 2), false)
	_check(is_equal_approx(float(e.get("hp")), hp0), "dnd: construct immune to psychic")
	e.free()
	var o := _make_enemy(_Grunt, arena, Vector3(0, 0.5, 0))
	o.call("set_creature_type", "ooze")
	var ohp: float = o.get("hp")
	o.call("take_typed_damage", 40.0, "acid", Vector3(0, 0.5, 2), false)
	_check(is_equal_approx(float(o.get("hp")), ohp - 20.0), "dnd: ooze resists acid (40 -> 20)")
	_check(is_equal_approx(float(o.get("last_damage_multiplier")), 0.5), "dnd: acid multiplier 0.5 on ooze")
	o.free()
	var f := _make_enemy(_Grunt, arena, Vector3(0, 0.5, 0))
	f.call("set_creature_type", "fiend")
	var fhp: float = f.get("hp")
	f.call("take_typed_damage", 40.0, "fire", Vector3(0, 0.5, 2), false)
	_check(is_equal_approx(float(f.get("hp")), fhp - 20.0), "dnd: fiend resists fire (40 -> 20)")
	f.free()
	var u := _make_enemy(_Grunt, arena, Vector3(0, 0.5, 0))
	u.call("set_creature_type", "undead")
	var uhp: float = u.get("hp")
	u.call("take_typed_damage", 40.0, "poison", Vector3(0, 0.5, 2), false)
	_check(is_equal_approx(float(u.get("hp")), uhp), "dnd: undead immune to poison")
	_check(not bool(u.call("apply_status_effect", "poison", {}, Vector3.ZERO)),
		"dnd: poison status refused on construct/undead-gated type")
	u.free()


# --- 14. spawn / Forge / damage compat ----------------------------------------------
func _test_compat(root: Window, arena: Node3D) -> void:
	# Forge enemy_spawn -> WaveManager director mod (fake manager).
	var fake := FakeWaveManager.new()
	root.add_child(fake)
	fake.add_to_group("wave_manager")
	var msg: String = _ForgeBuilder.call("_build_enemy_spawn",
		{"type": "brute", "count": 2, "creature_type": "undead"}, root)
	_check(fake.received.size() == 1, "compat: Forge enemy_spawn reaches the wave manager")
	if fake.received.size() == 1:
		var mod: Dictionary = fake.received[0]
		_check(str(mod.get("kind")) == "spawn_extra" and str(mod.get("type")) == "brute"
			and int(mod.get("count")) == 2 and str(mod.get("creature_type")) == "undead",
			"compat: Forge enemy_spawn carries type/count/creature_type")
	_check(msg.contains("brute"), "compat: Forge enemy_spawn message names the type")
	fake.free()
	# WaveManager queue composition.
	var wm: Node = _WaveManager.new()
	arena.add_child(wm)
	var q1: Array = wm.call("_build_queue", 1)
	var all_grunt := true
	for entry in q1:
		if str((entry as Dictionary).get("type", "")) != "grunt":
			all_grunt = false
	_check(q1.size() == 5 and all_grunt, "compat: wave 1 queue is 5 grunts")
	var q8: Array = wm.call("_build_queue", 8)
	var warlords := 0
	for entry in q8:
		if str((entry as Dictionary).get("type", "")) == "warlord":
			warlords += 1
	_check(warlords == 1, "compat: wave 8 queue has exactly one warlord")
	var before: int = (wm.get("_spawn_queue") as Array).size()
	wm.call("queue_extra", "rusher", 2)
	_check((wm.get("_spawn_queue") as Array).size() == before + 2, "compat: queue_extra appends spawns")
	wm.call("apply_director_mod", {"kind": "spawn_extra", "type": "brute", "count": 1, "creature_type": "undead"})
	var last: Dictionary = (wm.get("_spawn_queue") as Array)[-1]
	_check(str(last.get("type")) == "brute" and str(last.get("creature_type")) == "undead",
		"compat: director spawn_extra carries the creature-type override")
	wm.free()
	# Plain take_damage signature + info string.
	var g := _make_enemy(_Grunt, arena, Vector3(0, 0.5, 0))
	var hp0: float = g.get("hp")
	g.call("take_damage", 10.0, Vector3(0, 0.5, 2), false)
	_check(is_equal_approx(float(g.get("hp")), hp0 - 10.0), "compat: take_damage(amount, pos, headshot) intact")
	_check(str(g.call("info_string")).contains("Humanoid"), "compat: info_string still reports the creature type")
	g.free()
