# verify_tower_defense.gd — headless checks for FORGEFALL Tower Defense
# (Gameplay Rework, TD worker).
# Usage: godot --headless --path <project> --script res://tools/verify_tower_defense.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Covers: TD map loads with lanes/build spots; build phase allows
# building; combat waves follow the lanes (spawn doors at lane heads,
# lane-shaped nav); core HP falls when enemies reach it and the run
# ends; Forge building is BLOCKED in TDM/Zombies/other modes and
# ALLOWED in TD (gate + pipeline + menu); TD pre-run traversal choice
# is exactly one of grapple/jetpack/portal.
#
# Strategy: SceneTree script. Autoloads (Game, Forge) are present in
# --script runs (same pattern as verify_v05_b2_forge_backend.gd).
# Enemies are faked with a tiny Node3D double (active/dead vars +
# take_damage) — the real enemy AI is the parallel worker's, and the TD
# mode only ever touches the documented spawn/damage interfaces.
extends SceneTree

# Fake enemy: the only enemy surface TD mode touches is group "enemy",
# vars active/dead, and take_damage(amount, pos, is_headshot).
class FakeEnemy extends Node3D:
	var active := true
	var dead := false
	var take_damage_calls := 0

	func take_damage(_amount: float, _pos: Vector3, _hs: bool, _atk: Node = null) -> void:
		take_damage_calls += 1
		dead = true


# Fake player implementing the movement worker's selection API contract:
# set_traversal_tool(tool) — activates exactly that tool.
class FakePlayer extends Node3D:
	var traversal_calls: Array[String] = []

	func set_traversal_tool(tool: String) -> bool:
		traversal_calls.append(tool)
		return true


# Fake player WITHOUT the selection API (movement work not landed yet).
class FakePlayerNoApi extends Node3D:
	pass


var _fails := 0
var _checks := 0
var _started := false
var _done := false
var _forge_result: Array = []
var _td_over: Array = []
var _nav_map: Node3D = null
var _nav_done := false
var _nav_region_checked := false
var _launched := false
var _frames := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	if not _started:
		_started = true
		_run_checks()
		if not _launched:
			printerr("verify_tower_defense aborted early (runtime error above)")
			_done = true
			quit(1)
			return true
		return false
	# The nav stage polls each tick (no awaits — SceneTree scripts
	# cannot reliably await signals) and finishes on its own; this is
	# only a watchdog so a stuck nav stage cannot idle forever.
	_frames += 1
	if not _nav_done:
		_nav_tick()
	if _frames > 900:
		printerr("verify_tower_defense timed out waiting for nav stage")
		_done = true
		quit(1)
		return true
	return false


func _check(name: String, cond: bool) -> void:
	_checks += 1
	if cond:
		print("PASS: ", name)
	else:
		_fails += 1
		printerr("FAIL: ", name)


func _on_forge_result(success: bool, message: String) -> void:
	_forge_result.append([success, message])


func _on_td_over(waves: int, score: int) -> void:
	_td_over.append([waves, score])


