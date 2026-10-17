# verify_multiplayer_modes.gd — headless checks for FORGEFALL MP modes.
# Usage: godot --headless --path <project> --script res://tools/verify_multiplayer_modes.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Covers (MP worker): MP TD co-op starts with Forge building allowed +
# live_mode set (shared core HP sync); MP Zombies co-op starts, points
# per-player, cross-peer revive, shared doors, shared perks/box;
# MP TDM PvP + bot fill (puppets spawn incl. the NetPuppet_2 case,
# bot kills score, player-vs-bot kills do not); MP registry entries
# implemented; Forge building blocked in MP non-TD modes (local
# pipeline + remote NetForgeSync specs); traversal exactly-one choice
# in MP modes with player.gd enforcement ids ("portal", not
# "portal_gun").
#
# Two-peer sim: two MPModes instances in one tree (host + client),
# RPC handlers called directly — the same code path the wire uses
# (the verify_g4_tdm pattern). Direct calls pass the remote peer id
# explicitly where a real RPC would use get_remote_sender_id().
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

	func get_allowed_traversal_tools() -> Array[String]:
		return _allowed.duplicate()


var _fails := 0
var _checks := 0
var _started := false
var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	if not _started:
		_started = true
		_run_checks()
		if not _done:
			printerr("verify_multiplayer_modes aborted early (runtime error above)")
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


func _fake_spawn(_entry: Dictionary) -> Node:
	return Node3D.new()


