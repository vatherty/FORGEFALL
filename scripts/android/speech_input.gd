# res://scripts/android/speech_input.gd
# FORGEFALL — Worker 9 (Android + touch) + Worker C (v0.6.0 MIC)
#            + Worker E (Forge batch item 9: VOICE FORGING V2)
#
# Voice-to-Forge prompter (the MIC touch button + the Forge menu MIC feed this).
#
# v0.6.0: voice input is REAL on Android via the ForgeSpeech plugin
# (~/workspace/forgefall-plugin/ForgeSpeech/, manual-AAR build, no Gradle):
#   PLUGIN PATH — the Engine singleton "ForgeSpeech" drives Android's
#   SpeechRecognizer; the final transcript arrives on its onResult(text)
#   signal and is delivered to the listen() callback, which submits it to
#   Forge. RECORD_AUDIO is requested at runtime first (Android 6+):
#   OS.request_permission() returns true when already granted (Godot docs),
#   otherwise the answer arrives via MainLoop.on_request_permissions_result
#   — grant auto-starts listening, denial falls back. The plugin itself
#   never requests permissions; it emits onResult("") on any recognition
#   failure, which this file treats as "no result" and falls back.
#   TYPED FALLBACK — always available: shows a VISIBLE toast
#   ("Voice input isn't available yet — type your prompt", routed
#   through the existing Forge forge_result feedback so the HUD feed
#   and Forge menu both display it) and THEN presses the
#   contract-frozen "forge_console" input action, opening the typed
#   Forge console (worker 6). The console is NEVER opened silently:
#   the user always sees why they got a keyboard instead of voice.
#   The callback is NOT invoked on this path (no text to deliver).
#   Callers that ALREADY show a text field (the Forge menu's own MIC
#   button) pass press_console_on_fallback=false so the fallback only
#   toasts and never toggles the menu closed via forge_console.
#
# v2 (Forge batch item 9) — CONFIRMATION + PUSH-TO-TALK, same plugin:
#   (a) CONFIRM BEFORE ACTING. A recognized transcript NEVER reaches the
#       listen() callback (and therefore never reaches Forge) until the
#       player confirms it. The transcript lands in a CONFIRMING state
#       with a modal prompt — the heard text plus CONFIRM / RETRY /
#       CANCEL buttons and a TYPE INSTEAD button. CONFIRM delivers the
#       text to the callback; RETRY re-listens; CANCEL discards it;
#       TYPE INSTEAD discards it and opens the typed fallback. This
#       matters more now that budget is off: a misheard prompt could
#       otherwise spam structures with no cost gate to slow it down.
#   (b) PUSH-TO-TALK STATE MACHINE. listen() starts a session:
#       IDLE -> PERMISSION_PENDING -> LISTENING -> CONFIRMING -> IDLE.
#       While LISTENING a banner shows a live countdown to the visible
#       timeout (LISTEN_TIMEOUT_SEC). Tapping MIC again while LISTENING
#       cancels the session (banner says so). end_ptt() marks the
#       button released ("release to send"): nothing is sent on release
#       — the transcript still waits for CONFIRM — it just arms the
#       confirm step. Every exit (confirm / retry / cancel / error /
#       timeout / permission denial) returns to IDLE; there is no stuck
#       listening state.
#   PLUGIN LIMIT (honest): ForgeSpeech exposes startListening() +
#   onResult() ONLY — there is no stop/cancel on the Java side, and v2
#   does not change the plugin. So "cancel" / "timeout" / "release"
#   cannot kill the Android recognizer mid-utterance; instead the
#   session is closed GDScript-side and a stale guard (_session_active)
#   makes any late onResult from the abandoned recognizer a no-op.
#   The recognizer self-terminates on end-of-speech / silence / error
#   per Android, and its late result is ignored. The CONFIRM step is
#   what makes this safe: even if a stale transcript were attributed
#   to a fresh session (cancel -> immediate re-listen), the player
#   still sees the text and can Retry/Cancel before anything is built.
#   A true recognizer-level stopListening() is a small Java addition +
#   AAR rebuild — DEFERRED (would touch the shipped AAR mid-batch).
#   TYPED FALLBACK, ONE TAP AWAY, IN EVERY STATE: LISTENING banner
#   says "tap MIC again to cancel" (then type); CONFIRMING has a
#   TYPE INSTEAD button; the Forge menu always shows its prompt field;
#   the error path still opens the typed console automatically.
#
# Contract (frozen): listen(callback) with the ForgeSpeech singleton check;
# v0.6.0 only extends it with the optional press_console_on_fallback flag
# (default true — existing callers are untouched). v2 keeps listen()'s
# signature and the legacy direct-injection path in _on_plugin_result
# (a callback set WITHOUT a session still forwards directly) so the
# v0.6.0 verifier keeps passing; sessions started via listen() always
# go through CONFIRMING when require_confirmation is true (the default).
class_name SpeechInput
extends Node

