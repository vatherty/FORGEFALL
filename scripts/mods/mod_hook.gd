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
#     the ALLOWLIST validator (validate_hook_code, v0.5.6 route B —
#     the flip from the old blocklist scan): it may call ONLY ModAPI
#     methods (ModAPI.HOOK_ALLOWED_API_METHODS, the single authoritative
#     list) plus the safe builtins ModAPI documents. NO engine
#     internals, NO file/network/eval/dynamic loading, NO raw node
#     manipulation, NO ClassDB / GDScript.new / Expression / load /
#     preload. A violation is REJECTED with the violation named (e.g.
#     "hook script calls non-ModAPI (forbidden API): OS.execute").
#     The source also passes a compile check BEFORE it is ever
#     instantiated. At run time the instance receives ONLY a ModAPI +
#     a context Dictionary, under a step/time budget enforced by
#     ModHookRegistry (see ModAPI.HOOK_MAX_*). GDScript has no
#     try/catch: RECOVERABLE run-time errors (out-of-bounds index,
#     method on null) print an engine error and the call CONTINUES,
#     so the registry cannot detect them — such a hook completes.
#     ABORTING errors (stack overflow) synthesize a default return in
#     this engine version, so they cannot be detected by return value
#     either — the real guard is validation: call cycles (direct AND
#     mutual recursion) are rejected, which closes the overflow vector
#     for every hook that passes validation. A hook that exceeds its
#     step/time budget DISABLES ITS MOD VISIBLY (the registry records
#     the failure on the ModLoader record), never crashes.
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
# strings}, damage_mult {value 0-5}, and the STATUS kinds (v0.5.5 —
# the Bubble Blaster gap: slow was expressible nowhere before this):
# slow {factor 0.05-1.0, duration_sec 0.5-30}, freeze
# {duration_sec 0.5-10}, burn {damage_per_sec 1-500,
# duration_sec 0.5-30}, knockback {force 1-30}. Status kinds need a
# target: on_hit / on_kill (the hit target) or on_damage_taken (the
# player). They are REJECTED on fire points (no target exists yet).
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

const EFFECT_KINDS := ["heal", "explosion", "smoke", "announce", "damage_mult", "slow", "freeze", "burn", "knockback"]

## Status kinds: need a target, so they are rejected on fire points.
const STATUS_KINDS := ["slow", "freeze", "burn", "knockback"]

const HOOK_KEYS := ["hook_id", "hook_point", "display_name", "description", "projectile", "effects", "code"]

const EFFECT_KEYS := ["kind", "amount", "radius", "damage", "duration_sec", "title", "subtitle", "value", "factor", "damage_per_sec", "force"]

const MAX_HOOK_CODE_CHARS := 20000

## Max effects entries in one data hook (bounds interpreted dispatch:
## each effect is one ModAPI call; a hook with more is rejected).
const MAX_HOOK_EFFECTS := 64


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
		if str(k) not in HOOK_KEYS and str(k) not in ["_instance", "_mod_id"]:
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
		if (effs as Array).size() > MAX_HOOK_EFFECTS:
			return "hook '%s' effects exceed %d entries (data hooks are bounded — use code hooks for longer sequences, still under budget)" % [str(hid), MAX_HOOK_EFFECTS]
		for eff in (effs as Array):
			if not (eff is Dictionary):
				return "hook '%s' has a non-object effect" % str(hid)
			var eerr := validate_effect(eff as Dictionary)
			if eerr != "":
				return "hook '%s' effect: %s" % [str(hid), eerr]
			if str((eff as Dictionary).get("kind", "")) in STATUS_KINDS and is_fire_point(norm):
				return "hook '%s' effect '%s' needs a target — status effects go on on_hit / on_kill / on_damage_taken, not '%s'" % [str(hid), str((eff as Dictionary).get("kind", "")), norm]
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
		return "effect 'kind' must be heal|explosion|smoke|announce|damage_mult|slow|freeze|burn|knockback"
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
		"slow":
			if not _is_num_in(eff.get("factor", null), 0.05, 1.0):
				return "slow effect 'factor' out of range 0.05-1.0"
			if not _is_num_in(eff.get("duration_sec", null), 0.5, 30.0):
				return "slow effect 'duration_sec' out of range 0.5-30"
		"freeze":
			if not _is_num_in(eff.get("duration_sec", null), 0.5, 10.0):
				return "freeze effect 'duration_sec' out of range 0.5-10"
		"burn":
			if not _is_num_in(eff.get("damage_per_sec", null), 1.0, 500.0):
				return "burn effect 'damage_per_sec' out of range 1-500"
			if not _is_num_in(eff.get("duration_sec", null), 0.5, 30.0):
				return "burn effect 'duration_sec' out of range 0.5-30"
		"knockback":
			if not _is_num_in(eff.get("force", null), 1.0, 30.0):
				return "knockback effect 'force' out of range 1-30"
	return ""


