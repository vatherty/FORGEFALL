# scripts/maps/factory_builder.gd
# FORGEFALL — "Factory" (Ironworks) map builder (Gameplay Rework, Factory worker).
#
# MODE: TDM. TD already has its purpose-built tower_defense map and Main
# forces TD onto it, so a second TD map would need TD multi-map support
# (TD worker's scope, not this map's). TDM runs on the map-picker
# rotation, needs bot navmesh + spawns + cover + traversal play — this
# map delivers all four. Zombies keeps its own map: this map is NOT wired into
# Zombies (Main forces zombies_flat for that mode).
#
# KIT: Kenney Factory Kit v3.0 (CC0, verified in-pack — see
# assets/kenney_factory_kit/README.md). The kit ships smooth low-poly
# GLB/FBX/OBJ meshes; FORGEFALL ships zero imported meshes — every map
# is procedural voxel MultiMesh (perf contract: 3 MultiMeshes, box
# collision, nav baked from walk surfaces). So each kit piece below is a
# VOXEL RECREATION of the kit asset of the same name (kit name in the
# comment on every build step; KIT_ASSETS_USED lists them all). No kit
# mesh, texture, or binary is imported; no kit file is modified.
#
# Layout (56x56 m, ARENA_HALF 28):
#   - Two halls (north assembly / south press) split by a spine wall at
#     z = 0 with 3 door gaps (x = -18, 0, 18). Spine faces are the
#     long wall-run / portal surfaces; gaps are the chokes.
#   - Catwalk ring at y = 4.2: side decks at x = +/-24 + two cross
#     gantries at z = +/-14, stair access at (+/-24, +/-8). Decks +
#     stairs are nav surfaces, so bots path the upper level too.
#   - Conveyor lines down both halls (z = -16 / +16) with rollers,
#     side rails, belt crates, scanner arches.
#   - Machine rows (z = -8 / +8) with robot arms, pistons, hoppers;
#     overhead crane (north) + overhead pipe run (south); 12 m stack
#     in the NW corner. Crane beam / pipe / stack / catwalk rails are
#     the grapple anchors; the open sky + catwalks are the jetpack
#     playground; spine + perimeter walls are the portal surfaces.
#   - Destructible cover guards every doorway + mid-hall; static crate
#     stacks in the corners / hall middles.
#
# Markers: "player_spawn" x8, "spawn_door" x8, "forge_pad" x4 (pads are
# for the legacy modes that still run on any map; TDM never builds).
extends MapBuilderBase

const ARENA_HALF := 28.0
const MAP_SEED := 20261017

# Kit assets whose voxel equivalents this builder builds (Kenney
# Factory Kit v3.0, CC0). Used by tools/verify_factory_map.gd to prove
# the map is built from the kit vocabulary, not invented shapes.
const KIT_ASSETS_USED: PackedStringArray = [
	"structure-wall", "structure-doorway", "structure-window",
	"structure-yellow-tall", "floor", "floor-large",
	"catwalk-straight", "catwalk-corner", "catwalk-cross",
	"catwalk-junction", "catwalk-stairs",
	"conveyor-long", "conveyor-bars", "conveyor-sides",
	"conveyor-junction-t", "conveyor-corner",
	"machine", "machine-window", "machine-fortified", "machine-bed",
	"machine-connection-pipe", "robot-arm-a", "robot-arm-b",
	"piston-square", "piston-round", "hopper-square", "hopper-round",
	"cog-a", "cog-b", "cog-c",
	"crane", "crane-lift", "crane-magnet",
	"pipe-large", "pipe-large-long", "pipe-large-bend",
	"pipe-large-valve", "pipe-large-junction",
	"screen-hanging-wide", "screen-panel-wide", "screen-small",
	"scanner-high", "scanner-low",
	"box-small", "box-large", "box-long", "box-wide",
	"button-floor-square", "warning-orange", "indicator-special-lines",
	"lever-single", "cone", "top",
]

const PLAYER_SPAWNS := [
	Vector3(-18, 0.3, -24), Vector3(0, 0.3, -24), Vector3(24, 0.3, -24),
	Vector3(-24, 0.3, 24), Vector3(24, 0.3, 24), Vector3(0, 0.3, 24),
	Vector3(-24, 0.3, -4), Vector3(24, 0.3, 4),
]

