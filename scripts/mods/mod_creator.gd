# FORGEFALL — ModCreator (v0.8 chunk 2: LLM mod creation, Worker A)
# Turns a player's mod idea into an installed user mod, behind human
# approval. The pipeline is generation -> candidate -> HUMAN APPROVAL
# (the Create Mod UI shows the summary and only calls install() on the
# player's Install tap) -> install. NOTHING installs silently, and
# NOTHING is written to user://mods/ until install().
#
# - generate(idea): async. The LLM (ForgeLLM.request_generation) returns
#   a RAW generation object {manifest, payload, summary} or {error};
#   ModCreator turns it into a CANDIDATE via _candidate_for() (mod_id,
#   validation) and emits it via generation_ready(candidate).
# - validate(candidate): "" = OK, else an error. A candidate whose
#   "error" field is set is NEVER installable.
# - install(candidate): the ONLY write path. Re-validates, picks a
#   collision-free mod id, writes user://mods/<mod_id>/manifest.json +
#   payload file (block.json for blocks, mod.gd for scripts), rescans,
#   and verifies the installed record is error-free — a bad install is
#   rolled back (folder removed) and reported, never left behind.
#
# Candidate Dictionary shape (EXACT — Worker B's UI and Worker C's tests
# depend on it):
#   {"mod_id": String, "name": String, "kind": "block"|"script",
#    "manifest": Dictionary, "payload": String, "summary": String,
#    "error": String}
#
# USAGE (forge_menu): var creator := ModCreator.new(); add_child(creator)
# (it must be in the scene tree for the network path — the mock path
# works without a tree); creator.generation_ready.connect(_on_candidate);
# creator.generate(idea). The caller owns the approval step: show
# candidate["summary"], call creator.install(candidate) ONLY on Install.
#
# TEST SEAM: static var mock_generation — when non-empty, generate()
# builds its candidate from it (raw generation shape: {manifest, payload,
# summary} or {error}) through the SAME validation path as a real
# generation, instead of calling the network. Never set in production.
#
# No key -> generation returns the error "DeepSeek key required — add it
# in the Forge menu", never hangs. The Forge build path (SYSTEM_PROMPT /
# validate_modspec / spec_ready) is untouched.
extends Node
class_name ModCreator

signal generation_ready(candidate: Dictionary)

## Chat (v0.5.4 chat, Worker B): plain-text assistant reply.
signal chat_reply(text: String)
## Chat failure. NEVER a silent template/offline reply — the UI shows
## this message. No key -> NO_KEY_CHAT_ERROR below.
signal chat_error(message: String)

## Test seam (Worker C): see header. Raw generation shape, NOT a
## candidate — generate() parses it through _candidate_for() exactly
## like a real generation result.
static var mock_generation: Dictionary = {}

## Test seam for chat(): when non-empty, chat() emits chat_reply with
## this text instead of calling the network. Never set in production.
static var mock_chat_reply: String = ""

const NO_KEY_ERROR := "DeepSeek key required — add it in the Forge menu"
## User-facing no-key message for chat (v0.5.4 contract: names where to
## add the key). Differs from NO_KEY_ERROR on purpose — chat_error is
## shown verbatim in the chat UI.
const NO_KEY_CHAT_ERROR := "No DeepSeek key — add one in Options/Forge settings"
const MAX_SUMMARY_CHARS := 300
const _MAX_ID_ATTEMPTS := 100

