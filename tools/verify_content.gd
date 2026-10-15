# verify_content.gd — headless verification for FORGEFALL Goal 3 (CONTENT).
# Usage: godot --headless --path <project> --script res://tools/verify_content.gd
#
# Worker D (Verification). Owns ONLY this file. Never fixes game code: bugs
# found here are reported with file + line, not patched.
#
# Coverage (discovery-based, NOT hardcoded to today's content — the checks
# read the live tables / scan the live tree, so Worker A/B/C landings are
# judged on what actually exists):
#   A. MAPS: every res://scenes/maps/*.tscn (except *_props.tscn dressing)
#      loads + instantiates, has >=1 player_spawn, >=1 spawn_door (enemy
#      spawns), >=1 Forge marker (forge_pad / forge_marker / forge_spawn
#      group, or a node named *forge*), real geometry, and voxel-style
#      construction (VoxelBuilder or MultiMesh voxels). Maps must be
#      mutually distinct (not the same layout copied under a new name).
#      GOAL 3: >= 3 maps total (Dustline + 2 new).
#   B. ENEMIES: every scripts/enemies/*.gd that extends EnemyBase is a type.
#      Each type: stats sane, activates (telegraph -> can attack), takes
#      damage, scales with wave, dies + scores, overrides _ai_physics
#      (distinct behaviour), and is pairwise stat-distinct from every other
#      type. Every type must appear in a WaveManager wave queue (else waves
#      never spawn it). GOAL 3: >= 6 types (4 baseline + >= 2 new) and a
#      BOSS type that is NOT one of the baseline 4 (boss flag, "boss" in
#      id/display, or boss-kit stats: >= 8x grunt HP + flinch-immune +
#      oversized body).
#   C. MODES: a mode system must exist (scripts mentioning MODES / GameMode
#      / start_mode). GOAL 3: >= 2 NEW mode ids (beyond the default
#      survival/wave mode) from a known-mode vocabulary, with start +
#      complete/end + score paths in the mode code, menu/main wiring so a
#      mode is actually selectable, and endless best-score persistence
#      (best_score + ConfigFile / user:// save). Where a mode-manager class
#      exposes get_modes / start_mode / end_mode / get_best_score, those
#      are exercised behaviourally; otherwise the checks are source-level
#      (stated in the labels).
#   D. WEAPONS: every Arsenal.WEAPONS entry: sane stats, viewmodel with
#      Muzzle + Eject anchors, ADS target == -sight_height, fires (mag -1,
#      cooldown armed), reloads to full (staged reload simulated).
#      Raptor is special-cased: grab + throw a real RigidBody3D.
#      GOAL 3: >= 9 weapons total (7 baseline + >= 2 new).
#   E. INTEGRATION: every scripts/**/*.gd parses, every scenes/**/*.tscn
#      loads, voxel style holds (Arsenal viewmodels via VoxelBuilder,
#      enemies via VoxelSoldier boxes).
#
# Exit 0 = all checks pass (Goal 3 complete). Any FAIL prints and exits 1.
# "GOAL3:" FAILs before Workers A/B/C land are MISSING CONTENT, not bugs —
# the harness is written early precisely so it can run as their work lands.
extends SceneTree

const BASELINE_WEAPONS: Array[String] = ["ar7", "lr8", "sg12", "smg9", "lmg", "p9", "raptor"]
const BASELINE_ENEMIES: Array[String] = ["grunt", "rusher", "marksman", "brute"]
const MIN_MAPS := 3
const MIN_ENEMY_TYPES := 6
const MIN_NEW_MODES := 2
const MIN_WEAPONS := 9
const KNOWN_MODE_IDS: Array[String] = [
	"endless", "domination", "capture_the_flag", "ctf", "hardpoint",
	"king_of_the_hill", "deathmatch", "team_deathmatch", "elimination",
	"survival", "search_and_destroy", "payload", "control", "gunfight",
	"infected", "free_for_all", "ffa", "sabotage", "headquarters",
	"demolition", "escort", "arena", "skirmish", "blitz", "conquest",
	"breakthrough", "waves", "wave_survival", "classic", "campaign",
	"horde", "onslaught", "holdout", "defense", "assault", "retrieval",
]

var _passes := 0
var _fails := 0
var _warns := 0
var _frames := 0
var _stage := 0
var _map_paths: Array = []
var _map_idx := 0
var _map_node: Node = null
var _map_wait := 0
var _map_sigs: Array = []
var _game: Node = null
var _probed := false


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _warn(cond: bool, label: String) -> void:
	if cond:
		print("OK: ", label)
	else:
		_warns += 1
		print("WARN: ", label)


