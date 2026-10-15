# verify_fixes.gd — headless functional checks for the v0.1.10 QA fixes.
# Usage: godot --headless --path <project> --script res://tools/verify_fixes.gd
# Checks, in a minimal scene (player + one wall):
#   1. GUNS: player.tscn has a WeaponManager; it builds 3 weapons; the
#      current weapon's viewmodel is parented to the camera and visible.
#   2. WALL-RUN: an airborne, fast player beside a wall with move input
#      enters wall-run WITHOUT holding sprint (sprint gate removed), and a
#      head-on approach triggers via the forward ray.
#   3. GRAPPLE SOUND: fire() starts exactly one zip loop; release() stops
#      it; play_2d("grapple_zip") refuses (no leak); start_loop is idempotent.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _player: Node = null
var _wall: StaticBody3D = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	# Minimal scene: a root node, one wall, one player.
	var arena := Node3D.new()
	arena.name = "VerifyArena"
	root.add_child(arena)
	_wall = StaticBody3D.new()
	_wall.name = "Wall"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 6.0, 30.0)
	shape.shape = box
	_wall.add_child(shape)
	_wall.position = Vector3(1.0, 3.0, 0.0)  # wall face at x = 0.5
	arena.add_child(_wall)
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	_phase = 1
	print("VERIFY: arena built, waiting for _ready + physics")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 5:
				return false
			_check_guns()
			_phase = 2
		2:
			# Wall-run, side approach: airborne, fast, moving parallel to the
			# wall, NO sprint held.
			_player.position = Vector3(0.0, 2.0, 5.0)
			_player.velocity = Vector3(0.0, 0.0, -5.0)
			_player.rotation = Vector3.ZERO
			Input.action_press("move_forward", 1.0)
			_phase = 3
			_frames = 0
		3:
			if _frames < 8:
				return false
			_check(_player.get("_wallrunning") == true,
				"wall-run triggers beside a wall without sprint held")
			Input.action_release("move_forward")
			_player.call("_end_wallrun")
			# Head-on approach: face the wall, fly straight at it. The side
			# rays run parallel to the wall face and miss; the forward ray
			# must catch it.
			# Start just inside the 1.6m forward-ray range so entry is
			# deterministic (not dependent on physics/process frame ratio).
			_player.position = Vector3(-1.0, 2.0, 0.0)
			_player.velocity = Vector3(5.0, 0.0, 0.0)
			_player.rotation = Vector3(0, -PI / 2.0, 0)
			Input.action_press("move_forward", 1.0)
			_phase = 4
			_frames = 0
		4:
			if _frames < 8:
				return false
			_check(_player.get("_wallrunning") == true,
				"wall-run triggers on a head-on approach (forward ray)")
			Input.action_release("move_forward")
			_player.call("_end_wallrun")
			_phase = 5
		5:
			_check_grapple_sound()
			_phase = 6
		6:
			if _fails == 0:
				print("VERIFY: ALL CHECKS PASSED")
			else:
				printerr("VERIFY: %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


func _check_guns() -> void:
	var wm := _player.get_node_or_null("WeaponManager")
	_check(wm != null, "player.tscn has a WeaponManager child")
	if wm == null:
		return
	var weapons: Dictionary = wm.get("_weapons")
	_check(weapons.size() == 3, "WeaponManager builds 3 weapons (got %d)" % weapons.size())
	var cur = wm.call("current_weapon")
	_check(cur != null, "WeaponManager has a current weapon")
	if cur == null:
		return
	var vm = cur.get("_viewmodel")
	_check(vm != null, "current weapon has a viewmodel")
	if vm == null:
		return
	var cam: Camera3D = _player.get("camera")
	_check(vm.get_parent() == cam,
		"viewmodel is parented to the camera (not parked/hidden)")
	_check(vm.visible == true, "viewmodel is visible")
	# HUD group: the HUD binds ammo/weapon signals via this group.
	var in_group := _player.get_tree().get_nodes_in_group("weapon_manager").has(wm)
	_check(in_group, "WeaponManager is in the 'weapon_manager' group (HUD binds it)")


func _check_grapple_sound() -> void:
	var sfx := root.get_node_or_null("Sfx")
	_check(sfx != null and sfx.has_method("start_loop_2d"),
		"Sfx exposes start_loop_2d")
	_check(sfx != null and sfx.has_method("stop_loop_2d"),
		"Sfx exposes stop_loop_2d")
	if sfx == null:
		return
	# Idempotency: two starts = one player.
	sfx.call("start_loop_2d", "grapple_zip")
	sfx.call("start_loop_2d", "grapple_zip")
	var loops: Dictionary = sfx.get("_loop_players")
	var p: AudioStreamPlayer = loops.get("grapple_zip")
	_check(p != null and p.playing, "start_loop_2d starts the zip loop")
	_check(loops.size() == 1, "double start_loop_2d still = 1 loop player (no stack)")
	# One-shot path must refuse loop streams now.
	var pool_before := 0
	for pl in sfx.get("_pool_2d"):
		if (pl as AudioStreamPlayer).playing:
			pool_before += 1
	sfx.call("play_2d", "grapple_zip")
	var pool_after := 0
	for pl in sfx.get("_pool_2d"):
		if (pl as AudioStreamPlayer).playing:
			pool_after += 1
	_check(pool_after == pool_before,
		"play_2d('grapple_zip') refuses (no leaked looping pool player)")
	# Full grapple cycle: fire -> loop playing, release -> loop stopped.
	sfx.call("stop_loop_2d", "grapple_zip")
	_player.position = Vector3(-2.0, 2.0, 0.0)
	_player.rotation = Vector3(0, -PI / 2.0, 0)  # face +X, toward the wall
	_player.velocity = Vector3.ZERO
	var grapple = _player.get("grapple")
	var fired: bool = grapple.call("fire")
	_check(fired, "grapple fires at the wall in the test arena")
	if fired:
		_check(p.playing, "grapple fire() starts the zip loop")
		grapple.call("release")
		_check(not p.playing, "grapple release() stops the zip loop")
