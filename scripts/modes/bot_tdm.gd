# FORGEFALL — Bot Team Deathmatch (Gameplay Rework, menu + TDM worker).
#
# Single Player TDM: the player + 2 allied bots (ALPHA) vs 3 enemy bots
# (BRAVO). First team to SCORE_LIMIT kills wins. Bots are BotFighter
# bodies (EnemyBase chassis + team logic); the player fights with the
# loadout they chose beforehand (weapons from Loadouts, exactly one
# traversal tool via the movement worker's set_traversal_tool()).
#
# Scoring is owned HERE, not by Game.register_kill(): bot deaths never
# touch the player's score/streak/killstreaks (BotFighter.die() skips
# that call). record_kill() is the one scoring path — kills with an
# unknown killer (environment, thorns edge cases) score nothing.
#
# Lifecycle: GameModeManager.start("tdm") adds this node and calls
# start(traversal). Main connects tdm_match_ended (forwarded through
# GameModeManager) to show the result and quit to menu. The player
# respawns like the bots (3 s) — TDM has no KIA / run-over state.
# Forge building is DISABLED in TDM: ForgeGate blocks the pipeline in
# a live "tdm" run, the HUD hides the Forge button, and Main never
# instances the Forge menu for this mode.
class_name BotTDM
extends Node

signal match_ended(winner_team: int, result: Dictionary)
signal kill_scored(killer_name: String, victim_name: String, killer_team: int, victim_team: int)

## First team to this many kills wins.
const SCORE_LIMIT := 25
## Redeploy delay for bots and the player.
const RESPAWN_DELAY := 3.0
## Squad sizes (player + ALLY_BOTS vs ENEMY_BOTS).
const ALLY_BOTS := 2
const ENEMY_BOTS := 3
## How long a bot's hit on the player still attributes a later death.
const PLAYER_HIT_ATTRIB_WINDOW := 5.0

const BOT_NAMES: Array[String] = ["VIPER", "GHOST", "HAVOC", "JACKAL", "ORION", "NOMAD"]
## Team ids: 0 = ALPHA (player side), 1 = BRAVO (enemy bots).
const TEAM_ALPHA := 0
const TEAM_BRAVO := 1

## The player is always ALPHA.
var player_team := TEAM_ALPHA
## Bots in this match (BotFighter bodies, both teams).
var bots: Array[BotFighter] = []
var team_scores := [0, 0]
var running := false
## The traversal choice this run started with (from the loadout).
var traversal_tool := "grapple"

var _respawns: Array = []  # {bot: BotFighter, t: float}
var _player_respawn_t := -1.0
var _last_player_attacker: Node = null
var _last_player_hit_t := -999.0
var _elapsed := 0.0


## Start the match. `traversal` is informational here (the player
## already got it via Main's set_traversal_tool() call); it is kept
## for state/reporting and the verifier.
func start(traversal: String = "grapple") -> bool:
	traversal_tool = traversal
	team_scores = [0, 0]
	_respawns.clear()
	_player_respawn_t = -1.0
	_last_player_attacker = null
	_last_player_hit_t = -999.0
	_elapsed = 0.0
	if Game.has_signal("player_died") and not Game.player_died.is_connected(_on_player_died):
		Game.player_died.connect(_on_player_died)
	_spawn_bots()
	running = true
	_announce("TEAM DEATHMATCH", "FIRST TO %d KILLS WINS — ALPHA VS BRAVO" % SCORE_LIMIT)
	return true


## Stop the match (quit to menu / mode stop). Bots freeze; the parent
## (GameModeManager / Main) frees this node with the run.
func stop() -> void:
	running = false
	if Game.has_signal("player_died") and Game.player_died.is_connected(_on_player_died):
		Game.player_died.disconnect(_on_player_died)
	for b in bots:
		if b != null and is_instance_valid(b):
			b.set_match_active(false)


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
				_respawn_bot(bot)
	if _player_respawn_t > 0.0:
		_player_respawn_t -= delta
		if _player_respawn_t <= 0.0:
			_do_player_respawn()


# --- Spawning ---------------------------------------------------------------

func _spawn_bots() -> void:
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	var player_pos := Vector3.ZERO
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		player_pos = (players[0] as Node3D).global_position
	var name_i := 0
	for i in ALLY_BOTS:
		var bot := BotFighter.new()
		bot.setup(BOT_NAMES[name_i % BOT_NAMES.size()], TEAM_ALPHA, self)
		name_i += 1
		add_child(bot)
		bots.append(bot)
		bot.activate(_near_spawn(spawns, player_pos), 1, {})
	for i in ENEMY_BOTS:
		var bot := BotFighter.new()
		bot.setup(BOT_NAMES[name_i % BOT_NAMES.size()], TEAM_BRAVO, self)
		name_i += 1
		add_child(bot)
		bots.append(bot)
		bot.activate(_far_spawn(spawns, player_pos), 1, {})


## Spawn closest to `from` (allies deploy near the player).
func _near_spawn(spawns: Array, from: Vector3) -> Vector3:
	if spawns.is_empty():
		return Vector3(randf_range(-6.0, 6.0), 1.0, randf_range(-6.0, 6.0))
	var best: Node3D = spawns[0]
	var best_d := INF
	for s in spawns:
		var d := (s as Node3D).global_position.distance_to(from)
		if d < best_d:
			best_d = d
			best = s as Node3D
	return best.global_position


