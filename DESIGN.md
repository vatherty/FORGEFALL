# FORGEFALL — Design Document

**Version:** 0.1 (scaffold) · **Date:** 2026-10-05 · **Engine:** Godot 4.7.2-stable · **Platform:** Android (touch-first), Linux desktop for iteration
**QA:** Colin playtests on demand. He is the real QA. Nothing is "done" until it runs on his hardware.

---

## 1. Vision

FORGEFALL fuses two proven builds into one game:

- **Portal Arena** — the FPS movement kit: sprint/slide, wall-run, Spider-Man grapple, wrist-mounted portal emitter (blue/orange, always available), physics gun.
- **ModBox** — the AI "Forge" console: type (or speak) a prompt mid-combat and the game builds gear, cover, and killstreaks live from a ModSpec JSON pipeline.

The style target is **Call of Duty: Modern Warfare 2 (2009) game-feel** — ADS snap, punchy recoil, hitmarkers with the headshot *ding*, 3/5/7 killstreaks (UAV → Airstrike → Attack Chopper), Favela-grit fiction — but **all art is chunky voxels**: "MW2 directed by Minecraft." Colin's pivot name for the art direction: **Modern Voxfare 2**.

---

## 2. Fiction bridge

**Near-future military proving ground.** The player is a **test operative** dropped into "Dustline," a decommissioned shantytown the brass uses to stress-test prototype gear. The opposition: **militia waves** — scavenger infantry probing the proving ground, escalating as the brass cranks the difficulty dial.

Two AIs narrate the fiction and drive the systems:

- **FORGE (the quartermaster)** — the player's AI. It fabricates voxel gear, turrets, cover, and killstreak ordnance on demand from ModSpec requests, paid from a per-run build budget. Fiction: a rapid-fabrication rig wired into the operative's wrist console.
- **The Director (enemy AI)** — the range's adversarial AI. It watches *how* the player fights and retools the militia's tactics: campers get rushed and flanked, snipers get smoked and counter-sniped, turtles get grenadier'd out of cover. Fiction: the proving ground's red-team controller, and it is learning.

---

## 3. Core loop

**FIGHT → FORGE → SURVIVE.**

1. **Fight** a militia wave in the Dustline shantytown (MW2 gunplay: ADS, recoil, hitmarkers, kill confirms).
2. **Forge** during the build phase between waves (45s): spend build-budget on walls, turrets, pickups, weapon mods, killstreaks — via typed prompt (DeepSeek) or offline keyword fallback.
3. **Survive** the next wave, which the Director has re-tooled against your last performance. Kills feed the 3/5/7 killstreak ladder; wave clears pay budget trickle.

Death resets the killstreak counter (MW2 rules) but earned killstreaks are kept until used. The run ends when the operative dies; score is the bragging right.

---

## 4. MW2 style guide

### Gunplay
- **ADS:** right-mouse / left trigger hold — fast FOV snap (~0.18s), spread tightens hard, movement slows. Hip-fire is a desperation tool, not a strategy.
- **Recoil:** per-weapon kick pattern with first-shot multiplier; viewmodel kicks, crosshair blooms, then settles. Learnable, not random.
- **Hitmarkers:** white X on hit, red X + *ding* on headshot, skull + sound on kill confirm. Damage numbers are banned — hitmarkers ARE the feedback.
- **Killstreaks:** 3 = UAV (minimap sweep pings), 5 = Airstrike (marked target, voxel jets scream overhead), 7 = Attack Chopper (orbiting gunship, player-designated). Slots 4/5/6, MW2 ladder rules.
- **Weapons read like MW2 silhouettes** (AR/SMG/shotgun/LMG/sniper/pistol) translated into voxels — recognizable at a glance.

### Audio language
Procedural, punchy, dry. Gunshots crack (not boom) except the LMG/sniper. Reloads are two-beat foley (mag out / mag in). Hitmarker *tick*, headshot *ding*, kill-confirm *thunk*. Killstreak-ready is a radio chirp + "UAV standing by." Forge success/fail are fabrication *whirs* vs error *buzz*. Ambient: wind loop + distant drone. All SFX synthesized by `tools/gen_audio.py` (stdlib only) — no binary assets, no licensing risk.

