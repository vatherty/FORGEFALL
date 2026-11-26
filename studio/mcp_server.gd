extends Node
## mcp_server.gd — Forgefall Studio as a Model Context Protocol (MCP) server.
##
## When enabled from Studio's toolbar, this node serves a minimal Streamable
## HTTP MCP endpoint on 127.0.0.1 (default port 8772) so an external AI agent
## — Muse, Codex, any MCP client, typically running on the user's own
## subscription instead of a metered API key — can see and edit the map that
## is open in the editor. The agent is just another proposal source: every
## edit flows through ai_proposals.gd validation and the editor's undoable
## _apply(), exactly like AI Assist. Nothing outside that validated action
## vocabulary (add_block / move_instance / recolor_instance / rename_instance)
## can be applied, and each apply is a single undoable command.
##
## The server is OFF by default. It binds localhost only and has no auth:
## while it is enabled, any local process can edit the open map through the
## tools below. See tools/STUDIO_MCP.md.
##
## Implementation notes: one request per connection (responses are sent with
## Connection: close). studio_capture_view is asynchronous — it must wait for
## a rendered frame — so a tool handler may return a deferred sentinel and
## the response is completed later via complete_deferred(). Malformed input
## of any kind must produce a clean error, never a crashed editor.

const Proposals = preload("res://ai_proposals.gd")

const PROTOCOL_VERSION := "2025-03-26"
const SERVER_NAME := "forgefall-studio"
const SERVER_VERSION := "1.0"
const MAX_BODY_BYTES := 4 * 1024 * 1024
const MAX_HEADER_BYTES := 64 * 1024
const DEFER_TIMEOUT_MSEC := 4000
const CAPTURE_DRAW_WAIT_MSEC := 1500
const CAPTURE_MAX_WIDTH := 1280

var editor = null  # The studio editor (studio.gd). Set by the editor itself.

var _tcp := TCPServer.new()
var _port := 0
var _peers: Array = []  # {id, peer, in_buf, out_buf, out_sent, close_after_send, awaiting}
var _deferred := {}  # token -> {peer_id, request_id, deadline}
var _next_peer_id := 1
var _next_token := 1
var _draw_seen := false


func start(port: int) -> Error:
	if is_running():
		return OK
	var error := _tcp.listen(port, "127.0.0.1")
	if error != OK:
		return error
	_port = port
	set_process(true)
	return OK


func stop() -> void:
	for entry in _peers:
		(entry["peer"] as StreamPeerTCP).disconnect_from_host()
	_peers.clear()
	_deferred.clear()
	if _tcp.is_listening():
		_tcp.stop()
	_port = 0


func is_running() -> bool:
	return _tcp.is_listening()


func port() -> int:
	return _port


# ---------------------------------------------------------------------------
# Connection pump
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _tcp.is_listening():
		return
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		if peer != null:
			_peers.append({
				"id": _next_peer_id, "peer": peer,
				"in_buf": PackedByteArray(), "out_buf": PackedByteArray(),
				"out_sent": 0, "close_after_send": false, "awaiting": false,
			})
			_next_peer_id += 1
	_fail_expired_deferred()
	for i in range(_peers.size() - 1, -1, -1):
		var entry: Dictionary = _peers[i]
		var peer := entry["peer"] as StreamPeerTCP
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			_peers.remove_at(i)
			continue
		if status == StreamPeerTCP.STATUS_CONNECTED:
			if not bool(entry["awaiting"]) and not bool(entry["close_after_send"]):
				_read_peer(entry)
			_flush_peer(entry)
			if bool(entry["close_after_send"]) and int(entry["out_sent"]) >= (entry["out_buf"] as PackedByteArray).size():
				peer.disconnect_from_host()
				_peers.remove_at(i)


func _read_peer(entry: Dictionary) -> void:
	var peer := entry["peer"] as StreamPeerTCP
	var available := peer.get_available_bytes()
	if available > 0:
		var chunk := peer.get_data(mini(available, 65536))
		if chunk[0] == OK:
			var buffer: PackedByteArray = entry["in_buf"]
			buffer.append_array(chunk[1])
			entry["in_buf"] = buffer
	_try_dispatch(entry)


func _flush_peer(entry: Dictionary) -> void:
	var peer := entry["peer"] as StreamPeerTCP
	var out: PackedByteArray = entry["out_buf"]
	var sent := int(entry["out_sent"])
	while sent < out.size():
		var result := peer.put_partial_data(out.slice(sent))
		if result[0] != OK or int(result[1]) <= 0:
			break
		sent += int(result[1])
	entry["out_sent"] = sent


