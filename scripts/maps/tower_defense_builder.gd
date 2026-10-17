# FORGEFALL — "Tower Defense" map builder (Gameplay Rework, TD worker).
#
# Purpose-built TD arena — NOT a one-loop-fits-all map. Two serpentine
# lanes (north + south) run from spawn gates to a central core plaza;
# 8 build spots flank the lanes; the navmesh covers ONLY the lanes +
# core plaza + build aprons, so WaveManager spawns (at the lane-head
# spawn_doors) path along the lanes toward a player defending the
# core (enemy AI targets the player through the navmesh — see
# TowerDefenseMode header for the full mechanism).
#
# Layout (120x120 m, arena half 60):
#   - Core plaza at the centre (td_core marker at origin).
#   - Lane North: gate (0,-56) -> (0,-40) -> (-18,-22) -> (-10,-8) -> core.
#   - Lane South: gate (0, 56) -> (0, 40) -> (18, 22) -> (10, 8) -> core.
#   - Build spots: 8 pads flanking the lane mid-sections.
#   - Dressing (watchtowers, crates, ruins) sits OFF the lanes so it
#     never blocks a lane path.
#
# Markers: "player_spawn" x2 (core plaza), "spawn_door" x2 (lane
# heads), "td_lane" x2 (LaneNorth / LaneSouth, waypoint Marker3D
# children in order, head -> core), "td_build_spot" x8, "td_core" x1.
# Same perf contract as the other maps: 3 MultiMeshes + 1 draw call
# per cover, simplified box collision, nav baked from walk surfaces.
extends MapBuilderBase

const ARENA_HALF := 60.0
const MAP_SEED := 20261016

const CORE_POS := Vector3(0, 0, 0)
const LANE_NORTH := [
	Vector3(0, 0, -56), Vector3(0, 0, -40), Vector3(-18, 0, -22),
	Vector3(-10, 0, -8), Vector3(0, 0, 0),
]
const LANE_SOUTH := [
	Vector3(0, 0, 56), Vector3(0, 0, 40), Vector3(18, 0, 22),
	Vector3(10, 0, 8), Vector3(0, 0, 0),
]
const BUILD_SPOTS := [
	Vector3(-13, 0, -38), Vector3(13, 0, -38),
	Vector3(-26, 0, -18), Vector3(26, 0, -18),
	Vector3(-13, 0, 38), Vector3(13, 0, 38),
	Vector3(-26, 0, 18), Vector3(26, 0, 18),
]
const PLAYER_SPAWNS := [Vector3(9, 0.3, 9), Vector3(-9, 0.3, -9)]
const SPAWN_DOORS := [Vector3(0, 0, -59.6), Vector3(0, 0, 59.6)]

# Lane tread width (visual + nav). Nav boxes are axis-aligned
# (MapBuilderBase._add_box_faces), so diagonal lane runs are covered
# by a chain of overlapping square boxes stepping along the segment.
const LANE_WIDTH := 5.0
const NAV_STEP := 2.0


func _ready() -> void:
	_rng.seed = MAP_SEED
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_build_environment(0.006)
	_build_ground()
	_build_perimeter(ARENA_HALF, 3.0, 4.2)
	_build_lanes()
	_build_core_plaza()
	_build_spots()
	_build_lane_markers()
	_build_core_marker()
	_build_spawn_markers(PLAYER_SPAWNS, SPAWN_DOORS, [], ARENA_HALF)
	_build_dressing()
	_build_city()
	_commit_multimeshes(AABB(Vector3(-ARENA_HALF, -2, -ARENA_HALF),
		Vector3(ARENA_HALF * 2, 20, ARENA_HALF * 2)))
	_build_motes(Vector3(50, 3.5, 50), 150)
	_bake_nav_ribbon()


func _build_ground() -> void:
	_v(Vector3(0, -0.25, 0), Vector3(120, 0.5, 120), C_DIRT)
	_solid(Vector3(0, -0.25, 0), Vector3(120, 0.5, 120))
	# Ground is NOT a nav box: only lanes / plaza / aprons are
	# walkable in the baked navmesh (that is what makes waves follow
	# the lanes). Off-lane ground is visual only.


func _build_lanes() -> void:
	for lane in [LANE_NORTH, LANE_SOUTH]:
		for i in range(lane.size() - 1):
			_pave_segment(lane[i], lane[i + 1])


