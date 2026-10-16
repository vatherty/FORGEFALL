# FORGEFALL — ModHook (v0.5.3: invented hooks, Worker A)
# Base class + schema for INVENTED HOOKS. Colin changed the rule: when a
# request needs behaviour no existing block covers, the LLM must TRY TO
# CREATE the hook for it (it is no longer held to building-blocks-only).
# Same standing rules: the hook runs through the ModAPI surface only,
# never raw engine access; a hook that fails validation is REJECTED with
# a named violation, never silently repaired.
#
# TWO HOOK KINDS, one registry:
# (a) DATA hooks (preferred, fully sandboxed): plain Dictionaries the
#     game INTERPRETS — no code runs at all. A data hook carries either
#     a "projectile" dict (fire points) or an "effects" array (all
#     points). The registry applies the effects via ModAPI.
# (b) CODE hooks: a GDScript source string ("code") that MUST
#     `extend ModHook` and implement run(api, ctx). The source passes
#     the same forbidden-API text scan as ModBlock scripts, plus a
#     compile check, BEFORE it is ever instantiated. At run time the
#     instance receives ONLY a ModAPI + a context Dictionary. GDScript
#     has no try/catch, so a code hook that errors at run time prints an
#     engine error and returns nothing (the registry treats that as an
#     empty result) — it cannot crash the game, but like ModBlock it
#     carries the same GMod-addon trust bar: only install hooks from
#     sources you trust.
#
# HOW HOOKS REACH THE GAME (authoring):
# - JSON block mods: top-level "hooks": [...] in the payload (next to
#   the "block" object), and/or "hooks": [...] in a folder manifest.
# - Script mods: implement get_hooks() -> Array (ModBlock base returns
#   []) and/or declare "hook_files" in a folder manifest (see
#   ModLoader). A single-file script mod uses get_hooks().
# - LLM generation: block payloads carry "hooks"; script payloads
#   implement get_hooks(). The generation prompt (ModCreator's hook
#   addendum + the creator menu's technical notes) instructs exactly
#   that. Hooks are NEVER hidden: the approval screen lists every
#   invented hook before Install (ModHook.summarize_hooks).
#
# HOOK POINTS (hook_point, normalized: lowercase, "-" -> "_"):
#   "on_fire" / "projectile_spawn" — weapon fires. May carry a
#     "projectile" dict (the mod's custom projectile) and/or "effects".
#   "on_hit" — a shot/projectile struck something. "effects" only.
#     A damage_mult effect multiplies THAT hit's damage before it lands.
#   "on_kill" — a shot/projectile killed its target. "effects" only.
#   "on_damage_taken" — the player took damage. "effects" only. A
#     damage_mult < 1 is applied retroactively as a heal of the reduced
#     portion (net HP is exactly correct; the hurt feedback still plays
#     for one frame) — see WeaponManager's hp-drop poll. A damage_mult
#     > 1 (vulnerability) is ignored by that poll (it would re-trigger
#     on its own extra damage); vulnerability needs the player-side
#     pre-damage call.
# Aliases: "on_projectile_spawn" -> "projectile_spawn",
# "on_damage" -> "on_damage_taken".
#
# SCOPING: hooks belong to their mod's weapon. They attach to the weapon
# when the mod weapon is granted (ModHookRegistry.try_attach_pending /
# attach_mod_to_weapon) and run while that weapon is equipped. A hook
# never runs for a weapon it does not belong to.
#
# DATA HOOK SCHEMA:
#   {"hook_id": "watermelon_rounds", "hook_point": "projectile_spawn",
#    "display_name": "Watermelon Rounds", "description": "...",
#    "projectile": {"visual": "watermelon", "shape": "sphere",
#      "speed": 28.0, "damage": 40.0, "range": 90.0, "size": 1.0,
#      "gravity": 0.0, "pierce": false,
#      "explodes_on_impact": true, "explosion_radius": 4.0,
#      "explosion_damage": 60.0, "color": "#e83a4e"},
#    "effects": [{"kind": "heal", "amount": 15.0}]}
# EFFECT KINDS: heal {amount 1-500}, explosion {radius 0.5-20,
# damage 0-500}, smoke {duration_sec 1-120}, announce {title, subtitle
# strings}, damage_mult {value 0-5}.
# CODE HOOK SCHEMA: same keys, plus "code": "<GDScript source>".
# A hook must carry at least one of projectile / effects / code.
# Unknown keys are rejected (no silent typos).
#
# ModHook.run() RETURN CONTRACT (code hooks): a Dictionary with any of
#   {"damage_mult": float (multiplied into the hit), "healed": float,
#    "exploded": bool}. Anything else is ignored. Effects the hook
# applies directly through `api` (heal_player, fire_effect, ...) need
# not be reported; the return value is for damage_mult + accounting.
extends RefCounted
class_name ModHook

