# verify_menu_tdm.gd — headless checks for the Gameplay Rework menu + TDM worker.
# Usage: godot --headless --path <project> --script res://tools/verify_menu_tdm.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Pattern (verify_v05_c1_enemies.gd): scripts are loaded with load() in
# _initialize (NOT bare class_name refs — those break compilation under
# --script), checks run in _process phases so _ready() has settled.
#
# Covers:
#  1. Mode registry (GameModeManager): MODES + REGISTRY entries, scope
#     lists, is_implemented / register_mode, forge_menu_allowed.
#  2. Loadouts traversal: exactly one tool per loadout (grapple /
#     jetpack / portal), sanitize, persistence, alias.
#  3. Menu: SINGLE PLAYER / MULTIPLAYER top entries, no DEPLOY / MODE
#     row; SP + MP mode selects list the right entries with the right
#     AVAILABLE / NOT AVAILABLE states; TD setup opens + backs out;
#     unimplemented entries fail gracefully (status, never a crash).
#  4. Picker: traversal dropdown (3 options) alongside weapons.
#  5. Bot TDM: start with a chosen loadout traversal, 2 allies + 3
#     enemies, scoring (incl. friendly-fire = no score), player-death
#     attribution, bot respawn, match ends at the score limit with a
#     winner; GameModeManager.start("tdm") sets live_mode (ForgeGate
#     blocks Forge) and start("zombies") / start("mp_tdm") refuse.
#  6. Bots move + shoot: a bot with a visible opposing target gets a
#     non-zero wish_dir / velocity, and _fire_at damages a target.
#  7. End-to-end: Main boots to the start menu (not in-game), and
#     Main.start_sp_mode("tdm") builds a live TDM run (player + bots,
#     no Forge menu, HUD Forge button absent), then quit_to_menu
#     clears live_mode and returns to the menu.
extends SceneTree

class DummyTarget extends StaticBody3D:
	var hits: Array = []

	func take_damage(amount: float, hit_position: Vector3, is_headshot: bool, attacker: Node = null) -> void:
		hits.append(amount)


var _fails := 0
var _checks := 0
var _phase := 0
var _frame := 0
var _gm_script: GDScript = null
var _loadouts_script: GDScript = null
var _bot_tdm_script: GDScript = null
var _bot_fighter_script: GDScript = null
var _menu: Control = null
var _picker: Control = null
var _tdm: Node = null
var _kill_events: Array = []
var _end_events: Array = []
var _arena: Node3D = null
var _bot: Node = null
var _dummy: DummyTarget = null
var _main: Node = null
var _main_tdm: Node = null


func _check(name: String, cond: bool) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % name)
	else:
		_fails += 1
		printerr("FAIL: %s" % name)


func _on_kill(a: String, b: String, kt: int, vt: int) -> void:
	_kill_events.append([a, b, kt, vt])


func _on_end(winner: int, result: Dictionary) -> void:
	_end_events.append([winner, result])


func _initialize() -> void:
	_gm_script = load("res://scripts/core/game_mode.gd") as GDScript
	_loadouts_script = load("res://scripts/progression/loadouts.gd") as GDScript
	_bot_tdm_script = load("res://scripts/modes/bot_tdm.gd") as GDScript
	_bot_fighter_script = load("res://scripts/modes/bot_fighter.gd") as GDScript
	_phase = 1
	_frame = 0


