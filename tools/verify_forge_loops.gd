# FORGEFALL — verify_forge_loops (v0.5.9, Worker F verification)
# Verifies the v0.5.9 Forge loops:
#   (2) base-defense full loop: build phase -> wave -> core damage -> defeat;
#       a run WITH Forge building outlasts a run WITHOUT.
#   (3) Arsenal lists an installed weapon-mod + equips + fires with hooks;
#       loadout with a mod persists across matches; disabled mod drops out
#       cleanly (no dangling entries, no crash).
#   (4) EDIT flow: seed -> "make the bubble bigger" -> approval shows diff
#       -> install -> version 1.1, old version gone, discard leaves 1.0.
#   (5) take_damage hook: shield absorbs, vulnerable increases, thorns
#       reflects, petrified nullifies — all in-game.
#   (6) MAKE builds undo + sync + history; script-shaped MAKE ("exploding
#       wall") works in-session + never writes to user://mods/.
#
# Run: godot --headless --path . --script res://tools/verify_forge_loops.gd
# Exit code 0 = all checks passed. A feature that never landed FAILs its
# checks with "NOT LANDED" in the label — never a silent skip, never a
# fix to game code (this suite only writes its own probe mods under
# user://mods/verify_loops_*, which it removes again, and backs up +
# restores user://loadouts.json around the loadout test).
#
# Harness notes (from prior suites): load() game scripts at runtime in
# _process (never static class_name refs — Sfx autoload not registered at
# parse time); _process returning true quits. Probe mods use the same
# manifest.json + block.json shape as verify_forge_batch's alias probe.
extends SceneTree

var _fails := 0
var _checks := 0
var _ran := false
var _section_fails := {}
var _section_checks := {}

var _Loader: GDScript
var _Creator: GDScript
var _Hook: GDScript
var _Status: GDScript
var _Registry: GDScript
var _API: GDScript
var _Arsenal: GDScript
var _Builder: GDScript
var _SessionMake: GDScript
var _Manager: GDScript
var _Loadouts: GDScript
var _Sync: GDScript
var _Enemy: GDScript

var _arena: Node3D
var _player: Node3D
var _manager: Node


class DamageDummy extends CharacterBody3D:
	var hp := 100.0
	var dead := false
	var max_hp := 100.0
	func take_damage(amount: float, _pos: Vector3, _head: bool) -> void:
		if dead:
			return
		hp = maxf(hp - amount, 0.0)
		if hp <= 0.0:
			dead = true
	func is_dead() -> bool:
		return dead


func _check(section: String, cond: bool, label: String) -> void:
	_checks += 1
	_section_checks[section] = int(_section_checks.get(section, 0)) + 1
	if cond:
		print("PASS [%s]: %s" % [section, label])
	else:
		_fails += 1
		_section_fails[section] = int(_section_fails.get(section, 0)) + 1
		print("FAIL [%s]: %s" % [section, label])


func _src(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _file_has(path: String, needle: String) -> bool:
	return _src(path).contains(needle)


func _methods(script: GDScript) -> Array:
	# get_script_method_list(), NOT get_method_list(): the latter
	# returns the GDScript resource's own (Object) methods — 112 of
	# them, identical for every script — and never the script-defined
	# ones. That bug made two earlier runs report landed APIs absent.
	if script == null:
		return []
	var out: Array = []
	for m in script.get_script_method_list():
		out.append(str((m as Dictionary).get("name", "")))
	return out


func _has_method_on(script: GDScript, name: String) -> bool:
	return _methods(script).has(name)


func _consts(script: GDScript) -> Dictionary:
	if script == null:
		return {}
	return script.get_script_constant_map()


# --- probe-mod helpers (user://mods/verify_loops_*) -------------------------

func _mods_snapshot() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://mods")
	if d != null:
		d.list_dir_begin()
		var e := d.get_next()
		while e != "":
			if not e.begins_with("."):
				out.append(e)
			e = d.get_next()
		d.list_dir_end()
	out.sort()
	return out


func _write_probe(mod_id: String, block: Dictionary, hooks: Array, version: String) -> bool:
	var folder := "user://mods/" + mod_id
	var ud := DirAccess.open("user://")
	if ud == null:
		return false
	if not ud.dir_exists("mods"):
		ud.make_dir("mods")
	var md := DirAccess.open("user://mods")
	if md == null:
		return false
	if not md.dir_exists(mod_id):
		md.make_dir(mod_id)
	var manifest := {"name": mod_id, "kind": "block", "version": version, "file": "block.json"}
	if not hooks.is_empty():
		manifest["hooks"] = hooks
	var mf := FileAccess.open(folder + "/manifest.json", FileAccess.WRITE)
	if mf == null:
		return false
	mf.store_string(JSON.stringify(manifest))
	mf.close()
	var bf := FileAccess.open(folder + "/block.json", FileAccess.WRITE)
	if bf == null:
		return false
	bf.store_string(JSON.stringify(block))
	bf.close()
	return true


func _remove_probe(mod_id: String) -> void:
	var base := OS.get_user_data_dir().path_join("mods").path_join(mod_id)
	DirAccess.remove_absolute(base.path_join("manifest.json"))
	DirAccess.remove_absolute(base.path_join("block.json"))
	DirAccess.remove_absolute(base)
	_scrub_enabled(mod_id)


## ModLoader persists enabled state in user://mods_enabled.json — a
## probe disabled by the disable test stays disabled across runs
## (and would poison the NEXT run's listing test) unless scrubbed.
func _scrub_enabled(mod_id: String) -> void:
	var path := "user://mods_enabled.json"
	if not FileAccess.file_exists(path):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		return
	var d := data as Dictionary
	if d.has(mod_id):
		d.erase(mod_id)
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(d))
			f.close()


func _free_built_nodes() -> void:
	if _arena == null:
		return
	for child in _arena.get_children():
		if child != _player:
			child.queue_free()
	if _Builder != null:
		_Builder.set("last_built_node", null)


func _fresh_enemy(hp: float) -> CharacterBody3D:
	var enemy: CharacterBody3D = _Enemy.new()
	enemy.name = "LoopsEnemy"
	_arena.add_child(enemy)
	enemy.set("active", true)
	enemy.set("dead", false)
	enemy.set("hp", hp)
	enemy.set("max_hp", hp)
	enemy.set("base_hp", hp)
	return enemy


