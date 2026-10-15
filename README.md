# FORGEFALL

Voxel-styled tactical FPS for Android, Linux, and Windows, built in **Godot 4.7.2-stable** (GDScript-only, no .NET). MW2 (2009) game-feel — ADS, recoil, hitmarkers, 3/5/7 killstreaks — rendered as chunky voxels ("Modern Voxfare 2", a.k.a. MW2 directed by Minecraft). Fight militia waves on the Dustline map, forge gear live with the Forge AI console, call killstreaks, run portal puzzle chambers, and play LAN multiplayer (TDM / Domination).

Full design doc: [`DESIGN.md`](DESIGN.md). Living build log: [`BUILD_LOG.md`](BUILD_LOG.md). License: **MIT** (see [`LICENSE`](LICENSE)) — Colin's default; use it, fork it, mod it.

**Version note:** the current release is **v0.5.0** with **version code 26**. The display name (0.5.0) and the updater's version code (26) are different numbers on purpose: the in-game updater compares the code, so the code never goes backwards. Do not "reset" the code to match the display name — that would brick updates for existing installs.

---

## Play: install a build

Prebuilt builds live on the updates site: **https://vatherty.github.io/Forgefall-updates/** — one link per platform, plus in-game updates after the first install.

| Platform | File | Install |
|----------|------|---------|
| Android | `forgefall-v0.5.0-debug.apk` | Download on the phone, open it, allow install from that source once, confirm the single native system "Install update?" dialog. |
| Windows | `forgefall-v0.5.0-windows.zip` | Unzip anywhere, run `forgefall.exe` (`forgefall.console.exe` shows a console for logs). |
| Linux | `forgefall-v0.5.0-linux.zip` | Unzip, run `./forgefall.sh` (or `chmod +x forgefall` and run the binary). |

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
