# FORGEFALL — scripts/enemies/marksman.gd
# Worker 4 (enemy AI + waves).
#
# MARKSMAN — long-range harasser. Holds a 24–34m band from the player,
# CROUCHES into a long aim (1.0s telegraph: crouch pose + lamp + scope
# glint read) then fires one accurate, high-damage shot. Retreats when
# the player closes in, advances when the player runs, and periodically
# repositions to a new firing lane.

class_name Marksman
extends EnemyBase

enum State { SPAWN, HOLD, REPOSITION }

const BAND_MIN := 24.0
const BAND_MAX := 34.0
const RETREAT_DIST := 22.0
const ADVANCE_DIST := 36.0
const TOO_CLOSE := 12.0
const AIM_TELEGRAPH := 1.0  # was 0.9: the crack must stay readable
const SHOT_COOLDOWN_MIN := 2.8  # was 2.4: one accurate shot, then a real gap
const SHOT_COOLDOWN_MAX := 4.0  # was 3.6
const REPOSITION_EVERY := 11.0

var state: int = State.SPAWN
var _t := 0.0
var _fire_t := 0.0
var _aim_t := 0.0
var _reposition_t := 0.0
var _move_pos := Vector3.ZERO
var _strafe_dir := 1.0   # in-band sidestep direction (peek behavior)
var _strafe_t := 0.0


func _configure() -> void:
	type_id = "marksman"
	display_name = "Militia Marksman"
	creature_type = "humanoid"
	ability_scores = DnDTypes.ability_scores(11, 15, 13, 12, 14, 10)
	base_hp = 80.0
	base_speed = 3.4  # was 3.8: holds distance, repositions deliberately
	base_damage = 22.0  # was 26: one shot chunks ~1/5 HP, never one-taps
	base_accuracy = 0.88  # was 0.85: most accurate type
	preferred_range = 29.0
	body_radius = 0.34
	body_height = 1.7


func behaviour_tags() -> Array:
	return ["ranged", "long_range_band", "crouch_aim", "reposition", "peek_strafe"]


func _debris_colors() -> Array:
	return [Color(0.14, 0.15, 0.16), Color(0.72, 0.66, 0.53), Color(0.76, 0.60, 0.35)]


func _on_activated() -> void:
	state = State.SPAWN
	_t = 0.0
	_fire_t = randf_range(1.0, 2.0)
	_aim_t = 0.0
	_strafe_t = randf_range(0.8, 1.6)
	_reposition_t = randf_range(7.0, REPOSITION_EVERY)
	aiming = false


func _ai_physics(delta: float) -> void:
	if is_flinching():
		wish_dir = Vector3.ZERO
		aiming = false
		_aim_t = 0.0  # flinch breaks the aim
		return
	var pp := player_pos()
	var dist := global_position.distance_to(pp)
	var see := can_see_player()

	match state:
		State.SPAWN:
			_t += delta
			wish_dir = Vector3.ZERO
			if see:
				face_target = pp
			if _t > 0.6:  # telegraph (0.5s) + short settle; was 0.9
				_set_state(State.HOLD)

		State.HOLD:
			face_target = pp
			_update_band(delta, pp, dist)
			_update_shot(delta, pp, dist, see)
			_reposition_t -= delta
			if dist < TOO_CLOSE or _reposition_t <= 0.0:
				_pick_reposition(pp)
				_set_state(State.REPOSITION)

		State.REPOSITION:
			aiming = false
			face_target = pp
			wish_dir = nav_direction_to(_move_pos, delta)
			wish_speed = speed * 1.25
			var md := Vector2(_move_pos.x - global_position.x, _move_pos.z - global_position.z).length()
			if md < 1.5:
				_reposition_t = randf_range(8.0, REPOSITION_EVERY)
				_set_state(State.HOLD)


func _set_state(s: int) -> void:
	state = s
	_t = 0.0
	wish_speed = 0.0
	if s != State.HOLD:
		aiming = false
		_aim_t = 0.0
		anim_crouch = 0.0


func _update_band(delta: float, pp: Vector3, dist: float) -> void:
	var to_p: Vector3 = pp - global_position
	to_p.y = 0.0
	if dist < RETREAT_DIST:
		# Back off while keeping the rifle roughly on the player.
		wish_dir = -to_p.normalized()
		wish_speed = speed
		aiming = false
	elif dist > ADVANCE_DIST:
		wish_dir = to_p.normalized()
		wish_speed = speed
		aiming = false
	else:
		# In the band: peek — slow sidestep perpendicular to the player,
		# flipping direction every 1.2–2.0s so the head is never static.
		# (_update_shot overrides wish_dir to ZERO while aiming.)
		_strafe_t -= delta
		if _strafe_t <= 0.0:
			_strafe_t = randf_range(1.2, 2.0)
			_strafe_dir = -_strafe_dir
		var perp := Vector3(-to_p.z, 0, to_p.x).normalized() * _strafe_dir
		wish_dir = perp * 0.5
		wish_speed = speed * 0.6


func _update_shot(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	if _aim_t > 0.0:
		aiming = true
		anim_crouch = 1.0  # rework: drops into a crouch for the shot
		face_target = pp
		wish_dir = Vector3.ZERO
		_aim_t -= delta
		if _aim_t <= 0.0:
			anim_crouch = 0.0
			trigger_strike()  # recoil kick pose on the crack
			var spread := lerpf(3.0, 0.9, accuracy) + maxf(0.0, dist - BAND_MAX) * 0.05
			fire_hitscan(damage, spread, "shot_sniper", Color(0.7, 0.9, 1.0))
		return
	aiming = false
	anim_crouch = 0.0
	_fire_t -= delta
	if _fire_t <= 0.0 and see and dist < SIGHT_RANGE:
		_fire_t = randf_range(SHOT_COOLDOWN_MIN, SHOT_COOLDOWN_MAX)
		_aim_t = AIM_TELEGRAPH  # long, readable telegraph before the crack
		begin_telegraph(AIM_TELEGRAPH, "snipe")


func _pick_reposition(pp: Vector3) -> void:
	# New firing lane: 26–32m from the player at a wide random angle.
	var ang := randf() * TAU
	var r := randf_range(26.0, 32.0)
	_move_pos = pp + Vector3(cos(ang) * r, 0, sin(ang) * r)
