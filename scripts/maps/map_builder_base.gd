# scripts/maps/map_builder_base.gd
# FORGEFALL — shared base for procedural voxel maps (Goal 3, Worker A).
#
# Dustline's builder proved the pattern: ALL static opaque voxels in ONE
# MultiMeshInstance3D, emissive bits in a second, distant city in a third,
# collision as simplified invisible StaticBody3D boxes, navmesh baked once
# at load from the walk surfaces, markers in the "player_spawn" /
# "spawn_door" / "forge_pad" groups. This base extracts exactly those
# mechanics so new maps (Foundry, Outpost) only declare layout.
#
# Subclass contract: in _ready(), seed _rng, create _unit_box, call
# _build_environment(), then your layout builders, then
# _commit_multimeshes(), _build_motes(), _bake_nav().
class_name MapBuilderBase
extends Node3D

# Palette mirrors the frozen VoxelBuilder.PALETTE hex values (same as Dustline).
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
const C_GUNMETAL := Color("3a3f44")
const C_STEEL := Color("6a7078")
const C_STEEL_D := Color("4a4f56")

const PAL_BARREL := [Color("8a4b2a"), Color("653620"), Color("23262a")]
const PAL_CRATE := [Color("7a5c38"), Color("57412a"), Color("8a6c42")]
const PAL_BARRIER := [Color("9a958c"), Color("7d786f"), Color("6b665e")]

const NAV_AGENT_HEIGHT := 1.7
const NAV_AGENT_RADIUS := 0.35

var _rng := RandomNumberGenerator.new()
var _main: Array = []   # [pos, size, color, rot_y] static shaded voxels
var _glow: Array = []   # emissive voxels
var _city: Array = []   # distant skyline (unshaded)
var _nav_boxes: Array = []  # [center, size] walkable surfaces for nav bake
var _unit_box: BoxMesh
var _collision_root: StaticBody3D
var _nav_region: NavigationRegion3D


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
	c.palette.assign(palette)
	c.hp = hp
	c.position = pos
	c.rotation.y = rot_y
	add_child(c)  # _ready() builds its mesh + collision immediately


# Flat axis-aligned wall: one voxel box + collision. Used for perimeter and
# interior partition walls (door gaps are made by placing segments).
func _wall(center: Vector3, size: Vector3, color: Color) -> void:
	_v(center, size, color)
	_solid(center, size)


