# scripts/ui/ui_scale.gd
# FORGEFALL — viewport-relative UI scaling (v0.6.1).
# Pure static functions of viewport size so tests can call them at any
# resolution without a scene tree. Reference layout size is 1920x1080
# (the size the menus were originally laid out against); the factor is
# clamped so small phones stay legible and large tablets don't explode.
class_name UiScale
extends RefCounted

const REFERENCE_SIZE := Vector2(1920.0, 1080.0)
const MIN_SCALE := 0.6
const MAX_SCALE := 1.6
const PANEL_MARGIN_FRAC := 0.02


## Scale factor for the given viewport size: min(w/1920, h/1080),
## clamped to [0.6, 1.6]. Uses min (not max) so the layout fits BOTH
## axes — a wide-but-short phone screen scales by its height.
static func scale_factor(viewport_size: Vector2) -> float:
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return 1.0
	var f := minf(viewport_size.x / REFERENCE_SIZE.x, viewport_size.y / REFERENCE_SIZE.y)
	return clampf(f, MIN_SCALE, MAX_SCALE)


## Scaled font size: base * factor, rounded, never below 10px.
static func scaled_font(base: float, viewport_size: Vector2) -> int:
	return maxi(10, int(round(base * scale_factor(viewport_size))))


## Scaled pixel size for min-sizes, margins, and separations.
static func scaled_size(base: float, viewport_size: Vector2) -> float:
	return base * scale_factor(viewport_size)


## Full-screen-modal margin: ~2% of the viewport on each side.
static func panel_margin(viewport_size: Vector2) -> Vector2:
	return Vector2(viewport_size.x * PANEL_MARGIN_FRAC, viewport_size.y * PANEL_MARGIN_FRAC)
