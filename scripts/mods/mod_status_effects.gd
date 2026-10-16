# FORGEFALL — ModStatusEffects (v0.5.5: status effects for invented hooks)
# The hook effect catalog (ModHook) used to have NO status effects —
# heal / explosion / smoke / announce / damage_mult only. A "Bubble
# Blaster" that slows enemies could not express "slow" anywhere except
# in prose, so the LLM emitted smoke + announce and the blaster
# literally could not slow anything. This file is the game-side half
# of the fix: real, timed status effects that the hook registry applies
# and that locomotion actually obeys.
#
# KINDS (all validated in ModHook.validate_effect):
#   slow      {factor 0.05-1.0, duration_sec 0.5-30} — multiplies the
#             target's movement speed. factor 0.5 = half speed.
#   freeze    {duration_sec 0.5-10} — speed multiplier 0 (same
#             machinery as slow, reported distinctly).
#   burn      {damage_per_sec 1-500, duration_sec 0.5-30} — damage
#             over time, applied in 1.0s ticks so it cannot flinch-lock.
#   knockback {force 1-30} — instant impulse away from `origin`.
#
# STORAGE: effects live in the target's metadata ("mod_status_effects")
# as an Array of {kind, factor, damage_per_sec, remaining}. A tiny
# StatusTicker Node (child of the target) drives expiry + burn ticks
# in _process and frees itself when the list empties. Expiry is
# frame-based (remaining -= delta), so tests can drive it deterministically
# and no wall clock is involved. A freed target frees its ticker with it.
#
# CONSUMERS: EnemyBase._apply_locomotion and Player ground movement
# multiply their speed by ModStatusEffects.speed_multiplier(self) —
# one line each, the choke points where wish speed becomes velocity.
# Mods override: a mod slow/freeze/knockback applies to ANY
# CharacterBody3D, including the brute (whose own damage path is
# immune to flinch/knockback — a mod is an explicit player-built
# exception to that). Burn kills do NOT run on_kill hooks (those run
# only in the projectile / hitscan hit paths).
extends RefCounted
class_name ModStatusEffects

const META_KEY := "mod_status_effects"
const BURN_TICK_SEC := 1.0


## Ticker node: one per affected target, child of the target.
class StatusTicker extends Node:
	func _process(delta: float) -> void:
		var p := get_parent()
		if p == null or not is_instance_valid(p):
			queue_free()
			return
		ModStatusEffects.tick_target(p as Node, delta)


## Applies ONE status effect to `target`. `origin` is the hit point
## (knockback direction is away from it). Returns false when nothing
## was applied (null / freed / out-of-tree target, unknown kind).
static func apply_status(target: Node, kind: String, params: Dictionary, origin: Vector3) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not target.is_inside_tree():
		return false
	match kind:
		"slow":
			var factor := clampf(float(params.get("factor", 1.0)), 0.05, 1.0)
			var dur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_upsert(target, {"kind": "slow", "factor": factor, "remaining": dur})
			return true
		"freeze":
			var dur_f := clampf(float(params.get("duration_sec", 0.0)), 0.5, 10.0)
			_upsert(target, {"kind": "freeze", "factor": 0.0, "remaining": dur_f})
			return true
		"burn":
			var dps := clampf(float(params.get("damage_per_sec", 0.0)), 1.0, 500.0)
			var dur_b := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_upsert(target, {"kind": "burn", "damage_per_sec": dps, "remaining": dur_b})
			return true
		"knockback":
			if not (target is CharacterBody3D):
				return false
			var force := clampf(float(params.get("force", 0.0)), 1.0, 30.0)
			var dir := (target as Node3D).global_position - origin
			dir.y = 0.0
			if dir.length_squared() < 0.001:
				dir = Vector3(0, 0, 1)
			var body := target as CharacterBody3D
			body.velocity += dir.normalized() * force + Vector3.UP * force * 0.25
			return true
	return false


## Movement-speed multiplier from the target's active effects (1.0 =
## unaffected). Freeze forces 0. Multiple slows multiply.
static func speed_multiplier(target: Node) -> float:
	if target == null or not is_instance_valid(target):
		return 1.0
	if not target.has_meta(META_KEY):
		return 1.0
	var mult := 1.0
	for eff in (target.get_meta(META_KEY) as Array):
		if not (eff is Dictionary):
			continue
		var d := eff as Dictionary
		if float(d.get("remaining", 0.0)) <= 0.0:
			continue
		if str(d.get("kind", "")) in ["slow", "freeze"]:
			mult *= float(d.get("factor", 1.0))
	return clampf(mult, 0.0, 1.0)


