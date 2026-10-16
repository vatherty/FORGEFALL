# FORGEFALL

Voxel-styled tactical FPS for Android, Linux, and Windows, built in **Godot 4.7.2-stable** (GDScript-only, no .NET). MW2 (2009) game-feel — ADS, recoil, hitmarkers, 3/5/7 killstreaks — rendered as chunky voxels ("Modern Voxfare 2", a.k.a. MW2 directed by Minecraft). Fight militia waves on the Dustline map, forge gear live with the Forge AI console, call killstreaks, run portal puzzle chambers, and play LAN multiplayer (TDM / Domination).

Full design doc: [`DESIGN.md`](DESIGN.md). Living build log: [`BUILD_LOG.md`](BUILD_LOG.md). License: **MIT** (see [`LICENSE`](LICENSE)) — Colin's default; use it, fork it, mod it.

**Version note:** the current release is **v0.5.4** with **version code 30**. The display name (0.5.4) and the updater's version code (30) are different numbers on purpose: the in-game updater compares the code, so the code never goes backwards. Do not "reset" the code to match the display name — that would brick updates for existing installs.

---

## Play: install a build

Prebuilt builds live on the updates site: **https://vatherty.github.io/Forgefall-updates/** — one link per platform, plus in-game updates after the first install.

| Platform | File | Install |
|----------|------|---------|
| Android | `forgefall-v0.5.4-debug.apk` | Download on the phone, open it, allow install from that source once, confirm the single native system "Install update?" dialog. |
| Windows | `forgefall-v0.5.4-windows.zip` | Unzip anywhere, run `forgefall.exe` (`forgefall.console.exe` shows a console for logs). |
| Linux | `forgefall-v0.5.4-linux.zip` | Unzip, run `./forgefall.sh` (or `chmod +x forgefall` and run the binary). |

After the first install, the game checks for updates on launch and offers Download → Install from inside the game (Android: one native system dialog; PC: a helper script swaps the files and relaunches). No account, no launcher.

## Controls

Full input map lives in `project.godot` (`[input]`, deadzone 0.2).

| Action | Desktop (keyboard + mouse) | Android (touch) | Gamepad (Xbox-style / Steam Deck) |
|--------|-------------------|-----------------|----------------------------------|
| Move | WASD / arrows | Left virtual stick | Left stick |
| Look | Mouse | Drag right side | Right stick |
| Jump | Space | JUMP button | A |
| Sprint | Shift | Push stick to edge | L3 (stick click) |
| Crouch / Slide | C / Ctrl | CROUCH button | B |
| Fire | Mouse left | FIRE trigger button | RT |
| ADS | Mouse right | ADS toggle button | LT |
| Reload | R | RELOAD button (auto-reload also on) | X |
| Grapple | Mouse middle / G | HOOK button | LB |
| Portal blue / orange | Q / E | BLUE / ORNG wrist buttons | — (use keyboard/touch) |
| Forge console | T / / | FORGE button | RB |
| Killstreaks 1 / 2 / 3 | 4 / 5 / 6 | Killstreak bar slots | — (use keyboard/touch) |
| Interact | F | Context prompt button | Y |
| Voice forge (MIC) | — | MIC button (hold to talk) | — |
| Pause | Esc / P | Pause icon | Start |
| Weapon slots 1 / 2 / 3 | 1 / 2 / 3 | — | D-pad Up / Right / Down |

Movement kit: sprint, slide, wall-run, grapple with pendulum swing, wrist portals (momentum-conserving teleport), physics gun. Forge console: type a prompt ("build a tower near me", "LMG with sniper bullets") and the Forge builds it from validated blocks — or hold MIC and say it. Optional DeepSeek key is entered **in-game** (Forge → key entry) and stored only in the device's `user://forge_config.json`; it is never in this repo.

## The AI Forge (LLM) — the biggest feature

FORGEFALL has a real LLM inside the game — not a scripted command parser. It runs on **DeepSeek** (`deepseek-flash`, thinking disabled, stable-prefix prompt caching), and it powers three ways of making things: the in-match **Forge console**, **Forge MAKE**, and **Create-a-Mod**. The Forge menu is where you build during a match; Create-a-Mod is where you make permanent things to keep.

### Forge console (in-match, typed or voice)

