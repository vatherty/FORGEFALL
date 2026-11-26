# Studio as an MCP server — let your subscription agent drive the editor

Forgefall Studio can run as a **Model Context Protocol (MCP) server**. While
it is enabled, an external AI agent — Muse, Codex, or any other MCP
client — connects to the running Studio over HTTP on your own machine and can
see and edit the map you have open.

Why: those agents usually run on a **subscription you already pay for**. With
Studio as an MCP server, the agent subscription you have is the only bill —
no separate metered API key needed just to edit maps. (If you would rather
use an API key, the AI Assist window + `tools/studio_ai_adapter.py` remain
available; see `tools/AI_PROVIDERS.md`. The two paths share the same
validated action vocabulary and the same undo history.)

## Enabling it

- **Toolbar:** click **MCP: Off** in Studio's toolbar. It becomes
  **MCP: On :8772** and the status line shows the endpoint. Click again to
  turn it off. The server is **off by default** every launch.
- **Port:** default `8772`, changeable via the `workspace/mcp_port` key in
  Studio's `studio_settings.cfg`.
- **Agent-driven sessions:** set the environment variable
  `FORGEFALL_STUDIO_MCP_PORT=8772` before launching Studio and the server
  auto-starts on that port.

Endpoint: **`http://127.0.0.1:8772/mcp`** (Streamable HTTP, protocol
`2025-03-26`). A plain `GET http://127.0.0.1:8772/` answers with the server
name and status, handy for checking it is up.

## Tools the agent gets

| Tool | What it does |
| --- | --- |
| `studio_get_state` | Editor state: project open?, map name/id, instance count, selected instance, gizmo mode. |
| `studio_list_instances` | Every instance in the open map: id, name, kind, color, position, size. |
| `studio_get_map` | The full open map document as JSON. |
| `studio_apply_actions` | Apply 1–32 validated actions as **one undoable command**: `add_block`, `move_instance`, `recolor_instance`, `rename_instance`. |
| `studio_capture_view` | A PNG of Studio's 3D viewport, so the agent can *see* the map it is editing. |
| `studio_save` | Save the open map through Studio's normal save path. |

## Connecting a client

Muse:

```sh
Muse mcp add --transport http forgefall-studio http://127.0.0.1:8772/mcp
```

Codex — add to `~/.codex/config.toml`:

```toml
[mcp_servers.forgefall-studio]
url = "http://127.0.0.1:8772/mcp"
```

Then, in your agent session, just ask it to work on the open map — e.g.
*"Use the forgefall-studio tools: look at the current view, then build a
small watchtower at the north edge."* The agent reads the state and instance
list, looks at the capture, applies actions, and can check its work with
another capture.

## Security, honestly

- The server binds **127.0.0.1 only** — nothing off your machine can reach it.
- It is **off by default**; you turn it on per session from the toolbar.
- It has **no authentication**: while it is enabled, **any local process**
  (not just your agent) can call the tools and edit the open map. Only
  enable it while you are actively working with an agent, and turn it off
  when you are done.
- The blast radius is deliberately small: agents can only use the six tools
  above, edits are restricted to the same four validated action types AI
  Assist uses (nothing outside that vocabulary can be applied), and **every
  apply is a single undoable command** in Studio's history — Ctrl+Z reviews
  or reverts anything an agent did. Saving still goes through Studio's
  normal save path, including its on-disk conflict checks.
