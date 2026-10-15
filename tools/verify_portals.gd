# verify_portals.gd — headless integration verification for FORGEFALL Goal 5 (PORTALS, Portal 2 bar).
# Usage: godot --headless --path <project> --script res://tools/verify_portals.gd
#
# Worker D (Verification). Owns ONLY this file. Never fixes game code: bugs
# found here are reported with file + line, not patched.
#
# Coverage (discovery-based, NOT hardcoded to worker file names — the checks
# read the live tree / live objects, so Worker A/B/C landings are judged on
# what actually exists):
#   A. SEE-THROUGH: portal discs render a live view from the paired portal
#      (SubViewport + ViewportTexture + portal camera), the RT is non-black,
#      the virtual camera tracks the partner (position = pure pair rotation,
#      orientation = mirror flip — a camera looking INTO the entry portal
#      must look OUT OF the exit portal), and a fallback shimmer engages
#      when the RT/camera fails (partner gone -> RT off, shimmer visible,
#      never a black face). Headless forces the disc's dummy-renderer gate
#      open so the virtual-camera math is testable; the SubViewport render
#      itself is a no-op without a GPU.
#   B. MOMENTUM: teleport preserves speed and maps direction through the
#      pair with PORTAL 2 semantics — the body exits moving OUT of the exit
#      portal (along +exit normal), not back into the wall. Position offset
#      on the entry side is preserved on the exit side. Cooldown blocks
#      ping-pong; teleport requires both discs active. NOTE: position maps
#      with the pure pair rotation; velocity/direction maps with the mirror
#      flip — the same flip the see-through camera needs. A check that only
#      asserted rot*v would encode the old (wrong) behavior.
#   C. PUZZLES: every shipped chamber (discovered from disk — never invented
#      names) loads, exposes a completion API, is completable by a scripted
#      solution, requires portals, and resets.
#   D. PLACEMENT VALIDITY: a portal-able vs non-portal-able system exists
#      and fire() refuses non-portal-able surfaces (marked walls; enemy
#      bodies are a WARN — design may differ there).
#   E. INTEGRATION: player.tscn still wires PortalEmitter, portal_blue /
#      portal_orange actions exist, discs stay pooled (exactly 2, no new
#      discs per shot), portal SFX ids exist, voxel style holds.
#
# HONEST HEADLESS LIMITS (never faked as passes):
#   - Headless has no GPU: ViewportTexture pixel reads usually come back
#     empty. Pixel checks degrade to WARN when no image is readable; the
#     structural checks (SubViewport + camera + texture assigned + camera
#     follows partner) carry the weight.
#   - Real visual quality of see-through (does it LOOK right, correct
#     parallax, no tearing) is Colin's on-device verdict — headless checks
#     prove it renders, not that it looks right.
#   - A true player walk-through of a chamber cannot run headlessly; the
#     scripted solver drives completion APIs / buttons / cubes directly.
#
# Exit 0 = all checks pass. Any FAIL prints and exits 1.
# "MISSING" FAILs before Workers A/B/C land are missing content, not bugs —
# the harness is written early precisely so it can run as their work lands.
extends SceneTree

const DISCENE_PATH := "res://scenes/player/portal_disc.tscn"
const EMITTER_PATH := "res://scripts/player/portal_emitter.gd"
const PLAYER_PATH := "res://scenes/player.tscn"

var _passes := 0
var _fails := 0
var _warns := 0
var _sec: Dictionary = {}
var _frames := 0
var _stage := 0
var _stage_ms := 0

var _arena: Node3D = null
var _emitter: Node = null
var _blue: Node3D = null
var _orange: Node3D = null
var _player_body: CharacterBody3D = null
var _camera: Camera3D = null
var _wall_a: StaticBody3D = null
var _wall_b: StaticBody3D = null
var _enemy: CharacterBody3D = null

var _portal_source := ""
var _chambers: Array = []
var _chamber_idx := 0
var _chamber_node: Node = null
var _chamber_wait := 0
var _rt_texture: ViewportTexture = null
var _rt_baseline := -1.0
var _virt_before := Transform3D.IDENTITY
var _pool_count_before := 0


# ---------------------------------------------------------------- helpers

func _check(section: String, cond: bool, label: String) -> void:
	var c: Array = _sec.get(section, [0, 0])
	if cond:
		_passes += 1
		c[0] += 1
		print("PASS [%s]: %s" % [section, label])
	else:
		_fails += 1
		c[1] += 1
		printerr("FAIL [%s]: %s" % [section, label])
	_sec[section] = c


func _warn(section: String, cond: bool, label: String) -> void:
	if cond:
		print("OK [%s]: %s" % [section, label])
	else:
		_warns += 1
		print("WARN [%s]: %s" % [section, label])


