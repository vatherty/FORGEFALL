# FORGEFALL — scripts/enemies/grunt.gd
# Worker 4 (enemy AI + waves).
#
# GRUNT — the backbone militia rifleman. BOUNDING OVERWATCH advance
# (rework): moves in bounds, then plants, aims (telegraphed) and fires —
# never a straight run at the player. In combat: strafes and fires aimed
# bursts, takes cover below 50% HP (peek-and-fire), and flanks when the
# player camps in one spot. Throws telegraphed grenades at wave >= 4
# (or when the Forge director enables grenadiers).

class_name Grunt
extends EnemyBase

enum State { SPAWN, ADVANCE, COMBAT, TAKE_COVER, PEEK, FLANK }

const BURST_COUNT := 3
const FIRE_COOLDOWN_MIN := 1.3
const FIRE_COOLDOWN_MAX := 2.1
const AIM_TELEGRAPH := 0.4
const STRAFE_TIME_MIN := 1.0
const STRAFE_TIME_MAX := 2.2
const LOST_SIGHT_TIMEOUT := 3.0
const CAMP_TIME := 6.0        # player still this long -> flank
const CAMP_DIST := 2.5
const GRENADE_MIN_WAVE := 4
const GRENADE_RANGE_MIN := 8.0
const GRENADE_RANGE_MAX := 24.0

var state: int = State.SPAWN
var _t := 0.0
var _strafe_dir := 1.0
var _strafe_t := 0.0
var _fire_t := 0.0
var _aim_t := 0.0
var _peek_phase_t := 0.0
var _peeking := false
var _peek_count := 0
var _cover_node: Node3D = null
var _cover_pos := Vector3.ZERO
var _flank_pos := Vector3.ZERO
var _flank_side := 1.0
var _still_t := 0.0
var _still_ref := Vector3.ZERO
var _lost_t := 0.0
var _grenade_t := 0.0
var _bound_t := 0.0       # rework: bounding-overwatch phase timer
var _bound_move := true   # rework: true = moving bound, false = planted firing bound


func _configure() -> void:
	type_id = "grunt"
	display_name = "Militia Grunt"
	creature_type = "humanoid"  # v0.5.8 D&D: militia are humanoid (default)
	ability_scores = DnDTypes.ability_scores(12, 12, 12, 10, 11, 10)
	base_hp = 100.0
	base_speed = 4.2
	base_damage = 9.0
	base_accuracy = 0.55
	preferred_range = 15.0
	body_radius = 0.34
	body_height = 1.7


func behaviour_tags() -> Array:
	return ["ranged", "bounding_advance", "strafe", "cover_peek", "flank", "grenade"]


func _debris_colors() -> Array:
	return [Color(0.35, 0.42, 0.24), Color(0.14, 0.15, 0.16), Color(0.76, 0.66, 0.47)]


func _on_activated() -> void:
	state = State.SPAWN
	_t = 0.0
	_fire_t = randf_range(0.6, 1.4)
	_strafe_t = 0.0
	_aim_t = 0.0
	_peek_count = 0
	_cover_node = null
	_still_t = 0.0
	_still_ref = player_pos()
	_lost_t = 0.0
	_grenade_t = randf_range(4.0, 8.0)
	_bound_t = 1.0
	_bound_move = true
	aiming = false


func _on_damaged() -> void:
	# Getting shot makes grunts seek cover sooner.
	if hp < max_hp * 0.55 and (state == State.ADVANCE or state == State.COMBAT):
		if _find_cover():
			_enter_cover()


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
	_try_grenade(delta, pp, dist, see)

	match state:
		State.SPAWN:
			_t += delta
			wish_dir = Vector3.ZERO
			if see:
				face_target = pp
			if _t > 0.6:  # telegraph (0.5s) + short settle; was 0.9
				_set_state(State.ADVANCE)

		State.ADVANCE:
			face_target = pp
			# Bounding overwatch: MOVE bound (advance) alternates with a
			# SET bound (planted, aimed, firing). Never a straight run.
			_bound_t -= delta
			if _bound_t <= 0.0:
				_bound_move = not _bound_move
				_bound_t = 1.3 if _bound_move else 1.0
			if _bound_move:
				aiming = false
				wish_dir = nav_direction_to(pp, delta)
				wish_speed = speed
			else:
				aiming = true
				wish_dir = Vector3.ZERO
				_update_fire(delta, pp, dist, see)
			if see and dist <= preferred_range:
				_set_state(State.COMBAT)
			elif hp < max_hp * 0.5 and _find_cover():
				_enter_cover()
			elif not see and _lost_t > LOST_SIGHT_TIMEOUT:
				wish_dir = nav_direction_to(last_seen_pos, delta)

		State.COMBAT:
			face_target = pp
			_update_strafe(delta, pp, dist)
			_update_fire(delta, pp, dist, see)
			_track_camp(delta, pp, see)
			if hp < max_hp * 0.4 and _find_cover():
				_enter_cover()
			elif _lost_t > LOST_SIGHT_TIMEOUT:
				_set_state(State.ADVANCE)

		State.TAKE_COVER:
			aiming = false
			if _cover_node == null or not is_instance_valid(_cover_node):
				_set_state(State.COMBAT)
				return
			face_target = pp
			wish_dir = nav_direction_to(_cover_pos, delta)
			var cd := Vector2(_cover_pos.x - global_position.x, _cover_pos.z - global_position.z).length()
			if cd < 1.1:
				_set_state(State.PEEK)
				_peek_count = 0
				_peeking = true
				_peek_phase_t = 1.0

		State.PEEK:
			face_target = pp
			wish_dir = Vector3.ZERO
			_update_peek(delta, pp, dist, see)

		State.FLANK:
			aiming = false
			face_target = pp
			wish_dir = nav_direction_to(_flank_pos, delta)
			_t += delta
			var fd := Vector2(_flank_pos.x - global_position.x, _flank_pos.z - global_position.z).length()
			if fd < 2.0 or _t > 7.0:
				_set_state(State.COMBAT)
			elif see and dist <= preferred_range * 0.7:
				_set_state(State.COMBAT)