## One lane run: visual tread + (nav comes from the ribbon bake, not
## from boxes — see _bake_nav_ribbon).
func _pave_segment(a: Vector3, b: Vector3) -> void:
	var dist := a.distance_to(b)
	var steps := maxi(int(ceil(dist / NAV_STEP)), 1)
	for i in steps + 1:
		var t := float(i) / float(steps)
		var p := a.lerp(b, t)
		# Visual tread: flat paver, alternating tint per step so the
		# lane reads as a path, not a slab.
		var tint := C_CONCRETE_D if (i % 2 == 0) else C_TAN_D
		_v(Vector3(p.x, 0.015, p.z), Vector3(LANE_WIDTH, 0.03, LANE_WIDTH), tint)
	# Edge glow dots at the segment ends (lane readability).
	_g(Vector3(a.x, 0.06, a.z), Vector3(0.5, 0.06, 0.5), C_FORGE)


func _build_core_plaza() -> void:
	# Plaza disc (visual only — nav is the ribbons, which reach the
	# core; the plaza itself needs no separate nav region).
	_v(Vector3(0, -0.2, 0), Vector3(18, 0.4, 18), C_CONCRETE)
	_v(Vector3(0, 0.015, 0), Vector3(16, 0.03, 16), C_CONCRETE_D)
	# Pedestal ring the mode's core sits in + corner glow.
	_g(Vector3(0, 0.1, 0), Vector3(5.0, 0.08, 5.0), C_FORGE)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_v(Vector3(sx * 3.4, 0.6, sz * 3.4), Vector3(0.7, 1.2, 0.7), C_GUNMETAL)
			_g(Vector3(sx * 3.4, 1.25, sz * 3.4), Vector3(0.5, 0.1, 0.5), C_FORGE)


func _build_spots() -> void:
	for sp in BUILD_SPOTS:
		# Slab + orange corner glow + marker. Aprons are visual +
		# marker only (enemies path to a player standing on one via
		# the lane ribbons + direct steering, like any off-nav point).
		_v(Vector3(sp.x, 0.04, sp.z), Vector3(4.4, 0.08, 4.4), C_CONCRETE)
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				_g(Vector3(sp.x + sx * 1.9, 0.1, sp.z + sz * 1.9),
					Vector3(0.3, 0.08, 0.3), C_FORGE)
		var m := Marker3D.new()
		m.name = "BuildSpot"
		m.position = sp + Vector3(0, 0.2, 0)
		m.add_to_group("td_build_spot")
		add_child(m)


## Lane waypoint nodes: group "td_lane", Marker3D children in order
## (Waypoint0 = lane head at the gate, last = core). The mode +
## verifier read these; the map builder is the single source of truth.
func _build_lane_markers() -> void:
	var lanes := {"LaneNorth": LANE_NORTH, "LaneSouth": LANE_SOUTH}
	for lane_name in lanes:
		var lane_node := Node3D.new()
		lane_node.name = lane_name
		lane_node.add_to_group("td_lane")
		add_child(lane_node)
		var pts: Array = lanes[lane_name]
		for i in pts.size():
			var wp := Marker3D.new()
			wp.name = "Waypoint%d" % i
			wp.position = pts[i] + Vector3(0, 0.5, 0)
			lane_node.add_child(wp)
			# Waypoint glow dot (lane readability from the plaza).
			_g(pts[i] + Vector3(0, 0.08, 0), Vector3(0.6, 0.08, 0.6), C_FORGE)


func _build_core_marker() -> void:
	var m := Marker3D.new()
	m.name = "CoreMarker"
	m.position = CORE_POS + Vector3(0, 0.2, 0)
	m.add_to_group("td_core")
	add_child(m)


## Nav bake: ONE flat ribbon quad-strip per lane (miter joins), all at
## NAV_Y. This deliberately does NOT use the base class's _bake_nav()
## (_nav_boxes): a stepped chain of overlapping boxes bakes into a mesh
## with hundreds of edge-merge errors and unusable paths (proven by
## probe: 1000+ sync edge errors, empty path queries). Ribbon quads
## share edges exactly — no overlaps, no gaps — so the bake is a clean
## two-strip mesh and paths from a lane head to the core follow the
## lane bends. Build-spot aprons and the plaza carry no nav: enemies
## reach a player standing on one via the ribbons + the direct-steer
## fallback in EnemyBase.nav_direction_to().
const NAV_Y := 0.25


