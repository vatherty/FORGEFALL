# scripts/net/net_match.gd
# FORGEFALL — Goal 4 MULTIPLAYER (Worker C: match modes).
# Runs an online match: mode, teams, score limit, win condition, match
# lifecycle, and the scoreboard/killfeed presentation.
#
# TWO MODES, ONE DAMAGE PATH (read this before wiring anything):
# - DELEGATED (real play): /root/NetManager exists and is online. Then
#   NetManager owns ALL transport, damage, HP, scores, respawns and
#   puppet state (Worker A, verified in tools/verify_netcode.gd).
#   NetMatch is ONLY the match layer: it assigns teams, tracks team
#   kill-counts toward the score limit, translates NetManager signals
#   into killfeed/scoreboard updates, runs the match clock, and owns
#   match start/end. It NEVER applies damage, NEVER runs respawn timers,
#   NEVER broadcasts puppet state in this mode — doing so would double
#   NetManager's authority. Puppets are NetworkPlayer nodes from
#   NetManager.create_network_player() (the factory hook); NetMatch
#   spawns them, so the coordinator must NOT also spawn puppets on
#   player_joined. The local peer also gets a NetworkPlayer SHIM
#   (bind_local_player) that streams state to NetManager.
# - STANDALONE (no NetManager — headless tests, offline drills): NetMatch
#   runs the full stack itself with its own NetPuppet nodes (below), its
#   own host-validated damage, respawn timers and snapshots. Same match
#   semantics, no NetManager required.
# In BOTH modes there is exactly ONE damage path and NO client-callable
# kill RPC: kills are computed by the host from HP only (NetManager's
# request_damage in delegated mode, _host_on_hit in standalone mode).
#
# MODES: TDM ships. CO-OP is DEFERRED (see SUPPORTED_MODES): enemy sync
# needs a NetworkEnemy layer (Worker A, not landed) and WaveManager is
# local-only — syncing it would fork the wave system. start_match("coop")
# returns false rather than silently falling back, so the lobby can say
# "coming soon" instead of starting a broken mode.
#
# PLAYERS (standalone mode): the LOCAL peer uses the normal player scene
# (group "player", spawned by Main as usual — NetMatch never instantiates
# it). REMOTE peers get NetPuppet nodes (below): capsule + head hitbox,
# team colour, NO input, NO group "player", so HUD / waves / enemies never
# mistake a puppet for the local player. Puppets exist so the shooter's
# weapon raycast (mask 0xFFFFFFFF, hits anything with take_damage) has
# something to strike WITHOUT any weapon-code edit: puppet.take_damage()
# forwards the hit to the host for validation. Puppet HP is a mirror —
# the host's authoritative HP is the truth, synced on every damage/kill
# event plus a 1 Hz full sync to correct local regen drift (player.gd
# regens locally and has no HP setter, so the victim converges via
# take_damage/heal deltas against the cached health_changed value).
#
# COORDINATOR WIRING (Main / lobby):
#   1. Register NetManager as autoload "NetManager" (Worker A) BEFORE
#      any match. Without it, NetMatch runs standalone (tests only).
#   2. var m := NetMatch.new(); add_child(m)
#      m.kill_confirmed.connect(killfeed.add_entry)   # NetKillfeed, direct
#      m.match_ended.connect(_on_net_match_ended)     # show result, back to lobby
#   3. Host: m.start_match(peer_ids, names, "tdm", 25, 0.0) AFTER the
#      lobby has connected all peers (NetManager.create_server/_client
#      + player_joined for everyone). Clients learn the match from the
#      _rpc_begin_match broadcast — they never call start_match.
#   4. Do NOT spawn puppets on player_joined (NetMatch does it), do NOT
#      wire NetworkPlayer hitboxes separately (exactly one damage path),
#      do NOT start WaveManager / GameModeManager survival in a net
#      match (TDM has no AI enemies; if waves run anyway, enemies ignore
#      puppets because puppets are not in group "player").
#   5. On quit/disconnect: ALWAYS m.stop_match() BEFORE freeing NetMatch
#      (it unregisters puppets from NetManager; freeing first leaves
#      NetManager holding freed refs). stop_match() never disconnects
#      the network peer — Worker A owns connect/disconnect.
# Single-player is untouched: this node is only instanced for net matches
# and never writes to the Game autoload.
class_name NetMatch
extends Node

## Args mirror NetKillfeed.add_entry so the coordinator can connect the
## signal straight to the killfeed with no adapter.
signal kill_confirmed(killer_name: String, victim_name: String,
	weapon_display: String, killer_team: int, victim_team: int,
	headshot: bool, suicide: bool)
signal match_started(mode: String, score_limit: int)
signal match_ended(winner_team: int, result: Dictionary)
signal score_changed(team_scores: Array[int])

const SUPPORTED_MODES := ["tdm"]
const DEFAULT_SCORE_LIMIT := 25
const PLAYER_MAX_HP := 100.0  # mirrors player.gd MAX_HP
const RESPAWN_DELAY := 3.0
const SNAPSHOT_INTERVAL := 0.1  # puppet transform broadcast rate (10 Hz)
const HP_SYNC_INTERVAL := 1.0   # host full-HP re-sync (corrects regen drift)
const UNKNOWN_WEAPON_DAMAGE_CAP := 150.0
const TEAM_NAMES := ["ALPHA", "BRAVO"]
const TEAM_COLORS := [Color(1.0, 0.48, 0.11), Color(0.25, 0.6, 1.0)]


