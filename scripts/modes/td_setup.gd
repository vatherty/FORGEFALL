# FORGEFALL — Tower Defense pre-run setup (Gameplay Rework, TD worker).
#
# TD-side UI + wiring for Colin's traversal choice (GAMEPLAY_REWORK.md,
# "Traversal tools"): in Tower Defense the pre-run setup includes a
# choice of EXACTLY ONE traversal tool — Grapple Hook, Jetpack, or
# Portal Gun. Only the chosen tool is active in the run.
#
# Ownership split (do not blur it):
#   - THIS file (TD worker): the choice UI, the stored selection, and
#     the TD-side wiring that hands the choice to the player.
#   - Movement worker: the tool IMPLEMENTATIONS + the selection API.
#     Jetpack is new (fuel-based thrust, tunable); Grapple Hook and
#     Portal Gun already exist as player children but are currently
#     always-on — the movement worker gates them behind the selection.
#
# SELECTION API CONTRACT (movement worker implements on the player —
# ALREADY LANDED in player.gd):
#   set_traversal_tool(tool: String) -> bool — activates exactly that
#   tool and deactivates the others. Valid ids: "grapple" | "jetpack" |
#   "portal" | "none". Unknown ids return false (selection unchanged).
#   NOTE the id: the enforcement side uses "portal", NOT "portal_gun".
#   (loadouts.gd used to say "portal_gun" — the v0.6.0 integration
#   made "portal" canonical everywhere; "portal_gun" survives only
#   as a legacy alias in loadouts sanitize + MP normalize.)
# apply_to_player() calls that API when present (duck-typed, so this
# file never hard-depends on the movement worker's landing order).
# When the API is ABSENT (movement work not landed yet), apply returns
# false and the choice stays stored — the run proceeds with the
# player's current tools and the choice applies as soon as the API
# lands. (As of this writing the API HAS landed in player.gd, so the
# fallback is belt-and-braces only.)
#
# Exactly-one enforcement: the selection is a single String
# (selected_tool); set_tool() validates against TOOLS and rejects
# anything else; the UI is radio behaviour (picking one deselects the
# others). There is no code path that yields zero or two active tools
# from this file — the stored choice is always exactly one id.
#
# Persistence: user://td_setup.json {"traversal_tool": "<id>"}.
# Default: "grapple" (matches today's always-on behaviour).
#
# Flow: main menu DEPLOY with mode == tower_defense opens this overlay
# (TowerDefenseSetup.new() + open()); CONFIRM saves + emits
# setup_confirmed(tool) and the menu starts the run. TowerDefenseMode
# also applies the stored choice at run start (covers retries and any
# entry path that bypasses the menu).
class_name TowerDefenseSetup
extends Control

signal setup_confirmed(tool: String)
signal tool_selected(tool: String)

## The full tool set — exactly these three, no more, no less. Ids match
## the movement worker's enforcement-side contract in player.gd
## (set_traversal_tool): "portal", NOT "portal_gun" — see the header.
const TOOLS := ["grapple", "jetpack", "portal"]
const TOOL_NAMES := {
	"grapple": "GRAPPLE HOOK",
	"jetpack": "JETPACK",
	"portal": "PORTAL GUN",
}
const TOOL_DESCS := {
	"grapple": "Swing from anything. Momentum is your weapon.",
	"jetpack": "Fuel-based thrust. Fly the lanes — watch the tank.",
	"portal": "Two linked portals. Teleport across the map.",
}
const SAVE_PATH := "user://td_setup.json"
const DEFAULT_TOOL := "grapple"

## The stored choice — always exactly one of TOOLS.
static var selected_tool: String = DEFAULT_TOOL

var _buttons := {}
var _desc_label: Label = null
var _confirm_button: Button = null
var _status_label: Label = null


func _ready() -> void:
	StencilStyle.install_menu(self)
	add_to_group("td_setup")
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	load_selection()
	_build()


# --- Selection API (static — usable without the UI) ---------------------------

static func is_valid_tool(tool: String) -> bool:
	return tool in TOOLS


## Set the choice. Returns false + leaves the selection unchanged for
## anything outside TOOLS. Exactly-one holds by construction: one
## String, one valid id.
static func set_tool(tool: String) -> bool:
	if not is_valid_tool(tool):
		return false
	selected_tool = tool
	return true


static func get_tool() -> String:
	return selected_tool


