# scripts/maps/dustline_builder.gd
# FORGEFALL — "Dustline" map builder (Worker 5: Map).
#
# Builds the entire Favela-inspired voxel shantytown arena procedurally in
# _ready(). Design goals:
#   - MW2 Favela grit, "directed by Minecraft": chunky voxel massing.
#   - DESTRUCTIBLE COVER headline: crates / barrel clusters / barrier walls
#     are DestructibleCover nodes (group "cover") that fracture into pooled
#     physics cubes via DebrisPool.
#   - Performance: ALL static opaque voxels live in ONE MultiMeshInstance3D
#     (one draw call); emissive bits in a second; the distant city in a third
#     unshaded one. Collision is simplified invisible StaticBody3D boxes —
#     never per-voxel. Target < 60 draw calls for the whole map.
#   - DESIGNED FOR THE MOVEMENT KIT: 4 accessible rooftops (1 m stair steps),
#     long wall-run-friendly walls, a 10 m water tower + tall shacks as
#     grapple targets, laundry lines / overhangs to swing under.
#
# Scene tree produced under root Node3D "Dustline":
#   WorldEnvironment (warm dusk sky), Sun (DirectionalLight3D, shadows),
#   StaticVoxels / GlowVoxels / DistantCity (MultiMeshInstance3D),
#   StaticCollision (invisible boxes), Covers (DestructibleCover x N),
#   DustMotes (GPUParticles3D, group "fx_motes" — perf scaler kills on low),
#   NavRegion (NavigationRegion3D, navmesh baked synchronously at load),
#   Marker3D groups: "player_spawn" x5, "spawn_door" x7, "forge_pad" x4.
#
# Navigation: baked once at load from the static collision boxes via
# NavigationServer3D.bake_from_source_geometry_data(). Destructible cover is
# deliberately EXCLUDED so destroying cover never invalidates the mesh —
# enemies use local steering around cover (their worker owns the fallback).
extends Node3D

#region TUNABLES
const ARENA_HALF := 35.0        # arena is 70 x 70 m, perimeter walls at +-34
const WALL_H_MIN := 3.0
const WALL_H_MAX := 4.2
const MOTE_COUNT := 200
const ROOF_STEP := 1.0         # stair step height for rooftop access
const NAV_AGENT_HEIGHT := 1.7
const NAV_AGENT_RADIUS := 0.35
const COVER_BARRIER_HP := 70.0
const COVER_CRATE_HP := 45.0
const COVER_BARREL_HP := 30.0
const MAP_SEED := 20261005
#endregion

# Local palette (mirrors the frozen VoxelBuilder.PALETTE hex values so this
# file has zero load-order dependency on worker 1's script).
const C_CONCRETE := Color("9a958c")
const C_CONCRETE_D := Color("7d786f")
const C_RUST := Color("8a4b2a")
const C_RUST_D := Color("653620")
const C_WOOD := Color("7a5c38")
const C_WOOD_D := Color("57412a")
const C_CANVAS := Color("b8a888")
const C_OLIVE := Color("5a6b3c")
const C_DARKMETAL := Color("23262a")
const C_TAN := Color("c2a878")
const C_TAN_D := Color("9d8459")
const C_FORGE := Color("ff7b1c")
const C_DIRT := Color("8a7358")
const C_DIRT_D := Color("6b5844")
const C_WINDOW_LIT := Color("ffb35c")

const PAL_BARREL := [Color("8a4b2a"), Color("653620"), Color("23262a")]
const PAL_CRATE := [Color("7a5c38"), Color("57412a"), Color("8a6c42")]
const PAL_BARRIER := [Color("9a958c"), Color("7d786f"), Color("6b665e")]

# [pos, w, d, h, scheme] — scheme picks a wall color pair. "roof" marks the
# four grapple/stair-accessible rooftops (h = 3.0 exactly, reached by 1 m steps).
const SHACKS := [
	{"p": Vector3(-20, 0, -22), "w": 6.0, "d": 5.0, "h": 5.4, "c": 0},
	{"p": Vector3(-11, 0, -22), "w": 5.0, "d": 5.0, "h": 3.0, "c": 1, "roof": true},
	{"p": Vector3(-2, 0, -22), "w": 6.0, "d": 5.0, "h": 7.9, "c": 2},
	{"p": Vector3(7, 0, -22), "w": 5.0, "d": 4.0, "h": 5.4, "c": 3},
	{"p": Vector3(16, 0, -22), "w": 6.0, "d": 5.0, "h": 5.4, "c": 0},
	{"p": Vector3(-15, 0, 22), "w": 6.0, "d": 5.0, "h": 5.4, "c": 1},
	{"p": Vector3(-6, 0, 22), "w": 5.0, "d": 5.0, "h": 3.0, "c": 2, "roof": true},
	{"p": Vector3(4, 0, 22), "w": 6.0, "d": 5.0, "h": 7.9, "c": 0},
	{"p": Vector3(-26, 0, -6), "w": 5.0, "d": 6.0, "h": 3.0, "c": 3, "roof": true},
	{"p": Vector3(-26, 0, 8), "w": 5.0, "d": 5.0, "h": 5.4, "c": 2},
	{"p": Vector3(26, 0, 4), "w": 6.0, "d": 5.0, "h": 3.0, "c": 1, "roof": true},
]

