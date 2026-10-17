# FORGEFALL — WeaponManager
# Child of the player ("WeaponManager"). Owns three slots — primary,
# secondary, prototype (Raptor claw) — builds weapons via Arsenal, routes
# fire/ads/reload input to the current weapon, and handles switch timing
# (lower current -> swap -> raise new). Re-emits ammo_changed and
# weapon_changed for the HUD.
#
# INPUT ACTIONS (defined by the project-setup worker): "fire", "ads",
# "reload", "slot_1", "slot_2", "slot_3". Every read is guarded with
# InputMap.has_action so missing actions fail soft, not loud.
# ADS: the player worker emits ads_changed(active); the manager connects to
# it and forwards to the weapon. If the player has no such signal yet, the
# manager polls the "ads" action itself as a fallback.
class_name WeaponManager
extends Node3D

signal ammo_changed(mag: int, reserve: int)
signal weapon_changed(display_name: String)

const SLOT_ORDER := ["primary", "secondary", "prototype"]
const DEFAULT_LOADOUT := {"primary": "ar7", "secondary": "p9", "prototype": "raptor"}

## v0.6 LOADOUTS: free gear presets (NOT Forge builds — no budget cost).
## Weapon ids verified against Arsenal.WEAPONS (ar7/lr8/sg12/smg9/p9/raptor).
## NOTE: "secondary" here is the WeaponManager slot, not Arsenal's
## "slot" stat — smg9/raptor ride in the secondary slot for Breacher/Raptor
## even though Arsenal labels them primary/prototype.
const LOADOUTS := {
	"Assault": {"primary": "ar7", "secondary": "p9"},
	"Marksman": {"primary": "lr8", "secondary": "p9"},
	"Breacher": {"primary": "sg12", "secondary": "smg9"},
	"Raptor": {"primary": "raptor", "secondary": "smg9"},
	# Goal 3 CONTENT: showcases both new guns — burst rifle + heavy revolver.
	"Burst": {"primary": "br3", "secondary": "hv44"},
}

var _player: Node = null
var _camera: Camera3D = null
var _weapons: Dictionary = {}   # slot -> WeaponBase
var _current_slot: String = "primary"
var _current: WeaponBase = null
var _switching: bool = false
var _ads_active: bool = false
var _ads_signal_hooked: bool = false
var _poll_ads_fallback: bool = false
# v0.5.3: last observed player HP for the on_damage_taken hook poll
# (-1 = not yet observed). See _poll_damage_taken().
var _last_player_hp := -1.0


func _ready() -> void:
	add_to_group("weapon_manager")
	_player = get_parent()
	_find_camera()
	for slot in SLOT_ORDER:
		_weapons[slot] = _build_weapon(DEFAULT_LOADOUT[slot])
	_current = _weapons[_current_slot]
	_current.on_equip()
	_hook_ads()
	weapon_changed.emit.call_deferred(_current.display_name)
	_current.emit_ammo.call_deferred()


func _build_weapon(weapon_id: String) -> WeaponBase:
	var w := Arsenal.make_weapon(weapon_id)
	add_child(w)
	w.attach(_player, _camera)
	w.ammo_changed.connect(_on_weapon_ammo)
	w.on_unequip() # parked + hidden until equipped
	return w


func _find_camera() -> void:
	if _player == null:
		return
	var vp := _player.get_viewport()
	if vp != null:
		_camera = vp.get_camera_3d()


func _hook_ads() -> void:
	if _player != null and _player.has_signal("ads_changed"):
		_player.ads_changed.connect(_on_player_ads_changed)
		_ads_signal_hooked = true
	else:
		_poll_ads_fallback = true


