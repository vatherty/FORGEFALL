# FORGEFALL — Forge Manager (autoload "Forge") (Worker 8: Forge system)
# Owns the Forge requisition pipeline:
#   submit_prompt(text) -> busy/cooldown gates -> ForgeLLM.request_spec()
#   -> refusal check -> STRICT ForgeLLM.validate_modspec (reject, never
#   repair; the lenient _validate_spec survives for preview/back-compat) ->
#   [budget gate — OFF while BUDGET_ENABLED = false, directive A] ->
#   ForgeBuilder.build(spec, ctx) -> forge_result(success, message).
#   build_from_code(code) runs the same pipeline from a shareable build
#   code (ForgeLLM.encode/decode_build_code) instead of a prompt.
#
# BUDGET (directive A, Colin): building is FREE for now. Costs are still
# computed (ForgeLLM.recompute_cost) and shown (preview_cost / Forge menu
# COST line), but they never block a build and nothing is spent or
# refunded. The spend/refund code paths are NOT deleted — they are gated
# behind BUDGET_ENABLED below and come back by flipping it to true.
# The structure cap (12, ForgeBuilder.MAX_STRUCTURES) is a perf guard,
# not budget, and STAYS enforced.
#
# Game is the source of truth for budget; this node only echoes
# Game.forge_budget_changed as its own budget_changed signal.
# Also hosts the Killstreaks node (input: killstreak_1/2/3) and the
# ForgeDirector node. Cooldown: 3 s between completed builds.
extends Node

#region TUNABLES
const BUILD_COOLDOWN_SEC := 3.0
const MAX_VOXEL_AXIS := 12
const MAX_TTL_SEC := 120.0
const MAX_PROMPT_CHARS := 500
## Directive A: Forge budget enforcement. false = building is free —
## costs are computed + shown but never block, spend, or refund. true =
## the original behavior returns (spend on build, refund on failure /
## undo, "Insufficient Forge budget" when short). Flip this one flag;
## every spend/refund site in this file honors it.
const BUDGET_ENABLED := false
#endregion

signal forge_result(success: bool, message: String)
signal budget_changed(amount: int)

const DirectorScript := preload("res://scripts/forge/forge_director.gd")
const PlayerClasses := preload("res://scripts/progression/classes.gd")

const VALID_ACTIONS := ["spawn", "modify", "event"]
const VALID_TARGETS := ["weapon", "cover", "turret", "pickup", "enemy_mod", "killstreak", "arena_event", "structure", "enemy_spawn", "class", "emitter"]
const VALID_SHAPES := ["wall", "tower", "barricade"]
const VALID_STRUCTURES := ["bridge", "bunker", "watchtower", "ammo_depot", "stairs", "ramp", "wall", "jump_pad", "cover_piece", "sniper_nest"]
const VALID_STREAKS := ["uav", "airstrike", "chopper"]
const VALID_EVENTS := ["smoke", "supply_drop"]
const HISTORY_CAP := 10

var _busy := false
var _last_build_msec := -1000000
var _director: Node = null
var _killstreaks: Killstreaks = null
## Submitted prompts, most recent first (cap HISTORY_CAP).
var _history: Array[String] = []
## MAKE history (v0.5.9 MAKE parity): one entry per SUCCESSFUL MAKE
## build, most recent first (cap HISTORY_CAP). Entries are
## {prompt, label, kind, target} — the prompt the player typed in the
## MAKE box, the build's result message, and what it built. Preset
## Forge builds live in _history; MAKE builds live here (a MAKE prompt
## re-sent as a Forge prompt would build the wrong thing, so the two
## histories stay separate and the menu shows both).
var _make_history: Array[Dictionary] = []
## Last SUCCESSFUL build spec (post-validation, cost recomputed) and its
## shareable build code (ForgeLLM.encode_build_code). Empty until the
## first successful build. A build-from-code success replaces both, so
## codes chain: paste -> rebuild -> copy the same code again.
var _last_spec: Dictionary = {}
var _last_build_code: String = ""
## One level of undo: {cost: int, node: Node, label: String, structural: bool}.
## structural=true means a node exists that undo removes; false means the
## effect already happened (weapon/killstreak/event) and undo only refunds.
var _undo: Dictionary = {}
var _undo_valid := false


func _ready() -> void:
	ModLoader.scan_mods()  # v0.7: user mods (user://mods/) — one-line startup hook.
	_killstreaks = Killstreaks.new()
	add_child(_killstreaks)
	_director = DirectorScript.new()
	add_child(_director)
	if Game.has_signal("forge_budget_changed"):
		Game.forge_budget_changed.connect(_on_forge_budget_changed)


