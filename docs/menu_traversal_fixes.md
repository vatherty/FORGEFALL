# Menu, session, and traversal fixes

Based on upstream `f80cdca` (v0.6.1 source sync). No release/version-code bump or platform export is included.

## Changes

- Pause, Resume and Quit to Menu now go through Main's state machine. Quitting keeps the bootstrap scene, tears down mode/network/player nodes, stops the grapple loop, resets run state and returns cursor/focus to a fresh menu. Previously the pause menu replaced Main with the standalone menu scene, leaving nothing to start another match.
- Main menu uses an original industrial backdrop, orange navigation and a bundled OFL font. Play opens a full-screen cyan mode-card screen, then a sand-colored mission setup screen. Map, loadout and traversal are editable before deployment; TD/Zombies keep their required maps and mode rules. Existing multiplayer, puzzles, stats, mod creation, settings and remapping remain accessible.
- Layout is container-driven. Scrolling and narrow-screen stacking replace overlapping panels and one-character-wide labels. Controller focus remains visible and returns to the originating screen.
- Wall-running projects input onto the wall, tracks contact independently of camera yaw, bridges tiny contact gaps, preserves high incoming speed and forward wall-jump momentum, and permits airborne chains to opposing walls. Same-wall reattachment is blocked until landing or catching a different wall. Entry boosts are bounded to prevent exponential speed growth from chains.
- Angled grapple shots now apply radial pull while preserving tangential swing momentum. Reeling works while attached, including toggled input, rather than requiring held input. Close anchors release automatically.
- Fixed typed mode-list returns, optional Forge HUD scaling in non-Forge modes, and invalid unquoted placeholder keystore passwords in export configuration. Export credentials remain blank.

## Validation

Godot 4.6.3 on Linux (README requests 4.7.2):

- All 203 GDScript files compile.
- Controller suite: 895 checks pass.
- Existing menu-layout suite, updated for the new flow: 878 checks pass.
- Menu/TDM integration: 121 checks pass.
- Movement rework: 45 checks pass.
- Existing v0.6 movement/grapple suite passes.
- New regression suites verify full TDM -> TD -> Zombies -> TDM session cycles, responsive cards/deployment, oblique grapple pull, momentum, physical wall contact and opposing-wall chains.
- Rendered the three new screens at 1280x800 and smaller window sizes using the compatibility renderer. New layout regression also checks direct 540x960 control sizing.

Some existing headless suites emit resource-in-use warnings during engine shutdown; assertions pass. No physical Steam Deck/Android playtest or networked multiplayer session was performed. Movement tuning should be judged in a hands-on playtest.

## Artwork

The main backdrop is decorative generated art. Map previews are actual map geometry, captured under neutral thumbnail lighting; see `assets/ui/README.md`. The screenshot tool requires a display and is not part of the normal test suite.

## Consistent menu styling follow-up

The shared `StencilStyle.menu_theme()` now supplies bundled heading typography, flat dark surfaces, orange actions, clear keyboard/controller focus, readable body text, tabs, dropdowns, text fields, lists and progress bars. Screens install the theme at their roots so dynamic content inherits it.

Updated screens: loadout picker and editor, settings, input remapping, service record, multiplayer browser/lobby, mod creator (Create/Chat/Mods/Import-Export and approval flows), in-game Forge and its tabs, puzzle selector, sandbox, update dialogs, legacy TD/Zombies setup, and network scoreboard. The main menu, mode selection, deployment and pause screens retain their reference layouts. Gameplay HUD body text keeps its contrast outline.

Loadouts and stats use cards; puzzle selection uses responsive cards; the loadout editor has a dedicated scroll area; dense menus retain scrolling rather than reducing text to tiny sizes. Settings has an input-blocking dimmer. Corrected invisible slider tracks and initial sizing for script-created menu roots. Existing signals and menu entry points are preserved.

Follow-up validation on Godot 4.6.3: 203 scripts compile; controller 895/895; main menu layout 926/926; menu/TDM 121/121; Forge Mods layout 29/29; progression/stats/loadouts 67/67; creator redesign 56/56. The creator test has a documented early-autoload compile diagnostic in its `--script` startup, then reloads dependencies and completes all assertions. No script errors were found while rendering the actual screens. Shutdown resource warnings remain in some existing test harnesses.

Rendered menu screenshots at 1280x800 and 960x540, including creator tabs, chat, import/export, the loadout editor, update dialog and sandbox. Physical Steam Deck/Android and live network play still need device testing. Changes are source-only; no release or remote push has been performed.

## Cinematic concept implementation

This pass supersedes the earlier opaque card and sand-panel styling. Secondary screens now use full-screen scenery with dark readability gradients, translucent controls, thin orange selection markers, and restrained primary actions.

- Mode selection and puzzle selection are navigation lists with a description and a separate Continue/Enter action.
- Deployment uses compact map, mode, loadout and traversal rows over the industrial scene.
- Loadout selection and editing use an armory backdrop; active gear details, edit/delete, and new-loadout actions remain available. The dedicated editor still scrolls on short screens.
- Settings separates Audio, Display and Controls. Values retain immediate application and persistence. Multiplayer separates Host/Join while retaining LAN discovery, direct IP and the lobby.
- Service Record shows real kills, wins and accuracy prominently, with the full existing statistics available through expandable sections.
- Creator and chat use a workshop scene. Forge shows build icons, category tabs and its prompt first; History & Tools expands the existing history, build codes, API-key setup, made-item status and placed-structure controls.
- Pause and Forge darken the actual match view when a gameplay camera is active. Decorative art is used only as a standalone fallback.
- Rebinding, legacy setup screens, scoreboard, sandbox and update dialogs share the same translucent visual system.

New `tools/verify_cinematic_ui.gd` exercises the revised navigation, settings tabs, loadout editor/cancel/back behavior, expandable Forge controls, Host/Join switching, live stat values and live pause background. Broad existing controller, layout, TDM, session, creator, progression and Forge checks are also run. Background illustrations are decorative; they do not replace gameplay maps or selected models. The main menu retains its approved composition.

Cinematic-pass validation (Godot 4.6.3, Linux): 204 scripts compile; 895 controller checks, 626 main/settings layout checks, 121 menu/TDM checks, 29 Forge Mods layout checks, 67 progression/loadout/stats checks, 56 creator checks, and 43 creator-chat checks pass (2 chat checks skipped by the existing harness). The new cinematic interaction suite passes all 14 checks, including actual-match pause behavior. Responsive mode/deployment checks and repeated match-exit sessions also pass. Actual screens were rendered at 1280x800 and dense secondary forms at 960x540. Some existing harnesses report shutdown resource warnings and startup autoload diagnostics; the screenshot probes report no script errors, though the environment cannot complete automatic updater connections. No device exports, remote push, or public release is included.
