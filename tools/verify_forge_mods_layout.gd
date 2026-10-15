# verify_forge_mods_layout.gd — Forge menu Mods-tab layout verifier (v0.5.2 mirror fix).
# Mirrors the creator-menu fix (verify_creator_fix.gd "layout" section) into
# the Forge menu: the Mods tab's outer ScrollContainer was dropped, the
# Mods box is the direct TabContainer child, and the mod list (ModsScroll)
# is the only scroller. Asserts:
#   - 6 tabs, 6th tab child is a VBoxContainer named "Mods" (NOT a
#     ScrollContainer), tab title "Mods", _mods_tab_idx == 5
#   - ModsScroll is the ONLY ScrollContainer under the Mods tab and gets
#     real height: it fills the tab-area remainder after the path label
#     and Rescan row (baseline BEFORE the fix: exactly 0px — invisible
#     list; AFTER: the full remainder, 74px in headless geometry).
#     NOTE on the number: the Forge menu's TabContainer is min-sized
#     (ContentScroll sizes Content to its content minimum), so the tab
#     area is ~136px headless and the list gets the ~74px remainder —
#     small but visible and scrollable, same as the other tabs. The
#     assertion is therefore "fills the remainder + nonzero", not an
#     absolute >100px like the creator menu (which fills the viewport).
#   - ModsList gets nonzero content height
#   - ModsHintLabel keeps SIZE_EXPAND_FILL and renders horizontal
#     (>= 40px wide); the Rescan row stays < 100px tall (was ~1617px
#     in the creator menu's version of this bug)
#   - no visible Mods-tab label narrower than 40px with multi-char text
#     (no vertical-char rendering)
#   - Mods-tab behavior unchanged: path label shows user://mods, RESCAN
#     button exists, Rescan refreshes the list, tab-away-and-back
#     refreshes via _on_tab_changed, toggle flips status and flips back
#     (state restored; skipped when no mods are installed)
# Usage: godot --headless --path <project> --script res://tools/verify_forge_mods_layout.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _pass := 0
var _fails := 0
var _frames := 0
var _phase := 0
var _menu: Control = null
var _toggle_name := ""
var _toggle_before := ""


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _find_named(n: Node, name: String) -> Node:
	if n.name == name and not n.is_queued_for_deletion():
		return n
	for c in n.get_children():
		var found := _find_named(c, name)
		if found != null:
			return found
	return null


func _find_all_named(n: Node, name: String, out: Array) -> void:
	if n.name == name and not n.is_queued_for_deletion():
		out.append(n)
	for c in n.get_children():
		_find_all_named(c, name, out)


func _scan_narrow(n: Node, bad: Array[String]) -> void:
	if n is Control and not (n as Control).is_visible_in_tree():
		return
	if n is Label:
		var lb := n as Label
		if lb.text.length() > 10 and lb.size.x < 40.0:
			bad.append("%s '%s' size=%s text='%s'" % [lb.get_class(), lb.name, lb.size, lb.text.left(30)])
	for ch in n.get_children():
		_scan_narrow(ch, bad)


