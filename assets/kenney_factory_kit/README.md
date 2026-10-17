# Kenney Factory Kit v3.0 — provenance + use in FORGEFALL

Source: https://kenney.nl/assets/factory-kit (downloaded 2026-10-16)
Archive kept here for provenance: `kenney_factory-kit_3.0.zip` (4.5 MB).

## License — verified in-pack (CC0)

The zip's own `License.txt` (extracted alongside this file) states:

> License: (Creative Commons Zero, CC0)
> http://creativecommons.org/publicdomain/zero/1.0/
> You can use this content for personal, educational, and commercial purposes.
> Support by crediting 'Kenney' or 'www.kenney.nl' (this is not a requirement)

The kenney.nl product page likewise lists the license as Creative
Commons CC0 and describes the package as free incl. commercial use.
CC0 = public domain dedication: no attribution required, no
restrictions. FORGEFALL credits Kenney here anyway.

## Contents

143 `.glb` models in the zip (`Models/GLB format/`), plus the same
models as FBX and OBJ, a shared color-map texture, previews, and
`License.txt`. Asset families: structures, catwalks, conveyors,
pipes, machines, hoppers, cranes, robot arms, screens, scanners,
cogs, boxes, buttons, indicators, levers, cones, tops.

## How FORGEFALL uses it

FORGEFALL ships **zero imported meshes** — every map is procedural
voxel geometry (MultiMesh boxes, box collision, nav baked from walk
surfaces). The Factory map (`scripts/maps/factory_builder.gd`,
`scenes/maps/factory.tscn`) is built from the kit's vocabulary:
each kit asset below is recreated as voxel boxes in the Forgefall
style (kit name in the code comment on every build step; the full
list is the builder's `KIT_ASSETS_USED` constant). No kit mesh,
texture, or binary is imported into the game; no kit file is
modified. The map therefore stays Forgefall-voxel-compatible and
inside the established perf contract.

Kit asset → voxel build (representative; see builder comments):

| Kit asset | Voxel build in the Factory map |
|---|---|
| structure-wall / structure-doorway / structure-window | Perimeter + spine walls, door gaps + frames |
| structure-yellow-tall | 12 m NW stack (landmark grapple anchor) |
| floor / floor-large | Ground slab + plate seams |
| catwalk-straight / -corner / -cross / -junction | Side decks + cross gantries |
| catwalk-stairs | 3-step stairs to the decks |
| conveyor-long / conveyor-bars / conveyor-sides | Belt + rollers + rails, both halls |
| conveyor-junction-t / conveyor-corner | Belt end caps, scanner arch |
| machine / machine-window / machine-fortified / machine-bed | Machine rows, 6 bodies |
| machine-connection-pipe | Pipe stubs on machine tops |
| robot-arm-a / robot-arm-b | Arms between machines |
| piston-square / piston-round | Piston columns beside machines |
| hopper-square / hopper-round | Hopper bins at hall ends |
| cog-a / cog-b / cog-c | Cog clusters on spine faces |
| crane / crane-lift / crane-magnet | Overhead crane beam + trolley + magnet + crate |
| pipe-large / pipe-large-long / pipe-large-bend / pipe-large-valve / pipe-large-junction | Overhead pipe run + wall pipes + valves |
| screen-hanging-wide / screen-panel-wide / screen-small | Hanging screens, spine panels |
| scanner-high / scanner-low | Scanner arches over conveyors |
| box-small / box-large / box-long / box-wide | Crate stacks, belt crates |
| button-floor-square | Forge-pad style floor markers (via base builder) |
| warning-orange / indicator-special-lines | Hazard stripes, bay panels, cones |
| lever-single | Levers by the door gaps |
| cone | Cones at stair bases |
| top | Deck / cap plates |

## Names / signage

All in-game names and signage are Forgefall-original ("Ironworks",
bay stripes). No third-party trademarks, copied names, or copied
signage appear in the map. See `tools/verify_factory_map.gd` for the
headless banned-string scan.
