# FORGEFALL — ForgeStructure (Forge batch, Worker B: items 2/3/6)
# A Forge-built structure (bridge / bunker / watchtower / ammo depot /
# stairs / ramp / wall / jump pad / cover piece / sniper nest) that is
# DESTRUCTIBLE: it carries HP, takes damage through the standard
# take_damage(amount, hit_position, is_headshot) interface, shows damage
# feedback, and is removed at 0 HP.
#
# Damage sources (no enemy-code edits — the damage path lives here):
# - Player weapons / explosions hit the structure's collision body, a
#   StructureBody that forwards take_damage() to this node. Without the
#   forwarder the raycast collider would be a plain StaticBody3D with no
#   damage method and bullets would never hurt structures.
# - Enemies: ForgeEnemyPressure ticks this node (see
#   forge_enemy_pressure.gd): a nearby engaged enemy with line of sight
#   to the structure lands periodic hits for its own damage value.
# - Covers (DestructibleCover) and turrets already had take_damage;
#   ForgeBuilder attaches a ForgeEnemyPressure child to them so the same
#   enemy-pressure path reaches them too.
#
# Repair: repair(amount) / repair_full(), plus the interact key (F / Y)
# while standing within REPAIR_RANGE of a damaged structure. The
# ForgePlacement edit API (forge_placement.gd) exposes the same repair
# for covers/turrets via repair_target(), which duck-types the HP fields.
#
# Damage feedback (cheap, voxel-consistent — no shared-material mutation,
# because VoxelBuilder materials are cached per color and tinting one
# would tint every voxel in the game that color):
# - Hit flash: a translucent red overlay box, ~0.09 s per hit.
# - Cracks: small dark voxel cubes on the surface, count scales with
#   damage fraction (0..8).
# - Low HP (<35%): a small dark smoke emitter turns on; repair turns it
#   off again.
# - Destroyed: DebrisPool burst in the structure's palette + "cover_break"
#   sting, leaves group "forge_structure", queue_free.
#
# Edit API (used by ForgePlacement): move_to(pos), rotate_by(degrees),
# delete_structure() (no refund — budget is off for edits).
extends Node3D
class_name ForgeStructure

#region TUNABLES
const REPAIR_RANGE := 3.2
const FLASH_TIME := 0.09
const LOW_HP_FRAC := 0.35
const MAX_CRACKS := 8
const TURRET_MAX_HP := 150.0
#endregion

var structure_shape := ""
var hp := 300.0
var max_hp := 300.0
var bounds_size := Vector3(2.0, 2.0, 2.0)
var debris_colors: Array[Color] = [Color("9a958c"), Color("7a5c38"), Color("5a6b3c")]

var _destroyed := false
var _flash_overlay: MeshInstance3D = null
var _flash_t := 0.0
var _crack_root: Node3D = null
var _smoke: GPUParticles3D = null
var _player: Node3D = null


## Collision body for a ForgeStructure. Plain StaticBody3D children have
## no take_damage(), so weapon raycasts / explosion shape queries that
## strike the body would silently do nothing. This subclass forwards to
## the parent ForgeStructure, which owns the HP.
class StructureBody extends StaticBody3D:
	func take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void:
		var p := get_parent()
		if p != null and p != self and p.has_method("take_damage"):
			p.call("take_damage", amount, hit_position, is_headshot)


## Called by ForgeBuilder BEFORE add_child(). Keeps the legacy metadata
## readers (hp / max_hp) in sync with the live vars.
func setup(shape: String, hp_value: float, bounds: Vector3, colors: Array[Color] = []) -> void:
	structure_shape = shape
	hp = hp_value
	max_hp = hp_value
	bounds_size = bounds
	if not colors.is_empty():
		debris_colors = colors.duplicate()
	name = "ForgeStructure_" + shape
	set_meta("hp", hp)
	set_meta("max_hp", max_hp)
	set_meta("forge_kind", "structure")
	set_meta("shape", shape)


func _ready() -> void:
	add_to_group("forge_structure")
	_build_feedback_nodes()


func _process(delta: float) -> void:
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0 and is_instance_valid(_flash_overlay):
			_flash_overlay.visible = false
	# Interact-key repair: standing next to a damaged structure and
	# pressing interact (F / Y) restores it fully. Each structure checks
	# itself, so one press repairs every damaged structure in range —
	# generous, simple, and robust (no selection UI required).
	if not _destroyed and hp < max_hp:
		if Input.is_action_just_pressed("interact") and _player_in_repair_range():
			repair_full()
			_play("forge_success")


