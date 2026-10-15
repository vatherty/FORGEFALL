# FORGEFALL — VoxelAssetGenerator (Forge batch, Worker D: Mod Creator redesign)
# Keyword-driven PROCEDURAL voxel builder + cache for generated-mod visuals.
# NO external downloads, NO network: everything is generated locally from
# the visual description and cached on disk.
#
# Cache: user://mods/assets/<sha256-of-normalized-description>.json
#   {"version": 1, "description": "<normalized>", "key": "<sha256>",
#    "voxels": [{"p": [x, y, z], "c": "#rrggbb"}, ...]}
# Same normalized description -> same key -> cache HIT, no regeneration.
# Different description -> different key -> a new asset is generated.
#
# Voxel format (in-memory): Array of [Vector3i, Color] entries, the same
# shape VoxelBuilder.build_voxels() consumes, so a cached asset becomes a
# live node with one call (build_node()).
#
# Keyword model (deliberate, deterministic):
# - Named fruits/objects with a known look get a bespoke builder
#   (watermelon: green striped rind shell, red interior, black seeds).
# - Everything else: shape keywords (sphere/cube/cone/star/cylinder/disc/
#   blade, else a rounded blob) x colour keywords (red/green/blue/...)
#   x pattern keywords (stripes/checker/spots, else solid).
# - Unknown descriptions fall back to a sensible generic voxel shape
#   (concrete-grey rounded blob with a forge-orange accent), never an
#   error and never an empty asset.
#
# NOTE (Worker D, for the coordinator): the cache lives under
# user://mods/assets/ per the batch spec, which means ModLoader's scan
# of user://mods/ sees an "assets" folder with no manifest.json and
# records it as a broken mod entry. The Mod Creator's MODS tab filters
# that entry out of the display, but the Forge menu's Mods tab will
# show it until ModLoader skips non-mod directories (follow-up for the
# ModLoader owner — one-line skip of the "assets" dir).
extends RefCounted
class_name VoxelAssetGenerator

const ASSETS_DIR := "user://mods/assets/"
const CACHE_VERSION := 1

const COLOR_WORDS := {
	"red": Color("d92638"),
	"green": Color("3f9e4d"),
	"blue": Color("2b6fd6"),
	"yellow": Color("f2c230"),
	"orange": Color("ff7b1c"),
	"purple": Color("8a4fc0"),
	"pink": Color("f27fb0"),
	"white": Color("e8e6e0"),
	"black": Color("1a1a1a"),
	"brown": Color("7a5c38"),
	"gold": Color("d9a82e"),
	"silver": Color("b8bcc0"),
	"cyan": Color("2ec4d6"),
	"grey": Color("9a958c"),
	"gray": Color("9a958c"),
	"tan": Color("c2a878"),
	"rust": Color("8a4b2a"),
	"concrete": Color("9a958c"),
	"wood": Color("7a5c38"),
	"olive": Color("5a6b3c"),
	"dark": Color("23262a"),
	"crimson": Color("a3122a"),
	"lime": Color("7ed321"),
}

const DEFAULT_PRIMARY := Color("9a958c")
const DEFAULT_SECONDARY := Color("ff7b1c")


## Lowercase, punctuation -> single spaces, whitespace collapsed.
## "  Green WATERMELON!! " -> "green watermelon". The cache key input.
static func normalize_description(desc: String) -> String:
	var out := ""
	var last_space := true
	for ch in desc.to_lower():
		if "abcdefghijklmnopqrstuvwxyz0123456789".contains(ch):
			out += ch
			last_space = false
		elif not last_space:
			out += " "
			last_space = true
	return out.strip_edges()


## Cache key: sha256 of the NORMALIZED description.
static func cache_key(normalized: String) -> String:
	return normalized.sha256_text()


## Full cache path for a (raw) description.
static func cache_path_for(desc: String) -> String:
	return ASSETS_DIR + cache_key(normalize_description(desc)) + ".json"


## Cached asset (cache_hit=true) or freshly generated + saved asset
## (cache_hit=false). Shape:
## {"voxels": [{"p":[x,y,z],"c":"#rrggbb"},...], "cache_hit": bool,
##  "cache_key": String, "path": String, "voxel_count": int,
##  "normalized": String}
## Never fails: a corrupt cache file falls back to regeneration.
static func get_or_generate(desc: String) -> Dictionary:
	var norm := normalize_description(desc)
	var key := cache_key(norm)
	var path := ASSETS_DIR + key + ".json"
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and (parsed as Dictionary).has("voxels"):
			var vox: Variant = (parsed as Dictionary)["voxels"]
			if vox is Array:
				return {"voxels": vox, "cache_hit": true, "cache_key": key,
					"path": path, "voxel_count": (vox as Array).size(),
					"normalized": norm}
	var entries := generate_voxels(desc)
	var serialized := entries_to_serialized(entries)
	_ensure_assets_dir()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"version": CACHE_VERSION,
			"description": norm, "key": key, "voxels": serialized}))
		f.close()
	return {"voxels": serialized, "cache_hit": false, "cache_key": key,
		"path": path, "voxel_count": serialized.size(), "normalized": norm}


