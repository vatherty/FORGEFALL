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
		"weight": 5.2, # BB-5 (feel wave): gun weight — WeaponBase derives weight_norm from this; drives move/accel/spring/hitbox feel
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
		"weight": 8.6,
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
		"weight": 6.4,
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
		"weight": 3.8,
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
		"weight": 10.5,
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
		"weight": 3.0,
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
		"weight": 5.6,
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
		"weight": 6.8,
		"lower_time": 0.30,
		"reload_stages": [0.60, 1.10, 0.40],
		"cycle_time": 0.15, # cylinder rotation lockout between shots
		"sfx_fire": "shot_hv44",
		# Goal 1 FEEL contract: heavy kick, slow settle, big bright flash.
		"recoil_recover": 0.50,
		"muzzle_flash_time": 0.06,
		"muzzle_flash_energy": 6.0,
	},
	# Gameplay Rework (Zombies worker): the Zombies starter weapon —
	# a weak custom-made sidearm that barely dents anything (8 dmg:
	# ~13 body shots for a base grunt). Reuses the P9 viewmodel.
	"ember": {
		"weapon_id": "ember",
		"name": "SP-1 EMBER",
		"slot": "primary",
		"fire_mode": 1, # WeaponBase.FireMode.SEMI
		"rpm": 240.0,
		"damage": 8.0,
		"headshot_mult": 2.0,
		"mag_size": 8,
		"reserve": 32,
		"pellets": 1,
		"spread_hip": 0.050,
		"spread_move": 0.050,
		"near_range": 10.0,
		"far_range": 30.0,
		"falloff_min": 0.4,
		"recoil_pattern": [
			Vector2(0.005, 0.030),
		],
		"raise_time": 0.30,
		"weight": 3.0,
		"lower_time": 0.20,
		"reload_stages": [0.40, 0.70, 0.30],
		"cycle_time": 0.0,
		"sfx_fire": "shot_p9",
		"recoil_recover": 0.20,
		"muzzle_flash_time": 0.03,
		"muzzle_flash_energy": 2.5,
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
		"weight": 5.0,
		"lower_time": 0.30,
		"reload_stages": [0.2, 0.2, 0.2],
		"cycle_time": 0.0,
		"sfx_fire": "raptor_throw",
	},
}
#endregion

#region MOD WEAPONS (v0.5.9, Worker B; script mods unified v0.5.12)
## Installed user weapon-mods as first-class Arsenal entries.
## A weapon-mod is a JSON block mod (kind "block") whose block_info has
## target "weapon" and a base_weapon_id mapping to a base Arsenal id —
## OR a script mod (kind "script") whose block_info has target
## "weapon" (v0.5.12: script mods are loadout-compatible too — their
## behaviour lives in ModBlock.apply() code, which WeaponManager runs
## through the SAME ForgeBuilder path Forge uses; see
## ForgeBuilder.build_weapon_mod). A JSON weapon-mod is fully
## declarative (base stats x multipliers + data hooks + projectile
## spec), so Arsenal can build it exactly like
## ForgeBuilder._build_json_mod does for the weapon target. A script
## mod has NO declarative stats: Arsenal lists it (name/slot) and
## validates it, but NEVER builds it from stats — make_weapon refuses
## script mods and WeaponManager routes them to ForgeBuilder.
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
## weapon mod / JSON weapon block with no known base). Uses
## find_mod(..., false) so Arsenal lookups never pollute
## ModHookRegistry's find-pair history.
static func _mod_record(weapon_id: String) -> Dictionary:
	var mod_id := mod_id_of(weapon_id)
	if mod_id.is_empty():
		return {}
	var rec := ModLoader.find_mod(mod_id, false)
	if rec.is_empty() or not bool(rec.get("enabled", false)) or str(rec.get("error", "")) != "":
		return {}
	if not (str(rec.get("kind", "")) in ["block", "script"]):
		return {}
	var info: Dictionary = rec.get("block_info", {})
	if str(info.get("target", "")) != "weapon":
		return {}
	# JSON mods need a known base (Arsenal builds them from base
	# stats). Script mods need none: apply() decides what weapon it
	# grants, and WeaponManager routes them through ForgeBuilder.
	if str(rec.get("kind", "")) == "block" and _mod_base_id(rec).is_empty():
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
## id is not a live weapon-mod. SCRIPT MODS get a DISPLAY-ONLY dict
## (weapon_id / name / slot) — a script mod has no declarative stats,
## and feeding this to make_weapon would build a generic default gun.
## WeaponManager routes script mods through ForgeBuilder instead, so
## make_weapon never sees them; get_stats is only ever used for
## display names (Loadouts picker) on script ids.
static func _mod_stats(weapon_id: String) -> Dictionary:
	var rec := _mod_record(weapon_id)
	if rec.is_empty():
		return {}
	var info: Dictionary = rec.get("block_info", {})
	if str(rec.get("kind", "")) == "script":
		return {"weapon_id": weapon_id,
			"name": str(info.get("display_name", rec.get("name", weapon_id))),
			"slot": "primary"}
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