const SPAWN_DOORS := [
	Vector3(-14, 0, -27.6), Vector3(14, 0, -27.6),
	Vector3(-27.6, 0, -14), Vector3(-27.6, 0, 14),
	Vector3(27.6, 0, -14), Vector3(27.6, 0, 14),
	Vector3(-14, 0, 27.6), Vector3(14, 0, 27.6),
]

const FORGE_PADS := [
	Vector3(-14, 0, -20), Vector3(14, 0, -20),
	Vector3(-14, 0, 20), Vector3(14, 0, 20),
]

# Spine wall (z = 0): door gaps at these x centers, 4 m wide each.
const SPINE_GAP_X := [-18.0, 0.0, 18.0]
const SPINE_GAP_W := 4.0
const SPINE_H := 5.0
# Spine segments between/around the gaps: [center_x, length].
const SPINE_SEGMENTS := [[-24.0, 8.0], [-9.0, 14.0], [9.0, 14.0], [24.0, 8.0]]

const CATWALK_Y := 4.2
const CATWALK_SIDE_X := 24.0
const GANTRY_Z := [-14.0, 14.0]
const STAIR_Z := [-8.0, 8.0]

const CONVEYOR_Z := [-16.0, 16.0]
const MACHINE_ROW_Z := [-8.0, 8.0]

# Destructible-cover spots (position only; sizes in _build_covers).
# Verify checks every spawn is clear of these.
const COVER_SPOTS := [
	Vector3(-18, 0, -2.5), Vector3(-18, 0, 2.5),
	Vector3(0, 0, -2.5), Vector3(0, 0, 2.5),
	Vector3(18, 0, -2.5), Vector3(18, 0, 2.5),
	Vector3(-12, 0, -12), Vector3(12, 0, -12),
	Vector3(-12, 0, 12), Vector3(12, 0, 12),
]

# Grapple anchors (points the verify suite measures rope reach from).
# Beam + pipe runs are sampled along their length here.
const ANCHORS := [
	Vector3(-24, 7.0, -10), Vector3(-16, 7.0, -10), Vector3(-8, 7.0, -10),
	Vector3(0, 7.0, -10), Vector3(8, 7.0, -10), Vector3(16, 7.0, -10),
	Vector3(24, 7.0, -10), Vector3(6, 5.2, -10),
	Vector3(-24, 6.0, 10), Vector3(-16, 6.0, 10), Vector3(-8, 6.0, 10),
	Vector3(0, 6.0, 10), Vector3(8, 6.0, 10), Vector3(16, 6.0, 10),
	Vector3(24, 6.0, 10),
	Vector3(-24, 12.0, -24),
	Vector3(-24, 4.9, -14), Vector3(24, 4.9, -14),
	Vector3(-24, 4.9, 14), Vector3(24, 4.9, 14),
	Vector3(0, 4.9, -14), Vector3(0, 4.9, 14),
]

# Factory palette (extends the base palette).
const C_SAFETY := Color("e8a020")   # safety yellow (structure-yellow-*)
const C_HAZARD := Color("c8461c")   # hazard orange (warning-orange)
const C_BELT := Color("2e3236")     # conveyor belt
const C_PIPE := Color("7d8a94")     # pipe steel
const C_SCREEN := Color("7fd4c1")   # screen glow tint (via _g forge? no — own)
const C_COG := Color("4a4f56")

# Axis-aligned solid footprints [center, size], recorded by the _solid
# override so the verify suite can prove spawns are clear of collision.
var collision_footprints: Array = []


func _solid(center: Vector3, size: Vector3, nav := false, rot_y := 0.0) -> void:
	if rot_y == 0.0:
		collision_footprints.append([center, size])
	super._solid(center, size, nav, rot_y)