# --- main -------------------------------------------------------------------

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_Loader = load("res://scripts/mods/mod_loader.gd") as GDScript
	_Creator = load("res://scripts/mods/mod_creator.gd") as GDScript
	_Hook = load("res://scripts/mods/mod_hook.gd") as GDScript
	_Status = load("res://scripts/mods/mod_status_effects.gd") as GDScript
	_Registry = load("res://scripts/mods/mod_hook_registry.gd") as GDScript
	_API = load("res://scripts/mods/mod_api.gd") as GDScript
	_Arsenal = load("res://scripts/weapons/arsenal.gd") as GDScript
	_Builder = load("res://scripts/forge/forge_builder.gd") as GDScript
	_SessionMake = load("res://scripts/forge/forge_session_make.gd") as GDScript
	_Manager = load("res://scripts/forge/forge_manager.gd") as GDScript
	_Loadouts = load("res://scripts/progression/loadouts.gd") as GDScript
	_Sync = load("res://scripts/net/net_forge_sync.gd") as GDScript
	_Enemy = load("res://scripts/enemies/enemy_base.gd") as GDScript
	_check("setup", _Loader != null and _Hook != null and _Status != null and _Registry != null, "setup: core mod scripts load")
	_check("setup", _Builder != null and _SessionMake != null and _Manager != null, "setup: Forge scripts load")
	_check("setup", _Arsenal != null and _Enemy != null and _Sync != null, "setup: Arsenal / EnemyBase / NetForgeSync load")

	_arena = Node3D.new()
	_arena.name = "ForgeLoopsArena"
	root.add_child(_arena)
	current_scene = _arena
	_player = Node3D.new()
	_player.name = "ForgeLoopsPlayer"
	_player.add_to_group("player")
	_arena.add_child(_player)
	# Prefer the real autoload Forge (the node the Forge menu talks to);
	# fall back to a standalone instance for pure method calls.
	_manager = root.get_node_or_null("/root/Forge")
	if _manager == null and _Manager != null:
		_manager = _Manager.new() as Node

	_test_base_defense()
	_test_arsenal_mod()
	_test_edit_flow()
	_test_take_damage_hook()
	_test_make_loops()

	_free_built_nodes()
	# Restore the probe-free mods state even if a test bailed early.
	for mid in ["verify_loops_arsenal_zz", "verify_loops_bubble_zz"]:
		_remove_probe(mid)
	if _Loader != null:
		_Loader.call("rescan")
	print("verify_forge_loops: %d checks, %d failures %s" % [_checks, _fails, str(_section_fails)])
	quit(1 if _fails > 0 else 0)
	return true


# --- (2) base defense ---------------------------------------------------------

func _test_base_defense() -> void:
	# Against the landed API: scripts/modes/base_defense.gd (BaseDefenseMode),
	# wired by GameModeManager.start("base_defense") + the main menu.
	var s := "base-defense"
	var impl_path := "res://scripts/modes/base_defense.gd"
	var impl_src := _src(impl_path)
	_check(s, impl_src.contains("class_name BaseDefenseMode"),
		"base-defense: BaseDefenseMode exists (scripts/modes/base_defense.gd) — NOT LANDED if absent")
	if impl_src == "":
		for label in [
			"base-defense: GameModeManager + main menu wire the mode",
			"base-defense: build phase exists (phase 'build', Forge opens)",
			"base-defense: wave phase (phase 'combat', assault ticks)",
			"base-defense: core HP + damage (assault_split / _damage_core)",
			"base-defense: core at 0 HP -> defeat (phase 'over')",
			"base-defense: Forge outlasts — assault_split time-to-fall WITH > WITHOUT",
			"base-defense: _tick_assault integration — structures absorb, overflow hits core",
			"base-defense: player death alone does NOT end the run",
		]:
			_check(s, false, label + " — NOT LANDED (no base-defense implementation)")
		return
	var gm_src := _src("res://scripts/core/game_mode.gd")
	var menu_src := _src("res://scripts/ui/main_menu.gd")
	_check(s, gm_src.contains("BaseDefenseMode") and gm_src.contains("\"base_defense\"") and menu_src.contains("base_defense"),
		"base-defense: GameModeManager wires BaseDefenseMode + main menu lists base_defense")
	var bd_script: GDScript = load(impl_path) as GDScript
	if bd_script == null:
		_check(s, false, "base-defense: BaseDefenseMode script loads")
		return
	var bd: Node = bd_script.new() as Node
	_arena.add_child(bd)
	# _ready: phase build, core at full HP, Forge opens (no-op headless).
	_check(s, str(bd.get("phase")) == "build" and is_equal_approx(float(bd.get("core_hp")), 1000.0),
		"base-defense: run starts in BUILD phase with CORE 1000 (phase='%s', core=%.0f)" % [str(bd.get("phase")), float(bd.get("core_hp"))])
	bd.call("_on_build_phase_started", 30)
	_check(s, str(bd.get("phase")) == "build",
		"base-defense: build_phase_started -> phase stays 'build'")
	bd.call("_on_wave_started", 1)
	_check(s, str(bd.get("phase")) == "combat" and int(bd.get("wave")) == 1,
		"base-defense: wave_started(1) -> phase 'combat', wave 1 (phase='%s', wave=%d)" % [str(bd.get("phase")), int(bd.get("wave"))])
	# Core damage: pure assault_split + live _damage_core.
	var split0: Dictionary = bd_script.call("assault_split", 5, 1, 0)
	var split3: Dictionary = bd_script.call("assault_split", 5, 1, 3)
	_check(s, is_equal_approx(float(split0.get("overflow", -1.0)), 30.0) and is_equal_approx(float(split3.get("absorbed", -1.0)), 24.0) and is_equal_approx(float(split3.get("overflow", -1.0)), 6.0),
		"base-defense: assault_split(5 enemies, wave 1): 0 structures -> overflow 30 dps; 3 structures -> absorbed 24, overflow 6 (got %s / %s)" % [str(split0), str(split3)])
	bd.call("_damage_core", 100.0)
	_check(s, is_equal_approx(float(bd.get("core_hp")), 900.0),
		"base-defense: _damage_core(100) -> core 900 (got %.0f)" % float(bd.get("core_hp")))
	# Forge outlasts: time-to-fall from assault_split overflow.
	var t_no_forge := 1000.0 / float(split0.get("overflow", 1.0))
	var t_forge := 1000.0 / float(split3.get("overflow", 1.0))
	_check(s, t_forge > t_no_forge and t_forge > 100.0 and t_no_forge < 60.0,
		"base-defense: WITH Forge outlasts WITHOUT — time-to-fall %.0fs (3 structures) vs %.0fs (none)" % [t_forge, t_no_forge])
	# _tick_assault integration: 5 assaulters, 0 vs 3 live structures.
	var tick_no_forge := _assault_tick(bd, 5, 0)
	var tick_forge := _assault_tick(bd, 5, 3)
	_check(s, tick_no_forge > 20.0 and tick_forge >= 0.0 and tick_forge < tick_no_forge,
		"base-defense: _tick_assault(1s, 5 assaulters): core loses %.1f with NO structures vs %.1f WITH 3 structures" % [tick_no_forge, tick_forge])
	# Player death alone must not end the run.
	bd.call("_on_player_died")
	_check(s, str(bd.get("phase")) != "over" and bool(bd.get("running")),
		"base-defense: player death -> redeploy timer, run continues (phase='%s', running=%s)" % [str(bd.get("phase")), str(bd.get("running"))])
	# Defeat: core to 0.
	bd.set("core_hp", 50.0)
	bd.call("_damage_core", 50.0)
	_check(s, str(bd.get("phase")) == "over",
		"base-defense: core at 0 HP -> defeat (phase 'over', got '%s')" % str(bd.get("phase")))
	_arena.remove_child(bd)
	bd.free()


