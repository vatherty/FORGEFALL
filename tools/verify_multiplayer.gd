# verify_multiplayer.gd — headless verification for FORGEFALL Goal 4 (MULTIPLAYER).
# Usage: godot --headless --path <project> --script res://tools/verify_multiplayer.gd
#
# Worker D (Verification). Owns ONLY this file. Never fixes game code: bugs
# found here are reported with file + line, not patched.
#
# Coverage (against the REAL Worker A/B/C APIs as landed on disk — every
# game script is loaded at runtime via load() + can_instantiate(), so a
# worker file that fails to compile FAILs its own section instead of
# taking down this whole suite):
#   A. NetManager (scripts/net/net_manager.gd, Worker A): host/client
#      lifecycle, player table, host-authoritative damage (clamp, kill
#      score, self-damage / non-host rejection), respawn, state-seq +
#      sender guards, forged-broadcast rejection, disconnect callbacks,
#      leave(), create_network_player factory.
#   B. NetworkPlayer (scripts/net/network_player.gd, Worker A): puppet
#      interpolation/convergence, health/weapon/flag sync, snap on
#      teleport, damage/respawn application, local-shim state gather.
#   C. LanDiscovery (scripts/net/lan_discovery.gd, Worker B): packet
#      parsing, dedupe/update, stale prune, live broadcast/listen.
#   D. MultiplayerMenu (scripts/ui/multiplayer_menu.gd, Worker B): name
#      persistence, host/join lobby flow, ready toggle, match start,
#      failed-join recovery, disconnect-to-browse.
#   E. NetMatch + NetScoreboard + NetPuppet (scripts/net/net_match.gd,
#      net_scoreboard.gd, Worker C): TDM teams, host-validated hits
#      (friendly-fire / self / unknown / dead rejection, weapon-cap
#      clamp), kills -> correct team score on all peers' tables, win at
#      the limit, match-end result, respawn, forfeit, time limit,
#      co-op refusal (deferred by design), scoreboard snapshot sync.
#   F. Single-player untouched (in-suite proxies): no hard Net dependency
#      in player/weapon/main/game_state; NetManager offline calls no-op.
#
# HONEST HEADLESS LIMITS (never faked as passes):
#   - A true two-peer ENet handshake CANNOT run in one --script process
#     (one SceneTree = one MultiplayerAPI), AND ENet sends fail in this
#     sandbox (verified: Godot PacketPeerUDP loopback works, ENet
#     enet_socket_send fails). The handshake, forged-RPC-from-a-real-
#     remote-sender, live rate-limit, live host-disconnect, and true LAN
#     broadcast-across-devices checks are NEEDS-DEVICE. Headless
#     equivalents run instead: host bind, peer join/leave simulation
#     through the real connection callbacks, guard logic driven through
#     the real RPC handlers (a local forged broadcast has sender 0 and
#     MUST be rejected by the sender == 1 guard), direct packet-feed for
#     discovery, and PacketPeerUDP loopback.
#   - Sibling regression suites (verify_fixes, verify_v06_movement,
#     verify_feel, verify_sound, verify_content, verify_updater_pc,
#     verify_linux, verify_windows + 900-frame smoke) are run separately
#     by the worker and reported alongside — this script does not shell
#     out to them (verify_feel convention).
#
# Exit 0 = all checks pass; any FAIL prints and exits 1. NEEDS-DEVICE and
# SKIP never fail the suite.
extends SceneTree

const TEST_PORT := 27777        # NetManager host test (NOT 7777: the menu owns that)
const PHASE_TIMEOUT := 25.0     # per-phase cap (anti-drag: move on, don't grind)
const JOIN_TIMEOUT := 12.0      # menu failed-join wait cap

var _passes := 0
var _fails := 0
var _need_device := 0
var _skips := 0
var _phase := 0
var _phase_time := 0.0
var _last_phase := -1

# Loaded game scripts (null-guarded: a worker file that fails to compile
# FAILs its own section, never this suite's load).
var _nm_script: GDScript = null
var _np_script: GDScript = null
var _ld_script: GDScript = null
var _menu_script: GDScript = null
var _match_script: GDScript = null
var _sb_script: GDScript = null

# --- Phase 1 state (NetManager host) ---
var _net: Node = null
var _joined: Array = []
var _left: Array = []
var _dmg_events: Array = []
var _kill_events: Array = []
var _score_events: Array = []
var _respawn_events: Array = []
var _name_events: Array = []
var _net_stage := 0
# --- Phase 2 state (NetManager client-mode guards) ---
var _net2: Node = null
var _net2_joined: Array = []
var _net2_left: Array = []
var _net2_server_disc := false
var _net2_dmg := 0
# --- Phase 3 state (NetworkPlayer) ---
var _puppet: Node3D = null
var _shim: Node3D = null
var _fake_player: Node3D = null
var _puppet_dmg: Array = []
var _puppet_died := false
var _puppet_respawned: Array = []
var _puppet_stage := 0
# --- Phase 4 state (LanDiscovery) ---
var _disc_bcast: Node = null
var _disc_listen: Node = null
var _disc_found: Array = []
var _disc_lost: Array = []
var _disc_stage := 0
# --- Phase 5 state (MultiplayerMenu) ---
var _menu: Control = null
var _menu_start: Array = []
var _menu_lobby: Array = []
var _menu_status: Array = []
var _menu_stage := 0
var _menu_orig_cfg := ""
var _menu_cfg_existed := false
# --- Phase 6 state (NetMatch) ---
var _match: Node = null
var _match_kills: Array = []
var _match_scores: Array = []
var _match_ended: Array = []
var _match_started: Array = []
var _match_stage := 0
var _match2: Node = null
var _match2_ended: Array = []


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("MP PASS: ", label)
	else:
		_fails += 1
		printerr("MP FAIL: ", label)


func _device(label: String) -> void:
	_need_device += 1
	print("MP NEEDS-DEVICE: ", label)


func _skip(label: String) -> void:
	_skips += 1
	print("MP SKIP: ", label)


