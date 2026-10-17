# FORGEFALL — ModAPI (v0.7 chunk 1: user mods, Worker A)
# The ONLY surface a user script mod may touch. Mod scripts talk to the
# game exclusively through this object (passed to ModBlock.apply()).
# Deliberately small: spawn things, tune stats, fire effects, announce.
# NO filesystem / network / OS / eval / arbitrary resource loading — those
# are rejected by ModLoader's forbidden-API text scan before the script
# ever loads. Every spawn is tracked (last_spawned) so ForgeBuilder can
# register the node for undo / the structure cap.
#
# v0.5.6 route B — HOOK-SCRIPT ALLOWLIST + BUDGET (Worker A): hook
# scripts (GDScript `extends ModHook`) are held to a STRICTER rule than
# ModBlock scripts. A hook script may call ONLY the methods in
# HOOK_ALLOWED_API_METHODS (on `api`) plus the safe builtins listed
# below (on `ctx`, on locals, and bare). ModHook.validate_hook_code()
# enforces that allowlist — it is the SINGLE authoritative list, kept
# here so the prompt worker documents this exact surface (read it here;
# do not duplicate it anywhere else). Anything outside it is REJECTED
# with the violation named (e.g. "hook script calls non-ModAPI
# (forbidden API): OS.execute"). A hook script that errors at load or
# run DISABLES ITS MOD VISIBLY (ModLoader.note_hook_runtime_failure),
# never crashes. Runaway hooks are bounded by the step/time budget
# below (ModHookRegistry enforces it around every code-hook run).
extends RefCounted
class_name ModAPI

const TURRET_SCRIPT := preload("res://scripts/forge/forge_turret.gd")

# --- HOOK-SCRIPT ALLOWLIST (v0.5.6 route B) --------------------------------
# SINGLE AUTHORITATIVE LIST for what a hook script (extends ModHook) may
# call. ModHook.validate_hook_code() reads these constants — it defines
# NO allowlist of its own. The prompt worker documents this exact surface
# from here. Default is REJECT: anything not listed here is a violation.
#
# What a hook script gets: `api` (this object), `ctx` (a Dictionary of
# hook-point facts: position / hit_position / damage / target /
# weapon_id / ...), locals it declares itself, and the safe builtins
# below. Values that flow OUT of `api` (a Node, a Vector3, ...) may only
# be passed BACK into `api` or used through the safe methods below —
# there is NO way to reach into a node (`.position = ...`, `.queue_free()`,
# `.get_node(...)`, `["hp"]`, ...) because no such member is listed.

## Every ModAPI method a hook script may call as `api.<method>`.
## (All public ModAPI methods — the whole surface, nothing else.)
const HOOK_ALLOWED_API_METHODS := ["get_player", "get_root",
	"get_player_position", "get_aim_point", "spawn_voxel_box", "spawn_cover",
	"spawn_pickup", "spawn_turret", "give_weapon", "fire_effect", "announce",
	"get_player_health", "heal_player", "apply_status_effect", "spawn_projectile",
	"has_status_effect", "clear_status_effect", "spawn_elemental_emitter",
	"get_creature_type", "is_creature_immune_to_status", "get_ability_modifier",
	"get_shield_remaining", "get_damage_taken_multiplier"]

## Read-only Dictionary methods a hook may call on `ctx`. `ctx` is input:
## a hook must never mutate it (no erase / clear / assignment).
const HOOK_ALLOWED_CTX_METHODS := ["get", "has", "has_all", "keys", "values",
	"size", "is_empty"]