## BB-1 (ADS fix): the AUTHORITATIVE sight anchor per weapon — the
## viewmodel-local point that IS the aiming point (front-post tip / bead
## centre / lens centre / scope-tube centre). WeaponBase places the
## viewmodel at -anchor (x AND y) at full ADS, so this point lands exactly
## on the camera axis = screen centre. EVERY arsenal weapon has an
## explicit entry here: no silent defaults (unknown ids fall back to the
## model JSON anchor, then to a warned default — never for shipped ids).
##
## Values were re-derived 2026-11-26 from the shipped GLB geometry +
## rendered ADS captures (tools/verify_ads_alignment.gd), NOT from the
## old hand-tuned table: the JSON anchors were wrong for ember (0.074 vs
## the front-sight paint at 0.093), hv44 (0.089 vs the blade tip at
## 0.1025), p9 (0.070 vs the slide sight line at 0.0745) and sg12 (0.086
## vs the bead centre at 0.082), and the old ADS math ignored anchor X
## entirely (lmg sits 0.024 off the barrel axis -> +38 px on screen).
const SIGHT_ANCHOR := {
	"ar7": Vector3(0.0, 0.142, -0.118),   # reflex lens centre
	"lr8": Vector3(0.0, 0.111, -0.063),   # scope tube centre
	"sg12": Vector3(0.0, 0.082, -0.170),  # front bead centre (ghost ring)
	"smg9": Vector3(0.0, 0.147, -0.069),  # red-dot lens centre
	"lmg": Vector3(0.024, 0.143, 0.007),  # rear aperture centre (off-axis!)
	"p9": Vector3(0.0, 0.0745, -0.100),   # iron-sight line (post tips)
	"br3": Vector3(0.0, 0.193, -0.090),   # ACOG lens centre
	"hv44": Vector3(0.0, 0.1025, -0.180), # front blade tip
	"ember": Vector3(0.0, 0.093, -0.105), # painted front post tip
	"raptor": Vector3(0.0, 0.104, -0.120), # housing top centre (no true sight)
	"launcher": Vector3(0.0, 0.198, 0.001), # visual-family only (Forge-made)
}

## BB-1: optic class per weapon — drives ADS zoom + sensitivity scaling
## (player FOV block) and the HUD sniper-scope overlay. Explicit for
## every arsenal weapon, same rule as SIGHT_ANCHOR.
const OPTIC_CLASS := {
	"ar7": "reflex",
	"lr8": "scope",
	"sg12": "iron",
	"smg9": "reflex",
	"lmg": "iron",
	"p9": "iron",
	"br3": "acog",
	"hv44": "iron",
	"ember": "iron",
	"raptor": "none",
	"launcher": "iron",
}

## Effective ADS magnification per optic class. The player divides its
## preferred FOV by this (target_fov = preferred_fov / zoom) and scales
## ADS look sensitivity by 1/zoom, so a 5x scope is not 5x as twitchy.
const OPTIC_ZOOM := {
	"none": 1.0,
	"iron": 1.1,
	"reflex": 1.15,
	"acog": 3.0,
	"scope": 5.0,
}


## The family/id whose sight data a weapon uses: mod weapons resolve to
## their visual family (same rule sight_height always used).
static func _sight_family(weapon_id: String) -> String:
	if is_mod_weapon(weapon_id):
		var rec := _mod_record(weapon_id)
		if not rec.is_empty():
			var base_id := _mod_base_id(rec)
			return visual_family_for(rec.get("block_info", {}), base_id)
		return weapon_id
	return weapon_id


## The model's JSON "Sight" anchor (fallback for ids with no table
## entry — generated families etc.), or Vector3.INF when absent.
static func _json_sight_anchor(weapon_id: String) -> Vector3:
	var metadata_path := "res://assets/models/weapons/%s.json" % weapon_id
	if FileAccess.file_exists(metadata_path):
		var metadata: Variant = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
		if metadata is Dictionary:
			var anchors: Dictionary = (metadata as Dictionary).get("anchors", {})
			var sight: Variant = anchors.get("Sight", [])
			if sight is Array and (sight as Array).size() == 3:
				return Vector3(float((sight as Array)[0]), float((sight as Array)[1]), float((sight as Array)[2]))
	return Vector3.INF


