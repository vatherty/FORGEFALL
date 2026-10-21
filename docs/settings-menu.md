# Shared settings menu

Open SETTINGS from the main menu or pause screen. The mod workshop also has an
AI SETTINGS shortcut. Changes apply immediately and persist on this device.

- Controls: look sensitivity, ADS multiplier, invert vertical aim, and existing
  keyboard/controller rebinding (including controller dead zone).
- Audio: master, music/ambience, sound effects, and menu volume. Zero mutes.
- Display: field of view, resolution quality, vertical sync, and fullscreen.
  Browser-controlled display options are disabled on Web.
- Mobile: touch look sensitivity, button opacity, and supported-device vibration.
- Effects: screen-filter enable/disable, five looks, intensity, lightweight mode,
  and optional lens, grain, vignette, fringing and scanline treatments.
- Forge AI: masked DeepSeek key entry, show entered key, save, and remove.

The DeepSeek key is saved separately in `user://forge_config.json`; both online
Forge requests and mod creation already read this shared store on each request.
A new key takes effect without restarting. Keys are never included in this source
archive. Credentials are not encrypted at rest; browser storage can be cleared.
Saving does not validate a key or spend API credits. Offline Forge presets remain
available without a key. Resetting game settings preserves the key and bindings.

Settings use `user://forge_settings.cfg`, preserving existing map/mode choices.
The shared Preferences autoload applies saved settings at startup and to players
spawned later. Mobile controls, player aim/FOV, audio buses and desktop display
settings respond to changes while playing. The new settings panel scrolls and
adjusts text/target sizes for the stretch canvas on phones.

Validation with Godot 4.6.3:

- `verify_settings.gd`: 17 checks passed (uses isolated temporary user storage).
- A separate process confirmed saved sensitivity loads after restart.
- `verify_touch_aim.gd`: 21 checks passed.
- `verify_creator_chat.gd`: 43 passed, 2 skipped.
- 120-frame boot: no script errors.
- Desktop renders at 1280x720 and 844x390 are included as layout previews.

Run isolated settings tests with:

```sh
XDG_DATA_HOME=/tmp/forge-settings-verification godot --headless --path . --script res://tools/verify_settings.gd
XDG_DATA_HOME=/tmp/forge-settings-verification godot --headless --path . --script res://tools/verify_settings.gd -- --reload
```

No real DeepSeek key or billable API call was used in verification. Mobile
browser/device testing and actual API authentication remain to be checked.
