# FORGEFALL — ForgeSessionCover (v0.5.9, MAKE parity, Worker E)
# Property carrier for MAKE'd covers carrying session hooks.
#
# WHY THIS EXISTS: a MAKE'd cover is a DestructibleCover, which has no
# mod_hooks / session_hooks property — and Godot has no dynamic
# properties, so `node.set("mod_hooks", ...)` on a plain cover is a
# silent no-op. A session hook attached to a cover must be readable
# via node.get("mod_hooks") (the same shape WeaponBase exposes for
# weapon mods), so ForgeSessionMake swaps a hook-carrying cover's
# script to this subclass (set_script) right after the build and
# re-applies the builder's state (hp / vox_size / pitch / palette),
# which set_script resets to defaults. Children (mesh, collider,
# ForgeEnemyPressure), group membership, and metadata survive the swap
# (verified headless); the inherited _ready does NOT re-run, so the
# mesh is not rebuilt. fracture() null-guards the reset _mi, so
# destruction still works. No behaviour lives here — enemy-touch
# dispatch is ForgeSessionWatcher's job; this file only carries the
# hook properties.
extends DestructibleCover
class_name ForgeSessionCover

## Session hooks attached to this cover (validated on_hit hooks).
var mod_hooks: Array = []
## Alias of mod_hooks (same shape some readers use).
var session_hooks: Array = []
## The MAKE session id that built this cover.
var session_make_id := ""