## Global functions / type constructors a hook may call bare (no receiver).
## Pure math, conversions, and value construction only — no engine access.
const HOOK_ALLOWED_BUILTIN_CALLS := ["print", "str", "int", "float", "bool",
	"Vector2", "Vector3", "Vector3i", "Vector4", "Color", "Dictionary", "Array",
	"String", "StringName", "clampf", "clampi", "min", "max", "minf", "maxf",
	"abs", "absf", "sign", "signf", "floor", "ceil", "round", "lerp", "lerpf",
	"lerp_angle", "randf", "randi", "randf_range", "randi_range", "sqrt", "pow",
	"sin", "cos", "tan", "asin", "acos", "atan", "atan2", "deg_to_rad",
	"rad_to_deg", "is_equal_approx", "is_zero_approx", "is_inf", "is_nan",
	"is_finite", "typeof", "range", "snapped", "snappedf", "clamp",
	"move_toward", "posmod", "fmod", "wrap", "wrapf", "wrapi", "pingpong",
	"smoothstep", "inverse_lerp", "remap", "ease", "step_decimals", "is_same"]

## Types a hook may name (annotations, `is` / `as` checks, constructors).
## Engine node types appear ONLY for `is` checks (e.g. `if tgt is Node:` —
## the documented status-effect pattern); naming a node type never grants
## access to its members (see the dotted-access rule above).
const HOOK_ALLOWED_TYPES := ["ModAPI", "ModHook", "Dictionary", "Array",
	"String", "StringName", "int", "float", "bool", "Vector2", "Vector3",
	"Vector3i", "Vector4", "Color", "Variant", "Node", "Node3D",
	"CharacterBody3D", "PackedStringArray", "PackedVector3Array",
	"PackedFloat32Array", "PackedInt32Array"]

## Methods a hook may call on its OWN locals and on values chained off a
## call (e.g. `dir.normalized()`, `api.get_player_position().x`,
## `ctx.get("target", null)` is ctx — this list is for everything else).
## Pure value methods on Vector / Dictionary / Array / String / Color
## only — NO node methods (no queue_free / add_child / get_node / set /
## get / set_meta / get_meta / call / free / ...).
const HOOK_ALLOWED_SAFE_METHODS := [
	# Vector2/3/4 (pure math).
	"normalized", "length", "length_squared", "distance_to",
	"distance_squared_to", "direction_to", "dot", "cross", "lerp", "slerp",
	"rotated", "angle_to", "angle_to_point", "abs", "ceil", "floor", "round",
	"sign", "clamp", "clamped", "snapped", "bounce", "reflect", "slide",
	"project", "limit_length", "is_equal_approx", "is_zero_approx", "is_finite",
	"is_normalized", "posmod", "max_axis_index", "min_axis_index",
	# Dictionary (read + local mutation of a hook-owned dict only).
	"get", "has", "has_all", "keys", "values", "size", "is_empty", "duplicate",
	"get_or_add", "find_key", "erase", "clear", "merge", "sort",
	# Array (read + local mutation of a hook-owned array only).
	"front", "back", "count", "append", "push_back", "pop_back", "pop_front",
	"push_front", "insert", "remove_at", "slice", "reverse", "min", "max",
	"bsearch", "shuffle", "sort_custom",
	# String (pure text).
	"substr", "find", "findn", "rfind", "contains", "begins_with", "ends_with",
	"to_lower", "to_upper", "strip_edges", "trim_prefix", "trim_suffix",
	"replace", "replacen", "split", "join", "format", "pad_zeros",
	"pad_decimals", "is_valid_int", "is_valid_float", "to_int", "to_float",
	"capitalize", "repeat", "reverse", "lpad", "rpad", "get_slice", "left",
	"right", "mid", "dedent", "indent", "split_floats", "hex_encode",
	"hex_decode",
	# Color (pure).
	"to_html", "lightened", "darkened", "inverted", "blend", "srgb_to_linear",
	"linear_to_srgb",
]

## Component reads a hook may do on a value (`.x`, `.r`, ...). Any other
## dotted attribute read (`.position`, `.hp`, `.name`, ...) is rejected.
const HOOK_ALLOWED_COMPONENTS := ["x", "y", "z", "w", "r", "g", "b", "a"]