func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _collect_files(dir_path: String, ext: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(ext):
			out.append(dir_path.path_join(f))
	for sub in d.get_directories():
		if sub == "tools" or sub == "addons" or sub.begins_with("."):
			continue
		_collect_files(dir_path.path_join(sub), ext, out)


func _approx(a: Vector3, b: Vector3, tol: float) -> bool:
	return a.distance_to(b) <= tol


func _find_nodes_of_class(node: Node, cls: Variant, out: Array) -> void:
	# cls is a GDScript class object (e.g. SubViewport) — `is` needs a
	# static type, so compare via ClassDB instead.
	if ClassDB.class_exists(node.get_class()) and node.is_class(cls):
		out.append(node)
	for ch in node.get_children():
		_find_nodes_of_class(ch, cls, out)


func _disc_viewports(disc: Node) -> Array:
	var out: Array = []
	_find_nodes_of_class(disc, "SubViewport", out)
	return out


func _disc_cameras(disc: Node) -> Array:
	var out: Array = []
	_find_nodes_of_class(disc, "Camera3D", out)
	return out


func _disc_rt_textures(disc: Node) -> Array:
	# Any ViewportTexture reachable from the disc's mesh materials.
	var out: Array = []
	var stack: Array = [disc]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var mats: Array = []
			if mi.material_override != null:
				mats.append(mi.material_override)
			if mi.mesh != null:
				for si in mi.mesh.get_surface_count():
					mats.append(mi.get_surface_override_material(si))
					mats.append(mi.mesh.surface_get_material(si))
			for m in mats:
				if m is StandardMaterial3D:
					var sm := m as StandardMaterial3D
					for t in [sm.albedo_texture, sm.emission_texture, sm.metallic_texture]:
						if t is ViewportTexture and not out.has(t):
							out.append(t)
		for ch in n.get_children():
			stack.append(ch)
	return out


func _completion_of(obj: Object) -> Variant:
	# Returns true/false when a completion state is observable, else null.
	for m in ["is_complete", "is_solved", "check_complete", "get_completed", "is_finished"]:
		if obj.has_method(m):
			var r = obj.call(m)
			if r is bool:
				return r
	for p in ["completed", "solved", "is_complete", "is_solved", "complete", "finished"]:
		var v = obj.get(p)
		if v is bool:
			return v
	return null


func _try_solve(obj: Object) -> bool:
	# Direct solver APIs first.
	for m in ["solve", "debug_complete", "force_complete", "complete_all", "complete", "debug_solve", "auto_solve"]:
		if obj.has_method(m):
			obj.call(m)
			return true
	# Generic: press every button, move every cube onto every goal.
	var pressed := false
	var moved := false
	var goals: Array = []
	var cubes: Array = []
	var stack: Array = [obj]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node:
			if n.is_in_group("goal") or n.is_in_group("puzzle_goal") or n.is_in_group("target_zone") or n.name.to_lower().contains("goal"):
				goals.append(n)
			if n.is_in_group("cube") or n.is_in_group("puzzle_cube") or n.name.to_lower().contains("cube"):
				cubes.append(n)
			for ch in n.get_children():
				stack.append(ch)
	# Press buttons: prefer a press()/activate() method, else simulate a body entering.
	stack = [obj]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node:
			var is_button := n.is_in_group("button") or n.is_in_group("pressure_plate") \
				or n.is_in_group("puzzle_button") or n.name.to_lower().contains("button") \
				or n.name.to_lower().contains("pressure")
			if is_button:
				if n.has_method("press"):
					n.call("press")
					pressed = true
				elif n.has_method("activate"):
					n.call("activate")
					pressed = true
				elif n is Area3D:
					var dummy := CharacterBody3D.new()
					(n as Area3D).emit_signal("body_entered", dummy)
					dummy.free()
					pressed = true
			for ch in n.get_children():
				stack.append(ch)
	# Move cubes onto goals.
	for cube in cubes:
		if goals.is_empty():
			break
		if cube is Node3D:
			var g: Node3D = goals[0]
			(cube as Node3D).global_position = g.global_position
			moved = true
	return pressed or moved


func _fresh_body(pos: Vector3, vel: Vector3) -> CharacterBody3D:
	var b := CharacterBody3D.new()
	b.global_transform = Transform3D(Basis.IDENTITY, pos)
	b.velocity = vel
	_arena.add_child(b)
	return b


func _set_pair(blue_tf: Transform3D, orange_tf: Transform3D) -> void:
	_blue.global_transform = blue_tf
	_orange.global_transform = orange_tf
	_blue.set("is_active", true)
	_orange.set("is_active", true)
	_blue.set("visible", true)
	_orange.set("visible", true)


# ---------------------------------------------------------------- setup

func _initialize() -> void:
	_arena = Node3D.new()
	_arena.name = "VerifyPortalsArena"
	root.add_child(_arena)

	# --- discover portal sources (game code only — never tools/) ---
	var gd_files: Array = []
	_collect_files("res://scripts", ".gd", gd_files)
	_collect_files("res://scenes", ".gd", gd_files)
	var portal_hits: Array = []
	for p in gd_files:
		var p_str: String = p
		var base: String = p_str.get_file().to_lower()
		if base.contains("portal"):
			portal_hits.append(p)
	for p in portal_hits:
		_portal_source += "\n" + _read_file(p)
	_portal_source += "\n" + _read_file(DISCENE_PATH)

	# --- discover chambers (never invent names — read them from disk) ---
	var tscn_files: Array = []
	_collect_files("res://scenes", ".tscn", tscn_files)
	for p in tscn_files:
		var p_str: String = p
		var low: String = p_str.to_lower()
		var txt: String = _read_file(p_str)
		var is_chamber: bool = low.contains("chamber") or low.contains("puzzle") or low.contains("test_chamber")
		if not is_chamber:
			for grp in ["\"puzzle\"", "\"chamber\"", "\"portal_puzzle\"", "\"test_chamber\""]:
				if txt.contains(grp):
					is_chamber = true
					break
		if is_chamber:
			_chambers.append({"path": p, "kind": "tscn"})
	for p in gd_files:
		var p_str: String = p
		var low: String = p_str.to_lower()
		var txt: String = _read_file(p_str)
		# NOTE: plain "puzzle" in the path matches the puzzles/ DIRECTORY —
		# that would sweep in room_base.gd + progress_store.gd, which are
		# NOT chambers. Chambers are chamber_* scripts / Chamber classes.
		var is_chamber: bool = low.contains("chamber_") or low.contains("test_chamber") or txt.contains("class_name Chamber")
		if is_chamber and not low.contains("verify"):
			_chambers.append({"path": p, "kind": "gd"})
	# Catalogue (CompletionStore.ROOMS) is authoritative for the room list:
	# a catalogued script that does not exist on disk is a MISSING chamber.
	var cat_txt := _read_file("res://scripts/puzzles/progress_store.gd")
	var cidx := 0
	while true:
		var key := cat_txt.find('"script": "', cidx)
		if key < 0:
			break
		var a := key + len('"script": "')
		var b := cat_txt.find('"', a)
		if b < 0:
			break
		var cpath := cat_txt.substr(a, b - a)
		cidx = b + 1
		var already := false
		for c in _chambers:
			if str((c as Dictionary).get("path", "")) == cpath:
				already = true
				break
		if not already:
			if FileAccess.file_exists(cpath):
				_chambers.append({"path": cpath, "kind": "gd"})
			else:
				_chambers.append({"path": cpath, "kind": "missing"})

	# --- emitter under test (load()-guarded: a broken worker file FAILs its
	# section instead of taking down the whole suite) ---
	var scr = load(EMITTER_PATH)
	if scr == null or not scr.can_instantiate():
		printerr("FAIL [setup]: cannot load ", EMITTER_PATH, " — portal scripts do not compile")
		_fails += 1
		_stage = 99
		return
	_emitter = Node3D.new()
	_emitter.set_script(scr)
	_arena.add_child(_emitter)

	# --- placement arena: two walls + player + camera ---
	_wall_a = StaticBody3D.new()
	_wall_a.name = "PortalableWall"
	var sha := CollisionShape3D.new()
	var boxa := BoxShape3D.new()
	boxa.size = Vector3(0.5, 4.0, 10.0)
	sha.shape = boxa
	_wall_a.add_child(sha)
	_wall_a.position = Vector3(5.0, 2.0, 0.0)
	_wall_a.add_to_group("portalable")
	_arena.add_child(_wall_a)

	_wall_b = StaticBody3D.new()
	_wall_b.name = "NonPortalableWall"
	var shb := CollisionShape3D.new()
	var boxb := BoxShape3D.new()
	boxb.size = Vector3(0.5, 4.0, 10.0)
	shb.shape = boxb
	_wall_b.add_child(shb)
	_wall_b.position = Vector3(-5.0, 2.0, 0.0)
	# Every common non-portal-able marker, so the check tests the system,
	# not one guessed convention: groups + metadata.
	_wall_b.add_to_group("non_portalable")
	_wall_b.add_to_group("no_portal")
	_wall_b.set_meta("portalable", false)
	_wall_b.set_meta("portal_surface", false)
	_arena.add_child(_wall_b)

	_player_body = CharacterBody3D.new()
	_player_body.name = "ProbePlayer"
	_player_body.position = Vector3(0, 2, 0)
	_arena.add_child(_player_body)
	_camera = Camera3D.new()
	_camera.name = "ProbeCamera"
	_camera.global_transform = Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(0, 2, 0))
	_arena.add_child(_camera)

	print("VERIFY_PORTALS: setup done, chambers discovered: ", _chambers.size())
	_stage = 0