func _check_layout() -> void:
	var tag := "mods-layout"
	_check(_menu != null, tag + ": menu instantiates")
	if _menu == null:
		return
	var tabs := _menu.get("_tabs") as TabContainer
	_check(tabs != null, tag + ": menu has TabContainer")
	if tabs == null:
		return
	_check(tabs.get_tab_count() == 6, tag + ": 6 tabs (got %d)" % tabs.get_tab_count())
	var names: Array[String] = []
	for i in tabs.get_tab_count():
		names.append(tabs.get_child(i).name)
	_check(names == ["Build", "Weapons", "Events", "Killstreaks", "Loadouts", "Mods"],
		tag + ": tab child names incl. Mods 6th (got %s)" % str(names))
	_check(int(_menu.get("_mods_tab_idx")) == 5, tag + ": _mods_tab_idx == 5 (got %s)" % str(_menu.get("_mods_tab_idx")))
	_check(tabs.get_tab_title(5) == "Mods", tag + ": Mods tab title is 'Mods' (got '%s')" % tabs.get_tab_title(5))
	var tab_child := tabs.get_child(5) as Control
	_check(tab_child is VBoxContainer, tag + ": Mods tab child is a VBoxContainer, not a wrapping ScrollContainer (got %s)" % tab_child.get_class())
	_check(not (tab_child is ScrollContainer), tag + ": Mods tab has NO wrapping ScrollContainer (list is the only scroller)")
	var scrolls: Array = []
	_find_all_named(tab_child, "ModsScroll", scrolls)
	_check(scrolls.size() == 1 and scrolls[0] is ScrollContainer, tag + ": exactly one ModsScroll under the Mods tab")
	var scroll := _find_named(_menu, "ModsScroll") as ScrollContainer
	_check(scroll != null, tag + ": ModsScroll exists")
	var path_lbl := _find_named(_menu, "ModsPathLabel") as Label
	var row := _find_named(_menu, "ModsRescanRow") as Control
	if scroll != null:
		_check(scroll.size_flags_vertical == Control.SIZE_EXPAND_FILL, tag + ": ModsScroll keeps SIZE_EXPAND_FILL vertical")
		_check(scroll.size.y > 0.0, tag + ": ModsScroll gets nonzero height (was exactly 0px before the fix; got %.1f)" % scroll.size.y)
		if tab_child != null and path_lbl != null and row != null:
			# The list must take ALL remaining tab area after the fixed
			# rows (20px slack covers VBox separations), not collapse.
			var remainder := tab_child.size.y - path_lbl.size.y - row.size.y
			_check(scroll.size.y >= remainder - 20.0,
				tag + ": ModsScroll fills the tab-area remainder (list %.1f vs remainder %.1f, tab %.1f)" % [scroll.size.y, remainder, tab_child.size.y])
	var scroll_count := 0
	var stack: Array[Node] = [tab_child]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is ScrollContainer:
			scroll_count += 1
		for c in n.get_children():
			stack.append(c)
	_check(scroll_count == 1, tag + ": exactly 1 ScrollContainer under the Mods tab (got %d)" % scroll_count)
	var mods_list := _find_named(_menu, "ModsList") as VBoxContainer
	_check(mods_list != null, tag + ": ModsList exists")
	if mods_list != null:
		_check(mods_list.size.y > 0.0, tag + ": ModsList gets nonzero content height (got %.1f)" % mods_list.size.y)
		_check(mods_list.get_child_count() >= 1, tag + ": ModsList has >= 1 child (empty note or rows; got %d)" % mods_list.get_child_count())
	var hint := _find_named(_menu, "ModsHintLabel") as Label
	_check(hint != null, tag + ": ModsHintLabel exists")
	if hint != null:
		_check(hint.size_flags_horizontal == Control.SIZE_EXPAND_FILL, tag + ": hint keeps SIZE_EXPAND_FILL horizontal")
		_check(hint.size.x >= 40.0, tag + ": hint renders horizontal (>= 40px wide, not 1-char-per-line; got %.1f)" % hint.size.x)
		_check(hint.text == "Drop a mod folder in, then Rescan.", tag + ": hint text unchanged (got '%s')" % hint.text)
	_check(row != null, tag + ": ModsRescanRow exists")
	if row != null:
		_check(row.size.y < 100.0, tag + ": Rescan row < 100px tall (was ~1617px in the creator-menu bug; got %.1f)" % row.size.y)
	var bad: Array[String] = []
	_scan_narrow(tab_child, bad)
	_check(bad.is_empty(), tag + ": no narrow Mods-tab label with multi-char text (%s)" % (", ".join(bad) if not bad.is_empty() else "none"))
	# Behavior unchanged: path label + Rescan button.
	var want_path := OS.get_user_data_dir() + "/mods"
	_check(path_lbl != null and path_lbl.text.contains(want_path),
		tag + ": path label shows %s (got '%s')" % [want_path, path_lbl.text if path_lbl != null else "null"])
	var rescan := _find_named(_menu, "ModsRescanButton") as Button
	_check(rescan != null and rescan.text == "RESCAN",
		tag + ": Rescan button exists with text RESCAN")


