# FORGEFALL — AmmoPickup (also health variant)
# Spinning voxel crate (Area3D) built in code. When a body in the "player"
# group enters: kind "ammo" -> WeaponManager.add_reserve_ammo(amount);
# kind "health" -> player.heal(amount) (guarded; the player worker owns
# health). Plays a 2D sfx and frees itself.
#
# ASSUMPTION (FIX 4, v0.5.1): the player CharacterBody3D lives on
# physics layer 2 (player.tscn `collision_layer = 2`). The mask covers
# layers 1|2; the group check in _on_body_entered makes the extra bit safe.
class_name AmmoPickup
extends Area3D

#region TUNABLES
const SPIN_SPEED := 1.6
const BOB_SPEED := 2.2
const BOB_AMOUNT := 0.08
const DETECT_RADIUS := 0.9
#endregion

@export var kind: String = "ammo" # "ammo" | "health"
@export var amount: int = 60

var _base_y: float = 0.0
var _t: float = 0.0
var _crate: Node3D = null


func _ready() -> void:
	collision_layer = 0
	collision_mask = 1 | 2
	monitoring = true
	monitorable = false
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = DETECT_RADIUS
	shape.shape = sphere
	add_child(shape)
	_crate = _build_crate()
	add_child(_crate)
	_base_y = _crate.position.y
	body_entered.connect(_on_body_entered)


func _build_crate() -> Node3D:
	var g := Node3D.new()
	g.name = "Crate"
	var pal := VoxelBuilder.PALETTE
	var main_col: Color = pal.get("tan", Color(0.76, 0.66, 0.47))
	var trim_col: Color = pal.get("gunmetal", Color(0.23, 0.25, 0.27))
	var glow_col: Color = pal.get("forge_orange", Color(1.0, 0.48, 0.11))
	if kind == "health":
		glow_col = pal.get("rust", Color(0.54, 0.29, 0.16))
	# Crate body: 3x2x3 voxels at VOXEL_S pitch, built as boxes.
	g.add_child(VoxelBuilder.cube(Vector3(0.375, 0.25, 0.375), main_col, Vector3.ZERO))
	g.add_child(VoxelBuilder.cube(Vector3(0.395, 0.05, 0.395), trim_col, Vector3(0, 0.10, 0)))
	g.add_child(VoxelBuilder.cube(Vector3(0.395, 0.05, 0.395), trim_col, Vector3(0, -0.10, 0)))
	if kind == "ammo":
		# Bullet glyph: brass tip row on top.
		g.add_child(VoxelBuilder.cube(Vector3(0.20, 0.06, 0.06), glow_col, Vector3(0, 0.155, 0)))
		g.add_child(VoxelBuilder.cube(Vector3(0.06, 0.06, 0.20), glow_col, Vector3(0, 0.155, 0)))
	else:
		# Cross glyph.
		g.add_child(VoxelBuilder.cube(Vector3(0.22, 0.06, 0.07), glow_col, Vector3(0, 0.155, 0)))
		g.add_child(VoxelBuilder.cube(Vector3(0.07, 0.06, 0.22), glow_col, Vector3(0, 0.155, 0)))
	return g


func _process(delta: float) -> void:
	_t += delta
	_crate.rotation.y = _t * SPIN_SPEED
	_crate.position.y = _base_y + sin(_t * BOB_SPEED) * BOB_AMOUNT


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	if kind == "health":
		if body.has_method("heal"):
			body.heal(amount)
			Sfx.play_2d("heal_pickup")
			queue_free()
		return
	var mgr := body.get_node_or_null("WeaponManager")
	if mgr != null and mgr.has_method("add_reserve_ammo"):
		mgr.add_reserve_ammo(amount)
		Sfx.play_2d("pickup")
		queue_free()
