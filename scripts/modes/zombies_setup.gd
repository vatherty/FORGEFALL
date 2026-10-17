# FORGEFALL — Zombies pre-run setup (Gameplay Rework, Zombies worker).
#
# The Zombies traversal toggle (Colin 20:05): ONE toggle covers ALL
# THREE traversal tools — grapple hook, portal gun, AND jetpack.
# Default OFF: no traversal tools in Zombies. Toggle ON: all three
# allowed in Zombies. The toggle state itself lives in ZombiesMode
# (persisted to user://zombies_settings.json); this file is the menu
# UI + the thin wiring that hands the choice to the run.
#
# Ownership split (do not blur it):
#   - ZombiesMode (zombies.gd): the toggle state, persistence, the
#     allowed-set computation, and apply_traversal_to_player().
#   - THIS file: the pre-run overlay UI (a CheckButton + note) and
#     the menu plug-in point. It never computes the allowed set.
#   - Movement worker: the tool IMPLEMENTATIONS + the player
#     selection API (set_allowed_traversal_tools / set_traversal_tool).
#
# Flow: main menu DEPLOY with mode == "zombies" opens this overlay
# (ZombiesSetup.new() + open()); CONFIRM saves + emits setup_confirmed
# and the menu starts the run. ZombiesMode also applies the stored
# toggle at run start (covers retries and any entry path that
# bypasses the menu). If the menu worker never opens this overlay,
# the run still respects the last-saved toggle (default OFF).
class_name ZombiesSetup
extends Control

signal setup_confirmed(traversal_enabled: bool)

var _toggle: CheckButton = null
var _confirm_button: Button = null


func _ready() -> void:
	StencilStyle.install_menu(self)
	add_to_group("zombies_setup")
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()


func open() -> void:
	visible = true
	if _toggle != null:
		_toggle.button_pressed = ZombiesMode.is_traversal_enabled()


func close() -> void:
	visible = false


## Hand the stored toggle to the player through ZombiesMode.
## False = no player yet (the mode applies it at run start).
static func apply_to_player(player: Node) -> bool:
	if player == null or not is_instance_valid(player):
		return false
	return ZombiesMode.apply_traversal_to_player(player)


func _build() -> void:
	StencilStyle.cinematic_background(self, "industrial")

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 24
	panel.offset_right = -24
	panel.offset_top = 24
	panel.offset_bottom = -24
	add_child(panel)

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)
	vb.add_theme_constant_override("separation", 16)
	StencilStyle.eyebrow(vb, "ZOMBIES DEPLOYMENT")

	var title := Label.new()
	title.name = "Title"
	title.text = "ZOMBIES SETUP"
	StencilStyle.apply_title(title, 36, StencilStyle.TEXT, 0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var desc := Label.new()
	desc.name = "Desc"
	desc.text = "Traversal tools are OFF by default in Zombies.\nTurn the toggle on to allow all three."
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(desc)

	_toggle = CheckButton.new()
	_toggle.name = "TraversalToggle"
	_toggle.text = "TRAVERSAL TOOLS: grapple + jetpack + portal gun"
	_toggle.button_pressed = ZombiesMode.is_traversal_enabled()
	_toggle.toggled.connect(_on_toggle)
	vb.add_child(_toggle)

	_confirm_button = Button.new()
	_confirm_button.name = "ConfirmButton"
	_confirm_button.text = "CONFIRM — DEPLOY"
	StencilStyle.primary_button(_confirm_button)
	_confirm_button.pressed.connect(_on_confirm)
	vb.add_child(_confirm_button)


func _on_toggle(pressed: bool) -> void:
	ZombiesMode.set_traversal_enabled(pressed)


func _on_confirm() -> void:
	ZombiesMode.set_traversal_enabled(_toggle.button_pressed if _toggle != null else ZombiesMode.is_traversal_enabled())
	setup_confirmed.emit(ZombiesMode.is_traversal_enabled())
	close()