const STALLS := [
	Vector3(-4.5, 0, -3), Vector3(0, 0, -3), Vector3(4.5, 0, -3),
	Vector3(-4.5, 0, 2.5), Vector3(0, 0, 2.5), Vector3(4.5, 0, 2.5),
]

const PLAYER_SPAWNS := [
	Vector3(-30, 0.3, -30), Vector3(30, 0.3, -30), Vector3(-30, 0.3, 30),
	Vector3(30, 0.3, 30), Vector3(0, 0.3, 29),
]

# Door visuals sit on the inner face of the perimeter walls.
const SPAWN_DOORS := [
	Vector3(-24, 0, -33.6), Vector3(-8, 0, -33.6), Vector3(8, 0, -33.6),
	Vector3(24, 0, -33.6), Vector3(-16, 0, 33.6), Vector3(16, 0, 33.6),
	Vector3(33.6, 0, 0),
]

const FORGE_PADS := [
	Vector3(10, 0, 10), Vector3(-10, 0, -10), Vector3(22, 0, -14), Vector3(-22, 0, 16),
]

var _rng := RandomNumberGenerator.new()
var _main: Array = []   # [pos, size, color, rot_y] static shaded voxels
var _glow: Array = []   # emissive voxels (forge pads, door strips, lit windows)
var _city: Array = []   # distant skyline (unshaded)
var _nav_boxes: Array = []  # [center, size] walkable surfaces for nav bake
var _unit_box: BoxMesh
var _collision_root: StaticBody3D
var _nav_region: NavigationRegion3D


func _ready() -> void:
	_rng.seed = MAP_SEED
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_build_environment()
	_build_ground()
	_build_perimeter()
	for s in SHACKS:
		_build_shack(s)
	for p in STALLS:
		_build_stall(p)
	_build_water_tower(Vector3(-14, 0, 14))
	_build_car(Vector3(14, 0, -8), 0.35, C_RUST)
	_build_car(Vector3(-6, 0, 16), -0.5, C_OLIVE)
	_build_car(Vector3(20, 0, 10), 1.2, C_DARKMETAL)
	_build_covers()
	_build_laundry()
	_build_props()
	_build_spawn_markers()
	_commit_multimeshes()
	_build_motes()
	_bake_nav()


# ------------------------------------------------------------------ helpers

func _v(pos: Vector3, size: Vector3, color: Color, rot_y: float = 0.0) -> void:
	_main.append([pos, size, color, rot_y])


func _g(pos: Vector3, size: Vector3, color: Color, rot_y: float = 0.0) -> void:
	_glow.append([pos, size, color, rot_y])


func _c(pos: Vector3, size: Vector3, color: Color) -> void:
	_city.append([pos, size, color, 0.0])


func _pick(arr: Array):
	return arr[_rng.randi_range(0, arr.size() - 1)]


func _solid(center: Vector3, size: Vector3, nav := false, rot_y := 0.0) -> void:
	if rot_y == 0.0:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		cs.position = center
		_collision_root.add_child(cs)
	else:
		var body := StaticBody3D.new()
		body.position = center
		body.rotation.y = rot_y
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		body.add_child(cs)
		add_child(body)
	if nav:
		_nav_boxes.append([center, size])


func _cover(vox: Vector3i, palette: Array, hp: float, pos: Vector3, rot_y := 0.0) -> void:
	var c := DestructibleCover.new()
	c.vox_size = vox
	c.palette.assign(palette)  # typed Array[Color]: assign() converts, direct = would fail
	c.hp = hp
	c.position = pos
	c.rotation.y = rot_y
	add_child(c)  # _ready() builds its mesh + collision immediately


func _scheme_colors(scheme: int) -> Array:
	match scheme:
		0:
			return [C_TAN, C_CONCRETE]
		1:
			return [C_CONCRETE, C_WOOD]
		2:
			return [C_RUST, C_WOOD_D]
		_:
			return [C_CANVAS, C_OLIVE]


# ------------------------------------------------------------- environment

