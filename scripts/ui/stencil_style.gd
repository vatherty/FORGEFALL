# scripts/ui/stencil_style.gd
# FORGEFALL — shared military/stencil UI theme helpers (Worker 6: HUD/UI).
# Gives every menu and HUD element the same MW2-ish look: near-black panels,
# gunmetal borders, forge-orange accents, uppercase labels with glyph tracking
# on the default font (Barlow Condensed is bundled under the OFL).
# Usage: StencilStyle.panel(), StencilStyle.style_button(my_btn), ...
class_name StencilStyle
extends RefCounted

# Palette (matches VoxelBuilder.PALETTE where it overlaps).
const ORANGE := Color(1.0, 0.482, 0.110)        # ff7b1c forge orange
const ORANGE_DIM := Color(0.55, 0.27, 0.06, 1.0)
const BG := Color(0.025, 0.03, 0.035, 0.48)   # near-black panel
const BG_SOFT := Color(0.025, 0.035, 0.045, 0.56)
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
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	return sb


static func panel_accent() -> StyleBoxFlat:
	return panel(Color.TRANSPARENT, Color.TRANSPARENT, 0)


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
			sb.bg_color = ORANGE
			sb.border_color = ORANGE
			sb.set_border_width_all(2)
		"pressed":
			sb.bg_color = Color("e76c12")
			sb.border_color = ORANGE
			sb.set_border_width_all(2)
		"disabled":
			sb.bg_color = Color(0.05, 0.06, 0.07, 0.9)
			sb.border_color = Color(0.15, 0.16, 0.17, 1.0)
			sb.set_border_width_all(1)
		_:
			sb.bg_color = Color(0.025, 0.03, 0.035, 0.35)
			sb.border_color = GUNMETAL
			sb.set_border_width_all(1)
	return sb


static func style_button(b: Button) -> void:
	b.add_theme_stylebox_override("normal", button_style("normal"))
	b.add_theme_stylebox_override("hover", button_style("hover"))
	b.add_theme_stylebox_override("pressed", button_style("pressed"))
	b.add_theme_stylebox_override("disabled", button_style("disabled"))
	b.add_theme_stylebox_override("focus", panel(Color.TRANSPARENT, ORANGE, 2))
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color("101a23"))
	b.add_theme_color_override("font_pressed_color", Color("101a23"))
	b.add_theme_color_override("font_disabled_color", TEXT_DIM)
	b.add_theme_font_override("font", HEADING_FONT)
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
	fill.content_margin_top = 4.0
	fill.content_margin_bottom = 4.0
	s.add_theme_stylebox_override("slider", bg)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)


# Uppercase + tracked default font: the stencil stand-in.
static func tracking_font(_px_tracking: int = 3) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	fv.spacing_glyph = 0
	return fv


static func apply_title(l: Label, size: int, color: Color = TEXT, _tracking: int = 4) -> void:
	l.add_theme_font_override("font", HEADING_FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 0)
	l.text = l.text.to_upper()


static func apply_body(l: Label, size: int = 20, color: Color = TEXT, tracking: int = 2) -> void:
	l.add_theme_font_override("font", tracking_font(tracking))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 0)


# One menu design system, inherited by rebuilt rows and newly added tabs.
const HEADING_FONT = preload("res://assets/ui/fonts/BarlowCondensed-Bold.ttf")
const CYAN := Color("27d9ef")
const SURFACE := Color(0.025, 0.03, 0.035, 0.66)
const SURFACE_RAISED := Color(0.025, 0.035, 0.045, 0.38)
static var _menu_theme: Theme


