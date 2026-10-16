# FORGEFALL — verify_effects_catalog (v0.5.7: Worker C verification)
# Verifies Worker A's effects catalog + Worker B's structures, end to end.
#
# EFFECTS — every effect kind in ModHook.EFFECT_KINDS, through the whole
# pipeline the player actually touches:
#   generation prompt catalog mentions it ("kind": "x" table entry in
#   ModCreator.HOOK_PROMPT_ADDENDUM and the `x {params}` entry in
#   ForgeLLM.GENERATION_SYSTEM_PROMPT)
#   -> approval lists it (ModHook.summarize_hooks shows the kind WITH its
#      params, so the player can tell what it does — a bare kind token
#      with no params FAILS: "blind" alone tells the player nothing)
#   -> sandbox reports it visibly (status kinds: status_effects contains
#      the kind; instant kinds: the hook ran / its legacy channel fired)
#   -> in-game applies + wears off (registry run_hooks applies it to a
#      real target; the gameplay value moves; tick past duration and the
#      effect is gone + the value is restored)
# The loop is DATA-DRIVEN off ModHook.EFFECT_KINDS, so it covers every
# kind Worker A implemented, whatever names they chose. Kinds with
# unknown param shapes fall back to a generic probe battery; a kind no
# probe validates is a FAIL naming the kind (add its shape to the table).
# WORKER A'S CATALOG (v0.5.7, as implemented — the suite verifies THIS
# catalog, not a guessed one): 13 new status kinds — pull (instant yank
# toward origin), poison (DoT + slow x0.85), bleed (DoT, faster while
# moving), regen (heal over time), haste (speed x1.05-2.5), restrained
# (speed 0, can act), prone (knockdown impulse + speed 0), sleep (speed
# 0, pinned, wakes on damage), confusion (random stumble impulses),
# blind (accuracy x factor), weaken (damage dealt x factor), exhaustion
# (+1 level per application, speed -15%/level, 6 = death), typed_damage
# (instant damage of one D&D damage type + a rider). Names are A's:
# blind (not blinded), poison (not poisoned).
# FAMILIES (explicit, per the v0.5.7 brief):
#   D&D 5e conditions: A implemented 5 — blind (blinded), poison
#     (poisoned), restrained, prone, exhaustion — and v0.5.9 added a
#     6th, petrified, via the take_damage hook. The other 7 named
#     conditions (charmed, frightened, grappled, paralyzed, stunned,
#     deafened, unconscious) are DELIBERATELY OMITTED: they are on
#     BOTH prompts' do-not-invent lists, must NOT be in EFFECT_KINDS,
#     must NOT be offered as kinds by either prompt, and the validator
#     must reject them. incapacitated / invisible are neither
#     implemented nor named in the do-not-invent lists — the suite
#     reports them as INFO (prompt-gap note), not FAIL.
#   Damage types: the 9 in ModStatusEffects.TYPED_DAMAGE_TYPES (acid,
#     cold, fire, lightning, necrotic, poison, psychic, radiant,
#     thunder) via the typed_damage kind. Physical types (bludgeoning /
#     piercing / slashing) are excluded by design (untyped = physical);
#     the validator must reject them as damage_type values, like any
#     other invalid type ("laser"). Every type must validate, both
#     prompts must offer every type, and every type's rider must fire
#     in-game (fire->burn, cold->slow, lightning->knockback,
#     thunder->knockback+prone, acid->weaken, necrotic->exhaustion,
#     poison->poison, psychic->confusion, radiant->blind). There is NO
#     damage-resistance system by design — the rider is what makes the
#     type real.
#   Classic RPG effects: A implemented pull / bleed / weaken / sleep /
#     confusion / regen / haste; v0.5.9 added shield / vulnerable /
#     thorns (damage-interception states via the take_damage hook).
#     lifesteal is DELIBERATELY OMITTED (on the prompts' do-not-invent
#     lists — no damage-dealt hook exists to implement it genuinely).
# STRUCTURES (Worker B):
#   - The Forge prompt (SYSTEM_PROMPT) contains the full structure
#     catalog (all 10 shapes) + documents the diagonal ramp.
#   - Diagonal ramp: "build a diagonal ramp" parses to a ramp structure
#     spec carrying a rotation (~45 deg, any of rotation_deg / rotation
#     / yaw / angle, or a diagonal_ramp shape); the validator accepts
#     the rotation key; the BUILT geometry measures diagonal (footprint
#     extents in world X and Z both large — a rotated ramp — vs the
#     straight-ramp control whose long axis dominates one axis).
#   - Inexpressible geometry (spiral staircase, dome, sphere, curved
#     wall, circular tower) -> a VISIBLE message (offline _error /
#     refusal / gate rejection / FORGE_FAIL) or a build message that
#     LABELS the approximation ("approximate / closest / instead /
#     ..."). A plain success message for a DIFFERENT shape is a SILENT
#     WRONG BUILD and FAILS.
# REGRESSION GUARDS (small in-suite contract checks; the full suites are
# run separately): legacy validation, sandbox legacy slow, registry
# legacy heal, offline "knife" still unknown, invented fields rejected,
# unknown structure shape still FORGE_FAIL, creator prompt still
# documents slow.
# Run: godot --headless --path . --script res://tools/verify_effects_catalog.gd
# Exit code 0 = all checks passed. NO network: offline parser only.
extends SceneTree

var _fails := 0
var _checks := 0
var _ran := false

var _ModHook: GDScript
var _ModAPI: GDScript
var _ModStatus: GDScript
var _Sandbox: GDScript
var _Registry: GDScript
var _ForgeLLM: GDScript
var _ForgeBuilder: GDScript

var _creator_src := ""
var _creator_prompt := ""
var _forge_src := ""
var _forge_prompt := ""
var _forge_gen_prompt := ""
var _effect_kinds: Array = []
var _status_kinds: Array = []
var _arena: Node3D
var _player: Node3D


class TestDummy extends CharacterBody3D:
	var hp := 100.0
	var dead := false
	# Stat handles for blind (accuracy) / weaken (damage) — the "self"
	# path of ModStatusEffects._apply_stat_scale needs these, exactly
	# like enemies carry them. Without them blind/weaken legitimately
	# return false ("no handle on this target").
	var accuracy := 1.0
	var damage := 10.0
	func take_damage(amount: float, _pos: Vector3, _head: bool) -> void:
		hp -= amount
		if hp <= 0.0:
			dead = true
	func is_dead() -> bool:
		return dead


