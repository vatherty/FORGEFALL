# FORGEFALL — verify_dnd_types (v0.5.8: D&D creature types, classes,
# ability scores, spell schools, elemental emitters)
#
# Verifies Worker A (creature types + ability scores), Worker B (classes
# on the fly), Worker C (emitters + spell schools) end to end, through
# the REAL APIs each worker shipped:
#   A: DnDTypes (scripts/data/dnd_types.gd) + EnemyBase.take_typed_damage
#      / apply_status_effect / _sweep_immune_effects / info_string.
#   B: PlayerClasses (scripts/progression/classes.gd) +
#      Player.set_player_class + Forge modify/class spec + Forge menu
#      CLASS tab.
#   C: ElementalEmitter (scripts/fx/elemental_emitter.gd) +
#      SpellSchools (scripts/mods/spell_schools.gd) + Forge emitter /
#      element specs + ModAPI.spawn_elemental_emitter / fire_effect.
#
# THE v0.5.8 CONTRACT:
# - 14 creature types with REAL enforced immunities (poison does
#   nothing to a construct/undead, sleep doesn't land on undead, oozes
#   resist acid).
# - 12 classes, mid-match swap (old kit removed, new kit applied
#   immediately, no restart) via Forge prompt AND via menu entry.
# - Ability scores (STR/DEX/CON/INT/WIS/CHA) on characters, referenced
#   by class/creature definitions, shown in character info.
# - Spell schools tag mods (all 8) and show in approval + mod info.
# - Every emitter element fires from a Forge structure AND from a
#   weapon: fire burns, lightning arcs/damages, water slows +
#   extinguishes burn. Water conducts lightning (x1.5 + chain) — that
#   IS claimed by Worker C, so it is verified behaviorally.
# - Forge spawn-by-type works ("spawn an undead brute").
# - Prompts list the new catalogs (types, classes, emitters, schools).
#
# DESIGN: discovery-first where the API was unknown, direct API calls
# where the workers' contracts are known. A missing API / unwired
# pipeline is a FAIL naming the missing piece — never a crash, never
# a silent pass. Checks needing a live match (menu tap, manager
# dispatch, Second Wind) are SKIP with the exact reason, not green.
#
# Run: godot --headless --path . --script res://tools/verify_dnd_types.gd
# Exit code 0 = all checks passed.
extends SceneTree

const CREATURE_TYPES := ["aberration", "beast", "celestial", "construct",
	"dragon", "elemental", "fey", "fiend", "giant", "humanoid",
	"monstrosity", "ooze", "plant", "undead"]
const CLASSES := ["barbarian", "bard", "cleric", "druid", "fighter",
	"monk", "paladin", "ranger", "rogue", "sorcerer", "warlock",
	"wizard"]
const SCHOOLS := ["abjuration", "conjuration", "divination",
	"enchantment", "evocation", "illusion", "necromancy",
	"transmutation"]
const ABILITIES_FULL := ["strength", "dexterity", "constitution",
	"intelligence", "wisdom", "charisma"]
const EMITTER_ELEMENTS := ["fire", "cold", "lightning", "acid", "poison",
	"radiant", "necrotic", "thunder", "force", "water"]

var _fails := 0
var _checks := 0
var _skips := 0
var _ran := false
var _sources := {}  # path -> file text (scripts/ + tools/)
var _DnDTypes: GDScript
var _PlayerClasses: GDScript
var _SpellSchools: GDScript
var _Emitter: GDScript
var _ForgeLLM: GDScript
var _ForgeBuilder: GDScript
var _ModStatus: GDScript
var _ModAPI: GDScript
var _EnemyBase: GDScript
var _Player: GDScript


class FakeWaveManager extends Node:
	var received: Array = []
	func apply_director_mod(mod: Dictionary) -> void:
		received.append(mod)


class DummyTarget extends CharacterBody3D:
	var hp := 100.0
	var dead := false
	# Stat hooks so blind (accuracy) / weaken (damage) riders can attach
	# via ModStatusEffects._apply_stat_scale's self path.
	var damage := 10.0
	var accuracy := 0.5
	func take_damage(amount: float, _pos: Vector3, _head: bool) -> void:
		hp -= amount
		if hp <= 0.0:
			dead = true
	func is_dead() -> bool:
		return dead


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % label)
	else:
		_fails += 1
		print("FAIL: %s" % label)


func _skip(label: String) -> void:
	_skips += 1
	print("SKIP: %s" % label)


func _init() -> void:
	pass


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_scan_sources()
	_DnDTypes = load("res://scripts/data/dnd_types.gd")
	_PlayerClasses = load("res://scripts/progression/classes.gd")
	_SpellSchools = load("res://scripts/mods/spell_schools.gd")
	_Emitter = load("res://scripts/fx/elemental_emitter.gd")
	_ForgeLLM = load("res://scripts/forge/forge_llm.gd")
	_ForgeBuilder = load("res://scripts/forge/forge_builder.gd")
	_ModStatus = load("res://scripts/mods/mod_status_effects.gd")
	_ModAPI = load("res://scripts/mods/mod_api.gd")
	_EnemyBase = load("res://scripts/enemies/enemy_base.gd")
	_Player = load("res://scripts/player/player.gd")
	_test_creature_catalog()
	_test_immunities()
	_test_classes()
	_test_abilities()
	_test_schools()
	_test_emitters()
	_test_spawn_by_type()
	_test_prompts()
	print("verify_dnd_types: %d checks, %d failures, %d skipped" % [_checks, _fails, _skips])
	quit(1 if _fails > 0 else 0)
	return true


# --- helpers ---------------------------------------------------------------

func _scan_sources() -> void:
	for dir_path in ["res://scripts", "res://tools"]:
		_scan_dir(dir_path)


func _scan_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.ends_with(".gd"):
			var p := dir_path + "/" + f
			_sources[p] = FileAccess.get_file_as_string(p)
	for d in dir.get_directories():
		if d == ".godot":
			continue
		_scan_dir(dir_path + "/" + d)


func _has_word(text: String, word: String) -> bool:
	var low := text.to_lower()
	var w := word.to_lower()
	var idx := 0
	while true:
		var at := low.find(w, idx)
		if at < 0:
			return false
		var before_ok := at == 0 or not _is_word_char(low[at - 1])
		var after_idx := at + w.length()
		var after_ok := after_idx >= low.length() or not _is_word_char(low[after_idx])
		if before_ok and after_ok:
			return true
		idx = at + 1
	return false


