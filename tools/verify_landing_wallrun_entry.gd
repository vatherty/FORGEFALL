# verify_landing_wallrun_entry.gd — headless verification for bug-bash
# BB-2 (landing momentum consistency) and BB-3 (wall-run entry reliability).
# Usage: godot --headless --path <project> --script res://tools/verify_landing_wallrun_entry.gd
#
# BB-2: the old ground model dragged velocity per-component toward
# wish*speed at ACCEL_GROUND, so a fast landing kept its speed only when
# the sprint latch happened to be on (target 11) and lost ~5 m/s in ~5
# frames when it was off (target 6). These checks land the player at
# sprint speed across fall speeds and input states and assert ONE
# uniform outcome per input state:
#   - sprint held: no speed loss at any fall speed.
#   - walk held: identical gentle overspeed bleed at every fall speed,
#     converging to walk speed (no snap).
#   - no input: uniform friction stop (diagonal == axial timing).
#   - crouch held: the landing slide still triggers and glides.
# BB-3: wall-run entry matrix (direct-call pattern, same as
# verify_movement_rework's negative cases). The corridor dead zone —
# velocity angled steeply toward the wall (~55 deg off the tangent)
# while looking along the corridor — attached under NEITHER old gate;
# it must attach now. Splat (near head-on, not aimed at the wall),
# drifting away, too-slow, and blocked-normal cases must still refuse.
# Plus: a wall-run survives a brief wish-input flicker (grace) but
# detaches when input stays gone.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _passes := 0
var _player: Node = null


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _release_all() -> void:
	for a in ["move_forward", "move_back", "move_left", "move_right",
			"sprint", "crouch", "jump", "ads"]:
		Input.action_release(a)


func _hs() -> float:
	return Vector2(_player.velocity.x, _player.velocity.z).length()


func _initialize() -> void:
	call_deferred("run")


