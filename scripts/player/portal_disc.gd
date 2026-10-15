# FORGEFALL — scripts/player/portal_disc.gd
# Purpose: a single sticky portal gate. Visuals (emissive disc + voxel rim
#   ring + idle shimmer) are built in _ready; placement/activation is owned by
#   portal_emitter.gd, which also performs the actual teleport.
#   Goal 5 see-through (Worker A): each disc also owns a small SubViewport +
#   virtual camera that renders the view out of its partner portal onto a
#   flat RT surface in front of the shimmer core. Single-bounce only: the RT
#   is a plain texture, never a recursive viewport-in-viewport render, so a
#   portal seen through a portal shows at most last frame's texture.
#   Perf (the constraint): small square RTs (256/192/128 by PerfScaler tier),
#   per-tier frame throttling, facing/distance culling, and a shimmer
#   fallback whenever the RT can't render (partner missing/inactive, no main
#   camera, dummy renderer, or forced off) — the disc NEVER shows a black face.
# Connections: instantiated by portal_emitter.gd (only 2 exist, pooled);
#   scene: scenes/player/portal_disc.tscn (Area3D + sphere trigger).
class_name PortalDisc
extends Area3D

#region TUNABLES
const DISC_RADIUS := 0.55
const RIM_CUBES := 14
const SHIMMER_SPEED := 4.0
const SPIN_SPEED := 0.9
#endregion

#region SEE-THROUGH TUNABLES (Goal 5, Worker A)
# RT sizes by PerfScaler tier: small on purpose — render targets are the
# most expensive thing a phone GPU does, and the disc is a 1.1 m circle.
const RT_SIZE_HIGH := 256
const RT_SIZE_MED := 192
const RT_SIZE_LOW := 128
# How often each tier re-renders its RT (1 = every frame). MED/LOW trade a
# little staleness for a lot of GPU time.
const RT_EVERY_HIGH := 1
const RT_EVERY_MED := 2
const RT_EVERY_LOW := 3
# Beyond this the disc is too small on screen to justify an RT render.
const RT_MAX_VIEW_DIST := 30.0
# Facing cull: main camera must look at least this much toward the disc
# (dot of camera forward with direction-to-disc) or the RT stays frozen.
const RT_MIN_FACING_DOT := 0.05
# RT surface sits just in front of the shimmer core's front cap (core spans
# z in [-0.03, +0.03]; -Z is the outward face) and just inside the rim ring.
const RT_SURFACE_Z := -0.035
const RT_SURFACE_RADIUS := DISC_RADIUS * 0.95
# Test / quality overrides. force_rt_size >= 0 pins the RT size (tests,
# settings); force_seethrough_off disables RTs entirely (fallback path).
static var force_rt_size: int = -1
static var force_seethrough_off: bool = false
#endregion

var disc_color := Color(0.11, 0.66, 1.0)
var partner: PortalDisc
var emitter  # untyped on purpose: PortalEmitter owns discs, discs call back — avoids a script cycle
var is_active := false

var _cooldowns: Dictionary = {}
var _pulse := 0.0
var _visual_root: Node3D

# See-through state (all owned by this disc; nothing here is shared with
# Worker C's placement/teleport logic or Worker B's puzzle content).
var _rt_viewport: SubViewport
var _rt_camera: Camera3D
var _rt_surface: MeshInstance3D
var _seethrough_active := false
var _rt_frame := 0
var _cached_tier := -1
var _tier_cache_frame := 0
var _rendering_available := true


func configure(color: Color, partner_disc: PortalDisc, emitter_ref) -> void:
	disc_color = color
	partner = partner_disc
	emitter = emitter_ref


func _ready() -> void:
	# Dummy renderer (e.g. --headless) can never produce a real RT image:
	# treat see-through as unavailable from the start so the disc can only
	# ever show the shimmer, never a black face. Real devices (Vulkan /
	# Metal / OpenGL) report a non-empty adapter name.
	_rendering_available = not RenderingServer.get_video_adapter_name().is_empty()
	# Transform notifications let the virtual camera follow a partner move
	# at the earliest engine moment (next frame) instead of waiting for a
	# _process tick — placement via the emitter moves discs outside _process.
	set_notify_transform(true)
	_build_visuals()
	body_entered.connect(_on_body_entered)


