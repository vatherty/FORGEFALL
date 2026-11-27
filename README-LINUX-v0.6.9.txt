FORGEFALL v0.6.9 — Linux (x86_64) / Steam Deck
==============================================

Same game as the Android v0.6.9 build: voxel MW2-style FPS with
portals, grapple, wall-running, and the AI Forge console.

BUG BASH + GRAPHICS TIERS — v0.6.9 (TEST BUILD)
-----------------------------------------------
  - TEST BUILD: this release exists to try the new GRAPHICS
    High tier on mobile. Set SETTINGS > DISPLAY > GRAPHICS to
    High, play a few matches, and report the FPS — smooth or
    chuggy, and on which map.
  - GRAPHICS TIERS (BB-9): GRAPHICS Low = the classic look
    (default, phone-safe). High turns on real-time shadows
    (PSSM, 250 m), per-map colour grading, glow, a voxel grit
    shader with contact AO, ground decals, and MSAA 4x.
    Deck-verified: 60 fps at High. Applies at next map load.
  - SIGHTS (BB-1): per-weapon sight anchors and zoom classes
    — iron 1.1x, reflex 1.15x, ACOG 3x, sniper scope 5x with
    a scope overlay. ACOG and red-dot sights now have real
    picture-in-picture lenses: you see the world through the
    glass, with parallax as your eye moves. The ACOG lens adds
    1.5x on top of the 3x body zoom.
  - MOVEMENT (BB-2/BB-3): landing keeps your momentum (vector
    ground model, uniform overspeed bleed), and wall-running
    accepts diagonal entries with a short wish-grace window.
  - SKIES + HORIZONS (BB-6): real CC0 skyboxes (Poly Haven) on
    every map, and the Dustline/Outpost city-skyline rings are
    now layered desert mesas that fit the maps.
  - OUT OF BOUNDS (BB-7): BO3/Battlefield-style — leave the
    combat area and a 10-second countdown starts; get back in
    or you die (no enemy kill credit). Ground now reaches the
    horizon on every map.
  - BOT SKILL TIERS (BB-8): bots aim like humans now —
    tracked aim, reaction times, motion error. Pick ROOKIE /
    REGULAR / HARDENED / ELITE in the DEPLOY panel (default
    Regular).
  - Everything from v0.6.8 and earlier is included.

NEW SETTINGS MENU — v0.6.7
--------------------------
  - NEW in-game SETTINGS screen (built by Colin): five tabs —
    CONTROLS (look/ADS sensitivity, invert Y, key/controller
    bindings), AUDIO (master/music/SFX/menu volumes), DISPLAY
    (field of view, quality, vsync, fullscreen), MOBILE (touch
    sensitivity, button opacity, vibration), and FORGE AI.
  - The FORGE AI tab is where the DeepSeek key now lives:
    masked entry, save/remove, from the main menu or pause —
    no more hunting through the Forge's History & Tools.
  - Settings apply immediately and persist on the device.
    Resetting settings keeps your key and bindings.
  - Menus now use native touch-to-mouse emulation (Colin's
    call, for the settings controls); gameplay safety is
    unchanged — a tap still can never fire the gun (runtime
    toggling + binding-erase, re-verified 23/23).
  - Everything from v0.6.6 and earlier is included.

NEW MOBILE HUD — v0.6.6
----------------------
  - Touch controls rebuilt (designed and built by Colin's
    GPT/Codex session; verified and merged by Sparky):
    procedural icon buttons instead of text discs, FIRE-drag
    aiming (drag on FIRE to aim while shooting), an
    always-visible joystick base, PLACE/USE and CANCEL buttons
    for Forge placement, a weapon SWAP button, event-driven
    pause/interact buttons, and a touch-specific HUD layout.
  - Safety re-verified end to end: a tap can never fire the
    gun in any state (menu, deploy, Forge open, pause, death);
    touch fonts scale via the shared UiScale helper.
  - Everything from v0.6.5 and earlier is included.

