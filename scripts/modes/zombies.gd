# FORGEFALL — Zombies mode (Gameplay Rework, Zombies worker).
#
# CoD-style Zombies, Forgefall-flavored. Town-like first map (SAME
# flow/structure and price balance as BO2's Town — small town, central
# street, key buildings, two Mystery Box spots, Pack-a-Punch in a
# central exposed spot — but Forgefall's OWN names/art: no copied
# Activision names, signage, or assets). No power needed.
#
# POINTS ECONOMY (BO2 balance reference — these numbers ARE the spec):
#   hit 10; lethal torso 60; lethal limb 50; lethal explosive 50;
#   lethal neck 70; lethal headshot 100; lethal melee 130;
#   barrier board 10 (rebuild cap 40, scaling to 490 by round);
#   revive grants 5% of the downed player's points;
#   Carpenter 200; Nuke 400.
# Doors: buyable, BO2-style costs. Perks: contents RANDOMIZED per run,
# ALWAYS a health perk somewhere; Forgefall's own perk pool (own names,
# own effects) with BO2 prices as the balance reference. Wall buys:
# RANDOM per run (each chalk spot gets a random weapon per run).
# Mystery Box: 950, random weapon from EVERYTHING (all base weapons +
# all installed weapon mods), moves on teddy bear. Pack-a-Punch: 5000
# first use (element + damage buff), 2000 re-PAP (chain / sight /
# attachment). NO Forge building in Zombies (ForgeGate allowlists
# Tower Defense only — this mode never opts in). Mods are pre-added
# from the main menu only: the box pool reads the existing
# Arsenal/ModLoader plumbing; there is NO second mod system here.
#
# TRAVERSAL (Colin 20:05): one menu toggle covers ALL THREE traversal
# tools (grapple hook, portal gun, jetpack). Default OFF = no tools.
# Toggle ON = all three allowed. The toggle state lives here
# (persisted to user://zombies_settings.json); the menu UI is
# ZombiesSetup (scripts/modes/zombies_setup.gd), which reads/writes
# this same state. Enforcement uses the player API the movement
# worker built: set_allowed_traversal_tools([]) = no tools (the
# player's active tool falls back to "none"); the toggle-ON list is
# all three tools. NOTE on the player's exactly-one-active model:
# with the toggle ON the allowed set is all three and the active tool
# is the player's current selection (default grapple); a tool-switch
# input does not exist yet — see the report's open question.
#
# ENEMIES: this mode does NOT own enemy spawning or AI — WaveManager
# spawns, the enemy worker owns behaviour/models/animations. This
# mode scores what it can observe: it polls the "enemy" group each
# frame for HP drops (hit points) and dead-transitions (lethal
# points, headshot vs torso via headshot_last). Lethal limb /
# explosive / neck / melee awards exist as API (register_kill with
# the zone) for the damage path to call once the enemy worker wires
# hit-zone attribution; in-game polling can only distinguish
# headshot vs torso, so all other observed lethals score as torso.
# Co-op kill credit is likewise polling-limited: observed kills
# credit solo player 0; per-attacker credit needs the damage path.
#
# WIRING: GameModeManager.start("zombies") adds one ZombiesMode child;
# this node self-starts in _ready() (same pattern as TowerDefenseMode)
# and dies with the run when Main frees the mode manager. Rounds ride
# WaveManager waves: Game.wave_started -> start_round, Game.wave_cleared
# -> round_cleared. The town (geometry + interactables) is built in
# code at the origin on top of the loaded map.
class_name ZombiesMode
extends Node

signal zombies_started()
signal points_changed(player_id: int, points: int)
signal round_changed(round_number: int)
signal round_cleared(round_number: int)
signal perk_bought(player_id: int, perk_id: String)
signal door_opened(door_id: String)
signal box_moved(spot_index: int)
signal pap_upgraded(player_id: int, slot: String, level: int)
signal player_downed(player_id: int)
signal player_revived(player_id: int)
signal zombies_run_over()

# --- Points economy (BO2 balance reference) -------------------------------
const POINTS_HIT := 10
const POINTS_KILL_TORSO := 60
const POINTS_KILL_LIMB := 50
const POINTS_KILL_EXPLOSIVE := 50
const POINTS_KILL_NECK := 70
const POINTS_KILL_HEADSHOT := 100
const POINTS_KILL_MELEE := 130
const POINTS_BOARD := 10
const BOARD_CAP_ROUND_1 := 40
const BOARD_CAP_MAX := 490
const BOARD_CAP_PER_ROUND := 45  # 40 + 45*(round-1), capped at 490 (490 at round 11)
const REVIVE_SHARE := 0.05       # revive grants 5% of downed player's points
const POINTS_CARPENTER := 200
const POINTS_NUKE := 400

# --- Doors / box / PAP costs ----------------------------------------------
const BOX_COST := 950
const PAP_COST := 5000
const REPAP_COST := 2000
const TEDDY_CHANCE := 0.10  # Forgefall tuning (not a BO2 number): box moves on teddy
const WALL_BUY_AMMO_RESERVE := 60

## Weak custom-made starter weapon: barely dents anything (8 dmg).
const STARTER_WEAPON := "ember"

const ELEMENTS: Array[String] = ["ember", "frost", "volt", "toxic", "void"]
const REPAP_UPGRADES: Array[String] = [
	"chain_lightning", "chain_frost", "extended_mag", "red_dot", "suppressor",
]
const ALL_TRAVERSAL_TOOLS: Array[String] = ["grapple", "jetpack", "portal"]

## Perk pool — Forgefall's OWN names/effects; BO2 prices are the
## balance reference (see header). Exactly one health perk.
const PERK_POOL: Array[Dictionary] = [
	{"id": "bulwark_brew", "name": "Bulwark Brew", "desc": "Max health 100 -> 250.", "cost": 2500, "effect": "health"},
	{"id": "swift_sip", "name": "Swift Sip", "desc": "Reload 50% faster.", "cost": 3000, "effect": "reload"},
	{"id": "double_drum", "name": "Double Drum", "desc": "Fire rate +33%.", "cost": 2000, "effect": "fire_rate"},
	{"id": "fleet_foot", "name": "Fleet Foot", "desc": "Sprint faster, longer.", "cost": 2000, "effect": "stamina"},
	{"id": "pack_mule", "name": "Pack Mule", "desc": "Carry a 3rd weapon.", "cost": 4000, "effect": "third_weapon"},
	{"id": "lifeline", "name": "Lifeline", "desc": "Revive faster; solo: revive yourself.", "cost": 500, "effect": "revive"},
	{"id": "deadeye", "name": "Deadeye Draught", "desc": "Tighter aim, steadier ADS.", "cost": 1500, "effect": "accuracy"},
	{"id": "flopper", "name": "Flopper Phial", "desc": "Immune to your own blasts; flop on dive.", "cost": 2000, "effect": "explosive_immunity"},
	{"id": "voltaic", "name": "Voltaic Cherry", "desc": "Reloading shocks nearby enemies.", "cost": 2000, "effect": "reload_shock"},
	{"id": "vulture", "name": "Vulture's Eye", "desc": "See drops through walls; more ammo.", "cost": 3000, "effect": "drops"},
	{"id": "tombstone", "name": "Tombstone Tonic", "desc": "Keep your gear when downed.", "cost": 2000, "effect": "keep_gear"},
	{"id": "ghost_twin", "name": "Ghost Twin", "desc": "A spectre revives you once.", "cost": 2000, "effect": "self_revive"},
]
const HEALTH_PERK_ID := "bulwark_brew"

