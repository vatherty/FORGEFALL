# FORGEFALL — scripts/enemies/voxel_soldier.gd
# Worker 4 (enemy AI + waves).
#
# Procedural blocky militia soldier: head (helmet + visor per type), torso,
# arms on shoulder pivots, legs on hip pivots, voxel gun in the right hand.
# Minecraft-style procedural animation: walk-cycle limb swing, aim pose,
# frozen pose on death (EnemyBase tips + sinks the body).
#
# All geometry is built from VoxelBuilder.cube() so positions are fully
# deterministic. Forward is -Z, feet at y=0 in local space.

class_name VoxelSoldier
extends Node3D

const LEG_H := 0.75
const TORSO_H := 0.75
const HEAD_S := 0.375

var _leg_l: Node3D
var _leg_r: Node3D
var _arm_l: Node3D
var _arm_r: Node3D
var _head_pivot: Node3D
var _body_root: Node3D
var _walk_phase := 0.0
var _muzzle: Marker3D


func _box(parent: Node3D, size: Vector3, color: Color, pos: Vector3) -> MeshInstance3D:
	var m := VoxelBuilder.cube(size, color, pos)
	parent.add_child(m)
	return m


func build(type_id: String) -> Dictionary:
	"""Build the rig for `type_id`; returns the rig dict used by EnemyBase."""
	var pal := _palette(type_id)
	var uniform: Color = pal["uniform"]
	var armor: Color = pal["armor"]
	var helmet_c: Color = pal["helmet"]
	var skin: Color = pal["skin"]
	var accent: Color = pal["accent"]
	var bulky := type_id == "brute" or type_id == "warlord"
	var hip_w := 0.16 if bulky else 0.14
	var shoulder_w := 0.40 if bulky else 0.36
	var shoulder_y := 1.44 if bulky else 1.42
	var leg_w := 0.30 if bulky else 0.24
	var arm_w := 0.28 if bulky else 0.22
	var torso_w := 0.62 if bulky else 0.52

	_body_root = Node3D.new()
	_body_root.name = "BodyRoot"
	add_child(_body_root)

	# Legs (hip pivots).
	for side in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.name = "HipL" if side < 0.0 else "HipR"
		hip.position = Vector3(side * hip_w, LEG_H, 0)
		_body_root.add_child(hip)
		_box(hip, Vector3(leg_w, LEG_H, 0.26), uniform, Vector3(0, -LEG_H * 0.5, 0))
		_box(hip, Vector3(leg_w + 0.02, 0.16, 0.30), armor, Vector3(0, -LEG_H + 0.08, 0.02))  # boot
		if side < 0.0:
			_leg_l = hip
		else:
			_leg_r = hip

	# Torso.
	var torso_y := LEG_H + TORSO_H * 0.5
	_box(_body_root, Vector3(torso_w, TORSO_H, 0.30), uniform, Vector3(0, torso_y, 0))
	_box(_body_root, Vector3(torso_w + 0.04, 0.34, 0.36), armor, Vector3(0, torso_y + 0.08, 0))  # vest
	_box(_body_root, Vector3(0.20, 0.14, 0.05), accent, Vector3(0.12, torso_y - 0.18, 0.17))  # pouch

	# Arms (shoulder pivots).
	for side in [-1.0, 1.0]:
		var sh := Node3D.new()
		sh.name = "ShoulderL" if side < 0.0 else "ShoulderR"
		sh.position = Vector3(side * shoulder_w, shoulder_y, 0)
		_body_root.add_child(sh)
		_box(sh, Vector3(arm_w, 0.62, 0.24), uniform, Vector3(0, -0.31, 0))
		_box(sh, Vector3(arm_w, 0.16, 0.24), skin, Vector3(0, -0.68, 0))  # hand
		if bulky:
			_box(sh, Vector3(arm_w + 0.06, 0.30, 0.30), armor, Vector3(0, -0.16, 0))  # pauldron
		if side < 0.0:
			_arm_l = sh
		else:
			_arm_r = sh

	# Head (neck pivot) + helmet + visor.
	var neck_y := LEG_H + TORSO_H + 0.02
	_head_pivot = Node3D.new()
	_head_pivot.name = "Head"
	_head_pivot.position = Vector3(0, neck_y, 0)
	_body_root.add_child(_head_pivot)
	_box(_head_pivot, Vector3(HEAD_S, HEAD_S, HEAD_S), skin, Vector3(0, HEAD_S * 0.5, 0))
	_box(_head_pivot, Vector3(HEAD_S + 0.06, 0.16, HEAD_S + 0.06), helmet_c, Vector3(0, HEAD_S - 0.02, 0))
	_box(_head_pivot, Vector3(HEAD_S * 0.8, 0.09, 0.04), accent, Vector3(0, HEAD_S * 0.55, HEAD_S * 0.5 + 0.01))  # visor
	if type_id == "marksman":
		# Ghillie-ish strips.
		for i in 3:
			_box(_head_pivot, Vector3(0.05, 0.30, 0.42), pal["ghillie"], Vector3(-0.14 + 0.14 * i, 0.30, -0.05))
		_box(_body_root, Vector3(torso_w + 0.10, 0.50, 0.06), pal["ghillie"], Vector3(0, torso_y, -0.18))

	# Voxel gun parented to the right arm so it follows the aim pose.
	_build_gun(type_id, pal)
	# Goal 3: per-type silhouette extras — the shield wall, the boss crest.
	if type_id == "bulwark":
		# Riot shield: covers the torso front (y ~0.55–1.45), head stays
		# exposed above it — matches the headshot-bypasses-shield rule.
		_box(_body_root, Vector3(0.92, 1.0, 0.08), Color(0.5, 0.65, 0.8),
			Vector3(0, 1.0, -0.26))
		_box(_body_root, Vector3(0.30, 0.30, 0.03), Color(0.4, 1.0, 0.3),
			Vector3(0, 1.05, -0.31))
	if type_id == "warlord":
		# Gold war-crest on the helmet + broad gold pauldrons: reads BOSS.
		_box(_head_pivot, Vector3(0.10, 0.30, 0.42), Color(1.0, 0.75, 0.15),
			Vector3(0, HEAD_S + 0.12, -0.02))
		_box(_body_root, Vector3(0.30, 0.16, 0.40), Color(1.0, 0.75, 0.15),
			Vector3(-0.42, shoulder_y + 0.06, 0))
		_box(_body_root, Vector3(0.30, 0.16, 0.40), Color(1.0, 0.75, 0.15),
			Vector3(0.42, shoulder_y + 0.06, 0))

	# Head hitbox: Area3D in group "enemy_head" (weapon worker raycasts with
	# collide_with_areas=true; a hit here = headshot).
	var head_area := Area3D.new()
	head_area.name = "HeadHitbox"
	head_area.collision_layer = 0
	head_area.collision_mask = 0
	head_area.monitoring = false
	head_area.monitorable = true
	head_area.position = Vector3(0, HEAD_S * 0.5, 0)
	_head_pivot.add_child(head_area)
	head_area.add_to_group("enemy_head")
	var head_shape := CollisionShape3D.new()
	var head_box := BoxShape3D.new()
	head_box.size = Vector3(HEAD_S + 0.10, HEAD_S + 0.10, HEAD_S + 0.10)
	head_shape.shape = head_box
	head_area.add_child(head_shape)
	head_shape.add_to_group("enemy_head")

	reset_pose()
	return {
		"type": type_id,
		"body_root": _body_root,
		"leg_l": _leg_l, "leg_r": _leg_r,
		"arm_l": _arm_l, "arm_r": _arm_r,
		"head": _head_pivot,
		"muzzle": _muzzle,
		"head_hitbox": head_area,
	}