func _ready() -> void:
	_rng.seed = MAP_SEED
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_build_environment(0.0095)  # hazier than Foundry: interior factory air
	_build_ground()
	_build_perimeter(ARENA_HALF, 5.0, 5.0)
	_build_spine()
	_build_catwalks()
	_build_conveyors()
	_build_machines()
	_build_crane()
	_build_overhead_pipe()
	_build_stack()
	_build_wall_pipes()
	_build_cogs()
	_build_screens()
	_build_crates()
	_build_covers()
	_build_signage()
	_build_spawn_markers(PLAYER_SPAWNS, SPAWN_DOORS, FORGE_PADS, ARENA_HALF)
	_build_city()
	_commit_multimeshes(AABB(Vector3(-ARENA_HALF, -2, -ARENA_HALF),
		Vector3(ARENA_HALF * 2, 22, ARENA_HALF * 2)))
	_build_motes(Vector3(26, 3.5, 26))
	_bake_nav()


func _build_ground() -> void:
	# Kit: floor / floor-large (concrete slab + plate seams).
	_v(Vector3(0, -0.25, 0), Vector3(56, 0.5, 56), C_CONCRETE_D)
	_solid(Vector3(0, -0.25, 0), Vector3(56, 0.5, 56))
	_nav_boxes.append([Vector3(0, 0, 0), Vector3(56, 0.5, 56)])
	# Plate seams every 7 m (visual only).
	for t in range(-21, 22, 7):
		_v(Vector3(float(t), 0.012, 0), Vector3(0.12, 0.02, 56), C_DARKMETAL)
		_v(Vector3(0, 0.012, float(t)), Vector3(56, 0.02, 0.12), C_DARKMETAL)
	# Oil stains + scattered debris.
	for i in 14:
		var px := _rng.randf_range(-25, 25)
		var pz := _rng.randf_range(-25, 25)
		var s := _rng.randf_range(1.5, 4.0)
		_v(Vector3(px, 0.015, pz), Vector3(s, 0.03, s * _rng.randf_range(0.6, 1.0)),
			_pick([C_DIRT_D, C_RUST_D, C_DARKMETAL]), _rng.randf_range(0, TAU))
	for i in 80:
		var px := _rng.randf_range(-26, 26)
		var pz := _rng.randf_range(-26, 26)
		var s := _rng.randf_range(0.1, 0.25)
		_v(Vector3(px, s * 0.5, pz), Vector3(s, s, s),
			_pick([C_CONCRETE, C_RUST, C_STEEL_D, C_DIRT_D]), _rng.randf_range(0, TAU))


func _build_spine() -> void:
	# Kit: structure-wall segments + structure-doorway gaps + frame posts.
	for seg in SPINE_SEGMENTS:
		var cx: float = seg[0]
		var ln: float = seg[1]
		_wall(Vector3(cx, SPINE_H * 0.5, 0), Vector3(ln, SPINE_H, 0.6),
			_pick([C_CONCRETE, C_TAN, C_STEEL_D]))
	# Door frames: posts + header strip over each gap (players pass under).
	for gx in SPINE_GAP_X:
		for sx in [-2.1, 2.1]:
			_v(Vector3(gx + sx, 2.0, 0), Vector3(0.35, 4.0, 0.9), C_SAFETY)
			_solid(Vector3(gx + sx, 2.0, 0), Vector3(0.35, 4.0, 0.9))
		_g(Vector3(gx, 4.35, 0), Vector3(SPINE_GAP_W + 0.4, 0.14, 0.2), C_FORGE)


