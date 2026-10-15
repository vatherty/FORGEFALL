# scripts/net/lan_discovery.gd
# FORGEFALL — Goal 4 Multiplayer (Worker B: lobby + menu).
# LAN discovery via UDP broadcast. No central server, no relay, no
# platform-specific APIs: pure PacketPeerUDP, works on Android/Linux/Windows.
#
# Protocol: the host broadcasts one small JSON packet per second to
# 255.255.255.255:DISCOVERY_PORT:
#   {"protocol":"forgefall-mp-v1","host_name":..,"map":..,"mode":..,
#    "players":int,"max_players":int,"port":int,"host_id":str}
# Clients bind DISCOVERY_PORT, parse packets, dedupe by sender ip:game-port,
# and emit game_found(info) for new/changed games. Entries unseen for
# ENTRY_TIMEOUT seconds are pruned and emit game_lost(host_key).
#
# Failure modes are all graceful: if the bind fails (no network, no
# permission, port already in use) listening just stays off and
# is_listening() returns false — the menu's direct-IP join still works.
# Broadcast MUST stop when the match starts and when leaving the menu;
# the menu calls stop_all() on both paths (and _exit_tree).
class_name LanDiscovery
extends Node

## Emitted when a new game appears on the LAN, or a known game's info
## changes (player count, map, ...). `info` keys: host_name, map, mode,
## players, max_players, port, host_id, ip, key.
signal game_found(info: Dictionary)
## Emitted when a previously announced game stops broadcasting.
## `host_key` is the same "ip:port" string carried in info["key"].
signal game_lost(host_key: String)

## Fixed UDP port for discovery traffic. Deliberately NOT the game port
## (7777): discovery and gameplay must never fight over one socket.
const DISCOVERY_PORT := 47777
## How often the host re-announces itself.
const BROADCAST_INTERVAL := 1.0
## A game unseen for this long is considered gone.
const ENTRY_TIMEOUT := 3.5
## Protocol tag — packets without it are ignored (other apps / old builds).
const PROTOCOL := "forgefall-mp-v1"

var _udp: PacketPeerUDP
var _broadcasting := false
var _listening := false
var _broadcast_info := {}
var _broadcast_timer := 0.0
## key ("ip:port") -> {"info": Dictionary, "last_seen": float (seconds, Time.get_ticks_msec()/1000)}
var _known: Dictionary = {}
var _warned_broadcast := false


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _broadcasting and _udp != null:
		_broadcast_timer += _delta
		if _broadcast_timer >= BROADCAST_INTERVAL:
			_broadcast_timer = 0.0
			_send_broadcast()
	if _listening and _udp != null:
		while _udp.get_available_packet_count() > 0:
			var packet := _udp.get_packet()
			var sender_ip := _udp.get_packet_ip()
			_handle_packet(packet.get_string_from_utf8(), sender_ip)
		_prune_stale(now)


## Start announcing this host's game. `info` keys: host_name, map, mode,
## players, max_players, port, host_id. Returns false if the broadcast
## socket could not be set up (caller should still allow hosting — the
## game itself works without discovery; it just won't appear in browsers).
func start_broadcasting(info: Dictionary) -> bool:
	_broadcast_info = info.duplicate()
	_broadcast_timer = BROADCAST_INTERVAL  # announce immediately
	_warned_broadcast = false
	if _listening:
		stop_listening()  # one socket: close the listener before reusing it
	if _udp == null:
		_udp = PacketPeerUDP.new()
	if not _broadcasting:
		# The broadcast peer is NOT bound: it only sends. (A bound peer
		# here would fight the listener for DISCOVERY_PORT in tests that
		# run a broadcaster and a listener in one process.)
		_udp.set_broadcast_enabled(true)
		_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_broadcasting = true
	_send_broadcast()
	return true


## Change the announced info (player count, map, ...) without restarting.
func update_broadcast_info(info: Dictionary) -> void:
	_broadcast_info = info.duplicate()


func stop_broadcasting() -> void:
	_broadcasting = false
	_maybe_close()


