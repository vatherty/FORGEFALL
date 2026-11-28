# FORGEFALL — WeaponBase
# MW2-style hitscan weapon core. Subclasses / data-driven instances provide
# stats (via Arsenal) and voxel viewmodels; this class owns the gunplay:
# fire modes (auto/semi/bolt/pump), RPM gating, hitscan with hip/ADS spread
# + movement penalty, linear damage falloff, headshots x2, per-weapon recoil
# patterns with recovery, staged reloads (mag_out -> mag_in -> chamber),
# muzzle flash (light + emissive quad, 40ms), pooled tracers, pooled shell
# eject, idle sway + walk bob (suppressed in ADS), raise/lower timing.
#
# Camera kick goes through player.add_look(relative). Contract (v0.1.5):
# add_look takes RADIANS — recoil_pattern values are already radians.
# +x = look right, +y = look down. Muzzle rise is therefore a NEGATIVE y.
# Recoil pattern entries are stored as Vector2(yaw_kick, pitch_up_kick) in
# "look-up is positive" space and converted at apply time.
class_name WeaponBase
extends Node3D

#region TUNABLES
const RECOIL_RECOVER_TIME := 0.20   # seconds to recover applied kick (fallback; per-weapon recoil_recover wins)
const RECOIL_SETTLE_DELAY := 0.045  # Goal 1: kick holds briefly before recovery starts, so it READS
const RECOIL_VM_KICK_Z := 0.55      # viewmodel backward kick per unit of pattern pitch
const RECOIL_VM_KICK_PITCH := 0.75  # viewmodel muzzle-rise rotation per unit of pattern pitch
# BB-4 Stage B: the kick RETURN is a spring, not the old exp(-11t) decay.
const VM_KICK_STIFFNESS := 400.0    # kick spring (omega 20 rad/s)
const VM_KICK_DAMPING_RATIO := 0.30 # under-damped: settles through a small forward overshoot
const VM_KICK_VEL_GAIN := 6.0       # shot impulse -> kick spring velocity per unit of kick offset (1/s)
const MUZZLE_FLASH_TIME := 0.04     # 40ms flash
const SHELL_POOL_SIZE := 10
const SHELL_LIFE := 1.4
const SHELL_GRAVITY := 9.8
const SWAY_AMOUNT := 0.010          # idle sway amplitude (radians-ish)
const SWAY_SPEED := 1.6
const BOB_AMOUNT := 0.022           # walk bob amplitude (meters)
const BOB_FREQ := 9.0
const ADS_SPREAD_MULT := 0.35
const ADS_RECOIL_MULT := 0.7
const ADS_SWAY_MULT := 0.25
const ADS_BOB_MULT := 0.20
# --- BB-4 Stage B: viewmodel spring core (see _tick_viewmodel). One writer
# drives the viewmodel through damped springs; sway/bob formulas and kick
# magnitudes are unchanged additives on top. Rest-state feel is identical
# to the pre-spring build by construction.
const VM_SPRING_STIFFNESS := 220.0     # position spring (omega ~14.8 rad/s)
const VM_SPRING_DAMPING_RATIO := 1.0   # position: critically damped (pose never overshoots)
const VM_ROT_SPRING_STIFFNESS := 170.0 # rotation spring (omega ~13 rad/s) — slightly softer
const VM_ROT_SPRING_DAMPING_RATIO := 0.9 # rotation: a breath of overshoot reads as mass
const VM_RAISE_DAMPING_RATIO := 0.85   # raise only: under-damped settle, a hint of overshoot
const VM_SPRING_MAX_DT := 1.0 / 30.0   # max substep h for every viewmodel spring (see _spring_substeps)
const VM_SPRING_MAX_FRAME := 1.0       # gate fix: spring integration time clamped to this per tick (s)
const VM_RAISE_START_OFFSET := Vector3(0.0, -0.22, 0.06) # raise starts here (pre-spring value)
const VM_LOWER_OFFSET := Vector3(0.0, -0.25, 0.0)        # lower target = HIP_POS + this
const ADS_BLEND_TIME := 0.11           # ADS spring: ~95% of travel closed in this (s)
const SPRINT_BLEND_TIME := 0.16        # sprint pose spring: ~95% of travel in this (s)
# Sprint pose (plan §2.4; ruling §7.3 default = POSE ONLY: firing is NOT
# blocked while sprinting, no sprint-out delay — these offsets are the
# whole effect. A future delay would gate _attempt_fire on _sprint_blend
# and add its timer beside set_sprinting(); the pose machinery is ready.)
const SPRINT_POSE_POS := Vector3(-0.04, -0.05, 0.02)  # carried-at-a-run shift
const SPRINT_POSE_ROT := Vector3(-0.55, 0.35, -0.25)  # pitch down, yaw across, roll in (rad)
# --- BB-4 Stage C: reload choreography (plan §2.3). A pose TRACK sampled
# off the existing staged-reload timers — keyframe poses at the stage
# boundaries, smoothstepped within each stage, composed onto the spring
# target in _tick_viewmodel. VISUAL ONLY: reload timing and the staged
# game logic in _tick_reload are untouched. The track is normalised per
# stage, so it stretches over every weapon's own reload_stages with zero
# per-weapon authoring; at full ADS it plays at RELOAD_ADS_AMPLITUDE so
# the choreography yields to the sight picture (verify_ads_alignment).
const RELOAD_POSE_MAG_OUT_POS := Vector3(0.0, -0.06, 0.0)   # MAG_OUT key: dip
const RELOAD_POSE_MAG_OUT_ROT := Vector3(0.10, 0.0, -0.60)  # MAG_OUT key: ~35° roll to the mag side
const RELOAD_POSE_MAG_IN_POS := Vector3(0.0, -0.10, 0.0)    # MAG_IN key: deeper dip, mag going home
const RELOAD_POSE_MAG_IN_ROT := Vector3(0.28, 0.0, -0.15)   # MAG_IN key: muzzle-down pitch, roll mostly back
const RELOAD_POSE_CHAMBER_POS := Vector3(0.0, 0.0, -0.03)   # CHAMBER pulse peak: bolt driven home (mid-stage)
const RELOAD_POSE_CHAMBER_ROT := Vector3(-0.06, 0.0, 0.0)   # CHAMBER pulse peak: slight muzzle-up settle
const RELOAD_ADS_AMPLITUDE := 0.4     # choreography scale at full ADS
const RELOAD_SEAT_JOLT_POS := 0.9     # mag-seat boundary impulse -> pos spring vel (+y, m/s)
const RELOAD_SEAT_JOLT_ROT := -1.0    # mag-seat boundary impulse -> rot spring vel (pitch, rad/s)
const RELOAD_RACK_JOLT_ROT := -2.2    # chamber-start rack snap -> rot spring vel (pitch, rad/s)
# --- BB-4 Stage C: viewmodel landing dip (plan §2.5). A spring channel
# of its own, impulse-fired by the landing tracker in _tick_land_dip and
# scaled by the weapon's weight (weight_effects land_dip_mult — the
# BB-4×BB-5 join). The camera's own _land_offset dip is untouched.
const LAND_DIP_PER_SPEED := 0.008       # dip depth per m/s of fall speed (m)
const LAND_DIP_MAX := 0.09              # dip depth ceiling (m) before weight scaling
const LAND_DIP_PITCH_PER_SPEED := 0.010 # muzzle-down pitch per m/s of fall (rad)
const LAND_DIP_PITCH_MAX := 0.12        # pitch ceiling (rad) before weight scaling
const LAND_DIP_MIN_FALL := 2.0          # falls slower than this (m/s) don't dip the gun
const LAND_DIP_STIFFNESS := 170.0       # dip spring (omega ~13 rad/s)
const LAND_DIP_DAMPING_RATIO := 0.55    # under-damped: one soft bounce reads as mass
const HIP_POS := Vector3(0.24, -0.20, -0.50)
const ADS_POS := Vector3(0.0, -0.148, -0.38)
const HIP_ROT := Vector3(0.0, -0.07, 0.0)
const ADS_ROT := Vector3.ZERO
const MAX_HITSCAN_RANGE := 400.0
const MOVE_SPREAD_REF_SPEED := 6.0  # speed (m/s) at which move penalty maxes
# BB-1c/BB-1d optic PiP lens (BB-1c ACOG — Colin: the full-screen 3x
# FOV zoom STAYS, and the lens glass gets "a zoom and parallax effect"
# on top; BB-1d — "Do it with all the sights not just the acog, the
# red dot sight needs similar treatment. Just without the zoom, just
# parallax"). A second camera renders the world into the optic's lens
# screen; its FOV is the main camera's CURRENT fov divided by the
# family's extra zoom:
#   ACOG   — LENS_EXTRA_ZOOM, pinned by Colin at exactly 1.5 ("The
#            zoom on the acog lens should only be 1.5x the fov zoom
#            3x"), i.e. 4.5x total vs the hip view at full ADS.
#   reflex — LENS_EXTRA_ZOOM_REFLEX, pinned at exactly 1.0: the lens
#            camera matches the main camera, NO extra zoom; the
#            shader shows the screen's own angular crop of that frame
#            so the picture registers 1:1 with the surrounding view
#            and the treatment is pure parallax.
const LENS_EXTRA_ZOOM := 1.5
const LENS_EXTRA_ZOOM_REFLEX := 1.0
const LENS_VIEWPORT_SIZE := 512     # square lens render target, ACOG (px)
const LENS_VIEWPORT_SIZE_REFLEX := 1024 # reflex: the window shows a small
                                        # centre crop of the frame, so the
                                        # frame needs the extra resolution
const LENS_LAYER := 20              # viewmodel-only render layer (bit 19)
const LENS_PARALLAX_GAIN := 2.2     # lens UV swim per radian of eye misalignment
const LENS_PARALLAX_MAX := 0.16     # UV clamp for the swim


## BB-1d: which optic classes carry the PiP lens (irons have no glass;
## the lr8 scope has its own HUD-overlay treatment — both untouched).
static func has_lens_pip(optic: String) -> bool:
	return optic in ["acog", "reflex"]