## Runaway-hook budget (enforced by ModHookRegistry around every
## code-hook run; ModAPI counts the steps). One hook run may make at
## most HOOK_MAX_API_STEPS ModAPI calls and take at most
## HOOK_MAX_SINGLE_MSEC wall ms; a whole dispatch (all hooks at one hook
## point) may take at most HOOK_MAX_DISPATCH_MSEC wall ms. Exceeding any
## of them aborts the rest of the dispatch and disables the mod visibly.
## HONEST LIMIT: GDScript has no preemptive timeout, so a truly infinite
## TIGHT loop inside one hook call (no api calls, never returns) cannot
## be preempted — it hangs the frame. What the budget DOES bound: total
## ModAPI side-effects per run (step cap turns further api calls into
## no-ops), hooks that loop long but return (wall check after the call),
## and unbounded `while` loops (rejected at validation — hooks use
## bounded `for` loops; `range()` literals over HOOK_MAX_RANGE are
## rejected too). Prefer data hooks (interpreted, no code runs at all)
## for anything the effect-kinds table can express.
const HOOK_MAX_API_STEPS := 200
const HOOK_MAX_SINGLE_MSEC := 100
const HOOK_MAX_DISPATCH_MSEC := 250
const HOOK_MAX_RANGE_LITERAL := 1000

## Human-readable summary of the allowlist, for the prompt worker to
## document. Read the constants above — this is just their rendering.
static func hook_allowlist_doc() -> String:
	var lines: Array[String] = []
	lines.append("Hook scripts (extends ModHook) may call ONLY:")
	lines.append("- api.<method> for: " + ", ".join(HOOK_ALLOWED_API_METHODS))
	lines.append("- ctx.<method> for: " + ", ".join(HOOK_ALLOWED_CTX_METHODS))
	lines.append("- bare globals: " + ", ".join(HOOK_ALLOWED_BUILTIN_CALLS))
	lines.append("- types (annotations / is / as): " + ", ".join(HOOK_ALLOWED_TYPES))
	lines.append("- methods on own locals / chained values: " + ", ".join(HOOK_ALLOWED_SAFE_METHODS))
	lines.append("- components: " + ", ".join(HOOK_ALLOWED_COMPONENTS))
	lines.append("Everything else is REJECTED (forbidden API). No while loops; for loops only, range() literals <= %d." % HOOK_MAX_RANGE_LITERAL)
	lines.append("Per-hook budget: at most %d ModAPI calls and %d ms per hook run, %d ms per dispatch." % [HOOK_MAX_API_STEPS, HOOK_MAX_SINGLE_MSEC, HOOK_MAX_DISPATCH_MSEC])
	return "\n".join(lines)


# --- Hook step budget (static: shared across ModAPI instances) -------------
# Static on purpose: a hook could stash the `api` it was given in an
# instance var and call THAT object on a later run. Per-instance budget
# state would let the stashed object dodge the cap; static state means
# every ModAPI call made while a hook run is in progress is charged,
# whichever instance it goes through. The registry activates the budget
# for exactly one code-hook run at a time (begin/end around run()).

static var _hook_budget_active := false
static var _hook_budget_steps := 0
static var _hook_budget_exceeded := false


## Activates the per-hook step budget (registry calls this before a
## code hook's run()). Resets the step count + exceeded flag.
static func begin_hook_budget() -> void:
	_hook_budget_active = true
	_hook_budget_steps = 0
	_hook_budget_exceeded = false


## Deactivates the budget. Returns true when the run exceeded the step
## cap (further api calls in that run were no-ops).
static func end_hook_budget() -> bool:
	var exceeded := _hook_budget_exceeded
	_hook_budget_active = false
	_hook_budget_steps = 0
	_hook_budget_exceeded = false
	return exceeded


## True when the current hook run has exceeded the step cap.
static func hook_budget_exceeded() -> bool:
	return _hook_budget_exceeded


## Charges one ModAPI call against the active hook budget. Returns false
## when the budget is exhausted — the caller returns its safe default
## immediately (no side effect). No-op when no hook budget is active
## (game code, data hooks, ModBlock apply).
func _charge_step() -> bool:
	if not _hook_budget_active:
		return true
	_hook_budget_steps += 1
	if _hook_budget_steps > HOOK_MAX_API_STEPS:
		_hook_budget_exceeded = true
		return false
	return true



