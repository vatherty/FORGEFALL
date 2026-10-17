# FORGEFALL — scripts/enemies/voxel_soldier.gd
#
# ENEMIES REWORK (2026-10-16): full model + animation redo.
#
# MODEL: rebuilt voxel/low-poly militia soldier, same art direction as the
# rest of the game (VoxelBuilder.cube boxes only). Every type now has a
# distinct silhouette + dressing: per-type helmet, backpack, chest rig,
# knee pads, belt, shoulder dressing, and a per-type weapon. The rig
# contract is UNCHANGED: legs on hip pivots, arms on shoulder pivots,
# head on a neck pivot, gun parented to the right arm, muzzle marker,
# head hitbox Area3D in group "enemy_head". EnemyBase reads the same
# rig dict keys as before.
#
# ANIMATION: fully procedural / code-driven, no authored rigs.
# animate_full(dt, params) drives: locomotion (walk-cycle limb swing,
# torso bob + forward lean, strafe tilt + leg splay), idle breathing +
# head scanning, aim pose, attack WINDUP (arms draw back, torso leans
# back, chest lamp brightens — the telegraph the player reads), STRIKE
# (fast arm chop + torso lunge), HIT REACTION / flinch (torso snap-back,
# head snap, arms flail), CROUCH (marksman aim), and DEATH (knees
# buckle -> tip face-down -> settle; the sink is EnemyBase._death_tick).
# animate(dt, planar_speed, aiming, dead) is kept as a legacy wrapper.
#
# Forward is -Z, feet at y=0 in local space.

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
var _idle_t := 0.0
var _muzzle: Marker3D
var _lamp: MeshInstance3D
var _lamp_mat: StandardMaterial3D
var _lamp_color := Color(1.0, 0.75, 0.2)


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
	_lamp_color = accent
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

	# Legs (hip pivots) + boots + knee pads.
	for side in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.name = "HipL" if side < 0.0 else "HipR"
		hip.position = Vector3(side * hip_w, LEG_H, 0)
		_body_root.add_child(hip)
		_box(hip, Vector3(leg_w, LEG_H, 0.26), uniform, Vector3(0, -LEG_H * 0.5, 0))
		_box(hip, Vector3(leg_w + 0.02, 0.16, 0.30), armor, Vector3(0, -LEG_H + 0.08, 0.02))  # boot
		_box(hip, Vector3(leg_w + 0.02, 0.18, 0.05), armor, Vector3(0, -0.45, -0.15))  # knee pad
		if side < 0.0:
			_leg_l = hip
		else:
			_leg_r = hip

	# Torso + vest + chest rig + belt + backpack.
	var torso_y := LEG_H + TORSO_H * 0.5
	_box(_body_root, Vector3(torso_w, TORSO_H, 0.30), uniform, Vector3(0, torso_y, 0))
	_box(_body_root, Vector3(torso_w + 0.04, 0.34, 0.36), armor, Vector3(0, torso_y + 0.08, 0))  # vest
	_box(_body_root, Vector3(0.16, 0.20, 0.05), accent, Vector3(-0.13, torso_y + 0.02, 0.18))  # rig pouch L
	_box(_body_root, Vector3(0.16, 0.20, 0.05), accent, Vector3(0.13, torso_y + 0.02, 0.18))  # rig pouch R
	_box(_body_root, Vector3(torso_w + 0.02, 0.10, 0.32), armor, Vector3(0, LEG_H + 0.05, 0))  # belt
	_box(_body_root, Vector3(torso_w * 0.72, 0.52, 0.16), armor, Vector3(0, torso_y, 0.24))  # backpack
	if type_id == "brute" or type_id == "warlord":
		_box(_body_root, Vector3(torso_w * 0.8, 0.62, 0.20), armor, Vector3(0, torso_y, 0.30))  # heavy pack
		_box(_body_root, Vector3(0.10, 0.55, 0.06), accent, Vector3(-0.12, torso_y + 0.05, -0.19))  # ammo belt
		_box(_body_root, Vector3(0.10, 0.55, 0.06), accent, Vector3(0.12, torso_y + 0.05, -0.19))

	# Arms (shoulder pivots) + hands + arm guards.
	for side in [-1.0, 1.0]:
		var sh := Node3D.new()
		sh.name = "ShoulderL" if side < 0.0 else "ShoulderR"
		sh.position = Vector3(side * shoulder_w, shoulder_y, 0)
		_body_root.add_child(sh)
		_box(sh, Vector3(arm_w, 0.62, 0.24), uniform, Vector3(0, -0.31, 0))
		_box(sh, Vector3(arm_w, 0.16, 0.24), skin, Vector3(0, -0.68, 0))  # hand
		_box(sh, Vector3(arm_w + 0.04, 0.18, 0.28), armor, Vector3(0, -0.42, 0))  # forearm guard
		if bulky:
			_box(sh, Vector3(arm_w + 0.06, 0.30, 0.30), armor, Vector3(0, -0.16, 0))  # pauldron
		if side < 0.0:
			_arm_l = sh
		else:
			_arm_r = sh

	# Head (neck pivot) + per-type helmet / mask.
	var neck_y := LEG_H + TORSO_H + 0.02
	_head_pivot = Node3D.new()
	_head_pivot.name = "Head"
	_head_pivot.position = Vector3(0, neck_y, 0)
	_body_root.add_child(_head_pivot)
	_box(_head_pivot, Vector3(HEAD_S, HEAD_S, HEAD_S), skin, Vector3(0, HEAD_S * 0.5, 0))
	_dress_head(type_id, pal, helmet_c, accent)
	_dress_type_extras(type_id, pal, torso_w, torso_y, shoulder_w, shoulder_y)

	# Telegraph lamp: left shoulder, brightens with attack wind-up so the
	# telegraph reads at a glance even before the pose registers.
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_lamp_mat.albedo_color = Color(0.15, 0.15, 0.15)
	_lamp = MeshInstance3D.new()
	_lamp.name = "TelegraphLamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.10, 0.06, 0.06)
	_lamp.mesh = lamp_mesh
	_lamp.material_override = _lamp_mat
	_lamp.position = Vector3(-shoulder_w, shoulder_y + 0.14, 0.05)
	_body_root.add_child(_lamp)

	# Voxel gun parented to the right arm so it follows the aim pose.
	_build_gun(type_id, pal)

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


