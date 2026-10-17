# verify_forge_batch.gd — Worker F verification for the FORGEFALL Forge batch.
# Usage: godot --headless --path <project> --script res://tools/verify_forge_batch.gd
# Exit 0 = all checks pass; any FAIL prints and exits 1.
#
# Coverage (REAL handlers/code paths, not mocks):
#   budget-off: builds free (never blocked), no budget UI visible.
#   aliases: "give me a burst rifle" -> Trident, "give me a judge" -> Judge,
#     an installed mod name resolves in the offline parser.
#   ghost-edit: ghost preview with validity tint; move/rotate/delete on a
#     placed structure.
#   destructible: damage -> destroyed at 0 HP; repair restores HP.
#   mp-sync: in-process two-peer sim (the sandbox blocks real UDP
#     loopback): place on peer 1 -> identical on peer 2; destroy on host
#     -> removed on peer 2; late join receives the list.
#   per-weapon-costs: per-weapon costs differ + shown (enforcement off).
#   presets: stairs, ramp, wall, jump pad, cover piece, sniper nest — all
#     place + collide + count toward cap 12.
#   build-codes: build -> code -> identical rebuild; History search filters.
#   creator: main-menu button opens the creator; tabs CREATE / MODS /
#     IMPORT-EXPORT (placeholder, no functionality); old in-Forge create
#     panel gone; form has multi-choice categories + name + visual + logic
#     -> validated mod; voxel asset generated + cached + reused on repeat
#     description; watermelon-LMG example end-to-end (projectile visual +
#     explosion on impact); sandbox test works and does not pollute the
#     real mod list.
#   voice-confirm: recognized text shows in confirm prompt before any Forge
#     action; Confirm/Retry/Cancel behave; no stuck listening state.
#
# API COMPATIBILITY: the workers' exact method names were not frozen when
# this suite was written, so every capability is probed through an ALIAS
# LIST (e.g. show_ghost / spawn_ghost / preview_ghost). A capability with
# no matching API is a FAIL labelled NOT-LANDED, never a silent skip —
# except where noted, a missing feature fails its checks honestly so the
# coordinator can see exactly what has not landed yet. NO network: the
# offline parser / mock paths are used throughout; DeepSeek is never hit.
# NO persistent state is left behind: the temp-mod alias probe removes its
# user://mods folder and rescans; all built nodes are freed.
extends SceneTree

var _passes := 0
var _fails := 0
var _sec_pass: Dictionary = {}
var _sec_fail: Dictionary = {}
var _frames := 0
var _phase := 0
var _vstep := 0
var _vframes := 0
var _timeout := false

var _llm_script: GDScript = null
var _llm: Node = null
var _builder_script: GDScript = null
var _builder: RefCounted = null
var _manager_script: GDScript = null
var _manager: Node = null
var _loader_script: GDScript = null
var _creator_script: GDScript = null
var _arsenal_script: GDScript = null

var _arena: Node3D = null
var _player: Node3D = null
var _wm: Node = null
var _forge_menu: Control = null
var _main_menu: Control = null
var _voice_results := 0
var _voice_struct_before := 0
var _voice_confirm_found := false

var _placement_script: GDScript = null
var _ghost_script: GDScript = null
var _sync_script: GDScript = null
var _voxel_script: GDScript = null
var _creator_menu_script: GDScript = null
var _sandbox_script: GDScript = null
var _structure_script: GDScript = null
var _budget_phase_step := 0
var _budget_code := ""
var _budget_built_before := 0
var _budget_pos := Vector3.ZERO
var _forge_msgs: Array = []

const GHOST_METHODS := ["show_ghost", "spawn_ghost", "preview_ghost", "update_ghost", "set_ghost", "start_ghost_preview"]
const GHOST_VALID_METHODS := ["set_ghost_valid", "set_ghost_validity", "set_ghost_state", "update_ghost_validity"]
const GHOST_END_METHODS := ["confirm_ghost", "cancel_ghost", "hide_ghost", "clear_ghost"]
const EDIT_MOVE_METHODS := ["move_structure", "move_placed", "move_build", "edit_move", "move_forge_structure"]
const EDIT_ROTATE_METHODS := ["rotate_structure", "rotate_placed", "rotate_build", "edit_rotate", "rotate_forge_structure"]
const EDIT_DELETE_METHODS := ["delete_structure", "remove_placed", "delete_placed", "delete_build", "remove_forge_structure", "destroy_structure"]
const CODE_ENCODE_METHODS := ["encode_build", "export_build_code", "build_to_code", "serialize_build", "get_build_code", "export_code", "encode_build_code"]
const CODE_DECODE_METHODS := ["decode_build", "import_build_code", "code_to_build", "deserialize_build", "apply_build_code", "import_code", "decode_build_code"]
const HISTORY_SEARCH_METHODS := ["search_history", "filter_history", "find_in_history", "search", "filter"]
const SYNC_SCRIPT_PATHS := ["res://scripts/net/forge_sync.gd", "res://scripts/forge/forge_sync.gd", "res://scripts/net/forge_net.gd", "res://scripts/forge/forge_multiplayer.gd", "res://scripts/net/forge_multiplayer.gd"]
const SYNC_PLACE_METHODS := ["sync_forge_build", "apply_forge_place", "place_forge_build", "broadcast_forge_place", "apply_remote_build", "receive_forge_build"]
const SYNC_DESTROY_METHODS := ["sync_forge_destroy", "apply_forge_destroy", "broadcast_forge_destroy", "apply_remote_destroy", "receive_forge_destroy"]
const SYNC_STATE_METHODS := ["get_forge_state", "serialize_builds", "get_build_snapshot", "get_forge_builds", "export_forge_state"]
const SYNC_APPLY_STATE_METHODS := ["apply_forge_state", "apply_build_snapshot", "import_forge_state", "sync_forge_state", "apply_snapshot"]
const CREATOR_SCRIPT_PATHS := ["res://scripts/ui/mod_creator_menu.gd", "res://scripts/ui/creator_menu.gd", "res://scripts/ui/creator_form.gd", "res://scripts/mods/mod_creator_ui.gd", "res://scripts/ui/creator.gd", "res://scripts/ui/mod_creator.gd"]
const VOXEL_CACHE_METHODS := ["generate_voxel_asset", "voxel_asset", "get_voxel_asset", "get_cached_asset", "generate_asset", "cached_voxel_asset"]
const SANDBOX_METHODS := ["test_in_sandbox", "sandbox_test", "run_sandbox_test", "run_sandbox", "test_mod_in_sandbox"]


