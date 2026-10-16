# FORGEFALL — ChatSession (v0.5.4, Worker A: Chat UI + session)
# ONE conversation object owned by the ModCreatorMenu, shared by the
# CREATE tab and the CHAT tab. Persistence + state ONLY — no network
# code here. The network side lives in ModCreator (Worker B):
# ModCreator.chat(messages) / ModCreator.generate_with_context(...).
#
# - Ordered message list of {"role": "user"|"assistant", "text": String}.
# - Persisted to user://chat_session.json on every change, so reopening
#   the creator menu keeps the chat. CLEAR wipes the persisted file.
# - History cap: only the last MAX_MESSAGES (20) are kept, enforced on
#   every add AND on load (an old oversized file is trimmed).
# - get_messages() / get_conversation() / get_history() all return the
#   trimmed conversation for the model (deep copy — callers cannot
#   mutate the stored list). Error bubbles are DISPLAY-ONLY in the
#   ChatPanel and are NEVER stored here, so an error can never pollute
#   the model context or the persisted file.
extends RefCounted
class_name ChatSession

signal messages_changed
signal session_cleared

const SAVE_PATH := "user://chat_session.json"
const MAX_MESSAGES := 20

var _messages: Array = []


func _init() -> void:
	_load()


## Full stored conversation (deep copy, trimmed to the cap).
func get_messages() -> Array:
	return _messages.duplicate(true)


## Alias for get_messages() — the trimmed conversation for the model.
func get_conversation() -> Array:
	return get_messages()


## Alias for get_messages().
func get_history() -> Array:
	return get_messages()


func message_count() -> int:
	return _messages.size()


func is_empty() -> bool:
	return _messages.is_empty()


## Last user message text, or "" when the user has said nothing yet.
## CREATE FROM CHAT passes this as the generation request.
func last_user_request() -> String:
	for i in range(_messages.size() - 1, -1, -1):
		var m: Dictionary = _messages[i]
		if str(m.get("role", "")) == "user":
			return str(m.get("text", ""))
	return ""


## Appends one message. Empty text is ignored; unknown roles are
## rejected (never stored). Enforces the cap, persists, notifies.
func add_message(role: String, text: String) -> void:
	if role not in ["user", "assistant"]:
		return
	var clean := text.strip_edges()
	if clean.is_empty():
		return
	_messages.append({"role": role, "text": clean})
	_trim()
	_save()
	messages_changed.emit()


func add_user(text: String) -> void:
	add_message("user", text)


func add_assistant(text: String) -> void:
	add_message("assistant", text)


## Wipes the in-memory list AND the persisted file. Reopening the menu
## after this starts with an empty chat.
func clear() -> void:
	_messages.clear()
	_delete_save_file()
	session_cleared.emit()
	messages_changed.emit()


# --- Persistence ---------------------------------------------------------------

func _trim() -> void:
	while _messages.size() > MAX_MESSAGES:
		_messages.pop_front()


func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"messages": _messages}))
	f.close()


func _load() -> void:
	_messages = []
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if not (parsed is Dictionary):
		return
	var raw: Variant = (parsed as Dictionary).get("messages", [])
	if not (raw is Array):
		return
	for entry in (raw as Array):
		if not (entry is Dictionary):
			continue
		var d := entry as Dictionary
		var role := str(d.get("role", ""))
		var text: Variant = d.get("text", null)
		if role not in ["user", "assistant"]:
			continue
		if not (text is String):
			continue
		if (text as String).strip_edges().is_empty():
			continue
		_messages.append({"role": role, "text": (text as String).strip_edges()})
	_trim()


func _delete_save_file() -> void:
	var abs_path := OS.get_user_data_dir().path_join("chat_session.json")
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(abs_path)
