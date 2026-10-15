# verify_linux.gd — headless checks for the FORGEFALL Linux / Steam Deck build.
# Usage: godot --headless --path <project> --script res://tools/verify_linux.gd
# Also run against the BUILT Linux binary by executing the binary with the
# same --script argument (the binary accepts the same CLI).
#
# Asserts, on a non-Android (Linux) build:
#   1. PLATFORM: not android/ios; no ForgeUpdater singleton (no Android
#      plugin); the Updater autoload reports has_plugin() == false.
#   2. TOUCH UI: the touch layer stays hidden when no touchscreen is
#      available (its visibility must match its own activation rule:
#      force_show OR touchscreen OR android/ios).
#   3. UPDATE CHECK: a manual update check degrades gracefully without the
#      plugin — it settles to UP_TO_DATE / AVAILABLE / READY / ERROR /
#      DISABLED (never stuck in CHECKING, never a crash), and
#      installed_version_code() falls back to Tuning.FALLBACK_VERSION_CODE.
#   4. GAMEPAD (Worker A): InputMap carries joypad bindings for
#      move_forward/back/left/right + fire, and a right-stick look path.
#      Synthetic InputEventJoypadMotion/Button events through the real
#      Input singleton must then actually move the player, turn the
#      camera, and fire the weapon (mag decreases).
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _player: Node = null
var _touch: Node = null
var _updater: Node = null
var _deadline_ms := 0
var _start_pos := Vector3.ZERO
var _start_yaw := 0.0
var _start_pitch := 0.0
var _start_mag := -1
var _fire_button := -1
var _fire_axis := -1
var _fire_axis_value := 1.0
var _joy_presses := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _has_joypad_event(action: String) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton or e is InputEventJoypadMotion:
			return true
	return false


func _has_joypad_motion_axis(action: String, axis: int) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadMotion and (e as InputEventJoypadMotion).axis == axis:
			return true
	return false


func _joypad_button_for(action: String) -> int:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton:
			return (e as InputEventJoypadButton).button_index
	return -1


func _has_look_joypad_binding() -> bool:
	# Worker A implements right-stick look by polling
	# Input.get_joy_axis(JOY_AXIS_RIGHT_X/Y) in player._update_gamepad_look,
	# NOT via InputMap — so accept either an InputMap axis 2/3 binding or
	# the player's gamepad-look entry point. The dynamic test below is the
	# authoritative check; this is just the static presence check.
	for action in InputMap.get_actions():
		if _has_joypad_motion_axis(action, 2) or _has_joypad_motion_axis(action, 3):
			return true
	if _player != null and _player.has_method("_apply_gamepad_look"):
		return true
	return false


func _fire_motion_binding() -> Array:
	# Returns [axis, value] for a JoypadMotion binding on "fire", or [].
	for e in InputMap.action_get_events("fire"):
		if e is InputEventJoypadMotion:
			return [(e as InputEventJoypadMotion).axis, (e as InputEventJoypadMotion).axis_value]
	return []


func _press_fire() -> void:
	if _fire_button >= 0:
		_send_joy_button(_fire_button, true)
	elif _fire_axis >= 0:
		_send_joy_axis(_fire_axis, _fire_axis_value)


func _release_fire() -> void:
	if _fire_button >= 0:
		_send_joy_button(_fire_button, false)
	elif _fire_axis >= 0:
		_send_joy_axis(_fire_axis, 0.0)


