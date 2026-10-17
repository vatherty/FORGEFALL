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
#   IMPORT/EXPORT (v0.5.10, Worker B) — share mods as one copy-pasteable
#     code (MOD1-...). EXPORT turns an installed mod into a code
#     (pipeline: export_mod) shown in a copyable field + COPY button.
#     IMPORT pastes a code, decodes/validates it via the pipeline
#     (import_code), and shows the SAME approval screen as generation
#     (summary + full payload + invented hooks + hook script source)
#     before anything installs. A conflict (an installed mod already
#     claims the id OR the payload's block_id — a folder-collision
#     with a different block_id counts too) offers REPLACE (version
#     bump) or KEEP BOTH (renamed copy) — never a silent overwrite,
#     never a dead end. Invalid / tampered codes show the pipeline's
#     visible rejection reason. NEVER installs on import without
#     approval. The UI owns NO encode/decode/validation — all of that
#     is the pipeline in scripts/mods/* (see _share_target for the
#     resolved API). When the pipeline exposes install_import_result /
#     install_imported, Install routes through it (it owns the
#     pre-rewritten script Keep Both candidate); otherwise the
#     ModCreator paths (install / install_update / "<id>_copy" rename
#     + install) are the write path.
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
# Sharing-pipeline method-name aliases (Worker C's suite probes the
# same lists): the pipeline may expose any of these; the menu tries
# each in order and uses the first that exists.
const _SHARE_EXPORT_NAMES := ["export_mod", "export_code", "encode_mod", "share_export",
	"export_share_code", "make_share_code", "create_share_code"]