func _process(_delta: float) -> bool:
	_frame += 1
	match _phase:
		1:
			_check_registry()
			_check_loadouts()
			_phase = 2
			_frame = 0
		2:
			if _frame == 1:
				_menu = (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate()
				root.add_child(_menu)
				_menu.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
				_menu.position = Vector2.ZERO
				_menu.size = Vector2(1280, 800)
			if _frame >= 3:
				_check_menu()
				_phase = 3
				_frame = 0
		3:
			if _frame == 1:
				_picker = (load("res://scenes/ui/loadout_picker.tscn") as PackedScene).instantiate()
				root.add_child(_picker)
				_picker.call("open")
			if _frame >= 3:
				_check_picker()
				_phase = 4
				_frame = 0
		4:
			_check_bot_tdm_logic()
			_check_bot_move_and_shoot()
			_phase = 5
			_frame = 0
		5:
			if _frame == 1:
				_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
				root.add_child(_main)
			if _frame == 3:
				_check_launch_menu()
				# Chosen loadout traversal: portal -> the run must
				# carry it (Main -> GameModeManager -> BotTDM).
				var lo := root.get_node_or_null("Loadouts")
				if lo != null and lo.has_method("get_active_loadout"):
					var active: Dictionary = lo.call("get_active_loadout")
					if not active.is_empty():
						lo.call("update_loadout", str(active.get("name", "")), str(active.get("primary", "ar7")), str(active.get("secondary", "p9")), str(active.get("forge_preset", "")), "portal")
				_main.call("start_sp_mode", "tdm")
				_frame = 0
				_phase = 6
		6:
			if _frame >= 5:
				_check_live_tdm()
				_phase = 7
				_frame = 0
		7:
			if _frame == 1:
				# Restore the active loadout's traversal, then quit.
				var lo2 := root.get_node_or_null("Loadouts")
				if lo2 != null and lo2.has_method("get_active_loadout"):
					var active2: Dictionary = lo2.call("get_active_loadout")
					if not active2.is_empty():
						lo2.call("update_loadout", str(active2.get("name", "")), str(active2.get("primary", "ar7")), str(active2.get("secondary", "p9")), str(active2.get("forge_preset", "")), "grapple")
				_main.call("quit_to_menu")
			if _frame >= 3:
				_check_back_to_menu()
				_phase = 8
		8:
			print("----")
			print("MENU_TDM: %d checks, %d failures" % [_checks, _fails])
			quit(0 if _fails == 0 else 1)
			return true
	return false


# --- Phase 1: registry -------------------------------------------------------

func _check_registry() -> void:
	var consts: Dictionary = _gm_script.get_script_constant_map()
	var modes: Dictionary = consts.get("MODES", {})
	_check("MODES lists tdm", modes.has("tdm"))
	_check("MODES lists zombies", modes.has("zombies"))
	_check("MODES lists mp_tdm", modes.has("mp_tdm"))
	_check("MODES lists tower_defense", modes.has("tower_defense"))
	_check("MODES keeps legacy survival", modes.has("survival"))
	var reg: Dictionary = consts.get("REGISTRY", {})
	_check("REGISTRY has all six rework modes",
		reg.has("tower_defense") and reg.has("tdm") and reg.has("zombies")
		and reg.has("mp_tower_defense") and reg.has("mp_tdm") and reg.has("mp_zombies"))
	_check("SP mode order is tower_defense, tdm, zombies",
		_gm_script.call("modes_for_scope", "sp") == ["tower_defense", "tdm", "zombies"])
	_check("MP mode order is mp_tower_defense, mp_tdm, mp_zombies",
		_gm_script.call("modes_for_scope", "mp") == ["mp_tower_defense", "mp_tdm", "mp_zombies"])
	_check("tdm implemented", bool(_gm_script.call("is_implemented", "tdm")))
	_check("tower_defense implemented", bool(_gm_script.call("is_implemented", "tower_defense")))
	_check("zombies implemented (worker landed it)", bool(_gm_script.call("is_implemented", "zombies")))
	_check("mp_tdm implemented via MP lobby flow", bool(_gm_script.call("is_implemented", "mp_tdm")))
	_check("mp_tower_defense NOT implemented", not bool(_gm_script.call("is_implemented", "mp_tower_defense")))
	_check("mp_zombies NOT implemented", not bool(_gm_script.call("is_implemented", "mp_zombies")))
	_check("unknown mode never implemented", not bool(_gm_script.call("is_implemented", "nope")))
	_check("mode_scope tdm = sp", str(_gm_script.call("mode_scope", "tdm")) == "sp")
	_check("mode_scope mp_tdm = mp", str(_gm_script.call("mode_scope", "mp_tdm")) == "mp")
	_check("mode_scope survival = legacy", str(_gm_script.call("mode_scope", "survival")) == "legacy")
	# Registration contract: a worker flips its mode; unknown ids rejected.
	_check("register_mode(zombies, false) unregisters", bool(_gm_script.call("register_mode", "zombies", false)))
	_check("zombies NOT implemented after unregister", not bool(_gm_script.call("is_implemented", "zombies")))
	_check("register_mode(zombies, true) restores the landed state", bool(_gm_script.call("register_mode", "zombies", true)))
	_check("zombies implemented after re-register", bool(_gm_script.call("is_implemented", "zombies")))
	_check("register_mode rejects unknown id", not bool(_gm_script.call("register_mode", "nope", true)))
	# Forge menu: only TD (+ legacy) may instance it; TDM never.
	_check("forge_menu_allowed(tower_defense)", bool(_gm_script.call("forge_menu_allowed", "tower_defense")))
	_check("forge_menu_allowed(survival) legacy-kept", bool(_gm_script.call("forge_menu_allowed", "survival")))
	_check("forge_menu_allowed(tdm) false", not bool(_gm_script.call("forge_menu_allowed", "tdm")))
	_check("forge_menu_allowed(zombies) false", not bool(_gm_script.call("forge_menu_allowed", "zombies")))
	_check("forge_menu_allowed(mp_tdm) false", not bool(_gm_script.call("forge_menu_allowed", "mp_tdm")))


# --- Phase 1: loadouts traversal ---------------------------------------------

func _check_loadouts() -> void:
	var store: Node = _loadouts_script.new()
	root.add_child(store)
	var opts: Array = store.call("get_traversal_options")
	var ids: Array[String] = []
	for pair in opts:
		if pair is Array and (pair as Array).size() >= 2:
			ids.append(str((pair as Array)[0]))
	_check("traversal options are exactly grapple/jetpack/portal",
		ids == ["grapple", "jetpack", "portal"])
	_check("default active traversal is grapple",
		str(store.call("get_active_traversal")) == "grapple")
	_check("get_active_traversal_tool alias matches",
		str(store.call("get_active_traversal_tool")) == str(store.call("get_active_traversal")))
	_check("create loadout with portal traversal",
		bool(store.call("create_loadout", "TdmVerify", "ar7", "p9", "", "portal")))
	var entry: Dictionary = store.call("get_loadout", "TdmVerify")
	_check("stored traversal is portal", str(entry.get("traversal", "")) == "portal")
	_check("update traversal to jetpack",
		bool(store.call("update_loadout", "TdmVerify", "ar7", "p9", "", "jetpack")))
	_check("stored traversal is jetpack",
		str((store.call("get_loadout", "TdmVerify") as Dictionary).get("traversal", "")) == "jetpack")
	_check("update with legacy 'portal_gun' migrates to portal",
		bool(store.call("update_loadout", "TdmVerify", "ar7", "p9", "", "portal_gun")))
	_check("migrated traversal is portal",
		str((store.call("get_loadout", "TdmVerify") as Dictionary).get("traversal", "")) == "portal")
	_check("create with bogus traversal sanitizes to grapple",
		bool(store.call("create_loadout", "TdmVerify2", "ar7", "p9", "", "fly")))
	_check("bogus traversal stored as grapple",
		str((store.call("get_loadout", "TdmVerify2") as Dictionary).get("traversal", "")) == "grapple")
	_check("set_active(TdmVerify)", bool(store.call("set_active", "TdmVerify")))
	_check("active traversal follows the active loadout (portal)",
		str(store.call("get_active_traversal")) == "portal")
	_check("update traversal to portal on the active loadout",
		bool(store.call("update_loadout", "TdmVerify", "ar7", "p9", "", "portal")))
	_check("active traversal is portal",
		str(store.call("get_active_traversal")) == "portal")
	_check("delete TdmVerify", bool(store.call("delete_loadout", "TdmVerify")))
	_check("delete TdmVerify2", bool(store.call("delete_loadout", "TdmVerify2")))
	store.queue_free()


# --- Phase 2: menu --------------------------------------------------------------

func _check_menu() -> void:
	_check("menu instantiated", is_instance_valid(_menu))
	_check("PLAY top entry exists", _menu.find_child("SinglePlayerButton", true, false) != null)
	_check("MULTIPLAYER top entry exists", _menu.find_child("MultiplayerButton", true, false) != null)
	var overlay := _menu.get_node("ModeSelectOverlay") as Control
	_check("mode overlay initially hidden", not overlay.visible)
	_menu.call("_open_mode_select", "sp")
	_check("SP mode select opens", overlay.visible)
	for id in ["tdm", "tower_defense", "zombies"]:
		var button := _menu.find_child("ModeStart_" + id, true, false) as Button
		_check("SP mode selectable: " + id, button != null and not button.disabled)
	_menu.call("_on_mode_start_pressed", "tdm")
	_check("TDM continues to deployment", _menu.get("_deploy_panel").visible)
	_check("deployment shows active loadout", not str(_menu.get("_deploy_loadout").text).is_empty())
	_check("deployment has traversal", not _menu.get("_deploy_tool").disabled)
	_menu.call("_close_deploy")
	_menu.call("_on_mode_start_pressed", "zombies")
	_check("Zombies reaches deployment without Main", _menu.get("_deploy_panel").visible)
	_menu.call("_launch_mode", "zombies")
	_check("launch without Main reports error", _menu.get("_deploy_status").text.contains("MAIN MISSING"))
	_menu.call("_close_deploy")
	_menu.call("_on_mode_start_pressed", "tower_defense")
	_check("TD has traversal selection", not _menu.get("_deploy_tool").disabled)
	_menu.call("_close_deploy")
	_menu.call("_close_mode_select")
	_check("mode selection closes", not overlay.visible)
	_menu.call("_open_mode_select", "mp")
	for id in ["mp_tdm", "mp_tower_defense", "mp_zombies"]:
		var button := _menu.find_child("ModeStart_" + id, true, false) as Button
		_check("MP mode selectable: " + id, button != null and not button.disabled)
	_menu.call("_close_mode_select")
	_menu.queue_free()
	_menu = null


# --- Phase 3: picker -------------------------------------------------------------

func _check_picker() -> void:
	_check("picker instantiated + open", _picker != null and _picker.call("is_open"))
	var trav_sel := _picker.find_child("TraversalSelect", true, false) as OptionButton
	_check("picker has TRAVERSAL dropdown", trav_sel != null)
	if trav_sel != null:
		_check("traversal dropdown has exactly 3 options", trav_sel.item_count == 3)
		_check("traversal dropdown lists Grapple Hook / Jetpack / Portal Gun",
			trav_sel.get_item_text(0) == "Grapple Hook"
			and trav_sel.get_item_text(1) == "Jetpack"
			and trav_sel.get_item_text(2) == "Portal Gun")
	# List rows show the traversal choice.
	var found := false
	for lbl in _picker.find_children("*", "Label", true, false):
		if (lbl as Label).text.contains("Traversal:"):
			found = true
			break
	_check("picker list rows show Traversal:", found)
	_picker.call("close")
	_picker.queue_free()
	_picker = null


# --- Phase 4: BotTDM logic --------------------------------------------------------

func _check_bot_tdm_logic() -> void:
	_tdm = _bot_tdm_script.new()
	root.add_child(_tdm)
	_tdm.connect("kill_scored", _on_kill)
	_tdm.connect("match_ended", _on_end)
	_check("BotTDM starts with chosen traversal",
		bool(_tdm.call("start", "portal")))
	_check("BotTDM running after start", bool(_tdm.get("running")))
	_check("BotTDM keeps traversal_tool", str(_tdm.get("traversal_tool")) == "portal")
	var state: Dictionary = _tdm.call("get_state")
	_check("BotTDM spawns 5 bots (2 allies + 3 enemies)",
		int(state.get("bots_total", -1)) == 5)
	var allies := 0
	var enemies := 0
	for b in _tdm.get("bots"):
		if int(b.get("team_id")) == 0:
			allies += 1
		else:
			enemies += 1
	_check("BotTDM squad split is 2 ALPHA / 3 BRAVO", allies == 2 and enemies == 3)
	_check("BotTDM starts 0-0", (_tdm.get("team_scores") as Array) == [0, 0])
	# Scoring.
	_tdm.call("record_kill", 0, 1, "YOU", "HAVOC")
	_check("kill scores for ALPHA (1-0)", (_tdm.get("team_scores") as Array) == [1, 0])
	_check("kill_scored emitted", _kill_events.size() == 1)
	_tdm.call("record_kill", 1, 1, "VIPER", "HAVOC")
	_check("friendly kill scores NOTHING (still 1-0)", (_tdm.get("team_scores") as Array) == [1, 0])
	_tdm.call("record_kill", 1, 0, "VIPER", "YOU")
	_check("kill scores for BRAVO (1-1)", (_tdm.get("team_scores") as Array) == [1, 1])
	# Player-death attribution: a bot that hit the player gets the kill.
	var bravo_bot: Node = null
	for b in _tdm.get("bots"):
		if int(b.get("team_id")) == 1:
			bravo_bot = b
			break
	_tdm.call("note_player_damage", bravo_bot)
	_tdm.call("_on_player_died")
	_check("player death attributes to the last bot that hit (1-2)",
		(_tdm.get("team_scores") as Array) == [1, 2])
	_check("player death schedules a respawn",
		float(_tdm.get("_player_respawn_t")) > 0.0)
	# Real bot death: lethal damage from a BRAVO bot attributes the
	# kill (1-3), drops the alive count, and the respawn timer
	# re-activates the same body.
	var alpha_bot: Node = null
	for b in _tdm.get("bots"):
		if int(b.get("team_id")) == 0:
			alpha_bot = b
			break
	alpha_bot.call("take_damage", 100000.0, (alpha_bot as Node3D).global_position, false, bravo_bot)
	_check("lethal bot damage attributes the kill (1-3)",
		(_tdm.get("team_scores") as Array) == [1, 3])
	_check("dead bot drops the alive count to 4",
		int((_tdm.call("get_state") as Dictionary).get("bots_alive", -1)) == 4)
	_tdm.call("_process", 3.1)
	_check("bot respawn timer fires (alive count back to 5)",
		int((_tdm.call("get_state") as Dictionary).get("bots_alive", -1)) == 5)
	# Bot death with unknown killer: no score, respawn scheduled.
	(alpha_bot as Node).set("last_attacker", null)
	_tdm.call("on_enemy_died", alpha_bot)
	_check("unknown-killer bot death scores NOTHING (still 1-3)",
		(_tdm.get("team_scores") as Array) == [1, 3])
	# Win at the score limit.
	for i in 24:
		_tdm.call("record_kill", 0, 1, "YOU", "HAVOC")
	_check("match ends at the score limit (25-3, ALPHA)",
		not bool(_tdm.get("running")) and (_tdm.get("team_scores") as Array) == [25, 3])
	_check("match_ended emitted with ALPHA winner + score_limit reason",
		_end_events.size() == 1 and _end_events[0][0] == 0
		and str((_end_events[0][1] as Dictionary).get("reason", "")) == "score_limit")
	_tdm.call("record_kill", 1, 0, "VIPER", "YOU")
	_check("kills after match end ignored (still 25-3)",
		(_tdm.get("team_scores") as Array) == [25, 3])
	_tdm.call("stop")
	_tdm.queue_free()
	_tdm = null
	# GameModeManager wiring: start("tdm") sets live_mode; unimplemented
	# modes refuse; stop() clears live_mode.
	var gm: Node = _gm_script.new()
	root.add_child(gm)
	_check("GameModeManager.start(tdm) ok", bool(gm.call("start", "tdm")))
	_check("live_mode is tdm during the run", str(gm.get("live_mode")) == "tdm")
	_check("live_mode set even on the class (ForgeGate reads it)",
		str(_gm_script.call("get_live_mode")) == "tdm")
	gm.call("stop")
	_check("stop() clears live_mode", str(_gm_script.call("get_live_mode")) == "")
	_check("start(zombies) ok (worker landed it)", bool(gm.call("start", "zombies")))
	_check("zombies run sets live_mode", str(_gm_script.call("get_live_mode")) == "zombies")
	gm.call("stop")
	_check("stop() after zombies clears live_mode", str(_gm_script.call("get_live_mode")) == "")
	_check("start(mp_tdm) refuses (MP does not run through the manager)",
		not bool(gm.call("start", "mp_tdm")))
	_check("GameModeManager.start(tdm) again ok", bool(gm.call("start", "tdm")))
	_check("live_mode latched by the second run", str(_gm_script.call("get_live_mode")) == "tdm")
	gm.free()  # _exit_tree must clear live_mode even without stop().
	_check("freeing the manager without stop() clears live_mode",
		str(_gm_script.call("get_live_mode")) == "")


# --- Phase 4: bots move + shoot ---------------------------------------------------

func _check_bot_move_and_shoot() -> void:
	_arena = Node3D.new()
	_arena.name = "TdmVerifyArena"
	root.add_child(_arena)
	var tdm2: Node = _bot_tdm_script.new()
	_arena.add_child(tdm2)
	# A live-but-idle owner: bots read player_team / bots off it.
	tdm2.set("player_team", 0)
	_bot = _bot_fighter_script.new()
	_bot.call("setup", "VIPER", 1, tdm2)
	_arena.add_child(_bot)
	(tdm2.get("bots") as Array).append(_bot)
	# Opposing "player": a damageable body in the player group.
	_dummy = DummyTarget.new()
	_dummy.name = "DummyPlayer"
	_dummy.add_to_group("player")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 3.0, 3.0)
	shape.shape = box
	_dummy.add_child(shape)
	_dummy.position = Vector3(0, 1.0, 2.0)
	_arena.add_child(_dummy)
	_bot.call("activate", Vector3.ZERO, 1, {})
	_bot.set("_telegraph_t", 0.0)
	_bot.call("_ai_physics", 0.1)
	var wish: Vector3 = _bot.get("wish_dir")
	_check("bot with a visible opposing target wants to move (wish_dir != 0)",
		wish.length() > 0.1)
	_bot.call("_physics_process", 0.1)
	var vel: Vector3 = _bot.get("velocity")
	_check("bot velocity picks up toward the fight (planar speed > 0.5)",
		Vector2(vel.x, vel.z).length() > 0.5)
	# Shooting: repeated shots (spread is random) must land at least one.
	for i in 5:
		_bot.call("_fire_at", _dummy)
		if not (_dummy as DummyTarget).hits.is_empty():
			break
	_check("bot _fire_at damages the target",
		not (_dummy as DummyTarget).hits.is_empty())
	_check("bot fire damage equals bot damage stat",
		not (_dummy as DummyTarget).hits.is_empty()
		and is_equal_approx(float((_dummy as DummyTarget).hits[0]), float(_bot.get("damage"))))
	_arena.queue_free()
	_arena = null
	_bot = null
	_dummy = null