func _build_gun(type_id: String, pal: Dictionary) -> void:
	var gunmetal: Color = pal["gun"]
	var wood: Color = pal["wood"]
	var gun := Node3D.new()
	gun.name = "Gun"
	# Grip at the hand, barrel pointing forward (-Z) once arms raise.
	gun.position = Vector3(0, -0.72, 0.05)
	_arm_r.add_child(gun)
	match type_id:
		"shredder":
			# Twin blades, no gun: a long blade on the right arm, a short
			# one on the left (built on _arm_l directly).
			_box(gun, Vector3(0.05, 0.08, 0.55), Color(0.85, 0.88, 0.92),
				Vector3(0, 0.0, -0.30))
			_box(gun, Vector3(0.10, 0.10, 0.10), pal["armor"],
				Vector3(0, -0.02, -0.02))
			var offhand := Node3D.new()
			offhand.name = "OffhandBlade"
			offhand.position = Vector3(0, -0.72, 0.05)
			_arm_l.add_child(offhand)
			_box(offhand, Vector3(0.05, 0.08, 0.38), Color(0.85, 0.88, 0.92),
				Vector3(0, 0.0, -0.22))
		"suppressor":
			# Long heavy gun + drum + suppressor shroud: sustained fire.
			_box(gun, Vector3(0.11, 0.14, 0.95), gunmetal, Vector3(0, 0.03, -0.46))
			_box(gun, Vector3(0.16, 0.18, 0.20), gunmetal, Vector3(0, -0.14, -0.10))
			_box(gun, Vector3(0.09, 0.09, 0.30), pal["accent"], Vector3(0, 0.03, -0.85))
		"bulwark":
			_box(gun, Vector3(0.10, 0.14, 0.45), gunmetal, Vector3(0, 0.02, -0.22))
			_box(gun, Vector3(0.08, 0.16, 0.10), gunmetal, Vector3(0, -0.10, -0.12))
		"warlord":
			# Oversized LMG + gold trim: the boss's gun is visibly bigger.
			_box(gun, Vector3(0.20, 0.24, 0.80), gunmetal, Vector3(0, 0.0, -0.36))
			_box(gun, Vector3(0.26, 0.26, 0.26), gunmetal, Vector3(0, -0.20, -0.12))
			_box(gun, Vector3(0.22, 0.06, 0.50), Color(1.0, 0.75, 0.15),
				Vector3(0, 0.14, -0.30))
		"rusher":
			_box(gun, Vector3(0.11, 0.14, 0.42), gunmetal, Vector3(0, 0.02, -0.20))
			_box(gun, Vector3(0.13, 0.16, 0.18), wood, Vector3(0, -0.02, -0.02))  # pump
		"marksman":
			_box(gun, Vector3(0.09, 0.12, 0.80), gunmetal, Vector3(0, 0.03, -0.38))
			_box(gun, Vector3(0.10, 0.10, 0.22), wood, Vector3(0, -0.03, 0.02))  # stock
			_box(gun, Vector3(0.08, 0.08, 0.16), gunmetal, Vector3(0, 0.12, -0.10))  # scope
		"brute":
			_box(gun, Vector3(0.16, 0.20, 0.62), gunmetal, Vector3(0, 0.0, -0.28))
			_box(gun, Vector3(0.20, 0.20, 0.20), gunmetal, Vector3(0, -0.16, -0.10))  # drum
			_box(gun, Vector3(0.10, 0.14, 0.20), wood, Vector3(0, -0.06, 0.12))
		_:
			_box(gun, Vector3(0.10, 0.14, 0.55), gunmetal, Vector3(0, 0.02, -0.26))
			_box(gun, Vector3(0.08, 0.16, 0.10), gunmetal, Vector3(0, -0.10, -0.12))  # mag
			_box(gun, Vector3(0.09, 0.12, 0.18), wood, Vector3(0, -0.02, 0.05))
	_muzzle = Marker3D.new()
	_muzzle.name = "Muzzle"
	_muzzle.position = Vector3(0, 0.03, -0.70)
	gun.add_child(_muzzle)