const _SHARE_IMPORT_NAMES := ["import_code", "import_mod", "decode_mod", "decode_mod_code",
	"parse_share_code", "import_share_code", "decode_share_code"]

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
# v0.5.9 EDIT: diff vs the installed version (ModCreator.
# diff_candidate_vs_installed). Visible only while editing.
var _approval_diff: Label
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
# EDIT state (v0.5.9): the installed mod being refined. "" = creating
# fresh. _edit_original is ModCreator.load_installed() output for the
# diff + the version bump. The ChatSession carries the same context
# (it survives reopening the menu); _restore_edit_state() re-syncs
# these from the session in _ready().
var _editing_mod_id := ""
var _edit_original: Dictionary = {}
# IMPORT/EXPORT tab (v0.5.10): picker + code field + import approval.
# The import approval is its OWN panel on this tab (same CONTENT as the
# CREATE approval — summary + payload + hooks + hook script source —
# not the same panel), so the user never leaves the tab mid-import and
# the conflict choice (Replace / Keep Both) stays next to Install.
var _ie_export_picker: OptionButton
var _ie_export_ids: Array = []
var _ie_export_button: Button
var _ie_export_rescan_button: Button
var _ie_export_code: TextEdit
var _ie_copy_button: Button
var _ie_export_status: Label
var _ie_import_input: TextEdit
var _ie_import_button: Button
var _ie_import_paste_button: Button
var _ie_import_status: Label
var _ie_import_approval: VBoxContainer
var _ie_import_summary: Label
var _ie_import_hooks: Label
var _ie_import_diff: Label
var _ie_import_payload: TextEdit
var _ie_import_script_label: Label
var _ie_import_script_toggle: Button
var _ie_import_script: TextEdit
var _ie_import_script_collapsed := false
var _ie_conflict_row: HBoxContainer
var _ie_replace_toggle: Button
var _ie_keepboth_toggle: Button
var _ie_import_install_button: Button
var _ie_import_discard_button: Button
var _ie_import_approval_status: Label
var _ie_import_candidate: Dictionary = {}
var _ie_import_conflict := false
var _ie_import_existing_id := ""
var _ie_import_existing: Dictionary = {}
## Import resolution: "" = none chosen yet, "fresh" = no conflict,
## "replace" = overwrite the installed mod (version bump),
## "keepboth" = install as a renamed copy. Install stays disabled
## while a conflict has no resolution — no silent overwrite, ever.
var _ie_import_resolution := ""
var _ie_import_raw: Dictionary = {}
var _ie_import_keepboth_candidate: Dictionary = {}
var _ie_import_resolutions: Array = []
var _ie_import_replace_available := true
var _ie_import_keepboth_available := true
var _ie_share_target: Variant = null
var _ie_share_target_checked := false


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
	lines.append("HOOKS — PREFER THE EFFECT-KINDS TABLE (follow exactly): if the mod needs behaviour no existing block covers (a custom projectile, heal-on-kill, thorns, an on-hit explosion, ...), add a HOOK for it — prefer the table below whenever it covers the request; write a hook SCRIPT only when nothing in the table covers it. Block mod: add a top-level \"hooks\" array to the payload, next to the \"block\" object. Script mod: implement get_hooks() -> Array returning the hook dicts. Hook dict: {\"hook_id\": \"<lowercase [a-z0-9_]>\", \"hook_point\": \"on_fire\"|\"projectile_spawn\"|\"on_hit\"|\"on_kill\"|\"on_damage_taken\"|\"take_damage\", \"display_name\": \"<name>\", \"description\": \"<one line>\", ...}. A fire-point hook (on_fire / projectile_spawn) may carry \"projectile\": {\"visual\": \"<what it looks like>\", \"shape\": \"beam\"|\"sphere\"|\"cube\"|\"blob\"|\"bullet\", \"speed\": 1-200, \"damage\": 0-500 (-1 = use the weapon's damage), \"range\": 1-500, \"size\": 0.05-5, \"gravity\": -50-50, \"pierce\": true|false, \"explodes_on_impact\": true|false, \"explosion_radius\": 0-20, \"explosion_damage\": 0-500}. Any hook may carry \"effects\": [{\"kind\": \"heal\", \"amount\": 1-500} | {\"kind\": \"explosion\", \"radius\": 0.5-20, \"damage\": 0-500} | {\"kind\": \"smoke\", \"duration_sec\": 1-120} | {\"kind\": \"announce\", \"title\": \"...\", \"subtitle\": \"...\"} | {\"kind\": \"damage_mult\", \"value\": 0-5} | {\"kind\": \"slow\", \"factor\": 0.05-1.0, \"duration_sec\": 0.5-30} | {\"kind\": \"freeze\", \"duration_sec\": 0.5-10} | {\"kind\": \"burn\", \"damage_per_sec\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"knockback\", \"force\": 1-30} | {\"kind\": \"pull\", \"force\": 1-30} | {\"kind\": \"poison\", \"damage_per_sec\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"bleed\", \"damage_per_sec\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"regen\", \"heal_per_sec\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"haste\", \"factor\": 1.05-2.5, \"duration_sec\": 0.5-30} | {\"kind\": \"restrained\", \"duration_sec\": 0.5-10} | {\"kind\": \"prone\", \"force\": 1-30, \"duration_sec\": 0.5-10} | {\"kind\": \"sleep\", \"duration_sec\": 0.5-30} | {\"kind\": \"confusion\", \"force\": 1-10, \"duration_sec\": 0.5-30} | {\"kind\": \"blind\", \"factor\": 0.05-1.0, \"duration_sec\": 0.5-30} | {\"kind\": \"weaken\", \"factor\": 0.05-1.0, \"duration_sec\": 0.5-30} | {\"kind\": \"exhaustion\", \"duration_sec\": 0.5-60} | {\"kind\": \"typed_damage\", \"damage_type\": \"acid\"|\"cold\"|\"fire\"|\"lightning\"|\"necrotic\"|\"poison\"|\"psychic\"|\"radiant\"|\"thunder\", \"amount\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"shield\", \"amount\": 1-500, \"duration_sec\": 0.5-30} | {\"kind\": \"vulnerable\", \"factor\": 1.05-5.0, \"duration_sec\": 0.5-30} | {\"kind\": \"thorns\", \"reflect_mult\": 0.0-2.0, \"duration_sec\": 0.5-30} | {\"kind\": \"petrified\", \"duration_sec\": 0.5-30}]. STATUS EFFECTS (every status kind needs a target: put them on on_hit / on_kill (hit target), on_damage_taken (player), or take_damage (the character about to be hurt); NEVER on a fire point. slow multiplies movement speed by factor (0.5 = half speed); freeze pins: speed 0 AND knockback cannot move it; burn is pure damage over time; knockback shoves AWAY from the hit point, pull yanks TOWARD it; poison is damage over time PLUS a mild slow (x0.85); bleed is damage over time that ticks FASTER while the target moves; regen heals over time; haste multiplies movement speed only (not fire rate); restrained is speed 0 but can act and can be shoved; prone knocks down (impulse + speed 0) then stands back up; sleep is speed 0 + pinned and WAKES EARLY on any damage; confusion stumbles randomly; blind disrupts accuracy; weaken reduces damage dealt; exhaustion stacks +1 level per application (6 = death); typed_damage deals instant damage of one D&D type + a rider (fire burns, cold slows, lightning knocks back, thunder knocks back hard + prone, acid weakens, necrotic exhausts, poison poisons, psychic confuses, radiant blinds). DAMAGE-INTERCEPTION KINDS (real, via the take_damage hook point): shield is an absorbing pool (amount 1-500, re-applying ADDS to the pool); vulnerable multiplies incoming damage (factor 1.05-5.0 — mark an enemy so FOLLOW-UP hits deal more); thorns reflects reflect_mult (0.0-2.0) x the damage actually taken back to the attacker; petrified nullifies ALL incoming damage AND pins the target (damage does not break it; constructs + elementals are immune). TAKE_DAMAGE (pre-damage hook point): a take_damage hook fires when a character WOULD take damage, BEFORE it applies — its damage_mult scales THIS hit, and a shield/vulnerable/thorns/petrified effect on it applies to THIS hit and later hits. Do NOT invent stunned / paralyzed / unconscious / grappled / frightened / charmed / silence / lifesteal / curse — they are not kinds; use the real kinds above. A slowing bubble is an on_hit hook with effects [{\"kind\": \"slow\", \"factor\": 0.5, \"duration_sec\": 3.0}] — never express slowing as smoke or announce. HOOK SCRIPT (only when the table cannot express the behaviour, e.g. pulling the hit target toward the player): the hook dict carries \"code\": GDScript source starting with `extends ModHook` and implementing run(api: ModAPI, ctx: Dictionary) -> Dictionary with ONLY allowlisted calls (api.<ModAPI method>, ctx.get/has/..., pure value methods; NEVER node properties like .global_position/.position/.hp, NEVER api properties like api.last_spawned), bounded for loops (range <= 1000), no while/recursion/engine callbacks. A hook with \"code\" runs ONLY its code — \"effects\" on the same hook are ignored. Never put filesystem, network, OS, eval, or code-loading code in a hook.")
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
	StencilStyle.install_menu(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh_mods()
	_refresh_export_picker()
	_restore_edit_state()


## Re-syncs EDIT state from the ChatSession (v0.5.9): an edit in
## progress survives reopening the menu (the session persists the
## context). A stale context (mod uninstalled since) is dropped.
func _restore_edit_state() -> void:
	if _chat_session == null or not _chat_session.is_editing():
		return
	var mod_id := _chat_session.get_edit_mod_id()
	var loaded := ModCreator.load_installed(mod_id)
	if str(loaded.get("error", "")) != "":
		_chat_session.clear_edit()
		return
	_editing_mod_id = mod_id
	_edit_original = loaded
	_status.text = "Editing '%s' (v%s) — describe the change, then GENERATE. Discard abandons the edit." % [
		str(loaded.get("name", mod_id)), str(loaded.get("version", ""))]


func _build() -> void:
	StencilStyle.cinematic_background(self, "workshop", 0.18, false)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	add_child(panel)
	var vb := VBoxContainer.new()
	vb.name = "CreatorStack"
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	panel.resized.connect(func() -> void: panel.add_theme_stylebox_override("panel", _workshop_panel_style()))
	panel.add_theme_stylebox_override("panel", _workshop_panel_style())
	StencilStyle.eyebrow(vb, "MOD WORKSHOP")
	var head_row := HBoxContainer.new()
	vb.add_child(head_row)
	var head := Label.new()
	StencilStyle.apply_title(head, 40, StencilStyle.TEXT, 0)
	head.text = "CREATE A MOD"
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(head)
	var close := Button.new()
	close.name = "CloseButton"
	close.text = "BACK"
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
	box.add_child(_section_label("TYPE — choose any"))
	var cat_row := HFlowContainer.new()
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
	box.add_child(_section_label("APPEARANCE"))
	_visual_input = TextEdit.new()
	_visual_input.name = "VisualInput"
	_visual_input.placeholder_text = "e.g. a green watermelon with dark stripes and a red interior"
	_visual_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_visual_input.custom_minimum_size = Vector2(0, 90)
	box.add_child(_visual_input)
	# (4) LOGIC.
	box.add_child(_section_label("BEHAVIOR"))
	_logic_input = TextEdit.new()
	_logic_input.name = "LogicInput"
	_logic_input.placeholder_text = "e.g. an LMG that shoots watermelons. The watermelons explode on impact."
	_logic_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_logic_input.custom_minimum_size = Vector2(0, 110)
	box.add_child(_logic_input)
	_generate_button = Button.new()
	_generate_button.name = "GenerateButton"
	_generate_button.text = "GENERATE"
	StencilStyle.primary_button(_generate_button)
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
	# v0.5.9 EDIT: diff vs the installed version — shown ONLY while
	# editing, before Install, so an update is never a blind overwrite.
	_approval_diff = Label.new()
	_approval_diff.name = "ApprovalDiff"
	_approval_diff.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_approval_diff, 18, StencilStyle.TEXT, 2)
	_approval_diff.visible = false
	_approval_panel.add_child(_approval_diff)
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
	StencilStyle.primary_button(_install_button)
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
	# v0.5.9 EDIT: same preamble as the form path (the panel's own
	# CREATE FROM CHAT call prepends it too — the stored request
	# stays raw, so REGENERATE never double-prepends).
	var effective := request
	if _editing_mod_id != "" and _chat_session != null and _chat_session.is_editing():
		effective = ChatSession.edit_preamble(_chat_session.get_edit_context()) + "\n\n" + request
	creator.call("generate_with_context", conversation, effective)


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
	hint.text = "Same installed mods as the Forge menu — list / enable / disable / EDIT / Rescan."
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


