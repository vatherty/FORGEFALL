# FORGEFALL — ImpactFX
# Pooled impact dust, explosion smoke, and hard-landing dust. No per-spawn
# allocations beyond the preallocated pool; everything is capped and reused.
#
# API (all static, safe to call any time — no-op without a SceneTree):
#   ImpactFX.spawn(pos, normal)          — bullet-impact dust puff
#   ImpactFX.spawn_smoke(pos, radius)   — explosion smoke (called by ExplosionFX)
#   ImpactFX.spawn_landing(pos, hard)   — landing dust puff
#   ImpactFX.precache()                  — build the pool + bind landing early
#
# Landing dust self-wires: on first ensure, ImpactFX connects to the
# player node's `landed(hard)` signal (player is in the "player" group)
# and spawns a dust puff at the player's feet on hard landings only.
# No player.gd changes needed.
class_name ImpactFX
extends RefCounted

#region TUNABLES
const DUST_POOL_SIZE := 24
const DUST_LIFE := 0.5
const DUST_ALPHA := 0.55
const DUST_COLOR := Color(0.78, 0.74, 0.66)
const SMOKE_LIFE := 1.1
const SMOKE_ALPHA := 0.6
const SMOKE_COLOR := Color(0.16, 0.14, 0.13)
const LAND_LIFE := 0.6
const LAND_ALPHA := 0.5
#endregion

static var _root: Node3D = null
static var _pool: Array = [] # {node, mat, tween, order}
static var _order := 0
static var _landing_bound := false


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


static func _ensure(tree: SceneTree) -> bool:
	if _root != null and not is_instance_valid(_root):
		_root = null
		_pool.clear()
		_landing_bound = false
	if _root == null:
		var scene := tree.current_scene
		if scene == null:
			scene = tree.root
		if scene == null:
			return false
		_root = Node3D.new()
		_root.name = "ImpactFXRoot"
		scene.add_child(_root)
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 8
		sphere.rings = 6
		for i in DUST_POOL_SIZE:
			var mi := MeshInstance3D.new()
			mi.mesh = sphere
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			mat.albedo_color = Color(DUST_COLOR, 0.0)
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visible = false
			_root.add_child(mi)
			_pool.append({"node": mi, "mat": mat, "tween": null, "order": -1})
	_maybe_bind_landing(tree)
	return true


## Build the pool + bind the landing signal. Call once at game start.
static func precache() -> void:
	var tree := _tree()
	if tree != null:
		_ensure(tree)


static func _maybe_bind_landing(tree: SceneTree) -> void:
	if _landing_bound:
		return
	var players := tree.get_nodes_in_group("player")
	if players.is_empty():
		return
	var p: Node = players[0]
	if not p.has_signal("landed"):
		_landing_bound = true # no signal to bind; don't retry every spawn
		return
	var cb := Callable(ImpactFX, "_on_landed")
	if not p.is_connected("landed", cb):
		p.connect("landed", cb)
	_landing_bound = true


static func _on_landed(hard: bool) -> void:
	if not hard:
		return
	var tree := _tree()
	if tree == null:
		return
	var players := tree.get_nodes_in_group("player")
	if players.is_empty() or not (players[0] is Node3D):
		return
	var feet: Vector3 = (players[0] as Node3D).global_position
	feet.y += 0.1
	spawn_landing(feet, true)


static func _next_entry() -> Dictionary:
	for e in _pool:
		if e["tween"] == null:
			return e
	# Pool exhausted: steal the oldest active puff.
	var oldest: Dictionary = _pool[0]
	for e in _pool:
		if int(e["order"]) < int(oldest["order"]):
			oldest = e
	var tw: Tween = oldest["tween"]
	if tw != null and tw.is_valid():
		tw.kill()
	oldest["tween"] = null
	return oldest


static func _play(entry: Dictionary, pos: Vector3, dir: Vector3, color: Color,
		alpha: float, life: float, start_scale: float, end_scale: float,
		flatten: float) -> void:
	var mi: MeshInstance3D = entry["node"]
	var mat: StandardMaterial3D = entry["mat"]
	var old: Tween = entry["tween"]
	if old != null and old.is_valid():
		old.kill()
	mi.global_position = pos
	mi.scale = Vector3(start_scale, start_scale * flatten, start_scale)
	mat.albedo_color = Color(color, alpha)
	mi.visible = true
	_order += 1
	entry["order"] = _order
	var tw := _root.create_tween()
	entry["tween"] = tw
	tw.tween_method(_apply_puff.bind(entry, pos, dir, color, alpha,
		start_scale, end_scale, flatten), 0.0, 1.0, life)
	tw.tween_callback(_finish_puff.bind(entry))


static func _apply_puff(t: float, entry: Dictionary, origin: Vector3,
		dir: Vector3, color: Color, alpha: float, start_scale: float,
		end_scale: float, flatten: float) -> void:
	var mi: MeshInstance3D = entry["node"]
	var mat: StandardMaterial3D = entry["mat"]
	var s := lerpf(start_scale, end_scale, t)
	mi.scale = Vector3(s, s * flatten, s)
	mi.global_position = origin + dir * (t * 0.35) + Vector3(0, t * 0.25, 0)
	mat.albedo_color = Color(color, alpha * (1.0 - t))


static func _finish_puff(entry: Dictionary) -> void:
	var mi: MeshInstance3D = entry["node"]
	mi.visible = false
	entry["tween"] = null


## Bullet-impact dust puff. `normal` = hit surface normal (UP fallback).
static func spawn(pos: Vector3, normal: Vector3 = Vector3.UP) -> void:
	var tree := _tree()
	if tree == null or not _ensure(tree):
		return
	_play(_next_entry(), pos, normal.normalized(), DUST_COLOR, DUST_ALPHA,
		DUST_LIFE, 0.08, 0.45, 1.0)


## Explosion smoke: bigger, darker, longer-lived than impact dust.
static func spawn_smoke(pos: Vector3, radius: float) -> void:
	var tree := _tree()
	if tree == null or not _ensure(tree):
		return
	_play(_next_entry(), pos, Vector3.UP, SMOKE_COLOR, SMOKE_ALPHA,
		SMOKE_LIFE, 0.3, maxf(radius * 0.9, 0.6), 1.0)


## Landing dust: wide, ground-hugging (flattened) puff at the player's feet.
static func spawn_landing(pos: Vector3, hard: bool) -> void:
	var tree := _tree()
	if tree == null or not _ensure(tree):
		return
	var end_scale := 1.2 if hard else 0.7
	_play(_next_entry(), pos, Vector3.UP, DUST_COLOR, LAND_ALPHA,
		LAND_LIFE, 0.15, end_scale, 0.35)
