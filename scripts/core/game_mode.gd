# FORGEFALL — GameModeManager (Goal 3 CONTENT, Worker C: modes)
# Owns the three game modes. Survival is the shipped wave mode, unchanged.
# DOMINATION (objectives): capture/hold 3 points (A/B/C) on Dustline; each
# held point ticks +1 score/sec; first to WIN_SCORE wins. Enemies inside a
# point's radius CONTEST it (no capture progress, no tick) but never steal
# an owned point — the player must clear them. Death respawns the player
# after RESPAWN_DELAY at a random player_spawn marker so a match stays
# playable (survival/endless keep the shipped KIA behaviour / run-over).
# ENDLESS (score chase): waves keep coming with no cap (WaveManager already
# has no wave cap); each cleared wave pays an escalating bonus
# (100 x wave number) on top of kill score. Death ends the run and the
# run's score is compared against the persisted best in
# user://endless_best.json (saved on every wave clear too, crash-safe).
#
# Selection: the main menu sets GameModeManager.selected_mode before
# Main.start_game(); Main adds this node and calls start(selected_mode).
# HUD needs no changes: objective score flows through Game.add_score, so
# the topbar + killfeed already show it; mode events announce via the
# HUD's announce()/add_killfeed() when a HUD exists.
class_name GameModeManager
extends Node

signal mode_started(mode: String)
signal domination_point_changed(point_name: String, owned: bool)
signal domination_score_changed(score: int)
signal mode_won(mode: String, score: int)
signal endless_run_over(score: int, best: int, is_new_best: bool)
signal tdm_match_ended(winner_team: int, result: Dictionary)

## Mode registry (Gameplay Rework — menu + TDM worker).
## MODES above carries name/desc (legacy shape, kept for menus and
## verifiers); REGISTRY adds the routing metadata. A mode is
## SELECTABLE in the menus iff is_implemented(id) is true.
##   scope: "sp" | "mp" | "legacy" (legacy = pre-rework modes, kept
##     working via Main.start_game() but NOT listed in the new
##     Single/Multiplayer mode selects).
##   implemented: true when a start path ships — builtin (legacy),
##     BotTDM (tdm), TowerDefenseMode (tower_defense), or the MP lobby
##     flow (mp_tdm via Main.open_multiplayer_menu()).
## REGISTRATION CONTRACT (for the TD / Zombies / MP workers): when
## your mode lands, (1) wire its start path (cf. TowerDefenseMode's
## hook line in start() below, or Main.start_sp_mode()), then (2) call
## GameModeManager.register_mode("<id>", true). Until step 2, the menu
## shows the entry as NOT AVAILABLE and start() refuses it — never a
## crash, never a silent fallback into another mode.
const REGISTRY := {
	"tower_defense": {"scope": "sp", "implemented": true},
	"tdm": {"scope": "sp", "implemented": true},
	"zombies": {"scope": "sp", "implemented": true},
	"mp_tower_defense": {"scope": "mp", "implemented": false},
	"mp_tdm": {"scope": "mp", "implemented": true},
	"mp_zombies": {"scope": "mp", "implemented": false},
	"survival": {"scope": "legacy", "implemented": true},
	"domination": {"scope": "legacy", "implemented": true},
	"endless": {"scope": "legacy", "implemented": true},
	"base_defense": {"scope": "legacy", "implemented": true},
}
const SP_MODE_ORDER := ["tower_defense", "tdm", "zombies"]
const MP_MODE_ORDER := ["mp_tower_defense", "mp_tdm", "mp_zombies"]

## Runtime registration overrides (id -> bool), set by register_mode().
## Lets a worker flip its mode to implemented without editing this file.
static var _registry_overrides := {}


## Mark a mode implemented / not (see REGISTRY contract above).
## Returns false for unknown ids (nothing changed).
static func register_mode(id: String, implemented: bool) -> bool:
	if not REGISTRY.has(id):
		return false
	_registry_overrides[id] = implemented
	return true


## True when the mode has a start path (registry flag or override).
## Unknown ids are never implemented.
static func is_implemented(id: String) -> bool:
	if _registry_overrides.has(id):
		return bool(_registry_overrides[id])
	if REGISTRY.has(id):
		return bool((REGISTRY[id] as Dictionary).get("implemented", false))
	return false


## Scope of a mode ("sp" | "mp" | "legacy", "" when unknown).
static func mode_scope(id: String) -> String:
	if REGISTRY.has(id):
		return str((REGISTRY[id] as Dictionary).get("scope", ""))
	return ""