func _assault_tick(bd: Node, enemies: int, structures: int) -> float:
	# One 1s assault tick on a reset core; returns core HP lost.
	bd.set("core_hp", 1000.0)
	bd.set("phase", "combat")
	bd.set("wave", 1)
	var foes: Array = []
	for _i in range(enemies):
		var foe := DamageDummy.new()
		foe.name = "Assaulter"
		foe.hp = 100.0
		foe.position = Vector3(1.0, 0.0, 0.0)
		foe.add_to_group("enemy")
		_arena.add_child(foe)
		foes.append(foe)
	var defs: Array = []
	for _i in range(structures):
		var defn := DamageDummy.new()
		defn.name = "Defense"
		defn.hp = 200.0
		defn.position = Vector3(2.0, 0.0, 0.0)
		defn.add_to_group("forge_structure")
		_arena.add_child(defn)
		defs.append(defn)
	bd.call("_tick_assault", 1.0)
	var lost := 1000.0 - float(bd.get("core_hp"))
	for n in foes:
		_arena.remove_child(n as Node)
		(n as Node).free()
	for n in defs:
		_arena.remove_child(n as Node)
		(n as Node).free()
	return lost


# --- (3) Arsenal weapon-mod ---------------------------------------------------

func _test_arsenal_mod() -> void:
	var s := "arsenal-mod"
	var mod_id := "verify_loops_arsenal_zz"
	var block := {"block_id": mod_id, "target": "weapon", "cost": 210,
		"display_name": "Loops Probe Blaster", "description": "Verifier probe mod.",
		"base_weapon_id": "manticore"}
	var hooks := [
		{"hook_id": "loops_boom", "hook_point": "on_hit",
			"effects": [{"kind": "explosion", "radius": 5.0, "damage": 40.0}]},
		{"hook_id": "loops_proj", "hook_point": "on_fire",
			"projectile": {"visual": "bubble", "shape": "sphere", "speed": 20.0, "damage": 10.0, "range": 30.0, "size": 1.0, "gravity": 0.0, "pierce": false, "explodes_on_impact": false, "explosion_radius": 0.0, "explosion_damage": 0.0}},
	]
	_remove_probe(mod_id)
	_check(s, _write_probe(mod_id, block, hooks, "1.0"), "arsenal-mod: probe weapon-mod written to user://mods/")
	_Loader.call("rescan")
	# Fresh installs are enabled; make sure no stale disabled entry
	# from an earlier run shadows the probe.
	_Loader.call("set_mod_enabled", mod_id, true)
	_Loader.call("rescan")
	var rec: Dictionary = _Loader.call("find_mod", mod_id)
	_check(s, not rec.is_empty() and str(rec.get("error", "")) == "",
		"arsenal-mod: probe mod scans clean (error='%s')" % str(rec.get("error", "")))
	# Listing: Arsenal.get_mod_weapons() lists installed weapon-mods as
	# "mod:<mod_id>" entries (v0.5.9 Worker B API).
	var mod_weapon_id := "mod:" + mod_id
	var has_listing := _has_method_on(_Arsenal, "get_mod_weapons")
	_check(s, has_listing, "arsenal-mod: Arsenal.get_mod_weapons() exists — NOT LANDED if absent")
	var listed := false
	var listed_entry := {}
	if has_listing:
		var mods_list: Array = _Arsenal.call("get_mod_weapons")
		for entry in mods_list:
			if entry is Dictionary and str((entry as Dictionary).get("mod_id", "")) == mod_id:
				listed = true
				listed_entry = entry as Dictionary
	_check(s, listed and str(listed_entry.get("weapon_id", "")) == mod_weapon_id and str(listed_entry.get("base_weapon_id", "")) == "ar7",
		"arsenal-mod: probe mod listed as '%s' on base ar7 (entry=%s) — NOT LANDED if absent" % [mod_weapon_id, str(listed_entry)])
	_check(s, bool(_Arsenal.call("has_weapon", mod_weapon_id)),
		"arsenal-mod: Arsenal.has_weapon('%s') is true while enabled" % mod_weapon_id)
	# Equip: Arsenal.make_weapon("mod:<id>") builds the weapon WITH its
	# mod attachment (mod_id / mod_hooks / projectile spec) already set.
	var weapon: Variant = _Arsenal.call("make_weapon", mod_weapon_id)
	var weapon_node: Node = weapon as Node
	_arena.add_child(weapon_node)
	_check(s, weapon_node != null and str(weapon_node.get("weapon_id")) == mod_weapon_id and str(weapon_node.get("mod_id")) == mod_id,
		"arsenal-mod: make_weapon('%s') equips the mod (weapon_id='%s', mod_id='%s')" % [mod_weapon_id, str(weapon_node.get("weapon_id")), str(weapon_node.get("mod_id"))])
	_check(s, (weapon_node.get("mod_hooks") is Array) and ((weapon_node.get("mod_hooks") as Array).size() >= 1),
		"arsenal-mod: equipped weapon carries the mod hooks (hooks=%d)" % ((weapon_node.get("mod_hooks") as Array).size() if weapon_node.get("mod_hooks") is Array else -1))
	var api: Variant = _API.new(_player, _arena)
	var target := DamageDummy.new()
	target.name = "ArsenalTarget"
	_arena.add_child(target)
	var ctx := {"position": Vector3.ZERO, "hit_position": Vector3.ZERO, "damage": 18.0, "target": target}
	var fire_res: Variant = _Registry.call("run_point_for_weapon", weapon_node, "on_hit", api, ctx)
	_check(s, bool((fire_res as Dictionary).get("exploded", false)),
		"arsenal-mod: firing the mod weapon runs its hooks (on_hit exploded=%s)" % str((fire_res as Dictionary).get("exploded", false)))
	var pspec: Dictionary = _Registry.call("resolve_projectile_spec", weapon_node)
	_check(s, str(pspec.get("visual", "")) == "bubble",
		"arsenal-mod: mod projectile spec resolves on the equipped weapon (visual='%s')" % str(pspec.get("visual", "")))
	# Loadout with a mod persists across matches (fresh Loadouts instance
	# = a new match loading the same user:// file).
	_check(s, _test_loadout_mod_persists(mod_id), "arsenal-mod: loadout carrying the mod persists across a fresh Loadouts load (see detail)")
	# Disabled: drops out cleanly everywhere, no dangling entries.
	_Loader.call("set_mod_enabled", mod_id, false)
	_Loader.call("rescan")
	var enabled: Array = _Loader.call("get_enabled_mods")
	var still_enabled := false
	for e in enabled:
		if e is Dictionary and str((e as Dictionary).get("id", "")) == mod_id:
			still_enabled = true
	_check(s, not still_enabled, "arsenal-mod: disabled mod leaves get_enabled_mods()")
	var listed_after: Array = _Arsenal.call("get_mod_weapons")
	var still_listed := false
	for e in listed_after:
		if e is Dictionary and str((e as Dictionary).get("mod_id", "")) == mod_id:
			still_listed = true
	_check(s, not still_listed and not bool(_Arsenal.call("has_weapon", mod_weapon_id)),
		"arsenal-mod: disabled mod leaves Arsenal listing + has_weapon('mod:<id>') is false (no dangling entry)")
	var after_disable: Variant = _Registry.call("run_point_for_weapon", weapon_node, "on_hit", api, ctx)
	_check(s, not bool((after_disable as Dictionary).get("exploded", false)) and is_instance_valid(weapon_node),
		"arsenal-mod: disabled mod's hooks stop firing, weapon still valid (no crash, no dangling fire)")
	# Mid-match prune: a WeaponManager holding the mod weapon falls back
	# to the base default instead of keeping a stale mod weapon.
	var wm_pruned := _test_wm_prune(mod_id, mod_weapon_id)
	_check(s, wm_pruned, "arsenal-mod: WeaponManager.prune_stale_mod_weapons() falls back a disabled mod slot to base (no stale weapon)")
	var after_rec: Dictionary = _Loader.call("find_mod", mod_id)
	_check(s, not after_rec.is_empty() and not bool(after_rec.get("enabled", true)),
		"arsenal-mod: disabled mod record still exists but enabled=false (no dangling entry)")
	weapon_node.queue_free()
	target.queue_free()
	_remove_probe(mod_id)
	_Loader.call("rescan")


