# FORGEFALL — Arsenal
# Static weapon database + procedural voxel viewmodel factory.
# Every viewmodel is built from VoxelBuilder cubes: "MW2 directed by
# Minecraft" — readable silhouettes (receiver, barrel, mag, stock, sights)
# in dark gunmetal + tan, forward along -Z (camera space). Each build ends
# with two anchors: Marker3D "Muzzle" (tracer/muzzle-flash origin) and
# Marker3D "Eject" (shell-eject origin).
#
# TUNABLES: the WEAPONS table below is the single balance surface for the
# gunplay (coordinator consolidates into scripts/core/tuning.gd).
class_name Arsenal

#region TUNABLES
const WEAPONS := {
	"ar7": {
		"weapon_id": "ar7",
		"name": "AR-7 MANTICORE",
		"slot": "primary",
		"fire_mode": 0, # WeaponBase.FireMode.AUTO
		"rpm": 700.0,
		"damage": 25.0,
		"headshot_mult": 2.0,
		"mag_size": 30,
		"reserve": 120,
		"pellets": 1,
		"spread_hip": 0.030,
		"spread_move": 0.032,
		"near_range": 20.0,
		"far_range": 60.0,
		"falloff_min": 0.5,
		"recoil_pattern": [
			Vector2(0.004, 0.030), Vector2(-0.003, 0.034),
			Vector2(0.006, 0.032), Vector2(-0.005, 0.036),
			Vector2(0.007, 0.038), Vector2(-0.006, 0.034),
			Vector2(0.009, 0.040), Vector2(-0.008, 0.038),
		],
		"raise_time": 0.35,
		"lower_time": 0.25,
		"reload_stages": [0.45, 0.85, 0.35],
		"cycle_time": 0.0,
		"sfx_fire": "shot_ar7",
		# Goal 1 FEEL (gunfeel): snappy mid-weight recovery, standard flash.
		"recoil_recover": 0.22,
		"muzzle_flash_time": 0.04,
		"muzzle_flash_energy": 4.0,
	},
	"lr8": {
		"weapon_id": "lr8",
		"name": "LR-8 LONGEYE",
		"slot": "primary",
		"fire_mode": 2, # WeaponBase.FireMode.BOLT
		"rpm": 40.0,
		"damage": 120.0,
		"headshot_mult": 2.0,
		"mag_size": 5,
		"reserve": 20,
		"pellets": 1,
		"spread_hip": 0.090,
		"spread_move": 0.060,
		"near_range": 40.0,
		"far_range": 200.0,
		"falloff_min": 0.6,
		"recoil_pattern": [
			Vector2(0.010, 0.110),
		],
		"raise_time": 0.50,
		"lower_time": 0.35,
		"reload_stages": [0.60, 1.20, 0.50],
		"cycle_time": 1.10,
		"sfx_fire": "shot_lr8",
		# Goal 1 FEEL: heavy rifle — long settle, big bright flash.
		"recoil_recover": 0.55,
		"muzzle_flash_time": 0.07,
		"muzzle_flash_energy": 6.5,
	},
	"sg12": {
		"weapon_id": "sg12",
		"name": "SG-12 BREACHER",
		"slot": "primary",
		"fire_mode": 3, # WeaponBase.FireMode.PUMP
		"rpm": 65.0,
		"damage": 12.0,
		"headshot_mult": 2.0,
		"mag_size": 6,
		"reserve": 24,
		"pellets": 8,
		"spread_hip": 0.075,
		"spread_move": 0.040,
		"near_range": 8.0,
		"far_range": 28.0,
		"falloff_min": 0.25,
		"recoil_pattern": [
			Vector2(0.012, 0.095), Vector2(-0.010, 0.085),
		],
		"raise_time": 0.40,
		"lower_time": 0.30,
		"reload_stages": [0.50, 1.00, 0.40],
		"cycle_time": 0.62,
		"sfx_fire": "shot_sg12",
		# Goal 1 FEEL: pump thump — slow recovery, wide bright flash.
		"recoil_recover": 0.45,
		"muzzle_flash_time": 0.06,
		"muzzle_flash_energy": 5.5,
	},
	"smg9": {
		"weapon_id": "smg9",
		"name": "SMG-9 HORNET",
		"slot": "primary",
		"fire_mode": 0, # WeaponBase.FireMode.AUTO
		"rpm": 850.0,
		"damage": 18.0,
		"headshot_mult": 2.0,
		"mag_size": 32,
		"reserve": 160,
		"pellets": 1,
		"spread_hip": 0.045,
		"spread_move": 0.028,
		"near_range": 12.0,
		"far_range": 38.0,
		"falloff_min": 0.45,
		"recoil_pattern": [
			Vector2(0.010, 0.026), Vector2(-0.009, 0.030),
			Vector2(0.012, 0.034), Vector2(-0.011, 0.030),
			Vector2(0.014, 0.036), Vector2(-0.013, 0.040),
			Vector2(0.016, 0.042), Vector2(-0.015, 0.038),
			Vector2(0.018, 0.044), Vector2(-0.017, 0.046),
		],
		"raise_time": 0.30,
		"lower_time": 0.22,
		"reload_stages": [0.40, 0.75, 0.30],
		"cycle_time": 0.0,
		"sfx_fire": "shot_smg9",
		# Goal 1 FEEL: buzzy SMG — fastest recovery, small quick flash.
		"recoil_recover": 0.16,
		"muzzle_flash_time": 0.035,
		"muzzle_flash_energy": 3.5,
	},
	# v0.6.2: LMG block (Forge "lmg"): high capacity, slower handling.
	# Data-only — reuses WeaponBase + the AR-7 viewmodel via
	# build_viewmodel's default; no new systems.
	"lmg": {
		"weapon_id": "lmg",
		"name": "LMG-9 ANVIL",
		"slot": "primary",
		"fire_mode": 0, # WeaponBase.FireMode.AUTO
		"rpm": 600.0,
		"damage": 22.0,
		"headshot_mult": 2.0,
		"mag_size": 100,
		"reserve": 200,
		"pellets": 1,
		"spread_hip": 0.038,
		"spread_move": 0.036,
		"near_range": 18.0,
		"far_range": 55.0,
		"falloff_min": 0.5,
		"recoil_pattern": [
			Vector2(0.008, 0.028), Vector2(-0.007, 0.030),
			Vector2(0.009, 0.032), Vector2(-0.008, 0.030),
			Vector2(0.010, 0.034), Vector2(-0.009, 0.032),
			Vector2(0.011, 0.036), Vector2(-0.010, 0.034),
		],
		"raise_time": 0.55,
		"lower_time": 0.40,
		"reload_stages": [0.70, 1.30, 0.50],
		"cycle_time": 0.0,
		"sfx_fire": "shot_lmg",
		# Goal 2 integration: LMG maps to its own shot_lmg file. The old
		# "shot_ar7" alias made the LMG sound exactly like the AR.
		# (weapon_base also overrides this for the LMG; both now agree.)
		"recoil_recover": 0.30,
		"muzzle_flash_time": 0.045,
		"muzzle_flash_energy": 4.5,
	},
	"p9": {
		"weapon_id": "p9",
		"name": "P9 SIDEARM",
		"slot": "secondary",
		"fire_mode": 1, # WeaponBase.FireMode.SEMI
		"rpm": 420.0,
		"damage": 22.0,
		"headshot_mult": 2.0,
		"mag_size": 12,
		"reserve": 48,
		"pellets": 1,
		"spread_hip": 0.028,
		"spread_move": 0.030,
		"near_range": 14.0,
		"far_range": 45.0,
		"falloff_min": 0.5,
		"recoil_pattern": [
			Vector2(0.006, 0.045), Vector2(-0.005, 0.048),
		],
		"raise_time": 0.28,
		"lower_time": 0.20,
		"reload_stages": [0.35, 0.65, 0.30],
		"cycle_time": 0.0,
		"sfx_fire": "shot_p9",
		# Goal 1 FEEL: pistol snap — quick recovery, standard flash.
		"recoil_recover": 0.18,
		"muzzle_flash_time": 0.04,
		"muzzle_flash_energy": 4.0,
	},
	# Goal 3 CONTENT: BR-3 TRIDENT — 3-round burst rifle. The precision
	# mid-range role: tighter spread than the AR-7, 78 dmg per burst, but
	# burst-only fire caps sustained DPS below the AR-7 (re-press per burst).
	"br3": {
		"weapon_id": "br3",
		"name": "BR-3 TRIDENT",
		"slot": "primary",
		"fire_mode": 4, # WeaponBase.FireMode.BURST
		"burst_size": 3,
		"rpm": 900.0, # intra-burst rate; bursts are re-press gated
		"damage": 26.0,
		"headshot_mult": 2.0,
		"mag_size": 30,
		"reserve": 120,
		"pellets": 1,
		"spread_hip": 0.022,
		"spread_move": 0.026,
		"near_range": 25.0,
		"far_range": 80.0,
		"falloff_min": 0.55,
		"recoil_pattern": [
			Vector2(0.003, 0.026), Vector2(-0.002, 0.030),
			Vector2(0.004, 0.032),
		],
		"raise_time": 0.38,
		"lower_time": 0.26,
		"reload_stages": [0.50, 0.90, 0.35],
		"cycle_time": 0.0,
		"sfx_fire": "shot_br3",
		# Goal 1 FEEL contract: snappy recovery like the AR, standard flash.
		"recoil_recover": 0.20,
		"muzzle_flash_time": 0.04,
		"muzzle_flash_energy": 4.0,
	},
	# Goal 3 CONTENT: HV-44 JUDGE — heavy revolver. The high-alpha
	# finisher role: 65 dmg/shot, 6-round cylinder, slow 2.1 s reload,
	# long reach — nothing else trades this much per trigger pull.
	"hv44": {
		"weapon_id": "hv44",
		"name": "HV-44 JUDGE",
		"slot": "primary",
		"fire_mode": 1, # WeaponBase.FireMode.SEMI
		"rpm": 150.0,
		"damage": 65.0,
		"headshot_mult": 2.0,
		"mag_size": 6,
		"reserve": 36,
		"pellets": 1,
		"spread_hip": 0.018,
		"spread_move": 0.034,
		"near_range": 25.0,
		"far_range": 90.0,
		"falloff_min": 0.60,
		"recoil_pattern": [
			Vector2(0.014, 0.085),
		],
		"raise_time": 0.42,
		"lower_time": 0.30,
		"reload_stages": [0.60, 1.10, 0.40],
		"cycle_time": 0.15, # cylinder rotation lockout between shots
		"sfx_fire": "shot_hv44",
		# Goal 1 FEEL contract: heavy kick, slow settle, big bright flash.
		"recoil_recover": 0.50,
		"muzzle_flash_time": 0.06,
		"muzzle_flash_energy": 6.0,
	},
	"raptor": {
		"weapon_id": "raptor",
		"name": "RAPTOR CLAW",
		"slot": "prototype",
		"fire_mode": 1, # WeaponBase.FireMode.SEMI
		"rpm": 90.0,
		"damage": 0.0,
		"headshot_mult": 1.0,
		"mag_size": 1,
		"reserve": 999,
		"pellets": 0,
		"spread_hip": 0.0,
		"spread_move": 0.0,
		"near_range": 12.0,
		"far_range": 12.0,
		"falloff_min": 1.0,
		"recoil_pattern": [],
		"raise_time": 0.40,
		"lower_time": 0.30,
		"reload_stages": [0.2, 0.2, 0.2],
		"cycle_time": 0.0,
		"sfx_fire": "raptor_throw",
	},
}
#endregion

