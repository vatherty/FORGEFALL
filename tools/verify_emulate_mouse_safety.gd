# tools/verify_emulate_mouse_safety.gd — v0.6.6 intake probe (GPT patch).
# Usage: godot --headless --path <project> --script res://tools/verify_emulate_mouse_safety.gd
#
# v0.5.1 set pointing/emulate_mouse_from_touch=false ON PURPOSE: with it
# true, every Android tap synthesizes a mouse click and `fire` is bound to
# mouse button 1 — ANY tap fired the gun. The GPT mobile-HUD patch flips
# the project default back to true and instead toggles
# Input.emulate_mouse_from_touch at runtime via MouseCapture
# (set_gameplay -> false, set_menu -> true).
#
# This suite proves BEHAVIORALLY, through the real game, that the flip
# cannot reintroduce tap-to-fire, in every state Colin named:
#   main menu, deploy/loading transition, live gameplay, Forge menu open
#   mid-match, pause menu, death/redeploy window.
# The safety invariant sampled EVERY frame of every state:
#   SAFE := emulate_mouse_from_touch == false
#        OR mouse bindings for fire/ads/grapple are erased (MouseCapture)
#        OR no live player weapon exists (menu / not yet deployed / dead)
# In menu states it also proves the injected event still flows through
# the input pipeline (the same injection presses `fire` in gameplay
# state) — menus on device consume exactly this event type via the
# engine's touch->mouse emulation. NOTE: Control gui_input picking of
# injected events is NOT reproducible in the headless --script runner
# (probe-verified: gui_input never fires headless), so GUI consumption
# itself is asserted on device, not here.
# Exit 0 = all checks pass.
extends SceneTree

var _passes := 0
var _fails := 0
var _main: Node = null
var _phase := "boot"
var _frames := 0
var _invariant_violations := 0
var _saw_dead := false
var _death_frames := 0
var _btn_presses := 0


func _pass(label: String) -> void:
	_passes += 1
	print("  PASS: " + label)


func _fail(label: String, detail: String) -> void:
	_fails += 1
	printerr("  FAIL: " + label + " — " + detail)


func _check(label: String, cond: bool, detail := "") -> void:
	if cond:
		_pass(label)
	else:
		_fail(label, detail)


func _live_weapon() -> bool:
	for p in get_nodes_in_group("player"):
		if not bool(p.get("_dead")):
			return true
	return false


func _safe() -> bool:
	if not Input.emulate_mouse_from_touch:
		return true
	if MouseCapture.mouse_bindings_erased():
		return true
	return not _live_weapon()


func _sample() -> void:
	if not _safe():
		_invariant_violations += 1
		if _invariant_violations <= 6:
			var np := 0
			var dead := true
			for p in get_nodes_in_group("player"):
				np += 1
				dead = dead and bool(p.get("_dead"))
			print("  VIOLATION phase=%s frames=%d state=%s emulate=%s erased=%s players=%d all_dead=%s hud=%s" % [
				_phase, _frames, _main.get("state"), Input.emulate_mouse_from_touch,
				MouseCapture.mouse_bindings_erased(), np, dead, _main.get("_hud") != null])


func _click(pressed: bool, pos := Vector2(640, 360)) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _initialize() -> void:
	print("VERIFY_EMULATE_MOUSE_SAFETY: tap-can-never-fire, all states")
	var ps := load("res://scenes/main.tscn") as PackedScene
	_main = ps.instantiate()
	root.add_child(_main)
	current_scene = _main


