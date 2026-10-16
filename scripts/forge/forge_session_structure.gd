# FORGEFALL — ForgeSessionStructure (v0.5.9, MAKE parity, Worker E)
# Property carrier for MAKE'd structures carrying session hooks.
# Same deal as ForgeSessionCover (see its header): a plain
# ForgeStructure has no mod_hooks property, so a hook-carrying
# structure's script is swapped to this subclass after the build and
# the builder's state (shape / hp / max_hp / bounds / debris colors) is
# re-applied. Children (feedback nodes, StructureBody), group
# membership, and metadata survive the swap; the inherited _ready does
# NOT re-run. Damage feedback code null-guards the reset overlay /
# crack / smoke refs, so hit feedback + destruction still work. No
# behaviour lives here — enemy-touch dispatch is ForgeSessionWatcher's
# job; this file only carries the hook properties.
extends ForgeStructure
class_name ForgeSessionStructure

## Session hooks attached to this structure (validated on_hit hooks).
var mod_hooks: Array = []
## Alias of mod_hooks (same shape some readers use).
var session_hooks: Array = []
## The MAKE session id that built this structure.
var session_make_id := ""