#region MOD WEAPONS (v0.5.9, Worker B)
## Installed user weapon-mods as first-class Arsenal entries.
## A weapon-mod is a JSON block mod (kind "block") whose block_info has
## target "weapon" and a base_weapon_id mapping to a base Arsenal id.
## Script mods are NOT listed: their behaviour lives in ModBlock.apply()
## code, which Arsenal cannot run — they stay Forge-only (ForgeBuilder
## runs apply()). A JSON weapon-mod is fully declarative (base stats x
## multipliers + data hooks + projectile spec), so Arsenal can build it
## exactly like ForgeBuilder._build_json_mod does for the weapon target.
## Canonical id: "mod:<mod_id>" (mod id = the ModLoader record id, i.e.
## the mod folder/file name — stable, and never collides with a base id,
## which never contains ":"). The id is the persisted form: loadouts
## store it, WeaponManager slots hold it, get_slot_weapon_id returns it.
## A mod weapon is live-validated on EVERY lookup (enabled + error-free
## + target + base): disabling/removing a mod makes has_weapon() return
## false for its id immediately, so stale ids fail safe everywhere.
const MOD_PREFIX := "mod:"
## Forge prompt ids (what mod blocks declare) -> Arsenal ids. Mirrors
## ModHookRegistry.FORGE_TO_ARSENAL / ForgeBuilder.FORGE_WEAPON_IDS.
const MOD_FORGE_TO_ARSENAL := {
	"manticore": "ar7",
	"longeye": "lr8",
	"breacher": "sg12",
	"hornet": "smg9",
	"trident": "br3",
	"judge": "hv44",
}