## BB-1d: the family's pinned lens extra zoom (see the constants).
static func lens_extra_zoom_for(optic: String) -> float:
	match optic:
		"acog":
			return LENS_EXTRA_ZOOM
		"reflex":
			return LENS_EXTRA_ZOOM_REFLEX
	return 1.0


## BB-1d: the family's lens render-target size (square, px).
static func lens_viewport_size_for(optic: String) -> int:
	return LENS_VIEWPORT_SIZE_REFLEX if optic == "reflex" else LENS_VIEWPORT_SIZE

# --- BB-5 (feel wave): gun weight. Colin's rule: "guns make you heavier —
# heavier gun = slower, easier to hit; bigger guns even more." The per-weapon
# mass is DATA (Arsenal.WEAPONS "weight"); everything derived from it flows
# through weight_norm + weight_effects() below so tuning stays in one place.
# Movement penalties (speed / strafe-accel) are NOT here: player.gd owns
# WEIGHT_SPEED_PENALTY / WEIGHT_ACCEL_PENALTY and derives its multipliers
# from the pushed weight_norm (plan §4). The factors below drive the
# viewmodel feel (Stages B/C) and the Stage D hitbox push.
const WEIGHT_MIN := 2.5        # normalisation floor: weight_norm 0 at/below this
const WEIGHT_MAX := 10.5       # normalisation ceiling: weight_norm 1 (the LMG)
const WEIGHT_DEFAULT := 5.0    # stats dicts with no "weight" (Forge/mod customs)
const WEIGHT_SPRING_SOFTEN := 0.45 # viewmodel spring stiffness lost at norm 1
const WEIGHT_SWAY_GROW := 0.6      # idle sway amplitude gained at norm 1
const WEIGHT_BOB_GROW := 0.5       # walk bob amplitude gained at norm 1
const WEIGHT_BOB_RATE_SLOW := 0.25 # walk bob phase rate lost at norm 1
const WEIGHT_DIP_BASE := 0.7       # landing-dip scale at norm 0
const WEIGHT_DIP_GROW := 0.8       # extra landing-dip scale at norm 1
## PENDING RULING (plan §7.2, Colin has not ruled yet): the Raptor is a
## traversal tool as much as a weapon. Recommended default = true: it takes
## the FULL weight effects at its mid weight, including the Stage D hitbox
## growth. Flip to false to exempt it from hitbox growth ONLY (movement and
## spring effects are unchanged either way). weight_effects() is the single
## place this flag is read.
const RAPTOR_FULL_WEIGHT_EFFECTS := true
#endregion

enum FireMode { AUTO, SEMI, BOLT, PUMP, BURST }
enum _ReloadStage { NONE, MAG_OUT, MAG_IN, CHAMBER }

## Maps a mod block's "fire_mode" string to a FireMode enum value.
## Unknown / empty strings fall back to AUTO (the validator rejects
## bad fire_mode strings at generation time; this is the runtime
## belt-and-braces for direct setters). Case-insensitive.
static func fire_mode_from_string(s: String) -> int:
	match s.to_lower().strip_edges():
		"semi":
			return FireMode.SEMI
		"bolt":
			return FireMode.BOLT
		"pump":
			return FireMode.PUMP
		"burst":
			return FireMode.BURST
		_:
			return FireMode.AUTO

signal ammo_changed(mag: int, reserve: int)
signal fired

# --- Stats (filled by setup() from Arsenal.WEAPONS) ---
var weapon_id: String = ""
var display_name: String = "WEAPON"
var fire_mode: int = FireMode.AUTO
var burst_size: int = 3       # Goal 3: rounds per burst (BURST mode only)
var rpm: float = 600.0
var damage: float = 20.0
var headshot_mult: float = 2.0
var mag_size: int = 30
var mag: int = 30
var reserve: int = 120
var pellets: int = 1
var spread_hip: float = 0.030      # radians, cone half-angle-ish
var spread_move: float = 0.030    # added at full move speed
var near_range: float = 20.0      # full damage inside this
var far_range: float = 60.0       # min damage beyond this
var falloff_min: float = 0.5      # damage multiplier at far_range
var recoil_pattern: Array = []   # Array[Vector2(yaw, pitch_up)] radians
var recoil_recover_time: float = RECOIL_RECOVER_TIME # Goal 1: per-weapon recovery (Arsenal "recoil_recover")
var muzzle_flash_time: float = MUZZLE_FLASH_TIME    # Goal 1: per-weapon flash duration
var muzzle_flash_energy: float = 4.0                 # Goal 1: per-weapon flash brightness
var raise_time: float = 0.35
var lower_time: float = 0.25
var weight: float = WEIGHT_DEFAULT # BB-5: Arsenal "weight" stat (kg-flavoured)
var weight_norm: float = 0.3125    # BB-5: derived in setup() — (weight - 2.5) / 8, clamped 0..1
var reload_stages: Array = [0.45, 0.85, 0.35] # mag_out, mag_in, chamber
var cycle_time: float = 0.0      # bolt/pump re-chamber lockout
var sfx_fire: String = "shot"

# --- Mod hooks (v0.5.3: invented hooks) ---
# Attached by ModHookRegistry when a mod weapon is granted (see
# ModHookRegistry.try_attach_pending / attach_mod_to_weapon). Empty for
# every stock weapon, which keeps the stock firing path byte-for-byte
# identical. When mod_projectile_spec is non-empty (after hook merging
# in resolve_projectile_spec), the weapon fires ModProjectiles instead
# of hitscan; mod_hooks run on_fire / on_hit / on_kill.
var mod_id: String = ""
var mod_projectile_spec: Dictionary = {}
var mod_hooks: Array = []

# --- Runtime state ---
var _player: Node = null
var _camera: Camera3D = null
var _viewmodel: Node3D = null
var _muzzle: Marker3D = null
var _eject: Marker3D = null
var _cooldown: float = 0.0
var _cycle_t: float = 0.0
var _cycle_sfx_done: bool = true
var _reload_stage: int = _ReloadStage.NONE
var _reload_t: float = 0.0
var _raise_t: float = 999.0
var _lowering: bool = false
var _ads_pos := ADS_POS # per-weapon ADS target; = -Arsenal.sight_anchor(id) (x+y), ADS_POS.z
var _optic := "iron"    # BB-1: Arsenal.optic_class(weapon_id) — zoom/scope/dot behaviour
var _ads_dot: MeshInstance3D = null # BB-1: projected dot for reflex/ACOG sights
# BB-1c/BB-1d: PiP lens rig (ACOG + reflex families; null otherwise).
var _lens_viewport: SubViewport = null
var _lens_camera: Camera3D = null
var _lens_screen: MeshInstance3D = null # the viewmodel's PipScreen quad
var _lens_mat: ShaderMaterial = null
var _lens_active := false           # viewport rendering + picture up
var _ads: bool = false
var _ads_blend: float = 0.0
var _shot_index: int = 0
var _burst_left: int = 0   # Goal 3: rounds remaining in the current burst
var _recoil_debt := Vector2.ZERO
var _recoil_settle_t := 0.0    # Goal 1: recovery holds while this runs
var _vm_kick_z := 0.0          # Goal 1: transient viewmodel backward kick (m)
var _vm_kick_pitch := 0.0      # Goal 1: transient viewmodel muzzle-rise (rad)
var _vm_kick_z_vel := 0.0      # BB-4 Stage B: kick spring velocity (m/s)
var _vm_kick_pitch_vel := 0.0  # BB-4 Stage B: kick spring velocity (rad/s)
var _kick_mag := 0.0           # Goal 1: mean pattern pitch — scales the VM kick
# BB-4 Stage B: spring-core state. _vm_pos/_vm_rot are the spring-driven
# viewmodel transform BEFORE the sway/bob/kick additives are applied;
# the single writer is _tick_viewmodel.
var _vm_pos := HIP_POS
var _vm_pos_vel := Vector3.ZERO
var _vm_rot := HIP_ROT
var _vm_rot_vel := Vector3.ZERO
var _ads_vel := 0.0            # ADS critically-damped spring velocity
var _sprinting := false        # sprint pose input (manager signal / player poll)
var _sprint_blend := 0.0
var _sprint_blend_vel := 0.0
# BB-4×BB-5 join (Stage C): weight_effects() multipliers, cached in
# setup() (weight_norm only ever changes there) so the per-frame ticks
# read plain floats — no Dictionary allocation in the hot loop.
var _w_spring_mult := 1.0
var _w_sway_mult := 1.0
var _w_bob_mult := 1.0
var _w_bob_rate_mult := 1.0
var _w_dip_mult := 1.0
# BB-4 Stage C: viewmodel landing-dip spring channel + landing tracker.
var _land_dip := 0.0           # dip depth (m, positive = gun pushed down)
var _land_dip_vel := 0.0
var _land_dip_pitch := 0.0     # dip pitch (rad, positive = muzzle down)
var _land_dip_pitch_vel := 0.0
var _air_vy := 0.0             # last airborne vertical velocity (banked fall speed)
var _was_grounded := true      # landing tracker: grounded state last tick
var _sway_t: float = 0.0
var _bob_t: float = 0.0
var _dry_fired: bool = false
var _flash_t: float = 0.0
var _flash_light: OmniLight3D = null
var _flash_quad: MeshInstance3D = null
var _shells: Array = [] # {node, vel, life}


