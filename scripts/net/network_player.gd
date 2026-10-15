# FORGEFALL — scripts/net/network_player.gd (Goal 4, Worker A)
# Networked player representation. Two modes, one node:
#
#   LOCAL (is_local == true): a sync SHIM. It never moves, never renders
#   (visible = false, no visuals built). bind_local_player(real_player)
#   attaches the real player.gd CharacterBody3D; every SEND_INTERVAL the
#   shim reads position / yaw / pitch / velocity / health / weapon /
#   sprint-crouch-slide-ADS flags off that node (duck-typed, no player.gd
#   changes) and hands the snapshot to NetManager.send_state(). The real
#   controller stays 100% in charge of the local player.
#
#   REMOTE (is_local == false): a PUPPET. Lightweight voxel dummy built
#   in code (box body + box head + box gun + name Label3D + capsule hitbox)
#   — deliberately NOT an instance of player.tscn, because that scene
#   carries a Camera, WeaponManager, GrappleHook, PortalEmitter and live
#   input handling, none of which a remote puppet may have. receive_state()
#   feeds snapshots; _process() renders them through interpolation
#   (see MOVEMENT SYNC below). apply_damage() / apply_respawn() are called
#   by NetManager from host broadcasts.
#
# MOVEMENT SYNC — client-side interpolation (chosen over prediction):
#   Prediction would need to re-run the full movement controller
#   (sprint/slide/wall-run/grapple/portal) on every peer for every remote
#   player, fork player.gd, and still mispredict on input changes. The
#   game is a small-match (<=8) co-op/wave shooter, not a twitch
#   tournament dueller: an 80ms interpolation delay is invisible next to
#   enemy AI reaction times, and interpolation CANNOT diverge — the worst
#   case is a briefly stale puppet, never a rubber-banding correction.
#   Implementation: snapshots are buffered with receive timestamps.
#   Render time = now - INTERP_DELAY (80ms); the puppet lerps between
#   the two snapshots bracketing render time. Past the newest snapshot it
#   extrapolates along the last velocity for at most 0.15s, then damps.
#   A gap > SNAP_DISTANCE (6m) snaps (respawn / teleport). At ~100ms
#   simulated lag this yields smooth motion with no per-frame teleport:
#   verified headlessly (see tools/verify_netcode.gd).
#
# This node defines NO @rpc functions. All RPCs live on NetManager
# (stable autoload path). NetManager is found via set_net_manager(), else
# /root/Net, else /root/NetManager.
extends Node3D
class_name NetworkPlayer

signal damaged(amount: float, attacker_id: int)
signal died()
signal respawned(spawn_pos: Vector3)

const SEND_INTERVAL := 0.05  # 20 Hz state send for the local shim.
const INTERP_DELAY := 0.08  # 80ms interpolation buffer.
const MAX_EXTRAPOLATE := 0.15  # Cap velocity extrapolation past newest snapshot.
const SNAP_DISTANCE := 6.0  # Beyond this, snap instead of glide (respawn/teleport).
const FLAG_SPRINT := 1
const FLAG_CROUCH := 2
const FLAG_SLIDE := 4
const FLAG_ADS := 8


## Hitbox body for a remote puppet. WeaponBase hitscan calls
## take_damage() on whatever collider the ray strikes, so the hitbox
## itself must answer — it forwards to the owning NetworkPlayer, which
## forwards to NetManager.request_damage() (host-validated, never
## applied locally). A head hitbox in group "enemy_head" makes
## WeaponBase._is_headshot() return true with zero weapon-code edits.
class PuppetHitbox extends StaticBody3D:
	var _puppet: NetworkPlayer = null

	func _init(p_puppet: NetworkPlayer) -> void:
		_puppet = p_puppet

	func take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void:
		if _puppet != null:
			_puppet.take_damage(amount, hit_position, is_headshot)

	func is_dead() -> bool:
		return _puppet != null and _puppet.health <= 0.0

var peer_id: int = 0
var player_name: String = "Player"
var is_local_player: bool = false
var health: float = 100.0
var current_weapon: String = ""
var flags: int = 0

var _net: Node = null
var _local_player = null
var _local_hp: float = 100.0
var _send_timer: float = 0.0
# Puppet snapshot buffer: {"t": float, "pos": Vector3, "yaw": float,
# "pitch": float, "vel": Vector3} sorted by receive time.
var _snapshots: Array = []
var _head: Node3D = null
var _gun_mesh: MeshInstance3D = null
var _gun_mat: StandardMaterial3D = null
var _name_label: Label3D = null
var _body_mesh: MeshInstance3D = null


