# tools/verify_v06_mic.gd — headless checks for FORGEFALL v0.6.0 MIC (Worker C).
# Usage: godot --headless --path <project> --script res://tools/verify_v06_mic.gd
# Checks:
#   1. speech_input.gd exposes the listen path (plugin + RECORD_AUDIO
#      runtime-permission flow) and the v0.5.1 typed fallback (toast +
#      forge_console) still exists; press_console_on_fallback=false only
#      toasts (the Forge menu MIC case).
#   2. The Forge menu MIC insertable block (embedded below as #| comment
#      lines between BEGIN/END_MENU_MIC_BLOCK — the canonical deliverable
#      the coordinator applies to scripts/ui/forge_menu.gd) contains its
#      key lines, and its handler functions compile via GDScript.reload()
#      against stub declarations.
#   3. The ForgeSpeech plugin sources exist with the contracted API
#      (startListening + onResult via getPluginSignals/emitSignal, Android
#      SpeechRecognizer), the manifest carries RECORD_AUDIO + the v2
#      meta-data, and the manual-AAR build produced AARs (javac compile was
#      run separately by build-aar-manual.sh — see the worker report).
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _captured := ""


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _capture_result(text: String) -> void:
	_captured = text


func _initialize() -> void:
	var arena := Node.new()
	arena.name = "VerifyMicArena"
	root.add_child(arena)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	_run_checks()
	quit(1 if _fails > 0 else 0)
	return true


func _run_checks() -> void:
	_check_speech_input_source()
	_check_fallback_runtime()
	_check_plugin_result_path()
	_check_permission_result_path()
	_check_menu_mic_block()
	_check_plugin_sources()
	_check_touch_mic_wiring()


func _check_speech_input_source() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/android/speech_input.gd")
	_check(not src.is_empty(), "speech_input.gd readable")
	_check(src.contains("func listen(callback: Callable, press_console_on_fallback: bool = true)"),
		"speech_input exposes listen(callback, press_console_on_fallback=true)")
	_check(src.contains("PLUGIN_SINGLETON") and src.contains("\"ForgeSpeech\""),
		"speech_input expects the ForgeSpeech singleton")
	_check(src.contains("PERMISSION_RECORD_AUDIO") and src.contains("android.permission.RECORD_AUDIO"),
		"speech_input uses the full RECORD_AUDIO permission name")
	_check(src.contains("OS.request_permission(PERMISSION_RECORD_AUDIO)"),
		"speech_input requests RECORD_AUDIO at runtime")
	_check(src.contains("on_request_permissions_result"),
		"speech_input handles the async permission result")
	_check(src.contains("VOICE_UNAVAILABLE_MSG") and src.contains("Voice input isn't available yet"),
		"speech_input keeps the v0.5.1 voice-unavailable toast text")
	_check(src.contains("Input.action_press(\"forge_console\""),
		"speech_input fallback still presses forge_console (typed console)")
	_check(src.contains("func _on_plugin_result(text: String)"),
		"speech_input has the single onResult handler")
	_check(src.contains("func _start_plugin_listen"),
		"speech_input has the plugin-start helper")


func _check_fallback_runtime() -> void:
	# Desktop headless: no Android feature, no plugin -> fallback path.
	var speech := SpeechInput.new()
	root.add_child(speech)
	speech.call("listen", Callable())
	_check(str(speech.get("last_toast_text")).contains("Voice input"),
		"fallback records the voice-unavailable toast")
	_check(bool(speech.get("fallback_console_requested")) == true,
		"fallback requests the typed console (default press_console=true)")
	# Forge menu case: press_console_on_fallback=false -> toast only.
	var speech2 := SpeechInput.new()
	root.add_child(speech2)
	speech2.call("listen", Callable(), false)
	_check(str(speech2.get("last_toast_text")).contains("Voice input"),
		"menu fallback still toasts with press_console=false")
	_check(bool(speech2.get("fallback_console_requested")) == false,
		"menu fallback does NOT press forge_console (menu stays open)")


func _check_plugin_result_path() -> void:
	var speech := SpeechInput.new()
	root.add_child(speech)
	speech.set("_active_callback", Callable(self, "_capture_result"))
	_captured = ""
	speech.call("_on_plugin_result", "  build a wall  ")
	_check(_captured == "build a wall",
		"plugin result forwards the stripped transcript to the callback")
	# Empty result (plugin's error signal) -> typed fallback, no callback.
	var speech2 := SpeechInput.new()
	root.add_child(speech2)
	speech2.set("_active_callback", Callable(self, "_capture_result"))
	_captured = "SENTINEL"
	speech2.call("_on_plugin_result", "")
	_check(_captured == "SENTINEL",
		"empty plugin result does NOT invoke the callback")
	_check(str(speech2.get("last_toast_text")).contains("Voice input"),
		"empty plugin result falls back to toast + typed console")


