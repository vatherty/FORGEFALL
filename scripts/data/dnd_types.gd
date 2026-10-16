# FORGEFALL — DnDTypes (v0.5.8, Worker A: D&D 5e creature types + ability scores)
#
# The SINGLE source of truth for:
#   1. All 14 D&D 5e creature types + their resistance / immunity tables.
#   2. The six ability scores (STR/DEX/CON/INT/WIS/CHA) — stat-block
#      structure, getters, modifiers. WORKER B (classes) consumes this
#      read-only: a class grants bonuses by writing into a character's
#      ability_scores dict (see ability_scores() / with_bonus()).
#
# AUTHENTICITY RULE (Colin's standing rule: no prose-only tags, no fakes):
# In 5e, immunities are per-MONSTER, not per-type — the Monster Manual
# gives no blanket per-type immunity list. The tables below are the
# MM-typical traits for each type (the traits shared by the overwhelming
# majority of that type's stat blocks, e.g. golems for construct, oozes
# for ooze, angels for celestial). Where NO blanket trait exists the
# table is honestly EMPTY (beast, dragon, giant, humanoid, monstrosity)
# with a note saying why, instead of an invented immunity. A dragon's
# damage immunity varies by ancestry (red = fire, white = cold, ...) —
# there is no single dragon table, so dragon ships empty and an
# ancestry variant is a documented follow-up, not a guessed row.
#
# ENFORCEMENT (every enforced row is real, in EnemyBase):
# - Damage types: EnemyBase.take_typed_damage() multiplies by
#   damage_multiplier() (immune = 0x, resist = 0.5x, vulnerable = 2x)
#   and routes through take_damage(). Plain take_damage() is UNTYPED
#   (hitscan / explosions) and applies no multiplier — existing
#   weapons are unchanged.
# - Conditions: STATUS_CONDITION_MAP maps each game status kind to the
#   5e condition it expresses. EnemyBase.apply_status_effect() refuses
#   kinds whose condition the creature is immune to, and EnemyBase's
#   per-tick sweep clears any such effect that arrived through another
#   path (e.g. a mod hook calling ModStatusEffects directly), BEFORE a
#   1-second DOT tick can fire — so poison on a construct/undead deals
#   0 damage, and sleep on an undead never pins it.
# - UNENFORCED conditions: several 5e conditions have NO game mechanic
#   (charmed: no faction/AI-targeting hook; frightened: no steering
#   hook; paralyzed/petrified/stunned: no act-blocking hook; deafened:
#   no hearing system; grappled/incapacitated: no grapple system).
#   They are listed in the tables as lore (condition_immunities) and
#   split out by enforced_condition_immunities() /
#   unenforced_condition_immunities() — NEVER faked by renaming another
#   effect (e.g. freeze is NOT "paralyzed renamed": freeze stays freeze
#   and is NOT blocked by paralyzed immunity). See "DELIBERATE OMISSIONS".
#
# DELIBERATE OMISSIONS (don't-fake-it):
# - Charm/fear/paralysis/petrification/stun: no mechanic, no fake.
# - Per-type VULNERABILITIES: 5e has almost no blanket per-type
#   vulnerability (undead are NOT broadly vulnerable to radiant; plants
#   are NOT broadly vulnerable to fire — those are per-monster). All
#   vulnerability lists are empty; none invented.
# - Damage-type resistance for DOTs applied via ModStatusEffects
#   (burn/poison ticks call untyped take_damage): the typed-damage
#   channel does not reach them. The status-kind sweep covers the
#   immunity cases (poison kind vs poison immunity = 0 damage); a
#   RESIST-only case (e.g. burn DOT on a fire-resistant fiend) still
#   deals full damage — documented gap, coordinator follow-up: thread a
#   damage_type through ModStatusEffects._damage_target (mod file,
#   off-limits to this worker).
# - Exhaustion level-6 death: ModStatusEffects applies the lethal
#   damage IMMEDIATELY on the 6th stack, so a single-frame 6-stack
#   burst on an exhaustion-immune creature can kill before EnemyBase's
#   sweep runs. The wrapper (EnemyBase.apply_status_effect) blocks it;
#   the direct-ModStatusEffects path is the one-line coordinator
#   follow-up (gate apply_status on DnDTypes.is_status_immune).
#
# PROMPT CATALOG: ForgeLLM.SYSTEM_PROMPT (Forge build path) and
# GENERATION_SYSTEM_PROMPT (mod creation) + ModCreator.HOOK_PROMPT_ADDENDUM
# list all 14 types + their enforced immunities + the ability scores.
# Those prompt sections are generated from THESE tables by hand — keep
# them in sync when this file changes.
extends RefCounted
class_name DnDTypes

