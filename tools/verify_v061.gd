# verify_v061.gd — headless checks for FORGEFALL v0.6.1 (resolution-based UI scaling).
# Usage: godot --headless --path <project> --script res://tools/verify_v061.gd
# Covers (Worker A + Worker B work):
#   1. UiScale helper: factor in [0.6, 1.6], exact values at the four
#      target viewports, font floor (>= 10px), margins ~2% of viewport,
#      monotonic growth with resolution, degenerate-input guard.
#   2. Per viewport in [720x1600, 1080x2400, 1440x3200, 1920x1200]:
#      - Forge menu panel rect == viewport minus the 2% scaled margin
#        (cinematic: on wide viewports >= 1100 the panel keeps a 27%
#        right margin so the match/scenery stays visible).
#      - Forge title / tile / prompt sizes follow the cinematic
#        contract (max(32, menu_font(44)) title, fixed 104px tile
#        buttons, menu_font(20) prompt) instead of raw UiScale.
#      - All overlapping HUD elements hidden while the menu is open.
#      - Touch layer hidden while the menu is open.
#      - No menu content clipped: every visible control is within the
#        panel, or inside a ScrollContainer's content (checked per tab,
#        including UNDO LAST + DeepSeek key row reachability in the
#        outer scroll content).
#      - Menu/HUD font + button sizes match UiScale at that viewport.
#      - Close restores HUD + touch (both close paths: HUD-initiated and
#        menu-X-button, the latter via the HUD _process poll).
#   3. Font/button sizes scale monotonically with resolution (bigger
#      viewport -> bigger-or-equal sizes, never smaller).
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# HARNESS NOTE: the project ships with stretch mode "canvas_items" /
# aspect "keep_width" (1280x720 base), which maps every same-aspect
# window to the SAME visible rect — the three portrait phones would
# collapse to one effective viewport. This verifier disables the root
# Window's content scaling (CONTENT_SCALE_MODE_DISABLED) so each
# requested window size becomes the actual visible rect the UI lays
# out against; the UiScale checks are pure functions of the requested
# size either way. Assertions use the ACTUAL visible rect read back
# from the viewport, never the requested size blindly.
extends SceneTree

const TARGETS := [
	Vector2i(720, 1600),
	Vector2i(1080, 2400),
	Vector2i(1440, 3200),
	Vector2i(1920, 1200),
]
# Exact UiScale factors for TARGETS (min(w/1920, h/1080), clamped).
const EXPECTED_FACTORS := [0.6, 0.6, 0.75, 1.0]
const TOL := 2.0

var _fails := 0
var _frames := 0
var _phase := 0
var _res_idx := 0
var _tab_idx := 0
var _tab_count := 0
var _arena: Node = null
# HUD + touch roots are CanvasLayers (layer 10), NOT Controls — typing
# them as Control would silently null them via `as Control`.
var _hud: CanvasLayer = null
var _menu: Control = null
var _touch: CanvasLayer = null
var _pre_visible: Array = []  # [Control, bool] HUD visibility before open
var _pre_touch_visible := false
# Per-resolution samples for the monotonicity checks (index = TARGETS).
var _s_title_font: Array[int] = []
var _s_confirm_h: Array[float] = []
var _s_preset_h: Array[float] = []
var _s_prompt_font: Array[int] = []
var _s_ammo_font: Array[int] = []
var _s_topbar_font: Array[int] = []
var _s_fire_font: Array[int] = []


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _vp_size() -> Vector2:
	return root.get_viewport().get_visible_rect().size


func _initialize() -> void:
	# Disable stretch so each requested size is the real layout viewport.
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = TARGETS[0]
	_arena = Node.new()
	_arena.name = "VerifyArena"
	root.add_child(_arena)
	var hud_ps := load("res://scenes/ui/hud.tscn") as PackedScene
	_hud = hud_ps.instantiate() as CanvasLayer
	_arena.add_child(_hud)
	var menu_ps := load("res://scenes/ui/forge_menu.tscn") as PackedScene
	_menu = menu_ps.instantiate() as Control
	_arena.add_child(_menu)
	var touch_ps := load("res://scenes/ui/touch_controls.tscn") as PackedScene
	_touch = touch_ps.instantiate() as CanvasLayer
	_arena.add_child(_touch)
	# NOTE: do NOT set the touch-device simulation here. In --script
	# mode, _ready() runs on the first frame AFTER _initialize, so any
	# _touch_active/visible set here is overwritten by _ready (which
	# reads the headless no-touchscreen state). The simulation is
	# applied in phase 1, after _ready has run.
	_phase = 1
	print("VERIFY v0.6.1: arena built (HUD + Forge menu + touch layer)")


