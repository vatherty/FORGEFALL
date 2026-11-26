# Skybox sources — real photographic skies (CC0)

Every sky in this folder is a real photograph from **Poly Haven**
(polyhaven.com), downloaded 2026-11-26 via the public API
(api.polyhaven.com) at 2k HDR and converted to a game-ready equirect
JPG (see "Conversion" below). Colin's direction: "an actual skybox
that's copyright free."

## License — CC0 (public domain)

All Poly Haven assets are CC0. From https://polyhaven.com/license
(verified 2026-11-26):

> "Our assets are all licensed as CC0, which is effectively Public
> Domain even in jurisdictions that do not support the Public Domain."
>
> "You can use our assets for any purpose, including commercial work.
> You do not need to give credit or attribution when using them
> (although it is appreciated). You can redistribute them, share them
> around, include them when sharing your own work, or even in a product
> you sell."

Attribution below is given anyway, because it's appreciated and free.

## The skies

| File | Map | Poly Haven asset | Author(s) |
|---|---|---|---|
| `dustline_sky.jpg` | Dustline | [Belfast Sunset (Pure Sky)](https://polyhaven.com/a/belfast_sunset_puresky) | Greg Zaal, Dimitrios Savva, Jarod Guest |
| `cinder_city_sky.jpg` | Cinder City | [Industrial Sunset (Pure Sky)](https://polyhaven.com/a/industrial_sunset_puresky) | Sergej Majboroda (Original), Jarod Guest (Sky Edits) |
| `factory_sky.jpg` | Factory | [Kloofendal Overcast (Pure Sky)](https://polyhaven.com/a/kloofendal_overcast_puresky) | Greg Zaal |
| `foundry_sky.jpg` | Foundry | [Qwantani Sunset (Pure Sky)](https://polyhaven.com/a/qwantani_sunset_puresky) | Greg Zaal, Jarod Guest |
| `outpost_sky.jpg` | Outpost | [Kloofendal 43d Clear (Pure Sky)](https://polyhaven.com/a/kloofendal_43d_clear_puresky) | Greg Zaal |
| `tower_defense_sky.jpg` | Tower Defense | [Citrus Orchard (Pure Sky)](https://polyhaven.com/a/citrus_orchard_puresky) | Dimitrios Savva, Jarod Guest |
| `zombies_flat_sky.jpg` | Zombies Flat | [Rogland Clear Night](https://polyhaven.com/a/rogland_clear_night) | Greg Zaal |

Asset pages: `https://polyhaven.com/a/<asset_id>`; files were fetched
from `https://api.polyhaven.com/files/<asset_id>` (`hdri → 2k → hdr`).

## Selection notes (swaps vs the first-pass picks)

- **Cinder City — ROUND 2 SWAP (BB-6b, 2026-11-26):** *Camdeboo Road*
  (the round-1 pick, see below) was replaced after Colin's on-device
  verdict: its horizon is a **mountain range** — wrong for a city, and
  the game's own building ring already provides the silhouettes. The
  replacement is *Industrial Sunset (Pure Sky)*: a true sky-only
  capture (zero terrain at the horizon), low sun (az 37.5° / el 4.2°)
  glowing gold through a grey industrial cloud deck. The full warm
  catalog was swept for this slot (19 candidates, previews + a
  terrain-height metric): every more-saturated dusk — *Plains Sunset*,
  *Magalies Field*, *Farm Sunset*, *Safari Sunset*, *Twilight Sunset*,
  *Sunset JHB Central*, *Golden Bay* — carries terrain or buildings at
  the horizon (the Camdeboo problem again), and the other Pure Sky
  dusks (*Qwantani Dusk 1/2*, *Rosendal Park Sunset*, *Kloppenheim 06*,
  *Wasteland Clouds*) are paler/bluer than Industrial Sunset. Its
  exposure (×1.11) was solved to match the previous Cinder bake's
  upper-half median (0.7103) so in-game brightness is unchanged; the
  fog colour was re-sampled from the new JPG (linear 0.407, 0.447,
  0.493 — cooler than Camdeboo's, honestly matching the new horizon).
- **Cinder City (round 1)** was first assigned *Aarfontein Dusk* —
  rejected after download: despite the name it is a grey **overcast**
  capture over scrubland (its own catalog categories say "overcast"),
  with detailed terrain below the horizon. *Camdeboo Road* (golden-hour
  sun over dark ridge silhouettes) gave Cinder the deep warm burn it
  needed — until the ridges themselves became the problem (see above).
- **Tower Defense** was first assigned *Evening Road 01* /
  *Cedar Bridge Sunset 1*. Cedar Bridge was rejected outright (the
  capture viewpoint stands on a bridge deck over a highway — unusable
  as a sky). Evening Road reads as bright afternoon blue; *Citrus
  Orchard*'s heavy cloud deck with a warm dusk glow under it is the
  richer dusk, so it took the slot.
- **Zombies** compared *Rogland Clear Night* (dense stars + Milky Way
  arc) against *Clarens Night 01*, which is so bright it renders as
  full daylight. Rogland won outright.
- **Factory** compared *Kloofendal Overcast* against *Kloppenheim 01*
  (misty, washed pale). Kloofendal is the true flat-grey overcast.
- **Foundry** compared *Dikhololo Sunset* (pale, sun already gone)
  against *Camdeboo Road* and *Qwantani Sunset*: Qwantani's low warm
  sun band over a darker sky is the molten-horizon pick; Camdeboo went
  to Cinder City.

## Conversion (HDR → game JPG)

Raw 2k `.hdr` files (2048×1024, float) were processed with Python
(OpenCV + NumPy + Pillow), identically for every sky:

1. **Sun estimation (before tonemapping):** brightest-region centroid
   of the linear HDR above the horizon → sun azimuth/elevation in
   equirect space. Each map's `DirectionalLight3D` is aimed from these
   (Godot panorama mapping measured empirically: world azimuth
   φ = −az_image; light `rotation_degrees = (−el, −az, 0)`, with
   elevation clamped to ≥ 12° on the low-sun maps so 90 m ortho
   shadows stay readable). Estimates: Dustline az 39.8° / el 2.4°;
   Cinder City az 37.5° / el 4.2° (round 2, Industrial Sunset; the
   round-1 Camdeboo estimate was az 36.0° / el 2.6°); Factory (diffuse bright patch)
   az 33.4° / el 22.8°; Foundry az 35.9° / el 6.2°; Outpost az 36.1° /
   el 43.0°; Tower Defense (glow through cloud deck) az 72.8° /
   el 14.3°; Zombies — no moon visible; light aimed at the brightest
   region (Milky Way core) az −11.2° / el 33.9° as a moon stand-in.
2. **Tonemap:** Reinhard (`x/(1+x)`) with a per-sky exposure, then
   sRGB encode. (An ACES bake was tried first and rejected: the engine
   applies its own ACES tonemapping on top, and the double curve
   washed the skies to pale grey. Reinhard preserves saturation
   through the engine's pass.) Exposures were solved per sky so the
   upper-half median lands at a natural level for the mood — day/dusk
   skies matched to a common reference median; Zombies deliberately
   much darker (median sRGB 0.16) so it reads as night while the
   stars, which are 10–100× brighter than the sky background, stay
   visible; Outpost pulled down ~6× from its first bake, which
   clipped to white in-engine. Final exposures: Dustline ×1.15,
   Cinder City ×1.11 (round 2, solved against the round-1 bake's
   upper-half median 0.7103; round 1 was ×4.76), Factory ×1.29,
   Foundry ×1.74, Outpost ×0.64,
   Tower Defense ×1.15, Zombies ×0.06.
3. **Below-horizon fade (Zombies only since round 2):** Zombies is a
   location capture with real terrain below the horizon; rows below
   v = 0.515 are progressively darkened (to ~12% by v = 0.70) so the
   photo terrain becomes a dark ground falloff instead of detailed
   scenery floating behind the arena. Round-1 Cinder (Camdeboo Road)
   got the same fade; round-2 Cinder is a Pure Sky capture with a
   smooth synthetic lower half and needs none. The other Pure Sky
   captures are likewise untouched below the horizon.
4. **Encode:** JPEG quality 85 at native 2048×1024. Final sizes:
   61–118 KB per sky, **547 KB total** for all seven (vs 4–7 MB each
   as raw HDR). Fog colours in `SKY_PROFILES` were sampled from these
   finished JPGs: trimmed mean (brightest 10% excluded) of the horizon
   band (v 0.46–0.498), converted sRGB → linear.