## UI entry point: the player typed (or dictated) a requisition.
func submit_prompt(text: String) -> void:
	var prompt := text.strip_edges().left(MAX_PROMPT_CHARS)
	if prompt.is_empty():
		# Goal 2: DENY feedback — these early returns previously emitted
		# forge_result with no sound at all, so a denied requisition
		# felt dead. forge_fail = the established Forge error sting.
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge: empty requisition.")
		return
	# Forge gate (Gameplay Rework): building exists ONLY in Tower
	# Defense. One check here covers the whole prompt pipeline.
	if not ForgeGate.can_build():
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, ForgeGate.BLOCK_MESSAGE)
		return
	if _busy:
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge is already fabricating — one requisition at a time.")
		return
	var remaining := cooldown_remaining()
	if remaining > 0.0:
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge cooling down: %.1fs." % remaining)
		return
	_busy = true
	_history.push_front(prompt)
	if _history.size() > HISTORY_CAP:
		_history.resize(HISTORY_CAP)
	Sfx.play_2d("ui_click")
	_run_pipeline(prompt)


func is_busy() -> bool:
	return _busy


func cooldown_remaining() -> float:
	var elapsed := float(Time.get_ticks_msec() - _last_build_msec) / 1000.0
	return maxf(0.0, _effective_cooldown_sec() - elapsed)


## v0.5.8 CLASSES: wizards halve the Forge cooldown (Forge affinity).
func _effective_cooldown_sec() -> float:
	var tree := get_tree()
	if tree == null:
		return BUILD_COOLDOWN_SEC
	var player_node := tree.get_first_node_in_group("player")
	if player_node != null and player_node.has_method("class_forge_cooldown_mult"):
		return BUILD_COOLDOWN_SEC * float(player_node.call("class_forge_cooldown_mult"))
	return BUILD_COOLDOWN_SEC


func get_budget() -> int:
	var b: Variant = Game.get("forge_budget")
	if b is int or b is float:
		return int(b)
	return 0


## Cost preview: parses the prompt OFFLINE (no execution, no network, no
## budget change) and returns the cost the command would charge.
## {cost: int, ok: bool, error: String, approximation: String} — ok=false
## when unparseable. "approximation" is non-empty when the prompt maps to
## a LABELED approximation (e.g. spiral staircase -> straight stairs):
## the menu shows it in the COST line before the player confirms.
func preview_cost(prompt: String) -> Dictionary:
	var spec := ForgeLLM.parse_offline(prompt)
	if spec.has("_error"):
		return {"cost": 0, "ok": false, "error": str(spec["_error"]), "approximation": ""}
	var verdict := _validate_spec(spec)
	if not bool(verdict[0]):
		return {"cost": 0, "ok": false, "error": "Forge rejected the spec: %s." % str(verdict[1]), "approximation": ""}
	return {"cost": int(spec.get("cost", 0)), "ok": true, "error": "", "approximation": str(spec.get("_approximation", ""))}


## One level of undo: removes the last Forge-built structure (or, for
## effect-only actions, just refunds when BUDGET_ENABLED) and refunds
## the exact cost charged. With budget OFF there is nothing to refund,
## so the messages say so and refund is 0.
## {ok: bool, message: String, refund: int}.
func undo_last() -> Dictionary:
	if not _undo_valid:
		return {"ok": false, "message": "Nothing to undo", "refund": 0}
	var cost := int(_undo.get("cost", 0))
	var label := str(_undo.get("label", "last Forge build"))
	var structural := bool(_undo.get("structural", false))
	var node: Node = _undo.get("node")
	_undo = {}
	_undo_valid = false
	# The refund is the amount actually spent: cost when budget is ON,
	# 0 when OFF (building was free — nothing to give back).
	var refund := cost if BUDGET_ENABLED else 0
	if structural:
		if node == null or not is_instance_valid(node):
			return {"ok": false, "message": "Nothing to undo — the last build is already gone.", "refund": 0}
		# v0.5.9 MAKE parity: a synced build must also LEAVE the sync
		# registry, or peers keep a ghost of it (previously only the
		# NetForgeSync poll caught freed nodes). Capture the instance
		# id before freeing; notify after (no-op offline / unregistered).
		var iid := -1
		if node.has_meta("forge_instance_id"):
			iid = int(node.get_meta("forge_instance_id"))
		node.queue_free()
		if iid > 0:
			var nm := get_node_or_null("/root/NetManager")
			if nm != null and nm.has_method("forge_notify_removed"):
				nm.call("forge_notify_removed", iid)
		if refund > 0:
			Game.grant_budget(refund)
		Sfx.play_2d("forge_fail")
		var msg := "Undid: %s." % label if not BUDGET_ENABLED else "Undid: %s (refunded %d budget)." % [label, refund]
		forge_result.emit(true, msg)
		return {"ok": true, "message": msg, "refund": refund}
	if refund > 0:
		Game.grant_budget(refund)
	Sfx.play_2d("forge_fail")
	var msg2 := "Undid: %s (the effect itself stands)." % label if not BUDGET_ENABLED else "Undid: %s (refunded %d budget — the effect itself stands)." % [label, refund]
	forge_result.emit(true, msg2)
	return {"ok": true, "message": msg2, "refund": refund}


