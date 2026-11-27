# FORGEFALL Bug Bash — Colin's playtest reports

## Session 2026-11-26 (Team Deathmatch, Steam Deck, from-source build)
Colin's verdict: "team death match is actually kinda good" — movement feels great overall.

- [x] BB-1 SIGHTS/ADS: FIXED 2026-11-26 (audit: lenses opaque with no dots, LMG aperture +38px off-centre, scope = iron zoom + glass; fix: per-weapon sight anchors, optic classes iron/reflex/ACOG 3x/scope 5x, reflex dots, sniper scope overlay; verify_ads_alignment 144 checks xvfb) — sights do not work — iron, sniper scope, or ACOG. Needs proper ADS.
- [x] BB-2 LANDING MOMENTUM: FIXED 2026-11-26 (root cause: binary sprint-latch target speed + per-component drag; fix: vector ground model, uniform overspeed bleed; verify_landing_wallrun_entry 22/0) — inconsistent — sometimes you keep your speed on landing,
      sometimes you stop in place. (Momentum jump on landing feels weird.)
- [x] BB-3 WALL RUN: FIXED 2026-11-26 (dead-zone entry gates + stick-flicker detach/lockout; fix: diagonal entry band + 0.15s wish grace; anti-cheese kept) — only works sometimes — entry is unreliable.
- [ ] BB-4 ANIMATION/FEEL: animations and feel need work — "feels like mobile game",
      wants proper animation feel if possible.

## Pre-session (launcher, fixed before play)
- Deck source copy had never been imported -> 288 script parse errors on first launch
  (class cache missing). Fixed by --import on the Deck; relaunch clean (0 script errors).
  Lesson: after any Deck file sync, run an import before launching the game.
- [ ] BB-5 WEIGHT: game feels "flowy", no weight — "as if you were a kite".
      Colin's design rule: guns make you heavier — heavier gun = slower, easier to
      hit; bigger guns even more. Weapon encumbrance + grounded feel.