DEPLOY LOADING SCREEN + WARMUP FIXES — v0.6.5
-------------------------------------------
  - NEW MAP LOADING SCREEN: every deploy path (single player,
    multiplayer host/join, puzzle chambers) now shows a
    "DEPLOYING" screen with the map/mode, a live stage label
    (warming up → loading map → spawning player → systems →
    waves/match), and a real stage-based progress bar — so you
    always see where a deploy is. If a deploy fails, a red
    "DEPLOY FAILED" screen shows for 2 seconds, then returns
    you to the menu (no more silent black screens).
  - WARMUP FIXES: the pre-game effect-pool warmup now survives
    a fast deploy (it cancels cleanly mid-run, no stray damage
    emitters), and its Phase-0 pool precache actually works now
    (pools build up front instead of lazily mid-match).
    The missing-map check now runs BEFORE the menu closes.

DUAL-TOUCH AIM + WEB WARMUP — v0.6.4
---------------------------------
  - AIM FIX (touch devices): look deltas are now computed per
    touch from tracked finger positions — the engine's
    unreliable per-touch 'relative' is ignored, so the view no
    longer jumps to random places while a second finger is down.
    A second finger landing in the stick zone no longer steals
    the joystick mid-drag, and releases drop the touch cleanly
    (no stuck movement).
  - WEB WARMUP (browser port): a short main-menu "Warming up"
    pass pre-builds effect pools and compiles shaders up front,
    cutting first-use and after-idle slowness. A light rewarm
    runs if any single frame takes over 8 seconds.

CINEMATIC MENUS — v0.6.3
----------------------
  - SECONDARY SCREENS are now full-screen scenery: dark
    readability gradients, translucent controls, thin orange
    selection markers, and restrained primary actions. This
    pass supersedes the earlier opaque card and sand-panel
    styling. Decorative art is a standalone fallback only —
    Pause and Forge darken the ACTUAL match view when a
    gameplay camera is active.
  - MODE SELECTION and PUZZLE SELECTION are navigation lists
    with a description plus a separate Continue/Enter action.
  - DEPLOYMENT uses compact map, mode, loadout and traversal
    rows over the industrial scene.
  - LOADOUT selection/editing use an armory backdrop; active
    gear details, edit/delete, and new-loadout actions remain.
    The dedicated editor still scrolls on short screens.
  - SETTINGS separates Audio, Display and Controls. Values
    keep immediate application and persistence.
    MULTIPLAYER separates Host/Join while retaining LAN
    discovery, direct IP and the lobby.
  - SERVICE RECORD shows real kills, wins and accuracy
    prominently, with the full existing statistics available
    through expandable sections.
  - CREATOR and CHAT use a workshop scene. FORGE shows build
    icons, category tabs and its prompt first; HISTORY &
    TOOLS expands the existing history, build codes, API-key
    setup, made-item status and placed-structure controls.
  - SHARED MENU THEME (StencilStyle.menu_theme): bundled
    heading typography, flat dark surfaces, orange actions,
    clear keyboard/controller focus, readable body text,
    tabs, dropdowns, text fields, lists and progress bars —
    across loadout picker/editor, settings, remapping,
    service record, multiplayer browser/lobby, mod creator
    (Create/Chat/Mods/Import-Export + approval flows),
    in-game Forge and its tabs, puzzle selector, sandbox,
    update dialogs, legacy TD/Zombies setup, and network
    scoreboard. Main menu, mode selection, deployment and
    pause screens keep their reference layouts. Gameplay HUD
    body text keeps its contrast outline.
  - FORGE keeps a 27% right margin on wide viewports (>=1100px)
    so the match/scenery stays visible — deliberate, locked in
    by verify_v061; see BUILD_LOG v0.6.3 entry for the
    full-width decision item for Colin.