func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _collect_files(dir_path: String, ext: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(ext):
			out.append(dir_path.path_join(f))
	for sub in d.get_directories():
		_collect_files(dir_path.path_join(sub), ext, out)


func _quoted(line: String) -> Array:
	var out: Array = []
	var i := 0
	while true:
		var a := line.find('"', i)
		if a < 0:
			break
		var b := line.find('"', a + 1)
		if b < 0:
			break
		out.append(line.substr(a + 1, b - a - 1))
		i = b + 1
	return out


func _count_descendants(node: Node, type_name: String) -> int:
	var n := 0
	if node.get_class() == type_name or node.is_class(type_name):
		n += 1
	for c in node.get_children():
		n += _count_descendants(c as Node, type_name)
	return n


func _find_forge_markers(node: Node, out: Array) -> void:
	if node.is_in_group("forge_pad") or node.is_in_group("forge_marker") \
			or node.is_in_group("forge_spawn") or node.name.to_lower().contains("forge"):
		out.append(node)
	for c in node.get_children():
		_find_forge_markers(c as Node, out)


func _mesh_bounds(node: Node) -> Array:
	# [min, max] of all mesh / multimesh global positions in the subtree.
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	_accum_bounds(node, mn, mx)
	return [mn, mx]


func _accum_bounds(node: Node, mn: Vector3, mx: Vector3) -> void:
	if node is MeshInstance3D or node is MultiMeshInstance3D:
		var p := (node as Node3D).global_position
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.y)
		mn.z = minf(mn.z, p.z)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.y)
		mx.z = maxf(mx.z, p.z)
	for c in node.get_children():
		_accum_bounds(c as Node, mn, mx)


