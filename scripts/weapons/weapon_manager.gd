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
	# Slot switching.
	if not _switching:
		if _slot_pressed(0):
			switch_to("primary")
		elif _slot_pressed(1):
			switch_to("secondary")
		elif _slot_pressed(2):
			switch_to("prototype")
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
func give_weapon(weapon_id: String) -> void:
	set_slot("primary", weapon_id)


## v0.6 LOADOUTS: replace the weapon in a GIVEN slot, reusing the same
## replacement logic give_weapon used for primary (disconnect, unequip,
## queue_free old, build new, equip if it is the current slot). No budget
## is touched here — loadouts are free gear, never Forge builds.
func set_slot(slot: String, weapon_id: String) -> void:
	if not slot in SLOT_ORDER or not Arsenal.has_weapon(weapon_id):
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
