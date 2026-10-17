# FORGEFALL — ForgeBuilder (Worker 8: Forge system)
# Turns a validated ModSpec v1 Dictionary into live Godot nodes.
#
# Static entry: ForgeBuilder.build(spec, ctx) -> String (result message).
# ctx carries {"player": Node3D, "root": Node} from the Forge autoload.
# Failure messages are prefixed "FORGE_FAIL: " so the manager can refund
# the spent budget; success messages are plain human-readable text.
#
# Cross-worker contracts honored (all verified against the landed files):
# - DestructibleCover (scripts/maps/destructible_cover.gd): .new(), set
#   vox_size (Vector3i), pitch (float), palette (Array[Color]), hp BEFORE
#   add_child(); it joins group "cover" itself in _ready().
# - ExplosionFX (scripts/fx/explosion.gd): static detonate(pos, radius, dmg).
# - AmmoPickup (scripts/weapons/ammo_pickup.gd): .new(), kind/amount vars.
# - WeaponManager (child "WeaponManager" of the player): give_weapon(id).
# - wave_manager (group "wave_manager"): apply_director_mod() with the REAL
#   schema {kind:"spawn_extra", type, count} / {kind:"weaken", taken_mult} /
#   {kind:"grenadiers"}.
# - HUD (group "hud"): announce(title, subtitle). The HUD also exposes
#   set_uav(duration) and the killstreaks signals for UAV display (v0.5).
extends RefCounted
class_name ForgeBuilder

#region TUNABLES
const COVER_PITCH_M := 0.25
const NEAR_PLAYER_DIST := 2.0
const MARK_RAY_DIST := 120.0
const ARENA_LIMIT := 60.0
const PICKUP_AMMO_AMOUNT := 90
const PICKUP_HEAL_AMOUNT := 50
const SUPPLY_FALL_HEIGHT := 40.0
const SUPPLY_FALL_TIME := 3.0
const SUPPLY_BEACON_TIME := 30.0
const SMOKE_AMOUNT := 48
const FAIL_PREFIX := "FORGE_FAIL: "
const MAX_STRUCTURES := 12
const MARKER_LIFETIME_SEC := 2.5
#endregion

## Last node a successful build produced (structure, turret, pickup) — null
## for effect-only builds (weapons, killstreaks, events). The Forge manager
## reads this for undo. Reset on every build() call.
static var last_built_node: Node = null
## World position of the last positioned build, for the spawn marker.
static var last_built_position := Vector3.ZERO
static var last_built_valid := false

const WEAPON_NAMES := {
	"manticore": "Manticore AR",
	"longeye": "Longeye DMR",
	"breacher": "Breacher Shotgun",
	"hornet": "Hornet SMG",
	"p9": "P9 Sidearm",
	"raptor": "Raptor LMG",
	"lmg": "LMG-9 ANVIL",
	"trident": "BR-3 Trident",
	"judge": "HV-44 Judge",
}
## v0.6.2: Forge prompt ids -> Arsenal.WEAPONS ids. Forge speaks
## "manticore/longeye/breacher/hornet"; Arsenal only knows
## "ar7/lr8/sg12/smg9". Without this map give_weapon() silently no-ops
## (WeaponManager.set_slot rejects unknown ids). "p9"/"raptor"/"lmg"
## match on both sides and pass through via the .get() fallback.
## New weapons: Forge "trident" -> Arsenal "br3" (BR-3 Trident burst
## rifle), Forge "judge" -> Arsenal "hv44" (HV-44 Judge heavy revolver).
const FORGE_WEAPON_IDS := {
	"manticore": "ar7",
	"longeye": "lr8",
	"breacher": "sg12",
	"hornet": "smg9",
	"trident": "br3",
	"judge": "hv44",
}
## v0.6.2: base HP recorded on solid structures (metadata "hp"/"max_hp").
## vNext (Forge batch, Worker B): structures are DESTRUCTIBLE — the
## Node3D above is now a ForgeStructure carrying live HP, damage
## feedback, and destroy-at-0 behaviour (see forge_structure.gd). The
## table below is the single source of truth for structure HP; costs
## live in STRUCTURE_COST. HP scales with size/cost: bunker > wall >
## sniper nest > bridge > stairs/ramp > cover piece / jump pad.
const STRUCTURE_BASE_HP := {
	"bridge": 300.0,
	"bunker": 600.0,
	"watchtower": 400.0,
	"ammo_depot": 300.0,
	"stairs": 250.0,
	"ramp": 250.0,
	"wall": 400.0,
	"jump_pad": 200.0,
	"cover_piece": 200.0,
	"sniper_nest": 350.0,
}
## Forge preset costs (computed; enforcement off on the direct preset
## path — see build_preset). The LLM/prompt path keeps its own cost
## handling in ForgeManager / ForgeLLM.
const STRUCTURE_COST := {
	"bridge": 120,
	"bunker": 180,
	"watchtower": 200,
	"ammo_depot": 150,
	"stairs": 100,
	"ramp": 90,
	"wall": 120,
	"jump_pad": 150,
	"cover_piece": 60,
	"sniper_nest": 220,
}
## Approx. overall bounds per structure shape (metres), used for the
## ForgeStructure damage overlay / crack / smoke / destroy centre.
const STRUCTURE_BOUNDS := {
	"bridge": Vector3(2.2, 2.6, 8.0),
	"bunker": Vector3(4.4, 2.8, 4.4),
	"watchtower": Vector3(3.6, 5.1, 3.6),
	"ammo_depot": Vector3(3.8, 2.4, 1.2),
	"stairs": Vector3(2.2, 3.6, 9.0),
	"ramp": Vector3(2.2, 2.4, 8.0),
	"wall": Vector3(6.0, 3.0, 0.6),
	"jump_pad": Vector3(2.0, 0.8, 2.0),
	"cover_piece": Vector3(3.0, 1.2, 0.6),
	"sniper_nest": Vector3(3.6, 4.4, 3.6),
}
const REINFORCED_HP_MULT := 1.5
const TURRET_SCRIPT := preload("res://scripts/forge/forge_turret.gd")


## True when `shape` is a buildable Forge structure (Worker B: the
## geometry dispatcher + ghost + placement all key off this table).
static func is_structure_shape(shape: String) -> bool:
	return STRUCTURE_BASE_HP.has(shape)


## Computed cost of a structure preset, or -1 for unknown shapes.
## Enforcement is OFF on the direct preset path (build_preset) — the
## value is for display / the prompt path's recompute.
static func structure_cost(shape: String) -> int:
	return int(STRUCTURE_COST.get(shape, -1))


static func structure_bounds(shape: String) -> Vector3:
	return STRUCTURE_BOUNDS.get(shape, Vector3(2.0, 2.0, 2.0)) as Vector3


## True when the structure cap (12) is already reached.
static func structure_cap_reached() -> bool:
	return _structure_count() >= MAX_STRUCTURES


## Direct preset build (Worker B): builds one structure preset at
## "near_player" without going through the ForgeManager budget pipeline.
## Cost is computed via structure_cost() but NOT charged (enforcement
## off); the structure-cap check still applies. The Forge menu preset
## buttons call this; the LLM/prompt path keeps using build() via the
## manager with its own budget handling.
static func build_preset(shape: String, player: Node3D, root: Node) -> String:
	if not is_structure_shape(shape):
		return FAIL_PREFIX + "unknown structure '%s'." % shape
	return build({
		"spec_version": 1,
		"action": "spawn",
		"target": "structure",
		"params": {"shape": shape, "position": "near_player"},
		"cost": 0,
		"ttl": 0,
	}, {"player": player, "root": root})


## Shared geometry dispatcher (Worker B): builds one structure shape's
## voxel geometry into `parent` (visuals) + `body` (colliders). Used by
## _build_structure for real builds AND by ForgeGhost for previews, so
## the ghost shows the exact geometry that will be placed. Behaviour
## nodes (e.g. the jump-pad Area3D) are added to `parent`; the ghost
## strips them after building.
static func build_shape_geometry(shape: String, parent: Node3D, body: StaticBody3D) -> void:
	var pal := VoxelBuilder.PALETTE
	match shape:
		"bridge":
			_build_bridge(parent, body, pal)
		"bunker":
			_build_bunker(parent, body, pal)
		"watchtower":
			_build_watchtower(parent, body, pal)
		"ammo_depot":
			_build_ammo_depot(parent, body, pal)
		"stairs":
			_build_stairs(parent, body, pal)
		"ramp":
			_build_ramp(parent, body, pal)
		"wall":
			_build_wall_structure(parent, body, pal)
		"jump_pad":
			_build_jump_pad(parent, body, pal)
		"cover_piece":
			_build_cover_piece(parent, body, pal)
		"sniper_nest":
			_build_sniper_nest(parent, body, pal)


