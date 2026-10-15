# FORGEFALL — Build Log

## v0.5.1 — FORGE BATCH: budget off, ghost preview, destructible structures, MP Forge, per-weapon costs, new presets, build codes, Create-a-Mod widget, voice v2 (2026-10-15)

### Shipped (Forge batch items 1–9 + directives A–D; item 10 Quick Forge SKIPPED per Colin)
- **A. Budget OFF:** Forge building is free. `ForgeManager.BUDGET_ENABLED = false`; costs still computed + shown (needed for item 5 + future re-enable), never enforced. Structure cap 12 STAYS (perf guard). Budget UI hidden: Forge menu budget label + HUD budget label (hidden, still wired) + topbar BUDGET + "budget is real" / "spend budget" announcements removed.
- **B. Create-a-Mod is its own MAIN-MENU widget:** main-menu CREATE A MOD button (after STATS) opens `ModCreatorMenu` (NEW `scenes/ui/mod_creator_menu.tscn` + `scripts/ui/mod_creator_menu.gd`): tabs CREATE / MODS / IMPORT/EXPORT. IMPORT/EXPORT is placeholder/disabled only (note + two disabled buttons, nothing wired). Old Create Mod panel REMOVED from the Forge menu's Mods tab (one create flow, no duplicates); Forge Mods tab keeps list/enable/disable/Rescan.
- **C. CREATE tab = structured form:** multi-choice CATEGORY checkboxes (Weapon, Block/Structure, Enemy, Effect, Gameplay) + NAME + VISUAL DESCRIPTION + LOGIC. `compose_prompt()` feeds the EXISTING generation → strict validation → approval (summary + FULL payload → Install/Discard/Regenerate) pipeline.
- **D. Voxel asset generation + cache:** NEW `scripts/mods/voxel_asset_generator.gd` — local keyword-driven procedural voxel builder, no downloads. Watermelon = bespoke (green striped rind, red interior, black seeds); everything else = shape × colour × pattern, generic blob fallback. Cache keyed by sha256 of normalized description in `user://mods/assets/<sha256>.json`; approval shows voxel count + HIT/MISS. Generated mods wire the custom projectile visual + logic behaviour through the existing validated mod path.
- **1. Aliases:** offline parser resolves "burst rifle"/"trident"/"burst"/"3-round" → trident (br3), "judge"/"revolver"/"heavy revolver"/"six-shooter" → judge (hv44), multi-word mod names offline (single-word mod names deliberately don't match offline — e.g. mod "wall" would hijack base prompts; reachable via LLM catalog).
- **2. Ghost preview + edit placed structures:** structure prompts (offline parse) show a translucent ghost (valid green-ish / invalid red-ish, no live collision, never joins `forge_structure`) — INTERACT confirms (build goes through `ForgeManager.build_spec_direct` → history + MP sync + undo), ESC cancels + reopens menu. Forge menu PLACED STRUCTURES list (group `forge_structure`): MOVE (ghost move-preview) / ROTATE 45° / REPAIR / DELETE. `ForgePlacement` gains `_input` (interact/ui_cancel, marks handled), `preview_confirm_requested` / `preview_confirmed` / `preview_cancelled` signals, hint label (CanvasLayer), `start_move_preview()`.
- **3. Destructible Forge structures:** NEW `scripts/forge/forge_structure.gd` (live HP, `take_damage()`, flash + crack cubes + low-HP <35% smoke, destroy-at-0 with DebrisPool burst, `repair()/repair_full()`, F/Y interact repair within 3.2 m) + NEW `scripts/forge/forge_enemy_pressure.gd` (enemies damage structures without touching enemy code: every 0.9 s, ≤1 engaged enemy within 20 m with LOS lands one hit for its own damage × director `dmg_mult`). HP table: bunker 600 > wall 400 > sniper nest 350 > bridge/ammo depot 300 > stairs/ramp 250 > cover piece/jump pad 200; reinforced ×1.5.
- **4. Forge in multiplayer:** NEW `scripts/net/net_forge_sync.gd` + RPCs in `scripts/net/net_manager.gd` (single-RPC-endpoint rule). Host-authoritative: host validates + assigns instance ids + broadcasts; clients send requests. Events `{instance_id, preset_id, owner, pos, rot, spec}`; presets `cover:*`, `structure:<all 10 shapes>`, `turret`, `pickup:*`, `mod:<block_id>`. Provisional client placement → host echo adopts (no duplicate); destroy/move/rotate sync; late-join snapshot on `peer_connected` + `forge_request_resync()` after MP map load in `Main._on_mp_start`. Robustness: unknown presets / malformed entries (NaN, negative id, out-of-arena, spec mismatch) ignored, never crash; forged broadcasts (sender ≠ 1) ignored; requests host-only + rate-limited (10/s); duplicates dedupe; removals idempotent. Known by-design divergence: cover HP is per-node local (client-side fracture doesn't destroy the host's copy until the host's copy also breaks).
- **5. Real per-weapon Forge costs:** flat 200 killed. `ForgeLLM.weapon_cost()` = `clamp(round5(75 + sqrt(dmg×pellets×rpm×mag)/4 + dmg×pellets), 100, 350)`: manticore 280, longeye 235, breacher 220, hornet 270, p9 180, raptor 150 (fixed utility), lmg 350 (clamped), trident 310, judge 200 — all distinct, computed + shown, enforcement OFF per A. `Tuning.FORGE_COST_WEAPON` kept with a deprecation comment (zero-risk vs deleting).
- **6. More Build presets:** stairs, ramps, walls, jump pads (NEW `scripts/forge/forge_jump_pad.gd`: 12.5 m/s vertical, ~3.9 m apex, +3.5 m/s forward, 0.4 s retrigger cooldown), cover pieces, sniper nests — 10 structure shapes total in builder/parser/validator/SYSTEM_PROMPT/BLOCK SCHEMA. Costs: stairs 100, ramp 90, wall 120, jump pad 150, cover piece 60, sniper nest 220.
- **7. Shareable build codes:** `FORGE1-` + base64url(JSON of ModSpec); `encode/decode_build_code()` pure (garbage → `{}`, integral floats → ints); decoded specs never trusted (manager re-validates). Forge menu: history-search field + build-code row (paste + BUILD FROM CODE + COPY LAST CODE).
- **8. Create Mod: sandbox test before install:** NEW `scenes/ui/sandbox_test_room.tscn` + `scripts/ui/sandbox_test_room.gd` — flat voxel room, 2 dummies, candidate's generated voxel visual as projectile; TEST IN SANDBOX → FIRE TEST SHOT → impact flash + dummy topples + HIT/explosion result. Install stays available regardless. Sandbox NEVER executes the candidate script (simulates declared behaviour) and NEVER writes to the mod list or progression.
- **9. Voice forging v2:** `scripts/android/speech_input.gd` rewritten, same public contract. State machine IDLE → PERMISSION_PENDING → LISTENING → CONFIRMING → IDLE. Recognized transcript waits in CONFIRMING with a modal prompt (heard text + CONFIRM / RETRY / CANCEL + TYPE INSTEAD) — NO Forge action fires without confirmation. Push-to-talk: `end_ptt()` arms confirm, sends nothing; listening banner shows live countdown to visible 12 s timeout; tap-MIC-again while LISTENING cancels; every exit returns to IDLE; stale `_session_active` guard ignores late `onResult`. Deferred: true recognizer-level `stopListening()` — ForgeSpeech exposes only `startListening()` + `onResult()`; cancel/timeout/release close the session GDScript-side and the stale guard ignores the late result; the CONFIRM step makes this safe. Adding `stopListening()` is a small Java addition + AAR rebuild — plugin follow-up.

### Coordinator integration (this entry's author)
- `forge_llm.gd`: offline parser split for the 6 new shapes (sniper nest FIRST — contains "tower"; ramp split from bridge; jump pad / cover piece / stairs; "cover wall" phrase → cover wall before bare "wall"; bare "wall" → structure wall per F's expectation); `_is_int_in` accepts integral floats (JSON parses all numbers as float — the live LLM path was rejecting valid cover/enemy_spawn specs); `_base_cost` + `_validate_params` + SYSTEM_PROMPT + BLOCK SCHEMA extended to all 10 shapes; weapon `base_weapon_id` list += trident|judge; `BASE_WEAPON_IDS` in `mod_loader.gd` += trident|judge.
- `forge_manager.gd`: `VALID_STRUCTURES` → all 10; `build_spec_direct(spec)` (busy/cooldown gates → shared `_execute_spec` tail).
- `forge_menu.gd`: `_submit_prompt` ghost interception (offline parse → structure → ghost; non-structure keeps instant path); PLACED STRUCTURES section + handlers; 5 new Build presets.
- `hud.gd`: budget UI hidden (see A above).
- `mod_loader.gd`: `scan_mods()` skips the `assets` cache dir (it appeared as a broken mod entry — missing manifest — in the Forge Mods tab; D's MODS tab filtered it).
- `main_menu.gd`: short-screen tightening for the 8-button stack (title factor 0.095→0.075 + separation 1→0 on vp.y < 900; stack min 827→789 at 1280×800; buttons are floored at 56px by theme, so the win came from title + gaps).
- `main.gd`: `NetManager.forge_request_resync()` after MP map load.
- Test-suite updates: `verify_forge_batch.gd` voice section drives the REAL SpeechInput path (`test_start_session` + `simulate_transcript` + button presses + interact event into the placement node — calling `_on_voice_text` directly bypasses confirm by design); `verify_v08_create.gd` drives the new `ModCreatorMenu` (form fields + GenerateButton + CheckButton categories + ImportExport placeholder; `_list_recursive` skips the voxel cache dir; the old `_menu.call("open")` HUNG the run — `ModCreatorMenu` has no `open()` and `call()` on a nonexistent method stalls the SceneTree script; fixed by not calling it); re-baselined `verify_v05_b2_forge_backend.gd` (sniper 200→235, wall → structure wall 120 / cover wall 100, budget OFF charge/refund 0, weapon given as arsenal id `lr8`, stale ramp→bridge duplicate removed) + `verify_v062.gd` (LMG+sniper 250→400, manticore+buckshot 250→330, longeye 200→235).

### Verification
- `verify_forge_batch`: **143/143 ALL PASS** (budget-off 4, aliases 9, ghost-edit 18, destructible 7, mp-sync 9, per-weapon-costs 4, presets 41, build-codes 13, creator 24, voice-confirm 10, setup 4).
- `verify_v08_create`: **74/74 ALL PASS** (0 skipped).
- `verify_v05_b2_forge_backend`: **104/104 PASS**. `verify_v062`: **ALL PASS**.
- `verify_menu_layout`: **1060 passed, 0 failed** (was 1057/3 at 1280×800 before the title/gap fix).
- Regressions ALL PASS: verify_fixes, verify_v06_movement, verify_feel (83/0), verify_sound (725/0, 8 warnings), verify_content (495/0), verify_updater_pc (65/0), verify_multiplayer (180/0, 7 needs-device), verify_portals (ALL), verify_progression, verify_linux, verify_windows (48/48). 900-frame smoke clean, exit 0. `check_scripts`: 148 checked, 4 failed — all known pre-existing `android/build/` scaffolding files.
- Android APK: apksigner OK (v2+v3 true), aapt com.sparky.forgefall versionCode 27 / 0.5.1, manifest UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data + REQUEST_INSTALL_PACKAGES + RECORD_AUDIO, classes2.dex = stock XRMode (1960 B), classes14 = ForgeUpdaterPlugin + UpdateStatusReceiver, classes15 = ForgeSpeechPlugin. Linux binary headless --quit-after 120, exit 0. Windows PCK probe: all 10 Forge-batch files present + loadable.

### Version bump
- `export_presets.cfg`: `version/code=27`, `version/name="0.5.1"`; Windows preset export_path → `windows_staging/forgefall-v0.5.1-windows/`.
- `scripts/core/tuning.gd`: `FALLBACK_VERSION_CODE := 27`.

### Builds (all from the same current source)
- **Android** `updates/forgefall-v0.5.1-debug.apk` (30,790,040 bytes, SHA-256 `62c0a6e7eca6dfbcc083626f7c58509794259af3d5c729a633e788c0a485ba3b`) + `.idsig`. Godot 4.7.2 headless `--export-debug "Android"`, unchanged custom template (Godot signs + emits the .idsig).
- **Linux** `linux_staging/forgefall-v0.5.1-linux.zip` (29,882,908 bytes, SHA-256 `86bd7d414fa65e233f9ff4b08d864987a68eab5a3f97968b400a2f5211a741a6`): binary + forgefall.pck + forgefall.sh + README-LINUX.txt (0.5.0 → 0.5.1, + FORGE BATCH section, renumber note dropped).
- **Windows** `windows_staging/forgefall-v0.5.1-windows.zip` (36,810,423 bytes, SHA-256 `da5a6adb91ea25975e32d49d777e0f8c3953e72abfad1cb8035929498cb9e2c5`): forgefall.exe + forgefall.console.exe + forgefall.pck + README-WINDOWS.txt (0.5.0 → 0.5.1, + FORGE BATCH section).

### Publish
- **GitHub Release** [v0.5.1](https://github.com/vatherty/FORGEFALL/releases/tag/v0.5.1) in `vatherty/FORGEFALL` — all 3 artifacts attached, all `uploaded`, sizes match local builds. Helper extended: `github.py` gains `release-create` (POST /releases); also fixed two helper bugs found during publish — `pages-enable` had no handler (silently did nothing) and `release-upload` ended with a stray Pages POST after every asset upload (removed; likely contributor to the `errored` state).
- **Pages** (`vatherty/Forgefall-updates`): binaries uploaded first, then `version.json` + `version_pc.json` (0.5.1 / code 27) + `index.html` (0.5.1 links; also fixed the stale "no native gamepad bindings" Deck line → native gamepad). Transient `errored` Pages state after upload (known pattern): re-applied pages-enable (409 = already enabled) + ~2.5 min wait → `built`. Live verified: manifests 200 (0.5.1/code 27), all three artifacts 206, index.html with 0.5.1 links, downloaded APK sha256 matches the local build hash. `.nojekyll` verified still present (empty). Old v0.5.0 files stay as unlisted archive.
- Local `updates/` mirror synced (new index.html + version.json + version_pc.json + APK).

### Deferred / follow-ups (not in this batch's scope)
- Import/Export tab (placeholder by design). True recognizer-level `stopListening()` (needs Java/AAR change — plugin follow-up). Per-weapon accuracy, Raptor shots/hits not counted, exit-area blockage check for portals, portals on moving platforms, no download-resume for the updaters, co-op waves, host migration, late join, per-weapon puppet viewmodels, per-surface footsteps, chopper sting, portal hum loop, jump takeoff sound, barrel explosion hook, Domination hand-tuned points, boss HP bar, title/emblem/camo equip UI (Colin: playtest first).
- Needs Colin's on-device verdict: creator form feel, watermelon LMG in-game, ghost preview, MP Forge sync (incl. real two-device ENet), voice confirm (confirm-prompt layout on S23, banner readability, recognizer latency, hold-to-talk feel, permission flow), creator layout/touch on S23, sandbox feel, real-LLM watermelon-LMG quality, ghost tint readability, 1280×800 layout on Deck.
- The old Netlify site remains untouched serving v0.7.0. Colin's installed v0.7.0 polls Netlify, so getting onto the GitHub track still requires one manual Android install from the Pages/Release link. Installation has **not been confirmed**.


## v0.5.0 — RENUMBER: public open-source release (2026-10-15)

- **Renumber, display name only:** the release previously called v0.9.5 is now **v0.5.0**. `export_presets.cfg` `version/name` 0.9.5 → 0.5.0 and the Windows `export_path` `forgefall-v0.9.5-windows` → `forgefall-v0.5.0-windows`; `tools/verify_updater_pc.gd` manifest expectations 0.9.5 → 0.5.0 (name + Windows/Linux zip URL suffixes). **Version code UNCHANGED: `version/code=26`, `Tuning.FALLBACK_VERSION_CODE := 26`.** The code is what the in-game updater compares — resetting it would brick updates for existing installs (a device on code 26 would see a lower code as "newer"). Older BUILD_LOG entries below keep their historical 0.9.x names; they describe past releases, not the current one.
- **Open source:** full source published to public repo `vatherty/FORGEFALL` (MIT). The public tree excludes build outputs (`builds/`, `updates/`, `*.apk`, `*.zip`, `*.pck`), the Godot import cache (`.godot/`), regenerable editor leftovers (`*.import`), staging dirs (`*_staging/`, `.apkmod/`), the generated Android build template (`android/`, regenerable via Godot's "Create Android Build Template"), and all keystores/passwords — the public `export_presets.cfg` has blanked keystore password fields. The 4 `.aar` plugin binaries under `addons/ForgeUpdater/bin/` + `addons/ForgeSpeech/bin/` ARE included: they are build inputs the Android export needs and no Java/Kotlin source for them exists in-tree (documented in README).
- **Small fix folded in:** `scripts/android/touch_controls.gd` `_release_all()` skipped `Input.action_release("")` for buttons with no InputMap action (the MIC button passes `""`) — that call logged the pre-existing smoke ERROR `InputMap action ""`. MIC mode was already special-cased in `_btn_down`/`_btn_up`; now the release path matches. No gameplay behavior changed.

## v0.9.5 — Goal 6 PROGRESSION: XP + levels + unlocks, persistent loadouts, stats (2026-10-15 ~01:55 MDT)

### Shipped (gameplay by the Goal 6 PROGRESSION workers — this entry covers coordinator integration + build + publish)
- XP + levels + unlocks (Worker A): NEW `scripts/progression/progression.gd` (autoload "Progression"). XP from kills (100, +50 headshot, +100 brute, +400 warlord), wave clears (100 + 25×wave), Domination captures (150) / holds (5/pt/sec), match ends (win 500 / draw 150 / loss 50), endless run-overs (200 + 25×wave, +250 new best), puzzle first-clears (300/chamber, replays 0). Level curve: L1–4: 500, L5–9: 1000, L10–19: 1500, L20–29: 2500, L30–49: 4000, L50+: 5000 (L50 @ 127,000 cumulative; no cap). 23 unlocks: 7 titles, 6 emblems, 6 voxel-recolor camos (Color pairs, no models/stats), 4 extra custom loadout slots (2 base → 6). Nothing playable is locked. Persisted to user://progression.json with version-tolerant load (corrupt/wrong-typed → defaults, never crashes). Every event forwarded to Stats via guarded get_node_or_null("/root/Stats") + record_event with xp_awarded. Hook call sites (one guarded line each): enemy_base.die() ("kill"), wave_manager.on_enemy_died ("wave_cleared"), game_mode (domination_capture / domination_hold / match_end / endless_run_over), room_base._finish_room ("puzzle_complete"). Verification: /tmp/probe_progression.gd 84/84 PASS.
- Persistent loadouts (Worker B): NEW `scripts/progression/loadouts.gd` (autoload "Loadouts") — ONE shared loadout store in user://loadouts.json (`{version, active, loadouts:[{name, primary, secondary, forge_preset}]}`). Seeds the 5 Forge-tab presets verbatim (Assault/Marksman/Breacher/Raptor/Burst); the Forge tab has no store of its own, so no divergence. Slot cap from Progression (guarded; default 5 when absent); cap gates creation only, never truncates saved loadouts. Version-tolerant load. `apply_active_to(wm)` is the Deploy hook. NEW `scripts/ui/loadout_picker.gd` + `scenes/ui/loadout_picker.tscn`: self-contained full-screen picker — view/select/create/rename/delete, active used on Deploy, Forge-preset dropdown, SLOTS n/max + NEW disabled at cap. Main-menu COMING SOON / ComingSoonButton replaced by enabled LOADOUTS / LoadoutButton → picker. Verification: /tmp/probe_worker_b_loadouts.gd 73/73 PASS.
- Stats (Worker C): NEW `scripts/progression/stats.gd` (autoload "Stats") — lifetime kills/deaths/K-D/wins/losses/draws, accuracy (shots/hits), time played (in-memory accumulate, flush ≤ every 60 s + on quit), best Endless wave/score, per-weapon kills, per-mode matches/wins/losses/draws, captures, Domination hold points, waves cleared, puzzles solved, headshot kills. `record_event(type, data)` accepts the task-spec vocabulary plus Progression's forwarded vocabulary (mp_kill, wave_cleared, domination_capture/domination_hold, match_win, match_end with draw, endless_run_over) and plural aliases. Persisted to user://stats.json, version-tolerant (missing/malformed/old/hostile → field-by-field defaults, never crash). Weapon hooks: one shot per round fired, one hit per round that damaged ≥1 enemy (not per pellet); player death hook in _die(). Raptor throw not counted as shot (no hitscan). NEW `scripts/ui/stats_screen.gd` + `scenes/ui/stats_screen.tscn` — full-screen modal (UiScale fonts, scrolling flow), LIFETIME / PER-WEAPON KILLS / PER-MODE / BEST ENDLESS sections, BACK + two-tap-confirm RESET. Verification: /tmp/verify_stats_probe.gd 68/68.
- Coordinator integration (this entry's author): registered the three autoloads in project.godot (Progression/Loadouts/Stats). Applied Worker A's net_match snippets (multiplayer files were out of Worker A's scope): match-end XP hook in `_finish_match` (host) AND `_rpc_match_end` (clients — the host never self-fires call_remote RPCs, so no double-report), plus MP-kill XP in `_apply_kill` (killer's machine only); all three guarded by `multiplayer.has_multiplayer_peer()` so offline test drives never award XP. Wired `Loadouts.apply_active_to` into `Main._wire_player` (covers SP Deploy, MP matches — every peer equips its own active loadout — and puzzle chambers). Added `Main.open_stats_screen()` + `_on_stats_closed()` (mirrors the MP menu pattern) and the main-menu STATS button. Added `class_name StatsScreen` (Worker C's snippet assumed it; the file had none). Added `Progression.get_max_loadout_slots()` alias = 5 Forge presets + custom slots (Worker B probes that name; Worker A originally exposed only the custom-slot count — without the alias the cap would have stayed at the 5-preset fallback and no custom loadout could ever be created). Fixed a REAL layout regression my STATS button caused: 7 buttons overflowed 1280x800 (stack measured 830 > 800, footer out of viewport) — `_layout_stack()` now tightens stack separation 5→2 on short screens (vp.y < 900), stack ~788, footer back inside; tall screens unchanged. Updated `tools/verify_menu_layout.gd` to the Goal 6 menu (LOADOUTS + STATS expected, COMING SOON expected zero) and `tools/verify_updater_pc.gd` manifest expectations to 0.9.5/code 26. Process notes: Worker A self-caught three over-indented hook lines (game_mode:262 flagged by Worker B + two more); Worker C self-caught its `var stats :=` Variant-inference parse error (weapon_base:319) and hardened 4 sibling sites. Probe artifacts, not defects: standalone `--check-only` never resolves autoload globals (`Identifier not found: Game/Sfx`); the global class cache went stale for the new `StatsScreen` class_name (fixed by one headless editor rescan); a SceneTree probe calling `report_event` in `_initialize` sees `is_inside_tree() == false` (forwarding correctly bails) — defer to a `_process` frame. Linux export preset is named "Linux Desktop", NOT "Linux" (a bare "Linux" export fails with "Invalid export preset name").

### Verification
- verify_progression: **67 passed, 0 failed** (discovery 3, xp 22, levels 7, unlocks 8, loadouts 7, menu 4, stats 10, integration 6). Note: the suite's loadouts section is 7 checks post-integration, not 8 — its cap-rejection check only runs when the store is full, and with Progression registered the cap is 7 (5 seeded + 2 custom), so the store isn't full at seed; cap behavior is covered by the coordinator integration probe below.
- Coordinator integration probe (/tmp/probe_g6_integration.gd, boots the real Main scene): **25/25 PASS** — all three autoloads live, cap 7 at L1 (2 customs creatable, 3rd refused), kill → +100 XP + Stats kill recorded (A→C forwarding live), STATS press opens the screen + close restores the menu, LOADOUTS press opens the picker, no COMING SOON.
- Windows PCK probe (load_resource_pack on the shipped PCK): all 7 Goal 6 files present, Progression loads (level 1, max slots 7), PCK-compiled Progression forwards a kill to Stats (0→1).
- Regressions ALL PASS: verify_fixes, verify_v06_movement, verify_feel (83/0), verify_sound (713/0), verify_content (495/0), verify_updater_pc (65/0), verify_multiplayer (180/0, 7 needs-device), verify_portals (62/62), verify_menu_layout (975/0 after the separation fix), verify_linux, verify_windows (48/48). 900-frame smoke clean, exit 0.
- Android APK: apksigner OK (v2+v3), aapt com.sparky.forgefall versionCode 26 / 0.9.5, manifest UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data + REQUEST_INSTALL_PACKAGES + RECORD_AUDIO, classes2.dex = stock XRMode (1960 B), classes14/15 present. Linux binary headless --quit-after 900, exit 0.

### Version bump
- `export_presets.cfg`: `version/code=26`, `version/name="0.9.5"`. Windows preset export_path moved to windows_staging/forgefall-v0.9.5-windows/.
- `scripts/core/tuning.gd`: `FALLBACK_VERSION_CODE := 26`.

### Builds (all from the same current source)
- **Android** `updates/forgefall-v0.9.5-debug.apk` (30,603,146 bytes, SHA-256 `4d3c8906d569badca95599f51acbee5c157b84b7a54b9f43d1d5fca011d0f5ff`) + `.idsig`. Godot 4.7.2 headless `--export-debug "Android"`, unchanged custom template (Godot signs + emits the .idsig).
- **Linux** `linux_staging/forgefall-v0.9.5-linux.zip` (29,709,477 bytes, SHA-256 `d435e99b360ea5c01f364087043f0aa4d14447f7c950609048ea8a6af2bfbd12`): binary + forgefall.pck + forgefall.sh + README-LINUX.txt (0.9.4 -> 0.9.5, + PROGRESSION section).
- **Windows** `windows_staging/forgefall-v0.9.5-windows.zip` (36,636,770 bytes, SHA-256 `bfe11777944f0cd2321c8d569972174c69419dbdc76839470d62896f17dc2b17`): forgefall.exe + forgefall.console.exe + forgefall.pck + README-WINDOWS.txt (0.9.4 -> 0.9.5, + PROGRESSION section).

### Publish (GitHub Pages, repo `vatherty/Forgefall-updates`)
- Uploaded via `github.py` contents API: v0.9.5 APK + Linux zip + Windows zip FIRST, then version.json + version_pc.json + index.html LAST (code 26, changelog "Progression: XP + levels + unlocks (titles, emblems, camos, loadout slots), persistent loadouts + loadout picker, stats screen."). index.html: three v0.9.5 download links + "Previous version: v0.9.4" line; all older file URLs untouched. `.nojekyll` verified still present (raw 200). The manifest/index upload call was interrupted by a service restart mid-flight — all three files verified landed anyway (no re-upload needed). Pages status `built` (no transient `errored` this time).
- Live verified: version.json 200 (code 26, Pages apk_url, Progression changelog); version_pc.json 200 (code 26, v0.9.5, both platform URLs); v0.9.5 APK + Linux zip + Windows zip each 206; v0.9.4 trio still 206; index.html 200 with the three v0.9.5 links + v0.9.4 previous line; downloaded APK sha256 matches the local build hash.
- Local `updates/` mirror synced (new index.html + version.json + version_pc.json + APK).

### Deferred / follow-ups (not in Goal 6 scope)
- Title/emblem/camo EQUIP UI: unlocks are earned, persisted, and API-exposed (`equip_title/emblem/camo`, `get_equipped_camo_colors`), but no UI wires equip yet — titles/emblems don't display in lobby/scoreboard and camos don't recolor viewmodels until an equip UI lands. The unlocks themselves (incl. loadout slots) are fully functional.
- Per-weapon accuracy not tracked (schema is per-weapon kills only). Raptor shots/hits not counted (no hitscan; kills still counted).
- Older deferrals carried over: co-op waves, host migration, late join, per-weapon puppet viewmodels, per-surface footsteps, chopper sting, portal hum loop, jump takeoff sound, barrel explosion hook, Forge aliases for trident/judge, Domination hand-tuned point placement, boss HP bar in HUD.


**Project:** FORGEFALL — voxel-styled FPS for Android (Godot 4)
**Fusion:** Portal Arena (movement kit: grapple, wall-run, wrist portals, physics gun) × ModBox (AI Forge builds the world live)
**Style target:** Call of Duty: Modern Warfare 2 (2009) game-feel — ADS, recoil, hitmarkers, 3/5/7 killstreaks, Favela grit — rendered as chunky voxels ("MW2 directed by Minecraft").
**Started:** 2026-10-05 ~03:05 MDT
**Godot target:** **4.7.2-stable** (latest stable as of 2026-10-05; satisfies the "4.4+" requirement). Docs: https://docs.godotengine.org/en/stable/
**QA:** Colin playtests on demand — he is the real QA. Nothing is "done" until it runs.


## v0.9.4 — Goal 5 PORTALS: see-through discs, puzzle chambers, momentum teleport (2026-10-15 ~01:30 MDT)

### Shipped (gameplay by the Goal 5 PORTALS workers — this entry covers coordinator integration + build + publish)
- See-through portal discs (Worker A): `scripts/player/portal_disc.gd` — each disc shows a LIVE view through its paired portal via a virtual camera + small render target (SubViewport + ViewportTexture). Single-bounce only. Perf: small RTs, quality scaling (RT resolution / update rate scale down on low settings), never black on failure — shimmer fallback engages when the RT/camera fails. D's suite caught a real bug: the virtual camera looked INTO the exit portal; fixed by splitting position (pure pair transform) from orientation (partner * FlipY(180 deg) * self^-1 * camera) — same mirror-flip split as Worker C's teleport. Pitched-camera regression added (camera looking down into entry renders looking down out of exit, pitch preserved).
- Puzzle chambers (Worker B): `scripts/puzzles/` (room_base, progress_store, select_ui) + 4 chambers — 01 First Steps (portal basics, window sightline), 02 Heavy Lifting (block + pressure plate + door), 03 Fling (momentum: fall into floor portal, exit sideways at full speed), 04 The Gauntlet (all three combined). White panels = portal-able, dark surfaces = not. Main menu > PUZZLE CHAMBERS > chamber select; completion persisted to user://.
- Portal gameplay polish (Worker C): `scripts/player/portal_emitter.gd` rewritten teleport + placement + feedback. REAL BUG FOUND & FIXED: old teleport used `B * A^-1` (no flip), mapping exit velocity INTO the exit wall and tilting the body (player.gd never re-uprights, so a tilted body zeroed `wish` and rolled the view — flings died on the wall and broke movement/look until respawn). Now velocity/facing map through `R = B * FlipY(180 deg) * A^-1`, speed preserved exactly, CharacterBody3D stays upright (yaw-only), standoff from real collision shapes keeps bodies out of the exit wall. Placement: `is_surface_portalable()` (StaticBody3D yes; dynamic bodies no; no_portal group / portalable meta opt out/in), ghost disc (green/red/amber), 0.15 s debounce on successful fires only, per-body anti-ping-pong cooldown unchanged. Crosshair contract: `get_aim_state()` + `aim_state_changed` (fresh evaluation every call).
- Coordinator integration (this entry's author): wired HUD crosshair to the emitter contract — `scripts/ui/hud.gd` connects `aim_state_changed` on player bind; crosshair tints white (valid) / red (surface rejects) / amber (out of range), two pips under the crosshair show live blue/orange discs. Caught my own parse error in integration (Variant-inferred `var emitter :=` — project treats that warning as error; fixed to `var emitter =`); verify_windows 48/48 after the fix. HUD wiring probed headlessly (red/amber/white tints + pips all correct). Parallel main-menu layout fix (Deck screenshot: tagline/MAP + footer/LOADOUT overlaps) landed in `scripts/ui/main_menu.gd` from a separate worker — main menu rebuilt with a ScrollContainer, no fixed overlapping offsets, PUZZLE CHAMBERS button preserved; it ships in this build. Updated `tools/verify_updater_pc.gd` live-manifest expectations 0.9.2/code 23 -> 0.9.4/code 25 (the suite reads the local version_pc.json; the old expectations were the pre-existing Goal 5 failure D reported).

### Verification
- verify_portals: 62 checks (integration 9 + see_through 17 + placement 5 + momentum 15 + puzzles 16), ALL PASS (D's suite: 61/1/2 at first run — the 1 failure was the camera flip, fixed by Worker A; re-run 62/62 incl. A's pitched-camera addition).
- Worker suites: verify_portals_seethrough 31/31 (headless + xvfb+llvmpipe, incl. RT pixel 82% bright), verify_portals_gameplay 36/36 (momentum: floor->wall exit (20,0,0) from entry (0,-20,0), speed 20.000 preserved), verify_portals_puzzles ALL PASS.
- Regressions ALL PASS: verify_fixes, verify_v06_movement, verify_feel (82 passed, 0 failed), verify_sound (696 passed, 8 warnings), verify_content (495/495), verify_updater_pc (65/65), verify_multiplayer (180/180, 7 needs-device), verify_linux, verify_windows (48/48). 900-frame smoke clean, exit 0 (TLS handshake noise is the known Updater-autoload chatter).
- Windows PCK probe (verify_portals via --main-pack): 56 passed, 6 failed — all 6 are static source-scan checks (grep for SubViewport/ViewportTexture/fallback text in .gd source, which doesn't exist in a PCK of compiled .gdc) — known --main-pack artifact pattern, NOT defects. All behavioral checks pass (discs, fallback, momentum 15/15, puzzles 16/16).
- Android APK: apksigner OK (v2+v3), aapt com.sparky.forgefall versionCode 25 / 0.9.4, manifest UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data + REQUEST_INSTALL_PACKAGES + RECORD_AUDIO, classes2.dex = stock XRMode (1960 B), classes14/15 present. Linux binary headless --quit-after 900, exit 0 (TLS noise only).

### Version bump
- `export_presets.cfg`: `version/code=25`, `version/name="0.9.4"`. Windows preset export_path moved to windows_staging/forgefall-v0.9.4-windows/.
- `scripts/core/tuning.gd`: `FALLBACK_VERSION_CODE := 25`.

### Builds (all from the same current source)
- **Android** `updates/forgefall-v0.9.4-debug.apk` (30,495,178 bytes, SHA-256 `ba92066cc479ae9418527adb9c72407527ba23eed8c57ea5a4c123a1d616bccb`) + `.idsig`. Godot 4.7.2 headless `--export-debug "Android"`, unchanged custom template.
- **Linux** `linux_staging/forgefall-v0.9.4-linux.zip` (29,607,035 bytes, SHA-256 `d8ab90bc1573928ad37f8149f814e2fbcc2cda7022ecd10dd75ca14d75aa41df`): binary + forgefall.pck + forgefall.sh + README-LINUX.txt (0.9.3 -> 0.9.4, + PORTALS section).
- **Windows** `windows_staging/forgefall-v0.9.4-windows.zip` (36,534,547 bytes, SHA-256 `8bbca92d300b9f8641163803ff89e4c24b01a1982065a9933fc8b1fe9a780203`): forgefall.exe + forgefall.console.exe + forgefall.pck + README-WINDOWS.txt (0.9.3 -> 0.9.4, + PORTALS section).

### Publish (GitHub Pages, repo `vatherty/Forgefall-updates`)
- Uploaded via `github.py` contents API: v0.9.4 APK + Linux zip + Windows zip FIRST, then version.json + version_pc.json + index.html LAST (code 25, changelog "Portals: see-through portal discs, 4 puzzle chambers, momentum-conserving teleport, portal crosshair feedback. Main-menu layout fix."). index.html: three v0.9.4 download links + "Previous version: v0.9.3" line; all older file URLs untouched. `.nojekyll` verified still present (raw 200).
- **Pages build errored + recovered** (same transient failure as v0.9.1–v0.9.3): right after the uploads, Pages status was `errored`. `pages-enable` re-apply (409 "already enabled") + ~2.5 min wait flipped status to `built` and the live site to code 25.
- Live verified: version.json 200 (code 25, Pages apk_url, Portals changelog); version_pc.json 200 (code 25, v0.9.4, both platform URLs); v0.9.4 APK + Linux zip + Windows zip each 206; v0.9.3 trio still 206; index.html 200 with the three v0.9.4 links + v0.9.3 previous line; downloaded APK sha256 matches the local build hash.
- Local `updates/` mirror synced (new index.html + version.json + version_pc.json).

### Deferred / known limits
- No exit-area blockage check: a crate in front of the exit portal overlaps the teleported body; physics push-out resolves it.
- Portals on moving StaticBody3D platforms do not follow the platform.
- Co-op waves, host migration, late join (unchanged from v0.9.3); true per-surface footsteps, chopper sting / portal hum loop / jump takeoff sound / barrel explosion hook (unchanged from v0.9.1).
- `updater_check.gd` still FAILS on the current tree (stale expectations) — pre-existing, not a regression.

## v0.9.3 — Goal 4 MULTIPLAYER: host-authoritative ENet Team Deathmatch (2026-10-15 ~00:59 MDT)

### Shipped (gameplay by the Goal 4 MULTIPLAYER workers — this entry covers integration + build + publish)
- Architecture (honest): NO central server, NO relay, NO global matchmaking — this is a sideloaded game. One player hosts (ENet, default port 7777), others join via LAN discovery (UDP broadcast, `forgefall-mp-v1` JSON on port 47777) or direct IP:port. "Matchmaking" in this release = LAN browser + direct IP. A relay/central lobby is a documented future step. All netcode ADDITIVE: single-player stays fully offline and untouched.
- Netcode core (Worker A): `scripts/net/net_manager.gd` + `network_player.gd`. Host-authoritative ENet: host (peer 1) owns HP/kills/score; clients send REQUEST RPCs only. Damage clamped 0..200, self-damage / NaN / dead-victim / >30 reqs/sec rejected. Broadcast RPCs accept sender == 1 only (host applies its own via local helpers, never call_local) — a faking client is ignored by every peer including itself. State RPCs require sender == peer_id + newer seq. Positions client-reported, cosmetic only. NetworkPlayer: local = invisible sync shim duck-reading player.gd (no edits); remote = voxel dummy puppet (NOT player.tscn). Puppet hitboxes answer take_damage() -> host-validated request; head hitbox in "enemy_head" so WeaponBase headshots work with zero weapon edits. Movement sync: client-side interpolation, 80ms buffer, <=0.15s extrapolate, snap > 6m. Disconnect: peer leaves -> puppet removed, match continues. Host leaves -> server_disconnected, match ends. No host migration. leave() safe offline.
- Lobby + menu (Worker B): `scripts/ui/multiplayer_menu.gd` + `scenes/multiplayer_menu.tscn` + `scripts/net/lan_discovery.gd`. Callsign persisted to user://multiplayer.cfg (plus last IP/port/map/mode). HOST: map picker (Dustline/Foundry/Outpost, mirrors Main.MAPS) + mode picker + Host button. JOIN: LAN list (auto-refresh, game_found/game_lost, deduped by ip:port, pruned after 3.5s) + direct IP:port + Join. Lobby: player list (name + READY + YOU/HOST tags), Ready toggle, host-only Start, Leave. Start emits start_match_requested(map, mode, is_host). Disconnect / host-leaves / connect-timeout (5s) / Leave / Back all funnel through one cleanup back to browse. Menu delegates to NetManager when /root/NetManager exists, else creates its own ENet peer (standalone fallback). Peer is never closed on match start. Esc / gamepad B back out.
- Match modes (Worker C): `scripts/net/net_match.gd` + `net_scoreboard.gd` + `scripts/ui/killfeed.gd`. TDM SHIPPED: NetMatch is match-layer-only when NetManager is online (teams, score limit, match clock, start/end, killfeed/scoreboard); NetManager owns damage/HP/scores/respawns/puppets. Standalone mode (no NetManager) runs the full stack with own NetPuppet nodes for headless tests. One damage path in both modes; no client-callable kill RPC. TDM: balanced 2-team assignment (sorted ids -> smaller team), kills +1 team score, default limit 25 (host-configurable), optional time limit (draw on tie), forfeit when a team empties, match-end result (winner + per-player K/D rows). Killfeed ("A ▸ B [WEAPON]", team colours, 6-entry pool, 4s fade) + scoreboard (Tab toggle, no InputMap change). Co-op DEFERRED per anti-drag: needs a NetworkEnemy layer + host wave authority; WaveManager is local-only; start_match("coop") returns false (explicit rejection).
- Coordinator integration (this entry's author): ONE damage path decided (NetManager + NetworkPlayer + NetMatch delegated; NetMatch standalone is test-only). Registered NetManager as autoload "NetManager" in project.godot (removed `class_name NetManager` from net_manager.gd — Godot rejects a class_name identical to an autoload singleton; nothing referenced it as a type). Main wiring in scripts/core/main.gd: MULTIPLAYER button in main_menu.gd -> Main.open_multiplayer_menu() (hides main menu, Back restores it); start_match_requested builds the match scene on EVERY peer (map + props + player + perf + HUD + NetMatch named "NetMatch" + NetKillfeed — RPC paths identical on all peers) WITHOUT waves/modes (no AI enemies in TDM); host begins via start_match(peer_ids, names, "tdm", 25, 0) after a 0.75s delay so clients have built their NetMatch, or waits for the 2nd player if the host started solo (NetMatch refuses < 2). Match end shows a result overlay (winner + ALPHA/BRAVO scores) for 4s, then tears down (stop_match() BEFORE freeing NetMatch, NetManager.leave(), quit_to_menu). quit_to_menu() also stops the match + leaves the peer (pause-menu Quit during MP). Menu mode picker patched to TDM-only (was listing SP survival/domination/endless, which NetMatch refuses). NetManager/NetworkPlayer puppets join group "net_puppet" (same as standalone NetPuppet — HUD/waves/enemies ignore them uniformly). Menu + NetMatch _net_manager() look up /root/NetManager with /root/Net fallback. Known warts (documented, not blocking): Forge builds in a net match are local-only (not synced); menu _disconnect_peer closes the tree peer directly, desyncing NetManager's _peer until the next create_*/leave() (self-heals); killfeed weapon in delegated mode = killer puppet's synced current_weapon else "WEAPON"; no host migration, no late join.

### Verification
- verify_multiplayer: 180 passed, 0 failed, 7 NEEDS-DEVICE (live two-peer ENet handshake, live per-peer damage rate limit, real host broadcast acceptance, live host disconnect x2, live LAN broadcast across devices, TDM score sync + win on ALL peers). First run was 176/4: the 4 were coordinator integration items (autoload registration, autoload-name lookup, Main wiring, menu entry) — all fixed in integration; the suite's Phase-5 expectation + Phase-0 note were updated to the landed reality.
- /tmp/verify_g4_main_integration.gd (coordinator, NOT tools/): 17/17 PASS — MULTIPLAYER button exists, open/back round-trip, client _on_mp_start builds map+NetMatch+killfeed, quit_to_menu frees them, host with <2 players waits, quit during host-wait cleans up.
- Regressions ALL PASS: verify_fixes, verify_v06_movement, verify_feel (83/83), verify_sound (695/695, 8 warnings), verify_content (495/495), verify_updater_pc (65/65), verify_linux, verify_windows (48/48). 900-frame smoke clean, exit 0 (TLS handshake noise is the known Updater-autoload chatter).
- Windows PCK probe (/tmp/probe_win_pck.gd, editor binary + --main-pack at the WINDOWS PCK): 13/13 PASS — all 7 Goal 4 files present in the PCK, NetMatch starts TDM, teams balance, two kills end the match with ALPHA winning, menu + NetManager instantiate. (First probe run failed 2 checks from a probe bug — single 200-damage hit clamped to the ar7 cap of 25; fixed by looping hits like the suite does.)
- Two-process ENet verifier (tools/verify_netcode.sh) NOT runnable in this sandbox: UDP loopback returns EPERM (enet_socket_send fails) even though bind + PacketPeerUDP loopback work. Shipped ready for real hardware. Single-process dual-peer was tried and abandoned (branch APIs never serviced by the tree in 4.7.2).

### Version bump
- `export_presets.cfg`: `version/code=24`, `version/name="0.9.3"`. Windows preset export_path moved to windows_staging/forgefall-v0.9.3-windows/.
- `scripts/core/tuning.gd`: `FALLBACK_VERSION_CODE := 24` (the PC updater reads the installed code from it). `UPDATE_BASE_URL` unchanged.

### Builds (all from the same current source)
- **Android** `updates/forgefall-v0.9.3-debug.apk` (30,386,540 bytes, SHA-256 `45abb5fae01ed5504cfa9dbef34eb44f96405fbeeb90052705905f007e5d13fa`) + `.idsig`. Godot 4.7.2 headless `--export-debug "Android"`, unchanged custom template. Verified: apksigner OK (v2+v3 true), aapt com.sparky.forgefall versionCode 24 / 0.9.3, manifest UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data + REQUEST_INSTALL_PACKAGES + RECORD_AUDIO, classes2.dex = stock XRMode (1960 B), classes14.dex = ForgeUpdaterPlugin + UpdateStatusReceiver, classes15.dex = ForgeSpeechPlugin.
- **Linux** `linux_staging/forgefall-v0.9.3-linux.zip` (29,507,235 bytes, SHA-256 `28f921913ab7397e1d227d39d67e555dd5c891f65f838f80680b3a6a26adbba0`): binary + forgefall.pck + forgefall.sh + README-LINUX.txt (0.9.2 -> 0.9.3, PC-updater note corrected, + MULTIPLAYER section). Shipped binary headless `--quit-after 900`, exit 0, 0 errors.
- **Windows** `windows_staging/forgefall-v0.9.3-windows.zip` (36,434,549 bytes, SHA-256 `3ee6c01cc9559538c071c11443f416b6f95e9031c3c27010bc84b6836e9ca7df`): forgefall.exe + forgefall.console.exe + forgefall.pck + README-WINDOWS.txt (0.9.2 -> 0.9.3, PC-updater note corrected, + MULTIPLAYER section). Windows PCK verified functionally via the probe above.

### Publish (GitHub Pages, repo `vatherty/Forgefall-updates`)
- Uploaded via `github.py` contents API: v0.9.3 APK + Linux zip + Windows zip FIRST, then version.json + version_pc.json + index.html LAST (code 24, changelog "Multiplayer: host-authoritative ENet Team Deathmatch — host/join via LAN discovery + direct IP, killfeed + scoreboard. Co-op deferred."). index.html: three v0.9.3 download links + "Previous version: v0.9.2" line; all older file URLs untouched. `.nojekyll` verified still present in the repo (never delete it).
- **Pages build errored + recovered** (same transient failure as v0.9.1/v0.9.2): right after the uploads, Pages status was `errored` and the live site still served code 23 (v0.9.3 files 404). `.nojekyll` was present and all files were in the repo (raw 200s) — a transient build failure, not a content problem. A `pages-enable` re-apply (409 "already enabled") + ~3 min wait flipped status to `built` and the live site to code 24.
- Live verified: version.json 200 (code 24, Pages apk_url, Multiplayer changelog); version_pc.json 200 (code 24, v0.9.3, both platform URLs); v0.9.3 APK + Linux zip + Windows zip each 206; v0.9.2 trio still 206; index.html 200 with the three v0.9.3 links + v0.9.2 previous line; downloaded APK sha256 matches the local build hash.
- Local `updates/` mirror synced (new index.html + version.json + version_pc.json).

### Deferred
- Co-op waves — needs NetworkEnemy + host wave authority; WaveManager is local-only. start_match("coop") returns false.
- Host migration, late join, per-weapon puppet viewmodels (gun mesh tints by weapon id for now), request_heal() host-validated heal RPC, true per-surface footsteps (unchanged from v0.9.1), chopper sting / portal hum loop / jump takeoff sound / barrel explosion hook (unchanged from v0.9.1).
- Two-device ENet handshake + live LAN discovery + TDM score sync on ALL peers — NEEDS-DEVICE. Colin is QA on real hardware (two machines on one LAN).
- Forge builds in net matches are local-only (not synced) — noted above; syncing Forge structures is a follow-up, not a blocker.
- `updater_check.gd` (old Android scaffold check) already FAILS on the current tree (expects an empty UPDATE_BASE_URL and FALLBACK 3; real config has a URL and FALLBACK 24) — pre-existing stale expectations, not a regression.

## v0.9.2 — Goal 3 CONTENT: new maps, enemies + boss, modes, weapons + PC updater (2026-10-15 ~00:25 MDT)

### Shipped (gameplay by the Goal 3 CONTENT workers — this entry covers integration + build + publish; PC updater merged here, not a separate entry)
- Maps: Foundry + Outpost join Dustline (3 total). Each loads + instantiates with player spawns, spawn doors, Forge markers, voxel geometry, mutually distinct layouts.
- Enemies: Bulwark, Shredder, Suppressor join Grunt/Rusher/Marksman/Brute (7 types + boss). Warlord boss (boss flag, boss-kit stats: >= 8x grunt HP, flinch-immune, oversized body). Every type appears in a WaveManager wave queue.
- Modes: Domination (capture/hold 3 points A/B/C) + Endless (uncapped waves, score chase, best persists to user://endless_best.json, saved on every wave clear). Menu/main wiring selects the mode; survival stays the default.
- Weapons: BR-3 TRIDENT (3-round burst rifle, 900 rpm intra-burst, 26 dmg, 30/120) + HV-44 JUDGE (heavy revolver, SEMI 150 rpm, 65 dmg, 6/36, 0.15 s cylinder lockout, 2.10 s reload). 9 weapons total. New "Burst" loadout (br3 + hv44). Forge ordering for the new guns is NOT wired (forge_builder/forge_llm still list only the old 7 ids — "give me a burst rifle" via Forge/LLM refuses until the Forge worker adds aliases); Arsenal + loadouts work.
- PC updater (UpdaterPC autoload, `scripts/core/update_manager_pc.gd`): in-game updates on Windows + Linux, mirroring the Android updater's states/dialogs. Flow: CHECK version_pc.json (deferred launch check, 8s timeout, silent on auto-check failure) -> DIALOG (reused UpdateDialog, new additive `show_ready_pc()` text) -> DOWNLOAD the platform ZIP to `user://updates/forgefall-update.zip` with progress -> INSTALL: extract via ZIPReader to `user://updates/staging/` (zip-slip rejected: `..`/absolute entries fail the extract), then generate a helper script with all paths baked in, double-quoted (paths with spaces work): `update.bat` on Windows (waits on the game PID via tasklist, up to 60 s; `xcopy` staging over the install dir; `start` the exe; deletes staging + zip + itself), `update.sh` on Linux (waits on PID via `kill -0`, up to 60 s; `cp -rf` staging over install dir; `chmod +x` the binary — ZIP extraction loses the exec bit; `nohup` relaunch; deletes staging + zip + itself). Helper launched via `OS.create_process`, then the game quits. Nothing silent: user confirms at Download AND at INSTALL NOW. FALLBACK (built in): if the helper fails to launch, the dialog shows an error with the exact downloaded ZIP path + "unzip it over your install folder, then relaunch" — a helper-launch failure never bricks the updater. Manifest: only the CURRENT platform's URL is required (a Windows-only hotfix may omit Linux). Android manager parked in DISABLED on PC (update_manager.gd left byte-identical so its headless tests keep passing); main menu routes manual checks to UpdaterPC on PC (`main_menu.gd` `_active_updater()`). `Tuning.FALLBACK_VERSION_CODE` (now 23) is the installed-code source on PC.
- Coordinator integration fix (already in source, no gameplay edits by this worker): `scripts/core/game_mode.gd` `_enemies_near` one-line fix.
- Momentum hotfix (jump keeps momentum/sprint, crouch-land slide) continues to ship inside this build.

### Verification
- verify_content (source): 495 passed, 0 failed.
- verify_updater_pc: 65 pass, 0 fail (manifest parsing incl. code 23 + platform URL selection, bat/sh helper generation incl. PID wait + copy + relaunch + cleanup, ZIP extract incl. zip-slip rejection, Android-manager parking, main-menu routing).
- Regressions: verify_fixes, verify_feel, verify_sound PASS; 900-frame smoke clean.
- UpdaterPC autoload confirmed in source: `project.godot` has `UpdaterPC="*res://scripts/core/update_manager_pc.gd"`.

### Version bump
- `export_presets.cfg`: `version/code=23`, `version/name="0.9.2"`. Windows preset export_path moved to windows_staging/forgefall-v0.9.2-windows/.
- `scripts/core/tuning.gd`: `FALLBACK_VERSION_CODE := 23` (the PC updater reads the installed code from it). `UPDATE_BASE_URL` unchanged.

### Builds (all from the same current source)
- **Android** `updates/forgefall-v0.9.2-debug.apk` (30,220,653 bytes, SHA-256 `16985842e8e9d11eb9b45d3954be85097fd3f2f8e4861c2d5b3b8ad80ce2175d`) + `.idsig`. Godot 4.7.2 headless `--export-debug "Android"`, unchanged custom template. Verified: apksigner OK (v2+v3 true), aapt com.sparky.forgefall versionCode 23 / 0.9.2, manifest UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data + REQUEST_INSTALL_PACKAGES + RECORD_AUDIO, classes2.dex = stock XRMode (1960 B, sha256 matches v0.9.1 stock), classes14.dex = ForgeUpdaterPlugin + UpdateStatusReceiver, classes15.dex = ForgeSpeechPlugin.
- **Linux** `linux_staging/forgefall-v0.9.2-linux.zip` (29,348,471 bytes, SHA-256 `77051eb84e66ded8eb078db1117a1c8ed801d9f5b80f6f81167b4aabee3754b5`): binary + forgefall.pck + README-LINUX.txt (0.9.1 -> 0.9.2). Shipped binary headless `--quit-after 900`, exit 0, 0 errors.
- **Windows** `windows_staging/forgefall-v0.9.2-windows.zip` (36,276,278 bytes, SHA-256 `a5788811558736f7c2db86ed761644c17f1bdab96ba8b18bb4e782fba427fc8c`): forgefall.exe + forgefall.console.exe + forgefall.pck + README-WINDOWS.txt (0.9.1 -> 0.9.2). Windows PCK verified functionally, NOT by plain-text grep: editor binary ran verify_content with `--main-pack` pointed at the WINDOWS PCK -> 240 passed, 16 failed, and all 16 are source-discovery scans (0 maps / 0 enemy subclasses / 0 modes found) that cannot run against a PCK — PCKs hold compiled .gdc, not .gd source, and res:// scans find no .gd/.tscn files. Every behavioural check that could run under --main-pack passed (all weapons fire/ADS/reload, raptor grab/throw at 30.0 m/s). Same artifact class as the v0.9.1 PCK probe. Source run of the same suite is 495/0, confirming the content is in the build.

### Publish (GitHub Pages, repo `vatherty/Forgefall-updates`)
- Uploaded via `github.py` contents API: v0.9.2 APK + Linux zip + Windows zip FIRST, then version.json + version_pc.json + index.html LAST (code 23, apk_url = Pages URL for the v0.9.2 APK, changelog "Content: new maps, enemies + boss, game modes, weapons. PC updater: in-game updates on Windows + Linux."). version_pc.json verified before upload: version_code 23, version_name 0.9.2, windows_url/linux_url match the published zips. index.html: three v0.9.2 download links + "Previous version: v0.9.1" line; all older file URLs untouched. `.nojekyll` verified still present in the repo (never delete it).
- **Pages build errored + recovered** (same transient failure as v0.9.1): right after the uploads, Pages status was `errored` and the live site still served code 22 (version_pc.json 404). `.nojekyll` was present and all files were in the repo — a transient build failure, not a content problem. A `pages-enable` re-apply (409 "already enabled") coincided with a fresh build; status flipped to `built` and the live site flipped to code 23.
- Live verified: version.json 200 (code 23, Pages apk_url, Content changelog); version_pc.json 200 (code 23, v0.9.2, both platform URLs); v0.9.2 APK + Linux zip + Windows zip each 206; older artifacts (v0.9.1 trio, v0.9.0 trio, v0.8.0, v0.7.0, v0.6.2, v0.5.0, v0.1.11) all 206; index.html 200 with the three v0.9.2 links + v0.9.1 previous line; downloaded APK sha256 matches the local build hash.
- Local `updates/` mirror synced (new index.html + version.json + version_pc.json).

### Deferred
- Forge ordering/LLM aliases for trident/judge (Forge-owned files) — Arsenal + loadouts work today.
- Domination on Foundry/Outpost is placement-derived, not hand-tuned per map — worth a playtest pass (points could sit on cover/rooftops).
- Forge weapon cost stays flat 200 for all weapons (Forge-owned); the new guns are balanced via stats/ammo economy instead.
- PC updater helper-script run (exe lock-wait, copy, relaunch on real Windows / .sh on real Linux) could NOT be verified headlessly — generation + extraction are tested (65/65). Colin is QA on real hardware.
- PC updater: no download-resume (a cancelled download restarts from scratch, same as Android).
- `updater_check.gd` (old Android scaffold check) already FAILS on the current tree (expects an empty UPDATE_BASE_URL and FALLBACK 3; real config has a URL and FALLBACK 23) — pre-existing stale expectations, not a regression.

## v0.9.1 — Goal 2 SOUND: richer, punchier SFX (2026-10-15 ~00:07 MDT)

### Shipped (gameplay by the Goal 2 SOUND workers — this entry covers integration + build + publish)
- Weapon + combat SFX (Worker A): `gunshot_v2()` (crack + low thump + body + mech tick + slap), `explosion_v2()` (sub sine + wash + crack + rumble LFO + delayed secondary), `energy_zap()`, `reload_seq()`. All 8 shots distinct by (duration, spectral centroid): AR 0.38s/3977Hz, SMG 0.22/4296, Shotgun 0.70/8505, Sniper 1.05/3569, LMG 0.48/3889, Pistol 0.30/4137, Turret 0.32/3958, Raptor 0.35/9029. NEW: shot_raptor, impact_concrete/metal/dirt/flesh, cover_break, reload_sniper/shotgun/lmg, explosion_small/barrel/airstrike. Per-category voice caps (gunshot 6, explosion 2, impact 4, reload 2). Reload plays ONE per-weapon file once (was 3 overlapping plays). Bullet hits play a surface impact at -6 dB. Hitmarker wiring untouched.
- Movement + UI + enemy SFX (Worker B): NEW generator tools/gen_audio_ambient.py; NEW one-shots slide_whoosh, wallrun_scrape (2.8s long one-shot, deliberately NOT a loop), enemy_death, footstep_brute (every 3m), spawn_telegraph (replaces portal_open for non-brute spawns); regenerated footstep_concrete/dirt/metal (shorter decays for sprint cadence) + grapple_zip (band-swept rush). Speed-weighted footsteps (pitch 1.00->1.18, vol -4->-2 dB walk->sprint). Forge deny paths now play forge_fail. Wave start plays wave_horn once per wave. No movement/gameplay constants changed.
- Integration (coordinator): registered B's 5 one-shots in SOUND_IDS + MIX_DB (they were on disk but unregistered — Sfx would have silently skipped them); LOOP_IDS cut to ambient_wind_loop + grapple_zip ONLY (heartbeat_loop/portal_hum_loop/music_drone_loop de-looped — no start/stop callers; keeping them there made Sfx refuse one-shot plays = the silent-heartbeat bug; HUD heartbeat now plays); deleted orphan enemy_hit.wav (deliberately unwired to preserve the HUD hit-tick dedupe); arsenal LMG sfx_fire shot_ar7 -> shot_lmg (both mappings now agree); generators re-run in order (gen_audio.py, then gen_audio_ambient.py so B's footstep/grapple_zip versions win) + Godot --import. Stale LMG comment in weapon_base.gd cleaned up.
- Momentum hotfix from post-v0.9.0 (jump keeps momentum/sprint, crouch-land slide) ships inside this build — it was never version-bumped on its own.

### Verification
- verify_sound: 615 passed, 0 failed, 8 warnings (5x generator-attribution + 3x intentional de-looping notes — all warn-only). First pass was 586/20; integration resolved all 4 failure groups (6 unregistered WAVs, LMG==AR, 3 unwired loops, silent heartbeat).
- Regressions ALL PASS: verify_fixes, verify_v06_movement, verify_feel (77/77 incl. momentum phases), verify_linux, verify_windows (48/48). 900-frame smoke survived, exit 0.
- PCK behavioral probe (verify_sound's static text scans are invalid under --main-pack — PCKs hold compiled .gdc, not .gd source; the 8 "failures" there were scan artifacts, not defects): 12/12 WAVs load from the Linux AND Windows PCKs with correct lengths (slide_whoosh 0.7, wallrun_scrape 2.8, shot_raptor 0.35, explosion_airstrike 2.2, etc.).
- Audio size: 55 WAVs, 5,223,480 bytes total incl. .import (4.98 MiB) — under the ~6M cap.

### Version bump
- `export_presets.cfg`: `version/code=22`, `version/name="0.9.1"`. Windows preset export_path moved to windows_staging/forgefall-v0.9.1-windows/.
- `scripts/core/tuning.gd`: `FALLBACK_VERSION_CODE := 22`. `UPDATE_BASE_URL` unchanged.

### Builds (all from the same current source)
- **Android** `updates/forgefall-v0.9.1-debug.apk` (30,008,532 bytes, SHA-256 `2eb538a5dca2904a838a74db12cc18de55bd1ccf616442cc3f8cb6d499b3744f`) + `.idsig`. Godot 4.7.2 headless `--export-debug "Android"`, unchanged custom template. Verified: apksigner OK, aapt com.sparky.forgefall versionCode 22 / 0.9.1, manifest UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data + REQUEST_INSTALL_PACKAGES + RECORD_AUDIO, classes2.dex = stock XRMode (1960 B), classes14.dex = ForgeUpdaterPlugin + UpdateStatusReceiver, classes15.dex = ForgeSpeechPlugin.
- **Linux** `linux_staging/forgefall-v0.9.1-linux.zip` (29,151,982 bytes, SHA-256 `bb8e8441400de53529634680e9820dd551b7aefc9e80c4edd0bbaabc2fd486aa`): binary + forgefall.pck + README-LINUX.txt (0.9.0 -> 0.9.1). Shipped binary headless `--quit-after 900`, exit 0.
- **Windows** `windows_staging/forgefall-v0.9.1-windows.zip` (36,079,907 bytes, SHA-256 `ecca4f1032becc023a43b98344da4b52863619b0efda887163f8e4105753d288`): forgefall.exe + forgefall.console.exe + forgefall.pck + README-WINDOWS.txt (0.9.0 -> 0.9.1). Export needed `mkdir -p` for the new v0.9.1 staging dir first (Godot errors "The given export path doesn't exist" otherwise).

### Publish (GitHub Pages, repo `vatherty/Forgefall-updates`)
- Uploaded via `github.py` contents API: v0.9.1 APK + Linux zip + Windows zip, then version.json + index.html LAST (code 22, apk_url = Pages URL for the v0.9.1 APK, changelog "Sound: richer, punchier SFX across weapons, movement, UI, enemies"). index.html: three v0.9.1 download links + "Previous version: v0.9.0" line; all older file URLs untouched. `.nojekyll` verified still present in the repo (never delete it).
- **Pages build errored + recovered**: right after the uploads, Pages status was `errored` and the live site still served code 21 (v0.9.1 files 404'd). `.nojekyll` was present and the files were in the repo (raw 200s) — a transient build failure, not a content problem. A `pages-enable` re-apply (409 "already enabled") coincided with a fresh build; status flipped to `built` and the live site flipped to code 22.
- Live verified: version.json 200 (code 22, Pages apk_url, Sound changelog); v0.9.1 APK + Linux zip + Windows zip each 206; older artifacts (v0.9.0 trio, v0.8.0, v0.7.0, v0.6.2, v0.5.0, v0.1.11) all 206; index.html 200 with the three v0.9.1 links; downloaded APK sha256 matches the local build hash.
- Local `updates/` mirror synced (new index.html + version.json).

### Deferred
- Chopper arrival sting (no WAV assigned; killstreaks.gd not a Goal 2 file) — spec: new one-shot chopper_online.wav + one line in _trigger_chopper.
- Portal hum loop (no stop path — discs never deactivate).
- True per-surface footsteps (map has no surface tags) — shipped speed-weighted alternative instead.
- Jump takeoff sound (no WAV assigned; jump_land covers landing).
- explosion_barrel.wav registered but unwired — awaits a barrel-explosion hook (forge_builder/dustline, not Goal 2 files).

## ART DIRECTION PIVOT (2026-10-05, before workers launched)
Colin pivoted the whole project to **voxel styling**. Everything is cubes: voxel viewmodel weapons (MW2 silhouettes translated to voxels), voxel soldiers with procedural blocky animation, voxel Dustline shantytown with **destructible cover** (cover fractures into pooled physics cubes), MultiMeshInstance3D batching for static voxels. Audio, UI/HUD, MW2 game-feel, Forge pipeline, Android work unchanged. Forge synergy noted: Forge now spawns voxel assemblies (turrets, walls, towers, barricades) — unifies with the ModBox voxel-builder lineage.

## Build method
Coordinator + 9 parallel worker subagents, each writing one subsystem's files directly into `~/workspace/forgefall/`. Workers do NOT spawn further agents. Every Godot API must be verified against docs.godotengine.org (stable); assumptions are logged, never silent.

## Cross-subsystem contracts (frozen)
- **Autoloads** (defined in `project.godot` by worker 1): `Game` → `res://scripts/core/game_state.gd`, `Sfx` → `res://scripts/audio/audio_manager.gd`, `Forge` → `res://scripts/forge/forge_manager.gd` (load order: Game, Sfx, Forge).
- **Voxel helper** (worker 1): `res://scripts/core/voxel_builder.gd`, `class_name VoxelBuilder`. Exact static API:
  - `static func mat(color: Color) -> StandardMaterial3D` (cached materials)
  - `static func cube(size: Vector3, color: Color, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D`
  - `static func build_voxels(voxels: Array) -> Node3D` — each entry `[Vector3i, Color]`, voxel pitch = `VOXEL_S`
  - `static func collision_box(size: Vector3) -> CollisionShape3D`
  - `const VOXEL_S := 0.125`, `const VOXEL_M := 0.25`
  - `const PALETTE := {...}` — gunmetal `3a3f44`, darkmetal `23262a`, tan `c2a878`, rust `8a4b2a`, concrete `9a958c`, wood `7a5c38`, canvas `b8a888`, olive `5a6b3c`, forge_orange `ff7b1c`, portal_blue `1ca8ff`, portal_orange `ff8a1c`
- **Damageable interface:** `take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void`
- **Cover nodes:** group `"cover"`, method `cover_point(threat_pos: Vector3) -> Vector3`
- **Spawn doors:** group `"spawn_door"` (Marker3D)
- **Player node:** group `"player"`, method `add_look(relative: Vector2) -> void`
- **Debris pool** (worker 5): `res://scripts/fx/debris_pool.gd`, autoload-free static access: `DebrisPool.burst(pos: Vector3, colors: Array, count: int, speed: float) -> void` (pooled RigidBody3D cubes, cap ~120)
- **Explosion** (worker 3): `res://scripts/fx/explosion.gd`, `static func detonate(pos: Vector3, radius: float, damage: float) -> void`
- **Game signals:** `wave_started(n)`, `wave_cleared(n)`, `build_phase_started(seconds)`, `enemy_killed(points, headshot, victim_name)`, `player_died()`, `killstreak_ready(index)`, `killstreak_used(index)`, `forge_budget_changed(amount)`
- **Game funcs:** `register_kill(headshot: bool, victim_name: String)`, `register_player_death()`, `add_score(n: int)`, `spend_budget(n: int) -> bool`, `reset_run()`
- **Sfx funcs:** `play_2d(id: String, vol_db := 0.0)`, `play_3d(id: String, pos: Vector3, vol_db := 0.0)`
- **Forge funcs:** `submit_prompt(text: String) -> void`, signals `forge_result(success: bool, message: String)`, `budget_changed(amount: int)`
- **ModSpec v1 schema:** `{spec_version: 1, action: "spawn|modify|event", target: "weapon|cover|turret|pickup|enemy_mod|killstreak|arena_event", params: {...}, cost: 0, ttl: 0}`
- **Tunables:** every worker puts `const`s under `#region TUNABLES` at the top of their main script; coordinator consolidates into `scripts/core/tuning.gd` at the end. Single balance file is the goal.
- **DeepSeek key:** lives in `user://forge_config.json` on Colin's machine. NEVER in the repo.

## Subsystem status
| # | Subsystem | Worker | Status | Notes |
|---|-----------|--------|--------|-------|
| 1 | Project setup + DESIGN.md + README.md | setup | done | project.godot (4.7.2, mobile renderer, 19 input actions, Jolt pinned), Android+Linux export presets, main bootstrap, Game autoload, VoxelBuilder (frozen API), tuning skeleton, verify.sh, DESIGN.md (ModSpec v1 + 8 examples), README.md; project settings verified vs docs; no Godot binary on VM so .gd not compile-checked |
| 2 | Player controller | player | done | player.tscn, player.gd (walk/sprint/slide/jump+coyote/buffer, wall-run, health regen), grapple_hook.gd (direct-pull + pendulum, floor clamp), portal_emitter/disc (momentum teleport); APIs verified vs docs; needs editor parse check |
| 3 | Weapon system | weapons | done | WeaponBase (recoil patterns, falloff, ADS, staged reloads), 6 voxel viewmodels incl. Raptor physics gun, pooled tracers/shells, ExplosionFX (+detonate_light), pickups; needs Colin's gun-feel playtest (ADS sight alignment untested) |
| 4 | Enemy AI + waves | enemies | done | EnemyBase + 4 types (code-built, pooled), VoxelSoldier rigs, wave_manager (scaling, build phase, director mods), grenades, nav-agent with steering fallback; caught 4.6+ raycast exclude=Array[RID] gotcha; needs nav-bake + difficulty playtest |
| 5 | Map "Dustline" | map | done | dustline.tscn + builder (11 shacks, market, water tower, 16 destructible covers, 7 spawn doors, 4 forge pads), MultiMesh batching (~20 draw calls), DebrisPool, runtime navmesh bake; needs in-engine nav + playtest verification |
| 6 | HUD/UI | ui | done | hud.tscn (all 7 contract funcs: hitmarker/killfeed/banner/pips/damage/minimap/forge panel), main + pause menus, StencilStyle theme; SFX-id guesses centralized in hud.gd TUNABLES; needs phone-readability playtest |
| 7 | Audio | audio | done | 38 WAVs synthesized + generated (3.54 MB, 44.1k/16-bit/mono); Sfx autoload w/ pooled 2D/3D players, buses, music crossfade; APIs verified vs docs; WAVs NOT yet compile-checked in Godot |
| 8 | Forge system | forge | done | ForgeLLM (real DeepSeek HTTPRequest + offline keyword fallback), ForgeBuilder (voxel cover/turret/pickups/weapons/killstreaks/smoke/supply), Killstreaks (UAV/airstrike/chopper), ForgeDirector (camp/snipe/turtle counters), ForgeConfig (user:// key); DOWNLOADED Godot 4.7.2 headless — 0 script errors on import, 26/26 runtime assertions pass; fixed explosion.gd parse error + ClassDB.class_exists gotcha |
| 9 | Android + touch | android | done | touch_controls (manual multi-touch dispatcher, joystick+sprint-at-full-deflection, full button set), PerfScaler, Haptics, SpeechInput (typed fallback), GyroAim (REAL via Input.get_gyroscope), docs/android_export.md; needs gyro project setting + main.gd integration |

## Key technical decisions
- (2026-10-05) Worker 4 (enemies) done: 9 GDScript files under `scripts/enemies/`. Enemies built fully in code (no .tscn). Collision-layer assumption: world=1, enemies=2, player=3 (worker 1 to confirm in project.godot). Nav strategy: NavigationAgent3D per enemy when a baked navmesh exists (re-detected every wave via NavigationMesh.get_polygon_count()), else direct steering + obstacle probe. Weapon worker must raycast with collide_with_areas=true for headshots (head Area3D in group "enemy_head"). Docs verified: NavigationAgent3D, NavigationServer3D.parse/bake_from_source_geometry_data(_async), NavigationRegion3D.bake_navigation_mesh, NavigationMesh.get_polygon_count, PhysicsDirectSpaceState3D.intersect_ray + PhysicsRayQueryParameters3D.create (exclude is Array[RID] in 4.6+ — pass get_rid(), not self).
- (2026-10-05) Nav: Dustline bakes its NavigationMesh at runtime via NavigationServer3D.bake_from_source_geometry_data() (verified API) from static walk-surface boxes (ground + shack roofs + stair steps). Destructible cover is excluded so destruction never invalidates the mesh; enemies steer around cover locally.
- (2026-10-05) Godot **4.7.2-stable** pinned as target (latest stable; 4.4+ requirement satisfied).
- (2026-10-05) Renderer: Mobile (`rendering_method="mobile"`) for Android; no GI; 1 directional light + ambient; MSAA off on mobile.
- (2026-10-05) Physics: Jolt pinned explicitly in project.godot (4.7 default for new projects; pinned so behavior matches regardless of import path).
- (2026-10-05) Android export: min_sdk 24, target_sdk 35 (per 4.7 export docs: Platform 35, Build-Tools 35.0.1, NDK r28b, JDK 17); arm64-v8a only; INTERNET + VIBRATE permissions.
- (2026-10-05) Voxel pivot: all art from cubes; static map geometry via MultiMeshInstance3D w/ per-instance colors; simplified invisible collision boxes; destructible cover fractures into pooled RigidBody3D cubes (cap ~120).
- (2026-10-05) Viewmodels built in code via VoxelBuilder (no binary assets needed). Audio fully synthesized by `tools/gen_audio.py` (stdlib only).
- (2026-10-05) Forge works end-to-end on day one via keyword-matcher fallback (no API key needed); DeepSeek client is real HTTPRequest code, key from user config.
- (2026-10-05) Coordinator integration fixes: (a) `class_name TracerPool` collision (enemies/ vs weapons/) → enemy pool renamed `EnemyTracerPool`; (b) 3× `:=` type-inference failures on Variant dictionary indexing (voxel_soldier, dustline_builder) → explicit types; (c) `Vector2.set()` doesn't exist → direct assignment (gyro_aim); (d) typed `Array[Color]` property can't take untyped Array assignment → `.assign()` at both DestructibleCover call sites; (e) 21 SFX alias mappings added to audio_manager (player_hurt→damage_thud, shot_ar7→shot_ar, etc.); (f) damage direction flipped to point TOWARD source (HUD contract); (g) collision layers frozen: world=1, player=2, enemies=4 (enemy_base was on 2, colliding with player layer); enemy LOS_MASK fixed 5→3; (h) added slot_1/2/3 input actions + gyroscope project setting; (i) main.gd now wires HUD, touch controls, PerfScaler, WaveManager.
- (2026-10-05) `ClassDB.class_exists()` returns false for GDScript class_names in 4.7.2 (native classes only) — do NOT use it as a guard for script classes; use direct class_name references.

## Validation
- [x] `tools/gen_audio.py` runs, WAVs produced in `assets/audio/` — DONE 2026-10-05 (38 files, 3.54 MB, zero clipped, loops seamless)
- [x] Headless Godot 4.7.2 import — DONE: **0 script errors** (binary at /tmp/Godot_v4.7.2-stable_linux.x86_64; egress worked, no proxy issues)
- [x] Compile check (`tools/check_scripts.gd`) — DONE: **45/45 scripts pass**
- [x] Runtime smoke test (`tools/smoke_test.gd`) — DONE: boots to menu, start_game builds Dustline (nav bakes, 16 covers, wave manager live), Forge prompt→build loop verified live (budget 300→200, cover 16→17), 900 frames with zero script errors
- [ ] Colin playtest (pending — he is the real QA)

## Blockers
- None. Build complete and validated. Awaiting Colin's playtest — he is the real QA.

## Coordinator integration notes (all resolved 2026-10-05)
- SFX ID mismatches: resolved via 21-entry alias map in audio_manager.gd (warns-once preserved for truly unknown ids).
- `damage_flash(direction)`: player now emits direction TOWARD the source per HUD contract.
- main.gd instances hud.tscn + touch_controls.tscn, adds PerfScaler (auto_detect), instances WaveManager + start_run().
- Collision layers frozen: world=1, player=2, enemies=4. Weapons hitscan uses full mask (0xFFFFFFFF) — fine.
- `interact` action has no touch button (spec gap) — recommend small context button; flag for Colin.
- Navmesh bake emits harmless precision warnings (agent_height/radius ceiled to voxel units) — bake succeeds.

## Worker 2 — Player controller (2026-10-05 ~03:30 MDT) — DONE
Files: `scenes/player.tscn`, `scenes/player/portal_disc.tscn`,
`scripts/player/player.gd`, `scripts/player/grapple_hook.gd`,
`scripts/player/portal_emitter.gd`, `scripts/player/portal_disc.gd`.
- Locomotion: walk 4.2 / sprint 6.4 (forward-only, infinite, sprint-out signal for weapon raise delay), accel 40, friction 30, air control 0.35, jump 5.2 + coyote 0.12s + buffer 0.15s, custom gravity 20.
- Slide (sprint+crouch tap): low-friction glide, camera dip + lean roll, jump-cancel hop, cancels under 2.5 m/s.
- Wall-run: dual RayCast3D, 2.2s max, +10% entry boost along tangent, gravity x0.12, ±12° camera roll, wall-kick jump; needs floor touch to re-arm.
- Health 100, regen 25/s after 5s, take_damage() per Damageable contract, died() → Game.register_player_death(), ragdoll-lite cam slump, respawn(pos) for main.
- ADS: FOV 75→52, sensitivity x0.6, ads_changed signal; sprint FOV kick to 82; headbob + landing-dip spring; footsteps via Sfx every 2.2m; Input.vibrate_handheld(20) on damage.
- Grapple (no cooldown): DIRECT PULL (48 m/s², gravity x0.2) when anchor clearly above + slow, else PENDULUM rope constraint + 6 m/s reel-in; release keeps momentum; floor clamp after move_and_slide so the rope never drags the player underground; pooled rope + spark visuals.
- Portal emitter: wrist-mounted, one blue + one orange disc (pooled), 30m stick-to-surface aligned to normal, momentum-preserving teleport (relative transform + rotated velocity), 0.5s per-body anti-ping-pong cooldown; see-through rendering deferred as # STRETCH:.
- Signals: health_changed / damaged / died / landed (HUD), ads_changed / sprint_changed (weapons). Group "player", add_look(relative) public; desktop captured-mouse also feeds add_look.
- API docs verified (stable): Input.vibrate_handheld, CharacterBody3D.move_and_slide family, RayCast3D, Camera3D.fov. Assumed-stable (longstanding): Basis.looking_at, PhysicsRayQueryParameters3D.create, StandardMaterial3D emission props, KinematicCollision3D getters (unused — rays used instead).
- Notes for coordinator: player collision mask = 1 (world only) — enemy bodies won't physically push the player; Sfx ids used (assumed, audio worker to provide): footstep_concrete, player_hurt, player_death, player_land, player_land_hard, grapple_fire, grapple_zip, portal_fire, portal_fail, portal_travel; Android VIBRATE permission needed in export preset for haptics.

## Worker 6 — HUD/UI (2026-10-05 ~03:30 MDT)
Files written (all UI built in code; .tscn files are thin shells):
- `scripts/ui/stencil_style.gd` (class_name StencilStyle) — shared theme: panels, buttons, chips, sliders, LineEdit styling; uppercase + FontVariation glyph-tracking "stencil" labels on the default font; forge-orange `ff7b1c` accents matching VoxelBuilder palette.
- `scripts/ui/hud.gd` + `scenes/ui/hud.tscn` — CanvasLayer (group "hud", layer 10). Contract API implemented exactly: show_hitmarker(kill, headshot), add_killfeed(text), announce(title, subtitle), set_killstreak_pips(unlocked), damage_flash(direction), set_spread(px), set_touch_mode(on). Self-wires to Game/Sfx/Forge autoloads (has_signal/has_method guarded) + lazily binds player-group node signals (health_changed, damaged, died, ads_changed, ammo_changed, weapon_changed; also tries group "weapon_manager"). Elements: spread crosshair (hides on ADS/death), 120ms hitmarker (white, red + headshot_ding on kill/headshot), bottom-right MAG|RESERVE + RELOAD blink + low-mag red, MW2-style damage vignette + directional arc + low-hp pulse + heartbeat loop (no health bar), 6-label pooled killfeed (4s fade), slide/fade wave banner (JUGGERNAUT/K.I.A. auto-red via keyword), 3 killstreak pips (UAV/AIRSTRIKE/CHOPPER, keys 4/5/6, ready-flash), top-center WAVE/SCORE/BUDGET bar, 180px minimap (SubViewport own_world_3d + orthographic top-down Camera3D size=90, pooled red dots within 45m, green player triangle, north-up), Forge console panel (FORGE button + forge_console action, LineEdit + 5 suggestion chips + last-8 bbcode feed, auto-opens on build_phase, never auto-focuses input), touch-mode hint row, pause button -> group "pause_menu".
- `scripts/ui/main_menu.gd` + `scenes/ui/main_menu.tscn` — FORGEFALL stencil title, voxel-cube motif strip, DEPLOY (main.start_game() w/ fallback to res://scenes/main.tscn), LOADOUT disabled COMING SOON, OPTIONS (sensitivity/master/music/gyro-stub/quality->scaling_3d_scale, persisted to user://forge_settings.cfg), QUIT, footer "v0.1 scaffold — Colin's playtest build".
- `scripts/ui/pause_menu.gd` + `scenes/ui/pause_menu.tscn` — group "pause_menu", PROCESS_MODE_ALWAYS, ui_cancel toggle, RESUME / RESTART RUN (Game.reset_run + reload) / quick OPTIONS / QUIT TO MENU.
- TUNABLES consolidated in hud.gd `#region TUNABLES` (banner/hitmarker/killfeed timings, minimap range/size/pools, low-hp frac, heartbeat interval, SFX id map).
- Assumptions for other workers: damage direction = vector TOWARD the damage source (one-line flip if player worker uses opposite); SFX ids beyond hitmarker/headshot_ding (heartbeat, killstreak_ready, wave_start, forge_open, forge_submit, forge_success, forge_fail, ui_click) are guesses for the audio worker — all centralized in hud.gd TUNABLES; keypress 4/5/6 killstreak activation belongs to worker 8 (HUD only displays); worker 1's main.tscn should instance hud.tscn + pause_menu.tscn; "forge_console" input action expected from worker 1 (HUD degrades to button-only without it).
- Verified vs docs: Camera3D.projection=PROJECTION_ORTHOGONAL + size (no projection_orthogonal prop), SubViewport(size/own_world_3d/transparent_bg/UPDATE_ALWAYS), StyleBoxFlat API, LineEdit.text_submitted. Assumed (standard, un-fetched): ThemeDB.fallback_font, FontVariation.spacing_glyph, Viewport.scaling_3d_scale, String.xml_escape.
- Not verified: no Godot binary on this VM — needs coordinator's headless parse check + Colin's playtest (HUD readability on phone, minimap usefulness, touch-mode hints).

## Android APK build — debug sideload (2026-10-12 ~14:55 MDT)

First installable Android build, packaged for Colin's Galaxy S23 sideload testing.

- **APK:** `builds/forgefall-v0.1-debug.apk` — 29,255,230 bytes (~27.9 MB)
- **SHA-256:** `7b5d858bcfb1180f60de4a79a96fad2749d0b0309e8b8d1a76d59e6c4d280e7d`
- **Toolchain:** Godot 4.7.2-stable (official ed1daf0bf, `~/tools/godot-4.7.2/`), export templates 4.7.2.stable, Android SDK `~/tools/android-sdk` (platform-tools r35.0.2, platforms;android-35, build-tools 35.0.0), JDK 21 (`~/tools/jdk-21.0.12.1+1`)
- **Signing:** debug keystore `builds/debug.keystore` (standard `androiddebugkey`/`android` debug credentials, public knowledge — NOT a secret). apksigner verify: OK, signer cert `CN=Android Debug, O=Android, C=US` (SHA-256 `e8a9ef77…498`).
- **Package:** `com.sparky.forgefall`, versionCode 1 / versionName 0.1.0, label FORGEFALL, landscape, immersive mode. Native libs: arm64-v8a only (`libgodot_android.so` + `libc++_shared.so`).
- **SDK levels:** minSdk 24 / targetSdk 36 — these come baked into the 4.7.2 export template; the preset's `gradle_build/min_sdk` + `target_sdk` overrides were REMOVED from `export_presets.cfg` because Godot 4.7 rejects them unless "Use Gradle Build" is enabled (non-gradle export error). targetSdk 36 > device API is fine.
- **Permissions (from preset, install-time normal, no runtime prompt):** `INTERNET` (Forge DeepSeek HTTPS), `VIBRATE` (`Input.vibrate_handheld()`).
- **Preset changes (packaging only, no game code touched):** `keystore/debug` → `builds/debug.keystore`, `keystore/debug_user` → `androiddebugkey`, `keystore/debug_password` → `android`; removed the two gradle-only SDK override lines (see above).
- **Environment notes (for future builds on this VM):** (1) Godot 4.7 reads `~/.config/godot/editor_settings-4.7.tres`, NOT `editor_settings-4.tres` — SDK/Java paths must be set there (`export/android/android_sdk_path`, `export/android/java_sdk_path`). (2) Java ignores `*_proxy` env vars — sdkmanager needs proxy via `-Dhttps.proxyHost/Port/User/Password` JVM opts (parsed from `$https_proxy`); the sdkmanager script evals `JAVA_OPTS`, so quote values containing `|`. sdkmanager's repo fetch is flaky through the proxy — the SDK packages were instead downloaded directly with curl from `dl.google.com/android/repository/` using exact archive names from `repository2-1.xml` (`platform-tools_r35.0.2-linux.zip`, `build-tools_r35_linux.zip` → dir `android-15` → renamed to `build-tools/35.0.0`, `platform-35-ext15_r01.zip` → `android-35-ext15` → renamed to `platforms/android-35`).
- **Validation:** `godot --headless --path . --import` clean; `--export-debug "Android"` exit 0; apksigner verify OK; aapt badging shows correct package/version/label/arch.
- **Not yet tested:** install + launch on a real device (needs Colin's S23); touch layout, gyro, haptics, and Forge network calls on-device are unverified.

## Hotfix — black 3D viewport on device (2026-10-12, from Colin's S23 screenshot)
- Symptom: HUD/touch controls rendered, 3D viewport pure black, minimap radar empty. Install itself was fine.
- Root cause: `main.gd start_game()` instantiated the map, HUD, touch layer, and wave manager — but NEVER instantiated `player.tscn`. No Camera3D ever entered the tree, so the viewport had nothing to render. The headless smoke test never caught it (no camera assertion, and headless can't render anyway).
- Fix: new `_wire_player(game_map)` in `main.gd` — instantiates `res://scenes/player.tscn` at a random `player_spawn` marker, parented under the map. Runs before `_wire_waves()` so enemies' player-group lookups resolve.
- Checked and cleared: minimap `own_world_3d = true` is intentional (it's a blip radar with its own backdrop, not a live render) — no change needed; the empty radar was just the missing player blip.
- Rebuilt APK as v0.1.1 (version/code 2). Lesson: every future validation must assert a current Camera3D exists after `start_game()`.

## In-game auto-updater (2026-10-12) — Colin's request: "an updater at the beginning that checks version"

### Design
- `scripts/core/update_manager.gd` (autoload `Updater`): async version check at boot (8s timeout, never blocks the menu), state machine DISABLED → IDLE → CHECKING → UP_TO_DATE / AVAILABLE → DOWNLOADING → READY → (install). Failures are silent on the auto check (subtle line in Options); manual checks report visibly. Update dialog (`scripts/ui/update_dialog.gd`, StencilStyle, touch+mouse) only ever auto-pops over the main menu, never mid-gameplay. "CHECK FOR UPDATES" button + status line added to the Options panel in `main_menu.gd`.
- Base URL lives in ONE place: `Tuning.UPDATE_BASE_URL`. Empty = fully disabled.
- `version.json` protocol: `{"version_code": int, "version_name": "...", "apk_url": "https://...apk", "changelog": "..."}`.
- Hosting pivot (honest): the Tailscale plan (`http://100.79.133.90:8788/`) was verified DEAD — this VM has no Tailscale interface and cannot accept inbound connections (client-only egress proxy). Torn down. Netlify static hosting chosen instead: `https://forgefall-updates.netlify.app` (verified public 2026-10-12 ~16:05 MDT). HTTPS, so no `usesCleartextTraffic` needed.
- `Tuning.UPDATE_BASE_URL` is now `https://forgefall-updates.netlify.app`.

### ForgeUpdater Android plugin (v2, per live docs.godotengine.org 4.x)
- Kotlin source: `~/workspace/forgefall-plugin/ForgeUpdater/src/main/java/com/sparky/forgefall/updater/ForgeUpdaterPlugin.kt` (canonical). Methods: `getVersionCode()`, `getUpdatesDir()`, `installApk(path)` (FileProvider + ACTION_VIEW), `canInstallUnknown()`, `openUnknownSourcesSettings()` — all `@UsedByGodot`, exact names.
- Plugin manifest contributes: `REQUEST_INSTALL_PACKAGES`, FileProvider `<provider>` (`${applicationId}.forgeupdater.fileprovider`), and the `org.godotengine.plugin.v2.ForgeUpdater` meta-data (merged by AGP automatically).
- Editor packaging: `addons/ForgeUpdater/{plugin.cfg, export_plugin.gd}` (@tool EditorPlugin + EditorExportPlugin returning the AAR via `_get_android_libraries`); enabled headless via `[editor_plugins]` in project.godot (verified format from a real-world headless-Godot doc).
- androidx.core is NOT bundled in Godot's AAR (verified by inspecting godot-4.7.2.stable.aar) — declared explicitly as `implementation 'androidx.core:core:1.13.1'` (from Google Maven, not MavenCentral).

### Gradle situation on this VM (honest)
- The Gradle daemon CANNOT communicate here: it starts, binds 127.0.0.1, but the client's connections are never processed (verified via daemon logs, strace-era diagnostics, warm-daemon and --no-daemon attempts — 8+ distinct approaches). Likely the sandbox's memory/network constraints (742MB available). Java ignores `*_proxy` env, so `~/.gradle/gradle.properties` carries the proxy as `systemProp.*` (parsed from `$https_proxy` without logging secrets).
- What DID work: pre-seeding the Gradle 8.11.1 distribution (Godot 4.7.2's pinned version) via curl; installing the Android build template headless (`--install-android-build-template`, must be combined with the export flags — alone it hangs); building the plugin AAR manually with `javac` (no Gradle): `~/workspace/forgefall-plugin/build-aar-manual.sh` → `addons/ForgeUpdater/bin/ForgeUpdater-{debug,release}.aar` (Java 1:1 port in `manual-aar/`, reproducible).
- FALLBACK (per brief, loud): the shipped v0.1.2 APK was built with the PROVEN non-Gradle export (`use_gradle_build` temporarily false). It contains the full updater (check/download/dialog) but NOT the plugin — so "INSTALL NOW" opens the APK URL in Chrome, which downloads it and Colin installs from the notification. Same flow he already uses, minus hunting for the link. The repo preset stays `use_gradle_build=true` with the plugin packaged, so any machine with a working Gradle (e.g. Colin's) produces the full in-app-install build.
- `update_manager.gd` degrades gracefully: `Engine.has_singleton("ForgeUpdater")` gates every plugin call; version compare falls back to `Tuning.FALLBACK_VERSION_CODE` (keep in sync with preset `version/code`).

### Validation (all headless, real)
- `tools/updater_check.gd`: autoload present, DISABLED with empty URL, manual check → graceful "not configured" notice, Options button exists, dialog instantiates. Green.
- `tools/updater_flow_test.gd` (temp localhost server, URL temporarily set): CHECKING → AVAILABLE (v9.9-test/code 99) → DOWNLOADING → READY, 50KB file downloaded, no-plugin install path didn't crash. Green. (tuning.gd restored to the Netlify URL after.)
- `tools/smoke_test.gd` (900 frames): still green with the new autoload.
- APK `builds/forgefall-v0.1.2-debug.apk` (29.3MB, sha256 `809ba8d0…46bbcf74`, apksigner OK): contains `update_manager.gdc` + `update_dialog.gdc`; confirmed NO plugin classes (expected — fallback build). Copied to `updates/forgefall-v0.1.2-debug.apk` for publishing.
- Assumptions noted: `@UsedByGodot` exact-name rule and v2 meta-data format verified against live docs + the official plugin template; `getActivity()` nullability handled; FileProvider authority uses `${applicationId}` (standard AGP substitution).

### For the next version bump
1. Bump `version/code` + `version/name` in export_presets.cfg; sync `Tuning.FALLBACK_VERSION_CODE`.
2. Build APK (if Gradle ever works here, the plugin rides along automatically).
3. Copy to `updates/`, publish APK + new `version.json` per `updates/PUBLISH.md`.

## v0.1.3 — silent-install second attempt (2026-10-12, evening): PLUGIN IS IN THE BUILD

### 1. Docs verdict: truly silent install is IMPOSSIBLE (verified live, developer.android.com)
Checked `PackageInstaller.SessionParams#setRequireUserAction` docs live: the rumored API-31 "self-update carve-out" is NOT real. `USER_ACTION_NOT_REQUIRED` requires ALL listed conditions INCLUDING the `UPDATE_PACKAGES_WITHOUT_USER_ACTION` permission, which is signature|privileged — a sideloaded APK can never hold it. Honest UX ceiling for this app: `USER_ACTION_REQUIRED` → the system shows ONE native "Install update?" dialog, in-app, no browser. That is what v0.1.3 implements. Colin's "silently in app" wish is honored as far as Android allows: download → INSTALL NOW → one system tap → done.

### 2. Plugin rewritten to PackageInstaller Session API
- Kotlin (`~/workspace/forgefall-plugin/ForgeUpdater/.../ForgeUpdaterPlugin.kt`) AND the Java 1:1 port (`~/workspace/forgefall-plugin/manual-aar/ForgeUpdaterPlugin.java`) rewritten: `installApk(path)` now streams the APK into a `MODE_FULL_INSTALL` session (`openWrite` → `fsync` → `commit(intentSender)`), with a dynamically-registered `UpdateStatusReceiver` that fires the confirmation intent on `STATUS_PENDING_USER_ACTION`. `PendingIntent.FLAG_MUTABLE` on API 31+ (required for the system to fill the status intent), `RECEIVER_NOT_EXPORTED` on API 33+. Compile fix: `commit()` takes `IntentSender`, not `PendingIntent`.
- FileProvider + ACTION_VIEW path REMOVED (no longer needed; sessions don't need a content URI). `REQUEST_INSTALL_PACKAGES` + `canInstallUnknown()`/`openUnknownSourcesSettings()` gating KEPT (still required on API 26+).
- AAR rebuilt via `~/workspace/forgefall-plugin/build-aar-manual.sh` → `addons/ForgeUpdater/bin/ForgeUpdater-{debug,release}.aar`; `classes.jar` verified to contain `ForgeUpdaterPlugin.class` + `UpdateStatusReceiver.class`.

### 3. Gradle root cause FOUND (definitive) — the sandbox intercepts Java loopback TCP
- Fixed two real issues first: `org.gradle.jvmargs=-Xmx4536m` on a ~486MB-free VM → `-Xmx1g` (+`kotlin.daemon.jvmargs=-Xmx512m`); wrapper ran as root so it used `/root/.gradle` instead of the pre-seeded `~/.gradle` → `export GRADLE_USER_HOME=/home/hatch/.gradle` (after this `./gradlew --version` SUCCEEDED).
- But every build still died with `Could not receive a message from the daemon` ← `Unexpected type tag 109 found` (109 = ASCII 'm'), daemon logs showing it never accepted the client's connection.
- Decisive experiment: a Java TCP server on 127.0.0.1 + a Java TCP client got the response bytes `muse: Other TCP conn` — the server never saw the connection. Python→Python, Python→Java, and `nc`→Java all worked; Java→Java was intercepted 3/3. CONCLUSION: this sandbox transparently intercepts loopback TCP from Java clients (the 'm' was the first byte of the proxy's message). Gradle's daemon protocol is Java↔Java over loopback → fundamentally impossible here, in every mode (`--no-daemon` still forks a single-use daemon). ~6 genuine new attempts total; not a config problem, an environment hard limit.
- Also confirmed from live docs.godotengine.org: **v2 Android plugins REQUIRE the Gradle build** — the prebuilt-template export cannot take an AAR. So neither stock path can ship the plugin from this VM.

### 4. The workaround: apktool custom template with the plugin baked in
Since Gradle can't run but the plugin is just (a) dex classes + (b) manifest entries, the template APK itself was patched:
1. `apktool d android_debug.apk` (4.7.2 template) → text `AndroidManifest.xml`.
2. Added `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>` and `<meta-data android:name="org.godotengine.plugin.v2.ForgeUpdater" android:value="com.sparky.forgefall.updater.ForgeUpdaterPlugin"/>` inside `<application>`.
3. `d8`'d the plugin's `classes.jar` (from the release AAR) → `classes2.dex` (multidex is native on minSdk 24).
4. `apktool b` → added `classes2.dex` → `zipalign` → signed with the debug keystore → `/home/hatch/workspace/apkmod/template-debug.apk` (114MB).
5. Export preset: `gradle_build/use_gradle_build=false` + `custom_template/debug="/home/hatch/workspace/apkmod/template-debug.apk"` (absolute path; template lives OUTSIDE the project so it never bloats the game .pck).
- NOTE: the preset no longer says `use_gradle_build=true`. The old comment about "any machine with working Gradle produces the full build" is superseded — the plugin now ships via the custom template on THIS vm. If Gradle ever works here, flip it back and delete the custom template.

### 5. v0.1.3 build + verification (2026-10-12 ~22:35 MDT)
- `version/code=4`, `version/name="0.1.3"` in export_presets.cfg; `Tuning.FALLBACK_VERSION_CODE := 4`.
- Non-Gradle export with the custom template SUCCEEDED: `builds/forgefall-v0.1.3-debug.apk` (29.3MB).
- Verified in the final APK: `REQUEST_INSTALL_PACKAGES` present, `org.godotengine.plugin.v2.ForgeUpdater` meta-data → `com.sparky.forgefall.updater.ForgeUpdaterPlugin`, `classes2.dex` present, `dexdump` confirms `Lcom/sparky/forgefall/updater/ForgeUpdaterPlugin;` + `UpdateStatusReceiver;`, `aapt dump badging` → `com.sparky.forgefall` versionCode 4 / 0.1.3.
- Headless `Engine.has_singleton("ForgeUpdater")` check is NOT possible: headless runs the Linux x86_64 binary, Android plugins only load on-device. Structural verification (manifest + dex + class descriptors) is the strongest available proof; the plugin's discovery path (v2 meta-data → `GodotPlugin` subclass with `(Godot)` ctor) matches the documented contract exactly.
- Copied to `updates/forgefall-v0.1.3-debug.apk`; `updates/PUBLISH.md` updated with the exact v0.1.3 `version.json` (changelog honestly: one-tap system dialog, in-app, no browser; silent impossible).
- `update_manager.gd` header comment updated (PackageInstaller, not FileProvider).
- On Colin's S23 the flow is now: dialog → download → INSTALL NOW → (unknown-sources gate if needed) → ONE system "Install update?" dialog → installed. No Chrome. If the plugin ever fails to load, the manager still degrades to the browser fallback.

## v0.1.4 — crash fix (2026-10-12 ~16:55 MDT)

### The crash
Colin reported v0.1.3 "crashes immediately" on launch. Root cause found by inspection (no device needed): **the stock 4.7.2 template already ships a `classes2.dex`** (1960 bytes, containing `org.godotengine.godot.xr.XRMode`). The v0.1.3 template build overwrote it with the plugin's dex (7836 bytes), so `XRMode` was missing from the final APK → the engine died at startup loading a class that no longer existed. The plugin dex itself was clean (only the 3 plugin classes, verified via dexdump); the manifest additions were correct. It was purely a filename collision.

### The fix
1. In `~/workspace/apkmod/decoded/build/apk/`: restored the STOCK `classes2.dex` (XRMode) from `android_debug.apk`, added the plugin's dex as **`classes14.dex`** (stock template ships classes.dex + classes2–13; 14 is the next free slot — multidex loads it automatically on minSdk 24).
2. Empirically confirmed: `apktool b` takes whatever is in `decoded/build/apk/*.dex` into the rebuilt APK (it does NOT re-assemble the `smali*/` dirs over them — v0.1.3 proved this mechanism). So no smali work was needed.
3. `apktool b` → `template-apktool.apk` (verified: classes2=XRMode 1960B, classes14=plugin 7836B) → zipalign → apksigner → replaced `~/workspace/apkmod/template-debug.apk`.
4. Bumped `version/code=5`, `version/name="0.1.4"`; non-Gradle export with the fixed template → `updates/forgefall-v0.1.4-debug.apk` (29.3MB).
5. Verified in final APK: apksigner OK; classes2.dex → XRMode; classes14.dex → ForgeUpdaterPlugin + UpdateStatusReceiver; manifest → versionCode 5 / 0.1.4, REQUEST_INSTALL_PACKAGES, v2 meta-data.

### Environment lessons (added to AGENTS.md-worthy notes)
- **Never hand-zip a template**: my first fix attempt re-zipped the template with `zip -r -9`, and Godot's export failed with "Could not unzip temporary unaligned APK". The apktool rebuild path is the proven one — use it.
- **`/tmp` is a 512MB tmpfs and it FILLED UP** (my unzip leftovers + subagent AAR build dirs), which made Godot exports die silently with empty logs. Now cleaned (1% used). Watch it during big builds.
- Godot export's real exit code was masked by `| tail` in my first attempts — always capture `$?` without a pipe.

### Publish
- Netlify deploy `forgefall v0.1.4 crash fix`; `version.json` → code 5, apk_url → forgefall-v0.1.4-debug.apk, changelog honestly describes the crash fix + the one-tap in-app install ceiling.
- Intermediates cleaned: `apkmod/fix/`, `apktmp/`, `template-apktool.apk`, aligned/unsigned variants, /tmp leftovers.

## v0.1.5 — look/aim + recoil fix (2026-10-12 ~17:10 MDT)

### The bug (Colin's report: "I can't look. Like aim at all.")
`player.add_look()` had NO single unit contract. It multiplied its input by
LOOK_SENS (0.0022), but callers disagreed on units:
- touch_controls: pre-scaled pixels by LOOK_GAIN (0.0022), then add_look scaled
  AGAIN -> total gain 0.0022^2 ≈ 4.8e-6 per pixel. A 500px drag turned 0.14°.
  Effectively dead — exactly what Colin felt.
- weapon recoil: passed RADIANS (arsenal patterns like 0.030 rad ≈ 1.7° kick),
  then add_look multiplied by 0.0022 -> kick ≈ 0.004°. Recoil was invisible.
- gyro_aim: passed radian-derived units -> also ~0.0022x too weak (opt-in,
  disabled by default, but fixed anyway).
- desktop mouse: passed raw pixels -> the ONE path that was correct.

### The fix — one contract: add_look() takes RADIANS
- `player.gd`: add_look(relative) now treats input as radians; applies the new
  `look_sensitivity` var (default 1.0, options menu wires it later) x ADS 0.6
  mult once. Desktop `_unhandled_input` converts pixels -> radians with
  LOOK_SENS at the call site.
- `touch_controls.gd`: UNCHANGED code (already px -> rad via LOOK_GAIN);
  comments updated to document the radians contract.
- `gyro_aim.gd`: GAIN=1.6 is now correctly "radians of view per radian of
  device rotation" (was ~0.0022x too weak); comment fixed.
- `weapon_base.gd`: recoil passes radians already -> now lands at full
  strength (0.030 rad ≈ 1.7° per shot). Gun feel should be noticeably better.
- Headless functional test (temporary scene, since removed): add_look(0.5 rad)
  -> yaw -0.5 ✓; (0, 0.3) -> pitch -0.3 ✓; simulated 500px touch drag ->
  -1.1 rad (≈63°) ✓; recoil kick (0.004, -0.030) -> yaw -0.004 ✓. Zero script
  errors. Lesson: `-s` scripts skip autoloads (Sfx) and `await` in `_init()`
  hangs — run test SCENES via `godot --headless --path . res://...tscn` with
  call_deferred add_child instead.

### Build + publish
- `version/code=6`, `version/name="0.1.5"`; `Tuning.FALLBACK_VERSION_CODE := 6`.
- Non-Gradle export with the fixed custom template -> 
  `updates/forgefall-v0.1.5-debug.apk` (29.3MB), apksigner OK, plugin present.
- Netlify deploy `forgefall v0.1.5 look fix`; version.json -> code 6, changelog
  describes the aim fix honestly.

## v0.1.6 — install diagnostics (2026-10-12 ~18:05 MDT)

### The report
Colin: update downloads, but no system installer appears on his Samsung.
The old flow failed SILENTLY: the plugin logged to logcat (invisible) and
GDScript had no way to know what happened after calling installApk().

### The fix — the install flow now reports every step
- Plugin (Java port + Kotlin source, both updated): new install state machine
  `idle -> starting -> creating_session -> streaming -> committed ->
  user_action -> success`, or `failed` with the reason in the detail string.
  Written from the worker thread AND the status receiver (static instance ref,
  volatile fields). New `@UsedByGodot` methods `getInstallState()` /
  `getInstallDetail()`; receiver callbacks `onUserActionShown()` /
  `onInstallSuccess()` / `onInstallFailed(reason)` replace log-only handling.
  File-missing/empty and null-activity now report `failed` instead of
  returning silently.
- `update_manager.gd` `install_update()`: pre-flight `FileAccess.file_exists`
  check on the downloaded APK (missing -> error dialog, back to AVAILABLE);
  after `installApk()` starts a 0.5s poll timer mapping plugin states to the
  dialog: "Preparing…"/"Writing update package…"/"Waiting for the system
  installer…"/"Confirm the install in the system dialog." Terminal `failed`
  shows the reason in an error dialog; `success` hides the dialog.
- `update_dialog.gd`: new `Mode.INSTALLING` + `show_installing(text)` /
  `set_install_status(text)` (no buttons during install).
- Rebuilt AAR via build-aar-manual.sh, d8 -> classes14.dex, apktool template
  rebuild (proven path), zipalign, sign.
- `version/code=7`, `version/name="0.1.6"`; `Tuning.FALLBACK_VERSION_CODE := 7`.
- Export verified: signed, code 7, new plugin methods in classes14.dex, 0
  export errors. Netlify deploy `forgefall v0.1.6 install diagnostics`.
- Next time Colin taps INSTALL NOW, the dialog will say EXACTLY where it
  stalls (or the real reason it fails) — his report will pinpoint the cause.

## v0.1.7 — canary (2026-10-12 ~18:10 MDT)
Identical to v0.1.6 except version/code 8. Exists so the v0.1.6 install
diagnostics have a real update to exercise: Colin installs v0.1.6, launches,
gets offered v0.1.7, and the new reporting dialog shows exactly where the
install stalls. `Tuning.FALLBACK_VERSION_CODE := 8`. Published to Netlify.

## v0.1.8 — manifest-declared install receiver (2026-10-13 ~11:00 MDT)

### The report
Colin: v0.1.6's diagnostics still didn't produce the system installer.
(He didn't report what the dialog said — still unknown whether it stuck at
"Waiting for the system installer…" (committed, no callback) or showed a
failure reason. Asked.)

### The fix — the status receiver is manifest-declared now
Prime suspect: the status receiver was registered DYNAMICALLY
(`registerReceiver` with RECEIVER_NOT_EXPORTED). The system's
PackageInstaller status callback can miss a dynamically-registered receiver;
the manifest-declared receiver is the documented pattern (and survives the
app being backgrounded/killed mid-install).
- `UpdateStatusReceiver` moved to its own file
  (`manual-aar/UpdateStatusReceiver.java`, public top-level — Java requires a
  public class in its own file; this also fixed a latent build-script flaw:
  javac failures were masked by `|| true`, so the AAR build now fails loudly).
  Kotlin source keeps the receiver in the same .kt file (Kotlin allows
  multiple public top-level classes per file).
- `decoded/AndroidManifest.xml`: added
  `<receiver android:exported="false"
  android:name="com.sparky.forgefall.updater.UpdateStatusReceiver">` with the
  INSTALL_STATUS intent-filter.
- Dynamic `ensureStatusReceiver()` deleted from both sources.
- Rebuilt AAR, d8 -> classes14.dex, apktool template rebuild, zipalign, sign.
- `version/code=9`, `version/name="0.1.8"`; `Tuning.FALLBACK_VERSION_CODE := 9`.
- Export verified: signed, code 9, manifest contains the receiver + filter,
  0 export errors.

### v0.1.9 — canary (2026-10-13 ~11:05 MDT)
Identical to v0.1.8 except version/code 10. KEY POINT: the install flow runs
in the OLD version — v0.1.6's broken dynamic receiver would still handle a
v0.1.6 -> v0.1.8 install. So Colin must install v0.1.8 MANUALLY first;
then v0.1.8's manifest receiver handles the v0.1.8 -> v0.1.9 install, which is
the real test. Published v0.1.6 + v0.1.8 + v0.1.9 + version.json (code 10).

## v0.1.8 -> v0.1.9 — in-app install CONFIRMED WORKING (2026-10-13 ~11:07 MDT)
Colin: "It worked!" The manifest-declared receiver was the fix. The full
updater loop is now verified end-to-end on his Galaxy S23: launch check ->
update dialog -> download -> INSTALL NOW -> ONE native "Install update?"
system dialog -> installed in-app, no browser, no manual APK handling.
The updater is DONE as a feature. Future builds just need version bumps +
Netlify publishes; the install path is proven.

## v0.1.10 — guns back, wall-run works, grapple sound fixed (2026-10-13 ~11:20 MDT)

### Colin's report (3 bugs)
"There are no guns. The wall running doesn't work. And the hook makes a
loud noise that doesn't stop and stacks if you keep pressing it."

### Fix 1 — No guns: WeaponManager was never added to the player scene
`weapon_manager.gd` (builds 3 weapons, parents the viewmodel to the
camera) existed but `player.tscn` had NO WeaponManager child — same
wiring-class bug as v0.1.1's missing player. Nothing ever built a weapon.
- Added `<WeaponManager>` (Node3D + weapon_manager.gd) to `player.tscn`.
- `WeaponManager._ready()` now `add_to_group("weapon_manager")` — the HUD
  binds ammo/weapon signals via that group, and the manager never joined
  it, so the ammo readout would have stayed dead even with the node added.

### Fix 2 — Wall-run: sprint gate + side-rays-only
Two touch-hostile gates in `player.gd _update_wallrun()`:
- Entry AND keep required `Input.is_action_pressed("sprint")` — on touch,
  sprint only fires at >=92% stick deflection, so a wall-run needed the
  stick pinned at max for the whole run.
- Only side rays were checked — jumping head-on at a wall never triggers
  (side rays run parallel to a wall directly ahead and never hit it).
- Added `WallRayF` (forward, 1.6m) to `player.tscn`. Wall-running is now
  MOMENTUM-gated (airborne + >3 m/s + moving + wall in reach), Titanfall-style;
  a head-on approach enters via the forward ray and the tangent redirect
  runs the player along the wall the way they were moving.

### Fix 3 — Grapple zip: looping stream re-triggered with no stop path
`grapple_zip` is a LOOP_FORWARD stream (seamless loop). `apply_grapple()`
called `Sfx.play_2d("grapple_zip")` every 0.3s while attached — each call
grabbed a new pool player and started ANOTHER forever-loop. `release()`
never stopped any of them, and `Sfx` had no stop API at all. The Raptor
throw aliased to the same loop stream, leaking one more per throw.
- `audio_manager.gd`: new `start_loop_2d(id)` / `stop_loop_2d(id)` —
  dedicated per-id player, idempotent (re-start = no-op, no stacking).
- `play_2d`/`play_3d` now REFUSE loop streams (warn + return) so a
  one-shot call can never leak a loop again.
- `raptor_throw` alias re-pointed at `grapple_fire` (a one-shot whoosh).
- `grapple_hook.gd`: `fire()` starts the zip loop once, `release()` stops
  it; the 0.3s retrigger (`_zip_t`, `ZIP_SFX_INTERVAL`) deleted.

### Validation
- New `tools/verify_fixes.gd` (18 checks, headless): weapons present +
  viewmodel on camera + HUD group; wall-run side approach without sprint;
  wall-run head-on via forward ray; loop start/stop/idempotency + one-shot
  refusal + full grapple fire/release cycle. ALL PASS. (First run caught a
  racy test setup — head-on start was beyond ray range — fixed the test,
  not the game; the mechanic verified in isolation too.)
- Full 900-frame smoke test: green (only the known DeepSeek TLS
  offline-fallback line).
- `version/code=11`, `version/name="0.1.10"`; signed; clean export.
- Published v0.1.9 (rollback) + v0.1.10 + version.json (code 11). Colin
  gets it via the in-app updater he just verified.

## v0.1.11 — v0.5 chunk 1: Forge menu + backend, dusk lighting, props, HUD, audio/touch (2026-10-13 ~18:30 MDT)

### Shipped (6 workstreams, coordinator-integrated)
- **B1 Forge menu UI** (new scenes/ui/forge_menu.tscn + scripts/ui/forge_menu.gd):
  4 tabs (Build 7 presets, Weapons 5, Events 4, Killstreaks 3), preset ->
  cost preview -> FORGE IT confirm, free-text field, live budget, history
  (tap to re-submit), undo button, forge_result toasts. open()/close() API,
  group "forge_menu". Degrades gracefully when backend methods are absent.
- **B2 Forge backend** (forge_llm/forge_builder/forge_manager):
  Contract API: get_budget(), preview_cost(), undo_last() (one level,
  structural removal + exact refund; effect-only actions refund with a
  "stands" note), get_history() (cap 10). Parser: tower/bridge/bunker/
  watchtower/ammo depot/spawn enemies + aliases (sniper rifle, drone, sentry,
  ramp, pillbox) + helpful unknown-prompt error. New buildables with
  collision: bridge (stepped ramp), bunker (roofed pillbox), watchtower
  (3 m platform + stairs), ammo depot (crates + free cache). Structure cap
  12. Emissive orange spawn marker per build. Costs: wall 100, tower 150,
  bridge 120, bunker 180, watchtower 200, ammo depot 150, turret 250,
  sniper 200, UAV 150, spawn enemies 150, smoke 100, supply 50.
  New structures are solid (not destructible) — follow-up, not regression.
- **A1 Lighting** (dustline_builder._build_environment): one DirectionalLight3D
  sun, real shadows (single orthogonal cascade, 90 m frustum, bias tuned),
  ambient 0.65, gradient sky (PanoramaSkyMaterial + GradientTexture2D, no
  shader), fog 0.0075, ACES exposure 1.1, glow off, emissive 4.0x. Zero
  draw-call growth (still 3 MultiMeshes). Project shadow size 2048 -> 1024.
- **A2 Props** (new scenes/maps/dustline_props.tscn): 19 props, 19 box
  collisions, 2 MultiMesh nodes (+2 draw calls) — crates, barrels, sandbags,
  signs, ground variation, laundry line, canopy. Clear of spawns/doors/stairs.
- **A4 HUD** (hud.gd + stencil_style.gd): ammo 56 + caption, health cluster
  (numeric + bar, green/orange/red), killfeed capped at 4, two-stage vignette,
  hitmarker variants (hit/headshot/kill), killstreak pips with icons, UAV
  display via contract + legacy set_uav kept. Fixed live hud.gd:519 parse
  error (explicit `var ready: bool`).
- **C3 Audio + touch** (audio_manager + touch_controls): MIX_DB table (AR 0 dB
  ref, others -1..-5, clamped <= 0 dB), ambient wind on music bus during
  gameplay, Forge sounds verified wired, footsteps -4 dB, grapple loop fix
  untouched. Touch layout: uniform scale + retry-until-no-overlap, FIRE
  largest, same ids/actions. First-time hints (HOOK + wall-run), once per
  session, 10 s + fade.
- **Coordinator wiring** (main.gd + hud.gd): _wire_props() instances the
  props scene under the map; _wire_hud() instances the Forge menu;
  HUD forge_console delegates to the menu when present, legacy panel is
  the fallback. Fixed stale "No set_uav on the HUD" comment in
  forge_builder.gd. B1 verifier updated from degradation to integrated
  expectations (methods now present post-B2).

### Validation
- A1 24/24, A2 PASS, B1 ALL PASS (integrated), B2 89/89, A4 56/56,
  C3 27/27, verify_fixes 17/17, integration (props + menu open/close) 5/5.
- 900-frame smoke: green (budget 300 -> 200, 17 cover nodes).
- APK: signed, code 12, manifest UpdateStatusReceiver present,
  classes14.dex present, stock classes2.dex intact, 0 export errors.
- Deployed: index.html (now links v0.1.11) + version.json (code 12) +
  v0.1.9 + v0.1.10 + v0.1.11 — all verified 200/206.

### Still to come for v0.5
- A3 viewmodels/effects, C1 enemy AI, C2 killstreaks (in flight).
- Needs Colin's on-device verdict: dusk look, prop density, Forge loop
  (esp. new buildables + undo via live DeepSeek path), HUD readability,
  touch layout feel, sound mix.

## v0.5.0 — MILESTONE: all of A+B+C verified (2026-10-13 ~18:35 MDT)

### Shipped (chunk 2: A3 + C1 + C2 — completes A+B+C)
- **A3 Viewmodels + effects** (arsenal.gd, weapon_base.gd, tracer_pool.gd,
  fx/explosion.gd, NEW fx/impact_fx.gd): per-weapon voxel detail — AR-7
  foregrip/mag ribs, LR-8 fluted barrel/bipod/scope shade, SG-12 ghost-ring
  + pump grooves, SMG-9 red-dot sight, P9 tritium night sights, Raptor
  grip/vent. Every viewmodel carries Sight/Stock/Grip/Barrel/Muzzle/Eject
  markers. ADS alignment FIXED: old shared ADS_POS.y=-0.148 put every sight
  ~6 cm below centre; now per-weapon _ads_pos from Arsenal.SIGHT_Y, sight
  world Y = 0.0000 for all 6. Muzzle flash light FIXED: was parented to the
  weapon node in viewmodel-local coords (offset from muzzle); now parented
  to the viewmodel, energy 4.0, range 6.0, 40 ms, no shadows. Effects (all
  pooled/capped): ImpactFX.spawn() 24-puff impact dust on real hits,
  spawn_smoke() dark explosion smoke on both detonate paths, tracers
  life 0.10 s / width 0.024 / emission 6, landing dust on hard landings
  (auto-bound to player `landed`, no player.gd change). Stats unchanged.
  Also fixed `depth_write` -> `depth_draw_mode` warning.
- **C1 Enemy AI** (enemy_base + grunt/rusher/marksman/brute + wave_manager):
  distinct tunings — rusher 7.0 speed / 6 m range / 60 HP / 0.35 acc /
  6x6 pellets; grunt 4.2 / 15 m / 100 HP / 0.55 / 9x3 burst; marksman
  3.4 / 29 m / 80 HP / 0.88 / 22 single + in-band sidestep/peek; brute
  2.4 / 13 m / 1200 HP / 0.42 / 9x8 barrage. No worst-case burst >= 100.
  Ramp: w1 = 5 grunts only; rushers w2+, marksmen w3+, 1 brute every 5th
  wave, 2nd brute from w10; totals w1=5, w5=17, w10=28; alive cap 10.
  Spawn telegraphs: 0.5 s pulsing glow column at the door (color-coded by
  type) + sound; enemy frozen (no AI/move/fire) during the window,
  damageable. SPAWN settle trimmed (0.5-0.9 s).
- **C2 Killstreaks** (killstreaks.gd): UAV — exact HUD contract
  (uav_started/uav_ended signals, get_uav_targets() live-only, 20 s,
  re-trigger refreshes, legacy set_uav kept). Airstrike — warning
  marker/flare + 1.5 s delay, 3 blasts along a line, 8 m / 120 dmg,
  ENEMY-ONLY radial damage (no longer routes through the builder path that
  could hit the player) + detonate_light visuals. Chopper — voxel gunship
  orbits 25 m / 14 m for 45 s, 10 dmg hitscan / 0.5 s at nearest enemy in
  40 m, tracer beam per shot, climbs + frees itself. All triggerable via
  Forge prompts AND the earned 3/5/7 streak path. Full cleanup verified.
- **Coordinator integration fix**: C1 verifier phase-3 was racy (fixed
  _process frame count vs physics time; flaked 2/3 runs). Rewrote as
  poll-until-transition with timeout — 5/5 stable green. (C1's report said
  31 checks; 30 execute — 5 _check calls sit in unexecuted branches.
  Cosmetic; all key behaviors covered.)

### Validation (final full-suite run)
- A1 24/24, A2 PASS, A3 103/103, A4 56/56, B1 ALL PASS, B2 89/89,
  C1 30/30 (after race fix, 5/5 runs), C2 ALL PASS, C3 27/27,
  verify_fixes 17/17, integration 5/5. 900-frame smoke green.
- APK: signed, code 13, version 0.5.0, manifest UpdateStatusReceiver
  present, classes14.dex present, stock classes2.dex intact,
  0 export errors.
- Deployed: index.html (links v0.5.0) + version.json (code 13) +
  v0.1.10 + v0.1.11 + v0.5.0 — all verified 200/206. (v0.1.9 dropped:
  superseded twice, unreferenced by any live page.)

### Still OUT (per brief)
- Multiplayer: explicitly deferred, not started.
- Portal see-through rendering: stretch goal, not attempted — never blocked
  v0.5. Voice forging stays typed-only.
- New Forge structures are solid, not destructible (follow-up).
- Earned-streak unlock flow (Game.use_killstreak) not live-tested headless
  (no harness); trigger() shared by both paths is fully tested.

### Needs Colin's on-device verdict
- Dusk look (sky orientation, fog, emissive glow without bloom), prop
  density, HUD readability, touch layout feel, sound mix.
- Gun feel + ADS alignment (sights now geometrically centred; phone
  FOV/aspect + red-dot/tritium readability need his eyes), muzzle-flash
  brightness, tracer visibility, landing dust.
- Forge loop via live DeepSeek (new buildables' climbability/sight-lines/
  stairs, spawn marker, undo feel).
- Enemy difficulty (rusher 7.0 speed dodgeable? marksman fair? brute HP?),
  telegraph glow readability, killstreak feel (airstrike warning, chopper
  orbit, UAV blips on minimap).

## v0.5.1 — Colin + Donny playtest fixes (2026-10-13 ~19:35 MDT)

### The report (7 issues, 2 screenshots)
Colin: taps anywhere fire; HUD too small; shadows messed up.
Donny: can't pick up ammo packs; grapple texture takes over a quarter of
the screen; Forge auto-pops the keyboard; voice "knife" → nothing.
(Donny's "app link dont work" treated as transient — share page verified
200, link card rendered in his chat; no code fix.)

### Fix 1 — Tap-anywhere-fires (coordinator, project.godot)
`fire` is bound to mouse button 1 and Godot's default
`emulate_mouse_from_touch=true` synthesizes a mouse click per tap.
Set `pointing/emulate_mouse_from_touch=false`. CAUGHT IN VERIFICATION:
my first edit used `#` comments in project.godot — Godot parses `#`
lines as setting keys (comments are `;`), and the mangled key swallowed
the real setting (setting read back `true`). Fixed to `;` comments;
setting now reads `false`. Lesson: never `#` comments in .godot files.

### Fix 2 — HUD layout (hud.gd layout only + touch_controls.gd untouched)
Topbar moved 14–48 → 80–114 (clear of FORGE/MIC/K1–K3), font 20→26;
ammo block moved to −410…−270 (above the right cluster), fonts up
(weapon 26, AMMO 20, RELOAD 30); persistent hint line removed (first-time
hints stay with the touch layer, brief + fade); minimap moved below
BLU/ORG and hidden unless UAV active (frame re-synced every frame);
all HUD labels ≥20; HUD's duplicate pause button hidden in touch mode.
Verified 60/60 across 5 viewport sizes incl. S23 2340×1080.

### Fix 3 — Shadows (dustline_builder.gd; coordinator set map 2048)
Sun: shadow_bias 0.02→0.05, shadow_normal_bias 0.3→1.0, shadow_blur
0.0→1.0. Dusk color/energy/direction unchanged. Note: no per-light
`shadow_filter` exists in Godot 4.7.2 — blur is the per-light control.

### Fix 4 — Ammo packs (ammo_pickup.gd) + health packs (player.gd)
Pickup `collision_mask` was 1; player is on layer 2 → `body_entered`
never fired. Mask is now `1 | 2`. Coordinator follow-up: the health
branch calls `body.heal()` but `player.gd` had NO `heal()` — added it
(clamped, always applies since the pickup frees itself after the call).
Verified: reserve 168→288 + freed; HP 60→85 + freed. (My first heal()
edit briefly merged two lines and broke player.gd's parse — caught by
the headless run, fixed, re-verified clean.)

### Fix 5 — Grapple beam (grapple_hook.gd)
`_process` overwrote the rope/spark scales with 1.0 cross-sections.
Now `_rope.scale = (0.06, 0.06, d)`, `_spark.scale = 0.18 * s`.
Verified: rope (0.06, 0.06, 2.098), spark 0.18×pulse.

### Fix 6 — Forge keyboard (hud.gd focus lines + forge_menu.gd)
HUD toggle passes focus=false; chip path no longer grab_focus();
menu LineEdit `focus_mode = FOCUS_CLICK`; `open()` releases focus,
`close()` dismisses keyboard. Keyboard appears ONLY on LineEdit tap.

### Fix 7 — Voice + unknown prompts (speech_input.gd + forge_llm.gd)
MIC fallback now toasts "Voice input isn't available yet — type your
prompt" via the Forge channel BEFORE opening the console. Unknown
prompts return a visible error: "Don't know 'knife' — try: wall, tower,
turret, bridge, bunker, watchtower, ammo depot, sniper, UAV". No knife
weapon added. Caveat: the REMOTE DeepSeek path may still turn an unclear
prompt into a supply drop (system prompt instructs it); the offline
parser path is the one fixed.

### Validation
- New `tools/verify_v051.gd`: 24/24 PASS, 0 script errors.
- Existing `tools/verify_fixes.gd`: ALL PASS. 900-frame smoke: green.
- Export: signed, code 14, manifest receiver present, classes14.dex
  present, stock classes2.dex intact, 0 export errors.
- Deployed: index.html (v0.5.1) + version.json (code 14) + v0.1.11 +
  v0.5.0 + v0.5.1 — all verified 200/206.

## v0.5.2 — v0.6 chunk 1: level wall-run, grapple swing, Forge LLM real, Loadouts (2026-10-13 ~20:00 MDT)

### Item 1 — Wall-run stays level (Worker A)
- `player.gd _update_wallrun()` entry: `velocity.y = maxf(velocity.y, 1.0)` → `0.0` (a jump's upward velocity no longer survives into the run).
- Keep branch: `maxf(velocity.y, -2.0)` → `clampf(velocity.y, -0.5, 0.5)` — the run stays level. Wall-jump (WALL_JUMP_UP) untouched.
- Verified: max |vy| 0.12 over 10 frames, still moves forward.

### Item 5 — Grapple pendulum / Spider-Man swing (Worker A)
- `grapple_hook.gd fire()`: DIRECT iff anchor direction within 35° of straight up AND hspeed < 4.0 (old height check replaced). Side/ahead anchors → PENDULUM.
- `apply_grapple(delta, vel, wish)`: PENDULUM branch projects wish onto the plane perpendicular to the rope, accelerates along it at 8.0, tangential cap 14.0. Purely tangential — rope constraint intact.
- Release keeps momentum (unchanged). Verified: pumping 8.54 tangential vs 3.00 no-input; rope constraint holds; release preserves velocity exactly.

### Item 2 — Forge LLM, real (Worker B)
- Model `deepseek-chat` → `deepseek-flash` (DeepSeek-V4.1-Flash; old name retired 2026-07-24 per DeepSeek docs). Request sends `"thinking": {"type": "disabled"}` (thinking defaults ON and bills reasoning tokens).
- One stable SYSTEM_PROMPT constant: exact JSON schema + fixed catalog with fixed costs + few-shot examples + explicit REFUSAL shape (`action:"refuse"`); "improvise a supply_drop" removed.
- Strict `validate_modspec()`: REJECTS (never repairs) unknown action/target, invented fields, wrong cost, out-of-range numbers, code/script content. Refusals pass through untouched (never fall into offline fallback).
- `forge_manager.gd _run_pipeline()`: refusal first (no charge, no fallback) → strict gate → lenient validate kept as no-op safety net + preview_cost/back-compat.
- Forge menu: DeepSeek key entry (secret-masked, SAVE/CLEAR, status present/absent only, key never displayed/logged; FOCUS_CLICK). Results/refusals surface via existing forge_result → toast.
- DeepSeek skill authored (`~/workspace/custom-skills/deepseek/` + `custom.deepseek` connector doc + helper via surrogate exchange). Live test with stored credential (2 small calls): "build a tower near me" → exact valid spec (tower [4,10,4], hp 350, cost 150), 0 cache hits cold; "make a flying car that shoots lasers" → clean refusal, 896/1035 prompt tokens cache hits — proves stable-prefix-first layout hits DeepSeek's cache. No key ever printed/logged/filed.
- Fixed during integration: `forge_llm.gd:279` `var cost := spec.get(...)` Variant-inference parse error → `var cost: Variant`.
- Verified: verify_v06_llm 63/63, verify_fixes green, verify_v051 green.

### Item 4 — Loadouts (Worker D; tab applied by coordinator after Worker B)
- `weapon_manager.gd`: `LOADOUTS` const, `set_slot(slot, weapon_id)` (give_weapon now delegates to it), `equip_loadout(primary, secondary)`, `equip_loadout_named(name) -> bool`, `get_slot_weapon_id(slot)`. No budget touched in these paths.
- Forge menu: new "Loadouts" tab (5th tab) with 4 buttons — Assault (ar7/p9), Marksman (lr8/p9), Breacher (sg12/smg9), Raptor (raptor/smg9). Applies immediately on tap, toast "equipped — free."
- Verified: verify_v06_loadouts 42/42 (each preset sets exact ids, budget stays 300, unknown names no-op) + menu-level check (Loadouts tab present, 4 buttons, key input present).

### Integration + publish
- Full battery after integration: verify_v06_llm, verify_v06_loadouts, verify_v06_movement, verify_fixes, verify_v051 — ALL PASS. 900-frame smoke green (Forge still works: budget 300→200, covers 16→17).
- `version/code=15`, `version/name="0.5.2"`; signed; manifest UpdateStatusReceiver present; classes14.dex present; stock classes2.dex intact; 0 export errors.
- Deployed: index.html (v0.5.2) + version.json (code 15) + v0.1.11 + v0.5.0 + v0.5.1 + v0.5.2 — all verified 200/206.
- Still pending: Item 3 (MIC / ForgeSpeech plugin) — lands in the next increment.

## v0.6.0 — MILESTONE: all 5 items verified (2026-10-13 ~20:05 MDT)

### Item 3 — MIC voice input, real (Worker C; integrated by coordinator)
- `speech_input.gd`: `listen(callback, press_console_on_fallback := true)` — plugin path gates on runtime permission (`OS.get_granted_permissions()`); not granted → `OS.request_permission("android.permission.RECORD_AUDIO")` + waits for `MainLoop.on_request_permissions_result` (grant auto-starts listening; denial → typed fallback). Single `onResult` connection (old double-connect removed). Empty transcript (plugin's error signal) → typed fallback. v0.5.1 floor (toast + typed console) intact.
- `touch_controls.gd`: MIC handler strips/drops empty transcripts.
- Forge menu: new MIC button in the prompt row (`listen(..., false)` — fallback does NOT press forge_console, which would toggle the menu closed from inside it). Transcript submits via the same `_submit_prompt` path.
- ForgeSpeech plugin (NEW, `~/workspace/forgefall-plugin/ForgeSpeech/`): GodotPlugin subclass, singleton "ForgeSpeech", `@UsedByGodot startListening()` → Android SpeechRecognizer, `onResult` fires exactly once (transcript or "" on error/unavailable/SecurityException — never hangs/crashes). Manual-AAR flow (javac + zip, no Gradle). AAR copied to `addons/ForgeSpeech/bin/` + export template files.
- Template integration (coordinator): plugin classes d8'd to NEW `classes15.dex` (ForgeUpdater stays in classes14.dex, stock classes2.dex intact); manifest gains RECORD_AUDIO + `org.godotengine.plugin.v2.ForgeSpeech` meta-data; template rebuilt via apktool + zipalign + sign.
- Verified: verify_v06_mic 53 PASS / 0 FAIL (permission flow, fallback paths, plugin sources/manifest/AARs, menu block parses); verify_fixes + verify_v051 green; menu check (MIC button present, Loadouts tab present).

### Integration + publish (v0.6.0)
- Full battery after final integration: verify_v06_mic, verify_v06_llm, verify_v06_loadouts, verify_v06_movement, verify_fixes, verify_v051 — ALL PASS. 900-frame smoke green (Forge still works: budget 300→200, covers 16→17).
- `version/code=16`, `version/name="0.6.0"`; signed; manifest has UpdateStatusReceiver + ForgeSpeech meta-data + RECORD_AUDIO; classes2/14/15 dex present; 0 export errors.
- Deployed: index.html (v0.6.0) + version.json (code 16) + v0.1.11 + v0.5.0 + v0.5.1 + v0.5.2 + v0.6.0 — all verified 200/206.
- v0.5.2 (code 15) shipped earlier in this batch as the integrated chunk 1 (wall-run + swing + LLM + loadouts); v0.6.0 adds Item 3 (MIC) to complete all 5.

## v0.6.1 — resolution-scaled full-screen Forge menu + HUD scaling (2026-10-13 ~14:58 MDT)

### Shipped (Workers A/B/C, published by Worker D — GDScript-only, template untouched)
- **Forge menu** (Worker A): new `scripts/ui/ui_scale.gd` (resolution-based
  scale factor) + `forge_menu.gd` rework — the Forge menu is now a true
  full-screen menu with fonts and clickable widgets scaled by resolution
  instead of one-size-fits-all (Colin's "too big" report).
- **HUD** (Worker B): `hud.gd` hides the HUD behind the Forge menu and
  restores it on close; HUD fonts and `touch_controls.gd` widgets scale
  by resolution via the same `ui_scale.gd` factor.
- **Verification** (Worker C): new `tools/verify_v061.gd` — **1462 PASS**,
  all regressions + 900-frame smoke green.

### Publish (Worker D)
- `version/code=17`, `version/name="0.6.1"` in export_presets.cfg; signed
  debug APK `updates/forgefall-v0.6.1-debug.apk` (29,461,150 bytes) +
  `.idsig`, built with the unchanged v0.6.0 custom template (no Gradle,
  no template rebuild — GDScript-only change).
- APK verified: apksigner verify OK; aapt badging → `com.sparky.forgefall`
  versionCode 17 / versionName 0.6.1; manifest has UpdateStatusReceiver +
  ForgeUpdater + ForgeSpeech meta-data + RECORD_AUDIO +
  REQUEST_INSTALL_PACKAGES; classes2.dex = stock XRMode intact,
  classes14.dex = ForgeUpdaterPlugin + UpdateStatusReceiver,
  classes15.dex = ForgeSpeechPlugin.
- Deployed: index.html (v0.6.1) + version.json (code 17) + v0.1.11 +
  v0.5.0 + v0.5.1 + v0.5.2 + v0.6.0 + v0.6.1 — live page 200, live
  v0.6.1 APK 206, live version.json reads code 17, all older APKs 206.
- FLAG: `Tuning.FALLBACK_VERSION_CODE` still reads 16 — Worker D was
  barred from editing GDScript, so the one-line sync was left for the
  coordinator. Harmless in practice: the baked-in plugin's
  `getVersionCode()` (17) is what the updater compares on-device; the
  fallback only matters on builds without the plugin.

## v0.6.2 — Forge LLM composition gate (Colin's deliberate loosening) (2026-10-13 ~15:50 MDT)

### Shipped (Workers A/B/C, published by Worker D — GDScript-only, template untouched)
- **Composition-allowed Forge LLM gate** (`forge_llm.gd` + `forge_builder.gd`):
  the LLM may now COMPOSE known blocks — any known weapon + any known
  ammo_type (`standard`/`sniper` +50 / `armor_piercing` +75 / `buckshot`
  +50), any known cover/structure + `reinforced` property (+50 surcharge,
  +50% HP in the builder), turret + ammo_type. The game recomputes the
  cost as base + surcharges (`recompute_cost()`); the model's cost
  estimate is never trusted, and a cost mismatch no longer rejects.
  Few-shot example: "LMG with sniper bullets" -> lmg + sniper ammo, 250.
  This is Colin's deliberate call after v0.6.1's strict gate refused
  that exact prompt. Hard rule preserved: every piece of a composed
  spec must be a known catalog block — still never invented blocks,
  weapons, scripts, or code.
- **Verification** (Worker C): code + verification done before publish
  (per coordinator brief); no template/plugin changes.

### Publish (Worker D)
- `version/code=18`, `version/name="0.6.2"` in export_presets.cfg;
  `Tuning.FALLBACK_VERSION_CODE` synced 17 -> 18 (the v0.6.1 publish's
  one-behind flag is now resolved).
- Signed debug APK `updates/forgefall-v0.6.2-debug.apk`
  (29,485,879 bytes) + `.idsig`, built with the unchanged custom
  template (no Gradle, no template rebuild — GDScript-only change).
  Godot's export signed via apksigner itself (build-tools 35.0.0).
- APK verified: apksigner verify OK (v2 + v3 schemes); aapt2 badging ->
  `com.sparky.forgefall` versionCode 18 / versionName 0.6.2;
  manifest has UpdateStatusReceiver + ForgeUpdater + ForgeSpeech
  meta-data + RECORD_AUDIO + REQUEST_INSTALL_PACKAGES; classes2.dex =
  stock XRMode intact (1960 B), classes14.dex = ForgeUpdaterPlugin +
  UpdateStatusReceiver, classes15.dex = ForgeSpeechPlugin.
- Deployed (Netlify deploy `6acea7964df43a75154666f7`,
  "forgefall v0.6.2 composition gate"): index.html (v0.6.2) +
  version.json (code 18) + v0.1.11 + v0.5.0 + v0.5.1 + v0.5.2 +
  v0.6.0 + v0.6.1 + v0.6.2 — live page 200, live v0.6.2 APK 206,
  live version.json reads code 18, all older APKs 206. Pre-deploy
  probe confirmed the live set (v0.1.9/v0.1.10 already 404 from an
  earlier deploy; .idsig files are not served, so none were deployed).

## v0.7.0 — USER MODS, GMod-style (chunk 1) (2026-10-13 ~16:15 MDT)

### Shipped (Workers A/B/C, published by coordinator — GDScript-only, template untouched)
- **User mods system** (`scripts/mods/` NEW: `mod_loader.gd`,
  `mod_block.gd`, `mod_api.gd`): mods live in `user://mods/`, scanned
  on startup via a one-line hook (`Forge._ready()`, forge_manager.gd:49).
  Each mod = folder/file + manifest (name, kind, version, author).
- **TWO KINDS**: (1) JSON BLOCKS (data-only): new weapon / cover /
  structure / turret / pickup as JSON stats + references.
  Schema-validated (types, ranges, known references, no unknown
  fields, no duplicate block_id) BEFORE registration. (2) GDScript
  SCRIPTS: must `extend ModBlock` exactly; talk to the game ONLY via
  the minimal `ModAPI` (spawn voxel box/cover/pickup/turret, give
  weapon, fire effect, announce, player/root getters — NO
  filesystem/network/OS/eval). Forbidden-API text scan before load
  (OS.*, FileAccess, DirAccess, Expression, load(, ResourceLoader,
  ClassDB, threads, .new(, call(, @tool, ...). Load/compile errors ->
  mod disabled + recorded error, never a crash.
- **LLM catalog** (`forge_llm.gd`): base blocks + ENABLED user mods.
  Stable base SYSTEM_PROMPT stays byte-identical and FIRST (cache
  unit); user mods go in a second system message ("USER MODS"
  section) before the user prompt. Gate accepts specs referencing
  enabled user-mod blocks, cost recomputed = mod declared cost +
  surcharges for ammo_type/property the mod doesn't already declare.
  Disabled/broken mods never appear in the catalog.
- **Builder** (`forge_builder.gd`): `mod_block` specs route to
  `_build_mod_block` — JSON via existing paths (weapon: base +
  multipliers + ammo composition; cover: merged params + custom
  palette; structure: merged; turret: merged + combined metas;
  pickup: merged + amount), script via `ModLoader.instantiate_script_mod`
  + `ModAPI` (cap check + undo/cap registration). Failures return
  `FORGE_FAIL:` strings, never crash. ModLoader accessors lazy-scan
  (`_ensure_scanned()`), so the gate works even if the hook were missed.
- **Mods tab** (forge_menu.gd, 6th tab): lists installed mods (name,
  kind, ENABLED/DISABLED, red error line on failure), per-mod
  enable/disable toggle (persisted to `user://mods_enabled.json`),
  Rescan button (picks up newly dropped mods without restarting),
  mods-folder path label, empty-state text. Loader resolved via
  ResourceLoader (no hard class ref) — menu still opens if the
  loader is absent. All prior tabs/features untouched.
- **Turret follow-up** (v0.6.2 gap, closed): `forge_turret.gd` now
  READS `damage_mult` / `range_mult` metadata (in `_ready()` + re-read
  on every acquire/fire), so a turret with sniper ammo actually hits
  harder/farther. Defaults 1.0, clamped >= 0.
- **Verification** (Worker C, `tools/verify_v07_mods.gd`): 80/80 PASS
  — JSON load/register/catalog/build; bad schema + malformed JSON
  disabled + errored, no crash; ModBlock script load + ModAPI apply;
  syntax-error + `OS.execute` scripts disabled + errored; toggle
  persists + survives rescan; mod turret 2.0x damage live (30.0/hit);
  base prompt intact + mods section second; JSON `"amount": 50`
  (float 50.0) loads + builds; disabled/unknown mod_block ->
  graceful `FORGE_FAIL:`. Worker B's verifier also PASS. All prior
  suites green: verify_v062, verify_v06_llm, verify_v06_loadouts,
  verify_v06_mic, verify_v06_movement, verify_v051, verify_fixes +
  900-frame smoke green.
- **Known / not in this chunk**: `verify_v05_b2_forge_backend` has 1
  FAIL — CONFIRMED pre-existing stale expectation (expects
  `give_weapon("longeye")`, but v0.6.2's `FORGE_WEAPON_IDS` mapping
  correctly passes `"lr8"`; the weapon WAS given). Left as-is.
  GDScript has no try/catch: a mod that hard-crashes (infinite loop,
  stack overflow) cannot be contained — "install only mods you
  trust," same bar as GMod addons. Offline keyword parser doesn't
  know mod names (LLM path covers mods). `user://` script loading on
  the Android export is unverified on hardware — Colin is the QA.
  CHUNK 2 (LLM mod creation) is next, NOT in this build.
- **Integration fixes by coordinator**: stale comment in
  `mod_api.gd` (turret now reads the metas) corrected.

### Publish (coordinator)
- `version/code=19`, `version/name="0.7.0"` in export_presets.cfg;
  `Tuning.FALLBACK_VERSION_CODE` synced 18 -> 19.
- Signed debug APK `updates/forgefall-v0.7.0-debug.apk`
  (29,548,146 bytes) + `.idsig`, built with the unchanged custom
  template (no Gradle, no template rebuild — GDScript-only change).
  Godot's export signed via apksigner itself (build-tools 35.0.0).
- APK verified: apksigner verify OK; aapt badging ->
  `com.sparky.forgefall` versionCode 19 / versionName 0.7.0;
  manifest has UpdateStatusReceiver + ForgeUpdater + ForgeSpeech
  meta-data + RECORD_AUDIO + REQUEST_INSTALL_PACKAGES; classes2.dex =
  stock XRMode intact (1960 B), classes14.dex = ForgeUpdaterPlugin +
  UpdateStatusReceiver, classes15.dex = ForgeSpeechPlugin.
- Deployed (Netlify deploy `6aceacf40f04e627bb6a3757`,
  "forgefall v0.7.0 user mods"): index.html (v0.7.0) +
  version.json (code 19) + v0.1.11 + v0.5.0 + v0.5.1 + v0.5.2 +
  v0.6.0 + v0.6.1 + v0.6.2 + v0.7.0 — live page 200, live v0.7.0 APK
  206, live version.json reads code 19 (after ~45s CDN
  propagation), all older APKs 206. .idsig files not deployed.

## v0.8.0 — LLM MOD CREATION (chunk 2) (2026-10-13 ~22:40 MDT)

### Shipped (Workers A/B/C, coordinated — GDScript-only, template untouched)
- **LLM mod creation** (NEW `scripts/mods/mod_creator.gd` + generation section in
  `scripts/forge/forge_llm.gd`): "Create Mod" in the Mods tab — describe a mod
  idea, the LLM generates it as a JSON-block mod or a GDScript mod.
- **Generation template** (`GENERATION_SYSTEM_PROMPT`, stable prefix for cache):
  full ModAPI docs + ModBlock contract + manifest/block schemas + few-shot
  examples (one JSON-block mod, one GDScript mod). Output contract:
  `{"manifest","payload","summary"}`. LLM decides kind: data-only -> block,
  behaviour -> script. `GENERATION_MAX_TOKENS = 2000`, own
  `generation_ready` signal, own in-flight state — the Forge build prompt /
  `spec_ready` path untouched. Thinking disabled, deepseek-flash.
- **Validation before approval**: `ModLoader.validate_generated_mod()` (new,
  additive) — manifest-field whitelist + type checks; blocks via existing
  `_validate_block()`; scripts via existing `_scan_forbidden()` +
  `_extends_mod_block()` + get_block_info/apply presence checks. Invalid ->
  clean error, no install, offer Regenerate. Generation + validation alone
  never write to `user://mods/` (verified).
- **Human approval** (forge_menu.gd, Mods tab): CREATE MOD button -> idea
  input (FOCUS_CLICK) -> Generate -> approval panel: plain-language summary
  + name/ID/kind + key manifest stats + FULL payload in a scrollable
  read-only code area + Install / Discard / Regenerate. Install is the ONLY
  write path (`mod_creator.install()`): writes
  `user://mods/<mod_id>/manifest.json` + payload (`block.json` / `mod.gd`),
  rescans, verifies the installed record is error-free (bad install rolled
  back, folder removed). Discard drops the candidate. Close clears state.
- **Installed LLM-made mods are normal mods**: appear in the Mods tab and in
  the LLM catalog (`user_mods_section`), so Forge can compose with them in
  later requests. mod_id sanitized from the manifest name ([a-z0-9_]),
  collision-suffixed (`_2`, ...), block payload `block_id` normalized to it.
- **Verification** (Worker C, `tools/verify_v08_create.gd`): 74/74 PASS —
  valid block mod -> install -> in Mods + enabled + catalog + Forge builds
  from it; `OS.execute` script rejected at validation, install refuses,
  nothing written; generate+validate alone writes nothing; Discard drops;
  installed mod persists across rescan; Regenerate yields a distinct second
  candidate; full UI flow driven through real menu button presses.
  Worker A's `tools/verify_v08_a_creator.gd`: 110/110 PASS (prompt
  completeness, mock generation, collision, bad-block/forbidden-script
  rejection, no-key path). All prior suites green: verify_v07_mods 80/80,
  verify_v07_b_mods_turret, verify_v062, verify_v06_llm (see below),
  verify_v06_loadouts, verify_v06_mic 53/0, verify_v06_movement,
  verify_v051, verify_fixes + 900-frame smoke green (Forge 300->200, 17
  covers).
- **Coordinator integration fix**: verify_v06_llm's no-exec grep flagged
  literal forbidden tokens *mentioned* inside `GENERATION_SYSTEM_PROMPT`
  (a prompt string telling the LLM never to emit them — not executable
  code). Extended the checker to skip lines inside `"""..."""` prompt
  strings; verify_v06_llm green again. No game-code weakening.
- **Live DeepSeek test** (stored credential, generation prompt byte-exact
  from the game): "a railgun that fires explosive rounds" -> valid
  generation (Railgun Explosive, kind block, base longeye, damage 2.5x,
  range 2.0x, mag 0.5x, armor-piercing, cost 800) -> `validate()` clean.
  Model honestly noted explosive rounds aren't directly supported and gave
  the closest buildable weapon. First call with the new template: 0 cache
  hits (expected — cache builds on repeat identical-prefix calls).

### Publish — BLOCKED on Netlify credential (APK built + verified, NOT deployed)
- `version/code=20`, `version/name="0.8.0"` in export_presets.cfg;
  `Tuning.FALLBACK_VERSION_CODE` synced 19 -> 20.
- Signed debug APK `updates/forgefall-v0.8.0-debug.apk` (29,614,185 bytes)
  + `.idsig`, built with the unchanged custom template (no Gradle, no
  template rebuild — GDScript-only change). Godot's export signed via
  apksigner itself (build-tools 35.0.0).
- APK verified: apksigner verify OK; aapt badging ->
  `com.sparky.forgefall` versionCode 20 / versionName 0.8.0; manifest has
  UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data +
  RECORD_AUDIO + REQUEST_INSTALL_PACKAGES; classes2.dex = stock XRMode
  intact (1960 B), classes14.dex = ForgeUpdaterPlugin +
  UpdateStatusReceiver, classes15.dex = ForgeSpeechPlugin.
- DEPLOY FAILED: Netlify deploy-creation POST returns HTTP 403 Forbidden
  — twice via the one-shot zip flow, once via the file-digest flow (new
  `tools/netlify_digest_deploy.py`, written because the zip flow failed;
  it uploads only changed files — server would have needed just the new
  APK + index + version.json). GETs with the same stored credential
  SUCCEED (site read OK), so the token lost deploy/write scope (or was
  revoked/changed) since the v0.7.0 deploy — it is NOT a size, payload,
  or transient problem. Per the connector doc, the fix is
  `credentials.request_api_access` with `reconnect=true` for
  `custom.netlify` (provider `netlify`, `api.netlify.com`, api_key,
  bearer_header) — the parent agent must run it; the coordinator
  subagent has no credentials tools. Once reconnected, deploy with:
  `python3 tools/netlify_digest_deploy.py --site-id
  ce1d2f86-2b36-4e8d-af13-fc82a823554e --dir deploy_staging --title
  "forgefall v0.8.0 llm mod creation"` (staging dir already contains
  index.html + version.json (code 20) + v0.1.11 + v0.5.0–v0.8.0 APKs).
  Live site still serves v0.7.0 (code 19) until that deploy lands.
- **Known / not in this chunk**: GDScript has no try/catch: a mod that
  hard-crashes cannot be contained — "install only mods you trust."
  `user://` script loading on the Android export is unverified on
  hardware — Colin is the QA. `verify_v05_b2_forge_backend` 1 stale FAIL
  (pre-existing, expects give_weapon("longeye"), v0.6.2 mapping passes
  "lr8") left as-is.

## v0.8.0 — HOSTING MIGRATION: Netlify -> GitHub Pages (2026-10-14 ~06:20 MDT)

### Why
- Netlify deploy POSTs returned HTTP 403 on the stored token (GETs still
  worked). Colin's call: move update hosting to GitHub Pages (free).
  Netlify site left as-is serving v0.7.0; it is no longer the update host.

### What changed (code: ONE constant)
- `scripts/core/tuning.gd:201`: `Tuning.UPDATE_BASE_URL` =
  `https://vatherty.github.io/Forgefall-updates/` (was
  `https://forgefall-updates.netlify.app`). `FALLBACK_VERSION_CODE` already
  20. No gameplay changes.
- Rebuilt v0.8.0 APK (code 20 / 0.8.0, 29,614,352 bytes, SHA-256
  398607e5f854c2069a83027fa9db8086e722d0af895ddeaad6a5421cc156a510) via
  the exact v0.8.0 export flow (Godot 4.7.2 headless --export-debug
  "Android", custom template, apksigner). Verified: apksigner OK, aapt
  code 20 / 0.8.0, manifest UpdateStatusReceiver + ForgeUpdater +
  ForgeSpeech, classes2.dex stock (1960 B), classes14/15 present, runtime
  check prints the new UPDATE_BASE_URL, 900-frame smoke green.
- Note: the APK bundles inert `assets/deploy_staging/version.json` (old
  Netlify URL) and `assets/github_deploy_staging/version.json` (new URL)
  because the export includes all resources and the exclude filter does
  not cover staging dirs. Harmless (updater fetches version.json from
  the network, not bundled assets); consider adding staging dirs to
  `exclude_filter` in a future build.

### Deploy (GitHub Pages, repo `vatherty/Forgefall-updates`, public, main)
- All writes via `github.py` contents API (REST; never git CLI push).
  Uploaded all 11 files: `index.html` (relative links, unchanged),
  `version.json` (code 20, apk_url = Pages URL, changelog unchanged),
  + 9 APKs (v0.1.11, v0.5.0–v0.8.0). version.json + index.html uploaded
  LAST. Repo tree verified complete (11/11, none missing).
- Uploads were flaky: first batch 3/9 succeeded; the rest failed with
  transient GitHub 502 / 504 / 403-"rule did not run because of a
  timeout" / one 401. Retried one at a time with pauses — all eventually
  landed. (One exec service restart mid-retry aborted the batch; repo
  state re-checked before continuing — no partial uploads.)
- Verified via raw.githubusercontent.com: version.json reads code 20
  with the Pages apk_url; v0.8.0 APK range request 206.

### PENDING — Colin must enable Pages (PAT lacks Pages scope)
- `pages-enable` via API returns HTTP 403 "Resource not accessible by
  personal access token". The PAT has Contents scope but NOT Pages scope.
  `pages-get` still 404; `https://vatherty.github.io/Forgefall-updates/`
  returns 404 until Pages is on. ALL files are already in the repo, so
  the moment Pages is enabled the site is live with no further action.
- Colin: repo Settings -> Pages -> Build and deployment -> Source:
  Deploy from a branch, Branch: `main`, folder `/`, Save. (Alternative:
  re-issue the PAT with Pages write and the API enable works.)
- Colin's current on-phone build (v0.7.0) polls Netlify, so v0.8.0 needs
  ONE manual install from
  https://vatherty.github.io/Forgefall-updates/forgefall-v0.8.0-debug.apk
  (after Pages is enabled). After that the updater points at GitHub.

## v0.9.0 — Goal 1 FEEL: faster movement kit + sharper gunfeel (2026-10-14 ~23:43 MDT)

### Shipped (gameplay by the Goal 1 FEEL workers — this entry covers build + publish only)
- Movement retune (verify_feel contract): sprint 11.0, walk 6.0, slide
  friction 3.0 / end speed 2.0, wall-run 3.0 s / boost 1.25, grapple
  accel 75 / max speed 30 / reel 10. Deliberate trades, NOT regressions:
  SLIDE_MAX_TIME 3.0 -> 2.5, WALLRUN_MIN_SPEED 3.0 -> 4.0 (still far below
  sprint). 50 m cross-time 4.55 s (was 7.81 s baseline).
- Gunfeel: per-weapon recoil_recover + settle delay + viewmodel kick,
  hitmarker punch, damage-scaled flinch/knockback (deep suite:
  tools/verify_g1_gunfeel.gd; integration assertions in verify_feel).
- No gameplay changes in this entry — version bump + rebuild + publish.

### Version bump
- `export_presets.cfg`: `version/code=21`, `version/name="0.9.0"`.
  Windows preset `export_path` moved to
  `windows_staging/forgefall-v0.9.0-windows/forgefall.exe` (was the v0.8.0
  dir — avoids clobbering the v0.8.0 staging).
- `scripts/core/tuning.gd`: `FALLBACK_VERSION_CODE := 21`.
  `UPDATE_BASE_URL` unchanged
  (`https://vatherty.github.io/Forgefall-updates/`).

### Builds (all from the same current source)
- **Android** `updates/forgefall-v0.9.0-debug.apk` (29,681,035 bytes,
  SHA-256 `8e9a7bd842d5d85079e8fea98452c2f490837a5f92ef06c80b4b493a0567846a`)
  + `.idsig`. Godot 4.7.2 headless `--export-debug "Android"`, unchanged
  custom template (no Gradle, no template rebuild). Verified: apksigner
  OK (note: `java` is NOT on PATH in a fresh shell — apksigner needs
  `~/tools/jdk25/bin` or `~/tools/jdk-21.0.12.1+1/bin` on PATH first),
  aapt `com.sparky.forgefall` versionCode 21 / 0.9.0, manifest
  UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data +
  REQUEST_INSTALL_PACKAGES + RECORD_AUDIO, classes2.dex = stock XRMode
  (1960 B), classes14.dex = ForgeUpdaterPlugin + UpdateStatusReceiver,
  classes15.dex = ForgeSpeechPlugin.
- **Linux** `linux_staging/forgefall-v0.9.0-linux.zip` (28,836,195 bytes,
  SHA-256 `0e7e7570f76b1de7de7080bfbad9dfc5afd841b7e9c3269a52f1fa084f063289`):
  binary + forgefall.pck + README-LINUX.txt (version strings 0.8.0 ->
  0.9.0). Sanity run: shipped binary headless `--quit-after 900`, exit 0,
  0 errors. Linux PCK itself re-verified: verify_feel via editor binary
  `--main-pack builds/forgefall.pck` -> ALL CHECKS PASSED.
- **Windows** `windows_staging/forgefall-v0.9.0-windows.zip`
  (35,764,232 bytes, SHA-256
  `8c157d08f49c262b6923728222ed54ea6538a3ce3bbfa52058300d4525c1ef03`):
  forgefall.exe + forgefall.console.exe + forgefall.pck +
  README-WINDOWS.txt (0.8.0 -> 0.9.0). Rebuilt from CURRENT source
  regardless of any concurrent Windows-port publish (this zip carries
  the Feel changes). Packaged 2026-10-14 23:41:52 MDT (05:41:52 UTC).
  Windows PCK verified functionally, NOT by plain-text grep: the editor
  binary ran verify_feel with `--main-pack` pointed at the WINDOWS
  PCK -> 68 passed, 0 failed, ALL CHECKS PASSED (steady sprint 11.00,
  50 m cross 4.55 s). Note: export-template binaries reject `--path`
  ("compiled without support for path overrides") — use the editor
  binary + `--main-pack` for PCK-targeted runs; a standalone
  binary + `--script` silently ignores the script and hangs.

### Verification (post-integration, source)
- verify_feel: 68 passed, 0 failed, ALL CHECKS PASSED.
- verify_fixes: ALL CHECKS PASSED.
- verify_v06_movement: ALL CHECKS PASSED.
- 900-frame smoke: survived, exit 0 (one benign test-script artifact:
  `InputMap action "" doesn't exist` from smoke_test.gd:21 itself, not
  game code).

### Publish (GitHub Pages, repo `vatherty/Forgefall-updates`)
- Uploaded via `github.py` contents API (REST; never git CLI push):
  v0.9.0 APK + Linux zip + Windows zip, then version.json + index.html
  LAST (code 21, apk_url = Pages URL for the v0.9.0 APK, changelog
  "Feel: faster movement kit + sharper gunfeel"). index.html: three
  v0.9.0 download links + a "Previous version: v0.8.0" line; all older
  file URLs untouched. Published 2026-10-14 23:43:26 MDT.
- **Pages build failure + fix (anti-drag)**: all five push-triggered
  Pages builds errored ("Page build failed", duration 0) and the live
  site kept serving code 20. Root cause: the legacy Jekyll build
  chokes on this repo's tree. Fix: uploaded an empty `.nojekyll` to
  the repo root — Pages now serves the tree statically (this site is
  plain HTML + static downloads; no Jekyll features used). Next build
  status `built`; live site flipped to code 21. FUTURE DEPLOYS: keep
  `.nojekyll` in the repo; never delete it (deleting it re-enables
  Jekyll and will break deploys again).
- Repo tree now 17 files: .nojekyll + index.html + version.json +
  v0.9.0 trio + v0.8.0 trio + v0.1.11 + v0.5.0–v0.7.0 APKs.
- Live verified: version.json 200 (code 21, Pages apk_url, Feel
  changelog); v0.9.0 APK + Linux zip + Windows zip each 206; older
  APKs (v0.8.0 trio, v0.7.0, v0.6.2, v0.5.0, v0.1.11) all 206;
  index.html 200 with the three v0.9.0 links. NOTE: v0.1.10-debug.apk
  404s — PRE-EXISTING, not a regression: it was never uploaded to the
  GitHub repo (migration uploaded v0.1.11 + v0.5.0–v0.8.0 only); the
  file still exists locally in `updates/`.
- Local `updates/` mirror synced (new index.html + version.json).

### Deferred
- Nothing deferred. All three artifacts + publish + live verification
  complete.


## Momentum hotfix (post-v0.9.0, Colin playtest) — 2026-10-14 ~23:58 MDT
Colin: "when you jump it stops your momentum. And stops your sprinting it
should continue running. Also holding crouch while landing should keep
speed." All three fixed in `scripts/player/player.gd` ONLY (no version
bump, no rebuild — the running Sound build picks this up in its rebuild).
- Jump killed momentum: airborne steering used `move_toward` toward a
  WALK-speed target (sprint flag died in air). Air now accelerates ALONG
  the wish direction, capped at max(current speed, wish speed); no
  input = no change. Momentum preserved unless the player brakes/turns.
- Jump killed sprint: `_update_sprint` required `is_on_floor()`. Floor
  requirement removed — sprint persists across jump + airtime and
  resumes immediately on landing with sprint still held.
- Crouch-land braked: slide only started on a crouch TAP while grounded.
  `_update_landing` now enters a slide when landing with crouch held at
  >= SLIDE_MIN_SPEED, landing velocity preserved. Low-speed crouch-land
  = normal crouch (no slide).
- Slide-hop: removed the `*= 0.8` horizontal brake (20% instant loss).
- Extra catch from verification: the jump tick still took the ground
  branch (`is_on_floor()` stale-true pre-`move_and_slide`), costing
  exactly 1.0 m/s on slide-hop. New `_just_jumped` flag (set in all
  three jump paths, cleared at end of `_physics_process`) routes the
  jump tick through the air branch.
- Deliberately untouched: ALL `Sfx.*` lines (audio owned by the Sound
  worker — the landing-slide entry plays no whoosh; the whoosh stays on
  the grounded tap path only). Wall-kick velocity replacement untouched
  (by design).
- Verification: verify_feel extended with 5 momentum phases — 77/77
  PASS (was 68/68; new: jump keeps 11.00/11.00 at apex, sprint persists
  + 11.00 on landing, crouch-land slide 10.40 >= 80% of 11.00 after
  0.2 s, low-speed crouch-land = crouch, slide-hop 10.95/10.95).
  verify_fixes ALL PASS, verify_v06_movement ALL PASS, 900-frame smoke
  survived clean.

## v0.9.x — Goal 3 CONTENT, Worker C: Modes + weapons (2026-10-15 ~00:25 MDT)

### Modes (new: scripts/core/game_mode.gd, class GameModeManager)
- SURVIVAL: the shipped wave mode, unchanged (no respawn, KIA behaviour kept).
- DOMINATION (objectives): capture/hold 3 points A/B/C. Uncontested player
  presence captures in ~2.9 s (0.35/s); enemies inside the point CONTEST it
  (no capture, no tick) but never steal an owned point. Each held point
  ticks +1 score/sec through Game.add_score (HUD topbar shows it). First to
  200 wins -> mode_won, waves stopped. Death respawns the player after 3 s
  at a random player_spawn marker (Domination only) so matches stay playable.
  Point placement is map-agnostic: derived from the map's own player_spawn
  markers (centre + extent), falling back to hand-tuned Dustline coords.
  Points are visible translucent cylinders (grey neutral / orange owned /
  red contested), group "objective_point".
- ENDLESS (score chase): waves never cap; each cleared wave pays an
  escalating bonus (100 x wave number) on top of kill score. Death ends the
  run; the run score is compared against the persisted best in
  user://endless_best.json {best_score, best_wave} (saved on every wave
  clear too, crash-safe; menu shows it when Endless is picked).
- Selection: main menu MODE picker (Survival / Domination / Endless) +
  description + endless-best label; persists to forge_settings.cfg
  ("game"/"mode"). Main._wire_modes() adds the manager after waves and
  calls start(selected_mode); start() also resets the run (score/wave/
  budget). Merged with the maps worker's concurrent MAP picker edit in
  main_menu.gd (no clobber; _save_settings made null-safe for early saves).

### Weapons (Arsenal + WeaponBase BURST + loadouts)
- BR-3 TRIDENT (br3, primary): 3-round BURST rifle — new FireMode.BURST in
  weapon_base.gd (press queues a burst; rounds fire as the RPM cooldown
  clears; mid-burst re-press does NOT restart/extend). 900 rpm intra-burst,
  26 dmg (78/burst), 30/120, spread_hip 0.022, near 25 / far 80, recover
  0.20, flash 0.04/4.0. Precision mid-range role; sustained DPS below AR-7.
- HV-44 JUDGE (hv44, primary): heavy revolver, SEMI, 150 rpm, 65 dmg,
  6/36, spread_hip 0.018, near 25 / far 90, recover 0.50, flash 0.06/6.0,
  0.15 s cylinder lockout, 2.10 s reload. High-alpha finisher role.
- Both: voxel viewmodels (Trident: long barrel + 3 orange burst pips +
  raised red dot; Judge: fat cylinder + vent rib + wood grip + tall blade),
  Muzzle/Eject/Sight anchors, ADS sight heights (0.092 / 0.062), per-weapon
  reload sounds. New loadout "Burst" (br3 + hv44) in WeaponManager.LOADOUTS
  and the Forge menu's LOADOUT_PRESETS.
- Sounds (Sound-goal generator patterns): shot_burst, shot_revolver,
  reload_burst, reload_revolver in tools/gen_audio.py + 4 WAVs in
  assets/audio/ (unique .import UIDs); registered in Sfx SOUND_IDS / MIX_DB
  (burst -1 dB, revolver -2 dB) + shot_br3/shot_hv44 aliases. Existing 7
  weapons' damage/RPM/ADS untouched (verified).

### Verification (verify script kept in /tmp per scope — NOT tools/)
- /tmp/verify_g3_modes_weapons.gd: 51 checks, 0 failures (both modes
  start/capture/score/win/end, best persists; both weapons fire/ADS/reload;
  existing stats untouched; menu picker sets the mode).
- /tmp/verify_g3_integration.gd: real main scene + DEPLOY via the menu with
  Domination -> 3 objective points, 1 wave manager, 1 player. PASS.
- Regressions: verify_feel ALL PASS, verify_g1_gunfeel 39/39,
  verify_fixes ALL PASS, verify_v06_loadouts ALL PASS, verify_sound 693
  passed (0 failed), 900-frame smoke green. check_scripts: 4 failures, all
  pre-existing android/build/ test scaffolding, none in game code.

### Deferred / follow-ups (for the coordinator)
- Forge ordering for the new guns is NOT wired: forge_builder.gd /
  forge_llm.gd still list only the old 7 weapon ids (forge-owned files) —
  "give me a burst rifle" via Forge/LLM will refuse until the Forge worker
  adds trident/judge aliases. Arsenal + loadouts work today.
- Domination on Foundry/Outpost is placement-derived, not hand-tuned per
  map — worth a playtest pass by the maps worker (points could sit on
  cover/rooftops on those maps).
- Forge weapon cost stays flat 200 for all weapons (forge-owned); the new
  guns are balanced via stats/ammo economy instead.

## v0.9.x — Goal 5 PORTALS, Worker D: Verification (2026-10-15 ~01:30 MDT)

### Suite (new: tools/verify_portals.gd, discovery-based, no gameplay edits)
- A. SEE-THROUGH: SubViewport + ViewportTexture + portal camera structure, RT
  non-black (WARN headless: no GPU, pixel read unavailable), virtual-camera
  geometry (position = pure pair rotation, orientation = mirror flip), partner
  tracking, fallback (partner gone -> RT off, shimmer visible, never black).
- B. MOMENTUM: Portal 2 ejection contract — exit velocity along +exit normal
  at entry speed (position = flipped offset clamped to the standoff:
  1.35 char / 0.6 rigid), cooldown ping-pong block, both-discs-active rule.
  NOTE: position maps with the pure rotation; velocity/direction maps with
  the mirror flip. Asserting rot*v alone would encode the old bug.
- C. PUZZLES: chambers discovered from disk + CompletionStore.ROOMS catalogue
  (never invented names); each loads, solves via its real solve() path,
  requires portals, resets. Missing catalogued scripts FAIL explicitly.
- D. PLACEMENT: is_surface_portalable() + fire() refusal on non-portal-able
  walls and enemies. Staged across frames: refusal shot first on a cold
  0.15 s debounce, then portal-able + enemy shots after debounce/physics
  sync (a rapid second shot would otherwise be debounce-masked).
- E. INTEGRATION: compile gate for portal_disc/emitter, player.tscn wiring,
  portal actions, SFX ids, voxel style, disc pooling (exactly 2).
- Result vs the final tree: 61 passed, 1 failed, 2 warnings.

### ONE FAILURE left for the coordinator (Worker A)
- portal_disc.gd _refresh_rt_camera(): the virtual camera uses the PURE pair
  transform (partner * self^-1 * camera), so it looks INTO the exit portal
  (forward (0,0,1)) instead of OUT of it (want (0,0,-1)). Player looking
  into blue would see the back of the orange portal / wall, not the room
  beyond orange. Fix: position = pure transform; orientation = partner *
  FlipY(180°) * self^-1 * camera orientation (same flip Worker C applied to
  teleport velocity). Up stays +Y under FlipY. Suite check:
  "virtual camera looks OUT of the partner portal".
- Fixed during this run (no action needed): Worker A's CircleMesh parse error
  (Godot 4 has no CircleMesh) briefly broke ALL portals; replaced with a
  SurfaceTool triangle-fan circle mesh. Worker C's emitter + Worker B's
  chambers 03/04 also landed mid-run; the suite judged the final tree.

### Regressions (final tree)
- PASS: verify_fixes, verify_v06_movement, verify_feel (83/83),
  verify_sound (697/697, 8 warnings), verify_content (495/495, 1 warning),
  verify_multiplayer (180/180, 7 needs-device), verify_linux, verify_windows
  (48/48). Smoke: 900 frames clean, exit 0.
- verify_updater_pc: 4 FAILs, PRE-EXISTING / NOT Goal 5 — the suite hardcodes
  v0.9.2/code 23 expectations (tools/verify_updater_pc.gd ~L188) but the
  shipped updates/version_pc.json is v0.9.3/code 24 (Goal 4). No Goal 5
  worker touched the updater or the manifest.

### Headless limits (not faked as passes)
- RT pixel non-black + on-device look/feel are Colin's verdict — headless
  proves the RT structure + camera math, not that it looks right.
- True player walk-throughs of chambers are scripted-solver equivalents.

## 2026-10-15 — Goal 5 Worker B: PORTAL PUZZLE ROOMS (PUZZLE mode) — SHIPPED
- 4 hand-designed chambers, code-built (no .tscn) under scripts/puzzles/:
  room_base.gd (shared mechanics), chamber_01_first_steps.gd (portal pair
  through a divider window — teaches place-a-pair + walk through),
  chamber_02_heavy_lifting.gd (block + plate + door; door only stays open
  while a block holds the plate), chamber_03_fling.gd (momentum fling:
  floor portal + ledge-edge portal, fall 11.9 m -> 15.3 m/s exit +X,
  analytic landing x=8.96 on the goal platform x 6..12),
  chamber_04_gauntlet.gd (all three in sequence).
- Visual language: WHITE panels = portal-able (own StaticBody3D, group
  "portalable"); everything else dark/rust, group "non_portalable" +
  meta portalable=false, for the emitter validity check (Worker C).
- Progression: CompletionStore (user://puzzle_progress.cfg) persists
  completion; room-select screen lists 4 rooms with ✓ ticks.
- Reachable: main menu "PUZZLE CHAMBERS" -> select screen -> Main.
  start_puzzle(id) (no waves/modes/enemies). Minimal edits to
  scripts/ui/main_menu.gd + scripts/core/main.gd, marked "Goal 5 Worker B".
- Momentum requirement (Worker C): try_teleport must eject along +exit
  normal at entry speed (Worker D M1/M2 contract). Current rotate-velocity
  code sends the body back into the exit surface; fling rooms assume the
  fix. Noted in room_base.gd + chamber_03/04 headers.
- Verify: tools/verify_portals_puzzles.gd — 112/112 PASS (structure,
  visual language, solve->complete->persist->reset, plate/door, fling
  trajectory). Real-physics probes: player-on-plate opens door, off
  closes; RigidBody cube dropped on plate opens door; player in exit
  completes. End-to-end probe: Main boots -> select opens ->
  start_puzzle loads room + 1 player -> quit_to_menu returns to menu.
  Caveats: true player walk-throughs are scripted-solver equivalents
  (headless limit); fling rooms need Worker C's ejection fix before a
  live player can fling; cubes use can_sleep=false (teleport-while-asleep
  would hang them mid-air). No version bump / no publish (coordinator).

### Goal 5 — Worker C: Portal gameplay polish (2026-10-15)
- `scripts/player/portal_emitter.gd` only (plus new `tools/verify_portals_gameplay.gd`).
- MOMENTUM (bug fix, was broken): old teleport used `B * A^-1` — exit
  velocity pointed INTO the exit wall and the player body tilted (player.gd
  never re-uprights, so wish zeroed / look rolled after any fling). Now
  `R = B * FlipY(180) * A^-1`: "into A" -> "out of B", speed preserved
  exactly. Characters stay UPRIGHT (yaw-only, mapped facing projected to
  horizontal, fallbacks: exit-disc up, exit normal); RigidBody3D keeps full
  flipped rotation. Position maps through R then clamps to a standoff in
  front of the exit computed from the body's real collision shapes
  (player capsule: floor ~0.5, ceiling 2.2, wall 0.5). Backside guard:
  body behind entry plane + not moving inward never teleports; fast
  tunnelled bodies still teleport.
- PLACEMENT: `is_surface_portalable()` — StaticBody3D yes, dynamic bodies
  no; group `no_portal`/meta `portalable=false` opts out, group
  `portalable`/meta `true` opts in. Failed placements never move the disc.
- FEEDBACK: per-frame aim raycast + ghost disc (green placeable / red
  rejects / amber out-of-range / hidden no target); `get_aim_state()` +
  `aim_state_changed` for the HUD crosshair (aim, pair_active, blue/orange
  active, cooldown_remaining, distance/hit/portalable). `get_aim_state()`
  evaluates fresh so readers never see a one-frame-stale verdict.
  `set_aim_feedback_enabled()` for Forge/pause; `clear_portals()` for
  puzzle resets. 0.15s debounce on successful fires only (no accidental
  double-placement); 0.5s anti-ping-pong teleport cooldown unchanged.
- VERIFY: `tools/verify_portals_gameplay.gd` 36/36 PASS (momentum 4
  orientations + tangential, upright/facing, standoff floor/ceiling,
  backside guard, rigid rotation, placement valid/invalid/out-of-range/
  no-target, debounce incl. cross-color, pair + clear). Regressions:
  verify_feel 83/83, verify_v06_movement ALL PASS.
- FOR COORDINATOR / HUD WORKER: hud.gd still needs the one-line wiring to
  read `get_aim_state()` / `aim_state_changed` for crosshair tint + pair
  pips (emitter side done; hud.gd is outside this worker's ownership).
  Known limits: no exit-area blockage check (body overlapping a crate at
  the exit gets physics push-out); portals on moving StaticBody3D do not
  follow the platform.

## Main-menu layout fix (Deck screenshot: tagline/MAP + footer/LOADOUT overlaps)
- ROOT CAUSE: the centered buttons box had a fixed 300px anchor rect but
  ~590px of content, so it overflowed into the tagline above and the footer
  below; on short/windowed screens the footer ("…Colin's playtest build")
  landed on top of the LOADOUT button ("LOADOUT — COMING SOON"), producing
  the three-way garble. The LOADOUT button itself also said two things at
  once ("LOADOUT" + "COMING SOON").
- FIX (scripts/ui/main_menu.gd only): ONE vertical flow — a VBoxContainer
  inside a ScrollContainer. No fixed overlapping offsets; every row gets
  its own band. _layout_stack() (also on resize) sizes the stack to at
  least the viewport so EXPAND spacers center the menu + pin the footer;
  taller content scrolls instead of colliding. Title font + button height
  scale with viewport (title 48–110px, buttons 54/64px). Options panel is
  viewport-sized + scrollable. Menu buttons get SHRINK_CENTER (were
  stretching full-width). Portals worker's PUZZLE CHAMBERS button preserved.
- BOTTOM BUTTON: exactly one label — "COMING SOON", disabled, tooltip
  "Loadouts live in-game — open Forge and pick the Loadouts tab." Loadouts
  are live in Forge; there is no loadout picker on the main menu, so the
  button is genuinely not ready. Footer text is now version-free
  ("FORGEFALL — Colin's playtest build") — the old "v0.1 scaffold" went stale.
- VERIFY: tools/verify_menu_layout.gd 875/875 PASS — 1280x800 (Deck),
  1920x1080, 1080x2400, 720x1600 + resize path + options-open at each
  size: no text-control overlaps, tagline/MAP/MODE separated, button
  labels unique, all buttons + footer inside viewport, COMING SOON once,
  no LOADOUT label. Regressions: verify_fixes ALL PASS, 900-frame smoke
  clean (exit 0; the TLS + InputMap "" errors are the known pre-existing
  sandbox items, not this change).

## v0.9.x — Goal 5 PORTALS, Worker A: see-through rendering (2026-10-15 ~01:19 MDT)

Portal discs now show a LIVE view through the paired portal
(`scripts/player/portal_disc.gd` ONLY — emitter/teleport untouched,
Worker C's file; no version bump, no publish, no platform rebuild).

### Implementation
- Each disc owns a SubViewport + virtual Camera3D + a flat circular RT
  surface (SurfaceTool triangle fan, UVs [0,1]; Godot 4 has no CircleMesh)
  sitting 5 mm in front of the shimmer core, facing -Z (outward). The
  surface is NOT under the shimmer `Visuals` root, so the spin/pulse never
  rotates the live view. Single-bounce only: the RT is a plain
  ViewportTexture, never a recursive viewport-in-viewport render.
- Virtual camera (Portal 2 geometry, per D's contract): POSITION maps with
  the pure pair rotation (`partner * self^-1 * cam` — sits the same
  distance in front of the partner portal as the main camera sits in front
  of this disc); ORIENTATION maps with the mirror flip (RotY 180, applied
  in camera-local space AFTER cam so it rotates the view but leaves the
  position alone). The flip is a proper rotation (det +1): the view turns
  around to look OUT of the partner portal, never mirrored, up stays
  upright. First cut omitted the flip (camera stared into the exit wall);
  D's suite caught it (`forward (0,0,1)`, want `(0,0,-1)`) — fixed.
- Camera tracking is ungated (transform follows the pair even when the RT
  can't render); surface visibility + render requests are the gated parts.
  Updates run in `_process` AND synchronously-ish via
  `NOTIFICATION_TRANSFORM_CHANGED` (`set_notify_transform(true)`) so a
  partner move re-aims both discs' cameras at the earliest engine moment.
  View source: viewport's current camera, falling back to any non-portal
  Camera3D in the tree when none is current (test rigs do this; in-game
  the player camera is always current).

### Perf (the constraint)
- RT size by PerfScaler tier: HIGH 256 / MED 192 / LOW 128 (cached tier,
  `refresh_quality()` to re-resolve; `force_rt_size` override for tests).
- Per-tier re-render throttling: HIGH every frame / MED every 2nd /
  LOW every 3rd (`UPDATE_ONCE` on render frames, `DISABLED` otherwise).
- Facing cull (camera must look toward the disc) + 30 m distance cull —
  off-screen/behind discs freeze their RT.
- SubViewport shares the main world (`own_world_3d = false`), audio
  listeners off, RT camera `current` for its viewport only.

### Fallback (never a black face)
- RT surface hides + shimmer shows whenever: partner missing/inactive, no
  camera anywhere, camera facing away / too far, dummy renderer
  (`--headless` → adapter name empty → RT unavailable from `_ready`),
  `force_seethrough_off`, or `set_see_through_enabled(false)` (public
  fallback switch, probed by D's suite). Single portal (no partner) =
  shimmer, no crash.

### Verification
- `tools/verify_portals_seethrough.gd` (NEW — D owns `verify_portals.gd`,
  so A's checks live here to avoid clobbering): 28/28 PASS headless AND
  under xvfb+llvmpipe (RT image 82% bright with the flipped camera
  looking at an outward wall — live view, not black). Covers: RT objects +
  texture wiring, UV span, flip math (position/forward/up), partner-move
  tracking, all fallback paths, tier/override sizing, no-current-camera
  fallback, single portal.
- Worker D's `tools/verify_portals.gd`: see_through 17/17 PASS (incl. the
  flip forward/up checks, tracking, fallback). Full D run also green:
  integration 9/9, placement 5/5, momentum 15/15, puzzles 16/16
  (B/C already landed). NOTE: one D run hung in its own chamber stage
  (line ~802, RefCounted→Node assignment, 18k repeated errors, never
  advancing) — D's file, not touched; the later run completed clean, so
  it looks like a race with a concurrent landing, not a stable failure.
- 900-frame smoke: survived clean, exit 0, no script errors.
- `check_scripts`: 130 checked, 4 failed — all pre-existing
  `android/build/` scaffolding, none in game code.

### Caveats / for Colin's on-device verdict
- Texture orientation (vertical flip) can't be proven headless — the
  ViewportTexture is applied unflipped, which is the standard mapping,
  but confirm on device that the view through a portal isn't upside-down.
- On-device perf of 2 extra scene renders (even at 256 + throttling) is
  still Colin-QA; if phones chug, the dials are `RT_SIZE_*` /
  `RT_EVERY_*` / `RT_MAX_VIEW_DIST` in `portal_disc.gd`, or
  `set_see_through_enabled(false)` as a kill switch.
- Two deferred-note items: transform notifications are engine-deferred
  (next frame), so a same-call move-then-read of the virtual camera sees
  the pre-move pose — frame-based polling, not a bug; and the RT shows
  last frame's texture when a portal is viewed through its partner
  (single-bounce, by design).

### Follow-up fix (same session): mirror-flip placement in _refresh_rt_camera
D's follow-up caught a real bug in the first flip fix: the flip had been
applied in camera-local space AFTER cam (`partner * self^-1 * cam * Flip`).
That agrees with the correct formula for a LEVEL camera, but it NEGATES
pitch — a camera looking DOWN into the entry portal rendered a view
looking UP out of the exit portal. Correct placement, matching Worker C's
teleport split (position pure, direction flipped): position =
`partner * self^-1 * cam` (pure); orientation =
`partner * FlipY(180) * self^-1 * cam` (flip between partner and self^-1).
The flip (proper rotation, det +1) flips X/Z and keeps Y, so pitch is
preserved. The stale "No extra flip" / camera-local comment was replaced
with the correct explanation. Regression added to
`tools/verify_portals_seethrough.gd`: pitched camera (2 m above the disc,
looking down at it) must yield virtual forward ~(0,-0.37,-0.93) — DOWN out
of the partner — and pure position (10,3.5,-5). Re-verified: my suite
31/31 headless AND xvfb (was 28/28), D's suite see_through 17/17 with all
sections green, 900-frame smoke clean (exit 0, 0 script errors).

## v0.5.0 — RENUMBER from 0.9.5 (open-source release) — 2026-10-15 ~16:30 MDT

### Why
- The game is earlier than the old 0.9.5 numbering implied. Renumbered to
  0.5.0. Gameplay is byte-identical to the former 0.9.5 — version strings
  only. `version_code` stays 26 so in-game updaters keep working.
- Worker A amended the version strings (export_presets.cfg: version/name
  0.5.0, version/code 26; Windows export_path ->
  windows_staging/forgefall-v0.5.0-windows/) and published the clean source
  tree to `vatherty/FORGEFALL`. Worker B rebuilt + released + decluttered
  (this entry). Build from the WORKING tree, not the public repo: the public
  copy has blanked keystore passwords; the working source keeps the real
  (public-default) value so signing still works.

### FILENAME COLLISION — old code-13 v0.5.0 replaced (deliberate)
- A legacy `forgefall-v0.5.0-debug.apk` (version_code 13, Oct 13 milestone,
  SHA-256 `63728576…7cca23`, 29,381,965 bytes) already existed in `updates/`
  and in the Pages repo archive. Reusing the v0.5.0 filename for the code-26
  build is the right call (matches the renumber), but the old file was
  REPLACED, not duplicated: the new build overwrote `updates/` copy and the
  Pages-repo copy in place (same URL now serves the new build), and the
  stale code-13 copies in `deploy_staging/` and `github_deploy_staging/`
  were deleted. No two different builds share the v0.5.0 filename anywhere.

### Builds (all from the amended working source, Godot 4.7.2 headless)
- **Android** `updates/forgefall-v0.5.0-debug.apk` (30,603,146 bytes, SHA-256
  `f35cd72093695f65b73851539658debd1fb1a78c20c337e28bc61eff621dba19`) +
  `.idsig`. `--export-debug "Android"`, unchanged custom template.
  Verified: aapt com.sparky.forgefall versionCode 26 / 0.5.0, apksigner v2+v3
  true, manifest UpdateStatusReceiver + ForgeUpdater + ForgeSpeech meta-data
  + REQUEST_INSTALL_PACKAGES + RECORD_AUDIO, classes2.dex = stock XRMode
  (1960 B, never overwritten), classes14/15 present.
- **Linux** `linux_staging/forgefall-v0.5.0-linux.zip` (29,709,263 bytes,
  SHA-256 `d7674bed2a48130a9301ea013adac95b760b35e53385bdaf63c5e7ec93eaedd0`):
  forgefall.x86_64 + forgefall.pck + forgefall.sh + README-LINUX.txt (0.5.0,
  + renumber note). Shipped binary headless --quit-after 900, exit 0.
- **Windows** `windows_staging/forgefall-v0.5.0-windows.zip` (36,636,512 bytes,
  SHA-256 `07fb119687f2bcdd3d670f6ea30ba795a3d56c10ef686c3d635f8b5256320632`):
  forgefall.exe + forgefall.console.exe + forgefall.pck + README-WINDOWS.txt
  (0.5.0, + renumber note).
- PCK strings: no 0.9.5 anywhere (version lives in the export manifest /
  updater manifests, not game strings).

### GitHub Release (repo `vatherty/FORGEFALL`)
- Release **v0.5.0**, tag v0.5.0 on main:
  https://github.com/vatherty/FORGEFALL/releases/tag/v0.5.0
  Changelog: the v0.9.5 changelog retitled 0.5.0 + the renumber line.
- **BLOCKER — assets NOT attached:** the registered GitHub credential is
  scoped to api.github.com only; release-asset upload goes to
  uploads.github.com and returns 401 Bad credentials (surrogate not swapped
  for that host). Fallback applied: the release body links the three
  downloads directly from the Pages update site (same files the in-game
  updater serves). To attach assets properly, reconnect/extend the GitHub
  credential to include uploads.github.com, or attach the three files in the
  GitHub UI. Release page currently lists 0 attached assets.
- Repo description still reads "FORGEFALL update hosting..." (wrong — that
  describes the updates repo). github.py has no repo-update command; Colin
  to fix in the GitHub UI.

### Pages declutter (repo `vatherty/Forgefall-updates`)
- Uploaded artifacts first, manifests + index last. version.json +
  version_pc.json -> version_name 0.5.0, version_code 26, URLs to the new
  v0.5.0 files. index.html rewritten: LATEST 0.5.0 prominent, three
  downloads, link to https://github.com/vatherty/FORGEFALL/releases for
  history, old-version list REMOVED (old artifact files stay in the repo as
  archive, unlisted). Deleted the v0.9.5-named duplicates
  (forgefall-v0.9.5-debug.apk / -linux.zip / -windows.zip — same build, new
  name). `.nojekyll` kept at repo root. Pages status: `built`.
- Local `updates/` mirror synced (new index.html + version.json +
  version_pc.json + APK).
- Live verified: version.json 200 (0.5.0/code 26); version_pc.json 200
  (0.5.0/code 26, both platform URLs); all three v0.5.0 artifacts 206;
  index.html 200 with 0.5.0 + Releases link, no old-version list; v0.9.5
  trio 404; repo tree has zero 0.9.5-named files, .nojekyll present;
  downloaded APK SHA-256 matches the local build hash.

## Forge batch — item 9: VOICE FORGING V2 (Worker E) — 2026-10-15 ~13:55 MDT

### What
Two improvements to the MIC / ForgeSpeech voice path, same plugin, same
permission flow, no engine change:
(a) CONFIRMATION before acting: a recognized transcript NEVER reaches the
listen() callback (and therefore never reaches Forge) until the player
confirms it. The transcript lands in a CONFIRMING state with a modal
prompt — the heard text plus CONFIRM / RETRY / CANCEL and a TYPE INSTEAD
button. CONFIRM delivers, RETRY re-listens, CANCEL discards, TYPE INSTEAD
discards + opens the typed fallback. Matters more now that budget is off:
a misheard prompt could otherwise spam structures with no cost gate.
(b) SMOOTHER PUSH-TO-TALK: state machine IDLE -> PERMISSION_PENDING ->
LISTENING -> CONFIRMING -> IDLE. Listening banner shows a live countdown
to the visible 12s timeout. Tap MIC again while LISTENING cancels.
end_ptt() on button release arms the confirm step — nothing is sent on
release; the transcript still waits for CONFIRM. Every exit (confirm /
retry / cancel / error / timeout / permission denial) returns to IDLE;
no stuck-listening state. Typed fallback one tap away in every state:
listening banner says "tap MIC again to cancel" (then type), CONFIRMING
has TYPE INSTEAD, the Forge menu always shows its prompt field, and the
error path still auto-opens the typed console (v0.5.1 floor).

### Files (Worker E only — forge_menu.gd untouched, no backend/parser/
### history/budget/placement/net/mod-creator/verification-tool changes)
- `scripts/android/speech_input.gd` (rewritten, same public contract):
  State enum + `state_changed` signal + `get_state_name()` /
  `is_listening_session()` / `is_confirm_open()` / `listening_time_left()`;
  `listen()` now sessions + tap-again-to-cancel while LISTENING, ignored
  while CONFIRMING/PERMISSION_PENDING; new `end_ptt()`, `cancel_session()`,
  `confirm_pending()`, `retry_pending()`, `cancel_pending()`,
  `type_instead_pending()`; `_on_plugin_result` session path (gated) +
  legacy direct-injection path preserved (callback set with no session
  still forwards directly — keeps the v0.6.0 verifier green);
  `_session_active` stale guard (late onResult after cancel/timeout is
  a no-op); `_on_listen_timeout()` + `_process` countdown;
  confirm/listening overlays as plain Controls under this node (no
  CanvasLayer), so hiding the Forge menu / touch layer hides them too;
  confirm overlay is modal (full-screen STOP dim), listening banner is
  visual-only (mouse_filter IGNORE) so touches keep reaching the game
  while holding MIC. Test seam: `test_start_session()` /
  `simulate_transcript()` / `simulate_error()` / `simulate_timeout()`
  (production never calls these; they drive the real handlers).
- `scripts/android/touch_controls.gd` (voice handling only, 3 spots):
  `_input()` gates manual dispatch while the voice confirm prompt is
  open (`_voice_confirm_open()` -> `is_confirm_open()`), or taps on
  CONFIRM/RETRY/CANCEL would also fire game buttons underneath (the
  manual dispatcher does not respect Control mouse_filter); MIC release
  calls `end_ptt()`; `_on_voice_text` comment notes the text is
  CONFIRMED. The `_speech.listen(_on_voice_text)` call is unchanged.
- No plugin change: ForgeSpeech still exposes startListening() +
  onResult() only; the plugin Java + AARs are untouched.

### Verification (headless, Godot 4.7.2)
- Scratch verifier `/tmp/verify_voice_v2.gd` (kept out of tools/ —
  Worker F owns verification tools): 55/55 PASS. Covers: transcript
  held in CONFIRMING with zero callback before CONFIRM; CONFIRM
  delivers exactly once; RETRY re-listens; CANCEL / cancel_session /
  TYPE INSTEAD discard with no delivery; error -> IDLE + toast +
  console; timeout -> IDLE + "timed out" toast + no delivery;
  _process past 12s expires; late results after cancel/timeout
  ignored; release sends nothing, transcript still needs CONFIRM;
  listen() while LISTENING cancels, while CONFIRMING ignored;
  terminal actions from IDLE are safe no-ops; legacy direct-injection
  path still forwards; touch wiring strings present.
- Existing suites: `tools/verify_v06_mic.gd` 53/53 PASS, exit 0.
  `tools/check_scripts.gd`: 136 checked, 4 failed — all the known
  pre-existing `android/build/` scaffolding files, none in Worker E
  files. No publish, no version bump, no platform-artifact rebuild.

### Deferred (with reason)
- True recognizer-level stop/cancel: ForgeSpeech has NO stopListening()
  method, so cancel / timeout / release cannot kill the Android
  recognizer mid-utterance — the session closes GDScript-side and the
  stale guard ignores the late onResult. The recognizer self-terminates
  on end-of-speech/silence/error per Android. The CONFIRM step makes
  this safe (a stale transcript attributed to a fresh session is still
  shown for Retry/Cancel before anything is built). Adding
  stopListening() is a small Java addition + AAR rebuild — deferred to
  avoid touching the shipped AAR mid-batch; the coordinator can
  schedule it as plugin follow-up.
- On-device QA (Colin): confirm-prompt layout on his S23, banner
  readability, real recognizer latency, and the hold-to-talk feel.
  Headless verification proves the state machine + gating, not the
  on-device UX.

## Forge batch — Worker D: Mod Creator redesign (B, C, D + item 8) — 2026-10-15 ~14:00 MDT

### What landed (code + verification notes only — no publish, no version bump, no platform-artifact rebuild)
- **B. CREATE-A-MOD is its own main-menu widget.** `scripts/ui/main_menu.gd`
  (ONE addition): a CREATE A MOD button (after STATS) + `_on_create_mod()` /
  `_on_creator_menu_closed()` that opens the new menu scene and frees it on
  close. The menu is `scenes/ui/mod_creator_menu.tscn` +
  `scripts/ui/mod_creator_menu.gd` (class `ModCreatorMenu`) with three tabs:
  CREATE / MODS / IMPORT/EXPORT. IMPORT/EXPORT is a PLACEHOLDER/DISABLED tab
  only — note label + two disabled buttons, zero functionality, nothing wired.
  The MODS tab shows the SAME installed-mods list as the Forge menu
  (ModLoader.get_mods() directly — no second list): list / enable / disable /
  Rescan. The old Create Mod panel + approval panel + all wiring were REMOVED
  from `scripts/ui/forge_menu.gd` (414 lines, anchor-based deletion — the
  file had grown ~129 lines mid-task from another worker's concurrent
  additions (history search, code-build input); those were preserved and
  verified intact). The Forge menu's Mods tab keeps list/enable/disable/Rescan.
- **C. CREATE tab = structured form, not one text box.** Multi-choice
  CATEGORIES checkboxes (Weapon, Block/Structure, Enemy, Effect, Gameplay —
  a mod can be several at once) + NAME + VISUAL DESCRIPTION + LOGIC. GENERATE
  composes ONE stable prompt (`ModCreatorMenu.compose_prompt()`: fixed section
  order + fixed technical notes) and feeds the EXISTING generation -> strict
  validation -> approval pipeline (ModCreator, untouched): summary + FULL
  payload -> Install / Discard / Regenerate. The technical notes steer the
  model to the existing validated path (custom visuals via
  api.spawn_voxel_box, impact explosions via api.fire_effect("explosion",
  ...), ModAPI only, no forbidden code).
- **D. Voxel asset generation + cache.** NEW `scripts/mods/voxel_asset_generator.gd`
  (class `VoxelAssetGenerator`): keyword-driven PROCEDURAL voxel builder, local
  and self-contained — no external downloads. Watermelon gets a bespoke
  builder (green striped rind shell, red interior, black seeds); everything
  else is shape keywords (sphere/cube/cone/star/cylinder/disc/blade, else a
  rounded blob) x colour keywords x pattern keywords (stripes/checker/spots),
  with a sensible generic voxel shape for unknown descriptions. Cache keyed by
  sha256 of the NORMALIZED visual description in `user://mods/assets/<sha256>.json`;
  same description -> cache HIT (no regeneration), different description ->
  new asset. The approval screen shows the asset info (voxel count + HIT/MISS).
- **8. Sandbox test before install.** NEW `scenes/ui/sandbox_test_room.tscn` +
  `scripts/ui/sandbox_test_room.gd` (class `SandboxTestRoom`): flat voxel room,
  two target dummies, the candidate's generated voxel visual as the projectile.
  TEST IN SANDBOX (approval screen) -> FIRE TEST SHOT animates the projectile
  at dummy 0; on impact a local explosion flash fires, the dummy topples, and
  the result reports HIT / explosion. Install stays available whether or not
  the sandbox was used. The sandbox NEVER executes the candidate's script
  (it simulates the declared behaviour from form + payload) and NEVER writes
  to the real mod list or player progression — nodes live only in its own
  SubViewport (UI) or a caller-owned root (`build_room()` / `simulate_test()`).
- NEW verifier (Worker D's own scratch): `tools/verify_creator_redesign.gd`
  (55 checks). The pre-existing `tools/verify_v08_create.gd` (Worker F) is
  NOT touched — see Deferred.

### Verification evidence
- `tools/verify_creator_redesign.gd`: **55/55 PASS, exit 0.** Covers:
  normalize/cache-key determinism; watermelon voxels (139: green rind + red
  interior + black seeds); cache MISS -> HIT reuse (same key/count), different
  description -> new asset, cache file under `user://mods/assets/`; generic
  fallback non-empty; `compose_prompt` stable + carries all four form fields;
  `behavior_for` = projectile + explodes; sandbox `simulate_test` HIT +
  explosion + no writes; `build_room` = flat room + 2 dummies; main-menu
  button opens the creator; 3 tabs; 5 multi-choice categories (Weapon +
  Effect both selected); IMPORT/EXPORT disabled placeholder; MODS tab widgets;
  watermelon-LMG E2E (form -> GENERATE -> candidate validates, mod_id
  `watermelon_lmg` -> approval summary + FULL payload + asset info ->
  TEST IN SANDBOX opens room, HIT + explosion with the 139-voxel generated
  visual, mod-list tree unchanged -> INSTALL -> mod in `get_mods()` + MODS tab
  row -> Forge builds from it: "Forge fabricated: Watermelon LMG (mod).",
  arena gained the ModAPI-spawned watermelon nodes); old panel gone (source +
  live Forge menu); Forge Mods tab keeps list + Rescan.
- `tools/check_scripts.gd`: all Worker D files compile. Remaining 8 failures
  are other workers' mid-landing files (android test scaffolding x4,
  forge_ghost, forge_structure, net_forge_sync, verify_forge_batch) — not
  touched. One real bug found by the verifier and fixed in-session: sandbox
  camera/light used `look_at()` before viewport children finished entering
  the tree (engine error) — now `look_at_from_position()`.
- Regression: `tools/verify_v08_create.gd` = 41 PASS; its failures are ONLY
  checks asserting the old in-Forge create panel exists (removed by design
  per this task) plus downstream checks that drive that panel. The
  ModCreator pipeline itself (validation, install, catalog, Forge build)
  still passes there.

### Deferred / follow-ups (with reason)
- **Worker F: update `verify_v08_create.gd` to drive the new creator menu.**
  It asserts the old in-Forge panel; that panel is gone by design. Worker D
  did not touch it (Worker F owns verification tools).
- **ModLoader owner: skip the `assets` dir when scanning `user://mods/`.**
  The asset cache lives at `user://mods/assets/` per the batch spec, so
  ModLoader currently records an `assets` folder as a broken mod entry
  (missing manifest.json). The creator menu's MODS tab filters that entry
  out of its display, but the Forge menu's Mods tab will show it until
  ModLoader skips non-mod directories. One-line skip; deliberately not done
  by Worker D (ModLoader is not a Worker D file).
- **On-device QA (Colin):** creator menu layout / touch targets on his S23,
  sandbox feel (projectile speed, explosion flash), real-LLM watermelon-LMG
  generation quality (the headless E2E uses a mock generation; the live
  DeepSeek path goes through the same composed prompt + validation +
  approval). Headless verification proves wiring + validation, not the
  on-device UX.

## Forge batch — Worker A (Forge core: items 1, 5, 7 + directive A) — 2026-10-15 ~14:00 MDT

### What (Colin-approved Forge items 1, 5, 7 + directive A; code + verification only — no publish, no version bump, no platform rebuilds)
- **(1) Forge aliases for the new weapons + mod names (offline parser + LLM).**
  Forge ids `trident` -> Arsenal `br3` (BR-3 Trident) and `judge` -> Arsenal
  `hv44` (HV-44 Judge) in `ForgeBuilder.FORGE_WEAPON_IDS` / `WEAPON_NAMES`.
  Offline parser: "burst rifle" / "trident" / "burst" / "3-round" -> trident;
  "judge" / "revolver" / "heavy revolver" / "six-shooter" -> judge (checked
  before the generic rifle/gun branch, which used to swallow "burst rifle"
  as a manticore). LLM path: `trident`/`judge` added to the `weapon_id`
  enum in `SYSTEM_PROMPT` + descriptions (burst rifle / heavy revolver) +
  per-weapon costs + examples ("give me a burst rifle" -> trident 310,
  "give me a judge" -> judge 200); gate accepts both ids. Installed mod
  names resolve offline too: a MULTI-WORD mod name (mod id / name /
  display_name / block_id, underscores/hyphens -> spaces) appearing in the
  prompt returns a `mod_block` spec at the mod's declared cost. Single-word
  mod names deliberately do NOT match offline — a mod named "wall" or
  "sniper" would hijack every base prompt with that word; single-word mods
  stay reachable via the LLM path (its catalog lists them). New Forge-menu
  presets: Burst Rifle ("Give me a burst rifle"), Judge ("Give me a judge").
  Offline weapon+ammo composition generalized from the old LMG-only branch:
  any known weapon + ammo keyword with a trigger word (bullets/rounds/ammo/
  shells, or bare buckshot) composes (e.g. trident + sniper bullets = 360,
  shotgun + buckshot = 270). "Give me sniper ammo" stays an ammo pickup,
  not a composition (guard: bare "sniper" alone is not a weapon signal).
- **(5) Real per-weapon Forge costs — flat 200 is dead.** `ForgeLLM.weapon_cost()`
  computes each weapon from power: `clamp(round5(75 + sqrt(damage x pellets
  x rpm x mag)/4 + damage x pellets), 100, 350)`. The sqrt curve keeps the
  spread sane vs. structure costs (100-200) and the turret (250); the
  per-shot term keeps slow, hard-hitting weapons honest (without it the
  Longeye at 40 rpm / 5-round mag would cost less than a pistol despite
  120 damage a shot). Results, all distinct: manticore 280, longeye 235,
  breacher 220, hornet 270, p9 180, raptor 150 (fixed utility price —
  0-damage grab/throw, formula N/A), lmg 350 (raw 384, clamped), trident
  310, judge 200. Trident's 900 rpm is the intra-burst rate (bursts are
  re-press gated); the formula prices the per-burst alpha. Costs flow
  through `recompute_cost()` / `validate_modspec()` / `preview_cost()` /
  the menu COST line — computed + shown, never blocking (see A).
- **(7) Shareable build codes + history search.** A build code is one
  copy-pasteable string for a whole build action: `FORGE1-` + base64url
  (JSON of the ModSpec; `+` -> `-`, `/` -> `_`, padding stripped).
  `ForgeLLM.encode_build_code()` / `decode_build_code()` are pure; decode
  returns `{}` for garbage/empty/non-Dictionary input, and normalizes
  integral floats back to ints (Godot's JSON parser returns ALL numbers as
  float, but the strict gate requires true ints for `size_voxels`/`count` —
  without this, decoded specs fail the gate). A decoded spec is NEVER
  trusted: `build_from_code()` runs it through the same strict gate before
  anything builds (a tampered code with an invented `script` field is
  rejected). `Forge` manager: `get_last_build_code()` (last successful
  build, post-validation spec — codes chain: paste -> rebuild -> copy the
  same code), `build_from_code(code)` (same busy/cooldown gates as
  `submit_prompt`, does NOT pollute prompt history). Forge menu: COPY LAST
  CODE (clipboard + fills the code field), BUILD FROM CODE (paste a code
  -> rebuild), and a Search-history field above the history list.
  `Forge.search_history(query)` is the case-insensitive substring filter
  ("" = all); the menu uses it with a local-filter fallback.
- **(A) Budget OFF (directive A).** `ForgeManager.BUDGET_ENABLED = false` —
  one flag. Building is free: the spend gate, failure refunds, and undo
  refunds are all gated behind it (undo reports refund 0, messages claim
  no refund); the code paths are NOT deleted and return by flipping the
  flag. Costs are still computed + shown (menu preview reads
  `COST: N (free)`). The Forge menu budget label is HIDDEN (node stays in
  the tree, text still refreshed, `visible = false`). The structure cap
  12 STAYS (perf guard, not budget). The ForgeDirector's internal
  "budget" is untouched — it is enemy-AI planning spend, not player
  Forge budget. The LLM user message no longer carries a budget figure
  ("Forge building is free (no budget limit)"), so the model never
  rations a build against a budget that does not gate anything.

### Files (Worker A only)
- `scripts/forge/forge_llm.gd` — `WEAPON_POWER` table + `weapon_cost()` /
  `_weapon_power_cost()`; trident/judge in `SYSTEM_PROMPT`, gate,
  `_base_cost`, offline aliases + generalized weapon+ammo composition +
  `_mod_spec_for_prompt()` / `_normalize_mod_name()`; `encode/decode_build_code()`
  + `_normalize_json_numbers()`; free-building LLM user message.
- `scripts/forge/forge_builder.gd` — `WEAPON_NAMES` + `FORGE_WEAPON_IDS` for
  trident/judge (only Worker-A lines; Worker B's structure work in the
  same file was left untouched).
- `scripts/forge/forge_manager.gd` — `BUDGET_ENABLED = false` + gated
  spend/refund/undo; `_run_pipeline` tail extracted to `_execute_spec()`
  (shared by prompt + build-code paths); `get_last_build_code()` /
  `build_from_code()` / `search_history()`.
- `scripts/ui/forge_menu.gd` — budget label hidden; `COST: N (free)`
  preview; history-search field; build-code row (paste + BUILD FROM CODE
  + COPY LAST CODE); Burst Rifle / Judge presets; focus release for the
  new fields on close.

### Verification (scratch verifier `/tmp/verify_forge_a.gd`, NOT a repo suite — Worker F owns verification tools)
- Scratch suite: ALL CHECKS PASSED (aliases incl. burst rifle/judge/trident/
  revolver + sniper-ammo-not-composition + composition costs; all 9
  weapon costs distinct + recompute matches; code round-trips identical,
  base64url body, garbage/empty/blank -> {}, bare-base64 decodes, tampered
  code rejected, non-integral float hp survives; real mod folder
  `zz_scratch_chunky_wall` resolves by name at declared cost 150 while
  "build a wall" stays plain — scratch mod created + removed, `user://mods/`
  left clean; manager `build_from_code` with budget 0 SUCCEEDS, budget
  stays 0, same code rebuilds (+1 structure), undo refunds 0 with no
  refund claim; `search_history` case-insensitive; `preview_cost` 310/200;
  builder builds trident -> br3 / judge -> hv44 with "BR-3 Trident" /
  "HV-44 Judge" messages; menu budget label hidden, preview
  "COST: 310 (free)", history search shows 1 entry, copy-last-code fills
  the code field).
- Pre-existing suites (intentional deltas only, for Worker F):
  `verify_v062` — exactly 10 failures, ALL the flat-200 -> per-weapon
  change (LMG+sniper 250 -> 400, manticore+buckshot 250 -> 330,
  longeye 200 -> 235); everything else in that suite still passes.
  `verify_v05_b1_forge_ui` — 2 failures: "budget drops by wall cost 100"
  (intentional: no spend while budget is OFF) and "4 tabs exist (got 6)"
  (pre-existing: Loadouts + Mods tabs, suite never updated).

### Deferred / follow-ups (with reason)
- **PRE-EXISTING BUG (flagged, NOT fixed — needs a coordinator call): the
  live LLM path rejects JSON-parsed cover/enemy_spawn specs.** Probe:
  a raw LLM-style JSON wall spec run through `_extract_spec` +
  `validate_modspec` returns `false` ("size_voxels must be [x,y,z] each
  1-12"). Root cause: Godot's `JSON.parse_string` returns ALL numbers as
  float, but `ForgeLLM._is_int_in` requires true ints. Weapon specs are
  unaffected (no int-only params); cover (`size_voxels`) and enemy_spawn
  (`count`) specs from the LLM hit it. The build-code path is fixed (decode
  normalizes integral floats -> ints); the LLM path was left alone because
  changing gate semantics is a validation-behavior change for Worker F /
  the coordinator to route. Suggested fix: accept integral floats in
  `_is_int_in`, mirroring `ModLoader._is_int_in` (which already does).
- **HUD budget UI still visible (not a Worker-A file).** `hud.gd` still
  shows `BUDGET: N` (topbar + `_forge_budget_label`) and announces
  "spend budget: N" on build phase. Route to the HUD owner or gate behind
  the same flag. The Forge menu side is done.
- **ModLoader / mod-creation catalogs still list only 7 base weapons.**
  `ModLoader.BASE_WEAPON_IDS` + the generation prompt's `give_weapon`
  list lack trident/judge, so user mods cannot yet use them as
  `base_weapon_id`. Deliberately not touched (ModLoader / mod-creator
  files are not Worker-A files) — route to their owner.
- **`Tuning.FORGE_COST_WEAPON = 200` (mirror const) is stale.** Coordinator
  consolidation file, not Worker-A; the live value is `weapon_cost()`.
- **On-device QA (Colin):** build-code copy/paste between phones, new
  presets, "COST: N (free)" wording, budget label gone from the Forge menu.

## Forge batch — Worker C: FORGE IN MULTIPLAYER (item 4) — 2026-10-15

### What landed
Placed Forge structures now sync to every peer, host-authoritative
(host validates + broadcasts; matches the existing MP architecture where
the host owns HP/kills/score). Files touched (disjoint, Worker C only):
- NEW `scripts/net/net_forge_sync.gd` (class `NetForgeSync`) — registry,
  event shape, validation/sanitization, spawning, polling fallback.
- `scripts/net/net_manager.gd` — Forge RPCs (single-RPC-endpoint rule) +
  public API (`forge_notify_placed / forge_notify_removed /
  forge_notify_updated / forge_get_placed / forge_request_resync`) +
  forwarded signals + late-join snapshot on `peer_connected`.
- `scripts/forge/forge_manager.gd` — ONE hook in `_execute_spec`
  (after the FAIL check, so failed builds never sync): guarded,
  duck-typed `NetManager.forge_notify_placed(last_built_node, spec)`.
  No-op offline / without NetManager; SP behavior unchanged.

### Event shape (canonical — Worker B's destroy/move/rotate/delete events
### flow through this; B calls the NetManager API, never edits the shape)
`entry = {"instance_id": int,  # host-assigned, > 0; 0 = client provisional
"preset_id": String,  # "cover:wall" | "structure:<shape>" (all 10 shapes:
# bridge/bunker/watchtower/ammo_depot/stairs/ramp/wall/jump_pad/
# cover_piece/sniper_nest) | "turret" | "pickup:ammo|health" |
# "mod:<block_id>"
"owner": int, "pos": Vector3, "rot": Vector3 (euler), "spec": Dictionary}`
Wire form = entry without the local-only `"node"` key (deep-copied spec).

### Flows
- Host places: ForgeManager hook -> `host_place()` (assigns id,
  registers) -> broadcast `_rpc_forge_place`. Peers `apply_place()`.
- Client places: hook -> provisional entry (node tagged `forge_pending`,
  id 0) -> `_rpc_forge_request_place` to host -> host validates, spawns
  its own copy, assigns id, broadcasts -> client `apply_place()` ADOPTS
  its provisional node (no duplicate spawn).
- Destroyed on host (explicit destroy, cover fracture, undo, turret TTL):
  `host_remove()` -> broadcast `_rpc_forge_remove` -> peers
  `apply_remove()`. Host `_process` polling (0.1 s) also catches
  queue_free'd registered nodes, so fracture/undo/TTL need no extra call.
- Move/rotate: `host_update()` -> broadcast `_rpc_forge_update` -> peers
  `apply_update()` (transform forced to the authoritative pose).
- Late join: host sends `_rpc_forge_sync` (full wire list) on
  `peer_connected`; client can also call `forge_request_resync()` after
  map load (coordinator: one call in Main after the MP map loads —
  covers a snapshot that arrived before the world existed; apply dedupes
  by instance_id, so a double send is safe).
- Spawn on peers goes through `ForgeBuilder.build()` with an explicit
  `[x,y,z]` position, then the authoritative transform is FORCED onto
  the node (the builder orients structures toward the LOCAL player;
  peers must match the placer's orientation, not their own). Peers never
  charge Forge budget for a synced build (build bypasses ForgeManager).
- Robustness: unknown preset ids / malformed entries (NaN, negative id,
  out-of-arena, spec/preset mismatch) are IGNORED, never crash
  (`sanitize_entry` type-checks every field; cover params clamped).
  Forged broadcasts (sender != 1) ignored; place/remove/update requests
  are host-only + per-peer rate-limited (10/s). Duplicate broadcasts
  dedupe by instance_id. Removals/updates of unknown ids are idempotent.
- Polling fallback: untagged nodes in group `forge_structure` (direct
  `ForgeBuilder.build` calls that bypassed the hook) are inferred and
  synced. Inference prefers ForgeStructure markers (`forge_kind` meta /
  `structure_shape` property / `shape` meta) over the node NAME, because
  Godot auto-renames duplicate siblings (`ForgeStructure_bunker` ->
  `@Node3D@N`), which broke a name-only lookup in testing. Inferred
  specs use `property: "standard"` (reinforced is exact only on the hook
  path). Clients never emit remove/update from polling — host only.

### Verification (ephemeral `/tmp/verify_forge_mp.gd`, NOT landed in
### tools/ — Worker F owns verification tools)
- **57/57 PASS** headless two-peer simulation (two NetForgeSync
  instances, host broadcast simulated by feeding the host's wire entry
  into the client's `apply_*`, same pattern as verify_multiplayer):
  preset ids (incl. weapon -> not placeable, mod -> `mod:<id>`),
  sanitize rejects (unknown preset, NaN, negative id, out-of-arena) +
  cover clamp, host place (id 1, identical transform, tagged), client
  apply identical, duplicate broadcast deduped, client provisional +
  host-echo ADOPT (no duplicate, re-tagged with host id), move/rotate
  identical, destroy host -> removed client, double remove idempotent,
  late-join snapshot (identical transform) + empty-snapshot prune,
  unknown/malformed apply ignored, real ForgeBuilder spawn path
  (ForgeStructure_bunker node, transform forced, peer copy identical),
  NetManager guards (offline `forge_notify_placed` no-op; forged
  `_rpc_forge_place` / `_rpc_forge_sync` with sender 0 ignored;
  non-host `_rpc_forge_request_place` ignored), polling detects an
  untagged ForgeStructure + host-side free -> remove event.
- Regressions: `check_scripts` 148 checked, 4 failed — all pre-existing
  `android/build/` scaffolding, none in game code. `verify_multiplayer`
  180 passed, 0 failed (7 needs-device, pre-existing).
- `verify_v05_b2_forge_backend` (82/89) and `verify_v062` (10 fails)
  fail on SIBLING Forge-batch changes, not this item: per-weapon costs
  (longeye 235, not flat 200), `BUDGET_ENABLED = false` (Directive A:
  building is free, undo refund 0), new weapons trident/judge. The
  Worker C hook is offline-no-op in those runs and touches none of
  that logic. Coordinator to re-baseline those suites against the new
  cost/budget rules.
- NOT verified live: a real two-device ENet match (sandbox blocks ENet
  sends; same standing limitation as verify_netcode). Needs Colin /
  two-device QA: place on one phone -> appears on the other identical;
  destroy on host -> removed on peer; late join receives the list.

### Coordinator notes
- No Main wiring needed for the core path (NetManager autoload creates
  its NetForgeSync child in `_ready`). Recommended one-liner: call
  `NetManager.forge_request_resync()` after the MP map loads.
- Worker B contract: call `NetManager.forge_notify_removed(id)` /
  `forge_notify_updated(id, transform)` from destroy/move/rotate/delete
  paths (client -> host request, host -> broadcast). Fracture/undo/TTL
  are already covered by host polling — no B call needed there.
- Known divergence (by design, not fixed here): cover HP is per-node
  local, so a client-side fracture does not destroy the host's copy
  until the host's copy also breaks. Damage sync for structures belongs
  to Worker B's destruction item; this item syncs host-driven
  destruction only, per spec.
- Nothing deferred. No publish, no version bump, no platform rebuilds.

## Forge batch — Worker B: Placement + structures (items 2, 3, 6) (2026-10-15 ~20:10 MDT)

Ghost preview + edit placed structures, destructible Forge structures,
and six new Build presets. Code + verification only — no publish, no
version bump, no platform rebuilds. Existing prompt → ForgeManager →
ForgeBuilder pipeline untouched; ghost/edit/preset paths are additive.

### Item 2 — Ghost preview + edit placed structures
- NEW `scripts/forge/forge_ghost.gd` (ForgeGhost): translucent preview
  built from the EXACT structure geometry
  (ForgeBuilder.build_shape_geometry). Valid = green-ish
  (0.25,1,0.35,0.45), invalid = red-ish (1,0.25,0.25,0.45). Visual-only:
  its collision body is never added to the tree, jump-pad Area3D
  triggers (and any other behaviour nodes) are stripped, it never joins
  group "forge_structure" (no cap count, no damage), shadows off.
- NEW `scripts/forge/forge_placement.gd` (ForgePlacement): controller.
  `attach_to(root)` returns the singleton-per-root instance.
  `start_preview(shape, params, player, root)` → ghost follows the
  crosshair every frame (ground-snapped; valid = under cap + inside
  arena). `confirm_preview()` builds at the ghost position via
  ForgeBuilder (preset path: cost computed, enforcement off — no budget
  touched; the LLM/prompt path keeps its own budget handling in
  ForgeManager). `cancel_preview()` dismisses without building.
  Edit: `select_nearest()` (crosshair raycast, walks up from the struck
  collider to the forge_structure ancestor; falls back to nearest),
  `select(node)` (group-gated), `move_selected_to(pos)` (ground-snapped),
  `move_selected_by(offset)`, `rotate_selected(45° default)`,
  `repair_selected()` (full repair), `delete_selected()` (no refund —
  budget is off for edits). Static helpers
  `move_structure / rotate_structure / delete_structure /
  repair_structure` work without a controller instance.
- Integration contract for the menu worker (forge_menu.gd untouched):
  preset buttons call `ForgePlacement.attach_to(scene)` +
  `start_preview(...)`, confirm/cancel from the placement UI, and the
  edit buttons from the selection API above. The ghost/confirm path
  does NOT go through ForgeManager — the menu worker owns wiring it to
  its Confirm button.

### Item 3 — Destructible Forge structures
- NEW `scripts/forge/forge_structure.gd` (ForgeStructure): replaces the
  plain Node3D in `_build_structure`. Live HP (table in
  ForgeBuilder.STRUCTURE_BASE_HP, scaled by size/cost: bunker 600 >
  wall 400 > sniper nest 350 > bridge/ammo depot 300 > stairs/ramp 250
  > cover piece/jump pad 200; reinforced ×1.5). `take_damage(amount,
  hit_pos, is_headshot)` (headshot arg accepted, ignored), meta hp/max_hp
  kept in sync for legacy readers. Feedback (no shared-material
  mutation — VoxelBuilder materials are cached per color): ~0.09 s red
  flash overlay, crack cubes scaling 0→8 with damage, dark smoke
  emitter below 35% HP (off again on repair). At 0 HP: DebrisPool burst
  in the structure's palette + cover_break sting, leaves
  "forge_structure", queue_free.
- Damage routing WITHOUT touching enemy code (enemy hitscan only ever
  damages group "player", so no enemy caller existed for structure HP):
  (a) the structure's collision body is now
  `ForgeStructure.StructureBody`, which forwards take_damage() to the
  parent — without it, weapon raycasts / explosion shape queries strike
  a plain StaticBody3D with no damage method and structures would be
  immune to player fire/explosions; (b) NEW
  `scripts/forge/forge_enemy_pressure.gd` (ForgeEnemyPressure): every
  0.9 s at most ONE engaged enemy (can see the player, or player < 25 m)
  within 20 m with line of sight lands one hit for its own damage ×
  director dmg_mult. ForgeStructure ticks it on itself; covers and
  turrets get a ForgeEnemyPressure child from ForgeBuilder (their own
  scripts untouched).
- Repair: `repair(amount)` / `repair_full()` on ForgeStructure, plus
  interact key (F / Y) while standing within 3.2 m of a damaged
  structure. `ForgeStructure.repair_target(node, amount)` duck-types
  all three build kinds: ForgeStructure via repair(), DestructibleCover
  via hp + max_hp meta (ForgeBuilder now records it), turret via _hp
  (max 150). `hp_of / max_hp_of / delete_target` helpers likewise.
- Covers were already destructible (DestructibleCover fracture); this
  item gives them enemy-pressure damage + repair. Turret repair works
  via _hp; its TTL/power-down lifecycle is otherwise untouched.

### Item 6 — More Build presets
- `_build_structure` now accepts 10 shapes (old 4 + 6 new), all via the
  shared `build_shape_geometry(shape, parent, body)` dispatcher (also
  used by the ghost, so previews match placed geometry exactly).
  New: stairs (8 steps to a 3.4 m platform, 100), ramp (overlapping
  slabs to a 2.3 m deck, 90), wall (6 m × 3 m barrier + posts + orange
  cap, 120 — distinct from the cover-target "wall" slab), jump_pad
  (base + orange plate + ForgeJumpPad trigger, 150), cover_piece (low
  3 m × 1.1 m wall + rail + sandbags, 60), sniper_nest (legs + elevated
  platform, full rails, solid front shooting-rest lip, rear stairs, no
  roof, 220). Costs in STRUCTURE_COST (computed, enforcement off on
  the direct path); bounds in STRUCTURE_BOUNDS.
- NEW `scripts/forge/forge_jump_pad.gd` (ForgeJumpPad): Area3D (layer 0,
  mask 2 = player) that launches the player: vertical 12.5 m/s (~3.9 m
  apex vs the player's GRAVITY 20 — vs JUMP_VELOCITY 5.8 / slide-hop
  5.5, so it reads as a pad, not a hop) + 3.5 m/s forward in pad
  facing; horizontal velocity preserved, never replaced. 0.4 s
  per-body retrigger cooldown; ignores non-player bodies.
- `ForgeBuilder.build_preset(shape, player, root)` — direct preset
  build (near_player, cap still enforced, no budget touched).
- Poly/draw: each new shape is 4–15 meshes + one collider per solid
  block, same vocabulary as the original four — phone-sane.
- NOT wired: the LLM/prompt path cannot build the new shapes yet —
  ForgeLLM / ForgeManager VALID_STRUCTURES still list the old 4 (those
  files belong to other workers; the prompt worker adds keywords +
  costs). The menu worker wires preset buttons to `build_preset()` /
  the placement controller. Net sync (`net_forge_sync.gd`,
  STRUCTURE_SHAPES) also still lists only the old 4 — the net worker
  extends it, or new presets won't sync to peers.

### Verification
- NEW `tools/verify_forge_b_placement.gd` (B2 `load()` pattern — no
  parse-time class_name references, so the Sfx-autoload compile trap is
  avoided; staged `_process` + quit like the other verify scripts):
  **192/192 PASS** headless.
  Covers: all 10 shapes build + collide + group + HP + cost;
  reinforced bunker 900 HP; build_preset ok/unknown; ghost per shape
  (geometry shown, no group, no Area3D, valid/invalid tint, unknown →
  null); preview → confirm (+1, ghost gone) → cancel (builds nothing);
  select/rotate 45°+45°=90°/move/delete (count restored); damage 150 →
  250 → repair(100) → 350 → repair_full → 400, meta in sync, cracks +
  low-HP smoke, destroy at 0 HP (group left, queued); cover damage +
  repair_target; turret damage + repair_target; enemy pressure deals
  the foe's 25 damage, inactive/out-of-range/destroyed foes no-op;
  jump pad launches (vy 12.5, horizontal preserved + forward boost,
  cooldown blocks retrigger, non-player ignored); cap 12 enforced,
  13th rejected, ghost invalid at cap, delete reopens the cap.
- `tools/check_scripts.gd`: all game scripts pass (remaining failures
  are the 4 pre-existing android/build scaffolding files + the other
  worker's in-flight `tools/verify_forge_batch.gd`).
- Existing `tools/verify_v05_b2_forge_backend.gd`: 82/89 — the 7
  failures are all in files this worker did NOT touch (concurrent
  workers' landed changes: ForgeLLM per-weapon pricing, longeye 235
  vs B2's stale 200; ForgeManager budget handling, wall charged 0 /
  undo refund 0). The B2 structure-cap check (this worker's area)
  passes. Flagged for the coordinator — B2 needs re-baselining against
  the batch's new pricing/budget rules.
- Two verify-harness lessons (no game-code impact): (1) `quit()` in
  `_initialize` never terminates a `--script` SceneTree run (idles
  forever) — stage checks in `_process` like B2; (2) verify scripts
  must `load()` Forge scripts at runtime, never reference their
  class_names at parse time (Sfx autoload not yet registered).

### Deferred / notes
- Nothing deferred among items 2, 3, 6. Open follow-ups for the
  coordinator (other workers' files): ForgeLLM/ForgeManager new-shape
  keywords + costs; net_forge_sync STRUCTURE_SHAPES extension;
  B2 re-baseline for new pricing/budget rules. On-device QA still
  Colin's: ghost readability on the S23, pressure damage feel in a real
  wave, jump-pad launch feel, interact-repair discoverability.

## 2026-10-15 — WORKER F (Verification): FORGEFALL Forge batch verifier — FINAL

Suite: `tools/verify_forge_batch.gd` (owned by Worker F; only file touched).
Run: `godot --headless --path . --script res://tools/verify_forge_batch.gd`
Result: **128 PASS / 17 FAIL** (exit 17). All 17 FAILs are real gaps in
other workers' code, confirmed against the current sources — no suite
false negatives remain (two rounds of false-positive/false-negative
fixes during this session are documented in the suite's own comments).

### Per-area scoreboard
- budget-off: 4 PASS / 0 FAIL — BUDGET_ENABLED == false; prompt build
  at budget 0 succeeds, never blocked, budget stays 0; no budget UI.
- aliases: 9 PASS / 0 FAIL — "give me a burst rifle" -> Trident,
  "give me a judge" -> Judge (both pass validate_modspec); installed
  probe mod resolves in the offline parser; probe removed after.
- ghost-edit: 18 PASS / 0 FAIL — ForgePlacement + ForgeGhost: ghost
  for sniper_nest, no cap-group, no live collision, VALID/INVALID tint
  swaps, cancel dismisses, confirm builds, select/move/rotate/repair/
  delete on a placed structure all work.
- destructible: 7 PASS / 0 FAIL — structure 600 -> 500 -> destroyed
  at 0 HP -> repair to 600; cover 100 -> 60 -> repair_target -> 100
  -> broken at 0 HP.
- mp-sync: 9 PASS / 0 FAIL — NetForgeSync in-process peer sim (sandbox
  blocks real UDP loopback): host_place -> identical registries,
  destroy -> removed both sides, late join gets the full list, stairs
  syncs as structure:stairs. Live RPC wiring (NetManager
  _rpc_forge_*) covered by static checks.
- per-weapon-costs: 4 PASS / 0 FAIL — recompute_cost differs across
  weapons (manticore 280, longeye 235, breacher 220, hornet 270,
  p9 180, raptor 150, lmg 350; Trident 310 vs Judge 200); menu preview
  shows COST: 235 (free) vs COST: 180 (free).
- presets: 34 PASS / 7 FAIL — all six new structure presets place +
  collide + count toward cap 12 via ForgeBuilder.build_preset; 13th
  refused as cap. FAILs below.
- build-codes: 13 PASS / 0 FAIL — encode (FORGE1-...) / decode
  round-trips, garbage -> {}, rebuild from decoded spec identical,
  pipeline build -> code -> build_from_code identical position +
  code chains, History search filters (tower -> 1 entry, "" -> all).
- creator: 24 PASS / 0 FAIL — main-menu CREATE A MOD opens the
  creator; tabs CREATE / MODS / IMPORT/EXPORT (placeholder, buttons
  disabled); old in-Forge _create_panel gone; form categories + name
  + visual + logic composes a prompt (voxel + explosion notes) and
  validates via ModLoader; voxel asset generated + cached + reused;
  watermelon-LMG e2e (watermelon voxels, projectile + explodes_on_
  impact, sandbox hit + explosion); sandbox writes nothing and does
  not pollute the mod list.
- voice-confirm: 2 PASS / 10 FAIL — FAILs below. The 2 passes are
  "no stuck listening state" (vacuous: no listener exists).
- setup: 4 PASS / 0 FAIL.

### FAILs — exact repro (all in other workers' code)
1. presets wiring (1): NOTHING calls `build_preset(` or
   `start_preview(` outside their definition files (grep over
   scripts/ + scenes/ empty). The six presets are library-only —
   unreachable from the Forge menu or the prompt path.
   Repro: suite grep; or in-game: no menu button / prompt builds a
   new preset.
2. presets prompt-path (6): the offline parser does not map the new
   preset prompts to the structure presets:
   - "build stairs" -> _error fallback (arena_event supply_drop)
   - "build a ramp" -> structure bridge (fallback)
   - "build a wall" -> cover wall (old cover, not structure wall)
   - "build a jump pad" -> _error fallback (supply_drop)
   - "build a cover piece" -> cover wall (fallback)
   - "build a sniper nest" -> cover tower (fallback)
   Repro: `ForgeLLM.parse_offline("<prompt>")` in a headless probe.
3. voice-confirm (10): no voice confirm dialog exists.
   `scripts/ui/forge_menu.gd` `_on_voice_text` still calls
   `_submit_prompt(transcript)` directly — the transcript submits
   before any confirm, so there is no Confirm/Retry/Cancel to press.
   Repro: suite calls `_on_voice_text("build a wall in front of
   me")` -> forge_result emits with no dialog (forge_results=1).
   All 10 voice checks fail on this single root cause.

### Regressions
- GREEN (11): verify_fixes, verify_v06_movement, verify_feel
  (83/0), verify_sound (719/0, 8 warnings), verify_content
  (495/0, 1 warning), verify_updater_pc (65/0 — the old 4
  pre-existing FAILs are gone; suite expectations now match the
  shipped manifest), verify_multiplayer (180/0, 7 needs-device),
  verify_portals (62/62 + integration/see-through/placement/
  momentum/puzzles all green), verify_progression (67/0),
  verify_linux, verify_windows (48/0).
- 900-frame smoke: CLEAN ("survived 900 frames, quitting clean",
  exit 0).
- REGRESSION (1) — verify_menu_layout: 1057 passed, 3 failed, all
  at 1280x800: footer inside viewport, QUIT fully inside viewport,
  stack fits viewport height. Cause: the Forge batch's 8th main-menu
  button (CREATE A MOD, main_menu.gd:284) re-overflowed the
  1280x800 stack — the SAME regression a prior batch fixed by
  tightening stack separation 5->2 on short screens (BUILD_LOG
  entry above). The fix needs re-applying for 8 buttons
  (tighter separation / scroll / compress on vp.y < 900). 1920x1080
  still passes. Not a crash; small-window layout only.

### Coverage gaps / headless limits (honest)
- No real UDP loopback (sandbox) -> MP tested as in-process peer sim
  through the real NetForgeSync registry + static RPC wiring check.
- No DeepSeek network -> voice recognition itself not exercised;
  the suite drives `_on_voice_text` directly (the real handler).
- No on-device check (Colin is QA): ghost tint readability, creator
  touch targets, 1280x800 layout on the Deck, voice permission flow.
- Suite-harness notes: Object.set() silently rejects an untyped
  Array for an Array[String] script var (use a typed Array[String]);
  queue_free leaves is_instance_valid true same-frame (check group
  removal / is_queued_for_deletion); decode_build_code("garbage")
  prints one benign engine base64 error and returns {}.
- The other worker's in-flight note in a prior entry (B2 re-baseline
  for new pricing/budget rules) still stands — B2's 7 failures were
  in files this worker did not touch.

## Source sync — v0.5.1 tree to public repo
- Synced the local source tree to `vatherty/FORGEFALL` (main) via the contents API: uploaded only files whose git blob SHA differed, deleted repo files no longer present locally (incl. the removed in-Forge create panel).
- Exclusions (never pushed): builds/, updates/, .godot/, staging dirs, *.apk/*.zip/*.pck/*.keystore/*.import, android/ template, any credentials (export_presets.cfg keystore passwords stay blanked).
- Tag v0.5.1 now points at the post-batch source.
