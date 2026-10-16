# scripts/forge/forge_session_make.gd
# FORGEFALL — Forge MAKE (v0.5.3, session-scoped creation).
# Applies an already-validated BLOCK candidate from the generation
# pipeline (ModCreator.generate -> generation_ready) IN THIS MATCH ONLY.
#
# SESSION-SCOPING (binding): this file performs NO file I/O and calls
# NO install path. The candidate Dictionary lives in memory only; the
# built nodes live in the scene tree and die with the match. There is
# no registry, no cache, and nothing to clean up — a MAKE'd thing
# cannot outlive its session because it is never written anywhere.
# Create-a-Mod (ModCreator.install) remains the ONLY path that saves a
# permanent mod.
#
# APPLICATION PATH: block candidates go through
# ForgeBuilder.build_session_block, which routes the block_info through
# the SAME _build_json_mod path an installed block mod uses — a MAKE'd
# block behaves identically to an installed one for this match
# (structures get placed, weapons become usable, effects apply).
# Script candidates are REFUSED here (and in the menu): running
# unsaved code would need a disk file (ModLoader, file-backed) or
# dynamic code loading (blocked in scripts/forge/* by the no-exec
# rule). The refusal names the Create-a-Mod path instead of silently
# falling back to a preset.
#
# Validation lives in the caller: the menu re-checks the candidate
# with ModCreator.validate() (read-only) before calling apply_candidate.
# This function re-checks only shape (error field, kind, payload parses,
# target allowlist) and trusts the pipeline's validation for the rest.
extends RefCounted
class_name ForgeSessionMake

const SESSION_TARGETS := ["weapon", "cover", "structure", "turret", "pickup"]


## Applies a validated BLOCK candidate in-session.
## Returns {"ok": bool, "message": String}. Never writes anything.
static func apply_candidate(candidate: Dictionary, player: Node3D, root: Node) -> Dictionary:
	if root == null:
		return {"ok": false, "message": "no world to build in."}
	var err := str(candidate.get("error", ""))
	if not err.is_empty():
		return {"ok": false, "message": err}
	if str(candidate.get("kind", "")) != "block":
		return {"ok": false, "message": "MAKE can only build block mods in-session — script mods must be installed via Create-a-Mod first."}
	var payload := str(candidate.get("payload", ""))
	if payload.strip_edges().is_empty():
		return {"ok": false, "message": "candidate payload is empty."}
	var data: Variant = JSON.parse_string(payload)
	if not (data is Dictionary):
		return {"ok": false, "message": "block payload is not a JSON object."}
	var block: Dictionary = data as Dictionary
	# v0.5.3: hooks live NEXT TO the block in the payload
	# ({"block": {...}, "hooks": [...]}) or inside the block dict itself.
	# The old code unwrapped only the block and dropped the hooks, so a
	# MAKE'd weapon lost them. Carry them through to the builder.
	var hooks: Array = []
	if block.get("hooks") is Array:
		hooks = (block.get("hooks") as Array).duplicate(true)
	if block.has("block") and block["block"] is Dictionary:
		block = block["block"] as Dictionary
		if hooks.is_empty() and block.get("hooks") is Array:
			hooks = (block.get("hooks") as Array).duplicate(true)
	var target := str(block.get("target", ""))
	if target not in SESSION_TARGETS:
		return {"ok": false, "message": "block target '%s' is not buildable in-session." % target}
	var msg := ForgeBuilder.build_session_block(block, player, root, hooks, str(candidate.get("mod_id", "")))
	if msg.begins_with(ForgeBuilder.FAIL_PREFIX):
		return {"ok": false, "message": msg.trim_prefix(ForgeBuilder.FAIL_PREFIX)}
	return {"ok": true, "message": msg}