## Validates hook CODE (a GDScript source string): ALLOWLIST
## enforcement (v0.5.6 route B — this is the flip from the old
## blocklist scan). The script may call ONLY:
##   - `api.<method>` for <method> in ModAPI.HOOK_ALLOWED_API_METHODS,
##   - `ctx.<method>` for <method> in ModAPI.HOOK_ALLOWED_CTX_METHODS,
##   - bare globals in ModAPI.HOOK_ALLOWED_BUILTIN_CALLS,
##   - types in ModAPI.HOOK_ALLOWED_TYPES (annotations / `is` / `as`),
##   - methods in ModAPI.HOOK_ALLOWED_SAFE_METHODS on its own locals
##     and on values chained off a call, plus HOOK_ALLOWED_COMPONENTS.
## Everything else is a violation, REJECTED with the violation named
## (e.g. "hook script calls non-ModAPI (forbidden API): OS.execute").
## Structural rules, also enforced here: `extends ModHook`,
## `run(api, ctx)` present, no engine callbacks (`_init`, `_process`,
## ...), no anonymous functions, no `while` loops (unbounded — use a
## bounded `for`), no `range()` literal over HOOK_MAX_RANGE_LITERAL, no
## recursion, no `@` annotations, no `$` node-path lookups.
## "" = OK, else an error naming the violation. Never repairs.
## NOTE: strings/comments are stripped before analysis, so a forbidden
## name inside a string literal ("OS.execute" as text) is inert and
## does NOT trip the validator — only real code is judged.
static func validate_hook_code(code: String) -> String:
	if code.length() > MAX_HOOK_CODE_CHARS:
		return "hook code exceeds %d chars" % MAX_HOOK_CODE_CHARS
	var cleaned := _strip_hook_strings_comments(code)
	var extends_ok := false
	for raw_line in cleaned.split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("extends "):
			extends_ok = (line == "extends ModHook")
			break
		if line.begins_with("extends\t"):
			extends_ok = (line == "extends\tModHook")
			break
	if not extends_ok:
		return "hook code must 'extend ModHook'"
	if not cleaned.contains("func run("):
		return "hook code must implement run(api, ctx)"
	return _validate_hook_allowlist(cleaned)


