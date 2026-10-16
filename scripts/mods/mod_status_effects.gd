# FORGEFALL — ModStatusEffects (v0.5.7: effects expansion, Worker A)
# The hook effect catalog (ModHook) used to have NO status effects —
# heal / explosion / smoke / announce / damage_mult only. A "Bubble
# Blaster" that slows enemies could not express "slow" anywhere except
# in prose, so the LLM emitted smoke + announce and the blaster
# literally could not slow anything. This file is the game-side half
# of the fix: real, timed status effects that the hook registry applies
# and that locomotion actually obeys. v0.5.5 added slow / freeze /
# burn / knockback; v0.5.7 expands the table (see KINDS).
#
# KINDS (all validated in ModHook.validate_effect; all need a target,
# so all are STATUS_KINDS — rejected on fire points):
#   slow      {factor 0.05-1.0, duration_sec 0.5-30} — multiplies the
#             target's movement speed. factor 0.5 = half speed.
#   freeze    {duration_sec 0.5-10} — speed 0 AND horizontal velocity
#             zeroed every tick (encased: knockback cannot move it).
#   burn      {damage_per_sec 1-500, duration_sec 0.5-30} — damage
#             over time, applied in 1.0s ticks so it cannot flinch-lock.
#   knockback {force 1-30} — instant impulse away from `origin`.
#   pull      {force 1-30} — instant impulse TOWARD `origin`
#             (the pull/vortex script pattern, now a table kind).
#   poison    {damage_per_sec 1-500, duration_sec 0.5-30} — DOT with
#             its own accumulator (0.5s-flavoured ticks via the same
#             1s-chunk accounting) PLUS a mild slow (x0.85) while
#             active. Distinct from burn: burn is pure DOT, poison is
#             DOT + slow.
#   bleed     {damage_per_sec 1-500, duration_sec 0.5-30} — DOT whose
#             tick rate scales with the target's horizontal speed
#             (standing still = base rate; sprinting ≈ x2.6). Distinct
#             from burn/poison: movement makes it worse.
#   regen     {heal_per_sec 1-500, duration_sec 0.5-30} — heal over
#             time (heal() when present, else hp clamped to max_hp).
#   haste     {factor 1.05-2.5, duration_sec 0.5-30} — speed
#             multiplier above 1. Movement speed ONLY: no fire-rate
#             hook exists in the weapon code, so haste does not touch
#             fire rate (documented, not silently claimed).
#   restrained {duration_sec 0.5-10} — speed 0, can still act, CAN
#             still be shoved (velocity untouched). Distinct from
#             freeze (velocity zeroed) and prone (knockdown impulse).
#   prone     {force 1-30, duration_sec 0.5-10} — knockdown impulse
#             (away + down) + speed 0 for the duration, then the
#             target stands back up (speed restores on expiry).
#   sleep     {duration_sec 0.5-30} — speed 0 + velocity zeroed +
#             WAKES EARLY the moment the target takes damage (HP drop
#             polled each tick). Distinct from freeze: damage wakes
#             sleep, never freeze.
#   confusion {force 1-10, duration_sec 0.5-30} — random stumble
#             impulses every 0.5s (erratic movement). Distinct from
#             knockback: repeated, random direction, no single shove.
#   blind     {factor 0.05-1.0, duration_sec 0.5-30} — accuracy
#             disruption: enemies get their `accuracy` stat scaled by
#             factor (their spread widens); the player gets equipped
#             weapons' spread_hip/spread_move scaled by 1/factor.
#             Original values are captured + restored on expiry.
#             (Rusher's fixed pellet spread ignores accuracy — an
#             engine quirk, blind still lands on its accuracy stat.)
#   weaken    {factor 0.05-1.0, duration_sec 0.5-30} — damage dealt
#             reduced: enemies get their `damage` stat scaled by
#             factor; the player gets equipped weapons' `damage`
#             scaled by factor. Captured + restored on expiry.
#             (Warlord's slam uses a const, not `damage` — unaffected.)
#   exhaustion {duration_sec 0.5-60} — stacking: each application
#             adds ONE level (max 6). Speed x(1 - 0.15*level), floor
#             x0.10. Level 6 = death (lethal damage). Distinct from
#             slow: it stacks, and it can kill.
#   typed_damage {damage_type, amount 1-500, duration_sec 0.5-30} —
#             instant damage of one D&D damage type + a rider that
#             makes the type mechanically distinct (there is NO
#             resistance/vulnerability hook in take_damage, so the
#             rider + the report carry the distinction — documented,
#             not silently claimed):
#               fire     -> burn rider (dps = amount*0.25)
#               cold     -> slow rider (x0.6)
#               lightning-> knockback rider (force 6)
#               thunder  -> knockback (force 12) + prone (<=2s)
#               acid     -> weaken rider (x0.7, armour melt)
#               necrotic -> +1 exhaustion level (drain)
#               poison   -> poison rider (dps = amount*0.2)
#               psychic  -> confusion rider (force 4)
#               radiant  -> blind rider (x0.5, searing flash)
#   shield    {amount 1-500, duration_sec 0.5-30} — an absorbing
#             pool: incoming damage eats the pool first. Re-applying
#             ADDS to the remaining pool (shields stack) and refreshes
#             to the longest duration. Read via get_shield_remaining().
#   vulnerable {factor 1.05-5.0, duration_sec 0.5-30} — incoming
#             damage is multiplied by factor while active. Re-applying
#             keeps the STRONGEST factor, longest duration.
#   thorns    {reflect_mult 0.0-2.0, duration_sec 0.5-30} — reflects
#             reflect_mult x the damage ACTUALLY taken (after shield /
#             vulnerable / petrified) back to the attacker. Reflected
#             damage is real damage on the attacker (it passes through
#             the attacker's own defensive states, but never reflects
#             again). No reflection for internal damage (DOT ticks,
#             typed_damage, exhaustion) — there is no attacker.
#   petrified {duration_sec 0.5-30} — the target is stone: ALL
#             incoming damage nullified, speed 0, velocity zeroed
#             every tick (like freeze). Damage does NOT break it (unlike
#             sleep). Constructs + elementals are immune (5e:
#             condition_immunities include "petrified" for both —
#             enforced here because DnDTypes.STATUS_CONDITION_MAP has
#             no petrified row; see apply_status).
#
# DELIBERATE OMISSIONS (v0.5.7 — no lookalikes, no prose-only kinds):
#   stunned / paralyzed / unconscious / incapacitated — "can't act"
#     needs an act-blocking hook in enemy AI fire + weapon fire;
#     neither consults this file, so a "stunned" kind would be
#     freeze renamed. Sleep covers timed incapacitation WITH a real
#     wake rule; freeze covers timed immobility.
#   grappled — speed 0 + can act + can be shoved = restrained
#     exactly; a second name would be a lookalike.
#   frightened — "can't move closer / flees" needs a steering hook
#     in enemy AI; the ticker cannot steer.
#   charmed — no faction / AI-targeting hook; enemies would still
#     attack the player.
#   deafened — no hearing system (perception is distance-only).
#   silence — no ability-gating hook (grapple / portal /
#     killstreaks never consult this file).
#   lifesteal — timed version needs a damage-dealt hook (none);
#     instant version is heal renamed.
#   curse — no single mechanic; specific curses ARE specific kinds.
#
# v0.5.9 — NO LONGER OMITTED (take_damage interception exists now):
#   shield / vulnerable / thorns / petrified — see KINDS below and
#   resolve_incoming_damage(). They are REAL: Player.take_damage and
#   EnemyBase.take_damage call resolve_incoming_damage() BEFORE damage
#   lands, and take_damage hooks run before that (they may apply these
#   states to the target, or return damage_mult, for THIS hit).
#
# TAKE_DAMAGE INTERCEPTION (v0.5.9):
#   resolve_incoming_damage(target, amount, attacker) is THE choke
#   point. Callers (Player / EnemyBase take_damage) pass the
#   hook-adjusted amount; resolve applies the target's active
#   defensive states in this order:
#     1. petrified -> ALL damage nullified (final 0, no thorns).
#     2. vulnerable -> amount *= factor.
#     3. shield -> pool absorbs min(pool, amount); pool drains.
#     4. thorns -> reflects reflect_mult x the damage ACTUALLY taken
#        (post-absorption) back to the attacker. The caller performs
#        the reflection (attacker.take_damage) wrapped in
#        begin_reflection()/end_reflection(), so a reflected hit can
#        never ping-pong through two thorns carriers.
#   Attacker resolution: an explicit attacker wins. When the caller
#   has no attacker handle (explosions, grenades, slams), resolve
#   falls back to the player for enemy targets (single-player: all
#   player-side damage originates from the player) and to the nearest
#   live enemy for player targets. Internal damage (DOT ticks,
#   typed_damage, exhaustion-6) never reflects: _damage_target /
#   _damage_typed run inside begin_dot_damage()/end_dot_damage().
#
# STORAGE: effects live in the target's metadata ("mod_status_effects")
# as an Array of {kind, factor, damage_per_sec, heal_per_sec, force,
# damage_type, amount, level, remaining, accum, ...}. A tiny
# StatusTicker Node (child of the target) drives expiry + DOT/HOT
# ticks + stumble + sleep-wake checks in _process and frees itself
# when the list empties. Expiry is frame-based (remaining -= delta),
# so tests can drive it deterministically and no wall clock is
# involved. A freed target frees its ticker with it.
#
# CONSUMERS: EnemyBase._apply_locomotion and Player ground movement
# multiply their speed by ModStatusEffects.speed_multiplier(self) —
# one line each, the choke points where wish speed becomes velocity.
# Blind / weaken act EAGERLY: they scale the target's accuracy /
# damage stats (or the player's weapon stats) on apply and restore
# them on expiry/clear/death — no consumer change needed. Mods
# override: a mod slow/freeze/knockback applies to ANY
# CharacterBody3D, including the brute (whose own damage path is
# immune to flinch/knockback — a mod is an explicit player-built
# exception to that). DOT kills do NOT run on_kill hooks (those run
# only in the projectile / hitscan hit paths).
extends RefCounted
class_name ModStatusEffects

