# FORGEFALL — ForgePlacement (Forge batch, Worker B: items 2 + 3)
# Ghost preview + edit-placed-structures controller for Forge builds.
# Additive: the existing prompt -> ForgeManager -> ForgeBuilder pipeline
# is untouched. This controller is the piece the Forge menu (or any
# caller) uses to show a ghost BEFORE committing and to edit a placed
# structure afterwards:
#
#   var placement := ForgePlacement.attach_to(current_scene)
#   placement.start_preview("sniper_nest", {}, player, current_scene)
#   # ... ghost follows the crosshair every frame ...
#   placement.confirm_preview()  # builds at the ghost position
#   placement.cancel_preview()   # dismiss without building
#   placement.select_nearest()   # crosshair-pick a placed structure
#   placement.rotate_selected(45.0) / placement.move_selected_to(pos)
#   placement.repair_selected()  # full repair, works on structures /
#       covers / turrets via ForgeStructure.repair_target()
#   placement.delete_selected()  # removes it, no refund (budget off)
#
# Confirm builds through ForgeBuilder directly (the preset path: cost
# is computed via ForgeBuilder.structure_cost(), enforcement off — no
# budget is spent, matching this batch's preset contract). The
# LLM/prompt path keeps its own budget handling in ForgeManager.
#
# The static edit helpers (move_structure / rotate_structure /
# delete_structure / repair_structure) work without a controller
# instance, for callers that already hold the node.
extends Node
class_name ForgePlacement

## Emitted when the player confirms a BUILD preview (interact key).
## Carries the ghost position; the caller (Forge menu) builds the
## pending spec at that position through ForgeManager.
signal preview_confirm_requested(pos: Vector3)
## Emitted when the player confirms a MOVE preview. Carries the position.
signal preview_confirmed(pos: Vector3)
## Emitted when the player cancels a preview (ESC).
signal preview_cancelled

var _ghost: ForgeGhost = null
var _preview_shape := ""
var _preview_params := {}
var _player: Node3D = null
var _root: Node = null
var _preview_pos := Vector3.ZERO
var _preview_valid := false
var _selected: Node = null
var _move_mode := false
var _move_target: Node = null
var _hint_layer: CanvasLayer = null
var _hint_label: Label = null


## Returns the placement controller for `root`, creating one if needed.
static func attach_to(root: Node) -> ForgePlacement:
	for c in root.get_children():
		if c is ForgePlacement:
			return c as ForgePlacement
	var p := ForgePlacement.new()
	p.name = "ForgePlacement"
	root.add_child(p)
	return p


func _ready() -> void:
	add_to_group("forge_placement")


func _process(_delta: float) -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_update_preview()


## Input while a preview is active: INTERACT confirms, ESC cancels.
## Both mark the event handled so gameplay (interact-with-object,
## pause menu) does not ALSO fire on the same press.
func _input(event: InputEvent) -> void:
	if not has_preview():
		return
	if event.is_action_pressed("interact"):
		if _move_mode:
			var node := get_selected()
			if node != null and move_selected_to(_preview_pos):
				var pos := _preview_pos
				cancel_preview()
				preview_confirmed.emit(pos)
		else:
			preview_confirm_requested.emit(_preview_pos)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		cancel_preview()
		preview_cancelled.emit()
		get_viewport().set_input_as_handled()


func _show_hint(text: String) -> void:
	_hide_hint()
	_hint_layer = CanvasLayer.new()
	_hint_layer.name = "ForgePlacementHint"
	_hint_layer.layer = 50
	add_child(_hint_layer)
	_hint_label = Label.new()
	_hint_label.text = "Aim at a surface, then tap PLACE • CANCEL to dismiss" if OS.has_feature("web") or DisplayServer.is_touchscreen_available() else text
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint_label.offset_top = -56
	_hint_label.offset_bottom = -16
	_hint_layer.add_child(_hint_label)


func _hide_hint() -> void:
	if _hint_label != null and is_instance_valid(_hint_label):
		_hint_label.queue_free()
	_hint_label = null
	if _hint_layer != null and is_instance_valid(_hint_layer):
		_hint_layer.queue_free()
	_hint_layer = null


