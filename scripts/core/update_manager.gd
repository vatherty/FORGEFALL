# scripts/core/update_manager.gd
# FORGEFALL — in-game APK auto-updater (autoload "Updater").
#
# Checks version.json on the update server at boot (async, 8s timeout, never
# blocks the menu) and walks the player through download + install.
# States: DISABLED -> IDLE -> CHECKING -> UP_TO_DATE | AVAILABLE
#          AVAILABLE -> DOWNLOADING -> READY -> (installer launched)
# Any failure -> ERROR. Failures are silent on the automatic boot check (a
# subtle line appears in Options); manual checks report visibly.
# Empty Tuning.UPDATE_BASE_URL disables the updater completely.
#
# Android install path uses the ForgeUpdater plugin (PackageInstaller session API
# + REQUEST_INSTALL_PACKAGES, see addons/ForgeUpdater). With the plugin, tapping
# INSTALL NOW streams the APK into a PackageInstaller session and the system shows
# one native "Install update?" dialog — in-app, no browser detour. (Truly silent
# install is impossible for a sideloaded app; USER_ACTION_REQUIRED is mandatory.)
# Without the plugin (desktop/editor builds) the manager degrades gracefully: the
# installed version comes from Tuning.FALLBACK_VERSION_CODE and "install" opens the
# APK URL in the browser instead.
extends Node

signal state_changed(new_state: int)
signal download_progress(received_bytes: int, total_bytes: int)
signal notice(message: String)

enum State { DISABLED, IDLE, CHECKING, UP_TO_DATE, AVAILABLE, DOWNLOADING, READY, ERROR }

const PLUGIN_NAME := "ForgeUpdater"
const VERSION_JSON_PATH := "/version.json"
const APK_FILENAME := "forgefall-update.apk"

var state: int = State.DISABLED
var remote_version_code := -1
var remote_version_name := ""
var remote_changelog := ""
var remote_apk_url := ""
var last_error := ""

var _check_http: HTTPRequest
var _dl_http: HTTPRequest
var _manual := false
var _apk_path := ""
var _dialog: UpdateDialog = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if Tuning.UPDATE_BASE_URL.is_empty():
		state = State.DISABLED
		return
	state = State.IDLE
	_check_http = HTTPRequest.new()
	_check_http.timeout = Tuning.UPDATE_TIMEOUT_SEC
	add_child(_check_http)
	_check_http.request_completed.connect(_on_version_completed)
	_dl_http = HTTPRequest.new()
	_dl_http.timeout = 0  # downloads can take a while; the user can cancel
	add_child(_dl_http)
	_dl_http.request_completed.connect(_on_download_completed)
	call_deferred("_auto_check")


func _process(_delta: float) -> void:
	if state == State.DOWNLOADING and _dialog != null and is_instance_valid(_dialog):
		var received := _dl_http.get_downloaded_bytes()
		var total := _dl_http.get_body_size()
		_dialog.update_progress(received, total)
		download_progress.emit(received, total)


func has_plugin() -> bool:
	return Engine.has_singleton(PLUGIN_NAME)


func installed_version_code() -> int:
	if has_plugin():
		var code := int(Engine.get_singleton(PLUGIN_NAME).call("getVersionCode"))
		if code > 0:
			return code
	return Tuning.FALLBACK_VERSION_CODE


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
	var err := _check_http.request(Tuning.UPDATE_BASE_URL + VERSION_JSON_PATH)
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
	_apk_path = dir.path_join(APK_FILENAME)
	if FileAccess.file_exists(_apk_path):
		DirAccess.remove_absolute(_apk_path)
	_dl_http.download_file = _apk_path
	_set_state(State.DOWNLOADING)
	_ensure_dialog()
	_dialog.show_downloading()
	notice.emit("Downloading update…")
	var err := _dl_http.request(remote_apk_url)
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
	if has_plugin():
		var p := Engine.get_singleton(PLUGIN_NAME)
		if not bool(p.call("canInstallUnknown")):
			_ensure_dialog()
			_dialog.show_install_blocked()
			notice.emit("Allow “install unknown apps”, then tap INSTALL NOW again.")
			return
		if _apk_path.is_empty() or not FileAccess.file_exists(_apk_path):
			_ensure_dialog()
			_dialog.show_error("Downloaded file is missing. Please download the update again.")
			notice.emit("Downloaded file missing — please retry the download.")
			_set_state(State.AVAILABLE)
			return
		p.call("installApk", _apk_path)
		_ensure_dialog()
		_dialog.show_installing("Handing the update to Android…")
		notice.emit("Launching installer…")
		_start_install_poll()
	else:
		# No plugin (desktop/editor, or VM builds without the Gradle export):
		# hand the URL to the browser and get out of the way.
		OS.shell_open(remote_apk_url)
		notice.emit("Opened the APK in your browser — install it from the download.")
		_ensure_dialog()
		_dialog.hide_dialog()