# ---------------------------------------------------------------- stages

func _process(_delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			if _frames < 5:
				return false
			_blue = _emitter.get("_blue")
			_orange = _emitter.get("_orange")
			_run_static_checks()
			_stage = 1
			_frames = 0
		1:
			_run_momentum_checks()
			_stage = 2
			_frames = 0
		2:
			# Placement needs physics-server sync for the raycast.
			if _frames < 5:
				return false
			_run_placement_shot_b()
			_stage = 20
			_stage_ms = Time.get_ticks_msec()
			_frames = 0
		20:
			# 12 frames clears the 0.15 s placement debounce AND lets the
			# enemy body's collision sync before its shot. Headless frames
			# can run faster than wall-clock, so BOTH gates are required.
			if _frames < 12 or Time.get_ticks_msec() - _stage_ms < 250:
				return false
			_run_placement_shot_a()
			_stage = 21
			_stage_ms = Time.get_ticks_msec()
			_frames = 0
		21:
			if _frames < 12 or Time.get_ticks_msec() - _stage_ms < 250:
				return false
			_run_placement_shot_enemy()
			_setup_seethrough_scene()
			_stage = 3
			_frames = 0
		3:
			if _frames < 12:
				return false
			_run_see_through_checks()
			_stage = 30
			_frames = 0
		30:
			# Tracking: the virtual camera must follow the moved partner.
			if _frames < 5:
				return false
			_run_tracking_check()
			if _orange != null:
				_orange.set("is_active", false)  # partner-gone fallback gate
			_stage = 31
			_frames = 0
		31:
			if _frames < 5:
				return false
			_run_fallback_checks()
			_stage = 4
			_frames = 0
			_chamber_idx = 0
			_chamber_wait = 0
		4:
			_run_chamber_stage()
		99:
			_finish()
			return true
	return false


func _run_static_checks() -> void:
	# --- compile gate: a worker file that does not parse breaks ALL portals ---
	var disc_scr = load("res://scripts/player/portal_disc.gd")
	_check("integration", disc_scr != null and disc_scr.can_instantiate(),
		"portal_disc.gd compiles (a parse error here takes down both discs + PortalEmitter._ready)")
	var emitter_scr = load("res://scripts/player/portal_emitter.gd")
	_check("integration", emitter_scr != null and emitter_scr.can_instantiate(),
		"portal_emitter.gd compiles")
	var ps = load(PLAYER_PATH) as PackedScene
	var has_emitter := false
	if ps != null and ps.can_instantiate():
		var probe: Node = ps.instantiate()
		has_emitter = probe.get_node_or_null("PortalEmitter") != null
		probe.free()
	_check("integration", has_emitter, "player.tscn still wires a PortalEmitter child")
	_check("integration", InputMap.has_action("portal_blue"), "InputMap has portal_blue action")
	_check("integration", InputMap.has_action("portal_orange"), "InputMap has portal_orange action")
	var audio_src := _read_file("res://scripts/audio/audio_manager.gd")
	_check("integration", audio_src.contains("portal_fire") and audio_src.contains("portal_fail") and audio_src.contains("portal_travel"),
		"portal SFX ids (portal_fire / portal_fail / portal_travel) registered in audio_manager.gd")
	_check("integration", _emitter != null and _blue != null and _orange != null,
		"PortalEmitter instantiates exactly its 2 pooled discs")
	_check("integration", _portal_source.contains("VoxelBuilder"),
		"portal visuals keep voxel style (VoxelBuilder in portal sources)")

	# --- A (source-level): see-through machinery exists at all ---
	_check("see_through", _portal_source.contains("SubViewport"),
		"portal sources mention SubViewport (see-through render target)")
	_check("see_through", _portal_source.contains("ViewportTexture") or _portal_source.contains("get_texture()"),
		"portal sources use a ViewportTexture (disc shows the RT — literal 'ViewportTexture' or viewport get_texture())")
	_check("see_through", _portal_source.contains("Camera3D") or _portal_source.contains("portal_camera"),
		"portal sources mention a portal camera (view from the paired portal)")

	# --- D (source-level): placement-validity machinery exists at all ---
	var validity_kw := ["portalable", "can_place", "is_valid_surface", "valid_surface", "is_portalable", "surface_portalable", "no_portal", "non_portal"]
	var found_validity := false
	for kw in validity_kw:
		if _portal_source.contains(kw):
			found_validity = true
			break
	# Validity may also live outside portal files (surface/material script).
	if not found_validity:
		var all_gd: Array = []
		_collect_files("res://scripts", ".gd", all_gd)
		for p in all_gd:
			var txt := _read_file(p)
			if txt.contains("is_portalable") or txt.contains("can_place_portal"):
				found_validity = true
				break
	_check("placement", found_validity,
		"a portal-able vs non-portal-able validity system exists (is_portalable / can_place_portal / portalable marker)")


func _run_momentum_checks() -> void:
	if _blue == null or _orange == null:
		_check("momentum", false, "momentum: discs missing — cannot test teleport")
		return
	# M1: canonical identity pair. Entry normal = -Z = (0,0,-1); body on the
	# normal side moving into the portal (-normal = +Z).
	_set_pair(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)),
		Transform3D(Basis.IDENTITY, Vector3(10, 2, 0)))
	var b1 := _fresh_body(Vector3(0, 2, -0.3), Vector3(0, 0, 8))
	_emitter.call("try_teleport", _blue, b1)
	_check("momentum", absf(b1.velocity.length() - 8.0) <= 0.16,
		"identity pair: exit speed ~= entry speed (got %s, want 8.0)" % str(b1.velocity.length()))
	# Position: flipped offset lands behind the exit plane, so Worker C
	# clamps the normal component to the standoff (1.35 for a shapeless
	# CharacterBody3D = STANDOFF_CHARACTER): (10, 2, -0.3) -> (10, 2, -1.35).
	_check("momentum", _approx(b1.global_position, Vector3(10, 2, -1.35), 0.06),
		"identity pair: body exits at the standoff in front of the exit portal (got %s, want (10, 2, -1.35))" % str(b1.global_position))
	_check("momentum", _approx(b1.velocity, Vector3(0, 0, -8), 0.3),
		"identity pair: exit velocity points OUT of exit portal (got %s, want (0, 0, -8)) — Portal 2 ejection, not back into the wall" % str(b1.velocity))
	# M2: canonical floor -> wall fling (THE Portal 2 mechanic).
	_set_pair(Transform3D(Basis.looking_at(Vector3.UP, Vector3.FORWARD), Vector3(0, 0, 0)),
		Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(10, 0, 0)))
	var b2 := _fresh_body(Vector3(0, 0.3, 0), Vector3(0, -10, 0))
	_emitter.call("try_teleport", _blue, b2)
	_check("momentum", absf(b2.velocity.length() - 10.0) <= 0.2,
		"floor->wall fling: exit speed ~= entry speed (got %s, want 10.0)" % str(b2.velocity.length()))
	_check("momentum", _approx(b2.global_position, Vector3(11.35, 0, 0), 0.06),
		"floor->wall fling: body exits at the standoff in front of the wall portal (got %s, want (11.35, 0, 0))" % str(b2.global_position))
	_check("momentum", _approx(b2.velocity, Vector3(10, 0, 0), 0.3),
		"floor->wall fling: exit velocity = +exit normal (got %s, want (10, 0, 0)) — falling into a floor portal must fling OUT of the wall portal" % str(b2.velocity))
	# M3: canonical 90-degree pair. Entry normal = rotY90 * (0,0,-1) = (-1,0,0).
	_set_pair(Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(0, 2, 0)),
		Transform3D(Basis.IDENTITY, Vector3(10, 2, 0)))
	var b3 := _fresh_body(Vector3(-0.3, 2, 0), Vector3(8, 0, 0))
	_emitter.call("try_teleport", _blue, b3)
	_check("momentum", absf(b3.velocity.length() - 8.0) <= 0.16,
		"90-degree pair: exit speed ~= entry speed (got %s, want 8.0)" % str(b3.velocity.length()))
	_check("momentum", _approx(b3.global_position, Vector3(10, 2, -1.35), 0.06),
		"90-degree pair: body exits at the standoff in front of the exit portal (got %s, want (10, 2, -1.35))" % str(b3.global_position))
	_check("momentum", _approx(b3.velocity, Vector3(0, 0, -8), 0.3),
		"90-degree pair: exit velocity points OUT of exit portal (got %s, want (0, 0, -8))" % str(b3.velocity))
	# M4: RigidBody3D — linear momentum ejects, angular magnitude preserved.
	_set_pair(Transform3D(Basis.looking_at(Vector3.UP, Vector3.FORWARD), Vector3(0, 0, 0)),
		Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(10, 0, 0)))
	var rb := RigidBody3D.new()
	rb.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.3, 0))
	rb.linear_velocity = Vector3(0, -10, 0)
	rb.angular_velocity = Vector3(0, 2, 0)
	_arena.add_child(rb)
	_emitter.call("try_teleport", _blue, rb)
	_check("momentum", absf(rb.linear_velocity.length() - 10.0) <= 0.2,
		"RigidBody3D: exit linear speed ~= entry speed (got %s)" % str(rb.linear_velocity.length()))
	_check("momentum", _approx(rb.linear_velocity, Vector3(10, 0, 0), 0.3),
		"RigidBody3D: exit linear velocity points OUT of exit portal (got %s, want (10, 0, 0))" % str(rb.linear_velocity))
	_check("momentum", absf(rb.angular_velocity.length() - 2.0) <= 0.2,
		"RigidBody3D: angular speed magnitude preserved (got %s)" % str(rb.angular_velocity.length()))
	_check("momentum", _approx(rb.global_position, Vector3(10.6, 0, 0), 0.06),
		"RigidBody3D: body exits at the rigid standoff in front of the exit portal (got %s, want (10.6, 0, 0) = STANDOFF_RIGID 0.6)" % str(rb.global_position))
	# M5: cooldown blocks ping-pong.
	_set_pair(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)),
		Transform3D(Basis.IDENTITY, Vector3(10, 2, 0)))
	var b5 := _fresh_body(Vector3(0, 2, -0.3), Vector3(0, 0, 8))
	_emitter.call("try_teleport", _blue, b5)
	var after_first := b5.global_position
	_emitter.call("try_teleport", _orange, b5)
	_check("momentum", _approx(b5.global_position, after_first, 0.001),
		"cooldown blocks immediate ping-pong re-teleport (pos stayed %s)" % str(after_first))
	# M6: teleport requires BOTH discs active.
	_orange.set("is_active", false)
	var b6 := _fresh_body(Vector3(0, 2, -0.3), Vector3(0, 0, 8))
	_emitter.call("try_teleport", _blue, b6)
	_check("momentum", _approx(b6.global_position, Vector3(0, 2, -0.3), 0.001),
		"no teleport when the exit disc is inactive (body stayed put)")
	_orange.set("is_active", true)