# --- IMPORT/EXPORT tab (v0.5.10) ----------------------------------------------
# Layout rule (the v0.5.2 Mods-tab bug must not recur): EVERY label
# that can hold a long string gets autowrap + SIZE_EXPAND_FILL, every
# TextEdit gets SIZE_EXPAND_FILL, and the share code lives in a
# wrapping TextEdit — never in a bare Label, never a 1-char-wide
# column. The tab scrolls vertically; nothing inside scrolls
# horizontally except the code/payload TextEdits themselves.

func _build_import_export_tab() -> void:
	var scroll := _tab_scroll("ImportExportTab")
	_tabs.set_tab_title(3, CREATOR_TABS[3])
	var box := VBoxContainer.new()
	box.name = "ImportExportBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	# How sharing works.
	var howto := Label.new()
	howto.name = "ImportExportHowTo"
	howto.text = "HOW SHARING WORKS — Mods travel as a single code. Export one, paste it into any chat or message, and the other player pastes it here to import it. Works offline — no account, no server, no files to move."
	howto.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	howto.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(howto, 18, StencilStyle.TEXT_DIM, 2)
	box.add_child(howto)
	# --- EXPORT ---
	box.add_child(_section_label("EXPORT — turn an installed mod into a shareable code"))
	var picker_row := HBoxContainer.new()
	picker_row.name = "ExportPickerRow"
	box.add_child(picker_row)
	_ie_export_picker = OptionButton.new()
	_ie_export_picker.name = "ExportPicker"
	_ie_export_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker_row.add_child(_ie_export_picker)
	_ie_export_rescan_button = Button.new()
	_ie_export_rescan_button.name = "ExportRescanButton"
	_ie_export_rescan_button.text = "REFRESH"
	StencilStyle.style_button(_ie_export_rescan_button)
	_ie_export_rescan_button.pressed.connect(_refresh_export_picker)
	picker_row.add_child(_ie_export_rescan_button)
	var export_row := HBoxContainer.new()
	export_row.name = "ExportButtonRow"
	box.add_child(export_row)
	_ie_export_button = Button.new()
	_ie_export_button.name = "ExportButton"
	_ie_export_button.text = "EXPORT"
	_ie_export_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_button(_ie_export_button)
	_ie_export_button.pressed.connect(_on_export_pressed)
	export_row.add_child(_ie_export_button)
	_ie_copy_button = Button.new()
	_ie_copy_button.name = "CopyButton"
	_ie_copy_button.text = "COPY"
	StencilStyle.style_button(_ie_copy_button)
	_ie_copy_button.pressed.connect(_on_copy_pressed)
	export_row.add_child(_ie_copy_button)
	_ie_export_code = TextEdit.new()
	_ie_export_code.name = "ExportCode"
	_ie_export_code.editable = false
	_ie_export_code.placeholder_text = "Your share code appears here after EXPORT."
	_ie_export_code.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_ie_export_code.custom_minimum_size = Vector2(0, 120)
	_ie_export_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_ie_export_code)
	_ie_export_status = Label.new()
	_ie_export_status.name = "ExportStatus"
	_ie_export_status.text = ""
	_ie_export_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ie_export_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(_ie_export_status, 17, StencilStyle.TEXT_DIM, 2)
	box.add_child(_ie_export_status)
	# --- IMPORT ---
	box.add_child(_section_label("IMPORT — paste a share code from another player"))
	_ie_import_input = TextEdit.new()
	_ie_import_input.name = "ImportInput"
	_ie_import_input.placeholder_text = "Paste a MOD1-... code here"
	_ie_import_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_ie_import_input.custom_minimum_size = Vector2(0, 120)
	_ie_import_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_ie_import_input)
	var import_row := HBoxContainer.new()
	import_row.name = "ImportButtonRow"
	box.add_child(import_row)
	_ie_import_button = Button.new()
	_ie_import_button.name = "ImportButton"
	_ie_import_button.text = "IMPORT"
	_ie_import_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_button(_ie_import_button)
	_ie_import_button.pressed.connect(_on_import_pressed)
	import_row.add_child(_ie_import_button)
	_ie_import_paste_button = Button.new()
	_ie_import_paste_button.name = "ImportPasteButton"
	_ie_import_paste_button.text = "PASTE FROM CLIPBOARD"
	StencilStyle.style_button(_ie_import_paste_button)
	_ie_import_paste_button.pressed.connect(_on_import_paste_pressed)
	import_row.add_child(_ie_import_paste_button)
	_ie_import_status = Label.new()
	_ie_import_status.name = "ImportStatus"
	_ie_import_status.text = ""
	_ie_import_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ie_import_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(_ie_import_status, 17, StencilStyle.TEXT_DIM, 2)
	box.add_child(_ie_import_status)
	# --- IMPORT APPROVAL (same content as the CREATE approval) ---
	_ie_import_approval = VBoxContainer.new()
	_ie_import_approval.name = "ImportApprovalPanel"
	_ie_import_approval.visible = false
	_ie_import_approval.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_ie_import_approval)
	var approval_title := Label.new()
	approval_title.text = "REVIEW IMPORT — nothing is installed until you tap Install."
	approval_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	approval_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(approval_title, 18, StencilStyle.ORANGE, 2)
	_ie_import_approval.add_child(approval_title)
	_ie_import_summary = Label.new()
	_ie_import_summary.name = "ImportApprovalSummary"
	_ie_import_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ie_import_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(_ie_import_summary, 18, StencilStyle.TEXT, 2)
	_ie_import_approval.add_child(_ie_import_summary)
	_ie_import_hooks = Label.new()
	_ie_import_hooks.name = "ImportApprovalHooks"
	_ie_import_hooks.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ie_import_hooks.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(_ie_import_hooks, 18, StencilStyle.ORANGE, 2)
	_ie_import_approval.add_child(_ie_import_hooks)
	_ie_import_diff = Label.new()
	_ie_import_diff.name = "ImportApprovalDiff"
	_ie_import_diff.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ie_import_diff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(_ie_import_diff, 18, StencilStyle.TEXT, 2)
	_ie_import_diff.visible = false
	_ie_import_approval.add_child(_ie_import_diff)
	_ie_import_payload = TextEdit.new()
	_ie_import_payload.name = "ImportApprovalPayload"
	_ie_import_payload.editable = false
	_ie_import_payload.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_ie_import_payload.custom_minimum_size = Vector2(0, 240)
	_ie_import_payload.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ie_import_approval.add_child(_ie_import_payload)
	_ie_import_script_label = Label.new()
	_ie_import_script_label.name = "ImportApprovalScriptLabel"
	_ie_import_script_label.text = "LLM-AUTHORED HOOK SCRIPT — this mod contains a hook script written by the LLM (not a table effect). Read the full source below before installing."
	_ie_import_script_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ie_import_script_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(_ie_import_script_label, 18, StencilStyle.RED, 2)
	_ie_import_script_label.visible = false
	_ie_import_approval.add_child(_ie_import_script_label)
	_ie_import_script_toggle = Button.new()
	_ie_import_script_toggle.name = "ImportApprovalScriptToggle"
	_ie_import_script_toggle.text = "HIDE HOOK SCRIPT"
	StencilStyle.style_button(_ie_import_script_toggle)
	_ie_import_script_toggle.pressed.connect(_on_import_script_toggle_pressed)
	_ie_import_script_toggle.visible = false
	_ie_import_approval.add_child(_ie_import_script_toggle)
	_ie_import_script = TextEdit.new()
	_ie_import_script.name = "ImportApprovalScript"
	_ie_import_script.editable = false
	_ie_import_script.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_ie_import_script.custom_minimum_size = Vector2(0, 240)
	_ie_import_script.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ie_import_script.visible = false
	_ie_import_approval.add_child(_ie_import_script)
	# Conflict choice — visible ONLY on conflict. Toggle buttons in
	# one ButtonGroup: exactly one resolution at a time, and tapping
	# the selected one again clears it (Install goes dead again).
	_ie_conflict_row = HBoxContainer.new()
	_ie_conflict_row.name = "ImportConflictRow"
	_ie_conflict_row.visible = false
	_ie_import_approval.add_child(_ie_conflict_row)
	var conflict_lbl := Label.new()
	conflict_lbl.text = "Already installed — choose:"
	conflict_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	conflict_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(conflict_lbl, 18, StencilStyle.TEXT, 2)
	_ie_conflict_row.add_child(conflict_lbl)
	var conflict_group := ButtonGroup.new()
	_ie_replace_toggle = Button.new()
	_ie_replace_toggle.name = "ImportReplaceButton"
	_ie_replace_toggle.text = "REPLACE"
	_ie_replace_toggle.toggle_mode = true
	_ie_replace_toggle.button_group = conflict_group
	StencilStyle.style_button(_ie_replace_toggle)
	_ie_replace_toggle.toggled.connect(_on_import_resolution_toggled.bind("replace"))
	_ie_conflict_row.add_child(_ie_replace_toggle)
	_ie_keepboth_toggle = Button.new()
	_ie_keepboth_toggle.name = "ImportKeepBothButton"
	_ie_keepboth_toggle.text = "KEEP BOTH"
	_ie_keepboth_toggle.toggle_mode = true
	_ie_keepboth_toggle.button_group = conflict_group
	StencilStyle.style_button(_ie_keepboth_toggle)
	_ie_keepboth_toggle.toggled.connect(_on_import_resolution_toggled.bind("keepboth"))
	_ie_conflict_row.add_child(_ie_keepboth_toggle)
	var approval_btn_row := HBoxContainer.new()
	approval_btn_row.name = "ImportApprovalButtonRow"
	_ie_import_approval.add_child(approval_btn_row)
	_ie_import_install_button = Button.new()
	_ie_import_install_button.name = "ImportApprovalInstallButton"
	_ie_import_install_button.text = "INSTALL"
	StencilStyle.primary_button(_ie_import_install_button)
	_ie_import_install_button.pressed.connect(_on_import_install_pressed)
	approval_btn_row.add_child(_ie_import_install_button)
	_ie_import_discard_button = Button.new()
	_ie_import_discard_button.name = "ImportApprovalDiscardButton"
	_ie_import_discard_button.text = "DISCARD"
	StencilStyle.style_button(_ie_import_discard_button)
	_ie_import_discard_button.pressed.connect(_on_import_discard_pressed)
	approval_btn_row.add_child(_ie_import_discard_button)
	_ie_import_approval_status = Label.new()
	_ie_import_approval_status.name = "ImportApprovalStatus"
	_ie_import_approval_status.text = ""
	_ie_import_approval_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ie_import_approval_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.apply_body(_ie_import_approval_status, 17, StencilStyle.RED, 2)
	_ie_import_approval.add_child(_ie_import_approval_status)


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
	if tab == 3:
		_refresh_export_picker()


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
	# v0.5.9 EDIT: the original mod's payload rides along, so the
	# model refines THAT mod instead of generating a fresh one.
	if _editing_mod_id != "" and _chat_session != null and _chat_session.is_editing():
		prompt = ChatSession.edit_preamble(_chat_session.get_edit_context()) + "\n\n" + prompt
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
	# v0.5.8 spell schools (tag only): show the school in approval so
	# nothing about the mod is hidden. Fall back to the payload
	# (block wrapper / script comment) when the candidate predates
	# the top-level school field.
	var school := SpellSchools.normalize(str(candidate.get("spell_school", "")))
	if school.is_empty():
		school = SpellSchools.parse_from_payload(str(candidate.get("payload", "")))
	var school_line := SpellSchools.approval_line(school)
	if not school_line.is_empty():
		lines.append(school_line)
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
	# v0.5.9 EDIT: the approval shows a DIFF vs the installed
	# version (what changed), and Install becomes INSTALL UPDATE.
	if _editing_mod_id != "" and not _edit_original.is_empty():
		var diff_lines := ModCreator.diff_candidate_vs_installed(candidate, _edit_original)
		_approval_diff.text = "UPDATE '%s' — what changes vs the installed version:\n%s" % [
			str(_edit_original.get("name", _editing_mod_id)), "\n".join(diff_lines)]
		_approval_diff.visible = true
		_install_button.text = "INSTALL UPDATE"
	else:
		_approval_diff.visible = false
		_install_button.text = "INSTALL"
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
	# v0.5.9 EDIT: an edit installs as an UPDATE to the same mod
	# (same id, version bumped, old version gone). A fresh candidate
	# installs as a new mod.
	if _editing_mod_id != "" and not _edit_original.is_empty():
		var new_version := ModCreator.bump_version(str(_edit_original.get("version", "1.0")))
		var err := creator.install_update(_pending_candidate, _editing_mod_id)
		if err.is_empty():
			_pending_candidate = {}
			_pending_projectile_asset = {}
			_approval_panel.visible = false
			_status.text = "Updated to v%s." % new_version
			_clear_edit_state()
			_refresh_mods()
		else:
			_approval_status.text = "Update failed: " + err
		return
	var err2 := creator.install(_pending_candidate)
	if err2.is_empty():
		_pending_candidate = {}
		_pending_projectile_asset = {}
		_approval_panel.visible = false
		_status.text = "Installed."
		_refresh_mods()
	else:
		_approval_status.text = "Install failed: " + err2


