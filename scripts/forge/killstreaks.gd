# FORGEFALL — Killstreaks (Worker 8: Forge system)
# MW2-style support powers, earned by kill streaks (3/5/7 via Game) or bought
# through the Forge. Child of the Forge autoload; lives in group "killstreaks"
# so ForgeBuilder can reach it from static context.
#
# - trigger("uav", mode): HUD announce + asks the HUD to reveal enemies on the
#   minimap for 20 s (guarded: hud.set_uav may not exist -> announce only).
#   HUD contract (for the parallel HUD worker, guarded with has_method /
#   has_signal on its side): signals uav_started(duration: float) /
#   uav_ended(), and get_uav_targets() -> Array[Vector3] returning live enemy
#   positions while the UAV is active, [] when inactive.
# - trigger("airstrike", mode): warning marker/flare at the marked point +
#   ~1.5 s delay so it feels fair, then 3 blasts along a line at the marked
#   point (crosshair raycast) or nearest enemy ("auto"), staggered 0.4 s,
#   with a "wave_horn" incoming warning. Damage is ENEMY-ONLY radial damage
#   (same falloff formula as ExplosionFX) + ExplosionFX.detonate_light for
#   visuals/shake/flash/fireball/sound — it deliberately does NOT call
#   ExplosionFX.detonate / ForgeBuilder.fx_detonate, because that path hits
#   every take_damage collider including the player. The player is never
#   damaged by an airstrike.
# - trigger("chopper", mode): voxel attack helicopter orbits the player at
#   25 m for 45 s, engaging enemies with hitscan fire + a short tracer
#   visual, then climbs away and frees itself.
#
# _unhandled_input: killstreak_1/2/3 actions consume earned unlocks via
# Game.use_killstreak() (which emits killstreak_used and clears the slot).
extends Node
class_name Killstreaks

#region TUNABLES
const UAV_DURATION_SEC := 20.0
const AIRSTRIKE_BLASTS := 3
const AIRSTRIKE_SPACING_M := 6.0
const AIRSTRIKE_RADIUS_M := 8.0
const AIRSTRIKE_DAMAGE := 120.0
const AIRSTRIKE_STAGGER_SEC := 0.4
const AIRSTRIKE_WARNING_SEC := 1.5
const AIRSTRIKE_AUTO_RANGE_M := 60.0
const CHOPPER_DURATION_SEC := 45.0
const CHOPPER_ORBIT_RADIUS_M := 25.0
const CHOPPER_HEIGHT_M := 14.0
const CHOPPER_DAMAGE := 10.0
const CHOPPER_SHOT_INTERVAL := 0.5
const CHOPPER_RANGE_M := 40.0
#endregion

const STREAK_INDEX := {"uav": 0, "airstrike": 1, "chopper": 2}
const STREAK_THRESHOLDS := [3, 5, 7] ## mirrors Tuning.KILLSTREAK_THRESHOLDS

## HUD contract: emitted when the UAV goes live, with its duration.
signal uav_started(duration: float)
## HUD contract: emitted when the UAV sweep ends (or is refreshed away).
signal uav_ended

var _uav_active := false
var _uav_remaining := 0.0


func _ready() -> void:
	add_to_group("killstreaks")


func _process(delta: float) -> void:
	if _uav_active:
		_uav_remaining -= delta
		if _uav_remaining <= 0.0:
			_uav_active = false
			_uav_remaining = 0.0
			uav_ended.emit()


func _unhandled_input(event: InputEvent) -> void:
	for i in range(3):
		var action := "killstreak_%d" % (i + 1)
		if InputMap.has_action(action) and event.is_action_pressed(action):
			_try_consume(i)
			get_viewport().set_input_as_handled()
			return


func _try_consume(index: int) -> void:
	if Game.has_method("use_killstreak") and Game.use_killstreak(index):
		var streak := _index_to_streak(index)
		var msg := trigger(streak, "marked")
		_announce(Tuning.KILLSTREAK_NAMES[index] if index < Tuning.KILLSTREAK_NAMES.size() else "KILLSTREAK", msg)
		Sfx.play_2d("killstreak_ready")
	else:
		_announce("KILLSTREAK LOCKED", "Earn a %d kill streak — or buy it from the Forge." % STREAK_THRESHOLDS[index])