## Perk-machine spots (5): Forgefall building names, NOT BO2's.
const MACHINE_SPOTS: Array[Dictionary] = [
	{"id": "bank", "name": "Ironhold Bank", "pos": Vector3(-20, 0, -7.2)},
	{"id": "smithy", "name": "Emberworks Smithy", "pos": Vector3(0, 0, -7.2)},
	{"id": "chapel", "name": "Chapel of Cinders", "pos": Vector3(20, 0, -7.2)},
	{"id": "tavern", "name": "Rusty Anvil Tavern", "pos": Vector3(-20, 0, 7.2)},
	{"id": "goods", "name": "Grain & Goods", "pos": Vector3(0, 0, 7.2)},
]

## Wall-buy chalk spots (4). The weapon on each is randomized per run.
const WALL_BUY_SPOTS: Array[Dictionary] = [
	{"id": "chalk_west", "pos": Vector3(-26, 0, -2)},
	{"id": "chalk_mid", "pos": Vector3(10, 0, -2)},
	{"id": "chalk_south", "pos": Vector3(-6, 0, 2)},
	{"id": "chalk_east", "pos": Vector3(26, 0, 2)},
]
## Wall-buy candidate pool (BO2 prices as reference: M14 500,
## Olympia 500, B23R 900, MP5 1000; ammo 250). Distinct per run.
const WALL_BUY_POOL: Array[Dictionary] = [
	{"weapon_id": "ar7", "price": 500, "ammo_price": 250},
	{"weapon_id": "sg12", "price": 500, "ammo_price": 250},
	{"weapon_id": "br3", "price": 900, "ammo_price": 250},
	{"weapon_id": "smg9", "price": 1000, "ammo_price": 250},
]

## Mystery Box spots (2). The box sits at one; teddy moves it.
const BOX_SPOTS: Array[Dictionary] = [
	{"id": "box_west", "pos": Vector3(-14, 0, 0)},
	{"id": "box_east", "pos": Vector3(14, 0, 0)},
]

## Buyable doors (BO2-style costs): blocking volumes until bought.
const DOOR_DEFS: Array[Dictionary] = [
	{"id": "north_alley", "name": "North Alley Gate", "cost": 750, "pos": Vector3(-10, 0, -8), "size": Vector3(4, 3, 0.6)},
	{"id": "south_alley", "name": "South Alley Gate", "cost": 1000, "pos": Vector3(10, 0, 8), "size": Vector3(4, 3, 0.6)},
	{"id": "east_street", "name": "East Street Gate", "cost": 1250, "pos": Vector3(30, 0, 0), "size": Vector3(0.6, 3, 8)},
	{"id": "chapel_grounds", "name": "Chapel Grounds Gate", "cost": 1500, "pos": Vector3(20, 0, -8), "size": Vector3(4, 3, 0.6)},
]

## Barrier windows (6): boards the horde tears down, 10 pts per repair.
const BARRIER_DEFS: Array[Dictionary] = [
	{"id": "bar_bank", "pos": Vector3(-24, 0, -7.8)},
	{"id": "bar_smithy", "pos": Vector3(-14, 0, -7.8)},
	{"id": "bar_chapel", "pos": Vector3(4, 0, -7.8)},
	{"id": "bar_tavern", "pos": Vector3(-24, 0, 7.8)},
	{"id": "bar_goods", "pos": Vector3(4, 0, 7.8)},
	{"id": "bar_waystation", "pos": Vector3(24, 0, 7.8)},
]
const BARRIER_MAX_BOARDS := 6

## Town buildings (Forgefall's own names/art). Street runs along X.
const BUILDINGS: Array[Dictionary] = [
	{"name": "IRONHOLD BANK", "center": Vector3(-20, 0, -13), "size": Vector3(14, 7, 10), "color": Color(0.30, 0.38, 0.50)},
	{"name": "EMBERWORKS SMITHY", "center": Vector3(0, 0, -13), "size": Vector3(12, 6, 10), "color": Color(0.45, 0.28, 0.20)},
	{"name": "CHAPEL OF CINDERS", "center": Vector3(20, 0, -13), "size": Vector3(12, 8, 10), "color": Color(0.55, 0.55, 0.58)},
	{"name": "RUSTY ANVIL TAVERN", "center": Vector3(-20, 0, 13), "size": Vector3(14, 6, 10), "color": Color(0.42, 0.32, 0.22)},
	{"name": "GRAIN & GOODS", "center": Vector3(0, 0, 13), "size": Vector3(12, 6, 10), "color": Color(0.55, 0.50, 0.35)},
	{"name": "WAYSTATION", "center": Vector3(20, 0, 13), "size": Vector3(12, 6, 10), "color": Color(0.35, 0.42, 0.30)},
]
const INTERACT_RADIUS := 2.8
const SELF_REVIVE_DELAY := 3.0
const TRAVERSAL_SETTINGS_PATH := "user://zombies_settings.json"

# --- Run state --------------------------------------------------------------
static var _active := false
static var _traversal_enabled := false
static var _traversal_loaded := false

var running := false
var round_number := 0
var zombies_remaining := 0
var zombies_to_spawn := 0
var player_count := 1
var box_spot := 0
var seed_used := -1

var _players: Dictionary = {}       # player_id -> {points, perks, downed, pap}
var _machine_perks: Dictionary = {}  # machine_id -> perk_id
var _wall_buys: Dictionary = {}      # spot_id -> {weapon_id, price, ammo_price}
var _doors: Dictionary = {}           # door_id -> {open}
var _barriers: Dictionary = {}        # barrier_id -> {boards}
var _box_pool: Array[String] = []
var _rng := RandomNumberGenerator.new()
var _round_board_points := 0
var _self_revive_t := -1.0
var _self_revive_player := -1
var _enemy_track: Dictionary = {}    # instance_id -> {hp, dead}

var _town: Node3D = null
var _interactables: Array[Dictionary] = []  # {node, kind, id, pos, label}
var _door_nodes: Dictionary = {}     # door_id -> {root, body}
var _barrier_nodes: Dictionary = {}  # barrier_id -> {planks}
var _machine_labels: Dictionary = {} # machine_id -> Label3D
var _box_nodes: Array = []           # [{root, glow, label}]
var _pap_label: Label3D = null


# --- Statics: active + traversal toggle -------------------------------------

## True while a Zombies run is live (any instance).
static func is_active() -> bool:
	return _active


