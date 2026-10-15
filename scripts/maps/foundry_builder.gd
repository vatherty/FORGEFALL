# scripts/maps/foundry_builder.gd
# FORGEFALL — "Foundry" map builder (Goal 3, Worker A).
#
# Tight urban/interior map: a 48x48 m foundry floor that plays the OPPOSITE
# of Dustline's open shantytown. Identity: close-quarters room-to-room
# fighting, corner peeks, a mezzanine overlook, and alley flanks.
#
# Layout:
#   - Perimeter shell (24 m half-extent) + two long partition walls (x = +/-10,
#     door gaps at z = 0) splitting the floor into west alley / central hall /
#     east alley, plus a cross wall (z = 12, gap at x = 0) making a south
#     furnace room. Fights are 5-15 m, corners everywhere.
#   - Mezzanine deck (y = 3) over the hall's north end, stair access on its
#     +x side, parapet cover, its own Forge pad. Under-deck nook for ambushes.
#   - Furnace + 9 m chimney in the south room, overhead crane beam + hook
#     across the hall: grapple / vertical targets. Crane columns double as
#     hall pillars.
#   - Destructible cover chokes every doorway and alley corner.
#
# Same perf contract as Dustline: 3 MultiMeshes + 1 draw call per cover,
# simplified box collision, nav baked from walk surfaces only.
# Markers: "player_spawn" x5, "spawn_door" x6, "forge_pad" x4.
extends MapBuilderBase

const ARENA_HALF := 24.0
const MAP_SEED := 20261015

const PLAYER_SPAWNS := [
	Vector3(-20, 0.3, -20), Vector3(20, 0.3, -20),
	Vector3(-20, 0.3, 20), Vector3(20, 0.3, 20),
	Vector3(0, 0.3, 10),
]

const SPAWN_DOORS := [
	Vector3(-12, 0, -23.6), Vector3(12, 0, -23.6),
	Vector3(-23.6, 0, 0), Vector3(23.6, 0, 0),
	Vector3(-16, 0, 23.6), Vector3(16, 0, 23.6),
]

const FORGE_PADS := [
	Vector3(0, 0, -4), Vector3(-17, 0, 0),
	Vector3(17, 0, 0), Vector3(0, 3, -17),
]


func _ready() -> void:
	_rng.seed = MAP_SEED
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_build_environment(0.009)  # slightly hazier than Dustline: interior air
	_build_ground()
	_build_perimeter(ARENA_HALF, 4.2, 5.2)
	_build_partitions()
	_build_mezzanine()
	_build_furnace()
	_build_crane()
	_build_workshop()
	_build_covers()
	_build_dressing()
	_build_spawn_markers(PLAYER_SPAWNS, SPAWN_DOORS, FORGE_PADS, ARENA_HALF)
	_build_city()
	_commit_multimeshes(AABB(Vector3(-ARENA_HALF, -2, -ARENA_HALF),
		Vector3(ARENA_HALF * 2, 20, ARENA_HALF * 2)))
	_build_motes(Vector3(22, 3.5, 22))
	_bake_nav()


func _build_ground() -> void:
	_v(Vector3(0, -0.25, 0), Vector3(48, 0.5, 48), C_CONCRETE_D)
	_solid(Vector3(0, -0.25, 0), Vector3(48, 0.5, 48))
	_nav_boxes.append([Vector3(0, 0, 0), Vector3(48, 0.5, 48)])
	# Worn floor patches + scattered rubble.
	for i in 12:
		var px := _rng.randf_range(-21, 21)
		var pz := _rng.randf_range(-21, 21)
		var s := _rng.randf_range(2.0, 5.0)
		_v(Vector3(px, 0.015, pz), Vector3(s, 0.03, s * _rng.randf_range(0.6, 1.0)),
			_pick([C_DIRT_D, C_RUST_D, C_CONCRETE]), _rng.randf_range(0, TAU))
	for i in 90:
		var px := _rng.randf_range(-23, 23)
		var pz := _rng.randf_range(-23, 23)
		var s := _rng.randf_range(0.125, 0.3)
		_v(Vector3(px, s * 0.5, pz), Vector3(s, s, s),
			_pick([C_CONCRETE, C_RUST, C_TAN, C_DIRT_D]), _rng.randf_range(0, TAU))


