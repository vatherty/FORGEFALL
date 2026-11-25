# Forgefall Studio scope and acceptance

The current six-stage plan, implemented features, and open acceptance gates are tracked in [plan.md](plan.md). Checkmarks record workflows exercised locally under Godot 4.7.2.

Studio is a separate Godot application for map, voxel asset, behavior, animation, character, and weapon authoring. Desktop publication creates native Forgefall scenes and catalog entries. Forgefall can select and deploy published maps. The Web build supports JSON map import and editing, and offers download with a visible JSON copy fallback when a browser suppresses the file; native publication and game playtesting require desktop Studio.

A visibly inspected walkable-house map passed native floor, doorway, wall, spawn, and lift checks. The full handoff remains open because physical Steam Deck input and a live external AI-provider round trip remain unverified. Additional editor depth remains for freeform docking, deformation sculpting, custom collision shapes, direct gizmos, branching behavior debugging, and skeletal animation. See [README.md](README.md), [BEHAVIORS.md](BEHAVIORS.md), and [RELEASE.md](RELEASE.md) for use and verification commands.
