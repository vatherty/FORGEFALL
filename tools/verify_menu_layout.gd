# verify_menu_layout.gd — main-menu layout verifier (Deck screenshot fix).
# Instantiates scenes/ui/main_menu.tscn at 4 resolutions and asserts:
#  - tagline rect does not intersect the MAP row (vertical order, no
#    shared space). The legacy MODE row is gone (Gameplay Rework:
#    SINGLE PLAYER / MULTIPLAYER top entries + mode-select overlay).
#  - no two visible text controls overlap (within the menu stack, and
#    separately within the options panel when open — the panel is an
#    overlay, so cross-group pairs are excluded by design)
#  - every button label renders exactly once; no COMING SOON remains;
#    LOADOUTS and STATS buttons exist (Goal 6 progression)
#  - all visible buttons + footer are fully inside the viewport
#  - OPTIONS panel fits the viewport and its controls don't overlap
# Also exercises the resize path (build at 1280x800, resize to 1920x1080).
# Usage: godot --headless --path <proj> --script res://tools/verify_menu_layout.gd
extends SceneTree

var _pass := 0
var _fail := 0
var _frame := 0
var _phase := "build"
var _menu: Control = null
var _sizes := [Vector2(1280, 800), Vector2(1920, 1080), Vector2(1080, 2400), Vector2(720, 1600)]
var _size_idx := 0
var _size := Vector2.ZERO
var _resize_done := false


