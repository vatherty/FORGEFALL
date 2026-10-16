# FORGEFALL — ModHookRegistry (v0.5.3: invented hooks, Worker A)
# Runtime home for invented hooks: lookup + dispatch + weapon attach.
# Storage: hooks live ON the ModLoader record (rec["hooks"], validated
# at scan time); this registry never stores its own copy of a mod's
# hooks — it reads them from ModLoader so there is exactly one source
# of truth, and a disabled/broken mod's hooks can never run (the record
# is error-gated on every read).
#
# HOW A MOD WEAPON GETS ITS HOOKS (the attach problem):
# ForgeBuilder (scripts/forge/*, NOT owned by this worker) grants a mod
# weapon by calling WeaponManager.give_weapon(arsenal_id) with ONLY the
# base arsenal id — the mod identity never travels with that call. The
# attach therefore rides on ModLoader.find_mod, which ForgeBuilder and
# the Forge gate call for the mod's ref on the way to every build:
#   validation: ForgeLLM.recompute_cost -> find_mod(ref), and
#     _validate_mod_block_params -> find_mod(ref)
#   build:      ForgeBuilder._build_mod_block -> find_mod(ref)
#   -> give_weapon(arsenal_id) -> try_attach_pending(weapon, arsenal_id)
# try_attach_pending attaches ONLY when the last TWO find_mod calls were
# for the SAME ref within FIND_PAIR_WINDOW_MSEC. That pair is the
# signature of a real build: a lone/speculative find_mod (LLM catalog
# listing, offline name matching, a plain-weapon build that never
# references the mod) cannot produce two consecutive same-ref calls, so
# it can never mis-attach a mod's hooks to a plain weapon. A direct
# ForgeBuilder.build() call (bypassing the ForgeManager gate) makes
# only ONE find_mod call — callers doing that must either call
# ModLoader.find_mod(ref) twice first, or attach explicitly with
# attach_mod_to_weapon(). The explicit API is also what tests and
# ModAPI-driven flows use.
# Pending state is consumed on attach and expires after PENDING_TTL_MSEC.
#
# SCOPING: hooks are scoped to their mod's weapon (see ModHook). They
# run while that weapon is equipped: on_fire / projectile_spawn in
# WeaponBase._attempt_fire, on_hit / on_kill in the hit path,
# on_damage_taken in WeaponManager's hp-drop poll.
extends RefCounted
class_name ModHookRegistry

## Two consecutive find_mod calls for the same ref must land within
## this window to count as a build. Validation -> build is one
## synchronous chain (microseconds); LLM catalog / offline matching
## calls are separated by network / frame boundaries.
const FIND_PAIR_WINDOW_MSEC := 100
## A pending attach that is never consumed expires after this long.
const PENDING_TTL_MSEC := 5000

## Forge weapon id -> Arsenal id (mirrors ForgeBuilder.FORGE_WEAPON_IDS;
## ids not in the map (p9/raptor/lmg) pass through unchanged).
const FORGE_TO_ARSENAL := {
	"manticore": "ar7",
	"longeye": "lr8",
	"breacher": "sg12",
	"hornet": "smg9",
	"trident": "br3",
	"judge": "hv44",
}


## Validated hooks for an enabled, error-free mod. [] for anything else
## (unknown / disabled / broken mod, or a mod with no hooks).
static func hooks_for_mod(mod_id: String) -> Array:
	var rec := ModLoader.find_mod(mod_id, false)
	if rec.is_empty() or not bool(rec.get("enabled", false)) or str(rec.get("error", "")) != "":
		return []
	var hooks: Variant = rec.get("hooks", null)
	if not (hooks is Array):
		return []
	return (hooks as Array).duplicate(true)


## The mod's custom projectile spec (merged): the LAST fire-point hook
## carrying a "projectile" wins. {} when the mod defines no projectile.
## The returned dict carries "_hook_id" (which hook defined it).
static func projectile_for_mod(mod_id: String) -> Dictionary:
	var out: Dictionary = {}
	for h in hooks_for_mod(mod_id):
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		if str(d.get("error", "")) != "":
			continue
		if str(d.get("hook_point", "")) in ["on_fire", "projectile_spawn"] and d.has("projectile"):
			out = (d.get("projectile", {}) as Dictionary).duplicate(true)
			out["_hook_id"] = str(d.get("hook_id", ""))
	return out


