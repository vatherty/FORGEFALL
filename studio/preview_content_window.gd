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
