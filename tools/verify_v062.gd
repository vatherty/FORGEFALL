# verify_v062.gd — headless checks for FORGEFALL v0.6.2 (loosened Forge LLM gate).
# Usage: godot --headless --path <project> --script res://tools/verify_v062.gd
# Asserts (v0.6.2, Colin loosened the gate):
#   (1) Compositions of KNOWN blocks are ACCEPTED — "LMG with sniper
#       bullets" (weapon lmg + ammo_type sniper) passes, cost = recomputed
#       sum of block costs (350 + 50 = 400). Other compositions too.
#   (2) Cost mismatch NEVER rejects anymore: a spec with a wrong
#       LLM-supplied cost is accepted with the game's recomputed cost
#       substituted into spec["cost"].
#   (3) STILL REJECTED: unknown block, invented field, eval( string,
#       script field, out-of-range number.
#   (4) Truly unexpressible ("flying car that shoots lasers") -> clean
#       refusal, never falls into the offline fallback.
#   (5) Offline keyword fallback still works with no key.
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _llm_script: GDScript = null
var _llm: Node = null
var _builder_script: GDScript = null
var _arsenal_script: GDScript = null
var _test_root: Node3D = null
var _player: Node3D = null
var _wm: Node = null
var _builder_pending := false


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	_llm_script = load("res://scripts/forge/forge_llm.gd") as GDScript
	_check(_llm_script != null, "forge_llm.gd loads (no parse errors)")
	if _llm_script == null:
		_finish()
		return
	_llm = _llm_script.new()
	_check_composition_lmg()
	_check_composition_more()
	_check_cost_mismatch_accepted()
	_check_still_rejected()
	_check_refusal_not_fallback()
	_check_offline_fallback()
	_check_template_composition()
	# Builder checks run on the first _process frame (not in _initialize):
	# nodes added during _initialize are not inside the world yet, so
	# raycasts / global transforms in the builder would error.
	_builder_pending = true


func _process(_delta: float) -> bool:
	if _builder_pending:
		_builder_pending = false
		_check_builder_applies()
		_finish()
		return true
	return false


func _finish() -> void:
	if _fails == 0:
		print("VERIFY_V062: ALL CHECKS PASSED")
	else:
		printerr("VERIFY_V062: %d CHECK(S) FAILED" % _fails)
	quit(_fails)


# ------------------------------------------------------------------ (1)
# "LMG with sniper bullets": the composed spec the LLM emits per the
# SYSTEM_PROMPT example (weapon lmg + ammo_type sniper) must be ACCEPTED,
# with cost = recomputed sum 350 (per-weapon LMG cost) + 50 (sniper ammo) = 400.
func _check_composition_lmg() -> void:
	var spec := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "lmg", "ammo_type": "sniper"},
		"cost": 400, "ttl": 0,
	}
	var v: Array = _llm.call("validate_modspec", spec)
	_check(bool(v[0]), "v062(1): LMG + sniper ammo spec ACCEPTED (%s)" % str(v[1]))
	_check(int(spec.get("cost", -1)) == 400,
		"v062(1): LMG + sniper cost is recomputed sum 400 (got %s)" % str(spec.get("cost")))
	var rc: int = _llm.call("recompute_cost", "weapon", {"weapon_id": "lmg", "ammo_type": "sniper"})
	_check(rc == 400, "v062(1): recompute_cost(weapon lmg+sniper) == 400 (got %d)" % rc)
	# Same composition with a WRONG model cost must still accept + correct.
	var wrong := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "lmg", "ammo_type": "sniper"},
		"cost": 1, "ttl": 0,
	}
	var v2: Array = _llm.call("validate_modspec", wrong)
	_check(bool(v2[0]) and int(wrong.get("cost", -1)) == 400,
		"v062(1): LMG + sniper with wrong cost 1 ACCEPTED, corrected to 400 (got %s)" % str(wrong.get("cost")))


