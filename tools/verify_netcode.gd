# verify_netcode.gd — headless verification for FORGEFALL Goal 4 (Worker A).
# Usage:
#   godot --headless --path <project> --script res://tools/verify_netcode.gd -- --net-mode=host
#   godot --headless --path <project> --script res://tools/verify_netcode.gd -- --net-mode=client
# Or run both via tools/verify_netcode.sh (host in background + client).
#
# Two REAL processes (host + client) with separate ENet peers over
# loopback on port 7779 — this exercises the true RPC path (handshake,
# validation, broadcast, state sync), not a stubbed call graph.
# (Two MultiplayerAPI branches in ONE process were tried first: the
# tree never services branch peers — handshake fails with
# "Sending failed!" — so single-process dual-peer is not a viable
# harness in Godot 4.7.2.)
#
# Checks (host process):
#   I1. Interpolation: puppet fed 2 m/s snapshots never jumps > 0.35 m in
#       one frame (after startup) and converges to < 0.50 m of the final
#       snapshot.
#   N1. Handshake: host sees client join; client list syncs.
#   N2. Anti-cheat: client directly rpc()s _rpc_damage_applied (999 dmg)
#       and _rpc_score_update (99999 score) — host HP stays 100 and host
#       score for the client stays 0, and the faking client itself sees
#       no effect either.
#   N3. Legit damage: client request_damage(host, 25) -> host HP 75.
#   N4. Oversized damage clamped: request_damage(host, 9999, headshot)
#       -> host HP 0, died, killer kills == 1, score == 150 (headshot).
#   N5. Respawn: request_respawn -> host HP back to 100.
#   N8. Factory + hitbox: client calls create_network_player(1, false)
#       and hitbox.take_damage(10) (the real WeaponBase path) ->
#       host HP 90 via a validated request, never a local apply.
#   N6. State convergence: client's fake body moves 0 -> 10 m on X over
#       1 s; host puppet ends within 0.60 m of (10, 1, 0).
#   N7. Disconnect: client leave() -> host emits player_left, puppet
#       removed; host leave() -> offline, tables empty (SP-safe).
# The client process mirrors the same checks against its own mirror
# tables (N2/N3/N4/N5/N8) and exits non-zero on any failure.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

const PORT := 7779
const NetManagerScript := preload("res://scripts/net/net_manager.gd")
const NetworkPlayerScript := preload("res://scripts/net/network_player.gd")

var _mode := "host"
var _passed := 0
var _failed := 0
var _phase := 0
var _phase_t := 0.0
var _done := false

# Shared handles.
var _net = null
var _puppet = null
var _shim = null
var _fake_body: CharacterBody3D = null
var _client_id := 0

# Interp test state.
var _interp_puppet = null
var _interp_last_pos := Vector3.ZERO
var _interp_max_step := 0.0
var _interp_feed_timer := 0.0
var _interp_feeds := 0

# Event logs.
var _damage_events: Array = []
var _kill_events: Array = []
var _respawn_events: Array = []
var _left_events: Array = []
var _joined_events: Array = []
var _factory_puppet = null
var _factory_fired := false
var _state_t := 0.0


func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: %s" % name)
	else:
		_failed += 1
		print("FAIL: %s %s" % [name, detail])


func _advance(phase: int) -> void:
	_phase = phase
	_phase_t = 0.0


func _initialize() -> void:
	# User args come AFTER `--` on the command line and live in
	# get_cmdline_user_args() (get_cmdline_args() only has engine args).
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--net-mode="):
			_mode = arg.substr("--net-mode=".length())


func _process(delta: float) -> bool:
	if _done:
		return true  # MainLoop: true = quit.
	_phase_t += delta
	if _mode == "client":
		_client_tick(delta)
	else:
		_host_tick(delta)
	return false  # MainLoop: false = keep running.


# --- shared callbacks ------------------------------------------------------

func _on_damage(victim: int, attacker: int, amount: float, new_hp: float, died: bool) -> void:
	_damage_events.append([victim, attacker, amount, new_hp, died])


func _on_kill(killer: int, victim: int, headshot: bool) -> void:
	_kill_events.append([killer, victim, headshot])


func _on_respawn(peer_id: int, _pos: Vector3) -> void:
	_respawn_events.append(peer_id)


func _on_joined(peer_id: int, _player_name: String) -> void:
	_joined_events.append(peer_id)