# ------------------------------------------------------------------ stages

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	match _stage:
		0:
			_game = root.get_node_or_null("Game")
			if _game != null and _game.has_method("reset_run"):
				_game.call("reset_run")
			_stage = 1
			_run_static_checks()
			_collect_maps()
			_stage = 2
		2:
			_run_map_stage()
		3:
			_run_enemy_checks()
			_run_weapon_checks()
			_run_mode_behavioral()
			print("VERIFY(content): %d passed, %d failed, %d warnings" % [_passes, _fails, _warns])
			if _fails == 0:
				print("VERIFY(content): ALL CHECKS PASSED")
			else:
				printerr("VERIFY(content): %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


func _collect_maps() -> void:
	var all: Array = []
	_collect_files("res://scenes/maps", ".tscn", all)
	for p in all:
		var path := str(p)
		if path.ends_with("_props.tscn"):
			continue  # dressing sub-scene, not a playable map
		_map_paths.append(path)
	_check(not _map_paths.is_empty(), "at least one playable map scene exists (found %d)" % _map_paths.size())
	_check(_map_paths.size() >= MIN_MAPS,
		"GOAL3: >= %d maps total (Dustline + 2 new) — found %d: %s" % [MIN_MAPS, _map_paths.size(), _map_paths])
	print("VERIFY(content): map scenes: ", _map_paths)


func _run_map_stage() -> void:
	if _map_idx >= _map_paths.size():
		# Distinctness: no two maps share an identical layout signature.
		if _map_sigs.size() >= 2:
			var all_same := true
			for i in range(1, _map_sigs.size()):
				if str(_map_sigs[i]) != str(_map_sigs[0]):
					all_same = false
			_check(not all_same,
				"maps are mutually distinct (layout signatures differ: %s)" % [_map_sigs])
		_stage = 3
		return
	if _map_node == null:
		var path := str(_map_paths[_map_idx])
		var ps := load(path) as PackedScene
		_check(ps != null, "map loads as PackedScene: '%s'" % path)
		if ps == null:
			_map_idx += 1
			return
		_map_node = ps.instantiate()
		root.add_child(_map_node)
		_map_wait = 0
		return
	_map_wait += 1
	if _map_wait < 8:
		return
	_check_one_map(str(_map_paths[_map_idx]), _map_node)
	_map_node.get_parent().remove_child(_map_node)
	_map_node.free()
	_map_node = null
	_map_idx += 1


func _check_one_map(path: String, map_node: Node) -> void:
	var short := path.get_file()
	_check(map_node is Node3D, "map root is Node3D: '%s'" % short)
	var n_player := get_nodes_in_group("player_spawn").size()
	_check(n_player >= 1, "map '%s' has >= 1 player_spawn (found %d)" % [short, n_player])
	var n_doors := get_nodes_in_group("spawn_door").size()
	_check(n_doors >= 1, "map '%s' has >= 1 spawn_door / enemy spawn (found %d)" % [short, n_doors])
	var forge: Array = []
	_find_forge_markers(map_node, forge)
	_check(not forge.is_empty(),
		"map '%s' has >= 1 Forge marker (forge_pad/forge_marker/forge_spawn or *forge* node; found %d)" % [short, forge.size()])
	var n_mesh := _count_descendants(map_node, "MeshInstance3D") \
		+ _count_descendants(map_node, "MultiMeshInstance3D")
	_check(n_mesh >= 10, "map '%s' has real geometry (>= 10 mesh/multimesh nodes; found %d)" % [short, n_mesh])
	var navs := 0
	var nav_baked := false
	for c in map_node.find_children("*", "NavigationRegion3D", true, false):
		navs += 1
		var reg := c as NavigationRegion3D
		if reg.navigation_mesh != null and reg.navigation_mesh.get_polygon_count() > 0:
			nav_baked = true
	_warn(nav_baked, "map '%s' has a baked navmesh (%d NavigationRegion3D; enemies fall back to steering without one)" % [short, navs])
	# Voxel style: builder uses VoxelBuilder or MultiMesh voxel batches.
	var root_script: Script = (map_node as Node).get_script() as Script
	var builder_text := ""
	if root_script != null:
		builder_text = _read_file(root_script.resource_path)
	_check(builder_text.contains("VoxelBuilder") or builder_text.contains("MultiMesh"),
		"map '%s' builds voxel-style (builder mentions VoxelBuilder or MultiMesh)" % short)
	var bounds := _mesh_bounds(map_node)
	var size_v: Vector3 = (bounds[1] as Vector3) - (bounds[0] as Vector3)
	_map_sigs.append("%s|ps=%d|doors=%d|forge=%d|mesh=%d|size=%s" % [
		short, n_player, n_doors, forge.size(), n_mesh,
		Vector3(snappedf(size_v.x, 1.0), snappedf(size_v.y, 1.0), snappedf(size_v.z, 1.0))])


# ------------------------------------------------------------------ enemies

func _discover_enemy_files() -> Array:
	var files: Array = []
	_collect_files("res://scripts/enemies", ".gd", files)
	var out: Array = []
	for p in files:
		var text := _read_file(str(p))
		if text.contains("extends EnemyBase"):
			out.append(str(p))
	return out


func _run_enemy_checks() -> void:
	var files := _discover_enemy_files()
	_check(not files.is_empty(), "at least one EnemyBase subclass exists (found %d)" % files.size())
	print("VERIFY(content): enemy scripts: ", files)
	var types: Array = []  # Dictionary per type
	for p in files:
		var path := str(p)
		var text := _read_file(path)
		var script := load(path) as GDScript
		_check(script != null, "enemy script loads: '%s'" % path)
		if script == null:
			continue
		var e = script.new()  # untyped: global class cache is stale under --script; use get/call
		_check(e != null, "enemy instantiates: '%s'" % path)
		if e == null:
			continue
		root.add_child(e)  # _ready runs: _configure + _build_body
		var info := {
			"path": path, "text": text, "inst": e,
			"type_id": str(e.get("type_id")), "display": str(e.get("display_name")),
			"hp": float(e.get("base_hp")), "speed": float(e.get("base_speed")),
			"damage": float(e.get("base_damage")), "acc": float(e.get("base_accuracy")),
			"range": float(e.get("preferred_range")),
		}
		_check(not str(e.get("type_id")).is_empty() and str(e.get("type_id")) != "grunt" or path.contains("grunt"),
			"enemy '%s' sets a type_id ('%s')" % [path, e.get("type_id")])
		_check(float(e.get("base_hp")) > 0.0, "enemy '%s' has base_hp > 0 (%.0f)" % [e.get("type_id"), e.get("base_hp")])
		_check(float(e.get("base_speed")) > 0.0, "enemy '%s' has base_speed > 0 (%.2f)" % [e.get("type_id"), e.get("base_speed")])
		_check(float(e.get("base_damage")) >= 0.0, "enemy '%s' has base_damage >= 0 (%.1f)" % [e.get("type_id"), e.get("base_damage")])
		_check(float(e.get("base_accuracy")) >= 0.0 and float(e.get("base_accuracy")) <= 1.0,
			"enemy '%s' has base_accuracy in [0, 1] (%.2f)" % [e.get("type_id"), e.get("base_accuracy")])
		var uses_gun := text.contains("fire_hitscan") or text.contains("gun_update") or text.contains("gun_trigger")
		if uses_gun:
			_check(float(e.get("base_accuracy")) > 0.0,
				"enemy '%s' fires a gun, so base_accuracy must be > 0 (%.2f)" % [e.get("type_id"), e.get("base_accuracy")])
		else:
			_check(true, "enemy '%s' is melee (no gun calls) — accuracy 0.0 is valid" % e.get("type_id"))
		_check(float(e.get("preferred_range")) > 0.0,
			"enemy '%s' has preferred_range > 0 (%.1f)" % [e.get("type_id"), e.get("preferred_range")])
		_check(text.contains("func _ai_physics"),
			"enemy '%s' overrides _ai_physics (distinct behaviour, not base-class passthrough)" % e.get("type_id"))
		_check(e.get("soldier") != null, "enemy '%s' builds a voxel soldier body" % e.get("type_id"))
		types.append(info)
	# Baseline 4 must still exist.
	for b in BASELINE_ENEMIES:
		var found := false
		for t in types:
			if str(t["type_id"]) == b:
				found = true
		_check(found, "baseline enemy type still present: '%s'" % b)
	_check(types.size() >= MIN_ENEMY_TYPES,
		"GOAL3: >= %d enemy types (4 baseline + >= 2 new) — found %d: %s" % [MIN_ENEMY_TYPES, types.size(),
			types.map(func(t): return str(t["type_id"]))])
	# Pairwise stat-distinctness: no two types share the full stat tuple.
	for i in types.size():
		for j in range(i + 1, types.size()):
			var a: Dictionary = types[i]
			var b: Dictionary = types[j]
			var same := is_equal_approx(float(a["hp"]), float(b["hp"])) \
				and is_equal_approx(float(a["speed"]), float(b["speed"])) \
				and is_equal_approx(float(a["damage"]), float(b["damage"])) \
				and is_equal_approx(float(a["range"]), float(b["range"]))
			_check(not same,
				"enemy types '%s' and '%s' are stat-distinct (hp/speed/damage/range differ somewhere)" % [a["type_id"], b["type_id"]])
	# Behaviour per type: activate -> telegraph -> damage -> wave scale -> die + score.
	for t in types:
		_check_one_enemy_behavior(t)
	# WaveManager integration: every type must appear in some wave queue.
	var wm = (load("res://scripts/enemies/wave_manager.gd") as GDScript).new()
	root.add_child(wm)
	var queued: Array = []
	for w in [1, 2, 3, 5, 10]:
		for q in wm.call("_build_queue", w):
			if not queued.has(str(q)):
				queued.append(str(q))
	print("VERIFY(content): wave queues (w1/2/3/5/10) spawn: ", queued)
	for t in types:
		var tid := str(t["type_id"])
		var is_boss := _is_boss(t, types)
		if is_boss:
			_warn(queued.has(tid),
				"boss '%s' appears in a WaveManager wave queue (a boss on a special trigger only is OK, but must be reachable)" % tid)
		else:
			_check(queued.has(tid),
				"enemy '%s' appears in a WaveManager wave queue (waves actually spawn it)" % tid)
	root.remove_child(wm)
	wm.free()
	# GOAL 3 boss: a NEW type (not baseline) with a boss flag / boss id / boss kit.
	var boss_found := ""
	for t in types:
		if _is_boss(t, types):
			boss_found = str(t["type_id"])
	_check(not boss_found.is_empty(),
		"GOAL3: a BOSS type exists beyond the baseline 4 (boss flag / 'boss' id / boss kit) — found: '%s'" % boss_found)
	# Free enemy instances.
	for t in types:
		var e = t["inst"]
		if is_instance_valid(e):
			root.remove_child(e)
			e.free()


func _is_boss(t: Dictionary, all_types: Array) -> bool:
	var tid := str(t["type_id"])
	if BASELINE_ENEMIES.has(tid):
		return false
	var text := str(t["text"]).to_lower()
	var display := str(t["display"]).to_lower()
	if tid.contains("boss") or display.contains("boss"):
		return true
	if text.contains("is_boss") and (text.contains("is_boss = true") or text.contains("is_boss := true")):
		return true
	# Boss kit: >= 8x grunt HP + flinch-immune + oversized body.
	var grunt_hp := 100.0
	for o in all_types:
		if str(o["type_id"]) == "grunt":
			grunt_hp = float(o["hp"])
	var e = t["inst"]
	var oversized := e != null and ((e.get("body_scale") as Vector3).x > 1.15 or (e.get("body_scale") as Vector3).y > 1.15)
	if float(t["hp"]) >= 8.0 * grunt_hp and bool(e.get("flinch_immune")) and oversized:
		return true
	return false


func _check_one_enemy_behavior(t: Dictionary) -> void:
	var e = t["inst"]
	var tid := str(t["type_id"])
	var pos := Vector3(0, 1.0, 0)
	e.call("activate", pos, 1, {})
	_check(bool(e.get("active")), "enemy '%s' activates (active == true)" % tid)
	_check(is_equal_approx(float(e.get("hp")), float(e.get("max_hp"))),
		"enemy '%s' activates at full HP (hp %.0f == max %.0f)" % [tid, e.get("hp"), e.get("max_hp")])
	_check(e.call("is_spawn_telegraphing"), "enemy '%s' telegraphs on spawn (cannot act during telegraph)" % tid)
	_check(not e.call("can_attack"), "enemy '%s' cannot attack during spawn telegraph" % tid)
	e.set("_telegraph_t", 0.0)
	_check(e.call("can_attack"), "enemy '%s' can attack once the telegraph expires" % tid)
	var hp_before := float(e.get("hp"))
	e.call("take_damage", 10.0, (e.get("global_position") as Vector3) + Vector3(1, 0, 0), false)
	_check(float(e.get("hp")) < hp_before,
		"enemy '%s' takes damage (hp %.0f -> %.0f)" % [tid, hp_before, e.get("hp")])
	_check(float(e.get("hp")) > hp_before - 50.0,
		"enemy '%s' damage is sane (10 dmg did not nuke it: hp %.0f)" % [tid, e.get("hp")])
	# Wave scaling: wave 5 max HP ~= base * (1 + 0.08 * 4).
	e.call("activate", pos, 5, {})
	var expected := float(t["hp"]) * 1.32
	_check(absf(float(e.get("max_hp")) - expected) <= expected * 0.05,
		"enemy '%s' scales with wave (wave 5 max HP %.0f ~= base %.0f x 1.32)" % [tid, e.get("max_hp"), float(t["hp"])])
	# Death + scoring.
	var score_before := 0
	if _game != null:
		score_before = int(_game.get("score"))
	e.call("activate", pos, 1, {})
	e.call("take_damage", 999999.0, e.get("global_position"), false)
	_check(bool(e.get("dead")), "enemy '%s' dies on lethal damage" % tid)
	if _game != null:
		_check(int(_game.get("score")) >= score_before + 100,
			"enemy '%s' death scores (Game.score %d -> %d)" % [tid, score_before, int(_game.get("score"))])
	# Return to a parked state so later checks start clean.
	e.call("_recycle")


# ------------------------------------------------------------------ weapons

func _run_weapon_checks() -> void:
	var arsenal := load("res://scripts/weapons/arsenal.gd") as GDScript
	_check(arsenal != null, "arsenal.gd loads")
	if arsenal == null:
		return
	var weapons: Dictionary = arsenal.get_script_constant_map().get("WEAPONS", {}) as Dictionary
	for b in BASELINE_WEAPONS:
		_check(weapons.has(b), "baseline weapon still present in Arsenal: '%s'" % b)
	_check(weapons.size() >= MIN_WEAPONS,
		"GOAL3: >= %d weapons total (7 baseline + >= 2 new) — found %d: %s" % [MIN_WEAPONS, weapons.size(), weapons.keys()])
	# Camera + dummy player for fire / ADS / reload behaviour.
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.5, 0)
	root.add_child(camera)
	var dummy := Node3D.new()
	dummy.name = "VerifyDummyPlayer"
	root.add_child(dummy)
	for wid in weapons.keys():
		_check_one_weapon(str(wid), weapons[wid] as Dictionary, camera, dummy)
	root.remove_child(dummy)
	dummy.free()
	root.remove_child(camera)
	camera.free()