func _build_environment() -> void:
	# A1 (v0.5) — "Modern Voxfare 2" dusk. Cheap gradient sky: a 16x256
	# vertical gradient texture in a PanoramaSkyMaterial (one texture lookup,
	# no procedural-sky shader math). GradientTexture2D fill runs top->bottom,
	# so offset 0 = zenith, ~0.5 = horizon, 1 = below-horizon ground haze.
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.42, 0.50, 0.56, 1.0])
	grad.colors = PackedColorArray([
		Color(0.13, 0.08, 0.24),   # zenith: dusk purple
		Color(0.45, 0.20, 0.42),   # upper sky: purple -> orange
		Color(1.0, 0.52, 0.22),    # horizon: burnt orange
		Color(0.55, 0.32, 0.20),   # just below horizon
		Color(0.10, 0.07, 0.07),   # ground haze: dark warm brown
	])
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.width = 16
	gtex.height = 256
	gtex.fill = GradientTexture2D.FILL_LINEAR
	gtex.fill_from = Vector2(0, 0)
	gtex.fill_to = Vector2(0, 1)
	var smat := PanoramaSkyMaterial.new()
	smat.panorama = gtex
	var sky := Sky.new()
	sky.sky_material = smat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# Hemisphere-ish fill from the sky itself: shadowed sides stay readable,
	# never pitch black. No extra fill light (zero extra draw cost).
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.1
	env.glow_enabled = false  # NO bloom: too expensive on a Galaxy S23.
	# Fog: density tuned so the far wall (~70 m) is lightly hazed and the
	# distant city ring (130-190 m) is ~60-75% hazed, while gameplay ranges
	# (<35 m) stay clear. Warm fog color keeps the dusk palette.
	env.fog_enabled = true
	env.fog_light_color = Color(0.95, 0.62, 0.38)
	env.fog_density = 0.0075
	env.fog_sun_scatter = 0.15
	env.fog_sky_affect = 0.5
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.position = Vector3(0, 40, 0)  # centers the tight ortho shadow box
	sun.rotation_degrees = Vector3(-48, -32, 0)  # late-afternoon angle
	sun.light_color = Color(1.0, 0.72, 0.50)
	sun.light_energy = 1.35
	# Shadows: single ortho cascade, tight 90 m box around the 70 m arena
	# (no 4-split). Per-light shadow map size does NOT exist in Godot 4.7 —
	# the size is the project setting
	# rendering/lights_and_shadows/directional_shadow/size (lives in
	# project.godot, outside this file; coordinator: 2048).
	# FIX 3 (v0.5.1): v0.5 ran bias 0.02 / normal_bias 0.3 / blur 0 on a
	# 1024 map — far below engine defaults — and flat voxel walls showed
	# diagonal moire/acne banding, worst at this low sun angle (grazing
	# incidence). New values sit AT OR BELOW Godot 4.7 defaults
	# (bias 0.1 / normal_bias 2.0 / blur 1.0): normal_bias is the main
	# acne lever at grazing angles (official docs: prefer raising normal
	# bias over bias — less peter-panning), bias lifts the depth test out
	# of texel quantization, and blur 1.0 softens residual texel moire.
	# Offsets stay ~1 shadow texel (90 m / 2048), so thin voxel geometry
	# (0.25 m cover, 0.1 m slats) keeps attached shadows.
	# No per-light shadow_filter in Godot 4.7.2 (verified: not a property
	# of DirectionalLight3D) — filter quality lives in ProjectSettings,
	# which this file must not touch. shadow_blur is the per-light
	# softening control.
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_fade_start = 0.9
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 1.0  # was 0.3: primary acne fix
	sun.shadow_blur = 1.0  # was 0.0: Godot default, softens texel moire
	add_child(sun)

	_collision_root = StaticBody3D.new()
	_collision_root.name = "StaticCollision"
	add_child(_collision_root)

	_nav_region = NavigationRegion3D.new()
	_nav_region.name = "NavRegion"
	add_child(_nav_region)


# ------------------------------------------------------------------ ground

func _build_ground() -> void:
	_v(Vector3(0, -0.25, 0), Vector3(70, 0.5, 70), C_DIRT)
	_solid(Vector3(0, -0.25, 0), Vector3(70, 0.5, 70))
	_nav_boxes.append([Vector3(0, 0, 0), Vector3(70, 0.5, 70)])
	# Dust patches: thin darker/lighter slabs for ground variation.
	for i in 14:
		var px := _rng.randf_range(-30, 30)
		var pz := _rng.randf_range(-30, 30)
		var s := _rng.randf_range(2.5, 6.0)
		_v(Vector3(px, 0.015, pz), Vector3(s, 0.03, s * _rng.randf_range(0.6, 1.0)),
			_pick([C_DIRT_D, C_TAN_D, C_CONCRETE_D]), _rng.randf_range(0, TAU))
	# Scattered rubble voxels.
	for i in 160:
		var px := _rng.randf_range(-33, 33)
		var pz := _rng.randf_range(-33, 33)
		var s := _rng.randf_range(0.125, 0.3)
		_v(Vector3(px, s * 0.5, pz), Vector3(s, s, s),
			_pick([C_CONCRETE, C_RUST, C_TAN, C_DIRT_D]), _rng.randf_range(0, TAU))


# --------------------------------------------------------------- perimeter

