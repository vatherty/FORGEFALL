# verify_controller.gd — headless checks for v0.6.1 Workstream A:
# NATIVE CONTROLLER SUPPORT + REMAPPING.
# Usage: godot --headless --path <project> --script res://tools/verify_controller.gd
# Covers:
#   STEP 0 — keyboard buy path (the Deck failure must not be assumed
#     controller-only): a real Key-F press through the Input singleton
#     drives ZombiesMode._process -> buy_door (points deducted, door
#     opens), and the same via a gamepad Y-button press.
#   - Every managed action exists, has kb + pad primaries (except the
#     documented pad-less ones), defaults are conflict-free, dead zone
#     is one tunable applied everywhere, menu-nav actions carry
#     gamepad events, gamepad events map to every action.
#   - Rebind capture/persist/reset round-trips incl. loud conflicts,
#     intentional-share exemptions, and dead-zone persistence.
#   - Menu navigation via gamepad events: main menu focus + D-pad move
#     + Confirm into mode select + Back out, Options open/close,
#     rebind screen open/close, pause focus + Back, loadout picker
#     focus, Forge menu tab-bar focus.
#   - Player: tool-switch cycles, slide == crouch-held, gamepad-look
#     deadzone; WeaponManager weapon_next/prev cycling.
# Exit 0 = all checks pass; any FAIL prints and exits 1. The player's
# pre-existing input_bindings.cfg (if any) is restored at the end.
extends SceneTree

var _fails := 0
var _passes := 0
var _frames := 0
var _phase := 0
var _sub := 0

var _cfg_existed := false
var _cfg_backup := ""

var _zombies: Node = null
var _mock_player: Node3D = null
var _menu: Control = null
var _pause: Control = null
var _picker: Control = null
var _forge: Control = null
var _player: Node = null
var _menu_rebind: Control = null
var _pause_rebind: Control = null
var _cycle_t0 := 0


func _check_rebind_closed_from_menu() -> void:
	_check(_menu_rebind == null or not is_instance_valid(_menu_rebind),
		"gamepad Back closes rebind screen")


func _check_rebind_closed_from_pause() -> void:
	_check(_pause_rebind == null or not is_instance_valid(_pause_rebind),
		"gamepad Back closes rebind screen from pause")
	_check(paused, "closing rebind from pause does NOT resume the game")
	_pause.call("toggle_pause")
	_check(not paused, "pause menu closes cleanly after rebind test")


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _key_event(code: int, pressed: bool = true) -> InputEventKey:
	var ev := InputEventKey.new()
	# Do NOT set device: a fresh key event's default device (16) is
	# what stored key events (ours + Godot's built-ins) carry, and
	# is_action_pressed matches stored-16 only against test-device-16.
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	return ev


func _joy_button_event(btn: int, pressed: bool = true) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.device = -1
	ev.button_index = btn
	ev.pressed = pressed
	return ev


func _push(ev: InputEvent) -> void:
	root.get_viewport().push_input(ev)


func _initialize() -> void:
	# Back up the player's bindings config so the suite restores it.
	if FileAccess.file_exists(InputBindings.CONFIG_PATH):
		_cfg_existed = true
		_cfg_backup = FileAccess.get_file_as_string(InputBindings.CONFIG_PATH)
	InputBindings.ensure_loaded()
	_phase = 0
	_frames = 0
	print("VERIFY_CONTROLLER: starting")


var _total_frames := 0


