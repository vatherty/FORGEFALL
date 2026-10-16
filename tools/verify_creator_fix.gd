# verify_creator_fix.gd — Create-a-Mod fix verification (Forge batch follow-up).
# Usage: godot --headless --path <project> --script res://tools/verify_creator_fix.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Coverage (real handlers/code paths, mock_generation test seam only):
#   llm-path: key present -> real HTTP branch (http outstanding +
#     HTTPRequest child, freed immediately — no response consumed, no
#     silent fallback); simulated HTTP failure -> visible error
#     "generation returned invalid JSON", no fallback mod; no-key ->
#     "DeepSeek key required" error, never an installable candidate.
#   cache: distinct descriptions -> distinct keys; repeat -> HIT + same
#     voxels; normalized variants -> same key; watermelon vs pistol ->
#     different keys/voxels; beam = 6 voxels, bullet = 2, pistol visual
#     still 52 (shape path unchanged).
#   sandbox: pistol case -> projectile desc "glowing laser beam",
#     beam asset, hit, no explosion; watermelon case -> watermelon
#     projectile (flesh + rind), hit + explosion; open() 4-arg shows
#     BOTH projectile (6 children) and weapon visual (52 children) +
#     candidate name; open() 3-arg still works (no weapon visual).
#   watermelon-e2e: mock generation -> installable candidate -> install
#     -> listed + error-free -> sandbox hit + explosion.
#   menu-flow: menu generate (mock) -> candidate + watermelon projectile
#     asset (distinct from weapon visual) -> Install via menu -> row in
#     the Mods list immediately, no restart.
#   layout: Mods tab hint renders horizontal (width >= 40, row < 100px
#     tall), mod list gets real height (> 100px), no visible label
#     narrower than 40px rendering a multi-char string.
# NO persistent state left behind: test cache files + installed test
# mods are removed; mock_generation is reset.
extends SceneTree

var _passes := 0
var _fails := 0
var _sec_pass := {}
var _sec_fail := {}
var _phase := 0
var _pump := 0
var _frames := 0
var _timeout := false

var _gen_result := {}
var _captured: Dictionary = {}
var _creator: ModCreator = null
var _menu: Control = null
var _sandbox1: SandboxTestRoom = null
var _sandbox2: SandboxTestRoom = null
var _installed_id := ""


