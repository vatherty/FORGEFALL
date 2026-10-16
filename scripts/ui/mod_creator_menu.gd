# FORGEFALL — ModCreatorMenu (Forge batch, Worker D: Mod Creator redesign)
# CREATE-A-MOD is its own MAIN-MENU widget now (main menu -> CREATE A MOD),
# not a panel inside the Forge menu. Dedicated menu, four tabs:
#   CREATE — structured form (NOT one text box): multi-choice CATEGORIES
#     checkboxes (Weapon / Block-Structure / Enemy / Effect / Gameplay —
#     a mod can be several at once), NAME, VISUAL DESCRIPTION, LOGIC.
#     GENERATE composes ONE stable prompt from the form and feeds the
#     EXISTING generation -> strict validation -> approval pipeline
#     (ModCreator): summary + FULL payload -> Install / Discard /
#     Regenerate. Approval also offers TEST IN SANDBOX.
#   CHAT (v0.5.4, Worker A) — free-form conversation with the model
#     about mods. Shares ONE ChatSession with the CREATE tab: chatting
#     "make me a watermelon LMG" then hitting CREATE FROM CHAT sends
#     the chat history as context to the generation call, whose
#     candidate lands on the CREATE tab's approval screen (same
#     validation -> approval -> Install path, nothing installs from chat).
#     list / enable / disable / Rescan. The Forge menu's Mods tab keeps
#     the same list — one create flow, no duplicates.
#   IMPORT/EXPORT — PLACEHOLDER / DISABLED tab ONLY, no functionality.
#     FOR LATER: the tab exists so the layout is stable; both buttons
#     are disabled and nothing is wired.
#
# VOXEL ASSETS: after a candidate arrives, the menu generates the voxel
# asset from the VISUAL DESCRIPTION via VoxelAssetGenerator (local,
# keyword-driven, cached by hash of the normalized description) and shows
# the cache HIT/MISS + voxel count on the approval screen.
#
# SANDBOX: TEST IN SANDBOX opens SandboxTestRoom with the candidate +
# asset. The sandbox simulates the mod's declared behaviour and RUNS its
# validated hook scripts (code hooks only — the candidate's ModBlock
# script is still never executed) in the throwaway test room, then
# reports what each hook script did. A hook script that fails in the
# sandbox disables the candidate visibly (Install goes dead with the
# reason). The sandbox writes NOTHING to the real mod list or
# progression. Install stays available on the approval screen whether
# or not the sandbox was used (unless the sandbox disabled the candidate).
#
# NOTHING installs except the Install tap (ModCreator.install is the only
# write path, same as the old in-Forge flow). Closing the menu drops the
# pending candidate, uninstalled.
extends Control
class_name ModCreatorMenu

signal creator_closed

const CATEGORIES := ["Weapon", "Block/Structure", "Enemy", "Effect", "Gameplay"]
const CREATOR_TABS := ["CREATE", "CHAT", "MODS", "IMPORT/EXPORT"]

var _tabs: TabContainer
var _category_checks: Dictionary = {}
var _name_input: LineEdit
var _visual_input: TextEdit
var _logic_input: TextEdit
var _generate_button: Button
var _status: Label
var _approval_panel: VBoxContainer
var _approval_summary: Label
var _approval_hooks: Label
var _approval_code: TextEdit
# v0.5.6: LLM-authored HOOK SCRIPT display — shown ONLY when the
# candidate carries hook scripts ("code" hooks). Hidden for pure
# table-effects mods.
var _approval_script_label: Label
var _approval_script_toggle: Button
var _approval_script: TextEdit
var _approval_script_collapsed := false
var _asset_info: Label
var _approval_status: Label
var _install_button: Button
var _discard_button: Button
var _regenerate_button: Button
var _sandbox_button: Button
var _mods_list: VBoxContainer
var _mods_path_label: Label
var _mods_rescan_button: Button
var _creator: ModCreator
var _pending_candidate: Dictionary = {}
var _pending_prompt: String = ""
var _pending_asset: Dictionary = {}
var _pending_projectile_asset: Dictionary = {}
var _generating := false
var _last_sandbox_result: Dictionary = {}
# Chat tab (v0.5.4): the ONE shared session — the Chat tab and the
# Create tab both use this same object. Created in _build_chat_tab
# (loads the persisted conversation, so reopening keeps the chat).
var _chat_session: ChatSession = null
var _chat_panel: ChatPanel = null
# True while a CREATE FROM CHAT generation is in flight: its candidate
# switches the view to the CREATE tab's approval screen on success, or
# shows the error as a red bubble in the chat on failure.
var _chat_generation_pending := false
# Last chat-driven generation, kept so REGENERATE retries it with the
# same conversation context. Cleared by a form GENERATE (which owns the
# regenerate path from then on).
var _pending_chat_conversation: Array = []
var _pending_chat_request: String = ""


