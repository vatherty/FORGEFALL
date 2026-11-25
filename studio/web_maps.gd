extends Window

const Store = preload("res://shared/document_store.gd")
const History = preload("res://command_history.gd")

var editor: Control
var json_edit: TextEdit
var status_label: Label
var _import_callback: JavaScriptObject

func _ready() -> void:
	title = "Web map transfer"
	size = Vector2i(760, 620)
	min_size = Vector2i(580, 440)
	close_requested.connect(queue_free)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var intro := Label.new()
	intro.text = "Paste a Studio map JSON file to open it. Download JSON to keep edits. Native scene publishing requires desktop Studio."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(intro)
	json_edit = TextEdit.new()
	json_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(json_edit)
	var actions := HBoxContainer.new()
	root.add_child(actions)
	_add_button(actions, "New Map", _new_map)
	_add_button(actions, "Import JSON", _import_json)
	_add_button(actions, "Choose JSON file", _choose_file)
	_add_button(actions, "Download current map", _download)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.text = "No files are sent to a server. Import replaces the open map only after it has been downloaded."
	root.add_child(status_label)

func _add_button(parent: Node, caption: String, action: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(action)
	parent.add_child(button)

func _can_replace() -> bool:
	if editor == null:
		return false
	if editor._is_dirty():
		status_label.text = "Current map has undownloaded edits. Download it before replacing it."
		return false
	return true

func _new_map() -> void:
	if not _can_replace():
		return
	editor.map_doc = Store.new_map("Untitled Web Map")
	editor.saved_text = ""
	editor.disk_text = ""
	editor.history = History.new()
	editor.selected_id = ""
	editor._refresh()
	status_label.text = "New map. Download JSON when finished."

func _import_json() -> void:
	if not _can_replace():
		return
	if json_edit.text.length() > 2 * 1024 * 1024:
		status_label.text = "Map JSON exceeds 2 MiB."
		return
	var candidate: Variant = JSON.parse_string(json_edit.text)
	if not candidate is Dictionary:
		status_label.text = "Paste a valid JSON map object."
		return
	var problem := Store.validate_map(candidate)
	if problem != "":
		status_label.text = problem
		return
	editor.map_doc = candidate
	editor.saved_text = JSON.stringify(candidate)
	editor.disk_text = ""
	editor.history = History.new()
	editor.selected_id = ""
	editor._refresh()
	status_label.text = "Imported map. Download JSON after editing."

func _choose_file() -> void:
	if not _can_replace():
		return
	if not OS.has_feature("web"):
		status_label.text = "Browser file selection is available in the Web build."
		return
	_import_callback = JavaScriptBridge.create_callback(_file_chosen)
	JavaScriptBridge.get_interface("window").forgefallStudioImport = _import_callback
	JavaScriptBridge.eval("""
		(() => {
		  const input = document.createElement('input');
		  input.style.display = 'none';
		  document.body.appendChild(input);
		  input.type = 'file';
		  input.accept = '.json,application/json';
		  input.onchange = () => {
		    const file = input.files && input.files[0];
		    if (!file || file.size > 2 * 1024 * 1024) { window.forgefallStudioImport(''); input.remove(); return; }
		    const reader = new FileReader();
		    reader.onload = () => { window.forgefallStudioImport(String(reader.result || '')); input.remove(); };
		    reader.onerror = () => { window.forgefallStudioImport(''); input.remove(); };
		    reader.readAsText(file);
		  };
		  input.click();
		})();
	""")

func _file_chosen(args: Array) -> void:
	if args.is_empty() or str(args[0]).is_empty():
		status_label.text = "No readable JSON file selected (limit 2 MiB)."
		return
	json_edit.text = str(args[0])
	_import_json()

func _download() -> void:
	if editor == null or editor.map_doc.is_empty():
		status_label.text = "Create or import a map first."
		return
	var problem := Store.validate_map(editor.map_doc)
	if problem != "":
		status_label.text = problem
		return
	if not OS.has_feature("web"):
		status_label.text = "Download is available in the Web build."
		return
	var filename := "forgefall-map-" + str(editor.map_doc["id"]) + ".json"
	var json_text := JSON.stringify(editor.map_doc, "\t") + "\n"
	json_edit.text = json_text
	JavaScriptBridge.download_buffer(json_text.to_utf8_buffer(), filename, "application/json")
	editor.saved_text = JSON.stringify(editor.map_doc)
	editor._refresh()
	status_label.text = "Browser download requested: " + filename + ". If no file appears, copy the JSON above into a .json file before replacing this map."
