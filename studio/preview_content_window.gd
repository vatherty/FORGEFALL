extends SceneTree

func _initialize() -> void:
 call_deferred("_show")

func _show() -> void:
 DisplayServer.window_set_title("Forgefall Studio Content QA")
 DisplayServer.window_set_size(Vector2i(1280, 800))
 var workshop = load("res://content_workshop.tscn").instantiate()
 workshop.project_path = "/tmp/forgefall-studio-content-test"
 root.add_child(workshop)
 var args = OS.get_cmdline_user_args()
 if args.has("character"):
  workshop._new("character")
  return
 if args.has("weapon"):
  workshop._new("weapon")
  return
 if args.has("walk"):
  workshop.free()
  _show_walk()
  return
 var asset = load("res://shared/asset_document.gd").create("Lift Door")
 asset["voxels"] = []
 for x in range(-3, 4):
  for y in range(0, 13):
   for z in range(-1, 2):
    if x in [-3, 3] or y in [0, 12] or z in [-1, 1]:
     asset["voxels"].append({"x":x,"y":y,"z":z,"material":0,"layer":0})
 asset["animations"] = [{"name":"Open","keys":[{"time":0,"position":[0,0,0]},{"time":2,"position":[0,1.5,0]}]}]
 workshop.content_type = "asset"
 workshop.document = asset
 workshop.saved_text = ""
 workshop.editor.text = JSON.stringify(asset, "\t")
 workshop.timeline_name.text = "Open"
 workshop._sync_fields()
 workshop._refresh_title()
 workshop._refresh_preview()
 workshop._play_timeline()

# Walk-cycle QA: a full-rig character patrols between two waypoint markers
# on a plain floor so the procedural cycle and patrol AI can be eyeballed.
func _show_walk() -> void:
 DisplayServer.window_set_title("Forgefall Studio Character Walk QA")
 var world := Node3D.new()
 root.add_child(world)
 var environment := WorldEnvironment.new()
 environment.environment = Environment.new()
 environment.environment.background_mode = Environment.BG_COLOR
 environment.environment.background_color = Color("#293443")
 environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
 environment.environment.ambient_light_energy = 0.9
 world.add_child(environment)
 var light := DirectionalLight3D.new()
 light.rotation_degrees = Vector3(-50, -30, 0)
 world.add_child(light)
 var camera := Camera3D.new()
 camera.position = Vector3(4.5, 3.2, 6.5)
 world.add_child(camera)
 camera.look_at(Vector3(0, 0.8, 0))
 camera.current = true
 var floor_body := StaticBody3D.new()
 var floor_shape := CollisionShape3D.new()
 var floor_box := BoxShape3D.new()
 floor_box.size = Vector3(30, 1, 30)
 floor_shape.shape = floor_box
 floor_shape.position.y = -0.5
 floor_body.add_child(floor_shape)
 var floor_visual := MeshInstance3D.new()
 var floor_mesh := BoxMesh.new()
 floor_mesh.size = Vector3(30, 0.1, 30)
 floor_visual.mesh = floor_mesh
 floor_visual.position.y = -0.05
 floor_body.add_child(floor_visual)
 world.add_child(floor_body)
 for marker_data in [["WaypointA", Vector3(-5, 0, 0)], ["WaypointB", Vector3(5, 0, 0)]]:
  var marker := Marker3D.new()
  marker.name = marker_data[0]
  marker.position = marker_data[1]
  marker.add_to_group("waypoint")
  world.add_child(marker)
 var content = load("res://content_document.gd")
 var runtime = load("res://content_runtime.gd")
 var doc = content.new_character("Walker")
 doc["parts"] = [
  {"name": "Body", "parent": "", "position": [0.0, 0.95, 0.0], "size": [0.5, 0.7, 0.3], "color": "#8298a8"},
  {"name": "LegLeft", "parent": "", "position": [-0.15, 0.55, 0.0], "size": [0.18, 0.55, 0.2], "color": "#5a6a76", "limb": "leg_left"},
  {"name": "LegRight", "parent": "", "position": [0.15, 0.55, 0.0], "size": [0.18, 0.55, 0.2], "color": "#5a6a76", "limb": "leg_right"},
  {"name": "ArmLeft", "parent": "Body", "position": [-0.35, 0.25, 0.0], "size": [0.14, 0.5, 0.16], "color": "#8298a8"},
  {"name": "ArmRight", "parent": "Body", "position": [0.35, 0.25, 0.0], "size": [0.14, 0.5, 0.16], "color": "#8298a8"},
  {"name": "Hand", "parent": "Body", "position": [0.35, -0.2, -0.1], "size": [0.15, 0.15, 0.15], "color": "#d5b595"},
 ]
 var character = runtime.build_character(doc)
 character.position = Vector3(0, 0.1, 0)
 world.add_child(character)
