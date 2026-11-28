# verify_feel_wave.gd — headless verification for the BB-4/BB-5 FEEL WAVE.
# Usage: godot --headless --path <project> --script res://tools/verify_feel_wave.gd
#
# STAGE A (weight data + speed, shipped 2026-11-28) checks:
#   1. Every Arsenal.WEAPONS entry carries a "weight" in [2.5, 11.0]; the
#      nine plan weapons match the PLAN.md §3.1 table exactly, in the
#      handling order the table anchors to.
#   2. WeaponBase.setup() derives weight_norm = (weight - 2.5) / 8 clamped;
#      a stats dict WITHOUT "weight" falls back to WEIGHT_DEFAULT (5.0),
#      so hand-built Forge/mod dicts stay valid.
#   3. weight_effects() returns the full multiplier set inside sane bounds
#      for every weapon; "hitbox_norm" honours RAPTOR_FULL_WEIGHT_EFFECTS
#      (plan §7.2 pending ruling) whichever way the flag is set.
#   4. The player push chain: set_weapon_weight(norm) derives the speed /
#      accel multipliers from player.gd's WEIGHT_*_PENALTY consts, is
#      idempotent (re-push REPLACES, never compounds), and the full chain
#      Arsenal -> WeaponBase -> player lands the plan's headline numbers
#      (LMG sprint 11.0 * 0.78 = 8.58; P9 effectively unpenalised).
# STAGE B (viewmodel spring core, shipped 2026-11-28) checks:
#   5. ADS spring unit contract: WeaponBase._spring_crit_step is monotonic
#      toward its target at dt = 1/60, 1/20 and 0.2 (never overshoots —
#      the PiP lens at blend > 0.5 and the scope hide at > 0.85 must not
#      flicker) and snaps to EXACTLY 0.0 / 1.0.
#   6. ADS blend through the real _process tick: monotonic in and out,
#      crosses the lens/scope thresholds on a BB-1-comparable clock, and
#      settles at exactly 1.0 / 0.0.
#   7. Spring stability: 10 s of _process at dt = 1/20 (worst frame
#      hitch) with seeded random target jumps (ADS / sprint / recoil /
#      lower+equip) — no NaN, no divergence, settles back onto HIP_POS.
#   8. Recoil kick spring: a shot punches the kick offsets positive, the
#      spring return OVERSHOOTS below zero (a spring, not the old
#      exponential decay), and both offsets settle < 0.001.
#   9. Sprint pose (plan §7.3 default = pose only): set_sprinting drives
#      the blend to exactly 1 and the spring pose to HIP + SPRINT_POSE_*;
#      releasing returns to HIP. Firing is NOT blocked at full sprint
#      blend (p9 trigger still spends a round).
# STAGE C (reload choreography + landing dip + the BB-4×BB-5 join,
# shipped 2026-11-28) checks:
#  10. Reload track coverage: for EVERY weapon, reload_track_pose at
#      every stage returns finite offsets, is continuous across stage
#      boundaries (end of stage N == start of stage N+1), starts and
#      ends at zero, and actually moves the gun somewhere mid-track.
#  11. Live reload through _process (ar7): the viewmodel visibly leaves
#      the hip pose and returns, the mag refills at exactly the
#      MAG_IN -> CHAMBER boundary (never earlier), the seat jolt kicks
#      the pose spring on that boundary, and the total reload time is
#      the sum of reload_stages — choreography did NOT retime anything.
#  12. ADS yield: the same reload at full ADS deviates from the ADS pose
#      by a fraction of the hip deviation (RELOAD_ADS_AMPLITUDE) but
#      still plays.
#  13. Landing dip: a hard fall dips the gun, a heavier weapon dips
#      deeper at the same fall speed (land_dip_mult), a deeper fall
#      dips deeper, a soft fall does not dip at all, and the dip spring
#      settles back to zero.
#  14. Weight -> spring core: at a fixed frame after equip the LMG's
#      pose spring still trails the hip pose further than the P9's
#      (spring_stiffness_mult consumed), and both settle exactly.
#  15. Weight -> sway/bob: at marching speed the LMG's measured sway
#      and bob amplitudes exceed the P9's (sway_mult / bob_mult).
#  16. Raptor: 600 frames of ticks with sprint toggles — the reload
#      stage machine never engages (its try_reload is drop-only), no
#      dip, transforms finite throughout.
# STAGE D (dynamic capsule hitbox + soldier polish, shipped 2026-11-28)
# checks:
#  17. Hitbox push chain: a script-only player stores/clamps hitbox_norm
#      (radius stays base with no capsule resolved); WeaponManager's
#      _push_weapon_weight drives BOTH setters on a recording double —
#      hitbox_norm comes from weight_effects() (the raptor ruling),
#      never from raw weight_norm.
#  18. Real player.tscn instances: a fresh instance reads the AR7
#      radius (0.43375) — the scene's own WeaponManager equips the
#      default loadout in _ready and pushes it, which is the full
#      in-scene chain working; hitbox_norm 0 restores exactly 0.4; LMG
#      norm grows the LIVE CollisionShape3D shape to 0.50; a second
#      instance is unaffected (the shape is duplicated per instance in
#      _ready); re-push replaces (P9 0.40625, AR7 0.43375); a fresh
#      third instance still reads the AR7 radius (scene sub-resource
#      unpolluted); speed mult + radius land together from the dual push.
#  19. Monte-Carlo (plan §5): the fire_hitscan jitter cone (uniform
#      ±4° yaw then pitch, 25 m, chest aim) against the capsule
#      cross-section — with IDENTICAL seeded ray sets per radius the
#      hit sets nest, so rates must be monotone in radius and the LMG
#      rate must beat the P9 rate by a real margin. Zero-spread control
#      hits every time at every radius.
#  20. Flinch spring (EnemyBase._update_anim_flinch): from 1.0 it snaps
#      fast, OVERSHOOTS below zero (~16%), settles to an exact 0 rest,
#      and stays finite + settled at dt = 1/20. Smoothed stride
#      (_update_anim_speed): one step toward 3 m/s lands mid-way (fade,
#      not pop), repeated steps snap exactly onto the target, and the
#      step back down fades the same way.
#  21. Soldier pose (VoxelSoldier.animate_full): aim_pitch pitches the
#      gun's world angle by the full elevation (arms follow 0.6, gun
#      pivot takes the rest) for targets above AND below; omitting the
#      param == passing 0. Hip sway: at move_k 0.5 the body roll
#      oscillates on the stride cycle; at rest it is exactly 0. A
#      NEGATIVE flinch (the spring overshoot) renders as a forward
#      settle, and flinch clamps at -0.25.
# GATE FIX (2026-11-28, Publish-Ready Gate Checker 2 blocker) checks:
#  22. Substep plan (WeaponBase._spring_substeps): normal deltas keep
#      the pre-fix step counts exactly (1/60 -> 1 step, h == delta);
#      large deltas derive steps from the max-h target (h never
#      exceeds VM_SPRING_MAX_DT) with the integrated spring time
#      clamped to VM_SPRING_MAX_FRAME.
#  23. Recoil kick at dt = 3.0 (the Breaker repro: was 4.46e10 after a
#      single _process(2.0), viewmodel displaced ~4.45 s): through the
#      real _process AND the direct _tick_vm_kick channel (incl. an
#      absurd dt = 3600) the kick stays finite + sanely bounded and
#      settles < 0.001 within 0.5 s of normal frames.
#  24. Landing dip at dt = 3.0 with live dip state (the Breaker's probe
#      carried none; the channel diverged too, to ~9.9e11): finite,
#      never grows, settles < 0.001.
#  25. Pose spring at dt = 3.0 from the raised offset: finite and
#      settled exactly onto HIP_POS.
#  26. Weight rider: explicit `"weight": null` and a non-numeric weight
#      in a hand-authored dict fall back to WEIGHT_DEFAULT and setup()
#      COMPLETES (viewmodel built); an int weight is honoured.
# Stage E extends this file further — see
# ~/workspace/forgefall-feel-wave/PLAN.md §5.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# NOTE: game scripts loaded dynamically via load() (see verify_fixes.gd) —
# compile-time references to the game classes would drag the autoload
# dependency chain into this script's own compile and fail headless.
extends SceneTree

