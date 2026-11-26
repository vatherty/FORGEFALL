// assets/shaders/voxel_grit.gdshader
// FORGEFALL BB-9 — world-space grit + grounding AO for the voxel blocks.
//
// Replaces the flat StandardMaterial3D on the main MultiMesh block
// materials when the grit and/or ao graphics features are on (see
// GfxSettings). Lighting, fog, shadow receiving and tonemapping still
// come from the standard forward pipeline — this shader only shapes
// ALBEDO before lighting, starting from the per-instance colour (COLOR),
// so the game's colour identity is modulated, never repainted.
//
// Because everything keys off WORLD position (MODEL_MATRIX includes the
// per-instance transform), every instanced block gets its own variation
// for free — no UVs needed, which matters: the blocks are a unit BoxMesh
// with per-instance scale, so UV-space detail would stretch per block.
//
// grit: 3-octave value-noise albedo variation (broad patchiness, grain,
//   speckle), per-instance tint jitter (hash of the instance origin),
//   brown dirt creep near ground level, subtle lightening on box edges
//   (worn/chipped edges, from unit-box local coords).
// ao: contact darkening in a band at ground level (blocks sit INTO the
//   world instead of floating on it), extra darkening on downward-facing
//   surfaces (soffits/undersides read as occluded), both broken up by
//   noise so the bands never look like gradients painted on.
//   This is the shader route (option b) — the MultiMesh architecture
//   has no per-vertex bake step, so true baked corner AO (option a)
//   does not apply. Mobile renderer has no SSAO; this is the stand-in.

shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform bool grit_enabled = true;
uniform bool ao_enabled = true;
uniform float grit_strength : hint_range(0.0, 1.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 local_pos;
varying float instance_rand;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	local_pos = VERTEX;
	instance_rand = hash13(floor(MODEL_MATRIX[3].xyz * 4.0));
}

void fragment() {
	vec3 base = COLOR.rgb;

	float n_broad = vnoise(world_pos * 0.55);
	float n_grain = vnoise(world_pos * 2.3);
	float n_speck = vnoise(world_pos * 11.0);

	if (grit_enabled) {
		float v = mix(0.90, 1.10, n_broad)
			* mix(0.94, 1.06, n_grain)
			* mix(0.96, 1.04, n_speck);
		v *= mix(0.95, 1.05, instance_rand);
		base *= mix(1.0, v, grit_strength);

		// Dirt creep: brown darkening that climbs ~1.4 m from the ground.
		float dirt = smoothstep(1.4, 0.0, world_pos.y) * (0.40 + 0.60 * n_grain);
		vec3 dirt_tint = vec3(0.45, 0.36, 0.25);
		base = mix(base, base * dirt_tint * 1.7, dirt * 0.34 * grit_strength);

		// Edge wear: lighten where two local axes are near the box faces
		// (unit box local coords run -0.5..0.5). Corners/edges only.
		vec3 e = abs(local_pos) * 2.0;
		float wear = smoothstep(0.80, 0.99, e.x) * smoothstep(0.80, 0.99, e.y)
			+ smoothstep(0.80, 0.99, e.x) * smoothstep(0.80, 0.99, e.z)
			+ smoothstep(0.80, 0.99, e.y) * smoothstep(0.80, 0.99, e.z);
		base *= 1.0 + clamp(wear, 0.0, 1.0) * 0.10 * grit_strength;
	}

	if (ao_enabled) {
		float ao = 1.0;
		// Ground-contact band: strongest at y=0, gone by ~0.85 m,
		// broken up by broad noise so it reads as grime, not a gradient.
		float contact = smoothstep(0.85, 0.0, world_pos.y);
		ao *= 1.0 - contact * 0.30 * (0.55 + 0.45 * n_broad) * ao_strength;
		// Downward-facing surfaces (soffits, undersides) sit in shade.
		float under = smoothstep(0.15, -0.6, world_normal.y);
		ao *= 1.0 - under * 0.18 * ao_strength;
		base *= ao;
	}

	ALBEDO = base;
	ROUGHNESS = 0.95;
	SPECULAR = 0.35;
}