func _physics_process(delta: float) -> void:
	if _destroyed:
		return
	ForgeEnemyPressure.apply_pressure(self, delta)


## Standard damageable interface. is_headshot is accepted for interface
## compatibility and ignored — structures have no head.
func take_damage(amount: float, hit_position: Vector3, _is_headshot: bool) -> void:
	if _destroyed:
		return
	hp -= amount
	set_meta("hp", hp)
	_show_flash()
	_refresh_damage_visuals()
	if hp <= 0.0:
		_destroy()


## Restores up to `amount` HP (amount < 0 = full repair). Returns the HP
## actually restored (0 when destroyed or already full).
func repair(amount: float = -1.0) -> float:
	if _destroyed:
		return 0.0
	var want := (max_hp - hp) if amount < 0.0 else amount
	var restored := clampf(want, 0.0, max_hp - hp)
	if restored <= 0.0:
		return 0.0
	hp += restored
	set_meta("hp", hp)
	_refresh_damage_visuals()
	return restored


func repair_full() -> float:
	return repair(-1.0)


func get_hp() -> float:
	return hp


func get_max_hp() -> float:
	return max_hp


func get_hp_frac() -> float:
	if max_hp <= 0.0:
		return 0.0
	return clampf(hp / max_hp, 0.0, 1.0)


func is_destroyed() -> bool:
	return _destroyed


## Edit API: relocate the structure (caller snaps to ground first).
func move_to(pos: Vector3) -> void:
	global_position = pos


## Edit API: yaw the structure by `degrees` (positive = counter-clockwise).
func rotate_by(degrees: float) -> void:
	rotation.y += deg_to_rad(degrees)


## Edit API: remove the structure. No refund — budget is off for edits.
func delete_structure() -> void:
	remove_from_group("forge_structure")
	queue_free()


# --- Damage feedback ---------------------------------------------------------

func _build_feedback_nodes() -> void:
	# Hit-flash overlay: a slightly oversized translucent red box.
	_flash_overlay = MeshInstance3D.new()
	_flash_overlay.name = "HitFlash"
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	_flash_overlay.mesh = box
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.albedo_color = Color(1.0, 0.15, 0.1, 0.45)
	_flash_overlay.material_override = fmat
	_flash_overlay.scale = bounds_size * 1.04 + Vector3(0.05, 0.05, 0.05)
	_flash_overlay.position = Vector3(0, bounds_size.y * 0.5, 0)
	_flash_overlay.visible = false
	_flash_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_flash_overlay)
	# Crack decals live under this root so they can be rebuilt by count.
	_crack_root = Node3D.new()
	_crack_root.name = "Cracks"
	add_child(_crack_root)
	# Low-HP smoke: small dark emitter, off until HP drops below 35%.
	_smoke = GPUParticles3D.new()
	_smoke.name = "DamageSmoke"
	_smoke.amount = 10
	_smoke.lifetime = 1.6
	_smoke.preprocess = 0.5
	_smoke.explosiveness = 0.2
	_smoke.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 8, 8))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 30.0
	pm.initial_velocity_min = 0.4
	pm.initial_velocity_max = 1.0
	pm.gravity = Vector3(0, 0.4, 0)
	pm.damping_min = 0.3
	pm.damping_max = 0.6
	pm.scale_min = 0.5
	pm.scale_max = 1.1
	pm.color = Color(0.15, 0.14, 0.14, 0.55)
	_smoke.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var qmat := StandardMaterial3D.new()
	qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qmat.albedo_color = Color(0.2, 0.2, 0.2, 0.4)
	quad.material = qmat
	_smoke.draw_pass_1 = quad
	_smoke.position = Vector3(0, bounds_size.y * 0.8, 0)
	_smoke.emitting = false
	add_child(_smoke)


func _show_flash() -> void:
	if is_instance_valid(_flash_overlay):
		_flash_overlay.visible = true
		_flash_t = FLASH_TIME