# Placement is staged across frames on purpose: the emitter debounces
# successful placements (0.15 s), so a rapid second shot would be
# swallowed by the debounce and mask a missing validity check. Shot B
# (refusal) goes FIRST on a cold debounce; shots A / enemy follow after
# frame waits that clear the debounce and sync physics.
func _run_placement_shot_b() -> void:
	if _emitter == null or _blue == null or _orange == null:
		_check("placement", false, "placement: discs missing — cannot test fire()")
		return
	_emitter.call("setup", _player_body, _camera, null, null)
	# Pooled-disc count before firing.
	_pool_count_before = 0
	for ch in _emitter.get_children():
		if ch is Area3D and ch.get_script() != null and (ch as Node).get("is_active") != null:
			_pool_count_before += 1
	# Shot B (fresh orange disc): NON-portal-able wall B. Camera looks -X.
	# Debounce is cold (no successful placement yet), so a placement here
	# can only mean validity failed — the debounce cannot mask it.
	_camera.global_transform = Transform3D(Basis.looking_at(Vector3.LEFT, Vector3.UP), Vector3(0, 2, 0))
	_emitter.call("fire_orange")
	_check("placement", _orange.get("is_active") != true or not _approx(_orange.global_position, Vector3(-4.67, 2, 0), 0.35),
		"fire at NON-portal-able wall (groups non_portalable/no_portal + portalable=false) is refused (orange active=%s at %s)" % [str(_orange.get("is_active")), str(_orange.global_position)])


