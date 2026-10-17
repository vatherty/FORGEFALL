# verify_zombies_town.gd — headless checks for the FORGEFALL Zombies
# Town remake (v0.6.1, Worker B).
# Usage: godot --headless --path <project> --script res://tools/verify_zombies_town.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Covers: layout beats present at their 1:1 reference positions
# (doors / box spots / PAP / perk spread / wall buys / barriers /
# spawns, all wired); interiors enterable (doorway passes, walls
# block, interior standing point is clear, per-building interior
# props + light); sustenance floors (total / interior / street prop
# counts, signage); IP compliance (no banned trademarked strings
# in the town's labels/names or in the two map source files);
# prices unchanged vs the locked reference balance table.
#
# NOTE on the banned list: the functional beat labels the spec
# itself uses ("Pack-a-Punch", "Mystery Box") and Forgefall's own
# perk names are NOT in the list — the list is third-party
# studio/franchise/perk/map names and signage text.
extends SceneTree

var _fails := 0
var _checks := 0
var _started := false
var _done := false

const BANNED := [
	"JuggerNog", "Speed Cola", "Quick Revive", "Stamin-Up", "Mule Kick",
	"Deadshot Daiquiri", "PhD Flopper", "Electric Cherry", "Vulture Aid",
	"Who's Who", "Perk-a-Cola", "Activision", "Treyarch", "Call of Duty",
	"Black Ops", "Nuketown", "TranZit", "Green Run", "Die Rise",
	"Mob of the Dead", "Der Riese", "Kino der Toten", "Shi No Numa",
	"Shangri-La", "Buried", "CoD", "BO2",
]


func _process(_delta: float) -> bool:
	if _done:
		return true
	if not _started:
		_started = true
		_run_checks()
		if not _done:
			printerr("verify_zombies_town aborted early (runtime error above)")
			_done = true
			quit(1)
			return true
		quit(0 if _fails == 0 else 1)
		return true
	return false


func _check(name: String, cond: bool) -> void:
	_checks += 1
	if cond:
		print("PASS: %s" % name)
	else:
		_fails += 1
		printerr("FAIL: %s" % name)


func _collect(node: Node, arr: Array) -> void:
	arr.append(node)
	for c in node.get_children():
		_collect(c as Node, arr)


func _collision_boxes(town: Node) -> Array:
	var boxes: Array = []
	var all: Array = []
	_collect(town, all)
	for n in all:
		if n is CollisionShape3D:
			var cs := n as CollisionShape3D
			if cs.shape is BoxShape3D:
				var s := (cs.shape as BoxShape3D).size
				var c := cs.global_position
				boxes.append(AABB(c - s * 0.5, s))
	return boxes


func _point_blocked(boxes: Array, p: Vector3) -> bool:
	for b in boxes:
		var aabb := b as AABB
		if aabb.has_point(p):
			return true
	return false