const HOOK_POINTS := ["on_fire", "projectile_spawn", "on_hit", "on_kill", "on_damage_taken"]

const HOOK_POINT_ALIASES := {
	"on_projectile_spawn": "projectile_spawn",
	"on_damage": "on_damage_taken",
}

const EFFECT_KINDS := ["heal", "explosion", "smoke", "announce", "damage_mult"]

const HOOK_KEYS := ["hook_id", "hook_point", "display_name", "description", "projectile", "effects", "code"]

const EFFECT_KEYS := ["kind", "amount", "radius", "damage", "duration_sec", "title", "subtitle", "value"]

const MAX_HOOK_CODE_CHARS := 20000


## Catalog entry for this hook (code hooks may override; data hooks
## never instantiate this class). Default: {}.
func get_hook_info() -> Dictionary:
	return {}


## Runs the hook. `api` is the ONLY game surface available; `ctx`
## carries the hook-point facts (position, damage, target, weapon...).
## Return a Dictionary per the contract above, or {}.
func run(api: ModAPI, ctx: Dictionary) -> Dictionary:
	return {}


## Normalizes a hook-point string (lowercase, "-" -> "_", aliases).
## "" when it does not name a known point.
static func normalize_hook_point(raw: String) -> String:
	var p := raw.to_lower().strip_edges().replace("-", "_")
	if p in HOOK_POINT_ALIASES:
		p = str(HOOK_POINT_ALIASES[p])
	if p in HOOK_POINTS:
		return p
	return ""


## True when `point` is a fire point (may carry a projectile).
static func is_fire_point(point: String) -> bool:
	return point in ["on_fire", "projectile_spawn"]