func _notification(what: int) -> void:
	# Either disc of the pair moved: both virtual cameras depend on BOTH
	# disc transforms, so refresh both. Transform-only (no render request)
	# — safe to run synchronously from the notification.
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_refresh_rt_camera()
		if partner != null and is_instance_valid(partner):
			partner._refresh_rt_camera()


func _build_visuals() -> void:
	_visual_root = Node3D.new()
	_visual_root.name = "Visuals"
	add_child(_visual_root)
	# Emissive translucent core. Cylinder axis is Y; rotate so the face
	# points along local Z (the disc's facing, set by Basis.looking_at).
	var cyl := CylinderMesh.new()
	cyl.top_radius = DISC_RADIUS
	cyl.bottom_radius = DISC_RADIUS
	cyl.height = 0.06
	cyl.radial_segments = 24
	var core := MeshInstance3D.new()
	core.mesh = cyl
	core.rotation_degrees.x = 90.0
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(disc_color.r, disc_color.g, disc_color.b, 0.45)
	mat.emission_enabled = true
	mat.emission = disc_color
	mat.emission_energy_multiplier = 2.0
	core.material_override = mat
	_visual_root.add_child(core)
	# Voxel rim: chunky cubes around the rim for the FORGEFALL look.
	for i in RIM_CUBES:
		var a := TAU * float(i) / float(RIM_CUBES)
		var pos := Vector3(cos(a) * (DISC_RADIUS + 0.07), sin(a) * (DISC_RADIUS + 0.07), 0.0)
		_visual_root.add_child(VoxelBuilder.cube(
			Vector3(0.12, 0.12, 0.12), disc_color, pos))
	_build_seethrough()


func _build_seethrough() -> void:
	# SubViewport + virtual camera. own_world_3d = false shares the main
	# world (map, enemies, player) so the RT sees the real scene. The
	# camera is current for THIS viewport only — it never steals the main
	# camera — and audio listeners stay off so game audio is untouched.
	_rt_viewport = SubViewport.new()
	_rt_viewport.name = "PortalView"
	_rt_viewport.size = Vector2i(_resolve_rt_size(), _resolve_rt_size())
	_rt_viewport.own_world_3d = false
	_rt_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_rt_viewport.handle_input_locally = false
	_rt_viewport.audio_listener_enable_2d = false
	_rt_viewport.audio_listener_enable_3d = false
	add_child(_rt_viewport)
	_rt_camera = Camera3D.new()
	_rt_camera.name = "PortalCamera"
	_rt_camera.current = true
	_rt_viewport.add_child(_rt_camera)
	# Flat RT surface: a circle facing -Z (the outward face), in front of
	# the shimmer core. NOT under _visual_root — the shimmer spin/pulse
	# must never rotate or scale the live view. Cull disabled so the view
	# stays visible from either side, like the old disc.
	_rt_surface = MeshInstance3D.new()
	_rt_surface.name = "SeeThrough"
	_rt_surface.mesh = _make_circle_mesh(RT_SURFACE_RADIUS, 32)
	_rt_surface.rotation_degrees.y = 180.0
	_rt_surface.position = Vector3(0.0, 0.0, RT_SURFACE_Z)
	var rt_mat := StandardMaterial3D.new()
	rt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rt_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# ViewportTexture: the live view out of the partner portal.
	var rt_tex: ViewportTexture = _rt_viewport.get_texture()
	rt_mat.albedo_texture = rt_tex
	_rt_surface.material_override = rt_mat
	_rt_surface.visible = false
	add_child(_rt_surface)