## MAKE parity (v0.5.9): applies an already-generated MAKE candidate
## through ForgeSessionMake, then gives the build the SAME treatment
## as a preset Forge build — MAKE-history record, the one undo slot,
## and the MP-sync hook (NetManager.forge_notify_placed; the session
## file already notified once, and the sync registry dedupes the second
## call). Returns {"ok": bool, "message": String, "node": Node or null,
## "target": String}. Synchronous — no busy/cooldown gates (MAKE is its
## own path; the menu gates MAKE on is_busy itself). Never writes to
## user://mods/ (ForgeSessionMake never does). A failed MAKE records
## nothing — the failure message itself is the visible feedback.
func apply_make(candidate: Dictionary, prompt: String) -> Dictionary:
	# Forge gate (Gameplay Rework): MAKE builds are builds — TD only.
	if not ForgeGate.can_build():
		return {"ok": false, "message": ForgeGate.BLOCK_MESSAGE,
			"node": null, "target": ""}
	var ctx := _build_ctx()
	var result := ForgeSessionMake.apply_candidate(
		candidate, ctx.get("player") as Node3D, ctx.get("root"))
	if not bool(result.get("ok", false)):
		return {"ok": false, "message": str(result.get("message", "MAKE failed.")),
			"node": null, "target": str(result.get("target", ""))}
	var label := str(result.get("message", "MAKE build"))
	var node: Node = result.get("node")
	var target := str(result.get("target", ""))
	var structural := target in ["cover", "structure", "turret", "pickup"] \
		and node != null and is_instance_valid(node)
	_make_history.push_front({
		"prompt": prompt.strip_edges(),
		"label": label,
		"kind": str(result.get("kind", "")),
		"target": target,
	})
	if _make_history.size() > HISTORY_CAP:
		_make_history.resize(HISTORY_CAP)
	# Same undo slot shape as preset builds (structural = node removed,
	# effect-only = message only).
	_undo = {
		"cost": 0,
		"node": node if structural else null,
		"label": label,
		"structural": structural,
		"make": true,
	}
	_undo_valid = true
	# Same MP-sync hook as _execute_spec (second notify — deduped by
	# the sync registry on the node's forge_instance_id meta).
	if structural:
		var spec: Dictionary = {}
		if node.has_meta("forge_spec") and node.get_meta("forge_spec") is Dictionary:
			spec = node.get_meta("forge_spec") as Dictionary
		var nm := get_node_or_null("/root/NetManager")
		if nm != null and nm.has_method("forge_notify_placed") and not spec.is_empty():
			nm.call("forge_notify_placed", node, spec)
	Sfx.play_2d("forge_success")
	return {"ok": true, "message": label, "node": node, "target": target}


## MAKE history entries, most recent first (cap ~10). A copy — callers
## must not mutate the manager's view of it.
func get_make_history() -> Array:
	return _make_history.duplicate(true)


## MAKE history filtered by text (case-insensitive substring over
## prompt + label). "" = all.
func search_make_history(query: String) -> Array:
	var q := query.strip_edges().to_lower()
	if q.is_empty():
		return get_make_history()
	var out: Array = []
	for entry in _make_history:
		var hay := (str(entry.get("prompt", "")) + " " + str(entry.get("label", ""))).to_lower()
		if hay.contains(q):
			out.append((entry as Dictionary).duplicate(true))
	return out


## Recent submitted prompts, most recent first (cap ~10).
func get_history() -> Array[String]:
	return _history.duplicate()