func _run_placement_shot_a() -> void:
	if _emitter == null or _blue == null:
		_check("placement", false, "placement: discs missing — cannot test fire()")
		return
	# Shot A (fresh blue disc): portal-able wall A. Camera looks +X.
	_camera.global_transform = Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(0, 2, 0))
	_emitter.call("fire_blue")
	_check("placement", _blue.get("is_active") == true,
		"fire at portal-able wall activates the disc")
	_check("placement", _approx(_blue.global_position, Vector3(4.67, 2, 0), 0.35),
		"disc lands on the portal-able wall face (got %s, want ~(4.67, 2, 0))" % str(_blue.global_position))
	# Disc face aligns to the surface normal: -Z == wall normal (-X).
	_check("placement", _approx(_blue.global_transform.basis.z, Vector3(1, 0, 0), 0.1),
		"disc -Z aligns to the wall normal (disc basis z = %s, want (1, 0, 0))" % str(_blue.global_transform.basis.z))
	# Enemy staged now so its collision syncs during the next frame wait.
	_enemy = CharacterBody3D.new()
	_enemy.name = "ProbeEnemy"
	var esh := CollisionShape3D.new()
	var ebox := BoxShape3D.new()
	ebox.size = Vector3(0.6, 1.8, 0.6)
	esh.shape = ebox
	_enemy.add_child(esh)
	_enemy.position = Vector3(2.0, 2.0, 0.0)
	_enemy.add_to_group("enemy")
	_arena.add_child(_enemy)


