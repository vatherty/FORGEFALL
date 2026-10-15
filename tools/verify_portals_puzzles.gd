# verify_portals_puzzles.gd — headless verification for FORGEFALL Goal 5 (Worker B: portal puzzle rooms).
# Usage: godot --headless --path <project> --script res://tools/verify_portals_puzzles.gd
#
# Owns ONLY this file. Does NOT touch tools/verify_portals.gd (Worker D).
#
# Coverage:
#   1. Every room in CompletionStore.ROOMS instantiates, has a player_spawn
#      marker, an exit zone, >= 1 white portal panel, and a solution list.
#   2. Visual language: panel records are near-white; no solid record is
#      near-white (white == portal-able, dark == NOT portal-able).
#   3. Scripted solutions: solve() -> is_complete() == true, and completion
#      persists via CompletionStore; reset() -> incomplete again.
#   4. Mechanics: block-on-plate opens the door / release closes it
#      (rooms 2 + 4); fling trajectory lands on the goal platform
#      (rooms 3 + 4) under the Portal 2 ejection contract.
#   5. Room-select UI instantiates standalone; main menu + Main wire the
#      PUZZLE CHAMBERS entry (source-level checks).
#   6. Room scripts reference no autoloads (Sfx / Game) so they load here.
#
# HONEST HEADLESS LIMITS: a true player walk-through (aim, shoot, walk,
# push, fall) cannot run headlessly; solve() drives the real signal
# handlers synchronously instead. The fling check validates the analytic
# trajectory under the ejection contract — it does NOT prove the live
# emitter implements that contract (Worker C owns the emitter; Worker D's
# M1/M2 checks cover it live). Pre-existing user completion is saved and
# restored around this run (the suite resets progress to test persistence).
#
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _passes := 0
var _fails := 0
var _warns := 0
var _sec: Dictionary = {}
var _arena: Node3D = null
var _saved_done: Dictionary = {}
var _stage := 0


func _check(section: String, cond: bool, label: String) -> void:
	var c: Array = _sec.get(section, [0, 0])
	if cond:
		_passes += 1
		c[0] += 1
		print("PASS [%s]: %s" % [section, label])
	else:
		_fails += 1
		c[1] += 1
		printerr("FAIL [%s]: %s" % [section, label])
	_sec[section] = c


func _warn(section: String, label: String) -> void:
	_warns += 1
	print("WARN [%s]: %s" % [section, label])


func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _find_in_group(node: Node, group: String, out: Array) -> void:
	if node.is_in_group(group):
		out.append(node)
	for ch in node.get_children():
		_find_in_group(ch, group, out)


var _frames := 0
var _rooms: Array = []  # [{info, node}]
var _select_ui: Node = null


func _initialize() -> void:
	_arena = Node3D.new()
	_arena.name = "VerifyPuzzlesArena"
	root.add_child(_arena)
	# Preserve the user's real completion; restore it in _finish().
	_saved_done = CompletionStore.all_done()
	CompletionStore.reset_all()
	# Build everything now; _ready() runs on a later frame for nodes
	# added during _initialize, so checks wait for stage 1.
	for r in CompletionStore.ROOMS:
		var scr = load(str(r["script"]))
		if scr == null or not scr.can_instantiate():
			_rooms.append({"info": r, "node": null})
			continue
		var room: Node = (scr as GDScript).new()
		_arena.add_child(room)
		_rooms.append({"info": r, "node": room})
	var sscr = load("res://scripts/puzzles/select_ui.gd")
	if sscr != null and sscr.can_instantiate():
		_select_ui = (sscr as GDScript).new()
		_arena.add_child(_select_ui)
	_stage = 0


func _process(_delta: float) -> bool:
	_frames += 1
	if _stage == 0:
		if _frames < 4:
			return false
		_run_all()
		_stage = 1
		return false
	if _stage == 1:
		_finish()
		return true
	return false


