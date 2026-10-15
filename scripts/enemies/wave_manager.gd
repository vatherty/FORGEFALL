# FORGEFALL — scripts/enemies/wave_manager.gd
# Worker 4 (enemy AI + waves).
#
# Wave director for MW2-style wave survival. Owns per-type enemy object pools,
# staggered spawning from "spawn_door" Marker3Ds, wave composition + scaling
# curves, the 20s build phase (Game.build_phase_started), and the Forge
# director hook `apply_director_mod()`.
#
# INTEGRATION (main.gd / coordinator):
#   1. Add the map scene first, THEN instance WaveManager as a child of the
#      run root (nav detection needs the NavigationRegion3D present).
#   2. Call wave_manager.start_run() when the run begins.
#   3. WaveManager creates its own TracerPool child in _ready().
#   4. Optional nav: a NavigationRegion3D in group "nav_region" with a BAKED
#      NavigationMesh (editor-baked, or region.bake_navigation_mesh(false) at
#      map ready). Nav presence is re-checked at every wave start; without it
#      enemies use direct steering with obstacle probes (works in open arena).
# Enemies are built fully in code (Grunt.new() etc.) — no .tscn files.

class_name WaveManager
extends Node

#region TUNABLES
const INTERMISSION_TIME := 20.0   # build-phase seconds between waves
const MAX_CONCURRENT := 10        # alive cap; the rest queue up
const SPAWN_INTERVAL := 1.1       # seconds between spawns
const HP_GROWTH := 0.08           # +8% enemy HP per wave after wave 1
const SPEED_GROWTH := 0.02        # +2% speed per wave
const SPEED_CAP := 1.3            # speed multiplier ceiling
const DMG_GROWTH := 0.05          # +5% enemy damage per wave after wave 1
const ACC_GROWTH := 0.02          # +2% accuracy per wave after wave 1
const POOL_PREINSTANCE := {       # parked bodies per type at boot
	"grunt": 6, "rusher": 3, "marksman": 2, "brute": 1,
	# Goal 3: shredder 2 (they arrive in packs), suppressor/bulwark 1 each,
	# warlord 1 (max one boss per wave, so one parked body suffices).
	"shredder": 2, "suppressor": 1, "bulwark": 1, "warlord": 1,
}
#endregion

# Set by detect_nav(); read by EnemyBase.activate().
static var nav_available := false

var wave_number := 0
var running := false
var in_build_phase := false
var alive_count := 0

var _spawn_queue: Array[String] = []
var _spawn_t := 0.0
var _build_t := 0.0
var _pools := {"grunt": [], "rusher": [], "marksman": [], "brute": [],
	"shredder": [], "suppressor": [], "bulwark": [], "warlord": []}
var _director_mods := {}
var _enrage_t := 0.0
var _doors: Array[Marker3D] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	add_to_group("wave_manager")
	nav_available = detect_nav(get_tree())
	var tracer := EnemyTracerPool.new()
	tracer.name = "EnemyTracerPool"
	add_child(tracer)
	for type_id in POOL_PREINSTANCE.keys():
		for i in int(POOL_PREINSTANCE[type_id]):
			var e := _make_enemy(type_id)
			_pools[type_id].append(e)
			add_child(e)


static func detect_nav(tree: SceneTree) -> bool:
	"""True when a NavigationRegion3D with baked polygons exists."""
	var regions: Array[Node] = tree.get_nodes_in_group("nav_region")
	if regions.is_empty():
		regions = tree.root.find_children("*", "NavigationRegion3D", true, false)
	for r in regions:
		var reg := r as NavigationRegion3D
		if reg != null and reg.navigation_mesh != null:
			if reg.navigation_mesh.get_polygon_count() > 0:
				return true
	return false


static func refresh_nav(tree: SceneTree) -> void:
	nav_available = detect_nav(tree)


# --- run control ----------------------------------------------------------
func start_run() -> void:
	"""Called by main.gd when a run begins."""
	stop_run()
	running = true
	wave_number = 0
	_start_build_phase()


func stop_run() -> void:
	running = false
	in_build_phase = false
	alive_count = 0
	_spawn_queue.clear()
	_director_mods.clear()
	_enrage_t = 0.0
	for type_id in _pools.keys():
		for e in _pools[type_id] as Array:
			(e as EnemyBase)._recycle()


