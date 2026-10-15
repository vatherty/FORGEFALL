# verify_v05_c1_enemies.gd — headless checks for C1 (enemy AI: distinct
# behaviors + fair difficulty ramp + spawn telegraphs).
# Usage: godot --headless --path <project> --script res://tools/verify_v05_c1_enemies.gd
# Checks:
#   1. Each enemy type instantiates with DISTINCT speed/range/accuracy/HP
#      values, in the expected ordering (rusher fastest, brute slowest/tankiest,
#      marksman most accurate/longest range, rusher shortest range).
#   2. No instant-kill damage: worst-case burst from any type < 100 (player HP).
#   3. Wave compositions change across waves (w1 all grunts; rushers w2+,
#      marksmen w3+, brute w5, second brute w10), and the alive cap is 10-12
#      and actually gates spawning.
#   4. Spawn telegraph exists: enemy is not dangerous (can_attack() == false,
#      still in SPAWN) during the telegraph window, glow visible, then it
#      expires and the enemy becomes active.
# NOTE: enemy scripts are loaded with load() in _initialize (NOT referenced by
# class_name at parse time) so they compile after the Sfx/Game autoloads are
# registered. Eager class_name refs break compilation under --script.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _phase_frame := 0
var _arena: Node3D = null
var _grunt: CharacterBody3D = null
var _rusher: CharacterBody3D = null
var _marksman: CharacterBody3D = null
var _brute: CharacterBody3D = null
var _grunt_script: GDScript = null
var _rusher_script: GDScript = null
var _marksman_script: GDScript = null
var _brute_script: GDScript = null
var _wm_script: GDScript = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	_grunt_script = load("res://scripts/enemies/grunt.gd")
	_rusher_script = load("res://scripts/enemies/rusher.gd")
	_marksman_script = load("res://scripts/enemies/marksman.gd")
	_brute_script = load("res://scripts/enemies/brute.gd")
	_wm_script = load("res://scripts/enemies/wave_manager.gd")
	_arena = Node3D.new()
	_arena.name = "VerifyArenaC1"
	root.add_child(_arena)
	_grunt = _grunt_script.new()
	_rusher = _rusher_script.new()
	_marksman = _marksman_script.new()
	_brute = _brute_script.new()
	_arena.add_child(_grunt)
	_arena.add_child(_rusher)
	_arena.add_child(_marksman)
	_arena.add_child(_brute)
	_phase = 1
	print("VERIFY_C1: arena built, checking distinct stats")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			_check_distinct_stats()
			_check_wave_composition()
			_phase = 2
			_phase_frame = _frames
			# Start the telegraph on the grunt.
			_grunt.activate(Vector3(0, 0.5, 0), 1, {})
			_check(_grunt.is_spawn_telegraphing(),
				"telegraph active immediately after activate()")
			_check(not _grunt.can_attack(),
				"enemy not dangerous during telegraph (can_attack false)")
			_check(_grunt.get("_telegraph_glow").visible,
				"telegraph glow visible during telegraph window")
		2:
			# ~10 frames in: still telegraphing, still frozen in SPAWN.
			if _frames - _phase_frame >= 10:
				_check(_grunt.is_spawn_telegraphing(),
					"telegraph still active ~10 frames in")
				_check(_grunt.get("state") == 0,
					"enemy still in SPAWN state during telegraph (no AI/firing)")
				_check(not _grunt.can_attack(),
					"enemy still not dangerous mid-telegraph")
				_phase = 3
				_phase_frame = _frames
		3:
			# Telegraph (0.5s) + SPAWN settle (0.6s) need ~1.1s of PHYSICS
			# time, but _process frames can run much faster than physics in
			# headless, so a fixed frame count is racy (flaked 2/3 runs).
			# Poll until the transition actually happens (or a generous
			# timeout) instead of assuming a frame count.
			if _grunt.get("state") != 0:
				_check(not _grunt.is_spawn_telegraphing(),
					"telegraph expired after window")
				_check(_grunt.can_attack(),
					"enemy dangerous again after telegraph expires")
				_check(not _grunt.get("_telegraph_glow").visible,
					"telegraph glow hidden after window")
				_check(true, "enemy left SPAWN after telegraph + settle")
				print("VERIFY_C1: %d failures" % _fails)
				quit(_fails)
				return true
			if _frames - _phase_frame >= 600:
				_check(not _grunt.is_spawn_telegraphing(),
					"telegraph expired after window")
				_check(_grunt.can_attack(),
					"enemy dangerous again after telegraph expires")
				_check(not _grunt.get("_telegraph_glow").visible,
					"telegraph glow hidden after window")
				_check(false,
					"enemy left SPAWN after telegraph + settle (timeout)")
				print("VERIFY_C1: %d failures" % _fails)
				quit(_fails)
				return true
		_:
			print("VERIFY_C1: bad phase, quitting")
			quit(1)
			return true
	if _frames > 3000:
		print("VERIFY_C1: TIMEOUT, %d failures" % _fails)
		quit(1)
		return true
	return false