## Active effects on the target (duplicated). [] when none.
static func active_effects(target: Node) -> Array:
	if target == null or not is_instance_valid(target):
		return []
	if not target.has_meta(META_KEY):
		return []
	return (target.get_meta(META_KEY) as Array).duplicate(true)


## Advances one target's effects by `delta` (called by its ticker).
## Burn ticks in BURN_TICK_SEC chunks of damage, plus a final partial
## tick when the last burn expires — a 2.5s burn at 10 dps deals
## exactly 25 damage, not 20 or 30. Expired effects are dropped; an
## emptied list removes the ticker + metadata.
static func tick_target(target: Node, delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if not target.has_meta(META_KEY):
		return
	var effects := target.get_meta(META_KEY) as Array
	# Burn active this tick: the strongest burn's remaining governs.
	var burn_dps := 0.0
	var burn_remaining := 0.0
	for eff in effects:
		if not (eff is Dictionary):
			continue
		var d := eff as Dictionary
		if str(d.get("kind", "")) == "burn" and float(d.get("remaining", 0.0)) > 0.0:
			if float(d.get("damage_per_sec", 0.0)) >= burn_dps:
				burn_dps = float(d.get("damage_per_sec", 0.0))
				burn_remaining = float(d.get("remaining", 0.0))
	var kept: Array = []
	if burn_dps > 0.0:
		var active := minf(delta, burn_remaining)
		var accum := float(target.get_meta("_mod_burn_accum", 0.0)) + active
		while accum >= BURN_TICK_SEC:
			accum -= BURN_TICK_SEC
			if target.has_method("take_damage") and not _is_dead(target):
				var pos := Vector3.ZERO
				if target is Node3D:
					pos = (target as Node3D).global_position
				target.call("take_damage", burn_dps * BURN_TICK_SEC, pos, false)
		target.set_meta("_mod_burn_accum", accum)
	for eff in effects:
		if not (eff is Dictionary):
			continue
		var d := (eff as Dictionary).duplicate(true)
		d["remaining"] = float(d.get("remaining", 0.0)) - delta
		if float(d.get("remaining", 0.0)) <= 0.0:
			continue
		kept.append(d)
	var burn_alive := false
	for eff in kept:
		if str((eff as Dictionary).get("kind", "")) == "burn":
			burn_alive = true
			break
	if not burn_alive and burn_dps > 0.0:
		# Last burn expired: flush the leftover partial tick.
		var rest := float(target.get_meta("_mod_burn_accum", 0.0))
		if rest > 0.0 and target.has_method("take_damage") and not _is_dead(target):
			var pos2 := Vector3.ZERO
			if target is Node3D:
				pos2 = (target as Node3D).global_position
			target.call("take_damage", burn_dps * rest, pos2, false)
		target.set_meta("_mod_burn_accum", 0.0)
	if _is_dead(target):
		kept = []
	if kept.is_empty():
		target.remove_meta(META_KEY)
		if target.has_meta("_mod_burn_accum"):
			target.remove_meta("_mod_burn_accum")
		var ticker := target.get_node_or_null("ModStatusTicker")
		if ticker != null:
			ticker.queue_free()
	else:
		target.set_meta(META_KEY, kept)


## Inserts or refreshes an effect: same-kind re-application keeps the
## strongest value and refreshes to the longest duration.
static func _upsert(target: Node, eff: Dictionary) -> void:
	var effects: Array = []
	if target.has_meta(META_KEY):
		effects = target.get_meta(META_KEY) as Array
	var merged := false
	for i in range(effects.size()):
		var d := effects[i] as Dictionary
		if str(d.get("kind", "")) != str(eff.get("kind", "")):
			continue
		merged = true
		match str(eff.get("kind", "")):
			"slow", "freeze":
				d["factor"] = minf(float(d.get("factor", 1.0)), float(eff.get("factor", 1.0)))
			"burn":
				d["damage_per_sec"] = maxf(float(d.get("damage_per_sec", 0.0)), float(eff.get("damage_per_sec", 0.0)))
		d["remaining"] = maxf(float(d.get("remaining", 0.0)), float(eff.get("remaining", 0.0)))
		effects[i] = d
		break
	if not merged:
		effects.append(eff)
	target.set_meta(META_KEY, effects)
	_ensure_ticker(target)


static func _ensure_ticker(target: Node) -> void:
	if target.get_node_or_null("ModStatusTicker") != null:
		return
	var t := StatusTicker.new()
	t.name = "ModStatusTicker"
	target.add_child(t)


static func _is_dead(target: Node) -> bool:
	if target.has_method("is_dead"):
		return bool(target.call("is_dead"))
	var dead_v: Variant = target.get("dead")
	if dead_v is bool:
		return dead_v
	var hp_v: Variant = target.get("hp")
	if hp_v is int or hp_v is float:
		return float(hp_v) <= 0.0
	return false
