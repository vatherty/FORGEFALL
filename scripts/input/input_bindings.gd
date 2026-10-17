# scripts/input/input_bindings.gd
# FORGEFALL — native controller support + remapping (v0.6.1, Workstream A).
#
# SINGLE SOURCE OF TRUTH for gameplay bindings. project.godot's [input]
# section ships the original defaults; this module owns them at runtime:
# it ADDS the actions project.godot lacks (slide, weapon_next/prev,
# tool_switch, gamepad portals/killstreaks, menu-nav D-pad/stick) and
# applies the player's saved rebinds from user://input_bindings.cfg.
# Call ensure_loaded() once at boot (Main + MainMenu do this; it is
# idempotent) before gameplay or menus read the InputMap.
#
# GAMEPAD MODEL — Godot reads the pad through SDL's gamecontroller DB,
# so one mapping covers all three targets: Steam Deck built-in pad,
# Xbox (XInput-style) and PlayStation pads all arrive as the same
# JOY_BUTTON_* / JOY_AXIS_* indices (PS Cross/Square/Triangle/Circle land
# on A/B/X/Y positions). Do NOT rely on Steam Input WASD emulation: the
# game reads the joypad directly, and keyboard emulation still works
# through the keyboard bindings. Deck note: Steam Input may present the
# Deck pad as a virtual Xbox pad — same indices, no special-casing.
#
# BINDING MODEL — one PRIMARY binding per device class (kb / pad) per
# action. Secondary bindings already in the InputMap (arrow keys for
# move, "/" for Forge, "P" for pause, Space for ui_accept, ...) are
# PRESERVED: set_binding() only replaces the recorded primary, and
# ensure_loaded() only ADDS missing defaults, never removes extras.
# Analog bindings (left stick move, RT fire, LT ADS) are primaries of
# kind "pad" with type "joy_axis"; the rebind UI can capture them too
# (push a stick / squeeze a trigger past 70%).
#
# CONFLICTS — set_binding() overwrites loudly, never silently: if the
# new event is already bound (same device class) on another action it is
# REMOVED from that action (and that action's primary becomes empty),
# and the replaced action labels are returned + shown in the rebind UI.
# Three INTENTIONAL shares are exempt (same button, mutually exclusive
# contexts, documented here):
#   crouch/slide  — slide IS crouch-while-moving (one button, C / B).
#   grapple/portal_blue — the tool-fire button (LB): only the ACTIVE
#       traversal tool fires, so LB fires grapple OR blue portal.
#   pause/ui_cancel — Esc: gameplay Esc pauses; menu Esc backs out.
#
# DEAD ZONE — one tunable: InputBindings.deadzone (default 0.2), applied
# to every managed action's InputMap deadzone AND read by player.gd's
# right-stick poll. The rebind screen exposes it as a slider; it
# persists in the same config file.
# Look is ANALOG, not an InputMap action (mouse + right stick polled):
# it appears in the rebind UI as a fixed informational row, not a
# rebindable binding.
class_name InputBindings
extends RefCounted

const CONFIG_PATH := "user://input_bindings.cfg"
const DEFAULT_DEADZONE := 0.2

## Current stick/button dead zone (0..0.5). Player polls read this live.
static var deadzone: float = DEFAULT_DEADZONE

static var _loaded := false
## action -> {"kb": event-dict-or-null, "pad": event-dict-or-null} — the
## CURRENT primaries (defaults, or the player's saved rebinds).
static var _primary: Dictionary = {}

## Canonical rebindable actions, in rebind-UI order.
const ACTIONS: Array[String] = [
	"move_forward", "move_back", "move_left", "move_right",
	"jump", "sprint", "crouch", "slide",
	"fire", "ads", "reload",
	"interact", "slot_1", "slot_2", "slot_3", "weapon_next", "weapon_prev",
	"grapple", "portal_blue", "portal_orange", "tool_switch",
	"forge_console", "killstreak_1", "killstreak_2", "killstreak_3",
	"pause", "ui_accept", "ui_cancel",
]