## Emitted on every state transition, with the new state name
## ("idle" / "permission_pending" / "listening" / "confirming").
signal state_changed(state_name: String)

const PLUGIN_SINGLETON := "ForgeSpeech"
## Full Android permission name (Godot docs examples use the
## "android.permission.*" form for OS.request_permission).
const PERMISSION_RECORD_AUDIO := "android.permission.RECORD_AUDIO"

## v0.5.1 FIX 7a: shown (never silently) whenever the MIC falls back to
## the typed console. Reuses the existing Forge feedback channel — no
## new toast system is built here.
const VOICE_UNAVAILABLE_MSG := "Voice input isn't available yet — type your prompt"
## Shown while the system mic-permission dialog is up (the grant result
## arrives async; denial falls back to the typed console).
const PERMISSION_PENDING_MSG := "Allow microphone access, then tap MIC again."
## Shown when the visible listening timeout expires. The typed console
## is NOT auto-opened here: the player chose voice, so voice just ends
## and typing stays one tap away (MIC / Forge prompt field).
const LISTEN_TIMEOUT_MSG := "Listening timed out — tap MIC to try again, or type your prompt."
## Visible listening timeout, in seconds. Counted down live in the
## listening banner so the player always sees how long is left.
const LISTEN_TIMEOUT_SEC := 12.0

## Push-to-talk / confirm state machine. IDLE = no session in flight.
enum State { IDLE, PERMISSION_PENDING, LISTENING, CONFIRMING }

## When true (default), a recognized transcript waits in CONFIRMING
## until the player taps CONFIRM. Set false only for callers that do
## their own confirmation (none today — the overlay IS the confirm).
var require_confirmation := true

var _listening := false
## Last fallback toast text shown (headless-verifiable record of the
## visible feedback; the real display goes through Forge/HUD/menu).
var last_toast_text: String = ""
## True after the typed fallback requested the console (headless-verifiable
## alongside Input.is_action_pressed("forge_console")).
var fallback_console_requested := false
## Callback awaiting a transcript while a permission answer or a
## recognition result is in flight.
var _active_callback: Callable
## True while a RECORD_AUDIO answer is outstanding.
var _permission_pending := false
## listen()-time choice: press forge_console on the fallback path.
var _fallback_press_console := true
## Current state-machine state (see State). Read via get_state_name().
var _state: State = State.IDLE
## True while a session started via listen() is in flight (LISTENING or
## CONFIRMING). The stale-result guard: _on_plugin_result ignores
## results when this is false (cancel / timeout already closed the
## session), so a late onResult can never resurrect a dead session.
var _session_active := false
## Transcript currently awaiting confirmation (CONFIRMING only).
var pending_transcript: String = ""
## Seconds spent in LISTENING this session (drives the countdown).
var _listen_elapsed := 0.0
## True once end_ptt() marked the push-to-talk button released.
## Release arms the confirm step; it never sends anything by itself.
var ptt_released := false
## True when the current session runs on the headless test stub
## (test_start_session) instead of the real plugin.
var _test_session := false

