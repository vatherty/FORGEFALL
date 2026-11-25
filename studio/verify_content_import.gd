extends SceneTree

func _initialize() -> void:
 var doc_script: GDScript = load("res://content_document.gd")
 var runtime_script: GDScript = load("res://content_runtime.gd")
 assert(doc_script != null and runtime_script != null)
 var data: Dictionary = doc_script.new_weapon("Import Check")
 assert(doc_script.validate(data) == "")
 var asset := Node3D.new()
 assert(runtime_script.decorate_asset(asset, {"animations": [{"name":"Open","keys":[{"time":0,"position":[0,0,0]},{"time":1,"position":[0,1,0]}]}]}) == "")
 assert(asset.get_node_or_null("AnimationPlayer") != null)
 asset.free()
 print("Studio content import: PASS")
 quit(0)