func setup(stats: Dictionary) -> void:
	weapon_id = str(stats.get("weapon_id", "unknown"))
	display_name = str(stats.get("name", "WEAPON"))
	fire_mode = int(stats.get("fire_mode", FireMode.AUTO))
	burst_size = int(stats.get("burst_size", 3))
	rpm = float(stats.get("rpm", 600.0))
	damage = float(stats.get("damage", 20.0))
	headshot_mult = float(stats.get("headshot_mult", 2.0))
	mag_size = int(stats.get("mag_size", 30))
	mag = mag_size
	reserve = int(stats.get("reserve", 120))
	pellets = int(stats.get("pellets", 1))
	spread_hip = float(stats.get("spread_hip", 0.030))
	spread_move = float(stats.get("spread_move", 0.030))
	near_range = float(stats.get("near_range", 20.0))
	far_range = float(stats.get("far_range", 60.0))
	falloff_min = float(stats.get("falloff_min", 0.5))
	recoil_pattern = (stats.get("recoil_pattern", []) as Array).duplicate()
	recoil_recover_time = float(stats.get("recoil_recover", RECOIL_RECOVER_TIME))
	muzzle_flash_time = float(stats.get("muzzle_flash_time", MUZZLE_FLASH_TIME))
	muzzle_flash_energy = float(stats.get("muzzle_flash_energy", 4.0))
	# Mean pattern pitch drives the viewmodel kick so each gun's visual
	# punch matches its camera kick (sniper thumps, SMG buzzes).
	_kick_mag = 0.0
	for k in recoil_pattern:
		_kick_mag += float((k as Vector2).y)
	if not recoil_pattern.is_empty():
		_kick_mag /= float(recoil_pattern.size())
	raise_time = float(stats.get("raise_time", 0.35))
	lower_time = float(stats.get("lower_time", 0.25))
	# BB-5: weight -> weight_norm, the single input to every weight-driven
	# feel effect (see weight_effects()). Missing stat = WEIGHT_DEFAULT, so
	# hand-built Forge/mod stat dicts stay valid. Gate-fix rider: an
	# explicit `"weight": null` (or any non-numeric value) in a
	# hand-authored mod dict falls back the same way — float(null) used
	# to abort setup() here, leaving a viewmodel-less weapon.
	var raw_weight: Variant = stats.get("weight", WEIGHT_DEFAULT)
	weight = float(raw_weight) if (raw_weight is float or raw_weight is int) else WEIGHT_DEFAULT
	weight_norm = clampf((weight - WEIGHT_MIN) / (WEIGHT_MAX - WEIGHT_MIN), 0.0, 1.0)
	# BB-4×BB-5 join (Stage C): cache the effect multipliers the spring
	# core / sway / bob / landing dip read every tick.
	var wfx := weight_effects()
	_w_spring_mult = float(wfx["spring_stiffness_mult"])
	_w_sway_mult = float(wfx["sway_mult"])
	_w_bob_mult = float(wfx["bob_mult"])
	_w_bob_rate_mult = float(wfx["bob_rate_mult"])
	_w_dip_mult = float(wfx["land_dip_mult"])
	reload_stages = (stats.get("reload_stages", [0.45, 0.85, 0.35]) as Array).duplicate()
	cycle_time = float(stats.get("cycle_time", 0.0))
	sfx_fire = str(stats.get("sfx_fire", "shot"))
	# v0.5.3: forward-compat for mod-weapon Arsenal entries (custom
	# stats dicts may carry their mod attachment inline).
	if stats.has("mod_id"):
		mod_id = str(stats.get("mod_id", ""))
	if stats.has("mod_projectile_spec") and stats["mod_projectile_spec"] is Dictionary:
		mod_projectile_spec = (stats["mod_projectile_spec"] as Dictionary).duplicate(true)
	if stats.has("mod_hooks") and stats["mod_hooks"] is Array:
		mod_hooks = (stats["mod_hooks"] as Array).duplicate(true)
	# BB-1 ADS target: shift the viewmodel so this weapon's sight anchor
	# (Arsenal.sight_anchor — the actual aiming point of the model) lands
	# exactly on the camera's -Z axis, i.e. the sight sits centered on
	# screen. BOTH axes: the old math zeroed X, which left the LMG's
	# off-axis aperture +38 px right of centre. Shared ADS_POS z is kept.
	_optic = Arsenal.optic_class(weapon_id)
	_ads_pos = _ads_pos_for(weapon_id)
	_viewmodel = Arsenal.build_viewmodel(weapon_id)
	_build_ads_dot()
	add_child(_viewmodel)
	_muzzle = _viewmodel.get_node_or_null("Muzzle") as Marker3D
	_eject = _viewmodel.get_node_or_null("Eject") as Marker3D
	_build_flash()
	_build_shell_pool()
	_setup_lens_pip()


## BB-5: every weight-derived feel multiplier, computed from weight_norm in
## ONE place (plan §3.1). Movement penalties are deliberately absent: the
## player derives those from weight_norm with its own WEIGHT_*_PENALTY
## consts (plan §4). Consumers: the viewmodel spring/sway/bob/landing-dip
## scaling (Stage C join — setup() caches the multipliers into _w_* vars
## so the ticks read plain floats) and the Stage D hitbox push.
## "hitbox_norm" is the norm the player capsule grows by — the pending
## Raptor ruling (§7.2) is applied HERE and nowhere else, so flipping
## RAPTOR_FULL_WEIGHT_EFFECTS is the only change that ruling ever needs.
func weight_effects() -> Dictionary:
	var n := weight_norm
	return {
		"weight": weight,
		"weight_norm": n,
		"hitbox_norm": n if (weapon_id != "raptor" or RAPTOR_FULL_WEIGHT_EFFECTS) else 0.0,
		"spring_stiffness_mult": 1.0 - WEIGHT_SPRING_SOFTEN * n,
		"sway_mult": 1.0 + WEIGHT_SWAY_GROW * n,
		"bob_mult": 1.0 + WEIGHT_BOB_GROW * n,
		"bob_rate_mult": 1.0 - WEIGHT_BOB_RATE_SLOW * n,
		"land_dip_mult": WEIGHT_DIP_BASE + WEIGHT_DIP_GROW * n,
	}


## Apply a generated weapon's visual description after Forge grants its
## known gameplay base. The gunplay object, ammo, and hooks stay intact.
func set_visual_recipe(info: Dictionary) -> void:
	if info.is_empty() or _viewmodel == null:
		return
	var family := Arsenal.visual_family_for(info, weapon_id)
	var replacement := Arsenal.build_viewmodel(weapon_id, info)
	if replacement == null:
		return
	var old := _viewmodel
	var parent := old.get_parent()
	if parent == null:
		replacement.free()
		return
	var old_transform := old.transform
	var old_visible := old.visible
	for effect in [_flash_light, _flash_quad]:
		if effect != null and effect.get_parent() == old:
			old.remove_child(effect)
			replacement.add_child(effect)
	parent.remove_child(old)
	parent.add_child(replacement)
	replacement.transform = old_transform
	replacement.visible = old_visible
	old.free()
	_viewmodel = replacement
	_muzzle = replacement.get_node_or_null("Muzzle") as Marker3D
	_eject = replacement.get_node_or_null("Eject") as Marker3D
	_optic = Arsenal.optic_class(family)
	_ads_pos = _ads_pos_for(family)
	_build_ads_dot()
	# BB-1c/BB-1d: a recipe swap can change the optic family —
	# (re)build/bind the lens rig for the new viewmodel, or park it
	# (and drop the stale screen binding) if the lens went away.
	if has_lens_pip(_optic):
		_setup_lens_pip()
	else:
		_set_lens_active(false)
		_lens_screen = null
		_lens_mat = null


func attach(p_player: Node, p_camera: Camera3D) -> void:
	_player = p_player
	_camera = p_camera


## Attaches a mod's hooks + projectile spec to this weapon (called by
## ModHookRegistry; the Forge grant path attaches automatically). The
## weapon keeps the attachment until it is replaced.
func set_mod(p_mod_id: String, projectile_spec: Dictionary, hooks: Array) -> void:
	mod_id = p_mod_id
	mod_projectile_spec = projectile_spec.duplicate(true)
	mod_hooks = hooks.duplicate(true)


## A ModAPI bound to this weapon's player + scene root (for hook
## dispatch). Cheap RefCounted; safe with a null root (spawn calls
## no-op, heal/announce still work).
func _mod_api() -> ModAPI:
	var root: Node = null
	if is_inside_tree():
		var tree := get_tree()
		if tree != null:
			root = tree.current_scene
			if root == null:
				root = tree.root
	return ModAPI.new(_player as Node3D, root)


## Called by WeaponManager when this weapon becomes active.
func on_equip() -> void:
	_raise_t = 0.0
	_lowering = false
	_reload_stage = _ReloadStage.NONE
	if _viewmodel != null:
		if _viewmodel.get_parent() != null:
			_viewmodel.get_parent().remove_child(_viewmodel)
		if _camera != null:
			_camera.add_child(_viewmodel)
		else:
			add_child(_viewmodel)
		# BB-4 Stage B: the raise IS the position spring starting at the
		# lowered offset — reset the spring core so no velocity or pose
		# leaks in from the previously equipped weapon. (_sprint_blend
		# deliberately persists: swapping mid-sprint keeps the pose.)
		_vm_pos = HIP_POS + VM_RAISE_START_OFFSET
		_vm_pos_vel = Vector3.ZERO
		_vm_rot = HIP_ROT
		_vm_rot_vel = Vector3.ZERO
		_ads_vel = 0.0
		_vm_kick_z = 0.0
		_vm_kick_pitch = 0.0
		_vm_kick_z_vel = 0.0
		_vm_kick_pitch_vel = 0.0
		# BB-4 Stage C: no landing dip or stale fall speed leaks across
		# an equip either.
		_land_dip = 0.0
		_land_dip_vel = 0.0
		_land_dip_pitch = 0.0
		_land_dip_pitch_vel = 0.0
		_air_vy = 0.0
		_was_grounded = true
		_viewmodel.position = _vm_pos
		_viewmodel.rotation = _vm_rot
		# If we have no camera yet (first frames), stay hidden until the
		# manager re-equips us onto the real camera.
		_viewmodel.visible = _camera != null
	emit_ammo()


## Called by WeaponManager when switching away: park the viewmodel back on
## the weapon node and hide it so only the active gun renders.
func on_unequip() -> void:
	_set_lens_active(false) # BB-1c: never render the lens for a parked gun
	_lowering = false
	_burst_left = 0
	_reload_stage = _ReloadStage.NONE
	_ads = false
	_ads_blend = 0.0
	_ads_vel = 0.0
	if _viewmodel != null:
		if _viewmodel.get_parent() != null:
			_viewmodel.get_parent().remove_child(_viewmodel)
		add_child(_viewmodel)
		_viewmodel.position = Vector3.ZERO
		_viewmodel.visible = false


## Called by WeaponManager before switching away.
func begin_lower() -> void:
	_lowering = true
	_reload_stage = _ReloadStage.NONE