const LEGACY_KINDS := ["heal", "explosion", "smoke", "announce", "damage_mult", "slow", "freeze", "burn", "knockback"]
## D&D 5e condition name -> Worker A's kind (the 5 A implemented).
const CONDITION_IMPLEMENTED := {"blinded": "blind", "poisoned": "poison", "restrained": "restrained", "prone": "prone", "exhaustion": "exhaustion", "petrified": "petrified"}
## D&D 5e conditions on BOTH prompts' do-not-invent lists.
const CONDITION_OMITTED := ["stunned", "paralyzed", "unconscious", "grappled", "frightened", "charmed", "deafened"]
## 5e conditions neither implemented nor named in the do-not-invent lists.
const CONDITION_UNLISTED := ["incapacitated", "invisible"]
## The prompts' full do-not-invent list (ForgeLLM + creator, verbatim).
const DO_NOT_INVENT := ["stunned", "paralyzed", "unconscious", "grappled", "frightened", "charmed", "deafened", "silence", "lifesteal", "curse"]
## D&D damage types Worker A implemented (ModStatusEffects.TYPED_DAMAGE_TYPES).
const DAMAGE_TYPES := ["acid", "cold", "fire", "lightning", "necrotic", "poison", "psychic", "radiant", "thunder"]
## Classic RPG effects Worker A implemented.
const CLASSIC_IMPLEMENTED := ["pull", "bleed", "weaken", "sleep", "confusion", "regen", "haste", "shield", "vulnerable", "thorns"]
const STRUCTURE_SHAPES := ["bridge", "bunker", "watchtower", "ammo_depot", "stairs", "ramp", "wall", "jump_pad", "cover_piece", "sniper_nest"]
const ROTATION_KEYS := ["rotation_deg", "rotation", "yaw", "angle"]
const APPROX_WORDS := ["approximat", "closest", "instead", "similar", "not exact", "straight", "square", "rectangular"]
const INEXPRESSIBLE := ["build a spiral staircase", "build a dome", "build a sphere", "build a curved wall", "build a circular tower"]
const GENERIC_PROBES := [
	{"duration_sec": 5.0},
	{},
	{"amount": 10.0},
	{"factor": 0.5, "duration_sec": 5.0},
	{"damage_per_sec": 10.0, "duration_sec": 5.0},
	{"force": 10.0},
	{"value": 2.0},
	{"damage_type": "fire", "duration_sec": 5.0},
	{"heal_per_sec": 10.0, "duration_sec": 5.0},
]


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % label)
	else:
		_fails += 1
		print("FAIL: %s" % label)


func _info(msg: String) -> void:
	print("INFO: %s" % msg)


