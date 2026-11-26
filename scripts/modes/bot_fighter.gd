# FORGEFALL — Bot fighter (Gameplay Rework, menu + TDM worker).
#
# A player-like bot opponent for Single Player TDM. REUSES the enemy
# chassis (EnemyBase: health / hit reactions / locomotion / soldier
# rig / pooling) with TEAM logic on top — no second combatant system.
# Differences from a wave enemy:
#   - Target: the nearest OPPOSING combatant — the player (team 0) or
#     a bot on the other team — never a teammate, never the core.
#   - Fire: _fire_at() hitscans a GENERIC target (player or bot);
#     EnemyBase.fire_hitscan() is player-only, so bots cannot use it.
#   - Death: die() is overridden to SKIP Game.register_kill() /
#     Progression kill events. A bot killed by a bot is not the
#     player's kill; BotTDM owns all TDM scoring (record_kill) and
#     its own killfeed. Without the override every bot-vs-bot kill
#     would inflate the player's score, streak, and killstreak unlocks.
#   - Attribution: take_damage() records last_attacker (only when the
#     attacker param is non-null — thorns reflections carry none).
#     BotTDM reads it in on_enemy_died() to credit the killer's team.
#   - Respawn: BotTDM re-activates the same pooled body after
#     RESPAWN_DELAY (activate() resets HP/state).
#
# The bot never touches Forge (TDM has no Forge building — ForgeGate
# blocks the pipeline in a live TDM run, and the HUD hides the button).
class_name BotFighter
extends EnemyBase

## Teams: 0 = ALPHA (player + allied bots), 1 = BRAVO (enemy bots).
var team_id := 1
var bot_name := "BOT"
## Owning BotTDM (duck-typed Node: bots list, player_team, note_player_damage).
var tdm: Node = null
var match_active := true
## Last combatant that damaged this bot (null = environment / unknown).
var last_attacker: Node = null

var _target: Node3D = null
var _last_seen := Vector3.ZERO
var _lost_t := 0.0
var _strafe_dir := 1.0
var _strafe_t := 0.0
var _fire_t := 0.0
var _burst_left := 0
var _burst_t := 0.0
var _patrol_pos := Vector3.ZERO
var _has_patrol := false

const LOST_SIGHT_TIMEOUT := 4.0
const MAX_TARGET_DIST := 70.0
const FIRE_RANGE := 40.0
const STRAFE_TIME_MIN := 0.8
const STRAFE_TIME_MAX := 1.8