func _check_distinct_stats() -> void:
	var g := _grunt
	var r := _rusher
	var m := _marksman
	var b := _brute
	_check(g.get("type_id") == "grunt" and r.get("type_id") == "rusher"
		and m.get("type_id") == "marksman" and b.get("type_id") == "brute",
		"all four types instantiate with distinct type_ids")
	# Speed ordering: rusher > grunt > marksman > brute.
	_check(r.get("base_speed") > g.get("base_speed")
		and g.get("base_speed") > m.get("base_speed")
		and m.get("base_speed") > b.get("base_speed"),
		"speed distinct + ordered: rusher %.1f > grunt %.1f > marksman %.1f > brute %.1f"
		% [r.get("base_speed"), g.get("base_speed"), m.get("base_speed"), b.get("base_speed")])
	# Preferred range: marksman >> grunt > brute > rusher.
	_check(m.get("preferred_range") > g.get("preferred_range")
		and g.get("preferred_range") > b.get("preferred_range")
		and b.get("preferred_range") > r.get("preferred_range"),
		"preferred range distinct + ordered: marksman %.0f > grunt %.0f > brute %.0f > rusher %.0f"
		% [m.get("preferred_range"), g.get("preferred_range"), b.get("preferred_range"), r.get("preferred_range")])
	# Accuracy: marksman > grunt > brute > rusher.
	_check(m.get("base_accuracy") > g.get("base_accuracy")
		and g.get("base_accuracy") > b.get("base_accuracy")
		and b.get("base_accuracy") > r.get("base_accuracy"),
		"accuracy distinct + ordered: marksman %.2f > grunt %.2f > brute %.2f > rusher %.2f"
		% [m.get("base_accuracy"), g.get("base_accuracy"), b.get("base_accuracy"), r.get("base_accuracy")])
	# HP: brute tank >> grunt > marksman > rusher glass cannon.
	_check(b.get("base_hp") > g.get("base_hp") and g.get("base_hp") > m.get("base_hp")
		and m.get("base_hp") > r.get("base_hp"),
		"HP distinct + ordered: brute %.0f > grunt %.0f > marksman %.0f > rusher %.0f"
		% [b.get("base_hp"), g.get("base_hp"), m.get("base_hp"), r.get("base_hp")])
	# No instant-kill: worst-case burst from any type < 100 (player HP).
	_check(_grunt_script.BURST_COUNT * g.get("base_damage") < 100.0,
		"grunt worst burst %d x %.0f = %.0f < 100"
		% [_grunt_script.BURST_COUNT, g.get("base_damage"), _grunt_script.BURST_COUNT * g.get("base_damage")])
	_check(_rusher_script.BLAST_PELLETS * r.get("base_damage") < 100.0,
		"rusher worst blast %d x %.0f = %.0f < 100"
		% [_rusher_script.BLAST_PELLETS, r.get("base_damage"), _rusher_script.BLAST_PELLETS * r.get("base_damage")])
	_check(m.get("base_damage") < 30.0,
		"marksman single shot %.0f < 30 (no one-tap)" % m.get("base_damage"))
	_check(_brute_script.BURST_COUNT * b.get("base_damage") < 100.0,
		"brute worst barrage %d x %.0f = %.0f < 100"
		% [_brute_script.BURST_COUNT, b.get("base_damage"), _brute_script.BURST_COUNT * b.get("base_damage")])
	# Fire-rate / telegraphs differ per type (readable behavior).
	_check(_marksman_script.AIM_TELEGRAPH > _grunt_script.AIM_TELEGRAPH,
		"marksman aim telegraph (%.1fs) longer than grunt (%.1fs)"
		% [_marksman_script.AIM_TELEGRAPH, _grunt_script.AIM_TELEGRAPH])
	_check(_marksman_script.SHOT_COOLDOWN_MIN > _rusher_script.BLAST_COOLDOWN,
		"marksman cooldown min (%.1fs) slower than rusher blast cycle (%.1fs)"
		% [_marksman_script.SHOT_COOLDOWN_MIN, _rusher_script.BLAST_COOLDOWN])
	_check(b.get("base_speed") < 3.0, "brute slow enough to kite (speed %.1f)" % b.get("base_speed"))


func _count(q: Array, t: String) -> int:
	var n := 0
	for x in q:
		if x == t:
			n += 1
	return n


func _check_wave_composition() -> void:
	var wm: Node = _wm_script.new()
	_arena.add_child(wm)
	var cap: int = _wm_script.MAX_CONCURRENT
	_check(cap >= 10 and cap <= 12,
		"alive cap MAX_CONCURRENT = %d (within 10-12)" % cap)
	var q1: Array = wm._build_queue(1)
	_check(q1.size() == 5 and _count(q1, "grunt") == 5,
		"wave 1 = 5 grunts only (got %d)" % q1.size())
	var q2: Array = wm._build_queue(2)
	_check(_count(q2, "rusher") >= 1 and _count(q2, "marksman") == 0
		and _count(q2, "brute") == 0,
		"wave 2 adds rushers, no marksmen/brutes (rushers=%d)" % _count(q2, "rusher"))
	var q3: Array = wm._build_queue(3)
	_check(_count(q3, "marksman") >= 1 and _count(q3, "brute") == 0,
		"wave 3 adds marksmen, no brutes (marksmen=%d)" % _count(q3, "marksman"))
	var q5: Array = wm._build_queue(5)
	_check(_count(q5, "brute") == 1,
		"wave 5 has exactly 1 brute (brutes=%d)" % _count(q5, "brute"))
	var q10: Array = wm._build_queue(10)
	_check(_count(q10, "brute") == 2,
		"wave 10 has 2 brutes (brutes=%d)" % _count(q10, "brute"))
	_check(q10.size() > q5.size() and q5.size() > q1.size(),
		"total wave size grows gently: w1=%d w5=%d w10=%d"
		% [q1.size(), q5.size(), q10.size()])
	# Alive cap actually gates spawning.
	wm.set("running", true)
	wm.set("in_build_phase", false)
	var qcap: Array[String] = []
	for i in 15:
		qcap.append("grunt")
	wm.set("_spawn_queue", qcap)
	wm.set("alive_count", cap)
	wm.set("_spawn_t", 0.0)
	wm._process(0.5)
	_check(wm.get("alive_count") == cap and wm.get("_spawn_queue").size() == 15,
		"no spawn while alive_count == cap (queue stays 15)")
	wm.set("running", false)
	wm.get("_spawn_queue").clear()