## Last node a spawn_* call produced (null when nothing spawned).
var last_spawned: Node = null
## World position of last_spawned.
var last_spawned_position := Vector3.ZERO

var _player: Node3D
var _root: Node
## v0.5.12 UNIFIED GIVE PATH: the WeaponManager slot give_weapon()
## fills ("primary" by default). ForgeBuilder sets this from the
## build's _slot param when a script-mod weapon is built for a
## non-primary slot (e.g. a script mod in a loadout's secondary
## slot) — otherwise every script-mod weapon would land in primary
## and clobber whatever was there. Scripts never set this themselves;
## it is build context, not script API.
var _give_slot := "primary"


## Build-context only (ForgeBuilder): the slot give_weapon() fills.
func set_give_slot(slot: String) -> void:
	if slot in ["primary", "secondary", "prototype"]:
		_give_slot = slot


func _init(player: Node3D, root: Node) -> void:
	_player = player
	_root = root


## The player node (may be null in headless tests). Prefer the helpers
## below over reaching into the player yourself.
func get_player() -> Node3D:
	if not _charge_step():
		return null
	return _player


## The scene root builds attach to.
func get_root() -> Node:
	if not _charge_step():
		return null
	return _root


## Player position, or Vector3.ZERO when there is no player.
func get_player_position() -> Vector3:
	if not _charge_step():
		return Vector3.ZERO
	if _player != null:
		return _player.global_position
	return Vector3.ZERO


## Crosshair raycast point (the "marked" position).
func get_aim_point() -> Vector3:
	if not _charge_step():
		return Vector3.ZERO
	return ForgeBuilder.crosshair_point(_player)


## One voxel block: visible cube + optional solid collider, at `position`.
## Returns the Node3D (already added to the root), or null without a root.
func spawn_voxel_box(size: Vector3, color: Color, position: Vector3, solid: bool) -> Node3D:
	if not _charge_step():
		return null
	if _root == null:
		return null
	var node := Node3D.new()
	node.name = "ModVoxel"
	node.position = position
	_root.add_child(node)
	node.add_child(VoxelBuilder.cube(size, color, Vector3.ZERO))
	if solid:
		var body := StaticBody3D.new()
		body.add_child(VoxelBuilder.collision_box(size))
		node.add_child(body)
	_track(node, position)
	return node


## A destructible voxel cover slab. shape: wall|tower|barricade.
## size_voxels in voxels (each 1-12), hp 50-500. Null when unavailable.
func spawn_cover(shape: String, size_voxels: Vector3i, hp: float, position: Vector3) -> Node:
	if not _charge_step():
		return null
	if _root == null or not _has_script_class("DestructibleCover"):
		return null
	if not (shape in ["wall", "tower", "barricade"]):
		return null
	var cover := DestructibleCover.new()
	cover.vox_size = Vector3i(clampi(size_voxels.x, 1, 12), clampi(size_voxels.y, 1, 12), clampi(size_voxels.z, 1, 12))
	cover.pitch = ForgeBuilder.COVER_PITCH_M
	var pal: Array[Color] = [VoxelBuilder.PALETTE["concrete"], Color("847f76")]
	cover.palette.assign(pal)
	cover.hp = clampf(hp, 50.0, 500.0)
	cover.position = position
	_root.add_child(cover)
	_track(cover, position)
	return cover


## An ammo/health pickup at `position`. kind: ammo|health.
func spawn_pickup(kind: String, position: Vector3) -> Node:
	if not _charge_step():
		return null
	if _root == null:
		return null
	var node := ForgeBuilder.spawn_pickup(_root, position, kind)
	_track(node, position)
	return node


