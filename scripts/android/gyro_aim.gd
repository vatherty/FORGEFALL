# res://scripts/android/gyro_aim.gd
# FORGEFALL — Worker 9 (Android + touch)
#
# Gyro-assisted aiming. This is NOT a stub: Godot exposes the device gyroscope
# natively — VERIFIED (docs.godotengine.org/en/stable, class Input):
#   Input.get_gyroscope() -> Vector3  (rotation rate in rad/s around device
#   X/Y/Z axes; Vector3.ZERO when no sensor). Works on Android and iOS only.
#
# PROJECT SETTING REQUIRED (worker 1, project.godot):
#   input_devices/sensors/enable_gyroscope = true
# Without it, get_gyroscope() returns Vector3.ZERO on Android.
#
# Usage (main.gd adds it; options menu flips `enabled`):
#   var gyro := GyroAim.new()
#   add_child(gyro)   # enabled = false by default; Colin opts in.
#
# Sign/axis conventions depend on how the phone is held (landscape assumed).
# If aiming feels inverted on device, flip the signs in _process() — marked.
class_name GyroAim
extends Node

#region TUNABLES
const GAIN := 1.6        # radians of view per radian of device rotation (add_look takes radians)
const DEADZONE := 0.02   # rad/s; below this the gyro is ignored
const MAX_RATE := 6.0    # rad/s clamp against spikes
#endregion

@export var enabled := false
@export var sensitivity := 1.0  # shares the look-sensitivity option

var _rate := Vector3.ZERO  # reused
var _look := Vector2.ZERO  # reused


func _process(delta: float) -> void:
	if not enabled or delta <= 0.0:
		return
	if not (OS.has_feature("android") or OS.has_feature("ios")):
		return
	_rate = Input.get_gyroscope()
	if _rate.length_squared() < DEADZONE * DEADZONE:
		return
	var rx := clampf(_rate.x, -MAX_RATE, MAX_RATE)
	var ry := clampf(_rate.y, -MAX_RATE, MAX_RATE)
	# Landscape hold: device Y-rate ~ yaw, X-rate ~ pitch.
	# VERIFY ON DEVICE — flip a sign here if the view moves against the tilt.
	_look = Vector2(-ry * delta * GAIN * sensitivity, -rx * delta * GAIN * sensitivity)
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("add_look"):
		p.call("add_look", _look)