const LABELS: Dictionary = {
	"move_forward": "Move — Forward",
	"move_back": "Move — Back",
	"move_left": "Move — Left",
	"move_right": "Move — Right",
	"jump": "Jump",
	"sprint": "Sprint",
	"crouch": "Crouch",
	"slide": "Slide",
	"fire": "Fire",
	"ads": "Aim (ADS)",
	"reload": "Reload",
	"interact": "Interact / Buy",
	"slot_1": "Weapon Slot 1",
	"slot_2": "Weapon Slot 2",
	"slot_3": "Weapon Slot 3",
	"weapon_next": "Weapon — Next",
	"weapon_prev": "Weapon — Previous",
	"grapple": "Traversal Tool — Fire",
	"portal_blue": "Portal — Blue",
	"portal_orange": "Portal — Orange",
	"tool_switch": "Traversal Tool — Switch",
	"forge_console": "Forge — Open",
	"killstreak_1": "Killstreak 1 (UAV)",
	"killstreak_2": "Killstreak 2 (Airstrike)",
	"killstreak_3": "Killstreak 3 (Chopper)",
	"pause": "Pause / Menu",
	"ui_accept": "Menu — Confirm",
	"ui_cancel": "Menu — Back",
}

const CATEGORIES: Dictionary = {
	"move_forward": "MOVEMENT", "move_back": "MOVEMENT",
	"move_left": "MOVEMENT", "move_right": "MOVEMENT",
	"jump": "MOVEMENT", "sprint": "MOVEMENT", "crouch": "MOVEMENT",
	"slide": "MOVEMENT",
	"fire": "WEAPONS", "ads": "WEAPONS", "reload": "WEAPONS",
	"interact": "WEAPONS", "slot_1": "WEAPONS", "slot_2": "WEAPONS",
	"slot_3": "WEAPONS", "weapon_next": "WEAPONS",
	"weapon_prev": "WEAPONS",
	"grapple": "TRAVERSAL", "portal_blue": "TRAVERSAL",
	"portal_orange": "TRAVERSAL", "tool_switch": "TRAVERSAL",
	"forge_console": "FORGE & STREAKS", "killstreak_1": "FORGE & STREAKS",
	"killstreak_2": "FORGE & STREAKS", "killstreak_3": "FORGE & STREAKS",
	"pause": "MENU", "ui_accept": "MENU", "ui_cancel": "MENU",
}

## Menu-nav actions (Godot built-ins): NOT rebindable here — the D-pad /
## stick directions are fixed — but ensure_loaded() guarantees they
## carry gamepad events, because Godot's shipped defaults are
## keyboard-only on some builds and menus must work with no mouse.
## action -> event-dict that must be present.
const MENU_NAV: Dictionary = {
	"ui_up": {"type": "joy_button", "button_index": 11},      # D-pad Up
	"ui_down": {"type": "joy_button", "button_index": 12},    # D-pad Down
	"ui_left": {"type": "joy_button", "button_index": 13},     # D-pad Left
	"ui_right": {"type": "joy_button", "button_index": 14},    # D-pad Right
	"ui_focus_next": {"type": "joy_button", "button_index": 10},  # RB
	"ui_focus_prev": {"type": "joy_button", "button_index": 9},   # LB
}

## Intentional shares (see header). Pairs inside one group may share an
## event without the conflict resolver stripping it. The menu pairs
## (jump/ui_accept, crouch-or-slide/ui_cancel) are contextual: A is Jump
## in gameplay and Confirm in menus, B is Crouch in gameplay and Back in
## menus — the two sides never fire together usefully (gameplay input
## does not run while a menu owns the screen: main menu has no player,
## pause freezes the tree, Forge lives in TD where jump/crouch have no
## conflicting use). This mirrors the pause/ui_cancel Esc share.
const SHARED_GROUPS: Array[Array] = [
	["crouch", "slide"],
	["grapple", "portal_blue"],
	["pause", "ui_cancel"],
	["jump", "ui_accept"],
	["crouch", "ui_cancel"],
	["slide", "ui_cancel"],
]