## Spawn farthest from `from` (enemies deploy away from the player).
func _far_spawn(spawns: Array, from: Vector3) -> Vector3:
	if spawns.is_empty():
		return Vector3(randf_range(-24.0, 24.0), 1.0, randf_range(-24.0, 24.0))
	var best: Node3D = spawns[0]
	var best_d := -INF
	for s in spawns:
		var d := (s as Node3D).global_position.distance_to(from)
		if d > best_d:
			best_d = d
			best = s as Node3D
	return best.global_position


func _respawn_bot(bot: BotFighter) -> void:
	if not running:
		return
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	var player_pos := Vector3.ZERO
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		player_pos = (players[0] as Node3D).global_position
	var pos := _far_spawn(spawns, player_pos) if bot.team_id == TEAM_BRAVO \
		else _near_spawn(spawns, player_pos)
	bot.activate(pos, 1, {})


# --- Deaths + scoring --------------------------------------------------------

## EnemyBase.die() callback (parent hook): a bot died. Attribute the
## kill from the victim's last_attacker, score it, schedule respawn.
func on_enemy_died(bot: Node) -> void:
	if not running or bot == null or not is_instance_valid(bot):
		return
	var victim_team := int(bot.get("team_id"))
	var victim_name := str(bot.get("bot_name"))
	var killer_team := -1
	var killer_name := "?"
	var attacker: Node = bot.get("last_attacker")
	if attacker != null and is_instance_valid(attacker):
		if attacker is BotFighter:
			killer_team = int((attacker as BotFighter).team_id)
			killer_name = str((attacker as BotFighter).bot_name)
		elif (attacker as Node).is_in_group("player"):
			killer_team = player_team
			killer_name = "YOU"
	if killer_team >= 0:
		record_kill(killer_team, victim_team, killer_name, victim_name)
	if bot is BotFighter:
		_respawns.append({"bot": bot, "t": RESPAWN_DELAY})


## A bot hit the player: remember the shooter so a later player death
## attributes to them (player.take_damage() does not store attackers).
func note_player_damage(attacker_bot: Node) -> void:
	_last_player_attacker = attacker_bot
	_last_player_hit_t = _elapsed


func _on_player_died() -> void:
	if not running:
		return
	var killer_team := -1
	var killer_name := "?"
	if _last_player_attacker != null and is_instance_valid(_last_player_attacker) \
			and _elapsed - _last_player_hit_t <= PLAYER_HIT_ATTRIB_WINDOW:
		killer_team = int(_last_player_attacker.get("team_id"))
		killer_name = str(_last_player_attacker.get("bot_name"))
	if killer_team >= 0:
		record_kill(killer_team, player_team, killer_name, "YOU")
	_announce("K.I.A.", "REDEPLOYING IN %dS..." % int(RESPAWN_DELAY))
	_player_respawn_t = RESPAWN_DELAY


func _do_player_respawn() -> void:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var player: Node = players[0]
	if player == null or not is_instance_valid(player) or not player.has_method("respawn"):
		return
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	var pos := Vector3(0, 1.0, 0)
	if not spawns.is_empty():
		var m := spawns[randi() % spawns.size()] as Node3D
		pos = m.global_position
	player.call("respawn", pos)


## THE scoring path. Friendly kills (killer == victim team) score
## nothing. Reaching SCORE_LIMIT ends the match immediately.
func record_kill(killer_team: int, victim_team: int, killer_name: String, victim_name: String) -> void:
	if not running:
		return
	if killer_team == victim_team:
		return
	if killer_team < 0 or killer_team > 1:
		return
	team_scores[killer_team] += 1
	kill_scored.emit(killer_name, victim_name, killer_team, victim_team)
	# Kills go to the killfeed only — a centre-screen announce per kill
	# would spam the HUD. Match start / end get announces (below).
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("add_killfeed"):
			h.call("add_killfeed", "%s ▸ %s  (ALPHA %d — %d BRAVO)" % [killer_name, victim_name, team_scores[0], team_scores[1]])
	if team_scores[killer_team] >= SCORE_LIMIT:
		_end_match(killer_team)


func _end_match(winner_team: int) -> void:
	running = false
	for b in bots:
		if b != null and is_instance_valid(b):
			b.set_match_active(false)
	var winner := "ALPHA" if winner_team == TEAM_ALPHA else "BRAVO"
	_announce("%s WINS" % winner,
		"FINAL — ALPHA %d — %d BRAVO" % [team_scores[0], team_scores[1]])
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_2d"):
		sfx.call("play_2d", "killstreak_ready")
	if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("match_end", {"mode": "tdm", "won": winner_team == TEAM_ALPHA, "draw": false, "score": team_scores[0]})
	match_ended.emit(winner_team, {
		"team_scores": team_scores.duplicate(),
		"reason": "score_limit",
		"winner_team": winner_team,
	})


## State snapshot for verifiers / debug.
func get_state() -> Dictionary:
	var alive := 0
	for b in bots:
		if b != null and is_instance_valid(b) and bool(b.get("active")) and not bool(b.get("dead")):
			alive += 1
	return {
		"running": running,
		"team_scores": team_scores.duplicate(),
		"bots_total": bots.size(),
		"bots_alive": alive,
		"traversal_tool": traversal_tool,
	}


func _announce(title: String, subtitle: String) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("announce"):
			h.call("announce", title, subtitle)
		elif h.has_method("add_killfeed"):
			h.call("add_killfeed", "%s — %s" % [title, subtitle])
