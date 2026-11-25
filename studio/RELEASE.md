# Forgefall Studio release checks

The Studio source project targets Godot 4.7.2. Export presets are in `export_presets.cfg`. Install the matching **standard** Godot 4.7.2 export templates before exporting. The Linux and Web debug presets were exercised locally with the official templates; the built files are kept under `builds/studio/` in this workspace and are not a release upload.

```sh
GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64
"$GODOT" --headless --path studio --export-release 'Linux x86_64' "$PWD/builds/studio/linux/ForgefallStudio.x86_64"
"$GODOT" --headless --path studio --export-release Web "$PWD/builds/studio/web/index.html"
```

Run the standalone desktop package with `builds/studio/linux/launch.sh`; keep `ForgefallStudio.x86_64` and `ForgefallStudio.pck` together. Serve the Web output over HTTP, rather than opening `index.html` as a local file. For example: `python3 -m http.server 8765 --bind 127.0.0.1 --directory builds/studio/web`.

## Optional AI proposals

Open a map and choose **AI Assist**. Offline use works by pasting a response JSON object into the response field and pressing **Preview JSON**. For a provider, enter its HTTPS proposal endpoint (or a localhost HTTP endpoint), type a prompt, optionally choose a PNG/JPEG/WebP image up to 4 MiB, and press **Request**. An optional bearer token is read only from `FORGEFALL_STUDIO_AI_TOKEN`; the default endpoint can be set in `FORGEFALL_STUDIO_AI_ENDPOINT`. Neither is saved in Studio documents or settings. The request sends the current map, prompt, and optional base64 image to the endpoint only when Request is pressed. Treat the endpoint as a service you trust with that content.

The endpoint receives JSON with `schema: "forgefall-studio-proposal-v1"`, `prompt`, `map`, and optional `image_data_url`. It returns a JSON object with `actions` (or `proposal.actions`). Supported actions are `add_block` (`name`, `position`, optional `size` and `color`), `move_instance` (`id`, `position`), `recolor_instance` (`id`, `color`), and `rename_instance` (`id`, `name`). Positions and sizes are three-number arrays; colors are `#RRGGBB`. Studio validates all actions against the current map, shows a summary, refuses stale previews, and applies all accepted actions through one undoable history command. No provider is bundled or enabled by default. Live remote inference was verified 2026-11-25 with DeepSeek through the local adapter at repo `tools/studio_ai_adapter.py` (see `verify_ai_live.gd`); image proposals remain untested because the text model cannot consume images.

## Web map transfer

Web builds cannot use Godot's `FileDialog` to read arbitrary host directories. **Web Map** creates a browser map, imports a Studio map JSON from the browser file picker (or pasted JSON), and downloads the edited map as JSON. The browser flow was exercised by importing a local fixture, adding a block, downloading the JSON, and reimporting the downloaded file. Verify each download in the browser before replacing a map. Native scene generation and opening a Forgefall source directory require desktop Studio and a Godot editor executable.

## Validation boundaries

- Local headless checks cover proposal validation, preview/apply/undo/redo, voxel and asset workflows, export commands, and Linux package startup. A local browser loaded the Web debug build and completed the map JSON transfer round trip.
- A 32×32×32 solid voxel fixture meshed into eight chunks in roughly 147 ms after the occupancy-key optimization (roughly 472 ms before); a 500-block map preview refresh took roughly 23 ms on the same headless run. These are local timings, not frame-rate guarantees.
- The current machine is a Steam Deck host with a Debian work container. Steam Controller event devices were visible on the host, but physical trackpad, stick, touch, and button behavior was not exercised by a human in this check. On-device Steam Input validation remains open.
- Web map JSON transfer is narrower than desktop authoring: library assets, native publication, project directory selection, and game playtesting require the desktop workflow. Web browser rendering and JSON round trip do not establish full Web feature parity.

## Final integrated rebuild (2026-10-21)

After the Stage 1 and Stage 4 source changes, both workspace packages were rebuilt from current source with Godot 4.7.2 `--export-release`. The packages were rebuilt again after adding a JSON copy fallback. Each Linux and Web export exited 0 without script errors. `builds/studio/linux/launch.sh --headless --quit-after 30` exited 0. The rebuilt Web `index.html`, `index.wasm`, and `index.pck` each returned HTTP 200 from a localhost server. In a root browser session, the integrated Web build loaded, created a map, added a block, and reported a download request from **Save JSON**; however, no file appeared in Downloads and the browser download event did not fire. A preceding browser session successfully downloaded and reimported an edited map, so download delivery varies across these browser sessions. The final package now places the current map JSON in the transfer dialog whenever Save JSON is pressed and tells the user to copy it into a `.json` file if the browser suppresses the download. The final rebuilt Web package was reloaded in the root browser session; **Web Map → New Map → Download current map** displayed formatted JSON and the copy fallback message. Verify that the file exists or copy the displayed JSON before replacing a map; the UI cannot confirm whether the browser delivered a download.

### Artifact refresh after final asset and content changes

The Stage 2 smooth/layer/collision/attachment updates, Stage 5 lift fix, and visible-house acceptance guard were included in a final `--export-release` rebuild. Both Linux and Web exports exited 0 without script errors. The Linux launcher again exited 0 in a headless startup check. Linux executable/PCK timestamps: 2026-10-21 14:00:50 -0700; Web HTML/WASM/PCK timestamps: 2026-10-21 14:00:58 -0700. No browser round trip was repeated after this refresh because the Web transfer code did not change; the JSON copy fallback result and browser download limitation above still apply.