## Event dicts: {"type":"key","physical_keycode":int},
## {"type":"mouse","button_index":int},
## {"type":"joy_button","button_index":int},
## {"type":"joy_axis","axis":int,"axis_value":float}.
## action -> {"kb": dict-or-null, "pad": dict-or-null}.
static func defaults() -> Dictionary:
	return {
		"move_forward": {"kb": {"type": "key", "physical_keycode": 87}, "pad": {"type": "joy_axis", "axis": 1, "axis_value": -1.0}},  # W / left stick up
		"move_back": {"kb": {"type": "key", "physical_keycode": 83}, "pad": {"type": "joy_axis", "axis": 1, "axis_value": 1.0}},  # S / left stick down
		"move_left": {"kb": {"type": "key", "physical_keycode": 65}, "pad": {"type": "joy_axis", "axis": 0, "axis_value": -1.0}},  # A / left stick left
		"move_right": {"kb": {"type": "key", "physical_keycode": 68}, "pad": {"type": "joy_axis", "axis": 0, "axis_value": 1.0}},  # D / left stick right
		"jump": {"kb": {"type": "key", "physical_keycode": 32}, "pad": {"type": "joy_button", "button_index": 0}},  # Space / A (South)
		"sprint": {"kb": {"type": "key", "physical_keycode": 4194325}, "pad": {"type": "joy_button", "button_index": 7}},  # Shift / L3
		"crouch": {"kb": {"type": "key", "physical_keycode": 67}, "pad": {"type": "joy_button", "button_index": 1}},  # C / B (East)
		"slide": {"kb": {"type": "key", "physical_keycode": 67}, "pad": {"type": "joy_button", "button_index": 1}},  # SHARED with crouch
		"fire": {"kb": {"type": "mouse", "button_index": 1}, "pad": {"type": "joy_axis", "axis": 5, "axis_value": 1.0}},  # Mouse Left / RT
		"ads": {"kb": {"type": "mouse", "button_index": 2}, "pad": {"type": "joy_axis", "axis": 4, "axis_value": 1.0}},  # Mouse Right / LT
		"reload": {"kb": {"type": "key", "physical_keycode": 82}, "pad": {"type": "joy_button", "button_index": 2}},  # R / X (West)
		"interact": {"kb": {"type": "key", "physical_keycode": 70}, "pad": {"type": "joy_button", "button_index": 3}},  # F / Y (North) — face button
		"slot_1": {"kb": {"type": "key", "physical_keycode": 49}, "pad": {"type": "joy_button", "button_index": 11}},  # 1 / D-pad Up
		"slot_2": {"kb": {"type": "key", "physical_keycode": 50}, "pad": {"type": "joy_button", "button_index": 14}},  # 2 / D-pad Right
		"slot_3": {"kb": {"type": "key", "physical_keycode": 51}, "pad": {"type": "joy_button", "button_index": 12}},  # 3 / D-pad Down
		"weapon_next": {"kb": {"type": "mouse", "button_index": 4}, "pad": null},  # Wheel Up / — (D-pad is slots)
		"weapon_prev": {"kb": {"type": "mouse", "button_index": 5}, "pad": null},  # Wheel Down / —
		"grapple": {"kb": {"type": "key", "physical_keycode": 71}, "pad": {"type": "joy_button", "button_index": 9}},  # G / LB
		"portal_blue": {"kb": {"type": "key", "physical_keycode": 81}, "pad": {"type": "joy_button", "button_index": 9}},  # Q / LB (SHARED tool-fire)
		"portal_orange": {"kb": {"type": "key", "physical_keycode": 69}, "pad": {"type": "joy_button", "button_index": 8}},  # E / R3
		"tool_switch": {"kb": {"type": "key", "physical_keycode": 86}, "pad": {"type": "joy_button", "button_index": 13}},  # V / D-pad Left
		"forge_console": {"kb": {"type": "key", "physical_keycode": 84}, "pad": {"type": "joy_button", "button_index": 10}},  # T / RB
		"killstreak_1": {"kb": {"type": "key", "physical_keycode": 52}, "pad": {"type": "joy_button", "button_index": 4}},  # 4 / View (Back)
		"killstreak_2": {"kb": {"type": "key", "physical_keycode": 53}, "pad": null},  # 5 / — (no free face button left)
		"killstreak_3": {"kb": {"type": "key", "physical_keycode": 54}, "pad": null},  # 6 / —
		"pause": {"kb": {"type": "key", "physical_keycode": 4194305}, "pad": {"type": "joy_button", "button_index": 6}},  # Esc / Menu (Start)
		"ui_accept": {"kb": {"type": "key", "physical_keycode": 4194309}, "pad": {"type": "joy_button", "button_index": 0}},  # Enter / A (South)
		"ui_cancel": {"kb": {"type": "key", "physical_keycode": 4194305}, "pad": {"type": "joy_button", "button_index": 1}},  # Esc / B (East)
	}


