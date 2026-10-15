# FORGEFALL — File Manifest

Godot 4.7.2-stable voxel FPS for Android. 99 files. Every script carries a header comment with purpose + connections; tunables live in `scripts/core/tuning.gd` (mirrored from each subsystem's `#region TUNABLES`).

## Root
- `project.godot` — Godot 4.7.2 project: mobile renderer, Jolt physics, 1280×720 landscape, 22 input actions (incl. slot_1/2/3, killstreak_1/2/3), gyro enabled, Game/Sfx/Forge autoloads.
- `export_presets.cfg` — Android (arm64, SDK 24/35, INTERNET+VIBRATE) + Linux desktop presets.
- `icon.svg` — voxel-cube crosshair icon.
- `README.md` — setup, desktop run, Android export chain, playtest loop, controls, DeepSeek key setup.
- `DESIGN.md` — full design doc: fiction, FIGHT→FORGE→SURVIVE loop, MW2 style guide, voxel art direction, ModSpec v1 schema + 8 examples, director rules, roadmap.
- `BUILD_LOG.md` — living build log: subsystem status, decisions, contracts, validation, blockers.

## scenes/
- `scenes/main.tscn` — bootstrap scene (Main node + main.gd).
- `scenes/player.tscn` — player CharacterBody3D: capsule, camera rig, weapon holder, wrist anchors, wall/grapple rays.
- `scenes/player/portal_disc.tscn` — portal disc Area3D trigger (visuals built in code).
- `scenes/maps/dustline.tscn` — Dustline arena root (map built procedurally in _ready).
- `scenes/ui/hud.tscn` — MW2 HUD CanvasLayer shell.
- `scenes/ui/main_menu.tscn` — main menu shell.
- `scenes/ui/pause_menu.tscn` — pause menu shell.
- `scenes/ui/touch_controls.tscn` — touch controls CanvasLayer shell.

## scripts/core/
- `main.gd` — MENU/PLAYING/PAUSED state machine; wires HUD, touch controls, PerfScaler, WaveManager on game start.
- `game_state.gd` — autoload `Game`: waves, score, streaks, killstreak unlocks (3/5/7), Forge budget; all cross-system signals.
- `tuning.gd` — `class_name Tuning`: consolidated balance constants for all 9 subsystems + auto-updater (`UPDATE_BASE_URL`, `UPDATE_TIMEOUT_SEC`, `FALLBACK_VERSION_CODE`).
- `update_manager.gd` — autoload `Updater`: in-game APK auto-updater. Async version.json check at boot (8s timeout, never blocks menu); state machine DISABLED→IDLE→CHECKING→UP_TO_DATE/AVAILABLE→DOWNLOADING→READY; modal dialog only over the main menu; graceful no-plugin fallback (browser download). See DESIGN.md §11.
- `voxel_builder.gd` — `class_name VoxelBuilder`: shared voxel factory (cached materials, cube(), build_voxels(), collision_box(), palette, VOXEL_S/M).

## scripts/player/
- `player.gd` — MW2 movement: walk/sprint/slide, jump+coyote+buffer, wall-run, 100HP regen, ADS, headbob, footsteps, haptics.
- `grapple_hook.gd` — no-cooldown ascender: direct-pull vs pendulum swing, reel-in, momentum release, floor clamp.
- `portal_emitter.gd` — wrist portal emitter: fires blue/orange discs, manages the pair.
- `portal_disc.gd` — disc behavior: surface stick, momentum-preserving teleport, anti-ping-pong cooldown.

## scripts/weapons/
- `weapon_base.gd` — `class_name WeaponBase`: hitscan, recoil patterns, falloff, ADS, staged reloads, muzzle flash, tracers, shells, sway/bob.
- `weapon_manager.gd` — 3 slots (primary/secondary/prototype), switching, `give_weapon()` for Forge, ammo signals.
- `arsenal.gd` — `class_name Arsenal`: 6-weapon stat table + procedural voxel viewmodels with Muzzle/Eject anchors.
- `raptor_gun.gd` — `class_name RaptorGun`: PUNT-style physics gun (grab ≤12m, throw 30 m/s, damage only on impact).
- `tracer_pool.gd` — pooled emissive tracers.
- `ammo_pickup.gd` — spinning voxel ammo/health pickup crates.

## scripts/enemies/
- `enemy_base.gd` — `class_name EnemyBase`: HP, take_damage (headshot ×2), flinch, death, perception, nav-or-steer locomotion, burst fire.
- `voxel_soldier.gd` — `class_name VoxelSoldier`: procedural voxel rigs (walk cycle, aim pose) per enemy type.
- `grunt.gd` / `rusher.gd` / `marksman.gd` / `brute.gd` — tactical state machines (advance/strafe/cover/peek/flank/grenades).
- `wave_manager.gd` — `class_name WaveManager`: pools, spawn doors, composition, scaling curves, build phase, `apply_director_mod()`.
- `enemy_grenade.gd` — telegraphed ballistic grenade.
- `tracer_pool.gd` — pooled enemy tracers.

## scripts/maps/
- `dustline_builder.gd` — procedural Dustline: 11 shacks, market, water tower, cars, laundry, MultiMesh batching, nav bake, spawns/pads.
- `destructible_cover.gd` — `class_name DestructibleCover`: voxel cover with HP that fractures into debris.

## scripts/fx/
- `debris_pool.gd` — `class_name DebrisPool`: pooled RigidBody3D voxel cubes (cap 120).
- `explosion.gd` — `class_name ExplosionFX`: radial damage, flash, debris, camera shake.

## scripts/ui/
- `hud.gd` — MW2 HUD: crosshair, hitmarkers, ammo, damage vignette, killfeed, banners, killstreak pips, minimap, Forge console panel.
- `main_menu.gd` / `pause_menu.gd` — menus (deploy/options/quit; resume/restart). Main menu Options has a GAME UPDATES row: CHECK FOR UPDATES button + status line wired to the Updater autoload.
- `update_dialog.gd` — `class_name UpdateDialog`: modal update dialog owned by the Updater (AVAILABLE→DOWNLOADING→READY, plus install-blocked and error states), StencilStyle, touch+mouse.
- `stencil_style.gd` — `class_name StencilStyle`: shared military UI theme.

## addons/ForgeUpdater/ (Android plugin v2 — ships via custom export template)
- `plugin.cfg` + `export_plugin.gd` — @tool EditorPlugin packaging: hooks the AAR into Godot's Gradle export via `_get_android_libraries` (used when Gradle is available). Enabled headless via `[editor_plugins]` in project.godot.
- `bin/ForgeUpdater-{debug,release}.aar` — prebuilt plugin binary (built manually with javac; see `~/workspace/forgefall-plugin/build-aar-manual.sh`). Excluded from the resource pack via `exclude_filter`. The release AAR's classes are also baked into the custom export template (see below).
- Install path is the PackageInstaller Session API (no FileProvider); truly silent install is impossible for sideloaded apps (docs-verified), so the session always uses USER_ACTION_REQUIRED → one native "Install update?" dialog.

## scripts/forge/
- `forge_manager.gd` — autoload `Forge`: prompt pipeline, validation, budget, cooldown, result signals.
- `forge_llm.gd` — `class_name ForgeLLM`: real DeepSeek HTTPRequest client + offline keyword fallback.
- `forge_builder.gd` — `class_name ForgeBuilder`: ModSpec → voxel cover/turrets/pickups/weapons/killstreaks/smoke/supply drops.
- `forge_turret.gd` — voxel sentry turret (auto-targets enemies, TTL).
- `killstreaks.gd` — `class_name Killstreaks`: UAV / airstrike / attack chopper, key handling.
- `forge_director.gd` — enemy director: counters camping/sniping/turtling between waves.
- `forge_config.gd` — `class_name ForgeConfig`: DeepSeek key in `user://forge_config.json` only.

## scripts/audio/
- `audio_manager.gd` — autoload `Sfx`: 38 WAVs, 12+16 pooled players, buses, music crossfade, SFX alias map.

## scripts/android/
- `touch_controls.gd` — multi-touch dispatcher: dynamic joystick, look drag, full button cluster injecting Input actions.
- `perf_scaler.gd` — `class_name PerfScaler`: HIGH/MED/LOW tiers (resolution scale, shadows, motes).
- `haptics.gd` — `class_name Haptics`: guarded vibration presets.
- `speech_input.gd` — `class_name SpeechInput`: voice-to-Forge with typed fallback.
- `gyro_aim.gd` — `class_name GyroAim`: real gyro aim (disabled by default).

## assets/audio/ (38 WAVs, 3.54 MB, synthesized)
`shot_ar/sniper/shotgun/smg/pistol/lmg/turret`, `reload_ar`, `dryfire`, `weapon_raise`, `hitmarker`, `headshot_ding`, `kill_confirm`, `explosion_big`, `grenade_beep`, `grapple_fire/zip`, `portal_open/hum_loop/teleport`, `wave_horn`, `juggernaut_horn`, `damage_thud`, `heartbeat_loop`, `footstep_concrete/dirt/metal`, `jump_land`, `ui_click/hover/confirm`, `forge_success/fail`, `killstreak_ready`, `uav_online`, `pickup`, `ambient_wind_loop`, `music_drone_loop`.

## tools/
- `gen_audio.py` — stdlib-only synthesizer that produced all WAVs.
- `verify.sh` — headless import + script check (runs where Godot is installed).
- `check_scripts.gd` — SceneTree compile check: loads all 45 .gd files (45/45 pass on 4.7.2).
- `smoke_test.gd` — headless runtime smoke test: boots menu, starts game, runs 900 frames, exercises Forge prompt→build loop.
- `camera_check.gd` — asserts a Player with a current Camera3D exists after `start_game()` (regression test for the 2026-10-12 black-viewport hotfix).
- `updater_check.gd` — updater scaffolding test: autoload present, DISABLED path graceful, Options button + dialog instantiate.
- `updater_flow_test.gd` — full updater state machine vs a local HTTP server (needs `Tuning.UPDATE_BASE_URL` temporarily pointed at it): CHECKING→AVAILABLE→DOWNLOADING→READY.

## updates/ (publish staging, excluded from the APK)
- `forgefall-v0.1.2-debug.apk` — shippable build (see PUBLISH.md).
- `PUBLISH.md` — exact steps + version.json for publishing a new version to the Netlify update site.

## android/ (Gradle build template, excluded from the APK)
- Installed via `--install-android-build-template`; required for `use_gradle_build=true` exports. Contains Godot's template AARs under `build/libs/`.

## docs/
- `android_export.md` — full Android export chain (SDK/NDK/JDK versions, keystore, adb, troubleshooting) + main.gd integration snippet.