func _index_to_streak(index: int) -> String:
	match index:
		0:
			return "uav"
		1:
			return "airstrike"
		2:
			return "chopper"
	return ""


## Fires a killstreak. Returns a human-readable result message.
## Called both for earned streaks (via input) and Forge purchases (via builder).
func trigger(streak: String, target_mode: String, player: Node3D = null) -> String:
	if player == null:
		player = get_tree().get_first_node_in_group("player") as Node3D
	match streak:
		"uav":
			return _trigger_uav()
		"airstrike":
			return _trigger_airstrike(target_mode, player)
		"chopper":
			return _trigger_chopper(player)
	return "Unknown killstreak '%s'." % streak


## HUD contract: world positions of live enemies while the UAV is active,
## [] when inactive. Dead / non-Node3D foes are excluded.
func get_uav_targets() -> Array[Vector3]:
	if not _uav_active:
		return []
	var out: Array[Vector3] = []
	for e in _foes():
		if e is Node3D and not bool((e as Node).get("dead")):
			out.append((e as Node3D).global_position)
	return out


func is_uav_active() -> bool:
	return _uav_active


func _announce(title: String, subtitle: String) -> void:
	var hud = get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("announce"):
		hud.announce(title, subtitle)


func _trigger_uav() -> String:
	# Re-triggering refreshes the sweep (and re-emits started).
	_uav_active = true
	_uav_remaining = UAV_DURATION_SEC
	uav_started.emit(UAV_DURATION_SEC)
	_announce("UAV ONLINE", "Enemy positions revealed.")
	Sfx.play_2d("uav_online")
	var hud = get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("set_uav"):
		hud.set_uav(UAV_DURATION_SEC)
		return "UAV online — enemies marked on the minimap for %ds." % int(UAV_DURATION_SEC)
	return "UAV online — recon sweep complete (minimap link unavailable)."


func _trigger_airstrike(target_mode: String, player: Node3D) -> String:
	var point := _strike_point(target_mode, player)
	_announce("AIRSTRIKE INBOUND", "Danger close.")
	Sfx.play_2d("wave_horn")
	_run_airstrike(point, player)
	return "Airstrike inbound on the marked position."


func _strike_point(target_mode: String, player: Node3D) -> Vector3:
	if target_mode == "auto" and player != null:
		var best: Node3D = null
		var best_d := AIRSTRIKE_AUTO_RANGE_M
		for e in _foes():
			if e is Node3D and not bool((e as Node).get("dead")):
				var d := player.global_position.distance_to((e as Node3D).global_position)
				if d < best_d:
					best_d = d
					best = e
		if best != null:
			return best.global_position
	return ForgeBuilder.crosshair_point(player)


func _run_airstrike(point: Vector3, player: Node3D) -> void:
	var marker := _spawn_strike_marker(point)
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(AIRSTRIKE_WARNING_SEC).timeout
	if not is_instance_valid(self):
		return
	if is_instance_valid(marker):
		marker.queue_free()
	var dir := Vector3(1, 0, 0)
	if player != null and is_instance_valid(player):
		var away := point - player.global_position
		away.y = 0.0
		if away.length() > 0.5:
			dir = away.normalized().rotated(Vector3.UP, PI * 0.5)
	for i in range(AIRSTRIKE_BLASTS):
		if not is_instance_valid(self):
			return
		var at := point + dir * float(i - 1) * AIRSTRIKE_SPACING_M
		_blast_at(at)
		if i < AIRSTRIKE_BLASTS - 1:
			var t2 := get_tree()
			if t2 == null:
				return
			await t2.create_timer(AIRSTRIKE_STAGGER_SEC).timeout


