# scripts/core/update_manager_pc.gd
# FORGEFALL — in-game PC auto-updater (autoload "UpdaterPC").
#
# Windows + Linux only. Mirrors the Android Updater's shape (same states,
# same launch-check timing, same dialog patterns) but ships a platform ZIP
# instead of an APK, because a running game cannot self-replace its own
# binary — on Windows the .exe is locked while it runs.
#
# Flow: CHECK version_pc.json -> DIALOG (Download / Later) -> DOWNLOAD the
# platform ZIP -> INSTALL: extract to a staging dir, write a helper script
# (update.bat / update.sh) that waits for THIS process to exit, copies the
# new files over the install dir, relaunches the game, and cleans up temp.
# The helper is launched, then the game quits. Nothing is silent: the user
# confirms at the dialog AND at INSTALL NOW.
#
# States: DISABLED -> IDLE -> CHECKING -> UP_TO_DATE | AVAILABLE
#          AVAILABLE -> DOWNLOADING -> READY -> (helper launched, game quits)
# Any failure -> ERROR. Failures are silent on the automatic boot check (a
# subtle line appears in Options); manual checks report visibly.
# Empty Tuning.UPDATE_BASE_URL disables the updater completely.
#
# ANDROID HANDOFF (why this file touches the Android manager without editing
# it): update_manager.gd is intentionally left byte-identical — its headless
# tests run on Linux and must keep passing, so no platform guard may live in
# that file. Instead, on Windows/Linux this manager parks the Android
# autoload in DISABLED (one assignment, before its deferred _auto_check
# runs) so it never auto-checks version.json or pops its APK dialog next
# to ours. main_menu routes manual checks to this manager on PC, so the
# Android manager is never invoked on Windows/Linux.
extends Node

signal state_changed(new_state: int)
signal download_progress(received_bytes: int, total_bytes: int)
signal notice(message: String)

enum State { DISABLED, IDLE, CHECKING, UP_TO_DATE, AVAILABLE, DOWNLOADING, READY, ERROR }

const VERSION_PC_JSON_PATH := "/version_pc.json"
const ZIP_FILENAME := "forgefall-update.zip"
const STAGING_DIRNAME := "staging"
const HELPER_BASENAME := "update"

var state: int = State.DISABLED
var remote_version_code := -1
var remote_version_name := ""
var remote_changelog := ""
var remote_download_url := ""
var last_error := ""

# Test hook: verify_updater_pc.gd sets this before add_child so _ready
# skips the live auto-check (no network in tests).
var suppress_auto_check := false

var _check_http: HTTPRequest
var _dl_http: HTTPRequest
var _manual := false
var _zip_path := ""
var _dialog: UpdateDialog = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not is_pc_platform() or Tuning.UPDATE_BASE_URL.is_empty():
		state = State.DISABLED
		return
	state = State.IDLE
	_hand_off_android_updater()
	_check_http = HTTPRequest.new()
	_check_http.timeout = Tuning.UPDATE_TIMEOUT_SEC
	add_child(_check_http)
	_check_http.request_completed.connect(_on_version_completed)
	_dl_http = HTTPRequest.new()
	_dl_http.timeout = 0  # downloads can take a while; the user can cancel
	add_child(_dl_http)
	_dl_http.request_completed.connect(_on_download_completed)
	if not suppress_auto_check:
		call_deferred("_auto_check")


func _process(_delta: float) -> void:
	if state == State.DOWNLOADING and _dialog != null and is_instance_valid(_dialog):
		var received := _dl_http.get_downloaded_bytes()
		var total := _dl_http.get_body_size()
		_dialog.update_progress(received, total)
		download_progress.emit(received, total)


## True only on the platforms this updater serves. Never true on Android.
static func is_pc_platform() -> bool:
	var os_name := OS.get_name()
	return os_name == "Windows" or os_name == "Linux"


## Installed version code of the running build. PC builds have no plugin,
## so this is the FALLBACK constant the export keeps in sync with the build.
func installed_version_code() -> int:
	return Tuning.FALLBACK_VERSION_CODE


## Picks the download URL for one platform out of a parsed manifest.
## Returns "" for unknown platforms and for manifests missing that key.
static func download_url_for(os_name: String, data: Dictionary) -> String:
	if os_name == "Windows":
		return str(data.get("windows_url", ""))
	if os_name == "Linux":
		return str(data.get("linux_url", ""))
	return ""


