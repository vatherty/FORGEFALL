# tuning.gd — FORGEFALL central balance/tunable constants.
# Purpose: the single file Colin (and the coordinator) edits to rebalance the
# game. Every worker keeps their own `#region TUNABLES` consts in their main
# script during the build; at the end the coordinator consolidates them HERE.
# game_state.gd already reads the core combat/economy values from this file.
# Connections: class_name Tuning, referenced by scripts/core/game_state.gd (and
# eventually weapons/enemies/forge workers). Pure constants — no state.
class_name Tuning
extends RefCounted

#region TUNABLES — core / game balance (worker 1: project setup)

## Killstreak unlock thresholds: UAV at 3, Airstrike at 5, Attack Chopper at 7.
const KILLSTREAK_THRESHOLDS := [3, 5, 7]
## Killstreak display names in slot order (indices 0/1/2).
const KILLSTREAK_NAMES := ["UAV", "Airstrike", "Attack Chopper"]

## Score for a normal kill.
const SCORE_KILL := 100
## Score for a headshot kill.
const SCORE_HEADSHOT_KILL := 150

## Forge build-budget granted at the start of every run.
const FORGE_START_BUDGET := 300
## Budget trickle granted per wave cleared (keeps the Forge usable all run).
const FORGE_BUDGET_PER_WAVE := 50

## Build-phase duration in seconds between waves (Forge console window).
const BUILD_PHASE_SECONDS := 45

#endregion

#region TUNABLES — player (worker 2: player controller)
## NOTE: live values are the consts in scripts/player/player.gd; this mirrors them.
const PLAYER_WALK_SPEED := 6.0
const PLAYER_SPRINT_SPEED := 11.0
const PLAYER_CROUCH_SPEED := 3.2
const PLAYER_ACCEL_GROUND := 60.0
const PLAYER_FRICTION_GROUND := 45.0
const PLAYER_AIR_CONTROL := 0.55
const PLAYER_GRAVITY := 20.0
const PLAYER_JUMP_VELOCITY := 5.8
const PLAYER_COYOTE_TIME := 0.12
const PLAYER_JUMP_BUFFER := 0.15
const PLAYER_SLIDE_FRICTION := 3.0
const PLAYER_SLIDE_MIN_SPEED := 5.0
const PLAYER_SLIDE_END_SPEED := 2.0
const PLAYER_SLIDE_MAX_TIME := 2.5
const PLAYER_SLIDE_HOP := 5.5
const PLAYER_HEAD_SLIDE := 0.85  # slide camera: lowest stance (stand 1.6 / crouch 1.05)
const PLAYER_WALLRUN_MAX_TIME := 3.0
const PLAYER_WALLRUN_ENTRY_BOOST := 1.5  # +50% on attach (see player.gd BOOST READING note)
const PLAYER_WALLRUN_MIN_SPEED := 6.0  # full walking speed
const PLAYER_WALLRUN_AIM_DOT := 0.5  # aimed-at-wall gate
const PLAYER_WALLRUN_PARALLEL_DOT := 0.7  # moving-parallel gate
const PLAYER_WALLRUN_GRAVITY_SCALE := 0.12
const PLAYER_WALLRUN_ROLL_DEG := 12.0
const PLAYER_WALL_JUMP_AWAY := 8.0
const PLAYER_WALL_JUMP_UP := 6.5  # full (hold) wall-jump height
const PLAYER_WALL_JUMP_TAP_UP := 4.0  # tap wall-jump = small hop
const PLAYER_JETPACK_THRUST_ACCEL := 45.0
const PLAYER_JETPACK_MAX_RISE := 7.0
const PLAYER_JETPACK_FUEL_MAX := 100.0
const PLAYER_JETPACK_FUEL_DRAIN := 35.0
const PLAYER_JETPACK_FUEL_REGEN := 25.0
const PLAYER_JETPACK_MAX_BURN := 2.5
const PLAYER_MAX_HP := 100.0
const PLAYER_REGEN_DELAY := 5.0
const PLAYER_REGEN_RATE := 25.0
const PLAYER_LOOK_SENS := 0.0022
const PLAYER_FOV_NORMAL := 75.0
const PLAYER_FOV_ADS := 52.0
const PLAYER_FOV_SPRINT := 90.0
const PLAYER_HEADBOB_AMP := 0.035
# Grapple (Portal Arena rules).
const GRAPPLE_RANGE := 60.0
const GRAPPLE_MAX_ROPE := 40.0
const GRAPPLE_PULL_ACCEL := 75.0
const GRAPPLE_PULL_GRAVITY_SCALE := 0.2
const GRAPPLE_PULL_MAX_SPEED := 30.0
const GRAPPLE_DIRECT_MIN_HEIGHT := 1.5
const GRAPPLE_DIRECT_MAX_SPEED := 5.0
const GRAPPLE_REEL_SPEED := 10.0
const GRAPPLE_SWING_PUMP_ACCEL := 12.0
const GRAPPLE_SWING_MAX_TANGENTIAL := 20.0
# Portals.
const PORTAL_RANGE := 30.0
const PORTAL_TELEPORT_COOLDOWN := 0.5
const PORTAL_DISC_RADIUS := 0.55
#endregion

