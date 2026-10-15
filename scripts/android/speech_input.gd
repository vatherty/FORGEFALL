# res://scripts/android/speech_input.gd
# FORGEFALL — Worker 9 (Android + touch) + Worker C (v0.6.0 MIC)
#
# Voice-to-Forge prompter (the MIC touch button + the Forge menu MIC feed this).
#
# v0.6.0: voice input is REAL on Android via the ForgeSpeech plugin
# (~/workspace/forgefall-plugin/ForgeSpeech/, manual-AAR build, no Gradle):
#   PLUGIN PATH — the Engine singleton "ForgeSpeech" drives Android's
#   SpeechRecognizer; the final transcript arrives on its onResult(text)
#   signal and is delivered to the listen() callback, which submits it to
#   Forge. RECORD_AUDIO is requested at runtime first (Android 6+):
#   OS.request_permission() returns true when already granted (Godot docs),
#   otherwise the answer arrives via MainLoop.on_request_permissions_result
#   — grant auto-starts listening, denial falls back. The plugin itself
#   never requests permissions; it emits onResult("") on any recognition
#   failure, which this file treats as "no result" and falls back.
#   TYPED FALLBACK — always available: shows a VISIBLE toast
#   ("Voice input isn't available yet — type your prompt", routed
#   through the existing Forge forge_result feedback so the HUD feed
#   and Forge menu both display it) and THEN presses the
#   contract-frozen "forge_console" input action, opening the typed
#   Forge console (worker 6). The console is NEVER opened silently:
#   the user always sees why they got a keyboard instead of voice.
#   The callback is NOT invoked on this path (no text to deliver).
#   Callers that ALREADY show a text field (the Forge menu's own MIC
#   button) pass press_console_on_fallback=false so the fallback only
#   toasts and never toggles the menu closed via forge_console.
#
# Contract (frozen): listen(callback) with the ForgeSpeech singleton check;
# v0.6.0 only extends it with the optional press_console_on_fallback flag
# (default true — existing callers are untouched).
class_name SpeechInput
extends Node

const PLUGIN_SINGLETON := "ForgeSpeech"
## Full Android permission name (Godot docs examples use the
## "android.permission.*" form for OS.request_permission).
const PERMISSION_RECORD_AUDIO := "android.permission.RECORD_AUDIO"

## v0.5.1 FIX 7a: shown (never silently) whenever the MIC falls back to
## the typed console. Reuses the existing Forge feedback channel — no
## new toast system is built here.
const VOICE_UNAVAILABLE_MSG := "Voice input isn't available yet — type your prompt"
## Shown while the system mic-permission dialog is up (the grant result
## arrives async; denial falls back to the typed console).
const PERMISSION_PENDING_MSG := "Allow microphone access, then tap MIC again."

var _listening := false
## Last fallback toast text shown (headless-verifiable record of the
## visible feedback; the real display goes through Forge/HUD/menu).
var last_toast_text: String = ""
## True after the typed fallback requested the console (headless-verifiable
## alongside Input.is_action_pressed("forge_console")).
var fallback_console_requested := false
## Callback awaiting a transcript while a permission answer or a
## recognition result is in flight.
var _active_callback: Callable
## True while a RECORD_AUDIO answer is outstanding.
var _permission_pending := false
## listen()-time choice: press forge_console on the fallback path.
var _fallback_press_console := true


## True only on Android when the ForgeSpeech plugin singleton is registered.
static func is_available() -> bool:
	return OS.has_feature("android") and Engine.has_singleton(PLUGIN_SINGLETON)


## True when RECORD_AUDIO is already granted (Android only).
func _permission_granted() -> bool:
	if not OS.has_feature("android"):
		return false
	return OS.get_granted_permissions().has(PERMISSION_RECORD_AUDIO)


## Begin voice capture. Plugin path -> callback(text) on transcription.
## Fallback path -> opens the typed Forge console (unless
## press_console_on_fallback is false, in which case it only toasts),
## callback not called.
func listen(callback: Callable, press_console_on_fallback: bool = true) -> void:
	_fallback_press_console = press_console_on_fallback
	if is_available() and not _listening:
		if _permission_granted():
			_start_plugin_listen(callback)
			return
		# Android 6+: RECORD_AUDIO needs a runtime grant. Ask once; the
		# answer arrives via MainLoop.on_request_permissions_result —
		# grant auto-starts listening, denial falls back (unavailable).
		# Do NOT open the typed console underneath the system dialog:
		# wait for the answer instead.
		_active_callback = callback
		_permission_pending = true
		_connect_permission_result()
		if OS.request_permission(PERMISSION_RECORD_AUDIO):
			# Already granted (docs: returns true when already granted).
			_permission_pending = false
			_start_plugin_listen(callback)
			return
		_show_toast_text(PERMISSION_PENDING_MSG)
		return
	# Fallback (no plugin, or plugin call failed): typed console + toast.
	_typed_fallback()