## Pure manifest parser (testable without network).
## Returns { ok, version_code, version_name, changelog, download_url, error }.
## The download URL is validated for THIS platform only — a manifest may
## legitimately omit the other platform's URL (e.g. a Windows-only hotfix).
static func parse_manifest(body: PackedByteArray, os_name: String) -> Dictionary:
	var out := {
		"ok": false,
		"version_code": -1,
		"version_name": "",
		"changelog": "",
		"download_url": "",
		"error": "",
	}
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		out["error"] = "bad version file"
		return out
	var d: Dictionary = data
	out["version_code"] = int(d.get("version_code", -1))
	out["version_name"] = str(d.get("version_name", ""))
	out["changelog"] = str(d.get("changelog", ""))
	out["download_url"] = download_url_for(os_name, d)
	if int(out["version_code"]) <= 0 or str(out["version_name"]).is_empty():
		out["error"] = "bad version file"
		return out
	if str(out["download_url"]).is_empty():
		out["error"] = "bad version file (no download URL for this platform)"
		return out
	out["ok"] = true
	return out


## Starts a version check. If an update is already known, just (re)shows the
## dialog when we're in the menu instead of re-fetching.
func check_for_updates(manual: bool) -> void:
	if state == State.DISABLED:
		if manual:
			notice.emit("Updates are not configured on this build.")
		return
	if state == State.CHECKING or state == State.DOWNLOADING:
		return
	if state == State.AVAILABLE or state == State.READY:
		if _in_menu():
			_ensure_dialog()
			_refresh_dialog()
		elif manual:
			notice.emit("Update v%s is ready — open the main menu to install." % remote_version_name)
		return
	_manual = manual
	_set_state(State.CHECKING)
	if manual:
		notice.emit("Checking for updates…")
	var err := _check_http.request(Tuning.UPDATE_BASE_URL + VERSION_PC_JSON_PATH)
	if err != OK:
		_fail("Could not start the update check.", manual)


func start_download() -> void:
	if state != State.AVAILABLE:
		return
	var dir := _updates_dir()
	if dir.is_empty():
		_fail("No writable updates directory.", true)
		return
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		_fail("Could not create the updates directory.", true)
		return
	_zip_path = dir.path_join(ZIP_FILENAME)
	if FileAccess.file_exists(_zip_path):
		DirAccess.remove_absolute(_zip_path)
	_dl_http.download_file = _zip_path
	_set_state(State.DOWNLOADING)
	_ensure_dialog()
	_dialog.show_downloading()
	notice.emit("Downloading update…")
	var err := _dl_http.request(remote_download_url)
	if err != OK:
		_fail("Download could not start.", true)


func cancel_download() -> void:
	if state != State.DOWNLOADING:
		return
	_dl_http.cancel()
	_cleanup_partial()
	_set_state(State.AVAILABLE)
	_ensure_dialog()
	_refresh_dialog()
	notice.emit("Download cancelled.")


func install_update() -> void:
	if state != State.READY:
		return
	var dir := _updates_dir()
	var staging := dir.path_join(STAGING_DIRNAME)
	if _zip_path.is_empty() or not FileAccess.file_exists(_zip_path):
		_ensure_dialog()
		_dialog.show_error("Downloaded file is missing. Please download the update again.")
		notice.emit("Downloaded file missing — please retry the download.")
		_set_state(State.AVAILABLE)
		return
	# Fresh staging dir, then extract the ZIP into it.
	DirAccess.remove_absolute(staging)
	if DirAccess.make_dir_recursive_absolute(staging) != OK:
		_fail_install("Could not create the staging directory.")
		return
	if not _extract_zip(_zip_path, staging):
		DirAccess.remove_absolute(staging)
		_fail_install("Could not extract the update package.")
		return
	# Helper script: waits for this process to exit, copies staging over
	# the install dir, relaunches, cleans up temp + itself.
	var install_dir := OS.get_executable_path().get_base_dir()
	var exe_name := OS.get_executable_path().get_file()
	var helper_name := HELPER_BASENAME + (".bat" if OS.get_name() == "Windows" else ".sh")
	var helper_path := dir.path_join(helper_name)
	var script_text := ""
	if OS.get_name() == "Windows":
		script_text = build_update_bat(install_dir, staging, _zip_path, exe_name, OS.get_process_id())
	else:
		script_text = build_update_sh(install_dir, staging, _zip_path, exe_name, OS.get_process_id())
	var f := FileAccess.open(helper_path, FileAccess.WRITE)
	if f == null:
		_fail_install("Could not write the update helper.")
		return
	f.store_string(script_text)
	f.close()
	# Launch the helper, then quit: the helper waits for our PID to exit
	# before touching the install dir (the .exe is locked until then).
	var pid := -1
	if OS.get_name() == "Windows":
		pid = OS.create_process("cmd", PackedStringArray(["/c", helper_path]))
	else:
		pid = OS.create_process("sh", PackedStringArray([helper_path]))
	if pid < 0:
		# FALLBACK (anti-drag): the update is already downloaded. Tell the
		# user exactly where it is and how to finish manually instead of
		# letting a helper-launch failure brick the whole updater.
		_ensure_dialog()
		_dialog.show_error(
			"Automatic install could not start.\nThe update is downloaded at:\n%s\nUnzip it over your install folder, then relaunch the game." % _zip_path)
		notice.emit("Automatic install could not start — update downloaded, install it manually.")
		return
	_ensure_dialog()
	_dialog.show_installing("Installing update — the game will restart…")
	notice.emit("Installing update — the game will restart.")
	get_tree().quit()