## Validates ONE hook dict IN PLACE (normalizes hook_point). "" = OK,
## else an error naming the violation. Code hooks are also compiled
## (validate_hook_code); a compiled instance is stored under the
## internal "_instance" key for the registry to reuse. Never repairs.
static func validate_hook_data(hook: Dictionary) -> String:
	if hook.is_empty():
		return "hook is empty"
	for k in hook.keys():
		if str(k) not in HOOK_KEYS and str(k) != "_instance":
			return "unknown hook field '%s'" % str(k)
	var hid: Variant = hook.get("hook_id", null)
	if not (hid is String) or str(hid).is_empty() or str(hid).length() > 48:
		return "hook 'hook_id' must be a non-empty string (max 48 chars)"
	for ch in str(hid):
		if not ("abcdefghijklmnopqrstuvwxyz0123456789_".contains(ch)):
			return "hook_id '%s' must use only [a-z0-9_]" % str(hid)
	var point: Variant = hook.get("hook_point", null)
	if not (point is String):
		return "hook '%s' has no hook_point" % str(hid)
	var norm := normalize_hook_point(str(point))
	if norm.is_empty():
		return "hook '%s' has unknown hook_point '%s'" % [str(hid), str(point)]
	hook["hook_point"] = norm
	if hook.has("display_name"):
		var dn: Variant = hook.get("display_name", null)
		if not (dn is String) or str(dn).strip_edges().is_empty() or str(dn).length() > 80:
			return "hook '%s' display_name must be a non-empty string (max 80 chars)" % str(hid)
	if hook.has("description"):
		var ds: Variant = hook.get("description", null)
		if not (ds is String) or str(ds).length() > 300:
			return "hook '%s' description must be a string (max 300 chars)" % str(hid)
	var has_projectile := hook.has("projectile")
	var has_effects := hook.has("effects")
	var has_code := hook.has("code")
	if not (has_projectile or has_effects or has_code):
		return "hook '%s' does nothing (needs projectile, effects, or code)" % str(hid)
	if has_projectile:
		if not is_fire_point(norm):
			return "hook '%s' carries a projectile but its point is '%s' (projectiles only on on_fire / projectile_spawn)" % [str(hid), norm]
		var perr := validate_projectile_spec(hook.get("projectile", null))
		if perr != "":
			return "hook '%s' projectile: %s" % [str(hid), perr]
	if has_effects:
		var effs: Variant = hook.get("effects", null)
		if not (effs is Array):
			return "hook '%s' effects must be an array" % str(hid)
		if (effs as Array).is_empty():
			return "hook '%s' effects array is empty" % str(hid)
		for eff in (effs as Array):
			if not (eff is Dictionary):
				return "hook '%s' has a non-object effect" % str(hid)
			var eerr := validate_effect(eff as Dictionary)
			if eerr != "":
				return "hook '%s' effect: %s" % [str(hid), eerr]
	if has_code:
		var code: Variant = hook.get("code", null)
		if not (code is String) or str(code).strip_edges().is_empty():
			return "hook '%s' code must be a non-empty string" % str(hid)
		var cerr := validate_hook_code(str(code))
		if cerr != "":
			return "hook '%s' code: %s" % [str(hid), cerr]
		var compiled := compile_hook_code(str(code))
		if str(compiled.get("error", "")) != "":
			return "hook '%s' code: %s" % [str(hid), str(compiled.get("error", ""))]
		hook["_instance"] = compiled.get("instance")
	return ""


## Validates a projectile dict (inside a fire-point hook). "" = OK.
## All fields optional (runtime defaults fill them); any PRESENT field
## is type/range-checked. "damage": -1 or absent means "use the
## weapon's damage".
static func validate_projectile_spec(p: Variant) -> String:
	if not (p is Dictionary):
		return "projectile must be an object"
	var spec := p as Dictionary
	for k in spec.keys():
		if str(k) not in ["visual", "shape", "speed", "damage", "range", "size", "gravity", "pierce", "explodes_on_impact", "explosion_radius", "explosion_damage", "color"]:
			return "unknown projectile field '%s'" % str(k)
	if spec.has("visual") and not (spec["visual"] is String):
		return "projectile 'visual' must be a string"
	if spec.has("visual") and str(spec["visual"]).length() > 200:
		return "projectile 'visual' must be at most 200 chars"
	if spec.has("shape") and not (spec["shape"] is String):
		return "projectile 'shape' must be a string"
	if spec.has("shape") and str(spec["shape"]).length() > 32:
		return "projectile 'shape' must be at most 32 chars"
	if spec.has("speed") and not _is_num_in(spec.get("speed", null), 1.0, 200.0):
		return "projectile 'speed' out of range 1-200"
	if spec.has("damage") and not _is_num_in(spec.get("damage", null), -1.0, 500.0):
		return "projectile 'damage' out of range -1-500"
	if spec.has("range") and not _is_num_in(spec.get("range", null), 1.0, 500.0):
		return "projectile 'range' out of range 1-500"
	if spec.has("size") and not _is_num_in(spec.get("size", null), 0.05, 5.0):
		return "projectile 'size' out of range 0.05-5"
	if spec.has("gravity") and not _is_num_in(spec.get("gravity", null), -50.0, 50.0):
		return "projectile 'gravity' out of range -50-50"
	if spec.has("pierce") and not (spec["pierce"] is bool):
		return "projectile 'pierce' must be a bool"
	if spec.has("explodes_on_impact") and not (spec["explodes_on_impact"] is bool):
		return "projectile 'explodes_on_impact' must be a bool"
	if spec.has("explosion_radius") and not _is_num_in(spec.get("explosion_radius", null), 0.0, 20.0):
		return "projectile 'explosion_radius' out of range 0-20"
	if spec.has("explosion_damage") and not _is_num_in(spec.get("explosion_damage", null), 0.0, 500.0):
		return "projectile 'explosion_damage' out of range 0-500"
	if spec.has("color") and not (spec["color"] is String):
		return "projectile 'color' must be a string"
	return ""


