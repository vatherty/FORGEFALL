# verify_feel.gd — headless verification for FORGEFALL Goal 1 FEEL.
# Usage: godot --headless --path <project> --script res://tools/verify_feel.gd
#
# CONTRACT (pre-Feel baselines read from the pre-change code — sprint 6.4,
# walk 4.2, slide friction 4.0 / end speed 2.5, wall-run 2.2 s / boost 1.10,
# grapple accel 48 / max speed 18 / reel 6):
#   1. MOVEMENT IS FASTER — SHIPPED (Worker A): sprint 11.0, walk 6.0,
#      slide friction 3.0 / end speed 2.0, wall-run 3.0 s / boost 1.25,
#      grapple accel 75 / max speed 30 / reel 10. This suite asserts the
#      shipped values clear improvement floors (50 m cross-time <= 7.0 s
#      vs 7.81 s baseline; slide / wall-run distances up) rather than
#      pinning exact numbers, so future retunes still pass.
#      Deliberate trades that are NOT regressions: SLIDE_MAX_TIME 3.0 -> 2.5
#      (entry speed 6.4 -> 11.0 more than compensates — distance is the
#      metric) and WALLRUN_MIN_SPEED 3.0 -> 4.0 (still far below sprint).
#   2. GUNFEEL — SHIPPED (Worker B): per-weapon recoil_recover + settle
#      delay + VM kick, hitmarker punch, damage-scaled flinch/knockback
#      (see tools/verify_g1_gunfeel.gd for the deep gunfeel suite — this
#      file asserts the same shipped behavior at integration level).
#   3. NO REGRESSIONS in this file: grapple PENDULUM preserved, no knob
#      slower than baseline. (Sibling suites verify_fixes,
#      verify_v06_movement, verify_linux, verify_windows + the 900-frame
#      smoke test are run separately by the coordinator and reported
#      alongside this suite — this script does not shell out to them.)
#   4. MOMENTUM (post-Feel hotfix, Colin playtest): jump keeps >=95% of
#      hspeed at apex; sprint persists across jump + landing; landing
#      with crouch held at speed enters a slide keeping >=80% of
#      landing speed after 0.2 s; low-speed crouch-land is a normal
#      crouch (no slide); slide-hop preserves slide velocity.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

# --- Pre-Feel baselines (read from the pre-change code, hardcoded here
# as the comparison point — the SHIPPED values are read live below). ---
const BASE_SPRINT := 6.4
const BASE_WALK := 4.2
const BASE_SLIDE_FRICTION := 4.0
const BASE_SLIDE_MAX_TIME := 3.0
const BASE_SLIDE_END_SPEED := 2.5
const BASE_WALLRUN_TIME := 2.2
const BASE_WALLRUN_BOOST := 1.10
const BASE_GRAPPLE_ACCEL := 48.0
const BASE_GRAPPLE_MAX_SPEED := 18.0
const BASE_GRAPPLE_REEL := 6.0
const BASE_GRAPPLE_RANGE := 60.0

# --- Feel floors (shipped values must clear these). ---
const FLOOR_SPRINT := 7.0          # >= +9.4% over 6.4
const FLOOR_CROSS_50M := 7.0        # seconds; baseline 50/6.4 = 7.81
const FLOOR_SLIDE_DIST := 2.0        # metres; pre-Feel slide ~1.7 m
const FLOOR_WALLRUN_DIST := 15.0     # metres; pre-Feel ~14.2 m at sprint entry
const FLOOR_GRAPPLE_DIRECT_SPEED := 15.0  # sanity: the faster pull still yanks

const MODE_DIRECT := 1
const MODE_PENDULUM := 2


class FakeHud extends Node:
	var calls: Array = []

	func show_hitmarker(killed: bool, headshot: bool) -> void:
		calls.append({"killed": killed, "headshot": headshot})


class FakeTarget extends RefCounted:
	var dead := false

	func is_dead() -> bool:
		return dead


var _fails := 0
var _passes := 0
var _frames := 0
var _phase := 0
var _last_phase := -1
var _phase_time := 0.0
var _phase_fired := false
var _player: Node = null
var _fake_hud: FakeHud = null
var _sprint_const := 0.0
var _steady_speed := 0.0
var _slide_started := false
var _slide_start := Vector3.ZERO
var _slide_dist := 0.0
var _crouch_attempts := 0
var _crouch_pressed_time := -1.0
var _wall_started := false
var _wall_start := Vector3.ZERO
var _wall_dist := 0.0
var _grapple_max_speed := 0.0
var _grapple_direct_ok := false
var _enemy: Node = null
# --- Momentum hotfix phase state. ---
var _mom_jump_speed := 0.0
var _mom_min_air := 0.0
var _mom_airborne := false
var _mom_apex_checked := false
var _mom_land_time := -1.0
var _mom_land_speed := 0.0
var _mom_crouch_pressed := false
var _mom_slide_speed := 0.0
var _mom_slide_min_air := 0.0
var _mom_slide_airborne := false
var _mom_hop_checked := false


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _warn(cond: bool, label: String) -> void:
	# Informational only: never fails the suite.
	if cond:
		print("PASS: ", label)
	else:
		print("WARN: ", label)