## The allowlist engine. `cleaned` is hook code with strings/comments
## stripped (see _strip_hook_strings_comments). "" = OK, else an error
## naming the violation.
static func _validate_hook_allowlist(cleaned: String) -> String:
	# --- Whole-word forbidden tokens (keywords / annotations) --------
	var kw := RegEx.new()
	kw.compile("\\b(await|yield|while|preload|super|signal|enum|class|static|breakpoint)\\b")
	if kw.search(cleaned) != null:
		var m := kw.search(cleaned)
		return "hook script calls non-ModAPI (forbidden API): '%s' is not allowed in hook code" % m.get_string()
	if cleaned.contains("@"):
		return "hook script calls non-ModAPI (forbidden API): '@' annotations are not allowed in hook code"
	if cleaned.contains("$"):
		return "hook script calls non-ModAPI (forbidden API): '$' node-path lookup is raw node access, not allowed in hook code"
	var anon := RegEx.new()
	anon.compile("\\bfunc\\s*\\(")
	if anon.search(cleaned) != null:
		return "hook script calls non-ModAPI (forbidden API): anonymous functions (func(...) lambdas) are not allowed in hook code"
	# --- Function definitions: names, params, engine callbacks -------
	var func_re := RegEx.new()
	func_re.compile("(?m)^[ \\t]*func[ \\t]+([A-Za-z_]\\w*)[ \\t]*\\(")
	var func_names: Array[String] = []
	var func_headers: Array[Dictionary] = []
	for fm in func_re.search_all(cleaned):
		var fname := fm.get_string(1)
		func_names.append(fname)
		var open_idx := fm.get_start(0) + fm.get_string(0).length() - 1
		var close_idx := _matching_paren(cleaned, open_idx)
		var params := ""
		if close_idx > open_idx:
			params = cleaned.substr(open_idx + 1, close_idx - open_idx - 1)
		func_headers.append({"name": fname, "params": params,
			"body_start": close_idx + 1 if close_idx >= 0 else fm.get_end(0),
			"start": fm.get_start(0)})
	var ENGINE_CALLBACKS := ["_init", "_process", "_physics_process", "_ready",
		"_enter_tree", "_exit_tree", "_notification", "_input",
		"_unhandled_input", "_unhandled_key_input", "_shortcut_input", "_get",
		"_set", "_get_property_list", "_validate_property", "_to_string"]
	for h in func_headers:
		if str(h.get("name", "")) in ENGINE_CALLBACKS:
			return "hook script calls non-ModAPI (forbidden API): engine callback '%s' is not allowed in hook code" % str(h.get("name", ""))
	# Call cycles (direct AND mutual recursion): a recursing hook
	# overflows the stack at run time, and the engine synthesizes a
	# default return on abort — the registry CANNOT detect that by
	# return value — so cycles are rejected here, at validation.
	# (Direct recursion is the 1-cycle case of the same check.)
	var call_edges := {}
	for i in range(func_headers.size()):
		var h3: Dictionary = func_headers[i]
		var bend := cleaned.length()
		if i + 1 < func_headers.size():
			bend = int((func_headers[i + 1] as Dictionary).get("start", bend))
		var fbody := cleaned.substr(int(h3.get("body_start", 0)), bend - int(h3.get("body_start", 0)))
		var callees: Array[String] = []
		var call_re := RegEx.new()
		call_re.compile("\\b(?:self\\s*\\.\\s*)?([A-Za-z_]\\w*)\\s*\\(")
		for cm in call_re.search_all(fbody):
			var callee := cm.get_string(1)
			if callee in func_names and callee not in callees:
				callees.append(callee)
		call_edges[str(h3.get("name", ""))] = callees
	for fname in func_names:
		var cycle := _find_call_cycle(str(fname), call_edges)
		if not cycle.is_empty():
			return "hook script calls non-ModAPI (forbidden API): call cycle %s (recursion is not allowed in hook code)" % " -> ".join(cycle)
	# --- Declared identifiers (locals the hook itself introduces) ----
	var declared := {"_": true, "api": true, "ctx": true}
	for h in func_headers:
		declared[str(h.get("name", ""))] = true
		for param in _split_top_level(str(h.get("params", "")), ","):
			var pm := RegEx.new()
			pm.compile("^\\s*([A-Za-z_]\\w*)")
			var pmm := pm.search(param)
			if pmm != null:
				declared[pmm.get_string(1)] = true
	var var_re := RegEx.new()
	var_re.compile("\\b(var|const)[ \\t]+([A-Za-z_]\\w*)")
	for vm in var_re.search_all(cleaned):
		declared[vm.get_string(2)] = true
	var for_re := RegEx.new()
	for_re.compile("\\bfor[ \\t]+([A-Za-z_]\\w*)[ \\t]+in\\b")
	for frm in for_re.search_all(cleaned):
		declared[frm.get_string(1)] = true
	# --- range() literal cap ------------------------------------------
	var range_re := RegEx.new()
	range_re.compile("range\\s*\\(")
	for rm in range_re.search_all(cleaned):
		var open_r := rm.get_start(0) + rm.get_string(0).length() - 1
		var close_r := _matching_paren(cleaned, open_r)
		if close_r > open_r:
			var args := cleaned.substr(open_r + 1, close_r - open_r - 1)
			var num_re := RegEx.new()
			num_re.compile("\\b\\d+\\b")
			for nm in num_re.search_all(args):
				if int(nm.get_string()) > ModAPI.HOOK_MAX_RANGE_LITERAL:
					return "hook script calls non-ModAPI (forbidden API): range() literal %s exceeds %d (runaway-loop bound)" % [nm.get_string(), ModAPI.HOOK_MAX_RANGE_LITERAL]
	# --- Dotted access: receiver.member --------------------------------
	var dot_re := RegEx.new()
	dot_re.compile("([A-Za-z_]\\w*)\\s*\\.\\s*([A-Za-z_]\\w*)")
	for dm in dot_re.search_all(cleaned):
		var receiver := dm.get_string(1)
		var member := dm.get_string(2)
		if member == "new":
			return "hook script calls non-ModAPI (forbidden API): %s.new (dynamic instantiation is not allowed in hook code)" % receiver
		var derr := _check_dotted(receiver, member, func_names, declared)
		if derr != "":
			return derr
	# Chained off a call / literal: `).member`, `].member`, `}.member`.
	# Only safe value methods / components / constants may follow.
	var chain_re := RegEx.new()
	chain_re.compile("[\\)\\]\\}]\\s*\\.\\s*([A-Za-z_]\\w*)")
	for cm in chain_re.search_all(cleaned):
		var cmember := cm.get_string(1)
		if cmember == "new":
			return "hook script calls non-ModAPI (forbidden API): .new (dynamic instantiation is not allowed in hook code)"
		if not (cmember in ModAPI.HOOK_ALLOWED_SAFE_METHODS
				or cmember in ModAPI.HOOK_ALLOWED_COMPONENTS
				or _is_all_caps(cmember)):
			return "hook script calls non-ModAPI (forbidden API): .%s after a call (only safe value methods may follow a call in hook code)" % cmember
	# --- Bare identifiers ----------------------------------------------
	var kwds := {"extends": true, "func": true, "var": true, "const": true,
		"if": true, "elif": true, "else": true, "for": true, "in": true,
		"match": true, "return": true, "break": true, "continue": true,
		"pass": true, "and": true, "or": true, "not": true, "is": true,
		"as": true, "self": true, "true": true, "false": true, "null": true,
		"void": true, "PI": true, "TAU": true, "INF": true, "NAN": true}
	var id_re := RegEx.new()
	id_re.compile("([A-Za-z_]\\w*)")
	var depth := 0
	var last_end := 0
	for im in id_re.search_all(cleaned):
		var gap := cleaned.substr(last_end, im.get_start(0) - last_end)
		for ch in gap:
			if ch == "{":
				depth += 1
			elif ch == "}":
				depth -= 1
		last_end = im.get_end(0)
		var ident := im.get_string(1)
		# Member name (preceded by `.`) or receiver (followed by `.`):
		# already judged by the dotted check above.
		var before := _prev_nonspace(cleaned, im.get_start(0))
		if before == ".":
			continue
		var after := _next_nonspace(cleaned, im.get_end(0))
		if after == ".":
			continue
		if ident in kwds or ident in declared:
			continue
		if ident in ModAPI.HOOK_ALLOWED_TYPES:
			continue
		if ident in ModAPI.HOOK_ALLOWED_BUILTIN_CALLS:
			continue
		# Dict key: `ident:` inside braces (e.g. `{healed: 5.0}`).
		if after == ":" and depth > 0:
			continue
		return "hook script calls non-ModAPI (forbidden API): %s (only ModAPI + safe builtins allowed in hook code)" % ident
	return ""