## Validates ONE effect dict. "" = OK, else an error naming the violation.
static func validate_effect(eff: Dictionary) -> String:
	for k in eff.keys():
		if str(k) not in EFFECT_KEYS:
			return "unknown effect field '%s'" % str(k)
	var kind: Variant = eff.get("kind", null)
	if not (kind is String) or str(kind) not in EFFECT_KINDS:
		return "effect 'kind' must be heal|explosion|smoke|announce|damage_mult"
	match str(kind):
		"heal":
			if not _is_num_in(eff.get("amount", null), 1.0, 500.0):
				return "heal effect 'amount' out of range 1-500"
		"explosion":
			if not _is_num_in(eff.get("radius", null), 0.5, 20.0):
				return "explosion effect 'radius' out of range 0.5-20"
			if not _is_num_in(eff.get("damage", null), 0.0, 500.0):
				return "explosion effect 'damage' out of range 0-500"
		"smoke":
			if not _is_num_in(eff.get("duration_sec", null), 1.0, 120.0):
				return "smoke effect 'duration_sec' out of range 1-120"
		"announce":
			if eff.has("title") and (not (eff["title"] is String) or str(eff["title"]).length() > 120):
				return "announce effect 'title' must be a string (max 120 chars)"
			if eff.has("subtitle") and (not (eff["subtitle"] is String) or str(eff["subtitle"]).length() > 120):
				return "announce effect 'subtitle' must be a string (max 120 chars)"
		"damage_mult":
			if not _is_num_in(eff.get("value", null), 0.0, 5.0):
				return "damage_mult effect 'value' out of range 0-5"
	return ""


## Validates hook CODE (a GDScript source string): forbidden-API text
## scan, extends ModHook, run() present, and a real compile check.
## "" = OK, else an error naming the violation. Never repairs.
static func validate_hook_code(code: String) -> String:
	if code.length() > MAX_HOOK_CODE_CHARS:
		return "hook code exceeds %d chars" % MAX_HOOK_CODE_CHARS
	var forbidden := ModLoader._scan_forbidden(code)
	if forbidden != "":
		return "forbidden API in hook code: %s" % forbidden
	var extends_ok := false
	for raw_line in code.split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("extends "):
			extends_ok = (line == "extends ModHook")
			break
		if line.begins_with("extends\t"):
			extends_ok = (line == "extends\tModHook")
			break
	if not extends_ok:
		return "hook code must 'extend ModHook'"
	if not code.contains("func run("):
		return "hook code must implement run(api, ctx)"
	return ""


## Compiles hook code (already validated) into a ModHook instance.
## Returns {"instance": ModHook or null, "error": String}. The compile
## runs in-memory only — nothing is written to disk.
static func compile_hook_code(code: String) -> Dictionary:
	var scr := GDScript.new()
	scr.source_code = code
	var err := scr.reload()
	if err != OK:
		return {"instance": null, "error": "hook code failed to compile: %s" % error_string(err)}
	if not scr.can_instantiate():
		return {"instance": null, "error": "hook code cannot instantiate"}
	var inst: Variant = scr.new()
	if not (inst is ModHook):
		return {"instance": null, "error": "hook code does not extend ModHook"}
	return {"instance": inst as ModHook, "error": ""}