func _check(section: String, cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		_sec_pass[section] = int(_sec_pass.get(section, 0)) + 1
	else:
		_fails += 1
		_sec_fail[section] = int(_sec_fail.get(section, 0)) + 1
		printerr("FAIL [%s]: %s" % [section, msg])


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > 5000:
		_timeout = true
		_finish()
		return true
	if _pump > 0:
		_pump -= 1
		return false
	match _phase:
		0:
			_cleanup_test_state()
			_phase = 1
		1:
			_test_llm_path()
			_phase = 2
			_pump = 3
		2:
			_test_llm_path_deferred()
			_test_cache()
			_test_sandbox_pure()
			_phase = 3
		3:
			# Watermelon E2E: mock generation -> candidate.
			ModCreator.mock_generation = _watermelon_mock()
			_creator = ModCreator.new()
			_creator.generation_ready.connect(_on_e2e_generation)
			root.add_child(_creator)
			_creator.generate("watermelon lmg test")
			_phase = 4
			_pump = 4
		4:
			_test_e2e_candidate()
			_phase = 5
		5:
			_test_e2e_install()
			# Clean the E2E install up NOW: the menu flow installs the
			# same mock again, and its script hardcodes block_id
			# "watermelon_lmg" — a second install would (correctly,
			# fail-closed) be rejected as a duplicate block_id.
			if not _installed_id.is_empty():
				_delete_mod_folder(_installed_id)
				_installed_id = ""
			_phase = 6
		6:
			# Sandbox open(): 4-arg + 3-arg (needs tree + frames).
			_sandbox1 = SandboxTestRoom.new()
			_sandbox2 = SandboxTestRoom.new()
			root.add_child(_sandbox1)
			root.add_child(_sandbox2)
			_phase = 7
			_pump = 3
		7:
			_test_sandbox_open()
			_phase = 8
		8:
			# Menu flow: generate (mock) -> install -> layout.
			ModCreator.mock_generation = _watermelon_mock()
			_menu = load("res://scenes/ui/mod_creator_menu.tscn").instantiate() as Control
			root.add_child(_menu)
			_phase = 9
			_pump = 2
		9:
			(_menu.find_child("CategoryWeapon", true, false) as CheckButton).button_pressed = true
			(_menu.find_child("ModNameInput", true, false) as LineEdit).text = "Watermelon LMG"
			(_menu.find_child("VisualInput", true, false) as TextEdit).text = "a black LMG with a big hopper"
			(_menu.find_child("LogicInput", true, false) as TextEdit).text = "an LMG that shoots watermelons. The watermelons explode on impact."
			_menu.call("_on_generate_pressed")
			_phase = 10
			_pump = 4
		10:
			_test_menu_generate()
			_menu.call("_on_install_pressed")
			_phase = 11
			_pump = 3
		11:
			_test_menu_install()
			(_menu.find_child("CreatorTabs", true, false) as TabContainer).current_tab = 2
			_phase = 12
			_pump = 3
		12:
			_test_menu_layout()
			_cleanup_test_state()
			_finish()
			_phase = 99
	return false


# --- Section 1: LLM path ------------------------------------------------------

func _test_llm_path() -> void:
	var key_present := not ForgeConfig.load_key().is_empty()
	_check("llm-path", true, "llm-path: probe ran (key_present=%s)" % str(key_present))
	if key_present:
		# Real HTTP branch (freed immediately — no response consumed).
		var llm := ForgeLLM.new()
		root.add_child(llm)
		llm.request_generation("creator fix probe")
		var http_child := false
		for ch in llm.get_children():
			if ch is HTTPRequest:
				http_child = true
		_check("llm-path", bool(llm.get("_generation_http_outstanding")), "llm-path: key present -> HTTP branch taken (_generation_http_outstanding)")
		_check("llm-path", http_child, "llm-path: key present -> HTTPRequest child exists (real LLM call, not fallback)")
		llm.queue_free()
		# Simulated HTTP failure -> visible error, no fallback mod.
		var llm2 := ForgeLLM.new()
		llm2.generation_ready.connect(_on_gen_result)
		root.add_child(llm2)
		var http := HTTPRequest.new()
		root.add_child(http)
		_gen_result = {}
		llm2.call("_on_generation_http_completed", HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray(), http)
	else:
		# No key -> visible error, never an installable candidate.
		var llm := ForgeLLM.new()
		llm.generation_ready.connect(_on_gen_result)
		root.add_child(llm)
		_gen_result = {}
		llm.request_generation("creator fix probe")
	# No-key error string always surfaces as a non-installable candidate.
	var cand: Dictionary = ModCreator.new().call("_candidate_for", {"error": ModCreator.NO_KEY_ERROR}) as Dictionary
	_check("llm-path", str((cand as Dictionary).get("error", "")) == ModCreator.NO_KEY_ERROR, "llm-path: no-key error passes through as a candidate error (not a mod)")
	_check("llm-path", ModCreator.new().validate(cand as Dictionary) != "", "llm-path: error candidate is not installable")


func _on_gen_result(result: Dictionary) -> void:
	_gen_result = result


func _test_llm_path_deferred() -> void:
	if _gen_result.is_empty():
		return
	var err := str(_gen_result.get("error", ""))
	if err == "generation returned invalid JSON":
		_check("llm-path", true, "llm-path: simulated HTTP failure -> visible error 'generation returned invalid JSON'")
		var cand: Dictionary = ModCreator.new().call("_candidate_for", _gen_result) as Dictionary
		_check("llm-path", str((cand as Dictionary).get("error", "")) != "", "llm-path: HTTP failure produces an error candidate, never a silent fallback mod")
	elif err == ModCreator.NO_KEY_ERROR:
		_check("llm-path", true, "llm-path: no key -> visible error 'DeepSeek key required'")
	else:
		_check("llm-path", false, "llm-path: unexpected generation result error '%s'" % err)


# --- Section 2: cache ---------------------------------------------------------

func _delete_cache_for(desc: String) -> void:
	var path := VoxelAssetGenerator.cache_path_for(desc)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _voxels_canonical(voxels: Array) -> String:
	# Canonical form: JSON round-trip turns voxel ints into floats, so
	# compare int-normalized "x,y,z:color" entries, sorted.
	var parts: Array[String] = []
	for v in voxels:
		var d := v as Dictionary
		var p: Array = d.get("p", [])
		if p.size() == 3:
			parts.append("%d,%d,%d:%s" % [int(p[0]), int(p[1]), int(p[2]), str(d.get("c", ""))])
	parts.sort()
	return ",".join(parts)


func _test_cache() -> void:
	var d1 := "creatorfix test pistol one"
	var d1b := "CreatorFix Test Pistol One!!"
	var d2 := "creatorfix test watermelon xyz"
	_delete_cache_for(d1)
	_delete_cache_for(d2)
	_delete_cache_for("glowing laser beam")
	_delete_cache_for("small metal bullet")
	_delete_cache_for("a pistol with a long barrel, make it really long")
	var a1 := VoxelAssetGenerator.get_or_generate(d1)
	_check("cache", not bool(a1.get("cache_hit", true)), "cache: first generation is a MISS")
	var a1b := VoxelAssetGenerator.get_or_generate(d1)
	_check("cache", bool(a1b.get("cache_hit", false)), "cache: repeat generation is a HIT")
	_check("cache", _voxels_canonical(a1.get("voxels", []) as Array) == _voxels_canonical(a1b.get("voxels", []) as Array), "cache: HIT returns identical voxels")
	var a1c := VoxelAssetGenerator.get_or_generate(d1b)
	_check("cache", str(a1c.get("cache_key", "")) == str(a1.get("cache_key", "")), "cache: normalized variants ('A Pistol!!' vs 'a pistol') share one key")
	_check("cache", bool(a1c.get("cache_hit", false)), "cache: normalized variant is a HIT")
	var aw := VoxelAssetGenerator.get_or_generate(d2)
	_check("cache", str(aw.get("cache_key", "")) != str(a1.get("cache_key", "")), "cache: watermelon vs pistol descriptions have different keys")
	_check("cache", _voxels_canonical(aw.get("voxels", []) as Array) != _voxels_canonical(a1.get("voxels", []) as Array), "cache: watermelon vs pistol voxels differ")
	var beam := VoxelAssetGenerator.get_or_generate("glowing laser beam")
	_check("cache", int(beam.get("voxel_count", -1)) == 6, "cache: beam asset is 6 voxels (got %d)" % int(beam.get("voxel_count", -1)))
	var all_beam_yellow := true
	for v in (beam.get("voxels", []) as Array):
		# Color.to_html() includes alpha: "ffe066ff".
		if str((v as Dictionary).get("c", "")) != "ffe066ff":
			all_beam_yellow = false
	_check("cache", all_beam_yellow, "cache: beam voxels are bright laser yellow (ffe066ff)")
	var bullet := VoxelAssetGenerator.get_or_generate("small metal bullet")
	_check("cache", int(bullet.get("voxel_count", -1)) == 2, "cache: bullet asset is 2 voxels (got %d)" % int(bullet.get("voxel_count", -1)))
	var pistol := VoxelAssetGenerator.get_or_generate("a pistol with a long barrel, make it really long")
	_check("cache", int(pistol.get("voxel_count", -1)) == 52, "cache: pistol weapon visual still 52 voxels (shape path unchanged, got %d)" % int(pistol.get("voxel_count", -1)))
	_delete_cache_for(d1)
	_delete_cache_for(d2)
	_delete_cache_for("glowing laser beam")
	_delete_cache_for("small metal bullet")
	_delete_cache_for("a pistol with a long barrel, make it really long")


# --- Section 3: sandbox (pure + open) -----------------------------------------

func _test_sandbox_pure() -> void:
	var pdesc := ModCreatorMenu.projectile_description_for(["Weapon"], "fires a continuous laser beam", "")
	_check("sandbox", pdesc == "glowing laser beam", "sandbox: pistol logic -> projectile desc 'glowing laser beam' (got '%s')" % pdesc)
	var beam := VoxelAssetGenerator.get_or_generate("glowing laser beam")
	var pbeh := ModCreatorMenu.behavior_for(["Weapon"], "fires a continuous laser beam", "")
	_check("sandbox", bool(pbeh.get("projectile", false)) and not bool(pbeh.get("explodes_on_impact", true)), "sandbox: laser pistol behavior = projectile, no explosion")
	var psim := SandboxTestRoom.simulate_test({}, beam, pbeh)
	_check("sandbox", bool(psim.get("hit", false)) and not bool(psim.get("explosion_fired", true)), "sandbox: laser pistol simulate -> HIT, no explosion")
	var wdesc := ModCreatorMenu.projectile_description_for(["Weapon"], "an LMG that shoots watermelons. The watermelons explode on impact.", "")
	_check("sandbox", wdesc == "watermelon", "sandbox: watermelon logic -> projectile desc 'watermelon' (got '%s')" % wdesc)
	var wasset := VoxelAssetGenerator.get_or_generate("watermelon")
	var colors := {}
	for v in (wasset.get("voxels", []) as Array):
		colors[str((v as Dictionary).get("c", ""))] = true
	# Color.to_html() includes alpha: "e83a4eff", "58a83cff", "1e6b2aff".
	_check("sandbox", colors.has("e83a4eff") and (colors.has("58a83cff") or colors.has("1e6b2aff")), "sandbox: watermelon asset has flesh-red + rind-green")
	var wbeh := ModCreatorMenu.behavior_for(["Weapon"], "an LMG that shoots watermelons. The watermelons explode on impact.", "")
	_check("sandbox", bool(wbeh.get("explodes_on_impact", false)), "sandbox: watermelon behavior explodes on impact")
	var wsim := SandboxTestRoom.simulate_test({}, wasset, wbeh)
	_check("sandbox", bool(wsim.get("hit", false)) and bool(wsim.get("explosion_fired", false)), "sandbox: watermelon simulate -> HIT + explosion")
	_delete_cache_for("glowing laser beam")
	_delete_cache_for("watermelon")


func _test_sandbox_open() -> void:
	var beam := VoxelAssetGenerator.get_or_generate("glowing laser beam")
	var pistol := VoxelAssetGenerator.get_or_generate("a pistol with a long barrel, make it really long")
	var cand := {"name": "Long Laser Pistol", "mod_id": "long_laser_pistol", "kind": "script"}
	var beh := ModCreatorMenu.behavior_for(["Weapon"], "fires a continuous laser beam", "")
	_sandbox1.open(cand, beam, beh, pistol)
	_check("sandbox", _sandbox1.get_projectile() != null, "sandbox: open(4-arg) builds a projectile node")
	_check("sandbox", _sandbox1.get_weapon_visual() != null, "sandbox: open(4-arg) shows the weapon visual too")
	if _sandbox1.get_projectile() != null:
		_check("sandbox", _sandbox1.get_projectile().get_child_count() == 6, "sandbox: projectile is the 6-voxel beam (got %d children)" % _sandbox1.get_projectile().get_child_count())
	if _sandbox1.get_weapon_visual() != null:
		_check("sandbox", _sandbox1.get_weapon_visual().get_child_count() == 52, "sandbox: weapon visual is the 52-voxel pistol (got %d children)" % _sandbox1.get_weapon_visual().get_child_count())
	_check("sandbox", str(_sandbox1.get("_candidate_label").text) == "Long Laser Pistol", "sandbox: candidate-name header shows 'Long Laser Pistol'")
	_sandbox2.open(cand, beam, beh)
	_check("sandbox", _sandbox2.get_projectile() != null, "sandbox: open(3-arg) still works (projectile built)")
	_check("sandbox", _sandbox2.get_weapon_visual() == null, "sandbox: open(3-arg) has no weapon visual")
	_sandbox1.queue_free()
	_sandbox2.queue_free()
	_delete_cache_for("glowing laser beam")
	_delete_cache_for("a pistol with a long barrel, make it really long")


# --- Section 4: watermelon E2E -----------------------------------------------

func _watermelon_mock() -> Dictionary:
	var lines := [
		"extends ModBlock",
		"",
		"func get_block_info() -> Dictionary:",
		"\treturn {\"block_id\": \"watermelon_lmg\", \"target\": \"weapon\", \"cost\": 300, \"display_name\": \"Watermelon LMG\", \"description\": \"An LMG that shoots watermelons. The watermelons explode on impact.\", \"base_weapon_id\": \"lmg\", \"damage_mult\": 1.0, \"mag_mult\": 1.0, \"range_mult\": 1.0}",
		"",
		"func apply(api: ModAPI, params: Dictionary) -> String:",
		"\tapi.give_weapon(\"lmg\", 1.0, 1.0, 1.0)",
		"\tvar at: Vector3 = params.get(\"_position\", Vector3.ZERO)",
		"\tapi.spawn_voxel_box(Vector3(1, 1, 1), Color(0.35, 0.66, 0.24), at, false)",
		"\tapi.fire_effect(\"explosion\", at, 4.0, 60.0)",
		"\treturn \"Forge fabricated: Watermelon LMG (mod).\"",
	]
	return {
		"manifest": {"name": "Watermelon LMG", "kind": "script", "version": "1.0",
			"description": "An LMG that shoots watermelons. The watermelons explode on impact."},
		"payload": "\n".join(lines),
		"summary": "An LMG that fires exploding watermelons.",
	}


func _on_e2e_generation(candidate: Dictionary) -> void:
	_captured = candidate


func _test_e2e_candidate() -> void:
	_check("watermelon-e2e", str(_captured.get("error", "")) == "", "watermelon-e2e: mock generation -> candidate with no error (err='%s')" % str(_captured.get("error", "")))
	_check("watermelon-e2e", str(_captured.get("name", "")) == "Watermelon LMG", "watermelon-e2e: candidate name is Watermelon LMG")
	_check("watermelon-e2e", str(_captured.get("kind", "")) == "script", "watermelon-e2e: candidate kind is script")


func _find_installed_test_mod() -> String:
	for m in ModLoader.get_mods():
		var mid := str((m as Dictionary).get("id", ""))
		if mid.begins_with("watermelon_lmg"):
			return mid
	return ""


func _test_e2e_install() -> void:
	var err := _creator.install(_captured)
	_check("watermelon-e2e", err == "", "watermelon-e2e: install succeeds (err='%s')" % err)
	_installed_id = _find_installed_test_mod()
	_check("watermelon-e2e", not _installed_id.is_empty(), "watermelon-e2e: installed mod appears in ModLoader.get_mods()")
	if not _installed_id.is_empty():
		var rec := ModLoader.find_mod(_installed_id)
		_check("watermelon-e2e", str(rec.get("error", "")) == "", "watermelon-e2e: installed record is error-free")
		_check("watermelon-e2e", bool(rec.get("enabled", false)), "watermelon-e2e: installed mod defaults to enabled")
		var beh := ModCreatorMenu.behavior_for(["Weapon"], "an LMG that shoots watermelons. The watermelons explode on impact.", str(_captured.get("payload", "")))
		var wasset := VoxelAssetGenerator.get_or_generate("watermelon")
		var sim := SandboxTestRoom.simulate_test(_captured, wasset, beh)
		_check("watermelon-e2e", bool(sim.get("hit", false)) and bool(sim.get("explosion_fired", false)), "watermelon-e2e: installed mod simulates HIT + explosion")
		_delete_cache_for("watermelon")


# --- Section 5+6: menu flow + layout ------------------------------------------

func _test_menu_generate() -> void:
	_check("menu-flow", str(_menu.get("_pending_candidate").get("error", "")) == "" and not (_menu.get("_pending_candidate") as Dictionary).is_empty(), "menu-flow: menu generate (mock) -> pending candidate, no error")
	var proj: Dictionary = _menu.get("_pending_projectile_asset")
	var vis: Dictionary = _menu.get("_pending_asset")
	_check("menu-flow", str(proj.get("cache_key", "")) != str(vis.get("cache_key", "")), "menu-flow: projectile asset is distinct from the weapon visual asset")
	var colors := {}
	for v in (proj.get("voxels", []) as Array):
		colors[str((v as Dictionary).get("c", ""))] = true
	_check("menu-flow", colors.has("e83a4eff"), "menu-flow: projectile asset is the watermelon (flesh-red present)")


func _test_menu_install() -> void:
	_check("menu-flow", str((_menu.get("_status") as Label).text) == "Installed.", "menu-flow: Install via menu reports 'Installed.' (got '%s')" % str((_menu.get("_status") as Label).text))


func _test_menu_layout() -> void:
	# Row checks live here (not in _test_menu_install): the row is in
	# the MODS tab, and its label sizes are 0 until that tab is current
	# and laid out.
	var row_found := false
	var row_name_wide := false
	for ch in (_menu.get("_mods_list") as VBoxContainer).get_children():
		if ch is VBoxContainer and str(ch.name).begins_with("ModRow_watermelon"):
			row_found = true
			var name_lbl: Label = ch.get_node_or_null("ModRow/ModName") as Label
			if name_lbl != null and name_lbl.size.x >= 40.0:
				row_name_wide = true
	_check("menu-flow", row_found, "menu-flow: installed mod row appears in the Mods list immediately (no restart)")
	_check("menu-flow", row_name_wide, "menu-flow: installed mod row name renders readable (>= 40px wide)")
	var mods_box: VBoxContainer = _menu.get_node_or_null("Panel/CreatorStack/CreatorTabs/ModsBox") as VBoxContainer
	_check("layout", mods_box != null, "layout: ModsBox found as the direct Mods tab child (no wrapping ScrollContainer)")
	if mods_box == null:
		return
	var hint_ok := false
	var row_h_ok := false
	var list_h_ok := false
	for ch in mods_box.get_children():
		if ch is HBoxContainer:
			if ch.size.y < 100.0:
				row_h_ok = true
			for g in ch.get_children():
				if g is Label and (g as Label).text.begins_with("Same installed"):
					hint_ok = (g as Label).size.x >= 40.0
		if ch is ScrollContainer and ch.name == "ModsListScroll":
			list_h_ok = ch.size.y > 100.0
	_check("layout", hint_ok, "layout: Mods-tab hint label renders horizontal (>= 40px wide, not 1-char-per-line)")
	_check("layout", row_h_ok, "layout: Mods-tab button row is < 100px tall (was 1617px)")
	_check("layout", list_h_ok, "layout: mod list ScrollContainer gets real height (> 100px, was 0px)")
	var bad: Array[String] = []
	_scan_narrow(_menu, bad)
	if bad.is_empty():
		_check("layout", true, "layout: no visible label narrower than 40px with multi-char text")
	else:
		_check("layout", false, "layout: narrow labels: %s" % ", ".join(bad))


func _scan_narrow(n: Node, bad: Array[String]) -> void:
	if n is Control and not (n as Control).visible:
		return
	if n is Label:
		var lb := n as Label
		if lb.text.length() > 10 and lb.size.x < 40.0:
			bad.append("%s '%s' size=%s" % [lb.get_class(), lb.name, lb.size])
	for ch in n.get_children():
		_scan_narrow(ch, bad)


# --- Cleanup + finish ---------------------------------------------------------

func _delete_mod_folder(mod_id: String) -> void:
	if mod_id.is_empty():
		return
	var folder_abs := OS.get_user_data_dir().path_join("mods").path_join(mod_id)
	for f in ["manifest.json", "block.json", "mod.gd"]:
		var p := folder_abs.path_join(f)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if DirAccess.dir_exists_absolute(folder_abs):
		DirAccess.remove_absolute(folder_abs)
	ModLoader.rescan()


func _cleanup_test_state() -> void:
	ModCreator.mock_generation = {}
	if _creator != null and is_instance_valid(_creator):
		_creator.queue_free()
		_creator = null
	if _menu != null and is_instance_valid(_menu):
		_menu.queue_free()
		_menu = null
	# Delete EVERY test-mod folder (E2E install lands watermelon_lmg,
	# the menu install lands watermelon_lmg_2 while it still exists).
	var ids: Array[String] = []
	for m in ModLoader.get_mods():
		var mid := str((m as Dictionary).get("id", ""))
		if mid.begins_with("watermelon_lmg"):
			ids.append(mid)
	for mid in ids:
		_delete_mod_folder(mid)
	_installed_id = ""
	_delete_cache_for("creatorfix test pistol one")
	_delete_cache_for("creatorfix test watermelon xyz")
	_delete_cache_for("glowing laser beam")
	_delete_cache_for("small metal bullet")
	_delete_cache_for("watermelon")
	_delete_cache_for("a pistol with a long barrel, make it really long")
	_delete_cache_for("a black LMG with a big hopper")


func _finish() -> void:
	_cleanup_test_state()
	print("VERIFY_CREATOR_FIX: sections:")
	for section in ["llm-path", "cache", "sandbox", "watermelon-e2e", "menu-flow", "layout"]:
		var p := int(_sec_pass.get(section, 0))
		var f := int(_sec_fail.get(section, 0))
		if p + f > 0:
			print("  ", section, ": ", p, " PASS / ", f, " FAIL")
	if _timeout:
		printerr("VERIFY_CREATOR_FIX: TIMEOUT — phase machine did not finish")
	if _fails == 0:
		print("VERIFY_CREATOR_FIX: ALL CHECKS PASSED (%d)" % _passes)
	else:
		printerr("VERIFY_CREATOR_FIX: %d PASS / %d FAIL" % [_passes, _fails])
	quit(_fails)
