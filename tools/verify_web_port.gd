# verify_web_port.gd — FORGEFALL web-port source verification (Worker B, 2026-10-19).
# Usage: godot --headless --path <project> --script res://tools/verify_web_port.gd
# Source-level assertions for the Godot 4.7.2 web (nothreads) port:
#   (a) export_presets.cfg has a Web preset with variant/thread_support=false
#   (b) touch_controls.gd enables touch on web (OS.has_feature("web") in the
#       _touch_active enablement path)
#   (c) ForgeUpdater is gated on web: UpdaterPC._ready parks the Android
#       manager in DISABLED on web, main_menu routes manual checks to null,
#       update_manager.gd carries no web branch (byte-identical by design),
#       and no PackageInstaller symbol survives comment/string stripping
#       (the plugin singleton never exists on web, so that path is dead)
#   (d) speech/voice falls back to the typed path on web: SpeechInput.
#       is_available() requires Android + the ForgeSpeech singleton, and
#       listen() drops to _typed_fallback() when unavailable
#   (e) multiplayer entry is disabled + relabeled on web, and the "mp" mode
#       scope is only reachable through that one button
#   (f) forge_llm.gd points DIRECTLY at https://api.deepseek.com/chat/completions
#       with no proxy / workers.dev / cloudflare code anywhere in the file
#   (g) no Thread token in executable code anywhere under res://scripts/
#       (comments and string literals stripped first, so the mod-denylist
#       strings mentioning "Thread" do not count)
# Exit 0 = all checks pass; any FAIL prints and exits 1.
# Reads game source only; modifies nothing.
extends SceneTree

var _passes := 0
var _fails := 0


func _pass(label: String) -> void:
	_passes += 1
	print("  PASS: " + label)


func _fail(label: String, detail: String) -> void:
	_fails += 1
	printerr("  FAIL: " + label + " — " + detail)


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "<MISSING>"
	return FileAccess.get_file_as_string(path)


func _need(path: String, label: String) -> String:
	var text := _read(path)
	if text == "<MISSING>":
		_fail(label, path + " not found")
	return text


## Strip triple-quoted blocks, quoted strings, then # comments, leaving
## executable code only. Used so denylist strings / comments mentioning
## banned tokens do not count as usage.
func _code(src: String) -> String:
	var re3 := RegEx.new()
	re3.compile('(?s)"""(.*?)"""')
	var s: String = re3.sub(src, "", true)
	var out: PackedStringArray = []
	for ln in s.split("\n"):
		out.append(_strip_line(ln))
	return "\n".join(out)


func _strip_line(ln: String) -> String:
	var res := ""
	var i := 0
	var n := ln.length()
	while i < n:
		var c := ln.substr(i, 1)
		if c == "#":
			break
		if c == "\"" or c == "'":
			var q := c
			i += 1
			while i < n:
				var d := ln.substr(i, 1)
				if d == "\\":
					i += 2
				elif d == q:
					i += 1
					break
				else:
					i += 1
		else:
			res += c
			i += 1
	return res


func _list_gd(dir: String, acc: Array) -> void:
	for sub in DirAccess.get_directories_at(dir):
		if sub != ".godot" and not sub.begins_with("."):
			_list_gd(dir.path_join(sub), acc)
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".gd"):
			acc.append(dir.path_join(file))


func _next_preset_start(text: String, from: int) -> int:
	var p := from
	var h := text.find("[preset.", p)
	while h >= 0:
		var hend := text.find("]", h)
		if hend < 0:
			return -1
		# Skip "[preset.N.options]" subsections — they belong to the preset block.
		if not text.substr(h, hend - h + 1).contains(".options]"):
			return h
		p = hend + 1
		h = text.find("[preset.", p)
	return -1


