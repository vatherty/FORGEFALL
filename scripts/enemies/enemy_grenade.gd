# FORGEFALL — scripts/enemies/enemy_grenade.gd
# Worker 4 (enemy AI + waves).
#
# Telegraphed enemy grenade: ballistic arc to the player's position at throw
# time, accelerating beep + blinking voxel tip (Sfx "grenade_beep"), 2.2s
# fuse, then ExplosionFX.detonate() (guarded; manual radial falloff fallback).
# Thrown by Grunts/Rushers at wave >= 4 or when the director sets grenadiers.
# Enemies never throw at point-blank (thrower checks range first).

class_name EnemyGrenade
extends Node3D

const FUSE_TIME := 2.2
const FLIGHT_TIME := 1.1
const BLAST_RADIUS := 4.0
const BLAST_DAMAGE := 55.0
const GRAVITY := 18.0
const GROUND_Y := 0.09

var _vel := Vector3.ZERO
var _t := 0.0
var _beep_t := 0.0
var _beep_interval := 0.5
var _live := false
var _tip: MeshInstance3D


static func throw_at(parent: Node, from: Vector3, target: Vector3) -> void:
	var g := EnemyGrenade.new()
	parent.add_child(g)
	g.global_position = from
	# Ballistic solution for a fixed flight time: v = (to-from)/t + 0.5*g*t up.
	g._vel = (target - from) / FLIGHT_TIME + Vector3(0, 0.5 * GRAVITY * FLIGHT_TIME, 0)
	g._live = true


func _ready() -> void:
	var P := VoxelBuilder.PALETTE
	var body := VoxelBuilder.cube(Vector3(0.18, 0.18, 0.18), P["darkmetal"], Vector3.ZERO)
	add_child(body)
	_tip = VoxelBuilder.cube(Vector3(0.10, 0.06, 0.10), P["forge_orange"], Vector3(0, 0.12, 0))
	add_child(_tip)


func _physics_process(delta: float) -> void:
	if not _live:
		return
	_t += delta
	if global_position.y > GROUND_Y or _vel.y > 0.0:
		_vel.y -= GRAVITY * delta
		global_position += _vel * delta
		if global_position.y < GROUND_Y:
			global_position.y = GROUND_Y
			_vel = Vector3.ZERO
	rotation.y += delta * 9.0
	# Accelerating beep + blink: the telegraph.
	_beep_t += delta
	if _beep_t >= _beep_interval:
		_beep_t = 0.0
		_beep_interval = maxf(0.09, _beep_interval * 0.78)
		Sfx.play_3d("grenade_beep", global_position)
		_tip.visible = not _tip.visible
	if _t >= FUSE_TIME:
		_explode()


func _explode() -> void:
	_live = false
	var pos := global_position
	if ClassDB.class_exists("ExplosionFX"):
		# Goal 2: grenades use the grenade-scale explosion sound.
		ExplosionFX.detonate(pos, BLAST_RADIUS, BLAST_DAMAGE, "explosion_small")
	else:
		_fallback_blast(pos)
	if ClassDB.class_exists("DebrisPool"):
		DebrisPool.burst(pos, [Color(0.15, 0.15, 0.15), Color(1.0, 0.5, 0.1)], 10, 5.0)
	queue_free()


func _fallback_blast(pos: Vector3) -> void:
	# Manual radial damage (player only; militia don't frag each other).
	for p in get_tree().get_nodes_in_group("player"):
		var pn := p as Node3D
		if pn == null:
			continue
		var d: float = pn.global_position.distance_to(pos)
		if d < BLAST_RADIUS and p.has_method("take_damage"):
			var fall := 1.0 - d / BLAST_RADIUS
			p.take_damage(BLAST_DAMAGE * (0.4 + 0.6 * fall), pos, false)
