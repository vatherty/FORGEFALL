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


func _c(pos: Vector3, size: Vector3, color: Color, rot_y: float = 0.0) -> void:
	_city.append([pos, size, color, rot_y])


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


# ------------------------------------------------------------------ BB-7: play bounds + ground apron
# Colin (bug-bash BB-7): "on almost all maps you can fly off and not
# die." Three-part fix; this is the map side:
#   1. play_bounds — the combat-area AABB, registered per map via
#      set_play_bounds(). The player (player.gd) finds it through the
#      "map_play_bounds" group: outside the box the OOB countdown runs;
#      falling below play_bounds.min.y - 25 dies outright. Bounds sit
#      generously OUTSIDE the arena walls, so they only bite when a
#      player is genuinely leaving, never when hugging an edge.
#   2. _build_ground_apron() — one huge flat ground plane (visual +
#      collision) at the map's floor height, extending far past fog
#      visibility, so the ground visually meets the sky at the horizon
#      and the world has no visible edge to fly off.
# Maps that never call set_play_bounds() (Studio / custom maps) get no
# OOB countdown — the player's absolute kill floor still applies there.
var play_bounds := AABB()
var has_play_bounds := false


## Register this map's combat-area AABB (world space; builders build at
## the origin, so local == world). Call once from _ready().
func set_play_bounds(bounds: AABB) -> void:
	play_bounds = bounds
	has_play_bounds = true
	add_to_group("map_play_bounds")


## One big flat ground plane at floor height y (visual mesh + collision)
## so the world does not visibly end at the arena wall. size is the full
## width (900 m default: past the fog on every map). The apron's top
## sits 1 cm BELOW y: inside the arena the map's own ground slab (top
## exactly at y) hides the overlap seam, and outside the step down is
## imperceptible while the collision stays continuous.
func _build_ground_apron(color: Color, size := 900.0, y := 0.0) -> void:
	build_ground_apron(self, color, size, y)


## Static form so Dustline (which predates this base class and keeps
## its own builder) builds the identical apron. Returns the apron root
## (name "GroundApron": ApronMesh + ApronCollision children).
static func build_ground_apron(parent: Node3D, color: Color, size: float, y: float) -> Node3D:
	var apron := Node3D.new()
	apron.name = "GroundApron"
	parent.add_child(apron)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	var box := BoxMesh.new()
	box.size = Vector3(size, 0.5, size)
	box.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "ApronMesh"
	mi.mesh = box
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(0.0, y - 0.26, 0.0)
	apron.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "ApronCollision"
	var cs := CollisionShape3D.new()
	cs.name = "ApronShape"
	var shape := BoxShape3D.new()
	shape.size = Vector3(size, 0.5, size)
	cs.shape = shape
	cs.position = Vector3(0.0, y - 0.26, 0.0)
	body.add_child(cs)
	apron.add_child(body)
	return apron


