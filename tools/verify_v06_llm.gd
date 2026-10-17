# verify_v06_llm.gd — headless checks for the FORGEFALL v0.6 Forge LLM chunk.
# Usage: godot --headless --path <project> --script res://tools/verify_v06_llm.gd
# Asserts:
#   (1) The system-prompt template is ONE stable constant, with the variable
#       user prompt appended LAST (source-structure inspection).
#   (2) A valid in-catalog ModSpec passes strict validation.
#   (3) Out-of-catalog ModSpecs (unknown action / invented field / code
#       string / out-of-range number) are REJECTED, and a
#       refusal spec is recognized with a suggestions-bearing message.
#       (v0.6.2: a cost mismatch is NOT a rejection — composition of known
#       blocks is allowed and the game RECOMPUTES the cost.)
#   (4) No key -> offline fallback path is taken (parse_offline + the
#       no-key branch in request_spec; no network is touched here).
#   (5) No eval / Expression / OS.execute / dynamic-load code-execution
#       path exists in scripts/forge/* (grep-level; the validator's own
#       blocklist constants and comments are allowlisted, not flagged).
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _llm_script: GDScript = null
var _llm: Node = null


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
	_check_template_structure()
	_check_valid_spec()
	_check_rejections()
	_check_refusal()
	_check_offline_fallback()
	_check_no_code_exec()
	_finish()


func _finish() -> void:
	if _fails == 0:
		print("VERIFY_V06_LLM: ALL CHECKS PASSED")
	else:
		printerr("VERIFY_V06_LLM: %d CHECK(S) FAILED" % _fails)
	quit(_fails)


# ------------------------------------------------------------------ (1)
func _check_template_structure() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	# Exactly one stable template constant.
	var first := src.find("const SYSTEM_PROMPT :=")
	_check(first >= 0, "template: const SYSTEM_PROMPT exists")
	_check(src.find("const SYSTEM_PROMPT :=", first + 1) < 0,
		"template: exactly one SYSTEM_PROMPT constant (no per-call variants)")
	# Extract the template body (between the opening and closing """).
	var body_start := src.find('"""', first)
	var body_end := src.find('"""', body_start + 3)
	var template := ""
	if body_start >= 0 and body_end > body_start:
		template = src.substr(body_start + 3, body_end - (body_start + 3))
	_check(not template.is_empty(), "template: body extracted")
	_check(template.contains("REFUSAL") and template.contains("refuse"),
		"template: contains the refusal shape")
	_check(template.contains("CATALOG") and template.contains("Never invent"),
		"template: contains the fixed catalog + never-invent rule")
	_check(template.contains("code") and template.contains("script"),
		"template: forbids invented scripts/code")
	_check(not template.contains("deepseek-chat"),
		"template: does not name the retired deepseek-chat model")
	_check(not template.contains("Forge budget") and not template.contains("%d"),
		"template: carries no variable content (no budget, no interpolation)")
	# Cache layout: stable system message FIRST, variable user message LAST.
	var sys_idx := src.find('{"role": "system", "content": SYSTEM_PROMPT}')
	var user_idx := src.find('{"role": "user", "content":')
	_check(sys_idx >= 0 and user_idx > sys_idx,
		"cache: system message (stable template) precedes the user message")
	# The user message puts the prompt LAST: format ends with the prompt.
	_check(src.contains('Player requisition: %s"'),
		"cache: user message ends with the variable prompt (prompt LAST)")
	_check(src.contains('"thinking": {"type": "disabled"}'),
		"model: thinking disabled for fast/cheap JSON (thinking is default-on)")
	_check(src.contains('const MODEL := "deepseek-flash"'),
		"model: MODEL is the verified current cheap/fast deepseek-flash")


# ------------------------------------------------------------------ (2)
func _check_valid_spec() -> void:
	var spec := {
		"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"shape": "tower", "size_voxels": [4, 10, 4],
			"position": "near_player", "hp": 350},
		"cost": 150, "ttl": 0,
	}
	var v: Array = _llm.call("validate_modspec", spec)
	_check(bool(v[0]), "strict: valid in-catalog tower spec passes")
	# Every offline-fallback output must also pass the strict gate.
	for prompt in ["build a wall", "build a tower", "spawn a turret",
			"build a bridge", "build a bunker", "build a watchtower",
			"spawn an ammo depot", "give me a sniper rifle", "call a UAV",
			"deploy a smoke screen", "weaken the enemies",
			"spawn enemies", "send a health cache", "call a supply drop"]:
		var off: Dictionary = _llm.call("parse_offline", prompt)
		_check(not off.has("_error"),
			"strict: offline fallback for '%s' is parseable" % prompt)
		if not off.has("_error"):
			var vv: Array = _llm.call("validate_modspec", off)
			_check(bool(vv[0]),
				"strict: offline fallback for '%s' passes (%s)" % [prompt, str(vv[1])])


