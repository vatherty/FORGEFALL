# verify_v07_b_mods_turret.gd — headless checks for FORGEFALL v0.7 chunk 1,
# WORKER B: Forge menu Mods tab + turret damage_mult/range_mult follow-up.
# Usage: godot --headless --path <project> --script res://tools/verify_v07_b_mods_turret.gd
# Asserts:
#   (1) Forge menu has 6 tabs; the 6th is "Mods" with a path label
#       (OS.get_user_data_dir() + "/mods"), a RESCAN button, and a list.
#   (2) ModLoader ABSENT -> the tab shows a graceful unavailable/empty
#       note and the menu still opens (no parse breakage).
#       ModLoader PRESENT -> rows match get_mods() (name/kind/status,
#       error in red when present); toggle flips enabled via
#       set_mod_enabled(); rescan refreshes the list.
#   (3) Turret: damage_mult/range_mult metadata scale live damage and
#       range (sniper 1.5/1.0, buckshot 1.3/0.6); no metas -> 1.0/1.0.
#       Buckshot at 25 m (range 18) never acquires; sniper/default at
#       25 m acquire and deal scaled per-hit damage.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _arena: Node = null
var _menu: Control = null
var _toggle_mod_name := ""
var _toggle_status_before := ""
# Turret cases: [turret, foe, expected per-hit damage or 0.0 if out of range]
var _cases: Array = []


class MockFoe extends Node3D:
	var dead := false
	var damage_taken := 0.0

	func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool) -> void:
		damage_taken += amount


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _find_named(n: Node, name: String) -> Node:
	# Skips nodes queued for free: _refresh_mods() rebuilds rows with
	# queue_free(), so a stale row can linger one frame with the same name.
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


func _mods_status_by_name(mod_name: String) -> String:
	var rows: Array = []
	_find_all_named(_menu, "ModRow", rows)
	for r in rows:
		var name_lbl := _find_named(r as Node, "ModName") as Label
		if name_lbl != null and name_lbl.text == mod_name:
			var status_lbl := _find_named(r as Node, "ModStatus") as Label
			if status_lbl != null:
				return status_lbl.text
	return ""


func _mod_loader_script() -> GDScript:
	var path := "res://scripts/mods/mod_loader.gd"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as GDScript


func _mod_call(loader: GDScript, method: String, args: Array) -> Variant:
	if loader == null:
		return null
	var is_static := true
	var found := false
	for m in loader.get_script_method_list():
		if str(m.get("name", "")) == method:
			found = true
			is_static = (int(m.get("flags", 0)) & 32) != 0
			break
	if not found:
		return null
	if is_static:
		return loader.callv(method, args)
	var inst: Object = loader.new()
	var result: Variant = inst.callv(method, args)
	if inst is Node:
		(inst as Node).free()
	return result


func _initialize() -> void:
	_arena = Node.new()
	_arena.name = "VerifyArena"
	root.add_child(_arena)
	var menu_ps := load("res://scenes/ui/forge_menu.tscn") as PackedScene
	_menu = menu_ps.instantiate() as Control
	_check(_menu != null, "v07b: forge_menu.tscn instantiates")
	if _menu == null:
		_finish()
		return
	_arena.add_child(_menu)
	_build_turret_cases()
	_phase = 1
	_frames = 0
	print("VERIFY v07b: arena built (Forge menu + 4 turret cases)")