# --- Ghost preview -----------------------------------------------------------

## Starts a ghost preview for `shape`. Returns false for unknown shapes.
## Any active preview is cancelled first.
func start_preview(shape: String, params: Dictionary, player: Node3D, root: Node) -> bool:
	if not ForgeBuilder.is_structure_shape(shape):
		return false
	cancel_preview()
	_preview_shape = shape
	_preview_params = params.duplicate()
	_player = player
	_root = root
	_ghost = ForgeGhost.create_for_shape(shape)
	if _ghost == null:
		_preview_shape = ""
		return false
	_root.add_child(_ghost)
	_update_preview()
	_move_mode = false
	_move_target = null
	_show_hint("INTERACT to place • ESC to cancel")
	return true


## Move-preview: ghost the selected structure's shape at the crosshair;
## INTERACT moves the real node to the ghost position (see _input).
## Returns false when the node has no recognizable structure shape.
func start_move_preview(node: Node, player: Node3D, root: Node) -> bool:
	if not select(node):
		return false
	var shape := ""
	var sv: Variant = node.get("structure_shape")
	if sv is String:
		shape = str(sv)
	if shape.is_empty():
		shape = str(node.get_meta("shape", ""))
	if shape.is_empty() or not ForgeBuilder.is_structure_shape(shape):
		clear_selection()
		return false
	if not start_preview(shape, {}, player, root):
		return false
	_move_mode = true
	_move_target = node
	_show_hint("INTERACT to move • ESC to cancel")
	return true


func has_preview() -> bool:
	return _ghost != null and is_instance_valid(_ghost)


func preview_position() -> Vector3:
	return _preview_pos


func preview_valid() -> bool:
	return _preview_valid


func preview_shape() -> String:
	return _preview_shape


## Commits the preview: builds the structure at the ghost position.
## Returns the builder message. On failure the ghost stays up so the
## player can reposition; on success it is dismissed.
func confirm_preview() -> String:
	if not has_preview():
		return "No placement preview active."
	if not _preview_valid:
		return "Can't place here — structure cap reached or out of bounds."
	var params := _preview_params.duplicate()
	params["shape"] = _preview_shape
	params["position"] = [_preview_pos.x, _preview_pos.y, _preview_pos.z]
	var spec := {
		"spec_version": 1,
		"action": "spawn",
		"target": "structure",
		"params": params,
		"cost": 0,
		"ttl": 0,
	}
	var msg := ForgeBuilder.build(spec, {"player": _player, "root": _root})
	if msg.begins_with(ForgeBuilder.FAIL_PREFIX):
		return msg
	cancel_preview()
	return msg


func cancel_preview() -> void:
	_hide_hint()
	_move_mode = false
	_move_target = null
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	_preview_shape = ""
	_preview_params = {}


func _update_preview() -> void:
	if _ghost == null or not is_instance_valid(_ghost):
		return
	var target := ForgeBuilder.crosshair_point(_player)
	var snapped := ForgeBuilder.snap_to_ground(target, _root if _root != null else _ghost)
	var valid := (not ForgeBuilder.structure_cap_reached()) \
		and absf(snapped.x) <= ForgeBuilder.ARENA_LIMIT \
		and absf(snapped.z) <= ForgeBuilder.ARENA_LIMIT
	_preview_pos = snapped
	_preview_valid = valid
	_ghost.global_position = snapped
	if _player != null:
		# v0.5.7 Part B: the ghost shows the same yaw the build will
		# get — player facing + the spec's rotation_deg offset — so a
		# diagonal ramp previews diagonal.
		_ghost.rotation.y = _player.rotation.y + deg_to_rad(clampf(float(_preview_params.get("rotation_deg", 0.0)), -180.0, 180.0))
	_ghost.set_valid(valid)


# --- Edit placed structures --------------------------------------------------