func _process(_delta: float) -> void:
	# v0.5.9 MOD WEAPONS: a mod weapon whose mod was disabled / removed
	# / broken mid-match drops out to its slot fallback (its hooks
	# would already stop via the registry's live-record gate; this also
	# drops the baked multipliers + custom projectile). Base weapons
	# cost one begins_with check each — see prune_stale_mod_weapons().
	prune_stale_mod_weapons()
	# v0.5.3: on_damage_taken hooks for the equipped mod weapon (see
	# _poll_damage_taken). Runs even when there is no current weapon —
	# it only tracks HP then.
	_poll_damage_taken()
	if _current == null:
		return
	if _camera == null or not is_instance_valid(_camera):
		_find_camera()
		if _camera == null:
			return
		for w in _weapons.values():
			(w as WeaponBase).attach(_player, _camera)
		# First camera acquisition: the current weapon's viewmodel was
		# parked on the weapon node — move it onto the camera now.
		_current.on_equip()
		_current.set_ads(_ads_active)
	# ADS (fallback poll only when the player has no ads_changed signal).
	if _poll_ads_fallback and InputMap.has_action("ads"):
		var ads_now := Input.is_action_pressed("ads")
		if ads_now != _ads_active:
			_ads_active = ads_now
			_current.set_ads(_ads_active)
	# Slot switching: direct slots, then cycle (weapon_next/prev:
	# mouse wheel by default; gamepad users have the D-pad slots and
	# can rebind these to any button in Options > CONTROLS).
	if not _switching:
		if _slot_pressed(0):
			switch_to("primary")
		elif _slot_pressed(1):
			switch_to("secondary")
		elif _slot_pressed(2):
			switch_to("prototype")
		elif InputMap.has_action("weapon_next") and Input.is_action_just_pressed("weapon_next"):
			_cycle_slot(1)
		elif InputMap.has_action("weapon_prev") and Input.is_action_just_pressed("weapon_prev"):
			_cycle_slot(-1)
	# Fire / reload routing.
	if not _switching:
		if InputMap.has_action("fire"):
			if Input.is_action_just_pressed("fire"):
				_current.trigger_pressed()
			if Input.is_action_pressed("fire"):
				_current.trigger_held()
			if Input.is_action_just_released("fire"):
				_current.trigger_released()
		if InputMap.has_action("reload") and Input.is_action_just_pressed("reload"):
			_current.try_reload()


## Cycle to the next (+1) / previous (-1) weapon slot that actually
## holds a weapon, wrapping around. No-op with fewer than two weapons.
func _cycle_slot(dir: int) -> void:
	var order: Array[String] = ["primary", "secondary", "prototype"]
	var cur := order.find(_current_slot)
	if cur < 0:
		cur = 0
	for i in range(1, order.size() + 1):
		var nxt := order[(cur + dir * i) % order.size()] if dir >= 0 else order[(cur + dir * i + order.size() * 3) % order.size()]
		if _weapons.has(nxt):
			switch_to(nxt)
			return


func _slot_pressed(idx: int) -> bool:
	var action := "slot_%d" % (idx + 1)
	return InputMap.has_action(action) and Input.is_action_just_pressed(action)


func _on_player_ads_changed(active: bool) -> void:
	_ads_active = active
	if _current != null and not _switching:
		_current.set_ads(active)


func _on_weapon_ammo(mag: int, reserve: int) -> void:
	ammo_changed.emit(mag, reserve)


## Switch to a slot with lower/raise timing.
func switch_to(slot: String) -> void:
	if slot == _current_slot or _switching or not _weapons.has(slot):
		return
	_switching = true
	var old := _current
	old.begin_lower()
	old.set_ads(false)
	await get_tree().create_timer(old.lower_time).timeout
	if not is_instance_valid(old):
		_switching = false
		return
	old.on_unequip()
	_current_slot = slot
	_current = _weapons[slot]
	_current.attach(_player, _camera)
	_current.on_equip()
	_current.set_ads(_ads_active)
	_switching = false
	weapon_changed.emit(_current.display_name)


## Forge hook: replace the primary weapon with a new id (adds or upgrades).
## v0.5.3: after the swap, a pending mod attach (see ModHookRegistry)
## is consumed onto the fresh weapon — this is how a Forge-built mod
## weapon gets its hooks + custom projectile, since ForgeBuilder calls
## this with only the base arsenal id. Plain weapons (no pending mod)
## are untouched.
func give_weapon(weapon_id: String) -> void:
	set_slot("primary", weapon_id)
	# v0.5.9 MOD WEAPONS: a mod weapon already carries its hooks +
	# projectile spec from Arsenal stats (WeaponBase.setup) — the
	# pending-attach path below is for Forge-built BASE weapons only.
	# Attaching pending state to a mod weapon would overwrite its own
	# hooks with whatever a stale Forge build left behind.
	if Arsenal.is_mod_weapon(weapon_id):
		return
	var fresh: WeaponBase = _weapons.get("primary")
	if fresh != null:
		ModHookRegistry.try_attach_pending(fresh, weapon_id)