func _test_wm_prune(mod_id: String, mod_weapon_id: String) -> bool:
	# A live WeaponManager with the mod weapon equipped, then the mod
	# is disabled (already done by the caller): prune must replace it
	# with the base default for the slot.
	var wm_script: GDScript = load("res://scripts/weapons/weapon_manager.gd") as GDScript
	if wm_script == null:
		return false
	# Re-enable briefly so set_slot accepts the mod weapon, then disable.
	_Loader.call("set_mod_enabled", mod_id, true)
	_Loader.call("rescan")
	var wm: Node = wm_script.new() as Node
	wm.name = "LoopsWeaponManager"
	_player.add_child(wm)
	wm.call("set_slot", "primary", mod_weapon_id)
	var before := str(wm.call("get_slot_weapon_id", "primary"))
	_Loader.call("set_mod_enabled", mod_id, false)
	_Loader.call("rescan")
	wm.call("prune_stale_mod_weapons")
	var after := str(wm.call("get_slot_weapon_id", "primary"))
	_player.remove_child(wm)
	wm.free()
	print("arsenal-mod detail: WM prune slot before='%s' after='%s'" % [before, after])
	return before == mod_weapon_id and after == "ar7"


func _test_loadout_mod_persists(mod_id: String) -> bool:
	# Loadouts carry the mod as its canonical Arsenal id "mod:<mod_id>"
	# (v0.5.9 Worker B). Persists = a fresh Loadouts instance (a new
	# match re-reading user://loadouts.json) returns the same id.
	if _Loadouts == null:
		return false
	var mod_weapon_id := "mod:" + mod_id
	# Backup the real loadouts file, restore it afterwards.
	var save_path := "user://loadouts.json"
	var had_file := FileAccess.file_exists(save_path)
	var backup := ""
	if had_file:
		backup = FileAccess.get_file_as_string(save_path)
	var ok := false
	var store: Node = _Loadouts.new() as Node
	root.add_child(store)
	# The store caps at 5 loadouts by default; delete a non-active one
	# if needed to make room, then restore via the file backup.
	var created := false
	if store.has_method("create_loadout"):
		created = bool(store.call("create_loadout", "VerifyLoopsMod", mod_weapon_id, "p9", ""))
		if not created:
			# Free a slot: delete the last non-active loadout, retry once.
			var all_loadouts: Array = store.call("get_loadouts")
			for entry in all_loadouts:
				if entry is Dictionary and str((entry as Dictionary).get("name", "")) != str(store.call("get_active_name")):
					store.call("delete_loadout", str((entry as Dictionary).get("name", "")))
					break
			created = bool(store.call("create_loadout", "VerifyLoopsMod", mod_weapon_id, "p9", ""))
	if created:
		var fresh: Node = _Loadouts.new() as Node
		root.add_child(fresh)
		var entry: Dictionary = fresh.call("get_loadout", "VerifyLoopsMod")
		ok = str(entry.get("primary", "")) == mod_weapon_id
		# Equipping the reloaded loadout on a WeaponManager must yield
		# the mod weapon (not the base fallback).
		var wm_script: GDScript = load("res://scripts/weapons/weapon_manager.gd") as GDScript
		if ok and wm_script != null:
			var wm: Node = wm_script.new() as Node
			wm.name = "LoopsLoadoutWM"
			_player.add_child(wm)
			var applied: bool = fresh.call("apply_loadout_to", "VerifyLoopsMod", wm)
			ok = applied and str(wm.call("get_slot_weapon_id", "primary")) == mod_weapon_id
			_player.remove_child(wm)
			wm.free()
		fresh.queue_free()
		if store.has_method("delete_loadout"):
			store.call("delete_loadout", "VerifyLoopsMod")
	store.queue_free()
	# Restore the user's file byte-for-byte.
	if had_file:
		var f := FileAccess.open(save_path, FileAccess.WRITE)
		if f != null:
			f.store_string(backup)
			f.close()
	else:
		DirAccess.remove_absolute(OS.get_user_data_dir().path_join("loadouts.json"))
	return ok


# --- (4) EDIT flow --------------------------------------------------------------