func _build_perimeter() -> void:
	# Four walls of jittered-height shanty segments + crenellation cubes.
	for side in 4:
		for i in 8:
			var t := -34.0 + 4.375 + float(i) * 8.75
			var h := _rng.randf_range(WALL_H_MIN, WALL_H_MAX)
			var col: Color = _pick([C_CONCRETE, C_TAN, C_RUST, C_WOOD])
			var center := Vector3.ZERO
			match side:
				0:
					center = Vector3(t, h * 0.5, -34)
				1:
					center = Vector3(t, h * 0.5, 34)
				2:
					center = Vector3(-34, h * 0.5, t)
				_:
					center = Vector3(34, h * 0.5, t)
			var size := Vector3(8.75, h, 0.6) if side < 2 else Vector3(0.6, h, 8.75)
			_v(center, size, col)
			_solid(center, size)
			# Voxel crenellation along the top (wall-run readable edge).
			var n := int(8.75 / 2.2)
			for k in n:
				var off := -8.75 * 0.5 + 1.1 + float(k) * 2.2
				var cp := center + Vector3(off, h * 0.5 + 0.25, 0) if side < 2 else center + Vector3(0, h * 0.5 + 0.25, off)
				_v(cp, Vector3(0.5, 0.5, 0.5), col.darkened(0.15))
	# Spawn doors: dark inset + orange glow strip on the inner wall faces.
	for dp in SPAWN_DOORS:
		var inward := Vector3.ZERO
		if absf(dp.z) > 33.0:
			inward = Vector3(0, 0, -signf(dp.z))
		else:
			inward = Vector3(-signf(dp.x), 0, 0)
		var face: Vector3 = dp + inward * 0.05
		var rot := 0.0 if absf(dp.z) > 33.0 else PI * 0.5
		_v(face + Vector3(0, 1.25, 0), Vector3(1.5, 2.5, 0.14), C_DARKMETAL, rot)
		_g(face + Vector3(0, 2.65, 0), Vector3(1.5, 0.14, 0.2), C_FORGE, rot)


# ------------------------------------------------------------------- shacks

func _build_shack(s: Dictionary) -> void:
	var p: Vector3 = s["p"]
	var w: float = s["w"]
	var d: float = s["d"]
	var h: float = s["h"]
	var cols := _scheme_colors(int(s["c"]))
	var t := 0.25
	# Walls.
	_v(p + Vector3(0, h * 0.5, d * 0.5 - t * 0.5), Vector3(w, h, t), cols[0])
	_v(p + Vector3(0, h * 0.5, -d * 0.5 + t * 0.5), Vector3(w, h, t), cols[1])
	_v(p + Vector3(w * 0.5 - t * 0.5, h * 0.5, 0), Vector3(t, h, d - 2.0 * t), cols[0])
	_v(p + Vector3(-w * 0.5 + t * 0.5, h * 0.5, 0), Vector3(t, h, d - 2.0 * t), cols[1])
	# Dark base skirt.
	_v(p + Vector3(0, 0.2, 0), Vector3(w + 0.15, 0.4, d + 0.15), C_DARKMETAL.lightened(0.08))
	# Door (fake, +z face) + frame.
	_v(p + Vector3(0, 1.05, d * 0.5 + 0.02), Vector3(1.1, 2.1, 0.1), C_DARKMETAL)
	_v(p + Vector3(0, 2.18, d * 0.5 + 0.02), Vector3(1.3, 0.12, 0.12), C_WOOD_D)
	# Windows: dark insets, one lit (emissive) per shack for dusk life.
	_v(p + Vector3(-w * 0.22, h * 0.68, d * 0.5 + 0.02), Vector3(0.9, 0.9, 0.1), C_DARKMETAL)
	_v(p + Vector3(w * 0.24, h * 0.68, -d * 0.5 - 0.02), Vector3(0.9, 0.9, 0.1), C_DARKMETAL)
	_g(p + Vector3(w * 0.5 + 0.02, h * 0.62, 0), Vector3(0.1, 0.8, 1.1), C_WINDOW_LIT)
	# Corner posts (voxel read).
	for cx in [-1.0, 1.0]:
		for cz in [-1.0, 1.0]:
			_v(p + Vector3(cx * (w * 0.5 - 0.1), h * 0.5, cz * (d * 0.5 - 0.1)),
				Vector3(0.3, h, 0.3), C_WOOD_D)
	# Corrugated-look roof: alternating rust slats + dark ridge.
	var n := maxi(2, int(w / 0.55))
	var slat_w := w / float(n)
	for i in n:
		var sx := -w * 0.5 + (float(i) + 0.5) * slat_w
		_v(p + Vector3(sx, h + 0.05, 0), Vector3(slat_w - 0.06, 0.1, d + 0.7),
			C_RUST if i % 2 == 0 else C_RUST_D)
	_v(p + Vector3(0, h + 0.14, 0), Vector3(w + 0.7, 0.14, 0.35), C_DARKMETAL)
	_solid(p + Vector3(0, h * 0.5, 0), Vector3(w, h, d))
	_nav_boxes.append([p + Vector3(0, h, 0), Vector3(w, 0.2, d)])  # roof walkable
	if s.get("roof", false):
		# Parapet rim (low cover + grapple-readable silhouette). The +x side is
		# left OPEN — the stair steps arrive there.
		_v(p + Vector3(0, h + 0.25, d * 0.5 + 0.05), Vector3(w + 0.3, 0.5, 0.2), cols[0].darkened(0.1))
		_v(p + Vector3(0, h + 0.25, -d * 0.5 - 0.05), Vector3(w + 0.3, 0.5, 0.2), cols[0].darkened(0.1))
		_v(p + Vector3(-w * 0.5 - 0.05, h + 0.25, 0), Vector3(0.2, 0.5, d + 0.3), cols[1].darkened(0.1))
		# Stair steps up the +x side: 1 m rises, then the 3 m roof.
		var bx := p.x + w * 0.5
		_v(Vector3(bx + 2.1, 0.5, p.z), Vector3(1.4, 1.0, 1.8), C_CONCRETE_D)
		_solid(Vector3(bx + 2.1, 0.5, p.z), Vector3(1.4, 1.0, 1.8))
		_nav_boxes.append([Vector3(bx + 2.1, 1.0, p.z), Vector3(1.4, 0.2, 1.8)])
		_v(Vector3(bx + 0.7, 1.0, p.z), Vector3(1.4, 2.0, 1.8), C_CONCRETE)
		_solid(Vector3(bx + 0.7, 1.0, p.z), Vector3(1.4, 2.0, 1.8))
		_nav_boxes.append([Vector3(bx + 0.7, 2.0, p.z), Vector3(1.4, 0.2, 1.8)])