## HOOK ADDENDUM (v0.5.6: hook scripts, Worker B). Appended to EVERY
## generation idea before the LLM call (ForgeLLM's own generation
## template lives in scripts/forge/* and is untouched). Two ways to
## express hook behaviour, in strict preference order: (1) the
## EFFECT-KINDS TABLE — data hooks, preferred whenever they cover the
## request; (2) a HOOK SCRIPT — GDScript, `extends ModHook`, written ONLY
## when nothing in the table covers the request. The addendum teaches
## the hook-script format + the FULL hook-script allowlist, mirrored
## from ModAPI.HOOK_ALLOWED_* (Worker A's single authoritative list —
## the prompt documents it exactly, no more, no less; the generation
## system prompt's shorter ModAPI list predates it) + the prefer-table
## rule + constraints + budget + one few-shot pull/vortex example. A
## hook script outside the allowlist is rejected, never repaired. The
## approval screen shows every hook script's full source, labelled
## LLM-authored, before Install.
const HOOK_PROMPT_ADDENDUM := """
HOOK SCRIPTS AND THE EFFECT-KINDS TABLE (v0.5.6) — read this before deciding how the mod behaves. A hook is behaviour attached to the mod's weapon at one hook point: "on_fire"|"projectile_spawn" (weapon fires), "on_hit" (a shot struck something), "on_kill" (a shot killed its target), "on_damage_taken" (the player took damage), "take_damage" (v0.5.9 — a character WOULD take damage, BEFORE it applies; see TAKE_DAMAGE below).

PREFER THE TABLE. Most hook behaviour is a DATA hook: a hook dict with an "effects" array (and/or a "projectile" on a fire point). Use the table whenever it covers the request. The effect kinds are:
- heal {"amount": 1-500}, explosion {"radius": 0.5-20, "damage": 0-500}, smoke {"duration_sec": 1-120}, announce {"title": "...", "subtitle": "..."}, damage_mult {"value": 0-5}
- STATUS kinds (need a target — see STATUS EFFECTS below): slow {"factor": 0.05-1.0, "duration_sec": 0.5-30}, freeze {"duration_sec": 0.5-10}, burn {"damage_per_sec": 1-500, "duration_sec": 0.5-30}, knockback {"force": 1-30}, pull {"force": 1-30}, poison {"damage_per_sec": 1-500, "duration_sec": 0.5-30}, bleed {"damage_per_sec": 1-500, "duration_sec": 0.5-30}, regen {"heal_per_sec": 1-500, "duration_sec": 0.5-30}, haste {"factor": 1.05-2.5, "duration_sec": 0.5-30}, restrained {"duration_sec": 0.5-10}, prone {"force": 1-30, "duration_sec": 0.5-10}, sleep {"duration_sec": 0.5-30}, confusion {"force": 1-10, "duration_sec": 0.5-30}, blind {"factor": 0.05-1.0, "duration_sec": 0.5-30}, weaken {"factor": 0.05-1.0, "duration_sec": 0.5-30}, exhaustion {"duration_sec": 0.5-60}, typed_damage {"damage_type": "acid"|"cold"|"fire"|"lightning"|"necrotic"|"poison"|"psychic"|"radiant"|"thunder", "amount": 1-500, "duration_sec": 0.5-30}, shield {"amount": 1-500, "duration_sec": 0.5-30}, vulnerable {"factor": 1.05-5.0, "duration_sec": 0.5-30}, thorns {"reflect_mult": 0.0-2.0, "duration_sec": 0.5-30}, petrified {"duration_sec": 0.5-30}
Hook dict: {"hook_id": "<lowercase [a-z0-9_]>", "hook_point": "on_fire"|"projectile_spawn"|"on_hit"|"on_kill"|"on_damage_taken"|"take_damage", "display_name": "<name>", "description": "<one line>", ...}.
A fire-point hook (on_fire / projectile_spawn) may carry "projectile": {"visual": "<what it looks like, e.g. 'watermelon' or 'glowing laser beam'>", "shape": "beam"|"sphere"|"cube"|"blob"|"bullet", "speed": 1-200, "damage": 0-500 (-1 = use the weapon's damage), "range": 1-500, "size": 0.05-5, "gravity": -50-50, "pierce": true|false, "explodes_on_impact": true|false, "explosion_radius": 0-20, "explosion_damage": 0-500, "chain_targets": 0-5, "chain_radius": 1-15, "chain_falloff": 0.1-1.0, "element": "fire"|"cold"|"lightning"|"acid"|"poison"|"radiant"|"necrotic"|"thunder"|"force"|"water"}. CHAIN: after the primary hit, the projectile arcs to up to chain_targets further enemies within chain_radius (default 3) of each previous hit; each jump deals the primary damage * chain_falloff^jump (default 0.5). With "element" the chain hits carry that element's rider (lightning knocks back + conducts off wet targets); without it they are plain damage. Chain hits never run hooks and never chain again. A weapon whose hits chain to nearby enemies is a projectile_spawn hook with chain_targets >= 1 — do NOT express chaining as a separate effect or hook script. The weapon fires THIS projectile instead of hitscan. Example: a Long Laser Pistol is a p9-based weapon mod with a projectile_spawn hook whose projectile is {"visual": "glowing laser beam", "shape": "beam", "speed": 60, "damage": 45, "range": 120, "explodes_on_impact": false}. Example: a Watermelon LMG is an lmg-based weapon mod with a projectile_spawn hook whose projectile is {"visual": "watermelon", "shape": "sphere", "speed": 28, "damage": 40, "range": 90, "explodes_on_impact": true, "explosion_radius": 4, "explosion_damage": 60}. Example: a 3-round burst lightning gun is an lmg-based weapon mod with block fields fire_mode "burst" + burst_size 3 and a projectile_spawn hook whose projectile is {"visual": "glowing lightning bolt", "shape": "beam", "speed": 60, "damage": 25, "range": 120, "element": "lightning", "chain_targets": 2, "chain_radius": 4, "chain_falloff": 0.5}.
Any hook may carry "effects": [{"kind": "heal", "amount": 1-500} | {"kind": "explosion", "radius": 0.5-20, "damage": 0-500} | {"kind": "smoke", "duration_sec": 1-120} | {"kind": "announce", "title": "...", "subtitle": "..."} | {"kind": "damage_mult", "value": 0-5} | {"kind": "slow", "factor": 0.05-1.0, "duration_sec": 0.5-30} | {"kind": "freeze", "duration_sec": 0.5-10} | {"kind": "burn", "damage_per_sec": 1-500, "duration_sec": 0.5-30} | {"kind": "knockback", "force": 1-30} | {"kind": "pull", "force": 1-30} | {"kind": "poison", "damage_per_sec": 1-500, "duration_sec": 0.5-30} | {"kind": "bleed", "damage_per_sec": 1-500, "duration_sec": 0.5-30} | {"kind": "regen", "heal_per_sec": 1-500, "duration_sec": 0.5-30} | {"kind": "haste", "factor": 1.05-2.5, "duration_sec": 0.5-30} | {"kind": "restrained", "duration_sec": 0.5-10} | {"kind": "prone", "force": 1-30, "duration_sec": 0.5-10} | {"kind": "sleep", "duration_sec": 0.5-30} | {"kind": "confusion", "force": 1-10, "duration_sec": 0.5-30} | {"kind": "blind", "factor": 0.05-1.0, "duration_sec": 0.5-30} | {"kind": "weaken", "factor": 0.05-1.0, "duration_sec": 0.5-30} | {"kind": "exhaustion", "duration_sec": 0.5-60} | {"kind": "typed_damage", "damage_type": "acid"|"cold"|"fire"|"lightning"|"necrotic"|"poison"|"psychic"|"radiant"|"thunder", "amount": 1-500, "duration_sec": 0.5-30} | {"kind": "shield", "amount": 1-500, "duration_sec": 0.5-30} | {"kind": "vulnerable", "factor": 1.05-5.0, "duration_sec": 0.5-30} | {"kind": "thorns", "reflect_mult": 0.0-2.0, "duration_sec": 0.5-30} | {"kind": "petrified", "duration_sec": 0.5-30}]. Example: heal-on-kill is an on_kill hook with effects [{"kind": "heal", "amount": 15}]. A damage_mult effect on on_hit multiplies that hit's damage; on on_damage_taken it reduces the damage taken.
STATUS EFFECTS: every status kind needs a target — put them on on_hit or on_kill (they affect the hit target), on_damage_taken (they affect the player), or take_damage (they affect the character about to take damage — see TAKE_DAMAGE below). NEVER put a status effect on a fire point (on_fire / projectile_spawn) — it is rejected. What each kind REALLY does (never use one kind to mean another): slow multiplies movement speed by "factor" (0.5 = half speed). freeze pins the target: speed 0 AND knockback cannot move it. burn is pure damage over time. knockback is one instant shove AWAY from the hit point; pull is one instant yank TOWARD the hit point. poison is damage over time PLUS a mild slow (x0.85) — use poison when the venom should also slow, burn when it should not. bleed is damage over time that ticks FASTER while the target moves — use bleed for wounds that worsen with movement, never as a synonym for burn/poison. regen heals over time. haste multiplies movement speed (1.5 = 50% faster) — movement ONLY, it does not change fire rate. restrained: speed 0, can still act, CAN still be shoved. prone: knocks the target down (impulse + speed 0), then it stands back up when the duration ends. sleep: speed 0 + pinned, and it WAKES EARLY the moment the target takes any damage — use sleep for incapacitation that damage breaks, freeze for incapacitation that damage does NOT break. confusion: random stumble impulses (erratic movement). blind: accuracy disruption — enemies' shots spread wider, the player's weapon spread widens. weaken: damage DEALT reduced. exhaustion: each application adds ONE level (speed drops 15% per level); 6 levels kill. typed_damage: instant damage of one D&D damage type + a rider that makes the type real — fire burns, cold slows (x0.6), lightning knocks back (6), thunder knocks back hard (12) + knocks prone, acid weakens (x0.7, armour melt), necrotic adds an exhaustion level, poison poisons, psychic confuses, radiant blinds (x0.5). DAMAGE-INTERCEPTION KINDS (v0.5.9 — these four are REAL now, implemented through the take_damage interception; use them directly, never substitute another kind): shield is an absorbing pool — {"kind": "shield", "amount": 1-500, "duration_sec": 0.5-30} gives the target a pool that eats incoming damage first (re-applying ADDS to the remaining pool); vulnerable multiplies incoming damage — {"kind": "vulnerable", "factor": 1.05-5.0, "duration_sec": 0.5-30} (use it to mark an enemy so FOLLOW-UP hits deal more — e.g. an on_hit hook applies vulnerable to the hit target); thorns reflects damage actually taken back to the attacker — {"kind": "thorns", "reflect_mult": 0.0-2.0, "duration_sec": 0.5-30} (reflect_mult 0.5 = half the damage taken bounces back; reflected damage never reflects again); petrified turns the target to stone — {"kind": "petrified", "duration_sec": 0.5-30} nullifies ALL incoming damage AND pins the target (speed 0, cannot be shoved) while active; damage does NOT break it (unlike sleep). Constructs and elementals are IMMUNE to petrified (it does nothing on them). Do NOT invent other kinds: stunned / paralyzed / unconscious / grappled / frightened / charmed / deafened / silence / lifesteal / curse are NOT kinds — they cannot be genuinely implemented (no act-blocking, steering, faction, or ability-gating hook exists). Express the request with the real kinds above (e.g. "stun" = freeze or sleep). Example: a bubble that slows enemies is an on_hit hook with effects [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0}] — do NOT express slowing as smoke or announce; slow is its own kind.

TAKE_DAMAGE (v0.5.9) — the pre-damage hook point. A take_damage hook fires when a character WOULD take damage, BEFORE it applies. Its target is the character about to be hurt (ctx["target"]); ctx["attacker"] is the attacker when known (may be null for explosions). A take_damage hook may (a) return {"damage_mult": X} to scale THIS hit before it lands (0.0 = nullify this hit), (b) apply a damage-interception state to the target with api.apply_status_effect(target, "shield"|"vulnerable"|"thorns"|"petrified", {...}, origin) — the state then applies to THIS hit (a shield granted here absorbs this hit) and to later hits until it expires, or (c) carry data-hook "effects" — a damage_mult effect scales this hit; a shield/vulnerable/thorns/petrified effect applies that state to the target before the hit resolves. Resolution order for a hit: hooks first, then petrified nullifies -> vulnerable multiplies -> shield absorbs -> thorns reflects a share of what was actually taken. Examples: a "ward" mod is a take_damage hook with effects [{"kind": "shield", "amount": 50, "duration_sec": 10.0}]; a "curse of vulnerability" is an on_hit hook that applies vulnerable to the hit target; a "mirror armour" is a take_damage hook with effects [{"kind": "thorns", "reflect_mult": 0.5, "duration_sec": 10.0}]; a "stone skin" is a take_damage hook with effects [{"kind": "petrified", "duration_sec": 3.0}]. NEVER use take_damage hooks to deal damage in a loop (a hook that deals damage on every hit re-enters take_damage — nested hook dispatch is suppressed, but the damage still lands).

WRITE A HOOK SCRIPT ONLY WHEN THE TABLE CANNOT EXPRESS THE REQUEST. Script-only behaviour includes: pulling/dragging the hit target toward a point (pull/vortex — the table's knockback only pushes AWAY), behaviour that branches on ctx (e.g. a different effect when the player is low on HP), chaining several ModAPI calls in one run, or behaviour that depends on a value the table cannot read. When you write a script, do NOT downgrade to a closest-buildable table substitute — the script IS the build. Effect kinds stay the preferred path: use them whenever they cover the request; write a script ONLY when nothing in the table covers it.

HOOK-SCRIPT FORMAT:
- Carriage: the script travels as the "code" string of a hook dict. Block mod: add a top-level "hooks" array to the payload, next to the "block" object — NEVER put "hooks" inside the "block" object. Script mod: implement get_hooks() -> Array returning the hook dicts. Hook dict: {"hook_id": "<lowercase [a-z0-9_]>", "hook_point": "on_fire"|"projectile_spawn"|"on_hit"|"on_kill"|"on_damage_taken"|"take_damage", "display_name": "<name>", "description": "<one line>", "code": "<hook script source>"}.
- A hook with "code" runs ONLY its code — any "effects" or "projectile" on the SAME hook are IGNORED. Put everything the hook does inside run(). (A hook with no "code" is a data hook: its effects/projectile are applied by the game.)
- The script MUST start with `extends ModHook` and implement: func run(api: ModAPI, ctx: Dictionary) -> Dictionary. Do NOT add get_hook_info() — the hook dict already carries hook_id/hook_point. Max 20000 chars.
- Return contract: return a Dictionary with any of {"damage_mult": float, "healed": float, "exploded": bool, "announced": bool, "status_applied": bool}. Effects applied directly through `api` need not be reported; the return value is for damage accounting. Return {} when the hook does nothing.
- ctx keys by hook point (these are the ONLY ctx keys — never read another):
  - on_fire / projectile_spawn: {"weapon_id": String, "position": Vector3, "direction": Vector3}. NO target — a fire-point hook cannot touch a target (none exists yet).
  - on_hit / on_kill: {"position": Vector3, "hit_position": Vector3, "damage": float, "target": Node-or-null, "headshot": bool, "weapon_id": String} (hitscan) — or with "projectile": Dictionary instead of "headshot"/"weapon_id" when fired by a custom projectile.
  - on_damage_taken: {"damage": float, "hp_before": float, "hp_after": float, "position": Vector3, "weapon_id": String}. NO target — the target IS the player; use api.get_player() / api.get_player_position().
  - take_damage: {"damage": float, "target": Node-or-null (the character about to be hurt), "attacker": Node-or-null (may be null for explosions), "hit_position": Vector3, "position": Vector3, "headshot": bool, "hp_before": float (player only)}. The hook runs BEFORE the damage applies: return {"damage_mult": X} to scale this hit, or apply a shield/vulnerable/thorns/petrified state to ctx["target"] with api.apply_status_effect — the state applies to THIS hit and later hits until it expires.
- Always read ctx with ctx.get("key", default) and check `is` before use (e.g. `if not (tgt is Node3D): return {}`). A hook that errors on a missing key disables its mod — read defensively.

MODAPI / ALLOWLIST — THE ONLY CALLS A HOOK SCRIPT MAY MAKE. The validator (ModAPI.HOOK_ALLOWED_*) REJECTS anything not listed here — no more, no less. Values that flow OUT of `api` (a Node, a Vector3, ...) may only be passed BACK into `api` or used through the safe methods / components below.
- api.<method> — the ONLY game calls (all 23 ModAPI methods): get_player, get_root, get_player_position, get_aim_point, spawn_voxel_box, spawn_cover, spawn_pickup, spawn_turret, give_weapon, fire_effect, announce, get_player_health, heal_player, apply_status_effect, spawn_projectile, has_status_effect, clear_status_effect, spawn_elemental_emitter, get_creature_type, is_creature_immune_to_status, get_ability_modifier, get_shield_remaining, get_damage_taken_multiplier.
  Signatures: get_player() -> Node3D — the player node (may be null). get_root() -> Node — the scene root builds attach to. get_player_position() -> Vector3 — player position, or Vector3.ZERO. get_aim_point() -> Vector3 — crosshair raycast point ("marked" position). spawn_voxel_box(size: Vector3, color: Color, position: Vector3, solid: bool) -> Node3D — one voxel block: visible cube + optional solid collider. spawn_cover(shape: String, size_voxels: Vector3i, hp: float, position: Vector3) -> Node — destructible voxel cover slab; shape wall|tower|barricade, size each 1-12, hp 50-500. spawn_pickup(kind: String, position: Vector3) -> Node — ammo|health pickup. spawn_turret(position: Vector3, duration_sec: float, damage_mult: float, range_mult: float) -> Node — sentry turret; duration 5-120. give_weapon(weapon_id: String, damage_mult: float, range_mult: float, mag_mult: float, fire_mode: String = "", burst_size: int = 0) -> bool — give a base weapon (manticore|longeye|breacher|hornet|p9|raptor|lmg), tuned by multipliers (1.0 = stock); optional fire_mode "auto"|"semi"|"burst"|"bolt"|"pump" + burst_size 2-10 (a 3-round burst = fire_mode "burst", burst_size 3). fire_effect(kind: String, position: Vector3, radius: float, damage: float, duration_sec: float = 20.0, element: String = "fire") -> void — "explosion" (radius + damage), "smoke" (duration_sec), or "elemental" (a one-shot elemental burst of `element` at position: radius + damage, one hit). spawn_elemental_emitter(element: String, position: Vector3, radius: float, duration_sec: float, damage_per_sec: float) -> Node — persistent elemental emitter field: voxel particles + one elemental damage type + radius + duration, damaging ENEMIES ONLY inside the radius every 0.5 s (see ELEMENTAL EMITTERS below). announce(title: String, subtitle: String) -> void — HUD banner. get_player_health() -> float — current player HP, or -1 with no player. heal_player(amount: float) -> float — heals the player; returns HP afterwards, or -1. apply_status_effect(target: Node, kind: String, params: Dictionary, origin: Vector3) -> bool — applies a status kind to a target. Kinds: slow {"factor": 0.05-1.0, "duration_sec": 0.5-30}, freeze {"duration_sec": 0.5-10}, burn {"damage_per_sec": 1-500, "duration_sec": 0.5-30}, knockback {"force": 1-30} (pushes AWAY from `origin`), pull {"force": 1-30} (pulls TOWARD `origin`), poison {"damage_per_sec": 1-500, "duration_sec": 0.5-30} (DOT + slow x0.85), bleed {"damage_per_sec": 1-500, "duration_sec": 0.5-30} (DOT, ticks faster while moving), regen {"heal_per_sec": 1-500, "duration_sec": 0.5-30}, haste {"factor": 1.05-2.5, "duration_sec": 0.5-30} (movement speed only), restrained {"duration_sec": 0.5-10} (speed 0, can act, can be shoved), prone {"force": 1-30, "duration_sec": 0.5-10} (knockdown + speed 0), sleep {"duration_sec": 0.5-30} (wakes on damage), confusion {"force": 1-10, "duration_sec": 0.5-30} (random stumbles), blind {"factor": 0.05-1.0, "duration_sec": 0.5-30} (accuracy disruption), weaken {"factor": 0.05-1.0, "duration_sec": 0.5-30} (damage dealt reduced), exhaustion {"duration_sec": 0.5-60} (+1 level per application, 6 = death), typed_damage {"damage_type": "acid"|"cold"|"fire"|"lightning"|"necrotic"|"poison"|"psychic"|"radiant"|"thunder", "amount": 1-500, "duration_sec": 0.5-30} (instant damage + rider), shield {"amount": 1-500, "duration_sec": 0.5-30} (absorbing pool — eats incoming damage first; re-applying ADDS to the pool), vulnerable {"factor": 1.05-5.0, "duration_sec": 0.5-30} (incoming damage multiplied), thorns {"reflect_mult": 0.0-2.0, "duration_sec": 0.5-30} (reflects a share of damage actually taken back to the attacker), petrified {"duration_sec": 0.5-30} (nullifies ALL incoming damage + pins the target; damage does not break it; constructs + elementals are immune). has_status_effect(target: Node, kind: String) -> bool — true when the target has that active effect. clear_status_effect(target: Node, kind: String) -> bool — removes one kind ("all" removes every effect); the cure primitive. spawn_projectile(spec: Dictionary, origin: Vector3, direction: Vector3, hooks: Array = []) -> Node — flying mod projectile; spec is a hook projectile dict. get_shield_remaining(target: Node) -> float — the target's remaining shield pool (0.0 = no shield). get_damage_taken_multiplier(target: Node) -> float — 0.0 while petrified, else the vulnerable factor (1.0 = not vulnerable).
- ctx.<method> — read-only Dictionary methods ONLY: get, has, has_all, keys, values, size, is_empty. Read ctx ONLY through these (e.g. ctx.get("target", null)). Never mutate ctx.
- Bare globals — pure math / conversions / value construction ONLY: print, str, int, float, bool, Vector2, Vector3, Vector3i, Vector4, Color, Dictionary, Array, String, StringName, clampf, clampi, min, max, minf, maxf, abs, absf, sign, signf, floor, ceil, round, lerp, lerpf, lerp_angle, randf, randi, randf_range, randi_range, sqrt, pow, sin, cos, tan, asin, acos, atan, atan2, deg_to_rad, rad_to_deg, is_equal_approx, is_zero_approx, is_inf, is_nan, is_finite, typeof, range, snapped, snappedf, clamp, move_toward, posmod, fmod, wrap, wrapf, wrapi, pingpong, smoothstep, inverse_lerp, remap, ease, step_decimals, is_same.
- Types — annotations / `is` / `as` ONLY: ModAPI, ModHook, Dictionary, Array, String, StringName, int, float, bool, Vector2, Vector3, Vector3i, Vector4, Color, Variant, Node, Node3D, CharacterBody3D, PackedStringArray, PackedVector3Array, PackedFloat32Array, PackedInt32Array.
- Methods on your OWN locals and on values chained off a call — pure value methods ONLY: Vector: normalized, length, length_squared, distance_to, distance_squared_to, direction_to, dot, cross, lerp, slerp, rotated, angle_to, angle_to_point, abs, ceil, floor, round, sign, clamp, clamped, snapped, bounce, reflect, slide, project, limit_length, is_equal_approx, is_zero_approx, is_finite, is_normalized, posmod, max_axis_index, min_axis_index. Dictionary: get, has, has_all, keys, values, size, is_empty, duplicate, get_or_add, find_key, erase, clear, merge, sort. Array: front, back, count, append, push_back, pop_back, pop_front, push_front, insert, remove_at, slice, reverse, min, max, bsearch, shuffle, sort_custom. String: substr, find, findn, rfind, contains, begins_with, ends_with, to_lower, to_upper, strip_edges, trim_prefix, trim_suffix, replace, replacen, split, join, format, pad_zeros, pad_decimals, is_valid_int, is_valid_float, to_int, to_float, capitalize, repeat, reverse, lpad, rpad, get_slice, left, right, mid, dedent, indent, split_floats, hex_encode, hex_decode. Color: to_html, lightened, darkened, inverted, blend, srgb_to_linear, linear_to_srgb. (erase / clear / merge / append / ... mutate ONLY dicts/arrays you created yourself — never ctx.)
- Components — the ONLY dotted attribute reads: .x, .y, .z, .w, .r, .g, .b, .a.
- NEVER — REJECTED: any node property or method (.global_position, .position, .hp, .name, .queue_free, .get_node, .call, ...), any api.<property> (api.last_spawned and api.last_spawned_position are properties, NOT methods — REJECTED), any other dotted access, any engine type/member not listed above. In particular you CANNOT read node properties: the only position facts you get are ctx's Vector3s (position / hit_position) and api.get_player_position() / api.get_aim_point(). Anything not listed here DOES NOT EXIST for hook scripts — never call it (no get_enemies, no damage_target, no move_target, no get_target_position, no set_player_health, no other game function).
NOTE: the generation system prompt lists an older, shorter ModAPI list. For HOOK SCRIPTS the allowlist in this addendum is the full, current surface — it adds get_player_health, heal_player, apply_status_effect, spawn_projectile, has_status_effect, clear_status_effect, and spawn_elemental_emitter, plus the ctx / builtin / type / safe-method / component lists. Use this list, not the shorter one. (The ForgeLLM system prompt documents the same ModAPI surface separately and is owned by the coordinator — it needs the same catalog update.)

ELEMENTAL EMITTERS (v0.5.8) — a hook script or ModBlock script may spawn one with api.spawn_elemental_emitter(element, position, radius, duration_sec, damage_per_sec), or pop a one-shot burst with api.fire_effect("elemental", position, radius, damage, duration_sec, element). The catalog (all elements + what each does): fire = fire damage + burn rider (damage over time); cold = cold damage + slow rider (x0.6 speed); lightning = lightning damage + knockback rider, x1.5 + chains to the nearest other enemy within 3 m for 50% vs WET targets; acid = acid damage + weaken rider (damage dealt x0.7); poison = poison damage + poison rider (damage over time + slow x0.85); radiant = radiant damage + blind rider (accuracy x0.5); necrotic = necrotic damage + +1 exhaustion level per hit; thunder = thunder damage + heavy knockback + brief prone; force = force damage (direct) + knockback — pure kinetic shove; water = small water damage + slow x0.6 + EXTINGUISHES burn + marks targets WET 4 s (lightning conducts off wet: x1.5 + chain). Water does NOT clear poison, bleed, or any other DOT. Emitters damage ENEMIES ONLY (never the player). Data hooks CANNOT spawn emitters (no emitter effect kind exists) — use a hook script or a ModBlock script.

SPELL SCHOOLS (v0.5.8) — TAG ONLY: if the mod idea is spell-like, the generation object carries top-level "spell_school" set to exactly ONE of: abjuration (protective magic — wards, shields, banishment), conjuration (summoning and calling), divination (knowledge — revealing, sensing, foresight), enchantment (mind magic — charm, compulsion), evocation (raw energy — fire, lightning, force), illusion (deception — phantasms, false sense), necromancy (life and death — draining, undeath), transmutation (change — altering form, matter, properties). For non-spell mods OMIT it. The school NEVER changes mechanics (no damage bonus, no cost change, no spell slots, no skills/feats) — it shows in approval + mod info. NEVER put "spell_school" inside the block object (the loader rejects unknown block fields) or the manifest — top-level generation field only; the game persists it into the payload on install.

CONSTRAINTS — a hook script that breaks any of these is REJECTED, never repaired:
- Allowlist-only (see MODAPI / ALLOWLIST above): only the listed calls. No engine internals, no filesystem, network, OS, eval, or code-loading code.
- Structural: no `while` loops (use a bounded `for`), no await, no yield, no preload, no super, no signal / enum / class / static / breakpoint, no `@` annotations, no `$` lookups, no lambdas (func(...) literals), no engine callbacks (_init, _process, _ready, ...), no recursion (a function calling itself), no `.new` (dynamic instantiation).
- Bounded loops only: `for i in range(N)` with N <= 1000; keep loops small — the run budget below aborts runaway hooks.
- Run budget: at most 200 ModAPI calls per hook run, 100 ms per hook run, 250 ms per whole dispatch. Exceeding the budget aborts the dispatch and disables the mod visibly. Honest limit: a tight infinite loop with no api calls cannot be preempted — it hangs the frame — so loops MUST be bounded.
- Max 20000 chars per hook script. Max 32 hooks per mod.
- Helper functions are allowed (same allowlist, no recursion). Member variables are not forbidden, but the same hook instance runs for every shot, so member state persists between shots — avoid them; prefer locals.
- SCRIPT MODS ONLY: the whole script file is also text-scanned for the old denylist — FileAccess, DirAccess, OS.execute, OS.shell_open, OS.create_process, OS., Engine.get_singleton, Expression, GDScript.new, load(, ResourceLoader, preload(, ClassDB, JavaScriptBridge, HTTPRequest, HTTPClient, TCPServer, TCPStreamPeer, UDPServer, PacketPeerUDP, WebSocketPeer, Thread, Semaphore, Mutex, .new(, call(, call_deferred(, @tool — keep those substrings out of the ENTIRE script, even strings/comments inside hook code. (Block mods: hook code is judged by the allowlist only.)
- A hook script that errors at run time disables its mod visibly — never crashes the game. Write defensively: always read ctx with ctx.get("key", default) and check `is` before use.

FEW-SHOT EXAMPLE — a VALID hook script. Pull/vortex hook: drags the hit target toward the PLAYER (the vortex center — the table cannot express "pull": knockback only pushes AWAY, so this needs a script):
extends ModHook
func run(api: ModAPI, ctx: Dictionary) -> Dictionary:
	var tgt = ctx.get("target", null)
	if not (tgt is Node3D):
		return {}
	var hit = ctx.get("hit_position", api.get_player_position())
	var player_pos = api.get_player_position()
	var away = hit - player_pos
	if away.length_squared() < 0.001:
		return {}
	var origin = hit + away
	var pulled = api.apply_status_effect(tgt, "knockback", {"force": 8.0}, origin)
	return {"status_applied": pulled}
(How it works: knockback pushes AWAY from `origin`, and the target sits at the hit point — so the origin is mirrored past the hit point on the far side from the player, and "away from origin" then points back TOWARD the player, pulling the target in. No node property is read: hit and player_pos are plain Vector3s from ctx / api.)

The approval screen lists every invented hook and every hook script before Install, so describe each hook plainly in the summary.

D&D CREATURE TYPES + ABILITY SCORES (v0.5.8 — the game enforces the enforced rows; never write a hook whose whole point is an effect the target is immune to):
- All 14 types: aberration, beast, celestial, construct, dragon, elemental, fey, fiend, giant, humanoid, monstrosity, ooze, plant, undead. Every enemy carries one (default humanoid for militia).
- Enforced: construct — immune poison + psychic damage, immune to poisoned/sleep/exhaustion/petrified; undead — immune poison damage, immune to poisoned/sleep/exhaustion; elemental — immune poison damage, immune to poisoned/sleep/exhaustion/restrained/prone/petrified; fiend — immune poison damage, RESIST cold/fire/lightning, immune to poisoned; ooze — RESIST acid, immune to exhaustion/prone; celestial — RESIST radiant/necrotic, immune to exhaustion; fey — immune to sleep; plant — immune to exhaustion; aberration — RESIST psychic. Beast, dragon, giant, humanoid, monstrosity: NO blanket immunities (dragon immunity varies by ancestry — never guess one). No type is vulnerable to anything (undead are NOT vulnerable to radiant). Charmed/frightened/paralyzed/deafened/grappled immunities are real 5e traits but LORE-ONLY (no game mechanic) — never write a hook that depends on them. (Petrified USED to be lore-only; v0.5.9 made it a real kind, enforced for construct/elemental.)
- Consequence for hooks: a poison hook does NOTHING to a construct/undead; sleep never lands on undead; exhaustion never lands on a construct. If the mod idea is "poison the undead", say in the summary that it will do nothing — do not silently substitute another effect.
- ABILITY SCORES: STR (Strength), DEX (Dexterity), CON (Constitution), INT (Intelligence), WIS (Wisdom), CHA (Charisma). Scores 1-30, 10 = average. Modifier = floor((score-10)/2): 10 -> +0, 16 -> +3, 8 -> -1. A class grants bonuses by adding to scores (e.g. +2 STR). Name scores in the description/summary text only — there is no score field in the block schema."""