func _cmap(path: String) -> Dictionary:
	var s := load(path) as GDScript
	if s == null:
		return {}
	return s.get_script_constant_map()


func _release_all() -> void:
	for a in ["move_forward", "move_back", "move_left", "move_right",
			"sprint", "crouch", "jump", "ads", "grapple"]:
		Input.action_release(a)


func _initialize() -> void:
	var arena := Node3D.new()
	arena.name = "VerifyArena"
	root.add_child(arena)
	# Floor: top at y = 0, big enough for sprint/slide runs.
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	var fshape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(200.0, 1.0, 200.0)
	fshape.shape = fbox
	floor_body.add_child(fshape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	arena.add_child(floor_body)
	# Wall: face at x = 0.5 (same geometry as verify_fixes / v06_movement).
	var wall := StaticBody3D.new()
	wall.name = "Wall"
	var wshape := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(1.0, 6.0, 30.0)
	wshape.shape = wbox
	wall.add_child(wshape)
	wall.position = Vector3(1.0, 3.0, 0.0)
	arena.add_child(wall)
	# Ceiling: underside at y = 12.0 — a far near-vertical grapple anchor,
	# so the DIRECT pull has room to accelerate before the release radius.
	var ceil_body := StaticBody3D.new()
	ceil_body.name = "Ceiling"
	var cshape := CollisionShape3D.new()
	var cbox := BoxShape3D.new()
	cbox.size = Vector3(10.0, 1.0, 10.0)
	cshape.shape = cbox
	ceil_body.add_child(cshape)
	ceil_body.position = Vector3(0.0, 12.5, 0.0)
	arena.add_child(ceil_body)
	# Fake HUD first: WeaponBase._notify_hit resolves group "hud".
	_fake_hud = FakeHud.new()
	_fake_hud.name = "FakeHud"
	_fake_hud.add_to_group("hud")
	arena.add_child(_fake_hud)
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	_phase = 1
	print("VERIFY(feel): arena built, waiting for _ready + physics")


func _hspeed() -> float:
	return Vector2(_player.velocity.x, _player.velocity.z).length()


func _process(delta: float) -> bool:
	_frames += 1
	# Headless _process frames run FASTER than the 60 Hz physics ticks, so
	# every wait/timeout below is keyed on real elapsed time, not frames.
	if _phase != _last_phase:
		_last_phase = _phase
		_phase_time = 0.0
		_phase_fired = false
		_frames = 0
	_phase_time += delta
	match _phase:
		1:
			if _phase_time < 0.1:
				return false
			_check_constants()
			# Sprint setup: grounded start, sprint + forward held.
			_player.position = Vector3(0.0, 2.0, 30.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			Input.action_press("move_forward", 1.0)
			Input.action_press("sprint", 1.0)
			_phase = 2
			_frames = 0
		2:
			# Steady-state sprint speed after ~1.5 s (fall + accelerate).
			if _phase_time < 1.5:
				return false
			_check(bool(_player.call("is_on_floor")),
				"sprint measurement ran grounded")
			_steady_speed = _hspeed()
			_check(_steady_speed >= FLOOR_SPRINT,
				"measured sprint speed %.2f >= floor %.2f (baseline %.2f)" % [_steady_speed, FLOOR_SPRINT, BASE_SPRINT])
			var cross := 50.0 / maxf(_steady_speed, 0.001)
			_check(cross <= FLOOR_CROSS_50M,
				"50 m cross-time %.2f s <= %.2f s (baseline %.2f s)" % [cross, FLOOR_CROSS_50M, 50.0 / BASE_SPRINT])
			print("VERIFY(feel): steady sprint %.2f m/s, 50 m cross-time %.2f s" % [_steady_speed, cross])
			_release_all()
			# Slide setup: sprint again, then crouch-tap once at speed.
			_player.position = Vector3(0.0, 2.0, 30.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			Input.action_press("move_forward", 1.0)
			Input.action_press("sprint", 1.0)
			_slide_started = false
			_slide_dist = 0.0
			_crouch_attempts = 0
			_crouch_pressed_time = -1.0
			_phase = 3
			_frames = 0
		3:
			if _player.get("_sliding") == true:
				if not _slide_started:
					_slide_started = true
					_slide_start = _player.position
			elif _slide_started:
				_slide_dist = Vector2(_player.position.x - _slide_start.x,
					_player.position.z - _slide_start.z).length()
				_check(_slide_dist > FLOOR_SLIDE_DIST,
					"slide distance %.2f m > floor %.2f m (pre-Feel ~1.7 m)" % [_slide_dist, FLOOR_SLIDE_DIST])
				_release_all()
				_player.call("_end_wallrun")
				_phase = 4
				_frames = 0
				return false
			else:
				# Not sliding yet: once up to speed and grounded, tap crouch.
				# (One retry if the first just-press was consumed.)
				# SLIDE_MIN_SPEED is 5.0 shipped: press only above it.
				if _hspeed() >= 5.5 and bool(_player.call("is_on_floor")):
					if _crouch_pressed_time < 0.0 or (_phase_time - _crouch_pressed_time > 0.35 and _crouch_attempts < 2):
						Input.action_press("crouch", 1.0)
						_crouch_pressed_time = _phase_time
						_crouch_attempts += 1
			if _phase_time > 6.0:
				_check(false,
					"slide triggered and ended within 6 s (sliding=%s, started=%s, attempts=%d)" % [_player.get("_sliding"), _slide_started, _crouch_attempts])
				_release_all()
				_player.call("_end_wallrun")
				_phase = 4
				_frames = 0
		4:
			# Wall-run setup: airborne, sprint-speed entry beside the wall.
			_player.position = Vector3(0.0, 2.0, 5.0)
			_player.velocity = Vector3(0.0, 0.0, -_sprint_const)
			_player.rotation = Vector3.ZERO
			_player.call("_end_wallrun")
			Input.action_press("move_forward", 1.0)
			_wall_started = false
			_wall_dist = 0.0
			_phase = 5
			_frames = 0
		5:
			if _player.get("_wallrunning") == true:
				if not _wall_started:
					_wall_started = true
					_wall_start = _player.position
			elif _wall_started:
				_wall_dist = Vector2(_player.position.x - _wall_start.x,
					_player.position.z - _wall_start.z).length()
				_check(_wall_dist >= FLOOR_WALLRUN_DIST,
					"wall-run distance %.2f m >= floor %.2f m (pre-Feel ~14.2 m)" % [_wall_dist, FLOOR_WALLRUN_DIST])
				_release_all()
				_player.call("_end_wallrun")
				_phase = 6
				_frames = 0
				return false
			if _phase_time > 6.0:
				_check(false,
					"wall-run triggered and ended within 6 s (started=%s)" % _wall_started)
				_release_all()
				_player.call("_end_wallrun")
				_phase = 6
				_frames = 0
		6:
			# Grapple DIRECT setup: slow player, aim near-straight-up.
			_player.position = Vector3(0.0, 4.0, 0.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			_player.get_node("Head").rotation.x = 1.35
			_player.get("grapple").call("release")
			_grapple_max_speed = 0.0
			_grapple_direct_ok = false
			_phase = 7
			_frames = 0
		7:
			if _phase_time < 0.1:
				return false
			if not _phase_fired:
				_phase_fired = true
				var grapple = _player.get("grapple")
				var fired: bool = grapple.call("fire")
				_check(fired, "grapple fires at the ceiling (DIRECT test)")
				if fired:
					_check(grapple.get("_mode") == MODE_DIRECT,
						"near-vertical anchor + slow player yields DIRECT (mode %d)" % grapple.get("_mode"))
					_grapple_direct_ok = grapple.get("_mode") == MODE_DIRECT
			var grapple2 = _player.get("grapple")
			_grapple_max_speed = maxf(_grapple_max_speed, _player.velocity.length())
			if grapple2.get("_active") == false:
				_check(_grapple_direct_ok, "DIRECT grapple completed (anchor reached, released)")
				_check(_grapple_max_speed >= FLOOR_GRAPPLE_DIRECT_SPEED,
					"DIRECT grapple peak speed %.2f >= %.2f (baseline cap %.2f)" % [_grapple_max_speed, FLOOR_GRAPPLE_DIRECT_SPEED, BASE_GRAPPLE_MAX_SPEED])
				_player.get_node("Head").rotation.x = 0.0
				_phase = 8
				_frames = 0
				return false
			if _phase_time > 5.0:
				_check(false,
					"DIRECT grapple released within 5 s (active=%s, peak %.2f)" % [grapple2.get("_active"), _grapple_max_speed])
				grapple2.call("release")
				_player.get_node("Head").rotation.x = 0.0
				_phase = 8
				_frames = 0
		8:
			# Grapple PENDULUM regression (v0.6 behavior must survive Feel):
			# side/ahead anchor -> PENDULUM, not DIRECT.
			_player.position = Vector3(-2.0, 4.0, 0.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3(0, -PI / 2.0, 0)
			_player.get_node("Head").rotation.x = 0.0
			_player.get("grapple").call("release")
			_phase = 9
			_frames = 0
		9:
			if _phase_time < 0.1:
				return false
			if _phase_fired:
				return false
			_phase_fired = true
			var grapple = _player.get("grapple")
			var fired: bool = grapple.call("fire")
			_check(fired, "grapple fires at the side wall (PENDULUM test)")
			if fired:
				_check(grapple.get("_mode") == MODE_PENDULUM,
					"side/ahead anchor still yields PENDULUM (mode %d)" % grapple.get("_mode"))
			grapple.call("release")
			_check_recoil()
			_phase = 10
			_frames = 0
		10:
			_check_hitmarker()
			_phase = 11
			_frames = 0
		11:
			_check_flinch()
			_phase = 12
			_frames = 0
		12:
			# MOMENTUM 1+2: jump at full sprint keeps >=95% hspeed at
			# apex, and sprint persists across the jump + landing.
			if _phase_time < 0.1 and not _phase_fired:
				_phase_fired = true
				_player.position = Vector3(0.0, 2.0, 30.0)
				_player.velocity = Vector3.ZERO
				_player.rotation = Vector3.ZERO
				_player.call("_end_wallrun")
				Input.action_press("move_forward", 1.0)
				Input.action_press("sprint", 1.0)
				_mom_airborne = false
				_mom_apex_checked = false
				_mom_land_time = -1.0
				_mom_min_air = 1e9
				_mom_jump_speed = 0.0
			if not _mom_airborne:
				if _hspeed() >= 10.5 and bool(_player.call("is_on_floor")):
					_mom_jump_speed = _hspeed()
					_mom_min_air = _mom_jump_speed
					Input.action_press("jump", 1.0)
				if not bool(_player.call("is_on_floor")) and _mom_jump_speed > 0.0:
					_mom_airborne = true
					Input.action_release("jump")
				if _phase_time > 6.0:
					_check(false, "momentum: reached sprint + jumped within 6 s")
					_release_all()
					_phase = 13
					_frames = 0
				return false
			if not _mom_apex_checked:
				_mom_min_air = minf(_mom_min_air, _hspeed())
				if _player.velocity.y <= 0.0:
					_mom_apex_checked = true
					_check(_mom_min_air >= 0.95 * _mom_jump_speed,
						"jump keeps momentum: min airborne hspeed %.2f >= 95%% of jump speed %.2f" % [_mom_min_air, _mom_jump_speed])
				elif _phase_time > 8.0:
					_check(false, "momentum: apex reached within 8 s")
					_release_all()
					_phase = 13
					_frames = 0
				return false
			# After apex: wait for landing + 0.25 s, then sprint must persist.
			if bool(_player.call("is_on_floor")):
				if _mom_land_time < 0.0:
					_mom_land_time = _phase_time
				elif _phase_time - _mom_land_time >= 0.25:
					_check(_player.get("_sprinting") == true,
						"sprint persists across jump + landing (sprinting flag still true)")
					_check(_hspeed() >= 0.9 * _sprint_const,
						"sprint speed resumes on landing: %.2f >= 90%% of %.2f" % [_hspeed(), _sprint_const])
					_release_all()
					_phase = 13
					_frames = 0
			elif _phase_time > 10.0:
				_check(false, "momentum: landed within 10 s after jump")
				_release_all()
				_phase = 13
				_frames = 0
		13:
			# MOMENTUM 3a: crouch-land setup — airborne at sprint speed,
			# crouch pressed mid-air; landing must enter a slide.
			if _phase_time < 0.1 and not _phase_fired:
				_phase_fired = true
				_player.position = Vector3(0.0, 2.0, 30.0)
				_player.velocity = Vector3(0.0, 0.0, -_sprint_const)
				_player.rotation = Vector3.ZERO
				_player.call("_end_wallrun")
				Input.action_press("move_forward", 1.0)
				Input.action_press("sprint", 1.0)
				_mom_crouch_pressed = false
				_mom_land_time = -1.0
				_mom_land_speed = 0.0
			if not _mom_crouch_pressed and _phase_time > 0.15:
				# Press crouch once airborne (avoids the stale
				# is_on_floor() on the teleport frame entering a slide
				# before the fall).
				_mom_crouch_pressed = true
				Input.action_press("crouch", 1.0)
			if bool(_player.call("is_on_floor")) and _player.get("_sliding") == true:
				_mom_land_speed = _hspeed()
				_mom_land_time = _phase_time
				_phase = 14
				_frames = 0
			elif _phase_time > 5.0:
				_check(false, "crouch-land: slide entered on landing within 5 s (sliding=%s, speed=%.2f)" % [_player.get("_sliding"), _hspeed()])
				_release_all()
				_phase = 15
				_frames = 0
		14:
			# MOMENTUM 3b: 0.2 s after a crouch-landing slide starts,
			# speed must still be >= 80% of landing speed.
			if _phase_time >= 0.2:
				_check(_hspeed() >= 0.8 * _mom_land_speed,
					"crouch-land slide keeps speed: %.2f >= 80%% of landing %.2f after 0.2 s" % [_hspeed(), _mom_land_speed])
				_check(_player.get("_sliding") == true,
					"crouch-land slide still sliding 0.2 s after landing")
				_release_all()
				_player.call("_end_wallrun")
				_phase = 15
				_frames = 0
			elif _phase_time > 5.0:
				_check(false, "crouch-land: 0.2 s retention window reached")
				_release_all()
				_phase = 15
				_frames = 0
		15:
			# MOMENTUM 3c: low-speed crouch-land — crouch held, slow
			# landing -> normal crouch, NOT a slide.
			if _phase_time < 0.1 and not _phase_fired:
				_phase_fired = true
				_player.position = Vector3(0.0, 2.0, 30.0)
				_player.velocity = Vector3(0.0, 0.0, -2.0)
				_player.rotation = Vector3.ZERO
				_player.call("_end_wallrun")
				Input.action_press("crouch", 1.0)
				_mom_airborne = false
				_mom_land_time = -1.0
			if not bool(_player.call("is_on_floor")):
				_mom_airborne = true
			elif _mom_airborne:
				if _mom_land_time < 0.0:
					_mom_land_time = _phase_time
				elif _phase_time - _mom_land_time >= 0.3:
					_check(_player.get("_sliding") == false,
						"low-speed crouch-land does NOT slide (speed was 2.0 < SLIDE_MIN_SPEED)")
					_check(_player.get("_crouching") == true,
						"low-speed crouch-land is a normal crouch (crouching flag true)")
					_release_all()
					_phase = 16
					_frames = 0
			elif _phase_time > 5.0:
				_check(false, "low-speed crouch-land: landed within 5 s")
				_release_all()
				_phase = 16
				_frames = 0
		16:
			# MOMENTUM 4: slide-hop — jumping while sliding must
			# preserve slide velocity (old code multiplied it by 0.8).
			if _phase_time < 0.1 and not _phase_fired:
				_phase_fired = true
				_player.position = Vector3(0.0, 2.0, 30.0)
				_player.velocity = Vector3.ZERO
				_player.rotation = Vector3.ZERO
				_player.call("_end_wallrun")
				Input.action_press("move_forward", 1.0)
				Input.action_press("sprint", 1.0)
				_mom_slide_speed = 0.0
				_mom_slide_min_air = 1e9
				_mom_slide_airborne = false
				_mom_hop_checked = false
				_crouch_attempts = 0
				_crouch_pressed_time = -1.0
			if not _mom_slide_airborne:
				if _player.get("_sliding") == true:
					if _mom_slide_speed <= 0.0:
						_mom_slide_speed = _hspeed()
						_mom_slide_min_air = _mom_slide_speed
						Input.action_press("jump", 1.0)
				elif _hspeed() >= 5.5 and bool(_player.call("is_on_floor")):
					if _crouch_pressed_time < 0.0 or (_phase_time - _crouch_pressed_time > 0.35 and _crouch_attempts < 2):
						Input.action_press("crouch", 1.0)
						_crouch_pressed_time = _phase_time
						_crouch_attempts += 1
				if not bool(_player.call("is_on_floor")) and _mom_slide_speed > 0.0:
					_mom_slide_airborne = true
					Input.action_release("jump")
					Input.action_release("crouch")
				if _phase_time > 6.0:
					_check(false, "slide-hop: sliding + jumped within 6 s (sliding=%s)" % _player.get("_sliding"))
					_release_all()
					_phase = 17
					_frames = 0
				return false
			if not _mom_hop_checked:
				_mom_slide_min_air = minf(_mom_slide_min_air, _hspeed())
				if _player.velocity.y <= 0.0:
					_mom_hop_checked = true
					_check(_mom_slide_min_air >= 0.95 * _mom_slide_speed,
						"slide-hop keeps velocity: min airborne hspeed %.2f >= 95%% of slide speed %.2f" % [_mom_slide_min_air, _mom_slide_speed])
					_check(_player.get("_sliding") == false,
						"slide-hop exits the slide")
					_release_all()
					_phase = 17
					_frames = 0
				elif _phase_time > 8.0:
					_check(false, "slide-hop: apex reached within 8 s")
					_release_all()
					_phase = 17
					_frames = 0
		17:
			print("VERIFY(feel): %d passed, %d failed" % [_passes, _fails])
			if _fails == 0:
				print("VERIFY(feel): ALL CHECKS PASSED")
			else:
				printerr("VERIFY(feel): %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


func _check_constants() -> void:
	var p := _cmap("res://scripts/player/player.gd")
	var g := _cmap("res://scripts/player/grapple_hook.gd")
	var w := _cmap("res://scripts/weapons/weapon_base.gd")
	var e := _cmap("res://scripts/enemies/enemy_base.gd")
	var t := _cmap("res://scripts/core/tuning.gd")
	# --- Movement: faster than pre-Feel baselines. ---
	_sprint_const = float(p.get("SPRINT_SPEED", 0.0))
	_check(_sprint_const >= FLOOR_SPRINT,
		"SPRINT_SPEED %.2f >= floor %.2f (baseline %.2f)" % [_sprint_const, FLOOR_SPRINT, BASE_SPRINT])
	_check(float(p.get("WALK_SPEED", 0.0)) >= BASE_WALK,
		"WALK_SPEED %.2f not slower than baseline %.2f" % [float(p.get("WALK_SPEED", 0.0)), BASE_WALK])
	_check(float(p.get("ACCEL_GROUND", 0.0)) >= 40.0,
		"ACCEL_GROUND %.1f not slower than baseline 40.0 (snappier or equal)" % float(p.get("ACCEL_GROUND", 0.0)))
	# Slide: lower friction + lower end speed = longer glide. MAX_TIME
	# 3.0 -> 2.5 is a deliberate trade (entry speed 6.4 -> 11.0); the live
	# slide-distance check below is the metric that proves it is up.
	_check(float(p.get("SLIDE_MAX_TIME", 0.0)) > 0.0,
		"SLIDE_MAX_TIME %.2f > 0 (slide has a real glide window)" % float(p.get("SLIDE_MAX_TIME", 0.0)))
	_check(float(p.get("SLIDE_FRICTION", 0.0)) <= BASE_SLIDE_FRICTION,
		"SLIDE_FRICTION %.2f <= baseline %.2f (less drag, longer glide)" % [float(p.get("SLIDE_FRICTION", 0.0)), BASE_SLIDE_FRICTION])
	_check(float(p.get("SLIDE_END_SPEED", 0.0)) <= BASE_SLIDE_END_SPEED,
		"SLIDE_END_SPEED %.2f <= baseline %.2f" % [float(p.get("SLIDE_END_SPEED", 0.0)), BASE_SLIDE_END_SPEED])
	# Wall-run: longer + bigger boost. MIN_SPEED 3.0 -> 4.0 is a deliberate
	# trade — the invariant is that a sprint-speed entry still clears it.
	_check(float(p.get("WALLRUN_MAX_TIME", 0.0)) >= BASE_WALLRUN_TIME,
		"WALLRUN_MAX_TIME %.2f >= baseline %.2f" % [float(p.get("WALLRUN_MAX_TIME", 0.0)), BASE_WALLRUN_TIME])
	_check(float(p.get("WALLRUN_ENTRY_BOOST", 0.0)) >= BASE_WALLRUN_BOOST,
		"WALLRUN_ENTRY_BOOST %.2f >= baseline %.2f" % [float(p.get("WALLRUN_ENTRY_BOOST", 0.0)), BASE_WALLRUN_BOOST])
	_check(float(p.get("WALLRUN_MIN_SPEED", 0.0)) < _sprint_const,
		"WALLRUN_MIN_SPEED %.2f < SPRINT_SPEED %.2f (sprint entry clears it)" % [float(p.get("WALLRUN_MIN_SPEED", 0.0)), _sprint_const])
	# Grapple: at least one knob strictly faster + none regressed.
	var g_accel := float(g.get("PULL_ACCEL", 0.0))
	var g_max := float(g.get("PULL_MAX_SPEED", 0.0))
	var g_reel := float(g.get("REEL_SPEED", 0.0))
	var g_range := float(g.get("FIRE_RANGE", 0.0))
	_check(g_accel > BASE_GRAPPLE_ACCEL or g_max > BASE_GRAPPLE_MAX_SPEED
			or g_reel > BASE_GRAPPLE_REEL or g_range > BASE_GRAPPLE_RANGE,
		"grapple is FASTER: at least one knob up (accel %.1f / max %.1f / reel %.1f / range %.1f vs %.1f / %.1f / %.1f / %.1f)" % [g_accel, g_max, g_reel, g_range, BASE_GRAPPLE_ACCEL, BASE_GRAPPLE_MAX_SPEED, BASE_GRAPPLE_REEL, BASE_GRAPPLE_RANGE])
	_check(g_accel >= BASE_GRAPPLE_ACCEL,
		"grapple PULL_ACCEL %.1f not slower than baseline %.1f" % [g_accel, BASE_GRAPPLE_ACCEL])
	_check(g_max >= BASE_GRAPPLE_MAX_SPEED,
		"grapple PULL_MAX_SPEED %.1f not slower than baseline %.1f" % [g_max, BASE_GRAPPLE_MAX_SPEED])
	_check(g_reel >= BASE_GRAPPLE_REEL,
		"grapple REEL_SPEED %.1f not slower than baseline %.1f" % [g_reel, BASE_GRAPPLE_REEL])
	_check(g_range >= BASE_GRAPPLE_RANGE,
		"grapple FIRE_RANGE %.1f not shorter than baseline %.1f" % [g_range, BASE_GRAPPLE_RANGE])
	# Tuning mirror (warn-only: live values live in player.gd).
	_warn(is_equal_approx(float(t.get("PLAYER_SPRINT_SPEED", -1.0)), _sprint_const),
		"Tuning.PLAYER_SPRINT_SPEED mirrors player.gd SPRINT_SPEED (%.2f)" % float(t.get("PLAYER_SPRINT_SPEED", -1.0)))
	# --- Gunfeel constants. ---
	_check(float(w.get("RECOIL_RECOVER_TIME", 0.0)) > 0.0
			and float(w.get("RECOIL_RECOVER_TIME", 0.0)) <= 0.5,
		"RECOIL_RECOVER_TIME %.2f in (0, 0.5] (recoil recovers, snappy)" % float(w.get("RECOIL_RECOVER_TIME", 0.0)))
	_check(float(e.get("FLINCH_TIME", 0.0)) > 0.0,
		"FLINCH_TIME %.2f > 0 (enemies stagger on hit)" % float(e.get("FLINCH_TIME", 0.0)))
	_check(float(e.get("FLINCH_KNOCKBACK", 0.0)) > 0.0,
		"FLINCH_KNOCKBACK %.2f > 0 (hits shove enemies)" % float(e.get("FLINCH_KNOCKBACK", 0.0)))
	_check_recoil_patterns()


func _check_recoil_patterns() -> void:
	# Game scripts are loaded dynamically (class_name .new() does not
	# resolve in --script mode; see verify_v07_mods.gd).
	var arsenal_script := load("res://scripts/weapons/arsenal.gd") as GDScript
	var weapons: Dictionary = (arsenal_script.get_script_constant_map().get("WEAPONS", {}) as Dictionary)
	var seen: Array = []
	var checked := 0
	for id in weapons.keys():
		if str(id) == "raptor":
			continue  # melee thrower: no recoil pattern by design
		var stats: Dictionary = weapons[id]
		var pat: Array = stats.get("recoil_pattern", [])
		_check(not pat.is_empty(),
			"%s has a non-empty recoil_pattern" % str(id))
		var all_pitch_up := true
		for entry in pat:
			if not (entry is Vector2) or entry.y <= 0.0 or absf(entry.x) >= 0.05:
				all_pitch_up = false
		_check(all_pitch_up,
			"%s recoil_pattern is all pitch-up entries (|yaw| < 0.05, pitch > 0)" % str(id))
		# Per-weapon recovery exists (Worker B: recoil_recover in Arsenal).
		_check(float(stats.get("recoil_recover", -1.0)) > 0.0,
			"%s has a per-weapon recoil_recover (%.2f)" % [str(id), float(stats.get("recoil_recover", -1.0))])
		if not seen.has(str(pat)):
			seen.append(str(pat))
		checked += 1
	_check(checked >= 5,
		"checked recoil patterns for %d guns (expected >= 5 non-raptor)" % checked)
	_check(seen.size() >= 3,
		"recoil curves are per-weapon: %d distinct patterns across %d guns" % [seen.size(), checked])


func _check_recoil() -> void:
	# Behavioral: firing applies a kick that HOLDS during the settle
	# delay, then decays exponentially; ADS kicks less; the viewmodel
	# punches in sync. (Deep coverage lives in verify_g1_gunfeel.gd.)
	var arsenal_script := load("res://scripts/weapons/arsenal.gd") as GDScript
	var cam: Camera3D = _player.get("camera")
	var w_hip: Node3D = arsenal_script.call("make_weapon", "ar7")
	w_hip.call("attach", _player, cam)
	root.add_child(w_hip)
	w_hip.set("_raise_t", 999.0)
	w_hip.call("_apply_recoil")
	var hip_debt: Vector2 = w_hip.get("_recoil_debt")
	_check(hip_debt.length() > 0.0,
		"firing applies a recoil kick (debt %s)" % hip_debt)
	_check(w_hip.get("_shot_index") == 1,
		"firing advances the recoil pattern index")
	_check(float(w_hip.get("_recoil_settle_t")) > 0.0,
		"kick HOLDS during the settle delay (settle_t %.3f)" % float(w_hip.get("_recoil_settle_t")))
	_check(float(w_hip.get("_vm_kick_z")) > 0.0 and float(w_hip.get("_vm_kick_pitch")) > 0.0,
		"viewmodel punches with the kick (z %.4f pitch %.4f)" % [float(w_hip.get("_vm_kick_z")), float(w_hip.get("_vm_kick_pitch"))])
	# Recovery HOLDS during settle: one tick inside the delay changes nothing.
	w_hip.call("_recover_recoil", 0.016)
	_check((w_hip.get("_recoil_debt") as Vector2).is_equal_approx(hip_debt),
		"recoil debt unchanged during settle delay")
	# After settle, exponential decay bleeds it to ~0.
	for i in 60:
		w_hip.call("_recover_recoil", 0.016)
	_check((w_hip.get("_recoil_debt") as Vector2).length() < 0.001,
		"recoil recovers to ~0 after settle + decay (got %.5f)" % (w_hip.get("_recoil_debt") as Vector2).length())
	var w_ads: Node3D = arsenal_script.call("make_weapon", "ar7")
	w_ads.call("attach", _player, cam)
	root.add_child(w_ads)
	w_ads.set("_raise_t", 999.0)
	w_ads.call("set_ads", true)
	w_ads.call("_apply_recoil")
	var ads_debt: Vector2 = w_ads.get("_recoil_debt")
	_check(ads_debt.length() < hip_debt.length() * 0.9,
		"ADS recoil (%.4f) < hip recoil (%.4f) — ADS steadies the gun" % [ads_debt.length(), hip_debt.length()])
	w_hip.queue_free()
	w_ads.queue_free()


func _check_hitmarker() -> void:
	# Wiring: WeaponBase._notify_hit must reach the HUD (group "hud").
	var arsenal_script := load("res://scripts/weapons/arsenal.gd") as GDScript
	var w: Node3D = arsenal_script.call("make_weapon", "ar7")
	w.call("attach", _player, _player.get("camera"))
	root.add_child(w)
	_fake_hud.calls.clear()
	var target := FakeTarget.new()
	w.call("_notify_hit", target, false)
	_check(_fake_hud.calls.size() == 1 and _fake_hud.calls[0]["killed"] == false
			and _fake_hud.calls[0]["headshot"] == false,
		"hitmarker fires on a plain hit (killed=false, headshot=false)")
	target.dead = true
	w.call("_notify_hit", target, false)
	_check(_fake_hud.calls.size() == 2 and _fake_hud.calls[1]["killed"] == true,
		"hitmarker fires the kill variant when the target dies")
	target.dead = false
	w.call("_notify_hit", target, true)
	_check(_fake_hud.calls.size() == 3 and _fake_hud.calls[2]["headshot"] == true,
		"hitmarker fires the headshot variant on a headshot")
	w.queue_free()
	# Real HUD: show_hitmarker arms the marker timer.
	var hud_script := load("res://scripts/ui/hud.gd") as GDScript
	var hud: CanvasLayer = hud_script.new()
	root.add_child(hud)
	hud.call("show_hitmarker", false, false)
	_check(float(hud.get("_hit_t")) > 0.0,
		"real HUD show_hitmarker arms the hitmarker timer (_hit_t %.2f)" % float(hud.get("_hit_t")))
	hud.queue_free()


func _check_flinch() -> void:
	# Damage-scaled hit reactions (Worker B): flinch time grows with
	# damage, headshots flinch longer, heavier enemies shove less, the
	# brute stays immune. Deep coverage: verify_g1_gunfeel.gd.
	var enemy_script := load("res://scripts/enemies/enemy_base.gd") as GDScript
	var grunt_script := load("res://scripts/enemies/grunt.gd") as GDScript
	var brute_script := load("res://scripts/enemies/brute.gd") as GDScript
	_check(float(enemy_script.call("flinch_time_for", 120.0, false)) > float(enemy_script.call("flinch_time_for", 25.0, false))
			and float(enemy_script.call("flinch_time_for", 25.0, false)) > float(enemy_script.call("flinch_time_for", 12.0, false)),
		"flinch scales with damage: sniper > AR > pellet")
	_check(float(enemy_script.call("flinch_time_for", 25.0, true)) > float(enemy_script.call("flinch_time_for", 25.0, false)),
		"headshot flinch > body flinch for the same damage")
	_check(float(enemy_script.call("knockback_for", 25.0, 60.0, false, 0.0)) > float(enemy_script.call("knockback_for", 25.0, 100.0, false, 0.0)),
		"lighter enemy shoved further than heavier one for the same hit")
	# Live grunt: an AR hit flinches + knocks back + costs exact HP.
	var grunt: CharacterBody3D = grunt_script.new()
	root.add_child(grunt)
	grunt.call("activate", Vector3(0.0, 0.5, -10.0), 1, {})
	var hp_before: float = grunt.get("hp")
	grunt.call("take_damage", 25.0, Vector3(0.0, 0.5, -8.0), false)
	_check(bool(grunt.call("is_flinching")),
		"grunt flinches on a non-lethal AR hit")
	_check(is_equal_approx(float(grunt.get("last_hit_flinch")), float(enemy_script.call("flinch_time_for", 25.0, false))),
		"grunt flinch duration matches the scaled value (%.3f)" % float(grunt.get("last_hit_flinch")))
	_check((grunt.get("velocity") as Vector3).length() > 0.0,
		"grunt is knocked back by the hit")
	_check(is_equal_approx(float(grunt.get("hp")), hp_before - 25.0),
		"grunt HP drops by exactly the hit amount (no balance change)")
	# Brute: immune to flinch/knockback (design preserved).
	var brute: CharacterBody3D = brute_script.new()
	root.add_child(brute)
	brute.call("activate", Vector3(5.0, 0.5, -10.0), 5, {})
	brute.call("take_damage", 120.0, Vector3(5.0, 0.5, -8.0), true)
	_check(not bool(brute.call("is_flinching")),
		"brute stays flinch-immune on a 120-damage headshot")
	_check((brute.get("velocity") as Vector3).length() < 0.001,
		"brute takes no knockback")
	grunt.queue_free()
	brute.queue_free()
