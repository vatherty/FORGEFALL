# FORGEFALL — ChatPanel (v0.5.4, Worker A: Chat UI + session)
# The CHAT tab of the Mod Creator menu. Conversation UI ONLY — it never
# installs anything. Creation goes only through the existing
# generation -> validation -> approval -> Install path:
# CREATE FROM CHAT calls ModCreator.generate_with_context() (Worker B),
# whose candidate lands on the CREATE tab's approval screen.
#
# - Scrollable message list: user bubbles (orange edge, "YOU"),
#   assistant bubbles (gunmetal edge, "FORGE"), error bubbles (red
#   edge, "ERROR"). Full-width bubbles with word wrap, so text stays
#   readable at phone and Deck (1280x800) sizes; roles are told apart
#   by edge colour + role label, not by left/right alignment.
# - Suggested prompt chips INSERT text into the input (they do not send).
#   Includes "What can you do?".
# - SEND calls ModCreator.chat(session.get_messages()) (Worker B's side
#   emits chat_reply / chat_error). Errors surface as a RED error bubble
#   in the chat — never a silent template reply, never persisted.
# - CLEAR / NEW CHAT wipes the shared ChatSession (memory + file).
# - Error bubbles are display-only: they are NOT added to the session,
#   so they can never pollute the model context or the persisted file.
#
# Worker B contract: this panel calls the creator ONLY through
# Object.call("chat", ...) / Object.call("generate_with_context", ...)
# guarded by has_method/has_signal, so the panel compiles and runs
# even before Worker B's methods land (missing backend -> visible
# red error bubble, never a crash).
extends VBoxContainer
class_name ChatPanel

signal create_from_chat_requested(conversation: Array, request: String)

## Suggested prompts. Chips INSERT the text into the input; they do
## not send. "What can you do?" is REQUIRED to be present.
const SUGGESTED_PROMPTS: Array[String] = [
	"What can you do?",
	"Make me a watermelon LMG",
	"Suggest a fun weapon mod",
	"Explain how mod approval works",
]

const _MISSING_CHAT_ERROR := "Chat is unavailable — the chat backend is not ready yet."
const _MISSING_GENERATE_ERROR := "Creation from chat is unavailable — the generation backend is not ready yet."

var _session: ChatSession = null
var _creator: ModCreator = null
var _messages_scroll: ScrollContainer
var _messages_list: VBoxContainer
var _chips_row: FlowContainer
var _input: LineEdit
var _send_button: Button
var _clear_button: Button
var _create_button: Button
var _status: Label
var _built := false
var _signals_connected := false
var _waiting := false
var _epoch := 0
var _pending_epoch := -1
var _bubble_seq := 0


func _ready() -> void:
	_build()


## Wires the panel to the menu-owned session + creator. The menu passes
## the SAME ChatSession the CREATE tab uses, and the SAME ModCreator
## instance the CREATE tab generates with. Safe to call before or after
## _ready; safe to call once.
func setup(session: ChatSession, creator: ModCreator) -> void:
	_session = session
	_creator = creator
	_connect_creator_signals()
	if _built:
		_rebuild_messages()


func get_session() -> ChatSession:
	return _session


## Number of rendered bubbles (user + assistant + error). Test seam.
func get_bubble_count() -> int:
	if _messages_list == null:
		return 0
	return _messages_list.get_child_count()


func get_input_text() -> String:
	if _input == null:
		return ""
	return _input.text


func set_input_text(text: String) -> void:
	if _input != null:
		_input.text = text


## Sends `text` as the user (same path as typing + SEND). Test seam.
func send_text(text: String) -> void:
	if _input != null:
		_input.text = text
	_on_send_pressed()


## Clears the shared session + the rendered list. Test seam.
func clear_chat() -> void:
	_on_clear_pressed()


## Re-renders the message list from the session (v0.5.9: the menu
## calls this after seeding an EDIT, so the "Editing '…'" assistant
## bubble appears without reopening the tab).
func refresh_messages() -> void:
	_rebuild_messages()


## Shows a red error bubble WITHOUT persisting it to the session.
## The menu uses this for generation errors from CREATE FROM CHAT.
func show_error(message: String) -> void:
	_add_bubble("error", message.strip_edges())


func _connect_creator_signals() -> void:
	if _signals_connected or _creator == null:
		return
	_signals_connected = true
	if _creator.has_signal("chat_reply"):
		_creator.connect("chat_reply", _on_chat_reply)
	if _creator.has_signal("chat_error"):
		_creator.connect("chat_error", _on_chat_error)