## Forge building is never available in Zombies (ForgeGate is the
## real enforcement — Tower Defense allowlist; this mirrors it).
static func forge_allowed() -> bool:
	return not _active


## The menu toggle: ON = all three traversal tools allowed in Zombies.
## Default OFF. Persisted to user://zombies_settings.json.
static func is_traversal_enabled() -> bool:
	if not _traversal_loaded:
		_load_traversal()
	return _traversal_enabled


static func set_traversal_enabled(enabled: bool) -> void:
	_traversal_enabled = enabled
	_traversal_loaded = true
	_save_traversal()


## Test helper: drop the cached toggle so the next read reloads from
## disk (verifies the persistence round-trip without restarting).
static func reset_traversal_cache_for_tests() -> void:
	_traversal_loaded = false
	_traversal_enabled = false


static func _load_traversal() -> void:
	_traversal_loaded = true
	_traversal_enabled = false
	if not FileAccess.file_exists(TRAVERSAL_SETTINGS_PATH):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(TRAVERSAL_SETTINGS_PATH))
	if data is Dictionary and (data as Dictionary).get("traversal_enabled") is bool:
		_traversal_enabled = bool((data as Dictionary).get("traversal_enabled"))


static func _save_traversal() -> void:
	var f := FileAccess.open(TRAVERSAL_SETTINGS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"traversal_enabled": _traversal_enabled}))


## Traversal tools allowed in the CURRENT run: none in Zombies unless
## the toggle is ON (then all three). Outside Zombies, all three.
static func allowed_traversal_tools() -> Array[String]:
	if _active and not is_traversal_enabled():
		return []
	return ALL_TRAVERSAL_TOOLS.duplicate()


static func is_traversal_tool_allowed(tool: String) -> bool:
	return allowed_traversal_tools().has(tool)


## Jetpack contract for the movement worker: the jetpack fires only
## when this is true. (The player's own active-tool gate enforces it
## via the allowed set; this is the queryable form of the same rule.)
static func jetpack_allowed() -> bool:
	return is_traversal_tool_allowed("jetpack")


## Points table (pure — verifier-friendly, no instance needed).
static func points_for_kill(zone: String) -> int:
	match zone:
		"limb":
			return POINTS_KILL_LIMB
		"explosive":
			return POINTS_KILL_EXPLOSIVE
		"neck":
			return POINTS_KILL_NECK
		"headshot":
			return POINTS_KILL_HEADSHOT
		"melee":
			return POINTS_KILL_MELEE
		_:
			return POINTS_KILL_TORSO


## Barrier rebuild cap for a round: 40 -> 490 by round 11.
static func board_points_cap(round_n: int) -> int:
	return mini(BOARD_CAP_ROUND_1 + BOARD_CAP_PER_ROUND * maxi(round_n - 1, 0), BOARD_CAP_MAX)


# --- Lifecycle ---------------------------------------------------------------

func _ready() -> void:
	# Dedupe: GameModeManager.start() twice must not run two Zombies loops.
	if get_parent() != null:
		for sib in get_parent().get_children():
			if sib != self and sib is ZombiesMode:
				queue_free()
				return
	_connect_game_signals()
	start_run()


func _exit_tree() -> void:
	_active = false


func _connect_game_signals() -> void:
	if Game.has_signal("wave_started") and not Game.wave_started.is_connected(_on_wave_started):
		Game.wave_started.connect(_on_wave_started)
	if Game.has_signal("wave_cleared") and not Game.wave_cleared.is_connected(_on_wave_cleared):
		Game.wave_cleared.connect(_on_wave_cleared)
	if Game.has_signal("player_died") and not Game.player_died.is_connected(_on_player_died):
		Game.player_died.connect(_on_player_died)


## Start (or restart) a run. `seed` < 0 = random. Idempotent: a
## previous town/state is torn down first.
func start_run(seed: int = -1) -> void:
	_teardown_town()
	_players.clear()
	_enemy_track.clear()
	_round_board_points = 0
	_self_revive_t = -1.0
	_self_revive_player = -1
	round_number = 0
	zombies_remaining = 0
	zombies_to_spawn = 0
	box_spot = 0
	if seed >= 0:
		_rng.seed = seed
		seed_used = seed
	else:
		_rng.randomize()
		seed_used = _rng.seed
	_randomize_perks()
	_randomize_wall_buys()
	_init_doors_barriers()
	_box_pool = Arsenal.all_weapon_ids()
	_active = true
	running = true
	_build_town()
	apply_traversal_to_player()
	_equip_starter()
	_announce("ZOMBIES", "BUY DOORS — PERKS — PACK-A-PUNCH — SURVIVE")
	zombies_started.emit()


func stop_run() -> void:
	running = false
	_active = false
	_self_revive_t = -1.0
	_self_revive_player = -1
	_teardown_town()


# --- Players / points --------------------------------------------------------

func _ensure_player(player_id: int) -> Dictionary:
	if not _players.has(player_id):
		_players[player_id] = {"points": 0, "perks": [], "downed": false, "pap": {}}
	return _players[player_id]


func get_points(player_id: int = 0) -> int:
	return int(_ensure_player(player_id).get("points", 0))


## MP co-op hooks (MP worker): apply REPLICATED state without
## re-running the local purchase logic. The host validates an action
## (door / revive / points) once; every peer then applies the same
## outcome through these hooks, so no peer spends twice or awards
## twice. Local purchases still go through buy_door / buy_perk /
## revive_player (the SP path) — these hooks are MP-only.
## Set a peer's points to an exact value (host broadcast).
func mp_set_points(peer_id: int, points: int) -> void:
	var p := _ensure_player(peer_id)
	p["points"] = maxi(0, points)
	points_changed.emit(peer_id, int(p["points"]))


## Open a door without spending (host already charged the buyer).
## Returns false when the door is unknown / already open.
func mp_open_door(door_id: String) -> bool:
	if not _doors.has(door_id) or is_door_open(door_id):
		return false
	(_doors[door_id] as Dictionary)["open"] = true
	if _door_nodes.has(door_id):
		var rec: Dictionary = _door_nodes[door_id]
		var root: Node = rec.get("root")
		var body: Node = rec.get("body")
		if root != null and is_instance_valid(root):
			(root as Node3D).visible = false
		if body != null and is_instance_valid(body):
			(body as CollisionObject3D).collision_layer = 0
			(body as CollisionObject3D).collision_mask = 0
	door_opened.emit(door_id)
	return true


## Set a peer's downed flag without the SP side effects (no perk
## strip, no self-revive timer, no run-over): the host already
## decided the outcome, this only mirrors it. Emits the matching
## signal on change.
func mp_set_downed(peer_id: int, downed: bool) -> void:
	var p := _ensure_player(peer_id)
	if bool(p.get("downed", false)) == downed:
		return
	p["downed"] = downed
	if downed:
		player_downed.emit(peer_id)
	else:
		player_revived.emit(peer_id)