## History filtered by text (case-insensitive substring). "" = all.
func search_history(query: String) -> Array[String]:
	var q := query.strip_edges().to_lower()
	if q.is_empty():
		return get_history()
	var out: Array[String] = []
	for entry in _history:
		if entry.to_lower().contains(q):
			out.append(entry)
	return out


## Shareable code for the last successful build ("" until the first
## successful build). Copy it, send it to a friend, paste it back via
## build_from_code() to rebuild the identical spec.
func get_last_build_code() -> String:
	return _last_build_code


## Rebuilds the spec encoded in a build code (see
## ForgeLLM.encode/decode_build_code). Same busy/cooldown gates as
## submit_prompt, same validation as a fresh prompt (a pasted code is
## untrusted input: validate_modspec rejects anything outside the
## catalog). Does NOT add the code itself to prompt history.
func build_from_code(code: String) -> void:
	var trimmed := code.strip_edges()
	if trimmed.is_empty():
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Paste a build code first.")
		return
	# Forge gate (Gameplay Rework): build codes are builds — TD only.
	if not ForgeGate.can_build():
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, ForgeGate.BLOCK_MESSAGE)
		return
	if _busy:
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge is already fabricating — one requisition at a time.")
		return
	var remaining := cooldown_remaining()
	if remaining > 0.0:
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge cooling down: %.1fs." % remaining)
		return
	var spec := ForgeLLM.decode_build_code(trimmed)
	if spec.is_empty():
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "That build code didn't decode — check it and try again.")
		return
	_busy = true
	Sfx.play_2d("ui_click")
	_execute_spec(spec)


## Direct spec build (Forge batch, ghost placement): same gates +
## strict validation + history + MP-sync as the prompt path, but the
## caller supplies the full spec (e.g. a ghost-confirmed position).
## Callers do NOT set _busy — this entry owns the busy/cooldown gates.
func build_spec_direct(spec: Dictionary) -> void:
	# Forge gate (Gameplay Rework): ghost-confirmed builds are builds.
	if not ForgeGate.can_build():
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, ForgeGate.BLOCK_MESSAGE)
		return
	if _busy:
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge is already fabricating — one requisition at a time.")
		return
	var remaining := cooldown_remaining()
	if remaining > 0.0:
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge cooling down: %.1fs." % remaining)
		return
	_busy = true
	Sfx.play_2d("ui_click")
	_execute_spec(spec)


func _on_forge_budget_changed(amount: int) -> void:
	budget_changed.emit(amount)


func _build_ctx() -> Dictionary:
	# v0.5.12: current_scene can be null (headless / tests / a scene in
	# transition) — the tree root is always a valid build parent.
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	return {
		"player": get_tree().get_first_node_in_group("player") as Node3D,
		"root": root,
	}


func _run_pipeline(prompt: String) -> void:
	var llm := ForgeLLM.new()
	add_child(llm)
	llm.request_spec(prompt)
	var spec: Dictionary = await llm.spec_ready
	llm.queue_free()
	# Offline parser could not map the prompt: helpful error, no charge.
	if spec.has("_error"):
		_busy = false
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, str(spec["_error"]))
		return
	# v0.6 LLM refusal: the prompt cannot be expressed with the fixed
	# catalog. Clean refusal + suggestions, no charge, no fallback — the
	# fallback must NEVER improvise a build for a refused prompt.
	if ForgeLLM.is_refusal(spec):
		_busy = false
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, ForgeLLM.refusal_message(spec))
		return
	# v0.5.7 Part B: a LABELED approximation ("Closest I can build: ...")
	# rides on the spec as _approximation. Strip it BEFORE validation —
	# the strict gate rejects unknown top-level keys by design — and
	# carry it to _execute_spec, which appends it to the visible result
	# message. The stored / shared build code holds the stripped spec.
	var approximation_note := ""
	if spec.has("_approximation"):
		approximation_note = str(spec["_approximation"])
		spec.erase("_approximation")
	_execute_spec(spec, approximation_note)


