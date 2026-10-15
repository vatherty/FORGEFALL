# FORGEFALL — RaptorGun (prototype physics gun)
# Portal Arena PUNT rules: the gun itself deals NO damage. Fire grabs the
# nearest RigidBody3D within GRAB_RANGE under the crosshair (scale-pulse
# highlight while held); it floats at a hold point via a critically-damped
# follow; fire again THROWS it at THROW_SPEED toward the crosshair. Damage
# happens ONLY on impact: body_entered is connected at throw time and the
# first impact calls take_damage() with speed-scaled damage, then
# disconnects. Reload drops the held object gently.
class_name RaptorGun
extends WeaponBase

#region TUNABLES
const GRAB_RANGE := 12.0
const HOLD_DIST := 2.4
const HOLD_FOLLOW_SPEED := 18.0
const THROW_SPEED := 30.0
const DAMAGE_PER_SPEED := 4.0   # damage = speed * this, clamped
const DAMAGE_MIN := 20.0
const DAMAGE_MAX := 120.0
const PULSE_SPEED := 10.0
const PULSE_AMOUNT := 0.06
#endregion

var _held: RigidBody3D = null
var _thrown: RigidBody3D = null
var _last_speed: float = 0.0
var _pulse_t: float = 0.0


func trigger_pressed() -> void:
	_dry_fired = false
	if _held != null:
		_throw()
	elif _thrown == null:
		_grab()


func trigger_held() -> void:
	pass # semi only; the claw fires on press


func try_reload() -> void:
	# Reload = drop whatever is held, gently.
	if _held != null:
		_release_hold(false)


func set_ads(active: bool) -> void:
	super.set_ads(active)


func on_unequip() -> void:
	if _held != null:
		_release_hold(false)
	super.on_unequip()


func _grab() -> void:
	if _camera == null or _lowering or _raise_t < raise_time:
		return
	var from: Vector3 = _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var exclude: Array[RID] = []
	if _player is CollisionObject3D:
		exclude.append((_player as CollisionObject3D).get_rid())
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * GRAB_RANGE, 0xFFFFFFFF, exclude)
	var hit := _camera.get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Object = hit.get("collider")
	if collider is RigidBody3D:
		var body := collider as RigidBody3D
		_held = body
		body.contact_monitor = true
		body.max_contacts_reported = 8
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		_pulse_t = 0.0
		_show_muzzle_flash()
		# Goal 2: distinct energy zap (shot_raptor), not the grapple whoosh.
		Sfx.play_2d("shot_raptor")
		emit_ammo()


func _throw() -> void:
	var body := _held
	_held = null
	body.scale = Vector3.ONE
	body.freeze = false
	var dir := -_camera.global_transform.basis.z
	body.linear_velocity = dir * THROW_SPEED
	body.angular_velocity = Vector3(randf_range(-2.0, 2.0), randf_range(-2.0, 2.0), 0.0)
	_thrown = body
	_last_speed = THROW_SPEED
	if not body.body_entered.is_connected(_on_thrown_impact):
		body.body_entered.connect(_on_thrown_impact)
	_show_muzzle_flash()
	# Goal 2: distinct energy zap (shot_raptor), not the grapple whoosh.
	Sfx.play_2d("shot_raptor")
	emit_ammo()


func _release_hold(gentle_throw: bool) -> void:
	var body := _held
	_held = null
	if body == null or not is_instance_valid(body):
		return
	body.scale = Vector3.ONE
	body.freeze = false
	if gentle_throw and _camera != null:
		body.linear_velocity = -_camera.global_transform.basis.z * 3.0
	else:
		body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	Sfx.play_2d("raptor_drop")


func _on_thrown_impact(impacted: Node) -> void:
	var body := _thrown
	_thrown = null
	if body != null and is_instance_valid(body):
		if body.body_entered.is_connected(_on_thrown_impact):
			body.body_entered.disconnect(_on_thrown_impact)
		# Don't punish the player for catching their own throw.
		if impacted != _player and impacted.has_method("take_damage"):
			var dmg := clampf(_last_speed * DAMAGE_PER_SPEED, DAMAGE_MIN, DAMAGE_MAX)
			var at: Vector3 = (impacted as Node3D).global_position if impacted is Node3D else body.global_position
			impacted.take_damage(dmg, at, false)
			_notify_hit(impacted, false)
			# Heavy hits shake things up.
			if dmg >= 80.0:
				ExplosionFX.detonate_light(at)


func _physics_process(delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	if _held != null:
		if not is_instance_valid(_held):
			_held = null
			return
		var target: Vector3 = _camera.global_position + (-_camera.global_transform.basis.z) * HOLD_DIST
		_held.global_position = _held.global_position.move_toward(target, HOLD_FOLLOW_SPEED * delta)
	if _thrown != null:
		if not is_instance_valid(_thrown):
			_thrown = null
			return
		_last_speed = _thrown.linear_velocity.length()


func _process(delta: float) -> void:
	super._process(delta)
	if _held != null and is_instance_valid(_held):
		_pulse_t += delta
		var s := 1.0 + sin(_pulse_t * PULSE_SPEED) * PULSE_AMOUNT
		_held.scale = Vector3(s, s, s)
