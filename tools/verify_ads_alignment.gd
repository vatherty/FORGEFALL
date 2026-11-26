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
# NOTE: game scripts are load()ed dynamically inside _process (repo
# pattern — compile-time references fail in --script mode because the
# Sfx autoload does not exist yet at compile time).
extends SceneTree

const OUT_DIR := "/tmp/ads_verify"
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
			if optic in ["reflex", "acog"]:
				_check(dot != null and (dot as MeshInstance3D).visible,
					"%s %s: AdsDot present + visible at full ADS" % [id, optic])
			else:
				_check(dot == null, "%s %s: no AdsDot for non-dot optic" % [id, optic])
		w.call("on_unequip")
		w.queue_free()
	stage.queue_free()


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

	# [weapon, slot to equip, feature kind]
	var cases := [
		["lmg", "primary", "anchor"],
		["p9", "secondary", "iron_tip"],
		["ar7", "primary", "dot"],
		["br3", "primary", "dot"],
		["lr8", "primary", "scope"],
	]
	for c in cases:
		await _render_case(player, manager, camera, hud, str(c[0]), str(c[1]), str(c[2]))
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
