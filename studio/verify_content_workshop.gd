extends SceneTree

func _initialize() -> void:
 call_deferred("_run")

func _run() -> void:
 var workshop = load("res://content_workshop.tscn").instantiate()
 workshop.project_path = "/tmp/forgefall-content-workshop-ui"
 root.add_child(workshop)
 assert(workshop.preview_node != null)
 assert(workshop.part_select.item_count == 2)
 workshop.part_name.text = "Head"
 workshop.part_parent.text = "Body"
 workshop.part_values[0].value = 0
 workshop.part_values[1].value = 0.6
 workshop.part_values[2].value = 0
 workshop.part_values[3].value = 0.25
 workshop.part_values[4].value = 0.25
 workshop.part_values[5].value = 0.25
 workshop.part_select.select(-1)
 workshop._apply_part()
 var doc = JSON.parse_string(workshop.editor.text)
 assert(doc["parts"].size() == 3)
 assert(workshop.preview_node.get_node_or_null("Body/Head") != null)
 workshop._new("weapon")
 workshop.weapon_values[0].value = 22
 workshop._apply_weapon_fields()
 doc = JSON.parse_string(workshop.editor.text)
 assert(float(doc["damage"]) == 22.0)
 assert(workshop.preview_node.get_child_count() > 0)
 assert(workshop._save())
 var saved_path = load("res://content_document.gd").path(workshop.project_path, doc)
 workshop._new("character")
 workshop._open(saved_path)
 assert(float(JSON.parse_string(workshop.editor.text)["damage"]) == 22.0)
 DirAccess.remove_absolute(saved_path)
 var asset = load("res://shared/asset_document.gd").create("Lift")
 asset["voxels"] = [{"x":0,"y":0,"z":0,"material":0,"layer":0}]
 workshop.content_type = "asset"
 workshop.document = asset
 workshop.saved_text = ""
 workshop.editor.text = JSON.stringify(asset, "\t")
 workshop._sync_fields()
 workshop.timeline_name.text = "Open"
 workshop.offset_inputs[1].value = 2
 workshop._add_timeline()
 assert(workshop.preview_player != null)
 workshop._play_timeline()
 workshop._scrub_timeline(1.0)
 assert(absf(workshop.preview_player.get_parent().get_node("AnimatedBody").position.y - 2.0) < 0.01)
 root.remove_child(workshop)
 workshop.free()
 print("Content workshop visual authoring: PASS")
 quit(0)