func _check(section: String, cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		_sec_pass[section] = int(_sec_pass.get(section, 0)) + 1
		print("PASS [", section, "]: ", label)
	else:
		_fails += 1
		_sec_fail[section] = int(_sec_fail.get(section, 0)) + 1
		printerr("FAIL [", section, "]: ", label)


func _src(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _has_any(obj: Object, names: Array) -> bool:
	if obj == null:
		return false
	for n in names:
		if obj.has_method(str(n)):
			return true
	return false


func _find_method(obj: Object, names: Array) -> String:
	if obj == null:
		return ""
	for n in names:
		if obj.has_method(str(n)):
			return str(n)
	return ""


func _arg_count(obj: Object, name: String) -> int:
	if obj == null:
		return -1
	var scr: Script = obj.get_script() as Script
	if scr == null:
		return -1
	for m in scr.get_script_method_list():
		if str((m as Dictionary).get("name", "")) == name:
			return ((m as Dictionary).get("args", []) as Array).size()
	return -1


func _collect_texts(node: Node, out: Array) -> void:
	if node is Label:
		out.append((node as Label).text)
	elif node is Button:
		out.append((node as Button).text)
	elif node is LineEdit:
		out.append((node as LineEdit).text)
	elif node is OptionButton:
		var ob := node as OptionButton
		for i in ob.item_count:
			out.append(ob.get_item_text(i))
	for c in node.get_children():
		_collect_texts(c, out)


func _texts_contain(node: Node, substr: String) -> bool:
	var texts: Array = []
	_collect_texts(node, texts)
	var needle := substr.to_lower()
	for t in texts:
		if str(t).to_lower().contains(needle):
			return true
	return false


func _find_button_with(node: Node, substr: String) -> Button:
	if node is Button and (node as Button).text.to_lower().contains(substr.to_lower()):
		return node as Button
	for c in node.get_children():
		var r := _find_button_with(c, substr)
		if r != null:
			return r
	return null


func _find_label_with(node: Node, substr: String) -> Label:
	if node is Label and (node as Label).text.to_lower().contains(substr.to_lower()):
		return node as Label
	for c in node.get_children():
		var r := _find_label_with(c, substr)
		if r != null:
			return r
	return null


func _find_tab_container(node: Node) -> TabContainer:
	if node is TabContainer:
		return node as TabContainer
	for c in node.get_children():
		var r := _find_tab_container(c)
		if r != null:
			return r
	return null


func _count_type(node: Node, cls: GDScript, count: int) -> int:
	if cls != null and is_instance_of(node, cls):
		count += 1
	for c in node.get_children():
		count = _count_type(c, cls, count)
	return count


func _has_collision(node: Node) -> bool:
	if node is CollisionShape3D:
		return (node as CollisionShape3D).shape != null
	if node is CollisionPolygon3D:
		return true
	for c in node.get_children():
		if _has_collision(c):
			return true
	return false


func _group_count(group: String) -> int:
	return get_nodes_in_group(group).size()


func _free_node(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.free()


func _on_voice_forge_result(_success: bool, _message: String) -> void:
	_voice_results += 1


# ------------------------------------------------------------------ static
func _initialize() -> void:
	_llm_script = load("res://scripts/forge/forge_llm.gd") as GDScript
	_builder_script = load("res://scripts/forge/forge_builder.gd") as GDScript
	_manager_script = load("res://scripts/forge/forge_manager.gd") as GDScript
	_loader_script = load("res://scripts/mods/mod_loader.gd") as GDScript
	_creator_script = load("res://scripts/mods/mod_creator.gd") as GDScript
	_arsenal_script = load("res://scripts/weapons/arsenal.gd") as GDScript
	_check("setup", _llm_script != null, "setup: forge_llm.gd loads (no parse errors)")
	_check("setup", _builder_script != null, "setup: forge_builder.gd loads (no parse errors)")
	_check("setup", _manager_script != null, "setup: forge_manager.gd loads (no parse errors)")
	_check("setup", _loader_script != null, "setup: mod_loader.gd loads (no parse errors)")
	if _llm_script != null:
		_llm = _llm_script.new()
	if _builder_script != null:
		_builder = _builder_script.new() as RefCounted
	if _manager_script != null:
		_manager = _manager_script.new() as Node
	_static_aliases()
	_static_per_weapon_costs()
	_static_ghost_edit_presence()
	_static_build_codes_presence()
	_static_mp_sync_presence()
	_static_creator_presence()
	_static_watermelon()
	# Minimal world for the tree phases: arena + player + real WeaponManager.
	_arena = Node3D.new()
	_arena.name = "ForgeBatchArena"
	root.add_child(_arena)
	current_scene = _arena
	_player = Node3D.new()
	_player.name = "ForgeBatchPlayer"
	_player.add_to_group("player")
	_arena.add_child(_player)
	var wm_script: GDScript = load("res://scripts/weapons/weapon_manager.gd") as GDScript
	if wm_script != null:
		_wm = wm_script.new() as Node
		_wm.name = "WeaponManager"
		_player.add_child(_wm)
	_phase = 1
	print("VERIFY_FORGE_BATCH: static checks done, waiting for tree phases")


func _static_aliases() -> void:
	if _llm == null:
		_check("aliases", false, "aliases: no ForgeLLM instance (setup failed)")
		return
	var burst: Dictionary = _llm.call("parse_offline", "give me a burst rifle")
	_check("aliases", not burst.has("_error") and str((burst.get("params", {}) as Dictionary).get("weapon_id", "")) == "trident",
		"aliases: 'give me a burst rifle' -> weapon_id 'trident' (got %s)" % str(burst.get("params", {})))
	if not burst.has("_error"):
		var v: Array = _llm.call("validate_modspec", burst)
		_check("aliases", bool(v[0]), "aliases: burst-rifle spec passes validate_modspec (%s)" % str(v[1]))
	var judge: Dictionary = _llm.call("parse_offline", "give me a judge")
	_check("aliases", not judge.has("_error") and str((judge.get("params", {}) as Dictionary).get("weapon_id", "")) == "judge",
		"aliases: 'give me a judge' -> weapon_id 'judge' (got %s)" % str(judge.get("params", {})))
	if not judge.has("_error"):
		var v2: Array = _llm.call("validate_modspec", judge)
		_check("aliases", bool(v2[0]), "aliases: judge spec passes validate_modspec (%s)" % str(v2[1]))
	# The offline parser must consult the installed-mod catalog (ModLoader),
	# not just its hardcoded keyword table, for a mod name to resolve.
	var llm_src := _src("res://scripts/forge/forge_llm.gd")
	_check("aliases", llm_src.contains("ModLoader") and (llm_src.contains("find_mod") or llm_src.contains("get_enabled_mods") or llm_src.contains("get_mods")),
		"aliases: forge_llm.gd consults ModLoader for mod-name resolution")


func _static_per_weapon_costs() -> void:
	if _llm == null:
		_check("per-weapon-costs", false, "per-weapon-costs: no ForgeLLM instance (setup failed)")
		return
	var ids := ["manticore", "longeye", "breacher", "hornet", "p9", "raptor", "lmg"]
	var costs: Dictionary = {}
	for wid in ids:
		var c: int = _llm.call("recompute_cost", "weapon", {"weapon_id": wid})
		costs[wid] = c
	var distinct := {}
	for wid in costs.keys():
		distinct[int(costs[wid])] = true
	_check("per-weapon-costs", distinct.size() >= 3,
		"per-weapon-costs: recompute_cost differs across >=3 weapons (got %s)" % str(costs))
	var trident_c: int = _llm.call("recompute_cost", "weapon", {"weapon_id": "trident"})
	var judge_c: int = _llm.call("recompute_cost", "weapon", {"weapon_id": "judge"})
	_check("per-weapon-costs", trident_c > 0 and judge_c > 0 and trident_c != judge_c,
		"per-weapon-costs: Trident vs Judge costs differ and are positive (got %d / %d)" % [trident_c, judge_c])
	# Shown: preview_cost (the Forge menu's COST line) must also differ.
	if _manager != null:
		var sniper: Dictionary = _manager.call("preview_cost", "give me a sniper rifle")
		var pistol: Dictionary = _manager.call("preview_cost", "give me a pistol")
		var sc := int(sniper.get("cost", -1)) if bool(sniper.get("ok", false)) else -1
		var pc := int(pistol.get("cost", -1)) if bool(pistol.get("ok", false)) else -1
		_check("per-weapon-costs", sc > 0 and pc > 0 and sc != pc,
			"per-weapon-costs: preview_cost sniper (%d) != pistol (%d)" % [sc, pc])
	else:
		_check("per-weapon-costs", false, "per-weapon-costs: no ForgeManager instance (setup failed)")


func _static_ghost_edit_presence() -> void:
	_placement_script = load("res://scripts/forge/forge_placement.gd") as GDScript
	_ghost_script = load("res://scripts/forge/forge_ghost.gd") as GDScript
	_structure_script = load("res://scripts/forge/forge_structure.gd") as GDScript
	_check("ghost-edit", _ghost_script != null, "ghost-edit: forge_ghost.gd exists (ForgeGhost, NOT-LANDED if absent)")
	_check("ghost-edit", _placement_script != null, "ghost-edit: forge_placement.gd exists (ForgePlacement, NOT-LANDED if absent)")
	var ghost_src := _src("res://scripts/forge/forge_ghost.gd")
	_check("ghost-edit", ghost_src.contains("VALID_COLOR") and ghost_src.contains("INVALID_COLOR") and ghost_src.contains("set_valid"),
		"ghost-edit: ForgeGhost carries validity tinting (VALID/INVALID_COLOR + set_valid)")
	var place_src := _src("res://scripts/forge/forge_placement.gd")
	_check("ghost-edit", place_src.contains("start_preview") and place_src.contains("move_selected_to") and place_src.contains("rotate_selected") and place_src.contains("delete_selected"),
		"ghost-edit: ForgePlacement has preview + move/rotate/delete-selected")


func _static_build_codes_presence() -> void:
	var llm_src := _src("res://scripts/forge/forge_llm.gd")
	_check("build-codes", llm_src.contains("encode_build_code") and llm_src.contains("decode_build_code"),
		"build-codes: ForgeLLM has encode_build_code / decode_build_code (NOT-LANDED if absent)")
	var mgr_src := _src("res://scripts/forge/forge_manager.gd")
	_check("build-codes", mgr_src.contains("get_last_build_code") and mgr_src.contains("build_from_code"),
		"build-codes: ForgeManager has get_last_build_code / build_from_code (NOT-LANDED if absent)")
	_check("build-codes", mgr_src.contains("search_history"),
		"build-codes: ForgeManager has search_history")
	var menu_src := _src("res://scripts/ui/forge_menu.gd")
	_check("build-codes", menu_src.contains("CodeCopyButton") and menu_src.contains("build_from_code"),
		"build-codes: Forge menu has build-code copy/paste UI")


func _static_mp_sync_presence() -> void:
	_sync_script = load("res://scripts/net/net_forge_sync.gd") as GDScript
	_check("mp-sync", _sync_script != null, "mp-sync: net_forge_sync.gd exists (NetForgeSync, NOT-LANDED if absent)")
	var mgr_src := _src("res://scripts/net/net_manager.gd")
	_check("mp-sync", mgr_src.contains("_rpc_forge") and mgr_src.contains("NetForgeSync"),
		"mp-sync: NetManager wires NetForgeSync with Forge RPCs")
	var sync_src := _src("res://scripts/net/net_forge_sync.gd")
	_check("mp-sync", sync_src.contains("host_place") and sync_src.contains("apply_place") and sync_src.contains("apply_snapshot") and sync_src.contains("host_remove") and sync_src.contains("apply_remove"),
		"mp-sync: NetForgeSync has host_place/apply_place/apply_snapshot/host_remove/apply_remove")


func _static_creator_presence() -> void:
	_creator_menu_script = load("res://scripts/ui/mod_creator_menu.gd") as GDScript
	_voxel_script = load("res://scripts/mods/voxel_asset_generator.gd") as GDScript
	_sandbox_script = load("res://scripts/ui/sandbox_test_room.gd") as GDScript
	var menu_src := _src("res://scripts/ui/main_menu.gd")
	_check("creator", menu_src.contains("CREATE A MOD") and menu_src.contains("_on_create_mod"),
		"creator: main_menu.gd has a CREATE A MOD button + handler (NOT-LANDED if absent)")
	var forge_src := _src("res://scripts/ui/forge_menu.gd")
	_check("creator", not forge_src.contains("_create_panel"),
		"creator: old in-Forge create panel is gone from forge_menu.gd (NOT-LANDED: _create_panel still present)")
	_check("creator", _creator_menu_script != null and FileAccess.file_exists("res://scenes/ui/mod_creator_menu.tscn"),
		"creator: standalone ModCreatorMenu script + scene exist (NOT-LANDED if absent)")
	var creator_src := _src("res://scripts/ui/mod_creator_menu.gd")
	_check("creator", creator_src.contains('CREATOR_TABS := ["CREATE", "CHAT", "MODS", "IMPORT/EXPORT"]'),
		"creator: creator tabs are CREATE / CHAT / MODS / IMPORT/EXPORT")
	_check("creator", _voxel_script != null and _src("res://scripts/mods/voxel_asset_generator.gd").contains("get_or_generate") and _src("res://scripts/mods/voxel_asset_generator.gd").contains("cache_hit"),
		"creator: VoxelAssetGenerator.get_or_generate exists with cache_hit (NOT-LANDED if absent)")
	_check("creator", _sandbox_script != null and _src("res://scripts/ui/sandbox_test_room.gd").contains("simulate_test"),
		"creator: SandboxTestRoom.simulate_test exists (NOT-LANDED if absent)")


func _static_watermelon() -> void:
	var creator_src := _src("res://scripts/ui/mod_creator_menu.gd")
	var voxel_src := _src("res://scripts/mods/voxel_asset_generator.gd")
	var found := creator_src.to_lower().contains("watermelon") and voxel_src.contains("_watermelon_voxels")
	_check("creator", found, "creator: watermelon-LMG example exists (creator placeholders + _watermelon_voxels, NOT-LANDED if absent)")
	var wiring := creator_src.contains("spawn_voxel_box") and creator_src.contains("fire_effect") and creator_src.contains("explosion")
	_check("creator", wiring, "creator: watermelon-LMG steers generation to voxel projectiles + fire_effect explosions")


# ------------------------------------------------------------------ phases
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > 1500:
		_timeout = true
		_finish()
		return true
	match _phase:
		1:
			if _frames >= 3:
				_tree_checks_part1()
				_phase = 2
				_frames = 0
		2:
			_budget_step()
		3:
			if _frames >= 3:
				_ui_checks()
				_phase = 4
				_vstep = 0
				_vframes = 0
		4:
			_voice_step()
	return false


func _reset_forge_cooldown() -> void:
	var forge := root.get_node_or_null("Forge")
	if forge != null:
		forge.set("_last_build_msec", -1000000)
		forge.set("_busy", false)


func _on_budget_forge_result(success: bool, message: String) -> void:
	_forge_msgs.append({"success": success, "message": message})


func _has_prop(obj: Object, name: String) -> bool:
	if obj == null:
		return false
	for p in obj.get_property_list():
		if str((p as Dictionary).get("name", "")) == name:
			return true
	return false


func _norm_key(s: String) -> String:
	return s.to_lower().replace(" ", "_").replace("-", "_")


func _tree_checks_part1() -> void:
	_tree_alias_temp_mod()
	_tree_presets_and_cap()
	_tree_destructible()
	_tree_build_codes_behavior()
	_tree_mp_sync_behavior()


## Budget OFF, end-to-end through the REAL Forge pipeline (not a direct
## Game.spend_budget call — the batch gates enforcement in ForgeManager,
## and Game.spend_budget intentionally STAYS enforced for other callers).
## Phase 2 sub-steps: 0 = submit at budget 0; 1 = verify built + code;
## 2 = build_from_code the same code; 3 = verify the identical rebuild.
func _budget_step() -> void:
	var forge := root.get_node_or_null("Forge")
	var game := root.get_node_or_null("Game")
	if forge == null or game == null:
		_check("budget-off", false, "budget-off: Forge/Game autoload missing")
		_check("build-codes", false, "build-codes: Forge autoload missing for build_from_code")
		_phase = 3
		_frames = 0
		return
	match _budget_phase_step:
		0:
			_check("budget-off", _manager_script.BUDGET_ENABLED == false,
				"budget-off: ForgeManager.BUDGET_ENABLED == false (got %s)" % str(_manager_script.BUDGET_ENABLED))
			if forge.has_signal("forge_result") and not forge.is_connected("forge_result", _on_budget_forge_result):
				forge.connect("forge_result", _on_budget_forge_result)
			_forge_msgs.clear()
			_budget_built_before = _group_count("forge_structure")
			game.set("forge_budget", 0)
			_reset_forge_cooldown()
			forge.call("submit_prompt", "build a wall in front of me")
			_budget_phase_step = 1
			_frames = 0
		1:
			if _frames < 10:
				return
			var built := _group_count("forge_structure") > _budget_built_before
			var insufficient := false
			for m in _forge_msgs:
				if str((m as Dictionary).get("message", "")).contains("Insufficient"):
					insufficient = true
			_check("budget-off", built and not insufficient,
				"budget-off: prompt build at budget 0 succeeds, never blocked (built=%s insufficient=%s msgs=%s)"
				% [str(built), str(insufficient), str(_forge_msgs)])
			_check("budget-off", int(game.get("forge_budget")) == 0,
				"budget-off: budget 0 unchanged after a free build (got %d)" % int(game.get("forge_budget")))
			_budget_code = str(forge.call("get_last_build_code")) if forge.has_method("get_last_build_code") else ""
			_check("build-codes", not _budget_code.is_empty(),
				"build-codes: pipeline records a last build code (got '%s')" % _budget_code)
			if _budget_code.is_empty():
				_budget_phase_step = 3
				_frames = 0
				return
			_forge_msgs.clear()
			_budget_pos = Vector3.ZERO
			var node: Node = _builder_script.last_built_node
			if node != null and is_instance_valid(node) and node is Node3D:
				_budget_pos = (node as Node3D).global_position
			# Clear the field first: the rebuild resolves the same
			# "near_player" position, and with the original still
			# standing the ground-snap would stack it on top (+1.25 y)
			# instead of rebuilding the identical placement.
			_free_node(node)
			_budget_built_before = _group_count("forge_structure")
			_reset_forge_cooldown()
			forge.call("build_from_code", _budget_code)
			_budget_phase_step = 2
			_frames = 0
		2:
			if _frames < 10:
				return
			var rebuilt := _group_count("forge_structure") > _budget_built_before
			var code2 := str(forge.call("get_last_build_code")) if forge.has_method("get_last_build_code") else ""
			var pos2 := Vector3.INF
			var node2: Node = _builder_script.last_built_node
			if node2 != null and is_instance_valid(node2) and node2 is Node3D:
				pos2 = (node2 as Node3D).global_position
			_check("build-codes", rebuilt and code2 == _budget_code and pos2.distance_to(_budget_pos) < 0.5,
				"build-codes: build_from_code rebuilds the identical build at the same position and the code chains (rebuilt=%s code stable=%s pos=%s want=%s)"
				% [str(rebuilt), str(code2 == _budget_code), str(pos2), str(_budget_pos)])
			game.set("forge_budget", 300)
			_budget_phase_step = 3
			_frames = 0
		3:
			# Free the two pipeline builds (wall + its code rebuild) so
			# later phases start from a clean structure count. Everything
			# in the group at this point was built by this suite.
			var leftovers: Array = []
			for n in get_nodes_in_group("forge_structure"):
				leftovers.append(n)
			for n in leftovers:
				_free_node(n)
			_phase = 3
			_frames = 0


func _tree_alias_temp_mod() -> void:
	var mod_id := "verify_alias_probe_zz"
	var block_id := "verify_probe_blaster"
	var folder := "user://mods/" + mod_id
	var wrote := false
	var ud := DirAccess.open("user://")
	if ud != null:
		if not ud.dir_exists("mods"):
			ud.make_dir("mods")
		var md := DirAccess.open("user://mods")
		if md != null:
			if not md.dir_exists(mod_id):
				md.make_dir(mod_id)
			var mf := FileAccess.open(folder + "/manifest.json", FileAccess.WRITE)
			if mf != null:
				mf.store_string(JSON.stringify({"name": "Verify Probe", "kind": "block", "version": "1.0", "file": "block.json"}))
				mf.close()
				var bf := FileAccess.open(folder + "/block.json", FileAccess.WRITE)
				if bf != null:
					bf.store_string(JSON.stringify({"block_id": block_id, "target": "weapon", "cost": 210, "display_name": "Probe Blaster", "description": "Verifier probe mod.", "base_weapon_id": "manticore"}))
					bf.close()
					wrote = true
	_check("aliases", wrote, "aliases: temp probe mod written to user://mods/ (setup for the parser test)")
	if not wrote:
		return
	_loader_script.call("rescan")
	var rec: Dictionary = _loader_script.call("find_mod", block_id)
	_check("aliases", not rec.is_empty() and str(rec.get("error", "")) == "",
		"aliases: probe mod scans clean (error='%s')" % str(rec.get("error", "")))
	var resolved := false
	var got_mod := ""
	for prompt in ["give me a probe blaster", "give me verify_probe_blaster"]:
		var spec: Dictionary = _llm.call("parse_offline", prompt)
		if spec.has("_error"):
			continue
		var mb := str((spec.get("params", {}) as Dictionary).get("mod_block", ""))
		if mb == mod_id or mb == block_id:
			resolved = true
			got_mod = mb
	_check("aliases", resolved,
		"aliases: installed mod name resolves in the offline parser (got mod_block='%s')" % got_mod)
	# Cleanup: remove the probe mod + rescan, so no persistent state remains.
	var base := OS.get_user_data_dir().path_join("mods").path_join(mod_id)
	DirAccess.remove_absolute(base.path_join("manifest.json"))
	DirAccess.remove_absolute(base.path_join("block.json"))
	DirAccess.remove_absolute(base)
	_loader_script.call("rescan")
	var after: Dictionary = _loader_script.call("find_mod", block_id)
	_check("aliases", after.is_empty(), "aliases: probe mod removed after the test (no pollution)")


func _preset_spec(prompt: String) -> Dictionary:
	return _llm.call("parse_offline", prompt)


func _spec_identity(spec: Dictionary, accepted: Array) -> bool:
	var params: Dictionary = spec.get("params", {})
	for key in ["shape", "preset", "type", "kind", "name", "mod_block"]:
		if params.has(key):
			if _norm_key(str(params.get(key, ""))) in accepted:
				return true
	return false


func _tree_presets_and_cap() -> void:
	# Presets are STRUCTURE shapes, placed via ForgeBuilder.build_preset
	# (the direct preset path — cost computed, enforcement off). The
	# prompt/offline-parser path is checked separately below.
	var shapes := ["stairs", "ramp", "wall", "jump_pad", "cover_piece", "sniper_nest"]
	var costs: Dictionary = {}
	for shape in shapes:
		_check("presets", _builder_script.call("is_structure_shape", shape) == true,
			"presets: '%s' is a registered structure shape" % shape)
		var c: int = _builder_script.call("structure_cost", shape)
		costs[shape] = c
		_check("presets", c > 0, "presets: '%s' has a positive computed cost (got %d)" % [shape, c])
	var distinct_costs := {}
	for shape in costs.keys():
		distinct_costs[int(costs[shape])] = true
	_check("presets", distinct_costs.size() >= 3,
		"presets: structure costs differ across >=3 presets (got %s)" % str(costs))
	for shape in shapes:
		var before := _group_count("forge_structure")
		var msg: String = _builder_script.build_preset(shape, _player, _arena)
		var node: Node = _builder_script.last_built_node
		var ok := not msg.begins_with(_builder_script.FAIL_PREFIX) and node != null and is_instance_valid(node)
		_check("presets", ok, "presets: build_preset('%s') places (msg=%s)" % [shape, msg])
		if ok:
			_check("presets", _has_collision(node), "presets: '%s' collides (has a CollisionShape)" % shape)
			_check("presets", _group_count("forge_structure") == before + 1,
				"presets: '%s' counts toward the structure cap" % shape)
			if shape == "jump_pad":
				var areas := (node as Node).find_children("*", "Area3D", true, false)
				_check("presets", areas.size() >= 1, "presets: jump pad carries a trigger Area3D (launch behaviour)")
			_free_node(node)
	# Cap 12 via the preset path: twelve walls place, the thirteenth is
	# refused as cap.
	var cap_nodes: Array = []
	var cap_ok := true
	for i in range(12):
		var m: String = _builder_script.build_preset("wall", _player, _arena)
		var n: Node = _builder_script.last_built_node
		if m.begins_with(_builder_script.FAIL_PREFIX) or n == null or not is_instance_valid(n):
			cap_ok = false
		else:
			cap_nodes.append(n)
	_check("presets", cap_ok and _group_count("forge_structure") >= 12,
		"presets: 12 preset structures place toward cap 12 (placed %d)" % cap_nodes.size())
	var m13: String = _builder_script.build_preset("wall", _player, _arena)
	_check("presets", m13.begins_with(_builder_script.FAIL_PREFIX) and m13.to_lower().contains("cap"),
		"presets: 13th preset build refused as cap (got: %s)" % m13)
	for n in cap_nodes:
		_free_node(n)
	# Wiring: some game caller (menu / prompt path) must actually invoke
	# the preset path — shapes + build_preset alone are a library, not a
	# feature, if nothing calls them.
	var wiring_src := _src("res://scripts/ui/forge_menu.gd") + _src("res://scripts/ui/main_menu.gd") + _src("res://scripts/core/main.gd") + _src("res://scripts/ui/hud.gd")
	_check("presets", wiring_src.contains("build_preset(") or wiring_src.contains("start_preview("),
		"presets: a game caller wires build_preset / start_preview (menu or prompt path, NOT-LANDED if absent)")
	# Prompt path: typing the preset name should reach the preset, not a
	# fallback ("build a ramp" -> bridge) or an _error.
	var prompts := {"stairs": "build stairs", "ramp": "build a ramp", "wall": "build a wall", "jump_pad": "build a jump pad", "cover_piece": "build a cover piece", "sniper_nest": "build a sniper nest"}
	for shape in prompts.keys():
		var spec: Dictionary = _llm.call("parse_offline", str(prompts[shape]))
		var mapped := false
		if not spec.has("_error"):
			# The NEW presets are structure shapes: a prompt that lands
			# on the OLD cover wall ("build a wall" -> cover) does not
			# demonstrate the new structure-wall preset.
			mapped = str(spec.get("target", "")) == "structure" and _spec_identity(spec, [_norm_key(shape)])
		_check("presets", mapped, "presets: prompt-path '%s' maps to the structure '%s' preset (got target=%s params=%s)" % [str(prompts[shape]), shape, str(spec.get("target", spec.get("_error", ""))), str(spec.get("params", {}))])


func _tree_destructible() -> void:
	var ctx := {"player": _player, "root": _arena}
	# Structures: damage must land, 0 HP must destroy, repair must restore.
	var spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "bunker", "position": "near_player"}, "cost": 180, "ttl": 0}
	var msg: String = _builder_script.build(spec, ctx)
	var node: Node = _builder_script.last_built_node
	if msg.begins_with(_builder_script.FAIL_PREFIX) or node == null or not is_instance_valid(node):
		_check("destructible", false, "destructible: bunker builds for the damage test (msg=%s)" % msg)
		return
	var dmg_method := ""
	for m in ["take_damage", "apply_damage", "damage"]:
		if node.has_method(m):
			dmg_method = m
			break
	_check("destructible", dmg_method != "", "destructible: structure exposes a damage path (take_damage/apply_damage/damage)")
	if dmg_method != "":
		var hp_before := 0.0
		if node.has_meta("hp"):
			hp_before = float(node.get_meta("hp"))
		elif _has_prop(node, "hp"):
			hp_before = float(node.get("hp"))
		var ac := _arg_count(node, dmg_method)
		if ac == 3:
			node.call(dmg_method, 100.0, node.global_position if node is Node3D else Vector3.ZERO, false)
		elif ac == 1:
			node.call(dmg_method, 100.0)
		else:
			node.call(dmg_method, 100.0)
		var hp_after := hp_before
		if is_instance_valid(node):
			if node.has_meta("hp"):
				hp_after = float(node.get_meta("hp"))
			elif _has_prop(node, "hp"):
				hp_after = float(node.get("hp"))
		_check("destructible", is_instance_valid(node) and hp_after < hp_before,
			"destructible: structure damage reduces HP (%.0f -> %.0f)" % [hp_before, hp_after])
		if is_instance_valid(node):
			var ac2 := _arg_count(node, dmg_method)
			if ac2 == 3:
				node.call(dmg_method, 999999.0, node.global_position if node is Node3D else Vector3.ZERO, false)
			else:
				node.call(dmg_method, 999999.0)
			var destroyed := not is_instance_valid(node) or node.is_queued_for_deletion()
			if is_instance_valid(node) and not destroyed:
				if node.has_method("is_destroyed"):
					destroyed = bool(node.call("is_destroyed"))
				elif node.has_meta("hp"):
					destroyed = float(node.get_meta("hp")) <= 0.0
				elif _has_prop(node, "hp"):
					destroyed = float(node.get("hp")) <= 0.0
				elif _has_prop(node, "broken"):
					destroyed = bool(node.get("broken"))
			_check("destructible", destroyed, "destructible: structure destroyed at 0 HP")
		_free_node(node)
	# Repair on a fresh structure: damage then repair restores HP.
	var msg2: String = _builder_script.build(spec, ctx)
	var node2: Node = _builder_script.last_built_node
	if msg2.begins_with(_builder_script.FAIL_PREFIX) or node2 == null or not is_instance_valid(node2):
		_check("destructible", false, "destructible: fresh bunker builds for the repair test (msg=%s)" % msg2)
		return
	if dmg_method != "" and node2.has_method(dmg_method) and node2.has_method("repair"):
		var ac3 := _arg_count(node2, dmg_method)
		if ac3 == 3:
			node2.call(dmg_method, 100.0, node2.global_position if node2 is Node3D else Vector3.ZERO, false)
		else:
			node2.call(dmg_method, 100.0)
		var rac := _arg_count(node2, "repair")
		if rac == 1:
			node2.call("repair", 100.0)
		else:
			node2.call("repair")
		var hp_rep := -1.0
		if node2.has_meta("hp"):
			hp_rep = float(node2.get_meta("hp"))
		elif _has_prop(node2, "hp"):
			hp_rep = float(node2.get("hp"))
		_check("destructible", hp_rep >= 599.0,
			"destructible: repair restores HP to max (got %.0f, want ~600)" % hp_rep)
	else:
		_check("destructible", false, "destructible: structure exposes repair() (NOT-LANDED if absent)")
	_free_node(node2)
	# Covers: builder-built cover (the batch sets max_hp meta on it) —
	# damage then repair through the batch's duck-typed path,
	# ForgeStructure.repair_target (covers have no repair() of their own
	# by design; repair_target is the documented repair entry point).
	var cover_spec := {"spec_version": 1, "action": "spawn", "target": "cover",
		"params": {"shape": "wall", "size_voxels": [4, 3, 1], "position": "near_player", "hp": 100.0}, "cost": 100, "ttl": 0}
	var cmsg: String = _builder_script.build(cover_spec, ctx)
	var cover: Node = _builder_script.last_built_node
	if cmsg.begins_with(_builder_script.FAIL_PREFIX) or cover == null or not is_instance_valid(cover):
		_check("destructible", false, "destructible: builder-built cover for the repair test (msg=%s)" % cmsg)
		return
	cover.call("take_damage", 40.0, Vector3.ZERO, false)
	_check("destructible", is_equal_approx(float(cover.get("hp")), 60.0),
		"destructible: cover take_damage 100 -> 60 (got %s)" % str(cover.get("hp")))
	var restored: float = _structure_script.call("repair_target", cover, 40.0)
	_check("destructible", is_equal_approx(restored, 40.0) and is_equal_approx(float(cover.get("hp")), 100.0),
		"destructible: repair_target restores cover 60 -> 100 (restored=%.0f hp=%s)" % [restored, str(cover.get("hp"))])
	cover.call("take_damage", 999999.0, Vector3.ZERO, false)
	var cover_dead := false
	if not is_instance_valid(cover) or cover.is_queued_for_deletion():
		cover_dead = true
	elif cover.has_method("is_broken"):
		cover_dead = bool(cover.call("is_broken"))
	elif float(cover.get("hp")) <= 0.0:
		cover_dead = true
	_check("destructible", cover_dead, "destructible: cover destroyed/broken at 0 HP")
	_free_node(cover)


func _tree_build_codes_behavior() -> void:
	# Build codes live on ForgeLLM (encode/decode) + ForgeManager
	# (get_last_build_code / build_from_code, exercised in the budget
	# phase). Here: pure encode/decode round-trip + rebuild from a
	# decoded spec + History search on the manager.
	var spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "bunker", "position": [6.0, 0.0, -4.0]}, "cost": 180, "ttl": 0}
	var code: Variant = _llm.call("encode_build_code", spec)
	_check("build-codes", code is String and str(code).begins_with("FORGE") and str(code).length() > 10,
		"build-codes: encode_build_code produces a prefixed code string (got '%s')" % str(code))
	if not (code is String) or str(code).is_empty():
		_check("build-codes", false, "build-codes: decode round-trips the spec")
		_check("build-codes", false, "build-codes: rebuild from a decoded spec is identical")
		_check("build-codes", false, "build-codes: garbage code decodes to empty")
	else:
		var decoded: Dictionary = _llm.call("decode_build_code", str(code))
		var same := str(decoded.get("target", "")) == "structure" and str((decoded.get("params", {}) as Dictionary).get("shape", "")) == "bunker"
		_check("build-codes", same, "build-codes: decode round-trips the spec (got %s)" % str(decoded))
		var garbage: Dictionary = _llm.call("decode_build_code", "not-a-build-code!!!")
		_check("build-codes", garbage.is_empty(), "build-codes: garbage code decodes to empty")
		# Rebuild from the decoded spec: identical shape + position + HP.
		var ctx := {"player": _player, "root": _arena}
		var msg: String = _builder_script.build(decoded, ctx)
		var node: Node = _builder_script.last_built_node
		var ok := not msg.begins_with(_builder_script.FAIL_PREFIX) and node != null and is_instance_valid(node)
		if ok and node is Node3D:
			ok = (node as Node3D).global_position.distance_to(Vector3(6.0, 0.0, -4.0)) < 0.5
		_check("build-codes", ok, "build-codes: rebuild from a decoded spec is identical (msg=%s)" % msg)
		if node != null and is_instance_valid(node):
			_free_node(node)
	# History search on the Forge manager: filters without mutating.
	if _manager == null or not _manager.has_method("search_history"):
		_check("build-codes", false, "build-codes: History search_history exists on Forge (NOT-LANDED if absent)")
		return
	# Typed Array[String]: Object.set() silently REJECTS an untyped
	# Array literal for an Array[String] script var (the suite's
	# earlier failure was this Godot gotcha, not a search bug).
	var hist: Array[String] = ["build a tower", "give me a sniper rifle", "build a wall"]
	_manager.set("_history", hist)
	var filtered: Variant = _manager.call("search_history", "tower")
	var search_ok := filtered is Array and (filtered as Array).size() == 1 and str((filtered as Array)[0]).to_lower().contains("tower")
	_check("build-codes", search_ok, "build-codes: History search 'tower' filters to the tower entry (got %s)" % str(filtered))
	var unfiltered: Variant = _manager.call("search_history", "")
	_check("build-codes", unfiltered is Array and (unfiltered as Array).size() == 3,
		"build-codes: History search '' returns everything (got %s)" % str(unfiltered))