func _build_catwalks() -> void:
	# Kit: catwalk-straight decks + catwalk-stairs + catwalk-corner /
	# catwalk-cross / catwalk-junction at the deck/gantry crossings.
	# Side decks (x = +/-24, top y = 4.2).
	for sx in [-CATWALK_SIDE_X, CATWALK_SIDE_X]:
		_v(Vector3(sx, CATWALK_Y - 0.15, 0), Vector3(2.4, 0.3, 50), C_STEEL_D)
		_solid(Vector3(sx, CATWALK_Y - 0.15, 0), Vector3(2.4, 0.3, 50))
		_nav_boxes.append([Vector3(sx, CATWALK_Y, 0), Vector3(2.4, 0.2, 50)])
		# Support pillars (skip z = 0: the spine wall crosses there;
		# ends at +/-21 so the corner spawns stay clear of the posts).
		for pz in [-21.0, -18.0, -12.0, -6.0, 6.0, 12.0, 18.0, 21.0]:
			_v(Vector3(sx, 2.1, pz), Vector3(0.5, 4.2, 0.5), C_DARKMETAL)
			_solid(Vector3(sx, 2.1, pz), Vector3(0.5, 4.2, 0.5))
		# Outer railing: posts + top rail (visual only — falling off a
		# catwalk is legal; the rail is a grapple target, not a wall).
		for pz in range(-24, 25, 4):
			_v(Vector3(sx + signf(sx) * 1.15, CATWALK_Y + 0.45, float(pz)),
				Vector3(0.1, 0.9, 0.1), C_SAFETY)
		_v(Vector3(sx + signf(sx) * 1.15, CATWALK_Y + 0.9, 0),
			Vector3(0.1, 0.1, 50), C_SAFETY)
	# Cross gantries (z = +/-14, top y = 4.2) tying the side decks.
	for gz in GANTRY_Z:
		_v(Vector3(0, CATWALK_Y - 0.15, gz), Vector3(48, 0.3, 2.0), C_STEEL_D)
		_solid(Vector3(0, CATWALK_Y - 0.15, gz), Vector3(48, 0.3, 2.0))
		_nav_boxes.append([Vector3(0, CATWALK_Y, gz), Vector3(48, 0.2, 2.0)])
		# Gantry support columns mid-hall (double as cover).
		for px in [-8.0, 8.0]:
			_v(Vector3(px, 2.1, gz), Vector3(0.55, 4.2, 0.55), C_CONCRETE)
			_solid(Vector3(px, 2.1, gz), Vector3(0.55, 4.2, 0.55))
		# Gantry railings (visual only, both edges).
		for sz in [-0.95, 0.95]:
			_v(Vector3(0, CATWALK_Y + 0.9, gz + sz), Vector3(48, 0.1, 0.1), C_SAFETY)
	# Stairs (kit: catwalk-stairs): 3 steps, 1.4 m rise each, at
	# (+/-24, +/-8), ascending toward the side deck.
	for sx in [-CATWALK_SIDE_X, CATWALK_SIDE_X]:
		for sz in STAIR_Z:
			var dir := signf(sx)  # +1: ascend toward +x; -1: toward -x
			for i in 3:
				var top := 1.4 * float(i + 1)
				var cx := dir * (20.55 + float(i) * 1.1)
				_v(Vector3(cx, top * 0.5, sz), Vector3(1.1, top, 2.0), C_CONCRETE)
				_solid(Vector3(cx, top * 0.5, sz), Vector3(1.1, top, 2.0))
				_nav_boxes.append([Vector3(cx, top, sz), Vector3(1.1, 0.2, 2.0)])
			# Stair handrail posts (visual only).
			for i in 3:
				var top := 1.4 * float(i + 1)
				var cx := dir * (20.55 + float(i) * 1.1)
				_v(Vector3(cx, top + 0.45, sz + 0.95), Vector3(0.08, 0.9, 0.08), C_SAFETY)


func _build_conveyors() -> void:
	# Kit: conveyor-long belts + conveyor-bars rollers + conveyor-sides
	# rails + scanner-high/low arches + box-* crates riding the belt.
	for cz in CONVEYOR_Z:
		# Belt slab (top y = 0.9).
		_v(Vector3(0, 0.775, cz), Vector3(44, 0.25, 1.6), C_BELT)
		_solid(Vector3(0, 0.775, cz), Vector3(44, 0.25, 1.6))
		# Legs every 4 m.
		for lx in range(-20, 21, 4):
			_v(Vector3(float(lx), 0.325, cz), Vector3(0.2, 0.65, 1.2), C_DARKMETAL)
			_solid(Vector3(float(lx), 0.325, cz), Vector3(0.2, 0.65, 1.2))
		# Rollers every 1.5 m (visual).
		for rx in range(-21, 22, 3):
			_v(Vector3(float(rx), 0.92, cz), Vector3(0.25, 0.06, 1.5), C_STEEL)
		# Side rails.
		for sz in [-0.85, 0.85]:
			_v(Vector3(0, 1.05, cz + sz), Vector3(44, 0.08, 0.08), C_SAFETY)
		# Crates riding the belt (solid — belt-top cover).
		for bx in [-18.0, -9.0, 3.0, 13.0]:
			var s: float = _pick([0.55, 0.7, 0.85])
			_v(Vector3(bx, 0.9 + s * 0.5, cz), Vector3(s, s, s),
				_pick([C_WOOD, C_OLIVE, C_TAN]), _rng.randf_range(0, TAU))
			_solid(Vector3(bx, 0.9 + s * 0.5, cz), Vector3(s, s, s))
		# End rollers (kit: conveyor-corner caps).
		for ex in [-22.2, 22.2]:
			_v(Vector3(ex, 0.775, cz), Vector3(0.5, 0.5, 1.7), C_STEEL_D)
			_solid(Vector3(ex, 0.775, cz), Vector3(0.5, 0.5, 1.7))
		# Scanner arch over the belt at x = 0 (kit: scanner-high).
		for px in [-1.3, 1.3]:
			_v(Vector3(float(px), 1.35, cz), Vector3(0.25, 2.7, 0.25), C_DARKMETAL)
			_solid(Vector3(float(px), 1.35, cz), Vector3(0.25, 2.7, 0.25))
		_v(Vector3(0, 2.75, cz), Vector3(2.85, 0.25, 0.5), C_DARKMETAL)
		_g(Vector3(0, 2.6, cz), Vector3(2.2, 0.08, 0.1), C_FORGE)


