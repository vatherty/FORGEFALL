# Oblique grapple shots must pull inward even when the action is toggled.
extends SceneTree
var fails := 0
func check(ok: bool, label: String) -> void:
	print("PASS: " if ok else "FAIL: ", label)
	if not ok:
		fails += 1
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var p = load("res://scenes/player.tscn").instantiate()
	root.add_child(p)
	p.set_physics_process(false)
	await physics_frame
	var g = p.grapple
	p.position = Vector3(0, 10, 0)
	g._anchor = Vector3(12, 16, -12)
	g._active = true
	g._mode = g.Mode.PENDULUM
	g._rope_len = 18.0
	Input.action_release("grapple")
	var inward: Vector3 = (g._anchor - p.position - Vector3.UP).normalized()
	var tangent: Vector3 = inward.cross(Vector3.UP).normalized() * 8.0
	var v: Vector3 = g.apply_grapple(1.0 / 60.0, tangent)
	check(v.dot(inward) > 1.0, "angled grapple immediately accelerates toward anchor")
	check(absf(v.dot(tangent.normalized()) - 8.0) < 0.01, "pull preserves sideways swing momentum")
	var start: float = (p.position + Vector3.UP).distance_to(g._anchor)
	for frame in range(60):
		v = g.apply_grapple(1.0 / 60.0, v)
		p.position += v / 60.0
	var finish: float = (p.position + Vector3.UP).distance_to(g._anchor)
	check(finish < start - 6.0, "powered winch closes distance without held input: %.2f -> %.2f m" % [start, finish])
	p.velocity = v
	g.release()
	check(p.velocity == v, "releasing grapple retains momentum")
	g._active = true
	g._mode = g.Mode.PENDULUM
	g._anchor = p.position + Vector3.UP + Vector3(0.2, 0, 0)
	g.apply_grapple(1.0 / 60.0, v)
	check(not g.is_active(), "angled grapple releases when anchor reached")
	p.queue_free()
	await process_frame
	quit(1 if fails else 0)