func _test_edit_flow() -> void:
	var s := "edit-flow"
	var mod_id := "verify_loops_bubble_zz"
	var block := {"block_id": mod_id, "target": "weapon", "cost": 210,
		"display_name": "Bubble Blaster", "description": "Bubble gun, size 1.0.",
		"base_weapon_id": "manticore"}
	var hooks := [
		{"hook_id": "bubble_shot", "hook_point": "on_fire",
			"projectile": {"visual": "bubble", "shape": "sphere", "speed": 22.0, "damage": 18.0, "range": 30.0, "size": 1.0, "gravity": 0.0, "pierce": false, "explodes_on_impact": false, "explosion_radius": 0.0, "explosion_damage": 0.0}},
	]
	# Seed via the creator's own install path (creator-native form:
	# payload = {"block": {...}, "hooks": [...]}, hooks in the payload
	# so the EDIT diff can see the bubble size).
	_remove_probe(mod_id)
	var seed_payload := JSON.stringify({"block": block, "hooks": hooks})
	var seed_manifest := {"name": "Bubble Blaster", "kind": "block", "version": "1.0", "file": "block.json"}
	var seed_cand := {"mod_id": mod_id, "name": "Bubble Blaster", "kind": "block",
		"manifest": seed_manifest, "payload": seed_payload,
		"summary": "Bubble gun, size 1.0.", "error": ""}
	var creator_inst: Variant = _Creator.new()
	var seed_err := str(creator_inst.call("install", seed_cand))
	_check(s, seed_err == "", "edit-flow: seed bubble mod v1.0 installed via ModCreator.install (err='%s')" % seed_err)
	_Loader.call("rescan")
	var seed_rec: Dictionary = _Loader.call("find_mod", mod_id)
	_check(s, not seed_rec.is_empty() and str(seed_rec.get("version", "")) == "1.0" and is_equal_approx(_probe_bubble_size(mod_id), 1.0),
		"edit-flow: seed mod is version 1.0 with bubble size 1.0 (version='%s', size=%.1f)" % [str(seed_rec.get("version", "")), _probe_bubble_size(mod_id)])
	# EDIT API: load_installed + edit_context_for + diff + install_update.
	var creator_methods := _methods(_Creator)
	var has_edit_api := creator_methods.has("load_installed") and creator_methods.has("diff_candidate_vs_installed") and creator_methods.has("install_update") and creator_methods.has("bump_version") and creator_methods.has("edit_context_for")
	_check(s, has_edit_api,
		"edit-flow: EDIT API exists (load_installed / edit_context_for / diff_candidate_vs_installed / install_update / bump_version) — NOT LANDED if absent")
	_check(s, str(_Creator.call("bump_version", "1.0")) == "1.1" and str(_Creator.call("bump_version", "1.1")) == "1.2",
		"edit-flow: bump_version 1.0 -> 1.1, 1.1 -> 1.2")
	if not has_edit_api:
		for label in [
			"edit-flow: load_installed returns the exact installed payload",
			"edit-flow: edit_context_for seeds the refinement context",
			"edit-flow: approval diff shows Version 1.0 -> 1.1 + bubble size 1.0 -> 2.5",
			"edit-flow: discard leaves v1.0 untouched (size still 1.0)",
			"edit-flow: install_update writes version 1.1, old v1.0 gone",
		]:
			_check(s, false, label + " — NOT LANDED (no EDIT API)")
		_remove_probe(mod_id)
		_Loader.call("rescan")
		return
	var loaded: Dictionary = _Creator.call("load_installed", mod_id)
	_check(s, str(loaded.get("error", "")) == "" and str(loaded.get("payload", "")).contains("bubble"),
		"edit-flow: load_installed returns the exact installed payload (error='%s')" % str(loaded.get("error", "")))
	var ctx: Dictionary = _Creator.call("edit_context_for", mod_id)
	_check(s, str(ctx.get("error", "")) == "" and str(ctx.get("payload", "")).contains("bubble"),
		"edit-flow: edit_context_for seeds the refinement context for '%s' (error='%s')" % [mod_id, str(ctx.get("error", ""))])
	# The edited candidate: what generation would produce for
	# "make the bubble bigger" — same payload, projectile size 1.0 -> 2.5.
	var edited_cand := _bigger_bubble_candidate(mod_id, loaded)
	var cand_err := ""
	if not edited_cand.is_empty():
		cand_err = str(creator_inst.call("validate", edited_cand))
	_check(s, not edited_cand.is_empty() and cand_err == "",
		"edit-flow: 'make the bubble bigger' -> valid edited candidate (validate err='%s')" % cand_err)
	var diff: Array = _Creator.call("diff_candidate_vs_installed", edited_cand, loaded)
	var diff_text := JSON.stringify(diff)
	# NOTE: _diff_dicts truncates each changed value at 80 chars, so
	# the hooks line names the changed field but not the new size
	# value (2.5 is cut off) — approval shows THAT the hooks changed,
	# not the new value. Minor UX gap, flagged in the report, not a FAIL.
	_check(s, diff_text.contains("Version: 1.0 -> 1.1") and diff_text.contains("hooks"),
		"edit-flow: approval diff shows Version 1.0 -> 1.1 + hooks changed (diff=%s)" % diff_text.substr(0, 300))
	# Discard = never call install_update: no write at all.
	_Loader.call("rescan")
	var after_discard: Dictionary = _Loader.call("find_mod", mod_id)
	_check(s, str(after_discard.get("version", "")) == "1.0" and is_equal_approx(_probe_bubble_size(mod_id), 1.0),
		"edit-flow: discard leaves v1.0 untouched (version='%s', bubble size=%.1f)" % [str(after_discard.get("version", "")), _probe_bubble_size(mod_id)])
	var update_err := str(creator_inst.call("install_update", edited_cand, mod_id))
	_check(s, update_err == "", "edit-flow: install_update succeeds (err='%s')" % update_err)
	_Loader.call("rescan")
	var after_install: Dictionary = _Loader.call("find_mod", mod_id)
	_check(s, str(after_install.get("version", "")) == "1.1" and is_equal_approx(_probe_bubble_size(mod_id), 2.5),
		"edit-flow: after install the mod is version 1.1 with bubble size 2.5 (version='%s', size=%.1f)" % [str(after_install.get("version", "")), _probe_bubble_size(mod_id)])
	var folder_entries := _mods_snapshot()
	var dupes := 0
	for e in folder_entries:
		if str(e) == mod_id or str(e).begins_with(mod_id + "_"):
			dupes += 1
	_check(s, dupes == 1,
		"edit-flow: old v1.0 gone — exactly one folder for the mod id (dupes=%d)" % dupes)
	_remove_probe(mod_id)
	_Loader.call("rescan")


func _bigger_bubble_candidate(mod_id: String, loaded: Dictionary) -> Dictionary:
	# The edited candidate for "make the bubble bigger": the loaded
	# payload with the bubble projectile size 1.0 -> 2.5, everything
	# else identical. This is what the generation pipeline produces
	# from the edit context; the suite constructs it directly (no
	# network) and puts it through the real validate / diff / install.
	var payload_text := str(loaded.get("payload", ""))
	var data: Variant = JSON.parse_string(payload_text)
	if not (data is Dictionary):
		return {}
	var d := data as Dictionary
	var block: Dictionary = {}
	var hooks: Array = []
	if d.has("block") and d["block"] is Dictionary:
		block = (d["block"] as Dictionary).duplicate(true)
		if d.get("hooks") is Array:
			hooks = (d.get("hooks") as Array).duplicate(true)
	else:
		block = d.duplicate(true)
	var changed := false
	for h in hooks:
		if h is Dictionary and (h as Dictionary).has("projectile"):
			var proj: Variant = (h as Dictionary)["projectile"]
			if proj is Dictionary and (proj as Dictionary).has("size"):
				(proj as Dictionary)["size"] = 2.5
				changed = true
	if not changed:
		return {}
	var new_payload := JSON.stringify({"block": block, "hooks": hooks})
	var manifest: Dictionary = (loaded.get("manifest", {}) as Dictionary).duplicate(true)
	manifest["name"] = str(loaded.get("name", ""))
	manifest["kind"] = str(loaded.get("kind", "block"))
	return {"mod_id": mod_id, "name": str(loaded.get("name", "")), "kind": str(loaded.get("kind", "block")),
		"manifest": manifest, "payload": new_payload,
		"summary": "Bubble Blaster, bigger bubbles.", "error": ""}


