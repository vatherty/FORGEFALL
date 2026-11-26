# tools/verify_ads_alignment.gd — BB-1 ADS verification.
# Usage:
#   godot --headless --path <project> --script res://tools/verify_ads_alignment.gd
#   xvfb-run godot --path <project> --script res://tools/verify_ads_alignment.gd
#
# BB-1 was Colin's playtest report: "the sights do not work, either iron
# or like a sniper scope or acog". The audit behind this verify found:
# the ADS math centred the Sight ANCHOR for most weapons, but (a) the
# shipped GLB optics are opaque with no dot/reticle in them, (b) several
# JSON sight anchors disagreed with the actual model geometry (ember
# front post 19 mm above its anchor, hv44 blade 13 mm, p9 line 4.5 mm),
# (c) the LMG anchor's X was ignored (+38 px on screen), (d) every optic
# shared one FOV zoom and there was no scope view at all.
#
# This verify pins the fix in three layers:
#   A. DATA — every WEAPONS id has an explicit SIGHT_ANCHOR + OPTIC_CLASS
#      entry with the audited values; per-class zooms are as designed.
#   B. POSE — headless-safe: at full ADS blend the viewmodel sits at
#      -anchor on x/y (anchor lands on the camera axis); scope weapons
#      hide the viewmodel; reflex/ACOG weapons grow a visible AdsDot.
#   C. RENDERED (real renderer only; skipped under --headless) — the
#      REAL player scene + WeaponManager + HUD: ADS per optic class,
#      camera FOV converges to preferred/zoom, the sight anchor projects
#      within 6 px of screen centre, the reflex dot renders at centre,
#      the iron front-post tip renders at centre, and the sniper scope
#      overlay shows (black surround, bright aperture, reticle) only
#      while scoped. Captures land in /tmp/ads_verify/.
#
# BB-1b (Colin, on device, after BB-1): "the acog now has a dot, but
# it's still opaque and can't see [through it]" — the GLB optics are
# SOLID: behind the front lens plate, two more plates cross the sight
# line, so the centred dot sat on a dark plug. Layer B now also pins
# the see-through contract headlessly (lens material is transparent
# glass; no triangle centroid survives inside the 30 mm sight tunnel),
# and layer C proves it in pixels: a lime panel sits exactly on the
# sight line and must be VISIBLE through the ar7/smg9/br3 apertures
# (green fraction + mean luminance inside the projected lens rect).
#
# BB-1c (Colin: "I still want a fov zoom as you have to get closer to
# the gun, but then a zoom and parallax effect on the lens as well" +
# "The zoom on the acog lens should only be 1.5x the fov zoom 3x"):
# the BR-3's ACOG gains a picture-in-picture lens — the full-screen 3x
# FOV zoom is UNCHANGED, and the glass itself shows the world through
# a second camera at main_fov / 1.5 (WeaponBase.LENS_EXTRA_ZOOM,
# pinned 1.5), with the reticle drawn in the glass, parallax swim and
# scope shadow (assets/shaders/optic_lens.gdshader). Layer B pins the
# new pose contract for the ACOG (floating AdsDot hidden while the
# lens is up; lens rig active) and the parallax conversion math;
# layer D proves magnification + parallax in rendered pixels against
# a checkerboard target and the glass fallback at hip. The BB-1b
# tunnel check skips the PipScreen quads by name: they are the sight
# picture sitting in the tunnel by design, not GLB blockers.
#
# BB-1d (Colin: "Do it with all the sights not just the acog, the red
# dot sight needs similar treatment. Just without the zoom, just
# parallax"): the SAME rig generalised to the reflex family (ar7,
# smg9) with the zoom pinned OFF — WeaponBase.LENS_EXTRA_ZOOM_REFLEX
# is exactly 1.0, so the reflex lens camera's fov EQUALS the main
# camera's fov, and the shader displays the screen's own angular crop
# of that frame (WeaponBase.lens_sample_rect_for): the picture
# registers 1:1 with the world around the housing (no magnification)
# and the treatment is pure parallax — image swim + a dot-only
# reticle in the glass, in a rounded-rect aperture fitted to each
# measured reflex window. Layer B's pose contract extends to reflex
# (BB-1d supersedes the BB-1 reflex dot assertion exactly as BB-1c
# superseded the ACOG one: floating dot hidden while the lens is up),
# layer E proves the no-zoom pin (texture-normalised magnification
# ~1.0 AND on-screen in-window period ~ the surrounding view's),
# parallax swim against a fixed dot, and the hip fallback, for both
# reflex weapons.
#
# NOTE: game scripts are load()ed dynamically inside _process (repo
# pattern — compile-time references fail in --script mode because the
# Sfx autoload does not exist yet at compile time).
extends SceneTree

const OUT_DIR := "/tmp/ads_verify"
const PIP_OUT := "/home/hatch/workspace/bugbash-finish/ads-audit/pip"
const PIP_REFLEX_OUT := "/home/hatch/workspace/bugbash-finish/ads-audit/pip-reflex"
const CENTRE := Vector2(640, 360)

# Audited contract values (see Arsenal.SIGHT_ANCHOR / OPTIC_CLASS).
const EXPECT_ANCHOR := {
	"ar7": Vector3(0.0, 0.142, -0.118), "lr8": Vector3(0.0, 0.111, -0.063),
	"sg12": Vector3(0.0, 0.082, -0.170), "smg9": Vector3(0.0, 0.147, -0.069),
	"lmg": Vector3(0.024, 0.143, 0.007), "p9": Vector3(0.0, 0.0745, -0.100),
	"br3": Vector3(0.0, 0.193, -0.090), "hv44": Vector3(0.0, 0.1025, -0.180),
	"ember": Vector3(0.0, 0.093, -0.105), "raptor": Vector3(0.0, 0.104, -0.120),
}
const EXPECT_OPTIC := {
	"ar7": "reflex", "lr8": "scope", "sg12": "iron", "smg9": "reflex",
	"lmg": "iron", "p9": "iron", "br3": "acog", "hv44": "iron",
	"ember": "iron", "raptor": "none",
}
const EXPECT_ZOOM := {"iron": 1.1, "reflex": 1.15, "acog": 3.0, "scope": 5.0, "none": 1.0}

