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
#
# - EDIT CONTEXT (v0.5.9): when the player taps EDIT on an installed
#   mod, the menu seeds this session with that mod's context
#   (begin_edit: mod_id, name, version, categories, visual, logic,
#   current payload). The context persists alongside the messages
#   (same file, "edit_context" key) so an edit survives reopening the
#   menu, and generation requests include it (the model refines THAT
#   mod). clear_edit() abandons the edit — the installed mod is
#   untouched, and the conversation stays. clear() wipes the edit
#   context too (a new chat is not an edit).
extends RefCounted
class_name ChatSession

signal messages_changed
signal session_cleared

const SAVE_PATH := "user://chat_session.json"
const MAX_MESSAGES := 20

var _messages: Array = []
## EDIT context (v0.5.9): the installed mod being refined, or {} when
## no edit is in progress. Shape: ModCreator.edit_context_for() output
## (mod_id / name / kind / version / categories / visual / logic /
## payload / manifest). Persisted with the messages.
var _edit_context: Dictionary = {}


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
	_edit_context = {}
	_delete_save_file()
	session_cleared.emit()
	messages_changed.emit()


# --- EDIT CONTEXT (v0.5.9) -------------------------------------------------

## True while an EDIT is in progress (an installed mod is seeded).
func is_editing() -> bool:
	return not _edit_context.is_empty()


## The seeded edit context (deep copy), or {} when no edit is in
## progress. Callers must not mutate the stored dict.
func get_edit_context() -> Dictionary:
	return _edit_context.duplicate(true)


## The mod id being edited, or "" when no edit is in progress.
func get_edit_mod_id() -> String:
	return str(_edit_context.get("mod_id", ""))


## Seeds the session with an installed mod's context for EDIT
## (ModCreator.edit_context_for() output). Adds ONE assistant message
## announcing the edit ("Editing '<name>' (vX) — ..."), so the chat
## shows what is being refined; the full context (incl. the current
## payload) rides in _edit_context, not in the messages, so it never
## pollutes the trimmed conversation or counts against the cap.
## Replaces any previous edit context (one edit at a time).
func begin_edit(context: Dictionary) -> void:
	_edit_context = context.duplicate(true)
	var name := str(context.get("name", ""))
	var version := str(context.get("version", ""))
	_messages.append({"role": "assistant",
		"text": "Editing '%s' (v%s) — describe the change and I'll refine THIS mod. Nothing changes until you approve the diff and tap Install." % [name, version]})
	_trim()
	_save()
	messages_changed.emit()


## Abandons the edit: the edit context is dropped (the installed mod
## is untouched — Discard never writes). The conversation stays.
func clear_edit() -> void:
	_edit_context = {}
	_save()
	messages_changed.emit()


## Generation preamble for an edit ("" when no edit is in progress):
## the original mod's identity + current payload, so the model
## refines THAT mod instead of generating a fresh one. The caller
## prepends this to the generation request (CREATE tab + CREATE
## FROM CHAT both go through the menu, which reads this).
static func edit_preamble(context: Dictionary) -> String:
	if context.is_empty():
		return ""
	return "EDIT AN EXISTING MOD — refine it, do NOT create a fresh mod. Keep the mod's identity (same name, same kind, same mod_id '%s') unless the request explicitly renames it, and change ONLY what the request asks for. The current installed version is v%s. Its full current payload follows — start from THESE bytes and return the FULL updated payload (not a patch):\n%s" % [
		str(context.get("mod_id", "")), str(context.get("version", "")),
		str(context.get("payload", ""))]


# --- Persistence ---------------------------------------------------------------

func _trim() -> void:
	while _messages.size() > MAX_MESSAGES:
		_messages.pop_front()


func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"messages": _messages, "edit_context": _edit_context}))
	f.close()


func _load() -> void:
	_messages = []
	_edit_context = {}
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
	# v0.5.9: an edit in progress survives reopening the menu. A
	# stale context (mod uninstalled since) is kept as-is — the menu
	# re-validates it against the installed list before generating.
	var ctx: Variant = (parsed as Dictionary).get("edit_context", {})
	if ctx is Dictionary:
		_edit_context = (ctx as Dictionary).duplicate(true)


func _delete_save_file() -> void:
	var abs_path := OS.get_user_data_dir().path_join("chat_session.json")
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(abs_path)
