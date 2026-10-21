# FORGEFALL — scripts/player/player.gd
# Purpose: first-person player controller — MW2-style tactical locomotion
#   (sprint, ADS, slide, coyote/jump-buffer, headbob, health regen) fused with
#   prototype gear (wall-run mag-boots, ascender grapple, wrist portal emitter).
# Connections:
#   - Autoloads: Game (register_player_death), Sfx (play_2d/play_3d)
#   - Children: $GrappleHook (grapple_hook.gd), $PortalEmitter (portal_emitter.gd)
#   - Group "player"; public add_look(relative) for touch worker + captured mouse
#   - Signals: health_changed / damaged / died / landed drive the HUD (ui worker)
#   - ads_changed / sprint_changed let the weapon worker react (sprint-out delay)
#   - Damageable: take_damage(amount, hit_position, is_headshot)
extends CharacterBody3D

const PlayerClasses := preload("res://scripts/progression/classes.gd")
const DnDTypes := preload("res://scripts/data/dnd_types.gd")

#region TUNABLES
const WALK_SPEED := 6.0
const SPRINT_SPEED := 11.0
const CROUCH_SPEED := 3.2
const ACCEL_GROUND := 60.0
const FRICTION_GROUND := 45.0
const AIR_CONTROL := 0.55
const GRAVITY := 20.0
const JUMP_VELOCITY := 5.8
const COYOTE_TIME := 0.12
const JUMP_BUFFER_TIME := 0.15
const SLIDE_FRICTION := 3.0
const SLIDE_MIN_SPEED := 5.0      # horizontal speed needed to start a slide
const SLIDE_END_SPEED := 2.0      # slide cancels below this
const SLIDE_MAX_TIME := 2.5
const SLIDE_HOP := 5.5            # jump-out-of-slide vertical boost
const WALLRUN_MAX_TIME := 3.0
# GAMEPLAY REWORK (2026-10-16, Colin's spec): attach ONLY at >= full
# walking speed AND aimed at the wall OR moving parallel to it.
# Was WALLRUN_ENTRY_BOOST 1.25 / WALLRUN_MIN_SPEED 4.0.
# BOOST READING: Colin said "a small speed boost (~50 units)". A literal
# +50 m/s would be ~4.5x sprint speed — not "small" — so this is read as
# +50% (x1.5). Flagged for Colin to confirm; the constant is the one knob.
const WALLRUN_ENTRY_BOOST := 1.5
const WALLRUN_MIN_SPEED := 6.0  # == WALK_SPEED: full walking speed
const WALLRUN_AIM_DOT := 0.5  # aimed-at-wall: aim . (-wall_normal) > 0.5
const WALLRUN_PARALLEL_DOT := 0.7  # moving parallel: |vel_dir . tangent| > 0.7
const WALLRUN_GRAVITY_SCALE := 0.12
const WALLRUN_ROLL_DEG := 12.0
const WALL_JUMP_AWAY := 8.0
const WALL_JUMP_UP := 6.5  # FULL wall-jump height (jump HELD)
# GAMEPLAY REWORK: variable wall-jump height, WALL-JUMP ONLY (ground jump
# untouched). Tap = small hop: releasing jump early cuts upward velocity to
# this value. Hold = full WALL_JUMP_UP trajectory. Cut applies only while
# rising faster than this (see _walljump_cut_armed in _update_jump).
const WALL_JUMP_TAP_UP := 4.0
const MAX_HP := 100.0
const REGEN_DELAY := 5.0
const REGEN_RATE := 25.0
# LOOK CONTRACT (fixed v0.1.5): add_look() takes RADIANS. Pixel-based inputs
# (desktop mouse, touch drag) convert with LOOK_SENS before calling; radian
# sources (recoil patterns, gyro) pass through directly. The player applies
# look_sensitivity x ADS mult once, here — nowhere else.
const LOOK_SENS := 0.0022  # radians of view per dragged pixel
const ADS_SENS_MULT := 0.6
# GAMEPAD LOOK (Steam Deck / Xbox-style pad): the right stick is POLLED every
# frame in _process, not event-driven — JoypadMotion events only fire when the
# axis value CHANGES, so a held stick would stop turning the camera. The
# dead zone is NOT a local constant: InputBindings.deadzone is the one
# tunable (Options > CONTROLS slider, persisted), shared with the InputMap
# action deadzones. The stick deflection (0..1 after deadzone rescale) is
# a turn RATE: GAMEPAD_LOOK_SPEED radians/sec at full deflection,
# converted to radians once (deflection * rate * delta) and fed to
# add_look(). LOOK_SENS is NOT applied here — it is pixels->radians only.
const GAMEPAD_LOOK_SPEED := 2.8  # rad/s at full deflection (~160 deg/s)
const PITCH_LIMIT_DEG := 89.0
const FOV_NORMAL := 75.0
const FOV_ADS := 52.0
const FOV_SPRINT := 90.0
const FOV_LERP_RATE := 12.0
const HEADBOB_AMP := 0.035
const HEADBOB_FREQ := 1.6
const STEP_DISTANCE := 2.2
const LAND_HARD_SPEED := 10.0
const HEAD_HEIGHT := 1.6
const HEAD_CROUCH := 1.05
# GAMEPLAY REWORK: slide camera was 1.25 — HIGHER than crouch, which is why
# the slide felt wrong (popping UP when going low). Slide is now the lowest
# stance: stand 1.6 / crouch 1.05 / slide 0.85. Camera-only: the collision
# capsule is NOT shrunk (same as crouch today), so a slide does not let the
# player pass under low gaps — shrinking the capsule is a deferred gameplay
# change (stuck-risk when the slide ends under a ceiling; needs a headroom
# check). Colin to verify feel on device.
const HEAD_SLIDE := 0.85
# --- JETPACK (Gameplay Rework 2026-10-16: NEW traversal tool) ---
# Fuel-based thrust, on jump-HOLD while airborne. Tunables live here and
# are mirrored in Tuning (PLAYER_JETPACK_*). Colin QAs the feel.
const JETPACK_THRUST_ACCEL := 45.0  # m/s^2 toward max rise speed
const JETPACK_MAX_RISE := 7.0  # upward velocity cap while thrusting
const JETPACK_FUEL_MAX := 100.0
const JETPACK_FUEL_DRAIN := 35.0  # fuel/sec while thrusting (~2.9 s tank)
const JETPACK_FUEL_REGEN := 25.0  # fuel/sec, grounded only (4 s to refill)
const JETPACK_MAX_BURN := 2.5  # sec of continuous thrust before the latch
# cuts thrust until jump is released (or the player lands). Binds before
# the tank empties, so burn time — not fuel — is the per-burst cap.
#endregion

