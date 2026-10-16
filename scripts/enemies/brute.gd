# FORGEFALL — scripts/enemies/brute.gd
# Worker 4 (enemy AI + waves).
#
# BRUTE ("Juggernaut") — spawns on every 5th wave. 12x grunt HP, LMG with
# long sustained bursts, slow inexorable advance, IMMUNE to flinch/knockback,
# never takes cover. The wave manager announces "JUGGERNAUT INBOUND".

class_name Brute
extends EnemyBase

enum State { SPAWN, ADVANCE, BARRAGE }

const BURST_COUNT := 8  # was 10: 8 x 9 = 72 max per barrage, never instant-kill
const BURST_GAP := 0.10
const FIRE_COOLDOWN := 1.8  # was 1.2: a real gap between barrages to punish/reload
const AIM_TELEGRAPH := 0.5
const BARRAGE_RANGE := 15.0
const ADVANCE_RESUME := 19.0

var state: int = State.SPAWN
var _t := 0.0
var _fire_t := 0.0
var _aim_t := 0.0
var _strafe_dir := 1.0
var _strafe_t := 0.0


func _configure() -> void:
	type_id = "brute"
	display_name = "Juggernaut"
	creature_type = "humanoid"
	ability_scores = DnDTypes.ability_scores(19, 9, 18, 8, 10, 9)
	base_hp = 1200.0  # 12x grunt: the tank. Kite it — it cannot catch you.
	base_speed = 2.4  # was 2.6: slowest type, always kiteable
	base_damage = 9.0  # was 11: heavy but survivable per hit
	base_accuracy = 0.42  # was 0.5: LMG spray, not a laser
	preferred_range = 13.0
	flinch_immune = true
	body_radius = 0.46
	body_height = 2.05
	body_scale = Vector3(1.28, 1.18, 1.32)


func _debris_colors() -> Array:
	return [Color(0.23, 0.25, 0.27), Color(0.14, 0.15, 0.16), Color(0.54, 0.29, 0.16)]


func _on_activated() -> void:
	state = State.SPAWN
	_t = 0.0
	_fire_t = 1.2
	_aim_t = 0.0
	_strafe_t = 0.0
	aiming = false


func _ai_physics(delta: float) -> void:
	# No flinch handling: the Juggernaut does not stagger. Ever.
	var pp := player_pos()
	var dist := global_position.distance_to(pp)
	var see := can_see_player()

	match state:
		State.SPAWN:
			_t += delta
			wish_dir = Vector3.ZERO
			if see:
				face_target = pp
			if _t > 0.9:  # heavy spawn beat + telegraph; was 1.2
				_set_state(State.ADVANCE)

		State.ADVANCE:
			aiming = false
			face_target = pp
			wish_dir = nav_direction_to(pp, delta)
			wish_speed = speed
			if see and dist <= BARRAGE_RANGE:
				_set_state(State.BARRAGE)

		State.BARRAGE:
			face_target = pp
			# Slow menacing strafe, never still.
			_strafe_t -= delta
			if _strafe_t <= 0.0:
				_strafe_t = randf_range(1.6, 3.0)
				_strafe_dir = -_strafe_dir
			var to_p: Vector3 = pp - global_position
			to_p.y = 0.0
			var perp := Vector3(-to_p.z, 0, to_p.x).normalized() * _strafe_dir
			var close := Vector3.ZERO
			if dist > BARRAGE_RANGE + 3.0:
				close = to_p.normalized() * 0.8
			wish_dir = perp * 0.35 + close
			wish_speed = speed
			_update_lmg(delta, pp, dist, see)
			if dist > ADVANCE_RESUME:
				_set_state(State.ADVANCE)


func _set_state(s: int) -> void:
	state = s
	_t = 0.0
	_aim_t = 0.0
	aiming = false
	wish_speed = 0.0


func _update_lmg(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	gun_update(delta, damage, combat_spread(dist) + 1.5, "shot_ar", Color(1.0, 0.5, 0.25))
	if gun_burst_left > 0:
		aiming = true
		face_target = pp
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
		_fire_t = FIRE_COOLDOWN
		_aim_t = AIM_TELEGRAPH
