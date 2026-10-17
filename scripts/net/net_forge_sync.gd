# scripts/net/net_forge_sync.gd
# FORGEFALL — Forge in Multiplayer (Forge batch, Worker C).
# Host-authoritative sync of placed Forge structures. NetManager owns the
# RPCs (see net_manager.gd); this node owns the registry, the event shape,
# validation, spawning, and the local-detection fallback. It has NO direct
# dependency on NetManager (peer context is resolved duck-typed from the
# parent, or set explicitly via set_peer_context() for tests), and NO hard
# dependency on ForgeBuilder (spawn goes through a runtime load() +
# spawn_handler override, so headless tests can inject a fake spawner).
#
# EVENT SHAPE (canonical — Worker B's destroy/move/rotate events flow
# through this same shape; Worker B never edits this file's contract,
# it calls NetManager.forge_notify_removed / forge_notify_updated):
#   entry = {"instance_id": int,            # host-assigned, > 0; 0 = provisional
#            "preset_id": String,            # e.g. "cover:wall", "structure:bunker",
#                                            # "turret", "pickup:ammo", "mod:<block_id>"
#            "owner": int,                   # peer id that placed it
#            "pos": Vector3, "rot": Vector3, # world position + euler rotation
#            "spec": Dictionary}             # rebuild params (ModSpec params,
#                                            # sanitized; position forced to pos)
#   Wire form = entry WITHOUT the local-only "node" key.
#   Local entries also carry "node": Node (the live node, may be null).
#
# FLOWS (host-authoritative, same pattern as damage/HP in NetManager):
# - Host places: ForgeManager hook -> NetManager.forge_notify_placed ->
#   host_place() (assigns id, registers) -> broadcast _rpc_forge_place.
# - Client places: hook -> provisional entry (node tagged forge_pending,
#   instance_id 0) -> _rpc_forge_request_place to host -> host validates,
#   spawns its own copy, assigns id, broadcasts -> client apply_place()
#   ADOPTS its provisional node (no duplicate) instead of spawning.
# - Destroyed on host (Worker B, or cover fracture, turret TTL, undo):
#   host_remove() -> broadcast _rpc_forge_remove -> peers apply_remove().
#   Host polling also catches queue_free'd registered nodes (fracture /
#   undo / TTL) and reports them, so Worker B needs no extra call for
#   those paths — but B's explicit destroy/move/delete calls should use
#   NetManager.forge_notify_removed / forge_notify_updated, which route
#   client->host-request / host->broadcast.
# - Move/rotate: host_update() -> broadcast _rpc_forge_update.
# - Late join: host sends _rpc_forge_sync (full wire list) on
#   peer_connected + on explicit forge_request_resync() after map load.
#
# SAFETY: unknown preset ids / malformed entries are IGNORED, never crash
# (validate + sanitize on every inbound entry). Peers never charge Forge
# budget for a synced build: apply spawns via ForgeBuilder.build()
# directly, bypassing the ForgeManager budget path. Single-player:
# NetManager.forge_notify_placed is a no-op while offline, so SP Forge
# behavior is byte-for-byte unchanged.
class_name NetForgeSync
extends Node

signal structure_placed(entry: Dictionary)
signal structure_removed(instance_id: int)
signal structure_updated(entry: Dictionary)
## A local build was detected by polling (untagged node in group
## "forge_structure", or a freed-node / transform drift on the host).
## NetManager routes it: host -> broadcast, client -> request to host.
signal local_place_detected(entry: Dictionary, node: Node)
signal local_remove_detected(instance_id: int)
signal local_update_detected(entry: Dictionary)

const MAX_ENTRIES := 64
const ARENA_LIMIT := 200.0
const POLL_INTERVAL := 0.1
const POS_EPSILON := 0.02
const ROT_EPSILON := 0.02
const PROVISIONAL_POS_EPSILON := 0.15
const PROVISIONAL_ROT_EPSILON := 0.05

const COVER_SHAPES := ["wall", "tower", "barricade"]
## All 10 structure shapes — must match ForgeBuilder.STRUCTURE_BASE_HP's
## keys (the single source of truth for buildable shapes). "wall" is a
## structure shape here AND a cover shape; the preset prefix
## ("structure:" vs "cover:") disambiguates.
const STRUCTURE_SHAPES := ["bridge", "bunker", "watchtower", "ammo_depot",
	"stairs", "ramp", "wall", "jump_pad", "cover_piece", "sniper_nest"]
