# scripts/progression/classes.gd
# FORGEFALL — D&D 5e character classes (v0.5.8, Worker B).
#
# The player has ONE active class. Every class is a data definition:
# 2-4 REAL modifiers the game applies at the exact choke points where
# the value is used (player.gd regen / speed / jump / wall-run / heal /
# take_damage, weapon_base.gd hitscan damage + crit, forge_manager.gd
# Forge cooldown). NOTHING here is prose-only: if a modifier cannot be
# applied by real code it is cut and documented (see DEFERRED below).
#
# SWAP: Player.set_player_class(id) swaps mid-match — the old kit is
# dropped (all multipliers are read live from active_class_id, never
# cached) and the new kit applies on the next tick, no restart. HP
# keeps its FRACTION across the swap, so swapping can neither heal nor
# hurt. Entry points: Forge prompt ("make me a rogue" -> ModSpec
# modify/class, executed by ForgeManager) and the Forge menu CLASS tab
# (direct set_player_class call). The active class persists to
# user://player_class.json and is restored on spawn.
#
# ABILITY SCORES (Worker A's DnDTypes is the single source of truth,
# consumed READ-ONLY): each class carries raw ability BONUSES
# (+2 STR etc.) keyed by DnDTypes' lowercase ids ("str", "dex", ...).
# The player's EFFECTIVE stat block is base (all 10s) + class bonuses,
# computed with DnDTypes.with_bonus() — the canonical "class grants
# +2 STR" primitive — and read through DnDTypes.get_ability_modifier()
# / format_stat_block(). This file defines NO modifier formula and NO
# competing stat system. Scores are DATA (DnDTypes' rule): nothing
# turns a score into game behaviour. The class kit (mods below) is
# separate and applied directly — it does NOT derive anything from
# CON etc., so there is no double application. If a future system
# consumes the CON modifier for HP, it must reconcile with the kit's
# max_hp_mult (see BUILD_LOG).
#
# ENEMY CLASS TAG: enemies carry a class tag ONLY (a lookup, no
# behavior changes — scripts/enemies/* are untouched). Use
# enemy_class_tag(enemy_type) for display / Forge text, never for AI.
#
# DEFERRED (documented cuts, don't-fake-it rule):
# - Warlock lifesteal (heal on kill): there is no damage-dealt / kill
#   hook on the player (take_damage is incoming-only; kills are scored
#   in Game/enemy code). Warlock gets +damage / +healing instead.
# - Class damage / crit on MOD-PROJECTILE weapons: the class hook lives
#   in WeaponBase's hitscan path (the verified choke point for every
#   stock weapon). Mod-projectile damage is set at spawn from the mod
#   spec and bypasses the hook — a second hook there would duplicate
#   the choke point. Stock weapons all get the kit; mod projectiles
#   are a follow-up if the coordinator wants it.
# - No class changes enemy behavior, Forge build costs (budget is OFF;
#   costs are display-only), or weapon models (voxel recolor territory,
#   owned by camos). Wizard Forge affinity is real: Forge cooldown x0.5.
extends RefCounted
class_name PlayerClasses

const DnDTypes := preload("res://scripts/data/dnd_types.gd")

## Save file for the active class (restored on spawn).
const SAVE_PATH := "user://player_class.json"
## Default class for a fresh save.
const DEFAULT_CLASS := "fighter"

## All 12 D&D 5e class ids, in PHB order.
const CLASS_IDS: Array = [
	"barbarian", "bard", "cleric", "druid", "fighter", "monk",
	"paladin", "ranger", "rogue", "sorcerer", "warlock", "wizard",
]

## Prompt aliases -> class id ("mage" -> wizard, "thief" -> rogue, ...).
const ALIASES: Dictionary = {
	"barb": "barbarian",
	"priest": "cleric",
	"warrior": "fighter",
	"hunter": "ranger",
	"thief": "rogue",
	"mage": "wizard",
}