## Attaches a mod's hooks + projectile spec to a weapon node (duck-typed:
## any Node with mod_id / mod_projectile_spec / mod_hooks members —
## WeaponBase). Returns false when the mod is unknown/disabled/broken.
## The weapon keeps the attachment until it is replaced.
static func attach_mod_to_weapon(weapon: Node, mod_ref: Variant) -> bool:
	if weapon == null:
		return false
	var rec: Dictionary = {}
	if mod_ref is Dictionary:
		rec = mod_ref as Dictionary
	elif mod_ref is String:
		rec = ModLoader.find_mod(str(mod_ref), false)
	if rec.is_empty() or not bool(rec.get("enabled", false)) or str(rec.get("error", "")) != "":
		return false
	var mod_id := str(rec.get("id", ""))
	weapon.set("mod_id", mod_id)
	weapon.set("mod_projectile_spec", projectile_for_mod(mod_id))
	weapon.set("mod_hooks", hooks_for_mod(mod_id))
	return true


## Consumes a pending mod attach for a freshly-granted weapon (called by
## WeaponManager.give_weapon). True when a mod was attached.
static func try_attach_pending(weapon: Node, arsenal_id: String) -> bool:
	var rec := pending_mod_for_weapon(arsenal_id)
	if rec.is_empty():
		return false
	var ok := attach_mod_to_weapon(weapon, rec)
	ModLoader.clear_find_history()
	return ok


## The mod pending attach for a weapon of this arsenal id, or {}.
## Requires the find_mod pair rule (see header) + a target/base match:
## the mod must be an enabled, error-free WEAPON mod, and either it
## declares no base_weapon_id (script mods: the mod's weapon is
## whatever it grants) or its base maps to this arsenal id.
static func pending_mod_for_weapon(arsenal_id: String) -> Dictionary:
	var hist := ModLoader.get_find_history()
	if hist.size() < 2:
		return {}
	var a: Dictionary = hist[hist.size() - 2]
	var b: Dictionary = hist[hist.size() - 1]
	if str(a.get("ref", "")) != str(b.get("ref", "")):
		return {}
	if int(b.get("at_msec", 0)) - int(a.get("at_msec", 0)) > FIND_PAIR_WINDOW_MSEC:
		return {}
	if int(b.get("at_msec", 0)) > Time.get_ticks_msec() + 1:
		return {}
	if Time.get_ticks_msec() - int(b.get("at_msec", 0)) > PENDING_TTL_MSEC:
		return {}
	var rec := ModLoader.find_mod(str(b.get("ref", "")), false)
	if rec.is_empty() or not bool(rec.get("enabled", false)) or str(rec.get("error", "")) != "":
		return {}
	var info: Dictionary = rec.get("block_info", {})
	if str(info.get("target", "")) != "weapon":
		return {}
	if info.has("base_weapon_id"):
		var base := str(info.get("base_weapon_id", ""))
		var mapped := str(FORGE_TO_ARSENAL.get(base, base))
		if mapped != arsenal_id:
			return {}
	return rec


## Runs every hook in `hooks` at `point` through ModAPI. Data hooks are
## interpreted (effects applied via `api`); code hooks run their
## run(api, ctx). Returns a MERGED result:
##   {"damage_mult": float (1.0 = unchanged; multiplied across hooks),
##    "healed": float, "exploded": bool, "announced": bool,
##    "status_applied": bool (a slow/freeze/burn/knockback landed)}
## A code hook that errors at run time yields no result (its error is
## printed by the engine); the registry never lets one hook break the
## others or the shot. Projectile specs are NOT applied here — the
## firing path resolves them separately (resolve_projectile_spec).
static func run_hooks(hooks: Array, point: String, api: ModAPI, ctx: Dictionary) -> Dictionary:
	var out := {"damage_mult": 1.0, "healed": 0.0, "exploded": false, "announced": false, "status_applied": false}
	if api == null:
		return out
	for h in hooks:
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		if str(d.get("error", "")) != "":
			continue
		if str(d.get("hook_point", "")) != point:
			continue
		if d.has("_instance") and d["_instance"] is ModHook:
			var res: Variant = (d["_instance"] as ModHook).run(api, ctx)
			if res is Dictionary:
				_merge_hook_result(out, res as Dictionary)
			continue
		for eff in (d.get("effects", []) as Array):
			if eff is Dictionary:
				_apply_effect(out, eff as Dictionary, api, ctx, point)
	return out