# ------------------------------------------------------------------ (1b)
# Other known-block compositions: reinforced cover/structure, turret ammo,
# standard (zero-surcharge) ammo, and plain un-composed specs unchanged.
func _check_composition_more() -> void:
	var cases := [
		# [label, target, params, expected_cost]
		["reinforced bunker", "structure",
			{"shape": "bunker", "position": "near_player", "property": "reinforced"}, 230],
		["reinforced tower", "cover",
			{"shape": "tower", "size_voxels": [4, 10, 4], "position": "near_player", "hp": 350, "property": "reinforced"}, 200],
		["turret + armor-piercing", "turret",
			{"position": "near_player", "duration_sec": 45, "ammo_type": "armor_piercing"}, 325],
		["manticore + buckshot", "weapon",
			{"weapon_id": "manticore", "ammo_type": "buckshot"}, 330],
		["longeye + standard ammo", "weapon",
			{"weapon_id": "longeye", "ammo_type": "standard"}, 235],
		["plain tower (no composition)", "cover",
			{"shape": "tower", "size_voxels": [4, 10, 4], "position": "near_player", "hp": 350}, 150],
		["plain weapon (no composition)", "weapon",
			{"weapon_id": "longeye"}, 235],
	]
	for c in cases:
		var label: String = c[0]
		var target: String = c[1]
		var params: Dictionary = c[2]
		var expected: int = c[3]
		var action := "spawn"
		if target == "enemy_mod":
			action = "modify"
		var spec := {"spec_version": 1, "action": action, "target": target,
			"params": params, "cost": 999999, "ttl": 0}
		var v: Array = _llm.call("validate_modspec", spec)
		_check(bool(v[0]) and int(spec.get("cost", -1)) == expected,
			"v062(1): '%s' ACCEPTED with recomputed cost %d (got ok=%s cost=%s)"
			% [label, expected, str(v[0]), str(spec.get("cost"))])
		var rc: int = _llm.call("recompute_cost", target, params)
		_check(rc == expected,
			"v062(1): recompute_cost %s == %d (got %d)" % [label, expected, rc])


# ------------------------------------------------------------------ (2)
# Cost mismatch never rejects: wrong LLM-supplied costs are accepted and
# replaced with the game's recomputed cost.
func _check_cost_mismatch_accepted() -> void:
	var tower := {
		"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"shape": "tower", "size_voxels": [4, 10, 4],
			"position": "near_player", "hp": 350},
		"cost": 999, "ttl": 0,
	}
	var v: Array = _llm.call("validate_modspec", tower)
	_check(bool(v[0]) and int(tower.get("cost", -1)) == 150,
		"v062(2): tower with wrong cost 999 ACCEPTED, corrected to 150 (got ok=%s cost=%s)"
		% [str(v[0]), str(tower.get("cost"))])
	var weapon := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "longeye"}, "cost": 0, "ttl": 0,
	}
	var v2: Array = _llm.call("validate_modspec", weapon)
	_check(bool(v2[0]) and int(weapon.get("cost", -1)) == 235,
		"v062(2): weapon with wrong cost 0 ACCEPTED, corrected to 235 (got ok=%s cost=%s)"
		% [str(v2[0]), str(weapon.get("cost"))])
	# A non-numeric cost is still a rejection (recompute needs a number).
	var bad_cost := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "longeye"}, "cost": "free", "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_cost) as Array)[0]),
		"v062(2): non-numeric cost still rejected (recompute needs a number)")


