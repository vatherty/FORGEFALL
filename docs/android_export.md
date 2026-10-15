# FORGEFALL — Android Export Chain (definitive doc)

**Target:** Godot **4.7.2-stable** · package `com.sparky.forgefall` · arm64-v8a ·
min SDK 24 / target SDK 35 · Mobile renderer · landscape.
**Playtest path:** desktop Linux (same project, "Linux Desktop" preset).
Preset source of truth: `export_presets.cfg` (presets **"Android"** and
**"Linux Desktop"**, written by worker 1 — keys verified against the 4.7-stable
`EditorExportPlatformAndroid` class reference).

Official reference: https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html

---

## 1. One-time toolchain setup

### 1a. Godot editor + export templates
1. Download **Godot 4.7.2-stable** (standard, non-.NET) from
   https://godotengine.org/download — the build machine and every dev must run
   the **exact same version** the templates were exported from.
2. In the editor: **Editor → Manage Export Templates → Download and Install**.
   Wait for "Export templates installed successfully".
3. **Template mismatch is failure #1.** Symptom: `ERROR: Mismatched export
   templates` or a build that installs then instantly crashes. Fix: re-download
   templates for the exact editor version (check **Help → About** vs the
   `.tpz` version string). Never mix 4.7.x templates with a 4.7.y editor.

### 1b. OpenJDK 17
- Install [OpenJDK 17](https://adoptium.net/temurin/releases/) (Temurin 17).
  Higher JDKs also work, but the Godot docs recommend 17 for stability.
- Verify: `java -version` → `17.x`.

### 1c. Android SDK (command-line route, no Android Studio needed)
Per the official 4.x-stable docs, install with `sdkmanager`:

```bash
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"   # pick your location
mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
# unzip commandlinetools-*.zip so that bin/sdkmanager lives at:
#   $ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager
sdkmanager --sdk_root="$ANDROID_SDK_ROOT" \
  "platform-tools" \
  "build-tools;35.0.1" \
  "platforms;android-35" \
  "cmdline-tools;latest" \
  "cmake;3.10.2.4988404" \
  "ndk;28.1.13356709"
```

Versions pinned by the Godot docs (stable, verified 2026-10-05):
**Platform-Tools ≥ 35.0.0 · Build-Tools 35.0.1 · Platform android-35 ·
cmdline-tools latest · CMake 3.10.2.4988404 · NDK r28b (28.1.13356709).**
Do NOT use a distro-packaged SDK on Linux — it is usually outdated.

### 1d. Point the editor at the SDK
**Editor → Editor Settings → Export → Android:**
- **Android Sdk Path** → `$ANDROID_SDK_ROOT` (must contain `platform-tools/adb`)
- **Java SDK Path** → your OpenJDK 17 home
- **Debug Keystore** → path to the debug keystore from §2 (or leave empty and
  fill the preset fields / env vars instead)

---

## 2. Debug keystore (for on-device testing)

Generate once per dev machine:

```bash
keytool -genkeypair \
  -keystore "$HOME/.android/forgefall-debug.keystore" \
  -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass android -keypass android \
  -dname "CN=Android Debug,O=Android,C=US"
```

Then either paste the path into **Editor Settings → Export → Android →
Debug Keystore**, or fill the preset's `keystore/debug`, `keystore/debug_user`
(`androiddebugkey`), `keystore/debug_password` (`android`) fields, or export:

```bash
export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="$HOME/.android/forgefall-debug.keystore"
export GODOT_ANDROID_KEYSTORE_DEBUG_USER=androiddebugkey
export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD=android
```

Keep **Export With Debug** checked while iterating — debug builds allow USB
debugging and `adb logcat` stack traces.

## 3. Release keystore (for Colin's real install / Play Store)

Official docs command — guard this file with your life:

```bash
keytool -v -genkey -keystore forgefall-release.keystore \
  -alias forgefall -keyalg RSA -validity 10000