## Crosshair-picks the nearest placed Forge structure. Returns true on
## a hit (selection set), false when nothing was picked.
func select_nearest(max_dist: float = 40.0) -> bool:
	_selected = _pick_structure(max_dist)
	return _selected != null and is_instance_valid(_selected)


## Selects `node` directly. Only members of group "forge_structure"
## (real placed builds — never ghosts, pickups, or map geometry) can
## be selected.
func select(node: Node) -> bool:
	if node != null and is_instance_valid(node) and node.is_in_group("forge_structure"):
		_selected = node
		return true
	return false


func get_selected() -> Node:
	if _selected != null and is_instance_valid(_selected):
		return _selected
	return null


func clear_selection() -> void:
	_selected = null


## Moves the selection to `pos` (snapped to ground). False when nothing
## is selected.
func move_selected_to(pos: Vector3) -> bool:
	var node := get_selected()
	if node == null:
		return false
	return move_structure(node, pos)


## Shifts the selection by `offset`. False when nothing is selected.
func move_selected_by(offset: Vector3) -> bool:
	var node := get_selected()
	if node == null or not (node is Node3D):
		return false
	return move_structure(node, (node as Node3D).global_position + offset)


## Yaws the selection by `degrees` (default one 45-degree step).
func rotate_selected(degrees: float = 45.0) -> bool:
	var node := get_selected()
	if node == null:
		return false
	return rotate_structure(node, degrees)


## Deletes the selection (no refund) and clears it.
func delete_selected() -> bool:
	var node := get_selected()
	if node == null:
		return false
	_selected = null
	return delete_structure(node)


## Fully repairs the selection. Returns HP restored (0 when the
## selection is already full, destroyed, or not repairable).
func repair_selected() -> float:
	var node := get_selected()
	if node == null:
		return 0.0
	return repair_structure(node)


## Raycasts from the camera through the crosshair and returns the first
## placed Forge structure hit (walking up from the struck collider, so
## hits on a structure's collision body still resolve to the structure
## node). Falls back to the nearest structure to the player when there
## is no camera.
func _pick_structure(max_dist: float) -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var cam: Camera3D = null
	if _player != null:
		cam = _player.get_viewport().get_camera_3d()
	if cam != null:
		var from := cam.global_position
		var to := from + -cam.global_transform.basis.z * max_dist
		var space := cam.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF)
		if _player is CollisionObject3D:
			query.exclude = [(_player as CollisionObject3D).get_rid()]
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var collider: Object = hit.get("collider")
			var n := collider as Node
			while n != null:
				if n.is_in_group("forge_structure"):
					return n
				n = n.get_parent()
	var ref := _player.global_position if _player != null else Vector3.ZERO
	var best: Node = null
	var best_d := max_dist
	for n in tree.get_nodes_in_group("forge_structure"):
		if n is Node3D:
			var d := ref.distance_to((n as Node3D).global_position)
			if d < best_d:
				best_d = d
				best = n
	return best


# --- Static edit helpers (no controller instance needed) ---------------------

## Moves `node` to `pos` (snapped to ground). Only placed Forge
## structures (group "forge_structure") move.
static func move_structure(node: Node, pos: Vector3) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not node.is_in_group("forge_structure"):
		return false
	if not (node is Node3D):
		return false
	(node as Node3D).global_position = ForgeBuilder.snap_to_ground(pos, node)
	return true


## Yaws `node` by `degrees`.
static func rotate_structure(node: Node, degrees: float = 45.0) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not node.is_in_group("forge_structure"):
		return false
	if not (node is Node3D):
		return false
	var s := node as Node3D
	s.rotation.y += deg_to_rad(degrees)
	return true


## Deletes `node` (no refund). Only placed Forge structures delete.
static func delete_structure(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not node.is_in_group("forge_structure"):
		return false
	return ForgeStructure.delete_target(node)


## Repairs `node` (amount < 0 = full). Returns HP actually restored.
static func repair_structure(node: Node, amount: float = -1.0) -> float:
	if node == null or not is_instance_valid(node):
		return 0.0
	return ForgeStructure.repair_target(node, amount)