## Move the Mystery Box to a spot (host broadcast after a teddy roll).
func mp_set_box_spot(spot_index: int) -> void:
	box_spot = clampi(spot_index, 0, maxi(BOX_SPOTS.size() - 1, 0))
	_update_box_visuals()
	box_moved.emit(box_spot)


func set_player_count(n: int) -> void:
	player_count = maxi(1, n)


func add_points(player_id: int, n: int) -> int:
	var p := _ensure_player(player_id)
	p["points"] = int(p.get("points", 0)) + n
	points_changed.emit(player_id, int(p["points"]))
	return int(p["points"])


func spend_points(player_id: int, n: int) -> bool:
	var p := _ensure_player(player_id)
	if int(p.get("points", 0)) < n:
		return false
	p["points"] = int(p.get("points", 0)) - n
	points_changed.emit(player_id, int(p["points"]))
	return true


func award_hit(player_id: int = 0) -> int:
	return add_points(player_id, POINTS_HIT)


func award_kill(player_id: int, zone: String) -> int:
	return add_points(player_id, points_for_kill(zone))


## Observed kill (polling path): award + decrement the round counter.
func register_kill(player_id: int, zone: String) -> int:
	var gained := award_kill(player_id, zone)
	zombies_remaining = maxi(0, zombies_remaining - 1)
	return gained


func award_board(player_id: int = 0) -> int:
	var cap := board_points_cap(maxi(round_number, 1))
	if _round_board_points >= cap:
		return 0
	var gained := mini(POINTS_BOARD, cap - _round_board_points)
	_round_board_points += gained
	return add_points(player_id, gained)


func award_carpenter(player_id: int = 0) -> int:
	for bid in _barriers.keys():
		(_barriers[bid] as Dictionary)["boards"] = BARRIER_MAX_BOARDS
		_update_barrier_visual(str(bid))
	return add_points(player_id, POINTS_CARPENTER)


func award_nuke(player_id: int = 0) -> int:
	return add_points(player_id, POINTS_NUKE)


# --- Perks -------------------------------------------------------------------

func _perk_def(perk_id: String) -> Dictionary:
	for p in PERK_POOL:
		if str(p.get("id", "")) == perk_id:
			return p
	return {}


func _randomize_perks() -> void:
	var pool := PERK_POOL.duplicate(true)
	# Shuffle by random index removal (RandomNumberGenerator has no shuffle).
	var shuffled: Array = []
	while not pool.is_empty():
		shuffled.append(pool.pop_at(_rng.randi_range(0, pool.size() - 1)))
	var picked: Array = []
	for i in mini(MACHINE_SPOTS.size(), shuffled.size()):
		picked.append(str((shuffled[i] as Dictionary).get("id", "")))
	if not picked.has(HEALTH_PERK_ID):
		picked[_rng.randi_range(0, picked.size() - 1)] = HEALTH_PERK_ID
	_machine_perks.clear()
	for i in MACHINE_SPOTS.size():
		var mid := str((MACHINE_SPOTS[i] as Dictionary).get("id", ""))
		_machine_perks[mid] = picked[i]
		if _machine_labels.has(mid):
			var def := _perk_def(picked[i])
			(_machine_labels[mid] as Label3D).text = "%s\n%d PTS" % [str(def.get("name", picked[i])), int(def.get("cost", 0))]


func machine_perk(machine_id: String) -> String:
	return str(_machine_perks.get(machine_id, ""))


func has_perk(player_id: int, perk_id: String) -> bool:
	return (ensure_player_perks(player_id)).has(perk_id)


func ensure_player_perks(player_id: int) -> Array:
	return _ensure_player(player_id).get("perks", [])


func owned_perks(player_id: int = 0) -> Array:
	return (_ensure_player(player_id).get("perks", []) as Array).duplicate()


## Quick Revive analog ("Lifeline"): 500 solo / 1500 co-op (BO2 reference).
func quick_revive_cost() -> int:
	return 500 if player_count <= 1 else 1500


func buy_perk(player_id: int, machine_id: String) -> Dictionary:
	var perk_id := machine_perk(machine_id)
	if perk_id.is_empty():
		return {"ok": false, "error": "no such perk machine"}
	var def := _perk_def(perk_id)
	if def.is_empty():
		return {"ok": false, "error": "unknown perk"}
	var p := _ensure_player(player_id)
	if bool(p.get("downed", false)):
		return {"ok": false, "error": "downed"}
	if has_perk(player_id, perk_id):
		return {"ok": false, "error": "already owned"}
	var cost := int(def.get("cost", 0))
	if perk_id == "lifeline":
		cost = quick_revive_cost()
	if not spend_points(player_id, cost):
		return {"ok": false, "error": "not enough points"}
	(p["perks"] as Array).append(perk_id)
	_apply_perk_effects(player_id, perk_id)
	_announce("PERK BOUGHT", str(def.get("name", perk_id)).to_upper())
	perk_bought.emit(player_id, perk_id)
	return {"ok": true, "perk_id": perk_id, "cost": cost}


## Best-effort live application. Health raises max HP + heals; fire
## rate / reload / accuracy scale the CURRENT weapon's live vars
## (WeaponBase reads rpm + reload_stages + spread per shot, so this
## takes effect immediately). Other perks are stored (owned_perks)
#  and their full stat hooks are deferred: re-application on weapon
#  swap and sprint/third-weapon/reload-shock/drops hooks need the
#  weapon/player workers' hooks, not a second perk system here.
func _apply_perk_effects(player_id: int, perk_id: String) -> void:
	var player := _find_player()
	if player == null or not is_instance_valid(player):
		return
	match perk_id:
		"bulwark_brew":
			if player.has_method("get_max_hp") and player.has_method("heal"):
				var cur := float(player.call("get_max_hp"))
				player.set("_class_max_hp", cur + 150.0)
				player.call("heal", 150.0)
		"double_drum":
			var w: Variant = _current_weapon(player)
			if w != null and w.get("rpm") is float:
				w.set("rpm", float(w.get("rpm")) * 1.33)
		"swift_sip":
			var w2: Variant = _current_weapon(player)
			if w2 != null and w2.get("reload_stages") is Array:
				var stages: Array = (w2.get("reload_stages") as Array).duplicate()
				for i in stages.size():
					stages[i] = float(stages[i]) * 0.667
				w2.set("reload_stages", stages)
		"deadeye":
			var w3: Variant = _current_weapon(player)
			if w3 != null:
				if w3.get("spread_hip") is float:
					w3.set("spread_hip", float(w3.get("spread_hip")) * 0.75)
				if w3.get("spread_move") is float:
					w3.set("spread_move", float(w3.get("spread_move")) * 0.75)


func _current_weapon(player: Node) -> Variant:
	var wm := player.get_node_or_null("WeaponManager")
	if wm == null or not wm.has_method("current_weapon"):
		return null
	return wm.call("current_weapon")


# --- Wall buys ---------------------------------------------------------------