func _check_export_preset() -> void:
	var text := _need("res://export_presets.cfg", "web-preset")
	if text == "<MISSING>":
		return
	# Slice the cfg into [preset.N] blocks manually (robust, no regex needed).
	# A preset's own [preset.N.options] subsection stays inside its block.
	var blocks: Array = []
	var idx := 0
	while true:
		var h := _next_preset_start(text, idx)
		if h < 0:
			break
		var hend := text.find("]", h)
		var nxt := _next_preset_start(text, hend)
		var body: String
		if nxt >= 0:
			body = text.substr(hend + 1, nxt - hend - 1)
		else:
			body = text.substr(hend + 1)
		blocks.append(body)
		if nxt < 0:
			break
		idx = nxt
	var web := ""
	for b in blocks:
		if (b as String).contains("name=\"Web\""):
			web = b
	if web == "":
		_fail("web-preset/exists", "no preset named \"Web\" in export_presets.cfg")
		return
	_pass("web-preset/exists")
	if web.contains("platform=\"Web\""):
		_pass("web-preset/platform=Web")
	else:
		_fail("web-preset/platform=Web", "Web preset missing platform=\"Web\"")
	if web.contains("variant/thread_support=false"):
		_pass("web-preset/thread_support=false (nothreads)")
	else:
		_fail("web-preset/thread_support=false (nothreads)", "Web preset does not pin variant/thread_support=false")


func _check_touch_controls() -> void:
	var text := _need("res://scripts/android/touch_controls.gd", "touch")
	if text == "<MISSING>":
		return
	var i := text.find("_touch_active =")
	if i < 0:
		_fail("touch/web-in-enable-path", "_touch_active assignment not found")
		return
	# The assignment continues over backslash-continued lines; take a window.
	var seg := text.substr(i, 600)
	if seg.contains("OS.has_feature(\"web\")") and seg.contains("DisplayServer.is_touchscreen_available()"):
		_pass("touch/web-in-enable-path (_touch_active on browsers)")
	else:
		_fail("touch/web-in-enable-path", "OS.has_feature(\"web\") missing from _touch_active enablement")


func _check_updater_gating() -> void:
	var pc := _need("res://scripts/core/update_manager_pc.gd", "updater-pc")
	var mm := _need("res://scripts/ui/main_menu.gd", "updater-menu")
	var um := _need("res://scripts/core/update_manager.gd", "updater-android")
	if pc == "<MISSING>" or mm == "<MISSING>" or um == "<MISSING>":
		return
	# UpdaterPC._ready: on web, park the Android manager + DISABLED + return.
	var w := pc.find("OS.has_feature(\"web\")")
	if w < 0:
		_fail("updater/web-parked-disabled", "no OS.has_feature(\"web\") branch in update_manager_pc.gd")
	else:
		var seg := pc.substr(w, 700)
		if seg.contains("_hand_off_android_updater()") and seg.contains("State.DISABLED") and seg.contains("return"):
			_pass("updater/web-parked-disabled (Android manager parked, UpdaterPC DISABLED)")
		else:
			_fail("updater/web-parked-disabled", "web branch does not park the Android updater in DISABLED")
	# main_menu._active_updater: null on web, so manual checks are inert.
	var f := mm.find("func _active_updater()")
	if f < 0:
		_fail("updater/menu-routes-null-on-web", "func _active_updater() not found in main_menu.gd")
	else:
		var fseg := mm.substr(f, 500)
		if fseg.contains("OS.has_feature(\"web\")") and fseg.contains("return null"):
			_pass("updater/menu-routes-null-on-web")
		else:
			_fail("updater/menu-routes-null-on-web", "_active_updater() does not return null on web")
	# update_manager.gd is byte-identical by design (its headless tests run on
	# Linux): no web branch may live there. The handoff above is the mechanism.
	if um.contains("has_feature(\"web\")"):
		_fail("updater/android-manager-untouched", "update_manager.gd gained a web branch (breaks the handoff pattern)")
	else:
		_pass("updater/android-manager-untouched (no web branch; handoff lives in UpdaterPC)")
	# No PackageInstaller symbol in executable code: the only install path goes
	# through Engine.get_singleton("ForgeUpdater"), which never exists on web.
	if _code(um).contains("PackageInstaller"):
		_fail("updater/no-packageinstaller-on-web", "PackageInstaller reachable in update_manager.gd code")
	else:
		_pass("updater/no-packageinstaller-on-web (plugin-singleton path only)")
	# The singleton calls are guarded by has_singleton checks.
	if um.count("Engine.has_singleton(PLUGIN_NAME)") > 0 and um.count("Engine.get_singleton(PLUGIN_NAME)") > 0:
		_pass("updater/plugin-calls-singleton-guarded")
	else:
		_fail("updater/plugin-calls-singleton-guarded", "plugin singleton call/guard pattern changed")


