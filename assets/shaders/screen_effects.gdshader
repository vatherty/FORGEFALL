// Bodycam treatment adapted from cyanone's CC0 "Bodycam footage":
// https://godotshaders.com/shader/bodycam/
// Original credits: zuwiwano (grain), jamesfrize (radial distortion).
// Bounded lens mapping and the other looks are FORGEFALL additions.
shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D screen_image : hint_screen_texture, repeat_disable, filter_linear;
uniform int look = 1;
uniform float strength : hint_range(0.0, 1.0) = 0.65;
uniform float aspect = 1.777778;
uniform bool lens_enabled = true;
uniform bool grain_enabled = true;
uniform bool vignette_enabled = true;
uniform bool chromatic_enabled = false;
uniform bool scanlines_enabled = true;
uniform bool lightweight = true;

float noise(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 center = uv * 2.0 - 1.0;
	float radius_squared = dot(center, center);
	vec3 original = texture(screen_image, uv).rgb;
	vec3 image = original;
	if (look == 1) {
		if (lens_enabled) {
			// Polynomial barrel mapping avoids undefined square roots at the edges.
			uv = 0.5 + center * 0.5 * (1.0 + 0.22 * radius_squared) / 1.12;
			image = texture(screen_image, clamp(uv, vec2(0.001), vec2(0.999))).rgb;
		}
		if (chromatic_enabled && !lightweight) {
			vec2 offset = center * 0.0025 * radius_squared;
			image.r = texture(screen_image, clamp(uv + offset, vec2(0.001), vec2(0.999))).r;
			image.b = texture(screen_image, clamp(uv - offset, vec2(0.001), vec2(0.999))).b;
		}
		float luminance = dot(image, vec3(0.2126, 0.7152, 0.0722));
		image = mix(vec3(luminance), image, 0.82);
		image = (image - 0.5) * 1.10 + 0.5;
		// A defined dark feather outside the lens, never uninitialized color.
		if (lens_enabled) {
			float edge = max(abs(uv.x - 0.5), abs(uv.y - 0.5));
			image *= 1.0 - smoothstep(0.49, 0.525, edge);
		}
	} else if (look == 2) {
		float luminance = dot(image, vec3(0.2126, 0.7152, 0.0722));
		image = mix(vec3(luminance), image, 0.80);
		image = (image - 0.5) * 1.12 + 0.5;
		image += mix(vec3(-0.025, 0.012, 0.026), vec3(0.035, 0.010, -0.025), luminance);
	} else if (look == 3) {
		vec2 grid = vec2(240.0 * aspect, 240.0);
		vec2 pixel_uv = (floor(uv * grid) + 0.5) / grid;
		image = texture(screen_image, pixel_uv).rgb;
		image = floor(image * 15.0 + 0.5) / 15.0;
		if (scanlines_enabled) {
			image *= 0.90 + 0.10 * sin(uv.y * 240.0 * 6.2831853);
		}
	} else if (look == 4) {
		float luminance = dot(image, vec3(0.2126, 0.7152, 0.0722));
		image = vec3((luminance - 0.5) * 1.18 + 0.5);
	} else if (look == 5) {
		// Cosmetic night-vision treatment, no depth or object detection.
		float luminance = dot(image, vec3(0.2126, 0.7152, 0.0722));
		float boosted = pow(max(luminance, 0.0), 0.70);
		image = vec3(0.12, 1.0, 0.24) * boosted;
	}
	if (vignette_enabled) {
		image *= 1.0 - 0.48 * smoothstep(0.30, 1.65, radius_squared);
	}
	if (grain_enabled) {
		float frame = floor(TIME * 24.0);
		float grain = noise(floor(SCREEN_UV / SCREEN_PIXEL_SIZE) + vec2(frame, frame * 0.37)) - 0.5;
		image += grain * 0.035;
	}
	COLOR = vec4(mix(original, clamp(image, vec3(0.0), vec3(1.0)), strength), 1.0);
}