## All 14 D&D 5e creature types, in Monster Manual order.
const CREATURE_TYPE_IDS := ["aberration", "beast", "celestial", "construct",
	"dragon", "elemental", "fey", "fiend", "giant", "humanoid",
	"monstrosity", "ooze", "plant", "undead"]

## D&D damage types the typed-damage channel knows. Physical types
## (bludgeoning/piercing/slashing) are accepted by take_typed_damage()
## but have no per-type multiplier — no type resists plain weapon hits.
const DAMAGE_TYPES := ["acid", "cold", "fire", "lightning", "necrotic",
	"poison", "psychic", "radiant", "thunder"]

## The six ability scores, in PHB order.
const ABILITY_IDS := ["str", "dex", "con", "int", "wis", "cha"]

const ABILITY_NAMES := {
	"str": "Strength", "dex": "Dexterity", "con": "Constitution",
	"int": "Intelligence", "wis": "Wisdom", "cha": "Charisma",
}

## Game status kind -> 5e condition it expresses. ONLY kinds with a
## genuine 5e condition land here. freeze is NOT paralyzed (freeze is
## its own kind: encased, damage does not break it); confusion is NOT
## charmed (no faction change); slow is NOT a condition (no 5e
## equivalent). Unmapped kinds are never immunity-gated.
const STATUS_CONDITION_MAP := {
	"poison": "poisoned",
	"sleep": "sleep",
	"exhaustion": "exhaustion",
	"blind": "blinded",
	"restrained": "restrained",
	"prone": "prone",
	"petrified": "petrified",
}

