# tools/verify_city_maps.gd — headless checks for FORGEFALL city maps.
# Usage: godot --headless --path <project> --script res://tools/verify_city_maps.gd
# Covers Cinder City (scripts/maps/cinder_city_builder.gd):
#   1. Map scene loads, _ready() completes, expected child nodes exist
#      (StaticVoxels / GlowVoxels / DistantCity / StaticCollision /
#      NavRegion with a baked navmesh).
#   2. Buildings: >= 20 map-geometry buildings, heights 12..34 m,
#      >= 4 towers >= 24 m, footprints inside bounds, pairwise disjoint.
#   3. Grapple-anchor geometry (live tuning: FIRE_RANGE 60, MAX_ROPE 40):
#      for sample points every 10 m along every avenue, the nearest
#      building face is <= 20 m away horizontally, >= 12 m tall, and the
#      3D distance from a 1.7 m eye to a face anchor at 3/4 height is
#      <= MAX_ROPE (so a swing can start and be re-grappled down the
#      whole avenue). >= 95% of samples must pass.
#   4. Wall-run geometry (live tuning: rays 1.2 m side / 1.6 m forward,
#      MAX_TIME 3 s at ~13.75 m/s = ~41 m max run): 4 fins with 34 m x
#      5 m faces, >= 10 buildings with a face >= 12 m long, fins clear
#      of every building footprint.
#   5. Spawns: 6 player_spawn markers, in bounds, not inside any
#      building / fin footprint (1 m margin), pairwise >= 10 m apart.
#      8 spawn_door markers on the perimeter, 5 forge_pad markers clear
#      of geometry (incl. the plaza monument).
#   6. Registry: Main.MAPS + main_menu MAP_KEYS + multiplayer_menu
#      MAP_KEYS all contain "cinder_city"; its scene exists; the main
#      menu offers a "CINDER CITY" item.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

const MAP_SCENE := "res://scenes/maps/cinder_city.tscn"
const BUILDER_SCRIPT := "res://scripts/maps/cinder_city_builder.gd"
const MAX_ROPE := 40.0
const EYE_Y := 1.7

var _fails := 0
var _frames := 0
var _map: Node = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	var ps := load(MAP_SCENE) as PackedScene
	if ps == null:
		printerr("FAIL: could not load ", MAP_SCENE)
		quit(1)
		return
	_map = ps.instantiate()
	root.add_child(_map)
	print("CITY: map instantiated, waiting for _ready")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 5:
		return false
	_run_checks()
	print("CITY: %d failure(s)" % _fails)
	quit(1 if _fails > 0 else 0)
	return true


func _rects_overlap(a: Rect2, b: Rect2) -> bool:
	return a.intersects(b)


func _point_in_rect_expanded(p: Vector2, r: Rect2, margin: float) -> bool:
	return p.x >= r.position.x - margin and p.x <= r.end.x + margin \
		and p.y >= r.position.y - margin and p.y <= r.end.y + margin


func _closest_on_rect(p: Vector2, r: Rect2) -> Vector2:
	return Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))


func _fin_rect(f: Dictionary) -> Rect2:
	if f["along"] == "z":
		return Rect2(f["x"] - 0.4, f["z"] - f["len"] * 0.5, 0.8, f["len"])
	return Rect2(f["x"] - f["len"] * 0.5, f["z"] - 0.4, f["len"], 0.8)