func is_ready() -> bool:
	return (_raise_t >= raise_time and not _lowering
		and _reload_stage == _ReloadStage.NONE and _cycle_t <= 0.0)


func set_ads(active: bool) -> void:
	_ads = active


## BB-4 Stage B: sprint pose input. WeaponManager forwards the player's
## sprint_changed signal here (the signal player.gd always emitted and
## nothing consumed); _tick_viewmodel ALSO polls the player's _sprinting
## flag duck-typed as a fallback, matching the manager's ADS pattern.
## Ruling §7.3 default (Colin has not vetoed): POSE ONLY — firing is not
## blocked while sprinting and there is no sprint-out delay.
func set_sprinting(active: bool) -> void:
	_sprinting = active


## BB-4 Stage B: current sprint pose blend (0 = hip pose, 1 = full
## sprint pose). Verify/debug hook, same spirit as get_ads_blend().
func get_sprint_blend() -> float:
	return _sprint_blend


## BB-1: 0 = hip, 1 = fully aimed. The HUD reads this to fade the
## sniper-scope overlay in only once the scope is truly up.
func get_ads_blend() -> float:
	return _ads_blend


## BB-1: optic class of the equipped configuration ("iron" / "reflex" /
## "acog" / "scope" / "none") — follows visual-recipe swaps.
func get_optic_class() -> String:
	return _optic


## BB-1: ADS viewmodel target for a weapon/family id: the negated sight
## anchor on x/y (so the anchor lands on the camera axis), shared z.
static func _ads_pos_for(id: String) -> Vector3:
	var anchor := Arsenal.sight_anchor(id)
	return Vector3(-anchor.x, -anchor.y, ADS_POS.z)


## BB-1: reflex/ACOG sights get a projected dot at the sight anchor.
## The shipped GLB optics render as opaque dark glass with NO dot in
## them (the procedural builders' glow dot was lost in the GLB pass),
## so aiming through them was guesswork. The dot is a tiny unshaded
## cube with no_depth_test — it reads as a dot projected on the lens,
## exactly at the aiming point, and only appears once the sight is
## mostly raised (blend > 0.5) so it never ghosts through the gun at
## hip. Iron/scope/none weapons get no dot (their picture is physical).
func _build_ads_dot() -> void:
	if _ads_dot != null and is_instance_valid(_ads_dot):
		_ads_dot.queue_free()
	_ads_dot = null
	if _viewmodel == null or not (_optic in ["reflex", "acog"]):
		return
	var sight := _viewmodel.get_node_or_null("Sight") as Marker3D
	if sight == null:
		return
	var dot := MeshInstance3D.new()
	dot.name = "AdsDot"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.0055, 0.0055, 0.002)
	dot.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.10, 0.08)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.10, 0.08)
	mat.emission_energy_multiplier = 2.0
	mat.no_depth_test = true
	mat.render_priority = 10
	dot.material_override = mat
	dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dot.position = sight.position
	dot.visible = false
	_viewmodel.add_child(dot)
	_ads_dot = dot


# --- BB-1c/BB-1d: optic picture-in-picture lens -------------------------
# One rig, shared by both glass families (the ACOG of BB-1c and the
# reflex/red-dot family of BB-1d): a SubViewport + Camera3D owned by
# the weapon. The camera copies the main camera's transform every
# frame and uses its CURRENT fov / the family's pinned extra zoom
# (ACOG 1.5, reflex 1.0 — no zoom), so the lens picture is exactly
# what the player sees and the sight axis stays the shot axis.
# Separation is by render layer: the PiP viewmodel subtree moves to
# LENS_LAYER, the main camera keeps its default all-layer mask
# (portal cameras copy it, unchanged), and the lens camera's mask
# excludes that layer — it renders the world, never the gun or the
# screen itself. The viewport renders ONLY while the lens is up
# (equipped + ADS blend > 0.5 + a screen bound); at hip the screen
# falls back to the shader's BB-1b glass look. The two families
# differ only in parameters: extra zoom, render-target size, and the
# shader's sample_rect (ACOG: the full frame; reflex: the screen's
# angular crop, fed per frame by _lens_sample_rect).

func _setup_lens_pip() -> void:
	if not has_lens_pip(_optic) or _viewmodel == null:
		return
	_apply_viewmodel_layer(_viewmodel)
	if _lens_viewport == null:
		_lens_viewport = SubViewport.new()
		_lens_viewport.name = "OpticLensViewport"
		_lens_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(_lens_viewport)
		_lens_camera = Camera3D.new()
		_lens_camera.name = "OpticLensCamera"
		# Every layer EXCEPT the viewmodel layer.
		_lens_camera.cull_mask = 0xFFFFF & ~(1 << (LENS_LAYER - 1))
		_lens_camera.near = 0.05
		_lens_camera.far = 500.0
		_lens_viewport.add_child(_lens_camera)
		_lens_camera.current = true
	# One shared viewport across families; its size is the family's
	# (the reflex crop needs the resolution, the ACOG doesn't).
	var want := lens_viewport_size_for(_optic)
	if _lens_viewport.size != Vector2i(want, want):
		_lens_viewport.size = Vector2i(want, want)
	_bind_lens_screen()


func _apply_viewmodel_layer(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).layers = 1 << (LENS_LAYER - 1)
	for child in node.get_children():
		_apply_viewmodel_layer(child)


func _bind_lens_screen() -> void:
	_lens_screen = null
	_lens_mat = null
	if _viewmodel == null or _lens_viewport == null:
		return
	var disc := _viewmodel.get_node_or_null(Arsenal.pip_screen_name(_optic)) as MeshInstance3D
	if disc == null:
		return
	_lens_screen = disc
	_lens_mat = disc.material_override as ShaderMaterial
	if _lens_mat != null:
		_lens_mat.set_shader_parameter("lens_tex", _lens_viewport.get_texture())


func _set_lens_active(active: bool) -> void:
	if _lens_viewport == null:
		_lens_active = false
		return
	if active == _lens_active:
		return
	_lens_active = active
	_lens_viewport.render_target_update_mode = \
		SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED


## BB-1c: sight-anchor position in camera space -> lens UV swim.
## The anchor's angular offset from the eye axis IS the eye
## misalignment: x right / y up in camera space become a UV offset
## with y flipped (texture v grows downward). Pure + static so the
## ADS verify can pin the conversion without a renderer.
static func lens_eye_offset_for(local_sight: Vector3) -> Vector2:
	if local_sight.z > -0.05:
		return Vector2.ZERO
	var ang := Vector2(local_sight.x, local_sight.y) / -local_sight.z
	return (Vector2(ang.x, -ang.y) * LENS_PARALLAX_GAIN).limit_length(LENS_PARALLAX_MAX)


## BB-1d: the reflex family's sample_rect — the screen's own angular
## footprint in the lens frame. The reflex lens camera runs at the
## main camera's fov (extra zoom 1.0, Colin's no-zoom pin), so the
## region of that frame the window should show is exactly the region
## the window itself subtends from the eye: projecting the screen's
## centre + size through the lens camera's own projection gives a
## picture that registers 1:1 with the world seen around the housing
## — no magnification, pure parallax (the eye_offset swim rides on
## top, as on the ACOG). Pure function of the screen's camera-space
## position/size and the lens fov; the ACOG never calls this (its
## sample_rect stays the full frame — its zoom IS the extra fov).
static func lens_sample_rect_for(local_centre: Vector3, size: Vector2, fov_deg: float) -> Vector4:
	var dist := maxf(-local_centre.z, 0.05)
	var tan_v := tan(deg_to_rad(fov_deg) * 0.5)
	# Square lens frame: horizontal fov == vertical fov.
	var span := 2.0 * dist * tan_v # frame width/height at the screen's depth
	return Vector4(
		0.5 + local_centre.x / span,
		0.5 - local_centre.y / span,
		clampf(size.x / span, 0.01, 1.0),
		clampf(size.y / span, 0.01, 1.0))


func _tick_lens_pip() -> void:
	if _lens_viewport == null:
		return
	var equipped := _camera != null and _viewmodel != null \
		and _viewmodel.get_parent() == _camera
	# A bound screen is what makes this viewmodel a lens at all (a
	# recipe swap can park the rig on a lens-less family).
	_set_lens_active(equipped and _ads_blend > 0.5 and _lens_screen != null)
	if _lens_mat != null:
		var strength := 0.0
		if equipped:
			strength = clampf((_ads_blend - 0.5) / 0.4, 0.0, 1.0)
		_lens_mat.set_shader_parameter("pip_strength", strength)
		var off := Vector2.ZERO
		if _camera != null and _viewmodel != null:
			var sight := _viewmodel.get_node_or_null("Sight") as Marker3D
			if sight != null:
				var local := _camera.global_transform.affine_inverse() \
					* sight.global_position
				off = lens_eye_offset_for(local)
		_lens_mat.set_shader_parameter("eye_offset", off)
		# BB-1d: the reflex picture is the screen's angular crop of
		# the (unzoomed) lens frame, recomputed per frame so it
		# tracks the ADS fov ramp; the ACOG's stays the full frame.
		if _optic == "reflex" and _lens_screen != null and _camera != null:
			var qm := (_lens_screen as MeshInstance3D).mesh as QuadMesh
			if qm != null:
				var centre := _camera.global_transform.affine_inverse() \
					* _lens_screen.global_position
				_lens_mat.set_shader_parameter("sample_rect",
					lens_sample_rect_for(centre, qm.size, _camera.fov))
	if _lens_active and _camera != null:
		_lens_camera.global_transform = _camera.global_transform
		# Colin's pins: the ACOG lens zoom is 1.5x the FOV zoom (the
		# lens camera's fov is the main camera's current fov / 1.5,
		# always); the reflex lens adds NO zoom (fov == main fov).
		_lens_camera.fov = _camera.fov / lens_extra_zoom_for(_optic)


## BB-1c/BB-1d: verify hooks (also just useful API).
func get_lens_viewport() -> SubViewport:
	return _lens_viewport


func is_lens_pip_active() -> bool:
	return _lens_active


func get_lens_screen() -> MeshInstance3D:
	return _lens_screen