## Clears EDIT state (after a successful update, or on Discard).
## The installed mod is untouched by Discard — this only drops the
## in-progress edit (menu state + session context).
func _clear_edit_state() -> void:
	_editing_mod_id = ""
	_edit_original = {}
	_install_button.text = "INSTALL"
	_approval_diff.visible = false
	if _chat_session != null:
		_chat_session.clear_edit()


func _on_discard_pressed() -> void:
	_pending_candidate = {}
	_pending_asset = {}
	_pending_projectile_asset = {}
	_approval_panel.visible = false
	_install_button.disabled = false
	# v0.5.9 EDIT: Discard abandons the edit — the installed mod is
	# untouched (nothing was written). The form keeps the seeded
	# values so the player can start over from them.
	var was_editing := _editing_mod_id != ""
	_clear_edit_state()
	_status.text = "Edit discarded — installed mod untouched." if was_editing else "Discarded — nothing installed."


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
	# v0.5.9 EDIT: refine this installed mod instead of rerolling a
	# fresh one (seeds the creator with the mod's context).
	var edit_btn := Button.new()
	edit_btn.name = "ModEditButton"
	edit_btn.text = "EDIT"
	StencilStyle.style_button(edit_btn)
	edit_btn.pressed.connect(_on_mod_edit_pressed.bind(mod_id))
	row.add_child(edit_btn)
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


