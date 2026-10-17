# FORGEFALL Gameplay Rework — Colin's brief (2026-10-16)

Source: Colin's message 2026-10-16 ~19:51 MDT. His words first,
synthesis second. Nothing here is built yet — this is the design
record for the rework. Status: awaiting Colin's answers on the open
questions at the bottom before build starts.

## 1. Movement — "wall run, grapple, slide and jump. They all feel off."

### Wall run — still doesn't work. Root cause per Colin: not enough rules.
New attach rules (Colin's spec, verbatim intent):
- Attach ONLY if the player has enough speed (full walking speed).
- Attach ONLY if the player is aimed at the wall OR parallel to it.
- On attach, add a small speed boost (~50 units).
- No more attaching at weird times.

### Jump — wall jump feels like a little hop.
- When the player HOLDS jump, there should be a higher jump
  (variable jump height: tap = small hop, hold = full jump).
- Open: is this wall-jump only, or jump in general? Read as
  wall-jump in context — confirm with Colin.

### Slide — fine, but height is wrong.
- Slide needs to be lower to the ground, OR the player needs to
  be higher. (Camera/height mismatch during slide — tune + verify
  on device.)

### Grapple — starting to feel right. Maps are the problem.
- Maps are very small and short. No buildings to swing from.
- Fix: a few maps based off cities — urban maps with buildings
  tall/dense enough to grapple and swing through.

## 2. Structure — start menu + modes

Today the game deploys straight into a game. Replace with a start
menu: **Single Player** and **Multiplayer**.

### Single Player — 3 modes

1. **Tower Defense**
   - Specifically made maps, tailored for TD, so the flow is better
     (lanes/paths, build spots, enemy flow designed for the mode —
     not the current one-loop-fits-all maps).

2. **TDM (bots)**
   - Bots show up; player chooses or makes a loadout beforehand.

3. **Zombies (CoD-style, Forgefall-flavored)**
   - Like Call of Duty Zombies: buy doors, perk machines, Pack-a-Punch.
   - Starting gun: a custom-made weapon that doesn't do much damage.
   - Perks: randomly generated beforehand, doing random things.
     ALWAYS a health perk.
   - Pack-a-Punch: adds an element + a punchier damage buff.
   - Re-Pack (pack again): adds a chain effect, OR a sight, OR an
     attachment.
   - Colin offered to supply more zombies-mode info — see open
     questions. Defaults to propose if he doesn't specify:
     CoD-style points economy (points per hit/kill, doors cost
     points, perks cost points, PAP costs points).

### Multiplayer
- Same modes, with multiplayer elements.
- Read: TD co-op, Zombies co-op, TDM PvP (+ bots to fill).
  Confirm with Colin.

## 3. Enemies — "extremely bad. And no animations."

- AI behaviour needs a real pass (currently: enemies just run at
  the player — confirm specifics with Colin).
- No animations at all. Feasible path: procedural/code-driven
  animation (limb swing, attack wind-up, hit reactions, death)
  on the existing enemy models — no authored rigs needed.
- Open: what does "extremely bad" cover — behaviour, variety,
  or both? Which enemy types matter most?

## Proposed build order (for Colin to confirm)

1. Movement rules (wall-run attach conditions + boost, hold-jump,
   slide height) — foundation everything else sits on.
2. City map(s) — grapple/wall-run need real vertical urban space.
3. Start menu + mode select shell.
4. Modes: bot TDM + loadouts → TD tailored maps → Zombies.
5. Enemies: AI + procedural animations (parallel-izable once the
   movement/mode work lands).
6. Multiplayer versions of the modes (co-op TD/Zombies, PvP TDM).

## Open questions for Colin

1. Build order above OK, or different (e.g. enemies first)?
2. Wall-jump hold-to-jump-higher: wall-jump only, or all jumps?
3. Zombies: currency model (CoD-style points?), how many doors /
   perk machines on the first map, PAP + re-PAP costs, one zombies
   map to start or more? What are the perk pool / element pool?
4. Enemies: behaviour, variety, or both? Procedural animation OK?
5. Multiplayer read (TD co-op, Zombies co-op, TDM PvP + bots) right?

## Answers + locked spec (Colin, 2026-10-16 ~20:00 MDT)

1. **Order:** confirmed as proposed, sequencing delegated to Sparky.
2. **Wall-jump:** (still open — assumed wall-jump only unless Colin
   says otherwise).
3. **Zombies — map:** first map is Town-like: same flow/structure
   and same prices as BO2's Town. IP call: same flow + price
   balance, but Forgefall's own names/art — NOT a 1:1 clone of
   Activision's map (no copied names, signage, or assets). Keeps it
   shippable. Same layout principles: small town, central street,
   key buildings, two box spots, PAP in a central exposed spot.
4. **Zombies — Forge:** NO Forge mode in Zombies. Mods are
   pre-added from the main menu only. Forge building exists ONLY
   in Tower Defense. TDM also has no in-game building.
   - "Buildings" reading (confirm pending): "buildings" = Forge-
     built structures. City maps still get map-geometry buildings
     to swing from; only in-game building is TD-only.
5. **Zombies — randomness:** perks are random (machines' contents
   randomized per run; ALWAYS a health perk somewhere). Wall buys
   are random (each chalk spot gets a random weapon per run).
   Mystery Box pulls from EVERYTHING, including added weapon mods
   (box pool = all weapons + all installed weapon mods).
6. **Enemies:** full redo — behaviour AND model AND animations.
   Procedural/code-driven animation assumed OK.

## BO2 price reference (verified from public wikis/guides,
2026-10-16 — balance reference, not copied content)