func _refresh_damage_visuals() -> void:
	var frac := get_hp_frac()
	# Cracks: 0 at full HP, up to MAX_CRACKS near destruction.
	var want := 0
	if not _destroyed and hp < max_hp:
		want = int((1.0 - frac) * float(MAX_CRACKS))
	if is_instance_valid(_crack_root):
		while _crack_root.get_child_count() < want:
			var idx := _crack_root.get_child_count()
			var crack := VoxelBuilder.cube(Vector3(0.16, 0.16, 0.05), Color(0.08, 0.07, 0.07))
			# Deterministic scatter over the front face + top edge.
			var fx := sin(float(idx) * 2.7) * bounds_size.x * 0.38
			var fy := bounds_size.y * (0.25 + 0.12 * float(idx % 4))
			var fz := bounds_size.z * 0.5 + 0.03
			crack.position = Vector3(fx, fy, fz)
			_crack_root.add_child(crack)
		while _crack_root.get_child_count() > want:
			var extra := _crack_root.get_child(_crack_root.get_child_count() - 1)
			_crack_root.remove_child(extra)
			extra.queue_free()
	if is_instance_valid(_smoke):
		_smoke.emitting = (not _destroyed) and frac < LOW_HP_FRAC


func _destroy() -> void:
	if _destroyed:
		return
	_destroyed = true
	remove_from_group("forge_structure")
	if is_instance_valid(_smoke):
		_smoke.emitting = false
	var center := global_position + Vector3(0, bounds_size.y * 0.5, 0)
	if ClassDB.class_exists("DebrisPool"):
		DebrisPool.burst(center, debris_colors, 16, 5.0)
	_play_3d("cover_break", center)
	queue_free()


func _player_in_repair_range() -> bool:
	var p := _player_node()
	if p == null:
		return false
	return global_position.distance_to(p.global_position) <= REPAIR_RANGE


func _player_node() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	var tree := get_tree()
	if tree == null:
		return null
	var nodes := tree.get_nodes_in_group("player")
	if nodes.is_empty():
		return null
	_player = nodes[0] as Node3D
	return _player


func _play(id: String) -> void:
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_2d"):
		sfx.play_2d(id)


func _play_3d(id: String, pos: Vector3) -> void:
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_3d"):
		sfx.play_3d(id, pos)


# --- Cross-type static helpers ------------------------------------------------
# The ForgePlacement edit API repairs / deletes / reads HP on ANY Forge
# build (ForgeStructure, DestructibleCover, turret) through these
# duck-typed helpers, so the caller never needs the concrete type.
# - ForgeStructure: has repair().
# - DestructibleCover: has an `hp` var + a `max_hp` meta set by
#   ForgeBuilder at build time.
# - Turret: has a `_hp` script var, max TURRET_MAX_HP, `_dead` flag.

## Repairs `node` (amount < 0 = full). Returns HP actually restored.
static func repair_target(node: Node, amount: float = -1.0) -> float:
	if node == null or not is_instance_valid(node):
		return 0.0
	if node.has_method("repair"):
		return float(node.call("repair", amount))
	if node.has_method("is_broken") and bool(node.call("is_broken")):
		return 0.0
	if node.get("_dead") == true:
		return 0.0
	if node.get("hp") != null and node.has_meta("max_hp"):
		var cur := float(node.get("hp"))
		var mx := float(node.get_meta("max_hp"))
		var want := (mx - cur) if amount < 0.0 else amount
		var restored := clampf(want, 0.0, mx - cur)
		if restored > 0.0:
			node.set("hp", cur + restored)
		return restored
	if node.get("_hp") != null:
		var cur_t := float(node.get("_hp"))
		var want_t := (TURRET_MAX_HP - cur_t) if amount < 0.0 else amount
		var restored_t := clampf(want_t, 0.0, TURRET_MAX_HP - cur_t)
		if restored_t > 0.0:
			node.set("_hp", cur_t + restored_t)
		return restored_t
	return 0.0


## Removes `node` from the structure cap group and frees it. No refund.
static func delete_target(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	node.remove_from_group("forge_structure")
	node.queue_free()
	return true


## Current HP, or -1 when the node carries no readable HP.
static func hp_of(node: Node) -> float:
	if node == null or not is_instance_valid(node):
		return -1.0
	if node.has_method("get_hp"):
		return float(node.call("get_hp"))
	if node.get("hp") != null:
		return float(node.get("hp"))
	if node.get("_hp") != null:
		return float(node.get("_hp"))
	return -1.0


## Max HP, or -1 when the node carries no readable max HP.
static func max_hp_of(node: Node) -> float:
	if node == null or not is_instance_valid(node):
		return -1.0
	if node.has_method("get_max_hp"):
		return float(node.call("get_max_hp"))
	if node.has_meta("max_hp"):
		return float(node.get_meta("max_hp"))
	if node.get("_hp") != null:
		return TURRET_MAX_HP
	return -1.0
