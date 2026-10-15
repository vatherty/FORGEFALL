# FORGEFALL — scripts/enemies/shredder.gd
# Goal 3 CONTENT (Worker B — Enemies).
#
# SHREDDER — fast melee shredder. No gun: twin voxel blades, the fastest
# enemy on foot (8.2 m/s — still slower than the player's 11 m/s sprint,
# so it is always kiteable), paper HP (50). Charges the player, winds up a
# 0.45s telegraphed slash at <= 2.4m, then needs 0.9s to recover.
# A slash lands 18 damage in a 2.8m frontal arc — dodgeable by sprinting
# past, jumping back, or killing it mid-windup (flinch cancels the slash).
# Role: punishes standing still / ADS-camping; forces movement.

class_name Shredder
extends EnemyBase

enum State { SPAWN, CHARGE, WINDUP, RECOVER }

const MELEE_TRIGGER := 2.4   # start windup at or inside this range
const MELEE_HIT_RANGE := 2.8 # slash connects at or inside this range
const MELEE_FRONT_DOT := 0.3 # player must be in the frontal cone
const MELEE_DAMAGE := 18.0   # never a one-tap: 100 HP player survives 5 slashes
const WINDUP_TIME := 0.45    # readable telegraph before the slash
const RECOVER_TIME := 0.9    # breathing room after every slash (hit or miss)
const LOST_SIGHT_TIMEOUT := 3.0

var state: int = State.SPAWN
var _t := 0.0
var _zig_phase := 0.0
var _lost_t := 0.0


func _configure() -> void:
	type_id = "shredder"
	display_name = "Shredder"
	base_hp = 50.0       # glass: one clean burst kills it
	base_speed = 8.2     # fastest enemy — but player sprint (11.0) still wins
	base_damage = MELEE_DAMAGE
	base_accuracy = 0.0  # melee: accuracy unused
	preferred_range = 2.0
	body_radius = 0.32
	body_height = 1.65
	body_scale = Vector3(0.92, 1.0, 0.92)  # slim silhouette


func _debris_colors() -> Array:
	return [Color(0.35, 0.08, 0.08), Color(0.14, 0.15, 0.16), Color(1.0, 0.2, 0.6)]


func _on_activated() -> void:
	state = State.SPAWN
	_t = 0.0
	_zig_phase = randf() * TAU
	_lost_t = 0.0
	aiming = false


func _ai_physics(delta: float) -> void:
	if is_flinching():
		# A hit mid-windup cancels the slash — shooting it saves you.
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

	match state:
		State.SPAWN:
			_t += delta
			wish_dir = Vector3.ZERO
			if see:
				face_target = pp
			if _t > 0.5:  # telegraph (0.5s) + short settle
				_set_state(State.CHARGE)

		State.CHARGE:
			aiming = false
			face_target = pp
			# Slight weave so it is not a straight-line target on approach.
			var dir := nav_direction_to(pp, delta)
			_zig_phase += delta * 2.6
			var perp := Vector3(-dir.z, 0, dir.x)
			wish_dir = (dir + perp * sin(_zig_phase) * 0.3).normalized()
			wish_speed = speed
			if see and dist <= MELEE_TRIGGER:
				_set_state(State.WINDUP)
			elif not see and _lost_t > LOST_SIGHT_TIMEOUT:
				# Lost the player: hunt the last known position.
				wish_dir = nav_direction_to(last_seen_pos, delta)
				wish_speed = speed * 0.8
				if see:
					_lost_t = 0.0

		State.WINDUP:
			# Planted, blades raised (aim pose), tracking the player.
			aiming = true
			wish_dir = Vector3.ZERO
			face_target = pp
			_t += delta
			if _t >= WINDUP_TIME:
				_resolve_slash(pp, dist)
				_set_state(State.RECOVER)

		State.RECOVER:
			aiming = false
			face_target = pp
			# Back off a step while recovering — a second slash is never instant.
			var away: Vector3 = global_position - pp
			away.y = 0.0
			wish_dir = away.normalized() * 0.4 if away.length_squared() > 0.01 else Vector3.ZERO
			wish_speed = speed * 0.4
			_t += delta
			if _t >= RECOVER_TIME:
				_set_state(State.CHARGE)


func _resolve_slash(pp: Vector3, dist: float) -> void:
	# Slash connects only if the player is still in range AND in front.
	if dist > MELEE_HIT_RANGE:
		Sfx.play_3d("slide_whoosh", global_position, -2.0)  # whiff
		return
	var to_p: Vector3 = pp - global_position
	to_p.y = 0.0
	var fwd := -global_transform.basis.z
	if to_p.length_squared() < 0.01 or fwd.dot(to_p.normalized()) < MELEE_FRONT_DOT:
		Sfx.play_3d("slide_whoosh", global_position, -2.0)  # dodged behind
		return
	var p := _player_node()
	if p != null and p.has_method("take_damage"):
		p.take_damage(damage * float(director_mods.get("dmg_mult", 1.0)),
			global_position + fwd * 1.5, false)
		Sfx.play_3d("impact_flesh", global_position)


func _set_state(s: int) -> void:
	state = s
	_t = 0.0
	aiming = false
	wish_speed = 0.0