func _check_permission_result_path() -> void:
	var speech := SpeechInput.new()
	root.add_child(speech)
	# Wrong permission -> ignored, pending stays true.
	speech.set("_permission_pending", true)
	speech.call("_on_permission_result", StringName("android.permission.CAMERA"), true)
	_check(bool(speech.get("_permission_pending")) == true,
		"permission result for another permission is ignored")
	# Denial -> typed fallback (unavailable), pending cleared.
	speech.set("_active_callback", Callable())
	speech.call("_on_permission_result", StringName("android.permission.RECORD_AUDIO"), false)
	_check(bool(speech.get("_permission_pending")) == false,
		"permission denial clears the pending flag")
	_check(str(speech.get("last_toast_text")).contains("Voice input"),
		"permission denial falls back to toast + typed console")


func _check_menu_mic_block() -> void:
	var block := _extract_menu_mic_block()
	_check(not block.is_empty(), "menu MIC insertable block extracted from this file")
	for key in [
		"var _mic_button: Button",
		"var _speech: SpeechInput",
		"var _wired := false",
		"_mic_button = Button.new()",
		"_mic_button.text = \"MIC\"",
		"prompt_row.add_child(_mic_button)",
		"_mic_button.pressed.connect(_on_mic_pressed)",
		"func _on_mic_pressed() -> void:",
		"_speech.listen(_on_voice_text, false)",
		"func _on_voice_text(text: String) -> void:",
		"_submit_prompt(transcript)",
		"_confirm_button.pressed.connect(_on_confirm_pressed)",
		"func _on_confirm_pressed() -> void:",
	]:
		_check(block.contains(key), "menu MIC block contains: " + key)
	# Compile-check the handler functions against stubs.
	var idx := block.find("func _on_mic_pressed")
	_check(idx >= 0, "menu MIC block handlers found for compile check")
	if idx >= 0:
		var handlers := block.substr(idx)
		var stub := "extends Node\nvar _speech\nvar _prompt_input\nvar _mic_button\n"
		stub += "func _show_toast(_t: String) -> void:\n\tpass\n"
		stub += "func _submit_prompt(_t: String) -> void:\n\tpass\n"
		stub += handlers
		var gs := GDScript.new()
		gs.source_code = stub
		var err := gs.reload()
		_check(err == OK, "menu MIC handler functions compile (GDScript.reload OK)")


func _check_plugin_sources() -> void:
	var base := OS.get_environment("HOME") + "/workspace/forgefall-plugin/ForgeSpeech/"
	var java_path := base + "src/main/java/com/sparky/forgefall/speech/ForgeSpeechPlugin.java"
	var java := FileAccess.get_file_as_string(java_path)
	_check(not java.is_empty(), "ForgeSpeechPlugin.java exists")
	for key in ["startListening", "onResult", "SpeechRecognizer",
			"getPluginSignals", "SignalInfo(\"onResult\", String.class)",
			"emitSignal", "getPluginName", "ForgeSpeech"]:
		_check(java.contains(key), "ForgeSpeechPlugin.java contains: " + key)
	var manifest := FileAccess.get_file_as_string(base + "src/main/AndroidManifest.xml")
	_check(manifest.contains("android.permission.RECORD_AUDIO"),
		"ForgeSpeech manifest declares RECORD_AUDIO")
	_check(manifest.contains("org.godotengine.plugin.v2.ForgeSpeech")
		and manifest.contains("com.sparky.forgefall.speech.ForgeSpeechPlugin"),
		"ForgeSpeech manifest carries the v2 meta-data")
	_check(FileAccess.file_exists(base + "build-aar-manual.sh"),
		"ForgeSpeech manual-AAR build script exists")
	_check(FileAccess.file_exists(base + "export_scripts_template/export_plugin.gd")
		and FileAccess.file_exists(base + "export_scripts_template/plugin.cfg"),
		"ForgeSpeech export packaging (export_plugin.gd + plugin.cfg) delivered")
	for aar in ["bin/ForgeSpeech-debug.aar", "bin/ForgeSpeech-release.aar"]:
		var f := FileAccess.open(base + aar, FileAccess.READ)
		_check(f != null and f.get_length() > 0, "ForgeSpeech AAR built: " + aar)
		if f != null:
			f.close()


