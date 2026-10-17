# FORGEFALL — Multiplayer modes (Gameplay Rework, MP worker).
#
# The multiplayer versions of the modes: co-op Tower Defense, co-op
# Zombies, and PvP TDM with bot fill. One node per match, owned by
# Main (child "MPModes", same path on every peer so the @rpc handlers
# below route). Main creates it in _on_mp_start(); headless verifiers
# drive start_mp() + the _rpc_* handlers directly (same code path the
# wire uses — the verify_g4_tdm pattern).
#
# WHAT IS SHARED vs WHAT IS LOCAL (read before extending):
# - SHARED (host-authoritative, replicated by the RPCs below): the TD
#   core HP / wave / phase (host TD instance is the truth); the
#   Zombies doors (host-validated purchase, every peer opens the same
#   door), downed/revive state (cross-peer revive), per-player points
#   (each peer is authoritative for its OWN points and broadcasts
#   them; the host validates door/revive purchases against that
#   mirror), owned perks (mirror), Mystery Box spot. Forge structures
#   in MP TD ride the existing NetForgeSync (host-authoritative).
# - LOCAL (per peer, NOT synced): the enemies / waves themselves.
#   WaveManager is local-only and there is no NetworkEnemy layer, so
#   each peer fights its own local horde on its own map copy; the
#   host's core / door / revive state is what keeps the two worlds
#   one match. Syncing enemy positions would fork the wave system —
#   deferred to a NetworkEnemy layer, not faked here.
# - TDM: real PvP runs through NetMatch / NetManager (delegated mode);
#   bots are LOCAL filler on every peer (they fight the local player
#   + each other). Bot kills count (bot kills are scored via
#   NetMatch.record_bot_kill); a real player killing a bot does NOT
#   score — bots are filler, not a farmable win condition. Bots never
#   target remote puppets (BotFighter only sees group "player" + the
#   local bots list), and bot kills are local to each peer's filler
#   simulation: the match winner still comes from the host's
#   NetMatch _finish_match broadcast. Player respawn stays with
#   NetManager / NetMatch (delegated mode), never with this node.
#
# FORGE: MPModes sets GameModeManager.live_mode for MP matches (the
# known gap — MP matches never ran through GameModeManager.start()).
# ForgeGate then gates MP matches exactly like SP runs: MP TD builds,
# MP TDM / MP Zombies are refused, including remote specs (NetForgeSync
# consults the same gate). stop_mp() clears live_mode.
#
# TRAVERSAL: MP TD / MP TDM get the same exactly-one traversal-tool
# choice as SP (TD pre-run setup / active loadout). At the player
# enforcement boundary the ids are player.gd's — "grapple" /
# "jetpack" / "portal". The Loadouts store is canonical "portal"
# since the v0.6.0 integration; normalize_traversal still accepts
# the legacy "portal_gun" id as an alias, never passing it to the
# player. MP Zombies keeps the SP toggle semantics: OFF = no tools,
# ON = all three allowed (the active tool is still exactly one).
#
# REGISTRATION: ensure_registered() flips mp_tower_defense /
# mp_zombies to implemented through GameModeManager.register_mode()
# (the registry contract). The main menu calls it when the mode
# select opens, so the entries read AVAILABLE with no menu change.
class_name MPModes
extends Node

signal mp_match_started(mode: String, peer_ids: Array)
signal mp_match_ended(mode: String, result: Dictionary)
signal mp_zombies_state_changed(state: Dictionary)
signal mp_td_core_changed(core_hp: float, core_max_hp: float)

const MP_MODES: Array[String] = ["mp_tower_defense", "mp_tdm", "mp_zombies"]
const TRAVERSAL_TOOLS: Array[String] = ["grapple", "jetpack", "portal"]
const BOT_TEAM_SIZE := 3  # bots fill each team up to this many combatants
const BOT_NAMES: Array[String] = ["VIPER", "GHOST", "HAVOC", "JACKAL", "ORION", "NOMAD"]
const BOT_RESPAWN_DELAY := 3.0
const PLAYER_HIT_ATTRIB_WINDOW := 5.0
const REVIVE_SHARE := 0.05  # 5% of the downed player's points (BO2 rule)