func _run_checks() -> void:
	var core_pos := Vector3.ZERO
	var gate_script := load("res://scripts/forge/forge_gate.gd") as GDScript
	var td_script := load("res://scripts/modes/tower_defense.gd") as GDScript
	var setup_script := load("res://scripts/modes/td_setup.gd") as GDScript
	var mode_mgr_script := load("res://scripts/core/game_mode.gd") as GDScript
	var forge := root.get_node_or_null("Forge")
	_check("Forge autoload present", forge != null)
	if forge != null and forge.has_signal("forge_result"):
		forge.connect("forge_result", _on_forge_result)

	# ---- 1. TD map loads with lanes / build spots -------------------------
	var map_scene := load("res://scenes/maps/tower_defense.tscn") as PackedScene
	_check("TD map scene loads", map_scene != null)
	var td_map: Node3D = null
	if map_scene != null:
		td_map = map_scene.instantiate() as Node3D
		root.add_child(td_map)
		_nav_map = td_map
		# Builder _ready() runs synchronously in add_child().
		var lanes: Array[Node] = get_nodes_in_group("td_lane")
		_check("TD map: exactly 2 lanes", lanes.size() == 2)
		var lanes_ok: bool = lanes.size() == 2
		var doors: Array[Node] = get_nodes_in_group("spawn_door")
		var core_markers: Array[Node] = get_nodes_in_group("td_core")
		if not core_markers.is_empty():
			core_pos = (core_markers[0] as Node3D).global_position
		for lane in lanes:
			var wps: Array[Node] = []
			for c in (lane as Node).get_children():
				if c is Marker3D:
					wps.append(c)
			_check("TD lane %s: >=3 waypoints" % str(lane.name), wps.size() >= 3)
			if wps.size() >= 3:
				# Waypoint0 (lane head) sits at a spawn door; last
				# waypoint sits at the core. Waves spawn at lane heads
				# and the lane-shaped navmesh carries them to the core.
				var head := (wps[0] as Node3D).global_position
				var head_at_door := false
				for d in doors:
					if (d as Node3D).global_position.distance_to(head) < 4.0:
						head_at_door = true
				_check("TD lane %s: head waypoint at a spawn door" % str(lane.name), head_at_door)
				var tail := (wps[wps.size() - 1] as Node3D).global_position
				_check("TD lane %s: tail waypoint at the core" % str(lane.name),
					tail.distance_to(core_pos) < 4.0)
				lanes_ok = lanes_ok and head_at_door and tail.distance_to(core_pos) < 4.0
		_check("TD map: spawn doors at lane heads (2)", doors.size() == 2)
		var spots: Array[Node] = get_nodes_in_group("td_build_spot")
		_check("TD map: 8 build spots", spots.size() == 8)
		_check("TD map: 1 core marker", core_markers.size() == 1)
		_check("TD map: player spawns present", get_nodes_in_group("player_spawn").size() >= 1)
		# Static helpers read the same groups the mode reads.
		var static_lanes: Array = td_script.lane_waypoints(self)
		_check("TowerDefenseMode.lane_waypoints: 2 lanes", static_lanes.size() == 2)
		if static_lanes.size() == 2:
			_check("TowerDefenseMode.lane_waypoints: lane waypoint counts",
				(static_lanes[0] as Array).size() >= 3 and (static_lanes[1] as Array).size() >= 3)
		_check("TowerDefenseMode.build_spots: 8", td_script.build_spots(self).size() == 8)
		_check("TD lanes: distinct paths (not the same lane twice)",
			lanes_ok and (static_lanes.size() == 2
				and not (static_lanes[0] as Array).is_empty()
				and not (static_lanes[1] as Array).is_empty()
				and str(static_lanes[0][0]) != str(static_lanes[1][0])))

	# ---- 2. Forge gate: allowlist ------------------------------------------
	_check("Gate: pure check allows tower_defense",
		gate_script.can_build_for_mode("tower_defense"))
	for blocked in ["tdm", "zombies", "survival", "domination", "endless", "base_defense", "bogus_mode", ""]:
		_check("Gate: pure check blocks '%s'" % blocked,
			not gate_script.can_build_for_mode(blocked))
	# No live run -> gate permits (menus / tools / tests).
	mode_mgr_script.live_mode = ""
	_check("Gate: no live run -> permits", gate_script.can_build())
	# Live runs: TD allows, everything else blocks.
	mode_mgr_script.live_mode = "tower_defense"
	_check("Gate: live TD run -> allows", gate_script.can_build())
	for blocked in ["tdm", "zombies", "survival", "base_defense"]:
		mode_mgr_script.live_mode = blocked
		_check("Gate: live '%s' run -> blocks" % blocked, not gate_script.can_build())
	mode_mgr_script.live_mode = ""

	# ---- 3. Forge pipeline gated --------------------------------------------
	_forge_result.clear()
	mode_mgr_script.live_mode = "tdm"
	if forge != null:
		forge.call("submit_prompt", "build a wall")
		_check("Forge pipeline: submit_prompt BLOCKED in live TDM",
			_forge_result.size() == 1 and _forge_result[0][0] == false
			and str(_forge_result[0][1]) == gate_script.BLOCK_MESSAGE)
		_forge_result.clear()
		forge.call("build_from_code", "AAAAAAAAAAAAAAAA")
		_check("Forge pipeline: build_from_code BLOCKED in live TDM",
			_forge_result.size() == 1 and _forge_result[0][0] == false)
		_forge_result.clear()
		forge.call("build_spec_direct", {"action": "spawn", "target": "cover",
			"spec_version": 1, "cost": 0, "params": {}})
		_check("Forge pipeline: build_spec_direct BLOCKED in live TDM",
			_forge_result.size() == 1 and _forge_result[0][0] == false)
		var make_res: Dictionary = forge.call("apply_make", {}, "make a box")
		_check("Forge pipeline: apply_make BLOCKED in live TDM",
			not bool(make_res.get("ok", true)))
		mode_mgr_script.live_mode = "zombies"
		_forge_result.clear()
		forge.call("submit_prompt", "build a wall")
		_check("Forge pipeline: submit_prompt BLOCKED in live Zombies",
			_forge_result.size() == 1 and _forge_result[0][0] == false)
	mode_mgr_script.live_mode = ""

	# ---- 4. Forge menu cannot open outside TD -------------------------------
	# The menu gates in open(): blocked modes -> stays invisible.
	mode_mgr_script.live_mode = "tdm"
	var menu_script := load("res://scripts/ui/forge_menu.gd") as GDScript
	var menu := menu_script.new() as Control
	root.add_child(menu)
	menu.call("open")
	_check("Forge menu: open() refused in live TDM", not bool(menu.call("is_open")))
	mode_mgr_script.live_mode = "tower_defense"
	menu.call("open")
	_check("Forge menu: open() allowed in live TD", bool(menu.call("is_open")))
	menu.call("close")
	_check("Forge menu: close() hides", not bool(menu.call("is_open")))
	menu.queue_free()
	mode_mgr_script.live_mode = ""

	# ---- 5. TD mode: phases, leaks, run end ---------------------------------
	# TowerDefenseMode with a live GameModeManager in TD mode.
	var mgr: Node = mode_mgr_script.new()
	root.add_child(mgr)
	mgr.call("start", "tower_defense")
	var td: Node = null
	for c in mgr.get_children():
		if c is Node and str(c.get_script().resource_path) == "res://scripts/modes/tower_defense.gd":
			td = c
			break
	_check("GameModeManager.start(TD): TowerDefenseMode child added", td != null)
	if td != null:
		_check("TD mode: phase starts as build", str(td.get("phase")) == "build")
		_check("TD mode: core at TD map core marker",
			(td.get("core_pos") as Vector3).distance_to(core_pos) < 1.0)
		_check("TD mode: core HP full", float(td.get("core_hp")) == td_script.CORE_MAX_HP)
		td.connect("tower_defense_over", _on_td_over)
		# Build phase allows building: the gate permits in live TD.
		_check("TD build phase: Forge gate allows building", gate_script.can_build())
		# Combat: wave starts -> combat phase; a leaker at the core
		# damages the core and is destroyed at the gate.
		td.call("_on_wave_started", 1)
		_check("TD mode: wave start -> combat phase",
			str(td.get("phase")) == "combat" and int(td.get("wave")) == 1)
		var hp_before := float(td.get("core_hp"))
		var foe := FakeEnemy.new()
		foe.position = core_pos
		foe.add_to_group("enemy")
		root.add_child(foe)
		td.call("_tick_leaks")
		_check("TD leak: core HP falls when an enemy reaches it",
			float(td.get("core_hp")) == hp_before - td_script.leak_damage_for(1))
		_check("TD leak: leaker destroyed at the core",
			foe.dead and foe.take_damage_calls == 1)
		# A distant enemy does NOT leak.
		var far := FakeEnemy.new()
		far.position = core_pos + Vector3(0, 0, 40)
		far.add_to_group("enemy")
		root.add_child(far)
		hp_before = float(td.get("core_hp"))
		td.call("_tick_leaks")
		_check("TD leak: distant enemy does not leak",
			float(td.get("core_hp")) == hp_before and not far.dead)
		# Wave cleared -> build phase again (via signal handler).
		td.call("_on_wave_cleared", 1)
		_check("TD mode: wave cleared counts + bonus path",
			int(td.get("waves_survived")) == 1)
		td.call("_on_build_phase_started", 20)
		_check("TD mode: build phase resumes after wave",
			str(td.get("phase")) == "build")
		# Run ends when the core falls.
		td.call("_on_wave_started", 2)
		td.call("_damage_core", 100000.0)
		_check("TD mode: core at 0 -> run over",
			str(td.get("phase")) == "over" and float(td.get("core_hp")) == 0.0)
		_check("TD mode: tower_defense_over emitted", _td_over.size() == 1)
		# Pure leak-damage scaling.
		_check("TD leak damage: wave 1 = 100",
			is_equal_approx(td_script.leak_damage_for(1), 100.0))
		_check("TD leak damage: wave 11 = 150 (+5%/wave)",
			is_equal_approx(td_script.leak_damage_for(11), 150.0))
		foe.queue_free()
		far.queue_free()
	mgr.queue_free()
	mode_mgr_script.live_mode = ""

	# ---- 6. Traversal: exactly-one choice ------------------------------------
	_check("Traversal: exactly 3 tools",
		(setup_script.TOOLS as Array).size() == 3)
	_check("Traversal: tool set is grapple/jetpack/portal (player.gd ids)",
		(setup_script.TOOLS as Array).has("grapple")
		and (setup_script.TOOLS as Array).has("jetpack")
		and (setup_script.TOOLS as Array).has("portal"))
	_check("Traversal: default is grapple", setup_script.get_tool() == "grapple")
	_check("Traversal: set jetpack",
		setup_script.set_tool("jetpack") and setup_script.get_tool() == "jetpack")
	_check("Traversal: exactly one — picking grapple replaces jetpack",
		setup_script.set_tool("grapple") and setup_script.get_tool() == "grapple"
		and setup_script.get_tool() != "jetpack")
	_check("Traversal: invalid id rejected, selection unchanged",
		not setup_script.set_tool("bogus_tool") and setup_script.get_tool() == "grapple")
	_check("Traversal: empty id rejected",
		not setup_script.set_tool("") and setup_script.get_tool() == "grapple")
	# Wiring: player WITH the movement API receives exactly one call.
	var fp := FakePlayer.new()
	setup_script.set_tool("portal")
	_check("Traversal: apply_to_player via set_traversal_tool API",
		setup_script.apply_to_player(fp)
		and fp.traversal_calls.size() == 1 and fp.traversal_calls[0] == "portal")
	# Wiring: player WITHOUT the API -> false, no crash, choice stored.
	var fp_noapi := FakePlayerNoApi.new()
	setup_script.set_tool("jetpack")
	_check("Traversal: apply_to_player without API returns false, keeps choice",
		not setup_script.apply_to_player(fp_noapi) and setup_script.get_tool() == "jetpack")
	_check("Traversal: apply_to_player(null) returns false",
		not setup_script.apply_to_player(null))
	# Persistence round-trip on a scratch path (never the real save).
	var test_path := "user://td_setup_verify_test.json"
	setup_script.set_tool("portal")
	_check("Traversal: save_selection writes",
		setup_script.save_selection(test_path))
	setup_script.set_tool("grapple")
	_check("Traversal: load_selection restores",
		setup_script.load_selection(test_path) == "portal"
		and setup_script.get_tool() == "portal")
	DirAccess.remove_absolute(test_path)
	# UI: radio behaviour + confirm emits exactly the chosen tool.
	var setup_ui := setup_script.new() as Control
	root.add_child(setup_ui)
	var confirmed: Array = []
	setup_ui.connect("setup_confirmed", func(t: String) -> void: confirmed.append(t))
	setup_ui.call("open")
	_check("Traversal UI: opens", bool(setup_ui.call("is_open")))
	setup_ui.call("_on_tool_pressed", "jetpack")
	_check("Traversal UI: pressing jetpack selects exactly jetpack",
		setup_script.get_tool() == "jetpack")
	setup_ui.call("_on_tool_pressed", "grapple")
	_check("Traversal UI: pressing grapple replaces jetpack",
		setup_script.get_tool() == "grapple")
	setup_ui.call("_on_confirm_pressed")
	_check("Traversal UI: confirm emits setup_confirmed with the one choice",
		confirmed.size() == 1 and confirmed[0] == "grapple")
	_check("Traversal UI: confirm closes", not bool(setup_ui.call("is_open")))
	setup_ui.queue_free()
	# TD mode applies the stored choice to the player at run start.
	setup_script.set_tool("portal")
	var fp2 := FakePlayer.new()
	fp2.add_to_group("player")
	root.add_child(fp2)
	var td2: Node = td_script.new()
	root.add_child(td2)
	_check("TD mode: applies stored traversal choice to the player",
		fp2.traversal_calls.size() == 1 and fp2.traversal_calls[0] == "portal")
	td2.queue_free()
	fp2.queue_free()
	# Restore default for any later process state.
	setup_script.set_tool("grapple")
	mode_mgr_script.live_mode = ""

	# ---- Nav stage (deferred) ----------------------------------------------
	# The NavigationServer only answers path queries after it has
	# synced the baked region (a later frame), so the nav checks run
	# in _nav_stage() after two physics frames. The map stays alive
	# until then (freed in _nav_stage).
	_launched = true  # _process polls _nav_tick() from here on