func emit_ammo() -> void:
	ammo_changed.emit(mag, reserve)


func add_reserve(n: int) -> void:
	reserve += n
	emit_ammo()


# --- Input (driven by WeaponManager) ---

func trigger_pressed() -> void:
	_dry_fired = false
	if fire_mode == FireMode.BURST:
		# Goal 3: queue one burst; rounds fire in _process as the RPM
		# cooldown clears. Re-pressing mid-burst does NOT restart it.
		if _burst_left <= 0:
			_burst_left = maxi(burst_size, 1)
	elif fire_mode != FireMode.AUTO:
		_attempt_fire()


func trigger_held() -> void:
	if fire_mode == FireMode.AUTO:
		_attempt_fire()


func trigger_released() -> void:
	_dry_fired = false


func try_reload() -> void:
	if _reload_stage != _ReloadStage.NONE:
		return
	if mag >= mag_size or reserve <= 0:
		return
	_reload_stage = _ReloadStage.MAG_OUT
	_reload_t = float(reload_stages[0])
	# Goal 2: ONE per-weapon reload file played once at reload start
	# (clicks sit at this weapon's stage boundaries). Previously all three
	# stages played the same 1.9 s reload_ar file, stacking 3x.
	Sfx.play_2d(_reload_sfx(), 0.0, _reload_pitch())


# --- Goal 2 (SOUND) helpers: fire / reload / impact sound selection ---
# No gameplay numbers here — these only pick which WAV plays.

## Fire sound: the LMG has its own shot_lmg file (arsenal.gd maps it too).
## Kept explicit here so the LMG never falls back to the AR sound.
func _fire_sfx() -> String:
	if weapon_id == "lmg":
		return "shot_lmg"
	return sfx_fire


## Reload sound: dedicated staged files for sniper/shotgun/LMG; AR's file
## pitched up for the shorter SMG/pistol reloads; AR as-is. Raptor never
## reaches here (its try_reload is overridden: drop only).
func _reload_sfx() -> String:
	match weapon_id:
		"lr8":
			return "reload_sniper"
		"sg12":
			return "reload_shotgun"
		"lmg":
			return "reload_lmg"
		"br3":
			return "reload_burst"
		"hv44":
			return "reload_revolver"
	return "reload_ar"


## Reload pitch: SMG/pistol reuse reload_ar pitched to their shorter
## reloads (SMG ~1.45 s, pistol ~1.30 s vs AR 1.65 s).
func _reload_pitch() -> float:
	match weapon_id:
		"smg9":
			return 1.1
		"p9":
			return 1.25
	return 1.0


## Impact sound by what the bullet hit. Group-based heuristic: enemies
## (flesh) > turret (metal) > cover (concrete) > name hints (dirt/metal)
## > default concrete (most of Dustline is concrete/rubble).
func _impact_sfx(collider: Object) -> String:
	var n := collider as Node
	if n != null:
		if n.is_in_group("enemy") or n.is_in_group("enemies") or n.is_in_group("enemy_head"):
			return "impact_flesh"
		if n.is_in_group("turret"):
			return "impact_metal"
		if n.is_in_group("cover"):
			return "impact_concrete"
		var lname := n.name.to_lower()
		if "dirt" in lname or "ground" in lname or "terrain" in lname or "sand" in lname:
			return "impact_dirt"
		if "metal" in lname or "barrel" in lname or "turret" in lname:
			return "impact_metal"
	return "impact_concrete"


# --- Core ---

## Goal 6 (Progression): report a stats event to the Stats autoload.
## No-op when the autoload isn't registered yet (coordinator wires it).
func _record_stat(type: String, data: Dictionary = {}) -> void:
	var stats: Node = get_node_or_null("/root/Stats")
	if stats != null and stats.has_method("record_event"):
		stats.call("record_event", type, data)


func _attempt_fire() -> void:
	if _lowering or _raise_t < raise_time:
		return
	if _reload_stage != _ReloadStage.NONE or _cycle_t > 0.0 or _cooldown > 0.0:
		return
	if mag <= 0:
		if not _dry_fired:
			_dry_fired = true
			Sfx.play_2d("dryfire")
		try_reload() # auto-reload prompt behavior
		return
	mag -= 1
	# Goal 6 (Progression): one shot per round fired (not per pellet).
	_record_stat("shot", {"weapon_id": weapon_id})
	_cooldown = 60.0 / maxf(rpm, 1.0)
	# v0.5.3 INVENTED HOOKS: a mod weapon fires its mod's projectile
	# (ModProjectile, real firing path) instead of hitscan, and its
	# on_fire / projectile_spawn hooks run on every shot. Stock weapons
	# (no hooks, no projectile spec) take the old hitscan path exactly.
	var proj_spec := ModHookRegistry.resolve_projectile_spec(self)
	if not proj_spec.is_empty() or not mod_hooks.is_empty():
		var fire_api := _mod_api()
		var fire_pos: Vector3 = _muzzle.global_position if _muzzle != null else (_camera.global_position if _camera != null else Vector3.ZERO)
		var fire_ctx := {"weapon_id": weapon_id, "position": fire_pos,
			"direction": -_camera.global_transform.basis.z if _camera != null else Vector3.FORWARD}
		ModHookRegistry.run_point_for_weapon(self, "on_fire", fire_api, fire_ctx)
		ModHookRegistry.run_point_for_weapon(self, "projectile_spawn", fire_api, fire_ctx)
	if not proj_spec.is_empty():
		_fire_projectile(proj_spec)
	else:
		_fire_hitscan()
	_apply_recoil()
	_show_muzzle_flash()
	_eject_shell()
	Sfx.play_2d(_fire_sfx())
	fired.emit()
	emit_ammo()
	if cycle_time > 0.0:
		_cycle_t = cycle_time
		_cycle_sfx_done = false
	if mag <= 0:
		try_reload()


func _current_spread() -> float:
	var s := spread_hip
	if _ads:
		s *= ADS_SPREAD_MULT
	var speed := _player_speed()
	if speed > 0.5:
		s += spread_move * clampf(speed / MOVE_SPREAD_REF_SPEED, 0.0, 1.0)
	return s


func _player_velocity() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return Vector3.ZERO
	var v: Variant = _player.get("velocity")
	if v is Vector3:
		return v as Vector3
	return Vector3.ZERO


func _player_speed() -> float:
	return _player_velocity().length()


func _spread_dir(spread: float) -> Vector3:
	var basis_t: Basis = _camera.global_transform.basis
	var dir := -basis_t.z
	var a := randf() * TAU
	var r := spread * sqrt(randf())
	dir = (dir + basis_t.x * cos(a) * r + basis_t.y * sin(a) * r).normalized()
	return dir


## v0.5.3: fires the mod's custom projectile(s) — one per pellet, each
## with its own spread dir. The projectile carries the weapon's damage
## when the spec leaves damage at -1 (default), plus the weapon's
## attached hooks (on_hit / on_kill run on impact in ModProjectile).
func _fire_projectile(spec: Dictionary) -> void:
	if _camera == null:
		return
	var tree := get_tree()
	if tree == null:
		return
	var root: Node = tree.current_scene
	if root == null:
		root = tree.root
	var muzzle_pos: Vector3 = _muzzle.global_position if _muzzle != null else _camera.global_position + (-_camera.global_transform.basis.z) * 0.6
	var spread := _current_spread()
	for i in maxi(pellets, 1):
		var dir := _spread_dir(spread)
		var pspec := spec.duplicate(true)
		var dmg: Variant = pspec.get("damage", -1.0)
		if not (dmg is int or dmg is float) or float(dmg) < 0.0:
			pspec["damage"] = damage
		var p := ModProjectile.new()
		p.setup(pspec, mod_hooks, _player)
		root.add_child(p)
		p.launch(muzzle_pos, dir)