var mode: String = ""
var running := false
var is_host := false
var local_peer_id := -1
var peer_ids: Array = []
var peer_names := {}
var player_team := 0  # local player's team (BotFighter reads this)

var _teams := {}  # peer_id -> team (sorted ids, alternating — NetMatch parity)
var _td: TowerDefenseMode = null
var _zombies: ZombiesMode = null
var _last_td_core := -1.0
var _last_td_wave := -1
var _last_td_phase := ""
var _zombies_seed := -1
var _z_points := {}  # peer_id -> points mirror
var _z_doors := {}  # door_id -> true (open)
var _z_downed := {}  # peer_id -> bool
var _z_perks := {}  # peer_id -> Array[String] (mirror)
var _z_box_spot := 0
var _applying_zombies_state := false


func _ready() -> void:
	add_to_group("mp_modes")

## Bot fill (MP TDM): BotFighter bodies, both teams. BotFighter reads
## `bots` + `player_team` off this node (its tdm owner).
var bots: Array[BotFighter] = []
var bot_kills: Array[int] = [0, 0]  # local filler-simulation bot kills per team
var _respawns: Array = []  # {bot: BotFighter, t: float}
var _last_player_attacker: Node = null
var _last_player_hit_t := -999.0
var _elapsed := 0.0


# --- Registration / live mode ------------------------------------------------

## Flip the MP modes to implemented through the registry contract.
static func ensure_registered() -> bool:
	var ok := true
	ok = GameModeManager.register_mode("mp_tower_defense", true) and ok
	ok = GameModeManager.register_mode("mp_tdm", true) and ok
	ok = GameModeManager.register_mode("mp_zombies", true) and ok
	return ok


## MP matches never run through GameModeManager.start(): set the Forge
## gate's live mode directly. Also sets selected_mode so HUD/menu
## helpers that read it agree.
static func set_live_mode(mp_mode: String) -> void:
	GameModeManager.live_mode = mp_mode
	GameModeManager.selected_mode = mp_mode


## Clear live_mode, but only when it is an MP mode this layer owns —
## never clobber a live SP run.
static func clear_live_mode() -> void:
	if MP_MODES.has(GameModeManager.live_mode):
		GameModeManager.live_mode = ""


# --- Traversal (enforcement-side ids) ----------------------------------------

## The Loadouts store is canonical "portal" (v0.6.0 integration);
## the legacy "portal_gun" id is still accepted as an alias here
## so older saves / callers never pass an id the player rejects.
## Never pass "portal_gun" to set_traversal_tool() (it rejects it,
## and the allowed-set cleanup would silently drop the player to
## "none").
static func normalize_traversal(tool: String) -> String:
	match tool:
		"portal_gun", "portal":
			return "portal"
		"grapple", "jetpack", "none":
			return tool
		_:
			return "grapple"


## The exactly-one traversal choice for an MP mode: TD pre-run setup
## (TowerDefenseSetup), TDM active loadout. Zombies has no single
## choice (toggle semantics) -> "".
static func traversal_for_mode(mp_mode: String) -> String:
	match mp_mode:
		"mp_tower_defense":
			return normalize_traversal(TowerDefenseSetup.get_tool())
		"mp_tdm":
			var lo := _loadouts_autoload()
			if lo != null and lo.has_method("get_active_traversal"):
				return normalize_traversal(str(lo.call("get_active_traversal")))
			return "grapple"
		_:
			return ""


static func _loadouts_autoload() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Loadouts")
	return null