static func _is_word_char(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"


func _prop_names(obj: Object) -> Array:
	var names: Array = []
	for p in obj.get_property_list():
		names.append(str(p.get("name", "")))
	return names


func _make_enemy(creature_type: String) -> CharacterBody3D:
	var e: CharacterBody3D = _EnemyBase.new()
	e.name = "DndTestEnemy"
	root.add_child(e)
	# _ready runs on add_child; activate the enemy so take_damage works
	# (take_damage early-returns while parked: active == false).
	e.set("active", true)
	e.set("hp", 100.0)
	e.set("max_hp", 100.0)
	if not e.call("set_creature_type", creature_type):
		print("WARN: set_creature_type(%s) rejected" % creature_type)
	return e


func _make_dummy() -> DummyTarget:
	var d := DummyTarget.new()
	d.name = "EmitterDummy"
	d.hp = 100.0
	d.dead = false
	root.add_child(d)
	return d


# --- 1. creature types ------------------------------------------------------

func _test_creature_catalog() -> void:
	var ids: Variant = _DnDTypes.get_script_constant_map().get("CREATURE_TYPE_IDS", [])
	var table: Variant = _DnDTypes.get_script_constant_map().get("CREATURE_TYPES", {})
	_check(ids is Array and (ids as Array).size() == 14,
		"types: DnDTypes.CREATURE_TYPE_IDS has all 14 types (got %d)" % ((ids as Array).size() if ids is Array else -1))
	_check(table is Dictionary and (table as Dictionary).size() == 14,
		"types: DnDTypes.CREATURE_TYPES table has all 14 rows (got %d)" % ((table as Dictionary).size() if table is Dictionary else -1))
	for t in CREATURE_TYPES:
		_check(bool(_DnDTypes.call("is_creature_type", t)),
			"types: is_creature_type('%s') is true" % t)
	_check(not _DnDTypes.call("is_creature_type", "bogus"),
		"types: is_creature_type('bogus') is false")
	# Damage-multiplier table spot checks (0.0 immune, 0.5 resist, 1.0 else).
	var mult_cases := [
		["construct", "poison", 0.0], ["construct", "psychic", 0.0],
		["undead", "poison", 0.0], ["elemental", "poison", 0.0],
		["fiend", "poison", 0.0], ["ooze", "acid", 0.5],
		["fiend", "fire", 0.5], ["fiend", "cold", 0.5],
		["fiend", "lightning", 0.5], ["aberration", "psychic", 0.5],
		["celestial", "radiant", 0.5], ["celestial", "necrotic", 0.5],
		["humanoid", "poison", 1.0], ["humanoid", "fire", 1.0],
		["beast", "acid", 1.0], ["dragon", "fire", 1.0],
		["bogus", "poison", 1.0], ["humanoid", "bogus", 1.0],
	]
	for c in mult_cases:
		var got: float = _DnDTypes.call("damage_multiplier", c[0], c[1])
		_check(is_equal_approx(got, float(c[2])),
			"types: damage_multiplier('%s','%s') = %.1f (got %.1f)" % [c[0], c[1], float(c[2]), got])
	# Status-immunity table spot checks.
	var status_cases := [
		["construct", "poison", true], ["construct", "sleep", true],
		["construct", "exhaustion", true], ["undead", "sleep", true],
		["undead", "poison", true], ["fey", "sleep", true],
		["ooze", "blind", true], ["ooze", "prone", true],
		["elemental", "restrained", true], ["elemental", "prone", true],
		["elemental", "sleep", true], ["humanoid", "sleep", false],
		["humanoid", "poison", false], ["beast", "poison", false],
		["ooze", "poison", false], ["fiend", "poison", true],
	]
	for c in status_cases:
		var got: bool = _DnDTypes.call("is_status_immune", c[0], c[1])
		_check(got == bool(c[2]),
			"types: is_status_immune('%s','%s') = %s (got %s)" % [c[0], c[1], str(c[2]), str(got)])


# --- 2. immunities enforced in-game ------------------------------------------

func _test_immunities() -> void:
	# Controls: a humanoid takes full typed damage and can be slept.
	var human: CharacterBody3D = _make_enemy("humanoid")
	human.call("take_typed_damage", 20.0, "poison", Vector3.ZERO, false)
	_check(is_equal_approx(float(human.get("hp")), 80.0),
		"immunity CONTROL: humanoid takes full poison typed_damage 20 (hp %.1f)" % float(human.get("hp")))
	_check(is_equal_approx(float(human.get("last_damage_multiplier")), 1.0),
		"immunity CONTROL: humanoid last_damage_multiplier is 1.0")
	var human2: CharacterBody3D = _make_enemy("humanoid")
	var slept: bool = human2.call("apply_status_effect", "sleep", {"duration_sec": 5.0}, Vector3.ZERO)
	_check(slept and _ModStatus.call("has_status_effect", human2, "sleep"),
		"immunity CONTROL: sleep lands on a humanoid via apply_status_effect")
	# Construct: poison does NOTHING (typed damage + status + sweep).
	var construct: CharacterBody3D = _make_enemy("construct")
	construct.call("take_typed_damage", 20.0, "poison", Vector3.ZERO, false)
	_check(is_equal_approx(float(construct.get("hp")), 100.0),
		"immunity: poison typed_damage 20 deals NO damage to a construct (hp %.1f)" % float(construct.get("hp")))
	_check(is_equal_approx(float(construct.get("last_damage_multiplier")), 0.0),
		"immunity: construct last_damage_multiplier is 0.0 for poison")
	_check(is_equal_approx(float(construct.get("last_hit_damage")), 0.0),
		"immunity: construct last_hit_damage stays 0.0 for immune poison")
	var construct2: CharacterBody3D = _make_enemy("construct")
	var p_applied: bool = construct2.call("apply_status_effect", "poison",
		{"damage_per_sec": 10.0, "duration_sec": 3.0}, Vector3.ZERO)
	_check(not p_applied and not _ModStatus.call("has_status_effect", construct2, "poison"),
		"immunity: apply_status_effect('poison') on a construct returns false and applies nothing")
	# Direct ModStatusEffects path (mod hooks bypass the wrapper): the
	# Direct ModStatusEffects path: the v0.5.8 immunity gate in
	# apply_status refuses poison on a construct outright (better than
	# attaching + sweeping). The sweep is still covered below via a
	# gate-bypassing _upsert (effects injected past apply_status).
	var construct3: CharacterBody3D = _make_enemy("construct")
	var direct_refused: bool = not bool(_ModStatus.call("apply_status", construct3, "poison",
		{"damage_per_sec": 10.0, "duration_sec": 3.0}, Vector3.ZERO))
	_check(direct_refused and not _ModStatus.call("has_status_effect", construct3, "poison"),
		"immunity: direct ModStatusEffects poison refused by the gate (apply returns false, nothing attached)")
	_ModStatus.call("_upsert", construct3,
		{"kind": "poison", "damage_per_sec": 10.0, "remaining": 3.0, "accum": 0.0})
	_check(_ModStatus.call("has_status_effect", construct3, "poison"),
		"immunity CONTROL: gate-bypassing poison attaches via _upsert (the path the sweep must catch)")
	construct3.call("_sweep_immune_effects")
	_check(not _ModStatus.call("has_status_effect", construct3, "poison"),
		"immunity: sweep clears direct-path poison on a construct")
	_ModStatus.call("tick_target", construct3, 1.0)
	_check(is_equal_approx(float(construct3.get("hp")), 100.0),
		"immunity: swept poison deals 0 DOT damage after a 1s tick (hp %.1f)" % float(construct3.get("hp")))
	# Undead: poison does nothing, sleep doesn't land.
	var undead: CharacterBody3D = _make_enemy("undead")
	undead.call("take_typed_damage", 20.0, "poison", Vector3.ZERO, false)
	_check(is_equal_approx(float(undead.get("hp")), 100.0),
		"immunity: poison typed_damage 20 deals NO damage to an undead (hp %.1f)" % float(undead.get("hp")))
	var undead2: CharacterBody3D = _make_enemy("undead")
	var u_slept: bool = undead2.call("apply_status_effect", "sleep", {"duration_sec": 5.0}, Vector3.ZERO)
	_check(not u_slept and not _ModStatus.call("has_status_effect", undead2, "sleep"),
		"immunity: sleep does NOT land on an undead (apply returns false, no effect)")
	# Ooze: resists acid (half damage), immune to blind/prone.
	var ooze: CharacterBody3D = _make_enemy("ooze")
	ooze.call("take_typed_damage", 20.0, "acid", Vector3.ZERO, false)
	_check(is_equal_approx(float(ooze.get("hp")), 90.0),
		"immunity: ooze resists acid — typed_damage 20 deals 10 (hp %.1f)" % float(ooze.get("hp")))
	var ooze2: CharacterBody3D = _make_enemy("ooze")
	_check(not ooze2.call("apply_status_effect", "blind", {"factor": 0.5, "duration_sec": 3.0}, Vector3.ZERO),
		"immunity: blind does NOT land on an ooze")
	_check(not ooze2.call("apply_status_effect", "prone", {"force": 5.0, "duration_sec": 2.0}, Vector3.ZERO),
		"immunity: prone does NOT land on an ooze")
	# Fiend: resists fire. Elemental: immune to restrained.
	var fiend: CharacterBody3D = _make_enemy("fiend")
	fiend.call("take_typed_damage", 20.0, "fire", Vector3.ZERO, false)
	_check(is_equal_approx(float(fiend.get("hp")), 90.0),
		"immunity: fiend resists fire — typed_damage 20 deals 10 (hp %.1f)" % float(fiend.get("hp")))
	var elemental: CharacterBody3D = _make_enemy("elemental")
	_check(not elemental.call("apply_status_effect", "restrained", {"duration_sec": 3.0}, Vector3.ZERO),
		"immunity: restrained does NOT land on an elemental")
	# set_creature_type validation + info_string.
	var t := _make_enemy("humanoid")
	_check(not t.call("set_creature_type", "bogus") and str(t.get("creature_type")) == "humanoid",
		"immunity: set_creature_type('bogus') returns false and leaves type humanoid")
	_check(t.call("set_creature_type", "undead") and str(t.get("creature_type")) == "undead",
		"immunity: set_creature_type('undead') returns true and switches the live type")
	var info: String = str(t.call("info_string"))
	_check(info.contains("Undead") and info.contains("STR") and info.contains("immune"),
		"info: enemy info_string shows type + stat block + immunities (got '%s')" % info)
	var hinfo: String = str(human.call("info_string"))
	_check(hinfo.contains("Humanoid") and hinfo.contains("no enforced immunities"),
		"info: humanoid info_string shows 'no enforced immunities' (got '%s')" % hinfo)


# --- 3. classes ----------------------------------------------------------------

func _test_classes() -> void:
	var ids: Variant = _PlayerClasses.get_script_constant_map().get("CLASS_IDS", [])
	_check(ids is Array and (ids as Array).size() == 12,
		"classes: PlayerClasses.CLASS_IDS has all 12 classes (got %d)" % ((ids as Array).size() if ids is Array else -1))
	for c in CLASSES:
		_check(bool(_PlayerClasses.call("is_valid_class", c)),
			"classes: is_valid_class('%s') is true" % c)
		var defn: Variant = _PlayerClasses.call("get_definition", c)
		_check(defn is Dictionary and not (defn as Dictionary).is_empty()
				and (defn as Dictionary).has("ability_bonuses")
				and (defn as Dictionary).has("mods")
				and (defn as Dictionary).has("tagline"),
			"classes: get_definition('%s') has ability_bonuses + mods + tagline" % c)
	_check(not _PlayerClasses.call("is_valid_class", "bogus"),
		"classes: is_valid_class('bogus') is false")
	# Display name: read the DISPLAY_NAMES const (class_name() itself
	# can't be invoked via .call — `class_name` is a GDScript keyword).
	var display_names: Variant = _PlayerClasses.get_script_constant_map().get("DISPLAY_NAMES", {})
	_check(display_names is Dictionary and str((display_names as Dictionary).get("rogue", "")) == "Rogue",
		"classes: DISPLAY_NAMES['rogue'] = 'Rogue'")
	# Kit modifiers (the numbers the game actually applies).
	_check(is_equal_approx(float(_PlayerClasses.call("get_mod", "barbarian", "max_hp_mult", 1.0)), 1.4),
		"classes: barbarian max_hp_mult = 1.4")
	_check(is_equal_approx(float(_PlayerClasses.call("get_mod", "rogue", "crit_chance", 0.0)), 0.25),
		"classes: rogue crit_chance = 0.25")
	_check(is_equal_approx(float(_PlayerClasses.call("get_mod", "wizard", "forge_cooldown_mult", 1.0)), 0.5),
		"classes: wizard forge_cooldown_mult = 0.5")
	_check(is_equal_approx(float(_PlayerClasses.call("get_mod", "fighter", "damage_mult", 1.0)), 1.1),
		"classes: fighter damage_mult = 1.1")
	_check(bool(_PlayerClasses.call("get_mod", "fighter", "second_wind", false)),
		"classes: fighter second_wind = true")
	# Summary + prompt matching.
	var summ: String = str(_PlayerClasses.call("summary", "barbarian"))
	_check(summ.contains("BARBARIAN") and summ.contains("Ability") and summ.contains("+2 STR"),
		"classes: summary('barbarian') shows name + tagline + ability bonuses (got '%s')" % summ)
	_check(str(_PlayerClasses.call("match_in_prompt", "make me a rogue")) == "rogue",
		"classes: match_in_prompt('make me a rogue') = rogue")
	_check(str(_PlayerClasses.call("match_in_prompt", "become a wizard")) == "wizard",
		"classes: match_in_prompt('become a wizard') = wizard")
	_check(str(_PlayerClasses.call("match_in_prompt", "mage")) == "wizard",
		"classes: match_in_prompt('mage') = wizard (alias)")
	_check(str(_PlayerClasses.call("match_in_prompt", "thief")) == "rogue",
		"classes: match_in_prompt('thief') = rogue (alias)")
	_check(str(_PlayerClasses.call("match_in_prompt", "build a wall")).is_empty(),
		"classes: match_in_prompt('build a wall') = '' (no class intent)")
	_check(str(_PlayerClasses.call("enemy_class_tag", "grunt")) == "fighter",
		"classes: enemy_class_tag('grunt') = fighter (display tag)")
	# Mid-match swap on a real Player instance (no scene: _ready never
	# runs; set_player_class only touches kit state + save + signals).
	var saved_path := "user://player_class.json"
	var had_save := FileAccess.file_exists(saved_path)
	var saved_text := ""
	if had_save:
		var rf := FileAccess.open(saved_path, FileAccess.READ)
		if rf != null:
			saved_text = rf.get_as_text()
	var player: Object = _Player.new()
	_check(str(player.get("active_class_id")) == "fighter",
		"classes: fresh player defaults to fighter")
	# Player stat block: base all 10s + fighter bonuses, read live.
	_check("ability_scores" in _prop_names(player),
		"classes: player carries a base ability_scores block")
	var p_block: Variant = player.call("get_ability_scores")
	_check(p_block is Dictionary and int((p_block as Dictionary).get("str", 0)) == 12
			and int((p_block as Dictionary).get("con", 0)) == 11,
		"classes: fresh fighter's effective block is STR 12 / CON 11 (base 10s + fighter bonuses)")
	_check(int(player.call("get_ability_modifier", "str")) == 1,
		"classes: fresh fighter's STR modifier is +1")
	_check(str(player.call("get_stat_block_text")).contains("STR 12 (+1)"),
		"classes: get_stat_block_text() shows 'STR 12 (+1)' (got '%s')" % str(player.call("get_stat_block_text")))
	_check(bool(player.call("set_player_class", "rogue")),
		"classes: set_player_class('rogue') returns true")
	_check(str(player.call("get_active_class_id")) == "rogue",
		"classes: active class is rogue after swap")
	_check(is_equal_approx(float(player.call("class_crit_chance")), 0.25),
		"classes: rogue kit applies immediately — crit chance 0.25")
	_check(is_equal_approx(float(player.call("class_damage_mult")), 1.0),
		"classes: rogue kit has no damage_mult — class_damage_mult is the 1.0 default")
	# Old kit removed: swap rogue -> barbarian, crit must drop to 0.
	_check(bool(player.call("set_player_class", "barbarian")),
		"classes: set_player_class('barbarian') returns true")
	_check(is_equal_approx(float(player.call("class_crit_chance")), 0.0),
		"classes: old kit removed — barbarian crit chance is 0.0 (rogue's 0.25 is gone)")
	_check(is_equal_approx(float(player.call("class_damage_mult")), 1.15),
		"classes: new kit applies immediately — barbarian damage_mult 1.15")
	_check(is_equal_approx(float(player.call("class_damage_taken_mult")), 0.75),
		"classes: barbarian damage_taken_mult 0.75 applies immediately")
	var p_barb_block: Variant = player.call("get_ability_scores")
	_check(p_barb_block is Dictionary and int((p_barb_block as Dictionary).get("str", 0)) == 12
			and int((p_barb_block as Dictionary).get("con", 0)) == 12,
		"classes: effective block follows the swap — barbarian is STR 12 / CON 12 (was fighter 12/11)")
	# HP keeps its FRACTION across the swap (swap neither heals nor hurts).
	if "_hp" in _prop_names(player):
		var max_before: float = player.call("get_max_hp")
		player.set("_hp", max_before * 0.5)
		player.call("set_player_class", "wizard")
		var max_after: float = player.call("get_max_hp")
		_check(is_equal_approx(float(player.get("_hp")), max_after * 0.5),
			"classes: HP fraction preserved across swap (hp %.1f = 50%% of new max %.1f)" % [float(player.get("_hp")), max_after])
	else:
		_skip("classes: player has no _hp property to test HP-fraction preservation")
	# Same-class + invalid swaps are no-ops.
	_check(not player.call("set_player_class", "wizard"),
		"classes: set_player_class to the active class returns false (no-op)")
	_check(not player.call("set_player_class", "bogus")
			and str(player.call("get_active_class_id")) == "wizard",
		"classes: set_player_class('bogus') returns false and leaves the class wizard")
	# Persistence round-trip (restore the pre-test save afterwards).
	_PlayerClasses.call("save_class", "cleric")
	_check(str(_PlayerClasses.call("load_saved_class")) == "cleric",
		"classes: save_class('cleric') -> load_saved_class() = cleric")
	if had_save:
		var wf := FileAccess.open(saved_path, FileAccess.WRITE)
		if wf != null:
			wf.store_string(saved_text)
	else:
		DirAccess.remove_absolute("user://player_class.json")
	# Class ability bonuses: data exists; the handoff to a stat block
	# is a metadata stash (no player consumer yet — see abilities).
	var barb_bonuses: Variant = _PlayerClasses.call("get_ability_bonuses", "barbarian")
	_check(barb_bonuses is Dictionary and int((barb_bonuses as Dictionary).get("str", 0)) == 2
			and int((barb_bonuses as Dictionary).get("con", 0)) == 2,
		"classes: barbarian ability_bonuses = {str:2, con:2} (got %s)" % str(barb_bonuses))
	# Effective stat block = base + class bonuses (no stored application
	# step: the player reads it live from base + active class).
	var eff_fighter: Variant = _PlayerClasses.call("effective_ability_scores",
		{"str": 10, "dex": 10, "con": 10, "int": 10, "wis": 10, "cha": 10}, "fighter")
	_check(int((eff_fighter as Dictionary).get("str", 0)) == 12
			and int((eff_fighter as Dictionary).get("con", 0)) == 11,
		"classes: effective_ability_scores(all-10s, fighter) = STR 12 / CON 11")
	var eff_barb: Variant = _PlayerClasses.call("effective_ability_scores",
		{"str": 16, "dex": 10, "con": 10, "int": 10, "wis": 10, "cha": 10}, "barbarian")
	_check(int((eff_barb as Dictionary).get("str", 0)) == 18,
		"classes: effective_ability_scores({STR 16}, barbarian) = STR 18 (bonus stacks on base)")
	var eff_bogus: Variant = _PlayerClasses.call("effective_ability_scores",
		{"str": 10, "dex": 10, "con": 10, "int": 10, "wis": 10, "cha": 10}, "bogus")
	_check(int((eff_bogus as Dictionary).get("str", 0)) == 10,
		"classes: effective_ability_scores with an unknown class leaves the base block unchanged")
	player.free()
	# Forge prompt path: gate + offline parser.
	var spec := {"spec_version": 1, "action": "modify", "target": "class",
		"params": {"class_id": "rogue"}, "cost": 0, "ttl": 0}
	var verdict: Variant = _ForgeLLM.call("validate_modspec", spec)
	_check(verdict is Array and bool((verdict as Array)[0]),
		"classes: Forge gate accepts modify/class {class_id:rogue} (verdict: %s)" % str(verdict))
	var bad_spec := {"spec_version": 1, "action": "modify", "target": "class",
		"params": {"class_id": "bogus"}, "cost": 0, "ttl": 0}
	var bad_verdict: Variant = _ForgeLLM.call("validate_modspec", bad_spec)
	_check(bad_verdict is Array and not bool((bad_verdict as Array)[0]),
		"classes: Forge gate rejects modify/class {class_id:bogus} (verdict: %s)" % str(bad_verdict))
	var off: Variant = _ForgeLLM.call("_class_spec_for_prompt", "make me a rogue")
	_check(off is Dictionary and str((off as Dictionary).get("target", "")) == "class"
			and str(((off as Dictionary).get("params", {}) as Dictionary).get("class_id", "")) == "rogue",
		"classes: offline parser maps 'make me a rogue' to modify/class rogue (got %s)" % str(off))
	var off2: Variant = _ForgeLLM.call("_class_spec_for_prompt", "build a wall")
	_check(off2 is Dictionary and (off2 as Dictionary).is_empty(),
		"classes: offline parser returns {} for 'build a wall' (no class intent)")
	# Menu entry: CLASS tab built + buttons call set_player_class.
	var menu_src: String = _sources.get("res://scripts/ui/forge_menu.gd", "")
	_check(menu_src.contains("_build_class_tab()") and menu_src.contains("Class_"),
		"classes: Forge menu builds a CLASS tab with per-class buttons")
	_check(menu_src.contains("_on_class_pressed") and menu_src.contains("set_player_class"),
		"classes: menu class buttons call Player.set_player_class (direct swap, no Forge pipeline)")
	_skip("classes: live menu tap + Forge-manager dispatch need a running match (manager calls set_player_class; verified by source, not executed headless)")
	_skip("classes: fighter Second Wind needs a live player taking damage (no headless harness)")


# --- 4. ability scores ----------------------------------------------------------

func _test_abilities() -> void:
	# DnDTypes stat-block primitives.
	var defaults: Variant = _DnDTypes.call("default_ability_scores")
	_check(defaults is Dictionary and int((defaults as Dictionary).get("str", 0)) == 10
			and int((defaults as Dictionary).get("cha", 0)) == 10,
		"abilities: default_ability_scores() is all 10s")
	var block: Variant = _DnDTypes.call("ability_scores", 19, 9, 18, 8, 10, 9)
	_check(int((block as Dictionary).get("str", 0)) == 19 and int((block as Dictionary).get("con", 0)) == 18,
		"abilities: ability_scores(19,9,18,8,10,9) stores STR 19 / CON 18")
	var norm: Variant = _DnDTypes.call("normalize_ability_scores", {"str": 99})
	_check(int((norm as Dictionary).get("str", 0)) == 30 and int((norm as Dictionary).get("dex", 0)) == 10,
		"abilities: normalize clamps 99 -> 30 and fills missing keys with 10")
	var norm2: Variant = _DnDTypes.call("normalize_ability_scores", {})
	_check(int((norm2 as Dictionary).get("wis", 0)) == 10,
		"abilities: normalize({}) fills every score with 10")
	_check(int(_DnDTypes.call("ability_modifier", 10)) == 0,
		"abilities: ability_modifier(10) = 0")
	_check(int(_DnDTypes.call("ability_modifier", 14)) == 2,
		"abilities: ability_modifier(14) = 2")
	_check(int(_DnDTypes.call("ability_modifier", 8)) == -1,
		"abilities: ability_modifier(8) = -1")
	_check(int(_DnDTypes.call("ability_modifier", 9)) == -1,
		"abilities: ability_modifier(9) = -1 (floor, not truncation)")
	_check(int(_DnDTypes.call("ability_modifier", 16)) == 3,
		"abilities: ability_modifier(16) = +3")
	_check(int(_DnDTypes.call("ability_modifier", 1)) == -5,
		"abilities: ability_modifier(1) = -5")
	var base_block: Dictionary = {"str": 16, "dex": 10, "con": 10, "int": 10, "wis": 10, "cha": 10}
	var boosted: Variant = _DnDTypes.call("with_bonus", base_block, "str", 2)
	_check(int((boosted as Dictionary).get("str", 0)) == 18 and int(base_block.get("str", 0)) == 16,
		"abilities: with_bonus(+2 STR) gives 18 without mutating the input")
	_check(int(_DnDTypes.call("get_ability", base_block, "str")) == 16,
		"abilities: get_ability(block, 'str') = 16")
	_check(int(_DnDTypes.call("get_ability_modifier", base_block, "str")) == 3,
		"abilities: get_ability_modifier(block, 'str') = +3")
	var fmt: String = str(_DnDTypes.call("format_stat_block", base_block))
	_check(fmt.contains("STR 16 (+3)") and fmt.contains("DEX 10 (+0)"),
		"abilities: format_stat_block shows 'STR 16 (+3)' + 'DEX 10 (+0)' (got '%s')" % fmt)
	# Enemies carry stat blocks; a brute's is STR 19 / CON 18.
	var brute_script: GDScript = load("res://scripts/enemies/brute.gd")
	var brute: CharacterBody3D = brute_script.new()
	brute.name = "DndTestBrute"
	root.add_child(brute)
	_check("ability_scores" in _prop_names(brute),
		"abilities: enemies carry an ability_scores property")
	_check(int(brute.call("get_ability_score", "str")) == 19,
		"abilities: brute get_ability_score('str') = 19")
	_check(int(brute.call("get_ability_modifier", "con")) == 4,
		"abilities: brute get_ability_modifier('con') = +4 (CON 18)")
	var brute_info: String = str(brute.call("info_string"))
	_check(brute_info.contains("STR 19 (+4)") and brute_info.contains("CON 18 (+4)"),
		"abilities: brute info_string shows its stat block (got '%s')" % brute_info)
	# Creature definitions reference ability scores (source: the enemy
	# scripts assign real stat blocks).
	var enemy_src := ""
	for path in _sources.keys():
		if str(path).contains("/enemies/"):
			enemy_src += str(_sources[path]) + "\n"
	_check(enemy_src.contains("ability_scores = DnDTypes.ability_scores"),
		"abilities: creature definitions assign ability_scores via DnDTypes.ability_scores")
	# Class definitions reference ability scores (all 12 carry bonuses).
	var all_have := true
	for c in CLASSES:
		var b: Variant = _PlayerClasses.call("get_ability_bonuses", c)
		if not (b is Dictionary and not (b as Dictionary).is_empty()):
			all_have = false
	_check(all_have,
		"abilities: all 12 class definitions carry non-empty ability_bonuses")
	# Player side: base block + effective block follow the class swap.
	var p_probe: Object = _Player.new()
	_check("ability_scores" in _prop_names(p_probe),
		"abilities: player carries an ability_scores property (base block)")
	var p_base: Variant = p_probe.get("ability_scores")
	_check(p_base is Dictionary and int((p_base as Dictionary).get("str", 0)) == 10,
		"abilities: player base block is all 10s")
	_check(str(p_probe.call("get_stat_block_text")).contains("STR 12 (+1)"),
		"abilities: player character-info line shows the class-adjusted block (fighter: 'STR 12 (+1)')")
	p_probe.free()
	# Character info: enemy info_string shows scores (above); the HUD
	# does not display any character's scores.
	var hud_src: String = _sources.get("res://scripts/ui/hud.gd", "")
	_check(not (hud_src.contains("info_string") or hud_src.contains("ability_scores")),
		"abilities: HUD does not display ability scores (Worker A deferred HUD wiring — API exists, display does not)")


# --- 5. spell schools ------------------------------------------------------------

func _test_schools() -> void:
	var schools: Variant = _SpellSchools.get_script_constant_map().get("SCHOOLS", [])
	_check(schools is Array and (schools as Array).size() == 8,
		"schools: SpellSchools.SCHOOLS has all 8 schools (got %d)" % ((schools as Array).size() if schools is Array else -1))
	for s in SCHOOLS:
		_check(bool(_SpellSchools.call("is_school", s)),
			"schools: is_school('%s') is true" % s)
	_check(not _SpellSchools.call("is_school", "bogus"),
		"schools: is_school('bogus') is false")
	_check(str(_SpellSchools.call("normalize", "  EVOCATION ")) == "evocation",
		"schools: normalize('  EVOCATION ') = 'evocation' (case/whitespace-insensitive)")
	_check(str(_SpellSchools.call("normalize", "bogus")).is_empty(),
		"schools: normalize('bogus') = '' (unknown degrades to untagged)")
	_check(str(_SpellSchools.call("display_name", "evocation")) == "Evocation",
		"schools: display_name('evocation') = 'Evocation'")
	var all_blurbs := true
	for s in SCHOOLS:
		if str(_SpellSchools.call("blurb", s)).is_empty():
			all_blurbs = false
	_check(all_blurbs,
		"schools: every school has a non-empty blurb")
	var line: String = str(_SpellSchools.call("approval_line", "evocation"))
	_check(line.contains("Evocation") and line.contains("tag only"),
		"schools: approval_line('evocation') = '%s'" % line)
	_check(str(_SpellSchools.call("approval_line", "bogus")).is_empty(),
		"schools: approval_line('bogus') = '' (untagged)")
	# Persistence round-trip: block wrapper + script comment.
	var block_payload := "{\"block\": {\"hook_id\": \"x\"}}"
	var wrapped: String = str(_SpellSchools.call("wrap_block_payload", block_payload, "evocation"))
	_check(wrapped.contains("\"spell_school\":\"evocation\"") or wrapped.contains("\"spell_school\": \"evocation\""),
		"schools: wrap_block_payload adds spell_school outside the block (got '%s')" % wrapped)
	_check(str(_SpellSchools.call("parse_from_payload", wrapped)) == "evocation",
		"schools: parse_from_payload reads the school back from a wrapped block payload")
	var script_payload := "# spell_school: necromancy\n# some script"
	_check(str(_SpellSchools.call("parse_from_payload", script_payload)) == "necromancy",
		"schools: parse_from_payload reads the school back from a script comment")
	_check(str(_SpellSchools.call("parse_from_payload", "{\"block\": {}}")).is_empty(),
		"schools: parse_from_payload returns '' for an untagged payload")
	# WIRING: nothing in the pipeline references SpellSchools — the
	# catalog exists but no code calls it (approval / install / mod info).
	var wired := false
	for path in _sources.keys():
		if str(path).ends_with("spell_schools.gd") or str(path).contains("verify_dnd_types"):
			continue
		if str(_sources[path]).contains("SpellSchools") or str(_sources[path]).contains("spell_school") or str(_sources[path]).contains("approval_line"):
			wired = true
	_check(wired,
		"schools: pipeline files reference SpellSchools / spell_school / approval_line")
	var menu_src: String = _sources.get("res://scripts/ui/mod_creator_menu.gd", "")
	_check(menu_src.contains("School"),
		"schools: approval screen shows a school")
	var mods_tab_src: String = _sources.get("res://scripts/ui/forge_menu.gd", "")
	_check(mods_tab_src.contains("spell_school"),
		"schools: Forge Mods tab surfaces the school tag")


# --- 6. emitters -----------------------------------------------------------------

func _test_emitters() -> void:
	var elems: Variant = _Emitter.get_script_constant_map().get("ELEMENTS", [])
	_check(elems is Array and (elems as Array).size() == 10,
		"emitters: ElementalEmitter.ELEMENTS has all 10 elements (got %d)" % ((elems as Array).size() if elems is Array else -1))
	for e in EMITTER_ELEMENTS:
		_check(bool(_Emitter.call("is_element", e)),
			"emitters: is_element('%s') is true" % e)
		_check(not str(_Emitter.call("element_blurb", e)).is_empty(),
			"emitters: element_blurb('%s') is non-empty" % e)
	_check(not _Emitter.call("is_element", "bogus"),
		"emitters: is_element('bogus') is false")
	var catalog: String = str(_Emitter.call("catalog_text"))
	var cat_ok := true
	for e in EMITTER_ELEMENTS:
		if not catalog.contains(e):
			cat_ok = false
	_check(cat_ok and catalog.contains("WET"),
		"emitters: catalog_text() lists all 10 elements + the WET rule")
	# spawn_field for every element + clamps.
	for e in EMITTER_ELEMENTS:
		var node: Variant = _Emitter.call("spawn_field", root, e, Vector3.ZERO, 4.0, 10.0, 10.0)
		_check(node is Node and str((node as Node).get("element")) == e,
			"emitters: spawn_field('%s') returns a node with element='%s'" % [e, e])
		if node is Node:
			(node as Node).queue_free()
	var clamped: Variant = _Emitter.call("spawn_field", root, "fire", Vector3.ZERO, 99.0, 1.0, 0.0)
	_check(clamped is Node and is_equal_approx(float((clamped as Node).get("radius")), 10.0)
			and is_equal_approx(float((clamped as Node).get("duration_sec")), 3.0)
			and is_equal_approx(float((clamped as Node).get("damage_per_sec")), 1.0),
		"emitters: spawn_field clamps radius 99->10, duration 1->3, dps 0->1")
	if clamped is Node:
		(clamped as Node).queue_free()
	# apply_to_target per element: damage + the element's rider.
	var d := _make_dummy()
	_Emitter.call("apply_to_target", d, "fire", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 80.0) and _ModStatus.call("has_status_effect", d, "burn"),
		"emitters: fire hit deals 20 + applies burn (hp %.1f)" % d.hp)
	d.queue_free()
	d = _make_dummy()
	_Emitter.call("apply_to_target", d, "cold", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 80.0) and _ModStatus.call("has_status_effect", d, "slow"),
		"emitters: cold hit deals 20 + applies slow rider (hp %.1f)" % d.hp)
	d.queue_free()
	d = _make_dummy()
	_Emitter.call("apply_to_target", d, "lightning", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 80.0),
		"emitters: lightning hit on a DRY target deals exactly 20 (hp %.1f)" % d.hp)
	d.queue_free()
	d = _make_dummy()
	_Emitter.call("apply_to_target", d, "acid", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 80.0) and _ModStatus.call("has_status_effect", d, "weaken"),
		"emitters: acid hit deals 20 + applies weaken rider (hp %.1f)" % d.hp)
	d.queue_free()
	d = _make_dummy()
	_Emitter.call("apply_to_target", d, "poison", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 80.0) and _ModStatus.call("has_status_effect", d, "poison"),
		"emitters: poison hit deals 20 + applies poison rider (hp %.1f)" % d.hp)
	d.queue_free()
	d = _make_dummy()
	_Emitter.call("apply_to_target", d, "radiant", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 80.0) and _ModStatus.call("has_status_effect", d, "blind"),
		"emitters: radiant hit deals 20 + applies blind rider (hp %.1f)" % d.hp)
	d.queue_free()
	d = _make_dummy()
	_Emitter.call("apply_to_target", d, "necrotic", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 80.0) and _ModStatus.call("has_status_effect", d, "exhaustion"),
		"emitters: necrotic hit deals 20 + applies +1 exhaustion (hp %.1f)" % d.hp)
	d.queue_free()
	d = _make_dummy()
	_Emitter.call("apply_to_target", d, "thunder", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 80.0) and _ModStatus.call("has_status_effect", d, "prone"),
		"emitters: thunder hit deals 20 + applies prone (hp %.1f)" % d.hp)
	d.queue_free()
	d = _make_dummy()
	var vel_before := d.velocity
	_Emitter.call("apply_to_target", d, "force", 20.0, Vector3(0, 0, 5))
	_check(is_equal_approx(d.hp, 80.0) and d.velocity != vel_before,
		"emitters: force hit deals 20 direct + knockback (hp %.1f, velocity changed)" % d.hp)
	d.queue_free()
	# Water: small damage + slow + extinguishes burn + WET; poison NOT cleared.
	d = _make_dummy()
	_ModStatus.call("apply_status", d, "burn", {"damage_per_sec": 10.0, "duration_sec": 10.0}, Vector3.ZERO)
	_ModStatus.call("apply_status", d, "poison", {"damage_per_sec": 10.0, "duration_sec": 10.0}, Vector3.ZERO)
	_Emitter.call("apply_to_target", d, "water", 5.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 95.0),
		"emitters: water hit deals its small direct damage 5 (hp %.1f)" % d.hp)
	_check(_ModStatus.call("has_status_effect", d, "slow"),
		"emitters: water hit applies slow x0.6")
	_check(not _ModStatus.call("has_status_effect", d, "burn"),
		"emitters: water EXTINGUISHES burn")
	_check(_ModStatus.call("has_status_effect", d, "poison"),
		"emitters: water does NOT clear poison (only burn goes out)")
	_check(bool(_Emitter.call("is_wet", d)),
		"emitters: water marks the target WET")
	d.queue_free()
	# Unknown element: safe no-op.
	d = _make_dummy()
	_check(not _Emitter.call("apply_to_target", d, "bogus", 20.0, Vector3.ZERO)
			and is_equal_approx(d.hp, 100.0),
		"emitters: apply_to_target('bogus') returns false and deals no damage")
	d.queue_free()
	# Lightning conductivity: x1.5 vs WET.
	d = _make_dummy()
	_Emitter.call("apply_to_target", d, "water", 5.0, Vector3.ZERO)
	_Emitter.call("apply_to_target", d, "lightning", 20.0, Vector3.ZERO)
	_check(is_equal_approx(d.hp, 65.0),
		"emitters: lightning vs WET deals x1.5 — 5 water + 30 lightning = 65 hp (got %.1f)" % d.hp)
	d.queue_free()
	# Lightning chain: wet target chains 50% to the nearest other foe.
	var e1 := _make_dummy()
	e1.position = Vector3(1, 0, 0)
	e1.add_to_group("enemy")
	var e2 := _make_dummy()
	e2.position = Vector3(2, 0, 0)
	e2.add_to_group("enemy")
	var emitter: Variant = _Emitter.call("spawn_field", root, "lightning", Vector3.ZERO, 4.0, 60.0, 40.0)
	_Emitter.call("apply_to_target", e1, "water", 0.0, Vector3.ZERO)
	(emitter as Node).call("_tick_field")
	_check(is_equal_approx(e1.hp, 70.0),
		"emitters: field tick — wet target takes 30 (20 x 1.5), hp %.1f" % e1.hp)
	_check(is_equal_approx(e2.hp, 70.0),
		"emitters: field tick — chain: dry neighbour takes 20 direct + 10 chain = 30, hp %.1f" % e2.hp)
	if emitter is Node:
		(emitter as Node).queue_free()
	e1.queue_free()
	e2.queue_free()
	# One-shot burst.
	d = _make_dummy()
	d.position = Vector3(1, 0, 0)
	d.add_to_group("enemy")
	var burst: Variant = _Emitter.call("spawn_burst", root, "fire", Vector3.ZERO, 4.0, 25.0)
	_check(burst is Node and is_equal_approx(d.hp, 75.0),
		"emitters: spawn_burst fire 25 deals 25 once to a foe in radius (hp %.1f)" % d.hp)
	d.queue_free()
	# Forge structure: ForgeBuilder builds an emitter pylon per element.
	var fake_player := Node3D.new()
	fake_player.name = "EmitterProbePlayer"
	fake_player.position = Vector3.ZERO
	root.add_child(fake_player)
	for e in EMITTER_ELEMENTS:
		var spec := {"spec_version": 1, "action": "spawn", "target": "emitter",
			"params": {"element": e, "position": [0, 0, 3], "radius": 4.0, "duration_sec": 10.0, "damage_per_sec": 10.0},
			"cost": 200, "ttl": 0}
		var msg: String = str(_ForgeBuilder.call("build", spec, {"player": fake_player, "root": root}))
		var built: Variant = _ForgeBuilder.get("last_built_node")
		_check(not msg.begins_with("FORGE_FAIL") and built is Node
				and str((built as Node).get("element")) == e,
			"emitters: ForgeBuilder builds a %s emitter pylon (msg: '%s')" % [e, msg])
	fake_player.queue_free()
	# Forge gate: the prompt's own examples must validate.
	var gate_emitter := {"spec_version": 1, "action": "spawn", "target": "emitter",
		"params": {"element": "lightning", "position": "near_player", "radius": 4, "duration_sec": 10, "damage_per_sec": 10},
		"cost": 200, "ttl": 0}
	var v_emitter: Variant = _ForgeLLM.call("validate_modspec", gate_emitter)
	_check(v_emitter is Array and bool((v_emitter as Array)[0]),
		"emitters: Forge gate accepts the prompt's emitter example (verdict: %s)" % str(v_emitter))
	var gate_turret := {"spec_version": 1, "action": "spawn", "target": "turret",
		"params": {"position": "near_player", "duration_sec": 45, "element": "lightning"},
		"cost": 325, "ttl": 0}
	var v_turret: Variant = _ForgeLLM.call("validate_modspec", gate_turret)
	_check(v_turret is Array and bool((v_turret as Array)[0]),
		"emitters: Forge gate accepts the prompt's lightning turret example (verdict: %s)" % str(v_turret))
	var gate_weapon := {"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "manticore", "element": "fire"},
		"cost": 355, "ttl": 0}
	var v_weapon: Variant = _ForgeLLM.call("validate_modspec", gate_weapon)
	_check(v_weapon is Array and bool((v_weapon as Array)[0]),
		"emitters: Forge gate accepts weapon + element composition (verdict: %s)" % str(v_weapon))
	# Turret / weapon element wiring (source: the hit paths read the meta).
	var turret_src: String = _sources.get("res://scripts/forge/forge_turret.gd", "")
	_check(turret_src.contains("get_meta(\"element\"") and turret_src.contains("apply_to_target"),
		"emitters: turret _fire reads its element meta and deals damage via apply_to_target")
	var weapon_src: String = _sources.get("res://scripts/weapons/weapon_base.gd", "")
	_check(weapon_src.contains("elemental_ammo") and weapon_src.contains("apply_to_target"),
		"emitters: weapon hitscan reads elemental_ammo meta and deals damage via apply_to_target")
	var builder_src: String = _sources.get("res://scripts/forge/forge_builder.gd", "")
	_check(builder_src.contains("set_meta(\"element\"") and builder_src.contains("set_meta(\"elemental_ammo\""),
		"emitters: ForgeBuilder stamps element meta on turrets + elemental_ammo meta on weapons")
	# ModAPI: mods can spawn emitters + fire elemental bursts.
	var api_player := Node3D.new()
	api_player.name = "EmitterApiPlayer"
	root.add_child(api_player)
	var api: Variant = _ModAPI.new(api_player, root)
	var api_node: Variant = api.call("spawn_elemental_emitter", "fire", Vector3.ZERO, 4.0, 10.0, 10.0)
	_check(api_node is Node and str((api_node as Node).get("element")) == "fire",
		"emitters: ModAPI.spawn_elemental_emitter returns a fire emitter node")
	if api_node is Node:
		(api_node as Node).queue_free()
	d = _make_dummy()
	d.position = Vector3(1, 0, 0)
	d.add_to_group("enemy")
	api.call("fire_effect", "elemental", Vector3.ZERO, 4.0, 20.0, 1.0, "fire")
	_check(is_equal_approx(d.hp, 80.0),
		"emitters: ModAPI.fire_effect('elemental', fire) deals 20 to a foe in radius (hp %.1f)" % d.hp)
	d.queue_free()
	api_player.queue_free()


