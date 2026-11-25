extends SceneTree

const Document = preload("res://behavior_document.gd")
const Compiler = preload("res://behavior_compiler.gd")
const Source = preload("res://behavior_source.gd")
const Asset = preload("res://shared/asset_document.gd")
const Mesher = preload("res://shared/voxel_mesh.gd")
const ContentRuntime = preload("res://content_runtime.gd")

class DamageDummy:
	extends CharacterBody3D
	var total := 0.0
	func take_damage(amount: float, _hit_position: Vector3, _is_headshot: bool) -> void:
		total += amount

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for name in ["Animated Door", "Timed Lift", "Explosive Barrel"]:
		var doc: Dictionary = Document.template(name)
		assert(Document.validate(doc) == "")
		var result: Dictionary = Compiler.compile(doc)
		assert(result["error"] == "")
		var script := GDScript.new()
		script.source_code = result["source"]
		assert(script.reload() == OK)
	var live: Dictionary = Document.create("Runtime")
	var trigger: Dictionary = Document.node("ready")
	var emit: Dictionary = Document.node("emit_event", {"name": "started"})
	live["nodes"] = [trigger, emit]
	live["edges"] = [{"from": trigger["id"], "to": emit["id"]}]
	var live_source: Dictionary = Compiler.compile(live)
	var live_script := GDScript.new()
	live_script.source_code = live_source["source"]
	assert(live_script.reload() == OK)
	var live_node: Node3D = live_script.new()
	var events: Array[String] = []
	var steps: Array[String] = []
	var pauses: Array[String] = []
	live_node.debug_breakpoints.append(str(emit["id"]))
	live_node.behavior_step.connect(func(value: String) -> void: steps.append(value))
	live_node.behavior_paused.connect(func(value: String) -> void: pauses.append(value))
	live_node.behavior_event.connect(func(value: String) -> void: events.append(value))
	root.add_child(live_node)
	assert(steps == [str(emit["id"])])
	assert(pauses == [str(emit["id"])])
	assert(events.is_empty())
	live_node.resume_behavior()
	assert(events == ["started"])
	live_node.queue_free()
	var barrel: Dictionary = Document.template("Explosive Barrel")
	var barrel_script := GDScript.new()
	barrel_script.source_code = Compiler.compile(barrel)["source"]
	assert(barrel_script.reload() == OK)
	var barrel_node: Node3D = barrel_script.new()
	root.add_child(barrel_node)
	var dummy := DamageDummy.new()
	var dummy_shape := CollisionShape3D.new()
	dummy_shape.shape = SphereShape3D.new()
	dummy.add_child(dummy_shape)
	dummy.position = Vector3(1.0, 0.0, 0.0)
	root.add_child(dummy)
	await physics_frame
	barrel_node.interact()
	assert(is_equal_approx(dummy.total, 50.0))
	barrel_node.queue_free()
	dummy.queue_free()
	var published_asset: Dictionary = Asset.create("Behavior Door")
	published_asset["voxels"] = [{"x": 0, "y": 0, "z": 0, "material": 0, "layer": 0}]
	published_asset["animations"] = [{"name": "Open", "keys": [{"time": 0.0, "position": [0.0, 0.0, 0.0]}, {"time": 0.15, "position": [0.0, 1.0, 0.0]}]}]
	var asset_root: Node3D = Mesher.build_node(published_asset, true)
	assert(ContentRuntime.decorate_asset(asset_root, published_asset) == "")
	var asset_scene := PackedScene.new()
	assert(asset_scene.pack(asset_root) == OK)
	assert(ResourceSaver.save(asset_scene, "user://stage4_published_asset.tscn") == OK)
	asset_root.free()
	var door_script := GDScript.new()
	door_script.source_code = Compiler.compile(Document.template("Animated Door"))["source"]
	assert(door_script.reload() == OK)
	var door: Node3D = load("user://stage4_published_asset.tscn").instantiate()
	door.set_script(door_script)
	root.add_child(door)
	assert(door.get_node_or_null("AnimationPlayer") != null)
	door.interact()
	await create_timer(0.3).timeout
	assert(door.get_node("AnimatedBody").position.y > 0.9)
	assert(is_zero_approx(door.position.y))
	door.queue_free()
	var lift_doc: Dictionary = Document.template("Timed Lift")
	lift_doc["nodes"][0]["properties"]["seconds"] = 0.05
	lift_doc["nodes"][0]["properties"]["repeat"] = false
	var lift_script := GDScript.new()
	lift_script.source_code = Compiler.compile(lift_doc)["source"]
	assert(lift_script.reload() == OK)
	var lift: Node3D = load("user://stage4_published_asset.tscn").instantiate()
	lift.set_script(lift_script)
	root.add_child(lift)
	await create_timer(0.35).timeout
	assert(lift.get_node("AnimatedBody").position.y > 0.9)
	assert(is_zero_approx(lift.position.y))
	lift.queue_free()
	var broken: Dictionary = Document.template("Animated Door")
	broken["edges"].append({"from": broken["nodes"][1]["id"], "to": broken["nodes"][1]["id"]})
	assert(not Document.validate(broken).is_empty())
	var fixture := ProjectSettings.globalize_path("user://behavior_fixture_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(fixture)
	var published: Dictionary = Compiler.publish(fixture, Document.template("Animated Door"))
	assert(published["error"] == "")
	assert(FileAccess.file_exists(published["path"]))
	var workspace = Source.new()
	assert(workspace.open_file(fixture, "scripts/test.gd") == "")
	workspace.edit("extends Node\nfunc example() -> void:\n\tpass\n")
	assert(workspace.diagnose()["ok"])
	workspace.edit("extends Node\nfunc broken( -> void:\n\tpass\n")
	assert(not workspace.diagnose()["ok"])
	assert(workspace.diagnose()["line"] == 2)
	workspace.edit("extends Node\nfunc example() -> void:\n\tpass\n")
	assert(workspace.save() == "")
	workspace.edit("extends Node\nfunc example() -> void:\n\tprint(1)\n")
	var external := FileAccess.open(fixture.path_join("scripts/test.gd"), FileAccess.WRITE)
	external.store_string("extends Node\n# external\n")
	external.close()
	assert(not workspace.save().is_empty())
	var scene: PackedScene = load("res://behavior_workspace.tscn")
	var ui: Control = scene.instantiate()
	ui.project_path = fixture
	root.add_child(ui)
	ui.path_input.text = "scripts/repair.gd"
	ui.open_source()
	ui.editor.text = "extends Node\nfunc broken( -> void:\n\tpass\n"
	ui.check_source()
	assert(ui.status.text.contains("line 2"))
	assert(ui.editor.get_caret_line() == 1)
	ui.editor.text = "extends Node\nfunc repaired() -> void:\n\tpass\n"
	ui.check_source()
	assert(ui.status.text == "No parser errors.")
	ui.save_source()
	assert(ui.status.text == "GDScript saved.")
	assert(FileAccess.file_exists(fixture.path_join("scripts/repair.gd")))
	ui.load_template("Timed Lift")
	assert(ui.graph.get_child_count() > 0)
	assert(ui.graph.get_connection_list().size() == 1)
	ui.save_graph()
	assert(ui.status.text == "Behavior saved.")
	var saved_id: String = ui.document["id"]
	ui.load_template("Animated Door")
	ui.graph_id_input.text = saved_id
	ui.open_graph()
	assert(ui.document["id"] == saved_id)
	var graph_file := Document.path(fixture, saved_id)
	var changed := FileAccess.open(graph_file, FileAccess.WRITE)
	changed.store_string("{}\n")
	changed.close()
	ui.save_graph()
	assert(ui.status.text.contains("changed outside"))
	print("Behavior test passed: templates, compilation, validation, publication, source diagnostics/conflicts, editor")
	quit()