var _llm: ForgeLLM = null
var _generating := false
var _pending_candidates: Array = []
# Chat state (v0.5.4 chat): separate from generation — chat and
# generation never share in-flight state, so a chat reply can never
# disturb an in-flight generation and vice versa.
var _chatting := false
var _chat_http_outstanding := false
var _pending_chat: Array = []


## Starts an async generation for `idea`. Exactly one candidate is
## emitted per call via generation_ready(candidate) — a failed
## generation emits a candidate with "error" set, never nothing.
## ENTRY-POINT CONTRACT (v0.5.3, binding — Forge MAKE mode calls this
## read-only): generate(idea: String) -> void + signal
## generation_ready(candidate: Dictionary) keep this exact signature.
## The idea is augmented with HOOK_PROMPT_ADDENDUM before the LLM call
## (the hook-invention instructions); the mock path is unaffected.
## Mock (mock_generation non-empty) takes precedence over the network
## AND over the empty-idea check, so tests are fully deterministic.
func generate(idea: String) -> void:
	if _generating:
		_queue_candidate(_error_candidate("generation already in progress"))
		return
	if not mock_generation.is_empty():
		_queue_candidate(_candidate_for(mock_generation))
		return
	var clean := idea.strip_edges()
	if clean.is_empty():
		_queue_candidate(_error_candidate("describe the mod you want to create"))
		return
	if not is_inside_tree():
		_queue_candidate(_error_candidate("ModCreator must be added to the scene tree before generating (the network request needs the tree)"))
		return
	_generating = true
	_ensure_llm()
	_llm.request_generation(clean + "\n\n" + HOOK_PROMPT_ADDENDUM)