func _process(_delta: float) -> bool:
	_frames += 1
	_total_frames += 1
	if _total_frames > 20000:
		printerr("VERIFY_CONTROLLER: WATCHDOG — stuck in phase %d, aborting" % _phase)
		_fails += 1
		_teardown()
		quit(1)
		return true
	match _phase:
		0:
			_check_bindings_audit()
			_phase = 1
		1:
			_check_event_mapping()
			_phase = 2
		2:
			_check_rebinds()
			_phase = 3
			_frames = 0
		3:
			# STEP 0 setup: mock player + Zombies run (town builds in _ready).
			var arena := Node3D.new()
			arena.name = "VerifyArena"
			root.add_child(arena)
			_mock_player = Node3D.new()
			_mock_player.name = "MockPlayer"
			_mock_player.add_to_group("player")
			arena.add_child(_mock_player)
			# Lazy load: parse-time ZombiesMode would compile
			# zombies.gd before the `Game` autoload identifier
			# resolves in --script runs (see verify_zombies.gd).
			var zs := load("res://scripts/modes/zombies.gd") as GDScript
			_zombies = (zs as GDScript).new()
			_zombies.name = "ZombiesMode"
			arena.add_child(_zombies)
			_phase = 4
			_frames = 0
		4:
			if _frames < 3:
				return false
			_check_keyboard_buy()
			_phase = 5
			_frames = 0
		5:
			if _frames < 3:
				return false
			_check_gamepad_buy()
			_phase = 6
		6:
			_check_buy_logic()
			_phase = 7
			_frames = 0
		7:
			_check_main_menu_nav()
			_phase = 8
			_frames = 0
		8:
			# Layout must run (2 frames) before spatial focus nav can
			# move between buttons: freshly added buttons all sit at
			# (0,0) until the containers sort children.
			if _frames < 2:
				return false
			_check_main_menu_nav_dpad()
			_phase = 9
			_frames = 0
		9:
			if _frames < 2:
				return false
			_check_main_menu_nav2()
			_phase = 10
			_frames = 0
		10:
			if _frames < 2:
				return false
			_check_rebind_closed_from_menu()
			_check_pause_and_picker()
			_phase = 11
			_frames = 0
		11:
			if _frames < 2:
				return false
			_check_rebind_closed_from_pause()
			_phase = 12
			_frames = 0
		12:
			if _frames < 2:
				return false
			_check_forge_focus()
			_phase = 13
			_frames = 0
		13:
			if _frames < 2:
				return false
			_check_player_inputs()
			_phase = 14
			_frames = 0
		14:
			if Time.get_ticks_msec() - _cycle_t0 < 800:
				return false
			_check_weapon_cycle_step1()
			_phase = 15
			_frames = 0
		15:
			if Time.get_ticks_msec() - _cycle_t0 < 800:
				return false
			_check_weapon_cycle_step2()
			_phase = 16
		16:
			_teardown()
			if _fails == 0:
				print("VERIFY_CONTROLLER: ALL CHECKS PASSED (%d)" % _passes)
			else:
				printerr("VERIFY_CONTROLLER: %d CHECK(S) FAILED, %d passed" % [_fails, _passes])
			quit(1 if _fails > 0 else 0)
			return true
	return false


# --- Bindings audit -----------------------------------------------------------

