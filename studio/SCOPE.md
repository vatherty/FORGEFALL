# Forgefall Studio scope and acceptance

The current six-stage plan, implemented features, and open acceptance gates are tracked in [plan.md](plan.md). Checkmarks record workflows exercised locally under Godot 4.7.2.

Studio is a separate Godot application for map, voxel asset, behavior, animation, character, and weapon authoring. Desktop publication creates native Forgefall scenes and catalog entries. Forgefall can select and deploy published maps. The Web build supports JSON map import and editing, and offers download with a visible JSON copy fallback when a browser suppresses the file; native publication and game playtesting require desktop Studio.

A visibly inspected walkable-house map passed native floor, doorway, wall, spawn, and lift checks. The live external AI-provider round trip was verified 2026-11-25 (DeepSeek via tools/studio_ai_adapter.py; see verify_ai_live.gd). The full handoff remains open only because physical Steam Deck input remains unverified. Additional editor depth remains for freeform docking and skeletal animation (Studio rigs are box parts; a procedural walk cycle ships instead). Deformation sculpting, custom collision shapes, direct gizmos, and branching behavior logic were completed 2026-11-25. See [README.md](README.md), [BEHAVIORS.md](BEHAVIORS.md), and [RELEASE.md](RELEASE.md) for use and verification commands.