## Configure this node. Call before adding to the tree (visuals are
## built in _ready based on is_local_player).
func setup(p_peer_id: int, p_name: String, p_is_local: bool) -> void:
	peer_id = p_peer_id
	player_name = p_name
	is_local_player = p_is_local
	health = 100.0
	if not is_local_player:
		# Same group as NetMatch's standalone NetPuppet: HUD/waves/enemies
		# ignore net puppets via this group, so delegated puppets must join
		# it too (coordinator integration fix — without this the puppets
		# were invisible to every "net_puppet" filter).
		add_to_group("net_puppet")
	if is_local_player:
		visible = false
	if _name_label != null:
		_name_label.text = player_name


func set_net_manager(net: Node) -> void:
	_net = net


func get_net_manager() -> Node:
	if _net != null:
		return _net
	var root := get_tree().root if is_inside_tree() else null
	if root != null:
		var autoload_net := root.get_node_or_null("Net")
		if autoload_net != null:
			_net = autoload_net
			return _net
		var alt := root.get_node_or_null("NetManager")
		if alt != null:
			_net = alt
			return _net
	return null


## Local mode only: attach the real player.gd node. Duck-typed reads —
## player.gd is never modified. Health is tracked via its health_changed
## signal when present, else via the _hp script variable.
func bind_local_player(player_node) -> void:
	_local_player = player_node
	if player_node != null and player_node.has_signal("health_changed"):
		var cb := Callable(self, "_on_local_health_changed")
		if not player_node.is_connected("health_changed", cb):
			player_node.health_changed.connect(cb)
	if player_node != null:
		var hp_var = player_node.get("_hp")
		if hp_var != null:
			_local_hp = float(hp_var)


func _on_local_health_changed(hp: float, _max_hp: float) -> void:
	_local_hp = hp


func _ready() -> void:
	if is_local_player:
		visible = false
		return
	_build_puppet_visuals()


func _build_puppet_visuals() -> void:
	# Voxel dummy: chunky boxes, no textures, no player.tscn dependencies.
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.15, 0.75, 0.85)
	_body_mesh = MeshInstance3D.new()
	_body_mesh.name = "PuppetBody"
	var body_box := BoxMesh.new()
	body_box.size = Vector3(0.7, 1.1, 0.4)
	_body_mesh.mesh = body_box
	_body_mesh.material_override = body_mat
	_body_mesh.position = Vector3(0, 0.95, 0)
	add_child(_body_mesh)

	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.9, 0.85, 0.7)
	var head_mesh := MeshInstance3D.new()
	head_mesh.name = "PuppetHead"
	var head_box := BoxMesh.new()
	head_box.size = Vector3(0.55, 0.5, 0.55)
	head_mesh.mesh = head_box
	head_mesh.material_override = head_mat
	head_mesh.position = Vector3(0, 1.75, 0)
	add_child(head_mesh)
	_head = head_mesh

	_gun_mat = StandardMaterial3D.new()
	_gun_mat.albedo_color = Color(0.15, 0.15, 0.18)
	_gun_mesh = MeshInstance3D.new()
	_gun_mesh.name = "PuppetGun"
	var gun_box := BoxMesh.new()
	gun_box.size = Vector3(0.09, 0.13, 0.55)
	_gun_mesh.mesh = gun_box
	_gun_mesh.material_override = _gun_mat
	_gun_mesh.position = Vector3(0.28, 1.35, -0.45)
	add_child(_gun_mesh)

	_name_label = Label3D.new()
	_name_label.name = "NameLabel"
	_name_label.text = player_name
	_name_label.font_size = 24
	_name_label.pixel_size = 0.045
	_name_label.modulate = Color.WHITE
	_name_label.position = Vector3(0, 2.45, 0)
	add_child(_name_label)

	# Hitboxes so hitscan weapons can hit remote players with ZERO
	# weapon-code edits: WeaponBase calls collider.take_damage(), and
	# _is_headshot() is true when the collider is in group "enemy_head".
	# Body hitbox: capsule. Head hitbox: box in "enemy_head".
	var body := PuppetHitbox.new(self)
	body.name = "PuppetHitbox"
	body.collision_layer = 2
	body.collision_mask = 0
	body.set_meta("peer_id", peer_id)
	body.set_meta("is_network_player", true)
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.7
	shape.shape = capsule
	shape.position = Vector3(0, 0.85, 0)
	body.add_child(shape)
	body.add_to_group("network_player")
	add_child(body)

	var head_body := PuppetHitbox.new(self)
	head_body.name = "PuppetHeadHitbox"
	head_body.collision_layer = 2
	head_body.collision_mask = 0
	head_body.set_meta("peer_id", peer_id)
	head_body.set_meta("is_network_player", true)
	var head_shape := CollisionShape3D.new()
	var head_box_shape := BoxShape3D.new()
	head_box_shape.size = Vector3(0.55, 0.5, 0.55)
	head_shape.shape = head_box_shape
	head_shape.position = Vector3(0, 1.75, 0)
	head_body.add_child(head_shape)
	head_body.add_to_group("network_player")
	head_body.add_to_group("enemy_head")
	add_child(head_body)


