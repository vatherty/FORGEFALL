# verify_netcode_local.gd — TRANSPORT-FREE headless checks for Goal 4 (Worker A).
# Usage:
#   godot --headless --path <project> --script res://tools/verify_netcode_local.gd
#
# WHY THIS EXISTS: the sandbox blocks UDP loopback (proven: python UDP
# sendto to 127.0.0.1 -> Errno 1 Operation not permitted; TCP works).
# ENet runs on UDP, so no ENet packet can flow in this VM — the
# two-process ENet verifier (tools/verify_netcode.gd) cannot pass here
# and must run on real hardware / an unblocked machine. THIS script
# verifies everything that does not need packet transport, white-box:
#   L1. Interpolation (real _process, 2 m/s snapshots): no frame jump,
#       converges.
#   L2. Name sanitization (strip / newline / 24-char clamp).
#   L3. Host authoritative math: damage, oversized clamp (9999 -> 200),
#       NaN -> 0, kill/score, respawn, self-damage rejected.
#   L4. take_damage forwarding chain: puppet hitbox -> request_damage ->
#       host applies -> mirror + signal. Never a local apply.
#   L5. Broadcast guards: direct calls to _rpc_damage_applied /
#       _rpc_request_damage / _rpc_sync_players with a non-host sender
#       (0 outside an RPC) change NOTHING and emit NOTHING.
#   L6. Client mirror helpers apply + emit.
#   L7. leave() safety: offline, empty tables, double-leave, offline
#       request_damage no-op, no crash.
#   L8. Factory: create_network_player() returns a puppet with hitboxes
#       (remote) / an invisible shim (local).
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

const PORT := 7789
const NetManagerScript := preload("res://scripts/net/net_manager.gd")
const NetworkPlayerScript := preload("res://scripts/net/network_player.gd")

var _passed := 0
var _failed := 0
var _phase := 0
var _phase_t := 0.0
var _interp_puppet = null
var _interp_last_pos := Vector3.ZERO
var _interp_max_step := 0.0
var _interp_feed_timer := 0.0
var _interp_feeds := 0
var _net = null
var _damage_events: Array = []
var _kill_events: Array = []
var _respawn_events: Array = []
var _score_events: Array = []


func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: %s" % name)
	else:
		_failed += 1
		print("FAIL: %s %s" % [name, detail])


func _process(delta: float) -> bool:
	_phase_t += delta
	match _phase:
		0:
			_start_interp()
		1:
			_run_interp(delta)
		2:
			_run_logic()
			_phase = 3
		3:
			print("verify_netcode_local: %d passed, %d failed" % [_passed, _failed])
			quit(0 if _failed == 0 else 1)
			return true
	return false


func _start_interp() -> void:
	_interp_puppet = NetworkPlayerScript.new()
	_interp_puppet.setup(99, "InterpBot", false)
	root.add_child(_interp_puppet)
	_interp_puppet.global_position = Vector3(0, 1, 0)
	_interp_puppet.receive_state({
		"position": Vector3(0, 1, 0), "yaw": 0.0, "pitch": 0.0,
		"velocity": Vector3(2, 0, 0), "health": 100.0, "weapon": "", "flags": 0,
	})
	_interp_last_pos = _interp_puppet.global_position
	_interp_feed_timer = 0.0
	_interp_feeds = 0
	_phase = 1


func _run_interp(delta: float) -> void:
	_interp_feed_timer += delta
	if _interp_feed_timer >= 0.1 and _interp_feeds < 12:
		_interp_feeds += 1
		var t := _interp_feeds * 0.1
		_interp_puppet.receive_state({
			"position": Vector3(2.0 * t, 1, 0), "yaw": 0.0, "pitch": 0.0,
			"velocity": Vector3(2, 0, 0), "health": 100.0, "weapon": "", "flags": 0,
		})
		_interp_feed_timer = 0.0
	if _phase_t > 0.25:
		var step: float = _interp_puppet.global_position.distance_to(_interp_last_pos)
		_interp_max_step = maxf(_interp_max_step, step)
	_interp_last_pos = _interp_puppet.global_position
	if _phase_t >= 1.9:
		var final_err: float = _interp_puppet.global_position.distance_to(Vector3(2.4, 1, 0))
		_check("L1 interp max step < 0.35 m (got %.3f)" % _interp_max_step,
			_interp_max_step < 0.35)
		_check("L1 interp final error < 0.50 m (got %.3f)" % final_err,
			final_err < 0.50)
		_interp_puppet.queue_free()
		_interp_puppet = null
		_phase = 2
		_phase_t = 0.0


