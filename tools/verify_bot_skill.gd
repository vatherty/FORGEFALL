# verify_bot_skill.gd — headless checks for FORGEFALL BB-8 (bot skill).
# Usage: godot --headless --path <project> --script res://tools/verify_bot_skill.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Colin's complaint (BB-8): bots aimed at the target's exact position
# with distance-only spread, so a target crossing at grapple-fling
# speed was as hittable as a statue. This verifier proves the shape of
# the fix with a deterministic hit-rate simulation on the REAL game
# loop (real physics frames, real BotFighter._physics_process, real
# raycasts — nothing re-implemented):
#   - 4 lanes, one bot per tier (rookie/regular/hardened/elite),
#     jitter OFF, fixed RNG seeds. Bots are frozen in place (speed 0);
#     only their aim/fire brain runs.
#   - Each bot faces a capsule target 25 m away crossing laterally at
#     [0, 6, 11, 25, 60] m/s (ping-pong), N=90 shots per cell.
#   - Assertions: hit rate falls as target speed rises; at 60 m/s
#     every tier is ~unhittable (<= 16%); at 0-6 m/s Regular and above
#     are dangerous (>= 40%); tiers are ordered; and no tier fires
#     before its reaction delay after acquiring a target.
# NOTE: Engine.time_scale must NOT be used here — it scales the
# physics delta, which makes move_and_slide targets travel faster in
# metres-per-sim-second than their scripted velocity (the bot's own
# velocity estimate divides by the same scaled delta and cannot see
# the difference). The sim therefore runs at plain 60 Hz; expect a
# few minutes of wall time. All measurement is in SIM time (physics
# frame counts), so results are deterministic.
extends SceneTree


class FakeTDM extends Node:
	var player_team := 0
	var bots: Array = []

	func note_player_damage(_b: Node) -> void:
		pass


class TargetDouble extends CharacterBody3D:
	var hits := 0
	var vel := Vector3.ZERO
	var z_half := 18.0

	func _physics_process(_delta: float) -> void:
		velocity = vel
		move_and_slide()
		if global_position.z > z_half:
			global_position.z = z_half
			vel.z = -absf(vel.z)
		elif global_position.z < -z_half:
			global_position.z = -z_half
			vel.z = absf(vel.z)

	func take_damage(_amount: float, _pos: Vector3, _hs: bool, _attacker: Node = null) -> void:
		hits += 1


const RANGE := 25.0
const LANE_DX := 200.0
## Shots per matrix cell: more for the low-speed rounds, where the
## >= 40% danger assertions live, fewer for the high-speed rounds.
const SHOTS_LOW := 90
const SHOTS_HIGH := 60
const SPEEDS: Array[float] = [0.0, 6.0, 11.0, 25.0, 60.0]
const TIERS: Array[String] = ["rookie", "regular", "hardened", "elite"]

var _fails := 0
var _checks := 0
var _done := false

var _fighter_script: GDScript = null
var _tdm_script: GDScript = null
var _arena: Node3D = null
var _fake_tdm: FakeTDM = null

var _frame := 0               # physics frames elapsed (sim clock)
var _phase := ""
var _phase_frame := 0

# Reaction phase state.
var _react_bots: Array = []
var _react_targets: Array = []
var _react_first: Array = []  # sim seconds to first shot, -1 = pending

# Matrix phase state.
var _lane_bots: Array = []
var _lane_targets: Array = []
var _round := -1
var _round_state := ""        # "settle" | "count"
var _base_shots: Array = []
var _base_hits: Array = []
var _rates := {}              # tier -> Array[float]


func _process(_delta: float) -> bool:
	if _done:
		return true
	match _phase:
		"":
			_begin()
		"reaction":
			_poll_reaction()
		"matrix":
			_poll_matrix()
	return false


func _on_physics_frame() -> void:
	_frame += 1


func _sim_in_phase() -> float:
	return float(_frame - _phase_frame) / 60.0


func _set_phase(p: String) -> void:
	_phase = p
	_phase_frame = _frame