# --- BB-8: humanised aim + difficulty tiers --------------------------------
# Colin's report: bots were robotic — _fire_at() aimed at the target's
# EXACT current position with spread from DISTANCE ONLY, so a target
# crossing at grapple-fling speed was exactly as hittable as a statue.
# The skill model below fixes that with four human limits:
#   1. TRACKED AIM POINT: the bot aims at an internal point that CHASES
#      the target; the swing is capped at p_track_rate deg/sec, so a
#      fast lateral target out-runs the aim and shots trail behind it.
#   2. SAMPLED PERCEPTION + DEAD RECKONING: the bot only "sees" the
#      target position every p_vel_interval seconds; between samples
#      its aim target advances by its velocity ESTIMATE, which is the
#      measured velocity scaled by (1 +/- p_lead_noise) plus jitter —
#      an imperfect lead, so extreme-speed targets get trailed/missed.
#   3. REACTION TIME: a newly acquired (or re-acquired after >= 0.5 s
#      unseen) target cannot be fired on for p_reaction seconds.
#   4. MOTION ERROR: per-shot gaussian sigma grows with the target's
#      estimated LATERAL speed (p_vel_err deg per m/s) on top of the
#      tier base error and a small distance term.
# The model is OPT-IN per bot (skill_enabled): BotTDM enables it with
# the match tier; any other BotFighter driver (MP bot fill) leaves it
# off and gets the exact legacy aim. Wave enemies never use this class.
const SKILL_TIERS := {
	"rookie": {
		"reaction": 0.55, "track_rate": 30.0, "base_err": 1.05,
		"vel_err": 0.045, "lead_noise": 0.30, "vel_interval": 0.35,
		"burst_size": 3, "burst_pause_min": 1.2, "burst_pause_max": 1.9,
	},
	"regular": {
		"reaction": 0.38, "track_rate": 55.0, "base_err": 0.72,
		"vel_err": 0.030, "lead_noise": 0.20, "vel_interval": 0.25,
		"burst_size": 3, "burst_pause_min": 0.9, "burst_pause_max": 1.5,
	},
	"hardened": {
		"reaction": 0.27, "track_rate": 85.0, "base_err": 0.55,
		"vel_err": 0.022, "lead_noise": 0.12, "vel_interval": 0.18,
		"burst_size": 4, "burst_pause_min": 0.7, "burst_pause_max": 1.2,
	},
	"elite": {
		"reaction": 0.16, "track_rate": 120.0, "base_err": 0.38,
		"vel_err": 0.014, "lead_noise": 0.07, "vel_interval": 0.12,
		"burst_size": 5, "burst_pause_min": 0.55, "burst_pause_max": 0.95,
	},
}
const SKILL_TIER_ORDER: Array[String] = ["rookie", "regular", "hardened", "elite"]
const DEFAULT_TIER := "regular"
## LOS must be gone this long before re-acquisition costs reaction time.
const REACQUIRE_LOST_TIME := 0.5
## Aim error (deg) beyond which the bot gives up tracking, snaps onto
## the target and pays a partial reaction delay again (re-acquire).
const REACQUIRE_SNAP_DEG := 28.0
## Flat per-metre sigma growth past 15 m in the skill model.
const SKILL_DIST_ERR_PER_M := 0.01

## Skill model on/off for THIS bot (BotTDM turns it on at spawn).
var skill_enabled := false
## Tier this bot resolved to (after fallback for unknown ids).
var skill_tier := DEFAULT_TIER
# Resolved tier parameters (per-bot jitter applied by apply_skill_tier).
var p_reaction := 0.38
var p_track_rate := 55.0
var p_base_err := 0.72
var p_vel_err := 0.030
var p_lead_noise := 0.20
var p_vel_interval := 0.25
var p_burst_size := 3
var p_burst_pause_min := 0.9
var p_burst_pause_max := 1.5
## Total shots fired by this bot (telemetry / verifier observable).
var shots_fired := 0

var _rng := RandomNumberGenerator.new()
var _aim_pos := Vector3.ZERO       # tracked aim point (world)
var _aim_valid := false
var _tracked: Node3D = null        # target the aim state belongs to
var _vel_est := Vector3.ZERO       # bot's noisy velocity estimate
var _last_seen_chest := Vector3.ZERO
var _last_sample_pos := Vector3.ZERO
var _sample_age := 0.0
var _has_sample := false
var _force_sample := false
var _react_t := 0.0
var _unseen_t := 0.0


static func skill_tier_ids() -> Array[String]:
	return SKILL_TIER_ORDER.duplicate()


static func is_skill_tier(id: String) -> bool:
	return SKILL_TIERS.has(id)


## Enable the skill model at `p_tier` (unknown ids fall back to
## DEFAULT_TIER). `jitter` (0..~0.3) scales every numeric parameter by
## a per-bot random factor in [1-jitter, 1+jitter] so a squad is not
## four clones; `seed_value` != 0 seeds the bot's private RNG (the
## verifier uses fixed seeds; matches pass a random seed per bot).
func apply_skill_tier(p_tier: String, jitter := 0.0, seed_value := 0) -> void:
	var id := p_tier.to_lower()
	if not SKILL_TIERS.has(id):
		id = DEFAULT_TIER
	skill_tier = id
	skill_enabled = true
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	var t: Dictionary = SKILL_TIERS[id]
	p_reaction = _jittered(float(t["reaction"]), jitter)
	p_track_rate = _jittered(float(t["track_rate"]), jitter)
	p_base_err = _jittered(float(t["base_err"]), jitter)
	p_vel_err = _jittered(float(t["vel_err"]), jitter)
	p_lead_noise = _jittered(float(t["lead_noise"]), jitter)
	p_vel_interval = _jittered(float(t["vel_interval"]), jitter)
	p_burst_size = maxi(1, int(round(_jittered(float(t["burst_size"]), jitter))))
	p_burst_pause_min = _jittered(float(t["burst_pause_min"]), jitter)
	p_burst_pause_max = maxf(p_burst_pause_min,
		_jittered(float(t["burst_pause_max"]), jitter))
	_tracked = null
	_aim_valid = false
	_react_t = 0.0


