# tools/verify_touch_aim.gd — behavioral dual-touch aim verification.
# Usage: godot --headless --path <project> --script res://tools/verify_touch_aim.gd
#
# Feeds synthetic two-touch sequences through the REAL
# touch_controls._input() dispatcher and asserts the look path behaves.
# Every synthetic drag carries a DELIBERATELY WRONG engine `relative`,
# proving look deltas come from per-touch tracked positions only —
# the "aim jumps to random places while moving" bug class.
#
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

const GAIN := 0.0022  # must match touch_controls LOOK_GAIN (sensitivity 1.0)
const BOGUS := Vector2(99999.0, -99999.0)

var _passes := 0
var _fails := 0
var _tc: CanvasLayer
var _mp: Node
var _vs := Vector2.ZERO  # touch layer view size


func _pass(label: String) -> void:
	_passes += 1
	print("  PASS: " + label)


func _fail(label: String, detail: String) -> void:
	_fails += 1
	printerr("  FAIL: " + label + " — " + detail)


func _close(a: Vector2, b: Vector2, tol := 0.0001) -> bool:
	return (a - b).length() < tol


func _touch_begin(index: int, pos: Vector2) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = true
	_tc._input(e)


func _touch_end(index: int) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.pressed = false
	_tc._input(e)


func _drag(index: int, pos: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	e.relative = BOGUS  # always wrong on purpose: must be ignored
	_tc._input(e)


func _kind(index: int) -> String:
	return String((_tc.get("_touches") as Dictionary).get(index, ""))


func _joy() -> Vector2:
	return _vs * Vector2(0.20, 0.60)


func _look() -> Vector2:
	return _vs * Vector2(0.70, 0.50)


func _setup() -> bool:
	_tc = CanvasLayer.new()
	_tc.set_script(load("res://scripts/android/touch_controls.gd"))
	_tc.set("force_show", true)
	root.add_child(_tc)
	# Viewport is valid here (first _process frame); force a deterministic
	# landscape size and re-run layout before touching.
	root.size = Vector2i(1280, 720)
	_tc._layout()
	_mp = load("res://tools/mock_look_player.gd").new()
	root.add_child(_mp)
	_vs = _tc.get("_view_size")
	if _vs.x <= 0.0 or _vs.y <= 0.0:
		_fail("setup", "touch layer view size invalid: %s" % _vs)
		return false
	if not bool(_tc.get("_touch_active")):
		_fail("setup", "touch layer not active with force_show")
		return false
	_pass("setup: touch layer active, view %s" % _vs)
	return true


func _reset() -> void:
	_mp.reset()
	for a in ["move_forward", "move_back", "move_left", "move_right", "sprint"]:
		Input.action_release(a)


func _test_single_look() -> void:
	# Single-finger look: deltas must equal tracked position deltas,
	# never the (bogus) engine relative.
	_reset()
	var L := _look()
	_touch_begin(0, L)
	if _kind(0) != "look":
		_fail("single-look/zone", "touch at %s assigned '%s', expected 'look'" % [L, _kind(0)])
		return
	_drag(0, L + Vector2(50, 0))
	_drag(0, L + Vector2(50, 30))
	var want := Vector2(50, 30) * GAIN
	if _close(_mp.look_sum(), want):
		_pass("single-look: deltas from tracked positions, engine relative ignored")
	else:
		_fail("single-look", "got %s want %s" % [_mp.look_sum(), want])
	_touch_end(0)


func _test_dual_no_crosstalk() -> void:
	# The reported bug: aim while moving. Left thumb drives the stick,
	# right thumb aims — look must see ONLY the look finger's deltas.
	_reset()
	var J := _joy()
	var L := _look()
	_touch_begin(0, J)
	if _kind(0) != "joy":
		_fail("dual/zone-joy", "touch at %s assigned '%s'" % [J, _kind(0)])
		return
	_drag(0, J + Vector2(30, 0))  # moving right
	if not Input.is_action_pressed("move_right"):
		_fail("dual/move", "move_right not pressed after joy drag")
		return
	_touch_begin(1, L)
	if _kind(1) != "look":
		_fail("dual/zone-look", "touch at %s assigned '%s'" % [L, _kind(1)])
		return
	_drag(1, L + Vector2(40, 10))
	_drag(0, J + Vector2(30, 20))  # keep moving while aiming
	_drag(1, L + Vector2(40, 25))
	var want := Vector2(40, 25) * GAIN
	if _close(_mp.look_sum(), want):
		_pass("dual: look saw only the look finger (no crosstalk from stick)")
	else:
		_fail("dual", "look sum %s, want %s (stick leaked into aim?)" % [_mp.look_sum(), want])
	if Input.is_action_pressed("move_right"):
		_pass("dual: stick still driving movement")
	else:
		_fail("dual/move-held", "move_right lost while aiming")
	_touch_end(0)
	_touch_end(1)
	if Input.is_action_pressed("move_right"):
		_fail("dual/release", "move_right stuck after stick release")
	else:
		_pass("dual: stick release clears movement")


func _test_second_joy_finger() -> void:
	# Second finger in the stick zone must NOT steal _joy_origin.
	_reset()
	var J := _joy()
	var J2 := _vs * Vector2(0.10, 0.70)
	_touch_begin(0, J)
	_touch_begin(2, J2)
	if _kind(2) != "joy_wait":
		_fail("joy-wait/kind", "second stick-zone touch assigned '%s'" % _kind(2))
		_touch_end(0)
		_touch_end(2)
		return
	if int(_tc.get("_joy_touch")) != 0:
		_fail("joy-wait/owner", "_joy_touch stolen by second finger")
	_touch_end(2)
	# Finger 0 never moved: stick must be idle (deadzone), not jumped.
	_drag(2, J2 + Vector2(80, 0))  # stale drag for the released waiter
	for a in ["move_forward", "move_back", "move_left", "move_right"]:
		if Input.is_action_pressed(a):
			_fail("joy-wait/leak", "waiter finger drove %s" % a)
			_touch_end(0)
			return
	_pass("joy-wait: second stick-zone finger ignored, owner kept")
	_touch_end(0)
	if (_tc.get("_touches") as Dictionary).is_empty():
		_pass("joy-wait: clean release, no stuck touches")
	else:
		_fail("joy-wait/release", "touches stuck: %s" % _tc.get("_touches"))


func _test_release_drops_look() -> void:
	# After release, drags for that index must be ignored (stale events).
	_reset()
	var L := _look()
	_touch_begin(1, L)
	_drag(1, L + Vector2(20, 0))
	_touch_end(1)
	_drag(1, L + Vector2(400, 400))  # stale: finger is up
	var want := Vector2(20, 0) * GAIN
	if _close(_mp.look_sum(), want):
		_pass("release: stale drags after lift ignored")
	else:
		_fail("release", "look sum %s after lift, want %s" % [_mp.look_sum(), want])


func _test_midpoint_cross() -> void:
	# Assignment happens at touch-down: a look drag that crosses into
	# the left 40% stays look (no mid-gesture reassignment jumps).
	_reset()
	var L := _look()
	var cross := Vector2(_vs.x * 0.30, _vs.y * 0.50)
	_touch_begin(1, L)
	_drag(1, cross)
	var want := (cross - L) * GAIN
	if _close(_mp.look_sum(), want):
		_pass("midpoint-cross: look finger keeps look across the zone line")
	else:
		_fail("midpoint-cross", "look sum %s, want %s" % [_mp.look_sum(), want])
	_touch_end(1)


func _test_rapid_tap() -> void:
	# Rapid taps with no drags must not look (no phantom deltas).
	_reset()
	var L := _look()
	for i in 3:
		_touch_begin(1, L + Vector2(i * 5, 0))
		_touch_end(1)
	if _mp.look_calls.is_empty():
		_pass("rapid-tap: no look from taps without drags")
	else:
		_fail("rapid-tap", "%d phantom look calls" % _mp.look_calls.size())


func _button(id: String) -> Dictionary:
	for d in _tc.get("_btn_defs"):
		if d["id"] == id:
			return d
	return {}


func _test_fire_drag() -> void:
	_reset()
	var fire := _button("fire")
	var pos: Vector2 = fire["pos"] + fire["size"] * 0.5
	_touch_begin(0, _joy())
	_drag(0, _joy() + Vector2(35, 0))
	_touch_begin(1, pos)
	_drag(1, pos + Vector2(-40, 20))
	if Input.is_action_pressed("fire") and Input.is_action_pressed("move_right") and _close(_mp.look_sum(), Vector2(-40, 20) * GAIN):
		_pass("fire-drag: move, shoot and aim simultaneously")
	else:
		_fail("fire-drag", "movement, fire or tracked aim missing")
	_touch_begin(2, pos)
	_touch_end(1)
	if Input.is_action_pressed("fire"):
		_pass("fire: lifting one finger preserves the other owner's hold")
	else:
		_fail("fire ownership", "released another finger's fire")
	_tc.set_menu_open(true)
	if not Input.is_action_pressed("fire") and not Input.is_action_pressed("move_right") and (_tc.get("_touches") as Dictionary).is_empty():
		_pass("menu: held movement/fire released and touch ownership cleared")
	else:
		_fail("menu cleanup", "action or touch stuck")
	_tc.set_menu_open(false)
	_drag(2, pos + Vector2(90, 0))
	if _close(_mp.look_sum(), Vector2(-40, 20) * GAIN):
		_pass("menu: stale held-finger drag cannot resume aim")
	else:
		_fail("menu stale drag", "aim leaked after menu")


func _test_placement_touch() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var player := Node3D.new()
	world.add_child(player)
	var placement: Node = load("res://scripts/forge/forge_placement.gd").attach_to(world)
	var confirmations := [0]
	placement.preview_confirm_requested.connect(func(_pos: Vector3): confirmations[0] += 1)
	if not placement.start_preview("sniper_nest", {}, player, world):
		_fail("placement setup", "could not start ghost")
		world.free()
		return
	_tc._process(0.0)
	var use := _button("interact")
	var pos: Vector2 = use["pos"] + use["size"] * 0.5
	_touch_begin(5, pos)
	_touch_end(5)
	Input.flush_buffered_events()
	if confirmations[0] == 1:
		_pass("PLACE touch: real ghost controller receives confirmation event once")
	else:
		_fail("PLACE event", "received %d confirmations" % confirmations[0])
	var cancel := _button("cancel")
	pos = cancel["pos"] + cancel["size"] * 0.5
	_touch_begin(5, pos)
	_touch_end(5)
	Input.flush_buffered_events()
	if not placement.has_preview():
		_pass("CANCEL touch: dismisses real placement preview")
	else:
		_fail("CANCEL event", "preview still active")
	world.free()


func _test_mobile_layout() -> void:
	for vp in [Vector2(844, 390), Vector2(1280, 720), Vector2(2340, 1080)]:
		var k := clampf(minf(vp.x / 1280.0, vp.y / 720.0), 0.65, 1.8)
		_tc._place_buttons(vp, k)
		var valid: bool = not _tc._buttons_overlap()
		for d in _tc.get("_btn_defs"):
			var rect := Rect2(d["pos"], d["size"])
			valid = valid and Rect2(Vector2.ZERO, vp).encloses(rect) and rect.size.x >= 48 and rect.size.y >= 48
		if valid:
			_pass("layout: in bounds, no overlap, targets >=48 at %s" % vp)
		else:
			_fail("layout", "overlap, undersized or off-screen at %s" % vp)
	_tc._layout()


func _test_menu_emulation() -> void:
	MouseCapture.set_menu()
	if Input.emulate_mouse_from_touch:
		_pass("menus: native GUI receives emulated mouse taps")
	else:
		_fail("menu taps", "mouse emulation disabled")
	MouseCapture.set_gameplay()
	if not Input.emulate_mouse_from_touch:
		_pass("gameplay: native multi-touch cannot generate mouse fire")
	else:
		_fail("gameplay emulation", "touch could leak into mouse bindings")
	MouseCapture.set_menu()


func _initialize() -> void:
	print("VERIFY_TOUCH_AIM: behavioral dual-touch aim through the real dispatcher")
	# NOTE: nodes added here report is_inside_tree() == false, so the
	# whole test runs on the first _process frame instead.


var _ran := false


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	if _setup():
		_test_single_look()
		_test_dual_no_crosstalk()
		_test_second_joy_finger()
		_test_release_drops_look()
		_test_midpoint_cross()
		_test_rapid_tap()
		_test_fire_drag()
		_test_placement_touch()
		_test_mobile_layout()
		_test_menu_emulation()
	print("VERIFY_TOUCH_AIM: %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
	return false
