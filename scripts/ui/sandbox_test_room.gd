# FORGEFALL — SandboxTestRoom (Forge batch, Worker D: Mod Creator redesign)
# A small test room for trying a GENERATED mod BEFORE it touches the real
# game. Flat voxel room, two target dummies, the candidate's voxel visual
# as the projectile. FIRE TEST SHOT animates the projectile at dummy 0;
# on impact the room shows an explosion flash, the dummy topples, and the
# result label reports HIT / explosion. CLOSE returns to the approval
# screen; Install stays on the approval screen, never in here.
#
# SAFETY: the sandbox NEVER writes to the real mod list, player
# progression, or user://mods/ — it only builds throwaway nodes inside
# its own SubViewport (UI path) or under a caller-owned root (build_room).
# It NEVER executes the candidate's ModBlock script (apply()): the test
# simulates the candidate's DECLARED behaviour (projectile visual +
# explosion on impact, derived from the form + payload by the creator
# menu) with the local asset. It DOES execute the candidate's HOOK
# SCRIPTS (code hooks only): they passed the same validation + compile
# as install-time (allowlist, extends ModHook, run() present), they run
# through ModHookRegistry in the throwaway room, and a hook that fails
# there (invalid, won't compile, blows the run budget) disables the
# candidate visibly instead of crashing. A hook that errors at RUN time
# reports no effect here — in-game that error would disable its
# installed mod. An unapproved ModBlock is never run as code.
#
# Two paths, one math: simulate_test() is the pure-logic simulation
# (headless-testable, no nodes); the UI animation replays the same
# constants (SHOOTER_POS / DUMMY0_POS / speed / HIT_DIST) visually.
# simulate_test() takes an optional `live` dict (ModAPI + hit ctx) —
# with it, code hooks run for real; without it, they are only listed.
extends Control
class_name SandboxTestRoom

signal sandbox_closed(result: Dictionary)

const SHOOTER_POS := Vector3(0, 1.2, 8.0)
const DUMMY0_POS := Vector3(0, 1.0, 0.0)
const DUMMY1_POS := Vector3(2.5, 1.0, -1.5)
const PROJECTILE_SPEED := 6.0
const STEP_DT := 0.05
const HIT_DIST := 0.7
const DUMMY_BASE_SPEED := 4.0  # v0.5.5: sandbox dummy's base speed (grunt-like), for status-effect readouts.
const EXPLOSION_RADIUS := 4.0
const EXPLOSION_DAMAGE := 60.0
const MAX_STEPS := 200

## Minimal sandbox player: an HP pool + heal() so heal hooks change
## something real in the throwaway room. Not a game player.
class SandboxPlayer extends Node3D:
	var _hp := 100.0

	func heal(amount: float) -> void:
		_hp = minf(_hp + amount, 100.0)

var _candidate: Dictionary = {}
var _asset: Dictionary = {}
var _behavior: Dictionary = {}
var _viewport: SubViewport
var _room_root: Node3D
var _dummies: Array = []
var _projectile: Node3D
var _weapon_visual: Node3D
var _candidate_label: Label
var _result_label: Label
var _fire_button: Button
var _animating := false
var _projectile_pos := Vector3.ZERO
var _target_pos := Vector3.ZERO
var _result: Dictionary = {}
var _flash: MeshInstance3D
# v0.5.3: visual flight speed, from the behavior's projectile_spec
# (the hook's speed) — the UI animation replays the same speed the
# pure-logic simulation uses.
var _anim_speed := PROJECTILE_SPEED


