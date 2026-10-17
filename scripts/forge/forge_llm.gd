# FORGEFALL — ForgeLLM (v0.6: real LLM path, Colin's hard rules)
# v0.6.2 (Colin loosened the gate): COMPOSITION is allowed — the LLM may
# combine any known blocks (weapon + ammo_type, cover/structure +
# property) even when that exact combo has no preset. The gate validates
# each PIECE against its catalog and RECOMPUTES the cost as the sum of the
# composed blocks; a cost mismatch never rejects. Still never: invented
# blocks/fields, scripts/code, eval, out-of-range numbers.
# Turns a player requisition prompt into a ModSpec v1 Dictionary.
#
# HARD RULES (Colin, non-negotiable):
# - The LLM builds from BLOCKS ONLY. It NEVER invents scripts/code. There
#   is NO code generation, NO eval, NO code-execution path anywhere. The
#   LLM outputs JSON ModSpec from a FIXED catalog only; the game applies
#   it via the trusted ForgeBuilder. Requests the catalog cannot express
#   get a clean refusal + suggestions, never an improvised build.
# - TEMPLATED: one stable SYSTEM_PROMPT constant (exact JSON schema +
#   exact allowed-action catalog + few-shot examples), JSON-only output.
# - FAST + CACHE-AWARE: the stable template goes FIRST (system message,
#   byte-identical every call) and the variable user prompt goes LAST, so
#   DeepSeek's automatic disk prefix cache can hit on the system prefix.
#   Nothing variable (no budget, no timestamp, no randomness) is ever
#   placed before or inside the system prompt. DeepSeek caching is
#   automatic, best-effort, and needs no request field; a hit requires a
#   full match on a persisted cache prefix unit (see api-docs.deepseek.com
#   guides/kv_cache). The per-call budget rides in the user message, AFTER
#   the stable prefix, so it cannot break the system-prefix cache unit.
#
# Two paths, same output shape:
# 1. REAL DeepSeek client: HTTPRequest POST to
#    https://api.deepseek.com/chat/completions (model "deepseek-flash",
#    response_format {"type":"json_object"}, thinking DISABLED so the call
#    stays fast/cheap — thinking mode is on by default on this model and
#    bills reasoning tokens as output — temperature 0.2), key from
#    ForgeConfig.load_key() (user://forge_config.json), 20 s timeout.
#    The model name was verified against DeepSeek's own pricing docs on
#    2026-10-13: "deepseek-flash" is the current cheap/fast model
#    (DeepSeek-V4.1-Flash); the old "deepseek-chat" name was retired
#    2026-07-24 and no longer resolves.
# 2. Keyword-matcher fallback: used when there is no key, the request
#    fails, or the model returns garbage — the game ALWAYS works offline.
#
# Async contract: request_spec() returns {} immediately; the real spec
# arrives via signal spec_ready(spec). One request in flight at a time
# (the Forge manager serializes calls anyway).
extends Node
class_name ForgeLLM

const PlayerClasses := preload("res://scripts/progression/classes.gd")

signal spec_ready(spec: Dictionary)

#region TUNABLES
const API_URL := "https://api.deepseek.com/chat/completions"
const MODEL := "deepseek-flash"
const HTTP_TIMEOUT_SEC := 20.0
const MAX_TOKENS := 400
const TEMPERATURE := 0.2
# Fallback costs (must match the costs quoted to the model in SYSTEM_PROMPT
# and the base costs recomputed by validate_modspec()). Weapon costs are
# NOT flat: weapon_cost() prices each weapon by power (see WEAPON_POWER).
const COST_WALL := 100
const COST_TOWER := 150
const COST_BARRICADE := 100
const COST_TURRET := 250
const COST_PICKUP := 75
const COST_UAV := 150
const COST_AIRSTRIKE := 300
const COST_CHOPPER := 450
const COST_SMOKE := 100
const COST_SUPPLY := 50
const COST_ENEMYMOD := 150
const COST_BRIDGE := 120
const COST_BUNKER := 180
const COST_WATCHTOWER := 200
const COST_AMMO_DEPOT := 150
const COST_STAIRS := 100
const COST_RAMP := 90
const COST_STRUCTURE_WALL := 120
const COST_JUMP_PAD := 150
const COST_COVER_PIECE := 60
const COST_SNIPER_NEST := 220
const COST_SPAWN_ENEMIES := 150
## Per-weapon power inputs for weapon_cost(): [damage, pellets, rpm, mag]
## — the Arsenal stats for each Forge weapon id. RAPTOR is 0-damage
## utility (grab/throw), so the formula does not apply to it; weapon_cost()
## returns its fixed utility price instead. TRIDENT's 900 rpm is the
## INTRA-BURST rate (bursts are re-press gated, so sustained DPS is lower);
## the formula prices the per-burst alpha, which is what the player feels.
const WEAPON_POWER := {
	"manticore": [25.0, 1, 700.0, 30],
	"longeye": [120.0, 1, 40.0, 5],
	"breacher": [12.0, 8, 65.0, 6],
	"hornet": [18.0, 1, 850.0, 32],
	"p9": [22.0, 1, 420.0, 12],
	"raptor": [0.0, 0, 0.0, 0],
	"lmg": [22.0, 1, 600.0, 100],
	"trident": [26.0, 1, 900.0, 30],
	"judge": [65.0, 1, 150.0, 6],
}
## v0.6.2 COMPOSITION surcharges: the cost of a composed block, added to
## the base block's cost by recompute_cost(). Quoted to the model in
## SYSTEM_PROMPT; the game-computed sum is truth, never the model number.
const COST_AMMO_SNIPER := 50
const COST_AMMO_ARMOR_PIERCING := 75
const COST_AMMO_BUCKSHOT := 50
const COST_REINFORCED := 50
## v0.5.8 elemental emitters: a free-standing emitter pylon costs 200;
## composing an element onto a turret or weapon costs +75. Quoted to
## the model in SYSTEM_PROMPT; the game-computed sum is truth.
const COST_EMITTER := 200
const COST_ELEMENT_SURCHARGE := 75
## v0.6.2 COMPOSITION catalogs: every piece of a composed spec must be
## one of these known blocks. "standard" is the zero-surcharge default.
const AMMO_TYPES := ["standard", "sniper", "armor_piercing", "buckshot"]
const BLOCK_PROPERTIES := ["standard", "reinforced"]
## Helpful error for prompts the parser cannot map to any buildable.
const UNKNOWN_HINT := "I don't know how to build that — try: wall, tower, turret, bridge, bunker, watchtower, ammo depot, stairs, ramp, jump pad, sniper nest, sniper, UAV, make me a rogue"
## Suggestion list used by unknown_error() and refusal_message() — keep in
## sync with the preset prompts the offline parser actually understands.
const UNKNOWN_SUGGESTIONS := "wall, tower, turret, bridge, bunker, watchtower, ammo depot, stairs, ramp, jump pad, sniper nest, sniper, burst rifle, judge, UAV, make me a rogue, fire emitter, lightning turret"
## Max chars of a model-supplied refusal reason that reach the player.
const MAX_REFUSAL_REASON_CHARS := 120
#endregion

## Per-weapon Forge cost, COMPUTED from power, never flat. Formula:
##   cost = clamp(round5(75 + sqrt(damage x pellets x rpm x mag) / 4
##                       + damage x pellets), 100, 350)
## The sqrt() curve keeps the spread sane against structure costs
## (100-200) and the turret (250): the LMG's huge mag would otherwise
## price it out of the game (raw 384 -> clamped 350). The per-shot term
## (damage x pellets) is what keeps slow, hard-hitting weapons honest:
## without it the Longeye (40 rpm, 5-round mag) would cost less than a
## pistol despite 120 damage a shot. Results: manticore 280, longeye
## 235, breacher 220, hornet 270, p9 180, raptor 150 (utility, fixed),
## lmg 350 (clamped), trident 310, judge 200. Costs are computed +
## shown, never blocking (Forge manager: BUDGET_ENABLED = false).
static func weapon_cost(forge_weapon_id: String) -> int:
	if forge_weapon_id == "raptor":
		# 0-damage utility (grab/throw) — the power formula is N/A,
		# so the claw carries a fixed utility price between a pistol
		# and a rifle.
		return 150
	var row: Array = WEAPON_POWER.get(forge_weapon_id, [])
	if row.size() != 4:
		return -1
	return _weapon_power_cost(float(row[0]), int(row[1]), float(row[2]), int(row[3]))


static func _weapon_power_cost(damage: float, pellets: int, rpm: float, mag: int) -> int:
	var raw := damage * float(pellets) * rpm * float(mag)
	var cost := 75.0 + sqrt(raw) / 4.0 + damage * float(pellets)
	return clampi(int(round(cost / 5.0)) * 5, 100, 350)


