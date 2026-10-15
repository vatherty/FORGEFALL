# voxel_builder.gd — FORGEFALL shared voxel construction kit.
# Purpose: the single source of truth for all chunky-voxel geometry in the game
# (weapons, enemies, map props, Forge-spawned assemblies). Other workers depend
# on the exact static signatures below — do not rename or re-signature them.
# Connections: used by player/weapons/enemies/map/forge workers; pure static
# helpers (extends RefCounted, no scene-tree access), so it is safe to call from
# anywhere, including _ready() of any node. Minimal allocations: one shared
# BoxMesh(1,1,1) is reused for every cube; materials are cached per color.
class_name VoxelBuilder
extends RefCounted

## Voxel pitch in meters: one voxel = 12.5 cm cube.
const VOXEL_S := 0.125
## "Medium" voxel unit (2x pitch) used for chunkier props/debris.
const VOXEL_M := 0.25

## Canonical FORGEFALL palette (hex strings -> Color). Chunky military-shantytown
## tones plus the two portal accents and forge orange.
const PALETTE := {
	"gunmetal": Color("3a3f44"),
	"darkmetal": Color("23262a"),
	"tan": Color("c2a878"),
	"rust": Color("8a4b2a"),
	"concrete": Color("9a958c"),
	"wood": Color("7a5c38"),
	"canvas": Color("b8a888"),
	"olive": Color("5a6b3c"),
	"forge_orange": Color("ff7b1c"),
	"portal_blue": Color("1ca8ff"),
	"portal_orange": Color("ff8a1c"),
	"skin": Color("d9a066"),
	"shirt_green": Color("4a5d3a"),
}

# Shared unit cube mesh (1x1x1 m); cubes are made by scaling the NODE, never by
# duplicating the mesh resource. Lazily created on first use.
static var _unit_box: BoxMesh = null
# Material cache keyed by Color.to_html() so identical colors share one material.
static var _materials: Dictionary = {}


## Returns a cached StandardMaterial3D for the color (roughness 0.9, no
## metallic), except gunmetal which gets a slight metallic sheen (0.35).
static func mat(color: Color) -> StandardMaterial3D:
	var key: String = color.to_html()
	if _materials.has(key):
		return _materials[key] as StandardMaterial3D
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	m.metallic = 0.0
	if key == "3a3f44ff":  # gunmetal: slight metallic sheen
		m.metallic = 0.35
		m.roughness = 0.75
	_materials[key] = m
	return m


## Returns a MeshInstance3D cube of `size` meters at `pos`, using the shared
## unit BoxMesh (node scale) and a cached material. Cheap: no mesh duplication.
static func cube(size: Vector3, color: Color, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	if _unit_box == null:
		_unit_box = BoxMesh.new()  # default size is already (1,1,1)
	var mi := MeshInstance3D.new()
	mi.mesh = _unit_box
	mi.scale = size
	mi.position = pos
	mi.material_override = mat(color)
	return mi


## Builds a Node3D of voxel cubes from an array of [Vector3i, Color] entries.
## Grid positions are multiplied by VOXEL_S to get world positions.
static func build_voxels(voxels: Array) -> Node3D:
	var root := Node3D.new()
	root.name = "Voxels"
	var s := Vector3(VOXEL_S, VOXEL_S, VOXEL_S)
	for entry in voxels:
		var grid: Vector3i = entry[0]
		var col: Color = entry[1]
		root.add_child(cube(s, col, Vector3(grid) * VOXEL_S))
	return root


## Returns a CollisionShape3D with a BoxShape3D of the given size. Pair with a
## StaticBody3D (or any PhysicsBody3D) for invisible simplified collision.
static func collision_box(size: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	return cs


## Convenience: look up a palette color by name (falls back to white).
static func palette_color(palette_name: String) -> Color:
	return PALETTE.get(palette_name, Color.WHITE)
