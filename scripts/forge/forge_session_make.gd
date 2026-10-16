# scripts/forge/forge_session_make.gd
# FORGEFALL — Forge MAKE (v0.5.9, session-scoped creation).
# Applies an already-validated candidate from the generation pipeline
# (ModCreator.generate -> generation_ready) IN THIS MATCH ONLY.
#
# SESSION-SCOPING (binding): this file performs NO file I/O and calls
# NO install path. Candidates live in memory only; built nodes live in
# the scene tree and die with the match. Create-a-Mod
# (ModCreator.install) remains the ONLY path that saves a permanent
# mod. A MAKE'd thing is never in ModLoader (no find_mod calls here,
# so the find-pair history the weapon-attach path keys off is never
# polluted).
#
# TWO CANDIDATE KINDS:
# (a) BLOCK: the block builds through ForgeBuilder.build_session_block
#     (the SAME _build_json_mod path an installed block mod uses).
#     Its hooks were already validated by the pipeline; this file
#     re-validates them with ModHook.validate_hook_data (the SAME
#     validator installed mods pass, allowlist + compile included)
#     and attaches the on_hit subset to structural builds (see below).
#     Weapon hooks attach to the weapon exactly as before.
# (b) SCRIPT: the session loader (v0.5.9, MAKE parity). The payload is
#     validated with ModLoader.validate_generated_mod — the SAME
#     validator the install path uses (forbidden-API text scan,
#     `extends ModBlock`, get_block_info/apply presence) — then
#     compiled IN MEMORY with GDScript.new() (the same pattern
#     ModHook.compile_hook_code uses for hook code; nothing is written
#     to disk, ever) and its apply(api, params) runs with the same
#     trust as an installed mod's apply() (ModAPI only). Its
#     get_hooks() go through the same hook validation as (a). The old
#     "scripts can't run in-session" refusal is gone: a script-shaped
#     MAKE that cannot run for a REAL reason returns the exact reason
#     (validation error, compile error, empty apply result, nothing
#     spawned) — never a silent refusal, never a silent fallback.
#
# STRUCTURAL HOOKS (covers / structures / turrets / pickups): a
# structure has no weapon to attach hooks to, so its session hooks run
# on ENEMY TOUCH, dispatched by a ForgeSessionWatcher child at hook
# point "on_hit" (touch == hit — see the watcher's header). Only on_hit
# hooks can fire on a structure; any other-point hook is SKIPPED and
# NAMED in the returned message, never silently dropped. Covers and
# structures additionally get their script swapped to the
# ForgeSessionCover / ForgeSessionStructure carrier so the hooks are
# readable via node.get("mod_hooks") (plain covers/structures have no
# such property and set() on a missing property is a no-op).
#
# MANAGER PARITY: ForgeManager.apply_make() is the recording layer
# (MAKE history + undo slot + MP sync). This file ALSO notifies MP
# sync directly after a structural build (NetManager.forge_notify_placed
# -> NetForgeSync.notify_local_placed, the same hook preset builds
# use), carrying a synthesized ModSpec (forge_spec meta) so the build
# syncs to peers as the plain structure — session hooks run only on
# the maker's machine; peers never auto-run another peer's code.
# The notify is idempotent (the sync registry dedupes on the node's
# forge_instance_id / forge_pending meta), so the manager's own notify
# after apply_candidate is a harmless second call.
#
# Return shape: {"ok": bool, "message": String, "node": Node or null,
# "target": String, "kind": String}. "node" is the built structural
# node, or null for weapon builds (ForgeBuilder.last_built_node goes
# stale across builds and must never be trusted for undo — the manager
# uses this field).
extends RefCounted
class_name ForgeSessionMake

const SESSION_TARGETS := ["weapon", "cover", "structure", "turret", "pickup"]
## Same hook cap as installed mods (ModLoader.MAX_HOOKS_PER_MOD).
const MAX_SESSION_HOOKS := 32