## Per-type table. Keys: display_name, blurb, damage_immunities,
## damage_resistances, damage_vulnerabilities, condition_immunities,
## note. "sleep" in condition_immunities is the magical-sleep exclusion
## (sleep spell: undead + charm-immune creatures unaffected; fey
## ancestry: immune to magical sleep). Elemental's "unconscious"
## covers sleep too (sleep kind maps to BOTH sleep and unconscious —
## see status_conditions_for_kind).
const CREATURE_TYPES := {
	"aberration": {
		"display_name": "Aberration",
		"blurb": "Alien minds from beyond — mind flayers, beholders, aboleths.",
		"damage_immunities": [],
		"damage_resistances": ["psychic"],
		"damage_vulnerabilities": [],
		"condition_immunities": [],
		"note": "Psychic resistance is the shared aberration trait; charm/fear vary by monster, no blanket condition immunity.",
	},
	"beast": {
		"display_name": "Beast",
		"blurb": "Natural animals — wolves, bears, giant spiders.",
		"damage_immunities": [],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": [],
		"note": "Beasts have no blanket immunities — the baseline type.",
	},
	"celestial": {
		"display_name": "Celestial",
		"blurb": "Angels and beings of the Upper Planes.",
		"damage_immunities": [],
		"damage_resistances": ["radiant", "necrotic"],
		"damage_vulnerabilities": [],
		"condition_immunities": ["charmed", "exhaustion", "frightened"],
		"note": "Angel trait (deva/planetar/solar): radiant + necrotic resistance, immune to charm/exhaustion/fear.",
	},
	"construct": {
		"display_name": "Construct",
		"blurb": "Built, not born — golems, animated armor, shield guardians.",
		"damage_immunities": ["poison", "psychic"],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": ["charmed", "exhaustion", "frightened", "paralyzed", "petrified", "poisoned", "sleep"],
		"note": "Golem trait: no mind to poison or psychically assault, no body to exhaust; charm-immune, so the sleep spell cannot touch it either.",
	},
	"dragon": {
		"display_name": "Dragon",
		"blurb": "Chromatic and metallic dragons.",
		"damage_immunities": [],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": [],
		"note": "A dragon's damage immunity varies by ancestry (red = fire, white = cold, blue = lightning, ...) — no single dragon table exists. Ancestry variants are a follow-up, not a guessed row.",
	},
	"elemental": {
		"display_name": "Elemental",
		"blurb": "Living air, earth, fire, and water.",
		"damage_immunities": ["poison"],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": ["exhaustion", "grappled", "paralyzed", "petrified", "poisoned", "prone", "restrained", "sleep", "unconscious"],
		"note": "Air/earth elemental trait: no biology to poison, exhaust, or knock down; no mind to sleep.",
	},
	"fey": {
		"display_name": "Fey",
		"blurb": "Creatures of the Feywild — sprites, hags, eladrin.",
		"damage_immunities": [],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": ["sleep"],
		"note": "Fey ancestry: immune to magical sleep (the elf trait, generalized to the type). Charm is advantage, NOT immunity — not faked as one.",
	},
	"fiend": {
		"display_name": "Fiend",
		"blurb": "Demons and devils of the Lower Planes.",
		"damage_immunities": ["poison"],
		"damage_resistances": ["cold", "fire", "lightning"],
		"damage_vulnerabilities": [],
		"condition_immunities": ["poisoned"],
		"note": "Demon/devil trait: poison-immune, cold/fire/lightning-resistant. Devils' full fire immunity is folded to resistance here (conservative — the shared fiend trait is resistance).",
	},
	"giant": {
		"display_name": "Giant",
		"blurb": "Hill, stone, frost, fire, cloud, and storm giants.",
		"damage_immunities": [],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": [],
		"note": "Giants have no blanket immunities — their toughness is hit points, not a type trait.",
	},
	"humanoid": {
		"display_name": "Humanoid",
		"blurb": "People — soldiers, bandits, cultists, townsfolk. The default.",
		"damage_immunities": [],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": [],
		"note": "Humanoids have no blanket immunities — the baseline type. Every existing FORGEFALL enemy is humanoid (militia).",
	},
	"monstrosity": {
		"display_name": "Monstrosity",
		"blurb": "Owlbears, griffons, mimics, purple worms.",
		"damage_immunities": [],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": [],
		"note": "Monstrosities vary by monster — no blanket trait exists.",
	},
	"ooze": {
		"display_name": "Ooze",
		"blurb": "Gelatinous cubes, black puddings, gray oozes.",
		"damage_immunities": [],
		"damage_resistances": ["acid"],
		"damage_vulnerabilities": [],
		"condition_immunities": ["blinded", "charmed", "deafened", "exhaustion", "frightened", "prone"],
		"note": "Ooze trait: acid-resistant (black puddings are fully acid-immune — the shared type trait is resistance), no eyes/ears/mind to blind, deafen, charm, frighten, exhaust, or knock prone.",
	},
	"plant": {
		"display_name": "Plant",
		"blurb": "Shambling mounds, treants, awakened shrubs.",
		"damage_immunities": [],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": ["blinded", "deafened", "exhaustion", "frightened"],
		"note": "Plant trait: no eyes/ears to blind or deafen, no mind to frighten, no stamina to exhaust. Lightning/fire traits vary by monster (shambling mound vs treant) — not a blanket row.",
	},
	"undead": {
		"display_name": "Undead",
		"blurb": "Skeletons, zombies, ghosts, vampires — dead, still moving.",
		"damage_immunities": ["poison"],
		"damage_resistances": [],
		"damage_vulnerabilities": [],
		"condition_immunities": ["exhaustion", "poisoned", "sleep"],
		"note": "Undead trait: poison cannot harm what is already dead; no stamina to exhaust; the sleep spell cannot touch the dead. Charm/fear/paralysis vary by monster (ghost vs skeleton) — not blanket rows.",
	},
}


## True when `t` is one of the 14 creature types.
static func is_creature_type(t: String) -> bool:
	return str(t) in CREATURE_TYPES


## Full table row for `t` (duplicated). {} when unknown.
static func creature_info(t: String) -> Dictionary:
	var row: Variant = CREATURE_TYPES.get(str(t), {})
	if row is Dictionary:
		return (row as Dictionary).duplicate(true)
	return {}