# ------------------------------------------------------------------ skies
# BB-6 (2026-11-26) killed the shared gradient panorama that fog washed
# into a featureless peach void on every map, and gave each map a named
# procedural profile. Colin then asked for the real thing: "an actual
# skybox that's copyright free" — so every profile now points at a REAL
# photographic sky (Poly Haven, CC0 / public domain; see
# assets/skies/SOURCES.md for provenance + conversion details).
# make_sky_material() wraps the map's equirect JPG in a
# PanoramaSkyMaterial; fog colour is sampled programmatically from the
# texture's horizon band (sun-core-trimmed mean, linear) so the horizon
# seam stays invisible, and each builder aims its DirectionalLight3D at
# the sun/moon position estimated from the HDR's brightest region, so
# shadows agree with the visible sun. Glow stays OFF, one shadowed sun
# stays the rule.
const SKY_PROFILES := {
	"dustline": {
		"texture": "res://assets/skies/dustline_sky.jpg",
		"fog_color": Color(0.435, 0.408, 0.430), "scatter": 0.15, "sky_affect": 0.25,
		"sun_color": Color(1.0, 0.72, 0.50), "sun_energy": 1.30, "ambient_energy": 0.55,
		"exposure": 1.1,
	},
	"cinder_city": {
		"texture": "res://assets/skies/cinder_city_sky.jpg",
		"fog_color": Color(0.407, 0.447, 0.493), "scatter": 0.10, "sky_affect": 0.25,
		"sun_color": Color(1.0, 0.66, 0.48), "sun_energy": 1.25, "ambient_energy": 0.55,
		"exposure": 1.05,
	},
	"factory": {
		"texture": "res://assets/skies/factory_sky.jpg",
		"fog_color": Color(0.460, 0.476, 0.505), "scatter": 0.05, "sky_affect": 0.25,
		"sun_color": Color(1.0, 0.94, 0.88), "sun_energy": 0.85, "ambient_energy": 0.65,
		"exposure": 1.05,
	},
	"foundry": {
		"texture": "res://assets/skies/foundry_sky.jpg",
		"fog_color": Color(0.703, 0.683, 0.648), "scatter": 0.13, "sky_affect": 0.25,
		"sun_color": Color(1.0, 0.58, 0.37), "sun_energy": 1.25, "ambient_energy": 0.55,
		"exposure": 1.08,
	},
	"outpost": {
		"texture": "res://assets/skies/outpost_sky.jpg",
		"fog_color": Color(0.217, 0.253, 0.298), "scatter": 0.15, "sky_affect": 0.22,
		"sun_color": Color(1.0, 0.97, 0.92), "sun_energy": 1.50, "ambient_energy": 0.70,
		"exposure": 1.1,
	},
	"tower_defense": {
		"texture": "res://assets/skies/tower_defense_sky.jpg",
		"fog_color": Color(0.345, 0.389, 0.429), "scatter": 0.10, "sky_affect": 0.25,
		"sun_color": Color(1.0, 0.72, 0.53), "sun_energy": 1.10, "ambient_energy": 0.60,
		"exposure": 1.1,
	},
	"zombies_night": {
		"texture": "res://assets/skies/zombies_flat_sky.jpg",
		"fog_color": Color(0.008, 0.006, 0.006), "scatter": 0.03, "sky_affect": 0.20,
		"sun_color": Color(0.60, 0.68, 1.0), "sun_energy": 0.50, "ambient_energy": 0.50,
		"exposure": 1.05,
	},
}


static func sky_profile(profile_name: String) -> Dictionary:
	return SKY_PROFILES.get(profile_name, SKY_PROFILES["dustline"])


static func make_sky_material(profile: Dictionary) -> PanoramaSkyMaterial:
	var smat := PanoramaSkyMaterial.new()
	smat.panorama = load(str(profile["texture"])) as Texture2D
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
	env.glow_enabled = false  # NO bloom at Low: too expensive on a Galaxy S23.
	env.fog_enabled = true
	env.fog_light_color = profile["fog_color"]
	env.fog_density = fog_density
	env.fog_sun_scatter = profile["scatter"]
	env.fog_sky_affect = profile["sky_affect"]
	return env


# ------------------------------------------------------------------ BB-9 gfx
# Graphics push (Colin: "add all of them", FPS-gated per feature — see
# GfxSettings for the tier/flag resolution). make_environment() above is
# the LOW path and stays exactly as shipped; everything in this section
# layers on top only when its feature flag is on.

## make_environment + the High-tier environment features for a profile:
## glow (bloom threshold parked at 1.0 so the LDR photo skies — peak
## ~1.0 after exposure — stay under it while HDR emissives like the
## forge-orange glow voxels at energy 4.0 bloom) and colour grading
## (per-profile 32^3 LUT from GfxSettings).
static func gfx_environment(profile: Dictionary, fog_density: float, profile_name: String) -> Environment:
	var env := make_environment(profile, fog_density)
	if GfxSettings.feature("glow"):
		env.glow_enabled = true
		# Tuned against captures: threshold 1.15 sits above sunlit white
		# albedo (~1.3 peak gets only a hot edge) and far below the
		# emissive voxels (energy 4.0); tight levels 0-2 only — the
		# wide levels are what veiled the whole frame in haze at first
		# tune. Forge pads / lit windows bloom; the sky does not.
		env.glow_intensity = 0.3
		env.glow_strength = 0.85
		env.glow_bloom = 1.15  # threshold: skies must NOT bloom (BB-6 trap)
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
		for lvl in range(7):  # glow levels are 0..6 in Godot 4
			env.set_glow_level(lvl, lvl <= 2)
	if GfxSettings.feature("grading"):
		env.adjustment_enabled = true
		env.adjustment_color_correction = GfxSettings.lut_texture(profile_name)
	return env