## Apply the mode's traversal choice to one player. TD/TDM: allowed
## set = [tool], selection = tool (exactly one, enforcement ids).
## Zombies: the SP toggle (OFF -> none, ON -> all three allowed).
## Returns false when the player has no traversal API.
static func apply_traversal(player: Node, mp_mode: String, tool: String = "") -> bool:
	if player == null or not is_instance_valid(player):
		return false
	if mp_mode == "mp_zombies":
		return ZombiesMode.apply_traversal_to_player(player)
	var t := normalize_traversal(tool) if not tool.is_empty() else traversal_for_mode(mp_mode)
	if not TRAVERSAL_TOOLS.has(t):
		return false
	# ORDER MATTERS (player.gd contract): allowed set first, then the
	# selection — selecting first would be rejected against a stale set.
	if player.has_method("set_allowed_traversal_tools"):
		player.call("set_allowed_traversal_tools", [t])
	if player.has_method("set_traversal_tool"):
		return bool(player.call("set_traversal_tool", t))
	return false


## Apply the mode's traversal choice to every local player body.
func apply_traversal_to_players(mp_mode: String, tool: String = "") -> int:
	if not is_inside_tree():
		return 0
	var n := 0
	for p in get_tree().get_nodes_in_group("player"):
		if apply_traversal(p, mp_mode, tool):
			n += 1
	return n


# --- Match lifecycle -----------------------------------------------------------

## Start an MP match. `peer_ids` includes every peer (host + clients);
## `local_peer_id` < 0 = read multiplayer.get_unique_id() (verifiers
## pass it explicitly — two MPModes in one tree share one peer id).
## Returns false for unknown modes / empty rosters / double start.
func start_mp(mp_mode: String, p_peer_ids: Array, p_names: Dictionary,
		p_is_host: bool, p_local_peer_id: int = -1, traversal: String = "") -> bool:
	if running:
		push_warning("MPModes: match already running.")
		return false
	if not MP_MODES.has(mp_mode):
		push_warning("MPModes: mode '%s' is not an MP mode." % mp_mode)
		return false
	if p_peer_ids.is_empty():
		push_warning("MPModes: need at least 1 peer.")
		return false
	ensure_registered()
	mode = mp_mode
	is_host = p_is_host
	peer_ids = p_peer_ids.duplicate()
	peer_names = p_names.duplicate(true)
	local_peer_id = p_local_peer_id if p_local_peer_id >= 0 else multiplayer.get_unique_id()
	_elapsed = 0.0
	_teams.clear()
	var sorted_ids := peer_ids.duplicate()
	sorted_ids.sort()
	var counts := [0, 0]
	for pid in sorted_ids:
		var team := 0 if counts[0] <= counts[1] else 1
		counts[team] += 1
		_teams[int(pid)] = team
	player_team = int(_teams.get(local_peer_id, 0))
	set_live_mode(mode)
	_z_points.clear()
	_z_doors.clear()
	_z_downed.clear()
	_z_perks.clear()
	for pid in peer_ids:
		_z_points[int(pid)] = 0
		_z_downed[int(pid)] = false
		_z_perks[int(pid)] = []
	match mp_mode:
		"mp_tower_defense":
			_td = TowerDefenseMode.new()
			add_child(_td)
			_last_td_core = _td.core_hp
			_last_td_wave = _td.wave
			_last_td_phase = str(_td.phase)
			apply_traversal_to_players(mode, traversal)
			if _td.has_signal("tower_defense_over") and not _td.is_connected("tower_defense_over", _on_td_over):
				_td.connect("tower_defense_over", _on_td_over)
		"mp_zombies":
			_zombies = ZombiesMode.new()
			add_child(_zombies)
			_zombies.set_player_count(maxi(1, peer_ids.size()))
			_connect_zombies_signals()
			if is_host:
				_zombies_seed = RandomNumberGenerator.new().randi() % 1000000
				_zombies.start_run(_zombies_seed)
				_broadcast("_rpc_zombies_seed", [_zombies_seed])
			apply_traversal_to_players(mode, traversal)
		"mp_tdm":
			apply_traversal_to_players(mode, traversal)
			spawn_mp_bots()
			if Game.has_signal("player_died") and not Game.player_died.is_connected(_on_player_died):
				Game.player_died.connect(_on_player_died)
	running = true
	_connect_peer_joined()
	mp_match_started.emit(mode, peer_ids.duplicate())
	return true


