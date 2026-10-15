# scripts/puzzles/progress_store.gd
# FORGEFALL — Goal 5 (Worker B): room catalogue + completion persistence.
#
# Single source of truth for the four rooms: id, title, objective, and
# the script that builds the room. Main + the room-select UI read this
# table; rooms report completion here. Completion persists in
# user://puzzle_progress.cfg so it survives restarts.
#
# No autoload dependencies (plain ConfigFile), so this loads headlessly.
class_name CompletionStore

const SAVE_PATH := "user://puzzle_progress.cfg"

# Order = progression order. Script paths are the rooms' builders.
const ROOMS: Array = [
	{
		"id": "chamber_01",
		"title": "1 — FIRST STEPS",
		"objective": "Shoot one portal on the white panel ahead, the other on the white panel behind you, then walk through it.",
		"script": "res://scripts/puzzles/chamber_01_first_steps.gd",
		"teaches": "Portal basics: place a pair, walk through.",
	},
	{
		"id": "chamber_02",
		"title": "2 — HEAVY LIFTING",
		"objective": "Push the orange block onto the orange plate to hold the door open, then walk through to the green exit.",
		"script": "res://scripts/puzzles/chamber_02_heavy_lifting.gd",
		"teaches": "Blocks + pressure plates: doors only stay open while a block holds the plate.",
	},
	{
		"id": "chamber_03",
		"title": "3 — FLING",
		"objective": "Put one portal on the pit floor, the other on the white panel on the pillar. Drop into the pit — your fall becomes a sideways fling to the goal platform.",
		"script": "res://scripts/puzzles/chamber_03_fling.gd",
		"teaches": "Momentum: fall speed into a floor portal exits sideways at full speed.",
	},
	{
		"id": "chamber_04",
		"title": "4 — THE GAUNTLET",
		"objective": "Portal through the divider, block the plate to open the gate, then fling across the pit to the exit.",
		"script": "res://scripts/puzzles/chamber_04_gauntlet.gd",
		"teaches": "Everything combined: portals + blocks + plates + fling, in sequence.",
	},
]


static func room_for_id(id: String) -> Dictionary:
	for r in ROOMS:
		if str(r["id"]) == id:
			return r
	return {}


static func _load() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	return cfg


static func is_done(id: String) -> bool:
	return bool(_load().get_value("rooms", id, false))


static func mark_done(id: String) -> void:
	var cfg := _load()
	cfg.set_value("rooms", id, true)
	cfg.save(SAVE_PATH)


static func all_done() -> Dictionary:
	var cfg := _load()
	var out := {}
	for r in ROOMS:
		out[str(r["id"])] = bool(cfg.get_value("rooms", str(r["id"]), false))
	return out


static func reset_all() -> void:
	var cfg := ConfigFile.new()
	cfg.save(SAVE_PATH)
