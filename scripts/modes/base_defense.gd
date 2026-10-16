# FORGEFALL — Base Defense mode (v0.5.9, Worker A).
#
# The mode that NEEDS Forge. Loop: BUILD phase (Forge menu auto-opens,
# WaveManager's intermission timer runs) -> COMBAT wave -> wave cleared
# -> next build phase. The player defends a base core with HP; the run
# ends when the core falls. Player death does NOT end the run — the
# player redeploys after RESPAWN_DELAY, like Domination.
#
# How the core takes damage (assault model): enemies that reach the base
# (within ASSAULT_RANGE of the core) assault it, each dealing
# DPS_PER_ENEMY (+5%/wave). Forge structures near the core (within
# DEFENSE_RADIUS, group "forge_structure") ABSORB the assault first:
# each structure soaks up to ABSORB_PER_STRUCTURE dps, taking that
# damage into its own HP (ForgeStructure / turret / cover all share the
# take_damage(amount, pos, is_headshot) interface); only the overflow
# reaches the core. Structures therefore degrade under assault and the
# player must rebuild them every build phase — that is the whole mode.
# Existing enemy behaviour is untouched: enemies still hunt the player
# (their hitscan only ever damages the player) and still batter
# structures via ForgeEnemyPressure; the assault tick is the
# base-under-siege layer on top, driven by enemy proximity to the core.
#
# Wiring (no shared-file refactors): GameModeManager.start() adds one
# BaseDefenseMode child when mode == "base_defense" (one hook line in
# game_mode.gd + the MODES entry); the main menu lists the mode. This
# node self-starts in _ready(), syncs with the WaveManager's current
# phase (the first build phase starts before this node exists), and
# dies with the run when Main frees the mode manager. No new enemy
# types, no new map: waves/enemies come from WaveManager unchanged.
class_name BaseDefenseMode
extends Node

signal base_defense_started()
signal core_damaged(core_hp: float, core_max_hp: float)
signal wave_survived(wave: int)
signal base_defense_over(waves_survived: int, score: int)

## Core HP. 1000 = ~33 s of unopposed assault by a 5-enemy wave-1
## force (5 x 6 dps), long enough to react, short enough that an
## undefended base always falls.
const CORE_MAX_HP := 1000.0
## Damage per second each assaulting enemy deals to the defenses/core.
const DPS_PER_ENEMY := 6.0
## +5% assault DPS per wave after wave 1 (wave scaling on top of the
## WaveManager's own count/tier scaling).
const DPS_GROWTH_PER_WAVE := 0.05
## DPS each nearby Forge structure absorbs before the core is touched.
const ABSORB_PER_STRUCTURE := 8.0
## Enemies within this range of the core count as assaulting the base.
const ASSAULT_RANGE := 35.0
## Structures within this range of the core count as base defenses.
const DEFENSE_RADIUS := 30.0
## Player redeploy delay after death (Domination parity).
const RESPAWN_DELAY := 3.0
## Score bonus per cleared wave (mirrors Endless's wave bonus shape).
const WAVE_CLEAR_BONUS_PER_WAVE := 50

var running := false
## "build" | "combat" | "over".
var phase := "build"
var wave := 0
var core_hp := CORE_MAX_HP
var waves_survived := 0
var core_pos := Vector3.ZERO

var _core: Node3D = null
var _core_mat: StandardMaterial3D = null
var _chip_layer: CanvasLayer = null
var _chip_label: Label = null
var _chip_text := ""
var _end_screen: Control = null
var _end_stats: Label = null
var _respawn_t := -1.0


func _ready() -> void:
	# Dedupe: GameModeManager.start() called twice must not run two
	# Base Defense loops under the same parent.
	for sib in get_parent().get_children() if get_parent() != null else []:
		if sib != self and sib is BaseDefenseMode:
			queue_free()
			return
	if Game.has_signal("build_phase_started") and not Game.build_phase_started.is_connected(_on_build_phase_started):
		Game.build_phase_started.connect(_on_build_phase_started)
	if Game.has_signal("wave_started") and not Game.wave_started.is_connected(_on_wave_started):
		Game.wave_started.connect(_on_wave_started)
	if Game.has_signal("wave_cleared") and not Game.wave_cleared.is_connected(_on_wave_cleared):
		Game.wave_cleared.connect(_on_wave_cleared)
	if Game.has_signal("player_died") and not Game.player_died.is_connected(_on_player_died):
		Game.player_died.connect(_on_player_died)
	_spawn_core()
	_build_chip()
	running = true
	phase = "build"
	# Sync with the WaveManager: its first build phase started before
	# this node existed (Main wires waves before modes). If it is
	# already in combat, start there instead of faking a build phase.
	var wm := _wave_manager()
	if wm != null and wm.get("in_build_phase") == false and int(wm.get("wave_number")) > 0:
		phase = "combat"
		wave = int(wm.get("wave_number"))
	else:
		_open_forge()
	_announce("BASE DEFENSE", "DEFEND THE CORE — FORGE YOUR DEFENSES")
	base_defense_started.emit()


