# FORGEFALL — scripts/enemies/warlord.gd
# Goal 3 CONTENT (Worker B — Enemies).
#
# WARLORD — wave boss. 3000 HP, huge gold-crested voxel silhouette,
# flinch-immune, three phases, and a telegraphed ground SLAM in phase 3.
# Appears once on waves 8, 16, 24, ... (WaveManager._build_queue) — never
# every wave, never more than one per wave. The WaveManager announces
# "!! WARLORD INBOUND !!" at wave start.
#
#   Phase 1 (100–66% HP):  steady advance + 5-round bursts, speed 3.2.
#   Phase 2 (66–33% HP):   faster bursts, summons 2 rushers ONCE,
#                           killfeed warns "WARLORD ENRAGED".
#   Phase 3 (<33% HP):     faster movement (x1.3), summons 2 shredders
#                           ONCE, and unlocks the SLAM: when the player is
#                           within 9m it telegraphs for 1.0s (horn + frozen
#                           aim pose), then detonates a 7m shockwave for up
#                           to 34 damage with falloff to 0 at the edge.
#                           6s cooldown between slams; sprint away to dodge.
#
# Counterplay throughout: it is slow and kiteable, every heavy attack is
# telegraphed, and the slam only triggers close-in — keep distance, use
# the telegraphs, and burn it down between summons. Worst-case burst
# (5 x 10 = 50) and worst-case slam (34) are both survivable from 100 HP.

class_name Warlord
extends EnemyBase

enum State { SPAWN, ADVANCE, BARRAGE, SLAM_TELEGRAPH, SLAM_RECOVER }

const BURST_COUNT := 5
const BURST_DAMAGE := 10.0  # 5 x 10 = 50 worst case, never instant-kill
const FIRE_COOLDOWN_P1 := 2.0
const FIRE_COOLDOWN_P2 := 1.6
const FIRE_COOLDOWN_P3 := 1.2
const AIM_TELEGRAPH := 0.5
const BARRAGE_RANGE := 15.0
const ADVANCE_RESUME := 19.0
const PHASE2_FRAC := 0.66
const PHASE3_FRAC := 0.33
const SLAM_TRIGGER_RANGE := 9.0
const SLAM_TELEGRAPH_TIME := 1.0  # long, readable windup
const SLAM_RECOVER_TIME := 1.2
const SLAM_RADIUS := 7.0
const SLAM_MAX_DAMAGE := 34.0
const SLAM_COOLDOWN := 6.0
const PHASE3_SPEED_MULT := 1.3

var state: int = State.SPAWN
var _t := 0.0
var _fire_t := 0.0
var _aim_t := 0.0
var _strafe_dir := 1.0
var _strafe_t := 0.0
var _phase := 1
var _summoned_p2 := false
var _summoned_p3 := false
var _slam_t := 0.0
var _slam_cooldown := 0.0


func _configure() -> void:
	type_id = "warlord"
	display_name = "Warlord"
	creature_type = "humanoid"
	ability_scores = DnDTypes.ability_scores(20, 14, 20, 14, 15, 16)
	base_hp = 3000.0   # 2.5x the Juggernaut: a real boss fight, not a bullet sponge vs one player
	base_speed = 3.2   # slow — always kiteable, even in phase 3 (3.2 x 1.3 = 4.2 < 11 sprint)
	base_damage = BURST_DAMAGE
	base_accuracy = 0.5
	preferred_range = 13.0
	flinch_immune = true
	body_radius = 0.55
	body_height = 2.3
	body_scale = Vector3(1.6, 1.5, 1.65)  # biggest silhouette on the field


func behaviour_tags() -> Array:
	return ["boss", "phases", "summons", "slam_aoe", "flinch_immune", "barrage"]


func _debris_colors() -> Array:
	return [Color(0.5, 0.1, 0.1), Color(1.0, 0.75, 0.15), Color(0.14, 0.15, 0.16)]


func phase() -> int:
	"""Current boss phase from HP fraction (1/2/3). Verifier-friendly."""
	if max_hp <= 0.0:
		return 1
	var frac := hp / max_hp
	if frac <= PHASE3_FRAC:
		return 3
	if frac <= PHASE2_FRAC:
		return 2
	return 1


func _on_activated() -> void:
	state = State.SPAWN
	_t = 0.0
	_fire_t = 1.4
	_aim_t = 0.0
	_strafe_t = 0.0
	_phase = 1
	_summoned_p2 = false
	_summoned_p3 = false
	_slam_t = 0.0
	_slam_cooldown = 2.0  # no instant slam on spawn — the player gets a look first
	aiming = false


func die() -> void:
	if dead:
		return
	var pos := global_position
	super.die()
	# Boss death goes out with a bang: visuals + shockwave FX, no extra damage.
	if ClassDB.class_exists("ExplosionFX"):
		ExplosionFX.detonate_light(pos)
	if ClassDB.class_exists("DebrisPool"):
		DebrisPool.burst(pos + Vector3(0, 1.5, 0), _debris_colors(), 26, 6.0)
	_announce("WARLORD DOWN — run saved.")


func _announce(text: String) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("add_killfeed"):
			h.call("add_killfeed", text)