## Pure-logic simulation: no nodes, no scene tree, no writes.
## behavior: {"projectile": bool, "explodes_on_impact": bool,
##  "projectile_spec": Dictionary (a ModHook projectile dict),
##  "hooks": Array (ModHook dicts), "heal_on_kill": float}.
## v0.5.3: invented hooks are EXERCISED here, not just declared — the
## projectile flies at the hook's speed with the hook's explosion, an
## on_hit explosion hook detonates on impact, and an on_kill heal hook
## heals (the sandbox dummy dies on any hit, so a hit is a kill).
## v0.5.5: STATUS EFFECTS are exercised too — on_hit slow / freeze /
## burn / knockback hooks are parsed and reported (the dummy has a
## 4.0 m/s base speed, so a slow visibly drops its speed readout).
## v0.5.6: HOOK SCRIPTS run here too when `live` carries a ModAPI + hit
## ctx ({"api": ModAPI, "ctx": Dictionary}): code hooks at the fire
## points run at shot time, code hooks at on_hit / on_kill run on the
## hit, through ModHookRegistry (the same path as in-game). Reports land
## in "hook_script_reports" ("hook script ran: <id> — status applied
## (<description>)") and ran ids in "hook_scripts_run". A code hook that
## is invalid, fails to compile, or blows the run budget sets
## "hook_error" + "candidate_disabled" (Install goes dead in the menu).
## A hook that errors at RUN time prints an engine error and reports
## nothing (GDScript has no try/catch) — the sandbox never crashes on a
## hook; in-game that error would disable its installed mod. Without
## `live`, code hooks are only listed (never run): "hook_scripts_run"
## stays empty.
## Returns {"placed": bool, "hit": bool, "explosion_fired": bool,
##  "projectile_voxels": int, "steps": int, "dummy_hit": int,
##  "explosion_radius": float, "explosion_damage": float,
##  "heal_on_kill": float, "healed": bool, "hooks_run": Array[String],
##  "projectile_speed": float, "projectile_damage": float,
##  "status_effects": Array[Dictionary] (each {kind, factor,
##  duration_sec, damage_per_sec, force}),
##  "dummy_speed_before": float, "dummy_speed_after": float,
##  "hook_scripts_run": Array[String], "hook_script_reports": Array[String],
##  "hook_error": String, "candidate_disabled": bool,
##  "wrote_to_mod_list": false, "wrote_to_progression": false}.
static func simulate_test(_candidate: Dictionary, asset: Dictionary, behavior: Dictionary, live: Dictionary = {}) -> Dictionary:
	var voxels := int((asset as Dictionary).get("voxel_count", 0))
	var empty_scripts := {"hook_scripts_run": [], "hook_script_reports": [],
		"hook_error": "", "candidate_disabled": false}
	if not bool(behavior.get("projectile", true)):
		var placed := {"placed": true, "hit": false, "explosion_fired": false,
			"projectile_voxels": voxels, "steps": 0, "dummy_hit": -1,
			"explosion_radius": 0.0, "explosion_damage": 0.0,
			"heal_on_kill": 0.0, "healed": false, "hooks_run": [],
			"projectile_speed": 0.0, "projectile_damage": 0.0,
			"status_effects": [], "dummy_speed_before": DUMMY_BASE_SPEED,
			"dummy_speed_after": DUMMY_BASE_SPEED,
			"wrote_to_mod_list": false, "wrote_to_progression": false}
		placed.merge(empty_scripts)
		return placed
	var spec: Dictionary = {}
	if behavior.get("projectile_spec") is Dictionary:
		spec = behavior.get("projectile_spec", {}) as Dictionary
	var speed := PROJECTILE_SPEED
	if spec.has("speed") and (spec["speed"] is int or spec["speed"] is float):
		speed = clampf(float(spec["speed"]), 1.0, 200.0)
	var hooks: Array = []
	if behavior.get("hooks") is Array:
		hooks = behavior.get("hooks", []) as Array
	var heal_on_kill := 0.0
	if behavior.has("heal_on_kill") and (behavior["heal_on_kill"] is int or behavior["heal_on_kill"] is float):
		heal_on_kill = float(behavior["heal_on_kill"])
	var hooks_run: Array = []
	for h in hooks:
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		if str(d.get("hook_point", "")) in ["on_fire", "projectile_spawn"] and d.has("projectile"):
			hooks_run.append(str(d.get("hook_id", "")))
	# v0.5.6: fire-point HOOK SCRIPTS run at shot time when the caller
	# supplied a live ModAPI (the sandbox UI path does).
	var live_api: ModAPI = null
	var live_ctx: Dictionary = {}
	if live.get("api") is ModAPI:
		live_api = live.get("api") as ModAPI
		if live.get("ctx") is Dictionary:
			live_ctx = live.get("ctx", {}) as Dictionary
	var hook_scripts_run: Array = []
	var hook_script_reports: Array = []
	var hook_error := ""
	var candidate_disabled := false
	if live_api != null:
		var fire_ctx := {"weapon_id": "sandbox", "position": SHOOTER_POS,
			"direction": (DUMMY0_POS - SHOOTER_POS).normalized()}
		for point in ["on_fire", "projectile_spawn"]:
			var fres := run_hook_scripts(hooks, point, live_api, fire_ctx)
			hook_scripts_run.append_array(fres.get("ran", []))
			hook_script_reports.append_array(fres.get("reports", []))
			if str(fres.get("hook_error", "")) != "" and hook_error.is_empty():
				hook_error = str(fres.get("hook_error", ""))
				candidate_disabled = true
	var pos := SHOOTER_POS
	var steps := 0
	var hit := false
	while steps < MAX_STEPS:
		steps += 1
		pos = pos.move_toward(DUMMY0_POS, speed * STEP_DT)
		if pos.distance_to(DUMMY0_POS) <= HIT_DIST:
			hit = true
			break
	# On hit: on_hit explosion hooks detonate; on_kill hooks run (the
	# dummy dies on any hit) — a heal effect heals. v0.5.5: on_hit
	# STATUS effects are parsed + reported (the dummy's 4.0 m/s base
	# speed drops by the slow factor; freeze drops it to 0).
	var hit_explodes := false
	var hit_radius := EXPLOSION_RADIUS
	var hit_damage := EXPLOSION_DAMAGE
	var status_effects: Array = []
	if hit:
		for h in hooks:
			if not (h is Dictionary):
				continue
			var d := h as Dictionary
			if str(d.get("hook_point", "")) == "on_hit":
				for eff in (d.get("effects", []) as Array):
					if not (eff is Dictionary):
						continue
					var ek := str((eff as Dictionary).get("kind", ""))
					if ek == "explosion":
						hit_explodes = true
						hit_radius = float((eff as Dictionary).get("radius", EXPLOSION_RADIUS))
						hit_damage = float((eff as Dictionary).get("damage", EXPLOSION_DAMAGE))
					elif ek in ["slow", "freeze", "burn", "knockback"]:
						status_effects.append({
							"kind": ek,
							"factor": float((eff as Dictionary).get("factor", 1.0)),
							"duration_sec": float((eff as Dictionary).get("duration_sec", 0.0)),
							"damage_per_sec": float((eff as Dictionary).get("damage_per_sec", 0.0)),
							"force": float((eff as Dictionary).get("force", 0.0)),
						})
				if not hooks_run.has(str(d.get("hook_id", ""))):
					hooks_run.append(str(d.get("hook_id", "")))
			if str(d.get("hook_point", "")) == "on_kill":
				for eff in (d.get("effects", []) as Array):
					if eff is Dictionary and str((eff as Dictionary).get("kind", "")) == "heal":
						heal_on_kill = maxf(heal_on_kill, float((eff as Dictionary).get("amount", 0.0)))
				if not hooks_run.has(str(d.get("hook_id", ""))):
					hooks_run.append(str(d.get("hook_id", "")))
		# v0.5.6: on_hit / on_kill HOOK SCRIPTS run for real on the hit.
		if live_api != null:
			var hit_ctx := live_ctx if not live_ctx.is_empty() else {
				"position": DUMMY0_POS, "hit_position": DUMMY0_POS,
				"damage": 0.0, "target": null,
				"headshot": false, "weapon_id": "sandbox"}
			for point in ["on_hit", "on_kill"]:
				var hres := run_hook_scripts(hooks, point, live_api, hit_ctx)
				hook_scripts_run.append_array(hres.get("ran", []))
				hook_script_reports.append_array(hres.get("reports", []))
				if str(hres.get("hook_error", "")) != "" and hook_error.is_empty():
					hook_error = str(hres.get("hook_error", ""))
					candidate_disabled = true
	var spec_explodes := bool(spec.get("explodes_on_impact", false))
	var explodes := bool(behavior.get("explodes_on_impact", false)) or spec_explodes or hit_explodes
	var radius := EXPLOSION_RADIUS
	var edamage := EXPLOSION_DAMAGE
	if spec_explodes:
		radius = float(spec.get("explosion_radius", EXPLOSION_RADIUS))
		edamage = float(spec.get("explosion_damage", EXPLOSION_DAMAGE))
	elif hit_explodes:
		radius = hit_radius
		edamage = hit_damage
	var proj_damage := 0.0
	if spec.has("damage") and (spec["damage"] is int or spec["damage"] is float) and float(spec["damage"]) >= 0.0:
		proj_damage = float(spec["damage"])
	var dummy_speed_after := DUMMY_BASE_SPEED
	for st in status_effects:
		if str((st as Dictionary).get("kind", "")) in ["slow", "freeze"]:
			dummy_speed_after = minf(dummy_speed_after, DUMMY_BASE_SPEED * float((st as Dictionary).get("factor", 1.0)))
	return {"placed": false, "hit": hit,
		"explosion_fired": hit and explodes,
		"projectile_voxels": voxels, "steps": steps,
		"dummy_hit": 0 if hit else -1,
		"explosion_radius": radius if (hit and explodes) else 0.0,
		"explosion_damage": edamage if (hit and explodes) else 0.0,
		"heal_on_kill": heal_on_kill if hit else 0.0,
		"healed": hit and heal_on_kill > 0.0,
		"hooks_run": hooks_run,
		"projectile_speed": speed,
		"projectile_damage": proj_damage,
		"status_effects": status_effects if hit else [],
		"dummy_speed_before": DUMMY_BASE_SPEED,
		"dummy_speed_after": dummy_speed_after if hit else DUMMY_BASE_SPEED,
		"hook_scripts_run": hook_scripts_run,
		"hook_script_reports": hook_script_reports,
		"hook_error": hook_error,
		"candidate_disabled": candidate_disabled,
		"wrote_to_mod_list": false, "wrote_to_progression": false}