# --------------------------------------------------------------------------
# Remote-player puppet. CharacterBody3D with a capsule body + a separate
# head hitbox in group "enemy_head" (so WeaponBase._is_headshot() detects
# headshots — the same mechanism enemy heads use). No _physics_process,
# no input, collision_mask 0 (raycast target only, never pushes anything).
# take_damage() NEVER applies damage locally: it forwards the hit to the
# owning NetMatch, which routes it to the host for validation.
class NetPuppet extends CharacterBody3D:
	var peer_id := -1
	var team := 0
	var hp_mirror := NetMatch.PLAYER_MAX_HP
	var alive_mirror := true
	var _match: Object = null
	var _target_pos := Vector3.ZERO
	var _target_rot_y := 0.0
	var _has_target := false
	var _body_mesh: MeshInstance3D
	var _head_mesh: MeshInstance3D

	func _init(p_peer_id: int, p_team: int, p_match: Object) -> void:
		peer_id = p_peer_id
		team = p_team
		_match = p_match
		name = "NetPuppet_%d" % p_peer_id
		collision_layer = 2  # same layer as the player (player.tscn)
		collision_mask = 0
		add_to_group("net_puppet")
		var shape := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.4
		cap.height = 1.1
		shape.shape = cap
		shape.position.y = 0.95
		add_child(shape)
		_body_mesh = MeshInstance3D.new()
		var body_mesh := CapsuleMesh.new()
		body_mesh.radius = 0.4
		body_mesh.height = 1.1
		_body_mesh.mesh = body_mesh
		_body_mesh.position.y = 0.95
		_body_mesh.material_override = _team_material(p_team)
		add_child(_body_mesh)
		# Head hitbox: StaticBody3D child so the raycast collider IS the
		# head (WeaponBase checks collider group, then parent group).
		var head := NetPuppetHead.new(self)
		head.position.y = 1.62
		add_child(head)
		_head_mesh = MeshInstance3D.new()
		var head_mesh := BoxMesh.new()
		head_mesh.size = Vector3(0.55, 0.5, 0.55)
		_head_mesh.mesh = head_mesh
		_head_mesh.position.y = 1.62
		_head_mesh.material_override = _team_material(p_team)
		add_child(_head_mesh)

	func _team_material(p_team: int) -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = NetMatch.TEAM_COLORS[clampi(p_team, 0, 1)]
		return m

	# WeaponBase calls this when a hitscan ray strikes the puppet.
	# Forwards to the match; the host decides whether it counts.
	func take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void:
		if not alive_mirror:
			return
		if _match != null and is_instance_valid(_match) and _match.has_method("report_hit"):
			_match.call("report_hit", peer_id, amount, "", is_headshot)

	func is_dead() -> bool:
		return not alive_mirror

	func apply_state(pos: Vector3, rot_y: float, hp: float, alive: bool) -> void:
		if not _has_target:
			global_position = pos
			rotation.y = rot_y
		_target_pos = pos
		_target_rot_y = rot_y
		_has_target = true
		hp_mirror = hp
		set_alive(alive)

	func set_alive(alive: bool) -> void:
		alive_mirror = alive
		visible = alive

	func _process(delta: float) -> void:
		if not _has_target or not alive_mirror:
			return
		# Cheap exponential smoothing toward the latest snapshot. No
		# prediction: at 10 Hz + ~50 ms LAN latency the lag is unnoticeable
		# for a first netcode pass, and prediction would rubber-band.
		var k := 1.0 - exp(-12.0 * delta)
		global_position = global_position.lerp(_target_pos, k)
		rotation.y = lerp_angle(rotation.y, _target_rot_y, k)


# Head hitbox for puppets. Forwards hits to the puppet (which forwards to
# the match). Group "enemy_head" is what WeaponBase._is_headshot() checks.
class NetPuppetHead extends StaticBody3D:
	var _puppet: NetPuppet = null

	func _init(p_puppet: NetPuppet) -> void:
		_puppet = p_puppet
		name = "NetPuppetHead"
		collision_layer = 2
		collision_mask = 0
		add_to_group("enemy_head")
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.55, 0.5, 0.55)
		shape.shape = box
		add_child(shape)

	func take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void:
		if _puppet != null and is_instance_valid(_puppet):
			_puppet.take_damage(amount, hit_position, true)

	func is_dead() -> bool:
		if _puppet != null and is_instance_valid(_puppet):
			return _puppet.is_dead()
		return true


# --------------------------------------------------------------------------
var match_active := false
var match_mode := "tdm"
var score_limit := DEFAULT_SCORE_LIMIT
var time_limit_seconds := 0.0
var match_time_left := 0.0
var winner_team := -1
var _result: Dictionary = {}

## peer_id -> {name, team, hp, alive, kills, deaths, puppet: Node}
var _players: Dictionary = {}
var _team_scores: Array[int] = [0, 0]
var _respawn_timers: Dictionary = {}  # peer_id -> seconds left (host only, standalone mode)
var _snap_t := 0.0
var _hp_sync_t := 0.0
var _local_hp := PLAYER_MAX_HP
var _local_respawn_t := 0.0  # delegated mode: delay before WE request_respawn()
var _local_shim: Node = null  # delegated mode: our NetworkPlayer state shim
var _nm_signals_connected := false
var _scoreboard: NetScoreboard = null


func _ready() -> void:
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_ensure_scoreboard()
	_connect_nm_signals()


func _ensure_scoreboard() -> void:
	if _scoreboard == null:
		_scoreboard = NetScoreboard.new()
		add_child(_scoreboard)


# --- NetManager delegation ---------------------------------------------------
# Duck-typed (has_method/has_signal): NetMatch compiles and runs with or
# without NetManager. _using_nm() is evaluated per call, never cached,
# so a match started before NetManager comes online still delegates once
# it is online — and headless tests (no NetManager) stay standalone.

func _nm() -> Node:
	return get_node_or_null("/root/NetManager") as Node


func _using_nm() -> bool:
	var nm := _nm()
	if nm == null or not nm.has_method("is_online"):
		return false
	return bool(nm.call("is_online"))


func _try_connect_nm(nm: Node, sig: String, fn: Callable) -> void:
	if nm.has_signal(sig) and not nm.is_connected(sig, fn):
		nm.connect(sig, fn)


func _connect_nm_signals() -> void:
	if _nm_signals_connected:
		return
	var nm := _nm()
	if nm == null:
		return
	_nm_signals_connected = true
	_try_connect_nm(nm, "damage_applied", _on_nm_damage)
	_try_connect_nm(nm, "kill_confirmed", _on_nm_kill)
	_try_connect_nm(nm, "score_changed", _on_nm_score)
	_try_connect_nm(nm, "player_respawned", _on_nm_respawned)
	_try_connect_nm(nm, "player_left", _on_nm_player_left)
	_try_connect_nm(nm, "server_disconnected", _on_nm_server_disconnected)


