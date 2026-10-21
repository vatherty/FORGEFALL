# res://scripts/android/haptics.gd
# FORGEFALL — Worker 9 (Android + touch)
#
# Static haptics helper. Any worker may call Haptics.buzz(ms) or the presets.
#
# VERIFIED (docs.godotengine.org/en/stable, class Input):
#   Input.vibrate_handheld(duration_ms: int = 500, amplitude: float = -1.0)
#   exists. On Android it REQUIRES the VIBRATE permission in the export preset
#   (see docs/android_export.md) or it silently does nothing. Device settings
#   (vibration off, do-not-disturb) can also suppress it.
#
# Guard policy: only Android/iOS call the real API; everywhere else buzz() is
# a no-op so desktop playtests never error.
class_name Haptics
extends RefCounted

#region TUNABLES
const UI_MS := 15    # menu / button taps
const SHOT_MS := 25  # weapon fire (weapons worker owns the call)
const HIT_MS := 45   # hitmarker confirm
const KILL_MS := 70  # kill confirm
const STREAK_MS := 120  # killstreak ready
#endregion


## Vibrate for ms milliseconds. No-op off mobile. Never raises.
static func buzz(ms: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var preferences := tree.root.get_node_or_null("Preferences")
		if preferences != null and not preferences.values.haptics:
			return
	if ms <= 0:
		return
	if not (OS.has_feature("android") or OS.has_feature("ios")):
		return
	Input.vibrate_handheld(ms)


static func ui() -> void:
	buzz(UI_MS)


static func shot() -> void:
	buzz(SHOT_MS)


static func hit() -> void:
	buzz(HIT_MS)


static func kill() -> void:
	buzz(KILL_MS)


static func streak_ready() -> void:
	buzz(STREAK_MS)