#region SIGNALS
signal health_changed(hp: float, max_hp: float)
signal damaged(direction: Vector3)
signal died()
signal landed(hard: bool)
signal ads_changed(active: bool)
signal sprint_changed(active: bool)
signal class_changed(class_id: String)
#endregion

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var wall_ray_l: RayCast3D = $WallRayL
@onready var wall_ray_r: RayCast3D = $WallRayR
@onready var wall_ray_f: RayCast3D = $WallRayF
@onready var floor_ray: RayCast3D = $FloorRay
@onready var grapple: GrappleHook = $GrappleHook
@onready var portal_emitter: PortalEmitter = $PortalEmitter

var _pitch := 0.0
var invert_y := false
var preferred_fov := 90.0
var ads_sensitivity := ADS_SENS_MULT
var look_sensitivity := 1.0  # user setting; options menu wires this later
var _hp := MAX_HP
var _dead := false
var _ads := false
var _sprinting := false
var _crouching := false
var _sliding := false
var _slide_time := 0.0
var _wallrunning := false
var _wall_normal := Vector3.ZERO
var _wall_side := 0
var _wallrun_time := 0.0
var _can_wallrun := true
var _wallrun_blocked_normal := Vector3.ZERO
var _wallrun_detach_cooldown := 0.0
var _wall_contact_grace := 0.0
var _coyote := 0.0
var _jump_buf := 0.0
var _just_jumped := false  # jump fired this tick: horizontal uses the air branch (is_on_floor() is stale-true pre-move_and_slide)
var _regen_t := 99.0
var _bob_phase := 0.0
var _step_accum := 0.0
var _land_offset := 0.0
var _cam_roll := 0.0
var _prev_vy := 0.0
# --- TRAVERSAL TOOL (Gameplay Rework 2026-10-16): exactly ONE of
# "grapple" / "jetpack" / "portal" / "none" is active per run. The choice
# is part of the loadout (TDM) / pre-run setup (TD); see
# set_traversal_tool / set_allowed_traversal_tools. Default "grapple"
# preserves the pre-rework feel until a menu/loadout worker sets one.
# Zombies: the Zombies worker calls set_allowed_traversal_tools([]) (or
# its opt-in toggle list) — the allowed-set mechanism below is what makes
# traversal tools respect a per-run enabled-set; this file sets no
# mode-specific default of its own.
var _traversal_tool := "grapple"
var _allowed_traversal_tools: Array[String] = ["grapple", "jetpack", "portal"]
# --- JETPACK state ---
var _jetpack_fuel := JETPACK_FUEL_MAX
var _jetpack_burn := 0.0  # continuous thrust this burst (sec)
var _jetpack_latched := false  # max-burn reached: release jump to reset
var _jetpack_thrusting := false
# --- WALL-JUMP variable height: set on a wall-jump, cleared on landing /
# on any non-wall jump / when the cut fires. Ground jumps never arm it.
var _walljump_cut_armed := false
# --- CLASS KIT (v0.5.8): active D&D class id + derived kit state. ---
var active_class_id := "fighter"
## Base ability scores (all 10s — DnDTypes default). The EFFECTIVE block
## is base + active-class bonuses via PlayerClasses (see get_ability_scores).
var ability_scores := DnDTypes.default_ability_scores()
var _class_max_hp := MAX_HP
var _second_wind_used := false
var _was_on_floor := true


func apply_preferences(values: Dictionary) -> void:
	look_sensitivity = float(values.sensitivity)
	invert_y = bool(values.invert_y)
	preferred_fov = float(values.fov)
	ads_sensitivity = float(values.ads_sensitivity)


func _ready() -> void:
	apply_preferences(Preferences.values)
	add_to_group("player")
	_pitch = 0.0
	head.rotation.x = 0.0
	grapple.setup(self, camera, $Head/Camera3D/GrappleAnchor, floor_ray)
	portal_emitter.setup(self, camera, $Head/Camera3D/WristL, $Head/Camera3D/WristR)
	# v0.5.8 CLASSES: restore the saved class kit before the first HUD emit.
	var saved_class := PlayerClasses.load_saved_class()
	if PlayerClasses.is_valid_class(saved_class):
		active_class_id = saved_class
		_class_max_hp = MAX_HP * PlayerClasses.get_mod(saved_class, "max_hp_mult", 1.0)
		_hp = _class_max_hp
	health_changed.emit(_hp, get_max_hp())


# Public look entry: every caller passes RADIANS (see LOOK CONTRACT above).
# Yaw accumulates on the body, pitch on the head, clamped to ±89°.
func add_look(relative: Vector2) -> void:
	if _dead:
		return
	var s: float = look_sensitivity * (ads_sensitivity if _ads else 1.0)
	rotate_y(-relative.x * s)
	_pitch = clampf(_pitch - relative.y * s * (-1.0 if invert_y else 1.0),
			-deg_to_rad(PITCH_LIMIT_DEG), deg_to_rad(PITCH_LIMIT_DEG))
	head.rotation.x = _pitch


func _unhandled_input(event: InputEvent) -> void:
	# Desktop fallback: captured mouse drives the same add_look path the
	# touch worker uses. Mouse reports pixels -> convert to radians here.
	# Capture is the gate: MouseCapture is CAPTURED only during gameplay,
	# so no mouse-motion look ever runs while any menu is open.
	if event is InputEventMouseMotion and MouseCapture.is_captured():
		add_look((event as InputEventMouseMotion).relative * LOOK_SENS)


# Gamepad right-stick look: deadzone-rescale one raw axis (-1..1) to 0..1.
func _gamepad_axis(raw: float) -> float:
	if absf(raw) < InputBindings.deadzone:
		return 0.0
	return (absf(raw) - InputBindings.deadzone) / (1.0 - InputBindings.deadzone) * signf(raw)