func _process(delta: float) -> void:
	if not running:
		return
	if _respawn_t > 0.0:
		_respawn_t -= delta
		if _respawn_t <= 0.0:
			_do_respawn()
	if phase == "combat":
		_tick_assault(delta)
	_update_chip()


# --- Phase flow (driven by Game signals from WaveManager) -------------------

func _on_build_phase_started(_seconds: int) -> void:
	if not running or phase == "over":
		return
	phase = "build"
	_open_forge()
	_update_chip()


func _on_wave_started(n: int) -> void:
	if not running or phase == "over":
		return
	wave = n
	phase = "combat"
	_close_forge()
	_announce("WAVE %d — DEFEND THE CORE" % n, "CORE %d / %d" % [int(ceil(core_hp)), int(CORE_MAX_HP)])


func _on_wave_cleared(n: int) -> void:
	if not running or phase == "over":
		return
	waves_survived = maxi(waves_survived, n)
	Game.add_score(WAVE_CLEAR_BONUS_PER_WAVE * maxi(n, 1))
	wave_survived.emit(n)
	# WaveManager opens the next build phase itself (build_phase_started
	# fires from on_enemy_died); this announce carries the core status.
	_announce("WAVE %d CLEARED" % n, "CORE %d / %d — REBUILD YOUR DEFENSES" % [int(ceil(core_hp)), int(CORE_MAX_HP)])


func _on_player_died() -> void:
	if not running or phase == "over":
		return
	# The core is the run's life, not the player: redeploy, keep fighting.
	_respawn_t = RESPAWN_DELAY


func _do_respawn() -> void:
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return
	var player: Node = ps[0]
	if player == null or not is_instance_valid(player) or not player.has_method("respawn"):
		return
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	var pos := Vector3(0, 1.0, 0)
	if not spawns.is_empty():
		var m := spawns[randi() % spawns.size()] as Node3D
		pos = m.global_position
	player.call("respawn", pos)


# --- Assault: structures absorb, overflow hits the core ---------------------

## Pure split of one assault tick (verifier-friendly): incoming DPS
## from `alive` enemies at `wave_num`, absorbed by `structure_count`
## defenses, overflow to the core, and damage per structure.
static func assault_split(alive: int, wave_num: int, structure_count: int) -> Dictionary:
	var dps_each := DPS_PER_ENEMY * (1.0 + DPS_GROWTH_PER_WAVE * float(maxi(wave_num - 1, 0)))
	var incoming := float(alive) * dps_each
	var capacity := float(structure_count) * ABSORB_PER_STRUCTURE
	var absorbed := minf(incoming, capacity)
	var overflow := incoming - absorbed
	var per := (absorbed / float(structure_count)) if structure_count > 0 else 0.0
	return {"incoming": incoming, "absorbed": absorbed, "overflow": overflow, "per_structure": per}


func _tick_assault(delta: float) -> void:
	var alive := _alive_assaulters()
	if alive.is_empty():
		return
	var defenses := _defenses()
	var split := assault_split(alive.size(), wave, defenses.size())
	var per: float = split["per_structure"]
	if per > 0.0:
		for d in defenses:
			if d != null and is_instance_valid(d) and d.has_method("take_damage"):
				d.call("take_damage", per * delta, core_pos, false)
	var overflow: float = split["overflow"]
	if overflow > 0.0:
		_damage_core(overflow * delta)


## Live enemies within ASSAULT_RANGE of the core. Duck-typed so pooled
## EnemyBase bodies (active/dead vars) and test doubles both work:
## a node is skipped only when it explicitly reports active == false
## or dead == true.
func _alive_assaulters() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var seen := {}
	for e in get_tree().get_nodes_in_group("enemy"):
		if e == null or not is_instance_valid(e) or not (e is Node3D):
			continue
		var id := (e as Node).get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true
		if (e as Node).get("active") == false:
			continue
		if (e as Node).get("dead") == true:
			continue
		var foe := e as Node3D
		if foe.global_position.distance_to(core_pos) > ASSAULT_RANGE:
			continue
		out.append(foe)
	return out


