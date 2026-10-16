# FORGEFALL — scripts/enemies/bulwark.gd
# Goal 3 CONTENT (Worker B — Enemies).
#
# BULWARK — shielded breacher. Advances slowly behind a big voxel riot
# shield and holds 10m, firing 3-round bursts. Frontal BODY shots deal
# only 25% damage (the shield eats them); HEADSHOTS bypass the shield
# (the head is above the plate) and FLANK/REAR shots deal full damage.
# Role: teaches positioning — headshot it, flank it, or ignore it and
# kill its friends first; frontal mag-dumps are a trap. Counterplay is
# always available: it is slow (3.6), it never takes cover, and its
# shield does nothing from behind.

class_name Bulwark
extends EnemyBase

enum State { SPAWN, ADVANCE, COMBAT }

const BURST_COUNT := 3
const FIRE_COOLDOWN_MIN := 1.6
const FIRE_COOLDOWN_MAX := 2.4
const AIM_TELEGRAPH := 0.4
const HOLD_RANGE := 10.0
const FRONTAL_DOT := 0.35   # hit from within this frontal cone = shielded
const FRONTAL_MULT := 0.25  # frontal body shots deal 25% damage
const STRAFE_TIME_MIN := 1.2
const STRAFE_TIME_MAX := 2.4
const LOST_SIGHT_TIMEOUT := 3.0

var state: int = State.SPAWN
var _t := 0.0
var _strafe_dir := 1.0
var _strafe_t := 0.0
var _fire_t := 0.0
var _aim_t := 0.0
var _lost_t := 0.0


func _configure() -> void:
	type_id = "bulwark"
	display_name = "Bulwark"
	creature_type = "humanoid"
	ability_scores = DnDTypes.ability_scores(16, 10, 17, 10, 11, 10)
	base_hp = 260.0      # tanky from the front (~1040 effective), soft from behind
	base_speed = 3.6     # slow advance — flankable, kiteable
	base_damage = 9.0
	base_accuracy = 0.5
	preferred_range = HOLD_RANGE
	body_radius = 0.40
	body_height = 1.8
	body_scale = Vector3(1.15, 1.05, 1.1)  # wide silhouette: the shield wall


func _debris_colors() -> Array:
	return [Color(0.5, 0.65, 0.8), Color(0.14, 0.15, 0.16), Color(0.4, 1.0, 0.3)]


func take_damage(amount: float, hit_position: Vector3, is_headshot: bool, attacker: Node = null) -> void:
	# Shield rule: frontal BODY shots are reduced. Headshots bypass
	# (head is above the plate) and flank/rear shots bypass (no shield there).
	if not is_headshot:
		var to_hit: Vector3 = hit_position - global_position
		to_hit.y = 0.0
		if to_hit.length_squared() > 0.01:
			var fwd := -global_transform.basis.z
			if fwd.dot(to_hit.normalized()) > FRONTAL_DOT:
				amount *= FRONTAL_MULT
	# v0.5.9: forward the attacker so thorns / take_damage hooks on
	# the base path see who dealt the hit.
	super.take_damage(amount, hit_position, is_headshot, attacker)


func _on_activated() -> void:
	state = State.SPAWN
	_t = 0.0
	_fire_t = randf_range(0.8, 1.6)
	_strafe_t = 0.0
	_aim_t = 0.0
	_lost_t = 0.0
	aiming = false


func _ai_physics(delta: float) -> void:
	if is_flinching():
		wish_dir = Vector3.ZERO
		aiming = false
		return
	var pp := player_pos()
	var dist := global_position.distance_to(pp)
	var see := can_see_player()
	if see:
		_lost_t = 0.0
	else:
		_lost_t += delta

	match state:
		State.SPAWN:
			_t += delta
			wish_dir = Vector3.ZERO
			if see:
				face_target = pp
			if _t > 0.6:  # telegraph (0.5s) + short settle
				_set_state(State.ADVANCE)

		State.ADVANCE:
			aiming = false
			face_target = pp
			wish_dir = nav_direction_to(pp, delta)
			wish_speed = speed
			if see and dist <= HOLD_RANGE:
				_set_state(State.COMBAT)
			elif not see and _lost_t > LOST_SIGHT_TIMEOUT:
				wish_dir = nav_direction_to(last_seen_pos, delta)

		State.COMBAT:
			face_target = pp
			_update_strafe(delta, pp, dist)
			_update_fire(delta, pp, dist, see)
			if _lost_t > LOST_SIGHT_TIMEOUT:
				_set_state(State.ADVANCE)


func _set_state(s: int) -> void:
	state = s
	_t = 0.0
	_aim_t = 0.0
	aiming = false
	wish_speed = 0.0


func _update_strafe(delta: float, pp: Vector3, dist: float) -> void:
	# Slow lateral shuffle — the wall moves, but never quickly.
	_strafe_t -= delta
	if _strafe_t <= 0.0:
		_strafe_t = randf_range(STRAFE_TIME_MIN, STRAFE_TIME_MAX)
		_strafe_dir = -_strafe_dir if randf() < 0.7 else _strafe_dir
	var to_p: Vector3 = pp - global_position
	to_p.y = 0.0
	var perp := Vector3(-to_p.z, 0, to_p.x).normalized() * _strafe_dir
	var radial := Vector3.ZERO
	if dist > HOLD_RANGE + 3.0:
		radial = to_p.normalized() * 0.7
	elif dist < HOLD_RANGE - 4.0:
		radial = -to_p.normalized() * 0.7
	wish_dir = perp * 0.5 + radial
	if wish_dir.length_squared() > 1.0:
		wish_dir = wish_dir.normalized()
	wish_speed = speed * 0.5


func _update_fire(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	gun_update(delta, damage, combat_spread(dist), "shot_ar", Color(0.4, 1.0, 0.3))
	if gun_burst_left > 0:
		aiming = true
		return
	if _aim_t > 0.0:
		aiming = true
		face_target = pp
		_aim_t -= delta
		if _aim_t <= 0.0:
			gun_trigger(BURST_COUNT)
		return
	aiming = false
	_fire_t -= delta
	if _fire_t <= 0.0 and see and dist < SIGHT_RANGE:
		_fire_t = randf_range(FIRE_COOLDOWN_MIN, FIRE_COOLDOWN_MAX)
		_aim_t = AIM_TELEGRAPH