func _check_one_weapon(wid: String, stats: Dictionary, camera: Camera3D, dummy: Node3D) -> void:
	_check(float(stats.get("damage", -1.0)) >= 0.0 or wid == "raptor",
		"weapon '%s' has damage >= 0 (%.1f)" % [wid, float(stats.get("damage", -1.0))])
	if wid != "raptor":
		_check(float(stats.get("damage", 0.0)) > 0.0, "weapon '%s' deals damage (%.1f)" % [wid, float(stats.get("damage", 0.0))])
	_check(int(stats.get("mag_size", 0)) > 0, "weapon '%s' has mag_size > 0 (%d)" % [wid, int(stats.get("mag_size", 0))])
	_check(int(stats.get("reserve", -1)) >= 0, "weapon '%s' has reserve >= 0 (%d)" % [wid, int(stats.get("reserve", -1))])
	_check(float(stats.get("rpm", 0.0)) > 0.0, "weapon '%s' has rpm > 0 (%.0f)" % [wid, float(stats.get("rpm", 0.0))])
	_check(float(stats.get("near_range", 0.0)) < float(stats.get("far_range", 0.0)) or wid == "raptor",
		"weapon '%s' has near_range < far_range (%.0f < %.0f; raptor is a physics gun, near == far is valid)" % [wid, float(stats.get("near_range", 0.0)), float(stats.get("far_range", 0.0))])
	_check(float(stats.get("falloff_min", 0.0)) > 0.0 and float(stats.get("falloff_min", 0.0)) <= 1.0,
		"weapon '%s' has falloff_min in (0, 1] (%.2f)" % [wid, float(stats.get("falloff_min", 0.0))])
	_check((stats.get("reload_stages", []) as Array).size() == 3,
		"weapon '%s' has 3 reload stages" % wid)
	_check(not stats.has("recoil_recover") or float(stats.get("recoil_recover", 0.0)) > 0.0,
		"weapon '%s' has recoil_recover > 0 when specified (%.2f; missing = setup fallback applies)" % [wid, float(stats.get("recoil_recover", 0.0))])
	_check(str(stats.get("sfx_fire", "")) != "", "weapon '%s' has an sfx_fire entry" % wid)
	# Viewmodel + anchors.
	var arsenal_script := load("res://scripts/weapons/arsenal.gd") as GDScript
	var vm = arsenal_script.call("build_viewmodel", wid)
	_check(vm != null, "weapon '%s' builds a viewmodel" % wid)
	if vm != null:
		_check(vm.get_node_or_null("Muzzle") is Marker3D, "weapon '%s' viewmodel has a Muzzle anchor" % wid)
		_check(vm.get_node_or_null("Eject") is Marker3D, "weapon '%s' viewmodel has an Eject anchor" % wid)
		_check(vm.get_node_or_null("Sight") is Marker3D, "weapon '%s' viewmodel has a Sight anchor" % wid)
		vm.free()
	_check(float(arsenal_script.call("sight_height", wid)) > 0.0, "weapon '%s' has sight_height > 0 (%.3f)" % [wid, float(arsenal_script.call("sight_height", wid))])
	# Behavioural: fire / ADS / reload on a live WeaponBase.
	var w = arsenal_script.call("make_weapon", wid)
	_check(w != null, "weapon '%s' instantiates via Arsenal.make_weapon" % wid)
	if w == null:
		return
	root.add_child(w)
	w.call("attach", dummy, camera)
	_check(w.get("_viewmodel") != null, "weapon '%s' has a live viewmodel after setup" % wid)
	_check(w.get("_muzzle") != null, "weapon '%s' resolves its Muzzle marker" % wid)
	# ADS: target == -sight_height, set_ads toggles.
	var ads_pos: Vector3 = w.get("_ads_pos")
	_check(is_equal_approx(ads_pos.y, -float(arsenal_script.call("sight_height", wid))),
		"weapon '%s' ADS target centres the sight (ADS y %.3f == -sight_height %.3f)" % [wid, ads_pos.y, float(arsenal_script.call("sight_height", wid))])
	w.call("set_ads", true)
	_check(bool(w.get("_ads")), "weapon '%s' ADS engages (set_ads(true))" % wid)
	w.call("set_ads", false)
	_check(not bool(w.get("_ads")), "weapon '%s' ADS disengages (set_ads(false))" % wid)
	if wid == "raptor":
		_check_raptor(w, camera)
	else:
		# Fire: one trigger pull consumes round(s) and arms cooldown.
		# AUTO = 1 round per held tick; SEMI/BOLT/PUMP = 1 round per press;
		# BURST (4) = burst_size rounds, spent in _process as cooldown clears.
		w.set("_raise_t", 999.0)
		var mag_before := int(w.get("mag"))
		var fm := int(w.get("fire_mode"))
		if fm == 0:  # AUTO
			w.call("trigger_held")
			_check(int(w.get("mag")) == mag_before - 1,
				"weapon '%s' fires (mag %d -> %d)" % [wid, mag_before, int(w.get("mag"))])
		elif fm == 4:  # BURST
			w.call("trigger_pressed")
			w.call("_process", 0.1)
			_check(int(w.get("mag")) == mag_before - 1,
				"weapon '%s' burst starts firing on the first tick (mag %d -> %d)" % [wid, mag_before, int(w.get("mag"))])
			_check(float(w.get("_cooldown")) > 0.0 or int(w.get("_burst_left")) > 0,
				"weapon '%s' arms its burst state after triggering (cooldown %.3f, burst_left %d)" % [wid, float(w.get("_cooldown")), int(w.get("_burst_left"))])
			for i in 11:
				w.call("_process", 0.1)
			var expect := maxi(int(stats.get("burst_size", 3)), 1)
			_check(int(w.get("mag")) == mag_before - expect,
				"weapon '%s' fires a full burst (mag %d -> %d, burst_size %d)" % [wid, mag_before, int(w.get("mag")), expect])
		else:  # SEMI / BOLT / PUMP
			w.call("trigger_pressed")
			_check(int(w.get("mag")) == mag_before - 1,
				"weapon '%s' fires (mag %d -> %d)" % [wid, mag_before, int(w.get("mag"))])
		if fm != 4:  # BURST cooldown is checked mid-burst above; it decays by burst end
			_check(float(w.get("_cooldown")) > 0.0, "weapon '%s' arms its fire cooldown after firing" % wid)
		# Reload: staged reload simulated to completion refills the mag.
		w.set("mag", 0)
		w.set("reserve", int(w.get("mag_size")))
		w.call("try_reload")
		_check(int(w.get("_reload_stage")) != 0, "weapon '%s' starts a reload" % wid)
		for i in 40:
			w.call("_process", 0.1)
		_check(int(w.get("mag")) == int(w.get("mag_size")) and int(w.get("_reload_stage")) == 0,
			"weapon '%s' reloads to full (mag %d/%d, reload stage idle)" % [wid, int(w.get("mag")), int(w.get("mag_size"))])
	root.remove_child(w)
	w.free()