func _init() -> void:
	pass


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_ModHook = load("res://scripts/mods/mod_hook.gd")
	_ModAPI = load("res://scripts/mods/mod_api.gd")
	_ModStatus = load("res://scripts/mods/mod_status_effects.gd")
	_Sandbox = load("res://scripts/ui/sandbox_test_room.gd")
	_Registry = load("res://scripts/mods/mod_hook_registry.gd")
	_ForgeLLM = load("res://scripts/forge/forge_llm.gd")
	_ForgeBuilder = load("res://scripts/forge/forge_builder.gd")
	_creator_src = FileAccess.get_file_as_string("res://scripts/mods/mod_creator.gd")
	_creator_prompt = _extract_triple_quoted(_creator_src, "HOOK_PROMPT_ADDENDUM")
	if _creator_prompt.is_empty():
		_creator_prompt = _creator_src
		_info("HOOK_PROMPT_ADDENDUM extraction fell back to whole-file source")
	_forge_src = FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	_forge_prompt = _extract_triple_quoted(_forge_src, "SYSTEM_PROMPT")
	if _forge_prompt.is_empty():
		_forge_prompt = _forge_src
		_info("SYSTEM_PROMPT extraction fell back to whole-file source")
	_forge_gen_prompt = _extract_triple_quoted(_forge_src, "GENERATION_SYSTEM_PROMPT")
	if _forge_gen_prompt.is_empty():
		_forge_gen_prompt = _forge_src
		_info("GENERATION_SYSTEM_PROMPT extraction fell back to whole-file source")
	_effect_kinds = _load_kind_const("EFFECT_KINDS")
	_status_kinds = _load_kind_const("STATUS_KINDS")
	_arena = Node3D.new()
	_arena.name = "VerifyArena"
	root.add_child(_arena)
	_player = Node3D.new()
	_player.name = "VerifyPlayer"
	_arena.add_child(_player)
	_test_catalog_consistency()
	_test_forge_prompts()
	_test_per_kind_loop()
	_test_data_hook_dispatch()
	_test_conditions()
	_test_omitted()
	_test_damage_types()
	_test_classic_rpg()
	_test_structures()
	_test_regression_guards()
	print("verify_effects_catalog: %d checks, %d failures" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
	return true


# --- helpers ---------------------------------------------------------------

func _join(parts: Array, sep: String) -> String:
	var out := ""
	for i in range(parts.size()):
		if i > 0:
			out += sep
		out += str(parts[i])
	return out


func _extract_triple_quoted(src: String, const_name: String) -> String:
	var idx := src.find("const " + const_name)
	if idx < 0:
		return ""
	var open := src.find('"""', idx)
	if open < 0:
		return ""
	var close := src.find('"""', open + 3)
	if close < 0:
		return ""
	return src.substr(open + 3, close - open - 3)


func _load_kind_const(const_name: String) -> Array:
	var v: Variant = _ModHook.get(const_name)
	if v is Array:
		return v as Array
	var parsed := _parse_const_list("res://scripts/mods/mod_hook.gd", const_name)
	if parsed.is_empty():
		_info("could not read ModHook.%s (script .get() + source parse both empty)" % const_name)
	return parsed


func _parse_const_list(path: String, const_name: String) -> Array:
	var src := FileAccess.get_file_as_string(path)
	var idx := src.find("const " + const_name)
	if idx < 0:
		return []
	var open := src.find("[", idx)
	var close := src.find("]", open)
	if open < 0 or close < 0:
		return []
	var out: Array = []
	for part in src.substr(open + 1, close - open - 1).split(","):
		var t := str(part).strip_edges().replace('"', "").strip_edges()
		if not t.is_empty():
			out.append(t)
	return out


func _src_file(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _params_of(effect: Dictionary) -> Dictionary:
	var out := effect.duplicate(true)
	out.erase("kind")
	return out


func _hook_with(kind: String, params: Dictionary, point: String) -> Dictionary:
	var eff := {"kind": kind}
	for k in params.keys():
		eff[k] = params[k]
	return {"hook_id": "verify_" + kind, "hook_point": point,
		"display_name": "Verify " + kind, "description": "verification probe",
		"effects": [eff]}


func _validate_hook(hook: Dictionary) -> String:
	var copy: Dictionary = hook.duplicate(true)
	return str(_ModHook.call("validate_hook_data", copy))


func _probes_for(kind: String) -> Array:
	match kind:
		"heal":
			return [{"amount": 15.0}]
		"explosion":
			return [{"radius": 4.0, "damage": 60.0}]
		"smoke":
			return [{"duration_sec": 20.0}]
		"announce":
			return [{"title": "Test", "subtitle": "Effect"}]
		"damage_mult":
			return [{"value": 2.0}]
		"slow":
			return [{"factor": 0.5, "duration_sec": 5.0}]
		"freeze":
			return [{"duration_sec": 2.0}]
		"burn":
			return [{"damage_per_sec": 10.0, "duration_sec": 2.5}]
		"knockback":
			return [{"force": 12.0}]
		"pull":
			return [{"force": 12.0}]
		"poison", "bleed":
			return [{"damage_per_sec": 10.0, "duration_sec": 5.0}]
		"regen":
			return [{"heal_per_sec": 10.0, "duration_sec": 3.0}]
		"haste":
			return [{"factor": 1.5, "duration_sec": 5.0}]
		"restrained", "sleep", "exhaustion":
			return [{"duration_sec": 5.0}]
		"prone":
			return [{"force": 12.0, "duration_sec": 5.0}]
		"confusion":
			return [{"force": 5.0, "duration_sec": 5.0}]
		"blind", "weaken":
			return [{"factor": 0.5, "duration_sec": 5.0}]
		"shield":
			return [{"amount": 50.0, "duration_sec": 5.0}]
		"vulnerable":
			return [{"factor": 2.0, "duration_sec": 5.0}]
		"thorns":
			return [{"reflect_mult": 0.5, "duration_sec": 5.0}]
		"petrified":
			return [{"duration_sec": 5.0}]
		"typed_damage":
			return [{"damage_type": "fire", "amount": 20.0, "duration_sec": 5.0}]
	return []


## Finds a validating effect dict for `kind`: table probes first, then
## the generic battery. {"effect": Dictionary, "validated": bool}.
func _find_effect(kind: String) -> Dictionary:
	var attempts: Array = []
	attempts.append_array(_probes_for(kind))
	attempts.append_array(GENERIC_PROBES)
	for probe in attempts:
		var p := probe as Dictionary
		var hook := _hook_with(kind, p, "on_hit")
		if _validate_hook(hook) == "":
			var eff := {"kind": kind}
			for k in p.keys():
				eff[k] = p[k]
			return {"effect": eff, "validated": true}
	return {"effect": {"kind": kind}, "validated": false}


func _gameplay_for(kind: String) -> String:
	match kind:
		"slow":
			return "speed_eq_factor"
		"freeze", "restrained", "prone", "sleep":
			return "speed_zero"
		"poison":
			return "poison"
		"burn", "bleed":
			return "hp_down"
		"regen":
			return "hp_up"
		"haste":
			return "speed_boost"
		"knockback", "pull":
			return "impulse"
		"confusion":
			return "stumble"
		"blind":
			return "blind"
		"weaken":
			return "weaken"
		"exhaustion":
			return "exhaustion"
		"shield":
			return "shield_pool"
		"vulnerable":
			return "vuln_mult"
		"thorns":
			return "thorns_state"
		"petrified":
			return "petrified"
	return "active_only"


func _line_has_number(line: String, effect: Dictionary) -> bool:
	var has_num_param := false
	for k in effect.keys():
		if effect[k] is int or effect[k] is float:
			has_num_param = true
			break
	if not has_num_param:
		return true
	for ch in line:
		if ch >= "0" and ch <= "9":
			return true
	return false


func _approval_line(effect: Dictionary, point: String) -> String:
	var kind := str(effect.get("kind", ""))
	var hook := _hook_with(kind, _params_of(effect), point)
	var lines: Variant = _ModHook.call("summarize_hooks", [hook])
	if lines is Array and not (lines as Array).is_empty():
		return str((lines as Array)[0])
	return ""


func _sandbox_for(effect: Dictionary, point: String) -> Dictionary:
	var kind := str(effect.get("kind", ""))
	var hook := _hook_with(kind, _params_of(effect), point)
	var behavior := {"projectile": true,
		"projectile_spec": {"visual": "test bolt", "speed": 22.0, "damage": 10.0},
		"hooks": [hook], "heal_on_kill": 0.0}
	var res: Variant = _Sandbox.call("simulate_test", {}, {"voxel_count": 81}, behavior)
	if res is Dictionary:
		return res as Dictionary
	return {}


func _registry_for(hook: Dictionary, dummy: Node, point: String) -> Dictionary:
	var api: Variant = _ModAPI.new(_player, root)
	var ctx := {"position": Vector3.ZERO, "hit_position": Vector3.ZERO,
		"damage": 10.0, "target": dummy}
	var out: Variant = _Registry.call("run_hooks", [hook], point, api, ctx)
	if out is Dictionary:
		return out as Dictionary
	return {}


func _active_kinds(target: Node) -> Array:
	var out: Array = []
	var acts: Variant = _ModStatus.call("active_effects", target)
	if acts is Array:
		for eff in (acts as Array):
			if eff is Dictionary:
				out.append(str((eff as Dictionary).get("kind", "")))
	return out


func _active_entry(target: Node, kind: String) -> Dictionary:
	var acts: Variant = _ModStatus.call("active_effects", target)
	if acts is Array:
		for eff in (acts as Array):
			if eff is Dictionary and str((eff as Dictionary).get("kind", "")) == kind:
				return eff as Dictionary
	return {}


func _speed_of(target: Node) -> float:
	return float(_ModStatus.call("speed_multiplier", target))


func _is_wired(kind: String, files: Array) -> bool:
	for f in files:
		if _src_file(str(f)).contains(kind):
			return true
	return false


const GAMEPLAY_FILES := [
	"res://scripts/mods/mod_status_effects.gd",
	"res://scripts/mods/mod_hook_registry.gd",
	"res://scripts/mods/mod_api.gd",
	"res://scripts/player/player.gd",
	"res://scripts/enemies/enemy_base.gd",
	"res://scripts/weapons/weapon_manager.gd",
	"res://scripts/mods/mod_projectile.gd",
	"res://scripts/forge/forge_builder.gd",
]
const DAMAGE_PATH_FILES := [
	"res://scripts/weapons/weapon_manager.gd",
	"res://scripts/mods/mod_projectile.gd",
	"res://scripts/enemies/enemy_base.gd",
	"res://scripts/player/player.gd",
	"res://scripts/mods/mod_hook_registry.gd",
	"res://scripts/mods/mod_status_effects.gd",
]


# --- catalog consistency ---------------------------------------------------

func _test_catalog_consistency() -> void:
	_check(not _effect_kinds.is_empty(), "effects: ModHook.EFFECT_KINDS is non-empty (got %d kinds)" % _effect_kinds.size())
	for k in LEGACY_KINDS:
		_check(k in _effect_kinds, "effects: legacy kind '%s' still in EFFECT_KINDS" % k)
	for k in _status_kinds:
		_check(k in _effect_kinds, "effects: STATUS_KINDS entry '%s' is also in EFFECT_KINDS" % k)
	_info("effects: catalog has %d kinds: %s" % [_effect_kinds.size(), _join(_effect_kinds, ", ")])


# --- per-kind end-to-end loop (data-driven) --------------------------------

func _test_per_kind_loop() -> void:
	for kind_v in _effect_kinds:
		var kind := str(kind_v)
		var found := _find_effect(kind)
		var label := "effects:" + kind
		if not bool(found.get("validated", false)):
			_check(false, label + ": NO probe validates — suite cannot exercise this kind (add its param shape to _probes_for; tried table + generic battery)")
			continue
		var effect: Dictionary = found.get("effect", {})
		if kind == "typed_damage":
			# typed_damage stores NO "typed_damage" entry (instant damage
			# + rider) — it gets its own dedicated path below.
			_test_typed_damage()
			continue
		if kind in _status_kinds:
			_test_status_kind(kind, effect, label)
		else:
			_test_instant_kind(kind, effect, label)


## Coordinator fix #1, pinned explicitly: a DATA hook (no "code") with
## a NEW kind must dispatch through the registry with
## status_applied=true. Before the fix, ModHookRegistry._apply_effect's
## hardcoded 4-kind match dropped every new kind silently.
func _test_data_hook_dispatch() -> void:
	var dummy := TestDummy.new()
	dummy.name = "Dummy_DataHook"
	root.add_child(dummy)
	var poison_hook := {"hook_id": "verify_data_poison", "hook_point": "on_hit",
		"display_name": "Data Poison", "description": "data-hook dispatch probe",
		"effects": [{"kind": "poison", "damage_per_sec": 10.0, "duration_sec": 5.0}]}
	_check(not poison_hook.has("code"), "data-hook: probe carries no code (pure data hook)")
	var out := _registry_for(poison_hook, dummy, "on_hit")
	_check(bool(out.get("status_applied", false)),
		"data-hook poison dispatches: status_applied=true (coordinator fix #1)")
	_check("poison" in _active_kinds(dummy), "data-hook poison: in-game active after dispatch")
	_ModStatus.call("tick_target", dummy, 1.0)
	_check(dummy.hp < 100.0, "data-hook poison: DoT ticks in-game (hp %.1f)" % dummy.hp)
	dummy.free()
	var dummy2 := TestDummy.new()
	dummy2.name = "Dummy_DataHook2"
	root.add_child(dummy2)
	var haste_hook := {"hook_id": "verify_data_haste", "hook_point": "on_hit",
		"display_name": "Data Haste", "description": "data-hook dispatch probe",
		"effects": [{"kind": "haste", "factor": 1.5, "duration_sec": 5.0}]}
	var out2 := _registry_for(haste_hook, dummy2, "on_hit")
	_check(bool(out2.get("status_applied", false)),
		"data-hook haste dispatches: status_applied=true (coordinator fix #1)")
	_check(is_equal_approx(_speed_of(dummy2), 1.5),
		"data-hook haste: speed 1.50 in-game (got %.2f)" % _speed_of(dummy2))
	dummy2.free()


func _test_status_kind(kind: String, effect: Dictionary, label: String) -> void:
	_check(_creator_prompt.contains('"kind": "%s"' % kind),
		label + ": creator prompt offers \"%s\" (kind table)" % kind)
	_check(_forge_gen_prompt.contains('%s {' % kind),
		label + ": ForgeLLM generation prompt offers \"%s\" (status catalog)" % kind)
	var line := _approval_line(effect, "on_hit")
	_check(line.contains(kind) and _line_has_number(line, effect),
		label + ": approval lists it with params (got '%s')" % line)
	var sb := _sandbox_for(effect, "on_hit")
	var sts: Array = sb.get("status_effects", [])
	var sb_found := false
	var sb_dur_ok := true
	for st in sts:
		if st is Dictionary and str((st as Dictionary).get("kind", "")) == kind:
			sb_found = true
			if effect.has("duration_sec"):
				sb_dur_ok = is_equal_approx(float((st as Dictionary).get("duration_sec", -1.0)), float(effect.get("duration_sec", -1.0)))
	_check(sb_found, label + ": sandbox reports it visibly (status_effects)")
	if effect.has("duration_sec"):
		_check(sb_dur_ok, label + ": sandbox reports duration %.1fs" % float(effect.get("duration_sec", 0.0)))
	var dummy := TestDummy.new()
	dummy.name = "Dummy_" + kind
	if kind == "regen":
		dummy.hp = 50.0
	if kind == "pull":
		# Pull yanks TOWARD the hit point (ctx position = origin).
		# Park the dummy 5 m off-origin so "toward" is observable.
		dummy.position = Vector3(0, 0, -5)
	root.add_child(dummy)
	var hp_before := dummy.hp
	var hook := _hook_with(kind, _params_of(effect), "on_hit")
	if kind in ["knockback", "pull"]:
		var out := _registry_for(hook, dummy, "on_hit")
		_check(bool(out.get("status_applied", false)), label + ": registry applies it (status_applied)")
		if kind == "knockback":
			_check(dummy.velocity.length() > 11.0,
				label + ": in-game impulse lands AWAY from origin (velocity %.1f)" % dummy.velocity.length())
		else:
			_check(dummy.velocity.z > 0.0 and dummy.velocity.length() > 5.0,
				label + ": in-game impulse lands TOWARD origin (velocity %s)" % str(dummy.velocity))
		dummy.free()
		return
	var out2 := _registry_for(hook, dummy, "on_hit")
	_check(bool(out2.get("status_applied", false)), label + ": registry applies it (status_applied)")
	_check(kind in _active_kinds(dummy), label + ": in-game active after apply")
	# One gameplay tick: speed kinds hold steady, hp kinds move.
	_ModStatus.call("tick_target", dummy, 1.0)
	_check_gameplay(kind, effect, dummy, hp_before, label)
	_check_special(kind, dummy, label)
	# Wear off: tick past the remaining duration, then verify gone.
	var dur := float(effect.get("duration_sec", 5.0))
	_ModStatus.call("tick_target", dummy, dur)
	_check(not (kind in _active_kinds(dummy)), label + ": wears off after duration")
	_check_wearoff(kind, dummy, label)
	dummy.free()


## Kind-specific behaviour beyond the generic apply/tick/expiry flow:
## sleep must wake early on damage; exhaustion must stack levels.
func _check_special(kind: String, dummy: TestDummy, label: String) -> void:
	if kind == "sleep":
		dummy.take_damage(5.0, Vector3.ZERO, false)
		_ModStatus.call("tick_target", dummy, 0.1)
		_check(not ("sleep" in _active_kinds(dummy)),
			label + ": wakes early on damage (sleep cleared after 5 dmg)")
	elif kind == "exhaustion":
		_ModStatus.call("apply_status", dummy, "exhaustion", {"duration_sec": 5.0}, Vector3.ZERO)
		var entry := _active_entry(dummy, "exhaustion")
		_check(int(entry.get("level", 0)) == 2,
			label + ": second application stacks to level 2 (got %s)" % str(entry.get("level", "?")))
		_check(is_equal_approx(_speed_of(dummy), 0.70),
			label + ": level 2 speed is 0.70 (got %.2f)" % _speed_of(dummy))


func _check_gameplay(kind: String, effect: Dictionary, dummy: TestDummy, hp_before: float, label: String) -> void:
	var mode := _gameplay_for(kind)
	match mode:
		"speed_eq_factor":
			var want := float(effect.get("factor", 1.0))
			_check(is_equal_approx(_speed_of(dummy), want),
				label + ": in-game speed multiplier %.2f (want %.2f)" % [_speed_of(dummy), want])
		"speed_zero":
			_check(is_equal_approx(_speed_of(dummy), 0.0),
				label + ": in-game speed multiplier 0 (got %.2f)" % _speed_of(dummy))
			if kind == "prone":
				_check(dummy.velocity.length() > 5.0,
					label + ": knockdown impulse lands (velocity %.1f)" % dummy.velocity.length())
		"speed_boost":
			_check(_speed_of(dummy) > 1.0,
				label + ": in-game speed multiplier above 1 (got %.2f)" % _speed_of(dummy))
		"poison":
			_check(dummy.hp < hp_before,
				label + ": in-game HP drops (%.1f -> %.1f)" % [hp_before, dummy.hp])
			_check(is_equal_approx(_speed_of(dummy), 0.85),
				label + ": poison also slows x0.85 (got %.2f)" % _speed_of(dummy))
		"hp_down":
			_check(dummy.hp < hp_before,
				label + ": in-game HP drops (%.1f -> %.1f)" % [hp_before, dummy.hp])
		"hp_up":
			_check(dummy.hp > hp_before,
				label + ": in-game HP rises (%.1f -> %.1f)" % [hp_before, dummy.hp])
		"stumble":
			_check(dummy.velocity.length() > 0.0,
				label + ": confusion stumbles (velocity %.1f after 1s tick)" % dummy.velocity.length())
		"blind":
			_check(is_equal_approx(dummy.accuracy, float(effect.get("factor", 1.0))),
				label + ": in-game accuracy scaled to %.2f (got %.2f)" % [float(effect.get("factor", 1.0)), dummy.accuracy])
		"weaken":
			_check(is_equal_approx(dummy.damage, 10.0 * float(effect.get("factor", 1.0))),
				label + ": in-game damage dealt scaled to %.1f (got %.1f)" % [10.0 * float(effect.get("factor", 1.0)), dummy.damage])
		"exhaustion":
			var entry := _active_entry(dummy, "exhaustion")
			_check(int(entry.get("level", 0)) == 1,
				label + ": first application is level 1 (got %s)" % str(entry.get("level", "?")))
			_check(is_equal_approx(_speed_of(dummy), 0.85),
				label + ": level 1 speed is 0.85 (got %.2f)" % _speed_of(dummy))
		"shield_pool":
			_check(is_equal_approx(float(_ModStatus.call("get_shield_remaining", dummy)), float(effect.get("amount", 0.0))),
				label + ": shield pool %.0f (got %.1f)" % [float(effect.get("amount", 0.0)), float(_ModStatus.call("get_shield_remaining", dummy))])
		"vuln_mult":
			_check(is_equal_approx(float(_ModStatus.call("get_damage_taken_multiplier", dummy)), float(effect.get("factor", 1.0))),
				label + ": damage-taken multiplier %.2f (got %.2f)" % [float(effect.get("factor", 1.0)), float(_ModStatus.call("get_damage_taken_multiplier", dummy))])
		"thorns_state":
			var th_entry := _active_entry(dummy, "thorns")
			_check(is_equal_approx(float(th_entry.get("reflect_mult", -1.0)), float(effect.get("reflect_mult", 0.0))),
				label + ": thorns reflect_mult %.2f (got %.2f)" % [float(effect.get("reflect_mult", 0.0)), float(th_entry.get("reflect_mult", -1.0))])
		"petrified":
			_check(is_equal_approx(_speed_of(dummy), 0.0),
				label + ": petrified speed 0 (got %.2f)" % _speed_of(dummy))
			_check(is_equal_approx(float(_ModStatus.call("get_damage_taken_multiplier", dummy)), 0.0),
				label + ": petrified damage-taken multiplier 0 (got %.2f)" % float(_ModStatus.call("get_damage_taken_multiplier", dummy)))
		"active_only":
			_check(_is_wired(kind, GAMEPLAY_FILES),
				label + ": wired into a gameplay consumer (not decorative)")


func _check_wearoff(kind: String, dummy: TestDummy, label: String) -> void:
	var mode := _gameplay_for(kind)
	match mode:
		"speed_eq_factor", "speed_zero", "speed_boost", "poison":
			_check(is_equal_approx(_speed_of(dummy), 1.0),
				label + ": speed fully restored after expiry (got %.2f)" % _speed_of(dummy))
		"hp_down", "hp_up":
			var hp1 := dummy.hp
			_ModStatus.call("tick_target", dummy, 1.0)
			_check(is_equal_approx(dummy.hp, hp1),
				label + ": HP stable after expiry (%.1f -> %.1f)" % [hp1, dummy.hp])
		"blind":
			_check(is_equal_approx(_speed_of(dummy), 1.0),
				label + ": speed fully restored after expiry (got %.2f)" % _speed_of(dummy))
			_check(is_equal_approx(dummy.accuracy, 1.0),
				label + ": accuracy restored after expiry (got %.2f)" % dummy.accuracy)
		"weaken":
			_check(is_equal_approx(dummy.damage, 10.0),
				label + ": damage dealt restored after expiry (got %.1f)" % dummy.damage)
		"exhaustion":
			_check(is_equal_approx(_speed_of(dummy), 1.0),
				label + ": speed fully restored after expiry (got %.2f)" % _speed_of(dummy))
		"shield_pool":
			_check(is_equal_approx(float(_ModStatus.call("get_shield_remaining", dummy)), 0.0),
				label + ": shield pool gone after expiry (got %.1f)" % float(_ModStatus.call("get_shield_remaining", dummy)))
		"vuln_mult":
			_check(is_equal_approx(float(_ModStatus.call("get_damage_taken_multiplier", dummy)), 1.0),
				label + ": damage-taken multiplier restored to 1.0 (got %.2f)" % float(_ModStatus.call("get_damage_taken_multiplier", dummy)))
		"petrified":
			_check(is_equal_approx(_speed_of(dummy), 1.0),
				label + ": speed fully restored after expiry (got %.2f)" % _speed_of(dummy))
			_check(is_equal_approx(float(_ModStatus.call("get_damage_taken_multiplier", dummy)), 1.0),
				label + ": damage-taken multiplier restored to 1.0 (got %.2f)" % float(_ModStatus.call("get_damage_taken_multiplier", dummy)))


func _test_instant_kind(kind: String, effect: Dictionary, label: String) -> void:
	_check(_creator_prompt.contains('"kind": "%s"' % kind),
		label + ": creator prompt offers \"%s\" (kind table)" % kind)
	var point := "on_hit"
	if kind == "heal":
		point = "on_kill"
	var line := _approval_line(effect, point)
	_check(line.contains(kind) and _line_has_number(line, effect),
		label + ": approval lists it with params (got '%s')" % line)
	var sb := _sandbox_for(effect, point)
	if kind == "heal":
		_check(bool(sb.get("healed", false)), label + ": sandbox reports heal (healed)")
	elif kind == "explosion":
		_check(bool(sb.get("explosion_fired", false)), label + ": sandbox reports explosion (explosion_fired)")
	else:
		var hooks_run: Array = sb.get("hooks_run", [])
		_check(("verify_" + kind) in hooks_run, label + ": sandbox ran the hook (hooks_run)")
	var dummy := TestDummy.new()
	dummy.name = "Dummy_" + kind
	root.add_child(dummy)
	var hook := _hook_with(kind, _params_of(effect), point)
	var out := _registry_for(hook, dummy, point)
	match kind:
		"heal":
			_check(float(out.get("healed", 0.0)) >= float(effect.get("amount", 0.0)),
				label + ": registry heals %.0f" % float(out.get("healed", 0.0)))
		"explosion":
			_check(bool(out.get("exploded", false)), label + ": registry explodes")
		"announce":
			_check(bool(out.get("announced", false)), label + ": registry announces")
		"damage_mult":
			_check(is_equal_approx(float(out.get("damage_mult", 1.0)), float(effect.get("value", 1.0))),
				label + ": registry damage_mult %.2f" % float(out.get("damage_mult", 1.0)))
		_:
			_check(out.has("damage_mult"), label + ": registry ran without error")
	dummy.free()


# --- D&D 5e conditions ------------------------------------------------------

func _test_conditions() -> void:
	for dnd in CONDITION_IMPLEMENTED.keys():
		var kind := str(CONDITION_IMPLEMENTED[dnd])
		_check(kind in _effect_kinds,
			"condition %s: implemented as '%s' (end-to-end covered by per-kind loop)" % [str(dnd), kind])
	for c in CONDITION_UNLISTED:
		_info("condition %s: not implemented by Worker A and not named in the prompts' do-not-invent lists (prompt-gap note, not a failure)" % c)


## Deliberately-omitted kinds stay OUT: not in EFFECT_KINDS, not
## offered as a kind by either prompt, validator rejects them. The
## "offered" check uses the catalog shapes ("kind": "x" in the creator
## table, `x {` in the ForgeLLM status catalog) — NOT a bare quoted
## token, because prompts may mention a token in prose (e.g. "lifesteal
## is not a kind") without offering it.
func _test_omitted() -> void:
	for tok_v in DO_NOT_INVENT:
		var tok := str(tok_v)
		var label := "omitted " + tok
		_check(not (tok in _effect_kinds), label + ": NOT in EFFECT_KINDS (deliberately omitted)")
		_check(not _creator_prompt.contains('"kind": "%s"' % tok),
			label + ": creator prompt does not offer it as a kind")
		_check(not _forge_gen_prompt.contains('%s {' % tok),
			label + ": ForgeLLM prompt does not offer it as a kind")
		_check(_validate_hook(_hook_with(tok, {"duration_sec": 5.0}, "on_hit")) != "",
			label + ": validator rejects it")


# --- damage types ------------------------------------------------------------

func _test_damage_types() -> void:
	_check("typed_damage" in _effect_kinds,
		"damage-types: typed_damage mechanism exists")
	if not ("typed_damage" in _effect_kinds):
		return
	for t in DAMAGE_TYPES:
		_check(_creator_prompt.contains('"%s"' % t),
			"damage-type %s: creator prompt offers it" % t)
		_check(_forge_gen_prompt.contains('"%s"' % t),
			"damage-type %s: ForgeLLM prompt offers it" % t)
		_check(_validate_hook(_hook_with("typed_damage", {"damage_type": t, "amount": 20.0, "duration_sec": 5.0}, "on_hit")) == "",
			"damage-type %s: typed_damage validates" % t)
	_check(_validate_hook(_hook_with("typed_damage", {"damage_type": "laser", "amount": 20.0, "duration_sec": 5.0}, "on_hit")) != "",
		"damage-type: typed_damage rejects invalid type 'laser'")
	_check(_validate_hook(_hook_with("typed_damage", {"damage_type": "bludgeoning", "amount": 20.0, "duration_sec": 5.0}, "on_hit")) != "",
		"damage-type: typed_damage rejects 'bludgeoning' (physical types excluded by design — untyped = physical)")
	_test_typed_riders()


## Every damage type's rider fires in-game: fresh dummy per type,
## instant damage lands, the rider is observable, expiry clears it.
func _test_typed_riders() -> void:
	for t_v in DAMAGE_TYPES:
		var t := str(t_v)
		var label := "damage-type %s rider" % t
		var dummy := TestDummy.new()
		dummy.name = "Dummy_Rider_" + t
		root.add_child(dummy)
		var hook := _hook_with("typed_damage", {"damage_type": t, "amount": 20.0, "duration_sec": 5.0}, "on_hit")
		var out := _registry_for(hook, dummy, "on_hit")
		_check(bool(out.get("status_applied", false)), label + ": dispatches (status_applied)")
		_check(is_equal_approx(dummy.hp, 80.0),
			label + ": instant damage lands (hp 100 -> %.1f)" % dummy.hp)
		match t:
			"fire":
				_check("burn" in _active_kinds(dummy), label + ": fire -> burn rider active")
			"cold":
				_check("slow" in _active_kinds(dummy) and is_equal_approx(_speed_of(dummy), 0.6),
					label + ": cold -> slow x0.6 rider (speed %.2f)" % _speed_of(dummy))
			"lightning":
				_check(dummy.velocity.length() > 5.0,
					label + ": lightning -> knockback rider (velocity %.1f)" % dummy.velocity.length())
			"thunder":
				_check(dummy.velocity.length() > 11.0 and "prone" in _active_kinds(dummy),
					label + ": thunder -> knockback + prone riders (velocity %.1f)" % dummy.velocity.length())
			"acid":
				_check(is_equal_approx(dummy.damage, 7.0),
					label + ": acid -> weaken rider (damage dealt %.1f)" % dummy.damage)
			"necrotic":
				var entry := _active_entry(dummy, "exhaustion")
				_check(int(entry.get("level", 0)) == 1,
					label + ": necrotic -> exhaustion level 1 rider")
			"poison":
				_check("poison" in _active_kinds(dummy), label + ": poison -> poison rider active")
			"psychic":
				_check("confusion" in _active_kinds(dummy), label + ": psychic -> confusion rider active")
			"radiant":
				_check(is_equal_approx(dummy.accuracy, 0.5),
					label + ": radiant -> blind rider (accuracy %.2f)" % dummy.accuracy)
		_ModStatus.call("tick_target", dummy, 5.5)
		var riders_gone := true
		for r in ["burn", "slow", "prone", "exhaustion", "poison", "confusion"]:
			if r in _active_kinds(dummy):
				riders_gone = false
		_check(riders_gone, label + ": rider wears off")
		if t == "acid":
			_check(is_equal_approx(dummy.damage, 10.0),
				label + ": weaken rider restores damage (got %.1f)" % dummy.damage)
		if t == "radiant":
			_check(is_equal_approx(dummy.accuracy, 1.0),
				label + ": blind rider restores accuracy (got %.2f)" % dummy.accuracy)
		dummy.free()


# --- typed_damage (dedicated: no stored entry, instant + rider) --------------

func _test_typed_damage() -> void:
	var label := "effects:typed_damage"
	var effect := {"kind": "typed_damage", "damage_type": "fire", "amount": 20.0, "duration_sec": 5.0}
	_check(_creator_prompt.contains('"kind": "typed_damage"'),
		label + ": creator prompt offers it (kind table)")
	_check(_forge_gen_prompt.contains('typed_damage {'),
		label + ": ForgeLLM generation prompt offers it (status catalog)")
	var line := _approval_line(effect, "on_hit")
	_check(line.contains("fire") and line.contains("20") and line.contains("rider"),
		label + ": approval lists it with type + amount + rider (got '%s')" % line)
	var sb := _sandbox_for(effect, "on_hit")
	var sb_found := false
	for st in (sb.get("status_effects", []) as Array):
		if st is Dictionary and str((st as Dictionary).get("kind", "")) == "typed_damage":
			sb_found = true
	_check(sb_found, label + ": sandbox reports it visibly (status_effects)")
	var dummy := TestDummy.new()
	dummy.name = "Dummy_TypedDamage"
	root.add_child(dummy)
	var hook := _hook_with("typed_damage", _params_of(effect), "on_hit")
	var out := _registry_for(hook, dummy, "on_hit")
	_check(bool(out.get("status_applied", false)), label + ": registry applies it (status_applied)")
	_check(is_equal_approx(dummy.hp, 80.0),
		label + ": instant typed damage lands (hp 100 -> %.1f)" % dummy.hp)
	_check("burn" in _active_kinds(dummy),
		label + ": fire rider (burn) active — typed_damage itself stores no entry")
	_ModStatus.call("tick_target", dummy, 5.5)
	_check(not ("burn" in _active_kinds(dummy)), label + ": rider wears off")
	dummy.free()


# --- classic RPG effects -----------------------------------------------------

func _test_classic_rpg() -> void:
	for kind_v in CLASSIC_IMPLEMENTED:
		var kind := str(kind_v)
		_check(kind in _effect_kinds,
			"classic %s: implemented (end-to-end covered by per-kind loop)" % kind)
	_info("classic omitted-by-design: lifesteal (on the prompts' do-not-invent lists; covered by _test_omitted)")


# --- ForgeLLM prompts (coordinator fix #2) ------------------------------------

func _test_forge_prompts() -> void:
	_check(_forge_gen_prompt.contains("Do NOT invent other kinds"),
		"forge-prompt: GENERATION_SYSTEM_PROMPT carries the do-not-invent list")
	for kind_v in _status_kinds:
		var kind := str(kind_v)
		_check(_forge_gen_prompt.contains('%s {' % kind),
			"forge-prompt: GENERATION_SYSTEM_PROMPT offers status kind \"%s\"" % kind)


# --- structures --------------------------------------------------------------

func _test_structures() -> void:
	for s in STRUCTURE_SHAPES:
		_check(_forge_prompt.contains(s),
			"structures: Forge prompt contains shape '%s'" % s)
	_check(_forge_prompt.contains("diagonal"),
		"structures: Forge prompt documents the diagonal ramp")
	# Diagonal ramp: parser spec.
	var spec: Variant = _ForgeLLM.call("parse_offline", "build a diagonal ramp")
	var spec_ok := false
	var parser_rot_key := ""
	var parser_rot_val := 0.0
	if spec is Dictionary and (spec as Dictionary).has("_error"):
		_check(false, "structures: diagonal ramp parses (got _error: %s)" % str((spec as Dictionary).get("_error", "")))
	elif spec is Dictionary:
		var sd := spec as Dictionary
		var params: Dictionary = sd.get("params", {}) as Dictionary
		var shape := str(params.get("shape", ""))
		_check(str(sd.get("target", "")) == "structure" and shape in ["ramp", "diagonal_ramp"],
			"structures: diagonal ramp parses to a ramp structure spec (got target=%s shape=%s)" % [str(sd.get("target", "")), shape])
		for k in ROTATION_KEYS:
			if params.has(k):
				parser_rot_key = k
				parser_rot_val = float(params[k])
				break
		if shape == "diagonal_ramp":
			_check(true, "structures: diagonal ramp spec uses shape 'diagonal_ramp'")
			spec_ok = true
		else:
			_check(parser_rot_key != "" and absf(parser_rot_val - 45.0) < 10.0,
				"structures: diagonal spec contains rotation ~45 (got %s=%s)" % [parser_rot_key, parser_rot_val])
			spec_ok = parser_rot_key != ""
		var verdict: Variant = _ForgeLLM.call("validate_modspec", sd.duplicate(true))
		if verdict is Array and (verdict as Array).size() >= 2:
			_check(bool((verdict as Array)[0]),
				"structures: diagonal spec passes validate_modspec (%s)" % str((verdict as Array)[1]))
		else:
			_check(false, "structures: validate_modspec returned no verdict for diagonal spec")
	else:
		_check(false, "structures: diagonal ramp parses (no spec returned)")
	# Validator rotation keys (independent of the parser).
	var accepted := ""
	for k in ROTATION_KEYS:
		var probe := {"spec_version": 1, "action": "spawn", "target": "structure",
			"params": {"shape": "ramp", "position": "near_player", k: 45.0}, "cost": 90, "ttl": 0}
		var v: Variant = _ForgeLLM.call("validate_modspec", probe)
		if v is Array and not (v as Array).is_empty() and bool((v as Array)[0]):
			accepted = k
			break
	_check(accepted != "",
		"structures: validator accepts a rotation key (tried rotation_deg/rotation/yaw/angle)")
	# Geometry: straight control vs diagonal build.
	if accepted != "" or spec_ok:
		_test_ramp_geometry(accepted, spec if spec is Dictionary else {})
	else:
		_info("structures: geometry check skipped — no rotation key accepted and parser spec has none")
	# Inexpressible geometry: visible message or labeled approximation.
	for prompt in INEXPRESSIBLE:
		_test_inexpressible(prompt)


func _test_ramp_geometry(accepted_key: String, parser_spec: Dictionary) -> void:
	var ctx := {"player": _player, "root": _arena}
	var straight_spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "ramp", "position": "near_player"}, "cost": 90, "ttl": 0}
	var msg1: Variant = _ForgeBuilder.call("build", straight_spec, ctx)
	var straight_node: Node = _ForgeBuilder.last_built_node
	_check(not str(msg1).begins_with("FORGE_FAIL"),
		"structures: straight ramp control builds (got '%s')" % str(msg1))
	var straight_fp := _footprint(straight_node)
	var straight_ratio := _footprint_ratio(straight_fp)
	var diag_params := {"shape": "ramp", "position": "near_player"}
	if parser_spec.has("params") and (parser_spec["params"] as Dictionary).has("rotation_deg"):
		diag_params = (parser_spec["params"] as Dictionary).duplicate(true)
	elif parser_spec.has("params") and str((parser_spec["params"] as Dictionary).get("shape", "")) == "diagonal_ramp":
		diag_params = (parser_spec["params"] as Dictionary).duplicate(true)
	elif accepted_key != "":
		diag_params[accepted_key] = 45.0
	var diag_spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": diag_params, "cost": 90, "ttl": 0}
	var msg2: Variant = _ForgeBuilder.call("build", diag_spec, ctx)
	var diag_node: Node = _ForgeBuilder.last_built_node
	_check(not str(msg2).begins_with("FORGE_FAIL"),
		"structures: diagonal ramp builds (got '%s')" % str(msg2))
	if diag_node != null and is_instance_valid(diag_node):
		var diag_fp := _footprint(diag_node)
		var diag_ratio := _footprint_ratio(diag_fp)
		_info("structures: footprint straight [%.1f x %.1f] ratio %.2f; diagonal [%.1f x %.1f] ratio %.2f; diagonal node rotation.y %.1f deg" % [
			straight_fp[0], straight_fp[1], straight_ratio,
			diag_fp[0], diag_fp[1], diag_ratio,
			rad_to_deg((diag_node as Node3D).rotation.y) if diag_node is Node3D else 0.0])
		_check(diag_ratio > 0.6 and diag_ratio > straight_ratio + 0.25,
			"structures: diagonal ramp geometry IS diagonal (ratio %.2f vs straight %.2f)" % [diag_ratio, straight_ratio])
	else:
		_check(false, "structures: diagonal ramp produced no built node")