var _checked := 0
var _failed := 0
var _arsenal: GDScript = null
var _weapon_base: GDScript = null
var _stage_b_pending := false  # Stage B scene checks run on the first _process frame
var _fire_w: Node3D = null     # Stage B: p9 left armed for the _process fire check
var _fire_stage: Node3D = null
var _fire_mag_before := 0

# PLAN.md §3.1 table (weapon id -> [weight, weight_norm]).
const PLAN_WEIGHTS := {
	"p9": [3.0, 0.0625],
	"smg9": [3.8, 0.1625],
	"ar7": [5.2, 0.3375],
	"br3": [5.6, 0.3875],
	"raptor": [5.0, 0.3125],
	"sg12": [6.4, 0.4875],
	"hv44": [6.8, 0.5375],
	"lr8": [8.6, 0.7625],
	"lmg": [10.5, 1.0],
}
const EPS := 0.001


func _check(cond: bool, label: String) -> void:
	_checked += 1
	if not cond:
		_failed += 1
		printerr("VERIFY_FEEL_WAVE FAIL: ", label)


func _approx(a: float, b: float) -> bool:
	return absf(a - b) < EPS


func _initialize() -> void:
	_arsenal = load("res://scripts/weapons/arsenal.gd")
	_weapon_base = load("res://scripts/weapons/weapon_base.gd")
	_check(_arsenal != null and _weapon_base != null, "arsenal + weapon_base scripts load")
	_check_weight_table()
	_check_setup_and_effects()
	_check_player_push()
	_check_ads_spring_unit()
	# Stage B scene checks run on the first _process frame, not here:
	# nodes added during _initialize are not inside the tree yet, and
	# the weapon tick's lens path reads global transforms (in-game the
	# weapon is always in-tree; the harness must be too, or the log
	# fills with is_inside_tree noise that would mask real errors).
	_stage_b_pending = true


func _process(_delta: float) -> bool:
	if _stage_b_pending:
		_stage_b_pending = false
		_check_stage_b_scene()
		_check_stage_c_scene()
		_check_stage_d_pure()
		_check_stage_d_scene()
		_check_gate_fix()
		# The sprint fire check rides along here: shell eject reads
		# global transforms and the Sfx autoload finishes _ready only
		# once the tree iterates, so the p9 _check_stage_b_scene left
		# armed gets its trigger pulled on this live frame.
		if _fire_w != null:
			var w3 := _fire_w
			_fire_w = null
			w3.call("trigger_pressed")
			_check(int(w3.get("mag")) == _fire_mag_before - 1,
					"sprint pose: firing NOT blocked while sprinting (mag %d -> %d)" % [_fire_mag_before, int(w3.get("mag"))])
			_fire_stage.queue_free()
		_finish()
	return true


func _finish() -> void:
	print("VERIFY_FEEL_WAVE: checked %d, %d failed" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)


func _weapons() -> Dictionary:
	return _arsenal.get("WEAPONS")


func _check_weight_table() -> void:
	var weapons := _weapons()
	for id in weapons:
		var stats: Dictionary = weapons[id]
		_check(stats.has("weight"), "%s: WEAPONS entry has a weight stat" % id)
		if stats.has("weight"):
			var w := float(stats["weight"])
			_check(w >= 2.5 and w <= 11.0, "%s: weight %.2f in [2.5, 11.0]" % [id, w])
	for id in PLAN_WEIGHTS:
		var stats: Dictionary = weapons.get(id, {})
		_check(_approx(float(stats.get("weight", -1.0)), PLAN_WEIGHTS[id][0]),
				"%s: weight == plan table %.1f" % [id, PLAN_WEIGHTS[id][0]])
	# Handling order (plan §1.5/§3.1): weight must never contradict the
	# raise/recover order the player already feels.
	var order := ["p9", "smg9", "ar7", "br3", "sg12", "hv44", "lr8", "lmg"]
	for i in range(order.size() - 1):
		var a := float((weapons[order[i]] as Dictionary)["weight"])
		var b := float((weapons[order[i + 1]] as Dictionary)["weight"])
		_check(a < b, "weight order: %s (%.1f) < %s (%.1f)" % [order[i], a, order[i + 1], b])


func _check_setup_and_effects() -> void:
	for id in PLAN_WEIGHTS:
		var w: Node3D = _arsenal.call("make_weapon", id)
		_check(w != null, "%s: make_weapon returns a weapon" % id)
		if w == null:
			continue
		_check(_approx(float(w.get("weight")), PLAN_WEIGHTS[id][0]), "%s: setup() weight" % id)
		_check(_approx(float(w.get("weight_norm")), PLAN_WEIGHTS[id][1]), "%s: setup() weight_norm" % id)
		var fx: Dictionary = w.call("weight_effects")
		for key in ["weight", "weight_norm", "hitbox_norm", "spring_stiffness_mult",
				"sway_mult", "bob_mult", "bob_rate_mult", "land_dip_mult"]:
			_check(fx.has(key), "%s: weight_effects has %s" % [id, key])
		_check(float(fx["spring_stiffness_mult"]) >= 0.55 and float(fx["spring_stiffness_mult"]) <= 1.0,
				"%s: spring_stiffness_mult in [0.55, 1.0]" % id)
		_check(float(fx["sway_mult"]) >= 1.0 and float(fx["sway_mult"]) <= 1.6,
				"%s: sway_mult in [1.0, 1.6]" % id)
		_check(float(fx["bob_mult"]) >= 1.0 and float(fx["bob_mult"]) <= 1.5,
				"%s: bob_mult in [1.0, 1.5]" % id)
		_check(float(fx["bob_rate_mult"]) >= 0.75 and float(fx["bob_rate_mult"]) <= 1.0,
				"%s: bob_rate_mult in [0.75, 1.0]" % id)
		_check(float(fx["land_dip_mult"]) >= 0.7 and float(fx["land_dip_mult"]) <= 1.5,
				"%s: land_dip_mult in [0.7, 1.5]" % id)
		# §7.2: hitbox_norm follows RAPTOR_FULL_WEIGHT_EFFECTS for the
		# raptor and equals weight_norm for everything else, either way.
		var expect_hit := float(w.get("weight_norm"))
		if id == "raptor" and not bool(_weapon_base.get("RAPTOR_FULL_WEIGHT_EFFECTS")):
			expect_hit = 0.0
		_check(_approx(float(fx["hitbox_norm"]), expect_hit),
				"%s: hitbox_norm honours the raptor ruling flag" % id)
		w.free()
	# Stat-less dict (Forge/mod custom): weight falls back to the default.
	var bare := (_weapons()["ar7"] as Dictionary).duplicate(true)
	bare.erase("weight")
	var bw: Node3D = _weapon_base.new()
	bw.call("setup", bare)
	_check(_approx(float(bw.get("weight")), float(_weapon_base.get("WEIGHT_DEFAULT"))),
			"stat-less dict: weight == WEIGHT_DEFAULT")
	_check(_approx(float(bw.get("weight_norm")), 0.3125), "stat-less dict: weight_norm == 0.3125")
	bw.free()