## High-tier sun: parallel-split (PSSM 4) cascades reaching 250 m
## instead of the single 90 m orthogonal box, so near shadows stay
## texel-dense while buildings still shadow at gameplay ranges across
## the arena. Normal bias rises slightly (1.0 -> 1.2): at split texel
## sizes it is the acne lever, and 0.2 m of extra offset is invisible
## against metre-scale voxels (no peter-panning at this scale).
static func gfx_sun(sun: DirectionalLight3D) -> void:
	if not GfxSettings.feature("shadows"):
		return
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 250.0
	sun.directional_shadow_fade_start = 0.85
	sun.shadow_normal_bias = 1.2


static var _grit_material: Material = null


## The main block material: today's flat StandardMaterial3D at Low, or
## the shared world-space grit/AO shader material when either feature
## is on (uniforms switch the two effects independently, so grit and ao
## stay separately toggleable — see voxel_grit.gdshader).
static func gfx_main_material() -> Material:
	if not (GfxSettings.feature("grit") or GfxSettings.feature("ao")):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.WHITE
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.95
		return mat
	if _grit_material == null:
		var sm := ShaderMaterial.new()
		sm.shader = load("res://assets/shaders/voxel_grit.gdshader")
		sm.set_shader_parameter("grit_enabled", GfxSettings.feature("grit"))
		sm.set_shader_parameter("ao_enabled", GfxSettings.feature("ao"))
		_grit_material = sm
	return _grit_material


static var _grime_texture: Texture2D = null


## Procedural decal texture: layered soft blotches (oil/grime) with
## speckled edges, alpha strongest at the centre. One shared texture;
## per-decal variety comes from random rotation/scale/modulate.
static func grime_texture() -> Texture2D:
	if _grime_texture != null:
		return _grime_texture
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9009
	var blobs: Array = []
	for i in 42:
		blobs.append([Vector2(rng.randf_range(50, 206), rng.randf_range(50, 206)),
			rng.randf_range(14.0, 62.0), rng.randf_range(0.10, 0.30)])
	for y in n:
		for x in n:
			var p := Vector2(x, y)
			var a := 0.0
			for b in blobs:
				var d := p.distance_to(b[0])
				a += b[2] * clampf(1.0 - d / b[1], 0.0, 1.0)
			# Radial containment: stains never touch the decal quad edge.
			var dc := p.distance_to(Vector2(128, 128)) / 128.0
			a *= clampf(1.2 - dc, 0.0, 1.0)
			a *= 0.85 + 0.15 * rng.randf()
			img.set_pixel(x, y, Color(0.05, 0.04, 0.03, clampf(a, 0.0, 0.85)))
	_grime_texture = ImageTexture.create_from_image(img)
	return _grime_texture


## Scatter flat ground decals (grime / scorch / oil) over the arena
## floor. High tier only; counts stay in the tens. y: decal box spans
## 0..1.5 so it projects onto the y=0 ground slab (and anything low).
func _build_ground_decals(count: int, extent: float) -> void:
	if not GfxSettings.feature("decals"):
		return
	var root := Node3D.new()
	root.name = "GroundDecals"
	add_child(root)
	for i in count:
		var d := Decal.new()
		var s := _rng.randf_range(2.5, 6.5)
		d.size = Vector3(s, 1.5, s)
		d.position = Vector3(_rng.randf_range(-extent, extent), 0.75,
			_rng.randf_range(-extent, extent))
		d.rotation.y = _rng.randf_range(0.0, TAU)
		d.texture_albedo = grime_texture()
		d.modulate = Color(1, 1, 1, _rng.randf_range(0.4, 0.75))
		root.add_child(d)


# Per-map environment: the map's sky profile drives sky, fog colour,
# ambient and the sun's colour/energy; fog_density and sun_angle stay
# per-map dials (tighter maps hazier, open maps clearer).
func _build_environment(fog_density := 0.0075, sun_angle := Vector3(-48, -32, 0), profile_name := "dustline") -> void:
	var profile := sky_profile(profile_name)
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = gfx_environment(profile, fog_density, profile_name)
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
	gfx_sun(sun)  # BB-9: PSSM cascades + reach when the shadows feature is on
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
	var mat_main := gfx_main_material()  # BB-9: grit/AO shader when on
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