### UI language
Tactical-military minimal: stencil-ish headers, thin brackets around panels, amber/orange (`ff7b1c`) accents on dark metal (`23262a`). HUD = bottom-left health/armor, bottom-right ammo (big mag / small reserve), top-center wave + enemies remaining, top-right killstreak slots, center hitmarker layer, killfeed top-right under streaks. Damage direction indicator (red arc). No clutter: if it doesn't help you kill or forge, it doesn't ship.

### Copy tone
Terse radio chatter. FORGE: "Fabricating. Stand by." / "Budget insufficient, operative." Director taunts are dry, never cheesy: "Noted your rooftop habit. Correcting." Killstreak callouts: "UAV online." / "Danger close."

---

## 5. Voxel art direction ("Modern Voxfare 2")

- **Everything is cubes.** Voxel pitch `VOXEL_S = 0.125 m`; chunkier props use `VOXEL_M = 0.25 m`. Palette is frozen in `VoxelBuilder.PALETTE` (gunmetal, darkmetal, tan, rust, concrete, wood, canvas, olive, forge orange, portal blue/orange, skin, shirt green).
- **Weapons:** viewmodels built in code via `VoxelBuilder` (MW2 silhouettes, blocky) — zero binary art needed.
- **Enemies:** voxel soldiers (grunt/rusher/marksman/juggernaut brute) with procedural blocky limb animation — cheap, readable at distance, charmingly brutal.
- **Map:** "Dustline" shantytown — static voxels batched via **MultiMeshInstance3D with per-instance colors**; collision is simplified invisible boxes (never per-voxel physics).
- **Destructibility:** cover fractures into **pooled physics cubes** (`DebrisPool`, cap ~120 RigidBody3D cubes) — the money shot of the art style.
- **Performance (Android):** Mobile renderer, no GI, MSAA off, directional shadow 2048, ETC2/ASTC texture compression, <200 draw calls target. Voxels batch; debris pools; particles are capped.

---

## 6. Systems summary

| # | System | Owner file(s) | Notes |
|---|--------|---------------|-------|
| 1 | Project setup / bootstrap | `project.godot`, `scenes/main.tscn`, `scripts/core/{main,game_state,voxel_builder,tuning}.gd` | This worker. Autoloads Game/Sfx/Forge. |
| 2 | Player controller | `scripts/player/` | Sprint/slide, wall-run, grapple, wrist portals, physics gun, health/regen, `add_look()`, group `player`. |
| 3 | Weapons | `scripts/weapons/` | WeaponBase (ADS/recoil/spread), 5 voxel MW2-style guns + physics gun, `explosion.detonate()`, pickups. |
| 4 | Enemies + waves | `scripts/enemies/` | grunt/rusher/marksman/juggernaut, wave_manager, `take_damage(amount, hit_position, is_headshot)`, spawn doors group. |
| 5 | Map "Dustline" | `scripts/maps/`, `scenes/maps/` | MultiMesh shantytown, destructible cover (group `cover`, `cover_point()`), `DebrisPool`. |
| 6 | HUD/UI | `scripts/ui/`, `scenes/ui/` | MW2 HUD, menus, minimap, Forge console panel. |
| 7 | Audio | `scripts/audio/`, `tools/gen_audio.py` | AudioManager autoload (`play_2d`/`play_3d`), all SFX synthesized. |
| 8 | Forge + killstreaks + director | `scripts/forge/` | DeepSeek client + offline fallback → ModSpec → voxel spawns; `submit_prompt()`; UAV/Airstrike/Chopper; director AI. |
| 9 | Android + touch | `scripts/android/`, `docs/android_export.md` | Touch controls, perf scaler, haptics, export docs. |

**Frozen contracts** (see BUILD_LOG.md): Damageable `take_damage()`, cover group + `cover_point()`, spawn-door group, player group + `add_look()`, `DebrisPool.burst()`, `Explosion.detonate()`, Game signals/funcs, Sfx `play_2d`/`play_3d`, Forge `submit_prompt()` + signals, ModSpec v1 schema, DeepSeek key in `user://forge_config.json` (never in repo).

---

## 7. FORGE ModSpec v1

Canonical schema (verbatim — the Forge builder and the DeepSeek prompt both use this):

```json
{"spec_version":1,"action":"spawn|modify|event","target":"weapon|cover|turret|pickup|enemy_mod|killstreak|arena_event","params":{},"cost":0,"ttl":0}
```