func _check_player_push() -> void:
	var player: CharacterBody3D = load("res://scripts/player/player.gd").new()
	_check(_approx(float(player.get("_weapon_speed_mult")), 1.0), "player default: speed mult neutral 1.0")
	_check(_approx(float(player.get("_weapon_accel_mult")), 1.0), "player default: accel mult neutral 1.0")
	# LMG (norm 1.0): the plan's headline numbers.
	player.call("set_weapon_weight", 1.0)
	_check(_approx(float(player.get("_weapon_speed_mult")), 0.78), "LMG: speed mult == 0.78")
	_check(_approx(float(player.get("_weapon_accel_mult")), 0.65), "LMG: accel mult == 0.65")
	_check(_approx(11.0 * float(player.get("_weapon_speed_mult")), 8.58), "LMG: sprint target == 8.58 m/s")
	# Re-push REPLACES (equip lmg -> p9 -> lmg leaves no residue).
	player.call("set_weapon_weight", 0.0625)
	_check(_approx(float(player.get("_weapon_speed_mult")), 1.0 - 0.22 * 0.0625), "P9 after LMG: speed mult replaced")
	player.call("set_weapon_weight", 1.0)
	player.call("set_weapon_weight", 1.0)
	_check(_approx(float(player.get("_weapon_speed_mult")), 0.78), "LMG twice: no compounding")
	# Full chain: Arsenal -> WeaponBase -> player.
	var lmg: Node3D = _arsenal.call("make_weapon", "lmg")
	player.call("set_weapon_weight", float(lmg.get("weight_norm")))
	_check(_approx(float(player.get("_weapon_speed_mult")), 0.78), "full chain LMG: speed mult == 0.78")
	lmg.free()
	player.free()


# --- Stage B -------------------------------------------------------------

class _FakePlayer:
	extends Node3D
	var velocity := Vector3.ZERO
	var _sprinting := false
	func add_look(_r: Vector2) -> void:
		pass


## Stage D recording double: captures WeaponManager's dual push.
class _RecordingPlayer:
	extends Node
	var got_weight := -1.0
	var got_hitbox := -1.0
	func set_weapon_weight(n: float) -> void:
		got_weight = n
	func set_weapon_hitbox(n: float) -> void:
		got_hitbox = n


## Stage C landing double: a player the weapon's dip tracker can poll
## for floor state (the plain _FakePlayer has no is_on_floor, which the
## tracker reads as permanently grounded — Stage B behaviour).
class _FakeLandingPlayer:
	extends Node3D
	var velocity := Vector3.ZERO
	var _sprinting := false
	var on_floor := true
	func add_look(_r: Vector2) -> void:
		pass
	func is_on_floor() -> bool:
		return on_floor


func _finite3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


## Check 5: the closed-form critically-damped step is monotonic and
## snapping at every step size the game can hand it.
func _check_ads_spring_unit() -> void:
	var omega := 4.5 / float(_weapon_base.get("ADS_BLEND_TIME"))
	for h in [1.0 / 60.0, 1.0 / 20.0, 0.2]:
		var x := 0.0
		var v := 0.0
		var prev := 0.0
		var mono := true
		var bounded := true
		for i in 200:
			var s: Vector2 = _weapon_base.call("_spring_crit_step", x, v, 1.0, omega, h)
			x = s.x
			v = s.y
			if x < prev - 0.000001:
				mono = false
			if x > 1.0:
				bounded = false
			prev = x
		_check(mono, "ADS spring unit: monotonic in at dt %.3f" % h)
		_check(bounded, "ADS spring unit: never overshoots 1.0 at dt %.3f" % h)
		_check(x == 1.0 and v == 0.0, "ADS spring unit: snaps to exactly 1.0 at dt %.3f (got %f)" % [h, x])
		x = 1.0
		v = 0.0
		prev = 1.0
		mono = true
		bounded = true
		for i in 200:
			var s: Vector2 = _weapon_base.call("_spring_crit_step", x, v, 0.0, omega, h)
			x = s.x
			v = s.y
			if x > prev + 0.000001:
				mono = false
			if x < 0.0:
				bounded = false
			prev = x
		_check(mono, "ADS spring unit: monotonic out at dt %.3f" % h)
		_check(bounded, "ADS spring unit: never undershoots 0.0 at dt %.3f" % h)
		_check(x == 0.0 and v == 0.0, "ADS spring unit: snaps to exactly 0.0 at dt %.3f (got %f)" % [h, x])


func _make_stage_weapon(id: String, stage: Node3D, fake: _FakePlayer, cam: Camera3D) -> Node3D:
	var w: Node3D = _arsenal.call("make_weapon", id)
	stage.add_child(w)
	w.call("attach", fake, cam)
	w.call("on_equip")
	return w