func _run_placement_shot_enemy() -> void:
	if _emitter == null or _blue == null:
		_check("placement", false, "placement: discs missing — cannot test fire()")
		return
	# Shot: enemy body in front of wall A — a portal stuck to an enemy is
	# invalid (WARN: design may legitimately differ here). Validity is
	# checked BEFORE the debounce in _fire, so the debounce cannot mask
	# an enemy placement; the frame wait synced the enemy's collision.
	_camera.global_transform = Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(0, 2, 0))
	var blue_before: Vector3 = _blue.global_position
	_emitter.call("fire_blue")
	var landed_on_enemy := _approx(_blue.global_position, Vector3(1.62, 2, 0), 0.4)
	_warn("placement", not landed_on_enemy,
		"portal placed on an enemy body (blue moved %s -> %s) — portals should not stick to enemies" % [str(blue_before), str(_blue.global_position)])
	if _enemy != null:
		_enemy.queue_free()
		_enemy = null
	# Pooling: repeated fire must not create new discs.
	var pool_after := 0
	for ch in _emitter.get_children():
		if ch is Area3D and ch.get_script() != null and (ch as Node).get("is_active") != null:
			pool_after += 1
	_check("integration", pool_after == _pool_count_before and _pool_count_before == 2,
		"discs stay pooled: exactly 2 discs across repeated fires (before=%d after=%d)" % [_pool_count_before, pool_after])


func _setup_seethrough_scene() -> void:
	# Canonical see-through rig: blue at (0,2,-2) facing -Z, orange at
	# (6,2,0) facing -Z, main camera at (0,2,-7) looking +Z straight at
	# blue. Expected virtual camera (Portal 2 geometry — position maps
	# with the pure pair rotation, orientation maps with the mirror flip):
	# position (6,2,-5), forward +orange normal = (0,0,-1).
	if _blue == null or _orange == null:
		return
	_blue.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 2, -2))
	_orange.global_transform = Transform3D(Basis.IDENTITY, Vector3(6, 2, 0))
	_blue.set("is_active", true)
	_orange.set("is_active", true)
	_blue.set("visible", true)
	_orange.set("visible", true)
	_camera.global_transform = Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), Vector3(0, 2, -7))
	_camera.current = true
	# Headless reports a dummy renderer, which the disc (correctly) treats
	# as "RT unavailable". Force it so the virtual-camera math is testable
	# headlessly — the SubViewport update itself is a no-op without a GPU.
	if "_rendering_available" in _blue:
		_blue.set("_rendering_available", true)


