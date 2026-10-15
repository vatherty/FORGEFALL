# FORGEFALL — Forge Director (Worker 8: Forge system)
# The enemy side of the Forge: watches HOW the player fights each wave, then
# spends its own budget between waves to counter them. Drama included.
#
# Tracked per wave (1 s samples):
# - player position variance -> "camper" if variance < 25 m^2 over the wave
# - kill distances (attributed by watching foes vanish between samples) ->
#   "sniper" if > 50% of kills land beyond 25 m (min 3 kills)
# - fraction of samples within 3 m of cover -> "turtle" if > 50%
#
# On Game.wave_cleared: spends BASE_BUDGET + BUDGET_PER_WAVE * wave on
# counter-mods, applied via wave_manager.apply_director_mod(). Mod dicts use
# the wave manager's REAL schema: {kind:"spawn_extra", type, count},
# {kind:"weaken", taken_mult}, {kind:"grenadiers"}.
# - camper -> spawn_extra rusher x3 (+ "flank" hint) to flush them out
# - sniper -> smoke on the player's perch + spawn_extra marksman x2
# - turtle  -> grenadiers + spawn_extra grunt x2
# - balanced -> mixed grunts/rushers
# Announces "ENEMY ADAPTING" on the HUD for drama.
extends Node

#region TUNABLES
const SAMPLE_INTERVAL := 1.0
const CAMP_VARIANCE_M2 := 25.0
const SNIPE_KILL_DIST_M := 25.0
const SNIPE_FRACTION := 0.5
const MIN_KILLS_FOR_SNIPE := 3
const COVER_RADIUS_M := 3.0
const TURTLE_FRACTION := 0.5
const BASE_BUDGET := 100
const BUDGET_PER_WAVE := 25
const COST_RUSHERS := 60
const COST_MARKSMEN := 60
const COST_GRUNTS := 40
const COST_SMOKE := 40
const COST_GRENADIERS := 50
const COST_FLANK := 30
const COST_EXTRA_RUSHER := 25
const SMOKE_DURATION_SEC := 15.0
#endregion

var _active := false
var _wave := 0
var _pos_samples: Array[Vector3] = []
var _cover_ticks := 0
var _total_ticks := 0
var _kill_distances: Array[float] = []
var _enemy_dist: Dictionary = {} ## instance_id -> last distance to player
var _sample_timer := 0.0


func _ready() -> void:
	if Game.has_signal("wave_started"):
		Game.wave_started.connect(_on_wave_started)
	if Game.has_signal("wave_cleared"):
		Game.wave_cleared.connect(_on_wave_cleared)


func _on_wave_started(n: int) -> void:
	_wave = n
	_pos_samples.clear()
	_cover_ticks = 0
	_total_ticks = 0
	_kill_distances.clear()
	_enemy_dist.clear()
	_sample_timer = 0.0
	_active = true


func _process(delta: float) -> void:
	if not _active:
		return
	_sample_timer += delta
	if _sample_timer >= SAMPLE_INTERVAL:
		_sample_timer = 0.0
		_sample()


func _player() -> Node3D:
	return get_tree().get_first_node_in_group("player") as Node3D


func _sample() -> void:
	var player := _player()
	if player == null:
		return
	var pp := player.global_position
	_pos_samples.append(pp)
	_total_ticks += 1
	for c in get_tree().get_nodes_in_group("cover"):
		if c is Node3D and pp.distance_to((c as Node3D).global_position) <= COVER_RADIUS_M:
			_cover_ticks += 1
			break
	# Snapshot foe distances; anyone who vanished since last sample counts
	# as a kill at their last known distance (despawns included — heuristic).
	var now := {}
	for e in _foes():
		if e is Node3D:
			now[(e as Node).get_instance_id()] = pp.distance_to((e as Node3D).global_position)
	for id in _enemy_dist:
		if not now.has(id):
			_kill_distances.append(float(_enemy_dist[id]))
	_enemy_dist = now


func _foes() -> Array:
	var out: Array = []
	var seen := {}
	for group in ["enemy", "enemies"]:
		for e in get_tree().get_nodes_in_group(group):
			var id := (e as Node).get_instance_id()
			if not seen.has(id):
				seen[id] = true
				out.append(e)
	return out


func _on_wave_cleared(n: int) -> void:
	_active = false
	var profile := _classify()
	var budget := BASE_BUDGET + BUDGET_PER_WAVE * n
	var plan := _plan(profile, budget)
	var spent := 0
	for item in plan:
		var entry := item as Dictionary
		spent += int(entry.get("cost", 0))
		_apply(entry)
	_announce(profile)
	print("ForgeDirector: wave %d profile=%s spent %d/%d budget" % [n, profile, spent, budget])


