# Tactical voxel model pipeline

The live Godot game now uses code-authored Three.js geometry exported to GLB. Three.js is a build tool here; Godot loads the finished models at runtime. The shapes use the game's MW2-era tactical palette, block silhouettes, rails, optics, armor, and hard surface details.

## Current catalog

Weapon families: AR7, LR8, SG12, SMG9, P9, BR3, HV44, Raptor, LMG, Ember, and launcher. There are 13 swappable optic, muzzle, magazine, stock, and accent modules. All weapon sources are in `tools/weapon_models/`; exported files and anchor manifests are in `assets/models/weapons/`.

Enemy bodies: grunt, rusher, marksman, brute, shredder, suppressor, bulwark, and warlord. Sources are in `tools/character_models/`; exported GLBs and pivot manifests are in `assets/models/characters/`.

Every weapon has Muzzle, Eject, Sight, Grip, Stock, and Barrel anchors. Character parts have BodyRoot, HipL, HipR, ShoulderL, ShoulderR, and Head pivots. Preserve those names when revising a model: Godot binds the mesh to existing animation, fire, hitbox, and muzzle systems by them.

## Rebuild

From the repository root:

```bash
cd tools/weapon_models
npm ci
node export.mjs ar7 lr8 sg12 smg9 p9 br3 hv44 raptor lmg ember launcher
node export_attachments.mjs
node export_characters.mjs grunt rusher marksman brute shredder suppressor bulwark warlord
```

Open the project once in Godot 4.7.2 to import the GLBs. The exported assets ship with the game; Node and Three.js are not needed on players' devices.

For review, Blender can render selected exports with `render_blender.py` and `render_characters.py`. Renders under `qa/` are review images, not game assets. `tools/preview_visual_models.gd` also captures a character with its gun from the actual Godot renderer: `godot --path . --script res://tools/preview_visual_models.gd -- grunt`.

## Runtime selection

`Arsenal.build_viewmodel` chooses a base weapon model, attaches modules at the named anchors, and retains a procedural fallback if a GLB is unavailable. A created mod still uses validated weapon gameplay data. Its generated name and description select a visual family and visible modules: for example, a “Taquito Launcher” resolves to the launcher silhouette and can carry a muzzle or magazine variant. This is a modular visual vocabulary, not arbitrary text-to-3D generation. A novel projectile effect is handled by the separate mod projectile/hook system.

`VoxelSoldier` mounts each imported body on the existing procedural animation pivots. Existing enemy AI, attack telegraphs, head hitboxes, and muzzle markers remain in use. Most enemies also carry a model from the new weapon catalog; the shredder keeps its blades. Network player puppets use the same visual catalog.

## Verification

```bash
godot --headless --editor --path . --quit
godot --headless --path . --script res://tools/verify_weapon_models.gd
godot --headless --path . --script res://tools/verify_character_models.gd
godot --headless --path . --quit-after 120
```

The exporter merges static sibling geometry by material while preserving animation pivots and weapon anchors. The 19 current exports went from 1,862 mesh nodes to 481 without losing triangles, reducing GLB size about 36%. The GLBs are generated from source so shape edits remain reproducible. When adding a new family, export its GLB, add its anchors, and update the family selection and verification lists.
