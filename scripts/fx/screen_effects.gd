# Single screen-copy pass, after the 3D world and before every 2D menu/HUD.
# Hidden (including its BackBufferCopy) when off, at zero intensity, or outside a run.
extends CanvasLayer

const LOOK_NAMES := ["Bodycam", "Cinematic", "Retro CRT", "Monochrome", "Night vision"]
const PARAMETERS := {
	"lens_enabled": "effects_lens", "grain_enabled": "effects_grain",
	"vignette_enabled": "effects_vignette", "chromatic_enabled": "effects_chromatic",
	"scanlines_enabled": "effects_scanlines", "lightweight": "effects_lightweight",
}
var _rect: ColorRect
var _copy: BackBufferCopy
var _material: ShaderMaterial
var _enabled := false
var _strength := 0.65
var _player: Node

func _ready() -> void:
	layer = -1
	process_mode = Node.PROCESS_MODE_ALWAYS
	_copy = BackBufferCopy.new()
	_copy.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	add_child(_copy)
	_rect = ColorRect.new()
	_rect.name = "ScreenFilter"
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.focus_mode = Control.FOCUS_NONE
	_material = ShaderMaterial.new()
	_material.shader = preload("res://assets/shaders/screen_effects.gdshader")
	_rect.material = _material
	add_child(_rect)
	get_viewport().size_changed.connect(_resize)
	get_tree().node_added.connect(func(node: Node):
		if node.has_method("add_look"):
			_refresh_player.call_deferred())
	get_tree().node_removed.connect(func(node: Node):
		if node == _player:
			_player = null
			_refresh_player.call_deferred())
	configure(Preferences.values)
	_refresh_player()
	_resize()

func configure(values: Dictionary) -> void:
	if _material == null:
		return
	_enabled = bool(values.get("effects_enabled", false))
	_strength = clampf(float(values.get("effects_strength", 0.65)), 0.0, 1.0)
	_material.set_shader_parameter("look", clampi(int(values.get("effects_look", 0)), 0, LOOK_NAMES.size() - 1) + 1)
	_material.set_shader_parameter("strength", _strength)
	for uniform_name in PARAMETERS:
		_material.set_shader_parameter(uniform_name, bool(values.get(PARAMETERS[uniform_name], uniform_name != "chromatic_enabled")))
	_sync_visible()

func _refresh_player() -> void:
	_player = get_tree().get_first_node_in_group("player")
	_sync_visible()

func _sync_visible() -> void:
	var active := _enabled and _strength > 0.0 and is_instance_valid(_player)
	_rect.visible = active
	_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT if active else BackBufferCopy.COPY_MODE_DISABLED

func _resize() -> void:
	var size := get_viewport().get_visible_rect().size
	_material.set_shader_parameter("aspect", size.x / maxf(1.0, size.y))

func is_effect_active() -> bool:
	return _rect.visible