func _queue_response(entry: Dictionary, status_code: int, content_type: String, body: PackedByteArray) -> void:
	var reason: String = {200: "OK", 202: "Accepted", 400: "Bad Request", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"}.get(status_code, "OK")
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status_code, reason, content_type, body.size()]
	var out: PackedByteArray = entry["out_buf"]
	out.append_array(head.to_utf8_buffer())
	out.append_array(body)
	entry["out_buf"] = out
	entry["close_after_send"] = true


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

func _find_header_end(buffer: PackedByteArray) -> int:
	if buffer.size() < 4:
		return -1
	for i in range(buffer.size() - 3):
		if buffer[i] == 13 and buffer[i + 1] == 10 and buffer[i + 2] == 13 and buffer[i + 3] == 10:
			return i + 4
	return -1


func _try_dispatch(entry: Dictionary) -> void:
	var buffer: PackedByteArray = entry["in_buf"]
	var header_end := _find_header_end(buffer)
	if header_end < 0:
		if buffer.size() > MAX_HEADER_BYTES:
			_queue_response(entry, 400, "application/json", JSON.stringify({"error": "Request headers too large."}).to_utf8_buffer())
		return
	var head_text := buffer.slice(0, header_end).get_string_from_utf8()
	var lines := head_text.split("\r\n")
	if lines.is_empty():
		_queue_response(entry, 400, "application/json", JSON.stringify({"error": "Malformed request."}).to_utf8_buffer())
		return
	var request_parts := lines[0].split(" ")
	if request_parts.size() < 2:
		_queue_response(entry, 400, "application/json", JSON.stringify({"error": "Malformed request line."}).to_utf8_buffer())
		return
	var method := request_parts[0].to_upper()
	var content_length := 0
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon > 0 and lines[i].substr(0, colon).strip_edges().to_lower() == "content-length":
			content_length = int(lines[i].substr(colon + 1).strip_edges())
	if method == "GET":
		entry["in_buf"] = PackedByteArray()
		_queue_response(entry, 200, "application/json", JSON.stringify({
			"name": SERVER_NAME, "version": SERVER_VERSION, "running": true,
			"port": _port, "protocol": "mcp", "endpoint": "/mcp",
		}).to_utf8_buffer())
		return
	if method != "POST":
		_queue_response(entry, 405, "application/json", JSON.stringify({"error": "Method not allowed."}).to_utf8_buffer())
		return
	if content_length > MAX_BODY_BYTES:
		_queue_response(entry, 413, "application/json", JSON.stringify({"error": "Request body too large."}).to_utf8_buffer())
		return
	if buffer.size() - header_end < content_length:
		return  # Body still arriving; wait for more data.
	var body := buffer.slice(header_end, header_end + content_length)
	entry["in_buf"] = PackedByteArray()
	var outcome := _handle_rpc_body(body, int(entry["id"]))
	match str(outcome.get("kind", "respond")):
		"accepted":
			_queue_response(entry, 202, "application/json", PackedByteArray())
		"deferred":
			entry["awaiting"] = true
		_:
			_queue_response(entry, 200, "application/json", JSON.stringify(outcome.get("payload", {})).to_utf8_buffer())


# ---------------------------------------------------------------------------
# JSON-RPC layer
# ---------------------------------------------------------------------------