## EDIT (v0.5.9): seeds the creator with the installed mod's context
## (form fields + chat session) and switches to the CREATE tab, so
## "make the bubble bigger" refines THAT mod. The installed mod is
## untouched until an update is approved + installed; Discard
## abandons the edit. No-op while a generation is in flight.
func _on_mod_edit_pressed(mod_id: String) -> void:
	if _generating:
		_status.text = "Wait for the current generation to finish, then EDIT."
		return
	var ctx := ModCreator.edit_context_for(mod_id)
	if str(ctx.get("error", "")) != "":
		_status.text = "Cannot edit: " + str(ctx.get("error", ""))
		return
	var loaded := ModCreator.load_installed(mod_id)
	_editing_mod_id = mod_id
	_edit_original = loaded
	# Seed the form (categories / name / visual / logic).
	for cat in CATEGORIES:
		var cb: CheckButton = _category_checks.get(cat)
		if cb != null:
			cb.button_pressed = (cat in (ctx.get("categories", []) as Array))
	_name_input.text = str(ctx.get("name", ""))
	_visual_input.text = str(ctx.get("visual", ""))
	_logic_input.text = str(ctx.get("logic", ""))
	# Seed the chat session (announces the edit; the full context
	# rides in the session for generation requests).
	if _chat_session != null:
		_chat_session.begin_edit(ctx)
	if _chat_panel != null:
		_chat_panel.refresh_messages()
	_pending_candidate = {}
	_approval_panel.visible = false
	_status.text = "Editing '%s' (v%s) — describe the change, then GENERATE. Discard abandons the edit." % [
		str(ctx.get("name", mod_id)), str(ctx.get("version", ""))]
	_tabs.current_tab = 0


func _on_mods_rescan_pressed() -> void:
	ModLoader.rescan()
	_refresh_mods()


# --- IMPORT/EXPORT tab ----------------------------------------------------------
# PIPELINE CONTRACT (Worker A owns scripts/mods/* — this UI implements
# NONE of it: no base64, no JSON decode, no validation, no checksums):
#   export_mod(block_id: String) -> {ok, code, error} (or a bare
#       String code). Aliases in _SHARE_EXPORT_NAMES also accepted.
#   import_code(code: String) -> EITHER the pipeline shape:
#       {kind: "candidate"|"conflict"|"error", candidate: Dictionary,
#        candidate_keep_both: Dictionary, existing: Dictionary,
#        resolutions: [{action: "replace"|"keep_both", mod_id: String}],
#        error: String}
#     OR the legacy shape:
#       {ok, candidate, conflict: bool, existing_id: String,
#        existing: Dictionary, error: String}
#     OR a bare candidate-shaped Dictionary. A conflict is ANY of:
#     kind == "conflict", conflict == true, a non-empty "existing"
#     record, or a non-empty "resolutions" list — an EMPTY existing {}
#     does NOT mean conflict (the pipeline returns it for clean
#     candidates too). "resolutions" also gates the toggles: a
#     keep_both resolution with an EMPTY mod_id means the pipeline
#     cannot offer Keep Both.
#   install_import_result(raw_import_result, resolution) and
#   install_imported(candidate, resolution, existing_mod_id) — the
#   pipeline's write path when it exposes them (resolution:
#   "fresh" | "replace" | "keep_both"). The menu routes Install
#   through them when present; otherwise the ModCreator paths
#   (install / install_update / "<id>_copy" rename + install).
#   The candidate is the SAME shape as a generation candidate
#   (mod_id / name / kind / manifest / payload / summary), so the
#   import approval below reuses the same display rules as _show_approval.
# Resolution order: (1) a sharing script at
# scripts/mods/mod_share.gd (or mod_import_export.gd / mod_sharing.gd
# / mod_code.gd / mod_export.gd), loaded by path — found even though
# script global classes are NOT in ClassDB at runtime (verified
# headlessly); (2) export/import on the shared ModCreator instance;
# (3) the same on a ModLoader instance (static dispatch via .call
# works for both). When nothing resolves, the tab says so visibly
# instead of crashing or faking it. Cached per menu instance —
# reopening the menu re-resolves.

func _share_target() -> Variant:
	if _ie_share_target_checked:
		return _ie_share_target
	_ie_share_target_checked = true
	for path in ["res://scripts/mods/mod_share.gd",
			"res://scripts/mods/mod_import_export.gd",
			"res://scripts/mods/mod_sharing.gd",
			"res://scripts/mods/mod_code.gd",
			"res://scripts/mods/mod_export.gd"]:
		if ResourceLoader.exists(path):
			var scr = load(path)
			if scr != null and _has_any_method(scr, _SHARE_EXPORT_NAMES + _SHARE_IMPORT_NAMES):
				_ie_share_target = scr
				return _ie_share_target
	var creator := _creator_instance()
	if creator != null and _has_any_method(creator, _SHARE_EXPORT_NAMES + _SHARE_IMPORT_NAMES):
		_ie_share_target = creator
		return _ie_share_target
	var loader := ModLoader.new()
	if _has_any_method(loader, _SHARE_EXPORT_NAMES + _SHARE_IMPORT_NAMES):
		_ie_share_target = loader
		return _ie_share_target
	return null


## One pipeline call. Returns null when no pipeline resolved (the
## caller shows "sharing not available") or the method is missing on
## the resolved target — never a crash, never a local reimplementation.
func _has_any_method(target: Variant, names: Array) -> bool:
	if target == null:
		return false
	for n in names:
		if target.has_method(str(n)):
			return true
	return false


func _share_call_aliases(names: Array, args: Array) -> Variant:
	var target: Variant = _share_target()
	if target == null:
		return null
	for n in names:
		var name := str(n)
		if target.has_method(name):
			return target.callv(name, args)
	return null


## True when the pipeline exposes its own install path.
func _share_has_install() -> bool:
	var target: Variant = _share_target()
	if target == null:
		return false
	return target.has_method("install_import_result") or target.has_method("install_imported")


## A resolutions entry offers `action` ("replace" / "keep_both";
## "keepboth" spelling also accepted). A keep_both entry with an
## EMPTY mod_id means the pipeline cannot offer Keep Both. No
## resolutions at all (legacy shape) means both are offered.
func _resolution_available(resolutions: Array, action: String) -> bool:
	if resolutions.is_empty():
		return true
	for r in resolutions:
		if r is Dictionary:
			var a := str((r as Dictionary).get("action", ""))
			if a == action or (action == "keep_both" and a == "keepboth"):
				if action == "keep_both" and (r as Dictionary).has("mod_id"):
					return str((r as Dictionary).get("mod_id", "")) != ""
				return true
	return false


## The payload's block_id for a candidate: a top-level "block_id"
## when present, else the block object's block_id for block mods.
## "" for script mods (their id lives in script source) and when
## the payload is not block JSON.
func _block_id_of_candidate(candidate: Dictionary) -> String:
	var direct := str(candidate.get("block_id", ""))
	if not direct.is_empty():
		return direct
	if str(candidate.get("kind", "")) != "block":
		return ""
	var parsed: Variant = JSON.parse_string(str(candidate.get("payload", "")))
	if parsed is Dictionary:
		var block: Variant = (parsed as Dictionary).get("block", null)
		if block is Dictionary:
			return str((block as Dictionary).get("block_id", ""))
	return ""