func _build_partitions() -> void:
	# Long partition walls at x = +/-10, door gap at z = 0 (3 m wide).
	for x in [-10.0, 10.0]:
		for seg_z in [-10.75, 10.75]:
			_wall(Vector3(x, 2.0, seg_z), Vector3(0.5, 4.0, 18.5),
				_pick([C_TAN, C_CONCRETE, C_RUST]))
		# Door frame lintel over the gap.
		_v(Vector3(x, 3.6, 0), Vector3(0.6, 0.4, 3.2), C_DARKMETAL)
	# Cross wall at z = 12, door gap at x = 0 (2.5 m wide).
	for seg_x in [-5.625, 5.625]:
		_wall(Vector3(seg_x, 2.0, 12), Vector3(8.75, 4.0, 0.5), C_CONCRETE)
	_v(Vector3(0, 3.6, 12), Vector3(2.7, 0.4, 0.6), C_DARKMETAL)
	# Corner posts on every partition end (voxel read).
	for p in [Vector3(-10, 2, -20), Vector3(-10, 2, 20), Vector3(10, 2, -20),
			Vector3(10, 2, 20), Vector3(-10, 2, 12), Vector3(10, 2, 12)]:
		_v(p, Vector3(0.8, 4.0, 0.8), C_WOOD_D)


func _build_mezzanine() -> void:
	# Deck: x -8..8, z -20..-14, top at y = 3. Slab + 4 support pillars;
	# the space underneath stays walkable (ambush nook).
	_v(Vector3(0, 2.9, -17), Vector3(16, 0.3, 6), C_STEEL_D)
	_solid(Vector3(0, 2.9, -17), Vector3(16, 0.3, 6))
	_nav_boxes.append([Vector3(0, 3.05, -17), Vector3(16, 0.2, 6)])
	for px in [-7.5, 7.5]:
		for pz in [-19.5, -14.5]:
			_v(Vector3(px, 1.5, pz), Vector3(0.5, 3.0, 0.5), C_DARKMETAL)
			_solid(Vector3(px, 1.5, pz), Vector3(0.5, 3.0, 0.5))
	# Stair steps up the +x side: 1 m rises to the 3 m deck.
	_v(Vector3(10.1, 0.5, -17), Vector3(1.4, 1.0, 2.0), C_CONCRETE_D)
	_solid(Vector3(10.1, 0.5, -17), Vector3(1.4, 1.0, 2.0))
	_nav_boxes.append([Vector3(10.1, 1.0, -17), Vector3(1.4, 0.2, 2.0)])
	_v(Vector3(8.7, 1.0, -17), Vector3(1.4, 2.0, 2.0), C_CONCRETE)
	_solid(Vector3(8.7, 1.0, -17), Vector3(1.4, 2.0, 2.0))
	_nav_boxes.append([Vector3(8.7, 2.0, -17), Vector3(1.4, 0.2, 2.0)])
	# Parapet on the north / south / west deck edges (+x stays open for stairs).
	_v(Vector3(0, 3.3, -19.9), Vector3(16.3, 0.6, 0.2), C_STEEL)
	_v(Vector3(0, 3.3, -14.1), Vector3(16.3, 0.6, 0.2), C_STEEL)
	_v(Vector3(-7.9, 3.3, -17), Vector3(0.2, 0.6, 6.3), C_STEEL)
	# Railing posts along the open +x edge.
	for i in 4:
		_v(Vector3(8.05, 3.45, -19.0 + float(i) * 1.4), Vector3(0.15, 0.9, 0.15), C_FORGE)


func _build_furnace() -> void:
	var p := Vector3(0, 0, 18)
	# Furnace body + glowing mouth + chimney to 9 m (grapple bait).
	_v(p + Vector3(0, 1.5, 0), Vector3(4.0, 3.0, 3.0), C_RUST)
	_v(p + Vector3(0, 0.3, 0), Vector3(4.3, 0.6, 3.3), C_DARKMETAL)
	_g(p + Vector3(0, 1.4, 1.52), Vector3(2.0, 1.2, 0.15), C_FORGE)
	_v(p + Vector3(1.2, 4.5, 0), Vector3(1.2, 9.0, 1.2), C_DARKMETAL)
	_v(p + Vector3(1.2, 9.1, 0), Vector3(1.8, 0.3, 1.8), C_RUST_D)
	_solid(p + Vector3(0, 1.5, 0), Vector3(4.0, 3.0, 3.0))
	_solid(p + Vector3(1.2, 4.5, 0), Vector3(1.2, 9.0, 1.2))
	# Coal piles flanking the furnace.
	for sx in [-3.4, 3.4]:
		for i in 6:
			_v(p + Vector3(sx + _rng.randf_range(-0.7, 0.7), 0.2, _rng.randf_range(-1.0, 1.0)),
				Vector3(0.45, 0.4, 0.45), C_DARKMETAL.darkened(0.2), _rng.randf_range(0, TAU))