func _process(_delta: float) -> bool:
	_frames += 1
	# Fail fast instead of looping forever if a scene failed to load.
	if _hud == null or _menu == null or _touch == null:
		_fails += 1
		printerr("FAIL: scene instantiation failed (hud=%s menu=%s touch=%s)"
			% [_hud != null, _menu != null, _touch != null])
		quit(1)
		return true
	match _phase:
		1:
			if _frames < 3:
				return false
			# _ready() has run by now: simulate a touch device so the
			# touch layer's hide/restore checks are non-vacuous.
			# Headless has no touchscreen, so without this the layer
			# starts (and stays) invisible and hiding it proves nothing.
			_touch.set("_touch_active", true)
			_touch.visible = true
			_check_uiscale_pure()
			_phase = 2
			_frames = 0
		2:
			# Re-assert the touch-device sim (idempotent) before the
			# pre-open snapshot, so every resolution starts from it.
			_touch.set("_touch_active", true)
			_touch.visible = true
			# Resize to the current target, let size_changed propagate.
			root.size = TARGETS[_res_idx]
			if _frames < 3:
				return false
			_check(_vp_size() == Vector2(TARGETS[_res_idx]),
				"res %s: actual viewport == requested (got %s)"
				% [TARGETS[_res_idx], _vp_size()])
			# Snapshot pre-open HUD/touch visibility for the restore check.
			_pre_visible.clear()
			for n in (_hud.call("_hud_hide_nodes") as Array):
				_pre_visible.append([n, (n as Control).visible])
			_pre_touch_visible = _touch.visible
			_check(_pre_touch_visible,
				"res %s: touch layer visible before open (touch-device sim)"
				% [TARGETS[_res_idx]])
			_hud.call("_open_forge", true)
			_phase = 3
			_frames = 0
		3:
			if _frames < 3:
				return false
			_check_open_state()
			# Start the per-tab clipping walk on the first tab.
			var tabs = _menu.get("_tabs") as TabContainer
			_tab_count = tabs.get_tab_count() if tabs != null else 0
			_tab_idx = 0
			if tabs != null:
				tabs.current_tab = 0
			_phase = 4
			_frames = 0
		4:
			if _frames < 2:
				return false
			_check_clipping("tab %d" % _tab_idx)
			_tab_idx += 1
			var tabs2 = _menu.get("_tabs") as TabContainer
			if tabs2 != null and _tab_idx < _tab_count:
				tabs2.current_tab = _tab_idx
				_frames = 0
			else:
				_phase = 5
				_frames = 0
		5:
			# Close: even resolutions via the HUD path, odd via the menu's
			# own close() (X-button path) so the HUD _process poll must
			# observe the close and restore everything itself.
			if _res_idx % 2 == 0:
				_hud.call("_open_forge", false)
			else:
				_menu.call("close")
			_phase = 6
			_frames = 0
		6:
			if _frames < 3:
				return false
			_check_close_state()
			_res_idx += 1
			if _res_idx < TARGETS.size():
				_phase = 2
				_frames = 0
			else:
				_phase = 7
				_frames = 0
		7:
			_check_monotonic()
			if _fails == 0:
				print("VERIFY v0.6.1: ALL CHECKS PASSED")
			else:
				printerr("VERIFY v0.6.1: %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


# ------------------------------------------------------------------ UiScale
func _check_uiscale_pure() -> void:
	# Exact factors at the four target viewports.
	for i in TARGETS.size():
		var vp := Vector2(TARGETS[i])
		var f := UiScale.scale_factor(vp)
		_check(is_equal_approx(f, EXPECTED_FACTORS[i]),
			"UiScale: factor at %s == %s (got %s)" % [TARGETS[i], EXPECTED_FACTORS[i], f])
		_check(f >= 0.6 and f <= 1.6,
			"UiScale: factor at %s within [0.6, 1.6] (got %s)" % [TARGETS[i], f])
		_check(UiScale.scaled_font(20.0, vp) >= 10,
			"UiScale: scaled_font(20) at %s >= floor 10 (got %d)"
			% [TARGETS[i], UiScale.scaled_font(20.0, vp)])
		var m := UiScale.panel_margin(vp)
		_check(absf(m.x - vp.x * 0.02) < 0.01 and absf(m.y - vp.y * 0.02) < 0.01,
			"UiScale: panel_margin at %s ~2%% (got %s, want %s)"
			% [TARGETS[i], m, vp * 0.02])
	# Exact scaled fonts pin the formula (not just the range).
	_check(UiScale.scaled_font(20.0, Vector2(720, 1600)) == 12,
		"UiScale: scaled_font(20) at 720x1600 == 12")
	_check(UiScale.scaled_font(20.0, Vector2(1440, 3200)) == 15,
		"UiScale: scaled_font(20) at 1440x3200 == 15")
	_check(UiScale.scaled_font(20.0, Vector2(1920, 1200)) == 20,
		"UiScale: scaled_font(20) at 1920x1200 == 20")
	# Reference + clamps + degenerate guard.
	_check(is_equal_approx(UiScale.scale_factor(Vector2(1920, 1080)), 1.0),
		"UiScale: factor at reference 1920x1080 == 1.0")
	_check(is_equal_approx(UiScale.scale_factor(Vector2(3840, 2160)), 1.6),
		"UiScale: factor clamps to 1.6 at 3840x2160")
	_check(is_equal_approx(UiScale.scale_factor(Vector2(960, 540)), 0.6),
		"UiScale: factor clamps to 0.6 at 960x540")
	_check(is_equal_approx(UiScale.scale_factor(Vector2.ZERO), 1.0),
		"UiScale: degenerate 0x0 viewport returns 1.0")
	_check(UiScale.scaled_font(8.0, Vector2(720, 1600)) >= 10,
		"UiScale: tiny base font still >= floor 10 (got %d)"
		% UiScale.scaled_font(8.0, Vector2(720, 1600)))
	# Monotonicity across a factor-sorted sweep (helper level).
	var sweep := [Vector2(320, 480), Vector2(720, 1600), Vector2(1080, 2400),
		Vector2(1440, 3200), Vector2(1920, 1200), Vector2(2560, 1440),
		Vector2(3840, 2160)]
	var prev_f := -1
	var prev_font := -1
	var prev_size := -1.0
	for vp in sweep:
		var f := UiScale.scale_factor(vp)
		var fo := UiScale.scaled_font(20.0, vp)
		var sz := UiScale.scaled_size(100.0, vp)
		_check(f >= prev_f - 0.001 and fo >= prev_font and sz >= prev_size - 0.001,
			"UiScale: monotonic at %s (factor %s, font %d, size %.1f)"
			% [vp, f, fo, sz])
		prev_f = f
		prev_font = fo
		prev_size = sz


# ------------------------------------------------------------------ open
func _check_open_state() -> void:
	var res: Vector2i = TARGETS[_res_idx]
	var vp := _vp_size()
	var tag := "res %s" % res
	_check(_menu.visible, "%s: Forge menu visible after open" % tag)
	# Panel rect == viewport minus 2% margin on each side.
	var panel := _menu.get("_panel") as PanelContainer
	if panel == null:
		_check(false, "%s: menu _panel exists" % tag)
		return
	var m := UiScale.panel_margin(vp)
	# Cinematic Forge: narrow viewports keep the 2% full-screen
	# margins; wide viewports (>= 1100) keep a 27% right margin.
	var right := maxf(m.x, vp.x * 0.27) if vp.x >= 1100 else m.x
	var want := Rect2(m.x, m.y, vp.x - m.x - right, vp.y - 2.0 * m.y)
	var got := panel.get_global_rect()
	_check(absf(got.position.x - want.position.x) <= TOL
			and absf(got.position.y - want.position.y) <= TOL
			and absf(got.size.x - want.size.x) <= TOL
			and absf(got.size.y - want.size.y) <= TOL,
		"%s: panel rect == viewport - 2%% margin (got %s, want %s)"
		% [tag, got, want])
	# All overlapping HUD elements hidden.
	var hidden_count := 0
	var pre_visible_count := 0
	for entry in _pre_visible:
		var n: Control = entry[0]
		if bool(entry[1]):
			pre_visible_count += 1
		if not n.visible:
			hidden_count += 1
	_check(pre_visible_count >= 3,
		"%s: hide check non-vacuous (%d HUD nodes visible pre-open)"
		% [tag, pre_visible_count])
	_check(hidden_count == _pre_visible.size(),
		"%s: ALL %d HUD hide-nodes hidden while menu open (%d hidden)"
		% [tag, _pre_visible.size(), hidden_count])
	# Touch layer hidden while the menu is open.
	_check(not _touch.visible,
		"%s: touch layer hidden while menu open" % tag)
	# Menu/HUD sizes match UiScale at this viewport.
	var title := _menu.get("_title_label") as Label
	# Cinematic Forge title: max(32, menu_font(44)) — large display
	# type with a readability floor, not UiScale(26).
	var want_title := maxi(32, StencilStyle.menu_font(44.0, vp))
	_check(title != null and title.get_theme_font_size("font_size")
			== want_title,
		"%s: menu title font == cinematic max(32, menu_font(44)) = %d (got %d)" % [tag,
			want_title,
			title.get_theme_font_size("font_size") if title != null else -1])
	var confirm := _menu.get("_confirm_button") as Button
	_check(confirm != null and absf(confirm.custom_minimum_size.y
			- UiScale.scaled_size(56.0, vp)) <= 1.0,
		"%s: FORGE IT min height == UiScale(56) = %.1f (got %.1f)" % [tag,
			UiScale.scaled_size(56.0, vp),
			confirm.custom_minimum_size.y if confirm != null else -1.0])
	var preset := (_menu.get("_menu_buttons") as Array)[0] as Button
	# Cinematic Forge: tile preset buttons are fixed 104px tiles;
	# non-tile preset buttons keep the UiScale(64) height.
	var want_preset := 104.0 if preset != null and preset.has_meta("forge_tile") else UiScale.scaled_size(64.0, vp)
	_check(preset != null and absf(preset.custom_minimum_size.y
			- want_preset) <= 1.0,
		"%s: preset button min height == %.1f (got %.1f)" % [tag,
			want_preset,
			preset.custom_minimum_size.y if preset != null else -1.0])
	var prompt := _menu.get("_prompt_input") as LineEdit
	# Cinematic Forge prompt: StencilStyle.menu_font(20) — a 20px
	# readability floor — not raw UiScale(20).
	var want_prompt := StencilStyle.menu_font(20.0, vp)
	_check(prompt != null and prompt.get_theme_font_size("font_size")
			== want_prompt,
		"%s: prompt input font == menu_font(20) = %d" % [tag,
			want_prompt])
	var ammo := _hud.get("_ammo_label") as Label
	_check(ammo != null and ammo.get_theme_font_size("font_size")
			== UiScale.scaled_font(56.0, vp),
		"%s: HUD ammo font == UiScale(56) = %d (got %d)" % [tag,
			UiScale.scaled_font(56.0, vp),
			ammo.get_theme_font_size("font_size") if ammo != null else -1])
	var topbar := _hud.get("_topbar") as Label
	_check(topbar != null and topbar.get_theme_font_size("font_size")
			== UiScale.scaled_font(26.0, vp),
		"%s: HUD topbar font == UiScale(26) = %d" % [tag,
			UiScale.scaled_font(26.0, vp)])
	# Touch FIRE button: at/above the UiScale 48px floor (the layout may
	# shrink below the raw factor to avoid overlap, but never below floor).
	var fire := _touch_button("fire")
	if fire != null:
		var floor_px := UiScale.scaled_size(48.0, vp)
		_check(fire.size.x >= floor_px - 0.01 and fire.size.y >= floor_px - 0.01,
			"%s: touch FIRE size %s >= UiScale floor %.1f" % [tag, fire.size, floor_px])
		_check(fire.get_theme_font_size("font_size")
				== UiScale.scaled_font(24.0, vp),
			"%s: touch FIRE font == UiScale(24) = %d" % [tag,
				UiScale.scaled_font(24.0, vp)])
	else:
		_check(false, "%s: touch FIRE button found" % tag)
	# Record samples for the cross-resolution monotonicity checks.
	_s_title_font.append(title.get_theme_font_size("font_size"))
	_s_confirm_h.append(confirm.custom_minimum_size.y)
	_s_preset_h.append(preset.custom_minimum_size.y)
	_s_prompt_font.append(prompt.get_theme_font_size("font_size"))
	_s_ammo_font.append(ammo.get_theme_font_size("font_size"))
	_s_topbar_font.append(topbar.get_theme_font_size("font_size"))
	_s_fire_font.append(fire.get_theme_font_size("font_size")
		if fire != null else -1)
	# Bottom rows live inside the outer scroll content (reachability).
	_check_scroll_reachable(tag)


func _touch_button(id: String) -> Button:
	for d in (_touch.get("_btn_defs") as Array):
		if str((d as Dictionary).get("id", "")) == id:
			return (d as Dictionary).get("btn") as Button
	return null


func _check_scroll_reachable(tag: String) -> void:
	# The outer ContentScroll is the first ScrollContainer under Root;
	# its content VBox must contain UNDO LAST + the DeepSeek key row, and
	# scrolling to max must bring UNDO LAST fully into the viewport.
	var panel := _menu.get("_panel") as PanelContainer
	var content_scroll: ScrollContainer = null
	var content_box: VBoxContainer = null
	for c in panel.get_children():
		if c is VBoxContainer:  # Root box
			for cc in (c as VBoxContainer).get_children():
				if cc is ScrollContainer and content_scroll == null:
					content_scroll = cc as ScrollContainer
	if content_scroll == null:
		_check(false, "%s: outer ContentScroll exists" % tag)
		return
	if content_scroll.get_child_count() > 0:
		content_box = content_scroll.get_child(0) as VBoxContainer
	if content_box == null:
		_check(false, "%s: scroll content VBox exists" % tag)
		return
	var undo := _menu.get("_undo_button") as Button
	var key_row := _menu.get("_key_row") as HBoxContainer
	var box_rect := content_box.get_global_rect()
	# Tolerant containment: a ScrollContainer sizes its content from the
	# child's cached minimum size, which can lag _apply_scale by a
	# fraction of a pixel (observed 0.4px on tab grids) — that is not
	# user-visible clipping, so exact Rect2.encloses is too strict.
	_check(undo != null and _rect_within(undo.get_global_rect(), box_rect, TOL),
		"%s: UNDO LAST inside scroll content (undo %s, content %s)"
		% [tag, undo.get_global_rect() if undo != null else Rect2(),
			box_rect])
	_check(key_row != null and _rect_within(key_row.get_global_rect(), box_rect, TOL),
		"%s: DeepSeek key row inside scroll content" % tag)
	var scroll_rect := content_scroll.get_global_rect()
	var max_scroll := _effective_max_scroll(content_scroll)
	var undo_bottom := undo.get_global_rect().end.y
	_check(undo_bottom - max_scroll <= scroll_rect.end.y + TOL,
		"%s: UNDO LAST reachable at max scroll (bottom %.1f - max %.1f <= viewport bottom %.1f)"
		% [tag, undo_bottom, max_scroll, scroll_rect.end.y])


# ------------------------------------------------------------------ clipping
## Tolerant rect containment (see _check_scroll_reachable note).
func _rect_within(inner: Rect2, outer: Rect2, tol: float) -> bool:
	return inner.position.x >= outer.position.x - tol \
		and inner.end.x <= outer.end.x + tol \
		and inner.position.y >= outer.position.y - tol \
		and inner.end.y <= outer.end.y + tol


## ScrollContainer's real scroll range: Godot sets the scrollbar's
## max_value to the CONTENT size and page to the viewport size, so the
## offset itself clamps to [0, max - page] — using max_value raw would
## overstate reachability.
func _effective_max_scroll(scroll: ScrollContainer) -> float:
	var bar := scroll.get_v_scroll_bar()
	return maxf(0.0, bar.max_value - bar.page)


func _collect_controls(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Control:
			out.append(c)
		_collect_controls(c, out)


func _nearest_scroll(c: Control) -> ScrollContainer:
	var p := c.get_parent()
	while p != null:
		if p is ScrollContainer:
			return p as ScrollContainer
		p = p.get_parent()
	return null


func _check_clipping(label: String) -> void:
	var res: Vector2i = TARGETS[_res_idx]
	var tag := "res %s %s" % [res, label]
	var panel := _menu.get("_panel") as PanelContainer
	if panel == null:
		_check(false, "%s: panel exists for clipping" % tag)
		return
	var panel_rect := panel.get_global_rect()
	var controls: Array = []
	_collect_controls(panel, controls)
	var checked := 0
	for c in controls:
		var ctl := c as Control
		if not ctl.is_visible_in_tree():
			continue
		var r := ctl.get_global_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		checked += 1
		# Horizontal: scroll is disabled everywhere, so nothing may
		# overflow the panel sideways, scrolled or not.
		_check(r.position.x >= panel_rect.position.x - TOL
				and r.end.x <= panel_rect.end.x + TOL,
			"%s: %s within panel horizontally (rect %s, panel %s)"
			% [tag, ctl.name, r, panel_rect])
		var scroll := _nearest_scroll(ctl)
		if scroll == null:
			_check(r.position.y >= panel_rect.position.y - TOL
					and r.end.y <= panel_rect.end.y + TOL,
				"%s: %s within panel (rect %s, panel %s)"
				% [tag, ctl.name, r, panel_rect])
		else:
			# Inside a scrolling area: the user-visible requirement is
			# REACHABILITY, not exact containment in the content rect
			# (whose height comes from a cached minimum size and can lag
			# the laid-out children by a fraction of a pixel). The
			# control must start at/after the content top and be
			# scrollable fully into the scroll viewport.
			var content := scroll.get_child(0) as Control
			if content == null:
				_check(false, "%s: scroll %s has content" % [tag, scroll.name])
				continue
			var cr := content.get_global_rect()
			var max_scroll := _effective_max_scroll(scroll)
			var vp_rect := scroll.get_global_rect()
			_check(r.position.y >= cr.position.y - TOL
					and r.end.y - max_scroll <= vp_rect.end.y + TOL,
				"%s: %s reachable in scroll %s (rect %s, content top %.1f, max scroll %.1f, viewport bottom %.1f)"
				% [tag, ctl.name, scroll.name, r, cr.position.y,
					max_scroll, vp_rect.end.y])
	# Non-vacuous: each tab shows a grid of preset buttons + prompt rows.
	_check(checked >= 10,
		"%s: clipping walk checked %d visible controls" % [tag, checked])


# ------------------------------------------------------------------ close
func _check_close_state() -> void:
	var res: Vector2i = TARGETS[_res_idx]
	var path := "HUD _open_forge(false)" if _res_idx % 2 == 0 else "menu.close() + HUD poll"
	var tag := "res %s close via %s" % [res, path]
	_check(not _menu.visible, "%s: menu hidden after close" % tag)
	var restored := 0
	for entry in _pre_visible:
		var n: Control = entry[0]
		if n.visible == bool(entry[1]):
			restored += 1
	_check(restored == _pre_visible.size(),
		"%s: ALL %d HUD nodes restored (%d match pre-open)"
		% [tag, _pre_visible.size(), restored])
	_check(_touch.visible == _pre_touch_visible,
		"%s: touch layer restored (visible=%s, pre-open=%s)"
		% [tag, _touch.visible, _pre_touch_visible])


# ------------------------------------------------------------------ monotonic
func _check_mono_int(name: String, samples: Array[int]) -> void:
	for i in range(1, samples.size()):
		_check(samples[i] >= samples[i - 1],
			"monotonic: %s %s at %s >= %s at %s (samples %s)"
			% [name, samples[i], TARGETS[i], samples[i - 1], TARGETS[i - 1], samples])



func _check_mono_float(name: String, samples: Array[float]) -> void:
	for i in range(1, samples.size()):
		_check(samples[i] >= samples[i - 1] - 0.01,
			"monotonic: %s %.1f at %s >= %.1f at %s (samples %s)"
			% [name, samples[i], TARGETS[i], samples[i - 1], TARGETS[i - 1], samples])


func _check_monotonic() -> void:
	_check_mono_int("menu title font", _s_title_font)
	_check_mono_float("FORGE IT min height", _s_confirm_h)
	_check_mono_float("preset button min height", _s_preset_h)
	_check_mono_int("prompt input font", _s_prompt_font)
	_check_mono_int("HUD ammo font", _s_ammo_font)
	_check_mono_int("HUD topbar font", _s_topbar_font)
	_check_mono_int("touch FIRE font", _s_fire_font)
	# Endpoints must actually grow: smallest viewport < largest.
	_check(_s_title_font[3] > _s_title_font[0],
		"monotonic: title font grows 720x1600 (%d) -> 1920x1200 (%d)"
		% [_s_title_font[0], _s_title_font[3]])
	_check(_s_ammo_font[3] > _s_ammo_font[0],
		"monotonic: HUD ammo font grows 720x1600 (%d) -> 1920x1200 (%d)"
		% [_s_ammo_font[0], _s_ammo_font[3]])