func _auto_check() -> void:
	if state == State.IDLE:
		check_for_updates(false)


func _on_version_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if state != State.CHECKING:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_fail("Update check unavailable (HTTP %d)." % response_code, _manual)
		return
	var parsed := parse_manifest(body, OS.get_name())
	if not bool(parsed["ok"]):
		_fail("Update check unavailable (%s)." % str(parsed["error"]), _manual)
		return
	remote_version_code = int(parsed["version_code"])
	remote_version_name = str(parsed["version_name"])
	remote_changelog = str(parsed["changelog"])
	remote_download_url = str(parsed["download_url"])
	if remote_version_code > installed_version_code():
		_set_state(State.AVAILABLE)
		notice.emit("Update available: v%s." % remote_version_name)
		if _manual or _in_menu():
			_ensure_dialog()
			_refresh_dialog()
	else:
		_set_state(State.UP_TO_DATE)
		if _manual:
			notice.emit("Already up to date (v%s)." % remote_version_name)


func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if state != State.DOWNLOADING:
		return
	if result != HTTPRequest.RESULT_SUCCESS or (response_code != 200 and response_code != 0):
		_cleanup_partial()
		_fail("Download failed (HTTP %d)." % response_code, true)
		return
	if not FileAccess.file_exists(_zip_path):
		_fail("Download finished but the file is missing.", true)
		return
	_set_state(State.READY)
	_ensure_dialog()
	_dialog.show_ready_pc()
	notice.emit("Update downloaded — ready to install.")


func _fail(msg: String, manual: bool) -> void:
	last_error = msg
	_set_state(State.ERROR)
	notice.emit(msg)
	if manual and _in_menu():
		_ensure_dialog()
		_dialog.show_error(msg)


func _fail_install(msg: String) -> void:
	last_error = msg
	_set_state(State.AVAILABLE)
	_ensure_dialog()
	_dialog.show_error(msg + "\nYou can download again from the menu.")
	notice.emit(msg)


func _cleanup_partial() -> void:
	if not _zip_path.is_empty() and FileAccess.file_exists(_zip_path):
		DirAccess.remove_absolute(_zip_path)


func _updates_dir() -> String:
	return OS.get_user_data_dir().path_join("updates")


## Parks the Android updater in DISABLED so it never auto-checks
## version.json or pops its APK dialog on PC. See the header comment.
## Both managers' enums put DISABLED at 0; the Android file is untouched.
func _hand_off_android_updater() -> void:
	var android_updater := get_node_or_null("/root/Updater")
	if android_updater != null:
		android_updater.set("state", State.DISABLED)


## The update dialog only ever auto-pops over the main menu, never mid-game.
func _in_menu() -> bool:
	var root := get_tree().get_first_node_in_group("game_root")
	if root == null:
		return true
	return int(root.get("state")) == 0  # main.gd State.MENU


func _set_state(s: int) -> void:
	state = s
	state_changed.emit(s)


func _ensure_dialog() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		return
	_dialog = UpdateDialog.new()
	add_child(_dialog)
	_dialog.update_pressed.connect(start_download)
	_dialog.later_pressed.connect(_dialog.hide_dialog)
	_dialog.cancel_pressed.connect(cancel_download)
	_dialog.install_pressed.connect(install_update)


func _refresh_dialog() -> void:
	if _dialog == null or not is_instance_valid(_dialog):
		return
	if state == State.AVAILABLE:
		_dialog.show_available(remote_version_name, remote_changelog)
	elif state == State.READY:
		_dialog.show_ready_pc()


