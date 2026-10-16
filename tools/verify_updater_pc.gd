# tools/verify_updater_pc.gd — verification for the FORGEFALL PC updater.
#
# Covers: manifest parsing + version compare (newer/equal/older/malformed/
# offline), dialog flow triggers, per-platform download URL selection,
# helper script generation (wait-for-exit, copy, relaunch, cleanup, paths
# with spaces), ZIP extraction (+ zip-slip rejection), the Android handoff
# (Android manager parked in DISABLED on PC), the Android updater file
# untouched, main-menu routing to the PC updater, and the v0.9.2 manifest
# file on disk.
#
# NO live network: version callbacks are fed fabricated bodies directly.
# The real autoloads' deferred checks may still attempt HTTPS in the
# background (harmless noise); all assertions here are offline.
#
# SPLIT: _initialize runs the pure/static tests. The tree-dependent tests
# (autoload states, callbacks that pop dialogs, menu routing) run on the
# first _process frame — during _initialize get_tree() is null and _ready
# has not run yet, so tree tests there would silently misfire.
#
# Usage: godot --headless --path <proj> --script res://tools/verify_updater_pc.gd
extends SceneTree

# PC updater State enum (mirrors update_manager_pc.gd).
const PC_DISABLED := 0
const PC_IDLE := 1
const PC_CHECKING := 2
const PC_UP_TO_DATE := 3
const PC_AVAILABLE := 4
const PC_DOWNLOADING := 5
const PC_READY := 6
const PC_ERROR := 7

var _pass := 0
var _fail := 0
var _test_dir := ""
var _pc_script: Script = null