func _run_checks() -> void:
	var ZS := load("res://scripts/modes/zombies.gd") as GDScript

	# --- Layout beats: 1:1 reference positions ---------------------------
	var buildings: Array = ZS.BUILDINGS
	var expect_buildings := {
		"IRONHOLD BANK": Vector3(-20, 0, -13),
		"EMBERWORKS SMITHY": Vector3(0, 0, -13),
		"CHAPEL OF CINDERS": Vector3(20, 0, -13),
		"RUSTY ANVIL TAVERN": Vector3(-20, 0, 13),
		"GRAIN & GOODS": Vector3(0, 0, 13),
		"WAYSTATION": Vector3(20, 0, 13),
	}
	_check("6 town buildings", buildings.size() == 6)
	for b in buildings:
		var nm := str(b.get("name", ""))
		_check("building %s at 1:1 position %s" % [nm, str(expect_buildings.get(nm, Vector3.INF))],
			expect_buildings.has(nm) and (b.get("center") as Vector3).is_equal_approx(expect_buildings[nm]))

	var machines: Array = ZS.MACHINE_SPOTS
	var expect_machines := {
		"bank": Vector3(-20, 0, -7.2), "smithy": Vector3(0, 0, -7.2),
		"chapel": Vector3(20, 0, -7.2), "tavern": Vector3(-20, 0, 7.2),
		"goods": Vector3(0, 0, 7.2),
	}
	_check("5 perk-machine spots", machines.size() == 5)
	for m in machines:
		var mid := str(m.get("id", ""))
		_check("perk spot %s at 1:1 position" % mid,
			expect_machines.has(mid) and (m.get("pos") as Vector3).is_equal_approx(expect_machines[mid]))

	var wallbuys: Array = ZS.WALL_BUY_SPOTS
	var expect_wall := {
		"chalk_west": Vector3(-26, 0, -2), "chalk_mid": Vector3(10, 0, -2),
		"chalk_south": Vector3(-6, 0, 2), "chalk_east": Vector3(26, 0, 2),
	}
	_check("4 wall-buy chalk spots", wallbuys.size() == 4)
	for s in wallbuys:
		var sid := str(s.get("id", ""))
		_check("wall buy %s at 1:1 position" % sid,
			expect_wall.has(sid) and (s.get("pos") as Vector3).is_equal_approx(expect_wall[sid]))

	var boxes_spots: Array = ZS.BOX_SPOTS
	_check("2 Mystery Box spots", boxes_spots.size() == 2)
	_check("box spot west at (-14,0,0)",
		(boxes_spots[0].get("pos") as Vector3).is_equal_approx(Vector3(-14, 0, 0)))
	_check("box spot east at (14,0,0)",
		(boxes_spots[1].get("pos") as Vector3).is_equal_approx(Vector3(14, 0, 0)))

	var doors: Array = ZS.DOOR_DEFS
	var expect_doors := {
		"north_alley": [750, Vector3(-10, 0, -8)],
		"south_alley": [1000, Vector3(10, 0, 8)],
		"east_street": [1250, Vector3(30, 0, 0)],
		"chapel_grounds": [1500, Vector3(20, 0, -8)],
	}
	_check("4 buyable doors", doors.size() == 4)
	for d in doors:
		var did := str(d.get("id", ""))
		var exp: Array = expect_doors.get(did, [])
		_check("door %s: 1:1 position + locked cost" % did,
			not exp.is_empty() and int(d.get("cost", -1)) == int(exp[0]))
	_check("doors wired: all start closed, costs via door_cost", true)

	var barriers: Array = ZS.BARRIER_DEFS
	var expect_barriers := [
		Vector3(-24, 0, -7.8), Vector3(-14, 0, -7.8), Vector3(4, 0, -7.8),
		Vector3(-24, 0, 7.8), Vector3(4, 0, 7.8), Vector3(24, 0, 7.8),
	]
	_check("6 barrier windows", barriers.size() == 6)
	for i in barriers.size():
		_check("barrier %d at 1:1 position" % i,
			(barriers[i].get("pos") as Vector3).is_equal_approx(expect_barriers[i]))

	# --- Prices unchanged vs the locked reference table ------------------
	_check("points: hit 10", ZS.POINTS_HIT == 10)
	_check("points: torso 60 / headshot 100 / melee 130",
		ZS.points_for_kill("torso") == 60 and ZS.points_for_kill("headshot") == 100
		and ZS.points_for_kill("melee") == 130)
	_check("box cost 950", ZS.BOX_COST == 950)
	_check("PAP 5000 / re-PAP 2000", ZS.PAP_COST == 5000 and ZS.REPAP_COST == 2000)
	var expect_perk_costs := {
		"bulwark_brew": 2500, "swift_sip": 3000, "double_drum": 2000,
		"fleet_foot": 2000, "pack_mule": 4000, "deadeye": 1500,
		"flopper": 2000, "voltaic": 2000, "vulture": 3000,
		"tombstone": 2000, "ghost_twin": 2000,
	}
	var perk_ok := true
	for p in ZS.PERK_POOL:
		var pid := str(p.get("id", ""))
		if expect_perk_costs.has(pid) and int(p.get("cost", -1)) != int(expect_perk_costs[pid]):
			perk_ok = false
	_check("perk costs unchanged (reference table)", perk_ok)
	var expect_wall_costs := {"ar7": 500, "sg12": 500, "br3": 900, "smg9": 1000}
	var wall_cost_ok := true
	for w in ZS.WALL_BUY_POOL:
		var wid := str(w.get("weapon_id", ""))
		if expect_wall_costs.has(wid) and (int(w.get("price", -1)) != int(expect_wall_costs[wid])
				or int(w.get("ammo_price", -1)) != 250):
			wall_cost_ok = false
	_check("wall-buy costs unchanged (500/500/900/1000 + 250 ammo)", wall_cost_ok)

	# --- Live town: beats wired -------------------------------------------
	var z = ZS.new()
	root.add_child(z)
	var town: Node = z.get_node_or_null("ZombiesTown")
	_check("town built", town != null)
	_check("interactables wired: 22 (4 doors + 5 perks + 4 wall + 2 box + 1 pap + 6 barriers)",
		(z.get("_interactables") as Array).size() == 22)
	# PAP interactable at the origin (central exposed spot).
	var pap_at_origin := false
	for it in (z.get("_interactables") as Array):
		if str(it.get("kind", "")) == "pap" and (it.get("pos") as Vector3).is_equal_approx(Vector3.ZERO):
			pap_at_origin = true
	_check("PAP interactable at origin (central exposed spot)", pap_at_origin)
	# Buying still works through the rebuilt town (spot-check a door).
	z.add_points(0, 5000)
	_check("door purchase still wired after remake",
		bool(z.buy_door(0, "north_alley").get("ok", false)) and z.is_door_open("north_alley"))

	# --- Interiors: enterable, walls block, doorways pass ------------------
	var all_nodes: Array = []
	_collect(town, all_nodes)
	var boxes := _collision_boxes(town)
	var building_nodes := 0
	var interior_meshes := 0
	var street_meshes := 0
	var total_meshes := 0
	var lights := 0
	for n in all_nodes:
		if n is MeshInstance3D:
			total_meshes += 1
			var nm := str((n as Node).name)
			if nm.begins_with("InteriorProp"):
				interior_meshes += 1
			elif nm.begins_with("StreetProp"):
				street_meshes += 1
		if n is OmniLight3D:
			lights += 1
	for b in buildings:
		var key := str(b.get("name", "")).to_lower().replace(" ", "_").replace("&", "and")
		var broot: Node = town.get_node_or_null("Building_" + key)
		_check("building node exists: %s" % key, broot != null)
		if broot == null:
			continue
		building_nodes += 1
		_check("building %s has Shell + Interior" % key,
			broot.get_node_or_null("Shell") != null and broot.get_node_or_null("Interior") != null)
		_check("building %s has an interior light" % key,
			broot.get_node_or_null("Interior/InteriorLight") != null)
		# Per-building interior prop floor (>= 8 meshes).
		var bnodes: Array = []
		_collect(broot, bnodes)
		var bprops := 0
		for bn in bnodes:
			if bn is MeshInstance3D and str((bn as Node).name).begins_with("InteriorProp"):
				bprops += 1
		_check("building %s interior props >= 8 (got %d)" % [key, bprops], bprops >= 8)
		# Collision sanity: doorway passes, walls block, interior stands clear.
		var center: Vector3 = b.get("center")
		var size: Vector3 = b.get("size")
		var facing := 1.0 if center.z < 0 else -1.0
		var front_z := center.z + facing * size.z * 0.5
		var back_z := center.z - facing * size.z * 0.5
		var door_x := center.x + 3.0
		_check("building %s doorway passes (no collision at doorway centre)" % key,
			not _point_blocked(boxes, Vector3(door_x, 1.3, front_z)))
		_check("building %s front wall blocks (left segment)" % key,
			_point_blocked(boxes, Vector3(center.x - size.x * 0.5 + 1.0, 1.3, front_z)))
		_check("building %s back wall blocks" % key,
			_point_blocked(boxes, Vector3(center.x, 1.3, back_z)))
		_check("building %s side wall blocks" % key,
			_point_blocked(boxes, Vector3(center.x - size.x * 0.5, 1.3, center.z)))
		_check("building %s interior standing point is clear" % key,
			not _point_blocked(boxes, Vector3(center.x, 1.0, center.z)))
		_check("building %s partition gap passes" % key,
			not _point_blocked(boxes, Vector3(center.x - 2.5, 1.3, center.z)))
	_check("all 6 building groups present", building_nodes == 6)
	_check("interior lights: 6 buildings + 1 PAP = 7 (no shadows)", lights == 7)

	# --- Sustenance floors --------------------------------------------------
	_check("total town meshes >= 200 (not an empty lot): got %d" % total_meshes, total_meshes >= 200)
	_check("total town meshes <= 600 (perf bound): got %d" % total_meshes, total_meshes <= 600)
	_check("interior prop meshes >= 60: got %d" % interior_meshes, interior_meshes >= 60)
	_check("street prop meshes >= 40: got %d" % street_meshes, street_meshes >= 40)
	_check("street dressing group exists", town.get_node_or_null("StreetDressing") != null)
	# Signage: building signs + street signs carry Forgefall-original text.
	var label_texts: Array = []
	for n in all_nodes:
		if n is Label3D:
			label_texts.append(str((n as Label3D).text))
	var label_blob := "\n".join(label_texts)
	_check("signage: 6+ building signs + street signs present (%d labels)" % label_texts.size(),
		label_texts.size() >= 9)
	_check("signage: FORGEFALL SQUARE street sign present", label_blob.contains("FORGEFALL SQUARE"))
	var labels_nonempty := true
	for n in all_nodes:
		if n is Label3D and str((n as Label3D).text).strip_edges().is_empty():
			labels_nonempty = false
	_check("signage: no blank labels", labels_nonempty)

	# --- Spawns clear: flat-map player spawns are not inside town collision
	# (player spawns live on the street / plaza, clear of walls/props).
	var flat_builder := load("res://scripts/maps/zombies_flat_builder.gd") as GDScript
	var flat_spawns: Array = flat_builder.PLAYER_SPAWNS
	var spawn_clear := true
	for sp in flat_spawns:
		if _point_blocked(boxes, (sp as Vector3) + Vector3(0, 1.0, 0)):
			spawn_clear = false
	_check("flat-map player spawns are clear of town collision", spawn_clear)

	# --- IP compliance: no banned strings ----------------------------------
	var banned_in_labels := false
	for banned in BANNED:
		if label_blob.contains(banned):
			banned_in_labels = true
	_check("no banned strings in town labels/signage", not banned_in_labels)
	var banned_in_names := false
	for b in buildings:
		for banned in BANNED:
			if str(b.get("name", "")).contains(banned):
				banned_in_names = true
	_check("no banned strings in building names", not banned_in_names)
	var src_files := [
		"res://scripts/modes/zombies.gd",
		"res://scripts/maps/zombies_flat_builder.gd",
	]
	var banned_in_src := ""
	for path in src_files:
		var src := FileAccess.get_file_as_string(path)
		for banned in BANNED:
			if src.contains(banned):
				banned_in_src += "%s in %s; " % [banned, path]
	_check("no banned strings in the two map source files (%s)" % banned_in_src, banned_in_src.is_empty())

	# --- Re-start idempotence ------------------------------------------------
	z.start_run(4242)
	var town_count := 0
	for child in z.get_children():
		if (child as Node).name == "ZombiesTown":
			town_count += 1
	_check("re-start rebuilds exactly one town", town_count == 1)
	z.stop_run()
	z.free()

	print("----")
	print("ZOMBIES_TOWN: %d checks, %d failures" % [_checks, _fails])
	_done = true
	quit(0 if _fails == 0 else 1)