const AMMO_TYPES := ["standard", "sniper", "armor_piercing", "buckshot"]
const PROPERTIES := ["standard", "reinforced"]

## Optional spawner override for tests: Callable(entry: Dictionary) -> Node.
## When set + valid it replaces the ForgeBuilder spawn path entirely.
var spawn_handler: Callable = Callable()

var _entries: Dictionary = {}  # instance_id (int) -> entry (with "node")
var _provisional: Array = []  # {entry: Dictionary, node: Node} awaiting host ack
var _next_id := 1
var _poll_t := 0.0
var _builder_script: GDScript = null
var _forge_gate_script: GDScript = null  # runtime load (see _forge_allowed)


## MP worker: remote Forge specs are gated by the SAME allowlist as
## the local pipeline (ForgeGate). No live run -> permit (menus /
## tools / the existing NetForgeSync suites, which run with no mode
## manager). Live MP Zombies / MP TDM -> host_place / apply_place
## refuse the spec, so a peer cannot smuggle a build into a
## no-Forge match over the wire. Runtime load (not a bare ForgeGate
## reference): this file is preloaded by the NetManager autoload, and
## a bare reference would drag the GameModeManager chain into the
## autoload compile.
func _forge_allowed() -> bool:
	if _forge_gate_script == null:
		if ResourceLoader.exists("res://scripts/forge/forge_gate.gd"):
			_forge_gate_script = load("res://scripts/forge/forge_gate.gd") as GDScript
		if _forge_gate_script == null:
			return true  # gate script missing: fail open (legacy behaviour)
	return bool(_forge_gate_script.call("can_build"))
# Explicit peer context (tests). When unset, resolved from the parent.
var _peer_ctx_set := false
var _peer_online := false
var _peer_host := false
var _peer_id := 0


func set_peer_context(online: bool, is_host: bool, local_id: int) -> void:
	_peer_ctx_set = true
	_peer_online = online
	_peer_host = is_host
	_peer_id = local_id


func _resolve_online() -> bool:
	if _peer_ctx_set:
		return _peer_online
	var p := get_parent()
	if p != null and p.has_method("is_online"):
		return bool(p.call("is_online"))
	return false


func _resolve_host() -> bool:
	if _peer_ctx_set:
		return _peer_host
	var p := get_parent()
	if p != null and p.get("is_host") != null:
		return bool(p.get("is_host"))
	return false


func _resolve_local_id() -> int:
	if _peer_ctx_set:
		return _peer_id
	var p := get_parent()
	if p != null and p.get("local_id") != null:
		return int(p.get("local_id"))
	return 0


# --- preset / spec -----------------------------------------------------------

## ModSpec -> preset id. "" = not a placed structure (weapon, killstreak,
## enemy_mod, arena_event, enemy_spawn) — those are never synced.
static func preset_id_for_spec(spec: Dictionary) -> String:
	if spec.is_empty() or not (spec.get("params") is Dictionary):
		return ""
	var params: Dictionary = spec["params"]
	if params.has("mod_block"):
		var bid := str(params.get("mod_block", ""))
		if bid.is_empty():
			return ""
		return "mod:" + bid
	var target := str(spec.get("target", ""))
	match target:
		"cover":
			var shape := str(params.get("shape", ""))
			if shape in COVER_SHAPES:
				return "cover:" + shape
		"structure":
			var shape := str(params.get("shape", ""))
			if shape in STRUCTURE_SHAPES:
				return "structure:" + shape
		"turret":
			return "turret"
		"pickup":
			var kind := str(params.get("kind", "ammo"))
			if kind != "health":
				kind = "ammo"
			return "pickup:" + kind
	return ""


static func _is_valid_preset(preset_id: String) -> bool:
	if preset_id == "turret":
		return true
	if preset_id.begins_with("cover:"):
		return preset_id.substr("cover:".length()) in COVER_SHAPES
	if preset_id.begins_with("structure:"):
		return preset_id.substr("structure:".length()) in STRUCTURE_SHAPES
	if preset_id.begins_with("pickup:"):
		return preset_id.substr("pickup:".length()) in ["ammo", "health"]
	if preset_id.begins_with("mod:"):
		var bid := preset_id.substr("mod:".length())
		if bid.is_empty():
			return false
		for c in bid:
			if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
				return false
		return true
	return false