func _tree_mp_sync_behavior() -> void:
	# Peer sim through the REAL NetForgeSync registry (in-process — the
	# sandbox blocks real UDP loopback, so no real ENet peers are
	# created). The live RPC path (NetManager _rpc_forge_*) is covered
	# by the static wiring check; this sim proves the registry logic:
	# place -> identical, destroy -> removed, late join -> full list.
	if _sync_script == null:
		_check("mp-sync", false, "mp-sync: NetForgeSync script loads")
		_check("mp-sync", false, "mp-sync: place on peer 1 -> identical on peer 2")
		_check("mp-sync", false, "mp-sync: destroy on host -> removed on peer 2")
		_check("mp-sync", false, "mp-sync: late join receives the full list")
		_check("mp-sync", false, "mp-sync: new preset shapes sync (stairs)")
		return
	var peer1: Node = _sync_script.new() as Node
	var peer2: Node = _sync_script.new() as Node
	peer1.call("set_peer_context", false, true, 1)
	peer2.call("set_peer_context", false, false, 2)
	var spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "bunker", "position": [8.0, 0.0, -8.0]}, "cost": 180, "ttl": 0}
	var entry1: Dictionary = peer1.call("host_place", spec, 1, Vector3(8.0, 0.0, -8.0), Vector3.ZERO)
	var iid := int(entry1.get("instance_id", 0))
	_check("mp-sync", not entry1.is_empty() and iid > 0 and str(entry1.get("preset_id", "")) == "structure:bunker",
		"mp-sync: host_place registers the build (entry=%s)" % str(entry1))
	if entry1.is_empty():
		return
	var node2: Node = peer2.call("apply_place", entry1)
	_check("mp-sync", node2 != null and is_instance_valid(node2),
		"mp-sync: place on peer 1 -> peer 2 spawns the build (apply_place)")
	_check("mp-sync", str(peer1.call("get_wire_entries")) == str(peer2.call("get_wire_entries")) and int(peer1.call("entry_count")) == 1 and int(peer2.call("entry_count")) == 1,
		"mp-sync: place on peer 1 -> identical registries on peer 2 (counts %d / %d)" % [int(peer1.call("entry_count")), int(peer2.call("entry_count"))])
	# Destroy on host -> removed on peer 2.
	var removed_host: bool = peer1.call("host_remove", iid)
	var removed_peer: bool = peer2.call("apply_remove", iid)
	_check("mp-sync", removed_host and removed_peer and int(peer1.call("entry_count")) == 0 and int(peer2.call("entry_count")) == 0,
		"mp-sync: destroy on host -> removed on peer 2 (counts %d / %d)" % [int(peer1.call("entry_count")), int(peer2.call("entry_count"))])
	# Late join: a fresh peer applying the host snapshot gets the list.
	var entry2: Dictionary = peer1.call("host_place", spec, 1, Vector3(8.0, 0.0, -8.0), Vector3.ZERO)
	var iid2 := int(entry2.get("instance_id", 0))
	var peer3: Node = _sync_script.new() as Node
	peer3.call("set_peer_context", false, false, 3)
	var placed_n: int = peer3.call("apply_snapshot", peer1.call("get_wire_entries"))
	_check("mp-sync", placed_n >= 1 and int(peer3.call("entry_count")) == int(peer1.call("entry_count")) and str(peer3.call("get_wire_entries")) == str(peer1.call("get_wire_entries")),
		"mp-sync: late join receives the full list (placed=%d counts %d / %d)" % [placed_n, int(peer3.call("entry_count")), int(peer1.call("entry_count"))])
	# New preset shapes sync too (stairs is the probe for the batch's
	# six new structure presets).
	var stair_spec := {"spec_version": 1, "action": "spawn", "target": "structure",
		"params": {"shape": "stairs", "position": [10.0, 0.0, -10.0]}, "cost": 100, "ttl": 0}
	var stair_entry: Dictionary = peer1.call("host_place", stair_spec, 1, Vector3(10.0, 0.0, -10.0), Vector3.ZERO)
	_check("mp-sync", not stair_entry.is_empty() and str(stair_entry.get("preset_id", "")) == "structure:stairs",
		"mp-sync: new preset shapes sync — host_place('stairs') registers (entry=%s)" % str(stair_entry))
	# Cleanup: remove every entry so spawned sim nodes leave the arena.
	peer1.call("host_remove", iid2)
	peer2.call("apply_remove", iid2)
	peer3.call("apply_remove", iid2)
	if not stair_entry.is_empty():
		var sid := int(stair_entry.get("instance_id", 0))
		peer1.call("host_remove", sid)

