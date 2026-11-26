# bench_fps.gd — BB-9 per-feature FPS benchmark.
# Usage (needs a real renderer — use xvfb-run locally, the Deck GPU
# on device; a --headless run measures nothing):
#   xvfb-run godot --path . --script res://tools/bench_fps.gd -- \
#       --bench-map=cinder_city --gfx-tier=high --gfx-grit=0
#
# Loads ONE map scene, flies a FIXED deterministic camera path (slow
# orbit from a vantage, then a ground-level strafe), and after a warmup
# window samples every frame time. Prints exactly one summary line:
#   BENCH map=<key> gfx[tier=.. shadows=.. ..] avg_fps=.. p1_low_fps=.. frame_ms=.. frames=..
#
# Feature flags come from GfxSettings (cmdline wins): bench the same
# map with --gfx-<feature>=0|1 to attribute cost per feature.
#
# IMPORTANT: on this VM the renderer is llvmpipe (software) under xvfb,
# so absolute numbers here are MEANINGLESS for the Deck — only the
# RELATIVE deltas between feature configurations on the same map are
# signal. Absolute 60/30 fps verdicts must be measured on the real Deck.
extends SceneTree

var _map_key := "cinder_city"
var _seconds := 8.0
var _warmup := 2.5


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bench-map="):
			_map_key = a.trim_prefix("--bench-map=")
		elif a.begins_with("--bench-seconds="):
			_seconds = float(a.trim_prefix("--bench-seconds="))
		elif a.begins_with("--bench-warmup="):
			_warmup = float(a.trim_prefix("--bench-warmup="))
	call_deferred("run")


func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("BENCH: headless display — no rendering happens. Use xvfb-run or a real display.")
		quit(2)
		return
	root.size = Vector2i(960, 540)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	GfxSettings.apply_msaa(root)

	var arena := Node3D.new()
	arena.name = "BenchArena"
	root.add_child(arena)
	var map = load("res://scenes/maps/" + _map_key + ".tscn").instantiate()
	arena.add_child(map)
	var camera := Camera3D.new()
	arena.add_child(camera)
	camera.fov = 70.0
	camera.current = true
	for i in range(12):
		await process_frame

	# Warmup (shaders compile, shadow atlas settles), then measure.
	var times: Array = []
	var phase := 0.0
	var last := Time.get_ticks_usec()
	var measuring := false
	var measured := 0.0
	while measured < _seconds:
		await process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - last) / 1000000.0
		last = now
		phase += dt
		_drive_camera(camera, phase)
		if not measuring:
			if phase >= _warmup:
				measuring = true
				phase = 0.0
			continue
		measured += dt
		if dt > 0.0:
			times.append(dt)

	if times.is_empty():
		print("BENCH map=%s gfx[%s] avg_fps=0 p1_low_fps=0 frame_ms=0 frames=0 (no frames sampled)" % [
			_map_key, GfxSettings.describe()])
		quit(0)
		return
	times.sort()
	var total := 0.0
	for t in times:
		total += t
	var avg_ms := total / float(times.size()) * 1000.0
	var tail := maxi(1, int(times.size() * 0.01))
	var tail_sum := 0.0
	for i in range(times.size() - tail, times.size()):
		tail_sum += times[i]
	var p1_ms := tail_sum / float(tail) * 1000.0
	print("BENCH map=%s gfx[%s] avg_fps=%.1f p1_low_fps=%.1f frame_ms=%.2f frames=%d" % [
		_map_key, GfxSettings.describe(), 1000.0 / avg_ms, 1000.0 / p1_ms, avg_ms, times.size()])
	quit(0)


## Deterministic path: 55% slow orbit at r=26/h=11 looking at the arena
## heart, then a ground strafe across the front at eye height.
func _drive_camera(camera: Camera3D, t: float) -> void:
	var orbit_t := _seconds * 0.55
	if t < orbit_t:
		var ang := t * 0.22
		camera.position = Vector3(cos(ang) * 26.0, 11.0, sin(ang) * 26.0)
		camera.look_at(Vector3(0, 2, 0), Vector3.UP)
	else:
		var k := clampf((t - orbit_t) / maxf(_seconds * 0.45, 0.01), 0.0, 1.0)
		var x := lerpf(-20.0, 20.0, k)
		camera.position = Vector3(x, 1.7, 15.0)
		camera.look_at(Vector3(x * 0.6, 1.6, 0), Vector3.UP)