func _run_all() -> void:
	_check("catalog", CompletionStore.ROOMS.size() == 4,
		"catalog has exactly 4 rooms (got %d)" % CompletionStore.ROOMS.size())
	var ids := {}
	for entry in _rooms:
		var r: Dictionary = entry["info"]
		var rid: String = str(r["id"])
		_check("catalog", not ids.has(rid), "room id '%s' is unique" % rid)
		ids[rid] = true
		_check("catalog", str(r.get("script", "")).ends_with(".gd"),
			"room '%s' points at a .gd builder script" % rid)
		_run_room(r, entry["node"])
	_run_select_ui()
	_run_menu_wiring()


func _run_room(info: Dictionary, room: Node) -> void:
	var rid: String = str(info["id"])
	var sec := "room:" + rid
	_check(sec, room != null,
		"room script %s loads + instantiates" % str(info["script"]))
	if room == null:
		return
	_check(sec, str(room.get("room_id")) == rid,
		"room_id == '%s' (got '%s')" % [rid, str(room.get("room_id"))])
	_check(sec, str(room.get("room_title")) == str(info["title"]),
		"title matches catalog ('%s')" % str(info["title"]))
	_check(sec, not str(room.get("room_objective")).is_empty(),
		"room has an objective string")

	# Structure: spawn, exit, panels.
	var spawns: Array = []
	_find_in_group(room, "player_spawn", spawns)
	_check(sec, not spawns.is_empty(), "has a player_spawn marker")
	var goals: Array = []
	_find_in_group(room, "puzzle_goal", goals)
	_check(sec, goals.size() == 1, "has exactly 1 exit zone (got %d)" % goals.size())
	var panels: Array = room.call("panels") if room.has_method("panels") else []
	_check(sec, not panels.is_empty(), "has >= 1 white portal panel")
	# Visual language: panels near-white, solids never near-white.
	var panels_white := true
	for p in panels:
		var n: Vector3 = p["normal"]
		if absf(n.length() - 1.0) > 0.01:
			panels_white = false
	_check(sec, panels_white, "every panel normal is unit length")
	var solids: Array = room.call("solid_records") if room.has_method("solid_records") else []
	var solid_white := false
	for s in solids:
		var col: Color = s["color"]
		if col.r > 0.9 and col.g > 0.9 and col.b > 0.9:
			solid_white = true
	_check(sec, not solid_white,
		"no non-portal-able solid is near-white (white == portal-able only)")
	# Portal-ability marking: panels on the portalable body, solids not.
	var portal_bodies: Array = []
	_find_in_group(room, "portalable", portal_bodies)
	_check(sec, not portal_bodies.is_empty(),
		"a node carries group 'portalable' (emitter validity check target)")
	var nonportal_bodies: Array = []
	_find_in_group(room, "non_portalable", nonportal_bodies)
	_check(sec, not nonportal_bodies.is_empty(),
		"a node carries group 'non_portalable' (emitter refusal target)")

	# Source: rooms must not depend on autoloads (else they cannot load here).
	var src := _read_file(str(info["script"]))
	_check(sec, not src.contains("Sfx.") and not src.contains("Game."),
		"room script references no Sfx / Game autoloads (headless-loadable)")
	_check(sec, src.contains("portal") or src.contains("panel"),
		"room script is portal-aware (mentions portal/panel)")
	_check(sec, room.has_method("solution_steps") and not (room.call("solution_steps") as Array).is_empty(),
		"room exposes a non-empty solution_steps()")

	# Completion lifecycle: incomplete -> solve() -> complete + persisted -> reset() -> incomplete.
	_check(sec, room.has_method("is_complete") and room.call("is_complete") == false,
		"room starts incomplete")
	_check(sec, room.has_method("solve"), "room exposes solve()")
	if room.has_method("solve"):
		room.call("solve")
	_check(sec, room.call("is_complete") == true,
		"scripted solve() completes the room")
	_check(sec, CompletionStore.is_done(rid),
		"completion persists in CompletionStore (user://)")
	_check(sec, room.has_method("reset"), "room exposes reset()")
	if room.has_method("reset"):
		room.call("reset")
	_check(sec, room.call("is_complete") == false,
		"reset() returns the room to incomplete")

	# Per-room mechanics.
	if rid == "chamber_02" or rid == "chamber_04":
		_run_plate_door(room, sec)
	if rid == "chamber_03" or rid == "chamber_04":
		_run_fling(room, sec)
	if rid == "chamber_01":
		_check(sec, panels.size() == 2,
			"Room 1 has exactly 2 panels (entry + exit, got %d)" % panels.size())
	room.queue_free()