## Chat (v0.5.4 chat, Worker B). Sends `messages` (Array of
## {role, text}) to DeepSeek with ChatPrompt.CHAT_SYSTEM_PROMPT and
## emits exactly one chat_reply(text) on success or chat_error(message)
## on failure. No key -> chat_error(NO_KEY_CHAT_ERROR). LLM/network
## failure -> chat_error. NEVER a silent template/offline reply.
## History is trimmed by ChatPrompt.trim_conversation() on every call,
## so costs stay bounded. One chat at a time — a concurrent call gets
## a chat_error instead of disturbing the in-flight request. Mock
## (mock_chat_reply non-empty) takes precedence over the network AND
## over the empty-messages check, so tests are fully deterministic.
func chat(messages: Array) -> void:
	if _chatting:
		_queue_chat_error("chat already in progress")
		return
	if not mock_chat_reply.is_empty():
		_queue_chat_reply(mock_chat_reply)
		return
	var trimmed := ChatPrompt.trim_conversation(messages)
	if trimmed.is_empty():
		_queue_chat_error("Type a message first.")
		return
	if ForgeConfig.load_key().is_empty():
		_queue_chat_error(NO_KEY_CHAT_ERROR)
		return
	if not is_inside_tree():
		_queue_chat_error("ModCreator must be added to the scene tree before chatting (the network request needs the tree)")
		return
	_chatting = true
	_request_chat_remote(trimmed, ForgeConfig.load_key())


