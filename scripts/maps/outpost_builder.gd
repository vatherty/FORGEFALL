# scripts/maps/outpost_builder.gd
# FORGEFALL — "Outpost" map builder (Goal 3, Worker A).
#
# Large open map: a 110x110 m desert outpost that plays the OPPOSITE of
# Foundry's room-to-room fighting. Identity: long sightlines down a central
# road cross, open ground where marksman rifles and the grapple win, and
# cover POCKETS (barrier + crate clusters) you hop between — no room is ever
# more than a sprint from the next pocket.
#
# Layout:
#   - Central road cross (flat decals) with a fully open middle; sightlines
#     run ~100 m corner to corner, broken only by berms, ruins and pockets.
#   - 4 corner watchtowers: 2 stair-accessible (3 m deck), 2 tall (7 m,
#     grapple-only). Water tower + 12 m radio mast as extra grapple targets.
#   - L-shaped ruin walls, a concrete bunker, dirt berms, rock outcrops.
#   - 6 cover pockets + road barriers + barrel clusters (20 covers).
#
# Same perf contract as Dustline: 3 MultiMeshes + 1 draw call per cover,
# simplified box collision, nav baked from walk surfaces only.
# Markers: "player_spawn" x5, "spawn_door" x8, "forge_pad" x5.
extends MapBuilderBase

const ARENA_HALF := 55.0
const MAP_SEED := 20261016

const PLAYER_SPAWNS := [
	Vector3(-50, 0.3, -50), Vector3(50, 0.3, -50),
	Vector3(-50, 0.3, 50), Vector3(50, 0.3, 50),
	Vector3(0, 0.3, 50),
]

const SPAWN_DOORS := [
	Vector3(-27, 0, -54.6), Vector3(27, 0, -54.6),
	Vector3(-54.6, 0, -27), Vector3(-54.6, 0, 27),
	Vector3(54.6, 0, -27), Vector3(54.6, 0, 27),
	Vector3(-27, 0, 54.6), Vector3(27, 0, 54.6),
]

const FORGE_PADS := [
	Vector3(0, 0, 0), Vector3(26, 0, -26), Vector3(-26, 0, -26),
	Vector3(26, 0, 26), Vector3(-26, 0, 26),
]


func _ready() -> void:
	_rng.seed = MAP_SEED
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_build_environment(0.005)  # clearer air than Dustline: long sightlines
	_build_ground()
	_build_perimeter(ARENA_HALF, 3.0, 4.0)
	_build_towers()
	_build_water_tower(Vector3(34, 0, -34))
	_build_radio_mast(Vector3(-34, 0, -34))
	_build_ruins()
	_build_bunker()
	_build_berms()
	_build_rocks()
	_build_pockets()
	_build_covers()
	_build_dressing()
	_build_spawn_markers(PLAYER_SPAWNS, SPAWN_DOORS, FORGE_PADS, ARENA_HALF)
	_build_city()
	_commit_multimeshes(AABB(Vector3(-ARENA_HALF, -2, -ARENA_HALF),
		Vector3(ARENA_HALF * 2, 20, ARENA_HALF * 2)))
	_build_motes(Vector3(50, 3.5, 50), 150)
	_bake_nav()


func _build_ground() -> void:
	_v(Vector3(0, -0.25, 0), Vector3(110, 0.5, 110), C_DIRT)
	_solid(Vector3(0, -0.25, 0), Vector3(110, 0.5, 110))
	_nav_boxes.append([Vector3(0, 0, 0), Vector3(110, 0.5, 110)])
	# Central road cross (flat decals, walkable) + dust patches.
	_v(Vector3(0, 0.015, 0), Vector3(8, 0.03, 110), C_TAN_D)
	_v(Vector3(0, 0.015, 0), Vector3(110, 0.03, 8), C_TAN_D)
	for i in 20:
		var px := _rng.randf_range(-50, 50)
		var pz := _rng.randf_range(-50, 50)
		var s := _rng.randf_range(3.0, 9.0)
		_v(Vector3(px, 0.015, pz), Vector3(s, 0.03, s * _rng.randf_range(0.6, 1.0)),
			_pick([C_DIRT_D, C_TAN, C_CONCRETE_D]), _rng.randf_range(0, TAU))
	for i in 220:
		var px := _rng.randf_range(-54, 54)
		var pz := _rng.randf_range(-54, 54)
		var s := _rng.randf_range(0.125, 0.3)
		_v(Vector3(px, s * 0.5, pz), Vector3(s, s, s),
			_pick([C_CONCRETE, C_RUST, C_TAN, C_DIRT_D]), _rng.randf_range(0, TAU))