const CoverCarrier := preload("res://scripts/forge/forge_session_cover.gd")
const StructureCarrier := preload("res://scripts/forge/forge_session_structure.gd")
const WatcherScript := preload("res://scripts/forge/forge_session_watcher.gd")


## Applies a validated candidate in-session.
## Returns {"ok", "message", "node", "target", "kind"}. Never writes anything.
static func apply_candidate(candidate: Dictionary, player: Node3D, root: Node) -> Dictionary:
	if root == null:
		return _fail("no world to build in.")
	var err := str(candidate.get("error", ""))
	if not err.is_empty():
		return _fail(err)
	var kind := str(candidate.get("kind", ""))
	if kind == "block":
		return _apply_block(candidate, player, root)
	if kind == "script":
		return _apply_script(candidate, player, root)
	return _fail("MAKE cannot build kind '%s' (block or script only)." % kind)


# --- Block candidates ---------------------------------------------------------

static func _apply_block(candidate: Dictionary, player: Node3D, root: Node) -> Dictionary:
	var payload := str(candidate.get("payload", ""))
	if payload.strip_edges().is_empty():
		return _fail("candidate payload is empty.")
	var data: Variant = JSON.parse_string(payload)
	if not (data is Dictionary):
		return _fail("block payload is not a JSON object.")
	var block: Dictionary = data as Dictionary
	var hooks_raw: Array = []
	if block.get("hooks") is Array:
		hooks_raw = (block.get("hooks") as Array).duplicate(true)
	if block.has("block") and block["block"] is Dictionary:
		block = block["block"] as Dictionary
		if hooks_raw.is_empty() and block.get("hooks") is Array:
			hooks_raw = (block.get("hooks") as Array).duplicate(true)
	var target := str(block.get("target", ""))
	if target not in SESSION_TARGETS:
		return _fail("block target '%s' is not buildable in-session." % target)
	# Hooks are re-validated here (same validator as installed mods) —
	# a bad hook fails the MAKE visibly instead of attaching broken
	# behaviour to the build.
	var validated := _validate_session_hooks(hooks_raw)
	if str(validated.get("error", "")) != "":
		return _fail(str(validated.get("error", "")))
	var hooks: Array = validated.get("hooks", [])
	var build_hooks := hooks
	var skipped_note := ""
	if target in ["cover", "structure", "turret", "pickup"]:
		var split := _split_structural_hooks(hooks)
		build_hooks = split["attachable"]
		skipped_note = str(split["note"])
	var msg := ForgeBuilder.build_session_block(block, player, root, build_hooks, str(candidate.get("mod_id", "")))
	if msg.begins_with(ForgeBuilder.FAIL_PREFIX):
		return _fail(msg.trim_prefix(ForgeBuilder.FAIL_PREFIX))
	if target == "weapon":
		# Hooks already ride on the weapon via build_session_block;
		# node stays null (last_built_node is stale for weapon builds).
		return {"ok": true, "message": msg + skipped_note, "node": null, "target": target, "kind": "block"}
	var node: Node = ForgeBuilder.last_built_node
	if node == null or not is_instance_valid(node):
		return _fail("MAKE built nothing (no node was produced).")
	_attach_session(node, str(candidate.get("mod_id", "")), "block", build_hooks, _synth_spec(block, target, node))
	return {"ok": true, "message": msg + skipped_note, "node": node, "target": target, "kind": "block"}


# --- Script candidates (session code loading) ---------------------------------