## Judges ONE `receiver.member` pair. "" = allowed, else the violation.
static func _check_dotted(receiver: String, member: String, func_names: Array[String], declared: Dictionary) -> String:
	if receiver == "api":
		if member in ModAPI.HOOK_ALLOWED_API_METHODS:
			return ""
		return "hook script calls non-ModAPI (forbidden API): api.%s (not a ModAPI method)" % member
	if receiver == "ctx":
		if member in ModAPI.HOOK_ALLOWED_CTX_METHODS:
			return ""
		return "hook script calls non-ModAPI (forbidden API): ctx.%s (ctx is read-only; only %s)" % [member, ", ".join(ModAPI.HOOK_ALLOWED_CTX_METHODS)]
	if receiver == "self":
		if member in func_names:
			return ""
		return "hook script calls non-ModAPI (forbidden API): self.%s (only own helper functions)" % member
	if receiver in ModAPI.HOOK_ALLOWED_TYPES or _is_all_caps(receiver):
		if _is_all_caps(member) or member in ModAPI.HOOK_ALLOWED_SAFE_METHODS:
			return ""
		return "hook script calls non-ModAPI (forbidden API): %s.%s" % [receiver, member]
	if receiver in declared:
		if member in ModAPI.HOOK_ALLOWED_SAFE_METHODS \
				or member in ModAPI.HOOK_ALLOWED_COMPONENTS \
				or _is_all_caps(member):
			return ""
		return "hook script calls non-ModAPI (forbidden API): %s.%s (raw node access is not allowed in hook code)" % [receiver, member]
	return "hook script calls non-ModAPI (forbidden API): %s.%s" % [receiver, member]


