# scripts/maps/destructible_cover.gd
# FORGEFALL — DestructibleCover (Worker 5: Map).
#
# A StaticBody3D made of voxels that fractures into pooled physics cubes when
# destroyed. This is the HEADLINE "destructible cover" feature: enemies and
# the Forge builder both depend on this exact contract (frozen):
#
#   - Nodes live in group "cover".
#   - take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void
#   - cover_point(threat_pos: Vector3) -> Vector3
#       (a stand-behind spot on the far side from the threat, ~1.2 m out,
#        at standing height above the cover's base, which is assumed at ground)
#
# The node builds its own single-MultiMesh voxel body in _ready (one draw
# call per cover), so set the exported vars BEFORE add_child().
#
# Forge builder usage (API stable — build cover at runtime like this):
#     var c := DestructibleCover.new()
#     c.vox_size = Vector3i(8, 5, 2)   # voxel dimensions
#     c.pitch = 0.25                   # metres per voxel
#     c.palette = [Color("9a958c"), Color("847f76")]
#     c.hp = 70.0
#     c.position = Vector3(x, 0, z)
#     map.add_child(c)                 # _ready() builds mesh + collision
#
# On fracture: hides itself, disables collision, fires
# DebrisPool.burst() with its palette, plays "cover_break" via Sfx if the
# autoload exists, leaves group "cover", and queue_frees.
class_name DestructibleCover
extends StaticBody3D

#region TUNABLES
@export var hp: float = 50.0
@export var vox_size: Vector3i = Vector3i(4, 4, 4)
@export var pitch: float = 0.25
@export var palette: Array[Color] = [Color("9a958c"), Color("847f76")]
@export var debris_speed: float = 5.0
@export var debris_count: int = 14
@export var headshot_mult: float = 1.5
#endregion

const COVER_POINT_OFFSET := 1.2  # metres behind cover, away from the threat
const COVER_POINT_HEIGHT := 1.0  # standing height above the cover base

static var _unit_mesh: BoxMesh = null
static var _mat: StandardMaterial3D = null  # shared white vertex-color material

var _broken := false
var _mi: MultiMeshInstance3D = null


func _ready() -> void:
	add_to_group("cover")
	collision_layer = 1
	collision_mask = 0
	if palette.is_empty():
		palette = [Color(0.6, 0.6, 0.6)]
	_build()


func is_broken() -> bool:
	return _broken


func take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void:
	if _broken:
		return
	hp -= amount * (headshot_mult if is_headshot else 1.0)
	if hp <= 0.0:
		fracture(hit_position)


func fracture(_at_position: Vector3 = Vector3.ZERO) -> void:
	if _broken:
		return
	_broken = true
	remove_from_group("cover")
	var center := global_position + Vector3(0.0, float(vox_size.y) * pitch * 0.5, 0.0)
	DebrisPool.burst(center, palette, debris_count, debris_speed)
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_3d"):
		sfx.play_3d("cover_break", center)
	if _mi != null:
		_mi.visible = false
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	queue_free()


## Standing spot on the far side of this cover from the threat.
func cover_point(threat_pos: Vector3) -> Vector3:
	var away := global_position - threat_pos
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = Vector3(1, 0, 0)
	away = away.normalized()
	var p := global_position + away * COVER_POINT_OFFSET
	p.y = global_position.y + COVER_POINT_HEIGHT
	return p


func _build() -> void:
	if _unit_mesh == null:
		_unit_mesh = BoxMesh.new()
		_unit_mesh.size = Vector3.ONE
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color.WHITE
		_mat.vertex_color_use_as_albedo = true
		_mat.roughness = 0.9
	var rng := RandomNumberGenerator.new()
	rng.seed = int(absf(global_position.x * 13.7 + global_position.z * 71.3)) + 1
	var sx := float(vox_size.x) * pitch
	var sy := float(vox_size.y) * pitch
	var sz := float(vox_size.z) * pitch
	var count := vox_size.x * vox_size.y * vox_size.z
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _unit_mesh
	mm.instance_count = count
	var i := 0
	for ix in vox_size.x:
		for iy in vox_size.y:
			for iz in vox_size.z:
				var lp := Vector3(
					(float(ix) + 0.5) * pitch - sx * 0.5,
					(float(iy) + 0.5) * pitch,
					(float(iz) + 0.5) * pitch - sz * 0.5)
				mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * pitch), lp))
				var c: Color = palette[rng.randi_range(0, palette.size() - 1)]
				var f := rng.randf_range(0.85, 1.08)
				mm.set_instance_color(i, Color(c.r * f, c.g * f, c.b * f))
				i += 1
	mm.custom_aabb = AABB(Vector3(-sx * 0.5, 0, -sz * 0.5), Vector3(sx, sy, sz))
	_mi = MultiMeshInstance3D.new()
	_mi.multimesh = mm
	_mi.material_override = _mat
	add_child(_mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(sx, sy, sz)
	cs.shape = bs
	cs.position = Vector3(0, sy * 0.5, 0)
	add_child(cs)