# ------------------------------------------------------------------ (3)
# STILL REJECTED: unknown block, invented field, eval( string, script
# field, out-of-range number.
func _check_still_rejected() -> void:
	var base := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "lmg", "ammo_type": "sniper"},
		"cost": 250, "ttl": 0,
	}
	# Unknown block: unknown weapon / ammo_type / property / target / action.
	var bad_weapon := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "laser_gun"}, "cost": 200, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_weapon) as Array)[0]),
		"v062(3): unknown weapon block 'laser_gun' REJECTED")
	var bad_ammo := base.duplicate(true)
	(bad_ammo["params"] as Dictionary)["ammo_type"] = "plasma"
	_check(not bool((_llm.call("validate_modspec", bad_ammo) as Array)[0]),
		"v062(3): unknown ammo block 'plasma' REJECTED")
	var bad_prop := {
		"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "bunker", "position": "near_player", "property": "adamantium"},
		"cost": 180, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_prop) as Array)[0]),
		"v062(3): unknown property block 'adamantium' REJECTED")
	_check(_llm.call("recompute_cost", "weapon", {"weapon_id": "lmg", "ammo_type": "plasma"}) == -1,
		"v062(3): recompute_cost returns -1 for unknown ammo block")
	var bad_target := base.duplicate(true)
	bad_target["target"] = "flying_car"
	_check(not bool((_llm.call("validate_modspec", bad_target) as Array)[0]),
		"v062(3): unknown target 'flying_car' REJECTED")
	var bad_action := base.duplicate(true)
	bad_action["action"] = "teleport"
	_check(not bool((_llm.call("validate_modspec", bad_action) as Array)[0]),
		"v062(3): unknown action 'teleport' REJECTED")
	var bad_shape := {
		"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"shape": "dome", "size_voxels": [4, 4, 4],
			"position": "near_player", "hp": 200},
		"cost": 100, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_shape) as Array)[0]),
		"v062(3): unknown cover shape 'dome' REJECTED")
	# Invented field: unknown top-level key, and unknown extra param key.
	var invented_top := base.duplicate(true)
	invented_top["damage"] = 999
	_check(not bool((_llm.call("validate_modspec", invented_top) as Array)[0]),
		"v062(3): invented top-level field 'damage' REJECTED")
	var invented_param := base.duplicate(true)
	(invented_param["params"] as Dictionary)["damage_boost"] = 2
	_check(not bool((_llm.call("validate_modspec", invented_param) as Array)[0]),
		"v062(3): invented param 'damage_boost' REJECTED")
	# eval( string: code content in a field.
	var code_str := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "manticore'); eval("}, "cost": 200, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", code_str) as Array)[0]),
		"v062(3): eval( string in a field REJECTED")
	_check(_llm.call("_is_clean_value", "eval(") == false,
		"v062(3): _is_clean_value flags eval( content")
	_check(_llm.call("_is_clean_value", "sniper") == true,
		"v062(3): _is_clean_value allows clean catalog strings")
	# script field: top-level and in params.
	var script_top := base.duplicate(true)
	script_top["script"] = "print('hi')"
	_check(not bool((_llm.call("validate_modspec", script_top) as Array)[0]),
		"v062(3): 'script' top-level field REJECTED")
	var script_param := base.duplicate(true)
	(script_param["params"] as Dictionary)["script"] = "print('hi')"
	_check(not bool((_llm.call("validate_modspec", script_param) as Array)[0]),
		"v062(3): 'script' param field REJECTED")
	# Out-of-range numbers: hp, size_voxels, duration, count, ttl, position.
	var bad_hp := {
		"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"shape": "tower", "size_voxels": [4, 10, 4],
			"position": "near_player", "hp": 9999},
		"cost": 150, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_hp) as Array)[0]),
		"v062(3): out-of-range hp 9999 REJECTED (no clamping repair)")
	var bad_size := {
		"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"shape": "tower", "size_voxels": [99, 10, 4],
			"position": "near_player", "hp": 350},
		"cost": 150, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_size) as Array)[0]),
		"v062(3): out-of-range size_voxels REJECTED")
	var bad_dur := {
		"spec_version": 1, "action": "spawn", "target": "turret",
		"params": {"position": "near_player", "duration_sec": 999},
		"cost": 250, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_dur) as Array)[0]),
		"v062(3): out-of-range duration_sec REJECTED")
	var bad_count := {
		"spec_version": 1, "action": "spawn", "target": "enemy_spawn",
		"params": {"type": "grunt", "count": 99}, "cost": 150, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_count) as Array)[0]),
		"v062(3): out-of-range enemy count REJECTED")
	var bad_ttl := base.duplicate(true)
	bad_ttl["ttl"] = 999
	_check(not bool((_llm.call("validate_modspec", bad_ttl) as Array)[0]),
		"v062(3): out-of-range ttl REJECTED")
	var bad_pos := {
		"spec_version": 1, "action": "spawn", "target": "turret",
		"params": {"position": [999, 0, 0], "duration_sec": 45},
		"cost": 250, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_pos) as Array)[0]),
		"v062(3): out-of-range position REJECTED")
	var bad_mod := {
		"spec_version": 1, "action": "modify", "target": "enemy_mod",
		"params": {"mod": "enrage"}, "cost": 150, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_mod) as Array)[0]),
		"v062(3): enemy_mod 'enrage' still REJECTED (weaken only)")