## v0.5.3: on_damage_taken hooks for the equipped mod weapon. The
## player script is not owned by this worker, so there is no
## pre-damage interception point: instead this poll watches the
## player's HP. On a drop, the current weapon's on_damage_taken hooks
## run (heal / explosion / smoke / announce effects apply directly),
## and a damage_mult < 1 is applied retroactively as a heal of the
## reduced portion — net HP is exactly correct; the hurt feedback
## still plays for one frame. A damage_mult > 1 (vulnerability) is
## ignored here: amplifying damage retroactively would re-trigger
## the poll on its own extra damage, so vulnerability needs the
## player-side pre-damage call (ModHookRegistry/ModAPI surface is
## ready for it). HP rises (regen, respawn, heals) never trigger hooks.
## No-op without a player, without an HP var, or without attached hooks.
func _poll_damage_taken() -> void:
	if _player == null or not is_instance_valid(_player):
		_last_player_hp = -1.0
		return
	var hp_v: Variant = _player.get("_hp")
	if not (hp_v is int or hp_v is float):
		return
	var hp := float(hp_v)
	if _last_player_hp < 0.0:
		_last_player_hp = hp
		return
	if hp >= _last_player_hp - 0.001:
		_last_player_hp = hp
		return
	var damage_taken := _last_player_hp - hp
	_last_player_hp = hp
	if _current == null or _current.mod_hooks.is_empty():
		return
	var has_point := false
	for h in _current.mod_hooks:
		if h is Dictionary and str((h as Dictionary).get("hook_point", "")) == "on_damage_taken":
			has_point = true
			break
	if not has_point:
		return
	var root: Node = null
	if is_inside_tree():
		var tree := get_tree()
		if tree != null:
			root = tree.current_scene
			if root == null:
				root = tree.root
	var api := ModAPI.new(_player as Node3D, root)
	var ppos := Vector3.ZERO
	if _player is Node3D:
		ppos = (_player as Node3D).global_position
	var ctx := {"damage": damage_taken, "hp_before": _last_player_hp + damage_taken,
		"hp_after": hp, "position": ppos,
		"weapon_id": _current.weapon_id}
	var res := ModHookRegistry.run_hooks(_current.mod_hooks, "on_damage_taken", api, ctx)
	# damage_mult < 1: retroactive reduction — heal back the portion
	# the hooks negated, so net HP equals the reduced damage.
	var mult := float(res.get("damage_mult", 1.0))
	if mult < 1.0:
		api.heal_player(damage_taken * (1.0 - mult))
	# Hooks may have healed: re-observe HP so the heal is not mistaken
	# for a second event (and so a heal does not mask a later drop).
	var hp2: Variant = _player.get("_hp")
	if hp2 is int or hp2 is float:
		_last_player_hp = float(hp2)


## v0.6 LOADOUTS: replace the weapon in a GIVEN slot, reusing the same
## replacement logic give_weapon used for primary (disconnect, unequip,
## queue_free old, build new, equip if it is the current slot). No budget
## is touched here — loadouts are free gear, never Forge builds.
## v0.5.12 UNIFIED GIVE PATH: a SCRIPT-mod weapon id ("mod:<id>" for a
## kind="script" weapon mod) does NOT go through Arsenal.make_weapon
## (Arsenal has no declarative stats for it) — it routes through
## ForgeBuilder.build_weapon_mod, the SAME path Forge uses for a
## mod_block weapon spec, so Forge / Arsenal / Loadouts all construct a
## script-mod weapon identically. The script's apply() grants the base
## weapon via the nested give_weapon -> set_slot(base) call below.
func set_slot(slot: String, weapon_id: String) -> void:
	if not slot in SLOT_ORDER or not Arsenal.has_weapon(weapon_id):
		return
	if Arsenal.is_mod_weapon(weapon_id) and _is_script_mod_weapon(weapon_id):
		_set_script_mod_slot(slot, weapon_id)
		return
	var old: WeaponBase = _weapons.get(slot)
	if old != null:
		old.ammo_changed.disconnect(_on_weapon_ammo)
		old.on_unequip() # pull its viewmodel back off the camera first
		old.queue_free()
	var w := _build_weapon(weapon_id)
	_weapons[slot] = w
	if _current_slot == slot and not _switching:
		_current = w
		_current.on_equip()
		_current.set_ads(_ads_active)
		weapon_changed.emit(_current.display_name)


## True when `weapon_id` is a live SCRIPT-mod weapon id.
static func _is_script_mod_weapon(weapon_id: String) -> bool:
	var mod_id := Arsenal.mod_id_of(weapon_id)
	if mod_id.is_empty():
		return false
	var rec := ModLoader.find_mod(mod_id, false)
	if rec.is_empty() or not bool(rec.get("enabled", false)) or str(rec.get("error", "")) != "":
		return false
	return str(rec.get("kind", "")) == "script" and str((rec.get("block_info", {}) as Dictionary).get("target", "")) == "weapon"


