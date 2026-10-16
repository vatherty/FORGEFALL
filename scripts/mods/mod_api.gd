# FORGEFALL — ModAPI (v0.7 chunk 1: user mods, Worker A)
# The ONLY surface a user script mod may touch. Mod scripts talk to the
# game exclusively through this object (passed to ModBlock.apply()).
# Deliberately small: spawn things, tune stats, fire effects, announce.
# NO filesystem / network / OS / eval / arbitrary resource loading — those
# are rejected by ModLoader's forbidden-API text scan before the script
# ever loads. Every spawn is tracked (last_spawned) so ForgeBuilder can
# register the node for undo / the structure cap.
extends RefCounted
class_name ModAPI

const TURRET_SCRIPT := preload("res://scripts/forge/forge_turret.gd")

## Last node a spawn_* call produced (null when nothing spawned).
var last_spawned: Node = null
## World position of last_spawned.
var last_spawned_position := Vector3.ZERO

var _player: Node3D
var _root: Node


func _init(player: Node3D, root: Node) -> void:
	_player = player
	_root = root


## The player node (may be null in headless tests). Prefer the helpers
## below over reaching into the player yourself.
func get_player() -> Node3D:
	return _player


## The scene root builds attach to.
func get_root() -> Node:
	return _root


## Player position, or Vector3.ZERO when there is no player.
func get_player_position() -> Vector3:
	if _player != null:
		return _player.global_position
	return Vector3.ZERO


## Crosshair raycast point (the "marked" position).
func get_aim_point() -> Vector3:
	return ForgeBuilder.crosshair_point(_player)


## One voxel block: visible cube + optional solid collider, at `position`.
## Returns the Node3D (already added to the root), or null without a root.
func spawn_voxel_box(size: Vector3, color: Color, position: Vector3, solid: bool) -> Node3D:
	if _root == null:
		return null
	var node := Node3D.new()
	node.name = "ModVoxel"
	node.position = position
	_root.add_child(node)
	node.add_child(VoxelBuilder.cube(size, color, Vector3.ZERO))
	if solid:
		var body := StaticBody3D.new()
		body.add_child(VoxelBuilder.collision_box(size))
		node.add_child(body)
	_track(node, position)
	return node


## A destructible voxel cover slab. shape: wall|tower|barricade.
## size_voxels in voxels (each 1-12), hp 50-500. Null when unavailable.
func spawn_cover(shape: String, size_voxels: Vector3i, hp: float, position: Vector3) -> Node:
	if _root == null or not _has_script_class("DestructibleCover"):
		return null
	if not (shape in ["wall", "tower", "barricade"]):
		return null
	var cover := DestructibleCover.new()
	cover.vox_size = Vector3i(clampi(size_voxels.x, 1, 12), clampi(size_voxels.y, 1, 12), clampi(size_voxels.z, 1, 12))
	cover.pitch = ForgeBuilder.COVER_PITCH_M
	var pal: Array[Color] = [VoxelBuilder.PALETTE["concrete"], Color("847f76")]
	cover.palette.assign(pal)
	cover.hp = clampf(hp, 50.0, 500.0)
	cover.position = position
	_root.add_child(cover)
	_track(cover, position)
	return cover


## An ammo/health pickup at `position`. kind: ammo|health.
func spawn_pickup(kind: String, position: Vector3) -> Node:
	if _root == null:
		return null
	var node := ForgeBuilder.spawn_pickup(_root, position, kind)
	_track(node, position)
	return node


## A sentry turret. damage_mult / range_mult are recorded as metadata on
## the turret (same precedent as the Forge's own turret composition —
## forge_turret.gd reads them and applies them to damage/range).
func spawn_turret(position: Vector3, duration_sec: float, damage_mult: float, range_mult: float) -> Node:
	if _root == null:
		return null
	var t = TURRET_SCRIPT.new()
	t.set_meta("ammo_type", "standard")
	t.set_meta("damage_mult", damage_mult)
	t.set_meta("range_mult", range_mult)
	t.ttl_seconds = clampf(duration_sec, 5.0, 120.0)
	t.position = position
	if _player != null:
		var away: Vector3 = position - _player.global_position
		away.y = 0.0
		if away.length() > 0.5:
			var tr: Vector3 = t.rotation
			tr.y = atan2(-away.x, -away.z)
			t.rotation = tr
	_root.add_child(t)
	_track(t, position)
	return t


