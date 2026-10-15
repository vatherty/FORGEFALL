# verify_portals_gameplay.gd — headless checks for FORGEFALL Goal 5 (Worker C:
# portal gameplay polish). Run: godot --headless --path <project> --script
# res://tools/verify_portals_gameplay.gd
# Does NOT touch tools/verify_portals.gd (Worker D's file).
# Checks, driving the REAL PortalEmitter + PortalDiscs:
#   MOMENTUM: floor->wall, wall->floor, floor->floor, diagonal
#     floor->wall(+Z), tangential-velocity speed preservation — exit speed
#     == entry speed, exit velocity points OUT of the exit portal.
#   UPRIGHT: teleported CharacterBody3D keeps a yaw-only basis (up stays
#     world-up) and faces out of the exit portal; RigidBody3D keeps the
#     full flipped rotation.
#   STANDOFF: teleported body centre sits in FRONT of the exit plane
#     (capsule-aware: ceiling exits clear the head, floor exits ~0.5).
#   BACKSIDE GUARD: body behind the entry plane moving away does NOT
#     teleport; same body moving inward DOES.
#   PLACEMENT: StaticBody3D wall accepts a portal; CharacterBody3D
#     (enemy) rejects it; no surface -> no_target; surface at 45m ->
#     out_of_range; surface at 20m -> valid.
#   DEBOUNCE: a second successful fire in the same frame does not move
#     the disc; after the window it does.
#   PAIR + CLEAR: both discs live -> pair_active; clear_portals() -> both dark.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _wait_until := 0.0
var _emitter = null  # untyped on purpose: GDScript static checks reject emitter methods on Node
var _player: CharacterBody3D = null
var _camera: Camera3D = null
var _wall1: StaticBody3D = null
var _wall2: StaticBody3D = null
var _enemy: CharacterBody3D = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _close(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _close_v(a: Vector3, b: Vector3, eps: float) -> bool:
	return a.distance_to(b) <= eps


func _disc_pair(entry_pos: Vector3, entry_n: Vector3,
		exit_pos: Vector3, exit_n: Vector3) -> Array:
	# Position the emitter's two pooled discs as an entry/exit pair.
	var blue = _emitter.get("_blue")
	var orange = _emitter.get("_orange")
	for pair in [[blue, entry_pos, entry_n], [orange, exit_pos, exit_n]]:
		var d = pair[0]
		var pos: Vector3 = pair[1]
		var n: Vector3 = pair[2]
		var up := Vector3.UP
		if absf(n.dot(Vector3.UP)) > 0.98:
			up = Vector3.FORWARD
		d.global_transform = Transform3D(Basis.looking_at(n, up), pos)
		d.call("activate")
	return [blue, orange]


func _body(pos: Vector3, vel: Vector3, with_capsule: bool) -> CharacterBody3D:
	var b := CharacterBody3D.new()
	root.add_child(b)
	b.global_position = pos
	b.velocity = vel
	if with_capsule:
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.4
		cap.height = 1.7
		cs.shape = cap
		cs.position = Vector3(0.0, 0.85, 0.0)
		b.add_child(cs)
	return b


func _initialize() -> void:
	var arena := Node3D.new()
	arena.name = "VerifyArena"
	root.add_child(arena)
	var emitter_script = load("res://scripts/player/portal_emitter.gd")
	_emitter = emitter_script.new()
	_emitter.name = "PortalEmitter"
	arena.add_child(_emitter)
	_phase = 1
	print("VERIFY(portals gameplay): emitter built, waiting for _ready")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 3:
				return false
			_run_teleport_checks()
			_phase = 2
		2:
			_build_aim_arena()
			_phase = 3
		3:
			if _frames < 6:
				return false
			# Camera at (0,2,10) looking -Z: wall1 at 10m -> valid.
			_check(_emitter.get_aim_state()["aim"] == "valid",
				"aim valid on StaticBody3D wall in range")
			_emitter.fire_blue()
			var blue = _emitter.get("_blue")
			_check(_close_v(blue.global_position, Vector3(0, 2, 0.58), 0.05),
				"fire_blue places disc on wall1 (got %s)" % blue.global_position)
			# Immediate re-fire at wall2 must be debounced away.
			_camera.global_position = Vector3(10, 2, 10)
			_emitter.fire_blue()
			_check(_close_v(blue.global_position, Vector3(0, 2, 0.58), 0.05),
				"debounce: immediate second fire does not move the disc")
			_wait_until = Time.get_ticks_msec() + 250
			_phase = 4
		4:
			if Time.get_ticks_msec() < _wait_until:
				return false
			_emitter.fire_blue()
			var blue2 = _emitter.get("_blue")
			_check(_close_v(blue2.global_position, Vector3(10, 2, 0.58), 0.05),
				"after debounce window, fire moves disc to wall2 (got %s)"
				% blue2.global_position)
			# Enemy steps between camera and wall2 -> invalid surface.
			_enemy = CharacterBody3D.new()
			_enemy.global_position = Vector3(10, 2, 5)
			var ecs := CollisionShape3D.new()
			var ebox := BoxShape3D.new()
			ebox.size = Vector3(1.0, 2.0, 1.0)
			ecs.shape = ebox
			_enemy.add_child(ecs)
			root.add_child(_enemy)
			_phase = 5
		5:
			if _frames < 12:
				return false
			_check(_emitter.get_aim_state()["aim"] == "invalid",
				"aim invalid on CharacterBody3D enemy")
			var orange_pre = _emitter.get("_orange").global_position
			_emitter.fire_orange()
			var orange = _emitter.get("_orange")
			_check(orange.global_position == orange_pre,
				"fire at non-portalable surface does not move the disc")
			_enemy.queue_free()
			_enemy = null
			_camera.global_position = Vector3(0, 2, 45)
			_phase = 6
		6:
			if _frames < 16:
				return false
			_check(_emitter.get_aim_state()["aim"] == "out_of_range",
				"aim out_of_range at 45m (got %s)"
				% _emitter.get_aim_state()["aim"])
			_camera.global_position = Vector3(0, 2, 70)
			_phase = 7
		7:
			if _frames < 20:
				return false
			_check(_emitter.get_aim_state()["aim"] == "no_target",
				"aim no_target at 70m (beyond probe)")
			_camera.global_position = Vector3(0, 2, 20)
			_phase = 8
		8:
			# The phase-4 fire_blue set the debounce window; firing here
			# (milliseconds later) must be blocked — that IS the feature.
			# First prove the block, then wait it out.
			var orange_pre8 = _emitter.get("_orange").global_position
			_emitter.fire_orange()
			_check(_emitter.get("_orange").global_position == orange_pre8,
				"debounce: cross-color re-fire inside the window is blocked")
			_wait_until = Time.get_ticks_msec() + 250
			_phase = 9
		9:
			if Time.get_ticks_msec() < _wait_until:
				return false
			_emitter.clear_portals()
			_check(_emitter.get_aim_state()["pair_active"] == false,
				"pair_active false after clear")
			_emitter.fire_orange()
			var orange2 = _emitter.get("_orange")
			_check(orange2.is_active, "fire_orange places orange disc")
			_check(_close_v(orange2.global_position, Vector3(0, 2, 0.58), 0.05),
				"orange disc lands on wall1 (got %s)" % orange2.global_position)
			# Blue fire in the same frame would (correctly) be debounced.
			_wait_until = Time.get_ticks_msec() + 250
			_phase = 10
		10:
			if Time.get_ticks_msec() < _wait_until:
				return false
			_emitter.fire_blue()
			var blue4 = _emitter.get("_blue")
			_check(blue4.is_active, "fire_blue places blue disc")
			_check(_emitter.get_aim_state()["pair_active"] == true,
				"pair_active true with both discs live")
			_emitter.clear_portals()
			var blue3 = _emitter.get("_blue")
			var orange3 = _emitter.get("_orange")
			_check(not blue3.is_active and not orange3.is_active,
				"clear_portals deactivates both discs")
			_check(_emitter.get_aim_state()["pair_active"] == false,
				"pair_active false after second clear")
			print("VERIFY(portals gameplay): %d failures" % _fails)
			quit(1 if _fails > 0 else 0)
			return true
	return false


func _build_aim_arena() -> void:
	# Dummy player + camera for the emitter's aim raycasts.
	_player = CharacterBody3D.new()
	_player.name = "AimPlayer"
	root.add_child(_player)
	_camera = Camera3D.new()
	_camera.name = "AimCamera"
	root.add_child(_camera)
	_camera.global_position = Vector3(0, 2, 10)
	_emitter.setup(_player, _camera, null, null)
	# Wall1 at x=0 (front face z=0.5), wall2 at x=10.
	_wall1 = _make_wall(Vector3(0, 2, 0), Vector3(4, 4, 1))
	_wall2 = _make_wall(Vector3(10, 2, 0), Vector3(4, 4, 1))


func _make_wall(pos: Vector3, size: Vector3) -> StaticBody3D:
	var w := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	w.add_child(cs)
	root.add_child(w)
	w.global_position = pos
	return w


func _run_teleport_checks() -> void:
	var blue = null
	var orange = null

	# 1. Floor -> wall(+X): fall 20 down, fly 20 out of the wall.
	var pair = _disc_pair(Vector3(0, 0, 0), Vector3.UP,
		Vector3(5, 2, 0), Vector3(1, 0, 0))
	blue = pair[0]
	orange = pair[1]
	var b1 := _body(Vector3(0, 0.5, 0), Vector3(0, -20, 0), false)
	_emitter.try_teleport(blue, b1)
	_check(_close_v(b1.velocity, Vector3(20, 0, 0), 0.05),
		"floor->wall: exit velocity (20,0,0), got %s" % b1.velocity)
	_check(_close(b1.velocity.length(), 20.0, 0.05),
		"floor->wall: speed preserved 20 (got %.3f)" % b1.velocity.length())
	_check((b1.global_position - Vector3(5, 2, 0)).dot(Vector3(1, 0, 0)) > 1.0,
		"floor->wall: body in front of exit (offset %.2f)"
		% (b1.global_position - Vector3(5, 2, 0)).dot(Vector3(1, 0, 0)))
	_check(_close_v(b1.global_transform.basis * Vector3.UP, Vector3.UP, 0.01),
		"floor->wall: body stays upright")
	_check((b1.global_transform.basis * Vector3(0, 0, -1)).dot(Vector3(1, 0, 0)) > 0.9,
		"floor->wall: facing points out of exit portal")
	b1.queue_free()

	# 2. Wall(+X) -> floor: enter 12 into the wall, fly 12 up out of the floor.
	pair = _disc_pair(Vector3(5, 2, 0), Vector3(1, 0, 0),
		Vector3(0, 0, 10), Vector3.UP)
	blue = pair[0]
	orange = pair[1]
	var b2 := _body(Vector3(5.5, 2, 0), Vector3(-12, 0, 0), false)
	_emitter.try_teleport(blue, b2)
	_check(_close_v(b2.velocity, Vector3(0, 12, 0), 0.05),
		"wall->floor: exit velocity (0,12,0), got %s" % b2.velocity)
	_check((b2.global_position - Vector3(0, 0, 10)).dot(Vector3.UP) > 1.0,
		"wall->floor: body above exit floor portal")
	b2.queue_free()

	# 3. Floor -> floor: fall 8, fly 8 straight back up.
	pair = _disc_pair(Vector3(0, 0, 0), Vector3.UP,
		Vector3(0, 0, 10), Vector3.UP)
	blue = pair[0]
	orange = pair[1]
	var b3 := _body(Vector3(0, 0.5, 0), Vector3(0, -8, 0), false)
	_emitter.try_teleport(blue, b3)
	_check(_close_v(b3.velocity, Vector3(0, 8, 0), 0.05),
		"floor->floor: exit velocity (0,8,0), got %s" % b3.velocity)
	b3.queue_free()

	# 4. Diagonal: floor -> wall(+Z): fall 10, fly 10 out +Z.
	pair = _disc_pair(Vector3(0, 0, 0), Vector3.UP,
		Vector3(0, 2, -5), Vector3(0, 0, 1))
	blue = pair[0]
	orange = pair[1]
	var b4 := _body(Vector3(0, 0.5, 0), Vector3(0, -10, 0), false)
	_emitter.try_teleport(blue, b4)
	_check(_close_v(b4.velocity, Vector3(0, 0, 10), 0.05),
		"floor->wall(+Z): exit velocity (0,0,10), got %s" % b4.velocity)
	b4.queue_free()

	# 5. Tangential velocity: entry (3,-15,4) -> |v| preserved, exits outward.
	pair = _disc_pair(Vector3(0, 0, 0), Vector3.UP,
		Vector3(5, 2, 0), Vector3(1, 0, 0))
	blue = pair[0]
	orange = pair[1]
	var v_in := Vector3(3, -15, 4)
	var b5 := _body(Vector3(0.2, 0.5, 0.1), v_in, false)
	_emitter.try_teleport(blue, b5)
	_check(_close(b5.velocity.length(), v_in.length(), 0.05),
		"tangential: speed preserved %.2f -> %.2f" % [v_in.length(), b5.velocity.length()])
	_check(b5.velocity.dot(Vector3(1, 0, 0)) > 0.0,
		"tangential: exit velocity points out of exit portal (got %s)" % b5.velocity)
	b5.queue_free()

	# 6. Backside guard: behind the entry plane, moving AWAY -> no teleport.
	pair = _disc_pair(Vector3(0, 0, 0), Vector3.UP,
		Vector3(5, 2, 0), Vector3(1, 0, 0))
	blue = pair[0]
	orange = pair[1]
	var b6 := _body(Vector3(0, -0.5, 0), Vector3(0, 2, 0), false)
	var p6 := b6.global_position
	var v6 := b6.velocity
	_emitter.try_teleport(blue, b6)
	_check(b6.global_position == p6 and b6.velocity == v6,
		"backside guard: body behind plane moving away is NOT teleported")
	b6.queue_free()

	# 7. Same spot but moving INTO the portal -> teleports (tunnelled step).
	var b7 := _body(Vector3(0, -0.5, 0), Vector3(0, -5, 0), false)
	_emitter.try_teleport(blue, b7)
	_check(_close_v(b7.velocity, Vector3(5, 0, 0), 0.05),
		"tunnelled body moving inward still teleports (got %s)" % b7.velocity)
	b7.queue_free()

	# 8. RigidBody3D: full flipped rotation, velocity mapped, standoff clears.
	pair = _disc_pair(Vector3(0, 0, 0), Vector3.UP,
		Vector3(5, 2, 0), Vector3(1, 0, 0))
	blue = pair[0]
	orange = pair[1]
	var rb := RigidBody3D.new()
	root.add_child(rb)
	rb.global_position = Vector3(0, 0.5, 0)
	rb.linear_velocity = Vector3(0, -6, 0)
	rb.angular_velocity = Vector3(0, 0, 2)
	_emitter.try_teleport(blue, rb)
	_check(_close_v(rb.linear_velocity, Vector3(6, 0, 0), 0.05),
		"rigid: exit linear velocity (6,0,0), got %s" % rb.linear_velocity)
	_check(_close(rb.linear_velocity.length(), 6.0, 0.05),
		"rigid: speed preserved")
	_check(_close_v(rb.global_transform.basis * Vector3.UP, Vector3(-1, 0, 0), 0.05),
		"rigid: full flipped rotation (up -> -X), got %s"
		% (rb.global_transform.basis * Vector3.UP))
	_check((rb.global_position - Vector3(5, 2, 0)).dot(Vector3(1, 0, 0)) > 0.4,
		"rigid: body in front of exit")
	rb.queue_free()

	# 9. Capsule-aware standoff, ceiling exit: head must clear the ceiling.
	pair = _disc_pair(Vector3(0, 0, 0), Vector3.UP,
		Vector3(0, 5, 10), Vector3(0, -1, 0))
	blue = pair[0]
	orange = pair[1]
	var b9 := _body(Vector3(0, 0.5, 0), Vector3(0, -10, 0), true)
	_emitter.try_teleport(blue, b9)
	_check(_close_v(b9.velocity, Vector3(0, -10, 0), 0.05),
		"ceiling exit: velocity (0,-10,0) out of ceiling, got %s" % b9.velocity)
	_check((b9.global_position - Vector3(0, 5, 10)).dot(Vector3(0, -1, 0)) > 2.0,
		"ceiling exit: capsule standoff > 2.0 (got %.2f)"
		% (b9.global_position - Vector3(0, 5, 10)).dot(Vector3(0, -1, 0)))
	b9.queue_free()

	# 10. Capsule-aware standoff, floor exit: ~0.5, not the 1.35 fallback.
	pair = _disc_pair(Vector3(5, 2, 0), Vector3(1, 0, 0),
		Vector3(0, 0, 10), Vector3.UP)
	blue = pair[0]
	orange = pair[1]
	var b10 := _body(Vector3(5.5, 2, 0), Vector3(-12, 0, 0), true)
	_emitter.try_teleport(blue, b10)
	var off10 := (b10.global_position - Vector3(0, 0, 10)).dot(Vector3.UP)
	_check(off10 > 0.4 and off10 < 0.8,
		"floor exit capsule standoff ~0.5 (got %.2f)" % off10)
	b10.queue_free()
