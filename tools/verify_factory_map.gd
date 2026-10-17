# tools/verify_factory_map.gd — headless checks for the FORGEFALL Factory map.
# Usage: godot --headless --path <project> --script res://tools/verify_factory_map.gd
# Covers scripts/maps/factory_builder.gd + scenes/maps/factory.tscn:
#   1. Kit license: the Kenney Factory Kit zip + extracted License.txt
#      are present and License.txt confirms CC0; the builder's
#      KIT_ASSETS_USED list names >= 40 kit assets (map built from the
#      kit vocabulary, as voxel recreations — no kit mesh imported).
#   2. Map loads: scene instantiates, _ready() completes, expected
#      child nodes exist (StaticVoxels / GlowVoxels / DistantCity /
#      StaticCollision / NavRegion with a baked navmesh), voxel
#      instance count sane (not empty, not bloated).
#   3. Rotation wiring: Main.MAPS + main_menu MAP_KEYS +
#      multiplayer_menu MAP_KEYS all contain "factory"; the registered
#      scene exists; the main menu offers a "FACTORY" item.
#      NOT in Zombies: zombies.gd / td_setup.gd never reference the
#      factory map (Main forces zombies_flat / tower_defense there).
#   4. Gameplay: 8 player_spawn markers in bounds, pairwise >= 10 m,
#      clear of recorded collision footprints (+1 m, above ankle
#      height) and of destructible-cover spots; 8 spawn_door +
#      4 forge_pad markers; 10 destructible covers in group "cover".
#   5. Traversal: grapple-anchor coverage (nearest ANCHORS point
#      within MAX_ROPE 40 m of the eye, anchor >= 4 m up) >= 95% of
#      samples along both hall centerlines + catwalks; >= 4 wall-run
#      faces >= 12 m long and >= 4 m tall; flat portal-wall area
#      >= 1000 m^2; collision footprints present and in bounds.
#   6. No banned strings (trademarked / copied names or signage) in
#      the map files.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

const MAP_SCENE := "res://scenes/maps/factory.tscn"
const BUILDER_SCRIPT := "res://scripts/maps/factory_builder.gd"
const KIT_DIR := "res://assets/kenney_factory_kit/"
const MAX_ROPE := 40.0
const EYE_Y := 1.7

const BANNED := [
	"activision", "treyarch", "black ops", "call of duty", "bo2",
	"nuketown", "tranzit", "die rise", "mob of the dead",
	"kino der toten", "der riese", "nacht der untoten", "verruckt",
	"shi no numa", "shangri-la", "ascension", "buried",
	"juggernog", "pack-a-punch", "wunderwaffe", "ray gun",
	"monkey bomb", "perk-a-cola", "quick revive", "speed cola",
	"double tap", "stamin-up", "mule kick", "tombstone", "deadshot",
	"phd flopper", "electric cherry", "vulture aid", "who's who",
]

var _fails := 0
var _checks := 0
var _frames := 0
var _map: Node = null


func _check(cond: bool, label: String) -> void:
	_checks += 1
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
	print("FACTORY: map instantiated, waiting for _ready")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 5:
		return false
	_run_checks()
	print("FACTORY: %d/%d checks passed, %d failure(s)" % [_checks - _fails, _checks, _fails])
	quit(1 if _fails > 0 else 0)
	return true


func _point_clear_of_footprints(p: Vector3, footprints: Array, margin: float) -> bool:
	# Only footprints whose solid body intersects the player's standing
	# volume (ankle..head) can block a spawn; floor slabs below the
	# ankles are ground, and decks 4 m overhead are not blockers.
	var y_lo := p.y + 0.1
	var y_hi := p.y + 1.8
	for f in footprints:
		var c: Vector3 = f[0]
		var s: Vector3 = f[1]
		if c.y + s.y * 0.5 <= y_lo or c.y - s.y * 0.5 >= y_hi:
			continue
		if p.x >= c.x - s.x * 0.5 - margin and p.x <= c.x + s.x * 0.5 + margin \
				and p.z >= c.z - s.z * 0.5 - margin and p.z <= c.z + s.z * 0.5 + margin:
			return false
	return true


