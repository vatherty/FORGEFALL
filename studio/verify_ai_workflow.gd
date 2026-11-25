extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var editor: Control = load("res://main.tscn").instantiate()
	root.add_child(editor)
	editor._open_project(ProjectSettings.globalize_path("res://..").simplify_path())
	editor._new_map()
	if editor.map_doc.is_empty():
		push_error("AI integration needs an open Forgefall map")
		quit(1)
		return
	editor._open_ai_assistant()
	var assistant: Window = editor.get_node("AIProposals")
	if assistant == null:
		push_error("AI toolbar did not open assistant")
		quit(1)
		return
	assistant.response_edit.text = '{"actions":[{"type":"add_block","name":"AI preview","position":[1,0,2]}]}'
	assistant._preview()
	if assistant.apply_button.disabled or editor.map_doc["instances"].size() != 0:
		push_error("Preview mutated map or was not accepted")
		quit(1)
		return
	assistant._apply()
	if editor.map_doc["instances"].size() != 1:
		push_error("AI apply did not create block")
		quit(1)
		return
	editor._undo()
	if editor.map_doc["instances"].size() != 0:
		push_error("AI undo failed")
		quit(1)
		return
	editor._redo()
	if editor.map_doc["instances"].size() != 1:
		push_error("AI redo failed")
		quit(1)
		return
	print("PASS AI toolbar preview/apply/undo/redo")
	quit(0)
