# main.gd — FORGEFALL bootstrap: owns the MENU / PLAYING / PAUSED state machine.
# Purpose: the main scene's script. On boot it shows the main menu; start_game()
# (called by the menu UI, worker 6) swaps in the Dustline map; the `pause`
# input action toggles the pause menu. Everything is loaded by path and
# guarded with ResourceLoader.exists() so the game boots even while other
# workers' scenes are still being written.
# Connections: root of res://scenes/main.tscn (the project's main scene).
# Adds itself to group "game_root" so UI scripts can find it
# (get_tree().get_first_node_in_group("game_root")). Does NOT touch the Game
# autoload — game_state.gd is independent and boots on its own.
# NOTE for worker 6 (pause menu): when paused, get_tree().paused is true, so the
# pause menu scene root must have process_mode = PROCESS_MODE_WHEN_PAUSED.
extends Node

enum State { MENU, PLAYING, PAUSED }

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
# Map registry (Goal 3, Worker A): key -> scene + optional dressing-props
# scene. Dustline keeps its separate props scene; Foundry / Outpost carry
# their dressing inside their builders. Menu selection (main_menu.gd)
# calls set_selected_map(); start_game() loads the selected entry.
const MAPS := {
	"dustline": {"scene": "res://scenes/maps/dustline.tscn", "props": "res://scenes/maps/dustline_props.tscn"},
	"foundry": {"scene": "res://scenes/maps/foundry.tscn", "props": ""},
	"outpost": {"scene": "res://scenes/maps/outpost.tscn", "props": ""},
}
const MAP_SCENE := "res://scenes/maps/dustline.tscn"  # default; see selected_map_key
const PLAYER_SCENE := "res://scenes/player.tscn"
const PAUSE_SCENE := "res://scenes/ui/pause_menu.tscn"
const HUD_SCENE := "res://scenes/ui/hud.tscn"
const TOUCH_SCENE := "res://scenes/ui/touch_controls.tscn"
const PROPS_SCENE := "res://scenes/maps/dustline_props.tscn"
const FORGE_MENU_SCENE := "res://scenes/ui/forge_menu.tscn"
const MP_MENU_SCENE := "res://scenes/multiplayer_menu.tscn"
const MP_NET_MATCH_SCRIPT := "res://scripts/net/net_match.gd"
const MP_KILLFEED_SCRIPT := "res://scripts/ui/killfeed.gd"
const MP_SCORE_LIMIT := 25
const MP_HOST_START_DELAY := 0.75  # lets clients build NetMatch before begin

var selected_map_key: String = "dustline"

var state: int = State.MENU
var _menu: Node = null
var _pause_menu: Node = null
var _hud: Node = null
var _touch: Node = null
var _waves: WaveManager = null
var _modes: GameModeManager = null
# Goal 4 MULTIPLAYER: menu / match / killfeed nodes for a net match.
var _mp_menu: Node = null
var _net_match: Node = null
var _killfeed: Node = null
var _mp_result_label: Label = null
var _mp_waiting_for_players := false


func _ready() -> void:
	add_to_group("game_root")
	_show_menu()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and state != State.MENU:
		toggle_pause()


## Instantiates the main menu if its scene exists yet.
func _show_menu() -> void:
	if not ResourceLoader.exists(MENU_SCENE):
		push_warning("FORGEFALL: menu scene missing at %s — booting to empty root." % MENU_SCENE)
		return
	_menu = (load(MENU_SCENE) as PackedScene).instantiate()
	add_child(_menu)


## Called by the main menu map selector. Unknown keys are ignored (Dustline stays).
func set_selected_map(key: String) -> void:
	if MAPS.has(key):
		selected_map_key = key


## Called by the main menu ("Deploy" button). Frees the menu, loads the selected map.
func start_game() -> void:
	if state == State.PLAYING or state == State.PAUSED:
		return
	if _menu != null:
		_menu.queue_free()
		_menu = null
	var map_scene: String = MAPS[selected_map_key]["scene"]
	if not ResourceLoader.exists(map_scene):
		push_error("FORGEFALL: map scene missing at %s — cannot start game." % map_scene)
		return
	var game_map: Node = (load(map_scene) as PackedScene).instantiate()
	add_child(game_map)
	_wire_props(game_map)
	_wire_player(game_map)
	_wire_perf()
	_wire_hud()
	_wire_waves()
	_wire_modes()
	state = State.PLAYING