## Per-type head dressing: distinct helmet / mask / hood silhouettes.
func _dress_head(type_id: String, pal: Dictionary, helmet_c: Color, accent: Color) -> void:
	match type_id:
		"rusher":
			# Flat cap + goggles: the fast one reads lean, not armoured.
			_box(_head_pivot, Vector3(HEAD_S + 0.04, 0.08, HEAD_S + 0.10), helmet_c, Vector3(0, HEAD_S + 0.03, 0.02))
			_box(_head_pivot, Vector3(HEAD_S + 0.06, 0.06, 0.04), accent, Vector3(0, HEAD_S * 0.62, HEAD_S * 0.5 + 0.01))
		"marksman":
			# Hood + ghillie fringe + scope glint on the helmet.
			_box(_head_pivot, Vector3(HEAD_S + 0.10, 0.30, HEAD_S + 0.10), helmet_c, Vector3(0, HEAD_S * 0.45, -0.02))
			for i in 3:
				_box(_head_pivot, Vector3(0.05, 0.30, 0.42), pal["ghillie"], Vector3(-0.14 + 0.14 * i, 0.30, -0.05))
			_box(_head_pivot, Vector3(0.06, 0.06, 0.06), accent, Vector3(0.12, HEAD_S + 0.02, 0.10))
		"shredder":
			# Full face mask + mohawk spike strip: the melee threat.
			_box(_head_pivot, Vector3(HEAD_S + 0.04, 0.26, 0.04), accent, Vector3(0, HEAD_S * 0.45, HEAD_S * 0.5 + 0.01))
			_box(_head_pivot, Vector3(0.06, 0.22, 0.30), helmet_c, Vector3(0, HEAD_S + 0.08, -0.02))
		"suppressor":
			# Headset + helmet: comms for the fire-support gunner.
			_box(_head_pivot, Vector3(HEAD_S + 0.06, 0.16, HEAD_S + 0.06), helmet_c, Vector3(0, HEAD_S - 0.02, 0))
			_box(_head_pivot, Vector3(0.06, 0.20, 0.20), accent, Vector3(-HEAD_S * 0.55, HEAD_S * 0.5, 0))
			_box(_head_pivot, Vector3(0.06, 0.20, 0.20), accent, Vector3(HEAD_S * 0.55, HEAD_S * 0.5, 0))
		"bulwark":
			# Heavy helm with a narrow visor slit: the wall.
			_box(_head_pivot, Vector3(HEAD_S + 0.08, 0.24, HEAD_S + 0.08), helmet_c, Vector3(0, HEAD_S - 0.02, 0))
			_box(_head_pivot, Vector3(HEAD_S * 0.7, 0.05, 0.04), accent, Vector3(0, HEAD_S * 0.55, HEAD_S * 0.5 + 0.01))
		"warlord":
			# Gold war-crest + crown band: reads BOSS at any distance.
			_box(_head_pivot, Vector3(HEAD_S + 0.06, 0.16, HEAD_S + 0.06), helmet_c, Vector3(0, HEAD_S - 0.02, 0))
			_box(_head_pivot, Vector3(0.10, 0.30, 0.42), Color(1.0, 0.75, 0.15), Vector3(0, HEAD_S + 0.12, -0.02))
			_box(_head_pivot, Vector3(HEAD_S * 0.8, 0.09, 0.04), accent, Vector3(0, HEAD_S * 0.55, HEAD_S * 0.5 + 0.01))
		"brute":
			# Slab helm + chin guard: the juggernaut.
			_box(_head_pivot, Vector3(HEAD_S + 0.08, 0.20, HEAD_S + 0.08), helmet_c, Vector3(0, HEAD_S - 0.02, 0))
			_box(_head_pivot, Vector3(HEAD_S * 0.8, 0.09, 0.04), accent, Vector3(0, HEAD_S * 0.55, HEAD_S * 0.5 + 0.01))
		_:
			# Grunt: standard helmet + visor.
			_box(_head_pivot, Vector3(HEAD_S + 0.06, 0.16, HEAD_S + 0.06), helmet_c, Vector3(0, HEAD_S - 0.02, 0))
			_box(_head_pivot, Vector3(HEAD_S * 0.8, 0.09, 0.04), accent, Vector3(0, HEAD_S * 0.55, HEAD_S * 0.5 + 0.01))