func _ai_physics(delta: float) -> void:
	# No flinch handling: the Warlord does not stagger. Ever.
	var pp := player_pos()
	var dist := global_position.distance_to(pp)
	var see := can_see_player()
	if _slam_cooldown > 0.0:
		_slam_cooldown -= delta
	_update_phase()

	match state:
		State.SPAWN:
			_t += delta
			wish_dir = Vector3.ZERO
			if see:
				face_target = pp
			if _t > 1.0:  # heavy spawn beat + telegraph
				_set_state(State.ADVANCE)

		State.ADVANCE:
			aiming = false
			face_target = pp
			wish_dir = nav_direction_to(pp, delta)
			wish_speed = speed * (_phase_speed_mult())
			if _try_slam(pp, dist, see):
				return
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
			wish_speed = speed * _phase_speed_mult()
			if _try_slam(pp, dist, see):
				return
			_update_burst(delta, pp, dist, see)
			if dist > ADVANCE_RESUME:
				_set_state(State.ADVANCE)

		State.SLAM_TELEGRAPH:
			# Planted, roaring, weapon raised — the 1.0s dodge window.
			aiming = true
			wish_dir = Vector3.ZERO
			face_target = pp
			_slam_t -= delta
			if _slam_t <= 0.0:
				_detonate_slam()
				_set_state(State.SLAM_RECOVER)

		State.SLAM_RECOVER:
			aiming = false
			wish_dir = Vector3.ZERO
			face_target = pp
			_t += delta
			if _t >= SLAM_RECOVER_TIME:
				_set_state(State.BARRAGE)


func _phase_speed_mult() -> float:
	return PHASE3_SPEED_MULT if _phase >= 3 else 1.0


func _update_phase() -> void:
	var p := phase()
	if p == _phase:
		return
	_phase = p
	# Rework: phase change roars — horn + a brief raised-weapon telegraph
	# pose (arms up, lamp lit) so the phase shift reads before the summons.
	Sfx.play_3d("juggernaut_horn", global_position)
	begin_telegraph(0.5, "roar")
	var mgr := get_parent()
	if p == 2:
		_announce("WARLORD ENRAGED — reinforcements inbound!")
		if not _summoned_p2 and mgr != null and mgr.has_method("queue_extra"):
			_summoned_p2 = true
			mgr.call("queue_extra", "rusher", 2)
	elif p == 3:
		_announce("WARLORD UNLEASHED — watch for the SLAM!")
		if not _summoned_p3 and mgr != null and mgr.has_method("queue_extra"):
			_summoned_p3 = true
			mgr.call("queue_extra", "shredder", 2)


func _try_slam(_pp: Vector3, dist: float, see: bool) -> bool:
	# Phase 3 only, close-in, LOS, cooldown respected.
	if _phase < 3 or _slam_cooldown > 0.0 or not see or dist > SLAM_TRIGGER_RANGE:
		return false
	_slam_cooldown = SLAM_COOLDOWN
	_slam_t = SLAM_TELEGRAPH_TIME
	begin_telegraph(SLAM_TELEGRAPH_TIME, "slam")
	Sfx.play_3d("juggernaut_horn", global_position)
	_announce("WARLORD SLAM — MOVE!")
	_set_state(State.SLAM_TELEGRAPH)
	return true


func _detonate_slam() -> void:
	trigger_strike()
	# Visuals (detonate_light: fireball + shake + explosion_small, no damage).
	if ClassDB.class_exists("ExplosionFX"):
		ExplosionFX.detonate_light(global_position)
	if ClassDB.class_exists("DebrisPool"):
		DebrisPool.burst(global_position + Vector3(0, 0.3, 0),
			[Color(1.0, 0.75, 0.15), Color(0.5, 0.1, 0.1)], 16, 5.0)
	# Manual damage: linear falloff to ZERO at the edge (fair — sprinting
	# out during the 1.0s telegraph avoids it entirely).
	var p := _player_node()
	if p == null or not p.has_method("take_damage"):
		return
	var d: float = p.global_position.distance_to(global_position)
	if d < SLAM_RADIUS:
		var fall := 1.0 - d / SLAM_RADIUS
		p.take_damage(SLAM_MAX_DAMAGE * fall * float(director_mods.get("dmg_mult", 1.0)),
			global_position, false)


func _set_state(s: int) -> void:
	state = s
	_t = 0.0
	_aim_t = 0.0
	aiming = false
	wish_speed = 0.0


func _update_burst(delta: float, pp: Vector3, dist: float, see: bool) -> void:
	gun_update(delta, damage, combat_spread(dist) + 1.0, "shot_lmg", Color(1.0, 0.75, 0.15))
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
			trigger_strike()
		return
	aiming = false
	_fire_t -= delta
	if _fire_t <= 0.0 and see and dist < SIGHT_RANGE:
		match _phase:
			1:
				_fire_t = FIRE_COOLDOWN_P1
			2:
				_fire_t = FIRE_COOLDOWN_P2
			_:
				_fire_t = FIRE_COOLDOWN_P3
		_aim_t = AIM_TELEGRAPH
		begin_telegraph(AIM_TELEGRAPH, "aim")
