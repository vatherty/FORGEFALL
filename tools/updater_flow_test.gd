# tools/updater_flow_test.gd — full updater state-machine test (needs a local
# update server; Tuning.UPDATE_BASE_URL is temporarily pointed at it).
# Drives: CHECKING -> AVAILABLE -> DOWNLOADING -> READY, then install_update()
# with no plugin (expects OS.shell_open path, no crash).
extends SceneTree

var _main: Node = null
var _frames := 0
var _updater: Node = null
var _log: Array = []


func _initialize() -> void:
	var ps := load("res://scenes/main.tscn") as PackedScene
	_main = ps.instantiate()
	root.add_child(_main)
	current_scene = _main
	print("UFLOW: booted")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 5:
		_updater = root.get_node_or_null("Updater")
		_updater.connect("state_changed", func(s: int) -> void: _log.append("state->%d" % s))
		_updater.connect("notice", func(m: String) -> void: _log.append("notice:%s" % m))
		print("UFLOW: base url: ", Tuning.UPDATE_BASE_URL)
		_updater.call("check_for_updates", true)
	if _frames == 120:
		# By now the check should have completed (local server, fast).
		print("UFLOW: state (4=AVAILABLE): ", _updater.get("state"))
		print("UFLOW: remote v", _updater.get("remote_version_name"), " code ", _updater.get("remote_version_code"))
		if int(_updater.get("state")) == 4:
			_updater.call("start_download")
		else:
			printerr("UFLOW: FAIL — never reached AVAILABLE; log: ", _log)
			return true
	if _frames == 400:
		var st := int(_updater.get("state"))
		print("UFLOW: state (6=READY): ", st)
		print("UFLOW: log: ", _log)
		if st == 6:
			print("UFLOW: DOWNLOAD->READY OK")
			_updater.call("install_update")  # no plugin: shell_open path, must not crash
			print("UFLOW: install_update (no-plugin) did not crash — OK")
		else:
			printerr("UFLOW: FAIL — never reached READY")
		return true
	return false