## Display name ("Undead") for a type id ("undead"). Falls back to the id.
static func creature_display_name(t: String) -> String:
	var row := creature_info(t)
	if row.is_empty():
		return str(t)
	return str(row.get("display_name", t))


## Damage multiplier for `damage_type` against creature type `t`:
## 0.0 immune, 0.5 resistant, 2.0 vulnerable, 1.0 otherwise.
## Unknown type or unknown damage type -> 1.0 (no table, no effect).
static func damage_multiplier(creature_type: String, damage_type: String) -> float:
	var row := creature_info(creature_type)
	if row.is_empty():
		return 1.0
	var dt := str(damage_type).to_lower()
	if dt in (row.get("damage_immunities", []) as Array):
		return 0.0
	if dt in (row.get("damage_resistances", []) as Array):
		return 0.5
	if dt in (row.get("damage_vulnerabilities", []) as Array):
		return 2.0
	return 1.0


## True when creature type `t` is immune to damage type `dt`.
static func is_damage_immune(creature_type: String, damage_type: String) -> bool:
	return damage_multiplier(creature_type, damage_type) == 0.0


## The 5e condition(s) a game status kind expresses. Sleep maps to
## BOTH "sleep" (magical-sleep exclusion) and "unconscious" (an
## elemental is immune to sleep because it cannot be unconscious).
## [] when the kind expresses no 5e condition (never immunity-gated).
static func status_conditions_for_kind(kind: String) -> Array:
	match str(kind):
		"sleep":
			return ["sleep", "unconscious"]
		_:
			var c: Variant = STATUS_CONDITION_MAP.get(str(kind), "")
			if str(c).is_empty():
				return []
			return [str(c)]


## True when creature type `t` is immune to game status kind `kind`
## (via the 5e condition that kind expresses). False for kinds with
## no 5e condition, and for unknown types.
static func is_status_immune(creature_type: String, kind: String) -> bool:
	var row := creature_info(creature_type)
	if row.is_empty():
		return false
	var conds := (row.get("condition_immunities", []) as Array)
	for c in status_conditions_for_kind(kind):
		if str(c) in conds:
			return true
	return false


## Condition immunities of `t` that the game ENFORCES (the condition
## has a status kind that maps to it: poisoned/sleep/exhaustion/
## blinded/restrained/prone). Lore-only immunities are NOT here.
static func enforced_condition_immunities(creature_type: String) -> Array:
	var row := creature_info(creature_type)
	if row.is_empty():
		return []
	var out: Array = []
	var enforced: Array = ["poisoned", "sleep", "unconscious", "exhaustion", "blinded", "restrained", "prone"]
	for c in (row.get("condition_immunities", []) as Array):
		if str(c) in enforced:
			out.append(str(c))
	return out


## Condition immunities of `t` that are LORE ONLY — real 5e traits
## with no game mechanic (charmed/frightened/paralyzed/petrified/
## deafened/grappled). Listed for the prompt catalog and info display,
## never claimed as enforced.
static func unenforced_condition_immunities(creature_type: String) -> Array:
	var row := creature_info(creature_type)
	if row.is_empty():
		return []
	var out: Array = []
	var enforced: Array = ["poisoned", "sleep", "unconscious", "exhaustion", "blinded", "restrained", "prone"]
	for c in (row.get("condition_immunities", []) as Array):
		if not (str(c) in enforced):
			out.append(str(c))
	return out


## One-line summary of a type's ENFORCED table, for info display and
## the prompt catalog. "no enforced immunities" when the enforced set
## is empty (the type still has its lore rows in the full table).
static func type_summary(t: String) -> String:
	var row := creature_info(t)
	if row.is_empty():
		return "unknown creature type '%s'" % str(t)
	var parts: Array[String] = []
	var di := row.get("damage_immunities", []) as Array
	var dr := row.get("damage_resistances", []) as Array
	var dv := row.get("damage_vulnerabilities", []) as Array
	var ec := enforced_condition_immunities(t)
	if not di.is_empty():
		parts.append("immune: " + ", ".join(PackedStringArray(di)))
	if not dr.is_empty():
		parts.append("resist: " + ", ".join(PackedStringArray(dr)))
	if not dv.is_empty():
		parts.append("vulnerable: " + ", ".join(PackedStringArray(dv)))
	if not ec.is_empty():
		parts.append("immune to: " + ", ".join(PackedStringArray(ec)))
	if parts.is_empty():
		return "%s — no enforced immunities" % str(row.get("display_name", t))
	return "%s — %s" % [str(row.get("display_name", t)), "; ".join(parts)]


