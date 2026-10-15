# scripts/ui/update_dialog.gd
# FORGEFALL — update dialog, owned by the Updater autoload.
# Modal panel shown over the main menu only (never mid-gameplay):
#   AVAILABLE -> DOWNLOADING -> READY, plus ERROR and install-blocked states.
# Built in code with StencilStyle; touch + mouse friendly.
class_name UpdateDialog
extends CanvasLayer

signal update_pressed
signal later_pressed
signal cancel_pressed
signal install_pressed
signal open_settings_pressed

enum Mode { AVAILABLE, DOWNLOADING, READY, INSTALLING, ERROR, BLOCKED }

var _mode: int = Mode.AVAILABLE
var _title: Label
var _version_l: Label
var _changelog: Label
var _progress: ProgressBar
var _status: Label
var _primary: Button
var _secondary: Button
var _settings_btn: Button


func _ready() -> void:
	layer = 100
	_build()
	visible = false


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.65)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 0)
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_title)

	_version_l = Label.new()
	_version_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_version_l)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(600, 170)
	vb.add_child(scroll)
	_changelog = Label.new()
	StencilStyle.apply_body(_changelog, 18, StencilStyle.TEXT_DIM, 2)
	_changelog.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_changelog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_changelog)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(600, 26)
	_progress.show_percentage = false
	_progress.visible = false
	vb.add_child(_progress)

	_status = Label.new()
	StencilStyle.apply_body(_status, 18, StencilStyle.TEXT_DIM, 2)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_status)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	vb.add_child(row)

	_primary = _dlg_button("DOWNLOAD UPDATE")
	_primary.pressed.connect(_on_primary)
	row.add_child(_primary)
	_settings_btn = _dlg_button("OPEN SETTINGS")
	_settings_btn.visible = false
	_settings_btn.pressed.connect(func() -> void: open_settings_pressed.emit())
	row.add_child(_settings_btn)
	_secondary = _dlg_button("LATER")
	_secondary.pressed.connect(_on_secondary)
	row.add_child(_secondary)

	# Static title/version styling; per-state methods only change colors.
	StencilStyle.apply_title(_title, 34, StencilStyle.ORANGE, 4)
	StencilStyle.apply_body(_version_l, 22, StencilStyle.TEXT, 3)


func _dlg_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(220, 58)
	StencilStyle.style_button(b)
	b.add_theme_font_size_override("font_size", 20)
	return b


func show_available(version_name: String, changelog: String) -> void:
	_mode = Mode.AVAILABLE
	_title.text = "UPDATE AVAILABLE"
	StencilStyle.apply_title(_title, 34, StencilStyle.ORANGE, 4)
	_version_l.text = "v" + version_name
	_version_l.visible = true
	_changelog.text = changelog if not changelog.is_empty() else "A new build is ready."
	_progress.visible = false
	_status.text = ""
	_primary.text = "DOWNLOAD UPDATE"
	_primary.visible = true
	_secondary.text = "LATER"
	_secondary.visible = true
	_settings_btn.visible = false
	visible = true


func show_downloading() -> void:
	_mode = Mode.DOWNLOADING
	_title.text = "DOWNLOADING UPDATE"
	StencilStyle.apply_title(_title, 34, StencilStyle.ORANGE, 4)
	_progress.visible = true
	_progress.max_value = 100.0
	_progress.value = 0.0
	_status.text = "starting…"
	_primary.visible = false
	_settings_btn.visible = false
	_secondary.text = "CANCEL"
	_secondary.visible = true
	visible = true


func update_progress(received: int, total: int) -> void:
	if _mode != Mode.DOWNLOADING:
		return
	if total > 0:
		_progress.max_value = float(total)
		_progress.value = float(received)
		_status.text = "%s / %s" % [_fmt_mb(received), _fmt_mb(total)]
	else:
		_status.text = "%s downloaded…" % _fmt_mb(received)


func show_ready(via_plugin: bool) -> void:
	_mode = Mode.READY
	_title.text = "UPDATE READY"
	StencilStyle.apply_title(_title, 34, StencilStyle.GREEN, 4)
	_progress.visible = true
	_progress.max_value = 1.0
	_progress.value = 1.0
	if via_plugin:
		_status.text = "Tap INSTALL NOW — the system installer will open."
	else:
		_status.text = "No installer plugin on this build — the APK will open in your browser."
	_primary.text = "INSTALL NOW"
	_primary.visible = true
	_secondary.text = "LATER"
	_secondary.visible = true
	_settings_btn.visible = false
	visible = true


## PC variant of show_ready: the update is a downloaded ZIP, and INSTALL NOW
## hands it to the update helper (close, copy over the install dir,
## relaunch) instead of the Android installer. Added for the PC updater;
## the Android path above is untouched.
func show_ready_pc() -> void:
	_mode = Mode.READY
	_title.text = "UPDATE READY"
	StencilStyle.apply_title(_title, 34, StencilStyle.GREEN, 4)
	_progress.visible = true
	_progress.max_value = 1.0
	_progress.value = 1.0
	_status.text = "Tap INSTALL NOW — the game will close, install the update, and relaunch."
	_primary.text = "INSTALL NOW"
	_primary.visible = true
	_secondary.text = "LATER"
	_secondary.visible = true
	_settings_btn.visible = false
	visible = true


func show_install_blocked() -> void:
	_mode = Mode.BLOCKED
	_status.text = "“Install unknown apps” is off for FORGEFALL. Open Settings, allow it, then tap INSTALL NOW."
	_settings_btn.visible = true
	visible = true


func show_installing(status_text: String) -> void:
	_mode = Mode.INSTALLING
	_title.text = "INSTALLING UPDATE"
	StencilStyle.apply_title(_title, 34, StencilStyle.ORANGE, 4)
	_progress.visible = false
	_status.text = status_text
	_primary.visible = false
	_secondary.visible = false
	_settings_btn.visible = false
	visible = true


func set_install_status(status_text: String) -> void:
	if _mode != Mode.INSTALLING:
		show_installing(status_text)
		return
	_status.text = status_text


func show_error(msg: String) -> void:
	_mode = Mode.ERROR
	_title.text = "UPDATE FAILED"
	StencilStyle.apply_title(_title, 34, StencilStyle.RED, 4)
	_version_l.visible = false
	_changelog.text = ""
	_progress.visible = false
	_status.text = msg
	_primary.visible = false
	_settings_btn.visible = false
	_secondary.text = "CLOSE"
	_secondary.visible = true
	visible = true


func hide_dialog() -> void:
	visible = false


func _on_primary() -> void:
	match _mode:
		Mode.AVAILABLE:
			update_pressed.emit()
		Mode.READY, Mode.BLOCKED:
			install_pressed.emit()


func _on_secondary() -> void:
	match _mode:
		Mode.DOWNLOADING:
			cancel_pressed.emit()
		_:
			later_pressed.emit()


func _fmt_mb(bytes: int) -> String:
	return "%.1f MB" % (float(bytes) / 1048576.0)