func _jittered(v: float, jitter: float) -> float:
	if jitter <= 0.0:
		return v
	return v * (1.0 + _rng.randf_range(-jitter, jitter))


func _configure() -> void:
	type_id = "bot"  # VoxelSoldier._palette() default branch (olive kit).
	display_name = bot_name
	creature_type = "humanoid"
	base_hp = 100.0
	base_speed = 4.6
	base_damage = 9.0
	base_accuracy = 0.45
	preferred_range = 14.0
	body_radius = 0.34
	body_height = 1.7


## Identity + owner. Called by BotTDM right after new(), before add_child.
func setup(p_bot_name: String, p_team: int, p_tdm: Node) -> void:
	bot_name = p_bot_name
	display_name = p_bot_name
	team_id = p_team
	tdm = p_tdm


func set_match_active(active: bool) -> void:
	match_active = active
	if not active:
		wish_dir = Vector3.ZERO
		wish_speed = 0.0
		aiming = false
		_target = null
		_tracked = null
		_aim_valid = false


func _on_activated() -> void:
	_target = null
	_lost_t = 0.0
	_strafe_t = 0.0
	_fire_t = randf_range(0.6, 1.4)
	if skill_enabled:
		# Reaction time is the skill model's wind-up; don't stack the
		# legacy random delay on top of it.
		_fire_t = 0.0
	_burst_left = 0
	_burst_t = 0.0
	_has_patrol = false
	aiming = false
	_tracked = null
	_aim_valid = false
	_vel_est = Vector3.ZERO
	_react_t = 0.0
	_unseen_t = 0.0
	_sample_age = 0.0
	_has_sample = false


func _ai_physics(delta: float) -> void:
	if not match_active:
		wish_dir = Vector3.ZERO
		wish_speed = 0.0
		aiming = false
		return
	_target = _pick_target()
	if _target == null or not is_instance_valid(_target):
		if skill_enabled:
			_tracked = null
			_aim_valid = false
		_patrol(delta)
		return
	var tpos: Vector3 = _target.global_position
	var dist := global_position.distance_to(tpos)
	var visible := _has_los(_target)
	if visible:
		_last_seen = tpos
		_lost_t = 0.0
	else:
		_lost_t += delta
	if skill_enabled:
		_skill_track(delta, _target, visible)
	face_target = _aim_pos if (skill_enabled and _aim_valid) else tpos
	if visible and dist <= FIRE_RANGE:
		aiming = true
		_combat_move(tpos, dist, delta)
		_fire_update(delta)
	elif _lost_t < LOST_SIGHT_TIMEOUT:
		# Push to the last known position (or straight at the target
		# when it is merely out of fire range but still seen).
		aiming = false
		var goal := _last_seen if _lost_t > 0.0 else tpos
		wish_dir = nav_direction_to(goal, delta)
		wish_speed = 0.0
		_fire_update(delta)
	else:
		aiming = false
		_patrol(delta)