## True when `weapon_id` is a mod-weapon id ("mod:<mod_id>").
static func is_mod_weapon(weapon_id: String) -> bool:
	return weapon_id.begins_with(MOD_PREFIX)


## The mod id inside a mod-weapon id, or "" for a base weapon id.
static func mod_id_of(weapon_id: String) -> String:
	if not weapon_id.begins_with(MOD_PREFIX):
		return ""
	return weapon_id.substr(MOD_PREFIX.length())


## Canonical Arsenal id for a mod id ("mod:<mod_id>").
static func mod_weapon_id(mod_id: String) -> String:
	return MOD_PREFIX + mod_id


## The base Arsenal id a mod record builds on, or "" when the record is
## not a buildable weapon-mod (no/unknown base_weapon_id).
static func _mod_base_id(rec: Dictionary) -> String:
	var info: Dictionary = rec.get("block_info", {})
	var base := str(info.get("base_weapon_id", ""))
	if base.is_empty():
		return ""
	var mapped := str(MOD_FORGE_TO_ARSENAL.get(base, base))
	if not WEAPONS.has(mapped):
		return ""
	return mapped


## The validated full ModLoader record for a mod-weapon id, or {} when
## the id is not a live weapon-mod (unknown / disabled / broken / not a
## JSON weapon block / no known base). Uses find_mod(..., false) so
## Arsenal lookups never pollute ModHookRegistry's find-pair history.
static func _mod_record(weapon_id: String) -> Dictionary:
	var mod_id := mod_id_of(weapon_id)
	if mod_id.is_empty():
		return {}
	var rec := ModLoader.find_mod(mod_id, false)
	if rec.is_empty() or not bool(rec.get("enabled", false)) or str(rec.get("error", "")) != "":
		return {}
	if str(rec.get("kind", "")) != "block":
		return {} # script mods stay Forge-only (apply() code)
	var info: Dictionary = rec.get("block_info", {})
	if str(info.get("target", "")) != "weapon":
		return {}
	if _mod_base_id(rec).is_empty():
		return {}
	return rec


## Every live weapon-mod, sorted by display name: {"weapon_id",
## "mod_id", "name", "base_weapon_id", "slot"}. The Arsenal list /
## Forge Loadouts tab build from this.
static func get_mod_weapons() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for public_rec in ModLoader.get_mods():
		if not (public_rec is Dictionary):
			continue
		var mod_id := str((public_rec as Dictionary).get("id", ""))
		if mod_id.is_empty():
			continue
		var rec := _mod_record(mod_weapon_id(mod_id))
		if rec.is_empty():
			continue
		var info: Dictionary = rec.get("block_info", {})
		var base_id := _mod_base_id(rec)
		out.append({
			"weapon_id": mod_weapon_id(mod_id),
			"mod_id": mod_id,
			"name": str(info.get("display_name", rec.get("name", mod_id))),
			"base_weapon_id": base_id,
			"slot": str((WEAPONS.get(base_id, {}) as Dictionary).get("slot", "primary")),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("name", "")).to_lower() < str(b.get("name", "")).to_lower())
	return out


## Every weapon id Arsenal knows: base ids + live mod-weapon ids,
## sorted. The Loadouts store builds its picker list from this.
static func all_weapon_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in WEAPONS.keys():
		ids.append(str(key))
	for m in get_mod_weapons():
		ids.append(str(m.get("weapon_id", "")))
	ids.sort()
	return ids


## The custom projectile spec for a hook list: the LAST on_fire /
## projectile_spawn hook carrying a "projectile" dict wins, tagged with
## its _hook_id. Mirrors ForgeBuilder._projectile_spec_from_hooks. {}
## when no hook defines a projectile.
static func _mod_projectile_spec_from_hooks(hooks: Array) -> Dictionary:
	var out: Dictionary = {}
	for h in hooks:
		if not (h is Dictionary):
			continue
		var d := h as Dictionary
		if str(d.get("error", "")) != "":
			continue
		if str(d.get("hook_point", "")) in ["on_fire", "projectile_spawn"] and d.has("projectile"):
			var proj: Variant = d.get("projectile", {})
			if proj is Dictionary:
				out = (proj as Dictionary).duplicate(true)
				out["_hook_id"] = str(d.get("hook_id", ""))
	return out


## A composed ammo_type applied to already-derived mod stats. Mirrors
## ForgeBuilder._apply_ammo_modifiers exactly (same multipliers).
static func _apply_mod_ammo(stats: Dictionary, ammo_type: String) -> void:
	match ammo_type:
		"sniper":
			stats["damage"] = float(stats.get("damage", 0.0)) * 1.5
			stats["near_range"] = float(stats.get("near_range", 0.0)) * 1.5
			stats["far_range"] = float(stats.get("far_range", 0.0)) * 1.5
			var mag_size := maxi(1, int(round(float(stats.get("mag_size", 1)) * 0.5)))
			stats["mag_size"] = mag_size
		"armor_piercing":
			stats["damage"] = float(stats.get("damage", 0.0)) * 1.25
			stats["spread_hip"] = float(stats.get("spread_hip", 0.0)) * 1.2
			stats["spread_move"] = float(stats.get("spread_move", 0.0)) * 1.2
		"buckshot":
			stats["damage"] = float(stats.get("damage", 0.0)) * 1.3
			stats["near_range"] = float(stats.get("near_range", 0.0)) * 0.6
			stats["far_range"] = float(stats.get("far_range", 0.0)) * 0.6
			stats["spread_hip"] = float(stats.get("spread_hip", 0.0)) * 1.6
			stats["spread_move"] = float(stats.get("spread_move", 0.0)) * 1.6