## Display names.
const DISPLAY_NAMES: Dictionary = {
	"barbarian": "Barbarian",
	"bard": "Bard",
	"cleric": "Cleric",
	"druid": "Druid",
	"fighter": "Fighter",
	"monk": "Monk",
	"paladin": "Paladin",
	"ranger": "Ranger",
	"rogue": "Rogue",
	"sorcerer": "Sorcerer",
	"warlock": "Warlock",
	"wizard": "Wizard",
}

## Defaults for every kit modifier. A class lists only what it changes.
const DEFAULT_MODS: Dictionary = {
	"max_hp_mult": 1.0,
	"damage_mult": 1.0,
	"damage_taken_mult": 1.0,
	# 0.0 = unused. When > 0, this REPLACES damage_taken_mult while
	# the player is crouching or sliding (rogue Sneak).
	"damage_taken_crouch_mult": 0.0,
	"speed_mult": 1.0,
	"crouch_speed_mult": 1.0,
	"jump_mult": 1.0,
	"wallrun_mult": 1.0,
	"regen_rate_mult": 1.0,
	"regen_delay_mult": 1.0,
	"heal_mult": 1.0,
	"crit_chance": 0.0,
	"crit_mult": 2.0,
	"forge_cooldown_mult": 1.0,
	"second_wind": false,
}

## Class definitions: {name, ability_bonuses, mods, tagline}.
## tagline states the REAL numbers — it is what the Forge prompt, the
## menu detail label, and the swap toast all show.
const CLASSES: Dictionary = {
	"barbarian": {
		"ability_bonuses": {"str": 2, "con": 2},
		"mods": {"max_hp_mult": 1.4, "damage_mult": 1.15, "damage_taken_mult": 0.75},
		"tagline": "+40% max HP, +15% damage dealt, take 25% less damage.",
	},
	"bard": {
		"ability_bonuses": {"cha": 2},
		"mods": {"heal_mult": 1.5, "regen_rate_mult": 1.5, "regen_delay_mult": 0.75, "damage_mult": 1.05, "speed_mult": 1.05},
		"tagline": "+50% healing received, +50% health regen, +5% damage, +5% move speed.",
	},
	"cleric": {
		"ability_bonuses": {"wis": 2},
		"mods": {"regen_rate_mult": 2.0, "regen_delay_mult": 0.5, "heal_mult": 1.5, "max_hp_mult": 1.1},
		"tagline": "Regen aura: 2x health regen, regen starts 2x sooner, +50% healing received, +10% max HP.",
	},
	"druid": {
		"ability_bonuses": {"wis": 2, "con": 1},
		"mods": {"max_hp_mult": 1.2, "damage_taken_mult": 0.85, "speed_mult": 1.1, "regen_rate_mult": 1.25},
		"tagline": "+20% max HP, take 15% less damage, +10% move speed, +25% regen.",
	},
	"fighter": {
		"ability_bonuses": {"str": 2, "con": 1},
		"mods": {"max_hp_mult": 1.25, "damage_mult": 1.1, "second_wind": true},
		"tagline": "+25% max HP, +10% damage, Second Wind (once per life: dropping to 30% HP restores 30% HP).",
	},
	"monk": {
		"ability_bonuses": {"dex": 2, "wis": 1},
		"mods": {"speed_mult": 1.15, "jump_mult": 1.1, "wallrun_mult": 1.5, "damage_mult": 1.05},
		"tagline": "+15% move speed, +10% jump, +50% wall-run time, +5% damage.",
	},
	"paladin": {
		"ability_bonuses": {"str": 2, "cha": 2},
		"mods": {"damage_mult": 1.15, "damage_taken_mult": 0.9, "heal_mult": 1.25, "max_hp_mult": 1.1},
		"tagline": "+15% damage, take 10% less damage, +25% healing received, +10% max HP.",
	},
	"ranger": {
		"ability_bonuses": {"dex": 2, "wis": 1},
		"mods": {"crit_chance": 0.10, "damage_mult": 1.05, "speed_mult": 1.08, "jump_mult": 1.05},
		"tagline": "+10% crit chance, +5% damage, +8% move speed, +5% jump.",
	},
	"rogue": {
		"ability_bonuses": {"dex": 2},
		"mods": {"crit_chance": 0.25, "crouch_speed_mult": 1.6, "damage_taken_crouch_mult": 0.85, "speed_mult": 1.05},
		"tagline": "+25% crit chance, +60% crouch speed, take 15% less damage while crouching, +5% move speed.",
	},
	"sorcerer": {
		"ability_bonuses": {"cha": 2},
		"mods": {"damage_mult": 1.2, "damage_taken_mult": 1.15, "regen_rate_mult": 1.5, "speed_mult": 1.05},
		"tagline": "+20% damage, +50% regen, +5% move speed, take 15% more damage.",
	},
	"warlock": {
		"ability_bonuses": {"cha": 2},
		"mods": {"damage_mult": 1.25, "damage_taken_mult": 1.1, "max_hp_mult": 0.85, "heal_mult": 1.25},
		"tagline": "+25% damage, +25% healing received, -15% max HP, take 10% more damage.",
	},
	"wizard": {
		"ability_bonuses": {"int": 2},
		"mods": {"damage_mult": 1.1, "damage_taken_mult": 1.2, "max_hp_mult": 0.85, "forge_cooldown_mult": 0.5},
		"tagline": "+10% damage, Forge cooldown halved, -15% max HP, take 20% more damage.",
	},
}