- [x] BB-6 SKY/ENVIRONMENT: FIXED 2026-11-26 (audit: sky rendered as flat peach void #fdc7a3 on all 7 maps, fog_sky_affect 0.5 washed the gradient; fix: per-map procedural skies with sun/moon discs, cloud cover, zombies night + stars, silhouettes pulled in; verify_skies 56 checks) — "no skybox on any of the maps so it feels dull" — and
      Colin links this to BB-5: no visual references/distractions in the environment
      makes movement feel floatier. (Recon: a shared dusk gradient sky exists in
      map_builder_base for all maps — audit what it actually renders as.)
      FOLLOW-UP 2026-11-26 (Colin: "an actual skybox that's copyright free"): the
      procedural skies were replaced with REAL photographic skyboxes from Poly
      Haven (CC0) — see assets/skies/SOURCES.md. Per-map photos, sun/moon lights
      aimed from the HDRs, fog sampled from each texture's horizon band;
      verify_skies updated to the PanoramaSkyMaterial contract, captures in
      sky-audit/real-after/.
- [x] BB-6a DUSTLINE RING: the distant-building skyline ring around Dustline makes no
      sense — Dustline is not an industrial/commercial space. (Ring fits Cinder City
      perfectly.) Replace with desert-appropriate backdrop (mesas) or remove.
- [x] BB-6b CINDER SKY: its skybox (Camdeboo Road) shows a mountain range — wrong for
      a city. Swap to a terrain-free warm sky (industrial_sunset_puresky candidate).
- [x] BB-1b ACOG/REFLEX SEE-THROUGH: ACOG now has a dot but the optic is still opaque —
      you can't see through it. Lenses must be transparent/see-through on reflex + ACOG.
- [x] BB-7 OUT OF BOUNDS: on almost all maps you can fly off and not die. Colin's spec:
      (1) leaving the map must kill you; (2) it shouldn't look possible — geometry must
      extend as far as you can see (no visible world edge); (3) Black Ops 3 / Battlefield
      system: cross the boundary and a countdown starts — return in time or die.
- [x] BB-8 BOTS: bots are too robotic — they hit you even at extreme speed in the sky
      (aim = exact current position every shot; spread depends on distance only, not
      target velocity; no reaction time or tracking lag). Colin: "there needs to be
      levels of the bots" — difficulty tiers + humanised aim.

Round-2 (sky2): BB-6a done — Dustline's ring was 44 buildings 10-45 m tall; replaced
with layered flat-topped mesas (near + far, fog-blended). OUTPOST had the identical
mismatch (desert outpost, city skyline) and got the same mesa treatment. Factory/
Foundry/TD/Zombies rings left (thematically fine). BB-6b done — Cinder now uses
Industrial Sunset (Pure Sky, CC0): terrain-free, sun az 37.5/el 4.2 clamped 12, fog
resampled cooler (0.407,0.447,0.493), 75 KB. NOTE: mood shifts cooler grey-gold vs
Camdeboo's deep red — the price of zero terrain; 19 warmer candidates all had
mountains/trees/buildings baked in. Colin's device verdict pending.

BB-1b done: root cause deeper than the lens — the GLB optics are SOLID (3 plates cross
the sight line on ar7/smg9/br3). Fix in arsenal.gd build_viewmodel: _carve_sight_tunnel
drops triangles inside a 30 mm tunnel along the sight axis (rims/housings survive) +
_make_optic_glass turns remaining lens rims into real alpha glass (0.20, no depth draw).
World visibility through aperture: 0.000 -> 0.958/1.000/0.984. verify_ads_alignment
127/0 headless, 170/0 xvfb (anchors still <=1 px). CAVEAT: BR-3 ACOG now reads as an
open optic window, not an enclosed tube — tube feel needs a model-side rebuild.

BB-7 done: per-map play bounds (arena + ~20 m grace, top y=60) registered by builders
in group map_play_bounds; 900x900 ground aprons in each map's ground colour (1 cm below
floor, collision on) so the world runs to the horizon; player-side 10 s countdown with
oob_changed signal -> HUD warning (red under 3 s); expiry/kill-floor (y<bounds.min.y-25,
else y<-100) dies via the existing _die() path — no kill credit. verify_oob 43/0.
CORRECTION to the stream brief: SP bots are BotFighter/EnemyBase, NOT player instances —
OOB covers real players (the actual complaint); bots are navmesh-bound and cannot leave.
Known nuance: BotTDM's last-attacker window can credit a recent attacker on an OOB
death (pre-existing heuristic, unchanged).

BB-8 done: humanised bot aim in bot_fighter.gd (tracked aim point with capped swing
rate, sampled perception + noisy dead-reckoning lead, per-tier reaction time, motion
error scaling with target lateral speed) + 4 tiers (Rookie/Regular/Hardened/Elite)
selected via a BOT LEVEL control in the DEPLOY panel (Preferences bot_difficulty,
default Regular), per-bot +-20% jitter. Measured hit rates at 25 m: 60 m/s crossing ->
Rookie .017 / Regular .000 / Hardened .046 / Elite .011; stationary Regular .591,
Elite .947. verify_bot_skill 59/0. MP bot fill + zombies/TD enemies untouched (legacy
paths preserved). Round-2 (BB-6a/6b, BB-1b, BB-7, BB-8) integrated on the merged tree.
- [x] BB-1c ACOG LENS (Colin's spec): KEEP the full-screen FOV zoom on ADS (that's how
      you get closer to the gun) AND add a zoom + parallax effect on the ACOG lens
      itself — magnified picture-in-picture inside the glass (PINNED by Colin: lens zoom = 1.5x the 3x FOV zoom, i.e. sub-camera fov = main ADS fov / 1.5, 4.5x effective), reticle in the glass,
      eye-relief parallax + scope shadow. BR-3 only for now.