## Give the player a base weapon, tuned by the multipliers (1.0 = stock).
## weapon_id is a Forge id (manticore/longeye/breacher/hornet/p9/raptor/lmg).
## False when there is no player / WeaponManager / unknown weapon.
func give_weapon(weapon_id: String, damage_mult: float, range_mult: float, mag_mult: float) -> bool:
	if _player == null:
		return false
	var wm = _player.get_node_or_null("WeaponManager")
	if wm == null:
		wm = _player.find_child("WeaponManager", true, false)
	if wm == null or not wm.has_method("give_weapon"):
		return false
	var arsenal_id := str(ForgeBuilder.FORGE_WEAPON_IDS.get(weapon_id, weapon_id))
	if not Arsenal.has_weapon(arsenal_id):
		return false
	wm.give_weapon(arsenal_id)
	var kids := wm.get_children()
	for i in range(kids.size() - 1, -1, -1):
		var kid := kids[i] as Node
		if kid == null or kid.is_queued_for_deletion():
			continue
		if str(kid.get("weapon_id")) == arsenal_id:
			if damage_mult != 1.0:
				kid.set("damage", float(kid.get("damage")) * damage_mult)
			if range_mult != 1.0:
				kid.set("near_range", float(kid.get("near_range")) * range_mult)
				kid.set("far_range", float(kid.get("far_range")) * range_mult)
			if mag_mult != 1.0:
				var mag_size := maxi(1, int(round(float(kid.get("mag_size")) * mag_mult)))
				kid.set("mag_size", mag_size)
				kid.set("mag", mag_size)
			break
	return true


## A one-shot effect. kind: "explosion" (uses radius + damage) or "smoke"
## (uses duration_sec). Unknown kinds are ignored.
func fire_effect(kind: String, position: Vector3, radius: float, damage: float, duration_sec: float = 20.0) -> void:
	match kind:
		"explosion":
			ForgeBuilder.fx_detonate(position, radius, damage)
		"smoke":
			if _root != null:
				ForgeBuilder.fx_smoke(_root, position, clampf(duration_sec, 5.0, 120.0))


## HUD banner. Silent no-op when no HUD is listening.
func announce(title: String, subtitle: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var hud = tree.get_first_node_in_group("hud")
	if hud != null and hud.has_method("announce"):
		hud.announce(title, subtitle)


# --- Hook support (v0.5.3: invented hooks) ---------------------------------
# The surface ModHook code + the hook registry may use. Same deal as the
# rest of ModAPI: these are the ONLY game operations a hook gets.

## Current player HP, or -1 when there is no player / no HP to read.
func get_player_health() -> float:
	if _player == null or not is_instance_valid(_player):
		return -1.0
	var v: Variant = _player.get("_hp")
	if v is int or v is float:
		return float(v)
	return -1.0


## Heals the player (clamped by the player's own heal()). Returns the
## player's HP afterwards, or -1 when there is no player / heal().
func heal_player(amount: float) -> float:
	if _player == null or not is_instance_valid(_player):
		return -1.0
	if not _player.has_method("heal"):
		return -1.0
	_player.heal(amount)
	return get_player_health()


## Applies a status effect (slow / freeze / burn / knockback) to a
## target node — see ModStatusEffects. `origin` is the hit point
## (knockback direction is away from it). No-op (false) for a null /
## freed / out-of-tree target or an unknown kind.
func apply_status_effect(target: Node, kind: String, params: Dictionary, origin: Vector3) -> bool:
	return ModStatusEffects.apply_status(target, kind, params, origin)


## Spawns a flying mod projectile (see ModProjectile) at `origin`,
## travelling along `direction`. `spec` is a ModHook projectile dict
## (visual / speed / damage / explodes_on_impact / ...); `hooks` are
## the firing weapon's attached hooks (on_hit / on_kill run on impact).
## Returns the ModProjectile node, or null without a root.
func spawn_projectile(spec: Dictionary, origin: Vector3, direction: Vector3, hooks: Array = []) -> Node:
	if _root == null:
		return null
	var p := ModProjectile.new()
	p.setup(spec, hooks, _player)
	_root.add_child(p)
	p.launch(origin, direction)
	return p


func _track(node: Node, pos: Vector3) -> void:
	last_spawned = node
	last_spawned_position = pos


## ClassDB only knows native classes; script global classes (class_name)
## are checked against the project's global class list instead.
static func _has_script_class(cls_name: String) -> bool:
	for e in ProjectSettings.get_global_class_list():
		if (e as Dictionary).get("class") == cls_name:
			return true
	return false