func _check(name: String, cond: bool) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % name)
	else:
		_fails += 1
		printerr("FAIL: %s" % name)


func _begin() -> void:
	seed(20261126)
	physics_frame.connect(_on_physics_frame)
	_fighter_script = load("res://scripts/modes/bot_fighter.gd") as GDScript
	_tdm_script = load("res://scripts/modes/bot_tdm.gd") as GDScript
	_arena = Node3D.new()
	_arena.name = "BotSkillArena"
	root.add_child(_arena)
	_fake_tdm = FakeTDM.new()
	_arena.add_child(_fake_tdm)
	# Floor so the (real) bot bodies stand instead of falling.
	var floor_body := StaticBody3D.new()
	var fshape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(2600, 1, 400)
	fshape.shape = fbox
	floor_body.add_child(fshape)
	floor_body.position = Vector3(900, -0.5, 0)
	_arena.add_child(floor_body)
	_check_units()
	_build_reaction_lanes()
	_set_phase("reaction")


func _make_target(pos: Vector3) -> TargetDouble:
	var d := TargetDouble.new()
	d.add_to_group("player")
	d.collision_mask = 0  # scripted motion: never blocked, never falls
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.34
	cap.height = 1.7
	shape.shape = cap
	shape.position = Vector3(0, 0.85, 0)
	d.add_child(shape)
	d.position = pos
	_arena.add_child(d)
	return d


func _make_bot(tier: String, pos: Vector3, seed_value: int) -> Node:
	var bot: Node = _fighter_script.new()
	bot.call("setup", "SIM_" + tier.to_upper(), 1, _fake_tdm)
	bot.call("apply_skill_tier", tier, 0.0, seed_value)
	_arena.add_child(bot)
	bot.call("activate", pos, 1, {})
	bot.set("_telegraph_t", 0.0)
	bot.set("speed", 0.0)  # frozen in place: aim brain only
	return bot


# --- unit-level tier checks -------------------------------------------------

func _check_units() -> void:
	var probe: Node = _fighter_script.new()
	_arena.add_child(probe)
	_check("fresh BotFighter has the skill model OFF (legacy aim)",
		not bool(probe.get("skill_enabled")))
	var ids: Array = probe.call("skill_tier_ids")
	_check("at least 4 difficulty tiers", ids.size() >= 4)
	for t in TIERS:
		_check("tier exists: %s" % t, ids.has(t))
	probe.call("apply_skill_tier", "elite", 0.0, 7)
	_check("apply elite: tier id sticks", str(probe.get("skill_tier")) == "elite")
	_check("apply elite: reaction is the table value (0.16)",
		is_equal_approx(float(probe.get("p_reaction")), 0.16))
	_check("apply elite: track rate is the table value (120)",
		is_equal_approx(float(probe.get("p_track_rate")), 120.0))
	probe.call("apply_skill_tier", "bogus", 0.0, 7)
	_check("unknown tier falls back to regular",
		str(probe.get("skill_tier")) == "regular")
	var a: Node = _fighter_script.new()
	var b: Node = _fighter_script.new()
	_arena.add_child(a)
	_arena.add_child(b)
	a.call("apply_skill_tier", "regular", 0.2, 99)
	b.call("apply_skill_tier", "regular", 0.2, 123456)
	var ra := float(a.get("p_reaction"))
	_check("jittered reaction stays in the +/-20% band",
		ra >= 0.38 * 0.79 and ra <= 0.38 * 1.21)
	_check("per-bot jitter: two seeds differ",
		not is_equal_approx(ra, float(b.get("p_reaction")))
		or not is_equal_approx(float(a.get("p_track_rate")), float(b.get("p_track_rate"))))
	probe.queue_free()
	a.queue_free()
	b.queue_free()


# --- reaction time ----------------------------------------------------------

