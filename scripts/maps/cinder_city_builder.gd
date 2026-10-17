# scripts/maps/cinder_city_builder.gd
# FORGEFALL — "Cinder City" map builder (Gameplay Rework, city maps).
#
# The answer to Colin's complaint: the old maps are very small and short
# with nothing to swing from. Cinder City is a 130x130 m downtown grid
# built FOR the movement kit — grapple swing lines down every street,
# long flat wall-run faces everywhere, rooftops to land on.
#
# Layout (Forgefall's own name/art — no real-game map copied):
#   - Street grid: N-S + E-W avenues centred at x/z = -44, -14, 14, 44,
#     each 12 m wide. Blocks between them hold the buildings; the centre
#     block (-8..8) is an open plaza with a monument + Forge pad.
#   - 24 map-geometry buildings (map geometry is NOT Forge building — the
#     "Forge exists ONLY in Tower Defense" rule covers Forge-built
#     structures, not map geometry; city maps keep their map buildings).
#     Heights 12-34 m + a 40 m antenna on the landmark Spire.
#   - Buildings RENDER as Kenney City Kit (Commercial) v2.1 GLBs (CC0,
#     see assets/kenney-city-kit/): one kit model per building, scaled to
#     fit its gameplay volume EXACTLY (footprint w x d, height h, base at
#     y = 0). Collision stays the ORIGINAL voxel boxes, so wall-run
#     faces, grapple anchors, spawns and pads are bit-identical to the
#     verified layout. The old voxel shell (main mass, trim, roof slab
#     visual, parapet, window strips, AC boxes, water tower) is gone: the
#     kit model fills the same volume, so the box would hide / z-fight
#     it. Rooftop dressing: kit parasols on every third low roof.
#     The Spire keeps its antenna + beacon above the kit crown.
#   - 2 skybridges (y = 16 / 18) across streets: grapple anchors and
#     rooftop-to-rooftop traversal.
#   - 4 wall-run medians ("fins"): 34 m long x 5 m high freestanding
#     walls down the centre of the four outer avenues. A full wall-run
#     at current tuning is ~13.75 m/s x 3 s = ~41 m, so a 34 m fin is a
#     ~2.5 s run — near the max, chainable fin-to-building-face.
#   - Street dressing: lamps, parked cars, crosswalks, centre dashes.
#
# Grapple geometry (checked against live tuning in grapple_hook.gd):
#   FIRE_RANGE 60, MAX_ROPE 40. From any street point, the nearest
#   building face is <= ~12 m away horizontally and >= 12 m tall, so a
#   face anchor at ~3/4 height sits ~15-25 m away in 3D — inside rope
#   range, with headroom to swing. Swing chain: anchors recur every
#   ~20-30 m along every street (building after building), so a swing
#   can be re-grappled mid-flight down a whole avenue. Rooftop decks
#   are flat and landable; DIRECT-pull anchors (near-vertical + slow)
#   exist on every parapet edge and both skybridges.
#
# Wall-run geometry (checked against player.gd: rays at y = 1.0, reach
# 1.2 m side / 1.6 m forward, MIN_SPEED 4, MAX_TIME 3 s):
#   Every building face is a flat vertical plane from the ground up
#   (10-14 m long on inner blocks, 10 m on outer blocks); the 4 fins
#   add 34 m continuous faces. Faces are reachable: fins stand in open
#   street (1.2 m ray reach from a run alongside), building faces line
#   the street edges.
#
# Minimap-friendly: grid-aligned streets, plaza hub at the centre,
# one landmark (the 34 m Spire + antenna at +x) for orientation. The
# HUD minimap shows a 90 m window around the player (MINIMAP_RANGE 45),
# so the 130 m map reads as local blocks, never as a fog of buildings.
#
# Same perf contract as the other builders: 3 MultiMeshes + 1 draw call
# per cover, simplified box collision, nav baked from walk surfaces.
# Markers: "player_spawn" x6, "spawn_door" x8, "forge_pad" x5.
extends MapBuilderBase