func _rpc_result(id: Variant, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


func _rpc_error(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}


func _handle_rpc_body(body: PackedByteArray, peer_id: int) -> Dictionary:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not (parsed is Dictionary or parsed is Array):
		return {"kind": "respond", "payload": _rpc_error(null, -32700, "Parse error")}
	if parsed is Array:
		if (parsed as Array).is_empty():
			return {"kind": "respond", "payload": _rpc_error(null, -32600, "Invalid Request: empty batch")}
		var responses: Array = []
		for item in parsed:
			var outcome := _handle_single(item, peer_id)
			if str(outcome.get("kind", "")) == "deferred":
				# Deferred capture inside a batch is not supported; answer
				# that element with a tool error instead of hanging the batch.
				var token := int(outcome.get("token", -1))
				if _deferred.has(token):
					_deferred.erase(token)
				responses.append(_rpc_result(outcome.get("request_id"), _error_result("studio_capture_view is not available in batch requests.")))
			elif outcome.has("payload"):
				responses.append(outcome["payload"])
		if responses.is_empty():
			return {"kind": "accepted"}
		return {"kind": "respond", "payload": responses}
	return _handle_single(parsed, peer_id)


func _handle_single(message: Variant, peer_id: int) -> Dictionary:
	if not message is Dictionary:
		return {"kind": "respond", "payload": _rpc_error(null, -32600, "Invalid Request")}
	var has_id: bool = message.has("id")
	var id: Variant = message.get("id")
	var method := str(message.get("method", ""))
	match method:
		"initialize":
			return {"kind": "respond", "payload": _rpc_result(id, {
				"protocolVersion": PROTOCOL_VERSION,
				"capabilities": {"tools": {}},
				"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
			})}
		"ping":
			if has_id:
				return {"kind": "respond", "payload": _rpc_result(id, {})}
			return {"kind": "accepted"}
		"tools/list":
			if has_id:
				return {"kind": "respond", "payload": _rpc_result(id, {"tools": _tool_definitions()})}
			return {"kind": "accepted"}
		"tools/call":
			if not has_id:
				return {"kind": "accepted"}
			return _call_tool(message.get("params", {}), id, peer_id)
		_:
			if not has_id:
				return {"kind": "accepted"}
			return {"kind": "respond", "payload": _rpc_error(id, -32601, "Method not found: " + method)}


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

func _tool_definitions() -> Array:
	var no_args := {"type": "object", "properties": {}}
	return [
		{"name": "studio_get_state", "description": "Report the Studio editor state: whether a project is open, the current map's name/id, instance count, selected instance id, and gizmo mode.", "inputSchema": no_args},
		{"name": "studio_list_instances", "description": "List every instance in the open map with its id, name, kind, color, position, and size. Use these ids with studio_apply_actions.", "inputSchema": no_args},
		{"name": "studio_get_map", "description": "Return the full open map document as JSON.", "inputSchema": no_args},
		{"name": "studio_apply_actions", "description": "Apply validated map-editing actions to the open map as one undoable Studio command. Allowed action types: add_block {name, position, size?, color?}, move_instance {id, position}, recolor_instance {id, color}, rename_instance {id, name}. Positions/sizes snap to 0.125; colors are #RRGGBB.", "inputSchema": {"type": "object", "properties": {"actions": {"type": "array", "description": "Between 1 and 32 action objects."}, "label": {"type": "string", "description": "Undo label for this edit."}}, "required": ["actions"]}},
		{"name": "studio_capture_view", "description": "Capture Studio's 3D viewport as a PNG image so you can see the map you are editing.", "inputSchema": no_args},
		{"name": "studio_save", "description": "Save the open map through Studio's normal save path.", "inputSchema": no_args},
	]


func _text_result(text: String) -> Dictionary:
	return {"content": [{"type": "text", "text": text}], "isError": false}


func _error_result(message: String) -> Dictionary:
	return {"content": [{"type": "text", "text": message}], "isError": true}


func _respond_result(id: Variant, result: Dictionary) -> Dictionary:
	return {"kind": "respond", "payload": _rpc_result(id, result)}


func _call_tool(params: Variant, id: Variant, peer_id: int) -> Dictionary:
	if not params is Dictionary:
		return _respond_result(id, _error_result("tools/call params must be an object."))
	var tool_name := str(params.get("name", ""))
	var arguments: Variant = params.get("arguments", {})
	if not arguments is Dictionary:
		arguments = {}
	match tool_name:
		"studio_get_state":
			return _respond_result(id, _tool_get_state())
		"studio_list_instances":
			return _respond_result(id, _tool_list_instances())
		"studio_get_map":
			return _respond_result(id, _tool_get_map())
		"studio_apply_actions":
			return _respond_result(id, _tool_apply_actions(arguments))
		"studio_save":
			return _respond_result(id, _tool_save())
		"studio_capture_view":
			var token := _next_token
			_next_token += 1
			_deferred[token] = {"peer_id": peer_id, "request_id": id, "deadline": Time.get_ticks_msec() + DEFER_TIMEOUT_MSEC}
			_begin_capture(token)
			return {"kind": "deferred", "token": token, "request_id": id}
		_:
			return _respond_result(id, _error_result("Unknown tool: " + tool_name))


func _editor_ready() -> bool:
	return editor != null and is_instance_valid(editor)


func _tool_get_state() -> Dictionary:
	var data := {
		"project_open": false, "project_path": "", "map_name": "", "map_id": "",
		"instance_count": 0, "selected_id": "", "gizmo_mode": "",
	}
	if _editor_ready():
		var doc: Dictionary = editor.map_doc
		data["project_open"] = editor.project_path != ""
		data["project_path"] = editor.project_path
		data["map_name"] = str(doc.get("name", ""))
		data["map_id"] = str(doc.get("id", ""))
		data["instance_count"] = (doc.get("instances", []) as Array).size() if not doc.is_empty() else 0
		data["selected_id"] = editor.selected_id
		data["gizmo_mode"] = editor.gizmo_mode
	return _text_result(JSON.stringify(data))


func _tool_list_instances() -> Dictionary:
	var instances: Array = []
	if _editor_ready():
		for item in editor.map_doc.get("instances", []):
			if not item is Dictionary:
				continue
			var entry := {
				"id": str(item.get("id", "")),
				"name": str(item.get("name", "")),
				"kind": str(item.get("kind", "")),
				"color": str(item.get("color", "")),
				"position": item.get("position", []),
				"size": item.get("size", []),
			}
			if item.has("rotation"):
				entry["rotation"] = item["rotation"]
			instances.append(entry)
	return _text_result(JSON.stringify({"instances": instances}))


func _tool_get_map() -> Dictionary:
	if not _editor_ready() or editor.map_doc.is_empty():
		return _error_result("No map is open in Studio.")
	return _text_result(JSON.stringify(editor.map_doc))


func _tool_apply_actions(arguments: Dictionary) -> Dictionary:
	if not _editor_ready() or editor.map_doc.is_empty():
		return _error_result("No map is open in Studio.")
	var actions: Variant = arguments.get("actions")
	if not actions is Array:
		return _error_result("Argument 'actions' must be an array of action objects.")
	var label := "MCP edit"
	if arguments.get("label") is String and str(arguments["label"]).strip_edges() != "":
		label = str(arguments["label"])
	var result: Dictionary = Proposals.parse_response(JSON.stringify({"actions": actions}), editor.map_doc)
	if str(result.get("error", "")) != "":
		return _error_result(str(result["error"]))
	editor._apply(label, result["document"])
	return _text_result(JSON.stringify({
		"applied": true,
		"summary": str(result.get("summary", "")),
		"instance_count": (editor.map_doc.get("instances", []) as Array).size(),
	}))


func _tool_save() -> Dictionary:
	if not _editor_ready() or editor.map_doc.is_empty():
		return _error_result("No map is open in Studio.")
	var saved: bool = editor._save()
	return _text_result(JSON.stringify({"saved": saved}))


# ---------------------------------------------------------------------------
# Deferred completion + viewport capture
# ---------------------------------------------------------------------------

func complete_deferred(token: int, result: Dictionary) -> void:
	if not _deferred.has(token):
		return
	var pending: Dictionary = _deferred[token]
	_deferred.erase(token)
	var peer_id := int(pending["peer_id"])
	for entry in _peers:
		if int(entry["id"]) == peer_id:
			_queue_response(entry, 200, "application/json", JSON.stringify(_rpc_result(pending["request_id"], result)).to_utf8_buffer())
			return


func _fail_expired_deferred() -> void:
	if _deferred.is_empty():
		return
	var now := Time.get_ticks_msec()
	for token in _deferred.keys():
		if now > int(_deferred[token]["deadline"]):
			complete_deferred(token, _error_result("Viewport capture timed out."))


func _on_frame_drawn() -> void:
	_draw_seen = true


func _begin_capture(token: int) -> void:
	if not _editor_ready() or editor.viewport == null:
		complete_deferred(token, _error_result("Viewport capture needs a visible renderer."))
		return
	_capture_async(token)


func _capture_async(token: int) -> void:
	var view: SubViewport = editor.viewport
	var previous_mode := view.render_target_update_mode
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_draw_seen = false
	if not RenderingServer.frame_post_draw.is_connected(_on_frame_drawn):
		RenderingServer.frame_post_draw.connect(_on_frame_drawn)
	var deadline := Time.get_ticks_msec() + CAPTURE_DRAW_WAIT_MSEC
	while not _draw_seen and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if RenderingServer.frame_post_draw.is_connected(_on_frame_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_frame_drawn)
	if not _editor_ready():
		complete_deferred(token, _error_result("Viewport capture needs a visible renderer."))
		return
	view.render_target_update_mode = previous_mode
	var image: Image = null
	var texture := view.get_texture()
	if texture != null:
		image = texture.get_image()
	if image == null or image.is_empty() or image.get_width() <= 0 or image.get_height() <= 0:
		complete_deferred(token, _error_result("Viewport capture needs a visible renderer."))
		return
	if image.get_width() > CAPTURE_MAX_WIDTH:
		var scale := float(CAPTURE_MAX_WIDTH) / float(image.get_width())
		image.resize(CAPTURE_MAX_WIDTH, maxi(1, int(round(image.get_height() * scale))), Image.INTERPOLATE_LANCZOS)
	var bytes := image.save_png_to_buffer()
	if bytes.is_empty():
		complete_deferred(token, _error_result("Viewport capture needs a visible renderer."))
		return
	complete_deferred(token, {
		"content": [
			{"type": "image", "data": Marshalls.raw_to_base64(bytes), "mimeType": "image/png"},
			{"type": "text", "text": "Viewport capture %dx%d" % [image.get_width(), image.get_height()]},
		],
		"isError": false,
	})