## Extracts a ZIP into dest_dir (creates subdirs as needed). Rejects
## entries that would escape dest_dir (zip-slip: ".." or absolute paths).
## Returns false on any I/O failure.
static func _extract_zip(zip_path: String, dest_dir: String) -> bool:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return false
	for entry in reader.get_files():
		if entry.contains("..") or entry.begins_with("/") or entry.begins_with("\\"):
			reader.close()
			return false
		if entry.ends_with("/"):
			if DirAccess.make_dir_recursive_absolute(dest_dir.path_join(entry)) != OK:
				reader.close()
				return false
			continue
		var target := dest_dir.path_join(entry)
		if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
			reader.close()
			return false
		var data := reader.read_file(entry)
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			reader.close()
			return false
		out.store_buffer(data)
		out.close()
	reader.close()
	return true


## Builds the Windows helper script. All paths are baked in, double-quoted
## (paths with spaces work). Waits for GAME_PID to exit (up to 60 s),
## copies staging over the install dir, relaunches, cleans up temp + itself.
## Pure function — unit-tested by verify_updater_pc.gd.
static func build_update_bat(install_dir: String, staging_dir: String, zip_path: String, exe_name: String, game_pid: int) -> String:
	var lines: Array[String] = []
	lines.append("@echo off")
	lines.append("rem FORGEFALL self-update helper (generated by the game).")
	lines.append("rem Waits for the game process to exit, copies the new files")
	lines.append("rem over the install dir, relaunches, cleans up temp + itself.")
	lines.append("setlocal")
	lines.append("set \"INSTALL_DIR=%s\"" % install_dir)
	lines.append("set \"STAGING_DIR=%s\"" % staging_dir)
	lines.append("set \"ZIP_PATH=%s\"" % zip_path)
	lines.append("set \"EXE_NAME=%s\"" % exe_name)
	lines.append("set /a WAITED=0")
	lines.append(":waitloop")
	lines.append("tasklist /FI \"PID eq %d\" 2>nul | findstr /I \"%d\" >nul" % [game_pid, game_pid])
	lines.append("if errorlevel 1 goto copyfiles")
	lines.append("ping -n 2 127.0.0.1 >nul")
	lines.append("set /a WAITED+=1")
	lines.append("if %WAITED% GEQ 60 goto copyfiles")
	lines.append("goto waitloop")
	lines.append(":copyfiles")
	lines.append("xcopy /E /Y /Q \"%STAGING_DIR%\\*\" \"%INSTALL_DIR%\\\"")
	lines.append("start \"\" \"%INSTALL_DIR%\\%EXE_NAME%\"")
	lines.append("rmdir /S /Q \"%STAGING_DIR%\"")
	lines.append("del \"%ZIP_PATH%\"")
	lines.append("del \"%~f0\"")
	return "\n".join(lines) + "\n"


## Builds the Linux helper script. Same contract as build_update_bat.
## Launched via `sh update.sh` (no +x needed on the script itself);
## the game binary gets +x after the copy (ZIP extraction loses it).
## Pure function — unit-tested by verify_updater_pc.gd.
static func build_update_sh(install_dir: String, staging_dir: String, zip_path: String, exe_name: String, game_pid: int) -> String:
	var lines: Array[String] = []
	lines.append("#!/bin/sh")
	lines.append("# FORGEFALL self-update helper (generated by the game).")
	lines.append("# Waits for the game process to exit, copies the new files")
	lines.append("# over the install dir, relaunches, cleans up temp + itself.")
	lines.append("INSTALL_DIR=\"%s\"" % install_dir)
	lines.append("STAGING_DIR=\"%s\"" % staging_dir)
	lines.append("ZIP_PATH=\"%s\"" % zip_path)
	lines.append("EXE_NAME=\"%s\"" % exe_name)
	lines.append("GAME_PID=%d" % game_pid)
	lines.append("WAITED=0")
	lines.append("while kill -0 \"$GAME_PID\" 2>/dev/null; do")
	lines.append("  sleep 0.5")
	lines.append("  WAITED=$((WAITED + 1))")
	lines.append("  if [ \"$WAITED\" -ge 120 ]; then break; fi")
	lines.append("done")
	lines.append("cp -rf \"$STAGING_DIR\"/. \"$INSTALL_DIR\"/")
	lines.append("chmod +x \"$INSTALL_DIR/$EXE_NAME\"")
	lines.append("nohup \"$INSTALL_DIR/$EXE_NAME\" >/dev/null 2>&1 &")
	lines.append("rm -rf \"$STAGING_DIR\"")
	lines.append("rm -f \"$ZIP_PATH\"")
	lines.append("rm -- \"$0\"")
	return "\n".join(lines) + "\n"