# --- confirm / listening overlay (plain Controls, no CanvasLayer) -------
# Built lazily under this node so visibility follows the parent: when
# the Forge menu hides, the overlays hide with it (no leaked prompt
# over gameplay), and when the menu reopens a pending CONFIRM is still
# there. The confirm overlay is modal (full-screen STOP dim); the
# listening banner is visual-only (mouse_filter IGNORE) so touches
# keep reaching the game while the player holds MIC to talk.
var _confirm_root: Control = null
var _confirm_text_label: Label = null
var _listen_banner: Control = null
var _listen_label: Label = null


func _init() -> void:
	set_process(true)


## True only on Android when the ForgeSpeech plugin singleton is registered.
static func is_available() -> bool:
	return OS.has_feature("android") and Engine.has_singleton(PLUGIN_SINGLETON)


## True when RECORD_AUDIO is already granted (Android only).
func _permission_granted() -> bool:
	if not OS.has_feature("android"):
		return false
	return OS.get_granted_permissions().has(PERMISSION_RECORD_AUDIO)


## Current state-machine state as a string ("idle", "permission_pending",
## "listening", "confirming"). Headless- and HUD-friendly.
func get_state_name() -> String:
	match _state:
		State.PERMISSION_PENDING:
			return "permission_pending"
		State.LISTENING:
			return "listening"
		State.CONFIRMING:
			return "confirming"
		_:
			return "idle"


## True while a voice session is LISTENING (push-to-talk held or
## waiting on the recognizer). Touch MIC taps this to toggle-cancel.
func is_listening_session() -> bool:
	return _state == State.LISTENING


## True while the CONFIRM / RETRY / CANCEL prompt is open. The touch
## layer gates its manual _input dispatch on this so taps on the
## confirm buttons cannot also fire game buttons underneath (the
## touch dispatcher does not respect Control mouse_filter).
func is_confirm_open() -> bool:
	return _state == State.CONFIRMING


## Seconds of listening time left before the visible timeout fires.
func listening_time_left() -> float:
	return maxf(0.0, LISTEN_TIMEOUT_SEC - _listen_elapsed)


## Begin voice capture. Plugin path -> CONFIRMING (transcript shown for
## CONFIRM / RETRY / CANCEL) -> callback(text) only on CONFIRM.
## Fallback path -> opens the typed Forge console (unless
## press_console_on_fallback is false, in which case it only toasts),
## callback not called.
## Tapping MIC again while LISTENING cancels the session (toggle);
## tapping while CONFIRMING is ignored — resolve the prompt first.
func listen(callback: Callable, press_console_on_fallback: bool = true) -> void:
	if _state == State.LISTENING:
		# Tap-again-to-cancel: the listening banner says so.
		cancel_session()
		return
	if _state != State.IDLE:
		# CONFIRMING (resolve the prompt) or PERMISSION_PENDING (the
		# system dialog owns the screen): ignore the extra tap.
		return
	_fallback_press_console = press_console_on_fallback
	if is_available() and not _listening:
		if _permission_granted():
			_begin_plugin_session(callback)
			return
		# Android 6+: RECORD_AUDIO needs a runtime grant. Ask once; the
		# answer arrives via MainLoop.on_request_permissions_result —
		# grant auto-starts listening, denial falls back (unavailable).
		# Do NOT open the typed console underneath the system dialog:
		# wait for the answer instead.
		_active_callback = callback
		_session_active = true
		_permission_pending = true
		_set_state(State.PERMISSION_PENDING)
		_connect_permission_result()
		if OS.request_permission(PERMISSION_RECORD_AUDIO):
			# Already granted (docs: returns true when already granted).
			_permission_pending = false
			_begin_plugin_session(callback)
			return
		_show_toast_text(PERMISSION_PENDING_MSG)
		return
	# Fallback (no plugin, or plugin call failed): typed console + toast.
	_typed_fallback()


## Push-to-talk release: marks the button released ("release to send").
## Nothing is sent on release — the transcript, when it arrives, still
## waits in CONFIRMING for the player. No-op outside LISTENING.
## NOTE: the plugin has no stopListening(), so release cannot end the
## Android recognizer; it only arms the confirm step (see header).
func end_ptt() -> void:
	if _state != State.LISTENING:
		return
	ptt_released = true
	_update_listening_banner()