func _palette(type_id: String) -> Dictionary:
	var P := VoxelBuilder.PALETTE
	var skin: Color = P["tan"]
	var wood: Color = P["wood"]
	var gun: Color = P["gunmetal"]
	match type_id:
		"rusher":
			return {"uniform": P["rust"], "armor": P["darkmetal"], "helmet": P["rust"],
				"skin": skin, "accent": Color(1.0, 0.25, 0.15), "gun": gun, "wood": wood,
				"ghillie": P["canvas"]}
		"marksman":
			return {"uniform": P["darkmetal"], "armor": P["gunmetal"], "helmet": P["darkmetal"],
				"skin": skin, "accent": P["tan"], "gun": gun, "wood": wood,
				"ghillie": P["canvas"]}
		"brute":
			return {"uniform": P["gunmetal"], "armor": P["darkmetal"], "helmet": P["gunmetal"],
				"skin": skin, "accent": P["rust"], "gun": P["darkmetal"], "wood": wood,
				"ghillie": P["canvas"]}
		"shredder":
			return {"uniform": Color(0.35, 0.08, 0.08), "armor": P["darkmetal"],
				"helmet": Color(0.35, 0.08, 0.08),
				"skin": skin, "accent": Color(1.0, 0.2, 0.6), "gun": gun, "wood": wood,
				"ghillie": P["canvas"]}
		"suppressor":
			return {"uniform": Color(0.25, 0.1, 0.4), "armor": P["gunmetal"],
				"helmet": Color(0.25, 0.1, 0.4),
				"skin": skin, "accent": Color(0.7, 0.3, 1.0), "gun": gun, "wood": wood,
				"ghillie": P["canvas"]}
		"bulwark":
			return {"uniform": P["gunmetal"], "armor": Color(0.5, 0.65, 0.8),
				"helmet": Color(0.5, 0.65, 0.8),
				"skin": skin, "accent": Color(0.4, 1.0, 0.3), "gun": gun, "wood": wood,
				"ghillie": P["canvas"]}
		"warlord":
			return {"uniform": Color(0.5, 0.1, 0.1), "armor": P["darkmetal"],
				"helmet": Color(1.0, 0.75, 0.15),
				"skin": skin, "accent": Color(1.0, 0.75, 0.15), "gun": P["darkmetal"],
				"wood": wood, "ghillie": P["canvas"]}
		_:
			return {"uniform": P["olive"], "armor": P["darkmetal"], "helmet": P["olive"],
				"skin": skin, "accent": P["tan"], "gun": gun, "wood": wood,
				"ghillie": P["canvas"]}