static func build(spec: Dictionary, ctx: Dictionary) -> String:
	last_built_node = null
	last_built_valid = false
	var target := str(spec.get("target", ""))
	var params: Dictionary = spec.get("params", {})
	if params == null:
		params = {}
	var player: Node3D = ctx.get("player") as Node3D
	var root: Node = ctx.get("root")
	if root == null:
		return FAIL_PREFIX + "no world to build in."
	# v0.7 USER MODS: a spec referencing an enabled user-mod block builds
	# from that block (JSON data or ModBlock script) instead of the base
	# catalog. The gate already validated the reference.
	if params.has("mod_block"):
		return _build_mod_block(spec, params, player, root)
	match target:
		"cover":
			return _build_cover(params, player, root)
		"structure":
			return _build_structure(params, player, root)
		"turret":
			return _build_turret(params, player, root)
		"emitter":
			return _build_emitter(params, player, root)
		"pickup":
			return _build_pickup(params, player, root)
		"weapon":
			return _build_weapon(params, player)
		"enemy_mod":
			return _build_enemy_mod(params, root)
		"enemy_spawn":
			return _build_enemy_spawn(params, root)
		"killstreak":
			return _build_killstreak(params, player, root)
		"arena_event":
			return _build_arena_event(params, player, root)
	return FAIL_PREFIX + "unknown target '%s'." % target


# --- User-mod builds (v0.7) --------------------------------------------------
# A spec with params.mod_block builds from a validated user mod instead
# of the base catalog. The gate already checked the reference (enabled,
# error-free, target match) and recomputed the cost from the mod's
# declared cost. Failures here are graceful FAIL_PREFIX strings, never
# crashes: a mod that fails to load / apply refunds via the manager.

## v0.5.12 UNIFIED GIVE PATH: builds an installed weapon-mod for a
## player through the SAME route Forge uses for a mod_block weapon
## spec — so Forge ("give me the taquito launcher"), Arsenal, and
## Loadouts all construct a script-mod weapon identically. JSON mods
## never come here (Arsenal builds them from stats); this is for
## SCRIPT mods, whose behaviour lives in ModBlock.apply() code. The
## script's apply() typically calls api.give_weapon(base, ...) which
## lands the base weapon on the player's WeaponManager, and the
## pending-attach pair rule (see ModHookRegistry) attaches the mod's
## hooks — callers that bypass the ForgeManager gate must call
## ModLoader.find_mod(mod_id) twice first (WeaponManager does).
## `slot` is the WeaponManager slot the weapon fills (default
## "primary"): it rides to the script as params["_slot"] so a
## script-mod weapon built for a loadout's secondary slot lands in
## secondary instead of clobbering primary. Returns the builder
## message (FAIL_PREFIX + reason on failure).
static func build_weapon_mod(mod_id: String, player: Node3D, root: Node, slot: String = "primary") -> String:
	return _build_mod_block({"target": "weapon"}, {"mod_block": mod_id, "_slot": slot}, player, root)


static func _build_mod_block(spec: Dictionary, params: Dictionary, player: Node3D, root: Node) -> String:
	var ref := str(params.get("mod_block", ""))
	var rec := ModLoader.find_mod(ref)
	if rec.is_empty():
		return FAIL_PREFIX + "unknown mod block '%s'." % ref
	if not bool(rec.get("enabled", false)) or str(rec.get("error", "")) != "":
		return FAIL_PREFIX + "mod block '%s' is disabled or broken." % ref
	var info: Dictionary = rec.get("block_info", {})
	if str(info.get("target", "")) != str(spec.get("target", "")):
		return FAIL_PREFIX + "mod block '%s' is a %s, not a %s." % [ref, str(info.get("target", "")), str(spec.get("target", ""))]
	if str(rec.get("kind", "")) == "script":
		return _build_script_mod(rec, spec, params, player, root)
	return _build_json_mod(rec, spec, params, player, root)


## Session MAKE (v0.5.3): builds a JSON-block candidate that lives in
## memory only (never installed to user://mods/). The candidate was
## already validated by the generation pipeline (ModCreator.validate);
## this routes its block_info through the SAME _build_json_mod path an
## installed block mod uses, so a MAKE'd block behaves identically to
## an installed one for this match. No file I/O, no registry, no
## persistence: the built nodes live in the scene tree and die with the
## match. Script candidates never reach here (the menu refuses them).
static func build_session_block(block_info: Dictionary, player: Node3D, root: Node, session_hooks: Array = [], session_mod_id: String = "") -> String:
	var target := str(block_info.get("target", ""))
	if target.is_empty():
		return FAIL_PREFIX + "session block has no target."
	# v0.5.3: the candidate's hooks travel on the synthetic record so
	# _build_json_mod can attach them to a MAKE'd weapon. A session mod
	# is NOT in ModLoader (never installed), so nothing here may rely
	# on a ModLoader lookup to recover the hooks.
	var hooks: Array = session_hooks.duplicate(true)
	if hooks.is_empty() and block_info.get("hooks") is Array:
		hooks = (block_info.get("hooks") as Array).duplicate(true)
	var rec := {
		"id": session_mod_id if not session_mod_id.is_empty() else str(block_info.get("block_id", "session_make")),
		"kind": "block",
		"enabled": true,
		"error": "",
		"block_info": block_info,
		"hooks": hooks,
	}
	var spec := {"target": target}
	var params := {"position": "near_player"}
	return _build_json_mod(rec, spec, params, player, root)