## THE system prompt. One stable constant, byte-identical on every call.
## The variable user prompt is appended LAST (in the user message), never
## inside or before this template, so DeepSeek's prefix cache can reuse it.
## Exact JSON schema + exact allowed-action catalog + few-shot examples.
## The model MUST NOT invent targets, params, costs, scripts, or code.
const SYSTEM_PROMPT := """You are the FORGE, an AI quartermaster in a voxel FPS. The player requisitions gear with a short prompt. Reply with EXACTLY ONE raw JSON object — no markdown fences, no commentary — in one of these two shapes:
BUILD: {"spec_version":1,"action":"spawn|modify|event","target":"weapon|cover|turret|pickup|enemy_mod|killstreak|arena_event|structure|enemy_spawn|emitter|class","params":{},"cost":0,"ttl":0}
REFUSAL (use when the request cannot be built from the catalog below): {"spec_version":1,"action":"refuse","target":"none","params":{"reason":"<short reason, max 120 chars>"},"cost":0,"ttl":0}
CATALOG — build ONLY from these blocks. Never invent targets, params, blocks, scripts, or code. There is no code/script output; you compose pre-made blocks only.
- structure: params {"shape":"bridge"|"bunker"|"watchtower"|"ammo_depot"|"stairs"|"ramp"|"wall"|"jump_pad"|"cover_piece"|"sniper_nest","position":"near_player"|"marked","property":"standard"|"reinforced" optional,"rotation_deg":0-180 optional}. Costs: bridge 120, bunker 180, watchtower 200, ammo depot 150, stairs 100, ramp 90, wall 120, jump pad 150, cover piece 60, sniper nest 220, reinforced +50. action "spawn". FULL STRUCTURE CATALOG (build ONLY these — never guess a shape that is not listed here):
  - bridge: stepped ramp up to a 2 m platform, ~2.2 x 2.6 x 8 m, faces away from the player.
  - bunker: roofed concrete pillbox with a firing gap, ~4.4 x 2.8 x 4.4 m.
  - watchtower: tall platform on legs with rear stairs and a roof, ~3.6 x 5.1 x 3.6 m, platform ~3 m up.
  - ammo_depot: crates plus an ammo cache, ~3.8 x 2.4 x 1.2 m.
  - stairs: straight voxel staircase, 8 steps to a 3.4 m top platform, ~2.2 x 3.6 x 9 m, ascends away from the player.
  - ramp: straight sloped walkway of overlapping slabs to a 2.3 m deck, ~2.2 x 2.4 x 8 m, ascends away from the player.
  - wall: tall straight voxel barrier, 6 m wide, 3 m tall, ~6 x 3 x 0.6 m.
  - jump_pad: low launch pad that launches the player, ~2 x 0.8 x 2 m.
  - cover_piece: low straight wall for crouch cover, 3 m wide, 1.1 m tall.
  - sniper_nest: open-air elevated platform with rails and a shooting-rest lip, rear stairs, no roof, ~3.6 x 4.4 x 3.6 m.
  Structures are FIXED-SIZE presets: there is NO scale/size parameter for structures (do not emit one — the gate rejects it). The only per-structure tunables are position, property (standard|reinforced), and rotation_deg (below). PLACEMENT: "position" is "near_player" (default — 2 m in front of the player, ground-snapped), "marked" (where the player is aiming), or [x,y,z] with x/z in -60..60, y in 0..30. Structures face the player's facing direction by default and are ground-snapped; at most 12 Forge structures may stand at once. ROTATION: "rotation_deg" is a yaw offset in degrees, -180..180, added to the default orientation (0 = default, faces the player). A diagonal build is rotation_deg 45. Emit it whenever the prompt asks for diagonal / rotated / sideways / angled placement (e.g. "diagonal ramp" -> rotation_deg 45, "ramp rotated 90 degrees" -> rotation_deg 90). The same rotation_deg param works on cover and turret builds.
- cover: params {"shape":"wall"|"tower"|"barricade","size_voxels":[x,y,z] each 1-12,"position":"near_player"|"marked"|[x,y,z],"hp":50-500,"property":"standard"|"reinforced" optional,"rotation_deg":0-180 optional}. Costs: wall 100, tower 150, barricade 100, reinforced +50. action "spawn". (cover is the ONLY target with a size_voxels parameter; structures above have no size param. rotation_deg is a yaw offset as above.)
- turret: params {"position":"near_player"|"marked"|[x,y,z],"duration_sec":5-120,"ammo_type":"standard"|"sniper"|"armor_piercing"|"buckshot" optional,"element":"fire"|"cold"|"lightning"|"acid"|"poison"|"radiant"|"necrotic"|"thunder"|"force"|"water" optional,"rotation_deg":0-180 optional (yaw offset, as above)}. Cost 250 + ammo surcharge (standard 0, sniper 50, armor_piercing 75, buckshot 50) + element surcharge 75 when "element" is present. action "spawn". (An "element" turret is an ELEMENTAL EMITTER TURRET: every shot deals its full damage AS that element — see the emitter catalog below.)
- emitter: params {"element":"fire"|"cold"|"lightning"|"acid"|"poison"|"radiant"|"necrotic"|"thunder"|"force"|"water","position":"near_player"|"marked"|[x,y,z],"radius":1-10 optional (default 4),"duration_sec":3-60 optional (default 10),"damage_per_sec":1-100 optional (default 10)}. Cost 200. action "spawn". A free-standing emitter pylon: voxel particles + one elemental damage type + radius + duration, damaging ENEMIES ONLY inside the radius on every 0.5 s tick. ELEMENTAL EMITTER CATALOG (all elements + what each does):
  - fire: fire damage + burn rider (damage over time).
  - cold: cold damage + slow rider (x0.6 speed).
  - lightning: lightning damage + knockback rider; x1.5 damage + chains to the nearest other enemy within 3 m for 50% against WET targets.
  - acid: acid damage + weaken rider (damage dealt x0.7).
  - poison: poison damage + poison rider (damage over time + slow x0.85).
  - radiant: radiant damage + blind rider (accuracy x0.5).
  - necrotic: necrotic damage + +1 exhaustion level per hit.
  - thunder: thunder damage + heavy knockback + brief prone.
  - force: force damage (direct) + knockback — pure kinetic shove.
  - water: small water damage + slow x0.6 + EXTINGUISHES burn + marks targets WET for 4 s (lightning conducts off wet: x1.5 + chain). Water does NOT clear poison, bleed, or any other DOT — it puts out fire, not venom.
  Emitters damage ENEMIES ONLY (never the player). A weapon or turret with an "element" param is an elemental weapon/turret (see weapon/turret lines): its hits deal their full damage AS that element. An "emitter" target is the free-standing pylon.
- pickup: params {"kind":"ammo"|"health","position":"near_player"|"marked"}. Cost 75. action "spawn".
- weapon: params {"weapon_id":"manticore"|"longeye"|"breacher"|"hornet"|"p9"|"raptor"|"lmg"|"trident"|"judge","ammo_type":"standard"|"sniper"|"armor_piercing"|"buckshot" optional,"element":"fire"|"cold"|"lightning"|"acid"|"poison"|"radiant"|"necrotic"|"thunder"|"force"|"water" optional}. Costs by weapon (the game recomputes them; emit your best estimate): manticore 280, longeye 235, breacher 220, hornet 270, p9 180, raptor 150, lmg 350, trident 310, judge 200 — + ammo surcharge (standard 0, sniper 50, armor_piercing 75, buckshot 50) + element surcharge 75 when "element" is present. action "spawn". (manticore=assault rifle, longeye=sniper rifle, breacher=shotgun, hornet=smg, p9=pistol, raptor=prototype claw, lmg=light machine gun — high capacity, slower handling, trident=burst rifle — 3-round burst, precise mid-range, judge=heavy revolver — huge damage per shot, 6-round cylinder) (An "element" weapon fires ELEMENTAL rounds: every hitscan hit deals its full damage AS that element — see the emitter catalog under "emitter".)
- class: params {"class_id":"barbarian"|"bard"|"cleric"|"druid"|"fighter"|"monk"|"paladin"|"ranger"|"rogue"|"sorcerer"|"warlock"|"wizard"}. Cost 0. action "modify". Swaps the player's D&D class mid-match — the old kit is removed and the new kit applies immediately, no restart. CLASS CATALOG (use ONLY these 12 — never invent a class):
  - barbarian: Rage tank. +40% max HP, +15% damage dealt, take 25% less damage. Ability +2 STR, +2 CON.
  - bard: Song of Rest. +50% healing received, +50% health regen, +5% damage, +5% move speed. Ability +2 CHA.
  - cleric: Regen aura. 2x health regen, regen starts 2x sooner, +50% healing received, +10% max HP. Ability +2 WIS.
  - druid: Natural armor. +20% max HP, take 15% less damage, +10% move speed, +25% regen. Ability +2 WIS, +1 CON.
  - fighter: Second Wind. +25% max HP, +10% damage, Second Wind (once per life: dropping to 30% HP restores 30% HP). Ability +2 STR, +1 CON.
  - monk: Martial flow. +15% move speed, +10% jump, +50% wall-run time, +5% damage. Ability +2 DEX, +1 WIS.
  - paladin: Smite + ward. +15% damage, take 10% less damage, +25% healing received, +10% max HP. Ability +2 STR, +2 CHA.
  - ranger: Hunter's Mark. +10% crit chance, +5% damage, +8% move speed, +5% jump. Ability +2 DEX, +1 WIS.
  - rogue: Sneak Attack. +25% crit chance, +60% crouch speed, take 15% less damage while crouching, +5% move speed. Ability +2 DEX.
  - sorcerer: Wild surge. +20% damage, +50% regen, +5% move speed, take 15% more damage. Ability +2 CHA.
  - warlock: Eldritch pact. +25% damage, +25% healing received, -15% max HP, take 10% more damage. Ability +2 CHA.
  - wizard: Forge affinity. +10% damage, Forge cooldown halved, -15% max HP, take 20% more damage. Ability +2 INT.
- enemy_mod: params {"mod":"weaken"}. Player requisitions may ONLY weaken enemies — never enrage. Cost 150. action "modify".
- enemy_spawn: params {"type":"grunt"|"rusher"|"marksman"|"brute"|"shredder"|"suppressor"|"bulwark"|"warlord","count":1-6,"creature_type": optional one of the 14 D&D types below}. Spawns hostile enemies for target practice / a challenge. Cost 150. action "spawn". The "type" is the enemy CHASSIS (how it fights); "creature_type" is the D&D 5e type tag (what it IS — drives its real immunities, see CREATURE TYPES). "spawn an undead brute" -> {"type":"brute","count":1,"creature_type":"undead"}. "a fiend warlord" -> {"type":"warlord","count":1,"creature_type":"fiend"}. Omit "creature_type" for plain militia (humanoid).
CREATURE TYPES (D&D 5e — all 14; every enemy carries one; the game ENFORCES the enforced rows, no prose-only tags):
- aberration — RESIST psychic. No blanket condition immunity.
- beast — no immunities (baseline animal).
- celestial — RESIST radiant, necrotic. Condition immunities (lore-only, no game mechanic): charmed, frightened. Exhaustion IS enforced: celestial cannot gain exhaustion.
- construct — IMMUNE poison, psychic damage. ENFORCED: poisoned, sleep, exhaustion, petrified. Lore-only: charmed, frightened, paralyzed. Poison does NOTHING to a construct; sleep never lands; petrified does nothing (stone cannot turn to stone).
- dragon — no blanket immunities (immunity varies by ancestry: red=fire, white=cold, ... — never guess one).
- elemental — IMMUNE poison damage. ENFORCED: poisoned, sleep, exhaustion, restrained, prone, petrified. Lore-only: grappled, paralyzed. (Unconscious immunity is what makes sleep fail.)
- fey — ENFORCED: sleep (fey ancestry — immune to magical sleep). Charm is advantage, NOT immunity — never emit charm immunity for fey.
- fiend — IMMUNE poison damage; RESIST cold, fire, lightning. ENFORCED: poisoned.
- giant — no immunities (toughness is hit points).
- humanoid — no immunities (baseline; every militia enemy is humanoid).
- monstrosity — no immunities (varies by monster).
- ooze — RESIST acid. ENFORCED: exhaustion, prone. Lore-only: blinded, charmed, deafened, frightened.
- plant — ENFORCED: exhaustion. Lore-only: blinded, deafened, frightened.
- undead — IMMUNE poison damage. ENFORCED: poisoned, sleep, exhaustion. Poison does NOTHING to undead; sleep never lands.
- No type is vulnerable to anything (5e has almost no blanket per-type vulnerability — never invent one, e.g. undead are NOT vulnerable to radiant).
- "Lore-only" means the 5e trait is real but the game has no mechanic for that condition (no charm/fear/paralysis system) — the prompt lists it for honesty, the game enforces only the ENFORCED rows.
ABILITY SCORES (D&D 5e — every character carries a stat block): STR (Strength), DEX (Dexterity), CON (Constitution), INT (Intelligence), WIS (Wisdom), CHA (Charisma). Scores 1-30, 10 = average. Modifier = floor((score-10)/2): 10 -> +0, 16 -> +3, 8 -> -1. Forge enemy_spawn does NOT set scores (the class system owns them); when a prompt names a class or a score, say the score in the refusal reason or leave scores to the class system — never invent a score field in a ModSpec (the gate rejects it).
- killstreak: params {"streak":"uav"|"airstrike"|"chopper","target":"marked"|"auto"}. Costs: uav 150, airstrike 300, chopper 450. action "spawn".
- arena_event: params {"event":"smoke"|"supply_drop","duration_sec":5-120}. Costs: smoke 100, supply_drop 50. action "event". (duration_sec optional for supply_drop)
SPELL SCHOOLS — TAG ONLY, FOR CREATE-A-MOD (this Forge build path has NO school field; never emit one here): the eight D&D 5e spell schools — abjuration (protective magic — wards, shields, banishment), conjuration (summoning and calling), divination (knowledge — revealing, sensing, foresight), enchantment (mind magic — charm, compulsion), evocation (raw energy — fire, lightning, force), illusion (deception — phantasms, false sense), necromancy (life and death — draining, undeath), transmutation (change — altering form, matter, properties). In Create-a-Mod, a spell-like generated mod may be tagged with ONE school; the school shows in approval + mod info and NEVER changes mechanics (no damage bonus, no cost change, no spell slots, no skills/feats).
Rules: default "position" to "near_player"; use "marked" only when the prompt says "there", "where I'm looking", or "where I'm aiming". COMPOSITION: combine any known blocks — any known weapon + any known ammo_type, any known weapon/turret + any known "element" (see the emitter catalog), any known cover/structure + a known property — even when that exact combo has no preset. The game computes the final cost as the SUM of the composed blocks' costs (base block + each added block's surcharge); emit your best estimate of that sum. ROTATION: when the prompt asks for diagonal / rotated / sideways / angled placement, emit "rotation_deg" (yaw offset, -180..180; diagonal = 45) — never ignore a rotation request and build axis-aligned instead. INEXPRESSIBLE GEOMETRY: the builder can ONLY make straight, boxy, axis-built shapes from the catalog above — no curves, no spirals, no domes, no arches, no spheres, no cylinders, no cones, no pyramids, no rings, no tunnels, no mazes, no L/U-shaped or zigzag layouts, no scaled/resized structures (structures are fixed-size presets). If a request needs geometry the builder cannot express (e.g. spiral staircase, dome, curved wall, arch, sphere, pyramid, tunnel), emit the REFUSAL shape with reason "can't build that geometry: <what was asked>" — NEVER silently substitute a different shape (a spiral staircase must NOT become straight stairs without saying so). If the prompt is unclear or asks for anything outside this catalog (vehicles, flying things, lasers, new weapons, new enemies, scripts, code, behaviour changes), emit the REFUSAL shape — never improvise a build as a substitute.
Examples:
Player: "build a tower near me" -> {"spec_version":1,"action":"spawn","target":"cover","params":{"shape":"tower","size_voxels":[4,10,4],"position":"near_player","hp":350},"cost":150,"ttl":0}
Player: "give me a sniper rifle" -> {"spec_version":1,"action":"spawn","target":"weapon","params":{"weapon_id":"longeye"},"cost":235,"ttl":0}
Player: "give me an LMG with sniper bullets" -> {"spec_version":1,"action":"spawn","target":"weapon","params":{"weapon_id":"lmg","ammo_type":"sniper"},"cost":400,"ttl":0}
Player: "give me a burst rifle" -> {"spec_version":1,"action":"spawn","target":"weapon","params":{"weapon_id":"trident"},"cost":310,"ttl":0}
Player: "give me a judge" -> {"spec_version":1,"action":"spawn","target":"weapon","params":{"weapon_id":"judge"},"cost":200,"ttl":0}
Player: "spawn an undead brute" -> {"spec_version":1,"action":"spawn","target":"enemy_spawn","params":{"type":"brute","count":1,"creature_type":"undead"},"cost":150,"ttl":0}
Player: "a fiend warlord" -> {"spec_version":1,"action":"spawn","target":"enemy_spawn","params":{"type":"warlord","count":1,"creature_type":"fiend"},"cost":150,"ttl":0}
Player: "spawn two celestial marksmen" -> {"spec_version":1,"action":"spawn","target":"enemy_spawn","params":{"type":"marksman","count":2,"creature_type":"celestial"},"cost":150,"ttl":0}
Player: "build a reinforced bunker" -> {"spec_version":1,"action":"spawn","target":"structure","params":{"shape":"bunker","position":"near_player","property":"reinforced"},"cost":230,"ttl":0}
Player: "build a lightning emitter" -> {"spec_version":1,"action":"spawn","target":"emitter","params":{"element":"lightning","position":"near_player","radius":4,"duration_sec":10,"damage_per_sec":10},"cost":200,"ttl":0}
Player: "build a lightning emitter turret" -> {"spec_version":1,"action":"spawn","target":"turret","params":{"position":"near_player","duration_sec":45,"element":"lightning"},"cost":325,"ttl":0}
Player: "give me a fire rifle" -> {"spec_version":1,"action":"spawn","target":"weapon","params":{"weapon_id":"manticore","element":"fire"},"cost":355,"ttl":0}
Player: "build a ramp rotated 90 degrees" -> {"spec_version":1,"action":"spawn","target":"structure","params":{"shape":"ramp","position":"near_player","rotation_deg":90},"cost":90,"ttl":0}
Player: "build a spiral staircase" -> {"spec_version":1,"action":"refuse","target":"none","params":{"reason":"can't build that geometry: spiral staircases need curved geometry the Forge can't build"},"cost":0,"ttl":0}
Player: "build a dome" -> {"spec_version":1,"action":"refuse","target":"none","params":{"reason":"can't build that geometry: domes need curved geometry the Forge can't build"},"cost":0,"ttl":0}
Player: "make me a rogue" -> {"spec_version":1,"action":"modify","target":"class","params":{"class_id":"rogue"},"cost":0,"ttl":0}
Player: "make a flying car that shoots lasers" -> {"spec_version":1,"action":"refuse","target":"none","params":{"reason":"flying cars and lasers are not in the build catalog"},"cost":0,"ttl":0}"""