## A sentry turret. damage_mult / range_mult are recorded as metadata on
## the turret (same precedent as the Forge's own turret composition —
## forge_turret.gd reads them and applies them to damage/range).
func spawn_turret(position: Vector3, duration_sec: float, damage_mult: float, range_mult: float) -> Node:
	if not _charge_step():
		return null
	if _root == null:
		return null
	var t = TURRET_SCRIPT.new()
	t.set_meta("ammo_type", "standard")
	t.set_meta("damage_mult", damage_mult)
	t.set_meta("range_mult", range_mult)
	t.ttl_seconds = clampf(duration_sec, 5.0, 120.0)
	t.position = position
	if _player != null:
		var away: Vector3 = position - _player.global_position
		away.y = 0.0
		if away.length() > 0.5:
			var tr: Vector3 = t.rotation
			tr.y = atan2(-away.x, -away.z)
			t.rotation = tr
	_root.add_child(t)
	_track(t, position)
	return t


## Give the player a base weapon, tuned by the multipliers (1.0 = stock).
## weapon_id is a Forge id (manticore/longeye/breacher/hornet/p9/raptor/lmg).
## False when there is no player / WeaponManager / unknown weapon.
## Gives the player a weapon with optional multipliers + fire mode.
## fire_mode: "" (keep base) or "auto"|"semi"|"burst"|"bolt"|"pump".
## burst_size: rounds per burst (only with fire_mode "burst", 2-10).
## The weapon lands in the build's give slot (set_give_slot — "primary"
## unless a script-mod build targeted another slot). The primary path
## keeps WeaponManager.give_weapon (with its pending-attach consume);
## a non-primary slot uses set_slot + an explicit pending-attach on
## that slot's fresh weapon, so hooks attach identically in both.
func give_weapon(weapon_id: String, damage_mult: float, range_mult: float, mag_mult: float, fire_mode: String = "", burst_size: int = 0) -> bool:
	if not _charge_step():
		return false
	if _player == null:
		return false
	var wm = _player.get_node_or_null("WeaponManager")
	if wm == null:
		wm = _player.find_child("WeaponManager", true, false)
	if wm == null or not wm.has_method("give_weapon"):
		return false
	var arsenal_id := str(ForgeBuilder.FORGE_WEAPON_IDS.get(weapon_id, weapon_id))
	if not Arsenal.has_weapon(arsenal_id):
		return false
	var fresh: Node = null
	if _give_slot == "primary":
		wm.give_weapon(arsenal_id)
		fresh = _fresh_weapon_child(wm, arsenal_id)
	else:
		if not wm.has_method("set_slot") or not wm.has_method("get_slot_weapon"):
			return false
		wm.set_slot(_give_slot, arsenal_id)
		fresh = wm.get_slot_weapon(_give_slot)
		if fresh != null:
			ModHookRegistry.try_attach_pending(fresh, arsenal_id)
	if fresh == null:
		return false
	_apply_weapon_tuning(fresh, damage_mult, range_mult, mag_mult, fire_mode, burst_size)
	return true


## Newest live weapon child with this arsenal id (skips the
## queued-for-free old weapon after set_slot()).
static func _fresh_weapon_child(wm: Node, arsenal_id: String) -> Node:
	var kids := wm.get_children()
	for i in range(kids.size() - 1, -1, -1):
		var kid := kids[i] as Node
		if kid == null or kid.is_queued_for_deletion():
			continue
		if str(kid.get("weapon_id")) == arsenal_id:
			return kid
	return null


## In-place tuning of a freshly granted weapon (multipliers + fire
## mode). Shared by both give slots.
static func _apply_weapon_tuning(kid: Node, damage_mult: float, range_mult: float, mag_mult: float, fire_mode: String, burst_size: int) -> void:
	if damage_mult != 1.0:
		kid.set("damage", float(kid.get("damage")) * damage_mult)
	if range_mult != 1.0:
		kid.set("near_range", float(kid.get("near_range")) * range_mult)
		kid.set("far_range", float(kid.get("far_range")) * range_mult)
	if mag_mult != 1.0:
		var mag_size := maxi(1, int(round(float(kid.get("mag_size")) * mag_mult)))
		kid.set("mag_size", mag_size)
		kid.set("mag", mag_size)
	if not fire_mode.is_empty():
		kid.set("fire_mode", WeaponBase.fire_mode_from_string(fire_mode))
	if burst_size >= 2:
		kid.set("burst_size", mini(burst_size, 10))


