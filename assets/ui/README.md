# Menu artwork

- `industrial_backdrop.png`: original AI-generated background artwork created for FORGEFALL. This is decorative title-screen art, not an in-game screenshot.
- `maps/*.png`: screenshots of FORGEFALL's map geometry, captured with neutral thumbnail lighting by `tools/capture_map_previews.gd`. Recreate with a graphics display and Godot's compatibility renderer. These previews do not load maps during menu navigation.
- `fonts/BarlowCondensed-Bold.ttf`: Barlow Condensed by Jeremy Tribby, from Google Fonts. Distributed under the SIL Open Font License; see `fonts/OFL.txt`.

## Cinematic secondary menus

`scenes/armory.png`, `scenes/workshop.png`, `scenes/staging.png`, and `scenes/chambers.png` are original generated background illustrations created for the menu redesign. They depict the game's visual direction, not the selected map, selected weapon model, or a live multiplayer roster. Functional controls and live statistics are drawn separately by Godot. The original industrial backdrop is reused for mode selection and deployment.

Pause and in-game Forge use the real gameplay camera where present. They fall back to decorative industrial artwork when previewed without a running match.

`icons/*.svg` are original vector UI glyphs for Forge build presets. The background textures are shared through Godot's resource cache; menus do not instantiate a full 3D factory to draw these backdrops.
