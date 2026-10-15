# tools/verify_g1_gunfeel.gd — Goal 1 FEEL (Worker B: gunfeel) checks.
# Usage: godot --headless --path <project> --script res://tools/verify_g1_gunfeel.gd
# Asserts:
#   1. Per-weapon recoil recovery + muzzle flash: distinct, ordered
#      (smg < p9 < ar7 < lmg < sg12 < lr8), sniper flash brightest/longest.
#   2. Recoil curve: kick applies instantly (debt + VM kick), recovery
#      HOLDS during the settle delay, then decays exponentially to ~0;
#      VM kick springs back to 0.
#   3. Hitmarker: settled scale at call time (1.0/1.25/1.45), punch
#      overshoot on the next frame, settles back to base after punch time.
#   4. Enemy hit reactions scale with damage: sniper flinch > AR flinch >
#      pellet flinch; headshot > body; rusher shove > grunt shove for the
#      same hit; shotgun burst diminish; brute stays immune.
#   5. Balance untouched: rpm/damage spot-check (A3 surface).
# NOTE: game scripts loaded dynamically via load() (see verify_fixes.gd).
extends SceneTree

var _failures: Array = []
var _checks := 0
var _frames := 0
var _ran := false


class _FakePlayer extends Node3D:
	var look := Vector2.ZERO

	func add_look(v: Vector2) -> void:
		look += v


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: ", label)
	else:
		_failures.append(label)
		printerr("FAIL: ", label)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3 or _ran:
		return false
	_ran = true
	_run()
	print("G1 GUNFEEL VERIFY: %d checks, %d failures" % [_checks, _failures.size()])
	quit(1 if not _failures.is_empty() else 0)
	return true