# Four corner watchtowers. stairs = +1/-1: steps on the +x/-x side (toward
# the map center). Tall towers (7 m) have no stairs — grapple-only.
func _build_towers() -> void:
	_tower(Vector3(-42, 0, -42), 3.0, 1)
	_tower(Vector3(42, 0, 42), 3.0, -1)
	_tower(Vector3(42, 0, -42), 7.0, 0)
	_tower(Vector3(-42, 0, 42), 7.0, 0)


func _tower(p: Vector3, deck_h: float, stairs: int) -> void:
	for ox in [-1.6, 1.6]:
		for oz in [-1.6, 1.6]:
			_v(p + Vector3(ox, deck_h * 0.5, oz), Vector3(0.4, deck_h, 0.4), C_WOOD_D)
	_v(p + Vector3(0, deck_h, 0), Vector3(4.0, 0.3, 4.0), C_WOOD)
	_solid(p + Vector3(0, deck_h, 0), Vector3(4.0, 0.3, 4.0))
	_nav_boxes.append([p + Vector3(0, deck_h + 0.15, 0), Vector3(4.0, 0.2, 4.0)])
	# Parapet on all four deck edges (low cover up top).
	_v(p + Vector3(0, deck_h + 0.4, 2.0), Vector3(4.2, 0.5, 0.2), C_WOOD)
	_v(p + Vector3(0, deck_h + 0.4, -2.0), Vector3(4.2, 0.5, 0.2), C_WOOD)
	_v(p + Vector3(2.0, deck_h + 0.4, 0), Vector3(0.2, 0.5, 4.2), C_WOOD)
	_v(p + Vector3(-2.0, deck_h + 0.4, 0), Vector3(0.2, 0.5, 4.2), C_WOOD)
	# Flag pole + orange pennant (tower reads at 100 m).
	_v(p + Vector3(0, deck_h + 1.6, 0), Vector3(0.12, 3.2, 0.12), C_DARKMETAL)
	_v(p + Vector3(0.45, deck_h + 2.6, 0), Vector3(0.8, 0.5, 0.06), C_FORGE)
	if stairs != 0:
		# 1 m steps up the stairs side to the 3 m deck.
		var s1x := p.x + stairs * 3.4
		var s2x := p.x + stairs * 2.0
		_v(Vector3(s1x, 0.5, p.z), Vector3(1.4, 1.0, 2.0), C_CONCRETE_D)
		_solid(Vector3(s1x, 0.5, p.z), Vector3(1.4, 1.0, 2.0))
		_nav_boxes.append([Vector3(s1x, 1.0, p.z), Vector3(1.4, 0.2, 2.0)])
		_v(Vector3(s2x, 1.0, p.z), Vector3(1.4, 2.0, 2.0), C_CONCRETE)
		_solid(Vector3(s2x, 1.0, p.z), Vector3(1.4, 2.0, 2.0))
		_nav_boxes.append([Vector3(s2x, 2.0, p.z), Vector3(1.4, 0.2, 2.0)])


func _build_water_tower(p: Vector3) -> void:
	for ox in [-1.4, 1.4]:
		for oz in [-1.4, 1.4]:
			_v(p + Vector3(ox, 4.0, oz), Vector3(0.35, 8.0, 0.35), C_DARKMETAL)
	_v(p + Vector3(0, 9.0, 0), Vector3(3.6, 2.4, 3.6), C_RUST)
	_v(p + Vector3(0, 10.35, 0), Vector3(3.0, 0.5, 3.0), C_RUST_D)
	_v(p + Vector3(0, 9.0, 0), Vector3(3.75, 0.25, 3.75), C_DARKMETAL)
	_solid(p + Vector3(0, 4.0, 0), Vector3(3.4, 8.0, 3.4))
	_solid(p + Vector3(0, 9.4, 0), Vector3(3.8, 3.0, 3.8))