## Enemy type -> class TAG (display only, never behavior).
const ENEMY_CLASS_TAGS: Dictionary = {
	"grunt": "fighter",
	"rusher": "barbarian",
	"marksman": "ranger",
	"brute": "barbarian",
	"bulwark": "paladin",
	"shredder": "rogue",
	"suppressor": "wizard",
	"warlord": "warlock",
}


static func is_valid_class(class_id: String) -> bool:
	return str(class_id) in CLASSES


## "rogue" -> "Rogue". "" for unknown (never crashes on bad input).
static func display_name(class_id: String) -> String:
	return str(DISPLAY_NAMES.get(str(class_id), ""))


## Deep copy of one class definition ({} when unknown).
static func get_definition(class_id: String) -> Dictionary:
	if not is_valid_class(class_id):
		return {}
	return (CLASSES[str(class_id)] as Dictionary).duplicate(true)


## One kit modifier for a class (DEFAULT_MODS when the class doesn't
## list it, `default` when even the key is unknown).
static func get_mod(class_id: String, key: String, default: Variant = 1.0) -> Variant:
	var merged := DEFAULT_MODS.duplicate()
	if is_valid_class(class_id):
		var mods: Dictionary = (CLASSES[str(class_id)] as Dictionary).get("mods", {})
		for k in mods:
			merged[str(k)] = mods[k]
	if merged.has(key):
		return merged[key]
	return default


## Raw ability bonuses for a class (e.g. {"str": 2, "con": 2} —
## DnDTypes lowercase ids).
## DATA ONLY — Worker A's stat-block owns what a bonus means.
static func get_ability_bonuses(class_id: String) -> Dictionary:
	if not is_valid_class(class_id):
		return {}
	return ((CLASSES[str(class_id)] as Dictionary).get("ability_bonuses", {}) as Dictionary).duplicate()


## "BARBARIAN — +40% max HP, ... | Ability: +2 STR, +2 CON."
## Shown by the menu detail label and the swap toast.
static func summary(class_id: String) -> String:
	if not is_valid_class(class_id):
		return "Unknown class."
	var defn: Dictionary = CLASSES[str(class_id)]
	var tagline := str(defn.get("tagline", ""))
	var bonuses: Dictionary = defn.get("ability_bonuses", {})
	var parts: Array = []
	for ab in DnDTypes.ABILITY_IDS:
		if bonuses.has(ab):
			parts.append("+%d %s" % [int(bonuses[ab]), ab.to_upper()])
	var ability := "Ability: " + ", ".join(parts) if not parts.is_empty() else ""
	return "%s — %s | %s" % [display_name(class_id).to_upper(), tagline, ability]