func _randomize_wall_buys() -> void:
	var pool := WALL_BUY_POOL.duplicate(true)
	var shuffled: Array = []
	while not pool.is_empty():
		shuffled.append(pool.pop_at(_rng.randi_range(0, pool.size() - 1)))
	_wall_buys.clear()
	for i in WALL_BUY_SPOTS.size():
		var sid := str((WALL_BUY_SPOTS[i] as Dictionary).get("id", ""))
		_wall_buys[sid] = (shuffled[i] as Dictionary).duplicate(true)


func wall_buy(spot_id: String) -> Dictionary:
	return (_wall_buys.get(spot_id, {}) as Dictionary).duplicate(true)


func _player_has_weapon(player_id: int, weapon_id: String) -> bool:
	var player := _find_player()
	if player == null:
		return false
	var wm := player.get_node_or_null("WeaponManager")
	if wm == null or not wm.has_method("get_slot_weapon_id"):
		return false
	for slot in ["primary", "secondary", "prototype"]:
		if str(wm.call("get_slot_weapon_id", slot)) == weapon_id:
			return true
	return false


func buy_wall_weapon(player_id: int, spot_id: String) -> Dictionary:
	var def := wall_buy(spot_id)
	if def.is_empty():
		return {"ok": false, "error": "no such wall buy"}
	var weapon_id := str(def.get("weapon_id", ""))
	if _player_has_weapon(player_id, weapon_id):
		if not spend_points(player_id, int(def.get("ammo_price", 250))):
			return {"ok": false, "error": "not enough points"}
		var player := _find_player()
		if player != null:
			var wm := player.get_node_or_null("WeaponManager")
			if wm != null and wm.has_method("add_reserve_ammo"):
				wm.call("add_reserve_ammo", WALL_BUY_AMMO_RESERVE)
		return {"ok": true, "weapon_id": weapon_id, "ammo": true}
	if not spend_points(player_id, int(def.get("price", 0))):
		return {"ok": false, "error": "not enough points"}
	_give_weapon(player_id, weapon_id)
	return {"ok": true, "weapon_id": weapon_id, "ammo": false}


# --- Mystery Box -------------------------------------------------------------

func get_box_pool() -> Array[String]:
	return _box_pool.duplicate()


func roll_box(force_teddy: bool = false, forced_index: int = -1) -> Dictionary:
	# A forced index is a deterministic roll: no teddy chance.
	var is_teddy := force_teddy or (forced_index < 0 and _rng.randf() < TEDDY_CHANCE)
	if is_teddy:
		box_spot = 1 - box_spot
		_update_box_visuals()
		box_moved.emit(box_spot)
		return {"teddy": true, "weapon_id": ""}
	if _box_pool.is_empty():
		return {"teddy": false, "weapon_id": ""}
	var idx := forced_index if forced_index >= 0 and forced_index < _box_pool.size() else _rng.randi_range(0, _box_pool.size() - 1)
	return {"teddy": false, "weapon_id": _box_pool[idx]}


func buy_box(player_id: int, force_teddy: bool = false, forced_index: int = -1) -> Dictionary:
	if not spend_points(player_id, BOX_COST):
		return {"ok": false, "error": "not enough points"}
	var roll := roll_box(force_teddy, forced_index)
	if bool(roll.get("teddy", false)):
		_announce("TEDDY BEAR!", "THE BOX MOVES...")
		return {"ok": true, "teddy": true, "weapon_id": ""}
	_give_weapon(player_id, str(roll.get("weapon_id", "")))
	_announce("MYSTERY BOX", str(roll.get("weapon_id", "")).to_upper())
	return {"ok": true, "teddy": false, "weapon_id": str(roll.get("weapon_id", ""))}


# --- Pack-a-Punch ------------------------------------------------------------

func _pap_for(player_id: int, slot: String) -> Dictionary:
	var p := _ensure_player(player_id)
	var pap_all: Dictionary = p.get("pap", {})
	if not pap_all.has(slot):
		pap_all[slot] = {"level": 0, "element": "", "damage_mult": 1.0,
			"base_damage": 0.0, "upgrade": ""}
	return pap_all[slot]


func pap_state(player_id: int, slot: String = "primary") -> Dictionary:
	return (_pap_for(player_id, slot) as Dictionary).duplicate(true)


func buy_pap(player_id: int, slot: String = "primary") -> Dictionary:
	var pap := _pap_for(player_id, slot)
	var level := int(pap.get("level", 0))
	if level == 0:
		if not spend_points(player_id, PAP_COST):
			return {"ok": false, "error": "not enough points"}
		pap["level"] = 1
		pap["element"] = ELEMENTS[_rng.randi_range(0, ELEMENTS.size() - 1)]
		pap["damage_mult"] = 2.0
		var w: Variant = _slot_weapon(player_id, slot)
		if w != null and w.get("damage") is float:
			pap["base_damage"] = float(w.get("damage"))
		_apply_pap(player_id, slot)
		pap_upgraded.emit(player_id, slot, 1)
		_announce("PACK-A-PUNCHED", str(pap.get("element", "")).to_upper())
		return {"ok": true, "level": 1, "element": str(pap.get("element", ""))}
	if level == 1:
		if not spend_points(player_id, REPAP_COST):
			return {"ok": false, "error": "not enough points"}
		pap["level"] = 2
		pap["upgrade"] = REPAP_UPGRADES[_rng.randi_range(0, REPAP_UPGRADES.size() - 1)]
		_apply_pap(player_id, slot)
		pap_upgraded.emit(player_id, slot, 2)
		_announce("RE-PACKED", str(pap.get("upgrade", "")).to_upper())
		return {"ok": true, "level": 2, "upgrade": str(pap.get("upgrade", ""))}
	return {"ok": false, "error": "already max Pack-a-Punch"}


func _slot_weapon(player_id: int, slot: String) -> Variant:
	var player := _find_player()
	if player == null:
		return null
	var wm := player.get_node_or_null("WeaponManager")
	if wm == null or not wm.has_method("get_slot_weapon"):
		return null
	return wm.call("get_slot_weapon", slot)


func _apply_pap(player_id: int, slot: String) -> void:
	var pap := _pap_for(player_id, slot)
	var w: Variant = _slot_weapon(player_id, slot)
	if w == null:
		return
	var base := float(pap.get("base_damage", 0.0))
	if base <= 0.0 and w.get("damage") is float:
		base = float(w.get("damage"))
		pap["base_damage"] = base
	if base > 0.0:
		w.set("damage", base * float(pap.get("damage_mult", 1.0)))
	if str(pap.get("element", "")) != "":
		w.set_meta("pap_element", str(pap.get("element", "")))
	if str(pap.get("upgrade", "")) != "":
		w.set_meta("pap_upgrade", str(pap.get("upgrade", "")))


## The MP co-op layer (MPModes) when an MP match is running, else
## null. SP runs never see it. The parent check comes first: in MP
## this mode node is a CHILD of its MPModes, so the parent is exactly
## this peer's layer even when several MPModes share one tree
## (headless two-peer sims).
func _mp_layer() -> Node:
	var p := get_parent()
	if p != null and p.has_method("start_mp"):
		return p
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group("mp_modes")


