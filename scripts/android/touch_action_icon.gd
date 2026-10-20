# Resolution-independent white glyphs for the mobile action discs.
extends Control

var action := ""
const INK := Color(0.96, 0.96, 0.94, 0.95)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)

func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.24
	match action:
		"move":
			for direction in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
				var tip: Vector2 = c + direction * r * 1.8
				var base: Vector2 = c + direction * r * 1.5
				var side: Vector2 = direction.orthogonal() * r * 0.18
				draw_colored_polygon(PackedVector2Array([tip, base + side, base - side]), INK)
		"ads":
			draw_arc(c, r, 0, TAU, 40, INK, 2.0, true)
			for v in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
				draw_line(c + v * r * 0.65, c + v * r * 1.4, INK, 2.0, true)
			draw_circle(c, 2.0, INK)
		"fire":
			var points := PackedVector2Array([Vector2(-0.35, 0.9), Vector2(0.35, 0.9), Vector2(0.35, -0.4), Vector2(0, -1), Vector2(-0.35, -0.4)])
			for i in points.size():
				points[i] = c + points[i].rotated(-0.6) * r
			draw_colored_polygon(points, INK)
		"reload":
			draw_arc(c, r, -PI * 0.8, PI * 0.7, 32, INK, 3.0, true)
			draw_line(c + Vector2(-r, -r * 0.6), c + Vector2(-r, r * 0.1), INK, 4.0, true)
		"grapple":
			draw_line(c + Vector2(0, -r), c + Vector2(0, r * 0.3), INK, 4.0, true)
			draw_arc(c + Vector2(-r * 0.4, r * 0.3), r * 0.4, 0, PI, 20, INK, 4.0, true)
			draw_line(c + Vector2(-r * 0.8, r * 0.3), c + Vector2(-r * 0.8, -r * 0.1), INK, 3.0, true)
		"jump", "crouch":
			var low := r * 0.45 if action == "crouch" else 0.0
			draw_circle(c + Vector2(0, -r * 0.8 + low), r * 0.22, INK)
			var hip := c + Vector2(-r * 0.15, r * 0.25 + low)
			draw_line(c + Vector2(0, -r * 0.4 + low), hip, INK, 5.0, true)
			draw_polyline(PackedVector2Array([hip, c + Vector2(r * 0.65, r * 0.5), c + Vector2(r * 0.5, r)]), INK, 4.0, true)
			draw_polyline(PackedVector2Array([hip, c + Vector2(-r * 0.55, r * 0.6), c + Vector2(-r * 0.75, r)]), INK, 4.0, true)
			draw_polyline(PackedVector2Array([c + Vector2(-r * 0.6, -r * 0.5), c + Vector2(0, -r * 0.1 + low), c + Vector2(r * 0.7, -r * 0.4)]), INK, 3.0, true)