func _fire_hitscan() -> void:
	if _camera == null:
		return
	var space := _camera.get_world_3d().direct_space_state
	var from: Vector3 = _camera.global_position
	var spread := _current_spread()
	var exclude: Array[RID] = []
	if _player is CollisionObject3D:
		exclude.append((_player as CollisionObject3D).get_rid())
	var muzzle_pos: Vector3 = _muzzle.global_position if _muzzle != null else from + _spread_dir(0.0) * 0.6
	# Goal 6: one hit per round that damaged at least one enemy (not per
	# pellet) so accuracy = rounds that hit / rounds fired.
	var hit_enemy_this_round := false
	# v0.5.3: on_kill hooks run once per killed target per shot, even
	# with multi-pellet weapons (later pellets see an already-dead body).
	var killed_ids := {}
	for i in maxi(pellets, 1):
		var dir := _spread_dir(spread)
		var query := PhysicsRayQueryParameters3D.create(from, from + dir * MAX_HITSCAN_RANGE, 0xFFFFFFFF, exclude)
		var hit := space.intersect_ray(query)
		var hit_pos: Vector3 = hit.get("position", from + dir * MAX_HITSCAN_RANGE)
		TracerPool.spawn(muzzle_pos, hit_pos)
		# FX-only hook (no fire-logic change): dust puff where the bullet
		# lands. Misses (empty hit) get no puff.
		var collider: Object = hit.get("collider")
		var hit_enemy: bool = collider != null and collider.has_method("take_damage")
		if not hit.is_empty():
			ImpactFX.spawn(hit_pos, hit.get("normal", Vector3.UP))
			# Goal 2: bullet-impact sound by surface, under the gunfire
			# (mix table: impacts at -6 dB, voice-capped at 4).
			Sfx.play_3d(_impact_sfx(collider), hit_pos, -6.0)
			# Goal 1: heavy rounds (sniper) kick up a bigger impact cloud
			# on world surfaces. Enemy hits already get flash + flinch.
			if not hit_enemy and damage >= 60.0:
				ImpactFX.spawn_smoke(hit_pos, 0.7)
		if not hit.is_empty():
			# v0.5.3 INVENTED HOOKS (mod weapons only): on_hit hooks
			# run on EVERY hit (wall hits included — an on-hit
			# explosion still goes off), and a damage_mult effect
			# multiplies this hit's damage before it lands. on_kill
			# hooks run once per killed target.
			var dist := from.distance_to(hit_pos)
			var dmg := _falloff_damage(dist)
			var head := _is_headshot(collider)
			if head:
				dmg *= headshot_mult
			# v0.5.8 CLASSES: the shooter's class kit (damage + crit) —
			# one hook. Duck-typed: stock player exposes class_*(); a
			# missing method means no class kit (damage unchanged).
			if _player != null and _player.has_method("class_damage_mult"):
				dmg *= float(_player.call("class_damage_mult"))
				var crit_chance := 0.0
				if _player.has_method("class_crit_chance"):
					crit_chance = float(_player.call("class_crit_chance"))
				if crit_chance > 0.0 and randf() < crit_chance:
					var crit_mult := 2.0
					if _player.has_method("class_crit_mult"):
						crit_mult = float(_player.call("class_crit_mult"))
					dmg *= crit_mult
			if not mod_hooks.is_empty():
				var hit_api := _mod_api()
				var hit_ctx := {"position": hit_pos, "hit_position": hit_pos,
					"damage": dmg, "target": collider, "headshot": head,
					"weapon_id": weapon_id}
				var hres := ModHookRegistry.run_hooks(mod_hooks, "on_hit", hit_api, hit_ctx)
				dmg *= float(hres.get("damage_mult", 1.0))
			if collider != null and collider.has_method("take_damage"):
				# v0.5.8 elemental emitters: a weapon built with an
				# "element" meta (Forge weapon + element composition)
				# deals its FULL hit damage AS that element — typed
				# damage + rider, or force/water handling — instead of
				# plain damage, plus an element-colored voxel burst
				# at the impact point.
				var element := str(get_meta("elemental_ammo", "")) if has_meta("elemental_ammo") else ""
				if ElementalEmitter.is_element(element):
					ElementalEmitter.apply_to_target(collider, element, dmg, hit_pos)
					var scene := get_tree().current_scene if get_tree() != null else null
					if scene != null:
						ElementalEmitter.spawn_visual_burst(scene, element, hit_pos, 1.2)
				else:
					collider.take_damage(dmg, hit_pos, head)
				hit_enemy_this_round = true
				_notify_hit(collider, head)
				if ModHookRegistry.target_is_dead(collider) and not mod_hooks.is_empty():
					var iid := collider.get_instance_id()
					if not killed_ids.has(iid):
						killed_ids[iid] = true
						var kill_api := _mod_api()
						var kill_ctx := {"position": hit_pos, "hit_position": hit_pos,
							"damage": dmg, "target": collider, "headshot": head,
							"weapon_id": weapon_id}
						ModHookRegistry.run_hooks(mod_hooks, "on_kill", kill_api, kill_ctx)


	if hit_enemy_this_round:
		_record_stat("hit", {"weapon_id": weapon_id})


func _falloff_damage(dist: float) -> float:
	if dist <= near_range:
		return damage
	if dist >= far_range:
		return damage * falloff_min
	var t := (dist - near_range) / maxf(far_range - near_range, 0.001)
	return damage * lerpf(1.0, falloff_min, t)


func _is_headshot(collider: Object) -> bool:
	var n := collider as Node
	if n == null:
		return false
	if n.is_in_group("enemy_head"):
		return true
	var p := n.get_parent()
	return p != null and p.is_in_group("enemy_head")


func _notify_hit(collider: Object, headshot: bool) -> void:
	var killed := false
	if collider.has_method("is_dead"):
		killed = bool(collider.call("is_dead"))
	var hud := get_tree().get_first_node_in_group("hud")
	var hud_shown := false
	if hud != null and hud.has_method("show_hitmarker"):
		hud.show_hitmarker(killed, headshot)
		hud_shown = true
	# Goal 1: the HUD owns the hit sound (it plays exactly one tick per
	# show_hitmarker, deduped for same-frame doubles). The weapon only
	# plays a fallback when no HUD exists — previously BOTH played, so
	# every hit sounded twice and shotgun pellets stacked 8 ticks.
	if not hud_shown:
		if headshot:
			Sfx.play_2d("headshot_ding")
		else:
			Sfx.play_2d("hitmarker")


func _apply_recoil() -> void:
	if _player == null or not is_instance_valid(_player) or not _player.has_method("add_look"):
		return
	if recoil_pattern.is_empty():
		return
	var kick: Vector2 = recoil_pattern[_shot_index % recoil_pattern.size()]
	_shot_index += 1
	var mult := ADS_RECOIL_MULT if _ads else 1.0
	kick *= mult
	# add_look convention: +x right, +y down -> muzzle rise is -y.
	var look := Vector2(kick.x, -kick.y)
	_player.add_look(look)
	_recoil_debt += look
	# Goal 1: the kick HOLDS for a beat before recovery starts (settle
	# delay), and the viewmodel punches back + up in sync with the camera.
	_recoil_settle_t = RECOIL_SETTLE_DELAY
	_vm_kick_z += _kick_mag * RECOIL_VM_KICK_Z * mult
	_vm_kick_pitch += _kick_mag * RECOIL_VM_KICK_PITCH * mult
	# BB-4 Stage B: the punch itself stays instant (the camera kick it
	# syncs with is instant too), but the impulse ALSO feeds the kick
	# spring's velocity — the gun carries back a touch further, then
	# the under-damped spring hauls it home through a small overshoot
	# instead of the old exponential slide (see _tick_vm_kick).
	_vm_kick_z_vel += _kick_mag * RECOIL_VM_KICK_Z * mult * VM_KICK_VEL_GAIN
	_vm_kick_pitch_vel += _kick_mag * RECOIL_VM_KICK_PITCH * mult * VM_KICK_VEL_GAIN


func _recover_recoil(delta: float) -> void:
	if _recoil_debt.length_squared() < 0.0000001:
		return
	if _player == null or not is_instance_valid(_player) or not _player.has_method("add_look"):
		_recoil_debt = Vector2.ZERO
		return
	# Goal 1: settle delay first (kick reads), then exponential recovery
	# with a per-weapon time constant — fast guns snap back, the sniper
	# and shotgun settle slowly. ~95% recovered in recoil_recover_time.
	if _recoil_settle_t > 0.0:
		_recoil_settle_t -= delta
		return
	var tau := maxf(recoil_recover_time / 3.0, 0.02)
	var k := 1.0 - exp(-delta / tau)
	var step := _recoil_debt * k
	_player.add_look(-step)
	_recoil_debt -= step
	if _recoil_debt.length_squared() < 0.0000001:
		_recoil_debt = Vector2.ZERO


## BB-4 Stage B: viewmodel kick spring (was Goal 1's exponential decay).
## The kick offsets are spring positions with their own velocities; a
## shot's impulse (see _apply_recoil) punches them back and the
## under-damped spring (VM_KICK_DAMPING_RATIO < 1) settles them through
## a small forward overshoot — the gun reads as mass coming back onto
## the hands, not a value sliding home on a rail. Semi-implicit
## integration with the same substep clamp as the pose springs.
func _tick_vm_kick(delta: float) -> void:
	if _vm_kick_z == 0.0 and _vm_kick_pitch == 0.0 \
			and _vm_kick_z_vel == 0.0 and _vm_kick_pitch_vel == 0.0:
		return
	var c := 2.0 * VM_KICK_DAMPING_RATIO * sqrt(VM_KICK_STIFFNESS)
	var sub := _spring_substeps(delta)
	var steps: int = sub[0]
	var h: float = sub[1]
	for i in steps:
		_vm_kick_z_vel += (-VM_KICK_STIFFNESS * _vm_kick_z - c * _vm_kick_z_vel) * h
		_vm_kick_z += _vm_kick_z_vel * h
		_vm_kick_pitch_vel += (-VM_KICK_STIFFNESS * _vm_kick_pitch - c * _vm_kick_pitch_vel) * h
		_vm_kick_pitch += _vm_kick_pitch_vel * h
	if absf(_vm_kick_z) < 0.0002 and absf(_vm_kick_z_vel) < 0.002:
		_vm_kick_z = 0.0
		_vm_kick_z_vel = 0.0
	if absf(_vm_kick_pitch) < 0.0002 and absf(_vm_kick_pitch_vel) < 0.002:
		_vm_kick_pitch = 0.0
		_vm_kick_pitch_vel = 0.0


## BB-4 Stage C: current landing-dip state [depth_m, pitch_rad].
## Verify/debug hook, same spirit as get_ads_blend().
func get_land_dip() -> Vector2:
	return Vector2(_land_dip, _land_dip_pitch)


## BB-4 Stage C: viewmodel landing dip (plan §2.5). The tracker polls
## the player duck-typed (the _player_speed pattern): while airborne
## it banks the fall speed; on the grounded transition a fall past
## LAND_DIP_MIN_FALL fires the dip as an offset on the dip spring
## channel — depth and muzzle-down pitch scaled by fall speed and by
## the weapon's weight (land_dip_mult, cached in setup). The spring
## (under-damped, LAND_DIP_DAMPING_RATIO) hauls it home through one
## soft bounce. Players without is_on_floor (test doubles) read as
## permanently grounded, so the channel simply never fires for them.
func _tick_land_dip(delta: float) -> void:
	var grounded := true
	if _player != null and is_instance_valid(_player) \
			and _player.has_method("is_on_floor"):
		grounded = bool(_player.call("is_on_floor"))
	if not grounded:
		_air_vy = _player_velocity().y
	elif not _was_grounded and _air_vy < -LAND_DIP_MIN_FALL:
		var fall := -_air_vy
		_land_dip += minf(fall * LAND_DIP_PER_SPEED, LAND_DIP_MAX) * _w_dip_mult
		_land_dip_pitch += minf(fall * LAND_DIP_PITCH_PER_SPEED,
				LAND_DIP_PITCH_MAX) * _w_dip_mult
		_air_vy = 0.0
	_was_grounded = grounded
	if _land_dip == 0.0 and _land_dip_vel == 0.0 \
			and _land_dip_pitch == 0.0 and _land_dip_pitch_vel == 0.0:
		return
	var c := 2.0 * LAND_DIP_DAMPING_RATIO * sqrt(LAND_DIP_STIFFNESS)
	var sub := _spring_substeps(delta)
	var steps: int = sub[0]
	var h: float = sub[1]
	for i in steps:
		_land_dip_vel += (-LAND_DIP_STIFFNESS * _land_dip - c * _land_dip_vel) * h
		_land_dip += _land_dip_vel * h
		_land_dip_pitch_vel += (-LAND_DIP_STIFFNESS * _land_dip_pitch - c * _land_dip_pitch_vel) * h
		_land_dip_pitch += _land_dip_pitch_vel * h
	if absf(_land_dip) < 0.0002 and absf(_land_dip_vel) < 0.002:
		_land_dip = 0.0
		_land_dip_vel = 0.0
	if absf(_land_dip_pitch) < 0.0002 and absf(_land_dip_pitch_vel) < 0.002:
		_land_dip_pitch = 0.0
		_land_dip_pitch_vel = 0.0


