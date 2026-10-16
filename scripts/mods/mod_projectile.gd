# FORGEFALL — ModProjectile (v0.5.3: invented hooks, Worker A)
# A flying mod projectile: the thing a mod weapon actually shoots when
# its mod defines a projectile hook (ModHook "projectile" dict).
# Spawned by WeaponBase._fire_projectile (the REAL firing path, not the
# sandbox) or by ModAPI.spawn_projectile (hook code). Voxel visual from
# the spec's "visual" description via VoxelAssetGenerator (pure
# generation, no cache IO on this path), speed / damage / range / gravity
# / explosion from the spec, on_hit / on_kill hooks from the firing
# weapon's attached hooks.
#
# Movement: straight line + optional gravity, one physics raycast per
# step (prev -> next position) so fast beams cannot tunnel through
# targets. On impact: on_hit hooks may multiply the damage, take_damage
# lands, a kill runs on_kill hooks, then an exploding projectile
# detonates (ForgeBuilder.fx_detonate — same blast as killstreaks).
# Pierce projectiles (spec pierce=true) keep flying after a hit instead
# of freeing (they still explode only once, on their final impact or at
# range expiry... in practice: a piercing projectile explodes on its
# FIRST impact and keeps flying without further explosions).
class_name ModProjectile
extends Node3D

var spec: Dictionary = {}
var hooks: Array = []
var _player: Node = null
var _dir := Vector3(0, 0, -1)
var _speed := 30.0
var _damage := 20.0
var _range := 100.0
var _gravity := 0.0
var _vel_y := 0.0
var _traveled := 0.0
var _dead := false
var _exploded := false
var _hit_rids: Array[RID] = []


## Configures the projectile (visual + ballistics). Does NOT place it;
## call launch() after adding it to the tree.
func setup(p_spec: Dictionary, p_hooks: Array, player: Node) -> void:
	spec = p_spec.duplicate(true)
	hooks = p_hooks
	_player = player
	_speed = float(spec.get("speed", 30.0))
	var dmg: Variant = spec.get("damage", -1.0)
	_damage = float(dmg) if (dmg is int or dmg is float) else 20.0
	_range = float(spec.get("range", 100.0))
	_gravity = float(spec.get("gravity", 0.0))
	_build_visual()


## Places the projectile at `from`, flying along `dir`.
func launch(from: Vector3, dir: Vector3) -> void:
	global_position = from
	_dir = dir.normalized()
	_vel_y = 0.0
	_traveled = 0.0
	_dead = false


## True once the projectile has impacted / expired (and freed itself).
func is_finished() -> bool:
	return _dead


func _build_visual() -> void:
	var visual := str(spec.get("visual", "glowing energy bolt"))
	var entries := VoxelAssetGenerator.generate_voxels(visual)
	var node := VoxelAssetGenerator.build_node(entries)
	node.name = "ModProjectileVisual"
	add_child(node)
	var s := float(spec.get("size", 1.0))
	node.scale = Vector3.ONE * s
	# A beam reads as a beam: stretch the voxel art along flight (-Z is
	# forward for the art; the projectile flies along _dir, and the node
	# is oriented to face it in step()).
	if str(spec.get("shape", "")) == "beam":
		node.scale.z *= 2.0
	# Beams glow: emissive material on the beam art so a laser reads in
	# dusk lighting (the voxel art's own material is matte).
	if str(spec.get("shape", "")) == "beam" or visual.contains("laser") or visual.contains("beam"):
		for child in node.get_children():
			if child is MeshInstance3D:
				var mat := StandardMaterial3D.new()
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mat.emission_enabled = true
				mat.emission = Color("ffe066")
				mat.emission_energy_multiplier = 2.5
				mat.albedo_color = Color("ffe066")
				(child as MeshInstance3D).material_override = mat


func _physics_process(delta: float) -> void:
	step(delta)


## Advances the projectile one step. Public so headless tests can drive
## it without waiting on physics frames.
func step(delta: float) -> void:
	if _dead:
		return
	# Face along the flight direction (art runs along -Z).
	if _dir.length_squared() > 0.001:
		look_at(global_position + _dir, Vector3.UP)
	var move := _dir * _speed * delta
	_vel_y -= _gravity * delta
	move.y += _vel_y * delta
	var from := global_position
	var next := from + move
	_traveled += move.length()
	var hit := _raycast(from, next)
	if not hit.is_empty():
		var pierced := _impact(hit)
		if pierced:
			# Pierce: keep flying — step past the hit point so the same
			# target is not struck twice (its RID is now excluded).
			global_position = next
			if _traveled >= _range:
				_dead = true
				queue_free()
		return
	global_position = next
	if _traveled >= _range:
		_dead = true
		queue_free()


