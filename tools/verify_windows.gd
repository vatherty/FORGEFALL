# verify_windows.gd — Worker C verification for the FORGEFALL Windows port.
# Full mouse-mode transition matrix + single-source-of-truth scan.
# EXTENDS tools/verify_mouse_capture.gd (Worker A, 22/22) — does not duplicate
# it: Worker A covers the HUD/Forge/focus state machine via requested mode;
# this script adds the ESC paths through the REAL handlers (Main for
# ESC-in-gameplay, pause_menu._input for ESC-in-pause), the ESC-while-Forge
# matrix, the X-button path via the real CloseButton signal, the
# click-to-recapture sequence, the add_look conversion, and a runtime
# single-source-of-truth scan of res://scripts.
#
# HEADLESS LIMIT (same as Worker A): Godot has no display server headless
# and silently ignores MOUSE_MODE_CAPTURED, so live Input.mouse_mode stays
# VISIBLE. Assertions use MouseCapture.requested_captured() (the mode the
# machine ASKED for — on real hardware requested == live) plus the real
# InputMap bindings (erase/restore changes what InputMap matches) plus
# click suppression end-to-end via is_action_just_pressed. The mouse-motion
# LOOK-ON case (camera actually turns while captured) needs a real window:
# headless we prove the gate closes in every menu state, the gate reads
# live is_captured(), and add_look() converts pixels->radians correctly.
# Colin must verify LOOK-ON + capture feel + ESC feel on real hardware.
#
# Usage: godot --headless --path <proj> --script res://tools/verify_windows.gd
extends SceneTree

var _pass := 0
var _fail := 0
var _frame := 0
var _hud: CanvasLayer = null
var _forge: Control = null
var _player: CharacterBody3D = null
var _main: Node = null


