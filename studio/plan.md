# Forgefall Studio scope tracker

Status as of 2026-10-21. A checked item means the workflow was implemented and exercised locally, not merely described.

## Six-stage completion plan (2026-10-21)

Each stage has one dedicated subagent. The lead agent integrates their work, runs the shared checks, and records what was actually verified. A stage is complete only when its workflow can be reopened from disk and exercised in Godot. Stages 1, 2, and 4 can start in parallel because their primary files are separate. Stage 3 follows the foundation changes, stage 5 follows the map and behavior data contracts, and stage 6 follows the authoring features.

| Stage / subagent | Deliverable | Acceptance gate |
| --- | --- | --- |
| 1. Foundation | Complete transactional history and recovery, reusable document and meshing interfaces, workspace layout and control mapping. | Save, reopen, undo/redo, recover, and navigate the map editor with keyboard, mouse, and controller events; no regressions in existing foundation checks. |
| 2. Assets | Finish voxel modeling tools, layers and pivots, collision options, attachments, references, and thumbnails while preserving linked publication. | Author an asset with the new tools, save/reopen, publish, then republish and see map instances refresh; workshop checks pass. |
| 3. Maps and game | Transforms and grouping, lighting, volumes, gameplay markers and navigation, Forgefall menu catalog selection, native playtest. | Publish a Studio map, select and launch it from the game, and exercise its collision and gameplay markers. |
| 4. Behaviors and source | Behavior graph and compiler with templates and timers, GDScript editing, diagnostics and debugging hooks. | Save/reopen a behavior, compile it, attach it to a published object, and run it; invalid source reports an actionable location. |
| 5. Animation and content | Machinery timelines, character rig and spawn authoring, weapon authoring, and Forgefall runtime adapters. | Build and play an animated door or lift, a character spawn, and a firing weapon from saved Studio content. |
| 6. AI and release | Optional text/vision assistance as previewable proposals with apply/undo/redo; performance pass, Deck controls, Web export, standalone package. | Complete the end-to-end acceptance scenarios below, including reopen, native playtest, Deck validation, Web export and standalone launch. |

The stage owner should report changed files, commands and results, visual evidence where relevant, and remaining limitations. The lead agent will update the checkboxes after integration and verification. No stage should commit, push, deploy, or overwrite existing player saves.

## 1. Foundation — in progress

- [x] Standalone Godot project, separate from game autoloads.
- [x] Explicit Forgefall source selection and validation.
- [x] Versioned JSON map document with stable map and instance IDs.
- [x] Basic hierarchy, 3D preview, inspector, resizable panels, and 1280 × 800 startup size.
- [x] Block creation/deletion, position changes, undo/redo, dirty indicator, save/save-as, autosave, and recovery prompt.
- [x] Detect external map changes before saving over them.
- [x] Persistent map command history with stale-history rejection, bounded stacks, and tested undo/redo.
- [ ] Complete transaction coverage across every authoring surface.
- [x] Persisted split layout, configurable keyboard shortcuts, and basic stick/touch navigation.
- [x] Native gamepad button remapping, D-pad tool palette and hierarchy selection, hierarchy/inspector visibility, and Reset Layout.
- [ ] Freeform docking, hardware left-trackpad radial profile, and physical Deck touch/controller validation.
- [x] Target-project helper generates native block scenes with static collision and a catalog.
- [x] Shared document store/voxel mesher and Forgefall game menu integration.
- [ ] A complete shared map abstraction across every Studio authoring workspace.

## 2. Assets — in progress

- [x] Separate 3D voxel workshop with 0.125 m pitch, place, erase, paint, custom palette colors, coordinate editing, viewport click placement, save/recovery, and undo/redo.
- [x] Shared exposed-face mesher with chunked output and one consolidated static collision shape per occupied chunk.
- [x] Asset/map save conflicts, undo/redo for discrete edits, and crash-recovery snapshots.
- [x] Stable asset documents, publication into native Godot scenes, catalog entries, and linked map instances that refresh when the source asset is republished.
- [x] Box/sphere/cylinder stamps, add/erase brush, flood fill, grouped drag undo, XYZ symmetry, visible named layers, pivot, static/none collision, attachments, reference image preview, and visible-window thumbnail capture.
- [x] Neighbor-based smooth and one-cell deform tools, layer rename/reorder/merge, per-layer collision, and attachment edit/delete.
- [ ] Continuous deformation brushes and custom collision-shape editing.

## 3. Maps — implemented and native playtested

- [x] Place linked voxel library assets in maps and publish native scenes.
- [x] Transforms, group IDs, lights, volumes, gameplay markers, navigation regions, behavior attachment, and Forgefall menu integration.
- [x] Native TDM deploy test exercises player spawn, collision, and F/Y behavior interaction.
- [x] Native walkable-house scenario with wall and doorway physics plus a linked moving lift.
- [ ] Dedicated rotation/scale gizmo handles and additional gameplay scenarios.

## 4. Behaviors and source — integrated, debugging in progress

- [x] Separate graph workspace/compiler with templates and timers, GDScript editor, diagnostics, source save conflicts, and runtime trace signals.
- [x] Map behavior attachment and in-game F/Y interaction.
- [x] Generated behavior breakpoints with pause/resume, radius-based barrel damage, case-insensitive animation targets, and handwritten source error-line selection/repair.
- [ ] Editor connection to a running game playtest, exact diagnostic columns, and richer branching graph logic.

## 5. Animation and content — implemented with limits

- [x] Machinery timeline playback/scrubbing, visual box-part rig and weapon controls, map character spawns, navigation/chase, and authored weapon auto-fire.
- [ ] Skeletal deformation, walk cycles, and richer character AI/navigation.

## 6. AI and completion — implemented with release limits

- [x] Optional endpoint-based text/image proposals, preview and one-command apply/undo/redo; local voxel meshing optimization.
- [x] Linux standalone and Web export builds; browser JSON import/edit, copy fallback, and one successful download/reimport session. A later in-app browser session suppressed download delivery.
- [ ] Live external AI provider validation, physical Steam Deck input validation, and Web native publication/library/gameplay parity.

## End-to-end acceptance — not yet met

- [x] Barrel radius damage, animated door/lift movement, character rig/spawn, authored weapon firing, handwritten source diagnose/repair/save, AI apply/undo/redo, reopened content and behavior, native map deploy/interaction, Linux and Web exports.
- [x] Visibly inspected walkable-house map with floor, doorway, wall collision, spawn, and a linked moving lift; native test saved, published, reopened, deployed, and passed movement probes.
- [ ] A single scenario combining every authored system, physical Deck control playtest, and live external AI provider round trip.