## Sanitized rebuild spec for an entry: preset-consistent params, position
## forced to the entry position. Returns {} when the spec cannot be made
## consistent with the preset (unknown preset -> ignored, never crash).
static func sanitize_spec(spec: Dictionary, preset_id: String, pos: Vector3) -> Dictionary:
	if not _is_valid_preset(preset_id):
		return {}
	if spec.is_empty() or not (spec.get("params") is Dictionary):
		return {}
	var out := spec.duplicate(true)
	var params: Dictionary = out["params"]
	if preset_id.begins_with("mod:"):
		params["mod_block"] = preset_id.substr("mod:".length())
		params["position"] = [pos.x, pos.y, pos.z]
		return out
	if preset_id.begins_with("cover:"):
		out["target"] = "cover"
		params["shape"] = preset_id.substr("cover:".length())
		var sv: Array = params.get("size_voxels", [])
		var fixed: Array = []
		for i in range(3):
			fixed.append(clampi(int(sv[i]), 1, 12) if i < sv.size() else 4)
		params["size_voxels"] = fixed
		params["hp"] = clampf(float(params.get("hp", 200.0)), 50.0, 500.0)
		var prop := str(params.get("property", "standard"))
		params["property"] = prop if prop in PROPERTIES else "standard"
		params["position"] = [pos.x, pos.y, pos.z]
		return out
	if preset_id.begins_with("structure:"):
		out["target"] = "structure"
		params["shape"] = preset_id.substr("structure:".length())
		var prop := str(params.get("property", "standard"))
		params["property"] = prop if prop in PROPERTIES else "standard"
		params["position"] = [pos.x, pos.y, pos.z]
		return out
	if preset_id == "turret":
		out["target"] = "turret"
		params["duration_sec"] = clampf(float(params.get("duration_sec", 45.0)), 5.0, 120.0)
		var at := str(params.get("ammo_type", "standard"))
		params["ammo_type"] = at if at in AMMO_TYPES else "standard"
		params["position"] = [pos.x, pos.y, pos.z]
		return out
	if preset_id.begins_with("pickup:"):
		out["target"] = "pickup"
		params["kind"] = preset_id.substr("pickup:".length())
		params["position"] = [pos.x, pos.y, pos.z]
		return out
	return {}


## Validate + sanitize a wire entry. Returns a clean wire entry (no "node")
## or {} when the entry must be ignored (unknown preset, bad id, NaN /
## out-of-arena transform, spec/preset mismatch). Never crashes on
## malformed input: every field is type-checked first.
static func sanitize_entry(entry: Dictionary) -> Dictionary:
	if entry.is_empty():
		return {}
	var iid: Variant = entry.get("instance_id", 0)
	if not (iid is int) or iid < 0:
		return {}
	var preset_id := str(entry.get("preset_id", ""))
	if not _is_valid_preset(preset_id):
		return {}
	var owner: Variant = entry.get("owner", 0)
	if not (owner is int) or owner < 0:
		return {}
	var pos: Variant = entry.get("pos", null)
	var rot: Variant = entry.get("rot", null)
	if not (pos is Vector3) or not (rot is Vector3):
		return {}
	if not (pos as Vector3).is_finite() or not (rot as Vector3).is_finite():
		return {}
	if absf((pos as Vector3).x) > ARENA_LIMIT or absf((pos as Vector3).z) > ARENA_LIMIT \
			or (pos as Vector3).y < -10.0 or (pos as Vector3).y > 100.0:
		return {}
	var spec: Variant = entry.get("spec", null)
	if not (spec is Dictionary):
		return {}
	var clean_spec := sanitize_spec(spec, preset_id, pos)
	if clean_spec.is_empty():
		return {}
	return {
		"instance_id": iid,
		"preset_id": preset_id,
		"owner": owner,
		"pos": pos,
		"rot": rot,
		"spec": clean_spec,
	}


## Wire form of a local entry (strips the live node). The spec is
## deep-copied so a signal/RPC consumer can never mutate the registry's
## copy by aliasing.
static func wire_entry(entry: Dictionary) -> Dictionary:
	var w := entry.duplicate()
	w.erase("node")
	if w.has("spec") and w["spec"] is Dictionary:
		w["spec"] = (w["spec"] as Dictionary).duplicate(true)
	return w


