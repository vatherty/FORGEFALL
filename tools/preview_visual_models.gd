## Runtime render check for an enemy body and its equipped weapon.
## Usage: godot --path . --script res://tools/preview_visual_models.gd -- grunt
extends SceneTree

var _frames := 0
var _soldier: Node3D

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var type_id := args[0] if not args.is_empty() else "grunt"
	root.size = Vector2i(960, 720)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.12, 0.14, 0.16)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.8, 0.85, 0.9)
	settings.ambient_light_energy = 0.65
	env.environment = settings
	world.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, -30, 0)
	light.light_energy = 1.8
	world.add_child(light)
	_soldier = load("res://scripts/enemies/voxel_soldier.gd").new()
	world.add_child(_soldier)
	_soldier.call("build", type_id)
	_soldier.call("animate_full", 1.0, {"speed": 0.0, "aiming": true})
	var camera := Camera3D.new()
	camera.fov = 40
	camera.look_at_from_position(Vector3(2.8, 2.05, -3.3), Vector3(0, 1.0, -0.05))
	world.add_child(camera)
	camera.current = true

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 20:
		return false
	var args := OS.get_cmdline_user_args()
	var type_id := args[0] if not args.is_empty() else "grunt"
	var path := "res://qa/runtime_%s.png" % type_id
	var err := root.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	if err != OK:
		printerr("Runtime preview save failed: ", err)
		quit(1)
	else:
		print("Runtime preview saved: ", path)
		quit()
	return true