func _check_speech_fallback() -> void:
	var text := _need("res://scripts/android/speech_input.gd", "speech")
	if text == "<MISSING>":
		return
	var ia := text.find("static func is_available()")
	if ia < 0:
		_fail("speech/is_available-false-on-web", "static func is_available() not found")
	else:
		var seg := text.substr(ia, 250)
		if seg.contains("OS.has_feature(\"android\")") and seg.contains("Engine.has_singleton(PLUGIN_SINGLETON)"):
			_pass("speech/is_available-false-on-web (needs Android + ForgeSpeech singleton)")
		else:
			_fail("speech/is_available-false-on-web", "is_available() gate changed")
	var li := text.find("func listen(")
	if li < 0:
		_fail("speech/listen-falls-back-to-typed", "func listen() not found")
	elif text.substr(li, 3000).contains("_typed_fallback()"):
		_pass("speech/listen-falls-back-to-typed")
	else:
		_fail("speech/listen-falls-back-to-typed", "listen() has no _typed_fallback() path")


func _check_multiplayer_gating() -> void:
	var text := _need("res://scripts/ui/main_menu.gd", "multiplayer")
	if text == "<MISSING>":
		return
	var li := text.find("MULTIPLAYER (APP VERSION ONLY)")
	if li < 0:
		_fail("multiplayer/disabled-relabeled-on-web", "web relabel text not found")
	else:
		var seg := text.substr(maxi(0, li - 700), 1100)
		if seg.contains("OS.has_feature(\"web\")") and seg.contains("disabled = true") and seg.contains("MultiplayerButton"):
			_pass("multiplayer/disabled-relabeled-on-web")
		else:
			_fail("multiplayer/disabled-relabeled-on-web", "web gate around MultiplayerButton incomplete")
	# The "mp" scope must be reachable ONLY through the gated button's handler.
	var mp_calls := 0
	var search := 0
	while true:
		var p := text.find("_open_mode_select(\"mp\")", search)
		if p < 0:
			break
		mp_calls += 1
		search = p + 1
	var handler := text.find("func _on_multiplayer()")
	if mp_calls == 1 and handler >= 0 and text.find("_open_mode_select(\"mp\")") > handler:
		_pass("multiplayer/mp-scope-only-via-gated-button")
	else:
		_fail("multiplayer/mp-scope-only-via-gated-button", "found %d _open_mode_select(\"mp\") call sites" % mp_calls)


func _check_llm_direct() -> void:
	var text := _need("res://scripts/forge/forge_llm.gd", "llm")
	if text == "<MISSING>":
		return
	if text.contains("https://api.deepseek.com/chat/completions"):
		_pass("llm/direct-deepseek-url (api.deepseek.com/chat/completions)")
	else:
		_fail("llm/direct-deepseek-url", "direct DeepSeek URL not found in forge_llm.gd")
	var low := text.to_lower()
	var bad: Array = []
	for w in ["proxy", "workers.dev", "cloudflare", "corsproxy", "allorigins", "cors-anywhere"]:
		if low.contains(w):
			bad.append(w)
	if bad.is_empty():
		_pass("llm/no-proxy-code")
	else:
		_fail("llm/no-proxy-code", "proxy-ish tokens present: " + ", ".join(bad))


func _check_no_threads() -> void:
	var files: Array = []
	_list_gd("res://scripts", files)
	if files.is_empty():
		_fail("nothreads/scan", "no .gd files found under res://scripts/")
		return
	var re := RegEx.new()
	re.compile("\\bThread\\b")
	var bad: Array = []
	for f in files:
		var code := _code(_read(f as String))
		if re.search(code) != null:
			bad.append(f)
	if bad.is_empty():
		_pass("nothreads/no-Thread-in-scripts (%d .gd files scanned)" % files.size())
	else:
		_fail("nothreads/no-Thread-in-scripts", "Thread token in code: " + ", ".join(bad))


func _initialize() -> void:
	print("VERIFY_WEB_PORT: source assertions for the Godot 4.7.2 web (nothreads) port")
	_check_export_preset()
	_check_touch_controls()
	_check_updater_gating()
	_check_speech_fallback()
	_check_multiplayer_gating()
	_check_llm_direct()
	_check_no_threads()
	print("VERIFY_WEB_PORT: %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