## One-line human summary for the approval screen.
static func summarize(asset: Dictionary) -> String:
	var hit := "HIT" if bool(asset.get("cache_hit", false)) else "MISS (generated)"
	return "%d voxels — asset cache %s" % [int(asset.get("voxel_count", 0)), hit]


## In-memory voxel entries ([Vector3i, Color]) for a description.
static func generate_voxels(desc: String) -> Array:
	var norm := normalize_description(desc)
	if norm.contains("watermelon"):
		return _watermelon_voxels()
	var shape := _shape_for(norm)
	var cells := _cells_for_shape(shape)
	var colors := _colors_for(norm)
	var cell_set := {}
	for c in cells:
		cell_set[c] = true
	var out: Array = []
	for c in cells:
		out.append([c, _color_for_cell(c, _is_surface(c, cell_set), shape, colors, norm)])
	return out


## Live Node3D from in-memory entries (VoxelBuilder.build_voxels).
static func build_node(entries: Array) -> Node3D:
	return VoxelBuilder.build_voxels(entries)


## Live Node3D from a get_or_generate() asset dict.
static func build_node_for_asset(asset: Dictionary) -> Node3D:
	return build_node(serialized_to_entries(asset.get("voxels", [])))


## In-memory entries -> JSON-safe serialized form.
static func entries_to_serialized(entries: Array) -> Array:
	var out: Array = []
	for e in entries:
		var p: Vector3i = e[0]
		var col: Color = e[1]
		out.append({"p": [p.x, p.y, p.z], "c": col.to_html()})
	return out


## Serialized form (JSON round-trip: numbers come back as float) -> entries.
static func serialized_to_entries(data: Array) -> Array:
	var out: Array = []
	for item in data:
		if not (item is Dictionary):
			continue
		var d := item as Dictionary
		var p: Variant = d.get("p", [])
		var c: Variant = d.get("c", "")
		if p is Array and (p as Array).size() == 3 and c is String:
			out.append([Vector3i(int((p as Array)[0]), int((p as Array)[1]),
				int((p as Array)[2])), Color(str(c))])
	return out


# --- Bespoke builders ---------------------------------------------------------

## A voxel watermelon: ellipsoid blob, green-rind shell with dark vertical
## stripes, red interior, black seeds. Surface test: d > 0.62 of the
## ellipsoid radius; stripes: bands of the angle around the Y axis.
static func _watermelon_voxels() -> Array:
	var rind_light := Color("58a83c")
	var rind_dark := Color("1e6b2a")
	var flesh := Color("e83a4e")
	var seed := Color("141414")
	var out: Array = []
	for x in range(-3, 4):
		for y in range(-3, 4):
			for z in range(-3, 4):
				var d := (x * x) / 10.24 + (y * y) / 9.0 + (z * z) / 10.24
				if d > 1.0:
					continue
				var cell := Vector3i(x, y, z)
				if d > 0.62:
					var ang := atan2(float(z), float(x)) + PI
					var band := int(floor(ang / (PI / 3.0))) % 2
					out.append([cell, rind_dark if band == 0 else rind_light])
				elif (x * 7 + y * 11 + z * 5) % 9 == 0:
					out.append([cell, seed])
				else:
					out.append([cell, flesh])
	return out


# --- Generic keyword builder --------------------------------------------------

static func _shape_for(norm: String) -> String:
	# Beam/bullet FIRST: projectile descriptions ("glowing laser beam",
	# "small metal bullet") must win over weapon-part words — a pistol
	# visual's "barrel" must never turn its projectile into a cylinder.
	if norm.contains("beam") or norm.contains("laser") or norm.contains("bolt"):
		return "beam"
	if norm.contains("bullet") or norm.contains("round") or norm.contains("shell"):
		return "bullet"
	if norm.contains("sphere") or norm.contains("ball") or norm.contains("orb") or norm.contains("globe"):
		return "sphere"
	if norm.contains("cube") or norm.contains("box") or norm.contains("block"):
		return "cube"
	if norm.contains("cone") or norm.contains("spike"):
		return "cone"
	if norm.contains("star"):
		return "star"
	if norm.contains("cylinder") or norm.contains("barrel") or norm.contains("drum"):
		return "cylinder"
	if norm.contains("disc") or norm.contains("coin") or norm.contains("plate"):
		return "disc"
	if norm.contains("blade") or norm.contains("sword") or norm.contains("spear"):
		return "blade"
	return "blob"