# --- Doors / barriers --------------------------------------------------------

func _init_doors_barriers() -> void:
	_doors.clear()
	for d in DOOR_DEFS:
		_doors[str(d.get("id", ""))] = {"open": false}
	_barriers.clear()
	for b in BARRIER_DEFS:
		_barriers[str(b.get("id", ""))] = {"boards": BARRIER_MAX_BOARDS}


func is_door_open(door_id: String) -> bool:
	var d: Dictionary = _doors.get(door_id, {})
	return bool(d.get("open", false))


func door_cost(door_id: String) -> int:
	for d in DOOR_DEFS:
		if str(d.get("id", "")) == door_id:
			return int(d.get("cost", 0))
	return 0


func buy_door(player_id: int, door_id: String) -> Dictionary:
	# MP worker: on an MP CLIENT the door purchase is host-validated
	# (the host checks the buyer's mirrored points, opens the door,
	# and broadcasts it). The client never opens it locally — it
	# forwards the request and reports "mp_pending"; the door opens
	# on this peer when the host's broadcast lands (mp_open_door).
	# Host + SP run the existing path below unchanged.
	var mp := _mp_layer()
	if mp != null and bool(mp.get("running")) and not bool(mp.get("is_host")):
		if mp.has_method("request_door"):
			mp.call("request_door", door_id)
		return {"ok": false, "error": "mp_pending"}
	if not _doors.has(door_id):
		return {"ok": false, "error": "no such door"}
	if is_door_open(door_id):
		return {"ok": false, "error": "already open"}
	var cost := door_cost(door_id)
	if not spend_points(player_id, cost):
		return {"ok": false, "error": "not enough points"}
	(_doors[door_id] as Dictionary)["open"] = true
	if _door_nodes.has(door_id):
		var rec: Dictionary = _door_nodes[door_id]
		var root: Node = rec.get("root")
		var body: Node = rec.get("body")
		if root != null and is_instance_valid(root):
			(root as Node3D).visible = false
		if body != null and is_instance_valid(body):
			(body as CollisionObject3D).collision_layer = 0
			(body as CollisionObject3D).collision_mask = 0
	door_opened.emit(door_id)
	_announce("DOOR OPENED", door_id.to_upper())
	return {"ok": true, "door_id": door_id, "cost": cost}


func barrier_boards(barrier_id: String) -> int:
	var b: Dictionary = _barriers.get(barrier_id, {})
	return int(b.get("boards", 0))


func repair_board(player_id: int, barrier_id: String) -> Dictionary:
	if not _barriers.has(barrier_id):
		return {"ok": false, "error": "no such barrier"}
	if barrier_boards(barrier_id) >= BARRIER_MAX_BOARDS:
		return {"ok": false, "error": "barrier full"}
	(_barriers[barrier_id] as Dictionary)["boards"] = barrier_boards(barrier_id) + 1
	_update_barrier_visual(barrier_id)
	var gained := award_board(player_id)
	return {"ok": true, "boards": barrier_boards(barrier_id), "points": gained}


## Enemy worker calls this when the horde tears a board off.
func damage_barrier(barrier_id: String, n: int = 1) -> void:
	if not _barriers.has(barrier_id):
		return
	(_barriers[barrier_id] as Dictionary)["boards"] = maxi(0, barrier_boards(barrier_id) - n)
	_update_barrier_visual(barrier_id)


# --- Down / revive -----------------------------------------------------------

func is_downed(player_id: int = 0) -> bool:
	return bool(_ensure_player(player_id).get("downed", false))


func down_player(player_id: int = 0) -> bool:
	var p := _ensure_player(player_id)
	if bool(p.get("downed", false)):
		return false
	var had_lifeline := has_perk(player_id, "lifeline")
	var had_ghost := has_perk(player_id, "ghost_twin")
	p["downed"] = true
	# Downing strips perks (BO2 rules). PAP on weapons is kept.
	p["perks"] = []
	player_downed.emit(player_id)
	if (had_lifeline or had_ghost) and player_count <= 1:
		_self_revive_t = SELF_REVIVE_DELAY
		_self_revive_player = player_id
		_announce("DOWNED", "SELF-REVIVE IN %ds..." % int(SELF_REVIVE_DELAY))
		return true
	if player_count <= 1:
		_announce("DOWNED", "RUN OVER")
		zombies_run_over.emit()
	return true


func revive_player(reviver_id: int, downed_id: int) -> Dictionary:
	var d := _ensure_player(downed_id)
	if not bool(d.get("downed", false)):
		return {"ok": false, "error": "not downed"}
	var awarded := int(int(d.get("points", 0)) * REVIVE_SHARE)
	d["downed"] = false
	add_points(reviver_id, awarded)
	player_revived.emit(downed_id)
	_announce("REVIVED", "+%d PTS" % awarded)
	return {"ok": true, "awarded": awarded}


# --- Rounds ------------------------------------------------------------------

func start_round(n: int) -> void:
	round_number = n
	_round_board_points = 0
	zombies_to_spawn = mini(6 + 5 * (n - 1), 60)
	zombies_remaining = zombies_to_spawn
	round_changed.emit(n)
	_announce("ROUND %d" % n, "%d HOSTILES INBOUND" % zombies_to_spawn)


func _on_wave_started(n: int) -> void:
	if running:
		start_round(n)


func _on_wave_cleared(n: int) -> void:
	if running:
		round_cleared.emit(n)


func _on_player_died() -> void:
	if running:
		down_player(0)


# --- Traversal toggle application -------------------------------------------

## Hands the toggle's allowed-set to the player via the movement
## worker's API. OFF -> [] (active tool falls back to "none": no
## tools fire). ON -> all three allowed; a "none" active tool is
## restored to grapple so something fires. False = no player yet.
## Static: it uses only the toggle state + the passed player, so
## ZombiesSetup and tests can apply it without a mode instance.
static func apply_traversal_to_player(player: Node = null) -> bool:
	var p: Node = player
	if p == null:
		# Static context: no get_tree() — reach the tree via the main loop.
		var loop := Engine.get_main_loop()
		if loop is SceneTree:
			var ps := (loop as SceneTree).get_nodes_in_group("player")
			if not ps.is_empty():
				p = ps[0]
	if p == null or not is_instance_valid(p):
		return false
	if p.has_method("set_allowed_traversal_tools"):
		p.call("set_allowed_traversal_tools", allowed_traversal_tools())
		if is_traversal_enabled() and p.has_method("get_traversal_tool") \
				and str(p.call("get_traversal_tool")) == "none" \
				and p.has_method("set_traversal_tool"):
			p.call("set_traversal_tool", "grapple")
		return true
	return false


# --- Interaction --------------------------------------------------------------

func _find_player() -> Node:
	if not is_inside_tree():
		return null
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return null
	return ps[0]


