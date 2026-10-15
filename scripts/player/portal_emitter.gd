# FORGEFALL — scripts/player/portal_emitter.gd
# Purpose: wrist-mounted portal emitter. portal_blue / portal_orange actions
#   fire a disc (30m hitscan) that sticks to PORTAL-ABLE surfaces aligned to
#   the surface normal. Only one disc per color exists (pooled, reused).
# Placement validity (Goal 5, Worker C): a surface accepts a portal iff
#   is_surface_portalable() — StaticBody3D world geometry by default;
#   group "portalable" / metadata portalable=true opts in, group
#   "no_portal" / metadata portalable=false opts out. Dynamic bodies
#   (enemies, crates, the player) never accept portals.
# Aim feedback: _evaluate_aim() raycasts every frame; a translucent ghost
#   disc shows the would-be placement point (green = placeable, red =
#   surface rejects portals, amber = surface beyond range, hidden = no
#   surface). get_aim_state() + aim_state_changed expose the same verdict
#   for the HUD crosshair — HUD wiring lives in hud.gd, NOT this file.
# Teleport (Goal 5 momentum conservation): fall in fast, fly out fast.
#   Velocity maps through R = B * FlipY(180) * A^-1, which sends "into A"
#   (-n_A) to "out of B" (+n_B) and preserves speed EXACTLY (R is a pure
#   rotation). The old code used B * A^-1 (no flip), which sent exit
#   velocity INTO the exit wall and tilted the player — a fling died on
#   the wall, and a tilted body zeroes wish / rolls the view (player.gd
#   drives wish + look from the body basis and never re-uprights it).
#   Position maps through the same R, then the normal component is
#   clamped to a standoff in front of B (computed from the body's real
#   collision shapes) so the body never spawns embedded in the exit wall.
#   CharacterBody3D (player/enemies) stay UPRIGHT: only their yaw
#   changes (mapped facing projected to horizontal, with fallbacks to
#   the exit disc's local up, then the exit normal). RigidBody3D keeps
#   the full R rotation (crates may tumble).
#   Backside guard: a body behind the entry plane that is NOT moving
#   into the portal never teleports (no through-the-wall triggers); a
#   fast body that tunnelled a step past the plane still teleports
#   because its velocity points inward.
# Cooldowns: 0.5s per-body anti-ping-pong on both discs (unchanged);
#   0.15s placement debounce on successful fires (no accidental
#   double-placement from a bounced tap). Failed placements never start
#   the debounce window and never move the existing disc.
# Connections: driven by player.gd (setup/fire_blue/fire_orange);
#   portal discs (scenes/player/portal_disc.tscn) call try_teleport() back.
class_name PortalEmitter
extends Node3D

#region TUNABLES
const FIRE_RANGE := 30.0
const TELEPORT_COOLDOWN := 0.5
const BEAM_TIME := 0.12
const FIRE_DEBOUNCE := 0.15  # seconds; only successful placements start it
const AIM_PROBE_RANGE := 60.0  # second raycast: distinguishes out-of-range
const STANDOFF_RIGID := 0.6  # fallback when a body has no collision shapes
const STANDOFF_CHARACTER := 1.35  # fallback: player capsule half-extent + margin
const BACKSIDE_TOLERANCE := 0.15  # metres behind the entry plane still "in front"
const ENTERING_SPEED := 0.5  # |vel . n| above this = moving into the portal
#endregion

const DISC_SCENE: PackedScene = preload("res://scenes/player/portal_disc.tscn")

signal aim_state_changed(state: Dictionary)

var _player: CharacterBody3D
var _camera: Camera3D
var _wrist_l: Node3D
var _wrist_r: Node3D
var _blue: PortalDisc
var _orange: PortalDisc
var _beam: MeshInstance3D
var _beam_t := 0.0
var _beam_from := Vector3.ZERO
var _beam_to := Vector3.ZERO
var _last_fire_time := -100.0
var _ghost_root: Node3D
var _ghost_mat: StandardMaterial3D
var _aim_feedback_enabled := true
var _aim_state := {
	"aim": "no_target",
	"portalable": false,
	"in_range": false,
	"distance": 0.0,
	"hit_point": Vector3.ZERO,
	"hit_normal": Vector3.UP,
	"pair_active": false,
	"blue_active": false,
	"orange_active": false,
	"cooldown_remaining": 0.0,
}
var _aim_coarse := ""
var _aim_prev_pair := false