# ------------------------------------------------------------------ UI phase
func _collect_buttons(node: Node, out: Array) -> void:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_collect_buttons(c, out)


func _find_by_name_substr(node: Node, substr: String) -> Node:
	if node.name.to_lower().contains(substr.to_lower()):
		return node
	for c in node.get_children():
		var r := _find_by_name_substr(c, substr)
		if r != null:
			return r
	return null


func _count_kinds(node: Node, out: Dictionary) -> void:
	if node is LineEdit:
		out["lineedit"] = int(out.get("lineedit", 0)) + 1
	elif node is TextEdit:
		out["textedit"] = int(out.get("textedit", 0)) + 1
	elif node is OptionButton:
		out["option"] = int(out.get("option", 0)) + 1
	elif node is CheckButton:
		out["check"] = int(out.get("check", 0)) + 1
	elif node is Button:
		out["button"] = int(out.get("button", 0)) + 1
	elif node is Label:
		out["label"] = int(out.get("label", 0)) + 1
	for c in node.get_children():
		_count_kinds(c, out)


func _ghost_node() -> Node:
	var found := _find_by_name_substr(root, "ghost")
	if found != null:
		return found
	return _find_by_name_substr(_arena, "ghost")


func _material_color(node: Node) -> Color:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.material_override != null and (mi.material_override is StandardMaterial3D):
			var m := mi.material_override as StandardMaterial3D
			if m.emission_enabled:
				return m.emission
			return m.albedo_color
		if mi.mesh != null:
			var sm: Material = mi.mesh.surface_get_material(0)
			if sm is StandardMaterial3D:
				var m2 := sm as StandardMaterial3D
				if m2.emission_enabled:
					return m2.emission
				return m2.albedo_color
	for c in node.get_children():
		var col := _material_color(c)
		if col != Color(-1, -1, -1, -1):
			return col
	return Color(-1, -1, -1, -1)


