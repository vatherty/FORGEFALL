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