## Strafe at preferred range, close when too far, back off when too close.
func _combat_move(tpos: Vector3, dist: float, delta: float) -> void:
	_strafe_t -= delta
	if _strafe_t <= 0.0:
		_strafe_t = randf_range(STRAFE_TIME_MIN, STRAFE_TIME_MAX)
		_strafe_dir = -_strafe_dir if randf() < 0.5 else _strafe_dir
	var to: Vector3 = tpos - global_position
	to.y = 0.0
	var dir := to.normalized() if to.length_squared() > 0.001 else Vector3.FORWARD
	var side := Vector3(dir.z, 0.0, -dir.x) * _strafe_dir
	if dist > preferred_range * 1.25:
		wish_dir = (dir * 0.8 + side * 0.35).normalized()
	elif dist < preferred_range * 0.5:
		wish_dir = (-dir * 0.7 + side * 0.4).normalized()
	else:
		wish_dir = side
	wish_speed = 0.0


## Wander to random nearby points while no opposing combatant is known.
func _patrol(delta: float) -> void:
	aiming = false
	if not _has_patrol or global_position.distance_to(_patrol_pos) < 1.5:
		_patrol_pos = global_position + Vector3(randf_range(-14.0, 14.0), 0.0, randf_range(-14.0, 14.0))
		_has_patrol = true
	wish_dir = nav_direction_to(_patrol_pos, delta)
	wish_speed = 0.0
	_fire_update(delta)


## Burst fire: wind-up pause, then 3-round bursts while the target is
## visible and in range. Burst state lives here (not gun_update —
## that helper fires at the player only).
func _fire_update(delta: float) -> void:
	if skill_enabled:
		_fire_update_skill(delta)
		return
	if _burst_left > 0:
		_burst_t -= delta
		if _burst_t <= 0.0:
			_burst_t = 0.13
			_burst_left -= 1
			if _target != null and is_instance_valid(_target):
				_fire_at(_target)
		return
	_fire_t -= delta
	if _fire_t <= 0.0:
		if _target != null and is_instance_valid(_target) \
				and _has_los(_target) \
				and global_position.distance_to(_target.global_position) <= FIRE_RANGE:
			_burst_left = 3
			_burst_t = 0.0
		_fire_t = randf_range(0.9, 1.6)


## Nearest opposing combatant: the player (team 0) or a bot on the
## other team. Teammates are never targeted. No valid target -> null.
func _pick_target() -> Node3D:
	var best: Node3D = null
	var best_d := MAX_TARGET_DIST
	var player_team := 0
	if tdm != null and is_instance_valid(tdm):
		player_team = int(tdm.get("player_team"))
	if team_id != player_team:
		for p in get_tree().get_nodes_in_group("player"):
			if p is Node3D and is_instance_valid(p):
				var d := global_position.distance_to((p as Node3D).global_position)
				if d < best_d:
					best_d = d
					best = p as Node3D
	if tdm != null and is_instance_valid(tdm):
		var bots: Array = tdm.get("bots")
		for b in bots:
			if b == self or not is_instance_valid(b):
				continue
			if not bool(b.get("active")) or bool(b.get("dead")):
				continue
			if int(b.get("team_id")) == team_id:
				continue
			var d := global_position.distance_to((b as Node3D).global_position)
			if d < best_d:
				best_d = d
				best = b as Node3D
	return best


## Line of sight to `target`: raycast eye -> chest. A hit on the
## target itself (or one of its descendants, e.g. the head Area3D)
## means clear; a hit on anything else means blocked; no hit means
## clear (open ground). Bots are on layer 4, so the mask (7) covers
## world (1) + player (2) + enemies (4).
func _has_los(target: Node3D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var from: Vector3 = global_position + Vector3(0, EYE_HEIGHT * body_scale.y, 0)
	var to: Vector3 = target.global_position + Vector3(0, 1.15, 0)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, 7)
	var ex: Array[RID] = [get_rid()]
	query.exclude = ex
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return true
	var col: Object = hit.get("collider")
	if col is Node:
		var n: Node = col as Node
		while n != null:
			if n == target:
				return true
			n = n.get_parent()
		# The player's body is the collider; a bot target hit through
		# a teammate still counts as blocked (the walk above failed).
		return false
	return false


