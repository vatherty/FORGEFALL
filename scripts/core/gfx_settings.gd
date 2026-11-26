# scripts/core/gfx_settings.gd
# FORGEFALL — BB-9 graphics push: quality tier + per-feature flags.
#
# Colin's order: "Add all of them [shadows, colour grading, glow, grit,
# AO, decals, MSAA], but make sure to test fps performance once everything
# is added, then take off major changes that cause major fps drops, goal
# is 60-30fps." Every feature therefore sits behind its OWN flag so its
# cost can be measured and it can be dropped without touching the others.
#
# Resolution order for every feature (first hit wins):
#   1. Command-line user args (after `--`): --gfx-tier=low|high,
#      --gfx-shadows=0|1, --gfx-grading=0|1, --gfx-glow=0|1,
#      --gfx-grit=0|1, --gfx-ao=0|1, --gfx-decals=0|1, --gfx-msaa=0|1
#      (this is what tools/bench_fps.gd uses to flip one feature at a time)
#   2. Preferences keys in user://forge_settings.cfg [ui]:
#      gfx_tier (0 = Low, 1 = High) and per-feature gfx_<name>:
#      -1 = follow tier, 0 = force off, 1 = force on.
#   3. Tier default: Low = every feature OFF (today's exact look — the
#      phone-safe shipping default), High = every feature ON.
#
# This class reads the cfg file directly instead of the Preferences
# autoload so it resolves identically in-game, in headless verifies and
# in the bench tool, with no autoload ordering assumptions.
#
# Also home of the per-map colour grades (BB-9 item 3): grade parameters
# per sky profile + a runtime-built 32^3 LUT (ImageTexture3D). The LUTs
# are generated procedurally from GRADES below; tools/gen_luts.gd is the
# generator/preview script of record (it renders strip-PNG previews of
# exactly these LUTs). Runtime generation is the shipping path: the
# PackedByteArray ImageTexture3D.create() upload path is broken in this
# engine build (see lut_texture), and 32^3 texels cost ~a millisecond
# to build at map load anyway.
class_name GfxSettings
extends RefCounted

const FEATURES := ["shadows", "grading", "glow", "grit", "ao", "decals", "msaa"]
const CFG_PATH := "user://forge_settings.cfg"
const LUT_SIZE := 32

# Per-sky-profile colour grade. gain = per-channel multiplier (temperature
# / tint), lift = black-point shift, saturation and contrast are the
# classic mix/pivot ops. All deliberately MILD: the photo skies already
# carry the mood; the grade unifies the rendered world with the sky.
const GRADES := {
	"dustline": {"gain": Color(1.04, 1.00, 0.92), "lift": 0.0, "saturation": 1.05, "contrast": 1.03},
	"cinder_city": {"gain": Color(1.06, 0.98, 0.88), "lift": 0.0, "saturation": 1.12, "contrast": 1.06},
	"factory": {"gain": Color(0.96, 1.00, 1.04), "lift": 0.0, "saturation": 0.95, "contrast": 1.05},
	"foundry": {"gain": Color(1.07, 0.97, 0.86), "lift": 0.0, "saturation": 1.05, "contrast": 1.05},
	"outpost": {"gain": Color(1.00, 1.00, 1.00), "lift": 0.0, "saturation": 1.08, "contrast": 1.04},
	"tower_defense": {"gain": Color(1.05, 0.99, 0.90), "lift": 0.0, "saturation": 1.08, "contrast": 1.04},
	"zombies_night": {"gain": Color(0.88, 0.97, 1.12), "lift": 0.0, "saturation": 0.82, "contrast": 1.08},
}

static var _args: Dictionary = {}
static var _args_done := false
static var _cfg: Dictionary = {}
static var _cfg_done := false
static var _lut_cache: Dictionary = {}