## NetManager damage broadcast: mirror HP/alive, converge the LOCAL
## player's real HP, and schedule OUR respawn request if WE died.
## (NetManager owns the damage; this only mirrors + drives the local body.)
func _on_nm_damage(victim_id: int, _attacker_id: int, _amount: float,
		new_hp: float, died: bool) -> void:
	if not match_active or not _using_nm():
		return
	if _players.has(victim_id):
		_players[victim_id]["hp"] = new_hp
		_players[victim_id]["alive"] = not died
	if died and _scoreboard != null:
		_scoreboard.mark_alive(victim_id, false)
	if victim_id == multiplayer.get_unique_id():
		_converge_local_hp(new_hp)
		if died:
			_local_respawn_t = RESPAWN_DELAY


## NetManager kill broadcast: team score is derived from the scoreboard
## mirror (recomputed in _on_nm_score, which always follows this signal),
## so this handler only marks the victim dead and feeds the killfeed.
func _on_nm_kill(killer_id: int, victim_id: int, headshot: bool) -> void:
	if not match_active or not _using_nm():
		return
	if not _players.has(killer_id) or not _players.has(victim_id):
		return
	_players[victim_id]["alive"] = false
	_players[victim_id]["hp"] = 0.0
	if _scoreboard != null:
		_scoreboard.mark_alive(victim_id, false)
	kill_confirmed.emit(str(_players[killer_id]["name"]),
		str(_players[victim_id]["name"]),
		_nm_killer_weapon(killer_id),
		int(_players[killer_id]["team"]),
		int(_players[victim_id]["team"]), headshot, false)


## Killer's current weapon for the killfeed, from their NetworkPlayer
## puppet's synced current_weapon. "" / no puppet -> generic "WEAPON"
## (NetManager's kill signal carries no weapon id).
func _nm_killer_weapon(killer_id: int) -> String:
	var nm := _nm()
	if nm != null and nm.has_method("get_puppet"):
		var pup: Variant = nm.call("get_puppet", killer_id)
		if pup != null and (pup as Object).get("current_weapon") != null:
			var w := str((pup as Object).get("current_weapon"))
			if not w.is_empty():
				return _weapon_display(w)
	return "WEAPON"


## NetManager score broadcast: mirror stats into the scoreboard, derive
## team scores (kill counts) from the mirror, then check the win.
func _on_nm_score(peer_id: int, kills: int, deaths: int, score: int) -> void:
	if not match_active or not _using_nm():
		return
	if _scoreboard != null:
		_scoreboard.apply_player_stats(peer_id, kills, deaths, score)
	_recompute_team_scores_from_board()
	score_changed.emit(_team_scores.duplicate())
	for team in 2:
		if _team_scores[team] >= score_limit:
			_finish_match(team, "score_limit")
			return


func _recompute_team_scores_from_board() -> void:
	_team_scores = [0, 0]
	if _scoreboard == null:
		return
	for r in _scoreboard.get_rows_sorted():
		var t := clampi(int(r["team"]), 0, 1)
		_team_scores[t] += int(r["kills"])


## NetManager respawn broadcast: mirror alive/HP; respawn the LOCAL
## player body when WE are the one respawning (remote puppets are
## handled by NetManager -> NetworkPlayer.apply_respawn).
func _on_nm_respawned(peer_id: int, spawn_pos: Vector3) -> void:
	if not match_active or not _using_nm():
		return
	if _players.has(peer_id):
		_players[peer_id]["hp"] = PLAYER_MAX_HP
		_players[peer_id]["alive"] = true
	if _scoreboard != null:
		_scoreboard.mark_alive(peer_id, true)
	if peer_id == multiplayer.get_unique_id():
		_respawn_local(spawn_pos)


## NetManager player_left: drop the leaver from the roster/scoreboard.
## Host only: < 2 players left ends the match (forfeit). Clients never
## decide a forfeit — they learn it from the host's _rpc_match_end.
func _on_nm_player_left(peer_id: int) -> void:
	if not match_active or not _using_nm():
		return
	if not _players.has(peer_id):
		return
	var puppet: Variant = _players[peer_id].get("puppet")
	if puppet is Node and is_instance_valid(puppet):
		(puppet as Node).queue_free()
	_players.erase(peer_id)
	if _scoreboard != null:
		var snap := _scoreboard.serialize()
		var kept: Array = []
		for entry in snap.get("players", []):
			if int(entry.get("peer_id", -1)) != peer_id:
				kept.append(entry)
		snap["players"] = kept
		_scoreboard.apply_snapshot(snap)
	if multiplayer.is_server():
		var remaining: Array[int] = []
		for pid in _players.keys():
			remaining.append(int(pid))
		if remaining.size() < 2:
			var w := -1
			if remaining.size() == 1:
				w = int(_players[remaining[0]]["team"])
			_finish_match(w, "forfeit")


## NetManager server_disconnected: host left, no migration. End the match.
func _on_nm_server_disconnected() -> void:
	if not match_active:
		return
	match_active = false
	_result = {"winner_team": -2, "winner_name": "HOST LEFT",
		"draw": false, "team_scores": _team_scores.duplicate(),
		"mode": match_mode, "score_limit": score_limit,
		"reason": "host_left",
		"snapshot": _scoreboard.serialize() if _scoreboard != null else {},
		"rows": _scoreboard.get_rows_sorted() if _scoreboard != null else []}
	match_ended.emit(-2, _result)


func get_scoreboard() -> NetScoreboard:
	return _scoreboard


func set_scoreboard(sb: NetScoreboard) -> void:
	# Coordinator-owned scoreboard (e.g. one already in the HUD layer).
	# If NetMatch created its own in _ready, drop it.
	if _scoreboard != null and is_instance_valid(_scoreboard) and _scoreboard != sb:
		_scoreboard.queue_free()
	_scoreboard = sb


# --- match lifecycle (host) -------------------------------------------------