func _footprint(node: Node) -> Array:
	var xs: Array = []
	var zs: Array = []
	if node != null and is_instance_valid(node):
		_collect_mesh_positions(node, xs, zs)
	if xs.is_empty():
		return [0.0, 0.0]
	return [float(xs.max()) - float(xs.min()), float(zs.max()) - float(zs.min())]


func _footprint_ratio(fp: Array) -> float:
	if fp.size() < 2 or maxf(float(fp[0]), float(fp[1])) <= 0.0:
		return 0.0
	return minf(float(fp[0]), float(fp[1])) / maxf(float(fp[0]), float(fp[1]))


func _collect_mesh_positions(node: Node, xs: Array, zs: Array) -> void:
	for c in node.get_children():
		if c is MeshInstance3D:
			var gp := (c as Node3D).global_position
			xs.append(gp.x)
			zs.append(gp.z)
		_collect_mesh_positions(c, xs, zs)


func _test_inexpressible(prompt: String) -> void:
	var label := "structures: inexpressible '%s'" % prompt
	var spec: Variant = _ForgeLLM.call("parse_offline", prompt)
	if spec is Dictionary and (spec as Dictionary).has("_error"):
		_check(true, label + " -> visible message (%s)" % str((spec as Dictionary).get("_error", "")))
		return
	if spec is Dictionary and bool(_ForgeLLM.call("is_refusal", spec)):
		_check(true, label + " -> refusal")
		return
	if not (spec is Dictionary):
		_check(false, label + " -> no spec and no error (silent)")
		return
	var sd := spec as Dictionary
	var verdict: Variant = _ForgeLLM.call("validate_modspec", sd.duplicate(true))
	if verdict is Array and not (verdict as Array).is_empty() and not bool((verdict as Array)[0]):
		_check(true, label + " -> gate rejects with visible reason (%s)" % str((verdict as Array)[1]))
		return
	var msg: Variant = _ForgeBuilder.call("build", sd, {"player": _player, "root": _arena})
	var msg_l := str(msg).to_lower()
	if str(msg).begins_with("FORGE_FAIL"):
		_check(true, label + " -> visible failure (%s)" % str(msg))
		return
	var labeled := false
	for w in APPROX_WORDS:
		if msg_l.contains(w):
			labeled = true
			break
	_check(labeled,
		label + " -> labeled approximation, never silent wrong build (build said '%s')" % str(msg))


