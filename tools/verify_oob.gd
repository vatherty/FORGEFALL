# verify_oob.gd — headless verification for bug-bash BB-7 (out of bounds).
# Usage: godot --headless --path <project> --script res://tools/verify_oob.gd
#
# Colin's report: "on almost all maps you can fly off and not die."
# His spec, three parts: (1) leaving the map kills you, (2) geometry
# extends as far as the eye can see (no visible world edge), (3) the
# mechanism is Black Ops 3 / Battlefield — cross the boundary, a
# countdown starts, return in time or die.
#
# Part A (maps): dustline + cinder_city scenes register play bounds in
# the "map_play_bounds" group, the bounds contain EVERY player_spawn
# marker, and a GroundApron (mesh + collision, >= 600 m) exists.
# Part B (player): a synthetic arena + a MapBuilderBase bounds provider.
#   - Real physics: standing inside = no countdown; stepping out starts
#     it (~10 s, alive); stepping back clears it fully.
#   - Direct calls (physics off, the BB-3 pattern): 3 s out leaves ~7 s;
#     flying ABOVE the bounds top also counts as out; the full countdown
#     kills through the real death path (died signal, _dead set); death
#     clears the OOB state; respawn resets it.
#   - Kill floor: below bounds.min.y - 25 dies on the first check, timer
#     or not. With NO bounds provider: no countdown anywhere, y = -50
#     is survivable, y < -100 dies.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _passes := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	call_deferred("run")