var _failures: Array = []
var _checks := 0
var _frames := 0
var _ran := false
var ArsenalScript: GDScript


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: ", label)
	else:
		_failures.append(label)
		printerr("FAIL: ", label)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3 or _ran:
		return false
	_ran = true
	ArsenalScript = load("res://scripts/weapons/arsenal.gd")
	_run()
	return false


func _run() -> void:
	_check_data()
	_check_lens_math()
	_check_glass()
	_check_poses()
	if DisplayServer.get_name() == "headless":
		print("NOTE: headless renderer — rendered layer C skipped (anchor/dot/"
			+ "scope-overlay pixel checks need a real renderer; rerun under xvfb-run).")
	else:
		await _check_rendered()
	print("ADS VERIFY: %d checks, %d failures" % [_checks, _failures.size()])
	quit(1 if not _failures.is_empty() else 0)


# ---------------------------------------------------------------- A. data
func _check_data() -> void:
	var weapons: Dictionary = ArsenalScript.get("WEAPONS")
	# Explicit entries: scan the arsenal source so a future silent
	# fallback (table entry deleted -> JSON/default takes over) fails.
	var src := FileAccess.get_file_as_string("res://scripts/weapons/arsenal.gd")
	var anchor_block := _const_block(src, "SIGHT_ANCHOR")
	var optic_block := _const_block(src, "OPTIC_CLASS")
	for wid in weapons.keys():
		var id := str(wid)
		_check(anchor_block.contains("\"%s\":" % id), "%s has an explicit SIGHT_ANCHOR entry" % id)
		_check(optic_block.contains("\"%s\":" % id), "%s has an explicit OPTIC_CLASS entry" % id)
		var anchor: Vector3 = ArsenalScript.call("sight_anchor", id)
		if EXPECT_ANCHOR.has(id):
			_check(anchor.is_equal_approx(EXPECT_ANCHOR[id]),
				"%s sight_anchor %s == audited %s" % [id, anchor, EXPECT_ANCHOR[id]])
		_check(str(ArsenalScript.call("optic_class", id)) == str(EXPECT_OPTIC.get(id, "?")),
			"%s optic_class == %s" % [id, EXPECT_OPTIC.get(id, "?")])
		_check(is_equal_approx(float(ArsenalScript.call("sight_height", id)), anchor.y),
			"%s sight_height wraps sight_anchor.y" % id)
	for cls in EXPECT_ZOOM:
		# Zoom is per class: check via a representative weapon of the class.
		for wid in EXPECT_OPTIC:
			if EXPECT_OPTIC[wid] == cls:
				_check(is_equal_approx(float(ArsenalScript.call("ads_zoom", wid)), float(EXPECT_ZOOM[cls])),
					"ads_zoom(%s)=%s for class %s" % [wid, EXPECT_ZOOM[cls], cls])
				break


# ------------------------------------------------- BB-1c/1d lens math
# The pinned ratios + the parallax conversion, checkable headlessly.
func _check_lens_math() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_base.gd")
	_check(src.contains("const LENS_EXTRA_ZOOM := 1.5"),
		"LENS_EXTRA_ZOOM pinned at exactly 1.5 (Colin's spec)")
	_check(src.contains("const LENS_EXTRA_ZOOM_REFLEX := 1.0"),
		"LENS_EXTRA_ZOOM_REFLEX pinned at exactly 1.0 (Colin's no-zoom spec)")
	var WB: GDScript = load("res://scripts/weapons/weapon_base.gd")
	_check(is_equal_approx(float(WB.call("lens_extra_zoom_for", "acog")), 1.5),
		"lens extra zoom for acog == 1.5")
	_check(is_equal_approx(float(WB.call("lens_extra_zoom_for", "reflex")), 1.0),
		"lens extra zoom for reflex == 1.0 (no zoom, pure parallax)")
	_check(bool(WB.call("has_lens_pip", "acog")) and bool(WB.call("has_lens_pip", "reflex")),
		"acog + reflex carry the PiP lens")
	_check(not bool(WB.call("has_lens_pip", "iron")) and not bool(WB.call("has_lens_pip", "scope"))
		and not bool(WB.call("has_lens_pip", "none")),
		"iron/scope/none stay out of the PiP lens (BB-1d scope limit)")
	# BB-1d: the reflex crop — a screen centred on the axis maps to a
	# centred rect; a 40 mm screen 0.46 m out at fov 78.26 spans
	# 0.040 / (2 * 0.46 * tan(39.13 deg)) = 0.0533 of the frame.
	var rect: Vector4 = WB.call("lens_sample_rect_for",
		Vector3(0, 0, -0.46), Vector2(0.040, 0.034), 78.26)
	_check(absf(rect.x - 0.5) < 0.001 and absf(rect.y - 0.5) < 0.001,
		"reflex crop is centred for an on-axis screen (%s)" % rect)
	_check(absf(rect.z - 0.0533) < 0.002 and absf(rect.w - 0.0453) < 0.002,
		"reflex crop size is the screen's angular footprint (%s)" % rect)
	var off_rect: Vector4 = WB.call("lens_sample_rect_for",
		Vector3(0.046, 0.046, -0.46), Vector2(0.040, 0.034), 78.26)
	_check(off_rect.x > 0.55 and off_rect.y < 0.45,
		"reflex crop follows an off-axis screen (+x -> +u, +y -> -v) (%s)" % off_rect)
	_check(WB.call("lens_eye_offset_for", Vector3(0, 0, -0.47)) == Vector2.ZERO,
		"lens parallax offset is zero when the sight is on the eye axis")
	var ox: Vector2 = WB.call("lens_eye_offset_for", Vector3(0.0235, 0, -0.47))
	_check(ox.x > 0.10 and ox.x < 0.12 and is_zero_approx(ox.y),
		"sight right of axis -> +u parallax offset (%s)" % ox)
	var oy: Vector2 = WB.call("lens_eye_offset_for", Vector3(0, 0.0235, -0.47))
	_check(oy.y < -0.10 and oy.y > -0.12 and is_zero_approx(oy.x),
		"sight above axis -> -v parallax offset (%s)" % oy)
	var big: Vector2 = WB.call("lens_eye_offset_for", Vector3(0.47, 0, -0.47))
	_check(big.length() <= 0.161, "lens parallax offset clamped (%s)" % big)