## Hitscan one shot at a generic target. Friendly fire never lands:
## a ray that hits a teammate (or the world) deals no damage. A hit on
## the player is reported to BotTDM for death attribution.
func _fire_at(target: Node3D) -> void:
	if target == null or not is_instance_valid(target):
		return
	shots_fired += 1
	if skill_enabled:
		_fire_at_skill(target)
		return
	var muzzle: Vector3 = global_position + Vector3(0, 1.4 * body_scale.y, 0)
	if rig.has("muzzle") and is_instance_valid(rig["muzzle"]):
		muzzle = (rig["muzzle"] as Node3D).global_position
	var dist := global_position.distance_to(target.global_position)
	var aim_point: Vector3 = target.global_position + Vector3(0, 1.15, 0)
	var dir: Vector3 = (aim_point - muzzle).normalized()
	var sr := deg_to_rad(combat_spread(dist))
	dir = dir.rotated(Vector3.UP, randf_range(-sr, sr))
	var right := dir.cross(Vector3.UP)
	if right.length_squared() > 0.0001:
		dir = dir.rotated(right.normalized(), randf_range(-sr, sr))
	var end: Vector3 = muzzle + dir * 90.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(muzzle, end, 7)
	var ex: Array[RID] = [get_rid()]
	query.exclude = ex
	var hit := space.intersect_ray(query)
	var hit_pos := end
	if not hit.is_empty():
		hit_pos = hit["position"]
		var col: Object = hit.get("collider")
		if col is Node:
			var victim: Node = col as Node
			# Walk up: a head-area hit resolves to its owning body.
			var body: Node = victim
			while body != null and not (body is BotFighter or body.is_in_group("player")):
				body = body.get_parent()
			if body is BotFighter:
				var bf := body as BotFighter
				if bf.team_id != team_id and bf.has_method("take_damage"):
					bf.call("take_damage", damage, hit_pos, false, self)
			elif body != null and body.is_in_group("player"):
				if body.has_method("take_damage"):
					body.call("take_damage", damage, hit_pos, false, self)
				if tdm != null and is_instance_valid(tdm) and tdm.has_method("note_player_damage"):
					tdm.call("note_player_damage", self)
			elif victim == target and victim.has_method("take_damage"):
				# Test doubles / non-combatant targets: direct hit.
				victim.call("take_damage", damage, hit_pos, false, self)
	var col := Color(1.0, 0.48, 0.11) if team_id == 1 else Color(0.3, 0.8, 1.0)
	EnemyTracerPool.spawn(muzzle, hit_pos, col)
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_3d"):
		sfx.call("play_3d", "enemy_shoot", muzzle)


# --- BB-8 skill model -------------------------------------------------------

func _muzzle_pos() -> Vector3:
	if rig.has("muzzle") and is_instance_valid(rig["muzzle"]):
		return (rig["muzzle"] as Node3D).global_position
	return global_position + Vector3(0, 1.4 * body_scale.y, 0)


## First sight of a target (or a target switch): snap the aim onto it,
## start the reaction clock, and take the first perception sample.
func _skill_acquire(target: Node3D) -> void:
	var chest: Vector3 = target.global_position + Vector3(0, 1.15, 0)
	_tracked = target
	_aim_pos = chest
	_aim_valid = true
	_last_seen_chest = chest
	_last_sample_pos = target.global_position
	_vel_est = Vector3.ZERO
	_sample_age = 0.0
	_has_sample = true
	_force_sample = false
	_unseen_t = 0.0
	_react_t = p_reaction * _rng.randf_range(0.85, 1.25)