Params per target:

| target | params |
|--------|--------|
| `weapon` | `{weapon_id, stat_mods{name?}, name?}` |
| `cover` | `{shape: wall\|tower\|barricade, size_voxels: Vector3i, position: near_player\|marked\|Vector3, hp}` |
| `turret` | `{position, duration_sec}` |
| `pickup` | `{kind: ammo\|health\|armor, position}` |
| `enemy_mod` | `{mod: enrage\|weaken\|spawn_extra, enemy_type?, count?}` |
| `killstreak` | `{streak: uav\|airstrike\|chopper, target: marked\|auto}` |
| `arena_event` | `{event: smoke\|supply_drop, duration_sec?}` |

### Examples

1. **Emergency wall** (prompt: "wall in front of me"):
```json
{"spec_version":1,"action":"spawn","target":"cover","params":{"shape":"wall","size_voxels":[8,6,2],"position":"near_player","hp":300},"cost":40,"ttl":120}
```
2. **Sniper tower** (prompt: "build me a tower"):
```json
{"spec_version":1,"action":"spawn","target":"cover","params":{"shape":"tower","size_voxels":[6,10,6],"position":"near_player","hp":600},"cost":90,"ttl":180}
```
3. **Sentry turret** (prompt: "turret covering the alley"):
```json
{"spec_version":1,"action":"spawn","target":"turret","params":{"position":"marked","duration_sec":90},"cost":120,"ttl":90}
```
4. **Ammo resupply** (prompt: "i need ammo"):
```json
{"spec_version":1,"action":"spawn","target":"pickup","params":{"kind":"ammo","position":"near_player"},"cost":25,"ttl":60}
```
5. **Gun tuning** (prompt: "make my rifle hit harder"):
```json
{"spec_version":1,"action":"modify","target":"weapon","params":{"weapon_id":"ar","stat_mods":{"damage_mult":1.35,"name":"FORGE-TUNED"},"name":"Longshot AR"},"cost":60,"ttl":0}
```
6. **Call the sky** (prompt: "airstrike on my mark"):
```json
{"spec_version":1,"action":"spawn","target":"killstreak","params":{"streak":"airstrike","target":"marked"},"cost":150,"ttl":0}
```
7. **Chaos option** (prompt: "make them angry"):
```json
{"spec_version":1,"action":"spawn","target":"enemy_mod","params":{"mod":"enrage","count":4},"cost":50,"ttl":45}
```
8. **Smoke cover** (prompt: "smoke the courtyard"):
```json
{"spec_version":1,"action":"spawn","target":"arena_event","params":{"event":"smoke","duration_sec":20},"cost":35,"ttl":20}
```

Rules: every spec has a `cost` (deducted from Forge budget; rejected if unaffordable), `ttl` 0 = permanent for the run. The offline keyword fallback produces these from templates; DeepSeek produces them from the system prompt. The builder validates `spec_version` and target/params before spawning anything — malformed specs fail closed with "Fabrication rejected."

---

## 8. Director AI rules

The Director watches rolling player behavior and retools each wave. Rules (v0.1):

- **Camping** (player displacement < 8 m over 20 s) → +rushers, +flank spawns from side doors, marksman pressure on the camp spot.
- **Sniping** (majority of kills beyond 40 m) → smoke arena events on sightlines, +marksmen duels, rushers probe the nest.
- **Turtling** (player behind cover > 60% of wave) → +grenadiers (arc explosives over cover), airstrike-equivalent mortar on the turtle position (telegraphed).
- **Grapple/portal abuse** (high vertical mobility) → juggernaut brute with anti-air swat, enemies spread to deny zip lines.
- **Forge spam** (many turrets) → enraged rushers target turrets first.
- Mercy rule: after 2 consecutive wave wipes on the same wave number, the Director eases off (fewer elites, +supply drop) — the proving ground wants data, not a corpse.

---

## 9. Controls