# ------------------------------------------------------------------ skies
# BB-6 (2026-11-26): every map used to share ONE environment — a 5-stop
# gradient panorama that fog (fog_sky_affect 0.5, warm fog colour) washed
# into a featureless peach void on every map: no sun disc, no structure,
# no identity (see sky-audit/AUDIT.md). Now each map gets a named sky
# profile: a ProceduralSkyMaterial (real sun/moon disc that tracks the
# map's DirectionalLight3D, per-map colours) plus a generated sky_cover
# texture (streaky dusk clouds, or a star field for the zombies night).
# One fullscreen sky pass + one texture fetch: cheaper than the old
# panorama, glow stays OFF, one shadowed sun stays the rule.
const SKY_PROFILES := {
	"dustline": {
		"top": Color(0.145, 0.09, 0.30), "horizon": Color(0.98, 0.44, 0.15),
		"ground_horizon": Color(0.42, 0.25, 0.15), "ground_bottom": Color(0.07, 0.045, 0.04),
		"sky_curve": 0.12, "ground_curve": 0.04, "sun_angle_max": 14.0, "sun_curve": 0.35,
		"energy": 1.0, "fog_color": Color(0.92, 0.50, 0.26), "scatter": 0.15, "sky_affect": 0.25,
		"sun_color": Color(1.0, 0.66, 0.42), "sun_energy": 1.30, "ambient_energy": 0.55,
		"exposure": 1.1, "cover": "clouds", "cover_modulate": Color(1.0, 0.74, 0.52, 0.50),
	},
	"cinder_city": {
		"top": Color(0.16, 0.07, 0.17), "horizon": Color(0.82, 0.24, 0.09),
		"ground_horizon": Color(0.28, 0.13, 0.09), "ground_bottom": Color(0.05, 0.03, 0.03),
		"sky_curve": 0.13, "ground_curve": 0.04, "sun_angle_max": 20.0, "sun_curve": 0.12,
		"energy": 0.95, "fog_color": Color(0.62, 0.30, 0.19), "scatter": 0.10, "sky_affect": 0.25,
		"sun_color": Color(0.95, 0.50, 0.32), "sun_energy": 1.25, "ambient_energy": 0.55,
		"exposure": 1.05, "cover": "clouds", "cover_modulate": Color(0.42, 0.28, 0.26, 0.60),
	},
	"factory": {
		"top": Color(0.20, 0.16, 0.23), "horizon": Color(0.72, 0.47, 0.29),
		"ground_horizon": Color(0.30, 0.22, 0.16), "ground_bottom": Color(0.06, 0.05, 0.045),
		"sky_curve": 0.14, "ground_curve": 0.04, "sun_angle_max": 18.0, "sun_curve": 0.18,
		"energy": 0.95, "fog_color": Color(0.66, 0.50, 0.36), "scatter": 0.12, "sky_affect": 0.25,
		"sun_color": Color(0.98, 0.72, 0.50), "sun_energy": 1.10, "ambient_energy": 0.55,
		"exposure": 1.05, "cover": "clouds", "cover_modulate": Color(0.62, 0.56, 0.50, 0.55),
	},
	"foundry": {
		"top": Color(0.14, 0.09, 0.17), "horizon": Color(0.85, 0.36, 0.13),
		"ground_horizon": Color(0.33, 0.18, 0.11), "ground_bottom": Color(0.05, 0.035, 0.03),
		"sky_curve": 0.13, "ground_curve": 0.04, "sun_angle_max": 15.0, "sun_curve": 0.25,
		"energy": 0.97, "fog_color": Color(0.78, 0.44, 0.24), "scatter": 0.13, "sky_affect": 0.25,
		"sun_color": Color(1.0, 0.62, 0.38), "sun_energy": 1.25, "ambient_energy": 0.55,
		"exposure": 1.08, "cover": "clouds", "cover_modulate": Color(0.55, 0.42, 0.36, 0.55),
	},
	"outpost": {
		"top": Color(0.16, 0.30, 0.55), "horizon": Color(0.92, 0.60, 0.34),
		"ground_horizon": Color(0.40, 0.30, 0.20), "ground_bottom": Color(0.07, 0.06, 0.05),
		"sky_curve": 0.11, "ground_curve": 0.04, "sun_angle_max": 10.0, "sun_curve": 0.50,
		"energy": 1.05, "fog_color": Color(0.85, 0.58, 0.38), "scatter": 0.15, "sky_affect": 0.22,
		"sun_color": Color(1.0, 0.85, 0.66), "sun_energy": 1.50, "ambient_energy": 0.70,
		"exposure": 1.1, "cover": "clouds", "cover_modulate": Color(1.0, 0.92, 0.82, 0.35),
	},
	"tower_defense": {
		"top": Color(0.17, 0.11, 0.33), "horizon": Color(0.96, 0.46, 0.16),
		"ground_horizon": Color(0.40, 0.24, 0.14), "ground_bottom": Color(0.07, 0.045, 0.04),
		"sky_curve": 0.12, "ground_curve": 0.04, "sun_angle_max": 12.0, "sun_curve": 0.40,
		"energy": 1.0, "fog_color": Color(0.90, 0.52, 0.28), "scatter": 0.15, "sky_affect": 0.25,
		"sun_color": Color(1.0, 0.70, 0.46), "sun_energy": 1.35, "ambient_energy": 0.60,
		"exposure": 1.1, "cover": "clouds", "cover_modulate": Color(1.0, 0.72, 0.50, 0.45),
	},
	"zombies_night": {
		"top": Color(0.012, 0.020, 0.050), "horizon": Color(0.050, 0.075, 0.120),
		"ground_horizon": Color(0.030, 0.040, 0.070), "ground_bottom": Color(0.008, 0.010, 0.020),
		"sky_curve": 0.10, "ground_curve": 0.03, "sun_angle_max": 5.0, "sun_curve": 0.80,
		"energy": 1.0, "fog_color": Color(0.050, 0.070, 0.110), "scatter": 0.03, "sky_affect": 0.20,
		"sun_color": Color(0.60, 0.72, 1.0), "sun_energy": 0.50, "ambient_energy": 0.60,
		"exposure": 1.05, "cover": "stars", "cover_modulate": Color(1.0, 1.0, 1.0, 1.0),
	},
}

static var _sky_cover_cache: Dictionary = {}


static func sky_profile(profile_name: String) -> Dictionary:
	return SKY_PROFILES.get(profile_name, SKY_PROFILES["dustline"])