## Synthesized stats for a live mod-weapon id: base stats with the
## block's multipliers applied (same order as ForgeBuilder._build_json_mod
## for the weapon target: damage_mult, range_mult, mag_mult, then
## ammo_type), plus the mod attachment WeaponBase.setup already
## understands (mod_id / mod_hooks / mod_projectile_spec). {} when the
## id is not a live weapon-mod.
static func _mod_stats(weapon_id: String) -> Dictionary:
	var rec := _mod_record(weapon_id)
	if rec.is_empty():
		return {}
	var info: Dictionary = rec.get("block_info", {})
	var base_id := _mod_base_id(rec)
	var stats := (WEAPONS.get(base_id, {}) as Dictionary).duplicate(true)
	if stats.is_empty():
		return {}
	stats["weapon_id"] = weapon_id
	stats["name"] = str(info.get("display_name", rec.get("name", weapon_id)))
	stats["mod_base_weapon_id"] = base_id
	stats["mod_id"] = str(rec.get("id", ""))
	if info.has("damage_mult"):
		stats["damage"] = float(stats.get("damage", 0.0)) * float(info.get("damage_mult", 1.0))
	if info.has("range_mult"):
		stats["near_range"] = float(stats.get("near_range", 0.0)) * float(info.get("range_mult", 1.0))
		stats["far_range"] = float(stats.get("far_range", 0.0)) * float(info.get("range_mult", 1.0))
	if info.has("mag_mult"):
		var mag_size := maxi(1, int(round(float(stats.get("mag_size", 1)) * float(info.get("mag_mult", 1.0)))))
		stats["mag_size"] = mag_size
	# v0.5.11 BURST: fire_mode + burst_size ride in stats so
	# WeaponBase.setup() picks them up (same as the Forge grant path).
	if info.has("fire_mode"):
		stats["fire_mode"] = WeaponBase.fire_mode_from_string(str(info.get("fire_mode", "")))
	if info.has("burst_size"):
		stats["burst_size"] = maxi(2, int(info.get("burst_size", 3)))
	var hooks: Array = (rec.get("hooks", []) as Array).duplicate(true) if rec.get("hooks") is Array else []
	# Belt-and-braces: scan stamps _mod_id, but stamp any unstamped
	# hook so the registry's live-record gate applies to it.
	for h in hooks:
		if h is Dictionary and str((h as Dictionary).get("_mod_id", "")) == "":
			(h as Dictionary)["_mod_id"] = str(rec.get("id", ""))
	stats["mod_hooks"] = hooks
	stats["mod_projectile_spec"] = _mod_projectile_spec_from_hooks(hooks)
	var ammo_type := str(info.get("ammo_type", "standard"))
	if ammo_type != "standard":
		_apply_mod_ammo(stats, ammo_type)
	return stats
#endregion


## Sight-line height (viewmodel-local Y of the aiming point) per weapon.
## WeaponBase reads this to place ADS_POS so the sight sits exactly on the
## screen center: ADS y = -sight_height. Values match the "Sight" marker
## each builder places (iron-sight line / scope centre / red-dot centre).
const SIGHT_Y := {
	"ar7": 0.090,    # iron-sight line (front post tip / rear notch)
	"lr8": 0.095,    # scope tube centre
	"sg12": 0.078,   # bead / ghost-ring line
	"smg9": 0.088,   # red-dot centre
	"lmg": 0.092,    # iron-sight line (AR-7 viewmodel reuse)
	"p9": 0.055,     # iron-sight line
	"br3": 0.092,    # red-dot centre (raised sight line)
	"hv44": 0.062,   # iron-sight line (tall front blade)
	"raptor": 0.045, # prong-gap centre (no true sight)
}


static func sight_height(weapon_id: String) -> float:
	if is_mod_weapon(weapon_id):
		# A mod weapon aims down its base weapon's sight line.
		var rec := _mod_record(weapon_id)
		if not rec.is_empty():
			return float(SIGHT_Y.get(_mod_base_id(rec), 0.090))
		return 0.090
	return float(SIGHT_Y.get(weapon_id, 0.090))


static func get_stats(weapon_id: String) -> Dictionary:
	if is_mod_weapon(weapon_id):
		return _mod_stats(weapon_id)
	return (WEAPONS.get(weapon_id, {}) as Dictionary).duplicate(true)


static func has_weapon(weapon_id: String) -> bool:
	if WEAPONS.has(weapon_id):
		return true
	if is_mod_weapon(weapon_id):
		return not _mod_record(weapon_id).is_empty()
	return false


## Build a WeaponBase (or RaptorGun for "raptor" / raptor-based mods)
## with stats + viewmodel. Mod stats already carry the mod attachment,
## so the built weapon fires with its hooks/projectiles immediately.
static func make_weapon(weapon_id: String) -> WeaponBase:
	var w: WeaponBase
	if weapon_id == "raptor":
		w = RaptorGun.new()
	elif is_mod_weapon(weapon_id) and _mod_base_id(_mod_record(weapon_id)) == "raptor":
		w = RaptorGun.new()
	else:
		w = WeaponBase.new()
	w.setup(get_stats(weapon_id))
	# Node names must not contain ":" (NodePath subname separator).
	w.name = "Weapon_" + weapon_id.replace(":", "_")
	return w


# --- Viewmodel factory ---

static func _pal(key: String) -> Color:
	return VoxelBuilder.PALETTE.get(key, Color.WHITE)


static func _c(parent: Node3D, size: Vector3, color_key: String, pos: Vector3) -> MeshInstance3D:
	var mi := VoxelBuilder.cube(size, _pal(color_key), pos)
	parent.add_child(mi)
	return mi


static func _anchor(parent: Node3D, aname: String, pos: Vector3) -> Marker3D:
	var mk := Marker3D.new()
	mk.name = aname
	mk.position = pos
	parent.add_child(mk)
	return mk


