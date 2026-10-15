# FORGEFALL — ModBlock (v0.7 chunk 1: user mods, Worker A)
# Base class every user SCRIPT mod must extend. The game loads a mod
# script, instantiates it, and calls get_block_info() (at scan time, to
# validate + catalog the mod) and apply() (at build time, to build it).
#
# CONTRACT (keep it minimal — the game trusts NOTHING else about a mod):
# - get_block_info() -> Dictionary: the mod's catalog entry. Same schema
#   as a JSON block's "block" object (see ModLoader._validate_block):
#   {"block_id": "my_gun", "target": "weapon"|"cover"|"structure"|"turret"|"pickup",
#    "cost": 0-2000, "display_name": "My Gun", "description": "optional",
#    ...per-target fields (base_weapon_id/damage_mult, shape/size_voxels/hp,
#    duration_sec, kind/amount, ...)}. Invalid info -> mod disabled.
# - apply(api: ModAPI, params: Dictionary) -> String: build the thing using
#   ONLY the ModAPI surface (never raw nodes, never the filesystem, never
#   the network). Return a non-empty human-readable success message, or ""
#   to report failure (the builder fails gracefully, never crashes).
#   params carries the spec's params PLUS "_position" (Vector3, resolved
#   build point for placed targets) and "_target" (the spec's target).
# - _init() must stay side-effect free: it runs at SCAN time when the game
#   validates the mod. Do all building in apply(), not in _init().
# - Forbidden inside mod scripts (text-scanned before load, see
#   ModLoader.FORBIDDEN_SNIPPETS): OS/FileAccess/DirAccess, load()/preload/
#   ResourceLoader, Expression/GDScript, Engine singletons, .new(), call().
#   A mod script that needs a resource the API doesn't expose cannot do it
#   — that is the deal. The scan is a guardrail, not a sandbox: a mod
#   script runs with game trust, so only install mods from sources you
#   trust (same bar as any GMod addon).
extends RefCounted
class_name ModBlock


## Catalog entry for this mod. Override in the mod script.
func get_block_info() -> Dictionary:
	return {}


## Build the mod's thing via `api`. Return "" on failure.
func apply(api: ModAPI, params: Dictionary) -> String:
	return ""