func _build_radio_mast(p: Vector3) -> void:
	# 12 m mast: thin stacked segments + cross arms + glowing tip.
	for i in 6:
		_v(p + Vector3(0, 1.0 + float(i) * 2.0, 0), Vector3(0.3, 2.0, 0.3), C_STEEL_D)
	_v(p + Vector3(0, 6.0, 0), Vector3(2.4, 0.15, 0.15), C_STEEL)
	_v(p + Vector3(0, 9.0, 0), Vector3(1.6, 0.15, 0.15), C_STEEL)
	_g(p + Vector3(0, 12.2, 0), Vector3(0.4, 0.4, 0.4), C_FORGE)
	_solid(p + Vector3(0, 0.5, 0), Vector3(1.0, 1.0, 1.0))


func _build_ruins() -> void:
	# Three L-shaped ruin walls (2.5 m high, open corners = peek spots).
	var ruins := [
		[Vector3(-30, 0, 10), 0.0], [Vector3(28, 0, -18), PI * 0.5],
		[Vector3(8, 0, 38), PI * 0.25],
	]
	for r in ruins:
		var p: Vector3 = r[0]
		var rot: float = r[1]
		var fwd := Vector3(0, 0, 1).rotated(Vector3.UP, rot)
		var rgt := Vector3(1, 0, 0).rotated(Vector3.UP, rot)
		_v(p + fwd * 3.0, Vector3(0.5, 2.5, 6.0), C_CONCRETE, rot)
		_solid(p + fwd * 3.0, Vector3(0.5, 2.5, 6.0), false, rot)
		_v(p + rgt * 2.0 + fwd * 0.5, Vector3(4.0, 2.5, 0.5), C_TAN, rot)
		_solid(p + rgt * 2.0 + fwd * 0.5, Vector3(4.0, 2.5, 0.5), false, rot)
		# Broken top edge: missing chunks read as ruin, not fresh wall.
		_v(p + fwd * 3.0 + Vector3(0, 1.4, 0), Vector3(0.55, 0.5, 1.2), C_RUST_D, rot)


func _build_bunker() -> void:
	var p := Vector3(-34, 0, 30)
	_v(p + Vector3(0, 1.3, 0), Vector3(6.0, 2.6, 4.0), C_CONCRETE)
	_v(p + Vector3(0, 2.75, 0), Vector3(6.4, 0.3, 4.4), C_CONCRETE_D)
	# Doorway (dark inset) on the +z face + sandbag line in front.
	_v(p + Vector3(0, 1.0, 2.02), Vector3(1.2, 2.0, 0.1), C_DARKMETAL)
	_v(p + Vector3(0, 2.3, 2.02), Vector3(1.4, 0.15, 0.12), C_WOOD_D)
	for i in 5:
		_v(p + Vector3(-2.0 + float(i) * 1.0, 0.35, 3.4), Vector3(0.9, 0.7, 0.6), C_TAN_D)
	_solid(p + Vector3(0, 1.3, 0), Vector3(6.0, 2.6, 4.0))
	_solid(p + Vector3(0, 0.35, 3.4), Vector3(5.0, 0.7, 0.6))


func _build_berms() -> void:
	# Low dirt mounds (1 m): break sightlines at ankle height, vaultable
	# cover that does NOT block the long view.
	for b in [[Vector3(20, 0, -38), 0.3], [Vector3(-20, 0, 38), -0.4],
			[Vector3(38, 0, 20), 0.9], [Vector3(-38, 0, -20), -0.9]]:
		_v(b[0] + Vector3(0, 0.5, 0), Vector3(8.0, 1.0, 4.0), C_DIRT_D, b[1])
		_solid(b[0] + Vector3(0, 0.5, 0), Vector3(8.0, 1.0, 4.0), false, b[1])
		_nav_boxes.append([b[0] + Vector3(0, 1.0, 0), Vector3(8.0, 0.2, 4.0)])