## Runs the CODE hooks in `hooks` at `point` through the registry with
## `api` + `ctx` (the same path as in-game). Returns {"ran":
## Array[String] of hook_ids executed, "reports": Array[String]
## human-readable lines, "hook_error": String ("" = none),
## "candidate_disabled": bool}. An invalid hook (preview error), a hook
## that fails to compile, or a hook that blows the run budget DISABLES
## the candidate with a visible error and stops further code hooks. A
## hook that errors at RUN time cannot be caught (GDScript has no
## try/catch): the engine prints the error, the registry yields no
## result, and the report says "no effect reported" — the sandbox never
## crashes. (Sandbox hooks carry no "_mod_id", so a runtime error here
## never writes to ModLoader — unlike in-game, where it disables the
## installed mod.)
static func run_hook_scripts(hooks: Array, point: String, api: ModAPI, ctx: Dictionary) -> Dictionary:
	var ran: Array = []
	var reports: Array = []
	var hook_error := ""
	var disabled := false
	for h in hooks:
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		if str(d.get("hook_point", "")) != point:
			continue
		if not d.has("code"):
			continue
		var hid := str(d.get("hook_id", "?"))
		var desc := str(d.get("description", "")).strip_edges()
		var suffix := (" (" + desc + ")") if not desc.is_empty() else ""
		var perr := str(d.get("error", ""))
		if perr != "":
			hook_error = "hook script '%s' is invalid: %s" % [hid, perr]
			disabled = true
			break
		var inst: ModHook = null
		if d.has("_instance") and d["_instance"] is ModHook:
			inst = d["_instance"] as ModHook
		else:
			var compiled := ModHook.compile_hook_code(str(d.get("code", "")))
			if str(compiled.get("error", "")) != "":
				hook_error = "hook script '%s' failed to compile in the sandbox: %s" % [hid, str(compiled.get("error", ""))]
				disabled = true
				break
			inst = compiled.get("instance") as ModHook
		var single := d.duplicate(true)
		single["_instance"] = inst
		var res: Variant = ModHookRegistry.run_hooks([single], point, api, ctx)
		ran.append(hid)
		if res is Dictionary and bool((res as Dictionary).get("budget_exceeded", false)):
			reports.append("hook script ran: " + hid + " — budget exceeded (over 200 ModAPI calls / 100 ms; it would disable the mod in-game)" + suffix)
			hook_error = "hook script '%s' exceeded the run budget (200 ModAPI calls / 100 ms)" % hid
			disabled = true
			break
		reports.append(_describe_hook_script_result(hid, str(d.get("description", "")), res))
	return {"ran": ran, "reports": reports, "hook_error": hook_error, "candidate_disabled": disabled}


