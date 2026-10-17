# Wall traversal regressions: momentum, steering, chaining and timed release.
extends SceneTree
var fails := 0

func check(ok: bool, label: String) -> void:
	print("PASS: " if ok else "FAIL: ", label)
	if not ok:
		fails += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var player = load("res://scenes/player.tscn").instantiate()
	root.add_child(player)
	player.set_physics_process(false)
	await physics_frame
	player._wallrunning = true
	player._wall_normal = Vector3.LEFT
	player.velocity = Vector3(0, 0, -18)
	for i in range(60):
		player._update_horizontal(1.0 / 60.0, Vector3(0.6, 0, -0.8))
	check(is_equal_approx(player.velocity.z, -18.0), "looking into wall preserves along-wall momentum for one second")
	check(player.velocity.x > 0 and player.velocity.x < 2, "wall adhesion stays small and independent of camera input")
	player._jump_buf = 0.1
	player._update_jump()
	check(is_equal_approx(player.velocity.z, -18.0), "wall jump preserves forward momentum")
	check(player.velocity.x < -7 and player.velocity.y > 6, "wall jump adds outward and upward impulse")
	check(player._can_wallrun, "wall jump permits another airborne wall run")
	check(player._wallrun_blocked_normal == Vector3.LEFT, "departed wall is blocked against immediate reattachment")
	player._wallrunning = true
	player._wall_normal = Vector3.RIGHT
	player._update_horizontal(1.0 / 60.0, Vector3.RIGHT)
	check(not player._wallrunning, "steering away releases wall")
	# Real physics ray contact, including automatic timeout and re-entry.
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1, 20, 100)
	shape.shape = box
	wall.add_child(shape)
	root.add_child(wall)
	wall.position = Vector3(1, 0, 0)
	player.position = Vector3(0, 2, 0)
	player.velocity = Vector3(0, 0, -10)
	player._wallrun_blocked_normal = Vector3.ZERO
	player._wallrun_detach_cooldown = 0
	await physics_frame
	player.wall_ray_r.force_raycast_update()
	player._update_wallrun(1.0 / 60.0, Vector3.FORWARD)
	check(player._wallrunning, "actual side-wall ray starts run")
	player.rotation.y = PI / 2.0
	player._update_wallrun(1.0 / 60.0, Vector3.FORWARD)
	check(player._wallrunning, "turning camera away keeps physical wall contact")
	player.rotation.y = 0
	player._wallrun_time = 3.0
	player._update_wallrun(1.0 / 60.0, Vector3.FORWARD)
	check(not player._wallrunning, "duration limit releases wall")
	player._wallrun_detach_cooldown = 0
	player._update_wallrun(1.0 / 60.0, Vector3.FORWARD)
	check(not player._wallrunning, "expired run cannot instantly restart on same wall")
	# Jump from the right wall and catch a different, opposing wall.
	var other := StaticBody3D.new()
	var other_shape := CollisionShape3D.new()
	other_shape.shape = box
	other.add_child(other_shape)
	root.add_child(other)
	other.position = Vector3(-2, 0, 0)
	player.position = Vector3(-1, 2, 0)
	player.velocity = Vector3(-8, 3, -18)
	player._wallrun_detach_cooldown = 0.0
	await physics_frame
	for ray in [player.wall_ray_l, player.wall_ray_r, player.wall_ray_f]:
		ray.force_raycast_update()
	player._update_wallrun(1.0 / 60.0, Vector3.FORWARD)
	check(player._wallrunning and player._wall_normal.x > 0.9, "airborne chain catches opposing wall")
	check(Vector2(player.velocity.x, player.velocity.z).length() < 20, "chaining does not multiply already-fast momentum")
	player.queue_free()
	wall.queue_free()
	other.queue_free()
	await process_frame
	quit(1 if fails else 0)