## Map dressing props: only maps with a props scene get one (Dustline).
## Foundry / Outpost carry their dressing inside their builders.
func _wire_props(game_map: Node) -> void:
	var props_scene: String = MAPS[selected_map_key]["props"]
	if props_scene.is_empty():
		return
	if not ResourceLoader.exists(props_scene):
		push_warning("FORGEFALL: props scene missing at %s — running without dressing." % props_scene)
		return
	var props: Node = (load(props_scene) as PackedScene).instantiate()
	game_map.add_child(props)


## Spawns the player at a random "player_spawn" marker inside the map.
## (2026-10-12 hotfix: the player was never instantiated, so no Camera3D ever
## entered the tree and the 3D viewport rendered black on device. The map's
## _ready() runs synchronously inside add_child(), so markers exist by now.)
func _wire_player(game_map: Node) -> void:
	if not ResourceLoader.exists(PLAYER_SCENE):
		push_error("FORGEFALL: player scene missing at %s — world will render black." % PLAYER_SCENE)
		return
	var player: Node3D = (load(PLAYER_SCENE) as PackedScene).instantiate()
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	if spawns.is_empty():
		push_warning("FORGEFALL: no player_spawn markers — spawning at origin.")
		player.position = Vector3(0, 1.0, 0)
	else:
		var m := spawns[randi() % spawns.size()] as Node3D
		player.position = m.global_position
	# Parented under the map so quit_to_menu() frees it with everything else.
	game_map.add_child(player)
	# Goal 6 PROGRESSION: equip the active persistent loadout (menu
	# picker / Forge tab share one store). Guarded: no Loadouts, no-op.
	# Runs for SP Deploy, MP matches, and puzzle chambers alike — every
	# peer equips its own active loadout.
	var lo := get_node_or_null("/root/Loadouts")
	if lo != null and lo.has_method("apply_active_to"):
		lo.call("apply_active_to", player.get_node_or_null("WeaponManager"))


## Perf tier detection (Android HIGH/MED/LOW, desktop quality).
func _wire_perf() -> void:
	var perf := PerfScaler.new()
	add_child(perf)
	perf.auto_detect()


## HUD + touch controls for the run. Touch layer self-hides on desktop.
func _wire_hud() -> void:
	if ResourceLoader.exists(HUD_SCENE):
		_hud = (load(HUD_SCENE) as PackedScene).instantiate()
		add_child(_hud)
	if ResourceLoader.exists(TOUCH_SCENE):
		_touch = (load(TOUCH_SCENE) as PackedScene).instantiate()
		add_child(_touch)
	if ResourceLoader.exists(FORGE_MENU_SCENE):
		# v0.5 Forge menu (B1): the HUD's forge_console toggle delegates
		# to it when present; the HUD's legacy panel is the fallback.
		var fm := (load(FORGE_MENU_SCENE) as PackedScene).instantiate()
		add_child(fm)


## Wave manager: added after the map so spawn markers exist, then the run starts.
func _wire_waves() -> void:
	_waves = WaveManager.new()
	add_child(_waves)
	_waves.start_run()


## Goal 3 CONTENT: game-mode manager. Added AFTER the waves so the mode's
## start() (which resets run state) runs last; the node is a child of Main
## so quit_to_menu() frees it (and its objective points) with the run.
func _wire_modes() -> void:
	_modes = GameModeManager.new()
	add_child(_modes)
	_modes.start(GameModeManager.selected_mode)


## Toggles pause; safe to call from the pause action or UI buttons.
func toggle_pause() -> void:
	if state == State.PLAYING:
		_pause_game()
	elif state == State.PAUSED:
		resume()


func _pause_game() -> void:
	if not ResourceLoader.exists(PAUSE_SCENE):
		push_warning("FORGEFALL: pause menu scene missing — pausing without UI.")
		get_tree().paused = true
		state = State.PAUSED
		return
	_pause_menu = (load(PAUSE_SCENE) as PackedScene).instantiate()
	add_child(_pause_menu)
	get_tree().paused = true
	state = State.PAUSED