## One human-readable line for an executed hook script, in the same
## voice as the effect-kind reports: "hook script ran: <id> — status
## applied (<description>)". A hook whose run() yielded nothing reports
## "no effect reported".
static func _describe_hook_script_result(hook_id: String, description: String, res: Variant) -> String:
	var base := "hook script ran: " + hook_id
	var desc := description.strip_edges()
	var suffix := (" (" + desc + ")") if not desc.is_empty() else ""
	if not (res is Dictionary):
		return base + " — no effect reported" + suffix
	var parts: Array[String] = []
	var r := res as Dictionary
	if bool(r.get("status_applied", false)):
		parts.append("status applied")
	if float(r.get("healed", 0.0)) > 0.0:
		parts.append("healed +%.0f HP" % float(r.get("healed", 0.0)))
	if not is_equal_approx(float(r.get("damage_mult", 1.0)), 1.0):
		parts.append("damage x%.2f" % float(r.get("damage_mult", 1.0)))
	if bool(r.get("exploded", false)):
		parts.append("explosion fired")
	if bool(r.get("announced", false)):
		parts.append("banner shown")
	if parts.is_empty():
		return base + " — no effect reported" + suffix
	return base + " — " + ", ".join(parts) + suffix


## Builds the flat voxel room under `root` (caller-owned): floor, back +
## side walls, two dummies. Returns {"dummies": Array[Node3D],
## "spawn_point": Vector3}. The caller owns + frees everything.
static func build_room(root: Node3D) -> Dictionary:
	var floor_mat := VoxelBuilder.mat(Color("5a5e60"))
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = BoxMesh.new()
	(floor_mi.mesh as BoxMesh).size = Vector3(16, 0.25, 16)
	floor_mi.material_override = floor_mat
	floor_mi.position = Vector3(0, -0.125, 0)
	root.add_child(floor_mi)
	for wall in [[Vector3(16, 3, 0.5), Vector3(0, 1.5, -6.0)],
			[Vector3(0.5, 3, 12), Vector3(-8, 1.5, 0)],
			[Vector3(0.5, 3, 12), Vector3(8, 1.5, 0)]]:
		var w := MeshInstance3D.new()
		w.mesh = BoxMesh.new()
		(w.mesh as BoxMesh).size = wall[0]
		w.material_override = VoxelBuilder.mat(Color("3a3f44"))
		w.position = wall[1]
		root.add_child(w)
	var dummies: Array = []
	dummies.append(_build_dummy(root, DUMMY0_POS, Color("c2a878")))
	dummies.append(_build_dummy(root, DUMMY1_POS, Color("8a4b2a")))
	return {"dummies": dummies, "spawn_point": SHOOTER_POS}


