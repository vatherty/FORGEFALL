# FORGEFALL — scripts/player/grapple_hook.gd
# Purpose: wrist ascender grapple with NO cooldown. Two modes:
#   DIRECT PULL — anchor within ~35 deg of straight up + player slow:
#     48 m/s^2 toward the anchor with gravity x0.2 (yanks the operative
#     off the ground). Anything else is PENDULUM.
#   PENDULUM — Spider-Man rope constraint (distance <= rope length),
#     reel-in shortens the rope 6 m/s while the grapple action is held,
#     and wish input pumps the swing (tangential acceleration, capped).
# Release (action released, jump, or reaching the anchor) keeps momentum.
# Safety: NEVER pulls the player through the floor — clamp_floor() pins the
# player at floor_y + 0.5 after every move_and_slide.
# Connections: driven by player.gd — setup() once, then fire()/release()/
#   apply_grapple()/get_gravity_scale()/clamp_floor() each physics frame.
#   Rope + anchor spark visuals are pooled (reused, never re-created).
class_name GrappleHook
extends Node3D

#region TUNABLES
const FIRE_RANGE := 60.0
const MAX_ROPE := 40.0
const PULL_ACCEL := 75.0
const PULL_GRAVITY_SCALE := 0.2
const PULL_DIRECT_MAX_ANGLE_DEG := 35.0  # anchor within this of straight up
const PULL_DIRECT_MAX_SPEED := 5.0     # ...and player slower than this
const PULL_MAX_SPEED := 30.0
const PULL_RELEASE_DIST := 1.5
const REEL_SPEED := 10.0
const ROPE_MIN := 2.0
const SWING_PUMP_ACCEL := 12.0          # tangential accel from wish while swinging
const SWING_PUMP_MAX_TANGENTIAL := 20.0  # tangential speed cap for pumping
#endregion

enum Mode { IDLE, DIRECT, PENDULUM }

var _player: CharacterBody3D
var _camera: Camera3D
var _muzzle: Node3D
var _floor_ray: RayCast3D
var _active := false
var _mode: int = Mode.IDLE
var _anchor := Vector3.ZERO
var _rope_len := 0.0
var _rope: MeshInstance3D
var _spark: MeshInstance3D
var _pulse := 0.0


func setup(player: CharacterBody3D, camera: Camera3D, muzzle: Node3D,
		floor_ray: RayCast3D) -> void:
	_player = player
	_camera = camera
	_muzzle = muzzle
	_floor_ray = floor_ray


func _ready() -> void:
	# Pooled visuals: one rope, one spark, reused for the life of the run.
	_rope = VoxelBuilder.cube(Vector3(0.06, 0.06, 1.0),
		Color(VoxelBuilder.PALETTE["gunmetal"]))
	_rope.top_level = true
	_rope.visible = false
	add_child(_rope)
	_spark = VoxelBuilder.cube(Vector3(0.18, 0.18, 0.18),
		Color(VoxelBuilder.PALETTE["forge_orange"]))
	_spark.top_level = true
	_spark.visible = false
	add_child(_spark)


func is_active() -> bool:
	return _active


func get_gravity_scale() -> float:
	if _active and _mode == Mode.DIRECT:
		return PULL_GRAVITY_SCALE
	return 1.0


# Fires the ascender. Returns true if an anchor was hit.
# Pressing while attached toggles off (release, keep momentum).
func fire() -> bool:
	if _player == null or _camera == null:
		return false
	if _active:
		release()
		return false
	var space := _player.get_world_3d().direct_space_state
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(
		from, from + dir * FIRE_RANGE, 1, [_player.get_rid()])
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return false
	_anchor = hit["position"]
	_rope_len = minf(from.distance_to(_anchor), MAX_ROPE)
	var hspeed := Vector2(_player.velocity.x, _player.velocity.z).length()
	# DIRECT iff the anchor is near-vertical from the player (within
	# ~35 deg of straight up) AND the player is slow. A merely-high
	# side/ahead anchor (e.g. 1.6 m up but 2.5 m away = ~57 deg off
	# vertical) is PENDULUM, not DIRECT.
	var to_anchor := _anchor - _player.global_position
	var cos_up := 0.0
	if to_anchor.length() > 0.001:
		cos_up = to_anchor.normalized().dot(Vector3.UP)
	if cos_up > cos(deg_to_rad(PULL_DIRECT_MAX_ANGLE_DEG)) \
			and hspeed < PULL_DIRECT_MAX_SPEED:
		_mode = Mode.DIRECT
	else:
		_mode = Mode.PENDULUM
	_active = true
	_rope.visible = true
	_spark.visible = true
	Sfx.play_2d("grapple_fire")
	# The zip loop starts ONCE on its own dedicated player and stops on
	# release() — it must never be retriggered per-frame (v0.1.9 and earlier
	# re-played it every 0.3s, stacking forever-looping players).
	Sfx.start_loop_2d("grapple_zip")
	return true


