# scripts/maps/zombies_flat_builder.gd
# FORGEFALL — "Zombies Flat" map (Gameplay Rework, v0.6.0 integration).
#
# A minimal flat ground-plane map for Zombies (SP + MP). ZombiesMode
# builds its Town geometry in code at the origin on top of the loaded
# map — on Dustline that geometry overlaps map props (shacks, crates,
# walls). This map is EMPTY where the town goes: one flat 120x120 m
# plane, a low perimeter ring, and a few low crate clusters at the
# corners, all clear of the town footprint (|x| <= 36, |z| <= 18),
# of the spawn doors, and of the forge pad. Nothing here can overlap
# the town; the town is the only structure in the middle of the map.
#
# Markers: "player_spawn" x4 (on the town street, clear of the PAP
# pedestal, Mystery Box spots, chalk spots, and door volumes),
# "spawn_door" x4 (perimeter faces — WaveManager spawns the horde
# there and it walks in across the flat ground), "forge_pad" x1
# (corner pad; Forge is blocked in Zombies by ForgeGate — the pad
# exists so the generic map checks see a Forge marker, like every
# other map).
#
# Same perf contract as the other maps: voxel geometry batched into
# MultiMeshes via MapBuilderBase, simplified box collision, nav baked
# from the whole ground plane (enemies path anywhere on the flat).
extends MapBuilderBase

const ARENA_HALF := 60.0
const MAP_SEED := 20261016

# Player spawns: town street runs along X at z = 0; PAP pedestal at
# the origin (radius ~1.5), Mystery Box at x = ±14, chalk spots at
# (-26,-2) / (10,-2) / (-6,2) / (26,2), east gate volume at x = 30.
# These four sit on the street clear of all of them.
const PLAYER_SPAWNS := [
	Vector3(-28, 0.3, 0), Vector3(28, 0.3, 0),
	Vector3(0, 0.3, -4), Vector3(0, 0.3, 4),
]

const SPAWN_DOORS := [
	Vector3(0, 0, -59.6), Vector3(0, 0, 59.6),
	Vector3(-59.6, 0, 0), Vector3(59.6, 0, 0),
]

const FORGE_PADS := [Vector3(52, 0, 52)]

# Edge dressing: low crate clusters at the four corners, well clear
# of the town footprint, the spawn doors, and the forge pad.
const CRATE_CLUSTERS := [
	Vector3(-48, 0, -32), Vector3(48, 0, -32),
	Vector3(-48, 0, 32), Vector3(48, 0, 32),
]


func _ready() -> void:
	_rng.seed = MAP_SEED
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_build_environment(0.006)
	_build_ground()
	_build_perimeter(ARENA_HALF, 2.5, 3.0)
	_build_crate_clusters()
	_build_spawn_markers(PLAYER_SPAWNS, SPAWN_DOORS, FORGE_PADS, ARENA_HALF)
	_commit_multimeshes(AABB(Vector3(-ARENA_HALF, -2, -ARENA_HALF),
		Vector3(ARENA_HALF * 2, 20, ARENA_HALF * 2)))
	_build_motes(Vector3(50, 3.5, 50), 150)
	_bake_nav()


func _build_ground() -> void:
	_v(Vector3(0, -0.25, 0), Vector3(120, 0.5, 120), C_DIRT)
	_solid(Vector3(0, -0.25, 0), Vector3(120, 0.5, 120))
	_nav_boxes.append([Vector3(0, 0, 0), Vector3(120, 0.5, 120)])


func _build_crate_clusters() -> void:
	for c in CRATE_CLUSTERS:
		# Three low crates per cluster (<= 1 m tall): dressing only,
		# never a wall the horde or the town has to route around.
		_v(c + Vector3(0, 0.5, 0), Vector3(1.2, 1.0, 1.2), C_WOOD)
		_solid(c + Vector3(0, 0.5, 0), Vector3(1.2, 1.0, 1.2))
		_v(c + Vector3(1.5, 0.4, 0.4), Vector3(0.8, 0.8, 0.8), C_WOOD_D)
		_solid(c + Vector3(1.5, 0.4, 0.4), Vector3(0.8, 0.8, 0.8))
		_v(c + Vector3(-1.4, 0.3, -0.6), Vector3(0.9, 0.6, 0.9), C_RUST)
		_solid(c + Vector3(-1.4, 0.3, -0.6), Vector3(0.9, 0.6, 0.9))