func _mk_box(parent: Node, pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var s := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	s.shape = box
	b.add_child(s)
	b.position = pos
	parent.add_child(b)
	return b


func run() -> void:
	await _part_a_maps()
	await _part_b_player()
	print("VERIFY(out of bounds): %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


# ---------------------------------------------------------------- Part A

func _part_a_maps() -> void:
	for key in ["dustline", "cinder_city"]:
		var arena := Node3D.new()
		arena.name = "VerifyMap_" + key
		root.add_child(arena)
		var map = load("res://scenes/maps/" + key + ".tscn").instantiate()
		arena.add_child(map)
		for i in 6:
			await process_frame
		_check(bool(map.get("has_play_bounds")), key + ": map registers play bounds")
		_check(map.is_in_group("map_play_bounds"), key + ": map is in group map_play_bounds")
		var bounds: AABB = map.get("play_bounds")
		print("INFO: ", key, " play_bounds = ", bounds)
		_check(bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0,
			key + ": bounds are non-empty")
		var spawns := get_nodes_in_group("player_spawn")
		_check(not spawns.is_empty(), key + ": player_spawn markers exist (%d)" % spawns.size())
		var all_in := true
		for s in spawns:
			if not bounds.has_point((s as Node3D).global_position):
				all_in = false
				printerr("  spawn outside bounds: ", (s as Node3D).global_position)
		_check(all_in, key + ": EVERY spawn point is inside the play bounds")
		var apron = map.get_node_or_null("GroundApron")
		_check(apron != null, key + ": GroundApron node exists")
		if apron != null:
			_check(apron.get_node_or_null("ApronMesh") != null, key + ": apron mesh exists")
			var cs = apron.get_node_or_null("ApronCollision/ApronShape")
			_check(cs != null and (cs as CollisionShape3D).shape is BoxShape3D,
				key + ": apron collision exists (BoxShape3D)")
			if cs != null and (cs as CollisionShape3D).shape is BoxShape3D:
				var sz := ((cs as CollisionShape3D).shape as BoxShape3D).size
				_check(sz.x >= 600.0 and sz.z >= 600.0,
					key + ": apron collision size %.0f x %.0f m (>= 600)" % [sz.x, sz.z])
		arena.queue_free()
		await process_frame
		await process_frame


# ---------------------------------------------------------------- Part B

func _part_b_player() -> void:
	var arena := Node3D.new()
	arena.name = "VerifyOOBArena"
	root.add_child(arena)
	_mk_box(arena, Vector3(0.0, -0.5, 0.0), Vector3(200.0, 1.0, 200.0))  # floor, top y=0
	var provider := MapBuilderBase.new()
	provider.name = "BoundsProvider"
	arena.add_child(provider)
	var bounds := AABB(Vector3(-20, -10, -20), Vector3(40, 70, 40))  # top y=60, kill floor y=-35
	provider.set_play_bounds(bounds)

	var player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	player.name = "Player"
	arena.add_child(player)
	var oob_events: Array = []
	var died_events: Array = []
	player.connect("oob_changed", func(a: bool, s: float) -> void: oob_events.append([a, s]))
	player.connect("died", func() -> void: died_events.append(1))
	await physics_frame
	await physics_frame

	# --- real physics: inside is quiet ---
	player.position = Vector3(0, 1.0, 0)
	player.velocity = Vector3.ZERO
	for i in 12:
		await physics_frame
	_check(not bool(player.get("_oob_active")), "physics: standing inside bounds starts no countdown")
	_check(bool(player.call("is_alive")), "physics: alive inside bounds")

	# --- real physics: stepping out starts the countdown ---
	player.position = Vector3(30, 1.0, 0)  # 10 m past the +x face
	for i in 30:
		await physics_frame
	_check(bool(player.get("_oob_active")), "physics: stepping out of bounds starts the countdown")
	var left := float(player.call("get_oob_seconds_left"))
	_check(left > 8.5 and left < 10.0, "physics: ~10 s on the clock after 0.5 s out (got %.2f)" % left)
	_check(bool(player.call("is_alive")), "physics: still alive mid-countdown")
	_check(not oob_events.is_empty() and bool(oob_events[oob_events.size() - 1][0]),
		"physics: oob_changed(active=true) emitted for the HUD")

	# --- real physics: stepping back clears it fully ---
	player.position = Vector3(0, 1.0, 0)
	for i in 6:
		await physics_frame
	_check(not bool(player.get("_oob_active")), "physics: re-entering clears the countdown")
	_check(not oob_events.is_empty() and not bool(oob_events[oob_events.size() - 1][0]),
		"physics: oob_changed(active=false) emitted on re-entry")

	# --- direct calls from here (physics off; deltas are exact) ---
	player.set_physics_process(false)
	await process_frame

	# 3 s out leaves ~7 s, still alive.
	player.position = Vector3(30, 1.0, 0)
	player.call("_update_oob", 0.016)  # first call starts the countdown
	_check(bool(player.get("_oob_active")), "direct: first outside check starts the countdown")
	_check(absf(float(player.call("get_oob_seconds_left")) - 10.0) < 0.01,
		"direct: countdown starts at 10.0 s (got %.2f)" % float(player.call("get_oob_seconds_left")))
	player.call("_update_oob", 3.0)
	_check(absf(float(player.call("get_oob_seconds_left")) - 7.0) < 0.05,
		"direct: 3 s out leaves ~7 s (got %.2f)" % float(player.call("get_oob_seconds_left")))
	_check(bool(player.call("is_alive")), "direct: alive at 7 s left")
	# Back inside resets fully.
	player.position = Vector3(0, 1.0, 0)
	player.call("_update_oob", 0.016)
	_check(not bool(player.get("_oob_active")), "direct: re-entry resets the countdown fully")

	# Above the top counts as out (jetpack / grapple fly-ups).
	player.position = Vector3(0, 61.0, 0)  # bounds top is y=60
	player.call("_update_oob", 0.016)
	_check(bool(player.get("_oob_active")), "direct: flying ABOVE the bounds top starts the countdown")
	player.position = Vector3(0, 1.0, 0)
	player.call("_update_oob", 0.016)
	_check(not bool(player.get("_oob_active")), "direct: dropping back in clears it")

	# Full countdown kills through the real death path.
	var died_before := died_events.size()
	player.position = Vector3(30, 1.0, 0)
	player.call("_update_oob", 0.016)
	player.call("_update_oob", 9.0)
	_check(bool(player.call("is_alive")), "direct: alive with 1 s left")
	player.call("_update_oob", 1.5)
	_check(not bool(player.call("is_alive")), "direct: countdown expiry KILLS the player")
	_check(died_events.size() > died_before, "direct: death flowed through the real died signal")
	_check(not bool(player.get("_oob_active")), "direct: death clears the OOB state")

	# Respawn resets everything.
	player.call("respawn", Vector3(0, 1.0, 0))
	_check(bool(player.call("is_alive")), "respawn: player is alive again")
	_check(not bool(player.get("_oob_active")), "respawn: no countdown on a fresh life")

	# Kill floor: below bounds.min.y - 25 dies on the first check.
	player.position = Vector3(0, -36.0, 0)  # floor is at -10 - 25 = -35
	player.call("_update_oob", 0.016)
	_check(not bool(player.call("is_alive")), "kill floor: below bounds.min.y - 25 dies instantly")
	player.call("respawn", Vector3(0, 1.0, 0))

	# No bounds provider: no countdown anywhere; absolute floor only.
	provider.queue_free()
	await process_frame
	await process_frame
	player.set("_bounds_provider", null)
	player.set("_bounds_valid", false)
	player.position = Vector3(500, 1.0, 500)  # way outside any map
	player.call("_update_oob", 0.016)
	_check(bool(player.call("is_alive")) and not bool(player.get("_oob_active")),
		"no bounds: far outside starts NO countdown (Studio/custom maps)")
	player.position = Vector3(0, -50.0, 0)
	player.call("_update_oob", 0.016)
	_check(bool(player.call("is_alive")), "no bounds: y = -50 is survivable")
	player.position = Vector3(0, -101.0, 0)
	player.call("_update_oob", 0.016)
	_check(not bool(player.call("is_alive")), "no bounds: y < -100 dies (absolute kill floor)")
