# verify_movement_rework.gd — headless verification for the FORGEFALL
# GAMEPLAY REWORK movement system (2026-10-16, Colin's spec).
# Usage: godot --headless --path <project> --script res://tools/verify_movement_rework.gd
# Covers:
#   1. WALL-RUN ATTACH (Colin's exact rules): attach ONLY at >= full
#      walking speed AND (aimed at the wall OR moving parallel to it).
#      Too-slow = no attach; aimed-away + perpendicular-away = no attach;
#      attach grants ~+50% speed (WALLRUN_ENTRY_BOOST 1.5 — see the
#      "BOOST READING" note on the const in player.gd: "~50 units" read
#      as +50%, since a literal +50 m/s would be ~4.5x sprint speed).
#   2. WALL-JUMP ONLY variable height: tap = small hop, hold = full
#      jump (ground jump has no cut — verified by the tap-vs-hold control).
#   3. SLIDE HEIGHT: slide camera is the lowest stance (0.85 < crouch
#      1.05 < stand 1.6).
#   4. JETPACK (new traversal tool): fuel drain while thrusting, grounded
#      regen, max-burn latch, no thrust under another tool.
#   5. TRAVERSAL-TOOL SELECTION: exactly one of grapple / jetpack /
#      portal / none is live; per-run allowed-set (incl. the Zombies
#      default of none); grapple + portal inputs gated by the selection.
#      Grapple physics itself is UNTOUCHED (Colin: "starting to feel
#      right") — gating happens at the player input level only.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _passes := 0
var _phase := 0
var _last_phase := -1
var _phase_time := 0.0
var _phase_fired := false
var _player: Node = null

# Wall-jump apex tracking.
var _wj_state := 0  # 0 setup, 1 wait attach, 2 jump fired, 3 tracking
var _wj_y0 := 0.0
var _wj_max_y := 0.0
var _wj_tap := false
var _wj_hold_gain := 0.0
var _wj_tap_gain := 0.0
# Ground-jump control.
var _gj_state := 0
var _gj_y0 := 0.0
var _gj_max_y := 0.0
var _gj_tap := false
var _gj_tap_gain := 0.0
var _gj_hold_gain := 0.0
# Jetpack regen.
var _jp_fuel0 := 0.0
var _jp_grounded := false
var _jp_regen_t := 0.0


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _cmap(path: String) -> Dictionary:
	var s := load(path) as GDScript
	if s == null:
		return {}
	return s.get_script_constant_map()


func _release_all() -> void:
	for a in ["move_forward", "move_back", "move_left", "move_right",
			"sprint", "crouch", "jump", "ads", "grapple",
			"portal_blue", "portal_orange"]:
		Input.action_release(a)


func _hspeed() -> float:
	return Vector2(_player.velocity.x, _player.velocity.z).length()


func _initialize() -> void:
	var arena := Node3D.new()
	arena.name = "VerifyArena"
	root.add_child(arena)
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
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	_phase = 0
	print("VERIFY(movement_rework): arena built")


## Teleport the player + reset movement state. Does NOT touch Input.
func _reset_player(pos: Vector3, vel: Vector3, rot_y: float) -> void:
	_player.position = pos
	_player.velocity = vel
	_player.rotation = Vector3(0.0, rot_y, 0.0)
	_player.get_node("Head").rotation.x = 0.0
	_player.call("_end_wallrun")
	_player.set("_can_wallrun", true)
	_player.set("_walljump_cut_armed", false)
	_player.set("_sliding", false)
	_player.get("grapple").call("release")


## One direct _update_wallrun tick with freshly forced raycasts. Used for
## the negative attach cases + the boost measurement, where a physics-loop
## test would let _update_horizontal accelerate the player across the
## speed gate and contaminate the result.
func _direct_wallrun_attempt(wish: Vector3) -> bool:
	for ray_name in ["WallRayL", "WallRayR", "WallRayF"]:
		var ray: RayCast3D = _player.get_node(ray_name)
		ray.force_raycast_update()
	_player.call("_update_wallrun", 1.0 / 60.0, wish)
	return _player.get("_wallrunning") == true


