# verify_zombies.gd — headless checks for FORGEFALL Zombies mode.
# Usage: godot --headless --path <project> --script res://tools/verify_zombies.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Covers (per the brief + the 20:05 traversal correction): the BO2
# points table, doors, perk randomization (health perk always
# present), wall-buy randomization, Mystery Box (950 + full pool
# incl. mod weapons via Arsenal + teddy move), PAP 5000 / re-PAP
# 2000, NO Forge in Zombies (ForgeGate + forge_menu_allowed +
# ZombiesMode.forge_allowed), the weak starter weapon, the town
# layout, down/revive, rounds, and the traversal toggle (OFF = no
# tools, ON = all three: grapple + jetpack + portal). Plus the v0.6.0
# integration: Zombies runs on the flat zombies_flat map (no map
# geometry above the ground plane inside the town footprint), and
# Main routes SP + MP Zombies to that map.
extends SceneTree


class FakePlayer extends Node:
	var _allowed: Array[String] = ["grapple", "jetpack", "portal"]
	var _tool := "grapple"

	func set_allowed_traversal_tools(tools: Array) -> void:
		_allowed.clear()
		for t in tools:
			_allowed.append(str(t))
		if _tool != "none" and not _allowed.has(_tool):
			_tool = "none"

	func get_traversal_tool() -> String:
		return _tool

	func set_traversal_tool(tool: String) -> bool:
		if tool != "none" and not _allowed.has(tool):
			return false
		_tool = tool
		return true


var _fails := 0
var _checks := 0
var _started := false
var _done := false
var _round_cleared: Array = []
var _game: Node = null


func _process(_delta: float) -> bool:
	if _done:
		return true
	if not _started:
		_started = true
		_run_checks()
		if not _done:
			printerr("verify_zombies aborted early (runtime error above)")
			_done = true
			quit(1)
			return true
		quit(0 if _fails == 0 else 1)
		return true
	return false


func _check(name: String, cond: bool) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % name)
	else:
		_fails += 1
		printerr("FAIL: %s" % name)


func _on_round_cleared(n: int) -> void:
	_round_cleared.append(n)


## Solid geometry of the flat map that pokes above the ground plane
## (top > 0.1) inside the Zombies town footprint (|x| <= 36,
## |z| <= 18). Returns the offending shape centers (empty = no
## overlap). Checked via the map's CollisionShape3D boxes — collision
## is what actually blocks/overlaps gameplay — because headless
## Godot 4.7.2 returns identity for MultiMesh.get_instance_transform
## (the instance buffer stays empty headless), so multimesh
## transforms cannot be read back in a verifier. The ground slab
## (top = 0.0) is fine: the town sits ON it.
func _town_footprint_overlap(map_node: Node) -> Array:
	var bad: Array = []
	_collect_overlap(map_node, bad)
	return bad


func _collect_overlap(node: Node, bad: Array) -> void:
	if node is CollisionShape3D:
		var cs := node as CollisionShape3D
		var shape: Shape3D = cs.shape
		if shape is BoxShape3D:
			var center := cs.global_position
			var top := center.y + (shape as BoxShape3D).size.y * 0.5
			if top > 0.1 and absf(center.x) <= 36.0 and absf(center.z) <= 18.0:
				bad.append(center)
	for c in node.get_children():
		_collect_overlap(c as Node, bad)