func _build() -> void:
	if _built:
		return
	_built = true
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 800)
	if vp.x <= 0.0 or vp.y <= 0.0:
		vp = Vector2(1280, 800)
	var body_font := UiScale.scaled_font(18, vp)
	var small_font := UiScale.scaled_font(16, vp)
	add_theme_constant_override("separation", 8)
	# Message list (expands to fill the tab).
	_messages_scroll = ScrollContainer.new()
	_messages_scroll.name = "MessagesScroll"
	_messages_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_messages_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_messages_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_messages_scroll)
	_messages_list = VBoxContainer.new()
	_messages_list.name = "MessagesList"
	_messages_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages_list.add_theme_constant_override("separation", 8)
	_messages_scroll.add_child(_messages_list)
	# Suggested prompt chips — INSERT text into the input, never send.
	_chips_row = FlowContainer.new()
	_chips_row.name = "ChipsRow"
	_chips_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_chips_row)
	for i in SUGGESTED_PROMPTS.size():
		var chip := Button.new()
		chip.name = "Chip_%d" % i
		chip.text = SUGGESTED_PROMPTS[i]
		StencilStyle.style_button(chip)
		chip.add_theme_font_size_override("font_size", small_font)
		chip.pressed.connect(_on_chip_pressed.bind(SUGGESTED_PROMPTS[i]))
		_chips_row.add_child(chip)
	# Input row: text box + SEND (Enter also sends).
	var input_row := HBoxContainer.new()
	input_row.name = "InputRow"
	add_child(input_row)
	_input = LineEdit.new()
	_input.name = "ChatInput"
	_input.placeholder_text = "Ask about mods, or describe one to build…"
	_input.clear_button_enabled = true
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_input)
	_input.text_submitted.connect(_on_input_submitted)
	input_row.add_child(_input)
	_send_button = Button.new()
	_send_button.name = "SendButton"
	_send_button.text = "SEND"
	StencilStyle.style_button(_send_button)
	_send_button.pressed.connect(_on_send_pressed)
	input_row.add_child(_send_button)
	# Action row: CLEAR / NEW CHAT + CREATE FROM CHAT.
	var action_row := HBoxContainer.new()
	action_row.name = "ActionRow"
	add_child(action_row)
	_clear_button = Button.new()
	_clear_button.name = "ClearButton"
	_clear_button.text = "CLEAR / NEW CHAT"
	_clear_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_button(_clear_button)
	_clear_button.pressed.connect(_on_clear_pressed)
	action_row.add_child(_clear_button)
	_create_button = Button.new()
	_create_button.name = "CreateFromChatButton"
	_create_button.text = "CREATE FROM CHAT"
	_create_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_button(_create_button)
	_create_button.pressed.connect(_on_create_from_chat_pressed)
	action_row.add_child(_create_button)
	_status = Label.new()
	_status.name = "ChatStatus"
	_status.text = ""
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_status, small_font, StencilStyle.TEXT_DIM, 2)
	add_child(_status)
	# Font size for bubbles is stored on the list for _add_bubble.
	_messages_list.set_meta("body_font", body_font)
	_messages_list.set_meta("small_font", small_font)
	_rebuild_messages()


## Re-renders the whole list from the session (setup + CLEAR). Error
## bubbles are transient, so a rebuild drops them by design. When the
## session is EMPTY, a display-only greeting bubble is shown (the
## creator's get_greeting(), Worker B's opening message) — it is
## NEVER added to the session, so it can never reach the model or
## the persisted file.
func _rebuild_messages() -> void:
	if _messages_list == null:
		return
	for child in _messages_list.get_children():
		_messages_list.remove_child(child)
		child.queue_free()
	if _session == null:
		return
	for m in _session.get_messages():
		if m is Dictionary:
			_add_bubble(str((m as Dictionary).get("role", "")), str((m as Dictionary).get("text", "")))
	if _session.is_empty() and _creator != null and _creator.has_method("get_greeting"):
		var greeting := str(_creator.call("get_greeting"))
		if not greeting.strip_edges().is_empty():
			_add_bubble("assistant", greeting)
			var last := _messages_list.get_child(_messages_list.get_child_count() - 1)
			last.name = "BubbleGreeting_%d" % _bubble_seq