static func _build_dummy(root: Node3D, at: Vector3, shirt: Color) -> Node3D:
	# CharacterBody3D (not plain Node3D) so knockback — the pull-hook
	# mechanism — applies to sandbox dummies exactly as to in-game
	# enemies. The dummy never moves: nothing calls move_and_slide.
	var dummy := CharacterBody3D.new()
	dummy.name = "SandboxDummy"
	dummy.position = at
	dummy.add_child(VoxelBuilder.cube(Vector3(0.6, 1.0, 0.4), shirt, Vector3(0, 0.5, 0)))
	dummy.add_child(VoxelBuilder.cube(Vector3(0.35, 0.35, 0.35), Color("d9a066"), Vector3(0, 1.2, 0)))
	root.add_child(dummy)
	return dummy


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.7)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var panel := PanelContainer.new()
	panel.name = "SandboxPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -420
	panel.offset_right = 420
	panel.offset_top = -320
	panel.offset_bottom = 320
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	add_child(panel)
	var vb := VBoxContainer.new()
	vb.name = "SandboxStack"
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)
	var head := Label.new()
	StencilStyle.apply_title(head, 26, StencilStyle.ORANGE, 4)
	head.text = "SANDBOX TEST"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(head)
	_candidate_label = Label.new()
	_candidate_label.name = "SandboxCandidate"
	_candidate_label.text = ""
	_candidate_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_candidate_label, 18, StencilStyle.TEXT, 2)
	_candidate_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_candidate_label)
	var hint := Label.new()
	hint.name = "SandboxHint"
	hint.text = "Flat test room — nothing here touches your real mods or progression."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(hint, 17, StencilStyle.TEXT_DIM, 2)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)
	var vpc := SubViewportContainer.new()
	vpc.name = "SandboxViewportContainer"
	vpc.custom_minimum_size = Vector2(780, 380)
	vpc.stretch = true
	vb.add_child(vpc)
	_viewport = SubViewport.new()
	_viewport.name = "SandboxViewport"
	_viewport.size = Vector2i(780, 380)
	_viewport.handle_input_locally = false
	vpc.add_child(_viewport)
	var cam := Camera3D.new()
	cam.name = "SandboxCamera"
	cam.position = Vector3(0, 4.5, 13.0)
	# look_at_from_position: safe even before the viewport's children have
	# finished entering the tree (plain look_at() errors in that window).
	cam.look_at_from_position(Vector3(0, 4.5, 13.0), Vector3(0, 1.0, 0), Vector3.UP)
	_viewport.add_child(cam)
	var light := DirectionalLight3D.new()
	light.position = Vector3(4, 8, 6)
	light.look_at_from_position(Vector3(4, 8, 6), Vector3.ZERO, Vector3.UP)
	_viewport.add_child(light)
	_result_label = Label.new()
	_result_label.name = "SandboxResult"
	_result_label.text = ""
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	StencilStyle.apply_body(_result_label, 18, StencilStyle.TEXT, 2)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_result_label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vb.add_child(row)
	_fire_button = Button.new()
	_fire_button.name = "SandboxFireButton"
	_fire_button.text = "FIRE TEST SHOT"
	StencilStyle.style_button(_fire_button)
	_fire_button.pressed.connect(_on_fire_pressed)
	row.add_child(_fire_button)
	var close := Button.new()
	close.name = "SandboxCloseButton"
	close.text = "CLOSE"
	StencilStyle.style_button(close)
	close.pressed.connect(_on_close_pressed)
	row.add_child(close)