## A one-shot effect. kind: "explosion" (uses radius + damage), "smoke"
## (uses duration_sec), or "elemental" (a one-shot ElementalEmitter
## burst of the `element` at `position`: radius + damage, one hit).
## Unknown kinds are ignored.
func fire_effect(kind: String, position: Vector3, radius: float, damage: float, duration_sec: float = 20.0, element: String = "fire") -> void:
	if not _charge_step():
		return
	match kind:
		"explosion":
			ForgeBuilder.fx_detonate(position, radius, damage)
		"smoke":
			if _root != null:
				ForgeBuilder.fx_smoke(_root, position, clampf(duration_sec, 5.0, 120.0))
		"elemental":
			if _root != null:
				ElementalEmitter.spawn_burst(_root, element, position, radius, damage)


## Spawns a persistent elemental emitter field (see
## ElementalEmitter): voxel particles + one elemental damage type +
## radius + duration, damaging ENEMIES ONLY inside the radius on
## every 0.5 s tick. element: fire|cold|lightning|acid|poison|radiant|
## necrotic|thunder|force|water. Water slows + extinguishes burn +
## marks wet (lightning conducts: x1.5 + chain). Returns the emitter
## node, or null for an unknown element / no root. Usable from
## ModBlock scripts AND hook scripts (allowlisted).
func spawn_elemental_emitter(element: String, position: Vector3, radius: float, duration_sec: float, damage_per_sec: float) -> Node:
	if not _charge_step():
		return null
	if _root == null:
		return null
	var node := ElementalEmitter.spawn_field(_root, element, position, radius, duration_sec, damage_per_sec)
	if node != null:
		_track(node, position)
	return node


## HUD banner. Silent no-op when no HUD is listening.
func announce(title: String, subtitle: String) -> void:
	if not _charge_step():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var hud = tree.get_first_node_in_group("hud")
	if hud != null and hud.has_method("announce"):
		hud.announce(title, subtitle)


# --- Hook support (v0.5.3: invented hooks) ---------------------------------
# The surface ModHook code + the hook registry may use. Same deal as the
# rest of ModAPI: these are the ONLY game operations a hook gets.

## Current player HP, or -1 when there is no player / no HP to read.
func get_player_health() -> float:
	if not _charge_step():
		return -1.0
	if _player == null or not is_instance_valid(_player):
		return -1.0
	var v: Variant = _player.get("_hp")
	if v is int or v is float:
		return float(v)
	return -1.0


## Heals the player (clamped by the player's own heal()). Returns the
## player's HP afterwards, or -1 when there is no player / heal().
func heal_player(amount: float) -> float:
	if not _charge_step():
		return -1.0
	if _player == null or not is_instance_valid(_player):
		return -1.0
	if not _player.has_method("heal"):
		return -1.0
	_player.heal(amount)
	return get_player_health()


## Applies a status effect to a target node — see ModStatusEffects.
## Kinds: slow / freeze / burn / knockback / pull / poison / bleed /
## regen / haste / restrained / prone / sleep / confusion / blind /
## weaken / exhaustion / typed_damage / shield / vulnerable / thorns /
## petrified. `origin` is the hit point
## (knockback direction is away from it, pull toward it). No-op
## (false) for a null / freed / out-of-tree target, an unknown kind,
## or a kind with no handle on this target (e.g. blind on a target
## with no accuracy stat and no weapons). The four damage-interception
## kinds (shield / vulnerable / thorns / petrified) take effect
## through the take_damage interception the next time the target
## would take damage (ModStatusEffects.resolve_incoming_damage).
func apply_status_effect(target: Node, kind: String, params: Dictionary, origin: Vector3) -> bool:
	if not _charge_step():
		return false
	return ModStatusEffects.apply_status(target, kind, params, origin)


