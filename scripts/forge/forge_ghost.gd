# FORGEFALL — ForgeGhost (Forge batch, Worker B: item 2)
# Translucent preview of a Forge structure at the position it WOULD be
# placed, shown before the player commits. Valid = green-ish, invalid =
# red-ish. The ghost is visual-only: it reuses the exact structure
# geometry (ForgeBuilder.build_shape_geometry) but carries no collision
# (its StaticBody is never added to the tree), no behaviour nodes
# (jump-pad triggers etc. are stripped), no HP, and never joins group
# "forge_structure", so it cannot count toward the structure cap or
# take damage. ForgePlacement owns one ghost at a time and drives its
# position / validity from the crosshair every frame.
extends Node3D
class_name ForgeGhost

const VALID_COLOR := Color(0.25, 1.0, 0.35, 0.45)
const INVALID_COLOR := Color(1.0, 0.25, 0.25, 0.45)

var ghost_shape := ""
var _valid := true
var _mat: StandardMaterial3D = null


## Builds a ghost for `shape`, or null when the shape is unknown.
static func create_for_shape(shape: String) -> ForgeGhost:
	if not ForgeBuilder.is_structure_shape(shape):
		return null
	var g := ForgeGhost.new()
	g.ghost_shape = shape
	# Dummy body: never added to the tree, so its colliders never go
	# live. Geometry builders parent colliders to it either way.
	var dummy := StaticBody3D.new()
	ForgeBuilder.build_shape_geometry(shape, g, dummy)
	# Strip behaviour nodes (jump-pad Area3D triggers, ...): the ghost
	# must never launch the player or react to anything.
	var behaviours: Array[Node] = []
	for n in g.find_children("*", "Area3D", true, false):
		behaviours.append(n as Node)
	for n in behaviours:
		var parent := n.get_parent()
		if parent != null:
			parent.remove_child(n)
		n.queue_free()
	g._apply_material()
	return g


## Switches the tint: true = placeable (green), false = blocked (red).
func set_valid(valid: bool) -> void:
	_valid = valid
	if _mat == null:
		_apply_material()
	else:
		_mat.albedo_color = VALID_COLOR if _valid else INVALID_COLOR


func is_valid() -> bool:
	return _valid


func _apply_material() -> void:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.albedo_color = VALID_COLOR if _valid else INVALID_COLOR
	for n in find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