const META_KEY := "mod_status_effects"
const BURN_TICK_SEC := 1.0
## Poison's mild slow while active.
const POISON_SLOW_FACTOR := 0.85
## Bleed tick-rate bonus per m/s of horizontal speed.
const BLEED_MOVE_SCALE := 0.15
## Exhaustion speed penalty per level; floor multiplier.
const EXHAUSTION_PER_LEVEL := 0.15
const EXHAUSTION_FLOOR := 0.10
const EXHAUSTION_MAX_LEVEL := 6
## Confusion stumble cadence.
const CONFUSION_STUMBLE_SEC := 0.5
## D&D damage types expressible as typed_damage (rider table in
## apply_status). No other damage type is a real kind.
const TYPED_DAMAGE_TYPES := ["acid", "cold", "fire", "lightning", "necrotic", "poison", "psychic", "radiant", "thunder"]

## Reentrancy guards for the take_damage interception (v0.5.9).
## GDScript is single-threaded and all damage calls are synchronous,
## so depth counters are exact: _dot_damage_depth > 0 while internal
## damage (_damage_target / _damage_typed: DOT ticks, typed_damage,
## exhaustion-6) is being delivered — thorns never reflects those.
## _reflection_depth > 0 while a thorns reflection is being delivered
## — the reflected hit passes through the attacker's defensive states
## but never reflects again (no ping-pong).
static var _dot_damage_depth := 0
static var _reflection_depth := 0


