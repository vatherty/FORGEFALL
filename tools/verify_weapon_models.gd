extends SceneTree

var _frames := 0

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	var arsenal = load("res://scripts/weapons/arsenal.gd")
	var ids := ["ar7", "lr8", "sg12", "smg9", "p9", "br3", "hv44", "raptor", "lmg", "ember", "launcher"]
	var failures := 0
	for id in ids:
		var view: Node3D = arsenal.call("build_viewmodel", id)
		if view == null or view.get_node_or_null("Muzzle") == null or view.get_node_or_null("Eject") == null:
			printerr("FAIL missing imported model or anchor: ", id)
			failures += 1
			continue
		var model := view.get_child(0)
		if not model is Node3D or model.name != "AuxScene":
			printerr("FAIL procedural fallback used: ", id)
			failures += 1
			view.free()
			continue
		print("PASS %s imported, sight %.3f, muzzle %s" % [id, arsenal.call("sight_height", id), view.get_node("Muzzle").position])
		view.free()
	# Every shipped attachment should import as a real scene before a
	# generated recipe tries to assemble it.
	var module_ids := [
		"optic_iron", "optic_reflex", "optic_scope",
		"muzzle_brake", "muzzle_suppressor", "muzzle_launcher_cup",
		"magazine_box", "magazine_drum", "stock_solid", "stock_folding",
		"accent_heat_shield", "accent_hazard_stripe", "accent_stencil",
	]
	for module_id in module_ids:
		var path := "res://assets/models/weapons/attachments/%s.glb" % module_id
		var packed := load(path) as PackedScene
		if packed == null:
			printerr("FAIL attachment import: ", module_id)
			failures += 1
			continue
		var part := packed.instantiate() as Node3D
		if part == null or part.get_child_count() == 0:
			printerr("FAIL empty attachment: ", module_id)
			failures += 1
		if part != null:
			part.free()
	print("Checked %d imported attachment variants" % module_ids.size())
	var idea := {"display_name": "Taquito Launcher", "description": "oversized muzzle, drum, hazard stripes"}
	var family: String = arsenal.call("visual_family_for", idea, "p9")
	if family != "launcher":
		printerr("FAIL generated launcher selected ", family)
		failures += 1
	var mod_view: Node3D = arsenal.call("build_viewmodel", "p9", idea)
	for module_id in ["muzzle_launcher_cup", "magazine_drum", "accent_hazard_stripe"]:
		var part := mod_view.get_node_or_null("Module_" + module_id) as Node3D
		if part == null:
			printerr("FAIL generated module missing: ", module_id)
			failures += 1
			continue
		var anchor_name := "Muzzle" if module_id.begins_with("muzzle_") else ("Grip" if module_id.begins_with("magazine_") else "Barrel")
		var anchor := mod_view.get_node_or_null(anchor_name) as Node3D
		var expected_mount := anchor.position if anchor != null else Vector3.ZERO
		if module_id == "muzzle_launcher_cup":
			expected_mount.z += 0.218
		if anchor == null or not part.position.is_equal_approx(expected_mount):
			printerr("FAIL generated module mount: ", module_id)
			failures += 1
	print("Checked Taquito Launcher body, modules, and mount positions")
	mod_view.free()
	var weapon: Node3D = arsenal.call("make_weapon", "p9")
	weapon.call("set_visual_recipe", idea)
	var weapon_view: Node3D = weapon.get("_viewmodel")
	if weapon_view == null or weapon_view.name != "VM_launcher" or weapon_view.get_node_or_null("Muzzle") == null:
		printerr("FAIL live weapon visual swap")
		failures += 1
	else:
		var muzzle := weapon_view.get_node("Muzzle") as Marker3D
		if not is_equal_approx(muzzle.position.z, -0.681 - 0.218):
			printerr("FAIL launcher cup did not move firing origin to the visible muzzle")
			failures += 1
		weapon.call("_show_muzzle_flash")
		var flash: Node3D = weapon.get("_flash_quad")
		if flash == null or not flash.position.is_equal_approx(muzzle.position):
			printerr("FAIL live muzzle flash location")
			failures += 1
		else:
			print("PASS live P9 gameplay weapon swapped to launcher visual and muzzle")
	weapon.free()
	quit(1 if failures > 0 else 0)
	return true
