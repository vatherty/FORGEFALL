# Studio AI adapter — provider wiring

`studio_ai_adapter.py` is the endpoint Studio's AI Assist talks to
(`http://127.0.0.1:8771`). It can use **any** of:

- the original DeepSeek connector CLI (default when nothing is configured),
- any **OpenAI-compatible** chat-completions API (DeepSeek direct, OpenAI,
  OpenRouter, Ollama, LM Studio, KoboldCPP, …),
- any **Anthropic-compatible** Messages API (Anthropic direct, proxies, …),
- any **MCP server** (Model Context Protocol, stdio or HTTP) that exposes a
  chat-style tool — local AI frontends, agent harnesses, hosted MCP endpoints.

## Switching provider

Point the adapter at a JSON config file with the environment variable
`FORGEFALL_AI_CONFIG`, then (re)start the adapter:

```sh
FORGEFALL_AI_CONFIG=~/forgefall-ai/providers.json python3 studio_ai_adapter.py --port 8771
```

On the Steam Deck the adapter runs as the `forgefall-ai-adapter.service`
systemd user service; the config path is set in its unit file.

## Config fields

| Field | Meaning |
| --- | --- |
| `provider` | `"openai"`, `"anthropic"`, or `"deepseek-cli"` |
| `base_url` | API root. OpenAI-style: the adapter appends `/chat/completions`. Anthropic-style: it appends `/v1/messages` (or `/messages` if the base already ends in `/v1`). |
| `model` | Model id the provider expects. |
| `api_key_file` | Path to a file containing only the key (preferred; keep it mode 600). |
| `api_key_env` | Name of an environment variable holding the key. |
| `api_key` | The key inline (works, but a key file is tidier). |
| `max_tokens`, `temperature` | Optional; defaults 1500 / 0.1. |
| `json_mode` | OpenAI-style only; default `true` sends `response_format: {"type": "json_object"}`. Set `false` for servers that reject it. |
| `extra` | OpenAI-style only; an object merged into the request body (e.g. provider-specific switches). |

Key resolution order: `api_key` → `api_key_env` → `api_key_file`. Local
servers that need no key (Ollama, LM Studio, KoboldCPP) simply omit all three.
The key is never printed or logged by the adapter.

Images (Studio's attach / Use Current View) are sent in each API's native
shape: OpenAI-style `image_url` data-URL parts, Anthropic-style base64 image
blocks. Grounding (scene catalog, action vocabulary, coordinates) is added by
the adapter for every provider.

## Examples

DeepSeek direct API (what the Steam Deck service uses):

```json
{
  "provider": "openai",
  "base_url": "https://api.deepseek.com",
  "model": "deepseek-flash",
  "api_key_file": "/home/deck/forgefall-ai/deepseek.key",
  "extra": {"thinking": {"type": "disabled"}}
}
```

Anthropic:

```json
{
  "provider": "anthropic",
  "base_url": "https://api.anthropic.com",
  "model": "claude-sonnet-4-5",
  "api_key_file": "/home/deck/forgefall-ai/anthropic.key"
}
```

OpenAI:

```json
{
  "provider": "openai",
  "base_url": "https://api.openai.com/v1",
  "model": "gpt-4o-mini",
  "api_key_env": "OPENAI_API_KEY"
}
```

Local Ollama on the same machine (no key):

```json
{
  "provider": "openai",
  "base_url": "http://localhost:11434/v1",
  "model": "gemma3:4b",
  "json_mode": false
}
```

Original behaviour (DeepSeek via the connector CLI, VM only):

```json
{ "provider": "deepseek-cli" }
```

## MCP provider

With `"provider": "mcp"` the adapter speaks the Model Context Protocol to a
server you choose, and calls one of its tools per proposal. This is the
"any AI at all" escape hatch: if a frontend or harness exposes an MCP tool
that takes a prompt and returns text, Studio can use it as its brain.

```json
{
  "provider": "mcp",
  "model": "optional-model-name",
  "mcp": {
    "transport": "stdio",
    "command": ["python3", "/path/to/your_mcp_server.py"],
    "tool": "chat"
  }
}
```

HTTP (streamable) transport instead:

```json
{
  "provider": "mcp",
  "mcp": {
    "transport": "http",
    "url": "http://127.0.0.1:9000/mcp",
    "tool": "chat",
    "headers": {"Authorization": "Bearer ..."}
  }
}
```

The tool is called with these arguments:

| Argument | Content |
| --- | --- |
| `prompt` | The grounded user text (scene catalog, vocabulary, coordinates, request). |
| `system` | The adapter's system prompt (output contract). |
| `image_data_url` | Only when an image is attached: the image as a data URL. |
| `model` | Only when `model` is set in the config. |

The tool must return text content containing the proposal JSON object
(`{"actions": [...]}`); surrounding prose or code fences are tolerated by the
adapter's extractor, exactly like the API providers. MCP protocol version
negotiated: `2025-03-26`; both plain-JSON and SSE replies are handled.

## Checking what is wired

`curl http://127.0.0.1:8771/` answers with the active `provider` and `model`.
