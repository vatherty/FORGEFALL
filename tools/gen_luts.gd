# gen_luts.gd — BB-9 colour-grade LUT generator / preview of record.
# Usage:
#   godot --headless --path . --script res://tools/gen_luts.gd
#
# The shipping LUTs are built at runtime by GfxSettings.lut_texture()
# from the grade table in scripts/core/gfx_settings.gd (GRADES) — a
# 32^3 ImageTexture3D per sky profile. This script exercises exactly
# that table and renders a strip-PNG preview of every LUT (32 slices of
# 32x32 laid side by side: x = slice*32 + R, y = G) into
# ~/workspace/bugbash-finish/gfx-audit/luts/ so a human can eyeball the
# grade before it ships. An identity LUT preview is a perfect RGB cube
# unwrap: red ramps within each slice, green ramps downward, slices go
# blue front-to-back; any tint/curve in the grade shows as a warp of it.
extends SceneTree


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var out_dir := "/home/hatch/workspace/bugbash-finish/gfx-audit/luts"
	DirAccess.make_dir_recursive_absolute(out_dir)
	for name in GfxSettings.GRADES:
		var grade: Dictionary = GfxSettings.GRADES[name]
		var n := GfxSettings.LUT_SIZE
		var img := Image.create(n * n, n, false, Image.FORMAT_RGB8)
		for b in n:
			for g in n:
				for r in n:
					var c := GfxSettings.grade_color(grade, Color(
						float(r) / float(n - 1), float(g) / float(n - 1), float(b) / float(n - 1)))
					img.set_pixel(b * n + r, g, Color(c.r, c.g, c.b))
		var path: String = out_dir + "/lut_" + str(name) + ".png"
		img.save_png(path)
		# Sanity: the runtime texture for this profile must exist + size.
		var tex := GfxSettings.lut_texture(name)
		print("LUT %s: gain=%s sat=%.2f contrast=%.2f -> %s (Texture3D %dx%dx%d)" % [
			name, str(grade["gain"]), float(grade["saturation"]), float(grade["contrast"]),
			path, tex.get_width(), tex.get_height(), tex.get_depth()])
	print("GEN-LUTS: done")
	quit(0)