## Small emissive detail cube (red-dot lens, tritium dots). Voxel-cheap:
## one shared-shape box + one material per call (a handful per viewmodel).
static func _glow(parent: Node3D, size: Vector3, color: Color, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	mat.albedo_color = color
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


## Build the voxel viewmodel for a weapon id. Forward = -Z.
## A mod weapon reuses its base weapon's viewmodel (mods are stat +
## hook compositions, not new geometry).
static func build_viewmodel(weapon_id: String) -> Node3D:
	if is_mod_weapon(weapon_id):
		var rec := _mod_record(weapon_id)
		if not rec.is_empty():
			return build_viewmodel(_mod_base_id(rec))
		return _build_ar7()
	match weapon_id:
		"ar7":
			return _build_ar7()
		"lr8":
			return _build_lr8()
		"sg12":
			return _build_sg12()
		"smg9":
			return _build_smg9()
		"p9":
			return _build_p9()
		"br3":
			return _build_br3()
		"hv44":
			return _build_hv44()
		"raptor":
			return _build_raptor()
	return _build_ar7()


# M4-like carbine: receiver, tan handguard, carry-handle-ish rear sight,
# front post, curved mag, stock, grip.
static func _build_ar7() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_ar7"
	_c(g, Vector3(0.075, 0.095, 0.36), "gunmetal", Vector3(0, 0, -0.10))      # receiver
	_c(g, Vector3(0.060, 0.070, 0.20), "darkmetal", Vector3(0, -0.005, -0.36)) # handguard
	_c(g, Vector3(0.066, 0.020, 0.20), "tan", Vector3(0, 0.028, -0.36))        # tan top rail accent
	_c(g, Vector3(0.014, 0.050, 0.014), "darkmetal", Vector3(0, 0.028, -0.36))  # rail riser
	_c(g, Vector3(0.030, 0.030, 0.16), "darkmetal", Vector3(0, 0.008, -0.52))   # barrel
	_c(g, Vector3(0.040, 0.040, 0.05), "darkmetal", Vector3(0, 0.008, -0.60))  # muzzle device
	_c(g, Vector3(0.016, 0.055, 0.016), "darkmetal", Vector3(0, 0.075, -0.44))  # front sight post
	_c(g, Vector3(0.050, 0.014, 0.016), "darkmetal", Vector3(0, 0.050, -0.44))  # front sight wings
	_c(g, Vector3(0.014, 0.050, 0.014), "darkmetal", Vector3(-0.026, 0.068, 0.045)) # rear sight L
	_c(g, Vector3(0.014, 0.050, 0.014), "darkmetal", Vector3(0.026, 0.068, 0.045))  # rear sight R
	_c(g, Vector3(0.066, 0.014, 0.014), "darkmetal", Vector3(0, 0.090, 0.045))  # rear sight top
	_c(g, Vector3(0.050, 0.150, 0.065), "darkmetal", Vector3(0, -0.115, -0.10)) # magazine
	_c(g, Vector3(0.054, 0.030, 0.069), "tan", Vector3(0, -0.175, -0.10))      # mag baseplate
	_c(g, Vector3(0.045, 0.110, 0.050), "darkmetal", Vector3(0, -0.095, 0.045)) # grip
	_c(g, Vector3(0.058, 0.100, 0.150), "gunmetal", Vector3(0, -0.005, 0.150))  # stock
	_c(g, Vector3(0.062, 0.110, 0.030), "tan", Vector3(0, -0.010, 0.225))      # buttpad
	_c(g, Vector3(0.020, 0.020, 0.060), "darkmetal", Vector3(0, 0.052, 0.010))  # charging handle
	_c(g, Vector3(0.080, 0.030, 0.050), "darkmetal", Vector3(0, 0.020, -0.020)) # ejection port housing
	_c(g, Vector3(0.040, 0.090, 0.045), "darkmetal", Vector3(0, -0.075, -0.36)) # vertical foregrip
	_c(g, Vector3(0.056, 0.012, 0.010), "tan", Vector3(0, -0.085, -0.085))      # mag rib F
	_c(g, Vector3(0.056, 0.012, 0.010), "tan", Vector3(0, -0.130, -0.100))     # mag rib R
	_c(g, Vector3(0.062, 0.012, 0.030), "tan", Vector3(0, 0.048, 0.150))        # stock adjustment notch
	_anchor(g, "Sight", Vector3(0, 0.090, -0.10))
	_anchor(g, "Stock", Vector3(0, -0.005, 0.200))
	_anchor(g, "Grip", Vector3(0, -0.095, 0.045))
	_anchor(g, "Barrel", Vector3(0, 0.008, -0.520))
	_anchor(g, "Muzzle", Vector3(0, 0.008, -0.635))
	_anchor(g, "Eject", Vector3(0.055, 0.030, -0.020))
	return g


# Bolt sniper: long fluted barrel, big voxel scope, bolt handle, wood stock.
static func _build_lr8() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_lr8"
	_c(g, Vector3(0.070, 0.090, 0.34), "gunmetal", Vector3(0, 0, -0.06))       # receiver
	_c(g, Vector3(0.034, 0.034, 0.44), "darkmetal", Vector3(0, 0.010, -0.44))  # long barrel
	_c(g, Vector3(0.046, 0.046, 0.06), "darkmetal", Vector3(0, 0.010, -0.66))   # muzzle brake
	_c(g, Vector3(0.070, 0.060, 0.10), "wood", Vector3(0, -0.010, -0.30))      # fore-end
	# Voxel scope: tube + objective bell + ocular bell + mounts.
	_c(g, Vector3(0.052, 0.052, 0.20), "darkmetal", Vector3(0, 0.095, -0.06))  # scope tube
	_c(g, Vector3(0.068, 0.068, 0.06), "darkmetal", Vector3(0, 0.095, -0.18))  # objective bell
	_c(g, Vector3(0.060, 0.060, 0.05), "darkmetal", Vector3(0, 0.095, 0.055))   # ocular bell
	_c(g, Vector3(0.040, 0.052, 0.010), "portal_blue", Vector3(0, 0.095, -0.215)) # lens glint
	_c(g, Vector3(0.030, 0.030, 0.030), "darkmetal", Vector3(0, 0.060, -0.12))  # mount F
	_c(g, Vector3(0.030, 0.030, 0.030), "darkmetal", Vector3(0, 0.060, 0.000))  # mount R
	_c(g, Vector3(0.016, 0.016, 0.016), "darkmetal", Vector3(0, 0.128, -0.06))  # elevation turret
	_c(g, Vector3(0.016, 0.016, 0.016), "darkmetal", Vector3(0.034, 0.095, -0.06)) # windage turret
	# Bolt handle sticking out right.
	_c(g, Vector3(0.060, 0.016, 0.016), "darkmetal", Vector3(0.055, 0.020, 0.030))
	_c(g, Vector3(0.022, 0.022, 0.022), "darkmetal", Vector3(0.090, 0.020, 0.030))
	_c(g, Vector3(0.048, 0.130, 0.060), "darkmetal", Vector3(0, -0.105, -0.02)) # mag
	_c(g, Vector3(0.045, 0.100, 0.045), "wood", Vector3(0, -0.085, 0.075))      # grip
	_c(g, Vector3(0.060, 0.110, 0.220), "wood", Vector3(0, -0.015, 0.170))      # wood stock
	_c(g, Vector3(0.064, 0.120, 0.030), "tan", Vector3(0, -0.020, 0.285))       # buttpad
	_c(g, Vector3(0.070, 0.020, 0.060), "tan", Vector3(0, 0.055, 0.170))        # cheek riser
	_c(g, Vector3(0.040, 0.040, 0.014), "darkmetal", Vector3(0, 0.010, -0.300))  # barrel flute ring F
	_c(g, Vector3(0.040, 0.040, 0.014), "darkmetal", Vector3(0, 0.010, -0.400))  # barrel flute ring M
	_c(g, Vector3(0.040, 0.040, 0.014), "darkmetal", Vector3(0, 0.010, -0.500))  # barrel flute ring R
	_c(g, Vector3(0.016, 0.070, 0.016), "darkmetal", Vector3(-0.020, -0.075, -0.300)) # bipod leg L (folded)
	_c(g, Vector3(0.016, 0.070, 0.016), "darkmetal", Vector3(0.020, -0.075, -0.300))  # bipod leg R (folded)
	_c(g, Vector3(0.072, 0.072, 0.020), "darkmetal", Vector3(0, 0.095, -0.215)) # scope sunshade ring
	_anchor(g, "Sight", Vector3(0, 0.095, -0.060))
	_anchor(g, "Stock", Vector3(0, -0.015, 0.200))
	_anchor(g, "Grip", Vector3(0, -0.085, 0.075))
	_anchor(g, "Barrel", Vector3(0, 0.010, -0.440))
	_anchor(g, "Muzzle", Vector3(0, 0.010, -0.700))
	_anchor(g, "Eject", Vector3(0.050, 0.030, 0.020))
	return g


# Pump shotgun: fat barrel + tube, wood pump fore-end, chunky receiver.
static func _build_sg12() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_sg12"
	_c(g, Vector3(0.085, 0.100, 0.30), "gunmetal", Vector3(0, 0, -0.08))       # receiver
	_c(g, Vector3(0.048, 0.048, 0.42), "darkmetal", Vector3(0, 0.012, -0.40))   # barrel
	_c(g, Vector3(0.036, 0.036, 0.40), "darkmetal", Vector3(0, -0.038, -0.40))  # mag tube
	_c(g, Vector3(0.080, 0.075, 0.16), "wood", Vector3(0, -0.005, -0.34))      # pump fore-end
	_c(g, Vector3(0.086, 0.020, 0.16), "tan", Vector3(0, 0.036, -0.34))        # pump top strap
	_c(g, Vector3(0.016, 0.045, 0.016), "darkmetal", Vector3(0, 0.070, -0.55))  # bead sight
	_c(g, Vector3(0.060, 0.020, 0.120), "darkmetal", Vector3(0, 0.060, -0.02))  # top rail
	_c(g, Vector3(0.050, 0.120, 0.055), "wood", Vector3(0, -0.100, 0.040))     # grip
	_c(g, Vector3(0.062, 0.105, 0.170), "wood", Vector3(0, -0.010, 0.150))     # stock
	_c(g, Vector3(0.066, 0.115, 0.030), "tan", Vector3(0, -0.015, 0.240))      # buttpad
	_c(g, Vector3(0.090, 0.025, 0.080), "rust", Vector3(0, -0.060, -0.180))     # heat-shield rust band
	_c(g, Vector3(0.014, 0.045, 0.014), "darkmetal", Vector3(-0.026, 0.075, 0.020)) # ghost-ring L
	_c(g, Vector3(0.014, 0.045, 0.014), "darkmetal", Vector3(0.026, 0.075, 0.020))  # ghost-ring R
	_c(g, Vector3(0.066, 0.012, 0.014), "darkmetal", Vector3(0, 0.098, 0.020))   # ghost-ring top
	_c(g, Vector3(0.086, 0.012, 0.020), "tan", Vector3(0, 0.030, -0.300))       # pump groove F
	_c(g, Vector3(0.086, 0.012, 0.020), "tan", Vector3(0, 0.030, -0.380))       # pump groove R
	_c(g, Vector3(0.016, 0.016, 0.016), "rust", Vector3(-0.030, -0.030, 0.150))  # stock shell holder L
	_c(g, Vector3(0.016, 0.016, 0.016), "rust", Vector3(0.030, -0.030, 0.150))   # stock shell holder R
	_anchor(g, "Sight", Vector3(0, 0.078, -0.200))
	_anchor(g, "Stock", Vector3(0, -0.010, 0.180))
	_anchor(g, "Grip", Vector3(0, -0.100, 0.040))
	_anchor(g, "Barrel", Vector3(0, 0.012, -0.400))
	_anchor(g, "Muzzle", Vector3(0, 0.012, -0.620))
	_anchor(g, "Eject", Vector3(0.058, 0.035, -0.060))
	return g


# Compact SMG: short, top rail, foregrip, suppressor-ish shroud.
static func _build_smg9() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_smg9"
	_c(g, Vector3(0.070, 0.090, 0.26), "gunmetal", Vector3(0, 0, -0.06))       # receiver
	_c(g, Vector3(0.056, 0.056, 0.14), "darkmetal", Vector3(0, 0.005, -0.26))   # shroud
	_c(g, Vector3(0.062, 0.020, 0.140), "tan", Vector3(0, 0.038, -0.26))        # shroud top accent
	_c(g, Vector3(0.034, 0.034, 0.08), "darkmetal", Vector3(0, 0.005, -0.37))   # barrel tip
	_c(g, Vector3(0.070, 0.018, 0.200), "darkmetal", Vector3(0, 0.054, -0.06))   # top rail
	_c(g, Vector3(0.014, 0.040, 0.014), "darkmetal", Vector3(0, 0.075, -0.15))  # front sight
	_c(g, Vector3(0.014, 0.040, 0.014), "darkmetal", Vector3(-0.022, 0.075, 0.03)) # rear L
	_c(g, Vector3(0.014, 0.040, 0.014), "darkmetal", Vector3(0.022, 0.075, 0.03))  # rear R
	_c(g, Vector3(0.045, 0.170, 0.060), "darkmetal", Vector3(0, -0.120, -0.10)) # long mag
	_c(g, Vector3(0.040, 0.090, 0.045), "darkmetal", Vector3(0, -0.085, -0.235)) # foregrip
	_c(g, Vector3(0.045, 0.100, 0.050), "darkmetal", Vector3(0, -0.090, 0.055)) # grip
	_c(g, Vector3(0.055, 0.090, 0.100), "gunmetal", Vector3(0, -0.005, 0.120))  # wire-ish stock
	_c(g, Vector3(0.059, 0.095, 0.025), "tan", Vector3(0, -0.008, 0.175))       # stock plate
	_c(g, Vector3(0.020, 0.020, 0.050), "darkmetal", Vector3(0.045, 0.010, -0.02)) # side charger
	# Red-dot sight: riser + housing + glowing dot (distinct from iron sights).
	_c(g, Vector3(0.016, 0.020, 0.016), "darkmetal", Vector3(0, 0.070, -0.060)) # dot riser
	_c(g, Vector3(0.036, 0.030, 0.050), "darkmetal", Vector3(0, 0.088, -0.060)) # dot housing
	_glow(g, Vector3(0.009, 0.009, 0.004), Color(1.0, 0.15, 0.10), Vector3(0, 0.088, -0.087)) # red dot
	_c(g, Vector3(0.040, 0.014, 0.014), "darkmetal", Vector3(0, 0.108, -0.060)) # housing top cap
	_c(g, Vector3(0.060, 0.060, 0.012), "darkmetal", Vector3(0, 0.005, -0.315)) # suppressor ring
	_c(g, Vector3(0.049, 0.012, 0.010), "tan", Vector3(0, -0.090, -0.100))      # mag rib
	_anchor(g, "Sight", Vector3(0, 0.088, -0.060))
	_anchor(g, "Stock", Vector3(0, -0.005, 0.140))
	_anchor(g, "Grip", Vector3(0, -0.090, 0.055))
	_anchor(g, "Barrel", Vector3(0, 0.005, -0.370))
	_anchor(g, "Muzzle", Vector3(0, 0.005, -0.420))
	_anchor(g, "Eject", Vector3(0.050, 0.030, -0.040))
	return g


# Pistol: slide, frame, grip, tiny sights. Compact on purpose.
static func _build_p9() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_p9"
	_c(g, Vector3(0.055, 0.055, 0.20), "gunmetal", Vector3(0, 0.010, -0.10))    # slide
	_c(g, Vector3(0.059, 0.020, 0.200), "darkmetal", Vector3(0, 0.042, -0.10))  # slide top serration band
	_c(g, Vector3(0.050, 0.045, 0.190), "darkmetal", Vector3(0, -0.028, -0.10)) # frame
	_c(g, Vector3(0.052, 0.120, 0.060), "darkmetal", Vector3(0, -0.105, 0.015)) # grip
	_c(g, Vector3(0.056, 0.030, 0.064), "tan", Vector3(0, -0.150, 0.015))       # grip base
	_c(g, Vector3(0.012, 0.030, 0.012), "darkmetal", Vector3(0, 0.055, -0.195)) # front sight
	_c(g, Vector3(0.040, 0.025, 0.014), "darkmetal", Vector3(0, 0.052, -0.005)) # rear sight
	_c(g, Vector3(0.030, 0.030, 0.030), "darkmetal", Vector3(0, -0.005, -0.205)) # muzzle block
	_c(g, Vector3(0.056, 0.012, 0.050), "rust", Vector3(0, -0.008, -0.160))     # trigger guard accent
	# Tritium night sights: glowing front dot + two rear dots.
	_glow(g, Vector3(0.008, 0.008, 0.004), Color(0.55, 1.0, 0.45), Vector3(0, 0.058, -0.202))
	_glow(g, Vector3(0.007, 0.007, 0.004), Color(0.55, 1.0, 0.45), Vector3(-0.014, 0.055, -0.013))
	_glow(g, Vector3(0.007, 0.007, 0.004), Color(0.55, 1.0, 0.45), Vector3(0.014, 0.055, -0.013))
	_c(g, Vector3(0.056, 0.012, 0.010), "tan", Vector3(0, -0.090, 0.015))       # grip ridge F
	_c(g, Vector3(0.056, 0.012, 0.010), "tan", Vector3(0, -0.120, 0.015))       # grip ridge R
	_c(g, Vector3(0.059, 0.008, 0.040), "darkmetal", Vector3(0, 0.000, -0.100))  # slide serration band R
	_anchor(g, "Sight", Vector3(0, 0.055, -0.100))
	_anchor(g, "Stock", Vector3(0, -0.150, 0.015))
	_anchor(g, "Grip", Vector3(0, -0.105, 0.015))
	_anchor(g, "Barrel", Vector3(0, 0.010, -0.190))
	_anchor(g, "Muzzle", Vector3(0, 0.010, -0.220))
	_anchor(g, "Eject", Vector3(0.042, 0.035, -0.080))
	return g


# Goal 3: BR-3 TRIDENT burst rifle — long precision barrel, 3-slot burst
# indicator on the receiver, raised red-dot sight, tan furniture.
static func _build_br3() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_br3"
	_c(g, Vector3(0.072, 0.092, 0.38), "gunmetal", Vector3(0, 0, -0.10))      # receiver
	_c(g, Vector3(0.058, 0.068, 0.24), "darkmetal", Vector3(0, -0.005, -0.38)) # handguard
	_c(g, Vector3(0.064, 0.018, 0.24), "tan", Vector3(0, 0.028, -0.38))        # tan top rail accent
	_c(g, Vector3(0.028, 0.028, 0.22), "darkmetal", Vector3(0, 0.008, -0.56))   # long barrel
	_c(g, Vector3(0.038, 0.038, 0.05), "darkmetal", Vector3(0, 0.008, -0.66))    # muzzle brake
	_c(g, Vector3(0.016, 0.050, 0.016), "darkmetal", Vector3(0, 0.075, -0.50))  # front sight post
	_c(g, Vector3(0.050, 0.014, 0.016), "darkmetal", Vector3(0, 0.050, -0.50))  # front sight wings
	_c(g, Vector3(0.048, 0.145, 0.060), "darkmetal", Vector3(0, -0.112, -0.10)) # magazine
	_c(g, Vector3(0.052, 0.028, 0.064), "tan", Vector3(0, -0.170, -0.10))       # mag baseplate
	_c(g, Vector3(0.044, 0.108, 0.048), "darkmetal", Vector3(0, -0.092, 0.045)) # grip
	_c(g, Vector3(0.056, 0.098, 0.150), "gunmetal", Vector3(0, -0.005, 0.150))  # stock
	_c(g, Vector3(0.060, 0.108, 0.030), "tan", Vector3(0, -0.010, 0.225))        # buttpad
	_c(g, Vector3(0.038, 0.088, 0.042), "darkmetal", Vector3(0, -0.075, -0.38)) # vertical foregrip
	# Burst indicator: three forge-orange pips on the receiver side.
	_glow(g, Vector3(0.006, 0.012, 0.012), Color(1.0, 0.48, 0.11), Vector3(0.040, 0.020, -0.16))
	_glow(g, Vector3(0.006, 0.012, 0.012), Color(1.0, 0.48, 0.11), Vector3(0.040, 0.020, -0.12))
	_glow(g, Vector3(0.006, 0.012, 0.012), Color(1.0, 0.48, 0.11), Vector3(0.040, 0.020, -0.08))
	# Raised red-dot sight (distinct from the AR-7 irons).
	_c(g, Vector3(0.016, 0.022, 0.016), "darkmetal", Vector3(0, 0.068, -0.060)) # dot riser
	_c(g, Vector3(0.036, 0.030, 0.050), "darkmetal", Vector3(0, 0.092, -0.060)) # dot housing
	_glow(g, Vector3(0.009, 0.009, 0.004), Color(1.0, 0.15, 0.10), Vector3(0, 0.092, -0.087)) # red dot
	_c(g, Vector3(0.040, 0.014, 0.014), "darkmetal", Vector3(0, 0.112, -0.060)) # housing top cap
	_anchor(g, "Sight", Vector3(0, 0.092, -0.060))
	_anchor(g, "Stock", Vector3(0, -0.005, 0.200))
	_anchor(g, "Grip", Vector3(0, -0.092, 0.045))
	_anchor(g, "Barrel", Vector3(0, 0.008, -0.560))
	_anchor(g, "Muzzle", Vector3(0, 0.008, -0.695))
	_anchor(g, "Eject", Vector3(0.052, 0.030, -0.020))
	return g


# Goal 3: HV-44 JUDGE heavy revolver — fat cylinder, long barrel with
# vent rib, wood grip, tall front blade sight. Compact like the P9.
static func _build_hv44() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_hv44"
	_c(g, Vector3(0.056, 0.058, 0.20), "gunmetal", Vector3(0, 0.010, -0.08))   # frame
	_c(g, Vector3(0.058, 0.058, 0.055), "darkmetal", Vector3(0, 0.012, -0.10))  # cylinder housing
	_c(g, Vector3(0.052, 0.052, 0.060), "gunmetal", Vector3(0, 0.012, -0.10))  # cylinder
	_c(g, Vector3(0.056, 0.010, 0.060), "tan", Vector3(0, 0.042, -0.10))        # cylinder flute band
	_c(g, Vector3(0.040, 0.040, 0.22), "darkmetal", Vector3(0, 0.012, -0.28))   # long barrel
	_c(g, Vector3(0.046, 0.016, 0.22), "darkmetal", Vector3(0, 0.042, -0.28))   # vent rib
	_c(g, Vector3(0.014, 0.040, 0.014), "darkmetal", Vector3(0, 0.062, -0.380)) # tall front blade
	_c(g, Vector3(0.042, 0.026, 0.016), "darkmetal", Vector3(0, 0.058, 0.010))   # rear sight
	_c(g, Vector3(0.052, 0.125, 0.062), "wood", Vector3(0, -0.105, 0.020))      # wood grip
	_c(g, Vector3(0.056, 0.030, 0.066), "tan", Vector3(0, -0.152, 0.020))       # grip base
	_c(g, Vector3(0.020, 0.020, 0.020), "darkmetal", Vector3(0.038, 0.010, -0.04)) # cylinder release
	_glow(g, Vector3(0.008, 0.008, 0.004), Color(1.0, 0.48, 0.11), Vector3(0, 0.066, -0.388)) # blade tip
	_c(g, Vector3(0.056, 0.012, 0.050), "rust", Vector3(0, -0.008, -0.160))    # trigger guard accent
	_anchor(g, "Sight", Vector3(0, 0.062, -0.100))
	_anchor(g, "Stock", Vector3(0, -0.150, 0.020))
	_anchor(g, "Grip", Vector3(0, -0.105, 0.020))
	_anchor(g, "Barrel", Vector3(0, 0.012, -0.280))
	_anchor(g, "Muzzle", Vector3(0, 0.012, -0.400))
	_anchor(g, "Eject", Vector3(0.042, 0.035, -0.080))
	return g


# Raptor claw: chunky wrist mount, three prongs, forge-orange power core.
static func _build_raptor() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_raptor"
	_c(g, Vector3(0.090, 0.100, 0.160), "darkmetal", Vector3(0, 0, 0.02))        # wrist mount
	_c(g, Vector3(0.096, 0.040, 0.100), "gunmetal", Vector3(0, 0.055, -0.02))   # top housing
	_c(g, Vector3(0.050, 0.050, 0.050), "forge_orange", Vector3(0, 0.010, -0.075)) # power core
	_c(g, Vector3(0.070, 0.070, 0.020), "darkmetal", Vector3(0, 0.010, -0.045))  # core bezel
	# Three claw prongs reaching forward.
	_c(g, Vector3(0.030, 0.030, 0.200), "gunmetal", Vector3(0, 0.045, -0.200))  # prong top
	_c(g, Vector3(0.030, 0.030, 0.200), "gunmetal", Vector3(-0.045, -0.030, -0.200)) # prong L
	_c(g, Vector3(0.030, 0.030, 0.200), "gunmetal", Vector3(0.045, -0.030, -0.200))  # prong R
	_c(g, Vector3(0.034, 0.034, 0.050), "forge_orange", Vector3(0, 0.045, -0.290))   # prong tips
	_c(g, Vector3(0.034, 0.034, 0.050), "forge_orange", Vector3(-0.045, -0.030, -0.290))
	_c(g, Vector3(0.034, 0.034, 0.050), "forge_orange", Vector3(0.045, -0.030, -0.290))
	_c(g, Vector3(0.060, 0.120, 0.050), "darkmetal", Vector3(0, -0.100, 0.060)) # grip handle
	_c(g, Vector3(0.096, 0.020, 0.160), "tan", Vector3(0, -0.055, 0.02))        # tan wrap
	_c(g, Vector3(0.064, 0.012, 0.010), "tan", Vector3(0, -0.080, 0.060))       # grip ridge
	_c(g, Vector3(0.096, 0.012, 0.030), "darkmetal", Vector3(0, 0.068, -0.020)) # housing vent
	_anchor(g, "Sight", Vector3(0, 0.045, -0.200))
	_anchor(g, "Stock", Vector3(0, 0.0, 0.050))
	_anchor(g, "Grip", Vector3(0, -0.100, 0.060))
	_anchor(g, "Barrel", Vector3(0, 0.045, -0.300))
	_anchor(g, "Muzzle", Vector3(0, 0.010, -0.320))
	_anchor(g, "Eject", Vector3(0, 0.060, -0.020))
	return g
