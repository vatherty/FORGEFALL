# FORGEFALL — scripts/net/net_manager.gd (Goal 4, Worker A)
# Host-authoritative ENet multiplayer core. NO central server, NO relay:
# one player hosts (peer 1), others join directly (LAN / direct IP).
# "Matchmaking" = LAN browser + direct IP (Worker B owns lan_discovery.gd
# and the lobby UI). This file owns ALL RPCs: it is the single RPC endpoint
# because RPCs are addressed by NodePath, and an autoload has the same
# path (/root/Net) on every peer. NetworkPlayer nodes NEVER define @rpc
# functions — they call send_state() here, and this manager dispatches
# incoming state to the registered puppet.
#
# INTEGRATION (coordinator):
#   1. Register as autoload named "NetManager":
#      NetManager = *res://scripts/net/net_manager.gd
#      (Worker C's NetMatch looks up /root/NetManager for the
#      create_network_player() factory hook; NetworkPlayer also accepts
#      /root/Net. EITHER name works for RPCs — the path just has to be
#      the same on every peer, which autoloads guarantee.)
#   2. Add the node to the tree BEFORE calling create_server/create_client
#      (Node.multiplayer resolves from the node's path in the tree).
#   3. Menu / match code: Net.set_player_name(name) -> Net.create_server(port)
#      or Net.create_client(ip, port). Listen to player_joined/player_left /
#      connection_failed / server_disconnected.
#   4. Spawn: on player_joined(id), create a NetworkPlayer puppet
#      (setup(id, name, false)), register_puppet(id, puppet), add to scene.
#      On player_left(id): unregister_puppet(id) + free the puppet.
#      Local player: create a NetworkPlayer with setup(local_id, name, true),
#      bind_local_player(real_player_node) — it is a sync shim, it never
#      moves or renders anything itself.
#   5. Damage: when a local shot hits a remote player, call
#      Net.request_damage(victim_id, amount, hit_pos, headshot, weapon_id).
#      NEVER apply damage locally from a hit — the host validates and
#      broadcasts damage_applied; drive HUD / death / killfeed from that
#      signal and from get_hp(). In single-player Net.is_online() is false
#      and request_damage() is a no-op, so the SP damage path is untouched.
#   6. Respawn: dead player calls Net.request_respawn(); the host
#      broadcasts player_respawned(id, spawn_pos) — the match code moves
#      the player to spawn_pos on that signal.
#   7. Host leaves -> match ends: clients get server_disconnected and
#      must return to the lobby. NO host migration (documented, by design).
#
# ANTI-CHEAT (host-authoritative, enforced in code, verified headlessly):
#   - Damage/score/kills exist ONLY in the host's tables. Clients send
#     REQUEST RPCs; the host clamps amount (0..MAX_DAMAGE_PER_HIT),
#     rejects self-damage, unknown peers, and >MAX_DAMAGE_REQUESTS_PER_SEC
#     per peer, then broadcasts the result.
#   - Broadcast RPCs (_rpc_damage_applied, _rpc_score_update,
#     _rpc_player_respawned, _rpc_sync_players) are ACCEPTED ONLY when the
#     sender is the host (id 1). The host applies its own broadcasts via a
#     local helper (never via call_local), so a client that calls a
#     broadcast RPC directly is ignored by EVERY peer including itself —
#     a client can never fake a kill, score, damage, respawn, or list.
#   - State RPCs are accepted ONLY when sender == the peer_id in the
#     payload (a client cannot move another player's puppet) and the
#     sequence number is newer than the last accepted one.
#   - Positions are client-reported and interpolated (see network_player.gd);
#     they are cosmetic. Nothing gameplay-critical trusts a client position.
extends Node
# NOTE: no class_name here on purpose — this file is registered as the
# "NetManager" autoload in project.godot, and Godot rejects a class_name
# identical to an autoload singleton ("Class hides an autoload singleton").
# All lookups use the node path /root/NetManager.

const NetworkPlayerScript := preload("res://scripts/net/network_player.gd")

signal player_joined(peer_id: int, player_name: String)
signal player_left(peer_id: int)
signal connection_failed()
signal server_disconnected()
signal player_name_changed(peer_id: int, player_name: String)
signal damage_applied(victim_id: int, attacker_id: int, amount: float, new_hp: float, died: bool)
signal kill_confirmed(killer_id: int, victim_id: int, headshot: bool)
signal score_changed(peer_id: int, kills: int, deaths: int, score: int)
signal player_respawned(peer_id: int, spawn_pos: Vector3)

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 8
const MAX_NAME_LENGTH := 24
const MAX_HP := 100.0
const MAX_DAMAGE_PER_HIT := 200.0
const MAX_DAMAGE_REQUESTS_PER_SEC := 30
const KILL_SCORE := 100
const HEADSHOT_KILL_SCORE := 150