#region TUNABLES — weapons (worker 3: weapon system)
## NOTE: live values are the consts in scripts/weapons/*.gd; this mirrors them.
## Recoil recovery is per-weapon in arsenal.gd (SMG 0.16, P9 0.18, AR-7 0.22,
## LMG 0.30, SG-12 0.45, LR-8 0.55). This const is a legacy fallback only.
const WEAPON_RECOIL_RECOVER_TIME := 0.20
const WEAPON_MUZZLE_FLASH_TIME := 0.04
const WEAPON_ADS_SPREAD_MULT := 0.35
const WEAPON_ADS_RECOIL_MULT := 0.7
const WEAPON_SHELL_POOL_SIZE := 10
const WEAPON_TRACER_LIFE := 0.06
# Arsenal quick reference (full table + recoil patterns live in arsenal.gd):
# AR-7 "Manticore": auto 700rpm, 30/120, 25dmg | LR-8 "Longeye": bolt 40rpm, 5/20, 120dmg
# SG-12 "Breacher": pump 65rpm, 6/24, 8x12dmg | SMG-9 "Hornet": auto 850rpm, 32/160, 18dmg
# P9 "Sidearm": semi 420rpm, 12/48, 22dmg | Raptor Claw: grab<=12m, throw 30m/s, dmg=clamp(speed*4,20,120)
const RAPTOR_GRAB_RANGE := 12.0
const RAPTOR_THROW_SPEED := 30.0
const EXPLOSION_DEBRIS_COUNT := 26
const PICKUP_DETECT_RADIUS := 0.9
#endregion

#region TUNABLES — enemies (worker 4: enemy AI + waves)
## NOTE: live values are the consts in scripts/enemies/*.gd; this mirrors them.
const ENEMY_HEADSHOT_MULT := 2.0
const ENEMY_FLINCH_TIME := 0.25
const ENEMY_SIGHT_RANGE := 48.0
const ENEMY_SEPARATION_RADIUS := 1.7
const WAVE_INTERMISSION_TIME := 20.0
const WAVE_MAX_CONCURRENT := 10
const WAVE_SPAWN_INTERVAL := 1.1
const WAVE_HP_GROWTH := 0.08
const WAVE_SPEED_GROWTH := 0.02
const WAVE_SPEED_CAP := 1.3
const WAVE_DMG_GROWTH := 0.05
# Per-type quick reference (full stats in grunt/rusher/marksman/brute.gd):
# Grunt: 100hp, 9dmg x3 burst | Rusher: 70hp, 7dmg x6 pellets, fast
# Marksman: 80hp, 26dmg, 24-34m band | Brute: 1200hp, 11dmg x10 LMG, wave%5==0
const BRUTE_HP := 1200.0
const GRENADE_DAMAGE := 55.0
const GRENADE_RADIUS := 4.0
#endregion

