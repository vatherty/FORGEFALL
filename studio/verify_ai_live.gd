extends SceneTree
## verify_ai_live.gd — Stage 6 gate: LIVE external AI provider round trip.
##
## Requires the DeepSeek adapter (studio_ai_adapter.py) running on
## 127.0.0.1:8771. If it is not reachable this prints a clear SKIP and
## exits 0 without failing. When reachable, this drives the REAL Studio
## code path: main editor -> AIProposals window -> HTTPRequest to the
## adapter -> DeepSeek -> ai_proposals.gd validation -> preview -> apply,
## for two different prompts, and asserts the map actually changed.

const Store = preload("res://shared/document_store.gd")
const ENDPOINT := "http://127.0.0.1:8771/"

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not await _adapter_reachable():
		print("SKIP AI live: adapter not reachable at " + ENDPOINT + " — start studio_ai_adapter.py first; live provider not exercised.")
		quit(0)
		return
	print("LIVE adapter reachable at " + ENDPOINT)

	var editor: Control = load("res://main.tscn").instantiate()
	root.add_child(editor)
	editor._open_project(ProjectSettings.globalize_path("res://..").simplify_path())
	editor._new_map()
	if editor.map_doc.is_empty():
		_fail("could not create a map")
		quit(1)
		return
	# Seed one existing block so prompt 2 must resolve a real instance ID.
	var seed: Dictionary = Store.new_instance("OldCrate", Vector3.ZERO)
	editor.map_doc["instances"].append(seed)

	editor._open_ai_assistant()
	var assistant: Window = editor.get_node("AIProposals")
	if assistant == null:
		_fail("AI assistant window did not open")
		quit(1)
		return
	assistant.endpoint_edit.text = ENDPOINT

	# --- Round trip 1: add_block -------------------------------------------
	var prompt1 := "add a red block named Crate at position [2, 1, 2]"
	if not await _round_trip(assistant, prompt1):
		_fail("round trip 1 preview failed for prompt: " + prompt1)
		quit(1)
		return
	assistant._apply()
	var crate: Variant = _find_by_name(editor.map_doc, "Crate")
	_check(crate != null, "round trip 1: block 'Crate' exists after apply")
	if crate != null:
		_check(str(crate.get("color", "")).to_lower() == "#ff0000", "round trip 1: Crate color is #ff0000 (got %s)" % str(crate.get("color", "")))
		_check(_pos_matches(crate.get("position", []), Vector3(2, 1, 2)), "round trip 1: Crate at [2,1,2] (got %s)" % str(crate.get("position", [])))
	print("PASS AI live round trip 1 (add_block via DeepSeek): " + prompt1)

	# --- Round trip 2: rename + move an existing instance ------------------
	var prompt2 := "rename the block named OldCrate to SupplyCache and move it to position [4, 0, 4]"
	if not await _round_trip(assistant, prompt2):
		_fail("round trip 2 preview failed for prompt: " + prompt2)
		quit(1)
		return
	assistant._apply()
	var moved: Variant = _find_by_name(editor.map_doc, "SupplyCache")
	_check(moved != null, "round trip 2: block renamed to 'SupplyCache'")
	if moved != null:
		_check(str(moved.get("id", "")) == str(seed["id"]), "round trip 2: rename kept the same instance ID")
		_check(_pos_matches(moved.get("position", []), Vector3(4, 0, 4)), "round trip 2: SupplyCache at [4,0,4] (got %s)" % str(moved.get("position", [])))
	_check(_find_by_name(editor.map_doc, "OldCrate") == null, "round trip 2: old name gone")
	print("PASS AI live round trip 2 (rename+move via DeepSeek): " + prompt2)

	if failures == 0:
		print("PASS AI live provider round trip (DeepSeek via adapter, Studio validation + apply)")
		quit(0)
	else:
		quit(1)

func _adapter_reachable() -> bool:
	var http := HTTPRequest.new()
	http.timeout = 5
	root.add_child(http)
	var state := {"done": false, "ok": false}
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		state["done"] = true
		state["ok"] = result == HTTPRequest.RESULT_SUCCESS and code == 200)
	if http.request(ENDPOINT) != OK:
		return false
	var waited := 0.0
	while not bool(state["done"]) and waited < 6.0:
		await create_timer(0.1).timeout
		waited += 0.1
	http.queue_free()
	return bool(state["ok"])

func _round_trip(assistant: Window, prompt: String) -> bool:
	assistant.prompt_edit.text = prompt
	assistant._request_proposal()
	var waited := 0.0
	while waited < 90.0:
		if not assistant.apply_button.disabled:
			return true
		var status: String = str(assistant.status_label.text)
		if status.begins_with("Provider request failed") or status.begins_with("Use HTTPS") or status.begins_with("Enter a prompt"):
			push_error("FAIL: request rejected: " + status)
			return false
		await create_timer(0.25).timeout
		waited += 0.25
	push_error("FAIL: timed out waiting for proposal preview; status: " + assistant.status_label.text)
	return false

func _find_by_name(doc: Dictionary, wanted: String) -> Variant:
	for item in doc.get("instances", []):
		if str(item.get("name", "")) == wanted:
			return item
	return null

func _pos_matches(value: Variant, target: Vector3) -> bool:
	if not value is Array or value.size() != 3:
		return false
	return absf(float(value[0]) - target.x) < 0.001 and absf(float(value[1]) - target.y) < 0.001 and absf(float(value[2]) - target.z) < 0.001

func _check(condition: bool, name: String) -> void:
	if condition:
		print("  ok: " + name)
	else:
		_fail(name)

func _fail(name: String) -> void:
	failures += 1
	push_error("FAIL: " + name)