## Shared tail of the pipeline (prompt path + build-code path): strict
## gate -> [budget gate, OFF while BUDGET_ENABLED = false] -> build ->
## undo record + last-build code. Callers set _busy = true first;
## every exit here clears it. approximation_note (prompt path only) is
## appended to the visible success message — the player sees the
## "Closest I can build: ..." label on the build that used it.
func _execute_spec(spec: Dictionary, approximation_note: String = "") -> void:
	# v0.6 STRICT gate: LLM/fallback specs are REJECTED, never repaired.
	# _validate_spec (lenient clamp/correct) stays for preview_cost and
	# back-compat only; the pipeline enforces the fixed catalog exactly.
	var verdict := ForgeLLM.validate_modspec(spec)
	if not bool(verdict[0]):
		_busy = false
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge rejected the spec: %s. Try: %s." % [str(verdict[1]), ForgeLLM.UNKNOWN_SUGGESTIONS])
		return
	# (Legacy lenient validation kept below for reference — the strict gate
	# above already passed, so this is a no-op safety net, not a repair.)
	var _legacy := _validate_spec(spec)
	if not bool(_legacy[0]):
		_busy = false
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Forge rejected the spec: %s." % str(_legacy[1]))
		return
	# v0.5.8 CLASSES: a class-swap spec never reaches ForgeBuilder —
	# the player's kit is swapped in place, mid-match, no restart.
	if str(spec.get("target", "")) == "class":
		var class_id := str((spec.get("params", {}) as Dictionary).get("class_id", ""))
		var player_node: Node = (_build_ctx().get("player") as Node)
		if player_node == null or not player_node.has_method("set_player_class"):
			_busy = false
			Sfx.play_2d("forge_fail")
			forge_result.emit(false, "No player to reclass — class swap needs a live match.")
			return
		_last_build_msec = Time.get_ticks_msec()
		var switched: bool = bool(player_node.call("set_player_class", class_id))
		_last_spec = spec.duplicate(true)
		_last_build_code = ForgeLLM.encode_build_code(spec)
		_undo = {"cost": 0, "node": null, "label": "Class swap", "structural": false}
		_undo_valid = true
		_busy = false
		Sfx.play_2d("forge_success")
		if switched:
			forge_result.emit(true, "You are now a %s — %s" % [PlayerClasses.display_name(class_id), PlayerClasses.summary(class_id)])
		else:
			forge_result.emit(true, "Already a %s — kit unchanged." % PlayerClasses.display_name(class_id))
		return
	var cost := int(spec.get("cost", 0))
	# Directive A: with BUDGET_ENABLED = false this gate is skipped
	# entirely — a build is never blocked for cost. With it true, the
	# original spend-or-deny behavior returns.
	if BUDGET_ENABLED and not Game.spend_budget(cost):
		_busy = false
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, "Insufficient Forge budget — need %d, have %d." % [cost, get_budget()])
		return
	_last_build_msec = Time.get_ticks_msec()
	var message: String = ForgeBuilder.build(spec, _build_ctx())
	_busy = false
	if message.begins_with(ForgeBuilder.FAIL_PREFIX):
		# A failed build refunds what was spent — which is nothing while
		# budget is OFF, so the refund is gated the same way.
		if BUDGET_ENABLED:
			Game.grant_budget(cost)
		Sfx.play_2d("forge_fail")
		forge_result.emit(false, message.trim_prefix(ForgeBuilder.FAIL_PREFIX))
		return
	# v0.5.7 Part B: surface the approximation label on the build.
	if not approximation_note.is_empty():
		message += " " + approximation_note
	# Forge batch (Worker C, MP Forge sync): ONE hook — notify NetManager
	# of the placed structure. After the FAIL check, so failed builds
	# never sync. Guarded + duck-typed: no-op in single-player (NetManager
	# offline) and when there is no NetManager. Sets no budget / placement
	# state; SP behavior is unchanged.
	var _nm := get_node_or_null("/root/NetManager")
	if _nm != null and _nm.has_method("forge_notify_placed"):
		_nm.call("forge_notify_placed", ForgeBuilder.last_built_node, spec)
	# Success: remember the spec + its shareable build code (the code
	# encodes the post-validation spec, cost recomputed).
	_last_spec = spec.duplicate(true)
	_last_build_code = ForgeLLM.encode_build_code(spec)
	# Record the one undo slot: structural builds (cover/structure/turret/
	# pickup) carry their node for removal; everything else refunds only
	# (when budget is ON — with it OFF there is nothing to refund).
	var target := str(spec.get("target", ""))
	var structural := target in ["cover", "structure", "turret", "pickup", "emitter"]
	_undo = {
		"cost": cost,
		"node": ForgeBuilder.last_built_node if structural else null,
		"label": message,
		"structural": structural,
	}
	_undo_valid = true
	Sfx.play_2d("forge_success")
	forge_result.emit(true, message)