## Generation with chat context (v0.5.4 chat, Worker B). Used by BOTH
## the Create tab and the Chat tab's CREATE FROM CHAT button.
## Empty conversation -> calls generate(request) directly, so behavior
## is IDENTICAL to the existing generate() path (Create tab keeps
## working unchanged, byte for byte). Non-empty conversation -> the
## trimmed history is embedded as context in the generation request
## (ChatPrompt.build_generation_context), so previous discussion is
## usable by the model. Outcome is the same as generate(): generation
## -> validation (forbidden-API scan, invented hooks allowed per
## v0.5.3) -> generation_ready(candidate) for the approval screen.
## Generation never installs anything.
func generate_with_context(conversation: Array, request: String) -> void:
	var trimmed := ChatPrompt.trim_conversation(conversation)
	if trimmed.is_empty():
		generate(request)
		return
	if request.strip_edges().is_empty():
		generate(request)
		return
	generate(ChatPrompt.build_generation_context(trimmed, request))


## Opening message for the chat tab (v0.5.4 chat): what chat can do +
## example prompts. The UI shows this when the chat tab first opens.
func get_greeting() -> String:
	return ChatPrompt.get_greeting()


## "" = candidate is installable, else an error string. A candidate
## whose "error" field is set fails with that error. Checks the candidate
## shape + manifest/payload consistency, then delegates the manifest +
## payload itself to ModLoader.validate_generated_mod(). Never repairs,
## never touches user://mods/.
func validate(candidate: Dictionary) -> String:
	var already := str(candidate.get("error", ""))
	if already != "":
		return already
	for key in ["mod_id", "name", "kind", "manifest", "payload", "summary", "error"]:
		if not candidate.has(key):
			return "candidate is missing '%s'" % key
	var mod_id := str(candidate.get("mod_id", ""))
	if mod_id.is_empty() or mod_id != sanitize_mod_id(mod_id) or mod_id.length() > 48:
		return "candidate mod_id '%s' is not a valid [a-z0-9_] id" % mod_id
	var cname := str(candidate.get("name", ""))
	if cname.strip_edges().is_empty():
		return "candidate name is empty"
	var kind := str(candidate.get("kind", ""))
	if kind not in ["block", "script"]:
		return "candidate kind must be 'block' or 'script'"
	var manifest: Variant = candidate.get("manifest", null)
	if not (manifest is Dictionary):
		return "candidate manifest is not an object"
	if str((manifest as Dictionary).get("kind", "")) != kind:
		return "candidate kind does not match manifest kind"
	if str((manifest as Dictionary).get("name", "")) != cname:
		return "candidate name does not match manifest name"
	var payload: Variant = candidate.get("payload", null)
	if not (payload is String) or str(payload).strip_edges().is_empty():
		return "candidate payload is empty"
	var summary: Variant = candidate.get("summary", null)
	if not (summary is String):
		return "candidate summary is not a string"
	if str(summary).length() > MAX_SUMMARY_CHARS:
		return "candidate summary exceeds %d chars" % MAX_SUMMARY_CHARS
	return ModLoader.validate_generated_mod(manifest as Dictionary, str(payload))


## Installs an approved candidate. "" = installed, else an error and
## NOTHING is left behind. Re-validates (a failed candidate is refused),
## picks a collision-free mod id (candidate mod_id, else _2, _3, ...),
## writes user://mods/<mod_id>/manifest.json + payload file, rescans,
## and verifies the installed record is error-free (this is the check
## that catches a script mod whose get_block_info() is bad — the static
## text scan cannot see that). Does NOT mutate the passed candidate.
func install(candidate: Dictionary) -> String:
	if str(candidate.get("error", "")) != "":
		return str(candidate.get("error", ""))
	var err := validate(candidate)
	if err != "":
		return err
	var base := str(candidate.get("mod_id", ""))
	var kind := str(candidate.get("kind", ""))
	_ensure_mods_dir()
	for attempt in range(_MAX_ID_ATTEMPTS):
		var final_id := base if attempt == 0 else "%s_%d" % [base, attempt + 1]
		if _id_taken(final_id):
			continue
		if _mod_folder_exists(final_id):
			continue
		# Working copy: install-time mod id + block_id normalization.
		# Re-validated before writing, so the installed bytes are exactly
		# what validation approved (block_id == folder id, always).
		var work: Dictionary = candidate.duplicate(true)
		work["mod_id"] = final_id
		if kind == "block":
			var normalized := _normalize_block_payload(str(work.get("payload", "")), final_id)
			if normalized.is_empty():
				return "block payload is not a JSON object"
			work["payload"] = normalized
		err = validate(work)
		if err != "":
			return err
		var werr := _write_mod_files(final_id, work)
		if werr != "":
			_remove_mod_folder(final_id)
			return werr
		ModLoader.rescan()
		var rec := ModLoader.find_mod(final_id)
		if rec.is_empty():
			_remove_mod_folder(final_id)
			ModLoader.rescan()
			return "install verification failed for '%s'" % final_id
		var rec_err := str(rec.get("error", ""))
		if rec_err != "":
			_remove_mod_folder(final_id)
			ModLoader.rescan()
			return rec_err
		return ""
	return "could not find a free mod id for '%s'" % base


# --- EDIT INSTALLED MODS (v0.5.9) --------------------------------------------
# Refine, don't reroll: EDIT loads an installed mod back into the
# creator with its context seeded (see edit_context_for()), the
# player describes the refinement ("make the bubble bigger"), a new
# candidate is generated WITH the original payload as context, and
# approval shows a DIFF vs the installed version before Install.
# install_update() is the ONLY write path for edits: it OVERWRITES
# the same mod id (never a second copy — the old version is gone),
# bumps the version (1.0 -> 1.1), and rolls back to the ORIGINAL
# files when verification fails (the installed mod is untouched
# until the update is approved + installed; Discard abandons the
# edit with no write at all).

## Bumps a mod version string: the LAST numeric component +1.
## "1.0" -> "1.1", "1.1" -> "1.2", "2.3.4" -> "2.3.5", "1" -> "2",
## "" / non-numeric -> "1.1". Never touches non-numeric suffixes
## beyond the last component ("1.0-beta" -> "1.1" — the suffix is
## dropped, the bump is what matters).
static func bump_version(version: String) -> String:
	var clean := version.strip_edges()
	if clean.is_empty():
		return "1.1"
	var parts := clean.split(".")
	for i in range(parts.size() - 1, -1, -1):
		var p := str(parts[i]).strip_edges()
		if p.is_valid_int():
			parts[i] = str(int(p) + 1)
			return ".".join(parts)
		# A trailing non-numeric component ("beta") is dropped and
		# the search continues left ("1.0-beta" -> "1.1").
		parts.remove_at(i)
		if parts.is_empty():
			return "1.1"
	return "1.1"