## Mode ids for one menu, in display order ("sp" | "mp").
static func modes_for_scope(scope: String) -> Array[String]:
	if scope == "mp":
		return Array(MP_MODE_ORDER, TYPE_STRING, &"", null)
	return Array(SP_MODE_ORDER, TYPE_STRING, &"", null)


## Whether the Forge MENU may exist in a run of `mode` (HUD button +
## Forge menu scene). Forge BUILDING itself is gated by ForgeGate
## (TD worker): only "tower_defense" passes a live build. The menu
## still instances for legacy modes (their submits are refused by
## ForgeGate in a live run) but NEVER for the new non-TD modes —
## TDM / Zombies / MP must not open Forge building at all.
static func forge_menu_allowed(mode: String) -> bool:
	return mode in ["survival", "domination", "endless", "base_defense", "tower_defense", "mp_tower_defense"]

## Mode metadata for the menu (id -> {name, desc}). Survival first = default.
const MODES := {
	"survival": {
		"name": "SURVIVAL",
		"desc": "Classic waves. Survive as long as you can.",
	},
	"domination": {
		"name": "DOMINATION",
		"desc": "Capture and hold A / B / C. First to 200 pts wins.",
	},
	"endless": {
		"name": "ENDLESS",
		"desc": "Waves never stop. Chase your best score.",
	},
	"base_defense": {
		"name": "BASE DEFENSE",
		"desc": "Build phase, then hold the core. Forge is how you survive.",
	},
	"tower_defense": {
		"name": "TOWER DEFENSE",
		"desc": "Purpose-built TD map: build on the lanes, then defend the core. Forge building lives here — and only here.",
	},
	"tdm": {
		"name": "TEAM DEATHMATCH",
		"desc": "You + bot squadmates vs a bot squad. First team to 25 kills wins. Pick your loadout + traversal tool first.",
	},
	"zombies": {
		"name": "ZOMBIES",
		"desc": "Horde survival. Buy doors, perks, Mystery Box, Pack-a-Punch. No Forge — pure gunplay.",
	},
	"mp_tower_defense": {
		"name": "TOWER DEFENSE (MP)",
		"desc": "Co-op Tower Defense: two players defend the same core. Shared build phase — Forge building lives here, and only here.",
	},
	"mp_tdm": {
		"name": "TEAM DEATHMATCH (MP)",
		"desc": "PvP Team Deathmatch over LAN / direct IP. Bots fill empty slots (planned).",
	},
	"mp_zombies": {
		"name": "ZOMBIES (MP)",
		"desc": "Co-op Zombies: own points each, shared doors/perks/box/PAP, cross-peer revives. No Forge.",
	},
}

const BEST_PATH := "user://endless_best.json"

# --- Domination tunables ---
const POINT_RADIUS := 4.0
const POINT_CONTEST_RADIUS := 5.5   # enemies inside this contest the point
const CAPTURE_RATE := 0.35          # progress/sec uncontested (~2.9 s to flip)
const DECAY_RATE := 0.10            # progress/sec lost when nobody stands in it
const WIN_SCORE := 200

# --- Endless tunables ---
const ENDLESS_BONUS_PER_WAVE := 100  # wave-clear bonus = this x wave number

const RESPAWN_DELAY := 3.0

## Set by the main menu before Main.start_game(). Persists across runs in
## this process; reset to "survival" only by explicit menu choice.
static var selected_mode: String = "survival"


## Static getter for live_mode (verifiers / tools reach statics through
## script.call(), not get()).
static func get_live_mode() -> String:
	return live_mode

## Mode of the LIVE run, tracked for the Forge gate (ForgeGate).
## Set in start(), cleared in stop() / _exit_tree(). "" = no live run.
## The Forge gate permits building when no run is live (menus, tools,
## tests) and allows it in a live run ONLY for "tower_defense".
static var live_mode: String = ""

# Fixed Dustline points: open ground, clear of the shack footprints in
# dustline_builder.gd (A north-west plaza, B south-center, C south-east).
const POINT_DEFS := [
	{"name": "A", "pos": Vector3(-20, 0, -14)},
	{"name": "B", "pos": Vector3(0, 0, 12)},
	{"name": "C", "pos": Vector3(20, 0, 14)},
]

var mode: String = "survival"
var running := false
var domination_score := 0
var _points: Array = []  # {name, pos, progress, owned, contested, root, mat}
var _score_frac := 0.0
var _respawn_t := -1.0
var _tdm: Node = null  # BotTDM child while a TDM run is live.