## Checks 6–9 share one stage (fake player + camera in the tree).
func _check_stage_b_scene() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var fake := _FakePlayer.new()
	stage.add_child(fake)
	var cam := Camera3D.new()
	stage.add_child(cam)
	var hip_pos: Vector3 = _weapon_base.get("HIP_POS")
	var hip_rot: Vector3 = _weapon_base.get("HIP_ROT")

	# --- Check 6: ADS blend through the real tick. ---
	var w: Node3D = _make_stage_weapon("ar7", stage, fake, cam)
	w.call("set_ads", true)
	var prev := 0.0
	var mono := true
	var cross50 := -1
	var cross85 := -1
	for i in 90:
		w.call("_process", 1.0 / 60.0)
		var b := float(w.call("get_ads_blend"))
		if b < prev - 0.000001:
			mono = false
		if cross50 < 0 and b >= 0.5:
			cross50 = i
		if cross85 < 0 and b >= 0.85:
			cross85 = i
		prev = b
	_check(mono, "ADS blend (tick): monotonic in")
	_check(cross50 >= 0 and cross50 <= 10, "ADS blend (tick): lens threshold 0.5 crossed by step %d (<= 10)" % cross50)
	_check(cross85 >= 0 and cross85 <= 14, "ADS blend (tick): scope threshold 0.85 crossed by step %d (<= 14)" % cross85)
	_check(float(w.call("get_ads_blend")) == 1.0, "ADS blend (tick): settles at exactly 1.0")
	w.call("set_ads", false)
	prev = 1.0
	mono = true
	for i in 90:
		w.call("_process", 1.0 / 60.0)
		var b := float(w.call("get_ads_blend"))
		if b > prev + 0.000001:
			mono = false
		prev = b
	_check(mono, "ADS blend (tick): monotonic out")
	_check(float(w.call("get_ads_blend")) == 0.0, "ADS blend (tick): settles at exactly 0.0")

	# --- Check 7: spring stability, 10 s at dt = 1/20, random jumps. ---
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261128
	var stable := true
	for i in 200:
		if i % 7 == 0:
			w.call("set_ads", rng.randi_range(0, 1) == 1)
		if i % 11 == 0:
			var spr := rng.randi_range(0, 1) == 1
			fake._sprinting = spr
			w.call("set_sprinting", spr)
		if i % 13 == 0:
			w.call("_apply_recoil")
		if i == 60 or i == 130:
			w.call("begin_lower")
		if i == 63 or i == 133:
			w.call("on_unequip")
			w.call("on_equip")
		w.call("_process", 1.0 / 20.0)
		if not _finite3(w.get("_vm_pos")) or not _finite3(w.get("_vm_rot")) \
				or not _finite3(w.get("_vm_pos_vel")) or not _finite3(w.get("_vm_rot_vel")) \
				or not is_finite(float(w.call("get_ads_blend"))) \
				or not is_finite(float(w.call("get_sprint_blend"))):
			stable = false
		if (w.get("_vm_pos") as Vector3).length() > 2.0:
			stable = false
		var b2 := float(w.call("get_ads_blend"))
		if b2 < 0.0 or b2 > 1.0:
			stable = false
	_check(stable, "spring stability: 200 steps at dt 1/20 with random jumps — finite, bounded, blend in [0,1]")
	w.call("set_ads", false)
	fake._sprinting = false
	w.call("set_sprinting", false)
	for i in 80:
		w.call("_process", 1.0 / 20.0)
	_check((w.get("_vm_pos") as Vector3).distance_to(hip_pos) < 0.002,
			"spring stability: settles back onto HIP_POS (off %s)" % (w.get("_vm_pos") as Vector3 - hip_pos))
	_check(float(w.call("get_ads_blend")) == 0.0 and float(w.call("get_sprint_blend")) == 0.0,
			"spring stability: blends settle at exactly 0")

	# --- Check 8: recoil kick spring overshoots + settles. ---
	w.call("_apply_recoil")
	_check(float(w.get("_vm_kick_z")) > 0.0 and float(w.get("_vm_kick_pitch")) > 0.0,
			"kick spring: shot punches offsets positive (z %.4f)" % float(w.get("_vm_kick_z")))
	var min_z := 0.0
	var kick_finite := true
	for i in 90:
		w.call("_tick_vm_kick", 0.016)
		min_z = minf(min_z, float(w.get("_vm_kick_z")))
		if not is_finite(float(w.get("_vm_kick_z"))) or not is_finite(float(w.get("_vm_kick_pitch"))):
			kick_finite = false
	_check(kick_finite, "kick spring: finite over 90 ticks")
	_check(min_z < 0.0, "kick spring: return overshoots below zero (min %.4f) — a spring, not an exponential" % min_z)
	_check(absf(float(w.get("_vm_kick_z"))) < 0.001 and absf(float(w.get("_vm_kick_pitch"))) < 0.001,
			"kick spring: settles < 0.001 (z %.5f)" % float(w.get("_vm_kick_z")))
	w.queue_free()

	# --- Check 9: sprint pose + fire NOT blocked (ruling §7.3). ---
	var w2: Node3D = _make_stage_weapon("smg9", stage, fake, cam)
	_check((w2.get("_vm_pos") as Vector3).is_equal_approx(
			hip_pos + (_weapon_base.get("VM_RAISE_START_OFFSET") as Vector3)),
			"sprint pose: raise seeds the spring at HIP + VM_RAISE_START_OFFSET")
	for i in 40:
		w2.call("_process", 1.0 / 60.0)
	_check((w2.get("_vm_pos") as Vector3).distance_to(hip_pos) < 0.002,
			"sprint pose: raise settles onto HIP_POS")
	fake._sprinting = true
	w2.call("set_sprinting", true)
	for i in 60:
		w2.call("_process", 1.0 / 60.0)
	_check(float(w2.call("get_sprint_blend")) == 1.0, "sprint pose: blend settles at exactly 1.0")
	_check((w2.get("_vm_pos") as Vector3).distance_to(
			hip_pos + (_weapon_base.get("SPRINT_POSE_POS") as Vector3)) < 0.002,
			"sprint pose: position == HIP + SPRINT_POSE_POS")
	_check((w2.get("_vm_rot") as Vector3).distance_to(
			hip_rot + (_weapon_base.get("SPRINT_POSE_ROT") as Vector3)) < 0.002,
			"sprint pose: rotation == HIP_ROT + SPRINT_POSE_ROT")
	fake._sprinting = false
	w2.call("set_sprinting", false)
	for i in 60:
		w2.call("_process", 1.0 / 60.0)
	_check(float(w2.call("get_sprint_blend")) == 0.0
			and (w2.get("_vm_pos") as Vector3).distance_to(hip_pos) < 0.002,
			"sprint pose: release returns to HIP_POS, blend exactly 0")
	w2.queue_free()
	# Fire gate: p9 (SEMI) at full sprint state still spends a round.
	# The trigger pull itself is deferred to _process (live tree) —
	# see the note there. Everything else about the weapon is set here.
	var w3: Node3D = _arsenal.call("make_weapon", "p9")
	stage.add_child(w3)
	w3.call("attach", fake, null)
	w3.set("_raise_t", 999.0)
	w3.call("set_sprinting", true)
	_fire_w = w3
	_fire_stage = stage
	_fire_mag_before = int(w3.get("mag"))


# --- Stage C -------------------------------------------------------------

## Check 10: the reload pose track, sampled pure for every weapon.
func _check_reload_track() -> void:
	for id in PLAN_WEIGHTS:
		var w: Node3D = _arsenal.call("make_weapon", id)
		_check(w != null, "%s: track weapon builds" % id)
		if w == null:
			continue
		var finite_all := true
		var moves := false
		for stage in [1, 2, 3]:
			for p in [0.0, 0.25, 0.5, 0.75, 1.0]:
				var pose: Array = w.call("reload_track_pose", stage, p)
				var pp := pose[0] as Vector3
				var pr := pose[1] as Vector3
				if not _finite3(pp) or not _finite3(pr):
					finite_all = false
				if pp.length() > 0.01 or pr.length() > 0.01:
					moves = true
		_check(finite_all, "%s: reload track finite at every stage/progress sample" % id)
		_check(moves, "%s: reload track actually moves the gun mid-track" % id)
		var end1: Array = w.call("reload_track_pose", 1, 1.0)
		var start2: Array = w.call("reload_track_pose", 2, 0.0)
		var end2: Array = w.call("reload_track_pose", 2, 1.0)
		var start3: Array = w.call("reload_track_pose", 3, 0.0)
		_check((end1[0] as Vector3).is_equal_approx(start2[0] as Vector3)
				and (end1[1] as Vector3).is_equal_approx(start2[1] as Vector3),
				"%s: track continuous MAG_OUT -> MAG_IN" % id)
		_check((end2[0] as Vector3).is_equal_approx(start3[0] as Vector3)
				and (end2[1] as Vector3).is_equal_approx(start3[1] as Vector3),
				"%s: track continuous MAG_IN -> CHAMBER" % id)
		var start1: Array = w.call("reload_track_pose", 1, 0.0)
		var end3: Array = w.call("reload_track_pose", 3, 1.0)
		_check((start1[0] as Vector3).length() < EPS and (start1[1] as Vector3).length() < EPS,
				"%s: track starts at zero" % id)
		_check((end3[0] as Vector3).length() < 0.002 and (end3[1] as Vector3).length() < 0.002,
				"%s: track ends at zero (gun back in hand)" % id)
		var none_pose: Array = w.call("reload_track_pose", 0, 0.5)
		_check((none_pose[0] as Vector3).length() < EPS and (none_pose[1] as Vector3).length() < EPS,
				"%s: no pose outside the stage machine" % id)
		var total := 0.0
		for s in (w.get("reload_stages") as Array):
			total += float(s)
		_check(total > 0.0, "%s: reload_stages sum %.2f > 0 (track stretches over it)" % [id, total])
		w.free()


## One landing on a fresh weapon; returns the dip [depth, pitch] read
## one tick after touchdown (the firing tick also integrates the dip
## spring once, so the read is a hair under the analytic depth).
func _dip_after_fall(id: String, stage: Node3D, fake: _FakeLandingPlayer,
		cam: Camera3D, fall_vy: float) -> Vector2:
	var w: Node3D = _arsenal.call("make_weapon", id)
	stage.add_child(w)
	w.call("attach", fake, cam)
	w.call("on_equip")
	fake.on_floor = false
	fake.velocity = Vector3(0.0, fall_vy, 0.0)
	for i in 3:
		w.call("_process", 1.0 / 60.0)
	fake.on_floor = true
	fake.velocity = Vector3.ZERO
	w.call("_process", 1.0 / 60.0)
	var dip: Vector2 = w.call("get_land_dip")
	# Settle: the dip spring must come home to zero on its own.
	for i in 240:
		w.call("_process", 1.0 / 60.0)
	_check(absf((w.call("get_land_dip") as Vector2).x) < 0.001
			and absf((w.call("get_land_dip") as Vector2).y) < 0.001,
			"%s: landing dip settles back to zero" % id)
	w.queue_free()
	return dip