# ------------------------------------------------------------------- stalls

func _build_stall(p: Vector3) -> void:
	# Four posts.
	for ox in [-1.1, 1.1]:
		for oz in [-0.8, 0.8]:
			_v(p + Vector3(ox, 1.1, oz), Vector3(0.15, 2.2, 0.15), C_WOOD_D)
	# Striped canvas awning: 3x2 grid of cubes.
	for ix in 3:
		for iz in 2:
			var ax := -0.85 + float(ix) * 0.85
			var az := -0.45 + float(iz) * 0.9
			_v(p + Vector3(ax, 2.32, az), Vector3(0.8, 0.1, 0.85),
				C_CANVAS if (ix + iz) % 2 == 0 else C_OLIVE)
	# Counter + goods.
	_v(p + Vector3(0, 0.45, 0), Vector3(2.0, 0.9, 1.2), C_WOOD)
	for i in 5:
		var gx := _rng.randf_range(-0.8, 0.8)
		var gz := _rng.randf_range(-0.4, 0.4)
		var gs := _rng.randf_range(0.18, 0.3)
		_v(p + Vector3(gx, 0.9 + gs * 0.5, gz), Vector3(gs, gs, gs),
			_pick([C_RUST, C_OLIVE, C_TAN, C_FORGE]), _rng.randf_range(0, TAU))
	_solid(p + Vector3(0, 1.15, 0), Vector3(2.4, 2.3, 2.0))


# -------------------------------------------------------------- water tower

func _build_water_tower(p: Vector3) -> void:
	# Four legs + cross braces, rust tank, ladder. ~10.8 m tall: grapple bait.
	for ox in [-1.4, 1.4]:
		for oz in [-1.4, 1.4]:
			_v(p + Vector3(ox, 4.0, oz), Vector3(0.35, 8.0, 0.35), C_DARKMETAL)
	_v(p + Vector3(0, 2.0, 1.4), Vector3(3.1, 0.18, 0.18), C_DARKMETAL)
	_v(p + Vector3(0, 2.0, -1.4), Vector3(3.1, 0.18, 0.18), C_DARKMETAL)
	_v(p + Vector3(1.4, 2.0, 0), Vector3(0.18, 0.18, 3.1), C_DARKMETAL)
	_v(p + Vector3(-1.4, 2.0, 0), Vector3(0.18, 0.18, 3.1), C_DARKMETAL)
	_v(p + Vector3(0, 5.5, 1.4), Vector3(3.1, 0.18, 0.18), C_DARKMETAL)
	_v(p + Vector3(0, 5.5, -1.4), Vector3(3.1, 0.18, 0.18), C_DARKMETAL)
	# Tank: voxel-blocky cylinder impression (stacked boxes).
	_v(p + Vector3(0, 9.0, 0), Vector3(3.6, 2.4, 3.6), C_RUST)
	_v(p + Vector3(0, 10.35, 0), Vector3(3.0, 0.5, 3.0), C_RUST_D)
	_v(p + Vector3(0, 9.0, 0), Vector3(3.75, 0.25, 3.75), C_DARKMETAL)  # band
	# Lid slats.
	for i in 6:
		var sx := -1.25 + float(i) * 0.5
		_v(p + Vector3(sx, 10.68, 0), Vector3(0.44, 0.08, 3.0),
			C_RUST if i % 2 == 0 else C_RUST_D)
	# Ladder up the +x leg.
	for i in 16:
		_v(p + Vector3(1.62, 0.6 + float(i) * 0.5, 0.9), Vector3(0.08, 0.08, 0.5), C_DARKMETAL)
	_v(p + Vector3(1.62, 4.4, 0.68), Vector3(0.08, 8.2, 0.08), C_DARKMETAL)
	_v(p + Vector3(1.62, 4.4, 1.12), Vector3(0.08, 8.2, 0.08), C_DARKMETAL)
	_solid(p + Vector3(0, 4.0, 0), Vector3(3.4, 8.0, 3.4))
	_solid(p + Vector3(0, 9.4, 0), Vector3(3.8, 3.0, 3.8))