const ARENA_HALF := 65.0
const MAP_SEED := 20261016

# --- Layout data (also read by tools/verify_city_maps.gd) -----------------
# Buildings: {x, z} centre, {w, d} footprint, {h} height, {c} colour scheme.
# All footprints sit inside their block with >= 2 m setback from streets.
const BUILDINGS := [
	# Inner ring (8) around the plaza.
	{"x": -29.0, "z": -29.0, "w": 14.0, "d": 14.0, "h": 28.0, "c": 0},
	{"x": 29.0, "z": -29.0, "w": 14.0, "d": 14.0, "h": 24.0, "c": 1},
	{"x": -29.0, "z": 29.0, "w": 14.0, "d": 14.0, "h": 26.0, "c": 2},
	{"x": 29.0, "z": 29.0, "w": 14.0, "d": 14.0, "h": 30.0, "c": 3},
	{"x": 0.0, "z": -29.0, "w": 12.0, "d": 14.0, "h": 18.0, "c": 1},
	{"x": 0.0, "z": 29.0, "w": 12.0, "d": 14.0, "h": 20.0, "c": 0},
	{"x": -29.0, "z": 0.0, "w": 14.0, "d": 12.0, "h": 22.0, "c": 3},
	# Landmark Spire: tallest, + antenna to 40 m. Orienting landmark (+x).
	{"x": 29.0, "z": 0.0, "w": 14.0, "d": 12.0, "h": 34.0, "c": 2},
	# Outer west row (x = -57.5).
	{"x": -57.5, "z": -57.5, "w": 10.0, "d": 10.0, "h": 14.0, "c": 1},
	{"x": -57.5, "z": -29.0, "w": 10.0, "d": 14.0, "h": 16.0, "c": 0},
	{"x": -57.5, "z": 0.0, "w": 10.0, "d": 12.0, "h": 12.0, "c": 3},
	{"x": -57.5, "z": 29.0, "w": 10.0, "d": 14.0, "h": 15.0, "c": 2},
	{"x": -57.5, "z": 57.5, "w": 10.0, "d": 10.0, "h": 13.0, "c": 1},
	# Outer east row (x = 57.5).
	{"x": 57.5, "z": -57.5, "w": 10.0, "d": 10.0, "h": 15.0, "c": 0},
	{"x": 57.5, "z": -29.0, "w": 10.0, "d": 14.0, "h": 17.0, "c": 3},
	{"x": 57.5, "z": 0.0, "w": 10.0, "d": 12.0, "h": 13.0, "c": 2},
	{"x": 57.5, "z": 29.0, "w": 10.0, "d": 14.0, "h": 16.0, "c": 1},
	{"x": 57.5, "z": 57.5, "w": 10.0, "d": 10.0, "h": 14.0, "c": 0},
	# Outer north row (z = -57.5).
	{"x": -29.0, "z": -57.5, "w": 14.0, "d": 10.0, "h": 16.0, "c": 2},
	{"x": 0.0, "z": -57.5, "w": 14.0, "d": 10.0, "h": 18.0, "c": 3},
	{"x": 29.0, "z": -57.5, "w": 14.0, "d": 10.0, "h": 15.0, "c": 1},
	# Outer south row (z = 57.5).
	{"x": -29.0, "z": 57.5, "w": 14.0, "d": 10.0, "h": 15.0, "c": 0},
	{"x": 0.0, "z": 57.5, "w": 14.0, "d": 10.0, "h": 17.0, "c": 2},
	{"x": 29.0, "z": 57.5, "w": 14.0, "d": 10.0, "h": 16.0, "c": 3},
]

# Street centre-lines (avenues, 12 m wide). Grapple/wall-run corridors.
const STREETS := [-44.0, -14.0, 14.0, 44.0]

