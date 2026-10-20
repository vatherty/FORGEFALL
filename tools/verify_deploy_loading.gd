# tools/verify_deploy_loading.gd — deploy loading screen + stall-fix verification.
# Usage: godot --headless --path <project> --script res://tools/verify_deploy_loading.gd
#
# Drives the REAL deploy flow for every map + mode: boots main.tscn fresh
# per case, calls the menu's deploy entries, pumps frames, and asserts:
#   - the loading screen appears with staged labels in the expected order
#   - deploy completes (state == PLAYING, player spawned)
#   - the loading screen dismisses itself afterwards
# Plus:
#   - warmup interplay: deploy mid-warmup cancels the warmup cleanly
#     (room + runner freed, no cross-world emitters, deploy completes)
#   - Phase-0 fix: pools build even when the warmup starts from inside a
#     node's _ready() (the busy-parent condition that used to fail the
#     add_child calls and leave the pools lazy)
#   - fault injection: hang_at_stage stalls at the named stage and the
#     screen's label identifies it (proves the diagnostic works)
#
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

const WebWarmupScript := preload("res://scripts/core/web_warmup.gd")
const BusyHolderScript := preload("res://tools/_busy_warmup_holder.gd")

const CASE_BUDGET := 1500  # frames to reach PLAYING per deploy case
const SETTLE_FRAMES := 90  # extra frames after PLAYING for screen teardown

var _passes := 0
var _fails := 0

var _cases: Array = []
var _case_idx := -1
var _phase := "next"  # next | booting | deploying | settling | phase0 | fault | done
var _main: Node = null
var _frames := 0
var _stages: Array = []
var _screen_seen := false
var _loading: Node = null
var _play_frame := -1
var _fault_set := false


func _pass(label: String) -> void:
	_passes += 1
	print("  PASS: " + label)


func _fail(label: String, detail: String) -> void:
	_fails += 1
	printerr("  FAIL: " + label + " — " + detail)