# --- regression guards --------------------------------------------------------

func _test_regression_guards() -> void:
	var slow_hook := _hook_with("slow", {"factor": 0.5, "duration_sec": 3.0}, "on_hit")
	_check(_validate_hook(slow_hook) == "", "regression: slow on_hit still validates")
	var fire_hook := _hook_with("slow", {"factor": 0.5, "duration_sec": 3.0}, "projectile_spawn")
	_check(_validate_hook(fire_hook) != "", "regression: slow on a fire point still rejected")
	var bad_factor := _hook_with("slow", {"factor": 2.0, "duration_sec": 3.0}, "on_hit")
	_check(_validate_hook(bad_factor) != "", "regression: slow factor > 1 still rejected")
	var teleport := _hook_with("teleport", {"duration_sec": 5.0}, "on_hit")
	_check(_validate_hook(teleport) != "", "regression: unknown kind 'teleport' still rejected")
	var sb := _sandbox_for({"kind": "slow", "factor": 0.5, "duration_sec": 3.0}, "on_hit")
	_check(is_equal_approx(float(sb.get("dummy_speed_before", 0.0)), 4.0)
		and is_equal_approx(float(sb.get("dummy_speed_after", 0.0)), 2.0),
		"regression: sandbox legacy slow still 4.0 -> 2.0 m/s")
	var dummy := TestDummy.new()
	dummy.name = "Dummy_RegHeal"
	root.add_child(dummy)
	var heal_hook := _hook_with("heal", {"amount": 15.0}, "on_kill")
	var hout := _registry_for(heal_hook, dummy, "on_kill")
	_check(is_equal_approx(float(hout.get("healed", 0.0)), 15.0),
		"regression: registry legacy heal-on-kill still heals 15")
	dummy.free()
	var knife: Variant = _ForgeLLM.call("parse_offline", "give me a knife")
	_check(knife is Dictionary and (knife as Dictionary).has("_error"),
		"regression: offline 'knife' still a visible _error")
	var bad_spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "ramp", "position": "near_player", "script": "x"}, "cost": 90, "ttl": 0}
	var bv: Variant = _ForgeLLM.call("validate_modspec", bad_spec)
	_check(bv is Array and not (bv as Array).is_empty() and not bool((bv as Array)[0]),
		"regression: validate_modspec still rejects invented/script fields")
	var bad_msg: Variant = _ForgeBuilder.call("build",
		{"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "nope", "position": "near_player"}, "cost": 0, "ttl": 0},
		{"player": _player, "root": _arena})
	_check(str(bad_msg).begins_with("FORGE_FAIL"),
		"regression: unknown structure shape still FORGE_FAIL (got '%s')" % str(bad_msg))
	_check(_creator_prompt.contains('"slow"'),
		"regression: creator prompt still documents slow")