## USER MODS catalog section (v0.7): sent as the SECOND system message,
## AFTER the stable base SYSTEM_PROMPT and BEFORE the user prompt. Lists
## ENABLED user mods ONLY — disabled / broken mods never appear, so the
## model can never reference them. When no mods are installed the section
## is a fixed one-liner, so the system messages stay byte-identical
## across calls.
## Each line gives the model the exact mod_block id, target, cost, and
## param shape to emit: params {"mod_block":"<id>"} plus "position" for
## placed builds (near_player|marked|[x,y,z]). Composition with
## ammo_type/property still applies; the game recomputes cost from the
## mod's declared cost plus any composition surcharge.
static func user_mods_section() -> String:
	var enabled := ModLoader.get_enabled_mods()
	if enabled.is_empty():
		return "\nUSER MODS: none installed. (Players can add validated blocks in user://mods/.)\n"
	var lines: Array[String] = []
	lines.append("USER MODS — player-installed blocks (validated by the game). You may use ONLY the mod_block ids listed here; never invent one. A user-mod build uses params {\"mod_block\":\"<id>\"} plus \"position\" for placed builds (near_player|marked|[x,y,z]). The game computes the cost from the mod's declared cost; emit your best estimate.")
	for m in enabled:
		var rec := ModLoader.find_mod(str(m.get("id", "")))
		var info: Dictionary = rec.get("block_info", {})
		var desc := str(info.get("description", "")).strip_edges()
		var line := "- mod_block \"%s\" [%s] %s. Cost %d." % [
			str(m.get("id", "")),
			str(info.get("target", "")),
			str(info.get("display_name", "")),
			int(info.get("cost", 0)),
		]
		if not desc.is_empty():
			line += " %s" % desc
		lines.append(line)
	return "\n" + "\n".join(lines) + "\n"


var _in_flight := false
var _pending_spec: Dictionary = {}


func request_spec(prompt: String) -> Dictionary:
	if _in_flight:
		return {}
	_in_flight = true
	var key := ForgeConfig.load_key()
	if key.is_empty():
		_finish(_fallback_spec(prompt))
		return {}
	_request_remote(prompt, key)
	return {}


func is_busy() -> bool:
	return _in_flight


func _request_remote(prompt: String, key: String) -> void:
	# CACHE LAYOUT: messages[0] is the stable SYSTEM_PROMPT (byte-identical
	# every call, a whole-message cache unit); messages[1] is the user-mods
	# section (the only variable system content, clearly delimited);
	# messages[2] carries ALL other variable content, with the user prompt
	# LAST. Never reorder these, and never put variable text in
	# messages[0] — either breaks DeepSeek's prefix-cache match.
	# Directive A: Forge building is FREE (BUDGET_ENABLED = false in the
	# manager) — no budget figure rides along, so the model never rations
	# a build against a budget that does not gate anything.
	var body := {
		"model": MODEL,
		"messages": [
			{"role": "system", "content": SYSTEM_PROMPT},
			{"role": "system", "content": user_mods_section()},
			{"role": "user", "content": "Forge building is free (no budget limit). Player requisition: %s" % prompt},
		],
		"response_format": {"type": "json_object"},
		"temperature": TEMPERATURE,
		"max_tokens": MAX_TOKENS,
		# Thinking mode is ON by default on deepseek-flash and bills
		# reasoning tokens as output. This is a fixed-catalog JSON
		# extraction task: non-thinking is faster and cheaper.
		"thinking": {"type": "disabled"},
	}
	var http := HTTPRequest.new()
	http.timeout = HTTP_TIMEOUT_SEC
	add_child(http)
	http.request_completed.connect(_on_http_completed.bind(http, prompt))
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + key,
	])
	var err := http.request(API_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		push_warning("ForgeLLM: HTTPRequest failed to start (%s); using fallback." % error_string(err))
		http.queue_free()
		_finish(_fallback_spec(prompt))


func _on_http_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, prompt: String) -> void:
	var text := ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		text = body.get_string_from_utf8()
	http.queue_free()
	var spec := _extract_spec(text)
	if spec.is_empty():
		if result != HTTPRequest.RESULT_SUCCESS:
			push_warning("ForgeLLM: request failed (result=%d, http=%d); using fallback." % [result, code])
		else:
			push_warning("ForgeLLM: model returned bad JSON; using fallback.")
		spec = _fallback_spec(prompt)
	_finish(spec)