## JSON block: data-driven spawn through the existing builder paths, with
## the block's declared stats merged in (block wins over any duplicate
## spec keys; the spec's position / composition keys still apply).
static func _build_json_mod(rec: Dictionary, spec: Dictionary, params: Dictionary, player: Node3D, root: Node) -> String:
	var info: Dictionary = rec.get("block_info", {})
	var target := str(spec.get("target", ""))
	var display := str(info.get("display_name", rec.get("id", "mod")))
	match target:
		"weapon":
			if player == null:
				return FAIL_PREFIX + "no player to arm."
			var wm = player.get_node_or_null("WeaponManager")
			if wm == null:
				wm = player.find_child("WeaponManager", true, false)
			if wm == null or not wm.has_method("give_weapon"):
				return FAIL_PREFIX + "WeaponManager not found on player."
			var base_id := str(info.get("base_weapon_id", ""))
			var arsenal_id := str(FORGE_WEAPON_IDS.get(base_id, base_id))
			if not Arsenal.has_weapon(arsenal_id):
				return FAIL_PREFIX + "unknown weapon '%s'." % base_id
			wm.give_weapon(arsenal_id)
			var weapon := _find_fresh_weapon(wm, arsenal_id)
			if weapon != null:
				# v0.5.3: attach the mod's hooks to the fresh weapon.
				# The record's hooks are authoritative here — for an
				# installed mod they are the ModLoader record's hooks,
				# for a session MAKE they are the candidate's hooks
				# (carried on the synthetic record by
				# build_session_block). Deliberately NOT via
				# ModHookRegistry.attach_mod_to_weapon(): that helper
				# re-derives hooks through ModLoader.find_mod(mod_id),
				# which has no record for a never-installed session
				# mod and would attach empty hooks (and its find_mod
				# calls would pollute the find-pair history the
				# pending-attach path keys off). WeaponBase.set_mod
				# sets mod_id + projectile spec + hooks in one call;
				# it overwrites any pending-attach result with the
				# same (or, for MAKE, the correct) hooks.
				var rec_hooks: Array = rec.get("hooks", []) if rec.get("hooks") is Array else []
				var mod_id := str(rec.get("id", ""))
				if mod_id.is_empty():
					mod_id = str(info.get("block_id", ""))
				if weapon.has_method("set_mod"):
					weapon.call("set_mod", mod_id, _projectile_spec_from_hooks(rec_hooks), rec_hooks)
				else:
					weapon.set("mod_id", mod_id)
					weapon.set("mod_projectile_spec", _projectile_spec_from_hooks(rec_hooks))
					weapon.set("mod_hooks", rec_hooks.duplicate(true))
				if info.has("damage_mult"):
					weapon.set("damage", float(weapon.get("damage")) * float(info.get("damage_mult", 1.0)))
				if info.has("range_mult"):
					weapon.set("near_range", float(weapon.get("near_range")) * float(info.get("range_mult", 1.0)))
					weapon.set("far_range", float(weapon.get("far_range")) * float(info.get("range_mult", 1.0)))
				if info.has("mag_mult"):
					var mag_size := maxi(1, int(round(float(weapon.get("mag_size")) * float(info.get("mag_mult", 1.0)))))
					weapon.set("mag_size", mag_size)
					weapon.set("mag", mag_size)
				# v0.5.11 BURST: a weapon block may declare its fire
				# mode + burst size (e.g. "3-round burst lightning
				# gun"). The Forge grant path applies them to the
				# fresh weapon, same as the multipliers above.
				if info.has("fire_mode"):
					weapon.set("fire_mode", WeaponBase.fire_mode_from_string(str(info.get("fire_mode", ""))))
				if info.has("burst_size"):
					weapon.set("burst_size", maxi(2, int(info.get("burst_size", 3))))
				var at := str(params.get("ammo_type", info.get("ammo_type", "standard")))
				if at != "standard":
					_apply_ammo_modifiers(weapon, at)
			Sfx.play_2d("weapon_raise")
			var ammo_note := "" if str(params.get("ammo_type", info.get("ammo_type", "standard"))) == "standard" else " (%s ammo)" % str(params.get("ammo_type", info.get("ammo_type", "standard")))
			return "Forge fabricated: %s (mod)%s." % [display, ammo_note]
		"cover":
			var merged := {
				"shape": str(info.get("shape", "wall")),
				"size_voxels": info.get("size_voxels", [4, 3, 1]),
				"hp": info.get("hp", 200.0),
				"position": params.get("position", "near_player"),
				"property": str(params.get("property", info.get("property", "standard"))),
				"rotation_deg": params.get("rotation_deg", 0.0),
			}
			if info.has("color"):
				var col := _mod_color(str(info.get("color", "")))
				merged["_palette_colors"] = [col, col.darkened(0.25)] as Array[Color]
			return _build_cover(merged, player, root)
		"structure":
			return _build_structure({
				"shape": str(info.get("shape", "bridge")),
				"position": params.get("position", "near_player"),
				"property": str(params.get("property", info.get("property", "standard"))),
				"rotation_deg": params.get("rotation_deg", 0.0),
			}, player, root)
		"turret":
			var msg := _build_turret({
				"position": params.get("position", "near_player"),
				"duration_sec": params.get("duration_sec", info.get("duration_sec", 45.0)),
				"ammo_type": str(params.get("ammo_type", info.get("ammo_type", "standard"))),
				"rotation_deg": params.get("rotation_deg", 0.0),
			}, player, root)
			# The turret script fires with fixed DAMAGE/RANGE consts, so the
			# mod's multipliers land as metadata (same precedent as the
			# Forge's own turret ammo composition — recorded, no damage
			# path reads them yet).
			if last_built_node != null and is_instance_valid(last_built_node):
				var dm := float(last_built_node.get_meta("damage_mult", 1.0)) * float(info.get("damage_mult", 1.0))
				var rm := float(last_built_node.get_meta("range_mult", 1.0)) * float(info.get("range_mult", 1.0))
				last_built_node.set_meta("damage_mult", dm)
				last_built_node.set_meta("range_mult", rm)
			return msg
		"pickup":
			var pmsg := _build_pickup({
				"kind": str(info.get("kind", "ammo")),
				"position": params.get("position", "near_player"),
			}, player, root)
			if last_built_node != null and is_instance_valid(last_built_node):
				last_built_node.set("amount", int(info.get("amount", PICKUP_AMMO_AMOUNT)))
			return pmsg
	return FAIL_PREFIX + "mod block target '%s' not buildable." % target


## Script mod: instantiate its ModBlock, run apply() through ModAPI.
## GDScript has no exception catching, so "graceful" here means:
## pre-validated script (scan-time gate) + null/type checks on every step
## + a strict return contract (non-empty String = success, anything else
## = failure). A mod that hard-crashes the engine (infinite loop, stack
## overflow) cannot be contained — same bar as any GMod addon: only
## install mods you trust.
static func _build_script_mod(rec: Dictionary, spec: Dictionary, params: Dictionary, player: Node3D, root: Node) -> String:
	var target := str(spec.get("target", ""))
	if target in ["cover", "structure", "turret", "pickup"]:
		var cap := _cap_check()
		if not cap.is_empty():
			return cap
	var script_path := str(rec.get("script_path", ""))
	if script_path.is_empty():
		return FAIL_PREFIX + "script mod '%s' has no script." % str(rec.get("id", ""))
	# Loading lives in ModLoader (the no-exec check forbids dynamic
	# load() calls in scripts/forge/*).
	var inst := ModLoader.instantiate_script_mod(rec)
	if inst == null:
		return FAIL_PREFIX + "script mod '%s' failed to load." % str(rec.get("id", ""))
	var api := ModAPI.new(player, root)
	var call_params := params.duplicate()
	call_params["_target"] = target
	# v0.5.12 UNIFIED GIVE PATH: a weapon-mod build for a non-primary
	# slot (loadout secondary) tells the api which slot give_weapon()
	# fills, so the script's weapon lands in that slot instead of
	# clobbering primary. Absent _slot = "primary" (Forge default).
	if params.has("_slot"):
		api.set_give_slot(str(params.get("_slot", "primary")))
	if target in ["cover", "structure", "turret", "pickup"]:
		call_params["_position"] = snap_to_ground(_resolve_position(params.get("position", "near_player"), player, root), root)
	else:
		call_params["_position"] = Vector3.ZERO
	var result: Variant = (inst as ModBlock).apply(api, call_params)
	if not (result is String) or str(result).strip_edges().is_empty():
		return FAIL_PREFIX + "script mod '%s' produced no result." % str(rec.get("id", ""))
	# Register an API-spawned node for undo / the structure cap, when the
	# mod actually spawned one.
	if api.last_spawned != null and is_instance_valid(api.last_spawned):
		if target in ["cover", "structure", "turret", "pickup"]:
			_register_build(api.last_spawned, api.last_spawned_position, root, true)
		else:
			last_built_node = api.last_spawned
			last_built_position = api.last_spawned_position
			last_built_valid = true
	return str(result)


## The custom projectile spec for a hook list (mirrors
## ModHookRegistry.projectile_for_mod, but over the supplied hooks
## instead of a ModLoader lookup): the LAST on_fire / projectile_spawn
## hook carrying a "projectile" dict wins, tagged with its _hook_id.
## {} when no hook defines a projectile.
static func _projectile_spec_from_hooks(hooks: Array) -> Dictionary:
	var out: Dictionary = {}
	for h in hooks:
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		if str(d.get("error", "")) != "":
			continue
		if str(d.get("hook_point", "")) in ["on_fire", "projectile_spawn"] and d.has("projectile"):
			var proj: Variant = d.get("projectile", {})
			if proj is Dictionary:
				out = (proj as Dictionary).duplicate(true)
				out["_hook_id"] = str(d.get("hook_id", ""))
	return out


## Newest live weapon node on the manager with this arsenal id (skips the
## queued-for-free old weapon after set_slot()).
static func _find_fresh_weapon(wm: Node, arsenal_id: String) -> Node:
	var kids := wm.get_children()
	for i in range(kids.size() - 1, -1, -1):
		var kid := kids[i] as Node
		if kid == null or kid.is_queued_for_deletion():
			continue
		if str(kid.get("weapon_id")) == arsenal_id:
			return kid
	return null


## A JSON block's color: a VoxelBuilder palette name, or "#rrggbb" hex
## (ModLoader normalizes hex to "#rrggbb" at scan time).
static func _mod_color(color: String) -> Color:
	if color in VoxelBuilder.PALETTE:
		return VoxelBuilder.PALETTE[color]
	return Color(color)


# --- Build registration ------------------------------------------------------
# Every positioned build joins group "forge_structure" (only for real
# structures/turrets — pickups/weapons do not count toward the cap), records
# itself for undo, and drops a short-lived marker at the spawn point.

static func _register_build(node: Node, pos: Vector3, root: Node, count_toward_cap: bool) -> void:
	last_built_node = node
	last_built_position = pos
	last_built_valid = true
	if count_toward_cap and node != null:
		node.add_to_group("forge_structure")
	_spawn_marker(root, pos)