# --- Muzzle flash / shells (preallocated, no per-shot allocs) ---

func _build_flash() -> void:
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.62, 0.2)
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 6.0
	_flash_light.omni_attenuation = 1.0
	_flash_light.shadow_enabled = false
	_flash_quad = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.28, 0.28)
	_flash_quad.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(1.0, 0.7, 0.25)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.15)
	mat.emission_energy_multiplier = 4.0
	_flash_quad.material_override = mat
	_flash_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash_quad.visible = false
	_flash_light.visible = false
	# Parent to the VIEWMODEL, not the weapon node: _show_muzzle_flash sets
	# positions in viewmodel-local coords (Muzzle marker space), and the
	# viewmodel gets reparented onto the camera on equip — children follow.
	# (Previously the light lived in weapon-node space, so the flash could
	# appear offset from the muzzle / fail to track the camera.)
	if _viewmodel != null:
		_viewmodel.add_child(_flash_light)
		_viewmodel.add_child(_flash_quad)
	else:
		add_child(_flash_light)
		add_child(_flash_quad)


func _show_muzzle_flash() -> void:
	if _muzzle == null:
		return
	var mp := _muzzle.position
	_flash_light.position = mp
	_flash_quad.position = mp
	_flash_light.light_energy = muzzle_flash_energy
	_flash_light.visible = true
	_flash_quad.visible = true
	# Goal 1: per-shot flash variance — no two shots look identical.
	_flash_quad.scale = Vector3.ONE * randf_range(0.9, 1.35)
	_flash_t = muzzle_flash_time


func _build_shell_pool() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.76, 0.62, 0.30)
	mat.roughness = 0.35
	mat.metallic = 0.85
	for i in SHELL_POOL_SIZE:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.012, 0.012, 0.03)
		mi.mesh = bm
		mi.material_override = mat
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_shells.append({"node": mi, "vel": Vector3.ZERO, "life": 0.0})


func _eject_shell() -> void:
	if _eject == null:
		return
	for entry in _shells:
		if entry["life"] <= 0.0:
			var mi: MeshInstance3D = entry["node"]
			mi.global_position = _eject.global_position
			var basis_t: Basis = _eject.global_transform.basis
			var vel: Vector3 = (basis_t.x * randf_range(0.8, 1.4)
				+ basis_t.y * randf_range(1.2, 2.0)
				- basis_t.z * randf_range(0.2, 0.6)) * 1.6
			entry["vel"] = vel
			entry["life"] = SHELL_LIFE
			mi.visible = true
			return


# --- Per-frame ---

func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	# Goal 3 BURST: spend queued burst rounds as the RPM cooldown clears.
	# Empty mag cancels the burst (dry-fire + auto-reload come from
	# _attempt_fire's own path, so stop here to avoid a dry-fire loop).
	if _burst_left > 0:
		if mag <= 0:
			_burst_left = 0
		elif _cooldown <= 0.0 and not _lowering and _raise_t >= raise_time \
				and _reload_stage == _ReloadStage.NONE and _cycle_t <= 0.0:
			_burst_left -= 1
			_attempt_fire()
	if _cycle_t > 0.0:
		_cycle_t -= delta
		if not _cycle_sfx_done and _cycle_t <= cycle_time * 0.35:
			_cycle_sfx_done = true
			Sfx.play_2d("pump_cycle" if fire_mode == FireMode.PUMP else "bolt_cycle")
	_recover_recoil(delta)
	_tick_vm_kick(delta)
	_tick_reload(delta)
	_tick_land_dip(delta)
	_tick_viewmodel(delta)
	_tick_flash(delta)
	_tick_shells(delta)
	_tick_lens_pip()


## BB-4 Stage C: progress (0..1) through the CURRENT reload stage,
## read straight off the existing stage timer — the choreography is
## sampled from the timers, never the other way round (timing is law).
func _reload_stage_progress() -> float:
	if _reload_stage == _ReloadStage.NONE:
		return 0.0
	var dur := float(reload_stages[_reload_stage - 1])
	if dur <= 0.0:
		return 1.0
	return clampf(1.0 - _reload_t / dur, 0.0, 1.0)


## BB-4 Stage C: the reload pose track (plan §2.3). Keyframe poses sit
## at the stage boundaries — zero at reload start, MAG_OUT key at the
## end of stage 1, MAG_IN key at the end of stage 2, zero again at the
## end of CHAMBER — smoothstepped within each stage, so the track is
## continuous across boundaries and the pose spring adds life on top.
## CHAMBER adds a sin pulse (the bolt driven home) over its keyframe
## return. Pure function of (stage, progress) + the TUNABLES consts:
## every weapon performs the same track stretched over its own
## reload_stages — no per-weapon keyframes exist or are needed.
## Returns [position_offset, rotation_offset].
func reload_track_pose(stage: int, progress: float) -> Array:
	var p := clampf(progress, 0.0, 1.0)
	var s := p * p * (3.0 - 2.0 * p) # smoothstep
	var from_pos := Vector3.ZERO
	var from_rot := Vector3.ZERO
	var to_pos := Vector3.ZERO
	var to_rot := Vector3.ZERO
	match stage:
		_ReloadStage.MAG_OUT:
			to_pos = RELOAD_POSE_MAG_OUT_POS
			to_rot = RELOAD_POSE_MAG_OUT_ROT
		_ReloadStage.MAG_IN:
			from_pos = RELOAD_POSE_MAG_OUT_POS
			from_rot = RELOAD_POSE_MAG_OUT_ROT
			to_pos = RELOAD_POSE_MAG_IN_POS
			to_rot = RELOAD_POSE_MAG_IN_ROT
		_ReloadStage.CHAMBER:
			from_pos = RELOAD_POSE_MAG_IN_POS
			from_rot = RELOAD_POSE_MAG_IN_ROT
		_:
			return [Vector3.ZERO, Vector3.ZERO]
	var pos := from_pos.lerp(to_pos, s)
	var rot := from_rot.lerp(to_rot, s)
	if stage == _ReloadStage.CHAMBER:
		var pulse := sin(p * PI)
		pos += RELOAD_POSE_CHAMBER_POS * pulse
		rot += RELOAD_POSE_CHAMBER_ROT * pulse
	return [pos, rot]


func _tick_reload(delta: float) -> void:
	if _reload_stage == _ReloadStage.NONE:
		return
	_reload_t -= delta
	if _reload_t > 0.0:
		return
	match _reload_stage:
		_ReloadStage.MAG_OUT:
			_reload_stage = _ReloadStage.MAG_IN
			_reload_t = float(reload_stages[1])
		_ReloadStage.MAG_IN:
			var need := mag_size - mag
			var take := mini(need, reserve)
			mag += take
			reserve -= take
			emit_ammo()
			_reload_stage = _ReloadStage.CHAMBER
			_reload_t = float(reload_stages[2])
			# BB-4 Stage C: the mag seats and the chambering starts on
			# this boundary — kick the pose springs so the gun jolts in
			# the hands at the exact frame the ammo lands (the SFX
			# clicks already sit on this boundary). Visual only.
			_vm_pos_vel += Vector3(0.0, RELOAD_SEAT_JOLT_POS, 0.0)
			_vm_rot_vel += Vector3(RELOAD_SEAT_JOLT_ROT + RELOAD_RACK_JOLT_ROT, 0.0, 0.0)
		_ReloadStage.CHAMBER:
			_reload_stage = _ReloadStage.NONE


## Gate fix (2026-11-28): the shared substep plan for every semi-implicit
## spring in this file (recoil kick, landing dip, pose pos/rot). Returns
## [steps, h]. Two rules, both load-bearing:
##  - h NEVER exceeds VM_SPRING_MAX_DT (1/30 s). Semi-implicit Euler goes
##    unstable once h passes 2*(sqrt(zeta^2 + 1) - zeta)/omega; the
##    stiffest, least-damped channel here (kick: omega 20, zeta 0.30)
##    caps at ~0.074 s, so 1/30 s keeps every channel stable with >2x
##    margin. The pre-fix code capped the substep COUNT at 16, so any
##    frame delta past ~0.53 s silently stretched h: a 2 s hitch (Deck
##    suspend/resume mid-firefight) integrated the kick at h = 0.125
##    and blew it to ~4.5e10, displacing the viewmodel for seconds.
##    The step count is therefore derived from the max-h target, not
##    capped (the EnemyBase flinch spring already worked this way).
##  - The integrated spring time is clamped to VM_SPRING_MAX_FRAME, so
##    a multi-second (or multi-hour) hitch costs at most ~30 substeps
##    per channel. ONLY the springs drop the excess time — gameplay
##    timers (cooldowns, reload staging) keep the real delta in
##    _process. One clamped second is plenty: the kick envelope decays
##    as exp(-zeta*omega*t) = exp(-6t), so after the clamped step it
##    sits at ~0.25% of its amplitude and re-settles almost at once.
## For delta <= 16 * VM_SPRING_MAX_DT the step count and h are exactly
## the pre-fix values, so normal-frame feel is numerically unchanged
## (the verify suites pin it).
static func _spring_substeps(delta: float) -> Array:
	var eff := minf(maxf(delta, 0.0), VM_SPRING_MAX_FRAME)
	var steps := maxi(1, int(ceil(eff / VM_SPRING_MAX_DT)))
	return [steps, eff / float(steps)]


