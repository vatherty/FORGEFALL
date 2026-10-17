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


func _on_activated() -> void:
	_target = null
	_lost_t = 0.0
	_strafe_t = 0.0
	_fire_t = randf_range(0.6, 1.4)
	_burst_left = 0
	_burst_t = 0.0
	_has_patrol = false
	aiming = false


func _ai_physics(delta: float) -> void:
	if not match_active:
		wish_dir = Vector3.ZERO
		wish_speed = 0.0
		aiming = false
		return
	_target = _pick_target()
	if _target == null or not is_instance_valid(_target):
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
	face_target = tpos
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