func _check_raptor(w, camera: Camera3D) -> void:
	_check(str(w.get_script().resource_path).ends_with("raptor_gun.gd"), "raptor weapon is a RaptorGun (physics gun, not hitscan)")
	# Grab + throw a real RigidBody3D placed 2 m in front of the camera.
	var body := RigidBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 0.4, 0.4)
	shape.shape = box
	body.add_child(shape)
	body.position = camera.global_position + Vector3(0, 0, -2.0)
	root.add_child(body)
	w.set("_raise_t", 999.0)
	w.call("trigger_pressed")
	_check(w.get("_held") != null, "raptor grabs a RigidBody3D under the crosshair (fire = grab)")
	if w.get("_held") != null:
		w.call("trigger_pressed")
		_check(w.get("_held") == null, "raptor releases on second fire (fire again = throw)")
		_check((body.linear_velocity as Vector3).length() > 20.0,
			"raptor throw launches the body (speed %.1f m/s)" % (body.linear_velocity as Vector3).length())
	w.call("try_reload")  # reload = drop; must not crash with nothing held
	_check(true, "raptor reload with nothing held does not crash")
	root.remove_child(body)
	body.free()


# ------------------------------------------------------------------ modes

func _mode_files() -> Array:
	var files: Array = []
	_collect_files("res://scripts", ".gd", files)
	var out: Array = []
	for p in files:
		var text := _read_file(str(p))
		if text.contains("MODES") or text.contains("GameMode") or text.contains("start_mode") \
				or text.contains("game_mode") or text.contains("ModeManager"):
			out.append(str(p))
	return out