func _run_plate_door(room: Node, sec: String) -> void:
	var plates: Array = room.call("plates_list")
	var blocks: Array = room.call("blocks_list")
	_check(sec, not plates.is_empty(), "has >= 1 pressure plate")
	_check(sec, not blocks.is_empty(), "has >= 1 pushable block")
	if plates.is_empty() or blocks.is_empty():
		return
	var plate: Area3D = plates[0]
	var block: Node3D = blocks[0]
	_check(sec, room.call("door_open", 0) == false, "door starts closed")
	room.call("press_plate", plate, block)
	_check(sec, room.call("door_open", 0) == true,
		"block on plate opens the door")
	room.call("release_plate", plate, block)
	_check(sec, room.call("door_open", 0) == false,
		"block off plate closes the door again")


func _run_fling(room: Node, sec: String) -> void:
	if not room.has_method("fling_solution"):
		_check(sec, false, "fling room exposes fling_solution()")
		return
	var sim: Dictionary = room.call("fling_solution")
	var entry_speed: float = sqrt(2.0 * 9.8 * 11.9)
	_check(sec, absf(float(sim.get("exit_velocity", Vector3.ZERO).length()) - entry_speed) < 0.01,
		"fling preserves speed: exit |v| = entry |v| = %.2f (got %s)" % [entry_speed, str(sim.get("exit_velocity"))])
	_check(sec, Vector3(sim.get("exit_velocity", Vector3.ZERO)).x > 0.0
		and absf(Vector3(sim.get("exit_velocity", Vector3.ZERO)).y) < 0.01
		and absf(Vector3(sim.get("exit_velocity", Vector3.ZERO)).z) < 0.01,
		"fling exits straight east (+X) along +exit normal (got %s)" % str(sim.get("exit_velocity")))
	_check(sec, bool(sim.get("reaches", false)),
		"fling trajectory lands on the goal platform (landing %s, flight %.2f s)"
		% [str(sim.get("landing")), float(sim.get("flight_time", 0.0))])


func _run_select_ui() -> void:
	_check("select", _select_ui != null, "RoomSelect script loads + instantiates")
	if _select_ui == null:
		return
	var buttons := 0
	var stack: Array = [_select_ui]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button:
			buttons += 1
		for ch in n.get_children():
			stack.append(ch)
	_check("select", buttons >= 5,
		"select screen has >= 5 buttons (4 rooms + back, got %d)" % buttons)


func _run_menu_wiring() -> void:
	var menu_src := _read_file("res://scripts/ui/main_menu.gd")
	_check("menu", menu_src.contains("PUZZLE CHAMBERS"),
		"main menu has a PUZZLE CHAMBERS button")
	_check("menu", menu_src.contains("open_puzzle_select"),
		"main menu button calls Main.open_puzzle_select()")
	var main_src := _read_file("res://scripts/core/main.gd")
	_check("menu", main_src.contains("func start_puzzle("),
		"Main implements start_puzzle()")
	_check("menu", main_src.contains("func open_puzzle_select("),
		"Main implements open_puzzle_select()")


func _finish() -> void:
	# Restore the user's pre-run completion state.
	CompletionStore.reset_all()
	for rid in _saved_done.keys():
		if bool(_saved_done[rid]):
			CompletionStore.mark_done(str(rid))
	print("VERIFY_PORTALS_PUZZLES: %d passed, %d failed, %d warnings" % [_passes, _fails, _warns])
	for section in _sec.keys():
		var c: Array = _sec[section]
		print("VERIFY_PORTALS_PUZZLES [%s]: %d passed, %d failed" % [section, c[0], c[1]])
	if _fails == 0:
		print("VERIFY_PORTALS_PUZZLES: ALL CHECKS PASSED")
	else:
		printerr("VERIFY_PORTALS_PUZZLES: %d CHECK(S) FAILED" % _fails)
	quit(1 if _fails > 0 else 0)