func _check_stage_c_scene() -> void:
	_check_reload_track()
	var stage := Node3D.new()
	root.add_child(stage)
	var fake := _FakePlayer.new()
	stage.add_child(fake)
	var cam := Camera3D.new()
	stage.add_child(cam)
	var hip_pos: Vector3 = _weapon_base.get("HIP_POS")
	var dt := 1.0 / 60.0

	# --- Check 11: live reload at hip (ar7). ---
	var w: Node3D = _make_stage_weapon("ar7", stage, fake, cam)
	for i in 40:
		w.call("_process", dt)
	var vm := w.get("_viewmodel") as Node3D
	var stages_arr: Array = w.get("reload_stages")
	var total_t := 0.0
	for s in stages_arr:
		total_t += float(s)
	w.set("mag", 5)
	var mag_size := int(w.get("mag_size"))
	w.call("try_reload")
	_check(int(w.get("_reload_stage")) == 1, "live reload: MAG_OUT engaged by try_reload")
	var frames := 0
	var max_dev := 0.0
	var finite_all := true
	var mag_early := false
	var seat_jolt_seen := false
	var saw_chamber := false
	while int(w.get("_reload_stage")) != 0 and frames < 600:
		w.call("_process", dt)
		frames += 1
		var st := int(w.get("_reload_stage"))
		if not _finite3(vm.position) or not _finite3(vm.rotation):
			finite_all = false
		max_dev = maxf(max_dev, vm.position.distance_to(hip_pos))
		if st == 1 or st == 2:
			if int(w.get("mag")) != 5:
				mag_early = true
		if st == 3 and not saw_chamber:
			saw_chamber = true
			_check(int(w.get("mag")) == mag_size,
					"live reload: mag refills exactly at the CHAMBER boundary")
			if (w.get("_vm_pos_vel") as Vector3).y > 0.1:
				seat_jolt_seen = true
	_check(finite_all, "live reload: viewmodel transform finite throughout")
	_check(max_dev > 0.05, "live reload: choreography visibly moves the gun (max dev %.3f m)" % max_dev)
	_check(not mag_early, "live reload: mag untouched during MAG_OUT/MAG_IN (timing law)")
	_check(saw_chamber, "live reload: CHAMBER stage reached")
	_check(seat_jolt_seen, "live reload: mag-seat jolt kicks the pose spring at the boundary")
	_check(absf(float(frames) * dt - total_t) <= 4.0 * dt + 0.001,
			"live reload: total time %.2fs == sum(reload_stages) %.2fs (no retiming)" % [frames * dt, total_t])
	for i in 90:
		w.call("_process", dt)
	_check(vm.position.distance_to(hip_pos) < 0.002,
			"live reload: gun settles back onto HIP_POS afterwards")
	w.queue_free()

	# --- Check 12: the same reload at full ADS is damped, not absent. ---
	var w2: Node3D = _make_stage_weapon("ar7", stage, fake, cam)
	for i in 40:
		w2.call("_process", dt)
	w2.call("set_ads", true)
	for i in 90:
		w2.call("_process", dt)
	_check(float(w2.call("get_ads_blend")) == 1.0, "ADS reload: blend at exactly 1.0 before reload")
	var vm2 := w2.get("_viewmodel") as Node3D
	var ads_pos: Vector3 = w2.get("_ads_pos")
	w2.set("mag", 5)
	w2.call("try_reload")
	var ads_frames := 0
	var ads_max_dev := 0.0
	while int(w2.get("_reload_stage")) != 0 and ads_frames < 600:
		w2.call("_process", dt)
		ads_frames += 1
		ads_max_dev = maxf(ads_max_dev, vm2.position.distance_to(ads_pos))
	_check(ads_max_dev > 0.008, "ADS reload: choreography still plays at ADS (max dev %.3f m)" % ads_max_dev)
	_check(ads_max_dev < max_dev * 0.75,
			"ADS reload: amplitude yields to ADS (%.3f < 0.75 x hip %.3f)" % [ads_max_dev, max_dev])
	w2.queue_free()

	# --- Check 13: landing dip, scaled by fall and by weight. ---
	var land_fake := _FakeLandingPlayer.new()
	stage.add_child(land_fake)
	var p9_dip := _dip_after_fall("p9", stage, land_fake, cam, -10.0)
	var lmg_dip := _dip_after_fall("lmg", stage, land_fake, cam, -10.0)
	_check(p9_dip.x > 0.03, "landing dip: hard fall dips the p9 (%.3f m)" % p9_dip.x)
	_check(p9_dip.y > 0.02, "landing dip: hard fall pitches the p9 (%.3f rad)" % p9_dip.y)
	_check(lmg_dip.x > p9_dip.x * 1.5,
			"landing dip: LMG dips deeper than P9 at the same fall (%.3f vs %.3f)" % [lmg_dip.x, p9_dip.x])
	var shallow := _dip_after_fall("p9", stage, land_fake, cam, -5.0)
	_check(shallow.x > 0.005 and shallow.x < p9_dip.x,
			"landing dip: shallower fall, shallower dip (%.3f < %.3f)" % [shallow.x, p9_dip.x])
	var soft := _dip_after_fall("p9", stage, land_fake, cam, -1.5)
	_check(soft.x == 0.0 and soft.y == 0.0, "landing dip: soft fall (1.5 m/s) does not dip")

	# --- Check 14: weight softens the pose spring (raise settle). ---
	var dist_at_10 := {}
	for id in ["p9", "lmg"]:
		var w3: Node3D = _make_stage_weapon(id, stage, fake, cam)
		for i in 10:
			w3.call("_process", dt)
		dist_at_10[id] = (w3.get("_vm_pos") as Vector3).distance_to(hip_pos)
		for i in 80:
			w3.call("_process", dt)
		_check((w3.get("_vm_pos") as Vector3).distance_to(hip_pos) < 0.002,
				"weight springs: %s raise settles onto HIP_POS" % id)
		w3.queue_free()
	_check(float(dist_at_10["lmg"]) > float(dist_at_10["p9"]) + 0.01,
			"weight springs: LMG trails HIP by %.3f vs P9 %.3f at frame 10 (stiffness consumed)" % [dist_at_10["lmg"], dist_at_10["p9"]])

	# --- Check 15: weight grows sway + bob (measured off the writes). ---
	fake.velocity = Vector3(6.0, 0.0, 0.0)
	var sway_max := {}
	var bob_max := {}
	for id in ["p9", "lmg"]:
		var w4: Node3D = _make_stage_weapon(id, stage, fake, cam)
		for i in 60:
			w4.call("_process", dt)
		var vm4 := w4.get("_viewmodel") as Node3D
		var sm := 0.0
		var bm := 0.0
		for i in 240:
			w4.call("_process", dt)
			sm = maxf(sm, absf(vm4.rotation.x - (w4.get("_vm_rot") as Vector3).x))
			bm = maxf(bm, absf(vm4.position.y - (w4.get("_vm_pos") as Vector3).y))
		sway_max[id] = sm
		bob_max[id] = bm
		w4.queue_free()
	fake.velocity = Vector3.ZERO
	_check(float(sway_max["lmg"]) > float(sway_max["p9"]) * 1.25,
			"weight sway: LMG %.4f rad > P9 %.4f rad" % [sway_max["lmg"], sway_max["p9"]])
	_check(float(bob_max["lmg"]) > float(bob_max["p9"]) * 1.2,
			"weight bob: LMG %.4f m > P9 %.4f m" % [bob_max["lmg"], bob_max["p9"]])

	# --- Check 16: Raptor never enters the reload machine. ---
	var wr: Node3D = _make_stage_weapon("raptor", stage, fake, cam)
	wr.call("try_reload")
	var raptor_ok := true
	for i in 600:
		if i % 97 == 0:
			wr.call("set_sprinting", i % 194 == 0)
		if i % 131 == 0:
			wr.call("_apply_recoil")
		wr.call("_process", dt)
		if int(wr.get("_reload_stage")) != 0:
			raptor_ok = false
		var vmr := wr.get("_viewmodel") as Node3D
		if vmr != null and (not _finite3(vmr.position) or not _finite3(vmr.rotation)):
			raptor_ok = false
	_check(raptor_ok, "raptor: 600 frames — no reload track, finite transforms")
	_check((wr.call("get_land_dip") as Vector2) == Vector2.ZERO, "raptor: no landing dip on a floor-less double")
	wr.queue_free()
	stage.queue_free()