## Called by the pause menu ("Resume" button) or the pause action.
func resume() -> void:
	if state != State.PAUSED:
		return
	if _pause_menu != null:
		_pause_menu.queue_free()
		_pause_menu = null
	get_tree().paused = false
	state = State.PLAYING


## Called by the main menu ("Quit to menu"). Unloads the map, rebuilds menu.
func quit_to_menu() -> void:
	get_tree().paused = false
	if _pause_menu != null:
		_pause_menu.queue_free()
		_pause_menu = null
	# Goal 4: leaving a net match (e.g. pause-menu Quit) must stop the
	# match layer BEFORE its node is freed, and close the network peer.
	_mp_waiting_for_players = false
	_disconnect_mp_wait()
	if _net_match != null and is_instance_valid(_net_match):
		if _net_match.has_method("stop_match"):
			_net_match.stop_match()
		_net_match = null
	_killfeed = null
	if _mp_result_label != null and is_instance_valid(_mp_result_label):
		_mp_result_label.queue_free()
		_mp_result_label = null
	var nm := get_node_or_null("/root/NetManager")
	if nm != null and nm.has_method("leave"):
		nm.call("leave")
	for child in get_children():
		# All children here are menu / map / pause-menu instances owned by Main.
		child.queue_free()
	state = State.MENU
	_show_menu()


# --- Goal 5 Worker B: PUZZLE CHAMBERS --------------------------------------
# Puzzle rooms (scripts/puzzles/) are NOT combat maps: they load without
# waves / game modes / enemies. Main owns the select screen + the run,
# like it owns the MP menu. quit_to_menu() already frees every child of
# Main, so leaving a puzzle run needs no extra teardown.
const PUZZLE_SELECT_SCRIPT := "res://scripts/puzzles/select_ui.gd"

var _puzzle_select: Node = null


## Called by the main menu ("PUZZLE CHAMBERS"). Hides the main menu;
## the select screen's Back returns to it.
func open_puzzle_select() -> void:
	if _menu != null:
		_menu.visible = false
	if _puzzle_select != null and is_instance_valid(_puzzle_select):
		return
	if not ResourceLoader.exists(PUZZLE_SELECT_SCRIPT):
		push_warning("FORGEFALL: puzzle select missing — cannot open puzzle chambers.")
		if _menu != null:
			_menu.visible = true
		return
	_puzzle_select = (load(PUZZLE_SELECT_SCRIPT) as GDScript).new()
	_puzzle_select.name = "PuzzleSelect"
	add_child(_puzzle_select)


func on_puzzle_select_back() -> void:
	if _puzzle_select != null:
		_puzzle_select.queue_free()
		_puzzle_select = null
	if _menu != null:
		_menu.visible = true


## Called by the room-select screen. Frees menu + select, loads the room
## script, spawns the player at its "player_spawn" marker, wires HUD.
## Unknown ids are ignored (select screen stays).
func start_puzzle(chamber_id: String) -> void:
	var info := CompletionStore.room_for_id(chamber_id)
	if info.is_empty():
		push_warning("FORGEFALL: unknown puzzle room '%s'." % chamber_id)
		return
	if state == State.PLAYING or state == State.PAUSED:
		return
	if _puzzle_select != null:
		_puzzle_select.queue_free()
		_puzzle_select = null
	if _menu != null:
		_menu.queue_free()
		_menu = null
	var script_path: String = str(info["script"])
	if not ResourceLoader.exists(script_path):
		push_error("FORGEFALL: puzzle room script missing at %s." % script_path)
		return
	var room: Node = (load(script_path) as GDScript).new()
	add_child(room)
	_wire_player(room)
	_wire_perf()
	_wire_hud()
	state = State.PLAYING


# --- Goal 4 MULTIPLAYER -----------------------------------------------------
# One wiring point: Main owns the MP menu, the NetMatch node, and the
# killfeed. NetManager (autoload) owns transport/damage/HP/scores; NetMatch
# (delegated mode) owns teams/score-limit/start/end. Single-player paths
# above are untouched — net matches load the map WITHOUT waves/modes
# (no AI enemies in TDM).