func _check_touch_mic_wiring() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/android/touch_controls.gd")
	_check(src.contains("_speech.listen(_on_voice_text)"),
		"touch MIC button still routes through SpeechInput.listen")
	_check(src.contains("func _on_voice_text") and src.contains("strip_edges"),
		"touch MIC handler strips and drops empty transcripts")


## Reconstructs the canonical menu MIC block from the #| comment lines
## between BEGIN/END_MENU_MIC_BLOCK at the end of this file.
func _extract_menu_mic_block() -> String:
	var path: String = get_script().resource_path
	var text := FileAccess.get_file_as_string(path)
	# rfind: the literal marker strings also appear in this function's own
	# source above, so the LAST occurrence is the real marker at file end.
	var begin := text.rfind("# BEGIN_MENU_MIC_BLOCK")
	var end := text.rfind("# END_MENU_MIC_BLOCK")
	if begin < 0 or end < 0 or end <= begin:
		return ""
	var section := text.substr(begin, end - begin)
	var lines := PackedStringArray()
	for raw in section.split("\n"):
		var line := raw.strip_edges(false, true)
		if line.begins_with("#|"):
			var content := line.substr(2)
			if content.begins_with(" "):
				content = content.substr(1)
			lines.append(content)
	return "\n".join(lines)


# BEGIN_MENU_MIC_BLOCK — v0.6.0 Worker C: Forge menu MIC button.
# Canonical deliverable. The coordinator applies the three parts to
# scripts/ui/forge_menu.gd (owned by another worker) at the anchors given.
# Do NOT hand-edit the block below the markers: this verifier extracts
# these #| lines verbatim and compile-checks the handler functions.
#| # --- v0.6.0 MIC (Worker C) — PART 1: member vars ---
#| # ANCHOR: scripts/ui/forge_menu.gd, immediately after the line:
#| #     var _wired := false
#| # INSERT these two lines:
#| var _mic_button: Button
#| var _speech: SpeechInput
#|
#| # --- v0.6.0 MIC (Worker C) — PART 2: MIC button in the prompt row ---
#| # ANCHOR: scripts/ui/forge_menu.gd, in _build(), immediately after:
#| #     _confirm_button.pressed.connect(_on_confirm_pressed)
#| #     prompt_row.add_child(_confirm_button)
#| # INSERT:
#| # v0.6.0 MIC: voice input inside the Forge menu. Same path as the
#| # touch-layer MIC button: SpeechInput.listen() transcribes via the
#| # ForgeSpeech plugin when available, else falls back to the typed
#| # console + toast (the v0.5.1 floor — never removed). The fallback
#| # does NOT press forge_console here (listen(..., false)): the menu
#| # already shows a text field, and forge_console would toggle the
#| # menu closed.
#| _mic_button = Button.new()
#| _mic_button.name = "MicButton"
#| _mic_button.text = "MIC"
#| _mic_button.custom_minimum_size = Vector2(96, 56)
#| StencilStyle.style_button(_mic_button)
#| _mic_button.add_theme_font_size_override("font_size", 22)
#| _mic_button.pressed.connect(_on_mic_pressed)
#| prompt_row.add_child(_mic_button)
#| if _speech == null:
#| 	_speech = SpeechInput.new()
#| 	_speech.name = "SpeechInput"
#| 	add_child(_speech)
#|
#| # --- v0.6.0 MIC (Worker C) — PART 3: handlers ---
#| # ANCHOR: scripts/ui/forge_menu.gd, immediately after _on_confirm_pressed:
#| #     func _on_confirm_pressed() -> void:
#| #         _submit_prompt(_prompt_input.text)
#| # INSERT:
#| func _on_mic_pressed() -> void:
#| 	# Voice → transcript submits through the same _submit_prompt path
#| 	# as typed input (cost preview / history / forge_result all apply).
#| 	# No plugin or no mic permission → SpeechInput falls back to the
#| 	# typed console + "Voice input isn't available yet" toast.
#| 	if _speech == null:
#| 		_speech = SpeechInput.new()
#| 		_speech.name = "SpeechInput"
#| 		add_child(_speech)
#| 	_speech.listen(_on_voice_text, false)
#|
#|
#| func _on_voice_text(text: String) -> void:
#| 	var transcript := text.strip_edges()
#| 	if transcript.is_empty():
#| 		_show_toast("Didn't catch that — type your prompt.")
#| 		return
#| 	_submit_prompt(transcript)
# END_MENU_MIC_BLOCK