func _const_block(src: String, name: String) -> String:
	var start := src.find("const %s := {" % name)
	if start < 0:
		return ""
	var end := src.find("\n}", start)
	if end < 0:
		return ""
	return src.substr(start, end - start)


# ---------------------------------------------------------------- B. pose
func _check_poses() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var player := CharacterBody3D.new()
	stage.add_child(player)
	var camera := Camera3D.new()
	player.add_child(camera)
	camera.current = true
	var weapons: Dictionary = ArsenalScript.get("WEAPONS")
	for wid in weapons.keys():
		var id := str(wid)
		var w: Variant = ArsenalScript.call("make_weapon", id)
		stage.add_child(w)
		w.call("attach", player, camera)
		w.call("on_equip")
		w.call("set_ads", true)
		for i in 12:
			w.call("_process", 0.2)
		var vm: Node3D = w.get("_viewmodel")
		var anchor: Vector3 = ArsenalScript.call("sight_anchor", id)
		_check(is_equal_approx(float(w.call("get_ads_blend")), 1.0), "%s ADS blend reaches 1" % id)
		_check(vm != null and vm.position.is_equal_approx(w.get("_ads_pos")),
			"%s viewmodel settles at _ads_pos" % id)
		if vm != null:
			var sight := vm.get_node_or_null("Sight") as Marker3D
			_check(sight != null, "%s viewmodel has a Sight marker" % id)
			if sight != null:
				var centred := vm.position + sight.position
				_check(absf(centred.x) < 0.0015 and absf(centred.y) < 0.0015,
					"%s sight anchor on camera axis at full ADS (off %s)" % [id, centred])
			var optic := str(ArsenalScript.call("optic_class", id))
			if optic == "scope":
				_check(not vm.visible, "%s scope: viewmodel hidden at full ADS (HUD overlay takes over)" % id)
			else:
				_check(vm.visible, "%s viewmodel stays visible at full ADS" % id)
			var dot := vm.get_node_or_null("AdsDot")
			if optic in ["acog", "reflex"]:
				# BB-1c superseded the BB-1 dot assertion for the ACOG,
				# BB-1d extends the same contract to reflex: at full
				# ADS the PiP lens is up and the floating dot stands
				# down — the in-glass reticle replaces it.
				_check(dot != null and not (dot as MeshInstance3D).visible,
					"%s %s: AdsDot present but hidden while the PiP lens is up" % [id, optic])
				_check(bool(w.call("is_lens_pip_active")),
					"%s %s: PiP lens active at full ADS" % [id, optic])
				var lvp: Variant = w.call("get_lens_viewport")
				_check(lvp != null and (lvp as SubViewport).render_target_update_mode
					== SubViewport.UPDATE_ALWAYS,
					"%s %s: lens viewport rendering at full ADS" % [id, optic])
				_check(w.call("get_lens_screen") != null,
					"%s %s: lens screen bound to the rig" % [id, optic])
			else:
				_check(dot == null, "%s %s: no AdsDot for non-dot optic" % [id, optic])
		w.call("on_unequip")
		w.queue_free()
	stage.queue_free()