## Intact Forge structures within DEFENSE_RADIUS of the core.
func _defenses() -> Array[Node]:
	var out: Array[Node] = []
	for s in get_tree().get_nodes_in_group("forge_structure"):
		if s == null or not is_instance_valid(s) or not (s is Node3D):
			continue
		if (s as Node).get("_destroyed") == true:
			continue
		if (s as Node).get("_dead") == true:
			continue
		if (s as Node).has_method("is_broken") and bool((s as Node).call("is_broken")):
			continue
		if ForgeStructure.hp_of(s) <= 0.0:
			continue
		if (s as Node3D).global_position.distance_to(core_pos) > DEFENSE_RADIUS:
			continue
		out.append(s)
	return out


func _damage_core(amount: float) -> void:
	if phase == "over":
		return
	core_hp = maxf(core_hp - amount, 0.0)
	core_damaged.emit(core_hp, CORE_MAX_HP)
	_update_core_visual()
	_update_chip()
	if core_hp <= 0.0:
		_defeat()


func _defeat() -> void:
	phase = "over"
	_respawn_t = -1.0
	_close_forge()
	for wm in get_tree().get_nodes_in_group("wave_manager"):
		if wm != null and wm.has_method("stop_run"):
			wm.call("stop_run")
	_announce("BASE DESTROYED", "THE CORE HAS FALLEN — WAVE %d" % maxi(wave, 1))
	_sfx("player_death")
	base_defense_over.emit(waves_survived, Game.score)
	if is_inside_tree() and get_node_or_null("/root/Progression") != null: get_node_or_null("/root/Progression").report_event("match_end", {"mode": "base_defense", "won": false, "waves": waves_survived, "score": Game.score})
	_show_end_screen()


# --- Core: voxel pillar at the arena centre ----------------------------------

func _spawn_core() -> void:
	# Arena centre = centroid of the map's player_spawn markers (the
	# same markers Main spawns the player at); origin when the map has
	# none (headless / bare-tree runs).
	var center := Vector3.ZERO
	var spawns := get_tree().get_nodes_in_group("player_spawn")
	if not spawns.is_empty():
		for s in spawns:
			center += (s as Node3D).global_position
		center /= float(spawns.size())
	center.y = 0.0
	core_pos = center
	var root := Node3D.new()
	root.name = "BaseCore"
	root.position = center
	root.add_to_group("base_core")
	add_child(root)
	_core = root
	# Base ring.
	var ring := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 2.2
	cyl.bottom_radius = 2.4
	cyl.height = 0.18
	ring.mesh = cyl
	ring.position.y = 0.09
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(0.23, 0.25, 0.27)
	ring.material_override = ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	# The core itself: a chunky emissive voxel cube (Modern Voxfare 2).
	var cube := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.4, 1.4, 1.4)
	cube.mesh = box
	cube.position.y = 1.0
	_core_mat = StandardMaterial3D.new()
	_core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core_mat.emission_enabled = true
	_core_mat.albedo_color = StencilStyle.ORANGE
	_core_mat.emission = StencilStyle.ORANGE
	_core_mat.emission_energy_multiplier = 1.6
	cube.material_override = _core_mat
	root.add_child(cube)
	# Four corner pylons.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var py := MeshInstance3D.new()
			var pbox := BoxMesh.new()
			pbox.size = Vector3(0.35, 2.2, 0.35)
			py.mesh = pbox
			py.position = Vector3(sx * 1.7, 1.1, sz * 1.7)
			var pmat := StandardMaterial3D.new()
			pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			pmat.albedo_color = Color(0.35, 0.38, 0.42)
			py.material_override = pmat
			root.add_child(py)
	_update_core_visual()


func _update_core_visual() -> void:
	if _core_mat == null:
		return
	# Full HP = forge orange; empty = dark red. Lerp in HSV-ish steps
	# via Color.lerp so the core visibly "cools" as it takes damage.
	var frac := clampf(core_hp / CORE_MAX_HP, 0.0, 1.0)
	var col := Color(0.85, 0.12, 0.10).lerp(StencilStyle.ORANGE, frac)
	_core_mat.albedo_color = col
	_core_mat.emission = col
	_core_mat.emission_energy_multiplier = 0.4 + 1.2 * frac


# --- HUD chip: persistent CORE HP readout ------------------------------------

func _build_chip() -> void:
	_chip_layer = CanvasLayer.new()
	_chip_layer.name = "BaseDefenseChip"
	_chip_layer.layer = 10
	add_child(_chip_layer)
	_chip_label = Label.new()
	_chip_label.name = "CoreHp"
	_chip_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_chip_label.offset_top = 46.0
	_chip_label.offset_bottom = 78.0
	_chip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chip_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_chip_label.add_theme_font_size_override("font_size", 22)
	_chip_label.add_theme_color_override("font_color", StencilStyle.ORANGE)
	_chip_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_chip_label.add_theme_constant_override("shadow_offset_x", 2)
	_chip_label.add_theme_constant_override("shadow_offset_y", 2)
	_chip_layer.add_child(_chip_label)
	_update_chip()


