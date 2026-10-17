# FORGEFALL — scripts/enemies/suppressor.gd
# Goal 3 CONTENT (Worker B — Enemies).
#
# SUPPRESSOR — long-range area-denial gunner. Holds a 30–40m band and lays
# down sustained 6-round suppression bursts with HIGH spread: it is not
# trying to hit you, it is trying to make the open ground uninhabitable.
# NEW (rework): the burst SWEEPS — the aim point walks laterally across
# the player's position during the burst, so standing still in the open
# gets progressively more dangerous while a single sidestep clears the
# whole sweep. Distinct from the Marksman (one precise 22-dmg crack,
# long telegraph) and the Brute (close LMG barrage): the Suppressor pins
# campers from across the map and forces repositioning into cover.
# Counterplay: its bursts are inaccurate (move + it mostly misses), it
# is slow, and its 0.7s pre-burst telegraph + long cooldown leave big
# punish windows.

class_name Suppressor
extends EnemyBase

enum State { SPAWN, HOLD, REPOSITION }

const BAND_MIN := 30.0
const BAND_MAX := 40.0
const RETREAT_DIST := 27.0
const ADVANCE_DIST := 43.0
const TOO_CLOSE := 14.0
const BURST_COUNT := 6
const BURST_DAMAGE := 7.0    # 6 x 7 = 42 worst case, spread makes 0-2 hits typical
const SPREAD_BONUS := 4.5    # extra degrees on top of combat_spread: suppression, not precision
const AIM_TELEGRAPH := 0.7   # visible aim pose before the burst starts
const SHOT_COOLDOWN_MIN := 3.5
const SHOT_COOLDOWN_MAX := 5.0
const REPOSITION_EVERY := 13.0

var state: int = State.SPAWN
var _t := 0.0
var _fire_t := 0.0
var _aim_t := 0.0
var _reposition_t := 0.0
var _move_pos := Vector3.ZERO
var _strafe_dir := 1.0
var _strafe_t := 0.0
var _sweep_phase := 0.0  # rework: burst sweep oscillator


func _configure() -> void:
	type_id = "suppressor"
	display_name = "Suppressor"
	creature_type = "humanoid"
	ability_scores = DnDTypes.ability_scores(12, 13, 13, 11, 12, 10)
	base_hp = 110.0
	base_speed = 3.0      # slow: once you close the distance it cannot escape
	base_damage = BURST_DAMAGE
	base_accuracy = 0.45  # mediocre by design — spread does the suppressing
	preferred_range = 35.0
	body_radius = 0.34
	body_height = 1.7


func behaviour_tags() -> Array:
	return ["ranged", "suppression_sweep", "long_range_band", "reposition", "area_denial"]


func _debris_colors() -> Array:
	return [Color(0.25, 0.1, 0.4), Color(0.14, 0.15, 0.16), Color(0.7, 0.3, 1.0)]


func _on_activated() -> void:
	state = State.SPAWN
	_t = 0.0
	_fire_t = randf_range(1.2, 2.2)
	_aim_t = 0.0
	_strafe_t = randf_range(0.8, 1.6)
	_reposition_t = randf_range(8.0, REPOSITION_EVERY)
	aiming = false


func _ai_physics(delta: float) -> void:
	if is_flinching():
		wish_dir = Vector3.ZERO
		aiming = false
		_aim_t = 0.0  # flinch breaks the aim, like the marksman
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
			if _t > 0.6:  # telegraph (0.5s) + short settle
				_set_state(State.HOLD)

		State.HOLD:
			face_target = pp
			_update_band(delta, pp, dist)
			_update_burst(delta, pp, dist, see)
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
				_reposition_t = randf_range(9.0, REPOSITION_EVERY)
				_set_state(State.HOLD)


func _set_state(s: int) -> void:
	state = s
	_t = 0.0
	wish_speed = 0.0
	aim_offset = Vector3.ZERO  # sweep ends when the state ends
	if s != State.HOLD:
		aiming = false
		_aim_t = 0.0


func _update_band(delta: float, pp: Vector3, dist: float) -> void:
	var to_p: Vector3 = pp - global_position
	to_p.y = 0.0
	if dist < RETREAT_DIST:
		wish_dir = -to_p.normalized()
		wish_speed = speed
		aiming = false
	elif dist > ADVANCE_DIST:
		wish_dir = to_p.normalized()
		wish_speed = speed
		aiming = false
	else:
		# In the band: slow sidestep so the head is never static.
		_strafe_t -= delta
		if _strafe_t <= 0.0:
			_strafe_t = randf_range(1.2, 2.0)
			_strafe_dir = -_strafe_dir
		var perp := Vector3(-to_p.z, 0, to_p.x).normalized() * _strafe_dir
		wish_dir = perp * 0.5
		wish_speed = speed * 0.6


func _update_burst(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	# Sustained fire: gun_update drips one round per 0.13s with big spread.
	gun_update(delta, damage, combat_spread(dist) + SPREAD_BONUS,
		"shot_lmg", Color(1.0, 0.3, 0.9))
	if gun_burst_left > 0:
		aiming = true
		face_target = pp
		# Sweep: the aim point walks laterally across the player during
		# the burst (via base aim_offset, consumed by fire_hitscan).
		_sweep_phase += delta
		var to_p: Vector3 = pp - global_position
		to_p.y = 0.0
		if to_p.length_squared() > 0.01:
			var perp := Vector3(-to_p.z, 0, to_p.x).normalized()
			aim_offset = perp * sin(_sweep_phase * 2.2) * 2.5
		return
	aim_offset = Vector3.ZERO
	if _aim_t > 0.0:
		aiming = true
		face_target = pp
		wish_dir = Vector3.ZERO
		_aim_t -= delta
		if _aim_t <= 0.0:
			gun_trigger(BURST_COUNT)
			trigger_strike()
			_sweep_phase = 0.0
		return
	aiming = false
	_fire_t -= delta
	if _fire_t <= 0.0 and see and dist < SIGHT_RANGE:
		_fire_t = randf_range(SHOT_COOLDOWN_MIN, SHOT_COOLDOWN_MAX)
		_aim_t = AIM_TELEGRAPH
		begin_telegraph(AIM_TELEGRAPH, "suppress")


func _pick_reposition(pp: Vector3) -> void:
	# New firing lane: 32–38m from the player at a wide random angle.
	var ang := randf() * TAU
	var r := randf_range(32.0, 38.0)
	_move_pos = pp + Vector3(cos(ang) * r, 0, sin(ang) * r)
