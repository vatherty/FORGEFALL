# Animation and content authoring

Open **Content** from the Studio map toolbar after selecting a Forgefall source project. The workshop stores versioned JSON under `assets/studio/assets`, `assets/studio/characters`, and `assets/studio/weapons`. It checks for external changes before overwriting a document.

## Moving machinery

1. Create and save a voxel asset in the Asset Workshop.
2. In Content, choose **Open Voxel Asset**, enter an animation name, travel time, and X/Y/Z end offset. Choose **Add/Replace 2-Key Track**.
3. Save and Publish. The generated voxel scene includes `AnimationPlayer` with that animation. A behavior graph can use `play_animation` and target `AnimationPlayer`.

The timeline is a position track on the asset root. Use Play, Stop, and the scrubber in the workshop's 3D preview. More keys can be edited in the JSON document; each key has `time` and `position`. Animation names must be valid identifiers.

## Characters and weapons

Create a weapon document first. Its `damage`, `range`, `cooldown`, `magazine`, and `muzzle` fields drive the published scene's `fire()` method. Optional `asset_id` uses a published voxel scene as its visual. Publish the weapon, then create a character with a `weapon_id`. A character rig has named box parts with `parent`, `position`, `size`, and `color`; a part named `Hand` receives the weapon. Optional `asset_id` adds a published voxel visual. Publish the character.

Place a map marker of type `character_spawn` with the published `character_id` to instantiate it in a Studio map. A character with `auto_fire: true` aims its mounted weapon at the nearest node in the `player` group within `sight_range` and fires according to the authored cooldown. Set `auto_fire: false` for passive characters. Runtime scripts can also call `fire()` or `reload()` on the weapon; it emits `fired(hit)` or `empty()`. The character adapter follows players with a NavigationAgent3D when a navigation path exists and falls back to direct movement otherwise. The rig preview uses box parts and has no skeletal deformation or walk cycle.

Run `godot --headless --path . --script res://tools/verify_studio_content.gd` to exercise saved/reopened animation, character, and weapon content and a physics ray hit.