# --- registry queries ----------------------------------------------------------

func get_wire_entries() -> Array:
	var out: Array = []
	for iid in _entries.keys():
		out.append(wire_entry(_entries[iid]))
	return out


func entry_count() -> int:
	return _entries.size()


func get_entry(instance_id: int) -> Dictionary:
	if _entries.has(instance_id):
		return _entries[instance_id]
	return {}


func clear() -> void:
	# Registry only — never frees nodes (the scene / match teardown owns
	# the world). A fresh match gets fresh host-assigned ids.
	_entries.clear()
	_provisional.clear()
	_next_id = 1


# --- host-authoritative entry points -------------------------------------------
# Called by NetManager (which enforces host-only for the host_* methods
# on the RPC path). host_place spawns the host's own copy when node is
# null (client-placed builds the host has never seen); with a node it
# adopts the existing node.

func host_place(spec: Dictionary, owner: int, pos: Vector3, rot: Vector3,
		node: Node = null) -> Dictionary:
	if not _forge_allowed():
		return {}  # MP worker: Forge building is TD-only, incl. remote specs.
	var preset_id := preset_id_for_spec(spec)
	if preset_id.is_empty():
		return {}
	if not pos.is_finite() or not rot.is_finite():
		return {}
	if _entries.size() >= MAX_ENTRIES:
		return {}
	if node != null and is_instance_valid(node) and node.has_meta("forge_instance_id"):
		var existing := int(node.get_meta("forge_instance_id"))
		if _entries.has(existing):
			return wire_entry(_entries[existing])
	pos = Vector3(clampf(pos.x, -ARENA_LIMIT, ARENA_LIMIT),
		clampf(pos.y, -10.0, 100.0), clampf(pos.z, -ARENA_LIMIT, ARENA_LIMIT))
	var clean_spec := sanitize_spec(spec, preset_id, pos)
	if clean_spec.is_empty():
		return {}
	var iid := _next_id
	_next_id += 1
	var entry := {
		"instance_id": iid, "preset_id": preset_id, "owner": owner,
		"pos": pos, "rot": rot, "spec": clean_spec, "node": node,
	}
	if node == null:
		var spawned := _spawn_entry(entry)
		if spawned == null:
			return {}
		entry["node"] = spawned
	else:
		_tag_node(node, entry)
	_entries[iid] = entry
	structure_placed.emit(wire_entry(entry))
	return wire_entry(entry)


func host_remove(instance_id: int, free_node: bool = true) -> bool:
	if not _entries.has(instance_id):
		return false  # idempotent: already gone is not an error
	var entry: Dictionary = _entries[instance_id]
	_entries.erase(instance_id)
	var node: Variant = entry.get("node", null)
	if free_node and is_instance_valid(node) and node is Node:
		(node as Node).queue_free()
	structure_removed.emit(instance_id)
	return true


func host_update(instance_id: int, pos: Vector3, rot: Vector3) -> Dictionary:
	if not _entries.has(instance_id):
		return {}
	if not pos.is_finite() or not rot.is_finite():
		return {}
	var entry: Dictionary = _entries[instance_id]
	entry["pos"] = pos
	entry["rot"] = rot
	var node: Variant = entry.get("node", null)
	if is_instance_valid(node) and node is Node3D:
		(node as Node3D).global_position = pos
		(node as Node3D).rotation = rot
	structure_updated.emit(wire_entry(entry))
	return wire_entry(entry)


# --- apply (all peers, incl. host echo) ----------------------------------------