## Opens the sandbox for a candidate + its assets.
## `asset` is the PROJECTILE asset (what flies at the dummy);
## `weapon_asset` (optional) is the candidate's weapon visual, shown
## static at the shooter so the test shows BOTH the weapon and what it
## fires. `behavior` is the creator menu's {"projectile",
## "explodes_on_impact"}. Existing 3-arg callers keep working.
func open(candidate: Dictionary, asset: Dictionary, behavior: Dictionary, weapon_asset: Dictionary = {}) -> void:
	_candidate = candidate
	_asset = asset
	_behavior = behavior
	_result = {}
	_animating = false
	_weapon_visual = null
	_anim_speed = PROJECTILE_SPEED
	if behavior.get("projectile_spec") is Dictionary:
		var pspec := behavior.get("projectile_spec", {}) as Dictionary
		if pspec.has("speed") and (pspec["speed"] is int or pspec["speed"] is float):
			_anim_speed = clampf(float(pspec["speed"]), 1.0, 200.0)
	if _candidate_label != null:
		_candidate_label.text = str(candidate.get("name", ""))
		# v0.5.3: show the invented hooks under test, so the tester can
		# see which hooks the shot is exercising.
		if behavior.get("hooks") is Array and not (behavior.get("hooks", []) as Array).is_empty():
			var parts: Array[String] = []
			for h in (behavior.get("hooks", []) as Array):
				if h is Dictionary:
					parts.append("%s (%s)" % [str((h as Dictionary).get("hook_id", "?")), str((h as Dictionary).get("hook_point", "?"))])
			_candidate_label.text += "\nHooks: " + ", ".join(parts)
	if _viewport == null:
		return
	for child in _viewport.get_children():
		if child is Node3D and child.name == "SandboxRoom":
			child.queue_free()
	_room_root = Node3D.new()
	_room_root.name = "SandboxRoom"
	_viewport.add_child(_room_root)
	var room := build_room(_room_root)
	_dummies = room["dummies"]
	_projectile = VoxelAssetGenerator.build_node_for_asset(asset)
	_projectile.position = SHOOTER_POS
	_room_root.add_child(_projectile)
	if not weapon_asset.is_empty():
		_weapon_visual = VoxelAssetGenerator.build_node_for_asset(weapon_asset)
		_weapon_visual.position = SHOOTER_POS + Vector3(0.9, 0.3, 0.4)
		_weapon_visual.scale = Vector3.ONE * 0.5
		_room_root.add_child(_weapon_visual)
	_projectile_pos = SHOOTER_POS
	_target_pos = DUMMY0_POS
	if _result_label != null:
		_result_label.text = "Ready — tap FIRE TEST SHOT."
	if _fire_button != null:
		_fire_button.disabled = false