func _update_chip() -> void:
	if _chip_label == null:
		return
	var text := "CORE %d / %d   —   WAVE %d" % [int(ceil(core_hp)), int(CORE_MAX_HP), maxi(wave, 1)]
	if phase == "build":
		text += "   —   BUILD PHASE"
	elif phase == "over":
		text = "CORE DESTROYED"
	if text != _chip_text:
		_chip_text = text
		_chip_label.text = text


# --- End screen ----------------------------------------------------------------

func _show_end_screen() -> void:
	if _end_screen != null and is_instance_valid(_end_screen):
		_end_screen.visible = true
		_refresh_end_stats()
		return
	var screen := Control.new()
	screen.name = "BaseDefenseEndScreen"
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(screen)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.75)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	screen.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -320
	panel.offset_right = 320
	panel.offset_top = -190
	panel.offset_bottom = 190
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	screen.add_child(panel)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	var title := Label.new()
	StencilStyle.apply_title(title, 44, StencilStyle.RED, 4)
	title.text = "BASE DESTROYED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	_end_stats = Label.new()
	StencilStyle.apply_body(_end_stats, 22, StencilStyle.TEXT, 2)
	_end_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_end_stats)
	var retry := Button.new()
	retry.text = "RETRY"
	retry.custom_minimum_size = Vector2(300, 60)
	StencilStyle.style_button(retry)
	retry.add_theme_font_size_override("font_size", 26)
	retry.pressed.connect(_on_retry)
	vb.add_child(retry)
	var quit := Button.new()
	quit.text = "QUIT TO MENU"
	quit.custom_minimum_size = Vector2(300, 60)
	StencilStyle.style_button(quit)
	quit.add_theme_font_size_override("font_size", 26)
	quit.pressed.connect(_on_quit)
	vb.add_child(quit)
	_end_screen = screen
	_refresh_end_stats()


func _refresh_end_stats() -> void:
	if _end_stats == null:
		return
	_end_stats.text = "WAVES SURVIVED: %d\nSCORE: %d\nThe core has fallen. Forge harder." % [waves_survived, Game.score]


func _on_retry() -> void:
	# Fresh run: clear last run's Forge structures, reset run state,
	# restore the core, restart the WaveManager (its start_run opens
	# the first build phase, which re-opens Forge via the signal).
	if _end_screen != null and is_instance_valid(_end_screen):
		_end_screen.visible = false
	var doomed: Array[Node] = []
	for s in get_tree().get_nodes_in_group("forge_structure"):
		doomed.append(s)
	for s in doomed:
		if s != null and is_instance_valid(s):
			(s as Node).queue_free()
	Game.reset_run()
	core_hp = CORE_MAX_HP
	waves_survived = 0
	wave = 0
	phase = "build"
	_respawn_t = -1.0
	_update_core_visual()
	_update_chip()
	running = true
	var wm := _wave_manager()
	if wm != null and wm.has_method("start_run"):
		wm.call("start_run")
	else:
		_open_forge()
		_announce("BASE DEFENSE", "DEFEND THE CORE — FORGE YOUR DEFENSES")
	base_defense_started.emit()


func _on_quit() -> void:
	var roots := get_tree().get_nodes_in_group("game_root")
	if not roots.is_empty() and (roots[0] as Node).has_method("quit_to_menu"):
		(roots[0] as Node).call("quit_to_menu")
		return
	# No game root (headless / bare tree): just dismiss and stop.
	if _end_screen != null and is_instance_valid(_end_screen):
		_end_screen.visible = false
	running = false


# --- Helpers --------------------------------------------------------------------

func _wave_manager() -> Node:
	var wms := get_tree().get_nodes_in_group("wave_manager")
	if wms.is_empty():
		return null
	return wms[0]


func _open_forge() -> void:
	for m in get_tree().get_nodes_in_group("forge_menu"):
		if m == null or not is_instance_valid(m):
			continue
		if m.has_method("is_open") and bool(m.call("is_open")):
			continue
		if m.has_method("open"):
			m.call("open")


func _close_forge() -> void:
	for m in get_tree().get_nodes_in_group("forge_menu"):
		if m == null or not is_instance_valid(m):
			continue
		if m.has_method("is_open") and not bool(m.call("is_open")):
			continue
		if m.has_method("close"):
			m.call("close")


func _announce(title: String, subtitle: String) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("announce"):
			h.call("announce", title, subtitle)
		elif h.has_method("add_killfeed"):
			h.call("add_killfeed", "%s — %s" % [title, subtitle])


func _sfx(id: String) -> void:
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and sfx.has_method("play_2d"):
		sfx.call("play_2d", id)
