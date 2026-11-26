// FORGEFALL — BB-1c ACOG picture-in-picture lens shader.
//
// Drawn on the AcogPipScreen disc inside the BR-3's ACOG housing
// (Arsenal.build_viewmodel). Two looks in one material:
//
//   pip_strength 0 (hip / lens off): translucent tinted glass, the
//     BB-1b see-through fallback — the carved tunnel stays open and
//     the world shows through at main-camera zoom.
//   pip_strength 1 (ADS): the SubViewport picture (WeaponBase's lens
//     camera: main camera transform, fov = main fov / 1.5) fills the
//     disc, with a reticle drawn IN THE GLASS and parallax: the image
//     is UV-shifted by eye_offset (the sight axis' misalignment with
//     the eye axis, fed per frame by WeaponBase) while the reticle
//     stays fixed in lens space, and the aperture edges darken
//     ("scope shadow") as the misalignment grows.
//
// lens_tex is a ViewportTexture (linear) — plain sampler, no
// source_color hint, so the picture matches the main render.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform sampler2D lens_tex;
uniform float pip_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec2 eye_offset = vec2(0.0);
uniform vec4 glass_tint : source_color = vec4(0.55, 0.62, 0.70, 1.0);
uniform vec4 reticle_color : source_color = vec4(1.0, 0.10, 0.08, 1.0);

void fragment() {
	vec2 c = UV - 0.5;               // -0.5..0.5 across the quad
	float r = length(c) * 2.0;       // 0 centre, 1 at the disc edge
	if (r > 1.0) {
		discard;                     // circular aperture in a quad
	}
	// Magnified picture, swum by the eye misalignment (parallax).
	vec3 img = texture(lens_tex, UV + eye_offset).rgb;
	// Scope shadow: edges close in as the eye drifts off the axis.
	float mis = clamp(length(eye_offset) * 5.0, 0.0, 1.0);
	img *= 1.0 - mis * 0.85 * smoothstep(0.30, 1.0, r);
	// A breath of the lens coating over the picture.
	img = mix(img, img * glass_tint.rgb * 1.7, 0.15);
	// Reticle: fine cross + centre dot, fixed in lens space, fades in
	// with the picture. Half-widths are in UV units (512px texture:
	// 0.0075 half-width ~ a 4px line).
	float cross = clamp(
		step(abs(c.x), 0.0075) + step(abs(c.y), 0.0075), 0.0, 1.0)
		* step(r, 0.92);
	float dot = step(length(c), 0.034);
	float ret = clamp(cross + dot, 0.0, 1.0) * pip_strength;
	img = mix(img, reticle_color.rgb, ret);
	ALBEDO = mix(glass_tint.rgb, img, pip_strength);
	ALPHA = mix(0.20, 1.0, pip_strength);
}