func _build_rocks() -> void:
	var spots := [Vector3(-8, 0, -38), Vector3(12, 0, 38), Vector3(-38, 0, 8),
		Vector3(40, 0, -8), Vector3(-12, 0, 22), Vector3(22, 0, -6),
		Vector3(-6, 0, -22), Vector3(38, 0, 36)]
	for rp in spots:
		var s := _rng.randf_range(1.4, 2.4)
		_v(rp + Vector3(0, s * 0.45, 0), Vector3(s, s * 0.9, s * 0.8),
			_pick([C_CONCRETE_D, C_DIRT_D, C_RUST_D]), _rng.randf_range(0, TAU))
		_v(rp + Vector3(s * 0.3, s * 0.9, 0), Vector3(s * 0.5, s * 0.35, s * 0.5),
			C_CONCRETE, _rng.randf_range(0, TAU))
		_solid(rp + Vector3(0, s * 0.45, 0), Vector3(s, s * 0.9, s * 0.8))


func _build_pockets() -> void:
	# Cover pockets: barrier + crate pairs you hop between across open ground.
	var pockets := [
		[Vector3(15, 0, 15), 0.7], [Vector3(-15, 0, -15), 0.7],
		[Vector3(15, 0, -15), -0.7], [Vector3(-15, 0, 15), -0.7],
		[Vector3(0, 0, 30), 0.0], [Vector3(0, 0, -30), 0.0],
	]
	for pk in pockets:
		var p: Vector3 = pk[0]
		var rot: float = pk[1]
		_cover(Vector3i(8, 5, 2), PAL_BARRIER, 70.0, p, rot)
		_cover(Vector3i(4, 4, 4), PAL_CRATE, 45.0, p + Vector3(1.8, 0, 1.2), rot)


func _build_covers() -> void:
	for bp in [Vector3(10, 0, -25), Vector3(-10, 0, 25),
			Vector3(25, 0, 10), Vector3(-25, 0, -10)]:
		_cover(Vector3i(3, 4, 3), PAL_BARREL, 30.0, bp, _rng.randf_range(0, TAU))
	for bp in [[Vector3(0, 0, 18), 0.0], [Vector3(0, 0, -18), 0.0],
			[Vector3(18, 0, 0), PI * 0.5], [Vector3(-18, 0, 0), PI * 0.5]]:
		_cover(Vector3i(8, 5, 2), PAL_BARRIER, 70.0, bp[0], bp[1])


func _build_dressing() -> void:
	# Dead trees (trunk + 2 branches), signposts, crate stacks.
	for tp in [Vector3(-44, 0, -8), Vector3(44, 0, 12), Vector3(-10, 0, -44), Vector3(14, 0, 44)]:
		_v(tp + Vector3(0, 1.5, 0), Vector3(0.35, 3.0, 0.35), C_WOOD_D)
		_v(tp + Vector3(0.5, 2.8, 0.2), Vector3(1.2, 0.2, 0.2), C_WOOD_D, 0.6)
		_v(tp + Vector3(-0.4, 2.4, -0.2), Vector3(0.9, 0.18, 0.18), C_WOOD_D, -0.5)
		_solid(tp + Vector3(0, 1.5, 0), Vector3(0.4, 3.0, 0.4))
	for sp in [Vector3(-20, 0, -20), Vector3(20, 0, 20)]:
		_v(sp + Vector3(0, 1.4, 0), Vector3(0.2, 2.8, 0.2), C_DARKMETAL)
		_v(sp + Vector3(0, 2.5, 0), Vector3(1.6, 0.9, 0.08), C_FORGE)
	for pp in [Vector3(-44, 0, 30), Vector3(44, 0, -30)]:
		for i in 3:
			_v(pp + Vector3(0, 0.5 + float(i) * 1.0, 0), Vector3(1.0, 1.0, 1.0),
				_pick([C_WOOD, C_OLIVE, C_TAN]), _rng.randf_range(0, TAU))
		_solid(pp + Vector3(0, 1.5, 0), Vector3(1.2, 3.0, 1.2))


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