## Enemy-only radial damage (same falloff as ExplosionFX: min 30% at edge)
## + ExplosionFX visuals. The player is never iterated, so never damaged.
func _blast_at(pos: Vector3) -> void:
	for e in _foes():
		if e is Node3D and (e as Node).has_method("take_damage") and not bool((e as Node).get("dead")):
			var at := (e as Node3D).global_position
			var d := pos.distance_to(at)
			if d <= AIRSTRIKE_RADIUS_M:
				var fall := 1.0 - clampf(d / maxf(AIRSTRIKE_RADIUS_M, 0.001), 0.0, 1.0) * 0.7
				(e as Node).call("take_damage", AIRSTRIKE_DAMAGE * fall, at, false)
	# Visuals only (flash + fireball + shake + sound), no damage.
	# Goal 2: airstrike blasts use the biggest explosion sound.
	ExplosionFX.detonate_airstrike(pos)


## Warning marker/flare at the strike point. Freed when the blasts start.
## In group "airstrike_marker" so tests / cleanup can find it.
func _spawn_strike_marker(point: Vector3) -> Node3D:
	var m := Node3D.new()
	m.name = "AirstrikeMarker"
	m.add_to_group("airstrike_marker")
	var cyl := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.2
	cm.bottom_radius = 1.2
	cm.height = 0.15
	cyl.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.15, 0.1)
	mat.emission_energy_multiplier = 2.0
	mat.albedo_color = Color(1.0, 0.2, 0.1, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cyl.material_override = mat
	cyl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.add_child(cyl)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.25, 0.1)
	light.light_energy = 3.0
	light.omni_range = 10.0
	light.shadow_enabled = false
	light.position = Vector3(0, 1.5, 0)
	m.add_child(light)
	var tree := get_tree()
	var root := tree.current_scene if tree != null else null
	if root != null:
		root.add_child(m)
		m.global_position = point + Vector3(0, 0.2, 0)
	else:
		m.position = point + Vector3(0, 0.2, 0)
	return m


func _trigger_chopper(player: Node3D) -> String:
	if player == null:
		return "Chopper has no one to protect — no player found."
	var c := Chopper.new()
	c.target_player = player
	c.duration = CHOPPER_DURATION_SEC
	c.radius = CHOPPER_ORBIT_RADIUS_M
	c.height = CHOPPER_HEIGHT_M
	c.damage = CHOPPER_DAMAGE
	c.shot_interval = CHOPPER_SHOT_INTERVAL
	c.range_m = CHOPPER_RANGE_M
	var root := get_tree().current_scene
	if root == null:
		return "Chopper has nowhere to fly."
	root.add_child(c)
	c.global_position = player.global_position + Vector3(CHOPPER_ORBIT_RADIUS_M, CHOPPER_HEIGHT_M, 0)
	_announce("CHOPPER INBOUND", "Air support on station — %ds." % int(CHOPPER_DURATION_SEC))
	return "Attack chopper on station."


func _foes() -> Array:
	var out: Array = []
	var seen := {}
	for group in ["enemy", "enemies"]:
		for e in get_tree().get_nodes_in_group(group):
			var id := (e as Node).get_instance_id()
			if not seen.has(id):
				seen[id] = true
				out.append(e)
	return out