## Stop the match: free the mode children + bots, clear live_mode.
func stop_mp() -> void:
	running = false
	_disconnect_peer_joined()
	if Game.has_signal("player_died") and Game.player_died.is_connected(_on_player_died):
		Game.player_died.disconnect(_on_player_died)
	_respawns.clear()
	for b in bots:
		if b != null and is_instance_valid(b):
			(b as Node).free()
	bots.clear()
	bot_kills = [0, 0]
	if _td != null and is_instance_valid(_td):
		_td.free()
	_td = null
	if _zombies != null and is_instance_valid(_zombies):
		_zombies.free()
	_zombies = null
	if GameModeManager.live_mode == mode:
		GameModeManager.live_mode = ""
	mode = ""


func _exit_tree() -> void:
	_disconnect_peer_joined()
	if mode != "" and GameModeManager.live_mode == mode:
		GameModeManager.live_mode = ""


## Host: a peer joined mid-match (co-op TD / Zombies — TDM rosters
## are fixed at NetMatch start, so this only ever fires for co-op).
## The joiner gets a team + a fresh points/downed/perks mirror entry;
## their Zombies door/perk state arrives via the host's next
## broadcasts. Bots are NOT respawned/removed for a late joiner.
func _connect_peer_joined() -> void:
	if not is_host:
		return
	var nm := _net_manager_node()
	if nm != null and nm.has_signal("player_joined") \
			and not nm.is_connected("player_joined", _on_mp_peer_joined):
		nm.connect("player_joined", _on_mp_peer_joined)


func _disconnect_peer_joined() -> void:
	var nm := _net_manager_node()
	if nm != null and nm.has_signal("player_joined") \
			and nm.is_connected("player_joined", _on_mp_peer_joined):
		nm.disconnect("player_joined", _on_mp_peer_joined)


func _net_manager_node() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("NetManager")


func _on_mp_peer_joined(peer_id: int, _player_name: String) -> void:
	if not running or not is_host or peer_ids.has(peer_id):
		return
	peer_ids.append(peer_id)
	peer_names[peer_id] = _player_name
	var counts := [0, 0]
	for pid in peer_ids:
		if pid != peer_id:
			counts[int(_teams.get(int(pid), 0))] += 1
	_teams[peer_id] = 0 if counts[0] <= counts[1] else 1
	_z_points[peer_id] = 0
	_z_downed[peer_id] = false
	_z_perks[peer_id] = []
	if _zombies != null:
		_zombies.set_player_count(maxi(1, peer_ids.size()))


func get_local_team() -> int:
	return player_team


func get_team_for(peer_id: int) -> int:
	return int(_teams.get(peer_id, -1))


# --- TD co-op ------------------------------------------------------------------

func _on_td_over(waves_survived: int, score: int) -> void:
	mp_match_ended.emit(mode, {"waves_survived": waves_survived, "score": score, "reason": "core_destroyed"})


## Host core snapshot for the wire / verifiers.
func td_state_snapshot() -> Dictionary:
	if _td == null:
		return {}
	return {"core_hp": float(_td.core_hp), "core_max_hp": float(TowerDefenseMode.CORE_MAX_HP),
		"wave": int(_td.wave), "phase": str(_td.phase)}


func _maybe_broadcast_td() -> void:
	if not is_host or _td == null:
		return
	if float(_td.core_hp) != _last_td_core or int(_td.wave) != _last_td_wave \
			or str(_td.phase) != _last_td_phase:
		_last_td_core = float(_td.core_hp)
		_last_td_wave = int(_td.wave)
		_last_td_phase = str(_td.phase)
		_broadcast("_rpc_td_core", [float(_td.core_hp), int(_td.wave), str(_td.phase)])