# ------------------------------------------------------------------ (4)
# Truly unexpressible -> clean refusal, never falls into offline fallback:
# the refusal survives response-envelope extraction untouched (non-empty),
# so the HTTP handler never substitutes the fallback; and the offline
# fallback itself refuses to build for the same prompt (returns _error).
func _check_refusal_not_fallback() -> void:
	var refusal := {
		"spec_version": 1, "action": "refuse", "target": "none",
		"params": {"reason": "flying cars and lasers are not in the build catalog"},
		"cost": 0, "ttl": 0,
	}
	_check(_llm.call("is_refusal", refusal) == true,
		"v062(4): is_refusal recognizes the refusal shape")
	var msg: String = _llm.call("refusal_message", refusal)
	_check(msg.contains("Can't do that") and msg.contains("try:"),
		"v062(4): refusal message is clean + suggestions (got: %s)" % msg)
	_check(not bool((_llm.call("validate_modspec", refusal) as Array)[0]),
		"v062(4): refusal spec is not a build spec")
	var envelope := JSON.stringify({"choices": [{"message": {"content": JSON.stringify(refusal)}}]})
	var extracted: Dictionary = _llm.call("_extract_spec", envelope)
	_check(not extracted.is_empty() and _llm.call("is_refusal", extracted) == true,
		"v062(4): refusal survives _extract_spec non-empty (no fallback substitution)")
	var off: Dictionary = _llm.call("parse_offline", "make a flying car that shoots lasers")
	_check(off.has("_error") and str(off["_error"]).contains("try:"),
		"v062(4): offline fallback also refuses the flying-car prompt (_error + suggestions, no build)")


# ------------------------------------------------------------------ (5)
# Offline keyword fallback still works with no key: known prompts parse
# to valid specs that pass the (loosened) gate; unknown prompts _error.
func _check_offline_fallback() -> void:
	for prompt in ["build a tower near me", "build a wall", "spawn a turret",
			"build a bridge", "build a bunker", "build a watchtower",
			"spawn an ammo depot", "give me a sniper rifle", "call a UAV",
			"deploy a smoke screen", "weaken the enemies",
			"spawn enemies", "send a health cache", "call a supply drop",
			"give me an lmg", "give me a rifle"]:
		var off: Dictionary = _llm.call("parse_offline", prompt)
		_check(not off.has("_error"),
			"v062(5): offline fallback for '%s' is parseable" % prompt)
		if not off.has("_error"):
			var vv: Array = _llm.call("validate_modspec", off)
			_check(bool(vv[0]),
				"v062(5): offline fallback for '%s' passes gate (%s)" % [prompt, str(vv[1])])
	var unknown: Dictionary = _llm.call("parse_offline",
		"make a flying car that shoots lasers")
	_check(unknown.has("_error") and str(unknown["_error"]).contains("try:"),
		"v062(5): offline unknown prompt yields _error + suggestions, no build")
	var src := FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	var key_branch := src.find("if key.is_empty():")
	_check(key_branch >= 0
		and src.find("_finish(_fallback_spec(prompt))", key_branch) > key_branch,
		"v062(5): request_spec falls back when the key is empty (no network)")
	_check(src.contains("ForgeConfig.load_key()"),
		"v062(5): key read goes through ForgeConfig (user:// only)")


# ------------------------------------------------------------------ template
# The templated prompt still holds: one stable constant, composition rule
# + LMG example present, retired model name absent.
func _check_template_composition() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	var first := src.find("const SYSTEM_PROMPT :=")
	_check(first >= 0, "v062(template): const SYSTEM_PROMPT exists")
	_check(src.find("const SYSTEM_PROMPT :=", first + 1) < 0,
		"v062(template): exactly one SYSTEM_PROMPT constant (no per-call variants)")
	var body_start := src.find('"""', first)
	var body_end := src.find('"""', body_start + 3)
	var template := ""
	if body_start >= 0 and body_end > body_start:
		template = src.substr(body_start + 3, body_end - (body_start + 3))
	_check(template.contains("COMPOSITION") and template.contains("SUM"),
		"v062(template): composition rule present (game computes the SUM)")
	_check(template.contains('"weapon_id":"lmg"') or template.contains("lmg"),
		"v062(template): LMG block present in the catalog")
	_check(template.contains("ammo_type"),
		"v062(template): ammo_type composition present in the catalog")
	_check(not template.contains("deepseek-chat"),
		"v062(template): does not name the retired deepseek-chat model")
	_check(not template.contains("Forge budget") and not template.contains("%d"),
		"v062(template): carries no variable content (no budget, no interpolation)")