## Called by the main menu ("MULTIPLAYER"). Hides the main menu; the MP
## menu's Back returns to it. The network peer is owned by NetManager,
## never by the menu — freeing the menu must not close the peer.
func open_multiplayer_menu() -> void:
	if _menu != null:
		_menu.visible = false
	if _mp_menu != null and is_instance_valid(_mp_menu):
		return
	if not ResourceLoader.exists(MP_MENU_SCENE):
		push_warning("FORGEFALL: multiplayer menu scene missing — cannot open multiplayer.")
		if _menu != null:
			_menu.visible = true
		return
	_mp_menu = (load(MP_MENU_SCENE) as PackedScene).instantiate()
	_mp_menu.name = "MultiplayerMenu"  # RPC path must match on every peer
	add_child(_mp_menu)
	if _mp_menu.has_signal("back_requested"):
		_mp_menu.connect("back_requested", _on_mp_back)
	if _mp_menu.has_signal("start_match_requested"):
		_mp_menu.connect("start_match_requested", _on_mp_start)


func _on_mp_back() -> void:
	if _mp_menu != null:
		_mp_menu.queue_free()
		_mp_menu = null
	if _menu != null:
		_menu.visible = true


## Goal 6 PROGRESSION: stats screen. Hides the main menu; the screen's
## BACK (closed signal) returns to it. Mirrors open_multiplayer_menu.
func open_stats_screen() -> void:
	if _menu != null:
		_menu.visible = false
	var screen := StatsScreen.open_in(self)
	if screen != null and screen.has_signal("closed") \
			and not screen.is_connected("closed", _on_stats_closed):
		screen.connect("closed", _on_stats_closed)


func _on_stats_closed() -> void:
	if _menu != null:
		_menu.visible = true


## Menu start: host (button) and clients (menu RPC) converge here with the
## same map/mode. Builds the match scene on EVERY peer, then the host
## begins the match (delayed so clients have built their NetMatch first).
## mode_id is informational in v0.9.3: net matches are always TDM (the MP
## menu offers only TEAM DEATHMATCH; NetMatch refuses other modes).
func _on_mp_start(map_id: String, mode_id: String, is_host: bool) -> void:
	if _mp_menu != null:
		_mp_menu.queue_free()
		_mp_menu = null
	if _menu != null:
		_menu.queue_free()
		_menu = null
	set_selected_map(map_id)
	if state == State.PLAYING or state == State.PAUSED:
		return
	var map_scene: String = MAPS[selected_map_key]["scene"]
	if not ResourceLoader.exists(map_scene):
		push_error("FORGEFALL: map scene missing at %s — cannot start net match." % map_scene)
		return
	var game_map: Node = (load(map_scene) as PackedScene).instantiate()
	add_child(game_map)
	_wire_props(game_map)
	_wire_player(game_map)
	_wire_perf()
	_wire_hud()
	_wire_net_match()
	state = State.PLAYING
	# Forge batch: late-join Forge snapshot for peers that connected
	# before this map loaded (NetManager also snapshots on
	# peer_connected; this covers the host + already-connected peers).
	var nm2 := get_node_or_null("/root/NetManager")
	if nm2 != null and nm2.has_method("forge_request_resync"):
		nm2.call("forge_request_resync")
	if is_host:
		_maybe_host_begin_match()


## NetMatch + killfeed for a net match. NetMatch node is named "NetMatch"
## (RPC path must match on every peer); killfeed is a standalone Control.
func _wire_net_match() -> void:
	if ResourceLoader.exists(MP_NET_MATCH_SCRIPT):
		_net_match = (load(MP_NET_MATCH_SCRIPT) as GDScript).new()
		_net_match.name = "NetMatch"
		add_child(_net_match)
		if _net_match.has_signal("match_ended"):
			_net_match.connect("match_ended", _on_net_match_ended)
	if ResourceLoader.exists(MP_KILLFEED_SCRIPT):
		_killfeed = (load(MP_KILLFEED_SCRIPT) as GDScript).new()
		_killfeed.name = "NetKillfeed"
		add_child(_killfeed)
		if _net_match != null and _net_match.has_signal("kill_confirmed") and _killfeed.has_method("add_entry"):
			_net_match.connect("kill_confirmed", _killfeed.add_entry)