# --- 7. Forge spawn-by-type ----------------------------------------------------

func _test_spawn_by_type() -> void:
	var spec := {"spec_version": 1, "action": "spawn", "target": "enemy_spawn",
		"params": {"type": "brute", "count": 1, "creature_type": "undead"},
		"cost": 150, "ttl": 0}
	var verdict: Variant = _ForgeLLM.call("validate_modspec", spec)
	_check(verdict is Array and bool((verdict as Array)[0]),
		"spawn-by-type: Forge gate accepts enemy_spawn {brute, undead, 1} (verdict: %s)" % str(verdict))
	var spec2 := {"spec_version": 1, "action": "spawn", "target": "enemy_spawn",
		"params": {"type": "warlord", "count": 1, "creature_type": "fiend"},
		"cost": 150, "ttl": 0}
	var verdict2: Variant = _ForgeLLM.call("validate_modspec", spec2)
	_check(verdict2 is Array and bool((verdict2 as Array)[0]),
		"spawn-by-type: Forge gate accepts enemy_spawn {warlord, fiend, 1}")
	var bad := {"spec_version": 1, "action": "spawn", "target": "enemy_spawn",
		"params": {"type": "brute", "count": 1, "creature_type": "bogus"},
		"cost": 150, "ttl": 0}
	var verdict_bad: Variant = _ForgeLLM.call("validate_modspec", bad)
	_check(verdict_bad is Array and not bool((verdict_bad as Array)[0]),
		"spawn-by-type: Forge gate REJECTS an unknown creature_type (verdict: %s)" % str(verdict_bad))
	# Builder carries the type through to the wave manager (no fallback).
	var wm := FakeWaveManager.new()
	wm.name = "FakeWaveManager"
	wm.add_to_group("wave_manager")
	root.add_child(wm)
	var msg: String = str(_ForgeBuilder.call("_build_enemy_spawn",
		{"type": "brute", "creature_type": "undead", "count": 1}, root))
	var carried := false
	if not wm.received.is_empty():
		var got: Dictionary = wm.received[0]
		carried = str(got.get("creature_type", "")) == "undead" and str(got.get("type", "")) == "brute"
	_check(carried,
		"spawn-by-type: builder passes {type:brute, creature_type:undead} to the wave manager (mod: %s; msg: '%s')" % [
			str(wm.received[0]) if not wm.received.is_empty() else "<none>", msg])
	wm.queue_free()
	# Offline parser: "spawn an undead brute" / "a fiend warlord".
	var off: Variant = _ForgeLLM.call("_offline_enemy_spawn", "spawn an undead brute")
	_check(off is Dictionary and str(((off as Dictionary).get("params", {}) as Dictionary).get("type", "")) == "brute"
			and str(((off as Dictionary).get("params", {}) as Dictionary).get("creature_type", "")) == "undead",
		"spawn-by-type: offline parser maps 'spawn an undead brute' to brute + undead (got %s)" % str(off))
	var off2: Variant = _ForgeLLM.call("_offline_enemy_spawn", "a fiend warlord")
	_check(off2 is Dictionary and str(((off2 as Dictionary).get("params", {}) as Dictionary).get("type", "")) == "warlord"
			and str(((off2 as Dictionary).get("params", {}) as Dictionary).get("creature_type", "")) == "fiend",
		"spawn-by-type: offline parser maps 'a fiend warlord' to warlord + fiend (got %s)" % str(off2))
	var off3: Variant = _ForgeLLM.call("_offline_enemy_spawn", "spawn enemies")
	_check(off3 is Dictionary and str(((off3 as Dictionary).get("params", {}) as Dictionary).get("type", "")) == "grunt"
			and not ((off3 as Dictionary).get("params", {}) as Dictionary).has("creature_type"),
		"spawn-by-type: offline parser maps bare 'spawn enemies' to grunt x3 with NO creature_type (got %s)" % str(off3))
	# Prompt documents it.
	var forge_text: String = _sources.get("res://scripts/forge/forge_llm.gd", "")
	_check(forge_text.contains("spawn an undead brute"),
		"spawn-by-type: Forge prompt documents 'spawn an undead brute'")