## Apply a host broadcast. Dedupes (same id -> existing node), adopts a
## matching provisional node (client's own just-placed build), else spawns.
## Returns the live node or null when ignored / spawn failed.
func apply_place(raw_entry: Dictionary) -> Node:
	if not _forge_allowed():
		return null  # MP worker: refuse remote specs in a no-Forge match.
	var entry := sanitize_entry(raw_entry)
	if entry.is_empty():
		return null
	var iid := int(entry["instance_id"])
	if iid <= 0:
		return null  # broadcasts always carry a host-assigned id
	if _entries.has(iid):
		var existing: Dictionary = _entries[iid]
		var enode: Variant = existing.get("node", null)
		if is_instance_valid(enode) and enode is Node:
			return enode
		# Entry exists but its node is gone (local fracture awaiting the
		# host's verdict): respawn from the host's authoritative entry.
		var respawned := _spawn_entry(entry)
		if respawned == null:
			return null
		existing["node"] = respawned
		existing["pos"] = entry["pos"]
		existing["rot"] = entry["rot"]
		return respawned
	# Adopt a matching provisional node (same owner + preset + pose).
	for i in range(_provisional.size() - 1, -1, -1):
		var prov: Dictionary = _provisional[i]
		var pentry: Dictionary = prov["entry"]
		var pnode: Variant = prov["node"]
		if not is_instance_valid(pnode) or not (pnode is Node):
			_provisional.remove_at(i)
			continue
		if int(pentry.get("owner", -1)) == int(entry["owner"]) \
				and str(pentry.get("preset_id", "")) == str(entry["preset_id"]) \
				and (pentry.get("pos", Vector3.INF) as Vector3).distance_to(entry["pos"]) <= PROVISIONAL_POS_EPSILON \
				and (pentry.get("rot", Vector3.INF) as Vector3).distance_to(entry["rot"]) <= PROVISIONAL_ROT_EPSILON:
			_provisional.remove_at(i)
			_tag_node(pnode, entry)
			entry["node"] = pnode
			_entries[iid] = entry
			structure_placed.emit(wire_entry(entry))
			return pnode
	var spawned := _spawn_entry(entry)
	if spawned == null:
		return null
	entry["node"] = spawned
	_entries[iid] = entry
	structure_placed.emit(wire_entry(entry))
	return spawned


func apply_remove(instance_id: int) -> bool:
	if not _entries.has(instance_id):
		return false  # idempotent
	var entry: Dictionary = _entries[instance_id]
	_entries.erase(instance_id)
	var node: Variant = entry.get("node", null)
	if is_instance_valid(node) and node is Node:
		(node as Node).queue_free()
	structure_removed.emit(instance_id)
	return true


func apply_update(raw_entry: Dictionary) -> bool:
	var entry := sanitize_entry(raw_entry)
	if entry.is_empty():
		return false
	var iid := int(entry["instance_id"])
	if not _entries.has(iid):
		return false
	var local: Dictionary = _entries[iid]
	local["pos"] = entry["pos"]
	local["rot"] = entry["rot"]
	var node: Variant = local.get("node", null)
	if is_instance_valid(node) and node is Node3D:
		(node as Node3D).global_position = entry["pos"]
		(node as Node3D).rotation = entry["rot"]
	structure_updated.emit(wire_entry(local))
	return true


## Full host snapshot (late join / resync): apply every entry, then remove
## registered entries the host no longer lists. Returns placed count.
func apply_snapshot(raw_entries: Array) -> int:
	var placed := 0
	var seen: Dictionary = {}
	for raw in raw_entries:
		if not (raw is Dictionary):
			continue
		var e := sanitize_entry(raw)
		if e.is_empty():
			continue
		seen[int(e["instance_id"])] = true
		if apply_place(e) != null:
			placed += 1
	var stale: Array = []
	for iid in _entries.keys():
		if not seen.has(iid):
			stale.append(iid)
	for iid in stale:
		apply_remove(int(iid))
	return placed


# --- local placement hook (ForgeManager -> NetManager -> here) ------------------

## A build just landed on THIS peer (ForgeManager hook, or polling).
## Host: register + return the wire entry for broadcast. Client: store a
## provisional entry, tag the node pending, return an instance_id-0 entry
## for the host request. Returns {} when not placeable / offline.
func notify_local_placed(node: Node, spec: Dictionary) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {}
	if not _resolve_online():
		return {}
	if node.has_meta("forge_instance_id"):
		var existing := int(node.get_meta("forge_instance_id"))
		if _entries.has(existing):
			return wire_entry(_entries[existing])
	if node.has_meta("forge_pending"):
		return {}  # already awaiting the host's ack — never double-send
	if not (node is Node3D):
		return {}
	var preset_id := preset_id_for_spec(spec)
	if preset_id.is_empty():
		return {}
	var pos := (node as Node3D).global_position
	var rot := (node as Node3D).rotation
	if _resolve_host():
		return host_place(spec, _resolve_local_id(), pos, rot, node)
	var clean_spec := sanitize_spec(spec, preset_id, pos)
	if clean_spec.is_empty():
		return {}
	var entry := {
		"instance_id": 0, "preset_id": preset_id,
		"owner": _resolve_local_id(), "pos": pos, "rot": rot,
		"spec": clean_spec,
	}
	node.set_meta("forge_pending", true)
	node.set_meta("forge_preset_id", preset_id)
	node.set_meta("forge_spec", clean_spec)
	_provisional.append({"entry": entry, "node": node})
	return wire_entry(entry)


