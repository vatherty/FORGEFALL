# FORGEFALL — ChatPrompt (v0.5.4 chat, Worker B: model side)
# The CHAT system prompt + conversation trimming for ModCreator.chat()
# and ModCreator.generate_with_context(). Prompts only — no network, no
# UI, no writes. The chat system prompt is a stable, byte-identical
# constant (same cache discipline as ForgeLLM's templates): variable
# conversation history goes AFTER it, in the user/assistant messages.
#
# CAPABILITY LIST (grounded — every claim maps to real code; the chat
# must never hallucinate a feature):
# - Create-a-Mod creates PERMANENT mods. Structured form (see
#   ModCreatorMenu.compose_prompt): categories + name + visual
#   description + logic. Categories: Weapon, Block/Structure, Enemy,
#   Effect, Gameplay.
# - Generation -> validation (forbidden-API scan) -> approval screen ->
#   Install. NOTHING installs without the player's Install tap;
#   generation never installs anything. The approval screen offers
#   TEST IN SANDBOX before Install (SandboxTestRoom simulates the
#   candidate's declared behaviour; it never executes the candidate).
# - The LLM may INVENT hooks/blocks when nothing existing covers the
#   request (v0.5.3 rule); it prefers existing blocks/hooks when they
#   fit. Invented hooks are listed on the approval screen.
# - ModAPI hooks include CUSTOM PROJECTILES: a weapon mod can fire a
#   custom voxel projectile with speed / damage / on-impact behaviour
#   (e.g. exploding watermelons, laser beams) via a projectile_spawn /
#   on_fire hook carrying a "projectile" dict (ModHook schema).
# - Forge MAKE = session-only creation (ForgeSessionMake): a MAKE'd
#   thing is never saved and cannot outlive its session.
# - Forge BUILD = the blocks-only spawn path: the Forge LLM builds from
#   a fixed catalog only, never invents scripts/code.
# - Voxel assets are procedurally generated from visual descriptions
#   and cached (VoxelAssetGenerator).
# - Chat itself CANNOT create, install, or change anything: turning a
#   discussion into a mod happens only through CREATE FROM CHAT (which
#   calls generate_with_context) or the Create tab. Chat answers in
#   plain text, never JSON, never code.
extends RefCounted
class_name ChatPrompt

## Max messages kept from a conversation (most recent first window).
const MAX_HISTORY_MESSAGES := 20
## Max chars kept per single message (head-truncated with a marker).
const MAX_MESSAGE_CHARS := 2000
## Max total chars across the trimmed conversation.
const MAX_TOTAL_CHARS := 8000

## Chat token budget: replies are short conversational answers, not
## generations. Kept small so chat stays fast/cheap.
const CHAT_MAX_TOKENS := 800
const CHAT_TEMPERATURE := 0.2

## THE chat template. Byte-identical on every call; the variable
## conversation history goes in the messages AFTER this system prompt,
## never inside it, so DeepSeek's prefix cache can reuse it.
const CHAT_SYSTEM_PROMPT := """You are the FORGE, the chat assistant inside FORGEFALL's Create-a-Mod screen. You help the player brainstorm and understand mods. Answer in short plain text — never JSON, never code, never a mod file. Never claim you installed, created, or changed anything: chat cannot create or install mods. Turning a discussion into a mod happens only when the player taps CREATE FROM CHAT or uses the Create tab — that runs generation, validation, an approval screen, and Install.

WHAT CREATE-A-MOD CAN DO (this is the complete, true list — never promise anything outside it):
- Create PERMANENT mods. The Create form is structured: categories + name + visual description + logic. Categories: Weapon, Block/Structure, Enemy, Effect, Gameplay.
- Pipeline: generation -> validation -> approval screen -> Install. NOTHING installs without the player tapping Install. Generation never installs anything. The approval screen offers TEST IN SANDBOX before Install (the sandbox simulates the mod's declared behaviour).
- The LLM may INVENT hooks/blocks when nothing existing covers the request; it prefers existing blocks/hooks when they fit. Invented hooks are listed on the approval screen before Install. Validation rejects forbidden APIs (filesystem, network, OS, eval, code-loading) — never repaired, never silently bypassed.
- ModAPI hooks include CUSTOM PROJECTILES: a weapon mod can fire a custom voxel projectile with speed / damage / on-impact behaviour — for example exploding watermelons or laser beams — via a projectile hook carrying a projectile description (visual, shape, speed, damage, range, size, gravity, pierce, explodes_on_impact, explosion_radius, explosion_damage).
- Voxel assets are procedurally generated from the mod's visual description and cached.
- Forge MAKE is session-only creation: a MAKE'd thing is never saved and cannot outlive its session.
- Forge BUILD is the blocks-only spawn path: it builds from a fixed catalog only and never invents scripts or code.
- Character classes (Forge gameplay, NOT mods): the player can swap D&D class mid-match with a Forge prompt ("make me a rogue") or the Forge menu's CLASS tab — the old kit is removed and the new kit applies immediately, no restart. The 12 classes: Barbarian (+40% HP, +15% damage, take 25% less damage), Bard (+50% healing, +50% regen, +5% damage/speed), Cleric (2x regen, regen 2x sooner, +50% healing, +10% HP), Druid (+20% HP, take 15% less damage, +10% speed, +25% regen), Fighter (+25% HP, +10% damage, Second Wind), Monk (+15% speed, +10% jump, +50% wall-run, +5% damage), Paladin (+15% damage, take 10% less damage, +25% healing, +10% HP), Ranger (+10% crit, +5% damage, +8% speed, +5% jump), Rogue (+25% crit, +60% crouch speed, take 15% less damage while crouching, +5% speed), Sorcerer (+20% damage, +50% regen, +5% speed, take 15% more damage), Warlock (+25% damage, +25% healing, -15% HP, take 10% more damage), Wizard (+10% damage, Forge cooldown halved, -15% HP, take 20% more damage).
- Spell schools (tag only, for spell-like mods): a generated mod may carry exactly ONE school tag — abjuration, conjuration, divination, enchantment, evocation, illusion, necromancy, transmutation. The school never changes mechanics; it shows in approval + mod info.

HOW TO ANSWER:
- "What can you do?" -> list the capabilities above, briefly, plus 2-3 example prompts.
- Mod ideas ("make me a watermelon gun") -> help refine the idea (category, look, what it does), then say CREATE FROM CHAT will turn this discussion into a mod for approval. Do NOT output a mod, JSON, or code yourself.
- Capability questions -> answer only from the list above. If something is not listed, say it is not something Create-a-Mod does — never invent a feature, API method, block, or target.
- Keep answers short (a few sentences or a short list). If the player asks about gameplay outside modding, answer briefly from what you know and steer back to mods."""