## Cancels the in-flight session, if any: LISTENING / CONFIRMING /
## PERMISSION_PENDING all return to IDLE with no callback, no toast,
## no Forge action. Late onResult deliveries from the abandoned
## recognizer are ignored via the _session_active stale guard.
## Safe to call when idle (no-op).
func cancel_session() -> void:
	if _state == State.IDLE and not _session_active and not _permission_pending:
		_hide_overlays()
		return
	_close_session()


## CONFIRM button (or headless test): deliver the pending transcript
## to the listen() callback and return to IDLE. No-op unless CONFIRMING.
func confirm_pending() -> void:
	if _state != State.CONFIRMING:
		return
	var transcript := pending_transcript
	_deliver(transcript)


## RETRY button (or headless test): discard the pending transcript
## and re-listen with the same callback. No-op unless CONFIRMING.
func retry_pending() -> void:
	if _state != State.CONFIRMING:
		return
	var cb := _active_callback
	_hide_overlays()
	pending_transcript = ""
	ptt_released = false
	_listen_elapsed = 0.0
	# Session stays active across the retry; the stale guard still
	# covers results from the previous recognizer run.
	if _test_session:
		_set_state(State.LISTENING)
		_update_listening_banner()
		return
	_set_state(State.LISTENING)
	_start_plugin_listen(cb)


## CANCEL button (or headless test): discard the pending transcript,
## no callback, no Forge action. No-op unless CONFIRMING.
func cancel_pending() -> void:
	if _state != State.CONFIRMING:
		return
	cancel_session()


## TYPE INSTEAD button: discard the pending transcript and open the
## typed fallback (console + toast, or toast-only when the caller
## already shows a text field). No-op unless CONFIRMING.
func type_instead_pending() -> void:
	if _state != State.CONFIRMING:
		return
	cancel_session()
	_typed_fallback()


# --- headless test seam (stubbed recognizer) ------------------------------
# test_start_session() opens a LISTENING session WITHOUT the plugin so
# a scratch script can drive the whole state machine headlessly:
# simulate_transcript() / simulate_error() / simulate_timeout() feed
# it exactly like the real onResult / timeout paths. Production code
# never calls these; they exercise the same handlers as the plugin.

## Opens a LISTENING session backed by the test stub (no plugin).
func test_start_session(callback: Callable, press_console_on_fallback: bool = true) -> void:
	if _state != State.IDLE:
		return
	_fallback_press_console = press_console_on_fallback
	_active_callback = callback
	_session_active = true
	_test_session = true
	_listening = true
	_listen_elapsed = 0.0
	ptt_released = false
	pending_transcript = ""
	_set_state(State.LISTENING)
	_update_listening_banner()


## Stubbed recognizer delivery: behaves exactly like a plugin
## onResult(text) for the current session.
func simulate_transcript(text: String) -> void:
	_on_plugin_result(text)


## Stubbed recognizer failure: behaves exactly like a plugin
## onResult("") (the plugin emits "" on any recognition error).
func simulate_error() -> void:
	_on_plugin_result("")


## Stubbed timeout: behaves exactly like the visible-timeout expiry.
func simulate_timeout() -> void:
	_on_listen_timeout()