static func _parse_args() -> void:
	if _args_done:
		return
	_args_done = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--gfx-"):
			var body := a.trim_prefix("--gfx-")
			var eq := body.find("=")
			if eq > 0:
				_args[body.substr(0, eq)] = body.substr(eq + 1)


static func _load_cfg() -> void:
	if _cfg_done:
		return
	_cfg_done = true
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		for key in cfg.get_section_keys("ui") if cfg.has_section("ui") else []:
			_cfg[key] = cfg.get_value("ui", key)


static func tier_high() -> bool:
	_parse_args()
	if _args.has("tier"):
		return str(_args["tier"]).to_lower() == "high"
	_load_cfg()
	return int(_cfg.get("gfx_tier", 0)) == 1


static func feature(name: String) -> bool:
	_parse_args()
	if _args.has(name):
		return str(_args[name]) not in ["0", "off", "false"]
	_load_cfg()
	var override := int(_cfg.get("gfx_" + name, -1))
	if override == 0:
		return false
	if override == 1:
		return true
	return tier_high()


## One-line state dump for benches/verifies: "tier=high shadows=1 ..."
static func describe() -> String:
	var parts := ["tier=" + ("high" if tier_high() else "low")]
	for f in FEATURES:
		parts.append("%s=%d" % [f, 1 if feature(f) else 0])
	return " ".join(parts)


## Root-viewport MSAA (BB-9 item 8). Called by Preferences.apply() at
## startup and explicitly by the bench/capture tools.
static func apply_msaa(viewport: Viewport) -> void:
	if viewport == null:
		return
	viewport.msaa_3d = Viewport.MSAA_4X if feature("msaa") else Viewport.MSAA_DISABLED


# ------------------------------------------------------------ LUT build

static func grade_for(profile_name: String) -> Dictionary:
	return GRADES.get(profile_name, GRADES["dustline"])


static func grade_color(grade: Dictionary, c: Color) -> Color:
	var gain: Color = grade["gain"]
	var out := Color(
		clampf(c.r * gain.r + float(grade["lift"]), 0.0, 1.0),
		clampf(c.g * gain.g + float(grade["lift"]), 0.0, 1.0),
		clampf(c.b * gain.b + float(grade["lift"]), 0.0, 1.0))
	var contrast := float(grade["contrast"])
	out = Color(
		clampf((out.r - 0.5) * contrast + 0.5, 0.0, 1.0),
		clampf((out.g - 0.5) * contrast + 0.5, 0.0, 1.0),
		clampf((out.b - 0.5) * contrast + 0.5, 0.0, 1.0))
	var luma := out.r * 0.2126 + out.g * 0.7152 + out.b * 0.0722
	var sat := float(grade["saturation"])
	return Color(
		clampf(luma + (out.r - luma) * sat, 0.0, 1.0),
		clampf(luma + (out.g - luma) * sat, 0.0, 1.0),
		clampf(luma + (out.b - luma) * sat, 0.0, 1.0))


## Build (and cache) the 32^3 adjustment LUT for a sky profile.
## NOTE: built from slice Images via _set_images() — the same path the
## resource loader uses. The PackedByteArray create() path was proven
## broken in this engine build (texture RID never initialises:
## "p_data.is_empty()" / "texture is null", and the adjustment pass
## then samples black — the whole frame goes black). Verified by probe:
## slice-built identity LUT renders pixel-identical to adjustment off.
static func lut_texture(profile_name: String) -> Texture3D:
	if _lut_cache.has(profile_name):
		return _lut_cache[profile_name]
	var grade := grade_for(profile_name)
	var n := LUT_SIZE
	var images: Array = []
	for b in n:
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		for g in n:
			for r in n:
				img.set_pixel(r, g, grade_color(grade, Color(
					float(r) / float(n - 1), float(g) / float(n - 1), float(b) / float(n - 1))))
		images.append(img)
	var tex := ImageTexture3D.new()
	tex._set_images(images)
	_lut_cache[profile_name] = tex
	return tex
