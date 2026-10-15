# verify_v06_loadouts.gd — headless checks for the v0.6 LOADOUTS item.
# Usage: godot --headless --path <project> --script res://tools/verify_v06_loadouts.gd
# Checks:
#   1. Each of the 4 presets sets the expected primary + secondary weapon_id
#      on the WeaponManager (via equip_loadout_named + get_slot_weapon_id).
#   2. Applying a loadout does NOT change the Forge budget (Game autoload).
#   3. The delivered Loadouts tab block (TAB_BLOCK, verbatim copy of the
#      insertable block for forge_menu.gd) parses as GDScript, and contains
#      no Forge budget/cost calls.
#   4. Edge cases: unknown preset = no-op (false); bad slot/id = no-op;
#      set_slot("secondary", ...) works; give_weapon still replaces primary.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _player: Node = null
var _wm: Node = null

# Verbatim copy of the insertable Loadouts tab block delivered for
# scripts/ui/forge_menu.gd (const + builder + handlers). The coordinator
# applies it at the anchor in _build() (see comment at the top of the block).
const TAB_BLOCK := """# ---- v0.6 LOADOUTS insert (forge_menu.gd) ----
# ANCHOR (in _build(), right AFTER the preset-tab loop
# `for tab_name in ["Build", "Weapons", "Events", "Killstreaks"]:` and
# BEFORE `# Free-text prompt + confirm.`):
#	# v0.6 LOADOUTS (free gear — no Forge budget cost): 4 presets.
#	_build_loadouts_tab()
# Functions below: append near the end of forge_menu.gd (e.g. after _play).
# They call ONLY WeaponManager.equip_loadout — never Forge / budget APIs.
const LOADOUT_PRESETS := {
	"Assault": ["ar7", "p9"],
	"Marksman": ["lr8", "p9"],
	"Breacher": ["sg12", "smg9"],
	"Raptor": ["raptor", "smg9"],
}


func _build_loadouts_tab() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Loadouts"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for loadout_name in LOADOUT_PRESETS:
		var preset: Array = LOADOUT_PRESETS[loadout_name]
		var b := Button.new()
		b.name = "Loadout_" + loadout_name
		b.text = loadout_name.to_upper()
		b.custom_minimum_size = Vector2(0, 64)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		StencilStyle.style_button(b)
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(_on_loadout_pressed.bind(loadout_name, str(preset[0]), str(preset[1])))
		grid.add_child(b)


func _on_loadout_pressed(loadout_name: String, primary_id: String, secondary_id: String) -> void:
	var wm := _get_weapon_manager()
	if wm == null or not wm.has_method("equip_loadout"):
		_show_toast("Loadouts unavailable.")
		return
	wm.call("equip_loadout", primary_id, secondary_id)
	_show_toast("%s loadout equipped — free." % loadout_name)
	_play("ui_click")


func _get_weapon_manager() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var nodes := tree.get_nodes_in_group("weapon_manager")
	if nodes.is_empty():
		return null
	return nodes[0]
"""


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	var arena := Node3D.new()
	arena.name = "VerifyArena"
	root.add_child(arena)
	var ps := load("res://scenes/player.tscn") as PackedScene
	_player = ps.instantiate()
	_player.name = "Player"
	arena.add_child(_player)
	_phase = 1
	print("VERIFY: arena built, waiting for _ready")


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 1:
		if _frames < 5:
			return false
		_check_loadouts()
		_check_tab_block()
		_phase = 2
	if _phase == 2:
		if _fails == 0:
			print("VERIFY: ALL CHECKS PASSED")
		else:
			printerr("VERIFY: %d CHECK(S) FAILED" % _fails)
		quit(_fails)
		return true
	return false


