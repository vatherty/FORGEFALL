# scripts/ui/stencil_style.gd
# FORGEFALL — shared military/stencil UI theme helpers (Worker 6: HUD/UI).
# Gives every menu and HUD element the same MW2-ish look: near-black panels,
# gunmetal borders, forge-orange accents, uppercase labels with glyph tracking
# on the default font (a real stencil font is a Colin-side asset drop-in).
# Usage: StencilStyle.panel(), StencilStyle.style_button(my_btn), ...
class_name StencilStyle
extends RefCounted

# Palette (matches VoxelBuilder.PALETTE where it overlaps).
const ORANGE := Color(1.0, 0.482, 0.110)        # ff7b1c forge orange
const ORANGE_DIM := Color(0.55, 0.27, 0.06, 1.0)
const BG := Color(0.035, 0.045, 0.055, 0.94)   # near-black panel
const BG_SOFT := Color(0.06, 0.075, 0.09, 0.88)
const GUNMETAL := Color(0.23, 0.25, 0.27, 1.0) # 3a3f44-ish
const TEXT := Color(0.93, 0.94, 0.95, 1.0)
const TEXT_DIM := Color(0.62, 0.65, 0.68, 1.0)
const RED := Color(0.85, 0.12, 0.10, 1.0)
const GREEN := Color(0.25, 0.85, 0.35, 1.0)
const GOLD := Color(1.0, 0.75, 0.15, 1.0)   # headshot hitmarker / highlights
const BLOOD := Color(0.55, 0.04, 0.03, 1.0)


static func panel(bg: Color = BG, border: Color = GUNMETAL, bw: int = 2) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	return sb


static func panel_accent() -> StyleBoxFlat:
	return panel(BG, ORANGE, 2)


static func chip() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.14, 0.95)
	sb.border_color = ORANGE_DIM
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


# Killstreak pip panel: ready = warm orange-tinted + orange border,
# locked = dark + gunmetal border. Single source of truth for the HUD pips.
static func pip_style(ready: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	if ready:
		sb.bg_color = Color(0.16, 0.10, 0.04, 0.95)
		sb.border_color = ORANGE
		sb.set_border_width_all(2)
	else:
		sb.bg_color = Color(0.03, 0.04, 0.05, 0.75)
		sb.border_color = Color(0.16, 0.18, 0.20, 1.0)
		sb.set_border_width_all(1)
	return sb


# Hitmarker color by variant: "hit" white, "headshot" gold, "kill" red.
static func hitmarker_color(kind: String) -> Color:
	match kind:
		"headshot":
			return GOLD
		"kill":
			return RED
		_:
			return Color(1, 1, 1, 0.95)


# Health bar / numeric color by remaining fraction.
static func health_color(frac: float) -> Color:
	if frac < 0.30:
		return RED
	if frac < 0.50:
		return ORANGE
	return GREEN


static func button_style(kind: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	match kind:
		"hover":
			sb.bg_color = Color(0.14, 0.16, 0.18, 1.0)
			sb.border_color = ORANGE
			sb.set_border_width_all(2)
		"pressed":
			sb.bg_color = Color(0.30, 0.16, 0.05, 1.0)
			sb.border_color = ORANGE
			sb.set_border_width_all(2)
		"disabled":
			sb.bg_color = Color(0.05, 0.06, 0.07, 0.9)
			sb.border_color = Color(0.15, 0.16, 0.17, 1.0)
			sb.set_border_width_all(1)
		_:
			sb.bg_color = Color(0.08, 0.10, 0.12, 1.0)
			sb.border_color = GUNMETAL
			sb.set_border_width_all(2)
	return sb


static func style_button(b: Button) -> void:
	b.add_theme_stylebox_override("normal", button_style("normal"))
	b.add_theme_stylebox_override("hover", button_style("hover"))
	b.add_theme_stylebox_override("pressed", button_style("pressed"))
	b.add_theme_stylebox_override("disabled", button_style("disabled"))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", ORANGE)
	b.add_theme_color_override("font_pressed_color", TEXT)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM)
	b.add_theme_font_override("font", tracking_font(2))
	b.add_theme_font_size_override("font_size", 22)


static func style_lineedit(le: LineEdit) -> void:
	le.add_theme_stylebox_override("normal", panel(BG_SOFT, GUNMETAL, 1))
	le.add_theme_stylebox_override("focus", panel(BG_SOFT, ORANGE, 2))
	le.add_theme_stylebox_override("read_only", panel(BG_SOFT, GUNMETAL, 1))
	le.add_theme_color_override("font_color", TEXT)
	le.add_theme_color_override("font_placeholder_color", TEXT_DIM)
	le.add_theme_color_override("caret_color", ORANGE)
	le.add_theme_font_size_override("font_size", 20)


static func style_slider(s: HSlider) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.10, 0.12, 0.14, 1.0)
	bg.set_corner_radius_all(2)
	bg.content_margin_top = 4.0
	bg.content_margin_bottom = 4.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = ORANGE_DIM
	fill.set_corner_radius_all(2)
	s.add_theme_stylebox_override("background", bg)
	s.add_theme_stylebox_override("slider", fill)


# Uppercase + tracked default font: the stencil stand-in.
static func tracking_font(px_tracking: int = 3) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	fv.spacing_glyph = px_tracking
	return fv


static func apply_title(l: Label, size: int, color: Color = TEXT, tracking: int = 4) -> void:
	l.add_theme_font_override("font", tracking_font(tracking))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", maxi(2, size / 16))
	l.text = l.text.to_upper()


static func apply_body(l: Label, size: int = 20, color: Color = TEXT, tracking: int = 2) -> void:
	l.add_theme_font_override("font", tracking_font(tracking))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