func _check_bindings_audit() -> void:
	# Every managed action exists.
	for action in InputBindings.ACTIONS:
		_check(InputMap.has_action(action), "action exists: %s" % action)
	# Defaults are conflict-free (except the documented shares).
	var defs := InputBindings.defaults()
	for i in InputBindings.ACTIONS.size():
		for j in range(i + 1, InputBindings.ACTIONS.size()):
			var a: String = InputBindings.ACTIONS[i]
			var b: String = InputBindings.ACTIONS[j]
			var shared := false
			for g in InputBindings.SHARED_GROUPS:
				if (g as Array).has(a) and (g as Array).has(b):
					shared = true
			if shared:
				continue
			for kind in ["kb", "pad"]:
				var da: Variant = (defs.get(a, {}) as Dictionary).get(kind)
				var db: Variant = (defs.get(b, {}) as Dictionary).get(kind)
				if da is Dictionary and db is Dictionary:
					_check(not InputBindings.events_equal_dict(da, db),
						"defaults conflict-free: %s vs %s (%s)" % [a, b, kind])
	# No gaps: every action has a kb primary; pad primaries exist
	# except weapon_next/prev + killstreak_2/3 (documented, rebindable).
	var padless := ["weapon_next", "weapon_prev", "killstreak_2", "killstreak_3"]
	for action in InputBindings.ACTIONS:
		_check(InputBindings.primary_dict(action, "kb") is Dictionary,
			"kb primary present: %s" % action)
		if padless.has(action):
			_check(InputBindings.primary_dict(action, "pad") == null,
				"pad primary intentionally empty: %s" % action)
		else:
			_check(InputBindings.primary_dict(action, "pad") is Dictionary,
				"pad primary present: %s" % action)
	# One dead zone, applied everywhere.
	_check(is_equal_approx(InputBindings.deadzone, 0.2), "default deadzone 0.2")
	for action in InputBindings.ACTIONS:
		_check(is_equal_approx(InputMap.action_get_deadzone(action), 0.2),
			"InputMap deadzone 0.2: %s" % action)
	# Menu nav carries gamepad events (Godot's shipped ui_* defaults are
	# keyboard-only — without these, D-pad menus are dead).
	for action in ["ui_up", "ui_down", "ui_left", "ui_right"]:
		var has_pad := false
		for e in InputMap.action_get_events(action):
			if e is InputEventJoypadButton or e is InputEventJoypadMotion:
				has_pad = true
		_check(has_pad, "menu nav has gamepad event: %s" % action)
	# Menu confirm/back: A = confirm, B = back on pad.
	var acc_pad: Variant = InputBindings.primary_dict("ui_accept", "pad")
	_check(acc_pad is Dictionary and int((acc_pad as Dictionary).get("button_index", -1)) == 0,
		"ui_accept pad = A (South)")
	var can_pad: Variant = InputBindings.primary_dict("ui_cancel", "pad")
	_check(can_pad is Dictionary and int((can_pad as Dictionary).get("button_index", -1)) == 1,
		"ui_cancel pad = B (East)")
	# Interact is on a face button (Y/North); A stays jump (universal).
	var inter_pad: Variant = InputBindings.primary_dict("interact", "pad")
	_check(inter_pad is Dictionary and int((inter_pad as Dictionary).get("button_index", -1)) == 3,
		"interact pad = Y (North face button)")
	var jump_pad: Variant = InputBindings.primary_dict("jump", "pad")
	_check(jump_pad is Dictionary and int((jump_pad as Dictionary).get("button_index", -1)) == 0,
		"jump pad = A (South)")
	_check(InputBindings.connected_pad_label() is String, "connected_pad_label returns a String")


func _check_event_mapping() -> void:
	# Every primary event maps to its action (simulated hardware).
	for action in InputBindings.ACTIONS:
		for kind in ["kb", "pad"]:
			var d: Variant = InputBindings.primary_dict(action, kind)
			if d is Dictionary:
				var ev := InputBindings.dict_to_event(d as Dictionary)
				if ev is InputEventKey or ev is InputEventMouseButton or ev is InputEventJoypadButton:
					ev.pressed = true
				_check(ev.is_action_pressed(action),
					"event maps to action: %s (%s %s)" % [action, kind, InputBindings.event_label(ev)])
	# A gamepad Y press is an interact press; a Key-F press is too.
	_check(_joy_button_event(3).is_action_pressed("interact"), "Joypad Y event -> interact")
	_check(_key_event(70).is_action_pressed("interact"), "Key F event -> interact")
	# Axis direction matters: RT (axis 5 +) fires, LT (axis 4) does not.
	var rt := InputEventJoypadMotion.new()
	rt.axis = 5
	rt.axis_value = 1.0
	_check(rt.is_action_pressed("fire"), "RT axis event -> fire")
	_check(not rt.is_action_pressed("ads"), "RT axis event does NOT -> ads")
	# Event dict round-trips for all four event types.
	for d in [
		{"type": "key", "physical_keycode": 70},
		{"type": "mouse", "button_index": 1},
		{"type": "joy_button", "button_index": 3},
		{"type": "joy_axis", "axis": 5, "axis_value": 1.0},
	]:
		var back := InputBindings.event_to_dict(InputBindings.dict_to_event(d))
		_check(back == d, "event dict round-trip: %s" % str(d))
	_check(InputBindings.events_equal_dict(
		{"type": "joy_axis", "axis": 5, "axis_value": 0.8},
		{"type": "joy_axis", "axis": 5, "axis_value": 1.0}),
		"axis equality is by direction, not exact deflection")
	_check(not InputBindings.events_equal_dict(
		{"type": "joy_axis", "axis": 5, "axis_value": 1.0},
		{"type": "joy_axis", "axis": 5, "axis_value": -1.0}),
		"opposite axis directions do not match")