var is_host: bool = false
var local_id: int = 0
var local_name: String = "Player"

# players: peer_id -> {"name": String, "kills": int, "deaths": int, "score": int}
# On the host this is authoritative; on clients it is a mirror of the
# host's sync broadcasts.
var players: Dictionary = {}
# Host-authoritative HP. Clients keep a mirror (hp_mirror) updated ONLY
# from host damage/respawn broadcasts — never from client state packets.
var _auth_hp: Dictionary = {}
var hp_mirror: Dictionary = {}
# peer_id -> NetworkPlayer puppet (remote players only). Local player is
# NOT in here; it is bound via _local_player for damage-signal routing.
var _puppets: Dictionary = {}
var _local_player: Node = null
var _peer: ENetMultiplayerPeer = null
var _signals_connected: bool = false
var _state_seq: int = 0
var _last_state_seq: Dictionary = {}
var _damage_request_times: Dictionary = {}
# Optional host spawn provider: Callable() -> Vector3. If unset, the host
# picks a random node in group "player_spawn", else Vector3(0, 1, 0).
var spawn_provider: Callable = Callable()


func is_online() -> bool:
	return _peer != null and local_id != 0


func is_server() -> bool:
	return is_host


# --- lifecycle ------------------------------------------------------------

func create_server(port: int = DEFAULT_PORT, max_clients: int = MAX_PLAYERS - 1) -> Error:
	if is_online():
		leave()
	_connect_api_signals()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, maxi(max_clients, 1))
	if err != OK:
		_peer = null
		return err
	multiplayer.multiplayer_peer = _peer
	is_host = true
	local_id = 1
	players = {1: _new_player_entry(local_name)}
	_auth_hp = {1: MAX_HP}
	hp_mirror = {1: MAX_HP}
	return OK


func create_client(ip: String, port: int = DEFAULT_PORT) -> Error:
	if is_online():
		leave()
	_connect_api_signals()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(ip, port)
	if err != OK:
		_peer = null
		return err
	multiplayer.multiplayer_peer = _peer
	is_host = false
	# local_id is assigned when connected_to_server fires (unique id).
	return OK


## Disconnect cleanly. Safe to call when offline (no-op) and from
## single-player (never touches SP state). After leave(), is_online() is
## false and all tables are empty.
func leave() -> void:
	if _peer != null:
		# Detach first: prevents re-entrant server_disconnected callbacks
		# from running cleanup twice.
		_peer = null
		multiplayer.multiplayer_peer = null
	is_host = false
	local_id = 0
	players.clear()
	_auth_hp.clear()
	hp_mirror.clear()
	_puppets.clear()
	_local_player = null
	_last_state_seq.clear()
	_damage_request_times.clear()


func _connect_api_signals() -> void:
	if _signals_connected:
		return
	_signals_connected = true
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# --- player names ---------------------------------------------------------

func set_player_name(player_name: String) -> void:
	var clean := player_name.strip_edges().replace("\n", " ").replace("\r", " ")
	if clean.is_empty():
		clean = "Player"
	if clean.length() > MAX_NAME_LENGTH:
		clean = clean.substr(0, MAX_NAME_LENGTH)
	local_name = clean
	if is_host and players.has(1):
		players[1]["name"] = clean
		player_name_changed.emit(1, clean)
		_broadcast_player_sync()
	elif is_online() and not is_host:
		rpc_id(1, "_rpc_announce_name", clean)


func get_player_name(peer_id: int) -> String:
	if players.has(peer_id):
		return str(players[peer_id].get("name", "Player"))
	return "Player"


## Copy of the player table (name/kills/deaths/score). Worker C reads this
## for the scoreboard/killfeed.
func get_players() -> Dictionary:
	return players.duplicate(true)


## Authoritative HP on host, host-broadcast mirror on clients.
func get_hp(peer_id: int) -> float:
	if is_host and _auth_hp.has(peer_id):
		return float(_auth_hp[peer_id])
	if hp_mirror.has(peer_id):
		return float(hp_mirror[peer_id])
	return 0.0


func get_score_info(peer_id: int) -> Dictionary:
	if players.has(peer_id):
		return (players[peer_id] as Dictionary).duplicate()
	return _new_player_entry("Player")