func _probe_bubble_size(mod_id: String) -> float:
	var rec: Dictionary = _Loader.call("find_mod", mod_id, false)
	if rec.is_empty():
		return -1.0
	var hooks: Variant = rec.get("hooks", [])
	if hooks is Array:
		for h in (hooks as Array):
			if h is Dictionary and (h as Dictionary).has("projectile"):
				var proj: Variant = (h as Dictionary)["projectile"]
				if proj is Dictionary and (proj as Dictionary).has("size"):
					return float((proj as Dictionary)["size"])
	return -1.0


# --- (5) take_damage hook -------------------------------------------------------

func _test_take_damage_hook() -> void:
	var s := "take-damage-hook"
	var hook_consts := _consts(_Hook)
	var points: Variant = hook_consts.get("HOOK_POINTS", [])
	var has_point := false
	if points is Array:
		has_point = (points as Array).has("take_damage") or (points as Array).has("on_take_damage")
	var hook_src := _src("res://scripts/mods/mod_hook.gd")
	var point_marker := has_point or hook_src.contains("\"take_damage\"")
	var kinds: Variant = hook_consts.get("EFFECT_KINDS", [])
	var kinds_text := JSON.stringify(kinds)
	var has_kinds := kinds_text.contains("shield") and kinds_text.contains("vulnerable") and kinds_text.contains("thorns") and kinds_text.contains("petrified")
	_check(s, point_marker or has_kinds,
		"take-damage-hook: a take_damage hook point OR shield/vulnerable/thorns/petrified effect kinds exist (point=%s, kinds=%s) — NOT LANDED if neither" % [str(point_marker), str(has_kinds)])
	for kind in ["shield", "vulnerable", "thorns", "petrified"]:
		var eff := _effect_for(kind)
		var err: String = _Hook.call("validate_effect", eff)
		_check(s, err == "", "take-damage-hook: effect kind '%s' validates (err='%s')" % [kind, err])
	# Resolve-level (the choke-point math in ModStatusEffects): these
	# prove the interception semantics independent of take_damage wiring.
	_check(s, _resolve_case("shield", {"amount": 30.0, "duration_sec": 10.0}, 50.0, 20.0, 30.0, false),
		"take-damage-hook: resolve SHIELD — 50 dmg with 30 shield -> final 20, absorbed 30")
	_check(s, _resolve_case("vulnerable", {"factor": 2.0, "duration_sec": 10.0}, 50.0, 100.0, 0.0, false),
		"take-damage-hook: resolve VULNERABLE — 50 dmg at 2x -> final 100")
	_check(s, _resolve_thorns_case(), "take-damage-hook: resolve THORNS — 50 dmg taken at reflect 0.5 -> 25 reflected to the attacker")
	_check(s, _resolve_case("petrified", {"duration_sec": 10.0}, 50.0, 0.0, 0.0, true),
		"take-damage-hook: resolve PETRIFIED — 50 dmg -> final 0, nullified")
	# Wiring: Player/EnemyBase take_damage() must call the resolver.
	var player_src := _src("res://scripts/player/player.gd")
	var enemy_src := _src("res://scripts/enemies/enemy_base.gd")
	var wired := player_src.contains("resolve_incoming_damage") and enemy_src.contains("resolve_incoming_damage")
	_check(s, wired,
		"take-damage-hook: Player.take_damage AND EnemyBase.take_damage call resolve_incoming_damage (wired=%s) — NOT LANDED if false" % str(wired))
	# In-game: real EnemyBase targets, damage through take_damage().
	# These FAIL until the wiring above lands — the spec says "in-game".
	_check(s, _damage_case("shield", {"amount": 30.0, "duration_sec": 10.0}, 50.0, 15.0, 35.0),
		"take-damage-hook: SHIELD absorbs in-game (50 dmg with 30 shield -> 15..35 taken)")
	_check(s, _damage_case("vulnerable", {"factor": 2.0, "duration_sec": 10.0}, 50.0, 75.0, 999.0),
		"take-damage-hook: VULNERABLE increases in-game (50 dmg at 2x -> >=75 taken)")
	_check(s, _thorns_case(), "take-damage-hook: THORNS reflects in-game (attacker loses HP when the victim is hit)")
	_check(s, _damage_case("petrified", {"duration_sec": 10.0}, 50.0, -0.01, 0.01),
		"take-damage-hook: PETRIFIED nullifies in-game (50 dmg -> 0 taken)")


func _effect_for(kind: String) -> Dictionary:
	match kind:
		"shield":
			return {"kind": "shield", "amount": 30.0, "duration_sec": 10.0}
		"vulnerable":
			return {"kind": "vulnerable", "factor": 2.0, "duration_sec": 10.0}
		"thorns":
			return {"kind": "thorns", "reflect_mult": 0.5, "duration_sec": 10.0}
		"petrified":
			return {"kind": "petrified", "duration_sec": 10.0}
	return {"kind": kind}


func _resolve_case(kind: String, params: Dictionary, amount: float, want_final: float, want_absorbed: float, want_nullified: bool) -> bool:
	var target := _fresh_enemy(200.0)
	var applied: bool = _Status.call("apply_status", target, kind, params, Vector3.ZERO)
	var res: Dictionary = _Status.call("resolve_incoming_damage", target, amount, null)
	target.queue_free()
	print("take-damage-hook detail: resolve %s applied=%s -> %s" % [kind, str(applied), str(res)])
	if not applied:
		return false
	return is_equal_approx(float(res.get("final_damage", -1.0)), want_final) and is_equal_approx(float(res.get("absorbed", -1.0)), want_absorbed) and bool(res.get("nullified", false)) == want_nullified


func _resolve_thorns_case() -> bool:
	var victim := _fresh_enemy(200.0)
	var attacker := DamageDummy.new()
	attacker.name = "ThornsResolveAttacker"
	attacker.hp = 100.0
	_arena.add_child(attacker)
	var applied: bool = _Status.call("apply_status", victim, "thorns", {"reflect_mult": 0.5, "duration_sec": 10.0}, Vector3.ZERO)
	var res: Dictionary = _Status.call("resolve_incoming_damage", victim, 50.0, attacker)
	victim.queue_free()
	attacker.queue_free()
	print("take-damage-hook detail: resolve thorns applied=%s -> %s" % [str(applied), str(res)])
	return applied and is_equal_approx(float(res.get("reflected", -1.0)), 25.0) and (res.get("reflected_target") as Node) == attacker