## Composes ONE stable prompt from the structured form. Fixed section
## order + fixed technical-notes text, so the same form always yields the
## same prompt (and the LLM's stable-prefix cache sees a stable shape).
## The technical notes steer the model to the EXISTING validated path:
## custom visuals via api.spawn_voxel_box, impact explosions via
## api.fire_effect("explosion", ...), ModAPI only, no forbidden code —
## PLUS (v0.5.3) invented hooks: when the mod needs behaviour no
## existing block covers, the model invents a hook (projectile /
## effects) instead of refusing or improvising raw code.
static func compose_prompt(categories: Array, mod_name: String, visual: String, logic: String) -> String:
	var lines: Array[String] = []
	lines.append("Create a mod.")
	lines.append("Categories: " + ", ".join(categories))
	lines.append("Name: " + mod_name.strip_edges())
	lines.append("Visual description: " + visual.strip_edges())
	lines.append("Logic: " + logic.strip_edges())
	lines.append("Technical notes (follow exactly): represent any custom projectile or visual with api.spawn_voxel_box calls using voxel-sized cubes in the visual description's colours; trigger impact explosions with api.fire_effect(\"explosion\", position, radius, damage); build only through the ModAPI methods; never emit filesystem, network, OS, eval, or code-loading code.")
	lines.append("HOOKS — PREFER THE EFFECT-KINDS TABLE (follow exactly): if the mod needs behaviour no existing block covers (a custom projectile, heal-on-kill, thorns, an on-hit explosion, ...), add a HOOK for it — prefer the table below whenever it covers the request; write a hook SCRIPT only when nothing in the table covers it. Block mod: add a top-level \"hooks\" array to the payload, next to the \"block\" object. Script mod: implement get_hooks() -> Array returning the hook dicts. Hook dict: {\"hook_id\": \"<lowercase [a-z0-9_]>\", \"hook_point\": \"on_fire\"|\"projectile_spawn\"|\"on_hit\"|\"on_kill\"|\"on_damage_taken\", \"display_name\": \"<name>\", \"description\": \"<one line>\", ...}. A fire-point hook (on_fire / projectile_spawn) may carry \"projectile\": {\"visual\": \"<what it looks like>\", \"shape\": \"beam\"|\"sphere\"|\"cube\"|\"blob\"|\"bullet\", \"speed\": 1-200, \"damage\": 0-500 (-1 = use the weapon's damage), \"range\": 1-500, \"size\": 0.05-5, \"gravity\": -50-50, \"pierce\": true|false, \"explodes_on_impact\": true|false, \"explosion_radius\": 0-20, \"explosion_damage\": 0-500}. Any hook may carry \"effects\": [{\"kind\": \"heal\", \"amount\": 1-500} | {\"kind\": \"explosion\", \"radius\": 0.5-20, \"damage\": 0-500} | {\"kind\": \"smoke\", \"duration_sec\": 1-120} | {\"kind\": \"announce\", \"title\": \"...\", \"subtitle\": \"...\"} | {\"kind\": \"damage_mult\", \"value\": 0-5} | {\"kind\": \"slow\", \"factor\": 0.05-1.0, \"duration_sec\": 0.5-30} | {\"kind\": \"freeze\", \"duration_sec\": 0.5-10} | {\"kind\": \"burn\", \"damage_per_sec\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"knockback\", \"force\": 1-30} | {\"kind\": \"pull\", \"force\": 1-30} | {\"kind\": \"poison\", \"damage_per_sec\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"bleed\", \"damage_per_sec\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"regen\", \"heal_per_sec\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"haste\", \"factor\": 1.05-2.5, \"duration_sec\": 0.5-30} | {\"kind\": \"restrained\", \"duration_sec\": 0.5-10} | {\"kind\": \"prone\", \"force\": 1-30, \"duration_sec\": 0.5-10} | {\"kind\": \"sleep\", \"duration_sec\": 0.5-30} | {\"kind\": \"confusion\", \"force\": 1-10, \"duration_sec\": 0.5-30} | {\"kind\": \"blind\", \"factor\": 0.05-1.0, \"duration_sec\": 0.5-30} | {\"kind\": \"weaken\", \"factor\": 0.05-1.0, \"duration_sec\": 0.5-30} | {\"kind\": \"exhaustion\", \"duration_sec\": 0.5-60} | {\"kind\": \"typed_damage\", \"damage_type\": \"acid\"|\"cold\"|\"fire\"|\"lightning\"|\"necrotic\"|\"poison\"|\"psychic\"|\"radiant\"|\"thunder\", \"amount\": 1-500, \"duration_sec\": 0.5-30}]. STATUS EFFECTS (every status kind needs a target: put them on on_hit / on_kill (hit target) or on_damage_taken (player); NEVER on a fire point. slow multiplies movement speed by factor (0.5 = half speed); freeze pins: speed 0 AND knockback cannot move it; burn is pure damage over time; knockback shoves AWAY from the hit point, pull yanks TOWARD it; poison is damage over time PLUS a mild slow (x0.85); bleed is damage over time that ticks FASTER while the target moves; regen heals over time; haste multiplies movement speed only (not fire rate); restrained is speed 0 but can act and can be shoved; prone knocks down (impulse + speed 0) then stands back up; sleep is speed 0 + pinned and WAKES EARLY on any damage; confusion stumbles randomly; blind disrupts accuracy; weaken reduces damage dealt; exhaustion stacks +1 level per application (6 = death); typed_damage deals instant damage of one D&D type + a rider (fire burns, cold slows, lightning knocks back, thunder knocks back hard + prone, acid weakens, necrotic exhausts, poison poisons, psychic confuses, radiant blinds). Do NOT invent stunned / paralyzed / unconscious / petrified / grappled / frightened / charmed / silence / shield / vulnerable / thorns / lifesteal / curse — they are not kinds; use the real kinds above. A slowing bubble is an on_hit hook with effects [{\"kind\": \"slow\", \"factor\": 0.5, \"duration_sec\": 3.0}] — never express slowing as smoke or announce. HOOK SCRIPT (only when the table cannot express the behaviour, e.g. pulling the hit target toward the player): the hook dict carries \"code\": GDScript source starting with `extends ModHook` and implementing run(api: ModAPI, ctx: Dictionary) -> Dictionary with ONLY allowlisted calls (api.<ModAPI method>, ctx.get/has/..., pure value methods; NEVER node properties like .global_position/.position/.hp, NEVER api properties like api.last_spawned), bounded for loops (range <= 1000), no while/recursion/engine callbacks. A hook with \"code\" runs ONLY its code — \"effects\" on the same hook are ignored. Never put filesystem, network, OS, eval, or code-loading code in a hook.")
	return "\n".join(lines)