## Host-only. peer_ids = every peer in the match INCLUDING the host.
## names = {peer_id: display name}. Returns false (no state changed) for:
## unsupported mode (incl. "coop"), < 2 players, already active, not host.
func start_match(peer_ids: Array, names: Dictionary, mode: String = "tdm",
		p_score_limit: int = DEFAULT_SCORE_LIMIT,
		p_time_limit: float = 0.0) -> bool:
	if match_active:
		push_warning("NetMatch: match already active.")
		return false
	if not SUPPORTED_MODES.has(mode):
		push_warning("NetMatch: mode '%s' not supported (supported: %s)." % [mode, SUPPORTED_MODES])
		return false
	if not multiplayer.is_server():
		push_warning("NetMatch: start_match is host-only; clients get the match via broadcast.")
		return false
	if peer_ids.size() < 2:
		push_warning("NetMatch: need at least 2 players.")
		return false
	_ensure_scoreboard()
	_connect_nm_signals()
	match_mode = mode
	score_limit = maxi(1, p_score_limit)
	time_limit_seconds = maxf(0.0, p_time_limit)
	match_time_left = time_limit_seconds
	winner_team = -1
	_result = {}
	_team_scores = [0, 0]
	_respawn_timers.clear()
	_players.clear()
	# Balanced teams: sorted ids, each new player joins the smaller team
	# (tie -> team 0). Deterministic, host balances as players join.
	var sorted_ids := peer_ids.duplicate()
	sorted_ids.sort()
	var counts := [0, 0]
	var roster: Array = []
	for pid in sorted_ids:
		var team := 0 if counts[0] <= counts[1] else 1
		counts[team] += 1
		var pname := str(names.get(int(pid), "PLAYER %d" % int(pid)))
		_players[int(pid)] = {
			"name": pname, "team": team, "hp": PLAYER_MAX_HP,
			"alive": true, "kills": 0, "deaths": 0, "puppet": null,
		}
		roster.append({"peer_id": int(pid), "name": pname, "team": team})
	_apply_roster_local(roster)
	match_active = true
	_hook_local_player()
	_broadcast("_rpc_begin_match", [roster, {
		"mode": match_mode, "score_limit": score_limit,
		"time_limit": time_limit_seconds}])
	match_started.emit(match_mode, score_limit)
	return true


## Local half of roster application: scoreboard rows + puppets. Shared by
## the host path (start_match) and the client path (_rpc_begin_match).
func _apply_roster_local(roster: Array) -> void:
	if _scoreboard != null:
		_scoreboard.reset()
	var my_id := multiplayer.get_unique_id()
	for entry in roster:
		var pid := int(entry.get("peer_id", -1))
		if pid < 0:
			continue
		var pname := str(entry.get("name", "PLAYER %d" % pid))
		var team := clampi(int(entry.get("team", 0)), 0, 1)
		if _scoreboard != null:
			_scoreboard.register_player(pid, pname, team)
		if pid == my_id:
			# Local peer: real player scene, never a puppet. In delegated
			# mode also create the NetworkPlayer SHIM that streams our
			# state to NetManager (it never renders or moves anything).
			if _using_nm():
				_spawn_local_shim()
			continue
		_spawn_puppet(pid, team)


func _spawn_puppet(peer_id: int, team: int) -> void:
	# Worker A factory first (duck-typed: never a hard dependency).
	var factory := _net_manager()
	if factory != null and factory.has_method("create_network_player"):
		var node: Variant = factory.call("create_network_player", peer_id, false)
		if node is Node:
			(node as Node).name = "NetPlayer_%d" % peer_id
			add_child(node as Node)
			if _players.has(peer_id):
				_players[peer_id]["puppet"] = node
			return
	var puppet := NetPuppet.new(peer_id, team, self)
	add_child(puppet)
	if _players.has(peer_id):
		_players[peer_id]["puppet"] = puppet


func _spawn_local_shim() -> void:
	var factory := _net_manager()
	if factory == null or not factory.has_method("create_network_player"):
		return
	if _local_shim != null and is_instance_valid(_local_shim):
		return
	var node: Variant = factory.call("create_network_player",
		multiplayer.get_unique_id(), true)
	if node is Node:
		(node as Node).name = "NetPlayer_Local"
		add_child(node as Node)
		_local_shim = node as Node
		var p := _local_player()
		if p != null and (node as Node).has_method("bind_local_player"):
			(node as Node).call("bind_local_player", p)


func _net_manager() -> Node:
	# Canonical name is /root/NetManager (project.godot autoload); /root/Net
	# is a fallback if the autoload was registered under that name instead.
	var nm := get_node_or_null("/root/NetManager")
	if nm != null:
		return nm
	return get_node_or_null("/root/Net") as Node


func _hook_local_player() -> void:
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_signal("health_changed"):
		if not p.is_connected("health_changed", _on_local_health_changed):
			p.connect("health_changed", _on_local_health_changed)


func _on_local_health_changed(hp: float, _max_hp: float) -> void:
	_local_hp = hp


## End the match now (host). Reason: "score_limit" | "time_limit" |
## "forfeit" (a team emptied). Clients learn via _rpc_match_end.
func _finish_match(p_winner_team: int, reason: String) -> void:
	if not match_active:
		return
	match_active = false
	winner_team = p_winner_team
	if _using_nm():
		# Delegated mode: the win can fire on the killer's score update
		# before the victim's arrives (NetManager emits them as two
		# separate broadcasts). Refresh the whole mirror from
		# NetManager's table so the result snapshot is never stale.
		var nm := _nm()
		if nm != null and nm.has_method("get_players") and _scoreboard != null:
			var tbl: Dictionary = nm.call("get_players")
			# Current roster only: leavers already dropped from _players
			# must NOT be re-added to the result by the refresh.
			for pid in _players.keys():
				if not tbl.has(pid):
					continue
				var e: Dictionary = tbl[pid]
				_scoreboard.apply_player_stats(int(pid),
					int(e.get("kills", 0)), int(e.get("deaths", 0)),
					int(e.get("score", 0)))
				if nm.has_method("get_hp"):
					_scoreboard.mark_alive(int(pid),
						float(nm.call("get_hp", int(pid))) > 0.0)
	_result = {
		"winner_team": winner_team,
		"winner_name": TEAM_NAMES[winner_team] if winner_team >= 0 else "DRAW",
		"draw": winner_team < 0,
		"team_scores": _team_scores.duplicate(),
		"mode": match_mode,
		"score_limit": score_limit,
		"reason": reason,
		"snapshot": _scoreboard.serialize() if _scoreboard != null else {},
		"rows": _scoreboard.get_rows_sorted() if _scoreboard != null else [],
	}
	match_ended.emit(winner_team, _result)
	# Goal 6 PROGRESSION: match-end XP for this peer (host path;
	# clients report from _rpc_match_end instead). Only when actually
	# networked — offline test drives must not award XP.
	if is_inside_tree() and multiplayer.has_multiplayer_peer():
		var prog := get_node_or_null("/root/Progression")
		if prog != null and prog.has_method("report_event"):
			var my_team := -1
			var my_id := multiplayer.get_unique_id()
			if _players.has(my_id):
				my_team = int(_players[my_id].get("team", -1))
			prog.call("report_event", "match_end", {
				"mode": match_mode,
				"won": winner_team >= 0 and my_team == winner_team,
				"draw": winner_team < 0,
				"score": 0})
	_broadcast("_rpc_match_end", [winner_team, _result])