## Persist the choice. Returns false only when the file cannot be written.
static func save_selection(path: String = SAVE_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"traversal_tool": selected_tool}))
	return true


## Load the persisted choice (missing / corrupt / unknown id -> default).
## Returns the resulting selection.
static func load_selection(path: String = SAVE_PATH) -> String:
	if not FileAccess.file_exists(path):
		selected_tool = DEFAULT_TOOL
		return selected_tool
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		selected_tool = DEFAULT_TOOL
		return selected_tool
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary and is_valid_tool(str(data.get("traversal_tool", ""))):
		selected_tool = str(data.get("traversal_tool"))
	else:
		selected_tool = DEFAULT_TOOL
	return selected_tool


## Hand the stored choice to the player through the movement worker's
## selection API. True = the player accepted the choice; false = the
## API is not present yet (choice stays stored, run proceeds).
static func apply_to_player(player: Node) -> bool:
	if player == null or not is_instance_valid(player):
		return false
	if player.has_method("set_traversal_tool"):
		player.call("set_traversal_tool", selected_tool)
		return true
	return false


# --- UI ----------------------------------------------------------------------

func _build() -> void:
	StencilStyle.cinematic_background(self, "industrial")

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 24
	panel.offset_right = -24
	panel.offset_top = 24
	panel.offset_bottom = -24
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	add_child(panel)

	var root := VBoxContainer.new()
	root.name = "Root"
	root.add_theme_constant_override("separation", 12)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(root)
	StencilStyle.eyebrow(root, "TOWER DEFENSE DEPLOYMENT")

	var title := Label.new()
	title.name = "Title"
	StencilStyle.apply_title(title, 30, StencilStyle.ORANGE, 3)
	title.text = "TOWER DEFENSE SETUP"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	var sub := Label.new()
	sub.name = "Subtitle"
	StencilStyle.apply_body(sub, 20, StencilStyle.TEXT, 2)
	sub.text = "CHOOSE ONE TRAVERSAL TOOL — ONLY THE CHOSEN TOOL IS ACTIVE"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(sub)

	for tool in TOOLS:
		var b := Button.new()
		b.name = "Tool_" + tool
		b.text = str(TOOL_NAMES[tool])
		b.custom_minimum_size = Vector2(0, 56)
		StencilStyle.style_button(b)
		b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(_on_tool_pressed.bind(tool))
		root.add_child(b)
		_buttons[tool] = b

	_desc_label = Label.new()
	_desc_label.name = "DescLabel"
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_desc_label)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_status_label)

	_confirm_button = Button.new()
	_confirm_button.name = "ConfirmButton"
	_confirm_button.text = "CONFIRM & DEPLOY"
	_confirm_button.custom_minimum_size = Vector2(0, 60)
	StencilStyle.primary_button(_confirm_button)
	_confirm_button.add_theme_font_size_override("font_size", 24)
	_confirm_button.pressed.connect(_on_confirm_pressed)
	root.add_child(_confirm_button)

	_refresh()


## Radio refresh: the selected tool reads as chosen, the others as not.
func _refresh() -> void:
	for tool in TOOLS:
		var b: Button = _buttons.get(tool)
		if b == null:
			continue
		# Selected button gets the orange title treatment via modulate
		# (StencilStyle buttons share one stylebox; modulate is the
		# per-button channel). Unselected buttons stay neutral.
		b.modulate = Color(1.35, 1.15, 0.9) if tool == selected_tool else Color.WHITE
		b.text = str(TOOL_NAMES[tool]) + ("  ✓" if tool == selected_tool else "")
	if _desc_label != null:
		StencilStyle.apply_body(_desc_label, 19, StencilStyle.TEXT_DIM, 2)
		_desc_label.text = str(TOOL_DESCS.get(selected_tool, ""))
	if _status_label != null:
		StencilStyle.apply_body(_status_label, 18, StencilStyle.ORANGE, 2)
		_status_label.text = "SELECTED: %s" % str(TOOL_NAMES.get(selected_tool, selected_tool))


func open() -> void:
	load_selection()
	visible = true
	_refresh()


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


func _on_tool_pressed(tool: String) -> void:
	if set_tool(tool):
		_refresh()
		tool_selected.emit(tool)


func _on_confirm_pressed() -> void:
	save_selection()
	close()
	setup_confirmed.emit(selected_tool)