func _process(_delta: float) -> bool:
	_frames += 1
	_sample()
	match _phase:
		"boot":
			# Wait for the main menu state.
			if _frames > 10:
				_check("menu: state is MENU", int(_main.get("state")) == 0,
					"state=%s" % _main.get("state"))
				_check("menu: emulate ON (menus receive emulated taps)",
					Input.emulate_mouse_from_touch == true)
				_check("menu: no player exists (nothing can fire)",
					get_nodes_in_group("player").is_empty())
				_click(true)
				_click(false)
				_check("menu: background click creates no live fire risk",
					not _live_weapon())
				# Tower Defense: the mode where Forge building is allowed
				# (ForgeGate refuses the HUD Forge path in other modes) and
				# whose build phase opens the Forge menu itself — the real
				# mid-match Forge-open state.
				(load("res://scripts/core/game_mode.gd") as GDScript).set(
					"selected_mode", "tower_defense")
				_main.start_game()
				_phase = "deploying"
				_frames = 0
		"deploying":
			if int(_main.get("state")) == 1:  # State.PLAYING
				_check("deploy: reached PLAYING", true)
				_check("deploy: zero invariant violations during load",
					_invariant_violations == 0,
					"%d violations" % _invariant_violations)
				_phase = "playing_settle"
				_frames = 0
			elif _frames > 1500:
				_fail("deploy", "never reached PLAYING")
				_finish()
		"playing_settle":
			# Wait out the loading screen's "Ready" beat (while it is up,
			# the HUD correctly treats UI as open: set_menu + erased —
			# safe by the invariant, but not steady-state gameplay).
			# Then let the HUD's mouse-mode sync settle.
			if _main.get_node_or_null("MapLoadingScreen") == null and _frames > 3:
				# Default mode is "survival" (build-phase family): deploy
				# LEGITIMATELY ends with the Forge menu open for the build
				# phase. That is a menu state — assert it is the SAFE one
				# (emulate on + bindings erased), then close Forge to reach
				# true gameplay steady state.
				var hudx: Node = _main.get("_hud")
				_check("build phase: Forge open is a SAFE menu state (emulate on, bindings erased)",
					Input.emulate_mouse_from_touch
					and MouseCapture.mouse_bindings_erased(),
					"emulate=%s erased=%s" % [Input.emulate_mouse_from_touch,
						MouseCapture.mouse_bindings_erased()])
				hudx.call("_open_forge", false)
				_phase = "playing_steady"
				_frames = 0
			elif _frames > 900:
				_fail("playing_settle", "loading screen never dismissed")
				_finish()
		"playing_steady":
			if _frames == 5:
				_check("gameplay: emulate OFF (no synthesized mouse)",
					Input.emulate_mouse_from_touch == false)
				_check("gameplay: player alive with weapon", _live_weapon())
				_click(true)
				_check("gameplay: real mouse click DOES press fire (desktop intact)",
					Input.is_action_pressed("fire"))
				_click(false)
				_phase = "forge_open"
				_frames = 0
		"forge_open":
			if _frames == 2:
				var hud: Node = _main.get("_hud")
				hud.call("_open_forge", true)
			elif _frames == 6:
				_check("forge open: emulate ON (menu taps work)",
					Input.emulate_mouse_from_touch == true)
				_check("forge open: mouse bindings ERASED (tap cannot fire)",
					MouseCapture.mouse_bindings_erased())
				_click(true)
				_check("forge open: click does NOT press fire",
					not Input.is_action_pressed("fire"))
				_check("forge open: click does NOT press ads",
					not Input.is_action_pressed("ads"))
				_check("forge open: click does NOT press grapple",
					not Input.is_action_pressed("grapple"))
				_click(false)
				_phase = "forge_close"
				_frames = 0
		"forge_close":
			if _frames == 2:
				# Hold a click that BEGINS while bindings are erased...
				_click(true)
				var hud2: Node = _main.get("_hud")
				hud2.call("_open_forge", false)
			elif _frames == 6:
				_check("forge close: emulate OFF again",
					Input.emulate_mouse_from_touch == false)
				_check("forge close: held menu click did NOT become fire",
					not Input.is_action_pressed("fire"))
				_click(false)
				_click(true)
				_check("forge close: fresh gameplay click fires again",
					Input.is_action_pressed("fire"))
				_click(false)
				_phase = "pause"
				_frames = 0
		"pause":
			if _frames == 2:
				_main.toggle_pause()
			elif _frames == 8:
				_check("pause: emulate ON + bindings ERASED",
					Input.emulate_mouse_from_touch
					and MouseCapture.mouse_bindings_erased(),
					"emulate=%s erased=%s" % [Input.emulate_mouse_from_touch,
						MouseCapture.mouse_bindings_erased()])
				_click(true)
				_check("pause: click does NOT press fire",
					not Input.is_action_pressed("fire"))
				_click(false)
				_main.toggle_pause()
				_phase = "death"
				_frames = 0
		"death":
			if _frames == 4:
				_check("resume: emulate OFF after pause closes",
					Input.emulate_mouse_from_touch == false)
				for p in get_nodes_in_group("player"):
					p.take_damage(1000000.0, (p as Node3D).global_position, false)
			elif _frames > 4:
				_death_frames += 1
				for p in get_nodes_in_group("player"):
					if bool(p.get("_dead")):
						_saw_dead = true
				if _saw_dead and _death_frames > 30 and not _live_weapon():
					pass  # still in the death window; invariant is sampled
				if _death_frames > 400:
					_check("death: player actually died", _saw_dead)
					_check("death/redeploy: zero invariant violations",
						_invariant_violations == 0,
						"%d violations" % _invariant_violations)
					_finish()
		"done":
			return true
	return false


func _finish() -> void:
	print("VERIFY_EMULATE_MOUSE_SAFETY: %d passed, %d failed" % [_passes, _fails])
	_phase = "done"
	quit(1 if _fails > 0 else 0)