func _build_reaction_lanes() -> void:
	_react_bots.clear()
	_react_targets.clear()
	_react_first.clear()
	for i in TIERS.size():
		var x0 := 1000.0 + float(i) * LANE_DX
		_react_targets.append(_make_target(Vector3(x0 + RANGE, 0, -300.0)))
		_react_bots.append(_make_bot(TIERS[i], Vector3(x0, 0, 0), 3100 + i))
		_react_first.append(-1.0)
	# Targets teleport in NOW (phase clock starts): first shots are
	# measured against each tier's reaction delay.
	for i in TIERS.size():
		var x0 := 1000.0 + float(i) * LANE_DX
		(_react_targets[i] as Node3D).global_position = Vector3(x0 + RANGE, 0, 0)


func _poll_reaction() -> void:
	var pending := false
	for i in TIERS.size():
		if float(_react_first[i]) < 0.0:
			if int(_react_bots[i].get("shots_fired")) > 0:
				_react_first[i] = _sim_in_phase()
			else:
				pending = true
	if pending and _sim_in_phase() < 6.0:
		return
	for i in TIERS.size():
		var tier: String = TIERS[i]
		var t_first := float(_react_first[i])
		var reaction := float(_react_bots[i].get("p_reaction"))
		_check("%s: bot fires after acquiring (t=%.2fs)" % [tier, t_first],
			t_first > 0.0)
		_check("%s: no shot before reaction time (first %.2fs >= %.2fs x 0.80)" % [tier, t_first, reaction],
			t_first >= reaction * 0.80)
		_check("%s: first shot is not absurdly late (%.2fs <= %.2fs)" % [tier, t_first, reaction * 1.25 + 0.4],
			t_first <= reaction * 1.25 + 0.4)
		_react_bots[i].queue_free()
		_react_targets[i].queue_free()
	_build_matrix_lanes()
	_set_phase("matrix")


# --- hit-rate matrix --------------------------------------------------------

func _build_matrix_lanes() -> void:
	_lane_bots.clear()
	_lane_targets.clear()
	_rates.clear()
	for i in TIERS.size():
		var x0 := float(i) * LANE_DX
		_lane_targets.append(_make_target(Vector3(x0 + RANGE, 0, 0)))
		_lane_bots.append(_make_bot(TIERS[i], Vector3(x0, 0, 0), 4100 + i))
		_rates[TIERS[i]] = []
	_round = -1
	_start_next_round()


func _start_next_round() -> void:
	_round += 1
	if _round >= SPEEDS.size():
		_check_matrix()
		_check_tdm_wiring()
		_finish()
		return
	var speed: float = SPEEDS[_round]
	for i in TIERS.size():
		var d: TargetDouble = _lane_targets[i]
		d.vel = Vector3(0, 0, speed)
		d.global_position = Vector3(float(i) * LANE_DX + RANGE, 0, -15.0 if speed > 0.0 else 0.0)
	_round_state = "settle"
	_phase_frame = _frame


func _poll_matrix() -> void:
	if _round_state == "settle":
		if _sim_in_phase() >= 0.5:
			_base_shots.clear()
			_base_hits.clear()
			for i in TIERS.size():
				_base_shots.append(int(_lane_bots[i].get("shots_fired")))
				_base_hits.append((_lane_targets[i] as TargetDouble).hits)
			_round_state = "count"
			_phase_frame = _frame
		return
	# count
	var need := SHOTS_LOW if SPEEDS[_round] <= 11.0 else SHOTS_HIGH
	var done_all := true
	for i in TIERS.size():
		if int(_lane_bots[i].get("shots_fired")) - int(_base_shots[i]) < need:
			done_all = false
	if not done_all and _sim_in_phase() < 240.0:
		return
	var speed: float = SPEEDS[_round]
	for i in TIERS.size():
		var shots := int(_lane_bots[i].get("shots_fired")) - int(_base_shots[i])
		var hits := (_lane_targets[i] as TargetDouble).hits - int(_base_hits[i])
		var rate := float(hits) / float(maxi(shots, 1))
		(_rates[TIERS[i]] as Array).append(rate)
		print("MATRIX tier=%s speed=%.0f shots=%d hits=%d rate=%.3f" % [TIERS[i], speed, shots, hits, rate])
	_start_next_round()