BB-1c done: ACOG PiP lens (weapon_base.gd rig + arsenal.gd disc + acog_lens.gdshader).
Full-screen 3x FOV zoom untouched; lens sub-camera fov = main fov / LENS_EXTRA_ZOOM
(pinned 1.5 by Colin; measured 1.52x in rendered frames). Reticle lives in the glass;
parallax swim measured -13.0 px against a +0.12 eye offset while the reticle centroid
held (639.0, 359.5); scope shadow darkens the rim with misalignment. Viewport renders
only while br3 equipped + ADS blend > 0.5. verify_ads_alignment 135/0 headless,
194/0 xvfb. Taste knobs for Colin: LENS_PARALLAX_GAIN (2.2), shadow factor (0.85),
reticle weight. Device verdict pending.
- [x] BB-1d ALL OPTICS (Colin): extend the BB-1c lens treatment beyond the ACOG. The
      red dot (reflex) sights get the same in-glass picture + parallax, but WITHOUT
      the zoom (lens camera = main camera fov exactly, 1.0x extra) — just parallax.
- [x] BB-9 GRAPHICS PUSH (Colin): add ALL of it — real cascaded shadows with blocks
      casting, per-map colour grading + LUT, glow, grit (triplanar grunge + AO),
      decals, MSAA — behind a graphics quality tier (phones keep Low). THEN measure
      FPS and REMOVE any major change that causes a major FPS drop. Colin's target:
      60 fps, floor 30 fps.

BB-1d done: lens rig generalised per family (weapon_base.gd). Reflex (ar7/smg9):
extra zoom pinned 1.0 — the shader shows the lens camera's angular crop so the
picture registers 1:1 with the world around the housing (NOT a squeezed full
frame); dot-only reticle, rounded-rect aperture, shadow 0.45 (open housing),
viewport 1024 (the window shows a ~5% centre crop). Measured: magnification
1.00x both guns, swim -4.0 px, dot centroid identical centred vs offset.
Shader renamed acog_lens -> optic_lens (uid preserved); ACOG behaviour
unchanged (layer D passes as before). verify_ads_alignment 149/0 headless,
244/0 xvfb. If Colin wants the ACOG-style full-frame picture in the red dot
instead of the registered crop: one-line sample_rect change in _tick_lens_pip.

BB-9 implemented (ws-gfx): GfxSettings resolver (cmdline > Preferences > tier);
Low = today's look (default), High = all on; Settings > DISPLAY gains GRAPHICS
LOW/HIGH. Shadows: PSSM 4 splits @ 250 m (blocks already cast; the OFF helper was
the apron). Grading: real per-map 32^3 LUTs built at runtime via _set_images
(ImageTexture3D.create upload path is broken in this engine build). Glow:
threshold 1.15, levels 0-2, skies do not bloom. Grit+AO: voxel_grit.gdshader
(world-space noise, dirt creep, edge wear, contact band) on main block
MultiMeshes. Decals: base-builder scatter (Cinder x18, Factory x12). MSAA 4x at
High. verify_skies contract now tier-aware (Low + High runs pass).
llvmpipe-relative frame costs: msaa +143..299% (software-inflated), glow
+38..67%, shadows +33..47%, grading +10..15%, grit/ao/decals ~0. DECK bench +
Colin's cut rule (60 target / 30 floor) still to run.

BB-9 Deck bench DONE (27 runs, 1280x800, bench window resized on the Deck copy):
ALL configs — baseline AND all-on — measured avg 60.0 fps with p1 lows 42-45 on
cinder_city, dustline, zombies_flat. The desktop compositor caps presentation at
the panel's 60 Hz, so per-feature attribution above the cap is not measurable
this way; the decision-relevant fact is that all-on holds 60 avg / >=42 lows
everywhere, so under Colin's rule (60 target, 30 floor) NOTHING is cut — MSAA
included (the llvmpipe +143-299% was a software-renderer artifact; the Deck's
tile GPU absorbs it). Caveat: bench is a camera sweep, not live combat; Colin's
device verdict at High is the final word.