func _on_left(peer_id: int) -> void:
	_left_events.append(peer_id)


# --- HOST ------------------------------------------------------------------

func _host_tick(delta: float) -> void:
	match _phase:
		0:
			_host_start_interp()
		1:
			_host_run_interp(delta)
		2:
			_host_setup()
		3:
			_host_wait_join()
		4:
			_host_fake_window()
		5:
			_host_wait_damage(25.0, false, "N3 legit damage")
		6:
			_host_wait_damage(-1.0, true, "N4 oversized clamped")
		7:
			_host_wait_respawn()
		8:
			_host_wait_damage(10.0, false, "N8 hitbox take_damage")
		9:
			_host_wait_converge()
		10:
			_host_wait_leave()
		11:
			_finish()


func _host_start_interp() -> void:
	_interp_puppet = NetworkPlayerScript.new()
	_interp_puppet.name = "InterpPuppet"
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
	_advance(1)


func _host_run_interp(delta: float) -> void:
	_interp_feed_timer += delta
	# Feed a 2 m/s snapshot every 0.1 s (10 Hz — slower than the 20 Hz
	# real sender, harsher than production). Feed index drives position,
	# NOT the reset timer (that was a bug: it pinned every snapshot to
	# t ~= 0.1).
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
		_check("I1 interp max step < 0.35 m (got %.3f)" % _interp_max_step,
			_interp_max_step < 0.35)
		_check("I1 interp final error < 0.50 m (got %.3f)" % final_err,
			final_err < 0.50)
		_interp_puppet.queue_free()
		_interp_puppet = null
		_advance(2)


func _host_setup() -> void:
	_net = NetManagerScript.new()
	_net.name = "NetManager"
	root.add_child(_net)
	_net.player_joined.connect(_on_host_joined)
	_net.player_left.connect(_on_left)
	_net.damage_applied.connect(_on_damage)
	_net.kill_confirmed.connect(_on_kill)
	_net.player_respawned.connect(_on_respawn)
	_net.set_player_name("HostPlayer")
	var err: Error = _net.create_server(PORT)
	_check("N0 create_server OK", err == OK, "(err=%d)" % err)
	_advance(3)


func _on_host_joined(peer_id: int, player_name: String) -> void:
	_joined_events.append(peer_id)
	if peer_id == 1:
		return
	_client_id = peer_id
	_puppet = NetworkPlayerScript.new()
	_puppet.name = "Puppet%d" % peer_id
	_puppet.setup(peer_id, player_name, false)
	_puppet.set_net_manager(_net)
	root.add_child(_puppet)
	_net.register_puppet(peer_id, _puppet)


func _host_wait_join() -> void:
	if _net.players.size() >= 2:
		_check("N1 handshake: host sees 2 players", _net.players.size() == 2)
		_check("N1 handshake: host sees ClientPlayer",
			_net.get_player_name(_client_id) == "ClientPlayer")
		_damage_events.clear()
		_advance(4)
	elif _phase_t > 6.0:
		_check("N1 handshake (timeout)", false,
			"host players=%d" % _net.players.size())
		_advance(11)


func _host_fake_window() -> void:
	# Client sends the fake broadcasts ~immediately after it sees the
	# sync, and waits 1.0 s before its legit request — so at 0.7 s the
	# fake has landed but the legit has not.
	if _phase_t >= 0.7:
		_check("N2 anti-cheat: fake damage_applied ignored by host",
			_net.get_hp(1) == 100.0, "(host hp=%.1f)" % _net.get_hp(1))
		_check("N2 anti-cheat: fake score_update ignored by host",
			int(_net.get_score_info(_client_id).get("score", -1)) == 0)
		_check("N2 anti-cheat: no damage event from fake", _damage_events.is_empty())
		_damage_events.clear()
		_advance(5)