```

- Use only letters/numbers in the password; special characters cause errors.
- **Godot requires the keystore password and the key password to be identical.**
- Never commit the keystore or passwords to the repo (`export_presets.cfg`
  ships with these fields redacted for exactly this reason).
- Fill the preset's `keystore/release*` fields (or the
  `GODOT_ANDROID_KEYSTORE_RELEASE_*` env vars) at export time, then **uncheck
  Export With Debug**.
- Play Store uploads must be **AAB**: in the preset set
  `gradle_build/use_gradle_build=true` and `gradle_build/export_format=1`
  (AAB). Direct-to-device testing stays APK.

---

## 4. Export preset walkthrough ("Android")

Open **Project → Export…**, select **Android**. Key fields (already set in
`export_presets.cfg`; verify, don't re-derive):

| Section | Value | Notes |
|---|---|---|
| Package / Unique Name | `com.sparky.forgefall` | changing it later orphans installs |
| Version Code / Name | `1` / `0.1.0` | bump code every release |
| Architectures | **arm64-v8a only** | ship target; x86_64 is for emulators |
| Min / Target SDK | 24 / 35 | matches §1c |
| Screen / Immersive Mode | **on** | hides nav bar; true fullscreen FPS |
| Permissions | `permissions/internet=true`, `permissions/vibrate=true` | Forge DeepSeek HTTP + `Haptics.buzz()` |
| Orientation | from project: `display/window/handheld/orientation=0` (**Landscape**) | manifest gets `sensorLandscape` |
| Launcher icons | `launcher_icons/*` empty → Godot falls back to project icon | ship real 192px + 432px adaptive icons before release |

**Permissions detail.** The preset's Permissions section injects
`android.permission.INTERNET` (Forge's DeepSeek client is plain HTTPS —
without it every AI request fails silently) and
`android.permission.VIBRATE` (`Input.vibrate_handheld()` is a documented
no-op without it). Both are install-time normal permissions: no runtime
prompt needed.

---

## 5. Build & install

### One-click deploy (fastest loop)
1. Enable USB debugging on the phone (tap Build Number 7×).
2. `adb devices` → device shows as `device` (accept the RSA prompt on phone).
3. In the editor, click the **Android phone icon** (top-right, next to Play).
   Godot builds, signs (debug keystore), installs, and launches.

### Manual APK
1. **Project → Export… → Android → Export Project** → `forgefall.apk`
   (debug: keep **Export With Debug** on).
2. `adb install -r forgefall.apk` (`-r` = reinstall keeping data).
3. Logs: `adb logcat -s godot` (filter the engine tag) or
   `adb logcat | grep -i forgefall`.

### "Could not install to device"
Docs-verified cause: an app with the **same package name but a different
signing key** is already installed (e.g. debug vs release). Fix:
`adb uninstall com.sparky.forgefall`, then reinstall.

---

## 6. Landscape + refresh rate

- **Landscape:** `display/window/handheld/orientation=0` (Landscape) is set in
  `project.godot`. Verify on device: rotating the phone must not rotate the
  game; the manifest should contain `android:screenOrientation="sensorLandscape"`.
- **Refresh rate:** FORGEFALL targets a 60 fps baseline; `PerfScaler`
  (`scripts/android/perf_scaler.gd`) keeps the GPU under budget via
  `scaling_3d_scale` rather than chasing 120 Hz. On 120 Hz phones the Godot
  Android backend requests the display's native rate — confirm what you
  actually got with `DisplayServer.screen_get_refresh_rate()` (log it on boot
  in a debug build). If stuck at 60: check `display/window/vsync/vsync_mode`
  and the phone's per-app refresh-rate setting. **Do not** uncap
  `Engine.max_fps` to chase 120 on LOW-tier devices; heat-throttle will do
  worse than a stable 60.

## 7. Desktop Linux export (Colin's playtest path)

Preset **"Linux Desktop"** is configured (`export_presets.cfg` preset.1).
**Project → Export… → Linux Desktop → Export Project** → `forgefall.x86_64`,
then:

```bash
chmod +x forgefall.x86_64
./forgefall.x86_64
```

Notes:
- Touch UI auto-hides on desktop (`DisplayServer.is_touchscreen_available()`
  is false); set `force_show=true` on the TouchControls node to preview the
  touch layout with the mouse (emulate-touch-from-mouse is on by default).
- The editor's **Play** button (F5) is the faster loop for logic; export only
  to validate the real pipeline.

---

## 8. Troubleshooting

| Symptom | Cause → Fix |
|---|---|
| `SDK not found` / empty Android preset options | Editor Settings → Export → Android paths wrong. The SDK dir must contain `platform-tools/adb`. |
| Template mismatch errors | Editor and `.tpz` versions differ → **Manage Export Templates → Download and Install** again (§1a). |
| Signing errors at export | Keystore path/password/alias wrong; remember keystore password == key password (§3). |
| `Could not install to device` | Same package, different key → `adb uninstall com.sparky.forgefall` (§5). |
| `adb` shows `unauthorized` | Revoke USB debugging authorizations on the phone, re-plug, accept RSA prompt. |
| Black screen on launch | Renderer check: project uses `renderer/rendering_method="mobile"`. On ancient GPUs try the Compatibility renderer (`renderer/rendering_method="gl_compatibility"`) as a diagnostic — but Mobile is the ship target. Also check `adb logcat` for shader compile errors. |
| Touch buttons don't appear | `TouchControls` layer hidden: not a touch device and `force_show=false`; or `main.gd` never instanced `touch_controls.tscn` (see §9). |
| No vibration | VIBRATE permission missing in preset, or device has vibration disabled / DND on (both documented `vibrate_handheld()` killers). |
| Gyro does nothing | `input_devices/sensors/enable_gyroscope` must be `true` in `project.godot` (worker 1 — currently **not set**, see §9). |
| Forge AI calls fail on device | INTERNET permission missing, or no network. Test with the keyword-matcher fallback (works offline). |

## 9. Integration checklist (worker 1 / coordinator)

`scripts/core/main.gd` must wire the Android pieces (all exist; none are
autoloads by design):

```gdscript
# In main.gd _ready() (or right after the map loads in start_game()):
var touch_layer := load("res://scenes/ui/touch_controls.tscn").instantiate()
add_child(touch_layer)                       # CanvasLayer, layer 10, self-shows on touch devices

var scaler := PerfScaler.new()               # class_name in perf_scaler.gd
add_child(scaler)
scaler.auto_detect()                         # HIGH/MED/LOW from cores + RAM

var gyro := GyroAim.new()                    # class_name in gyro_aim.gd
gyro.enabled = false                         # Colin opts in via options menu
add_child(gyro)
```

`project.godot` additions needed:
```ini
[input_devices/sensors]
enable_gyroscope=true   # required for GyroAim on Android; harmless on desktop
```

## 10. Future native plugins

- **ForgeSpeech STT** (`scripts/android/speech_input.gd` documents the hook):
  build a Godot Android **v2 plugin** (Gradle) registering an Engine singleton
  named `ForgeSpeech` with `startListening()` and signal
  `onResult(text: String)`. Docs pattern:
  https://docs.godotengine.org/en/stable/tutorials/platform/android/android_plugin.html
  In the preset: `gradle_build/use_gradle_build=true`, drop the plugin under
  `addons/ForgeSpeech/`. Until then the MIC button opens the typed Forge
  console — the game is fully playable without it.
- Gyro needs **no** plugin (`Input.get_gyroscope()` is built-in).

---
*Worker 9 (android), 2026-10-05. API facts verified against
docs.godotengine.org/en/stable on 2026-10-05; assumptions are labeled inline.*