## True when `s` is an ALL_CAPS constant name (ZERO, RED, AXIS_X, ...).
static func _is_all_caps(s: String) -> bool:
	if s.is_empty():
		return false
	for ch in s:
		if not ("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".contains(ch)):
			return false
	return true


## Depth-first search for a call cycle starting at `start` in the
## call graph `edges` (func name -> called func names). Returns the
## cycle path (e.g. ["a", "b", "a"]), or [] when none.
static func _find_call_cycle(start: String, edges: Dictionary) -> Array[String]:
	var visited: Array[String] = []
	var stack: Array[String] = []
	return _cycle_dfs(start, start, edges, visited, stack)


static func _cycle_dfs(node: String, start: String, edges: Dictionary, visited: Array[String], stack: Array[String]) -> Array[String]:
	if node in stack:
		if node == start:
			var cyc := stack.duplicate()
			cyc.append(node)
			return cyc
		return []
	if node in visited:
		return []
	visited.append(node)
	stack.append(node)
	var nexts: Array = edges.get(node, [])
	for nxt in nexts:
		var found := _cycle_dfs(str(nxt), start, edges, visited, stack)
		if not found.is_empty():
			return found
	stack.pop_back()
	return []
## replacing their contents with spaces (newlines preserved, so line
## structure survives). Handles '...', "...", '''...''', \"\"\"...\"\"\"
## and backslash escapes. The validator judges real code only.
static func _strip_hook_strings_comments(code: String) -> String:
	var out := PackedStringArray()
	var i := 0
	var n := code.length()
	var state := ""  # "" | "#" | "'" | '"' | "'''" | '"""'
	while i < n:
		var ch := code[i]
		if state == "":
			if ch == "#":
				state = "#"
				out.append(" ")
				i += 1
			elif ch == "'":
				if code.substr(i, 3) == "'''":
					state = "'''"
					out.append("   ")
					i += 3
				else:
					state = "'"
					out.append(" ")
					i += 1
			elif ch == '"':
				if code.substr(i, 3) == '"""':
					state = '"""'
					out.append("   ")
					i += 3
				else:
					state = '"'
					out.append(" ")
					i += 1
			else:
				out.append(ch)
				i += 1
		elif state == "#":
			if ch == "\n":
				state = ""
				out.append("\n")
			else:
				out.append(" ")
			i += 1
		elif state == "'" or state == '"':
			if ch == "\\" and i + 1 < n:
				out.append("  ")
				i += 2
			elif ch == "\n":
				state = ""
				out.append("\n")
				i += 1
			elif ch == state:
				state = ""
				out.append(" ")
				i += 1
			else:
				out.append(" ")
				i += 1
		else:  # triple-quoted
			if ch == "\\" and i + 1 < n:
				out.append("  ")
				i += 2
			elif code.substr(i, 3) == state:
				state = ""
				out.append("   ")
				i += 3
			elif ch == "\n":
				out.append("\n")
				i += 1
			else:
				out.append(" ")
				i += 1
	return "".join(out)