## Returns [ok: bool, reason: String]. Clamps sizes/cost/ttl in place.
func _validate_spec(spec: Dictionary) -> Array:
	if spec.is_empty():
		return [false, "empty spec"]
	if int(spec.get("spec_version", 0)) != 1:
		return [false, "unsupported spec_version"]
	var action := str(spec.get("action", ""))
	var target := str(spec.get("target", ""))
	if not (action in VALID_ACTIONS):
		return [false, "bad action '%s'" % action]
	if not (target in VALID_TARGETS):
		return [false, "bad target '%s'" % target]
	if float(spec.get("cost", 0.0)) < 0.0:
		spec["cost"] = 0
	if float(spec.get("ttl", 0.0)) > MAX_TTL_SEC:
		spec["ttl"] = MAX_TTL_SEC
	if not (spec.get("params") is Dictionary):
		spec["params"] = {}
	var params: Dictionary = spec["params"]
	# v0.5.12 UNIFIED FORGE (root cause of Colin's "weapon_id missing"):
	# a spec referencing an installed mod (params.mod_block) is NOT a
	# base-catalog spec — the strict gate (validate_modspec) already
	# validated the reference + target match before this legacy check
	# runs, and the mod block itself carries the shape/stats. The old
	# code fell through to the per-target branches below, where the
	# "weapon" branch demanded a base weapon_id and rejected EVERY
	# mod_block weapon spec with "weapon_id missing" — so "give me the
	# taquito launcher" could resolve to the installed mod and still
	# never build (the COST preview showed the same error). A
	# mod_block spec passes this legacy check outright; the strict
	# gate remains the real validator.
	if params.has("mod_block"):
		return [true, "ok"]
	match target:
		"cover":
			var shape := str(params.get("shape", "wall"))
			if not (shape in VALID_SHAPES):
				params["shape"] = "wall"
			var sv: Array = params.get("size_voxels", [])
			var fixed: Array = []
			for i in range(3):
				fixed.append(clampi(int(sv[i]), 1, MAX_VOXEL_AXIS) if i < sv.size() else 4)
			params["size_voxels"] = fixed
			params["hp"] = clampf(float(params.get("hp", 200.0)), 50.0, 500.0)
		"structure":
			var shape := str(params.get("shape", "bridge"))
			if not (shape in VALID_STRUCTURES):
				return [false, "bad structure '%s' — try: bridge, bunker, watchtower, ammo depot" % shape]
		"enemy_spawn":
			if not (str(params.get("type", "grunt")) in ["grunt", "rusher", "marksman"]):
				params["type"] = "grunt"
			params["count"] = clampi(int(params.get("count", 3)), 1, 6)
		"turret":
			params["duration_sec"] = clampf(float(params.get("duration_sec", 45.0)), 5.0, MAX_TTL_SEC)
		"emitter":
			# v0.5.8: element must be a known emitter element (never
			# silently corrected to fire); numbers clamped to the
			# ForgeLLM gate's ranges.
			if not ElementalEmitter.is_element(str(params.get("element", ""))):
				return [false, "bad element '%s'" % str(params.get("element", ""))]
			params["radius"] = clampf(float(params.get("radius", 4.0)), 1.0, 10.0)
			params["duration_sec"] = clampf(float(params.get("duration_sec", 10.0)), 3.0, 60.0)
			params["damage_per_sec"] = clampf(float(params.get("damage_per_sec", 10.0)), 1.0, 100.0)
		"pickup":
			if not (str(params.get("kind", "")) in ["ammo", "health"]):
				params["kind"] = "ammo"
		"weapon":
			if str(params.get("weapon_id", "")).is_empty():
				return [false, "weapon_id missing"]
		"class":
			if not PlayerClasses.is_valid_class(str(params.get("class_id", ""))):
				return [false, "unknown class_id '%s'" % str(params.get("class_id", ""))]
			spec["cost"] = 0
		"enemy_mod":
			# Director-grade mods are off-limits to player requisitions.
			if str(params.get("mod", "")) != "weaken":
				return [false, "requisitions are limited to 'weaken'"]
		"killstreak":
			if not (str(params.get("streak", "")) in VALID_STREAKS):
				return [false, "bad streak '%s'" % str(params.get("streak", ""))]
			if not (str(params.get("target", "auto")) in ["marked", "auto"]):
				params["target"] = "auto"
		"arena_event":
			if not (str(params.get("event", "")) in VALID_EVENTS):
				return [false, "bad event '%s'" % str(params.get("event", ""))]
	return [true, "ok"]