func setup(player: CharacterBody3D, camera: Camera3D,
		wrist_l: Node3D, wrist_r: Node3D) -> void:
	_player = player
	_camera = camera
	_wrist_l = wrist_l
	_wrist_r = wrist_r


func _ready() -> void:
	# The only two discs that will ever exist: pooled for the whole run.
	_blue = DISC_SCENE.instantiate() as PortalDisc
	_orange = DISC_SCENE.instantiate() as PortalDisc
	for d in [_blue, _orange]:
		d.top_level = true
		d.visible = false
		add_child(d)
	_blue.configure(Color(VoxelBuilder.PALETTE["portal_blue"]), _orange, self)
	_orange.configure(Color(VoxelBuilder.PALETTE["portal_orange"]), _blue, self)
	# Pooled muzzle-flash beam (wrist -> disc), tinted portal blue.
	_beam = VoxelBuilder.cube(Vector3(0.08, 0.08, 1.0),
		Color(VoxelBuilder.PALETTE["portal_blue"]))
	_beam.top_level = true
	_beam.visible = false
	add_child(_beam)
	_build_ghost()


func _build_ghost() -> void:
	# Placement preview: a plain translucent disc (NOT the PortalDisc
	# visual — Worker A owns that). Parent carries the placement transform;
	# the child mesh is rotated so the cylinder face points along local Z.
	_ghost_root = Node3D.new()
	_ghost_root.name = "AimGhost"
	_ghost_root.top_level = true
	_ghost_root.visible = false
	var cyl := CylinderMesh.new()
	cyl.top_radius = PortalDisc.DISC_RADIUS
	cyl.bottom_radius = PortalDisc.DISC_RADIUS
	cyl.height = 0.05
	cyl.radial_segments = 24
	var mesh := MeshInstance3D.new()
	mesh.mesh = cyl
	mesh.rotation_degrees.x = 90.0
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.albedo_color = Color(0.2, 1.0, 0.4, 0.35)
	_ghost_mat.emission_enabled = true
	_ghost_mat.emission = Color(0.2, 1.0, 0.4)
	_ghost_mat.emission_energy_multiplier = 0.8
	mesh.material_override = _ghost_mat
	_ghost_root.add_child(mesh)
	add_child(_ghost_root)


func fire_blue() -> void:
	_fire(_blue, _wrist_l)


func fire_orange() -> void:
	_fire(_orange, _wrist_r)


func _fire(disc: PortalDisc, wrist: Node3D) -> void:
	if _player == null or _camera == null:
		return
	var hit := _raycast_from_camera(FIRE_RANGE)
	if hit.is_empty():
		Sfx.play_2d("portal_fail")
		return
	if not is_surface_portalable(hit):
		Sfx.play_2d("portal_fail")
		return
	# Debounce AFTER the validity checks so a failed attempt never eats a
	# later good one; only a successful placement starts the window.
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_fire_time < FIRE_DEBOUNCE:
		return
	_last_fire_time = now
	var n: Vector3 = hit["normal"]
	var p: Vector3 = hit["position"]
	var up := Vector3.UP
	if absf(n.dot(Vector3.UP)) > 0.98:
		up = Vector3.FORWARD
	# Disc faces along the surface normal (-Z toward the normal).
	disc.global_transform = Transform3D(Basis.looking_at(n, up), p + n * 0.08)
	disc.activate()
	_beam_from = wrist.global_position if wrist != null else _camera.global_position
	_beam_to = disc.global_position
	_beam_t = BEAM_TIME
	_beam.visible = true
	Sfx.play_2d("portal_fire")


#region PLACEMENT VALIDITY + AIM FEEDBACK
func _raycast_from_camera(dist: float) -> Dictionary:
	if _player == null or _camera == null:
		return {}
	var space := _player.get_world_3d().direct_space_state
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(
		from, from + dir * dist, 1, [_player.get_rid()])
	return space.intersect_ray(query)