static func _apply_script(candidate: Dictionary, player: Node3D, root: Node) -> Dictionary:
	var payload := str(candidate.get("payload", ""))
	if payload.strip_edges().is_empty():
		return _fail("candidate payload is empty.")
	var manifest: Dictionary = {}
	if candidate.get("manifest") is Dictionary:
		manifest = candidate.get("manifest") as Dictionary
	# SAME validator as the install path (ModLoader): forbidden-API
	# text scan + `extends ModBlock` + get_block_info/apply presence.
	# A rejection here names the exact violation.
	var verr := ModLoader.validate_generated_mod(manifest, payload)
	if verr != "":
		return _fail("MAKE script rejected: %s" % verr)
	# In-memory compile ONLY — nothing is written to disk. Same pattern
	# as ModHook.compile_hook_code for hook code.
	var scr := GDScript.new()
	scr.source_code = payload
	var cerr := scr.reload()
	if cerr != OK:
		return _fail("MAKE script failed to compile: %s" % error_string(cerr))
	if not scr.can_instantiate():
		return _fail("MAKE script cannot instantiate.")
	var inst: Variant = scr.new()
	if not (inst is ModBlock):
		return _fail("MAKE script does not extend ModBlock.")
	var mod := inst as ModBlock
	var info_v: Variant = mod.get_block_info()
	if not (info_v is Dictionary):
		return _fail("MAKE script get_block_info() did not return a Dictionary.")
	var info: Dictionary = info_v as Dictionary
	# Same block-info validation scan-time script mods pass.
	var berr := ModLoader._validate_block(info, false)
	if berr != "":
		return _fail("MAKE script block info invalid: %s" % berr)
	var target := str(info.get("target", ""))
	if target not in SESSION_TARGETS:
		return _fail("MAKE script target '%s' is not buildable in-session." % target)
	var hooks_v: Variant = mod.get_hooks()
	if not (hooks_v is Array):
		return _fail("MAKE script get_hooks() did not return an Array.")
	var validated := _validate_session_hooks(hooks_v)
	if str(validated.get("error", "")) != "":
		return _fail(str(validated.get("error", "")))
	var hooks: Array = validated.get("hooks", [])
	# apply() runs with the same trust as an installed mod's apply()
	# (ModAPI only — the forbidden scan above already rejected engine
	# access). It is NOT step/time-boxed (installed apply() isn't
	# either); only HOOKS run under the registry budget.
	var api := ModAPI.new(player, root)
	var params := {
		"_target": target,
		"_position": ForgeBuilder.snap_to_ground(
			ForgeBuilder._resolve_position("near_player", player, root), root),
	}
	var result_v: Variant = mod.apply(api, params)
	if not (result_v is String) or str(result_v).strip_edges().is_empty():
		return _fail("MAKE script produced no result (apply() returned empty — build failed).")
	var message := str(result_v)
	var make_id := str(candidate.get("mod_id", ""))
	if make_id.is_empty():
		make_id = str(info.get("block_id", "session_make"))
	if target == "weapon":
		var skipped_note := ""
		if not hooks.is_empty() and not _attach_weapon_hooks(player, info, hooks, make_id):
			skipped_note = " Hooks could not attach (no fresh weapon found)."
		return {"ok": true, "message": message + skipped_note, "node": null, "target": target, "kind": "script"}
	# Structural: the script must have spawned a node via ModAPI.
	var spawned: Variant = api.last_spawned
	if spawned == null or not is_instance_valid(spawned) or not (spawned is Node):
		return _fail("MAKE script built nothing (apply() spawned no node).")
	var node := spawned as Node
	# Register for the structure cap + PLACED STRUCTURES + undo,
	# exactly like ForgeBuilder._build_script_mod does for installed
	# script mods.
	var pos := api.last_spawned_position
	if node is Node3D:
		pos = (node as Node3D).global_position
	ForgeBuilder._register_build(node, pos, root, true)
	var split := _split_structural_hooks(hooks)
	_attach_session(node, make_id, "script", split["attachable"], _synth_spec(info, target, node))
	return {"ok": true, "message": message + str(split["note"]), "node": node, "target": target, "kind": "script"}


# --- Session hooks --------------------------------------------------------------