func _build_crane() -> void:
	# Overhead crane beam across the hall at y = 6, hook hanging at x = 3.
	_v(Vector3(0, 6.0, -6), Vector3(16, 0.4, 0.4), C_STEEL)
	_v(Vector3(3, 5.4, -6), Vector3(0.15, 1.0, 0.15), C_DARKMETAL)
	_v(Vector3(3, 4.8, -6), Vector3(0.6, 0.7, 0.6), C_FORGE)
	for sx in [-8.0, 8.0]:
		_v(Vector3(sx, 3.0, -6), Vector3(0.4, 6.0, 0.4), C_CONCRETE)
		_solid(Vector3(sx, 3.0, -6), Vector3(0.4, 6.0, 0.4))
	# Two more hall pillars south of the beam.
	for sx in [-5.0, 5.0]:
		_v(Vector3(sx, 2.0, 4), Vector3(0.8, 4.0, 0.8), C_CONCRETE)
		_solid(Vector3(sx, 2.0, 4), Vector3(0.8, 4.0, 0.8))


func _build_workshop() -> void:
	# Workbenches down the west alley.
	for bz in [-8.0, 8.0]:
		var p := Vector3(-18, 0, bz)
		_v(p + Vector3(0, 0.45, 0), Vector3(1.8, 0.9, 0.8), C_WOOD)
		_v(p + Vector3(-0.4, 1.0, 0), Vector3(0.5, 0.3, 0.5), C_STEEL)
		_v(p + Vector3(0.5, 1.05, 0.1), Vector3(0.35, 0.4, 0.35), C_RUST)
		_solid(p + Vector3(0, 0.45, 0), Vector3(1.8, 0.9, 0.8))
	# Storage racks down the east alley (uprights + shelves + goods).
	for rz in [-6.0, 2.0, 10.0]:
		var p := Vector3(18, 0, rz)
		for sz in [-1.4, 1.4]:
			_v(p + Vector3(0, 1.1, sz), Vector3(1.2, 2.2, 0.2), C_STEEL_D)
		for sy in [0.5, 1.3, 2.0]:
			_v(p + Vector3(0, sy, 0), Vector3(1.2, 0.12, 2.8), C_WOOD_D)
			_v(p + Vector3(0, sy + 0.25, 0), Vector3(0.8, 0.4, 0.8),
				_pick([C_OLIVE, C_TAN, C_RUST]))
		_solid(p + Vector3(0, 1.1, 0), Vector3(1.2, 2.2, 2.8))


func _build_covers() -> void:
	for bp in [Vector3(-14, 0, -14), Vector3(14, 0, -14),
			Vector3(-14, 0, 14), Vector3(14, 0, 14)]:
		_cover(Vector3i(3, 4, 3), PAL_BARREL, 30.0, bp, _rng.randf_range(0, TAU))
	for cp in [Vector3(5, 0, 2), Vector3(-5, 0, -8), Vector3(-3, 0, 15)]:
		_cover(Vector3i(4, 4, 4), PAL_CRATE, 45.0, cp, _rng.randf_range(0, TAU))
	for bp in [[Vector3(0, 0, 8), 0.0], [Vector3(-7, 0, 0), PI * 0.5],
			[Vector3(7, 0, 0), PI * 0.5], [Vector3(-14, 0, 2), PI * 0.5]]:
		_cover(Vector3i(8, 5, 2), PAL_BARRIER, 70.0, bp[0], bp[1])


func _build_dressing() -> void:
	# Wall pipes along the partitions + hanging lamps in the hall.
	for z in [-16.0, -8.0, 4.0, 16.0]:
		_v(Vector3(-9.7, 3.4, z), Vector3(0.14, 0.14, 3.0), C_RUST_D)
		_v(Vector3(9.7, 3.4, z), Vector3(0.14, 0.14, 3.0), C_RUST_D)
	for p in [Vector3(0, 5.2, -2), Vector3(0, 5.2, 4), Vector3(-17, 4.6, -10), Vector3(17, 4.6, -10)]:
		_v(p + Vector3(0, 0.4, 0), Vector3(0.1, 0.8, 0.1), C_DARKMETAL)
		_g(p, Vector3(0.5, 0.25, 0.5), C_FORGE)
	# Stencil-style wall signs (flat colored panels, no collision).
	_v(Vector3(-9.7, 2.4, -6), Vector3(0.06, 1.0, 1.8), C_FORGE)
	_v(Vector3(9.7, 2.4, 6), Vector3(0.06, 1.0, 1.8), C_OLIVE)
	_v(Vector3(0, 2.4, 11.7), Vector3(2.2, 1.0, 0.06), C_TAN)


func _build_city() -> void:
	# Distant skyline ring (unshaded, same as Dustline) — visible over the
	# low perimeter from the mezzanine.
	for i in 44:
		var ang := float(i) / 44.0 * TAU + _rng.randf_range(-0.05, 0.05)
		var r := _rng.randf_range(130, 190)
		var bw := _rng.randf_range(8, 20)
		var bh := _rng.randf_range(10, 45)
		var bd := _rng.randf_range(8, 20)
		var shade := _rng.randf_range(0.8, 1.3)
		_c(Vector3(cos(ang) * r, bh * 0.5 - 2.0, sin(ang) * r), Vector3(bw, bh, bd),
			Color(0.17 * shade, 0.15 * shade, 0.25 * shade))