func _exit_tree() -> void:
	# quit_to_menu() frees this node WITHOUT calling stop(): clear the
	# Forge gate's live mode here, or the gate would stay latched on
	# the dead run's mode and refuse Forge in the menu / next run.
	# Only clear when this manager owns the live mode (a newer manager
	# may already have started the next run).
	if live_mode == mode:
		live_mode = ""


func _ready() -> void:
	# Connected once per node lifetime; handlers no-op unless running.
	if not Game.player_died.is_connected(_on_player_died):
		Game.player_died.connect(_on_player_died)
	if not Game.wave_cleared.is_connected(_on_wave_cleared):
		Game.wave_cleared.connect(_on_wave_cleared)


## Start a run in `m`. Resets the run state (score/wave/budget) and builds
## objective points for Domination. Returns false (and starts NOTHING)
## for a known-but-unimplemented mode — the menu shows those as NOT
## AVAILABLE and never calls start() for them; a direct call must not
## silently fall back into another mode. Unknown ids still fall back
## to survival (legacy behaviour).
func start(m: String) -> bool:
	if not MODES.has(m):
		push_warning("GameModeManager: unknown mode '%s', falling back to survival." % m)
		m = "survival"
	if not is_implemented(m):
		push_warning("GameModeManager: mode '%s' is registered but not implemented — not starting." % m)
		return false
	if mode_scope(m) == "mp":
		push_warning("GameModeManager: mode '%s' is multiplayer — it starts through Main._on_mp_start, not GameModeManager." % m)
		return false
	mode = m
	selected_mode = m
	live_mode = m
	domination_score = 0
	_score_frac = 0.0
	_respawn_t = -1.0
	Game.reset_run()
	_clear_points()
	if mode == "base_defense": add_child(BaseDefenseMode.new())
	if mode == "tower_defense": add_child(TowerDefenseMode.new())
	if mode == "zombies":
		# Same treatment as BotTDM below (TD worker, 2026-10-16): the
		# Zombies worker's zombies.gd does not parse yet (its own
		# in-flight errors), so a direct ZombiesMode.new() reference
		# breaks parsing of this WHOLE file. Load at runtime; when
		# zombies.gd parses, this behaves identically to
		# ZombiesMode.new(). Coordinator: remove the guard once
		# zombies.gd is green in check_scripts.
		var zombies_script: GDScript = null
		if ResourceLoader.exists("res://scripts/modes/zombies.gd"):
			zombies_script = load("res://scripts/modes/zombies.gd") as GDScript
		if zombies_script == null:
			push_warning("GameModeManager: ZombiesMode script missing/unparseable — Zombies run starts without zombie logic.")
		else:
			add_child(zombies_script.new())
	if mode == "tdm":
		# TD worker note (2026-10-16): the TDM worker's BotTDM script
		# has not landed yet — a direct BotTDM.new() reference breaks
		# parsing of this WHOLE file (and every file that depends on
		# GameModeManager). Load it at runtime instead, so a missing
		# TDM script warns instead of breaking all modes; when the TDM
		# worker lands scripts/modes/bot_tdm.gd this behaves
		# identically to BotTDM.new(). Coordinator: confirm the path.
		var tdm_script: GDScript = null
		if ResourceLoader.exists("res://scripts/modes/bot_tdm.gd"):
			tdm_script = load("res://scripts/modes/bot_tdm.gd") as GDScript
		if tdm_script == null:
			push_warning("GameModeManager: BotTDM script missing — TDM run starts without bot logic.")
		else:
			_tdm = tdm_script.new()
			add_child(_tdm)
			if _tdm.has_signal("match_ended") and not _tdm.is_connected("match_ended", _on_tdm_match_ended):
				_tdm.connect("match_ended", _on_tdm_match_ended)
			if _tdm.has_method("start"):
				_tdm.call("start", _active_traversal())
	if mode == "domination":
		_build_points()
	running = true
	mode_started.emit(mode)
	_announce("%s" % str(MODES[mode]["name"]),
		str(MODES[mode]["desc"]).to_upper())
	return true


## The active loadout's traversal choice (TDM runs it). Guarded: no
## Loadouts autoload (headless / bare tree) -> the default "grapple".
func _active_traversal() -> String:
	var lo := get_node_or_null("/root/Loadouts")
	if lo != null and lo.has_method("get_active_traversal"):
		return str(lo.call("get_active_traversal"))
	return "grapple"