## Runs the hooks attached to `weapon` at `point`. No-op ({defaults})
## when the weapon carries no hooks for the point.
static func run_point_for_weapon(weapon: Node, point: String, api: ModAPI, ctx: Dictionary) -> Dictionary:
	if weapon == null:
		return {"damage_mult": 1.0, "healed": 0.0, "exploded": false, "announced": false, "status_applied": false}
	var hooks: Variant = weapon.get("mod_hooks")
	if not (hooks is Array):
		return {"damage_mult": 1.0, "healed": 0.0, "exploded": false, "announced": false, "status_applied": false}
	return run_hooks(hooks as Array, point, api, ctx)


## The projectile spec a weapon actually fires: the attached spec
## merged with the attached hooks' projectile dicts (last hook wins on
## conflicting keys). {} when the weapon has no custom projectile.
static func resolve_projectile_spec(weapon: Node) -> Dictionary:
	if weapon == null:
		return {}
	var spec: Variant = weapon.get("mod_projectile_spec")
	var out: Dictionary = {}
	if spec is Dictionary:
		out = (spec as Dictionary).duplicate(true)
	var hooks: Variant = weapon.get("mod_hooks")
	if hooks is Array:
		for h in (hooks as Array):
			if not (h is Dictionary):
				continue
			var d := h as Dictionary
			if str(d.get("error", "")) != "":
				continue
			if str(d.get("hook_point", "")) in ["on_fire", "projectile_spawn"] and d.has("projectile"):
				for k in (d.get("projectile", {}) as Dictionary).keys():
					out[str(k)] = (d.get("projectile", {}) as Dictionary)[k]
	return out


## Dead = is_dead() when present, else the "dead" flag, else hp <= 0.
## Shared by WeaponBase (on_kill detection) and ModProjectile.
static func target_is_dead(collider: Variant) -> bool:
	var obj := collider as Object
	if obj == null:
		return false
	if obj.has_method("is_dead"):
		return bool(obj.call("is_dead"))
	var dead_v: Variant = obj.get("dead")
	if dead_v is bool:
		return dead_v
	var hp_v: Variant = obj.get("hp")
	if hp_v is int or hp_v is float:
		return float(hp_v) <= 0.0
	return false


static func _merge_hook_result(out: Dictionary, res: Dictionary) -> void:
	if res.has("damage_mult"):
		var m: Variant = res.get("damage_mult", null)
		if (m is int or m is float):
			out["damage_mult"] = float(out.get("damage_mult", 1.0)) * float(m)
	if res.has("healed"):
		var h: Variant = res.get("healed", null)
		if (h is int or h is float):
			out["healed"] = float(out.get("healed", 0.0)) + float(h)
	if res.has("exploded") and bool(res.get("exploded", false)):
		out["exploded"] = true
	if res.has("announced") and bool(res.get("announced", false)):
		out["announced"] = true
	if res.has("status_applied") and bool(res.get("status_applied", false)):
		out["status_applied"] = true


## Applies ONE data-hook effect via ModAPI. Position comes from ctx
## ("position" / "hit_position" / player position, in that order).
## Status effects (slow / freeze / burn / knockback) hit the ctx
## "target" (on_hit / on_kill) or the player (on_damage_taken).
static func _apply_effect(out: Dictionary, eff: Dictionary, api: ModAPI, ctx: Dictionary, point: String = "") -> void:
	var kind := str(eff.get("kind", ""))
	var pos := _effect_position(api, ctx)
	match kind:
		"heal":
			var amount := float(eff.get("amount", 0.0))
			api.heal_player(amount)
			out["healed"] = float(out.get("healed", 0.0)) + amount
		"explosion":
			api.fire_effect("explosion", pos, float(eff.get("radius", 4.0)), float(eff.get("damage", 60.0)))
			out["exploded"] = true
		"smoke":
			api.fire_effect("smoke", pos, 0.0, 0.0, float(eff.get("duration_sec", 20.0)))
		"announce":
			api.announce(str(eff.get("title", "")), str(eff.get("subtitle", "")))
			out["announced"] = true
		"damage_mult":
			out["damage_mult"] = float(out.get("damage_mult", 1.0)) * float(eff.get("value", 1.0))
		"slow", "freeze", "burn", "knockback":
			var tgt: Variant = ctx.get("target", null)
			if tgt == null and point == "on_damage_taken":
				tgt = api.get_player()
			if tgt is Node:
				if api.apply_status_effect(tgt as Node, kind, eff, pos):
					out["status_applied"] = true


static func _effect_position(api: ModAPI, ctx: Dictionary) -> Vector3:
	if ctx.has("position") and ctx["position"] is Vector3:
		return ctx["position"] as Vector3
	if ctx.has("hit_position") and ctx["hit_position"] is Vector3:
		return ctx["hit_position"] as Vector3
	return api.get_player_position()
