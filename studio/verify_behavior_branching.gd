extends SceneTree

# Stage 4 branching + diagnostic-column checks:
# - a condition node taking both branches at runtime (bool and numeric tests)
# - invalid branch wiring / condition properties producing diagnostics
# - handwritten source diagnostics carrying line AND column to the editor caret
const Document = preload("res://behavior_document.gd")
const Compiler = preload("res://behavior_compiler.gd")
const Source = preload("res://behavior_source.gd")

func _initialize() -> void:
	call_deferred("_run")

func _branch_doc() -> Dictionary:
	var doc: Dictionary = Document.create("Branching")
	var trigger: Dictionary = Document.node("interact")
	var gate: Dictionary = Document.node("condition", {"target": ".", "property": "visible", "operator": "==", "value": true})
	var shown: Dictionary = Document.node("emit_event", {"name": "shown"})
	var after: Dictionary = Document.node("emit_event", {"name": "after_true"})
	var hidden: Dictionary = Document.node("emit_event", {"name": "hidden"})
	doc["nodes"] = [trigger, gate, shown, after, hidden]
	doc["edges"] = [
		{"from": trigger["id"], "to": gate["id"]},
		{"from": gate["id"], "to": shown["id"], "port": "true"},
		{"from": shown["id"], "to": after["id"]},
		{"from": gate["id"], "to": hidden["id"], "port": "false"},
	]
	doc["_ids"] = {"gate": gate["id"]}
	return doc