| Action | Desktop (testing) | Android (touch) |
|--------|-------------------|-----------------|
| Move | WASD / arrows | Left virtual stick |
| Jump | Space | JUMP button |
| Sprint | Shift | Stick pushed to edge |
| Crouch / Slide | C / Ctrl | CROUCH button |
| Fire | Mouse left | Right trigger button |
| ADS | Mouse right | ADS toggle button |
| Reload | R | Auto + RELOAD button |
| Grapple | Mouse middle / G | HOOK button |
| Portal blue / orange | Q / E | BLUE / ORNG wrist buttons |
| Forge console | T / / | FORGE button |
| Killstreaks 1/2/3 | 4 / 5 / 6 | Killstreak bar slots |
| Interact | F | Context prompt button |
| Pause | Esc / P | Pause icon |

Full input map lives in `project.godot` (`[input]`, deadzone 0.2).

---

## 10. Roadmap

- **v0.1 — Scaffold (now):** project config, bootstrap, autoloads, VoxelBuilder, tunables, input map, export presets, design docs. All 9 workers land their subsystems.
- **v0.2 — First playable:** Dustline loads, player moves/shoots, one enemy type, wave 1 completable on desktop. Coordinator integration pass.
- **Colin playtest #1:** desktop build → notes → iteration. He is the real QA; his one-line directives are the spec.
- **v0.3 — Full loop:** all 4 enemy types, waves + Director, Forge console (offline fallback first), killstreaks 3/5/7, MW2 HUD.
- **v0.4 — Android:** touch controls, perf scaler, export APK, device playtest, haptics.
- **v0.5+ — Polish:** DeepSeek live path hardened, more Forge recipes, map dressing, audio mix pass, balance from playtest data.

**Non-goals for v0.x:** multiplayer, story campaign, non-voxel art, iOS.

## 11. Auto-updater (in-game APK updates)

Colin never hunts for APK links again. On every launch the game checks
`https://forgefall-updates.netlify.app/version.json` (base URL in
`Tuning.UPDATE_BASE_URL`; empty = updater fully disabled):

```json
{"version_code": 4, "version_name": "0.1.3",
 "apk_url": "https://forgefall-updates.netlify.app/forgefall-v0.1.3-debug.apk",
 "changelog": "..."}
```

If the remote `version_code` beats the installed one, a modal dialog offers
[DOWNLOAD UPDATE] / [LATER]; download shows a cancellable progress bar, then
[INSTALL NOW]. The dialog only ever appears over the main menu, never
mid-gameplay; Options has a CHECK FOR UPDATES button for manual checks.

Install plumbing is the `ForgeUpdater` Android plugin (v2): it reads the
installed version code, provides a private updates directory, and installs via
the PackageInstaller Session API (`REQUEST_INSTALL_PACKAGES`; if the user
hasn't allowed unknown-app installs, the game deep-links them to the toggle
first). Truly silent install is impossible for a sideloaded app
(docs-verified), so every session commits with USER_ACTION_REQUIRED: the
system shows ONE native "Install update?" dialog, in-app, no browser detour.
Without the plugin the updater degrades gracefully — version compare uses
`Tuning.FALLBACK_VERSION_CODE` and INSTALL NOW opens the APK in the browser.

Hosting history: a Tailscale file server was planned first, then verified
impossible (the build VM has no Tailscale interface and can't accept inbound
connections). Netlify static hosting won instead. Publishing a version is:
bump `version/code`+`version/name` in `export_presets.cfg` (sync
`FALLBACK_VERSION_CODE`), build, copy the APK to `updates/`, upload it, and
publish a new `version.json` — see `updates/PUBLISH.md`.

VM caveat (2026-10-12, resolved for v0.1.3): the Gradle daemon cannot
communicate on the build VM — root-caused to the sandbox transparently
intercepting loopback TCP from Java clients (a Java client connecting to a
Java server on 127.0.0.1 receives the proxy bytes `muse: Other TCP conn`,
which Gradle's protocol chokes on as "Unexpected type tag 109"). Gradle is
fundamentally unusable here, in every mode. The v0.1.3 build instead uses a
custom export template (`/home/hatch/workspace/apkmod/template-debug.apk`):
the stock 4.7.2 `android_debug.apk` patched with apktool (added
`REQUEST_INSTALL_PACKAGES` + the `org.godotengine.plugin.v2.ForgeUpdater`
meta-data to the manifest) plus the plugin's dexed classes as `classes2.dex`.
Preset is `use_gradle_build=false` + `custom_template/debug` → that template,
so VM-built APKs DO ship the plugin and install in-app.