# --- spawning --------------------------------------------------------------------

func _tag_node(node: Node, entry: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	node.set_meta("forge_instance_id", int(entry["instance_id"]))
	node.set_meta("forge_preset_id", str(entry["preset_id"]))
	node.set_meta("forge_spec", (entry["spec"] as Dictionary).duplicate(true))
	if node.has_meta("forge_pending"):
		node.remove_meta("forge_pending")


## Spawn the node for an entry (spawn_handler override first, else the
## real ForgeBuilder path). Tags metas. Returns null on failure.
func _spawn_entry(entry: Dictionary) -> Node:
	var node: Node = null
	if spawn_handler.is_valid():
		var res: Variant = spawn_handler.call(entry)
		if res is Node:
			node = res
	else:
		node = _default_spawn(entry)
	if node == null or not is_instance_valid(node):
		return null
	_tag_node(node, entry)
	return node


## Real spawn: ForgeBuilder.build() with an explicit position, then force
## the authoritative transform (the builder orients structures toward
## the LOCAL player; peers must match the placer's orientation, not
## their own). No budget is charged — this bypasses ForgeManager.
func _default_spawn(entry: Dictionary) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	if _builder_script == null:
		_builder_script = load("res://scripts/forge/forge_builder.gd") as GDScript
		if _builder_script == null:
			return null
	var spec: Dictionary = (entry["spec"] as Dictionary).duplicate(true)
	var params: Dictionary = spec.get("params", {})
	params["position"] = [
		float((entry["pos"] as Vector3).x),
		float((entry["pos"] as Vector3).y),
		float((entry["pos"] as Vector3).z),
	]
	spec["params"] = params
	var root_node: Node = tree.current_scene
	if root_node == null:
		root_node = tree.root
	var player: Node = null
	var players := tree.get_nodes_in_group("player")
	if not players.is_empty():
		player = players[0]
	# Dot-syntax static access (same pattern as tools/verify_v05_b2_*).
	var msg: String = _builder_script.build(spec, {"player": player, "root": root_node})
	if msg.begins_with("FORGE_FAIL: "):
		return null
	var node: Variant = _builder_script.last_built_node
	if not is_instance_valid(node) or not (node is Node):
		return null
	if node is Node3D:
		(node as Node3D).global_position = entry["pos"]
		(node as Node3D).rotation = entry["rot"]
	return node


# --- polling fallback ------------------------------------------------------------
# Catches builds that bypassed the ForgeManager hook (direct
# ForgeBuilder.build calls), host-side destruction (queue_free'd nodes:
# cover fracture, undo, turret TTL), and host-side transform drift
# (Worker B move/rotate on the host). Clients never emit remove/update
# from polling — the host is the authority on those.

func _process(delta: float) -> void:
	if not _resolve_online():
		return
	_poll_t += delta
	if _poll_t < POLL_INTERVAL:
		return
	_poll_t = 0.0
	poll_now()


func poll_now() -> void:
	if not _resolve_online():
		return
	var tree := get_tree()
	if tree == null:
		return
	# Provisional cleanup: node freed before the host acked -> drop it.
	for i in range(_provisional.size() - 1, -1, -1):
		var prov: Dictionary = _provisional[i]
		var pnode: Variant = prov["node"]
		if not is_instance_valid(pnode) or not (pnode is Node):
			_provisional.remove_at(i)
	# Registered nodes: host-side destruction / transform drift.
	for iid in _entries.keys():
		var entry: Dictionary = _entries[iid]
		var node: Variant = entry.get("node", null)
		if not is_instance_valid(node) or not (node is Node):
			if _resolve_host():
				# Host copy gone (fracture / undo / TTL): broadcast removal.
				var rid := int(iid)
				host_remove(rid, false)
				local_remove_detected.emit(rid)
			continue
		if _resolve_host() and node is Node3D:
			var n3d := node as Node3D
			if n3d.global_position.distance_to(entry["pos"]) > POS_EPSILON \
					or n3d.rotation.distance_to(entry["rot"]) > ROT_EPSILON:
				var updated := host_update(int(iid), n3d.global_position, n3d.rotation)
				if not updated.is_empty():
					local_update_detected.emit(updated)
	# Untagged new builds in group "forge_structure".
	for n in tree.get_nodes_in_group("forge_structure"):
		if n == null or not is_instance_valid(n):
			continue
		if n.has_meta("forge_instance_id") or n.has_meta("forge_pending"):
			continue
		var spec := _infer_spec(n)
		if spec.is_empty():
			continue
		var placed := notify_local_placed(n, spec)
		if not placed.is_empty():
			local_place_detected.emit(placed, n)


## Best-effort spec inference for untagged nodes (direct ForgeBuilder
## builds that bypassed the hook). The hook path is exact; this is the
## fallback so those builds still sync instead of vanishing on peers.
## Returns {} when the node cannot be identified (ignored, never crash).
func _infer_spec(node: Node) -> Dictionary:
	if node.has_meta("forge_spec"):
		var ms: Variant = node.get_meta("forge_spec")
		if ms is Dictionary:
			return (ms as Dictionary).duplicate(true)
	# ForgeStructure (Worker B): structure_shape property + meta "shape"
	# + meta forge_kind="structure". Property/meta first — they survive
	# Godot's duplicate-name auto-rename (@Node3D@N), the node NAME does
	# not (a second "ForgeStructure_bunker" sibling gets renamed).
	var kind := str(node.get_meta("forge_kind")) if node.has_meta("forge_kind") else ""
	if kind == "structure":
		var shape := ""
		if node.get("structure_shape") != null:
			shape = str(node.get("structure_shape"))
		if shape.is_empty() and node.has_meta("shape"):
			shape = str(node.get_meta("shape"))
		if shape in STRUCTURE_SHAPES:
			return {"spec_version": 1, "action": "spawn", "target": "structure",
				"params": {"shape": shape, "property": "standard"},
				"cost": 0, "ttl": 0}
	# Cover: DestructibleCover shape (vox_size / hp / palette).
	if kind == "cover" or (node.get("vox_size") != null and node.get("hp") != null):
		var shape := "wall"
		if node.has_meta("forge_shape"):
			shape = str(node.get_meta("forge_shape"))
		var sv: Variant = node.get("vox_size")
		var size: Array = [4, 3, 1]
		if sv is Vector3i:
			size = [int((sv as Vector3i).x), int((sv as Vector3i).y), int((sv as Vector3i).z)]
		return {"spec_version": 1, "action": "spawn", "target": "cover",
			"params": {"shape": shape, "size_voxels": size,
				"hp": float(node.get("hp")), "property": "standard"},
			"cost": 0, "ttl": 0}
	# Fallback: structure_shape property without the forge_kind meta.
	if node.get("structure_shape") != null:
		var pshape := str(node.get("structure_shape"))
		if pshape in STRUCTURE_SHAPES:
			return {"spec_version": 1, "action": "spawn", "target": "structure",
				"params": {"shape": pshape, "property": "standard"},
				"cost": 0, "ttl": 0}
	# Structure: ForgeStructure_<shape> naming from ForgeBuilder.
	# Godot auto-renames duplicate sibling names ("ForgeStructure_bunker"
	# -> "ForgeStructure_bunker2"), so trailing digits are stripped
	# before the shape lookup (no known shape ends in a digit).
	var nm := str(node.name)
	if nm.begins_with("ForgeStructure_"):
		var shape := nm.substr("ForgeStructure_".length())
		while not shape.is_empty() and shape[-1] >= "0" and shape[-1] <= "9":
			shape = shape.substr(0, shape.length() - 1)
		if shape in STRUCTURE_SHAPES:
			return {"spec_version": 1, "action": "spawn", "target": "structure",
				"params": {"shape": shape, "property": "standard"},
				"cost": 0, "ttl": 0}
	# Turret: group "turret" + ttl_seconds.
	if node.is_in_group("turret"):
		var ttl := 45.0
		if node.get("ttl_seconds") != null:
			ttl = float(node.get("ttl_seconds"))
		var at := "standard"
		if node.has_meta("ammo_type"):
			at = str(node.get_meta("ammo_type"))
		return {"spec_version": 1, "action": "spawn", "target": "turret",
			"params": {"duration_sec": ttl, "ammo_type": at},
			"cost": 0, "ttl": 0}
	return {}