## Loads an installed mod's manifest + payload from disk for EDIT.
## Returns {"mod_id", "name", "kind", "version", "manifest",
## "payload", "path", "is_folder", "error"}. "error" is "" on success.
## Folder mods read manifest.json + the payload file; single-file
## mods read the file itself (a .json single file carries manifest +
## block inline; a .gd single file's companion .json, when present,
## supplies the manifest fields). The record's block_info is NOT
## enough — EDIT needs the exact installed bytes for the diff.
static func load_installed(mod_id: String) -> Dictionary:
	var rec := ModLoader.find_mod(mod_id, false)
	if rec.is_empty():
		return {"mod_id": mod_id, "name": "", "kind": "block", "version": "1.0",
			"manifest": {}, "payload": "", "path": "", "is_folder": false,
			"error": "no installed mod '%s'" % mod_id}
	var path := str(rec.get("path", ""))
	var kind := str(rec.get("kind", "block"))
	var manifest: Dictionary = {}
	var payload := ""
	var is_folder := false
	# Folder mods: path is the folder (ModLoader records the folder
	# path); single-file mods: path is the file itself.
	if FileAccess.file_exists(path):
		is_folder = false
		if path.ends_with(".json"):
			var text := FileAccess.get_file_as_string(path)
			var data: Variant = JSON.parse_string(text)
			if data is Dictionary and (data as Dictionary).has("block"):
				# Single-file .json: manifest fields + block inline.
				manifest = (data as Dictionary).duplicate(true)
				payload = text
			elif data is Dictionary:
				manifest = (data as Dictionary).duplicate(true)
				payload = text
			else:
				return {"mod_id": mod_id, "name": str(rec.get("name", "")), "kind": kind,
					"version": str(rec.get("version", "1.0")), "manifest": {}, "payload": "",
					"path": path, "is_folder": false, "error": "installed mod '%s' is not a JSON object" % mod_id}
		else:
			payload = FileAccess.get_file_as_string(path)
			var companion := path.get_basename() + ".json"
			if FileAccess.file_exists(companion):
				var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(companion))
				if m is Dictionary:
					manifest = (m as Dictionary).duplicate(true)
	else:
		is_folder = true
		var folder := path
		if folder.is_empty():
			folder = ModLoader.MODS_DIR.path_join(mod_id)
		var mpath := folder.path_join("manifest.json")
		if not FileAccess.file_exists(mpath):
			return {"mod_id": mod_id, "name": str(rec.get("name", "")), "kind": kind,
				"version": str(rec.get("version", "1.0")), "manifest": {}, "payload": "",
				"path": folder, "is_folder": true, "error": "installed mod '%s' has no manifest.json" % mod_id}
		var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(mpath))
		if not (m is Dictionary):
			return {"mod_id": mod_id, "name": str(rec.get("name", "")), "kind": kind,
				"version": str(rec.get("version", "1.0")), "manifest": {}, "payload": "",
				"path": folder, "is_folder": true, "error": "installed mod '%s' manifest.json is not a JSON object" % mod_id}
		manifest = (m as Dictionary).duplicate(true)
		var payload_file := str(manifest.get("file", ""))
		if payload_file.is_empty():
			payload_file = "block.json" if kind == "block" else "mod.gd"
		var ppath := folder.path_join(payload_file)
		if not FileAccess.file_exists(ppath):
			return {"mod_id": mod_id, "name": str(rec.get("name", "")), "kind": kind,
				"version": str(rec.get("version", "1.0")), "manifest": manifest, "payload": "",
				"path": folder, "is_folder": true, "error": "installed mod '%s' payload '%s' not found" % [mod_id, payload_file]}
		payload = FileAccess.get_file_as_string(ppath)
	return {"mod_id": mod_id, "name": str(rec.get("name", "")),
		"kind": kind, "version": str(rec.get("version", "1.0")),
		"manifest": manifest, "payload": payload, "path": path,
		"is_folder": is_folder, "error": ""}


## The EDIT seed for an installed mod: name, categories, visual,
## logic, current payload, manifest — everything the creator needs
## to refine THAT mod instead of generating a fresh one. Categories
## are INFERRED (installed mods do not store the creation form):
## weapon target -> Weapon; cover/structure/turret -> Block/Structure;
## pickup -> Gameplay; any hooks -> Effect. Visual = the manifest /
## block description; logic = a plain-language summary of the block
## fields + hooks (the full payload rides along for the diff + the
## generation context). Returns {"error": ...} when the mod cannot
## be loaded (the caller shows it; nothing is seeded).
static func edit_context_for(mod_id: String) -> Dictionary:
	var loaded := load_installed(mod_id)
	if str(loaded.get("error", "")) != "":
		return {"error": str(loaded.get("error", ""))}
	var rec := ModLoader.find_mod(mod_id, false)
	var info: Dictionary = rec.get("block_info", {})
	var target := str(info.get("target", ""))
	var cats: Array = []
	match target:
		"weapon":
			cats = ["Weapon"]
		"cover", "structure", "turret":
			cats = ["Block/Structure"]
		"pickup":
			cats = ["Gameplay"]
	var hooks: Array = rec.get("hooks", [])
	if not hooks.is_empty() and "Effect" not in cats:
		cats.append("Effect")
	if cats.is_empty():
		cats = ["Gameplay"]
	var manifest: Dictionary = loaded.get("manifest", {})
	var visual := str(manifest.get("description", ""))
	if visual.is_empty():
		visual = str(info.get("description", ""))
	if visual.is_empty():
		visual = str(info.get("display_name", loaded.get("name", "")))
	var logic_parts: Array[String] = []
	if not str(info.get("display_name", "")).is_empty():
		logic_parts.append("Display name: %s." % str(info.get("display_name", "")))
	if not target.is_empty():
		logic_parts.append("Target: %s." % target)
	for key in ["base_weapon_id", "damage_mult", "mag_mult", "range_mult", "ammo_type",
			"shape", "hp", "property", "duration_sec", "kind", "amount"]:
		if info.has(key):
			logic_parts.append("%s: %s." % [key, str(info[key])])
	for h in hooks:
		if h is Dictionary:
			logic_parts.append("Hook: %s (%s) — %s." % [
				str((h as Dictionary).get("hook_id", "?")),
				str((h as Dictionary).get("hook_point", "?")),
				str((h as Dictionary).get("description", ""))])
	var logic := " ".join(logic_parts)
	if logic.is_empty():
		logic = "Script mod — see the current payload."
	return {"mod_id": mod_id, "name": str(loaded.get("name", "")),
		"kind": str(loaded.get("kind", "block")),
		"version": str(loaded.get("version", "1.0")),
		"categories": cats, "visual": visual, "logic": logic,
		"payload": str(loaded.get("payload", "")),
		"manifest": manifest, "error": ""}


## Installs an approved EDIT candidate as an UPDATE to `mod_id`.
## "" = updated, else an error and the ORIGINAL files are restored
## (the installed mod is untouched on failure). Re-validates, writes
## manifest.json + payload into the SAME folder (same mod id — no
## second copy), bumps the version from the installed record, rescans,
## and verifies the updated record is error-free. A single-file mod
## is converted to folder form (its old file is removed ONLY after
## the update verifies). Does NOT mutate the passed candidate.
func install_update(candidate: Dictionary, mod_id: String) -> String:
	if str(candidate.get("error", "")) != "":
		return str(candidate.get("error", ""))
	var loaded := load_installed(mod_id)
	if str(loaded.get("error", "")) != "":
		return str(loaded.get("error", ""))
	var old_version := str(loaded.get("version", "1.0"))
	var new_version := bump_version(old_version)
	var work: Dictionary = candidate.duplicate(true)
	work["mod_id"] = mod_id
	if str(work.get("kind", "")) == "block":
		var normalized := _normalize_block_payload(str(work.get("payload", "")), mod_id)
		if normalized.is_empty():
			return "block payload is not a JSON object"
		work["payload"] = normalized
	# The manifest carries the bumped version (the candidate's own
	# version, if any, is superseded — an update always bumps).
	var wmanifest: Dictionary = (work.get("manifest", {}) as Dictionary).duplicate(true)
	wmanifest["version"] = new_version
	wmanifest["name"] = str(work.get("name", loaded.get("name", "")))
	work["manifest"] = wmanifest
	var err := validate(work)
	if err != "":
		return err
	_ensure_mods_dir()
	var folder := ModLoader.MODS_DIR.path_join(mod_id)
	# Snapshot the original files for rollback (folder mods: the two
	# files; single-file mods: the file + companion). Rollback
	# restores bytes, then rescans — the mod is exactly as before.
	var backup := _snapshot_mod_files(mod_id, loaded)
	var werr := _write_mod_files(mod_id, work)
	if werr != "":
		_restore_mod_files(mod_id, backup, loaded)
		ModLoader.rescan()
		return werr
	ModLoader.rescan()
	var rec := ModLoader.find_mod(mod_id)
	if rec.is_empty():
		_restore_mod_files(mod_id, backup, loaded)
		ModLoader.rescan()
		return "update verification failed for '%s'" % mod_id
	var rec_err := str(rec.get("error", ""))
	if rec_err != "":
		_restore_mod_files(mod_id, backup, loaded)
		ModLoader.rescan()
		return rec_err
	# Verified: a converted single-file mod's old file can go now
	# (its bytes live in the folder). Folder mods have no stale file
	# except a payload of the OTHER kind (block.json vs mod.gd) when
	# the edit changed kinds — remove it so the loader never reads a
	# stale payload.
	_remove_stale_update_files(mod_id, str(work.get("kind", "")), loaded)
	ModLoader.rescan()
	return ""


## Snapshots an installed mod's files (path -> bytes) for rollback.
static func _snapshot_mod_files(mod_id: String, loaded: Dictionary) -> Dictionary:
	var out := {}
	if bool(loaded.get("is_folder", false)):
		var folder := str(loaded.get("path", ModLoader.MODS_DIR.path_join(mod_id)))
		for f in ["manifest.json", "block.json", "mod.gd"]:
			var p := folder.path_join(f)
			if FileAccess.file_exists(p):
				out[p] = FileAccess.get_file_as_string(p)
	else:
		var p := str(loaded.get("path", ""))
		if not p.is_empty() and FileAccess.file_exists(p):
			out[p] = FileAccess.get_file_as_string(p)
		var companion := p.get_basename() + ".json"
		if FileAccess.file_exists(companion):
			out[companion] = FileAccess.get_file_as_string(companion)
	return out


## Restores snapshotted files (rollback). Removes a folder that did
## not exist before the update (single-file -> folder conversion),
## and removes payload files the update created that were NOT in the
## snapshot (e.g. a failed block->script edit must not leave a stale
## mod.gd next to the restored block.json).
static func _restore_mod_files(mod_id: String, backup: Dictionary, loaded: Dictionary) -> void:
	for p in backup.keys():
		var f := FileAccess.open(str(p), FileAccess.WRITE)
		if f != null:
			f.store_string(str(backup[p]))
			f.close()
	if not bool(loaded.get("is_folder", false)):
		_remove_mod_folder(mod_id)
		return
	var folder := ModLoader.MODS_DIR.path_join(mod_id)
	for payload_file in ["block.json", "mod.gd"]:
		var p := folder.path_join(payload_file)
		if not backup.has(p) and FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