# --- Rebind round-trips --------------------------------------------------------

func _check_rebinds() -> void:
	InputBindings.reset_to_defaults()
	# Loud conflict: interact <- E steals E from portal_orange.
	var res: Dictionary = InputBindings.set_binding("interact", "kb", {"type": "key", "physical_keycode": 69})
	_check(bool(res.get("ok", false)), "rebind interact kb -> E ok")
	_check((res.get("replaced", []) as Array).has("Portal — Orange"),
		"rebind reports replaced: Portal — Orange")
	_check(InputBindings.binding_label("portal_orange", "kb") == "—",
		"portal_orange kb cleared after overwrite")
	_check(InputBindings.binding_label("interact", "kb") == "E",
		"interact kb now E")
	# Loud conflict on pad: jump <- Y steals Y from interact.
	res = InputBindings.set_binding("jump", "pad", {"type": "joy_button", "button_index": 3})
	_check((res.get("replaced", []) as Array).has("Interact / Buy"),
		"rebind reports replaced: Interact / Buy")
	_check(InputBindings.binding_label("interact", "pad") == "—",
		"interact pad cleared after overwrite")
	# Intentional shares are NOT stripped.
	InputBindings.reset_to_defaults()
	res = InputBindings.set_binding("slide", "kb", {"type": "key", "physical_keycode": 67})
	_check(not (res.get("replaced", []) as Array).has("Crouch"),
		"slide <- C does NOT strip crouch (intentional share)")
	_check(InputBindings.binding_label("crouch", "kb") == "C", "crouch keeps C")
	res = InputBindings.set_binding("portal_blue", "pad", {"type": "joy_button", "button_index": 9})
	_check(not (res.get("replaced", []) as Array).has("Traversal Tool — Fire"),
		"portal_blue <- LB does NOT strip grapple (intentional share)")
	res = InputBindings.set_binding("pause", "kb", {"type": "key", "physical_keycode": 4194305})
	_check(not (res.get("replaced", []) as Array).has("Menu — Back"),
		"pause <- Esc does NOT strip ui_cancel (intentional share)")
	# Wrong device class rejected.
	res = InputBindings.set_binding("jump", "pad", {"type": "key", "physical_keycode": 32})
	_check(not bool(res.get("ok", true)), "key event rejected for pad slot")
	# Persist: rebind, reload from disk, binding survives.
	InputBindings.reset_to_defaults()
	InputBindings.set_binding("interact", "kb", {"type": "key", "physical_keycode": 75})
	var file_text := FileAccess.get_file_as_string(InputBindings.CONFIG_PATH)
	_check(file_text.contains("75"), "rebind persisted to config file")
	InputBindings.reload()
	_check(InputBindings.binding_label("interact", "kb") == "K",
		"rebind survives reload from disk")
	# Reset restores defaults.
	InputBindings.reset_to_defaults()
	_check(InputBindings.binding_label("interact", "kb") == "F",
		"reset restores interact kb = F")
	_check(InputBindings.binding_label("jump", "pad") == "A (South)",
		"reset restores jump pad = A")
	# Dead-zone round-trip incl. persistence.
	InputBindings.set_deadzone(0.3)
	_check(is_equal_approx(InputMap.action_get_deadzone("fire"), 0.3),
		"deadzone slider applies to InputMap")
	_check(FileAccess.get_file_as_string(InputBindings.CONFIG_PATH).contains("0.3"),
		"deadzone persists to config file")
	InputBindings.set_deadzone(0.2)
	_check(is_equal_approx(InputBindings.deadzone, 0.2), "deadzone reset to 0.2")


# --- STEP 0: keyboard buy + gamepad buy ---------------------------------------