# ------------------------------------------------- BB-1b glass (headless)
# The see-through contract, checkable without a renderer: for every
# reflex/ACOG weapon the lens elements carry transparent glass, and
# the 30 mm sight tunnel along the anchor axis is genuinely empty —
# no surviving triangle centroid inside it in ANY viewmodel mesh.
func _check_glass() -> void:
	for id in ["ar7", "smg9", "br3"]:
		var vm: Node3D = ArsenalScript.call("build_viewmodel", id)
		_check(vm != null, "%s viewmodel builds for glass checks" % id)
		if vm == null:
			continue
		var lenses: Array = []
		_collect_lenses(vm, lenses)
		_check(not lenses.is_empty(), "%s has a lens element to make glass" % id)
		for lens in lenses:
			var mat := (lens as MeshInstance3D).get_active_material(0)
			_check(mat is StandardMaterial3D
				and (mat as StandardMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA
				and (mat as StandardMaterial3D).albedo_color.a <= 0.3,
				"%s lens '%s' is transparent glass (alpha <= 0.3)" % [id, (lens as MeshInstance3D).name])
		var anchor: Vector3 = ArsenalScript.call("sight_anchor", id)
		var box := AABB(
			Vector3(anchor.x - 0.015, anchor.y - 0.015, anchor.z - 0.055),
			Vector3(0.030, 0.030, 0.110))
		var blockers := 0
		var meshes: Array = []
		_collect_meshes(vm, meshes)
		for mi in meshes:
			# BB-1c/BB-1d: the PiP screens sit IN the tunnel by design
			# — they ARE the sight picture, not GLB blockers.
			if (mi as MeshInstance3D).name.contains("PipScreen"):
				continue
			var mesh := (mi as MeshInstance3D).mesh
			if mesh == null:
				continue
			var rel := _rel_transform(mi as Node3D, vm)
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var tris := index.size() / 3 if index.size() > 0 else verts.size() / 3
				for t in tris:
					var c := Vector3.ZERO
					for k in 3:
						var vi := index[t * 3 + k] if index.size() > 0 else t * 3 + k
						c += rel * verts[vi]
					if box.has_point(c / 3.0):
						blockers += 1
		_check(blockers == 0, "%s sight tunnel is open (0 blocking triangles, found %d)" % [id, blockers])
		vm.free()


func _collect_lenses(node: Node, out: Array) -> void:
	if node is MeshInstance3D:
		var lname := node.name.to_lower()
		if lname.contains("lens") or lname.contains("glass"):
			out.append(node)
	for c in node.get_children():
		_collect_lenses(c, out)


func _collect_meshes(node: Node, out: Array) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_collect_meshes(c, out)


func _rel_transform(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


# ------------------------------------------------------------- C. rendered
func _check_rendered() -> void:
	root.size = Vector2i(1280, 720)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var stage := Node3D.new()
	stage.name = "Stage"
	root.add_child(stage)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.72, 0.78, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.85
	we.environment = env
	stage.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30, 30, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = false
	stage.add_child(sun)
	var wall := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(40, 20, 0.5)
	wall.mesh = bm
	var wm_mat := StandardMaterial3D.new()
	wm_mat.albedo_color = Color(0.93, 0.89, 0.79)
	wall.material_override = wm_mat
	wall.position = Vector3(0, 1, -12)
	stage.add_child(wall)
	var floor_body := StaticBody3D.new()
	var floor_mi := MeshInstance3D.new()
	var fbm := BoxMesh.new()
	fbm.size = Vector3(40, 0.5, 40)
	floor_mi.mesh = fbm
	var fcol := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(40, 0.5, 40)
	fcol.shape = fbox
	floor_body.add_child(floor_mi)
	floor_body.add_child(fcol)
	floor_body.position = Vector3(0, -0.26, 0)
	stage.add_child(floor_body)

	var player: Node = load("res://scenes/player.tscn").instantiate()
	stage.add_child(player)
	player.global_position = Vector3(0, 0.1, 0)
	var hud: CanvasLayer = load("res://scripts/ui/hud.gd").new()
	root.add_child(hud)
	var camera: Camera3D = player.get("camera")
	var manager: Node = player.get_node("WeaponManager")
	# Let the player settle + HUD bind.
	await _wait_frames(30)

	# BB-1b: a lime panel exactly on the sight line — the see-through
	# checks assert this panel is visible THROUGH the reflex/ACOG
	# apertures (it is unshaded and unmissable when not occluded).
	var panel := MeshInstance3D.new()
	var pbm := BoxMesh.new()
	pbm.size = Vector3(3.0, 3.0, 0.1)
	panel.mesh = pbm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.25, 0.95, 0.25)
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	panel.material_override = pmat
	panel.position = Vector3(0, camera.global_position.y, -11.6)
	stage.add_child(panel)
	await _wait_frames(5)

	# [weapon, slot to equip, feature kind]
	var cases := [
		["lmg", "primary", "anchor"],
		["p9", "secondary", "iron_tip"],
		["ar7", "primary", "dot_glass"],
		["smg9", "primary", "dot_glass"],
		["br3", "primary", "dot_glass"],
		["lr8", "primary", "scope"],
	]
	for c in cases:
		await _render_case(player, manager, camera, hud, str(c[0]), str(c[1]), str(c[2]))
	await _check_pip(player, manager, camera, panel)
	await _check_pip_reflex(player, manager, camera, panel)
	stage.queue_free()
	await process_frame


func _render_case(player: Node, manager: Node, camera: Camera3D, hud: CanvasLayer, id: String, slot: String, kind: String) -> void:
	# equip_loadout only replaces slot CONTENTS; the current slot stays
	# wherever the previous case left it, so switch first, then rebuild
	# the slot's weapon, then wait for the swap to actually land.
	manager.call("equip_loadout", "ar7", "p9")
	manager.call("switch_to", slot)
	if slot == "primary":
		manager.call("set_slot", "primary", id)
	await _wait_until(func() -> bool: return _weapon_is(manager, id), 5000)
	var weapon: Variant = manager.call("current_weapon")
	_check(weapon != null and str(weapon.get("weapon_id")) == id, "%s equipped for rendered case" % id)
	if weapon == null:
		return
	var zoom := float(ArsenalScript.call("ads_zoom", id))
	Input.action_press("ads")
	var ok := await _wait_until(func() -> bool: return _ads_settled(player, weapon, camera, zoom), 6000)
	_check(ok, "%s ADS settles: blend 1 + FOV %.1f (zoom %.2fx)" % [id, camera.fov, zoom])
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(OUT_DIR + "/ads_" + id + ".png")
	# Anchor projection (works even when the viewmodel is hidden: scope).
	var vm: Node3D = weapon.get("_viewmodel")
	var sight := vm.get_node_or_null("Sight") as Marker3D if vm != null else null
	if sight != null:
		var px := camera.unproject_position(sight.global_position)
		_check((px - CENTRE).length() <= 6.0, "%s sight anchor projects %.1f px from centre" % [id, (px - CENTRE).length()])
	match kind:
		"dot":
			var dot := _red_centroid(img)
			_check(dot.x >= 0.0 and (dot - CENTRE).length() <= 8.0,
				"%s reflex dot renders at centre (centroid %s)" % [id, dot])
		"dot_glass":
			var dot := _red_centroid(img)
			_check(dot.x >= 0.0 and (dot - CENTRE).length() <= 8.0,
				"%s reflex dot renders at centre (centroid %s)" % [id, dot])
			# BB-1b: the world (lime panel on the sight line) must be
			# visible through the aperture — sample the projected lens
			# rect's inner 60%, excluding the dot's own 14x14 centre.
			var lens := _find_lens(vm) if vm != null else null
			_check(lens != null, "%s lens element found for see-through check" % id)
			if lens != null:
				var stats := _aperture_stats(img, camera, lens)
				_check(stats[1] >= 0.5,
					"%s aperture shows the world: green frac %.3f >= 0.5" % [id, stats[1]])
				_check(stats[0] >= 0.45,
					"%s aperture is not a dark plug: mean lum %.3f >= 0.45" % [id, stats[0]])
		"iron_tip":
			var tip := _iron_tip_y(img)
			_check(tip > 0 and absf(tip - CENTRE.y) <= 9.0,
				"%s front-post tip renders at centre height (y=%d)" % [id, tip])
		"scope":
			var scope_root: Control = hud.get("_scope_root")
			_check(scope_root != null and scope_root.visible, "lr8 scope overlay visible at full ADS")
			# Sample inside the aperture but OFF the reticle cross
			# (the exact centre pixel is the reticle dot by design).
			_check(_lum(img.get_pixel(668, 388)) > 0.35, "lr8 aperture shows the world off-reticle (lum %.2f)" % _lum(img.get_pixel(668, 388)))
			_check(_lum(img.get_pixel(6, 6)) < 0.05, "lr8 surround is black (lum %.2f)" % _lum(img.get_pixel(6, 6)))
			_check(_lum(img.get_pixel(520, 360)) < 0.16, "lr8 reticle line present left of centre (lum %.2f)" % _lum(img.get_pixel(520, 360)))
			_check(_lum(img.get_pixel(520, 300)) > 0.35, "lr8 aperture off-line shows the world (lum %.2f)" % _lum(img.get_pixel(520, 300)))
	Input.action_release("ads")
	var released := await _wait_until(func() -> bool: return float(weapon.call("get_ads_blend")) < 0.05, 4000)
	_check(released, "%s ADS releases cleanly" % id)
	if kind == "scope":
		var scope_root2: Control = hud.get("_scope_root")
		_check(scope_root2 != null and not scope_root2.visible, "lr8 scope overlay hides on ADS release")


# BB-1b: first lens/glass MeshInstance3D in a viewmodel subtree.
func _find_lens(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		var lname := node.name.to_lower()
		if lname.contains("lens") or lname.contains("glass"):
			return node as MeshInstance3D
	for c in node.get_children():
		var found := _find_lens(c)
		if found != null:
			return found
	return null


# BB-1b: [mean luminance, lime-panel fraction] inside the projected
# lens rect (inner 60%, centre 14x14 excluded — that's the dot).
func _aperture_stats(img: Image, camera: Camera3D, lens: MeshInstance3D) -> Array:
	var aabb := lens.get_aabb()
	var gt := lens.global_transform
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for xi in [aabb.position.x, aabb.end.x]:
		for yi in [aabb.position.y, aabb.end.y]:
			for zi in [aabb.position.z, aabb.end.z]:
				var px := camera.unproject_position(gt * Vector3(xi, yi, zi))
				lo = lo.min(px)
				hi = hi.max(px)
	var inner_lo := lo + (hi - lo) * 0.2
	var inner_hi := hi - (hi - lo) * 0.2
	var n := 0
	var green := 0
	var lum_sum := 0.0
	for y in range(int(inner_lo.y), int(inner_hi.y)):
		for x in range(int(inner_lo.x), int(inner_hi.x)):
			if absf(x - CENTRE.x) < 7 and absf(y - CENTRE.y) < 7:
				continue
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var p := img.get_pixel(x, y)
			lum_sum += _lum(p)
			n += 1
			if p.g > 0.55 and p.g - p.r > 0.25 and p.g - p.b > 0.25:
				green += 1
	return [lum_sum / maxf(n, 1), float(green) / maxf(n, 1)]


# ------------------------------------------------- D. BB-1c PiP (rendered)
# Checkerboard target (regular cells, measurable along both axes —
# the same physical feature is measured in both views, so the ratio
# needs no knowledge of the cell size): magnification is read on the
# vertical (fov) axis — the lens texture
# period vs the main frame period, each normalised by its frame
# height; parallax is read horizontally: freeze the weapon, drive the
# shader's eye_offset, and the in-lens image must swim against the
# offset while the in-glass reticle stays put and the edges darken.
func _check_pip(player: Node, manager: Node, camera: Camera3D, panel: MeshInstance3D) -> void:
	DirAccess.make_dir_recursive_absolute(PIP_OUT)
	panel.visible = false
	var board := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(8, 4, 0.1)
	board.mesh = bm
	var bimg := Image.create(800, 400, false, Image.FORMAT_RGB8)
	for y in 400:
		for x in 800:
			var cell := (x / 40 + y / 40) % 2
			bimg.set_pixel(x, y, Color(0.95, 0.95, 0.95) if cell == 0 else Color(0.05, 0.05, 0.05))
	var bmat := StandardMaterial3D.new()
	bmat.albedo_texture = ImageTexture.create_from_image(bimg)
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	board.material_override = bmat
	board.position = Vector3(0, camera.global_position.y, -11.55)
	player.get_parent().add_child(board)
	await _wait_frames(3)

	manager.call("equip_loadout", "ar7", "p9")
	manager.call("switch_to", "primary")
	manager.call("set_slot", "primary", "br3")
	var equipped := await _wait_until(func() -> bool: return _weapon_is(manager, "br3"), 5000)
	_check(equipped, "br3 PiP case: weapon equipped")
	var weapon: Variant = manager.call("current_weapon")
	if weapon == null:
		return
	Input.action_press("ads")
	var settled := await _wait_until(
		func() -> bool: return _ads_settled(player, weapon, camera, 3.0), 6000)
	_check(settled, "br3 PiP case: ADS settles (full-screen 3x zoom intact)")
	await _wait_frames(6) # let the lens viewport render real frames
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	frame.save_png(PIP_OUT + "/pip_ads_centred.png")
	frame.save_png(OUT_DIR + "/pip_ads_centred.png")

	var lvp: SubViewport = weapon.call("get_lens_viewport")
	_check(lvp != null, "br3 PiP: lens viewport exists")
	if lvp == null:
		Input.action_release("ads")
		return
	var lcam := lvp.get_child(0) as Camera3D
	_check(lcam != null and absf(lcam.fov - camera.fov / 1.5) < 0.6,
		"lens camera fov = main fov / 1.5 (%.2f vs %.2f)" % [lcam.fov if lcam != null else -1.0, camera.fov])
	# Magnification on the fov (vertical) axis, from the lens texture
	# itself (512px — the precise read) vs the main frame (720px).
	var tex_img := lvp.get_texture().get_image()
	var period_tex := _stripe_period_v(tex_img, 256, 60, 452)
	var period_main := _stripe_period_v(frame, 200, 150, 570)
	_check(period_tex > 0.0 and period_main > 0.0,
		"checker period measurable (lens tex %.1f px, main %.1f px)" % [period_tex, period_main])
	if period_tex > 0.0 and period_main > 0.0:
		var mag := (period_tex / 512.0) / (period_main / 720.0)
		_check(mag > 1.30 and mag < 1.75,
			"in-lens magnification %.2f ~= 1.5x the main view (Colin's pin)" % mag)
	# On screen: the checker must be visible INSIDE the lens aperture.
	var disc: MeshInstance3D = weapon.call("get_lens_screen")
	_check(disc != null, "br3 PiP: lens screen bound in the rendered case")
	if disc == null:
		Input.action_release("ads")
		return
	var rect := _project_rect(camera, disc)
	var row := int((rect.position.y + rect.end.y) * 0.5) - 10
	var transitions := _row_transitions(frame, row,
		int(rect.position.x) + 4, int(rect.end.x) - 4)
	_check(transitions >= 3,
		"checker visible inside the lens on screen (%d transitions across the aperture)" % transitions)
	# Parallax: freeze the weapon so the test owns the shader param.
	weapon.set_process(false)
	var mat := disc.material_override as ShaderMaterial
	var profile_a := _row_profile(frame, row, int(rect.position.x), int(rect.end.x))
	var ring_a := _ring_lum(frame, rect)
	var ret_a := _red_centroid_in(frame, rect)
	mat.set_shader_parameter("eye_offset", Vector2(0.12, 0.0))
	await _wait_frames(3)
	await RenderingServer.frame_post_draw
	var frame_b := root.get_texture().get_image()
	frame_b.save_png(PIP_OUT + "/pip_parallax_offset.png")
	frame_b.save_png(OUT_DIR + "/pip_parallax_offset.png")
	var profile_b := _row_profile(frame_b, row, int(rect.position.x), int(rect.end.x))
	var shift := _profile_shift(profile_a, profile_b)
	_check(absf(shift) >= 2.0,
		"parallax: in-lens image swims under eye_offset (shift %.1f px)" % shift)
	_check(shift < 0.0,
		"parallax: image swims AGAINST the eye offset (+u -> content -x, got %.1f)" % shift)
	var ret_b := _red_centroid_in(frame_b, rect)
	_check(ret_a.x >= 0.0 and ret_b.x >= 0.0 and (ret_a - ret_b).length() <= 2.0,
		"parallax: reticle stays fixed in the glass (A %s, B %s)" % [ret_a, ret_b])
	var ring_b := _ring_lum(frame_b, rect)
	_check(ring_b < ring_a * 0.9,
		"scope shadow: aperture edges darken when misaligned (ring lum %.3f -> %.3f)" % [ring_a, ring_b])
	mat.set_shader_parameter("eye_offset", Vector2.ZERO)
	weapon.set_process(true)
	# Hip: lens stands down — viewport not updating, shader back to glass.
	Input.action_release("ads")
	var released := await _wait_until(
		func() -> bool: return float(weapon.call("get_ads_blend")) < 0.05, 4000)
	_check(released, "br3 PiP case: ADS releases")
	await _wait_frames(3)
	_check(not bool(weapon.call("is_lens_pip_active")),
		"br3 PiP: lens inactive at hip")
	_check(lvp.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"br3 PiP: lens viewport NOT updating at hip")
	_check(float(mat.get_shader_parameter("pip_strength")) < 0.05,
		"br3 PiP: shader back to the glass fallback at hip (strength %.2f)"
			% float(mat.get_shader_parameter("pip_strength")))
	await RenderingServer.frame_post_draw
	var hip := root.get_texture().get_image()
	hip.save_png(PIP_OUT + "/pip_hip.png")
	hip.save_png(OUT_DIR + "/pip_hip.png")
	board.queue_free()


# ------------------------------------------------- E. BB-1d reflex PiP
# The reflex treatment, proven per weapon (ar7, smg9) against a fine
# checkerboard (0.2 m cells — ~9 px per cell at the reflex ADS fov, in
# the main frame and in the window alike):
#   * the no-zoom pin: lens camera fov == main camera fov, and the
#     texture-normalised magnification (the BB-1c method) is ~1.0;
#   * registration: the on-screen checker period INSIDE the window
#     matches the period in the surrounding main view (~1:1);
#   * parallax: a small driven eye_offset swims the in-window image
#     against the offset while the in-glass dot holds its place, and
#     a large offset visibly darkens the aperture rim (subtle shadow);
#   * hip: viewport parked, shader back to glass.
func _check_pip_reflex(player: Node, manager: Node, camera: Camera3D, panel: MeshInstance3D) -> void:
	DirAccess.make_dir_recursive_absolute(PIP_REFLEX_OUT)
	panel.visible = false
	await _wait_frames(2) # let _check_pip's board finish freeing
	var board := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(8, 4, 0.1)
	board.mesh = bm
	var bimg := Image.create(800, 400, false, Image.FORMAT_RGB8)
	for y in 400:
		for x in 800:
			var cell := (x / 20 + y / 20) % 2
			bimg.set_pixel(x, y, Color(0.95, 0.95, 0.95) if cell == 0 else Color(0.05, 0.05, 0.05))
	var bmat := StandardMaterial3D.new()
	bmat.albedo_texture = ImageTexture.create_from_image(bimg)
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	board.material_override = bmat
	board.position = Vector3(0, camera.global_position.y, -11.55)
	player.get_parent().add_child(board)
	await _wait_frames(3)
	for id in ["ar7", "smg9"]:
		await _pip_reflex_case(player, manager, camera, id)
	board.queue_free()


func _pip_reflex_case(player: Node, manager: Node, camera: Camera3D, id: String) -> void:
	manager.call("equip_loadout", "ar7", "p9")
	manager.call("switch_to", "primary")
	manager.call("set_slot", "primary", id)
	var equipped := await _wait_until(func() -> bool: return _weapon_is(manager, id), 5000)
	_check(equipped, "%s reflex PiP case: weapon equipped" % id)
	var weapon: Variant = manager.call("current_weapon")
	if weapon == null:
		return
	Input.action_press("ads")
	var settled := await _wait_until(
		func() -> bool: return _ads_settled(player, weapon, camera, 1.15), 6000)
	_check(settled, "%s reflex PiP case: ADS settles (full-screen reflex zoom intact)" % id)
	await _wait_frames(6) # let the lens viewport render real frames
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	frame.save_png(PIP_REFLEX_OUT + "/pip_reflex_%s_ads.png" % id)
	frame.save_png(OUT_DIR + "/pip_reflex_%s_ads.png" % id)

	var lvp: SubViewport = weapon.call("get_lens_viewport")
	_check(lvp != null, "%s reflex PiP: lens viewport exists" % id)
	if lvp == null:
		Input.action_release("ads")
		return
	_check(lvp.size == Vector2i(1024, 1024),
		"%s reflex PiP: lens viewport at the reflex size (%s)" % [id, lvp.size])
	var lcam := lvp.get_child(0) as Camera3D
	_check(lcam != null and absf(lcam.fov - camera.fov) < 0.6,
		"%s reflex PiP: lens camera fov == main fov (%.2f vs %.2f) — no zoom (Colin's pin)"
			% [id, lcam.fov if lcam != null else -1.0, camera.fov])
	# No-zoom, texture-normalised (the BB-1c method): the lens frame
	# and the main frame must show the same checker at the same scale.
	var tex_img := lvp.get_texture().get_image()
	var period_tex := _stripe_period_v(tex_img, tex_img.get_width() / 2, 300, 724)
	var period_main := _stripe_period_v(frame, 560, 150, 570)
	_check(period_tex > 0.0 and period_main > 0.0,
		"%s reflex PiP: checker period measurable (lens tex %.1f px, main %.1f px)"
			% [id, period_tex, period_main])
	if period_tex > 0.0 and period_main > 0.0:
		var mag := (period_tex / float(tex_img.get_height())) / (period_main / 720.0)
		_check(mag > 0.90 and mag < 1.10,
			"%s reflex PiP: in-lens magnification %.2f ~= 1.0x (no-zoom pin)" % [id, mag])
	# Registration on screen: the period inside the window matches
	# the surrounding view's — the picture is the world at 1:1.
	var disc: MeshInstance3D = weapon.call("get_lens_screen")
	_check(disc != null, "%s reflex PiP: lens screen bound in the rendered case" % id)
	if disc == null:
		Input.action_release("ads")
		return
	var rect := _project_rect(camera, disc)
	# Registration is read on the HORIZONTAL period: the window is
	# only ~2 checker cells tall, but ~2 cells wide too — pooled over
	# its rows the horizontal spacings are plentiful and clean.
	var win_period := _region_period_h(frame, rect)
	var main_period_h := _region_period_h(frame, Rect2(500, 298, 110, 34))
	_check(win_period > 0.0 and main_period_h > 0.0
		and win_period / main_period_h > 0.70 and win_period / main_period_h < 1.40,
		"%s reflex PiP: on-screen window period %.1f px ~ main view %.1f px (1:1 registration)"
			% [id, win_period, main_period_h])
	var transitions := _row_transitions(frame, int((rect.position.y + rect.end.y) * 0.5) - 6,
		int(rect.position.x) + 4, int(rect.end.x) - 4)
	_check(transitions >= 2,
		"%s reflex PiP: world visible inside the window (%d transitions across the aperture)"
			% [id, transitions])
	# The in-glass dot sits at the window's centre (= screen centre).
	var ret_a := _red_centroid_in(frame, rect)
	_check(ret_a.x >= 0.0 and (ret_a - CENTRE).length() <= 4.0,
		"%s reflex PiP: in-glass dot at centre (centroid %s)" % [id, ret_a])
	# Parallax: freeze the weapon so the test owns the shader param.
	weapon.set_process(false)
	var mat := disc.material_override as ShaderMaterial
	var row := int((rect.position.y + rect.end.y) * 0.5) - 8 # above the dot
	var ix0 := int(rect.position.x + rect.size.x * 0.2)
	var ix1 := int(rect.end.x - rect.size.x * 0.2)
	var profile_a := _row_profile(frame, row, ix0, ix1)
	# The reflex scope shadow is deliberately subtle and lives at the
	# aperture edge — measured on the rect's outer ring (the quad
	# rect is tight to the aperture, so the ring IS the edge band).
	var ring_a := _ring_lum(frame, rect)
	mat.set_shader_parameter("eye_offset", Vector2(0.005, 0.0))
	await _wait_frames(3)
	await RenderingServer.frame_post_draw
	var frame_b := root.get_texture().get_image()
	frame_b.save_png(PIP_REFLEX_OUT + "/pip_reflex_%s_offset.png" % id)
	frame_b.save_png(OUT_DIR + "/pip_reflex_%s_offset.png" % id)
	var shift := _profile_shift(profile_a, _row_profile(frame_b, row, ix0, ix1))
	_check(shift <= -2.0,
		"%s reflex PiP: parallax — in-window image swims against the eye offset (shift %.1f px)"
			% [id, shift])
	var ret_b := _red_centroid_in(frame_b, rect)
	_check(ret_a.x >= 0.0 and ret_b.x >= 0.0 and (ret_a - ret_b).length() <= 2.0,
		"%s reflex PiP: parallax — dot stays fixed in the glass (A %s, B %s)" % [id, ret_a, ret_b])
	# Scope shadow: a big offset must measurably darken the aperture
	# edge (subtle by design on the open reflex housing — but present).
	mat.set_shader_parameter("eye_offset", Vector2(0.12, 0.0))
	await _wait_frames(3)
	await RenderingServer.frame_post_draw
	var frame_c := root.get_texture().get_image()
	var ring_c := _ring_lum(frame_c, rect)
	_check(ring_c < ring_a * 0.95,
		"%s reflex PiP: scope shadow darkens the aperture edge when misaligned (ring lum %.3f -> %.3f)"
			% [id, ring_a, ring_c])
	mat.set_shader_parameter("eye_offset", Vector2.ZERO)
	weapon.set_process(true)
	# Hip: lens stands down — viewport not updating, shader back to glass.
	Input.action_release("ads")
	var released := await _wait_until(
		func() -> bool: return float(weapon.call("get_ads_blend")) < 0.05, 4000)
	_check(released, "%s reflex PiP case: ADS releases" % id)
	await _wait_frames(3)
	_check(not bool(weapon.call("is_lens_pip_active")),
		"%s reflex PiP: lens inactive at hip" % id)
	_check(lvp.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"%s reflex PiP: lens viewport NOT updating at hip" % id)
	_check(float(mat.get_shader_parameter("pip_strength")) < 0.05,
		"%s reflex PiP: shader back to the glass fallback at hip (strength %.2f)"
			% [id, float(mat.get_shader_parameter("pip_strength"))])
	await RenderingServer.frame_post_draw
	var hip := root.get_texture().get_image()
	hip.save_png(PIP_REFLEX_OUT + "/pip_reflex_%s_hip.png" % id)
	hip.save_png(OUT_DIR + "/pip_reflex_%s_hip.png" % id)


# BB-1d: pooled horizontal checker period over a screen region —
# the reflex window is small (~40x33 px, barely 2 cells tall), so a
# single line yields too few clean spacings. Pool the spacings of
# every row in the rect (skipping the in-glass dot's own rows around
# screen centre) and average.
func _region_period_h(img: Image, rect: Rect2) -> float:
	var spacings: Array = []
	var x0 := int(rect.position.x) + 2
	var x1 := int(rect.end.x) - 2
	for y in range(int(rect.position.y) + 2, int(rect.end.y) - 2, 2):
		if absf(y - CENTRE.y) < 5.0:
			continue # the in-glass dot lives here
		var edges: Array = []
		var prev := _lum(img.get_pixel(x0, y)) > 0.5
		for x in range(x0 + 1, x1):
			var cur := _lum(img.get_pixel(x, y)) > 0.5
			if cur != prev:
				edges.append(x)
				prev = cur
		for i in range(1, edges.size()):
			spacings.append(float(edges[i] - edges[i - 1]))
	if spacings.size() < 6:
		return -1.0
	var sum := 0.0
	for s in spacings:
		sum += s
	return sum / float(spacings.size())


# Mean spacing (px) of luminance transitions down a column — one
# spacing per checker cell.
func _stripe_period_v(img: Image, x: int, y0: int, y1: int) -> float:
	var transitions: Array = []
	var prev := _lum(img.get_pixel(x, y0)) > 0.5
	for y in range(y0 + 1, y1):
		var cur := _lum(img.get_pixel(x, y)) > 0.5
		if cur != prev:
			transitions.append(y)
			prev = cur
	if transitions.size() < 3:
		return -1.0
	var sum := 0.0
	for i in range(1, transitions.size()):
		sum += float(transitions[i] - transitions[i - 1])
	return sum / float(transitions.size() - 1)


# Projected screen rect of a mesh's AABB (same pattern as _aperture_stats).
func _project_rect(camera: Camera3D, mi: MeshInstance3D) -> Rect2:
	var aabb := mi.get_aabb()
	var gt := mi.global_transform
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for xi in [aabb.position.x, aabb.end.x]:
		for yi in [aabb.position.y, aabb.end.y]:
			for zi in [aabb.position.z, aabb.end.z]:
				var px := camera.unproject_position(gt * Vector3(xi, yi, zi))
				lo = lo.min(px)
				hi = hi.max(px)
	return Rect2(lo, hi - lo)


func _row_profile(img: Image, y: int, x0: int, x1: int) -> Array:
	var out: Array = []
	for x in range(x0, x1):
		out.append(_lum(img.get_pixel(x, y)))
	return out


func _row_transitions(img: Image, y: int, x0: int, x1: int) -> int:
	var n := 0
	var prev := _lum(img.get_pixel(x0, y)) > 0.5
	for x in range(x0 + 1, x1):
		var cur := _lum(img.get_pixel(x, y)) > 0.5
		if cur != prev:
			n += 1
			prev = cur
	return n


# Best integer lag of profile b vs a by mean absolute difference —
# negative means b's content moved LEFT (smaller x) relative to a.
func _profile_shift(a: Array, b: Array) -> float:
	var best_lag := 0
	var best_err := INF
	var n := mini(a.size(), b.size())
	for lag in range(-24, 25):
		var err := 0.0
		var cnt := 0
		for i in n:
			var j := i + lag
			if j < 0 or j >= n:
				continue
			err += absf(float(a[i]) - float(b[j]))
			cnt += 1
		if cnt > 0:
			err /= float(cnt)
			if err < best_err:
				best_err = err
				best_lag = lag
	return float(best_lag)


# Red centroid restricted to a rect (the in-glass reticle).
func _red_centroid_in(img: Image, rect: Rect2) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for y in range(int(rect.position.y), int(rect.end.y), 1):
		for x in range(int(rect.position.x), int(rect.end.x), 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var p := img.get_pixel(x, y)
			if p.r > 0.55 and p.r - p.g > 0.25 and p.r - p.b > 0.25:
				sum += Vector2(x, y)
				n += 1
	if n < 4:
		return Vector2(-1, -1)
	return sum / float(n)


# Mean luminance of the rect's outer ring (the aperture's edge band).
func _ring_lum(img: Image, rect: Rect2) -> float:
	var sum := 0.0
	var n := 0
	var inset := rect.size * 0.16
	for y in range(int(rect.position.y), int(rect.end.y), 2):
		for x in range(int(rect.position.x), int(rect.end.x), 2):
			var inside := x > rect.position.x + inset.x and x < rect.end.x - inset.x \
				and y > rect.position.y + inset.y and y < rect.end.y - inset.y
			if inside:
				continue
			sum += _lum(img.get_pixel(x, y))
			n += 1
	return sum / maxf(n, 1)


# Red-dot centroid: pixels that are strongly red (the AdsDot emission).
func _red_centroid(img: Image) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for y in range(240, 480, 2):
		for x in range(520, 760, 2):
			var p := img.get_pixel(x, y)
			if p.r > 0.55 and p.r - p.g > 0.25 and p.r - p.b > 0.25:
				sum += Vector2(x, y)
				n += 1
	if n < 4:
		return Vector2(-1, -1)
	return sum / float(n)


# Iron front-post tip: topmost sight-dark (or ember-orange) pixel in the
# narrow centre band — the rear posts sit outside this band by design.
func _iron_tip_y(img: Image) -> int:
	for y in range(200, 560):
		for x in range(632, 649):
			var p := img.get_pixel(x, y)
			var dark := p.r < 0.45 and p.g < 0.46 and p.b < 0.48
			var orange := p.r > 0.45 and p.g > 0.2 and p.g < 0.55 and p.b < 0.3 and p.r - p.b > 0.25
			if dark or orange:
				return y
	return -1


func _lum(p: Color) -> float:
	return 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b


func _weapon_is(manager: Node, id: String) -> bool:
	var cw: Variant = manager.call("current_weapon")
	return cw != null and str(cw.get("weapon_id")) == id


func _ads_settled(player: Node, weapon: Variant, camera: Camera3D, zoom: float) -> bool:
	# Blend + FOV converge BEFORE the raise animation finishes (blend
	# rate 10/s vs raise up to 0.55 s — at low frame rates blend can hit
	# 1.0 on frame one), and mid-raise the viewmodel is still lerping
	# from hip: a capture then measures the raise, not the ADS pose.
	# Require the raise to be done too — that IS "fully aimed".
	return bool(player.call("is_ads")) and float(weapon.call("get_ads_blend")) >= 0.999 \
		and float(weapon.get("_raise_t")) >= float(weapon.get("raise_time")) \
		and absf(camera.fov - 90.0 / zoom) < 1.5


func _wait_frames(n: int) -> void:
	for i in n:
		await process_frame


func _wait_until(cond: Callable, timeout_ms: int) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return cond.call()