MENU / SESSION / TRAVERSAL FIXES — v0.6.2
--------------------------------------
  - PAUSE / RESUME / QUIT TO MENU now go through Main's state machine.
    Quitting keeps the bootstrap scene, tears down mode / network /
    player nodes, stops the grapple loop, resets run state, and
    returns cursor/focus to a fresh menu — so a second match
    starts cleanly. Previously the pause menu replaced Main with
    the standalone menu scene, leaving nothing to start another
    match.
  - NEW INDUSTRIAL MAIN MENU: original backdrop artwork + bundled
    OFL font (Barlow Condensed), orange navigation. PLAY opens a
    full-screen cyan mode-card screen, then a sand-colored
    mission-deployment screen. Map, loadout and traversal are
    editable before deployment; TD/Zombies keep their required
    maps and mode rules. Multiplayer, puzzles, stats, mod
    creation, settings and remapping remain accessible.
  - LAYOUT is container-driven: scrolling and narrow-screen
    stacking replace overlapping panels and one-character-wide
    labels. Controller focus remains visible and returns to the
    originating screen.
  - WALL-RUNNING: input is projected onto the wall, contact is
    tracked independently of camera yaw, tiny contact gaps are
    bridged, high incoming speed is preserved, and forward
    wall-jump momentum is kept. Airborne chains to opposing walls
    are allowed. Same-wall reattachment is blocked until landing
    or catching a different wall. Entry boosts are bounded to
    prevent exponential speed growth from chains.
  - GRAPPLE: angled shots now apply radial pull while preserving
    tangential swing momentum. Reeling works while attached,
    including toggled input, rather than requiring held input.
    Close anchors release automatically.
  - RESUME hides the pause menu synchronously (no one-frame
    mouse-mode flip). Plus: typed mode-list returns, optional
    Forge HUD scaling in non-Forge modes, and export-config
    placeholders fixed (credentials stay blank).
  - Map previews on the deployment screen are actual map
    geometry, captured under neutral thumbnail lighting.

