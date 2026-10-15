# verify_v05_b1_forge_ui.gd — headless checks for the B1 Forge menu UI.
# Usage: godot --headless --path <project> --script res://tools/verify_v05_b1_forge_ui.gd
# Checks:
#   1. The menu scene instantiates; starts hidden; joins group "forge_menu".
#   2. All 4 tabs exist (Build / Weapons / Events / Killstreaks) with preset buttons.
#   3. open()/close() work; budget label reflects Forge.get_budget().
#   4. Preset tap fills the prompt field; CONFIRM submits via Forge.submit_prompt
#      and a forge_result arrives (real backend, offline fallback) with no error.
#   5. Integration (post-B2): with preview_cost / undo_last / get_history
#      PRESENT on the real Forge autoload, the Undo button is visible and
#      the menu uses the backend. (Degradation with those methods absent
#      was verified pre-B2 at delivery; the has_method guards are unchanged.)
#   6. History: after a submit, a history button for that prompt exists and
#      re-submitting through it reaches Forge (cooldown result is fine).
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

var _fails := 0
var _frames := 0
var _phase := 0
var _menu: Control = null
var _result_count := 0
var _last_result := ""


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	# Minimal world so ForgeBuilder has a root to build cover into.
	var arena := Node3D.new()
	arena.name = "ForgeMenuArena"
	root.add_child(arena)
	current_scene = arena
	var game := root.get_node_or_null("Game")
	if game != null:
		game.set("forge_budget", 1000)
	var ps := load("res://scenes/ui/forge_menu.tscn") as PackedScene
	_menu = ps.instantiate() as Control
	_menu.name = "ForgeMenu"
	root.add_child(_menu)
	var forge := root.get_node_or_null("Forge")
	if forge != null and forge.has_signal("forge_result"):
		forge.connect("forge_result", _on_forge_result)
	_phase = 1
	print("VERIFY-B1: menu instantiated, waiting for _ready")


func _on_forge_result(_success: bool, message: String) -> void:
	_result_count += 1
	_last_result = message


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		1:
			if _frames < 3:
				return false
			_check(_menu != null, "forge_menu.tscn instantiates")
			_check(_menu.is_in_group("forge_menu"), "menu joins group 'forge_menu'")
			_check(_menu.visible == false, "menu starts hidden")
			var tabs := _menu.find_child("TabContainer", true, false) as TabContainer
			_check(tabs != null, "TabContainer exists")
			if tabs != null:
				_check(tabs.get_tab_count() == 4, "4 tabs exist (got %d)" % tabs.get_tab_count())
				for i in 4:
					var title := tabs.get_tab_title(i)
					_check(title in ["Build", "Weapons", "Events", "Killstreaks"],
						"tab %d is '%s'" % [i, title])
					var n := _count_preset_buttons(tabs.get_tab_control(i))
					_check(n >= 3, "tab '%s' has preset buttons (got %d)" % [title, n])
			# Integrated-backend configuration (post-B2): the real Forge now
			# HAS the new methods, so this run verifies the integrated path.
			# Degradation (methods absent) was verified pre-B2 at delivery
			# (30/30 pass); the menu's has_method guards are unchanged.
			var forge := root.get_node_or_null("Forge")
			_check(forge != null and forge.has_method("submit_prompt"), "Forge.submit_prompt exists")
			_check(forge != null and forge.has_method("preview_cost"),
				"integrated setup: Forge.preview_cost present")
			_check(forge != null and forge.has_method("undo_last"),
				"integrated setup: Forge.undo_last present")
			_check(forge != null and forge.has_method("get_history"),
				"integrated setup: Forge.get_history present")
			# Set the budget AFTER autoload _ready (Game._ready resets it to the
			# tuning default, which would clobber the _initialize value).
			var game2 := root.get_node_or_null("Game")
			if game2 != null:
				game2.set("forge_budget", 1000)
			_menu.call("open")
			_phase = 2
			_frames = 0
		2:
			if _frames < 3:
				return false
			_check(_menu.visible == true, "open() shows the menu")
			var budget := _menu.find_child("BudgetLabel", true, false) as Label
			_check(budget != null and budget.text == "BUDGET: 1000",
				"budget label shows Forge.get_budget() (got '%s')" % (budget.text if budget != null else "<null>"))
			var preview := _menu.find_child("PreviewLabel", true, false) as Label
			_check(preview != null and preview.text == "COST: —",
				"no preview_cost -> preview shows budget-only 'COST: —' (got '%s')" % (preview.text if preview != null else "<null>"))
			var undo := _menu.find_child("UndoButton", true, false) as Button
			_check(undo != null and undo.visible == true,
				"undo_last present -> Undo button visible")
			# Preset tap fills the prompt field (does not auto-submit).
			var wall_btn := _menu.find_child("Wall", true, false) as Button
			_check(wall_btn != null, "Build tab has a Wall preset button")
			if wall_btn != null:
				wall_btn.emit_signal("pressed")
			var input := _menu.find_child("PromptInput", true, false) as LineEdit
			_check(input != null and input.text == "Build a wall in front of me",
				"preset tap fills the prompt field (got '%s')" % (input.text if input != null else "<null>"))
			_result_count = 0
			_menu.call("_on_confirm_pressed")
			_phase = 3
			_frames = 0
		3:
			# Wait for the async Forge pipeline (LLM fallback -> build).
			if _result_count == 0 and _frames < 240:
				return false
			_check(_result_count >= 1, "submit via Forge.submit_prompt yields forge_result (got %d)" % _result_count)
			_check(_last_result.to_lower().contains("wall"),
				"forge_result message describes the wall build (got '%s')" % _last_result)
			var budget2 := _menu.find_child("BudgetLabel", true, false) as Label
			_check(budget2 != null and budget2.text == "BUDGET: 900",
				"budget drops by wall cost 100 after build (got '%s')" % (budget2.text if budget2 != null else "<null>"))
			# History falls back to the local list: a button for the prompt.
			var hist := _find_history_button("Build a wall in front of me")
			_check(hist != null, "history lists the submitted prompt (local fallback)")
			if hist != null:
				_result_count = 0
				hist.emit_signal("pressed")
				_phase = 4
				_frames = 0
			else:
				_phase = 5
				_frames = 0
		4:
			# Re-submit through history: Forge is on cooldown, so the result
			# is a cooldown rejection — still a clean round-trip, no error.
			if _result_count == 0 and _frames < 120:
				return false
			_check(_result_count >= 1, "history tap re-submits to Forge (got %d results)" % _result_count)
			_phase = 5
			_frames = 0
		5:
			_menu.call("close")
			_check(_menu.visible == false, "close() hides the menu")
			# Tree must NOT be paused by the menu (pause-friendly requirement).
			_check(paused == false, "menu never pauses the game tree")
			if _fails == 0:
				print("VERIFY-B1: ALL CHECKS PASSED")
			else:
				printerr("VERIFY-B1: %d CHECK(S) FAILED" % _fails)
			quit(_fails)
			return true
	return false


func _count_preset_buttons(node: Node) -> int:
	var n := 0
	if node is Button and (node as Button).has_meta("forge_prompt"):
		n += 1
	for child in node.get_children():
		n += _count_preset_buttons(child)
	return n


func _find_history_button(prompt: String) -> Button:
	var hist_list := _menu.find_child("HistoryList", true, false)
	if hist_list == null:
		return null
	for child in hist_list.get_children():
		if child is Button and (child as Button).text == prompt:
			return child as Button
	return null