# Gamepad look entry (testable without hardware): convert a right-stick
# deflection to RADIANS once and feed add_look(). Called by the per-frame
# poll below; the headless verifier calls this directly with synthetic
# deflections since get_joy_axis() reads real hardware, not event input.
func _apply_gamepad_look(rx: float, ry: float, delta: float) -> void:
	var lx := _gamepad_axis(rx)
	var ly := _gamepad_axis(ry)
	if lx != 0.0 or ly != 0.0:
		add_look(Vector2(lx, ly) * GAMEPAD_LOOK_SPEED * delta)


func _update_gamepad_look(delta: float) -> void:
	for dev in Input.get_connected_joypads():
		var rx := Input.get_joy_axis(dev, JOY_AXIS_RIGHT_X)
		var ry := Input.get_joy_axis(dev, JOY_AXIS_RIGHT_Y)
		if absf(rx) >= InputBindings.deadzone or absf(ry) >= InputBindings.deadzone:
			_apply_gamepad_look(rx, ry, delta)
			break


func is_alive() -> bool:
	return not _dead


func is_ads() -> bool:
	return _ads


func get_camera() -> Camera3D:
	return camera


# ------------------------------------------------------------------ CLASS KIT (v0.5.8)
# D&D 5e class (PlayerClasses): the active class's kit is a set of
# multipliers consulted at the exact choke points where the value is
# used (regen, speed, jump, wall-run, heal, take_damage). set_player_class
# swaps mid-match: the old kit is dropped (multipliers are read live
# from active_class_id, never cached) and the new kit applies on the
# next tick; HP keeps its FRACTION across the swap so changing class
# can neither heal nor hurt. Class ability bonuses (+2 STR etc.) are
# Worker A's stat-block domain — the effective block is base +
# class bonuses via DnDTypes.with_bonus (see get_ability_scores);
# this file never converts an ability score into HP/damage.
func get_active_class_id() -> String:
	return active_class_id


## Effective stat block: base + active-class bonuses (DnDTypes
## with_bonus primitive, via PlayerClasses). Read-only consumption —
## no formula lives here.
func get_ability_scores() -> Dictionary:
	return PlayerClasses.effective_ability_scores(ability_scores, active_class_id)


## 5e modifier for one ability ("str"|"dex"|...) in the EFFECTIVE block.
func get_ability_modifier(ability: String) -> int:
	return DnDTypes.get_ability_modifier(get_ability_scores(), ability)


## "STR 12 (+1)  DEX 10 (+0)  ..." — character-info line.
func get_stat_block_text() -> String:
	return DnDTypes.format_stat_block(get_ability_scores())


func get_max_hp() -> float:
	return _class_max_hp


func set_player_class(class_id: String) -> bool:
	if not PlayerClasses.is_valid_class(class_id):
		return false
	if class_id == active_class_id:
		return false
	var old_max := _class_max_hp
	var frac := clampf(_hp / maxf(old_max, 1.0), 0.0, 1.0)
	active_class_id = class_id
	_class_max_hp = MAX_HP * PlayerClasses.get_mod(class_id, "max_hp_mult", 1.0)
	_hp = clampf(frac * _class_max_hp, 0.0, _class_max_hp)
	_second_wind_used = false
	PlayerClasses.save_class(class_id)
	class_changed.emit(class_id)
	health_changed.emit(_hp, _class_max_hp)
	return true


func class_damage_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "damage_mult", 1.0)


func class_crit_chance() -> float:
	return PlayerClasses.get_mod(active_class_id, "crit_chance", 0.0)


func class_crit_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "crit_mult", 2.0)


func class_damage_taken_mult() -> float:
	# Rogue Sneak: the crouch damage-taken multiplier replaces the
	# base one while crouching or sliding.
	var crouch_mult := float(PlayerClasses.get_mod(active_class_id, "damage_taken_crouch_mult", 0.0))
	if crouch_mult > 0.0 and (_crouching or _sliding):
		return crouch_mult
	return PlayerClasses.get_mod(active_class_id, "damage_taken_mult", 1.0)


func class_speed_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "speed_mult", 1.0)


func class_crouch_speed_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "crouch_speed_mult", 1.0)


func class_jump_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "jump_mult", 1.0)


func class_wallrun_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "wallrun_mult", 1.0)


func class_regen_rate_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "regen_rate_mult", 1.0)


func class_regen_delay_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "regen_delay_mult", 1.0)


func class_heal_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "heal_mult", 1.0)


func class_forge_cooldown_mult() -> float:
	return PlayerClasses.get_mod(active_class_id, "forge_cooldown_mult", 1.0)


func _physics_process(delta: float) -> void:
	if _dead:
		velocity.y -= GRAVITY * delta
		move_and_slide()
		return

	# --- health regen ---
	_regen_t += delta
	if _regen_t >= REGEN_DELAY * class_regen_delay_mult() and _hp < get_max_hp():
		_hp = minf(_hp + REGEN_RATE * class_regen_rate_mult() * delta, get_max_hp())
		health_changed.emit(_hp, get_max_hp())

	_wallrun_detach_cooldown = maxf(_wallrun_detach_cooldown - delta, 0.0)
	# --- coyote time + jump buffering ---
	if is_on_floor():
		_coyote = COYOTE_TIME
		_can_wallrun = true
		_wallrun_blocked_normal = Vector3.ZERO
	else:
		_coyote = maxf(_coyote - delta, 0.0)
	if Input.is_action_just_pressed("jump"):
		_jump_buf = JUMP_BUFFER_TIME
	else:
		_jump_buf = maxf(_jump_buf - delta, 0.0)

	# --- wish direction (camera-relative, body yaw applied) ---
	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward"))
	if input_dir.length() > 1.0:
		input_dir = input_dir.normalized()
	var wish: Vector3 = (global_transform.basis * Vector3(input_dir.x, 0.0, input_dir.y))
	wish.y = 0.0
	if wish.length() > 1.0:
		wish = wish.normalized()

	_update_ads()
	_update_sprint(wish)
	_update_crouch_slide(delta, wish)
	_update_wallrun(delta, wish)
	_update_tool_switch()
	_update_grapple_input()
	_update_portal_input()
	_update_jump()
	_update_horizontal(delta, wish)
	_update_gravity(delta)
	_update_jetpack(delta)

	var pre_vy := velocity.y
	move_and_slide()
	grapple.clamp_floor()
	_update_landing(pre_vy)
	_update_footsteps(delta)
	_just_jumped = false