func _check_matrix() -> void:
	for i in TIERS.size():
		var tier: String = TIERS[i]
		var r: Array = _rates[tier]
		_check("%s: matrix complete (5 speed cells)" % tier, r.size() == 5)
		if r.size() != 5:
			continue
		var falls := true
		for s in range(SPEEDS.size() - 1):
			if float(r[s + 1]) > float(r[s]) + 0.10:
				falls = false
		_check("%s: (a) hit rate falls as speed rises %s" % [tier, str(r)], falls)
		_check("%s: (a2) 60 m/s rate well below stationary (%.3f < %.3f)" % [tier, float(r[4]), float(r[0])],
			float(r[4]) < float(r[0]) - 0.10)
		_check("%s: (b) 60 m/s hit rate <= 16%% (got %.3f)" % [tier, float(r[4])],
			float(r[4]) <= 0.16)
		if tier != "rookie":
			_check("%s: (c) stationary hit rate >= 40%% (got %.3f)" % [tier, float(r[0])],
				float(r[0]) >= 0.40)
			_check("%s: (c) 6 m/s hit rate >= 40%% (got %.3f)" % [tier, float(r[1])],
				float(r[1]) >= 0.40)
	for s in SPEEDS.size():
		var tol := 0.12 if s <= 2 else 0.10
		var ordered := true
		for i in range(TIERS.size() - 1):
			var lo: float = (_rates[TIERS[i]] as Array)[s]
			var hi: float = (_rates[TIERS[i + 1]] as Array)[s]
			if hi < lo - tol:
				ordered = false
		_check("(d) tiers ordered at %.0f m/s (tol %.2f)" % [SPEEDS[s], tol], ordered)


# --- BotTDM wiring ------------------------------------------------------------

func _check_tdm_wiring() -> void:
	var prefs := root.get_node_or_null("/root/Preferences")
	if prefs != null:
		(prefs.get("values") as Dictionary)["bot_difficulty"] = "regular"
	var tdm: Node = _tdm_script.new()
	root.add_child(tdm)
	_check("BotTDM starts", bool(tdm.call("start", "grapple")))
	var state: Dictionary = tdm.call("get_state")
	_check("BotTDM default difficulty is regular",
		str(state.get("bot_difficulty", "")) == "regular")
	var all_skill := true
	var reactions := {}
	for b in tdm.get("bots"):
		if not bool(b.get("skill_enabled")) or str(b.get("skill_tier")) != "regular":
			all_skill = false
		reactions[float(b.get("p_reaction"))] = true
	_check("all 5 match bots run the skill model at regular", all_skill)
	_check("per-bot jitter: match bots are not clones (>1 distinct reaction)",
		reactions.size() > 1)
	tdm.call("stop")
	tdm.queue_free()

	var tdm2: Node = _tdm_script.new()
	root.add_child(tdm2)
	_check("set_bot_difficulty(elite) accepted", bool(tdm2.call("set_bot_difficulty", "elite")))
	_check("set_bot_difficulty(bogus) rejected", not bool(tdm2.call("set_bot_difficulty", "bogus")))
	tdm2.call("start", "grapple")
	var elite_ok := true
	for b in tdm2.get("bots"):
		if str(b.get("skill_tier")) != "elite":
			elite_ok = false
	_check("explicit setter wins: all bots elite", elite_ok)
	tdm2.call("stop")
	tdm2.queue_free()

	if prefs != null:
		(prefs.get("values") as Dictionary)["bot_difficulty"] = "hardened"
		var tdm3: Node = _tdm_script.new()
		root.add_child(tdm3)
		tdm3.call("start", "grapple")
		var st3: Dictionary = tdm3.call("get_state")
		_check("Preferences bot_difficulty=hardened reaches the match",
			str(st3.get("bot_difficulty", "")) == "hardened")
		tdm3.call("stop")
		tdm3.queue_free()
		(prefs.get("values") as Dictionary)["bot_difficulty"] = "regular"


func _finish() -> void:
	print("----")
	print("BOT SKILL: %d checks, %d failures" % [_checks, _fails])
	_done = true
	quit(0 if _fails == 0 else 1)