func _status_by_name(mod_name: String) -> String:
	var rows: Array = []
	_find_all_named(_menu, "ModRow", rows)
	for r in rows:
		var name_lbl := _find_named(r as Node, "ModName") as Label
		if name_lbl != null and name_lbl.text == mod_name:
			var status_lbl := _find_named(r as Node, "ModStatus") as Label
			if status_lbl != null:
				return status_lbl.text
	return ""


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		0:
			var ps := load("res://scenes/ui/forge_menu.tscn") as PackedScene
			_menu = ps.instantiate() as Control
			_menu.name = "ForgeModsLayoutMenu"
			root.add_child(_menu)
			_menu.call("open")
			var tabs := _menu.get("_tabs") as TabContainer
			if tabs != null:
				tabs.current_tab = int(_menu.get("_mods_tab_idx"))
			_frames = 0
			_phase = 1
		1:
			if _frames < 3:
				return false
			_check_layout()
			# Rescan refreshes the list without breaking it.
			var rescan := _find_named(_menu, "ModsRescanButton") as Button
			if rescan != null:
				rescan.pressed.emit()
			_frames = 0
			_phase = 2
		2:
			if _frames < 3:
				return false
			var mods_list := _find_named(_menu, "ModsList") as VBoxContainer
			_check(mods_list != null and mods_list.get_child_count() >= 1,
				"mods-layout: after Rescan, ModsList still populated (got %d)" % (mods_list.get_child_count() if mods_list != null else -1))
			# Tab away and back: _on_tab_changed must refresh the Mods tab.
			var tabs := _menu.get("_tabs") as TabContainer
			if tabs != null:
				tabs.current_tab = 0
			_frames = 0
			_phase = 3
		3:
			if _frames < 2:
				return false
			var tabs := _menu.get("_tabs") as TabContainer
			if tabs != null:
				tabs.current_tab = int(_menu.get("_mods_tab_idx"))
			_frames = 0
			_phase = 4
		4:
			if _frames < 3:
				return false
			var mods_list := _find_named(_menu, "ModsList") as VBoxContainer
			_check(mods_list != null and mods_list.get_child_count() >= 1,
				"mods-layout: after tab-away-and-back, ModsList still populated (got %d)" % (mods_list.get_child_count() if mods_list != null else -1))
			# Toggle-through on the first row, if any mod is installed.
			var rows: Array = []
			_find_all_named(_menu, "ModRow", rows)
			if rows.is_empty():
				_check(true, "mods-layout: no installed mods — toggle check skipped (empty-note path)")
				_phase = 7
				_frames = 0
				return false
			var name_lbl := _find_named(rows[0] as Node, "ModName") as Label
			_toggle_name = name_lbl.text if name_lbl != null else ""
			_toggle_before = _status_by_name(_toggle_name)
			var toggle := _find_named(rows[0] as Node, "ModToggle") as Button
			_check(toggle != null, "mods-layout: first mod row has a toggle button")
			if toggle != null:
				toggle.pressed.emit()
			_frames = 0
			_phase = 5
		5:
			if _frames < 3:
				return false
			var after := _status_by_name(_toggle_name)
			_check(not after.is_empty() and after != _toggle_before,
				"mods-layout: toggle flips '%s' status %s -> %s" % [_toggle_name, _toggle_before, after])
			# Flip back so the verifier leaves persisted mod state untouched.
			var rows: Array = []
			_find_all_named(_menu, "ModRow", rows)
			for r in rows:
				var name_lbl := _find_named(r as Node, "ModName") as Label
				if name_lbl != null and name_lbl.text == _toggle_name:
					var toggle := _find_named(r as Node, "ModToggle") as Button
					if toggle != null:
						toggle.pressed.emit()
					break
			_frames = 0
			_phase = 6
		6:
			if _frames < 3:
				return false
			var restored := _status_by_name(_toggle_name)
			_check(restored == _toggle_before,
				"mods-layout: toggle restores '%s' status to %s (got %s)" % [_toggle_name, _toggle_before, restored])
			_phase = 7
			_frames = 0
		7:
			if _frames < 1:
				return false
			if _menu != null and is_instance_valid(_menu):
				_menu.queue_free()
			if _fails == 0:
				print("VERIFY_FORGE_MODS_LAYOUT: ALL CHECKS PASSED (%d)" % _pass)
			else:
				printerr("VERIFY_FORGE_MODS_LAYOUT: %d PASS / %d FAIL" % [_pass, _fails])
			quit(_fails)
			return true
	return false
