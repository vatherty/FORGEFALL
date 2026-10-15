# res://scripts/android/perf_scaler.gd
# FORGEFALL — Worker 9 (Android + touch)
#
# Performance tiers for Android. Autoload-free Node: main.gd (worker 1) adds it:
#   var scaler := PerfScaler.new()
#   add_child(scaler)
#   scaler.auto_detect()   # or scaler.set_tier(PerfScaler.Tier.MED)
# The options menu calls set_tier() for the Quality setting.
#
# What each tier changes (MSAA is already off project-wide per build log):
#   HIGH: scaling_3d_scale 1.0, sun shadows on,  fx motes on
#   MED:  scaling_3d_scale 0.8, sun shadows on,  fx motes on
#   LOW:  scaling_3d_scale 0.65, sun shadows OFF, fx motes OFF
#
# VERIFIED APIs (docs.godotengine.org/en/stable):
#   - OS.get_processor_count() -> int (logical cores)
#   - OS.get_memory_info() -> Dictionary with "physical"/"free"/"available"/"stack"
#     in bytes; any entry may be -1 when unknown.
#   - Viewport.scaling_3d_mode (SCALING_3D_MODE_BILINEAR) + scaling_3d_scale (float).
# Tier thresholds below are HEURISTICS (assumption, logged not silent):
#   LOW: <= 6 cores or < 4 GB RAM.  MED: <= 8 cores or < 6 GB RAM. Else HIGH.
# Desktop (non-Android) always detects HIGH — the dev/playtest path is unscaled.
class_name PerfScaler
extends Node

enum Tier { HIGH, MED, LOW }

#region TUNABLES
const SCALE_HIGH := 1.0
const SCALE_MED := 0.8
const SCALE_LOW := 0.65
const LOW_MAX_CORES := 6
const LOW_MAX_RAM_GB := 4.0
const MED_MAX_CORES := 8
const MED_MAX_RAM_GB := 6.0
#endregion

var tier: int = Tier.HIGH


func _ready() -> void:
	# Defer so the map's sun/motes groups exist before first apply.
	call_deferred("_deferred_init")


func _deferred_init() -> void:
	auto_detect()


## Pick a tier from device hardware and apply it. Returns the tier.
func auto_detect() -> int:
	var t := Tier.HIGH
	if OS.has_feature("android"):
		var cores := OS.get_processor_count()
		var mem: Dictionary = OS.get_memory_info()
		var phys: int = int(mem.get("physical", -1))
		if phys <= 0:
			# RAM unknown on this device: decide on cores alone.
			if cores <= LOW_MAX_CORES:
				t = Tier.MED if cores > 4 else Tier.LOW
			elif cores <= MED_MAX_CORES:
				t = Tier.MED
		else:
			var gb := float(phys) / 1073741824.0
			if cores <= LOW_MAX_CORES or gb < LOW_MAX_RAM_GB:
				t = Tier.LOW
			elif cores <= MED_MAX_CORES or gb < MED_MAX_RAM_GB:
				t = Tier.MED
	set_tier(t)
	return t


## Apply a tier immediately. Idempotent; safe to call after scene changes.
func set_tier(t: int) -> void:
	tier = clampi(t, Tier.HIGH, Tier.LOW)
	var vp := get_viewport()
	if vp != null:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		match tier:
			Tier.HIGH:
				vp.scaling_3d_scale = SCALE_HIGH
			Tier.MED:
				vp.scaling_3d_scale = SCALE_MED
			Tier.LOW:
				vp.scaling_3d_scale = SCALE_LOW
	# Sun: map worker puts the DirectionalLight3D in group "sun".
	for n in get_tree().get_nodes_in_group("sun"):
		if n is DirectionalLight3D:
			(n as DirectionalLight3D).shadow_enabled = tier != Tier.LOW
	# Dust motes: map worker puts them in group "fx_motes".
	var motes_on := tier != Tier.LOW
	for n in get_tree().get_nodes_in_group("fx_motes"):
		if n is Node3D:
			(n as Node3D).visible = motes_on
		elif n is CanvasItem:
			(n as CanvasItem).visible = motes_on


## Re-apply the current tier (e.g. after a map reload repopulates groups).
func refresh() -> void:
	set_tier(tier)


static func tier_name(t: int) -> String:
	match t:
		Tier.HIGH:
			return "High"
		Tier.MED:
			return "Medium"
		Tier.LOW:
			return "Low"
	return "Unknown"
