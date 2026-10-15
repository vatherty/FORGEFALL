# FORGEFALL — ForgeJumpPad (Forge batch, Worker B: item 6)
# The trigger volume of the "jump pad" Forge preset. The pad geometry
# (base + orange plate) is built by ForgeBuilder; this Area3D sits just
# above it and launches the player on contact.
#
# Launch feel reuses the player's existing jump numbers: JUMP_VELOCITY
# is 5.8 (a ~0.8 m hop) and slide-hop is 5.5. A pad that only matched
# those would feel like a slightly bigger jump, so the pad launches at
# 12.5 m/s vertical (~3.9 m apex against the player's GRAVITY 20) plus
# a small forward boost in the pad's facing direction. Horizontal
# velocity is preserved — the pad adds to it, never replaces it — so
# sprinting into a pad flies further, matching the game's momentum
# rules. A short per-body retrigger cooldown keeps standing on the pad
# from re-launching every physics frame.
extends Area3D
class_name ForgeJumpPad

const LAUNCH_VELOCITY := 12.5
const FORWARD_BOOST := 3.5
const RETRIGGER_COOLDOWN_MSEC := 400

var _last_launch: Dictionary = {}  # body instance id -> ticks msec


func _ready() -> void:
	collision_layer = 0
	collision_mask = 2  # player lives on layer 2 (scenes/player.tscn)
	monitoring = true
	monitorable = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 0.7, 2.0)
	shape.shape = box
	shape.position = Vector3(0, 0.35, 0)
	add_child(shape)
	body_entered.connect(_on_body_entered)


## Launches `body` if it is the player and off cooldown. Returns true
## when a launch happened. Public so tests can drive it without physics.
func launch_player(body: Node) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	if not (body is Node) or not (body as Node).is_in_group("player"):
		return false
	var now := Time.get_ticks_msec()
	var id := (body as Node).get_instance_id()
	if _last_launch.has(id) and now - int(_last_launch[id]) < RETRIGGER_COOLDOWN_MSEC:
		return false
	_last_launch[id] = now
	if body is CharacterBody3D:
		var cb := body as CharacterBody3D
		cb.velocity.y = maxf(cb.velocity.y, LAUNCH_VELOCITY)
		var fwd := -global_transform.basis.z
		fwd.y = 0.0
		if fwd.length() > 0.1:
			fwd = fwd.normalized()
			cb.velocity.x += fwd.x * FORWARD_BOOST
			cb.velocity.z += fwd.z * FORWARD_BOOST
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_3d"):
		sfx.play_3d("jump_land", global_position)
	return true


func _on_body_entered(body: Node) -> void:
	launch_player(body)