# ------------------------------------------------------------------ (3)
func _check_rejections() -> void:
	var base := {
		"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"shape": "tower", "size_voxels": [4, 10, 4],
			"position": "near_player", "hp": 350},
		"cost": 150, "ttl": 0,
	}
	var bad_action := base.duplicate(true)
	bad_action["action"] = "teleport"
	_check(not bool((_llm.call("validate_modspec", bad_action) as Array)[0]),
		"strict: unknown action rejected")
	var bad_target := base.duplicate(true)
	bad_target["target"] = "flying_car"
	_check(not bool((_llm.call("validate_modspec", bad_target) as Array)[0]),
		"strict: unknown target rejected")
	var invented := base.duplicate(true)
	invented["script"] = "print('hi')"
	_check(not bool((_llm.call("validate_modspec", invented) as Array)[0]),
		"strict: invented field 'script' rejected")
	var code_str := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "manticore'); eval("}, "cost": 200, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", code_str) as Array)[0]),
		"strict: code string in a field rejected")
	_check(_llm.call("_is_clean_value", "eval(") == false,
		"strict: _is_clean_value flags eval( content")
	_check(_llm.call("_is_clean_value", "near_player") == true,
		"strict: _is_clean_value allows clean catalog strings")
	var wrong_cost := base.duplicate(true)
	wrong_cost["cost"] = 999
	var _wc: Array = _llm.call("validate_modspec", wrong_cost)
	_check(bool(_wc[0]) and int(wrong_cost.get("cost", -1)) == 150,
		"strict: wrong cost ACCEPTED and corrected to recomputed 150 (cost is no longer a rejection reason)")
	var bad_hp := base.duplicate(true)
	var p: Dictionary = (bad_hp["params"] as Dictionary).duplicate()
	p["hp"] = 9999
	bad_hp["params"] = p
	_check(not bool((_llm.call("validate_modspec", bad_hp) as Array)[0]),
		"strict: out-of-range hp rejected (no clamping repair)")
	var bad_size := base.duplicate(true)
	var p2: Dictionary = (bad_size["params"] as Dictionary).duplicate()
	p2["size_voxels"] = [99, 10, 4]
	bad_size["params"] = p2
	_check(not bool((_llm.call("validate_modspec", bad_size) as Array)[0]),
		"strict: out-of-range size_voxels rejected")
	var bad_weapon := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "laser_gun"}, "cost": 200, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_weapon) as Array)[0]),
		"strict: unknown weapon_id rejected")
	var bad_mod := {
		"spec_version": 1, "action": "modify", "target": "enemy_mod",
		"params": {"mod": "enrage"}, "cost": 150, "ttl": 0,
	}
	_check(not bool((_llm.call("validate_modspec", bad_mod) as Array)[0]),
		"strict: enemy_mod 'enrage' rejected (weaken only)")


# ------------------------------------------------------------------ refusal
func _check_refusal() -> void:
	var refusal := {
		"spec_version": 1, "action": "refuse", "target": "none",
		"params": {"reason": "flying cars and lasers are not in the build catalog"},
		"cost": 0, "ttl": 0,
	}
	_check(_llm.call("is_refusal", refusal) == true,
		"refusal: is_refusal recognizes the refusal shape")
	var msg: String = _llm.call("refusal_message", refusal)
	_check(msg.contains("Can't do that") and msg.contains("try:"),
		"refusal: message is a clean refusal + suggestions (got: %s)" % msg)
	_check(not bool((_llm.call("validate_modspec", refusal) as Array)[0]),
		"refusal: refusal spec is not a build spec")
	# A refusal must survive response-envelope extraction untouched, so the
	# manager can handle it instead of the offline fallback improvising.
	var envelope := JSON.stringify({"choices": [{"message": {"content": JSON.stringify(refusal)}}]})
	var extracted: Dictionary = _llm.call("_extract_spec", envelope)
	_check(_llm.call("is_refusal", extracted) == true,
		"refusal: survives _extract_spec (no fallback substitution)")
	# And a real build JSON extracts as a build spec.
	var build := {
		"spec_version": 1, "action": "spawn", "target": "weapon",
		"params": {"weapon_id": "longeye"}, "cost": 200, "ttl": 0,
	}
	var env2 := JSON.stringify({"choices": [{"message": {"content": JSON.stringify(build)}}]})
	var ex2: Dictionary = _llm.call("_extract_spec", env2)
	_check(str(ex2.get("target", "")) == "weapon",
		"extract: build JSON survives _extract_spec")


