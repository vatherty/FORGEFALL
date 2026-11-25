# Forgefall Studio

This is a separate Godot application. Open `studio/project.godot` with the locally tested Godot 4.7.2 standard build, or run:

```sh
/path/to/Godot_v4.7.2-stable_linux.x86_64 --path studio
```

Choose **Open Project** and select the Forgefall source directory that contains the game's `project.godot`. **New Map** creates a versioned map document. **+ Block** adds a 1 m placeholder block at the camera focus, and the inspector edits its position in 0.125 m steps. **Save** writes `assets/studio/maps/<map-id>.json` in the chosen project. **Open Map** loads a saved document. **Save As** forks a new map ID. **Publish** invokes `tools/studio_generate.gd` inside the selected Forgefall project and writes a native scene under `assets/studio/generated/maps/` plus `assets/studio/generated/catalog.json`. Forgefall scripts can read it through `scripts/studio/studio_catalog.gd`. Publishing refuses a generated scene changed outside Studio. Studio stores recovery copies under Godot's `user://recovery/`, outside exported content. Opening the project offers recovery when an autosave differs from the saved map.

Current keyboard and mouse controls: right mouse drag orbits, middle mouse drag pans, and the wheel zooms. Default shortcuts are Ctrl+S to save, Ctrl+Z to undo, Ctrl+Y to redo, Delete to remove the selected instance, and F to focus it. Open **Deck Controls** and select a shortcut button to change its key; Escape cancels capture. Shortcut and divider settings persist in `user://studio_settings.cfg`. The right stick orbits, and the left stick moves the camera focus in Navigate mode when Godot receives controller events. Single-touch drag orbits; supported magnify/pan gestures zoom and pan. The target layout is 1280 × 800, with large toolbar buttons and a viewport between hierarchy and inspector. The panels can be resized using their dividers, hidden with **Hierarchy Panel** and **Inspector Panel**, and restored with **Reset Layout**.

Steam Input setup for this preview: map the right trackpad to mouse, right trigger to left click, left trigger to right click, and rear buttons to Ctrl+Z, Ctrl+Y, and F. Use Steam+X to open the on-screen keyboard for paths and numeric fields. Studio's gamepad tool palette opens with LB by default. D-pad directions move through its 3 × 3 tools, A activates, and B closes it. Outside the palette, D-pad up/down changes the selected map instance; X/Y undo/redo, and RB focuses the selection. Select a gamepad binding in **Deck Controls**, then press a new button to remap it; duplicate assignments are rejected. The right trackpad and rear buttons still depend on Steam Input mappings. Synthetic Godot events exercise gamepad button routing and touch drag, magnify, and pan behavior, but physical Steam Deck button, trackpad, and touchscreen validation remains outstanding.

Run focused tests:

```sh
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_foundation.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_controls.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_workflow.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_voxels.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_workshop.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_asset_pipeline.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_asset_tools.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_maps.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_behaviors.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_content_workshop.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path studio --script res://verify_ai.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path . --script res://tools/verify_studio_game.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --headless --path . --script res://tools/verify_studio_content.gd
/path/to/Godot_v4.7.2-stable_linux.x86_64 --path . --script res://tools/verify_studio_house.gd  # visible renderer required
```

The **Workshop** button opens a separate voxel asset workspace. New assets start with one voxel. Choose Place, Erase, Paint, Sculpt, Fill, Smooth, or Deform; select a box, sphere, or cylinder brush and radius; and edit by XYZ or left drag on the model. A drag is one undo step. Mirror toggles reflect a brush around coordinate zero. Fill recolors a connected group of voxels that share the starting material. Erase, Paint, and Fill target the hit voxel; other tools work against the hit face. Choose a palette material and edit its color. Sculpt uses the add brush; Smooth removes isolated tips and closes tightly surrounded gaps within its sphere; Deform moves the selected layer one voxel in the chosen direction when every shifted voxel has room. Layers can be added, renamed, reordered, merged into the previous layer, and hidden in the workshop preview; all layers publish into the native mesh. Collision can be enabled or disabled separately on each layer. Set Pivot at XYZ shifts the mesh origin. The whole asset collision can be Static or None. Named attachments at XYZ can be added, edited, or deleted and publish as `Marker3D` nodes. Reference images are copied into `assets/studio/references/` and shown in the workshop; Save Thumbnail writes a PNG under `assets/studio/thumbnails/`. Reference images and thumbnails are authoring aids and are not embedded in the generated scene. Save writes a stable asset document under `assets/studio/assets/`. Publish creates a chunk-meshed native scene and catalog entry. In the map workspace, **+ Asset** places a linked instance. Republishing an asset refreshes those instances when the map scene loads.

Published maps are native scenes with collision, transforms, lights, volumes, navigation regions, gameplay markers, and optional behavior scripts. The Forgefall deploy picker lists published Studio maps; a native test deploys one, spawns the player at its marker, and interacts with a generated behavior. The **Behaviors** workspace edits graph documents and GDScript, **Content** authors animated assets, characters, and weapons, and **AI Assist** previews optional map proposals as one undoable change. Publishing currently needs a Godot editor executable; set `GODOT_EDITOR_PATH` if Studio is launched from a packaged executable. The Web build offers JSON map import, editing, and download without native scene publication. See `BEHAVIORS.md`, `RELEASE.md`, and `plan.md` for commands, scope, and remaining acceptance gates.