# Deferred nav checks (see _run_checks tail): path queries need the
# NavigationServer to have synced the baked region, which happens on
# later frames — so _nav_tick polls until the query answers (or the
# watchdog gives up). The block below is the nav proof from section 1.
func _nav_tick() -> void:
	if _nav_done or _nav_map == null or not is_instance_valid(_nav_map):
		_nav_done = true
		_finish()
		return
	var nav_regions: Array[Node] = []
	for c in _nav_map.find_children("*", "NavigationRegion3D", true, false):
		nav_regions.append(c)
	if not _nav_region_checked:
		_nav_region_checked = true
		_check("TD map: nav region baked", not nav_regions.is_empty())
	if nav_regions.is_empty():
		_nav_done = true
		_finish()
		return
	var region := nav_regions[0] as NavigationRegion3D
	var map_rid: RID = region.get_navigation_map()
	var north_path: PackedVector3Array = NavigationServer3D.map_get_path(
		map_rid, Vector3(0, 0, -56), Vector3(0, 0, 0), true, 1)
	if north_path.is_empty() and _frames < 120:
		return  # NavigationServer has not synced the region yet; retry.
	# Nav proof: a path queried on the baked navmesh from a lane
	# head to the core must follow the lane's BEND (north lane
	# bends west, x < -10; south lane bends east, x > 10) — a
	# straight-line cut would stay near x == 0. This is what
	# makes WaveManager spawns (at lane heads, homing on a
	# player at the core) actually travel the lanes.
	var min_north_x := 0.0
	for p in north_path:
		min_north_x = minf(min_north_x, p.x)
	_check("TD nav: north lane path follows the west bend (min x < -10)",
		min_north_x < -10.0)
	var south_path: PackedVector3Array = NavigationServer3D.map_get_path(
		map_rid, Vector3(0, 0, 56), Vector3(0, 0, 0), true, 1)
	var max_south_x := 0.0
	for p in south_path:
		max_south_x = maxf(max_south_x, p.x)
	_check("TD nav: south lane path follows the east bend (max x > 10)",
		max_south_x > 10.0)
	if _nav_map != null and is_instance_valid(_nav_map):
		_nav_map.queue_free()
	_nav_done = true
	_finish()


func _finish() -> void:
	print("----")
	print("Tower Defense: %d checks, %d failures" % [_checks, _fails])
	_done = true
	quit(0 if _fails == 0 else 1)