## Single handler for the plugin's onResult(text). Resets the gate,
## forwards non-empty transcripts, falls back on empty (the plugin emits
## "" on any recognition error / unavailable recognizer).
##
## Two paths: (1) SESSION path — a session started via listen() is in
## flight: non-empty transcripts go to CONFIRMING (or straight to the
## callback when require_confirmation is false); empty results end the
## session via the typed fallback; results after cancel/timeout are
## ignored by the _session_active stale guard. (2) LEGACY path — no
## session is in flight but a callback was injected directly (the
## v0.6.0 verifier does this): forward directly, preserving the old
## contract. cancel_session() clears _active_callback, so a late
## result after a real cancel can never take the legacy path.
func _on_plugin_result(text: String) -> void:
	_listening = false
	if not _session_active:
		# LEGACY direct-injection path (no session): forward directly.
		var legacy_cb := _active_callback
		_active_callback = Callable()
		var legacy_transcript := text.strip_edges()
		if legacy_transcript.is_empty():
			_typed_fallback()
			return
		if legacy_cb.is_valid():
			legacy_cb.call(legacy_transcript)
		return
	# SESSION path: the result belongs to the in-flight session.
	# CONFIRMING sessions never expect another result; if one arrives
	# (rapid retry), it belongs to the newest listen — treat it as a
	# fresh transcript for confirmation rather than dropping it.
	var transcript := text.strip_edges()
	if transcript.is_empty():
		# Recognition error / unavailable recognizer: end the session
		# via the typed fallback (the v0.5.1 floor), no callback.
		_close_session()
		_typed_fallback()
		return
	if require_confirmation:
		_enter_confirming(transcript)
	else:
		_deliver(transcript)


func _begin_plugin_session(callback: Callable) -> void:
	_active_callback = callback
	_session_active = true
	_test_session = false
	_listen_elapsed = 0.0
	ptt_released = false
	pending_transcript = ""
	_set_state(State.LISTENING)
	_start_plugin_listen(callback)


func _start_plugin_listen(callback: Callable) -> void:
	var plugin: Object = Engine.get_singleton(PLUGIN_SINGLETON)
	if plugin == null or not plugin.has_method("startListening"):
		_close_session()
		_typed_fallback()
		return
	_active_callback = callback
	if plugin.has_signal("onResult") and not plugin.is_connected("onResult", _on_plugin_result):
		plugin.connect("onResult", _on_plugin_result)
	_listening = true
	_update_listening_banner()
	plugin.call("startListening")


func _connect_permission_result() -> void:
	var main_loop := Engine.get_main_loop()
	if main_loop != null and main_loop.has_signal("on_request_permissions_result"):
		if not main_loop.is_connected("on_request_permissions_result", _on_permission_result):
			main_loop.connect("on_request_permissions_result", _on_permission_result)


## MainLoop.on_request_permissions_result(permission, granted) — the async
## answer to OS.request_permission(PERMISSION_RECORD_AUDIO).
func _on_permission_result(permission: StringName, granted: bool) -> void:
	if not _permission_pending:
		return
	if permission != StringName(PERMISSION_RECORD_AUDIO):
		return
	_permission_pending = false
	if granted:
		_begin_plugin_session(_active_callback)
	else:
		# Denial == unavailable: the v0.5.1 floor (toast + typed console).
		_close_session()
		_typed_fallback()


## Visible-timeout expiry: close the session, toast, back to IDLE.
## No callback, no Forge action, no auto-opened console.
func _on_listen_timeout() -> void:
	if _state != State.LISTENING:
		return
	_close_session()
	_show_toast_text(LISTEN_TIMEOUT_MSG)


func _process(delta: float) -> void:
	if _state != State.LISTENING:
		return
	_listen_elapsed += delta
	_update_listening_banner()
	if _listen_elapsed >= LISTEN_TIMEOUT_SEC:
		_on_listen_timeout()


## Moves a transcript into CONFIRMING: shows the modal prompt with
## the heard text + CONFIRM / RETRY / CANCEL (+ TYPE INSTEAD).
func _enter_confirming(transcript: String) -> void:
	pending_transcript = transcript
	_set_state(State.CONFIRMING)
	_hide_listening_banner()
	_show_confirm(transcript)


## Delivers a transcript to the listen() callback. Session state is
## cleared BEFORE invoking the callback so re-entrant calls (the
## callback submitting a Forge prompt, or starting a new session)
## cannot see a half-closed session.
func _deliver(transcript: String) -> void:
	var cb := _active_callback
	_close_session()
	if cb.is_valid():
		cb.call(transcript)