func _mk_box(parent: Node, pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var s := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	s.shape = box
	b.add_child(s)
	b.position = pos
	parent.add_child(b)
	return b


## Land once with the given starting horizontal speed / fall speed /
## held inputs. Returns per-frame horizontal speeds starting at the
## touchdown frame (index 0), or an empty array on timeout.
func _land_case(hs: float, fall_v: float, vel_dir: Vector3, inputs: Array) -> Array:
	_release_all()
	_player.position = Vector3(0.0, 2.5, 30.0)
	_player.velocity = Vector3(vel_dir.x * hs, -fall_v, vel_dir.z * hs)
	_player.rotation = Vector3.ZERO
	_player.get_node("Head").rotation.x = 0.0
	_player.call("_end_wallrun")
	_player.set("_sliding", false)
	_player.set("_crouching", false)
	for inp in inputs:
		Input.action_press(inp)
	var air_frames := 0
	var samples: Array = []
	var frames := 0
	while frames < 400:
		await physics_frame
		frames += 1
		if samples.is_empty():
			if not _player.is_on_floor():
				air_frames += 1
			elif air_frames >= 3:
				samples.append(_hs())
		else:
			samples.append(_hs())
			if samples.size() >= 45:
				break
	_release_all()
	return samples


func _at(samples: Array, idx: int) -> float:
	return samples[idx] if samples.size() > idx else -1.0


## Measure the player's grounded sprint speed under the CURRENT
## loadout (the same player instance the landing cases use). Runs on
## a clear stretch of floor away from the wall and returns the speed
## once it plateaus (15 consecutive on-floor samples within 0.05).
## Returns 0.0 if no plateau is reached — callers must treat that as
## a broken measurement, never as a usable reference.
func _grounded_sprint_speed() -> float:
	_release_all()
	_player.position = Vector3(-20.0, 1.0, 30.0)
	_player.velocity = Vector3.ZERO
	_player.rotation = Vector3.ZERO
	_player.get_node("Head").rotation.x = 0.0
	_player.call("_end_wallrun")
	_player.set("_sliding", false)
	_player.set("_crouching", false)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	var window: Array = []
	var frames := 0
	var ref := 0.0
	while frames < 300:
		await physics_frame
		frames += 1
		if not _player.is_on_floor():
			continue
		window.append(_hs())
		if window.size() > 15:
			window.pop_front()
		if window.size() == 15 and window.max() - window.min() < 0.05:
			ref = _hs()
			break
	_release_all()
	return ref


func run() -> void:
	var arena := Node3D.new()
	arena.name = "VerifyArena"
	root.add_child(arena)
	_mk_box(arena, Vector3(0.0, -0.5, 0.0), Vector3(200.0, 1.0, 200.0))  # floor, top y=0
	# Wall: face at x = 0.5 (same geometry as the other movement verifies).
	_mk_box(arena, Vector3(1.0, 3.0, -10.0), Vector3(1.0, 6.0, 60.0))
	_player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	await physics_frame
	await physics_frame

	# ---------------- BB-2: landing consistency ----------------
	# A1: sprint held — no loss at any fall speed. The reference speed
	# is MEASURED under the current loadout, not hard-coded: BB-5
	# weapon weight scales top sprint speed (ar7: 11.0 x ~0.926), so
	# the invariant is "land at your loadout's real sprint speed and
	# keep it", within the suite's standing 0.6 m/s tolerance. The
	# guard check fails closed: a broken measurement must never turn
	# A1 into a vacuous pass. The frame-5 checkpoint matters as much
	# as frame-30: laden ground accel (~53 m/s^2) can repair a
	# one-frame touchdown cut within ~7 frames, so a late sample
	# alone cannot see momentum eaten at touchdown — preservation is
	# asserted from the first frames after contact onward.
	var sprint_ref := await _grounded_sprint_speed()
	_check(sprint_ref > 6.0,
		"BB-2 sprint reference: grounded sprint speed measured under current loadout (%.2f m/s)" % sprint_ref)
	for fv in [2.0, 10.0, 16.0]:
		var s := await _land_case(sprint_ref, fv, Vector3(0, 0, -1), ["move_forward", "sprint"])
		_check(s.size() >= 31 and _at(s, 5) >= sprint_ref - 0.6 and _at(s, 30) >= sprint_ref - 0.6,
			"BB-2 sprint landing (fall %.0f): speed kept, hs@5f = %.2f, hs@30f = %.2f (ref %.2f)" % [fv, _at(s, 5), _at(s, 30), sprint_ref])
	# A2: walk held — identical gentle bleed at every fall speed.
	var a2: Array = []
	for fv in [2.0, 10.0, 16.0]:
		a2.append(await _land_case(11.0, fv, Vector3(0, 0, -1), ["move_forward"]))
	var a2_12: Array = [_at(a2[0], 12), _at(a2[1], 12), _at(a2[2], 12)]
	_check(a2_12.max() - a2_12.min() <= 0.3,
		"BB-2 walk landing: hs@12f identical across fall speeds (%s)" % str(a2_12))
	_check(a2_12.min() >= 7.5,
		"BB-2 walk landing: no snap — hs@12f %.2f still well above walk 6.0" % a2_12.min())
	_check(_at(a2[0], 40) <= 6.6 and _at(a2[0], 40) >= 5.4,
		"BB-2 walk landing: converges to walk speed, hs@40f = %.2f" % _at(a2[0], 40))
	# A3: no input — friction stop, fast but not instant.
	var a3 := await _land_case(11.0, 10.0, Vector3(0, 0, -1), [])
	_check(_at(a3, 5) >= 5.0, "BB-2 no-input landing: not an instant stop, hs@5f = %.2f" % _at(a3, 5))
	_check(_at(a3, 18) <= 1.0, "BB-2 no-input landing: friction stops it, hs@18f = %.2f" % _at(a3, 18))
	# A4: no-input stop timing — diagonal matches axial (uniform friction).
	var stop_frames: Array = []
	for dir in [Vector3(0, 0, -1), Vector3(-0.7071, 0, -0.7071)]:
		var s := await _land_case(11.0, 10.0, dir, [])
		var n := -1
		for i in range(s.size()):
			if s[i] < 0.5:
				n = i
				break
		stop_frames.append(n)
	_check(stop_frames[0] > 0 and stop_frames[1] > 0 and abs(stop_frames[0] - stop_frames[1]) <= 3,
		"BB-2 no-input stop: diagonal == axial timing (%s frames)" % str(stop_frames))
	# A5: crouch-land slide regression — slide triggers and glides.
	var a5 := await _land_case(11.0, 10.0, Vector3(0, 0, -1), ["crouch"])
	_check(_player.get("_sliding") == true or _at(a5, 20) >= 8.5,
		"BB-2 crouch landing: slide path taken (sliding=%s)" % str(_player.get("_sliding")))
	_check(_at(a5, 20) >= 8.5,
		"BB-2 crouch landing: slide glides, hs@20f = %.2f" % _at(a5, 20))

	# ---------------- BB-3: wall-run entry matrix ----------------
	# Fresh player with physics process disabled (never move_and_slide,
	# so is_on_floor stays false) — the direct-call pattern.
	_player.queue_free()
	await physics_frame
	_player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	_player.name = "PlayerB"
	arena.add_child(_player)
	_player.set_physics_process(false)
	await physics_frame

	# angle_deg: velocity angle from the wall tangent (-Z) toward the
	# wall (+X). aim: "corridor" (-Z), "velocity", or "wall" (+X).
	var cases: Array = [
		[0.0, 8.0, "corridor", true, "parallel, looking along travel (regression)"],
		[30.0, 8.0, "corridor", true, "shallow diagonal, looking along corridor (regression)"],
		[55.0, 8.0, "corridor", true, "BB-3 dead zone: steep diagonal, looking along corridor"],
		[55.0, 8.0, "velocity", true, "steep diagonal, looking along velocity (aim gate)"],
		[80.0, 8.0, "corridor", false, "near head-on, NOT aimed at wall: splat stays closed"],
		[80.0, 8.0, "wall", true, "near head-on, aimed at wall: attaches"],
		[55.0, 5.0, "corridor", false, "steep diagonal but too slow (Colin speed spec)"],
		[-55.0, 8.0, "corridor", false, "steep diagonal DRIFTING AWAY: no attach"],
	]
	for c in cases:
		var attached := await _entry_attempt(c[0], c[1], c[2])
		_check(attached == c[3], "BB-3 entry: %s -> %s" % [c[4], "attach" if attached else "refused"])
	# Blocked normal (same wall just departed) still refuses.
	var blocked := await _entry_attempt(55.0, 8.0, "corridor", true)
	_check(not blocked, "BB-3 entry: departed wall's normal stays blocked (anti-cheese)")
	# Wish-flicker grace: run survives a 0.1 s input dip, detaches after.
	_player.position = Vector3(0.0, 2.0, 0.0)
	_player.velocity = Vector3(0.0, 0.0, -8.0)
	_player.rotation = Vector3.ZERO
	_player.set("_wallrunning", true)
	_player.set("_wall_normal", Vector3(-1, 0, 0))
	_player.set("_wallrun_time", 0.0)
	_player.set("_wall_contact_grace", 0.08)
	_player.set("_wallrun_wish_grace", 0.15)
	await process_frame
	for i in range(6):
		_player.call("_update_wallrun", 1.0 / 60.0, Vector3.ZERO)
	_check(_player.get("_wallrunning") == true,
		"BB-3 sustain: 0.1 s wish flicker does NOT detach the run")
	for i in range(6):
		_player.call("_update_wallrun", 1.0 / 60.0, Vector3.ZERO)
	_check(_player.get("_wallrunning") == false,
		"BB-3 sustain: wish gone for good (0.2 s) detaches the run")

	print("VERIFY(landing + wall-run entry): %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


## One direct wall-run entry attempt for player B. angle_deg rotates the
## velocity from the wall tangent (-Z) toward the wall (+X); a negative
## angle drifts away from the wall. Returns _wallrunning after the call.
func _entry_attempt(angle_deg: float, speed: float, aim: String, blocked_normal: bool = false) -> bool:
	var th := deg_to_rad(angle_deg)
	var vel := Vector3(sin(th), 0.0, -cos(th)) * speed
	_player.position = Vector3(0.0, 2.0, 0.0)
	_player.velocity = vel
	_player.call("_end_wallrun")
	_player.set("_wallrun_blocked_normal", Vector3(-1, 0, 0) if blocked_normal else Vector3.ZERO)
	_player.set("_wallrun_detach_cooldown", 0.0)
	_player.set("_can_wallrun", true)
	match aim:
		"corridor":
			_player.rotation = Vector3.ZERO
		"velocity":
			_player.rotation = Vector3(0.0, -th, 0.0)
		"wall":
			_player.rotation = Vector3(0.0, -PI / 2.0, 0.0)
	_player.get_node("Head").rotation.x = 0.0
	await process_frame
	await process_frame
	for ray_name in ["WallRayL", "WallRayR", "WallRayF"]:
		(_player.get_node(ray_name) as RayCast3D).force_raycast_update()
	_player.call("_update_wallrun", 1.0 / 60.0, vel.normalized())
	var attached: bool = _player.get("_wallrunning")
	_player.call("_end_wallrun")
	return attached
