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
const WALLRUN_ENTRY_BOOST := 1.25
const WALLRUN_MIN_SPEED := 4.0
const WALLRUN_GRAVITY_SCALE := 0.12
const WALLRUN_ROLL_DEG := 12.0
const WALL_JUMP_AWAY := 8.0
const WALL_JUMP_UP := 6.5
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
# axis value CHANGES, so a held stick would stop turning the camera. Polling
# also matches the InputMap deadzone (0.2). The stick deflection (0..1 after
# deadzone rescale) is a turn RATE: GAMEPAD_LOOK_SPEED radians/sec at full
# deflection, converted to radians once (deflection * rate * delta) and fed
# to add_look(). LOOK_SENS is NOT applied here — it is pixels->radians only.
const GAMEPAD_DEADZONE := 0.2
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
const HEAD_SLIDE := 1.25
#endregion

#region SIGNALS
signal health_changed(hp: float, max_hp: float)
signal damaged(direction: Vector3)
signal died()
signal landed(hard: bool)
signal ads_changed(active: bool)
signal sprint_changed(active: bool)
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
var _coyote := 0.0
var _jump_buf := 0.0
var _just_jumped := false  # jump fired this tick: horizontal uses the air branch (is_on_floor() is stale-true pre-move_and_slide)
var _regen_t := 99.0
var _bob_phase := 0.0
var _step_accum := 0.0
var _land_offset := 0.0
var _cam_roll := 0.0
var _prev_vy := 0.0
var _was_on_floor := true


func _ready() -> void:
	add_to_group("player")
	_pitch = 0.0
	head.rotation.x = 0.0
	grapple.setup(self, camera, $Head/Camera3D/GrappleAnchor, floor_ray)
	portal_emitter.setup(self, camera, $Head/Camera3D/WristL, $Head/Camera3D/WristR)
	health_changed.emit(_hp, MAX_HP)