# Generated once per process, shared by every map: horizontal streaks of
# value noise in an equirect band above the horizon (v 0.05..0.47; v=0 is
# the zenith, 0.5 the horizon). Alpha carries the coverage.
static func _cloud_cover_texture() -> Texture2D:
	if _sky_cover_cache.has("clouds"):
		return _sky_cover_cache["clouds"]
	var w := 512
	var h := 256
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var n1 := FastNoiseLite.new()
	n1.seed = 20261
	n1.frequency = 1.0
	n1.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	var n2 := FastNoiseLite.new()
	n2.seed = 7741
	n2.frequency = 1.0
	n2.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	for y in h:
		var v := float(y) / float(h - 1)
		var band := smoothstep(0.04, 0.16, v) * (1.0 - smoothstep(0.30, 0.46, v))
		if band <= 0.001:
			continue
		for x in w:
			var streak := n1.get_noise_2d(float(x) * 0.022, float(y) * 0.14) * 0.65 				+ n2.get_noise_2d(float(x) * 0.055 + 300.0, float(y) * 0.34) * 0.35
			var a := clampf((streak - 0.10) * 1.6, 0.0, 1.0) * band * 0.9
			if a > 0.003:
				img.set_pixel(x, y, Color(1.0, 0.93, 0.85, a))
	var tex := ImageTexture.create_from_image(img)
	_sky_cover_cache["clouds"] = tex
	return tex


# Star field for the night profile: fixed-seed random points, alpha =
# brightness, only above the horizon (v < 0.47). A handful of brighter
# 2 px stars for depth.
static func _star_cover_texture() -> Texture2D:
	if _sky_cover_cache.has("stars"):
		return _sky_cover_cache["stars"]
	var w := 1024
	var h := 512
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	for i in 1500:
		var x := rng.randi_range(0, w - 1)
		var y := int(pow(rng.randf(), 1.35) * float(h) * 0.46)
		var b := rng.randf_range(0.30, 1.0)
		img.set_pixel(x, y, Color(b, b, b, b))
		if i % 11 == 0 and x + 1 < w:
			img.set_pixel(x + 1, y, Color(b * 0.7, b * 0.7, b * 0.7, b * 0.7))
	var tex := ImageTexture.create_from_image(img)
	_sky_cover_cache["stars"] = tex
	return tex


static func make_sky_material(profile: Dictionary) -> ProceduralSkyMaterial:
	var smat := ProceduralSkyMaterial.new()
	smat.sky_top_color = profile["top"]
	smat.sky_horizon_color = profile["horizon"]
	smat.sky_curve = profile["sky_curve"]
	smat.sky_energy_multiplier = profile["energy"]
	smat.ground_bottom_color = profile["ground_bottom"]
	smat.ground_horizon_color = profile["ground_horizon"]
	smat.ground_curve = profile["ground_curve"]
	smat.ground_energy_multiplier = profile["energy"]
	smat.sun_angle_max = profile["sun_angle_max"]
	smat.sun_curve = profile["sun_curve"]
	match str(profile.get("cover", "")):
		"clouds":
			smat.sky_cover = _cloud_cover_texture()
			smat.sky_cover_modulate = profile["cover_modulate"]
		"stars":
			smat.sky_cover = _star_cover_texture()
			smat.sky_cover_modulate = profile["cover_modulate"]
	return smat


static func make_environment(profile: Dictionary, fog_density: float) -> Environment:
	var sky := Sky.new()
	sky.sky_material = make_sky_material(profile)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = profile["ambient_energy"]
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = profile["exposure"]
	env.glow_enabled = false  # NO bloom: too expensive on a Galaxy S23.
	env.fog_enabled = true
	env.fog_light_color = profile["fog_color"]
	env.fog_density = fog_density
	env.fog_sun_scatter = profile["scatter"]
	env.fog_sky_affect = profile["sky_affect"]
	return env


# Per-map environment: the map's sky profile drives sky, fog colour,
# ambient and the sun's colour/energy; fog_density and sun_angle stay
# per-map dials (tighter maps hazier, open maps clearer).
func _build_environment(fog_density := 0.0075, sun_angle := Vector3(-48, -32, 0), profile_name := "dustline") -> void:
	var profile := sky_profile(profile_name)
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = make_environment(profile, fog_density)
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.position = Vector3(0, 40, 0)
	sun.rotation_degrees = sun_angle
	sun.light_color = profile["sun_color"]
	sun.light_energy = profile["sun_energy"]
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_fade_start = 0.9
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 1.0
	sun.shadow_blur = 1.0
	add_child(sun)

	_collision_root = StaticBody3D.new()
	_collision_root.name = "StaticCollision"
	add_child(_collision_root)

	_nav_region = NavigationRegion3D.new()
	_nav_region.name = "NavRegion"
	add_child(_nav_region)