## The flying projectile node (null before open / when headless).
func get_projectile() -> Node3D:
	return _projectile


## The static weapon-visual node (null when no weapon asset passed).
func get_weapon_visual() -> Node3D:
	return _weapon_visual


func get_last_result() -> Dictionary:
	return _result


func _process(_delta: float) -> void:
	if not _animating or _projectile == null:
		return
	_projectile_pos = _projectile_pos.move_toward(_target_pos, _anim_speed * _delta)
	_projectile.position = _projectile_pos
	_projectile.rotate_y(_delta * 6.0)
	if _projectile_pos.distance_to(_target_pos) <= HIT_DIST:
		_animating = false
		_detonate_visual()


func _on_fire_pressed() -> void:
	if _animating or _projectile == null:
		return
	if not bool(_behavior.get("projectile", true)):
		_result = simulate_test(_candidate, _asset, _behavior)
		if _result_label != null:
			_result_label.text = "Block placed in the test room — sandbox only, nothing installed."
		if _fire_button != null:
			_fire_button.disabled = true
		return
	_animating = true
	if _result_label != null:
		_result_label.text = "Projectile away…"


## Local-only explosion flash + dummy topple. No game FX, no damage to
## anything real — the sandbox viewport is a throwaway world. Hook
## scripts run for real here (see _live_hook_run): their reports land in
## the result label next to the effect-kind reports.
func _detonate_visual() -> void:
	_result = simulate_test(_candidate, _asset, _behavior, _live_hook_run())
	if _projectile != null:
		_projectile.visible = false
	if bool(_result.get("explosion_fired", false)):
		_flash = MeshInstance3D.new()
		_flash.mesh = SphereMesh.new()
		(_flash.mesh as SphereMesh).radius = 1.0
		(_flash.mesh as SphereMesh).height = 2.0
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1.0, 0.6, 0.15, 0.7)
		_flash.material_override = mat
		_flash.position = _target_pos
		if _room_root != null:
			_room_root.add_child(_flash)
		var tw := _flash.create_tween()
		tw.tween_property(_flash, "scale", Vector3.ONE * float(_result.get("explosion_radius", EXPLOSION_RADIUS)), 0.25)
		tw.tween_property(mat, "albedo_color:a", 0.0, 0.25)
		tw.chain().tween_callback(_flash.queue_free)
	if _dummies.size() > 0 and _dummies[0] is Node3D:
		var dummy := _dummies[0] as Node3D
		var tw2 := dummy.create_tween()
		tw2.tween_property(dummy, "rotation", Vector3(-PI / 2.0, 0, 0), 0.3)
	if _result_label != null:
		if bool(_result.get("hit", false)) and bool(_result.get("explosion_fired", false)):
			_result_label.text = "HIT — projectile struck dummy 0 and EXPLODED (radius %.0f, damage %.0f). Nothing installed." % [float(_result.get("explosion_radius", EXPLOSION_RADIUS)), float(_result.get("explosion_damage", EXPLOSION_DAMAGE))]
		elif bool(_result.get("hit", false)):
			_result_label.text = "HIT — projectile struck dummy 0 (no explosion in this mod). Nothing installed."
		else:
			_result_label.text = "MISS — projectile did not reach the dummy."
		# v0.5.3: report the hooks the shot exercised.
		if bool(_result.get("healed", false)):
			_result_label.text += " On-kill hook healed +%.0f HP." % float(_result.get("heal_on_kill", 0.0))
		# v0.5.5: report status effects visibly — a status mod must be
		# verifiable here, not just "HIT".
		var st_eff: Variant = _result.get("status_effects", [])
		if st_eff is Array:
			for st in (st_eff as Array):
				if not (st is Dictionary):
					continue
				var sk := str((st as Dictionary).get("kind", ""))
				if sk in ["slow", "freeze"]:
					_result_label.text += " %s: dummy speed %.1f → %.1f m/s for %.1fs." % [
						"SLOWED" if sk == "slow" else "FROZEN",
						float(_result.get("dummy_speed_before", DUMMY_BASE_SPEED)),
						float(_result.get("dummy_speed_after", DUMMY_BASE_SPEED)),
						float((st as Dictionary).get("duration_sec", 0.0))]
				elif sk == "burn":
					_result_label.text += " BURNING: %.0f damage/s for %.1fs." % [
						float((st as Dictionary).get("damage_per_sec", 0.0)),
						float((st as Dictionary).get("duration_sec", 0.0))]
				elif sk == "knockback":
					_result_label.text += " KNOCKBACK: force %.0f." % float((st as Dictionary).get("force", 0.0))
		var hooks_run: Variant = _result.get("hooks_run", [])
		if hooks_run is Array and not (hooks_run as Array).is_empty():
			var names: Array[String] = []
			for h in (hooks_run as Array):
				names.append(str(h))
			_result_label.text += " Hooks run: " + ", ".join(names) + "."
		# v0.5.6: report what the hook scripts actually did.
		var script_reports: Variant = _result.get("hook_script_reports", [])
		if script_reports is Array:
			for line in (script_reports as Array):
				_result_label.text += " " + str(line) + "."
		if bool(_result.get("candidate_disabled", false)):
			_result_label.text += " DISABLED — hook script error: " + str(_result.get("hook_error", "")) + "."
	if _fire_button != null:
		_fire_button.disabled = true