# Public look entry: every caller passes RADIANS (see LOOK CONTRACT above).
# Yaw accumulates on the body, pitch on the head, clamped to ±89°.
func add_look(relative: Vector2) -> void:
	if _dead:
		return
	var s: float = look_sensitivity * (ADS_SENS_MULT if _ads else 1.0)
	rotate_y(-relative.x * s)
	_pitch = clampf(_pitch - relative.y * s,
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
	if absf(raw) < GAMEPAD_DEADZONE:
		return 0.0
	return (absf(raw) - GAMEPAD_DEADZONE) / (1.0 - GAMEPAD_DEADZONE) * signf(raw)


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
		if absf(rx) >= GAMEPAD_DEADZONE or absf(ry) >= GAMEPAD_DEADZONE:
			_apply_gamepad_look(rx, ry, delta)
			break


func is_alive() -> bool:
	return not _dead


func is_ads() -> bool:
	return _ads


func get_camera() -> Camera3D:
	return camera


func _physics_process(delta: float) -> void:
	if _dead:
		velocity.y -= GRAVITY * delta
		move_and_slide()
		return

	# --- health regen ---
	_regen_t += delta
	if _regen_t >= REGEN_DELAY and _hp < MAX_HP:
		_hp = minf(_hp + REGEN_RATE * delta, MAX_HP)
		health_changed.emit(_hp, MAX_HP)

	# --- coyote time + jump buffering ---
	if is_on_floor():
		_coyote = COYOTE_TIME
		_can_wallrun = true
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
	_update_grapple_input()
	_update_portal_input()
	_update_jump()
	_update_horizontal(delta, wish)
	_update_gravity(delta)

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
	if Input.is_action_just_pressed("crouch") and _sprinting \
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
	_crouching = Input.is_action_pressed("crouch") and is_on_floor() \
		and not _sprinting and wish.length() < 0.9


func _update_wallrun(delta: float, wish: Vector3) -> void:
	# Wall-running is MOMENTUM-gated, not sprint-gated (v0.1.10): requiring
	# the "sprint" action meant holding the touch stick pinned at >=92%
	# deflection for the whole run — nearly impossible on a phone. Airborne +
	# fast + moving + a wall within reach is the real trigger, Titanfall-style.
	if _wallrunning:
		var ray := _wall_ray_for_side()
		var keep := ray != null and not is_on_floor() \
			and _wallrun_time < WALLRUN_MAX_TIME and wish.length() > 0.1
		if keep:
			_wall_normal = ray.get_collision_normal()
			_wallrun_time += delta
			# Stick to the wall, hold vertical speed near zero so the run
			# stays level (v0.6.0: was maxf(..., -2.0), which let a jump's
			# upward velocity carry the player up the whole run).
			velocity -= _wall_normal * 2.5 * delta
			velocity.y = clampf(velocity.y, -0.5, 0.5)
		else:
			_end_wallrun()
		return
	if is_on_floor() or grapple.is_active() or not _can_wallrun:
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
	if absf(n.y) > 0.35:
		return
	# Wall-run entry: redirect momentum along the wall tangent + 10% boost.
	# The tangent is flipped to match travel direction, so a head-on
	# (forward-ray) entry runs along the wall the way the player was moving.
	_wallrunning = true
	_wall_side = side
	_wall_normal = n
	_wallrun_time = 0.0
	# Goal 2: wall-run scrape — a 2.8 s ONE-SHOT fired once on entry.
	# Deliberately not a loop (wall runs last <= 3 s, so the sample
	# covers the whole run and there is no stop path to leak).
	Sfx.play_3d("wallrun_scrape", global_position, -4.0)
	var tangent := n.cross(Vector3.UP).normalized()
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	if tangent.dot(hv) < 0.0:
		tangent = -tangent
	var nspeed := hv.length() * WALLRUN_ENTRY_BOOST
	velocity.x = tangent.x * nspeed
	velocity.z = tangent.z * nspeed
	# Level entry (v0.6.0): a jump's upward velocity must NOT survive into
	# the run — was maxf(velocity.y, 1.0), which sent the player climbing.
	velocity.y = 0.0


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
	_wallrunning = false
	_wallrun_time = 0.0


func _update_grapple_input() -> void:
	if Input.is_action_just_pressed("grapple"):
		if grapple.fire():
			_end_wallrun()
	elif Input.is_action_just_released("grapple"):
		grapple.release()


func _update_portal_input() -> void:
	if Input.is_action_just_pressed("portal_blue"):
		portal_emitter.fire_blue()
	elif Input.is_action_just_pressed("portal_orange"):
		portal_emitter.fire_orange()


func _update_jump() -> void:
	if _jump_buf <= 0.0:
		return
	if _wallrunning:
		# Wall kick: away from the wall + up, momentum preserved.
		velocity = _wall_normal * WALL_JUMP_AWAY + Vector3.UP * WALL_JUMP_UP
		_end_wallrun()
		_can_wallrun = false
		_jump_buf = 0.0
		_just_jumped = true
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
	elif is_on_floor() or _coyote > 0.0:
		velocity.y = JUMP_VELOCITY
		_coyote = 0.0
		_jump_buf = 0.0
		_sliding = false
		_just_jumped = true


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
		var rate := ACCEL_GROUND * AIR_CONTROL
		velocity.x = move_toward(velocity.x, wish.x * SPRINT_SPEED, rate * delta)
		velocity.z = move_toward(velocity.z, wish.z * SPRINT_SPEED, rate * delta)
		return
	if grapple.is_active():
		velocity = grapple.apply_grapple(delta, velocity, wish)
		return
	var speed := WALK_SPEED
	if _sprinting:
		speed = SPRINT_SPEED
	elif _crouching:
		speed = CROUCH_SPEED
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
		if Input.is_action_pressed("crouch") and hspeed >= SLIDE_MIN_SPEED \
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
	_hp = minf(_hp + amount, MAX_HP)
	health_changed.emit(_hp, MAX_HP)


# Damageable interface: take_damage(amount, hit_position, is_headshot).
func take_damage(amount: float, hit_position: Vector3, is_headshot: bool) -> void:
	if _dead:
		return
	_hp = maxf(_hp - amount, 0.0)
	_regen_t = 0.0
	health_changed.emit(_hp, MAX_HP)
	var dir := hit_position - global_position
	dir.y = 0.0
	damaged.emit(dir.normalized() if dir.length() > 0.01 else Vector3.ZERO)
	Input.vibrate_handheld(20)  # no-op on desktop; Android needs VIBRATE permission
	Sfx.play_2d("player_hurt")
	if _hp <= 0.0:
		_die()


func _die() -> void:
	_dead = true
	_sliding = false
	_end_wallrun()
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
	_hp = MAX_HP
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
	grapple.release()
	_land_offset = 0.0
	_cam_roll = 0.0
	health_changed.emit(_hp, MAX_HP)
#endregion


func _process(delta: float) -> void:
	if _dead:
		# Ragdoll-lite: camera slumps and tilts; main handles the respawn.
		head.position.y = lerpf(head.position.y, 0.6, 1.0 - exp(-4.0 * delta))
		head.rotation.z = lerpf(head.rotation.z, 0.55, 1.0 - exp(-4.0 * delta))
		return

	_update_gamepad_look(delta)

	# --- FOV: ADS zoom vs sprint kick ---
	var fov_t := FOV_NORMAL
	if _ads:
		fov_t = FOV_ADS
	elif _sprinting:
		fov_t = FOV_SPRINT
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