## Voxel attack helicopter: orbits the player, engages nearest enemy in range.
class Chopper extends Node3D:
	var target_player: Node3D = null
	var duration := 45.0
	var radius := 25.0
	var height := 14.0
	var damage := 10.0
	var shot_interval := 0.5
	var range_m := 40.0
	var _t := 0.0
	var _angle := 0.0
	var _fire_timer := 1.0
	var _rotor: Node3D = null
	var _leaving := false

	func _ready() -> void:
		add_to_group("chopper")
		_t = duration
		var olive: Color = VoxelBuilder.PALETTE["olive"]
		var dark: Color = VoxelBuilder.PALETTE["darkmetal"]
		add_child(VoxelBuilder.cube(Vector3(1.7, 0.7, 1.0), olive, Vector3.ZERO))
		add_child(VoxelBuilder.cube(Vector3(0.7, 0.45, 0.9), Color(0.4, 0.7, 0.9), Vector3(0, 0.1, -0.75)))
		add_child(VoxelBuilder.cube(Vector3(0.35, 0.35, 1.6), olive, Vector3(0, 0.15, 1.4)))
		add_child(VoxelBuilder.cube(Vector3(0.12, 0.7, 0.5), olive, Vector3(0, 0.4, 2.1)))
		add_child(VoxelBuilder.cube(Vector3(1.4, 0.12, 0.25), dark, Vector3(0, -0.5, 0.2)))
		add_child(VoxelBuilder.cube(Vector3(1.4, 0.12, 0.25), dark, Vector3(0, -0.5, -0.4)))
		_rotor = Node3D.new()
		_rotor.position = Vector3(0, 0.45, 0)
		add_child(_rotor)
		_rotor.add_child(VoxelBuilder.cube(Vector3(4.2, 0.08, 0.3), dark, Vector3.ZERO))
		_rotor.add_child(VoxelBuilder.cube(Vector3(0.3, 0.08, 4.2), dark, Vector3.ZERO))

	func _process(delta: float) -> void:
		if _leaving:
			return
		if target_player == null or not is_instance_valid(target_player):
			queue_free()
			return
		_t -= delta
		if _t <= 0.0:
			_leave()
			return
		_angle += delta * 0.45
		var center: Vector3 = target_player.global_position
		var want := center + Vector3(cos(_angle) * radius, height, sin(_angle) * radius)
		global_position = global_position.lerp(want, clampf(delta * 2.0, 0.0, 1.0))
		var look := center + Vector3(0, 1.0, 0)
		if (look - global_position).length() > 0.5:
			look_at(look, Vector3.UP)
		if _rotor != null:
			_rotor.rotate_y(delta * 18.0)
		_fire_timer -= delta
		if _fire_timer <= 0.0:
			_fire_timer = shot_interval
			_shoot()

	func _shoot() -> void:
		var best = null
		var best_d := range_m
		var seen := {}
		for group in ["enemy", "enemies"]:
			for e in get_tree().get_nodes_in_group(group):
				var id := (e as Node).get_instance_id()
				if seen.has(id):
					continue
				seen[id] = true
				var foe = e
				if foe is Node3D and not bool(foe.get("dead")) and foe.has_method("take_damage"):
					var d := global_position.distance_to((foe as Node3D).global_position)
					if d < best_d:
						best_d = d
						best = foe
		if best == null:
			return
		var target_pos := (best as Node3D).global_position
		best.take_damage(damage, target_pos, false)
		_spawn_tracer(global_position, target_pos)
		Sfx.play_3d("shot_turret", global_position, -8.0)

	## Short-lived tracer beam from muzzle to target; frees itself.
	func _spawn_tracer(from: Vector3, to: Vector3) -> void:
		var tree := get_tree()
		if tree == null:
			return
		var dist := from.distance_to(to)
		if dist < 0.5:
			return
		var mi := MeshInstance3D.new()
		mi.name = "ChopperTracer"
		var box := BoxMesh.new()
		box.size = Vector3(0.06, 0.06, dist)
		mi.mesh = box
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.85, 0.3)
		mat.emission_energy_multiplier = 2.0
		mat.albedo_color = Color(1.0, 0.85, 0.3)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var parent := get_parent()
		if parent != null:
			parent.add_child(mi)
		elif tree.current_scene != null:
			tree.current_scene.add_child(mi)
		else:
			return
		mi.global_position = (from + to) * 0.5
		mi.look_at(to, Vector3.UP)
		tree.create_timer(0.12).timeout.connect(func() -> void:
			if is_instance_valid(mi):
				mi.queue_free())

	func _leave() -> void:
		if _leaving:
			return
		_leaving = true
		var tw := create_tween()
		tw.tween_property(self, "global_position:y", global_position.y + 25.0, 3.0)
		tw.tween_callback(queue_free)
