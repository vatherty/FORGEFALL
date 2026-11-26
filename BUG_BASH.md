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
