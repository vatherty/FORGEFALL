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