func set_player_name(p_name: String) -> void:
	player_name = p_name
	if _name_label != null:
		_name_label.text = p_name


## Puppet-only: tint the gun mesh from the weapon id so weapon swaps are
## visible at a glance. (A real per-weapon viewmodel swap is a
## coordinator follow-up; the id is already synced.)
func set_weapon_display(weapon_id: String) -> void:
	current_weapon = weapon_id
	if _gun_mat != null and not weapon_id.is_empty():
		var h := float(hash(weapon_id) % 1000) / 1000.0
		_gun_mat.albedo_color = Color.from_hsv(h, 0.6, 0.9)


func is_sprinting() -> bool:
	return (flags & FLAG_SPRINT) != 0


func is_crouching() -> bool:
	return (flags & FLAG_CROUCH) != 0


func is_sliding() -> bool:
	return (flags & FLAG_SLIDE) != 0


func is_ads() -> bool:
	return (flags & FLAG_ADS) != 0


# --- local shim: gather + send --------------------------------------------

func _physics_process(delta: float) -> void:
	if not is_local_player or _local_player == null:
		return
	var net = get_net_manager()
	if net == null or not net.has_method("send_state"):
		return
	if net.has_method("is_online") and not net.is_online():
		return
	_send_timer -= delta
	if _send_timer > 0.0:
		return
	_send_timer = SEND_INTERVAL
	net.send_state(_gather_local_state())


func _gather_local_state() -> Dictionary:
	var p = _local_player
	var pos: Vector3 = Vector3.ZERO
	var yaw := 0.0
	var pitch := 0.0
	var vel: Vector3 = Vector3.ZERO
	if p is Node3D:
		pos = (p as Node3D).global_position
		yaw = (p as Node3D).rotation.y
		var head = (p as Node).get_node_or_null("Head")
		if head != null:
			pitch = (head as Node3D).rotation.x
	var vel_var = p.get("velocity")
	if vel_var is Vector3:
		vel = vel_var
	var hp_var = p.get("_hp")
	var hp := _local_hp
	if hp_var != null:
		hp = float(hp_var)
	var weapon := ""
	var wm = (p as Node).get_node_or_null("WeaponManager")
	if wm != null:
		if wm.has_method("current_weapon"):
			var w = wm.current_weapon()
			if w != null:
				var wid = w.get("weapon_id")
				if wid != null:
					weapon = str(wid)
		if weapon.is_empty() and wm.has_method("current_slot"):
			weapon = str(wm.current_slot())
	var fl := 0
	if p.get("_sprinting") == true:
		fl |= FLAG_SPRINT
	if p.get("_crouching") == true:
		fl |= FLAG_CROUCH
	if p.get("_sliding") == true:
		fl |= FLAG_SLIDE
	if p.has_method("is_ads") and p.is_ads():
		fl |= FLAG_ADS
	elif p.get("_ads") == true:
		fl |= FLAG_ADS
	current_weapon = weapon
	flags = fl
	return {
		"position": pos, "yaw": yaw, "pitch": pitch,
		"velocity": vel, "health": hp, "weapon": weapon, "flags": fl,
	}


# --- puppet: receive + interpolate ----------------------------------------

## Called by NetManager (never directly by the network). Snapshots are
## timestamped on RECEIPT — sender clocks are never trusted.
func receive_state(state: Dictionary) -> void:
	if is_local_player:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var pos: Vector3 = state.get("position", global_position)
	_snapshots.append({
		"t": now,
		"pos": pos,
		"yaw": float(state.get("yaw", rotation.y)),
		"pitch": float(state.get("pitch", 0.0)),
		"vel": state.get("velocity", Vector3.ZERO),
	})
	if _snapshots.size() > 4:
		_snapshots.remove_at(0)
	health = float(state.get("health", health))
	var weapon := str(state.get("weapon", current_weapon))
	if weapon != current_weapon:
		set_weapon_display(weapon)
	flags = int(state.get("flags", flags))
	# Dead puppets hide; a later snapshot with hp > 0 shows them again
	# (respawn also arrives via apply_respawn from the host broadcast).
	visible = health > 0.0