# --- Ability scores ---------------------------------------------------------
# A stat block is a Dictionary {"str": int, "dex": int, "con": int,
# "int": int, "wis": int, "cha": int}, scores 1-30 (5e range; 10 is an
# average human). Characters carry one on `ability_scores` (EnemyBase;
# the player/class side is WORKER B's). Scores are DATA: nothing in
# this file turns a score into game behaviour — the score's meaning is
# defined where it is consumed (e.g. a class grants +2 STR by writing
# the score, and the class system reads the modifier). What IS defined
# here: the structure, the modifier formula, getters, and formatting.

const ABILITY_MIN := 1
const ABILITY_MAX := 30
const ABILITY_DEFAULT := 10


## Fresh default stat block: all 10s.
static func default_ability_scores() -> Dictionary:
	return {"str": 10, "dex": 10, "con": 10, "int": 10, "wis": 10, "cha": 10}


## Stat block from six scores (clamped to 1-30). Missing args default 10.
static func ability_scores(str_v: int = 10, dex_v: int = 10, con_v: int = 10, int_v: int = 10, wis_v: int = 10, cha_v: int = 10) -> Dictionary:
	return {
		"str": clampi(str_v, ABILITY_MIN, ABILITY_MAX),
		"dex": clampi(dex_v, ABILITY_MIN, ABILITY_MAX),
		"con": clampi(con_v, ABILITY_MIN, ABILITY_MAX),
		"int": clampi(int_v, ABILITY_MIN, ABILITY_MAX),
		"wis": clampi(wis_v, ABILITY_MIN, ABILITY_MAX),
		"cha": clampi(cha_v, ABILITY_MIN, ABILITY_MAX),
	}


## Normalizes any dict into a full stat block: unknown/missing keys get
## 10, out-of-range values clamp to 1-30. Never fails — always returns
## a complete block.
static func normalize_ability_scores(block: Variant) -> Dictionary:
	var out := default_ability_scores()
	if block is Dictionary:
		for a in ABILITY_IDS:
			var v: Variant = (block as Dictionary).get(a, ABILITY_DEFAULT)
			if v is int or v is float:
				out[a] = clampi(int(v), ABILITY_MIN, ABILITY_MAX)
	return out


## The 5e modifier: floor((score - 10) / 2). 10 -> 0, 16 -> +3, 8 -> -1.
## Godot int division truncates toward zero, so the floor is done on a
## float (else 9 -> 0 instead of -1).
static func ability_modifier(score: int) -> int:
	return int(floor((float(score) - 10.0) / 2.0))


## Score of `ability` ("str"|"dex"|...) in `block`. 10 when missing/unknown.
static func get_ability(block: Dictionary, ability: String) -> int:
	var norm := normalize_ability_scores(block)
	return int(norm.get(str(ability).to_lower(), ABILITY_DEFAULT))


## Modifier of `ability` in `block`.
static func get_ability_modifier(block: Dictionary, ability: String) -> int:
	return ability_modifier(get_ability(block, ability))


## New block = `block` with `bonus` added to `ability` (clamped 1-30).
## The class-system primitive: "class grants +2 STR" is
## with_bonus(block, "str", 2). Never mutates the input.
static func with_bonus(block: Dictionary, ability: String, bonus: int) -> Dictionary:
	var out := normalize_ability_scores(block)
	var a := str(ability).to_lower()
	if a in ABILITY_IDS:
		out[a] = clampi(int(out[a]) + bonus, ABILITY_MIN, ABILITY_MAX)
	return out


## "STR 16 (+3)  DEX 12 (+1)  ..." — the character-info line.
static func format_stat_block(block: Dictionary) -> String:
	var norm := normalize_ability_scores(block)
	var parts: Array[String] = []
	for a in ABILITY_IDS:
		var s := int(norm[a])
		var m := ability_modifier(s)
		var sign := "+" if m >= 0 else ""
		parts.append("%s %d (%s%d)" % [a.to_upper(), s, sign, m])
	return "  ".join(parts)
