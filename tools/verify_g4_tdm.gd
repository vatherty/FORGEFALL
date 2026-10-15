# verify_g4_tdm.gd — headless checks for FORGEFALL Goal 4 (Worker C: TDM).
# Usage: godot --headless --path <project> --script res://tools/verify_g4_tdm.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Strategy: no real network in this verifier. The host logic is driven
# directly through _host_on_hit() — the exact function the client RPC
# _rpc_report_hit() calls with the verified sender id — and a second
# NetMatch instance plays the client (roster/kill/snapshot/respawn RPC
# handlers called directly, same code path as over the wire). A live
# two-peer ENet round-trip is covered separately (see report) because a
# single SceneTree has one local peer id.
extends SceneTree

# Stand-in for Worker A's NetManager (duck-typed API only): signals +
# is_online / create_network_player / request_damage / get_puppet /
# unregister_puppet / get_players. Lets the verifier exercise NetMatch's
# DELEGATED mode without a real network.
class FakeNetManager extends Node:
	signal damage_applied(victim_id: int, attacker_id: int, amount: float, new_hp: float, died: bool)
	signal kill_confirmed(killer_id: int, victim_id: int, headshot: bool)
	signal score_changed(peer_id: int, kills: int, deaths: int, score: int)
	signal player_respawned(peer_id: int, spawn_pos: Vector3)
	signal player_left(peer_id: int)
	signal server_disconnected()
	var table := {}
	var last_request := {}
	var unregistered := []

	func is_online() -> bool:
		return true

	func create_network_player(_peer_id: int, _is_local: bool) -> Node:
		return Node.new()

	func request_damage(victim_id: int, amount: float, _pos: Vector3, _hs: bool, _w: String) -> void:
		last_request = {"victim": victim_id, "amount": amount}

	func get_puppet(_peer_id: int):
		return null

	func unregister_puppet(peer_id: int) -> void:
		unregistered.append(peer_id)

	func get_players() -> Dictionary:
		return table.duplicate(true)


var _fails := 0
var _checks := 0
var _started := false
var _done := false


# MainLoop pattern (verify_netcode.gd): _init runs before the tree is
# set up (multiplayer is null there), so checks run on the first
# _process tick and _done + quit() ends the loop.
func _process(_delta: float) -> bool:
	if _done:
		return true
	if not _started:
		_started = true
		_run_checks()
		if not _done:
			# _run_checks aborted on a runtime error before reaching
			# its tail (GDScript runtime errors unwind one frame).
			# Fail loudly instead of idling forever.
			printerr("verify_g4_tdm aborted early (runtime error above)")
			_done = true
			quit(1)
			return true
		quit(0 if _fails == 0 else 1)
		return true
	return false
var _kill_events: Array = []
var _end_events: Array = []


func _check(name: String, cond: bool) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % name)
	else:
		_fails += 1
		printerr("FAIL: %s" % name)


func _on_kill(a: String, b: String, w: String, kt: int, vt: int, hs: bool, su: bool) -> void:
	_kill_events.append([a, b, w, kt, vt, hs, su])


func _on_end(winner: int, result: Dictionary) -> void:
	_end_events.append([winner, result])


func _roster() -> Array:
	return [
		{"peer_id": 1, "name": "HOST", "team": 0},
		{"peer_id": 2, "name": "VIPER", "team": 1},
		{"peer_id": 3, "name": "GHOST", "team": 0},
		{"peer_id": 4, "name": "HAVOC", "team": 1},
	]


func _names() -> Dictionary:
	return {1: "HOST", 2: "VIPER", 3: "GHOST", 4: "HAVOC"}


