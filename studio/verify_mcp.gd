extends SceneTree
## verify_mcp.gd — Studio as an MCP server (mcp_server.gd + studio.gd toggle).
##
## Opens the real Studio editor, creates a map with one block, enables the
## MCP server on a test port through the same toggle the toolbar button uses,
## then drives it as a REAL MCP client over TCP/HTTP (HTTPClient): initialize,
## tools/list, tools/call for state/list/get_map/apply (valid + invalid) and
## capture, checking that applies land in the editor's live, undoable document.
##
## Capture follows the same renderer split as verify_ai_capture: under
## --headless the dummy rendering server cannot produce pixels, so the tool
## must answer a graceful isError; under a real renderer (xvfb-run) it must
## return a decodable PNG image content block.

const Store = preload("res://shared/document_store.gd")

const TEST_PORT := 18772
const RPC_TIMEOUT_MSEC := 15000

var failures := 0
var _rpc_id := 100


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var editor: Control = load("res://main.tscn").instantiate()
	root.add_child(editor)
	editor._open_project(ProjectSettings.globalize_path("res://..").simplify_path())
	editor._new_map()
	if editor.map_doc.is_empty():
		_fail("could not create a map")
		quit(1)
		return
	var block: Dictionary = Store.new_instance("McpCrate", Vector3(1, 0, 1))
	var block_id := str(block["id"])
	editor.map_doc["instances"].append(block)
	editor._refresh()
	var base_count: int = editor.map_doc["instances"].size()

	# Enable through the same path (and port setting) as the toolbar button.
	editor.settings.set_value("workspace", "mcp_port", TEST_PORT)
	editor._toggle_mcp_server()
	_check(editor.mcp_server != null and editor.mcp_server.is_running(), "MCP server running after toggle on port %d" % TEST_PORT)
	if editor.mcp_server == null or not editor.mcp_server.is_running():
		quit(1)
		return

	# GET / health info.
	var health := await _request(HTTPClient.METHOD_GET, "/", "")
	_check(int(health.get("status", 0)) == 200, "GET / answers 200 (got %s)" % str(health.get("status")))
	_check(health.get("json") is Dictionary and str((health["json"] as Dictionary).get("name", "")) == "forgefall-studio", "GET / names the forgefall-studio server")

	# initialize.
	var init_response := await _post_rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "verify_mcp", "version": "1.0"}}})
	var init_json: Dictionary = init_response.get("json") if init_response.get("json") is Dictionary else {}
	var init_result: Dictionary = init_json.get("result", {}) if init_json.get("result") is Dictionary else {}
	_check(str(init_result.get("serverInfo", {}).get("name", "")) == "forgefall-studio", "initialize returns serverInfo.name forgefall-studio (got '%s')" % str(init_result.get("serverInfo", {}).get("name", "")))
	_check(str(init_result.get("protocolVersion", "")) == "2025-03-26", "initialize returns protocolVersion 2025-03-26")

	# notifications/initialized -> 202, empty body.
	var note := await _post_rpc({"jsonrpc": "2.0", "method": "notifications/initialized"})
	_check(int(note.get("status", 0)) == 202, "notification answered 202 (got %s)" % str(note.get("status")))

	# tools/list.
	var list_response := await _post_rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
	var list_json: Dictionary = list_response.get("json") if list_response.get("json") is Dictionary else {}
	var list_result: Dictionary = list_json.get("result", {}) if list_json.get("result") is Dictionary else {}
	var tools: Array = list_result.get("tools", []) if list_result.get("tools") is Array else []
	var names: Array = []
	for tool in tools:
		if tool is Dictionary:
			names.append(str(tool.get("name", "")))
	for expected in ["studio_get_state", "studio_list_instances", "studio_get_map", "studio_apply_actions", "studio_capture_view", "studio_save"]:
		_check(names.has(expected), "tools/list includes " + expected)

	# studio_get_state.
	var state_result := await _call_tool("studio_get_state", {})
	_check(not bool(state_result.get("isError", true)), "studio_get_state is not an error")
	var state: Variant = JSON.parse_string(_result_text(state_result))
	_check(state is Dictionary and bool(state.get("project_open", false)), "state reports the open project")
	_check(state is Dictionary and int(state.get("instance_count", -1)) == base_count, "state instance_count is %d (got %s)" % [base_count, str(state.get("instance_count") if state is Dictionary else null)])

	# studio_list_instances sees the block we placed.
	var instances_result := await _call_tool("studio_list_instances", {})
	var listed: Variant = JSON.parse_string(_result_text(instances_result))
	var listed_instances: Array = listed.get("instances", []) if listed is Dictionary else []
	_check(listed_instances.size() == base_count and not listed_instances.is_empty() and str(listed_instances[0].get("id", "")) == block_id, "list_instances returns the placed block by id")

	# studio_get_map round-trips the live document id.
	var map_result := await _call_tool("studio_get_map", {})
	var remote_map: Variant = JSON.parse_string(_result_text(map_result))
	_check(remote_map is Dictionary and str(remote_map.get("id", "")) == str(editor.map_doc.get("id", "")), "get_map returns the live map document")

	# studio_apply_actions: one valid add_block lands in the editor document.
	var apply_result := await _call_tool("studio_apply_actions", {"label": "MCP verify add", "actions": [{"type": "add_block", "name": "McpAdded", "position": [3, 0, 3], "color": "#3366cc"}]})
	_check(not bool(apply_result.get("isError", true)), "apply_actions accepts a valid add_block (got: %s)" % _result_text(apply_result))
	_check(editor.map_doc["instances"].size() == base_count + 1, "editor document grew to %d instances" % (base_count + 1))
	# ...and the editor's undo removes exactly that command.
	editor._undo()
	_check(editor.map_doc["instances"].size() == base_count, "editor undo restores %d instances" % base_count)

	# studio_apply_actions: an invalid action is refused, document untouched.
	var bad_result := await _call_tool("studio_apply_actions", {"actions": [{"type": "recolor_instance", "id": "no-such-instance", "color": "#ff0000"}]})
	_check(bool(bad_result.get("isError", false)), "apply_actions refuses an unknown instance id")
	_check(editor.map_doc["instances"].size() == base_count, "document unchanged after refused apply")

	# studio_capture_view: renderer-dependent, like verify_ai_capture.
	var capture_result := await _call_tool("studio_capture_view", {})
	if DisplayServer.get_name() == "headless":
		_check(bool(capture_result.get("isError", false)), "headless: capture_view degrades to a graceful isError")
	else:
		_check(not bool(capture_result.get("isError", true)), "capture_view succeeds under a real renderer (got: %s)" % _result_text(capture_result))
		var image_block: Dictionary = {}
		for content in capture_result.get("content", []):
			if content is Dictionary and str(content.get("type", "")) == "image":
				image_block = content
		_check(not image_block.is_empty(), "capture_view returns an image content block")
		if not image_block.is_empty():
			var png_bytes := Marshalls.base64_to_raw(str(image_block.get("data", "")))
			var decoded := Image.new()
			var decode_error := decoded.load_png_from_buffer(png_bytes)
			_check(decode_error == OK and decoded.get_width() > 0, "capture image decodes as PNG (%dx%d)" % [decoded.get_width(), decoded.get_height()])

	# Toggle off through the same path.
	editor._toggle_mcp_server()
	_check(not editor.mcp_server.is_running(), "MCP server stopped after second toggle")

	if failures == 0:
		print("PASS MCP server (health/initialize/list/state/apply/undo/invalid/capture, real HTTP client)")
		quit(0)
	else:
		quit(1)