static func menu_theme() -> Theme:
	if _menu_theme != null:
		return _menu_theme
	var t := Theme.new()
	t.default_font = ThemeDB.fallback_font
	t.default_font_size = 18
	for type in ["Label", "RichTextLabel", "LineEdit", "TextEdit", "ItemList", "PopupMenu", "CheckBox", "CheckButton"]:
		t.set_color("font_color", type, TEXT)
		t.set_color("font_disabled_color", type, TEXT_DIM)
		t.set_font_size("font_size", type, 18)
	for type in ["Button", "OptionButton", "MenuButton"]:
		t.set_font("font", type, HEADING_FONT)
		t.set_font_size("font_size", type, 24)
		for state in ["normal", "hover", "pressed", "disabled"]:
			t.set_stylebox(state, type, button_style(state))
		t.set_stylebox("focus", type, panel(Color.TRANSPARENT, ORANGE, 2))
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, Color("101a23"))
		t.set_color("font_pressed_color", type, Color("101a23"))
		t.set_color("font_focus_color", type, TEXT)
		t.set_color("font_disabled_color", type, TEXT_DIM)
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, panel(SURFACE, GUNMETAL, 1))
		t.set_stylebox("focus", type, panel(SURFACE, ORANGE, 2))
		t.set_stylebox("read_only", type, panel(SURFACE, GUNMETAL, 1))
		t.set_color("caret_color", type, ORANGE)
		t.set_color("selection_color", type, Color("82451f"))
		t.set_color("font_placeholder_color", type, TEXT_DIM)
	for type in ["TabContainer", "TabBar"]:
		t.set_font("font", type, HEADING_FONT)
		t.set_font_size("font_size", type, 22)
		t.set_color("font_selected_color", type, TEXT)
		t.set_color("font_unselected_color", type, TEXT_DIM)
		t.set_color("font_hovered_color", type, TEXT)
		var active_tab := panel(Color(0.02, 0.025, 0.03, 0.35), ORANGE, 0)
		active_tab.border_width_bottom = 3
		t.set_stylebox("tab_selected", type, active_tab)
		t.set_stylebox("tab_unselected", type, panel(Color.TRANSPARENT, Color.TRANSPARENT, 0))
		t.set_stylebox("tab_hovered", type, panel(SURFACE_RAISED, ORANGE, 1))
		t.set_stylebox("panel", type, panel(Color.TRANSPARENT, Color.TRANSPARENT, 0))
		t.set_constant("side_margin", type, 0)
	t.set_stylebox("panel", "PanelContainer", glass_panel())
	t.set_stylebox("panel", "PopupMenu", panel(Color("141719"), GUNMETAL, 1))
	t.set_stylebox("hover", "PopupMenu", panel(ORANGE, ORANGE, 0))
	t.set_color("font_hover_color", "PopupMenu", Color("101a23"))
	t.set_stylebox("panel", "ItemList", panel(SURFACE, GUNMETAL, 1))
	t.set_stylebox("selected", "ItemList", panel(Color("74401d"), ORANGE, 1))
	t.set_stylebox("selected_focus", "ItemList", panel(Color("74401d"), ORANGE, 2))
	t.set_stylebox("background", "ProgressBar", panel(SURFACE, SURFACE, 0))
	t.set_stylebox("fill", "ProgressBar", panel(ORANGE, ORANGE, 0))
	for type in ["VBoxContainer", "HBoxContainer"]:
		t.set_constant("separation", type, 12)
	t.set_constant("h_separation", "GridContainer", 16)
	t.set_constant("v_separation", "GridContainer", 12)
	_menu_theme = t
	return t


static func install_menu(root: Control) -> void:
	root.theme = menu_theme()
	# Scripts instantiated under Main (a Node) need an initial viewport
	# rect; scenes already carry it through their serialized anchors.
	if root.is_inside_tree() and not root.get_parent() is Control and root.size == Vector2.ZERO:
		root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		root.set_deferred("size", root.get_viewport_rect().size)


static func section_header(parent: Control, title: String, subtitle: String = "") -> VBoxContainer:
	var header := VBoxContainer.new()
	header.name = "SectionHeader"
	header.add_theme_constant_override("separation", 6)
	parent.add_child(header)
	var label := Label.new()
	label.text = title
	apply_title(label, 46, TEXT, 0)
	header.add_child(label)
	if not subtitle.is_empty():
		var description := Label.new()
		description.text = subtitle
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		apply_body(description, 17, TEXT_DIM, 0)
		header.add_child(description)
	return header