## Behaviour flags for the sandbox, derived from the form + payload.
## Never executes the candidate — the sandbox simulates this behaviour.
## v0.5.3: invented hooks in the payload are merged in (see
## _merge_hooks_into_behavior): a projectile hook sets the sandbox
## projectile spec, an on_kill heal hook sets heal_on_kill, and the raw
## hook list rides along in behavior["hooks"].
static func behavior_for(categories: Array, logic: String, payload: String) -> Dictionary:
	var l := logic.to_lower()
	var p := payload.to_lower()
	var projectile := categories.has("Weapon") or l.contains("shoot") or l.contains("projectile") or l.contains("fire") or l.contains("launch") or p.contains("spawn_voxel_box")
	var explodes := l.contains("explod") or p.contains("explosion") or p.contains("fire_effect")
	var behavior := {"projectile": projectile, "explodes_on_impact": explodes}
	# Only block payloads are JSON — a script payload ("extends
	# ModBlock...") would make JSON.parse_string print a benign error,
	# so skip the parse for non-JSON payloads.
	var parsed: Variant = null
	if payload.strip_edges().begins_with("{"):
		parsed = JSON.parse_string(payload)
	if parsed is Dictionary:
		var hooks: Variant = (parsed as Dictionary).get("hooks", null)
		if hooks is Array:
			_merge_hooks_into_behavior(behavior, hooks as Array)
	return behavior


## Merges invented hooks (ModHook dicts) into a sandbox behavior dict:
## a fire-point projectile hook becomes behavior["projectile_spec"], an
## on_kill heal effect becomes behavior["heal_on_kill"], and the hooks
## themselves ride along as behavior["hooks"] for the sandbox to report.
static func _merge_hooks_into_behavior(behavior: Dictionary, hooks: Array) -> void:
	behavior["hooks"] = hooks
	for h in hooks:
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		var point := str(d.get("hook_point", ""))
		if point in ["on_fire", "projectile_spawn"] and d.has("projectile"):
			behavior["projectile"] = true
			behavior["projectile_spec"] = (d.get("projectile", {}) as Dictionary).duplicate(true)
			behavior["explodes_on_impact"] = bool((d.get("projectile", {}) as Dictionary).get("explodes_on_impact", false))
		if point == "on_kill":
			for eff in (d.get("effects", []) as Array):
				if eff is Dictionary and str((eff as Dictionary).get("kind", "")) == "heal":
					behavior["heal_on_kill"] = float((eff as Dictionary).get("amount", 0.0))


## Visual description of what the mod FIRES (its projectile), derived
## from the logic + payload — NEVER the weapon visual. A pistol mod's
## visual ("a pistol with a long barrel") describes the WEAPON; the
## sandbox must fly its projectile (laser beam / bullet / watermelon),
## not a barrel-shaped tube. "" = non-weapon mod, no projectile.
static func projectile_description_for(categories: Array, logic: String, payload: String) -> String:
	var l := logic.to_lower()
	var p := payload.to_lower()
	if l.contains("watermelon") or p.contains("watermelon"):
		return "watermelon"
	if l.contains("laser") or l.contains("beam") or p.contains("laser") or p.contains("beam"):
		return "glowing laser beam"
	if l.contains("bullet") or l.contains("round") or l.contains("shell") or p.contains("bullet"):
		return "small metal bullet"
	if l.contains("fireball") or l.contains("plasma") or p.contains("fireball") or p.contains("plasma"):
		return "glowing plasma fireball"
	if l.contains("rocket") or l.contains("missile") or p.contains("rocket") or p.contains("missile"):
		return "rocket"
	if l.contains("grenade") or p.contains("grenade"):
		return "grenade"
	if categories.has("Weapon") or l.contains("shoot") or l.contains("projectile") or l.contains("fire") or l.contains("launch") or p.contains("spawn_voxel_box"):
		return "glowing energy bolt"
	return ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh_mods()


func _build() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	add_child(panel)
	var vb := VBoxContainer.new()
	vb.name = "CreatorStack"
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)
	var head_row := HBoxContainer.new()
	vb.add_child(head_row)
	var head := Label.new()
	StencilStyle.apply_title(head, 30, StencilStyle.ORANGE, 4)
	head.text = "CREATE A MOD"
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(head)
	var close := Button.new()
	close.name = "CloseButton"
	close.text = "X"
	StencilStyle.style_button(close)
	close.pressed.connect(_on_close_pressed)
	head_row.add_child(close)
	_tabs = TabContainer.new()
	_tabs.name = "CreatorTabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_tab_changed)
	vb.add_child(_tabs)
	_build_create_tab()
	_build_chat_tab()
	_build_mods_tab()
	_build_import_export_tab()


