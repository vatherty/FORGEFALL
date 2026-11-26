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
| `cinder_city_sky.jpg` | Cinder City | [Camdeboo Road](https://polyhaven.com/a/camdeboo_road) | Dario Barresi, Jarod Guest |
| `factory_sky.jpg` | Factory | [Kloofendal Overcast (Pure Sky)](https://polyhaven.com/a/kloofendal_overcast_puresky) | Greg Zaal |
| `foundry_sky.jpg` | Foundry | [Qwantani Sunset (Pure Sky)](https://polyhaven.com/a/qwantani_sunset_puresky) | Greg Zaal, Jarod Guest |
| `outpost_sky.jpg` | Outpost | [Kloofendal 43d Clear (Pure Sky)](https://polyhaven.com/a/kloofendal_43d_clear_puresky) | Greg Zaal |
| `tower_defense_sky.jpg` | Tower Defense | [Citrus Orchard (Pure Sky)](https://polyhaven.com/a/citrus_orchard_puresky) | Dimitrios Savva, Jarod Guest |
| `zombies_flat_sky.jpg` | Zombies Flat | [Rogland Clear Night](https://polyhaven.com/a/rogland_clear_night) | Greg Zaal |

Asset pages: `https://polyhaven.com/a/<asset_id>`; files were fetched
from `https://api.polyhaven.com/files/<asset_id>` (`hdri → 2k → hdr`).

## Selection notes (swaps vs the first-pass picks)

- **Cinder City** was first assigned *Aarfontein Dusk* — rejected after
  download: despite the name it is a grey **overcast** capture over
  scrubland (its own catalog categories say "overcast"), with detailed
  terrain below the horizon. *Camdeboo Road* (golden-hour sun over dark
  ridge silhouettes) gives Cinder the deep warm burn it needed.
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
   Cinder City az 36.0° / el 2.6°; Factory (diffuse bright patch)
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
   Cinder City ×4.76, Factory ×1.29, Foundry ×1.74, Outpost ×0.64,
   Tower Defense ×1.15, Zombies ×0.06.
3. **Below-horizon fade (Cinder City + Zombies only):** these two are
   location captures with real terrain below the horizon; rows below
   v = 0.515 are progressively darkened (to ~12% by v = 0.70) so the
   photo terrain becomes a dark ground falloff instead of detailed
   scenery floating behind the arena. The five Pure Sky captures
   already have smooth synthetic lower halves and are untouched.
4. **Encode:** JPEG quality 85 at native 2048×1024. Final sizes:
   60–204 KB per sky, **681 KB total** for all seven (vs 4–7 MB each
   as raw HDR). Fog colours in `SKY_PROFILES` were sampled from these
   finished JPGs: trimmed mean (brightest 10% excluded) of the horizon
   band (v 0.46–0.498), converted sRGB → linear.
