# Animation and content authoring

Open **Content** from the Studio map toolbar after selecting a Forgefall source project. The workshop stores versioned JSON under `assets/studio/assets`, `assets/studio/characters`, and `assets/studio/weapons`. It checks for external changes before overwriting a document.

## Moving machinery

1. Create and save a voxel asset in the Asset Workshop.
2. In Content, choose **Open Voxel Asset**, enter an animation name, travel time, and X/Y/Z end offset. Choose **Add/Replace 2-Key Track**.
3. Save and Publish. The generated voxel scene includes `AnimationPlayer` with that animation. A behavior graph can use `play_animation` and target `AnimationPlayer`.

The timeline is a position track on the asset root. Use Play, Stop, and the scrubber in the workshop's 3D preview. More keys can be edited in the JSON document; each key has `time` and `position`. Animation names must be valid identifiers.

## Characters and weapons

Create a weapon document first. Its `damage`, `range`, `cooldown`, `magazine`, and `muzzle` fields drive the published scene's `fire()` method. Optional `asset_id` uses a published voxel scene as its visual. Publish the weapon, then create a character with a `weapon_id`. A character rig has named box parts with `parent`, `position`, `size`, and `color`; a part named `Hand` receives the weapon. Optional `asset_id` adds a published voxel visual. Publish the character.

Place a map marker of type `character_spawn` with the published `character_id` to instantiate it in a Studio map. A character with `auto_fire: true` aims its mounted weapon at the nearest node in the `player` group within `sight_range` and fires according to the authored cooldown. Set `auto_fire: false` for passive characters. Runtime scripts can also call `fire()` or `reload()` on the weapon; it emits `fired(hit)` or `empty()`.

## Character motion and AI

Every published character carries a `CharacterMotion` component (`character_motion.gd`, attached by the content runtime). The rig is a tree of box parts, not a skeleton, so there is no skeletal deformation to author; instead the component animates the rig procedurally. Parts classified as legs swing around their authored joint position, arms counter-swing, and body parts bob, all driven by the character's actual movement speed with an idle/move blend that eases back to the authored pose at rest. Position leg and arm parts at their pivot (hip or shoulder) so the swing reads correctly. A part's role comes from an optional `limb` field (`leg_left`, `leg_right`, `arm_left`, `arm_right`, `body`); without it, the role is inferred from the part name (`Leg`, `Arm`, `Body`/`Torso`, with `Left`/`Right` for the side). Two document fields tune the cycle: `stride_length` (meters per step, default 0.7) and `swing_degrees` (leg/arm swing, default 28).

The same component runs a small deterministic AI: **idle** (brief pause), **patrol** (loop through the map's `waypoint` markers in name order), **chase** (nearest `player` within `sight_range`, using the navigation regions when present and direct steering otherwise), and **return** (walk home to the spawn position after losing the player for a few seconds, then resume patrol). In the game, the character adapter still drives the body while it can see a player; the motion component drives patrol and return, and never fights the adapter for the body.

Run `godot --headless --path . --script res://tools/verify_studio_content.gd` to exercise saved/reopened animation, character, and weapon content and a physics ray hit. Run `godot --headless --path studio --script res://verify_character_motion.gd` to exercise the walk cycle and the idle → patrol → chase → return state sequence headlessly.