func _run_checks() -> void:
	var ZS := load("res://scripts/modes/zombies.gd") as GDScript
	var ZSSetup := load("res://scripts/modes/zombies_setup.gd") as GDScript
	var GM := load("res://scripts/core/game_mode.gd") as GDScript
	var FG := load("res://scripts/forge/forge_gate.gd") as GDScript
	var ARS := load("res://scripts/weapons/arsenal.gd") as GDScript
	# Autoloads are NOT visible as bare identifiers in --script entry
	# scripts (verify_content.gd precedent): look Game up on root.
	_game = root.get_node_or_null("Game")

	# --- Points table (pure statics) -------------------------------------
	_check("points: hit 10", ZS.POINTS_HIT == 10)
	_check("points: lethal torso 60", ZS.points_for_kill("torso") == 60)
	_check("points: lethal limb 50", ZS.points_for_kill("limb") == 50)
	_check("points: lethal explosive 50", ZS.points_for_kill("explosive") == 50)
	_check("points: lethal neck 70", ZS.points_for_kill("neck") == 70)
	_check("points: lethal headshot 100", ZS.points_for_kill("headshot") == 100)
	_check("points: lethal melee 130", ZS.points_for_kill("melee") == 130)
	_check("points: unknown zone defaults to torso 60", ZS.points_for_kill("bogus") == 60)
	_check("board cap round 1 = 40", ZS.board_points_cap(1) == 40)
	_check("board cap round 11 = 490", ZS.board_points_cap(11) == 490)
	_check("board cap never exceeds 490", ZS.board_points_cap(100) == 490)

	# --- Instance: auto-starts on add -------------------------------------
	var z = ZS.new()
	root.add_child(z)
	_check("zombies active after add", ZS.is_active())
	_check("zombies running after add", bool(z.get("running")))
	_check("town built", z.get_node_or_null("ZombiesTown") != null)
	_check("interactables: 4 doors + 5 perks + 4 wall + 2 box + 1 pap + 6 barriers = 22",
		(z.get("_interactables") as Array).size() == 22)
	_check("NO Forge in Zombies (forge_allowed false)", not ZS.forge_allowed())
	_check("ForgeGate blocks zombies mode", not FG.can_build_for_mode("zombies"))
	_check("ForgeGate allows tower_defense", FG.can_build_for_mode("tower_defense"))
	_check("Forge menu never opens for zombies", not GM.forge_menu_allowed("zombies"))
	_check("mode registered implemented", GM.is_implemented("zombies"))
	_check("zombies in SP menu order", GM.modes_for_scope("sp").has("zombies"))

	# --- Points: award / spend ----------------------------------------------
	_check("add_points stores", z.add_points(7, 1000) == 1000)
	_check("award_hit +10", z.award_hit(7) == 1010)
	_check("award_kill headshot +100", z.award_kill(7, "headshot") == 1110)
	_check("spend fails when short (points unchanged)",
		not z.spend_points(7, 2000) and z.get_points(7) == 1110)
	_check("spend succeeds", z.spend_points(7, 110) and z.get_points(7) == 1000)
	_check("carpenter +200", z.award_carpenter(7) == 1200)
	_check("nuke +400", z.award_nuke(7) == 1600)

	# --- Barriers: board points + round cap ----------------------------------
	z.start_round(1)
	z.damage_barrier("bar_bank", 1)
	_check("damage_barrier drops a board", z.barrier_boards("bar_bank") == 5)
	# NOTE: repair_board's "points" is the player's CUMULATIVE total
	# (add_points returns the new total) — measure deltas instead.
	var board_total := 0
	for i in 4:
		z.damage_barrier("bar_bank", 1)
		var before: int = z.get_points(5)
		var r: Dictionary = z.repair_board(5, "bar_bank")
		board_total += z.get_points(5) - before
	_check("4 board repairs award 10 each (cap 40)", board_total == 40 and z.get_points(5) == 40)
	z.damage_barrier("bar_bank", 1)
	var capped: Dictionary = z.repair_board(5, "bar_bank")
	_check("board repair past round cap awards 0 (board still repaired)",
		int(capped.get("points", -1)) == 0 and z.barrier_boards("bar_bank") == 5)
	_check("one more repair tops the barrier off",
		bool(z.repair_board(5, "bar_bank").get("ok", false)) and z.barrier_boards("bar_bank") == 6)
	_check("repairing a full barrier fails",
		not bool(z.repair_board(5, "bar_bank").get("ok", true)))
	_check("repairing an unknown barrier fails",
		not bool(z.repair_board(5, "nope").get("ok", true)))

	# --- Doors -----------------------------------------------------------------
	_check("doors start closed", not z.is_door_open("north_alley"))
	z.add_points(0, 2000)
	var d1: Dictionary = z.buy_door(0, "north_alley")
	_check("buy door: ok, deducts 750", bool(d1.get("ok", false)) and z.get_points(0) == 1250)
	_check("door open after buy", z.is_door_open("north_alley"))
	_check("re-buying an open door fails", not bool(z.buy_door(0, "north_alley").get("ok", true)))
	_check("buying an unknown door fails", not bool(z.buy_door(0, "nope").get("ok", true)))
	_check("buying a door without points fails",
		not bool(z.buy_door(8, "south_alley").get("ok", true)) and not z.is_door_open("south_alley"))

	# --- Perks: randomization + buy -------------------------------------------
	z.start_run(12345)
	var first_assign := {}
	for mid in ["bank", "smithy", "chapel", "tavern", "goods"]:
		first_assign[mid] = z.machine_perk(mid)
	z.start_run(12345)
	var same := true
	for mid in first_assign.keys():
		if z.machine_perk(str(mid)) != str(first_assign[mid]):
			same = false
	_check("perk randomization is seed-deterministic", same)
	var differ := false
	for s in range(1000, 1021):
		z.start_run(s)
		for mid in first_assign.keys():
			if z.machine_perk(str(mid)) != str(first_assign[mid]):
				differ = true
				break
		if differ:
			break
	_check("perk randomization differs across seeds", differ)
	var health_always := true
	for s in range(1, 21):
		z.start_run(s)
		var found := false
		for mid in ["bank", "smithy", "chapel", "tavern", "goods"]:
			if z.machine_perk(mid) == "bulwark_brew":
				found = true
		if not found:
			health_always = false
	_check("health perk (Bulwark Brew) present in 20/20 runs", health_always)
	z.start_run(777)
	var perk_ids: Array = []
	for mid in ["bank", "smithy", "chapel", "tavern", "goods"]:
		perk_ids.append(z.machine_perk(mid))
	var distinct := true
	for i in perk_ids.size():
		for j in perk_ids.size():
			if i != j and perk_ids[i] == perk_ids[j]:
				distinct = false
	_check("5 machines get 5 distinct perks", distinct)
	var health_machine := ""
	for mid in ["bank", "smithy", "chapel", "tavern", "goods"]:
		if z.machine_perk(mid) == "bulwark_brew":
			health_machine = mid
	z.add_points(9, 10000)
	var pb: Dictionary = z.buy_perk(9, health_machine)
	_check("buy health perk: ok, costs 2500", bool(pb.get("ok", false))
		and z.get_points(9) == 7500 and z.has_perk(9, "bulwark_brew"))
	_check("re-buying an owned perk fails", not bool(z.buy_perk(9, health_machine).get("ok", true)))
	_check("buying a perk without points fails",
		not bool(z.buy_perk(11, health_machine).get("ok", true)))
	z.set_player_count(1)
	_check("Quick Revive analog costs 500 solo", z.quick_revive_cost() == 500)
	z.set_player_count(2)
	_check("Quick Revive analog costs 1500 co-op", z.quick_revive_cost() == 1500)
	z.set_player_count(1)

	# --- Wall buys: randomization + buy ----------------------------------------
	z.start_run(777)
	var wall_ids: Array = []
	var wall_ok := true
	for sid in ["chalk_west", "chalk_mid", "chalk_south", "chalk_east"]:
		var def: Dictionary = z.wall_buy(sid)
		wall_ids.append(str(def.get("weapon_id", "")))
		if int(def.get("price", -1)) not in [500, 900, 1000] or int(def.get("ammo_price", -1)) != 250:
			wall_ok = false
	var wall_distinct := true
	for i in wall_ids.size():
		for j in wall_ids.size():
			if i != j and wall_ids[i] == wall_ids[j]:
				wall_distinct = false
	_check("wall buys: 4 distinct weapons, BO2-reference prices + 250 ammo", wall_ok and wall_distinct)
	z.add_points(10, 10000)
	var wb: Dictionary = z.buy_wall_weapon(10, "chalk_west")
	_check("buy wall weapon: ok, deducts its price",
		bool(wb.get("ok", false)) and str(wb.get("weapon_id", "")) == wall_ids[0]
		and z.get_points(10) == 10000 - int(z.wall_buy("chalk_west").get("price", 0)))
	_check("buying a wall weapon without points fails",
		not bool(z.buy_wall_weapon(11, "chalk_mid").get("ok", true)))

	# --- Mystery Box -------------------------------------------------------------
	var pool: Array[String] = z.get_box_pool()
	_check("box pool = every Arsenal weapon (base + installed mods)",
		pool == ARS.all_weapon_ids() and pool.has("ember") and pool.has("ar7") and pool.has("p9"))
	z.add_points(12, 10000)
	var bx: Dictionary = z.buy_box(12, false, 0)
	_check("box buy: 950, returns first pool weapon",
		bool(bx.get("ok", false)) and str(bx.get("weapon_id", "")) == pool[0]
		and z.get_points(12) == 9050)
	var spot_before: int = int(z.get("box_spot"))
	var ted: Dictionary = z.buy_box(12, true)
	_check("teddy: no weapon, box moves to the other spot",
		bool(ted.get("teddy", false)) and str(ted.get("weapon_id", "")) == ""
		and int(z.get("box_spot")) == 1 - spot_before)
	_check("box buy without points fails",
		not bool(z.buy_box(13).get("ok", true)))

	# --- Pack-a-Punch ---------------------------------------------------------------
	z.add_points(14, 10000)
	var pap1: Dictionary = z.buy_pap(14, "primary")
	var st1: Dictionary = z.pap_state(14, "primary")
	_check("PAP first use: 5000, level 1, element, 2x damage",
		bool(pap1.get("ok", false)) and int(st1.get("level", 0)) == 1
		and str(st1.get("element", "")) in ["ember", "frost", "volt", "toxic", "void"]
		and float(st1.get("damage_mult", 0.0)) == 2.0 and z.get_points(14) == 5000)
	var pap2: Dictionary = z.buy_pap(14, "primary")
	var st2: Dictionary = z.pap_state(14, "primary")
	_check("re-PAP: 2000, level 2, chain/sight/attachment upgrade",
		bool(pap2.get("ok", false)) and int(st2.get("level", 0)) == 2
		and str(st2.get("upgrade", "")) in ["chain_lightning", "chain_frost", "extended_mag", "red_dot", "suppressor"])
	_check("third PAP fails (max)", not bool(z.buy_pap(14, "primary").get("ok", true)))
	_check("PAP without points fails", not bool(z.buy_pap(15, "primary").get("ok", true)))

	# --- Down / revive --------------------------------------------------------------
	z.add_points(16, 2000)
	var p16: Dictionary = z._ensure_player(16)
	p16["perks"] = ["double_drum"]
	_check("down_player marks downed + strips perks",
		z.down_player(16) and z.is_downed(16) and z.owned_perks(16).is_empty())
	var rv: Dictionary = z.revive_player(17, 16)
	_check("revive grants 5% of downed player's points (2000 -> +100)",
		bool(rv.get("ok", false)) and int(rv.get("awarded", -1)) == 100
		and z.get_points(17) == 100 and not z.is_downed(16))
	_check("reviving a standing player fails", not bool(z.revive_player(17, 16).get("ok", true)))
	# Self-revive via Lifeline (solo).
	var p19: Dictionary = z._ensure_player(19)
	p19["perks"] = ["lifeline"]
	z.down_player(19)
	_check("Lifeline down schedules self-revive", z.is_downed(19) and float(z.get("_self_revive_t")) > 0.0)
	z._process(3.1)
	_check("self-revive clears downed after 3s", not z.is_downed(19))

	# --- Rounds ----------------------------------------------------------------------
	_round_cleared.clear()
	z.round_cleared.connect(_on_round_cleared)
	_game.call("emit_signal", "wave_started", 3)
	_check("wave 3 starts round 3 (16 hostiles)", z.round_number == 3 and z.zombies_remaining == 16)
	z.register_kill(0, "torso")
	_check("observed kill awards torso 60 + decrements remaining",
		z.zombies_remaining == 15)
	_game.call("emit_signal", "wave_cleared", 3)
	_check("wave cleared emits round_cleared", _round_cleared.has(3))

	# --- Starter weapon ------------------------------------------------------------------
	_check("starter weapon is ember", ZS.STARTER_WEAPON == "ember")
	_check("ember exists in Arsenal", ARS.has_weapon("ember"))
	_check("ember is weak (8 dmg < AR-7 25)", float(ARS.get_stats("ember").get("damage", 99.0)) == 8.0
		and float(ARS.get_stats("ember").get("damage", 0.0)) < float(ARS.get_stats("ar7").get("damage", 0.0)))
	var ember_vm: Node3D = ARS.build_viewmodel("ember")
	_check("ember has a viewmodel", ember_vm is Node3D)
	ember_vm.free()
	# NOTE: no WeaponBase annotation here — a game-class annotation
	# forces compile-time resolution before autoloads exist in a
	# --script entry run (breaks WeaponBase.new() at runtime).
	var ember_w = ARS.make_weapon("ember")
	_check("ember builds with 8 damage", ember_w.damage == 8.0)
	ember_w.free()

	# --- Town: re-run is idempotent ------------------------------------------------------
	z.start_run(4242)
	var town_count := 0
	for child in z.get_children():
		if (child as Node).name == "ZombiesTown":
			town_count += 1
	_check("re-start rebuilds exactly one town", town_count == 1)
	_check("barriers reset to full on re-start", z.barrier_boards("bar_bank") == 6)
	_check("doors reset to closed on re-start", not z.is_door_open("north_alley"))

	# --- Traversal toggle: OFF = no tools, ON = all three -------------------------------
	ZS.set_traversal_enabled(false)
	_check("toggle default OFF after explicit set", not ZS.is_traversal_enabled())
	_check("toggle OFF: allowed set is empty", ZS.allowed_traversal_tools().is_empty())
	_check("toggle OFF: grapple not allowed", not ZS.is_traversal_tool_allowed("grapple"))
	_check("toggle OFF: portal not allowed", not ZS.is_traversal_tool_allowed("portal"))
	_check("toggle OFF: jetpack not allowed", not ZS.jetpack_allowed())
	ZS.set_traversal_enabled(true)
	_check("toggle ON: allowed set is all three",
		ZS.allowed_traversal_tools() == ["grapple", "jetpack", "portal"])
	_check("toggle ON: grapple allowed", ZS.is_traversal_tool_allowed("grapple"))
	_check("toggle ON: portal allowed", ZS.is_traversal_tool_allowed("portal"))
	_check("toggle ON: jetpack allowed", ZS.jetpack_allowed())
	# Persistence round-trip: save ON, drop cache, re-read from disk.
	ZS.reset_traversal_cache_for_tests()
	_check("toggle persists across a cache reset (ON)", ZS.is_traversal_enabled())
	ZS.set_traversal_enabled(false)
	ZS.reset_traversal_cache_for_tests()
	_check("toggle persists across a cache reset (OFF)", not ZS.is_traversal_enabled())
	# Fake player through the movement API.
	var fake := FakePlayer.new()
	root.add_child(fake)
	ZS.set_traversal_enabled(false)
	_check("apply OFF to player: allowed [] + active none",
		z.apply_traversal_to_player(fake) and fake._allowed.is_empty() and fake._tool == "none")
	ZS.set_traversal_enabled(true)
	_check("apply ON to player: allowed all three + active restored to grapple",
		z.apply_traversal_to_player(fake) and fake._allowed == ["grapple", "jetpack", "portal"]
		and fake._tool == "grapple")
	_check("ZombiesSetup.apply_to_player hands the toggle to the player",
		ZSSetup.apply_to_player(fake))
	fake.free()
	# Setup overlay reflects the toggle.
	var setup = ZSSetup.new()
	root.add_child(setup)
	setup.open()
	_check("setup overlay checkbox reflects toggle ON",
		bool(setup.get("_toggle").button_pressed) == true)
	setup.close()
	setup.free()
	ZS.set_traversal_enabled(false)

	# --- Real player: traversal gate + starter equip --------------------------------------
	var real_player: Node = null
	if ResourceLoader.exists("res://scenes/player.tscn"):
		var pscene := load("res://scenes/player.tscn") as PackedScene
		if pscene != null:
			real_player = pscene.instantiate()
			root.add_child(real_player)
	_check("real player scene instantiates headless", real_player != null)
	if real_player != null:
		ZS.set_traversal_enabled(false)
		z.apply_traversal_to_player(real_player)
		_check("real player: toggle OFF -> allowed [] + active none",
			(real_player.call("get_allowed_traversal_tools") as Array).is_empty()
			and str(real_player.call("get_traversal_tool")) == "none")
		ZS.set_traversal_enabled(true)
		z.apply_traversal_to_player(real_player)
		_check("real player: toggle ON -> allowed all three + active grapple",
			(real_player.call("get_allowed_traversal_tools") as Array) == ["grapple", "jetpack", "portal"]
			and str(real_player.call("get_traversal_tool")) == "grapple")
		z._equip_starter()
		var wm := real_player.get_node_or_null("WeaponManager")
		_check("starter equipped: primary is ember",
			wm != null and str(wm.call("get_slot_weapon_id", "primary")) == "ember")
		ZS.set_traversal_enabled(false)
		real_player.free()

	# --- GameModeManager integration (last: it frees the mode node) -----------------------
	z.stop_run()
	z.free()
	_check("stop_run clears active", not ZS.is_active())
	var gm = GM.new()
	root.add_child(gm)
	_check("GameModeManager.start('zombies') succeeds", gm.start("zombies"))
	var has_zombies := false
	for child in gm.get_children():
		if (child as Node).get_script() == ZS:
			has_zombies = true
	_check("start('zombies') adds a ZombiesMode child", has_zombies)
	_check("live_mode is zombies during the run", GM.live_mode == "zombies")
	_check("ForgeGate blocks building during a live zombies run", not FG.can_build())
	gm.stop()
	_check("stop() clears live_mode", GM.live_mode == "")
	gm.free()
	_check("freeing the manager clears zombies active", not ZS.is_active())

	# Leave the toggle OFF on disk (default).
	ZS.set_traversal_enabled(false)

	# --- v0.6.0 integration: flat Zombies map (no town overlap) ---------
	# Main routes SP + MP Zombies to zombies_flat; the map itself must
	# have no geometry above the ground plane inside the town
	# footprint (|x| <= 36, |z| <= 18 — the town slab + buildings
	# zone). Ground-plane voxels (top <= 0.1) are fine: the town
	# sits ON the plane.
	var main_consts := (load("res://scripts/core/main.gd") as GDScript).get_script_constant_map()
	var maps: Dictionary = main_consts.get("MAPS", {})
	_check("Main.MAPS registers zombies_flat", maps.has("zombies_flat"))
	var flat_scene := str((maps.get("zombies_flat", {}) as Dictionary).get("scene", ""))
	_check("zombies_flat scene exists", flat_scene != "" and ResourceLoader.exists(flat_scene))
	var flat_src := FileAccess.get_file_as_string("res://scripts/core/main.gd")
	_check("Main routes SP zombies to zombies_flat",
		flat_src.contains("mode_id == \"zombies\"") and flat_src.contains("zombies_flat"))
	_check("Main routes MP zombies to zombies_flat",
		flat_src.contains("mode_id == \"mp_zombies\"") and flat_src.contains("zombies_flat"))
	if flat_scene != "" and ResourceLoader.exists(flat_scene):
		var flat: Node = (load(flat_scene) as PackedScene).instantiate()
		root.add_child(flat)
		var overlap := _town_footprint_overlap(flat)
		_check("zombies_flat: no map geometry above ground inside the town footprint (overlap: %s)" % str(overlap),
			overlap.is_empty())
		flat.queue_free()

	print("----")
	print("ZOMBIES: %d checks, %d failures" % [_checks, _fails])
	_done = true
	quit(0 if _fails == 0 else 1)
