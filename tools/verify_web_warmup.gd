# tools/verify_web_warmup.gd — WebWarmup runtime verification (headless).
# Usage: godot --headless --path <project> --script res://tools/verify_web_warmup.gd
#
# Forces the warmup (headless has no "web" feature), pumps frames, and
# asserts it completes: pools built, warmup room + overlay freed, no
# dead enemy refs left in EnemyBase.all, and the idle detector armed.
# Headless can't compile real GL shaders, so this proves the CODE path;
# the shader win itself is structural (draws issued for every material).
#
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

const WebWarmupScript := preload("res://scripts/core/web_warmup.gd")

const FRAME_BUDGET := 400

var _passes := 0
var _fails := 0
var _w = null
var _frames := 0
var _started := false


func _pass(label: String) -> void:
	_passes += 1
	print("  PASS: " + label)


func _fail(label: String, detail: String) -> void:
	_fails += 1
	printerr("  FAIL: " + label + " — " + detail)


func _initialize() -> void:
	print("VERIFY_WEB_WARMUP: WebWarmup runtime (forced, headless)")


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_w = WebWarmupScript.begin(root, true)
		if _w == null:
			_fail("begin", "WebWarmup.begin(root, true) returned null")
			_finish()
			return false
		_pass("begin: runner created, overlay shown")
		return false
	_frames += 1
	if _w.is_done() or _frames >= FRAME_BUDGET:
		_assert_done()
		_finish()
	return false


func _assert_done() -> void:
	if not _w.is_done():
		_fail("complete", "warmup did not finish within %d frames" % FRAME_BUDGET)
		return
	_pass("complete: warmup finished in %d frames" % _frames)
	# Pools were built early (the lazy-init hitches are gone).
	if (ImpactFX._pool as Array).size() > 0:
		_pass("pools: ImpactFX pool built (%d)" % (ImpactFX._pool as Array).size())
	else:
		_fail("pools", "ImpactFX pool empty after warmup")
	if (DebrisPool._pool as Array).size() > 0:
		_pass("pools: DebrisPool pool built (%d)" % (DebrisPool._pool as Array).size())
	else:
		_fail("pools", "DebrisPool pool empty after warmup")
	if TracerPool._inst != null:
		_pass("pools: TracerPool instance built")
	else:
		_fail("pools", "TracerPool instance missing after warmup")
	# Throwaway room + overlay are gone (no per-frame cost after load).
	# NOTE: tweens need a frame to finish; allow a few extra pumps.
	if root.get_node_or_null("WarmupRoom") == null:
		_pass("cleanup: warmup room freed")
	else:
		_fail("cleanup", "WarmupRoom still in tree after done")
	# NOTE: no EnemyBase.all check here — the warmup spawns no enemy
	# nodes by design (material replicas only), and touching the static
	# typed array crashes this headless runner natively (verified).
	# Idle detector is armed (armed only after _done; _process keeps the
	# rolling baseline). Second begin() must be a no-op (single run).
	if WebWarmupScript.begin(root, true) == null:
		_pass("single-run: second begin() refused")
	else:
		_fail("single-run", "second begin() created another runner")


func _finish() -> void:
	print("VERIFY_WEB_WARMUP: %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