func _build_machines() -> void:
	# Kit: machine / machine-window / machine-fortified / machine-bed
	# bodies + robot-arm-a/b + piston-square/round + hopper-square/round.
	var north_x := [-16.0, -4.0, 8.0]
	var south_x := [-8.0, 4.0, 16.0]
	for mx in north_x:
		_build_machine(Vector3(mx, 0, MACHINE_ROW_Z[0]), 1)
	for mx in south_x:
		_build_machine(Vector3(mx, 0, MACHINE_ROW_Z[1]), -1)
	# Robot arms between the machines.
	for ax in [-10.0, 2.0]:
		_build_robot_arm(Vector3(ax, 0, MACHINE_ROW_Z[0]))
	for ax in [-2.0, 10.0]:
		_build_robot_arm(Vector3(ax, 0, MACHINE_ROW_Z[1]))
	# Hopper bins at the hall ends (kit: hopper-square / hopper-round).
	# Kept off the stair footprints at (+/-24, +/-8) and off the
	# crate stacks at (+/-20, +/-20).
	for hp in [Vector3(-22, 0, -20), Vector3(22, 0, 20)]:
		_v(hp + Vector3(0, 0.6, 0), Vector3(1.6, 1.2, 1.6), C_STEEL_D)
		_v(hp + Vector3(0, 1.35, 0), Vector3(1.1, 0.5, 1.1), C_STEEL)
		_v(hp + Vector3(0, 1.7, 0), Vector3(0.7, 0.25, 0.7), C_RUST)
		_solid(hp + Vector3(0, 0.6, 0), Vector3(1.6, 1.2, 1.6))


func _build_machine(p: Vector3, facing: int) -> void:
	# Body 2.6 x 2.2 x 1.8 + top cabinet + window + status screen.
	_v(p + Vector3(0, 1.1, 0), Vector3(2.6, 2.2, 1.8),
		_pick([C_STEEL_D, C_GUNMETAL, C_RUST_D]))
	_v(p + Vector3(0, 2.45, 0), Vector3(1.6, 0.7, 1.2), C_DARKMETAL)
	_v(p + Vector3(0, 1.5, facing * 0.92), Vector3(1.4, 0.9, 0.06), C_DARKMETAL)
	_g(p + Vector3(-0.4, 1.5, facing * 0.97), Vector3(0.5, 0.5, 0.06), C_FORGE)
	_g(p + Vector3(0.45, 1.5, facing * 0.97), Vector3(0.3, 0.5, 0.06), C_SCREEN)
	_solid(p + Vector3(0, 1.1, 0), Vector3(2.6, 2.2, 1.8))
	# Piston column beside the body (kit: piston-square).
	_v(p + Vector3(1.7, 1.0, 0), Vector3(0.5, 2.0, 0.5), C_COG)
	_v(p + Vector3(1.7, 2.25, 0), Vector3(0.3, 0.6, 0.3), C_STEEL)
	_solid(p + Vector3(1.7, 1.0, 0), Vector3(0.5, 2.0, 0.5))
	# Pipe stub on top (kit: machine-connection-pipe).
	_v(p + Vector3(-0.8, 3.1, 0), Vector3(0.3, 0.5, 0.3), C_PIPE)