static func label_for(action: String) -> String:
	return str(LABELS.get(action, action))


## Idempotent boot entry: create missing actions, add missing default
## events, guarantee menu-nav gamepad events, then apply saved rebinds.
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var defs := defaults()
	for action in ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var prim: Dictionary = {"kb": null, "pad": null}
		var d: Dictionary = defs.get(action, {})
		for kind: String in ["kb", "pad"]:
			var ev_dict: Variant = d.get(kind)
			if ev_dict is Dictionary:
				_ensure_event(action, ev_dict as Dictionary)
				prim[kind] = (ev_dict as Dictionary).duplicate(true)
		_primary[action] = prim
	_ensure_menu_nav()
	_apply_deadzone()
	_load_saved()


## Test / teardown hook: forget loaded state so the next ensure_loaded()
## re-reads the config file from disk.
static func reload() -> void:
	_loaded = false
	_primary.clear()
	ensure_loaded()


## Remove current primaries, restore defaults, reset dead zone, persist.
static func reset_to_defaults() -> void:
	ensure_loaded()
	var defs := defaults()
	for action in ACTIONS:
		var prim: Dictionary = _primary.get(action, {})
		var d: Dictionary = defs.get(action, {})
		for kind: String in ["kb", "pad"]:
			var cur: Variant = prim.get(kind)
			if cur is Dictionary:
				_erase_matching(action, cur as Dictionary)
			var want: Variant = d.get(kind)
			if want is Dictionary:
				_ensure_event(action, want as Dictionary)
				prim[kind] = (want as Dictionary).duplicate(true)
			else:
				prim[kind] = null
		_primary[action] = prim
	deadzone = DEFAULT_DEADZONE
	_apply_deadzone()
	save()


## Bind `ev_dict` as `action`'s primary for `kind` ("kb"/"pad").
## Returns {"ok": bool, "replaced": Array[String]} — replaced lists the
## action labels whose binding was overwritten (never silent).
static func set_binding(action: String, kind: String, ev_dict: Dictionary) -> Dictionary:
	ensure_loaded()
	if not ACTIONS.has(action) or (kind != "kb" and kind != "pad"):
		return {"ok": false, "replaced": []}
	if event_kind_of_dict(ev_dict) != kind:
		return {"ok": false, "replaced": []}
	var replaced: Array[String] = []
	# Overwrite loudly: strip the same event from every other action
	# except intentional shares.
	for other in ACTIONS:
		if other == action or _shares_group(action, other):
			continue
		if _has_matching(other, ev_dict):
			_erase_matching(other, ev_dict)
			var oprim: Dictionary = _primary.get(other, {})
			if oprim.get(kind) is Dictionary and events_equal_dict(oprim.get(kind), ev_dict):
				oprim[kind] = null
				_primary[other] = oprim
			replaced.append(label_for(other))
	var prim: Dictionary = _primary.get(action, {})
	var cur: Variant = prim.get(kind)
	if cur is Dictionary:
		_erase_matching(action, cur as Dictionary)
	_ensure_event(action, ev_dict)
	prim[kind] = ev_dict.duplicate(true)
	_primary[action] = prim
	save()
	return {"ok": true, "replaced": replaced}


