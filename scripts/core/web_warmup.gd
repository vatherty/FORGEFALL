# res://scripts/core/web_warmup.gd
# FORGEFALL — Web-port warmup (iPhone Safari first-use hitches).
#
# Two problems on web, both real:
#   1. FIRST USE HITCHES. WebGL shaders compile on first DRAW of each
#      material, and several pools (ImpactFX, DebrisPool, TracerPool)
#      build lazily on first use. The first shot / explosion / enemy
#      therefore hitches. Fix: render the common combat set once during
#      the main menu, inside a throwaway SubViewport "warmup room", so
#      every shader is compiled and every pool is built before the
#      first match. Progress is shown honestly on a small overlay.
#   2. AFTER-IDLE SLOWNESS. Safari suspends/throttles backgrounded tabs;
#      on return the WASM engine re-tiers and the GPU context may be
#      cold again. Fix: detect the suspension gap and run a LIGHT rewarm
#      (palette materials only, ~2 frames). Honest limit: this re-touches
#      the hot paths but cannot prevent the JS engine's re-tiering —
#      the first seconds after a long idle may still feel soft.
#
# Scope is deliberately the common COMBAT path only: voxel palette
# materials (shared across all weapons/enemies/structures via
# VoxelBuilder), enemy-specific material variants (hit-flash, spawn
# telegraph, telegraph lamp), one emitter per element, a
# tracer-equivalent material, and the three lazy pools. Forge/creator
# content warms on its own first use (out of scope, time-boxed).
#
# Runs on web only (main.gd gates it). Headless tests can force it via
# WebWarmup.begin(parent, true).
class_name WebWarmup
extends Node

## Wall-clock gap that means "the tab was suspended" -> light rewarm.
const IDLE_GAP_MSEC := 8000
## Frames each warmup batch gets to actually draw (shader compile needs
## real draws, not just instantiation).
const BATCH_FRAMES := 3

static var _started := false

var _done := false
var _overlay: CanvasLayer
var _label: Label
var _last_frame_msec := 0


## Entry point. Returns the runner (or null when skipped).
## NOTE: the return type is Node (not WebWarmup) and the instance is
## built via load(), so this file compiles even when the editor's
## script-class cache hasn't seen the new class_name yet (headless
## --script runs, fresh checkouts, export scans).
static func begin(parent: Node, force := false) -> Node:
	if _started:
		return null
	if not force and not OS.has_feature("web"):
		return null
	_started = true
	var w: Node = (load("res://scripts/core/web_warmup.gd") as GDScript).new()
	w.name = "WebWarmup"
	parent.add_child(w)
	return w


func _ready() -> void:
	_build_overlay()
	_last_frame_msec = Time.get_ticks_msec()
	_run()  # fire-and-forget coroutine; progress via the overlay


func _process(_delta: float) -> void:
	# After-idle detection: wall-clock gap between frames. Only armed
	# after the full warmup (its own shader compiles can take seconds).
	if not _done:
		_last_frame_msec = Time.get_ticks_msec()
		return
	var now := Time.get_ticks_msec()
	if now - _last_frame_msec > IDLE_GAP_MSEC:
		_light_rewarm()
	_last_frame_msec = now


func is_done() -> bool:
	return _done


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 100
	_overlay.name = "WarmupOverlay"
	add_child(_overlay)
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_label.position = Vector2(-160, -64)
	_label.size = Vector2(320, 32)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	_label.text = "Warming up… 0%"
	_overlay.add_child(_label)


func _set_progress(pct: int) -> void:
	if is_instance_valid(_label):
		_label.text = "Warming up… %d%%" % pct


func _finish() -> void:
	_done = true
	_last_frame_msec = Time.get_ticks_msec()
	# CanvasLayer has no modulate of its own — fade the label, then
	# free the whole overlay.
	if is_instance_valid(_label):
		var tw := create_tween()
		tw.tween_property(_label, "modulate:a", 0.0, 0.6)
		tw.tween_callback(_overlay.queue_free)
	elif is_instance_valid(_overlay):
		_overlay.queue_free()


func _make_room() -> SubViewport:
	var vp := SubViewport.new()
	vp.name = "WarmupRoom"
	vp.own_world_3d = true
	vp.size = Vector2i(320, 180)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(0, 4.5, 11), Vector3(0, 1.0, 0))
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	vp.add_child(sun)
	get_tree().root.add_child(vp)
	return vp