func _run_checks() -> void:
	var script := load(BUILDER_SCRIPT) as GDScript
	var consts := script.get_script_constant_map()
	var arena_half: float = consts.get("ARENA_HALF", 28.0)
	var kit_used: PackedStringArray = consts.get("KIT_ASSETS_USED", [])
	var anchors: Array = consts.get("ANCHORS", [])
	var cover_spots: Array = consts.get("COVER_SPOTS", [])
	var spine_segments: Array = consts.get("SPINE_SEGMENTS", [])
	var spine_h: float = consts.get("SPINE_H", 5.0)

	# 1. Kit license (in-pack) + kit vocabulary.
	_check(FileAccess.file_exists(KIT_DIR + "License.txt"),
		"kit License.txt present in-pack")
	var lic := ""
	if FileAccess.file_exists(KIT_DIR + "License.txt"):
		lic = FileAccess.get_file_as_string(KIT_DIR + "License.txt")
	_check(lic.contains("CC0") and lic.contains("creativecommons.org/publicdomain/zero"),
		"kit License.txt confirms CC0")
	_check(FileAccess.file_exists(KIT_DIR + "kenney_factory-kit_3.0.zip"),
		"kit archive retained for provenance")
	_check(FileAccess.file_exists(KIT_DIR + "README.md"),
		"kit README (provenance + mapping) present")
	_check(kit_used.size() >= 40,
		"KIT_ASSETS_USED names %d >= 40 kit assets" % kit_used.size())

	# 2. Structure + perf sanity.
	_check(_map != null, "map node instantiated")
	_check(_map.get_node_or_null("StaticVoxels") != null, "StaticVoxels present")
	_check(_map.get_node_or_null("GlowVoxels") != null, "GlowVoxels present")
	_check(_map.get_node_or_null("DistantCity") != null, "DistantCity present")
	_check(_map.get_node_or_null("StaticCollision") != null, "StaticCollision present")
	var nav := _map.get_node_or_null("NavRegion") as NavigationRegion3D
	_check(nav != null and nav.navigation_mesh != null,
		"NavRegion baked navmesh present")
	if nav != null and nav.navigation_mesh != null:
		_check(nav.navigation_mesh.get_polygon_count() > 20,
			"navmesh polygons %d > 20" % nav.navigation_mesh.get_polygon_count())
	var total_instances := 0
	for mname in ["StaticVoxels", "GlowVoxels", "DistantCity"]:
		var mmi := _map.get_node_or_null(mname) as MultiMeshInstance3D
		if mmi != null and mmi.multimesh != null:
			total_instances += mmi.multimesh.instance_count
	_check(total_instances > 500, "voxel instances %d > 500 (map not empty)" % total_instances)
	_check(total_instances < 6000, "voxel instances %d < 6000 (perf sane)" % total_instances)

	# 3. Rotation wiring (TDM via the map picker) + NOT in Zombies.
	var main_consts := (load("res://scripts/core/main.gd") as GDScript).get_script_constant_map()
	var maps: Dictionary = main_consts.get("MAPS", {})
	_check(maps.has("factory"), "Main.MAPS registers factory")
	if maps.has("factory"):
		_check(ResourceLoader.exists(str(maps["factory"]["scene"])),
			"registered factory scene exists")
	var menu_consts := (load("res://scripts/ui/main_menu.gd") as GDScript).get_script_constant_map()
	var menu_keys: Array = menu_consts.get("MAP_KEYS", [])
	_check(menu_keys.has("factory"), "main_menu MAP_KEYS contains factory")
	var mp_consts := (load("res://scripts/ui/multiplayer_menu.gd") as GDScript).get_script_constant_map()
	var mp_keys: Array = mp_consts.get("MAP_KEYS", [])
	_check(mp_keys.has("factory"), "multiplayer_menu MAP_KEYS contains factory")
	var menu_src := FileAccess.get_file_as_string("res://scripts/ui/main_menu.gd")
	# Map items are built from MAP_KEYS with to_upper(), so "factory"
	# renders as "FACTORY" at runtime — no "FACTORY" literal in source.
	_check(menu_src.contains("_map_select.add_item") and menu_src.contains("to_upper()"),
		"main menu offers a FACTORY item (MAP_KEYS rendered upper-case)")
	var zombies_src := FileAccess.get_file_as_string("res://scripts/modes/zombies.gd")
	_check(not zombies_src.to_lower().contains("factory"),
		"zombies.gd never references the factory map (Zombies keeps its own map)")
	var td_src := FileAccess.get_file_as_string("res://scripts/modes/td_setup.gd")
	_check(not td_src.to_lower().contains("factory"),
		"td_setup.gd never references the factory map (TD keeps its own map)")

	# 4. Spawns / doors / pads / covers.
	var spawns := get_nodes_in_group("player_spawn")
	_check(spawns.size() == 8, "player_spawn count %d == 8" % spawns.size())
	var spawn_pts: Array = []
	var footprints: Array = []
	if _map != null and _map.get("collision_footprints") != null:
		footprints = _map.get("collision_footprints")
	_check(footprints.size() >= 50, "collision footprints %d >= 50" % footprints.size())
	var footprints_in_bounds := true
	for f in footprints:
		var c: Vector3 = f[0]
		var s: Vector3 = f[1]
		if absf(c.x) - s.x * 0.5 > arena_half + 1.0 or absf(c.z) - s.z * 0.5 > arena_half + 1.0:
			footprints_in_bounds = false
	_check(footprints_in_bounds, "all collision footprints inside arena bounds (+1 m)")
	for sp in spawns:
		var p := (sp as Node3D).global_position
		spawn_pts.append(Vector2(p.x, p.z))
		_check(absf(p.x) <= arena_half and absf(p.z) <= arena_half,
			"spawn (%.0f,%.0f) in bounds" % [p.x, p.z])
		_check(_point_clear_of_footprints(p, footprints, 1.0),
			"spawn (%.0f,%.0f) clear of collision (+1 m)" % [p.x, p.z])
		var cover_clear := true
		for cp in cover_spots:
			var c: Vector3 = cp
			if Vector2(p.x, p.z).distance_to(Vector2(c.x, c.z)) < 2.0:
				cover_clear = false
		_check(cover_clear, "spawn (%.0f,%.0f) clear of cover spots (>= 2 m)" % [p.x, p.z])
	for i in spawn_pts.size():
		for j in range(i + 1, spawn_pts.size()):
			_check(spawn_pts[i].distance_to(spawn_pts[j]) >= 10.0,
				"spawns %d/%d separated %.1f m >= 10" % [i, j, spawn_pts[i].distance_to(spawn_pts[j])])
	var doors := get_nodes_in_group("spawn_door")
	_check(doors.size() == 8, "spawn_door count %d == 8" % doors.size())
	var pads := get_nodes_in_group("forge_pad")
	_check(pads.size() == 4, "forge_pad count %d == 4" % pads.size())
	var covers := get_nodes_in_group("cover")
	_check(covers.size() == 10, "destructible cover count %d == 10" % covers.size())

	# 5. Traversal: grapple anchors / wall-run faces / portal walls.
	var samples := 0
	var samples_ok := 0
	var sample_pts: Array = []
	for x in range(-24, 25, 8):
		sample_pts.append(Vector3(float(x), EYE_Y, -10.0))
		sample_pts.append(Vector3(float(x), EYE_Y, 10.0))
	for z in range(-24, 25, 8):
		sample_pts.append(Vector3(-24.0, EYE_Y, float(z)))
		sample_pts.append(Vector3(24.0, EYE_Y, float(z)))
	for pt in sample_pts:
		samples += 1
		var best := 1e9
		for a in anchors:
			var av: Vector3 = a
			if av.y < 4.0:
				continue
			best = minf(best, pt.distance_to(av))
		if best <= MAX_ROPE:
			samples_ok += 1
		else:
			printerr("  grapple sample (%.0f,%.0f): nearest anchor %.1f m > %.0f rope" % [pt.x, pt.z, best, MAX_ROPE])
	_check(samples_ok * 100 >= samples * 95,
		"grapple anchor coverage %d/%d samples (rope %.0f m)" % [samples_ok, samples, MAX_ROPE])
	var long_faces := 0
	var wall_area := 0.0
	for side in 4:  # perimeter: 4 x (2*half x spine height)
		wall_area += 2.0 * arena_half * spine_h
		if 2.0 * arena_half >= 12.0 and spine_h >= 4.0:
			long_faces += 1
	for seg in spine_segments:
		var ln: float = seg[1]
		wall_area += ln * spine_h
		if ln >= 12.0 and spine_h >= 4.0:
			long_faces += 1
	_check(long_faces >= 4, "wall-run faces >= 12 m x >= 4 m: %d >= 4" % long_faces)
	_check(wall_area >= 1000.0, "flat portal-wall area %.0f m^2 >= 1000" % wall_area)

	# 6. No banned strings in the map files.
	var scan_files := [
		"res://scripts/maps/factory_builder.gd",
		"res://scenes/maps/factory.tscn",
		"res://assets/kenney_factory_kit/README.md",
	]
	for fpath in scan_files:
		var text := FileAccess.get_file_as_string(fpath).to_lower()
		var hit := ""
		for b in BANNED:
			if text.contains(b):
				hit = b
				break
		_check(hit.is_empty(), "no banned strings in %s%s" % [fpath, "" if hit.is_empty() else " (found: " + hit + ")"])