## Leave / tear down the match. Frees puppets, clears state. Does NOT
## disconnect the network peer — Worker A owns the connection lifecycle.
func stop_match() -> void:
	match_active = false
	_respawn_timers.clear()
	_local_respawn_t = 0.0
	var nm := _nm()
	for pid in _players.keys():
		var puppet: Variant = _players[pid].get("puppet")
		if puppet is Node and is_instance_valid(puppet):
			(puppet as Node).queue_free()
		# Delegated mode: drop the puppet from NetManager's registry
		# BEFORE the node is freed, or it holds a freed ref.
		if nm != null and nm.has_method("unregister_puppet"):
			nm.call("unregister_puppet", int(pid))
	if _local_shim != null and is_instance_valid(_local_shim):
		_local_shim.queue_free()
	_local_shim = null
	_players.clear()
	_team_scores = [0, 0]
	winner_team = -1
	_result = {}
	_local_hp = PLAYER_MAX_HP
	if _scoreboard != null:
		_scoreboard.reset()


# --- hit / kill flow ---------------------------------------------------------
#
# Shooter-side entry. Called by puppet.take_damage() on the shooter's
# machine (weapon raycast struck a puppet). Clients forward to the host;
# the host applies directly. weapon_id is best-effort: puppets pass ""
# and the host resolves the shooter's current weapon from WeaponManager;
# tests / direct callers may pass an explicit id.
func report_hit(victim_id: int, damage: float, weapon_id: String, headshot: bool) -> void:
	if not match_active:
		return
	if _using_nm():
		# Delegated mode: NetManager owns damage. Forward as a damage
		# request (hit position unknown on this path — NetworkPlayer
		# hitboxes pass the real position via request_damage directly,
		# so this entry is only for direct callers).
		var nm := _nm()
		if nm != null and nm.has_method("request_damage"):
			nm.call("request_damage", victim_id, damage, Vector3.ZERO,
				headshot, weapon_id)
		return
	if multiplayer.is_server():
		_host_on_hit(multiplayer.get_unique_id(), victim_id, damage, weapon_id, headshot)
	elif _net_connected():
		rpc_id(1, "_rpc_report_hit", victim_id, damage, weapon_id, headshot)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_report_hit(victim_id: int, damage: float, weapon_id: String,
		headshot: bool) -> void:
	# The attacker is ALWAYS the true RPC sender — a client cannot claim
	# to be someone else, so a forged kill (or a kill on someone else's
	# behalf) is structurally impossible.
	_host_on_hit(multiplayer.get_remote_sender_id(), victim_id, damage,
		weapon_id, headshot)


## Host-authoritative hit resolution. `sender_id` is the verified RPC
## sender (or the host's own id for local hits). All validation lives
## here; nothing below trusts the client.
func _host_on_hit(sender_id: int, victim_id: int, damage: float,
		weapon_id: String, headshot: bool) -> void:
	if not match_active or not multiplayer.is_server():
		return
	if _using_nm():
		return  # Delegated mode: NetManager owns damage. A client that
		# calls _rpc_report_hit directly is ignored here — its damage
		# only ever flows through NetManager.request_damage.
	if not _players.has(sender_id) or not _players.has(victim_id):
		return  # unknown peer (stale / forged roster entry)
	if sender_id == victim_id:
		return  # no self-damage
	var attacker: Dictionary = _players[sender_id]
	var victim: Dictionary = _players[victim_id]
	if not bool(attacker["alive"]) or not bool(victim["alive"]):
		return  # dead players neither shoot nor take damage
	if int(attacker["team"]) == int(victim["team"]):
		return  # friendly fire off
	if not is_finite(damage) or damage <= 0.0:
		return
	# Clamp to the weapon's real max: base damage (falloff only lowers
	# it) x headshot multiplier. A client claiming 99999 damage gets the
	# weapon's max, nothing more. Unknown weapon -> hard cap.
	var wid := weapon_id
	if wid.is_empty():
		wid = _current_weapon_id(sender_id)
	var cap := _weapon_damage_cap(wid, headshot)
	var applied := minf(damage, cap)
	var hp := float(victim["hp"]) - applied
	victim["hp"] = hp
	if hp <= 0.0:
		_apply_kill(sender_id, victim_id, wid, headshot)
	else:
		_apply_damage(victim_id, hp, sender_id, wid, headshot)


## Host-side damage application (non-lethal): mirrors + local HP converge
## + broadcast. Also used by clients when they receive _rpc_damage_event.
func _apply_damage(victim_id: int, hp: float, attacker_id: int,
		weapon_id: String, headshot: bool) -> void:
	if _players.has(victim_id):
		_players[victim_id]["hp"] = hp
		var puppet: Variant = _players[victim_id].get("puppet")
		if puppet is NetPuppet:
			(puppet as NetPuppet).hp_mirror = hp
	if victim_id == multiplayer.get_unique_id():
		_converge_local_hp(hp)
	if multiplayer.is_server():
		_broadcast("_rpc_damage_event",
			[victim_id, hp, attacker_id, weapon_id, headshot])