func _run() -> void:
	var ArsenalScript = load("res://scripts/weapons/arsenal.gd")
	var EnemyBaseScript = load("res://scripts/enemies/enemy_base.gd")
	var GruntScript = load("res://scripts/enemies/grunt.gd")
	var RusherScript = load("res://scripts/enemies/rusher.gd")
	var BruteScript = load("res://scripts/enemies/brute.gd")
	var HudScript = load("res://scripts/ui/hud.gd")

	# --- 5. Balance untouched ---
	var expect_stats := {
		"ar7": [700.0, 25.0], "lr8": [40.0, 120.0], "sg12": [65.0, 12.0],
		"smg9": [850.0, 18.0], "p9": [420.0, 22.0],
	}
	for wid in expect_stats:
		var st: Dictionary = ArsenalScript.call("get_stats", wid)
		_check(is_equal_approx(float(st["rpm"]), expect_stats[wid][0])
			and is_equal_approx(float(st["damage"]), expect_stats[wid][1]),
			"stats untouched %s rpm=%s dmg=%s" % [wid, st["rpm"], st["damage"]])

	# --- 1. Per-weapon recoil recovery + flash ---
	var rec: Dictionary = {}
	var flash_e: Dictionary = {}
	var flash_t: Dictionary = {}
	for wid in ["ar7", "lr8", "sg12", "smg9", "lmg", "p9"]:
		var st: Dictionary = ArsenalScript.call("get_stats", wid)
		rec[wid] = float(st.get("recoil_recover", -1.0))
		flash_e[wid] = float(st.get("muzzle_flash_energy", -1.0))
		flash_t[wid] = float(st.get("muzzle_flash_time", -1.0))
	_check(rec["smg9"] < rec["p9"] and rec["p9"] < rec["ar7"]
		and rec["ar7"] < rec["lmg"] and rec["lmg"] < rec["sg12"]
		and rec["sg12"] < rec["lr8"],
		"recoil_recover ordered smg %.2f < p9 %.2f < ar7 %.2f < lmg %.2f < sg12 %.2f < lr8 %.2f"
		% [rec["smg9"], rec["p9"], rec["ar7"], rec["lmg"], rec["sg12"], rec["lr8"]])
	_check(flash_e["lr8"] > flash_e["sg12"] and flash_e["sg12"] > flash_e["ar7"]
		and flash_e["ar7"] > flash_e["smg9"],
		"flash energy ordered lr8 %.1f > sg12 %.1f > ar7 %.1f > smg9 %.1f"
		% [flash_e["lr8"], flash_e["sg12"], flash_e["ar7"], flash_e["smg9"]])
	_check(flash_t["lr8"] > flash_t["sg12"] and flash_t["lr8"] <= 0.1,
		"flash time lr8 %.3f > sg12 %.3f, all expire within _tick_flash(0.1)"
		% [flash_t["lr8"], flash_t["sg12"]])

	# --- 2. Recoil curve (AR-7) ---
	var cam := Camera3D.new()
	root.add_child(cam)
	var fake := _FakePlayer.new()
	root.add_child(fake)
	var w: Node3D = ArsenalScript.call("make_weapon", "ar7")
	root.add_child(w)
	w.call("attach", fake, cam)
	_check(is_equal_approx(float(w.get("recoil_recover_time")), rec["ar7"]),
		"weapon recoil_recover_time %.2f == Arsenal" % float(w.get("recoil_recover_time")))
	_check(float(w.get("_kick_mag")) > 0.0, "AR-7 _kick_mag %.4f > 0" % float(w.get("_kick_mag")))
	w.call("_apply_recoil")
	var debt0: Vector2 = w.get("_recoil_debt")
	_check(debt0.length() > 0.0, "kick applies instantly: debt %s" % debt0)
	_check(float(w.get("_vm_kick_z")) > 0.0 and float(w.get("_vm_kick_pitch")) > 0.0,
		"VM kick punches: z %.4f pitch %.4f" % [float(w.get("_vm_kick_z")), float(w.get("_vm_kick_pitch"))])
	_check(float(w.get("_recoil_settle_t")) > 0.0, "settle delay armed")
	# Recovery HOLDS during settle.
	w.call("_recover_recoil", 0.016)
	_check((w.get("_recoil_debt") as Vector2).is_equal_approx(debt0),
		"debt unchanged during settle delay")
	# After settle, exponential decay to ~0 within ~1s of small steps.
	for i in 60:
		w.call("_recover_recoil", 0.016)
		w.call("_tick_vm_kick", 0.016)
	_check((w.get("_recoil_debt") as Vector2).length() < 0.001,
		"debt decays to ~0 (got %.5f)" % (w.get("_recoil_debt") as Vector2).length())
	_check(float(w.get("_vm_kick_z")) < 0.001 and float(w.get("_vm_kick_pitch")) < 0.001,
		"VM kick springs back to ~0")
	# Sniper recovers slower than SMG over the same window.
	var w_slow: Node3D = ArsenalScript.call("make_weapon", "lr8")
	root.add_child(w_slow)
	w_slow.call("attach", fake, cam)
	w_slow.call("_apply_recoil")
	var w_fast: Node3D = ArsenalScript.call("make_weapon", "smg9")
	root.add_child(w_fast)
	w_fast.call("attach", fake, cam)
	w_fast.call("_apply_recoil")
	for i in 12:
		w_slow.call("_recover_recoil", 0.016)
		w_fast.call("_recover_recoil", 0.016)
	var slow_left := (w_slow.get("_recoil_debt") as Vector2).length() / maxf((w_slow.get("recoil_pattern") as Array)[0].length(), 0.001)
	var fast_left := (w_fast.get("_recoil_debt") as Vector2).length() / maxf((w_fast.get("recoil_pattern") as Array)[0].length(), 0.001)
	_check(slow_left > fast_left,
		"sniper retains more debt than SMG after 12 ticks (%.2f > %.2f)" % [slow_left, fast_left])
	# Muzzle flash per-weapon energy/duration.
	var w_lr8: Node3D = ArsenalScript.call("make_weapon", "lr8")
	root.add_child(w_lr8)
	w_lr8.call("attach", fake, cam)
	w_lr8.call("on_equip")
	w_lr8.call("_show_muzzle_flash")
	_check(is_equal_approx(float((w_lr8.get("_flash_light") as OmniLight3D).light_energy), flash_e["lr8"]),
		"lr8 flash energy %.1f" % float((w_lr8.get("_flash_light") as OmniLight3D).light_energy))
	_check(is_equal_approx(float(w_lr8.get("_flash_t")), flash_t["lr8"]),
		"lr8 flash duration %.3f" % float(w_lr8.get("_flash_t")))
	w_lr8.call("_tick_flash", 0.1)
	_check(not (w_lr8.get("_flash_light") as OmniLight3D).visible,
		"lr8 flash expires after 0.1s tick")
	w.queue_free()
	w_slow.queue_free()
	w_fast.queue_free()
	w_lr8.queue_free()

	# --- 3. Hitmarker punch ---
	var hud: CanvasLayer = HudScript.new()
	root.add_child(hud)
	var hroot: Control = hud.get_node_or_null("Hitmarker") as Control
	_check(hroot != null, "HUD hitmarker node exists")
	if hroot != null:
		hud.call("show_hitmarker", false, false)
		_check(is_equal_approx(hroot.scale.x, 1.0), "hit settled scale 1.0 at call time")
		hud.call("show_hitmarker", false, true)
		_check(hroot.scale.x > 1.2 and hroot.scale.x < 1.3, "headshot settled scale 1.25x")
		hud.call("show_hitmarker", true, false)
		_check(hroot.scale.x > 1.4 and hroot.scale.x < 1.5, "kill settled scale 1.45x")
		# Next frame: punch overshoot above the settled scale.
		hud.call("_process", 0.016)
		_check(hroot.scale.x > 1.45, "kill punch overshoots on next frame (%.2f)" % hroot.scale.x)
		# After punch time: back to the settled scale.
		for i in 8:
			hud.call("_process", 0.016)
		_check(is_equal_approx(hroot.scale.x, 1.45), "punch settles back to 1.45x")
		# Hitmarker still shows until HITMARKER_TIME expires.
		_check(hroot.visible, "hitmarker still visible during hold")
	hud.queue_free()

	# --- 4. Enemy hit reactions ---
	var arena := Node3D.new()
	root.add_child(arena)
	# Static scaling helpers (no instantiation needed).
	_check(EnemyBaseScript.call("flinch_time_for", 120.0, false) > EnemyBaseScript.call("flinch_time_for", 25.0, false)
		and EnemyBaseScript.call("flinch_time_for", 25.0, false) > EnemyBaseScript.call("flinch_time_for", 12.0, false),
		"flinch scales with damage: sniper > AR > pellet")
	_check(EnemyBaseScript.call("flinch_time_for", 25.0, true) > EnemyBaseScript.call("flinch_time_for", 25.0, false),
		"headshot flinch > body flinch")
	_check(EnemyBaseScript.call("knockback_for", 25.0, 60.0, false, 0.0) > EnemyBaseScript.call("knockback_for", 25.0, 100.0, false, 0.0),
		"rusher (60hp) shoved further than grunt (100hp) for same hit")
	_check(EnemyBaseScript.call("knockback_for", 25.0, 100.0, false, 0.0) > EnemyBaseScript.call("knockback_for", 25.0, 100.0, false, 3.0),
		"burst diminish: fresh hit shoves harder than 4th-in-window hit")
	# Live grunt: AR hit flinches + knocks back; sniper hit flinches longer.
	var grunt: CharacterBody3D = GruntScript.new()
	arena.add_child(grunt)
	grunt.call("activate", Vector3(0, 0.5, 0), 1, {})
	var hp_before: float = grunt.get("hp")
	grunt.call("take_damage", 25.0, Vector3(0, 0.5, 2.0), false)
	_check(bool(grunt.call("is_flinching")), "grunt flinches on AR hit")
	_check(is_equal_approx(float(grunt.get("last_hit_flinch")), float(EnemyBaseScript.call("flinch_time_for", 25.0, false))),
		"grunt AR flinch %.3f == scaled value" % float(grunt.get("last_hit_flinch")))
	_check((grunt.get("velocity") as Vector3).length() > 0.0, "grunt knocked back")
	_check(is_equal_approx(float(grunt.get("hp")), hp_before - 25.0), "grunt HP still reduced by raw damage (no balance change)")
	grunt.call("take_damage", 60.0, Vector3(0, 0.5, 2.0), false)
	_check(float(grunt.get("last_hit_flinch")) > float(EnemyBaseScript.call("flinch_time_for", 25.0, false)),
		"heavy hit flinches longer than AR hit")
	# Flinch refreshes, never stacks: small hit after big hit keeps the big duration.
	var big: float = float(grunt.get("last_hit_flinch"))
	grunt.call("take_damage", 10.0, Vector3(0, 0.5, 2.0), false)
	_check(float(grunt.get("last_hit_flinch")) < big and bool(grunt.call("is_flinching")),
		"small follow-up hit does not extend flinch past the big hit")
	# Brute: immune to flinch/knockback (design preserved).
	var brute: CharacterBody3D = BruteScript.new()
	arena.add_child(brute)
	brute.call("activate", Vector3(5, 0.5, 0), 5, {})
	brute.call("take_damage", 120.0, Vector3(5, 0.5, 2.0), true)
	_check(not bool(brute.call("is_flinching")), "brute stays flinch-immune on 120 headshot")
	_check((brute.get("velocity") as Vector3).length() < 0.001, "brute takes no knockback")
	arena.queue_free()