func _update_ads() -> void:
	var want_ads: bool = Input.is_action_pressed("ads") and not _dead
	if want_ads != _ads:
		_ads = want_ads
		ads_changed.emit(_ads)
		if _ads and _sprinting:
			_sprinting = false
			sprint_changed.emit(false)


func _update_sprint(wish: Vector3) -> void:
	# Sprint PERSISTS across jump + airtime (momentum fix): the old
	# is_on_floor() requirement dropped sprint the moment a jump left
	# the ground, so every landing braked to walk for a frame even with
	# sprint still held. Sprint now only ends on input/ADS/crouch/slide.
	var fwd := Input.get_action_strength("move_forward") > 0.3
	var want := Input.is_action_pressed("sprint") and fwd and not _ads \
		and not _crouching and not _sliding and wish.length() > 0.1
	if want != _sprinting:
		_sprinting = want
		sprint_changed.emit(_sprinting)
		# MW2 sprint-out: weapon worker applies its own 0.25s raise delay on this.


func _update_crouch_slide(delta: float, wish: Vector3) -> void:
	var hspeed := Vector2(velocity.x, velocity.z).length()
	# Slide: sprint + crouch tap at speed.
	if _crouch_tapped() and _sprinting \
			and hspeed >= SLIDE_MIN_SPEED and is_on_floor() and not _sliding:
		_sliding = true
		_slide_time = 0.0
		_crouching = false
		# Goal 2: slide whoosh — one-shot fired ONCE on slide entry (a
		# 0.7 s sample, never a loop, so nothing can stack or run forever).
		Sfx.play_3d("slide_whoosh", global_position, -3.0)
	if _sliding:
		_slide_time += delta
		if _slide_time > SLIDE_MAX_TIME or hspeed < SLIDE_END_SPEED or not is_on_floor():
			_sliding = false
		return
	_crouching = _crouch_held() and is_on_floor() \
		and not _sprinting and wish.length() < 0.9