func _give_weapon(_player_id: int, weapon_id: String) -> bool:
	var player := _find_player()
	if player == null:
		return false
	var wm := player.get_node_or_null("WeaponManager")
	if wm == null or not wm.has_method("give_weapon"):
		return false
	wm.call("give_weapon", weapon_id)
	return true


func _equip_starter() -> void:
	var player := _find_player()
	if player == null:
		return
	var wm := player.get_node_or_null("WeaponManager")
	if wm != null and wm.has_method("set_slot"):
		wm.call("set_slot", "primary", STARTER_WEAPON)


func get_interact_prompt() -> String:
	var player := _find_player()
	if player == null or not (player is Node3D):
		return ""
	var ppos := (player as Node3D).global_position
	var best: Dictionary = {}
	var best_d := INF
	for it in _interactables:
		var ipos: Vector3 = it.get("pos")
		var d := ipos.distance_to(ppos)
		if d < best_d:
			best_d = d
			best = it
	if best.is_empty() or best_d > INTERACT_RADIUS:
		return ""
	return _prompt_for(str(best.get("kind", "")), str(best.get("id", "")))


func _prompt_for(kind: String, id: String) -> String:
	match kind:
		"door":
			if is_door_open(id):
				return "DOOR OPEN"
			return "BUY DOOR — %d PTS" % door_cost(id)
		"perk":
			var pid := machine_perk(id)
			var def := _perk_def(pid)
			if has_perk(0, pid):
				return "%s — OWNED" % str(def.get("name", pid))
			var cost := int(def.get("cost", 0))
			if pid == "lifeline":
				cost = quick_revive_cost()
			return "BUY %s — %d PTS" % [str(def.get("name", pid)), cost]
		"wallbuy":
			var def := wall_buy(id)
			return "BUY %s — %d PTS" % [str(def.get("weapon_id", "?")).to_upper(), int(def.get("price", 0))]
		"box":
			return "MYSTERY BOX — 950 PTS"
		"pap":
			var pap := _pap_for(0, "primary")
			if int(pap.get("level", 0)) == 0:
				return "PACK-A-PUNCH — 5000 PTS"
			if int(pap.get("level", 0)) == 1:
				return "RE-PACK — 2000 PTS"
			return "PACK-A-PUNCH — MAX"
		"barrier":
			if barrier_boards(id) >= BARRIER_MAX_BOARDS:
				return "BARRIER FULL"
			return "REPAIR BARRIER — 10 PTS"
	return ""


func activate_nearest_interact(player_id: int = 0) -> Dictionary:
	var player := _find_player()
	if player == null or not (player is Node3D):
		return {"ok": false, "error": "no player"}
	var ppos := (player as Node3D).global_position
	var best: Dictionary = {}
	var best_d := INF
	for it in _interactables:
		var ipos: Vector3 = it.get("pos")
		var d := ipos.distance_to(ppos)
		if d < best_d:
			best_d = d
			best = it
	if best.is_empty() or best_d > INTERACT_RADIUS:
		return {"ok": false, "error": "nothing in reach"}
	return activate_interact(player_id, str(best.get("kind", "")), str(best.get("id", "")))


func activate_interact(player_id: int, kind: String, id: String) -> Dictionary:
	match kind:
		"door":
			return buy_door(player_id, id)
		"perk":
			return buy_perk(player_id, id)
		"wallbuy":
			return buy_wall_weapon(player_id, id)
		"box":
			return buy_box(player_id)
		"pap":
			return buy_pap(player_id, "primary")
		"barrier":
			return repair_board(player_id, id)
	return {"ok": false, "error": "unknown interactable"}


# --- Per-frame: enemy polling + interact input + self-revive ---------------

func _process(delta: float) -> void:
	if not running or not is_inside_tree():
		return
	_poll_enemies()
	if _self_revive_t > 0.0:
		_self_revive_t -= delta
		if _self_revive_t <= 0.0:
			_do_self_revive()
	if InputMap.has_action("interact") and Input.is_action_just_pressed("interact"):
		activate_nearest_interact(0)


func _do_self_revive() -> void:
	var who := _self_revive_player
	_self_revive_player = -1
	if who < 0:
		who = 0
	var p := _ensure_player(who)
	p["downed"] = false
	var player := _find_player()
	if player != null and player.has_method("respawn") and player is Node3D:
		player.call("respawn", (player as Node3D).global_position)
	player_revived.emit(who)
	_announce("BACK ON YOUR FEET", "PERKS LOST")


func _poll_enemies() -> void:
	var live_ids := {}
	for e in get_tree().get_nodes_in_group("enemy"):
		if not (e is Node):
			continue
		var id := e.get_instance_id()
		live_ids[id] = true
		var hp_v: Variant = e.get("hp")
		var dead_v: Variant = e.get("dead")
		if not (hp_v is float or hp_v is int) or not (dead_v is bool):
			continue
		var hp := float(hp_v)
		var dead := bool(dead_v)
		if not _enemy_track.has(id):
			_enemy_track[id] = {"hp": hp, "dead": dead}
			continue
		var prev: Dictionary = _enemy_track[id]
		if dead and not bool(prev.get("dead", false)):
			var hs_v: Variant = e.get("headshot_last")
			var zone := "headshot" if (hs_v is bool and bool(hs_v)) else "torso"
			register_kill(0, zone)
			prev["dead"] = true
			prev["hp"] = hp
		elif not dead and hp < float(prev.get("hp", hp)) - 0.001:
			award_hit(0)
			prev["hp"] = hp
		elif hp > float(prev.get("hp", hp)) + 0.001:
			prev["hp"] = hp
	for id in _enemy_track.keys():
		if not live_ids.has(id):
			_enemy_track.erase(id)


# --- Town construction ---------------------------------------------------------

func _teardown_town() -> void:
	if _town != null and is_instance_valid(_town):
		_town.free()
	_town = null
	_interactables.clear()
	_door_nodes.clear()
	_barrier_nodes.clear()
	_machine_labels.clear()
	_box_nodes.clear()
	_pap_label = null