## BB-1: the aiming point of a weapon in viewmodel-local space.
static func sight_anchor(weapon_id: String) -> Vector3:
	var fam := _sight_family(weapon_id)
	if SIGHT_ANCHOR.has(fam):
		return SIGHT_ANCHOR[fam]
	var from_json := _json_sight_anchor(fam)
	if from_json != Vector3.INF:
		return from_json
	push_warning("Arsenal.sight_anchor: no sight data for '%s' — using default" % weapon_id)
	return Vector3(0.0, 0.090, -0.100)


static func sight_height(weapon_id: String) -> float:
	return sight_anchor(weapon_id).y


## BB-1: "iron" / "reflex" / "acog" / "scope" / "none" for a weapon.
static func optic_class(weapon_id: String) -> String:
	var fam := _sight_family(weapon_id)
	return str(OPTIC_CLASS.get(fam, "iron"))


## BB-1: effective ADS magnification for a weapon (per optic class).
static func ads_zoom(weapon_id: String) -> float:
	return float(OPTIC_ZOOM.get(optic_class(weapon_id), 1.0))


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
## NEVER called for script-mod ids: WeaponManager routes those through
## ForgeBuilder.build_weapon_mod. A direct call with a script-mod id
## warns and returns a default-configured weapon (unreachable in the
## game; the guard exists so a script mod can never be built from
## display-only stats as a silent wrong gun).
static func make_weapon(weapon_id: String) -> WeaponBase:
	if is_mod_weapon(weapon_id) and str(_mod_record(weapon_id).get("kind", "")) == "script":
		push_warning("Arsenal.make_weapon: script mod %s must go through ForgeBuilder.build_weapon_mod" % weapon_id)
		var fallback := WeaponBase.new()
		fallback.setup((WEAPONS.get("ar7", {}) as Dictionary).duplicate(true))
		fallback.name = "Weapon_" + weapon_id.replace(":", "_")
		return fallback
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
static func build_viewmodel(weapon_id: String, visual_info: Dictionary = {}) -> Node3D:
	var vm := _build_viewmodel_raw(weapon_id, visual_info)
	# BB-1: the "Sight" marker IS the contract for the aiming point —
	# force it to the authoritative SIGHT_ANCHOR so the marker, the ADS
	# math and the rendered sight picture can never drift apart again
	# (the shipped JSON anchors disagreed with the actual geometry for
	# ember / hv44 / p9 / sg12). No-op when the id has no table entry
	# (JSON-only families keep their extracted anchor).
	if vm != null and SIGHT_ANCHOR.has(_sight_family(weapon_id)):
		var sight := vm.get_node_or_null("Sight") as Marker3D
		if sight != null:
			sight.position = SIGHT_ANCHOR[_sight_family(weapon_id)]
	# BB-1b: the shipped GLB reflex/ACOG lenses are OPAQUE plates — BB-1
	# centred the dot on them, but you still can't see through them
	# (Colin, on device: "the acog now has a dot, but it's still opaque
	# and can't see"). Turn the lens elements into real glass so the
	# world shows through around the dot. Scope (lr8) is untouched: its
	# viewmodel hides at full ADS and the HUD scope takes over.
	if vm != null and optic_class(weapon_id) in ["reflex", "acog"]:
		_carve_sight_tunnel(vm, sight_anchor(weapon_id))
		_make_optic_glass(vm)
	# BB-1c/BB-1d: glass-optic weapons gain the picture-in-picture lens
	# screen inside the carved tunnel (BB-1c ACOG — Colin: keep the 3x
	# FOV zoom AND "a zoom and parallax effect on the lens as well";
	# BB-1d extends it to the reflex family — "the red dot sight needs
	# similar treatment. Just without the zoom, just parallax"). The
	# screen itself is inert — WeaponBase owns the lens camera rig,
	# binds the viewport texture and drives the shader (pip_strength /
	# eye_offset / sample_rect). With no rig bound it renders as BB-1b
	# glass, so standalone builds (verifies, Studio previews) keep the
	# see-through tunnel.
	if vm != null and optic_class(weapon_id) in ["reflex", "acog"]:
		_add_pip_screen(vm, sight_anchor(weapon_id), optic_class(weapon_id),
			_sight_family(weapon_id))
	return vm