func _check_loadouts() -> void:
	_wm = _player.get_node_or_null("WeaponManager")
	_check(_wm != null, "player.tscn has a WeaponManager child")
	if _wm == null:
		return
	_check(_wm.has_method("equip_loadout"), "WeaponManager exposes equip_loadout")
	_check(_wm.has_method("equip_loadout_named"), "WeaponManager exposes equip_loadout_named")
	_check(_wm.has_method("set_slot"), "WeaponManager exposes set_slot")
	_check(_wm.has_method("get_slot_weapon_id"), "WeaponManager exposes get_slot_weapon_id")
	if not _wm.has_method("equip_loadout_named"):
		return

	var game := root.get_node_or_null("Game")
	_check(game != null, "Game autoload present for live budget check")

	# Expected presets (ids verified against Arsenal.WEAPONS).
	var expected := {
		"Assault": ["ar7", "p9"],
		"Marksman": ["lr8", "p9"],
		"Breacher": ["sg12", "smg9"],
		"Raptor": ["raptor", "smg9"],
	}
	for loadout_name in expected:
		var want: Array = expected[loadout_name]
		var budget_before := -1
		if game != null:
			budget_before = int(game.get("forge_budget"))
		var applied: bool = _wm.call("equip_loadout_named", loadout_name)
		_check(applied, "equip_loadout_named('%s') returns true" % loadout_name)
		var got_primary: String = str(_wm.call("get_slot_weapon_id", "primary"))
		var got_secondary: String = str(_wm.call("get_slot_weapon_id", "secondary"))
		_check(got_primary == str(want[0]),
			"%s sets primary=%s (got %s)" % [loadout_name, want[0], got_primary])
		_check(got_secondary == str(want[1]),
			"%s sets secondary=%s (got %s)" % [loadout_name, want[1], got_secondary])
		if game != null:
			var budget_after := int(game.get("forge_budget"))
			_check(budget_after == budget_before,
				"%s leaves Forge budget unchanged (%d)" % [loadout_name, budget_after])

	# Edge: unknown preset is a no-op returning false; slots unchanged.
	var before_p: String = str(_wm.call("get_slot_weapon_id", "primary"))
	var before_s: String = str(_wm.call("get_slot_weapon_id", "secondary"))
	var unknown: bool = _wm.call("equip_loadout_named", "NoSuchLoadout")
	_check(unknown == false, "unknown loadout name returns false")
	_check(str(_wm.call("get_slot_weapon_id", "primary")) == before_p,
		"unknown loadout leaves primary unchanged")
	_check(str(_wm.call("get_slot_weapon_id", "secondary")) == before_s,
		"unknown loadout leaves secondary unchanged")

	# Edge: bad slot / bad weapon id are no-ops.
	_wm.call("set_slot", "nope", "ar7")
	_wm.call("set_slot", "primary", "nope")
	_check(str(_wm.call("get_slot_weapon_id", "primary")) == before_p,
		"bad set_slot calls leave primary unchanged")

	# Edge: set_slot("secondary", ...) works directly.
	_wm.call("set_slot", "secondary", "p9")
	_check(str(_wm.call("get_slot_weapon_id", "secondary")) == "p9",
		"set_slot('secondary', 'p9') sets secondary=p9")

	# Regression: give_weapon still replaces only the primary.
	var budget_before := -1
	if game != null:
		budget_before = int(game.get("forge_budget"))
	_wm.call("give_weapon", "smg9")
	_check(str(_wm.call("get_slot_weapon_id", "primary")) == "smg9",
		"give_weapon('smg9') still replaces primary")
	_check(str(_wm.call("get_slot_weapon_id", "secondary")) == "p9",
		"give_weapon leaves secondary untouched")
	if game != null:
		_check(int(game.get("forge_budget")) == budget_before,
			"give_weapon leaves Forge budget unchanged")


func _check_tab_block() -> void:
	# No Forge/budget call patterns anywhere in the delivered tab block.
	for banned in ["get_budget", "spend_budget", "grant_budget", "preview_cost",
			"submit_prompt", "_get_forge", "Forge.", "forge_result"]:
		_check(not (banned in TAB_BLOCK),
			"tab block contains no '%s' call" % banned)
	_check("equip_loadout" in TAB_BLOCK, "tab block calls equip_loadout")
	for preset_name in ["Assault", "Marksman", "Breacher", "Raptor"]:
		_check(preset_name in TAB_BLOCK, "tab block includes '%s' button" % preset_name)
	# Parse-check: compile the block's GDScript (const + funcs) standalone.
	# The anchor comment lines are stripped (they are not code); the
	# one-line call site is represented by the hook stub below.
	var src := "extends Control\nvar _tabs: TabContainer\n"
	src += "func _show_toast(_t: String) -> void:\n\tpass\n"
	src += "func _play(_id: String) -> void:\n\tpass\n"
	var code := TAB_BLOCK
	# Drop the leading anchor-comment header (lines starting with # up to
	# the LOADOUT_PRESETS const) — it is documentation, not code.
	var cut := code.find("const LOADOUT_PRESETS")
	if cut >= 0:
		code = code.substr(cut)
	src += code
	src += "\nfunc _hook() -> void:\n\t_build_loadouts_tab()\n"
	var script := GDScript.new()
	script.source_code = src
	var err := script.reload()
	_check(err == OK, "tab block parses as GDScript (reload err=%d)" % err)