## Marks the start of internal (attacker-less) damage delivery.
## Paired with end_dot_damage(); callers use try/finally discipline
## (GDScript has no try/finally — the increment/decrement bracket a
## single synchronous take_damage call, so they cannot leak).
static func begin_dot_damage() -> void:
	_dot_damage_depth += 1


static func end_dot_damage() -> void:
	_dot_damage_depth = maxi(0, _dot_damage_depth - 1)


## Marks the start of a thorns reflection delivery. Paired with
## end_reflection().
static func begin_reflection() -> void:
	_reflection_depth += 1


static func end_reflection() -> void:
	_reflection_depth = maxi(0, _reflection_depth - 1)


## Ticker node: one per affected target, child of the target.
class StatusTicker extends Node:
	func _process(delta: float) -> void:
		var p := get_parent()
		if p == null or not is_instance_valid(p):
			queue_free()
			return
		ModStatusEffects.tick_target(p as Node, delta)


## Applies ONE status effect to `target`. `origin` is the hit point
## (knockback direction is away from it, pull toward it). Returns false
## when nothing was applied (null / freed / out-of-tree target,
## unknown kind, or the kind has no handle on this target — e.g.
## blind on a target with no accuracy stat and no weapons).
static func apply_status(target: Node, kind: String, params: Dictionary, origin: Vector3) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not target.is_inside_tree():
		return false
	# v0.5.8 D&D: refuse kinds the target's creature type is immune to
	# (e.g. poison on a construct/undead, sleep on an elemental) BEFORE
	# any effect is upserted — so exhaustion level-6 death can never
	# fire through this path on an immune target.
	var ctype_v: Variant = target.get("creature_type")
	if ctype_v is String and DnDTypes.is_status_immune(str(ctype_v), kind):
		return false
	# v0.5.9 petrified: 5e construct + elemental condition_immunities
	# include "petrified" (DnDTypes.CREATURE_TYPES), but
	# DnDTypes.STATUS_CONDITION_MAP has no petrified row, so
	# is_status_immune() above cannot see it. Enforced here against
	# the table, not invented: a construct/elemental can never be
	# petrified, via any path that calls apply_status.
	if kind == "petrified" and ctype_v is String and str(ctype_v) in ["construct", "elemental"]:
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
			_upsert(target, {"kind": "burn", "damage_per_sec": dps, "remaining": dur_b, "accum": 0.0})
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
		"pull":
			if not (target is CharacterBody3D):
				return false
			var pforce := clampf(float(params.get("force", 0.0)), 1.0, 30.0)
			var pdir := origin - (target as Node3D).global_position
			pdir.y = 0.0
			if pdir.length_squared() < 0.001:
				pdir = Vector3(0, 0, -1)
			var pbody := target as CharacterBody3D
			pbody.velocity += pdir.normalized() * pforce + Vector3.UP * pforce * 0.1
			return true
		"poison":
			var pdps := clampf(float(params.get("damage_per_sec", 0.0)), 1.0, 500.0)
			var pdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_upsert(target, {"kind": "poison", "damage_per_sec": pdps, "remaining": pdur, "accum": 0.0})
			return true
		"bleed":
			var bdps := clampf(float(params.get("damage_per_sec", 0.0)), 1.0, 500.0)
			var bdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			var last := Vector3.ZERO
			if target is Node3D:
				last = (target as Node3D).global_position
			_upsert(target, {"kind": "bleed", "damage_per_sec": bdps, "remaining": bdur, "accum": 0.0, "last_pos": last})
			return true
		"regen":
			var hps := clampf(float(params.get("heal_per_sec", 0.0)), 1.0, 500.0)
			var rdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			if not _can_heal(target):
				return false
			_upsert(target, {"kind": "regen", "heal_per_sec": hps, "remaining": rdur, "accum": 0.0})
			return true
		"haste":
			var hfactor := clampf(float(params.get("factor", 1.0)), 1.05, 2.5)
			var hdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_upsert(target, {"kind": "haste", "factor": hfactor, "remaining": hdur})
			return true
		"restrained":
			var redur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 10.0)
			_upsert(target, {"kind": "restrained", "factor": 0.0, "remaining": redur})
			return true
		"prone":
			if not (target is CharacterBody3D):
				return false
			var prforce := clampf(float(params.get("force", 0.0)), 1.0, 30.0)
			var prdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 10.0)
			var prdir := (target as Node3D).global_position - origin
			prdir.y = 0.0
			if prdir.length_squared() < 0.001:
				prdir = Vector3(0, 0, 1)
			var prbody := target as CharacterBody3D
			prbody.velocity += prdir.normalized() * prforce * 0.5 + Vector3(0, -1, 0) * prforce * 0.5
			_upsert(target, {"kind": "prone", "factor": 0.0, "remaining": prdur})
			return true
		"sleep":
			var sdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			var hp_now := -1.0
			var hp_v: Variant = target.get("hp")
			if hp_v is int or hp_v is float:
				hp_now = float(hp_v)
			_upsert(target, {"kind": "sleep", "factor": 0.0, "remaining": sdur, "hp_at_apply": hp_now})
			return true
		"confusion":
			if not (target is CharacterBody3D):
				return false
			var cforce := clampf(float(params.get("force", 0.0)), 1.0, 10.0)
			var cdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_upsert(target, {"kind": "confusion", "force": cforce, "remaining": cdur, "stumble_timer": 0.0})
			return true
		"blind":
			var bfactor := clampf(float(params.get("factor", 1.0)), 0.05, 1.0)
			var bdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			return _apply_stat_scale(target, "blind", bfactor, bdur)
		"weaken":
			var wfactor := clampf(float(params.get("factor", 1.0)), 0.05, 1.0)
			var wdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			return _apply_stat_scale(target, "weaken", wfactor, wdur)
		"exhaustion":
			var edur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 60.0)
			var level := 1
			var existing := _find_effect(target, "exhaustion")
			if not existing.is_empty():
				level = mini(int(existing.get("level", 1)) + 1, EXHAUSTION_MAX_LEVEL)
			_upsert(target, {"kind": "exhaustion", "level": level, "remaining": edur})
			if level >= EXHAUSTION_MAX_LEVEL:
				# Level 6 = death (D&D). Lethal damage through the
				# normal path, so death handling stays consistent.
				_damage_target(target, 99999.0)
			return true
		"typed_damage":
			var dtype := str(params.get("damage_type", ""))
			if dtype not in TYPED_DAMAGE_TYPES:
				return false
			var amount := clampf(float(params.get("amount", 0.0)), 1.0, 500.0)
			var tdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_damage_typed(target, amount, dtype)
			if _is_dead(target):
				return true
			_apply_typed_rider(target, dtype, amount, tdur, origin)
			return true
		"shield":
			var pool := clampf(float(params.get("amount", 0.0)), 1.0, 500.0)
			var shdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			# Shields STACK: re-applying adds to the remaining pool
			# (the generic _upsert keeps max, which would LOSE pool).
			var existing_sh := _find_effect(target, "shield")
			if not existing_sh.is_empty():
				existing_sh["amount"] = float(existing_sh.get("amount", 0.0)) + pool
				existing_sh["remaining"] = maxf(float(existing_sh.get("remaining", 0.0)), shdur)
				_ensure_ticker(target)
				return true
			_upsert(target, {"kind": "shield", "amount": pool, "remaining": shdur})
			return true
		"vulnerable":
			var vfactor := clampf(float(params.get("factor", 1.0)), 1.05, 5.0)
			var vdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_upsert(target, {"kind": "vulnerable", "factor": vfactor, "remaining": vdur})
			return true
		"thorns":
			var rmult := clampf(float(params.get("reflect_mult", 0.0)), 0.0, 2.0)
			var thdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_upsert(target, {"kind": "thorns", "reflect_mult": rmult, "remaining": thdur})
			return true
		"petrified":
			var pdur := clampf(float(params.get("duration_sec", 0.0)), 0.5, 30.0)
			_upsert(target, {"kind": "petrified", "factor": 0.0, "remaining": pdur})
			return true
	return false