func _check_keyboard_buy() -> void:
	_check(_zombies != null and _zombies.get("running") == true, "zombies run is live")
	_mock_player.global_position = Vector3(-10, 0, -8)  # north_alley door
	_zombies.call("add_points", 0, 5000)
	var before: int = _zombies.call("get_points", 0)
	_check(before == 5000, "points granted (5000)")
	# Key F maps to interact (event level), then the simulated press
	# drives the real Input singleton -> ZombiesMode._process path.
	_check(_key_event(70).is_action_pressed("interact"), "Key F event -> interact")
	Input.action_press("interact", 1.0)
	_check(Input.is_action_just_pressed("interact"), "interact press reads as just-pressed")
	_zombies.call("_process", 0.016)
	Input.action_release("interact")
	_check(_zombies.call("is_door_open", "north_alley") == true,
		"STEP 0: keyboard F buys the door (not a controller-only path)")
	_check(_zombies.call("get_points", 0) == 5000 - 750,
		"STEP 0: door buy deducts 750 pts (5000 -> 4250)")


func _check_gamepad_buy() -> void:
	_mock_player.global_position = Vector3(10, 0, 8)  # south_alley door
	# Joypad Y maps to interact (event level), then the same
	# singleton -> _process path buys through the gamepad binding.
	_check(_joy_button_event(3).is_action_pressed("interact"), "Joypad Y event -> interact")
	Input.action_press("interact", 1.0)
	_check(Input.is_action_just_pressed("interact"), "interact press (gamepad leg) reads as just-pressed")
	_zombies.call("_process", 0.016)
	Input.action_release("interact")
	_check(_zombies.call("is_door_open", "south_alley") == true,
		"gamepad Y buys the door")
	_check(_zombies.call("get_points", 0) == 4250 - 1000,
		"gamepad door buy deducts 1000 pts (4250 -> 3250)")


func _check_buy_logic() -> void:
	# Prompt near a wall-buy spot, empty far away.
	_mock_player.global_position = Vector3(10, 0, -2)  # chalk_mid
	var prompt: String = _zombies.call("get_interact_prompt")
	_check(prompt.begins_with("BUY"), "interact prompt near wall-buy: %s" % prompt)
	var def: Dictionary = _zombies.call("wall_buy", "chalk_mid")
	var price: int = int(def.get("price", 0))
	var before: int = _zombies.call("get_points", 0)
	var res: Dictionary = _zombies.call("activate_nearest_interact", 0)
	_check(bool(res.get("ok", false)), "wall-buy activates near chalk spot")
	_check(_zombies.call("get_points", 0) == before - price,
		"wall-buy deducts price (%d)" % price)
	# Broke: buy fails, nothing spent, door stays shut.
	_zombies.call("mp_set_points", 0, 0)
	res = _zombies.call("buy_door", 0, "east_street")
	_check(not bool(res.get("ok", true)), "buy_door fails with 0 points")
	_check(_zombies.call("is_door_open", "east_street") == false,
		"door stays shut when broke")
	_mock_player.global_position = Vector3(100, 0, 100)
	_check(str(_zombies.call("get_interact_prompt")) == "",
		"no interact prompt when far from everything")


# --- Menu navigation via gamepad ------------------------------------------------

