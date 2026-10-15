# verify_portals_seethrough.gd — Worker A verification for FORGEFALL Goal 5
# PORTALS see-through rendering (scripts/player/portal_disc.gd).
# Worker D owns tools/verify_portals.gd (integration suite); this file is
# Worker A's own checks for the RT implementation, kept separate so the two
# suites never clobber each other.
# Usage:
#   godot --headless --path <project> --script res://tools/verify_portals_seethrough.gd
#   (pixel check skipped under --headless: dummy renderer, no pixels)
#   xvfb-run -a godot --path <project> --script res://tools/verify_portals_seethrough.gd
#   (full run incl. RT pixel sampling under llvmpipe)
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# What is checked:
#   1. Each disc owns a SubViewport + virtual Camera3D + RT surface with
#      the viewport texture assigned; RT size follows the tier default (256).
#   2. With no real renderer (--headless) the disc falls back to the
#      shimmer (surface hidden) — NEVER a black face.
#   3. Virtual camera transform == partner * self^-1 * main camera, and it
#      updates when the partner moves.
#   4. Fallback (shimmer, no crash) when: partner inactive, main camera
#      facing away, no camera anywhere in the tree, single portal (no
#      partner), RT forced off via force_seethrough_off AND via
#      set_see_through_enabled(false).
#   5. A camera present in the tree but not current is still used as the
#      view source (fallback camera search — test rigs do this).
#   6. RT size follows force_rt_size and the PerfScaler tier (LOW -> 128).
#   7. Under a real renderer (xvfb): the RT image is mostly bright when a
#      bright wall fills the partner's view (not black, not stale-black).
extends SceneTree

var _passes := 0
var _fails := 0
var _frames := 0
var _has_rendering := false
var _disc_a: PortalDisc
var _disc_b: PortalDisc
var _cam: Camera3D
var _wall: MeshInstance3D
var _single: PortalDisc
var _scaler: PerfScaler
var _virt_before := Transform3D.IDENTITY


