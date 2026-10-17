# FORGEFALL — scripts/enemies/rusher.gd
# Worker 4 (enemy AI + waves).
#
# RUSHER — shotgun breacher. Sprints at the player in a zigzag with
# sudden FEINT JUKES (a hard 90-degree cut every 1–2s), then a TELEGRAPHED
# BLAST: a 0.35s wind-up (shotgun raised, lamp lit) before the 6-pellet
# blast — the old instant blast is gone. Then strafes tight while the
# shotgun cycles. Falls back to hunting the last known position when
# sight is lost. Throws grenades like a grunt at wave >= 4.

class_name Rusher
extends EnemyBase

enum State { SPAWN, CHARGE, WINDUP, BLAST, HUNT }

const BLAST_RANGE := 6.5
const BLAST_PELLETS := 6
const PELLET_SPREAD := 9.5  # was 7.0: rushers are sloppy up close, not lasers
const BLAST_COOLDOWN := 2.0  # was 1.7: more breathing room after each blast
const WINDUP_TIME := 0.35   # rework: telegraphed blast wind-up
const LOST_SIGHT_TIMEOUT := 4.0
const GRENADE_MIN_WAVE := 4

var state: int = State.SPAWN
var _t := 0.0
var _fire_t := 0.0
var _zig_phase := 0.0
var _strafe_dir := 1.0
var _strafe_t := 0.0
var _lost_t := 0.0
var _grenade_t := 0.0
var _windup_t := 0.0    # rework: blast wind-up countdown
var _juke_t := 0.0      # rework: time to the next feint juke
var _juke_active_t := 0.0  # rework: remaining juke cut time


func _configure() -> void:
	type_id = "rusher"
	display_name = "Militia Rusher"
	creature_type = "humanoid"
	ability_scores = DnDTypes.ability_scores(11, 15, 11, 9, 10, 9)
	base_hp = 60.0      # was 70: glass cannon — dies fast if you aim
	base_speed = 7.0    # was 6.2: fastest type, closes distance hard
	base_damage = 6.0   # per pellet; 6 pellets = 36 max, never instant-kill
	base_accuracy = 0.35  # was 0.6: low accuracy by design (spread does the work)
	preferred_range = 6.0
	body_radius = 0.34
	body_height = 1.7


func behaviour_tags() -> Array:
	return ["shotgun", "zigzag_charge", "juke", "telegraphed_blast", "strafe", "grenade"]


func _debris_colors() -> Array:
	return [Color(0.54, 0.29, 0.16), Color(0.14, 0.15, 0.16), Color(1.0, 0.25, 0.15)]


func _on_activated() -> void:
	state = State.SPAWN
	_t = 0.0
	_fire_t = 0.4
	_zig_phase = randf() * TAU
	_strafe_t = 0.0
	_lost_t = 0.0
	_grenade_t = randf_range(5.0, 9.0)
	_windup_t = 0.0
	_juke_t = 0.0  # jukes on the first charge tick, then every 1.2–2.0s
	_juke_active_t = 0.0
	aiming = false


func _ai_physics(delta: float) -> void:
	if is_flinching():
		# A hit mid-windup cancels the blast — shooting it saves you.
		if state == State.WINDUP:
			_set_state(State.CHARGE)
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
			if _t > 0.5:  # telegraph (0.5s) + short settle; was 0.7
				_set_state(State.CHARGE)

		State.CHARGE:
			aiming = false
			face_target = pp
			# Zigzag sprint: nav direction plus a sinusoidal perpendicular
			# weave, interrupted by sudden feint jukes (hard lateral cut).
			var dir := nav_direction_to(pp, delta)
			_zig_phase += delta * 3.2
			var perp := Vector3(-dir.z, 0, dir.x)
			var weave := sin(_zig_phase) * 0.45
			_juke_t -= delta
			if _juke_t <= 0.0:
				_juke_t = randf_range(1.2, 2.0)
				_juke_active_t = 0.3
				_strafe_dir = -_strafe_dir
			if _juke_active_t > 0.0:
				_juke_active_t -= delta
				weave = _strafe_dir * 2.2
			wish_dir = (dir + perp * weave).normalized()
			wish_speed = speed
			if see and dist <= BLAST_RANGE:
				_windup_t = WINDUP_TIME
				begin_telegraph(WINDUP_TIME, "blast")
				_set_state(State.WINDUP)
			elif not see and _lost_t > LOST_SIGHT_TIMEOUT:
				_set_state(State.HUNT)

		State.WINDUP:
			# Planted, shotgun raised: the readable blast telegraph.
			aiming = true
			wish_dir = Vector3.ZERO
			face_target = pp
			_windup_t -= delta
			if _windup_t <= 0.0:
				trigger_strike()
				for i in BLAST_PELLETS:
					fire_hitscan(damage, PELLET_SPREAD, "shot_shotgun", Color(1.0, 0.6, 0.2))
				_fire_t = BLAST_COOLDOWN
				_set_state(State.BLAST)
			elif not see:
				# Lost sight mid-windup: abort, re-approach.
				_set_state(State.CHARGE)

		State.BLAST:
			face_target = pp
			aiming = false
			_fire_t -= delta
			if _fire_t <= 0.0 and see and dist < BLAST_RANGE + 2.0:
				_windup_t = WINDUP_TIME
				begin_telegraph(WINDUP_TIME, "blast")
				_set_state(State.WINDUP)
			# Tight circle-strafe while the shotgun cycles.
			_strafe_t -= delta
			if _strafe_t <= 0.0:
				_strafe_t = randf_range(0.8, 1.6)
				_strafe_dir = -_strafe_dir
			var to_p: Vector3 = pp - global_position
			to_p.y = 0.0
			var perp2 := Vector3(-to_p.z, 0, to_p.x).normalized() * _strafe_dir
			var hold := Vector3.ZERO
			if dist > BLAST_RANGE:
				hold = to_p.normalized() * 0.8
			elif dist < BLAST_RANGE - 2.5:
				hold = -to_p.normalized() * 0.5
			wish_dir = perp2 * 0.7 + hold
			wish_speed = speed * 0.6
			if dist > BLAST_RANGE + 5.0:
				_set_state(State.CHARGE)
			elif not see and _lost_t > LOST_SIGHT_TIMEOUT:
				_set_state(State.HUNT)

		State.HUNT:
			aiming = false
			wish_dir = nav_direction_to(last_seen_pos, delta)
			wish_speed = speed * 0.8
			var hd := Vector2(last_seen_pos.x - global_position.x, last_seen_pos.z - global_position.z).length()
			if see:
				_set_state(State.CHARGE)
			elif hd < 1.5:
				# Reached last known position: sweep around it.
				_strafe_t -= delta
				if _strafe_t <= 0.0:
					_strafe_t = randf_range(1.0, 2.0)
					_strafe_dir = -_strafe_dir
				wish_dir = Vector3(-wish_dir.z, 0, wish_dir.x) * _strafe_dir * 0.5
				face_target = last_seen_pos


func _set_state(s: int) -> void:
	state = s
	_t = 0.0
	aiming = false
	wish_speed = 0.0


func _try_grenade(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	var enabled: bool = wave_number >= GRENADE_MIN_WAVE or bool(director_mods.get("grenadiers", false))
	if not enabled:
		return
	_grenade_t -= delta
	if _grenade_t > 0.0:
		return
	if see and dist > 8.0 and dist < 24.0:
		_grenade_t = randf_range(9.0, 15.0)
		EnemyGrenade.throw_at(get_parent(), global_position + Vector3(0, 1.5, 0), pp)