func _classify() -> String:
	var camping := _pos_samples.size() >= 4 and _variance(_pos_samples) < CAMP_VARIANCE_M2
	var sniping := false
	if _kill_distances.size() >= MIN_KILLS_FOR_SNIPE:
		var far := 0
		for d in _kill_distances:
			if d > SNIPE_KILL_DIST_M:
				far += 1
		sniping = float(far) / float(_kill_distances.size()) > SNIPE_FRACTION
	var turtling := _total_ticks > 0 and float(_cover_ticks) / float(_total_ticks) > TURTLE_FRACTION
	if camping:
		return "camper"
	if sniping:
		return "sniper"
	if turtling:
		return "turtle"
	return "balanced"


func _variance(samples: Array[Vector3]) -> float:
	if samples.size() < 2:
		return 999999.0
	var mean := Vector3.ZERO
	for s in samples:
		mean += s
	mean /= float(samples.size())
	var acc := 0.0
	for s in samples:
		acc += mean.distance_squared_to(s)
	return acc / float(samples.size())


## Greedy plan: candidates in priority order, included while budget lasts.
## Each entry: {"cost": int, "mod": Dictionary} or {"cost": int, "fx": "smoke"}.
func _plan(profile: String, budget: int) -> Array:
	var cands: Array = []
	match profile:
		"camper":
			cands = [
				{"cost": COST_RUSHERS, "mod": {"kind": "spawn_extra", "type": "rusher", "count": 3, "flank": true}},
				{"cost": COST_FLANK, "mod": {"kind": "spawn_extra", "type": "rusher", "count": 1, "flank": true}},
				{"cost": COST_GRUNTS, "mod": {"kind": "spawn_extra", "type": "grunt", "count": 2}},
			]
		"sniper":
			cands = [
				{"cost": COST_SMOKE, "fx": "smoke"},
				{"cost": COST_MARKSMEN, "mod": {"kind": "spawn_extra", "type": "marksman", "count": 2}},
				{"cost": COST_GRUNTS, "mod": {"kind": "spawn_extra", "type": "grunt", "count": 2}},
			]
		"turtle":
			cands = [
				{"cost": COST_GRENADIERS, "mod": {"kind": "grenadiers"}},
				{"cost": COST_GRUNTS, "mod": {"kind": "spawn_extra", "type": "grunt", "count": 2}},
				{"cost": COST_EXTRA_RUSHER * 2, "mod": {"kind": "spawn_extra", "type": "rusher", "count": 2}},
			]
		_:
			cands = [
				{"cost": COST_GRUNTS, "mod": {"kind": "spawn_extra", "type": "grunt", "count": 2}},
				{"cost": COST_EXTRA_RUSHER, "mod": {"kind": "spawn_extra", "type": "rusher", "count": 1}},
			]
	var plan: Array = []
	var left := budget
	for c in cands:
		var entry := c as Dictionary
		var cost := int(entry.get("cost", 0))
		if cost <= left:
			plan.append(entry)
			left -= cost
	return plan


func _apply(entry: Dictionary) -> void:
	if entry.has("fx") and str(entry["fx"]) == "smoke":
		_director_smoke()
		return
	var wm = get_tree().get_first_node_in_group("wave_manager")
	var mod: Dictionary = entry.get("mod", {})
	if wm != null and wm.has_method("apply_director_mod"):
		wm.apply_director_mod(mod)
	else:
		push_warning("ForgeDirector: no wave_manager for %s" % str(mod))


## The wave manager has no smoke mod, so the director deploys it directly
## through the Forge's own smoke spawner — right on the player's perch.
func _director_smoke() -> void:
	var player := _player()
	var root := get_tree().current_scene
	if player == null or root == null:
		return
	ForgeBuilder.fx_smoke(root, player.global_position, SMOKE_DURATION_SEC)


func _announce(profile: String) -> void:
	var hud = get_tree().get_first_node_in_group("hud")
	if hud == null or not hud.has_method("announce"):
		return
	var sub := ""
	match profile:
		"camper":
			sub = "No more camping — rushers flanking your nest."
		"sniper":
			sub = "Smoke on your perch. Their marksmen are moving up."
		"turtle":
			sub = "Grenadiers inbound. That wall won't save you."
		_:
			sub = "Fresh meat for the grinder."
	hud.announce("ENEMY ADAPTING", sub)