# --------------------------------------------------------------------- cars

func _build_car(p: Vector3, rot_y: float, body_c: Color) -> void:
	# Wrecked cube car: body, cabin, wheels, bumpers. Rotated for street chaos.
	var fwd := Vector3(0, 0, 1).rotated(Vector3.UP, rot_y)
	var rgt := Vector3(1, 0, 0).rotated(Vector3.UP, rot_y)
	_v(p + Vector3(0, 0.62, 0), Vector3(2.0, 0.65, 4.3), body_c, rot_y)
	_v(p + Vector3(0, 1.2, 0) - fwd * 0.2, Vector3(1.7, 0.55, 2.1), C_DARKMETAL.lightened(0.05), rot_y)
	_v(p + Vector3(0, 0.35, 0) + fwd * 2.2, Vector3(2.05, 0.25, 0.3), C_DARKMETAL, rot_y)
	_v(p + Vector3(0, 0.35, 0) - fwd * 2.2, Vector3(2.05, 0.25, 0.3), C_DARKMETAL, rot_y)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var wp: Vector3 = p + rgt * (sx * 0.95) + fwd * (sz * 1.35) + Vector3(0, 0.36, 0)
			_v(wp, Vector3(0.32, 0.72, 0.72), C_DARKMETAL.darkened(0.25), rot_y)
	# Rust patches on the body.
	for i in 4:
		var rp: Vector3 = p + rgt * _rng.randf_range(-0.9, 0.9) + Vector3(0, _rng.randf_range(0.5, 0.9), 0) + fwd * _rng.randf_range(-1.8, 1.8)
		_v(rp, Vector3(0.4, 0.25, 0.1), C_RUST_D, rot_y)
	_solid(p + Vector3(0, 0.8, 0), Vector3(2.1, 1.6, 4.4), false, rot_y)


# ------------------------------------------------------------------- covers

func _build_covers() -> void:
	# Barrel clusters (3x4x3 voxels @ 0.25 m).
	for bp in [Vector3(7, 0, 0), Vector3(-7, 0, 6), Vector3(12, 0, -14),
			Vector3(-16, 0, -12), Vector3(2, 0, 14)]:
		_cover(Vector3i(3, 4, 3), PAL_BARREL, COVER_BARREL_HP, bp, _rng.randf_range(0, TAU))
	# Supply crates (4x4x4 @ 0.25 m = 1 m cubes) mid-map.
	for cp in [Vector3(-2, 0, -10), Vector3(9, 0, 5), Vector3(-12, 0, -2),
			Vector3(16, 0, 18), Vector3(-20, 0, 12), Vector3(5, 0, -16)]:
		_cover(Vector3i(4, 4, 4), PAL_CRATE, COVER_CRATE_HP, cp, _rng.randf_range(0, TAU))
	# Concrete barriers (8x5x2 @ 0.25 m = 2 x 1.25 x 0.5 m) across lanes.
	for bp in [[Vector3(0, 0, -12), 0.0], [Vector3(-14, 0, 4), PI * 0.5],
			[Vector3(12, 0, 14), 0.2], [Vector3(-4, 0, 20), PI * 0.5],
			[Vector3(24, 0, -6), PI * 0.5]]:
		_cover(Vector3i(8, 5, 2), PAL_BARRIER, COVER_BARRIER_HP, bp[0], bp[1])


# ------------------------------------------------------------------ laundry