## Validates session hooks with the SAME validator installed mods pass
## (ModHook.validate_hook_data: schema + allowlist + compile). Returns
## {"hooks": Array (validated copies), "error": String}. "" error = OK.
## A bad hook fails the whole MAKE with the violation named — never a
## silent drop, never a repair.
static func _validate_session_hooks(raw: Array) -> Dictionary:
	if raw.size() > MAX_SESSION_HOOKS:
		return {"hooks": [], "error": "MAKE carries %d hooks (max %d, same as installed mods)" % [raw.size(), MAX_SESSION_HOOKS]}
	var out: Array = []
	var seen: Dictionary = {}
	for item in raw:
		if not (item is Dictionary):
			return {"hooks": [], "error": "MAKE hook is not an object"}
		var copy: Dictionary = (item as Dictionary).duplicate(true)
		var err := ModHook.validate_hook_data(copy)
		if err != "":
			return {"hooks": [], "error": "MAKE hook invalid: %s" % err}
		var hid := str(copy.get("hook_id", ""))
		if seen.has(hid):
			return {"hooks": [], "error": "MAKE duplicate hook_id '%s'" % hid}
		seen[hid] = true
		out.append(copy)
	return {"hooks": out, "error": ""}


## Splits structural hooks into attachable (on_hit — the only point
## that can fire on a structure, via enemy touch) and skipped. Returns
## {"attachable": Array, "note": String} where note is "" or a visible
## "hooks not attached (...)" suffix for the MAKE result message.
static func _split_structural_hooks(hooks: Array) -> Dictionary:
	var attachable: Array = []
	var skipped: Array[String] = []
	for h in hooks:
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		if str(d.get("hook_point", "")) == "on_hit":
			attachable.append(d)
		else:
			skipped.append("%s (%s)" % [str(d.get("hook_id", "?")), str(d.get("hook_point", "?"))])
	var note := ""
	if not skipped.is_empty():
		note = " Hooks not attached (cannot fire on a structure): %s." % ", ".join(skipped)
	return {"attachable": attachable, "note": note}


## Tags a structural node as a session MAKE: metas (incl. the
## synthesized forge_spec for MP sync), hook-property carrier for
## covers/structures, and the touch watcher. Idempotent for the
## watcher: at most one watcher per node.
static func _attach_session(node: Node, make_id: String, kind: String, hooks: Array, spec: Dictionary) -> void:
	node.set_meta("session_make", true)
	node.set_meta("session_make_id", make_id)
	node.set_meta("session_make_kind", kind)
	node.set_meta("session_hooks", hooks.duplicate())
	if not spec.is_empty():
		node.set_meta("forge_spec", spec)
	if hooks.is_empty():
		_notify_sync(node, spec)
		return
	_expose_hook_property(node, hooks, make_id)
	var has_watcher := false
	for child in node.get_children():
		if child is ForgeSessionWatcher:
			has_watcher = true
			break
	if not has_watcher:
		var watcher := WatcherScript.new()
		watcher.name = "SessionHookWatcher"
		watcher.setup(hooks, make_id)
		node.add_child(watcher)
	_notify_sync(node, spec)


## Makes hooks readable via node.get("mod_hooks") on covers and
## structures (plain ones have no such property — set() on a missing
## property is a silent no-op). Swaps the node's script to the
## carrier subclass and re-applies the builder's state, which
## set_script resets to defaults. Turrets / pickups have no carrier
## (ForgeTurret has no class_name to extend) — they expose hooks via
## the session_hooks meta + watcher only.
static func _expose_hook_property(node: Node, hooks: Array, make_id: String) -> void:
	if node is DestructibleCover:
		var hp: float = float(node.get("hp"))
		var vs: Vector3i = node.get("vox_size")
		var pitch: float = float(node.get("pitch"))
		var pal: Array[Color] = []
		for c in (node.get("palette") as Array):
			pal.append(c as Color)
		node.set_script(CoverCarrier)
		node.set("hp", hp)
		node.set("vox_size", vs)
		node.set("pitch", pitch)
		node.set("palette", pal)
		node.set("mod_hooks", hooks.duplicate())
		node.set("session_hooks", hooks.duplicate())
		node.set("session_make_id", make_id)
		return
	if node is ForgeStructure:
		var shape: String = str(node.get("structure_shape"))
		var shp: float = float(node.get("hp"))
		var mx: float = float(node.get("max_hp"))
		var bounds: Vector3 = node.get("bounds_size")
		var colors: Array[Color] = []
		for c in (node.get("debris_colors") as Array):
			colors.append(c as Color)
		node.set_script(StructureCarrier)
		node.set("structure_shape", shape)
		node.set("hp", shp)
		node.set("max_hp", mx)
		node.set("bounds_size", bounds)
		node.set("debris_colors", colors)
		node.set("mod_hooks", hooks.duplicate())
		node.set("session_hooks", hooks.duplicate())
		node.set("session_make_id", make_id)
		return