## BB-1c/BB-1d: PiP screen geometry per sight family, measured from
## the shipped GLBs (2026-11-26). The screen sits at the tunnel's rear
## plane; from the eye it overfills the window and reads as the
## optic's rear lens. The shader discards outside the aperture, so a
## quad is the whole mesh. Added AFTER the carve: the screen is the
## sight picture, not a blocker (the ADS verify's tunnel check skips
## it by name).
##   br3 (ACOG): window ("Optic front glass") 52x36 mm at z -0.125
##     around the anchor (0, 0.193, -0.090) -> 34 mm disc (the window's
##     inner height, less a bezel's width) at anchor + 0.042.
##   ar7 (reflex): lens plate ("Optic lens front") 49x45 mm at
##     z -0.154 around the anchor (0, 0.142, -0.118); plate layers at
##     z -0.152 / -0.083 -> 40x34 mm rounded-rect screen at +0.038.
##   smg9 (reflex): lens plate ("Red dot front lens") 48x39 mm at
##     z -0.101 around the anchor (0, 0.147, -0.069), same 3-plate
##     pattern -> 40x30 mm rounded-rect screen at +0.038.
const PIP_SCREEN_SIZE := {
	"br3": Vector2(0.034, 0.034),
	"ar7": Vector2(0.040, 0.034),
	"smg9": Vector2(0.040, 0.030),
}
const PIP_SCREEN_Z := {"br3": 0.042, "ar7": 0.038, "smg9": 0.038}
# Fallback for mod families built on a reflex/ACOG base without their
# own table entry (their anchor comes from the base family too).
const PIP_SCREEN_SIZE_DEFAULT := Vector2(0.036, 0.030)
const PIP_SCREEN_Z_DEFAULT := 0.038


## The viewmodel node name of a family's PiP screen (WeaponBase binds
## the lens rig by this name).
static func pip_screen_name(optic: String) -> String:
	return "AcogPipScreen" if optic == "acog" else "ReflexPipScreen"


static func _add_pip_screen(vm: Node3D, anchor: Vector3, optic: String, family: String) -> void:
	var screen_name := pip_screen_name(optic)
	if vm.get_node_or_null(screen_name) != null:
		return # mod weapons: the recursive base build already added it
	var size: Vector2 = PIP_SCREEN_SIZE.get(family, PIP_SCREEN_SIZE_DEFAULT)
	var disc := MeshInstance3D.new()
	disc.name = screen_name
	var quad := QuadMesh.new()
	quad.size = size
	disc.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://assets/shaders/optic_lens.gdshader")
	# Per-family look (see optic_lens.gdshader's header): the ACOG
	# keeps the shader defaults (full-frame sample, cross + dot,
	# circular aperture, 0.85 shadow); the reflex family gets the
	# dot-only reticle in a rounded-rect aperture, a subtler shadow
	# (open housing — the swim is the star), a chunkier dot, and a
	# centre-crop sample_rect that WeaponBase feeds per frame (its
	# camera runs at main fov — no zoom — so the crop is what makes
	# the picture register 1:1 with the surrounding view).
	if optic == "reflex":
		mat.set_shader_parameter("reticle_style", 1)
		mat.set_shader_parameter("aperture_shape", 1)
		mat.set_shader_parameter("aperture_aspect", size.x / size.y)
		mat.set_shader_parameter("corner_radius", 0.16)
		mat.set_shader_parameter("shadow_strength", 0.45)
		mat.set_shader_parameter("dot_radius", 0.07)
	disc.material_override = mat
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	disc.position = Vector3(anchor.x, anchor.y,
		anchor.z + float(PIP_SCREEN_Z.get(family, PIP_SCREEN_Z_DEFAULT)))
	vm.add_child(disc)


## BB-1b: the GLB optics are SOLID — behind the front lens plate, two
## more plates cross the sight line (measured: ar7 layers at z -0.152
## and -0.083 around the -0.118 anchor; same pattern on smg9/br3), so
## glass alone still shows a dark plug. Carve a 30 mm tunnel along the
## sight axis through every mesh in the viewmodel: any triangle whose
## centroid lands inside the tunnel box is dropped. The lens plate
## keeps its rim (tunnel is narrower than the lens), the housing keeps
## its frame — the centre becomes a genuinely open aperture with the
## AdsDot floating in it. Mesh RESOURCES are never mutated: affected
## nodes get a rebuilt ArrayMesh (the GLB resource is shared).
static func _carve_sight_tunnel(vm: Node3D, anchor: Vector3) -> void:
	var half := 0.015
	var box := AABB(
		Vector3(anchor.x - half, anchor.y - half, anchor.z - 0.055),
		Vector3(half * 2.0, half * 2.0, 0.110))
	var stack: Array = [vm]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := _transform_relative_to(mi, vm)
		var rebuilt: ArrayMesh = null
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var kept: Variant = _drop_tunnel_triangles(arrays, rel, box)
			if kept == null:
				if rebuilt != null:
					rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
					var keep_mat := mi.mesh.surface_get_material(s)
					if keep_mat != null:
						rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, keep_mat)
				continue
			if rebuilt == null:
				rebuilt = ArrayMesh.new()
				# Re-add any earlier surfaces untouched before this one.
				for prev in s:
					rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mi.mesh.surface_get_arrays(prev))
					var prev_mat := mi.mesh.surface_get_material(prev)
					if prev_mat != null:
						rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, prev_mat)
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, kept)
			var mat := mi.mesh.surface_get_material(s)
			if mat != null:
				rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, mat)
		if rebuilt != null:
			mi.mesh = rebuilt