# Wall-run medians: {x, z} centre, {along} "x" | "z", {len} face length.
const FINS := [
	{"x": -44.0, "z": 0.0, "along": "z", "len": 34.0},
	{"x": 44.0, "z": 0.0, "along": "z", "len": 34.0},
	{"x": 0.0, "z": -44.0, "along": "x", "len": 34.0},
	{"x": 0.0, "z": 44.0, "along": "x", "len": 34.0},
]
const FIN_HEIGHT := 5.0
const FIN_THICK := 0.8

const PLAYER_SPAWNS := [
	Vector3(-44, 0.3, -44), Vector3(44, 0.3, -44),
	Vector3(-44, 0.3, 44), Vector3(44, 0.3, 44),
	Vector3(-29, 0.3, -44), Vector3(29, 0.3, 44),
]

const SPAWN_DOORS := [
	Vector3(-44, 0, -64.6), Vector3(44, 0, -64.6),
	Vector3(-44, 0, 64.6), Vector3(44, 0, 64.6),
	Vector3(-64.6, 0, -44), Vector3(-64.6, 0, 44),
	Vector3(64.6, 0, -44), Vector3(64.6, 0, 44),
]

const FORGE_PADS := [
	Vector3(4.5, 0, 4.5), Vector3(-14, 0, -14), Vector3(14, 0, -14),
	Vector3(-14, 0, 14), Vector3(14, 0, 14),
]

# --- Kenney City Kit (Commercial) v2.1 visuals (CC0) ---------------------
# KIT_DIR holds the GLBs the builder instantiates (one per building).
# Each entry: {file, min, size} = native GLB AABB measured from the kit
# files (base at y = 0, roughly centred in x/z). The builder scales the
# model so its AABB maps EXACTLY onto the building's gameplay volume.
# Tall buildings (h >= 24) get skyscraper variants; the rest get the
# 14 standard variants, round-robin in BUILDINGS order. Awnings /
# overhangs are deliberately NOT used: they would poke past the
# collision faces and clip wall-running players. Parasols sit on roofs,
# inside the footprint, so they are safe.
const KIT_DIR := "res://assets/kenney-city-kit/models/"
const KIT_SKYSCRAPERS := [
	{"file": "building-skyscraper-a.glb", "min": Vector3(-0.68, 0, -0.68), "size": Vector3(1.36, 2.88, 1.36)},
	{"file": "building-skyscraper-b.glb", "min": Vector3(-0.68, 0, -0.68), "size": Vector3(1.36, 4.48, 1.36)},
	{"file": "building-skyscraper-c.glb", "min": Vector3(-0.64, 0, -0.69), "size": Vector3(1.28, 4.08, 1.39)},
	{"file": "building-skyscraper-d.glb", "min": Vector3(-0.64, 0, -0.69), "size": Vector3(1.28, 5.47, 1.39)},
	{"file": "building-skyscraper-e.glb", "min": Vector3(-0.65, 0, -0.62), "size": Vector3(1.29, 4.08, 1.24)},
]
const KIT_BUILDINGS := [
	{"file": "building-a.glb", "min": Vector3(-0.44, 0, -0.47), "size": Vector3(0.88, 1.29, 0.94)},
	{"file": "building-b.glb", "min": Vector3(-0.49, 0, -0.47), "size": Vector3(0.97, 1.29, 0.94)},
	{"file": "building-c.glb", "min": Vector3(-0.44, 0, -0.55), "size": Vector3(0.88, 0.89, 1.09)},
	{"file": "building-d.glb", "min": Vector3(-0.42, 0, -0.45), "size": Vector3(0.84, 1.29, 0.90)},
	{"file": "building-e.glb", "min": Vector3(-0.82, 0, -0.50), "size": Vector3(1.64, 0.89, 1.01)},
	{"file": "building-f.glb", "min": Vector3(-0.42, 0, -0.51), "size": Vector3(0.84, 1.69, 1.03)},
	{"file": "building-g.glb", "min": Vector3(-0.49, 0, -0.46), "size": Vector3(0.97, 1.69, 0.92)},
	{"file": "building-h.glb", "min": Vector3(-0.44, 0, -0.50), "size": Vector3(0.88, 1.29, 1.01)},
	{"file": "building-i.glb", "min": Vector3(-0.62, 0, -0.65), "size": Vector3(1.24, 1.68, 1.30)},
	{"file": "building-j.glb", "min": Vector3(-1.04, 0, -0.67), "size": Vector3(2.08, 1.69, 1.34)},
	{"file": "building-k.glb", "min": Vector3(-1.04, 0, -0.47), "size": Vector3(2.08, 1.47, 0.94)},
	{"file": "building-l.glb", "min": Vector3(-0.69, 0, -0.70), "size": Vector3(1.37, 2.27, 1.40)},
	{"file": "building-m.glb", "min": Vector3(-0.62, 0, -0.62), "size": Vector3(1.24, 3.15, 1.24)},
	{"file": "building-n.glb", "min": Vector3(-1.16, 0, -0.91), "size": Vector3(2.32, 2.48, 1.82)},
]
const KIT_PARASOLS := [
	{"file": "detail-parasol-a.glb", "min": Vector3(-0.17, 0, -0.20), "size": Vector3(0.35, 0.45, 0.40)},
	{"file": "detail-parasol-b.glb", "min": Vector3(-0.17, 0, -0.20), "size": Vector3(0.35, 0.45, 0.40)},
]
# Every kit file the builder can load (read by tools/verify_city_maps.gd).
const KIT_FILES := [
	"building-a.glb", "building-b.glb", "building-c.glb", "building-d.glb",
	"building-e.glb", "building-f.glb", "building-g.glb", "building-h.glb",
	"building-i.glb", "building-j.glb", "building-k.glb", "building-l.glb",
	"building-m.glb", "building-n.glb", "building-skyscraper-a.glb",
	"building-skyscraper-b.glb", "building-skyscraper-c.glb",
	"building-skyscraper-d.glb", "building-skyscraper-e.glb",
	"detail-parasol-a.glb", "detail-parasol-b.glb",
]
# Which kit model BUILDINGS[idx] renders (same rule as _build_building).
static func kit_model_for(idx: int) -> Dictionary:
	var tall_before := 0
	for j in idx:
		if float(BUILDINGS[j]["h"]) >= 24.0:
			tall_before += 1
	if float(BUILDINGS[idx]["h"]) >= 24.0:
		return KIT_SKYSCRAPERS[tall_before % KIT_SKYSCRAPERS.size()]
	return KIT_BUILDINGS[(idx - tall_before) % KIT_BUILDINGS.size()]