func _tab_scroll(tab_name: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	return scroll


func _section_label(text: String) -> Label:
	var lbl := Label.new()
	StencilStyle.apply_body(lbl, 20, StencilStyle.ORANGE, 2)
	lbl.text = text
	return lbl


# --- CREATE tab ---------------------------------------------------------------

func _build_create_tab() -> void:
	var scroll := _tab_scroll("CreateTab")
	_tabs.set_tab_title(0, CREATOR_TABS[0])
	var box := VBoxContainer.new()
	box.name = "CreateBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	# (1) CATEGORIES — MULTI-CHOICE checkboxes, never single-select.
	box.add_child(_section_label("CATEGORIES — pick all that apply"))
	var cat_row := HBoxContainer.new()
	cat_row.name = "CategoryRow"
	box.add_child(cat_row)
	for cat in CATEGORIES:
		var cb := CheckButton.new()
		cb.name = "Category" + cat.replace("/", "").replace(" ", "")
		cb.text = cat
		cb.add_theme_font_size_override("font_size", 18)
		cat_row.add_child(cb)
		_category_checks[cat] = cb
	# (2) NAME.
	box.add_child(_section_label("NAME"))
	_name_input = LineEdit.new()
	_name_input.name = "ModNameInput"
	_name_input.placeholder_text = "e.g. Watermelon LMG"
	_name_input.clear_button_enabled = true
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_name_input)
	_name_input.focus_mode = Control.FOCUS_CLICK
	box.add_child(_name_input)
	# (3) VISUAL DESCRIPTION.
	box.add_child(_section_label("VISUAL DESCRIPTION — what it looks like"))
	_visual_input = TextEdit.new()
	_visual_input.name = "VisualInput"
	_visual_input.placeholder_text = "e.g. a green watermelon with dark stripes and a red interior"
	_visual_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_visual_input.custom_minimum_size = Vector2(0, 90)
	box.add_child(_visual_input)
	# (4) LOGIC.
	box.add_child(_section_label("LOGIC — what it does"))
	_logic_input = TextEdit.new()
	_logic_input.name = "LogicInput"
	_logic_input.placeholder_text = "e.g. an LMG that shoots watermelons. The watermelons explode on impact."
	_logic_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_logic_input.custom_minimum_size = Vector2(0, 110)
	box.add_child(_logic_input)
	_generate_button = Button.new()
	_generate_button.name = "GenerateButton"
	_generate_button.text = "GENERATE"
	StencilStyle.style_button(_generate_button)
	_generate_button.pressed.connect(_on_generate_pressed)
	box.add_child(_generate_button)
	_status = Label.new()
	_status.name = "CreateStatus"
	_status.text = ""
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_status, 17, StencilStyle.TEXT_DIM, 2)
	box.add_child(_status)
	# Approval: summary + FULL payload + asset info + Install / Discard /
	# Regenerate / TEST IN SANDBOX. Nothing installs until Install.
	_approval_panel = VBoxContainer.new()
	_approval_panel.name = "ApprovalPanel"
	_approval_panel.visible = false
	box.add_child(_approval_panel)
	var approval_title := Label.new()
	approval_title.text = "REVIEW — nothing is installed until you tap Install."
	approval_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(approval_title, 18, StencilStyle.ORANGE, 2)
	_approval_panel.add_child(approval_title)
	_approval_summary = Label.new()
	_approval_summary.name = "ApprovalSummary"
	_approval_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_summary, 18, StencilStyle.TEXT, 2)
	_approval_panel.add_child(_approval_summary)
	# v0.5.3: invented hooks are listed EXPLICITLY here — "this mod adds
	# a new hook: X (hook point: Y)" — before Install. No silent installs.
	_approval_hooks = Label.new()
	_approval_hooks.name = "ApprovalHooks"
	_approval_hooks.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_hooks, 18, StencilStyle.ORANGE, 2)
	_approval_panel.add_child(_approval_hooks)
	_approval_code = TextEdit.new()
	_approval_code.name = "ApprovalCode"
	_approval_code.editable = false
	_approval_code.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_approval_code.custom_minimum_size = Vector2(0, 240)
	_approval_panel.add_child(_approval_code)
	# v0.5.6: LLM-authored HOOK SCRIPT display — shown ONLY when the
	# candidate carries hook scripts ("code" hooks). The label names
	# the script as LLM-authored (vs table effects, which are data);
	# the scrollable TextEdit shows the full DECODED source on demand
	# (toggle collapses/expands it). Pure table-effects mods never
	# see this section.
	_approval_script_label = Label.new()
	_approval_script_label.name = "ApprovalScriptLabel"
	_approval_script_label.text = "LLM-AUTHORED HOOK SCRIPT — this mod contains a hook script written by the LLM (not a table effect). Read the full source below before installing."
	_approval_script_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_script_label, 18, StencilStyle.RED, 2)
	_approval_script_label.visible = false
	_approval_panel.add_child(_approval_script_label)
	_approval_script_toggle = Button.new()
	_approval_script_toggle.name = "ApprovalScriptToggle"
	_approval_script_toggle.text = "HIDE HOOK SCRIPT"
	StencilStyle.style_button(_approval_script_toggle)
	_approval_script_toggle.pressed.connect(_on_script_toggle_pressed)
	_approval_script_toggle.visible = false
	_approval_panel.add_child(_approval_script_toggle)
	_approval_script = TextEdit.new()
	_approval_script.name = "ApprovalScript"
	_approval_script.editable = false
	_approval_script.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_approval_script.custom_minimum_size = Vector2(0, 240)
	_approval_script.visible = false
	_approval_panel.add_child(_approval_script)
	_asset_info = Label.new()
	_asset_info.name = "AssetInfo"
	_asset_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_asset_info, 17, StencilStyle.TEXT, 2)
	_approval_panel.add_child(_asset_info)
	_approval_status = Label.new()
	_approval_status.name = "ApprovalStatus"
	_approval_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_status, 17, StencilStyle.RED, 2)
	_approval_panel.add_child(_approval_status)
	var btn_row := HBoxContainer.new()
	btn_row.name = "ApprovalButtonRow"
	_approval_panel.add_child(btn_row)
	_install_button = Button.new()
	_install_button.name = "ApprovalInstallButton"
	_install_button.text = "INSTALL"
	StencilStyle.style_button(_install_button)
	_install_button.pressed.connect(_on_install_pressed)
	btn_row.add_child(_install_button)
	_discard_button = Button.new()
	_discard_button.name = "ApprovalDiscardButton"
	_discard_button.text = "DISCARD"
	StencilStyle.style_button(_discard_button)
	_discard_button.pressed.connect(_on_discard_pressed)
	btn_row.add_child(_discard_button)
	_regenerate_button = Button.new()
	_regenerate_button.name = "ApprovalRegenerateButton"
	_regenerate_button.text = "REGENERATE"
	StencilStyle.style_button(_regenerate_button)
	_regenerate_button.pressed.connect(_on_regenerate_pressed)
	btn_row.add_child(_regenerate_button)
	_sandbox_button = Button.new()
	_sandbox_button.name = "SandboxButton"
	_sandbox_button.text = "TEST IN SANDBOX"
	StencilStyle.style_button(_sandbox_button)
	_sandbox_button.pressed.connect(_on_sandbox_pressed)
	btn_row.add_child(_sandbox_button)