@rpc("authority", "call_remote", "reliable")
func _rpc_td_core(core_hp: float, wave: int, phase: String) -> void:
	if not running or _td == null:
		return
	_td.core_hp = clampf(core_hp, 0.0, float(TowerDefenseMode.CORE_MAX_HP))
	_td.wave = wave
	_td.phase = phase
	if _td.has_method("_update_core_visual"):
		_td.call("_update_core_visual")
	if _td.has_method("_update_chip"):
		_td.call("_update_chip")
	mp_td_core_changed.emit(float(_td.core_hp), float(TowerDefenseMode.CORE_MAX_HP))


# --- Zombies co-op ---------------------------------------------------------------

func _connect_zombies_signals() -> void:
	if _zombies == null:
		return
	if _zombies.has_signal("points_changed") and not _zombies.is_connected("points_changed", _on_z_points):
		_zombies.connect("points_changed", _on_z_points)
	if _zombies.has_signal("player_downed") and not _zombies.is_connected("player_downed", _on_z_downed):
		_zombies.connect("player_downed", _on_z_downed)
	if _zombies.has_signal("perk_bought") and not _zombies.is_connected("perk_bought", _on_z_perk):
		_zombies.connect("perk_bought", _on_z_perk)
	if _zombies.has_signal("box_moved") and not _zombies.is_connected("box_moved", _on_z_box):
		_zombies.connect("box_moved", _on_z_box)
	if _zombies.has_signal("door_opened") and not _zombies.is_connected("door_opened", _on_z_door_opened):
		_zombies.connect("door_opened", _on_z_door_opened)


## Host's own local door buy (ZombiesMode.buy_door, SP path): the
## door already opened + points already spent locally — mirror the
## door and broadcast it so clients open the same door. Client
## buys never reach here (ZombiesMode forwards them to the host);
## host-applied requests run under _applying_zombies_state.
func _on_z_door_opened(door_id: String) -> void:
	if _applying_zombies_state or not is_host:
		return
	if bool(_z_doors.get(door_id, false)):
		return
	_z_doors[door_id] = true
	_broadcast("_rpc_zombies_door", [door_id, local_peer_id, int(_z_points.get(local_peer_id, 0))])
	mp_zombies_state_changed.emit(zombies_state_snapshot())


## Buy a door through the co-op layer (the path ZombiesMode.buy_door
## forwards MP clients to, and the path a revive/door HUD button
## calls). Host: validate + apply + broadcast (same path as a client
## request). Client: ask the host (sender = buyer).
func request_door(door_id: String) -> void:
	if not running or mode != "mp_zombies":
		return
	if is_host:
		_rpc_zombies_request_door(door_id, local_peer_id)
	elif _net_connected():
		rpc_id(1, "_rpc_zombies_request_door", door_id)


## Ask the host to revive `downed_peer` (the reviver is the caller).
## Host validates (downed, reviver up) + broadcasts the revive.
func request_revive(downed_peer: int) -> void:
	if not running or mode != "mp_zombies":
		return
	if is_host:
		_rpc_zombies_request_revive(downed_peer, local_peer_id)
	elif _net_connected():
		rpc_id(1, "_rpc_zombies_request_revive", downed_peer)


## Local ZombiesMode player id for a peer: the local player is 0 in
## the local instance; every other peer keeps its peer id.
func _z_player_id(peer_id: int) -> int:
	return 0 if peer_id == local_peer_id else peer_id


