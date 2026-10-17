# verify_v06_movement.gd — headless functional checks for FORGEFALL v0.6.0
# movement work (WORKER A: wall-run + grapple pendulum).
# Usage: godot --headless --path <project> --script res://tools/verify_v06_movement.gd
# Checks, in a minimal scene (player + one wall + one ceiling):
#   1. WALL-RUN: airborne, fast player beside a wall enters wall-run, keeps
#      |vy| small (< 1.0) over several physics frames, and still moves
#      forward along the wall (no more climbing).
#   2. GRAPPLE MODE: a side/ahead anchor (high but far off vertical) yields
#      PENDULUM, not DIRECT; a near-vertical anchor with a slow player
#      still yields DIRECT.
#   3. SWING PUMPING: while PENDULUM, apply_grapple() with wish builds
#      more tangential speed than the same calls with no wish, and the
#      rope constraint still kills outward (stretching) radial velocity.
#   4. RELEASE: grapple release() preserves the player's velocity.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

# GrappleHook.Mode enum: IDLE = 0, DIRECT = 1, PENDULUM = 2.
const MODE_DIRECT := 1
const MODE_PENDULUM := 2

var _fails := 0
var _frames := 0
var _phase := 0
var _player: Node = null
var _max_abs_vy := 0.0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	var arena := Node3D.new()
	arena.name = "VerifyArena"
	root.add_child(arena)
	# Wall: face at x = 0.5 (same as verify_fixes.gd).
	var wall := StaticBody3D.new()
	wall.name = "Wall"
	var wshape := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(1.0, 6.0, 30.0)
	wshape.shape = wbox
	wall.add_child(wshape)
	wall.position = Vector3(1.0, 3.0, 0.0)
	arena.add_child(wall)
	# Ceiling: underside at y = 6.0, for the near-vertical anchor test.
	var ceil_body := StaticBody3D.new()
	ceil_body.name = "Ceiling"
	var cshape := CollisionShape3D.new()
	var cbox := BoxShape3D.new()
	cbox.size = Vector3(10.0, 1.0, 10.0)
	cshape.shape = cbox
	ceil_body.add_child(cshape)
	ceil_body.position = Vector3(0.0, 6.5, 0.0)
	arena.add_child(ceil_body)
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	_phase = 1
	print("VERIFY(v0.6 movement): arena built, waiting for _ready + physics")