# --- Stage D -------------------------------------------------------------

## Closest distance between a ray (origin m, unit dir d, length <= 90 m
## — fire_hitscan's range) and a segment a..b.
func _ray_segment_dist(m: Vector3, d: Vector3, a: Vector3, b: Vector3) -> float:
	var u := b - a
	var r := m - a
	var aa := d.dot(d)
	var bb := d.dot(u)
	var cc := u.dot(u)
	var dd := d.dot(r)
	var ee := u.dot(r)
	var denom := aa * cc - bb * bb
	var s := 0.0
	if denom > 0.000000001:
		s = clampf((aa * ee - bb * dd) / denom, 0.0, 1.0)
	var t := (bb * s - dd) / aa
	if t < 0.0:
		t = 0.0
		s = clampf(ee / cc, 0.0, 1.0)
	elif t > 90.0:
		t = 90.0
		s = clampf((ee + t * bb) / cc, 0.0, 1.0)
	return (m + d * t).distance_to(a + u * s)


## Monte-Carlo of the fire_hitscan shot distribution against a capsule
## of the given radius: muzzle at eye height, aim at the chest point
## (player position + 1.15 m) 25 m away, direction jittered by uniform
## ±spread yaw then ±spread pitch — the exact structure of
## EnemyBase.fire_hitscan. The capsule axis runs from (0, r) to
## (0, 1.7 - r), matching scenes/player.tscn (centre 0.85, height 1.7).
func _mc_hit_rate(radius: float, spread_deg: float, shots: int, seed: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var muzzle := Vector3(0.0, 1.4, 0.0)
	var aim := Vector3(0.0, 1.15, 25.0)
	var seg_a := Vector3(0.0, radius, 25.0)
	var seg_b := Vector3(0.0, 1.7 - radius, 25.0)
	var sr := deg_to_rad(spread_deg)
	var hits := 0
	for i in shots:
		var dir := (aim - muzzle).normalized()
		dir = dir.rotated(Vector3.UP, rng.randf_range(-sr, sr))
		var right := dir.cross(Vector3.UP)
		if right.length_squared() > 0.0001:
			dir = dir.rotated(right.normalized(), rng.randf_range(-sr, sr))
		if _ray_segment_dist(muzzle, dir, seg_a, seg_b) <= radius:
			hits += 1
	return float(hits) / float(shots)


func _check_stage_d_pure() -> void:
	# --- Check 17a: script-only player stores + clamps hitbox_norm. ---
	var player: CharacterBody3D = load("res://scripts/player/player.gd").new()
	player.call("set_weapon_hitbox", 1.0)
	_check(_approx(float(player.get("_hitbox_norm")), 1.0), "hitbox: norm 1.0 stored")
	player.call("set_weapon_hitbox", 2.5)
	_check(_approx(float(player.get("_hitbox_norm")), 1.0), "hitbox: norm clamps at 1.0")
	player.call("set_weapon_hitbox", -1.0)
	_check(_approx(float(player.get("_hitbox_norm")), 0.0), "hitbox: norm clamps at 0.0")
	_check(_approx(float(player.call("weapon_hitbox_radius")), 0.4),
			"hitbox: no capsule resolved (script-only) -> base radius 0.4")
	player.free()

	# --- Check 17b: the manager push drives BOTH setters, and the
	# hitbox value is weight_effects()["hitbox_norm"], not weight_norm.
	var manager: Node3D = load("res://scripts/weapons/weapon_manager.gd").new()
	var rec := _RecordingPlayer.new()
	manager.set("_player", rec)
	for id in ["lmg", "p9", "raptor"]:
		var w: Node3D = _arsenal.call("make_weapon", id)
		manager.set("_current", w)
		manager.call("_push_weapon_weight")
		_check(_approx(rec.got_weight, float(w.get("weight_norm"))),
				"push %s: weight_norm pushed (%.4f)" % [id, rec.got_weight])
		_check(_approx(rec.got_hitbox, float((w.call("weight_effects") as Dictionary)["hitbox_norm"])),
				"push %s: hitbox_norm pushed from weight_effects (%.4f)" % [id, rec.got_hitbox])
		w.free()
	manager.free()
	rec.free()

	# --- Check 19: Monte-Carlo hit probability vs capsule radius. ---
	# Identical seed per radius -> identical ray sets -> hit sets nest,
	# so the ordering assertions are exact, not statistical hopes.
	for r in [0.40625, 0.43375, 0.5]:
		_check(_approx(_mc_hit_rate(r, 0.0, 16, 7), 1.0),
				"monte-carlo control: zero-spread ray always hits at r %.5f" % r)
	var rate_p9 := _mc_hit_rate(0.40625, 4.0, 6000, 20261128)
	var rate_ar7 := _mc_hit_rate(0.43375, 4.0, 6000, 20261128)
	var rate_lmg := _mc_hit_rate(0.5, 4.0, 6000, 20261128)
	_check(rate_p9 > 0.05 and rate_p9 < 0.9, "monte-carlo: P9 rate sane (%.3f)" % rate_p9)
	_check(rate_ar7 >= rate_p9, "monte-carlo: AR7 rate >= P9 rate (%.3f >= %.3f)" % [rate_ar7, rate_p9])
	_check(rate_lmg >= rate_ar7, "monte-carlo: LMG rate >= AR7 rate (%.3f >= %.3f)" % [rate_lmg, rate_ar7])
	_check(rate_lmg > rate_p9 + 0.015,
			"monte-carlo: heavier gun is measurably easier to hit (LMG %.3f > P9 %.3f + 0.015)" % [rate_lmg, rate_p9])

	# --- Check 20: flinch spring + smoothed stride (EnemyBase state
	# methods driven directly on a script instance — no tree needed).
	var enemy: CharacterBody3D = load("res://scripts/enemies/enemy_base.gd").new()
	enemy.set("anim_flinch", 1.0)
	enemy.set("_anim_flinch_vel", 0.0)
	var min_flinch := 0.0
	var finite := true
	var early := 1.0
	for i in 180:
		enemy.call("_update_anim_flinch", 1.0 / 60.0)
		var f := float(enemy.get("anim_flinch"))
		if not is_finite(f):
			finite = false
		min_flinch = minf(min_flinch, f)
		if i == 5:
			early = f
	_check(finite, "flinch spring: finite over 180 steps at dt 1/60")
	_check(early < 0.3, "flinch spring: snaps fast (%.3f at 0.1 s; linear decay would read 0.5)" % early)
	_check(min_flinch < -0.04 and min_flinch > -0.30,
			"flinch spring: overshoots past neutral ~16%% (min %.3f)" % min_flinch)
	_check(float(enemy.get("anim_flinch")) == 0.0 and float(enemy.get("_anim_flinch_vel")) == 0.0,
			"flinch spring: settles to an exact rest at 0")
	enemy.set("anim_flinch", 1.0)
	enemy.set("_anim_flinch_vel", 0.0)
	finite = true
	for i in 120:
		enemy.call("_update_anim_flinch", 1.0 / 20.0)
		if not is_finite(float(enemy.get("anim_flinch"))):
			finite = false
	_check(finite and float(enemy.get("anim_flinch")) == 0.0,
			"flinch spring: stable + settled at dt 1/20 (substepped)")
	enemy.call("_update_anim_speed", 3.0, 1.0 / 60.0)
	var one_step := float(enemy.get("_anim_speed"))
	_check(one_step > 0.3 and one_step < 1.0,
			"smoothed stride: one step toward 3 m/s fades (%.3f, not a pop to 3.0)" % one_step)
	for i in 240:
		enemy.call("_update_anim_speed", 3.0, 1.0 / 60.0)
	_check(float(enemy.get("_anim_speed")) == 3.0, "smoothed stride: snaps exactly onto 3.0")
	enemy.call("_update_anim_speed", 0.0, 1.0 / 60.0)
	var down_step := float(enemy.get("_anim_speed"))
	_check(down_step > 2.0 and down_step < 2.9,
			"smoothed stride: step back down fades too (%.3f)" % down_step)
	for i in 240:
		enemy.call("_update_anim_speed", 0.0, 1.0 / 60.0)
	_check(float(enemy.get("_anim_speed")) == 0.0, "smoothed stride: settles exactly at 0")
	enemy.free()


## World pitch of a soldier's gun: body lean + arm pitch + gun pivot.
func _gun_world_pitch(s: Node3D, rig: Dictionary) -> float:
	return (rig["body_root"] as Node3D).rotation.x \
			+ (rig["arm_r"] as Node3D).rotation.x \
			+ (s.get("_gun_pivot") as Node3D).rotation.x


func _player_shape_radius(p: Node) -> float:
	var cs := p.get_node("CollisionShape3D") as CollisionShape3D
	return (cs.shape as CapsuleShape3D).radius


func _check_stage_d_scene() -> void:
	# --- Check 18: real player instances own independent capsules. ---
	var stage := Node3D.new()
	root.add_child(stage)
	var packed := load("res://scenes/player.tscn") as PackedScene
	var p1 := packed.instantiate()
	stage.add_child(p1)
	var p2 := packed.instantiate()
	stage.add_child(p2)
	# The scene's WeaponManager equips the default AR7 in _ready and
	# pushes its hitbox — a fresh instance reads the AR7 radius, which
	# proves the whole in-scene chain (manager _ready -> push -> shape).
	var ar7: Node3D = _arsenal.call("make_weapon", "ar7")
	var ar7_hit := float((ar7.call("weight_effects") as Dictionary)["hitbox_norm"])
	ar7.free()
	var spawn_radius := 0.4 + 0.1 * ar7_hit
	_check(_approx(_player_shape_radius(p1), spawn_radius),
			"capsule: fresh instance reads the equipped AR7 radius (%.5f)" % spawn_radius)
	_check(_approx(float(p1.call("weapon_hitbox_radius")), spawn_radius), "capsule: hook agrees")
	p1.call("set_weapon_hitbox", 0.0)
	_check(_approx(_player_shape_radius(p1), 0.4), "capsule: hitbox_norm 0 restores exactly 0.4")
	p1.call("set_weapon_hitbox", 1.0)
	_check(_approx(_player_shape_radius(p1), 0.5), "capsule: LMG norm grows the LIVE shape to 0.50")
	_check(_approx(_player_shape_radius(p2), spawn_radius),
			"capsule: second instance unaffected (shape duplicated per instance)")
	p1.call("set_weapon_hitbox", 0.0625)
	_check(_approx(_player_shape_radius(p1), 0.40625), "capsule: P9 re-push replaces (0.40625)")
	p1.call("set_weapon_hitbox", 0.3375)
	_check(_approx(_player_shape_radius(p1), 0.43375), "capsule: AR7 re-push replaces (0.43375)")
	p1.call("set_weapon_weight", 1.0)
	p1.call("set_weapon_hitbox", 1.0)
	_check(_approx(float(p1.get("_weapon_speed_mult")), 0.78)
			and _approx(_player_shape_radius(p1), 0.5),
			"capsule: dual push lands together (speed 0.78 AND radius 0.50)")
	var p3 := packed.instantiate()
	stage.add_child(p3)
	_check(_approx(_player_shape_radius(p3), spawn_radius),
			"capsule: fresh third instance reads the AR7 radius (scene sub-resource unpolluted)")
	p1.queue_free()
	p2.queue_free()
	p3.queue_free()

	# --- Check 21: soldier pose — aim pitch, hip sway, flinch render.
	var soldier_script: GDScript = load("res://scripts/enemies/voxel_soldier.gd")
	var dt := 1.0 / 60.0

	var pitches := {}
	for key in ["up", "flat", "down", "omitted"]:
		var s: Node3D = soldier_script.new()
		stage.add_child(s)
		var rig: Dictionary = s.call("build", "grunt")
		var params := {"aiming": true, "speed": 0.0}
		if key == "up":
			params["aim_pitch"] = 0.5
		elif key == "down":
			params["aim_pitch"] = -0.5
		elif key == "flat":
			params["aim_pitch"] = 0.0
		for i in 40:
			s.call("animate_full", dt, params)
		pitches[key] = _gun_world_pitch(s, rig)
		s.queue_free()
	_check(absf(float(pitches["flat"])) < 0.03, "aim pitch: level target -> level gun (%.3f)" % pitches["flat"])
	_check(absf(float(pitches["up"]) - float(pitches["flat"]) - 0.5) < 0.06,
			"aim pitch: target above -> gun pitches up the full 0.5 (delta %.3f)" % (float(pitches["up"]) - float(pitches["flat"])))
	_check(absf(float(pitches["down"]) - float(pitches["flat"]) + 0.5) < 0.06,
			"aim pitch: target below -> gun pitches down the full 0.5 (delta %.3f)" % (float(pitches["down"]) - float(pitches["flat"])))
	_check(absf(float(pitches["omitted"]) - float(pitches["flat"])) < 0.02,
			"aim pitch: omitted param == 0.0 (existing callers unchanged)")

	# Hip sway: mid-transition speed oscillates the body roll; rest is 0.
	var sw: Node3D = soldier_script.new()
	stage.add_child(sw)
	var sw_rig: Dictionary = sw.call("build", "grunt")
	var sway_max := 0.0
	for i in 240:
		sw.call("animate_full", dt, {"speed": 1.5})
		sway_max = maxf(sway_max, absf((sw_rig["body_root"] as Node3D).rotation.z))
	_check(sway_max > 0.02, "hip sway: stride roll oscillates at move_k 0.5 (max %.3f rad)" % sway_max)
	sw.queue_free()
	var rest: Node3D = soldier_script.new()
	stage.add_child(rest)
	var rest_rig: Dictionary = rest.call("build", "grunt")
	for i in 60:
		rest.call("animate_full", dt, {"speed": 0.0})
	_check(absf((rest_rig["body_root"] as Node3D).rotation.z) < 0.005,
			"hip sway: exactly still at rest")
	rest.queue_free()

	# Flinch render: positive snaps back, negative (spring overshoot)
	# settles forward, and the value clamps at -0.25.
	var flinch_rots := {}
	for key in ["pos", "neg", "clamped"]:
		var s2: Node3D = soldier_script.new()
		stage.add_child(s2)
		var rig2: Dictionary = s2.call("build", "grunt")
		var fv := 0.6 if key == "pos" else (-0.15 if key == "neg" else -1.0)
		for i in 60:
			s2.call("animate_full", dt, {"flinch": fv})
		flinch_rots[key] = (rig2["body_root"] as Node3D).rotation.x
		s2.queue_free()
	_check(float(flinch_rots["pos"]) > 0.12, "flinch pose: +0.6 snaps the torso back (%.3f)" % flinch_rots["pos"])
	_check(float(flinch_rots["neg"]) < -0.025,
			"flinch pose: -0.15 (overshoot) settles the torso forward (%.3f)" % flinch_rots["neg"])
	_check(float(flinch_rots["clamped"]) < -0.05 and float(flinch_rots["clamped"]) > -0.13,
			"flinch pose: -1.0 clamps at -0.25 (%.3f)" % flinch_rots["clamped"])
	stage.queue_free()


# --- Gate fix (2026-11-28): large-dt spring stability + weight rider ---

func _check_gate_fix() -> void:
	var max_dt := float(_weapon_base.get("VM_SPRING_MAX_DT"))
	var max_frame := float(_weapon_base.get("VM_SPRING_MAX_FRAME"))
	var hip_pos: Vector3 = _weapon_base.get("HIP_POS")

	# --- Check 22: the substep plan itself. ---
	var sub: Array = _weapon_base.call("_spring_substeps", 1.0 / 60.0)
	_check(int(sub[0]) == 1 and _approx(float(sub[1]), 1.0 / 60.0),
			"substeps: dt 1/60 -> 1 step, h == dt (pre-fix behaviour pinned)")
	sub = _weapon_base.call("_spring_substeps", 0.25)
	_check(int(sub[0]) == 8 and float(sub[1]) <= max_dt + 0.000001,
			"substeps: dt 0.25 -> 8 steps of h <= MAX_DT (got %d x %.5f)" % [int(sub[0]), float(sub[1])])
	sub = _weapon_base.call("_spring_substeps", 3.0)
	_check(float(sub[1]) <= max_dt + 0.000001,
			"substeps: dt 3.0 -> h %.5f <= MAX_DT %.5f (max-h target, not a count cap)" % [float(sub[1]), max_dt])
	_check(_approx(float(int(sub[0])) * float(sub[1]), max_frame),
			"substeps: dt 3.0 integrates exactly the clamped %.1f s of spring time" % max_frame)
	sub = _weapon_base.call("_spring_substeps", 0.0)
	_check(int(sub[0]) == 1 and float(sub[1]) == 0.0, "substeps: dt 0 -> 1 step of h 0")

	var stage := Node3D.new()
	root.add_child(stage)
	var fake := _FakePlayer.new()
	stage.add_child(fake)
	var cam := Camera3D.new()
	stage.add_child(cam)

	# --- Check 23a: the Breaker repro through the real _process. ---
	var w: Node3D = _make_stage_weapon("p9", stage, fake, cam)
	w.call("_apply_recoil")
	_check(float(w.get("_vm_kick_z")) > 0.0, "large-dt kick: recoil punched the kick live before the hitch")
	w.call("_process", 3.0)
	_check(is_finite(float(w.get("_vm_kick_z"))) and is_finite(float(w.get("_vm_kick_pitch")))
			and is_finite(float(w.get("_vm_kick_z_vel"))) and is_finite(float(w.get("_vm_kick_pitch_vel"))),
			"large-dt kick: all kick state finite after _process(3.0) (was 4.46e10)")
	_check(absf(float(w.get("_vm_kick_z"))) < 0.05 and absf(float(w.get("_vm_kick_pitch"))) < 0.05,
			"large-dt kick: bounded after _process(3.0) (z %.5f)" % float(w.get("_vm_kick_z")))
	var vm := w.get("_viewmodel") as Node3D
	_check(_finite3(vm.position) and vm.position.length() < 2.0,
			"large-dt kick: viewmodel write finite + bounded after the hitch")
	var settled := false
	for i in 30:
		w.call("_process", 1.0 / 60.0)
		if absf(float(w.get("_vm_kick_z"))) < 0.001 and absf(float(w.get("_vm_kick_pitch"))) < 0.001:
			settled = true
	_check(settled, "large-dt kick: settles < 0.001 within 0.5 s of normal frames")
	w.queue_free()

	# --- Check 23b: the direct kick channel, incl. an absurd delta. ---
	var wk: Node3D = _arsenal.call("make_weapon", "p9")
	wk.set("_player", fake)
	wk.call("_apply_recoil")
	wk.call("_tick_vm_kick", 3.0)
	_check(is_finite(float(wk.get("_vm_kick_z"))) and absf(float(wk.get("_vm_kick_z"))) < 0.05,
			"large-dt kick: direct _tick_vm_kick(3.0) finite + bounded (z %.5f)" % float(wk.get("_vm_kick_z")))
	wk.call("_apply_recoil")
	wk.call("_tick_vm_kick", 3600.0)
	_check(is_finite(float(wk.get("_vm_kick_z"))) and is_finite(float(wk.get("_vm_kick_pitch")))
			and absf(float(wk.get("_vm_kick_z"))) < 0.05,
			"large-dt kick: _tick_vm_kick(3600) clamped, finite + bounded")
	wk.free()

	# --- Check 24: landing dip with live state at dt = 3.0. ---
	var land_fake := _FakeLandingPlayer.new()
	stage.add_child(land_fake)
	var wd: Node3D = _arsenal.call("make_weapon", "p9")
	stage.add_child(wd)
	wd.call("attach", land_fake, cam)
	wd.call("on_equip")
	wd.set("_land_dip", 0.05)
	wd.set("_land_dip_pitch", 0.06)
	wd.call("_tick_land_dip", 3.0)
	_check(is_finite(float(wd.get("_land_dip"))) and is_finite(float(wd.get("_land_dip_pitch")))
			and absf(float(wd.get("_land_dip"))) <= 0.05 and absf(float(wd.get("_land_dip_pitch"))) <= 0.06,
			"large-dt dip: finite, never grows at dt 3.0 (was ~9.9e11; dip %.5f)" % float(wd.get("_land_dip")))
	var dip_settled := false
	for i in 30:
		wd.call("_tick_land_dip", 1.0 / 60.0)
		if absf(float(wd.get("_land_dip"))) < 0.001 and absf(float(wd.get("_land_dip_pitch"))) < 0.001:
			dip_settled = true
	_check(dip_settled, "large-dt dip: settles < 0.001 within 0.5 s of normal frames")
	wd.queue_free()

	# --- Check 25: pose spring at dt = 3.0 from the raised offset. ---
	var wp: Node3D = _make_stage_weapon("p9", stage, fake, cam)
	wp.call("_process", 3.0)
	_check(_finite3(wp.get("_vm_pos")) and _finite3(wp.get("_vm_rot"))
			and _finite3(wp.get("_vm_pos_vel")) and _finite3(wp.get("_vm_rot_vel")),
			"large-dt pose: all pose state finite after _process(3.0) (was ~1e16)")
	_check((wp.get("_vm_pos") as Vector3).distance_to(hip_pos) < 0.002,
			"large-dt pose: settled onto HIP_POS after the hitch (off %s)" % (wp.get("_vm_pos") as Vector3 - hip_pos))
	wp.queue_free()
	stage.queue_free()

	# --- Check 26: the weight rider (null / non-numeric / int). ---
	var nullw := (_weapons()["ar7"] as Dictionary).duplicate(true)
	nullw["weight"] = null
	var nw: Node3D = _weapon_base.new()
	nw.call("setup", nullw)
	_check(_approx(float(nw.get("weight")), float(_weapon_base.get("WEIGHT_DEFAULT"))),
			"weight rider: explicit null weight falls back to WEIGHT_DEFAULT")
	_check(_approx(float(nw.get("weight_norm")), 0.3125),
			"weight rider: null weight -> default weight_norm 0.3125")
	_check(nw.get("_viewmodel") != null,
			"weight rider: setup() completes with null weight (viewmodel built)")
	nw.free()
	var strw := (_weapons()["ar7"] as Dictionary).duplicate(true)
	strw["weight"] = "heavy"
	var sw2: Node3D = _weapon_base.new()
	sw2.call("setup", strw)
	_check(_approx(float(sw2.get("weight")), float(_weapon_base.get("WEIGHT_DEFAULT")))
			and sw2.get("_viewmodel") != null,
			"weight rider: non-numeric weight falls back and setup() completes")
	sw2.free()
	var intw := (_weapons()["ar7"] as Dictionary).duplicate(true)
	intw["weight"] = 7
	var iw: Node3D = _weapon_base.new()
	iw.call("setup", intw)
	_check(_approx(float(iw.get("weight")), 7.0), "weight rider: int weight honoured (7 -> 7.0)")
	iw.free()