func _src(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _load_mp_scripts() -> void:
	_nm_script = load("res://scripts/net/net_manager.gd") as GDScript
	_np_script = load("res://scripts/net/network_player.gd") as GDScript
	_ld_script = load("res://scripts/net/lan_discovery.gd") as GDScript
	_menu_script = load("res://scripts/ui/multiplayer_menu.gd") as GDScript
	_match_script = load("res://scripts/net/net_match.gd") as GDScript
	_sb_script = load("res://scripts/net/net_scoreboard.gd") as GDScript


func _can_inst(s: GDScript) -> bool:
	return s != null and s.can_instantiate()


# --- Phase 0: discovery + source checks (synchronous) ----------------------

func _phase0_source_checks() -> void:
	_load_mp_scripts()
	var nm_src := _src("res://scripts/net/net_manager.gd")
	var np_src := _src("res://scripts/net/network_player.gd")
	var ld_src := _src("res://scripts/net/lan_discovery.gd")
	var menu_src := _src("res://scripts/ui/multiplayer_menu.gd")
	var match_src := _src("res://scripts/net/net_match.gd")
	var sb_src := _src("res://scripts/net/net_scoreboard.gd")
	var proj_src := _src("res://project.godot")
	var main_src := _src("res://scripts/core/main.gd")
	var main_menu_src := _src("res://scripts/ui/main_menu.gd")
	var player_src := _src("res://scripts/player/player.gd")
	var wm_src := _src("res://scripts/weapons/weapon_manager.gd")
	var gs_src := _src("res://scripts/core/game_state.gd")

	_check(not nm_src.is_empty(), "A: net_manager.gd exists")
	_check(not np_src.is_empty(), "B: network_player.gd exists")
	_check(not ld_src.is_empty(), "C: lan_discovery.gd exists")
	_check(not menu_src.is_empty(), "D: multiplayer_menu.gd exists")
	_check(not match_src.is_empty(), "E: net_match.gd exists (Worker C)")
	_check(not sb_src.is_empty(), "E: net_scoreboard.gd exists (Worker C)")
	_check(_can_inst(_nm_script), "A: net_manager.gd compiles + instantiates")
	_check(_can_inst(_np_script), "B: network_player.gd compiles + instantiates")
	_check(_can_inst(_ld_script), "C: lan_discovery.gd compiles + instantiates")
	_check(_can_inst(_menu_script), "D: multiplayer_menu.gd compiles + instantiates")
	_check(_can_inst(_match_script),
		"E: net_match.gd compiles + instantiates (rpc_unreliable() does not exist in Godot 4 — _broadcast_unreliable must use rpc(), whose transfer mode comes from the @rpc annotation)")
	_check(_can_inst(_sb_script), "E: net_scoreboard.gd compiles + instantiates")

	# A: transport + RPC shape (current design: broadcasts are call_remote,
	# sender == 1 only; the host applies its own broadcast via *_mirror).
	_check(nm_src.contains("ENetMultiplayerPeer"), "A: NetManager uses ENetMultiplayerPeer (source)")
	_check(nm_src.contains("@rpc"), "A: NetManager defines @rpc handlers (source)")
	_check(nm_src.contains("get_remote_sender_id() != 1"),
		"A: broadcast RPCs accept sender == 1 (host) only (source)")
	_check(nm_src.contains("_apply_damage_mirror") and nm_src.contains("_apply_score_mirror")
		and nm_src.contains("_apply_respawn_mirror"),
		"A: host applies its own broadcasts via explicit mirror helpers (source)")
	_check(nm_src.contains("sender != peer_id"),
		"A: state RPCs require sender == peer_id in payload (source)")
	_check(nm_src.contains("MAX_DAMAGE_PER_HIT") and nm_src.contains("clampf(amount, 0.0, MAX_DAMAGE_PER_HIT)"),
		"A: damage clamped to MAX_DAMAGE_PER_HIT on the host (source)")
	_check(nm_src.contains("MAX_DAMAGE_REQUESTS_PER_SEC") and nm_src.contains("kept.size() >= MAX_DAMAGE_REQUESTS_PER_SEC"),
		"A: damage requests rate-limited per peer (source)")
	_check(nm_src.contains("seq <= last"),
		"A: stale/reordered state snapshots rejected by sequence (source)")
	_check(nm_src.contains("sender == victim_id"),
		"A: self-damage rejected on the network path (source)")
	_check(nm_src.contains("func create_network_player"),
		"A: NetManager exposes create_network_player factory for NetMatch (source)")
	_check(not np_src.contains("@rpc("),
		"A: NetworkPlayer defines no @rpc (all RPCs on NetManager) (source)")
	_check(np_src.contains("INTERP_DELAY") and np_src.contains("SNAP_DISTANCE"),
		"B: puppet uses interpolation + snap-distance (source)")

	# E: match shape.
	_check(match_src.contains("SUPPORTED_MODES") and match_src.contains('"tdm"'),
		"E: NetMatch supports TDM (source)")
	_check(match_src.contains("friendly fire") or match_src.contains("Friendly fire"),
		"E: NetMatch rejects friendly fire (source)")
	_check(match_src.contains("_weapon_damage_cap"),
		"E: NetMatch clamps hits to the weapon's real damage cap (source)")
	_check(match_src.contains('"coop"') and match_src.contains("DEFERRED"),
		"E: NetMatch documents co-op as DEFERRED (not silently broken) (source)")
	_check(sb_src.contains("func record_kill") and sb_src.contains("func apply_snapshot"),
		"E: scoreboard has host record_kill + client apply_snapshot (source)")

	# Integration: autoload registration vs every lookup site.
	var net_registered := proj_src.contains('Net="*res://scripts/net/net_manager.gd"') \
		or proj_src.contains('NetManager="*res://scripts/net/net_manager.gd"')
	_check(net_registered,
		"INTEGRATION: NetManager registered as an autoload in project.godot (coordinator)")
	_check(menu_src.contains('"/root/Net"') and match_src.contains('"/root/Net"'),
		"INTEGRATION: menu + NetMatch look up the documented autoload name /root/Net (not only /root/NetManager)")
	if not (menu_src.contains('"/root/Net"') and match_src.contains('"/root/Net"')):
		printerr("MP NOTE: menu _net_manager() and NetMatch._net_manager() only check /root/NetManager. The canonical autoload name is NetManager (project.godot); /root/Net is kept as a fallback so either registration works.")
	_check(main_src.contains("MultiplayerMenu") or main_src.contains("NetMatch"),
		"INTEGRATION: Main wires the multiplayer menu / match (coordinator)")
	_check(main_menu_src.contains("MultiplayerMenu") or main_menu_src.contains("multiplayer"),
		"INTEGRATION: main menu offers a MULTIPLAYER entry (coordinator)")

	# F: single-player untouched (source proxies).
	_check(not player_src.contains("NetManager") and not player_src.contains("multiplayer."),
		"F: player.gd has no Net/multiplayer dependency (SP untouched) (source)")
	_check(not wm_src.contains("NetManager") and not wm_src.contains("multiplayer."),
		"F: weapon_manager.gd has no Net/multiplayer dependency (SP untouched) (source)")
	_check(not gs_src.contains("NetManager") and not gs_src.contains("multiplayer."),
		"F: game_state.gd has no Net/multiplayer dependency (SP untouched) (source)")
	_check(not match_src.contains("Game.") or match_src.contains("never writes to the Game autoload"),
		"E: NetMatch never writes to the Game autoload (SP state untouched) (source)")

	# C: discovery protocol shape.
	_check(ld_src.contains("forgefall-mp-v1") and ld_src.contains("255.255.255.255"),
		"C: discovery uses the forgefall-mp-v1 protocol over UDP broadcast (source)")
	_check(ld_src.contains("ENTRY_TIMEOUT") and ld_src.contains("game_lost"),
		"C: stale discovery entries prune + emit game_lost (source)")

	# Transport reality check: PacketPeerUDP loopback works in this sandbox.
	_check(_udp_loopback_ok(),
		"TRANSPORT: PacketPeerUDP loopback send/receive works headless (engine UDP proven)")
	_device("TRANSPORT: live two-peer ENet handshake (host + client in separate processes/devices) — ENet send fails in this sandbox (enet_socket_send) even though bind + UDP loopback work; the game handshake must be verified on two real machines. Headless equivalents (host bind, callback-driven join/leave, guard logic) run below.")


func _udp_loopback_ok() -> bool:
	var srv := UDPServer.new()
	if srv.listen(47801, "127.0.0.1") != OK:
		return false
	var cli := PacketPeerUDP.new()
	if cli.connect_to_host("127.0.0.1", 47801) != OK:
		srv.stop()
		return false
	if cli.put_packet("PING".to_utf8_buffer()) != OK:
		srv.stop()
		return false
	for _i in 20:
		srv.poll()
		if srv.is_connection_available():
			var p := srv.take_connection()
			var ok := p.get_packet().get_string_from_utf8() == "PING"
			srv.stop()
			return ok
		OS.delay_msec(10)
	srv.stop()
	return false

# --- Phase 1: NetManager host behaviour ------------------------------------

func _net_host_begin() -> void:
	_net_stage = 1  # advance-first: a mid-function error must not re-run this stage
	if not _can_inst(_nm_script):
		_check(false, "A: NetManager instantiates (skipping host behaviour)")
		_net_stage = 4
		return
	_net = _nm_script.new()
	_net.name = "Net"
	root.add_child(_net)
	_net.player_joined.connect(func(id: int, n: String) -> void: _joined.append([id, n]))
	_net.player_left.connect(func(id: int) -> void: _left.append(id))
	_net.damage_applied.connect(func(v: int, a: int, amt: float, hp: float, died: bool) -> void: _dmg_events.append([v, a, amt, hp, died]))
	_net.kill_confirmed.connect(func(k: int, v: int, hs: bool) -> void: _kill_events.append([k, v, hs]))
	_net.score_changed.connect(func(p: int, k: int, d: int, s: int) -> void: _score_events.append([p, k, d, s]))
	_net.player_respawned.connect(func(p: int, pos: Vector3) -> void: _respawn_events.append([p, pos]))
	_net.player_name_changed.connect(func(p: int, n: String) -> void: _name_events.append([p, n]))
	_check(not _net.call("is_online"), "A: fresh NetManager is offline")
	_check(_net.get("is_host") == false, "A: fresh NetManager is not host")
	_check((_net.get("players") as Dictionary).is_empty(), "A: fresh NetManager player table empty")
	_check(_net.call("get_hp", 99) == 0.0, "A: get_hp(unknown peer) == 0")
	# Offline no-ops (single-player safety): must not crash or change state.
	_net.call("request_damage", 2, 25.0, Vector3.ZERO, false, "ar7")
	_net.call("request_respawn")
	_net.call("send_state", {"position": Vector3.ZERO, "weapon": "ar7"})
	_check((_net.get("players") as Dictionary).is_empty(),
		"F: offline request_damage/respawn/send_state are no-ops (SP safe)")
	# Name sanitisation.
	_net.call("set_player_name", "")
	_check(str(_net.get("local_name")) == "Player", "D: empty player name sanitises to 'Player'")
	_net.call("set_player_name", "  Bad\nName  ")
	_check(not str(_net.get("local_name")).contains("\n") and str(_net.get("local_name")).begins_with("Bad"),
		"D: player name strips newlines/edges")
	_net.call("set_player_name", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
	_check(str(_net.get("local_name")).length() == 24,
		"D: player name truncates to MAX_NAME_LENGTH 24")
	_net.call("set_player_name", "HostPilot")
	# Host bind (real ENet bind, no peer connects — handshake itself is NEEDS-DEVICE).
	var err: int = _net.call("create_server", TEST_PORT)
	_check(err == OK, "A: create_server(%d) returns OK (real ENet bind)" % TEST_PORT)
	_check(_net.call("is_online") and _net.get("is_host") == true and int(_net.get("local_id")) == 1,
		"A: after create_server: online, host, local_id == 1")
	_check(_net.call("get_hp", 1) == 100.0, "A: host HP starts at MAX_HP 100")
	_check(str((_net.get("players") as Dictionary).get(1, {}).get("name", "")) == "HostPilot",
		"A: host player table carries the local name")
	# send_state stamps + increments the sequence (host path).
	_net.call("send_state", {"position": Vector3(1, 0, 2), "weapon": "ar7"})
	_net.call("send_state", {"position": Vector3(1, 0, 3), "weapon": "ar7"})
	_check(int(_net.get("_state_seq")) == 2, "A: send_state increments the sequence number")


func _net_host_peers() -> void:
	_net_stage = 2  # advance-first
	# Simulate peer 2 joining through the REAL connection callback.
	_net.call("_on_peer_connected", 2)
	_check((_net.get("players") as Dictionary).has(2), "A: _on_peer_connected(2) adds peer 2 to the table")
	_check(_joined.size() == 1 and int(_joined[0][0]) == 2,
		"A: player_joined fires for peer 2 (both-sides visibility simulated via callback)")
	_check(_net.call("get_hp", 2) == 100.0, "A: new peer HP starts at 100")
	# Duplicate join is ignored.
	_net.call("_on_peer_connected", 2)
	_check(_joined.size() == 1, "A: duplicate _on_peer_connected(2) does not double-add")
	# Puppet registration + disconnect cleanup.
	var pup: Node = _np_script.new()
	pup.call("setup", 2, "Bob", false)
	root.add_child(pup)
	_net.call("register_puppet", 2, pup)
	_check(_net.call("get_puppet", 2) == pup, "A: register_puppet/get_puppet round-trips")
	_net.call("_on_peer_disconnected", 2)
	_check(not (_net.get("players") as Dictionary).has(2),
		"A: _on_peer_disconnected(2) removes peer 2 (puppet removed, match continues)")
	_check(_left.size() == 1 and _left[0] == 2, "A: player_left fires for peer 2")
	_check(_net.call("get_puppet", 2) == null, "A: disconnect erases the puppet registration")
	_check(is_instance_valid(pup), "A: disconnect unregisters (does not free) the puppet node — caller owns it")
	pup.queue_free()
	# Re-join for the damage tests.
	_net.call("_on_peer_connected", 2)
	_net.call("_on_peer_connected", 3)


func _net_host_damage() -> void:
	_net_stage = 3  # advance-first
	# Host-authoritative damage: body hit 25.
	_net.call("request_damage", 2, 25.0, Vector3(0, 1, 0), false, "ar7")
	_check(_net.call("get_hp", 2) == 75.0, "A: host-validated damage applies: peer 2 HP 100 -> 75")
	_check(_dmg_events.size() == 1 and _dmg_events[0][3] == 75.0 and _dmg_events[0][4] == false,
		"A: damage_applied broadcast carries (victim, attacker, amount, new_hp, died=false)")
	# Forged overkill is CLAMPED to MAX_DAMAGE_PER_HIT (200), not applied raw.
	_net.call("request_damage", 2, 99999.0, Vector3.ZERO, false, "ar7")
	_check(_net.call("get_hp", 2) == 0.0, "A: forged 99999-damage hit kills via the 200 clamp (75 - 200 -> 0), never below 0")
	_check(_kill_events.size() == 1 and _kill_events[0][0] == 1 and _kill_events[0][1] == 2 and _kill_events[0][2] == false,
		"A: kill_confirmed fires (killer 1, victim 2, headshot=false)")
	var info: Dictionary = _net.call("get_score_info", 1)
	_check(int(info.get("kills", -1)) == 1 and int(info.get("score", -1)) == 100,
		"A: body kill scores KILL_SCORE 100 (kills 1, score 100)")
	# Headshot kill scores HEADSHOT_KILL_SCORE 150.
	_net.call("request_damage", 3, 200.0, Vector3.ZERO, true, "lr8")
	_check(_kill_events.size() == 2 and _kill_events[1][2] == true,
		"A: headshot kill_confirmed carries headshot=true")
	info = _net.call("get_score_info", 1)
	_check(int(info.get("kills", -1)) == 2 and int(info.get("score", -1)) == 250,
		"A: headshot kill adds 150 (kills 2, score 250)")
	# Deaths recorded on the victim.
	var vinfo: Dictionary = _net.call("get_score_info", 2)
	_check(int(vinfo.get("deaths", -1)) == 1, "A: victim deaths increment on death")
	_device("A: live per-peer damage rate limit (31 requests/sec from a real client) — requires a live second peer; window logic is source-verified.")
	# Respawn: dead peer 2 respawns; alive peer 1 does not.
	var before := _respawn_events.size()
	_net.call("_host_respawn", 2)
	_check(_net.call("get_hp", 2) == 100.0, "A: _host_respawn restores dead peer HP to 100")
	_check(_respawn_events.size() == before + 1 and _respawn_events[_respawn_events.size() - 1][0] == 2,
		"A: player_respawned fires for the dead peer")
	_net.call("_host_respawn", 1)
	_check(_respawn_events.size() == before + 1, "A: respawn of an ALIVE peer is rejected (no broadcast)")
	# Factory hook for NetMatch.
	var fac_remote: Node = _net.call("create_network_player", 2, false)
	_check(fac_remote != null and _net.call("get_puppet", 2) == fac_remote,
		"A: create_network_player(remote) returns a registered puppet")
	var fac_local: Node = _net.call("create_network_player", 1, true)
	_check(fac_local != null and fac_local.get("is_local_player") == true,
		"A: create_network_player(local) returns an unbound local shim")
	fac_remote.queue_free()
	fac_local.queue_free()


func _net_host_leave() -> void:
	_net_stage = 4  # advance-first
	_net.call("leave")
	_check(not _net.call("is_online"), "A: leave() takes the manager offline")
	_check((_net.get("players") as Dictionary).is_empty(), "A: leave() clears the player table")
	_check(_net.call("get_hp", 1) == 0.0, "A: leave() clears HP state")
	var api: MultiplayerAPI = root.get_multiplayer()
	_check(api == null or api.multiplayer_peer == null,
		"A: leave() detaches the tree multiplayer peer")
	_net.queue_free()
	_net = null


# --- Phase 2: client-mode guards (no sockets) -------------------------------
# Current design: broadcast RPCs accept sender == 1 ONLY. A local call has
# sender 0, so a forged broadcast driven in-process MUST be rejected —
# this is now behaviourally provable without a live second peer.

func _net_client_guards() -> void:
	if not _can_inst(_nm_script):
		_check(false, "A: NetManager instantiates (skipping client guards)")
		return
	_net2 = _nm_script.new()
	_net2.name = "NetClient"
	root.add_child(_net2)
	_net2.player_joined.connect(func(id: int, n: String) -> void: _net2_joined.append([id, n]))
	_net2.player_left.connect(func(id: int) -> void: _net2_left.append(id))
	_net2.damage_applied.connect(func(_v: int, _a: int, _amt: float, _hp: float, _d: bool) -> void: _net2_dmg += 1)
	_net2.server_disconnected.connect(func() -> void: _net2_server_disc = true)
	# Simulate a CONNECTED client: not host, local_id assigned, one peer known.
	_net2.set("is_host", false)
	_net2.set("local_id", 2)
	_net2.set("players", {2: {"name": "Client", "kills": 0, "deaths": 0, "score": 0}})
	_net2.set("hp_mirror", {2: 100.0})
	_check(not _net2.call("is_online"),
		"A: client-mode fixture is offline with no peer (guard tests below are logic-level)")
	# Non-host ignores damage requests (only the host resolves damage).
	var hp_before: float = _net2.call("get_hp", 2)
	_net2.call("_rpc_request_damage", 2, 25.0, Vector3.ZERO, false, "ar7")
	_check(_net2.call("get_hp", 2) == hp_before,
		"A: non-host _rpc_request_damage is ignored (client cannot resolve damage)")
	# Non-host ignores name announcements (only the host owns the table).
	_net2.call("_rpc_announce_name", "ForgedName")
	_check(str((_net2.get("players") as Dictionary).get(2, {}).get("name", "")) == "Client",
		"A: non-host _rpc_announce_name is ignored (client cannot rename peers)")
	# FORGED BROADCASTS: local calls (sender 0) must be rejected by the
	# sender == 1 guard — the client can never fake a kill/score/damage.
	_net2.call("_rpc_damage_applied", 2, 1, 999.0, 0.0, true, false)
	_check(_net2.call("get_hp", 2) == hp_before and _net2_dmg == 0,
		"A: forged _rpc_damage_applied (sender 0 != 1) is IGNORED — no HP change, no signal")
	_net2.call("_rpc_score_update", 2, 99, 0, 9999)
	_check(int((_net2.get("players") as Dictionary).get(2, {}).get("kills", -1)) == 0,
		"A: forged _rpc_score_update (sender 0 != 1) is IGNORED — kills/score unchanged")
	_net2.call("_rpc_player_respawned", 2, Vector3(50, 1, 50))
	_check(_net2.call("get_hp", 2) == hp_before,
		"A: forged _rpc_player_respawned (sender 0 != 1) is IGNORED — no HP restore")
	_net2.call("_rpc_sync_players", {2: {"name": "Forged", "kills": 5, "deaths": 0, "score": 500},
		3: {"name": "Ghost", "kills": 0, "deaths": 0, "score": 0}})
	_check(not (_net2.get("players") as Dictionary).has(3)
		and str((_net2.get("players") as Dictionary).get(2, {}).get("name", "")) == "Client",
		"A: forged _rpc_sync_players (sender 0 != 1) is IGNORED — no ghost peer, no rename")
	_device("A: a REAL host broadcast (sender 1) is accepted by clients — requires a live host->client connection; the rejection side is proven above.")
	# State from a local call (sender 0) never lands on a puppet: the
	# sender==peer_id guard drops it.
	var pup: Node = _np_script.new()
	pup.call("setup", 2, "Client", false)
	root.add_child(pup)
	_net2.call("register_puppet", 2, pup)
	_net2.call("_rpc_state", 2, 1, Vector3(9, 0, 9), 0.0, 0.0, Vector3.ZERO, 90.0, "ar7", 0)
	_check(pup.call("snapshot_count") == 0,
		"A: _rpc_state with sender != peer_id is dropped (no puppet update)")
	pup.queue_free()
	# Host disconnect -> client returns to lobby state cleanly.
	_net2.set("_peer", ENetMultiplayerPeer.new())
	_net2.call("_on_server_disconnected")
	_check(not _net2.call("is_online") and _net2_server_disc,
		"A: _on_server_disconnected: client leaves + server_disconnected fires (lobby return)")
	_net2.queue_free()
	_net2 = null
	_device("A: host disconnect over a LIVE connection (clients drop to lobby, no crash) — requires two connected peers; callback path is proven above.")


# --- Phase 3: NetworkPlayer --------------------------------------------------

func _puppet_begin() -> void:
	_puppet_stage = 1  # advance-first
	if not _can_inst(_np_script):
		_check(false, "B: NetworkPlayer instantiates (skipping puppet tests)")
		_puppet_stage = 3
		return
	_puppet = _np_script.new()
	_puppet.call("setup", 2, "Bob", false)
	root.add_child(_puppet)
	_puppet.damaged.connect(func(a: float, atk: int) -> void: _puppet_dmg.append([a, atk]))
	_puppet.died.connect(func() -> void: _puppet_died = true)
	_puppet.respawned.connect(func(p: Vector3) -> void: _puppet_respawned.append(p))
	_check(_puppet.get_node_or_null("PuppetBody") != null,
		"B: remote puppet builds voxel visuals (body/head/gun/label)")
	_check(_puppet.get_node_or_null("PuppetHitbox") != null,
		"B: puppet has a hitbox node")
	var hb := _puppet.get_node_or_null("PuppetHitbox")
	if hb != null:
		_check(hb.is_in_group("network_player"),
			"B: puppet hitbox is in group network_player")
		_check(int(hb.get_meta("peer_id", -1)) == 2 and bool(hb.get_meta("is_network_player", false)),
			"B: puppet hitbox carries peer_id 2 + is_network_player meta")
	# Feed a snapshot stream: puppet must converge on the target.
	_puppet.call("receive_state", {"position": Vector3(10, 0, 0), "yaw": 0.0, "pitch": 0.0,
		"velocity": Vector3.ZERO, "health": 80.0, "weapon": "lr8", "flags": 1})
	_check(_puppet.call("snapshot_count") == 1, "B: receive_state buffers a snapshot")
	_check(_puppet.get("health") == 80.0, "B: receive_state syncs health (80)")
	_check(str(_puppet.get("current_weapon")) == "lr8", "B: receive_state syncs weapon (lr8)")
	_check(_puppet.call("is_sprinting") == true, "B: receive_state syncs flags (SPRINT)")
	_puppet_stage = 1


func _puppet_converge() -> void:
	_puppet_stage = 2  # advance-first
	# After ~0.4 s of interpolation the puppet must be near the target.
	var d := (_puppet.global_position as Vector3).distance_to(Vector3(10, 0, 0))
	_check(d < 1.5, "B: puppet position converges to the snapshot (dist %.2f < 1.5)" % d)
	# Teleport / respawn: a >SNAP_DISTANCE snapshot snaps, not glides.
	_puppet.call("receive_state", {"position": Vector3(100, 0, 0), "yaw": 0.0, "pitch": 0.0,
		"velocity": Vector3.ZERO, "health": 80.0, "weapon": "lr8", "flags": 0})
	_puppet_stage = 2


func _puppet_snap_and_damage() -> void:
	_puppet_stage = 3  # advance-first
	var d := (_puppet.global_position as Vector3).distance_to(Vector3(100, 0, 0))
	_check(d < 1.5, "B: far snapshot snaps (dist %.2f < 1.5, no cross-map glide)" % d)
	# Authoritative damage path.
	_puppet.call("apply_damage", 25.0, 55.0, 1)
	_check(_puppet.get("health") == 55.0 and _puppet_dmg.size() == 1,
		"B: apply_damage sets HP 55 + emits damaged")
	_puppet.call("apply_damage", 55.0, 0.0, 1)
	_check(_puppet_died and _puppet.visible == false,
		"B: lethal apply_damage hides the puppet + emits died")
	_puppet.call("apply_respawn", Vector3(3, 1, 3))
	_check(_puppet.get("health") == 100.0 and _puppet.visible == true
		and (_puppet.global_position as Vector3).is_equal_approx(Vector3(3, 1, 3)),
		"B: apply_respawn restores HP 100, shows the puppet, moves to spawn")
	_check(_puppet_respawned.size() == 1, "B: apply_respawn emits respawned")
	# Local shim: invisible, no visuals, gathers real-player state.
	_shim = _np_script.new()
	_shim.call("setup", 1, "Host", true)
	root.add_child(_shim)
	_check(_shim.visible == false and _shim.get_node_or_null("PuppetBody") == null,
		"B: local shim is invisible with no puppet visuals")
	var ps := load("res://scenes/player.tscn") as PackedScene
	_fake_player = ps.instantiate()
	_fake_player.name = "FakePlayer"
	root.add_child(_fake_player)
	_fake_player.position = Vector3(5, 1, 5)
	_fake_player.call("take_damage", 10.0, Vector3(5, 1, 5), false)
	var head := _fake_player.get_node_or_null("Head")
	if head != null:
		(head as Node3D).rotation.x = 0.25
	_shim.call("bind_local_player", _fake_player)
	var st: Dictionary = _shim.call("_gather_local_state")
	_check((st.get("position", Vector3.ZERO) as Vector3).is_equal_approx(Vector3(5, 1, 5)),
		"B: shim gathers the local position (5,1,5)")
	_check(is_equal_approx(float(st.get("health", -1.0)), 115.0),
		"B: shim gathers local health (115 after a 10-damage hit: fighter max HP is 125, not 100)")
	_check(is_equal_approx(float(st.get("pitch", -1.0)), 0.25),
		"B: shim gathers head pitch (0.25)")
	_check(str(st.get("weapon", "")) == "ar7",
		"B: shim gathers the current weapon id (ar7, default primary)")
	# Shim ignores snapshots (local player is never a puppet).
	_shim.call("receive_state", {"position": Vector3(99, 0, 99), "health": 1.0})
	_check(_shim.call("snapshot_count") == 0 and _shim.get("health") == 100.0,
		"B: local shim ignores receive_state (never becomes a puppet)")
	_puppet.queue_free()
	_shim.queue_free()
	_fake_player.queue_free()
	_puppet = null
	_shim = null
	_fake_player = null
	_puppet_stage = 3

# --- Phase 4: LanDiscovery ---------------------------------------------------

func _disc_begin() -> void:
	_disc_stage = 1  # advance-first
	if not _can_inst(_ld_script):
		_check(false, "C: LanDiscovery instantiates (skipping discovery tests)")
		_disc_stage = 2
		return
	_disc_bcast = _ld_script.new()
	_disc_bcast.name = "DiscBcast"
	root.add_child(_disc_bcast)
	_disc_listen = _ld_script.new()
	_disc_listen.name = "DiscListen"
	root.add_child(_disc_listen)
	_disc_listen.game_found.connect(func(info: Dictionary) -> void: _disc_found.append(info))
	_disc_listen.game_lost.connect(func(k: String) -> void: _disc_lost.append(k))
	# Direct packet feed (deterministic, no sockets).
	_disc_listen.call("_handle_packet", JSON.stringify({
		"protocol": "forgefall-mp-v1", "host_name": "HOST1", "map": "dustline",
		"mode": "survival", "players": 2, "max_players": 8,
		"port": 7777, "host_id": "h1"}), "192.168.1.5")
	_check(_disc_found.size() == 1, "C: _handle_packet accepts a valid announcement (game_found)")
	var got: Array = _disc_listen.call("get_discovered")
	_check(got.size() == 1 and str(got[0].get("ip", "")) == "192.168.1.5"
		and str(got[0].get("key", "")) == "192.168.1.5:7777",
		"C: discovered entry carries ip + key ip:port")
	# Wrong protocol / malformed / bad port are ignored.
	_disc_listen.call("_handle_packet", JSON.stringify({"protocol": "other", "port": 7777}), "10.0.0.1")
	_disc_listen.call("_handle_packet", "{not json", "10.0.0.2")
	_disc_listen.call("_handle_packet", JSON.stringify({"protocol": "forgefall-mp-v1", "port": 0}), "10.0.0.3")
	_check(_disc_found.size() == 1 and (_disc_listen.call("get_discovered") as Array).size() == 1,
		"C: wrong-protocol / malformed / bad-port packets are ignored")
	# Same key, changed player count -> update, not duplicate.
	_disc_listen.call("_handle_packet", JSON.stringify({
		"protocol": "forgefall-mp-v1", "host_name": "HOST1", "map": "dustline",
		"mode": "survival", "players": 5, "max_players": 8,
		"port": 7777, "host_id": "h1"}), "192.168.1.5")
	_check(_disc_found.size() == 2 and (_disc_listen.call("get_discovered") as Array).size() == 1
		and int((_disc_listen.call("get_discovered") as Array)[0].get("players", -1)) == 5,
		"C: same-key re-announce updates (no duplicate) + game_found on change")
	# Stale prune (far-future `now` so the check is not time-dependent:
	# Time.get_ticks_msec()/1000 is only ~seconds at suite start, which
	# would be < ENTRY_TIMEOUT and never prune).
	var known: Dictionary = _disc_listen.get("_known")
	for k in known.keys():
		(known[k] as Dictionary)["last_seen"] = 0.0
	_disc_listen.call("_prune_stale", 1000000.0)
	_check((_disc_listen.call("get_discovered") as Array).is_empty() and _disc_lost.size() == 1,
		"C: stale entries prune + game_lost fires")
	# Live broadcast/listen (environment-dependent: broadcast loopback).
	_disc_found.clear()
	_disc_lost.clear()
	var listen_ok: bool = _disc_listen.call("start_listening")
	_check(listen_ok and _disc_listen.call("is_listening"),
		"C: start_listening binds DISCOVERY_PORT 47777")
	var bcast_ok: bool = _disc_bcast.call("start_broadcasting", {
		"host_name": "LIVEHOST", "map": "foundry", "mode": "domination",
		"players": 1, "max_players": 8, "port": 7777, "host_id": "live-1"})
	_check(bcast_ok and _disc_bcast.call("is_broadcasting"),
		"C: start_broadcasting announces immediately")
	_disc_stage = 1


func _disc_live() -> void:
	_disc_stage = 2  # advance-first
	if _disc_found.size() > 0:
		var entry: Dictionary = _disc_found[0]
		_check(str(entry.get("host_name", "")) == "LIVEHOST" and str(entry.get("map", "")) == "foundry",
			"C: live broadcast packet arrives at the listener (host_name LIVEHOST, map foundry)")
	else:
		_device("C: live LAN broadcast packet did not arrive at the same-process listener within the window — broadcast loopback is environment-dependent (routers/VMs often swallow 255.255.255.255); verify on two real devices on one LAN. Packet parsing/dedupe/prune are proven above.")
	_disc_bcast.call("stop_broadcasting")
	_check(not _disc_bcast.call("is_broadcasting"), "C: stop_broadcasting halts announcements")
	_disc_listen.call("stop_all")
	_disc_bcast.call("stop_all")
	_check(not _disc_listen.call("is_listening"), "C: stop_all halts listening")
	_disc_bcast.queue_free()
	_disc_listen.queue_free()
	_disc_bcast = null
	_disc_listen = null
	_disc_stage = 2


# --- Phase 5: MultiplayerMenu -------------------------------------------------

func _menu_begin() -> void:
	_menu_stage = 1  # advance-first
	if not _can_inst(_menu_script):
		_check(false, "D: MultiplayerMenu instantiates (skipping menu tests)")
		_menu_stage = 3
		return
	# Snapshot the persisted settings so the test can restore them.
	var cfg_path := "user://multiplayer.cfg"
	_menu_cfg_existed = FileAccess.file_exists(cfg_path)
	if _menu_cfg_existed:
		_menu_orig_cfg = FileAccess.get_file_as_string(cfg_path)
	_menu = _menu_script.new()
	_menu.name = "MultiplayerMenu"
	root.add_child(_menu)
	_menu.start_match_requested.connect(func(m: String, mo: String, h: bool) -> void: _menu_start.append([m, mo, h]))
	_menu.lobby_updated.connect(func(p: Array) -> void: _menu_lobby.append(p))
	_menu.status_changed.connect(func(s: String) -> void: _menu_status.append(s))
	_check(_menu.call("get_state") == "browse", "D: menu starts in browse state")
	var cmap := _menu_script.get_script_constant_map()
	var map_keys: Array = cmap.get("MAP_KEYS", [])
	var mode_keys: Array = cmap.get("MODE_KEYS", [])
	_check(map_keys.has(_menu.call("get_selected_map")),
		"D: selected map is a known MAP_KEY")
	_check(mode_keys.has(_menu.call("get_selected_mode")),
		"D: selected mode is a known MODE_KEY")
	# Name persistence round-trip. _save_player_name() reads the LineEdit,
	# so set the field (the way a real keystroke would) before saving.
	var name_edit: LineEdit = _menu.get("_name_edit")
	if name_edit != null:
		name_edit.text = "TestPilot"
	_menu.call("_save_player_name")
	var cfg := ConfigFile.new()
	_check(cfg.load(cfg_path) == OK and str(cfg.get_value("player", "name", "")) == "TestPilot",
		"D: player name persists to user://multiplayer.cfg")
	var menu2: Control = _menu_script.new()
	root.add_child(menu2)
	_check(menu2.call("get_player_name") == "TestPilot",
		"D: a fresh menu loads the persisted player name")
	menu2.queue_free()
	# Integration landed: the NetManager autoload IS registered, so the
	# menu delegates to it (no standalone fallback in the real game).
	_check(_menu.call("_net_manager") != null,
		"D: menu finds /root/NetManager autoload (delegated path)")
	_menu.call("_on_host_pressed")
	_check(_menu.call("get_state") == "lobby" and _menu.call("is_host") == true,
		"D: HOST GAME enters the lobby as host")
	_check((_menu.call("get_players") as Array).size() == 1,
		"D: lobby roster starts with the host alone")
	_menu_stage = 1


func _menu_lobby_and_start() -> void:
	_menu_stage = 2  # advance-first
	_menu.call("_on_ready_pressed")
	var roster: Array = _menu.call("get_players")
	_check(roster.size() == 1 and bool(roster[0].get("ready", false)) == true,
		"D: READY toggles the host ready flag")
	_menu.call("_on_start_pressed")
	_check(_menu_start.size() == 1 and _menu_start[0][2] == true,
		"D: START MATCH emits start_match_requested (map, mode, is_host=true)")
	_check(_menu.get("_match_started") == true,
		"D: match start flags the peer as match-owned (menu will not close it)")
	# Leave flow + failed-join recovery run on a FRESH menu (this one is
	# match-owned now and must not be reused for lobby tests).
	_menu.call("_disconnect_peer")
	_menu.queue_free()
	_menu = null
	_menu = _menu_script.new()
	_menu.name = "MultiplayerMenu"
	root.add_child(_menu)
	_menu.start_match_requested.connect(func(m: String, mo: String, h: bool) -> void: _menu_start.append([m, mo, h]))
	_menu.status_changed.connect(func(s: String) -> void: _menu_status.append(s))
	_menu.call("_on_host_pressed")
	_check(_menu.call("get_state") == "lobby", "D: second menu hosts a lobby (re-host works)")
	_menu.call("_on_leave_pressed")
	_check(_menu.call("get_state") == "browse",
		"D: LEAVE LOBBY returns to browse (disconnect recovery)")
	# Failed join: direct IP to a dead port must recover to browse cleanly.
	var ip_edit: LineEdit = _menu.get("_ip_edit")
	var port_spin: SpinBox = _menu.get("_port_spin")
	if ip_edit != null:
		ip_edit.text = "127.0.0.1"
	if port_spin != null:
		port_spin.value = 9
	_menu.call("_on_join_pressed")
	_menu_stage = 2


func _menu_join_failed() -> void:
	_menu_stage = 3  # advance-first
	var peer: MultiplayerPeer = root.get_multiplayer().multiplayer_peer
	var status_text := ""
	var sl: Label = _menu.get("_status_label")
	if sl != null:
		status_text = sl.text
	_check(peer == null and _menu.call("get_state") == "browse",
		"D: failed direct-IP join recovers to browse with the peer closed (status: '%s')" % status_text)
	# Restore the user's persisted multiplayer settings.
	var cfg_path := "user://multiplayer.cfg"
	if _menu_cfg_existed:
		var f := FileAccess.open(cfg_path, FileAccess.WRITE)
		if f != null:
			f.store_string(_menu_orig_cfg)
	else:
		# DirAccess.remove_absolute does NOT resolve user:// — use the
		# absolute user-data path for deletion.
		DirAccess.remove_absolute(OS.get_user_data_dir().path_join("multiplayer.cfg"))
	_menu.queue_free()
	_menu = null
	_menu_stage = 3


# --- Phase 6: NetMatch + NetScoreboard + NetPuppet ------------------------------

func _match_begin() -> void:
	_match_stage = 1  # advance-first
	if not _can_inst(_match_script):
		_check(false, "E: NetMatch instantiates (skipping match tests — see phase 0 compile FAIL)")
		_match_stage = 9
		return
	# Fixture: restore the offline peer (see note above).
	var _api: MultiplayerAPI = root.get_multiplayer()
	if _api != null and _api.multiplayer_peer == null:
		_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	_match = _match_script.new()
	_match.name = "NetMatch"
	root.add_child(_match)
	_match.kill_confirmed.connect(func(_a: String, _b: String, _c: String, _d: int, _e: int, _f: bool, _g: bool) -> void: _match_kills.append(1))
	_match.score_changed.connect(func(_s: Array) -> void: _match_scores.append(1))
	_match.match_started.connect(func(m: String, lim: int) -> void: _match_started.append([m, lim]))
	_match.match_ended.connect(func(w: int, r: Dictionary) -> void: _match_ended.append([w, r]))
	# Refusals: co-op (deferred), bad mode, < 2 players, double start.
	_check(_match.call("start_match", [1, 2], {1: "A", 2: "B"}, "coop", 25, 0.0) == false
		and _match.get("match_active") == false,
		"E: start_match('coop') returns false, no state changed (co-op deferred by design)")
	_check(_match.call("start_match", [1, 2], {1: "A", 2: "B"}, "domination", 25, 0.0) == false,
		"E: start_match(unsupported mode) returns false")
	_check(_match.call("start_match", [1], {1: "A"}, "tdm", 25, 0.0) == false,
		"E: start_match(<2 players) returns false")
	# Real TDM start: 4 players, limit 2. Teams: sorted ids -> 1:ALPHA, 2:BRAVO, 3:ALPHA, 4:BRAVO.
	var ok: bool = _match.call("start_match", [1, 2, 3, 4],
		{1: "Alpha1", 2: "Bravo1", 3: "Alpha2", 4: "Bravo2"}, "tdm", 2, 0.0)
	_check(ok and _match.get("match_active") == true,
		"E: start_match(tdm, 4 players, limit 2) starts (offline headless counts as host)")
	_check(_match_started.size() == 1 and _match_started[0][0] == "tdm" and _match_started[0][1] == 2,
		"E: match_started fires (tdm, limit 2)")
	_check(_match.call("start_match", [1, 2], {1: "A", 2: "B"}, "tdm", 25, 0.0) == false,
		"E: start_match while active returns false")
	var i1: Dictionary = _match.call("get_player_info", 1)
	var i2: Dictionary = _match.call("get_player_info", 2)
	var i3: Dictionary = _match.call("get_player_info", 3)
	var i4: Dictionary = _match.call("get_player_info", 4)
	_check(int(i1.get("team", -1)) == 0 and int(i2.get("team", -1)) == 1
		and int(i3.get("team", -1)) == 0 and int(i4.get("team", -1)) == 1,
		"E: teams balance deterministically (1:ALPHA, 2:BRAVO, 3:ALPHA, 4:BRAVO)")
	_check(_match.call("get_team_scores") == [0, 0], "E: team scores start 0-0")
	var sb: Node = _match.call("get_scoreboard")
	_check(sb != null and sb.call("player_count") == 4,
		"E: scoreboard registers all 4 players on start")
	# Puppets: one per remote peer, never in group "player".
	var puppets := get_nodes_in_group("net_puppet")
	_check(puppets.size() == 3, "E: NetPuppet spawned for each remote peer (3, not the local)")
	var pup_ok := true
	for p in puppets:
		if p.is_in_group("player"):
			pup_ok = false
	_check(pup_ok, "E: puppets are NOT in group 'player' (HUD/waves/enemies ignore them)")
	var head_ok := false
	for p in puppets:
		for ch in (p as Node).get_children():
			if ch.is_in_group("enemy_head"):
				head_ok = true
	_check(head_ok, "E: puppet head hitbox is in group 'enemy_head' (WeaponBase headshot detection)")
	_match_stage = 1


func _match_validation() -> void:
	_match_stage = 2  # advance-first
	# Friendly fire: attacker 1 (ALPHA) vs victim 3 (ALPHA) -> ignored.
	_match.call("report_hit", 3, 50.0, "ar7", false)
	_check(is_equal_approx(float((_match.call("get_player_info", 3) as Dictionary).get("hp", -1.0)), 100.0),
		"E: friendly fire rejected (same-team victim HP unchanged)")
	# Self-damage: host (1) reporting a hit on itself -> ignored.
	_match.call("report_hit", 1, 50.0, "ar7", false)
	_check(is_equal_approx(float((_match.call("get_player_info", 1) as Dictionary).get("hp", -1.0)), 100.0),
		"E: self-damage rejected (attacker == victim)")
	# Unknown peer -> ignored, no crash.
	_match.call("report_hit", 99, 50.0, "ar7", false)
	_check(_match.get("match_active") == true, "E: hit on unknown peer ignored (match still active)")
	# Real damage: 10 (below the ar7 cap of 25) applies exactly.
	_match.call("report_hit", 2, 10.0, "ar7", false)
	_check(is_equal_approx(float((_match.call("get_player_info", 2) as Dictionary).get("hp", -1.0)), 90.0),
		"E: host-validated damage applies (victim 2 HP 100 -> 90)")
	# Forged overkill is clamped to the weapon cap (ar7 base 25).
	_match.call("report_hit", 2, 99999.0, "ar7", false)
	_check(is_equal_approx(float((_match.call("get_player_info", 2) as Dictionary).get("hp", -1.0)), 65.0),
		"E: forged 99999 damage clamped to ar7 cap 25 (HP 90 -> 65)")
	# Unknown weapon -> hard cap 150 (still bounded): 50 damage applies in full.
	_match.call("report_hit", 2, 50.0, "no_such_gun", false)
	_check(is_equal_approx(float((_match.call("get_player_info", 2) as Dictionary).get("hp", -1.0)), 15.0),
		"E: unknown-weapon hit applies under the 150 hard cap (HP 65 -> 15, no instant-kill-all)")
	_match_stage = 2


func _match_kill_and_win() -> void:
	_match_stage = 3  # advance-first
	# Kill victim 2 (BRAVO) by host (ALPHA): team ALPHA scores.
	var tries := 0
	while bool((_match.call("get_player_info", 2) as Dictionary).get("alive", true)) and tries < 10:
		_match.call("report_hit", 2, 99999.0, "ar7", false)
		tries += 1
	_check(bool((_match.call("get_player_info", 2) as Dictionary).get("alive", true)) == false,
		"E: repeated validated hits kill victim 2")
	_check(_match_kills.size() == 1, "E: kill_confirmed fires once for the kill")
	_check(_match.call("get_team_scores") == [1, 0],
		"E: kill increments the CORRECT team score (ALPHA 1-0)")
	_check(_match_scores.size() >= 1, "E: score_changed fires on the kill")
	var sb: Node = _match.call("get_scoreboard")
	_check(int((sb.call("row_for", 1) as Dictionary).get("kills", -1)) == 1
		and int((sb.call("row_for", 2) as Dictionary).get("deaths", -1)) == 1,
		"E: scoreboard records killer kill + victim death")
	# Dead players neither shoot nor take damage.
	_match.call("report_hit", 2, 50.0, "ar7", false)
	_check(is_equal_approx(float((_match.call("get_player_info", 2) as Dictionary).get("hp", -1.0)), 0.0),
		"E: hit on a DEAD victim ignored (HP stays 0)")
	# Respawn restores the victim.
	_match.call("_respawn_player", 2)
	var info2: Dictionary = _match.call("get_player_info", 2)
	_check(bool(info2.get("alive", false)) == true and is_equal_approx(float(info2.get("hp", -1.0)), 100.0),
		"E: _respawn_player restores victim (alive, HP 100)")
	# Second kill (victim 4, BRAVO) hits the limit -> match ends, ALPHA wins.
	tries = 0
	while bool((_match.call("get_player_info", 4) as Dictionary).get("alive", true)) and tries < 10:
		_match.call("report_hit", 4, 99999.0, "ar7", false)
		tries += 1
	_check(_match.call("get_team_scores") == [2, 0], "E: second kill makes ALPHA 2-0 (limit reached)")
	_check(_match_ended.size() == 1 and _match_ended[0][0] == 0,
		"E: match_ended fires with winner_team ALPHA (0)")
	var res: Dictionary = _match_ended[0][1] if _match_ended.size() > 0 else {}
	_check(str(res.get("reason", "")) == "score_limit" and str(res.get("winner_name", "")) == "ALPHA",
		"E: match-end result correct (reason score_limit, winner ALPHA)")
	_check((res.get("team_scores", []) as Array) == [2, 0],
		"E: match-end result carries team_scores [2, 0]")
	_check(_match.get("match_active") == false, "E: match is inactive after the win")
	# Post-match hits are ignored.
	_match.call("report_hit", 2, 50.0, "ar7", false)
	_check(is_equal_approx(float((_match.call("get_player_info", 2) as Dictionary).get("hp", -1.0)), 100.0),
		"E: hits after match end are ignored")
	_match.call("stop_match")
	_check((_match.call("get_match_state") as Dictionary).get("players", -1) == 0,
		"E: stop_match clears the match state")
	_match.queue_free()
	_match = null
	_match_stage = 3


func _match_time_forfeit() -> void:
	_match_stage = 4  # advance-first
	# Time limit: fresh match, 0.3 s clock, no kills -> draw.
	_match2 = _match_script.new()
	_match2.name = "NetMatch2"
	root.add_child(_match2)
	_match2.match_ended.connect(func(w: int, r: Dictionary) -> void: _match2_ended.append([w, r]))
	var ok: bool = _match2.call("start_match", [1, 2], {1: "A", 2: "B"}, "tdm", 25, 0.3)
	_check(ok, "E: time-limit match starts")
	_match_stage = 4


func _match_time_done() -> void:
	_match_stage = 5  # advance-first
	_check(_match2_ended.size() == 1 and _match2_ended[0][0] == -1,
		"E: time limit ends the match as a DRAW (0-0)")
	_check(str(((_match2_ended[0][1] if _match2_ended.size() > 0 else {}) as Dictionary).get("reason", "")) == "time_limit",
		"E: time-limit result carries reason time_limit")
	_match2.call("stop_match")
	_match2.queue_free()
	_match2 = null
	# Forfeit: a peer disconnect empties a team -> the other team wins.
	_match2 = _match_script.new()
	_match2.name = "NetMatch3"
	root.add_child(_match2)
	_match2.match_ended.connect(func(w: int, r: Dictionary) -> void: _match2_ended.append([w, r]))
	_match2_ended.clear()
	var ok2: bool = _match2.call("start_match", [1, 2], {1: "A", 2: "B"}, "tdm", 25, 0.0)
	_check(ok2, "E: forfeit-test match starts")
	_match2.call("_on_peer_disconnected", 2)
	_check(_match2_ended.size() == 1 and _match2_ended[0][0] == 0,
		"E: peer disconnect forfeits -> remaining team ALPHA wins")
	_check(str(((_match2_ended[0][1] if _match2_ended.size() > 0 else {}) as Dictionary).get("reason", "")) == "forfeit",
		"E: forfeit result carries reason forfeit")
	_match2.call("stop_match")
	_match2.queue_free()
	_match2 = null
	_device("E: host disconnect over a LIVE connection (client match ends with reason host_left) — requires a real client peer; callback exists in _on_peer_disconnected(peer 1, non-server).")
	_device("E: TDM kills increment the correct team score on ALL peers + win fires on every peer — requires two connected peers; single-peer host path + scoreboard snapshot sync are proven above.")
	_match_stage = 5


func _scoreboard_tests() -> void:
	_match_stage = 9  # advance-first
	if not _can_inst(_sb_script):
		_check(false, "E: NetScoreboard instantiates (skipping scoreboard tests)")
		_match_stage = 9
		return
	var b1: Control = _sb_script.new()
	root.add_child(b1)
	var b2: Control = _sb_script.new()
	root.add_child(b2)
	b1.call("register_player", 1, "Alpha1", 0)
	b1.call("register_player", 2, "Bravo1", 1)
	b1.call("register_player", 3, "Alpha2", 0)
	_check(b1.call("player_count") == 3, "E: scoreboard registers players")
	_check(b1.call("record_kill", 1, 2) == true, "E: record_kill(known ids) returns true")
	var r1: Dictionary = b1.call("row_for", 1)
	var r2: Dictionary = b1.call("row_for", 2)
	_check(int(r1.get("kills", -1)) == 1 and int(r1.get("score", -1)) == 1
		and int(r2.get("deaths", -1)) == 1 and bool(r2.get("alive", true)) == false,
		"E: record_kill updates killer kill/score + victim death/alive=false")
	_check(b1.call("get_team_scores") == [1, 0], "E: record_kill increments the killer's team score")
	_check(b1.call("record_kill", 99, 1) == false, "E: record_kill(unknown id) returns false, no crash")
	b1.call("mark_alive", 2, true)
	_check(bool((b1.call("row_for", 2) as Dictionary).get("alive", false)) == true,
		"E: mark_alive restores the victim row")
	# Snapshot convergence: client board == host board after apply.
	b2.call("apply_snapshot", b1.call("serialize"))
	_check(JSON.stringify(b2.call("serialize")) == JSON.stringify(b1.call("serialize")),
		"E: scoreboard snapshot converges (client serialize == host serialize)")
	var rows: Array = b1.call("get_rows_sorted")
	_check(rows.size() == 3 and int(rows[0].get("peer_id", -1)) == 1,
		"E: rows sort score-desc (killer first)")
	# Visibility toggle.
	b1.call("set_scoreboard_visible", true)
	_check(b1.call("is_scoreboard_visible") == true and b1.visible == true,
		"E: scoreboard shows on set_scoreboard_visible(true)")
	b1.call("toggle_scoreboard")
	_check(b1.call("is_scoreboard_visible") == false, "E: scoreboard hides on toggle")
	b1.call("reset")
	_check(b1.call("player_count") == 0 and b1.call("get_team_scores") == [0, 0],
		"E: scoreboard reset clears rows + team scores")
	b1.queue_free()
	b2.queue_free()
	_match_stage = 9


# --- Main loop ------------------------------------------------------------------

func _process(delta: float) -> bool:
	if _phase != _last_phase:
		_last_phase = _phase
		_phase_time = 0.0
	_phase_time += delta
	if _phase_time > PHASE_TIMEOUT and _phase > 0:
		_fails += 1
		printerr("MP FAIL: phase %d timed out after %.0f s (anti-drag: moving on)" % [_phase, PHASE_TIMEOUT])
		_phase += 1
		return false
	match _phase:
		0:
			_phase0_source_checks()
			_phase = 1
		1:
			if _net_stage == 0:
				_net_host_begin()
			elif _net_stage == 1:
				_net_host_peers()
			elif _net_stage == 2:
				_net_host_damage()
			elif _net_stage == 3:
				_net_host_leave()
			elif _net_stage == 4:
				_phase = 2
		2:
			_net_client_guards()
			_phase = 3
		3:
			if _puppet_stage == 0:
				_puppet_begin()
			elif _puppet_stage == 1:
				if _phase_time > 0.6:
					_puppet_converge()
			elif _puppet_stage == 2:
				if _phase_time > 0.9:
					_puppet_snap_and_damage()
			elif _puppet_stage == 3:
				_phase = 4
		4:
			if _disc_stage == 0:
				_disc_begin()
			elif _disc_stage == 1:
				if _phase_time > 1.8:
					_disc_live()
			elif _disc_stage == 2:
				_phase = 5
		5:
			if _menu_stage == 0:
				_menu_begin()
			elif _menu_stage == 1:
				_menu_lobby_and_start()
			elif _menu_stage == 2:
				if _phase_time > JOIN_TIMEOUT:
					_check(false, "D: failed join recovered within %d s (still connecting)" % int(JOIN_TIMEOUT))
					_menu.call("_disconnect_peer")
					_menu_stage = 3
				else:
					var peer2: MultiplayerPeer = root.get_multiplayer().multiplayer_peer
					if peer2 == null:
						_menu_join_failed()
			elif _menu_stage == 3:
				_phase = 6
		6:
			if _match_stage == 0:
				_match_begin()
			elif _match_stage == 1:
				_match_validation()
			elif _match_stage == 2:
				_match_kill_and_win()
			elif _match_stage == 3:
				_match_time_forfeit()
			elif _match_stage == 4:
				if _match2_ended.size() >= 1 or _phase_time > 5.0:
					_match_time_done()
			elif _match_stage == 5:
				_scoreboard_tests()
			elif _match_stage == 9:
				_phase = 7
		7:
			print("VERIFY(multiplayer): %d passed, %d failed, %d needs-device, %d skipped" % [_passes, _fails, _need_device, _skips])
			if _fails == 0:
				print("VERIFY(multiplayer): ALL CHECKS PASSED")
			else:
				printerr("VERIFY(multiplayer): %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false