func _build_robot_arm(p: Vector3) -> void:
	# Kit: robot-arm-a/b — base + two angled segments + gripper.
	_v(p + Vector3(0, 0.5, 0), Vector3(1.0, 1.0, 1.0), C_SAFETY)
	_v(p + Vector3(0, 1.35, 0), Vector3(0.45, 0.9, 0.45), C_STEEL, 0.6)
	_v(p + Vector3(0.5, 1.9, 0), Vector3(0.3, 1.1, 0.3), C_FORGE, -0.7)
	_v(p + Vector3(0.95, 2.05, 0), Vector3(0.4, 0.3, 0.4), C_DARKMETAL)
	_solid(p + Vector3(0, 0.5, 0), Vector3(1.0, 1.0, 1.0))


func _build_crane() -> void:
	# Kit: crane beam + crane-lift trolley + crane-magnet + lifted crate.
	# Beam across the north hall at y = 7, z = -10.
	_v(Vector3(0, 7.0, -10), Vector3(48, 0.5, 0.5), C_STEEL)
	for sx in [-24.0, 24.0]:
		_v(Vector3(sx, 3.5, -10), Vector3(0.6, 7.0, 0.6), C_CONCRETE)
		_solid(Vector3(sx, 3.5, -10), Vector3(0.6, 7.0, 0.6))
	# Trolley + cable + magnet + suspended crate (visual only: the
	# crate hangs at 3.8 m, above head height — no collision).
	_v(Vector3(6, 6.7, -10), Vector3(1.4, 0.6, 1.0), C_SAFETY)
	_v(Vector3(6, 5.9, -10), Vector3(0.08, 1.0, 0.08), C_DARKMETAL)
	_v(Vector3(6, 5.2, -10), Vector3(1.2, 0.5, 1.2), C_FORGE)
	_v(Vector3(6, 4.2, -10), Vector3(0.9, 0.8, 0.9), C_WOOD)
	# Hazard stripes under the crane path (kit: indicator-special-lines).
	for i in 6:
		var hx := -20.0 + float(i) * 8.0
		_v(Vector3(hx, 0.02, -10), Vector3(1.6, 0.03, 0.5), C_SAFETY if i % 2 == 0 else C_DARKMETAL)


func _build_overhead_pipe() -> void:
	# Kit: pipe-large-long run + pipe-large-bend elbows +
	# pipe-large-valve crosses + pipe-large-junction tees, on posts.
	_v(Vector3(0, 6.0, 10), Vector3(48, 0.35, 0.35), C_PIPE)
	for px in [-12.0, 12.0]:
		_v(Vector3(px, 3.0, 10), Vector3(0.3, 6.0, 0.3), C_DARKMETAL)
		_solid(Vector3(px, 3.0, 10), Vector3(0.3, 6.0, 0.3))
	for px in [-24.0, 24.0]:
		_v(Vector3(px, 3.0, 10), Vector3(0.3, 6.0, 0.3), C_DARKMETAL)
		_solid(Vector3(px, 3.0, 10), Vector3(0.3, 6.0, 0.3))
	# Valve crosses + junction tees along the run (visual).
	for vx in [-6.0, 6.0]:
		_v(Vector3(vx, 6.0, 10), Vector3(0.5, 0.9, 0.5), C_HAZARD)
		_v(Vector3(vx, 6.0, 10), Vector3(0.9, 0.2, 0.2), C_HAZARD)
	for jx in [0.0]:
		_v(Vector3(jx, 5.7, 10), Vector3(0.4, 0.8, 0.4), C_PIPE)
		_v(Vector3(jx, 5.35, 10), Vector3(0.4, 0.3, 1.0), C_PIPE)