## Index of the `)` matching the `(` at `open_idx` (-1 when unbalanced).
static func _matching_paren(text: String, open_idx: int) -> int:
	var depth := 0
	for i in range(open_idx, text.length()):
		var ch := text[i]
		if ch == "(":
			depth += 1
		elif ch == ")":
			depth -= 1
			if depth == 0:
				return i
	return -1


## Splits `s` on `sep` at nesting depth 0 for ()[]{}.
static func _split_top_level(s: String, sep: String) -> Array[String]:
	var out: Array[String] = []
	var depth := 0
	var cur := ""
	for ch in s:
		if ch in ["(", "[", "{"]:
			depth += 1
		elif ch in [")", "]", "}"]:
			depth -= 1
		if ch == sep and depth == 0:
			out.append(cur)
			cur = ""
		else:
			cur += ch
	out.append(cur)
	return out


## Previous non-whitespace char before `idx` ("" when none).
static func _prev_nonspace(text: String, idx: int) -> String:
	var j := idx - 1
	while j >= 0:
		var ch := text[j]
		if ch != " " and ch != "\t" and ch != "\n" and ch != "\r":
			return ch
		j -= 1
	return ""


## Next non-whitespace char at/after `idx` ("" when none).
static func _next_nonspace(text: String, idx: int) -> String:
	var j := idx
	while j < text.length():
		var ch := text[j]
		if ch != " " and ch != "\t" and ch != "\n" and ch != "\r":
			return ch
		j += 1
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
		if d.has("effects") and d.get("effects") is Array:
			var eff_lines: Array[String] = []
			for eff in (d.get("effects", []) as Array):
				if eff is Dictionary:
					eff_lines.append(_describe_effect(eff as Dictionary))
			if not eff_lines.is_empty():
				line += " | Effects: " + ", ".join(eff_lines)
		lines.append(line)
	return lines


## One-line human summary of a data-hook effect, so the approval
## screen shows status effects ("slow x0.5 for 3.0s") instead of
## leaving them visible only in the raw payload.
static func _describe_effect(eff: Dictionary) -> String:
	match str(eff.get("kind", "")):
		"heal":
			return "heal %.0f" % float(eff.get("amount", 0.0))
		"explosion":
			return "explosion r%.0f d%.0f" % [float(eff.get("radius", 0.0)), float(eff.get("damage", 0.0))]
		"smoke":
			return "smoke %.0fs" % float(eff.get("duration_sec", 0.0))
		"announce":
			return "announce '%s'" % str(eff.get("title", ""))
		"damage_mult":
			return "damage x%.2f" % float(eff.get("value", 1.0))
		"slow":
			return "slow x%.2f for %.1fs" % [float(eff.get("factor", 1.0)), float(eff.get("duration_sec", 0.0))]
		"freeze":
			return "freeze %.1fs" % float(eff.get("duration_sec", 0.0))
		"burn":
			return "burn %.0f dps for %.1fs" % [float(eff.get("damage_per_sec", 0.0)), float(eff.get("duration_sec", 0.0))]
		"knockback":
			return "knockback %.0f" % float(eff.get("force", 0.0))
	return str(eff.get("kind", "?"))


static func _is_num_in(v: Variant, lo: float, hi: float) -> bool:
	return (v is int or v is float) and float(v) >= lo and float(v) <= hi