## Host-side kill application: scoreboard, killfeed signal, victim death,
## respawn scheduling (host only), win check. Clients run the same code
## from _rpc_kill_event (minus the broadcast / respawn scheduling).
func _apply_kill(killer_id: int, victim_id: int, weapon_id: String,
		headshot: bool) -> void:
	if not _players.has(killer_id) or not _players.has(victim_id):
		return
	var killer: Dictionary = _players[killer_id]
	var victim: Dictionary = _players[victim_id]
	victim["hp"] = 0.0
	victim["alive"] = false
	victim["deaths"] = int(victim["deaths"]) + 1
	killer["kills"] = int(killer["kills"]) + 1
	var team := int(killer["team"])
	_team_scores[team] = int(_team_scores[team]) + 1
	if _scoreboard != null:
		_scoreboard.record_kill(killer_id, victim_id)
		_scoreboard.mark_alive(victim_id, false)
	var puppet: Variant = victim.get("puppet")
	if puppet is NetPuppet:
		(puppet as NetPuppet).hp_mirror = 0.0
		(puppet as NetPuppet).set_alive(false)
	if victim_id == multiplayer.get_unique_id():
		_converge_local_hp(0.0)
	var display := _weapon_display(weapon_id)
	kill_confirmed.emit(str(killer["name"]), str(victim["name"]), display,
		int(killer["team"]), int(victim["team"]), headshot, false)
	score_changed.emit(_team_scores.duplicate())
	# Goal 6 PROGRESSION: MP-kill XP — only the killer's own machine
	# reports (this runs on host + every client from the broadcast),
	# and only when actually networked (offline test drives excluded).
	if killer_id == multiplayer.get_unique_id() and is_inside_tree() \
			and multiplayer.has_multiplayer_peer():
		var prog := get_node_or_null("/root/Progression")
		if prog != null and prog.has_method("report_event"):
			prog.call("report_event", "mp_kill",
				{"headshot": headshot, "weapon_id": weapon_id})
	if multiplayer.is_server():
		_broadcast("_rpc_kill_event",
			[killer_id, victim_id, weapon_id, headshot])
		_broadcast("_rpc_sync_scoreboard",
			[_scoreboard.serialize() if _scoreboard != null else {}])
		_respawn_timers[victim_id] = RESPAWN_DELAY
		if int(_team_scores[team]) >= score_limit:
			_finish_match(team, "score_limit")


# --- local HP convergence ----------------------------------------------------
# player.gd has no HP setter and regens locally, so the victim machine
# converges its real player toward the host's HP with take_damage/heal
# deltas measured against the cached health_changed value.

func _local_player() -> Node:
	return get_tree().get_first_node_in_group("player")


func _converge_local_hp(target_hp: float) -> void:
	_hook_local_player()  # late hook: player may have spawned after start
	var p := _local_player()
	if p == null:
		return
	var delta := _local_hp - target_hp
	if delta > 0.5 and p.has_method("take_damage"):
		var pos := (p as Node3D).global_position if p is Node3D else Vector3.ZERO
		p.call("take_damage", delta, pos, false)
	elif delta < -0.5 and p.has_method("heal"):
		p.call("heal", -delta)


func _respawn_local(pos: Vector3) -> void:
	var p := _local_player()
	if p != null and p.has_method("respawn"):
		p.call("respawn", pos)


func _pick_spawn_pos(team: int) -> Vector3:
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	if not spawns.is_empty():
		var m := spawns[randi() % spawns.size()] as Node3D
		return m.global_position
	# No markers (headless / minimal map): split the teams across midfield.
	return Vector3(-12.0 if team == 0 else 12.0, 1.0, 0.0)


# --- per-frame (host timers, snapshots, HP sync) ------------------------------

func _process(delta: float) -> void:
	if not match_active:
		return
	if _using_nm():
		# Delegated mode: damage / respawn / puppet state ALL live in
		# NetManager. NetMatch runs only the match clock + our delayed
		# respawn request (we died -> ask the host for a respawn).
		if time_limit_seconds > 0.0:
			match_time_left -= delta
			if match_time_left <= 0.0:
				var w := -1
				if _team_scores[0] != _team_scores[1]:
					w = 0 if _team_scores[0] > _team_scores[1] else 1
				_finish_match(w, "time_limit")
				return
		if _local_respawn_t > 0.0:
			_local_respawn_t -= delta
			if _local_respawn_t <= 0.0:
				var nm := _nm()
				if nm != null and nm.has_method("request_respawn"):
					nm.call("request_respawn")
		return
	if multiplayer.is_server():
		# Time limit (host clock is the match clock).
		if time_limit_seconds > 0.0:
			match_time_left -= delta
			if match_time_left <= 0.0:
				var w := -1
				if _team_scores[0] != _team_scores[1]:
					w = 0 if _team_scores[0] > _team_scores[1] else 1
				_finish_match(w, "time_limit")
				return
		# Respawn timers.
		var done: Array = []
		for pid in _respawn_timers.keys():
			_respawn_timers[pid] = float(_respawn_timers[pid]) - delta
			if float(_respawn_timers[pid]) <= 0.0:
				done.append(pid)
		for pid in done:
			_respawn_timers.erase(pid)
			_respawn_player(int(pid))
		# Periodic full-HP sync (corrects local regen drift on victims).
		_hp_sync_t -= delta
		if _hp_sync_t <= 0.0:
			_hp_sync_t = HP_SYNC_INTERVAL
			var hp_map := {}
			for pid in _players.keys():
				hp_map[int(pid)] = float(_players[pid]["hp"])
			_broadcast("_rpc_sync_hp", [hp_map])
	# Puppet transform broadcast (every peer, 10 Hz, unreliable).
	_snap_t -= delta
	if _snap_t <= 0.0:
		_snap_t = SNAPSHOT_INTERVAL
		var p := _local_player()
		if p is Node3D:
			var rot_y := (p as Node3D).rotation.y
			_broadcast_unreliable("_rpc_puppet_state",
				[multiplayer.get_unique_id(),
				(p as Node3D).global_position, rot_y])