func _build_laundry() -> void:
	var lines := [
		[Vector3(-17, 5.8, -22), Vector3(-13.5, 4.8, -22)],
		[Vector3(1, 7.0, -22), Vector3(4.5, 5.6, -22)],
		[Vector3(-26, 5.6, -3), Vector3(-26, 4.8, 5.5)],
		[Vector3(-12, 5.6, 22), Vector3(-8.5, 4.8, 22)],
	]
	# One free-standing line on poles across the north street.
	var pole_a := Vector3(-8, 0, -14)
	var pole_b := Vector3(8, 0, -14)
	_v(pole_a + Vector3(0, 2.3, 0), Vector3(0.15, 4.6, 0.15), C_WOOD_D)
	_v(pole_b + Vector3(0, 2.3, 0), Vector3(0.15, 4.6, 0.15), C_WOOD_D)
	_solid(pole_a + Vector3(0, 2.3, 0), Vector3(0.2, 4.6, 0.2))
	_solid(pole_b + Vector3(0, 2.3, 0), Vector3(0.2, 4.6, 0.2))
	lines.append([pole_a + Vector3(0, 4.5, 0), pole_b + Vector3(0, 4.5, 0)])
	for line in lines:
		var a: Vector3 = line[0]
		var b: Vector3 = line[1]
		var mid := (a + b) * 0.5
		var length := a.distance_to(b)
		# Box length runs along local z; rotate +z onto the (b - a) direction.
		var rot := atan2(b.x - a.x, b.z - a.z)
		_v(mid, Vector3(0.06, 0.06, length), C_DARKMETAL, rot)
		for i in 4:
			var t := 0.2 + float(i) * 0.2
			var cp: Vector3 = a.lerp(b, t)
			_v(cp + Vector3(0, -0.35, 0), Vector3(0.45, 0.6, 0.06),
				_pick([C_CANVAS, C_OLIVE, C_TAN, C_RUST]), rot)


# -------------------------------------------------------------------- props

func _build_props() -> void:
	# AC units + drain pipes on shack walls.
	var ac_spots := [
		[0, 1], [2, -1], [4, 1], [5, -1], [7, 1], [9, -1],
	]
	for spot in ac_spots:
		var s: Dictionary = SHACKS[spot[0]]
		var p: Vector3 = s["p"]
		var w: float = s["w"]
		var d: float = s["d"]
		var face := float(spot[1])
		var ax := p.x + _rng.randf_range(-w * 0.3, w * 0.3)
		var ay := _rng.randf_range(2.5, 3.5)
		_v(Vector3(ax, ay, p.z + face * (d * 0.5 + 0.25)), Vector3(0.7, 0.5, 0.45), C_DARKMETAL)
		_v(Vector3(ax + 0.2, ay * 0.5, p.z + face * (d * 0.5 + 0.22)), Vector3(0.12, ay, 0.12), C_RUST_D)
	# Static pallet stacks (non-destructible set dressing near stalls).
	for pp in [Vector3(-9, 0, -6), Vector3(11, 0, -1)]:
		for i in 3:
			_v(pp + Vector3(0, 0.09 + float(i) * 0.18, 0), Vector3(1.2, 0.14, 1.0), C_WOOD_D,
				_rng.randf_range(-0.1, 0.1))
		_solid(pp + Vector3(0, 0.3, 0), Vector3(1.2, 0.6, 1.0))
	# Distant city silhouette ring (unshaded dark boxes, separate MultiMesh).
	for i in 44:
		var ang := float(i) / 44.0 * TAU + _rng.randf_range(-0.05, 0.05)
		var r := _rng.randf_range(130, 190)
		var bw := _rng.randf_range(8, 20)
		var bh := _rng.randf_range(10, 45)
		var bd := _rng.randf_range(8, 20)
		var shade := _rng.randf_range(0.8, 1.3)
		_c(Vector3(cos(ang) * r, bh * 0.5 - 2.0, sin(ang) * r), Vector3(bw, bh, bd),
			Color(0.17 * shade, 0.15 * shade, 0.25 * shade))


# ------------------------------------------------------------ spawn markers

func _build_spawn_markers() -> void:
	for sp in PLAYER_SPAWNS:
		var m := Marker3D.new()
		m.name = "PlayerSpawn"
		m.position = sp
		m.add_to_group("player_spawn")
		add_child(m)
	for dp in SPAWN_DOORS:
		var m := Marker3D.new()
		m.name = "SpawnDoor"
		m.position = dp + Vector3(0, 0.1, 0)
		m.add_to_group("spawn_door")
		add_child(m)
	for fp in FORGE_PADS:
		# Concrete base + emissive orange ring + center disc.
		_v(fp + Vector3(0, 0.04, 0), Vector3(3.2, 0.08, 3.2), C_CONCRETE_D)
		for i in 10:
			var ang := float(i) / 10.0 * TAU
			_g(fp + Vector3(cos(ang) * 1.3, 0.12, sin(ang) * 1.3), Vector3(0.32, 0.1, 0.32), C_FORGE)
		_g(fp + Vector3(0, 0.1, 0), Vector3(1.0, 0.08, 1.0), C_FORGE)
		var m := Marker3D.new()
		m.name = "ForgePad"
		m.position = fp + Vector3(0, 0.2, 0)
		m.add_to_group("forge_pad")
		add_child(m)


# --------------------------------------------------------------- multimesh