## Closes the session without delivering anything: state IDLE,
## overlays hidden, callback cleared (so late onResult deliveries
## hit the stale guard, never the legacy path), listening gate reset.
func _close_session() -> void:
	_session_active = false
	_test_session = false
	_permission_pending = false
	_listening = false
	_active_callback = Callable()
	pending_transcript = ""
	_listen_elapsed = 0.0
	ptt_released = false
	_hide_overlays()
	_set_state(State.IDLE)


func _set_state(next: State) -> void:
	if _state == next:
		return
	_state = next
	state_changed.emit(get_state_name())


func _typed_fallback() -> void:
	_permission_pending = false
	# FIX 7a: NEVER silently — tell the user voice isn't available, then
	# open the typed console (unless the caller already shows a text
	# field, e.g. the Forge menu's MIC button). Toast first so the
	# message is queued before the console appears (HUD feed entries /
	# menu toast persist into it).
	_show_voice_unavailable_toast()
	if not _fallback_press_console:
		return
	fallback_console_requested = true
	# Same input path as the on-screen FORGE button: contract-frozen action.
	# Release is deferred one frame so is_action_just_pressed() observers
	# (the player/HUD) still see the tap.
	Input.action_press("forge_console", 1.0)
	_release_next_frame("forge_console")


func _show_toast_text(text: String) -> void:
	last_toast_text = text
	if not is_inside_tree():
		return
	# Primary path: the existing Forge feedback channel. Both the HUD
	# (forge feed entry) and the Forge menu (toast) already listen to
	# Forge.forge_result, so one emit reaches both visible surfaces.
	var forge := get_node_or_null("/root/Forge")
	if forge != null and forge.has_signal("forge_result"):
		forge.emit_signal("forge_result", false, text)
		return
	# No Forge autoload (e.g. isolated test): reuse the HUD banner +
	# Forge menu toast directly. Still no new toast system.
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("announce"):
		hud.call("announce", "VOICE UNAVAILABLE", "Type your prompt")
	for menu in get_tree().get_nodes_in_group("forge_menu"):
		if menu.has_method("show_feedback"):
			menu.call("show_feedback", text)


func _show_voice_unavailable_toast() -> void:
	_show_toast_text(VOICE_UNAVAILABLE_MSG)


func _release_next_frame(action: StringName) -> void:
	await get_tree().process_frame
	Input.action_release(action)


# --- overlays --------------------------------------------------------------
# Plain Controls under this node (no CanvasLayer): visibility follows
# the parent, so hiding the Forge menu / touch layer hides the prompt.

func _ensure_overlays() -> void:
	if not is_inside_tree():
		return
	if _confirm_root == null:
		_confirm_root = _build_confirm_overlay()
		add_child(_confirm_root)
	if _listen_banner == null:
		_listen_banner = _build_listen_banner()
		add_child(_listen_banner)