## Installs through the pipeline's write path when it exposes one.
## Returns {handled: bool, error: String}. "handled" is false only
## when no pipeline install function exists (the caller falls back
## to the ModCreator paths); a handled failure carries the error.
func _install_via_pipeline() -> Dictionary:
	var target: Variant = _share_target()
	if target == null:
		return {"handled": false, "error": ""}
	var resolution := "fresh"
	if _ie_import_conflict:
		if _ie_import_resolution == "replace":
			resolution = "replace"
		elif _ie_import_resolution == "keepboth":
			resolution = "keep_both"
		else:
			return {"handled": false, "error": ""}
	if target.has_method("install_import_result"):
		# Annotate a COPY with the menu-resolved conflict context:
		# the pipeline may have missed this conflict (the loader
		# backstop found it), in which case the raw result carries
		# no existing info and the pipeline could not know WHICH
		# installed mod Replace targets. The menu's existing_id
		# (pipeline-provided, or the backstop's find_mod hit) is
		# the authority here; the stored raw result is untouched.
		var raw_for_pipeline := _ie_import_raw.duplicate(true)
		raw_for_pipeline["existing_id"] = _ie_import_existing_id
		if not _ie_import_existing.is_empty():
			raw_for_pipeline["existing"] = _ie_import_existing
		var res: Variant = target.call("install_import_result", raw_for_pipeline, resolution)
		return _norm_pipeline_install_result(res)
	if target.has_method("install_imported"):
		var cand: Dictionary = _ie_import_candidate
		if resolution == "keep_both" and not _ie_import_keepboth_candidate.is_empty():
			cand = _ie_import_keepboth_candidate
		var res2: Variant = target.call("install_imported", cand, resolution, _ie_import_existing_id)
		return _norm_pipeline_install_result(res2)
	return {"handled": false, "error": ""}


func _norm_pipeline_install_result(res: Variant) -> Dictionary:
	if res is Dictionary:
		var d := res as Dictionary
		if bool(d.get("ok", false)):
			return {"handled": true, "error": ""}
		return {"handled": true, "error": str(d.get("error", d.get("reason", "pipeline install failed")))}
	if res is String:
		# "" = success, else the error message.
		return {"handled": true, "error": str(res)}
	if res is bool:
		return {"handled": true, "error": "" if bool(res) else "pipeline install failed"}
	return {"handled": true, "error": "pipeline install returned an unexpected result"}


func _refresh_export_picker() -> void:
	if _ie_export_picker == null:
		return
	_ie_export_picker.clear()
	_ie_export_ids.clear()
	var mods := ModLoader.get_mods()
	for m in mods:
		if not (m is Dictionary):
			continue
		var mod := m as Dictionary
		if str(mod.get("id", "")) == "assets":
			continue
		var label := "%s (%s) — v%s" % [
			str(mod.get("name", mod.get("id", ""))),
			str(mod.get("id", "")), str(mod.get("version", ""))]
		if str(mod.get("error", "")) != "":
			label += " (broken)"
		_ie_export_picker.add_item(label)
		_ie_export_ids.append(str(mod.get("id", "")))
	var empty := _ie_export_ids.is_empty()
	if empty:
		_ie_export_picker.add_item("No mods installed")
	_ie_export_picker.disabled = empty
	if _ie_export_button != null:
		_ie_export_button.disabled = empty
	if not empty:
		_ie_export_picker.select(0)


## EXPORT: picker mod -> block_id -> pipeline export_mod -> code in
## the copyable field. The picker lists MOD ids; the pipeline takes a
## BLOCK id, so resolve via the loader record (block_id == mod id for
## JSON mods; script mods may differ). The lookup is a lookup only —
## no encoding happens here.
func _on_export_pressed() -> void:
	if _ie_export_picker == null or _ie_export_ids.is_empty():
		_ie_export_status.text = "No mods installed — create one on the CREATE tab first."
		return
	var idx := _ie_export_picker.get_selected()
	if idx < 0 or idx >= _ie_export_ids.size():
		_ie_export_status.text = "Pick a mod to export."
		return
	var mod_id: String = _ie_export_ids[idx]
	var block_id := mod_id
	var rec := ModLoader.find_mod(mod_id, false)
	if not rec.is_empty():
		var info: Dictionary = rec.get("block_info", {})
		var bid := str(info.get("block_id", ""))
		if not bid.is_empty():
			block_id = bid
	var result: Variant = _share_call_aliases(_SHARE_EXPORT_NAMES, [block_id])
	if result == null:
		_ie_export_status.text = "Mod sharing is not available in this build — the share pipeline did not load."
		return
	var code := ""
	if result is String:
		# Bare-String export: the string IS the code.
		code = str(result)
	elif result is Dictionary:
		var res := result as Dictionary
		if res.has("ok") and not bool(res.get("ok", false)):
			var err := str(res.get("error", res.get("reason", "")))
			_ie_export_status.text = "Export failed: " + (err if not err.is_empty() else "unknown error")
			return
		code = str(res.get("code", res.get("share_code", res.get("data", ""))))
	else:
		_ie_export_status.text = "Export failed: the share pipeline returned an unexpected result."
		return
	if code.strip_edges().is_empty():
		_ie_export_status.text = "Export failed: the share pipeline returned an empty code."
		return
	_ie_export_code.text = code
	_ie_export_code.scroll_vertical = 0
	_ie_export_code.scroll_horizontal = 0
	_ie_export_status.text = "Code ready — tap COPY, then paste it to a friend."


func _on_copy_pressed() -> void:
	var code := _ie_export_code.text.strip_edges() if _ie_export_code != null else ""
	if code.is_empty():
		_ie_export_status.text = "Nothing to copy — export a mod first."
		return
	DisplayServer.clipboard_set(code)
	_ie_export_status.text = "Code copied — paste it to a friend"


func _on_import_paste_pressed() -> void:
	var clip := DisplayServer.clipboard_get().strip_edges()
	if clip.is_empty():
		_ie_import_status.text = "Clipboard is empty — copy a share code first."
		return
	_ie_import_input.text = clip
	_ie_import_status.text = "Pasted from clipboard — tap IMPORT to review it."