func _host_wait_damage(expected_amount: float, expect_died: bool, label: String) -> void:
	for ev in _damage_events:
		if ev[0] == 1 and (expected_amount < 0.0 or ev[2] == expected_amount) and ev[4] == expect_died:
			if label.begins_with("N3"):
				_check("N3 legit damage: host HP 75", _net.get_hp(1) == 75.0,
					"(got %.1f)" % _net.get_hp(1))
			elif label.begins_with("N4"):
				_check("N4 oversized clamped: host HP 0 (not negative)",
					_net.get_hp(1) == 0.0, "(got %.1f)" % _net.get_hp(1))
				_check("N4 oversized clamped: kill_confirmed fired (headshot)",
					_kill_events.size() == 1 and _kill_events[0][2] == true)
				var info: Dictionary = _net.get_score_info(_client_id)
				_check("N4 oversized clamped: killer kills == 1",
					int(info.get("kills", -1)) == 1)
				_check("N4 oversized clamped: killer score == 150 (headshot)",
					int(info.get("score", -1)) == 150)
			elif label.begins_with("N8"):
				_check("N8 hitbox take_damage: host HP 90 via validated request",
					_net.get_hp(1) == 90.0, "(got %.1f)" % _net.get_hp(1))
			_damage_events.clear()
			if label.begins_with("N3"):
				_advance(6)
			elif label.begins_with("N4"):
				_advance(7)
			else:
				_advance(9)
			return
	if _phase_t > 5.0:
		_check(label + " (timeout, events=%s)" % str(_damage_events), false)
		_advance(11)


func _host_wait_respawn() -> void:
	if _respawn_events.has(1):
		_check("N5 respawn: host HP back to 100", _net.get_hp(1) == 100.0)
		_respawn_events.clear()
		_advance(8)
	elif _phase_t > 5.0:
		_check("N5 respawn (timeout)", false)
		_advance(11)


func _host_wait_converge() -> void:
	var err := -1.0
	if _puppet != null and is_instance_valid(_puppet):
		err = _puppet.global_position.distance_to(Vector3(10, 1, 0))
		if err < 0.60:
			_check("N6 state convergence: puppet within 0.60 m of (10,1,0)",
				true, "(err=%.3f)" % err)
			_advance(10)
			return
	if _phase_t > 6.0:
		_check("N6 state convergence: puppet within 0.60 m of (10,1,0)",
			false, "(err=%.3f)" % err)
		_advance(10)


func _host_wait_leave() -> void:
	if _left_events.has(_client_id):
		_check("N7 disconnect: host emitted player_left", true)
		_check("N7 disconnect: host player table back to 1",
			_net.players.size() == 1)
		_check("N7 disconnect: puppet unregistered", _net.get_puppet(_client_id) == null)
		_check("N7 disconnect: puppet freed",
			_puppet == null or not is_instance_valid(_puppet))
		_check("N7 disconnect: host match still online", _net.is_online())
		_net.leave()
		_check("N7 disconnect: host offline after leave", not _net.is_online())
		_check("N7 disconnect: host tables empty", _net.players.is_empty())
		_advance(11)
	elif _phase_t > 6.0:
		_check("N7 disconnect (timeout, left=%s)" % str(_left_events), false)
		_advance(11)


# --- CLIENT ----------------------------------------------------------------

func _client_tick(delta: float) -> void:
	match _phase:
		0:
			_client_setup()
		1:
			_client_wait_join()
		2:
			_client_fake_window()
		3:
			_client_wait_damage(25.0, false, "N3 legit damage")
		4:
			_client_wait_damage(-1.0, true, "N4 oversized clamped")
		5:
			_client_wait_respawn()
		6:
			_client_factory()
		70:
			_client_wait_damage(10.0, false, "N8 hitbox take_damage")
		7:
			_client_state(delta)
		8:
			_client_leave()
		9:
			_finish()


func _client_setup() -> void:
	_net = NetManagerScript.new()
	_net.name = "NetManager"
	root.add_child(_net)
	_net.damage_applied.connect(_on_damage)
	_net.kill_confirmed.connect(_on_kill)
	_net.player_respawned.connect(_on_respawn)
	_net.set_player_name("ClientPlayer")
	var err: Error = _net.create_client("127.0.0.1", PORT)
	_check("N0 create_client OK", err == OK, "(err=%d)" % err)
	_advance(1)