#region TUNABLES — map (worker 5: Dustline)
## NOTE: live values are the consts in scripts/maps/*.gd; this mirrors them.
const MAP_ARENA_HALF := 35.0
const MAP_SEED := 20261005
const MAP_MOTE_COUNT := 200
const MAP_ROOF_STEP := 1.0
const COVER_BARRIER_HP := 70.0
const COVER_CRATE_HP := 45.0
const COVER_BARREL_HP := 30.0
const DEBRIS_MAX_ACTIVE := 120
const DEBRIS_DESPAWN_TIME := 2.5
#endregion

#region TUNABLES — UI (worker 6: HUD)
## NOTE: live values are the consts in scripts/ui/hud.gd; this mirrors them.
const UI_HITMARKER_TIME := 0.12
const UI_KILLFEED_FADE := 4.0
const UI_KILLFEED_POOL := 6
const UI_BANNER_HOLD := 2.4
const UI_MINIMAP_RANGE := 45.0
const UI_MINIMAP_SIZE := 180.0
const UI_LOW_HP_FRAC := 0.30
const UI_HEARTBEAT_INTERVAL := 1.1
#endregion

#region TUNABLES — audio (worker 7)
## NOTE: live values are the consts in scripts/audio/audio_manager.gd; this mirrors them.
const AUDIO_POOL_2D := 12
const AUDIO_POOL_3D := 16
const AUDIO_PITCH_JITTER := 0.05
const AUDIO_MUSIC_FADE_SEC := 1.5
const AUDIO_MUSIC_VOLUME_DB := -8.0
const AUDIO_3D_UNIT_SIZE := 12.0
const AUDIO_3D_MAX_DISTANCE := 90.0
#endregion

#region TUNABLES — Forge (worker 8: ModBox DNA)
## NOTE: live values are the consts in scripts/forge/*.gd; this mirrors them.
const FORGE_BUILD_COOLDOWN := 3.0
const FORGE_MAX_VOXEL_AXIS := 12
const FORGE_MAX_TTL := 120.0
const FORGE_COST_WALL := 100
const FORGE_COST_TOWER := 150
const FORGE_COST_BARRICADE := 100
const FORGE_COST_TURRET := 250
const FORGE_COST_PICKUP := 75
## DEPRECATED (Forge batch): the flat per-weapon Forge cost is gone —
## weapons are priced per-weapon by ForgeLLM.weapon_cost() (computed,
## shown, never enforced while budget is OFF per directive A). Kept so
## old references don't break; do not use for new pricing.
const FORGE_COST_WEAPON := 200
const FORGE_COST_UAV := 150
const FORGE_COST_AIRSTRIKE := 300
const FORGE_COST_CHOPPER := 450
const FORGE_COST_SMOKE := 100
const FORGE_COST_SUPPLY := 50
const TURRET_RANGE := 30.0
const TURRET_DAMAGE := 15.0
const TURRET_HP := 150.0
const KILLSTREAK_UAV_TIME := 20.0
const DIRECTOR_BASE_BUDGET := 100
const DIRECTOR_BUDGET_PER_WAVE := 25
const DIRECTOR_CAMP_VARIANCE := 25.0
#endregion

#region TUNABLES — Android/touch (worker 9)
## NOTE: live values are the consts in scripts/android/*.gd; this mirrors them.
const TOUCH_JOY_RADIUS := 90.0
const TOUCH_JOY_DEADZONE := 0.15
const TOUCH_JOY_SPRINT_AT := 0.92
const TOUCH_LOOK_GAIN := 0.0022
const TOUCH_BTN_ALPHA := 0.55
const PERF_SCALE_HIGH := 1.0
const PERF_SCALE_MED := 0.8
const PERF_SCALE_LOW := 0.65
const HAPTIC_SHOT_MS := 25
const HAPTIC_HIT_MS := 45
const HAPTIC_KILL_MS := 70
const GYRO_GAIN := 1.6
#endregion