const C_ASPHALT := Color("33363b")
const C_ASPHALT_D := Color("2a2d31")
const C_SIDEWALK := Color("6b6760")
const C_STRIPE := Color("d8d2c2")
const C_CAR_BODY := Color("7a2e2e")
const C_CAR_BODY2 := Color("2e4a7a")
const C_CAR_GLASS := Color("1c2733")


func _ready() -> void:
	_rng.seed = MAP_SEED
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_build_environment(0.0045)  # clearer air than Dustline: 130 m sightlines
	_build_ground()
	_build_perimeter(ARENA_HALF, 5.0, 6.0)
	var bi := 0
	for b in BUILDINGS:
		_build_building(b, bi)
		bi += 1
	_build_skybridges()
	_build_fins()
	_build_plaza()
	_build_lamps()
	_build_cars()
	_build_spawn_markers(PLAYER_SPAWNS, SPAWN_DOORS, FORGE_PADS, ARENA_HALF)
	_build_distant_city()
	_commit_multimeshes(AABB(Vector3(-ARENA_HALF, -2, -ARENA_HALF),
		Vector3(ARENA_HALF * 2, 52, ARENA_HALF * 2)))
	_build_motes(Vector3(60, 3.5, 60), 150)
	_bake_nav()


func _building_rect(b: Dictionary) -> Rect2:
	return Rect2(b["x"] - b["w"] * 0.5, b["z"] - b["d"] * 0.5, b["w"], b["d"])