## BB-4 Stage B: critically-damped scalar spring, integrated in CLOSED
## FORM (exact for any step size). Monotonic by construction — it can
## never overshoot its target, which the ADS blend's consumers require:
## the PiP lens wakes at blend > 0.5 and the scope viewmodel hides at
## > 0.85, so an overshooting blend would flicker both. Snaps exactly
## onto the target inside a hair of it, so blend == 0.0 / 1.0 are
## reachable states rather than asymptotes (the ADS pose contract pins
## blend == 1.0). Returns [value, velocity]. Pure + static so the feel
## verify can pin the monotonicity contract without a renderer.
static func _spring_crit_step(x: float, v: float, target: float, omega: float, h: float) -> Vector2:
	var d := x - target
	var b := v + omega * d
	var e := exp(-omega * h)
	var nx := target + (d + b * h) * e
	var nv := (v - omega * b * h) * e
	if absf(nx - target) < 0.0015 and absf(nv) < 0.02:
		return Vector2(target, 0.0)
	return Vector2(nx, nv)


## BB-4 Stage B: THE viewmodel tick — the single writer of the
## viewmodel transform (replaces _tick_raise_lower + _tick_sway_bob and
## their `animating` peace-treaty flag). Each frame: compose a target
## pose (hip/ADS lerp + sprint pose, or the lowered pose while
## lowering), integrate the position/rotation springs toward it, then
## add the UNCHANGED sway/bob formulas and the recoil-kick spring
## offsets on top — the same separation the flag used to enforce, now
## structural. Raise/lower are spring states, not separate writers:
## on_equip seeds the spring at VM_RAISE_START_OFFSET with the
## under-damped VM_RAISE_DAMPING_RATIO; _raise_t bookkeeping (and
## therefore is_ready()) is untouched.
func _tick_viewmodel(delta: float) -> void:
	if _viewmodel == null or _camera == null:
		return
	# Sprint fallback poll: the manager's sprint_changed forward is the
	# primary path; this covers weapons built after sprint started and
	# signal-less player doubles (the manager's ADS fallback pattern).
	if _player != null and is_instance_valid(_player):
		var sp: Variant = _player.get("_sprinting")
		if sp is bool:
			_sprinting = sp
	_sway_t += delta
	if _raise_t < raise_time:
		_raise_t += delta
	# ADS blend: critically-damped spring (monotonic — see
	# _spring_crit_step). Omega chosen so ~95% of travel closes in
	# ADS_BLEND_TIME, comparable to the old linear 10/s full travel, so
	# BB-1 sight timing does not regress.
	var ads_step := _spring_crit_step(_ads_blend, _ads_vel,
			1.0 if _ads else 0.0, 4.5 / ADS_BLEND_TIME, delta)
	_ads_blend = ads_step.x
	_ads_vel = ads_step.y
	# Sprint blend: same critically-damped family, its own time
	# constant. ADS suppresses the pose (the player cancels sprint on
	# ADS anyway; this keeps a stale flag from tilting an aimed gun).
	var sprint_step := _spring_crit_step(_sprint_blend, _sprint_blend_vel,
			1.0 if (_sprinting and not _ads) else 0.0, 4.5 / SPRINT_BLEND_TIME, delta)
	_sprint_blend = sprint_step.x
	_sprint_blend_vel = sprint_step.y
	# Compose the target pose (plan §2.1 stack): base hip/ADS lerp,
	# sprint pose, then the Stage C reload track sampled off the stage
	# timers. The track's amplitude fades with the ADS blend — at full
	# ADS the gun works at RELOAD_ADS_AMPLITUDE so the choreography
	# yields to the sight picture instead of throwing the aim off.
	var target_pos := HIP_POS.lerp(_ads_pos, _ads_blend)
	var target_rot := HIP_ROT.lerp(ADS_ROT, _ads_blend)
	var pose_w := _sprint_blend * (1.0 - _ads_blend)
	target_pos += SPRINT_POSE_POS * pose_w
	target_rot += SPRINT_POSE_ROT * pose_w
	if _reload_stage != _ReloadStage.NONE:
		var track := reload_track_pose(_reload_stage, _reload_stage_progress())
		var amp := lerpf(1.0, RELOAD_ADS_AMPLITUDE, _ads_blend)
		target_pos += (track[0] as Vector3) * amp
		target_rot += (track[1] as Vector3) * amp
	if _lowering:
		target_pos = HIP_POS + VM_LOWER_OFFSET
		target_rot = HIP_ROT
	# Integrate the pose springs: semi-implicit (symplectic), substepped
	# via _spring_substeps so no single step exceeds VM_SPRING_MAX_DT
	# and the integrated time is hitch-clamped (frame-hitch stable).
	# BB-4×BB-5 join (Stage C): both stiffnesses scale by the weapon's
	# spring_stiffness_mult — a heavy gun's springs are lazier, so it
	# lags, wallows and settles late where a light gun snaps (plan §3.2).
	var pos_k := VM_SPRING_STIFFNESS * _w_spring_mult
	var rot_k := VM_ROT_SPRING_STIFFNESS * _w_spring_mult
	var pos_ratio := VM_RAISE_DAMPING_RATIO if _raise_t < raise_time else VM_SPRING_DAMPING_RATIO
	var pos_c := 2.0 * pos_ratio * sqrt(pos_k)
	var rot_c := 2.0 * VM_ROT_SPRING_DAMPING_RATIO * sqrt(rot_k)
	var sub := _spring_substeps(delta)
	var steps: int = sub[0]
	var h: float = sub[1]
	for i in steps:
		_vm_pos_vel += (-pos_k * (_vm_pos - target_pos) - pos_c * _vm_pos_vel) * h
		_vm_pos += _vm_pos_vel * h
		_vm_rot_vel += (-rot_k * (_vm_rot - target_rot) - rot_c * _vm_rot_vel) * h
		_vm_rot += _vm_rot_vel * h
	# Snap: a settled spring sits EXACTLY on its target — the ADS pose
	# contract pins viewmodel.position == _ads_pos at full ADS, and a
	# spring that only asymptotes would never quite get there.
	if _vm_pos.distance_squared_to(target_pos) < 0.00000016 and _vm_pos_vel.length_squared() < 0.000016:
		_vm_pos = target_pos
		_vm_pos_vel = Vector3.ZERO
	if _vm_rot.distance_squared_to(target_rot) < 0.00000016 and _vm_rot_vel.length_squared() < 0.000016:
		_vm_rot = target_rot
		_vm_rot_vel = Vector3.ZERO
	# Additives — formulas unchanged from the pre-spring tick: walk bob
	# (hip-fire only, frozen in ADS) and recoil kick on position; idle
	# sway (ADS-scaled, faded in over the raise) and recoil pitch on
	# rotation.
	var speed := _player_speed()
	if speed > 0.8 and not _ads:
		# BB-4×BB-5 join: a heavy gun's bob phase runs slower (it lumbers).
		_bob_t += delta * (2.0 + speed * 0.6) * _w_bob_rate_mult
	var bob_mult := ADS_BOB_MULT if _ads else 1.0
	# BB-4×BB-5 join: bob amplitude grows with weapon weight.
	var bob := Vector3(
		cos(_bob_t * BOB_FREQ) * BOB_AMOUNT * 0.6,
		sin(_bob_t * BOB_FREQ * 2.0) * BOB_AMOUNT * 0.5,
		0.0) * bob_mult * _w_bob_mult * clampf(speed / 3.0, 0.0, 1.0)
	# Goal 1: viewmodel recoil kick rides on top of bob (backward +Z,
	# since forward is -Z). Its spring lives in _tick_vm_kick. BB-4
	# Stage C: the landing dip (its own spring, _tick_land_dip) pushes
	# the gun down on the same write.
	_viewmodel.position = _vm_pos + bob + Vector3(0.0, -_land_dip, _vm_kick_z)
	var ads_mult := ADS_SWAY_MULT if _ads else 1.0
	# BB-4×BB-5 join: idle sway amplitude grows with weapon weight.
	var sway := Vector3(
		sin(_sway_t * SWAY_SPEED * 1.7) * SWAY_AMOUNT,
		sin(_sway_t * SWAY_SPEED * 1.3) * SWAY_AMOUNT * 1.2,
		0.0) * ads_mult * _w_sway_mult
	var raise_blend := clampf(_raise_t / maxf(raise_time, 0.001), 0.0, 1.0)
	_viewmodel.rotation = _vm_rot + sway * raise_blend \
			+ Vector3(_vm_kick_pitch - _land_dip_pitch, 0.0, 0.0)
	# BB-1: reflex/ACOG dot appears only once the sight is mostly up.
	# BB-1c/BB-1d: on a PiP optic (ACOG, reflex) the floating dot stands
	# down while the lens is up — the in-glass reticle replaces it (no
	# double reticles).
	if _ads_dot != null:
		_ads_dot.visible = _ads_blend > 0.5 and not _lens_active
	# BB-1: at full ADS a sniper scope hands the view to the HUD scope
	# overlay (the GLB scope is an opaque prop — there is nothing to see
	# through it). Hide the viewmodel while scoped; it returns as the
	# blend falls. Only while equipped (parented to the camera) — a
	# parked viewmodel's visibility belongs to on_unequip.
	if _optic == "scope" and _viewmodel.get_parent() == _camera:
		_viewmodel.visible = _ads_blend < 0.85


func _tick_flash(delta: float) -> void:
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_flash_light.light_energy = 0.0
			_flash_light.visible = false
			_flash_quad.visible = false


func _tick_shells(delta: float) -> void:
	for entry in _shells:
		var life: float = entry["life"]
		if life <= 0.0:
			continue
		life -= delta
		entry["life"] = life
		var mi: MeshInstance3D = entry["node"]
		if life <= 0.0:
			mi.visible = false
			continue
		var vel: Vector3 = entry["vel"]
		vel.y -= SHELL_GRAVITY * delta
		entry["vel"] = vel
		mi.global_position += vel * delta
		mi.rotation += Vector3(9.0, 7.0, 5.0) * delta
		if life < 0.3:
			var s := clampf(life / 0.3, 0.05, 1.0)
			mi.scale = Vector3(s, s, s)
		else:
			mi.scale = Vector3.ONE