## Clear one primary (row shows "—"). The action keeps any secondary
## bindings already in the InputMap.
static func clear_binding(action: String, kind: String) -> bool:
	ensure_loaded()
	if not ACTIONS.has(action) or (kind != "kb" and kind != "pad"):
		return false
	var prim: Dictionary = _primary.get(action, {})
	var cur: Variant = prim.get(kind)
	if cur is Dictionary:
		_erase_matching(action, cur as Dictionary)
	prim[kind] = null
	_primary[action] = prim
	save()
	return true


static func primary_dict(action: String, kind: String) -> Variant:
	ensure_loaded()
	var prim: Dictionary = _primary.get(action, {})
	return prim.get(kind)


static func binding_label(action: String, kind: String) -> String:
	var d: Variant = primary_dict(action, kind)
	if d is Dictionary:
		return event_label(dict_to_event(d as Dictionary))
	return "—"


static func set_deadzone(v: float) -> void:
	ensure_loaded()
	deadzone = clampf(v, 0.0, 0.5)
	_apply_deadzone()
	save()


static func connected_pad_label() -> String:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return "No gamepad detected — keyboard / mouse active"
	return "Gamepad: %s" % Input.get_joy_name(pads[0])


# --- Event dict helpers ------------------------------------------------------

static func event_kind_of_dict(d: Dictionary) -> String:
	match str(d.get("type", "")):
		"key", "mouse":
			return "kb"
		"joy_button", "joy_axis":
			return "pad"
	return ""


