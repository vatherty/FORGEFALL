extends SceneTree
## verify_ai_capture.gd — "Use Current View" capture in the AI assistant.
##
## Opens the real Studio editor, creates a map with one block, opens the AI
## assistant and calls the same capture function the button uses. Asserts a
## PNG was written under user://, that the assistant now points at it, and
## that the file decodes as an image with sane dimensions.
##
## NOTE on renderers: under --headless the rendering server is a dummy whose
## texture storage returns null images (texture_2d_get), so NO viewport
## capture can produce pixels there — the assistant must degrade gracefully
## (status message, no image selected, no crash), and this verify asserts
## exactly that in headless mode. Run the same script with a real renderer
## (e.g. under xvfb-run, without --headless) and it asserts the full path:
## PNG written, non-trivial size, decodable, correct dimensions, selected
## as the assistant's image. Pixel content beyond that still wants a real
## display/GPU (same limitation class as verify_visual).

const Store = preload("res://shared/document_store.gd")

var failures := 0

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
	var block: Dictionary = Store.new_instance("CaptureCrate", Vector3(1, 0, 1))
	editor.map_doc["instances"].append(block)
	editor._refresh()

	editor._open_ai_assistant()
	var assistant: Window = editor.get_node("AIProposals")
	if assistant == null:
		_fail("AI assistant window did not open")
		quit(1)
		return
	_check(assistant.image_path == "", "no image selected before capture")

	# Remove any stale capture from an earlier run so the assertions below
	# can only pass on a file written by this capture.
	var capture_global := ProjectSettings.globalize_path(assistant.CAPTURE_PATH)
	if FileAccess.file_exists(assistant.CAPTURE_PATH):
		DirAccess.remove_absolute(capture_global)

	await assistant._use_current_view()

	if DisplayServer.get_name() == "headless":
		# Dummy rendering server: texture reads return null by design, so the
		# capture must refuse gracefully instead of writing a bogus file.
		_check(assistant.image_path == "", "headless: no image selected when capture is impossible")
		_check(assistant.status_label.text == "The current view is empty — nothing to capture.", "headless: status explains the empty view (got '%s')" % assistant.status_label.text)
		_check(not FileAccess.file_exists(assistant.CAPTURE_PATH), "headless: no capture file written")
		if failures == 0:
			print("PASS AI current-view capture headless degradation (no renderer: graceful refusal, no crash)")
			print("NOTE: rerun under a real renderer (xvfb-run, no --headless) to verify the PNG-writing path.")
			quit(0)
		else:
			quit(1)
		return

	_check(assistant.image_path == assistant.CAPTURE_PATH, "assistant image_path points at the capture (got '%s')" % assistant.image_path)
	_check(assistant.image_label.text == assistant.CAPTURE_PATH.get_file(), "image label shows the capture file name (got '%s')" % assistant.image_label.text)
	_check(FileAccess.file_exists(assistant.CAPTURE_PATH), "capture PNG exists at " + assistant.CAPTURE_PATH)
	if FileAccess.file_exists(assistant.CAPTURE_PATH):
		var bytes := FileAccess.get_file_as_bytes(assistant.CAPTURE_PATH)
		_check(bytes.size() > 2048, "capture PNG is non-trivial in size (%d bytes)" % bytes.size())
		_check(bytes.size() <= assistant.MAX_IMAGE_BYTES, "capture PNG within the 4 MiB send limit (%d bytes)" % bytes.size())
		var decoded := Image.new()
		var error := decoded.load_png_from_buffer(bytes)
		_check(error == OK, "capture decodes as a PNG image")
		if error == OK:
			_check(decoded.get_width() > 0 and decoded.get_height() > 0, "capture has real dimensions (%dx%d)" % [decoded.get_width(), decoded.get_height()])
			_check(decoded.get_width() <= assistant.CAPTURE_MAX_WIDTH, "capture width within the %d px cap (%d)" % [assistant.CAPTURE_MAX_WIDTH, decoded.get_width()])
			print("Capture decoded: %dx%d, format %d, %d bytes (pixels may be blank under --headless)" % [decoded.get_width(), decoded.get_height(), decoded.get_format(), bytes.size()])

	if failures == 0:
		print("PASS AI current-view capture (button path writes a valid PNG and selects it)")
		quit(0)
	else:
		quit(1)

func _check(condition: bool, name: String) -> void:
	if condition:
		print("ok: " + name)
	else:
		_fail(name)

func _fail(message: String) -> void:
	failures += 1
	push_error("FAIL: " + message)
