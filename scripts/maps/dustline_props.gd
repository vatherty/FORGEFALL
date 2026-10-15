# scripts/maps/dustline_props.gd
# FORGEFALL — "Dustline" dressing props (Worker A2).
#
# Self-contained dressing for the Dustline arena: crates, barrels, sandbag
# lines, signage, ground variation, one laundry line, one freestanding
# canopy. The coordinator instances this scene into the game; it never edits
# dustline.tscn / dustline_builder.gd itself.
#
# Design:
#   - Palette mirrors VoxelBuilder.PALETTE hex values (zero load-order dep).
#   - PERF: ALL prop visuals live in TWO MultiMeshInstance3D nodes
#     (opaque + emissive glow strips) = +2 draw calls. Collision is simple
#     axis-aligned boxes under ONE StaticBody3D — never per-voxel.
#   - CLEARANCES (mirrored from dustline_builder.gd): arena 70x70 (walls at
#     +-34); player spawns (±30,±30) + (0,29); spawn doors on inner wall
#     faces; rooftop stair routes on the +x side of the four 3 m roof
#     shacks. Every prop below was placed in a gap between those, >= ~2 m
#     from any spawn point, door, or stair step, and clear of shacks /
#     stalls / cars / destructible covers / forge pads / laundry poles.
#   - Ground patches are flat 0.03 m decals (no collision, walkable).
#     Hanging cloth + sign boards sit above head height (no collision).
#     Everything solid-looking gets a collision box.
extends Node3D

# Palette (mirrors VoxelBuilder.PALETTE hex values).
const C_GUNMETAL := Color("3a3f44")
const C_DARKMETAL := Color("23262a")
const C_TAN := Color("c2a878")
const C_RUST := Color("8a4b2a")
const C_RUST_D := Color("653620")
const C_CONCRETE := Color("9a958c")
const C_CONCRETE_D := Color("7d786f")
const C_WOOD := Color("7a5c38")
const C_WOOD_D := Color("57412a")
const C_CANVAS := Color("b8a888")
const C_OLIVE := Color("5a6b3c")
const C_FORGE := Color("ff7b1c")
const C_DIRT_D := Color("6b5844")
const C_CLOTH_BLUE := Color("5a7a9a")
const C_CLOTH_RED := Color("9a4a3a")

const ARENA_HALF := 35.0
const MAX_PROPS := 40
const MAX_MULTIMESH_NODES := 3

# Logical prop centers (one per solid prop) — the verifier checks each has
# a collision box nearby. Flat ground patches are NOT listed (no collision).
var solid_centers: Array = []
var prop_count := 0
var collision_count := 0
var multimesh_instance_total := 0

var _main: Array = []  # [pos, size, color] opaque voxel boxes
var _glow: Array = []  # [pos, size, color] emissive boxes
var _unit_box: BoxMesh
var _collision_root: StaticBody3D


func _ready() -> void:
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE
	_collision_root = StaticBody3D.new()
	_collision_root.name = "PropCollision"
	add_child(_collision_root)

	_build_crate_stacks()
	_build_barrel_clusters()
	_build_sandbag_lines()
	_build_signs()
	_build_ground_variation()
	_build_laundry_line()
	_build_canopy()

	_commit_multimeshes()
	prop_count = solid_centers.size()
	collision_count = _collision_root.get_child_count()


# ------------------------------------------------------------------ helpers

func _v(pos: Vector3, size: Vector3, color: Color) -> void:
	_main.append([pos, size, color])


func _g(pos: Vector3, size: Vector3, color: Color) -> void:
	_glow.append([pos, size, color])