# --- CHAT tab (v0.5.4, Worker A) -------------------------------------------------
# Free-form conversation. Shares _chat_session with the CREATE tab
# (same object, not a copy): the panel SENDs via
# ModCreator.chat(session.get_messages()) and CREATE FROM CHAT via
# ModCreator.generate_with_context(session.get_messages(),
# session.last_user_request()). The panel calls generate_with_context
# itself right after emitting create_from_chat_requested — this handler
# only records the pending state (tab switch on success, error bubble
# on failure, REGENERATE path), it must NOT call generate again.

func _build_chat_tab() -> void:
	_chat_session = ChatSession.new()
	_chat_panel = ChatPanel.new()
	_chat_panel.name = "ChatPanel"
	_chat_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(_chat_panel)
	_tabs.set_tab_title(1, CREATOR_TABS[1])
	_chat_panel.setup(_chat_session, _creator_instance())
	_chat_panel.create_from_chat_requested.connect(_on_chat_create_requested)


func get_chat_session() -> ChatSession:
	return _chat_session


func get_chat_panel() -> ChatPanel:
	return _chat_panel


func _on_chat_create_requested(conversation: Array, request: String) -> void:
	# Pending state ONLY — the panel makes the generate_with_context
	# call itself right after emitting this signal.
	_chat_generation_pending = true
	_pending_chat_conversation = conversation.duplicate(true)
	_pending_chat_request = request
	# Fallback for REGENERATE if the conversation is later cleared:
	# plain-generate the request text itself.
	_pending_prompt = request
	_generating = true
	if _generate_button != null:
		_generate_button.disabled = true


func _start_chat_generation(conversation: Array, request: String) -> void:
	# REGENERATE path for a chat-driven generation: same pending state
	# as _on_chat_create_requested, PLUS the actual generation call
	# (the panel only makes that call for its own button press).
	if _generating:
		return
	var creator := _creator_instance()
	if creator == null or not creator.has_method("generate_with_context"):
		_status.text = "Creation from chat is unavailable — the generation backend is not ready yet."
		if _chat_panel != null:
			_chat_panel.show_error("Creation from chat is unavailable — the generation backend is not ready yet.")
		return
	_chat_generation_pending = true
	_pending_chat_conversation = conversation.duplicate(true)
	_pending_chat_request = request
	_pending_prompt = request
	_generating = true
	if _generate_button != null:
		_generate_button.disabled = true
	_status.text = "Generating from chat…"
	creator.call("generate_with_context", conversation, request)


# --- MODS tab (same ModLoader list as the Forge menu) --------------------------