func _check(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", msg)
	else:
		_fails += 1
		printerr("FAIL: ", msg)


func _initialize() -> void:
	PortalDisc.force_seethrough_off = false
	PortalDisc.force_rt_size = -1
	_has_rendering = not RenderingServer.get_video_adapter_name().is_empty()
	print("VERIFY(portals-seethrough): rendering available: ", _has_rendering,
		" adapter='", RenderingServer.get_video_adapter_name(), "'")
	var disc_script := load("res://scripts/player/portal_disc.gd") as GDScript
	_disc_a = disc_script.new() as PortalDisc
	_disc_b = disc_script.new() as PortalDisc
	_disc_a.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	_disc_b.global_transform = Transform3D(Basis.IDENTITY, Vector3(10, 1.5, 0))
	root.add_child(_disc_a)
	root.add_child(_disc_b)
	_disc_a.configure(Color(0.11, 0.66, 1.0), _disc_b, null)
	_disc_b.configure(Color(1.0, 0.54, 0.11), _disc_a, null)
	_disc_a.activate()
	_disc_b.activate()
	_cam = Camera3D.new()
	root.add_child(_cam)
	_cam.look_at_from_position(Vector3(0, 1.5, -5), Vector3(0, 1.5, 0), Vector3.UP)
	_cam.make_current()
	# Bright wall beyond partner B on its OUTWARD side (-Z): the flipped
	# virtual camera looks out of B, so the wall must be where it looks.
	# It fills the virtual camera's view, so the RT must come back mostly
	# bright (not black) when rendering is real.
	_wall = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(24, 12, 1)
	_wall.mesh = box
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color.WHITE
	wm.emission_enabled = true
	wm.emission = Color.WHITE
	wm.emission_energy_multiplier = 4.0
	_wall.material_override = wm
	_wall.position = Vector3(10, 1.5, -15)
	root.add_child(_wall)


func _expected_virt(disc: PortalDisc) -> Transform3D:
	# Position: pure pair rotation. Orientation: mirror flip (FlipY 180)
	# between partner and self^-1 — partner * FlipY * self^-1 * cam,
	# the same split Worker C uses for teleport (position pure, direction
	# flipped). NOT the camera-local flip (cam * Flip), which negates pitch.
	var pure := disc.partner.global_transform \
		* disc.global_transform.affine_inverse() * _cam.global_transform
	var orient := disc.partner.global_transform.basis * Basis(Vector3.UP, PI) \
		* disc.global_transform.basis.inverse() * _cam.global_transform.basis
	return Transform3D(orient, pure.origin)


func _virt_close(a: Transform3D, b: Transform3D) -> bool:
	if (a.origin - b.origin).length() > 0.01:
		return false
	for i in 3:
		if a.basis[i].dot(b.basis[i]) < 0.999:
			return false
	return true


func _approx_vec(a: Vector3, b: Vector3) -> bool:
	return (a - b).length() <= 0.15


func _process(_delta: float) -> bool:
	_frames += 1
	match _frames:
		3:
			# Default headless behaviour: no real renderer -> shimmer
			# fallback, never a black face. Under xvfb this is already live.
			if not _has_rendering:
				_check(not _disc_a.is_seethrough_active(),
					"headless: disc A falls back to shimmer (RT inactive)")
				_check(_disc_a.get("_rt_surface") != null
					and not (_disc_a.get("_rt_surface") as MeshInstance3D).visible,
					"headless: RT surface hidden in fallback")
				_disc_a.set("_rendering_available", true)
				_disc_b.set("_rendering_available", true)
			_check(_disc_a.get("_rt_viewport") != null
				and _disc_a.get("_rt_camera") != null
				and _disc_a.get("_rt_surface") != null,
				"disc A owns SubViewport + virtual camera + RT surface")
			_check(_disc_b.get("_rt_viewport") != null
				and _disc_b.get("_rt_camera") != null
				and _disc_b.get("_rt_surface") != null,
				"disc B owns SubViewport + virtual camera + RT surface")
		8:
			_check(_disc_a.is_seethrough_active(),
				"disc A see-through active with partner + main camera")
			_check(_disc_a.get_rt_size() == 256,
				"RT size 256 on HIGH tier (got %d)" % _disc_a.get_rt_size())
			var rt_mat := (_disc_a.get("_rt_surface") as MeshInstance3D).material_override as StandardMaterial3D
			_check(rt_mat != null and rt_mat.albedo_texture == (_disc_a.get("_rt_viewport") as SubViewport).get_texture(),
				"RT surface material uses the SubViewport texture")
			_check(_virt_close(_disc_a.get_virtual_camera_transform(), _expected_virt(_disc_a)),
				"virtual camera == partner * self^-1 * main camera * mirror flip")
			var vt0 := _disc_a.get_virtual_camera_transform()
			_check(_approx_vec(-vt0.basis.z, Vector3(0, 0, -1)),
				"virtual camera looks OUT of the partner portal (forward %s, want (0,0,-1))" % str(-vt0.basis.z))
			_check(_approx_vec(vt0.basis.y, Vector3(0, 1, 0)),
				"virtual camera stays upright (up %s, want (0,1,0))" % str(vt0.basis.y))
			# RT-surface mesh UVs must span [0,1] or the view maps wrong.
			var surf_mesh := (_disc_a.get("_rt_surface") as MeshInstance3D).mesh as ArrayMesh
			var arrays := surf_mesh.surface_get_arrays(0) if surf_mesh != null else []
			if arrays.size() > 4 and arrays[4] is PackedVector2Array:
				var uvs := arrays[4] as PackedVector2Array
				var mn := Vector2.INF
				var mx := Vector2(-INF, -INF)
				for uv in uvs:
					mn = mn.min(uv)
					mx = mx.max(uv)
				_check(mn.x > -0.01 and mn.y > -0.01 and mx.x < 1.01 and mx.y < 1.01,
					"RT surface UVs span [0,1] (min %s max %s)" % [mn, mx])
			else:
				_check(false, "RT surface mesh exposes UV arrays")
			_virt_before = _disc_a.get_virtual_camera_transform()
			_disc_b.global_transform = Transform3D(Basis.IDENTITY, Vector3(12, 2.5, 1))
		14:
			_check(not _virt_close(_disc_a.get_virtual_camera_transform(), _virt_before),
				"virtual camera updates when the partner moves")
			_check(_virt_close(_disc_a.get_virtual_camera_transform(), _expected_virt(_disc_a)),
				"virtual camera matches partner * self^-1 * main camera * flip after partner move")
			_disc_b.global_transform = Transform3D(Basis.IDENTITY, Vector3(10, 1.5, 0))
			_disc_b.is_active = false
		20:
			_check(not _disc_a.is_seethrough_active(),
				"fallback: RT off when partner inactive (shimmer, no crash)")
			_disc_b.is_active = true
			_cam.look_at_from_position(Vector3(0, 1.5, 5), Vector3(0, 1.5, 20), Vector3.UP)
		24:
			_check(not _disc_a.is_seethrough_active(),
				"fallback: RT off when main camera faces away from the disc")
			_cam.look_at_from_position(Vector3(0, 1.5, -5), Vector3(0, 1.5, 0), Vector3.UP)
		28:
			_check(_disc_a.is_seethrough_active(),
				"see-through resumes when the camera faces the disc again")
			PortalDisc.force_seethrough_off = true
		32:
			_check(not _disc_a.is_seethrough_active(),
				"fallback: RT off when force_seethrough_off (shimmer, no crash)")
			PortalDisc.force_seethrough_off = false
			_disc_a.set_see_through_enabled(false)
		36:
			_check(not _disc_a.is_seethrough_active(),
				"fallback: RT off via set_see_through_enabled(false)")
			_disc_a.set_see_through_enabled(true)
			PortalDisc.force_rt_size = 128
		40:
			_check(_disc_a.is_seethrough_active(),
				"see-through resumes after set_see_through_enabled(true)")
			_check(_disc_a.get_rt_size() == 128,
				"force_rt_size=128 resizes the RT (got %d)" % _disc_a.get_rt_size())
			PortalDisc.force_rt_size = -1
		44:
			_check(_disc_a.get_rt_size() == 256,
				"clearing force_rt_size restores 256 (got %d)" % _disc_a.get_rt_size())
			# PerfScaler's _ready defers auto_detect() to the next idle
			# frame, so the tier is only set AFTER that has run.
			_scaler = PerfScaler.new()
			root.add_child(_scaler)
		48:
			_scaler.set_tier(PerfScaler.Tier.LOW)
			_disc_a.refresh_quality()
			_disc_b.refresh_quality()
		54:
			_check(_disc_a.get_rt_size() == 128,
				"LOW tier -> 128 RT (got %d)" % _disc_a.get_rt_size())
			_scaler.set_tier(PerfScaler.Tier.HIGH)
			_disc_a.refresh_quality()
			_disc_b.refresh_quality()
		60:
			_check(_disc_a.get_rt_size() == 256,
				"HIGH tier -> 256 RT (got %d)" % _disc_a.get_rt_size())
			var disc_script := load("res://scripts/player/portal_disc.gd") as GDScript
			_single = disc_script.new() as PortalDisc
			_single.global_transform = Transform3D(Basis.IDENTITY, Vector3(-5, 1.5, 0))
			root.add_child(_single)
			_single.configure(Color(0.11, 0.66, 1.0), null, null)
			_single.activate()
		64:
			_check(_single.get("_rt_viewport") != null,
				"single portal (no partner) still builds its RT objects, no crash")
			_check(not _single.is_seethrough_active(),
				"single portal shows shimmer, not RT / not black")
			_cam.clear_current()
		68:
			_check(_disc_a.is_seethrough_active(),
				"camera present but not current is still used as the view source")
			root.remove_child(_cam)
		72:
			_check(not _disc_a.is_seethrough_active(),
				"fallback: RT off with no camera anywhere in the tree (no crash)")
			root.add_child(_cam)
			_cam.make_current()
		76:
			_check(_disc_a.is_seethrough_active(),
				"see-through resumes when a main camera exists again")
			# Pitched camera: looking DOWN into the entry disc. The flip
			# belongs between partner and self^-1 (partner * FlipY *
			# self^-1 * cam): the virtual camera must look DOWN out of
			# the partner disc. The camera-local flip (cam * Flip) would
			# negate pitch and look UP instead — this phase catches that.
			_cam.look_at_from_position(Vector3(0, 3.5, -5), Vector3(0, 1.5, 0), Vector3.UP)
		80:
			var vt_p := _disc_a.get_virtual_camera_transform()
			_check(_virt_close(vt_p, _expected_virt(_disc_a)),
				"pitched camera: virtual camera == pure position + flipped orientation")
			_check(absf((-vt_p.basis.z - Vector3(0, -0.3714, -0.9285)).length()) <= 0.15,
				"pitched camera: virtual camera looks DOWN out of partner (forward %s, want ~(0,-0.37,-0.93)) — pitch preserved, not negated" % str(-vt_p.basis.z))
			_check(absf((vt_p.origin - Vector3(10, 3.5, -5)).length()) <= 0.05,
				"pitched camera: virtual camera position still pure (got %s, want (10,3.5,-5))" % str(vt_p.origin))
			_cam.look_at_from_position(Vector3(0, 1.5, -5), Vector3(0, 1.5, 0), Vector3.UP)
		84:
			if _has_rendering:
				var tex := (_disc_a.get("_rt_viewport") as SubViewport).get_texture()
				var img := tex.get_image() if tex != null else null
				_check(img != null, "RT texture yields an image under a real renderer")
				if img != null:
					img.convert(Image.FORMAT_RGB8)
					var bright := 0
					var total := img.get_width() * img.get_height()
					for y in range(img.get_height()):
						for x in range(img.get_width()):
							var p := img.get_pixel(x, y)
							if (p.r + p.g + p.b) / 3.0 > 0.5:
								bright += 1
					_check(total > 0 and float(bright) / float(total) > 0.5,
						"RT image mostly bright (bright %d/%d) — live view, not black" % [bright, total])
			else:
				print("SKIP: RT pixel check (no real renderer under --headless)")
			PortalDisc.force_seethrough_off = false
			PortalDisc.force_rt_size = -1
			print("VERIFY(portals-seethrough): %d passed, %d failed" % [_passes, _fails])
			if _fails == 0:
				print("VERIFY(portals-seethrough): ALL CHECKS PASSED")
			else:
				printerr("VERIFY(portals-seethrough): %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false