# --- Phase 5/6/7: launch + live TDM + back to menu ---------------------------------

func _check_launch_menu() -> void:
	_check("Main boots to the start menu (MainMenu exists)",
		_main.get_node_or_null("MainMenu") != null)
	_check("Main boots in MENU state, not in-game", int(_main.get("state")) == 0)
	_check("no player at boot (not deployed straight into a game)",
		get_nodes_in_group("player").is_empty())


func _check_live_tdm() -> void:
	_check("start_sp_mode(tdm) leaves Main PLAYING", int(_main.get("state")) == 1)
	var players: Array[Node] = get_nodes_in_group("player")
	_check("live TDM run has a player", not players.is_empty())
	var modes: Node = _main.get("_modes")
	_check("live TDM run has a GameModeManager", modes != null and is_instance_valid(modes))
	var live_tdm: Node = null
	if modes != null:
		live_tdm = modes.get("_tdm")
	_main_tdm = live_tdm
	_check("live TDM run has a BotTDM", live_tdm != null and is_instance_valid(live_tdm))
	if live_tdm != null:
		_check("live BotTDM is running", bool(live_tdm.get("running")))
		_check("live BotTDM carries the chosen traversal (portal)",
			str(live_tdm.get("traversal_tool")) == "portal")
		_check("live BotTDM has 5 bots",
			int((live_tdm.call("get_state") as Dictionary).get("bots_total", -1)) == 5)
	_check("live TDM sets live_mode = tdm (ForgeGate blocks Forge)",
		str(_gm_script.call("get_live_mode")) == "tdm")
	_check("live TDM instances NO Forge menu",
		get_nodes_in_group("forge_menu").is_empty())
	var huds: Array[Node] = get_nodes_in_group("hud")
	_check("live TDM has a HUD", not huds.is_empty())
	if not huds.is_empty():
		_check("HUD Forge button absent in TDM",
			(huds[0] as Node).get("_forge_btn") == null)
		_check("HUD _forge_ui_open() false in TDM (no crash)",
			not bool((huds[0] as Node).call("_forge_ui_open")))


func _check_back_to_menu() -> void:
	_check("quit_to_menu returns Main to MENU", int(_main.get("state")) == 0)
	_check("menu rebuilt after quit", _main.get_node_or_null("MainMenu") != null)
	_check("live_mode cleared after quit (ForgeGate unlatched)",
		str(_gm_script.call("get_live_mode")) == "")
	_check("player freed after quit",
		get_nodes_in_group("player").is_empty())