## Transform of `node` expressed in `root`'s local space (both in the
## same detached subtree at build time).
static func _transform_relative_to(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


## Return surface arrays with every triangle whose centroid (in
## viewmodel space) falls inside `box` removed, or null when nothing
## was removed. Handles indexed and non-indexed triangle arrays.
static func _drop_tunnel_triangles(arrays: Array, rel: Transform3D, box: AABB) -> Variant:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return null
	var vcount := verts.size()
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var tri_ids: Array = []
	if index.size() > 0:
		for t in range(0, index.size(), 3):
			tri_ids.append([index[t], index[t + 1], index[t + 2]])
	else:
		for t in range(0, vcount, 3):
			tri_ids.append([t, t + 1, t + 2])
	var keep: Array = []
	var removed := 0
	for tri in tri_ids:
		var c := Vector3.ZERO
		for k in 3:
			c += rel * verts[tri[k]]
		c /= 3.0
		if box.has_point(c):
			removed += 1
		else:
			keep.append(tri)
	if removed == 0:
		return null
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	if index.size() > 0:
		# Indexed: keep the vertex arrays whole, filter the index list.
		for i in Mesh.ARRAY_MAX:
			out[i] = arrays[i]
		var new_index := PackedInt32Array()
		for tri in keep:
			new_index.append_array(PackedInt32Array([tri[0], tri[1], tri[2]]))
		out[Mesh.ARRAY_INDEX] = new_index
	else:
		# Non-indexed: filter every per-vertex array in lockstep.
		for i in Mesh.ARRAY_MAX:
			var arr: Variant = arrays[i]
			if arr == null or typeof(arr) == TYPE_NIL:
				out[i] = arr
				continue
			var stride := 0
			match typeof(arr):
				TYPE_PACKED_VECTOR3_ARRAY:
					stride = 3
				TYPE_PACKED_VECTOR2_ARRAY:
					stride = 2
				TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_BYTE_ARRAY:
					stride = int(arr.size()) / vcount
				TYPE_PACKED_COLOR_ARRAY:
					stride = 4
				TYPE_PACKED_VECTOR4_ARRAY:
					stride = 4
			if stride <= 0:
				out[i] = arr
				continue
			out[i] = _filter_packed(arr, stride, keep)
	return out


static func _filter_packed(arr: Variant, stride: int, keep: Array) -> Variant:
	match typeof(arr):
		TYPE_PACKED_VECTOR3_ARRAY:
			var src := arr as PackedVector3Array
			var dst := PackedVector3Array()
			for tri in keep:
				for k in 3:
					dst.append(src[tri[k]])
			return dst
		TYPE_PACKED_VECTOR2_ARRAY:
			var src := arr as PackedVector2Array
			var dst := PackedVector2Array()
			for tri in keep:
				for k in 3:
					dst.append(src[tri[k]])
			return dst
		TYPE_PACKED_COLOR_ARRAY:
			var src := arr as PackedColorArray
			var dst := PackedColorArray()
			for tri in keep:
				for k in 3:
					dst.append(src[tri[k]])
			return dst
		TYPE_PACKED_VECTOR4_ARRAY:
			var src := arr as PackedVector4Array
			var dst := PackedVector4Array()
			for tri in keep:
				for k in 3:
					dst.append(src[tri[k]])
			return dst
		TYPE_PACKED_FLOAT32_ARRAY:
			var src := arr as PackedFloat32Array
			var dst := PackedFloat32Array()
			for tri in keep:
				for k in 3:
					for e in stride:
						dst.append(src[tri[k] * stride + e])
			return dst
		TYPE_PACKED_INT32_ARRAY:
			var src := arr as PackedInt32Array
			var dst := PackedInt32Array()
			for tri in keep:
				for k in 3:
					for e in stride:
						dst.append(src[tri[k] * stride + e])
			return dst
		TYPE_PACKED_BYTE_ARRAY:
			var src := arr as PackedByteArray
			var dst := PackedByteArray()
			for tri in keep:
				for k in 3:
					for e in stride:
						dst.append(src[tri[k] * stride + e])
			return dst
	return arr


## BB-1b: replace the material on every lens/glass element of a
## reflex/ACOG viewmodel with transparent glass. The GLB names its lens
## nodes ("Optic lens front", "Red dot front lens", "Optic front
## glass"); each keeps its own coated-lens hue at low alpha, depth
## write OFF so the glass never occludes the world or the AdsDot (the
## dot has no_depth_test + render_priority 10 and draws over it).
## Surface OVERRIDE only — the shared GLB materials are never mutated.
static func _make_optic_glass(vm: Node) -> void:
	for node in _lens_nodes(vm):
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s)
			var glass := StandardMaterial3D.new()
			glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var hue := Color(0.55, 0.62, 0.70)
			if src is StandardMaterial3D:
				var a := (src as StandardMaterial3D).albedo_color
				hue = Color(a.r, a.g, a.b)
			glass.albedo_color = Color(hue.r, hue.g, hue.b, 0.20)
			glass.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			glass.roughness = 0.12
			mi.set_surface_override_material(s, glass)


