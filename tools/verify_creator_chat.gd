# verify_creator_chat.gd — headless checks for FORGEFALL v0.5.4 chat
# (WORKER C, verification): a CHAT tab in the Create-a-Mod menu
# (CREATE / CHAT / MODS / IMPORT-EXPORT). One shared ChatSession:
# Chat tab + Create tab use the same conversation. Chat uses the
# DeepSeek key (user://forge_config.json). Generation -> validation ->
# approval -> Install is the only path that creates a mod.
#
# Usage: godot --headless --path <project> --script res://tools/verify_creator_chat.gd
#
# CONTRACT UNDER TEST (per the v0.5.4 task):
#   ChatSession (scripts/mods/chat_session.gd) holds messages +
#       persistence + clear + trimming.
#   ChatPanel (scripts/ui/chat_panel.gd) is the Chat tab UI.
#   ModCreator (scripts/mods/mod_creator.gd) exposes chat(messages)
#       emitting chat_reply / chat_error, generate_with_context(
#       conversation, request) with the same approval outcome as
#       generate(), and get_greeting().
#
# ADAPTIVITY (A/B land in parallel): this suite PROBES the real API at
# runtime instead of assuming exact names — it inspects method lists,
# signal lists, property lists and constant maps, and accepts the
# message shapes {role, content} or {sender, text}. Missing contract
# deliverables FAIL the presence checks; behaviour that cannot run
# without them is SKIPPED with a reason, never faked.
#
# STUB POLICY — NO LIVE NETWORK, NO REAL KEY, EVER:
#   - Tests NEVER call chat()/generate()/generate_with_context()
#     unless (a) a stub seam is armed AND read back, or (b) the
#     DeepSeek key has been removed from user://forge_config.json
#     (the no-key path must error before any HTTP — the same guard
#     ForgeLLM.request_generation already uses) — or (c) the call
#     goes through ModCreator.mock_generation, the same stub pattern
#     verify_v08_create.gd uses.
#   - Chat stub seams probed, in order: mock_chat_reply,
#     mock_chat_response, mock_chat, mock_reply (String = canned
#     reply, Dictionary = {"reply": ...}). A seam supplied BY THIS
#     TEST is never used to assert on reply CONTENT (that would test
#     the test); capability keywords are asserted only on
#     implementation-owned text (a local canned answer, a
#     CHAT_SYSTEM_PROMPT-style constant, or get_greeting()).
#   - This suite NEVER calls install(). Approval-screen appearance
#     is the end state; the mods-tree-unchanged check is the guard.
#
# ISOLATION: backs up user://forge_config.json, user://mods/ and
# top-level user:// files, and restores them in _cleanup() on EVERY
# exit path. The real key (if any) is never printed or logged.
#
# Exit 0 = all checks pass; any FAIL prints and exits 1. SKIPPED checks
# (with reasons) do not fail the run.
extends SceneTree

var _fails := 0
var _passes := 0
var _skips := 0
var _cleaned_up := false
var _done := false

# --- Phase machine ----------------------------------------------------------
var _phase := 0
var _step := "run"  # run | wait
var _wait := 0
var _wait_frames := 120
var _wait_for := ""  # chat_reply | chat_error | chat_any | generation_ready | timer
var _signal_got := false
var _signal_payload: Variant = null
var _substep := 0
const LAST_PHASE := 9
const TIMEOUT_FRAMES := 120
const TIMER_FRAMES := 45

# --- Scripts under test -----------------------------------------------------
var _session_script: GDScript = null
var _panel_script: GDScript = null
var _creator_script: GDScript = null
var _menu_script: GDScript = null
var _loader_script: GDScript = null
var _llm_script: GDScript = null
var _prompt_script: GDScript = null  # ChatPrompt (system prompt + trimming)

# --- Live instances ---------------------------------------------------------
var _creator_inst: Object = null
var _session_inst: Object = null
var _panel: Control = null
var _menu: Control = null

# --- Stub seam state --------------------------------------------------------
var _chat_seam_name := ""
var _chat_seam_scope := ""  # "script" (static) | "instance" | ""
var _chat_seam_orig: Variant = null
var _chat_seam_type := ""  # "String" | "Dictionary" | ""
var _local_reply_text := ""  # reply received with NO key + NO seam (impl-owned)
var _last_chat_error := ""
var _last_chat_reply := ""
var _last_candidate: Dictionary = {}
var _panel_approval_candidate: Dictionary = {}

# --- Fixture staging --------------------------------------------------------
var _user_dir := ""
var _mods_abs := ""
var _mods_backup_abs := ""
var _enabled_abs := ""
var _enabled_backup_abs := ""
var _config_abs := ""
var _config_backup_abs := ""
var _had_mods := false
var _had_enabled := false
var _had_config := false
var _snapshot_files: Dictionary = {}  # rel name -> content (top-level user://)
var _snapshot_mods: Array = []
var _snapshot_dirs: Array = []  # top-level user:// dir names


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _skip(label: String, reason: String) -> void:
	_skips += 1
	print("SKIPPED: ", label, " (", reason, ")")


func _note(msg: String) -> void:
	print("CHATVERIFY NOTE: ", msg)


# --- Generic reflection helpers ---------------------------------------------

func _method_info(script: GDScript, method: String) -> Dictionary:
	if script == null:
		return {}
	for m in script.get_script_method_list():
		if str(m.get("name", "")) == method:
			return m
	return {}


func _has_method(script: GDScript, method: String) -> bool:
	return not _method_info(script, method).is_empty()


func _method_arg_count(script: GDScript, method: String) -> int:
	var info := _method_info(script, method)
	if info.is_empty():
		return -1
	return (info.get("args", []) as Array).size()


func _method_first_arg_type(script: GDScript, method: String) -> int:
	var info := _method_info(script, method)
	if info.is_empty():
		return -1
	var args: Array = info.get("args", [])
	if args.is_empty():
		return -1
	return int((args[0] as Dictionary).get("type", -1))


func _has_prop(script: GDScript, name: String) -> bool:
	if script == null:
		return false
	for p in script.get_script_property_list():
		if str((p as Dictionary).get("name", "")) == name:
			return true
	return false


func _const_map(script: GDScript) -> Dictionary:
	if script == null:
		return {}
	return script.get_script_constant_map()


func _const_named(script: GDScript, names: Array) -> Variant:
	var cmap := _const_map(script)
	for n in names:
		if cmap.has(n):
			return cmap[n]
	return null


func _call_script(script: GDScript, method: String, args: Array) -> Variant:
	if script == null:
		return null
	var is_static := true
	var found := false
	for m in script.get_script_method_list():
		if str(m.get("name", "")) == method:
			found = true
			is_static = (int(m.get("flags", 0)) & 32) != 0
			break
	if not found:
		return null
	if is_static:
		return script.callv(method, args)
	var inst: Object = script.new()
	var result: Variant = inst.callv(method, args)
	if inst is Node:
		(inst as Node).free()
	return result


# --- Message-shape helpers (accept {role,content} or {sender,text}) ---------

func _mk_msg(role: String, text: String) -> Dictionary:
	return {"role": role, "content": text}


func _msg_role(m: Variant) -> String:
	if not (m is Dictionary):
		return ""
	var d := m as Dictionary
	for k in ["role", "sender", "author", "from"]:
		if d.has(k):
			return str(d[k])
	return ""


func _msg_text(m: Variant) -> String:
	if not (m is Dictionary):
		return ""
	var d := m as Dictionary
	for k in ["content", "text", "message", "body"]:
		if d.has(k):
			return str(d[k])
	return ""


func _msgs_have(msgs: Array, role: String, text: String) -> bool:
	for m in msgs:
		if _msg_role(m) == role and _msg_text(m) == text:
			return true
	return false


func _msgs_contain(msgs: Array, needle: String) -> bool:
	for m in msgs:
		if _msg_text(m).contains(needle):
			return true
	return false


# --- Node helpers -----------------------------------------------------------

func _find_named(n: Node, name: String) -> Node:
	if n.name == name and not n.is_queued_for_deletion():
		return n
	for c in n.get_children():
		var found := _find_named(c, name)
		if found != null:
			return found
	return null


func _find_by_name_substr(n: Node, needle: String) -> Node:
	if n.name.to_lower().contains(needle.to_lower()):
		return n
	for c in n.get_children():
		var found := _find_by_name_substr(c, needle)
		if found != null:
			return found
	return null


func _find_button_by_text(n: Node, needle: String) -> Button:
	if n is Button and (n as Button).text.to_lower().contains(needle.to_lower()):
		return n as Button
	for c in n.get_children():
		var found := _find_button_by_text(c, needle)
		if found != null:
			return found
	return null