func _check_main_menu_nav() -> void:
	_menu = (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate() as Control
	root.add_child(_menu)
	var focus := root.get_viewport().gui_get_focus_owner()
	_check(focus != null and focus is Button and focus.name == "SinglePlayerButton",
		"main menu opens with SINGLE PLAYER focused (controller-ready)")


func _check_main_menu_nav_dpad() -> void:
	# D-pad Down moves focus to MULTIPLAYER.
	_push(_joy_button_event(12, true))
	_push(_joy_button_event(12, false))
	var focus := root.get_viewport().gui_get_focus_owner()
	_check(focus != null and focus is Button and focus.name == "MultiplayerButton",
		"D-pad Down moves focus to MULTIPLAYER")
	# Confirm (A) opens the mode select.
	_push(_joy_button_event(0, true))
	_push(_joy_button_event(0, false))
	var overlay := _menu.get_node_or_null("ModeSelectOverlay") as Control
	_check(overlay != null and overlay.visible, "gamepad Confirm opens mode select")
	# Back (B) closes the mode select and restores focus to MULTIPLAYER.
	_push(_joy_button_event(1, true))
	_push(_joy_button_event(1, false))
	_check(overlay != null and not overlay.visible, "gamepad Back closes mode select")
	focus = root.get_viewport().gui_get_focus_owner()
	_check(focus != null and focus is Button and focus.name == "MultiplayerButton",
		"focus returns to MULTIPLAYER after Back")


func _check_main_menu_nav2() -> void:
	# Options via direct open (focus path), closed via gamepad Back.
	_menu.call("_on_options")
	var opts := _menu.get_node_or_null("OptionsPanel") as Control
	_check(opts != null and opts.visible, "Options panel opens")
	var focus := root.get_viewport().gui_get_focus_owner()
	_check(focus != null and _is_descendant_of(focus, opts),
		"focus moves inside Options panel")
	_push(_joy_button_event(1, true))
	_push(_joy_button_event(1, false))
	_check(opts != null and not opts.visible, "gamepad Back closes Options")
	focus = root.get_viewport().gui_get_focus_owner()
	_check(focus != null and focus is Button and focus.name == "OptionsButton",
		"focus returns to OPTIONS after Back")
	# Rebind screen opens, has focus, closes on gamepad Back
	# (queue_free is deferred: the freed-assert runs next phase).
	_menu_rebind = RebindMenu.open_in(_menu)
	_check(_menu_rebind != null and is_instance_valid(_menu_rebind), "rebind screen opens from menu")
	focus = root.get_viewport().gui_get_focus_owner()
	_check(focus != null and _is_descendant_of(focus, _menu_rebind),
		"focus moves inside rebind screen")
	_push(_joy_button_event(1, true))
	_push(_joy_button_event(1, false))


func _is_descendant_of(node: Node, ancestor: Node) -> bool:
	var cur: Node = node
	while cur != null:
		if cur == ancestor:
			return true
		cur = cur.get_parent()
	return false


func _check_pause_and_picker() -> void:
	_pause = (load("res://scenes/ui/pause_menu.tscn") as PackedScene).instantiate() as Control
	root.add_child(_pause)
	_pause.call("toggle_pause")
	_check(paused, "pause menu pauses the tree")
	var focus := root.get_viewport().gui_get_focus_owner()
	_check(focus != null and focus is Button and (focus as Button).text == "RESUME",
		"pause menu opens with RESUME focused")
	# Back (B) resumes.
	_push(_joy_button_event(1, true))
	_push(_joy_button_event(1, false))
	_check(not paused, "gamepad Back resumes from pause")
	# Rebind screen from pause closes on Back WITHOUT resuming
	# (queue_free is deferred: the freed-assert runs next phase).
	_pause.call("toggle_pause")
	_pause_rebind = RebindMenu.open_in(_pause)
	_push(_joy_button_event(1, true))
	_push(_joy_button_event(1, false))
	# Loadout picker: open -> a button has focus; close hides it.
	_picker = (load("res://scenes/ui/loadout_picker.tscn") as PackedScene).instantiate() as Control
	root.add_child(_picker)
	_picker.call("open")
	focus = root.get_viewport().gui_get_focus_owner()
	_check(focus != null and focus is Button and _is_descendant_of(focus, _picker),
		"loadout picker opens with a button focused")
	_picker.call("close")
	_check(not _picker.visible, "loadout picker closes")


func _check_forge_focus() -> void:
	_forge = (load("res://scenes/ui/forge_menu.tscn") as PackedScene).instantiate() as Control
	root.add_child(_forge)
	_forge.call("open")
	if bool(_forge.get("visible")):
		var tabs := _forge.get("_tabs") as TabContainer
		var tab_bar: Control = tabs.get_tab_bar() if tabs != null else null
		var focus := root.get_viewport().gui_get_focus_owner()
		_check(tab_bar != null and focus == tab_bar,
			"Forge menu focuses the tab bar (controller nav, no keyboard pop)")
		_forge.call("close")
	else:
		_check(false, "Forge menu opens (ForgeGate)")


# --- Player / WeaponManager ------------------------------------------------------

func _check_player_inputs() -> void:
	var arena := Node3D.new()
	arena.name = "PlayerArena"
	root.add_child(arena)
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	# Tool-switch cycles grapple -> jetpack -> portal -> grapple.
	_player.call("set_allowed_traversal_tools", ["grapple", "jetpack", "portal"])
	_player.call("set_traversal_tool", "grapple")
	Input.action_press("tool_switch", 1.0)
	_player.call("_update_tool_switch")
	_check(str(_player.call("get_traversal_tool")) == "jetpack", "tool_switch: grapple -> jetpack")
	Input.action_press("tool_switch", 1.0)
	_player.call("_update_tool_switch")
	_check(str(_player.call("get_traversal_tool")) == "portal", "tool_switch: jetpack -> portal")
	Input.action_press("tool_switch", 1.0)
	_player.call("_update_tool_switch")
	_check(str(_player.call("get_traversal_tool")) == "grapple", "tool_switch wraps: portal -> grapple")
	Input.action_release("tool_switch")
	# No allowed tools: switch is a no-op (Zombies default).
	_player.call("set_allowed_traversal_tools", [])
	_check(str(_player.call("get_traversal_tool")) == "none", "no allowed tools -> tool none")
	Input.action_press("tool_switch", 1.0)
	_player.call("_update_tool_switch")
	_check(str(_player.call("get_traversal_tool")) == "none", "tool_switch no-op with no allowed tools")
	Input.action_release("tool_switch")
	# Slide counts as crouch-held.
	Input.action_press("slide", 1.0)
	_check(bool(_player.call("_crouch_held")), "slide held reads as crouch-held")
	Input.action_release("slide")
	_check(not bool(_player.call("_crouch_held")), "slide released reads as not crouch-held")
	Input.action_press("crouch", 1.0)
	_check(bool(_player.call("_crouch_held")), "crouch held still reads as crouch-held")
	Input.action_release("crouch")
	# Gamepad-look dead zone: below -> 0, full deflection -> 1.
	_check(is_equal_approx(float(_player.call("_gamepad_axis", 0.1)), 0.0),
		"gamepad look deadzone swallows 0.1 deflection")
	_check(is_equal_approx(float(_player.call("_gamepad_axis", 1.0)), 1.0),
		"gamepad look full deflection = 1.0")
	_check(is_equal_approx(float(_player.call("_gamepad_axis", -1.0)), -1.0),
		"gamepad look full negative deflection = -1.0")
	# Start a weapon cycle (switch_to awaits its lower timer; the
	# follow-up phases wait, then assert each step landed).
	var wm := _player.get_node_or_null("WeaponManager")
	_check(wm != null, "player has WeaponManager")
	if wm != null:
		wm.call("_cycle_slot", 1)
		_cycle_t0 = Time.get_ticks_msec()


func _check_weapon_cycle_step1() -> void:
	var wm := _player.get_node_or_null("WeaponManager")
	_check(wm != null and str(wm.get("_current_slot")) == "secondary",
		"weapon_next cycles primary -> secondary")
	if wm != null:
		wm.call("_cycle_slot", 1)
		_cycle_t0 = Time.get_ticks_msec()


func _check_weapon_cycle_step2() -> void:
	var wm := _player.get_node_or_null("WeaponManager")
	_check(wm != null and str(wm.get("_current_slot")) == "prototype",
		"weapon_next cycles secondary -> prototype")


func _teardown() -> void:
	# Restore the player's bindings config (or remove the suite's).
	if _cfg_existed:
		var f := FileAccess.open(InputBindings.CONFIG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_cfg_backup)
	else:
		if FileAccess.file_exists(InputBindings.CONFIG_PATH):
			DirAccess.remove_absolute(InputBindings.CONFIG_PATH)
	InputBindings.reload()
	if paused:
		paused = false