## Per-tick aim maintenance for the skill model. Runs before
## _fire_update() in _ai_physics, so bursts use the freshest aim.
func _skill_track(delta: float, target: Node3D, visible: bool) -> void:
	if target != _tracked or not _aim_valid:
		_skill_acquire(target)
		return
	var chest_now: Vector3 = target.global_position + Vector3(0, 1.15, 0)
	if not visible:
		_unseen_t += delta
		_sample_age += delta
	else:
		if _unseen_t >= REACQUIRE_LOST_TIME:
			# Re-acquisition after a real loss of sight costs most of
			# the reaction time again, and the velocity estimate is
			# stale — resample immediately.
			_react_t = maxf(_react_t, p_reaction * 0.7 * _rng.randf_range(0.85, 1.25))
			_force_sample = true
		_unseen_t = 0.0
		_sample_age += delta
		if _react_t > 0.0:
			_react_t -= delta
		if _force_sample or _sample_age >= p_vel_interval:
			var dt := maxf(_sample_age, 0.001)
			if _has_sample:
				var measured: Vector3 = (target.global_position - _last_sample_pos) / dt
				_vel_est = measured * (1.0 + _rng.randf_range(-p_lead_noise, p_lead_noise))
				_vel_est += Vector3(_rng.randfn(0.0, 0.2), 0.0, _rng.randfn(0.0, 0.2))
			_last_sample_pos = target.global_position
			_last_seen_chest = chest_now
			_sample_age = 0.0
			_has_sample = true
			_force_sample = false
	# The aim TARGET is the last sampled chest, dead-reckoned forward
	# by the (noisy) velocity estimate — between samples the bot is
	# aiming at where it THINKS the target is going.
	var aim_target: Vector3 = _last_seen_chest + _vel_est * _sample_age
	var muzzle := _muzzle_pos()
	if visible:
		# Hopelessly off (extreme angular speed): snap + re-react.
		var dir_now: Vector3 = _aim_pos - muzzle
		var dir_true: Vector3 = chest_now - muzzle
		if dir_now.length() > 0.01 and dir_true.length() > 0.01 \
				and dir_now.angle_to(dir_true) > deg_to_rad(REACQUIRE_SNAP_DEG):
			_aim_pos = chest_now
			_react_t = maxf(_react_t, p_reaction * 0.6)
			return
	# Rate-capped chase: the aim direction may swing at most
	# p_track_rate deg/sec toward the aim target.
	var to_aim: Vector3 = _aim_pos - muzzle
	var to_tgt: Vector3 = aim_target - muzzle
	if to_aim.length() <= 0.01 or to_tgt.length() <= 0.01:
		_aim_pos = aim_target
		return
	var ang := to_aim.angle_to(to_tgt)
	var max_step := deg_to_rad(p_track_rate) * delta
	if ang <= 0.0001 or max_step >= ang:
		_aim_pos = aim_target
	else:
		var nd := to_aim.normalized().slerp(to_tgt.normalized(), max_step / ang)
		_aim_pos = muzzle + nd * to_tgt.length()


## The target's lateral speed (relative to the line of sight) as the
## bot PERCEIVES it — from its own velocity estimate.
func _est_lateral_speed(target: Node3D) -> float:
	var los: Vector3 = target.global_position - global_position
	los.y = 0.0
	if los.length() <= 0.01:
		return 0.0
	var ln := los.normalized()
	return (_vel_est - ln * _vel_est.dot(ln)).length()


## Skill-model burst fire: same cadence shape as legacy, but a burst
## may only START once the reaction clock has expired, and burst size
## / pause come from the tier.
func _fire_update_skill(delta: float) -> void:
	if _burst_left > 0:
		_burst_t -= delta
		if _burst_t <= 0.0:
			_burst_t = 0.13
			_burst_left -= 1
			if _target != null and is_instance_valid(_target):
				_fire_at(_target)
		return
	_fire_t -= delta
	if _fire_t <= 0.0:
		if _target != null and is_instance_valid(_target) \
				and _react_t <= 0.0 and _aim_valid \
				and _has_los(_target) \
				and global_position.distance_to(_target.global_position) <= FIRE_RANGE:
			_burst_left = p_burst_size
			_burst_t = 0.0
			_fire_t = _rng.randf_range(p_burst_pause_min, p_burst_pause_max)
		else:
			# Not ready (still reacting / no LOS / out of range): retry
			# almost immediately — the burst pause is the gap BETWEEN
			# bursts, not a tax on the first shot after acquisition.
			_fire_t = 0.05