func _run_see_through_checks() -> void:
	if _blue == null:
		_check("see_through", false, "see-through: blue disc missing (BLOCKED: portal_disc.gd does not compile — no discs)")
		return
	# Live structure: SubViewport + camera + texture on the disc.
	var vps := _disc_viewports(_blue)
	var cams := _disc_cameras(_blue)
	var rts := _disc_rt_textures(_blue)
	_check("see_through", not vps.is_empty(),
		"blue disc owns a SubViewport (live see-through render target)")
	_check("see_through", not cams.is_empty(),
		"blue disc owns a portal Camera3D (view from the paired portal)")
	_check("see_through", not rts.is_empty(),
		"blue disc's face material shows a ViewportTexture")
	if not rts.is_empty():
		_rt_texture = rts[0] as ViewportTexture
	# RT renders non-black (headless: degrades to WARN when unreadable).
	if _rt_texture != null:
		var img: Image = _rt_texture.get_image()
		if img == null or img.get_width() == 0 or img.get_height() == 0:
			_warn("see_through", false,
				"RT pixel read unavailable headless (no GPU) — non-black render NOT proven here; needs on-device check")
		else:
			var total := 0.0
			var n := 0
			for y in range(0, img.get_height(), 4):
				for x in range(0, img.get_width(), 4):
					total += img.get_pixel(x, y).get_luminance()
					n += 1
			var mean := total / maxf(float(n), 1.0)
			_rt_baseline = mean
			_check("see_through", mean > 0.01,
				"RT renders non-black (mean luminance %s)" % str(mean))
	else:
		_check("see_through", false,
			"RT renders non-black — BLOCKED: no ViewportTexture on the disc")
	# Virtual-camera geometry: position maps with the pure pair rotation,
	# orientation maps with the mirror flip (a camera looking INTO the
	# entry portal must look OUT OF the exit portal).
	if _blue.has_method("get_virtual_camera_transform"):
		var vt: Transform3D = _blue.call("get_virtual_camera_transform")
		_virt_before = vt
		_check("see_through", _approx(vt.origin, Vector3(6, 2, -5), 0.35),
			"virtual camera sits mirrored in front of the partner portal (got %s, want (6, 2, -5))" % str(vt.origin))
		var fwd := -vt.basis.z
		_check("see_through", _approx(fwd, Vector3(0, 0, -1), 0.15),
			"virtual camera looks OUT of the partner portal (forward %s, want (0, 0, -1)) — same mirror flip the teleport velocity needs" % str(fwd))
		# FlipY (about local Y) keeps up upright; a FlipX-style mirror
		# would pass the forward check but render the view upside-down.
		_check("see_through", _approx(vt.basis.y, Vector3(0, 1, 0), 0.15),
			"virtual camera stays upright (up %s, want (0, 1, 0))" % str(vt.basis.y))
	else:
		_warn("see_through", false,
			"blue disc exposes no get_virtual_camera_transform() probe — virtual-camera orientation not observable headlessly")
	# Source-level cross-check for the flip: the virt computation must
	# mention a flip/mirror (WARN only — the behavioral check above is
	# authoritative, so a differently-implemented flip is not failed).
	var disc_src := _read_file("res://scripts/player/portal_disc.gd")
	var flip_in_virt := false
	for line in disc_src.split("\n"):
		if line.contains("virt") and line.contains("partner") and (line.contains("lip") or line.contains("irror")):
			flip_in_virt = true
			break
	_warn("see_through", flip_in_virt,
		"virtual-camera mapping mentions a mirror flip in source (if absent, the behavioral check above is the verdict)")
	# Shimmer root exists (the visible fallback).
	var vis_root: Node3D = _blue.get_node_or_null("Visuals")
	_check("see_through", vis_root != null and vis_root.visible,
		"disc has a visible shimmer/visual root (fallback rendering exists)")
	# Move the partner now; the tracking check (next stage, after frames)
	# verifies the virtual camera followed it.
	if _orange != null:
		_orange.global_transform = Transform3D(Basis.IDENTITY, Vector3(6, 3, 2))


func _run_tracking_check() -> void:
	if _blue == null or not _blue.has_method("get_virtual_camera_transform"):
		_check("see_through", false,
			"RT updates when the paired portal moves — BLOCKED: no virtual-camera probe (discs missing)")
		return
	var vt: Transform3D = _blue.call("get_virtual_camera_transform")
	_check("see_through", _approx(vt.origin, Vector3(6, 3, -3), 0.35),
		"virtual camera follows the moved partner (got %s, want (6, 3, -3))" % str(vt.origin))
	_check("see_through", not _approx(vt.origin, _virt_before.origin, 0.05),
		"virtual camera moved when the partner moved (before %s, after %s)" % [str(_virt_before.origin), str(vt.origin)])


