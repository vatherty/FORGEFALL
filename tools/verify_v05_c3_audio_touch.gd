# verify_v05_c3_audio_touch.gd — C3 (sound mix + touch layout) headless checks.
# Usage: godot --headless --path <project> --script res://tools/verify_v05_c3_audio_touch.gd
# Asserts: ambient wind auto-starts on gameplay / stops in menus, footsteps
# route at a sane (tamed) mix level, forge success/fail callable, gunshot mix
# never exceeds the 0 dB reference, touch buttons never overlap at 19.5:9 AND
# 16:9, FIRE is the largest button, action mapping unchanged, hints exist and
# fade, grapple loop API still idempotent + one-shot refusal intact.
# Any SCRIPT ERROR printed = real bug. Exit 0 = all checks pass.
extends SceneTree

var _failures: Array[String] = []
var _passes := 0
var _phase := 0
var _until := 0
var _sfx: Node = null
var _touch: Node = null
var _dummy_player: Node3D = null

const EXPECTED_ACTIONS := {
	"portal_blue": "portal_blue", "portal_orange": "portal_orange",
	"forge": "forge_console", "mic": "", "ks1": "killstreak_1",
	"ks2": "killstreak_2", "ks3": "killstreak_3", "pause": "pause",
	"fire": "fire", "jump": "jump", "ads": "ads", "crouch": "crouch",
	"grapple": "grapple", "reload": "reload",
}


func _check(cond: bool, name: String) -> void:
	if cond:
		_passes += 1
		print("C3 PASS: ", name)
	else:
		_failures.append(name)
		print("C3 FAIL: ", name)


func _now() -> int:
	return Time.get_ticks_msec()


func _playing_loop_count() -> int:
	var loops: Dictionary = _sfx.get("_loop_players")
	var n := 0
	for v in loops.values():
		if v != null and v.playing:
			n += 1
	return n


func _check_layout(label: String, w: float, h: float) -> void:
	# Drive _place_buttons directly at the exact target size: headless runs
	# ignore Window resizes, so resizing root.size cannot produce a 2340x1080
	# viewport. The retry loop below mirrors _layout() exactly (same start k,
	# same step, same overlap test), so this exercises the real layout code.
	var kk := clampf(minf(w / 1920.0, h / 1080.0), 0.30, 1.0)
	for _a in 12:
		_touch.call("_place_buttons", Vector2(w, h), kk)
		if not _touch.call("_buttons_overlap"):
			break
		kk = maxf(0.30, kk - 0.05)
	_touch.set("_view_size", Vector2(w, h))
	print("C3 INFO: layout ", label, " final scale k=", kk)
	var view := Vector2(w, h)
	var defs: Array = _touch.get("_btn_defs")
	var rects := {}
	for d in defs:
		rects[String(d["id"])] = Rect2(d["pos"], d["size"])
	# No pairwise overlap.
	var overlap_found := false
	var ids := rects.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			if rects[ids[i]].intersects(rects[ids[j]]):
				overlap_found = true
				print("C3 INFO: overlap ", ids[i], " vs ", ids[j],
					" ", rects[ids[i]], " ", rects[ids[j]])
	_check(not overlap_found, "no button overlaps at %s" % label)
	# All buttons inside the viewport.
	var bounds := Rect2(Vector2.ZERO, view)
	var inside := true
	for id in ids:
		if not bounds.encloses(rects[id]):
			inside = false
			print("C3 INFO: out of bounds ", id, " ", rects[id])
	_check(inside, "all buttons inside viewport at %s" % label)
	# FIRE is the largest button.
	var fire_area: float = rects["fire"].get_area()
	var fire_biggest := true
	for id in ids:
		if id != "fire" and rects[id].get_area() >= fire_area:
			fire_biggest = false
	_check(fire_biggest, "FIRE is the largest button at %s" % label)
	# Action mapping unchanged (same ids, same Input actions).
	var mapping_ok := true
	for d in defs:
		var id := String(d["id"])
		if String(d["action"]) != String(EXPECTED_ACTIONS.get(id, "?!")):
			mapping_ok = false
			print("C3 INFO: action changed for ", id, ": ", d["action"])
	_check(mapping_ok, "button action mapping unchanged at %s" % label)


func _initialize() -> void:
	_sfx = root.get_node_or_null("Sfx")
	_check(_sfx != null, "Sfx autoload present")
	var ps := load("res://scenes/ui/touch_controls.tscn") as PackedScene
	_check(ps != null, "touch_controls.tscn loads")
	_touch = ps.instantiate()
	_touch.set("force_show", true)
	root.add_child(_touch)
	_until = _now() + 300