# --- boss / director reinforcement hook --------------------------------------
func queue_extra(type_id: String, count: int) -> void:
	"""Queue extra spawns mid-wave (used by the Warlord's phase summons).
	Unknown types fall back to grunt; the alive cap still paces delivery."""
	if not _pools.has(type_id):
		type_id = "grunt"
	for i in maxi(1, count):
		_spawn_queue.append(type_id)


# --- Forge director hook ----------------------------------------------------
func apply_director_mod(mod: Dictionary) -> void:
	"""Mods from the Forge director. Keys:
	{kind:"spawn_extra", type, count}, {kind:"enrage", speed_mult, dmg_mult,
	duration}, {kind:"weaken", taken_mult}, {kind:"grenadiers"}."""
	var kind := String(mod.get("kind", ""))
	match kind:
		"spawn_extra":
			var t := String(mod.get("type", "grunt"))
			if not _pools.has(t):
				t = "grunt"
			for i in maxi(1, int(mod.get("count", 1))):
				_spawn_queue.append(t)
			_announce("Director reinforcements inbound!")
		"enrage":
			_director_mods["speed_mult"] = float(mod.get("speed_mult", 1.25))
			_director_mods["dmg_mult"] = float(mod.get("dmg_mult", 1.5))
			_enrage_t = float(mod.get("duration", 20.0))
			_announce("Enemies ENRAGED!")
		"weaken":
			_director_mods["taken_mult"] = float(mod.get("taken_mult", 1.5))
			_announce("Enemies weakened!")
		"grenadiers":
			_director_mods["grenadiers"] = true
			_announce("Grenadiers incoming!")
		_:
			push_warning("WaveManager: unknown director mod kind '%s'" % kind)


# --- wave flow ---------------------------------------------------------------
func _process(delta: float) -> void:
	if not running:
		return
	if _enrage_t > 0.0:
		_enrage_t -= delta
		if _enrage_t <= 0.0:
			_director_mods.erase("speed_mult")
			_director_mods.erase("dmg_mult")
	if in_build_phase:
		_build_t -= delta
		if _build_t <= 0.0:
			in_build_phase = false
			_start_wave(wave_number + 1)
		return
	if not _spawn_queue.is_empty() and alive_count < MAX_CONCURRENT:
		_spawn_t -= delta
		if _spawn_t <= 0.0:
			_spawn_t = SPAWN_INTERVAL
			_spawn_next()


func _start_build_phase() -> void:
	in_build_phase = true
	_build_t = INTERMISSION_TIME
	Game.build_phase_started.emit(INTERMISSION_TIME)
	_announce("BUILD PHASE — %ds. Forge your defenses." % int(INTERMISSION_TIME))


func _start_wave(n: int) -> void:
	wave_number = n
	Game.set("wave", n)
	refresh_nav(get_tree())  # map may have baked its navmesh during the build phase
	_refresh_doors()
	_director_mods.clear()
	_enrage_t = 0.0
	_spawn_queue = _build_queue(n)
	_spawn_t = 0.5
	Game.wave_started.emit(n)
	# Goal 2: wave horn — one-shot, once per wave start. (Brute spawns
	# play their own juggernaut horn later; that is a separate event.)
	Sfx.play_2d("wave_horn")
	_announce("WAVE %d" % n)
	if n % 5 == 0:
		_announce("!! JUGGERNAUT INBOUND !!")
	if n % 8 == 0:
		_announce("!! WARLORD INBOUND — BOSS FIGHT !!")