func _tint_is(node: Node, want_green: bool) -> bool:
	var col := _material_color(node)
	if col == Color(-1, -1, -1, -1):
		return false
	if want_green:
		return col.g > col.r + 0.1 and col.g > col.b + 0.1
	return col.r > col.g + 0.1 and col.r > col.b + 0.1


func _ui_checks() -> void:
	# Forge menu: instantiate the real scene.
	var ps := load("res://scenes/ui/forge_menu.tscn") as PackedScene
	if ps == null:
		_check("budget-off", false, "budget-off: forge_menu.tscn loads")
		_check("voice-confirm", false, "voice-confirm: forge_menu.tscn loads")
		return
	_forge_menu = ps.instantiate() as Control
	_forge_menu.name = "ForgeBatchMenu"
	root.add_child(_forge_menu)
	_forge_menu.call("open")
	# Budget OFF: no budget UI visible anywhere in the open menu.
	var budget_visible := false
	var labels: Array = []
	_collect_labels(_forge_menu, labels)
	for l in labels:
		var lbl := l as Label
		if lbl.text.to_lower().contains("budget") and lbl.is_visible_in_tree():
			budget_visible = true
	_check("budget-off", not budget_visible, "budget-off: no budget UI visible in the open Forge menu")
	# Per-weapon costs SHOWN: the COST preview differs per weapon.
	var input := _forge_menu.find_child("PromptInput", true, false) as LineEdit
	var preview := _forge_menu.find_child("PreviewLabel", true, false) as Label
	if input != null and preview != null:
		input.text = "give me a sniper rifle"
		_forge_menu.call("_update_preview")
		var sniper_text := preview.text
		input.text = "give me a pistol"
		_forge_menu.call("_update_preview")
		var pistol_text := preview.text
		_check("per-weapon-costs", sniper_text.contains("COST: ") and pistol_text.contains("COST: ") and sniper_text != pistol_text,
			"per-weapon-costs: menu COST preview differs (sniper='%s' pistol='%s')" % [sniper_text, pistol_text])
	else:
		_check("per-weapon-costs", false, "per-weapon-costs: Forge menu PromptInput/PreviewLabel found")
	# History search field in the menu.
	_ui_history_search_field()
	# Ghost + edit through the real menu / builder / manager.
	_ui_ghost_edit()
	# Creator: main-menu button + form + voxel cache + sandbox.
	_ui_creator()
	# Voice: arm the listener before the voice phase runs.
	var forge := root.get_node_or_null("Forge")
	if forge != null and forge.has_signal("forge_result"):
		if not forge.is_connected("forge_result", _on_voice_forge_result):
			forge.connect("forge_result", _on_voice_forge_result)
	_voice_results = 0
	_voice_struct_before = _group_count("forge_structure")


func _collect_labels(node: Node, out: Array) -> void:
	if node is Label:
		out.append(node)
	for c in node.get_children():
		_collect_labels(c, out)


func _ui_history_search_field() -> void:
	var field: LineEdit = _find_search_field(_forge_menu)
	if field == null:
		_check("build-codes", false, "build-codes: Forge menu has a History search field (NOT-LANDED if absent)")
		return
	# Cinematic layout: history lives in the collapsed "History &
	# Tools" details — expand it first, or its buttons are never
	# visible in tree and the filter check reads empty.
	var details_btn := _forge_menu.find_child("ForgeDetailsButton", true, false) as Button
	if details_btn != null:
		details_btn.button_pressed = true
	var forge := root.get_node_or_null("Forge")
	if forge != null:
		# Typed Array[String] (see the manager search check): an
		# untyped Array literal is silently rejected by Object.set().
		var hist2: Array[String] = ["build a tower", "give me a sniper rifle", "build a wall"]
		forge.set("_history", hist2)
	# Purge the history list's existing children NOW (immediate free):
	# _refresh_history queue_frees them, which leaves stale buttons
	# visible/collection-visible for the rest of this frame.
	var hist_list_purge: Variant = _forge_menu.get("_history_list")
	if hist_list_purge is Node:
		for c in (hist_list_purge as Node).get_children():
			(c as Node).free()
	# One refresh only (via the field's own handler): the history list is
	# rebuilt once, so no stale queued buttons pollute the collection.
	field.text = "tower"
	if _forge_menu.has_method("_on_history_search_changed"):
		_forge_menu.call("_on_history_search_changed", "tower")
	else:
		_forge_menu.call("_refresh_history")
	# Scope to the HISTORY LIST container only: preset buttons elsewhere
	# in the menu also carry a "forge_prompt" meta (they fill the prompt),
	# so a whole-menu collection would count presets as history.
	var hist_list: Variant = _forge_menu.get("_history_list")
	var visible_hist: Array = []
	if hist_list is Node:
		var btns: Array = []
		_collect_buttons(hist_list as Node, btns)
		for b in btns:
			var btn := b as Button
			if btn.is_visible_in_tree() and btn.has_meta("forge_prompt"):
				visible_hist.append(str(btn.get_meta("forge_prompt")))
	var ok := visible_hist.size() == 1 and str(visible_hist[0]).to_lower().contains("tower")
	_check("build-codes", ok, "build-codes: History search field filters to the tower entry (visible=%s)" % str(visible_hist))


