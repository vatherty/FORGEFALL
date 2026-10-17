# FORGEFALL — Forge building gate (Gameplay Rework, TD worker + MP worker).
#
# THE single gate for Forge building (Colin, GAMEPLAY_REWORK.md):
# Forge building exists ONLY in Tower Defense. Every Forge entry point
# consults ForgeGate.can_build() before building anything:
#   - ForgeManager.submit_prompt / build_from_code / build_spec_direct /
#     apply_make (the pipeline choke point — covers HUD, menu, ghost,
#     build codes, and MAKE),
#   - Forge menu open() (the menu cannot even open in other modes),
#   - HUD Forge toggle (refuses + announces instead of opening),
#   - NetForgeSync.host_place / apply_place (MP worker: remote Forge
#     specs are gated by the SAME allowlist — a peer in an MP Zombies /
#     MP TDM match cannot smuggle a build in over the wire).
# The gate is an ALLOWLIST: only mode ids "tower_defense" (SP) and
# "mp_tower_defense" (MP co-op) pass. Unknown / future mode ids ("tdm",
# "zombies", "mp_zombies", ...) are blocked by default.
#
# Live-mode tracking: GameModeManager sets static live_mode in start()
# and clears it in stop()/_exit_tree(). MP matches do NOT run through
# GameModeManager.start() — MPModes.set_live_mode() sets the same
# static for MP matches, so MP matches are gated exactly like SP runs.
# When NO run is live (live_mode empty — main menu, tools, headless
# verifiers), the gate PERMITS: there is no match to protect, and
# existing Forge suites run without a mode manager. Inside a live run
# the gate is absolute.
class_name ForgeGate
extends RefCounted

## The mode ids allowed to build. Keep in sync with
## GameModeManager.MODES["tower_defense"] / ["mp_tower_defense"].
const FORGE_MODE := "tower_defense"
const FORGE_MODES: Array[String] = ["tower_defense", "mp_tower_defense"]
const BLOCK_MESSAGE := "Forge building is only available in Tower Defense."

## The mode of the live run ("" = no live run). Prefers the live
## manager's mode; falls back to the menu's selected mode.
static func current_mode() -> String:
	if GameModeManager.live_mode != "":
		return GameModeManager.live_mode
	return GameModeManager.selected_mode


## Pure allowlist check for one mode id (verifier-friendly, no tree).
static func can_build_for_mode(mode: String) -> bool:
	return FORGE_MODES.has(mode)


## The gate every Forge entry point calls. No live run -> permit
## (menus / tools / tests). Live run -> Tower Defense only (SP or MP).
static func can_build() -> bool:
	if GameModeManager.live_mode == "":
		return true
	return FORGE_MODES.has(GameModeManager.live_mode)


## True while a run is live (a mode manager has started a run).
static func in_live_run() -> bool:
	return GameModeManager.live_mode != ""