static func _structure_count() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return 0
	return tree.get_nodes_in_group("forge_structure").size()


static func _cap_check() -> String:
	if _structure_count() >= MAX_STRUCTURES:
		return FAIL_PREFIX + "Forge structure cap reached (%d) — undo a build or wait for one to break." % MAX_STRUCTURES
	return ""


## Short-lived emissive voxel marker at the build point so the player can
## see WHERE the thing landed. No ping system exists to reuse; this is a
## plain MeshInstance3D + timer free, safe headless.
static func _spawn_marker(root: Node, pos: Vector3) -> void:
	if root == null:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.5, 0.5)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.1)
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.5, 0.1, 0.9)
	mi.material_override = mat
	root.add_child(mi)
	mi.global_position = pos + Vector3(0, 2.0, 0)
	tree.create_timer(MARKER_LIFETIME_SEC).timeout.connect(
		func():
			if is_instance_valid(mi):
				mi.queue_free())


# --- Target builders ---------------------------------------------------------

## Yaw offset in degrees carried by params.rotation_deg (v0.5.7 Part B):
## clamped -180..180, 0 = default orientation. Applied AFTER the build's
## default orientation (player-facing for structures, aim-facing for
## turrets, 0 for covers), so 0 preserves today's behavior exactly.
static func _rotation_deg(params: Dictionary) -> float:
	return clampf(float(params.get("rotation_deg", 0.0)), -180.0, 180.0)


static func _build_cover(params: Dictionary, player: Node3D, root: Node) -> String:
	if not _has_script_class("DestructibleCover"):
		return FAIL_PREFIX + "cover fabricator offline."
	var cap := _cap_check()
	if not cap.is_empty():
		return cap
	var shape := str(params.get("shape", "wall"))
	var sv: Array = params.get("size_voxels", _default_cover_size(shape))
	var size := Vector3i(_sv(sv, 0, 4), _sv(sv, 1, 3), _sv(sv, 2, 1))
	var hp := clampf(float(params.get("hp", 200.0)), 50.0, 500.0)
	var reinforced := str(params.get("property", "standard")) == "reinforced"
	if reinforced:
		hp *= REINFORCED_HP_MULT
	var pos := snap_to_ground(_resolve_position(params.get("position", "near_player"), player, root), root)
	var cover := DestructibleCover.new()
	cover.vox_size = size
	cover.pitch = COVER_PITCH_M
	# v0.7: JSON mod blocks may supply a custom palette via the internal
	# "_palette_colors" param (never in player specs — the gate rejects
	# unknown params, and the builder only sets this for mod builds).
	var custom_pal: Variant = params.get("_palette_colors", null)
	if custom_pal is Array and (custom_pal as Array).size() >= 1:
		var pal_colors: Array[Color] = []
		for c in (custom_pal as Array):
			pal_colors.append(c as Color)
		cover.palette.assign(pal_colors)
	else:
		cover.palette.assign(_cover_palette(shape))  # typed Array[Color]: assign() converts
	cover.hp = hp
	# Worker B: max HP for repair (ForgeStructure.repair_target) + the
	# enemy-pressure tick (ForgeEnemyPressure child) so enemies can
	# damage and destroy Forge-built covers, same as structures.
	cover.set_meta("max_hp", hp)
	cover.set_meta("forge_kind", "cover")
	cover.add_child(ForgeEnemyPressure.new())
	cover.position = pos
	cover.rotation.y = deg_to_rad(_rotation_deg(params))
	root.add_child(cover)
	_register_build(cover, pos, root, true)
	var meters := Vector3(size) * COVER_PITCH_M
	var rot := _rotation_deg(params)
	var rot_note := "" if is_zero_approx(rot) else ", rotated %d°" % int(round(rot))
	return "Forge fabricated %s (%.1fx%.1fx%.1f m, %d HP%s%s)." % [shape, meters.x, meters.y, meters.z, int(hp), ", reinforced" if reinforced else "", rot_note]


# --- Forge structures (all 10 shapes) --------------------------------------
# Solid voxel assemblies: one ForgeStructure + one StructureBody carrying
# a box collider per voxel block. _solid() adds the visible cube AND its
# collider at the same local offset. Structures face the player's facing
# direction (local -Z = forward after look_at), so bridges/stairs ascend
# away from the player. Structures are DESTRUCTIBLE (Worker B): the
# ForgeStructure node owns HP, damage feedback, repair, and destroy-at-0
# behaviour; its StructureBody forwards take_damage() from weapon /
# explosion hits, and ForgeEnemyPressure lets enemies batter them down.

static func _build_structure(params: Dictionary, player: Node3D, root: Node) -> String:
	var cap := _cap_check()
	if not cap.is_empty():
		return cap
	var shape := str(params.get("shape", "bridge"))
	if not is_structure_shape(shape):
		return FAIL_PREFIX + "unknown structure '%s'." % shape
	# v0.6.2 composition: property "reinforced" -> +50% HP (live now:
	# ForgeStructure reads the same value as its max HP).
	var reinforced := str(params.get("property", "standard")) == "reinforced"
	var hp := float(STRUCTURE_BASE_HP.get(shape, 300.0))
	if reinforced:
		hp *= REINFORCED_HP_MULT
	var pos := snap_to_ground(_resolve_position(params.get("position", "near_player"), player, root), root)
	var s := ForgeStructure.new()
	var pal := VoxelBuilder.PALETTE
	s.setup(shape, hp, structure_bounds(shape), _debris_colors_for(shape, pal))
	root.add_child(s)
	s.global_position = pos
	if player != null:
		var fwd := -player.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length() > 0.1:
			s.look_at(pos + fwd.normalized(), Vector3.UP)
	# v0.5.7 Part B: rotation_deg yaw offset, applied AFTER the default
	# player-facing orientation (0 = today's behavior). This is what
	# makes a "diagonal ramp" actually diagonal.
	s.rotation.y += deg_to_rad(_rotation_deg(params))
	# StructureBody forwards take_damage() to the ForgeStructure — a
	# plain StaticBody3D would swallow weapon/explosion hits silently.
	var body := ForgeStructure.StructureBody.new()
	s.add_child(body)
	build_shape_geometry(shape, s, body)
	_register_build(s, pos, root, true)
	var notes: Array[String] = []
	if reinforced:
		notes.append("reinforced, %d HP" % int(hp))
	var rot := _rotation_deg(params)
	if not is_zero_approx(rot):
		notes.append("rotated %d°" % int(round(rot)))
	var hp_note := "" if notes.is_empty() else " (" + ", ".join(notes) + ")"
	if shape == "ammo_depot":
		# The depot stocks itself: one ammo cache at its base.
		spawn_pickup(root, pos + Vector3(0, 0.6, 2.2), "ammo")
		return "Forge fabricated ammo depot (crates + ammo cache)%s." % hp_note
	match shape:
		"bridge":
			return "Forge fabricated bridge (stepped ramp to a 2 m platform)%s." % hp_note
		"bunker":
			return "Forge fabricated bunker (roofed pillbox, firing gap)%s." % hp_note
		"watchtower":
			return "Forge fabricated watchtower (3 m platform, stairs, roof)%s." % hp_note
		"stairs":
			return "Forge fabricated stairs (8 steps to a 3.4 m platform)%s." % hp_note
		"ramp":
			return "Forge fabricated ramp (sloped slabs to a 2.3 m deck)%s." % hp_note
		"wall":
			return "Forge fabricated wall (6 m barrier, 3 m tall)%s." % hp_note
		"jump_pad":
			return "Forge fabricated jump pad (launch pad)%s." % hp_note
		"cover_piece":
			return "Forge fabricated cover piece (low wall)%s." % hp_note
		"sniper_nest":
			return "Forge fabricated sniper nest (elevated platform with rails)%s." % hp_note
	return "Forge fabricated %s%s." % [shape, hp_note]


## Debris palette per structure shape (destruction burst colors).
static func _debris_colors_for(shape: String, pal: Dictionary) -> Array[Color]:
	match shape:
		"bunker", "wall", "cover_piece", "bridge":
			return [pal["concrete"], pal["olive"], pal["forge_orange"]] as Array[Color]
		"watchtower", "sniper_nest", "stairs", "ramp", "ammo_depot":
			return [pal["wood"], pal["olive"], pal["forge_orange"]] as Array[Color]
		"jump_pad":
			return [pal["concrete"], pal["forge_orange"], pal["darkmetal"]] as Array[Color]
	return [pal["concrete"], pal["wood"], pal["olive"]] as Array[Color]