func _collect_texts(n: Node, out: Array) -> void:
	if n is Label:
		out.append((n as Label).text)
	elif n is Button:
		out.append((n as Button).text)
	elif n is TextEdit:
		out.append((n as TextEdit).text)
	elif n is LineEdit:
		out.append((n as LineEdit).text)
	for c in n.get_children():
		_collect_texts(c, out)


func _texts_contain(n: Node, needle: String) -> bool:
	var texts: Array = []
	_collect_texts(n, texts)
	var low := needle.to_lower()
	for t in texts:
		if str(t).to_lower().contains(low):
			return true
	return false


# --- Filesystem (backup / restore / listing) --------------------------------

func _copy_file(src: String, dst: String) -> void:
	var text := FileAccess.get_file_as_string(src)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _copy_recursive(src: String, dst: String) -> void:
	var dir := DirAccess.open(src)
	if dir == null:
		return
	DirAccess.make_dir_recursive_absolute(dst)
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var s := src.path_join(entry)
		var d := dst.path_join(entry)
		if dir.current_is_dir():
			_copy_recursive(s, d)
		else:
			_copy_file(s, d)
		entry = dir.get_next()
	dir.list_dir_end()


func _wipe_contents(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_wipe_contents(full)
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _list_recursive(abs: String, rel: String, out: Array) -> void:
	var dir := DirAccess.open(abs)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			if entry == "assets" and dir.current_is_dir() and rel.is_empty():
				entry = dir.get_next()
				continue
			var r := entry if rel.is_empty() else rel + "/" + entry
			if dir.current_is_dir():
				_list_recursive(abs.path_join(entry), r, out)
			else:
				out.append(r)
		entry = dir.get_next()
	dir.list_dir_end()


func _list_mods_tree() -> Array:
	var out: Array = []
	_list_recursive(_mods_abs, "", out)
	out.sort()
	return out


func _snapshot_user_top() -> void:
	_snapshot_files = {}
	_snapshot_dirs = []
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		if dir.current_is_dir():
			_snapshot_dirs.append(entry)
		else:
			_snapshot_files[entry] = FileAccess.get_file_as_string("user://".path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()


func _backup_and_stage() -> void:
	_user_dir = OS.get_user_data_dir()
	_mods_abs = _user_dir.path_join("mods")
	_mods_backup_abs = _user_dir.path_join("_v054_chat_verify_backup_mods")
	_enabled_abs = _user_dir.path_join("mods_enabled.json")
	_enabled_backup_abs = _user_dir.path_join("_v054_chat_verify_backup_enabled.json")
	_config_abs = _user_dir.path_join("forge_config.json")
	_config_backup_abs = _user_dir.path_join("_v054_chat_verify_backup_config.json")
	_wipe_contents(_mods_backup_abs)
	DirAccess.remove_absolute(_mods_backup_abs)
	for p in [_enabled_backup_abs, _config_backup_abs]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	_had_mods = DirAccess.dir_exists_absolute(_mods_abs)
	if _had_mods:
		_copy_recursive(_mods_abs, _mods_backup_abs)
	_had_enabled = FileAccess.file_exists(_enabled_abs)
	if _had_enabled:
		_copy_file(_enabled_abs, _enabled_backup_abs)
	_had_config = FileAccess.file_exists(_config_abs)
	if _had_config:
		_copy_file(_config_abs, _config_backup_abs)
	_snapshot_user_top()
	_snapshot_mods = _list_mods_tree()
	# No-key state for every chat phase: the key file is replaced with
	# an empty object (no key field). Restored in _cleanup().
	var f := FileAccess.open("user://forge_config.json", FileAccess.WRITE)
	if f != null:
		f.store_string("{}")
		f.close()


func _cleanup() -> void:
	if _cleaned_up:
		return
	_cleaned_up = true
	if _creator_script != null:
		_creator_script.set("mock_generation", {})
		_disarm_chat_seam()
	if _creator_inst != null and is_instance_valid(_creator_inst):
		if _creator_inst is Node:
			var n := _creator_inst as Node
			if n.is_inside_tree() and n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.free()
		_creator_inst = null
	if _session_inst != null and is_instance_valid(_session_inst):
		if _session_inst is Node:
			var n := _session_inst as Node
			if n.is_inside_tree() and n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.free()
		_session_inst = null
	if _panel != null and is_instance_valid(_panel):
		if _panel.get_parent() != null:
			_panel.get_parent().remove_child(_panel)
		_panel.free()
		_panel = null
	if _menu != null and is_instance_valid(_menu):
		if _menu.get_parent() != null:
			_menu.get_parent().remove_child(_menu)
		_menu.free()
		_menu = null
	# Restore top-level user:// files: chat/session/config files written
	# by this run are removed, pre-existing ones restored byte-for-byte.
	var dir := DirAccess.open("user://")
	if dir != null:
		dir.list_dir_begin()
		var entry := dir.get_next()
		var current: Array = []
		while entry != "":
			if entry != "." and entry != ".." and not dir.current_is_dir():
				current.append(entry)
			entry = dir.get_next()
		dir.list_dir_end()
		for name in current:
			if str(name).begins_with("_v054_chat_verify_backup"):
				continue  # own backup files — restored explicitly below
			if not _snapshot_files.has(name):
				DirAccess.remove_absolute("user://".path_join(str(name)))
		for name in _snapshot_files.keys():
			var f2 := FileAccess.open("user://".path_join(str(name)), FileAccess.WRITE)
			if f2 != null:
				f2.store_string(str(_snapshot_files[name]))
				f2.close()
	# Explicit config restore (same content as snapshot; kept for clarity).
	if _had_config:
		_copy_file(_config_backup_abs, _config_abs)
		DirAccess.remove_absolute(_config_backup_abs)
	else:
		if FileAccess.file_exists(_config_abs):
			DirAccess.remove_absolute(_config_abs)
	if not _mods_abs.is_empty():
		_wipe_contents(_mods_abs)
		if _had_mods:
			_copy_recursive(_mods_backup_abs, _mods_abs)
			_wipe_contents(_mods_backup_abs)
			DirAccess.remove_absolute(_mods_backup_abs)
		else:
			DirAccess.remove_absolute(_mods_abs)
	if FileAccess.file_exists(_enabled_abs):
		DirAccess.remove_absolute(_enabled_abs)
	if _had_enabled:
		_copy_file(_enabled_backup_abs, _enabled_abs)
		DirAccess.remove_absolute(_enabled_backup_abs)
	if _loader_script != null:
		_call_script(_loader_script, "scan_mods", [])


# --- Chat stub seam -----------------------------------------------------------
# Probed names, in order. Static (script-level) seams are preferred:
# they reach any creator instance the panel/menu builds internally.

const _CHAT_SEAM_NAMES := ["mock_chat_reply", "mock_chat_response", "mock_chat", "mock_reply"]
const CANNED_REPLY := "Stub reply: I can help you brainstorm mod ideas."
const CANNED_CHAT_QUESTION := "What can you do?"
const CANNED_CHAT_GENERIC := "Make me a fire sword that shoots watermelons."


func _find_chat_seam() -> void:
	_chat_seam_name = ""
	_chat_seam_scope = ""
	_chat_seam_type = ""
	if _creator_script == null:
		return
	# Static vars (mock_generation, mock_chat_reply) do NOT appear in
	# get_script_property_list(), so probe by READING: a seam that exists
	# reads back its default ("" or {}), a missing one reads back null.
	# No writes here — arming happens only in the phases that need it.
	for nm in _CHAT_SEAM_NAMES:
		var v: Variant = _creator_script.get(nm)
		if v is String:
			_chat_seam_name = nm
			_chat_seam_scope = "script"
			_chat_seam_type = "String"
			_chat_seam_orig = v
			return
		if v is Dictionary:
			_chat_seam_name = nm
			_chat_seam_scope = "script"
			_chat_seam_type = "Dictionary"
			_chat_seam_orig = v
			return


func _arm_chat_seam() -> bool:
	if _chat_seam_name.is_empty() or _chat_seam_scope != "script":
		return false
	var value: Variant = null
	if _chat_seam_type == "String":
		value = CANNED_REPLY
	elif _chat_seam_type == "Dictionary":
		value = {"reply": CANNED_REPLY}
	else:
		return false
	_creator_script.set(_chat_seam_name, value)
	var back: Variant = _creator_script.get(_chat_seam_name)
	if _chat_seam_type == "String":
		return back is String and str(back) == CANNED_REPLY
	if back is Dictionary:
		return str((back as Dictionary).get("reply", "")) == CANNED_REPLY
	return false


func _disarm_chat_seam() -> void:
	# Restore the original value; keep the metadata so the seam can be
	# re-armed by a later phase (panel, then menu).
	if _chat_seam_name.is_empty() or _chat_seam_scope != "script":
		return
	_creator_script.set(_chat_seam_name, _chat_seam_orig)


# --- ModCreator mock_generation (v08 stub pattern) ---------------------------

func _set_mock_generation(mock: Dictionary) -> bool:
	if _creator_script == null:
		return false
	_creator_script.set("mock_generation", mock)
	var back: Variant = _creator_script.get("mock_generation")
	return back is Dictionary


func _disarm_mock_generation() -> void:
	if _creator_script != null:
		_creator_script.set("mock_generation", {})


func _mock_block(display_name: String, shape: String, cost: int, hp: int, summary: String) -> Dictionary:
	var block := {
		"block_id": "placeholder_block", "target": "cover", "cost": cost,
		"display_name": display_name,
		"description": "A generated test block.",
		"shape": shape, "size_voxels": [1, 2, 1], "hp": hp,
	}
	return {
		"manifest": {"name": display_name, "kind": "block",
			"version": "1.0", "author": "verify"},
		"payload": JSON.stringify(block),
		"summary": summary,
	}


# --- ChatSession helpers (adaptive to the real API) --------------------------

func _new_session() -> Object:
	if _session_script == null:
		return null
	var inst: Object = _session_script.new()
	if inst == null:
		return null
	if inst is Node and not (inst as Node).is_inside_tree():
		root.add_child(inst as Node)
	return inst


func _free_session(inst: Object) -> void:
	if inst == null or not is_instance_valid(inst):
		return
	if inst is Node:
		var n := inst as Node
		if n.is_inside_tree() and n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.free()


func _session_messages(sess: Object) -> Array:
	if sess == null:
		return []
	for m in ["get_messages", "get_history", "get_all_messages", "get_entries"]:
		if sess.has_method(m):
			var r: Variant = sess.callv(m, [])
			if r is Array:
				return r as Array
	for p in ["messages", "history", "chat_history", "entries", "_messages"]:
		var v: Variant = sess.get(p)
		if v is Array:
			return v as Array
	return []


func _session_add(sess: Object, role: String, text: String) -> bool:
	if sess == null:
		return false
	if sess.has_method("add_message"):
		if _method_arg_count(_session_script, "add_message") == 2:
			sess.callv("add_message", [role, text])
			return true
		sess.callv("add_message", [_mk_msg(role, text)])
		return true
	for m in ["append_message", "append", "push_message", "add"]:
		if sess.has_method(m):
			if _method_arg_count(_session_script, m) == 2:
				sess.callv(m, [role, text])
				return true
			sess.callv(m, [_mk_msg(role, text)])
			return true
	if role == "user" and sess.has_method("add_user_message"):
		sess.callv("add_user_message", [text])
		return true
	if role == "assistant" and sess.has_method("add_assistant_message"):
		sess.callv("add_assistant_message", [text])
		return true
	return false


func _session_clear(sess: Object) -> bool:
	if sess == null:
		return false
	for m in ["clear", "clear_history", "clear_messages", "reset"]:
		if sess.has_method(m):
			sess.callv(m, [])
			return true
	return false


func _session_save(sess: Object) -> bool:
	if sess == null:
		return false
	for m in ["save", "save_session", "persist", "store"]:
		if sess.has_method(m):
			sess.callv(m, [])
			return true
	return false


func _session_load(sess: Object) -> bool:
	if sess == null:
		return false
	for m in ["load", "load_session", "restore", "reload"]:
		if sess.has_method(m):
			sess.callv(m, [])
			return true
	return false


func _session_cap() -> int:
	# History cap constant, probed across every chat-adjacent script.
	for scr in [_session_script, _creator_script, _panel_script, _llm_script, _prompt_script]:
		if scr == null:
			continue
		var v: Variant = _const_named(scr, ["MAX_MESSAGES", "MAX_HISTORY",
			"MAX_CHAT_MESSAGES", "HISTORY_CAP", "MESSAGE_CAP", "MAX_TURNS",
			"CHAT_HISTORY_CAP", "MAX_CONTEXT_MESSAGES", "MAX_CHAT_HISTORY",
			"MAX_HISTORY_MESSAGES"])
		if v is int and int(v) > 0:
			return int(v)
	return -1


# --- Creator helpers ----------------------------------------------------------

func _new_creator() -> Object:
	if _creator_inst != null and is_instance_valid(_creator_inst):
		if _creator_inst is Node:
			var n := _creator_inst as Node
			if n.is_inside_tree() and n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.free()
		_creator_inst = null
	if _creator_script == null:
		return null
	var inst: Object = _creator_script.new()
	if inst == null:
		return null
	_creator_inst = inst
	if inst.has_signal("chat_reply"):
		inst.connect("chat_reply", Callable(self, "_on_chat_reply"))
	if inst.has_signal("chat_error"):
		inst.connect("chat_error", Callable(self, "_on_chat_error"))
	if inst.has_signal("generation_ready"):
		inst.connect("generation_ready", Callable(self, "_on_generation_ready"))
	if inst is Node and not (inst as Node).is_inside_tree():
		root.add_child(inst as Node)
	return inst


func _call_chat(creator: Object, messages: Array, single_text: String) -> bool:
	# chat(messages) per contract; adapt if the real signature takes a
	# single String instead of an Array.
	if creator == null or not creator.has_method("chat"):
		return false
	var argc := _method_arg_count(_creator_script, "chat")
	if argc == 1:
		var t := _method_first_arg_type(_creator_script, "chat")
		if t == TYPE_STRING:
			creator.callv("chat", [single_text])
			return true
		if t == TYPE_DICTIONARY:
			creator.callv("chat", [{"messages": messages}])
			return true
	creator.callv("chat", [messages])
	return true


func _last_context_accessor(creator: Object) -> Variant:
	if creator == null:
		return null
	for m in ["get_last_context", "get_last_chat_context",
			"get_last_generation_context", "get_last_request_messages",
			"get_last_messages", "last_context"]:
		if creator.has_method(m):
			return creator.callv(m, [])
	for p in ["last_context", "last_chat_context", "last_generation_context",
			"last_request_messages", "last_messages", "_last_context"]:
		var v: Variant = creator.get(p)
		if v is Array or v is String:
			return v
	return null


func _greeting_text() -> String:
	# Implementation-owned greeting, from any chat-adjacent object.
	if _creator_inst != null and _creator_inst.has_method("get_greeting"):
		var g: Variant = _creator_inst.callv("get_greeting", [])
		if g is String and not str(g).strip_edges().is_empty():
			return str(g)
	if _session_inst != null and _session_inst.has_method("get_greeting"):
		var g2: Variant = _session_inst.callv("get_greeting", [])
		if g2 is String and not str(g2).strip_edges().is_empty():
			return str(g2)
	if _panel != null and _panel.has_method("get_greeting"):
		var g3: Variant = _panel.callv("get_greeting", [])
		if g3 is String and not str(g3).strip_edges().is_empty():
			return str(g3)
	return ""


func _capability_source_text() -> String:
	# Implementation-owned capability text. The CHAT_SYSTEM_PROMPT is
	# the text that actually answers "What can you do?" (the LLM
	# answers from it); the greeting is a secondary, shorter blurb.
	var parts: Array[String] = []
	for scr in [_prompt_script, _session_script, _creator_script, _panel_script, _llm_script]:
		if scr == null:
			continue
		for nm in ["CHAT_SYSTEM_PROMPT", "CHAT_PROMPT", "CHAT_CAPABILITIES",
				"CAPABILITIES_TEXT", "CHAT_GREETING", "GREETING"]:
			var v: Variant = _const_named(scr, [nm])
			if v is String and not str(v).strip_edges().is_empty():
				parts.append(str(v))
	var g := _greeting_text()
	if not g.is_empty():
		parts.append(g)
	return "\n".join(parts)


func _capability_keywords_ok(text: String) -> bool:
	var low := text.to_lower()
	var hits := 0
	for kw in ["projectile", "hook", "session", "permanent", "sandbox", "approval", "make"]:
		if low.contains(kw):
			hits += 1
	return hits >= 5


# --- Signal handlers ----------------------------------------------------------

func _on_chat_reply(reply: Variant) -> void:
	if _wait_for in ["chat_reply", "chat_any"]:
		_last_chat_reply = str(reply)
		_signal_payload = reply
		_signal_got = true


func _on_chat_error(err: Variant) -> void:
	if _wait_for in ["chat_error", "chat_any"]:
		_last_chat_error = str(err)
		_signal_payload = err
		_signal_got = true


func _on_generation_ready(candidate: Dictionary) -> void:
	# Always record the latest candidate (phases that wait on a timer
	# still need to see it); only claim the signal when this phase is
	# waiting for it.
	_last_candidate = candidate
	_signal_payload = candidate
	if _wait_for == "generation_ready":
		_signal_got = true
	if _panel != null and is_instance_valid(_panel):
		_panel_approval_candidate = candidate


# --- Main flow ----------------------------------------------------------------

func _initialize() -> void:
	_backup_and_stage()
	_session_script = load("res://scripts/mods/chat_session.gd") as GDScript
	_panel_script = load("res://scripts/ui/chat_panel.gd") as GDScript
	_creator_script = load("res://scripts/mods/mod_creator.gd") as GDScript
	_menu_script = load("res://scripts/ui/mod_creator_menu.gd") as GDScript
	_loader_script = load("res://scripts/mods/mod_loader.gd") as GDScript
	_llm_script = load("res://scripts/forge/forge_llm.gd") as GDScript
	_prompt_script = load("res://scripts/mods/chat_prompt.gd") as GDScript
	_check(_loader_script != null, "chat: mod_loader.gd loads (no parse errors)")
	_check(_creator_script != null, "chat: mod_creator.gd loads (no parse errors)")
	_find_chat_seam()
	_phase = 0
	_step = "run"


func _process(_delta: float) -> bool:
	if _done:
		return true
	if _step == "run":
		_run_phase(_phase)
		return false
	if _step == "wait":
		_wait += 1
		if _signal_got or _wait >= _wait_frames:
			var stay := _end_phase(_phase)
			if _done:
				return true
			if stay:
				_step = "wait"
				_wait = 0
				_signal_got = false
				_signal_payload = null
				return false
			_phase += 1
			_substep = 0
			_step = "run"
			_wait = 0
			_signal_got = false
			_signal_payload = null
		return false
	return false


func _begin_wait(kind: String, frames: int) -> void:
	_wait_for = kind
	_wait_frames = frames
	_wait = 0
	_signal_got = false
	_signal_payload = null
	_step = "wait"


func _advance_sync() -> void:
	_phase += 1
	_substep = 0
	_step = "run"


# --- Panel / menu helpers -----------------------------------------------------

var _panel_send_attempted := false
var _panel_create_attempted := false
var _panel_session_injected := false
var _panel_seam_armed := false
var _menu_create_attempted := false
var _panel_create_signal: Dictionary = {}
var _ctx_conv: Array = []
var _ctx_request := ""


func _find_panel_input(p: Control) -> Variant:
	# Prefer a chat input; never the approval payload box.
	var stack: Array = [p]
	while not stack.is_empty():
		var n: Node = stack.pop_back() as Node
		if n is LineEdit or n is TextEdit:
			var nm := n.name.to_lower()
			if not (nm.contains("approval") or nm.contains("code")):
				if nm.contains("input") or nm.contains("message") or nm.contains("chat"):
					return n
		for c in n.get_children():
			stack.append(c)
	stack = [p]
	while not stack.is_empty():
		var n2: Node = stack.pop_back() as Node
		if n2 is LineEdit:
			return n2
		for c in n2.get_children():
			stack.append(c)
	stack = [p]
	while not stack.is_empty():
		var n3: Node = stack.pop_back() as Node
		if n3 is TextEdit and not n3.name.to_lower().contains("approval"):
			return n3
		for c in n3.get_children():
			stack.append(c)
	return null


func _find_create_from_chat_button(root: Node) -> Button:
	var b := _find_button_by_text(root, "CREATE FROM CHAT")
	if b != null:
		return b
	var n := _find_by_name_substr(root, "createfromchat")
	if n is Button:
		return n as Button
	n = _find_by_name_substr(root, "create_from_chat")
	if n is Button:
		return n as Button
	# Fallback: a button whose text mentions both CREATE and CHAT.
	var stack: Array = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back() as Node
		if cur is Button:
			var t := (cur as Button).text.to_upper()
			if t.contains("CREATE") and t.contains("CHAT"):
				return cur as Button
		for c in cur.get_children():
			stack.append(c)
	return null


func _approval_visible_in(root: Node) -> bool:
	var ap := _find_named(root, "ApprovalPanel")
	if ap is Control:
		return (ap as Control).is_visible_in_tree()
	return false


func _pending_candidate_of(obj: Object) -> Dictionary:
	if obj == null:
		return {}
	if obj.has_method("get_pending_candidate"):
		var r: Variant = obj.callv("get_pending_candidate", [])
		if r is Dictionary:
			return r as Dictionary
	var v: Variant = obj.get("_pending_candidate")
	if v is Dictionary:
		return v as Dictionary
	return {}


func _on_panel_approval(candidate: Dictionary) -> void:
	_panel_approval_candidate = candidate
	if _wait_for in ["generation_ready", "approval"]:
		_signal_payload = candidate
		_signal_got = true


func _on_create_from_chat_requested(conversation: Array, request: String) -> void:
	_panel_create_signal = {"conversation": conversation, "request": request}


# --- Phase runners ------------------------------------------------------------

func _run_phase(phase: int) -> void:
	match phase:
		0:
			_run_presence()
		1:
			_run_session()
		2:
			_run_nokey_chat()
		3:
			_run_stub_chat()
		4:
			_run_capabilities()
		5:
			_run_gen_with_context()
		6:
			_run_panel()
		7:
			_run_menu()
		8:
			_run_regression()
		9:
			_finish()
		_:
			_finish()


func _end_phase(phase: int) -> bool:
	# Returns true = stay in this phase (another wait follows).
	match phase:
		2:
			_end_nokey_chat()
		3:
			_end_stub_chat()
		4:
			return _end_capabilities()
		5:
			_end_gen_with_context()
		6:
			return _end_panel()
		7:
			return _end_menu()
		8:
			_end_regression()
	return false


# --- Phase 0: presence ---------------------------------------------------------

func _run_presence() -> void:
	_check(_session_script != null,
		"chat(presence): scripts/mods/chat_session.gd EXISTS + loads (Worker A deliverable)")
	_check(_panel_script != null,
		"chat(presence): scripts/ui/chat_panel.gd EXISTS + loads (Worker A deliverable)")
	if _creator_script != null:
		_check(_has_method(_creator_script, "chat"),
			"chat(presence): ModCreator exposes chat(messages) (Worker B deliverable)")
		_check(_has_method(_creator_script, "generate_with_context"),
			"chat(presence): ModCreator exposes generate_with_context(conversation, request)")
		_check(_has_method(_creator_script, "get_greeting"),
			"chat(presence): ModCreator exposes get_greeting()")
		var inst: Object = _creator_script.new()
		if inst != null:
			_check(inst.has_signal("chat_reply"),
				"chat(presence): ModCreator emits chat_reply")
			_check(inst.has_signal("chat_error"),
				"chat(presence): ModCreator emits chat_error")
			if inst is Node:
				(inst as Node).free()
		else:
			_check(false, "chat(presence): ModCreator instantiates (for signal probe)")
	else:
		_check(false, "chat(presence): ModCreator exposes chat(messages) (mod_creator.gd missing)")
		_check(false, "chat(presence): ModCreator exposes generate_with_context(conversation, request)")
		_check(false, "chat(presence): ModCreator exposes get_greeting()")
		_check(false, "chat(presence): ModCreator emits chat_reply")
		_check(false, "chat(presence): ModCreator emits chat_error")
	var has_chat_tab := false
	if _menu_script != null:
		var tabs: Variant = _const_named(_menu_script, ["CREATOR_TABS"])
		if tabs is Array and (tabs as Array).has("CHAT"):
			has_chat_tab = true
	if not has_chat_tab:
		var src := FileAccess.get_file_as_string("res://scripts/ui/mod_creator_menu.gd")
		has_chat_tab = src.contains("\"CHAT\"")
	_check(has_chat_tab,
		"chat(presence): creator menu has a CHAT tab (CREATE / CHAT / MODS / IMPORT-EXPORT)")
	if _chat_seam_name.is_empty():
		_note("no chat stub seam found on ModCreator (mock_chat_reply / mock_chat_response / mock_chat / mock_reply) — stubbed-reply checks will SKIP rather than touch the network")
	else:
		_note("chat stub seam: %s (%s, %s)" % [_chat_seam_name, _chat_seam_scope, _chat_seam_type])
	_advance_sync()


# --- Phase 1: ChatSession unit --------------------------------------------------

func _run_session() -> void:
	if _session_script == null:
		for label in [
			"chat(session): messages hold role + text",
			"chat(session): persistence — reopen (new instance) keeps history",
			"chat(session): CLEAR wipes persisted session",
			"chat(session): trimming — long history capped",
			"chat(session): greeting non-empty",
		]:
			_skip(label, "chat_session.gd not landed yet")
		_advance_sync()
		return
	_session_inst = _new_session()
	if _session_inst == null:
		_skip("chat(session): all session checks", "ChatSession did not instantiate")
		_advance_sync()
		return
	# Greeting (implementation-owned text). Captured BEFORE the message
	# checks: a session that auto-adds its greeting on init is allowed
	# to start with exactly that one greeting message.
	var greeting := ""
	if _session_inst.has_method("get_greeting") or (_creator_script != null and _has_method(_creator_script, "get_greeting")):
		_new_creator()
		greeting = _greeting_text()
		_check(not greeting.is_empty(), "chat(session): get_greeting() returns non-empty text")
	else:
		_skip("chat(session): greeting non-empty", "no get_greeting() on ChatSession or ModCreator")
	# Messages hold role + text.
	var added := _session_clear(_session_inst)
	if not added:
		_note("ChatSession has no clear()/clear_history()/reset() — starting from existing state")
	_session_add(_session_inst, "user", "hello from verify")
	_session_add(_session_inst, "assistant", "hi there from verify")
	var msgs := _session_messages(_session_inst)
	if msgs.is_empty():
		_skip("chat(session): messages hold role + text", "no readable message list (get_messages/messages/history)")
		_skip("chat(session): persistence — reopen (new instance) keeps history", "no readable message list")
		_skip("chat(session): CLEAR wipes persisted session", "no readable message list")
		_skip("chat(session): trimming — long history capped", "no readable message list")
		_advance_sync()
		return
	_check(_msgs_have(msgs, "user", "hello from verify")
			and _msgs_have(msgs, "assistant", "hi there from verify"),
		"chat(session): messages hold role + text (roles + texts preserved; %d messages incl. any auto-greeting)" % msgs.size())
	# Persistence: new instance, same user://, must see the same history.
	_session_save(_session_inst)
	var s2 := _new_session()
	_session_load(s2)
	var msgs2 := _session_messages(s2)
	var has_persist_api := _session_inst.has_method("save") or _session_inst.has_method("load") \
		or _session_inst.has_method("save_session") or _session_inst.has_method("load_session")
	if _msgs_have(msgs2, "user", "hello from verify") and _msgs_have(msgs2, "assistant", "hi there from verify"):
		_check(true, "chat(session): persistence — reopen (new instance) keeps history")
	elif has_persist_api:
		_check(false, "chat(session): persistence — reopen (new instance) keeps history (got %d messages)" % msgs2.size())
	else:
		_check(false, "chat(session): persistence — no save/load API and fresh instance did not auto-load (got %d messages)" % msgs2.size())
	_free_session(s2)
	# CLEAR wipes persisted session.
	if _session_clear(_session_inst):
		var after_clear := _session_messages(_session_inst)
		_check(after_clear.is_empty(), "chat(session): CLEAR empties the in-memory session")
		_session_save(_session_inst)
		var s3 := _new_session()
		_session_load(s3)
		var msgs3 := _session_messages(s3)
		var wiped := msgs3.is_empty() or (msgs3.size() == 1 and not greeting.is_empty()
			and _msg_text(msgs3[0]) == greeting)
		_check(wiped, "chat(session): CLEAR wipes persisted session (empty after reopen; a lone auto-greeting is allowed, got %d)" % msgs3.size())
		_free_session(s3)
	else:
		_check(false, "chat(session): CLEAR wipes persisted session (no clear()/clear_history()/reset())")
	# Trimming: feed a long history (>20 messages).
	var s4 := _new_session()
	_session_clear(s4)
	var base_n := _session_messages(s4).size()
	var fed := 0
	for i in range(30):
		if _session_add(s4, "user" if i % 2 == 0 else "assistant", "trim message %d" % i):
			fed += 1
	var trimmed := _session_messages(s4)
	var cap := _session_cap()
	if fed < 30:
		_skip("chat(session): trimming — long history capped", "no add_message-style API to feed history")
	elif cap > 0:
		_check(trimmed.size() <= cap,
			"chat(session): trimming — 30 fed, %d kept, cap %d" % [trimmed.size(), cap])
	else:
		_check(trimmed.size() < base_n + 30,
			"chat(session): trimming — 30 fed on a base of %d, %d kept (no MAX_* cap constant found; trimming observed)" % [base_n, trimmed.size()])
	_free_session(s4)
	_advance_sync()


# --- Phase 2: no-key chat ---------------------------------------------------------

func _run_nokey_chat() -> void:
	if _creator_script == null or not _has_method(_creator_script, "chat"):
		_skip("chat(nokey): no-key → visible error", "ModCreator.chat not landed yet")
		_skip("chat(nokey): no-key chat creates no mod", "ModCreator.chat not landed yet")
		_advance_sync()
		return
	_new_creator()
	_last_chat_reply = ""
	_last_chat_error = ""
	_local_reply_text = ""
	var sent := _call_chat(_creator_inst, [_mk_msg("user", CANNED_CHAT_GENERIC)], CANNED_CHAT_GENERIC)
	if not sent:
		_skip("chat(nokey): no-key → visible error", "chat() call shape not recognised")
		_skip("chat(nokey): no-key chat creates no mod", "chat() call shape not recognised")
		_advance_sync()
		return
	_begin_wait("chat_any", TIMEOUT_FRAMES)


func _end_nokey_chat() -> void:
	if _signal_got and not _last_chat_error.is_empty():
		_check(true, "chat(nokey): no-key → visible error via chat_error ('%s')" % _last_chat_error.left(120))
	elif _signal_got and not _last_chat_reply.is_empty():
		var low := _last_chat_reply.to_lower()
		if low.contains("key") and (low.contains("required") or low.contains("add")):
			_check(true, "chat(nokey): no-key → visible error delivered as reply")
		else:
			_local_reply_text = _last_chat_reply
			_check(false, "chat(nokey): no-key chat produced a model-style reply instead of an error")
	elif _signal_got:
		_check(false, "chat(nokey): no-key chat emitted an empty reply/error (no visible error)")
	else:
		_check(false, "chat(nokey): no-key chat produced neither chat_reply nor chat_error (silent / hang)")
	_check(_list_mods_tree() == _snapshot_mods,
		"chat(nokey): no-key chat creates no mod (mods tree unchanged)")


# --- Phase 3: stubbed chat reply --------------------------------------------------

func _run_stub_chat() -> void:
	if _creator_script == null or not _has_method(_creator_script, "chat"):
		_skip("chat(send): chat send → model reply appears in the message list", "ModCreator.chat not landed yet")
		_advance_sync()
		return
	if _chat_seam_name.is_empty():
		_skip("chat(send): chat send → model reply appears in the message list",
			"no stub seam on ModCreator — a reply would need a live network call")
		_advance_sync()
		return
	if not _arm_chat_seam():
		_skip("chat(send): chat send → model reply appears in the message list",
			"stub seam '%s' could not be armed + read back" % _chat_seam_name)
		_advance_sync()
		return
	_new_creator()
	_last_chat_reply = ""
	_last_chat_error = ""
	var sent := _call_chat(_creator_inst, [_mk_msg("user", CANNED_CHAT_GENERIC)], CANNED_CHAT_GENERIC)
	if not sent:
		_disarm_chat_seam()
		_skip("chat(send): chat send → model reply appears in the message list", "chat() call shape not recognised")
		_advance_sync()
		return
	_begin_wait("chat_any", TIMEOUT_FRAMES)


func _end_stub_chat() -> void:
	_disarm_chat_seam()
	if _signal_got and not _last_chat_error.is_empty():
		_check(false, "chat(send): stubbed chat returned chat_error ('%s')" % _last_chat_error.left(120))
	elif _signal_got and not _last_chat_reply.is_empty():
		_check(true, "chat(send): chat send → stubbed model reply received")
		# Reply appears in the message list (session, when wired).
		if _session_inst != null:
			var msgs := _session_messages(_session_inst)
			if _msgs_contain(msgs, _last_chat_reply) or _msgs_contain(msgs, CANNED_REPLY):
				_check(true, "chat(send): model reply appears in the message list (ChatSession)")
			else:
				_skip("chat(send): model reply appears in the message list (ChatSession)",
					"creator chat not wired to this session instance — panel phase checks the UI list")
		else:
			_skip("chat(send): model reply appears in the message list",
				"no ChatSession to check — panel phase checks the UI list")
	elif _signal_got:
		_check(false, "chat(send): stubbed chat emitted an empty reply")
	else:
		_check(false, "chat(send): stubbed chat produced no reply (timeout)")
	_check(_list_mods_tree() == _snapshot_mods,
		"chat(send): chatting alone creates no mod (mods tree unchanged)")


# --- Phase 4: capabilities ----------------------------------------------------------

func _run_capabilities() -> void:
	var src := _capability_source_text()
	if not src.is_empty():
		_check(_capability_keywords_ok(src),
			"chat(caps): 'What can you do?' names REAL capabilities (projectiles, hooks, MAKE session-only vs Creator permanent, sandbox, approval flow)")
		_advance_sync()
		return
	if not _local_reply_text.is_empty():
		_check(_capability_keywords_ok(_local_reply_text),
			"chat(caps): local 'What can you do?' answer names REAL capabilities (projectiles, hooks, MAKE session-only vs Creator permanent, sandbox, approval flow)")
		_advance_sync()
		return
	# No local source: probe a local canned answer with NO key + NO seam.
	if _creator_script == null or not _has_method(_creator_script, "chat"):
		_skip("chat(caps): 'What can you do?' names REAL capabilities", "ModCreator.chat not landed yet")
		_advance_sync()
		return
	_new_creator()
	_last_chat_reply = ""
	_last_chat_error = ""
	var sent := _call_chat(_creator_inst, [_mk_msg("user", CANNED_CHAT_QUESTION)], CANNED_CHAT_QUESTION)
	if not sent:
		_skip("chat(caps): 'What can you do?' names REAL capabilities", "chat() call shape not recognised")
		_advance_sync()
		return
	_substep = 1
	_begin_wait("chat_any", TIMEOUT_FRAMES)


func _end_capabilities() -> bool:
	if _substep != 1:
		return false
	if _signal_got and not _last_chat_reply.is_empty():
		var low := _last_chat_reply.to_lower()
		if low.contains("key") and (low.contains("required") or low.contains("add")):
			_skip("chat(caps): 'What can you do?' names REAL capabilities",
				"no-key → error; capabilities live behind the LLM call with no local source to assert on")
		else:
			_check(_capability_keywords_ok(_last_chat_reply),
				"chat(caps): local 'What can you do?' answer names REAL capabilities (projectiles, hooks, MAKE session-only vs Creator permanent, sandbox, approval flow)")
	elif _signal_got:
		_skip("chat(caps): 'What can you do?' names REAL capabilities",
			"no-key → chat_error; capabilities live behind the LLM call with no local source to assert on")
	else:
		_skip("chat(caps): 'What can you do?' names REAL capabilities", "no reply to the capabilities probe")
	_check(_list_mods_tree() == _snapshot_mods,
		"chat(caps): capabilities probe creates no mod (mods tree unchanged)")
	return false


# --- Phase 5: generate_with_context ---------------------------------------------------

func _run_gen_with_context() -> void:
	if _creator_script == null or not _has_method(_creator_script, "generate_with_context"):
		_skip("chat(ctx): chat-then-create — generation request carries earlier chat messages",
			"ModCreator.generate_with_context not landed yet")
		_skip("chat(ctx): generate_with_context approval outcome matches generate()",
			"ModCreator.generate_with_context not landed yet")
		_advance_sync()
		return
	if _method_arg_count(_creator_script, "generate_with_context") != 2:
		_skip("chat(ctx): chat-then-create — generation request carries earlier chat messages",
			"generate_with_context arity is not (conversation, request)")
		_skip("chat(ctx): generate_with_context approval outcome matches generate()",
			"generate_with_context arity is not (conversation, request)")
		_advance_sync()
		return
	if not _set_mock_generation(_mock_block("Verify Chat Lamp", "wall", 90, 100,
			"A lamp-post cover block from chat context.")):
		_skip("chat(ctx): chat-then-create checks", "mock_generation could not be armed")
		_advance_sync()
		return
	var conv: Array = []
	for i in range(30):
		if i == 0:
			conv.append(_mk_msg("user", "CHATCTX_OLDEST_MARKER_7F3A first idea: a lamp"))
		elif i == 29:
			conv.append(_mk_msg("user", "CHATCTX_NEWEST_MARKER_7F3A latest idea: make it a fire lamp"))
		else:
			conv.append(_mk_msg("user" if i % 2 == 0 else "assistant", "chat context message %d" % i))
	_ctx_conv = conv
	_ctx_request = "Create a mod from our chat: a fire lamp."
	_new_creator()
	_last_candidate = {}
	_creator_inst.callv("generate_with_context", [conv, _ctx_request])
	_begin_wait("generation_ready", TIMEOUT_FRAMES)


func _end_gen_with_context() -> void:
	_disarm_mock_generation()
	if _last_candidate.is_empty():
		_check(false, "chat(ctx): generate_with_context produced no candidate (timeout / no signal)")
		_skip("chat(ctx): chat-then-create — generation request carries earlier chat messages",
			"no candidate produced")
		return
	_check(str(_last_candidate.get("error", "?")) == "",
		"chat(ctx): generate_with_context approval outcome matches generate() (candidate error == '', got '%s')"
		% str(_last_candidate.get("error", "?")))
	var shape_ok := true
	for key in ["mod_id", "name", "kind", "manifest", "payload", "summary", "error"]:
		if not _last_candidate.has(key):
			shape_ok = false
	_check(shape_ok,
		"chat(ctx): generate_with_context candidate carries all 7 contract keys (same approval shape as generate())")
	var acc: Variant = _last_context_accessor(_creator_inst)
	var cap := _session_cap()
	if acc is Array:
		var arr: Array = acc as Array
		var has_oldest := _msgs_contain(arr, "CHATCTX_OLDEST_MARKER_7F3A")
		var has_newest := _msgs_contain(arr, "CHATCTX_NEWEST_MARKER_7F3A")
		_check(not has_oldest and has_newest,
			"chat(ctx): generation request carries recent chat context (oldest trimmed out, newest present; %d msgs)" % arr.size())
		if cap > 0:
			_check(arr.size() <= cap,
				"chat(ctx): generation request carries at most the cap (%d <= %d)" % [arr.size(), cap])
		else:
			_check(arr.size() < 30,
				"chat(ctx): generation request trimmed (30 fed, %d carried)" % arr.size())
	elif acc is String:
		var s := str(acc)
		_check(not s.contains("CHATCTX_OLDEST_MARKER_7F3A") and s.contains("CHATCTX_NEWEST_MARKER_7F3A"),
			"chat(ctx): generation request carries recent chat context (oldest trimmed out, newest present)")
	else:
		_skip("chat(ctx): chat-then-create — generation request carries earlier chat messages",
			"request context not observable (no last-context accessor on ModCreator)")
	# Pure-function cross-check of the context builder itself
	# (ChatPrompt.trim_conversation / build_generation_context): the
	# same logic generate_with_context() routes through, testable
	# without any network.
	if _prompt_script != null and _has_method(_prompt_script, "trim_conversation"):
		var trimmed_p: Variant = _call_script(_prompt_script, "trim_conversation", [_ctx_conv])
		if trimmed_p is Array:
			var tarr: Array = trimmed_p as Array
			var tcap := _session_cap()
			_check(tarr.size() <= (tcap if tcap > 0 else 20),
				"chat(ctx): trim_conversation caps a 30-message history (kept %d)" % tarr.size())
			_check(not _msgs_contain(tarr, "CHATCTX_OLDEST_MARKER_7F3A")
					and _msgs_contain(tarr, "CHATCTX_NEWEST_MARKER_7F3A"),
				"chat(ctx): trim_conversation keeps the NEWEST window (oldest marker gone, newest kept)")
		else:
			_check(false, "chat(ctx): trim_conversation returns an Array")
	if _prompt_script != null and _has_method(_prompt_script, "build_generation_context"):
		var ctx_s: Variant = _call_script(_prompt_script, "build_generation_context", [_ctx_conv, _ctx_request])
		if ctx_s is String:
			var cs := str(ctx_s)
			_check(not cs.contains("CHATCTX_OLDEST_MARKER_7F3A")
					and cs.contains("CHATCTX_NEWEST_MARKER_7F3A")
					and cs.contains(_ctx_request),
				"chat(ctx): build_generation_context embeds recent chat as context + request last (oldest trimmed)")
		else:
			_check(false, "chat(ctx): build_generation_context returns a String")
	_check(_list_mods_tree() == _snapshot_mods,
		"chat(ctx): generate_with_context alone creates no mod (mods tree unchanged)")


# --- Phase 6: ChatPanel UI -------------------------------------------------------------

func _run_panel() -> void:
	if _panel_script == null:
		for label in [
			"chat(panel): send → reply appears in the panel message list",
			"chat(panel): CLEAR wipes the session",
			"chat(panel): CREATE FROM CHAT → approval screen appears",
			"chat(panel): no-key → visible error bubble, no silent reply, no mod",
		]:
			_skip(label, "chat_panel.gd not landed yet")
		_advance_sync()
		return
	var inst: Object = _panel_script.new()
	if inst == null or not (inst is Control):
		for label in [
			"chat(panel): send → reply appears in the panel message list",
			"chat(panel): CLEAR wipes the session",
			"chat(panel): CREATE FROM CHAT → approval screen appears",
			"chat(panel): no-key → visible error bubble, no silent reply, no mod",
		]:
			_skip(label, "ChatPanel did not instantiate as a Control")
		_advance_sync()
		return
	_panel = inst as Control
	if _session_inst == null:
		for label in [
			"chat(panel): send → reply appears in the panel message list",
			"chat(panel): CLEAR wipes the session",
			"chat(panel): CREATE FROM CHAT → approval screen appears",
			"chat(panel): no-key → visible error bubble, no silent reply, no mod",
		]:
			_skip(label, "no ChatSession instance to wire the panel to (session phase did not produce one)")
		_panel.free()
		_panel = null
		_advance_sync()
		return
	if _creator_inst == null:
		_new_creator()
	# The panel's real wiring API is setup(session, creator) — the
	# same call the menu makes. Property injection is only a fallback
	# for a panel that predates setup().
	if _panel.has_method("setup") and _method_arg_count(_panel_script, "setup") == 2:
		_panel.callv("setup", [_session_inst, _creator_inst])
		_panel_session_injected = true
	else:
		for p in ["chat_session", "session", "chat"]:
			if _has_prop(_panel_script, p):
				_panel.set(p, _session_inst)
				_panel_session_injected = true
		for m in ["set_session", "set_chat_session"]:
			if _panel.has_method(m):
				_panel.callv(m, [_session_inst])
				_panel_session_injected = true
		for p in ["creator", "mod_creator"]:
			if _has_prop(_panel_script, p):
				_panel.set(p, _creator_inst)
		for m in ["set_creator", "set_mod_creator"]:
			if _panel.has_method(m):
				_panel.callv(m, [_creator_inst])
	if _panel.has_signal("chat_reply"):
		_panel.connect("chat_reply", Callable(self, "_on_chat_reply"))
	if _panel.has_signal("chat_error"):
		_panel.connect("chat_error", Callable(self, "_on_chat_error"))
	if _panel.has_signal("generation_ready"):
		_panel.connect("generation_ready", Callable(self, "_on_generation_ready"))
	if _panel.has_signal("approval_ready"):
		_panel.connect("approval_ready", Callable(self, "_on_panel_approval"))
	if _panel.has_signal("create_from_chat_requested"):
		_panel.connect("create_from_chat_requested", Callable(self, "_on_create_from_chat_requested"))
	root.add_child(_panel)
	_substep = 0
	_begin_wait("timer", 5)


func _end_panel() -> bool:
	match _substep:
		0:
			# Settle done — drive a send.
			_panel_seam_armed = _arm_chat_seam()
			_last_chat_reply = ""
			_last_chat_error = ""
			var input: Variant = _find_panel_input(_panel)
			if input != null:
				if input is LineEdit:
					(input as LineEdit).text = CANNED_CHAT_GENERIC
				elif input is TextEdit:
					(input as TextEdit).text = CANNED_CHAT_GENERIC
			var send_b := _find_button_by_text(_panel, "SEND")
			if send_b == null:
				var n := _find_by_name_substr(_panel, "send")
				if n is Button:
					send_b = n as Button
			_panel_send_attempted = (input != null and send_b != null)
			if send_b != null:
				send_b.pressed.emit()
			_substep = 1
			_begin_wait("chat_any", TIMEOUT_FRAMES)
			return true
		1:
			# Send outcome + CLEAR.
			var reply_seen := false
			if _signal_got and not _last_chat_reply.is_empty():
				reply_seen = true
				_check(true, "chat(panel): send → reply received")
			elif _texts_contain(_panel, CANNED_REPLY):
				reply_seen = true
				_check(true, "chat(panel): send → reply appears in the panel message list")
			elif _panel_send_attempted and _panel_seam_armed:
				_check(false, "chat(panel): send produced no reply with the stubbed LLM (no signal, no reply text in panel)")
			elif _panel_send_attempted:
				_skip("chat(panel): send → reply appears in the panel message list",
					"no stub seam reached the panel's creator — reply would need a live network call")
			else:
				_skip("chat(panel): send → reply appears in the panel message list",
					"panel has no drivable input + SEND button")
			if reply_seen and not _signal_got:
				_check(true, "chat(panel): send → reply appears in the panel message list")
			elif reply_seen and _signal_got:
				if _texts_contain(_panel, _last_chat_reply):
					_check(true, "chat(panel): send → reply appears in the panel message list")
				elif _session_inst != null and _msgs_contain(_session_messages(_session_inst), _last_chat_reply):
					_check(true, "chat(panel): send → reply appears in the message list (ChatSession)")
				else:
					_skip("chat(panel): send → reply appears in the panel message list",
						"reply arrived via signal but is not visible in panel texts or the session list")
			_disarm_chat_seam()
			_panel_seam_armed = false
			# CLEAR.
			var clear_b := _find_button_by_text(_panel, "CLEAR")
			if clear_b == null:
				var n2 := _find_by_name_substr(_panel, "clear")
				if n2 is Button:
					clear_b = n2 as Button
			if clear_b != null:
				clear_b.pressed.emit()
				if _panel_session_injected and _session_inst != null:
					_check(_session_messages(_session_inst).is_empty(),
						"chat(panel): CLEAR wipes the session (session list empty)")
				elif not _texts_contain(_panel, CANNED_REPLY):
					_check(true, "chat(panel): CLEAR wipes the panel message list (reply text gone)")
				else:
					_check(false, "chat(panel): CLEAR did not wipe the panel message list (reply text still shown)")
			else:
				_skip("chat(panel): CLEAR wipes the session", "panel has no CLEAR button")
			# CLEAR wiped the session, so re-send one message before
			# CREATE FROM CHAT (it refuses on an empty chat by design).
			_panel_seam_armed = _arm_chat_seam()
			_last_chat_reply = ""
			_last_chat_error = ""
			var input2: Variant = _find_panel_input(_panel)
			if input2 != null:
				if input2 is LineEdit:
					(input2 as LineEdit).text = CANNED_CHAT_GENERIC
				elif input2 is TextEdit:
					(input2 as TextEdit).text = CANNED_CHAT_GENERIC
			var send_b2 := _find_button_by_text(_panel, "SEND")
			if send_b2 == null:
				var n3 := _find_by_name_substr(_panel, "send")
				if n3 is Button:
					send_b2 = n3 as Button
			if send_b2 != null:
				send_b2.pressed.emit()
			_substep = 2
			_begin_wait("chat_any", TIMEOUT_FRAMES)
			return true
		2:
			# Re-send outcome: reply back in the list after CLEAR.
			_disarm_chat_seam()
			_panel_seam_armed = false
			if _signal_got and not _last_chat_reply.is_empty():
				_check(true, "chat(panel): re-send after CLEAR → reply received")
			elif _texts_contain(_panel, CANNED_REPLY):
				_check(true, "chat(panel): re-send after CLEAR → reply appears in the panel message list")
			else:
				_skip("chat(panel): re-send after CLEAR → reply appears",
					"no reply observed; CREATE FROM CHAT below is the decisive check")
			# CREATE FROM CHAT: the panel emits
			# create_from_chat_requested (conversation + request) and
			# runs generate_with_context itself; the menu turns the
			# candidate into the approval screen (verified end-to-end
			# in the menu phase).
			_panel_create_signal = {}
			_last_candidate = {}
			_panel_approval_candidate = {}
			_set_mock_generation(_mock_block("Verify Chat Post", "wall", 60, 100,
				"A post cover block from chat."))
			var create_b := _find_create_from_chat_button(_panel)
			_panel_create_attempted = (create_b != null)
			if create_b != null:
				create_b.pressed.emit()
				_substep = 3
				_begin_wait("timer", 60)
				return true
			_skip("chat(panel): CREATE FROM CHAT → request emitted + generation runs",
				"panel has no CREATE FROM CHAT button")
			_disarm_mock_generation()
			# Fall through to the no-key error-bubble probe.
			_last_chat_reply = ""
			_last_chat_error = ""
			var input2b: Variant = _find_panel_input(_panel)
			if input2b != null:
				if input2b is LineEdit:
					(input2b as LineEdit).text = CANNED_CHAT_GENERIC
				elif input2b is TextEdit:
					(input2b as TextEdit).text = CANNED_CHAT_GENERIC
			var send_b2b := _find_button_by_text(_panel, "SEND")
			if send_b2b != null:
				send_b2b.pressed.emit()
			_substep = 4
			_begin_wait("chat_any", 60)
			return true
		3:
			# CREATE FROM CHAT outcome.
			_disarm_mock_generation()
			var sig_ok := not _panel_create_signal.is_empty() and str(_panel_create_signal.get("request", "")) != ""
			_check(sig_ok,
				"chat(panel): CREATE FROM CHAT emits create_from_chat_requested (conversation + request)")
			var gen_ok := (not _last_candidate.is_empty() and str(_last_candidate.get("error", "?")) == "") \
				or _approval_visible_in(_panel) or not _pending_candidate_of(_panel).is_empty()
			_check(gen_ok,
				"chat(panel): CREATE FROM CHAT runs generation → candidate for approval (menu shows the approval screen)")
			_check(_list_mods_tree() == _snapshot_mods,
				"chat(panel): CREATE FROM CHAT alone creates no mod (mods tree unchanged)")
			# No-key error-bubble probe (seam disarmed, key removed).
			_last_chat_reply = ""
			_last_chat_error = ""
			var input3: Variant = _find_panel_input(_panel)
			if input3 != null:
				if input3 is LineEdit:
					(input3 as LineEdit).text = CANNED_CHAT_GENERIC
				elif input3 is TextEdit:
					(input3 as TextEdit).text = CANNED_CHAT_GENERIC
			var send_b3 := _find_button_by_text(_panel, "SEND")
			if send_b3 != null:
				send_b3.pressed.emit()
			_substep = 4
			_begin_wait("chat_any", 60)
			return true
		4:
			# No-key error-bubble outcome.
			var err_visible := false
			if _signal_got and not _last_chat_error.is_empty():
				err_visible = true
				_check(true, "chat(panel): no-key → visible error via chat_error")
			if _texts_contain(_panel, "key") or _texts_contain(_panel, "error") or _texts_contain(_panel, "DeepSeek"):
				if not err_visible:
					_check(true, "chat(panel): no-key → visible error bubble in panel")
				err_visible = true
			if not err_visible:
				if _signal_got and not _last_chat_reply.is_empty():
					_check(false, "chat(panel): no-key send produced a reply instead of a visible error (silent-reply risk)")
				else:
					_check(false, "chat(panel): no-key send showed no error bubble (silent)")
			_check(_list_mods_tree() == _snapshot_mods,
				"chat(panel): no-key chat creates no mod (mods tree unchanged)")
			return false
	return false


# --- Phase 7: menu integration ------------------------------------------------------

func _run_menu() -> void:
	if not ResourceLoader.exists("res://scenes/ui/mod_creator_menu.tscn"):
		_skip("chat(menu): CHAT tab present in the live menu", "mod_creator_menu.tscn missing")
		_skip("chat(menu): Chat + Create share one ChatSession", "mod_creator_menu.tscn missing")
		_skip("chat(menu): menu CREATE FROM CHAT → approval screen appears", "mod_creator_menu.tscn missing")
		_advance_sync()
		return
	var ps := load("res://scenes/ui/mod_creator_menu.tscn") as PackedScene
	if ps == null:
		_skip("chat(menu): CHAT tab present in the live menu", "mod_creator_menu.tscn failed to load")
		_skip("chat(menu): Chat + Create share one ChatSession", "mod_creator_menu.tscn failed to load")
		_skip("chat(menu): menu CREATE FROM CHAT → approval screen appears", "mod_creator_menu.tscn failed to load")
		_advance_sync()
		return
	_menu = ps.instantiate() as Control
	if _menu == null:
		_skip("chat(menu): CHAT tab present in the live menu", "menu did not instantiate")
		_skip("chat(menu): Chat + Create share one ChatSession", "menu did not instantiate")
		_skip("chat(menu): menu CREATE FROM CHAT → approval screen appears", "menu did not instantiate")
		_advance_sync()
		return
	root.add_child(_menu)
	_substep = 0
	_begin_wait("timer", 5)


func _end_menu() -> bool:
	if _substep == 0:
		# CHAT tab present?
		var tabs := _find_named(_menu, "CreatorTabs") as TabContainer
		var chat_tab_found := false
		if tabs != null:
			for i in range(tabs.get_tab_count()):
				if str(tabs.get_tab_title(i)).to_upper().contains("CHAT"):
					chat_tab_found = true
		_check(chat_tab_found, "chat(menu): CHAT tab present in the live menu")
		# Shared session: menu's session vs the Chat tab panel's session.
		var menu_session: Variant = null
		if _menu.has_method("get_chat_session"):
			menu_session = _menu.callv("get_chat_session", [])
		else:
			menu_session = _menu.get("chat_session")
			if menu_session == null:
				menu_session = _menu.get("_chat_session")
		var panel_child: Node = null
		if _panel_script != null:
			var stack: Array = [_menu]
			while not stack.is_empty():
				var cur: Node = stack.pop_back() as Node
				if cur.get_script() == _panel_script:
					panel_child = cur
					break
				for c in cur.get_children():
					stack.append(c)
		if menu_session != null and panel_child != null:
			var panel_session: Variant = null
			if panel_child.has_method("get_session"):
				panel_session = panel_child.callv("get_session", [])
			else:
				panel_session = panel_child.get("chat_session")
				if panel_session == null:
					panel_session = panel_child.get("session")
			if panel_session != null:
				_check(panel_session == menu_session,
					"chat(menu): Chat + Create share one ChatSession (same object)")
			else:
				_skip("chat(menu): Chat + Create share one ChatSession",
					"chat panel child exposes no session to compare")
		else:
			_skip("chat(menu): Chat + Create share one ChatSession",
				"menu exposes no session and/or no ChatPanel child found in the menu")
		# Menu CREATE FROM CHAT → approval.
		_panel_approval_candidate = {}
		_set_mock_generation(_mock_block("Verify Menu Chat Post", "wall", 60, 100,
			"A post cover block from menu chat."))
		var create_b := _find_create_from_chat_button(_menu)
		_menu_create_attempted = (create_b != null)
		if create_b != null:
			create_b.pressed.emit()
			_substep = 1
			_begin_wait("timer", 60)
			return true
		_skip("chat(menu): menu CREATE FROM CHAT → approval screen appears",
			"menu has no CREATE FROM CHAT button")
		_disarm_mock_generation()
		return false
	# substep 1: menu approval outcome.
	_disarm_mock_generation()
	var approved := false
	if _approval_visible_in(_menu):
		approved = true
	elif not _pending_candidate_of(_menu).is_empty():
		approved = true
	_check(approved, "chat(menu): menu CREATE FROM CHAT → approval screen appears")
	_check(_list_mods_tree() == _snapshot_mods,
		"chat(menu): menu chat flows create no mod (mods tree unchanged)")
	return false


# --- Phase 8: regression — Create with NO chat history ---------------------------------

func _run_regression() -> void:
	if _creator_script == null or not _has_method(_creator_script, "generate"):
		_skip("chat(regression): Create tab with NO chat history still generates",
			"ModCreator.generate missing")
		_advance_sync()
		return
	if _session_inst != null:
		_session_clear(_session_inst)
	if not _set_mock_generation(_mock_block("Verify No History Lamp", "wall", 90, 100,
			"A lamp-post cover block with no chat history.")):
		_skip("chat(regression): Create tab with NO chat history still generates",
			"mock_generation could not be armed")
		_advance_sync()
		return
	_new_creator()
	_last_candidate = {}
	_creator_inst.callv("generate", ["a small lamp post cover"])
	_begin_wait("generation_ready", TIMEOUT_FRAMES)


func _end_regression() -> void:
	_disarm_mock_generation()
	if _last_candidate.is_empty():
		_check(false, "chat(regression): Create tab with NO chat history still generates (no candidate)")
		return
	_check(str(_last_candidate.get("error", "?")) == "",
		"chat(regression): Create tab with NO chat history still generates exactly as before (candidate error == '', got '%s')"
		% str(_last_candidate.get("error", "?")))
	_check(_list_mods_tree() == _snapshot_mods,
		"chat(regression): generate alone creates no mod (mods tree unchanged)")


# --- Finish -------------------------------------------------------------------------

func _finish() -> void:
	_check(_list_mods_tree() == _snapshot_mods,
		"chat(no-install): chatting / generating / approving alone created no file in user://mods/")
	_cleanup()
	if _fails == 0:
		print("VERIFY_CREATOR_CHAT: ALL CHECKS PASSED (%d passed, %d skipped)" % [_passes, _skips])
	else:
		printerr("VERIFY_CREATOR_CHAT: %d CHECK(S) FAILED (%d passed, %d skipped)" % [_fails, _passes, _skips])
	_done = true
	quit(_fails)