func _client_wait_join() -> void:
	if _net.local_id != 0 and _net.players.size() >= 2 \
			and _net.get_player_name(1) == "HostPlayer":
		_client_id = _net.local_id
		_check("N1 handshake: client id assigned", _client_id != 0)
		_check("N1 handshake: client sees HostPlayer",
			_net.get_player_name(1) == "HostPlayer")
		_check("N1 handshake: client HP mirror for host is 100",
			_net.get_hp(1) == 100.0)
		_fake_body = CharacterBody3D.new()
		_fake_body.name = "FakeBody"
		_fake_body.position = Vector3(0, 1, 0)
		root.add_child(_fake_body)
		_shim = NetworkPlayerScript.new()
		_shim.name = "LocalShim"
		_shim.setup(_client_id, "ClientPlayer", true)
		_shim.set_net_manager(_net)
		root.add_child(_shim)
		_shim.bind_local_player(_fake_body)
		# Fire the fake broadcasts NOW; phase 2 waits, then asserts.
		_net.rpc("_rpc_damage_applied", 1, _client_id, 999.0, 0.0, true, false)
		_net.rpc("_rpc_score_update", _client_id, 999, 0, 99999)
		_advance(2)
	elif _phase_t > 6.0:
		_check("N1 handshake (timeout)", false,
			"client id=%d players=%d" % [_net.local_id, _net.players.size()])
		_advance(9)


func _client_fake_window() -> void:
	if _phase_t >= 1.0:
		_check("N2 anti-cheat: fake damage_applied ignored by faking client too",
			_net.get_hp(1) == 100.0, "(client mirror hp=%.1f)" % _net.get_hp(1))
		_check("N2 anti-cheat: no damage event from fake", _damage_events.is_empty())
		_damage_events.clear()
		_net.request_damage(1, 25.0, Vector3.ZERO, false, "ar7")
		_advance(3)


func _client_wait_damage(expected_amount: float, expect_died: bool, label: String) -> void:
	for ev in _damage_events:
		if ev[0] == 1 and (expected_amount < 0.0 or ev[2] == expected_amount) and ev[4] == expect_died:
			if label.begins_with("N3"):
				_check("N3 legit damage: client mirror HP 75", _net.get_hp(1) == 75.0,
					"(got %.1f)" % _net.get_hp(1))
				_net.request_damage(1, 9999.0, Vector3.ZERO, true, "lr8")
				_damage_events.clear()
				_advance(4)
			elif label.begins_with("N4"):
				_check("N4 oversized clamped: client mirror HP 0", _net.get_hp(1) == 0.0)
				_check("N4 oversized clamped: client mirror score 150",
					int(_net.get_score_info(_client_id).get("score", -1)) == 150)
				_net.request_respawn()
				_damage_events.clear()
				_advance(5)
			else:
				_check("N8 hitbox take_damage: client mirror HP 90",
					_net.get_hp(1) == 90.0, "(got %.1f)" % _net.get_hp(1))
				_damage_events.clear()
				_state_t = 0.0
				_advance(7)
			return
	if _phase_t > 5.0:
		_check(label + " (timeout, events=%s)" % str(_damage_events), false)
		_advance(9)


func _client_wait_respawn() -> void:
	if _respawn_events.has(1):
		_check("N5 respawn: client mirror HP back to 100", _net.get_hp(1) == 100.0)
		_respawn_events.clear()
		_advance(6)
	elif _phase_t > 5.0:
		_check("N5 respawn (timeout)", false)
		_advance(9)


func _client_factory() -> void:
	if not _factory_fired:
		_factory_fired = true
		_factory_puppet = _net.create_network_player(1, false)
		root.add_child(_factory_puppet)
		_check("N8 factory: create_network_player returns NetworkPlayer",
			_factory_puppet != null and _factory_puppet.has_method("receive_state"))
		var hitbox = _factory_puppet.get_node_or_null("PuppetHitbox")
		_check("N8 factory: puppet has take_damage hitbox",
			hitbox != null and hitbox.has_method("take_damage"))
		if hitbox != null:
			# The REAL WeaponBase path: collider.take_damage() on the hitbox.
			hitbox.take_damage(10.0, Vector3.ZERO, false)
		# Mirror check happens in the phase-70 waiter (N8 branch).
		_phase = 70
		_phase_t = 0.0


func _client_state(delta: float) -> void:
	_state_t += delta
	# Move the fake body 0 -> 10 m on X over 1.0 s (10 m/s), then hold.
	var t := minf(_state_t, 1.0)
	_fake_body.position = Vector3(10.0 * t, 1, 0)
	_fake_body.velocity = Vector3(10, 0, 0) if _state_t <= 1.0 else Vector3.ZERO
	if _state_t >= 1.7:
		_advance(8)


func _client_leave() -> void:
	_net.leave()
	_check("N7 disconnect: client offline after leave", not _net.is_online())
	_advance(9)


func _finish() -> void:
	_done = true
	print("verify_netcode[%s]: %d passed, %d failed" % [_mode, _passed, _failed])
	quit(0 if _failed == 0 else 1)