## Pulls the ModSpec JSON out of a chat-completions response envelope.
## Returns {} unless the payload has action+target. A REFUSAL spec passes
## through untouched — the manager handles it before any validation, and
## it must NEVER fall through to the offline fallback (which might
## improvise a build for a prompt the model correctly refused).
func _extract_spec(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {}
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return {}
	var choices: Array = (data as Dictionary).get("choices", [])
	if choices.is_empty() or not (choices[0] is Dictionary):
		return {}
	var msg: Dictionary = (choices[0] as Dictionary).get("message", {})
	var content := _strip_fences(str(msg.get("content", "")).strip_edges())
	var spec: Variant = JSON.parse_string(content)
	if not (spec is Dictionary):
		return {}
	var d := spec as Dictionary
	if not (d.has("action") and d.has("target")):
		return {}
	d["spec_version"] = 1
	return d


func _strip_fences(s: String) -> String:
	if s.begins_with("```"):
		var lines := s.split("\n")
		if lines.size() >= 2:
			lines = lines.slice(1)
			if lines[lines.size() - 1].strip_edges() == "```":
				lines = lines.slice(0, lines.size() - 1)
			return "\n".join(lines).strip_edges()
	return s


func _finish(spec: Dictionary) -> void:
	_in_flight = false
	_pending_spec = spec
	# Deferred: request_spec() may complete synchronously (offline fallback),
	# and the caller only starts awaiting AFTER it returns.
	call_deferred("_emit_ready")


func _emit_ready() -> void:
	spec_ready.emit(_pending_spec)


# --- Refusal ---------------------------------------------------------------
# The model (or a future caller) can return a refusal spec when the prompt
# cannot be expressed with the fixed catalog. Refusals carry no build, no
# charge, and must be surfaced verbatim-ish to the player with suggestions.

## True when spec is the REFUSAL shape from SYSTEM_PROMPT.
static func is_refusal(spec: Dictionary) -> bool:
	return str(spec.get("action", "")) == "refuse" and str(spec.get("target", "")) == "none"


## Player-facing refusal text: the reason (when sane) + what IS buildable.
## Never echoes raw model text beyond the capped reason string.
static func refusal_message(spec: Dictionary) -> String:
	var reason := ""
	if spec.get("params") is Dictionary:
		reason = str((spec["params"] as Dictionary).get("reason", "")).strip_edges().left(MAX_REFUSAL_REASON_CHARS)
	if reason.is_empty():
		return "Can't do that with the available blocks — try: %s" % UNKNOWN_SUGGESTIONS
	return "Can't do that with the available blocks (%s) — try: %s" % [reason, UNKNOWN_SUGGESTIONS]


# --- ModSpec validation (v0.6.2: composition-allowed gate) ------------------
# COMPOSITION-ALLOWED, unlike the v0.6.0 strict gate. The LLM may combine
# any KNOWN blocks (any known weapon + any known ammo_type, any known
# cover/structure + a known property, any known turret + any known
# ammo_type) even when that exact combo has no preset. Each PIECE is
# validated against its catalog — an unknown action/target/block, an
# invented field, code/script content, or an out-of-range number still
# returns [false, reason]. The COST is never a rejection reason anymore:
# recompute_cost() sums the composed blocks' costs and the recomputed
# value is substituted into spec["cost"] as truth, so a stale or estimated
# model cost cannot reject a valid build. Refusals are handled by the
# manager before this gate; they are not build specs. The trusted
# ForgeBuilder only ever receives specs that passed this gate (or the
# offline fallback, whose outputs are in-catalog by construction and pass
# it too).
#
# Returns [ok: bool, reason: String]. On success, spec["cost"] holds the
# recomputed game cost.

const _TOP_KEYS := ["spec_version", "action", "target", "params", "cost", "ttl"]
const _FORBIDDEN_KEYS := ["script", "code", "gdscript", "eval", "expression", "source", "behavior", "behaviour"]
const _FORBIDDEN_SUBSTRINGS := ["eval(", "OS.execute", "OS.create_process", "func ", "extends ", "GDScript", "load(", "preload(", "Expression", "call_deferred"]

static func validate_modspec(spec: Dictionary) -> Array:
	if spec.is_empty():
		return [false, "empty spec"]
	if is_refusal(spec):
		return [false, "refusal — not a build spec"]
	for k in spec.keys():
		if not (str(k) in _TOP_KEYS):
			return [false, "invented field '%s'" % str(k)]
		if str(k) in _FORBIDDEN_KEYS:
			return [false, "forbidden field '%s'" % str(k)]
	if int(spec.get("spec_version", 0)) != 1:
		return [false, "unsupported spec_version"]
	var action := str(spec.get("action", ""))
	var target := str(spec.get("target", ""))
	if not _is_catalog_pair(action, target):
		return [false, "unknown action/target '%s/%s'" % [action, target]]
	if not _is_clean_value(spec):
		return [false, "spec contains code/script content"]
	var cost: Variant = spec.get("cost", null)
	if not (cost is int or cost is float):
		return [false, "cost is not a number"]
	var ttl: Variant = spec.get("ttl", 0)
	if not (ttl is int or ttl is float) or float(ttl) < 0.0 or float(ttl) > 120.0:
		return [false, "ttl out of range 0-120"]
	if not (spec.get("params") is Dictionary):
		return [false, "params is not an object"]
	var params: Dictionary = spec["params"]
	var param_verdict := _validate_params(target, params)
	if not bool(param_verdict[0]):
		return param_verdict
	# COST: recompute from the composed blocks; the recomputed sum is
	# truth and is SUBSTITUTED — a mismatch is never a rejection.
	var recomputed := recompute_cost(target, params)
	if recomputed < 0:
		return [false, "unknown build in catalog"]
	spec["cost"] = recomputed
	return [true, "ok"]


## (action, target) pairs the catalog allows.
static func _is_catalog_pair(action: String, target: String) -> bool:
	match target:
		"cover", "structure", "turret", "pickup", "weapon", "killstreak", "enemy_spawn", "emitter":
			return action == "spawn"
		"enemy_mod", "class":
			return action == "modify"
		"arena_event":
			return action == "event"
	return false


## Recomputes the game cost of a spec from its composed blocks: the base
## block's fixed cost PLUS each composed block's surcharge (ammo_type,
## property). Returns -1 when the base build or a composed piece is
## unknown (the caller / _validate_params rejects those first).
static func recompute_cost(target: String, params: Dictionary) -> int:
	# v0.7 USER MODS: the mod's declared cost is the base. Composition
	# surcharges still apply for an ammo_type/property the mod does NOT
	# already declare (a mod that already declares the same value adds
	# nothing — no double charge).
	if params.has("mod_block"):
		var rec := ModLoader.find_mod(str(params.get("mod_block", "")))
		if rec.is_empty():
			return -1
		var info: Dictionary = rec.get("block_info", {})
		var mod_cost: Variant = info.get("cost", null)
		if not (mod_cost is int or mod_cost is float):
			return -1
		var extra := 0
		if params.has("ammo_type"):
			var at := str(params.get("ammo_type", ""))
			if str(info.get("ammo_type", "")) != at:
				match at:
					"standard":
						pass
					"sniper":
						extra += COST_AMMO_SNIPER
					"armor_piercing":
						extra += COST_AMMO_ARMOR_PIERCING
					"buckshot":
						extra += COST_AMMO_BUCKSHOT
					_:
						return -1
		if params.has("property"):
			var pr := str(params.get("property", ""))
			if str(info.get("property", "")) != pr:
				match pr:
					"standard":
						pass
					"reinforced":
						extra += COST_REINFORCED
					_:
						return -1
		# v0.5.8: element composition onto a mod-block turret/weapon.
		# (The "emitter" target carries "element" as its PRIMARY param,
		# not a composition — but mod_block never reaches here for
		# target "emitter": _validate_mod_block_params rejects it.)
		if params.has("element") and target in ["turret", "weapon"]:
			if not ElementalEmitter.is_element(str(params.get("element", ""))):
				return -1
			extra += COST_ELEMENT_SURCHARGE
		return int(mod_cost) + extra
	if target == "class":
		return 0
	var base := _base_cost(target, params)
	if base < 0:
		return -1
	var extra := 0
	if params.has("ammo_type"):
		match str(params.get("ammo_type", "")):
			"standard":
				pass
			"sniper":
				extra += COST_AMMO_SNIPER
			"armor_piercing":
				extra += COST_AMMO_ARMOR_PIERCING
			"buckshot":
				extra += COST_AMMO_BUCKSHOT
			_:
				return -1
	if params.has("property"):
		match str(params.get("property", "")):
			"standard":
				pass
			"reinforced":
				extra += COST_REINFORCED
			_:
				return -1
	# v0.5.8: element composition onto a turret/weapon (the base
	# build's cost already covers the plain version). The "emitter"
	# target carries "element" as its PRIMARY param — its base cost
	# already covers it, so no surcharge and no rejection here.
	if params.has("element"):
		if target in ["turret", "weapon"]:
			if not ElementalEmitter.is_element(str(params.get("element", ""))):
				return -1
			extra += COST_ELEMENT_SURCHARGE
		elif target != "emitter":
			return -1
	return base + extra


## Back-compat alias: the old fixed-cost lookup is now the recompute.
static func _catalog_cost(target: String, params: Dictionary) -> int:
	return recompute_cost(target, params)


## Fixed base cost of the primary block. -1 when the distinguishing param
## is itself unknown (caught by _validate_params, but cost must fail first
## so a bad shape cannot smuggle a plausible cost past the gate).
static func _base_cost(target: String, params: Dictionary) -> int:
	match target:
		"cover":
			match str(params.get("shape", "")):
				"wall":
					return COST_WALL
				"tower":
					return COST_TOWER
				"barricade":
					return COST_BARRICADE
		"structure":
			match str(params.get("shape", "")):
				"bridge":
					return COST_BRIDGE
				"bunker":
					return COST_BUNKER
				"watchtower":
					return COST_WATCHTOWER
				"ammo_depot":
					return COST_AMMO_DEPOT
				"stairs":
					return COST_STAIRS
				"ramp":
					return COST_RAMP
				"wall":
					return COST_STRUCTURE_WALL
				"jump_pad":
					return COST_JUMP_PAD
				"cover_piece":
					return COST_COVER_PIECE
				"sniper_nest":
					return COST_SNIPER_NEST
		"turret":
			return COST_TURRET
		"emitter":
			return COST_EMITTER
		"pickup":
			return COST_PICKUP
		"weapon":
			return weapon_cost(str(params.get("weapon_id", "")))
		"enemy_mod":
			return COST_ENEMYMOD
		"enemy_spawn":
			return COST_SPAWN_ENEMIES
		"killstreak":
			match str(params.get("streak", "")):
				"uav":
					return COST_UAV
				"airstrike":
					return COST_AIRSTRIKE
				"chopper":
					return COST_CHOPPER
		"arena_event":
			match str(params.get("event", "")):
				"smoke":
					return COST_SMOKE
				"supply_drop":
					return COST_SUPPLY
	return -1


## Per-target param validation: required keys + optional composition keys
## (ammo_type / property), enums, ranges. No clamping, no defaults, no
## repair — anything outside the catalog is a rejection. Composition
## pieces (ammo_type, property) are validated individually against their
## own catalogs, never against a preset list of whole combos.
static func _validate_params(target: String, params: Dictionary) -> Array:
	for k in params.keys():
		if str(k) in _FORBIDDEN_KEYS:
			return [false, "forbidden param '%s'" % str(k)]
	# v0.7 USER MODS: a spec referencing an enabled user-mod block takes
	# this branch instead of the per-target shape checks — the block
	# itself carries the shape/stats (already validated at scan time).
	# Only the reference, the target match, and any composition keys are
	# checked here. Extra base keys (shape, hp, ...) are ignored: the
	# mod block wins.
	if params.has("mod_block"):
		return _validate_mod_block_params(target, params)
	match target:
		"cover":
			if not _keys_with_optional(params, ["shape", "size_voxels", "position", "hp"], ["shape", "size_voxels", "position", "hp", "property", "rotation_deg"]):
				return [false, "cover params must be shape/size_voxels/position/hp (+optional property/rotation_deg)"]
			if not (str(params.get("shape", "")) in ["wall", "tower", "barricade"]):
				return [false, "bad cover shape '%s'" % str(params.get("shape", ""))]
			if not _is_size_voxels(params.get("size_voxels", null)):
				return [false, "size_voxels must be [x,y,z] each 1-12"]
			if not _is_position(params.get("position", null)):
				return [false, "bad position"]
			if not _is_num_in(params.get("hp", null), 50.0, 500.0):
				return [false, "hp out of range 50-500"]
			if params.has("property") and not (str(params.get("property", "")) in BLOCK_PROPERTIES):
				return [false, "bad cover property '%s'" % str(params.get("property", ""))]
			if params.has("rotation_deg") and not _is_rotation_deg(params.get("rotation_deg", null)):
				return [false, "rotation_deg out of range -180..180"]
		"structure":
			if not _keys_with_optional(params, ["shape", "position"], ["shape", "position", "property", "rotation_deg"]):
				return [false, "structure params must be shape/position (+optional property/rotation_deg)"]
			if not (str(params.get("shape", "")) in ["bridge", "bunker", "watchtower", "ammo_depot", "stairs", "ramp", "wall", "jump_pad", "cover_piece", "sniper_nest"]):
				return [false, "bad structure '%s'" % str(params.get("shape", ""))]
			if not _is_position(params.get("position", null)):
				return [false, "bad position"]
			if params.has("property") and not (str(params.get("property", "")) in BLOCK_PROPERTIES):
				return [false, "bad structure property '%s'" % str(params.get("property", ""))]
			if params.has("rotation_deg") and not _is_rotation_deg(params.get("rotation_deg", null)):
				return [false, "rotation_deg out of range -180..180"]
		"turret":
			if not _keys_with_optional(params, ["position", "duration_sec"], ["position", "duration_sec", "ammo_type", "rotation_deg", "element"]):
				return [false, "turret params must be position/duration_sec (+optional ammo_type/rotation_deg/element)"]
			if not _is_position(params.get("position", null)):
				return [false, "bad position"]
			if not _is_num_in(params.get("duration_sec", null), 5.0, 120.0):
				return [false, "duration_sec out of range 5-120"]
			if params.has("ammo_type") and not (str(params.get("ammo_type", "")) in AMMO_TYPES):
				return [false, "bad ammo_type '%s'" % str(params.get("ammo_type", ""))]
			if params.has("rotation_deg") and not _is_rotation_deg(params.get("rotation_deg", null)):
				return [false, "rotation_deg out of range -180..180"]
			if params.has("element") and not ElementalEmitter.is_element(str(params.get("element", ""))):
				return [false, "bad element '%s'" % str(params.get("element", ""))]
		"emitter":
			if not _keys_with_optional(params, ["element", "position"], ["element", "position", "radius", "duration_sec", "damage_per_sec"]):
				return [false, "emitter params must be element/position (+optional radius/duration_sec/damage_per_sec)"]
			if not ElementalEmitter.is_element(str(params.get("element", ""))):
				return [false, "bad element '%s'" % str(params.get("element", ""))]
			if not _is_position(params.get("position", null)):
				return [false, "bad position"]
			if params.has("radius") and not _is_num_in(params.get("radius", null), 1.0, 10.0):
				return [false, "radius out of range 1-10"]
			if params.has("duration_sec") and not _is_num_in(params.get("duration_sec", null), 3.0, 60.0):
				return [false, "duration_sec out of range 3-60"]
			if params.has("damage_per_sec") and not _is_num_in(params.get("damage_per_sec", null), 1.0, 100.0):
				return [false, "damage_per_sec out of range 1-100"]
		"pickup":
			if not _keys_exact(params, ["kind", "position"]):
				return [false, "pickup params must be kind/position"]
			if not (str(params.get("kind", "")) in ["ammo", "health"]):
				return [false, "bad pickup kind '%s'" % str(params.get("kind", ""))]
			if not _is_position(params.get("position", null)):
				return [false, "bad position"]
		"weapon":
			if not _keys_with_optional(params, ["weapon_id"], ["weapon_id", "ammo_type", "element"]):
				return [false, "weapon params must be weapon_id (+optional ammo_type/element)"]
			if not (str(params.get("weapon_id", "")) in ["manticore", "longeye", "breacher", "hornet", "p9", "raptor", "lmg", "trident", "judge"]):
				return [false, "bad weapon_id '%s'" % str(params.get("weapon_id", ""))]
			if params.has("ammo_type") and not (str(params.get("ammo_type", "")) in AMMO_TYPES):
				return [false, "bad ammo_type '%s'" % str(params.get("ammo_type", ""))]
			if params.has("element") and not ElementalEmitter.is_element(str(params.get("element", ""))):
				return [false, "bad element '%s'" % str(params.get("element", ""))]
		"class":
			if not _keys_exact(params, ["class_id"]):
				return [false, "class params must be class_id"]
			if not PlayerClasses.is_valid_class(str(params.get("class_id", ""))):
				return [false, "unknown class_id '%s'" % str(params.get("class_id", ""))]
		"enemy_mod":
			if not _keys_exact(params, ["mod"]):
				return [false, "enemy_mod params must be mod"]
			if str(params.get("mod", "")) != "weaken":
				return [false, "requisitions are limited to 'weaken'"]
		"enemy_spawn":
			# v0.5.8 D&D: all 8 chassis + optional creature_type (one of
			# the 14 types in DnDTypes). An unknown creature_type is a
			# rejection, never a silent humanoid fallback.
			if not _keys_with_optional(params, ["type", "count"], ["type", "count", "creature_type"]):
				return [false, "enemy_spawn params must be type/count (+optional creature_type)"]
			if not (str(params.get("type", "")) in ["grunt", "rusher", "marksman", "brute", "shredder", "suppressor", "bulwark", "warlord"]):
				return [false, "bad enemy type '%s'" % str(params.get("type", ""))]
			if not _is_int_in(params.get("count", null), 1, 6):
				return [false, "count out of range 1-6"]
			if params.has("creature_type") and not DnDTypes.is_creature_type(str(params.get("creature_type", ""))):
				return [false, "bad creature_type '%s'" % str(params.get("creature_type", ""))]
		"killstreak":
			if not _keys_exact(params, ["streak", "target"]):
				return [false, "killstreak params must be streak/target"]
			if not (str(params.get("streak", "")) in ["uav", "airstrike", "chopper"]):
				return [false, "bad streak '%s'" % str(params.get("streak", ""))]
			if not (str(params.get("target", "")) in ["marked", "auto"]):
				return [false, "bad killstreak target '%s'" % str(params.get("target", ""))]
		"arena_event":
			if not _keys_subset(params, ["event", "duration_sec"]):
				return [false, "arena_event params must be event (+duration_sec)"]
			if not (str(params.get("event", "")) in ["smoke", "supply_drop"]):
				return [false, "bad event '%s'" % str(params.get("event", ""))]
			if params.has("duration_sec") and not _is_num_in(params.get("duration_sec", null), 5.0, 120.0):
				return [false, "duration_sec out of range 5-120"]
	return [true, "ok"]


## v0.7: validates a spec whose params carry "mod_block". The reference
## must resolve to an ENABLED, error-free mod whose declared target
## matches the spec's target; composition keys (position / ammo_type /
## property / duration_sec / kind) are validated when present.
static func _validate_mod_block_params(target: String, params: Dictionary) -> Array:
	var ref: Variant = params.get("mod_block", null)
	if not (ref is String) or str(ref).strip_edges().is_empty():
		return [false, "mod_block must be a non-empty string"]
	var rec := ModLoader.find_mod(str(ref))
	if rec.is_empty():
		return [false, "unknown mod_block '%s'" % str(ref)]
	if not bool(rec.get("enabled", false)) or str(rec.get("error", "")) != "":
		return [false, "mod_block '%s' is disabled or broken" % str(ref)]
	var info: Dictionary = rec.get("block_info", {})
	if str(info.get("target", "")) != target:
		return [false, "mod_block '%s' is a %s, not a %s" % [str(ref), str(info.get("target", "")), target]]
	match target:
		"weapon":
			for k in params.keys():
				if str(k) not in ["mod_block", "ammo_type", "weapon_id", "element"]:
					return [false, "weapon mod_block params must be mod_block (+optional ammo_type/element)"]
		"cover":
			for k in params.keys():
				if str(k) not in ["mod_block", "position", "property", "shape", "size_voxels", "hp", "rotation_deg"]:
					return [false, "cover mod_block params must be mod_block/position (+optional property/rotation_deg)"]
		"structure":
			for k in params.keys():
				if str(k) not in ["mod_block", "position", "property", "shape", "rotation_deg"]:
					return [false, "structure mod_block params must be mod_block/position (+optional property/rotation_deg)"]
		"turret":
			for k in params.keys():
				if str(k) not in ["mod_block", "position", "duration_sec", "ammo_type", "rotation_deg", "element"]:
					return [false, "turret mod_block params must be mod_block/position (+optional duration_sec/ammo_type/rotation_deg/element)"]
		"pickup":
			for k in params.keys():
				if str(k) not in ["mod_block", "position", "kind"]:
					return [false, "pickup mod_block params must be mod_block/position"]
		_:
			return [false, "mod_block not supported for target '%s'" % target]
	if params.has("position") and not _is_position(params.get("position", null)):
		return [false, "bad position"]
	if params.has("rotation_deg") and not _is_rotation_deg(params.get("rotation_deg", null)):
		return [false, "rotation_deg out of range -180..180"]
	if params.has("ammo_type") and not (str(params.get("ammo_type", "")) in AMMO_TYPES):
		return [false, "bad ammo_type '%s'" % str(params.get("ammo_type", ""))]
	if params.has("property") and not (str(params.get("property", "")) in BLOCK_PROPERTIES):
		return [false, "bad property '%s'" % str(params.get("property", ""))]
	if params.has("duration_sec") and not _is_num_in(params.get("duration_sec", null), 5.0, 120.0):
		return [false, "duration_sec out of range 5-120"]
	if params.has("element") and not ElementalEmitter.is_element(str(params.get("element", ""))):
		return [false, "bad element '%s'" % str(params.get("element", ""))]
	if params.has("kind") and info.has("kind") and str(params.get("kind", "")) != str(info.get("kind", "")):
		return [false, "kind '%s' does not match mod_block '%s'" % [str(params.get("kind", "")), str(ref)]]
	return [true, "ok"]


## Recursively scans every string in the spec for code/script content.
## The catalog has no legitimate string containing any of these.
static func _is_clean_value(v: Variant) -> bool:
	if v is String:
		var s: String = v
		for bad in _FORBIDDEN_SUBSTRINGS:
			if s.contains(bad):
				return false
		return true
	if v is Dictionary:
		for k in (v as Dictionary).keys():
			if not _is_clean_value(k):
				return false
			if not _is_clean_value((v as Dictionary)[k]):
				return false
		return true
	if v is Array:
		for item in (v as Array):
			if not _is_clean_value(item):
				return false
		return true
	return true


static func _keys_exact(params: Dictionary, required: Array) -> bool:
	if params.size() != required.size():
		return false
	for k in required:
		if not params.has(k):
			return false
	return true


## Required keys must all be present; every key (required or extra) must
## be in `allowed`. Composition params live in `allowed` but not
## `required` (e.g. weapon: required [weapon_id], allowed + ammo_type).
static func _keys_with_optional(params: Dictionary, required: Array, allowed: Array) -> bool:
	for k in required:
		if not params.has(k):
			return false
	for k in params.keys():
		if not (str(k) in allowed):
			return false
	return true


static func _keys_subset(params: Dictionary, allowed: Array) -> bool:
	if params.is_empty():
		return false
	for k in params.keys():
		if not (str(k) in allowed):
			return false
	for k in ["event"]:
		if not params.has(k):
			return false
	return true


static func _is_num_in(v: Variant, lo: float, hi: float) -> bool:
	return (v is int or v is float) and float(v) >= lo and float(v) <= hi


## rotation_deg: yaw offset in degrees, -180..180 (0 = default orientation).
static func _is_rotation_deg(v: Variant) -> bool:
	return _is_num_in(v, -180.0, 180.0)


static func _is_int_in(v: Variant, lo: int, hi: int) -> bool:
	# Accepts int, or a float with an integral value (Godot's JSON parser
	# returns ALL numbers as float, so a JSON block's 4 arrives as 4.0).
	# Mirrors ModLoader._is_int_in — the live LLM path parses JSON, so a
	# strict int-only check rejected valid cover/enemy_spawn specs.
	if v is int:
		return int(v) >= lo and int(v) <= hi
	if v is float and float(v) == floor(float(v)):
		return int(v) >= lo and int(v) <= hi
	return false


static func _is_size_voxels(v: Variant) -> bool:
	if not (v is Array) or (v as Array).size() != 3:
		return false
	for item in (v as Array):
		if not _is_int_in(item, 1, 12):
			return false
	return true


## "near_player" | "marked" | [x,y,z] with x/z in -60..60, y in 0..30
## (the ForgeBuilder arena clamp).
static func _is_position(v: Variant) -> bool:
	if v is String:
		return str(v) in ["near_player", "marked"]
	if v is Array and (v as Array).size() == 3:
		var a: Array = v
		return _is_num_in(a[0], -60.0, 60.0) and _is_num_in(a[1], 0.0, 30.0) and _is_num_in(a[2], -60.0, 60.0)
	return false


# --- Offline keyword-matcher fallback ---------------------------------------
# Genuinely useful on its own: covers every Forge target with sensible
# defaults so the prompt->build loop works with zero network and zero key.
# All-static so preview_cost() can parse without executing or touching the
# network. Unknown prompts return {"_error": unknown_error(prompt)} instead
# of improvising a build, so the UI can show a helpful error that names
# the prompt and lists what IS buildable. v0.5.1 FIX 7b: the error echoes
# the prompt ("Don't know 'knife' — try: ...") so the player sees WHY
# nothing happened instead of silence. No knife weapon is added — "knife"
# stays unknown by design; the error is the fix.

## Synchronous offline parse: returns a ModSpec, or {"_error": hint} when the
## prompt matches nothing. Never touches the network.
static func parse_offline(prompt: String) -> Dictionary:
	return _fallback_spec(prompt)


static func _ph(hay: String, words: Array) -> bool:
	for w in words:
		if hay.contains(str(w)):
			return true
	return false


static func _spec(action: String, target: String, params: Dictionary, cost: int) -> Dictionary:
	return {"spec_version": 1, "action": action, "target": target, "params": params, "cost": cost, "ttl": 0}


static func _unknown_spec(prompt: String = "") -> Dictionary:
	var d := _spec("event", "arena_event", {"event": "supply_drop"}, 0)
	d["_error"] = unknown_error(prompt)
	return d


## Visible-error text for an unparseable prompt. Echoes the prompt (so
## "knife" doesn't vanish into silence) plus the buildable suggestions.
## Empty prompt falls back to the generic UNKNOWN_HINT.
static func unknown_error(prompt: String) -> String:
	var clean := prompt.strip_edges().left(40)
	if clean.is_empty():
		return UNKNOWN_HINT
	return "Don't know '%s' — try: %s" % [clean, UNKNOWN_SUGGESTIONS]


## First element name in the prompt ("fire", "lightning", ...), or ""
## when none. "fire" matches the word "fire" anywhere — callers that
## treat "fire" as a verb (weapon fallback) must not use this.
static func _element_in_prompt(p: String) -> String:
	for el in ElementalEmitter.ELEMENTS:
		if _ph(p, [el]):
			return el
	return ""



## a mod_block spec for the first enabled mod whose multi-word name
## (mod id, name, display_name, or block_id — underscores/hyphens become
## spaces) appears in the prompt, or {} when nothing matches. The cost is
## the mod's declared cost; validate_modspec recomputes it as truth.
## Single-word names never match (see _fallback_spec).
## LONGEST match wins (v0.5.12): when two mods' names both appear
## ("Taquito Launcher" and "Taquito Launcher Script"), the longer name
## is the more specific request — first-match-wins would make the
## longer-named mod unreachable by name.
static func _mod_spec_for_prompt(p: String) -> Dictionary:
	var best: Dictionary = {}
	var best_len := -1
	for m in ModLoader.get_enabled_mods():
		if not (m is Dictionary):
			continue
		var rec := ModLoader.find_mod(str((m as Dictionary).get("id", "")))
		if rec.is_empty():
			continue
		var info: Dictionary = rec.get("block_info", {})
		var target := str(info.get("target", ""))
		if target not in ["weapon", "cover", "structure", "turret", "pickup"]:
			continue
		var names: Array[String] = [
			str((m as Dictionary).get("id", "")),
			str((m as Dictionary).get("name", "")),
			str(info.get("display_name", "")),
			str(info.get("block_id", "")),
		]
		for raw_name in names:
			var norm := _normalize_mod_name(raw_name)
			if norm.is_empty() or not norm.contains(" "):
				continue
			if p.contains(norm) and norm.length() > best_len:
				best_len = norm.length()
				var params := {"mod_block": str((m as Dictionary).get("id", ""))}
				if target in ["cover", "structure", "turret", "pickup"]:
					params["position"] = "near_player"
				best = _spec("spawn", target, params, int(info.get("cost", 0)))
	return best


## Lowercase, underscores/hyphens -> spaces, collapsed whitespace.
static func _normalize_mod_name(raw: String) -> String:
	var s := raw.to_lower().replace("_", " ").replace("-", " ").strip_edges()
	while s.contains("  "):
		s = s.replace("  ", " ")
	return s


## Offline weapon + ammo composition: a known weapon (by Forge id, alias,
## or class keyword) PLUS an ammo keyword with a trigger word -> the
## composed spec. {} when the prompt is not a composition. The cost is
## weapon_cost() + the ammo surcharge; validate_modspec recomputes it.
static func _offline_weapon_ammo_composition(p: String) -> Dictionary:
	var ammo_type := ""
	if p.contains("buckshot"):
		ammo_type = "buckshot"
	elif p.contains("armor-piercing") or p.contains("armor piercing") \
			or p.contains("ap bullets") or p.contains("ap rounds") or p.contains("ap ammo"):
		ammo_type = "armor_piercing"
	elif p.contains("sniper") and (p.contains("bullet") or p.contains("round") or p.contains("ammo") or p.contains("shell")):
		ammo_type = "sniper"
	if ammo_type.is_empty():
		return {}
	var wid := _offline_weapon_id(p)
	if wid.is_empty():
		return {}
	# "sniper ammo" alone is an AMMO pickup, not a composition: the only
	# weapon signal is the word "sniper" itself. Require an explicit
	# longeye marker ("sniper rifle", "dmr", ...) for a sniper-weapon
	# composition; anything else falls through to the ammo pickup branch.
	if ammo_type == "sniper" and wid == "longeye" \
			and not (p.contains("longeye") or p.contains("sniper rifle") \
			or p.contains("dmr") or p.contains("marksman rifle")):
		return {}
	var surcharge := 0
	match ammo_type:
		"sniper":
			surcharge = COST_AMMO_SNIPER
		"armor_piercing":
			surcharge = COST_AMMO_ARMOR_PIERCING
		"buckshot":
			surcharge = COST_AMMO_BUCKSHOT
	return _spec("spawn", "weapon", {"weapon_id": wid, "ammo_type": ammo_type},
		weapon_cost(wid) + surcharge)


## Offline enemy-spawn resolution (v0.5.8 D&D): "spawn an undead brute"
## -> {type brute, count 1, creature_type undead}; "a fiend warlord"
## -> {type warlord, count 1, creature_type fiend}; "spawn enemies" ->
## {type grunt, count 3} (the old behaviour). {} when the prompt is not
## an enemy spawn. Trigger: a spawn verb + a chassis/enemies word, OR
## a creature-type word + a chassis word (the bare "a fiend warlord"
## has no verb). Guards: "marksman rifle" (a weapon, no verb, no
## creature type) is NOT a spawn; "plant a turret" (a structure verb,
## no chassis) is NOT a spawn.
static func _offline_enemy_spawn(p: String) -> Dictionary:
	var chassis := ""
	for cand in ["warlord", "bulwark", "suppressor", "shredder", "marksman", "marksmen", "rusher", "brute", "grunt"]:
		if cand in p:
			chassis = "marksman" if cand == "marksmen" else cand
			break
	var creature := ""
	for cand in DnDTypes.CREATURE_TYPE_IDS:
		if cand in p:
			creature = cand
			break
	var spawn_verb := _ph(p, ["spawn", "summon", "send", "call in", "bring", "more enemies"])
	var enemies_word := _ph(p, ["enemies", "foes", "hostiles"])
	if chassis.is_empty() and not enemies_word:
		return {}
	if chassis.is_empty() and creature.is_empty():
		# "spawn enemies" with no type: generic grunts.
		if spawn_verb and enemies_word:
			return _spec("spawn", "enemy_spawn", {"type": "grunt", "count": 3}, COST_SPAWN_ENEMIES)
		return {}
	if chassis.is_empty():
		# Creature type but no chassis ("spawn undead enemies"): grunts
		# wearing the type.
		if spawn_verb and enemies_word:
			return _spec("spawn", "enemy_spawn", {"type": "grunt", "count": 3, "creature_type": creature}, COST_SPAWN_ENEMIES)
		return {}
	# A chassis is named: need a spawn verb, a creature type, or the
	# generic enemies word — otherwise "marksman rifle" / "brute force"
	# would hijack weapon / non-spawn prompts.
	if not spawn_verb and creature.is_empty() and not enemies_word:
		return {}
	var count := 1
	if _ph(p, ["six", " 6 "]):
		count = 6
	elif _ph(p, ["five", " 5 "]):
		count = 5
	elif _ph(p, ["four", " 4 "]):
		count = 4
	elif _ph(p, ["three", " 3 "]):
		count = 3
	elif _ph(p, ["pair", "two", " 2 "]):
		count = 2
	elif spawn_verb and enemies_word and creature.is_empty():
		count = 3
	var params := {"type": chassis, "count": count}
	if not creature.is_empty():
		params["creature_type"] = creature
	return _spec("spawn", "enemy_spawn", params, COST_SPAWN_ENEMIES)


## Offline weapon resolution shared by the composition check and (via the
## chain in _fallback_spec) plain weapon prompts. "" when no weapon.
static func _offline_weapon_id(p: String) -> String:
	for wid in ["manticore", "longeye", "breacher", "hornet", "p9", "raptor", "lmg", "trident", "judge"]:
		if wid in p:
			return wid
	if "shotgun" in p:
		return "breacher"
	if "sniper" in p or "dmr" in p or "marksman rifle" in p:
		return "longeye"
	if _ph(p, ["smg", "submachine"]):
		return "hornet"
	if _ph(p, ["pistol", "sidearm", "handgun"]):
		return "p9"
	if _ph(p, ["lmg", "machine gun", "minigun"]):
		return "lmg"
	if _ph(p, ["trident", "burst", "three-round", "3-round", "three round"]):
		return "trident"
	if _ph(p, ["judge", "revolver", "six-shooter", "six shooter"]):
		return "judge"
	if _ph(p, ["rifle", "gun", "weapon", "armed"]):
		return "manticore"
	return ""


# --- Shareable build codes --------------------------------------------------
# A build code is one copy-pasteable string for a whole build action:
#   "FORGE1-" + base64url(JSON of the ModSpec)
# base64url = standard base64 with + -> -, / -> _, padding stripped, so the
# code survives chat/clipboard without escaping. encode/decode are pure
# and total: encode always succeeds on a Dictionary; decode returns {}
# for garbage, non-JSON, or non-Dictionary input. A decoded spec is
# NEVER trusted: the manager runs it through validate_modspec (which
# rejects invented fields, unknown blocks, code content, out-of-range
# numbers) before anything builds. Cost in the code is informational —
# validation recomputes it as truth.

const BUILD_CODE_PREFIX := "FORGE1-"


static func encode_build_code(spec: Dictionary) -> String:
	var b64 := Marshalls.raw_to_base64(JSON.stringify(spec).to_utf8_buffer())
	return BUILD_CODE_PREFIX + b64.replace("+", "-").replace("/", "_").rstrip("=")


static func decode_build_code(code: String) -> Dictionary:
	var s := code.strip_edges()
	if s.begins_with(BUILD_CODE_PREFIX):
		s = s.substr(BUILD_CODE_PREFIX.length())
	if s.is_empty():
		return {}
	s = s.replace("-", "+").replace("_", "/")
	while s.length() % 4 != 0:
		s += "="
	var raw := Marshalls.base64_to_raw(s)
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if parsed is Dictionary:
		# JSON round-trip loses int-ness: Godot's JSON parser returns
		# ALL numbers as float, but the strict gate requires true ints
		# for size_voxels / count (see _is_int_in). Normalize integral
		# floats back to ints recursively, so a decoded spec validates
		# exactly like the spec it was encoded from. Non-integral floats
		# (hp, duration) pass through untouched.
		return _normalize_json_numbers(parsed)
	return {}


## Recursively converts integral floats (4.0) to ints (4) in a decoded
## JSON value. Mirrors the ModLoader._is_int_in tolerance (int OR
## integral float) at the boundary where JSON re-enters the game, instead
## of loosening the gate itself.
static func _normalize_json_numbers(v: Variant) -> Variant:
	if v is float and float(v) == floor(float(v)) and abs(float(v)) < 9007199254740992.0:
		return int(v)
	if v is Dictionary:
		var out := {}
		for k in (v as Dictionary).keys():
			out[k] = _normalize_json_numbers((v as Dictionary)[k])
		return out
	if v is Array:
		var arr: Array = []
		for item in (v as Array):
			arr.append(_normalize_json_numbers(item))
		return arr
	return v


## Offline parse wrapper: the inner parser maps the prompt to a spec,
## then rotation words ("diagonal", "rotated 45 degrees", ...) are
## applied as params.rotation_deg on placed builds (structure / cover /
## turret). Rotation is post-processing, not a branch: every placed
## build benefits, including mod-block and approximation specs. Only
## added when non-zero, so plain prompts produce byte-identical specs.
static func _fallback_spec(prompt: String) -> Dictionary:
	var spec := _fallback_spec_inner(prompt)
	if spec.has("_error"):
		return spec
	if str(spec.get("target", "")) not in ["structure", "cover", "turret"]:
		return spec
	var rot := _rotation_deg_from_prompt(prompt.to_lower())
	if is_zero_approx(rot):
		return spec
	var params: Dictionary = spec.get("params", {})
	params["rotation_deg"] = rot
	spec["params"] = params
	return spec


## Yaw offset in degrees parsed from prompt words. Explicit numbers win
## ("rotated 30 degrees" -> 30); otherwise keywords: diagonal 45,
## sideways/perpendicular 90, backwards/reversed 180. 0 = no rotation
## requested. NOTE: a bare "N degrees" on a ramp is read as YAW (the
## builder's slope is fixed and cannot be re-angled) — documented in
## the SYSTEM_PROMPT rotation rule.
static func _rotation_deg_from_prompt(p: String) -> float:
	var rx := RegEx.new()
	# "rotated 45 degrees" / "rotate the ramp 45" / "at 45 degrees" /
	# "45-degree ramp" / "45°" — the number after a rotation keyword,
	# or a number directly attached to "degree"/"°". Bare "at" is NOT a
	# rotation keyword (it would misread "at position 3" as rotation);
	# "at 45 degrees" is still caught by the "degrees" alternative.
	if rx.compile("(rotat\\w*|turn\\w*|angle\\w*)\\D{0,15}(-?\\d+)|(-?\\d+)\\s*-?\\s*degrees?|(-?\\d+)\\s*°") == OK:
		var m := rx.search(p)
		if m != null:
			for g in [2, 3, 4]:
				var s := m.get_string(g)
				if not s.is_empty():
					return clampf(float(s), -180.0, 180.0)
	if _ph(p, ["diagonal", "diagonally"]):
		return 45.0
	if _ph(p, ["sideways", "perpendicular", "crosswise"]):
		return 90.0
	if _ph(p, ["backwards", "backward", "reversed", "facing me", "facing toward me", "facing towards me"]):
		return 180.0
	return 0.0


## Inexpressible-geometry check (v0.5.7 Part B): the builder only makes
## straight, boxy shapes. Returns {} when the prompt is expressible.
## Otherwise returns a spec that is NEVER a silent wrong build:
## - {"kind": "approx"} cases return a real build spec for the nearest
##   buildable shape PLUS a "_approximation" note ("Closest I can
##   build: ...") — the manager strips the note before validation and
##   appends it to the visible result message + cost preview.
## - {"kind": "refuse"} cases return an "_error" spec whose message says
##   "Can't build that geometry" — surfaced via forge_result, no build.
## Runs AFTER the user-mod name match (a user-installed mod literally
## named e.g. "spiral stairs" still wins) and BEFORE the shape branches
## that would otherwise swallow these prompts ("spiral staircase"
## contains "staircase"; "curved wall" contains "wall").
static func _inexpressible_check(p: String) -> Dictionary:
	if _ph(p, ["spiral", "helix", "helical", "corkscrew"]):
		if _ph(p, ["ramp"]):
			return _approximation_spec("ramp", COST_RAMP, "straight ramp", "spiral geometry")
		if _ph(p, ["stairs", "staircase", "steps", "stair"]):
			return _approximation_spec("stairs", COST_STAIRS, "straight stairs", "spiral geometry")
		return _inexpressible_error(p)
	if _ph(p, ["curved", "curving", "curve"]):
		if _ph(p, ["wall"]):
			return _approximation_spec("wall", COST_STRUCTURE_WALL, "straight wall", "curved geometry")
		if _ph(p, ["ramp"]):
			return _approximation_spec("ramp", COST_RAMP, "straight ramp", "curved geometry")
		if _ph(p, ["bridge"]):
			return _approximation_spec("bridge", COST_BRIDGE, "straight bridge", "curved geometry")
		if _ph(p, ["stairs", "staircase"]):
			return _approximation_spec("stairs", COST_STAIRS, "straight stairs", "curved geometry")
		return _inexpressible_error(p)
	if _ph(p, ["circular", "circle", "ring", "round wall", "round tower"]):
		if _ph(p, ["wall"]):
			return _approximation_spec("wall", COST_STRUCTURE_WALL, "straight wall", "circular geometry")
		return _inexpressible_error(p)
	# Bare "cone" is NOT listed — it is a substring of "concrete"
	# ("concrete wall" must stay a wall). "a cone" / "cone-shaped" only.
	# Bare "ball" is kept: "fireball"-style prompts get a geometry error
	# instead of an unknown error — still an error, never a build.
	if _ph(p, ["dome", "domed", "sphere", "spherical", "arch", "archway",
			"cylinder", "cylindrical", "pyramid", "pyramidal",
			"triangle", "triangular", "torus", "tunnel", "maze",
			"labyrinth", "l-shaped", "l shaped", "u-shaped", "u shaped",
			"zigzag", "zig-zag", "oval", "ellipse", "cone-shaped",
			"cone shape", "a cone", "ball", "orb"]):
		return _inexpressible_error(p)
	return {}


## Nearest-buildable spec + the visible approximation label.
static func _approximation_spec(shape: String, cost: int, label: String, detail: String) -> Dictionary:
	var spec := _spec("spawn", "structure", {"shape": shape, "position": "near_player"}, cost)
	spec["_approximation"] = "Closest I can build: %s — the Forge can't build %s." % [label, detail]
	return spec


## Visible refusal for geometry the builder cannot express at all.
static func _inexpressible_error(prompt: String) -> Dictionary:
	var clean := prompt.strip_edges().left(40)
	var d := _spec("event", "arena_event", {"event": "supply_drop"}, 0)
	d["_error"] = "Can't build that geometry: '%s' — the Forge only builds straight, boxy shapes (no spirals, curves, domes, or arches). Try: %s" % [clean, UNKNOWN_SUGGESTIONS]
	return d


## Class-swap spec for an offline prompt ({} when no class intent).
## Cost 0 — class swaps are free; validate_modspec recomputes it.
static func _class_spec_for_prompt(p: String) -> Dictionary:
	var class_id := PlayerClasses.match_in_prompt(p)
	if class_id.is_empty():
		return {}
	return _spec("modify", "class", {"class_id": class_id}, 0)


static func _fallback_spec_inner(prompt: String) -> Dictionary:
	var p := prompt.to_lower()
	# v0.5.8 CLASSES: a class-swap prompt resolves before every other
	# branch — "make me a rogue" is a swap, never a build.
	var class_spec := _class_spec_for_prompt(p)
	if not class_spec.is_empty():
		return class_spec
	# Installed user mods by NAME first: a multi-word mod name in the
	# prompt ("give me a chunky wall") is a stronger signal than any base
	# keyword, so the mod wins over the base catalog. Single-word mod
	# names are deliberately NOT matched here — a mod named "wall" or
	# "sniper" would hijack every base prompt with that word. Single-word
	# mods stay reachable through the LLM path (its catalog lists them).
	var mod_spec := _mod_spec_for_prompt(p)
	if not mod_spec.is_empty():
		return mod_spec
	# Inexpressible geometry: visible refusal / labeled approximation,
	# never a silent wrong build (see _inexpressible_check).
	var inexpressible := _inexpressible_check(p)
	if not inexpressible.is_empty():
		return inexpressible
	# v0.5.8 elemental emitters (offline): "build a lightning emitter"
	# -> emitter pylon; "build a lightning emitter turret" / "lightning
	# turret" -> turret with element. "emitter" alone defaults to fire.
	# Elemental weapons stay LLM-path only offline ("fire rifle" is
	# ambiguous — "fire" is also a verb — so the fallback never guesses
	# it; the LLM path handles weapon + element composition). "portal
	# emitter" is the wrist portal tool, not an elemental emitter.
	if _ph(p, ["emitter"]) and not _ph(p, ["portal"]):
		var el := _element_in_prompt(p)
		if el.is_empty():
			el = "fire"
		if _ph(p, ["turret", "sentry", "auto gun", "auto-gun"]):
			var tparams := {"position": "near_player", "duration_sec": 45, "element": el}
			return _spec("spawn", "turret", tparams, COST_TURRET + COST_ELEMENT_SURCHARGE)
		return _spec("spawn", "emitter",
			{"element": el, "position": "near_player", "radius": 4, "duration_sec": 10, "damage_per_sec": 10},
			COST_EMITTER)
	if _ph(p, ["turret", "sentry", "auto gun", "auto-gun"]):
		var tel := _element_in_prompt(p)
		if tel != "":
			return _spec("spawn", "turret",
				{"position": "near_player", "duration_sec": 45, "element": tel},
				COST_TURRET + COST_ELEMENT_SURCHARGE)
		return _spec("spawn", "turret", {"position": "near_player", "duration_sec": 45}, COST_TURRET)
	# "watchtower" first: it contains "tower", and is its own buildable.
	if _ph(p, ["watchtower", "watch tower", "observation", "guard tower"]):
		return _spec("spawn", "structure", {"shape": "watchtower", "position": "near_player"}, COST_WATCHTOWER)
	if _ph(p, ["bunker", "pillbox", "foxhole", "dugout"]):
		return _spec("spawn", "structure", {"shape": "bunker", "position": "near_player"}, COST_BUNKER)
	# "ammo depot" before the generic ammo pickup ("ammo") and supply ("drop").
	if _ph(p, ["ammo depot", "ammo dump", "supply depot", "armory", "armoury", "ammo cache"]):
		return _spec("spawn", "structure", {"shape": "ammo_depot", "position": "near_player"}, COST_AMMO_DEPOT)
	# New structure shapes (Forge batch): checked BEFORE the generic
	# branches below — "sniper nest" contains "tower", "ramp" used to
	# fall into "bridge", "cover piece" contains "cover", and bare
	# "wall" is now the destructible structure wall (cover wall stays
	# reachable via "cover wall" / "barrier" / "blockade").
	if _ph(p, ["sniper nest", "sniper's nest", "sniper-nest"]):
		return _spec("spawn", "structure", {"shape": "sniper_nest", "position": "near_player"}, COST_SNIPER_NEST)
	if _ph(p, ["jump pad", "jump-pad", "launch pad", "launchpad"]):
		return _spec("spawn", "structure", {"shape": "jump_pad", "position": "near_player"}, COST_JUMP_PAD)
	if _ph(p, ["cover piece"]):
		return _spec("spawn", "structure", {"shape": "cover_piece", "position": "near_player"}, COST_COVER_PIECE)
	if _ph(p, ["stairs", "staircase", "steps"]):
		return _spec("spawn", "structure", {"shape": "stairs", "position": "near_player"}, COST_STAIRS)
	if _ph(p, ["ramp"]):
		return _spec("spawn", "structure", {"shape": "ramp", "position": "near_player"}, COST_RAMP)
	if _ph(p, ["bridge", "crossing", "walkway", "overpass"]):
		return _spec("spawn", "structure", {"shape": "bridge", "position": "near_player"}, COST_BRIDGE)
	# "tower" first: "build a sniper tower" is cover; bare "sniper" is a rifle.
	if _ph(p, ["tower", "overwatch", "lookout"]):
		return _spec("spawn", "cover", {"shape": "tower", "size_voxels": [4, 10, 4], "position": "near_player", "hp": 350}, COST_TOWER)
	if _ph(p, ["barricade"]):
		return _spec("spawn", "cover", {"shape": "barricade", "size_voxels": [6, 4, 2], "position": "near_player", "hp": 200}, COST_BARRICADE)
	if _ph(p, ["cover wall"]):
		return _spec("spawn", "cover", {"shape": "wall", "size_voxels": [8, 5, 2], "position": "near_player", "hp": 250}, COST_WALL)
	if _ph(p, ["wall", "fortif", "defense", "defence"]):
		return _spec("spawn", "structure", {"shape": "wall", "position": "near_player"}, COST_STRUCTURE_WALL)
	if _ph(p, ["cover", "barrier", "blockade", "hide"]):
		return _spec("spawn", "cover", {"shape": "wall", "size_voxels": [8, 5, 2], "position": "near_player", "hp": 250}, COST_WALL)
	if _ph(p, ["chopper", "helicopter", "heli", "air support"]):
		return _spec("spawn", "killstreak", {"streak": "chopper", "target": "auto"}, COST_CHOPPER)
	if _ph(p, ["airstrike", "air strike", "bomb", "carpet"]):
		return _spec("spawn", "killstreak", {"streak": "airstrike", "target": "marked"}, COST_AIRSTRIKE)
	if _ph(p, ["uav", "drone", "reveal", "recon", "scan", "show enemies", "spot", "surveillance"]):
		return _spec("spawn", "killstreak", {"streak": "uav", "target": "auto"}, COST_UAV)
	if "smoke" in p:
		return _spec("event", "arena_event", {"event": "smoke", "duration_sec": 20}, COST_SMOKE)
	# v0.5.8 D&D: spawn-by-type ("spawn an undead brute", "a fiend
	# warlord", "spawn undead enemies"). See _offline_enemy_spawn.
	var enemy_spawn := _offline_enemy_spawn(p)
	if not enemy_spawn.is_empty():
		return enemy_spawn
	# COMPOSITION (generalized from the old LMG-only branch): a known
	# weapon + an ammo keyword with a trigger word ("bullets"/"rounds"/
	# "ammo"/"shells", or bare "buckshot") is a weapon + ammo_type
	# composition, NOT an ammo pickup — checked before the generic ammo
	# branch below (which fires on "bullets"). "sniper rifle" alone is
	# NOT composition: it has no trigger word, so it stays a plain
	# longeye (see the sniper branch further down).
	var composed := _offline_weapon_ammo_composition(p)
	if not composed.is_empty():
		return composed
	if _ph(p, ["ammo", "reload", "bullets", "mags", "rounds"]):
		return _spec("spawn", "pickup", {"kind": "ammo", "position": "near_player"}, COST_PICKUP)
	if _ph(p, ["health", "heal", "medic", "medkit", "patch me", "hurt"]):
		return _spec("spawn", "pickup", {"kind": "health", "position": "near_player"}, COST_PICKUP)
	for wid in ["manticore", "longeye", "breacher", "hornet", "p9", "raptor", "lmg", "trident", "judge"]:
		if wid in p:
			return _spec("spawn", "weapon", {"weapon_id": wid}, weapon_cost(wid))
	if "shotgun" in p:
		return _spec("spawn", "weapon", {"weapon_id": "breacher"}, weapon_cost("breacher"))
	if "sniper" in p or "dmr" in p or "marksman rifle" in p or "sniper rifle" in p:
		return _spec("spawn", "weapon", {"weapon_id": "longeye"}, weapon_cost("longeye"))
	if _ph(p, ["smg", "submachine"]):
		return _spec("spawn", "weapon", {"weapon_id": "hornet"}, weapon_cost("hornet"))
	if _ph(p, ["pistol", "sidearm", "handgun"]):
		return _spec("spawn", "weapon", {"weapon_id": "p9"}, weapon_cost("p9"))
	if _ph(p, ["lmg", "machine gun", "minigun"]):
		return _spec("spawn", "weapon", {"weapon_id": "lmg"}, weapon_cost("lmg"))
	# New weapons by alias: "burst rifle" / "trident" -> BR-3 Trident,
	# "judge" / "revolver" -> HV-44 Judge. Checked before the generic
	# "rifle"/"gun" branch (which would swallow "burst rifle" as a
	# manticore) and after the specific branches above.
	if _ph(p, ["trident", "burst", "three-round", "3-round", "three round"]):
		return _spec("spawn", "weapon", {"weapon_id": "trident"}, weapon_cost("trident"))
	if _ph(p, ["judge", "revolver", "six-shooter", "six shooter"]):
		return _spec("spawn", "weapon", {"weapon_id": "judge"}, weapon_cost("judge"))
	if _ph(p, ["rifle", "gun", "weapon", "armed"]):
		return _spec("spawn", "weapon", {"weapon_id": "manticore"}, weapon_cost("manticore"))
	# NOTE: "enrage" maps to weaken — player requisitions may only weaken
	# (enrage is director-only and rejected in validation).
	if _ph(p, ["weaken", "enrage", "soften", "kill them", "take them out", "wreck them"]):
		return _spec("modify", "enemy_mod", {"mod": "weaken"}, COST_ENEMYMOD)
	if _ph(p, ["supply", "drop", "crate", "care package"]):
		return _spec("event", "arena_event", {"event": "supply_drop"}, COST_SUPPLY)
	# Unknown: no improvising — the caller surfaces unknown_error(prompt)
	# via Forge.forge_result (HUD feed + Forge menu toast) / preview_cost.
	return _unknown_spec(prompt)


# --- LLM MOD CREATION (v0.8 chunk 2, Worker A) --------------------------------
# SEPARATE from the Forge build path above. The build path turns a prompt
# into a ModSpec from the fixed catalog (SYSTEM_PROMPT + spec_ready, max
# 400 tokens). THIS path turns a player's mod idea into a NEW user mod
# (manifest + payload + summary) for human approval + install via
# ModCreator. It has its own template (GENERATION_SYSTEM_PROMPT), its own
# token budget (GENERATION_MAX_TOKENS), its own in-flight / queue state,
# and its own signal (generation_ready). It NEVER touches _in_flight,
# _pending_spec, spec_ready, SYSTEM_PROMPT, or validate_modspec.
# Cache layout mirrors the build path: messages[0] is the stable
# GENERATION_SYSTEM_PROMPT (byte-identical every call); messages[1]
# carries ALL variable content, with the user idea LAST.
# The generation result is a RAW generation object — {manifest, payload,
# summary} or {error} — NOT a candidate. ModCreator turns it into a
# candidate (mod_id, validation, install). Full validation lives in
# ModLoader.validate_generated_mod(); this path only checks the envelope
# shape (manifest is an object, payload/summary are strings).

signal generation_ready(result: Dictionary)

const GENERATION_MAX_TOKENS := 2000

## THE generation template. One stable constant, byte-identical on every
## call; the variable user idea goes LAST (in the user message), never
## inside or before this template, so DeepSeek's prefix cache can reuse
## it. ModAPI docs + ModBlock contract + manifest schema + few-shot
## examples (one JSON-block mod, one GDScript mod). The LLM decides kind:
## data-only idea -> block, behaviour idea -> script. Generation must
## NEVER emit filesystem / network / OS / eval code — stated here AND
## enforced by ModLoader.validate_generated_mod().
const GENERATION_SYSTEM_PROMPT := """You are the FORGE MOD SMITH in a voxel FPS. The player describes a NEW mod in one sentence. Reply with EXACTLY ONE raw JSON object — no markdown fences, no commentary:
{"manifest": {"name": "<short name>", "kind": "block"|"script", "version": "1.0", "description": "<one line>"}, "payload": "<JSON block text for kind=block OR GDScript source for kind=script>", "summary": "<plain-language summary, max 300 chars>", "spell_school": "<optional: ONE of abjuration|conjuration|divination|enchantment|evocation|illusion|necromancy|transmutation — tag ONLY for spell-like mods; omit the field (or use \"\") for non-spell mods>"}
KIND: data-only idea (stats, shape, size, cost of a known thing) -> "block". Behaviour idea (does something new when built or used) -> "script".
MODAPI — the ONLY functions a script mod may call (via the `api` argument). Never call anything else:
- get_player() -> Node3D — the player node (may be null).
- get_root() -> Node — the scene root builds attach to.
- get_player_position() -> Vector3 — player position, or Vector3.ZERO.
- get_aim_point() -> Vector3 — crosshair raycast point ("marked" position).
- spawn_voxel_box(size: Vector3, color: Color, position: Vector3, solid: bool) -> Node3D — one voxel block: visible cube + optional solid collider.
- spawn_cover(shape: String, size_voxels: Vector3i, hp: float, position: Vector3) -> Node — destructible voxel cover slab; shape wall|tower|barricade, size each 1-12, hp 50-500.
- spawn_pickup(kind: String, position: Vector3) -> Node — ammo|health pickup.
- spawn_turret(position: Vector3, duration_sec: float, damage_mult: float, range_mult: float) -> Node — sentry turret; duration 5-120.
- give_weapon(weapon_id: String, damage_mult: float, range_mult: float, mag_mult: float) -> bool — give a base weapon (manticore|longeye|breacher|hornet|p9|raptor|lmg), tuned by multipliers (1.0 = stock).
- fire_effect(kind: String, position: Vector3, radius: float, damage: float, duration_sec: float = 20.0, element: String = "fire") -> void — "explosion" (radius + damage), "smoke" (duration_sec), or "elemental" (a one-shot elemental burst of `element` at position: radius + damage, one hit).
- spawn_elemental_emitter(element: String, position: Vector3, radius: float, duration_sec: float, damage_per_sec: float) -> Node — persistent elemental emitter field: voxel particles + one elemental damage type + radius + duration, damaging ENEMIES ONLY inside the radius every 0.5 s. element: fire|cold|lightning|acid|poison|radiant|necrotic|thunder|force|water. ELEMENTAL EMITTER CATALOG (all elements + what each does): fire = fire damage + burn rider (damage over time); cold = cold damage + slow rider (x0.6 speed); lightning = lightning damage + knockback rider, x1.5 + chains to the nearest other enemy within 3 m for 50% vs WET targets; acid = acid damage + weaken rider (damage dealt x0.7); poison = poison damage + poison rider (damage over time + slow x0.85); radiant = radiant damage + blind rider (accuracy x0.5); necrotic = necrotic damage + +1 exhaustion level per hit; thunder = thunder damage + heavy knockback + brief prone; force = force damage (direct) + knockback — pure kinetic shove; water = small water damage + slow x0.6 + EXTINGUISHES burn + marks targets WET 4 s (lightning conducts off wet: x1.5 + chain). Water does NOT clear poison, bleed, or any other DOT. Emitters damage ENEMIES ONLY (never the player).
- announce(title: String, subtitle: String) -> void — HUD banner.
- get_player_health() -> float — current player HP, or -1 when there is no player / no HP to read.
- heal_player(amount: float) -> float — heals the player, returns the player's HP afterwards, or -1 when there is no player.
- apply_status_effect(target: Node, kind: String, params: Dictionary, origin: Vector3) -> bool — status effect on a target; origin is the hit point. Kinds: slow {"factor": 0.05-1.0, "duration_sec": 0.5-30}, freeze {"duration_sec": 0.5-10}, burn {"damage_per_sec": 1-500, "duration_sec": 0.5-30}, knockback {"force": 1-30} (AWAY from origin), pull {"force": 1-30} (TOWARD origin), poison {"damage_per_sec": 1-500, "duration_sec": 0.5-30} (DOT + slow x0.85), bleed {"damage_per_sec": 1-500, "duration_sec": 0.5-30} (DOT, ticks faster while moving), regen {"heal_per_sec": 1-500, "duration_sec": 0.5-30}, haste {"factor": 1.05-2.5, "duration_sec": 0.5-30} (movement speed only), restrained {"duration_sec": 0.5-10} (speed 0, can act, can be shoved), prone {"force": 1-30, "duration_sec": 0.5-10} (knockdown + speed 0), sleep {"duration_sec": 0.5-30} (wakes on damage), confusion {"force": 1-10, "duration_sec": 0.5-30} (random stumbles), blind {"factor": 0.05-1.0, "duration_sec": 0.5-30} (accuracy disruption), weaken {"factor": 0.05-1.0, "duration_sec": 0.5-30} (damage dealt reduced), exhaustion {"duration_sec": 0.5-60} (+1 level per application, 6 = death), typed_damage {"damage_type": "acid"|"cold"|"fire"|"lightning"|"necrotic"|"poison"|"psychic"|"radiant"|"thunder", "amount": 1-500, "duration_sec": 0.5-30} (instant damage + rider), shield {"amount": 1-500, "duration_sec": 0.5-30} (absorbing pool — eats incoming damage first), vulnerable {"factor": 1.05-5.0, "duration_sec": 0.5-30} (incoming damage multiplied — mark a target so FOLLOW-UP hits deal more), thorns {"reflect_mult": 0.0-2.0, "duration_sec": 0.5-30} (reflects a share of damage actually taken back to the attacker), petrified {"duration_sec": 0.5-30} (nullifies ALL incoming damage + pins the target; constructs + elementals are immune). Shield / vulnerable / thorns / petrified are DAMAGE-INTERCEPTION states: they matter through the take_damage interception — apply them on a take_damage hook (they affect THIS hit) or on_hit (they affect the hit target for FOLLOW-UP hits). Status kinds need a target — never on a fire point. Do NOT invent other kinds (stunned/paralyzed/unconscious/grappled/frightened/charmed/deafened/silence/lifesteal/curse are NOT kinds).
- spawn_projectile(spec: Dictionary, origin: Vector3, direction: Vector3, hooks: Array = []) -> Node — flying mod projectile travelling along direction; spec carries visual / speed / damage / explodes_on_impact.
- get_creature_type(target: Node) -> String — the target's D&D creature type ("" for targets without one). Branch on it: don't waste poison on a construct.
- is_creature_immune_to_status(target: Node, kind: String) -> bool — true when the target's creature type is immune to the 5e condition the status kind expresses.
- get_ability_modifier(target: Node, ability: String) -> int — the target's ability modifier for STR/DEX/CON/INT/WIS/CHA (10 = +0); 0 for targets without a stat block.
MODBLOCK CONTRACT — every script mod MUST follow this exactly:
- First line: `extends ModBlock` (exactly, nothing else on that line).
- Implement `get_block_info() -> Dictionary` returning {"block_id": "<lowercase [a-z0-9_]>", "target": "weapon"|"cover"|"structure"|"turret"|"pickup", "cost": 0-2000, "display_name": "<name>", "description": "<one line>", ...per-target fields...}.
- Implement `apply(api: ModAPI, params: Dictionary) -> String`: build via ONLY the ModAPI methods above; return a non-empty success message, or "" on failure. params carries "_position" (Vector3 build point) and "_target" (the spec target). _init() must stay side-effect free — all building in apply().
- NEVER emit filesystem, network, OS, eval, or code-loading code: NO FileAccess, DirAccess, OS, Engine, load(), preload(), ResourceLoader, Expression, GDScript.new, ClassDB, HTTPRequest, HTTPClient, sockets, Thread, .new(), call(), call_deferred(), @tool. The game rejects any mod containing them. A script mod runs with game trust — only ModAPI, full stop.
MANIFEST SCHEMA: {"name": str (non-empty), "kind": "block"|"script", "version": str (e.g. "1.0"), "description": str (max 300 chars)}.
BLOCK SCHEMA (payload for kind=block): the payload is EITHER a wrapper {\"block\": {...}, \"hooks\": [...]} (canonical) OR a flat block object {\"block_id\": ..., \"hooks\": [...]}. The \"hooks\" array ALWAYS lives OUTSIDE the \"block\" object, next to it — NEVER put \"hooks\" inside the \"block\" object. The block object is {\"block_id\": \"<lowercase [a-z0-9_]>\", \"target\": \"weapon\"|\"cover\"|\"structure\"|\"turret\"|\"pickup\", \"cost\": 0-2000 int, \"display_name\": str, \"description\": str?, ...per-target fields...}. Per-target fields: weapon: base_weapon_id (manticore|longeye|breacher|hornet|p9|raptor|lmg|trident|judge), damage_mult 0.1-5, mag_mult 0.25-4, range_mult 0.1-5, ammo_type? (standard|sniper|armor_piercing|buckshot), fire_mode? (auto|semi|burst|bolt|pump — default auto; a 3-round burst = fire_mode burst + burst_size 3), burst_size? (2-10, only with fire_mode burst). cover: shape wall|tower|barricade, size_voxels [x,y,z] each 1-12, hp 50-500, property? standard|reinforced, color? (palette name or "#rrggbb"). structure: shape bridge|bunker|watchtower|ammo_depot|stairs|ramp|wall|jump_pad|cover_piece|sniper_nest, property? standard|reinforced. turret: duration_sec 5-120, damage_mult 0.1-5, range_mult 0.1-3, ammo_type?. pickup: kind ammo|health, amount 1-500. No other fields inside the block object — unknown fields are rejected.
Examples:
Player idea: "a chunky concrete wall" -> {"manifest": {"name": "Chunky Wall", "kind": "block", "version": "1.0", "description": "A thick concrete wall."}, "payload": "{\\"block_id\\": \\"chunky_wall\\", \\"target\\": \\"cover\\", \\"cost\\": 150, \\"display_name\\": \\"Chunky Wall\\", \\"description\\": \\"A thick concrete wall.\\", \\"shape\\": \\"wall\\", \\"size_voxels\\": [8, 6, 3], \\"hp\\": 500}", "summary": "A thick concrete wall with 500 HP for 150."}
Player idea: "a beacon that drops a glowing marker where I'm looking" -> {"manifest": {"name": "Aim Beacon", "kind": "script", "version": "1.0", "description": "Drops a glowing marker at the aim point."}, "payload": "extends ModBlock\\n\\nfunc get_block_info() -> Dictionary:\\n\\treturn {\\"block_id\\": \\"aim_beacon\\", \\"target\\": \\"cover\\", \\"cost\\": 100, \\"display_name\\": \\"Aim Beacon\\", \\"description\\": \\"Drops a glowing marker at the aim point.\\", \\"shape\\": \\"wall\\", \\"size_voxels\\": [1, 1, 1], \\"hp\\": 100.0}\\n\\nfunc apply(api: ModAPI, params: Dictionary) -> String:\\n\\tvar at: Vector3 = params.get(\\"_position\\", Vector3.ZERO)\\n\\tvar node: Node3D = api.spawn_voxel_box(Vector3(1, 1, 1), Color(1, 0.8, 0), at, false)\\n\\tif node == null:\\n\\t\\treturn \\"\\"\\n\\tapi.announce(\\"Beacon\\", \\"Marker placed.\\")\\n\\treturn \\"Forge fabricated: Aim Beacon (mod).\\"\\n", "summary": "Drops a glowing marker at your aim point."}
D&D CREATURE TYPES + ABILITY SCORES (v0.5.8 — for mods about creatures/enemies; do NOT invent block fields for these — the block schema above has no creature_type / ability-score field, so name the type and scores in the description/summary text only):
- All 14 types: aberration, beast, celestial, construct, dragon, elemental, fey, fiend, giant, humanoid, monstrosity, ooze, plant, undead. Every enemy in the game carries one (default humanoid for militia) and the game ENFORCES the enforced rows below.
- Enforced immunities (real in-game): construct — immune poison + psychic damage, immune to poisoned/sleep/exhaustion; undead — immune poison damage, immune to poisoned/sleep/exhaustion; elemental — immune poison damage, immune to poisoned/sleep/exhaustion/restrained/prone; fiend — immune poison damage, RESIST cold/fire/lightning, immune to poisoned; ooze — RESIST acid, immune to exhaustion/prone; celestial — RESIST radiant/necrotic, immune to exhaustion; fey — immune to sleep (magical sleep); plant — immune to exhaustion; aberration — RESIST psychic. Beast, dragon, giant, humanoid, monstrosity have NO blanket immunities (dragon immunity varies by ancestry — never guess one). No type is vulnerable to anything (never invent a vulnerability, e.g. undead are NOT vulnerable to radiant). Charmed/frightened/paralyzed/petrified/deafened/grappled immunities are real 5e traits but LORE-ONLY (no game mechanic) — never write a mod that depends on them.
- Status-effect kinds are gated by these immunities: a poison hook does NOTHING to a construct/undead, sleep never lands on undead, exhaustion never lands on a construct. Do not write a mod whose whole point is poisoning an undead — it will do nothing; say so in the summary.
- ABILITY SCORES: STR (Strength), DEX (Dexterity), CON (Constitution), INT (Intelligence), WIS (Wisdom), CHA (Charisma). Scores 1-30, 10 = average. Modifier = floor((score-10)/2): 10 -> +0, 16 -> +3, 8 -> -1. A class grants bonuses by adding to scores (e.g. +2 STR). When a mod idea names scores ("a brutish strong brute"), put the scores in the description/summary text (e.g. "STR 19") — never as invented block fields.
Rules: numbers must stay in the ranges above; never invent a ModAPI method, block field, or target; summary max 300 chars. If the idea cannot be expressed with ModAPI / the block schema, emit the closest buildable mod and say so in the summary — never emit code the game rejects, never leave the output malformed.
SPELL SCHOOLS — TAG ONLY: if the idea is spell-like (a fireball, a ward, a charm, a summoned thing...), set top-level "spell_school" to exactly ONE of: abjuration (protective magic — wards, shields, banishment), conjuration (summoning and calling), divination (knowledge — revealing, sensing, foresight), enchantment (mind magic — charm, compulsion), evocation (raw energy — fire, lightning, force), illusion (deception — phantasms, false sense), necromancy (life and death — draining, undeath), transmutation (change — altering form, matter, properties). For non-spell mods (a wall, a rifle, a turret) OMIT "spell_school" entirely — never tag a non-spell mod. The school is a TAG ONLY: it never changes mechanics (no damage bonus, no cost change, no behavior change, no spell slots, no skills/feats). It shows in approval + mod info. NEVER put "spell_school" inside the block object (the loader rejects unknown block fields) or inside the manifest — it lives ONLY as the top-level generation field; the game persists it into the payload on install."""


var _generation_in_flight := false
var _generation_http_outstanding := false
var _generation_queue: Array = []


## Starts a generation request. The result arrives via generation_ready
## as {manifest, payload, summary} or {error}. One request at a time per
## instance — a concurrent call gets an {"error": ...} result instead of
## disturbing the in-flight request (and never touches spec_ready).
func request_generation(idea: String) -> void:
	if _generation_in_flight:
		_queue_generation({"error": "generation already in progress"})
		return
	_generation_in_flight = true
	var key := ForgeConfig.load_key()
	if key.is_empty():
		_queue_generation({"error": "DeepSeek key required — add it in the Forge menu"})
		return
	_generation_http_outstanding = true
	_request_generation_remote(idea, key)


func _request_generation_remote(idea: String, key: String) -> void:
	# CACHE LAYOUT: messages[0] is the stable GENERATION_SYSTEM_PROMPT
	# (byte-identical every call); messages[1] carries ALL variable
	# content, with the user idea LAST.
	var body := {
		"model": MODEL,
		"messages": [
			{"role": "system", "content": GENERATION_SYSTEM_PROMPT},
			{"role": "user", "content": "Create a mod: %s" % idea},
		],
		"response_format": {"type": "json_object"},
		"temperature": TEMPERATURE,
		"max_tokens": GENERATION_MAX_TOKENS,
		# Thinking mode is ON by default on deepseek-flash and bills
		# reasoning tokens as output. Same call shape as the build path.
		"thinking": {"type": "disabled"},
	}
	var http := HTTPRequest.new()
	http.timeout = HTTP_TIMEOUT_SEC
	add_child(http)
	http.request_completed.connect(_on_generation_http_completed.bind(http))
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + key,
	])
	var err := http.request(API_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		push_warning("ForgeLLM: generation HTTPRequest failed to start (%s)." % error_string(err))
		http.queue_free()
		_generation_http_outstanding = false
		_queue_generation({"error": "generation request failed to start"})


func _on_generation_http_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	var text := ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		text = body.get_string_from_utf8()
	http.queue_free()
	_generation_http_outstanding = false
	var gen := _extract_generation(text)
	if gen.is_empty():
		if result != HTTPRequest.RESULT_SUCCESS:
			push_warning("ForgeLLM: generation request failed (result=%d, http=%d)." % [result, code])
		else:
			push_warning("ForgeLLM: generation returned bad JSON.")
		gen = {"error": "generation returned invalid JSON"}
	_queue_generation(gen)


## Pulls the generation object out of a chat-completions response envelope.
## Returns {} unless the payload has a manifest object + string payload +
## string summary. Full validation happens in ModCreator / ModLoader.
func _extract_generation(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {}
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return {}
	var choices: Array = (data as Dictionary).get("choices", [])
	if choices.is_empty() or not (choices[0] is Dictionary):
		return {}
	var msg: Dictionary = (choices[0] as Dictionary).get("message", {})
	var content := _strip_fences(str(msg.get("content", "")).strip_edges())
	var gen: Variant = JSON.parse_string(content)
	if not (gen is Dictionary):
		return {}
	var d := gen as Dictionary
	if not (d.has("manifest") and d["manifest"] is Dictionary):
		return {}
	if not (d.has("payload") and d["payload"] is String):
		return {}
	if not (d.has("summary") and d["summary"] is String):
		return {}
	# v0.5.8 spell schools: the generation object may carry a
	# top-level "spell_school" tag. Normalized here (unknown -> "");
	# an invalid school never rejects the generation.
	var school := SpellSchools.normalize(str(d.get("spell_school", "")))
	return {"manifest": d["manifest"], "payload": str(d["payload"]), "summary": str(d["summary"]), "spell_school": school}


func _queue_generation(result: Dictionary) -> void:
	_generation_queue.append(result)
	call_deferred("_emit_generation")


func _emit_generation() -> void:
	if _generation_queue.is_empty():
		return
	var result: Dictionary = _generation_queue.pop_front()
	generation_ready.emit(result)
	if _generation_queue.is_empty() and not _generation_http_outstanding:
		_generation_in_flight = false
	elif not _generation_queue.is_empty():
		call_deferred("_emit_generation")