func _check(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("WINVERIFY PASS: ", name)
	else:
		_fail += 1
		printerr("WINVERIFY FAIL: ", name)


func _requested_captured() -> bool:
	return MouseCapture.requested_captured()


func _bindings_erased() -> bool:
	return MouseCapture.mouse_bindings_erased()


func _pause_menu() -> Control:
	var pm: Node = get_first_node_in_group("pause_menu")
	if pm is Control:
		return pm as Control
	return null


func _motion_no_turn(label: String) -> void:
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(100, 0)
	var yaw0 := _player.rotation.y
	var head_node: Node3D = _player.get("head")
	var pitch0: float = head_node.rotation.x
	_player._unhandled_input(ev)
	var head_node2: Node3D = _player.get("head")
	_check(label, is_equal_approx(_player.rotation.y, yaw0) and is_equal_approx(head_node2.rotation.x, pitch0))


func _esc_pause_event() -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = "pause"
	ev.pressed = true
	return ev


func _esc_cancel_event() -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	return ev


func _press_x_button() -> void:
	var btn: Node = _forge.find_child("CloseButton", true, false)
	if btn != null and btn.has_method("emit_signal"):
		btn.emit_signal("pressed")
	else:
		_forge.call("close")


func _initialize() -> void:
	MouseCapture.set_menu()
	MouseCapture.restore_mouse_bindings()
	_check("helper starts VISIBLE + bindings present",
		not _requested_captured() and not _bindings_erased())


func _process(_delta: float) -> bool:
	_frame += 1
	match _frame:
		1:
			# --- game start: HUD + Forge + player + Main (real boot shape).
			_hud = (load("res://scenes/ui/hud.tscn") as PackedScene).instantiate()
			root.add_child(_hud)
			_forge = (load("res://scenes/ui/forge_menu.tscn") as PackedScene).instantiate()
			root.add_child(_forge)
			_player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
			root.add_child(_player)
			_main = (load("res://scripts/core/main.gd") as GDScript).new()
			root.add_child(_main)
			# Main boots in MENU; simulate post-start_game state.
			_main.set("state", 1)  # State.PLAYING
			# Main boots into the menu (set_menu) and this harness fakes
			# PLAYING without start_game(); on the real Deploy path the
			# HUD sync establishes gameplay capture once the run starts.
			_hud.call("_sync_mouse_mode")
			_check("game start -> requested CAPTURED + bindings present",
				_requested_captured() and not _bindings_erased())
			var wd: Variant = _hud.get("_mouse_watchdog")
			_check("mouse watchdog exists + PROCESS_MODE_ALWAYS",
				wd != null and wd is Node and (wd as Node).process_mode == Node.PROCESS_MODE_ALWAYS)
			_check("Main in game_root group", _main.is_in_group("game_root"))
		2:
			# --- Forge open via HUD -> VISIBLE + bindings erased.
			_hud.call("_open_forge", true)
			_check("Forge open (HUD) -> requested VISIBLE + bindings erased",
				not _requested_captured() and _bindings_erased())
			_check("Forge menu visible after open", _forge.visible)
			_motion_no_turn("mouse motion with Forge open does NOT turn camera (gate closed)")
			# Menu click must not set fire (binding erased at parse).
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			click.position = Vector2(100, 100)
			Input.parse_input_event(click)
		3:
			_check("menu click does not set fire just_pressed", not Input.is_action_just_pressed("fire"))
			# --- Forge close via the REAL X button (CloseButton.pressed -> close()).
			_press_x_button()
			_check("Forge close (X button) -> requested CAPTURED + bindings present",
				_requested_captured() and not _bindings_erased())
			_check("Forge menu hidden after X close", not _forge.visible)
			# --- Forge open via menu.open() -> VISIBLE + erased; HUD close -> CAPTURED.
			_forge.call("open")
			_check("Forge open (menu.open) -> requested VISIBLE + bindings erased",
				not _requested_captured() and _bindings_erased())
			_hud.call("_open_forge", false)
			_check("Forge close (HUD) -> requested CAPTURED + bindings present",
				_requested_captured() and not _bindings_erased())
			# --- Pause open via HUD button (routes through Main.toggle_pause).
			_hud.call("_on_pause_pressed")
			_check("pause open (HUD button) -> requested VISIBLE + bindings erased",
				not _requested_captured() and _bindings_erased())
			_check("pause open -> tree paused + pause menu visible + Main PAUSED",
				paused and _pause_menu() != null and _pause_menu().visible
				and int(_main.get("state")) == 2)
			_motion_no_turn("mouse motion with pause open does NOT turn camera (gate closed)")
			# --- Pause close via pause_menu.toggle_pause() (Resume-equivalent).
			_pause_menu().call("toggle_pause")
			_hud.call("_sync_mouse_mode")
			_check("pause close (Resume) -> requested CAPTURED + bindings present",
				_requested_captured() and not _bindings_erased())
			_check("pause close -> tree running + pause menu hidden",
				not paused and _pause_menu() != null and not _pause_menu().visible)
			# Harness cleanup: mirror Main.resume() (frees menu, state PLAYING).
			_main.call("resume")
			# resume() queue_frees the menu (deferred): state asserts now,
			# freed-ness asserts at the top of the next frame.
			_check("Main.resume cleanup -> state PLAYING",
				int(_main.get("state")) == 1)
		4:
			_check("prior pause menu freed (deferred queue_free completed)",
				_pause_menu() == null)
			# --- ESC in gameplay via the REAL handler: Main._unhandled_input.
			_main.call("_unhandled_input", _esc_pause_event())
			_hud.call("_sync_mouse_mode")
			_check("ESC in gameplay -> requested VISIBLE + bindings erased",
				not _requested_captured() and _bindings_erased())
			_check("ESC in gameplay -> pause open (tree paused + menu visible + Main PAUSED)",
				paused and _pause_menu() != null and _pause_menu().visible
				and int(_main.get("state")) == 2)
			_check("ESC in gameplay -> never quits (state != MENU, HUD alive)",
				int(_main.get("state")) != 0 and is_instance_valid(_hud))
			_motion_no_turn("mouse motion with ESC-pause open does NOT turn camera (gate closed)")
			# --- ESC in pause via the REAL handler: pause_menu._input (ui_cancel).
			# pause_menu._input marks the event handled, so Main's
			# _unhandled_input never double-toggles on hardware.
			_pause_menu().call("_input", _esc_cancel_event())
			_hud.call("_sync_mouse_mode")
			_check("ESC in pause -> requested CAPTURED + bindings present",
				_requested_captured() and not _bindings_erased())
			_check("ESC in pause -> pause closed (tree running + menu hidden)",
				not paused and _pause_menu() != null and not _pause_menu().visible)
			_main.call("resume")
			_check("ESC round-trip cleanup -> Main PLAYING",
				int(_main.get("state")) == 1)
		5:
			_check("prior pause menu freed (deferred queue_free completed)",
				_pause_menu() == null)
			# --- ESC while Forge is open: pause opens UNDER Forge, mode stays VISIBLE.
			_hud.call("_open_forge", true)
			_check("Forge open (pre-ESC) -> requested VISIBLE", not _requested_captured())
			_main.call("_unhandled_input", _esc_pause_event())
			_hud.call("_sync_mouse_mode")
			_check("ESC with Forge open -> requested VISIBLE + bindings erased + pause open + Forge still open",
				not _requested_captured() and _bindings_erased() and paused
				and _pause_menu() != null and _pause_menu().visible and _forge.visible)
			_motion_no_turn("mouse motion with Forge+pause open does NOT turn camera (gate closed)")
			# --- ESC in pause with Forge still open: pause closes, mode STAYS VISIBLE.
			_pause_menu().call("_input", _esc_cancel_event())
			_hud.call("_sync_mouse_mode")
			_check("ESC in pause with Forge open -> requested VISIBLE (NOT recaptured) + bindings erased",
				not _requested_captured() and _bindings_erased())
			_check("ESC in pause with Forge open -> pause closed, Forge still open",
				not paused and not _pause_menu().visible and _forge.visible)
			# --- Forge X close with no pause -> CAPTURED.
			_press_x_button()
			_check("Forge X close after ESC round-trip -> requested CAPTURED + bindings present",
				_requested_captured() and not _bindings_erased())
			_main.call("resume")
			_check("Forge+ESC cleanup -> Main PLAYING",
				int(_main.get("state")) == 1)
		6:
			_check("prior pause menu freed (deferred queue_free completed)",
				_pause_menu() == null)
			# --- Focus-out (alt-tab) -> VISIBLE + erased + pending.
			_hud.call("_on_window_focus_out")
			_check("focus-out -> requested VISIBLE + bindings erased + pending",
				not _requested_captured() and _bindings_erased()
				and bool(_hud.get("_focus_click_pending")))
			_motion_no_turn("mouse motion after focus-out does NOT turn camera (gate closed)")
			# --- Focus-in -> requested CAPTURED, bindings STILL erased (refocus click must not fire).
			_hud.call("_on_window_focus_in")
			_check("focus-in -> requested CAPTURED + bindings still erased + pending",
				_requested_captured() and _bindings_erased()
				and bool(_hud.get("_focus_click_pending")))
			# The focus click: parsed with the binding gone; HUD._input restores.
			var fclick := InputEventMouseButton.new()
			fclick.button_index = MOUSE_BUTTON_LEFT
			fclick.pressed = true
			fclick.position = Vector2(100, 100)
			Input.parse_input_event(fclick)
		7:
			_check("focus click (recapture click) does NOT set fire just_pressed",
				not Input.is_action_just_pressed("fire"))
			_check("focus click restored bindings + cleared pending",
				not _bindings_erased() and not bool(_hud.get("_focus_click_pending")))
			_check("click-to-recapture -> requested CAPTURED after focus click",
				_requested_captured())
			# --- A later genuine click DOES fire.
			var real := InputEventMouseButton.new()
			real.button_index = MOUSE_BUTTON_LEFT
			real.pressed = true
			real.position = Vector2(100, 100)
			Input.parse_input_event(real)
		8:
			_check("genuine click after recapture DOES set fire", Input.is_action_just_pressed("fire"))
			_check("genuine click leaves bindings present", not _bindings_erased())
			# --- Mouse-motion LOOK contract: add_look converts radians once.
			var yaw0 := _player.rotation.y
			var head_node3: Node3D = _player.get("head")
			var pitch0: float = head_node3.rotation.x
			var sens: float = float(_player.get("look_sensitivity"))
			_player.call("add_look", Vector2(0.1, 0.05))
			var head_node4: Node3D = _player.get("head")
			_check("add_look(0.1, 0.05) yaws by -0.1*sensitivity, pitches by -0.05*sensitivity",
				is_equal_approx(_player.rotation.y, yaw0 - 0.1 * sens)
				and is_equal_approx(head_node4.rotation.x, pitch0 - 0.05 * sens))
			# --- Headless limit, stated as checks: live mode is VISIBLE
			# headless (Godot ignores CAPTURED with no display), requested
			# is CAPTURED. The LOOK-ON case needs a real window (Colin QA).
			_check("HEADLESS LIMIT: live is_captured() false headless while requested CAPTURED",
				not MouseCapture.is_captured() and _requested_captured())
			var yaw1 := _player.rotation.y
			var mev := InputEventMouseMotion.new()
			mev.relative = Vector2(100, 0)
			_player._unhandled_input(mev)
			_check("HEADLESS LIMIT: motion in gameplay does NOT turn headless (gate reads live mode)",
				is_equal_approx(_player.rotation.y, yaw1))
			# --- Single source of truth: runtime scan of res://scripts.
			var violations := _scan_single_source()
			_check("single source of truth: no set_mouse_mode / mouse_mode write outside mouse_capture.gd, no InputMap action edit outside mouse_capture.gd / input_bindings.gd",
				violations.is_empty())
			for v in violations:
				printerr("WINVERIFY VIOLATION: ", v)
			# --- HUD freed (quit-to-menu) -> VISIBLE + bindings present.
			_hud.queue_free()
			_hud = null
		9:
			_check("HUD freed (quit to menu) -> requested VISIBLE + bindings present",
				not _requested_captured() and not _bindings_erased())
			print("WINVERIFY: %d passed, %d failed" % [_pass, _fail])
			quit(1 if _fail > 0 else 0)
	return false


# Recursively scan res://scripts for mouse-mode writes or InputMap
# action edits outside their owners. Full-comment lines are skipped
# (hud.gd documents the helper in comments). Returns violations.
# v0.6.1: mouse_mode writes stay owned by mouse_capture.gd ONLY, but
# InputMap action edits are also owned by input_bindings.gd — the
# controller/rebind system (verify_controller.gd, 896 checks) MUST call
# action_add_event/action_erase_event to apply rebinds; the pre-rebind
# scan rule that flagged any such call outside mouse_capture.gd is
# superseded for that one file. mouse_capture.gd keeps its own
# erase/restore of the fire bindings.
func _scan_single_source() -> Array:
	var violations: Array = []
	_scan_dir("res://scripts", violations)
	return violations


func _scan_dir(path: String, violations: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		violations.append("cannot open dir: " + path)
		return
	for d in dir.get_directories():
		_scan_dir(path + "/" + d, violations)
	for f in dir.get_files():
		if not f.ends_with(".gd"):
			continue
		var full := path + "/" + f
		if full == "res://scripts/input/mouse_capture.gd":
			continue
		var text := FileAccess.get_file_as_string(full)
		if text.is_empty():
			continue
		for line in text.split("\n"):
			var code := line.strip_edges()
			if code.begins_with("#"):
				continue
			if code.contains("set_mouse_mode("):
				violations.append(full + ": calls set_mouse_mode")
			elif code.contains("mouse_mode =") or code.contains("mouse_mode="):
				violations.append(full + ": writes mouse_mode")
			if full != "res://scripts/input/input_bindings.gd" and (code.contains("action_erase_event(") or code.contains("action_add_event(")):
				violations.append(full + ": edits InputMap action bindings")