# --- local player / puppet registration -----------------------------------

func register_local_player(player_node: Node) -> void:
	_local_player = player_node


func register_puppet(peer_id: int, puppet: Node) -> void:
	_puppets[peer_id] = puppet


func unregister_puppet(peer_id: int) -> void:
	_puppets.erase(peer_id)


func get_puppet(peer_id: int) -> Node:
	return _puppets.get(peer_id, null)


## Factory hook consumed by Worker C's NetMatch (duck-typed): returns a
## configured NetworkPlayer for the peer. Remote puppets are registered
## (state + damage dispatch); local shims are returned unbound — the
## caller must bind_local_player(real_player) on them. The caller adds
## the node to the tree (visuals build in _ready).
func create_network_player(peer_id: int, p_is_local: bool) -> Node:
	var np = NetworkPlayerScript.new()
	np.setup(peer_id, get_player_name(peer_id), p_is_local)
	np.set_net_manager(self)
	if not p_is_local:
		register_puppet(peer_id, np)
	return np


# --- outgoing: damage / respawn / state -----------------------------------

## Client -> host damage request. On the host this applies directly.
## No-op when offline (single-player never calls this).
func request_damage(victim_id: int, amount: float, hit_position: Vector3,
		is_headshot: bool, weapon_id: String = "") -> void:
	if not is_online():
		return
	if is_host:
		_host_apply_damage(local_id, victim_id, amount, hit_position, is_headshot, weapon_id)
	else:
		rpc_id(1, "_rpc_request_damage", victim_id, amount, hit_position, is_headshot, weapon_id)


## Dead player asks the host for a respawn. Host validates (must be dead)
## and broadcasts player_respawned with the spawn position.
func request_respawn() -> void:
	if not is_online():
		return
	if is_host:
		_host_respawn(local_id)
	else:
		rpc_id(1, "_rpc_request_respawn")


## Called by the local NetworkPlayer shim at ~20 Hz. The manager stamps
## the sender id itself (callers cannot spoof another peer).
func send_state(state: Dictionary) -> void:
	if not is_online():
		return
	_state_seq += 1
	rpc("_rpc_state",
		local_id,
		_state_seq,
		state.get("position", Vector3.ZERO),
		float(state.get("yaw", 0.0)),
		float(state.get("pitch", 0.0)),
		state.get("velocity", Vector3.ZERO),
		float(state.get("health", MAX_HP)),
		str(state.get("weapon", "")),
		int(state.get("flags", 0)))


# --- host-side authoritative resolution -----------------------------------

func _host_apply_damage(attacker_id: int, victim_id: int, amount: float,
		_hit_position: Vector3, is_headshot: bool, _weapon_id: String) -> void:
	# Preconditions already validated by _rpc_request_damage / local call.
	# The attacker == victim rejection is repeated here (defense in depth:
	# the local host path bypasses the RPC handler's check).
	if attacker_id == victim_id:
		return
	if not _auth_hp.has(victim_id):
		return
	if float(_auth_hp[victim_id]) <= 0.0:
		return  # Already dead: damage must not re-fire the kill block.
	if not is_finite(amount):
		amount = 0.0
	amount = clampf(amount, 0.0, MAX_DAMAGE_PER_HIT)
	if amount <= 0.0:
		return  # Zero damage (e.g. NaN input) emits no event.
	var new_hp := maxf(float(_auth_hp[victim_id]) - amount, 0.0)
	_auth_hp[victim_id] = new_hp
	var died := new_hp <= 0.0
	# Broadcast to remotes, then apply locally through the same helper
	# the remote handler runs — single code path, no double-apply (the
	# helper only mirrors + emits, it never subtracts again). Broadcast
	# RPCs are call_remote and accept sender == 1 only, so the host must
	# apply its own broadcast explicitly here.
	rpc("_rpc_damage_applied", victim_id, attacker_id, amount, new_hp, died, is_headshot)
	_apply_damage_mirror(victim_id, attacker_id, amount, new_hp, died, is_headshot)
	if died:
		players[victim_id]["deaths"] = int(players[victim_id].get("deaths", 0)) + 1
		players[attacker_id]["kills"] = int(players[attacker_id].get("kills", 0)) + 1
		var gained := HEADSHOT_KILL_SCORE if is_headshot else KILL_SCORE
		players[attacker_id]["score"] = int(players[attacker_id].get("score", 0)) + gained
		rpc("_rpc_score_update", attacker_id,
			int(players[attacker_id]["kills"]),
			int(players[attacker_id].get("deaths", 0)),
			int(players[attacker_id]["score"]))
		_apply_score_mirror(attacker_id,
			int(players[attacker_id]["kills"]),
			int(players[attacker_id].get("deaths", 0)),
			int(players[attacker_id]["score"]))
		rpc("_rpc_score_update", victim_id,
			int(players[victim_id].get("kills", 0)),
			int(players[victim_id]["deaths"]),
			int(players[victim_id].get("score", 0)))
		_apply_score_mirror(victim_id,
			int(players[victim_id].get("kills", 0)),
			int(players[victim_id]["deaths"]),
			int(players[victim_id].get("score", 0)))