## Builds the live hook-run context for the UI detonation: a ModAPI
## bound to the sandbox room (throwaway world, SandboxPlayer with a
## real HP pool) + a hit ctx aimed at dummy 0, mirroring the real
## in-game hit ctx keys. {} when the room is not open (pure simulation
## — no code hooks run).
func _live_hook_run() -> Dictionary:
	if _room_root == null or _dummies.is_empty():
		return {}
	var player := SandboxPlayer.new()
	player.name = "SandboxPlayer"
	player.position = SHOOTER_POS
	_room_root.add_child(player)
	var api := ModAPI.new(player, _room_root)
	var spec: Dictionary = {}
	if _behavior.get("projectile_spec") is Dictionary:
		spec = _behavior.get("projectile_spec", {}) as Dictionary
	var dmg := 0.0
	if spec.has("damage") and (spec["damage"] is int or spec["damage"] is float):
		dmg = maxf(float(spec["damage"]), 0.0)
	var ctx := {"position": _target_pos, "hit_position": _target_pos,
		"damage": dmg, "target": _dummies[0], "headshot": false,
		"weapon_id": "sandbox", "projectile": spec}
	return {"api": api, "ctx": ctx}


func _on_close_pressed() -> void:
	sandbox_closed.emit(_result)
	queue_free()
