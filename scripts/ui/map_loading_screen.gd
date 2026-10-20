# res://scripts/ui/map_loading_screen.gd
# FORGEFALL — Map loading screen (deploy diagnostics).
#
# Shown by Main during EVERY deploy (menu -> match): map/scene loading,
# spawn-in, waves, mode start. Real staged progress, not a fake bar:
# Main sets a stage label + overall progress BEFORE doing that stage's
# (possibly blocking) work, yielding frames so the screen paints first.
# If a stage hangs, the label names exactly where the deploy is stuck.
#
# Proof-of-life: the stage label animates an ellipsis while frames are
# pumping, so a frozen label + frozen dots = the main thread is blocked
# inside the NAMED stage; a live label with animating dots = between
# stages. Either way Colin can see where it is.
#
# Test hook: hang_at_stage — when Main reaches that stage id it stalls
# there (verify_deploy_loading uses it to prove the diagnostic works).
class_name MapLoadingScreen
extends CanvasLayer

signal stage_changed(stage_id: String)

## Test-only: stage id at which the deploy runner should stall.
var hang_at_stage := ""

var _title: Label
var _subtitle: Label
var _stage_label: Label
var _bar: ProgressBar
var _stage_text := ""
var _failed := false
var _dot_t := 0.0
var current_stage := ""


func _ready() -> void:
	layer = 90
	var bg := ColorRect.new()
	bg.name = "LoadingBG"
	bg.color = Color(0.015, 0.015, 0.025, 0.97)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.name = "LoadingBox"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)

	_title = Label.new()
	_title.text = "DEPLOYING"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_title(_title, 54, StencilStyle.ORANGE, 6)
	box.add_child(_title)

	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 22)
	_subtitle.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	box.add_child(_subtitle)

	_stage_label = Label.new()
	_stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stage_label.add_theme_font_size_override("font_size", 26)
	_stage_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_stage_label.custom_minimum_size = Vector2(560, 40)
	box.add_child(_stage_label)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(480, 20)
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.value = 0.0
	_bar.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = StencilStyle.ORANGE
	fill.corner_radius_top_left = 4
	fill.corner_radius_top_right = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4
	_bar.add_theme_stylebox_override("fill", fill)
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = Color(0.12, 0.12, 0.15)
	bg_sb.corner_radius_top_left = 4
	bg_sb.corner_radius_top_right = 4
	bg_sb.corner_radius_bottom_left = 4
	bg_sb.corner_radius_bottom_right = 4
	_bar.add_theme_stylebox_override("background", bg_sb)
	var wrap := CenterContainer.new()
	wrap.add_child(_bar)
	box.add_child(wrap)


func _process(delta: float) -> void:
	if _failed:
		return
	# Proof-of-life ellipsis: animates only while frames pump.
	_dot_t += delta
	var dots := ""
	for i in (int(_dot_t * 2.5) % 4):
		dots += "."
	if is_instance_valid(_stage_label):
		_stage_label.text = _stage_text + dots


## Map/mode line under the title, e.g. "DUSTLINE — TOWER DEFENSE".
func setup(subtitle: String) -> void:
	if is_instance_valid(_subtitle):
		_subtitle.text = subtitle.to_upper()


## Reports a stage BEFORE its work runs. Progress is 0..1 overall.
func set_stage(stage_id: String, label: String, progress: float) -> void:
	current_stage = stage_id
	_stage_text = label
	_failed = false
	if is_instance_valid(_bar):
		_bar.value = clampf(progress, 0.0, 1.0) * 100.0
	if is_instance_valid(_stage_label):
		_stage_label.text = label
	stage_changed.emit(stage_id)


## Current stage label (test/diagnostic read).
func current_label() -> String:
	return _stage_text


## A stage failed: show the error in red, stop the dots.
func set_failed(message: String) -> void:
	_failed = true
	_stage_text = message
	if is_instance_valid(_stage_label):
		_stage_label.text = message
		_stage_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))


## Deploy finished: brief "Ready", then fade out and free.
func set_ready() -> void:
	_stage_text = "Ready"
	_failed = false
	if is_instance_valid(_bar):
		_bar.value = 100.0
	if is_instance_valid(_stage_label):
		_stage_label.text = "Ready"
		_stage_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))
	await get_tree().create_timer(0.45).timeout
	# CanvasLayer has no modulate of its own — the "Ready" beat above
	# is the confirmation; just leave.
	queue_free()


## Immediate teardown (failure path, quit_to_menu).
func dismiss() -> void:
	queue_free()