func _build_ground() -> void:
	_v(Vector3(0, -0.25, 0), Vector3(130, 0.5, 130), C_SIDEWALK)
	_solid(Vector3(0, -0.25, 0), Vector3(130, 0.5, 130))
	_nav_boxes.append([Vector3(0, 0, 0), Vector3(130, 0.5, 130)])
	# Asphalt avenue strips (N-S then E-W), 12 m wide, full length.
	for s in STREETS:
		_v(Vector3(s, 0.015, 0), Vector3(12, 0.03, 130), C_ASPHALT)
		_v(Vector3(0, 0.015, s), Vector3(130, 0.03, 12), C_ASPHALT)
	# Centre dashes: one per avenue, every 6 m (skip intersection cores).
	for s in STREETS:
		for t in range(-60, 61, 6):
			if absf(float(t)) < 24 and (s == -14.0 or s == 14.0):
				continue  # keep the plaza + near-plaza crossings clean
			if absf(float(t)) < 9.0:
				continue  # intersection cores: crosswalks live here, not dashes
			# N-S avenue dash (long along z) + E-W avenue dash (long along x).
			_v(Vector3(s, 0.03, float(t)), Vector3(0.3, 0.02, 1.6), C_STRIPE)
			_v(Vector3(float(t), 0.03, s), Vector3(1.6, 0.02, 0.3), C_STRIPE)
	# Crosswalks at the four inner intersections (5 stripes each).
	for cx in [-14.0, 14.0]:
		for cz in [-14.0, 14.0]:
			for k in 5:
				var off := -3.2 + float(k) * 1.6
				_v(Vector3(cx + off, 0.03, cz), Vector3(0.9, 0.02, 8.0), C_STRIPE)


func _build_building(b: Dictionary, idx: int) -> void:
	var cx: float = b["x"]
	var cz: float = b["z"]
	var w: float = b["w"]
	var d: float = b["d"]
	var h: float = b["h"]
	var center := Vector3(cx, h * 0.5, cz)
	# COLLISION (gameplay volumes — UNCHANGED from the verified layout):
	# one flat vertical face per side, ground to roof, + roof slab.
	_solid(center, Vector3(w, h, d))
	_solid(Vector3(cx, h + 0.15, cz), Vector3(w + 0.4, 0.3, d + 0.4))
	# VISUAL: one Kenney kit model, scaled so its AABB maps EXACTLY onto
	# the collision volume (footprint w x d, height h, base at y = 0).
	_kit_place(kit_model_for(idx), Vector3(cx - w * 0.5, 0, cz - d * 0.5),
		Vector3(w, h, d), "KitBuilding_%d" % idx, "kit_building")
	# Rooftop parasols on every third low roof (inside the footprint).
	if idx % 3 == 0 and h < 28.0:
		for s in [-1.0, 1.0]:
			_kit_place(KIT_PARASOLS[idx % KIT_PARASOLS.size()],
				Vector3(cx + s * w * 0.22 - 0.7, h + 0.3, cz + d * 0.22 - 0.7),
				Vector3(1.4, 1.8, 1.4),
				"KitParasol_%d_%s" % [idx, "a" if s < 0.0 else "b"], "kit_detail")
	# Landmark Spire antenna: 34 m roof + 6 m mast = 40 m tip, glowing.
	if h >= 34.0:
		_v(Vector3(cx, h + 3.0, cz), Vector3(0.3, 6.0, 0.3), C_STEEL_D)
		_g(Vector3(cx, h + 6.2, cz), Vector3(0.5, 0.5, 0.5), C_FORGE)
		# Spire beacon strip down the +x face (visible from across the map).
		_g(Vector3(cx + w * 0.5 + 0.06, h * 0.6, cz), Vector3(0.14, h * 0.7, 1.2), C_FORGE)