## Local gameplay awarded the LOCAL player points (player_id 0 in the
## local instance): mirror + broadcast as our own points. Mirror
## entries (player_id != 0) are network-applied — never rebroadcast
## (that would ping-pong). The mirror comparison also kills the
## echo when a network apply lands on entry 0.
func _on_z_points(player_id: int, points: int) -> void:
	if _applying_zombies_state or player_id != 0:
		return
	if int(_z_points.get(local_peer_id, -1)) == points:
		return
	_z_points[local_peer_id] = points
	_broadcast("_rpc_zombies_points", [local_peer_id, points])


func _on_z_downed(player_id: int) -> void:
	if _applying_zombies_state or player_id != 0:
		return
	if bool(_z_downed.get(local_peer_id, false)):
		return
	_z_downed[local_peer_id] = true
	_broadcast("_rpc_zombies_downed", [local_peer_id])


func _on_z_perk(player_id: int, _perk_id: String) -> void:
	if _applying_zombies_state or player_id != 0 or _zombies == null:
		return
	_z_perks[local_peer_id] = _zombies.owned_perks(0)
	_broadcast("_rpc_zombies_perks", [local_peer_id, (_z_perks[local_peer_id] as Array).duplicate()])


func _on_z_box(spot_index: int) -> void:
	if _applying_zombies_state:
		return
	if _z_box_spot == spot_index:
		return
	_z_box_spot = spot_index
	_broadcast("_rpc_zombies_box", [spot_index])


## Full co-op snapshot for verifiers / debug.
func zombies_state_snapshot() -> Dictionary:
	return {
		"points": _z_points.duplicate(),
		"doors": _z_doors.duplicate(),
		"downed": _z_downed.duplicate(),
		"perks": _z_perks.duplicate(true),
		"box_spot": _z_box_spot,
		"seed": _zombies_seed,
	}


func _sender_or(arg_peer: int) -> int:
	var sender := multiplayer.get_remote_sender_id()
	return sender if sender > 0 else arg_peer


@rpc("authority", "call_remote", "reliable")
func _rpc_zombies_seed(seed: int) -> void:
	_zombies_seed = seed
	if _zombies != null:
		_zombies.start_run(seed)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_zombies_points(peer_id: int, points: int) -> void:
	var sender := _sender_or(peer_id)
	if sender != peer_id:
		return  # a peer may only report its OWN points
	if int(_z_points.get(peer_id, -1)) == points:
		return
	_z_points[peer_id] = points
	if _zombies != null:
		_applying_zombies_state = true
		_zombies.mp_set_points(_z_player_id(peer_id), points)
		_applying_zombies_state = false
	mp_zombies_state_changed.emit(zombies_state_snapshot())


@rpc("any_peer", "call_remote", "reliable")
func _rpc_zombies_downed(peer_id: int) -> void:
	var sender := _sender_or(peer_id)
	if sender != peer_id:
		return
	if bool(_z_downed.get(peer_id, false)):
		return
	_z_downed[peer_id] = true
	if _zombies != null:
		_applying_zombies_state = true
		_zombies.mp_set_downed(_z_player_id(peer_id), true)
		_applying_zombies_state = false
	mp_zombies_state_changed.emit(zombies_state_snapshot())


@rpc("any_peer", "call_remote", "reliable")
func _rpc_zombies_request_door(door_id: String, buyer_peer: int = -1) -> void:
	if not is_host or not running or _zombies == null:
		return
	var buyer := _sender_or(buyer_peer)
	if buyer < 0:
		return
	if bool(_z_doors.get(door_id, false)) or _zombies.is_door_open(door_id):
		return  # already open (mirror + local agree)
	var cost := _zombies.door_cost(door_id)
	if cost <= 0:
		return  # unknown door
	if int(_z_points.get(buyer, 0)) < cost:
		return  # cannot afford
	var after := int(_z_points.get(buyer, 0)) - cost
	_apply_zombies_door(door_id, buyer, after)
	_broadcast("_rpc_zombies_door", [door_id, buyer, after])