# ------------------------------------------------------------------ builder
# WORKER A: a composed spec that passes the gate must CHANGE the game.
# Live builder checks with a REAL WeaponManager (not a stub): weapon +
# ammo_type mutates the freshly built weapon's fields, reinforced
# structure HP lands in metadata, turret ammo lands as metadata, and
# every Forge weapon id builds a real Arsenal weapon.
func _check_builder_applies() -> void:
	_builder_script = load("res://scripts/forge/forge_builder.gd") as GDScript
	_arsenal_script = load("res://scripts/weapons/arsenal.gd") as GDScript
	_check(_builder_script != null, "v062(builder): forge_builder.gd loads (no parse errors)")
	_check(_arsenal_script != null, "v062(builder): arsenal.gd loads (no parse errors)")
	if _builder_script == null or _arsenal_script == null:
		return
	# --- weapon-id mapping: every Forge id -> a real Arsenal id ---
	var forge_ids := ["manticore", "longeye", "breacher", "hornet", "p9", "raptor", "lmg"]
	var mapping: Dictionary = _builder_script.FORGE_WEAPON_IDS
	for fid in forge_ids:
		var mapped := str(mapping.get(fid, fid))
		_check(bool(_arsenal_script.call("has_weapon", mapped)),
			"v062(map): Forge id '%s' -> Arsenal id '%s' exists" % [fid, mapped])
	# --- LMG entry completeness vs ar7 (the complete reference entry) ---
	var ar7: Dictionary = _arsenal_script.call("get_stats", "ar7")
	var lmg: Dictionary = _arsenal_script.call("get_stats", "lmg")
	var lmg_complete := true
	for k in ar7.keys():
		if not lmg.has(k):
			lmg_complete = false
	_check(lmg_complete, "v062(lmg): LMG-9 entry has every field ar7 has")
	_check(str(lmg.get("name", "")) == "LMG-9 ANVIL" and int(lmg.get("mag_size", 0)) == 100,
		"v062(lmg): LMG-9 ANVIL, mag_size 100 (got name=%s mag=%s)" % [str(lmg.get("name")), str(lmg.get("mag_size"))])
	_check(float(_arsenal_script.call("sight_height", "lmg")) > 0.0,
		"v062(lmg): sight_height(lmg) > 0")
	var vm: Node3D = _arsenal_script.call("build_viewmodel", "lmg")
	_check(vm != null and vm.get_node_or_null("Muzzle") != null and vm.get_node_or_null("Eject") != null,
		"v062(lmg): build_viewmodel(lmg) has Muzzle + Eject anchors")
	if vm != null:
		vm.free()
	# --- live harness: real WeaponManager on a real player node ---
	_test_root = Node3D.new()
	_test_root.name = "V062TestRoot"
	root.add_child(_test_root)
	_player = Node3D.new()
	_player.name = "V062Player"
	_player.add_to_group("player")
	_test_root.add_child(_player)
	var wm_script: GDScript = load("res://scripts/weapons/weapon_manager.gd") as GDScript
	_wm = wm_script.new()
	_wm.name = "WeaponManager"
	_player.add_child(_wm)
	var ctx := {"player": _player, "root": _test_root}
	# (1) LMG + sniper: damage x1.5, ranges x1.5, mag halved (100 -> 50).
	var msg: String = _builder_script.build(
		{"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "lmg", "ammo_type": "sniper"}, "cost": 250, "ttl": 0}, ctx)
	_check(not msg.begins_with(_builder_script.FAIL_PREFIX),
		"v062(builder): LMG + sniper builds (%s)" % msg)
	var w := _find_live_weapon("lmg")
	_check(w != null, "v062(builder): LMG weapon node found after build")
	if w != null:
		_check(is_equal_approx(float(w.get("damage")), 22.0 * 1.5),
			"v062(builder): LMG + sniper damage 22 -> 33 (got %s)" % str(w.get("damage")))
		_check(is_equal_approx(float(w.get("near_range")), 18.0 * 1.5),
			"v062(builder): LMG + sniper near_range 18 -> 27 (got %s)" % str(w.get("near_range")))
		_check(is_equal_approx(float(w.get("far_range")), 55.0 * 1.5),
			"v062(builder): LMG + sniper far_range 55 -> 82.5 (got %s)" % str(w.get("far_range")))
		_check(int(w.get("mag_size")) == 50 and int(w.get("mag")) == 50,
			"v062(builder): LMG + sniper mag 100 -> 50/50 (got %s/%s)" % [str(w.get("mag_size")), str(w.get("mag"))])
	# (2) manticore + armor_piercing: damage x1.25, spreads x1.2.
	var msg2: String = _builder_script.build(
		{"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "manticore", "ammo_type": "armor_piercing"}, "cost": 275, "ttl": 0}, ctx)
	_check(not msg2.begins_with(_builder_script.FAIL_PREFIX),
		"v062(builder): manticore + armor-piercing builds (%s)" % msg2)
	var w2 := _find_live_weapon("ar7")
	_check(w2 != null, "v062(builder): manticore (ar7) node found after build")
	if w2 != null:
		_check(is_equal_approx(float(w2.get("damage")), 25.0 * 1.25),
			"v062(builder): manticore + AP damage 25 -> 31.25 (got %s)" % str(w2.get("damage")))
		_check(is_equal_approx(float(w2.get("spread_hip")), 0.030 * 1.2),
			"v062(builder): manticore + AP spread_hip 0.03 -> 0.036 (got %s)" % str(w2.get("spread_hip")))
		_check(is_equal_approx(float(w2.get("spread_move")), 0.032 * 1.2),
			"v062(builder): manticore + AP spread_move 0.032 -> 0.0384 (got %s)" % str(w2.get("spread_move")))
	# (3) breacher + buckshot: damage x1.3, ranges x0.6, spreads x1.6.
	var msg3: String = _builder_script.build(
		{"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "breacher", "ammo_type": "buckshot"}, "cost": 250, "ttl": 0}, ctx)
	_check(not msg3.begins_with(_builder_script.FAIL_PREFIX),
		"v062(builder): breacher + buckshot builds (%s)" % msg3)
	var w3 := _find_live_weapon("sg12")
	_check(w3 != null, "v062(builder): breacher (sg12) node found after build")
	if w3 != null:
		_check(is_equal_approx(float(w3.get("damage")), 12.0 * 1.3),
			"v062(builder): breacher + buckshot damage 12 -> 15.6 (got %s)" % str(w3.get("damage")))
		_check(is_equal_approx(float(w3.get("near_range")), 8.0 * 0.6),
			"v062(builder): breacher + buckshot near_range 8 -> 4.8 (got %s)" % str(w3.get("near_range")))
		_check(is_equal_approx(float(w3.get("far_range")), 28.0 * 0.6),
			"v062(builder): breacher + buckshot far_range 28 -> 16.8 (got %s)" % str(w3.get("far_range")))
		_check(is_equal_approx(float(w3.get("spread_hip")), 0.075 * 1.6),
			"v062(builder): breacher + buckshot spread_hip 0.075 -> 0.12 (got %s)" % str(w3.get("spread_hip")))
	# (4) Every Forge weapon id builds a real Arsenal weapon end-to-end.
	for fid in forge_ids:
		var mapped := str(mapping.get(fid, fid))
		var m: String = _builder_script.build(
			{"spec_version": 1, "action": "spawn", "target": "weapon",
			"params": {"weapon_id": fid}, "cost": 200, "ttl": 0}, ctx)
		var slot_id: String = str(_wm.call("get_slot_weapon_id", "primary"))
		_check(not m.begins_with(_builder_script.FAIL_PREFIX) and slot_id == mapped,
			"v062(map): Forge '%s' builds, primary slot holds '%s' (got slot=%s msg=%s)" % [fid, mapped, slot_id, m])
	# (5) Reinforced structure HP lands in metadata: bunker 600 -> 900.
	var bmsg: String = _builder_script.build(
		{"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "bunker", "position": "near_player", "property": "reinforced"},
		"cost": 230, "ttl": 0}, ctx)
	var bnode: Node = _builder_script.last_built_node
	_check(not bmsg.begins_with(_builder_script.FAIL_PREFIX) and bnode != null,
		"v062(builder): reinforced bunker builds (%s)" % bmsg)
	if bnode != null:
		_check(is_equal_approx(float(bnode.get_meta("hp")), 600.0 * 1.5),
			"v062(builder): reinforced bunker hp 600 -> 900 (got %s)" % str(bnode.get_meta("hp")))
		_check(is_equal_approx(float(bnode.get_meta("max_hp")), 600.0 * 1.5),
			"v062(builder): reinforced bunker max_hp 600 -> 900 (got %s)" % str(bnode.get_meta("max_hp")))
	var bmsg2: String = _builder_script.build(
		{"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "bunker", "position": "near_player"}, "cost": 180, "ttl": 0}, ctx)
	var bnode2: Node = _builder_script.last_built_node
	_check(not bmsg2.begins_with(_builder_script.FAIL_PREFIX) and bnode2 != null
		and is_equal_approx(float(bnode2.get_meta("hp")), 600.0),
		"v062(builder): plain bunker hp stays 600 (got %s)" % str(bnode2.get_meta("hp") if bnode2 != null else "null"))
	# (6) Reinforced cover HP lands on the cover node: wall 200 -> 300.
	var cmsg: String = _builder_script.build(
		{"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"shape": "wall", "size_voxels": [8, 5, 2], "position": "near_player",
		"hp": 200, "property": "reinforced"}, "cost": 150, "ttl": 0}, ctx)
	var cnode: Node = _builder_script.last_built_node
	_check(not cmsg.begins_with(_builder_script.FAIL_PREFIX) and cnode != null,
		"v062(builder): reinforced wall builds (%s)" % cmsg)
	if cnode != null:
		_check(is_equal_approx(float(cnode.get("hp")), 200.0 * 1.5),
			"v062(builder): reinforced wall hp 200 -> 300 (got %s)" % str(cnode.get("hp")))
	# (7) Turret + ammo_type lands as metadata (turret script reads fixed
	# consts, so metadata is the application path — see forge_builder.gd).
	var tmsg: String = _builder_script.build(
		{"spec_version": 1, "action": "spawn", "target": "turret",
		"params": {"position": "near_player", "duration_sec": 45, "ammo_type": "sniper"},
		"cost": 300, "ttl": 0}, ctx)
	var tnode: Node = _builder_script.last_built_node
	_check(not tmsg.begins_with(_builder_script.FAIL_PREFIX) and tnode != null,
		"v062(builder): turret + sniper builds (%s)" % tmsg)
	if tnode != null:
		_check(str(tnode.get_meta("ammo_type")) == "sniper"
			and is_equal_approx(float(tnode.get_meta("damage_mult")), 1.5),
			"v062(builder): turret + sniper meta ammo_type=sniper damage_mult=1.5 (got %s/%s)"
			% [str(tnode.get_meta("ammo_type")), str(tnode.get_meta("damage_mult"))])
	var tmsg2: String = _builder_script.build(
		{"spec_version": 1, "action": "spawn", "target": "turret",
		"params": {"position": "near_player", "duration_sec": 45, "ammo_type": "buckshot"},
		"cost": 300, "ttl": 0}, ctx)
	var tnode2: Node = _builder_script.last_built_node
	_check(not tmsg2.begins_with(_builder_script.FAIL_PREFIX) and tnode2 != null
		and is_equal_approx(float(tnode2.get_meta("damage_mult")), 1.3)
		and is_equal_approx(float(tnode2.get_meta("range_mult")), 0.6),
		"v062(builder): turret + buckshot meta damage_mult=1.3 range_mult=0.6 (got %s/%s)"
		% [str(tnode2.get_meta("damage_mult") if tnode2 != null else "null"),
			str(tnode2.get_meta("range_mult") if tnode2 != null else "null")])


## Live (not queued-for-free) WeaponManager child with this Arsenal id.
## Mirrors the builder's newest-first search: skips queued-for-free old
## weapons so a replaced slot never masquerades as the fresh build.
func _find_live_weapon(arsenal_id: String) -> Node:
	if _wm == null:
		return null
	var kids := _wm.get_children()
	for i in range(kids.size() - 1, -1, -1):
		var kid := kids[i] as Node
		if kid == null or kid.is_queued_for_deletion():
			continue
		if str(kid.get("weapon_id")) == arsenal_id:
			return kid
	return null