## Build a flat circle mesh (triangle fan, +Z facing, UVs spanning [0,1])
## for the RT surface. Godot 4 has no CircleMesh primitive, so this is
## built with SurfaceTool — the same UV mapping a CircleMesh would give.
static func _make_circle_mesh(radius: float, segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center_uv := Vector2(0.5, 0.5)
	for i in segments:
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var v0 := Vector3(cos(a0) * radius, sin(a0) * radius, 0.0)
		var v1 := Vector3(cos(a1) * radius, sin(a1) * radius, 0.0)
		var uv0 := Vector2(0.5 + 0.5 * cos(a0), 0.5 + 0.5 * sin(a0))
		var uv1 := Vector2(0.5 + 0.5 * cos(a1), 0.5 + 0.5 * sin(a1))
		st.set_uv(center_uv)
		st.add_vertex(Vector3.ZERO)
		st.set_uv(uv0)
		st.add_vertex(v0)
		st.set_uv(uv1)
		st.add_vertex(v1)
	st.generate_normals()
	return st.commit()


func activate() -> void:
	is_active = true
	visible = true
	set_deferred("monitoring", true)


func is_cooling(body: Node) -> bool:
	var until: float = float(_cooldowns.get(body.get_instance_id(), 0.0))
	return until > Time.get_ticks_msec() / 1000.0


func set_cooldown(body: Node, dur: float) -> void:
	_cooldowns[body.get_instance_id()] = Time.get_ticks_msec() / 1000.0 + dur


func _on_body_entered(body: Node3D) -> void:
	if not is_active:
		return
	if not (body is CharacterBody3D or body is RigidBody3D):
		return
	if is_cooling(body):
		return
	if emitter != null and emitter.has_method("try_teleport"):
		emitter.try_teleport(self, body)


func _process(delta: float) -> void:
	if not is_active:
		return
	_pulse += delta
	# Prune stale cooldown entries so the dict never grows.
	if _cooldowns.size() > 24:
		var now := Time.get_ticks_msec() / 1000.0
		for k in _cooldowns.keys():
			if _cooldowns[k] < now:
				_cooldowns.erase(k)
	# Idle shimmer: gentle scale pulse + slow face spin.
	var s := 1.0 + 0.05 * sin(_pulse * SHIMMER_SPEED)
	_visual_root.scale = Vector3(s, s, 1.0)
	_visual_root.rotate_z(delta * SPIN_SPEED)
	_update_seethrough()


#region SEE-THROUGH (Goal 5, Worker A)

## Public probe for tests / settings: is the live view currently showing?
func is_seethrough_active() -> bool:
	return _seethrough_active


## Public probe: the RT edge length currently applied (0 if no RT yet).
func get_rt_size() -> int:
	if _rt_viewport == null:
		return 0
	return _rt_viewport.size.x


## Public probe: the virtual camera's world transform (identity if no RT).
func get_virtual_camera_transform() -> Transform3D:
	if _rt_camera == null:
		return Transform3D.IDENTITY
	return _rt_camera.global_transform


## Public fallback switch (probed by Worker D's verification): disabling
## forces the shimmer fallback on every disc; enabling restores the RT.
## Same effect as force_seethrough_off, as a per-disc-callable method.
func set_see_through_enabled(enabled: bool) -> void:
	force_seethrough_off = not enabled


## Force the quality tier cache to refresh (e.g. after a settings change).
func refresh_quality() -> void:
	_cached_tier = -1


func _resolve_tier() -> int:
	# PerfScaler lives under Main; re-resolve at most every 120 frames so
	# this stays cheap. No PerfScaler (unit tests, bare scenes) = HIGH.
	if _cached_tier >= 0 and _rt_frame - _tier_cache_frame < 120:
		return _cached_tier
	_cached_tier = PerfScaler.Tier.HIGH
	_tier_cache_frame = _rt_frame
	var tree := get_tree()
	if tree != null and tree.root != null:
		var found := tree.root.find_children("*", "PerfScaler", true, false)
		if not found.is_empty() and found[0] is PerfScaler:
			_cached_tier = int((found[0] as PerfScaler).tier)
	return _cached_tier


func _resolve_rt_size() -> int:
	if force_rt_size >= 0:
		return force_rt_size
	match _resolve_tier():
		PerfScaler.Tier.LOW:
			return RT_SIZE_LOW
		PerfScaler.Tier.MED:
			return RT_SIZE_MED
		_:
			return RT_SIZE_HIGH


func _resolve_rt_every() -> int:
	match _resolve_tier():
		PerfScaler.Tier.LOW:
			return RT_EVERY_LOW
		PerfScaler.Tier.MED:
			return RT_EVERY_MED
		_:
			return RT_EVERY_HIGH


func _set_seethrough_active(on: bool) -> void:
	_seethrough_active = on
	if _rt_surface != null:
		_rt_surface.visible = on
	if _rt_viewport != null and not on:
		_rt_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _update_seethrough() -> void:
	_rt_frame += 1
	if _rt_viewport == null or _rt_camera == null or _rt_surface == null:
		return
	# Camera tracking is UNGATED: the virtual camera must follow the pair
	# even when the RT itself can't render (headless, forced off), so any
	# reader of the virtual camera sees the current view. Only the surface
	# visibility + render requests below are gated.
	_refresh_rt_camera()
	# Hard gates: anything here means "show shimmer, never black".
	if not _rendering_available or force_seethrough_off:
		if _seethrough_active:
			_set_seethrough_active(false)
		return
	if partner == null or not is_instance_valid(partner) or not partner.is_active:
		if _seethrough_active:
			_set_seethrough_active(false)
		return
	var main_cam := _find_main_camera()
	if main_cam == null or not is_instance_valid(main_cam):
		if _seethrough_active:
			_set_seethrough_active(false)
		return
	# Perf culls: too far away or behind the main camera = freeze the RT.
	var to_disc := global_position - main_cam.global_position
	var dist := to_disc.length()
	if dist > RT_MAX_VIEW_DIST:
		if _seethrough_active:
			_set_seethrough_active(false)
		return
	var facing := (-main_cam.global_transform.basis.z).dot(to_disc / maxf(dist, 0.001))
	if facing < RT_MIN_FACING_DOT:
		if _seethrough_active:
			_set_seethrough_active(false)
		return
	# Resize only when the tier/override actually changed (reallocates).
	var want_size := _resolve_rt_size()
	if _rt_viewport.size.x != want_size:
		_rt_viewport.size = Vector2i(want_size, want_size)
	# Per-tier throttling: off-frames keep last frame's texture.
	if _rt_frame % _resolve_rt_every() != 0:
		if not _seethrough_active:
			_set_seethrough_active(true)
		return
	_rt_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_set_seethrough_active(true)


## Recompute the virtual camera from the live pair + main camera.
## Transform-only (no render request): safe to call from _process, from the
## transform-changed notification, and from tests. Portal 2 geometry, the
## same split Worker C uses for teleport (position vs direction):
## POSITION maps with the pure pair rotation (partner * self^-1 * cam) so
## the virtual camera sits the same distance IN FRONT of the partner portal
## as the main camera sits in front of this disc; ORIENTATION maps with the
## mirror flip — partner * FlipY(180) * self^-1 * cam — so a camera looking
## INTO this disc looks OUT OF the partner disc. The flip is a proper
## rotation (det +1), not a reflection: it flips X/Z and keeps Y, so the
## view turns around without mirroring and up stays upright. (An earlier
## cut applied the flip in camera-local space AFTER cam; that agrees with
## this formula for a level camera but NEGATES pitch — a camera looking
## down into the entry portal rendered a view looking UP out of the exit
## portal. The flip belongs between partner and self^-1, as here.)
func _refresh_rt_camera() -> void:
	if _rt_camera == null or not is_inside_tree():
		return
	if partner == null or not is_instance_valid(partner):
		return
	var main_cam := _find_main_camera()
	if main_cam == null or not is_instance_valid(main_cam):
		return
	# Pure pair rotation gives the virtual camera POSITION (in front of
	# the partner portal); the flipped orientation below gives its view.
	var virt_pos := (partner.global_transform * global_transform.affine_inverse() * main_cam.global_transform).origin
	var virt_basis: Basis = partner.global_transform.basis * Basis(Vector3.UP, PI) * global_transform.basis.inverse() * main_cam.global_transform.basis  # mirror flip: partner * FlipY * self^-1 * cam
	_rt_camera.global_transform = Transform3D(virt_basis, virt_pos)
	_rt_camera.fov = main_cam.fov
	_rt_camera.near = main_cam.near
	_rt_camera.far = main_cam.far
	_rt_camera.cull_mask = main_cam.cull_mask


## The view source for the RT: the viewport's current camera, falling back
## to any non-portal Camera3D in the tree when none is current (test rigs
## and menu states create cameras without making them current; in-game the
## player camera is always current so this never triggers there).
func _find_main_camera() -> Camera3D:
	var vp := get_viewport()
	if vp != null:
		var cur := vp.get_camera_3d()
		if cur != null and is_instance_valid(cur):
			return cur
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	return _find_scene_camera(tree.root)


func _find_scene_camera(node: Node) -> Camera3D:
	if node is Camera3D and not _is_portal_camera(node):
		return node as Camera3D
	for ch in node.get_children():
		var found := _find_scene_camera(ch)
		if found != null:
			return found
	return null


func _is_portal_camera(node: Node) -> bool:
	# RT cameras live inside a PortalDisc's SubViewport; never use one as
	# the view source (that would be a recursive view).
	var p := node.get_parent()
	while p != null:
		if p is PortalDisc or p is SubViewport:
			return true
		p = p.get_parent()
	return false

#endregion