## IMPORT: paste -> strip ALL whitespace (chat apps wrap long codes
## across lines; base64url has no significant whitespace) -> pipeline
## import_code -> approval panel. Invalid/tampered codes surface the
## pipeline's rejection reason; nothing installs here.
func _on_import_pressed() -> void:
	var raw := _ie_import_input.text if _ie_import_input != null else ""
	var code := ""
	for i in range(raw.length()):
		var ch := raw[i]
		if ch != " " and ch != "\t" and ch != "\n" and ch != "\r":
			code += ch
	if code.is_empty():
		_ie_import_status.text = "Paste a share code first."
		return
	var result: Variant = _share_call_aliases(_SHARE_IMPORT_NAMES, [code])
	if result == null:
		_ie_import_status.text = "Mod sharing is not available in this build — the share pipeline did not load."
		return
	if not (result is Dictionary):
		_ie_import_status.text = "Import failed: the share pipeline returned an unexpected result."
		return
	var res := result as Dictionary
	# Kind-aware: the pipeline shape carries kind ("candidate" /
	# "conflict" / "error") and may carry NO "ok" key at all, so a
	# missing "ok" must not reject a kind="candidate"/"conflict"
	# result. The legacy shape carries "ok" (and no kind).
	var kind := str(res.get("kind", ""))
	var err_text := str(res.get("error", res.get("reason", "")))
	if kind == "error":
		_ie_import_status.text = "Import rejected: " + (err_text if not err_text.is_empty() else "invalid code")
		return
	if res.has("ok") and not bool(res.get("ok", false)):
		_ie_import_status.text = "Import rejected: " + (err_text if not err_text.is_empty() else "invalid code")
		return
	if kind != "" and kind != "candidate" and kind != "conflict" and not res.has("candidate") and not res.has("mod_id"):
		_ie_import_status.text = "Import rejected: " + (err_text if not err_text.is_empty() else "unrecognized import result")
		return
	var candidate: Dictionary = {}
	var cand_raw: Variant = res.get("candidate", null)
	if cand_raw is Dictionary:
		candidate = cand_raw as Dictionary
	elif res.has("mod_id") and res.has("payload"):
		# Tolerant shape: the candidate IS the result.
		candidate = res
	if candidate.is_empty():
		_ie_import_status.text = "Import rejected: the share pipeline returned no mod."
		return
	var cand_err := str(candidate.get("error", ""))
	if not cand_err.is_empty():
		_ie_import_status.text = "Import rejected: " + cand_err
		return
	# Conflict: the pipeline flags it via kind == "conflict", a
	# conflict flag, a non-empty "existing" record, or a non-empty
	# "resolutions" list — a folder-collision with a DIFFERENT
	# block_id still carries existing/resolutions, so it is never
	# missed. The UI ALSO checks the loader, so a pipeline that
	# misses one can never turn into a silent rename (creator.
	# install() auto-renames on collision — that must never happen
	# for an import without the player choosing KEEP BOTH).
	var existing: Dictionary = {}
	var existing_raw: Variant = res.get("existing", null)
	if existing_raw is Dictionary:
		existing = existing_raw as Dictionary
	var resolutions: Array = []
	var res_raw: Variant = res.get("resolutions", null)
	if res_raw is Array:
		resolutions = res_raw as Array
	var keepboth_cand: Dictionary = {}
	var kb_raw: Variant = res.get("candidate_keep_both", null)
	if kb_raw is Dictionary:
		keepboth_cand = kb_raw as Dictionary
	var conflict := kind == "conflict" or bool(res.get("conflict", false)) or str(res.get("status", "")) == "conflict" or not existing.is_empty() or not resolutions.is_empty()
	var existing_id := str(res.get("existing_id", res.get("existing_mod_id", "")))
	if existing_id.is_empty() and not existing.is_empty():
		existing_id = str(existing.get("mod_id", ""))
	if existing_id.is_empty() and conflict:
		existing_id = str(candidate.get("mod_id", ""))
	if not conflict:
		# Loader backstop: the candidate's mod id, OR its payload
		# block_id colliding with a DIFFERENT installed folder
		# (find_mod matches by mod id OR block_id).
		var hit: Dictionary = {}
		var cand_id := str(candidate.get("mod_id", ""))
		if not cand_id.is_empty():
			hit = ModLoader.find_mod(cand_id, false)
		if hit.is_empty():
			var bid := _block_id_of_candidate(candidate)
			if not bid.is_empty() and bid != cand_id:
				hit = ModLoader.find_mod(bid, false)
		if not hit.is_empty():
			conflict = true
			existing_id = str(hit.get("id", existing_id))
	if conflict and existing.is_empty() and not existing_id.is_empty():
		var loaded := ModCreator.load_installed(existing_id)
		if str(loaded.get("error", "")) == "":
			existing = loaded
	_ie_import_raw = res
	_ie_import_candidate = candidate
	_ie_import_keepboth_candidate = keepboth_cand
	_ie_import_resolutions = resolutions
	_ie_import_conflict = conflict
	_ie_import_existing_id = existing_id
	_ie_import_existing = existing
	_show_import_approval(candidate, conflict, existing)
	_ie_import_status.text = "Code accepted — review it below. Nothing is installed until you tap Install."


## Import approval — same CONTENT as the CREATE approval (summary +
## full payload + invented hooks + hook script source), plus the
## conflict diff when one exists. Mirrors _show_approval's display
## rules; it does not share that panel (see the member-var note).
func _show_import_approval(candidate: Dictionary, conflict: bool, existing: Dictionary) -> void:
	var lines: Array[String] = []
	lines.append("Shared mod — imported from a share code.")
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
	var school := SpellSchools.normalize(str(candidate.get("spell_school", "")))
	if school.is_empty():
		school = SpellSchools.parse_from_payload(str(candidate.get("payload", "")))
	var school_line := SpellSchools.approval_line(school)
	if not school_line.is_empty():
		lines.append(school_line)
	var summary := str(candidate.get("summary", ""))
	if not summary.is_empty():
		lines.append("")
		lines.append(summary)
	_ie_import_summary.text = "\n".join(lines)
	var hooks := ModHook.preview_hooks_for_candidate(candidate)
	var hook_lines := ModHook.summarize_hooks(hooks)
	if hook_lines.is_empty():
		hook_lines = ["No new hooks — this mod uses existing blocks only."]
	_ie_import_hooks.text = "\n".join(hook_lines)
	_ie_import_payload.text = str(candidate.get("payload", ""))
	_ie_import_payload.scroll_vertical = 0
	_ie_import_payload.scroll_horizontal = 0
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
	_ie_import_script_label.visible = has_script
	_ie_import_script_toggle.visible = has_script
	_ie_import_script_collapsed = false
	_ie_import_script_toggle.text = "HIDE HOOK SCRIPT"
	if has_script:
		_ie_import_script.text = "\n\n".join(script_parts)
		_ie_import_script.scroll_vertical = 0
		_ie_import_script.scroll_horizontal = 0
	_ie_import_script.visible = has_script
	# Conflict: show what REPLACE would change vs the installed
	# version (the EDIT diff), and require an explicit choice.
	# Availability comes from the pipeline's resolutions when it
	# offers them (a keep_both resolution with an EMPTY mod_id
	# means the pipeline cannot offer one) — plus one menu-side
	# rule: a SCRIPT mod's Keep Both needs a pipeline install
	# function (only the pipeline can rewrite the block_id literal
	# in script source); without one, KEEP BOTH is disabled with
	# the reason, and REPLACE / DISCARD stay available.
	if conflict:
		_ie_import_replace_available = _resolution_available(_ie_import_resolutions, "replace")
		_ie_import_keepboth_available = _resolution_available(_ie_import_resolutions, "keep_both")
		if _ie_import_keepboth_available and str(candidate.get("kind", "")) == "script" and not _share_has_install():
			_ie_import_keepboth_available = false
		var loaded := existing
		if loaded.is_empty() or str(loaded.get("payload", "")).is_empty():
			var reloaded := ModCreator.load_installed(_ie_import_existing_id)
			if str(reloaded.get("error", "")) == "":
				loaded = reloaded
		var diff_lines := ModCreator.diff_candidate_vs_installed(candidate, loaded)
		var diff_text := "CONFLICT — '%s' (v%s) is already installed. REPLACE updates it (old version gone, version bumped). KEEP BOTH installs it as a separate copy. Choose below — nothing is overwritten without your choice.\nWhat changes vs the installed version:\n%s" % [
			str(loaded.get("name", _ie_import_existing_id)),
			str(loaded.get("version", "")),
			"\n".join(diff_lines)]
		if not _ie_import_replace_available:
			diff_text += "\nREPLACE is unavailable for this import."
		if not _ie_import_keepboth_available:
			diff_text += "\nKEEP BOTH is unavailable for this import — a script mod's block_id lives in its script source, and only the pipeline's rewritten copy can rename it. Use REPLACE or DISCARD."
		_ie_import_diff.text = diff_text
		_ie_import_diff.visible = true
		_ie_conflict_row.visible = true
		_ie_replace_toggle.button_pressed = false
		_ie_keepboth_toggle.button_pressed = false
		_ie_replace_toggle.disabled = not _ie_import_replace_available
		_ie_keepboth_toggle.disabled = not _ie_import_keepboth_available
		_ie_import_resolution = ""
		_ie_import_install_button.disabled = true
	else:
		_ie_import_diff.visible = false
		_ie_conflict_row.visible = false
		_ie_import_resolution = "fresh"
		_ie_import_install_button.disabled = false
	_ie_import_approval_status.text = ""
	_ie_import_approval.visible = true