func _update_wallrun(delta: float, wish: Vector3) -> void:
	# Wall-running is MOMENTUM-gated, not sprint-gated (v0.1.10): requiring
	# the "sprint" action meant holding the touch stick pinned at >=92%
	# deflection for the whole run — nearly impossible on a phone. Airborne +
	# fast + moving + a wall within reach is the real trigger, Titanfall-style.
	if _wallrunning:
		# Track the physical wall in world space rather than camera-relative
		# side rays, so looking around while running cannot detach the player.
		var from := global_position + Vector3.UP
		var query := PhysicsRayQueryParameters3D.create(from, from - _wall_normal * 1.25, 1, [get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		var contact := not hit.is_empty()
		if contact:
			var normal: Vector3 = hit["normal"]
			contact = absf(normal.y) < 0.35 and normal.dot(_wall_normal) > 0.5
			if contact:
				_wall_normal = normal
				_wall_contact_grace = 0.08
		else:
			_wall_contact_grace = maxf(0.0, _wall_contact_grace - delta)
		var keep := (contact or _wall_contact_grace > 0.0) and not is_on_floor() \
			and not grapple.is_active() and wish.length() > 0.1 \
			and _wallrun_time + delta < WALLRUN_MAX_TIME * class_wallrun_mult()
		if keep:
			_wallrun_time += delta
			# Stick to the wall, hold vertical speed near zero so the run
			# stays level (v0.6.0: was maxf(..., -2.0), which let a jump's
			# upward velocity carry the player up the whole run).
			velocity -= _wall_normal * 2.5 * delta
			velocity.y = clampf(velocity.y, -0.5, 0.5)
		else:
			_end_wallrun()
		return
	if is_on_floor() or grapple.is_active() or not _can_wallrun or _wallrun_detach_cooldown > 0.0:
		return
	if Vector2(velocity.x, velocity.z).length() < WALLRUN_MIN_SPEED:
		return
	if wish.length() < 0.1:
		return
	var ray: RayCast3D = null
	var side := 0
	if wall_ray_l.is_colliding():
		ray = wall_ray_l
		side = -1
	elif wall_ray_r.is_colliding():
		ray = wall_ray_r
		side = 1
	elif wall_ray_f.is_colliding():
		# Head-on approach: the side rays run parallel to a wall directly
		# ahead and never hit it — the forward ray is what catches it.
		ray = wall_ray_f
		side = 0
	if ray == null:
		return
	var n := ray.get_collision_normal()
	if absf(n.y) > 0.35 or n.dot(_wallrun_blocked_normal) > 0.95:
		return
	# GAMEPLAY REWORK attach gate (Colin's spec): speed >= full walk AND
	# (aimed at the wall OR moving parallel to it). No more attaching at
	# weird times — e.g. drifting away from a wall, or strafing past it
	# while looking away, no longer attaches.
	if not _wallrun_attach_allowed(n):
		return
	# Wall-run entry: redirect momentum along the wall with a bounded boost
	# (up to 1.25x sprint; faster incoming momentum is preserved, not multiplied).
	# The tangent is flipped to match travel direction, so a head-on
	# (forward-ray) entry runs along the wall the way the player was moving.
	_wallrunning = true
	_wall_side = side
	_wall_normal = n
	_wallrun_time = 0.0
	_wall_contact_grace = 0.08
	_wallrun_blocked_normal = Vector3.ZERO
	_walljump_cut_armed = false
	# Goal 2: wall-run scrape — a 2.8 s ONE-SHOT fired once on entry.
	# Deliberately not a loop (wall runs last <= 3 s, so the sample
	# covers the whole run and there is no stop path to leak).
	Sfx.play_3d("wallrun_scrape", global_position, -4.0)
	var tangent := n.cross(Vector3.UP).normalized()
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	if tangent.dot(hv) < 0.0:
		tangent = -tangent
	var nspeed := minf(hv.length() * WALLRUN_ENTRY_BOOST, maxf(hv.length(), SPRINT_SPEED * class_speed_mult() * 1.25))
	velocity.x = tangent.x * nspeed
	velocity.z = tangent.z * nspeed
	# Level entry (v0.6.0): a jump's upward velocity must NOT survive into
	# the run — was maxf(velocity.y, 1.0), which sent the player climbing.
	velocity.y = 0.0


## Wall-run attach gate (Gameplay Rework, Colin's spec): speed >= full
## walking speed (WALLRUN_MIN_SPEED, checked by the caller) AND the player
## is aimed at the wall OR moving parallel to it.
## - Aimed: camera aim (horizontal) points against the wall normal by more
##   than WALLRUN_AIM_DOT — i.e. within ~60 deg of straight at the wall.
## - Parallel: horizontal velocity direction runs along the wall tangent
##   (|vel_dir . tangent| > WALLRUN_PARALLEL_DOT, within ~45 deg).
## Uses VELOCITY (actual movement), not wish/input, for the parallel test.
func _wallrun_attach_allowed(n: Vector3) -> bool:
	if Vector2(velocity.x, velocity.z).length() < WALLRUN_MIN_SPEED:
		return false
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if horizontal.dot(n) > 1.0:
		return false
	var hv := horizontal.normalized()
	var tangent := n.cross(Vector3.UP).normalized()
	if absf(hv.dot(tangent)) > WALLRUN_PARALLEL_DOT:
		return true
	var aim := -camera.global_transform.basis.z
	aim.y = 0.0
	if aim.length() < 0.001:
		return false
	aim = aim.normalized()
	return aim.dot(-n) > WALLRUN_AIM_DOT


func _wall_ray_for_side() -> RayCast3D:
	# Prefer the side we entered on so the run doesn't flicker between rays.
	if _wall_side <= 0 and wall_ray_l.is_colliding():
		return wall_ray_l
	if _wall_side >= 0 and wall_ray_r.is_colliding():
		return wall_ray_r
	if wall_ray_l.is_colliding():
		return wall_ray_l
	if wall_ray_r.is_colliding():
		return wall_ray_r
	if wall_ray_f.is_colliding():
		return wall_ray_f
	return null


func _end_wallrun() -> void:
	if _wallrunning:
		_wallrun_blocked_normal = _wall_normal
		_wallrun_detach_cooldown = 0.2
	_wallrunning = false
	_wallrun_time = 0.0


## Crouch held / tapped through EITHER the crouch or the slide action.
## Slide defaults share crouch's binding, so a default setup behaves
## exactly as before; a rebound slide button still crouches (a slide
## is a crouch entered at speed — one input, not two buttons to hold).
func _crouch_held() -> bool:
	return (InputMap.has_action("crouch") and Input.is_action_pressed("crouch")) \
		or (InputMap.has_action("slide") and Input.is_action_pressed("slide"))


func _crouch_tapped() -> bool:
	return (InputMap.has_action("crouch") and Input.is_action_just_pressed("crouch")) \
		or (InputMap.has_action("slide") and Input.is_action_just_pressed("slide"))


## tool_switch (V / D-pad Left): cycle the ACTIVE traversal tool through
## the run's allowed set. Previously there was no in-game switch input —
## the tool could only change via the loadout menu. "none" cycles to the
## first allowed tool (Zombies with tools disabled has an empty allowed
## set and this is a no-op).
func _update_tool_switch() -> void:
	if InputMap.has_action("tool_switch") and Input.is_action_just_pressed("tool_switch"):
		_cycle_traversal_tool()


func _cycle_traversal_tool() -> void:
	var order: Array[String] = ["grapple", "jetpack", "portal"]
	var candidates: Array[String] = []
	for t in order:
		if _allowed_traversal_tools.has(t):
			candidates.append(t)
	if candidates.is_empty():
		return
	var idx := candidates.find(_traversal_tool)
	var next_tool: String = candidates[(idx + 1) % candidates.size()] if idx >= 0 else candidates[0]
	set_traversal_tool(next_tool)


func _update_grapple_input() -> void:
	# Traversal-tool gate: the grapple only fires when it is the chosen
	# tool. Grapple itself is untouched (Colin: "starting to feel right").
	if _traversal_tool != "grapple":
		return
	if Input.is_action_just_pressed("grapple"):
		if grapple.fire():
			_end_wallrun()
	elif Input.is_action_just_released("grapple"):
		grapple.release()


func _update_portal_input() -> void:
	# Traversal-tool gate: portals only fire when the portal gun is the
	# chosen tool.
	if _traversal_tool != "portal":
		return
	if Input.is_action_just_pressed("portal_blue"):
		portal_emitter.fire_blue()
	elif Input.is_action_just_pressed("portal_orange"):
		portal_emitter.fire_orange()


func _update_jump() -> void:
	# WALL-JUMP variable height (wall-jump ONLY): releasing jump while
	# still rising faster than the tap value cuts the rise to the tap
	# value — tap = small hop, hold = full jump. Ground jumps never arm
	# this (only the wall-jump branch below sets the flag), and landing
	# disarms it, so ground jump feel is byte-for-byte unchanged.
	if _walljump_cut_armed:
		if is_on_floor():
			_walljump_cut_armed = false
		elif Input.is_action_just_released("jump") and velocity.y > WALL_JUMP_TAP_UP:
			velocity.y = WALL_JUMP_TAP_UP
			_walljump_cut_armed = false
	if _jump_buf <= 0.0:
		return
	if _wallrunning:
		# Keep the along-wall component and add the outward/upward kick.
		var along_wall := velocity.slide(_wall_normal)
		along_wall.y = 0.0
		velocity = along_wall + _wall_normal * WALL_JUMP_AWAY + Vector3.UP * WALL_JUMP_UP
		_end_wallrun()
		_can_wallrun = true
		_jump_buf = 0.0
		_just_jumped = true
		_walljump_cut_armed = true
		return
	if grapple.is_active():
		grapple.release()  # release keeps momentum; jump below may still fire via coyote
	if _sliding:
		# Slide-hop: PRESERVE slide velocity (was *= 0.8 — a 20%
		# instant brake on every jump out of a slide).
		velocity.y = SLIDE_HOP
		_sliding = false
		_jump_buf = 0.0
		_just_jumped = true
		_walljump_cut_armed = false
	elif is_on_floor() or _coyote > 0.0:
		velocity.y = JUMP_VELOCITY * class_jump_mult()
		_coyote = 0.0
		_jump_buf = 0.0
		_sliding = false
		_just_jumped = true
		_walljump_cut_armed = false


func _update_horizontal(delta: float, wish: Vector3) -> void:
	if _sliding:
		# Titanfall glide (Goal 1): KEEP entry momentum, bleed speed at
		# SLIDE_FRICTION, steer gently toward wish. The old code steered
		# toward wish * 1.5 m/s, which braked an 11 m/s sprint slide to
		# a crawl in ~0.4 s — the slide never glided.
		var hv := Vector2(velocity.x, velocity.z)
		var speed := hv.length()
		var dir := hv / speed if speed > 0.001 else Vector2.ZERO
		if wish.length() > 0.1:
			dir = (dir + Vector2(wish.x, wish.z) * 2.0 * delta).normalized()
		speed = maxf(speed - SLIDE_FRICTION * delta, 0.0)
		velocity.x = dir.x * speed
		velocity.z = dir.y * speed
		return
	if _wallrunning:
		# Input is projected onto the wall; camera yaw cannot steer into it
		# or brake a fast entry back to sprint speed. Opposing input brakes
		# deliberately, while strafing away releases the wall.
		if wish.dot(_wall_normal) > 0.5:
			_end_wallrun()
			return
		var tangent := _wall_normal.cross(Vector3.UP).normalized()
		var along := Vector3(velocity.x, 0.0, velocity.z).dot(tangent)
		var intent := wish.dot(tangent)
		if along * intent < -0.1:
			along = move_toward(along, 0.0, ACCEL_GROUND * AIR_CONTROL * delta)
		elif absf(intent) > 0.1 and absf(along) < SPRINT_SPEED * class_speed_mult():
			along = move_toward(along, signf(intent) * SPRINT_SPEED * class_speed_mult(), 12.0 * delta)
		var horizontal := tangent * along - _wall_normal * 1.5
		velocity.x = horizontal.x
		velocity.z = horizontal.z
		return
	if grapple.is_active():
		velocity = grapple.apply_grapple(delta, velocity, wish)
		return
	var speed := WALK_SPEED
	if _sprinting:
		speed = SPRINT_SPEED
	elif _crouching:
		speed = CROUCH_SPEED * class_crouch_speed_mult()
	speed *= class_speed_mult()
	# v0.5.5: mod status effects (slow / freeze) on the player.
	speed *= ModStatusEffects.speed_multiplier(self)
	if not is_on_floor() or _just_jumped:
		# AIRBORNE (momentum fix): accelerate ALONG the wish direction,
		# never drag toward a lower speed. No input = no change, so a
		# jump at sprint keeps sprint speed to the apex and beyond.
		# Result is capped at max(current speed, wish speed): holding
		# sprint in air can build up to sprint, holding back brakes.
		if wish.length() > 0.1:
			var wish_speed := WALK_SPEED
			if _sprinting:
				wish_speed = SPRINT_SPEED
			elif _crouching:
				wish_speed = CROUCH_SPEED
			var hv := Vector2(velocity.x, velocity.z)
			var cur := hv.length()
			hv += Vector2(wish.x, wish.z) * (ACCEL_GROUND * AIR_CONTROL) * delta
			var cap := maxf(cur, wish_speed)
			if hv.length() > cap:
				hv = hv.normalized() * cap
			velocity.x = hv.x
			velocity.z = hv.y
		return
	var rate := ACCEL_GROUND
	if wish == Vector3.ZERO:
		rate = FRICTION_GROUND
	velocity.x = move_toward(velocity.x, wish.x * speed, rate * delta)
	velocity.z = move_toward(velocity.z, wish.z * speed, rate * delta)


func _update_gravity(delta: float) -> void:
	var gs := 1.0
	if _wallrunning:
		gs = WALLRUN_GRAVITY_SCALE
	if grapple.is_active():
		gs = grapple.get_gravity_scale()
	if not is_on_floor():
		velocity.y -= GRAVITY * gs * delta


# ------------------------------------------------------------------ JETPACK
# Fuel-based thrust on jump-HOLD while airborne. Runs AFTER gravity so
# thrust is the final word on vertical velocity each tick. Never fires
# while wall-running (the run owns vertical), grappled, grounded, or
# when another traversal tool is selected. Fuel refills grounded-only;
# the burn latch caps each continuous burst at JETPACK_MAX_BURN.
func _update_jetpack(delta: float) -> void:
	_jetpack_thrusting = false
	if _traversal_tool != "jetpack":
		return
	if is_on_floor():
		_jetpack_burn = 0.0
		_jetpack_latched = false
		if _jetpack_fuel < JETPACK_FUEL_MAX:
			_jetpack_fuel = minf(_jetpack_fuel + JETPACK_FUEL_REGEN * delta, JETPACK_FUEL_MAX)
		return
	if _wallrunning or grapple.is_active():
		return
	if _jetpack_latched:
		# Latch clears when jump is released (or on landing, above).
		if not Input.is_action_pressed("jump"):
			_jetpack_latched = false
		return
	if not Input.is_action_pressed("jump"):
		return
	if _jetpack_fuel <= 0.0:
		return
	_jetpack_thrusting = true
	velocity.y = move_toward(velocity.y, JETPACK_MAX_RISE, JETPACK_THRUST_ACCEL * delta)
	_jetpack_fuel = maxf(_jetpack_fuel - JETPACK_FUEL_DRAIN * delta, 0.0)
	_jetpack_burn += delta
	if _jetpack_burn >= JETPACK_MAX_BURN:
		_jetpack_latched = true


# ------------------------------------------------------------------ TRAVERSAL TOOL SELECTION
# Contract for the menu / loadout workers (TDM loadout, TD pre-run setup,
# Zombies opt-in toggle):
#   player.set_traversal_tool("jetpack")  -> true; only that tool is live.
#   player.set_traversal_tool("bogus")    -> false, selection unchanged.
#   player.get_traversal_tool()           -> "grapple" | "jetpack" | "portal" | "none"
#   player.set_allowed_traversal_tools(["portal"])  -> per-run enabled set;
#     a current selection outside the set falls back to "none".
#   Zombies: set_allowed_traversal_tools([]) = NO tools (default). The
#     opt-in toggle passes the toggled list instead.
#   Loadouts (canonical): the Loadouts store exposes
#     get_active_traversal() -> String; Main._wire_player applies it via
#     _apply_traversal_to_player() (allowed-set first, then selection).
# Switching away from the grapple releases it (no dangling rope).
const TRAVERSAL_TOOLS: Array[String] = ["grapple", "jetpack", "portal", "none"]


func get_traversal_tool() -> String:
	return _traversal_tool


func set_traversal_tool(tool: String) -> bool:
	if not TRAVERSAL_TOOLS.has(tool):
		return false
	if tool != "none" and not _allowed_traversal_tools.has(tool):
		return false
	if tool != _traversal_tool:
		if grapple != null and is_instance_valid(grapple):
			grapple.release()
		_traversal_tool = tool
		# A fresh tool starts with a clean jetpack state.
		_jetpack_burn = 0.0
		_jetpack_latched = false
	return true


func get_allowed_traversal_tools() -> Array[String]:
	return _allowed_traversal_tools.duplicate()


func is_traversal_tool_allowed(tool: String) -> bool:
	if tool == "none":
		return true
	return _allowed_traversal_tools.has(tool)


func set_allowed_traversal_tools(tools: Array) -> void:
	var cleaned: Array[String] = []
	for t: Variant in tools:
		var s := str(t)
		if s != "none" and TRAVERSAL_TOOLS.has(s) and not cleaned.has(s):
			cleaned.append(s)
	_allowed_traversal_tools = cleaned
	if _traversal_tool != "none" and not _allowed_traversal_tools.has(_traversal_tool):
		if grapple != null and is_instance_valid(grapple):
			grapple.release()
		_traversal_tool = "none"


## Jetpack fuel 0..1 (HUD worker reads this for the fuel bar).
func get_jetpack_fuel_frac() -> float:
	return clampf(_jetpack_fuel / JETPACK_FUEL_MAX, 0.0, 1.0)


## True while the jetpack is actively thrusting this tick.
func is_jetpack_thrusting() -> bool:
	return _jetpack_thrusting


func _update_landing(pre_vy: float) -> void:
	var on_floor := is_on_floor()
	if not _was_on_floor and on_floor:
		var fall := -pre_vy
		var hard := fall >= LAND_HARD_SPEED
		landed.emit(hard)
		_land_offset = -minf(fall * 0.02, 0.28)
		Sfx.play_2d("player_land_hard" if hard else "player_land")
		# Crouch-land (momentum fix): landing with crouch held at speed
		# enters a slide with the landing velocity preserved — the old
		# code only slid on a crouch TAP while grounded, so landing
		# while holding crouch braked to crouch speed. No whoosh call
		# here: audio is owned by the Sound worker; the slide-entry
		# whoosh stays on the grounded tap path only.
		var hspeed := Vector2(velocity.x, velocity.z).length()
		if _crouch_held() and hspeed >= SLIDE_MIN_SPEED \
				and not _sliding:
			_sliding = true
			_slide_time = 0.0
			_crouching = false
	_was_on_floor = on_floor
	_prev_vy = velocity.y


func _update_footsteps(delta: float) -> void:
	var hs := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and hs > 1.5 and not _sliding:
		_step_accum += hs * delta
		if _step_accum >= STEP_DISTANCE:
			_step_accum = 0.0
			# Goal 2: footsteps keep up with Goal 1 speed — cadence is
			# already distance-based (faster = more steps), and now the
			# pitch/volume also scale with speed so a sprint doesn't
			# sound like a stroll. Mix (-4 dB) + caller vol keep every
			# step well under the gunshot reference.
			# Per-surface note: still concrete — the map has no surface
			# tags (single StaticBody3D ground), so true per-surface
			# footsteps need map-side tags (coordinator follow-up).
			var k := clampf((hs - WALK_SPEED) / maxf(SPRINT_SPEED - WALK_SPEED, 0.001), 0.0, 1.0)
			var pitch := 1.0 + k * 0.18
			var vol := lerpf(-4.0, -2.0, k)
			Sfx.play_3d("footstep_concrete", global_position, vol, pitch)
	else:
		_step_accum = 0.0


#region HEALTH / DAMAGE
# Healing interface: AmmoPickup (health variant) calls this, then frees
# itself — so heal() must always apply (clamped), never silently no-op,
# or the pack would be consumed for nothing.
func heal(amount: float) -> void:
	if _dead:
		return
	_hp = minf(_hp + amount * class_heal_mult(), get_max_hp())
	health_changed.emit(_hp, get_max_hp())


# Damageable interface: take_damage(amount, hit_position, is_headshot,
# attacker). `attacker` is the Node that dealt the hit when the caller
# has a handle on it (EnemyBase.fire_hitscan passes self); null for
# attacker-less sources (explosions, grenades, slams) — thorns then
# reflects to the nearest live enemy (see ModStatusEffects).
# v0.5.9 take_damage INTERCEPTION (ONE hook point, no refactor):
#   1. take_damage hooks of the EQUIPPED weapon run first (they may
#      apply shield/vulnerable/thorns/petrified to the player, or
#      return damage_mult for THIS hit).
#   2. The class damage-taken multiplier applies.
#   3. ModStatusEffects.resolve_incoming_damage() applies the
#      player's active defensive states (petrified nullifies,
#      vulnerable multiplies, shield absorbs, thorns reflects).
#   4. Only the final damage lands. A fully absorbed / nullified hit
#      deals no damage: no HP loss, no hurt feedback, no regen reset.
#   5. Thorns reflection (if any) is delivered to the attacker as a
#      plain hit — it passes through the attacker's own defensive
#      states but never reflects again (reflection guard).
func take_damage(amount: float, hit_position: Vector3, is_headshot: bool, attacker: Node = null) -> void:
	if _dead:
		return
	var final_damage := amount
	var reflected := 0.0
	var reflected_target: Node = null
	if amount > 0.0:
		var incoming := amount
		var hooks := _take_damage_hooks()
		if not hooks.is_empty():
			var root: Node = null
			if is_inside_tree():
				var tree := get_tree()
				if tree != null:
					root = tree.current_scene
			var api := ModAPI.new(self, root)
			var ctx := {"damage": incoming, "target": self, "attacker": attacker,
				"hit_position": hit_position, "position": global_position,
				"headshot": is_headshot, "hp_before": _hp}
			var res := ModHookRegistry.run_take_damage(hooks, api, ctx)
			incoming *= float(res.get("damage_mult", 1.0))
		incoming *= class_damage_taken_mult()
		var resolved := ModStatusEffects.resolve_incoming_damage(self, incoming, attacker)
		final_damage = float(resolved.get("final_damage", incoming))
		reflected = float(resolved.get("reflected", 0.0))
		var rt: Variant = resolved.get("reflected_target", null)
		if rt is Node:
			reflected_target = rt as Node
	if final_damage <= 0.0:
		# Fully absorbed / nullified / non-positive: no damage lands.
		# Thorns cannot reflect damage that was never taken (resolve
		# returns reflected 0.0 for nullified hits), so nothing more
		# to do.
		return
	_hp = maxf(_hp - final_damage, 0.0)
	_regen_t = 0.0
	# v0.5.8 FIGHTER Second Wind: once per life, dropping to <=30% HP
	# (but not to 0) restores 30% of max HP instead of staying low.
	if _hp > 0.0 and _hp <= 0.30 * _class_max_hp and not _second_wind_used \
		and bool(PlayerClasses.get_mod(active_class_id, "second_wind", false)):
		_second_wind_used = true
		_hp = minf(_hp + 0.30 * _class_max_hp, _class_max_hp)
	health_changed.emit(_hp, get_max_hp())
	var dir := hit_position - global_position
	dir.y = 0.0
	damaged.emit(dir.normalized() if dir.length() > 0.01 else Vector3.ZERO)
	Input.vibrate_handheld(20)  # no-op on desktop; Android needs VIBRATE permission
	Sfx.play_2d("player_hurt")
	if reflected > 0.0 and reflected_target != null and is_instance_valid(reflected_target) \
			and reflected_target.has_method("take_damage"):
		ModStatusEffects.begin_reflection()
		# 3-arg call: the reflected hit is a plain hit — the
		# reflection guard (not an attacker param) stops ping-pong,
		# and 3 args stay compatible with every take_damage.
		reflected_target.call("take_damage", reflected, global_position, false)
		ModStatusEffects.end_reflection()
	if _hp <= 0.0:
		_die()


## take_damage hooks of the EQUIPPED weapon (the WeaponManager's
## current weapon's mod_hooks). [] when there is no WeaponManager /
## no current weapon / no hooks. The registry filters by hook point.
func _take_damage_hooks() -> Array:
	var wm := get_node_or_null("WeaponManager")
	if wm == null:
		return []
	var cur: Variant = wm.get("_current")
	if not (cur is Node):
		return []
	var hooks: Variant = (cur as Node).get("mod_hooks")
	if hooks is Array:
		return hooks as Array
	return []


func _die() -> void:
	_dead = true
	_sliding = false
	_end_wallrun()
	_walljump_cut_armed = false
	_jetpack_thrusting = false
	_jetpack_burn = 0.0
	_jetpack_latched = false
	if _ads:
		_ads = false
		ads_changed.emit(false)
	if _sprinting:
		_sprinting = false
		sprint_changed.emit(false)
	grapple.release()
	Game.register_player_death()
	# Goal 6 (Progression): deaths feed lifetime stats. Guarded — the
	# Stats autoload is registered by the coordinator; no-op until then.
	var stats: Node = get_node_or_null("/root/Stats")
	if stats != null and stats.has_method("record_event"):
		stats.call("record_event", "death")
	Sfx.play_2d("player_death")
	died.emit()


# Called by main (game_state / map) to put the operative back in the fight.
func respawn(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	_hp = get_max_hp()
	_second_wind_used = false
	_dead = false
	_regen_t = 99.0
	_pitch = 0.0
	rotation = Vector3.ZERO
	head.rotation = Vector3.ZERO
	head.position.y = HEAD_HEIGHT
	_sliding = false
	_crouching = false
	_ads = false
	_sprinting = false
	_end_wallrun()
	_can_wallrun = true
	_wallrun_blocked_normal = Vector3.ZERO
	_wallrun_detach_cooldown = 0.0
	_walljump_cut_armed = false
	_jetpack_fuel = JETPACK_FUEL_MAX
	_jetpack_burn = 0.0
	_jetpack_latched = false
	_jetpack_thrusting = false
	grapple.release()
	_land_offset = 0.0
	_cam_roll = 0.0
	health_changed.emit(_hp, get_max_hp())
#endregion


func _process(delta: float) -> void:
	if _dead:
		# Ragdoll-lite: camera slumps and tilts; main handles the respawn.
		head.position.y = lerpf(head.position.y, 0.6, 1.0 - exp(-4.0 * delta))
		head.rotation.z = lerpf(head.rotation.z, 0.55, 1.0 - exp(-4.0 * delta))
		return

	_update_gamepad_look(delta)

	# --- FOV: ADS zoom vs sprint kick ---
	var fov_t := preferred_fov
	if _ads:
		fov_t = preferred_fov * FOV_ADS / FOV_NORMAL
	elif _sprinting:
		fov_t = preferred_fov + FOV_SPRINT - FOV_NORMAL
	camera.fov = lerpf(camera.fov, fov_t, 1.0 - exp(-FOV_LERP_RATE * delta))

	# --- camera roll: wall-run lean / slide lean ---
	var roll_t := 0.0
	if _wallrunning:
		roll_t = deg_to_rad(WALLRUN_ROLL_DEG) * float(-_wall_side)
	elif _sliding:
		var lean := clampf(global_transform.basis.x.dot(velocity) / 4.0, -1.0, 1.0)
		roll_t = -lean * deg_to_rad(6.0)
	_cam_roll = lerpf(_cam_roll, roll_t, 1.0 - exp(-10.0 * delta))
	camera.rotation.z = _cam_roll

	# --- landing dip spring ---
	_land_offset = lerpf(_land_offset, 0.0, 1.0 - exp(-9.0 * delta))

	# --- headbob: subtle, grounded + moving, never while ADS ---
	var bob_y := 0.0
	var bob_x := 0.0
	var hs := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and hs > 0.5 and not _ads and not _sliding:
		_bob_phase += hs * HEADBOB_FREQ * delta
		var bscale := clampf(hs / SPRINT_SPEED, 0.0, 1.0)
		bob_y = sin(_bob_phase * 2.0) * HEADBOB_AMP * bscale
		bob_x = cos(_bob_phase) * HEADBOB_AMP * 0.6 * bscale
	camera.position = Vector3(bob_x, bob_y + _land_offset, 0.0)

	# --- head height: stand / crouch / slide ---
	var head_t := HEAD_HEIGHT
	if _sliding:
		head_t = HEAD_SLIDE
	elif _crouching:
		head_t = HEAD_CROUCH
	head.position.y = lerpf(head.position.y, head_t, 1.0 - exp(-12.0 * delta))