func _commit_multimeshes() -> void:
	var mat_main := StandardMaterial3D.new()
	mat_main.albedo_color = Color.WHITE
	mat_main.vertex_color_use_as_albedo = true
	mat_main.roughness = 0.95
	var mmi := _commit(_main, mat_main,
		AABB(Vector3(-ARENA_HALF, -2, -ARENA_HALF), Vector3(ARENA_HALF * 2, 20, ARENA_HALF * 2)))
	mmi.name = "StaticVoxels"
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mmi)

	var mat_glow := StandardMaterial3D.new()
	mat_glow.albedo_color = Color(0.12, 0.08, 0.05)
	mat_glow.emission_enabled = true
	mat_glow.emission = C_FORGE
	# Emissive-only glow boost (no bloom post-processing): 4.0x reads as
	# visibly lit windows / forge pads at dusk without any extra pass.
	mat_glow.emission_energy_multiplier = 4.0
	var mmi_g := _commit(_glow, mat_glow, mmi.multimesh.custom_aabb)
	mmi_g.name = "GlowVoxels"
	mmi_g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi_g)

	var mat_city := StandardMaterial3D.new()
	mat_city.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_city.albedo_color = Color.WHITE
	mat_city.vertex_color_use_as_albedo = true
	var mmi_c := _commit(_city, mat_city,
		AABB(Vector3(-220, -10, -220), Vector3(440, 80, 440)))
	mmi_c.name = "DistantCity"
	mmi_c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi_c)


func _commit(entries: Array, mat: Material, aabb: AABB) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _unit_box
	mm.instance_count = entries.size()
	for i in entries.size():
		var e: Array = entries[i]
		var basis := Basis(Vector3.UP, e[3]).scaled(e[1])
		mm.set_instance_transform(i, Transform3D(basis, e[0]))
		mm.set_instance_color(i, e[2])
	mm.custom_aabb = aabb
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	return mmi


# -------------------------------------------------------------------- motes

func _build_motes() -> void:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(32, 3.5, 32)
	pm.direction = Vector3(0.3, 0.15, 0.1)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.6
	pm.gravity = Vector3(0, 0.02, 0)
	pm.damping_min = 0.05
	pm.damping_max = 0.15
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	pm.color = Color(1.0, 0.82, 0.58, 0.5)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.07, 0.07)
	var qmat := StandardMaterial3D.new()
	qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qmat.albedo_color = Color(1.0, 0.82, 0.58, 0.5)
	qmat.emission_enabled = true
	qmat.emission = Color(1.0, 0.75, 0.45)
	qmat.emission_energy_multiplier = 0.8
	quad.material = qmat
	var motes := GPUParticles3D.new()
	motes.name = "DustMotes"
	motes.amount = MOTE_COUNT
	motes.lifetime = 7.0
	motes.preprocess = 7.0
	motes.process_material = pm
	motes.draw_pass_1 = quad
	motes.emitting = true
	motes.visibility_aabb = AABB(Vector3(-40, -2, -40), Vector3(80, 16, 80))
	motes.position = Vector3(0, 4, 0)
	motes.add_to_group("fx_motes")  # perf scaler disables this group on low tier
	add_child(motes)


# ----------------------------------------------------------------- navigation

func _bake_nav() -> void:
	# Runtime navmesh bake from the static walk surfaces. Destructible cover
	# is excluded on purpose (see file header).
	var src := NavigationMeshSourceGeometryData3D.new()
	for b in _nav_boxes:
		_add_box_faces(src, b[0], b[1])
	if not src.has_data():
		return
	var nm := NavigationMesh.new()
	nm.agent_height = NAV_AGENT_HEIGHT
	nm.agent_radius = NAV_AGENT_RADIUS
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	_nav_region.navigation_mesh = nm


func _add_box_faces(src: NavigationMeshSourceGeometryData3D, c: Vector3, s: Vector3) -> void:
	# Adds all 6 faces of an axis-aligned box. Each quad is emitted in BOTH
	# windings: Godot front faces are clockwise, but emitting both guarantees
	# the baker sees an upward normal for walkable tops regardless of the
	# winding convention — down-facing duplicates are discarded by slope test.
	var hx := s.x * 0.5
	var hy := s.y * 0.5
	var hz := s.z * 0.5
	var v := [
		c + Vector3(-hx, -hy, -hz), c + Vector3(hx, -hy, -hz),
		c + Vector3(hx, hy, -hz), c + Vector3(-hx, hy, -hz),
		c + Vector3(-hx, -hy, hz), c + Vector3(hx, -hy, hz),
		c + Vector3(hx, hy, hz), c + Vector3(-hx, hy, hz),
	]
	var quads := [
		[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3],
		[1, 2, 6, 5], [0, 1, 5, 4], [3, 7, 6, 2],
	]
	var faces := PackedVector3Array()
	for q in quads:
		var a: Vector3 = v[q[0]]
		var b: Vector3 = v[q[1]]
		var cc: Vector3 = v[q[2]]
		var d: Vector3 = v[q[3]]
		faces.append_array([a, b, cc, a, cc, d])  # winding A
		faces.append_array([a, cc, b, a, d, cc])  # winding B (reversed)
	src.add_faces(faces, Transform3D.IDENTITY)