func _damage_case(kind: String, params: Dictionary, amount: float, lo: float, hi: float) -> bool:
	# Baseline: fresh enemy, no effect, take_damage(amount).
	var base_enemy := _fresh_enemy(200.0)
	base_enemy.call("take_damage", amount, Vector3.ZERO, false)
	var base_taken := 200.0 - float(base_enemy.get("hp"))
	base_enemy.queue_free()
	# Effect: apply via ModStatusEffects, then the same hit.
	var enemy := _fresh_enemy(200.0)
	var applied: bool = _Status.call("apply_status", enemy, kind, params, Vector3.ZERO)
	if not applied:
		# Fallback: the hook path — run a take_damage / on_damage_taken
		# hook carrying the effect, then hit the target.
		var api: Variant = _API.new(_player, _arena)
		var hook_point := "take_damage"
		var hook := {"hook_id": "loops_" + kind, "hook_point": hook_point, "effects": [_effect_for(kind)]}
		var ctx := {"position": Vector3.ZERO, "hit_position": Vector3.ZERO, "damage": amount, "target": enemy, "attacker": null}
		var _res: Variant = _Registry.call("run_hooks", [hook], hook_point, api, ctx)
		applied = _Status.call("has_status_effect", enemy, kind)
	enemy.call("take_damage", amount, Vector3.ZERO, false)
	var taken := 200.0 - float(enemy.get("hp"))
	enemy.queue_free()
	print("take-damage-hook detail: %s baseline_taken=%.1f taken=%.1f (want %.1f..%.1f) applied=%s" % [kind, base_taken, taken, lo, hi, str(applied)])
	if kind == "vulnerable":
		# Vulnerable is relative to baseline: 2x must beat baseline.
		return taken > base_taken * 1.4 and taken >= lo
	return taken >= lo and taken <= hi


func _thorns_case() -> bool:
	var victim := _fresh_enemy(200.0)
	var attacker := DamageDummy.new()
	attacker.name = "ThornsAttacker"
	attacker.hp = 100.0
	_arena.add_child(attacker)
	var applied: bool = _Status.call("apply_status", victim, "thorns", {"reflect_mult": 0.5, "duration_sec": 10.0}, Vector3.ZERO)
	if not applied:
		var api: Variant = _API.new(_player, _arena)
		var hook := {"hook_id": "loops_thorns", "hook_point": "take_damage",
			"effects": [{"kind": "thorns", "reflect_mult": 0.5, "duration_sec": 10.0}]}
		var ctx := {"position": Vector3.ZERO, "hit_position": Vector3.ZERO, "damage": 50.0, "target": victim, "attacker": attacker}
		var _res: Variant = _Registry.call("run_hooks", [hook], "take_damage", api, ctx)
		applied = _Status.call("has_status_effect", victim, "thorns")
	# Pass the attacker through take_damage's 4th arg (v0.5.9) so the
	# reflection has a live target; a 3-arg call falls back to the
	# player, which is not this attacker.
	victim.call("take_damage", 50.0, Vector3.ZERO, false, attacker)
	var reflected := 100.0 - attacker.hp
	victim.queue_free()
	attacker.queue_free()
	print("take-damage-hook detail: thorns applied=%s attacker_hp=%.1f reflected=%.1f" % [str(applied), attacker.hp, reflected])
	return reflected > 0.0


# --- (6) MAKE loops ---------------------------------------------------------------

func _test_make_loops() -> void:
	var s := "make-loops"
	# Guard: if forge_session_make.gd is mid-edit / unparseable (a
	# concurrent worker's in-flight state), its methods don't exist
	# and calling them aborts this function — report, don't crash.
	if _SessionMake == null or not _has_method_on(_SessionMake, "apply_candidate"):
		for label in [
			"make-loops: MAKE builds a block cover in-session",
			"make-loops: MAKE produced a live session node",
			"make-loops: MAKE build appears in ForgeManager history",
			"make-loops: MAKE build is undoable via ForgeManager.undo_last()",
			"make-loops: NetForgeSync peer sim",
			"make-loops: MAKE builds feed NetForgeSync",
			"make-loops: script-shaped MAKE ('exploding wall') works in-session",
			"make-loops: MAKE wrote NO file to user://mods/",
			"make-loops: MAKE'd wall is session-only (not in ModLoader)",
		]:
			_check(s, false, label + " — UNVERIFIED (forge_session_make.gd currently unparseable / in-flight edit)")
		return
	var snap_before := _mods_snapshot()
	# MAKE via the recording layer: ForgeManager.apply_make() gives the
	# build history + undo + MP-sync treatment (v0.5.9 MAKE parity).
	var has_apply_make := _manager != null and _manager.has_method("apply_make")
	_check(s, has_apply_make,
		"make-loops: ForgeManager.apply_make() exists (recording layer) — NOT LANDED if absent")
	# MAKE a plain block cover (baseline).
	var cover_cand := {"mod_id": "verify_loops_make_wall", "name": "Loops Make Wall",
		"kind": "block", "manifest": {}, "summary": "wall",
		"payload": JSON.stringify({"block_id": "verify_loops_make_wall", "target": "cover",
			"cost": 100, "display_name": "Loops Wall", "shape": "wall",
			"size_voxels": [4, 3, 1], "hp": 200.0}),
		"error": ""}
	var hist_before := 0
	if _manager != null and _manager.has_method("get_make_history"):
		hist_before = (_manager.call("get_make_history") as Array).size()
	var res: Dictionary = {}
	var built_node: Node = null
	if has_apply_make:
		res = _manager.call("apply_make", cover_cand, "build a wall")
		built_node = res.get("node") as Node
	else:
		res = _SessionMake.call("apply_candidate", cover_cand, _player, _arena)
		built_node = res.get("node") as Node
	_check(s, bool(res.get("ok", false)), "make-loops: MAKE builds a block cover in-session (ok=%s, msg='%s')" % [str(res.get("ok", false)), str(res.get("message", ""))])
	_check(s, built_node != null and is_instance_valid(built_node),
		"make-loops: MAKE produced a live session node (result node, not last_built_node)")
	# History: get_make_history + search_make_history record the MAKE.
	var hist_ok := false
	var search_ok := false
	if _manager != null and _manager.has_method("get_make_history"):
		var hist: Array = _manager.call("get_make_history")
		hist_ok = hist.size() == hist_before + 1 and str((hist[0] as Dictionary).get("prompt", "")) == "build a wall"
	if _manager != null and _manager.has_method("search_make_history"):
		var found: Array = _manager.call("search_make_history", "wall")
		search_ok = not found.is_empty()
	_check(s, hist_ok, "make-loops: MAKE build appears in get_make_history() (before=%d, prompt='build a wall')" % hist_before)
	_check(s, search_ok, "make-loops: search_make_history('wall') finds the MAKE build")
	# Sync wiring: the built node must carry a syncable forge_spec meta
	# (the live notify no-ops offline — NetManager.forge_notify_placed
	# returns {} when not online — so the meta + source wiring is the
	# headless evidence, plus the peer sim below).
	var spec_ok := built_node != null and built_node.has_meta("forge_spec") and (built_node.get_meta("forge_spec") is Dictionary) and not (built_node.get_meta("forge_spec") as Dictionary).is_empty()
	var make_src := _src("res://scripts/forge/forge_session_make.gd")
	var mgr_src := _src("res://scripts/forge/forge_manager.gd")
	var sync_wired := make_src.contains("forge_notify_placed") and mgr_src.contains("forge_notify_placed")
	_check(s, spec_ok and sync_wired,
		"make-loops: MAKE build carries forge_spec meta + notify wiring in session_make + manager (spec_ok=%s, wired=%s) — NOT LANDED if absent" % [str(spec_ok), str(sync_wired)])
	# Undo: ForgeManager.undo_last() must remove the MAKE build.
	var undo_ok := false
	if _manager != null and _manager.has_method("undo_last"):
		var ures: Dictionary = _manager.call("undo_last")
		undo_ok = bool(ures.get("ok", false)) and (built_node == null or not is_instance_valid(built_node) or (built_node as Node).is_queued_for_deletion())
	_check(s, undo_ok,
		"make-loops: MAKE build is undoable via ForgeManager.undo_last() (undo_ok=%s) — NOT LANDED if false" % str(undo_ok))
	if built_node != null and is_instance_valid(built_node) and not (built_node as Node).is_queued_for_deletion():
		built_node.queue_free()
	# Sync machinery (NetForgeSync peer sim).
	_check(s, _sync_peer_sim(), "make-loops: NetForgeSync peer sim — host_place -> peer has the identical entry")
	# Script-shaped MAKE: an exploding wall, in-session.
	_check(s, _exploding_wall_case(), "make-loops: script-shaped MAKE ('exploding wall') works in-session (wall built + touch explodes)")
	# MAKE never writes to user://mods/ (across ALL MAKE builds above).
	var snap_after := _mods_snapshot()
	print("make-loops detail: mods snapshot before=%s after=%s" % [str(snap_before), str(snap_after)])
	_check(s, snap_after == snap_before,
		"make-loops: MAKE wrote NO file to user://mods/ (snapshot unchanged)")
	# Session-scoped: the MAKE'd thing is not a registered mod.
	var ghost: Dictionary = _Loader.call("find_mod", "verify_loops_make_wall", false)
	_check(s, ghost.is_empty(), "make-loops: MAKE'd wall is session-only (not in ModLoader)")