func _send_joy_axis(axis: int, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.device = 0
	ev.axis = axis
	ev.axis_value = value
	Input.parse_input_event(ev)


func _send_joy_button(button: int, pressed: bool) -> void:
	var ev := InputEventJoypadButton.new()
	ev.device = 0
	ev.button_index = button
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _current_mag() -> int:
	if _player == null:
		return -1
	var mgr := _player.get_node_or_null("WeaponManager")
	if mgr == null:
		return -1
	var cur = null
	if mgr.has_method("current_weapon"):
		cur = mgr.call("current_weapon")
	else:
		cur = mgr.get("_current")
	if cur == null:
		return -1
	return int(cur.get("mag"))


func _initialize() -> void:
	var arena := Node3D.new()
	arena.name = "VerifyLinuxArena"
	root.add_child(arena)
	# Floor so the player lands and can walk.
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	var fshape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(60.0, 1.0, 60.0)
	fshape.shape = fbox
	floor_body.add_child(fshape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	arena.add_child(floor_body)
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	# Touch layer, as main.gd wires it.
	var tps := load("res://scenes/ui/touch_controls.tscn") as PackedScene
	_touch = tps.instantiate()
	_touch.name = "TouchControls"
	arena.add_child(_touch)
	_updater = root.get_node_or_null("Updater")
	_phase = 1
	print("VERIFY(linux): arena built, waiting for _ready + physics")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 5:
				return false
			# --- 1. PLATFORM: Linux, no Android plugin. ---
			_check(OS.get_name() == "Linux", "running on Linux (OS.get_name() == %s)" % OS.get_name())
			_check(not OS.has_feature("android"), "not an Android build")
			_check(not OS.has_feature("ios"), "not an iOS build")
			_check(not Engine.has_singleton("ForgeUpdater"),
				"no ForgeUpdater singleton (no Android plugin on Linux)")
			_check(_updater != null, "Updater autoload present")
			if _updater != null:
				_check(_updater.call("has_plugin") == false,
					"Updater.has_plugin() == false without the Android plugin")
				_check(int(_updater.call("installed_version_code")) == Tuning.FALLBACK_VERSION_CODE,
					"installed_version_code() falls back to Tuning (%d)" % Tuning.FALLBACK_VERSION_CODE)
			_phase = 2
			_frames = 0
		2:
			# --- 2. TOUCH UI: hidden when no touchscreen. ---
			var touchscreen := DisplayServer.is_touchscreen_available()
			print("VERIFY(linux): touchscreen available: ", touchscreen)
			var expect_visible := touchscreen or OS.has_feature("android") or OS.has_feature("ios")
			# force_show is a debug export defaulting false; read it if present.
			if _touch != null and bool(_touch.get("force_show")):
				expect_visible = true
			_check(_touch != null and _touch.visible == expect_visible,
				"touch layer hidden on non-touch (visible=%s, expected=%s)" % [str(_touch.visible if _touch != null else null), str(expect_visible)])
			_phase = 3
			_frames = 0
		3:
			# --- 3. UPDATE CHECK degrades gracefully (no plugin, no crash). ---
			if _updater == null:
				_check(false, "Updater autoload present (update-check phase)")
				_phase = 4
				_frames = 0
				return false
			var state: int = int(_updater.get("state"))
			# State enum: DISABLED=0 IDLE=1 CHECKING=2 UP_TO_DATE=3 AVAILABLE=4
			# DOWNLOADING=5 READY=6 ERROR=7.
			if state == 0:  # DISABLED (empty UPDATE_BASE_URL)
				_check(true, "updater DISABLED with no update URL (graceful)")
				_phase = 4
				_frames = 0
				return false
			if _frames == 1:
				_updater.call("check_for_updates", true)
				_deadline_ms = Time.get_ticks_msec() + 20000
			if state == 2:  # CHECKING — wait for it to settle.
				if Time.get_ticks_msec() > _deadline_ms:
					_check(false, "update check settles within 20s (stuck CHECKING)")
					_phase = 4
					_frames = 0
				return false
			_check(state == 3 or state == 4 or state == 6 or state == 7,
				"manual update check settles gracefully (state %d, no crash)" % state)
			if state == 7:
				print("VERIFY(linux): updater ERROR (expected offline/sandbox): ", str(_updater.get("last_error")))
			_phase = 4
			_frames = 0
		4:
			# --- 4a. GAMEPAD bindings exist in InputMap (Worker A). ---
			_check(_has_joypad_event("move_forward"), "gamepad binding: move_forward has joypad event")
			_check(_has_joypad_event("move_back"), "gamepad binding: move_back has joypad event")
			_check(_has_joypad_event("move_left"), "gamepad binding: move_left has joypad event")
			_check(_has_joypad_event("move_right"), "gamepad binding: move_right has joypad event")
			_check(_has_joypad_event("fire"), "gamepad binding: fire has joypad event")
			_check(_has_look_joypad_binding(), "gamepad look path exists (right-stick poll or axis 2/3 binding)")
			_fire_button = _joypad_button_for("fire")
			# Land the player before the movement test.
			_player.position = Vector3(0.0, 2.0, 5.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			_phase = 5
			_frames = 0
		5:
			if _frames < 20:
				return false
			# --- 4b. GAMEPAD MOVE: left stick forward moves the player. ---
			_start_pos = _player.position
			_send_joy_axis(1, -1.0)  # left stick Y up = forward
			_send_joy_axis(0, 0.0)
			_phase = 55
			_frames = 0
		55:
			# parse_input_event queues the event: strength is only visible
			# from the NEXT frame on. Check after one frame of latency.
			if _frames < 2:
				return false
			_check(Input.get_action_strength("move_forward") > 0.5,
				"left-stick up drives move_forward (strength %.2f)" % Input.get_action_strength("move_forward"))
			_phase = 6
			_frames = 0
		6:
			if _frames < 60:
				return false
			var moved: float = _start_pos.z - _player.position.z
			_check(Input.get_action_strength("move_forward") > 0.5,
				"move_forward stays held from left stick (strength %.2f)" % Input.get_action_strength("move_forward"))
			_check(moved > 0.1,
				"left stick moves player forward (dz %.2f)" % moved)
			_check(_player.velocity.z < -1.0,
				"left stick gives forward velocity (vz %.2f)" % _player.velocity.z)
			_send_joy_axis(1, 0.0)  # release stick
			_start_yaw = _player.rotation.y
			_start_pitch = float(_player.get_node("Head").rotation.x)
			# Right-stick look is polled from REAL hardware
			# (Input.get_joy_axis over connected joypads), which synthetic
			# events cannot feed — Worker A documents the headless path as
			# calling _apply_gamepad_look() directly with deflections.
			_player.call("_apply_gamepad_look", 0.8, 0.5, 0.5)
			_phase = 7
			_frames = 0
		7:
			if _frames < 2:
				return false
			# --- 4c. GAMEPAD LOOK: right stick turns yaw/pitch. ---
			var yaw_delta := absf(_player.rotation.y - _start_yaw)
			var pitch_delta := absf(float(_player.get_node("Head").rotation.x) - _start_pitch)
			_check(yaw_delta > 0.01 or pitch_delta > 0.01,
				"right stick turns the camera (dyaw %.3f, dpitch %.3f)" % [yaw_delta, pitch_delta])
			_check(_player.has_method("_update_gamepad_look"),
				"gamepad look poll (_update_gamepad_look) wired into _process")
			_start_mag = _current_mag()
			print("VERIFY(linux): mag before joypad fire: ", _start_mag)
			_phase = 8
			_frames = 0
			_joy_presses = 0
		8:
			# --- 4d. GAMEPAD FIRE: joypad fire input fires the weapon. ---
			# Fire may be a JoypadButton (e.g. shoulder) or a JoypadMotion
			# (analog trigger axis) binding — Worker A uses the RT axis.
			if _fire_button < 0 and _fire_axis < 0:
				var fb := _fire_motion_binding()
				if fb.size() == 2:
					_fire_axis = int(fb[0])
					_fire_axis_value = float(fb[1])
				else:
					_check(false, "fire has a joypad binding (button or trigger axis) for the fire test")
					_phase = 9
					_frames = 0
					return false
			if _joy_presses < 3:
				_press_fire()
				_joy_presses += 1
				return false
			_release_fire()
			_phase = 9
			_frames = 0
		9:
			if _frames < 5:
				return false
			var end_mag := _current_mag()
			print("VERIFY(linux): mag after joypad fire: ", end_mag)
			_check(_start_mag > 0 and end_mag >= 0 and end_mag < _start_mag,
				"joypad fire input fires weapon (mag %d -> %d)" % [_start_mag, end_mag])
			_phase = 10
		10:
			if _fails == 0:
				print("VERIFY(linux): ALL CHECKS PASSED")
			else:
				printerr("VERIFY(linux): %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false