func _set_state(s: int) -> void:
	state = s
	_t = 0.0
	_aim_t = 0.0
	aiming = false
	wish_speed = 0.0


func _update_strafe(delta: float, pp: Vector3, dist: float) -> void:
	_strafe_t -= delta
	if _strafe_t <= 0.0:
		_strafe_t = randf_range(STRAFE_TIME_MIN, STRAFE_TIME_MAX)
		_strafe_dir = -_strafe_dir if randf() < 0.7 else _strafe_dir
		if randf() < 0.25:
			_strafe_t = 0.4  # brief pause
			_strafe_dir = 0.0
	var to_p: Vector3 = pp - global_position
	to_p.y = 0.0
	var perp := Vector3(-to_p.z, 0, to_p.x).normalized() * _strafe_dir
	var radial := Vector3.ZERO
	if dist > preferred_range + 4.0:
		radial = to_p.normalized() * 0.7
	elif dist < preferred_range - 6.0:
		radial = -to_p.normalized() * 0.7
	wish_dir = (perp * 0.6 + radial)
	if wish_dir.length_squared() > 1.0:
		wish_dir = wish_dir.normalized()
	wish_speed = speed * 0.55


func _update_fire(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	gun_update(delta, damage, combat_spread(dist), "shot_ar", Color(1.0, 0.85, 0.4))
	if gun_burst_left > 0:
		aiming = true
		return
	if _aim_t > 0.0:
		aiming = true
		face_target = pp
		_aim_t -= delta
		if _aim_t <= 0.0:
			gun_trigger(BURST_COUNT)
			trigger_strike()  # recoil kick pose on the burst
		return
	aiming = false
	_fire_t -= delta
	if _fire_t <= 0.0 and see and dist < SIGHT_RANGE:
		_fire_t = randf_range(FIRE_COOLDOWN_MIN, FIRE_COOLDOWN_MAX)
		_aim_t = AIM_TELEGRAPH  # telegraphed aim before the burst
		begin_telegraph(AIM_TELEGRAPH, "aim")


func _track_camp(delta: float, pp: Vector3, see: bool) -> void:
	if pp.distance_to(_still_ref) > CAMP_DIST:
		_still_ref = pp
		_still_t = 0.0
	elif see:
		_still_t += delta
		if _still_t > CAMP_TIME:
			_still_t = 0.0
			_flank_side = 1.0 if randf() < 0.5 else -1.0
			var d: Vector3 = pp - global_position
			d.y = 0.0
			var side := Vector3(-d.z, 0, d.x).normalized() * _flank_side
			_flank_pos = pp + side * 13.0
			_set_state(State.FLANK)


func _find_cover() -> bool:
	var best: Node3D = null
	var best_d := 30.0
	for c in get_tree().get_nodes_in_group("cover"):
		if c is Node3D and is_instance_valid(c):
			var d: float = (c as Node3D).global_position.distance_to(global_position)
			if d < best_d:
				best_d = d
				best = c as Node3D
	if best != null and best.has_method("cover_point"):
		_cover_node = best
		_cover_pos = best.call("cover_point", player_pos()) as Vector3
		return true
	return false


func _enter_cover() -> void:
	_set_state(State.TAKE_COVER)


func _update_peek(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	_peek_phase_t -= delta
	if _peeking:
		aiming = true
		gun_update(delta, damage, combat_spread(dist), "shot_ar", Color(1.0, 0.85, 0.4))
		if _peek_phase_t <= 0.0:
			_peeking = false
			_peek_phase_t = randf_range(1.2, 1.8)
			aiming = false
	else:
		aiming = false
		if _peek_phase_t <= 0.0:
			_peek_count += 1
			if _peek_count >= 3:
				_set_state(State.COMBAT)
				return
			_peeking = true
			_peek_phase_t = 1.0
			if see:
				_aim_t = 0.0
				gun_trigger(BURST_COUNT)
				trigger_strike()


func _try_grenade(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	var enabled: bool = wave_number >= GRENADE_MIN_WAVE or bool(director_mods.get("grenadiers", false))
	if not enabled:
		return
	_grenade_t -= delta
	if _grenade_t > 0.0:
		return
	if see and dist > GRENADE_RANGE_MIN and dist < GRENADE_RANGE_MAX:
		_grenade_t = randf_range(8.0, 14.0)
		var from: Vector3 = global_position + Vector3(0, 1.5, 0)
		EnemyGrenade.throw_at(get_parent(), from, pp)