static func _lens_nodes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		var lname := node.name.to_lower()
		if lname.contains("lens") or lname.contains("glass"):
			out.append(node)
	for child in node.get_children():
		out.append_array(_lens_nodes(child))
	return out


static func _build_viewmodel_raw(weapon_id: String, visual_info: Dictionary = {}) -> Node3D:
	if is_mod_weapon(weapon_id):
		var rec := _mod_record(weapon_id)
		if not rec.is_empty():
			return build_viewmodel(_mod_base_id(rec), rec.get("block_info", {}))
		return _build_ar7()
	var visual_id := visual_family_for(visual_info, weapon_id)
	var imported := _load_imported_viewmodel(visual_id)
	if imported != null:
		if not visual_info.is_empty():
			_apply_visual_modules(imported, visual_info)
		return imported
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
		"ember":
			return _build_p9()
		"raptor":
			return _build_raptor()
	return _build_ar7()


## Generated weapons retain their validated gameplay base. Their name and
## description choose a visual family independently, so an invented launcher
## can have a launcher body while its stats and projectile hooks still use a
## known weapon. This is deterministic and bounded to shipped assets.
static func visual_family_for(info: Dictionary, fallback_id: String) -> String:
	var words := ("%s %s" % [str(info.get("display_name", "")), str(info.get("description", ""))]).to_lower()
	for word in ["launcher", "cannon", "bazooka", "mortar", "rocket", "rpg"]:
		if words.contains(word):
			return "launcher"
	for word in ["sniper", "marksman", "long rifle"]:
		if words.contains(word):
			return "lr8"
	for word in ["shotgun", "blunderbuss"]:
		if words.contains(word):
			return "sg12"
	for word in ["revolver", "hand cannon"]:
		if words.contains(word):
			return "hv44"
	for word in ["machine gun", "minigun", "gatling", "lmg"]:
		if words.contains(word):
			return "lmg"
	for word in ["smg", "submachine", "machine pistol"]:
		if words.contains(word):
			return "smg9"
	for word in ["burst rifle", "bullpup"]:
		if words.contains(word):
			return "br3"
	for word in ["pistol", "sidearm"]:
		if words.contains(word):
			return "p9"
	return fallback_id


## Small shipped modules give generated weapons a distinct profile without
## running model-generated code. Optional words select one module per slot.
static func _apply_visual_modules(root: Node3D, info: Dictionary) -> void:
	var words := ("%s %s" % [str(info.get("display_name", "")), str(info.get("description", ""))]).to_lower()
	if words.contains("suppress") or words.contains("silenc"):
		_attach_visual_module(root, "muzzle_suppressor", "Muzzle")
	elif words.contains("oversized muzzle") or words.contains("wide muzzle"):
		_attach_visual_module(root, "muzzle_launcher_cup", "Muzzle")
	elif words.contains("muzzle brake"):
		_attach_visual_module(root, "muzzle_brake", "Muzzle")
	if words.contains("drum") or words.contains("belt fed"):
		_attach_visual_module(root, "magazine_drum", "Grip")
	if words.contains("folding stock"):
		_attach_visual_module(root, "stock_folding", "Stock")
	if words.contains("hazard") or words.contains("warning stripe"):
		_attach_visual_module(root, "accent_hazard_stripe", "Barrel")
	elif words.contains("heat shield"):
		_attach_visual_module(root, "accent_heat_shield", "Barrel")


