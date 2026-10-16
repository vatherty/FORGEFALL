# FORGEFALL — ForgeSessionWatcher (v0.5.9, MAKE parity, Worker E)
# Enemy-touch dispatch for session hooks on MAKE'd structures.
#
# A MAKE'd structure (cover / structure / turret / pickup) carrying
# session hooks gets one of these as a child (see ForgeSessionMake).
# Every physics tick it polls enemies (groups "enemy" / "enemies", the
# same groups ForgeEnemyPressure uses) and, when an enemy ENTERS the
# structure's touch radius, dispatches the session hooks at hook point
# "on_hit" through ModHookRegistry.run_hooks — the SAME registry call,
# SAME allowlist validator (hooks were validated by
# ForgeSessionMake._validate_session_hooks before attach), and SAME
# step/time budget as installed mods' hooks.
#
# MAPPING (documented, not silent): "enemy touches the structure" IS a
# hit on the structure, so touch dispatches at "on_hit" with ctx
# {position, hit_position, damage: 0, target: the enemy, headshot:
# false, weapon_id: "session_make"}. Only on_hit hooks are ever
# attached to a structure (ForgeSessionMake splits them out and names
# any skipped hook in the MAKE result message), so every attached hook
# can fire here. Data hooks run interpreted (explosion / status /
# ...); code hooks run their run(api, ctx) under the registry budget.
#
# FIRING SEMANTICS: one dispatch per enemy per touch-enter (an enemy
# that stays inside does NOT re-trigger; it must leave past the exit
# hysteresis and re-enter). A wall that explodes when touched explodes
# once per enemy that touches it — it does not machine-gun explosions
# while one enemy leans on it.
#
# BUDGET / VISIBILITY: if a dispatch exceeds the step/time budget,
# run_hooks reports budget_exceeded; the watcher DISABLES itself
# visibly (session_hook_error meta on the parent + a HUD announce),
# never silently, never crashing. The structure itself keeps standing.
#
# SCOPE: session-only. The watcher is a child of the built node, so
# undo / fracture / TTL freeing the node frees the watcher too.
# Session hooks run ONLY on the maker's machine: peers receive the
# plain structure via NetForgeSync (geometry sync, same as preset
# builds) and never auto-run another peer's code.
extends Node
class_name ForgeSessionWatcher

## Extra reach past the structure's half-extent (enemy body radius).
const TOUCH_MARGIN := 1.0
## Exit hysteresis: an enemy must get this far past the touch radius
## before it counts as having left (no boundary jitter re-trigger).
const EXIT_HYSTERESIS := 0.5
## Vertical slack: an enemy whose feet are within this of the
## structure's base height counts as touching.
const HEIGHT_SLACK := 1.5

## Validated session hooks (on_hit only). Set by setup().
var session_hooks: Array = []
var session_make_id := ""
## Total touch dispatches this watcher has run (test seam).
var dispatch_count := 0
## "" while healthy; the disable reason once budget-disabled.
var last_error := ""
var disabled := false

## instance_id -> true for enemies currently inside the touch radius.
var _touching: Dictionary = {}


func setup(hooks: Array, make_id: String) -> void:
	session_hooks = hooks.duplicate()
	session_make_id = make_id


func _physics_process(_delta: float) -> void:
	check_now()


## One poll pass (also the test seam: call directly to simulate a tick).
func check_now() -> void:
	if disabled:
		return
	if session_hooks.is_empty():
		return
	var parent := get_parent()
	if parent == null or not is_instance_valid(parent):
		return
	if not (parent is Node3D):
		return
	if parent.get("_destroyed") == true or parent.get("_dead") == true or parent.get("_broken") == true:
		return
	var tree := get_tree()
	if tree == null:
		return
	var center := (parent as Node3D).global_position
	var radius := _touch_radius(parent)
	var height := _height(parent)
	var seen: Dictionary = {}
	for group in ["enemy", "enemies"]:
		for e in tree.get_nodes_in_group(group):
			if e == null or not is_instance_valid(e):
				continue
			if not (e is Node3D):
				continue
			var foe := e as Node3D
			if foe.get("dead") == true:
				continue
			# Pooled / inactive enemies never attack (same rule as
			# ForgeEnemyPressure); nodes without an `active` var pass.
			if foe.get("active") == false:
				continue
			var id := foe.get_instance_id()
			seen[id] = true
			var dist := Vector2(foe.global_position.x - center.x, foe.global_position.z - center.z).length()
			var dy := absf(foe.global_position.y - center.y)
			if dist <= radius and dy <= height + HEIGHT_SLACK:
				if not _touching.has(id):
					_touching[id] = true
					_dispatch(foe)
			elif dist > radius + EXIT_HYSTERESIS:
				_touching.erase(id)
	# Enemies freed since the last pass leave the touching set.
	for id in _touching.keys():
		if not seen.has(id):
			_touching.erase(id)


## Runs the attached hooks at "on_hit" for one touching enemy.
func _dispatch(foe: Node3D) -> void:
	var parent := get_parent()
	if parent == null or not is_instance_valid(parent) or not (parent is Node3D):
		return
	var api := _make_api()
	var ctx := {
		"position": (parent as Node3D).global_position,
		"hit_position": foe.global_position,
		"damage": 0.0,
		"target": foe,
		"headshot": false,
		"weapon_id": "session_make",
	}
	dispatch_count += 1
	var result := ModHookRegistry.run_hooks(session_hooks, "on_hit", api, ctx)
	if bool(result.get("budget_exceeded", false)):
		_disable("session hook exceeded the step/time budget — hooks disabled")


## Visible disable: HUD announce + error meta on the parent. The
## structure keeps standing; only its hooks stop running.
func _disable(reason: String) -> void:
	if disabled:
		return
	disabled = true
	last_error = reason
	var parent := get_parent()
	if parent != null and is_instance_valid(parent):
		parent.set_meta("session_hook_error", reason)
		parent.set_meta("session_hooks_disabled", true)
	_make_api().announce("MAKE hook disabled", reason)


func _make_api() -> ModAPI:
	var tree := get_tree()
	var player: Node3D = null
	var root: Node = null
	if tree != null:
		var players := tree.get_nodes_in_group("player")
		if not players.is_empty():
			player = players[0] as Node3D
		root = tree.current_scene
		if root == null:
			root = tree.root
	return ModAPI.new(player, root)


## Touch radius from the parent's shape: structure bounds, cover
## voxels, else a turret-sized fallback.
func _touch_radius(node: Node) -> float:
	if node.get("bounds_size") != null:
		var b: Vector3 = node.get("bounds_size")
		return maxf(b.x, b.z) * 0.5 + TOUCH_MARGIN
	if node.get("vox_size") != null:
		var vs: Vector3i = node.get("vox_size")
		var pitch := 0.25
		if node.get("pitch") != null:
			pitch = float(node.get("pitch"))
		return maxf(float(vs.x), float(vs.z)) * pitch * 0.5 + TOUCH_MARGIN
	return 1.5 + TOUCH_MARGIN


func _height(node: Node) -> float:
	if node.get("bounds_size") != null:
		return float((node.get("bounds_size") as Vector3).y)
	if node.get("vox_size") != null:
		var vs: Vector3i = node.get("vox_size")
		var pitch := 0.25
		if node.get("pitch") != null:
			pitch = float(node.get("pitch"))
		return float(vs.y) * pitch
	return 2.0