## Prompt-catalog text: one line per class, for the Forge SYSTEM_PROMPT
## (the prompt itself carries a literal copy of this catalog — this
## function is the programmatic source verifiers/menus read).
static func prompt_catalog() -> String:
	var lines: Array = []
	for id in CLASS_IDS:
		lines.append("- %s: %s Ability %s." % [
			id, str((CLASSES[id] as Dictionary).get("tagline", "")),
			_ability_short(str(id))])
	return "\n".join(lines)


static func _ability_short(class_id: String) -> String:
	var bonuses: Dictionary = get_ability_bonuses(class_id)
	var parts: Array = []
	for ab in DnDTypes.ABILITY_IDS:
		if bonuses.has(ab):
			parts.append("+%d %s" % [int(bonuses[ab]), ab.to_upper()])
	return ", ".join(parts)


## Matches a class-swap intent in a lowercased Forge prompt.
## Accepts swap-verb phrases ("make me a rogue", "become a wizard",
## "switch to paladin", "class rogue") and a bare class name / alias
## ("rogue", "mage"). "" when no class intent. Checked by
## ForgeLLM._class_spec_for_prompt BEFORE any build branch, so a swap
## prompt can never fall through to a build.
static func match_in_prompt(p: String) -> String:
	var s := p.to_lower()
	var verbs: Array = []
	for base in ["make me", "become", "switch to", "change to", "turn into",
			"let me be", "i want to be", "play as"]:
		verbs.append(base + " ")
		verbs.append(base + " a ")
		verbs.append(base + " an ")
	verbs.append("change class to ")
	verbs.append("set class to ")
	verbs.append("class ")
	verbs.append("class: ")
	for id in CLASS_IDS:
		var names: Array = [id]
		for alias in ALIASES:
			if str(ALIASES[alias]) == id:
				names.append(str(alias))
		for verb in verbs:
			for nm in names:
				if s.contains(str(verb) + str(nm)):
					return id
	# Bare name / alias ("rogue", "mage").
	var t := s.strip_edges()
	for id in CLASS_IDS:
		if t == id:
			return id
		for alias in ALIASES:
			if t == str(alias) and str(ALIASES[alias]) == id:
				return id
	return ""


## Class tag for an enemy type ("" when the type has no tag).
## TAG ONLY — never feeds AI, stats, or spawning.
static func enemy_class_tag(enemy_type: String) -> String:
	return str(ENEMY_CLASS_TAGS.get(str(enemy_type).to_lower(), ""))


## Effective stat block = `base_block` + this class's bonuses, applied
## with DnDTypes.with_bonus() (Worker A's canonical primitive — this
## file never re-implements the bonus math). Never mutates the input.
## The player computes its block live from its base + active class, so
## a swap changes the block with no stored application step.
static func effective_ability_scores(base_block: Dictionary, class_id: String) -> Dictionary:
	var out := DnDTypes.normalize_ability_scores(base_block)
	for ab in DnDTypes.ABILITY_IDS:
		var bonus := int(get_ability_bonuses(class_id).get(ab, 0))
		if bonus != 0:
			out = DnDTypes.with_bonus(out, ab, bonus)
	return out


## Persists the active class. Never crashes on IO failure.
static func save_class(class_id: String) -> void:
	if not is_valid_class(class_id):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"class_id": str(class_id)}))


## Reads the saved class; DEFAULT_CLASS when missing / malformed /
## unknown (a bad save can never break spawn).
static func load_saved_class() -> String:
	if not FileAccess.file_exists(SAVE_PATH):
		return DEFAULT_CLASS
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return DEFAULT_CLASS
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary and is_valid_class(str((parsed as Dictionary).get("class_id", ""))):
		return str((parsed as Dictionary).get("class_id", ""))
	return DEFAULT_CLASS