func _run_fallback_checks() -> void:
	# Partner was deactivated in the previous stage: the RT must switch
	# off and the shimmer must stay visible — never a black face.
	if _blue == null:
		_check("see_through", false, "fallback: blue disc missing (BLOCKED: portal_disc.gd does not compile — no discs)")
		return
	var has_fallback_api := _blue.has_method("is_seethrough_active") \
		or _read_file("res://scripts/player/portal_disc.gd").contains("force_seethrough_off")
	_check("see_through", has_fallback_api,
		"a fallback switch exists (is_seethrough_active / force_seethrough_off) — RT failure must engage shimmer, not a black disc")
	_check("see_through", _portal_source.contains("fallback"),
		"portal sources implement a fallback path ('fallback' in portal code)")
	if _blue.has_method("is_seethrough_active"):
		var active: bool = _blue.call("is_seethrough_active")
		_check("see_through", active == false,
			"partner gone -> see-through deactivates (is_seethrough_active=%s)" % str(active))
	var rt_surface: Node3D = _blue.get_node_or_null("SeeThrough")
	if rt_surface != null:
		_check("see_through", rt_surface.visible == false,
			"partner gone -> RT surface hides (visible=%s)" % str(rt_surface.visible))
	var vis_root: Node3D = _blue.get_node_or_null("Visuals")
	_check("see_through", vis_root != null and vis_root.visible,
		"partner gone -> shimmer root still visible (fallback shows, never black)")


func _run_chamber_stage() -> void:
	if _chambers.is_empty():
		_check("puzzles", false,
			"at least one test chamber shipped (MISSING: no chamber/puzzle scene or script found under res://scenes or res://scripts)")
		_stage = 99
		return
	if _chamber_idx >= _chambers.size() or _chamber_idx >= 6:
		_stage = 99
		return
	if _chamber_node == null:
		# Instantiate this chamber.
		var info: Dictionary = _chambers[_chamber_idx]
		var path: String = info["path"]
		var kind: String = info["kind"]
		if kind == "missing":
			_check("puzzles", false, "chamber %s catalogued in CompletionStore.ROOMS but script missing on disk" % path)
			_chamber_idx += 1
			return
		if kind == "tscn":
			var ps = load(path) as PackedScene
			if ps == null or not ps.can_instantiate():
				_check("puzzles", false, "chamber %s loads + instantiates" % path)
				_chamber_idx += 1
				return
			_chamber_node = ps.instantiate()
		else:
			var scr = load(path)
			if scr == null or not scr.can_instantiate():
				_check("puzzles", false, "chamber script %s loads + instantiates" % path)
				_chamber_idx += 1
				return
			var inst: Object = (scr as GDScript).new()
			if not (inst is Node):
				_check("puzzles", false, "chamber script %s instantiates a Node (got %s)" % [path, inst.get_class()])
				_chamber_idx += 1
				return
			_chamber_node = inst as Node
		_arena.add_child(_chamber_node)
		_chamber_wait = 0
		return
	_chamber_wait += 1
	if _chamber_wait < 3:
		return
	# Solve this chamber.
	var info: Dictionary = _chambers[_chamber_idx]
	var path: String = info["path"]
	_check("puzzles", _chamber_node != null, "chamber %s instantiates" % path)
	var src := _read_file(path) if info["kind"] == "gd" else ""
	if info["kind"] == "tscn":
		src = _read_file(path)
	_check("puzzles", src.contains("portal") or _chamber_node.find_child("PortalDisc", true, false) != null or _chamber_node.find_child("PortalEmitter", true, false) != null,
		"chamber %s requires portals (mentions portal / contains portal nodes)" % path)
	var completion = _completion_of(_chamber_node)
	if completion == null:
		_warn("puzzles", false,
			"chamber %s exposes no completion API (is_complete / completed) — scripted completion not observable" % path)
	else:
		_try_solve(_chamber_node)
		var after = _completion_of(_chamber_node)
		_check("puzzles", after == true,
			"chamber %s completable by scripted solution (completed=%s)" % [path, str(after)])
		if _chamber_node.has_method("reset"):
			_chamber_node.call("reset")
			var reset_state = _completion_of(_chamber_node)
			_check("puzzles", reset_state == false,
				"chamber %s resets to incomplete (completed=%s)" % [path, str(reset_state)])
		else:
			_warn("puzzles", false, "chamber %s exposes no reset() — replay/restart untestable" % path)
	_chamber_node.queue_free()
	_chamber_node = null
	_chamber_idx += 1
	_chamber_wait = 0


func _finish() -> void:
	print("VERIFY_PORTALS: %d passed, %d failed, %d warnings" % [_passes, _fails, _warns])
	for section in _sec.keys():
		var c: Array = _sec[section]
		print("VERIFY_PORTALS [%s]: %d passed, %d failed" % [section, c[0], c[1]])
	if _fails == 0:
		print("VERIFY_PORTALS: ALL CHECKS PASSED")
	else:
		printerr("VERIFY_PORTALS: %d CHECK(S) FAILED" % _fails)
	quit(1 if _fails > 0 else 0)
