# bench_movement_goal1.gd — headless BEFORE/AFTER benchmark for Goal 1 (Feel) Worker A.
# Usage: godot --headless --path <project> --script res://tools/bench_movement_goal1.gd
# Measures, all in a minimal arena (floor + one wall):
#   1. SPRINT: time to travel 50 m forward at full sprint + top speed.
#   2. SLIDE: distance + duration of one sprint-initiated slide.
#   3. WALLRUN: distance + duration of one wall-run (entry speed 8 m/s).
#   4. GRAPPLE: DIRECT-pull zip time over ~20 m vertical + peak speed.
# Prints BENCH: lines; always exits 0 (measurement, not pass/fail).
extends SceneTree

var _phase := 0
var _frames := 0
var _t := 0.0
var _player: Node3D = null
var _start := Vector3.ZERO
var _top_speed := 0.0
var _slide_start := Vector3.ZERO
var _slide_t := 0.0
var _wr_start := Vector3.ZERO
var _wr_t := 0.0
var _zip_t := 0.0
var _zip_peak := 0.0


func _initialize() -> void:
	var arena := Node3D.new()
	arena.name = "BenchArena"
	root.add_child(arena)
	var floor_body := StaticBody3D.new()
	var fshape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(200.0, 1.0, 200.0)
	fshape.shape = fbox
	floor_body.add_child(fshape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	arena.add_child(floor_body)
	var wall := StaticBody3D.new()
	var wshape := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(1.0, 6.0, 120.0)  # long wall: wall-run must end by timer, not wall end
	wshape.shape = wbox
	wall.add_child(wshape)
	wall.position = Vector3(1.0, 3.0, 0.0)
	arena.add_child(wall)
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	_phase = 1
	print("BENCH: arena built")


func _release_all() -> void:
	for a in ["move_forward", "move_back", "move_left", "move_right",
			"sprint", "crouch", "jump", "grapple", "ads"]:
		if Input.is_action_pressed(a):
			Input.action_release(a)


func _process(delta: float) -> bool:
	_frames += 1
	match _phase:
		1:  # --- SPRINT: land, then sprint 50 m ---
			if _frames < 5:
				return false
			_player.position = Vector3(0.0, 2.0, 50.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			_release_all()
			_phase = 2
			_frames = 0
		2:
			if _frames < 30:
				return false  # let the player land
			if not _player.is_on_floor():
				if _frames > 300:
					print("BENCH: sprint_50m_time=TIMEOUT (never landed)")
					_phase = 3
					_frames = 0
				return false
			_start = _player.position
			_t = 0.0
			_top_speed = 0.0
			Input.action_press("move_forward", 1.0)
			Input.action_press("sprint", 1.0)
			_phase = 3
			_frames = 0
		3:
			_t += delta
			var hs := Vector2(_player.velocity.x, _player.velocity.z).length()
			_top_speed = maxf(_top_speed, hs)
			var traveled := _start.z - _player.position.z
			if traveled >= 50.0:
				print("BENCH: sprint_50m_time=%.2fs top_speed=%.2f m/s" % [_t, _top_speed])
				_release_all()
				_phase = 4
				_frames = 0
			elif _t > 30.0:
				print("BENCH: sprint_50m_time=TIMEOUT traveled=%.1f top=%.2f" % [traveled, _top_speed])
				_release_all()
				_phase = 4
				_frames = 0
		4:  # --- SLIDE: sprint to speed, tap crouch, measure the glide ---
			if _frames < 5:
				return false
			_player.position = Vector3(0.0, 2.0, 50.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			_release_all()
			_phase = 5
			_frames = 0
		5:
			if _frames < 30:
				return false
			if not _player.is_on_floor():
				if _frames > 300:
					print("BENCH: slide=TIMEOUT (never landed)")
					_phase = 8
					_frames = 0
				return false
			Input.action_press("move_forward", 1.0)
			Input.action_press("sprint", 1.0)
			_phase = 6
			_frames = 0
		6:  # sprint 1.5 s to reach top speed, then tap crouch
			if _frames < 90:
				return false
			Input.action_press("crouch", 1.0)
			_phase = 7
			_frames = 0
		7:
			if _frames == 2:
				Input.action_release("crouch")
			if _frames < 3:
				return false
			if _player.get("_sliding") == true and _slide_t == 0.0:
				_slide_start = _player.position
				_slide_t = 0.0
			if _player.get("_sliding") == true:
				_slide_t += delta
			elif _slide_t > 0.0:
				var d := _slide_start.distance_to(_player.position)
				print("BENCH: slide_distance=%.2fm slide_time=%.2fs" % [d, _slide_t])
				_release_all()
				_phase = 8
				_frames = 0
				_slide_t = 0.0
			elif _frames > 600:
				print("BENCH: slide=TIMEOUT (slide never started)")
				_release_all()
				_phase = 8
				_frames = 0
		8:  # --- WALLRUN: airborne fast beside the wall ---
			if _frames < 5:
				return false
			_player.position = Vector3(0.0, 2.0, 5.0)
			_player.velocity = Vector3(0.0, 0.0, -8.0)
			_player.rotation = Vector3.ZERO
			_player.call("_end_wallrun")
			_release_all()
			Input.action_press("move_forward", 1.0)
			_phase = 9
			_frames = 0
			_wr_t = 0.0
		9:
			if _player.get("_wallrunning") == true:
				if _wr_t == 0.0:
					_wr_start = _player.position
				_wr_t += delta
			elif _wr_t > 0.0:
				var d := _wr_start.distance_to(_player.position)
				print("BENCH: wallrun_distance=%.2fm wallrun_time=%.2fs" % [d, _wr_t])
				_release_all()
				_phase = 10
				_frames = 0
				_wr_t = 0.0
			elif _frames > 600:
				print("BENCH: wallrun=TIMEOUT (never started)")
				_release_all()
				_phase = 10
				_frames = 0
		10:  # --- GRAPPLE ZIP: DIRECT pull, anchor ~20 m above ---
			if _frames < 5:
				return false
			_player.position = Vector3(0.0, 4.0, 0.0)
			_player.velocity = Vector3.ZERO
			_player.rotation = Vector3.ZERO
			_release_all()
			var grapple = _player.get("grapple")
			grapple.call("release")
			grapple.set("_active", true)
			grapple.set("_mode", 1)  # DIRECT
			grapple.set("_anchor", Vector3(0.0, 25.0, 0.0))
			grapple.set("_rope_len", 21.0)
			_zip_t = 0.0
			_zip_peak = 0.0
			_phase = 11
			_frames = 0
		11:
			_zip_t += delta
			_zip_peak = maxf(_zip_peak, _player.velocity.length())
			var grapple = _player.get("grapple")
			if grapple.get("_active") == false:
				print("BENCH: grapple_zip_time=%.2fs zip_peak_speed=%.2f m/s" % [_zip_t, _zip_peak])
				_phase = 12
			elif _zip_t > 10.0:
				print("BENCH: grapple_zip_time=TIMEOUT peak=%.2f" % _zip_peak)
				grapple.call("release")
				_phase = 12
		12:
			print("BENCH: done")
			quit(0)
			return true
	return false