## Single handler for the plugin's onResult(text). Resets the gate,
## forwards non-empty transcripts, falls back on empty (the plugin emits
## "" on any recognition error / unavailable recognizer).
func _on_plugin_result(text: String) -> void:
	_listening = false
	var cb := _active_callback
	_active_callback = Callable()
	var transcript := text.strip_edges()
	if transcript.is_empty():
		_typed_fallback()
		return
	if cb.is_valid():
		cb.call(transcript)


func _start_plugin_listen(callback: Callable) -> void:
	var plugin: Object = Engine.get_singleton(PLUGIN_SINGLETON)
	if plugin == null or not plugin.has_method("startListening"):
		_typed_fallback()
		return
	_active_callback = callback
	if plugin.has_signal("onResult") and not plugin.is_connected("onResult", _on_plugin_result):
		plugin.connect("onResult", _on_plugin_result)
	_listening = true
	plugin.call("startListening")


func _connect_permission_result() -> void:
	var main_loop := Engine.get_main_loop()
	if main_loop != null and main_loop.has_signal("on_request_permissions_result"):
		if not main_loop.is_connected("on_request_permissions_result", _on_permission_result):
			main_loop.connect("on_request_permissions_result", _on_permission_result)


## MainLoop.on_request_permissions_result(permission, granted) — the async
## answer to OS.request_permission(PERMISSION_RECORD_AUDIO).
func _on_permission_result(permission: StringName, granted: bool) -> void:
	if not _permission_pending:
		return
	if permission != StringName(PERMISSION_RECORD_AUDIO):
		return
	_permission_pending = false
	if granted:
		_start_plugin_listen(_active_callback)
	else:
		# Denial == unavailable: the v0.5.1 floor (toast + typed console).
		_typed_fallback()


func _typed_fallback() -> void:
	_permission_pending = false
	# FIX 7a: NEVER silently — tell the user voice isn't available, then
	# open the typed console (unless the caller already shows a text
	# field, e.g. the Forge menu's MIC button). Toast first so the
	# message is queued before the console appears (HUD feed entries /
	# menu toast persist into it).
	_show_voice_unavailable_toast()
	if not _fallback_press_console:
		return
	fallback_console_requested = true
	# Same input path as the on-screen FORGE button: contract-frozen action.
	# Release is deferred one frame so is_action_just_pressed() observers
	# (the player/HUD) still see the tap.
	Input.action_press("forge_console", 1.0)
	_release_next_frame("forge_console")


func _show_toast_text(text: String) -> void:
	last_toast_text = text
	if not is_inside_tree():
		return
	# Primary path: the existing Forge feedback channel. Both the HUD
	# (forge feed entry) and the Forge menu (toast) already listen to
	# Forge.forge_result, so one emit reaches both visible surfaces.
	var forge := get_node_or_null("/root/Forge")
	if forge != null and forge.has_signal("forge_result"):
		forge.emit_signal("forge_result", false, text)
		return
	# No Forge autoload (e.g. isolated test): reuse the HUD banner +
	# Forge menu toast directly. Still no new toast system.
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("announce"):
		hud.call("announce", "VOICE UNAVAILABLE", "Type your prompt")
	for menu in get_tree().get_nodes_in_group("forge_menu"):
		if menu.has_method("show_feedback"):
			menu.call("show_feedback", text)


func _show_voice_unavailable_toast() -> void:
	_show_toast_text(VOICE_UNAVAILABLE_MSG)


func _release_next_frame(action: StringName) -> void:
	await get_tree().process_frame
	Input.action_release(action)


## Human-readable status for a debug/options row.
static func status_text() -> String:
	if is_available():
		return "Voice input: plugin ready"
	if OS.has_feature("android"):
		return "Voice input: typed console (no STT plugin installed)"
	return "Voice input: unavailable on desktop"