Points: hit 10; lethal torso 60; lethal limb 50; lethal explosive
50; lethal neck 70; lethal headshot 100; lethal melee 130;
barrier board 10 (rebuild cap 40 → 490 by round); revive 5% of
downed player's points; Carpenter 200; Nuke 400.
Mystery Box: 950, random weapon, moves on teddy bear.
Pack-a-Punch: 5000 first; 2000 re-PAP (attachment change in BO2).
Wall buys (examples): M14 500 (ammo 250), Olympia 500, B23R 900,
MP5 1000.
Perks: Quick Revive 500 solo / 1500 co-op; JuggerNog 2500
(health 100→250); Speed Cola 3000 (reload +50%); Double Tap
2000 (fire rate +33%); Stamin-Up 2000; Mule Kick 4000 (3rd
weapon); Tombstone 2000; Who's Who 2000; Deadshot 1500;
PhD Flopper 2000; Electric Cherry 2000; Vulture Aid 3000.
Forgefall perks are RANDOM per run (own pool, own effects),
always including a health perk — BO2 prices are the balance
reference for costs.
Town flow reference (structure only): no power needed; box
spawns in 2 spots; PAP in central exposed spot; perk machines
spread across the map (JuggerNog + MP5 NE house, Speed Cola in
Bank, Quick Revive in Bar, Stamin-Up south, etc.).

## Traversal tools (Colin, 2026-10-16 ~20:04 MDT)

- **Zombies:** NO grapple hook, NO portal gun — UNLESS enabled by
  a toggle in the menu (opt-in toggle adds them to Zombies).
  Jetpack in Zombies: same toggle covers it too (Colin 20:05) —
  one menu toggle enables all three traversal tools in Zombies;
  default OFF for all three.
- **TDM + Tower Defense:** player CHOOSES one traversal tool
  (loadout / pre-run choice, exactly one):
  1. Grapple Hook
  2. Jetpack (NEW key item — design + build: fuel-based thrust,
     tunable; Colin QA)
  3. Portal Gun
- The choice is part of the loadout (TDM) / pre-run setup (TD).

## Round 2 — Colin's v0.6.0 playtest verdict (2026-10-16 ~22:11 MDT)

Colin played v0.6.0 on Steam Deck (WASD emulation):

1. **The (Zombies Town-like) map sucks. Needs actual sustenance.**
   Fix: remake BO2's Town faithfully — same layout/flow, same
   streets/buildings/beats — with Forgefall's own voxel art and
   names, framed as parody/homage. "Sustenance" = enterable
   interiors (bank, bar, gun store, etc.), props, clutter, street
   detail, lighting/atmosphere, more to explore and do — not a
   flat empty lot with buy spots. No copied Activision assets,
   textures, signage text, or trademarked names.
   CLARIFIED by Colin 22:13: remake in voxel, NO BO2 assets
   whatsoever, ENOUGH CHANGED to be covered, keep the reliable
   flow. I.e. Town-inspired, not 1:1: same flow principles (small
   town, central street, key buildings, box/PAP/perk spread) but
   the layout itself changed enough to be a distinct map.
   CLARIFIED AGAIN by Colin 22:13: 1:1 LAYOUT, different items and
   different objects. Final spec: the spatial layout matches
   Town (streets, building footprints, placements, flow), but
   the items/objects/dressing are all different, voxel art, zero
   BO2 assets.
2. **Can't buy anything on Deck WASD emulation.** Fix: NATIVE
   CONTROLLER SUPPORT WITH REMAPPING. Godot joypad / SDL mappings,
   Deck built-in gamepad + Xbox/PS controllers, all actions
   rebindable (keyboard + gamepad), remapping UI in Options,
   interact/buy on a controller button. First verify buy/interact
   works with keyboard (rule out a separate interact bug), then
   add controller.
3. Cinder City untouched unless Colin says otherwise.

## Art suggestion (Colin, 2026-10-16 ~22:16 MDT)

Kenney Blocky Characters (https://kenney.nl/assets/blocky-characters)
for the player + enemies. Verified: CC0 license (public domain,
free incl. commercial, no attribution), 3D, includes animations,
20 files, v2.0 remade. Evaluate + adopt if formats (need
Godot-friendly GLB/FBX/OBJ) and style fit — beats the procedural
voxel models if the rigs/animations hold up. If not fitting this
round, report as follow-up.

## Art suggestion 2 (Colin, 2026-10-16 ~22:18 MDT)

Kenney Brick Kit (https://kenney.nl/assets/brick-kit) for one of
the maps — Lego-looking bricks fit the voxel style. Verified:
CC0 (public domain, free incl. commercial), 3D, 290 files,
v1.0 (2024). Evaluate: best fit is the Town remake (brick
buildings + props/dressing) or the TD map. Adopt where it fits;
report if it doesn't.

## Factory map (Colin, 2026-10-16 ~22:18 MDT)

Kenney Factory Kit (https://kenney.nl/assets/factory-kit) — USE
for a factory-style map. v3.0 remade. License: Kenney packs are
CC0 site-wide (confirmed on the Blocky Characters + Brick Kit
pages); coordinator to confirm in-pack before use. Map serves the
rotation (TDM/TD — coordinator picks); Zombies keeps Town.

## Tall city map kit (Colin, 2026-10-16 ~22:19 MDT)

Kenney City Kit (Commercial)
(https://kenney.nl/assets/city-kit-commercial) — USE for the
tall city map (Cinder City). Verified: CC0, 3D, 50 files,
skyscraper/building variations, v2.1. Rebuild/upgrade Cinder
City's buildings with the kit; KEEP the verified layout metrics
(grapple coverage 104/104, wall-run faces, chainable medians).