static func primary_button(button: Button) -> void:
	style_button(button)
	button.add_theme_stylebox_override("normal", panel(ORANGE, ORANGE, 0))
	button.add_theme_color_override("font_color", Color("101a23"))
	button.add_theme_color_override("font_focus_color", Color("101a23"))


# Gameplay HUD text retains its contrast outline against arbitrary map colors.
static func apply_hud_body(label: Label, size: int = 20, color: Color = TEXT, tracking: int = 2) -> void:
	apply_body(label, size, color, tracking)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 4)


static func eyebrow(parent: Control, section: String) -> Label:
	var label := Label.new()
	label.name = "MenuEyebrow"
	label.text = "FORGEFALL / " + section.to_upper()
	apply_body(label, 13, Color(0.65, 0.65, 0.62), 0)
	parent.add_child(label)
	return label


static func menu_font(base: float, viewport: Vector2) -> int:
	# Keep menu text readable on handhelds; density is handled by scrolling.
	return maxi(mini(int(base), 20), UiScale.scaled_font(base, viewport))


# Atmospheric scenery stays separate from the interactive layout. Images are
# decorative; labels, selections and stats always come from the live game.
static func cinematic_background(root: Control, scene: String = "industrial", darkness: float = 0.12, live_game: bool = false) -> Control:
	var layer := Control.new()
	layer.name = "CinematicBackdrop"
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var host: Node = root
	if root is Container:
		host = root.get_parent()
	host.add_child(layer)
	host.move_child(layer, root.get_index() if root is Container else 0)
	if root is Container:
		layer.visible = root.visible
		var backdrop_ref: WeakRef = weakref(layer)
		root.visibility_changed.connect(func() -> void:
			var backdrop = backdrop_ref.get_ref()
			if is_instance_valid(backdrop):
				backdrop.visible = root.visible)
		root.tree_exiting.connect(layer.queue_free)
	if not live_game:
		var art := TextureRect.new()
		art.name = "SceneArt"
		var path := "res://assets/ui/scenes/" + scene + ".png"
		if not ResourceLoader.exists(path):
			path = "res://assets/ui/industrial_backdrop.png"
		art.texture = load(path)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(art)
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.48, 1.0])
	gradient.colors = PackedColorArray([Color(0.01, 0.015, 0.02, 0.89), Color(0.01, 0.015, 0.02, 0.51), Color(0.01, 0.015, 0.02, darkness)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2.ZERO
	texture.fill_to = Vector2.RIGHT
	var shade := TextureRect.new()
	shade.texture = texture
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(shade)
	return layer


static func navigation_button(button: Button, selected: bool = false) -> void:
	style_button(button)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_stylebox_override("normal", navigation_style(selected))
	button.add_theme_stylebox_override("hover", navigation_style(true))
	button.add_theme_stylebox_override("pressed", navigation_style(true))
	button.add_theme_stylebox_override("focus", panel(Color.TRANSPARENT, ORANGE, 0))
	button.add_theme_color_override("font_color", TEXT if selected else Color("b4b4b0"))
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", TEXT)
	button.add_theme_color_override("font_focus_color", TEXT)
	button.add_theme_font_size_override("font_size", 28)
	# A thin marker remains visible for keyboard/gamepad selection.
	var focus := navigation_style(true)
	focus.bg_color = Color(0.02, 0.025, 0.03, 0.15)
	button.add_theme_stylebox_override("focus", focus)


static func navigation_style(selected: bool) -> StyleBoxFlat:
	var style := panel(Color(0.025, 0.03, 0.035, 0.48 if selected else 0.12), ORANGE, 0)
	style.border_width_left = 4 if selected else 0
	style.content_margin_left = 22
	style.content_margin_right = 20
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style


static func glass_panel() -> StyleBoxFlat:
	return panel(Color(0.025, 0.035, 0.045, 0.46), Color(0.7, 0.7, 0.65, 0.16), 1)