## Skill-model shot: fire from the TRACKED AIM POINT (never the
## target's exact position) with gaussian error = tier base + distance
## + estimated-lateral-speed terms. Hit resolution is identical to the
## legacy _fire_at (same ray, same friendly-fire rules).
func _fire_at_skill(target: Node3D) -> void:
	var muzzle := _muzzle_pos()
	var dist := global_position.distance_to(target.global_position)
	var aim_point: Vector3 = _aim_pos if _aim_valid \
		else target.global_position + Vector3(0, 1.15, 0)
	var sigma := p_base_err \
		+ maxf(0.0, dist - 15.0) * SKILL_DIST_ERR_PER_M \
		+ _est_lateral_speed(target) * p_vel_err
	var dir: Vector3 = (aim_point - muzzle).normalized()
	dir = dir.rotated(Vector3.UP, deg_to_rad(_rng.randfn(0.0, sigma)))
	var right := dir.cross(Vector3.UP)
	if right.length_squared() > 0.0001:
		dir = dir.rotated(right.normalized(), deg_to_rad(_rng.randfn(0.0, sigma)))
	var end: Vector3 = muzzle + dir * 90.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(muzzle, end, 7)
	var ex: Array[RID] = [get_rid()]
	query.exclude = ex
	var hit := space.intersect_ray(query)
	var hit_pos := end
	if not hit.is_empty():
		hit_pos = hit["position"]
		var col_obj: Object = hit.get("collider")
		if col_obj is Node:
			var victim: Node = col_obj as Node
			var body: Node = victim
			while body != null and not (body is BotFighter or body.is_in_group("player")):
				body = body.get_parent()
			if body is BotFighter:
				var bf := body as BotFighter
				if bf.team_id != team_id and bf.has_method("take_damage"):
					bf.call("take_damage", damage, hit_pos, false, self)
			elif body != null and body.is_in_group("player"):
				if body.has_method("take_damage"):
					body.call("take_damage", damage, hit_pos, false, self)
				if tdm != null and is_instance_valid(tdm) and tdm.has_method("note_player_damage"):
					tdm.call("note_player_damage", self)
			elif victim == target and victim.has_method("take_damage"):
				victim.call("take_damage", damage, hit_pos, false, self)
	var col := Color(1.0, 0.48, 0.11) if team_id == 1 else Color(0.3, 0.8, 1.0)
	EnemyTracerPool.spawn(muzzle, hit_pos, col)
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_3d"):
		sfx.call("play_3d", "enemy_shoot", muzzle)


func take_damage(amount: float, hit_position: Vector3, is_headshot: bool, attacker: Node = null) -> void:
	# Attribution BEFORE super: take_damage() may kill this bot (die()
	# reads last_attacker via BotTDM). Reflections carry no attacker
	# (null) and must not overwrite a real shooter.
	if attacker != null:
		last_attacker = attacker
	super.take_damage(amount, hit_position, is_headshot, attacker)


## EnemyBase.die() MINUS Game.register_kill() / Progression kill events
## (see header: bot kills are BotTDM's score, not the player's).
## Death visuals / tween / manager callback are identical to the base.
func die() -> void:
	if dead:
		return
	dead = true
	collision_layer = 0
	collision_mask = 0
	aiming = false
	wish_dir = Vector3.ZERO
	if ClassDB.class_exists("DebrisPool"):
		var torso_pos: Vector3 = global_position + Vector3(0, 1.2 * body_scale.y, 0)
		DebrisPool.burst(torso_pos, _debris_colors(), 14, 4.5)
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_3d"):
		sfx.call("play_3d", "enemy_death", global_position, -4.0)
	_death_tween = create_tween()
	_death_tween.tween_property(soldier, "rotation:x", -PI * 0.48, DEATH_TIP_TIME)
	var mgr := get_parent()
	if mgr != null and mgr.has_method("on_enemy_died"):
		mgr.call("on_enemy_died", self)