CONTROLLER + MAPS — v0.6.1
--------------------------
  - NATIVE CONTROLLER SUPPORT + REMAPPING: full gamepad play on
    Deck/PC — every action has keyboard + gamepad bindings, one
    dead-zone tunable (0.2) applied everywhere, and a
    Controls/rebind overlay in Options (persisted to
    user://input_bindings.cfg). Tool-switch: V / D-pad Left.
    Weapon cycle: mouse wheel (weapon_next/prev). Slide is
    crouch-held. Interact/Buy default: F / Y (North). Menu
    navigation works by gamepad (D-pad + Confirm/Back),
    including Forge tab-bar focus. Keyboard buy verified
    working — the earlier Deck failure was controller-layer
    only.
  - ZOMBIES TOWN REMAKE: the town was rebuilt in place at the
    same 1:1 layout, with all-different Forgefall-original
    contents — 6 buildings with enterable interiors, 89
    interior props, 73 street dressing, 7 lights. Prices and
    rules unchanged. (The Brick Kit was evaluated and NOT
    adopted — toy scale, clashes with the voxel look.)
  - NEW MAP — FACTORY (Team Deathmatch): 56x56 m industrial
    map built as voxel recreations of kit assets (no kit
    binaries imported). In the map picker + TDM rotation.
  - CINDER CITY UPGRADE: all 24 buildings now RENDER as Kenney
    City Kit (Commercial) v2.1 GLBs (CC0) scaled to each
    building's exact gameplay volume. Collision is untouched
    (original voxel boxes), metrics unchanged.
  - DEFERRED: Kenney Blocky Characters for player/enemy models
    — 1 body / 18 paint jobs, no skeleton, no flinch/windup
    clips, unlit vs the lit world, no player value. Not
    adopted; no code or assets touched.

GAMEPLAY REWORK — v0.6.0
------------------------
  - START MENU: the game no longer deploys straight into a game.
    Pick SINGLE PLAYER or MULTIPLAYER, then a mode.
  - SINGLE PLAYER — TOWER DEFENSE: purpose-built TD map with two
    serpentine lanes and 8 build spots. Build phase (Forge
    auto-opens) -> combat wave -> repeat. Defend a 1000-HP core;
    an enemy that reaches it is destroyed at the gate and deals
    100 damage (+5% per wave). Forge building lives HERE and
    only here. Player death redeploys after 3s; the run ends
    when the core falls.
  - SINGLE PLAYER — TEAM DEATHMATCH (bots): you + bot squadmates
    vs a bot squad, first team to 25 kills. Pick a loadout
    beforehand, including exactly ONE traversal tool: Grapple
    Hook, Jetpack, or Portal Gun.
  - SINGLE PLAYER — ZOMBIES (CoD-style, Forgefall-flavored):
    small town map, buy doors with points, randomized perk
    machines (a health perk is ALWAYS somewhere), randomized
    wall buys, Mystery Box (950 pts, pulls from EVERYTHING
    incl. installed weapon mods), Pack-a-Punch (5000, re-Pack
    2000 for a chain effect / sight / attachment). Starting
    gun is the weak custom SP-1 EMBER. No Forge in Zombies;
    no grapple/portal/jetpack unless the pre-run toggle is ON.
  - MULTIPLAYER: co-op Tower Defense, co-op Zombies (shared
    doors/perks/box/PAP, cross-peer revives), PvP Team
    Deathmatch + bot fill (bot kills count; a real player
    killing a bot scores nothing).
  - MOVEMENT: wall-run now has real rules — attach only at full
    walking speed, only when aimed at the wall or parallel to
    it, with a 50% entry boost. Hold jump for a higher WALL-jump
    (tap = small hop, hold = full jump; ground jumps unchanged).
    Slide camera lowered: stand 1.6 / crouch 1.05 / slide 0.85
    (camera-only; the collision capsule is NOT shrunk).
    NEW: Jetpack traversal tool — fuel-based thrust (~2.9 s
    tank, 2.5 s max burn per burst, refills grounded in ~4 s).
  - MAPS: new CINDER CITY — a dense urban map with tall
    buildings to grapple and swing through. Zombies runs on a
    flat town map so the town geometry never overlaps map
    props. Tower Defense has its own tailored map.
  - ENEMIES: full redo — distinct behaviour per type (rusher,
    grunt, marksman, brute, bulwark, shredder, suppressor,
    warlord) plus procedural/code-driven animation: limb swing,
    attack wind-up + telegraph, hit reactions, death animation.
  - TRAVERSAL IDs: the portal tool id is now "portal"
    everywhere (loadouts, TD setup, MP). Older saves with
    "portal_gun" migrate to "portal" on load.
  - BASE DEFENSE stays as a legacy mode: still registered and
    startable, hidden from the new Single/Multiplayer menus.
  - KNOWN DEFERS (not in this build): in-game MP revive
    key/prompt (downed state has no world position to key a
    prompt off — needs new proximity + HUD + input plumbing);
    TD leaked-enemy kill score (leaked enemies still award
    kill score — no despawn hook exists yet).

UNIFIED FORGE — v0.5.12
----------------------
  - ONE Forge box: type anything — if it exists, it spawns; if
    not, it is made for this match. The second MAKE box is gone;
    the MAKE section now shows status + history only.
  - Fixed "weapon id missing": installed mods (like the taquito
    launcher from Create-a-Mod) now spawn from the Forge menu
    instead of being rejected by the legacy validator.
  - MAKE only fires as a fallback when Forge answers "Don't
    know". Refusals and validation errors never trigger a
    generation. Generated things stay session-only, never saved;
    installed things stay permanent.
  - Script mods now work in Loadouts through the same give path
    as Forge — including a script mod in the secondary slot
    without clobbering primary. Disabling a mod degrades its
    weapon to the plain base form instead of vanishing it.
  - Longest-match name resolution: "give me the taquito launcher
    script" now finds the script mod, not the JSON one.

MOD SHARING — IMPORT / EXPORT — v0.5.10
---------------------------------------
  - Create-a-Mod (main menu) now has a REAL Import/Export tab.
    EXPORT turns any installed mod into ONE share code
    (MOD1-... — compressed, self-contained: full mod payload +
    hook scripts + voxel assets). COPY it and send it to a
    friend; they paste it into IMPORT.
  - IMPORT runs the SAME validation as generation (schema +
    forbidden-API scan + hook allowlist) and shows the SAME
    approval screen — summary, full payload, hook list — before
    anything installs. Tampered codes are rejected with a
    visible reason. Import alone installs nothing.
  - CONFLICTS: importing a mod you already have offers Replace
    (bumps version, swaps content) or Keep Both (installs a
    renamed copy, original untouched). Block mods copy to
    <id>_copy; script mods copy to <id>_2.
  - Export is mod-only: it never includes your DeepSeek key
    or any other settings.

FORGE LOOPS — v0.5.10
--------------------
  - BASE DEFENSE (new mode, main menu): build phase (Forge
    auto-opens, 20s intermission) -> combat wave -> repeat.
    A voxel core (1000 HP) sits at the arena centre; the run
    ends when the core falls. Player death does NOT end the
    run (3s redeploy). Enemies within 35m assault the core;
    Forge structures within 30m absorb damage first (up to
    8 DPS into their own HP), overflow hits the core.
  - MODS IN ARSENAL / LOADOUTS: installed JSON weapon-mods
    are first-class weapons, keyed mod:<mod_id> — they list
    in Arsenal, equip and fire with hooks, and loadouts
    accept mod ids and persist them. Script weapon-mods stay
    Forge-only.
  - EDIT INSTALLED MODS: per-row EDIT in the Mods tab seeds
    the creator with the installed mod; approval shows a
    DIFF (Version 1.0 -> 1.1, changed fields) before Install
    updates it in place. Discard leaves it untouched.
  - take_damage HOOK: new hook point firing BEFORE damage
    applies — shield (absorbing pool), vulnerable (damage
    multiplier), thorns (reflects a share of damage actually
    taken), petrified (nullifies ALL damage + pins). Order:
    petrified -> vulnerable -> shield -> thorns. Constructs
    and elementals are immune to petrified.
  - MAKE PARITY: MAKE builds now go through ForgeManager —
    history record, shared undo slot, MP-sync, PLACED
    STRUCTURES listing, history search. Script-shaped MAKE
    ("a wall that explodes when enemies touch it") now WORKS
    in-session: hooks re-validated + compiled in memory,
    zero file I/O, never written to user://mods/. Peers get
    the plain structure only — session hooks run on the
    maker's machine.

D&D 5e — CREATURE TYPES + CLASSES + ELEMENTAL EMITTERS — v0.5.10
------------------------------------------------------------
  - D&D 5e CREATURE TYPES: every enemy has one of the 14
    creature types (aberration, beast, celestial, construct,
    dragon, elemental, fey, fiend, giant, humanoid, monstrosity,
    ooze, plant, undead) with REAL enforced immunities and
    resistances — constructs and undead ignore poison, fiends
    resist cold/fire/lightning, elementals ignore poison/sleep/
    exhaustion/restrained/prone, oozes resist acid. Immune
    means no damage, no flinch, no flash. Forge can spawn by
    type: "spawn an undead brute", "a fiend warlord".
  - ABILITY SCORES: every enemy carries a real STR/DEX/CON/
    INT/WIS/CHA stat block (modifier = floor((score-10)/2)).
  - 12 PLAYABLE CLASSES, swappable MID-MATCH: barbarian, bard,
    cleric, druid, fighter, monk, paladin, ranger, rogue,
    sorcerer, warlock, wizard. Say "make me a rogue" in the
    Forge console, or use the new CLASS tab in the Forge menu.
    Every modifier is real: barbarian +40% HP / take 25% less
    damage, wizard halves Forge cooldown, rogue +25% crit,
    fighter Second Wind, and more. Swapping keeps your HP
    fraction — it can neither heal nor hurt you.
  - ELEMENTAL EMITTERS: 10 elements — fire, cold, lightning,
    acid, poison, radiant, necrotic, thunder, force, water.
    Build one from Forge ("build a lightning emitter"), or put
    an element on a turret / weapon (+75). Real interactions:
    water extinguishes burn and leaves targets WET; lightning
    vs a wet target deals x1.5 and chains to a nearby enemy.
    Emitters damage ENEMIES ONLY.
  - SPELL SCHOOLS: spell-like mods carry one of the 8 D&D
    spell-school tags (abjuration … transmutation), shown on
    approval and in the Mods tab. Tag only — never changes
    mechanics.
  - DOT ticks are now TYPED damage (burn = fire, poison =
    poison, bleed = slashing), so creature resistances apply
    to damage-over-time too, and status immunities are gated
    in one place. Mods can read creature types / immunities /
    ability modifiers via new ModAPI getters.


EFFECTS + DIAGONAL STRUCTURES — v0.5.7
--------------------------------------
  - Effect table expanded: poison, bleed, regen, haste, restrained,
    prone, sleep, confusion, blind, weaken, exhaustion, pull — plus
    9 D&D damage types (fire, cold, lightning, thunder, acid,
    necrotic, poison, psychic, radiant), each with a real rider
    that makes the type mechanically distinct (fire burns, cold
    slows, lightning knocks back, thunder knocks back + knocks
    prone, acid weakens, necrotic adds exhaustion, poison poisons,
    psychic confuses, radiant blinds). All genuinely implemented —
    no lookalikes. Deliberate omissions (stun, petrified, shield,
    etc.) are documented in BUILD_LOG: kinds with no real hook
    behind them are refused, never faked.
  - Structures: the full buildable catalog is now in the Forge
    prompt, and placement supports real diagonal / rotated builds:
    "build a diagonal ramp" builds a ramp rotated 45 degrees
    (also "sideways" = 90, "backwards" = 180, "rotated N degrees"
    = N). Ghost preview shows the same rotation.
  - Inexpressible geometry never builds silently wrong: a spiral
    staircase or dome gets a visible refusal, and a close
    approximation is labeled as one ("Closest I can build:
    straight stairs") before you confirm.


LLM-AUTHORED HOOK SCRIPTS — v0.5.6
----------------------------------
  - When the effect table doesn't cover your request, the LLM may
    now author a GDScript hook (extends ModHook) for the mod —
    data hooks from the effect table are still preferred whenever
    they can express it. Code hooks are the fallback for genuinely
    new behaviour, not the default.
  - Hook scripts may call ONLY the ModAPI allowlist (ModAPI
    HOOK_ALLOWED_*) plus listed safe builtins — anything else is
    rejected with the violation named. A hook that errors at load
    or run disables its mod visibly, never crashes.
  - Step/time budget: at most 200 ModAPI calls and 100 ms per hook
    run, 250 ms per dispatch. Exceeding it aborts the dispatch and
    disables the mod visibly.
  - Approval shows the hook script source and labels it
    LLM-authored. TEST IN SANDBOX runs code hooks against the
    dummy and reports what they did.
  - Honest limit: a tight loop with no API calls cannot be
    preempted (GDScript has no preemptive timeout) — it hangs the
    frame. `while` loops are rejected at validation; use bounded
    `for` loops.


STATUS EFFECTS FOR INVENTED HOOKS — v0.5.5
------------------------------------------
  - Mods can now apply real STATUS EFFECTS: slow (speed x factor
    for N seconds), freeze (speed 0), burn (damage per second),
    and knockback (impulse away from the hit). They work on
    on_hit / on_kill (the hit target) or on_damage_taken (you).
  - The Bubble Blaster gap is closed: before this release the
    effect catalog had no slow, so a "slows enemies" blaster
    could only express slowing as smoke + a message. Now slow
    is a first-class effect kind.
  - The sandbox REPORTS status effects: e.g. "SLOWED: dummy
    speed 4.0 -> 2.0 m/s for 3.0s." / "BURNING: 10 damage/s
    for 5.0s." / "KNOCKBACK: force 12." Approval screens list
    effects per hook, so you see them before installing.
  - CONTRIBUTING.md (in the repo) documents how to add a new
    effect kind in six steps.


CHAT IN CREATE-A-MOD — v0.5.5
-------------------------------
  - Create-a-Mod (main menu) now has FOUR tabs: CREATE / CHAT /
    MODS / IMPORT-EXPORT.
  - The CHAT tab is a free-form conversation with the model:
    message bubbles, suggested prompts (including "What can you
    do?"), CLEAR / NEW CHAT, and CREATE FROM CHAT.
  - Chat and Create share ONE session (last 20 messages, saved
    across restarts), so you can brainstorm in chat and then
    turn the conversation into a mod — it goes through the same
    generation → validation → approval → Install flow.
  - Chat answers are grounded in the true capability list, and
    the greeting lists what the creator can actually do.
  - Same DeepSeek key as Forge. No key or an LLM failure shows
    a visible error — there is no silent offline fallback.
    Chat never installs anything on its own.

FORGE MAKE + INVENTED HOOKS — v0.5.3
------------------------------------
  - Forge MAKE: one-box creation in the Forge menu. Type one
    prompt, get a one-shot creation that lives for THIS SESSION
    ONLY — never saved, gone on quit. For quick experiments
    without cluttering your mod list.
  - Create-a-Mod can now INVENT HOOKS: when no existing hook
    expresses what the mod needs, the generator may create a
    new hook/script for it. Forbidden APIs are still rejected,
    and the approval screen lists invented hooks explicitly.
  - Custom projectiles fire in the REAL GAME now, not just the
    sandbox: a Long Laser Pistol fires a beam; a watermelon LMG
    fires watermelons that explode on impact.
  - Known limits: script-mod candidates can't run in-session
    via MAKE (it refuses and points you to Create-a-Mod); MAKE
    skips Forge undo / MP-sync / history; on_damage_taken
    damage_mult above 1 is ignored; turret damage hooks
    aren't wired yet.


CREATE-A-MOD FIXES — v0.5.2
----------------------------
  - Sandbox test now flies the candidate mod's PROJECTILE (what
    the mod fires), not a generic launcher. The weapon visual
    still shows at the shooter, static, so you can see both.
  - Mods lists fixed in BOTH the Create-a-Mod menu and the Forge
    menu: the list was rendering at 0px tall (invisible) because
    of a nested-scroll layout bug. Installed mods show up
    immediately after install now.


FORGE BATCH — v0.5.2 (BUILDING IS FREE FOR NOW)
-------------------------------------------------
  - Forge budget is OFF: building costs nothing right now
    (costs are still computed and shown; the budget may come
    back later). The 12-structure cap stays (performance).
  - Ghost preview: structure prompts show a translucent ghost
    first — INTERACT places it, ESC cancels. After placing,
    the Forge menu's PLACED STRUCTURES list lets you MOVE /
    ROTATE / REPAIR / DELETE.
  - Destructible structures: enemies can damage Forge
    structures; repair with the interact key nearby (or the
    REPAIR button). Structures break at 0 HP.
  - Forge in multiplayer: placed structures sync to every peer.
  - Real per-weapon Forge costs (shown in the preview).
  - New Build presets: stairs, ramps, walls, jump pads
    (launch you), cover pieces, sniper nests.
  - Shareable build codes: COPY LAST CODE in Forge, send the
    code to a friend, paste it in BUILD FROM CODE to rebuild.
    History is searchable.
  - CREATE A MOD (main menu): its own menu with CREATE / CHAT / MODS /
    IMPORT-EXPORT tabs. The CREATE form takes categories
    (multi-choice), name, visual description, and logic —
    e.g. "an LMG that shoots watermelons. The watermelons
    explode on impact." The pipeline generates the mod +
    a procedural voxel model (cached, reused for the same
    description), then shows summary + full payload for your
    approval (Install / Discard / Regenerate). TEST IN SANDBOX
    tries it in a test room before it touches the real game.
    IMPORT/EXPORT is now real (v0.5.10): Export any installed mod to a MOD1- share code, Import one from a friend — see MOD SHARING above.
  - Voice forging v2 (Android): the MIC prompt now shows
    what was heard and waits for CONFIRM / RETRY / CANCEL
    before building anything. Push-to-talk: hold MIC, release
    to send — nothing builds until you confirm.

PROGRESSION — XP, LEVELS, UNLOCKS, LOADOUTS, STATS
---------------------------------------------------
  Earn XP from kills, Domination captures/holds, match wins,
  wave survival, and puzzle-chamber completions. Level up to
  unlock titles, emblems, voxel camo recolors, and extra
  custom loadout slots. Nothing playable is locked — unlocks
  are additions, not removals.
  Main menu > LOADOUTS: build and pick persistent custom
  loadouts (weapon + Forge preset) — the same loadouts the
  Forge tab uses. Main menu > STATS: lifetime kills, deaths,
  K/D, accuracy, wins/losses, best Endless wave/score, and
  per-weapon / per-mode stats. Progress and stats persist
  across updates.

NOTES
-----
- Voice forging (MIC) is Android-only; on Linux the Forge
  console is typed. A DeepSeek key can be entered in-game in
  the Forge menu for live AI builds.
- User mods live in ~/.local/share/godot/app_userdata/FORGEFALL/mods/
  (the standard Godot user:// folder on Linux). JSON blocks and
  GDScript ModBlock scripts work the same as on Android.
- In-game updater: the game checks for updates on launch
  (Options > CHECK FOR UPDATES for a manual check). When one is
  ready, confirm Download, then INSTALL NOW — a helper script
  waits for the game to quit, copies the new files over the
  install folder, and relaunches. If the helper ever fails, the
  dialog shows the downloaded ZIP path — unzip it over your
  install folder and relaunch.
- Free, no account or sign-in needed.