func _build_confirm_overlay() -> Control:
	var root := Control.new()
	root.name = "VoiceConfirmOverlay"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.visible = false
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var panel := PanelContainer.new()
	panel.name = "ConfirmPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	var panel_bg := StyleBoxFlat.new()
	panel_bg.bg_color = Color(0.08, 0.09, 0.12, 1.0)
	panel_bg.border_color = Color(1.0, 0.55, 0.12, 1.0)
	panel_bg.set_border_width_all(3)
	panel_bg.set_corner_radius_all(14)
	panel_bg.content_margin_left = 20.0
	panel_bg.content_margin_right = 20.0
	panel_bg.content_margin_top = 16.0
	panel_bg.content_margin_bottom = 16.0
	panel.add_theme_stylebox_override("panel", panel_bg)
	root.add_child(panel)
	var box := VBoxContainer.new()
	box.name = "ConfirmBox"
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var title := Label.new()
	title.name = "ConfirmTitle"
	title.text = "VOICE — CHECK WHAT I HEARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.55, 0.12))
	box.add_child(title)
	var text_label := Label.new()
	text_label.name = "ConfirmTranscript"
	text_label.text = ""
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text_label.add_theme_font_size_override("font_size", 24)
	text_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	box.add_child(text_label)
	_confirm_text_label = text_label
	var hint := Label.new()
	hint.name = "ConfirmHint"
	hint.text = "Build this? Confirm only what you actually said."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 17)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	box.add_child(hint)
	var row := HBoxContainer.new()
	row.name = "ConfirmButtonRow"
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var confirm_btn := Button.new()
	confirm_btn.name = "ConfirmButton"
	confirm_btn.text = "CONFIRM"
	confirm_btn.custom_minimum_size = Vector2(150, 56)
	confirm_btn.pressed.connect(confirm_pending)
	row.add_child(confirm_btn)
	var retry_btn := Button.new()
	retry_btn.name = "RetryButton"
	retry_btn.text = "RETRY"
	retry_btn.custom_minimum_size = Vector2(130, 56)
	retry_btn.pressed.connect(retry_pending)
	row.add_child(retry_btn)
	var cancel_btn := Button.new()
	cancel_btn.name = "CancelButton"
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(130, 56)
	cancel_btn.pressed.connect(cancel_pending)
	row.add_child(cancel_btn)
	var type_btn := Button.new()
	type_btn.name = "TypeInsteadButton"
	type_btn.text = "TYPE INSTEAD"
	type_btn.custom_minimum_size = Vector2(180, 56)
	type_btn.pressed.connect(type_instead_pending)
	box.add_child(type_btn)
	return root


func _build_listen_banner() -> Control:
	var banner := Control.new()
	banner.name = "VoiceListenBanner"
	banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.visible = false
	var label := Label.new()
	label.name = "ListenLabel"
	label.text = ""
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.02, 0.03, 0.05, 0.72)
	bg.set_corner_radius_all(10)
	bg.content_margin_left = 16.0
	bg.content_margin_right = 16.0
	bg.content_margin_top = 8.0
	bg.content_margin_bottom = 8.0
	label.add_theme_stylebox_override("normal", bg)
	label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner.add_child(label)
	_listen_label = label
	return banner


func _show_confirm(transcript: String) -> void:
	_ensure_overlays()
	if _confirm_root == null:
		return
	# Viewport-aware panel: at most 90% of the viewport, capped at 760px.
	var vp := get_viewport()
	var panel_w := 760.0
	var panel_h := 420.0
	if vp != null:
		var vs := vp.get_visible_rect().size
		panel_w = minf(760.0, vs.x * 0.9)
		panel_h = minf(420.0, vs.y * 0.8)
	var panel := _confirm_root.get_node_or_null("ConfirmPanel")
	if panel is Control:
		(panel as Control).offset_left = -panel_w * 0.5
		(panel as Control).offset_right = panel_w * 0.5
		(panel as Control).offset_top = -panel_h * 0.5
		(panel as Control).offset_bottom = panel_h * 0.5
	if _confirm_text_label != null:
		_confirm_text_label.text = "\"%s\"" % transcript
	_confirm_root.visible = true
	_confirm_root.move_to_front()


func _update_listening_banner() -> void:
	_ensure_overlays()
	if _listen_banner == null or _listen_label == null:
		return
	if _state != State.LISTENING:
		_listen_banner.visible = false
		return
	var secs := int(ceilf(listening_time_left()))
	var text := "🎤 Listening… %ds left — release to send, tap MIC again to cancel" % secs
	if ptt_released:
		text = "🎤 Got it — waiting for the transcript… %ds left" % secs
	_listen_label.text = text
	_listen_banner.visible = true
	_listen_banner.move_to_front()


func _hide_listening_banner() -> void:
	if _listen_banner != null:
		_listen_banner.visible = false


func _hide_confirm() -> void:
	if _confirm_root != null:
		_confirm_root.visible = false


func _hide_overlays() -> void:
	_hide_listening_banner()
	_hide_confirm()


## Human-readable status for a debug/options row.
static func status_text() -> String:
	if is_available():
		return "Voice input: plugin ready"
	if OS.has_feature("android"):
		return "Voice input: typed console (no STT plugin installed)"
	return "Voice input: unavailable on desktop"