## Extracts the invented hooks from a ModCreator CANDIDATE (shape:
## mod_id/name/kind/manifest/payload/summary/error) WITHOUT installing
## anything. Block candidates: hooks parsed from the payload JSON.
## Script candidates: the script is compiled IN MEMORY and its
## get_hooks() read (its _init runs, which must stay side-effect free
## per the ModBlock contract). Returns an Array of hook dicts; a hook
## that fails validation is returned WITH an "error" key instead of
## being dropped, so the approval screen can show the problem.
static func preview_hooks_for_candidate(candidate: Dictionary) -> Array:
	var out: Array = []
	var kind := str(candidate.get("kind", ""))
	var payload := str(candidate.get("payload", ""))
	if kind == "block":
		var data: Variant = JSON.parse_string(payload)
		if not (data is Dictionary):
			return out
		var d := data as Dictionary
		var raw: Variant = d.get("hooks", null)
		if raw == null and d.has("block") and d["block"] is Dictionary:
			raw = (d["block"] as Dictionary).get("hooks", null)
		if not (raw is Array):
			return out
		for h in (raw as Array):
			if not (h is Dictionary):
				out.append({"hook_id": "", "hook_point": "", "error": "hook is not an object"})
				continue
			var copy: Dictionary = (h as Dictionary).duplicate(true)
			var err := validate_hook_data(copy)
			if err != "":
				copy["error"] = err
			out.append(copy)
		return out
	if kind == "script":
		if payload.strip_edges().is_empty():
			return out
		var scr := GDScript.new()
		scr.source_code = payload
		if scr.reload() != OK or not scr.can_instantiate():
			out.append({"hook_id": "", "hook_point": "", "error": "script failed to compile (hooks could not be previewed)"})
			return out
		var inst: Variant = scr.new()
		if not (inst is ModBlock):
			out.append({"hook_id": "", "hook_point": "", "error": "script does not extend ModBlock"})
			return out
		var raw_hooks: Variant = (inst as ModBlock).get_hooks()
		if not (raw_hooks is Array):
			out.append({"hook_id": "", "hook_point": "", "error": "get_hooks() did not return an Array"})
			return out
		for h in (raw_hooks as Array):
			if not (h is Dictionary):
				out.append({"hook_id": "", "hook_point": "", "error": "hook is not an object"})
				continue
			var copy: Dictionary = (h as Dictionary).duplicate(true)
			var err := validate_hook_data(copy)
			if err != "":
				copy["error"] = err
			out.append(copy)
		return out
	return out


## Approval-screen lines for a hook list (see preview_hooks_for_candidate).
## Every invented hook gets an EXPLICIT line — "this mod adds a new hook:
## X (hook point: Y)" — before Install. Invalid hooks get an error line.
static func summarize_hooks(hooks: Array) -> Array:
	var lines: Array = []
	for h in hooks:
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		var err := str(d.get("error", ""))
		if err != "":
			lines.append("Hook '%s' INVALID: %s" % [str(d.get("hook_id", "?")), err])
			continue
		var line := "This mod adds a new hook: %s (hook point: %s)" % [
			str(d.get("hook_id", "?")), str(d.get("hook_point", "?"))]
		var desc := str(d.get("description", "")).strip_edges()
		if not desc.is_empty():
			line += " — " + desc
		if d.has("projectile"):
			var proj: Dictionary = d.get("projectile", {})
			line += " [custom projectile: %s]" % str(proj.get("visual", "energy bolt"))
		lines.append(line)
	return lines


static func _is_num_in(v: Variant, lo: float, hi: float) -> bool:
	return (v is int or v is float) and float(v) >= lo and float(v) <= hi