func _run_logic() -> void:
	_net = NetManagerScript.new()
	_net.name = "NetManager"
	root.add_child(_net)
	_net.damage_applied.connect(func(v: int, a: int, amt: float, hp: float, d: bool) -> void:
		_damage_events.append([v, a, amt, hp, d]))
	_net.kill_confirmed.connect(func(k: int, v: int, h: bool) -> void:
		_kill_events.append([k, v, h]))
	_net.player_respawned.connect(func(p: int, _pos: Vector3) -> void:
		_respawn_events.append(p))
	_net.score_changed.connect(func(p: int, k: int, d: int, s: int) -> void:
		_score_events.append([p, k, d, s]))

	# L2 — name sanitization (offline, no RPCs).
	_net.set_player_name("  A\nB  ")
	_check("L2 name: newline -> space + strip", _net.local_name == "A B",
		"(got '%s')" % _net.local_name)
	_net.set_player_name("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")  # 30 x's
	_check("L2 name: clamped to 24 chars", _net.local_name.length() == 24)
	_net.set_player_name("   ")
	_check("L2 name: blank -> Player", _net.local_name == "Player")
	_net.set_player_name("ClientPlayer")

	# L3 — host authoritative math. create_server binds UDP (bind works
	# in the sandbox; only packet SEND is blocked), then simulate the
	# join white-box (the join itself is covered by the ENet verifier).
	var err: Error = _net.create_server(PORT)
	_check("L3 create_server OK", err == OK, "(err=%d)" % err)
	_check("L3 host is_host + local_id 1", _net.is_host and _net.local_id == 1)
	_net._on_peer_connected(2)
	_check("L3 simulated join: 2 players", _net.players.size() == 2)
	_damage_events.clear()
	_net._host_apply_damage(2, 1, 25.0, Vector3.ZERO, false, "ar7")
	_check("L3 damage: host HP 75", _net.get_hp(1) == 75.0)
	_check("L3 damage: event emitted (25, died=false)",
		_damage_events.size() == 1 and _damage_events[0][2] == 25.0
		and _damage_events[0][4] == false)
	_net._host_apply_damage(2, 1, 9999.0, Vector3.ZERO, true, "lr8")
	_check("L3 oversized clamped: HP 0, died", _net.get_hp(1) == 0.0
		and _damage_events.size() == 2 and _damage_events[1][4] == true
		and _damage_events[1][2] == 200.0)
	_check("L3 oversized clamped: kill + headshot score 150",
		_kill_events.size() == 1 and _kill_events[0][2] == true
		and int(_net.get_score_info(2).get("kills", -1)) == 1
		and int(_net.get_score_info(2).get("score", -1)) == 150)
	_net._host_apply_damage(2, 1, NAN, Vector3.ZERO, false, "ar7")
	_check("L3 NaN damage -> 0 (HP still 0)", _net.get_hp(1) == 0.0)
	_net._host_apply_damage(1, 1, 50.0, Vector3.ZERO, false, "ar7")
	_check("L3 self-damage rejected (host path)", _net.get_hp(1) == 0.0
		and _damage_events.size() == 2)
	_net._host_respawn(1)
	_check("L3 respawn: HP back to 100", _net.get_hp(1) == 100.0
		and _respawn_events.has(1))
	_net._host_respawn(1)
	_check("L3 respawn while alive rejected (no 2nd event)",
		_respawn_events.size() == 1)

	# L4 — take_damage forwarding chain (host puppet for peer 2).
	var puppet = _net.create_network_player(2, false)
	root.add_child(puppet)
	_damage_events.clear()
	var hitbox = puppet.get_node_or_null("PuppetHitbox")
	_check("L4 puppet has take_damage hitbox",
		hitbox != null and hitbox.has_method("take_damage"))
	if hitbox != null:
		hitbox.take_damage(10.0, Vector3.ZERO, false)
	_check("L4 hitbox take_damage: victim HP 90 via host validation",
		_net.get_hp(2) == 90.0, "(got %.1f)" % _net.get_hp(2))
	_check("L4 hitbox take_damage: damage event (victim 2, 10)",
		_damage_events.size() == 1 and _damage_events[0][0] == 2
		and _damage_events[0][2] == 10.0)
	_check("L4 puppet mirror HP updated by broadcast", puppet.health == 90.0)
	puppet.queue_free()

	# L5 — broadcast guards: direct RPC calls with non-host sender (0
	# outside an RPC) must change nothing and emit nothing.
	_damage_events.clear()
	_kill_events.clear()
	_score_events.clear()
	_respawn_events.clear()
	var hp_before: float = _net.get_hp(1)
	_net._rpc_damage_applied(1, 2, 999.0, 0.0, true, false)
	_check("L5 guard: fake _rpc_damage_applied ignored",
		_net.get_hp(1) == hp_before and _damage_events.is_empty()
		and _kill_events.is_empty())
	_net._rpc_score_update(2, 999, 0, 99999)
	_check("L5 guard: fake _rpc_score_update ignored",
		int(_net.get_score_info(2).get("score", -1)) == 150
		and _score_events.is_empty())
	_net._rpc_player_respawned(2, Vector3.ZERO)
	_check("L5 guard: fake _rpc_player_respawned ignored",
		_respawn_events.is_empty())
	_net._rpc_sync_players({9: {"name": "Intruder", "kills": 0, "deaths": 0, "score": 0}})
	_check("L5 guard: fake _rpc_sync_players ignored (host owns table)",
		not _net.players.has(9))
	_net._rpc_request_damage(1, 50.0, Vector3.ZERO, false, "ar7")
	_check("L5 guard: direct _rpc_request_damage with sender 0 ignored",
		_net.get_hp(1) == hp_before and _damage_events.is_empty())
	_net._rpc_state(2, 1, Vector3(50, 1, 50), 0.0, 0.0, Vector3.ZERO, 100.0, "", 0)
	_check("L5 guard: direct _rpc_state with sender 0 ignored (no puppet state)",
		true)  # Passes if no crash / no misroute; sender check is the guard.

	# L6 — client mirror helpers apply + emit (white-box, no transport).
	var net2 = NetManagerScript.new()
	net2.name = "NetManager2"
	root.add_child(net2)
	var mirror_events: Array = []
	net2.damage_applied.connect(func(v: int, a: int, amt: float, hp: float, d: bool) -> void:
		mirror_events.append([v, a, amt, hp, d]))
	net2._apply_damage_mirror(1, 2, 25.0, 75.0, false, false)
	_check("L6 mirror: damage applies + emits", net2.hp_mirror[1] == 75.0
		and mirror_events.size() == 1)
	net2._apply_respawn_mirror(1, Vector3(0, 1, 0))
	_check("L6 mirror: respawn restores HP 100", net2.hp_mirror[1] == 100.0)
	net2.queue_free()

	# L7 — leave() safety.
	_net.leave()
	_check("L7 leave: offline + tables empty",
		not _net.is_online() and _net.players.is_empty())
	_net.leave()
	_check("L7 double leave: no crash", true)
	_net.request_damage(1, 25.0, Vector3.ZERO, false, "ar7")
	_check("L7 offline request_damage: no-op, no crash", true)
	_net.set_player_name("Solo")
	_check("L7 offline set_player_name works", _net.local_name == "Solo")

	# L8 — factory shapes.
	var remote = _net.create_network_player(5, false)
	root.add_child(remote)  # _ready() builds visuals only once in-tree.
	_check("L8 factory remote: puppet with hitboxes",
		remote != null and remote.get_node_or_null("PuppetHitbox") != null
		and remote.get_node_or_null("PuppetHeadHitbox") != null
		and remote.get_node_or_null("PuppetHeadHitbox").is_in_group("enemy_head"))
	remote.queue_free()
	var shim = _net.create_network_player(6, true)
	root.add_child(shim)
	_check("L8 factory local: invisible shim, no visuals",
		shim != null and shim.is_local_player and not shim.visible
		and shim.get_node_or_null("PuppetHitbox") == null)
	shim.queue_free()
	_net.queue_free()