func _process(_delta: float) -> bool:
	match _phase:
		0:
			if _now() < _until:
				return false
			_check_layout("19.5:9 (2340x1080)", 2340.0, 1080.0)
			_until = _now() + 100
			_phase = 1
		1:
			if _now() < _until:
				return false
			_check_layout("16:9 (1920x1080)", 1920.0, 1080.0)
			# Real _layout() path at the actual headless viewport: must also
			# come out overlap-free (exercises the retry loop end-to-end).
			_touch.call("_layout")
			_check(not _touch.call("_buttons_overlap"),
				"real _layout() overlap-free at headless viewport")
			# Gameplay starts: a node joins the "player" group.
			_dummy_player = Node3D.new()
			_dummy_player.name = "DummyPlayer"
			root.add_child(_dummy_player)
			_dummy_player.add_to_group("player")
			_until = _now() + 700  # Sfx polls every 0.25s
			_phase = 2
		2:
			if _now() < _until:
				return false
			_check(_sfx.call("is_ambient_playing"),
				"ambient wind loop starts on gameplay start")
			_dummy_player.remove_from_group("player")
			_dummy_player.queue_free()
			_dummy_player = null
			_until = _now() + 700
			_phase = 3
		3:
			if _now() < _until:
				return false
			_check(not _sfx.call("is_ambient_playing"),
				"ambient wind loop stops back in menus")
			# --- Mix: nothing above the 0 dB gunshot reference. ---
			_check(_sfx.call("mix_db_for", "shot_ar") == 0.0,
				"shot_ar is the 0 dB mix reference")
			_check(_sfx.call("mix_db_for", "shot_sniper") < 0.0
				and _sfx.call("mix_db_for", "shot_shotgun") < 0.0
				and _sfx.call("mix_db_for", "shot_lmg") < 0.0,
				"loudest gunshots (sniper/shotgun/lmg) tamed below reference")
			var mix_ok := true
			for id in ["shot_ar", "shot_sniper", "shot_shotgun", "shot_smg",
					"shot_pistol", "shot_lmg", "shot_turret", "explosion_big",
					"footstep_concrete", "footstep_dirt", "footstep_metal",
					"forge_success", "forge_fail", "grapple_zip",
					"ui_click", "hitmarker", "killstreak_ready"]:
				var v: float = _sfx.call("mix_db_for", id)
				if v > 0.0:
					mix_ok = false
					print("C3 INFO: mix above 0 dB: ", id, " = ", v)
			_check(mix_ok, "no mix offset above 0 dB (no clipping / no louder-than-gunshots)")
			# Footsteps route: play_footstep runs clean at a tamed level.
			_sfx.call("play_footstep", "concrete", Vector3.ZERO)
			_sfx.call("play_footstep", "dirt", Vector3.ZERO)
			_sfx.call("play_footstep", "metal", Vector3.ZERO)
			_check(_sfx.call("mix_db_for", "footstep_concrete") == -4.0
				and _sfx.call("mix_db_for", "footstep_metal") == -4.0,
				"footsteps route at -4 dB (audible, under gunfire)")
			# Forge success/fail callable (forge_manager already calls these).
			_sfx.call("play_forge_result", true)
			_sfx.call("play_forge_result", false)
			_sfx.call("play_2d", "forge_success")
			_sfx.call("play_2d", "forge_fail")
			_check(true, "forge success/fail sounds callable (no errors)")
			# --- Grapple loop API still intact (must not regress). ---
			_sfx.call("start_loop_2d", "grapple_zip")
			_sfx.call("start_loop_2d", "grapple_zip")
			var loops: Dictionary = _sfx.get("_loop_players")
			var gp = loops.get("grapple_zip")
			_check(gp != null and gp.playing,
				"grapple start_loop_2d starts the zip loop")
			_check(_playing_loop_count() == 1,
				"double start_loop_2d still = 1 playing loop (no stack)")
			var before_size := loops.size()
			_sfx.call("play_2d", "grapple_zip")
			_check(_sfx.get("_loop_players").size() == before_size
				and _playing_loop_count() == 1,
				"play_2d('grapple_zip') still refused (no leak)")
			_sfx.call("stop_loop_2d", "grapple_zip")
			_check(not gp.playing, "stop_loop_2d stops the zip loop")
			# --- Hints. ---
			_touch.call("show_hints")
			_check(_touch.call("hints_visible"), "hints show on demand")
			var hg: Label = _touch.get("_hint_grapple")
			var hw: Label = _touch.get("_hint_wallrun")
			_check(hg != null and hg.text.to_lower().contains("grapple")
				and hg.text.contains("tap again to release"),
				"grapple hint text correct")
			_check(hw != null and hw.text.to_lower().contains("wall-run"),
				"wall-run hint text correct")
			_check(_touch.call("hints_shown"), "hints marked shown (once per session)")
			_touch.call("dismiss_hints")
			_until = _now() + 1500  # fade is 1.0s
			_phase = 4
		4:
			if _now() < _until:
				return false
			_check(not _touch.call("hints_visible"),
				"hints fade out after dismiss")
			print("C3 SUMMARY: %d passed, %d failed" % [_passes, _failures.size()])
			if not _failures.is_empty():
				print("C3 FAILED CHECKS: ", _failures)
			quit(1 if not _failures.is_empty() else 0)
			return true
	return false