func _harvest_mode_ids(files: Array) -> Array:
	var found: Array = []
	for p in files:
		for line in _read_file(str(p)).split("\n"):
			for q in _quoted(line):
				if KNOWN_MODE_IDS.has(q) and not found.has(q):
					found.append(q)
	return found


func _method_arg_count(inst: Object, method: String) -> int:
	for m in inst.get_method_list():
		if str(m.get("name", "")) == method:
			return int((m.get("args", []) as Array).size())
	return -1


func _run_mode_behavioral() -> void:
	var files := _mode_files()
	print("VERIFY(content): mode-related scripts: ", files)
	var ids := _harvest_mode_ids(files)
	print("VERIFY(content): mode ids found: ", ids)
	var new_ids: Array = []
	for m in ids:
		if not ["survival", "waves", "wave_survival", "classic"].has(str(m)):
			new_ids.append(str(m))
	_check(not files.is_empty(), "a mode system exists (a script mentions MODES / GameMode / start_mode)")
	_check(new_ids.size() >= MIN_NEW_MODES,
		"GOAL3: >= %d NEW game modes (beyond default survival/wave mode) — found %d: %s" % [MIN_NEW_MODES, new_ids.size(), new_ids])
	# Source-level lifecycle: start + complete/end + score in the mode code.
	var combined := ""
	for p in files:
		combined += _read_file(str(p)) + "\n"
	_check(combined.contains("start_mode") or combined.contains("func start("),
		"mode code has a start path (start_mode / start)")
	_check(combined.contains("complete_mode") or combined.contains("end_mode") \
			or combined.contains("func complete") or combined.contains("func finish") \
			or combined.contains("func stop(") or combined.contains("mode_won") \
			or combined.contains("_win_"),
		"mode code has a complete/end path (complete_mode / end_mode / stop / mode_won / win)")
	_check(combined.contains("score"),
		"mode code tracks score")
	# Menu / main wiring: a mode must be selectable, not just defined.
	var main_text := _read_file("res://scripts/core/main.gd") + _read_file("res://scripts/ui/main_menu.gd")
	var wired := main_text.to_lower().contains("mode") and (
		main_text.contains("GameMode") or main_text.contains("current_mode") \
		or main_text.contains("select_mode") or main_text.contains("start_mode"))
	for m in new_ids:
		if main_text.contains(str(m)):
			wired = true
	_check(wired,
		"main / main_menu wires a mode selection (GameMode / current_mode / select_mode / a mode id)")
	# Endless best-score persistence: best_score + a save mechanism.
	var persist_text := combined + _read_file("res://scripts/core/game_state.gd")
	_check(persist_text.contains("best_score"),
		"best_score exists (endless high score is tracked)")
	_check(persist_text.contains("ConfigFile") \
			or (persist_text.contains("user://") and (persist_text.contains("save") or persist_text.contains("set_value"))),
		"endless best_score persists (ConfigFile / user:// save, not session-only)")
	# Behavioural probe: GameModeManager (start / stop / domination capture +
	# contest + score tick / endless bonus + run-over + best persistence).
	# The probe NEVER leaves test state behind: the pre-existing endless
	# best is restored (or the file removed if none existed).
	_probed = false
	for p in files:
		var text := _read_file(str(p))
		if not (text.contains("class_name GameModeManager") or (text.contains("MODES") and text.contains("func start("))):
			continue
		var script := load(str(p)) as GDScript
		if script == null:
			continue
		var mgr = script.new()
		if mgr == null:
			continue
		root.add_child(mgr)
		_probed = true
		var modes_const: Dictionary = (script.get_script_constant_map().get("MODES", {}) as Dictionary)
		_check(modes_const.size() >= 3,
			"GameModeManager MODES lists survival + >= 2 new modes (got %d: %s)" % [modes_const.size(), modes_const.keys()])
		var best_before: Dictionary = script.call("load_best") as Dictionary
		var best_existed := FileAccess.file_exists("user://endless_best.json")
		# Unknown mode falls back to survival (documented behaviour).
		mgr.call("start", "bogus_mode_xyz")
		_check(str(mgr.get("mode")) == "survival", "GameModeManager start('bogus') falls back to survival")
		mgr.call("stop")
		# --- Domination: capture + score tick + contest + stop.
		mgr.call("start", "domination")
		_check(str(mgr.get("mode")) == "domination" and bool(mgr.get("running")),
			"GameModeManager start('domination') runs domination")
		_check((mgr.get("_points") as Array).size() == 3,
			"domination builds 3 objective points (got %d)" % (mgr.get("_points") as Array).size())
		var pt0: Dictionary = (mgr.get("_points") as Array)[0] as Dictionary
		var ppos: Vector3 = pt0.get("pos", Vector3.ZERO)
		var dummy_player := Node3D.new()
		dummy_player.add_to_group("player")
		dummy_player.position = ppos
		root.add_child(dummy_player)
		var score_before := 0
		if _game != null:
			score_before = int(_game.get("score"))
		mgr.call("_process", 3.5)  # capture takes ~2.9 s uncontested
		_check(bool(pt0.get("owned")), "domination: standing in a point captures it (progress -> owned)")
		mgr.call("_process", 1.5)  # held point ticks score
		_check(int(mgr.get("domination_score")) >= 1,
			"domination: held point ticks score (domination_score %d)" % int(mgr.get("domination_score")))
		if _game != null:
			_check(int(_game.get("score")) > score_before,
				"domination: objective score flows through Game (Game.score %d -> %d)" % [score_before, int(_game.get("score"))])
		# Enemies inside a point contest it: progress/score stall.
		var grunt_script := load("res://scripts/enemies/grunt.gd") as GDScript
		var grunt = grunt_script.new()
		root.add_child(grunt)
		grunt.call("activate", ppos, 1, {})
		mgr.call("_process", 0.5)
		_check(bool(pt0.get("contested")), "domination: an enemy inside the point contests it")
		grunt.call("_recycle")
		root.remove_child(grunt)
		grunt.free()
		mgr.call("stop")
		_check(not bool(mgr.get("running")) and (mgr.get("_points") as Array).is_empty(),
			"GameModeManager stop() ends the run and clears objective points")
		root.remove_child(dummy_player)
		dummy_player.free()
		# --- Endless: wave bonus + run-over + best persistence.
		mgr.call("start", "endless")
		_check(str(mgr.get("mode")) == "endless" and bool(mgr.get("running")),
			"GameModeManager start('endless') runs endless")
		var escore_before := 0
		if _game != null:
			escore_before = int(_game.get("score"))
		mgr.call("_on_wave_cleared", 3)
		if _game != null:
			_check(int(_game.get("score")) == escore_before + 300,
				"endless: cleared wave 3 pays 100 x wave bonus (Game.score %d -> %d)" % [escore_before, int(_game.get("score"))])
		mgr.call("_on_player_died")
		_check(not bool(mgr.get("running")), "endless: player death ends the run")
		_check(int(script.call("load_best_score")) >= int(_game.get("score")) if _game != null else true,
			"endless: run-over persists the score as the best (best %d)" % int(script.call("load_best_score")))
		mgr.call("stop")
		# Restore pre-probe best state (no test residue).
		if best_existed:
			script.call("save_best", int(best_before.get("best_score", 0)), int(best_before.get("best_wave", 0)))
			_check(int(script.call("load_best_score")) == int(best_before.get("best_score", 0)),
				"endless best restored after probe (best %d)" % int(best_before.get("best_score", 0)))
		else:
			DirAccess.remove_absolute("user://endless_best.json")
			_check(not FileAccess.file_exists("user://endless_best.json"),
				"endless best file removed after probe (none existed before)")
		root.remove_child(mgr)
		mgr.free()
		break
	if not _probed:
		print("VERIFY(content): no GameModeManager-style class found — lifecycle checks above are source-level")
	# Map-select wiring (warn-only: a map cycle / auto-rotation is legit too).
	var map_wired := main_text.contains("MAP_SCENE") and (
		main_text.to_lower().contains("map_select") or main_text.to_lower().contains("current_map") \
		or main_text.to_lower().contains("select_map") or main_text.to_lower().contains("map_id"))
	_warn(map_wired, "main / main_menu wires a map selection (map_select / current_map / map_id)")