func _check(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("MENUVERIFY PASS: ", name)
	else:
		_fail += 1
		printerr("MENUVERIFY FAIL: ", name)


func _build_menu(sz: Vector2) -> void:
	if _menu != null and is_instance_valid(_menu):
		_menu.queue_free()
	_menu = (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate()
	root.add_child(_menu)
	# Pin the menu to the test size: _ready() anchors it FULL_RECT, which
	# headless resolves against the dummy root viewport — so re-anchor to
	# TOP_LEFT (keeping the rect) and then set the size explicitly.
	_menu.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	_menu.position = Vector2.ZERO
	_menu.size = sz
	_size = sz


func _is_effectively_visible(c: Control) -> bool:
	return c.is_visible_in_tree()


func _text_of(c: Control) -> String:
	if c is Label:
		return (c as Label).text
	if c is Button:
		return (c as Button).text
	if c is OptionButton:
		var ob := c as OptionButton
		return ob.get_item_text(ob.selected) if ob.item_count > 0 else ""
	if c is CheckButton:
		return (c as CheckButton).text
	return ""


## Visible, non-empty text controls under `root_node`.
func _leaves(root_node: Node, out: Array[Control]) -> void:
	if root_node is Control and not (root_node as Control).is_visible_in_tree():
		return
	if root_node is Label or root_node is Button or root_node is OptionButton or root_node is CheckButton:
		var c := root_node as Control
		if not _text_of(c).is_empty():
			out.append(c)
		return
	for ch in root_node.get_children():
		_leaves(ch, out)


func _check_no_overlaps(leaves: Array[Control], group: String) -> void:
	for i in leaves.size():
		for j in range(i + 1, leaves.size()):
			var a := leaves[i]
			var b := leaves[j]
			var ra := a.get_global_rect()
			var rb := b.get_global_rect()
			_check("%s no overlap: '%s' vs '%s'" % [group, _text_of(a), _text_of(b)], not ra.intersects(rb))


func _check_buttons(leaves: Array[Control], group: String) -> void:
	var seen := {}
	var coming_soon := 0
	var has_loadout := false
	var has_stats := false
	var vp := Rect2(Vector2.ZERO, _size)
	for c in leaves:
		if c is Button:
			var t := (c as Button).text
			_check("%s button '%s' renders exactly once" % [group, t], not seen.has(t))
			seen[t] = true
			if t == "COMING SOON":
				coming_soon += 1
			if t.contains("LOADOUT"):
				has_loadout = true
			if t == "STATS":
				has_stats = true
			_check("%s button '%s' fully inside viewport" % [group, t], vp.encloses(c.get_global_rect()))
	_check("%s COMING SOON appears zero times" % group, coming_soon == 0)
	_check("%s has a LOADOUTS button" % group, has_loadout)
	_check("%s has a STATS button" % group, has_stats)
	for want in ["SINGLE PLAYER", "MULTIPLAYER", "PUZZLE CHAMBERS", "LOADOUTS", "STATS", "CREATE A MOD", "OPTIONS", "QUIT"]:
		_check("%s has button '%s'" % [group, want], seen.has(want))
	var loadouts := _menu.get_node_or_null("MenuScroll/MenuStack/LoadoutButton") as Button
	if loadouts != null:
		_check("%s LOADOUTS button is enabled" % group, not loadouts.disabled)
	var stats := _menu.get_node_or_null("MenuScroll/MenuStack/StatsButton") as Button
	if stats != null:
		_check("%s STATS button is enabled" % group, not stats.disabled)


func _check_closed() -> void:
	var tag := "closed@%dx%d" % [int(_size.x), int(_size.y)]
	var stack := _menu.get_node_or_null("MenuScroll/MenuStack")
	_check(tag + " stack exists", stack != null)
	if stack == null:
		return
	var tagline := _menu.get_node_or_null("MenuScroll/MenuStack/Tagline") as Label
	var map_row := _menu.get_node_or_null("MenuScroll/MenuStack/MapRow") as Control
	_check(tag + " tagline exists", tagline != null)
	_check(tag + " map row exists", map_row != null)
	_check(tag + " no legacy MODE row (rework: mode select is an overlay)", _menu.get_node_or_null("MenuScroll/MenuStack/ModeRow") == null)
	_check(tag + " no legacy DEPLOY button (rework: SINGLE PLAYER top entry)", _menu.get_node_or_null("MenuScroll/MenuStack/DeployButton") == null)
	_check(tag + " SINGLE PLAYER top entry exists", _menu.get_node_or_null("MenuScroll/MenuStack/SinglePlayerButton") != null)
	_check(tag + " mode-select overlay exists (hidden)", _menu.get_node_or_null("ModeSelectOverlay") != null)
	if tagline != null and map_row != null:
		var tr := tagline.get_global_rect()
		var mr := map_row.get_global_rect()
		_check(tag + " tagline does not intersect MAP row", not tr.intersects(mr))
		_check(tag + " tagline is above MAP row", tr.position.y + tr.size.y <= mr.position.y + 0.5)
	var footer := _menu.get_node_or_null("MenuScroll/MenuStack/Footer") as Label
	_check(tag + " footer exists", footer != null)
	if footer != null:
		_check(tag + " footer text has no stale version", footer.text == "FORGEFALL — Colin's playtest build")
		_check(tag + " footer inside viewport", Rect2(Vector2.ZERO, _size).encloses(footer.get_global_rect()))
	var leaves: Array[Control] = []
	_leaves(stack, leaves)
	_check_no_overlaps(leaves, tag)
	_check_buttons(leaves, tag)
	# Stack must fit the viewport (no scrolling needed at these sizes).
	_check(tag + " stack fits viewport height", (stack as Control).size.y <= _size.y + 0.5)


func _check_options_open() -> void:
	var tag := "options@%dx%d" % [int(_size.x), int(_size.y)]
	var panel := _menu.get_node_or_null("OptionsPanel") as PanelContainer
	_check(tag + " options panel visible", panel != null and panel.visible)
	if panel == null:
		return
	_check(tag + " options panel inside viewport", Rect2(Vector2.ZERO, _size).encloses(panel.get_global_rect()))
	var leaves: Array[Control] = []
	_leaves(panel, leaves)
	_check_no_overlaps(leaves, tag)
	for c in leaves:
		if c is Button:
			_check(tag + " button '%s' inside viewport" % _text_of(c), Rect2(Vector2.ZERO, _size).encloses(c.get_global_rect()))


func _process(_delta: float) -> bool:
	_frame += 1
	match _phase:
		"build":
			_build_menu(_sizes[_size_idx])
			_frame = 0
			_phase = "wait_closed"
		"wait_closed":
			if _frame >= 3:
				_check_closed()
				(_menu as Control).call("_on_options")
				_frame = 0
				_phase = "wait_options"
		"wait_options":
			if _frame >= 2:
				_check_options_open()
				(_menu as Control).call("_on_options")
				_frame = 0
				_phase = "next"
		"next":
			if _frame >= 1:
				_size_idx += 1
				if _size_idx < _sizes.size():
					_phase = "build"
				elif not _resize_done:
					# Resize path: same menu, new size (NOTIFICATION_RESIZED).
					_resize_done = true
					_size_idx = 0
					_build_menu(Vector2(1280, 800))
					_frame = 0
					_phase = "wait_resize"
				else:
					_phase = "done"
		"wait_resize":
			if _frame >= 3:
				_menu.size = Vector2(1920, 1080)
				_size = Vector2(1920, 1080)
				_frame = 0
				_phase = "wait_resize2"
		"wait_resize2":
			if _frame >= 3:
				_check_closed()
				_phase = "done"
		"done":
			print("MENUVERIFY SUMMARY: %d passed, %d failed" % [_pass, _fail])
			quit(0 if _fail == 0 else 1)
			return true
	return false