func _apply_zombies_door(door_id: String, buyer: int, buyer_points_after: int) -> void:
	_z_doors[door_id] = true
	_z_points[buyer] = buyer_points_after
	if _zombies != null:
		_applying_zombies_state = true
		_zombies.mp_open_door(door_id)
		_zombies.mp_set_points(_z_player_id(buyer), buyer_points_after)
		_applying_zombies_state = false
	mp_zombies_state_changed.emit(zombies_state_snapshot())


@rpc("authority", "call_remote", "reliable")
func _rpc_zombies_door(door_id: String, buyer: int, buyer_points_after: int) -> void:
	if bool(_z_doors.get(door_id, false)):
		return  # already applied
	_apply_zombies_door(door_id, buyer, buyer_points_after)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_zombies_request_revive(downed_peer: int, reviver_peer: int = -1) -> void:
	if not is_host or not running:
		return
	var reviver := _sender_or(reviver_peer)
	if reviver < 0 or reviver == downed_peer:
		return
	if not bool(_z_downed.get(downed_peer, false)):
		return  # not downed
	if bool(_z_downed.get(reviver, false)):
		return  # downed players cannot revive
	var awarded := int(int(_z_points.get(downed_peer, 0)) * REVIVE_SHARE)
	var after := int(_z_points.get(reviver, 0)) + awarded
	_apply_zombies_revive(reviver, downed_peer, after)
	_broadcast("_rpc_zombies_revived", [reviver, downed_peer, after])


func _apply_zombies_revive(reviver: int, downed_peer: int, reviver_points_after: int) -> void:
	_z_downed[downed_peer] = false
	_z_points[reviver] = reviver_points_after
	if _zombies != null:
		_applying_zombies_state = true
		_zombies.mp_set_downed(_z_player_id(downed_peer), false)
		_zombies.mp_set_points(_z_player_id(reviver), reviver_points_after)
		_applying_zombies_state = false
	if downed_peer == local_peer_id:
		_respawn_local_player()
	mp_zombies_state_changed.emit(zombies_state_snapshot())


@rpc("authority", "call_remote", "reliable")
func _rpc_zombies_revived(reviver: int, downed_peer: int, reviver_points_after: int) -> void:
	if not bool(_z_downed.get(downed_peer, false)):
		return  # already applied
	_apply_zombies_revive(reviver, downed_peer, reviver_points_after)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_zombies_perks(peer_id: int, perks: Array) -> void:
	var sender := _sender_or(peer_id)
	if sender != peer_id:
		return
	_z_perks[peer_id] = perks.duplicate()
	mp_zombies_state_changed.emit(zombies_state_snapshot())


@rpc("any_peer", "call_remote", "reliable")
func _rpc_zombies_box(spot_index: int) -> void:
	if _z_box_spot == spot_index:
		return
	_z_box_spot = spot_index
	if _zombies != null:
		_zombies.mp_set_box_spot(spot_index)


func _respawn_local_player() -> void:
	if not is_inside_tree():
		return
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return
	var p: Node = ps[0]
	if p != null and is_instance_valid(p) and p.has_method("respawn") and p is Node3D:
		p.call("respawn", (p as Node3D).global_position)


# --- TDM PvP + bots ---------------------------------------------------------------

## Fill each team up to BOT_TEAM_SIZE combatants with BotFighter
## bodies (the SP BotTDM pattern: setup + add_child + activate).
## Returns the number of bots spawned on this peer.
func spawn_mp_bots() -> int:
	if not is_inside_tree():
		return 0
	var counts := [0, 0]
	for pid in peer_ids:
		counts[int(_teams.get(int(pid), 0))] += 1
	var name_i := 0
	for team in 2:
		var need := maxi(0, BOT_TEAM_SIZE - counts[team])
		for _i in need:
			var bot := BotFighter.new()
			bot.setup(BOT_NAMES[name_i % BOT_NAMES.size()], team, self)
			name_i += 1
			add_child(bot)
			bots.append(bot)
			bot.activate(_bot_spawn_pos(team), 1, {})
	return bots.size()