func _host_respawn(peer_id: int) -> void:
	if not _auth_hp.has(peer_id):
		return
	if float(_auth_hp[peer_id]) > 0.0:
		return  # Only dead players respawn.
	_auth_hp[peer_id] = MAX_HP
	var spawn_pos := Vector3(0, 1.0, 0)
	if spawn_provider.is_valid():
		spawn_pos = spawn_provider.call()
	else:
		var spawns := get_tree().get_nodes_in_group("player_spawn")
		if not spawns.is_empty():
			var m := spawns[randi() % spawns.size()] as Node3D
			if m != null:
				spawn_pos = m.global_position
	rpc("_rpc_player_respawned", peer_id, spawn_pos)
	_apply_respawn_mirror(peer_id, spawn_pos)


func _new_player_entry(player_name: String) -> Dictionary:
	return {"name": player_name, "kills": 0, "deaths": 0, "score": 0}


func _broadcast_player_sync() -> void:
	if not is_host:
		return
	rpc("_rpc_sync_players", players.duplicate(true))


# --- connection callbacks -------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if not is_host:
		return
	if players.has(peer_id):
		return
	players[peer_id] = _new_player_entry("Player %d" % peer_id)
	_auth_hp[peer_id] = MAX_HP
	hp_mirror[peer_id] = MAX_HP
	player_joined.emit(peer_id, str(players[peer_id]["name"]))
	_broadcast_player_sync()


func _on_peer_disconnected(peer_id: int) -> void:
	if is_host:
		players.erase(peer_id)
		_auth_hp.erase(peer_id)
		hp_mirror.erase(peer_id)
		_puppets.erase(peer_id)
		_last_state_seq.erase(peer_id)
		_damage_request_times.erase(peer_id)
		player_left.emit(peer_id)
		_broadcast_player_sync()
	else:
		# A client sees other peers vanish; the host re-syncs the list,
		# and _rpc_sync_players emits player_left for the missing ids.
		players.erase(peer_id)
		hp_mirror.erase(peer_id)
		_puppets.erase(peer_id)
		player_left.emit(peer_id)


func _on_connected_to_server() -> void:
	local_id = multiplayer.get_unique_id()
	if not players.has(local_id):
		players[local_id] = _new_player_entry(local_name)
	hp_mirror[local_id] = MAX_HP
	rpc_id(1, "_rpc_announce_name", local_name)


func _on_connection_failed() -> void:
	leave()
	connection_failed.emit()


func _on_server_disconnected() -> void:
	# Host left -> match ends, back to lobby. NO host migration.
	var was_online := is_online()
	leave()
	if was_online:
		server_disconnected.emit()


# --- broadcast mirrors --------------------------------------------------
# Helpers shared by the host (local apply) and the RPC handlers (sender
# == 1 only). Single code path for every peer.

func _apply_damage_mirror(victim_id: int, attacker_id: int, amount: float,
		new_hp: float, died: bool, is_headshot: bool) -> void:
	hp_mirror[victim_id] = new_hp
	damage_applied.emit(victim_id, attacker_id, amount, new_hp, died)
	if died:
		kill_confirmed.emit(attacker_id, victim_id, is_headshot)
	var puppet = _puppets.get(victim_id, null)
	if puppet != null and puppet.has_method("apply_damage"):
		puppet.apply_damage(amount, new_hp, attacker_id)


func _apply_score_mirror(peer_id: int, kills: int, deaths: int, score: int) -> void:
	if not players.has(peer_id):
		players[peer_id] = _new_player_entry("Player")
	players[peer_id]["kills"] = kills
	players[peer_id]["deaths"] = deaths
	players[peer_id]["score"] = score
	score_changed.emit(peer_id, kills, deaths, score)