## Per-type body extras: shields, capes, antennae, spikes.
func _dress_type_extras(type_id: String, pal: Dictionary, torso_w: float, torso_y: float, shoulder_w: float, shoulder_y: float) -> void:
	match type_id:
		"marksman":
			_box(_body_root, Vector3(torso_w + 0.10, 0.50, 0.06), pal["ghillie"], Vector3(0, torso_y, -0.18))
		"shredder":
			# Spiked pauldrons: two angled spikes per shoulder.
			_box(_body_root, Vector3(0.06, 0.30, 0.06), pal["accent"], Vector3(-shoulder_w, shoulder_y + 0.18, 0))
			_box(_body_root, Vector3(0.06, 0.30, 0.06), pal["accent"], Vector3(shoulder_w, shoulder_y + 0.18, 0))
		"suppressor":
			# Whip antenna on the pack + extra ammo pouch.
			_box(_body_root, Vector3(0.03, 0.85, 0.03), pal["accent"], Vector3(0.22, torso_y + 0.55, 0.28))
			_box(_body_root, Vector3(0.20, 0.16, 0.06), pal["accent"], Vector3(0, torso_y - 0.28, 0.19))
		"bulwark":
			# Riot shield: covers the torso front (y ~0.55–1.45), head stays
			# exposed above it — matches the headshot-bypasses-shield rule.
			_box(_body_root, Vector3(0.92, 1.0, 0.08), Color(0.5, 0.65, 0.8),
				Vector3(0, 1.0, -0.26))
			_box(_body_root, Vector3(0.30, 0.30, 0.03), Color(0.4, 1.0, 0.3),
				Vector3(0, 1.05, -0.31))
		"warlord":
			# Broad gold pauldrons + dark cape panel behind the torso.
			_box(_body_root, Vector3(0.30, 0.16, 0.40), Color(1.0, 0.75, 0.15),
				Vector3(-0.42, shoulder_y + 0.06, 0))
			_box(_body_root, Vector3(0.30, 0.16, 0.40), Color(1.0, 0.75, 0.15),
				Vector3(0.42, shoulder_y + 0.06, 0))
			_box(_body_root, Vector3(0.72, 0.95, 0.05), Color(0.45, 0.08, 0.08),
				Vector3(0, torso_y - 0.05, 0.30))


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
	_idle_t = 0.0
	if _body_root != null:
		_body_root.position = Vector3.ZERO
		_body_root.rotation = Vector3.ZERO
	for pivot in [_leg_l, _leg_r, _arm_l, _arm_r, _head_pivot]:
		if pivot != null:
			pivot.rotation = Vector3.ZERO
	_set_lamp(0.0)


func _set_lamp(windup: float) -> void:
	if _lamp_mat == null:
		return
	# Dim idle -> bright accent at full wind-up; the lamp is the readable
	# telegraph even when the pose is hard to read at distance.
	_lamp_mat.albedo_color = Color(0.15, 0.15, 0.15).lerp(_lamp_color, clampf(windup, 0.0, 1.0))
	if _lamp != null:
		_lamp.scale = Vector3.ONE * (1.0 + 0.4 * clampf(windup, 0.0, 1.0))