func _initialize() -> void:
	print("VERIFY_DEPLOY_LOADING: staged deploy + loading screen")
	_cases = [
		{"name": "deploy_dustline", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "deploy_foundry", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "deploy_factory", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "deploy_outpost", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "deploy_cinder_city", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "sp_tower_defense", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "sp_tdm", "stages": ["warmup", "map", "player", "systems", "mode"]},
		{"name": "sp_zombies", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "legacy_domination", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "legacy_endless", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "puzzle_chamber_01", "stages": ["warmup", "room", "player", "systems"]},
		{"name": "mp_tdm_host", "stages": ["warmup", "map", "player", "systems", "net", "match"]},
		{"name": "warmup_interplay", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
		{"name": "warmup_cancel", "stages": ["warmup", "map", "player", "systems", "waves", "mode"]},
	]


func _boot_main() -> void:
	var ps := load("res://scenes/main.tscn") as PackedScene
	_main = ps.instantiate()
	root.add_child(_main)
	current_scene = _main


func _start_case(idx: int) -> void:
	# NOTE: "booting" already booted the Main; this only starts the deploy.
	_frames = 0
	_stages = []
	_screen_seen = false
	_loading = null
	_play_frame = -1
	_fault_set = false
	# Isolation: GameModeManager.selected_mode is static and persists
	# across cases in one process. A stale "mp_tdm" from the MP case
	# would make the next SP deploy's mode stage refuse (real-game
	# menus never produce that combination; the refusal path itself is
	# correct). Reset; legacy/mp cases override below.
	(load("res://scripts/core/game_mode.gd") as GDScript).set("selected_mode", "")
	var cname: String = _cases[idx]["name"]
	match cname:
		"deploy_dustline":
			_main.set_selected_map("dustline")
			_main.start_game()
		"deploy_foundry":
			_main.set_selected_map("foundry")
			_main.start_game()
		"deploy_factory":
			_main.set_selected_map("factory")
			_main.start_game()
		"deploy_outpost":
			_main.set_selected_map("outpost")
			_main.start_game()
		"deploy_cinder_city":
			_main.set_selected_map("cinder_city")
			_main.start_game()
		"sp_tower_defense":
			_main.start_sp_mode("tower_defense")
		"sp_tdm":
			_main.start_sp_mode("tdm")
		"sp_zombies":
			_main.start_sp_mode("zombies")
		"legacy_domination":
			# NOTE: no bare GameModeManager reference here — a static
			# class_name touch at THIS script's compile time (before
			# autoloads exist in --script mode) poisons game_mode.gd
			# for the whole run. Runtime load() compiles it cleanly.
			(load("res://scripts/core/game_mode.gd") as GDScript).set("selected_mode", "domination")
			_freeze_mode_tick_on_add()
			_main.set_selected_map("dustline")
			_main.start_game()
		"legacy_endless":
			(load("res://scripts/core/game_mode.gd") as GDScript).set("selected_mode", "endless")
			_freeze_mode_tick_on_add()
			_main.set_selected_map("dustline")
			_main.start_game()
		"puzzle_chamber_01":
			_main.start_puzzle("chamber_01")
		"mp_tdm_host":
			_main.call("_on_mp_start", "dustline", "mp_tdm", true)
		"warmup_interplay":
			# Forced at frame 1 below (needs the tree settled first).
			pass


func _poll_loading() -> void:
	if _loading != null and is_instance_valid(_loading):
		return
	if _main == null or not is_instance_valid(_main):
		return
	var scr: Node = _main.get_node_or_null("MapLoadingScreen")
	if scr != null:
		_loading = scr
		_screen_seen = true
		# The first stage ("warmup") fires synchronously inside the
		# deploy entry call, before this poll ever sees the screen —
		# capture it from current_stage so the order check is complete.
		var cur := str(scr.get("current_stage"))
		if cur != "" and _stages.is_empty():
			_stages.append(cur)
		if not _loading.is_connected("stage_changed", _on_stage):
			_loading.connect("stage_changed", _on_stage)


func _on_stage(stage_id: String) -> void:
	_stages.append(stage_id)


## Legacy domination/endless tick EnemyBase.all every frame, which
## crashes this headless runner natively (pre-existing environmental
## limitation, verified — the real game is unaffected). The deploy
## (stages, player, mode start) is what this suite proves, so the mode
## node's processing is frozen the instant it enters the tree — before
## its first tick can run. Connected only for the legacy cases.
func _freeze_mode_tick_on_add() -> void:
	if _main != null and is_instance_valid(_main) \
			and not _main.is_connected("child_entered_tree", _on_main_child):
		_main.connect("child_entered_tree", _on_main_child)


## Forced warmup with the single-run static reset (each forced begin
## needs _started cleared; the real game only ever begins once).
func _force_warmup() -> Node:
	# Cast: on the const-preloaded script, .set() parses as a static
	# call (illegal); through a GDScript-typed ref it is dynamic.
	(WebWarmupScript as GDScript).set("_started", false)
	return WebWarmupScript.begin(_main, true)


func _on_main_child(node: Node) -> void:
	# NOTE: Node.get_class() returns the NATIVE class ("Node") here —
	# the script class name lives on the script resource (verified).
	if is_instance_valid(node) and node.get_script() != null \
			and str(node.get_script().get_global_name()) == "GameModeManager":
		node.process_mode = Node.PROCESS_MODE_DISABLED


func _finish_case() -> void:
	var cname: String = _cases[_case_idx]["name"]
	var expected: Array = _cases[_case_idx]["stages"]
	if not _screen_seen:
		_fail(cname + ": screen", "loading screen never appeared")
	elif _stages != expected:
		_fail(cname + ": stage order", "got %s, want %s" % [str(_stages), str(expected)])
	else:
		_pass(cname + ": stages in order (%d)" % _stages.size())
	var players := get_nodes_in_group("player").size()
	if players < 1:
		_fail(cname + ": player", "no player spawned")
	else:
		_pass(cname + ": player spawned")
	if _main != null and is_instance_valid(_main) \
			and _main.get_node_or_null("MapLoadingScreen") != null:
		_fail(cname + ": teardown", "loading screen still present after Ready")
	else:
		_pass(cname + ": screen dismissed")
	if cname == "warmup_interplay" or cname == "warmup_cancel":
		if root.get_node_or_null("WarmupRoom") != null:
			_fail(cname + ": room", "WarmupRoom still alive after deploy")
		else:
			_pass(cname + ": warmup room freed")
		if _main != null and is_instance_valid(_main) \
				and _main.get_node_or_null("WebWarmup") != null:
			_fail(cname + ": runner", "WebWarmup still alive after deploy")
		else:
			_pass(cname + ": warmup runner gone")
	# Tear the run down before the next case (deferred frees flush).
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
	_main = null
	_loading = null


func _process(_delta: float) -> bool:
	match _phase:
		"next":
			_case_idx += 1
			if _case_idx >= _cases.size():
				_phase = "phase0"
				_frames = 0
				return false
			_phase = "booting"
			_frames = 0
			return false
		"booting":
			# One frame for the menu to settle, then start the case.
			_frames += 1
			if _frames == 1:
				_boot_main()
			elif _frames == 3:
				_start_case(_case_idx)
				_phase = "deploying"
				_frames = 0
			return false
		"deploying":
			_frames += 1
			_poll_loading()
			var cname: String = _cases[_case_idx]["name"]
			if cname == "warmup_interplay":
				if _frames == 1:
					# Wire it into Main._warmup so the deploy's real
					# _settle_warmup() path runs (headless has no web
					# feature, so Main never starts it itself).
					_main.set("_warmup", _force_warmup())
				elif _frames == 4:
					_main.start_game()
			elif cname == "warmup_cancel":
				if _frames == 1:
					_main.set("_warmup", _force_warmup())
				elif _frames == 5:
					# Cancel mid-run: the room exists now and must be
					# gone right after; the deploy then starts clean.
					var w = _main.get("_warmup")
					if w != null and is_instance_valid(w):
						w.call("cancel")
				elif _frames == 8:
					_main.start_game()
			if _main != null and is_instance_valid(_main) and int(_main.get("state")) == 1:
				_play_frame = _frames
				_phase = "settling"
				_frames = 0
				return false
			if _frames >= CASE_BUDGET:
				_fail(_cases[_case_idx]["name"] + ": deploy",
					"state != PLAYING after %d frames (state=%s, stages=%s)" % [
						CASE_BUDGET, str(_main.get("state")) if _main != null else "?",
						str(_stages)])
				_finish_case()
				_phase = "next"
			return false
		"settling":
			_frames += 1
			_poll_loading()
			if _frames >= SETTLE_FRAMES:
				_finish_case()
				_phase = "next"
			return false
		"phase0":
			# Busy-parent repro: a node that starts the warmup from inside
			# its OWN _ready(). Before the Phase-0 fix the pools'
			# add_child() calls failed here and the pools stayed lazy.
			_frames += 1
			if _frames == 1:
				(WebWarmupScript as GDScript).set("_started", false)
				var holder: Node = BusyHolderScript.new()
				holder.name = "BusyWarmupHolder"
				root.add_child(holder)  # _ready fires now, warmup begins
			if _frames >= 120:
				var w: Node = root.get_node_or_null("BusyWarmupHolder")
				var runner: Node = w.get("warmup") if w != null else null
				if runner == null or not (runner as Node).call("is_done"):
					_fail("phase0: warmup", "busy-parent warmup did not finish")
				else:
					_pass("phase0: busy-parent warmup finished")
					if ImpactFX._root == null:
						_fail("phase0: impactfx", "ImpactFX pool missing (Phase-0 add failed)")
					else:
						_pass("phase0: ImpactFX pool built")
					if DebrisPool._holder == null or DebrisPool._pool.is_empty():
						_fail("phase0: debris", "DebrisPool missing/empty (Phase-0 add failed)")
					else:
						_pass("phase0: DebrisPool built (%d)" % DebrisPool._pool.size())
					if TracerPool._inst == null:
						_fail("phase0: tracer", "TracerPool missing (Phase-0 add failed)")
					else:
						_pass("phase0: TracerPool built")
				_phase = "fault"
				_frames = 0
			return false
		"fault":
			# Fault injection: stall the waves stage; the screen must
			# name it.
			_frames += 1
			if _frames == 1:
				_boot_main()
			elif _frames == 3:
				_main.start_game()
			elif _frames >= 6:
				_poll_loading()
				if _loading != null and is_instance_valid(_loading) and not _fault_set:
					_loading.set("hang_at_stage", "waves")
					_fault_set = true
			if _frames >= 200:
				var label := ""
				var stage := ""
				if _loading != null and is_instance_valid(_loading):
					label = str(_loading.call("current_label"))
					stage = str(_loading.get("current_stage"))
				var st := -1
				if _main != null and is_instance_valid(_main):
					st = int(_main.get("state"))
				if st == 1:
					_fail("fault: stall", "deploy completed despite injected hang")
				elif stage != "waves":
					_fail("fault: stage", "current_stage=%s, want 'waves'" % stage)
				elif not ("Spawning enemies" in label):
					_fail("fault: label", "label=%s, want the waves label" % label)
				else:
					_pass("fault: stuck stage identified on screen ('%s')" % label)
				_phase = "done"
			return false
		"done":
			print("VERIFY_DEPLOY_LOADING: %d passed, %d failed" % [_passes, _fails])
			quit(1 if _fails > 0 else 0)
			return true
	return false