func snapshot_count() -> int:
	return _snapshots.size()


func _process(delta: float) -> void:
	if is_local_player or _snapshots.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var render_t := now - INTERP_DELAY
	var target_pos: Vector3
	var target_yaw := rotation.y
	var target_pitch := 0.0
	if render_t <= float(_snapshots[0]["t"]):
		target_pos = _snapshots[0]["pos"]
		target_yaw = float(_snapshots[0]["yaw"])
		target_pitch = float(_snapshots[0]["pitch"])
	elif render_t >= float(_snapshots[_snapshots.size() - 1]["t"]):
		var last: Dictionary = _snapshots[_snapshots.size() - 1]
		var age := minf(render_t - float(last["t"]), MAX_EXTRAPOLATE)
		target_pos = last["pos"] + (last["vel"] as Vector3) * age
		target_yaw = float(last["yaw"])
		target_pitch = float(last["pitch"])
	else:
		var i := 0
		while i < _snapshots.size() - 1 and float(_snapshots[i + 1]["t"]) < render_t:
			i += 1
		var a: Dictionary = _snapshots[i]
		var b: Dictionary = _snapshots[i + 1]
		var span := float(b["t"]) - float(a["t"])
		var f := 0.5 if span <= 0.0 else clampf((render_t - float(a["t"])) / span, 0.0, 1.0)
		target_pos = (a["pos"] as Vector3).lerp(b["pos"] as Vector3, f)
		target_yaw = lerp_angle(float(a["yaw"]), float(b["yaw"]), f)
		target_pitch = lerpf(float(a["pitch"]), float(b["pitch"]), f)
	# Teleport / respawn: snap instead of gliding across the map.
	if global_position.distance_to(target_pos) > SNAP_DISTANCE:
		global_position = target_pos
	else:
		var k := 1.0 - exp(-25.0 * delta)
		global_position = global_position.lerp(target_pos, k)
	rotation.y = lerp_angle(rotation.y, target_yaw, 1.0 - exp(-18.0 * delta))
	if _head != null:
		_head.rotation.x = lerpf(_head.rotation.x, target_pitch, 1.0 - exp(-18.0 * delta))
	# Prune snapshots older than the render window.
	while _snapshots.size() > 1 and float(_snapshots[1]["t"]) < render_t - 0.05:
		_snapshots.remove_at(0)


# --- damage entry (weapon raycasts land here) ---------------------------

## Called by WeaponBase when a hitscan ray strikes this puppet's hitbox
## (or by anything else that damages a player). NEVER applies damage
## locally: it forwards a damage REQUEST to the host via NetManager,
## which validates and broadcasts the result. The local peer is the
## attacker implicitly (the host reads the RPC sender). No-op when
## offline or for the local shim. USE ONE DAMAGE PATH: if the match
## layer is NetMatch (Worker C), its NetPuppet is the damage path and
## this node must not also be wired as a target — do not wire both.
func take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void:
	if is_local_player:
		return
	var net = get_net_manager()
	if net != null and net.has_method("request_damage"):
		net.request_damage(peer_id, amount, hit_position, is_headshot, current_weapon)


func is_dead() -> bool:
	return health <= 0.0


# --- puppet: authoritative damage / respawn -------------------------------

## Called by NetManager from the host's damage broadcast ONLY. Never
## called from a hit — clients cannot damage each other directly.
func apply_damage(amount: float, new_hp: float, attacker_id: int) -> void:
	if is_local_player:
		return
	health = new_hp
	damaged.emit(amount, attacker_id)
	if new_hp <= 0.0:
		visible = false
		died.emit()
	# Flash the body red briefly on hit.
	if _body_mesh != null and _body_mesh.material_override is StandardMaterial3D:
		var mat := _body_mesh.material_override as StandardMaterial3D
		mat.albedo_color = Color(1.0, 0.2, 0.2)
		await get_tree().create_timer(0.12).timeout
		if is_instance_valid(self) and _body_mesh != null and _body_mesh.material_override is StandardMaterial3D:
			(_body_mesh.material_override as StandardMaterial3D).albedo_color = Color(0.15, 0.75, 0.85)


func apply_respawn(spawn_pos: Vector3) -> void:
	if is_local_player:
		return
	global_position = spawn_pos
	_snapshots.clear()
	health = 100.0
	visible = true
	respawned.emit(spawn_pos)