## Start listening for host announcements. Returns false if the bind
## failed (no network / no permission / port busy) — NOT an error for the
## caller: discovery is best-effort, direct IP still works.
func start_listening() -> bool:
	if _listening:
		return true
	if _broadcasting:
		stop_broadcasting()  # one socket: close the broadcaster before binding
	if _udp == null:
		_udp = PacketPeerUDP.new()
	var err := _udp.bind(DISCOVERY_PORT, "*")
	if err != OK:
		push_warning("LanDiscovery: could not bind UDP %d (err %d) — LAN browser disabled, direct IP still works." % [DISCOVERY_PORT, err])
		_listening = false
		_maybe_close()
		return false
	_listening = true
	return true


func stop_listening() -> void:
	_listening = false
	_known.clear()
	_maybe_close()


## Stop everything (broadcast + listen). Call on match start / menu exit.
func stop_all() -> void:
	_broadcasting = false
	_listening = false
	_known.clear()
	_maybe_close()


func is_broadcasting() -> bool:
	return _broadcasting


func is_listening() -> bool:
	return _listening


## Snapshot of currently known games (deduped). Each entry is an info dict.
func get_discovered() -> Array:
	var out: Array = []
	for key in _known:
		out.append((_known[key] as Dictionary).get("info", {}))
	return out


## Parse one received packet. Split out of the poll loop so tests can feed
## packets directly (loopback broadcast is environment-dependent).
func _handle_packet(text: String, sender_ip: String) -> void:
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return
	if str(data.get("protocol", "")) != PROTOCOL:
		return
	var game_port := int(data.get("port", 0))
	if game_port <= 0:
		return
	# Never list our own broadcast back to ourselves (same-process
	# broadcaster+listener, or broadcast loopback on some routers).
	if _broadcasting and str(data.get("host_id", "")) != "" and str(data.get("host_id", "")) == str(_broadcast_info.get("host_id", "")):
		return
	var key := "%s:%d" % [sender_ip, game_port]
	var info := {
		"host_name": str(data.get("host_name", "HOST")),
		"map": str(data.get("map", "dustline")),
		"mode": str(data.get("mode", "survival")),
		"players": int(data.get("players", 1)),
		"max_players": int(data.get("max_players", 8)),
		"port": game_port,
		"host_id": str(data.get("host_id", "")),
		"ip": sender_ip,
		"key": key,
	}
	var is_new := not _known.has(key)
	var changed := false
	if not is_new:
		var old: Dictionary = (_known[key] as Dictionary).get("info", {})
		changed = old.get("players") != info["players"] or old.get("map") != info["map"] or old.get("mode") != info["mode"] or old.get("host_name") != info["host_name"]
	_known[key] = {"info": info, "last_seen": Time.get_ticks_msec() / 1000.0}
	if is_new or changed:
		game_found.emit(info)


func _prune_stale(now: float) -> void:
	var dead: Array = []
	for key in _known:
		var last_seen := float((_known[key] as Dictionary).get("last_seen", 0.0))
		if now - last_seen > ENTRY_TIMEOUT:
			dead.append(key)
	for key in dead:
		_known.erase(key)
		game_lost.emit(str(key))


func _send_broadcast() -> void:
	if _udp == null:
		return
	var payload := _broadcast_info.duplicate()
	payload["protocol"] = PROTOCOL
	var data := JSON.stringify(payload).to_utf8_buffer()
	var err := _udp.put_packet(data)
	if err != OK and not _warned_broadcast:
		_warned_broadcast = true
		push_warning("LanDiscovery: broadcast send failed (err %d) — game will not appear in LAN browsers." % err)
	# Loopback copy: lets two game instances on ONE machine discover each
	# other (local testing, split-screen dev) and keeps the packet on the
	# LAN broadcast as the primary path. Self-packets are filtered by the
	# host_id check in _handle_packet, so a host never lists itself.
	_udp.set_dest_address("127.0.0.1", DISCOVERY_PORT)
	_udp.put_packet(data)
	_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)


func _maybe_close() -> void:
	if _broadcasting or _listening:
		return
	if _udp != null:
		_udp.close()
		_udp = null


func _exit_tree() -> void:
	stop_all()