func _bake_nav_ribbon() -> void:
	var src := NavigationMeshSourceGeometryData3D.new()
	var faces := PackedVector3Array()
	for lane in [LANE_NORTH, LANE_SOUTH]:
		_append_ribbon_faces(faces, lane)
	if faces.is_empty():
		return
	src.add_faces(faces, Transform3D.IDENTITY)
	var nm := NavigationMesh.new()
	nm.agent_height = NAV_AGENT_HEIGHT
	nm.agent_radius = NAV_AGENT_RADIUS
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	_nav_region.navigation_mesh = nm


## Append one ribbon strip for a lane polyline (head -> core): per-point
## left/right verts from the averaged direction of adjacent segments
## (miter joins — consecutive quads share the (L,R) edge exactly).
## Winding: (L_i, R_i, R_{i+1}) / (L_i, R_{i+1}, L_{i+1}) gives +Y
## normals (verified by bake: polygons > 0 and paths follow the bends).
func _append_ribbon_faces(faces: PackedVector3Array, pts: Array) -> void:
	var n := pts.size()
	var lefts: Array[Vector3] = []
	var rights: Array[Vector3] = []
	for i in n:
		var dir: Vector3
		if i == 0:
			dir = (pts[1] - pts[0]).normalized()
		elif i == n - 1:
			dir = (pts[n - 1] - pts[n - 2]).normalized()
		else:
			dir = ((pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()).normalized()
		# Perp to the left of travel (XZ plane).
		var perp := Vector3(-dir.z, 0, dir.x)
		var p: Vector3 = pts[i]
		lefts.append(Vector3(p.x + perp.x * LANE_WIDTH * 0.5, NAV_Y, p.z + perp.z * LANE_WIDTH * 0.5))
		rights.append(Vector3(p.x - perp.x * LANE_WIDTH * 0.5, NAV_Y, p.z - perp.z * LANE_WIDTH * 0.5))
	for i in n - 1:
		var li := lefts[i]
		var ri := rights[i]
		var lj := lefts[i + 1]
		var rj := rights[i + 1]
		faces.append_array([li, ri, rj, li, rj, lj])


## Off-lane dressing only: two watchtowers, crate/barrel clusters, and
## ruin walls placed where no lane runs (checked against the lane
## polylines by eye: lanes stay within |x| <= 26, towers at |x| = 42).
func _build_dressing() -> void:
	# Watchtowers (grapple targets for the TD traversal choice).
	for tx in [-42.0, 42.0]:
		for tz in [-42.0, 42.0]:
			_v(Vector3(tx, 2.0, tz), Vector3(3.0, 4.0, 3.0), C_CONCRETE)
			_v(Vector3(tx, 4.6, tz), Vector3(4.0, 0.5, 4.0), C_WOOD)
			_v(Vector3(tx, 5.4, tz), Vector3(3.4, 1.2, 3.4), C_RUST)
	# Crate + barrel clusters (cover pockets off the lanes).
	for c in [Vector3(-36, 0, 8), Vector3(36, 0, -8), Vector3(-8, 0, -44), Vector3(8, 0, 44)]:
		_v(c + Vector3(0, 0.5, 0), Vector3(1.4, 1.0, 1.4), C_WOOD)
		_v(c + Vector3(1.6, 0.4, 0.4), Vector3(1.0, 0.8, 1.0), C_WOOD_D)
		_v(c + Vector3(-1.4, 0.45, 1.2), Vector3(0.9, 0.9, 0.9), C_RUST)
	# Ruin walls (broken, never spanning a lane).
	for r in [Vector3(-46, 0, -20), Vector3(46, 0, 20)]:
		_v(r + Vector3(0, 1.0, 0), Vector3(0.6, 2.0, 7.0), C_CONCRETE)
		_v(r + Vector3(0, 2.2, -2.0), Vector3(0.6, 0.6, 2.0), C_RUST)


func _build_city() -> void:
	for i in 44:
		var ang := float(i) / 44.0 * TAU + _rng.randf_range(-0.05, 0.05)
		var r := _rng.randf_range(130, 190)
		var bw := _rng.randf_range(8, 20)
		var bh := _rng.randf_range(10, 45)
		var bd := _rng.randf_range(8, 20)
		var shade := _rng.randf_range(0.8, 1.3)
		_c(Vector3(cos(ang) * r, bh * 0.5 - 2.0, sin(ang) * r), Vector3(bw, bh, bd),
			Color(0.17 * shade, 0.15 * shade, 0.25 * shade))