static func _attach_visual_module(root: Node3D, module_id: String, anchor_name: String) -> void:
	var anchor := root.get_node_or_null(anchor_name) as Marker3D
	var path := "res://assets/models/weapons/attachments/%s.glb" % module_id
	if anchor == null or not ResourceLoader.exists(path):
		return
	var packed := load(path) as PackedScene
	if packed == null:
		return
	var part := packed.instantiate() as Node3D
	if part == null:
		return
	part.name = "Module_" + module_id
	root.add_child(part)
	part.position = anchor.position
	# Muzzle modules begin at the original barrel tip and project along -Z.
	# Move the gameplay marker to the visible exit so shots and flashes do not
	# originate inside a suppressor, brake, or launcher cup.
	match module_id:
		"muzzle_brake":
			anchor.position.z -= 0.093
		"muzzle_suppressor":
			anchor.position.z -= 0.199
		"muzzle_launcher_cup":
			anchor.position.z -= 0.218


## Code-authored Three.js models are exported to GLB with a JSON anchor
## manifest. Keep markers as direct children for WeaponBase's muzzle flash,
## casing ejection, and attachment lookups. The old procedural model remains
## a fallback when the GLB has not been imported yet.
static func _load_imported_viewmodel(weapon_id: String) -> Node3D:
	var path := "res://assets/models/weapons/%s.glb" % weapon_id
	var metadata_path := "res://assets/models/weapons/%s.json" % weapon_id
	if not ResourceLoader.exists(path) or not FileAccess.file_exists(metadata_path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var metadata: Variant = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
	if not (metadata is Dictionary):
		return null
	var anchors: Dictionary = (metadata as Dictionary).get("anchors", {})
	if not anchors.has("Muzzle") or not anchors.has("Eject"):
		return null
	var root := Node3D.new()
	root.name = "VM_" + weapon_id
	var model := packed.instantiate() as Node3D
	if model == null:
		return null
	root.add_child(model)
	for anchor_name in anchors:
		var p: Variant = anchors[anchor_name]
		if not (p is Array) or (p as Array).size() != 3:
			continue
		var marker := Marker3D.new()
		marker.name = str(anchor_name)
		marker.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
		root.add_child(marker)
	return root


# M4-like carbine: receiver, tan handguard, carry-handle-ish rear sight,
# front post, curved mag, stock, grip.
static func _build_ar7() -> Node3D:
	var g := Node3D.new()
	g.name = "VM_ar7"
	# v5 prop: 1309 voxels at 0.017 m pitch, voxelized from weapon-refs/ar7_v4/ (cubes.json is the source).
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, -0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, -0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, -0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, -0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, -0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, 0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, 0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, 0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, 0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0415, 0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.1743, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.1743, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.1743, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.1411, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.1411, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.1411, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.1079, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.1079, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.1079, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.0913, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.0913, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0249, -0.0913, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0747, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0747, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0747, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0747, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0581, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0581, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0581, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0581, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0581, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0581, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0581, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0415, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0415, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0249, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0249, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, -0.0249, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, -0.0249, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, -0.0083, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, -0.0083, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, -0.0083, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, -0.0083, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0083, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0083, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0249, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0249, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0249, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0249, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0249, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0249, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0249, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0249, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0249, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0249, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0415, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0415, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0415, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0415, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0415, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0415, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0415, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0415, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0249, 0.0415, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0415, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0415, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0249, 0.0581, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0581, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0249, 0.0581, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0249, 0.0581, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0249, 0.0581, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0249, 0.0581, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0249, 0.0581, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0249, 0.0581, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0249, 0.0581, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0747, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0249, 0.0913, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1743, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1743, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1743, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, -0.1577, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.1577, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(-0.0083, -0.1577, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1577, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1577, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1577, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.1411, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.1411, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.1411, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1411, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1411, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1411, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.1245, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, -0.1245, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(-0.0083, -0.1245, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1245, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1245, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1245, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(-0.0083, -0.1079, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(-0.0083, -0.1079, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.1079, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.1079, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.1079, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1079, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1079, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.1079, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0913, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0913, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0913, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0913, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0913, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0913, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0913, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0913, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0913, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(-0.0083, -0.0747, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(-0.0083, -0.0747, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0747, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0747, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(-0.0083, -0.0747, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(-0.0083, -0.0747, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0747, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0747, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0747, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0581, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0581, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(-0.0083, -0.0581, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0581, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0581, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0581, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0581, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0581, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0581, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0581, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0581, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0415, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0415, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0415, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0415, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0415, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0415, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0415, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0249, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0249, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0249, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0249, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0249, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0249, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0249, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0249, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0249, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.6225))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.6059))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, -0.0083, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, -0.0083, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0083, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, -0.0083, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.6225))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.6059))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.5893))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.5727))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.5561))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.5395))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.5229))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0083, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0083, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, -0.6225))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.6059))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0249, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0249, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0249, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0249, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0415, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(-0.0083, 0.0415, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0415, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0415, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(-0.0083, 0.0581, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, 0.0581, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, 0.0581, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, 0.0581, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, 0.0581, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, 0.0581, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, 0.0581, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(-0.0083, 0.0581, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(-0.0083, 0.0913, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1743, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1743, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1743, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.1577, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.1577, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.1577, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1577, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1577, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1577, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.1411, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.1411, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.1411, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1411, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1411, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.1411, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.1245, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.1245, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.1245, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1245, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1245, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.1245, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.1079, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.1079, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.1079, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.1079, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.1079, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1079, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1079, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.1079, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0913, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0913, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0913, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0913, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0913, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0913, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0913, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0913, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0913, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.0747, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.0747, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.0747, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.0747, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "olive", Vector3(0.0083, -0.0747, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0747, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0581, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0581, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0083, -0.0581, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0581, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0581, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0581, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0581, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0581, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0581, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0581, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0581, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0581, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0415, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0415, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0415, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0415, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0415, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0415, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0415, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0249, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0249, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0249, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0249, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.6225))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.6059))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, -0.0083, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, -0.0083, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0083, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, -0.0083, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.6225))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.6059))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.5893))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.5727))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.5561))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.5395))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.5229))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0083, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0083, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0249, -0.6225))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.6059))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0249, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0249, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0249, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0249, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0249, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0249, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0249, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0249, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0249, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0415, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0415, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0415, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0415, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0415, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0415, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0415, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0415, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0083, 0.0415, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0415, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0415, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0581, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0083, 0.0581, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0083, 0.0581, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0083, 0.0581, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0083, 0.0581, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0083, 0.0581, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0083, 0.0581, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0083, 0.0581, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0083, 0.0581, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0747, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0913, -0.5063))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0083, 0.0913, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.1743, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.1743, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.1743, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.1411, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.1411, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.1411, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.1079, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.1079, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.1079, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.0913, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.0913, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "shirt_green", Vector3(0.0249, -0.0913, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0747, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0747, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0747, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0747, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0581, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0581, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0581, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0581, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0581, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0581, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0581, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0415, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0415, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0249, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0249, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, -0.0249, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, -0.0249, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, -0.0083, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, -0.0083, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, -0.0083, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, -0.0083, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0083, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0083, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0249, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0249, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0249, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0249, 0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0249, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0249, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0249, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.4233))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.3901))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.2905))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.2573))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0415, 0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.0415))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.0747))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "gunmetal", Vector3(0.0249, 0.0415, 0.2075))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0415, 0.2241))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0415, 0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.4897))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.4565))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.3735))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.3403))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.3071))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.2739))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.2407))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.0581))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "tan", Vector3(0.0249, 0.0581, -0.0249))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0581, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0249, 0.0581, 0.0913))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0249, 0.0581, 0.1079))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0249, 0.0581, 0.1245))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0249, 0.0581, 0.1411))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0249, 0.0581, 0.1577))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0249, 0.0581, 0.1743))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "canvas", Vector3(0.0249, 0.0581, 0.1909))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0747, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0249, 0.0913, -0.0083))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, -0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, -0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, -0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, -0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, -0.0083, -0.3237))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, 0.0083, -0.4731))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, 0.0083, -0.4399))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, 0.0083, -0.4067))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, 0.0083, -0.3569))
	_c(g, Vector3(0.0166, 0.0166, 0.0166), "darkmetal", Vector3(0.0415, 0.0083, -0.3237))
	_anchor(g, "Sight", Vector3(0, 0.09, -0.1))
	_anchor(g, "Stock", Vector3(0, -0.005, 0.2))
	_anchor(g, "Grip", Vector3(0, -0.095, 0.045))
	_anchor(g, "Barrel", Vector3(0, 0.008, -0.52))
	_anchor(g, "Muzzle", Vector3(0, 0.008, -0.635))
	_anchor(g, "Eject", Vector3(0.055, 0.03, -0.02))
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
