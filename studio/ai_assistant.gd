extends Window

const Proposals = preload("res://ai_proposals.gd")
const MAX_IMAGE_BYTES := 4 * 1024 * 1024

var editor: Control
var prompt_edit: TextEdit
var response_edit: TextEdit
var preview_edit: TextEdit
var endpoint_edit: LineEdit
var image_label: Label
var status_label: Label
var apply_button: Button
var image_path := ""
var proposal: Dictionary = {}
var request: HTTPRequest

func _ready() -> void:
	title = "AI proposals — Forgefall Studio"
	size = Vector2i(880, 730)
	min_size = Vector2i(680, 540)
	close_requested.connect(queue_free)
	_build_ui()

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)
	root.add_child(_label("AI is optional. Request a proposal, review its actions, then Apply as one undoable edit."))
	endpoint_edit = LineEdit.new()
	endpoint_edit.placeholder_text = "HTTPS proposal endpoint (or http://127.0.0.1:port)"
	endpoint_edit.text = OS.get_environment("FORGEFALL_STUDIO_AI_ENDPOINT")
	root.add_child(endpoint_edit)
	root.add_child(_label("Token comes only from FORGEFALL_STUDIO_AI_TOKEN. Nothing is sent until Request is pressed."))
	root.add_child(_label("Describe a map edit"))
	prompt_edit = TextEdit.new()
	prompt_edit.custom_minimum_size.y = 90
	prompt_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(prompt_edit)
	var actions := HBoxContainer.new()
	root.add_child(actions)
	_button(actions, "Choose image", _choose_image)
	image_label = _label("No image selected")
	image_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(image_label)
	_button(actions, "Request", _request_proposal)
	root.add_child(_label("Provider JSON response (you can paste one for offline use)"))
	response_edit = TextEdit.new()
	response_edit.custom_minimum_size.y = 125
	response_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	response_edit.text_changed.connect(_clear_proposal)
	root.add_child(response_edit)
	_button(root, "Preview JSON", _preview)
	root.add_child(_label("Validated preview"))
	preview_edit = TextEdit.new()
	preview_edit.editable = false
	preview_edit.custom_minimum_size.y = 125
	preview_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(preview_edit)
	apply_button = Button.new()
	apply_button.text = "Apply proposal"
	apply_button.disabled = true
	apply_button.pressed.connect(_apply)
	root.add_child(apply_button)
	status_label = _label("Supported actions: add_block, move_instance, recolor_instance, rename_instance.")
	root.add_child(status_label)
	var picker := FileDialog.new()
	picker.name = "ImagePicker"
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.add_filter("*.png, *.jpg, *.jpeg, *.webp", "Image")
	picker.file_selected.connect(_set_image)
	add_child(picker)
	request = HTTPRequest.new()
	request.timeout = 30
	request.request_completed.connect(_request_completed)
	add_child(request)

func _label(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _button(parent: Node, label: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.pressed.connect(callback)
	parent.add_child(button)

func _choose_image() -> void:
	get_node("ImagePicker").popup_centered_ratio(0.8)

func _set_image(path: String) -> void:
	image_path = path
	image_label.text = path.get_file()

func _clear_proposal() -> void:
	proposal = {}
	apply_button.disabled = true
	preview_edit.text = ""

func _request_proposal() -> void:
	_clear_proposal()
	if editor == null or editor.map_doc.is_empty():
		status_label.text = "Create or open a map first."
		return
	var endpoint := endpoint_edit.text.strip_edges()
	if not endpoint.begins_with("https://") and not endpoint.begins_with("http://127.0.0.1:") and not endpoint.begins_with("http://localhost:"):
		status_label.text = "Use HTTPS or a localhost HTTP endpoint."
		return
	if prompt_edit.text.strip_edges().is_empty() or prompt_edit.text.length() > 2000:
		status_label.text = "Enter a prompt of 1 to 2000 characters."
		return
	var payload := {"schema": "forgefall-studio-proposal-v1", "prompt": prompt_edit.text, "map": editor.map_doc.duplicate(true)}
	if image_path != "":
		var image := FileAccess.get_file_as_bytes(image_path)
		if image.is_empty() or image.size() > MAX_IMAGE_BYTES:
			status_label.text = "Image must be readable and at most 4 MiB."
			return
		var extension := image_path.get_extension().to_lower()
		var mime := "image/jpeg" if extension in ["jpg", "jpeg"] else "image/webp" if extension == "webp" else "image/png"
		payload["image_data_url"] = "data:" + mime + ";base64," + Marshalls.raw_to_base64(image)
	var headers := PackedStringArray(["Content-Type: application/json"])
	var token := OS.get_environment("FORGEFALL_STUDIO_AI_TOKEN")
	if token != "":
		headers.append("Authorization: Bearer " + token)
	var error := request.request(endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	status_label.text = "Request sent. Review the response before applying." if error == OK else "Request failed to start: " + error_string(error)

func _request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		status_label.text = "Provider request failed (network %d, HTTP %d)." % [result, code]
		return
	if body.size() > 1024 * 1024:
		status_label.text = "Provider response is too large."
		return
	response_edit.text = body.get_string_from_utf8()
	_preview()

func _preview() -> void:
	_clear_proposal()
	if editor == null or editor.map_doc.is_empty():
		status_label.text = "Create or open a map first."
		return
	proposal = Proposals.parse_response(response_edit.text, editor.map_doc)
	if str(proposal.get("error", "")) != "":
		status_label.text = str(proposal["error"])
		return
	preview_edit.text = str(proposal["summary"])
	apply_button.disabled = false
	status_label.text = "Preview ready. Apply creates one undo step."

func _apply() -> void:
	if proposal.is_empty() or editor == null:
		return
	if str(proposal.get("base", "")) != JSON.stringify(editor.map_doc):
		_clear_proposal()
		status_label.text = "Map changed since preview. Request or preview again."
		return
	editor._apply("Apply AI proposal", proposal["document"])
	_clear_proposal()
	status_label.text = "Applied. Use Studio Undo or Redo to review."