# Instantiates one kit GLB and scales it so its native AABB (min/size)
# maps onto the box [corner, corner + target]. The instance's visual
# AABB then equals the target box exactly: nothing pokes past the
# collision faces. No collision is added — kit models are visual-only.
func _kit_place(model: Dictionary, corner: Vector3, target: Vector3,
		node_name: String, group: String) -> void:
	var ps := load(KIT_DIR + str(model["file"])) as PackedScene
	if ps == null:
		push_warning("Cinder City: kit model failed to load: %s" % str(model["file"]))
		return
	var inst := ps.instantiate() as Node3D
	if inst == null:
		return
	inst.name = node_name
	inst.set_meta("kit_file", str(model["file"]))
	var mn: Vector3 = model["min"]
	var sz: Vector3 = model["size"]
	inst.scale = Vector3(target.x / sz.x, target.y / sz.y, target.z / sz.z)
	inst.position = Vector3(corner.x - mn.x * inst.scale.x,
		corner.y - mn.y * inst.scale.y, corner.z - mn.z * inst.scale.z)
	inst.add_to_group(group)
	add_child(inst)


func _build_skybridges() -> void:
	# Bridge 1: across the x = -14 avenue at z = -29, deck y = 16.
	# Spans the gap between the (-29,-29) tower face (x = -22) and the
	# (0,-29) building face (x = -6). Bridge 2 mirrors it at z = +29.
	var bridges := [
		{"c": Vector3(-14, 16, -29), "len": 16.0},
		{"c": Vector3(14, 18, 29), "len": 16.0},
	]
	for br in bridges:
		var c: Vector3 = br["c"]
		var ln: float = br["len"]
		_v(c, Vector3(ln, 0.8, 3.0), C_STEEL_D)
		_solid(c, Vector3(ln, 0.8, 3.0))
		_v(c + Vector3(0, 0.6, 1.4), Vector3(ln, 0.9, 0.2), C_GUNMETAL)
		_v(c + Vector3(0, 0.6, -1.4), Vector3(ln, 0.9, 0.2), C_GUNMETAL)
		_g(c + Vector3(0, 1.2, 0), Vector3(ln * 0.9, 0.12, 0.12), C_FORGE)


func _build_fins() -> void:
	# Wall-run medians: 34 m x 5 m flat faces down the outer avenues.
	for f in FINS:
		var cx: float = f["x"]
		var cz: float = f["z"]
		var size := Vector3(FIN_THICK, FIN_HEIGHT, f["len"]) if f["along"] == "z" \
			else Vector3(f["len"], FIN_HEIGHT, FIN_THICK)
		var center := Vector3(cx, FIN_HEIGHT * 0.5, cz)
		_v(center, size, C_CONCRETE)
		_solid(center, size)
		# Billboard cap: glowing strip + panel so the fin reads at 130 m.
		var cap_size := Vector3(0.4, 0.5, f["len"] * 0.8) if f["along"] == "z" \
			else Vector3(f["len"] * 0.8, 0.5, 0.4)
		_g(Vector3(cx, FIN_HEIGHT + 0.35, cz), cap_size, C_FORGE)
		_v(Vector3(cx, FIN_HEIGHT + 0.9, cz),
			Vector3(0.3, 0.6, f["len"] * 0.6) if f["along"] == "z" \
			else Vector3(f["len"] * 0.6, 0.6, 0.3), C_DARKMETAL)