func _await_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## The shared voxel materials: one cube per palette color. Because
## VoxelBuilder caches materials per color, this compiles the material
## behind every weapon, enemy, structure, and debris mesh in the game.
func _warm_palette(room: SubViewport) -> void:
	var colors: Array = VoxelBuilder.PALETTE.values()
	var cols := 8
	var i := 0
	for c in colors:
		var mi := VoxelBuilder.cube(Vector3(0.6, 0.6, 0.6), c,
			Vector3((i % cols) * 1.0 - cols * 0.5, 1.0, (i / cols) * 1.0))
		room.add_child(mi)
		i += 1


## Enemy-specific shader variants. Enemy bodies are VoxelBuilder cubes
## (covered by the palette phase), but each enemy also carries three
## materials with distinct flags — hit-flash (unshaded white),
## spawn-telegraph (unshaded + alpha), telegraph lamp (unshaded dark).
## Exact flag replicas of EnemyBase._flash_mat / _telegraph_mat and
## VoxelSoldier._lamp_mat, so those variants compile now instead of on
## first damage / first spawn. (Full enemy nodes are NOT instantiated:
## their physics bodies crash headless test contexts and are unnecessary
## — only the material flags matter for shader warmup.)
func _warm_enemy_materials(room: SubViewport) -> void:
	var defs := [
		{"albedo": Color(1, 1, 1), "alpha": false},           # hit flash
		{"albedo": Color(1, 0.75, 0.2, 0.6), "alpha": true},  # telegraph
		{"albedo": Color(0.15, 0.15, 0.15), "alpha": false},  # lamp
	]
	var i := 0
	for d in defs:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = d["albedo"]
		if bool(d["alpha"]):
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.8, 1.6, 0.8)
		mi.mesh = bm
		mi.material_override = m
		mi.position = Vector3(-4.0 + i * 2.0, 1.0, -2.0)
		room.add_child(mi)
		i += 1


func _warm_emitters(room: SubViewport) -> void:
	var i := 0
	for elem in ElementalEmitter.ELEMENTS:
		var em := ElementalEmitter.new()
		em.element = String(elem)
		em.position = Vector3(i * 2.0 - 9.0, 1.0, 3.0)
		room.add_child(em)
		i += 1


## TracerPool builds its own shared material lazily; replicate its exact
## flags here so the unshaded+emission shader variant compiles now.
func _warm_tracer_material(room: SubViewport) -> void:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = TracerPool.TRACER_COLOR
	m.emission_enabled = true
	m.emission = TracerPool.TRACER_COLOR
	m.emission_energy_multiplier = 6.0
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(TracerPool.TRACER_WIDTH, TracerPool.TRACER_WIDTH, 1.0)
	mi.mesh = bm
	mi.material_override = m
	mi.position = Vector3(0, 1.0, 5.0)
	room.add_child(mi)


func _run() -> void:
	# Phase 0: pools that build lazily on first combat use. These entry
	# points already exist — they were just never called early.
	_set_progress(5)
	ImpactFX.precache()
	DebrisPool.ensure_pool()
	TracerPool._ensure()  # underscore is convention-only; callable
	_set_progress(15)
	await _await_frames(1)

	var room := _make_room()
	# Phase 1: shared voxel materials (the big shader win).
	_warm_palette(room)
	_set_progress(40)
	await _await_frames(BATCH_FRAMES)
	# Phase 2: enemy-specific material variants (hit flash, telegraph,
	# lamp). Bodies are palette cubes — already covered above.
	_warm_enemy_materials(room)
	_set_progress(65)
	await _await_frames(BATCH_FRAMES)
	# Phase 3: one emitter per element (particle shaders + element mats).
	# Enemies are gone, so field ticks find no targets — pure visuals.
	_warm_emitters(room)
	_set_progress(85)
	await _await_frames(BATCH_FRAMES + 1)
	# Phase 4: tracer material variant.
	_warm_tracer_material(room)
	_set_progress(95)
	await _await_frames(BATCH_FRAMES)

	room.queue_free()
	_set_progress(100)
	_finish()


## After-idle: palette materials only, ~2 frames. Re-touches the hot
## shader/CPU paths after a tab suspension. Cannot prevent WASM
## re-tiering — documented in the header, not faked.
func _light_rewarm() -> void:
	var room := _make_room()
	_warm_palette(room)
	await _await_frames(2)
	room.queue_free()