func _respawn_player(peer_id: int) -> void:
	# Host only. Called when the respawn timer expires.
	if not _players.has(peer_id) or not match_active:
		return
	var team := int(_players[peer_id]["team"])
	_players[peer_id]["hp"] = PLAYER_MAX_HP
	_players[peer_id]["alive"] = true
	if _scoreboard != null:
		_scoreboard.mark_alive(peer_id, true)
	var pos := _pick_spawn_pos(team)
	var puppet: Variant = _players[peer_id].get("puppet")
	if puppet is NetPuppet:
		(puppet as NetPuppet).apply_state(pos, 0.0, PLAYER_MAX_HP, true)
	if peer_id == multiplayer.get_unique_id():
		_respawn_local(pos)
	_broadcast("_rpc_respawn", [peer_id, pos])


# --- disconnects ---------------------------------------------------------------

func _on_peer_disconnected(peer_id: int) -> void:
	if not match_active:
		return
	if _using_nm():
		return  # Delegated mode: NetManager emits player_left /
		# server_disconnected; NetMatch reacts to those, never to the
		# raw peer signal (handling both would double-count leavers).
	if peer_id == 1 and not multiplayer.is_server():
		# Host left: the match cannot continue (no migration — the host
		# WAS the server). Report it as an ended match, reason host_left.
		match_active = false
		_result = {"winner_team": -2, "winner_name": "HOST LEFT",
			"draw": false, "team_scores": _team_scores.duplicate(),
			"mode": match_mode, "score_limit": score_limit,
			"reason": "host_left",
			"snapshot": _scoreboard.serialize() if _scoreboard != null else {},
			"rows": _scoreboard.get_rows_sorted() if _scoreboard != null else []}
		match_ended.emit(-2, _result)
		return
	if not multiplayer.is_server():
		return  # clients learn roster changes from the host broadcast
	if not _players.has(peer_id):
		return
	var puppet: Variant = _players[peer_id].get("puppet")
	if puppet is Node and is_instance_valid(puppet):
		(puppet as Node).queue_free()
	_players.erase(peer_id)
	_respawn_timers.erase(peer_id)
	if _scoreboard != null:
		# Rebuild the board without the leaver (snapshot, not a kill).
		var snap := _scoreboard.serialize()
		var kept: Array = []
		for entry in snap.get("players", []):
			if int(entry.get("peer_id", -1)) != peer_id:
				kept.append(entry)
		snap["players"] = kept
		_scoreboard.apply_snapshot(snap)
		_broadcast("_rpc_sync_scoreboard", [snap])
	# Forfeit: a team with no players left loses; < 2 players ends it.
	var remaining: Array[int] = []
	for pid in _players.keys():
		remaining.append(int(pid))
	if remaining.size() < 2:
		var w := -1
		if remaining.size() == 1:
			w = int(_players[remaining[0]]["team"])
		_finish_match(w, "forfeit")


# --- weapon helpers -------------------------------------------------------------

func _current_weapon_id(_peer_id: int) -> String:
	# Local shooter's current weapon (WeaponManager group, duck-typed).
	# Remote peers' weapons are not visible to the host; their clients
	# pass "" and the host falls back to the unknown-weapon cap.
	var wm := get_tree().get_first_node_in_group("weapon_manager")
	if wm != null and wm.has_method("current_weapon"):
		var w: Variant = wm.call("current_weapon")
		if w != null and (w as Object).get("weapon_id") != null:
			return str((w as Object).get("weapon_id"))
	return ""


var _arsenal_weapons_cache: Dictionary = {}
var _arsenal_weapons_loaded := false


## Arsenal is the single balance surface — but it is read through a
## runtime load() + get_script_constant_map() (the verify_content.gd
## pattern), NEVER a bare `Arsenal` identifier. A bare reference would
## drag weapon_base.gd (which names the Sfx autoload) into this script's
## compile, and autoload globals do not resolve at headless --script
## startup-compile time.
func _arsenal_weapons() -> Dictionary:
	if not _arsenal_weapons_loaded:
		_arsenal_weapons_loaded = true
		var script := load("res://scripts/weapons/arsenal.gd") as GDScript
		if script != null:
			_arsenal_weapons_cache = (
				script.get_script_constant_map().get("WEAPONS", {}) as Dictionary)
	return _arsenal_weapons_cache


func _weapon_damage_cap(weapon_id: String, headshot: bool) -> float:
	# A weapon's hits can never exceed its base damage x headshot
	# multiplier (falloff only lowers).
	var weapons := _arsenal_weapons()
	if not weapon_id.is_empty() and weapons.has(weapon_id):
		var stats: Dictionary = weapons[weapon_id]
		var base := float(stats.get("damage", 0.0))
		if headshot:
			base *= float(stats.get("headshot_mult", 1.0))
		return maxf(base, 1.0)
	return UNKNOWN_WEAPON_DAMAGE_CAP


func _weapon_display(weapon_id: String) -> String:
	var weapons := _arsenal_weapons()
	if not weapon_id.is_empty() and weapons.has(weapon_id):
		return str((weapons[weapon_id] as Dictionary).get("name", weapon_id))
	if weapon_id.is_empty():
		return "WEAPON"
	return weapon_id.to_upper()


# --- RPCs: server -> clients ---------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _rpc_begin_match(roster: Array, config: Dictionary) -> void:
	_ensure_scoreboard()
	_connect_nm_signals()
	match_mode = str(config.get("mode", "tdm"))
	score_limit = int(config.get("score_limit", DEFAULT_SCORE_LIMIT))
	time_limit_seconds = float(config.get("time_limit", 0.0))
	match_time_left = time_limit_seconds
	winner_team = -1
	_result = {}
	_team_scores = [0, 0]
	_respawn_timers.clear()
	_players.clear()
	for entry in roster:
		if not (entry is Dictionary):
			continue
		var pid := int(entry.get("peer_id", -1))
		if pid < 0:
			continue
		_players[pid] = {
			"name": str(entry.get("name", "PLAYER %d" % pid)),
			"team": clampi(int(entry.get("team", 0)), 0, 1),
			"hp": PLAYER_MAX_HP, "alive": true,
			"kills": 0, "deaths": 0, "puppet": null,
		}
	_apply_roster_local(roster)
	match_active = true
	_hook_local_player()
	match_started.emit(match_mode, score_limit)