func _bot_spawn_pos(team: int) -> Vector3:
	if is_inside_tree():
		var spawns := get_tree().get_nodes_in_group("player_spawn")
		if not spawns.is_empty():
			var m := spawns[randi() % spawns.size()] as Node3D
			return m.global_position
	return Vector3(-12.0 if team == 0 else 12.0, 1.0, 0.0)


## BotFighter.die() callback (parent hook, BotTDM parity): attribute
## the kill from the victim's last_attacker, score BOT kills, and
## schedule the respawn. A real player killing a bot scores nothing
## (filler, not a farmable win condition).
func on_enemy_died(bot: Node) -> void:
	if not running or mode != "mp_tdm" or bot == null or not is_instance_valid(bot):
		return
	var victim_team := int(bot.get("team_id"))
	var victim_name := str(bot.get("bot_name"))
	var attacker: Node = bot.get("last_attacker")
	if attacker != null and is_instance_valid(attacker):
		if attacker is BotFighter:
			var killer_team := int((attacker as BotFighter).team_id)
			var killer_name := str((attacker as BotFighter).bot_name)
			_record_bot_kill(killer_team, victim_team, killer_name, victim_name)
	if bot is BotFighter:
		_respawns.append({"bot": bot, "t": BOT_RESPAWN_DELAY})


## A bot hit the local player: remember the shooter for death
## attribution (player.take_damage() stores no attacker).
func note_player_damage(attacker_bot: Node) -> void:
	_last_player_attacker = attacker_bot
	_last_player_hit_t = _elapsed


func _on_player_died() -> void:
	if not running or mode != "mp_tdm":
		return
	if _last_player_attacker != null and is_instance_valid(_last_player_attacker) \
			and _elapsed - _last_player_hit_t <= PLAYER_HIT_ATTRIB_WINDOW:
		var killer_team := int(_last_player_attacker.get("team_id"))
		var killer_name := str(_last_player_attacker.get("bot_name"))
		_record_bot_kill(killer_team, player_team, killer_name, "YOU")


## Bot-kill scoring: local filler mirror + the NetMatch match layer
## when one is wired (Main adds NetMatch as a sibling). Friendly bot
## kills score nothing.
func _record_bot_kill(killer_team: int, victim_team: int, killer_name: String, victim_name: String) -> void:
	if killer_team == victim_team or killer_team < 0 or killer_team > 1:
		return
	var nm := _net_match()
	if nm != null:
		# A wired NetMatch owns the match clock: filler kills before
		# it starts (lobby / host-start delay) never count.
		if not bool(nm.get("match_active")):
			return
		bot_kills[killer_team] += 1
		if nm.has_method("record_bot_kill"):
			nm.call("record_bot_kill", killer_team, victim_team, killer_name, victim_name)
	else:
		bot_kills[killer_team] += 1


func _net_match() -> Node:
	if not is_inside_tree():
		return null
	var p := get_parent()
	if p != null:
		var sib := p.get_node_or_null("NetMatch")
		if sib != null:
			return sib
	return get_tree().root.get_node_or_null("NetMatch")


# --- per-frame ---------------------------------------------------------------------

func _process(delta: float) -> void:
	if not running:
		return
	_elapsed += delta
	for i in range(_respawns.size() - 1, -1, -1):
		var entry: Dictionary = _respawns[i]
		entry["t"] = float(entry["t"]) - delta
		if float(entry["t"]) <= 0.0:
			_respawns.remove_at(i)
			var bot: BotFighter = entry["bot"]
			if bot != null and is_instance_valid(bot):
				bot.activate(_bot_spawn_pos(int(bot.team_id)), 1, {})
	_maybe_broadcast_td()


# --- RPC plumbing --------------------------------------------------------------------

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
			push_warning("MPModes: broadcast %s has %d args (max 3)." % [method, args.size()])
