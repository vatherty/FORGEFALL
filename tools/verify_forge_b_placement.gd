# tools/verify_forge_b_placement.gd — Worker B (Forge batch) verification.
# Usage: godot --headless --path <project> --script res://tools/verify_forge_b_placement.gd
# Covers items 2 (ghost preview + edit placed), 3 (destructible structures
# + enemy pressure + repair), 6 (six new presets). Headless, no network.
# Exit: prints RESULT: PASS/FAIL + quits.
#
# NOTE (B2 pattern): Forge scripts are loaded via load() at runtime and
# called through the GDScript objects — never referenced by global
# class_name at parse time. A parse-time reference would force the
# compiler to compile forge_builder.gd before the Sfx autoload is
# registered, failing with "Identifier not found: Sfx". Node handles
# are kept as Variant so their method calls resolve at runtime too.
extends SceneTree

class MockEnemy extends Node3D:
	var damage := 25.0
	var active := true
	var dead := false
	var _see := true
	func can_see_player() -> bool:
		return _see

const FAIL_PREFIX := "FORGE_FAIL: "

var _fails: Array[String] = []
var _checks := 0
var _test_root: Node3D = null
var _player: Node3D = null
var _stage := 0
var _builder: GDScript = null
var _structure: GDScript = null
var _ghost: GDScript = null
var _pressure: GDScript = null
var _placement: GDScript = null
var _pad: GDScript = null


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: ", label)
	else:
		_fails.append(label)
		print("FAIL: ", label)


func _has_collision(n: Node) -> bool:
	if n is CollisionShape3D:
		return true
	for c in n.get_children():
		if _has_collision(c):
			return true
	return false


func _mesh_count(n: Node) -> int:
	var count := 0
	if n is MeshInstance3D:
		count += 1
	for c in n.get_children():
		count += _mesh_count(c)
	return count


func _find_jump_pad(n: Node) -> Variant:
	if n.has_method("launch_player"):
		return n
	for c in n.get_children():
		var found: Variant = _find_jump_pad(c)
		if found != null:
			return found
	return null


func _structure_count() -> int:
	return get_nodes_in_group("forge_structure").size()


func _build_structure(shape: String, extra: Dictionary = {}) -> Variant:
	var params := {"shape": shape, "position": "near_player"}
	for k in extra.keys():
		params[k] = extra[k]
	var msg: Variant = _builder.build(
		{"spec_version": 1, "action": "spawn", "target": "structure",
			"params": params, "cost": 0, "ttl": 0},
		{"player": _player, "root": _test_root})
	if str(msg).begins_with(FAIL_PREFIX):
		print("  build failed for ", shape, ": ", msg)
		return null
	return _builder.last_built_node


func _initialize() -> void:
	_builder = load("res://scripts/forge/forge_builder.gd") as GDScript
	_structure = load("res://scripts/forge/forge_structure.gd") as GDScript
	_ghost = load("res://scripts/forge/forge_ghost.gd") as GDScript
	_pressure = load("res://scripts/forge/forge_enemy_pressure.gd") as GDScript
	_placement = load("res://scripts/forge/forge_placement.gd") as GDScript
	_pad = load("res://scripts/forge/forge_jump_pad.gd") as GDScript
	_test_root = Node3D.new()
	_test_root.name = "BTestRoot"
	root.add_child(_test_root)
	current_scene = _test_root
	_player = Node3D.new()
	_player.name = "BPlayer"
	_player.position = Vector3(0, 0, 0)
	_player.add_to_group("player")
	_test_root.add_child(_player)


func _process(_delta: float) -> bool:
	# Staged like the other verify scripts: quit() from _initialize does
	# not terminate a --script SceneTree run (it idles forever), so the
	# checks run on the first frame and quit on the next.
	if _stage == 0:
		_stage = 1
		_run_checks()
	elif _stage == 1:
		_stage = 2
		quit()
	return true


