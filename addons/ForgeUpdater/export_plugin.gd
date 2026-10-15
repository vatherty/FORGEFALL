# addons/ForgeUpdater/export_plugin.gd
# EditorExportPlugin packaging for the ForgeUpdater Android plugin (v2).
# Hooks the prebuilt AAR into Godot's Gradle export. The AAR's own manifest
# carries REQUEST_INSTALL_PACKAGES, the FileProvider <provider>, and the
# org.godotengine.plugin.v2 meta-data — the Android Gradle Plugin merges them
# into the app manifest automatically, so no _get_android_manifest_* overrides
# are needed here.
@tool
extends EditorPlugin

var _export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	var _plugin_name := "ForgeUpdater"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	# Paths are relative to res://addons/ (per EditorExportPlugin docs).
	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		if debug:
			return PackedStringArray(["ForgeUpdater/bin/ForgeUpdater-debug.aar"])
		return PackedStringArray(["ForgeUpdater/bin/ForgeUpdater-release.aar"])

	func _get_name() -> String:
		return _plugin_name