func _build_plaza() -> void:
	# Centre plaza (-8..8): monument + ring. Forge pad sits at (4.5, 4.5),
	# clear of the monument footprint (+/-2 m).
	_v(Vector3(0, 0.03, 0), Vector3(16, 0.06, 16), C_TAN_D)
	# Monument: stepped pedestal + 14 m obelisk + glowing cap.
	_v(Vector3(0, 0.5, 0), Vector3(4.0, 1.0, 4.0), C_CONCRETE_D)
	_v(Vector3(0, 1.25, 0), Vector3(3.0, 0.5, 3.0), C_CONCRETE)
	_v(Vector3(0, 8.0, 0), Vector3(2.0, 14.0, 2.0), C_CONCRETE)
	_solid(Vector3(0, 8.0, 0), Vector3(2.0, 14.0, 2.0))
	_g(Vector3(0, 15.3, 0), Vector3(1.2, 0.6, 1.2), C_FORGE)
	# Plaza ring: 8 low bollard glows marking the hub on the minimap.
	for i in 8:
		var ang := (float(i) + 0.5) / 8.0 * TAU
		var px := cos(ang) * 7.0
		var pz := sin(ang) * 7.0
		_v(Vector3(px, 0.4, pz), Vector3(0.4, 0.8, 0.4), C_DARKMETAL)
		_g(Vector3(px, 0.9, pz), Vector3(0.3, 0.2, 0.3), C_FORGE)


func _build_lamps() -> void:
	# 12 street lamps: pole + glowing head. Positions avoid fins, pads,
	# spawns and the monument (checked in verify_city_maps.gd).
	var spots := [
		Vector3(-44, 0, -26), Vector3(-44, 0, 26),
		Vector3(44, 0, -26), Vector3(44, 0, 26),
		Vector3(-26, 0, -44), Vector3(26, 0, -44),
		Vector3(-26, 0, 44), Vector3(26, 0, 44),
		Vector3(7, 0, 0), Vector3(-7, 0, 0),
		Vector3(0, 0, 7), Vector3(0, 0, -7),
	]
	for p in spots:
		_v(p + Vector3(0, 2.5, 0), Vector3(0.18, 5.0, 0.18), C_DARKMETAL)
		_v(p + Vector3(0, 5.1, 0), Vector3(0.9, 0.18, 0.4), C_DARKMETAL)
		_g(p + Vector3(0, 5.0, 0), Vector3(0.7, 0.25, 0.35), C_WINDOW_LIT)
		_solid(p + Vector3(0, 2.5, 0), Vector3(0.3, 5.0, 0.3))


func _build_cars() -> void:
	# 6 parked cars on avenue curbs (voxel body + cabin). All clear of
	# fins / spawns / pads by construction (avenue edges, off-centre).
	var cars := [
		{"p": Vector3(-40, 0, -26), "rot": 0.0, "c": C_CAR_BODY},
		{"p": Vector3(40, 0, 26), "rot": 0.0, "c": C_CAR_BODY2},
		{"p": Vector3(-26, 0, 40), "rot": PI * 0.5, "c": C_CAR_BODY2},
		{"p": Vector3(26, 0, -40), "rot": PI * 0.5, "c": C_CAR_BODY},
		{"p": Vector3(-40, 0, 30), "rot": 0.0, "c": C_CAR_BODY},
		{"p": Vector3(40, 0, -30), "rot": 0.0, "c": C_CAR_BODY2},
	]
	for car in cars:
		var p: Vector3 = car["p"]
		var rot: float = car["rot"]
		var col: Color = car["c"]
		_v(p + Vector3(0, 0.55, 0), Vector3(4.0, 0.8, 2.0), col, rot)
		_v(p + Vector3(0, 1.2, 0), Vector3(2.2, 0.7, 1.7), C_CAR_GLASS, rot)
		_solid(p + Vector3(0, 0.7, 0), Vector3(4.0, 1.4, 2.0), false, rot)


func _build_distant_city() -> void:
	for i in 48:
		var ang := float(i) / 48.0 * TAU + _rng.randf_range(-0.05, 0.05)
		var r := _rng.randf_range(150, 230)
		var bw := _rng.randf_range(10, 24)
		var bh := _rng.randf_range(14, 55)
		var bd := _rng.randf_range(10, 24)
		var shade := _rng.randf_range(0.8, 1.3)
		_c(Vector3(cos(ang) * r, bh * 0.5 - 2.0, sin(ang) * r), Vector3(bw, bh, bd),
			Color(0.17 * shade, 0.15 * shade, 0.25 * shade))