func _add_bubble(role: String, text: String) -> void:
	if _messages_list == null or text.is_empty():
		return
	var body_font: int = int(_messages_list.get_meta("body_font", 18))
	var small_font: int = int(_messages_list.get_meta("small_font", 16))
	var bubble := PanelContainer.new()
	_bubble_seq += 1
	match role:
		"user":
			bubble.name = "BubbleUser_%d" % _bubble_seq
		"assistant":
			bubble.name = "BubbleAssistant_%d" % _bubble_seq
		_:
			bubble.name = "BubbleError_%d" % _bubble_seq
	bubble.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StencilStyle.panel(StencilStyle.BG_SOFT, StencilStyle.GUNMETAL, 1)
	sb.border_width_left = 4
	match role:
		"user":
			sb.border_color = StencilStyle.ORANGE
		"assistant":
			sb.border_color = StencilStyle.GUNMETAL
		_:
			sb.border_color = StencilStyle.RED
	bubble.add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bubble.add_child(col)
	var role_lbl := Label.new()
	role_lbl.name = "BubbleRole"
	match role:
		"user":
			role_lbl.text = "YOU"
			StencilStyle.apply_body(role_lbl, small_font, StencilStyle.ORANGE, 2)
		"assistant":
			role_lbl.text = "FORGE"
			StencilStyle.apply_body(role_lbl, small_font, StencilStyle.TEXT_DIM, 2)
		_:
			role_lbl.text = "ERROR"
			StencilStyle.apply_body(role_lbl, small_font, StencilStyle.RED, 2)
	col.add_child(role_lbl)
	var body := Label.new()
	body.name = "BubbleText"
	body.text = text
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if role == "error":
		StencilStyle.apply_body(body, body_font, StencilStyle.RED, 2)
	else:
		StencilStyle.apply_body(body, body_font, StencilStyle.TEXT, 2)
	col.add_child(body)
	_messages_list.add_child(bubble)
	call_deferred("_scroll_to_bottom")


func _scroll_to_bottom() -> void:
	if _messages_scroll == null:
		return
	var bar := _messages_scroll.get_v_scroll_bar()
	if bar != null:
		_messages_scroll.scroll_vertical = int(bar.max_value)


func _set_waiting(waiting: bool) -> void:
	_waiting = waiting
	if _send_button != null:
		_send_button.disabled = waiting
	if _create_button != null:
		_create_button.disabled = waiting
	if _status != null:
		_status.text = "Waiting for a reply…" if waiting else _status.text


func _on_chip_pressed(prompt: String) -> void:
	if _input != null:
		_input.text = prompt
		_input.grab_focus()


func _on_input_submitted(_text: String) -> void:
	_on_send_pressed()


func _on_send_pressed() -> void:
	if _input == null or _session == null:
		return
	if _waiting:
		return
	var text := _input.text.strip_edges()
	if text.is_empty():
		return
	_session.add_user(text)
	_add_bubble("user", text)
	_input.text = ""
	_pending_epoch = _epoch
	_set_waiting(true)
	_status.text = "Waiting for a reply…"
	if _creator == null or not _creator.has_method("chat"):
		_add_bubble("error", _MISSING_CHAT_ERROR)
		_set_waiting(false)
		_status.text = _MISSING_CHAT_ERROR
		return
	_creator.call("chat", _session.get_messages())


func _on_chat_reply(text: String) -> void:
	# A CLEAR / NEW CHAT since this send voids the stale reply.
	if _pending_epoch != _epoch:
		return
	_set_waiting(false)
	_status.text = ""
	if _session == null:
		return
	var clean := text.strip_edges()
	if clean.is_empty():
		return
	_session.add_assistant(clean)
	_add_bubble("assistant", clean)


func _on_chat_error(message: String) -> void:
	if _pending_epoch != _epoch:
		return
	_set_waiting(false)
	# Error bubbles are DISPLAY-ONLY — never added to the session, so
	# the error can never pollute the model context or the saved file.
	var clean := message.strip_edges()
	if clean.is_empty():
		clean = "Chat failed."
	_add_bubble("error", clean)
	_status.text = clean


func _on_clear_pressed() -> void:
	_epoch += 1
	_pending_epoch = -1
	_set_waiting(false)
	if _session != null:
		_session.clear()
	_rebuild_messages()
	if _status != null:
		_status.text = "Chat cleared — start a new conversation."


func _on_create_from_chat_pressed() -> void:
	if _session == null or _session.is_empty():
		if _status != null:
			_status.text = "Chat first — send a message, then CREATE FROM CHAT."
		return
	if _waiting:
		return
	var conversation := _session.get_messages()
	var request := _session.last_user_request()
	# Backend check FIRST: only emit (and only mark the menu pending)
	# when a real generation is about to start. Otherwise a missing
	# backend would leave the menu's _generating flag stuck on.
	if _creator == null or not _creator.has_method("generate_with_context"):
		_add_bubble("error", _MISSING_GENERATE_ERROR)
		if _status != null:
			_status.text = _MISSING_GENERATE_ERROR
		return
	# Let the menu mark this as a chat-driven generation (pending
	# state, Regenerate path), then run the generation itself.
	create_from_chat_requested.emit(conversation, request)
	# v0.5.9 EDIT: the original mod's payload rides along, so the
	# model refines THAT mod. The emitted request stays raw (the
	# menu stores it for REGENERATE, which prepends at call time) —
	# only this direct call carries the preamble.
	var effective := request
	if _session != null and _session.is_editing():
		effective = ChatSession.edit_preamble(_session.get_edit_context()) + "\n\n" + request
	if _status != null:
		_status.text = "Generating from chat — review it on the CREATE tab…"
	_creator.call("generate_with_context", conversation, effective)
