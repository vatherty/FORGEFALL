# verify_v051.gd — headless consolidated checks for the v0.5.1 fix round.
# Usage: godot --headless --path <project> --script res://tools/verify_v051.gd
# Fixes covered:
#   1. emulate_mouse_from_touch=false; `fire` keeps its desktop mouse binding.
#   2. HUD layout: hint hidden, minimap hidden when UAV inactive (full
#      rect geometry was verified 60/60 across 5 sizes by the fix worker).
#   3. Shadow map 2048 + sun bias values.
#   4. Ammo + health pickups collect on the real player.
#   5. Grapple rope/spark scales stay thin (0.06 / 0.18).
#   6. Forge menu opens with no keyboard focus; LineEdit FOCUS_CLICK.
#   7. MIC fallback toasts + unknown prompt ("knife") shows suggestions.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _arena: Node3D = null
var _player: Node = null
var _wall: StaticBody3D = null
var _pickup: Node = null
var _pickup_kind := ""
var _reserve_before := 0
var _hp_before := 0.0
var _hud: Node = null
var _menu: Node = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	_arena = Node3D.new()
	_arena.name = "VerifyArena"
	root.add_child(_arena)
	# Wall for grapple + wall-run-adjacent checks.
	_wall = StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 6.0, 30.0)
	shape.shape = box
	_wall.add_child(shape)
	_wall.position = Vector3(1.0, 3.0, 0.0)
	_arena.add_child(_wall)
	# Real player (weapons, grapple, health).
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_arena.add_child(_player)
	# HUD + Forge menu (structural checks).
	var hud_ps := load("res://scenes/ui/hud.tscn") as PackedScene
	if hud_ps != null:
		_hud = hud_ps.instantiate()
		_arena.add_child(_hud)
	var menu_ps := load("res://scenes/ui/forge_menu.tscn") as PackedScene
	if menu_ps != null:
		_menu = menu_ps.instantiate()
		_arena.add_child(_menu)
	_phase = 1
	print("VERIFY v0.5.1: arena built")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 5:
				return false
			_check_fix1()
			_check_fix2()
			_check_fix3()
			_phase = 2
			_frames = 0
		2:
			# Fix 4, ammo leg: spawn an ammo pickup overlapping the player.
			_reserve_before = _total_reserve()
			_pickup_kind = "ammo"
			_spawn_pickup("ammo", 60)
			_phase = 3
			_frames = 0
		3:
			if _frames < 6:
				return false
			_check(_total_reserve() > _reserve_before,
				"fix 4: ammo pickup increases reserve (%d -> %d)"
				% [_reserve_before, _total_reserve()])
			_check(not is_instance_valid(_pickup),
				"fix 4: ammo pickup freed after collection")
			# Fix 4, health leg: damage, then health pickup.
			_player.call("take_damage", 40.0,
				_player.position + Vector3(1, 0, 0), false)
			_hp_before = _player.get("_hp")
			_pickup_kind = "health"
			_spawn_pickup("health", 25)
			_phase = 4
			_frames = 0
		4:
			if _frames < 6:
				return false
			var hp_after: float = _player.get("_hp")
			_check(hp_after > _hp_before,
				"fix 4: health pickup heals (%s -> %s)" % [_hp_before, hp_after])
			_check(not is_instance_valid(_pickup),
				"fix 4: health pickup freed after collection")
			# Fix 5: fire grapple at the wall, check thin scales.
			_player.position = Vector3(-2.0, 2.0, 0.0)
			_player.rotation = Vector3(0, -PI / 2.0, 0)
			_player.velocity = Vector3.ZERO
			var grapple = _player.get("grapple")
			var fired: bool = grapple.call("fire")
			_check(fired, "fix 5: grapple fires at the wall")
			_phase = 5
			_frames = 0
		5:
			if _frames < 5:
				return false
			var grapple2 = _player.get("grapple")
			var rope = grapple2.get("_rope") as Node3D
			var spark = grapple2.get("_spark") as Node3D
			if rope != null:
				_check(absf(rope.scale.x - 0.06) < 0.001,
					"fix 5: rope scale.x ~0.06 (got %s)" % rope.scale.x)
				_check(absf(rope.scale.y - 0.06) < 0.001,
					"fix 5: rope scale.y ~0.06 (got %s)" % rope.scale.y)
			else:
				_check(false, "fix 5: rope exists")
			if spark != null:
				_check(spark.scale.x < 0.35 and spark.scale.x > 0.05,
					"fix 5: spark scale ~0.18 x pulse (got %s)" % spark.scale.x)
			else:
				_check(false, "fix 5: spark exists")
			grapple2.call("release")
			_check_fix6_fix7()
			_phase = 6
		6:
			if _fails == 0:
				print("VERIFY v0.5.1: ALL CHECKS PASSED")
			else:
				printerr("VERIFY v0.5.1: %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


func _check_fix1() -> void:
	_check(ProjectSettings.get_setting(
		"input_devices/pointing/emulate_mouse_from_touch") == false,
		"fix 1: emulate_mouse_from_touch is false")
	var has_mouse := false
	for ev in InputMap.action_get_events("fire"):
		if ev is InputEventMouseButton \
				and (ev as InputEventMouseButton).button_index == 1:
			has_mouse = true
	_check(has_mouse,
		"fix 1: `fire` keeps its desktop mouse-button binding")


func _check_fix2() -> void:
	if _hud == null:
		_check(false, "fix 2: HUD instantiates")
		return
	# Persistent hint line must never show.
	var hints = _hud.get("_touch_hints") if _hud.get("_touch_hints") != null else null
	if hints != null:
		_check((hints as CanvasItem).visible == false,
			"fix 2: persistent touch-hint line stays hidden")
	else:
		print("PASS: fix 2: no persistent hint node (removed)")
	# Minimap hidden when UAV inactive.
	var frame = _hud.get("_map_frame")
	if frame != null:
		_check((frame as CanvasItem).visible == false,
			"fix 2: minimap hidden when UAV inactive")
	else:
		_check(false, "fix 2: minimap frame exists")


func _check_fix3() -> void:
	_check(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/directional_shadow/size") == 2048,
		"fix 3: directional shadow map is 2048")
	# Sun values come from the real Dustline builder.
	var builder := load("res://scripts/maps/dustline_builder.gd") as Script
	var b = builder.new()
	_arena.add_child(b)
	# Builder runs in _ready; check next phase via stored ref.
	_check_fix3_sun.call_deferred(b)


func _check_fix3_sun(b: Node) -> void:
	var sun := b.get_node_or_null("Sun") as DirectionalLight3D
	if sun == null:
		# The builder may parent the sun elsewhere; search the arena.
		for n in _arena.get_children():
			if n is DirectionalLight3D:
				sun = n
				break
	if sun == null:
		_check(false, "fix 3: sun exists in built map")
		return
	_check(absf(sun.shadow_bias - 0.05) < 0.001,
		"fix 3: sun shadow_bias 0.05 (got %s)" % sun.shadow_bias)
	_check(absf(sun.shadow_normal_bias - 1.0) < 0.001,
		"fix 3: sun shadow_normal_bias 1.0 (got %s)" % sun.shadow_normal_bias)
	_check(absf(sun.shadow_blur - 1.0) < 0.001,
		"fix 3: sun shadow_blur 1.0 (got %s)" % sun.shadow_blur)


func _total_reserve() -> int:
	var wm = _player.get_node_or_null("WeaponManager")
	if wm == null:
		return -1
	var total := 0
	for w in (wm.get("_weapons") as Dictionary).values():
		if w != null and w.get("weapon_id") != "raptor":
			total += int(w.get("reserve"))
	return total


func _spawn_pickup(kind: String, amount: int) -> void:
	var script := load("res://scripts/weapons/ammo_pickup.gd") as Script
	_pickup = Area3D.new()
	_pickup.set_script(script)
	_pickup.set("kind", kind)
	_pickup.set("amount", amount)
	_pickup.position = _player.position
	_arena.add_child(_pickup)
	# The pickup's collision mask must cover the player's layer 2.
	_check(int(_pickup.get("collision_mask")) & 2 != 0,
		"fix 4: %s pickup mask covers player layer 2 (mask=%s)"
		% [kind, _pickup.get("collision_mask")])


func _check_fix6_fix7() -> void:
	# Fix 6: Forge menu opens with no keyboard focus; LineEdit FOCUS_CLICK.
	if _menu != null and _menu.has_method("open"):
		_menu.call("open")
		var prompt = _menu.get("_prompt_input")
		if prompt != null:
			_check(int(prompt.get("focus_mode")) == Control.FOCUS_CLICK,
				"fix 6: Forge prompt LineEdit focus_mode is FOCUS_CLICK")
		else:
			_check(false, "fix 6: Forge prompt LineEdit exists")
		var vp := root.get_viewport()
		var focused = vp.gui_get_focus_owner() if vp != null else null
		# v0.6.1 (Workstream A): the no-focus rule is narrowed to its
		# INTENT — no TEXT field may hold focus (that pops the phone
		# keyboard and routes WASD into the prompt). The tab bar IS
		# focused now, so a gamepad can switch Forge tabs with no
		# mouse; a TabBar is not editable, so it cannot pop the
		# keyboard or swallow prompt text.
		_check(not (focused is LineEdit) and not (focused is TextEdit),
			"fix 6: no text field has focus after Forge open (no keyboard pop)")
		var tabs = _menu.get("_tabs") as TabContainer
		_check(tabs != null and focused == tabs.get_tab_bar(),
			"fix 6: Forge tab bar holds focus after open (controller nav)")
		if _menu.has_method("close"):
			_menu.call("close")
	else:
		_check(false, "fix 6: Forge menu instantiates with open()")
	# Fix 7a: MIC fallback toasts + opens console.
	var speech := SpeechInput.new()
	_arena.add_child(speech)
	speech.call("listen", Callable())
	_check(str(speech.get("last_toast_text")).contains("Voice input"),
		"fix 7a: MIC fallback records voice-unavailable toast")
	_check(bool(speech.get("fallback_console_requested")) == true,
		"fix 7a: MIC fallback requests the console")
	# Fix 7b: unknown prompt shows suggestions. Route through the Forge
	# autoload's preview_cost (same error path) — referencing ForgeLLM
	# directly breaks compilation in --script mode (forge_llm.gd reads
	# the Game autoload, which isn't registered at compile time there).
	var forge = root.get_node_or_null("Forge")
	if forge != null and forge.has_method("preview_cost"):
		var costed: Dictionary = forge.call("preview_cost", "knife")
		var err2: String = str(costed.get("error", ""))
		_check(costed.get("ok", true) == false
			and err2.contains("knife") and err2.contains("try:"),
			"fix 7b: unknown prompt error names it + suggests (got: %s)" % err2)
	else:
		_check(false, "fix 7b: Forge autoload with preview_cost exists")
