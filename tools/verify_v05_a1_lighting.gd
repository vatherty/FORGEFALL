# verify_v05_a1_lighting.gd — headless checks for A1 Lighting & Atmosphere.
# Usage: godot --headless --path <project> --script res://tools/verify_v05_a1_lighting.gd
# Instantiates the real Dustline map scene and asserts:
#   1. Map builds (StaticVoxels MultiMesh has instances).
#   2. Exactly ONE DirectionalLight3D ("Sun") with shadow_enabled, cheap
#      mobile settings (orthogonal, tight frustum, blur 1.0 to soften
#      texel moire — dustline_builder sets 1.0 deliberately). Shadow map
#      SIZE is a project setting in Godot 4.7, reported not asserted.
#   3. A WorldEnvironment with fog + ACES tonemapping + gradient sky,
#      glow (bloom) explicitly OFF, ambient fill present.
#   4. GlowVoxels emissive boosted (>= 3.0x), glow/city cast no shadows.
#   5. Draw-call footprint unchanged: exactly 3 map MultiMeshInstance3Ds.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _map: Node = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	var ps := load("res://scenes/maps/dustline.tscn") as PackedScene
	_map = ps.instantiate()
	root.add_child(_map)
	print("VERIFY-A1: Dustline instantiated, waiting for _ready + nav bake")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 10:
		return false
	_run_checks()
	if _fails == 0:
		print("VERIFY-A1: ALL CHECKS PASSED")
	else:
		printerr("VERIFY-A1: %d CHECK(S) FAILED" % _fails)
	quit(_fails)
	return true


func _run_checks() -> void:
	# 1. Map builds.
	var static_voxels := _map.get_node_or_null("StaticVoxels") as MultiMeshInstance3D
	_check(static_voxels != null, "StaticVoxels MultiMeshInstance3D exists")
	_check(static_voxels != null and static_voxels.multimesh != null
		and static_voxels.multimesh.instance_count > 100,
		"StaticVoxels has instances (got %d)" % (
			static_voxels.multimesh.instance_count if static_voxels != null
			and static_voxels.multimesh != null else -1))
	_check(static_voxels != null and static_voxels.cast_shadow
		== GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"StaticVoxels cast shadows (sun shadows actually render)")

	# 2. Exactly one sun, with cheap mobile shadow settings.
	var suns: Array = []
	_collect(_map, "sun", suns)
	_check(suns.size() == 1, "exactly one DirectionalLight3D (got %d)" % suns.size())
	if suns.size() == 1:
		var sun := suns[0] as DirectionalLight3D
		_check(sun.shadow_enabled, "Sun shadow_enabled = true")
		_check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL,
			"Sun uses single orthogonal shadow cascade (no 4-split)")
		_check(sun.directional_shadow_max_distance <= 100.0,
			"Sun shadow frustum tight around arena (max_distance %.0f)" % sun.directional_shadow_max_distance)
		# Shadow map size is a project setting in Godot 4.7 (not per-light);
		# report it, don't fail on it — project.godot is outside this stream.
		print("INFO-A1: project directional shadow size = ",
			ProjectSettings.get_setting(
				"rendering/lights_and_shadows/directional_shadow/size"))
		_check(sun.shadow_blur == 1.0,
			"Sun shadow blur 1.0 (softens texel moire — dustline_builder sets 1.0 deliberately, was 0.0)")

	# 3. WorldEnvironment: fog + tonemapping + gradient sky + ambient.
	var we := _map.get_node_or_null("WorldEnvironment") as WorldEnvironment
	_check(we != null and we.environment != null, "WorldEnvironment with Environment exists")
	if we != null and we.environment != null:
		var env := we.environment
		_check(env.fog_enabled, "fog enabled")
		_check(env.fog_density > 0.003 and env.fog_density < 0.02,
			"fog density tuned for haze-at-range (got %.4f)" % env.fog_density)
		_check(env.tonemap_mode == Environment.TONE_MAPPER_ACES,
			"tonemapping = ACES")
		_check(env.tonemap_exposure > 0.9 and env.tonemap_exposure < 1.3,
			"tonemap exposure tuned (got %.2f)" % env.tonemap_exposure)
		_check(env.ambient_light_energy > 0.3,
			"ambient fill present (energy %.2f, shadowed sides not black)" % env.ambient_light_energy)
		_check(not env.glow_enabled, "glow/bloom OFF (no expensive post-processing)")
		_check(env.sky != null and env.sky.sky_material is PanoramaSkyMaterial,
			"gradient sky via PanoramaSkyMaterial (no procedural-sky shader)")
		if env.sky != null and env.sky.sky_material is PanoramaSkyMaterial:
			var pano := env.sky.sky_material as PanoramaSkyMaterial
			_check(pano.panorama is GradientTexture2D,
				"sky panorama is a GradientTexture2D (cheap gradient)")

	# 4. Emissive glow boosted, no shadow cost from glow/city.
	var glow := _map.get_node_or_null("GlowVoxels") as MultiMeshInstance3D
	_check(glow != null, "GlowVoxels exists")
	if glow != null:
		var gm := glow.material_override as StandardMaterial3D
		_check(gm != null and gm.emission_enabled, "glow material emission enabled")
		_check(gm != null and gm.emission_energy_multiplier >= 3.0,
			"glow emissive boosted >= 3x (got %.1f)" % (
				gm.emission_energy_multiplier if gm != null else -1.0))
		_check(glow.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"GlowVoxels cast no shadows (perf)")
	var city := _map.get_node_or_null("DistantCity") as MultiMeshInstance3D
	_check(city != null and city.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"DistantCity casts no shadows (perf)")

	# 5. Draw-call footprint unchanged: exactly 3 map MultiMeshes as DIRECT
	# children of Dustline (covers carry their own MultiMeshes; those are
	# gameplay objects, not map draw-call growth).
	var map_mmis := 0
	for c in _map.get_children():
		if c is MultiMeshInstance3D:
			map_mmis += 1
	_check(map_mmis == 3, "exactly 3 map MultiMeshInstance3Ds (got %d, no draw-call growth)" % map_mmis)


func _collect(node: Node, kind: String, out: Array) -> void:
	if kind == "sun" and node is DirectionalLight3D:
		out.append(node)
	for c in node.get_children():
		_collect(c, kind, out)