func _find_search_field(node: Node) -> LineEdit:
	if node is LineEdit and (node.name.to_lower().contains("search") or node.name.to_lower().contains("filter")):
		return node as LineEdit
	for c in node.get_children():
		var r := _find_search_field(c)
		if r != null:
			return r
	return null


func _ui_ghost_edit() -> void:
	# Ghost + edit through the REAL ForgePlacement / ForgeGhost API.
	if _placement_script == null or _ghost_script == null:
		_check("ghost-edit", false, "ghost-edit: ForgePlacement/ForgeGhost scripts load")
		_check("ghost-edit", false, "ghost-edit: ghost appears with validity tint")
		_check("ghost-edit", false, "ghost-edit: ghost is visual-only (no collision, no cap)")
		_check("ghost-edit", false, "ghost-edit: confirm_preview builds / cancel_preview dismisses")
		_check("ghost-edit", false, "ghost-edit: move/rotate/delete/repair on a placed structure")
		return
	var placement: Node = _placement_script.call("attach_to", _arena)
	_check("ghost-edit", placement != null, "ghost-edit: ForgePlacement.attach_to works")
	if placement == null:
		return
	# Unknown shape -> no ghost.
	var null_ghost: Variant = _ghost_script.call("create_for_shape", "not_a_shape")
	_check("ghost-edit", null_ghost == null, "ghost-edit: ghost for an unknown shape is null")
	# Ghost preview for a real preset.
	var started: bool = placement.call("start_preview", "sniper_nest", {}, _player, _arena)
	_check("ghost-edit", started and bool(placement.call("has_preview")),
		"ghost-edit: start_preview('sniper_nest') shows a ghost")
	var ghost: Node = placement.get("_ghost")
	if ghost != null and is_instance_valid(ghost):
		_check("ghost-edit", str(ghost.get("ghost_shape")) == "sniper_nest",
			"ghost-edit: ghost is for the requested shape (got %s)" % str(ghost.get("ghost_shape")))
		_check("ghost-edit", not ghost.is_in_group("forge_structure"),
			"ghost-edit: ghost never joins the structure-cap group")
		var bodies := ghost.find_children("*", "StaticBody3D", true, false)
		_check("ghost-edit", bodies.is_empty(), "ghost-edit: ghost carries no live collision (StaticBody never added)")
		var mat: Variant = ghost.get("_mat")
		var valid_col: Color = _ghost_script.VALID_COLOR
		var invalid_col: Color = _ghost_script.INVALID_COLOR
		var tint_ok := false
		if mat is StandardMaterial3D:
			tint_ok = (mat as StandardMaterial3D).albedo_color == valid_col
			ghost.call("set_valid", false)
			tint_ok = tint_ok and (mat as StandardMaterial3D).albedo_color == invalid_col
			ghost.call("set_valid", true)
			tint_ok = tint_ok and (mat as StandardMaterial3D).albedo_color == valid_col
		_check("ghost-edit", tint_ok, "ghost-edit: ghost validity tint is VALID_COLOR when valid, INVALID_COLOR when invalid")
	else:
		_check("ghost-edit", false, "ghost-edit: ghost node exists after start_preview")
		_check("ghost-edit", false, "ghost-edit: ghost is for the requested shape")
		_check("ghost-edit", false, "ghost-edit: ghost never joins the structure-cap group")
		_check("ghost-edit", false, "ghost-edit: ghost carries no live collision")
		_check("ghost-edit", false, "ghost-edit: ghost validity tint is VALID/INVALID_COLOR")
	# Cancel dismisses without building; confirm builds at the ghost.
	var before_cancel := _group_count("forge_structure")
	placement.call("cancel_preview")
	_check("ghost-edit", not bool(placement.call("has_preview")) and _group_count("forge_structure") == before_cancel,
		"ghost-edit: cancel_preview dismisses the ghost without building")
	placement.call("start_preview", "bunker", {}, _player, _arena)
	var before_confirm := _group_count("forge_structure")
	var confirm_msg: String = placement.call("confirm_preview")
	var built_node: Node = _builder_script.last_built_node
	_check("ghost-edit", not bool(placement.call("has_preview")) and _group_count("forge_structure") == before_confirm + 1 and built_node != null and is_instance_valid(built_node),
		"ghost-edit: confirm_preview builds at the ghost position (msg=%s)" % confirm_msg)
	# Edit the confirmed build: select + move + rotate + repair + delete.
	if built_node != null and is_instance_valid(built_node):
		var selected: bool = placement.call("select", built_node)
		_check("ghost-edit", selected, "ghost-edit: select() picks the placed structure")
		var moved: bool = placement.call("move_selected_to", Vector3(9, 0, -9))
		var pos_ok := moved and (built_node as Node3D).global_position.distance_to(Vector3(9, 0, -9)) < 0.6
		_check("ghost-edit", pos_ok, "ghost-edit: move_selected_to moves the placed structure (moved=%s pos=%s)" % [str(moved), str((built_node as Node3D).global_position)])
		var rot_before := (built_node as Node3D).rotation.y
		var rotated: bool = placement.call("rotate_selected", 45.0)
		_check("ghost-edit", rotated and absf((built_node as Node3D).rotation.y - rot_before - deg_to_rad(45.0)) < 0.01,
			"ghost-edit: rotate_selected yaws 45 degrees (rotated=%s)" % str(rotated))
		built_node.call("take_damage", 100.0, (built_node as Node3D).global_position, false)
		var repaired: float = placement.call("repair_selected")
		_check("ghost-edit", repaired > 0.0, "ghost-edit: repair_selected restores HP (restored=%.0f)" % repaired)
		var deleted: bool = placement.call("delete_selected")
		# delete_target() removes the group + queue_frees: a queued
		# node is still instance-valid this frame, so group removal
		# (or queued-for-deletion) is the same-frame signal.
		var gone := deleted and (not built_node.is_in_group("forge_structure") or built_node.is_queued_for_deletion() or not is_instance_valid(built_node))
		_check("ghost-edit", gone,
			"ghost-edit: delete_selected removes the placed structure (deleted=%s in_group=%s queued=%s)" % [str(deleted), str(built_node.is_in_group("forge_structure")), str(built_node.is_queued_for_deletion())])
		if is_instance_valid(built_node):
			_free_node(built_node)
	else:
		_check("ghost-edit", false, "ghost-edit: select() picks the placed structure (no confirmed build)")
		_check("ghost-edit", false, "ghost-edit: move_selected_to moves the placed structure")
		_check("ghost-edit", false, "ghost-edit: rotate_selected yaws 45 degrees")
		_check("ghost-edit", false, "ghost-edit: repair_selected restores HP")
		_check("ghost-edit", false, "ghost-edit: delete_selected removes the placed structure")


func _ui_edit_one(kind: String, methods: Array, spec: Dictionary, ctx: Dictionary, value: Variant) -> void:
	var msg: String = _builder_script.build(spec, ctx)
	var node: Node = _builder_script.last_built_node
	if msg.begins_with(_builder_script.FAIL_PREFIX) or node == null or not is_instance_valid(node):
		_check("ghost-edit", false, "ghost-edit: %s test needs a placed structure (msg=%s)" % [kind, msg])
		return
	var holders: Array = []
	if _forge_menu != null:
		holders.append(_forge_menu)
	if _builder != null:
		holders.append(_builder)
	if _manager != null:
		holders.append(_manager)
	holders.append(node)
	var before_pos := (node as Node3D).global_position if node is Node3D else Vector3.ZERO
	var before_rot := (node as Node3D).rotation if node is Node3D else Vector3.ZERO
	var tried := false
	var effected := false
	for h in holders:
		var m := _find_method(h, methods)
		if m == "":
			continue
		tried = true
		var ac := _arg_count(h, m)
		if kind == "delete":
			if ac == 1:
				h.call(m, node)
			elif ac == 2:
				h.call(m, node, null)
			elif ac == 0:
				h.call(m)
			else:
				h.call(m, node)
		elif ac == 2:
			h.call(m, node, value)
		elif ac == 1:
			h.call(m, value)
		elif ac == 0:
			h.call(m)
		else:
			h.call(m, node)
		if not is_instance_valid(node):
			effected = kind == "delete"
			break
		if kind == "move" and node is Node3D and (node as Node3D).global_position.distance_to(value as Vector3) < 0.5:
			effected = true
			break
		if kind == "rotate" and node is Node3D and absf((node as Node3D).rotation.y - before_rot.y) > 0.1:
			effected = true
			break
		if kind == "delete":
			continue
	if kind == "move":
		_check("ghost-edit", tried and effected,
			"ghost-edit: move works on a placed structure (tried=%s effected=%s from=%s)" % [str(tried), str(effected), str(before_pos)])
	elif kind == "rotate":
		_check("ghost-edit", tried and effected,
			"ghost-edit: rotate works on a placed structure (tried=%s effected=%s)" % [str(tried), str(effected)])
	else:
		_check("ghost-edit", tried and effected,
			"ghost-edit: delete works on a placed structure (tried=%s effected=%s)" % [str(tried), str(effected)])
	if is_instance_valid(node):
		_free_node(node)