func _on_import_script_toggle_pressed() -> void:
	_ie_import_script_collapsed = not _ie_import_script_collapsed
	_ie_import_script.visible = not _ie_import_script_collapsed
	_ie_import_script_toggle.text = "SHOW HOOK SCRIPT" if _ie_import_script_collapsed else "HIDE HOOK SCRIPT"


## Conflict resolution toggle: tapping the selected choice again
## clears it (Install goes dead) — the player must hold a choice.
func _on_import_resolution_toggled(pressed: bool, mode: String) -> void:
	if pressed:
		_ie_import_resolution = mode
		_ie_import_install_button.disabled = false
		_ie_import_approval_status.text = "Install will REPLACE the installed mod (version bumped)." if mode == "replace" else "Install will keep both — the import installs as a separate copy."
	else:
		if _ie_import_resolution == mode:
			_ie_import_resolution = ""
		_ie_import_install_button.disabled = true
		_ie_import_approval_status.text = "Choose REPLACE or KEEP BOTH to enable Install."


## INSTALL for an import — the ONLY write path. Pipeline install
## (install_import_result / install_imported) first when the
## pipeline exposes it; otherwise ModCreator: Fresh = install as a
## new mod. Replace = install_update (same id, version bumped, old
## version gone, rollback on failure). Keep Both = rename the
## candidate to a collision-free "<id>_copy" (+ " (copy)" on the
## display name, kept in sync with the manifest so validation's
## name-match holds) and install it. Script-mod Keep Both never
## reaches the rename path (the toggle is disabled without a
## pipeline install function — only the pipeline can rewrite a
## script's block_id literal). Failures leave the panel up with the
## reason — never a dead end, never a partial install.
func _on_import_install_pressed() -> void:
	if _ie_import_candidate.is_empty():
		return
	if _ie_import_conflict and _ie_import_resolution not in ["replace", "keepboth"]:
		_ie_import_approval_status.text = "Choose REPLACE or KEEP BOTH first."
		return
	var creator := _creator_instance()
	var err := ""
	var done_msg := ""
	# Pipeline install first when the pipeline exposes it
	# (install_import_result / install_imported are its write
	# path — they own the pre-rewritten script Keep Both
	# candidate). Otherwise the ModCreator paths below.
	var via_pipeline := _install_via_pipeline()
	if bool(via_pipeline.get("handled", false)):
		err = str(via_pipeline.get("error", ""))
		if _ie_import_resolution == "replace":
			var pv := ModCreator.bump_version(str(_ie_import_existing.get("version", "1.0")))
			done_msg = "Replaced '%s' — now v%s." % [
				str(_ie_import_existing.get("name", _ie_import_existing_id)), pv]
		elif _ie_import_resolution == "keepboth":
			done_msg = "Installed as a separate copy."
		else:
			done_msg = "Installed."
	elif not _ie_import_conflict or _ie_import_resolution == "fresh":
		err = creator.install(_ie_import_candidate)
		done_msg = "Installed."
	elif _ie_import_resolution == "replace":
		err = creator.install_update(_ie_import_candidate, _ie_import_existing_id)
		var new_version := ModCreator.bump_version(str(_ie_import_existing.get("version", "1.0")))
		done_msg = "Replaced '%s' — now v%s." % [
			str(_ie_import_existing.get("name", _ie_import_existing_id)), new_version]
	else:  # keepboth
		var renamed := _ie_import_candidate.duplicate(true)
		renamed["mod_id"] = _unique_copy_id(str(_ie_import_candidate.get("mod_id", "mod")))
		var nm := str(renamed.get("name", ""))
		if not nm.ends_with(" (copy)"):
			nm += " (copy)"
			renamed["name"] = nm
			var m: Dictionary = (renamed.get("manifest", {}) as Dictionary).duplicate(true)
			m["name"] = nm
			renamed["manifest"] = m
		err = creator.install(renamed)
		done_msg = "Installed as a separate copy ('%s')." % str(renamed.get("mod_id", ""))
	if err.is_empty():
		_clear_import_state()
		_ie_import_approval.visible = false
		_ie_import_status.text = done_msg
		_refresh_mods()
		_refresh_export_picker()
	else:
		_ie_import_approval_status.text = "Install failed: " + err


func _on_import_discard_pressed() -> void:
	_clear_import_state()
	_ie_import_approval.visible = false
	_ie_import_status.text = "Discarded — nothing installed."


func _clear_import_state() -> void:
	_ie_import_raw = {}
	_ie_import_candidate = {}
	_ie_import_keepboth_candidate = {}
	_ie_import_resolutions = []
	_ie_import_conflict = false
	_ie_import_existing_id = ""
	_ie_import_existing = {}
	_ie_import_resolution = ""
	_ie_import_replace_available = true
	_ie_import_keepboth_available = true
	_ie_replace_toggle.button_pressed = false
	_ie_keepboth_toggle.button_pressed = false
	_ie_replace_toggle.disabled = false
	_ie_keepboth_toggle.disabled = false


## Collision-free copy id: "<base>_copy", then "<base>_copy_2", ...
## find_mod also matches block_ids, so a copy can never shadow an
## existing mod OR block id.
func _unique_copy_id(base: String) -> String:
	var first := base + "_copy"
	if ModLoader.find_mod(first, false).is_empty():
		return first
	for n in range(2, 100):
		var cand := "%s_copy_%d" % [base, n]
		if ModLoader.find_mod(cand, false).is_empty():
			return cand
	return first


func _workshop_panel_style() -> StyleBoxFlat:
	var style := StencilStyle.panel(Color.TRANSPARENT, Color.TRANSPARENT, 0)
	style.content_margin_left = 48
	style.content_margin_right = maxf(48, size.x * 0.38) if size.x >= 1000 else 32
	style.content_margin_top = 32
	style.content_margin_bottom = 32
	return style