func _build_mods_tab() -> void:
	# NOTE: NO outer ScrollContainer here (unlike Create/Import-Export):
	# the mod list itself scrolls (ModsListScroll), and a wrapping
	# ScrollContainer sizes this VBox to its content minimum, which
	# leaves the EXPAND list ScrollContainer at 0px tall — an invisible
	# list (the v0.5.1 "installed mod doesn't show up" bug).
	var box := VBoxContainer.new()
	box.name = "ModsBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.add_child(box)
	_tabs.set_tab_title(2, CREATOR_TABS[2])
	_mods_path_label = Label.new()
	_mods_path_label.name = "ModsPathLabel"
	_mods_path_label.text = "Mods folder: " + OS.get_user_data_dir() + "/mods"
	_mods_path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_mods_path_label, 17, StencilStyle.TEXT_DIM, 2)
	box.add_child(_mods_path_label)
	var row := HBoxContainer.new()
	box.add_child(row)
	_mods_rescan_button = Button.new()
	_mods_rescan_button.name = "ModsRescanButton"
	_mods_rescan_button.text = "RESCAN"
	StencilStyle.style_button(_mods_rescan_button)
	_mods_rescan_button.pressed.connect(_on_mods_rescan_pressed)
	row.add_child(_mods_rescan_button)
	var hint := Label.new()
	hint.text = "Same installed mods as the Forge menu — list / enable / disable / Rescan."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# EXPAND_FILL is REQUIRED: without it the HBox gives this autowrap
	# label its minimum size (1px wide, ~1617px tall wrapped), rendering
	# one character per line and squeezing the mod list to 0px tall.
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(hint, 17, StencilStyle.TEXT_DIM, 2)
	row.add_child(hint)
	var list_scroll := ScrollContainer.new()
	list_scroll.name = "ModsListScroll"
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(list_scroll)
	_mods_list = VBoxContainer.new()
	_mods_list.name = "ModsList"
	_mods_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_mods_list)


# --- IMPORT/EXPORT tab: PLACEHOLDER ONLY, no functionality ---------------------

func _build_import_export_tab() -> void:
	var scroll := _tab_scroll("ImportExportTab")
	_tabs.set_tab_title(3, CREATOR_TABS[3])
	var box := VBoxContainer.new()
	box.name = "ImportExportBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	scroll.add_child(box)
	var note := Label.new()
	note.name = "ImportExportNote"
	note.text = "IMPORT / EXPORT — coming in a later update.\nShare mods as files and bring in mods from other players."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StencilStyle.apply_body(note, 20, StencilStyle.TEXT_DIM, 2)
	box.add_child(note)
	var import_btn := Button.new()
	import_btn.name = "ImportButton"
	import_btn.text = "IMPORT MOD"
	import_btn.disabled = true
	StencilStyle.style_button(import_btn)
	box.add_child(import_btn)
	var export_btn := Button.new()
	export_btn.name = "ExportButton"
	export_btn.text = "EXPORT MOD"
	export_btn.disabled = true
	StencilStyle.style_button(export_btn)
	box.add_child(export_btn)


# --- Form state -----------------------------------------------------------------

func get_selected_categories() -> Array:
	var out: Array = []
	for cat in CATEGORIES:
		var cb: CheckButton = _category_checks.get(cat)
		if cb != null and cb.button_pressed:
			out.append(cat)
	return out


func get_pending_candidate() -> Dictionary:
	return _pending_candidate


func get_pending_asset() -> Dictionary:
	return _pending_asset


func get_last_sandbox_result() -> Dictionary:
	return _last_sandbox_result


func _on_tab_changed(tab: int) -> void:
	if tab == 2:
		_refresh_mods()


func _on_close_pressed() -> void:
	_pending_candidate = {}
	_pending_projectile_asset = {}
	creator_closed.emit()
	queue_free()


# --- Generation -> approval -------------------------------------------------------

func _on_generate_pressed() -> void:
	var cats := get_selected_categories()
	if cats.is_empty():
		_status.text = "Pick at least one category."
		return
	if _name_input.text.strip_edges().is_empty():
		_status.text = "Give the mod a name."
		return
	if _visual_input.text.strip_edges().is_empty():
		_status.text = "Describe what it looks like."
		return
	if _logic_input.text.strip_edges().is_empty():
		_status.text = "Describe what it does."
		return
	# A form GENERATE owns the regenerate path from here on: the
	# chat-driven pending state no longer applies.
	_pending_chat_conversation = []
	_pending_chat_request = ""
	_chat_generation_pending = false
	_pending_prompt = compose_prompt(cats, _name_input.text, _visual_input.text, _logic_input.text)
	_start_generation(_pending_prompt)


func _on_regenerate_pressed() -> void:
	# Chat-driven generation regenerates WITH its conversation context;
	# form generation regenerates with its composed prompt (unchanged).
	if not _pending_chat_conversation.is_empty():
		_start_chat_generation(_pending_chat_conversation, _pending_chat_request)
		return
	if _pending_prompt.is_empty():
		return
	_start_generation(_pending_prompt)


func _start_generation(prompt: String) -> void:
	if _generating:
		return
	var creator := _creator_instance()
	if creator == null:
		_status.text = "Mod creation unavailable — creator not found."
		return
	_generating = true
	_generate_button.disabled = true
	_approval_panel.visible = false
	_status.text = "Generating…"
	creator.generate(prompt)