func _check(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("PCUPD PASS: ", name)
	else:
		_fail += 1
		printerr("PCUPD FAIL: ", name)


func _json_bytes(s: String) -> PackedByteArray:
	return s.to_utf8_buffer()


func _manifest_body(code: int, win_url: String, lin_url: String) -> PackedByteArray:
	var d := {
		"version_code": code,
		"version_name": "9.9.%d" % code,
		"changelog": "test build",
	}
	if not win_url.is_empty():
		d["windows_url"] = win_url
	if not lin_url.is_empty():
		d["linux_url"] = lin_url
	return _json_bytes(JSON.stringify(d))


func _new_pc_manager() -> Node:
	var m: Node = _pc_script.new()
	m.set("suppress_auto_check", true)
	root.add_child(m)
	return m


func _initialize() -> void:
	_pc_script = load("res://scripts/core/update_manager_pc.gd")
	_test_dir = OS.get_user_data_dir().path_join("pc_updater_test")
	DirAccess.make_dir_recursive_absolute(_test_dir)

	# --- URL selection per platform ---
	_check("download_url_for Windows picks windows_url",
		_pc_script.call("download_url_for", "Windows", {"windows_url": "W", "linux_url": "L"}) == "W")
	_check("download_url_for Linux picks linux_url",
		_pc_script.call("download_url_for", "Linux", {"windows_url": "W", "linux_url": "L"}) == "L")
	_check("download_url_for Android returns empty",
		_pc_script.call("download_url_for", "Android", {"windows_url": "W", "linux_url": "L"}) == "")
	_check("download_url_for macOS returns empty",
		_pc_script.call("download_url_for", "macOS", {"windows_url": "W", "linux_url": "L"}) == "")
	_check("download_url_for missing key returns empty",
		_pc_script.call("download_url_for", "Linux", {"windows_url": "W"}) == "")

	# --- Manifest parsing ---
	var good: Dictionary = _pc_script.call("parse_manifest",
		_manifest_body(23, "https://x/win.zip", "https://x/lin.zip"), "Linux")
	_check("parse_manifest valid on Linux ok", bool(good["ok"]))
	_check("parse_manifest code 23", int(good["version_code"]) == 23)
	_check("parse_manifest Linux URL selected", str(good["download_url"]) == "https://x/lin.zip")
	var good_win: Dictionary = _pc_script.call("parse_manifest",
		_manifest_body(23, "https://x/win.zip", "https://x/lin.zip"), "Windows")
	_check("parse_manifest Windows URL selected", str(good_win["download_url"]) == "https://x/win.zip")
	var bad_json: Dictionary = _pc_script.call("parse_manifest", _json_bytes("{not json"), "Linux")
	_check("parse_manifest malformed JSON not ok", not bool(bad_json["ok"]))
	var no_code: Dictionary = _pc_script.call("parse_manifest",
		_json_bytes('{"version_name":"1.0","windows_url":"W","linux_url":"L"}'), "Linux")
	_check("parse_manifest missing version_code not ok", not bool(no_code["ok"]))
	var zero_code: Dictionary = _pc_script.call("parse_manifest",
		_manifest_body(0, "W", "L"), "Linux")
	_check("parse_manifest zero version_code not ok", not bool(zero_code["ok"]))
	var no_url: Dictionary = _pc_script.call("parse_manifest",
		_manifest_body(23, "https://x/win.zip", ""), "Linux")
	_check("parse_manifest missing THIS-platform URL not ok", not bool(no_url["ok"]))
	var win_only: Dictionary = _pc_script.call("parse_manifest",
		_manifest_body(23, "https://x/win.zip", ""), "Windows")
	_check("parse_manifest Windows-only manifest ok on Windows", bool(win_only["ok"]))

	# --- Helper script generation (paths with spaces) ---
	var inst := "C:/Games/My Game"
	var staging := "C:/Users/Test User/AppData/Roaming/Godot/app_userdata/FORGEFALL/updates/staging"
	var zip_p := "C:/Users/Test User/AppData/Roaming/Godot/app_userdata/FORGEFALL/updates/forgefall-update.zip"
	var bat: String = _pc_script.call("build_update_bat", inst, staging, zip_p, "forgefall.exe", 1234)
	_check("bat: install dir quoted", bat.contains("set \"INSTALL_DIR=C:/Games/My Game\""))
	_check("bat: staging dir quoted", bat.contains("set \"STAGING_DIR=" + staging + "\""))
	_check("bat: waits on game PID", bat.contains("PID eq 1234"))
	_check("bat: xcopy staging over install dir", bat.contains("xcopy /E /Y /Q"))
	_check("bat: relaunches exe", bat.contains("start \"\" \"%INSTALL_DIR%\\%EXE_NAME%\""))
	_check("bat: cleans staging + zip + self", bat.contains("rmdir /S /Q") and bat.contains("del \"%ZIP_PATH%\"") and bat.contains("del \"%~f0\""))

	var lin_inst := "/home/test user/games/forgefall"
	var lin_staging := "/home/test user/.local/share/godot/app_userdata/FORGEFALL/updates/staging"
	var lin_zip := "/home/test user/.local/share/godot/app_userdata/FORGEFALL/updates/forgefall-update.zip"
	var sh: String = _pc_script.call("build_update_sh", lin_inst, lin_staging, lin_zip, "forgefall.x86_64", 5678)
	_check("sh: install dir quoted", sh.contains("INSTALL_DIR=\"/home/test user/games/forgefall\""))
	_check("sh: staging dir quoted", sh.contains("STAGING_DIR=\"" + lin_staging + "\""))
	_check("sh: waits on game PID", sh.contains("GAME_PID=5678") and sh.contains("kill -0 \"$GAME_PID\""))
	_check("sh: copies staging over install dir", sh.contains("cp -rf \"$STAGING_DIR\"/. \"$INSTALL_DIR\"/"))
	_check("sh: chmod +x on binary", sh.contains("chmod +x \"$INSTALL_DIR/$EXE_NAME\""))
	_check("sh: relaunches binary detached", sh.contains("nohup \"$INSTALL_DIR/$EXE_NAME\""))
	_check("sh: cleans staging + zip + self", sh.contains("rm -rf \"$STAGING_DIR\"") and sh.contains("rm -f \"$ZIP_PATH\"") and sh.contains("rm -- \"$0\""))

	# --- ZIP extraction (+ zip-slip rejection) ---
	var zip_path := _test_dir.path_join("test.zip")
	var packer := ZIPPacker.new()
	_check("ZIPPacker opens test zip", packer.open(zip_path) == OK)
	packer.start_file("forgefall.exe")
	packer.write_file("EXEBYTES".to_utf8_buffer())
	packer.close_file()
	packer.start_file("sub/readme.txt")
	packer.write_file("HELLO".to_utf8_buffer())
	packer.close_file()
	packer.close()
	var dest := _test_dir.path_join("extracted")
	_check("extract valid zip ok", _pc_script.call("_extract_zip", zip_path, dest))
	_check("extracted exe content correct",
		FileAccess.get_file_as_string(dest.path_join("forgefall.exe")) == "EXEBYTES")
	_check("extracted nested file content correct",
		FileAccess.get_file_as_string(dest.path_join("sub/readme.txt")) == "HELLO")
	_check("extract missing zip fails", not bool(_pc_script.call("_extract_zip",
		_test_dir.path_join("nope.zip"), dest.path_join("x"))))
	var evil_zip := _test_dir.path_join("evil.zip")
	var ep := ZIPPacker.new()
	var evil_created := false
	if ep.open(evil_zip) == OK:
		ep.start_file("../evil.txt")
		ep.write_file("EVIL".to_utf8_buffer())
		ep.close_file()
		ep.close()
		evil_created = true
	if evil_created:
		var evil_dest := _test_dir.path_join("evil_out")
		_check("zip-slip entry rejected", not bool(_pc_script.call("_extract_zip", evil_zip, evil_dest)))
		_check("zip-slip file did not escape", not FileAccess.file_exists(_test_dir.path_join("evil.txt")))
	else:
		_check("zip-slip test zip could not be created (packer refused)", false)

	# --- Android updater file untouched ---
	var android_src := FileAccess.get_file_as_string("res://scripts/core/update_manager.gd")
	_check("Android updater has no UpdaterPC reference", not android_src.contains("UpdaterPC"))
	_check("Android updater has no version_pc reference", not android_src.contains("version_pc"))
	_check("Android updater has no PC helper reference", not android_src.contains("build_update_"))
	_check("Android updater still fetches version.json",
		android_src.contains("VERSION_JSON_PATH") and android_src.contains("/version.json"))
	_check("project.godot registers UpdaterPC autoload",
		FileAccess.get_file_as_string("res://project.godot").contains("UpdaterPC="))

	# --- version_pc.json manifest file ---
	var manifest_text := FileAccess.get_file_as_string("res://updates/version_pc.json")
	var manifest: Variant = JSON.parse_string(manifest_text)
	_check("version_pc.json parses", typeof(manifest) == TYPE_DICTIONARY)
	if typeof(manifest) == TYPE_DICTIONARY:
		var md: Dictionary = manifest
		_check("manifest version_code 37", int(md.get("version_code", -1)) == 37)
		_check("manifest version_name 0.5.11", str(md.get("version_name", "")) == "0.5.11")
		_check("manifest windows_url follows Pages naming",
			str(md.get("windows_url", "")).ends_with("forgefall-v0.5.11-windows.zip"))
		_check("manifest linux_url follows Pages naming",
			str(md.get("linux_url", "")).ends_with("forgefall-v0.5.11-linux.zip"))
		_check("manifest changelog non-empty", not str(md.get("changelog", "")).is_empty())


func _process(_delta: float) -> bool:
	# --- Autoloads present + handoff applied ---
	var android_autoload := root.get_node_or_null("Updater")
	var pc_autoload := root.get_node_or_null("UpdaterPC")
	_check("UpdaterPC autoload present", pc_autoload != null)
	_check("Updater autoload present", android_autoload != null)
	if pc_autoload != null:
		_check("PC manager is_pc_platform() true on this Linux VM", pc_autoload.call("is_pc_platform"))
		# The autoload may already be IDLE / CHECKING / ERROR by now
		# (its deferred auto-check fires on the first idle frame); the
		# property that matters is that it ACTIVATED on PC, not DISABLED.
		_check("PC manager activated on PC (not DISABLED)", int(pc_autoload.get("state")) != PC_DISABLED)
		_check("installed_version_code() == FALLBACK_VERSION_CODE",
			pc_autoload.call("installed_version_code") == Tuning.FALLBACK_VERSION_CODE)
	if android_autoload != null:
		_check("Android manager parked DISABLED on PC (handoff)", int(android_autoload.get("state")) == PC_DISABLED)

	# --- Version compare via the real callback (newer / equal / older) ---
	var m_new := _new_pc_manager()
	m_new.set("state", PC_CHECKING)
	m_new.call("_on_version_completed", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _manifest_body(99, "W", "L"))
	_check("newer version -> AVAILABLE", int(m_new.get("state")) == PC_AVAILABLE)
	_check("newer version -> remote code stored", int(m_new.get("remote_version_code")) == 99)
	var dlg_new: Node = m_new.get("_dialog")
	_check("newer version -> dialog created + visible",
		dlg_new != null and bool(dlg_new.get("visible")))
	if dlg_new != null:
		_check("newer version -> dialog title UPDATE AVAILABLE",
			str(dlg_new.get("_title").text) == "UPDATE AVAILABLE")
	m_new.free()

	var m_eq := _new_pc_manager()
	m_eq.set("state", PC_CHECKING)
	m_eq.call("_on_version_completed", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
		_manifest_body(Tuning.FALLBACK_VERSION_CODE, "W", "L"))
	_check("equal version -> UP_TO_DATE", int(m_eq.get("state")) == PC_UP_TO_DATE)
	m_eq.free()

	var m_old := _new_pc_manager()
	m_old.set("state", PC_CHECKING)
	m_old.call("_on_version_completed", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
		_manifest_body(1, "W", "L"))
	_check("older version -> UP_TO_DATE", int(m_old.get("state")) == PC_UP_TO_DATE)
	m_old.free()

	# --- Malformed / offline / HTTP error -> ERROR ---
	var m_bad := _new_pc_manager()
	m_bad.set("state", PC_CHECKING)
	m_bad.call("_on_version_completed", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _json_bytes("{bad"))
	_check("malformed manifest -> ERROR", int(m_bad.get("state")) == PC_ERROR)
	m_bad.free()

	var m_off := _new_pc_manager()
	m_off.set("state", PC_CHECKING)
	m_off.call("_on_version_completed", HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())
	_check("offline (cant connect) -> ERROR", int(m_off.get("state")) == PC_ERROR)
	m_off.free()

	var m_404 := _new_pc_manager()
	m_404.set("state", PC_CHECKING)
	m_404.call("_on_version_completed", HTTPRequest.RESULT_SUCCESS, 404, PackedStringArray(), PackedByteArray())
	_check("HTTP 404 -> ERROR", int(m_404.get("state")) == PC_ERROR)
	m_404.free()

	var m_man := _new_pc_manager()
	m_man.set("state", PC_CHECKING)
	m_man.set("_manual", true)
	m_man.call("_on_version_completed", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _json_bytes("{bad"))
	var dlg_man: Node = m_man.get("_dialog")
	_check("manual malformed -> ERROR + error dialog visible",
		int(m_man.get("state")) == PC_ERROR
		and dlg_man != null
		and bool(dlg_man.get("visible")))
	m_man.free()

	# --- Dialog PC-ready state ---
	var dlg := UpdateDialog.new()
	root.add_child(dlg)
	dlg.call("show_ready_pc")
	_check("show_ready_pc visible", bool(dlg.get("visible")))
	_check("show_ready_pc primary INSTALL NOW", str(dlg.get("_primary").text) == "INSTALL NOW")
	_check("show_ready_pc status mentions relaunch",
		str(dlg.get("_status").text).contains("relaunch"))
	dlg.free()

	# --- Main-menu routing: Options check goes to the PC updater on PC ---
	var menu_script: Script = load("res://scripts/ui/main_menu.gd")
	var menu: Control = menu_script.new()
	root.add_child(menu)
	var active: Node = menu.call("_active_updater")
	_check("main menu routes manual checks to UpdaterPC on Linux",
		active == pc_autoload)
	menu.free()

	_cleanup_test_dir()
	print("PCUPD SUMMARY: %d pass, %d fail" % [_pass, _fail])
	if _fail > 0:
		printerr("PCUPD: FAILURES PRESENT")
	return true  # quit


func _cleanup_test_dir() -> void:
	_delete_recursive(_test_dir)


func _delete_recursive(path: String) -> void:
	var da := DirAccess.open(path)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for d in da.get_directories():
		_delete_recursive(path.path_join(d))
	DirAccess.remove_absolute(path)