# --- 8. prompts list the new catalogs -------------------------------------------

func _test_prompts() -> void:
	var forge_text: String = _sources.get("res://scripts/forge/forge_llm.gd", "")
	var creator_text: String = _sources.get("res://scripts/mods/mod_creator.gd", "")
	var chat_text: String = _sources.get("res://scripts/mods/chat_prompt.gd", "")
	_check(_all_words(forge_text, CREATURE_TYPES),
		"prompts: Forge prompt lists all 14 creature types")
	_check(_all_words(forge_text, CLASSES),
		"prompts: Forge prompt lists all 12 classes")
	_check(_all_words(forge_text, EMITTER_ELEMENTS),
		"prompts: Forge prompt lists all 10 emitter elements")
	_check(_all_words(forge_text, SCHOOLS),
		"prompts: Forge prompt lists all 8 spell schools")
	_check(_all_words(forge_text, ABILITIES_FULL),
		"prompts: Forge prompt lists the ability scores")
	# Creator addendum (mod_creator.gd) lists creature types. The
	# mod-GENERATION prompt lives in forge_llm.gd (GENERATION_SYSTEM_PROMPT):
	# it must list types + emitters + abilities (it does) and schools
	# (it does not — real gap: nothing tells the mod LLM about schools).
	_check(_all_words(creator_text, CREATURE_TYPES),
		"prompts: creator addendum lists all 14 creature types")
	var gen_idx := forge_text.find("GENERATION_SYSTEM_PROMPT")
	var gen_text := forge_text.substr(gen_idx) if gen_idx >= 0 else ""
	_check(_all_words(gen_text, CREATURE_TYPES),
		"prompts: mod-generation prompt lists all 14 creature types")
	_check(_all_words(gen_text, EMITTER_ELEMENTS),
		"prompts: mod-generation prompt lists all 10 emitter elements")
	_check(_all_words(gen_text, ABILITIES_FULL),
		"prompts: mod-generation prompt lists the ability scores")
	_check(_all_words(gen_text, SCHOOLS),
		"prompts: mod-generation prompt lists all 8 spell schools")
	_check(_all_words(chat_text, CLASSES),
		"prompts: chat prompt lists all 12 classes")
	_check(_all_words(chat_text, SCHOOLS),
		"prompts: chat prompt lists all 8 spell schools")


static func _all_words(text: String, words: Array) -> bool:
	for w in words:
		if not _has_word_static(text, str(w)):
			return false
	return true


static func _has_word_static(text: String, word: String) -> bool:
	var low := text.to_lower()
	var w := word.to_lower()
	var idx := 0
	while true:
		var at := low.find(w, idx)
		if at < 0:
			return false
		var before_ok := at == 0 or not _is_word_char(low[at - 1])
		var after_idx := at + w.length()
		var after_ok := after_idx >= low.length() or not _is_word_char(low[after_idx])
		if before_ok and after_ok:
			return true
		idx = at + 1
	return false