func _on_generation_ready(candidate: Dictionary) -> void:
	_generating = false
	_generate_button.disabled = false
	var err := str(candidate.get("error", ""))
	if not err.is_empty():
		_pending_candidate = {}
		_approval_panel.visible = false
		_status.text = "Generation failed: " + err
		# Chat-driven generation: surface the failure where the user
		# is — as a red bubble in the chat — and stay on the CHAT tab.
		# The pending conversation is kept, so REGENERATE retries it.
		if _chat_generation_pending:
			_chat_generation_pending = false
			if _chat_panel != null:
				_chat_panel.show_error("Generation failed: " + err)
		return
	# Chat-driven generation succeeded: its approval screen lives on
	# the CREATE tab — switch there so the user sees it. The pending
	# conversation is kept, so REGENERATE retries it with context.
	if _chat_generation_pending:
		_chat_generation_pending = false
		_tabs.current_tab = 0
	_pending_candidate = candidate
	# Voxel asset from the VISUAL DESCRIPTION (local, cached) — the WEAPON.
	_pending_asset = VoxelAssetGenerator.get_or_generate(_visual_input.text)
	# Projectile asset: what the mod FIRES, derived from logic/payload —
	# never the weapon visual (a pistol's barrel is not its bullet).
	var proj_desc := projectile_description_for(get_selected_categories(), _logic_input.text, str(candidate.get("payload", "")))
	if proj_desc.is_empty():
		_pending_projectile_asset = _pending_asset
	else:
		_pending_projectile_asset = VoxelAssetGenerator.get_or_generate(proj_desc)
	_status.text = "Review the mod below — nothing is installed until you tap Install."
	_show_approval(candidate)


func _show_approval(candidate: Dictionary) -> void:
	var lines: Array[String] = []
	for key in ["name", "mod_id", "kind"]:
		var v := str(candidate.get(key, ""))
		if not v.is_empty():
			lines.append("%s: %s" % [key.capitalize(), v])
	var manifest: Variant = candidate.get("manifest", {})
	if manifest is Dictionary:
		for key in (manifest as Dictionary).keys():
			if lines.size() >= 16:
				break
			var v: Variant = (manifest as Dictionary)[key]
			if v is String or v is int or v is float or v is bool:
				lines.append("%s: %s" % [str(key), str(v)])
	var summary := str(candidate.get("summary", ""))
	if not summary.is_empty():
		lines.append("")
		lines.append(summary)
	_approval_summary.text = "\n".join(lines)
	# v0.5.3: invented hooks, listed EXPLICITLY (no silent installs).
	var hooks := ModHook.preview_hooks_for_candidate(candidate)
	var hook_lines := ModHook.summarize_hooks(hooks)
	if hook_lines.is_empty():
		hook_lines = ["No new hooks — this mod uses existing blocks only."]
	_approval_hooks.text = "\n".join(hook_lines)
	_approval_code.text = str(candidate.get("payload", ""))
	_approval_code.scroll_vertical = 0
	_approval_code.scroll_horizontal = 0
	# v0.5.6: hook scripts (code hooks) get their own labelled,
	# readable section — decoded source, not JSON-escaped. Pure
	# table-effects mods show nothing here.
	var script_parts: Array[String] = []
	for h in hooks:
		if not (h is Dictionary):
			continue
		var hd := h as Dictionary
		var code := str(hd.get("code", ""))
		if code.strip_edges().is_empty():
			continue
		script_parts.append("--- Hook script: %s (%s) — %s ---\n%s" % [
			str(hd.get("hook_id", "?")), str(hd.get("hook_point", "?")),
			str(hd.get("display_name", "")), code])
	var has_script := not script_parts.is_empty()
	_approval_script_label.visible = has_script
	_approval_script_toggle.visible = has_script
	_approval_script_collapsed = false
	_approval_script_toggle.text = "HIDE HOOK SCRIPT"
	if has_script:
		_approval_script.text = "\n\n".join(script_parts)
		_approval_script.scroll_vertical = 0
		_approval_script.scroll_horizontal = 0
	_approval_script.visible = has_script
	_asset_info.text = "Voxel asset: " + VoxelAssetGenerator.summarize(_pending_asset) + " — visual: " + _visual_input.text.strip_edges().left(120)
	if bool(_pending_asset.get("cache_hit", false)):
		_asset_info.text += " (reused from an earlier generation with the same description)"
	_approval_status.text = ""
	# A fresh candidate re-enables Install (the sandbox may have
	# disabled it for a previous candidate).
	_install_button.disabled = false
	_approval_panel.visible = true


func _creator_instance() -> ModCreator:
	if _creator != null and is_instance_valid(_creator):
		return _creator
	_creator = ModCreator.new()
	_creator.generation_ready.connect(_on_generation_ready)
	add_child(_creator)
	return _creator


# --- Approval actions -------------------------------------------------------------

## v0.5.6: collapses/expands the hook-script source view.
func _on_script_toggle_pressed() -> void:
	_approval_script_collapsed = not _approval_script_collapsed
	_approval_script.visible = not _approval_script_collapsed
	_approval_script_toggle.text = "SHOW HOOK SCRIPT" if _approval_script_collapsed else "HIDE HOOK SCRIPT"


func _on_install_pressed() -> void:
	if _pending_candidate.is_empty():
		return
	var creator := _creator_instance()
	var err := creator.install(_pending_candidate)
	if err.is_empty():
		_pending_candidate = {}
		_pending_projectile_asset = {}
		_approval_panel.visible = false
		_status.text = "Installed."
		_refresh_mods()
	else:
		_approval_status.text = "Install failed: " + err