## BotTDM -> public signal (Main shows the result, then quits to menu).
func _on_tdm_match_ended(winner_team: int, result: Dictionary) -> void:
	tdm_match_ended.emit(winner_team, result)


## Stop the run (quit to menu / mode won / endless run over). Points freed.
func stop() -> void:
	running = false
	live_mode = ""
	_respawn_t = -1.0
	if _tdm != null and is_instance_valid(_tdm) and _tdm.has_method("stop"):
		_tdm.call("stop")
	_tdm = null
	_clear_points()


func _process(delta: float) -> void:
	if not running:
		return
	if _respawn_t > 0.0:
		_respawn_t -= delta
		if _respawn_t <= 0.0:
			_do_respawn()
	if mode == "domination":
		_tick_domination(delta)


# --- Domination -----------------------------------------------------------

func _build_points() -> void:
	# Map-agnostic placement: derive the arena centre + extent from the
	# map's own player_spawn markers, then spread A/B/C across it. Falls
	# back to the hand-tuned Dustline coords when the map has no spawns.
	var defs := POINT_DEFS
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	if spawns.size() >= 3:
		var center := Vector3.ZERO
		for s in spawns:
			center += (s as Node3D).global_position
		center /= float(spawns.size())
		center.y = 0.0
		var extent := 0.0
		for s in spawns:
			extent = maxf(extent, (s as Node3D).global_position.distance_to(center))
		extent = maxf(extent, 1.0)
		defs = [
			{"name": "A", "pos": center + Vector3(-0.55 * extent, 0, -0.40 * extent)},
			{"name": "B", "pos": center + Vector3(0.0, 0, 0.35 * extent)},
			{"name": "C", "pos": center + Vector3(0.55 * extent, 0, 0.40 * extent)},
		]
	for def in defs:
		var root := Node3D.new()
		root.name = "Objective_" + str(def["name"])
		root.position = Vector3(def["pos"].x, 0.0, def["pos"].z)
		root.add_to_group("objective_point")
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = POINT_RADIUS
		cyl.bottom_radius = POINT_RADIUS
		cyl.height = 0.12
		mi.mesh = cyl
		mi.position.y = 0.06
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.35, 0.35, 0.38, 0.45)
		mi.material_override = mat
		root.add_child(mi)
		add_child(root)
		_points.append({
			"name": str(def["name"]),
			"pos": Vector3(def["pos"].x, 0.0, def["pos"].z),
			"progress": 0.0,
			"owned": false,
			"contested": false,
			"root": root,
			"mat": mat,
		})


func _clear_points() -> void:
	for p in _points:
		var r: Node = p.get("root")
		if r != null and is_instance_valid(r):
			r.queue_free()
	_points.clear()


func _player_pos() -> Variant:
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return null
	return (ps[0] as Node3D).global_position


func _enemies_near(pos: Vector3, radius: float) -> bool:
	for e in EnemyBase.all:
		if not is_instance_valid(e):
			continue
		var eb := e as EnemyBase
		if eb == null or not eb.active or eb.dead:
			continue
		if eb.global_position.distance_to(pos) <= radius:
			return true
	return false


func _tick_domination(delta: float) -> void:
	var player_pos: Variant = _player_pos()
	var held := 0
	for p in _points:
		var pos: Vector3 = p["pos"]
		var contested: bool = _enemies_near(pos, POINT_CONTEST_RADIUS)
		p["contested"] = contested
		var player_inside := player_pos != null and (player_pos as Vector3).distance_to(pos) <= POINT_RADIUS
		if not p["owned"]:
			if player_inside and not contested:
				p["progress"] = minf(float(p["progress"]) + CAPTURE_RATE * delta, 1.0)
				if float(p["progress"]) >= 1.0:
					p["owned"] = true
					domination_point_changed.emit(str(p["name"]), true)
					if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("domination_capture", {"point": str(p["name"])})
					_announce("POINT %s CAPTURED" % str(p["name"]), "HOLD IT — +1 PT/SEC")
					Sfx.play_2d("forge_success")
			elif not player_inside and float(p["progress"]) > 0.0:
				p["progress"] = maxf(float(p["progress"]) - DECAY_RATE * delta, 0.0)
		elif not contested:
			held += 1
		_update_point_visual(p)
	if held > 0:
		_score_frac += float(held) * delta
		if _score_frac >= 1.0:
			var whole := int(floor(_score_frac))
			_score_frac -= float(whole)
			domination_score += whole
			Game.add_score(whole)
			domination_score_changed.emit(domination_score)
			if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("domination_hold", {"points": whole})
			if domination_score >= WIN_SCORE:
				_win_domination()


