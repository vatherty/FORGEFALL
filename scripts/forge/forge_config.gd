# FORGEFALL — ForgeConfig (Worker 8: Forge system)
# Reads/writes the player's DeepSeek API key. The key lives ONLY in
# user://forge_config.json on the player's device — never in the repo,
# never in logs, never in chat. load_key() returns "" when absent, in which
# case ForgeLLM runs its offline keyword-matcher fallback so the Forge
# always works end-to-end on day one.
extends RefCounted
class_name ForgeConfig

const CONFIG_PATH := "user://forge_config.json"
const KEY_FIELD := "deepseek_api_key"


## Returns the stored DeepSeek key, or "" when missing/unreadable/invalid.
static func load_key() -> String:
	if not FileAccess.file_exists(CONFIG_PATH):
		return ""
	var text := FileAccess.get_file_as_string(CONFIG_PATH)
	if text.strip_edges().is_empty():
		return ""
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return ""
	return str((data as Dictionary).get(KEY_FIELD, "")).strip_edges()


## Persists a key for later runs. Called from the options UI (not the Forge).
static func save_key(key: String) -> Error:
	var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({KEY_FIELD: key.strip_edges()}))
	var result := file.get_error()
	file.close()
	return result