# Portal-able rule (shared by _fire, the ghost and the crosshair state):
# world geometry yes, dynamic bodies no, explicit opt-in/out wins.
func is_surface_portalable(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false
	var collider: Variant = hit.get("collider")
	if not (collider is Node):
		return false
	var node := collider as Node
	if node.is_in_group("no_portal"):
		return false
	if node.is_in_group("portalable"):
		return true
	if node.has_meta("portalable"):
		return bool(node.get_meta("portalable"))
	return collider is StaticBody3D


func _evaluate_aim() -> Dictionary:
	var state := {
		"aim": "no_target",
		"portalable": false,
		"in_range": false,
		"distance": 0.0,
		"hit_point": Vector3.ZERO,
		"hit_normal": Vector3.UP,
		"pair_active": false,
		"blue_active": false,
		"orange_active": false,
		"cooldown_remaining": 0.0,
	}
	state["blue_active"] = _blue != null and _blue.is_active
	state["orange_active"] = _orange != null and _orange.is_active
	state["pair_active"] = bool(state["blue_active"]) and bool(state["orange_active"])
	var now := Time.get_ticks_msec() / 1000.0
	state["cooldown_remaining"] = maxf(0.0, FIRE_DEBOUNCE - (now - _last_fire_time))
	if _camera == null or _player == null:
		return state
	var hit := _raycast_from_camera(FIRE_RANGE)
	if not hit.is_empty():
		state["in_range"] = true
		state["distance"] = _camera.global_position.distance_to(hit["position"])
		state["hit_point"] = hit["position"]
		state["hit_normal"] = hit["normal"]
		state["portalable"] = is_surface_portalable(hit)
		state["aim"] = "valid" if state["portalable"] else "invalid"
		return state
	var probe := _raycast_from_camera(AIM_PROBE_RANGE)
	if not probe.is_empty():
		state["distance"] = _camera.global_position.distance_to(probe["position"])
		state["hit_point"] = probe["position"]
		state["hit_normal"] = probe["normal"]
		state["portalable"] = is_surface_portalable(probe)
		state["aim"] = "out_of_range"
		return state
	state["aim"] = "no_target"
	return state


# Crosshair contract for the HUD (hud.gd reads this / the signal):
#   aim: "valid" | "invalid" | "out_of_range" | "no_target"
#   pair_active / blue_active / orange_active: which discs are live
#   cooldown_remaining: seconds of placement debounce left
#   distance / hit_point / hit_normal / portalable / in_range
# Evaluated FRESH on every call (two raycasts at most), so a reader
# never sees a one-frame-stale verdict just because its _process ran
# before the emitter's.
func get_aim_state() -> Dictionary:
	var state := _evaluate_aim()
	if not _aim_feedback_enabled:
		_no_target_override(state)
	return state


func is_pair_active() -> bool:
	return _blue != null and _orange != null \
		and _blue.is_active and _orange.is_active


# Lets Forge / pause hide the ghost + crosshair verdict while open.
func set_aim_feedback_enabled(enabled: bool) -> void:
	_aim_feedback_enabled = enabled
	if not enabled and _ghost_root != null:
		_ghost_root.visible = false


# Puzzle reset: both discs go dark. Cooldowns are per-body and expire in
# TELEPORT_COOLDOWN on their own; nothing else is left stuck.
func clear_portals() -> void:
	for d in [_blue, _orange]:
		if d == null:
			continue
		d.is_active = false
		d.visible = false
		d.set_deferred("monitoring", false)


# Shared by get_aim_state() and _update_aim_feedback(): with feedback
# disabled (Forge / pause), the verdict is "no_target" while the pair
# flags stay truthful.
func _no_target_override(state: Dictionary) -> void:
	state["aim"] = "no_target"
	state["portalable"] = false
	state["in_range"] = false
	state["distance"] = 0.0
	state["hit_point"] = Vector3.ZERO
	state["hit_normal"] = Vector3.UP


func _update_aim_feedback() -> void:
	var state := _evaluate_aim()
	if not _aim_feedback_enabled:
		_no_target_override(state)
		if _ghost_root != null:
			_ghost_root.visible = false
	_aim_state = state
	var coarse: String = state["aim"]
	if coarse != _aim_coarse or bool(state["pair_active"]) != _aim_prev_pair:
		_aim_coarse = coarse
		_aim_prev_pair = bool(state["pair_active"])
		aim_state_changed.emit(state.duplicate())
	if _ghost_root == null or not _aim_feedback_enabled:
		return
	match coarse:
		"valid":
			_ghost_root.visible = true
			_set_ghost_color(Color(0.2, 1.0, 0.4))
		"invalid":
			_ghost_root.visible = true
			_set_ghost_color(Color(1.0, 0.25, 0.2))
		"out_of_range":
			_ghost_root.visible = true
			_set_ghost_color(Color(1.0, 0.7, 0.15))
		_:
			_ghost_root.visible = false
			return
	var n: Vector3 = state["hit_normal"]
	var p: Vector3 = state["hit_point"]
	var up := Vector3.UP
	if absf(n.dot(Vector3.UP)) > 0.98:
		up = Vector3.FORWARD
	_ghost_root.global_transform = Transform3D(Basis.looking_at(n, up), p + n * 0.08)


func _set_ghost_color(c: Color) -> void:
	if _ghost_mat == null:
		return
	_ghost_mat.albedo_color = Color(c.r, c.g, c.b, 0.35)
	_ghost_mat.emission = c
#endregion


#region TELEPORT (momentum conservation)
# Called back by a disc when a body enters it.
func try_teleport(from_disc: PortalDisc, body: Node3D) -> void:
	var to_disc: PortalDisc = _orange if from_disc == _blue else _blue
	if to_disc == null or not to_disc.is_active:
		return
	if from_disc.is_cooling(body) or to_disc.is_cooling(body):
		return
	var entry_n: Vector3 = from_disc.global_transform.basis * Vector3(0, 0, -1)
	var exit_n: Vector3 = to_disc.global_transform.basis * Vector3(0, 0, -1)
	var vel := Vector3.ZERO
	if body is CharacterBody3D:
		vel = (body as CharacterBody3D).velocity
	elif body is RigidBody3D:
		vel = (body as RigidBody3D).linear_velocity
	# Backside guard: a body behind the entry plane that is NOT moving
	# into the portal never teleports (no through-the-wall triggers).
	# A fast body that tunnelled a step past the plane still counts —
	# its velocity points inward.
	var offset_n := (body.global_position - from_disc.global_position).dot(entry_n)
	if offset_n < -BACKSIDE_TOLERANCE and vel.dot(entry_n) > -ENTERING_SPEED:
		return
	# Full Portal map R = B * FlipY(180) * A^-1: sends "into A" (-n_A)
	# to "out of B" (+n_B), preserves speed exactly (pure rotation).
	var flip := Basis(Vector3.UP, PI)
	var rot: Basis = to_disc.global_transform.basis * flip \
		* from_disc.global_transform.basis.inverse()
	var rel: Transform3D = from_disc.global_transform.affine_inverse() * body.global_transform
	var new_xform := to_disc.global_transform * Transform3D(flip, Vector3.ZERO) * rel
	# Basis: characters stay UPRIGHT (yaw only — see header); rigid
	# bodies keep the full flipped rotation (they may tumble).
	var new_basis := rot
	if body is CharacterBody3D:
		new_basis = Basis(Vector3.UP, _exit_yaw(from_disc, to_disc, body))
	# Position: the flipped offset lands BEHIND the exit plane (mirror);
	# clamp the normal component to a standoff in FRONT of the exit so
	# the body never spawns embedded in the exit wall.
	var standoff := _standoff_for(body, exit_n, new_basis)
	var off := new_xform.origin - to_disc.global_position
	var off_n := off.dot(exit_n)
	if off_n < standoff:
		new_xform.origin += exit_n * (standoff - off_n)
	new_xform.basis = new_basis
	body.global_transform = new_xform
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = rot * vel
	elif body is RigidBody3D:
		var rb := body as RigidBody3D
		rb.linear_velocity = rot * vel
		rb.angular_velocity = rot * rb.angular_velocity
	from_disc.set_cooldown(body, TELEPORT_COOLDOWN)
	to_disc.set_cooldown(body, TELEPORT_COOLDOWN)
	Sfx.play_2d("portal_travel")


# Yaw for a teleported CharacterBody3D: mapped facing projected to
# horizontal. Falls back to the exit disc's local up, then the exit
# normal, when the mapped facing is (near-)vertical — e.g. falling into
# a floor portal and out of a wall: the player faces OUT of the wall
# with a level view, Portal-style, instead of staring at the ceiling.
func _exit_yaw(from_disc: PortalDisc, to_disc: PortalDisc, body: Node3D) -> float:
	var facing: Vector3 = body.global_transform.basis * Vector3(0, 0, -1)
	var flip := Basis(Vector3.UP, PI)
	var rot: Basis = to_disc.global_transform.basis * flip \
		* from_disc.global_transform.basis.inverse()
	var mapped := rot * facing
	var flat := Vector3(mapped.x, 0.0, mapped.z)
	if flat.length() > 0.2:
		flat = flat.normalized()
		return atan2(-flat.x, -flat.z)
	var up2 := to_disc.global_transform.basis * Vector3.UP
	var flat2 := Vector3(up2.x, 0.0, up2.z)
	if flat2.length() > 0.2:
		flat2 = flat2.normalized()
		return atan2(-flat2.x, -flat2.z)
	var exit_n: Vector3 = to_disc.global_transform.basis * Vector3(0, 0, -1)
	var flat3 := Vector3(exit_n.x, 0.0, exit_n.z)
	if flat3.length() > 0.2:
		flat3 = flat3.normalized()
		return atan2(-flat3.x, -flat3.z)
	return 0.0


# How far in front of the exit plane (+exit_n) the body's centre must sit
# so no collision shape clips the exit wall: max shape extent toward the
# surface (direction -exit_n), plus a 0.1 margin. Falls back to a fixed
# standoff when the body has no shapes.
func _standoff_for(body: Node3D, exit_n: Vector3, new_basis: Basis) -> float:
	var d_world := -exit_n
	var d_local := new_basis.inverse() * d_world
	var best := 0.0
	var found := false
	var body_inv := body.global_transform.affine_inverse()
	for shape_node in body.find_children("*", "CollisionShape3D", true, false):
		var cs := shape_node as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		found = true
		var rel: Transform3D = body_inv * cs.global_transform
		var center_proj := rel.origin.dot(d_local)
		var ext := 0.0
		if cs.shape is CapsuleShape3D:
			var cap := cs.shape as CapsuleShape3D
			var axis := (rel.basis * Vector3.UP).normalized()
			ext = cap.radius + (cap.height * 0.5) * absf(axis.dot(d_local))
		elif cs.shape is BoxShape3D:
			var box := cs.shape as BoxShape3D
			var half := box.size * 0.5
			ext = absf((rel.basis.x * half.x).dot(d_local)) \
				+ absf((rel.basis.y * half.y).dot(d_local)) \
				+ absf((rel.basis.z * half.z).dot(d_local))
		elif cs.shape is SphereShape3D:
			ext = (cs.shape as SphereShape3D).radius
		else:
			ext = 0.5
		best = maxf(best, center_proj + ext)
	if not found:
		if body is RigidBody3D:
			return STANDOFF_RIGID
		return STANDOFF_CHARACTER
	return best + 0.1
#endregion


func _process(delta: float) -> void:
	# Aim feedback runs every frame (cheap: at most two raycasts).
	_update_aim_feedback()
	if _beam_t <= 0.0:
		return
	_beam_t -= delta
	var d := _beam_from.distance_to(_beam_to)
	if d > 0.05:
		_beam.global_position = (_beam_from + _beam_to) * 0.5
		var dir := (_beam_to - _beam_from).normalized()
		var up := Vector3.UP
		if absf(dir.dot(Vector3.UP)) > 0.98:
			up = Vector3.FORWARD
		_beam.look_at(_beam_to, up)
		_beam.scale = Vector3(1.0, 1.0, d)
	if _beam_t <= 0.0:
		_beam.visible = false