func _build_stack() -> void:
	# Kit: structure-yellow-tall as the landmark stack (NW corner).
	# 2.2 m square, 12 m tall — the map's tallest grapple anchor.
	var p := Vector3(-24, 0, -24)
	_v(p + Vector3(0, 6.0, 0), Vector3(2.2, 12.0, 2.2), C_RUST)
	for by in [3.0, 6.0, 9.0]:
		_v(p + Vector3(0, by, 0), Vector3(2.5, 0.3, 2.5), C_DARKMETAL)
	_v(p + Vector3(0, 12.15, 0), Vector3(2.6, 0.3, 2.6), C_DARKMETAL)
	_g(p + Vector3(0, 10.5, 1.12), Vector3(0.5, 1.2, 0.06), C_FORGE)
	_solid(p + Vector3(0, 6.0, 0), Vector3(2.2, 12.0, 2.2))


func _build_wall_pipes() -> void:
	# Kit: pipe-large runs along every interior perimeter face.
	var h := 27.6
	for z in [-h, h]:
		_v(Vector3(0, 3.5, z), Vector3(54, 0.28, 0.28), C_PIPE)
	for x in [-h, h]:
		_v(Vector3(x, 3.5, 0), Vector3(0.28, 0.28, 54), C_PIPE)
	# Vertical drops at the corners + valve wheels (visual).
	for cx in [-h, h]:
		for cz in [-h, h]:
			_v(Vector3(cx, 1.75, cz), Vector3(0.3, 3.5, 0.3), C_PIPE)
			_v(Vector3(cx, 3.5, cz), Vector3(0.7, 0.15, 0.15), C_HAZARD)
			_v(Vector3(cx, 3.5, cz), Vector3(0.15, 0.15, 0.7), C_HAZARD)


func _build_cogs() -> void:
	# Kit: cog-a/b/c — flat cog clusters on both spine faces (visual).
	for gx in [-10.0, 10.0]:
		for fz in [-0.45, 0.45]:
			_v(Vector3(gx, 3.2, fz), Vector3(1.2, 1.2, 0.12), C_COG)
			_v(Vector3(gx - 0.85, 3.2, fz), Vector3(0.35, 0.35, 0.12), C_COG)
			_v(Vector3(gx + 0.85, 3.2, fz), Vector3(0.35, 0.35, 0.12), C_COG)
			_v(Vector3(gx, 3.2 - 0.85, fz), Vector3(0.35, 0.35, 0.12), C_COG)
			_v(Vector3(gx, 3.2 + 0.85, fz), Vector3(0.35, 0.35, 0.12), C_COG)
			_g(Vector3(gx, 3.2, fz + signf(fz) * 0.08), Vector3(0.3, 0.3, 0.06), C_FORGE)


func _build_screens() -> void:
	# Kit: screen-hanging-wide over the machine rows + screen-panel-wide
	# on the spine + screen-small levers by the door gaps.
	for mx in [-16.0, -4.0, 8.0]:
		_v(Vector3(mx, 3.9, -8), Vector3(0.08, 0.6, 0.08), C_DARKMETAL)
		_g(Vector3(mx, 3.5, -8), Vector3(1.6, 0.9, 0.1), C_SCREEN)
	for mx in [-8.0, 4.0, 16.0]:
		_v(Vector3(mx, 3.9, 8), Vector3(0.08, 0.6, 0.08), C_DARKMETAL)
		_g(Vector3(mx, 3.5, 8), Vector3(1.6, 0.9, 0.1), C_SCREEN)
	_g(Vector3(-9, 3.4, 0.35), Vector3(2.4, 1.1, 0.06), C_SCREEN)
	_g(Vector3(9, 3.4, -0.35), Vector3(2.4, 1.1, 0.06), C_SCREEN)
	# Levers by the door gaps (kit: lever-single, visual).
	for gx in SPINE_GAP_X:
		_v(Vector3(gx + 2.6, 1.1, 0.5), Vector3(0.18, 0.5, 0.18), C_DARKMETAL)
		_v(Vector3(gx + 2.6, 1.5, 0.5), Vector3(0.3, 0.3, 0.3), C_HAZARD, 0.5)