## Script-mod slot fill (see set_slot): frees the old weapon in the
## slot, then builds the mod through ForgeBuilder. The script's
## apply() grants the base weapon via a nested give_weapon -> set_slot
## call, which fills _weapons[slot] with the base weapon + attached
## mod hooks (the two find_mod calls below satisfy the registry's
## pending-attach pair rule — a direct ForgeBuilder call bypasses the
## ForgeManager gate that normally makes them). If apply() grants no
## weapon (mod misbehaved), the slot falls back to its base default —
## a script mod must never leave an empty slot. NOTE on disable: the
## built node is a BASE weapon with the mod's hooks attached (its
## weapon_id is the base id, not "mod:..."), so prune_stale_mod_weapons
## cannot see it — but the registry gates every hook on the mod's live
## record, so disabling the mod stops the hooks and the weapon degrades
## to its plain base form instead of vanishing.
func _set_script_mod_slot(slot: String, weapon_id: String) -> void:
	var old: WeaponBase = _weapons.get(slot)
	if old != null:
		old.ammo_changed.disconnect(_on_weapon_ammo)
		old.on_unequip()
		old.queue_free()
	_weapons[slot] = null
	var mod_id := Arsenal.mod_id_of(weapon_id)
	ModLoader.find_mod(mod_id)
	ModLoader.find_mod(mod_id)
	var player := _player as Node3D
	var root: Node = null
	if is_inside_tree():
		var tree := get_tree()
		if tree != null:
			root = tree.current_scene
	var msg := ForgeBuilder.build_weapon_mod(mod_id, player, root, slot)
	if _weapons.get(slot) == null:
		push_warning("WeaponManager: script mod '%s' granted no weapon (%s) — slot falls back." % [mod_id, msg])
		set_slot(slot, str(DEFAULT_LOADOUT.get(slot, "")))


## v0.5.9 MOD WEAPONS: drop equipped mod weapons whose mod is no longer
## valid (disabled / removed / broken) — each stale slot falls back to
## its base default (primary ar7, secondary p9, prototype raptor).
## Never touches base weapons. Stale mod ids in a saved loadout never
## reach here as live weapons: set_slot() already no-ops on them
## (Arsenal.has_weapon is live-validated), and the Loadouts store
## sanitizes them to the fallback on load — this covers the mid-match
## case, where the weapon already exists. Safe to call any time (also
## called every frame from _process); no-op while switching.
func prune_stale_mod_weapons() -> void:
	if _switching:
		return
	for slot in SLOT_ORDER:
		var w: WeaponBase = _weapons.get(slot)
		if w == null or not Arsenal.is_mod_weapon(w.weapon_id):
			continue
		if Arsenal.has_weapon(w.weapon_id):
			continue
		var fallback := str(DEFAULT_LOADOUT.get(slot, ""))
		if fallback != "" and fallback != w.weapon_id:
			set_slot(slot, fallback)


## v0.6 LOADOUTS: equip a primary + secondary pair immediately. The
## prototype (Raptor claw) slot is left untouched. Free — no budget cost.
func equip_loadout(primary_id: String, secondary_id: String) -> void:
	set_slot("primary", primary_id)
	set_slot("secondary", secondary_id)


## v0.6 LOADOUTS: equip one of the named LOADOUTS presets. No-op on an
## unknown name (returns false); returns true when applied.
func equip_loadout_named(loadout_name: String) -> bool:
	var preset: Dictionary = LOADOUTS.get(loadout_name, {})
	if preset.is_empty():
		return false
	equip_loadout(str(preset.get("primary", "")), str(preset.get("secondary", "")))
	return true


## Weapon id currently in a slot ("" when the slot is empty/unknown).
func get_slot_weapon_id(slot: String) -> String:
	var w: WeaponBase = _weapons.get(slot)
	if w == null:
		return ""
	return w.weapon_id


## The weapon node in a slot (null when the slot is empty). Used by
## ModAPI for non-primary give slots (pending-attach on the fresh
## weapon). Duck-typed callers must check has_method first.
func get_slot_weapon(slot: String) -> WeaponBase:
	return _weapons.get(slot)


## Pickups call this: +n reserve to every ballistic weapon.
func add_reserve_ammo(n: int) -> void:
	for w in _weapons.values():
		var weapon := w as WeaponBase
		if weapon != null and weapon.weapon_id != "raptor":
			weapon.add_reserve(n)


func current_weapon() -> WeaponBase:
	return _current


func current_slot() -> String:
	return _current_slot
