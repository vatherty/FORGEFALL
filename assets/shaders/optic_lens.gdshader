// FORGEFALL — optic picture-in-picture lens shader (BB-1c ACOG, BB-1d
// generalised to every glass optic: ACOG + reflex/red-dot).
//
// Drawn on the PipScreen quad inside the optic housing
// (Arsenal.build_viewmodel). Two looks in one material:
//
//   pip_strength 0 (hip / lens off): translucent tinted glass, the
//     BB-1b see-through fallback — the carved tunnel stays open and
//     the world shows through at main-camera zoom.
//   pip_strength 1 (ADS): the SubViewport picture (WeaponBase's lens
//     camera) fills the aperture, with a reticle drawn IN THE GLASS
//     and parallax: the image is UV-shifted by eye_offset (the sight
//     axis' misalignment with the eye axis, fed per frame by
//     WeaponBase) while the reticle stays fixed in lens space, and
//     the aperture edges darken ("scope shadow") as the misalignment
//     grows.
//
// Per-family behaviour is all uniforms, set by Arsenal at build time:
//   sample_rect    — centre.xy + size.zw of the lens-texture region
//     the aperture displays. ACOG: the full frame (0.5, 0.5, 1, 1) —
//     its camera runs at main_fov / 1.5, so the full frame IS the
//     extra zoom. Reflex: a small centre crop fed per frame by
//     WeaponBase (its camera runs at main_fov exactly — Colin's
//     no-zoom pin — and the crop is the screen's own angular footprint,
//     so the picture registers 1:1 with the world around the housing:
//     no magnification, pure parallax).
//   reticle_style  — 0 = fine cross + centre dot (ACOG),
//     1 = dot only (reflex — a classic red dot).
//   aperture_shape — 0 = circle (ACOG), 1 = rounded rect (reflex).
//   aperture_aspect — aperture width / height (reticle metrics are
//     computed in height-normalised space so shapes stay round).
//   corner_radius  — rounded-rect corner radius (height units).
//   shadow_strength — scope-shadow depth (ACOG 0.85; the open reflex
//     housings get a subtler 0.45 — the swim is the star there).
//   dot_radius     — reticle dot radius (height units).
//
// With the defaults below the material reproduces the BB-1c ACOG
// lens exactly. lens_tex is a ViewportTexture (linear) — plain
// sampler, no source_color hint, so the picture matches the main
// render.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform sampler2D lens_tex;
uniform float pip_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec2 eye_offset = vec2(0.0);
uniform vec4 glass_tint : source_color = vec4(0.55, 0.62, 0.70, 1.0);
uniform vec4 reticle_color : source_color = vec4(1.0, 0.10, 0.08, 1.0);
uniform vec4 sample_rect = vec4(0.5, 0.5, 1.0, 1.0);
uniform int reticle_style = 0;
uniform int aperture_shape = 0;
uniform float aperture_aspect = 1.0;
uniform float corner_radius = 0.0;
uniform float shadow_strength = 0.85;
uniform float dot_radius = 0.034;

void fragment() {
	vec2 c = UV - 0.5;               // -0.5..0.5 across the quad
	// Height-normalised aperture space: y spans -0.5..0.5 (the full
	// aperture height), x is stretched by the aspect so circles and
	// dots stay round on wide reflex windows.
	vec2 p = vec2(c.x * aperture_aspect, c.y);
	float edge01;                    // 0 centre, 1 at the aperture edge
	if (aperture_shape == 0) {
		float r = length(p) * 2.0;
		if (r > 1.0) {
			discard;                 // circular aperture in a quad
		}
		edge01 = r;
	} else {
		vec2 he = vec2(aperture_aspect, 1.0) * 0.5;
		vec2 q = abs(p) - (he - corner_radius);
		float d = length(max(q, vec2(0.0)))
			+ min(max(q.x, q.y), 0.0) - corner_radius;
		if (d > 0.0) {
			discard;                 // rounded-rect aperture in a quad
		}
		edge01 = clamp(1.0 + d / 0.18, 0.0, 1.0);
	}
	// The family's picture region, swum by the eye misalignment
	// (parallax). ACOG: sample_rect is the full frame, so this is
	// exactly BB-1c's UV + eye_offset.
	vec3 img = texture(lens_tex, sample_rect.xy + c * sample_rect.zw + eye_offset).rgb;
	// Scope shadow: edges close in as the eye drifts off the axis.
	float mis = clamp(length(eye_offset) * 5.0, 0.0, 1.0);
	img *= 1.0 - mis * shadow_strength * smoothstep(0.30, 1.0, edge01);
	// A breath of the lens coating over the picture.
	img = mix(img, img * glass_tint.rgb * 1.7, 0.15);
	// Reticle, fixed in lens space, fades in with the picture.
	float ret = 0.0;
	if (reticle_style == 0) {
		float cross = clamp(
			step(abs(p.x), 0.0075) + step(abs(p.y), 0.0075), 0.0, 1.0)
			* step(length(p) * 2.0, 0.92);
		ret = clamp(cross + step(length(p), dot_radius), 0.0, 1.0);
	} else {
		ret = step(length(p), dot_radius);
	}
	ret *= pip_strength;
	img = mix(img, reticle_color.rgb, ret);
	ALBEDO = mix(glass_tint.rgb, img, pip_strength);
	ALPHA = mix(0.20, 1.0, pip_strength);
}