## Polls the plugin's install state machine so failures are visible in the
## dialog instead of dying silently in logcat. Stops on terminal states.
var _install_poll: Timer = null

func _start_install_poll() -> void:
	_stop_install_poll()
	_install_poll = Timer.new()
	_install_poll.wait_time = 0.5
	_install_poll.timeout.connect(_poll_install_state)
	add_child(_install_poll)
	_install_poll.start()
	_poll_install_state()

func _stop_install_poll() -> void:
	if _install_poll != null and is_instance_valid(_install_poll):
		_install_poll.stop()
		_install_poll.queue_free()
	_install_poll = null

func _poll_install_state() -> void:
	if not has_plugin():
		_stop_install_poll()
		return
	var p := Engine.get_singleton(PLUGIN_NAME)
	var st := str(p.call("getInstallState"))
	var detail := str(p.call("getInstallDetail"))
	match st:
		"starting", "creating_session":
			_dialog.set_install_status("Preparing the install…")
		"streaming":
			_dialog.set_install_status("Writing update package…")
		"committed":
			_dialog.set_install_status("Waiting for the system installer…")
		"user_action":
			_dialog.set_install_status("Confirm the install in the system dialog.")
			_stop_install_poll()
		"success":
			_stop_install_poll()
			notice.emit("Update installed.")
			_dialog.hide_dialog()
		"failed":
			_stop_install_poll()
			var msg := "Install failed."
			if not detail.is_empty():
				msg += "\n" + detail
			msg += "\nYou can also install manually from the download."
			_dialog.show_error(msg)
			notice.emit("Install failed: " + detail)
		"idle":
			pass  # installApk hasn't started its thread yet; keep polling


func open_install_settings() -> void:
	if has_plugin():
		Engine.get_singleton(PLUGIN_NAME).call("openUnknownSourcesSettings")


func _auto_check() -> void:
	if state == State.IDLE:
		check_for_updates(false)


func _on_version_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if state != State.CHECKING:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_fail("Update check unavailable (HTTP %d)." % response_code, _manual)
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		_fail("Update check unavailable (bad version file).", _manual)
		return
	var d: Dictionary = data
	remote_version_code = int(d.get("version_code", -1))
	remote_version_name = str(d.get("version_name", ""))
	remote_changelog = str(d.get("changelog", ""))
	remote_apk_url = str(d.get("apk_url", ""))
	if remote_version_code <= 0 or remote_apk_url.is_empty():
		_fail("Update check unavailable (bad version file).", _manual)
		return
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
	if not FileAccess.file_exists(_apk_path):
		_fail("Download finished but the file is missing.", true)
		return
	_set_state(State.READY)
	_ensure_dialog()
	_dialog.show_ready(has_plugin())
	notice.emit("Update downloaded — ready to install.")


func _fail(msg: String, manual: bool) -> void:
	last_error = msg
	_set_state(State.ERROR)
	notice.emit(msg)
	if manual and _in_menu():
		_ensure_dialog()
		_dialog.show_error(msg)


func _cleanup_partial() -> void:
	if not _apk_path.is_empty() and FileAccess.file_exists(_apk_path):
		DirAccess.remove_absolute(_apk_path)


func _updates_dir() -> String:
	if has_plugin():
		var d := str(Engine.get_singleton(PLUGIN_NAME).call("getUpdatesDir"))
		if not d.is_empty():
			return d
	return OS.get_user_data_dir().path_join("updates")


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
	_dialog.open_settings_pressed.connect(open_install_settings)


func _refresh_dialog() -> void:
	if _dialog == null or not is_instance_valid(_dialog):
		return
	if state == State.AVAILABLE:
		_dialog.show_available(remote_version_name, remote_changelog)
	elif state == State.READY:
		_dialog.show_ready(has_plugin())
