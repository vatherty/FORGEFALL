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
HOOK SCRIPTS AND THE EFFECT-KINDS TABLE (v0.5.6) — read this before deciding how the mod behaves. A hook is behaviour attached to the mod's weapon at one hook point: "on_fire"|"projectile_spawn" (weapon fires), "on_hit" (a shot struck something), "on_kill" (a shot killed its target), "on_damage_taken" (the player took damage).

PREFER THE TABLE. Most hook behaviour is a DATA hook: a hook dict with an "effects" array (and/or a "projectile" on a fire point). Use the table whenever it covers the request. The effect kinds are:
- heal {"amount": 1-500}, explosion {"radius": 0.5-20, "damage": 0-500}, smoke {"duration_sec": 1-120}, announce {"title": "...", "subtitle": "..."}, damage_mult {"value": 0-5}
- STATUS kinds (need a target — see STATUS EFFECTS below): slow {"factor": 0.05-1.0, "duration_sec": 0.5-30}, freeze {"duration_sec": 0.5-10}, burn {"damage_per_sec": 1-500, "duration_sec": 0.5-30}, knockback {"force": 1-30}
Hook dict: {"hook_id": "<lowercase [a-z0-9_]>", "hook_point": "on_fire"|"projectile_spawn"|"on_hit"|"on_kill"|"on_damage_taken", "display_name": "<name>", "description": "<one line>", ...}.
A fire-point hook (on_fire / projectile_spawn) may carry "projectile": {"visual": "<what it looks like, e.g. 'watermelon' or 'glowing laser beam'>", "shape": "beam"|"sphere"|"cube"|"blob"|"bullet", "speed": 1-200, "damage": 0-500 (-1 = use the weapon's damage), "range": 1-500, "size": 0.05-5, "gravity": -50-50, "pierce": true|false, "explodes_on_impact": true|false, "explosion_radius": 0-20, "explosion_damage": 0-500}. The weapon fires THIS projectile instead of hitscan. Example: a Long Laser Pistol is a p9-based weapon mod with a projectile_spawn hook whose projectile is {"visual": "glowing laser beam", "shape": "beam", "speed": 60, "damage": 45, "range": 120, "explodes_on_impact": false}. Example: a Watermelon LMG is an lmg-based weapon mod with a projectile_spawn hook whose projectile is {"visual": "watermelon", "shape": "sphere", "speed": 28, "damage": 40, "range": 90, "explodes_on_impact": true, "explosion_radius": 4, "explosion_damage": 60}.
Any hook may carry "effects": [{"kind": "heal", "amount": 1-500} | {"kind": "explosion", "radius": 0.5-20, "damage": 0-500} | {"kind": "smoke", "duration_sec": 1-120} | {"kind": "announce", "title": "...", "subtitle": "..."} | {"kind": "damage_mult", "value": 0-5} | {"kind": "slow", "factor": 0.05-1.0, "duration_sec": 0.5-30} | {"kind": "freeze", "duration_sec": 0.5-10} | {"kind": "burn", "damage_per_sec": 1-500, "duration_sec": 0.5-30} | {"kind": "knockback", "force": 1-30}]. Example: heal-on-kill is an on_kill hook with effects [{"kind": "heal", "amount": 15}]. A damage_mult effect on on_hit multiplies that hit's damage; on on_damage_taken it reduces the damage taken.
STATUS EFFECTS: slow / freeze / burn / knockback need a target — put them on on_hit or on_kill (they affect the hit target) or on_damage_taken (they affect the player). NEVER put a status effect on a fire point (on_fire / projectile_spawn) — it is rejected. slow's "factor" is the speed multiplier (0.5 = half speed) and "duration_sec" is how long it lasts. Example: a bubble that slows enemies is an on_hit hook with effects [{"kind": "slow", "factor": 0.5, "duration_sec": 3.0}] — do NOT express slowing as smoke or announce; slow is its own kind.

WRITE A HOOK SCRIPT ONLY WHEN THE TABLE CANNOT EXPRESS THE REQUEST. Script-only behaviour includes: pulling/dragging the hit target toward a point (pull/vortex — the table's knockback only pushes AWAY), behaviour that branches on ctx (e.g. a different effect when the player is low on HP), chaining several ModAPI calls in one run, or behaviour that depends on a value the table cannot read. When you write a script, do NOT downgrade to a closest-buildable table substitute — the script IS the build. Effect kinds stay the preferred path: use them whenever they cover the request; write a script ONLY when nothing in the table covers it.

HOOK-SCRIPT FORMAT:
- Carriage: the script travels as the "code" string of a hook dict. Block mod: add a top-level "hooks" array to the payload, next to the "block" object. Script mod: implement get_hooks() -> Array returning the hook dicts. Hook dict: {"hook_id": "<lowercase [a-z0-9_]>", "hook_point": "on_fire"|"projectile_spawn"|"on_hit"|"on_kill"|"on_damage_taken", "display_name": "<name>", "description": "<one line>", "code": "<hook script source>"}.
- A hook with "code" runs ONLY its code — any "effects" or "projectile" on the SAME hook are IGNORED. Put everything the hook does inside run(). (A hook with no "code" is a data hook: its effects/projectile are applied by the game.)
- The script MUST start with `extends ModHook` and implement: func run(api: ModAPI, ctx: Dictionary) -> Dictionary. Do NOT add get_hook_info() — the hook dict already carries hook_id/hook_point. Max 20000 chars.
- Return contract: return a Dictionary with any of {"damage_mult": float, "healed": float, "exploded": bool, "announced": bool, "status_applied": bool}. Effects applied directly through `api` need not be reported; the return value is for damage accounting. Return {} when the hook does nothing.
- ctx keys by hook point (these are the ONLY ctx keys — never read another):
  - on_fire / projectile_spawn: {"weapon_id": String, "position": Vector3, "direction": Vector3}. NO target — a fire-point hook cannot touch a target (none exists yet).
  - on_hit / on_kill: {"position": Vector3, "hit_position": Vector3, "damage": float, "target": Node-or-null, "headshot": bool, "weapon_id": String} (hitscan) — or with "projectile": Dictionary instead of "headshot"/"weapon_id" when fired by a custom projectile.
  - on_damage_taken: {"damage": float, "hp_before": float, "hp_after": float, "position": Vector3, "weapon_id": String}. NO target — the target IS the player; use api.get_player() / api.get_player_position().
- Always read ctx with ctx.get("key", default) and check `is` before use (e.g. `if not (tgt is Node3D): return {}`). A hook that errors on a missing key disables its mod — read defensively.

MODAPI / ALLOWLIST — THE ONLY CALLS A HOOK SCRIPT MAY MAKE. The validator (ModAPI.HOOK_ALLOWED_*) REJECTS anything not listed here — no more, no less. Values that flow OUT of `api` (a Node, a Vector3, ...) may only be passed BACK into `api` or used through the safe methods / components below.
- api.<method> — the ONLY game calls (all 15 ModAPI methods): get_player, get_root, get_player_position, get_aim_point, spawn_voxel_box, spawn_cover, spawn_pickup, spawn_turret, give_weapon, fire_effect, announce, get_player_health, heal_player, apply_status_effect, spawn_projectile.
  Signatures: get_player() -> Node3D — the player node (may be null). get_root() -> Node — the scene root builds attach to. get_player_position() -> Vector3 — player position, or Vector3.ZERO. get_aim_point() -> Vector3 — crosshair raycast point ("marked" position). spawn_voxel_box(size: Vector3, color: Color, position: Vector3, solid: bool) -> Node3D — one voxel block: visible cube + optional solid collider. spawn_cover(shape: String, size_voxels: Vector3i, hp: float, position: Vector3) -> Node — destructible voxel cover slab; shape wall|tower|barricade, size each 1-12, hp 50-500. spawn_pickup(kind: String, position: Vector3) -> Node — ammo|health pickup. spawn_turret(position: Vector3, duration_sec: float, damage_mult: float, range_mult: float) -> Node — sentry turret; duration 5-120. give_weapon(weapon_id: String, damage_mult: float, range_mult: float, mag_mult: float) -> bool — give a base weapon (manticore|longeye|breacher|hornet|p9|raptor|lmg), tuned by multipliers (1.0 = stock). fire_effect(kind: String, position: Vector3, radius: float, damage: float, duration_sec: float = 20.0) -> void — "explosion" (radius + damage) or "smoke" (duration_sec). announce(title: String, subtitle: String) -> void — HUD banner. get_player_health() -> float — current player HP, or -1 with no player. heal_player(amount: float) -> float — heals the player; returns HP afterwards, or -1. apply_status_effect(target: Node, kind: String, params: Dictionary, origin: Vector3) -> bool — applies slow|freeze|burn|knockback to a target. slow params {"factor": 0.05-1.0, "duration_sec": 0.5-30}; freeze {"duration_sec": 0.5-10}; burn {"damage_per_sec": 1-500, "duration_sec": 0.5-30}; knockback {"force": 1-30} and pushes AWAY from `origin`. spawn_projectile(spec: Dictionary, origin: Vector3, direction: Vector3, hooks: Array = []) -> Node — flying mod projectile; spec is a hook projectile dict.
- ctx.<method> — read-only Dictionary methods ONLY: get, has, has_all, keys, values, size, is_empty. Read ctx ONLY through these (e.g. ctx.get("target", null)). Never mutate ctx.
- Bare globals — pure math / conversions / value construction ONLY: print, str, int, float, bool, Vector2, Vector3, Vector3i, Vector4, Color, Dictionary, Array, String, StringName, clampf, clampi, min, max, minf, maxf, abs, absf, sign, signf, floor, ceil, round, lerp, lerpf, lerp_angle, randf, randi, randf_range, randi_range, sqrt, pow, sin, cos, tan, asin, acos, atan, atan2, deg_to_rad, rad_to_deg, is_equal_approx, is_zero_approx, is_inf, is_nan, is_finite, typeof, range, snapped, snappedf, clamp, move_toward, posmod, fmod, wrap, wrapf, wrapi, pingpong, smoothstep, inverse_lerp, remap, ease, step_decimals, is_same.
- Types — annotations / `is` / `as` ONLY: ModAPI, ModHook, Dictionary, Array, String, StringName, int, float, bool, Vector2, Vector3, Vector3i, Vector4, Color, Variant, Node, Node3D, CharacterBody3D, PackedStringArray, PackedVector3Array, PackedFloat32Array, PackedInt32Array.
- Methods on your OWN locals and on values chained off a call — pure value methods ONLY: Vector: normalized, length, length_squared, distance_to, distance_squared_to, direction_to, dot, cross, lerp, slerp, rotated, angle_to, angle_to_point, abs, ceil, floor, round, sign, clamp, clamped, snapped, bounce, reflect, slide, project, limit_length, is_equal_approx, is_zero_approx, is_finite, is_normalized, posmod, max_axis_index, min_axis_index. Dictionary: get, has, has_all, keys, values, size, is_empty, duplicate, get_or_add, find_key, erase, clear, merge, sort. Array: front, back, count, append, push_back, pop_back, pop_front, push_front, insert, remove_at, slice, reverse, min, max, bsearch, shuffle, sort_custom. String: substr, find, findn, rfind, contains, begins_with, ends_with, to_lower, to_upper, strip_edges, trim_prefix, trim_suffix, replace, replacen, split, join, format, pad_zeros, pad_decimals, is_valid_int, is_valid_float, to_int, to_float, capitalize, repeat, reverse, lpad, rpad, get_slice, left, right, mid, dedent, indent, split_floats, hex_encode, hex_decode. Color: to_html, lightened, darkened, inverted, blend, srgb_to_linear, linear_to_srgb. (erase / clear / merge / append / ... mutate ONLY dicts/arrays you created yourself — never ctx.)
- Components — the ONLY dotted attribute reads: .x, .y, .z, .w, .r, .g, .b, .a.
- NEVER — REJECTED: any node property or method (.global_position, .position, .hp, .name, .queue_free, .get_node, .call, ...), any api.<property> (api.last_spawned and api.last_spawned_position are properties, NOT methods — REJECTED), any other dotted access, any engine type/member not listed above. In particular you CANNOT read node properties: the only position facts you get are ctx's Vector3s (position / hit_position) and api.get_player_position() / api.get_aim_point(). Anything not listed here DOES NOT EXIST for hook scripts — never call it (no get_enemies, no damage_target, no move_target, no get_target_position, no set_player_health, no other game function).
NOTE: the generation system prompt lists an older, shorter ModAPI list. For HOOK SCRIPTS the allowlist in this addendum is the full, current surface — it adds get_player_health, heal_player, apply_status_effect, and spawn_projectile, plus the ctx / builtin / type / safe-method / component lists. Use this list, not the shorter one.

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

The approval screen lists every invented hook and every hook script before Install, so describe each hook plainly in the summary."""

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
	var verr := validate(cand)
	if verr != "":
		cand["error"] = verr
	return cand


static func _error_candidate(msg: String) -> Dictionary:
	return {"mod_id": "", "name": "", "kind": "block", "manifest": {}, "payload": "", "summary": "", "error": msg}


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