func _build_queue(n: int) -> Array[String]:
	# Gentle ramp (C1): wave 1 is a handful of grunts; each type unlocks
	# one at a time (rushers w2, marksmen w3, brute w5), counts grow slowly,
	# and the alive cap (MAX_CONCURRENT) paces the rest of the queue.
	# Goal 3: shredders w4 (melee pressure), suppressors w6 (area denial),
	# bulwarks w7 (shield wall), Warlord boss on every 8th wave (w8/16/24)
	# — exactly one per boss wave, never alongside a second boss.
	var q: Array[String] = []
	var grunts := mini(3 + 2 * n, 18)  # w1=5, w3=9, w8+=18 (was 4+2n cap 24)
	for i in grunts:
		q.append("grunt")
	if n >= 2:
		for i in mini(n / 2, 6):  # w2=1, w4=2, w8=4, w12+=6 (was 1+n/2 cap 8)
			q.append("rusher")
	if n >= 3:
		for i in mini(n / 3, 4):  # w3=1, w6=2, w9=3, w12+=4 (was cap 5)
			q.append("marksman")
	if n >= 4:
		for i in mini((n - 2) / 2, 4):  # w4=1, w6=2, w8=3, w10+=4
			q.append("shredder")
	if n >= 6:
		for i in mini((n - 3) / 3, 3):  # w6=1, w9=2, w12+=3
			q.append("suppressor")
	if n >= 7:
		for i in mini((n - 4) / 3, 3):  # w7=1, w10=2, w13+=3
			q.append("bulwark")
	if n % 5 == 0:
		q.append("brute")
		if n >= 10:
			q.append("brute")  # second juggernaut only from wave 10
	if n % 8 == 0:
		q.append("warlord")  # boss: exactly one, every 8th wave
	q.shuffle()
	return q


func on_enemy_died(_enemy: EnemyBase) -> void:
	alive_count = maxi(0, alive_count - 1)
	if running and not in_build_phase and _spawn_queue.is_empty() and alive_count <= 0:
		Game.wave_cleared.emit(wave_number)
		if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("wave_cleared", {"wave": wave_number})
		_announce("WAVE %d CLEARED" % wave_number)
		_start_build_phase()


# --- spawning -----------------------------------------------------------------
func _make_enemy(type_id: String) -> EnemyBase:
	match type_id:
		"rusher":
			return Rusher.new()
		"marksman":
			return Marksman.new()
		"brute":
			return Brute.new()
		"shredder":
			return Shredder.new()
		"suppressor":
			return Suppressor.new()
		"bulwark":
			return Bulwark.new()
		"warlord":
			return Warlord.new()
		_:
			return Grunt.new()


func _get_enemy(type_id: String) -> EnemyBase:
	var pool: Array = _pools[type_id]
	for e in pool:
		if not (e as EnemyBase).active:
			return e as EnemyBase
	var e := _make_enemy(type_id)
	pool.append(e)
	add_child(e)
	return e


func _refresh_doors() -> void:
	_doors.clear()
	for d in get_tree().get_nodes_in_group("spawn_door"):
		if d is Marker3D:
			_doors.append(d as Marker3D)


func _pick_door() -> Marker3D:
	if _doors.is_empty():
		return null
	# Prefer doors far from the player so spawns don't pop in his face.
	var pp := Vector3.ZERO
	var ps := get_tree().get_nodes_in_group("player")
	if not ps.is_empty():
		pp = (ps[0] as Node3D).global_position
	var best: Marker3D = _doors[_rng.randi_range(0, _doors.size() - 1)]
	var best_score := -1.0
	for i in 3:
		var d: Marker3D = _doors[_rng.randi_range(0, _doors.size() - 1)]
		var score: float = d.global_position.distance_to(pp) + _rng.randf() * 6.0
		if score > best_score:
			best_score = score
			best = d
	return best


func _spawn_next() -> void:
	var type_id: String = _spawn_queue.pop_front()
	var e := _get_enemy(type_id)
	var pos := Vector3(0, 0.5, 0)
	var door := _pick_door()
	if door != null:
		pos = door.global_position + Vector3(0, 0.5, 0)
	else:
		# No spawn doors: ring around the arena edge, away from the player.
		var ps := get_tree().get_nodes_in_group("player")
		var pp := Vector3.ZERO
		if not ps.is_empty():
			pp = (ps[0] as Node3D).global_position
		var ang := _rng.randf() * TAU
		pos = pp + Vector3(cos(ang) * 30.0, 0.5, sin(ang) * 30.0)
	e.activate(pos, wave_number, _director_mods)
	alive_count += 1
	if ClassDB.class_exists("DebrisPool"):
		DebrisPool.burst(pos, [Color(0.6, 0.55, 0.5)], 6, 2.5)


func _announce(text: String) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("add_killfeed"):
			h.call("add_killfeed", text)