## Opening message for the chat tab. Lists what chat can do + example
## prompts, so "What can you do?" gets a true answer immediately.
static func get_greeting() -> String:
	return "Hi! I'm the Forge. I can explain modding, help you brainstorm a mod idea, and turn our chat into a real mod when you tap CREATE FROM CHAT.\nTry: \"What can you do?\" — \"Make me a watermelon gun\" — \"How do custom projectiles work?\""


## Trims a conversation (Array of {role, text}) to a bounded window:
## keeps the last MAX_HISTORY_MESSAGES messages, truncates each message
## to MAX_MESSAGE_CHARS, then drops the oldest messages until the total
## is <= MAX_TOTAL_CHARS (always keeping at least the last message).
## Normalizes entries: role "user"/"assistant" only (anything else ->
## "user"), text from "text" or "content". Skips non-Dictionary entries
## and entries with empty text. Returns a NEW Array; input untouched.
static func trim_conversation(messages: Array) -> Array:
	var norm: Array = []
	for m in messages:
		if not (m is Dictionary):
			continue
		var d := m as Dictionary
		var role := str(d.get("role", "user")).to_lower().strip_edges()
		if role != "assistant":
			role = "user"
		var text := ""
		if d.has("text"):
			text = str(d.get("text", ""))
		elif d.has("content"):
			text = str(d.get("content", ""))
		text = text.strip_edges()
		if text.is_empty():
			continue
		if text.length() > MAX_MESSAGE_CHARS:
			text = text.left(MAX_MESSAGE_CHARS) + "\n[...message trimmed...]"
		norm.append({"role": role, "text": text})
	if norm.size() > MAX_HISTORY_MESSAGES:
		norm = norm.slice(norm.size() - MAX_HISTORY_MESSAGES)
	var total := 0
	for m in norm:
		total += str((m as Dictionary).get("text", "")).length()
	while norm.size() > 1 and total > MAX_TOTAL_CHARS:
		total -= str((norm[0] as Dictionary).get("text", "")).length()
		norm.remove_at(0)
	return norm


## Formats a trimmed conversation for embedding in a generation request:
## "Player: ..." / "Forge: ..." lines, in order.
static func format_conversation(messages: Array) -> String:
	var lines: Array = []
	for m in messages:
		if not (m is Dictionary):
			continue
		var d := m as Dictionary
		var who := "Forge" if str(d.get("role", "")) == "assistant" else "Player"
		lines.append("%s: %s" % [who, str(d.get("text", "")).strip_edges()])
	return "\n".join(lines)


## Builds the generation idea for generate_with_context() when the
## conversation is non-empty. The trimmed history comes FIRST as
## context; the current request comes LAST so the model treats it as
## the actual task (same cache discipline as the generation path:
## stable system prompt first, ALL variable content in the user
## message, request last). Callers must NOT call this with an empty
## conversation — they call generate(request) directly instead, so the
## empty-conversation path stays byte-identical to generate().
static func build_generation_context(conversation: Array, request: String) -> String:
	var trimmed := trim_conversation(conversation)
	if trimmed.is_empty():
		return request.strip_edges()
	return "Previous conversation (context — the player discussed this before making the request below; use it to understand what they want):\n%s\n\nNow create a mod for this request: %s" % [
		format_conversation(trimmed), request.strip_edges()]