## Removes stale files after a verified update: the old single file
## (converted to folder form), and the other-kind payload when the
## edit changed kinds (block.json left behind by a script edit, or
## mod.gd left behind by a block edit).
static func _remove_stale_update_files(mod_id: String, new_kind: String, loaded: Dictionary) -> void:
	if not bool(loaded.get("is_folder", false)):
		var old_path := str(loaded.get("path", ""))
		if not old_path.is_empty() and FileAccess.file_exists(old_path):
			DirAccess.remove_absolute(old_path)
		var companion := old_path.get_basename() + ".json"
		if FileAccess.file_exists(companion):
			DirAccess.remove_absolute(companion)
	var folder := ModLoader.MODS_DIR.path_join(mod_id)
	var stale := "mod.gd" if new_kind == "block" else "block.json"
	var stale_path := folder.path_join(stale)
	if FileAccess.file_exists(stale_path):
		DirAccess.remove_absolute(stale_path)
	# A folder mod whose payload file had a custom name (not
	# block.json / mod.gd) leaves that file behind — remove it so
	# the loader never reads a stale payload.
	var old_manifest: Dictionary = loaded.get("manifest", {})
	var old_file := str(old_manifest.get("file", ""))
	var new_file := "block.json" if new_kind == "block" else "mod.gd"
	if not old_file.is_empty() and old_file != new_file:
		var old_path := folder.path_join(old_file)
		if FileAccess.file_exists(old_path):
			DirAccess.remove_absolute(old_path)


## DIFF: human-readable lines describing what `candidate` changes vs
## the installed mod (`loaded` from load_installed()). The approval
## screen shows these BEFORE Install, so an edit is never a blind
## overwrite. Block payloads (JSON): recursive field diff
## (added / removed / changed, with old -> new values). Script
## payloads: added / removed line counts + the first changed lines
## (capped). The manifest version line is always first
## ("Version: 1.0 -> 1.1"). [] when nothing changed.
static func diff_candidate_vs_installed(candidate: Dictionary, loaded: Dictionary) -> Array:
	var lines: Array = []
	var old_version := str(loaded.get("version", "1.0"))
	var new_version := bump_version(old_version)
	lines.append("Version: %s -> %s" % [old_version, new_version])
	var old_name := str(loaded.get("name", ""))
	var new_name := str(candidate.get("name", ""))
	if new_name != "" and new_name != old_name:
		lines.append("Name: '%s' -> '%s'" % [old_name, new_name])
	var old_kind := str(loaded.get("kind", ""))
	var new_kind := str(candidate.get("kind", ""))
	if new_kind != "" and new_kind != old_kind:
		lines.append("Kind: %s -> %s" % [old_kind, new_kind])
	var old_payload := str(loaded.get("payload", ""))
	var new_payload := str(candidate.get("payload", ""))
	if old_payload == new_payload:
		lines.append("Payload: unchanged.")
		return lines
	var old_data: Variant = JSON.parse_string(old_payload)
	var new_data: Variant = JSON.parse_string(new_payload)
	if old_data is Dictionary and new_data is Dictionary:
		var field_lines: Array = []
		_diff_dicts(old_data as Dictionary, new_data as Dictionary, "", field_lines)
		if field_lines.is_empty():
			lines.append("Payload: changed (formatting only).")
		else:
			lines.append("Payload changes (%d):" % field_lines.size())
			lines.append_array(field_lines.slice(0, 40))
			if field_lines.size() > 40:
				lines.append("... and %d more field changes." % (field_lines.size() - 40))
		return lines
	# Script (or unparseable) payload: line diff.
	var old_lines := old_payload.split("\n")
	var new_lines := new_payload.split("\n")
	var old_set := {}
	for l in old_lines:
		old_set[str(l)] = true
	var new_set := {}
	for l in new_lines:
		new_set[str(l)] = true
	var added: Array = []
	var removed: Array = []
	for l in new_lines:
		if not old_set.has(str(l)) and str(l).strip_edges() != "":
			added.append(str(l))
	for l in old_lines:
		if not new_set.has(str(l)) and str(l).strip_edges() != "":
			removed.append(str(l))
	lines.append("Script: +%d lines / -%d lines (total %d -> %d)." % [added.size(), removed.size(), old_lines.size(), new_lines.size()])
	for l in removed.slice(0, 10):
		lines.append("  - %s" % l.left(120))
	for l in added.slice(0, 10):
		lines.append("  + %s" % l.left(120))
	if removed.size() > 10 or added.size() > 10:
		lines.append("  ... (first 10 removed / added lines shown)")
	return lines


## Recursive dict diff: appends "path: old -> new" / "path: added (…)"
## / "path: removed (was …)" lines. Nested dicts recurse; equal-
## length arrays recurse per index; anything else compares by
## string form.
static func _diff_dicts(old_d: Dictionary, new_d: Dictionary, prefix: String, out: Array) -> void:
	for k in old_d.keys():
		var path := str(k) if prefix.is_empty() else prefix + "." + str(k)
		if not new_d.has(k):
			out.append("%s: removed (was %s)" % [path, str(old_d[k]).left(80)])
		elif old_d[k] is Dictionary and new_d[k] is Dictionary:
			_diff_dicts(old_d[k] as Dictionary, new_d[k] as Dictionary, path, out)
		elif old_d[k] is Array and new_d[k] is Array:
			_diff_arrays(old_d[k] as Array, new_d[k] as Array, path, out)
		elif str(old_d[k]) != str(new_d[k]):
			out.append("%s: %s -> %s" % [path, str(old_d[k]).left(80), str(new_d[k]).left(80)])
	for k in new_d.keys():
		if not old_d.has(k):
			var path := str(k) if prefix.is_empty() else prefix + "." + str(k)
			out.append("%s: added (%s)" % [path, str(new_d[k]).left(80)])


## Array diff for _diff_dicts: same length -> per-index recurse /
## compare; different length -> one summary line.
static func _diff_arrays(old_a: Array, new_a: Array, prefix: String, out: Array) -> void:
	if old_a.size() != new_a.size():
		out.append("%s: %d entries -> %d entries" % [prefix, old_a.size(), new_a.size()])
		return
	for i in range(old_a.size()):
		var path := "%s[%d]" % [prefix, i]
		if old_a[i] is Dictionary and new_a[i] is Dictionary:
			_diff_dicts(old_a[i] as Dictionary, new_a[i] as Dictionary, path, out)
		elif old_a[i] is Array and new_a[i] is Array:
			_diff_arrays(old_a[i] as Array, new_a[i] as Array, path, out)
		elif str(old_a[i]) != str(new_a[i]):
			out.append("%s: %s -> %s" % [path, str(old_a[i]).left(80), str(new_a[i]).left(80)])


# --- Candidate construction ---------------------------------------------------

## Builds a candidate from a raw generation result ({manifest, payload,
## summary} or {error}). Runs the SAME validation as install(): a bad
## generation becomes a candidate with "error" set, never an installable
## candidate. Block payloads get their block_id normalized to the
## candidate mod_id (the folder id and the block id are always the same).
func _candidate_for(raw: Dictionary) -> Dictionary:
	var cand := _error_candidate("")
	var raw_err := str(raw.get("error", ""))
	if raw_err != "":
		cand["error"] = raw_err
		return cand
	var manifest: Variant = raw.get("manifest", null)
	if not (manifest is Dictionary):
		cand["error"] = "generation result has no manifest object"
		return cand
	var payload: Variant = raw.get("payload", null)
	if not (payload is String) or str(payload).strip_edges().is_empty():
		cand["error"] = "generation result has no payload"
		return cand
	var summary: Variant = raw.get("summary", "")
	if not (summary is String):
		cand["error"] = "generation result summary is not a string"
		return cand
	var m := manifest as Dictionary
	cand["manifest"] = m.duplicate(true)
	cand["payload"] = str(payload)
	cand["summary"] = str(summary)
	# v0.5.8 spell schools (tag only): the generation object's
	# top-level "spell_school" is the canonical carrier; fall back to
	# a school already embedded in the payload (block wrapper key /
	# script "# spell_school:" comment). Invalid -> "" (untagged),
	# never a rejection. Persisted into the payload below so the tag
	# survives install (the loader ignores it on rescan — it is not
	# yet surfaced in the Mods tab; see SpellSchools).
	var school := SpellSchools.normalize(str(raw.get("spell_school", "")))
	if school.is_empty():
		school = SpellSchools.parse_from_payload(str(payload))
	cand["spell_school"] = school
	cand["name"] = str(m.get("name", ""))
	cand["kind"] = str(m.get("kind", ""))
	var base := sanitize_mod_id(str(cand["name"]))
	if base.is_empty():
		cand["error"] = "could not derive a mod id from name '%s'" % str(cand["name"])
		return cand
	cand["mod_id"] = _unique_mod_id(base)
	if str(cand["kind"]) == "block":
		var normalized := _normalize_block_payload(str(cand["payload"]), str(cand["mod_id"]))
		if not normalized.is_empty():
			cand["payload"] = normalized
		# Else: leave the payload as-is; validate() reports the parse
		# problem instead of this function inventing a repair.
		if not school.is_empty():
			cand["payload"] = SpellSchools.wrap_block_payload(str(cand["payload"]), school)
	elif not school.is_empty():
		cand["payload"] = SpellSchools.prepend_script_comment(str(cand["payload"]), school)
	var verr := validate(cand)
	if verr != "":
		cand["error"] = verr
	return cand