# Perimeter walls: 4 sides of jittered-height segments + crenellation, at
# +/- arena_half. Door positions are drawn on the inner faces by
# _build_spawn_markers(); this only builds the wall shell.
func _build_perimeter(arena_half: float, h_min := 3.0, h_max := 4.2) -> void:
	var seg := arena_half * 2.0 / 8.0
	for side in 4:
		for i in 8:
			var t := -arena_half + seg * 0.5 + float(i) * seg
			var h := _rng.randf_range(h_min, h_max)
			var col: Color = _pick([C_CONCRETE, C_TAN, C_RUST, C_WOOD])
			var center := Vector3.ZERO
			match side:
				0:
					center = Vector3(t, h * 0.5, -arena_half)
				1:
					center = Vector3(t, h * 0.5, arena_half)
				2:
					center = Vector3(-arena_half, h * 0.5, t)
				_:
					center = Vector3(arena_half, h * 0.5, t)
			var size := Vector3(seg, h, 0.6) if side < 2 else Vector3(0.6, h, seg)
			_v(center, size, col)
			_solid(center, size)
			var n := int(seg / 2.2)
			for k in n:
				var off := -seg * 0.5 + 1.1 + float(k) * 2.2
				var cp := center + Vector3(off, h * 0.5 + 0.25, 0) if side < 2 else center + Vector3(0, h * 0.5 + 0.25, off)
				_v(cp, Vector3(0.5, 0.5, 0.5), col.darkened(0.15))


# Markers + visuals. player_spawns: Vector3 list (y = spawn height).
# doors: Vector3 list on the inner perimeter faces (x or z == +/- arena_half
# approx). forge_pads: Vector3 list (y = pad deck height; 0 = ground).
# Door visuals: dark inset + orange glow strip, facing inward.
func _build_spawn_markers(player_spawns: Array, doors: Array, forge_pads: Array, arena_half: float) -> void:
	for sp in player_spawns:
		var m := Marker3D.new()
		m.name = "PlayerSpawn"
		m.position = sp
		m.add_to_group("player_spawn")
		add_child(m)
	for dp in doors:
		var inward := Vector3.ZERO
		if absf(dp.z) > absf(dp.x):
			inward = Vector3(0, 0, -signf(dp.z))
		else:
			inward = Vector3(-signf(dp.x), 0, 0)
		var face: Vector3 = dp + inward * 0.05
		var rot := 0.0 if absf(dp.z) > absf(dp.x) else PI * 0.5
		_v(face + Vector3(0, 1.25, 0), Vector3(1.5, 2.5, 0.14), C_DARKMETAL, rot)
		_g(face + Vector3(0, 2.65, 0), Vector3(1.5, 0.14, 0.2), C_FORGE, rot)
		var m := Marker3D.new()
		m.name = "SpawnDoor"
		m.position = dp + Vector3(0, 0.1, 0)
		m.add_to_group("spawn_door")
		add_child(m)
	for fp in forge_pads:
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


func _commit_multimeshes(aabb: AABB) -> void:
	var mat_main := StandardMaterial3D.new()
	mat_main.albedo_color = Color.WHITE
	mat_main.vertex_color_use_as_albedo = true
	mat_main.roughness = 0.95
	var mmi := _commit(_main, mat_main, aabb)
	mmi.name = "StaticVoxels"
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mmi)

	var mat_glow := StandardMaterial3D.new()
	mat_glow.albedo_color = Color(0.12, 0.08, 0.05)
	mat_glow.emission_enabled = true
	mat_glow.emission = C_FORGE
	mat_glow.emission_energy_multiplier = 4.0
	var mmi_g := _commit(_glow, mat_glow, aabb)
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


func _build_motes(extents := Vector3(32, 3.5, 32), count := 200) -> void:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = extents
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
	motes.amount = count
	motes.lifetime = 7.0
	motes.preprocess = 7.0
	motes.process_material = pm
	motes.draw_pass_1 = quad
	motes.emitting = true
	motes.visibility_aabb = AABB(-extents - Vector3(8, 2, 8), extents * 2 + Vector3(16, 16, 16))
	motes.position = Vector3(0, 4, 0)
	motes.add_to_group("fx_motes")  # perf scaler disables this group on low tier
	add_child(motes)


func _bake_nav() -> void:
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
		faces.append_array([a, b, cc, a, cc, d])
		faces.append_array([a, cc, b, a, d, cc])
	src.add_faces(faces, Transform3D.IDENTITY)