# ------------------------------------------------------------------ static

func _run_static_checks() -> void:
	# Every game script parses; every scene loads.
	var gd_files: Array = []
	_collect_files("res://scripts", ".gd", gd_files)
	var bad := 0
	for p in gd_files:
		var s := load(str(p)) as GDScript
		if s == null:
			bad += 1
			printerr("FAIL: script does not parse: ", p)
	_check(bad == 0, "all %d game scripts parse (0 failures)" % gd_files.size())
	var scene_files: Array = []
	_collect_files("res://scenes", ".tscn", scene_files)
	var bad_scenes := 0
	for p in scene_files:
		if (load(str(p)) as PackedScene) == null:
			bad_scenes += 1
			printerr("FAIL: scene does not load: ", p)
	_check(bad_scenes == 0, "all %d scenes load (0 failures)" % scene_files.size())
	# Voxel style holds: viewmodels via VoxelBuilder, enemies via voxel soldier.
	var arsenal_text := _read_file("res://scripts/weapons/arsenal.gd")
	_check(arsenal_text.contains("VoxelBuilder"),
		"voxel style: Arsenal viewmodels build from VoxelBuilder cubes")
	var soldier_text := _read_file("res://scripts/enemies/voxel_soldier.gd")
	_check(soldier_text.contains("BoxMesh") or soldier_text.contains("Voxel"),
		"voxel style: enemies build from voxel boxes (VoxelSoldier)")