func _process(delta: float) -> bool:
	if _phase != _last_phase:
		_last_phase = _phase
		_phase_time = 0.0
		_phase_fired = false
	_phase_time += delta
	match _phase:
		0:
			if _phase_time < 0.1:
				return false
			_check_constants()
			_phase = 1
		1:
			# TOO SLOW = NO ATTACH: 5.0 m/s, parallel to the wall, aimed
			# along it — everything right except the speed gate (6.0).
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 5.0), Vector3(0.0, 0.0, -5.0), 0.0)
			if _phase_time < 0.15:
				return false
			var attached := _direct_wallrun_attempt(Vector3(0.0, 0.0, -1.0))
			_check(not attached,
				"too-slow (5.0 < 6.0 full walk) does NOT attach despite parallel motion")
			_player.call("_end_wallrun")
			_phase = 2
		2:
			# AIMED AWAY + PERPENDICULAR-AWAY = NO ATTACH: full speed,
			# but moving straight away from the wall while looking away.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				# Facing -x (away from the wall at +x), moving -x.
				_reset_player(Vector3(0.0, 2.0, 0.0), Vector3(-7.0, 0.0, 0.0), PI / 2.0)
			if _phase_time < 0.15:
				return false
			var attached := _direct_wallrun_attempt(Vector3(-1.0, 0.0, 0.0))
			_check(not attached,
				"aimed away + moving perpendicular-away does NOT attach at full speed")
			_player.call("_end_wallrun")
			_phase = 3
		3:
			# AIMED AT THE WALL + SPEED = ATTACH (physics loop): head-on
			# approach, facing the wall, flying straight at it.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(-1.0, 2.0, 0.0), Vector3(7.0, 0.0, 0.0), -PI / 2.0)
				Input.action_press("move_forward", 1.0)
			if _player.get("_wallrunning") == true:
				_check(true, "aimed-at-wall + speed attaches (head-on, forward ray)")
				_release_all()
				_player.call("_end_wallrun")
				_phase = 4
			elif _phase_time > 1.0:
				_check(false, "aimed-at-wall + speed attaches within 1 s")
				_release_all()
				_phase = 4
		4:
			# PARALLEL + SPEED = ATTACH (physics loop): running alongside
			# the wall while looking along it (NOT at the wall).
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 5.0), Vector3(0.0, 0.0, -7.0), 0.0)
				Input.action_press("move_forward", 1.0)
			if _player.get("_wallrunning") == true:
				_check(true, "parallel + speed attaches (looking along the wall, not at it)")
				_release_all()
				_player.call("_end_wallrun")
				_phase = 5
			elif _phase_time > 1.0:
				_check(false, "parallel + speed attaches within 1 s")
				_release_all()
				_phase = 5
		5:
			# ATTACH BOOST: direct entry at 8.0 m/s parallel must exit
			# at ~12.0 m/s (x1.5, Colin's "~50" boost).
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 5.0), Vector3(0.0, 0.0, -8.0), 0.0)
			if _phase_time < 0.15:
				return false
			var pre := _hspeed()
			var attached := _direct_wallrun_attempt(Vector3(0.0, 0.0, -1.0))
			var post := _hspeed()
			_check(attached, "boost test: wall-run attaches for the boost measurement")
			_check(post > pre * 1.45 and post < pre * 1.55,
				"attach grants ~+50%% speed: %.2f -> %.2f (ratio %.3f)" % [pre, post, post / maxf(pre, 0.001)])
			_player.call("_end_wallrun")
			_phase = 6
		6:
			# WALL-JUMP HOLD: full height. Attach, hold jump to apex.
			if _wj_state == 0:
				_wj_state = 1
				_wj_tap = false
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 5.0), Vector3(0.0, 0.0, -8.0), 0.0)
				Input.action_press("move_forward", 1.0)
			elif _wj_state == 1:
				if _player.get("_wallrunning") == true:
					Input.action_press("jump", 1.0)
					_wj_state = 2
				elif _phase_time > 2.0:
					_check(false, "wall-jump HOLD: wall-run attached within 2 s")
					_release_all()
					_wj_state = 0
					_phase = 7
			elif _wj_state == 2:
				# Wall jump fired once _wallrunning clears.
				if _player.get("_wallrunning") == false:
					_wj_y0 = _player.position.y
					_wj_max_y = _wj_y0
					_wj_state = 3
				elif _phase_time > 3.0:
					_check(false, "wall-jump HOLD: jump fired within 3 s")
					_release_all()
					_wj_state = 0
					_phase = 7
			elif _wj_state == 3:
				_wj_max_y = maxf(_wj_max_y, _player.position.y)
				if bool(_player.call("is_on_floor")) or _phase_time > 4.0:
					_wj_hold_gain = _wj_max_y - _wj_y0
					_check(_wj_hold_gain > 0.7,
						"wall-jump HOLD reaches full height (gain %.2f m, expect ~1.0)" % _wj_hold_gain)
					_release_all()
					_wj_state = 0
					_phase = 7
		7:
			# WALL-JUMP TAP: small hop. Attach, tap jump (release next
			# frame), measure apex — must be clearly below the hold apex.
			if _wj_state == 0:
				_wj_state = 1
				_wj_tap = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 5.0), Vector3(0.0, 0.0, -8.0), 0.0)
				Input.action_press("move_forward", 1.0)
			elif _wj_state == 1:
				if _player.get("_wallrunning") == true:
					Input.action_press("jump", 1.0)
					_wj_state = 2
				elif _phase_time > 2.0:
					_check(false, "wall-jump TAP: wall-run attached within 2 s")
					_release_all()
					_wj_state = 0
					_phase = 8
			elif _wj_state == 2:
				# Release on the frame AFTER the press: the cut fires in
				# _update_jump when it sees the release while still rising.
				Input.action_release("jump")
				if _player.get("_wallrunning") == false:
					_wj_y0 = _player.position.y
					_wj_max_y = _wj_y0
					_wj_state = 3
				elif _phase_time > 3.0:
					_check(false, "wall-jump TAP: jump fired within 3 s")
					_release_all()
					_wj_state = 0
					_phase = 8
			elif _wj_state == 3:
				_wj_max_y = maxf(_wj_max_y, _player.position.y)
				if bool(_player.call("is_on_floor")) or _phase_time > 4.0:
					_wj_tap_gain = _wj_max_y - _wj_y0
					_check(_wj_tap_gain + 0.3 < _wj_hold_gain,
						"wall-jump TAP is a small hop: tap gain %.2f m vs hold %.2f m" % [_wj_tap_gain, _wj_hold_gain])
					_check(_wj_tap_gain > 0.15,
						"wall-jump TAP still hops (gain %.2f m > 0.15)" % _wj_tap_gain)
					_release_all()
					_wj_state = 0
					_phase = 8
		8:
			# GROUND-JUMP CONTROL: tap vs hold must match (no cut on
			# ground jumps — the variable height is wall-jump ONLY).
			if _gj_state == 0:
				_gj_state = 1
				_gj_tap = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 30.0), Vector3.ZERO, 0.0)
			elif _gj_state == 1:
				if bool(_player.call("is_on_floor")):
					Input.action_press("jump", 1.0)
					_gj_state = 2
				elif _phase_time > 2.0:
					_check(false, "ground-jump control: landed within 2 s")
					_release_all()
					_gj_state = 0
					_phase = 9
			elif _gj_state == 2:
				# Tap run: release next frame. Hold run: keep held.
				if _gj_tap:
					Input.action_release("jump")
				if not bool(_player.call("is_on_floor")):
					_gj_y0 = _player.position.y
					_gj_max_y = _gj_y0
					_gj_state = 3
				elif _phase_time > 3.0:
					_check(false, "ground-jump control: jump fired within 3 s")
					_release_all()
					_gj_state = 0
					_phase = 9
			elif _gj_state == 3:
				_gj_max_y = maxf(_gj_max_y, _player.position.y)
				if bool(_player.call("is_on_floor")) or _phase_time > 4.0:
					var gain := _gj_max_y - _gj_y0
					if _gj_tap:
						_gj_tap_gain = gain
						_gj_tap = false
						_release_all()
						# Loop back for the hold run via state 4.
						_gj_state = 4
					else:
						_gj_hold_gain = gain
						_check(absf(_gj_tap_gain - _gj_hold_gain) < 0.15,
							"ground jump has NO cut: tap %.2f m ~= hold %.2f m" % [_gj_tap_gain, _gj_hold_gain])
						_check(_gj_hold_gain > 0.6 and _gj_hold_gain < 1.1,
							"ground jump height unchanged (gain %.2f m, expect ~0.84)" % _gj_hold_gain)
						_release_all()
						_gj_state = 0
						_phase = 9
			elif _gj_state == 4:
				# Hold run setup: grounded, then press + HOLD jump.
				if bool(_player.call("is_on_floor")):
					Input.action_press("jump", 1.0)
					_gj_state = 2
				elif _phase_time > 4.0:
					_check(false, "ground-jump HOLD: landed within 4 s")
					_release_all()
					_gj_state = 0
					_phase = 9
		9:
			# SLIDE HEIGHT: slide camera is the lowest stance.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 30.0), Vector3.ZERO, 0.0)
			if not bool(_player.call("is_on_floor")):
				if _phase_time > 2.0:
					_check(false, "slide height: grounded within 2 s")
					_phase = 10
				return false
			# Grounded: force a slide (entry path covered by verify_feel)
			# and let the head-height lerp settle.
			_player.set("_sliding", true)
			_player.velocity = Vector3(0.0, 0.0, -11.0)
			if _phase_time < 0.9:
				return false
			var head_y: float = _player.get_node("Head").position.y
			_check(head_y > 0.7 and head_y < 1.0,
				"slide head height settles low (head y %.2f, expect ~0.85)" % head_y)
			_check(head_y < 1.05,
				"slide camera is BELOW crouch height (%.2f < 1.05)" % head_y)
			_player.set("_sliding", false)
			_phase = 10
		10:
			# TRAVERSAL-TOOL SELECTION API.
			_check(_player.call("get_traversal_tool") == "grapple",
				"default traversal tool is grapple (pre-rework feel)")
			_check(_player.call("set_traversal_tool", "jetpack") == true
					and _player.call("get_traversal_tool") == "jetpack",
				"set_traversal_tool('jetpack') succeeds")
			_check(_player.call("set_traversal_tool", "bogus") == false
					and _player.call("get_traversal_tool") == "jetpack",
				"set_traversal_tool('bogus') fails, selection unchanged")
			_player.call("set_allowed_traversal_tools", ["portal"])
			_check(_player.call("get_traversal_tool") == "none",
				"selection outside the allowed set falls back to 'none'")
			_check(_player.call("set_traversal_tool", "jetpack") == false,
				"set_traversal_tool fails for a tool outside the allowed set")
			# ZOMBIES DEFAULT: empty allowed set = NO tools.
			_player.call("set_allowed_traversal_tools", [])
			_check(_player.call("get_traversal_tool") == "none",
				"empty allowed set (Zombies default) = no traversal tool")
			_check(_player.call("set_traversal_tool", "grapple") == false
					and _player.call("set_traversal_tool", "portal") == false
					and _player.call("set_traversal_tool", "jetpack") == false,
				"Zombies default: no tool selectable while the set is empty")
			# Zombies opt-in toggle: the toggle passes its enabled list.
			_player.call("set_allowed_traversal_tools", ["grapple", "portal"])
			_check(_player.call("set_traversal_tool", "portal") == true,
				"opt-in toggle re-enables selection (portal)")
			_check(_player.call("set_traversal_tool", "jetpack") == false,
				"opt-in toggle: jetpack stays blocked when not in the set")
			_player.call("set_allowed_traversal_tools", ["grapple", "jetpack", "portal"])
			_check(_player.call("set_traversal_tool", "grapple") == true,
				"full allowed set restores grapple selection")
			_phase = 11
		11:
			# GRAPPLE INPUT GATING: with jetpack selected, the grapple
			# action does nothing; with grapple selected, it fires.
			# Player faces the wall so a fire WOULD hit if the gate broke.
			# The press is consumed with a DIRECT _update_grapple_input()
			# call in the same frame: a held just_pressed across a second
			# physics tick would re-enter fire() and TOGGLE an active
			# grapple back off (fire() toggles), which would fake-fail
			# the positive control.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 0.0), Vector3.ZERO, -PI / 2.0)
				_player.call("set_traversal_tool", "jetpack")
				Input.action_press("grapple", 1.0)
				_player.call("_update_grapple_input")
				_check(_player.get("grapple").get("_active") == false,
					"grapple input ignored while jetpack is the selected tool")
				Input.action_release("grapple")
				_player.call("set_traversal_tool", "grapple")
				Input.action_press("grapple", 1.0)
				_player.call("_update_grapple_input")
				_check(_player.get("grapple").get("_active") == true,
					"grapple fires when grapple is the selected tool")
				_player.get("grapple").call("release")
				Input.action_release("grapple")
			_phase = 13
		13:
			# PORTAL INPUT GATING: with grapple selected, portal input
			# does nothing; with portal selected, the blue disc places.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 0.0), Vector3.ZERO, -PI / 2.0)
				_player.call("set_traversal_tool", "grapple")
				Input.action_press("portal_blue", 1.0)
			if _phase_time < 0.25:
				return false
			var emitter: Node = _player.get_node("PortalEmitter")
			_check(emitter.get("_blue").get("is_active") == false,
				"portal input ignored while grapple is the selected tool")
			Input.action_release("portal_blue")
			_player.call("set_traversal_tool", "portal")
			Input.action_press("portal_blue", 1.0)
			_phase = 14
		14:
			if _phase_time < 0.25:
				return false
			var emitter: Node = _player.get_node("PortalEmitter")
			_check(emitter.get("_blue").get("is_active") == true,
				"portal fires when portal is the selected tool")
			emitter.call("clear_portals")
			Input.action_release("portal_blue")
			_player.call("set_traversal_tool", "grapple")
			_phase = 15
		15:
			# JETPACK THRUST: airborne + jump held -> rises, fuel drains.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 5.0, 0.0), Vector3(0.0, -2.0, 0.0), 0.0)
				_player.call("set_traversal_tool", "jetpack")
				Input.action_press("jump", 1.0)
			if _phase_time < 0.6:
				return false
			_check(_player.velocity.y > 2.0,
				"jetpack thrust lifts a falling player (vy %.2f > 2.0)" % _player.velocity.y)
			_check(_player.call("get_jetpack_fuel_frac") < 0.9,
				"jetpack burns fuel while thrusting (frac %.2f < 0.9)" % _player.call("get_jetpack_fuel_frac"))
			_check(_player.call("is_jetpack_thrusting") == true,
				"jetpack reports thrusting while the burn runs")
			Input.action_release("jump")
			_phase = 16
		16:
			# JETPACK WRONG-TOOL CONTROL: jump held with grapple selected
			# = plain gravity, no fuel change.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 5.0, 0.0), Vector3.ZERO, 0.0)
				_player.call("set_traversal_tool", "grapple")
				_jp_fuel0 = _player.call("get_jetpack_fuel_frac")
				Input.action_press("jump", 1.0)
			if _phase_time < 0.4:
				return false
			_check(_player.velocity.y < -2.0,
				"no jetpack thrust under another tool (vy %.2f, still falling)" % _player.velocity.y)
			_check(absf(_player.call("get_jetpack_fuel_frac") - _jp_fuel0) < 0.01,
				"no fuel burn under another tool (frac %.2f unchanged)" % _player.call("get_jetpack_fuel_frac"))
			Input.action_release("jump")
			_phase = 17
		17:
			# JETPACK MAX-BURN LATCH: full tank + jump held past
			# JETPACK_MAX_BURN -> thrust cuts while still held, until
			# jump is released.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 8.0, 0.0), Vector3.ZERO, 0.0)
				_player.call("set_traversal_tool", "jetpack")
				_player.set("_jetpack_fuel", 100.0)
				Input.action_press("jump", 1.0)
			if _phase_time < 3.2:
				return false
			_check(_player.call("is_jetpack_thrusting") == false,
				"max-burn latch cuts thrust after ~2.5 s of held burn")
			_check(_player.velocity.y < 0.0,
				"latched jetpack falls again while jump is still held (vy %.2f)" % _player.velocity.y)
			_check(_player.get("_jetpack_latched") == true,
				"jetpack latched flag is set at max burn")
			Input.action_release("jump")
			_phase = 18
		18:
			if _phase_time < 0.2:
				return false
			_check(_player.get("_jetpack_latched") == false,
				"releasing jump clears the max-burn latch")
			Input.action_release("jump")
			_phase = 19
		19:
			# JETPACK REGEN: grounded, fuel climbs back.
			if not _phase_fired:
				_phase_fired = true
				_release_all()
				_reset_player(Vector3(0.0, 2.0, 30.0), Vector3.ZERO, 0.0)
				_player.call("set_traversal_tool", "jetpack")
				_player.set("_jetpack_fuel", 50.0)
				_jp_grounded = false
			if not _jp_grounded:
				if bool(_player.call("is_on_floor")):
					_jp_grounded = true
					_jp_fuel0 = _player.call("get_jetpack_fuel_frac")
					_jp_regen_t = 0.0
				elif _phase_time > 2.0:
					_check(false, "jetpack regen: grounded within 2 s")
					_phase = 20
				return false
			_jp_regen_t += delta
			if _jp_regen_t < 1.0:
				return false
			var frac: float = _player.call("get_jetpack_fuel_frac")
			_check(frac > _jp_fuel0 + 0.15 and frac < _jp_fuel0 + 0.35,
				"jetpack fuel regens grounded (%.2f -> %.2f in ~1 s, expect +0.25)" % [_jp_fuel0, frac])
			_phase = 20
		20:
			print("VERIFY(movement_rework): %d passed, %d failed" % [_passes, _fails])
			if _fails == 0:
				print("VERIFY(movement_rework): ALL CHECKS PASSED")
			else:
				printerr("VERIFY(movement_rework): %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


func _check_constants() -> void:
	var p := _cmap("res://scripts/player/player.gd")
	var t := _cmap("res://scripts/core/tuning.gd")
	_check(is_equal_approx(float(p.get("WALLRUN_MIN_SPEED", -1.0)), float(p.get("WALK_SPEED", -2.0))),
		"WALLRUN_MIN_SPEED (%.2f) == WALK_SPEED (%.2f): full walking speed" % [float(p.get("WALLRUN_MIN_SPEED", -1.0)), float(p.get("WALK_SPEED", -2.0))])
	_check(is_equal_approx(float(p.get("WALLRUN_ENTRY_BOOST", 0.0)), 1.5),
		"WALLRUN_ENTRY_BOOST %.2f == 1.5 (+50%% on attach)" % float(p.get("WALLRUN_ENTRY_BOOST", 0.0)))
	_check(float(p.get("WALL_JUMP_TAP_UP", 0.0)) < float(p.get("WALL_JUMP_UP", 0.0)),
		"WALL_JUMP_TAP_UP (%.2f) < WALL_JUMP_UP (%.2f): tap is the small hop" % [float(p.get("WALL_JUMP_TAP_UP", 0.0)), float(p.get("WALL_JUMP_UP", 0.0))])
	_check(float(p.get("HEAD_SLIDE", 0.0)) < float(p.get("HEAD_CROUCH", 0.0))
			and float(p.get("HEAD_CROUCH", 0.0)) < float(p.get("HEAD_HEIGHT", 0.0)),
		"slide head (%.2f) < crouch head (%.2f) < stand head (%.2f)" % [float(p.get("HEAD_SLIDE", 0.0)), float(p.get("HEAD_CROUCH", 0.0)), float(p.get("HEAD_HEIGHT", 0.0))])
	_check(float(p.get("JETPACK_FUEL_MAX", 0.0)) > 0.0
			and float(p.get("JETPACK_FUEL_DRAIN", 0.0)) > 0.0
			and float(p.get("JETPACK_FUEL_REGEN", 0.0)) > 0.0
			and float(p.get("JETPACK_MAX_BURN", 0.0)) > 0.0
			and float(p.get("JETPACK_THRUST_ACCEL", 0.0)) > 0.0
			and float(p.get("JETPACK_MAX_RISE", 0.0)) > 0.0,
		"jetpack tunables all positive (thrust %.1f, rise %.1f, fuel %.0f, drain %.1f/s, regen %.1f/s, burn %.1f s)" % [float(p.get("JETPACK_THRUST_ACCEL", 0.0)), float(p.get("JETPACK_MAX_RISE", 0.0)), float(p.get("JETPACK_FUEL_MAX", 0.0)), float(p.get("JETPACK_FUEL_DRAIN", 0.0)), float(p.get("JETPACK_FUEL_REGEN", 0.0)), float(p.get("JETPACK_MAX_BURN", 0.0))])
	var tools: Array = p.get("TRAVERSAL_TOOLS", [])
	_check(tools.has("grapple") and tools.has("jetpack") and tools.has("portal") and tools.has("none"),
		"TRAVERSAL_TOOLS lists grapple / jetpack / portal / none")
	# Tuning mirror (warn-level: live values live in player.gd).
	_check(is_equal_approx(float(t.get("PLAYER_WALLRUN_MIN_SPEED", -1.0)), float(p.get("WALLRUN_MIN_SPEED", -2.0))),
		"Tuning mirrors WALLRUN_MIN_SPEED (%.2f)" % float(t.get("PLAYER_WALLRUN_MIN_SPEED", -1.0)))
	_check(is_equal_approx(float(t.get("PLAYER_JETPACK_FUEL_MAX", -1.0)), float(p.get("JETPACK_FUEL_MAX", -2.0))),
		"Tuning mirrors JETPACK_FUEL_MAX (%.1f)" % float(t.get("PLAYER_JETPACK_FUEL_MAX", -1.0)))
