# scripts/input/mouse_capture.gd
# FORGEFALL — mouse capture (Windows port, Worker A).
# SINGLE SOURCE OF TRUTH for the mouse. No other file may set the mouse
# mode or the mouse-button InputMap bindings — every transition goes
# through this helper so the mouse can never get stuck in the wrong state.
#
# MODE: CAPTURED only during gameplay, VISIBLE in every menu.
#   set_gameplay() -> MOUSE_MODE_CAPTURED (gameplay: look + fire live)
#   set_menu()     -> MOUSE_MODE_VISIBLE  (every menu / unfocused window)
#   is_captured()  -> ground truth: live Input.mouse_mode, never a cached
#                     flag (a cached flag can drift from the real mode).
#   requested_captured() -> the last mode this helper was ASKED for.
#                     On real hardware it always equals is_captured().
#                     Headless Godot has no display server and silently
#                     ignores MOUSE_MODE_CAPTURED, so headless tests
#                     assert on requested_captured(), not is_captured().
#
# MOUSE-BUTTON BINDINGS (focus-click / menu-click suppression):
# WeaponManager polls Input.is_action_just_pressed("fire") in _process,
# and marking an input event handled does NOT clear that polled state —
# nor does Input.action_release() in _input (probe-verified: the release
# runs before the press state is applied, so the press wins). The only
# ordering-proof suppression is removing the binding before the press
# arrives, so the press can never create the action state:
#   erase_mouse_bindings()   -> save + remove the MB1/MB2/MB3 events from
#                               fire/ads/grapple (joypad + keyboard
#                               bindings are untouched; touch uses
#                               Input.action_press directly, unaffected).
#   restore_mouse_bindings() -> re-add the saved events (idempotent,
#                               never duplicates). The press that
#                               triggers the restore still cannot fire:
#                               its binding was gone when it was parsed.
#   mouse_bindings_erased()  -> whether bindings are currently erased.
# Erase on focus-out / menu-open; restore on the first gameplay mouse
# press, on menu-close, and on HUD exit (safety). All three are idempotent,
# so redundant calls are free.
class_name MouseCapture
extends RefCounted

static var _requested_captured := false
# action -> Array[InputEventMouseButton] saved by erase_mouse_bindings().
static var _erased: Dictionary = {}

const _MOUSE_ACTIONS := ["fire", "ads", "grapple"]


static func set_gameplay() -> void:
	Input.emulate_mouse_from_touch = false
	_requested_captured = true
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


static func set_menu() -> void:
	Input.emulate_mouse_from_touch = true
	_requested_captured = false
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


static func is_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


static func requested_captured() -> bool:
	return _requested_captured


static func erase_mouse_bindings() -> void:
	if not _erased.is_empty():
		return
	for action in _MOUSE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var saved: Array[InputEvent] = []
		# action_get_events returns a copy: erasing during this loop is safe.
		for e in InputMap.action_get_events(action):
			if e is InputEventMouseButton:
				saved.append(e)
				InputMap.action_erase_event(action, e)
		if not saved.is_empty():
			_erased[action] = saved


static func restore_mouse_bindings() -> void:
	for action in _erased.keys():
		if not InputMap.has_action(action):
			continue
		for e in _erased[action]:
			var btn := (e as InputEventMouseButton).button_index
			var present := false
			for cur in InputMap.action_get_events(action):
				if cur is InputEventMouseButton and (cur as InputEventMouseButton).button_index == btn:
					present = true
					break
			if not present:
				InputMap.action_add_event(action, e)
	_erased.clear()


static func mouse_bindings_erased() -> bool:
	return not _erased.is_empty()