## Host: begin the match once >= 2 players are present. If the host
## started with only themselves in the lobby, wait for the second player
## (NetMatch refuses < 2) instead of failing the start.
func _maybe_host_begin_match() -> void:
	var nm := get_node_or_null("/root/NetManager")
	if nm == null or not nm.has_method("get_players"):
		push_warning("FORGEFALL: NetManager missing — cannot start net match.")
		_end_net_match_to_menu()
		return
	var count: int = (nm.call("get_players") as Dictionary).size()
	if count >= 2:
		await get_tree().create_timer(MP_HOST_START_DELAY).timeout
		_host_begin_match()
	else:
		_mp_waiting_for_players = true
		if nm.has_signal("player_joined") and not nm.is_connected("player_joined", _on_mp_player_joined):
			nm.connect("player_joined", _on_mp_player_joined)


func _on_mp_player_joined(_id: int, _name: String) -> void:
	if not _mp_waiting_for_players or state != State.PLAYING:
		return
	var nm := get_node_or_null("/root/NetManager")
	if nm == null:
		return
	if (nm.call("get_players") as Dictionary).size() >= 2:
		_mp_waiting_for_players = false
		_disconnect_mp_wait()
		await get_tree().create_timer(MP_HOST_START_DELAY).timeout
		_host_begin_match()


func _disconnect_mp_wait() -> void:
	var nm := get_node_or_null("/root/NetManager")
	if nm != null and nm.has_signal("player_joined") and nm.is_connected("player_joined", _on_mp_player_joined):
		nm.disconnect("player_joined", _on_mp_player_joined)


func _host_begin_match() -> void:
	if _net_match == null or not is_instance_valid(_net_match):
		return
	if state != State.PLAYING:
		return
	var nm := get_node_or_null("/root/NetManager")
	if nm == null:
		return
	var players: Dictionary = nm.call("get_players")
	var peer_ids: Array = players.keys()
	var names := {}
	for pid in peer_ids:
		names[int(pid)] = str(nm.call("get_player_name", int(pid)))
	var ok: bool = _net_match.call("start_match", peer_ids, names, "tdm", MP_SCORE_LIMIT, 0.0)
	if not ok:
		push_warning("FORGEFALL: NetMatch refused start — returning to menu.")
		_end_net_match_to_menu()


## Match over (host win/draw/forfeit, or host left): show the result
## briefly, then tear the match down back to the main menu.
func _on_net_match_ended(_winner_team: int, result: Dictionary) -> void:
	var text := "MATCH OVER"
	if str(result.get("reason", "")) == "host_left":
		text = "HOST LEFT"
	elif bool(result.get("draw", false)):
		text = "DRAW"
	elif result.has("winner_name"):
		text = str(result["winner_name"])
	var scores: Array = result.get("team_scores", [])
	if scores.size() >= 2:
		text += "\nALPHA %d  —  %d BRAVO" % [int(scores[0]), int(scores[1])]
	_show_mp_result(text)
	await get_tree().create_timer(4.0).timeout
	_end_net_match_to_menu()


func _show_mp_result(text: String) -> void:
	if _mp_result_label != null and is_instance_valid(_mp_result_label):
		_mp_result_label.queue_free()
	var label := Label.new()
	label.name = "NetMatchResult"
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.offset_left = -320
	label.offset_right = 320
	label.offset_top = -60
	label.offset_bottom = 60
	StencilStyle.apply_title(label, 44, StencilStyle.ORANGE, 4)
	add_child(label)
	_mp_result_label = label


## Tear a net match down: stop the match layer first (never free NetMatch
## with puppets still registered), close the peer, then quit to menu.
func _end_net_match_to_menu() -> void:
	_mp_waiting_for_players = false
	_disconnect_mp_wait()
	if _net_match != null and is_instance_valid(_net_match):
		if _net_match.has_method("stop_match"):
			_net_match.stop_match()
		_net_match = null
	_killfeed = null
	if _mp_result_label != null and is_instance_valid(_mp_result_label):
		_mp_result_label.queue_free()
		_mp_result_label = null
	var nm := get_node_or_null("/root/NetManager")
	if nm != null and nm.has_method("leave"):
		nm.call("leave")
	quit_to_menu()