func _apply_respawn_mirror(peer_id: int, spawn_pos: Vector3) -> void:
	hp_mirror[peer_id] = MAX_HP
	if is_host:
		_auth_hp[peer_id] = MAX_HP
	player_respawned.emit(peer_id, spawn_pos)
	var puppet = _puppets.get(peer_id, null)
	if puppet != null and puppet.has_method("apply_respawn"):
		puppet.apply_respawn(spawn_pos)

# --- RPCs -----------------------------------------------------------------
# Sender rules (see header): broadcasts accept host (1) only; requests
# accept any connected peer; state requires sender == peer_id.

@rpc("any_peer", "call_remote", "reliable")
func _rpc_announce_name(player_name: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0 or not players.has(sender):
		return
	var clean := player_name.strip_edges().replace("\n", " ").replace("\r", " ")
	if clean.is_empty():
		clean = "Player"
	if clean.length() > MAX_NAME_LENGTH:
		clean = clean.substr(0, MAX_NAME_LENGTH)
	players[sender]["name"] = clean
	player_name_changed.emit(sender, clean)
	_broadcast_player_sync()


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_damage(victim_id: int, amount: float, hit_position: Vector3,
		is_headshot: bool, weapon_id: String) -> void:
	if not is_host:
		return  # Only the host resolves damage. Clients ignore this.
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		return
	if not players.has(sender) or not players.has(victim_id):
		return
	if sender == victim_id:
		return  # No self-damage through the network path.
	if not is_finite(amount) or amount < 0.0:
		return
	# Rate limit: bursts of damage requests are dropped, not queued.
	var now := Time.get_ticks_msec() / 1000.0
	var times: Array = _damage_request_times.get(sender, [])
	var kept: Array = []
	for t in times:
		if now - float(t) < 1.0:
			kept.append(t)
	if kept.size() >= MAX_DAMAGE_REQUESTS_PER_SEC:
		return
	kept.append(now)
	_damage_request_times[sender] = kept
	var hit := hit_position if hit_position.is_finite() else Vector3.ZERO
	_host_apply_damage(sender, victim_id, amount, hit, is_headshot, weapon_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_respawn() -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0 or not players.has(sender):
		return
	_host_respawn(sender)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_damage_applied(victim_id: int, attacker_id: int, amount: float,
		new_hp: float, died: bool, is_headshot: bool) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return  # Only the host may broadcast damage. Client fakes ignored.
	_apply_damage_mirror(victim_id, attacker_id, amount, new_hp, died, is_headshot)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_score_update(peer_id: int, kills: int, deaths: int, score: int) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return  # Only the host may broadcast scores.
	_apply_score_mirror(peer_id, kills, deaths, score)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_player_respawned(peer_id: int, spawn_pos: Vector3) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return  # Only the host may broadcast respawns.
	_apply_respawn_mirror(peer_id, spawn_pos)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_sync_players(snapshot: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return  # Only the host may broadcast the player list.
	if is_host:
		return  # Host owns the table; its local call is a no-op.
	for peer_id in snapshot.keys():
		var entry: Dictionary = snapshot[peer_id]
		if not players.has(peer_id):
			players[peer_id] = (entry as Dictionary).duplicate()
			if not hp_mirror.has(peer_id):
				hp_mirror[peer_id] = MAX_HP
			player_joined.emit(int(peer_id), str(entry.get("name", "Player")))
		else:
			players[peer_id]["name"] = entry.get("name", players[peer_id].get("name", "Player"))
			players[peer_id]["kills"] = entry.get("kills", players[peer_id].get("kills", 0))
			players[peer_id]["deaths"] = entry.get("deaths", players[peer_id].get("deaths", 0))
			players[peer_id]["score"] = entry.get("score", players[peer_id].get("score", 0))
	for peer_id in players.keys():
		if not snapshot.has(peer_id) and int(peer_id) != local_id:
			players.erase(peer_id)
			hp_mirror.erase(peer_id)
			_puppets.erase(peer_id)
			player_left.emit(int(peer_id))


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_state(peer_id: int, seq: int, pos: Vector3, yaw: float, pitch: float,
		vel: Vector3, hp: float, weapon: String, flags: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != peer_id:
		return  # A peer may only send state for itself.
	if not players.has(peer_id):
		return
	var last: int = int(_last_state_seq.get(peer_id, -1))
	if seq <= last:
		return  # Stale / reordered snapshot.
	_last_state_seq[peer_id] = seq
	var puppet = _puppets.get(peer_id, null)
	if puppet != null and puppet.has_method("receive_state"):
		puppet.receive_state({
			"position": pos, "yaw": yaw, "pitch": pitch,
			"velocity": vel, "health": hp, "weapon": weapon, "flags": flags,
		})