## Resolves ONE incoming hit against the target's active defensive
## states (v0.5.9 take_damage interception). Called by
## Player.take_damage / EnemyBase.take_damage with the HOOK-ADJUSTED
## amount (take_damage hooks already ran) and the attacker when known
## (null when the damage source has no handle). Returns:
##   {"final_damage": float (what actually lands on HP),
##    "absorbed": float (eaten by shield),
##    "reflected": float (thorns damage for the attacker, 0 when none),
##    "reflected_target": Node-or-null (the attacker to reflect to),
##    "nullified": bool (petrified ate everything),
##    "vulnerable_mult": float (the vulnerable factor applied, 1.0 none)}
## SIDE EFFECT: a shield pool is DRAINED by what it absorbs (an
## emptied pool removes the shield effect). Call EXACTLY once per hit.
## Order: petrified nullifies -> vulnerable multiplies -> shield
## absorbs -> thorns reflects a share of what was ACTUALLY taken.
## Thorns never fires for internal damage (DOT/typed/exhaustion —
## _dot_damage_depth > 0) or for a hit that is itself a reflection
## (_reflection_depth > 0). A nullified hit reflects nothing.
static func resolve_incoming_damage(target: Node, amount: float, attacker: Node = null) -> Dictionary:
	var out := {"final_damage": maxf(amount, 0.0), "absorbed": 0.0,
		"reflected": 0.0, "reflected_target": null,
		"nullified": false, "vulnerable_mult": 1.0}
	if target == null or not is_instance_valid(target):
		return out
	if amount <= 0.0:
		out["final_damage"] = 0.0
		return out
	var petr := _find_effect(target, "petrified")
	if not petr.is_empty() and float(petr.get("remaining", 0.0)) > 0.0:
		out["final_damage"] = 0.0
		out["nullified"] = true
		out["vulnerable_mult"] = 0.0
		return out
	var scaled := amount
	var vuln := _find_effect(target, "vulnerable")
	if not vuln.is_empty() and float(vuln.get("remaining", 0.0)) > 0.0:
		var factor := float(vuln.get("factor", 1.0))
		scaled = amount * factor
		out["vulnerable_mult"] = factor
	var absorbed := 0.0
	var shield := _find_effect(target, "shield")
	if not shield.is_empty() and float(shield.get("remaining", 0.0)) > 0.0:
		var pool := float(shield.get("amount", 0.0))
		absorbed = minf(pool, scaled)
		pool -= absorbed
		if pool <= 0.0:
			clear_status_effect(target, "shield")
		else:
			shield["amount"] = pool
	var final := maxf(scaled - absorbed, 0.0)
	out["final_damage"] = final
	out["absorbed"] = absorbed
	if final > 0.0 and _dot_damage_depth <= 0 and _reflection_depth <= 0:
		var th := _find_effect(target, "thorns")
		if not th.is_empty() and float(th.get("remaining", 0.0)) > 0.0:
			var rmult := float(th.get("reflect_mult", 0.0))
			if rmult > 0.0:
				var resolved := _resolve_attacker(target, attacker)
				if resolved != null and is_instance_valid(resolved) and resolved != target:
					out["reflected"] = final * rmult
					out["reflected_target"] = resolved
	return out