func _raycast(from: Vector3, to: Vector3) -> Dictionary:
	var world := get_world_3d()
	if world == null:
		return {}
	var space := world.direct_space_state
	if space == null:
		return {}
	var exclude: Array[RID] = []
	if _player is CollisionObject3D:
		exclude.append((_player as CollisionObject3D).get_rid())
	exclude.append_array(_hit_rids)
	var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, exclude)
	return space.intersect_ray(query)


## Impacts the raycast hit. Returns true when the projectile pierces
## (keeps flying) instead of dying.
func _impact(hit: Dictionary) -> bool:
	var pierce := bool(spec.get("pierce", false))
	if not pierce:
		_dead = true
	var pos: Vector3 = hit.get("position", global_position)
	var collider: Variant = hit.get("collider", null)
	var api := _make_api()
	var ctx := {"position": pos, "hit_position": pos, "damage": _damage,
		"target": collider, "projectile": spec}
	# on_hit hooks may multiply THIS hit's damage (explosion / heal /
	# announce effects apply here too, at the impact point).
	var res := ModHookRegistry.run_hooks(hooks, "on_hit", api, ctx)
	var dmg := _damage * float(res.get("damage_mult", 1.0))
	var killed := false
	if collider != null and (collider as Object).has_method("take_damage"):
		(collider as Object).call("take_damage", dmg, pos, false)
		killed = ModHookRegistry.target_is_dead(collider)
		if pierce and collider is CollisionObject3D:
			_hit_rids.append((collider as CollisionObject3D).get_rid())
	if killed:
		var kctx := {"position": pos, "hit_position": pos, "damage": dmg,
			"target": collider, "projectile": spec}
		ModHookRegistry.run_hooks(hooks, "on_kill", api, kctx)
	if bool(spec.get("explodes_on_impact", false)) and not _exploded:
		_exploded = true
		ForgeBuilder.fx_detonate(pos, float(spec.get("explosion_radius", 4.0)), float(spec.get("explosion_damage", 60.0)))
	else:
		ImpactFX.spawn(pos, hit.get("normal", Vector3.UP))
	# v0.5.11 CHAIN: after the primary hit, arc to nearby enemies.
	# Only when the primary hit struck a damageable target (a wall
	# hit chains nowhere — the arc starts FROM the hit target).
	if collider != null and (collider as Object).has_method("take_damage"):
		_chain_from(pos, collider, dmg)
	if not pierce:
		queue_free()
	return pierce


## Chain: arc from the primary hit to up to chain_targets further
## enemies within chain_radius of each previous hit. Each jump deals
## the primary damage * chain_falloff^jump. With "element", chain
## hits apply through ElementalEmitter.apply_to_target (the
## element's rider — e.g. lightning knockback + wet conductivity);
## without it they are plain damage. Chain hits NEVER run on_hit /
## on_kill hooks and never chain again (one flat loop — no
## recursion, no feedback loops through kill effects).
func _chain_from(from_pos: Vector3, first_target: Node, primary_dmg: float) -> void:
	var jumps := int(spec.get("chain_targets", 0))
	if jumps <= 0:
		return
	var radius := float(spec.get("chain_radius", 3.0))
	var falloff := float(spec.get("chain_falloff", 0.5))
	var element := str(spec.get("element", ""))
	var hit_targets: Array = [first_target]
	var at := from_pos
	for jump in range(1, jumps + 1):
		var nxt := _nearest_other_foe(hit_targets, at, radius)
		if nxt == null:
			return
		hit_targets.append(nxt)
		var cdmg := primary_dmg * pow(falloff, jump)
		var npos := (nxt as Node3D).global_position if nxt is Node3D else at
		if not element.is_empty():
			ElementalEmitter.apply_to_target(nxt, element, cdmg, at)
		elif (nxt as Object).has_method("take_damage"):
			(nxt as Object).call("take_damage", cdmg, npos, false)
		ImpactFX.spawn(npos, Vector3.UP)
		at = npos


## Nearest enemy within max_dist of `from`, excluding every node in
## `exclude` and dead targets. Scans the "enemy"/"enemies" groups
## (same scan as ElementalEmitter._all_foes).
func _nearest_other_foe(exclude: Array, from: Vector3, max_dist: float) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var best: Node = null
	var best_d := max_dist
	var seen := {}
	for group in ["enemy", "enemies"]:
		for e in tree.get_nodes_in_group(group):
			if e == null or not is_instance_valid(e):
				continue
			var id := (e as Node).get_instance_id()
			if seen.has(id):
				continue
			seen[id] = true
			if e in exclude:
				continue
			if not (e is Node3D):
				continue
			if (e as Object).has_method("is_dead") and bool((e as Object).call("is_dead")):
				continue
			var d := (e as Node3D).global_position.distance_to(from)
			if d <= best_d:
				best_d = d
				best = e
	return best


func _make_api() -> ModAPI:
	var root: Node = null
	var tree := get_tree()
	if tree != null:
		root = tree.current_scene
		if root == null:
			root = tree.root
	return ModAPI.new(_player as Node3D, root)