func _update_point_visual(p: Dictionary) -> void:
	var mat: StandardMaterial3D = p["mat"]
	if mat == null:
		return
	if p["contested"]:
		mat.albedo_color = Color(1.0, 0.15, 0.10, 0.6)
	elif p["owned"]:
		mat.albedo_color = Color(1.0, 0.48, 0.11, 0.5)
	elif float(p["progress"]) > 0.0:
		var t := float(p["progress"])
		mat.albedo_color = Color(0.35 + 0.65 * t, 0.35 + 0.13 * t, 0.38 - 0.27 * t, 0.45)
	else:
		mat.albedo_color = Color(0.35, 0.35, 0.38, 0.45)


func _win_domination() -> void:
	running = false
	_announce("DOMINATION VICTORY", "ALL POINTS HELD — %d PTS" % domination_score)
	Sfx.play_2d("killstreak_ready")
	mode_won.emit(mode, domination_score)
	if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("match_end", {"mode": "domination", "won": true, "draw": false, "score": domination_score})
	_stop_waves()


# --- Endless --------------------------------------------------------------

func _on_wave_cleared(n: int) -> void:
	if not running or mode != "endless":
		return
	var bonus := ENDLESS_BONUS_PER_WAVE * maxi(n, 1)
	Game.add_score(bonus)
	_announce("ENDLESS WAVE %d CLEARED" % n, "BONUS +%d PTS" % bonus)
	# Crash-safe: persist whenever the run beats its best, not just at death.
	_maybe_save_best()


func _on_player_died() -> void:
	if not running:
		return
	match mode:
		"domination":
			_respawn_t = RESPAWN_DELAY
			_announce("K.I.A.", "REDEPLOYING IN %dS..." % int(RESPAWN_DELAY))
		"endless":
			running = false
			var score: int = Game.score
			var best: int = load_best_score()
			var is_new := score > best
			if is_new:
				save_best(score, Game.wave)
				best = score
			_announce("ENDLESS RUN OVER", "SCORE %d — BEST %d" % [score, best])
			Sfx.play_2d("killstreak_ready")
			endless_run_over.emit(score, best, is_new)
			if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("endless_run_over", {"score": score, "best": best, "is_new_best": is_new, "wave": Game.wave})
			_stop_waves()
		"tdm":
			pass  # BotTDM owns player death (attribution + redeploy)
		_:
			pass  # survival keeps the shipped KIA behaviour (no respawn)


func _do_respawn() -> void:
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return
	var player: Node = ps[0]
	if player == null or not is_instance_valid(player) or not player.has_method("respawn"):
		return
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	var pos := Vector3(0, 1.0, 0)
	if not spawns.is_empty():
		var m := spawns[randi() % spawns.size()] as Node3D
		pos = m.global_position
	player.call("respawn", pos)


func _stop_waves() -> void:
	for wm in get_tree().get_nodes_in_group("wave_manager"):
		if wm != null and wm.has_method("stop_run"):
			wm.call("stop_run")


# --- Endless best-score persistence ---------------------------------------
# user://endless_best.json: {"best_score": int, "best_wave": int}.
# Static so the main menu can show the best without starting a run.

static func load_best() -> Dictionary:
	if not FileAccess.file_exists(BEST_PATH):
		return {"best_score": 0, "best_wave": 0}
	var f := FileAccess.open(BEST_PATH, FileAccess.READ)
	if f == null:
		return {"best_score": 0, "best_wave": 0}
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		return {
			"best_score": int(data.get("best_score", 0)),
			"best_wave": int(data.get("best_wave", 0)),
		}
	return {"best_score": 0, "best_wave": 0}


static func load_best_score() -> int:
	return int(load_best().get("best_score", 0))


static func save_best(score: int, wave: int) -> void:
	var f := FileAccess.open(BEST_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("GameModeManager: could not save endless best score.")
		return
	f.store_string(JSON.stringify({"best_score": score, "best_wave": wave}))


func _maybe_save_best() -> void:
	var best := load_best_score()
	if Game.score > best:
		save_best(Game.score, Game.wave)


# --- HUD announce helper (no-op when no HUD exists, e.g. headless) --------

func _announce(title: String, subtitle: String) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("announce"):
			h.call("announce", title, subtitle)
		elif h.has_method("add_killfeed"):
			h.call("add_killfeed", "%s — %s" % [title, subtitle])