## Remaining shield pool on the target (0.0 when no shield). Hook
## scripts read this via ModAPI.get_shield_remaining().
static func get_shield_remaining(target: Node) -> float:
	var sh := _find_effect(target, "shield")
	if sh.is_empty() or float(sh.get("remaining", 0.0)) <= 0.0:
		return 0.0
	return maxf(float(sh.get("amount", 0.0)), 0.0)


## Damage-taken multiplier from defensive states: 0.0 while petrified
## (nullified), else the vulnerable factor (1.0 when not vulnerable).
## Hook scripts read this via ModAPI.get_damage_taken_multiplier().
## NOTE: shield is NOT a multiplier (it is a pool) — it does not
## appear here; use get_shield_remaining() for it.
static func get_damage_taken_multiplier(target: Node) -> float:
	var petr := _find_effect(target, "petrified")
	if not petr.is_empty() and float(petr.get("remaining", 0.0)) > 0.0:
		return 0.0
	var vuln := _find_effect(target, "vulnerable")
	if not vuln.is_empty() and float(vuln.get("remaining", 0.0)) > 0.0:
		return float(vuln.get("factor", 1.0))
	return 1.0


## The attacker a thorns reflection goes to. An explicit, live
## attacker wins. Fallbacks (damage sources with no attacker handle):
## enemy target -> the player (single-player: all player-side damage
## originates from the player); player target -> the nearest live
## enemy (grenades / slams / explosions have no attacker handle).
## Null when no attacker can be resolved (out-of-tree target, no
## player/enemies around) — thorns then reflects nothing.
static func _resolve_attacker(target: Node, attacker: Node) -> Node:
	if attacker != null and is_instance_valid(attacker):
		return attacker
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return null
	if target.is_in_group("enemy"):
		var tree := target.get_tree()
		if tree != null:
			var players := tree.get_nodes_in_group("player")
			if not players.is_empty() and is_instance_valid(players[0]):
				return players[0] as Node
		return null
	if target.is_in_group("player"):
		var best: Node = null
		var best_d := INF
		var tpos := (target as Node3D).global_position if target is Node3D else Vector3.ZERO
		for e in EnemyBase.all:
			if e == null or not is_instance_valid(e):
				continue
			if not bool(e.get("active")) or bool(e.get("dead")):
				continue
			if not (e is Node3D):
				continue
			var d := (e as Node3D).global_position.distance_squared_to(tpos)
			if d < best_d:
				best_d = d
				best = e
		return best
	return null


## Applies a typed-damage rider (see KINDS). Failures are silent by
## design: the instant damage already landed; a rider with no handle
## on this target (e.g. weaken on a target with no damage stat)
## simply does not attach.
static func _apply_typed_rider(target: Node, dtype: String, amount: float, dur: float, origin: Vector3) -> void:
	match dtype:
		"fire":
			apply_status(target, "burn", {"damage_per_sec": maxf(amount * 0.25, 1.0), "duration_sec": dur}, origin)
		"cold":
			apply_status(target, "slow", {"factor": 0.6, "duration_sec": dur}, origin)
		"lightning":
			apply_status(target, "knockback", {"force": 6.0}, origin)
		"thunder":
			apply_status(target, "knockback", {"force": 12.0}, origin)
			apply_status(target, "prone", {"force": 6.0, "duration_sec": minf(dur, 2.0)}, origin)
		"acid":
			apply_status(target, "weaken", {"factor": 0.7, "duration_sec": dur}, origin)
		"necrotic":
			apply_status(target, "exhaustion", {"duration_sec": dur}, origin)
		"poison":
			apply_status(target, "poison", {"damage_per_sec": maxf(amount * 0.2, 1.0), "duration_sec": dur}, origin)
		"psychic":
			apply_status(target, "confusion", {"force": 4.0, "duration_sec": dur}, origin)
		"radiant":
			apply_status(target, "blind", {"factor": 0.5, "duration_sec": dur}, origin)


## Movement-speed multiplier from the target's active effects (1.0 =
## unaffected). Freeze / restrained / prone / sleep force 0. Multiple
## slows multiply. Haste multiplies above 1 (clamped to 2.5).
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
		match str(d.get("kind", "")):
			"slow", "freeze", "restrained", "prone", "sleep", "petrified":
				mult *= float(d.get("factor", 1.0))
			"poison":
				mult *= POISON_SLOW_FACTOR
			"haste":
				mult *= float(d.get("factor", 1.0))
			"exhaustion":
				var lvl := int(d.get("level", 1))
				mult *= maxf(EXHAUSTION_FLOOR, 1.0 - EXHAUSTION_PER_LEVEL * float(lvl))
	return clampf(mult, 0.0, 2.5)


## Active effects on the target (duplicated). [] when none.
static func active_effects(target: Node) -> Array:
	if target == null or not is_instance_valid(target):
		return []
	if not target.has_meta(META_KEY):
		return []
	return (target.get_meta(META_KEY) as Array).duplicate(true)