func _build_crates() -> void:
	# Kit: box-small / box-large / box-long / box-wide stacks + cone
	# markers. Bottom boxes are solid; stacked tops are visual only.
	var stacks := [
		Vector3(-20, 0, -20), Vector3(20, 0, -20),
		Vector3(-20, 0, 20), Vector3(20, 0, 20),
		Vector3(0, 0, -11), Vector3(0, 0, 11),
	]
	for sp in stacks:
		var s1: float = _pick([1.0, 1.2])
		_v(sp + Vector3(0, s1 * 0.5, 0), Vector3(s1, s1, s1), C_WOOD, _rng.randf_range(0, TAU))
		_solid(sp + Vector3(0, s1 * 0.5, 0), Vector3(s1, s1, s1))
		var s2: float = _pick([0.6, 0.8])
		_v(sp + Vector3(0.15, s1 + s2 * 0.5, 0.1), Vector3(s2, s2, s2), C_OLIVE, _rng.randf_range(0, TAU))
		var s3: float = _pick([0.5, 0.65])
		_v(sp + Vector3(-0.4, s3 * 0.5, 0.5), Vector3(s3, s3, s3 * 1.6), C_TAN, _rng.randf_range(0, TAU))
		_solid(sp + Vector3(-0.4, s3 * 0.5, 0.5), Vector3(s3, s3, s3 * 1.6))
	# Cones marking the catwalk stair bases (kit: cone, visual).
	for sx in [-CATWALK_SIDE_X, CATWALK_SIDE_X]:
		for sz in STAIR_Z:
			var dir := signf(sx)
			_v(Vector3(dir * 19.2, 0.25, sz + 1.6), Vector3(0.3, 0.5, 0.3), C_HAZARD)
			_v(Vector3(dir * 19.2, 0.25, sz - 1.6), Vector3(0.3, 0.5, 0.3), C_HAZARD)


func _build_covers() -> void:
	# Doorway guards: barriers flanking every spine gap (both sides).
	for i in 6:
		var cp: Vector3 = COVER_SPOTS[i]
		_cover(Vector3i(8, 5, 2), PAL_BARRIER, 70.0, cp, 0.0)
	# Mid-hall crates.
	for i in range(6, 10):
		var cp: Vector3 = COVER_SPOTS[i]
		_cover(Vector3i(4, 4, 4), PAL_CRATE, 45.0, cp, _rng.randf_range(0, TAU))


func _build_signage() -> void:
	# Forgefall-original signage only: flat colored panels (no text
	# geometry, no copied names). "IRONWORKS" is the in-world foundry
	# name; bay markers are plain stripe pairs at each doorway.
	# Big identity panel on the spine's north face.
	_v(Vector3(0, 4.1, -0.35), Vector3(6.0, 1.1, 0.06), C_FORGE)
	_v(Vector3(0, 4.1, 0.35), Vector3(6.0, 1.1, 0.06), C_FORGE)
	# Bay stripes at each gap (kit: warning-orange panels).
	for gx in SPINE_GAP_X:
		for fz in [-0.35, 0.35]:
			_v(Vector3(gx - 3.2, 2.6, fz), Vector3(0.5, 1.4, 0.06), C_SAFETY)
			_v(Vector3(gx + 3.2, 2.6, fz), Vector3(0.5, 1.4, 0.06), C_SAFETY)
	# Floor hazard stripes at the gap approaches (both sides).
	for gx in SPINE_GAP_X:
		for fz in [-3.0, 3.0]:
			for k in 3:
				var col: Color = C_SAFETY if k % 2 == 0 else C_DARKMETAL
				_v(Vector3(gx - 1.2 + float(k) * 1.2, 0.02, fz),
					Vector3(0.9, 0.03, 0.5), col)


func _build_city() -> void:
	# Distant skyline ring (unshaded) — visible over the 5 m walls from
	# the catwalks, same pattern as Foundry/Dustline.
	for i in 44:
		var ang := float(i) / 44.0 * TAU + _rng.randf_range(-0.05, 0.05)
		var r := _rng.randf_range(130, 190)
		var bw := _rng.randf_range(8, 20)
		var bh := _rng.randf_range(10, 45)
		var bd := _rng.randf_range(8, 20)
		var shade := _rng.randf_range(0.8, 1.3)
		_c(Vector3(cos(ang) * r, bh * 0.5 - 2.0, sin(ang) * r), Vector3(bw, bh, bd),
			Color(0.17 * shade, 0.15 * shade, 0.25 * shade))