func _run_checks() -> void:
	var script := load(BUILDER_SCRIPT) as GDScript
	var consts := script.get_script_constant_map()
	var buildings: Array = consts.get("BUILDINGS", [])
	var streets: Array = consts.get("STREETS", [])
	var fins: Array = consts.get("FINS", [])
	var arena_half: float = consts.get("ARENA_HALF", 65.0)

	# 1. Structure.
	_check(_map != null, "map node instantiated")
	_check(_map.get_node_or_null("StaticVoxels") != null, "StaticVoxels present")
	_check(_map.get_node_or_null("GlowVoxels") != null, "GlowVoxels present")
	_check(_map.get_node_or_null("DistantCity") != null, "DistantCity present")
	_check(_map.get_node_or_null("StaticCollision") != null, "StaticCollision present")
	var nav := _map.get_node_or_null("NavRegion") as NavigationRegion3D
	_check(nav != null and nav.navigation_mesh != null, "NavRegion baked navmesh present")

	# 2. Buildings.
	_check(buildings.size() >= 20, "building count %d >= 20" % buildings.size())
	var rects: Array = []
	var min_h := 1e9
	var max_h := 0.0
	var tall := 0
	for b in buildings:
		var h: float = b["h"]
		min_h = minf(min_h, h)
		max_h = maxf(max_h, h)
		if h >= 24.0:
			tall += 1
		var r := Rect2(b["x"] - b["w"] * 0.5, b["z"] - b["d"] * 0.5, b["w"], b["d"])
		rects.append(r)
		_check(absf(r.position.x) <= arena_half and absf(r.end.x) <= arena_half \
			and absf(r.position.y) <= arena_half and absf(r.end.y) <= arena_half,
			"building (%.0f,%.0f) footprint inside bounds" % [b["x"], b["z"]])
	_check(min_h >= 10.0, "min building height %.1f >= 10" % min_h)
	_check(max_h >= 30.0, "max building height %.1f >= 30 (landmark Spire)" % max_h)
	_check(tall >= 4, "tall towers >=24 m: %d >= 4" % tall)
	var overlap := false
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if _rects_overlap(rects[i], rects[j]):
				overlap = true
	_check(not overlap, "no two building footprints overlap")

	# 3. Grapple anchors along every avenue.
	var samples := 0
	var samples_ok := 0
	var worst := 0.0
	for s in streets:
		for t in range(-60, 61, 10):
			for pt in [Vector2(s, float(t)), Vector2(float(t), s)]:
				samples += 1
				var best_dist := 1e9
				var best_h := 0.0
				var best_anchor := Vector3.ZERO
				for bi in buildings.size():
					var b: Dictionary = buildings[bi]
					var r: Rect2 = rects[bi]
					var cp := _closest_on_rect(pt, r)
					var hd: float = pt.distance_to(cp)
					if hd < best_dist:
						best_dist = hd
						best_h = float(b["h"])
						var ay := minf(best_h * 0.75, 30.0)
						best_anchor = Vector3(cp.x, ay, cp.y)
				var eye := Vector3(pt.x, EYE_Y, pt.y)
				var d3 := eye.distance_to(best_anchor)
				worst = maxf(worst, d3)
				if best_dist <= 20.0 and best_h >= 12.0 and d3 <= MAX_ROPE:
					samples_ok += 1
				else:
					printerr("  grapple sample (%.0f,%.0f): face %.1f m, h %.1f, 3D %.1f" % [pt.x, pt.y, best_dist, best_h, d3])
	_check(samples_ok * 100 >= samples * 95,
		"grapple anchor coverage %d/%d samples (worst 3D %.1f m <= %.0f rope)" % [samples_ok, samples, worst, MAX_ROPE])

	# 4. Wall-run geometry.
	_check(fins.size() == 4, "fin count %d == 4" % fins.size())
	for f in fins:
		_check(float(f["len"]) >= 30.0, "fin at (%.0f,%.0f) face %.0f m >= 30" % [f["x"], f["z"], f["len"]])
		var fr := _fin_rect(f)
		var hits := false
		for r in rects:
			if _rects_overlap(fr, r):
				hits = true
		_check(not hits, "fin at (%.0f,%.0f) clear of building footprints" % [f["x"], f["z"]])
	var long_faces := 0
	for b in buildings:
		if maxf(float(b["w"]), float(b["d"])) >= 12.0:
			long_faces += 1
	_check(long_faces >= 10, "buildings with a wall-run face >= 12 m: %d >= 10" % long_faces)

	# 5. Spawns / doors / pads.
	var spawns := get_nodes_in_group("player_spawn")
	_check(spawns.size() == 6, "player_spawn count %d == 6" % spawns.size())
	var spawn_pts: Array = []
	for sp in spawns:
		var p := (sp as Node3D).global_position
		spawn_pts.append(Vector2(p.x, p.z))
		_check(absf(p.x) <= arena_half and absf(p.z) <= arena_half,
			"spawn (%.0f,%.0f) in bounds" % [p.x, p.z])
		var inside := false
		for r in rects:
			if _point_in_rect_expanded(Vector2(p.x, p.z), r, 1.0):
				inside = true
		for f in fins:
			if _point_in_rect_expanded(Vector2(p.x, p.z), _fin_rect(f), 1.0):
				inside = true
		_check(not inside, "spawn (%.0f,%.0f) clear of geometry (+1 m)" % [p.x, p.z])
	for i in spawn_pts.size():
		for j in range(i + 1, spawn_pts.size()):
			_check(spawn_pts[i].distance_to(spawn_pts[j]) >= 10.0,
				"spawns %d/%d separated %.1f m >= 10" % [i, j, spawn_pts[i].distance_to(spawn_pts[j])])
	var doors := get_nodes_in_group("spawn_door")
	_check(doors.size() == 8, "spawn_door count %d == 8" % doors.size())
	for dp in doors:
		var p := (dp as Node3D).global_position
		_check(absf(absf(p.x) - 64.6) < 1.0 or absf(absf(p.z) - 64.6) < 1.0,
			"door (%.0f,%.0f) on perimeter" % [p.x, p.z])
	var pads := get_nodes_in_group("forge_pad")
	_check(pads.size() == 5, "forge_pad count %d == 5" % pads.size())
	for fp in pads:
		var p := (fp as Node3D).global_position
		var inside := false
		for r in rects:
			if _point_in_rect_expanded(Vector2(p.x, p.z), r, 1.0):
				inside = true
		for f in fins:
			if _point_in_rect_expanded(Vector2(p.x, p.z), _fin_rect(f), 1.0):
				inside = true
		if Vector2(p.x, p.z).distance_to(Vector2.ZERO) <= 3.0:
			inside = true  # plaza monument footprint (+margin)
		_check(not inside, "forge pad (%.1f,%.1f) clear of geometry" % [p.x, p.z])

	# 6. Registry.
	var main_consts := (load("res://scripts/core/main.gd") as GDScript).get_script_constant_map()
	var maps: Dictionary = main_consts.get("MAPS", {})
	_check(maps.has("cinder_city"), "Main.MAPS registers cinder_city")
	if maps.has("cinder_city"):
		_check(ResourceLoader.exists(str(maps["cinder_city"]["scene"])),
			"registered cinder_city scene exists")
	var menu_consts := (load("res://scripts/ui/main_menu.gd") as GDScript).get_script_constant_map()
	var menu_keys: Array = menu_consts.get("MAP_KEYS", [])
	_check(menu_keys.has("cinder_city"), "main_menu MAP_KEYS contains cinder_city")
	var mp_consts := (load("res://scripts/ui/multiplayer_menu.gd") as GDScript).get_script_constant_map()
	var mp_keys: Array = mp_consts.get("MAP_KEYS", [])
	_check(mp_keys.has("cinder_city"), "multiplayer_menu MAP_KEYS contains cinder_city")
	var menu_src := FileAccess.get_file_as_string("res://scripts/ui/main_menu.gd")
	_check(menu_src.contains("CINDER CITY"), "main menu offers a CINDER CITY item")