func _tangential_speed(anchor: Vector3) -> float:
	var to_p: Vector3 = (_player.global_position + Vector3(0.0, 1.0, 0.0)) - anchor
	var dist := to_p.length()
	if dist < 0.001:
		return 0.0
	var radial := to_p / dist
	var vel: Vector3 = _player.velocity
	return (vel - radial * vel.dot(radial)).length()


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 5:
				return false
			# --- Wall-run setup: airborne, fast, beside the wall. ---
			# Entry speed 7.0: above the Gameplay Rework attach minimum
			# (full walk speed 6.0).
			_player.position = Vector3(0.0, 2.0, 5.0)
			_player.velocity = Vector3(0.0, 0.0, -7.0)
			_player.rotation = Vector3.ZERO
			_player.call("_end_wallrun")
			Input.action_press("move_forward", 1.0)
			_max_abs_vy = 0.0
			_phase = 2
			_frames = 0
		2:
			_max_abs_vy = maxf(_max_abs_vy, absf(_player.velocity.y))
			if _frames < 10:
				return false
			_check(_player.get("_wallrunning") == true,
				"wall-run triggers beside a wall")
			_check(_max_abs_vy < 1.0,
				"wall-run keeps |vy| small (max %.2f < 1.0, no climbing)" % _max_abs_vy)
			_check(_player.velocity.z < -2.0,
				"wall-run still moves forward along the wall (vz %.2f)" % _player.velocity.z)
			_check(_player.position.z < 5.0,
				"wall-run advanced forward (z %.2f < 5.0)" % _player.position.z)
			Input.action_release("move_forward")
			_player.call("_end_wallrun")
			_phase = 3
			_frames = 0
		3:
			# --- Side/ahead grapple setup: slow player, anchor high but
			# far off vertical -> must be PENDULUM, not DIRECT. ---
			_player.position = Vector3(-2.0, 4.0, 0.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3(0, -PI / 2.0, 0)  # face +X, toward wall
			_player.get_node("Head").rotation.x = 0.0
			_player.get("grapple").call("release")
			_phase = 4
			_frames = 0
		4:
			if _frames < 1:
				return false
			var grapple = _player.get("grapple")
			var fired: bool = grapple.call("fire")
			_check(fired, "grapple fires at the side wall")
			if fired:
				_check(grapple.get("_mode") == MODE_PENDULUM,
					"side/ahead anchor yields PENDULUM, not DIRECT (mode %d)" % grapple.get("_mode"))
			grapple.call("release")
			_phase = 5
			_frames = 0
		5:
			# --- Near-vertical grapple setup: slow player, aim at the
			# ceiling almost straight up -> must still be DIRECT. ---
			_player.position = Vector3(0.0, 4.0, 0.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			_player.get_node("Head").rotation.x = 1.35  # ~77 deg up
			_player.get("grapple").call("release")
			_phase = 6
			_frames = 0
		6:
			if _frames < 1:
				return false
			var grapple = _player.get("grapple")
			var fired: bool = grapple.call("fire")
			_check(fired, "grapple fires at the ceiling")
			if fired:
				_check(grapple.get("_mode") == MODE_DIRECT,
					"near-vertical anchor + slow player yields DIRECT (mode %d)" % grapple.get("_mode"))
			grapple.call("release")
			_player.get_node("Head").rotation.x = 0.0
			_phase = 7
		7:
			# --- Swing pumping, direct apply_grapple comparison. ---
			# Rope straight up (anchor above player), slack rope so the
			# constraint does not interfere with the pumping measurement.
			_player.position = Vector3(0.0, 4.0, 0.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			var grapple = _player.get("grapple")
			var anchor := Vector3(0.0, 8.0, 0.0)
			grapple.set("_active", true)
			grapple.set("_mode", MODE_PENDULUM)
			grapple.set("_anchor", anchor)
			grapple.set("_rope_len", 10.0)
			var vel_no_wish := Vector3(3.0, 0.0, 0.0)
			var vel_wish := Vector3(3.0, 0.0, 0.0)
			var wish := Vector3(0.0, 0.0, -1.0)  # fully tangential to a vertical rope
			for i in 60:
				vel_no_wish = grapple.call("apply_grapple", 1.0 / 60.0, vel_no_wish, Vector3.ZERO)
				vel_wish = grapple.call("apply_grapple", 1.0 / 60.0, vel_wish, wish)
			_player.velocity = vel_no_wish
			var tan_no_wish := _tangential_speed(anchor)
			_player.velocity = vel_wish
			var tan_wish := _tangential_speed(anchor)
			_check(tan_wish > tan_no_wish + 1.0,
				"PENDULUM wish pumping builds tangential speed (wish %.2f vs no-input %.2f)" % [tan_wish, tan_no_wish])
			# Rope constraint intact: taut rope + outward velocity must
			# lose its outward radial component (no rope stretching).
			grapple.set("_rope_len", 2.0)  # taut: dist is 3.0
			var vel_out := Vector3(0.0, -5.0, 0.0)  # straight away from anchor
			vel_out = grapple.call("apply_grapple", 1.0 / 60.0, vel_out, Vector3.ZERO)
			var radial: Vector3 = ((_player.global_position + Vector3(0.0, 1.0, 0.0)) - anchor).normalized()
			_check(vel_out.dot(radial) <= 0.001,
				"rope constraint still kills outward radial velocity (radial %.3f)" % vel_out.dot(radial))
			# Release preserves velocity.
			_player.velocity = Vector3(2.0, 3.0, 4.0)
			var before: Vector3 = _player.velocity
			grapple.call("release")
			_check(_player.velocity == before,
				"grapple release preserves velocity (%s)" % _player.velocity)
			_check(grapple.get("_active") == false,
				"grapple is inactive after release")
			_phase = 8
		8:
			if _fails == 0:
				print("VERIFY(v0.6 movement): ALL CHECKS PASSED")
			else:
				printerr("VERIFY(v0.6 movement): %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false