func reset_pose() -> void:
	_walk_phase = 0.0
	if _body_root != null:
		_body_root.position = Vector3.ZERO
		_body_root.rotation = Vector3.ZERO
	for pivot in [_leg_l, _leg_r, _arm_l, _arm_r, _head_pivot]:
		if pivot != null:
			pivot.rotation = Vector3.ZERO


func animate(dt: float, planar_speed: float, aiming: bool, _dead: bool) -> void:
	# Death pose is owned by EnemyBase (tip + sink); here we just freeze.
	if _dead:
		return
	var move_k := clampf(planar_speed / 3.0, 0.0, 1.0)
	_walk_phase += dt * (3.0 + planar_speed * 2.4)
	var swing := sin(_walk_phase) * 0.65 * move_k
	_leg_l.rotation.x = swing
	_leg_r.rotation.x = -swing
	if aiming:
		# Arms raise forward (-Z); the gun (child of arm_r) points at the target.
		_arm_l.rotation.x = lerpf(_arm_l.rotation.x, 1.45, minf(1.0, 12.0 * dt))
		_arm_r.rotation.x = lerpf(_arm_r.rotation.x, 1.45, minf(1.0, 12.0 * dt))
		_head_pivot.rotation.x = 0.08
	else:
		_arm_l.rotation.x = -swing * 0.8
		_arm_r.rotation.x = swing * 0.8
		_head_pivot.rotation.x = 0.0
	# Torso bob while moving.
	_body_root.position.y = absf(sin(_walk_phase)) * 0.045 * move_k