## MP sync: feeds this build to NetForgeSync via
## NetManager.forge_notify_placed (the same hook preset Forge builds
## use) -> NetForgeSync.notify_local_placed. No-op offline / without a
## NetManager / without a syncable spec. Idempotent: the sync registry
## dedupes on the node's forge_instance_id / forge_pending meta, so
## ForgeManager.apply_make()'s own notify after this call is harmless.
static func _notify_sync(node: Node, spec: Dictionary) -> void:
	if spec.is_empty():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var nm: Node = tree.root.get_node_or_null("NetManager")
	if nm == null or not nm.has_method("forge_notify_placed"):
		return
	nm.call("forge_notify_placed", node, spec)


## Synthesized ModSpec for a MAKE build (MP sync + the sync polling
## fallback, which reads the forge_spec meta). Params mirror the
## block_info; the sync sanitizer re-clamps them. {} when the
## block_info cannot describe the build exactly (script mods may omit
# per-target fields) — then the build stays local-only rather than
# syncing a WRONG shape.
static func _synth_spec(block_info: Dictionary, target: String, node: Node) -> Dictionary:
	var params := {}
	match target:
		"cover":
			var shape := str(block_info.get("shape", ""))
			if shape not in ["wall", "tower", "barricade"]:
				return {}
			params = {
				"shape": shape,
				"size_voxels": block_info.get("size_voxels", [4, 3, 1]),
				"hp": block_info.get("hp", 200.0),
				"property": str(block_info.get("property", "standard")),
			}
		"structure":
			var sshape := str(block_info.get("shape", ""))
			if not ForgeBuilder.is_structure_shape(sshape):
				return {}
			params = {
				"shape": sshape,
				"property": str(block_info.get("property", "standard")),
			}
		"turret":
			params = {
				"duration_sec": block_info.get("duration_sec", 45.0),
				"ammo_type": str(block_info.get("ammo_type", "standard")),
			}
		"pickup":
			var pkind := str(block_info.get("kind", "ammo"))
			if pkind != "health":
				pkind = "ammo"
			params = {"kind": pkind}
		_:
			return {}
	if node is Node3D:
		var p := (node as Node3D).global_position
		params["position"] = [p.x, p.y, p.z]
	return {"spec_version": 1, "action": "spawn", "target": target, "params": params, "cost": 0, "ttl": 0}


## Attaches session hooks to a freshly granted weapon (script MAKE
## weapons have no ModLoader record, so the registry's pending-attach
## pair rule cannot fire). Mirrors ForgeBuilder._build_json_mod's
## weapon attach. True when a weapon was found and hooked.
static func _attach_weapon_hooks(player: Node3D, info: Dictionary, hooks: Array, make_id: String) -> bool:
	if player == null:
		return false
	var wm = player.get_node_or_null("WeaponManager")
	if wm == null:
		wm = player.find_child("WeaponManager", true, false)
	if wm == null:
		return false
	var base_id := str(info.get("base_weapon_id", ""))
	var arsenal_id := str(ForgeBuilder.FORGE_WEAPON_IDS.get(base_id, base_id))
	var kids := wm.get_children()
	for i in range(kids.size() - 1, -1, -1):
		var kid := kids[i] as Node
		if kid == null or kid.is_queued_for_deletion():
			continue
		if str(kid.get("weapon_id")) != arsenal_id:
			continue
		kid.set("mod_id", make_id)
		kid.set("mod_projectile_spec", ForgeBuilder._projectile_spec_from_hooks(hooks))
		kid.set("mod_hooks", hooks.duplicate())
		return true
	return false


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "message": message, "node": null, "target": "", "kind": ""}