Press **T** / **/** (desktop), the **FORGE** button (touch), or hold **MIC** and talk. Type or say what you want — "build a tower near me", "LMG with sniper bullets", "give me a burst rifle" — and the Forge builds it from validated blocks. The LLM composes known blocks (a sniper-barreled LMG gets sniper damage, a smaller mag, and a recomputed cost — the game always recomputes cost itself, never trusts the model's numbers), and the result goes through cost preview → confirm. Ghost preview shows a translucent structure before you commit; placed structures can be moved, rotated, repaired, and deleted, and enemies can damage and destroy them. Forge builds sync to every player in LAN multiplayer. Without a key, the Forge falls back to an offline keyword parser (it knows the base weapons, the new Trident/Judge aliases, and installed mod names) — but the LLM path is the real one.

### Forge MAKE (one box, this match only)

The Forge menu also has a **MAKE** section: one prompt box, on the fly. Type an idea — "a wall that explodes when enemies touch it" is the canonical example — and it creates the thing **now, for this match**. MAKE is session-scoped: zero file writes, nothing saved, it dies with the match. Block-shaped requests (walls, weapons, turrets, pickups, structures with stats) build in-session; script-shaped requests (custom behaviors) are refused in MAKE with a message pointing to Create-a-Mod, where the same idea works as a permanent mod.

### Create-a-Mod (permanent mods you keep)

From the main menu: **CREATE A MOD** → a dedicated menu with **Create / Chat / Mods / Import-Export** tabs (Import-Export is a placeholder for later). Create-a-Mod is where you make permanent weapons, blocks, enemies, and effects that stay in your game across matches.

- **Create tab — structured form, not one text box.** Multi-choice categories (Weapon, Block/Structure, Enemy, Effect, Gameplay — a mod can be several at once), then **Name**, **Visual description**, and **Logic**. Example: an LMG that shoots watermelons, and the watermelons explode on impact.
- **Voxel assets, generated + cached.** From the visual description, the game procedurally generates the voxel model (a watermelon: striped green rind, red interior, seeds) and uses it. If an asset for that description already exists, it is reused — the cache is keyed by a hash of the normalized description, stored in `user://mods/assets/`. No downloads.
- **The LLM may invent hooks.** Create-a-Mod is *not* held to the building-blocks-only standard. If a request needs a hook or script that does not exist in the mod API, the LLM tries to create it — that is what Create-a-Mod is for. The Forge build path stays blocks-only; only the creator path may invent.
- **Custom projectiles fire in the real game.** The mod API has a projectile/fire-mode hook (`on_fire` / `projectile_spawn`, `on_hit`, `on_kill`, `on_damage_taken`): a generated weapon spawns a real projectile carrying the mod's voxel visual, speed, damage, and on-impact behavior. A Long Laser Pistol fires a beam; a watermelon LMG fires exploding watermelons. The sandbox simulates behavior the game can express, and the game expresses it.
- **Sandbox test before install.** Try a generated mod in a test room with dummies (and the candidate's projectile) before it touches your real game.
- **Approval before anything installs.** Every generated mod goes through generation → strict validation → an approval screen (plain-language summary + full payload, with invented hooks listed explicitly — "this mod adds a new hook: X") → **Install / Discard / Regenerate**. Nothing installs silently.

### Chat (talk to the creator)

The **Chat** tab sits next to Create, and it is the **same session** as the one you create a mod in. Ask it what it can do, brainstorm a weapon, argue about stats — then hit **Create** or **Create from Chat** and the model has the whole conversation as context when it generates. Its system prompt carries the true capability list (hooks, custom projectiles, invented hooks, Forge MAKE vs. Creator, sandbox, approval), so "What can you do?" gets a grounded answer, not a hallucinated one. History persists across restarts (last 20 messages, trimmed per request to keep costs bounded). Chat itself never installs anything.

### Safety model

- Generated code goes through a **strict validator** (schema + forbidden-API scan: no file/network/eval/process access, no dynamic code loading) and **human approval** before Install. A mod that errors at load or run disables itself visibly — it never crashes the game.
- **No silent fallback.** If the LLM call fails, or no key is configured, you get a visible error — never a quietly substituted template mod. (The Forge console's offline keyword parser is the one explicit exception, and it is labeled as offline.)
- **Your key stays on your device.** Enter it in-game (Forge → key entry); it is stored only in the device's `user://forge_config.json` and is never in this repo, never in a screenshot-safe place, never transmitted anywhere except the DeepSeek API call itself.

## Build / run from source

1. Install **Godot 4.7.2-stable** (standard build, *not* .NET): https://godotengine.org/download
2. Clone this repo, then in the Godot Project Manager → **Import** → select `project.godot` → **Open**. On first open the editor imports resources and builds the `.godot/` cache (class_name globals included). Wait for the import spinner to finish. (`.import` files are regenerable and not committed; the editor recreates them.)
3. **Desktop (fast iteration):** press **F5** (or ▶) with `scenes/main.tscn` as the main scene. The game boots to the main menu; "Deploy" starts the Dustline map.
4. **Headless import / smoke test** (no editor, e.g. on a build machine):
   ```bash
   ./tools/verify.sh .                 # import + optional script checks
   godot --headless --path . --quit-after 120   # boot smoke test (120 frames)
   ```
5. **Per-script parse check:** `godot --headless --path . --check-only --script res://scripts/core/voxel_builder.gd`

### Exporting

- **Linux / Windows:** Project → Export… → select the **Linux Desktop** or **Windows Desktop** preset. Export paths point at `*_staging/` dirs (gitignored build scratch).
- **Android:** full chain (JDK 17, Android SDK Platform 35, Build-Tools 35.0.1, CMake 3.10.2.4988404, NDK r28b, export templates, keystore) is documented in [`docs/android_export.md`](docs/android_export.md). Notes for this repo:
  - `export_presets.cfg` ships with **blanked keystore password fields**. Fill them locally at export time, or use the `GODOT_ANDROID_KEYSTORE_*` env vars / `.godot/export_credentials.cfg` — never commit a keystore or password. No keystore is in this repo.
  - The Android preset's `custom_template/debug` path is machine-specific (the apktool custom-template flow); leave it empty for a stock-template export.
  - The `android/` Godot build template is **not** in this repo — regenerate it in the editor (Project → Install Android Build Template) if you need it.
  - `addons/ForgeUpdater` (in-game APK install) and `addons/ForgeSpeech` (voice forge) ship as **prebuilt `.aar` plugin binaries** in their `bin/` folders — no Java/Kotlin source for them exists in this repo. They are build inputs the Android export needs, which is why they are committed. Everything else is GDScript source.

### Tests

`tools/` holds headless verification suites (`verify_*.gd`, run via `verify.sh` or Godot headless). One suite, `tools/verify_updater_pc.gd`, reads `updates/version_pc.json` — that file is generated by the publish flow (see below), so that suite's manifest section expects a published build to exist.

### Publishing a release (maintainers)

Bump `version/code` + `version/name` in `export_presets.cfg`, sync `Tuning.FALLBACK_VERSION_CODE` in `scripts/core/tuning.gd`, export all three builds, upload them plus `version.json` / `version_pc.json` / `index.html` to the updates repo behind https://vatherty.github.io/Forgefall-updates/ (builds FIRST, manifests LAST). The legacy Netlify deploy script in `tools/netlify_digest_deploy.py` is kept for reference only — current hosting is GitHub Pages. See `BUILD_LOG.md` for the per-release checklist.

## Repo layout

| Path | What it is |
|------|-----------|
| `project.godot` | Engine config, autoloads, input map |
| `scripts/` | All game code (player, enemies, weapons, Forge, net, UI, progression, portals, mods) |
| `scenes/` | Main scene + UI scenes |
| `tools/` | Audio generators (`gen_audio*.py`) + headless verify suites |
| `assets/` | Sound effects / music (`.wav`, generated by `tools/gen_audio*.py`) |
| `addons/` | ForgeUpdater + ForgeSpeech Godot plugins (GDScript + prebuilt `.aar`s) |
| `docs/` | Android export chain |
| `DESIGN.md` / `MANIFEST.md` / `BUILD_LOG.md` | Design doc, file manifest, per-release log |

Excluded from the repo (gitignored, generated locally): `.godot/`, `builds/`, `updates/`, `*_staging/`, `.apkmod/`, `*.pck`, `*.apk`, `*.zip`, `*.keystore`, `*.import`.