# ------------------------------------------------------------------ (4)
func _check_offline_fallback() -> void:
	var tower: Dictionary = _llm.call("parse_offline", "build a tower near me")
	_check(str(tower.get("target", "")) == "cover"
		and str((tower.get("params", {}) as Dictionary).get("shape", "")) == "tower",
		"offline: 'build a tower near me' parses to a tower spec")
	var unknown: Dictionary = _llm.call("parse_offline",
		"make a flying car that shoots lasers")
	_check(unknown.has("_error") and str(unknown["_error"]).contains("try:"),
		"offline: unexpressible prompt yields _error + suggestions, no build")
	# Structural: request_spec() takes the fallback branch when no key.
	var src := FileAccess.get_file_as_string("res://scripts/forge/forge_llm.gd")
	var key_branch := src.find("if key.is_empty():")
	_check(key_branch >= 0
		and src.find("_finish(_fallback_spec(prompt))", key_branch) > key_branch,
		"offline: request_spec falls back when the key is empty (no network)")
	_check(src.contains("ForgeConfig.load_key()"),
		"offline: key read goes through ForgeConfig (user:// only)")


# ------------------------------------------------------------------ (5)
func _check_no_code_exec() -> void:
	var dir := DirAccess.open("res://scripts/forge")
	_check(dir != null, "no-exec: scripts/forge/ readable")
	if dir == null:
		return
	var bad_patterns := ["eval(", "Expression", "OS.execute",
		"OS.create_process", "CodeEdit", "GDScript.new", "load("]
	var hits := 0
	for fname in dir.get_files():
		if not fname.ends_with(".gd"):
			continue
		var text := FileAccess.get_file_as_string("res://scripts/forge/" + fname)
		# Prompt-template strings ("""...""") are string literals, not
		# executable code: e.g. GENERATION_SYSTEM_PROMPT *mentions* the
		# forbidden tokens to tell the LLM never to emit them. Skip every
		# line inside a triple-quoted string, plus the delimiter lines.
		var in_triple := false
		for line in text.split("\n"):
			var triple := line.count('"""')
			if in_triple or triple > 0:
				if triple % 2 == 1:
					in_triple = not in_triple
				continue
			var stripped := line.strip_edges()
			# Allowlist: the validator's own blocklist constants, and
			# comments describing the no-code rule — neither executes.
			if stripped.begins_with("#") or stripped.contains("_FORBIDDEN"):
				continue
			# Session-MAKE exception (v0.5.9 MAKE parity, deliberate):
			# forge_session_make.gd — and ONLY that file — may compile
			# a session hook in memory (GDScript.new + reload) for the
			# MAKER's own in-session MAKE build. The code is never
			# persisted, never written to user://mods/, and peers never
			# auto-run it. eval/Expression/OS.* stay forbidden there too.
			if fname == "forge_session_make.gd" and (
					stripped.contains("GDScript.new") or stripped.contains("reload(")):
				continue
			for pat in bad_patterns:
				if line.contains(pat):
					# Static resource preloads/loads of res:// literals are
					# the trusted builder's normal loads, not LLM-supplied
					# code — allow them, flag any other load( call.
					if pat == "load(" and (line.contains('preload("res://')
							or line.contains('load("res://')):
						continue
					hits += 1
					printerr("FAIL: no-exec: %s contains '%s' in: %s"
						% [fname, pat, stripped])
	_check(hits == 0, "no-exec: no eval/Expression/OS.execute/dynamic-load in scripts/forge/* (session-MAKE in-memory compile in forge_session_make.gd only is the documented v0.5.9 exception)")