func _solid(center: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = center
	_collision_root.add_child(cs)
	solid_centers.append(center)


# --------------------------------------------------------------- multimesh

func _commit_multimeshes() -> void:
	var mat_main := StandardMaterial3D.new()
	mat_main.albedo_color = Color.WHITE
	mat_main.vertex_color_use_as_albedo = true
	mat_main.roughness = 0.95
	multimesh_instance_total = _main.size() + _glow.size()
	var mmi := _commit(_main, mat_main)
	mmi.name = "PropVoxels"
	add_child(mmi)

	var mat_glow := StandardMaterial3D.new()
	mat_glow.albedo_color = Color(0.12, 0.08, 0.05)
	mat_glow.emission_enabled = true
	mat_glow.emission = C_FORGE
	mat_glow.emission_energy_multiplier = 2.0
	var mmi_g := _commit(_glow, mat_glow)
	mmi_g.name = "PropGlow"
	add_child(mmi_g)


func _commit(entries: Array, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _unit_box
	mm.instance_count = entries.size()
	for i in entries.size():
		var e: Array = entries[i]
		var basis := Basis.IDENTITY.scaled(e[1])
		mm.set_instance_transform(i, Transform3D(basis, e[0]))
		mm.set_instance_color(i, e[2])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	return mmi


# ------------------------------------------------------------------- crates

func _build_crate_stacks() -> void:
	# Three stacked-crate props: 1 m base crate + smaller top crate +
	# dark edge trim for the voxel read. "Destructible-looking" = banded
	# + nailed trim, but these are static dressing (real destructibles
	# already exist in dustline_builder.gd as DestructibleCover).
	var stacks := [
		Vector3(-18, 0, 8),
		Vector3(18, 0, -2),
		Vector3(11.5, 0, -19.5),
	]
	for p in stacks:
		_v(p + Vector3(0, 0.5, 0), Vector3(1.0, 1.0, 1.0), C_WOOD)
		_v(p + Vector3(0, 0.5, 0), Vector3(1.06, 0.12, 1.06), C_WOOD_D)  # base band
		_v(p + Vector3(0, 1.06, 0), Vector3(0.7, 0.7, 0.7), C_WOOD)
		_v(p + Vector3(0, 1.06, 0), Vector3(0.76, 0.1, 0.76), C_WOOD_D)  # top band
		_v(p + Vector3(0, 1.45, 0), Vector3(0.4, 0.08, 0.4), C_TAN)  # lid slat
		_solid(p + Vector3(0, 0.7, 0), Vector3(1.0, 1.4, 1.0))


# ------------------------------------------------------------------ barrels

func _build_barrel_clusters() -> void:
	# Three 3-barrel clusters. Each barrel: body box + dark band + rusty
	# lid, arranged in a triangle so the cluster reads as one obstacle.
	var clusters := [
		Vector3(-18, 0, -16),
		Vector3(18, 0, 20),
		Vector3(-2, 0, 10),
	]
	for p in clusters:
		var offsets := [Vector3(-0.4, 0, 0), Vector3(0.4, 0, 0.1), Vector3(0, 0, 0.55)]
		var cols := [C_RUST, C_DARKMETAL, C_RUST_D]
		for i in 3:
			var bp: Vector3 = p + offsets[i]
			_v(bp + Vector3(0, 0.45, 0), Vector3(0.6, 0.9, 0.6), cols[i])
			_v(bp + Vector3(0, 0.45, 0), Vector3(0.66, 0.1, 0.66), C_DARKMETAL)
			_v(bp + Vector3(0, 0.92, 0), Vector3(0.5, 0.06, 0.5), C_CONCRETE_D)
		_solid(p + Vector3(0, 0.45, 0.15), Vector3(1.5, 0.9, 1.3))


# ----------------------------------------------------------------- sandbags

func _build_sandbag_lines() -> void:
	# Three low barrier walls: stacked sandbag rows (canvas/olive/dirt)
	# on a concrete footing. Crouch-cover height (~0.9 m).
	var lines := [
		{"p": Vector3(0, 0, -6), "w": 4.0, "rot": false},
		{"p": Vector3(-16, 0, 2), "w": 4.0, "rot": true},  # runs along z
		{"p": Vector3(20, 0, -18), "w": 4.0, "rot": false},
	]
	for line in lines:
		var p: Vector3 = line["p"]
		var w: float = line["w"]
		var along_z: bool = line["rot"]
		var dir := Vector3(0, 0, 1) if along_z else Vector3(1, 0, 0)
		var foot := Vector3(w, 0.18, 0.7) if not along_z else Vector3(0.7, 0.18, w)
		_v(p + Vector3(0, 0.09, 0), foot, C_CONCRETE_D)
		# Two sandbag rows + a staggered top row.
		for row in 2:
			for i in 4:
				var t := -w * 0.5 + 0.55 + float(i) * 1.0
				var bag_c := C_CANVAS if (i + row) % 2 == 0 else C_OLIVE
				var bp: Vector3 = p + dir * t + Vector3(0, 0.32 + float(row) * 0.28, 0)
				var bs := Vector3(0.95, 0.28, 0.6) if not along_z else Vector3(0.6, 0.28, 0.95)
				_v(bp, bs, bag_c)
		for i in 3:
			var t := -w * 0.5 + 1.0 + float(i) * 1.1
			var bp: Vector3 = p + dir * t + Vector3(0, 0.85, 0)
			var bs := Vector3(0.9, 0.22, 0.55) if not along_z else Vector3(0.55, 0.22, 0.9)
			_v(bp, bs, C_DIRT_D)
		var cs := Vector3(w, 0.95, 0.7) if not along_z else Vector3(0.7, 0.95, w)
		_solid(p + Vector3(0, 0.48, 0), cs)


# -------------------------------------------------------------------- signs

func _build_signs() -> void:
	# Three voxel sign boards on poles: board + frame + emissive strip.
	# Boards sit above head height (bottom edge ~2.1 m); only the pole
	# gets collision.
	var signs := [
		{"p": Vector3(-4, 0, -18), "txt": C_FORGE},
		{"p": Vector3(16, 0, 0), "txt": C_TAN},
		{"p": Vector3(-20, 0, -2), "txt": C_FORGE},
	]
	for s in signs:
		var p: Vector3 = s["p"]
		_v(p + Vector3(0, 1.3, 0), Vector3(0.14, 2.6, 0.14), C_DARKMETAL)
		_v(p + Vector3(0, 2.55, 0), Vector3(1.7, 1.0, 0.1), C_WOOD_D)  # frame
		_v(p + Vector3(0, 2.55, 0.06), Vector3(1.5, 0.8, 0.04), C_GUNMETAL)  # board
		_g(p + Vector3(0, 2.22, 0.09), Vector3(1.5, 0.08, 0.03), s["txt"])  # strip
		_v(p + Vector3(-0.5, 2.62, 0.09), Vector3(0.25, 0.25, 0.03), C_FORGE)  # glyph block
		_v(p + Vector3(0.2, 2.62, 0.09), Vector3(0.25, 0.25, 0.03), C_TAN)
		_solid(p + Vector3(0, 1.3, 0), Vector3(0.2, 2.6, 0.2))


# --------------------------------------------------------- ground variation

func _build_ground_variation() -> void:
	# Flat ground patches (thin decals, NO collision — walkable).
	var patches := [
		{"p": Vector3(6, 0, 8), "c": C_DIRT_D, "s": 3.0},
		{"p": Vector3(-14, 0, -18), "c": C_CONCRETE_D, "s": 3.0},
		{"p": Vector3(24, 0, 16), "c": C_DIRT_D, "s": 3.0},
		{"p": Vector3(-23, 0, 1), "c": C_TAN, "s": 3.0},
		{"p": Vector3(-8, 0, 26.5), "c": C_CONCRETE_D, "s": 3.0},
	]
	for patch in patches:
		var p: Vector3 = patch["p"]
		var s: float = patch["s"]
		_v(p + Vector3(0, 0.02, 0), Vector3(s, 0.03, s), patch["c"])
		# A few scattered rubble cubes on each patch (still flat, no collision).
		_v(p + Vector3(-0.8, 0.07, 0.5), Vector3(0.25, 0.1, 0.25), C_RUST_D)
		_v(p + Vector3(0.7, 0.06, -0.6), Vector3(0.2, 0.08, 0.2), C_CONCRETE)
		_v(p + Vector3(0.2, 0.06, 0.9), Vector3(0.18, 0.08, 0.18), C_WOOD_D)
	# Debris piles: low mounds (<= 0.45 m) with one simple box each.
	var piles := [
		Vector3(-4, 0, -14),
		Vector3(14, 0, 4),
		Vector3(26, 0, -12),
	]
	for p in piles:
		_v(p + Vector3(0, 0.12, 0), Vector3(1.6, 0.24, 1.4), C_DIRT_D)
		_v(p + Vector3(0.3, 0.3, 0.2), Vector3(0.9, 0.3, 0.8), C_CONCRETE_D)
		_v(p + Vector3(-0.3, 0.28, -0.3), Vector3(0.7, 0.26, 0.7), C_RUST)
		_v(p + Vector3(0.1, 0.42, -0.1), Vector3(0.3, 0.12, 0.3), C_WOOD_D)
		_solid(p + Vector3(0, 0.22, 0), Vector3(1.6, 0.45, 1.4))


# ------------------------------------------------------------- laundry line

func _build_laundry_line() -> void:
	# One free-standing laundry line (south street, clear of the shack at
	# (4,22) and the (0,29) spawn). Cloth hangs above head height.
	var a := Vector3(10, 0, 24)
	var b := Vector3(22, 0, 24)
	for p in [a, b]:
		_v(p + Vector3(0, 1.9, 0), Vector3(0.16, 3.8, 0.16), C_WOOD_D)
		_solid(p + Vector3(0, 1.9, 0), Vector3(0.22, 3.8, 0.22))
	var mid := (a + b) * 0.5
	_v(mid + Vector3(0, 3.7, 0), Vector3(12.0, 0.05, 0.05), C_DARKMETAL)
	for t in [0.25, 0.6]:
		var cp: Vector3 = a.lerp(b, t)
		var cloth_c := C_CLOTH_BLUE if t < 0.5 else C_CLOTH_RED
		_v(cp + Vector3(0, 3.3, 0), Vector3(0.9, 0.8, 0.06), cloth_c)


# ------------------------------------------------------------------- canopy

func _build_canopy() -> void:
	# Freestanding market canopy: 2 posts + corrugated top. 2.6 m
	# clearance so the player walks under it; posts get collision.
	var p := Vector3(16, 0, -12)
	_v(p + Vector3(0, 2.6, 0), Vector3(2.6, 0.12, 2.2), C_RUST)
	_v(p + Vector3(0, 2.72, 0), Vector3(2.6, 0.06, 0.25), C_DARKMETAL)  # ridge
	_v(p + Vector3(0, 2.45, 1.0), Vector3(2.6, 0.1, 0.15), C_CANVAS)  # front valance
	_g(p + Vector3(0, 2.4, 0.95), Vector3(1.8, 0.05, 0.03), C_FORGE)  # light strip
	for sx in [-1.1, 1.1]:
		_v(p + Vector3(sx, 1.3, 0.9), Vector3(0.16, 2.6, 0.16), C_WOOD_D)
		_solid(p + Vector3(sx, 1.3, 0.9), Vector3(0.22, 2.6, 0.22))
