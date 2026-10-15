# verify_mouse_capture.gd — Worker A self-check (Windows mouse capture).
# Drives the state machine headless and asserts each transition.
# HEADLESS LIMIT: Godot has no display server headless and silently
# ignores MOUSE_MODE_CAPTURED, so live Input.mouse_mode stays VISIBLE.
# The state machine is therefore asserted via MouseCapture's
# requested_captured() (the mode the machine ASKED for — on real hardware
# requested == live) plus the mouse-button InputMap bindings, which ARE
# real headless (erase/restore changes what InputMap matches). Click
# suppression is asserted end-to-end via is_action_just_pressed.
# Mouse-motion look is asserted OFF while a menu is open (VISIBLE);
# the ON case (turns while captured) needs a real window — the dedicated
# verifier must cover it on hardware (live mode CAN be CAPTURED there).
# Usage: godot --headless --path <proj> --script res://tools/verify_mouse_capture.gd
extends SceneTree

var _pass := 0
var _fail := 0
var _frame := 0
var _hud: CanvasLayer = null
var _forge: Control = null
var _player: CharacterBody3D = null
var _pause: Control = null

func _check(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("MOUSECAP PASS: ", name)
	else:
		_fail += 1
		printerr("MOUSECAP FAIL: ", name)

func _initialize() -> void:
	MouseCapture.set_menu()
	MouseCapture.restore_mouse_bindings()
	_check("helper starts VISIBLE + bindings present",
		not MouseCapture.requested_captured() and not MouseCapture.mouse_bindings_erased())

func _process(_delta: float) -> bool:
	_frame += 1
	match _frame:
		1:
			# --- game start: HUD + Forge menu instanced like Main does.
			_hud = (load("res://scenes/ui/hud.tscn") as PackedScene).instantiate()
			root.add_child(_hud)
			_forge = (load("res://scenes/ui/forge_menu.tscn") as PackedScene).instantiate()
			root.add_child(_forge)
			_check("game start -> requested CAPTURED, bindings present",
				MouseCapture.requested_captured() and not MouseCapture.mouse_bindings_erased())
			_player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
			root.add_child(_player)
		2:
			# --- Forge open via HUD -> VISIBLE + bindings erased.
			_hud.call("_open_forge", true)
			_check("Forge open (HUD) -> requested VISIBLE + bindings erased",
				not MouseCapture.requested_captured() and MouseCapture.mouse_bindings_erased())
			_check("Forge menu visible after open", _forge.visible)
			# Motion while menu open must NOT turn the camera (gate = capture).
			var ev := InputEventMouseMotion.new()
			ev.relative = Vector2(100, 0)
			var yaw0 := _player.rotation.y
			_player._unhandled_input(ev)
			_check("mouse motion with Forge open does NOT turn camera",
				is_equal_approx(_player.rotation.y, yaw0))
			# Menu click must not set fire (binding erased at parse).
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			click.position = Vector2(100, 100)
			Input.parse_input_event(click)
		3:
			_check("menu click does not set fire just_pressed", not Input.is_action_just_pressed("fire"))
			_check("menu click keeps bindings erased (menu still open)",
				MouseCapture.mouse_bindings_erased())
			# --- Forge close via menu's own close() (X-button path).
			_forge.call("close")
			_check("Forge close (X path) -> requested CAPTURED + bindings present",
				MouseCapture.requested_captured() and not MouseCapture.mouse_bindings_erased())
			_check("Forge menu hidden after close", not _forge.visible)
			# --- Forge open via menu's own open() -> VISIBLE + erased.
			_forge.call("open")
			_check("Forge open (menu.open) -> requested VISIBLE + bindings erased",
				not MouseCapture.requested_captured() and MouseCapture.mouse_bindings_erased())
			_hud.call("_open_forge", false)
			_check("Forge close (HUD) -> requested CAPTURED + bindings present",
				MouseCapture.requested_captured() and not MouseCapture.mouse_bindings_erased())
			# --- Pause open (tree paused, menu starts invisible like Main's).
			_pause = (load("res://scenes/ui/pause_menu.tscn") as PackedScene).instantiate()
			root.add_child(_pause)
			_pause.visible = false
			paused = true
			_hud.call("_sync_mouse_mode")
			_check("pause open -> requested VISIBLE + bindings erased",
				not MouseCapture.requested_captured() and MouseCapture.mouse_bindings_erased())
			_check("pause menu forced visible while paused", _pause.visible)
			# --- ESC in pause: pause_menu toggles (resume).
			paused = false
			_pause.visible = false
			_pause.queue_free()
			_pause = null
			_hud.call("_sync_mouse_mode")
			_check("pause close (ESC resume) -> requested CAPTURED + bindings present",
				MouseCapture.requested_captured() and not MouseCapture.mouse_bindings_erased())
		4:
			# --- Focus-out (alt-tab) -> VISIBLE + erased + pending.
			_hud.call("_on_window_focus_out")
			_check("focus-out -> requested VISIBLE + bindings erased + pending",
				not MouseCapture.requested_captured()
				and MouseCapture.mouse_bindings_erased()
				and bool(_hud.get("_focus_click_pending")))
			# --- Focus-in -> requested CAPTURED, bindings STILL erased
			# (restoring here would let the refocus click fire).
			_hud.call("_on_window_focus_in")
			_check("focus-in -> requested CAPTURED + bindings still erased + pending",
				MouseCapture.requested_captured()
				and MouseCapture.mouse_bindings_erased()
				and bool(_hud.get("_focus_click_pending")))
			# The focus click: parsed with the binding gone; the next
			# frame's pump dispatches it to HUD._input, which restores.
			var fclick := InputEventMouseButton.new()
			fclick.button_index = MOUSE_BUTTON_LEFT
			fclick.pressed = true
			fclick.position = Vector2(100, 100)
			Input.parse_input_event(fclick)
		5:
			_check("focus click does NOT set fire just_pressed", not Input.is_action_just_pressed("fire"))
			_check("focus click restored bindings + cleared pending",
				not MouseCapture.mouse_bindings_erased() and not bool(_hud.get("_focus_click_pending")))
			# --- A later genuine click DOES fire.
			var real := InputEventMouseButton.new()
			real.button_index = MOUSE_BUTTON_LEFT
			real.pressed = true
			real.position = Vector2(100, 100)
			Input.parse_input_event(real)
		6:
			_check("genuine click after recapture DOES set fire", Input.is_action_just_pressed("fire"))
			_check("genuine click leaves bindings present",
				not MouseCapture.mouse_bindings_erased())
			# --- HUD pause button path (no Main in this harness: falls
			# back to nothing, must not crash, must keep sane state).
			_hud.call("_on_pause_pressed")
			_check("pause button press keeps requested CAPTURED + bindings present",
				MouseCapture.requested_captured() and not MouseCapture.mouse_bindings_erased())
			# --- HUD freed (quit-to-menu) -> VISIBLE + bindings present.
			_hud.queue_free()
			_hud = null
		7:
			_check("HUD freed (quit to menu) -> requested VISIBLE + bindings present",
				not MouseCapture.requested_captured() and not MouseCapture.mouse_bindings_erased())
			print("MOUSECAP: %d passed, %d failed" % [_pass, _fail])
			quit(1 if _fail > 0 else 0)
	return false