## True when `target` currently has an active effect of `kind`.
func has_status_effect(target: Node, kind: String) -> bool:
	if not _charge_step():
		return false
	return ModStatusEffects.has_status_effect(target, kind)


## Removes one status kind from `target` (restoring blind/weaken
## stat scaling), or every effect when kind == "all". The "cure"
## primitive: a hook can end poison early. True when something was
## removed.
func clear_status_effect(target: Node, kind: String) -> bool:
	if not _charge_step():
		return false
	return ModStatusEffects.clear_status_effect(target, kind)


## v0.5.8 D&D: the target's creature type ("" for targets without one,
## e.g. players, structures, dummies). Hook scripts can branch on it
## (e.g. don't waste poison on a construct).
func get_creature_type(target: Node) -> String:
	if not _charge_step():
		return ""
	if target == null or not is_instance_valid(target):
		return ""
	var t: Variant = target.get("creature_type")
	return str(t) if t is String else ""


## v0.5.8 D&D: true when the target's creature type is immune to the
## 5e condition the status `kind` expresses (poison on a construct,
## sleep on an elemental, ...). False for kinds with no 5e condition.
func is_creature_immune_to_status(target: Node, kind: String) -> bool:
	if not _charge_step():
		return false
	return DnDTypes.is_status_immune(get_creature_type(target), kind)


## v0.5.8 D&D: the target's ability modifier for `ability` (STR/DEX/
## CON/INT/WIS/CHA, case-insensitive; 10 = +0). 0 for targets without
## a stat block.
func get_ability_modifier(target: Node, ability: String) -> int:
	if not _charge_step():
		return 0
	if target == null or not is_instance_valid(target):
		return 0
	var scores: Variant = target.get("ability_scores")
	if not (scores is Dictionary):
		return 0
	return DnDTypes.get_ability_modifier(scores as Dictionary, ability)


## v0.5.9 take_damage: remaining shield pool on `target` (0.0 when no
## shield). Hook scripts branch on this (e.g. re-shield only when the
## pool is empty). Read-only — the pool itself drains only when the
## target actually takes damage (ModStatusEffects.resolve_...).
func get_shield_remaining(target: Node) -> float:
	if not _charge_step():
		return 0.0
	if target == null or not is_instance_valid(target):
		return 0.0
	return ModStatusEffects.get_shield_remaining(target)


## v0.5.9 take_damage: damage-taken multiplier from defensive states —
## 0.0 while the target is petrified (all damage nullified), else the
## vulnerable factor (1.0 when not vulnerable). Shield is NOT a
## multiplier (it is a pool) — read it with get_shield_remaining().
func get_damage_taken_multiplier(target: Node) -> float:
	if not _charge_step():
		return 1.0
	if target == null or not is_instance_valid(target):
		return 1.0
	return ModStatusEffects.get_damage_taken_multiplier(target)


## Spawns a flying mod projectile (see ModProjectile) at `origin`,
## travelling along `direction`. `spec` is a ModHook projectile dict
## (visual / speed / damage / explodes_on_impact / ...); `hooks` are
## the firing weapon's attached hooks (on_hit / on_kill run on impact).
## Returns the ModProjectile node, or null without a root.
func spawn_projectile(spec: Dictionary, origin: Vector3, direction: Vector3, hooks: Array = []) -> Node:
	if not _charge_step():
		return null
	if _root == null:
		return null
	var p := ModProjectile.new()
	p.setup(spec, hooks, _player)
	_root.add_child(p)
	p.launch(origin, direction)
	return p


func _track(node: Node, pos: Vector3) -> void:
	last_spawned = node
	last_spawned_position = pos


## ClassDB only knows native classes; script global classes (class_name)
## are checked against the project's global class list instead.
static func _has_script_class(cls_name: String) -> bool:
	for e in ProjectSettings.get_global_class_list():
		if (e as Dictionary).get("class") == cls_name:
			return true
	return false
