"""Render exported character GLBs for review with Blender in background mode.

Usage: blender --background --python render_blender.py -- ar7 launcher
"""
import sys
from pathlib import Path
import bpy
from mathutils import Vector

root = Path(__file__).resolve().parents[2]
ids = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["grunt"]
out = root / "qa" / "character_renders"
out.mkdir(parents=True, exist_ok=True)

for wid in ids:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.gltf(filepath=str(root / "assets" / "models" / "characters" / f"{wid}.glb"))
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 24
    scene.render.resolution_x = 960
    scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    scene.world.color = (0.08, 0.09, 0.10)
    cam_data = bpy.data.cameras.new("ReviewCamera")
    cam = bpy.data.objects.new("ReviewCamera", cam_data)
    scene.collection.objects.link(cam)
    cam.location = (3.0, 4.2, 2.6)
    target = Vector((0, 0, 1.0))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 3.5
    scene.camera = cam
    for name, loc, power, size in [
        ("Key", (1.0, -2.0, 3.2), 400, 2.6),
        ("Fill", (-2.0, 2.0, 1.4), 260, 2.5),
    ]:
        data = bpy.data.lights.new(name, "AREA")
        data.energy = power
        data.shape = "DISK"
        data.size = size
        obj = bpy.data.objects.new(name, data)
        scene.collection.objects.link(obj)
        obj.location = loc
        obj.rotation_euler = (target - obj.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = str(out / f"{wid}.png")
    bpy.ops.render.render(write_still=True)
    print("RENDERED", wid, scene.render.filepath)