## Full procedural animation driver. Params (all optional, 0..1 unless noted):
## speed (m/s), aiming, windup, strike, flinch, strafe (-1..1),
## crouch, death (0..1 crumple progress).
func animate_full(dt: float, params: Dictionary) -> void:
	var spd := float(params.get("speed", 0.0))
	var aiming := bool(params.get("aiming", false))
	var windup := clampf(float(params.get("windup", 0.0)), 0.0, 1.0)
	var strike := clampf(float(params.get("strike", 0.0)), 0.0, 1.0)
	var flinch := clampf(float(params.get("flinch", 0.0)), 0.0, 1.0)
	var strafe := clampf(float(params.get("strafe", 0.0)), -1.0, 1.0)
	var crouch := clampf(float(params.get("crouch", 0.0)), 0.0, 1.0)
	var death := clampf(float(params.get("death", 0.0)), 0.0, 1.0)
	_idle_t += dt
	if death > 0.0:
		_apply_death_pose(death)
		_set_lamp(0.0)
		return
	var move_k := clampf(spd / 3.0, 0.0, 1.0)
	if move_k > 0.02:
		_walk_phase += dt * (4.0 + spd * 2.2)
	var swing := sin(_walk_phase) * 0.70 * move_k
	# Legs: walk swing + crouch fold + strafe splay.
	var fold := crouch * 0.70
	_leg_l.rotation.x = swing - fold
	_leg_r.rotation.x = -swing - fold
	_leg_l.rotation.z = strafe * 0.14
	_leg_r.rotation.z = -strafe * 0.14
	# Arms: aim/windup/strike pose, else counter-swing with the legs.
	if aiming or windup > 0.0 or strike > 0.0:
		# Aim = 1.45; wind-up draws the weapon back/up (0.60); the
		# strike chops forward (2.00). Lerped so poses blend, never snap.
		var arm_target := 1.45 - windup * 0.85 + strike * 0.55
		_arm_l.rotation.x = lerpf(_arm_l.rotation.x, arm_target, minf(1.0, 18.0 * dt))
		_arm_r.rotation.x = lerpf(_arm_r.rotation.x, arm_target, minf(1.0, 18.0 * dt))
	else:
		_arm_l.rotation.x = -swing * 0.8
		_arm_r.rotation.x = swing * 0.8
	_arm_l.rotation.z = 0.08 + strafe * 0.10 + flinch * 0.50
	_arm_r.rotation.z = -0.08 - strafe * 0.10 - flinch * 0.50
	# Torso: forward lean with speed, lean BACK on wind-up / flinch,
	# lunge forward on the strike; bob + breathing; strafe tilt.
	var lean := -move_k * 0.10 + windup * 0.30 - strike * 0.38 + flinch * 0.35
	_body_root.rotation.x = lerpf(_body_root.rotation.x, lean, minf(1.0, 14.0 * dt))
	_body_root.rotation.z = -strafe * 0.10
	var bob := absf(sin(_walk_phase)) * 0.05 * move_k
	var breathe := sin(_idle_t * 2.0) * 0.012 * (1.0 - move_k)
	_body_root.position.y = bob + breathe - crouch * 0.30
	# Head: scan while idle, steady while aiming, snap on flinch.
	var head_yaw := 0.0
	if not aiming and move_k < 0.1 and windup <= 0.0:
		head_yaw = sin(_idle_t * 0.6) * 0.35
	_head_pivot.rotation.y = lerpf(_head_pivot.rotation.y, head_yaw, minf(1.0, 4.0 * dt))
	_head_pivot.rotation.x = 0.08 if aiming else (-windup * 0.18 + flinch * 0.30)
	_set_lamp(windup)


## Death crumple: knees buckle (0–0.35), tip face-down (0.35–0.75),
## settle. The vertical sink is EnemyBase._death_tick.
func _apply_death_pose(p: float) -> void:
	var buckle := clampf(p / 0.35, 0.0, 1.0)
	var tip := clampf((p - 0.35) / 0.40, 0.0, 1.0)
	_leg_l.rotation.x = -1.25 * buckle
	_leg_r.rotation.x = -1.25 * buckle
	_leg_l.rotation.z = 0.10
	_leg_r.rotation.z = -0.10
	_arm_l.rotation.x = -0.40 + tip * 0.40
	_arm_r.rotation.x = -0.40 + tip * 0.40
	_arm_l.rotation.z = 0.95 * tip
	_arm_r.rotation.z = -0.95 * tip
	_body_root.position.y = -0.45 * buckle
	_body_root.rotation.x = -1.35 * tip
	_body_root.rotation.z = 0.0
	_head_pivot.rotation.x = 0.45 * tip
	_head_pivot.rotation.y = 0.30 * tip


## Legacy wrapper: same signature as before the rework.
func animate(dt: float, planar_speed: float, aiming: bool, _dead: bool) -> void:
	animate_full(dt, {"speed": planar_speed, "aiming": aiming,
		"death": 1.0 if _dead else 0.0})