static func _cells_for_shape(shape: String) -> Array:
	var out: Array = []
	match shape:
		"sphere":
			for x in range(-3, 4):
				for y in range(-3, 4):
					for z in range(-3, 4):
						if (x * x) / 9.0 + (y * y) / 9.0 + (z * z) / 9.0 <= 1.0:
							out.append(Vector3i(x, y, z))
		"cube":
			for x in range(-2, 2):
				for y in range(-2, 2):
					for z in range(-2, 2):
						out.append(Vector3i(x, y, z))
		"cone":
			for y in range(0, 5):
				var r := 3 - y
				for x in range(-r, r + 1):
					for z in range(-r, r + 1):
						if x * x + z * z <= r * r:
							out.append(Vector3i(x, y, z))
		"star":
			out.append(Vector3i.ZERO)
			for axis in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
					Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				out.append(axis)
				out.append(axis * 2)
		"cylinder":
			for y in range(0, 4):
				for x in range(-2, 3):
					for z in range(-2, 3):
						if x * x + z * z <= 4:
							out.append(Vector3i(x, y, z))
		"disc":
			for x in range(-3, 4):
				for z in range(-3, 4):
					if x * x + z * z <= 9:
						out.append(Vector3i(x, 0, z))
		"blade":
			for x in range(0, 6):
				var w := 1 if x >= 4 else 0
				out.append(Vector3i(x, 0, 0))
				if w == 0:
					out.append(Vector3i(x, 0, 1))
		"beam":
			# Thin elongated bolt along Z: the projectile of laser/energy
			# weapons. 6 cells, deliberately small (it flies at a dummy).
			for z in range(0, 6):
				out.append(Vector3i(0, 0, z))
		"bullet":
			# A single round: 1x1x2 along Z.
			out.append(Vector3i(0, 0, 0))
			out.append(Vector3i(0, 0, 1))
		_:
			for x in range(-2, 3):
				for y in range(-2, 3):
					for z in range(-2, 3):
						if (x * x) / 6.25 + (y * y) / 6.25 + (z * z) / 6.25 <= 1.0:
							out.append(Vector3i(x, y, z))
	return out


## First colour word -> primary, second -> secondary, else defaults.
## Energy projectiles with no explicit colour read as a bright
## yellow-white bolt (laser/glow/energy), not concrete grey.
static func _colors_for(norm: String) -> Dictionary:
	var found: Array[Color] = []
	for word in norm.split(" "):
		if COLOR_WORDS.has(word):
			var c: Color = COLOR_WORDS[word]
			if not found.has(c):
				found.append(c)
	var primary := DEFAULT_PRIMARY
	var secondary := DEFAULT_SECONDARY
	if not found.is_empty():
		primary = found[0]
	elif norm.contains("laser") or norm.contains("glow") or norm.contains("energy"):
		primary = Color("ffe066")
		secondary = Color("ff7b1c")
	if found.size() > 1:
		secondary = found[1]
	return {"primary": primary, "secondary": secondary}


static func _color_for_cell(cell: Vector3i, _surface: bool, _shape: String, colors: Dictionary, norm: String) -> Color:
	var primary: Color = colors["primary"]
	var secondary: Color = colors["secondary"]
	if norm.contains("stripe"):
		return secondary if (cell.x % 2 == 0) else primary
	if norm.contains("checker"):
		return secondary if ((cell.x + cell.y + cell.z) % 2 == 0) else primary
	if norm.contains("spot") or norm.contains("dot") or norm.contains("speckle"):
		return secondary if ((cell.x * 5 + cell.y * 7 + cell.z * 3) % 6 == 0) else primary
	if not _surface:
		return primary.darkened(0.15)
	return primary


static func _is_surface(cell: Vector3i, cell_set: Dictionary) -> bool:
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
			Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		if not cell_set.has(cell + d):
			return true
	return false


static func _ensure_assets_dir() -> void:
	var user_dir := DirAccess.open("user://")
	if user_dir == null:
		return
	if not user_dir.dir_exists("mods"):
		user_dir.make_dir("mods")
	var mods_dir := DirAccess.open("user://mods/")
	if mods_dir == null:
		return
	if not mods_dir.dir_exists("assets"):
		mods_dir.make_dir("assets")