## One voxel block: visible cube + matching box collider, same local offset.
static func _solid(visual_parent: Node3D, body: StaticBody3D, size: Vector3, color: Color, pos: Vector3) -> void:
	visual_parent.add_child(VoxelBuilder.cube(size, color, pos))
	var cs := VoxelBuilder.collision_box(size)
	cs.position = pos
	body.add_child(cs)


## Visual-only cube (rails, stripes, trim) — no collider.
static func _visual(parent: Node3D, size: Vector3, color: Color, pos: Vector3) -> void:
	parent.add_child(VoxelBuilder.cube(size, color, pos))


static func _build_bridge(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var concrete: Color = pal["concrete"]
	var orange: Color = pal["forge_orange"]
	# Five steps rising away from the player (local -Z), then a flat deck.
	for i in range(5):
		_solid(s, body, Vector3(2.2, 0.4, 1.2), concrete, Vector3(0, 0.2 + i * 0.4, -0.6 - i * 1.2))
	_solid(s, body, Vector3(2.2, 0.4, 2.4), concrete, Vector3(0, 2.2, -6.6))
	_visual(s, Vector3(0.15, 0.9, 7.8), orange, Vector3(1.05, 2.7, -3.9))
	_visual(s, Vector3(0.15, 0.9, 7.8), orange, Vector3(-1.05, 2.7, -3.9))


static func _build_bunker(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var concrete: Color = pal["concrete"]
	var olive: Color = pal["olive"]
	_solid(s, body, Vector3(4.4, 0.4, 4.4), concrete, Vector3(0, 0.2, 0))
	_solid(s, body, Vector3(4.4, 2.2, 0.5), concrete, Vector3(0, 1.3, 1.95))
	_solid(s, body, Vector3(0.5, 2.2, 4.4), concrete, Vector3(1.95, 1.3, 0))
	_solid(s, body, Vector3(0.5, 2.2, 4.4), concrete, Vector3(-1.95, 1.3, 0))
	# Front face: two pillars, open firing gap between them.
	_solid(s, body, Vector3(0.9, 2.2, 0.5), concrete, Vector3(1.75, 1.3, -1.95))
	_solid(s, body, Vector3(0.9, 2.2, 0.5), concrete, Vector3(-1.75, 1.3, -1.95))
	_solid(s, body, Vector3(4.4, 0.4, 4.4), olive, Vector3(0, 2.6, 0))


static func _build_watchtower(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var wood: Color = pal["wood"]
	var olive: Color = pal["olive"]
	for sx in [-1.2, 1.2]:
		for sz in [-1.2, 1.2]:
			_solid(s, body, Vector3(0.4, 3.0, 0.4), wood, Vector3(sx, 1.5, sz))
	_solid(s, body, Vector3(3.2, 0.4, 3.2), wood, Vector3(0, 3.2, 0))
	# Stairs up the +Z (rear) side: six steps to the platform top (~3.4 m).
	for i in range(6):
		_solid(s, body, Vector3(1.6, 0.4, 0.9), wood, Vector3(0, 0.2 + i * 0.55, 2.05 + i * 0.8))
	# Railing (visual) + roof on posts.
	_visual(s, Vector3(3.2, 0.15, 0.15), olive, Vector3(0, 3.95, -1.55))
	_visual(s, Vector3(3.2, 0.15, 0.15), olive, Vector3(0, 3.95, 1.55))
	_visual(s, Vector3(0.15, 0.15, 3.2), olive, Vector3(-1.55, 3.95, 0))
	_visual(s, Vector3(0.15, 0.15, 3.2), olive, Vector3(1.55, 3.95, 0))
	for sx in [-1.4, 1.4]:
		for sz in [-1.4, 1.4]:
			_visual(s, Vector3(0.25, 1.4, 0.25), wood, Vector3(sx, 4.1, sz))
	_solid(s, body, Vector3(3.6, 0.3, 3.6), olive, Vector3(0, 4.9, 0))


static func _build_ammo_depot(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var wood: Color = pal["wood"]
	var orange: Color = pal["forge_orange"]
	_solid(s, body, Vector3(1.2, 1.2, 1.2), wood, Vector3(-1.3, 0.6, 0))
	_solid(s, body, Vector3(1.2, 1.2, 1.2), wood, Vector3(0, 0.6, 0))
	_solid(s, body, Vector3(1.2, 1.2, 1.2), wood, Vector3(1.3, 0.6, 0))
	_solid(s, body, Vector3(1.2, 1.2, 1.2), wood, Vector3(0, 1.8, 0))
	_visual(s, Vector3(1.24, 0.25, 1.24), orange, Vector3(0, 0.6, 0))
	_visual(s, Vector3(1.24, 0.25, 1.24), orange, Vector3(0, 1.8, 0))


# --- New presets (Worker B, item 6) -----------------------------------------
# stairs / ramp / wall / jump_pad / cover_piece / sniper_nest. Same
# _solid()/_visual() vocabulary as the original four, so poly/draw
# budgets stay phone-sane (each _solid is one mesh + one collider).

## Straight staircase: 8 steps rising away from the player (-Z) to a
## 3.4 m top platform. 2.2 m wide — same footprint language as bridge.
static func _build_stairs(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var concrete: Color = pal["concrete"]
	var orange: Color = pal["forge_orange"]
	for i in range(8):
		_solid(s, body, Vector3(2.2, 0.4, 1.1), concrete, Vector3(0, 0.2 + i * 0.4, -0.55 - i * 1.1))
	_solid(s, body, Vector3(2.2, 0.4, 1.4), concrete, Vector3(0, 3.4, -9.3))
	_visual(s, Vector3(0.12, 0.9, 8.8), orange, Vector3(1.05, 2.4, -4.4))
	_visual(s, Vector3(0.12, 0.9, 8.8), orange, Vector3(-1.05, 2.4, -4.4))


## Sloped ramp: overlapping slabs (no stair lip) to a 2.3 m deck.
## Slabs overlap by 0.1 m so there are no gaps to snag on.
static func _build_ramp(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var concrete: Color = pal["concrete"]
	var orange: Color = pal["forge_orange"]
	for i in range(6):
		_solid(s, body, Vector3(2.2, 0.3, 1.35), concrete, Vector3(0, 0.15 + i * 0.36, -0.65 - i * 1.2))
	_solid(s, body, Vector3(2.2, 0.3, 1.5), concrete, Vector3(0, 2.32, -7.9))
	_visual(s, Vector3(0.12, 0.12, 7.4), orange, Vector3(1.12, 1.35, -3.9))
	_visual(s, Vector3(0.12, 0.12, 7.4), orange, Vector3(-1.12, 1.35, -3.9))


## Tall barrier wall: 6 m wide, 3 m tall, with end posts, a base trim
## and a forge-orange cap stripe. Distinct from the cover-target "wall"
## (a DestructibleCover slab) — this one is a ForgeStructure.
static func _build_wall_structure(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var concrete: Color = pal["concrete"]
	var orange: Color = pal["forge_orange"]
	_solid(s, body, Vector3(6.2, 0.3, 0.8), concrete, Vector3(0, 0.15, 0))
	_solid(s, body, Vector3(6.0, 3.0, 0.6), concrete, Vector3(0, 1.5, 0))
	_solid(s, body, Vector3(0.6, 3.2, 0.8), concrete, Vector3(-2.7, 1.6, 0))
	_solid(s, body, Vector3(0.6, 3.2, 0.8), concrete, Vector3(2.7, 1.6, 0))
	_visual(s, Vector3(6.05, 0.18, 0.64), orange, Vector3(0, 2.95, 0))


## Jump pad: low concrete base + orange launch plate + a ForgeJumpPad
## Area3D trigger that launches the player (see forge_jump_pad.gd).
static func _build_jump_pad(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var concrete: Color = pal["concrete"]
	var darkmetal: Color = pal["darkmetal"]
	var orange: Color = pal["forge_orange"]
	_solid(s, body, Vector3(2.0, 0.3, 2.0), concrete, Vector3(0, 0.15, 0))
	_visual(s, Vector3(1.6, 0.15, 1.6), orange, Vector3(0, 0.38, 0))
	for sx in [-0.85, 0.85]:
		for sz in [-0.85, 0.85]:
			_visual(s, Vector3(0.2, 0.5, 0.2), darkmetal, Vector3(sx, 0.25, sz))
	var pad := ForgeJumpPad.new()
	pad.position = Vector3(0, 0.45, 0)
	s.add_child(pad)


## Cover piece: a low wall (3 m wide, 1.1 m tall) for crouch cover,
## with an olive top rail and canvas sandbag blocks.
static func _build_cover_piece(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var concrete: Color = pal["concrete"]
	var olive: Color = pal["olive"]
	var canvas: Color = pal["canvas"]
	_solid(s, body, Vector3(3.0, 1.1, 0.6), concrete, Vector3(0, 0.55, 0))
	_visual(s, Vector3(3.05, 0.12, 0.65), olive, Vector3(0, 1.15, 0))
	_visual(s, Vector3(0.8, 0.25, 0.5), canvas, Vector3(-0.9, 1.32, 0))
	_visual(s, Vector3(0.8, 0.25, 0.5), canvas, Vector3(0.9, 1.32, 0))


## Sniper nest: watchtower's open-air cousin — legs + elevated platform
## with full rails and a solid front shooting-rest lip, reached by rear
## stairs. No roof, so the sightline stays clear.
static func _build_sniper_nest(s: Node3D, body: StaticBody3D, pal: Dictionary) -> void:
	var wood: Color = pal["wood"]
	var olive: Color = pal["olive"]
	for sx in [-1.2, 1.2]:
		for sz in [-1.2, 1.2]:
			_solid(s, body, Vector3(0.4, 3.0, 0.4), wood, Vector3(sx, 1.5, sz))
	_solid(s, body, Vector3(3.2, 0.4, 3.2), wood, Vector3(0, 3.2, 0))
	# Rear stairs: five steps to the platform top (~3.4 m).
	for i in range(5):
		_solid(s, body, Vector3(1.4, 0.4, 0.9), wood, Vector3(0, 0.2 + i * 0.6, 2.0 + i * 0.75))
	# Front shooting-rest lip (solid) + rails (visual) on the other sides.
	_solid(s, body, Vector3(3.2, 0.6, 0.2), wood, Vector3(0, 3.7, -1.5))
	_visual(s, Vector3(3.2, 0.15, 0.15), olive, Vector3(0, 3.95, 1.55))
	_visual(s, Vector3(0.15, 0.15, 3.2), olive, Vector3(-1.55, 3.95, 0))
	_visual(s, Vector3(0.15, 0.15, 3.2), olive, Vector3(1.55, 3.95, 0))


static func _build_turret(params: Dictionary, player: Node3D, root: Node) -> String:
	var cap := _cap_check()
	if not cap.is_empty():
		return cap
	var pos := snap_to_ground(_resolve_position(params.get("position", "near_player"), player, root), root)
	var ttl := clampf(float(params.get("duration_sec", 45.0)), 5.0, 120.0)
	var ammo_type := str(params.get("ammo_type", "standard"))
	var t = TURRET_SCRIPT.new()
	_apply_turret_ammo(t, ammo_type)
	# v0.5.8 elemental emitters: an "element" param turns the turret
	# into an elemental emitter turret — every shot deals its full
	# damage AS that element (see forge_turret.gd _fire).
	if params.has("element") and ElementalEmitter.is_element(str(params.get("element", ""))):
		t.set_meta("element", str(params.get("element", "")))
	t.ttl_seconds = ttl
	# Worker B: enemy-pressure tick so enemies can damage the turret
	# (its take_damage() previously had no enemy caller).
	t.add_child(ForgeEnemyPressure.new())
	t.position = pos
	if player != null:
		var away: Vector3 = pos - player.global_position
		away.y = 0.0
		if away.length() > 0.5:
			var tr: Vector3 = t.rotation
			tr.y = atan2(-away.x, -away.z)
			t.rotation = tr
	# v0.5.7 Part B: rotation_deg yaw offset after the default aim yaw.
	t.rotation.y += deg_to_rad(_rotation_deg(params))
	root.add_child(t)
	_register_build(t, pos, root, true)
	var ammo_note := "" if ammo_type == "standard" else " (%s ammo)" % ammo_type
	if t.has_meta("element"):
		ammo_note += " (%s emitter)" % str(t.get_meta("element"))
	var rot := _rotation_deg(params)
	if not is_zero_approx(rot):
		ammo_note += ", rotated %d°" % int(round(rot))
	return "Forge deployed sentry turret (%ds, 15 dmg @ 300 rpm%s)." % [int(ttl), ammo_note]


## v0.6.2 composition: turret + ammo_type. The turret script fires with
## fixed DAMAGE / RANGE consts and exposes no tuning fields, so the
## composition lands as metadata on the turret node — the same precedent
## as reinforced-structure HP metadata (recorded, no damage path reads
## it yet). Multipliers mirror the weapon ammo table: sniper x1.5 dmg,
## armor-piercing x1.25 dmg, buckshot x1.3 dmg + 0.6 range.
## "standard"/unknown = identity multipliers. A turret-script change is
## still needed before these metas change live fire behaviour.
static func _apply_turret_ammo(turret: Node, ammo_type: String) -> void:
	var damage_mult := 1.0
	var range_mult := 1.0
	match ammo_type:
		"sniper":
			damage_mult = 1.5
		"armor_piercing":
			damage_mult = 1.25
		"buckshot":
			damage_mult = 1.3
			range_mult = 0.6
	turret.set_meta("ammo_type", ammo_type)
	turret.set_meta("damage_mult", damage_mult)
	turret.set_meta("range_mult", range_mult)


## v0.5.8 elemental emitters: a free-standing emitter pylon —
## voxel particles + one elemental damage type + radius + duration,
## damaging ENEMIES ONLY inside the radius. Counts toward the
## structure cap and registers for undo like any structure.
static func _build_emitter(params: Dictionary, player: Node3D, root: Node) -> String:
	var cap := _cap_check()
	if not cap.is_empty():
		return cap
	var element := str(params.get("element", "fire"))
	if not ElementalEmitter.is_element(element):
		return FAIL_PREFIX + "unknown emitter element '%s'." % element
	var pos := snap_to_ground(_resolve_position(params.get("position", "near_player"), player, root), root)
	var radius := clampf(float(params.get("radius", 4.0)), 1.0, 10.0)
	var dur := clampf(float(params.get("duration_sec", 10.0)), 3.0, 60.0)
	var dps := clampf(float(params.get("damage_per_sec", 10.0)), 1.0, 100.0)
	var node := ElementalEmitter.spawn_field(root, element, pos, radius, dur, dps)
	if node == null:
		return FAIL_PREFIX + "could not deploy %s emitter." % element
	_register_build(node, pos, root, true)
	return "Forge deployed %s emitter (radius %.0f m, %ds, %.0f dmg/s, enemies only)." % [element, radius, int(dur), dps]


static func _build_pickup(params: Dictionary, player: Node3D, root: Node) -> String:
	var kind := str(params.get("kind", "ammo"))
	if kind != "health":
		kind = "ammo"
	var pos := snap_to_ground(_resolve_position(params.get("position", "near_player"), player, root), root)
	pos.y += 0.6
	var node := spawn_pickup(root, pos, kind)
	last_built_node = node
	last_built_position = pos
	last_built_valid = true
	_spawn_marker(root, pos)
	return "Forge dropped %s cache." % kind


## Public so the supply-drop crate can reuse it. Returns the pickup node.
static func spawn_pickup(root: Node, pos: Vector3, kind: String) -> Node:
	if _has_script_class("AmmoPickup"):
		var p := AmmoPickup.new()
		p.kind = kind
		p.amount = PICKUP_AMMO_AMOUNT if kind == "ammo" else PICKUP_HEAL_AMOUNT
		p.position = pos
		root.add_child(p)
		return p
	else:
		var f := FallbackPickup.new()
		f.kind = kind
		f.amount = PICKUP_AMMO_AMOUNT if kind == "ammo" else PICKUP_HEAL_AMOUNT
		f.position = pos
		root.add_child(f)
		return f


static func _build_weapon(params: Dictionary, player: Node3D) -> String:
	var wid := str(params.get("weapon_id", "manticore"))
	if player == null:
		return FAIL_PREFIX + "no player to arm."
	var wm = player.get_node_or_null("WeaponManager")
	if wm == null:
		wm = player.find_child("WeaponManager", true, false)
	if wm == null or not wm.has_method("give_weapon"):
		return FAIL_PREFIX + "WeaponManager not found on player."
	# v0.6.2: Forge ids -> Arsenal ids (manticore->ar7 etc.); unknown ids
	# fail loudly instead of silently no-op'ing inside set_slot().
	var arsenal_id := str(FORGE_WEAPON_IDS.get(wid, wid))
	if not Arsenal.has_weapon(arsenal_id):
		return FAIL_PREFIX + "unknown weapon '%s'." % wid
	wm.give_weapon(arsenal_id)
	# v0.6.2 composition: give_weapon() takes no modifiers, so apply the
	# ammo_type tuning to the freshly built weapon in place. Search the
	# manager's children newest-first and skip the queued-for-free old
	# weapon (set_slot queue_frees it; it keeps its id until freed).
	var ammo_type := str(params.get("ammo_type", "standard"))
	if ammo_type != "standard":
		var weapon := _find_fresh_weapon(wm, arsenal_id)
		if weapon != null:
			_apply_ammo_modifiers(weapon, ammo_type)
	# v0.5.8 elemental emitters: an "element" param makes every
	# hitscan hit deal its full damage AS that element (recorded as
	# metadata — WeaponBase reads it on hit). Composes with ammo_type.
	if params.has("element") and ElementalEmitter.is_element(str(params.get("element", ""))):
		var eweapon := _find_fresh_weapon(wm, arsenal_id)
		if eweapon != null:
			eweapon.set_meta("elemental_ammo", str(params.get("element", "")))
	Sfx.play_2d("weapon_raise")
	var ammo_note := "" if ammo_type == "standard" else " (%s ammo)" % ammo_type
	if params.has("element") and ElementalEmitter.is_element(str(params.get("element", ""))):
		ammo_note += " (%s elemental)" % str(params.get("element", ""))
	return "Forge fabricated: %s%s." % [str(WEAPON_NAMES.get(wid, wid)), ammo_note]


## v0.6.2: apply a composed ammo_type to an already-built WeaponBase by
## mutating its existing tuning fields (no new systems). Multipliers:
## sniper = harder-hitting, longer-reaching, half the mag; armor-piercing
## = harder-hitting but looser spread; buckshot = harder-hitting up close
## but shorter reach and much wider spread. "standard"/unknown = no-op.
static func _apply_ammo_modifiers(weapon: Node, ammo_type: String) -> void:
	match ammo_type:
		"sniper":
			weapon.set("damage", float(weapon.get("damage")) * 1.5)
			weapon.set("near_range", float(weapon.get("near_range")) * 1.5)
			weapon.set("far_range", float(weapon.get("far_range")) * 1.5)
			var mag_size := maxi(1, int(round(float(weapon.get("mag_size")) * 0.5)))
			weapon.set("mag_size", mag_size)
			weapon.set("mag", mag_size)
		"armor_piercing":
			weapon.set("damage", float(weapon.get("damage")) * 1.25)
			weapon.set("spread_hip", float(weapon.get("spread_hip")) * 1.2)
			weapon.set("spread_move", float(weapon.get("spread_move")) * 1.2)
		"buckshot":
			weapon.set("damage", float(weapon.get("damage")) * 1.3)
			weapon.set("near_range", float(weapon.get("near_range")) * 0.6)
			weapon.set("far_range", float(weapon.get("far_range")) * 0.6)
			weapon.set("spread_hip", float(weapon.get("spread_hip")) * 1.6)
			weapon.set("spread_move", float(weapon.get("spread_move")) * 1.6)


static func _build_enemy_mod(params: Dictionary, root: Node) -> String:
	var wm = _wave_manager(root)
	if wm == null or not wm.has_method("apply_director_mod"):
		return FAIL_PREFIX + "no wave to weaken."
	# Player requisitions may only weaken (enrage/spawn_extra are director-only;
	# the manager rejects anything else before we get here).
	wm.apply_director_mod({"kind": "weaken", "taken_mult": 1.5, "source": "forge"})
	return "Forge: enemy force weakened (they take +50% damage)."


## "Spawn enemies": player-paid challenge wave — enemies queue into the
## wave manager's spawn queue. Nothing to remove on undo (see manager: the
## refund still applies, the spawned enemies stay).
## v0.5.8 D&D: all 8 chassis are spawnable (was grunt/rusher/marksman
## only) and params may carry "creature_type" — a 5e type override
## ("spawn an undead brute", "a fiend warlord") that the wave manager
## applies to those spawns only. The type shows in the result message
## (the Forge side of "type shows in enemy info/Forge").
static func _build_enemy_spawn(params: Dictionary, root: Node) -> String:
	var wm = _wave_manager(root)
	if wm == null or not wm.has_method("apply_director_mod"):
		return FAIL_PREFIX + "no wave manager to spawn enemies."
	var etype := str(params.get("type", "grunt"))
	if not (etype in ["grunt", "rusher", "marksman", "brute", "shredder", "suppressor", "bulwark", "warlord"]):
		etype = "grunt"
	var count := clampi(int(params.get("count", 3)), 1, 6)
	var mod := {"kind": "spawn_extra", "type": etype, "count": count, "source": "forge"}
	var ct := str(params.get("creature_type", ""))
	if DnDTypes.is_creature_type(ct):
		mod["creature_type"] = ct
	wm.apply_director_mod(mod)
	var type_note := "" if ct.is_empty() else " %s" % DnDTypes.creature_display_name(ct).to_lower()
	return "Forge: %d hostile%s %s inbound — good hunting." % [count, type_note, etype + ("s" if count != 1 else "")]


static func _build_killstreak(params: Dictionary, player: Node3D, root: Node) -> String:
	var ks = _killstreaks_node(root)
	if ks == null:
		return FAIL_PREFIX + "killstreak network offline."
	var streak := str(params.get("streak", "uav"))
	var tm := str(params.get("target", "auto"))
	# Forge-bought streaks fire immediately; the budget paid was the cost, so
	# no Game.use_killstreak() bookkeeping here (that is for earned streaks).
	return ks.trigger(streak, tm, player)


static func _build_arena_event(params: Dictionary, player: Node3D, root: Node) -> String:
	var ev := str(params.get("event", "smoke"))
	if ev == "smoke":
		var pos := _resolve_position(params.get("position", "near_player"), player, root)
		var dur := clampf(float(params.get("duration_sec", 20.0)), 5.0, 120.0)
		fx_smoke(root, pos, dur)
		return "Forge: smoke screen deployed (%ds)." % int(dur)
	var improvised := bool(params.get("_improvised", false))
	_spawn_supply_drop(player, root)
	if improvised:
		return "Quartermaster improvises: supply drop."
	return "Forge: supply drop inbound."


# --- Shared FX entry points --------------------------------------------------

## Explosion with graceful fallback: if the FX worker's script is missing,
## do manual radial damage + a flash so killstreaks always do SOMETHING.
static func fx_detonate(pos: Vector3, radius: float, damage: float) -> void:
	if _has_script_class("ExplosionFX"):
		ExplosionFX.detonate(pos, radius, damage)
		return
	_manual_blast(pos, radius, damage)


static func _manual_blast(pos: Vector3, radius: float, damage: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return
	for e in tree.get_nodes_in_group("enemy"):
		var foe = e
		if foe is Node3D and foe.has_method("take_damage"):
			var d := pos.distance_to((foe as Node3D).global_position)
			if d <= radius:
				var fall := 1.0 - (d / maxf(radius, 0.001)) * 0.6
				foe.take_damage(damage * fall, (foe as Node3D).global_position, false)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.6, 0.15, 0.6)
	mi.material_override = mat
	tree.current_scene.add_child(mi)
	mi.global_position = pos
	mi.scale = Vector3.ONE * radius * 0.4
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * radius, 0.25)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.25)
	tw.chain().tween_callback(mi.queue_free)
	Sfx.play_3d("explosion_big", pos)


## Gray smoke puff that lingers `duration_sec`, then dissipates and frees.
static func fx_smoke(root: Node, pos: Vector3, duration_sec: float) -> void:
	var p := GPUParticles3D.new()
	p.amount = SMOKE_AMOUNT
	p.lifetime = 2.5
	p.preprocess = 1.0
	p.explosiveness = 0.15
	p.visibility_aabb = AABB(Vector3(-8, -1, -8), Vector3(16, 12, 16))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 40.0
	pm.initial_velocity_min = 0.8
	pm.initial_velocity_max = 1.8
	pm.gravity = Vector3(0, 0.5, 0)
	pm.damping_min = 0.4
	pm.damping_max = 0.8
	pm.scale_min = 1.4
	pm.scale_max = 2.8
	pm.color = Color(0.62, 0.62, 0.65, 0.5)
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(0.6, 0.6, 0.63, 0.42)
	quad.material = mat
	p.draw_pass_1 = quad
	root.add_child(p)
	p.global_position = pos + Vector3(0, 0.5, 0)
	p.emitting = true
	var tree := Engine.get_main_loop() as SceneTree
	tree.create_timer(duration_sec).timeout.connect(
		func():
			if is_instance_valid(p):
				p.emitting = false)
	tree.create_timer(duration_sec + 4.0).timeout.connect(
		func():
			if is_instance_valid(p):
				p.queue_free())


# --- Supply drop --------------------------------------------------------------

static func _spawn_supply_drop(player: Node3D, root: Node) -> void:
	var pos := _drop_position(player, root)
	var crate := SupplyCrate.new()
	crate.target_y = pos.y
	root.add_child(crate)
	crate.global_position = pos + Vector3(0, SUPPLY_FALL_HEIGHT, 0)
	Sfx.play_2d("ui_confirm")


static func _drop_position(player: Node3D, root: Node) -> Vector3:
	var tree := Engine.get_main_loop() as SceneTree
	var ref := player.global_position if player != null else Vector3.ZERO
	var best := Vector3.ZERO
	var best_d := 60.0
	var found := false
	if tree != null:
		for n in tree.get_nodes_in_group("forge_pad"):
			if n is Node3D:
				var d := ref.distance_to((n as Node3D).global_position)
				if d < best_d:
					best_d = d
					best = (n as Node3D).global_position
					found = true
	if found:
		return best
	return snap_to_ground(_resolve_position("near_player", player, root), root)


## Voxel crate that falls from the sky, lands, pops a random pickup plus an
## orange beacon light, then frees itself.
class SupplyCrate extends Node3D:
	var target_y := 0.0
	var _t := 0.0
	var _start_y := 0.0
	var _landed := false

	func _ready() -> void:
		_start_y = global_position.y
		var wood: Color = VoxelBuilder.PALETTE["wood"]
		var orange: Color = VoxelBuilder.PALETTE["forge_orange"]
		add_child(VoxelBuilder.cube(Vector3(0.9, 0.9, 0.9), wood, Vector3.ZERO))
		add_child(VoxelBuilder.cube(Vector3(0.94, 0.2, 0.94), orange, Vector3.ZERO))

	func _process(delta: float) -> void:
		if _landed:
			return
		_t += delta
		var k := clampf(_t / 3.0, 0.0, 1.0)
		global_position = Vector3(global_position.x, lerpf(_start_y, target_y + 0.45, k * k), global_position.z)
		rotate_y(delta * 0.8)
		if k >= 1.0:
			_land()

	func _land() -> void:
		_landed = true
		var root := get_parent()
		var kind := "ammo" if randi() % 2 == 0 else "health"
		ForgeBuilder.spawn_pickup(root, global_position + Vector3(0, 0.4, 0), kind)
		var beacon := OmniLight3D.new()
		beacon.light_color = Color(1.0, 0.5, 0.1)
		beacon.light_energy = 2.0
		beacon.omni_range = 12.0
		beacon.shadow_enabled = false
		root.add_child(beacon)
		beacon.global_position = global_position + Vector3(0, 1.5, 0)
		Sfx.play_2d("jump_land")
		var tree := get_tree()
		tree.create_timer(30.0).timeout.connect(
			func():
				if is_instance_valid(beacon):
					beacon.queue_free())
		queue_free()


## Minimal backup pickup if the weapons worker's AmmoPickup is ever missing.
class FallbackPickup extends Area3D:
	var kind := "ammo"
	var amount := 90
	var _t := 0.0
	var _base_y := 0.0
	var _crate: Node3D = null

	func _ready() -> void:
		collision_layer = 0
		collision_mask = 1
		var cs := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 1.4
		cs.shape = sphere
		add_child(cs)
		_crate = Node3D.new()
		var col: Color = VoxelBuilder.PALETTE["olive"] if kind == "ammo" else Color(0.85, 0.12, 0.12)
		_crate.add_child(VoxelBuilder.cube(Vector3(0.5, 0.4, 0.5), col, Vector3.ZERO))
		_crate.add_child(VoxelBuilder.cube(Vector3(0.54, 0.12, 0.54), Color.WHITE, Vector3(0, 0.14, 0)))
		add_child(_crate)
		_base_y = _crate.position.y
		body_entered.connect(_on_body_entered)

	func _process(delta: float) -> void:
		_t += delta
		_crate.position.y = _base_y + sin(_t * 2.2) * 0.07
		_crate.rotate_y(delta * 1.4)

	func _on_body_entered(body) -> void:
		if not body.is_in_group("player"):
			return
		if kind == "ammo":
			var wm = body.find_child("WeaponManager", true, false)
			if wm != null and wm.has_method("add_reserve_ammo"):
				wm.add_reserve_ammo(amount)
		elif body.has_method("heal"):
			body.heal(amount)
		Sfx.play_2d("pickup")
		queue_free()


# --- Position helpers ----------------------------------------------------------

## Crosshair raycast point (the "marked" position), or a max-range fallback.
static func crosshair_point(player: Node3D) -> Vector3:
	var cam: Camera3D = null
	if player != null:
		cam = player.get_viewport().get_camera_3d()
	if cam == null:
		if player != null:
			return player.global_position + -player.global_transform.basis.z * 20.0
		return Vector3(0, 1.0, -20.0)
	var from := cam.global_position
	var to := from + -cam.global_transform.basis.z * MARK_RAY_DIST
	var hit := _ray(cam, from, to, [])
	if hit.is_empty():
		return to
	return hit["position"]


static func _resolve_position(spec: Variant, player: Node3D, root: Node) -> Vector3:
	if spec is Array:
		var a: Array = spec
		if a.size() >= 3:
			return Vector3(
				clampf(float(a[0]), -ARENA_LIMIT, ARENA_LIMIT),
				clampf(float(a[1]), 0.0, 30.0),
				clampf(float(a[2]), -ARENA_LIMIT, ARENA_LIMIT))
	if str(spec) == "marked":
		return crosshair_point(player)
	if player != null:
		var fwd := -player.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length() < 0.1:
			fwd = Vector3(0, 0, -1)
		return player.global_position + fwd.normalized() * NEAR_PLAYER_DIST
	return Vector3(0, 0, NEAR_PLAYER_DIST)


## Public (Worker B): ground-snaps `pos` by raycasting down. Used by
## ForgePlacement for ghost + move, and by the builders.
static func snap_to_ground(pos: Vector3, ref: Node) -> Vector3:
	var hit := _ray(ref, pos + Vector3(0, 12, 0), pos + Vector3(0, -12, 0), [])
	if hit.is_empty():
		return pos
	return hit["position"]


static func _ray(ref: Node, from: Vector3, to: Vector3, exclude: Array[RID]) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = null
	if ref is Node3D:
		space = (ref as Node3D).get_world_3d().direct_space_state
	else:
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null or tree.root == null:
			return {}
		space = tree.root.world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = exclude
	return space.intersect_ray(q)


static func _wave_manager(root: Node) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group("wave_manager")


## ClassDB only knows native classes; script global classes (class_name)
## are checked against the project's global class list instead.
static func _has_script_class(cls_name: String) -> bool:
	for e in ProjectSettings.get_global_class_list():
		if (e as Dictionary).get("class") == cls_name:
			return true
	return false


static func _killstreaks_node(root: Node) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group("killstreaks")


static func _sv(sv: Array, i: int, fallback: int) -> int:
	if i < sv.size():
		return clampi(int(sv[i]), 1, 12)
	return fallback


static func _default_cover_size(shape: String) -> Array:
	match shape:
		"tower":
			return [4, 10, 4]
		"barricade":
			return [6, 4, 2]
	return [8, 5, 2]


static func _cover_palette(shape: String) -> Array[Color]:
	var pal := VoxelBuilder.PALETTE
	match shape:
		"tower":
			return [pal["olive"], pal["darkmetal"]]
		"barricade":
			return [pal["wood"], pal["rust"]]
	return [pal["concrete"], Color("847f76")]
