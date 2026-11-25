# Behavior and GDScript workspace

`behavior_workspace.tscn` is a separate editor view. Instantiate it and set `project_path` to the validated Forgefall source directory before opening or saving content. The graph tab supports creating nodes, connecting one flow output to one action input, editing node properties as JSON, dragging nodes, templates, save/reopen, and publication. The GDScript tab opens files only under the target project's `scripts/` tree, checks syntax with `GDScript.reload()`, shows the parser error and selects its line in the editor, saves with external-change detection, and lets the user mark editor breakpoints.

A behavior document is stored at `assets/studio/behaviors/<id>.json`. `behavior_compiler.gd` validates it and publishes `assets/studio/generated/behaviors/<id>.gd`. Generated scripts extend `Node3D` and may be attached to a generated map instance root. A map instance can refer to one with an optional `behavior_id` equal to the document ID. The generated script exposes `interact()`, `behavior_event(name)`, and `behavior_step(id)`. Ready and timer events start automatically. A game interaction adapter must call `interact()` on the instance; the map publisher must attach the script and ensure named child paths used by actions exist.

Node types: `ready`, `interact`, `timer`, `wait`, `toggle_visible`, `play_animation`, `area_damage`, and `emit_event`. `timer` and `wait` take `seconds`; `timer` also accepts `repeat`. `play_animation` takes a target node path and animation name. `area_damage` takes a radius and amount, queries nearby physics bodies, and calls Forgefall's `take_damage(amount, hit_position, is_headshot)`. It works on a linked voxel asset without an extra child area. `play_animation` resolves clip names without case sensitivity and falls back to the first clip when the requested one is absent. Graphs are acyclic and have at most one outgoing edge per node.

Generated scripts emit `behavior_step(id)` and accept node IDs in `debug_breakpoints`. At a matching node they emit `behavior_paused(id)` and wait for `resume_behavior()`. The graph editor does not yet attach to a running playtest, and handwritten source breakpoints remain editor marks. Parser errors select the affected line; Godot check-only output does not provide a reliable column. Generated scripts and behavior documents need map publication and an in-game interaction adapter for full gameplay integration.

Run focused validation with Godot 4.7.2:

```sh
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_behaviors.gd
```