@rpc("authority", "call_remote", "reliable")
func _rpc_damage_event(victim_id: int, hp: float, _attacker_id: int,
		_weapon_id: String, _headshot: bool) -> void:
	if _using_nm():
		return  # Delegated mode: NetManager owns damage broadcasts.
	_apply_damage(victim_id, hp, _attacker_id, _weapon_id, _headshot)


@rpc("authority", "call_remote", "reliable")
func _rpc_kill_event(killer_id: int, victim_id: int, weapon_id: String,
		headshot: bool) -> void:
	if _using_nm():
		return  # Delegated mode: NetManager owns kill broadcasts.
	_apply_kill(killer_id, victim_id, weapon_id, headshot)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_scoreboard(snapshot: Dictionary) -> void:
	if _using_nm():
		return  # Delegated mode: scores mirror NetManager signals.
	if _scoreboard != null:
		_scoreboard.apply_snapshot(snapshot)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_hp(hp_map: Dictionary) -> void:
	if _using_nm():
		return  # Delegated mode: NetManager owns HP.
	for key in hp_map.keys():
		var pid := int(key)
		var hp := float(hp_map[key])
		if _players.has(pid):
			_players[pid]["hp"] = hp
			var puppet: Variant = _players[pid].get("puppet")
			if puppet is NetPuppet:
				(puppet as NetPuppet).hp_mirror = hp
		if pid == multiplayer.get_unique_id():
			_converge_local_hp(hp)


@rpc("authority", "call_remote", "reliable")
func _rpc_respawn(peer_id: int, pos: Vector3) -> void:
	if _using_nm():
		return  # Delegated mode: NetManager owns respawns.
	if not _players.has(peer_id):
		return
	_players[peer_id]["hp"] = PLAYER_MAX_HP
	_players[peer_id]["alive"] = true
	if _scoreboard != null:
		_scoreboard.mark_alive(peer_id, true)
	var puppet: Variant = _players[peer_id].get("puppet")
	if puppet is NetPuppet:
		(puppet as NetPuppet).apply_state(pos, 0.0, PLAYER_MAX_HP, true)
	if peer_id == multiplayer.get_unique_id():
		_respawn_local(pos)


@rpc("authority", "call_remote", "reliable")
func _rpc_match_end(p_winner_team: int, result: Dictionary) -> void:
	match_active = false
	winner_team = p_winner_team
	_result = result
	if _scoreboard != null and result.has("snapshot"):
		_scoreboard.apply_snapshot(result["snapshot"])
	match_ended.emit(p_winner_team, result)
	# Goal 6 PROGRESSION: match-end XP for this peer (client path;
	# the host reports from _finish_match instead).
	if is_inside_tree() and multiplayer.has_multiplayer_peer():
		var prog := get_node_or_null("/root/Progression")
		if prog != null and prog.has_method("report_event"):
			var my_team := -1
			var my_id := multiplayer.get_unique_id()
			if _players.has(my_id):
				my_team = int(_players[my_id].get("team", -1))
			prog.call("report_event", "match_end", {
				"mode": match_mode,
				"won": p_winner_team >= 0 and my_team == p_winner_team,
				"draw": p_winner_team < 0,
				"score": 0})


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_puppet_state(peer_id: int, pos: Vector3, rot_y: float) -> void:
	# Trust the true sender, not the claimed id.
	_apply_puppet_state(multiplayer.get_remote_sender_id(), pos, rot_y)


## Apply a puppet transform. The headless verifier drives this directly
## (same code path the RPC wrapper uses) without a network.
func _apply_puppet_state(peer_id: int, pos: Vector3, rot_y: float) -> void:
	if not match_active or not _players.has(peer_id):
		return
	if peer_id == multiplayer.get_unique_id():
		return  # never puppet ourselves
	var puppet: Variant = _players[peer_id].get("puppet")
	if puppet is NetPuppet:
		var hp := float(_players[peer_id]["hp"])
		var alive := bool(_players[peer_id]["alive"])
		(puppet as NetPuppet).apply_state(pos, rot_y, hp, alive)


# --- broadcast helpers (skip RPCs when offline — headless tests drive the
# host functions directly, and rpc() on an offline peer is a no-op) ----------

func _net_connected() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer)


func _broadcast(method: String, args: Array) -> void:
	if not _net_connected():
		return
	match args.size():
		0:
			rpc(method)
		1:
			rpc(method, args[0])
		2:
			rpc(method, args[0], args[1])
		3:
			rpc(method, args[0], args[1], args[2])
		_:
			push_warning("NetMatch: broadcast %s has %d args (max 3)." % [method, args.size()])


func _broadcast_unreliable(method: String, args: Array) -> void:
	# Godot 4 has no rpc_unreliable(): reliability comes from the
	# target's @rpc("unreliable") annotation — plain rpc() honors it.
	if not _net_connected():
		return
	match args.size():
		0:
			rpc(method)
		1:
			rpc(method, args[0])
		2:
			rpc(method, args[0], args[1])
		3:
			rpc(method, args[0], args[1], args[2])
		_:
			push_warning("NetMatch: unreliable broadcast %s has %d args (max 3)." % [method, args.size()])


# --- queries for the lobby / result screen -------------------------------------

func get_result() -> Dictionary:
	return _result.duplicate(true)


func get_team_scores() -> Array[int]:
	return _team_scores.duplicate()


func get_local_team() -> int:
	var my_id := multiplayer.get_unique_id()
	if _players.has(my_id):
		return int(_players[my_id]["team"])
	return -1


func get_player_info(peer_id: int) -> Dictionary:
	if not _players.has(peer_id):
		return {}
	var d: Dictionary = (_players[peer_id] as Dictionary).duplicate()
	d.erase("puppet")
	return d


func get_match_state() -> Dictionary:
	return {
		"active": match_active,
		"mode": match_mode,
		"score_limit": score_limit,
		"time_left": match_time_left,
		"team_scores": _team_scores.duplicate(),
		"players": _players.size(),
		"winner_team": winner_team,
	}