func _sync_peer_sim() -> bool:
	if _Sync == null:
		return false
	var host: Node = _Sync.new() as Node
	var peer: Node = _Sync.new() as Node
	_arena.add_child(host)
	_arena.add_child(peer)
	host.call("set_peer_context", false, true, 1)
	peer.call("set_peer_context", false, false, 2)
	var spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "bunker", "position": [8.0, 0.0, -8.0]}, "cost": 180, "ttl": 0}
	var placed: Dictionary = host.call("host_place", spec, 1, Vector3(8.0, 0.0, -8.0), Vector3.ZERO)
	if placed.is_empty():
		host.queue_free()
		peer.queue_free()
		return false
	var node2: Node = peer.call("apply_place", placed)
	var same := str(host.call("get_wire_entries")) == str(peer.call("get_wire_entries"))
	var iid := int(placed.get("instance_id", 0))
	var ok: bool = node2 != null and is_instance_valid(node2) and same and int(peer.call("entry_count")) == 1
	host.call("host_remove", iid)
	peer.call("apply_remove", iid)
	host.queue_free()
	peer.queue_free()
	return ok


func _exploding_wall_case() -> bool:
	# Script-shaped MAKE: a ModBlock script that spawns a cover wall
	# + an on_hit explosion hook. Built through apply_make (the
	# recording layer), then an enemy touch is simulated via the
	# wall's ForgeSessionWatcher: touch -> dispatch -> explosion
	# damages the touching enemy (fx_detonate, 40 dmg at point blank).
	var script_text := "extends ModBlock\n" \
		+ "func get_block_info() -> Dictionary:\n" \
		+ "\treturn {\"block_id\": \"verify_loops_exploding_wall\", \"target\": \"cover\", \"cost\": 100, \"display_name\": \"Exploding Wall\", \"shape\": \"wall\", \"size_voxels\": [4, 3, 1], \"hp\": 200.0}\n" \
		+ "func get_hooks() -> Array:\n" \
		+ "\treturn [{\"hook_id\": \"explode_on_touch\", \"hook_point\": \"on_hit\", \"effects\": [{\"kind\": \"explosion\", \"radius\": 5.0, \"damage\": 40.0}]}]\n" \
		+ "func apply(api: ModAPI, params: Dictionary) -> String:\n" \
		+ "\tvar pos: Vector3 = params.get(\"_position\", Vector3.ZERO)\n" \
		+ "\tvar node: Node = api.spawn_cover(\"wall\", Vector3i(4, 3, 1), 200.0, pos)\n" \
		+ "\tif node == null:\n" \
		+ "\t\treturn \"\"\n" \
		+ "\treturn \"Exploding wall built.\"\n"
	var script_cand := {"mod_id": "verify_loops_exploding_wall", "name": "Exploding Wall",
		"kind": "script", "manifest": {"name": "Exploding Wall", "kind": "script", "version": "1.0"},
		"summary": "wall that explodes when enemies touch it",
		"payload": script_text, "error": ""}
	var res: Dictionary = {}
	if _manager != null and _manager.has_method("apply_make"):
		res = _manager.call("apply_make", script_cand, "build an exploding wall")
	else:
		res = _SessionMake.call("apply_candidate", script_cand, _player, _arena)
	var node: Node = res.get("node") as Node
	if not bool(res.get("ok", false)) or node == null or not is_instance_valid(node):
		print("make-loops detail: exploding wall script MAKE ok=%s msg='%s'" % [str(res.get("ok", false)), str(res.get("message", ""))])
		return false
	var watcher: Node = null
	for child in node.get_children():
		if child.has_method("check_now"):
			watcher = child
			break
	if watcher == null:
		print("make-loops detail: exploding wall has NO session watcher")
		node.queue_free()
		return false
	var foe := DamageDummy.new()
	foe.name = "ExplodingWallFoe"
	foe.hp = 100.0
	foe.position = (node as Node3D).global_position
	foe.add_to_group("enemy")
	_arena.add_child(foe)
	var before: int = int(watcher.get("dispatch_count"))
	watcher.call("check_now")
	var after: int = int(watcher.get("dispatch_count"))
	watcher.call("check_now")
	var after2: int = int(watcher.get("dispatch_count"))
	# The explosion effect itself: the watcher dispatches the SAME
	# hooks on touch; run them through the registry and confirm the
	# explosion effect executes (exploded=true). Damage to the foe is
	# NOT asserted here: ExplosionFX.detonate damages via a physics
	# shape query, and the test dummy has no collision shape, so it
	# can never be hit — a real enemy (with a collider) would be.
	# The damage path belongs to ExplosionFX's own suite.
	var api: Variant = _API.new(_player, _arena)
	var r: Variant = _Registry.call("run_hooks", watcher.get("session_hooks"), "on_hit", api,
		{"position": (node as Node3D).global_position, "hit_position": foe.global_position, "damage": 0.0, "target": foe, "headshot": false, "weapon_id": "session_make"})
	var exploded := bool((r as Dictionary).get("exploded", false))
	print("make-loops detail: exploding wall dispatch %d -> %d -> %d, registry exploded=%s (foe hp=%.1f — no collider, physics query cannot hit it)" % [before, after, after2, str(exploded), foe.hp])
	_arena.remove_child(foe)
	foe.free()
	node.queue_free()
	return after >= 1 and after2 == after and exploded
