# FORGEFALL — SpellSchools (v0.5.8 Worker C: spell schools as tags)
# The eight D&D 5e spell schools, as TAGS for spell-like generated mods.
# TAG ONLY — a school never changes mechanics: no damage bonus, no cost
# change, no behavior change, no spell slots, no skills/feats. The game
# validates the tag (normalize: unknown -> ""), shows it in the approval
# screen, and persists it on disk in the mod payload so it survives
# install. The loader is untouched (this worker must not modify the
# validator/loader), so the loader IGNORES the persisted tag on rescan:
# it is not yet surfaced in the Forge Mods tab — that needs a loader
# change (follow-up, noted in BUILD_LOG). What the player sees today:
# approval screen ("School: Evocation — tag only...") + the payload
# itself (block wrapper key / script comment).
#
# PERSISTENCE SHAPE (written by ModCreator.install, never by the loader):
#   block mods:  payload {"block": {...}, "spell_school": "evocation"}
#   script mods: payload source starts with "# spell_school: evocation"
# Both shapes pass ModLoader.validate_generated_mod (the loader only
# validates the block / scans the script — the wrapper key is ignored,
# a comment line is inert), and parse_from_payload() below reads them
# back. The generation object also carries "spell_school" top-level;
# that is the canonical carrier from the LLM to the candidate.
extends RefCounted
class_name SpellSchools

## The eight D&D 5e spell schools (lowercase canonical).
const SCHOOLS := ["abjuration", "conjuration", "divination", "enchantment",
	"evocation", "illusion", "necromancy", "transmutation"]

## One-line flavor per school (display only — never mechanics).
const SCHOOL_BLURBS := {
	"abjuration": "protective magic — wards, shields, banishment",
	"conjuration": "summoning and calling — things brought from elsewhere",
	"divination": "knowledge magic — revealing, sensing, foresight",
	"enchantment": "mind magic — charm, compulsion, control",
	"evocation": "raw energy — fire, lightning, force unleashed",
	"illusion": "deception — phantasms, invisibility, false sense",
	"necromancy": "life and death — draining, undeath, reanimation",
	"transmutation": "change — altering form, matter, and properties",
}


## True when `s` names a school (case/whitespace-insensitive).
static func is_school(s: String) -> bool:
	return normalize(s) != ""


## Canonical lowercase school, or "" when `raw` is not a school.
## Never rejects: an unknown / empty tag degrades to untagged.
static func normalize(raw: String) -> String:
	var s := str(raw).strip_edges().to_lower()
	if s in SCHOOLS:
		return s
	return ""


## Display name ("Evocation"), "" when untagged.
static func display_name(raw: String) -> String:
	var s := normalize(raw)
	if s.is_empty():
		return ""
	return s.capitalize()


## Blurb for a school ("" when untagged).
static func blurb(raw: String) -> String:
	return str(SCHOOL_BLURBS.get(normalize(raw), ""))


## Approval-screen line for a school ("" when untagged).
static func approval_line(raw: String) -> String:
	var s := normalize(raw)
	if s.is_empty():
		return ""
	return "School: %s (%s) — tag only; schools never change mechanics." % [
		s.capitalize(), blurb(s)]


## Reads a school back out of a payload string: a block wrapper's
## "spell_school" key, or a script payload's "# spell_school: <school>"
## first-line comment. "" when none / invalid.
static func parse_from_payload(payload: String) -> String:
	var text := str(payload).strip_edges()
	if text.is_empty():
		return ""
	if text.begins_with("{"):
		var data: Variant = JSON.parse_string(text)
		if data is Dictionary:
			return normalize(str((data as Dictionary).get("spell_school", "")))
		return ""
	# Script payload: look for the "# spell_school: <school>" comment.
	var marker := "# spell_school:"
	var idx := text.find(marker)
	if idx < 0:
		return ""
	var rest := text.substr(idx + marker.length())
	var line := rest.split("\n")[0].strip_edges().to_lower()
	# Take the first word (a trailing comment or whitespace ends it).
	var token := line.split(" ")[0].strip_edges()
	return normalize(token)


## Wraps a block payload string with a school (wrapped form
## {"block": {...}, "spell_school": ...}); leaves script payloads
## untouched (the caller prepends the comment instead). Returns the
## payload unchanged when `school` is empty / invalid / unparseable.
static func wrap_block_payload(payload: String, school: String) -> String:
	var s := normalize(school)
	if s.is_empty():
		return payload
	var data: Variant = JSON.parse_string(str(payload))
	if not (data is Dictionary):
		return payload
	var d := data as Dictionary
	if d.has("block") and d["block"] is Dictionary:
		d["spell_school"] = s
		return JSON.stringify(d)
	# Pure block dict: wrap it so the school has a home outside the
	# validated block object (a "spell_school" key INSIDE the block
	# would be rejected by the loader as an unknown block field).
	return JSON.stringify({"block": d, "spell_school": s})


## Prepends the school comment to a script payload (no-op when the
## school is empty/invalid or the comment is already present).
static func prepend_script_comment(payload: String, school: String) -> String:
	var s := normalize(school)
	if s.is_empty():
		return payload
	var text := str(payload)
	if text.contains("# spell_school:"):
		return text
	return "# spell_school: %s\n%s" % [s, text]