func release() -> void:
	_active = false
	_mode = Mode.IDLE
	_rope.visible = false
	_spark.visible = false
	Sfx.stop_loop_2d("grapple_zip")


# Called by player.gd before move_and_slide. Returns the modified velocity.
# `wish` is the player's horizontal wish direction (may be ZERO); in
# PENDULUM mode it pumps the swing via tangential acceleration.
func apply_grapple(delta: float, vel: Vector3, wish := Vector3.ZERO) -> Vector3:
	if not _active:
		return vel
	if _mode == Mode.DIRECT:
		var chest := _player.global_position + Vector3(0.0, 1.2, 0.0)
		var to_a := _anchor - chest
		var dist := to_a.length()
		if dist < PULL_RELEASE_DIST:
			release()
			return vel
		vel += to_a.normalized() * PULL_ACCEL * delta
		var sp := vel.length()
		if sp > PULL_MAX_SPEED:
			vel = vel.normalized() * PULL_MAX_SPEED
	else:
		var to_p := (_player.global_position + Vector3(0.0, 1.0, 0.0)) - _anchor
		var dist := to_p.length()
		# Swing pumping (v0.6.0): project wish onto the plane
		# perpendicular to the rope and accelerate along it. Purely
		# tangential, so the rope constraint (distance <= rope_len)
		# below stays intact; tangential speed is capped.
		if dist > 0.001 and wish.length_squared() > 0.0001:
			var radial := to_p / dist
			var wish_tan := wish - radial * wish.dot(radial)
			if wish_tan.length_squared() > 0.0001:
				var radial_vel := vel.dot(radial)
				var tan_vel := vel - radial * radial_vel
				if tan_vel.length() < SWING_PUMP_MAX_TANGENTIAL:
					vel += wish_tan.normalized() * SWING_PUMP_ACCEL * delta
					radial_vel = vel.dot(radial)
					tan_vel = vel - radial * radial_vel
					var ts := tan_vel.length()
					if ts > SWING_PUMP_MAX_TANGENTIAL:
						vel = radial * radial_vel \
							+ tan_vel.normalized() * SWING_PUMP_MAX_TANGENTIAL
		if Input.is_action_pressed("grapple"):
			_rope_len = maxf(ROPE_MIN, _rope_len - REEL_SPEED * delta)
		if dist > _rope_len and dist > 0.001:
			var radial := to_p / dist
			var outward := vel.dot(radial)
			if outward > 0.0:
				vel -= radial * outward  # kill motion that would stretch the rope
			vel -= radial * ((dist - _rope_len) * 6.0) * delta  # gentle inward spring
	return vel


# Called by player.gd AFTER move_and_slide. The rope never drags the
# operative through the floor.
func clamp_floor() -> void:
	if not _active or _floor_ray == null:
		return
	if _floor_ray.is_colliding():
		var min_y := _floor_ray.get_collision_point().y + 0.5
		if _player.global_position.y < min_y:
			_player.global_position.y = min_y
			if _player.velocity.y < 0.0:
				_player.velocity.y = 0.0


func _process(delta: float) -> void:
	if not _active:
		return
	_pulse += delta
	var from: Vector3 = _muzzle.global_position if _muzzle != null \
		else _player.global_position
	var d := from.distance_to(_anchor)
	if d > 0.05:
		_rope.global_position = (from + _anchor) * 0.5
		var dir := (_anchor - from).normalized()
		var up := Vector3.UP
		if absf(dir.dot(Vector3.UP)) > 0.98:
			up = Vector3.FORWARD  # look_at needs a non-parallel up vector
		_rope.look_at(_anchor, up)  # rope cube's depth runs along Z
		_rope.scale = Vector3(0.06, 0.06, d)
	_spark.global_position = _anchor
	var s := 1.0 + 0.35 * sin(_pulse * 14.0)
	_spark.scale = Vector3(0.18 * s, 0.18 * s, 0.18 * s)