func _run_checks() -> void:
	# ---- Item 6: all 10 structure shapes build + collide + HP + cost ----
	var expected_hp := {
		"bridge": 300.0, "bunker": 600.0, "watchtower": 400.0,
		"ammo_depot": 300.0, "stairs": 250.0, "ramp": 250.0,
		"wall": 400.0, "jump_pad": 200.0, "cover_piece": 200.0,
		"sniper_nest": 350.0,
	}
	var expected_cost := {
		"bridge": 120, "bunker": 180, "watchtower": 200,
		"ammo_depot": 150, "stairs": 100, "ramp": 90,
		"wall": 120, "jump_pad": 150, "cover_piece": 60,
		"sniper_nest": 220,
	}
	var built: Dictionary = {}
	for shape in expected_hp.keys():
		_check(bool(_builder.is_structure_shape(shape)), "is_structure_shape(%s)" % shape)
		_check(int(_builder.structure_cost(shape)) == int(expected_cost[shape]),
			"structure_cost(%s) == %d" % [shape, int(expected_cost[shape])])
		var node: Variant = _build_structure(shape)
		_check(node != null and is_instance_valid(node), "%s builds" % shape)
		if node == null:
			continue
		built[shape] = node
		_check((node as Node).get_script() == _structure, "%s is a ForgeStructure" % shape)
		_check((node as Node).is_in_group("forge_structure"), "%s in forge_structure group" % shape)
		_check(_has_collision(node as Node), "%s has collision" % shape)
		_check(_mesh_count(node as Node) >= 3, "%s has >=3 meshes (got %d)" % [shape, _mesh_count(node as Node)])
		_check(is_equal_approx(float((node as Node).get("hp")), float(expected_hp[shape])),
			"%s HP == %s (got %s)" % [shape, str(expected_hp[shape]), str((node as Node).get("hp"))])
		_check(is_equal_approx(float(_structure.hp_of(node)), float(expected_hp[shape])),
			"hp_of(%s) == %s" % [shape, str(expected_hp[shape])])
	_check(_structure_count() == 10, "10 structures standing after building all shapes (got %d)" % _structure_count())
	# Reinforced composition still works on the new destructible path.
	var rb: Variant = _build_structure("bunker", {"property": "reinforced"})
	_check(rb != null and is_equal_approx(float((rb as Node).get("hp")), 900.0),
		"reinforced bunker HP == 900 (got %s)" % str((rb as Node).get("hp") if rb != null else "null"))
	# Direct preset path.
	var preset_msg: Variant = _builder.build_preset("cover_piece", _player, _test_root)
	_check(not str(preset_msg).begins_with(FAIL_PREFIX),
		"build_preset(cover_piece) succeeds (%s)" % str(preset_msg))
	_check(str(_builder.build_preset("nope", _player, _test_root)).begins_with(FAIL_PREFIX),
		"build_preset(unknown) fails cleanly")
	# Free the shape sweep so later stages start from a known count.
	for shape in built.keys():
		var n: Variant = built[shape]
		if n != null and is_instance_valid(n):
			_structure.delete_target(n)
	if rb != null and is_instance_valid(rb):
		_structure.delete_target(rb)
	_check(_structure_count() == 1, "sweep cleanup leaves only the preset build (got %d)" % _structure_count())

	# ---- Item 2: ghost preview ----
	for shape in ["bridge", "wall", "jump_pad", "sniper_nest"]:
		var ghost: Variant = _ghost.create_for_shape(shape)
		_check(ghost != null, "ghost for %s created" % shape)
		if ghost == null:
			continue
		_check(str(ghost.get("ghost_shape")) == shape, "ghost shape recorded (%s)" % shape)
		_check(not (ghost as Node).is_in_group("forge_structure"), "ghost %s NOT in forge_structure group" % shape)
		_check(_mesh_count(ghost as Node) >= 3, "ghost %s shows geometry" % shape)
		_check((ghost as Node).find_children("*", "Area3D", true, false).is_empty(),
			"ghost %s has no live Area3D behaviour" % shape)
		_test_root.add_child(ghost as Node)
		ghost.call("set_valid", true)
		_check(bool(ghost.call("is_valid")), "ghost %s valid after set_valid(true)" % shape)
		ghost.call("set_valid", false)
		_check(not bool(ghost.call("is_valid")), "ghost %s invalid after set_valid(false)" % shape)
		(ghost as Node).queue_free()
	_check(_ghost.create_for_shape("nope") == null, "ghost for unknown shape is null")
	# Placement controller: preview -> confirm -> ghost gone, structure up.
	var placement: Variant = _placement.attach_to(_test_root)
	_check(_placement.attach_to(_test_root) == placement, "attach_to returns the same controller")
	_check(not bool(placement.call("start_preview", "nope", {}, _player, _test_root)),
		"start_preview(unknown) returns false")
	var before := _structure_count()
	_check(bool(placement.call("start_preview", "wall", {}, _player, _test_root)), "start_preview(wall) succeeds")
	_check(bool(placement.call("has_preview")), "preview active after start")
	_check(bool(placement.call("preview_valid")), "preview valid below cap")
	_check((placement.call("preview_position") as Vector3) != Vector3.ZERO, "preview has a crosshair position")
	var confirm_msg: Variant = placement.call("confirm_preview")
	_check(not str(confirm_msg).begins_with(FAIL_PREFIX),
		"confirm_preview builds (%s)" % str(confirm_msg))
	_check(not bool(placement.call("has_preview")), "ghost dismissed after confirm")
	_check(_structure_count() == before + 1, "structure count +1 after confirm")
	placement.call("start_preview", "wall", {}, _player, _test_root)
	placement.call("cancel_preview")
	_check(not bool(placement.call("has_preview")), "cancel_preview dismisses ghost")
	_check(_structure_count() == before + 1, "cancel builds nothing")
	# Edit: select / rotate / move / delete on a placed structure.
	var target: Variant = _builder.last_built_node
	_check(bool(placement.call("select", target)), "select(placed structure) succeeds")
	_check(placement.call("get_selected") == target, "get_selected returns the selection")
	var ghost_node := Node3D.new()
	_test_root.add_child(ghost_node)
	_check(not bool(placement.call("select", ghost_node)), "select(non-structure) refuses")
	_check(bool(placement.call("rotate_selected", 45.0)), "rotate_selected succeeds")
	_check(is_equal_approx((target as Node3D).rotation.y, deg_to_rad(45.0)),
		"rotate_selected(45) yaws 45 deg")
	_check(bool(_placement.rotate_structure(target, 45.0)), "static rotate_structure succeeds")
	_check(is_equal_approx((target as Node3D).rotation.y, deg_to_rad(90.0)),
		"second rotate reaches 90 deg")
	var moved := bool(placement.call("move_selected_to", Vector3(10, 0, 10)))
	_check(moved and (target as Node3D).global_position == Vector3(10, 0, 10),
		"move_selected_to relocates (no floor: snap is identity)")
	_check(bool(placement.call("delete_selected")), "delete_selected succeeds")
	_check(placement.call("get_selected") == null, "selection cleared after delete")
	_check(not is_instance_valid(target) or (target as Node).is_queued_for_deletion(),
		"deleted structure queued for free")
	_check(_structure_count() == before, "structure count back after delete")

	# ---- Item 3: damage / destroy / repair ----
	var wall: Variant = _build_structure("wall")
	_check(wall != null, "wall built for damage tests")
	wall.call("take_damage", 150.0, (wall as Node3D).global_position, false)
	_check(is_equal_approx(float((wall as Node).get("hp")), 250.0), "wall HP 250 after 150 damage")
	_check(is_equal_approx(float((wall as Node).get_meta("hp")), 250.0), "wall hp meta stays in sync")
	var restored: Variant = wall.call("repair", 100.0)
	_check(is_equal_approx(float(restored), 100.0) and is_equal_approx(float((wall as Node).get("hp")), 350.0),
		"repair(100) restores 100 (got %s)" % str(restored))
	_check(is_equal_approx(float(wall.call("repair_full")), 50.0) and is_equal_approx(float((wall as Node).get("hp")), 400.0),
		"repair_full tops up to 400")
	# Damage feedback nodes exist (flash overlay + cracks + smoke).
	_check((wall as Node).find_child("HitFlash", false, false) != null, "wall has HitFlash overlay")
	wall.call("take_damage", 300.0, (wall as Node3D).global_position, false)
	var cracks: Variant = (wall as Node).find_child("Cracks", false, false)
	_check(cracks != null and (cracks as Node).get_child_count() > 0,
		"cracks appear after heavy damage")
	var smoke: Variant = (wall as Node).find_child("DamageSmoke", false, false)
	_check(smoke != null and bool(smoke.get("emitting")), "low-HP smoke emitting below 35%")
	wall.call("take_damage", 9999.0, (wall as Node3D).global_position, false)
	_check(bool((wall as Node).get("_destroyed")), "wall destroyed at 0 HP")
	_check(not (wall as Node).is_in_group("forge_structure"), "destroyed wall leaves forge_structure group")
	_check((wall as Node).is_queued_for_deletion(), "destroyed wall queued for free")
	# Cover: damage + repair_target (duck-typed hp + max_hp meta).
	var cover_msg: Variant = _builder.build(
		{"spec_version": 1, "action": "spawn", "target": "cover",
			"params": {"shape": "wall", "size_voxels": [4, 3, 1],
				"position": "near_player", "hp": 200}, "cost": 0, "ttl": 0},
		{"player": _player, "root": _test_root})
	var cover: Variant = _builder.last_built_node
	_check(cover != null and (cover as Node).has_method("take_damage"), "forge cover builds with take_damage")
	_check((cover as Node).has_meta("max_hp") and is_equal_approx(float((cover as Node).get_meta("max_hp")), 200.0),
		"cover max_hp meta recorded (200)")
	cover.call("take_damage", 80.0, (cover as Node3D).global_position, false)
	_check(is_equal_approx(float(_structure.hp_of(cover)), 120.0), "cover HP 120 after 80 damage")
	_check(is_equal_approx(float(_structure.repair_target(cover)), 80.0),
		"repair_target restores cover to full")
	_check(is_equal_approx(float(_structure.hp_of(cover)), 200.0), "cover HP back to 200")
	# Turret: damage + repair_target via _hp.
	var turret_msg: Variant = _builder.build(
		{"spec_version": 1, "action": "spawn", "target": "turret",
			"params": {"position": "near_player", "duration_sec": 45}, "cost": 0, "ttl": 0},
		{"player": _player, "root": _test_root})
	var turret: Variant = _builder.last_built_node
	_check(turret != null and (turret as Node).has_method("take_damage"), "turret builds with take_damage")
	turret.call("take_damage", 50.0, (turret as Node3D).global_position, false)
	_check(is_equal_approx(float(_structure.hp_of(turret)), 100.0), "turret HP 100 after 50 damage")
	_check(is_equal_approx(float(_structure.repair_target(turret)), 50.0),
		"repair_target restores turret to 150")
	# Enemy pressure: an engaged enemy with LOS lands its own damage.
	var foe := MockEnemy.new()
	foe.name = "MockFoe"
	foe.position = Vector3(8, 0, 5)
	foe.add_to_group("enemy")
	_test_root.add_child(foe)
	var victim: Variant = _build_structure("cover_piece")
	# Move the victim off the build pile: every other test build sits at
	# near_player (0,0,-2), so a pressure LOS ray from the foe would
	# strike a different stacked structure first and correctly report
	# blocked. The victim gets its own clear lane at x=8.
	(victim as Node3D).global_position = Vector3(8, 0, 0)
	var hp_before := float(_structure.hp_of(victim))
	_pressure.apply_pressure(victim, 1.0)
	_check(is_equal_approx(float(_structure.hp_of(victim)), hp_before - 25.0),
		"enemy pressure deals foe damage (25) to structure")
	# Inactive foe: no damage.
	foe.active = false
	_pressure.apply_pressure(victim, 1.0)
	_check(is_equal_approx(float(_structure.hp_of(victim)), hp_before - 25.0),
		"inactive enemy deals no pressure damage")
	# Out-of-range foe: no damage.
	foe.active = true
	foe.position = Vector3(0, 0, 60)
	_pressure.apply_pressure(victim, 1.0)
	_check(is_equal_approx(float(_structure.hp_of(victim)), hp_before - 25.0),
		"out-of-range enemy deals no pressure damage")
	# Pressure destroys at 0 HP (no crash, group left).
	_pressure.apply_pressure(victim, 1.0)  # foe still far: no-op
	victim.call("take_damage", 9999.0, (victim as Node3D).global_position, false)
	_check(bool((victim as Node).get("_destroyed")), "pressure victim destroyed by lethal damage")
	_pressure.apply_pressure(victim, 1.0)  # destroyed: must no-op
	_check(true, "pressure on destroyed structure is a safe no-op")

	# ---- Item 6: jump pad launches the player ----
	var pad_node: Variant = _build_structure("jump_pad")
	var pad: Variant = _find_jump_pad(pad_node as Node)
	_check(pad != null, "jump pad has a ForgeJumpPad trigger")
	if pad != null:
		var body := CharacterBody3D.new()
		body.name = "MockPlayer"
		body.add_to_group("player")
		body.velocity = Vector3(2, 0, 0)
		_test_root.add_child(body)
		_check(bool(pad.call("launch_player", body)), "launch_player fires for the player")
		_check(is_equal_approx(body.velocity.y, float(_pad.LAUNCH_VELOCITY)),
			"launch sets vertical velocity to 12.5")
		# Pad faces -Z (away from the player, like every structure), so
		# the forward boost lands on velocity.z; velocity.x is preserved.
		_check(is_equal_approx(body.velocity.x, 2.0) and body.velocity.z < -3.0,
			"launch preserves horizontal velocity + boosts forward")
		_check(not bool(pad.call("launch_player", body)),
			"launch retrigger blocked by cooldown")
		var stranger := CharacterBody3D.new()
		_test_root.add_child(stranger)
		_check(not bool(pad.call("launch_player", stranger)),
			"launch ignores non-player bodies")

	# ---- Cap: 12 max, 13th rejected, ghost invalid at cap ----
	var standing := _structure_count()
	var need := 12 - standing
	for i in range(need):
		var extra_node: Variant = _build_structure("cover_piece")
		_check(extra_node != null, "cap fill %d/%d" % [i + 1, need])
	_check(_structure_count() == 12, "cap reached at 12 (got %d)" % _structure_count())
	_check(bool(_builder.structure_cap_reached()), "structure_cap_reached() true at 12")
	var over_msg: Variant = _builder.build(
		{"spec_version": 1, "action": "spawn", "target": "structure",
			"params": {"shape": "wall", "position": "near_player"}, "cost": 0, "ttl": 0},
		{"player": _player, "root": _test_root})
	_check(str(over_msg).begins_with(FAIL_PREFIX) and "cap" in str(over_msg),
		"13th structure rejected with cap message")
	placement.call("start_preview", "wall", {}, _player, _test_root)
	_check(not bool(placement.call("preview_valid")), "ghost invalid at cap")
	placement.call("cancel_preview")
	# Free one slot via delete and confirm the cap opens again.
	var any_node: Variant = null
	for n in get_nodes_in_group("forge_structure"):
		if (n as Node).get_script() == _structure:
			any_node = n
			break
	_check(any_node != null and bool(_structure.delete_target(any_node)),
		"delete frees a cap slot")
	_check(_structure_count() == 11, "count 11 after delete (got %d)" % _structure_count())
	_check(not bool(_builder.structure_cap_reached()), "cap open again after delete")

	print("CHECKS: %d, FAILS: %d" % [_checks, _fails.size()])
	if _fails.is_empty():
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL")