func _ui_creator() -> void:
	# Main-menu button opens the creator.
	var mps := load("res://scenes/ui/main_menu.tscn") as PackedScene
	var creator_ui: Control = null
	if mps != null:
		_main_menu = mps.instantiate() as Control
		_main_menu.name = "ForgeBatchMainMenu"
		_main_menu.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
		_main_menu.position = Vector2.ZERO
		_main_menu.size = Vector2(1280, 720)
		root.add_child(_main_menu)
		var btn := _find_button_with(_main_menu, "creat")
		_check("creator", btn != null, "creator: main menu has a creator button (NOT-LANDED if absent)")
		if btn != null:
			btn.emit_signal("pressed")
			creator_ui = _find_creator_ui()
			_check("creator", creator_ui != null, "creator: main-menu button opens the creator")
	else:
		_check("creator", false, "creator: main_menu.tscn loads")
		_check("creator", false, "creator: main-menu button opens the creator")
	if creator_ui == null:
		creator_ui = _instantiate_creator_direct()
	if creator_ui == null:
		_check("creator", false, "creator: creator UI instantiates (tabs CREATE / MODS / IMPORT-EXPORT)")
		_check("creator", false, "creator: IMPORT-EXPORT tab is a placeholder with no functionality")
		_check("creator", false, "creator: form has multi-choice categories + name + visual + logic")
		_check("creator", false, "creator: form produces a validated mod")
		_check("creator", false, "creator: voxel asset generated + cached + reused on repeat description")
		_check("creator", false, "creator: sandbox test works and does not pollute the real mod list")
		return
	_ui_creator_tabs(creator_ui)


func _norm_tab(title: String) -> String:
	# "IMPORT/EXPORT" (the code's literal) and "IMPORT-EXPORT" (the task
	# wording) are the same tab; normalize separators + case.
	return title.to_upper().replace("/", "-").replace(" ", "-")


func _find_creator_ui() -> Control:
	return _find_creator_ui_in(root)


func _find_creator_ui_in(node: Node) -> Control:
	# A candidate must own a TabContainer carrying ALL THREE creator
	# tabs. (Matching any one tab is a false positive: the Forge menu's
	# own TabContainer carries MODS.)
	if node is Control and node != _main_menu and node != _forge_menu:
		var tabs := _find_tab_container(node)
		if tabs != null:
			var titles: Array = []
			for i in tabs.get_tab_count():
				titles.append(_norm_tab(tabs.get_tab_title(i)))
			if "CREATE" in titles and "MODS" in titles and "IMPORT-EXPORT" in titles:
				return node as Control
	for c in node.get_children():
		var r := _find_creator_ui_in(c)
		if r != null:
			return r
	return null


func _instantiate_creator_direct() -> Control:
	for f in DirAccess.get_files_at("res://scenes/ui/"):
		if str(f).to_lower().contains("creator"):
			var ps := load("res://scenes/ui/".path_join(str(f))) as PackedScene
			if ps != null:
				var inst := ps.instantiate() as Control
				if inst != null:
					inst.name = "ForgeBatchCreatorDirect"
					root.add_child(inst)
					return inst
	for p in CREATOR_SCRIPT_PATHS:
		if FileAccess.file_exists(p):
			var scr: GDScript = load(p) as GDScript
			if scr != null:
				var inst: Object = scr.new()
				if inst is Control:
					var ctl := inst as Control
					ctl.name = "ForgeBatchCreatorDirect"
					root.add_child(ctl)
					return ctl
	return null


func _ui_creator_tabs(creator_ui: Control) -> void:
	var tabs := _find_tab_container(creator_ui)
	if tabs == null:
		_check("creator", false, "creator: creator has a TabContainer")
		return
	var titles: Array = []
	for i in tabs.get_tab_count():
		titles.append(_norm_tab(tabs.get_tab_title(i)))
	_check("creator", "CREATE" in titles and "MODS" in titles and "IMPORT-EXPORT" in titles,
		"creator: tabs are CREATE / MODS / IMPORT-EXPORT (got %s)" % str(titles))
	# IMPORT-EXPORT: placeholder — a placeholder label, and no enabled
	# visible button (no functionality).
	var ie_idx := -1
	for i in tabs.get_tab_count():
		if _norm_tab(tabs.get_tab_title(i)) == "IMPORT-EXPORT":
			ie_idx = i
	if ie_idx >= 0:
		var tab_ctl := tabs.get_tab_control(ie_idx)
		var btns: Array = []
		_collect_buttons(tab_ctl, btns)
		var live := false
		for b in btns:
			var btn := b as Button
			if btn.visible and not btn.disabled:
				live = true
		var placeholder := _texts_contain(tab_ctl, "placeholder") or _texts_contain(tab_ctl, "coming soon") or _texts_contain(tab_ctl, "not yet") or _texts_contain(tab_ctl, "later update")
		_check("creator", not placeholder and live,
			"creator: IMPORT-EXPORT is live (placeholder label=%s, live button=%s)" % [str(placeholder), str(live)])
	else:
		_check("creator", false, "creator: IMPORT-EXPORT tab exists")
	# CREATE form: multi-choice categories + name + visual + logic.
	var create_idx := -1
	for i in tabs.get_tab_count():
		if _norm_tab(tabs.get_tab_title(i)) == "CREATE":
			create_idx = i
	if create_idx < 0:
		_check("creator", false, "creator: CREATE tab exists")
		_check("creator", false, "creator: form has multi-choice categories + name + visual + logic")
		_check("creator", false, "creator: form produces a validated mod")
		return
	var form := tabs.get_tab_control(create_idx)
	var kinds: Dictionary = {}
	_count_kinds(form, kinds)
	var multi := int(kinds.get("option", 0)) + int(kinds.get("check", 0)) >= 2
	var has_name := int(kinds.get("lineedit", 0)) >= 1
	# Cinematic creator labels the visual section "APPEARANCE".
	var visual := _texts_contain(form, "visual") or _texts_contain(form, "color") or _texts_contain(form, "shape") or _texts_contain(form, "asset") or _texts_contain(form, "appearance")
	var logic := _texts_contain(form, "logic") or _texts_contain(form, "behavior") or _texts_contain(form, "behaviour") or _texts_contain(form, "effect")
	var has_textedits := int(kinds.get("textedit", 0)) >= 2
	_check("creator", multi and has_name and visual and logic and has_textedits,
		"creator: form has multi-choice categories + name + visual + logic (option=%s check=%s lineedit=%s textedit=%s visual=%s logic=%s)"
		% [str(kinds.get("option", 0)), str(kinds.get("check", 0)), str(kinds.get("lineedit", 0)), str(kinds.get("textedit", 0)), str(visual), str(logic)])
	# Form -> validated mod, via the REAL form path: the creator composes
	# a prompt from (categories, name, visual, logic), and the composed
	# output validates through ModLoader.validate_generated_mod (the gate
	# the generation pipeline feeds). Live LLM generation is never hit
	# (no network in tests).
	var cats: Array = []
	if creator_ui.has_method("get_selected_categories"):
		cats = creator_ui.call("get_selected_categories")
	if cats.is_empty():
		cats = ["Weapon"]
	var prompt: Variant = null
	if _creator_menu_script != null:
		prompt = _creator_menu_script.call("compose_prompt", cats, "Watermelon LMG",
			"a green watermelon with dark stripes and a red interior",
			"an LMG that shoots watermelons. The watermelons explode on impact.")
	var prompt_ok := prompt is String and str(prompt).contains("Watermelon LMG") and str(prompt).contains("watermelon") and str(prompt).contains("spawn_voxel_box") and str(prompt).contains("fire_effect")
	_check("creator", prompt_ok, "creator: form composes a prompt carrying name + visual + logic + the voxel/explosion technical notes")
	var payload := JSON.stringify({"block_id": "watermelon_lmg", "target": "weapon", "cost": 250, "display_name": "Watermelon LMG",
		"description": "An LMG that shoots watermelons.", "base_weapon_id": "lmg", "damage_mult": 1.0})
	var verr: Variant = _loader_script.call("validate_generated_mod",
		{"name": "Watermelon LMG", "kind": "block", "version": "1.0", "description": "An LMG that shoots watermelons."}, payload)
	_check("creator", str(verr) == "", "creator: form output validates via ModLoader.validate_generated_mod (err='%s')" % str(verr))
	_ui_voxel_cache(creator_ui)
	_ui_sandbox(creator_ui)
	_ui_watermelon_e2e()


func _ui_voxel_cache(_creator_ui: Control) -> void:
	# Voxel assets: VoxelAssetGenerator.get_or_generate(desc) — first
	# call generates (cache_hit false), repeat call reuses the cache
	# (cache_hit true). A unique probe description keeps the cache clean;
	# its cache file is removed afterwards.
	if _voxel_script == null:
		_check("creator", false, "creator: VoxelAssetGenerator loads")
		return
	var desc := "verify-probe watermelon cache check"
	var a1: Dictionary = _voxel_script.call("get_or_generate", desc)
	var a2: Dictionary = _voxel_script.call("get_or_generate", desc)
	var generated := int(a1.get("voxel_count", 0)) > 0 and not bool(a1.get("cache_hit", true))
	var reused := bool(a2.get("cache_hit", false)) and str(a2.get("cache_key", "")) == str(a1.get("cache_key", "")) and int(a2.get("voxel_count", 0)) == int(a1.get("voxel_count", 0))
	_check("creator", generated and reused,
		"creator: voxel asset generated + cached + reused on repeat description (first hit=%s n=%d, second hit=%s n=%d)"
		% [str(a1.get("cache_hit", "")), int(a1.get("voxel_count", 0)), str(a2.get("cache_hit", "")), int(a2.get("voxel_count", 0))])
	var node: Node = _voxel_script.call("build_node_for_asset", a1)
	_check("creator", node != null and is_instance_valid(node) and node is Node3D,
		"creator: cached voxel asset builds a live Node3D")
	if node != null and is_instance_valid(node):
		_free_node(node)
	# Cleanup: remove this probe's cache file (never leave probe state).
	var cpath: String = _voxel_script.call("cache_path_for", desc)
	var abs_path := OS.get_user_data_dir().path_join("mods").path_join("assets").path_join(cpath.get_file())
	DirAccess.remove_absolute(abs_path)


func _ui_sandbox(_creator_ui: Control) -> void:
	# Sandbox: SandboxTestRoom.simulate_test (pure simulation — never
	# executes the candidate) + the creator's TEST IN SANDBOX button.
	if _sandbox_script == null:
		_check("creator", false, "creator: SandboxTestRoom loads")
		return
	var before: Array = []
	for m in (_loader_script.call("get_mods") as Array):
		before.append(str((m as Dictionary).get("id", "")))
	var behavior := {"projectile": true, "explodes_on_impact": true}
	var asset := {"voxels": [], "voxel_count": 42, "cache_hit": false}
	var res: Dictionary = _sandbox_script.call("simulate_test", {"manifest": {}, "payload": ""}, asset, behavior)
	var sim_ok := bool(res.get("hit", false)) and bool(res.get("explosion_fired", false)) and is_equal_approx(float(res.get("explosion_radius", 0.0)), 4.0) and is_equal_approx(float(res.get("explosion_damage", 0.0)), 60.0)
	_check("creator", sim_ok, "creator: sandbox simulate_test fires a hit + explosion (got %s)" % str(res))
	_check("creator", res.get("wrote_to_mod_list") == false and res.get("wrote_to_progression") == false,
		"creator: sandbox simulation writes nothing (wrote_to_mod_list=%s wrote_to_progression=%s)" % [str(res.get("wrote_to_mod_list")), str(res.get("wrote_to_progression"))])
	var after: Array = []
	for m in (_loader_script.call("get_mods") as Array):
		after.append(str((m as Dictionary).get("id", "")))
	_check("creator", str(before) == str(after),
		"creator: sandbox test does not pollute the real mod list (before=%s after=%s)" % [str(before), str(after)])