func _build_turret_cases() -> void:
	var turret_script := load("res://scripts/forge/forge_turret.gd") as GDScript
	_check(turret_script != null, "v07b: forge_turret.gd loads (no parse errors)")
	if turret_script == null:
		return
	# [label, turret pos, metas, foe pos, expected per-hit damage (0 = out of range)]
	var defs := [
		["sniper", Vector3(0, 0, 0), {"damage_mult": 1.5, "range_mult": 1.0}, Vector3(25, 0, 0), 22.5],
		["buckshot-far", Vector3(0, 0, 60), {"damage_mult": 1.3, "range_mult": 0.6}, Vector3(25, 0, 60), 0.0],
		["buckshot-near", Vector3(0, 0, 120), {"damage_mult": 1.3, "range_mult": 0.6}, Vector3(10, 0, 120), 19.5],
		["default", Vector3(0, 0, 180), {}, Vector3(25, 0, 180), 15.0],
	]
	for d in defs:
		var label: String = d[0]
		var t: Node = turret_script.new()
		t.name = "Turret_" + label
		for k in (d[2] as Dictionary).keys():
			t.set_meta(k, (d[2] as Dictionary)[k])
		t.position = d[1]
		_arena.add_child(t)
		var foe := MockFoe.new()
		foe.name = "Foe_" + label
		foe.position = d[3]
		foe.add_to_group("enemy")
		_arena.add_child(foe)
		_cases.append([label, t, foe, float(d[4])])


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 3:
				return false
			_check_menu_static()
			var loader := _mod_loader_script()
			if loader != null and _menu != null:
				var mods: Variant = _mod_call(loader, "get_mods", [])
				if mods is Array and not (mods as Array).is_empty():
					# Toggle-through test on the first listed mod.
					var rows: Array = []
					_find_all_named(_menu, "ModRow", rows)
					if not rows.is_empty():
						var name_lbl := _find_named(rows[0] as Node, "ModName") as Label
						_toggle_mod_name = name_lbl.text if name_lbl != null else ""
						_toggle_status_before = _mods_status_by_name(_toggle_mod_name)
						var toggle := _find_named(rows[0] as Node, "ModToggle") as Button
						_check(toggle != null, "v07b: first mod row has a toggle button")
						if toggle != null:
							toggle.pressed.emit()
							_phase = 2
							_frames = 0
							return false
			_phase = 4
			_frames = 0
		2:
			if _frames < 3:
				return false
			var after := _mods_status_by_name(_toggle_mod_name)
			_check(not after.is_empty() and after != _toggle_status_before,
				"v07b: toggle flips '%s' status %s -> %s" % [_toggle_mod_name, _toggle_status_before, after])
			# Flip it back so the verifier leaves persisted mod state untouched.
			var rows2: Array = []
			_find_all_named(_menu, "ModRow", rows2)
			for r in rows2:
				var name_lbl := _find_named(r as Node, "ModName") as Label
				if name_lbl != null and name_lbl.text == _toggle_mod_name:
					var toggle := _find_named(r as Node, "ModToggle") as Button
					if toggle != null:
						toggle.pressed.emit()
					break
			_phase = 3
			_frames = 0
		3:
			if _frames < 3:
				return false
			var restored := _mods_status_by_name(_toggle_mod_name)
			_check(restored == _toggle_status_before,
				"v07b: toggle restores '%s' status to %s (got %s)" % [_toggle_mod_name, _toggle_status_before, restored])
			var rescan := _find_named(_menu, "ModsRescanButton") as Button
			_check(rescan != null, "v07b: Rescan button exists for rescan check")
			if rescan != null:
				rescan.pressed.emit()
			_phase = 5
			_frames = 0
		5:
			if _frames < 3:
				return false
			var loader2 := _mod_loader_script()
			var mods2: Variant = _mod_call(loader2, "get_mods", [])
			var rows3: Array = []
			_find_all_named(_menu, "ModRow", rows3)
			if mods2 is Array:
				_check(rows3.size() == (mods2 as Array).size(),
					"v07b: after Rescan, row count %d == get_mods() count %d" % [rows3.size(), (mods2 as Array).size()])
			_phase = 4
			_frames = 0
		4:
			if _frames < 4:
				return false
			_check_turrets()
			_finish()
			return true
	return false