## True when the target has an active effect of `kind`.
static func has_status_effect(target: Node, kind: String) -> bool:
	return not _find_effect(target, kind).is_empty()


## Removes one kind from the target (restoring blind/weaken stat
## scaling), or every effect when kind == "all". True when something
## was removed. The "cure" primitive: a hook can end poison early.
static func clear_status_effect(target: Node, kind: String) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not target.has_meta(META_KEY):
		return false
	var effects := target.get_meta(META_KEY) as Array
	var removed := false
	var kept: Array = []
	for eff in effects:
		if not (eff is Dictionary):
			continue
		var d := eff as Dictionary
		if kind == "all" or str(d.get("kind", "")) == kind:
			_restore_effect(target, d)
			removed = true
			continue
		kept.append(d)
	if kept.is_empty():
		_clear_all(target)
	else:
		target.set_meta(META_KEY, kept)
	return removed


## Advances one target's effects by `delta` (called by its ticker).
## DOT/HOT effects tick in 1.0s chunks of damage/healing (threshold =
## the per-second rate), plus a final partial flush when the effect
## expires — a 2.5s burn at 10 dps deals exactly 25 damage, not 20
## or 30. Bleed's tick rate scales with movement speed. Confusion
## stumbles every CONFUSION_STUMBLE_SEC. Sleep wakes on HP loss.
## Expired effects are dropped (blind/weaken restore their captured
## stats); an emptied list removes the ticker + metadata. A dead
## target's effects are cleared (blind/weaken restored first, so a
## respawned player never keeps scaled weapon stats).
static func tick_target(target: Node, delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if not target.has_meta(META_KEY):
		return
	var effects := target.get_meta(META_KEY) as Array
	var dead := _is_dead(target)
	var kept: Array = []
	for eff in effects:
		if not (eff is Dictionary):
			continue
		var d := (eff as Dictionary).duplicate(true)
		var kind := str(d.get("kind", ""))
		if dead:
			_restore_effect(target, d)
			continue
		# Per-kind per-tick behaviour (before the remaining countdown).
		# DOT/HOT accumulation is capped by the time the effect has
		# LEFT (min(delta, remaining)): the final partial tick deals
		# exactly the leftover, never a full tick for a dead effect.
		var active_delta := minf(delta, float(d.get("remaining", 0.0)))
		match kind:
			"burn", "poison", "bleed":
				var rate := float(d.get("damage_per_sec", 0.0))
				if kind == "bleed":
					rate *= 1.0 + BLEED_MOVE_SCALE * _horizontal_speed(target)
					if target is Node3D:
						d["last_pos"] = (target as Node3D).global_position
				var accum := float(d.get("accum", 0.0)) + rate * active_delta
				var threshold := float(d.get("damage_per_sec", 0.0))
				# v0.5.8 D&D: DOT ticks are TYPED (burn=fire, poison=poison,
				# bleed=slashing) so creature-type resistances apply.
				var dot_type: String = str({"burn": "fire", "poison": "poison", "bleed": "slashing"}.get(kind, ""))
				while accum >= threshold and threshold > 0.0 and not _is_dead(target):
					accum -= threshold
					_damage_typed(target, threshold, dot_type)
				d["accum"] = accum
			"regen":
				var hps := float(d.get("heal_per_sec", 0.0))
				var raccum := float(d.get("accum", 0.0)) + hps * active_delta
				while raccum >= hps and hps > 0.0 and not _is_dead(target):
					raccum -= hps
					_heal_target(target, hps)
				d["accum"] = raccum
			"confusion":
				var timer := float(d.get("stumble_timer", 0.0)) - delta
				if timer <= 0.0 and target is CharacterBody3D and not _is_dead(target):
					var ang := randf() * TAU
					var stumble := Vector3(cos(ang), 0.0, sin(ang)) * float(d.get("force", 4.0))
					(target as CharacterBody3D).velocity += stumble
					timer = CONFUSION_STUMBLE_SEC
				d["stumble_timer"] = timer
			"sleep":
				var hp_at := float(d.get("hp_at_apply", -1.0))
				if hp_at >= 0.0:
					var hp_now_v: Variant = target.get("hp")
					if (hp_now_v is int or hp_now_v is float) and float(hp_now_v) < hp_at - 0.001:
						# Damage wakes the sleeper early.
						continue
		d["remaining"] = float(d.get("remaining", 0.0)) - delta
		if float(d.get("remaining", 0.0)) <= 0.0:
			# Expiry: flush leftover partial DOT/HOT, restore stats.
			if kind in ["burn", "poison", "bleed"]:
				var rest := float(d.get("accum", 0.0))
				if rest > 0.0 and not _is_dead(target):
					_damage_typed(target, rest, {"burn": "fire", "poison": "poison", "bleed": "slashing"}.get(kind, ""))
			elif kind == "regen":
				var rrest := float(d.get("accum", 0.0))
				if rrest > 0.0 and not _is_dead(target):
					_heal_target(target, rrest)
			_restore_effect(target, d)
			continue
		kept.append(d)
	if dead:
		_clear_all(target)
		return
	if kept.is_empty():
		_clear_all(target)
		return
	# Freeze / sleep / petrified pin the target in place (horizontal
	# velocity zeroed every tick — knockback cannot move a frozen,
	# sleeping, or petrified target).
	var pinned := false
	for eff in kept:
		if str((eff as Dictionary).get("kind", "")) in ["freeze", "sleep", "petrified"]:
			pinned = true
			break
	if pinned and target is CharacterBody3D:
		var body := target as CharacterBody3D
		body.velocity.x = 0.0
		body.velocity.z = 0.0
	target.set_meta(META_KEY, kept)


## Inserts or refreshes an effect: same-kind re-application keeps the
## strongest value and refreshes to the longest duration. (Blind /
## weaken / exhaustion bypass this — they need captured-stat /
## level handling in _apply_stat_scale / apply_status.)
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
			"slow", "freeze", "restrained", "prone", "sleep":
				d["factor"] = minf(float(d.get("factor", 1.0)), float(eff.get("factor", 1.0)))
			"petrified":
				d["factor"] = minf(float(d.get("factor", 1.0)), float(eff.get("factor", 0.0)))
			"burn", "poison", "bleed":
				d["damage_per_sec"] = maxf(float(d.get("damage_per_sec", 0.0)), float(eff.get("damage_per_sec", 0.0)))
				# accum / last_pos survive: a refresh never resets
				# the tick accounting.
			"regen":
				d["heal_per_sec"] = maxf(float(d.get("heal_per_sec", 0.0)), float(eff.get("heal_per_sec", 0.0)))
			"haste":
				d["factor"] = maxf(float(d.get("factor", 1.0)), float(eff.get("factor", 1.0)))
			"vulnerable":
				d["factor"] = maxf(float(d.get("factor", 1.0)), float(eff.get("factor", 1.0)))
			"thorns":
				d["reflect_mult"] = maxf(float(d.get("reflect_mult", 0.0)), float(eff.get("reflect_mult", 0.0)))
			"confusion":
				d["force"] = maxf(float(d.get("force", 0.0)), float(eff.get("force", 0.0)))
			"exhaustion":
				d["level"] = int(eff.get("level", 1))
			"sleep":
				d["hp_at_apply"] = float(eff.get("hp_at_apply", -1.0))
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


## Removes all metadata + the ticker. Callers restore blind/weaken
## stats BEFORE this (tick_target / clear_status_effect do).
static func _clear_all(target: Node) -> void:
	if target.has_meta(META_KEY):
		target.remove_meta(META_KEY)
	if target.has_meta("_mod_burn_accum"):
		target.remove_meta("_mod_burn_accum")
	var ticker := target.get_node_or_null("ModStatusTicker")
	if ticker != null:
		ticker.queue_free()


## Finds the target's active effect dict of `kind` (the live dict,
## not a copy). {} when none.
static func _find_effect(target: Node, kind: String) -> Dictionary:
	if target == null or not is_instance_valid(target):
		return {}
	if not target.has_meta(META_KEY):
		return {}
	for eff in (target.get_meta(META_KEY) as Array):
		if eff is Dictionary and str((eff as Dictionary).get("kind", "")) == kind:
			return eff as Dictionary
	return {}


## Blind / weaken: scale a stat on apply, restore on expiry. Two
## paths: (1) the target itself carries the stat — enemies carry
## `accuracy` (blind) / `damage` (weaken); (2) the target has a
## WeaponManager child — the player — whose weapons carry
## `spread_hip`/`spread_move` (blind, scaled by 1/factor) /
## `damage` (weaken, scaled by factor). A re-application re-scales
## from the CAPTURED originals, never from the already-scaled value.
## Returns false when neither path has a handle on this target.
static func _apply_stat_scale(target: Node, kind: String, factor: float, dur: float) -> bool:
	var stat_prop := "accuracy" if kind == "blind" else "damage"
	var cur_v: Variant = target.get(stat_prop)
	var existing := _find_effect(target, kind)
	var best_factor := factor
	if not existing.is_empty():
		best_factor = minf(float(existing.get("factor", 1.0)), factor)
	if cur_v is int or cur_v is float:
		var orig := float(cur_v)
		if not existing.is_empty() and str(existing.get("stat_path", "")) == "self":
			orig = float(existing.get("orig_value", orig))
		target.set(stat_prop, orig * best_factor)
		var effects: Array = []
		if target.has_meta(META_KEY):
			effects = target.get_meta(META_KEY) as Array
		var merged := false
		for i in range(effects.size()):
			var d := effects[i] as Dictionary
			if str(d.get("kind", "")) != kind:
				continue
			d["factor"] = best_factor
			d["remaining"] = maxf(float(d.get("remaining", 0.0)), dur)
			d["stat_path"] = "self"
			d["orig_value"] = orig
			effects[i] = d
			merged = true
			break
		if not merged:
			effects.append({"kind": kind, "factor": best_factor, "remaining": dur,
				"stat_path": "self", "orig_value": orig})
		target.set_meta(META_KEY, effects)
		_ensure_ticker(target)
		return true
	# Player path: scale every equipped weapon's stat.
	var wm := target.get_node_or_null("WeaponManager")
	if wm == null:
		return false
	var weapons: Array = []
	for kid in (wm as Node).get_children():
		if kid == null or not is_instance_valid(kid):
			continue
		if kind == "blind":
			if (kid as Node).get("spread_hip") is int or (kid as Node).get("spread_hip") is float:
				weapons.append(kid)
		else:
			if (kid as Node).get("damage") is int or (kid as Node).get("damage") is float:
				weapons.append(kid)
	if weapons.is_empty():
		return false
	var origs: Array = []
	if not existing.is_empty() and str(existing.get("stat_path", "")) == "weapons":
		origs = (existing.get("origs", []) as Array).duplicate(true)
		# Re-capture any weapon granted since the first application
		# (it was never scaled — its current value IS its original).
		var known: Array = []
		for entry in origs:
			if entry is Array and not (entry as Array).is_empty():
				known.append((entry as Array)[0])
		for w in weapons:
			if not known.has(w):
				if kind == "blind":
					origs.append([w, _num_prop(w, "spread_hip"), _num_prop(w, "spread_move")])
				else:
					origs.append([w, _num_prop(w, "damage")])
	else:
		for w in weapons:
			if kind == "blind":
				origs.append([w, _num_prop(w, "spread_hip"), _num_prop(w, "spread_move")])
			else:
				origs.append([w, _num_prop(w, "damage")])
	for entry in origs:
		if not (entry is Array) or (entry as Array).is_empty():
			continue
		var w := (entry as Array)[0] as Node
		if w == null or not is_instance_valid(w):
			continue
		if kind == "blind":
			w.set("spread_hip", float((entry as Array)[1]) / best_factor)
			w.set("spread_move", float((entry as Array)[2]) / best_factor)
		else:
			w.set("damage", float((entry as Array)[1]) * best_factor)
	var weffects: Array = []
	if target.has_meta(META_KEY):
		weffects = target.get_meta(META_KEY) as Array
	var wmerged := false
	for i in range(weffects.size()):
		var d := weffects[i] as Dictionary
		if str(d.get("kind", "")) != kind:
			continue
		d["factor"] = best_factor
		d["remaining"] = maxf(float(d.get("remaining", 0.0)), dur)
		d["stat_path"] = "weapons"
		d["origs"] = origs
		weffects[i] = d
		wmerged = true
		break
	if not wmerged:
		weffects.append({"kind": kind, "factor": best_factor, "remaining": dur,
			"stat_path": "weapons", "origs": origs})
	target.set_meta(META_KEY, weffects)
	_ensure_ticker(target)
	return true


## Numeric property of a node (0.0 when missing / non-numeric).
## Object.get() takes ONE argument — Dictionary.get()'s default does
## not exist here, so reads go through this helper.
static func _num_prop(node: Node, prop: String) -> float:
	var v: Variant = node.get(prop)
	if v is int or v is float:
		return float(v)
	return 0.0


## Restores a blind/weaken effect's captured stats. No-op for other
## kinds. Freed weapon nodes are skipped (their stats die with them).
static func _restore_effect(target: Node, eff: Dictionary) -> void:
	var kind := str(eff.get("kind", ""))
	if kind != "blind" and kind != "weaken":
		return
	if target == null or not is_instance_valid(target):
		return
	if str(eff.get("stat_path", "")) == "self":
		var prop := "accuracy" if kind == "blind" else "damage"
		var cur_v: Variant = target.get(prop)
		if cur_v is int or cur_v is float:
			target.set(prop, float(eff.get("orig_value", cur_v)))
	elif str(eff.get("stat_path", "")) == "weapons":
		for entry in (eff.get("origs", []) as Array):
			if not (entry is Array) or (entry as Array).is_empty():
				continue
			var w := (entry as Array)[0] as Node
			if w == null or not is_instance_valid(w):
				continue
			if kind == "blind":
				w.set("spread_hip", float((entry as Array)[1]))
				w.set("spread_move", float((entry as Array)[2]))
			else:
				w.set("damage", float((entry as Array)[1]))


## True when the target can receive healing (heal() or an hp var).
static func _can_heal(target: Node) -> bool:
	if target.has_method("heal"):
		return true
	var hp_v: Variant = target.get("hp")
	return hp_v is int or hp_v is float


## Deals damage through the target's take_damage (no-op without it).
## Internal damage: bracketed by the dot guard, so a thorns carrier
## never reflects DOT / exhaustion damage (there is no attacker).
static func _damage_target(target: Node, amount: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if target.has_method("take_damage") and not _is_dead(target):
		var pos := Vector3.ZERO
		if target is Node3D:
			pos = (target as Node3D).global_position
		begin_dot_damage()
		target.call("take_damage", amount, pos, false)
		end_dot_damage()


## Typed damage: prefers the target's take_typed_damage (EnemyBase
## applies the creature-type resistance table); falls back to untyped
## take_damage for targets without it (dummies, players, structures).
## "" damage_type == untyped (used for true damage, e.g. exhaustion-6).
## Internal damage (dot guard): never reflects via thorns.
static func _damage_typed(target: Node, amount: float, damage_type: String) -> void:
	if damage_type.is_empty():
		_damage_target(target, amount)
		return
	if target == null or not is_instance_valid(target):
		return
	if target.has_method("take_typed_damage") and not _is_dead(target):
		var pos := Vector3.ZERO
		if target is Node3D:
			pos = (target as Node3D).global_position
		begin_dot_damage()
		target.call("take_typed_damage", amount, damage_type, pos, false)
		end_dot_damage()
		return
	_damage_target(target, amount)


## Heals through heal() when present, else clamps hp to max_hp.
static func _heal_target(target: Node, amount: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if _is_dead(target):
		return
	if target.has_method("heal"):
		target.call("heal", amount)
		return
	var hp_v: Variant = target.get("hp")
	if hp_v is int or hp_v is float:
		var cap := float(hp_v) + amount
		var max_v: Variant = target.get("max_hp")
		if max_v is int or max_v is float:
			cap = minf(cap, float(max_v))
		target.set("hp", cap)


## Horizontal speed of the target (bleed scaling). 0 for non-bodies.
static func _horizontal_speed(target: Node) -> float:
	if target is CharacterBody3D:
		var v := (target as CharacterBody3D).velocity
		return Vector2(v.x, v.z).length()
	return 0.0


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