static func _error_candidate(msg: String) -> Dictionary:
	return {"mod_id": "", "name": "", "kind": "block", "manifest": {}, "payload": "", "summary": "", "spell_school": "", "error": msg}


## Sanitizes a manifest name to a mod id: lowercase, non-alphanumeric ->
## "_", leading/trailing "_" stripped, max 48 chars (the block_id cap).
## "" when nothing usable remains.
static func sanitize_mod_id(name: String) -> String:
	var out := ""
	for ch in name.to_lower():
		if "abcdefghijklmnopqrstuvwxyz0123456789_".contains(ch):
			out += ch
		else:
			out += "_"
	while out.begins_with("_"):
		out = out.substr(1)
	while out.ends_with("_"):
		out = out.substr(1)
	return out.left(48)


## Collision-free mod id for `base` (base, base_2, base_3, ...), checked
## against BOTH installed mod ids and declared block_ids (a block_id from
## another mod would collide at scan time even with a different folder).
static func _unique_mod_id(base: String) -> String:
	if not _id_taken(base):
		return base
	var n := 2
	while n < 1000:
		var c := "%s_%d" % [base, n]
		if not _id_taken(c):
			return c
		n += 1
	return base


## True when `mod_id` is taken as a mod id OR as another mod's block_id.
static func _id_taken(mod_id: String) -> bool:
	var mods := ModLoader.get_mods()
	for m in mods:
		if str((m as Dictionary).get("id", "")) == mod_id:
			return true
	for m in mods:
		var rec := ModLoader.find_mod(str((m as Dictionary).get("id", "")))
		var info: Dictionary = rec.get("block_info", {})
		if str(info.get("block_id", "")) == mod_id:
			return true
	return false


## Rewrites a block payload's block_id to `mod_id`, preserving a
## {"block": {...}} wrapper when present. "" when the payload is not a
## JSON object (the caller reports that instead of repairing it).
static func _normalize_block_payload(payload: String, mod_id: String) -> String:
	var data: Variant = JSON.parse_string(payload)
	if not (data is Dictionary):
		return ""
	var d := data as Dictionary
	if d.has("block") and d["block"] is Dictionary:
		(d["block"] as Dictionary)["block_id"] = mod_id
	else:
		d["block_id"] = mod_id
	return JSON.stringify(d)


# --- Filesystem (install path only) -----------------------------------------

static func _ensure_mods_dir() -> void:
	var user_dir := DirAccess.open("user://")
	if user_dir == null:
		return
	if not user_dir.dir_exists("mods"):
		user_dir.make_dir("mods")


static func _mod_folder_exists(mod_id: String) -> bool:
	var dir := DirAccess.open(ModLoader.MODS_DIR)
	if dir == null:
		return false
	return dir.dir_exists(mod_id)


## Writes user://mods/<mod_id>/manifest.json + payload file. The written
## manifest is the candidate manifest PLUS "file" (the payload filename
## the scanner uses to find the payload). "" = OK, else an error.
static func _write_mod_files(mod_id: String, work: Dictionary) -> String:
	var folder := ModLoader.MODS_DIR.path_join(mod_id)
	var dir := DirAccess.open(ModLoader.MODS_DIR)
	if dir == null:
		return "could not open user://mods/"
	if dir.make_dir(mod_id) != OK and not dir.dir_exists(mod_id):
		return "could not create mod folder '%s'" % mod_id
	var manifest: Dictionary = (work.get("manifest", {}) as Dictionary).duplicate(true)
	var payload_file := "block.json" if str(work.get("kind", "")) == "block" else "mod.gd"
	manifest["file"] = payload_file
	var mf := FileAccess.open(folder.path_join("manifest.json"), FileAccess.WRITE)
	if mf == null:
		return "could not write manifest.json"
	mf.store_string(JSON.stringify(manifest))
	mf.close()
	var pf := FileAccess.open(folder.path_join(payload_file), FileAccess.WRITE)
	if pf == null:
		return "could not write %s" % payload_file
	pf.store_string(str(work.get("payload", "")))
	pf.close()
	return ""


## Removes a mod folder (install rollback). Best-effort: failures are
## ignored — install() already reported the real error.
static func _remove_mod_folder(mod_id: String) -> void:
	var folder_abs := OS.get_user_data_dir().path_join("mods").path_join(mod_id)
	for f in ["manifest.json", "block.json", "mod.gd"]:
		var p := folder_abs.path_join(f)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if DirAccess.dir_exists_absolute(folder_abs):
		DirAccess.remove_absolute(folder_abs)


# --- Async plumbing -----------------------------------------------------------

func _ensure_llm() -> void:
	if _llm != null:
		return
	_llm = ForgeLLM.new()
	add_child(_llm)
	_llm.generation_ready.connect(_on_llm_generation)


func _on_llm_generation(result: Dictionary) -> void:
	_generating = false
	# ForgeLLM already emits the exact NO_KEY_ERROR string for the
	# no-key case; _candidate_for passes {"error": ...} through as-is.
	_queue_candidate(_candidate_for(result))


func _queue_candidate(cand: Dictionary) -> void:
	_pending_candidates.append(cand)
	call_deferred("_emit_candidate")


func _emit_candidate() -> void:
	if _pending_candidates.is_empty():
		return
	var cand: Dictionary = _pending_candidates.pop_front()
	generation_ready.emit(cand)
	if not _pending_candidates.is_empty():
		call_deferred("_emit_candidate")


# --- Chat plumbing (v0.5.4 chat) ---------------------------------------------
# Own HTTPRequest path (ForgeLLM has no chat entry point and is NOT
# modified): same call shape as ForgeLLM's generation path — model
# deepseek-flash, thinking disabled, same timeout — but NO
# response_format (chat replies are plain text, not JSON) and the
# messages are [stable CHAT_SYSTEM_PROMPT, ...trimmed history].

func _request_chat_remote(trimmed: Array, key: String) -> void:
	var messages: Array = [{"role": "system", "content": ChatPrompt.CHAT_SYSTEM_PROMPT}]
	for m in trimmed:
		var d := m as Dictionary
		messages.append({"role": str(d.get("role", "user")), "content": str(d.get("text", ""))})
	var body := {
		"model": ForgeLLM.MODEL,
		"messages": messages,
		"temperature": ChatPrompt.CHAT_TEMPERATURE,
		"max_tokens": ChatPrompt.CHAT_MAX_TOKENS,
		# Thinking mode is ON by default on deepseek-flash and bills
		# reasoning tokens as output. Same call shape as the build /
		# generation paths.
		"thinking": {"type": "disabled"},
	}
	var http := HTTPRequest.new()
	http.timeout = ForgeLLM.HTTP_TIMEOUT_SEC
	add_child(http)
	_chat_http_outstanding = true
	http.request_completed.connect(_on_chat_http_completed.bind(http))
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + key,
	])
	var err := http.request(ForgeLLM.API_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		push_warning("ModCreator: chat HTTPRequest failed to start (%s)." % error_string(err))
		http.queue_free()
		_chat_http_outstanding = false
		_queue_chat_error("chat request failed to start")


func _on_chat_http_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	var text := ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		text = body.get_string_from_utf8()
	http.queue_free()
	_chat_http_outstanding = false
	if result != HTTPRequest.RESULT_SUCCESS:
		push_warning("ModCreator: chat request failed (result=%d, http=%d)." % [result, code])
		_queue_chat_error("chat request failed — check your connection and try again")
		return
	if code != 200:
		push_warning("ModCreator: chat returned HTTP %d." % code)
		_queue_chat_error("chat failed (server returned %d) — try again" % code)
		return
	var reply := _extract_chat_reply(text)
	if reply.is_empty():
		push_warning("ModCreator: chat returned no usable reply.")
		_queue_chat_error("chat returned an empty reply — try again")
		return
	_queue_chat_reply(reply)


## Pulls the assistant's plain-text reply out of a chat-completions
## response envelope. "" when there is no usable message content.
static func _extract_chat_reply(text: String) -> String:
	if text.strip_edges().is_empty():
		return ""
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return ""
	var choices: Array = (data as Dictionary).get("choices", [])
	if choices.is_empty() or not (choices[0] is Dictionary):
		return ""
	var msg: Dictionary = (choices[0] as Dictionary).get("message", {})
	return str(msg.get("content", "")).strip_edges()


func _queue_chat_reply(text: String) -> void:
	_pending_chat.append({"kind": "reply", "text": text})
	call_deferred("_emit_chat")


func _queue_chat_error(message: String) -> void:
	_pending_chat.append({"kind": "error", "text": message})
	call_deferred("_emit_chat")


func _emit_chat() -> void:
	if _pending_chat.is_empty():
		return
	var item: Dictionary = _pending_chat.pop_front()
	# Clear _chatting BEFORE emitting the final item, so a signal
	# handler may immediately start the next chat. While HTTP is still
	# outstanding (a rejected concurrent call's error), the flag stays
	# set so no second request sneaks in mid-flight.
	if _pending_chat.is_empty() and not _chat_http_outstanding:
		_chatting = false
	if str(item.get("kind", "")) == "reply":
		chat_reply.emit(str(item.get("text", "")))
	else:
		chat_error.emit(str(item.get("text", "")))
	if not _pending_chat.is_empty():
		call_deferred("_emit_chat")