func _run() -> void:
	# --- valid branching graph: both branches at runtime -------------------
	var doc := _branch_doc()
	var gate_id := str(doc["_ids"]["gate"])
	doc.erase("_ids")
	assert(Document.validate(doc) == "")
	var compiled: Dictionary = Compiler.compile(doc)
	assert(compiled["error"] == "")
	var script := GDScript.new()
	script.source_code = compiled["source"]
	assert(script.reload() == OK)
	var node: Node3D = script.new()
	var events: Array[String] = []
	var steps: Array[String] = []
	node.behavior_event.connect(func(value: String) -> void: events.append(value))
	node.behavior_step.connect(func(value: String) -> void: steps.append(value))
	root.add_child(node)
	node.interact()
	assert(events == ["shown", "after_true"], "true branch + chained action: %s" % [events])
	assert(steps.has(gate_id))
	node.visible = false
	node.interact()
	assert(events == ["shown", "after_true", "hidden"], "false branch: %s" % [events])
	node.queue_free()

	# --- numeric ordering comparison against a child node's property -------
	var numeric: Dictionary = Document.create("Numeric Branch")
	var trigger2: Dictionary = Document.node("interact")
	var gate2: Dictionary = Document.node("condition", {"target": "Stats", "property": "health", "operator": ">", "value": 10.0})
	var strong: Dictionary = Document.node("emit_event", {"name": "strong"})
	var weak: Dictionary = Document.node("emit_event", {"name": "weak"})
	numeric["nodes"] = [trigger2, gate2, strong, weak]
	numeric["edges"] = [
		{"from": trigger2["id"], "to": gate2["id"]},
		{"from": gate2["id"], "to": strong["id"], "port": "true"},
		{"from": gate2["id"], "to": weak["id"], "port": "false"},
	]
	assert(Document.validate(numeric) == "")
	var numeric_script := GDScript.new()
	numeric_script.source_code = Compiler.compile(numeric)["source"]
	assert(numeric_script.reload() == OK)
	var numeric_node: Node3D = numeric_script.new()
	var numeric_events: Array[String] = []
	numeric_node.behavior_event.connect(func(value: String) -> void: numeric_events.append(value))
	var stats_script := GDScript.new()
	stats_script.source_code = "extends Node\nvar health := 30.0\n"
	assert(stats_script.reload() == OK)
	var stats: Node = stats_script.new()
	stats.name = "Stats"
	numeric_node.add_child(stats)
	root.add_child(numeric_node)
	numeric_node.interact()
	assert(numeric_events == ["strong"], "health 30 > 10: %s" % [numeric_events])
	stats.set("health", 5.0)
	numeric_node.interact()
	assert(numeric_events == ["strong", "weak"], "health 5 <= 10: %s" % [numeric_events])
	numeric_node.queue_free()

	# --- invalid branch wiring must produce diagnostics, not crashes -------
	var missing_port := _branch_doc()
	missing_port.erase("_ids")
	missing_port["edges"][1].erase("port")
	assert(not Document.validate(missing_port).is_empty(), "condition edge without a port label")
	assert(not Compiler.compile(missing_port)["error"].is_empty())
	var doubled := _branch_doc()
	doubled.erase("_ids")
	doubled["edges"][3]["port"] = "true"
	assert(not Document.validate(doubled).is_empty(), "two edges on the true output")
	var plain_port := _branch_doc()
	plain_port.erase("_ids")
	plain_port["edges"][0]["port"] = "true"
	assert(not Document.validate(plain_port).is_empty(), "port label on a plain node edge")
	var cyclic := _branch_doc()
	cyclic.erase("_ids")
	cyclic["edges"].append({"from": cyclic["nodes"][2]["id"], "to": cyclic["nodes"][1]["id"]})
	assert(not Document.validate(cyclic).is_empty(), "cycle running through a branch")
	var bad_operator := _branch_doc()
	bad_operator.erase("_ids")
	bad_operator["nodes"][1]["properties"]["operator"] = "==="
	assert(not Document.validate(bad_operator).is_empty(), "unknown comparison operator")
	var bad_value := _branch_doc()
	bad_value.erase("_ids")
	bad_value["nodes"][1]["properties"]["value"] = [1, 2]
	assert(not Document.validate(bad_value).is_empty(), "non-scalar comparison value")
	var bad_property := _branch_doc()
	bad_property.erase("_ids")
	bad_property["nodes"][1]["properties"]["property"] = "not a property!"
	assert(not Document.validate(bad_property).is_empty(), "non-identifier comparison property")

	# --- source diagnostics: line AND column -------------------------------
	var fixture := ProjectSettings.globalize_path("user://branch_fixture_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(fixture)
	var workspace = Source.new()
	assert(workspace.open_file(fixture, "scripts/check.gd") == "")
	var bad_source := "extends Node\nfunc f() -> void:\n\tvar x := undefined_identifier + 1\n"
	workspace.edit(bad_source)
	var diagnostic: Dictionary = workspace.diagnose()
	assert(not diagnostic["ok"])
	assert(int(diagnostic["line"]) == 3, "diagnostic line: %s" % [diagnostic])
	var expected_column: int = bad_source.split("\n")[2].find("undefined_identifier") + 1
	assert(expected_column > 1)
	assert(int(diagnostic["column"]) == expected_column, "diagnostic column %s, expected %d" % [diagnostic, expected_column])
	assert(str(diagnostic["message"]).contains("column %d" % expected_column))

	# --- editor: caret/selection lands on the column; graph shows ports ----
	var scene: PackedScene = load("res://behavior_workspace.tscn")
	var ui: Control = scene.instantiate()
	ui.project_path = fixture
	root.add_child(ui)
	ui.path_input.text = "scripts/check.gd"
	ui.open_source()
	ui.editor.text = bad_source
	ui.check_source()
	assert(ui.status.text.contains("line 3, column %d" % expected_column), "status: %s" % ui.status.text)
	assert(ui.editor.get_selection_from_line() == 2)
	assert(ui.editor.get_selection_from_column() == expected_column - 1, "selection starts at the diagnostic column")
	assert(ui.editor.get_selection_to_column() == bad_source.split("\n")[2].length())
	var graph_doc := _branch_doc()
	graph_doc.erase("_ids")
	ui.document = graph_doc
	ui._render_graph()
	var connections: Array = ui.graph.get_connection_list()
	assert(connections.size() == 4, "connections: %s" % [connections])
	var saw_false_port := false
	for connection in connections:
		if int(connection["from_port"]) == 1:
			saw_false_port = true
	assert(saw_false_port, "false branch rendered on output port 1")
	ui.queue_free()
	print("Branching test passed: condition branches at runtime, invalid wiring diagnostics, source line+column caret, graph ports")
	quit()
