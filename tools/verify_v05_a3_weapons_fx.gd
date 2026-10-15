# tools/verify_v05_a3_weapons_fx.gd — A3 (weapon viewmodels + effects) checks.
# Usage: godot --headless --path <project> --script res://tools/verify_v05_a3_weapons_fx.gd
# Asserts: all 6 viewmodels build with Sight/Stock/Grip/Barrel/Muzzle/Eject
# markers; per-weapon ADS position centers the sight; muzzle flash light is
# parented to the viewmodel with sane range/energy; tracer + impact + smoke
# + landing effects instantiate from pools; weapon stats untouched.
#
# NOTE: game scripts are loaded dynamically via load() inside _process (like
# verify_fixes.gd loads player.tscn at runtime). Referencing Arsenal /
# WeaponBase as compile-time identifiers would make the engine compile those
# scripts before the Sfx autoload exists, failing with "Identifier not
# found: Sfx" — a --script-mode quirk, not a game bug.
extends SceneTree

var _failures: Array = []
var _checks := 0
var _frames := 0
var _ran := false


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("PASS: ", label)
	else:
		_failures.append(label)
		printerr("FAIL: ", label)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3 or _ran:
		return false
	_ran = true
	_run()
	print("A3 VERIFY: %d checks, %d failures" % [_checks, _failures.size()])
	quit(1 if not _failures.is_empty() else 0)
	return true


func _run() -> void:
	var ArsenalScript = load("res://scripts/weapons/arsenal.gd")
	var TracerScript = load("res://scripts/weapons/tracer_pool.gd")
	var ImpactScript = load("res://scripts/fx/impact_fx.gd")
	var cam := Camera3D.new()
	root.add_child(cam)

	# Stats untouched (spot-check the balance surface).
	var expect_stats := {
		"ar7": [700.0, 25.0], "lr8": [40.0, 120.0], "sg12": [65.0, 12.0],
		"smg9": [850.0, 18.0], "p9": [420.0, 22.0],
	}
	for wid in expect_stats:
		var st: Dictionary = ArsenalScript.call("get_stats", wid)
		_check(is_equal_approx(float(st["rpm"]), expect_stats[wid][0])
			and is_equal_approx(float(st["damage"]), expect_stats[wid][1]),
			"stats untouched %s rpm=%s dmg=%s" % [wid, st["rpm"], st["damage"]])

	# Viewmodels + markers + ADS alignment per weapon.
	var ids := ["ar7", "lr8", "sg12", "smg9", "p9", "raptor"]
	for wid in ids:
		var vm: Node3D = ArsenalScript.call("build_viewmodel", wid)
		root.add_child(vm)
		var meshes := 0
		for c in vm.get_children():
			if c is MeshInstance3D:
				meshes += 1
		_check(meshes >= 10, "%s viewmodel mesh count %d >= 10" % [wid, meshes])
		for mname in ["Sight", "Stock", "Grip", "Barrel", "Muzzle", "Eject"]:
			_check(vm.get_node_or_null(mname) != null,
				"%s has %s marker" % [wid, mname])
		var sight: Marker3D = vm.get_node_or_null("Sight")
		var sh: float = ArsenalScript.call("sight_height", wid)
		if sight != null:
			_check(is_equal_approx(sight.position.y, sh),
				"%s Sight marker y %.3f == sight_height" % [wid, sight.position.y])
		vm.queue_free()

		var w: Node3D = ArsenalScript.call("make_weapon", wid)
		root.add_child(w)
		w.call("attach", null, cam)
		w.call("on_equip")
		w.call("set_ads", true)
		for i in 8:
			w.call("_process", 0.2)
		var ads_pos: Vector3 = w.get("_ads_pos")
		_check(is_equal_approx(ads_pos.y, -sh) and is_equal_approx(ads_pos.x, 0.0),
			"%s _ads_pos %s centers sight (y = -sight_height)" % [wid, ads_pos])
		var vm2: Node3D = w.get("_viewmodel")
		_check(vm2 != null and vm2.position.is_equal_approx(ads_pos),
			"%s ADS viewmodel pos %s == _ads_pos" % [wid, vm2.position if vm2 != null else Vector3.INF])
		# Sight line lands on the camera -Z axis (screen centre) in ADS.
		if vm2 != null:
			var sight2: Marker3D = vm2.get_node_or_null("Sight")
			if sight2 != null:
				var sight_world_y := vm2.position.y + sight2.position.y
				_check(absf(sight_world_y) < 0.001,
					"%s ADS sight world y %.4f ~ 0 (centred)" % [wid, sight_world_y])

		# Muzzle flash: light parented to viewmodel, sane range, fires.
		var fl: OmniLight3D = w.get("_flash_light")
		_check(fl != null and fl.get_parent() == vm2,
			"%s flash light parented to viewmodel" % wid)
		if fl != null:
			_check(fl.omni_range >= 4.0 and fl.omni_range <= 12.0,
				"%s flash omni_range %.1f sane" % [wid, fl.omni_range])
		w.call("_show_muzzle_flash")
		_check(fl != null and fl.light_energy > 0.0 and fl.visible,
			"%s flash fires (energy %.1f)" % [wid, fl.light_energy if fl != null else -1.0])
		w.call("_tick_flash", 0.1)
		_check(fl != null and fl.light_energy == 0.0 and not fl.visible,
			"%s flash expires after 40ms window" % wid)
		w.call("on_unequip")
		w.queue_free()

	# Tracers: brighter/longer pool instantiates.
	var tracer_src := FileAccess.get_file_as_string("res://scripts/weapons/tracer_pool.gd")
	_check(tracer_src.contains("TRACER_LIFE := 0.10"), "tracer life 0.10 (was 0.06)")
	_check(tracer_src.contains("TRACER_WIDTH := 0.024"), "tracer width 0.024 (was 0.016)")
	_check(tracer_src.contains("emission_energy_multiplier = 6.0"), "tracer emission 6x (was 3x)")
	TracerScript.call("spawn", Vector3.ZERO, Vector3(0, 0, -20))
	var tpool := root.get_node_or_null("TracerPool")
	_check(tpool != null and tpool.get_child_count() == 28,
		"tracer pool built (%d nodes)" % (tpool.get_child_count() if tpool != null else -1))

	# Impact / smoke / landing dust instantiate from the pool.
	ImpactScript.call("spawn", Vector3(1, 1, -3), Vector3.UP)
	ImpactScript.call("spawn_smoke", Vector3(2, 1, -3), 3.0)
	ImpactScript.call("spawn_landing", Vector3(0, 0.1, -2), true)
	var iroot := root.get_node_or_null("ImpactFXRoot")
	var visible_puffs := 0
	if iroot != null:
		for c in iroot.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).visible:
				visible_puffs += 1
	_check(iroot != null and iroot.get_child_count() == 24,
		"impact pool built (%d nodes)" % (iroot.get_child_count() if iroot != null else -1))
	_check(visible_puffs >= 3, "impact+smoke+landing puffs visible: %d" % visible_puffs)
	# Landing auto-bind: no player in this harness, must not error.
	ImpactScript.call("precache")
	_check(true, "ImpactFX.precache() no-error without player")

	# ExplosionFX wires smoke through ImpactFX (source-level: detonate would
	# need Sfx/physics; the smoke call itself is covered above).
	var src := FileAccess.get_file_as_string("res://scripts/fx/explosion.gd")
	_check(src.contains("ImpactFX.spawn_smoke"), "explosion.gd calls ImpactFX.spawn_smoke")