func _mat(color: Color, emissive: Color = Color(0, 0, 0), energy: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emissive
		m.emission_energy_multiplier = energy
	return m


func _box_mesh(parent: Node, size: Vector3, pos: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = material
	mi.position = pos
	parent.add_child(mi)
	return mi


func _solid(parent: Node, size: Vector3, pos: Vector3, material: StandardMaterial3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	shape.shape = bs
	body.add_child(shape)
	body.position = pos
	parent.add_child(body)
	_box_mesh(body, size, Vector3.ZERO, material)
	return body


func _label(parent: Node, text: String, pos: Vector3, size: int = 32) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.font_size = size
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l


func _interact(parent: Node, kind: String, id: String, pos: Vector3) -> void:
	var area := Area3D.new()
	area.name = "Interact_%s_%s" % [kind, id]
	var shape := CollisionShape3D.new()
	var ss := SphereShape3D.new()
	ss.radius = 2.0
	shape.shape = ss
	area.add_child(shape)
	area.position = pos
	parent.add_child(area)
	_interactables.append({"node": area, "kind": kind, "id": id, "pos": pos})


func _build_town() -> void:
	_town = Node3D.new()
	_town.name = "ZombiesTown"
	add_child(_town)
	# Street slab.
	_box_mesh(_town, Vector3(72, 0.2, 10), Vector3(0, 0.05, 0), _mat(Color(0.16, 0.16, 0.18)))
	# Buildings (solid + signed).
	for b in BUILDINGS:
		var center: Vector3 = b.get("center")
		var size: Vector3 = b.get("size")
		var col: Color = b.get("color")
		_solid(_town, size, center + Vector3(0, size.y * 0.5, 0), _mat(col))
		var facing_z := -1.0 if center.z < 0 else 1.0
		_label(_town, str(b.get("name", "")), center + Vector3(0, size.y + 0.8, facing_z * (size.z * 0.5 + 0.4)), 40)
	# Doors (blocking volumes until bought).
	for d in DOOR_DEFS:
		var did := str(d.get("id", ""))
		var dpos: Vector3 = d.get("pos")
		var dsize: Vector3 = d.get("size")
		var root := Node3D.new()
		root.name = "Door_" + did
		root.position = dpos
		_town.add_child(root)
		var body := _solid(root, dsize, Vector3(0, dsize.y * 0.5, 0), _mat(Color(0.45, 0.30, 0.12)))
		_label(root, "%s\n%d PTS" % [str(d.get("name", did)).to_upper(), int(d.get("cost", 0))], Vector3(0, dsize.y + 1.0, 0), 28)
		_door_nodes[did] = {"root": root, "body": body}
		_interact(_town, "door", did, dpos)
	# Perk machines.
	for m in MACHINE_SPOTS:
		var mid := str(m.get("id", ""))
		var mpos: Vector3 = m.get("pos")
		_box_mesh(_town, Vector3(1.4, 2.0, 0.8), mpos + Vector3(0, 1.0, 0), _mat(Color(0.15, 0.55, 0.45), Color(0.1, 0.8, 0.6), 1.2))
		var pid := machine_perk(mid)
		var def := _perk_def(pid)
		var lbl := _label(_town, "%s\n%d PTS" % [str(def.get("name", pid)), int(def.get("cost", 0))], mpos + Vector3(0, 2.8, 0), 28)
		_machine_labels[mid] = lbl
		_interact(_town, "perk", mid, mpos)
	# Wall-buy chalk spots.
	for s in WALL_BUY_SPOTS:
		var sid := str(s.get("id", ""))
		var spos: Vector3 = s.get("pos")
		_box_mesh(_town, Vector3(1.2, 1.6, 0.2), spos + Vector3(0, 0.8, 0), _mat(Color(0.75, 0.75, 0.72)))
		var def := wall_buy(sid)
		_label(_town, "%s\n%d PTS" % [str(def.get("weapon_id", "?")).to_upper(), int(def.get("price", 0))], spos + Vector3(0, 2.2, 0), 26)
		_interact(_town, "wallbuy", sid, spos)
	# Mystery Box spots (2).
	for i in BOX_SPOTS.size():
		var spot: Dictionary = BOX_SPOTS[i]
		var bpos: Vector3 = spot.get("pos")
		var root := Node3D.new()
		root.name = "MysteryBox_%d" % i
		root.position = bpos
		_town.add_child(root)
		_box_mesh(root, Vector3(1.6, 1.2, 1.2), Vector3(0, 0.6, 0), _mat(Color(0.35, 0.20, 0.55), Color(0.5, 0.2, 0.9), 0.8))
		var glow := _box_mesh(root, Vector3(1.8, 0.15, 1.4), Vector3(0, 1.35, 0), _mat(Color(1, 0.9, 0.3), Color(1, 0.85, 0.2), 2.5))
		var lbl := _label(root, "MYSTERY BOX\n950 PTS", Vector3(0, 2.1, 0), 28)
		_box_nodes.append({"root": root, "glow": glow, "label": lbl})
		_interact(_town, "box", str(spot.get("id", "")), bpos)
	_update_box_visuals()
	# Pack-a-Punch: central exposed plaza pedestal.
	var pap_root := Node3D.new()
	pap_root.name = "PackAPunch"
	pap_root.position = Vector3(0, 0, 0)
	_town.add_child(pap_root)
	var cyl := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.2
	cm.bottom_radius = 1.5
	cm.height = 0.5
	cyl.mesh = cm
	cyl.material_override = _mat(Color(0.25, 0.25, 0.30), Color(1.0, 0.48, 0.11), 1.5)
	cyl.position.y = 0.25
	pap_root.add_child(cyl)
	_pap_label = _label(pap_root, "PACK-A-PUNCH\n5000 PTS", Vector3(0, 2.2, 0), 30)
	_interact(_town, "pap", "pap", Vector3(0, 0, 0))
	# Barrier windows (6): frame + planks.
	for b in BARRIER_DEFS:
		var bid := str(b.get("id", ""))
		var bpos: Vector3 = b.get("pos")
		_box_mesh(_town, Vector3(2.2, 1.8, 0.2), bpos + Vector3(0, 1.2, 0), _mat(Color(0.30, 0.22, 0.15)))
		var planks: Array = []
		for i in BARRIER_MAX_BOARDS:
			var plank := _box_mesh(_town, Vector3(2.0, 0.22, 0.1),
				bpos + Vector3(0, 0.45 + float(i) * 0.28, 0.15), _mat(Color(0.55, 0.42, 0.28)))
			planks.append(plank)
		_barrier_nodes[bid] = {"planks": planks}
		_interact(_town, "barrier", bid, bpos)


func _update_box_visuals() -> void:
	for i in _box_nodes.size():
		var rec: Dictionary = _box_nodes[i]
		var glow: MeshInstance3D = rec.get("glow")
		var lbl: Label3D = rec.get("label")
		var active_spot := i == box_spot
		if glow != null and is_instance_valid(glow):
			glow.visible = active_spot
		if lbl != null and is_instance_valid(lbl):
			lbl.text = "MYSTERY BOX\n950 PTS" if active_spot else "BOX — MOVED"


func _update_barrier_visual(barrier_id: String) -> void:
	if not _barrier_nodes.has(barrier_id):
		return
	var rec: Dictionary = _barrier_nodes[barrier_id]
	var planks: Array = rec.get("planks", [])
	var boards := barrier_boards(barrier_id)
	for i in planks.size():
		var plank: MeshInstance3D = planks[i]
		if plank != null and is_instance_valid(plank):
			plank.visible = i < boards


# --- HUD announce helper (no-op when no HUD exists, e.g. headless) --------

func _announce(title: String, subtitle: String) -> void:
	if not is_inside_tree():
		return
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("announce"):
			h.call("announce", title, subtitle)
		elif h.has_method("add_killfeed"):
			h.call("add_killfeed", "%s — %s" % [title, subtitle])