func _on_discard_pressed() -> void:
	_pending_candidate = {}
	_pending_asset = {}
	_pending_projectile_asset = {}
	_approval_panel.visible = false
	_install_button.disabled = false
	_status.text = "Discarded — nothing installed."


func _on_sandbox_pressed() -> void:
	if _pending_candidate.is_empty():
		return
	var behavior := behavior_for(get_selected_categories(), _logic_input.text, str(_pending_candidate.get("payload", "")))
	# v0.5.3: script candidates carry their hooks in get_hooks(), which
	# behavior_for (pure payload-JSON parsing) cannot see — merge the
	# previewed hooks in so the sandbox exercises them too.
	var previewed := ModHook.preview_hooks_for_candidate(_pending_candidate)
	if not previewed.is_empty():
		_merge_hooks_into_behavior(behavior, previewed)
	var sandbox: SandboxTestRoom
	if ResourceLoader.exists("res://scenes/ui/sandbox_test_room.tscn"):
		var ps := load("res://scenes/ui/sandbox_test_room.tscn") as PackedScene
		sandbox = ps.instantiate() as SandboxTestRoom
	else:
		sandbox = SandboxTestRoom.new()
	sandbox.name = "SandboxTestRoom"
	add_child(sandbox)
	sandbox.sandbox_closed.connect(_on_sandbox_closed)
	# 1st asset arg = the PROJECTILE (what flies); 4th arg = the weapon
	# visual, shown static at the shooter.
	var proj := _pending_projectile_asset if not _pending_projectile_asset.is_empty() else _pending_asset
	sandbox.open(_pending_candidate, proj, behavior, _pending_asset)


func _on_sandbox_closed(result: Dictionary) -> void:
	_last_sandbox_result = result
	# v0.5.6: a hook script that failed in the sandbox disables the
	# candidate visibly — Install goes dead with the reason. Discard
	# or Regenerate to move on; a fresh candidate re-enables Install.
	if bool(result.get("candidate_disabled", false)):
		var herr := str(result.get("hook_error", "hook script failed in the sandbox"))
		_status.text = "Sandbox: candidate DISABLED — " + herr
		_approval_status.text = "Sandbox disabled this candidate: " + herr + " — discard it or regenerate."
		_install_button.disabled = true
		return
	if bool(result.get("hit", false)) and bool(result.get("explosion_fired", false)):
		_status.text = "Sandbox: HIT — projectile exploded on impact. Install still available."
	elif bool(result.get("hit", false)):
		_status.text = "Sandbox: HIT — no explosion. Install still available."
	elif bool(result.get("placed", false)):
		_status.text = "Sandbox: block placed in the test room. Install still available."
	elif not result.is_empty():
		_status.text = "Sandbox: no hit. Install still available."


# --- MODS tab ----------------------------------------------------------------------

func _refresh_mods() -> void:
	if _mods_list == null:
		return
	for child in _mods_list.get_children():
		_mods_list.remove_child(child)
		child.queue_free()
	if _mods_path_label != null:
		_mods_path_label.text = "Mods folder: " + OS.get_user_data_dir() + "/mods"
	# Same source as the Forge menu: ModLoader.get_mods(). No second list.
	# "assets" is the voxel-asset cache dir, not a mod — filtered out.
	var mods := ModLoader.get_mods()
	if mods.is_empty():
		var lbl := Label.new()
		lbl.text = "No mods installed — create one on the CREATE tab."
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		StencilStyle.apply_body(lbl, 17, StencilStyle.TEXT_DIM, 2)
		_mods_list.add_child(lbl)
		return
	for m in mods:
		if not (m is Dictionary):
			continue
		var mod := m as Dictionary
		if str(mod.get("id", "")) == "assets":
			continue
		_add_mod_row(mod)


func _add_mod_row(mod: Dictionary) -> void:
	var mod_id := str(mod.get("id", ""))
	var wrap := VBoxContainer.new()
	wrap.name = "ModRow_" + mod_id
	_mods_list.add_child(wrap)
	var row := HBoxContainer.new()
	row.name = "ModRow"
	wrap.add_child(row)
	var name_lbl := Label.new()
	name_lbl.name = "ModName"
	name_lbl.text = str(mod.get("name", mod_id))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(name_lbl, 19, StencilStyle.TEXT, 2)
	row.add_child(name_lbl)
	var kind_lbl := Label.new()
	kind_lbl.text = str(mod.get("kind", ""))
	StencilStyle.apply_body(kind_lbl, 17, StencilStyle.TEXT_DIM, 2)
	row.add_child(kind_lbl)
	var toggle := CheckButton.new()
	toggle.name = "ModToggle"
	toggle.text = "ON"
	toggle.button_pressed = bool(mod.get("enabled", false))
	toggle.toggled.connect(_on_mod_toggle.bind(mod_id))
	row.add_child(toggle)
	var err := str(mod.get("error", ""))
	if not err.is_empty():
		var err_lbl := Label.new()
		err_lbl.name = "ModError"
		err_lbl.text = err
		err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		StencilStyle.apply_body(err_lbl, 16, StencilStyle.RED, 2)
		wrap.add_child(err_lbl)


func _on_mod_toggle(mod_id: String, enable: bool) -> void:
	ModLoader.set_mod_enabled(mod_id, enable)
	_refresh_mods()


func _on_mods_rescan_pressed() -> void:
	ModLoader.rescan()
	_refresh_mods()