func _check_menu_static() -> void:
	if _menu == null:
		_check(false, "v07b: menu exists for static checks")
		return
	_menu.call("open")
	var tabs := _menu.get("_tabs") as TabContainer
	_check(tabs != null, "v07b: menu has TabContainer")
	if tabs == null:
		return
	_check(tabs.get_tab_count() == 6,
		"v07b: menu has 6 tabs (got %d)" % tabs.get_tab_count())
	var names: Array[String] = []
	for i in tabs.get_tab_count():
		names.append(tabs.get_child(i).name)
	_check(names == ["Build", "Weapons", "Events", "Killstreaks", "Loadouts", "Mods"],
		"v07b: tab names incl. Mods 6th (got %s)" % str(names))
	var path_lbl := _find_named(_menu, "ModsPathLabel") as Label
	var want_path := OS.get_user_data_dir() + "/mods"
	_check(path_lbl != null and path_lbl.text.contains(want_path),
		"v07b: Mods path label shows %s (got '%s')" % [want_path, path_lbl.text if path_lbl != null else "null"])
	var rescan := _find_named(_menu, "ModsRescanButton") as Button
	_check(rescan != null and rescan.text == "RESCAN",
		"v07b: Mods Rescan button exists with text RESCAN")
	_check(_find_named(_menu, "ModsList") != null, "v07b: ModsList container exists")
	_check(_find_named(_menu, "ModsScroll") != null, "v07b: ModsScroll exists")
	var loader := _mod_loader_script()
	if loader == null:
		var empty := _find_named(_menu, "ModsEmptyLabel") as Label
		_check(empty != null and (empty.text.contains("unavailable") or empty.text.contains("No mods")),
			"v07b: no ModLoader -> graceful unavailable/empty note (got '%s')" % (empty.text if empty != null else "null"))
		print("V07B NOTE: ModLoader absent — toggle/rescan-through checks skipped (menu-only path verified)")
	else:
		var mods: Variant = _mod_call(loader, "get_mods", [])
		_check(mods is Array, "v07b: ModLoader.get_mods() returns Array")
		if mods is Array:
			if (mods as Array).is_empty():
				var empty2 := _find_named(_menu, "ModsEmptyLabel") as Label
				_check(empty2 != null and empty2.text.contains("No mods installed")
					and empty2.text.contains(want_path) and empty2.text.contains("Rescan"),
					"v07b: empty state text names path + Rescan (got '%s')" % (empty2.text if empty2 != null else "null"))
			else:
				var rows: Array = []
				_find_all_named(_menu, "ModRow", rows)
				_check(rows.size() == (mods as Array).size(),
					"v07b: row count %d == get_mods() count %d" % [rows.size(), (mods as Array).size()])
				for i in range(mini(rows.size(), (mods as Array).size())):
					var m := (mods as Array)[i] as Dictionary
					var name_lbl := _find_named(rows[i] as Node, "ModName") as Label
					var kind_lbl := _find_named(rows[i] as Node, "ModKind") as Label
					var status_lbl := _find_named(rows[i] as Node, "ModStatus") as Label
					_check(name_lbl != null and name_lbl.text == str(m.get("name", m.get("id", ""))),
						"v07b: row %d name '%s'" % [i, name_lbl.text if name_lbl != null else "null"])
					var want_kind := "Script" if str(m.get("kind", "")) == "script" else "Block"
					_check(kind_lbl != null and kind_lbl.text == want_kind,
						"v07b: row %d kind '%s'" % [i, kind_lbl.text if kind_lbl != null else "null"])
					var want_status := "ENABLED" if bool(m.get("enabled", false)) else "DISABLED"
					_check(status_lbl != null and status_lbl.text == want_status,
						"v07b: row %d status '%s'" % [i, status_lbl.text if status_lbl != null else "null"])
					var err := str(m.get("error", ""))
					# ModError lives in the row WRAP (sibling of the
					# ModRow HBox), not inside the HBox itself.
					var wrap := (rows[i] as Node).get_parent()
					var err_lbl := _find_named(wrap, "ModError") as Label if wrap != null else null
					if not err.is_empty():
						_check(err_lbl != null and err_lbl.text.contains(err),
							"v07b: row %d shows error in red label" % i)
						if err_lbl != null:
							_check(err_lbl.get_theme_color("font_color") == Color(0.85, 0.12, 0.10),
								"v07b: row %d error label is red" % i)
					else:
						_check(err_lbl == null, "v07b: row %d has no error label when error empty" % i)


func _check_turrets() -> void:
	for c in _cases:
		var label: String = c[0]
		var t = c[1]
		var foe: MockFoe = c[2]
		var want_hit: float = c[3]
		if t == null or foe == null:
			_check(false, "v07b(turret %s): case nodes exist" % label)
			continue
		var dmg_mult := float(t.get("_damage_mult"))
		var rng_mult := float(t.get("_range_mult"))
		var want_dmg := 1.0
		var want_rng := 1.0
		match label:
			"sniper":
				want_dmg = 1.5
				want_rng = 1.0
			"buckshot-far", "buckshot-near":
				want_dmg = 1.3
				want_rng = 0.6
		_check(is_equal_approx(dmg_mult, want_dmg),
			"v07b(turret %s): _damage_mult == %s (got %s)" % [label, want_dmg, dmg_mult])
		_check(is_equal_approx(rng_mult, want_rng),
			"v07b(turret %s): _range_mult == %s (got %s)" % [label, want_rng, rng_mult])
		_check(is_equal_approx(float(t.call("get_damage")), 15.0 * want_dmg),
			"v07b(turret %s): get_damage() == %s (got %s)" % [label, 15.0 * want_dmg, float(t.call("get_damage"))])
		_check(is_equal_approx(float(t.call("get_range")), 30.0 * want_rng),
			"v07b(turret %s): get_range() == %s (got %s)" % [label, 30.0 * want_rng, float(t.call("get_range"))])
		if want_hit <= 0.0:
			_check(t.get("_target") == null and is_equal_approx(foe.damage_taken, 0.0),
				"v07b(turret %s): out of range -> no target, no damage (target=%s dmg=%s)"
				% [label, str(t.get("_target")), foe.damage_taken])
		else:
			_check(t.get("_target") == foe,
				"v07b(turret %s): in range -> acquired foe" % label)
			_check(foe.damage_taken >= want_hit - 0.001,
				"v07b(turret %s): foe took >= %.1f damage (got %.1f)" % [label, want_hit, foe.damage_taken])
			var hits := foe.damage_taken / want_hit if want_hit > 0.0 else 0.0
			_check(is_equal_approx(hits, roundf(hits)) and hits >= 1.0,
				"v07b(turret %s): damage is a whole number of %.1f hits (%.1f total = %.1f hits)"
				% [label, want_hit, foe.damage_taken, hits])


func _finish() -> void:
	if _fails == 0:
		print("VERIFY_V07B: ALL CHECKS PASSED")
	else:
		printerr("VERIFY_V07B: %d CHECK(S) FAILED" % _fails)
	quit(_fails)