static func event_to_dict(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		return {"type": "key", "physical_keycode": int((ev as InputEventKey).physical_keycode)}
	if ev is InputEventMouseButton:
		return {"type": "mouse", "button_index": int((ev as InputEventMouseButton).button_index)}
	if ev is InputEventJoypadButton:
		return {"type": "joy_button", "button_index": int((ev as InputEventJoypadButton).button_index)}
	if ev is InputEventJoypadMotion:
		return {"type": "joy_axis", "axis": int((ev as InputEventJoypadMotion).axis), "axis_value": float((ev as InputEventJoypadMotion).axis_value)}
	return {}


static func dict_to_event(d: Dictionary) -> InputEvent:
	# DEVICE RULE (probe-verified on 4.7.2): the engine matches a stored
	# event against a live event iff stored.device == -1 (wildcard) or
	# stored.device == live.device. Godot's built-in ui_* events carry
	# device 16, so a stored key event must carry 16 to match them —
	# which is exactly a fresh InputEventKey's default device, so keys
	# leave `device` untouched. Mouse/joypad stored events use -1
	# (the project.godot convention, wildcard for every real device).
	match str(d.get("type", "")):
		"key":
			var k := InputEventKey.new()
			# Both fields: Godot's shipped defaults match on keycode
			# (e.g. ui_accept Enter), real hardware matches on
			# physical_keycode. Setting both keeps one event matching
			# both worlds instead of adding a duplicate.
			k.keycode = int(d.get("physical_keycode", 0))
			k.physical_keycode = int(d.get("physical_keycode", 0))
			k.pressed = false
			return k
		"mouse":
			var m := InputEventMouseButton.new()
			m.device = -1
			m.button_index = int(d.get("button_index", 1)) as MouseButton
			m.pressed = false
			return m
		"joy_button":
			var b := InputEventJoypadButton.new()
			b.device = -1
			b.button_index = int(d.get("button_index", 0)) as JoyButton
			b.pressed = false
			return b
		"joy_axis":
			var a := InputEventJoypadMotion.new()
			a.device = -1
			a.axis = int(d.get("axis", 0)) as JoyAxis
			a.axis_value = float(d.get("axis_value", 0.0))
			return a
	return null


## Two events conflict when they are the same physical input. Axis
## events match on axis + direction sign (0.8 deflection == 1.0).
static func events_equal(a: InputEvent, b: InputEvent) -> bool:
	if a is InputEventKey and b is InputEventKey:
		var ak := a as InputEventKey
		var bk := b as InputEventKey
		if ak.physical_keycode != 0 and ak.physical_keycode == bk.physical_keycode:
			return true
		if ak.keycode != 0 and ak.keycode == bk.keycode:
			return true
		return false
	if a is InputEventMouseButton and b is InputEventMouseButton:
		return (a as InputEventMouseButton).button_index == (b as InputEventMouseButton).button_index
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		return (a as InputEventJoypadButton).button_index == (b as InputEventJoypadButton).button_index
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		return (a as InputEventJoypadMotion).axis == (b as InputEventJoypadMotion).axis \
			and signf((a as InputEventJoypadMotion).axis_value) == signf((b as InputEventJoypadMotion).axis_value)
	return false


static func events_equal_dict(d1: Variant, d2: Variant) -> bool:
	if not (d1 is Dictionary and d2 is Dictionary):
		return false
	var e1 := dict_to_event(d1 as Dictionary)
	var e2 := dict_to_event(d2 as Dictionary)
	if e1 == null or e2 == null:
		return false
	return events_equal(e1, e2)


const JOY_BUTTON_NAMES: Dictionary = {
	0: "A (South)", 1: "B (East)", 2: "X (West)", 3: "Y (North)",
	4: "View (Back)", 5: "Guide", 6: "Menu (Start)",
	7: "Left Stick (L3)", 8: "Right Stick (R3)",
	9: "LB", 10: "RB",
	11: "D-Pad Up", 12: "D-Pad Down", 13: "D-Pad Left", 14: "D-Pad Right",
	15: "Misc (Paddle)",
}


static func event_label(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var t := (ev as InputEventKey).as_text()
		return t if not t.is_empty() else "Key %d" % int((ev as InputEventKey).physical_keycode)
	if ev is InputEventMouseButton:
		match int((ev as InputEventMouseButton).button_index):
			1:
				return "Mouse Left"
			2:
				return "Mouse Right"
			3:
				return "Mouse Middle"
			4:
				return "Wheel Up"
			5:
				return "Wheel Down"
			_:
				return "Mouse %d" % int((ev as InputEventMouseButton).button_index)
	if ev is InputEventJoypadButton:
		return str(JOY_BUTTON_NAMES.get(int((ev as InputEventJoypadButton).button_index), "Pad Btn %d" % int((ev as InputEventJoypadButton).button_index)))
	if ev is InputEventJoypadMotion:
		var ax := int((ev as InputEventJoypadMotion).axis)
		var v := float((ev as InputEventJoypadMotion).axis_value)
		match ax:
			0:
				return "Left Stick " + ("Right" if v > 0.0 else "Left")
			1:
				return "Left Stick " + ("Down" if v > 0.0 else "Up")
			2:
				return "Right Stick " + ("Right" if v > 0.0 else "Left")
			3:
				return "Right Stick " + ("Down" if v > 0.0 else "Up")
			4:
				return "LT"
			5:
				return "RT"
		return "Pad Axis %d" % ax
	return "—"


# --- Focus helper (controller menu navigation) --------------------------------

## Depth-first: grab focus on the first focusable, enabled, visible
## control under `root` that is NOT a text field (LineEdit/TextEdit
## would pop the phone keyboard / swallow keys). Returns the control
## focused, or null. Menus call this on open so D-pad + Confirm work
## with no mouse: without an initial focus owner, Godot's ui_* nav has
## nowhere to move FROM and the D-pad appears dead.
static func grab_first_focus(root: Control) -> Control:
	if root == null:
		return null
	var found := _first_focusable(root)
	if found != null:
		found.grab_focus()
	return found


static func _first_focusable(node: Node) -> Control:
	if node is Control:
		var c := node as Control
		if c.visible and c.focus_mode != Control.FOCUS_NONE \
				and not (c is LineEdit) and not (c is TextEdit) \
				and not (c is Button and (c as Button).disabled) \
				and not (c is OptionButton and (c as OptionButton).disabled):
			return c
	for child in node.get_children():
		var hit := _first_focusable(child)
		if hit != null:
			return hit
	return null


# --- Internals -----------------------------------------------------------------

static func _shares_group(a: String, b: String) -> bool:
	for g in SHARED_GROUPS:
		if (g as Array).has(a) and (g as Array).has(b):
			return true
	return false


static func _has_matching(action: String, ev_dict: Dictionary) -> bool:
	if not InputMap.has_action(action):
		return false
	for e in InputMap.action_get_events(action):
		if events_equal(e, dict_to_event(ev_dict)):
			return true
	return false


static func _erase_matching(action: String, ev_dict: Dictionary) -> void:
	if not InputMap.has_action(action):
		return
	var target := dict_to_event(ev_dict)
	if target == null:
		return
	for e in InputMap.action_get_events(action):
		if events_equal(e, target):
			InputMap.action_erase_event(action, e)


static func _ensure_event(action: String, ev_dict: Dictionary) -> void:
	if not _has_matching(action, ev_dict):
		var ev := dict_to_event(ev_dict)
		if ev != null:
			InputMap.action_add_event(action, ev)


static func _ensure_menu_nav() -> void:
	for action in MENU_NAV.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		_ensure_event(action, MENU_NAV[action] as Dictionary)


static func _apply_deadzone() -> void:
	for action in ACTIONS:
		if InputMap.has_action(action):
			InputMap.action_set_deadzone(action, deadzone)


static func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "version", 1)
	cfg.set_value("meta", "deadzone", deadzone)
	for action in ACTIONS:
		var prim: Dictionary = _primary.get(action, {})
		# Cleared primaries persist as {} (ConfigFile drops nulls, so
		# null is reserved for "key absent" = keep the default).
		cfg.set_value("bindings", action + ".kb", prim.get("kb") if prim.get("kb") is Dictionary else {})
		cfg.set_value("bindings", action + ".pad", prim.get("pad") if prim.get("pad") is Dictionary else {})
	cfg.save(CONFIG_PATH)


static func _load_saved() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	if cfg.has_section_key("meta", "deadzone"):
		deadzone = clampf(float(cfg.get_value("meta", "deadzone", DEFAULT_DEADZONE)), 0.0, 0.5)
		_apply_deadzone()
	for action in ACTIONS:
		for kind: String in ["kb", "pad"]:
			var key := action + "." + kind
			if not cfg.has_section_key("bindings", key):
				continue  # action added after this save: keep default.
			var saved: Variant = cfg.get_value("bindings", key, null)
			if saved is Dictionary and not (saved as Dictionary).is_empty():
				# Rebind through the same path as the UI (conflict
				# resolution included) — but do not re-save per action.
				_apply_saved_binding(action, kind, saved as Dictionary)
			elif saved is Dictionary:
				# {} = explicitly cleared primary: stays cleared.
				var prim: Dictionary = _primary.get(action, {})
				if prim.get(kind) is Dictionary:
					_erase_matching(action, prim.get(kind) as Dictionary)
					prim[kind] = null
					_primary[action] = prim


static func _apply_saved_binding(action: String, kind: String, ev_dict: Dictionary) -> void:
	var cur: Variant = (_primary.get(action, {}) as Dictionary).get(kind)
	if cur is Dictionary and events_equal_dict(cur, ev_dict):
		return
	for other in ACTIONS:
		if other == action or _shares_group(action, other):
			continue
		if _has_matching(other, ev_dict):
			_erase_matching(other, ev_dict)
			var oprim: Dictionary = _primary.get(other, {})
			if oprim.get(kind) is Dictionary and events_equal_dict(oprim.get(kind), ev_dict):
				oprim[kind] = null
				_primary[other] = oprim
	if cur is Dictionary:
		_erase_matching(action, cur as Dictionary)
	_ensure_event(action, ev_dict)
	(_primary.get(action, {}) as Dictionary)[kind] = ev_dict.duplicate(true)