func _ui_watermelon_e2e() -> void:
	# Watermelon-LMG end-to-end through the REAL creator path (no LLM,
	# no network): form values -> compose_prompt -> behavior_for ->
	# VoxelAssetGenerator (watermelon voxels) -> simulate_test must hit
	# and explode, and the sandbox must not pollute the mod list.
	if _creator_menu_script == null or _voxel_script == null or _sandbox_script == null:
		_check("creator", false, "creator: watermelon e2e scripts load")
		return
	var visual := "a green watermelon with dark stripes and a red interior"
	var logic := "an LMG that shoots watermelons. The watermelons explode on impact."
	var behavior: Dictionary = _creator_menu_script.call("behavior_for", ["Weapon"], logic, "")
	_check("creator", bool(behavior.get("projectile", false)) and bool(behavior.get("explodes_on_impact", false)),
		"creator: watermelon-LMG logic yields projectile + explodes_on_impact (got %s)" % str(behavior))
	var asset: Dictionary = _voxel_script.call("get_or_generate", visual)
	var asset_str := str(asset.get("voxels", []))
	var has_melon_colors := asset_str.contains("e83a4e") or asset_str.contains("58a83c")
	_check("creator", int(asset.get("voxel_count", 0)) > 0 and has_melon_colors,
		"creator: watermelon visual generates watermelon-colored voxels (n=%d colors=%s)" % [int(asset.get("voxel_count", 0)), str(has_melon_colors)])
	var before: Array = []
	for m in (_loader_script.call("get_mods") as Array):
		before.append(str((m as Dictionary).get("id", "")))
	var res: Dictionary = _sandbox_script.call("simulate_test", {"manifest": {}, "payload": ""}, asset, behavior)
	_check("creator", bool(res.get("hit", false)) and bool(res.get("explosion_fired", false)),
		"creator: watermelon-LMG sandbox test hits and explodes on impact (got %s)" % str(res))
	var after: Array = []
	for m in (_loader_script.call("get_mods") as Array):
		after.append(str((m as Dictionary).get("id", "")))
	_check("creator", str(before) == str(after),
		"creator: watermelon sandbox test does not pollute the real mod list")


# ------------------------------------------------------------------ voice
## The dedicated voice-confirm dialog: a visible Control whose name
## mentions voice/speech. Deliberately scoped — an unscoped search is a
## false positive: the Forge menu's history buttons carry the transcript
## text and its cost-preview carries a CONFIRM button, which together
## look like a voice prompt but are not one.
func _voice_dialog_node() -> Control:
	if _forge_menu == null:
		return null
	return _find_voice_dialog_in(_forge_menu)


func _find_voice_dialog_in(node: Node) -> Control:
	if node is Control and node != _forge_menu and (node as Control).visible:
		var n := node.name.to_lower()
		if n.contains("voice") or n.contains("speech"):
			return node as Control
	for c in node.get_children():
		var r := _find_voice_dialog_in(c)
		if r != null:
			return r
	return null


func _find_text_with(node: Node, substr: String) -> Node:
	if node is Label and (node as Label).text.to_lower().contains(substr.to_lower()):
		return node
	if node is LineEdit and (node as LineEdit).text.to_lower().contains(substr.to_lower()):
		return node
	if node is TextEdit and (node as TextEdit).text.to_lower().contains(substr.to_lower()):
		return node
	for c in node.get_children():
		var r := _find_text_with(c, substr)
		if r != null:
			return r
	return null


func _find_voice_button(names: Array) -> Button:
	var dialog := _voice_dialog_node()
	if dialog == null:
		return null
	for n in names:
		var b := _find_button_with(dialog, str(n))
		if b != null and b.is_visible_in_tree():
			return b
	return null


func _voice_dialog_visible(transcript: String) -> bool:
	var dialog := _voice_dialog_node()
	if dialog == null:
		return false
	var label := _find_text_with(dialog, transcript)
	var confirm := _find_voice_button(["confirm", "forge it", "yes", "build it"])
	return label != null and label.is_visible_in_tree() and confirm != null


func _voice_listening() -> bool:
	if _forge_menu == null:
		return false
	var speech: Variant = _forge_menu.get("_speech")
	if speech == null or not (speech is Object):
		return false
	return bool((speech as Object).get("_listening"))


## Voice v2 (Forge batch item 9): the confirm prompt lives in
## SpeechInput, and _on_voice_text is the POST-confirm callback — so
## the suite drives the REAL path (test_start_session +
## simulate_transcript, exactly like the plugin's onResult), never the
## callback directly. Calling _on_voice_text directly would bypass the
## confirm step by design, so it must not be used as the test entry.
func _voice_arm(transcript: String) -> void:
	var speech: Variant = _forge_menu.get("_speech")
	if speech == null or not (speech is Object):
		return
	(speech as Object).call("test_start_session", Callable(_forge_menu, "_on_voice_text"), false)
	(speech as Object).call("simulate_transcript", transcript)


func _voice_step() -> void:
	_vframes += 1
	match _vstep:
		0:
			if _vframes == 1:
				_voice_arm("build a wall in front of me")
				_check("voice-confirm", _voice_dialog_visible("build a wall in front of me"),
					"voice-confirm: recognized text shows in a confirm prompt before any Forge action")
				_vstep = 1
				_vframes = 0
		1:
			if _vframes >= 4:
				_check("voice-confirm", _voice_results == 0 and _group_count("forge_structure") == _voice_struct_before,
					"voice-confirm: no Forge action before confirm (forge_results=%d structures=%d, want 0 / %d)"
					% [_voice_results, _group_count("forge_structure"), _voice_struct_before])
				_reset_forge_cooldown()
				var confirm := _find_voice_button(["confirm", "forge it", "yes", "build it"])
				if confirm != null:
					confirm.emit_signal("pressed")
					_voice_confirm_found = true
				else:
					_check("voice-confirm", false, "voice-confirm: Confirm button exists in the voice prompt")
				_vstep = 2
				_vframes = 0
		2:
			if _vframes == 1:
				# Voice-Confirm delivered the prompt to the Forge menu,
				# which routes STRUCTURE prompts through the ghost
				# preview (item 2): the build fires only when the
				# player confirms the placement with the interact key.
				# Drive that real input path into the placement node.
				var placement := _arena.get_node_or_null("ForgePlacement") as Node
				if placement != null and bool(placement.call("has_preview")):
					var ev := InputEventAction.new()
					ev.action = "interact"
					ev.pressed = true
					placement.call("_input", ev)
			if _vframes >= 6:
				_check("voice-confirm", _voice_confirm_found and (_voice_results > 0 or _group_count("forge_structure") > _voice_struct_before),
					"voice-confirm: Confirm submits the recognized prompt (forge_results=%d structures=%d)"
					% [_voice_results, _group_count("forge_structure")])
				_check("voice-confirm", not _voice_listening(), "voice-confirm: no stuck listening state after Confirm")
				_voice_results = 0
				_voice_struct_before = _group_count("forge_structure")
				_voice_arm("build a tower")
				_check("voice-confirm", _voice_dialog_visible("build a tower"),
					"voice-confirm: second recognition shows its own confirm prompt")
				_vstep = 3
				_vframes = 0
		3:
			if _vframes >= 4:
				_check("voice-confirm", _voice_results == 0,
					"voice-confirm: no Forge action before confirm on round 2 (forge_results=%d)" % _voice_results)
				var retry := _find_voice_button(["retry", "listen again", "try again", "re-listen"])
				if retry != null:
					retry.emit_signal("pressed")
				else:
					_check("voice-confirm", false, "voice-confirm: Retry button exists in the voice prompt")
				_vstep = 4
				_vframes = 0
		4:
			if _vframes >= 4:
				_check("voice-confirm", _voice_results == 0,
					"voice-confirm: Retry re-listens without submitting (forge_results=%d)" % _voice_results)
				# Retry left the session LISTENING: the re-listen delivers
				# a fresh transcript, which waits in its own confirm prompt.
				_voice_arm_transcript_only("build a tower")
				_check("voice-confirm", _voice_dialog_visible("build a tower"),
					"voice-confirm: re-listen transcript shows its own confirm prompt")
				var cancel := _find_voice_button(["cancel", "dismiss", "no"])
				if cancel != null:
					cancel.emit_signal("pressed")
				else:
					_check("voice-confirm", false, "voice-confirm: Cancel button exists in the voice prompt")
				_vstep = 5
				_vframes = 0
		5:
			if _vframes >= 4:
				_check("voice-confirm", not _voice_dialog_visible("build a tower") and _voice_results == 0,
					"voice-confirm: Cancel dismisses the prompt with no Forge action (dialog=%s forge_results=%d)"
					% [str(_voice_dialog_visible("build a tower")), _voice_results])
				_check("voice-confirm", not _voice_listening(), "voice-confirm: no stuck listening state after Cancel")
				_finish()
				_phase = 99


## Deliver a transcript into an already-LISTENING session (the Retry
## path) without re-arming — test_start_session is a no-op when not
## IDLE, so the re-listen transcript must go through simulate alone.
func _voice_arm_transcript_only(transcript: String) -> void:
	var speech: Variant = _forge_menu.get("_speech")
	if speech == null or not (speech is Object):
		return
	(speech as Object).call("simulate_transcript", transcript)


func _finish() -> void:
	print("VERIFY_FORGE_BATCH: sections:")
	for section in ["budget-off", "aliases", "ghost-edit", "destructible", "mp-sync", "per-weapon-costs", "presets", "build-codes", "creator", "voice-confirm", "setup"]:
		var p := int(_sec_pass.get(section, 0))
		var f := int(_sec_fail.get(section, 0))
		if p + f > 0:
			print("  ", section, ": ", p, " PASS / ", f, " FAIL")
	if _timeout:
		printerr("VERIFY_FORGE_BATCH: TIMEOUT — phase machine did not finish")
	if _fails == 0:
		print("VERIFY_FORGE_BATCH: ALL CHECKS PASSED (%d)" % _passes)
	else:
		printerr("VERIFY_FORGE_BATCH: %d PASS / %d FAIL" % [_passes, _fails])
	quit(_fails)