func _run_checks() -> void:
	# Runtime load() (verify_content.gd pattern): the entry script must
	# not name these classes bare — that would compile them at startup
	# time, before autoload globals exist, via the Arsenal/Sfx chain.
	var match_script := load("res://scripts/net/net_match.gd") as GDScript
	var scoreboard_script := load("res://scripts/net/net_scoreboard.gd") as GDScript
	var killfeed_script := load("res://scripts/ui/killfeed.gd") as GDScript
	# --- host match ------------------------------------------------------
	var host = match_script.new()
	root.add_child(host)
	host.kill_confirmed.connect(_on_kill)
	host.match_ended.connect(_on_end)
	_check("start_match accepts tdm (host, 4 players)",
		host.start_match([1, 2, 3, 4], _names(), "tdm", 3, 0.0))
	_check("match active after start", host.match_active)
	_check("teams balanced: 1->ALPHA 2->BRAVO 3->ALPHA 4->BRAVO",
		host.get_player_info(1)["team"] == 0
		and host.get_player_info(2)["team"] == 1
		and host.get_player_info(3)["team"] == 0
		and host.get_player_info(4)["team"] == 1)
	_check("scoreboard has 4 rows", host.get_scoreboard().player_count() == 4)
	var p2 = host.get_node_or_null("NetPuppet_2")
	_check("puppet spawned for remote peer 2", p2 is Node and is_instance_valid(p2))
	_check("no puppet for local peer 1", host.get_node_or_null("NetPuppet_1") == null)
	_check("puppet in net_puppet group", (p2 as Node).is_in_group("net_puppet"))
	_check("puppet NOT in player group", not (p2 as Node).is_in_group("player"))
	var head := (p2 as Node).get_node_or_null("NetPuppetHead")
	_check("puppet head hitbox exists + in enemy_head group",
		head != null and head.is_in_group("enemy_head"))
	_check("no client-callable kill RPC exists",
		not host.has_method("_rpc_report_kill") and not host.has_method("report_kill"))

	# --- hit validation ---------------------------------------------------
	host._host_on_hit(2, 3, 25.0, "ar7", false)
	_check("hit applies damage (100 -> 75)", host.get_player_info(3)["hp"] == 75.0)
	host._host_on_hit(2, 3, 99999.0, "ar7", false)
	_check("forged 99999 damage clamped to ar7 max 25 (75 -> 50)",
		host.get_player_info(3)["hp"] == 50.0)
	host._host_on_hit(2, 4, 25.0, "ar7", false)
	_check("friendly fire ignored (peer 4 still 100)",
		host.get_player_info(4)["hp"] == 100.0)
	host._host_on_hit(2, 2, 25.0, "ar7", false)
	_check("self-damage ignored (peer 2 still 100)",
		host.get_player_info(2)["hp"] == 100.0)
	host._host_on_hit(99, 3, 25.0, "ar7", false)
	_check("unknown attacker ignored (peer 3 still 50)",
		host.get_player_info(3)["hp"] == 50.0)
	host._host_on_hit(2, 3, -10.0, "ar7", false)
	_check("negative damage ignored (peer 3 still 50)",
		host.get_player_info(3)["hp"] == 50.0)
	host._host_on_hit(2, 3, NAN, "ar7", false)
	_check("NaN damage ignored (peer 3 still 50)",
		host.get_player_info(3)["hp"] == 50.0)

	# --- puppet hit forwarding (shooter = host peer 1, team ALPHA) -------
	(p2 as Node).call("take_damage", 25.0, Vector3.ZERO, false)
	_check("puppet.take_damage forwards to host (peer 2: 100 -> 75)",
		host.get_player_info(2)["hp"] == 75.0)
	head.call("take_damage", 10.0, Vector3.ZERO, false)
	_check("puppet head hit forwards as headshot (peer 2: 75 -> 65)",
		host.get_player_info(2)["hp"] == 65.0)

	# --- kill --------------------------------------------------------------
	host._host_on_hit(2, 3, 25.0, "ar7", false)  # 50 -> 25
	host._host_on_hit(2, 3, 25.0, "ar7", false)  # 25 -> 0, kill
	_check("kill: killer has 1 kill", host.get_player_info(2)["kills"] == 1)
	_check("kill: victim has 1 death + 0 hp + dead",
		host.get_player_info(3)["deaths"] == 1
		and host.get_player_info(3)["hp"] == 0.0
		and not bool(host.get_player_info(3)["alive"]))
	_check("kill: BRAVO team score 1", host.get_team_scores() == [0, 1])
	_check("kill_confirmed emitted with display args",
		_kill_events.size() == 1 and _kill_events[0][0] == "VIPER"
		and _kill_events[0][1] == "GHOST"
		and _kill_events[0][2] == "AR-7 MANTICORE"
		and _kill_events[0][3] == 1 and _kill_events[0][4] == 0)
	host._host_on_hit(2, 3, 25.0, "ar7", false)
	_check("hits on a dead player ignored (still 1 death)",
		host.get_player_info(3)["deaths"] == 1)

	# --- client convergence -------------------------------------------------
	var client = match_script.new()
	root.add_child(client)
	client._rpc_begin_match(_roster(),
		{"mode": "tdm", "score_limit": 3, "time_limit": 0.0})
	_check("client match active after begin broadcast", client.match_active)
	_check("client teams match host",
		client.get_player_info(2)["team"] == 1
		and client.get_player_info(3)["team"] == 0)
	client._rpc_kill_event(2, 3, "ar7", false)
	client._rpc_sync_scoreboard(host.get_scoreboard().serialize())
	_check("client scoreboard converges after kill + snapshot",
		client.get_scoreboard().serialize() == host.get_scoreboard().serialize())
	_check("client sees victim dead",
		not bool(client.get_player_info(3)["alive"]))

	# --- puppet state --------------------------------------------------------
	host._apply_puppet_state(2, Vector3(5, 1, 5), 1.0)
	_check("puppet snaps to first snapshot",
		((p2 as Node3D).global_position - Vector3(5, 1, 5)).length() < 0.01)
	host._apply_puppet_state(1, Vector3(99, 1, 99), 0.0)
	_check("self puppet state ignored (no puppet for local)",
		host.get_node_or_null("NetPuppet_1") == null)
	host._apply_puppet_state(99, Vector3.ZERO, 0.0)
	_check("unknown peer puppet state ignored (no crash)", true)

	# --- respawn ---------------------------------------------------------------
	host._process(3.5)  # respawn timer (3.0s) expires
	_check("host respawns victim after delay (alive, 100 hp)",
		bool(host.get_player_info(3)["alive"])
		and host.get_player_info(3)["hp"] == 100.0)
	client._rpc_respawn(3, Vector3(0, 1, 0))
	_check("client respawns victim on broadcast",
		bool(client.get_player_info(3)["alive"]))

	# --- win condition (score limit 3, BRAVO) ----------------------------------
	host._host_on_hit(2, 1, 500.0, "lr8", true)  # capped to 240 -> kill, 2-0
	_check("sniper headshot capped kill works (BRAVO 2)",
		host.get_team_scores() == [0, 2])
	host._process(3.5)  # respawn peer 1
	host._host_on_hit(4, 1, 500.0, "lr8", false)  # capped to 120 -> kill, 3-0
	_check("match ends at score limit", not host.match_active)
	_check("winner is BRAVO (team 1)", _end_events.size() == 1
		and _end_events[0][0] == 1)
	_check("result carries team scores + reason",
		_end_events[0][1]["team_scores"] == [0, 3]
		and _end_events[0][1]["reason"] == "score_limit")
	_check("result rows sorted, top = a BRAVO player",
		_end_events[0][1]["rows"][0]["team"] == 1)
	host.report_hit(2, 25.0, "ar7", false)
	_check("hits after match end ignored", host.get_player_info(2)["hp"] == 65.0)
	host.stop_match()
	_check("stop_match clears players", host.get_match_state()["players"] == 0)

	# --- client receives match end ---------------------------------------------
	client._rpc_match_end(1, host.get_result())
	_check("client match ends on broadcast", not client.match_active)

	# --- coop rejected ----------------------------------------------------------
	var m_coop = match_script.new()
	root.add_child(m_coop)
	_check("start_match('coop') returns false (deferred, no silent fallback)",
		not m_coop.start_match([1, 2], {1: "A", 2: "B"}, "coop", 25, 0.0))
	_check("coop rejection leaves match inactive", not m_coop.match_active)
	_check("start_match with 1 player returns false",
		not m_coop.start_match([1], {1: "A"}, "tdm", 25, 0.0))

	# --- double start rejected ---------------------------------------------------
	var m4 = match_script.new()
	root.add_child(m4)
	_check("first start ok", m4.start_match([1, 2], {1: "A", 2: "B"}, "tdm", 25, 0.0))
	_check("second start rejected (already active)",
		not m4.start_match([1, 2], {1: "A", 2: "B"}, "tdm", 25, 0.0))
	m4.stop_match()

	# --- time limit -> draw --------------------------------------------------------
	var m2 = match_script.new()
	root.add_child(m2)
	_end_events.clear()
	m2.match_ended.connect(_on_end)
	m2.start_match([1, 2], {1: "A", 2: "B"}, "tdm", 25, 5.0)
	m2._process(5.1)
	_check("time limit ends match as draw (0-0)",
		not m2.match_active and _end_events.size() == 1
		and _end_events[0][0] == -1
		and _end_events[0][1]["reason"] == "time_limit"
		and bool(_end_events[0][1]["draw"]))

	# --- disconnect -> forfeit ------------------------------------------------------
	var m3 = match_script.new()
	root.add_child(m3)
	_end_events.clear()
	m3.match_ended.connect(_on_end)
	m3.start_match([1, 2, 3, 4], _names(), "tdm", 25, 0.0)
	m3._on_peer_disconnected(4)
	_check("disconnect removes leaver (3 left)",
		m3.get_match_state()["players"] == 3)
	m3._on_peer_disconnected(3)
	_check("second disconnect still running (2 left)", m3.match_active)
	m3._on_peer_disconnected(2)
	_check("last-but-one disconnect forfeits to remaining team",
		not m3.match_active and _end_events.size() == 1
		and _end_events[0][0] == 0
		and _end_events[0][1]["reason"] == "forfeit")

	# --- killfeed --------------------------------------------------------------------
	var kf = killfeed_script.new()
	root.add_child(kf)
	kf.add_entry("VIPER", "GHOST", "AR-7 MANTICORE", 1, 0, false, false)
	_check("killfeed shows 1 entry", kf.entry_count_visible() == 1)
	kf.add_entry("VIPER", "GHOST", "LR-8 LONGEYE", 1, 0, true, false)
	_check("killfeed shows 2 entries", kf.entry_count_visible() == 2)
	_check("killfeed headshot entry carries [HEADSHOT]",
		str(kf._labels[1].text).find("HEADSHOT") >= 0)
	for i in 8:
		kf.add_entry("A", "B", "AR7", 0, 1, false, false)
	_check("killfeed caps at MAX_ENTRIES (6)", kf.entry_count_visible() == 6)
	kf._process(4.6)
	_check("killfeed fades out after FADE_AFTER + FADE_TIME",
		kf.entry_count_visible() == 0)

	# --- scoreboard visibility ---------------------------------------------------------
	var sb = scoreboard_script.new()
	root.add_child(sb)
	sb.set_scoreboard_visible(true)
	_check("scoreboard visible after set true", sb.visible)
	sb.toggle_scoreboard()
	_check("scoreboard hidden after toggle", not sb.visible)
	sb.register_player(1, "HOST", 0)
	sb.register_player(2, "VIPER", 1)
	sb.record_kill(2, 1)
	_check("scoreboard data: kill recorded",
		sb.get_team_scores() == [0, 1]
		and sb.row_for(2)["kills"] == 1
		and sb.row_for(1)["deaths"] == 1)
	var sb2 = scoreboard_script.new()
	root.add_child(sb2)
	sb2.apply_snapshot(sb.serialize())
	_check("scoreboard snapshot round-trips",
		sb2.serialize() == sb.serialize())

	# --- delegated mode (NetManager present) --------------------------------
	var fake := FakeNetManager.new()
	fake.name = "NetManager"
	root.add_child(fake)
	var dm = match_script.new()
	root.add_child(dm)
	_kill_events.clear()
	_end_events.clear()
	dm.kill_confirmed.connect(_on_kill)
	dm.match_ended.connect(_on_end)
	_check("delegated: start ok (limit 2)", dm.start_match([1, 2, 3, 4], _names(), "tdm", 2, 0.0))
	_check("delegated: factory puppets used, no NetPuppets",
		dm.get_node_or_null("NetPuppet_2") == null
		and dm.get_node_or_null("NetPlayer_2") != null)
	_check("delegated: local state shim created",
		dm.get_node_or_null("NetPlayer_Local") != null)
	_check("delegated: no own respawn timers scheduled",
		dm._respawn_timers.is_empty())
	fake.kill_confirmed.emit(2, 3, false)
	_check("delegated: killfeed emitted from NM kill",
		_kill_events.size() == 1 and _kill_events[0][0] == "VIPER"
		and _kill_events[0][1] == "GHOST"
		and _kill_events[0][2] == "WEAPON")
	fake.score_changed.emit(2, 1, 0, 100)
	fake.score_changed.emit(3, 0, 1, 0)
	_check("delegated: team score from mirror [0,1]", dm.get_team_scores() == [0, 1])
	_check("delegated: scoreboard mirrors NM points (100, not +1)",
		dm.get_scoreboard().row_for(2)["score"] == 100
		and dm.get_scoreboard().row_for(2)["kills"] == 1)
	_check("delegated: victim marked dead",
		not bool(dm.get_player_info(3)["alive"]))
	fake.damage_applied.emit(1, 2, 25.0, 75.0, false)
	_check("delegated: damage mirrors HP (local 100 -> 75)",
		dm.get_player_info(1)["hp"] == 75.0)
	fake.last_request = {}
	dm.report_hit(3, 25.0, "ar7", false)
	_check("delegated: report_hit forwards to NM.request_damage",
		fake.last_request.get("victim") == 3
		and fake.last_request.get("amount") == 25.0)
	dm._host_on_hit(2, 4, 25.0, "ar7", false)
	_check("delegated: direct _host_on_hit ignored (NM owns damage)",
		dm.get_player_info(4)["hp"] == 100.0)
	# Win: second kill for VIPER. The victim's score broadcast would
	# arrive after the killer's in real play, so the finish refreshes
	# from NM's full table (fake.table) — victim deaths must read 1.
	fake.table = {
		1: {"name": "HOST", "kills": 0, "deaths": 1, "score": 0},
		2: {"name": "VIPER", "kills": 2, "deaths": 0, "score": 250},
		3: {"name": "GHOST", "kills": 0, "deaths": 1, "score": 0},
		4: {"name": "HAVOC", "kills": 0, "deaths": 1, "score": 0},
	}
	fake.kill_confirmed.emit(2, 4, true)
	fake.score_changed.emit(2, 2, 0, 250)
	_check("delegated: match ends at limit, BRAVO wins",
		not dm.match_active and _end_events.size() == 1
		and _end_events[0][0] == 1)
	var dm4_deaths := -1
	for row in _end_events[0][1]["rows"]:
		if int(row["peer_id"]) == 4:
			dm4_deaths = int(row["deaths"])
	_check("delegated: finish refreshes victim stats from NM table",
		dm4_deaths == 1)
	dm.stop_match()
	_check("delegated: stop unregisters puppets from NM",
		fake.unregistered.has(2) and fake.unregistered.has(3)
		and fake.unregistered.has(4))

	# Delegated: host-left abort.
	var dm2 = match_script.new()
	root.add_child(dm2)
	_end_events.clear()
	dm2.match_ended.connect(_on_end)
	dm2.start_match([1, 2], {1: "A", 2: "B"}, "tdm", 25, 0.0)
	fake.server_disconnected.emit()
	_check("delegated: host-left aborts match",
		not dm2.match_active and _end_events.size() == 1
		and _end_events[0][0] == -2
		and _end_events[0][1]["reason"] == "host_left")
	dm2.stop_match()

	# Delegated: player-left forfeit.
	var dm3 = match_script.new()
	root.add_child(dm3)
	_end_events.clear()
	dm3.match_ended.connect(_on_end)
	dm3.start_match([1, 2, 3, 4], _names(), "tdm", 25, 0.0)
	fake.player_left.emit(4)
	fake.player_left.emit(3)
	_check("delegated: two leavers, still running", dm3.match_active)
	fake.player_left.emit(2)
	_check("delegated: last-but-one leaver forfeits to ALPHA",
		not dm3.match_active and _end_events.size() == 1
		and _end_events[0][0] == 0
		and _end_events[0][1]["reason"] == "forfeit")
	dm3.stop_match()

	# Delegated: death + respawn mirror.
	var dm4 = match_script.new()
	root.add_child(dm4)
	dm4.start_match([1, 2], {1: "A", 2: "B"}, "tdm", 25, 0.0)
	fake.damage_applied.emit(2, 1, 100.0, 0.0, true)
	_check("delegated: NM death marks victim dead",
		not bool(dm4.get_player_info(2)["alive"]))
	fake.player_respawned.emit(2, Vector3(3, 1, 3))
	_check("delegated: NM respawn marks victim alive + full HP",
		bool(dm4.get_player_info(2)["alive"])
		and dm4.get_player_info(2)["hp"] == 100.0)
	dm4.stop_match()

	print("----")
	print("G4 TDM: %d checks, %d failures" % [_checks, _fails])
	_done = true
	quit(0 if _fails == 0 else 1)