# ---------------------------------------------------------------------------
# Minimal MCP-over-HTTP client (one HTTPClient per request; the server
# answers with Connection: close).
# ---------------------------------------------------------------------------

func _post_rpc(payload: Dictionary) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/mcp", JSON.stringify(payload))


func _request(method: HTTPClient.Method, path: String, body: String) -> Dictionary:
	var client := HTTPClient.new()
	var deadline := Time.get_ticks_msec() + RPC_TIMEOUT_MSEC
	if client.connect_to_host("127.0.0.1", TEST_PORT) != OK:
		return {"status": -1, "json": null}
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		await process_frame
		if Time.get_ticks_msec() > deadline:
			return {"status": -2, "json": null}
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"status": -3, "json": null}
	var headers := ["Content-Type: application/json", "Accept: application/json"]
	if client.request(method, path, headers, body) != OK:
		return {"status": -4, "json": null}
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await process_frame
		if Time.get_ticks_msec() > deadline:
			return {"status": -5, "json": null}
	var status_code := client.get_response_code()
	var bytes := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		if client.get_status() != HTTPClient.STATUS_BODY:
			break
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			bytes.append_array(chunk)
		else:
			await process_frame
		if Time.get_ticks_msec() > deadline:
			break
	client.close()
	var parsed: Variant = null
	if bytes.size() > 0:
		parsed = JSON.parse_string(bytes.get_string_from_utf8())
	return {"status": status_code, "json": parsed}


func _call_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	_rpc_id += 1
	var response := await _post_rpc({"jsonrpc": "2.0", "id": _rpc_id, "method": "tools/call", "params": {"name": tool_name, "arguments": arguments}})
	var json: Variant = response.get("json")
	if json is Dictionary and (json as Dictionary).has("result") and (json as Dictionary)["result"] is Dictionary:
		return (json as Dictionary)["result"]
	_fail("tools/call %s returned no result (status %s, body %s)" % [tool_name, str(response.get("status")), str(json)])
	return {"content": [{"type": "text", "text": ""}], "isError": true}


func _result_text(result: Dictionary) -> String:
	for content in result.get("content", []):
		if content is Dictionary and str(content.get("type", "")) == "text":
			return str(content.get("text", ""))
	return ""


func _check(condition: bool, name: String) -> void:
	if condition:
		print("ok: " + name)
	else:
		_fail(name)


func _fail(message: String) -> void:
	failures += 1
	push_error("FAIL: " + message)