#region TUNABLES — auto-updater (in-game APK updates)
## Base URL of the update server (Netlify static site, HTTPS).
## EMPTY = the updater is fully disabled: no checks, no nagging, the Options
## "check for updates" button just reports "not configured".
## 2026-10-12: Tailscale-inbound was verified impossible on this VM (no
## Tailscale interface, client-only egress proxy) and torn down. Netlify
## static hosting chosen instead: https://forgefall-updates.netlify.app
## (verified public 2026-10-12 ~16:05 MDT). The manager appends "/version.json";
## apk_url values inside version.json are absolute.
const UPDATE_BASE_URL := "https://vatherty.github.io/Forgefall-updates/"
## Seconds before the version check gives up. Non-blocking; silent on failure.
const UPDATE_TIMEOUT_SEC := 8
## Installed version code used when the ForgeUpdater Android plugin is absent
## (desktop/editor builds). KEEP IN SYNC with export_presets.cfg version/code.
const FALLBACK_VERSION_CODE := 49
#endregion

#region TUNABLES — feel wave (BB-4/BB-5)
## NOTE: live values are the consts in scripts/weapons/weapon_base.gd and
## scripts/player/player.gd, and the per-weapon "weight" stats in
## scripts/weapons/arsenal.gd (WEAPONS); this mirrors them.
## BB-5 weapon weight: weight_norm = clamp((weight - MIN) / (MAX - MIN)).
const WEIGHT_MIN := 2.5        # weapon_base.gd: normalisation floor
const WEIGHT_MAX := 10.5       # weapon_base.gd: normalisation ceiling (LMG)
const WEIGHT_DEFAULT := 5.0    # weapon_base.gd: stat-less Forge/mod weapons
const WEIGHT_SPRING_SOFTEN := 0.45 # weapon_base.gd: VM spring stiffness lost at norm 1
const WEIGHT_SWAY_GROW := 0.6      # weapon_base.gd: sway amplitude gained at norm 1
const WEIGHT_BOB_GROW := 0.5       # weapon_base.gd: bob amplitude gained at norm 1
const WEIGHT_BOB_RATE_SLOW := 0.25 # weapon_base.gd: bob phase rate lost at norm 1
const WEIGHT_DIP_BASE := 0.7       # weapon_base.gd: landing-dip scale at norm 0
const WEIGHT_DIP_GROW := 0.8       # weapon_base.gd: extra dip scale at norm 1
## PENDING RULING (plan §7.2): Raptor takes full weight effects incl. the
## Stage D hitbox growth. Flip in weapon_base.gd (the live copy) to exempt.
const WEIGHT_RAPTOR_FULL_EFFECTS := true
const PLAYER_WEIGHT_SPEED_PENALTY := 0.22 # player.gd: top-speed fraction lost at norm 1
const PLAYER_WEIGHT_ACCEL_PENALTY := 0.35 # player.gd: ground-accel fraction lost at norm 1
## BB-4 Stage B: viewmodel spring core + recoil kick spring + sprint pose.
const VM_SPRING_STIFFNESS := 220.0     # weapon_base.gd: position spring (omega ~14.8)
const VM_SPRING_DAMPING_RATIO := 1.0   # weapon_base.gd: position critically damped
const VM_ROT_SPRING_STIFFNESS := 170.0 # weapon_base.gd: rotation spring (omega ~13)
const VM_ROT_SPRING_DAMPING_RATIO := 0.9 # weapon_base.gd: rotation damping
const VM_RAISE_DAMPING_RATIO := 0.85   # weapon_base.gd: raise-only under-damped settle
const VM_SPRING_MAX_DT := 1.0 / 30.0   # weapon_base.gd: per-substep clamp
const VM_RAISE_START_OFFSET := Vector3(0.0, -0.22, 0.06) # weapon_base.gd: raise seed pose
const VM_LOWER_OFFSET := Vector3(0.0, -0.25, 0.0)        # weapon_base.gd: lower target offset
const ADS_BLEND_TIME := 0.11           # weapon_base.gd: ADS spring ~95% travel time (s)
const SPRINT_BLEND_TIME := 0.16        # weapon_base.gd: sprint pose spring time (s)
const VM_KICK_STIFFNESS := 400.0       # weapon_base.gd: recoil kick spring (omega 20)
const VM_KICK_DAMPING_RATIO := 0.30    # weapon_base.gd: kick spring under-damped settle
const VM_KICK_VEL_GAIN := 6.0          # weapon_base.gd: shot impulse -> kick velocity gain
## Sprint pose: POSE ONLY (plan §7.3 default) — no fire block, no delay.
const SPRINT_POSE_POS := Vector3(-0.04, -0.05, 0.02)  # weapon_base.gd: sprint pose shift
const SPRINT_POSE_ROT := Vector3(-0.55, 0.35, -0.25)  # weapon_base.gd: sprint pose rotation
## BB-4 Stage C: reload choreography track (sampled off the staged-reload
## timers; timing untouched) + viewmodel landing dip. The BB-4×BB-5 join
## consumes the WEIGHT_* factors above: pose-spring stiffness, sway and
## bob scale by the equipped weapon's weight_effects() multipliers.
const RELOAD_POSE_MAG_OUT_POS := Vector3(0.0, -0.06, 0.0)   # weapon_base.gd: MAG_OUT key dip
const RELOAD_POSE_MAG_OUT_ROT := Vector3(0.10, 0.0, -0.60)  # weapon_base.gd: MAG_OUT key roll
const RELOAD_POSE_MAG_IN_POS := Vector3(0.0, -0.10, 0.0)    # weapon_base.gd: MAG_IN key dip
const RELOAD_POSE_MAG_IN_ROT := Vector3(0.28, 0.0, -0.15)   # weapon_base.gd: MAG_IN key pitch
const RELOAD_POSE_CHAMBER_POS := Vector3(0.0, 0.0, -0.03)   # weapon_base.gd: chamber pulse peak
const RELOAD_POSE_CHAMBER_ROT := Vector3(-0.06, 0.0, 0.0)   # weapon_base.gd: chamber pulse peak
const RELOAD_ADS_AMPLITUDE := 0.4     # weapon_base.gd: choreography scale at full ADS
const RELOAD_SEAT_JOLT_POS := 0.9     # weapon_base.gd: mag-seat impulse -> pos spring vel
const RELOAD_SEAT_JOLT_ROT := -1.0    # weapon_base.gd: mag-seat impulse -> rot spring vel
const RELOAD_RACK_JOLT_ROT := -2.2    # weapon_base.gd: rack snap impulse -> rot spring vel
const LAND_DIP_PER_SPEED := 0.008       # weapon_base.gd: dip depth per m/s of fall
const LAND_DIP_MAX := 0.09              # weapon_base.gd: dip depth ceiling (pre-weight)
const LAND_DIP_PITCH_PER_SPEED := 0.010 # weapon_base.gd: dip pitch per m/s of fall
const LAND_DIP_PITCH_MAX := 0.12        # weapon_base.gd: dip pitch ceiling (pre-weight)
const LAND_DIP_MIN_FALL := 2.0          # weapon_base.gd: min fall speed that dips the gun
const LAND_DIP_STIFFNESS := 170.0       # weapon_base.gd: dip spring (omega ~13)
const LAND_DIP_DAMPING_RATIO := 0.55    # weapon_base.gd: dip spring under-damped bounce
## BB-5 Stage D: dynamic capsule hitbox (player.gd owns the capsule).
const PLAYER_WEIGHT_HITBOX_RADIUS := 0.10 # player.gd: capsule radius gained at hitbox_norm 1
const PLAYER_WEIGHT_HITBOX_BASE_RADIUS := 0.4 # player.gd: scenes/player.tscn capsule radius
## BB-4 Stage D: soldier polish (enemy_base.gd / voxel_soldier.gd).
const ANIM_FLINCH_STIFFNESS := 1100.0     # enemy_base.gd: rendered-flinch spring (omega ~33)
const ANIM_FLINCH_DAMPING_RATIO := 0.5    # enemy_base.gd: ~16% overshoot past neutral
const ANIM_SPEED_SMOOTH_RATE := 10.0      # enemy_base.gd: stride input smoothing (/s)
const AIM_PITCH_ARM_FOLLOW := 0.6         # voxel_soldier.gd: arm share of the aim elevation
const HIP_SWAY_ROLL := 0.05               # voxel_soldier.gd: idle->walk weight-shift roll (rad)
#endregion