func _run_checks() -> void:
	var mp_script := load("res://scripts/net/mp_modes.gd") as GDScript
	var gm_script := load("res://scripts/core/game_mode.gd") as GDScript
	var fg_script := load("res://scripts/forge/forge_gate.gd") as GDScript
	var nm_script := load("res://scripts/net/net_match.gd") as GDScript
	var sync_script := load("res://scripts/net/net_forge_sync.gd") as GDScript
	var zs_script := load("res://scripts/modes/zombies.gd") as GDScript
	var td_setup_script := load("res://scripts/modes/td_setup.gd") as GDScript

	# --- 1. Registry ------------------------------------------------------
	_check("MP registry: ensure_registered flips mp_tower_defense",
		bool(mp_script.call("ensure_registered"))
		and gm_script.is_implemented("mp_tower_defense"))
	_check("MP registry: mp_zombies implemented",
		gm_script.is_implemented("mp_zombies"))
	_check("MP registry: mp_tdm implemented",
		gm_script.is_implemented("mp_tdm"))
	_check("MP registry: MP menu order lists all three",
		gm_script.modes_for_scope("mp") == ["mp_tower_defense", "mp_tdm", "mp_zombies"])
	_check("MP registry: MP TD desc no longer 'Not implemented yet'",
		not str(gm_script.MODES["mp_tower_defense"]["desc"]).contains("Not implemented"))
	_check("MP registry: MP Zombies desc no longer 'Not implemented yet'",
		not str(gm_script.MODES["mp_zombies"]["desc"]).contains("Not implemented"))
	_check("MP registry: forge menu allowed for MP TD",
		gm_script.forge_menu_allowed("mp_tower_defense"))
	_check("MP registry: forge menu NOT allowed for MP Zombies/TDM",
		not gm_script.forge_menu_allowed("mp_zombies")
		and not gm_script.forge_menu_allowed("mp_tdm"))

	# --- 2. ForgeGate: MP modes -------------------------------------------
	_check("ForgeGate: allows mp_tower_defense",
		fg_script.can_build_for_mode("mp_tower_defense"))
	_check("ForgeGate: blocks mp_tdm / mp_zombies / bogus",
		not fg_script.can_build_for_mode("mp_tdm")
		and not fg_script.can_build_for_mode("mp_zombies")
		and not fg_script.can_build_for_mode("bogus"))
	gm_script.live_mode = "mp_tower_defense"
	_check("ForgeGate: live MP TD run -> allows", fg_script.can_build())
	gm_script.live_mode = "mp_tdm"
	_check("ForgeGate: live MP TDM run -> blocks", not fg_script.can_build())
	gm_script.live_mode = "mp_zombies"
	_check("ForgeGate: live MP Zombies run -> blocks", not fg_script.can_build())
	gm_script.live_mode = ""

	# --- 3. Remote Forge specs gated by match mode ------------------------
	var sync1: Node = sync_script.new()
	var sync2: Node = sync_script.new()
	sync1.call("set_peer_context", true, true, 1)
	sync2.call("set_peer_context", true, false, 2)
	sync1.set("spawn_handler", Callable(self, "_fake_spawn"))
	sync2.set("spawn_handler", Callable(self, "_fake_spawn"))
	var spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "bunker", "position": [8.0, 0.0, -8.0]}, "cost": 180, "ttl": 0}
	gm_script.live_mode = "mp_zombies"
	_check("NetForgeSync: host_place refused in live MP Zombies",
		(sync1.call("host_place", spec, 1, Vector3(8, 0, -8), Vector3.ZERO) as Dictionary).is_empty())
	gm_script.live_mode = "mp_tdm"
	_check("NetForgeSync: host_place refused in live MP TDM",
		(sync1.call("host_place", spec, 1, Vector3(8, 0, -8), Vector3.ZERO) as Dictionary).is_empty())
	gm_script.live_mode = "mp_tower_defense"
	var entry_td: Dictionary = sync1.call("host_place", spec, 1, Vector3(8, 0, -8), Vector3.ZERO)
	_check("NetForgeSync: host_place allowed in live MP TD",
		not entry_td.is_empty() and int(entry_td.get("instance_id", 0)) > 0)
	gm_script.live_mode = "mp_zombies"
	_check("NetForgeSync: apply_place refused in live MP Zombies",
		sync2.call("apply_place", entry_td) == null)
	gm_script.live_mode = "mp_tower_defense"
	var node_td: Node = sync2.call("apply_place", entry_td)
	_check("NetForgeSync: apply_place allowed in live MP TD",
		node_td != null and is_instance_valid(node_td))
	gm_script.live_mode = ""
	sync1.call("clear")
	sync2.call("clear")

	# --- 4. MPModes start guards -------------------------------------------
	var bad: Node = mp_script.new()
	root.add_child(bad)
	_check("MPModes: unknown mode refused",
		not bool(bad.call("start_mp", "bogus", [1, 2], {1: "A", 2: "B"}, true, 1)))
	_check("MPModes: empty roster refused",
		not bool(bad.call("start_mp", "mp_tdm", [], {}, true, 1)))
	_check("MPModes: refused start leaves live_mode empty",
		str(gm_script.call("get_live_mode")) == "")
	bad.queue_free()

	# --- 5. MP Tower Defense co-op ------------------------------------------
	var td_host: Node = mp_script.new()
	var td_client: Node = mp_script.new()
	root.add_child(td_host)
	root.add_child(td_client)
	_check("MP TD: host starts",
		bool(td_host.call("start_mp", "mp_tower_defense", [1, 2], {1: "HOST", 2: "VIPER"}, true, 1)))
	_check("MP TD: live_mode set to mp_tower_defense",
		str(gm_script.call("get_live_mode")) == "mp_tower_defense")
	_check("MP TD: Forge building allowed in the live match",
		fg_script.can_build())
	var td_h: Node = td_host.get("_td")
	_check("MP TD: host runs a TowerDefenseMode",
		td_h != null and is_instance_valid(td_h))
	_check("MP TD: host core full, build phase",
		td_h != null and float(td_h.get("core_hp")) == 1000.0  # CORE_MAX_HP (const: .get() cannot read consts)
		and str(td_h.get("phase")) == "build")
	_check("MP TD: client starts",
		bool(td_client.call("start_mp", "mp_tower_defense", [1, 2], {1: "HOST", 2: "VIPER"}, false, 2)))
	var td_c: Node = td_client.get("_td")
	_check("MP TD: client runs a TowerDefenseMode",
		td_c != null and is_instance_valid(td_c))
	# Core HP sync: host core takes damage -> client mirrors it.
	td_h.call("_damage_core", 100.0)
	var snap: Dictionary = td_host.call("td_state_snapshot")
	td_client.call("_rpc_td_core", float(snap.get("core_hp", -1.0)),
		int(snap.get("wave", 0)), str(snap.get("phase", "")))
	_check("MP TD: core HP syncs host -> client (1000 -> 900)",
		td_c != null and float(td_c.get("core_hp")) == 900.0)
	td_host.call("stop_mp")
	td_client.call("stop_mp")
	_check("MP TD: stop clears live_mode",
		str(gm_script.call("get_live_mode")) == "")

	# --- 6. MP Zombies co-op -------------------------------------------------
	var z_host: Node = mp_script.new()
	var z_client: Node = mp_script.new()
	root.add_child(z_host)
	root.add_child(z_client)
	_check("MP Zombies: host starts",
		bool(z_host.call("start_mp", "mp_zombies", [1, 2], {1: "HOST", 2: "VIPER"}, true, 1)))
	_check("MP Zombies: live_mode set to mp_zombies",
		str(gm_script.call("get_live_mode")) == "mp_zombies")
	_check("MP Zombies: Forge building blocked in the live match",
		not fg_script.can_build())
	_check("MP Zombies: client starts",
		bool(z_client.call("start_mp", "mp_zombies", [1, 2], {1: "HOST", 2: "VIPER"}, false, 2)))
	var zh: Node = z_host.get("_zombies")
	var zc: Node = z_client.get("_zombies")
	_check("MP Zombies: both peers run a ZombiesMode",
		zh != null and zc != null and is_instance_valid(zh) and is_instance_valid(zc))
	# Shared seed: same perks + wall buys on both peers.
	z_client.call("_rpc_zombies_seed", int(z_host.get("_zombies_seed")))
	var perks_match := true
	var wall_match := true
	for m in zs_script.MACHINE_SPOTS:
		if zh.call("machine_perk", str(m.get("id", ""))) != zc.call("machine_perk", str(m.get("id", ""))):
			perks_match = false
	for s in zs_script.WALL_BUY_SPOTS:
		if str(zh.call("wall_buy", str(s.get("id", ""))).get("weapon_id", "")) != str(zc.call("wall_buy", str(s.get("id", ""))).get("weapon_id", "")):
			wall_match = false
	_check("MP Zombies: shared seed -> identical perk machines", perks_match)
	_check("MP Zombies: shared seed -> identical wall buys", wall_match)
	# Points per player: each peer authoritative for its own points.
	zh.call("add_points", 0, 1000)
	_check("MP Zombies: host points mirror (peer 1 = 1000)",
		int((z_host.get("_z_points") as Dictionary).get(1, -1)) == 1000)
	z_client.call("_rpc_zombies_points", 1, 1000)
	_check("MP Zombies: host points replicate to client",
		int((z_client.get("_z_points") as Dictionary).get(1, -1)) == 1000
		and zc.call("get_points", 1) == 1000)
	zc.call("add_points", 0, 500)
	_check("MP Zombies: client points mirror (peer 2 = 500)",
		int((z_client.get("_z_points") as Dictionary).get(2, -1)) == 500)
	z_host.call("_rpc_zombies_points", 2, 500)
	_check("MP Zombies: client points replicate to host",
		int((z_host.get("_z_points") as Dictionary).get(2, -1)) == 500)
	# Shared doors: client buy forwards (mp_pending, nothing opens
	# locally); host validates against the mirrored points.
	var pending: Dictionary = zc.call("buy_door", 0, "north_alley")
	_check("MP Zombies: client door buy forwards, opens nothing locally",
		str(pending.get("error", "")) == "mp_pending" and not zc.call("is_door_open", "north_alley"))
	z_host.call("_rpc_zombies_request_door", "north_alley", 2)
	_check("MP Zombies: host refuses the door (500 < 750 cost)",
		not zh.call("is_door_open", "north_alley"))
	zc.call("add_points", 0, 2000)  # client now 2500
	z_host.call("_rpc_zombies_points", 2, 2500)
	z_host.call("_rpc_zombies_request_door", "north_alley", 2)
	_check("MP Zombies: host opens the door + charges the buyer (2500 -> 1750)",
		zh.call("is_door_open", "north_alley")
		and int((z_host.get("_z_points") as Dictionary).get(2, -1)) == 1750)
	z_client.call("_rpc_zombies_door", "north_alley", 2, 1750)
	_check("MP Zombies: door + charge replicate to the buyer",
		zc.call("is_door_open", "north_alley")
		and int((z_client.get("_z_points") as Dictionary).get(2, -1)) == 1750
		and zc.call("get_points", 0) == 1750)
	# Cross-peer revive: client downed -> host revives -> client back up.
	zc.call("down_player", 0)
	_check("MP Zombies: client downed locally",
		zc.call("is_downed", 0))
	z_host.call("_rpc_zombies_downed", 2)
	_check("MP Zombies: downed state replicates to host",
		bool((z_host.get("_z_downed") as Dictionary).get(2, false))
		and zh.call("is_downed", 2))
	z_host.call("_rpc_zombies_request_revive", 2, 1)
	var host_pts_after := int((z_host.get("_z_points") as Dictionary).get(1, -1))
	_check("MP Zombies: host revive clears downed + pays 5% (1000 + 87 = 1087)",
		host_pts_after == 1087
		and not bool((z_host.get("_z_downed") as Dictionary).get(2, true)))
	z_client.call("_rpc_zombies_revived", 1, 2, 1087)
	_check("MP Zombies: revive replicates (client up, reviver paid)",
		not zc.call("is_downed", 2)
		and int((z_client.get("_z_points") as Dictionary).get(1, -1)) == 1087)
	# Perks mirror: client buys a perk locally -> host learns it.
	zc.call("add_points", 0, 10000)
	z_host.call("_rpc_zombies_points", 2, 11750)
	var machine_id := str((zh.call("machine_perk", "bank")))  # perk id at the bank machine
	var perk_res: Dictionary = zc.call("buy_perk", 0, "bank")
	_check("MP Zombies: client buys a perk locally",
		bool(perk_res.get("ok", false)))
	var client_perks: Array = (z_client.get("_z_perks") as Dictionary).get(2, [])
	_check("MP Zombies: bought perk mirrored on the buyer",
		client_perks.has(machine_id))
	z_host.call("_rpc_zombies_perks", 2, client_perks.duplicate())
	_check("MP Zombies: perks replicate to host",
		((z_host.get("_z_perks") as Dictionary).get(2, []) as Array).has(machine_id))
	# Mystery Box spot: host teddy roll -> client follows.
	var spot_before := int(zh.get("box_spot"))
	zh.call("roll_box", true, -1)
	var spot_after := int(zh.get("box_spot"))
	z_client.call("_rpc_zombies_box", spot_after)
	_check("MP Zombies: box spot replicates after teddy move",
		spot_after != spot_before and int(zc.get("box_spot")) == spot_after)
	# Traversal toggle (while the run is live): OFF = none, ON = all three.
	zs_script.call("set_traversal_enabled", false)
	var fake := FakePlayer.new()
	root.add_child(fake)
	_check("MP Zombies: traversal OFF -> no tools (none)",
		bool(mp_script.call("apply_traversal", fake, "mp_zombies"))
		and fake.get_traversal_tool() == "none")
	zs_script.call("set_traversal_enabled", true)
	_check("MP Zombies: traversal ON -> all three allowed, active grapple",
		bool(mp_script.call("apply_traversal", fake, "mp_zombies"))
		and fake.get_traversal_tool() == "grapple"
		and (fake.get_allowed_traversal_tools() as Array).size() == 3)
	zs_script.call("set_traversal_enabled", false)
	fake.queue_free()
	z_host.call("stop_mp")
	z_client.call("stop_mp")
	_check("MP Zombies: stop clears live_mode",
		str(gm_script.call("get_live_mode")) == "")

	# --- 7. MP TDM PvP + bots -------------------------------------------------
	var nm: Node = nm_script.new()
	nm.name = "NetMatch"
	root.add_child(nm)
	_check("MP TDM: NetMatch starts (2 peers)",
		bool(nm.call("start_match", [1, 2], {1: "HOST", 2: "VIPER"}, "tdm", 25, 0.0)))
	_check("MP TDM: NetPuppet_2 spawns (standalone, no online NetManager)",
		nm.get_node_or_null("NetPuppet_2") != null)
	nm.call("record_bot_kill", 1, 0, "VIPER", "YOU")
	_check("MP TDM: bot kill scores (BRAVO 1)",
		(nm.call("get_team_scores") as Array) == [0, 1])
	_check("MP TDM: bot kill recorded in _bot_scores",
		(nm.get("_bot_scores") as Array) == [0, 1])
	nm.call("record_bot_kill", 0, 0, "VIPER", "GHOST")
	_check("MP TDM: friendly bot kill scores nothing",
		(nm.call("get_team_scores") as Array) == [0, 1])
	var tdm: Node = mp_script.new()
	root.add_child(tdm)
	_check("MP TDM: MPModes starts",
		bool(tdm.call("start_mp", "mp_tdm", [1, 2], {1: "HOST", 2: "VIPER"}, true, 1)))
	_check("MP TDM: live_mode set to mp_tdm",
		str(gm_script.call("get_live_mode")) == "mp_tdm")
	_check("MP TDM: Forge blocked in the live match",
		not fg_script.can_build())
	var bots: Array = tdm.get("bots")
	_check("MP TDM: bots fill teams to 3v3 (2 bots per team, 4 total)",
		bots.size() == 4)
	var allies := 0
	var enemies := 0
	for b in bots:
		if int(b.get("team_id")) == 0:
			allies += 1
		else:
			enemies += 1
	_check("MP TDM: bot split is 2 ALPHA / 2 BRAVO", allies == 2 and enemies == 2)
	# Bot-vs-bot kill: attacker bot -> victim bot scores + respawn queued.
	var victim: Node = null
	var attacker: Node = null
	for b in bots:
		if int(b.get("team_id")) == 1 and victim == null:
			victim = b
		if int(b.get("team_id")) == 0 and attacker == null:
			attacker = b
	if victim != null and attacker != null:
		victim.set("last_attacker", attacker)
		tdm.call("on_enemy_died", victim)
	_check("MP TDM: bot-vs-bot kill scores via NetMatch (ALPHA 1, BRAVO 1)",
		(nm.call("get_team_scores") as Array) == [1, 1]
		and (tdm.get("bot_kills") as Array) == [1, 0])
	_check("MP TDM: dead bot queued for respawn",
		(tdm.get("_respawns") as Array).size() == 1)
	# Bot-vs-player kill: Game.player_died with a bot attacker scores.
	var killer_bot: Node = null
	for b in bots:
		if int(b.get("team_id")) == 1:
			killer_bot = b
			break
	tdm.set("_last_player_attacker", killer_bot)
	tdm.set("_elapsed", 10.0)
	tdm.set("_last_player_hit_t", 9.0)
	var game_node: Node = root.get_node_or_null("Game")
	if game_node != null and game_node.has_signal("player_died"):
		game_node.emit_signal("player_died")
	_check("MP TDM: bot killing the player scores (ALPHA 1, BRAVO 2)",
		(nm.call("get_team_scores") as Array) == [1, 2])
	# Player-vs-bot kill scores nothing (filler, not a farm).
	var victim2: Node = null
	for b in bots:
		if int(b.get("team_id")) == 1 and b != victim:
			victim2 = b
			break
	if victim2 != null:
		var player_node: Node = Node.new()
		player_node.add_to_group("player")
		root.add_child(player_node)
		victim2.set("last_attacker", player_node)
		tdm.call("on_enemy_died", victim2)
		player_node.queue_free()
	_check("MP TDM: player killing a bot scores nothing (still ALPHA 1, BRAVO 2)",
		(nm.call("get_team_scores") as Array) == [1, 2])
	tdm.call("stop_mp")
	_check("MP TDM: stop clears live_mode",
		str(gm_script.call("get_live_mode")) == "")
	nm.call("stop_match")
	nm.queue_free()

	# --- 8. Traversal: exactly-one + enforcement ids -------------------------
	var fake2 := FakePlayer.new()
	root.add_child(fake2)
	_check("Traversal: normalize legacy 'portal_gun' -> 'portal' (alias)",
		str(mp_script.call("normalize_traversal", "portal_gun")) == "portal")
	_check("Traversal: normalize 'portal' stays 'portal' (canonical)",
		str(mp_script.call("normalize_traversal", "portal")) == "portal")
	_check("Traversal: MP TDM applies portal loadout as 'portal'",
		bool(mp_script.call("apply_traversal", fake2, "mp_tdm", "portal"))
		and fake2.get_traversal_tool() == "portal"
		and (fake2.get_allowed_traversal_tools() as Array) == ["portal"])
	td_setup_script.call("set_tool", "jetpack")
	_check("Traversal: MP TD applies the pre-run choice (jetpack, exactly one)",
		bool(mp_script.call("apply_traversal", fake2, "mp_tower_defense"))
		and fake2.get_traversal_tool() == "jetpack"
		and (fake2.get_allowed_traversal_tools() as Array) == ["jetpack"])
	td_setup_script.call("set_tool", "grapple")
	_check("Traversal: bogus tool sanitizes to the grapple default",
		bool(mp_script.call("apply_traversal", fake2, "mp_tdm", "bogus_tool"))
		and fake2.get_traversal_tool() == "grapple")
	fake2.queue_free()

	# --- 9. NetMatch standalone puppet regression (NetPuppet_2) --------------
	var nm2: Node = nm_script.new()
	root.add_child(nm2)
	_check("NetMatch: standalone start spawns NetPuppet_2",
		bool(nm2.call("start_match", [1, 2], {1: "A", 2: "B"}, "tdm", 25, 0.0))
		and nm2.get_node_or_null("NetPuppet_2") != null)
	nm2.call("stop_match")
	nm2.queue_free()

	# Final: no live mode leaks out of the suite.
	_check("Suite: live_mode empty at end",
		str(gm_script.call("get_live_mode")) == "")

	print("----")
	print("MULTIPLAYER MODES: %d checks, %d failures" % [_checks, _fails])
	_done = true
	quit(0 if _fails == 0 else 1)
