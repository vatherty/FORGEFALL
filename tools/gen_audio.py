#!/usr/bin/env python3
"""
FORGEFALL procedural audio synthesizer — Worker 7 (audio).

Synthesizes every SFX for FORGEFALL (voxel FPS, MW2-style audio language)
with Python stdlib ONLY (wave, struct, math, random). No numpy, no assets.

Output: 16-bit mono WAV @ 44100 Hz into ../assets/audio/
Loops are generated seamless via tail/head crossfade; loop metadata
(loop_mode/loop_begin/loop_end) is applied at runtime by the Sfx autoload.

Run:  python3 tools/gen_audio.py   (from the forgefall project root)
"""

import math
import os
import random
import struct
import wave

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------

SR = 44100  # sample rate, Hz

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "assets", "audio"))

# ----------------------------------------------------------------------------
# Synthesis helpers
# ----------------------------------------------------------------------------

def _n(dur_s):
    """Sample count for a duration in seconds."""
    return max(1, int(dur_s * SR))


def white(dur_s, seed=1):
    """White noise buffer, -1..1."""
    rng = random.Random(seed)
    n = _n(dur_s)
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def tone(f0, f1, dur_s, wave="sine", phase=0.0):
    """Oscillator with linear freq sweep. wave: sine | square | saw."""
    n = _n(dur_s)
    out = [0.0] * n
    ph = phase
    for i in range(n):
        k = i / (n - 1) if n > 1 else 0.0
        f = f0 + (f1 - f0) * k
        ph += 2.0 * math.pi * f / SR
        s = math.sin(ph)
        if wave == "sine":
            out[i] = s
        elif wave == "square":
            out[i] = 1.0 if s >= 0.0 else -1.0
        else:  # saw
            out[i] = 2.0 * ((ph / (2.0 * math.pi)) % 1.0) - 1.0
    return out


def exp_decay(n, tau_s, delay_s=0.0):
    """Exponential decay envelope, tau in seconds, optional delay."""
    d = int(delay_s * SR)
    inv = 1.0 / (tau_s * SR)
    return [math.exp(-max(0.0, i - d) * inv) if i >= d else 0.0 for i in range(n)]


def attack(n, attack_s):
    """Linear attack ramp envelope 0..1."""
    a = max(1, int(attack_s * SR))
    env = [1.0] * n
    for i in range(min(a, n)):
        env[i] = i / a
    return env


def amod(x, env):
    """Amplitude-modulate signal by envelope."""
    return [v * e for v, e in zip(x, env)]


def lowpass(x, cutoff_hz):
    """One-pole lowpass."""
    a = 1.0 - math.exp(-2.0 * math.pi * cutoff_hz / SR)
    y = 0.0
    out = [0.0] * len(x)
    for i, v in enumerate(x):
        y += a * (v - y)
        out[i] = y
    return out


def highpass(x, cutoff_hz):
    """One-pole highpass (via lowpass subtraction)."""
    lp = lowpass(x, cutoff_hz)
    return [v - l for v, l in zip(x, lp)]


def place(dst, src, at_s, gain=1.0):
    """Mix src into dst at time offset (seconds)."""
    o = int(at_s * SR)
    for i, v in enumerate(src):
        j = o + i
        if 0 <= j < len(dst):
            dst[j] += v * gain
    return dst


def add(a, b):
    """Sum two equal-length buffers."""
    return [x + y for x, y in zip(a, b)]


def normalize(x, peak=0.9):
    """Peak-normalize to target peak amplitude."""
    m = max(max(x), -min(x), 1e-9)
    s = peak / m
    return [v * s for v in x]


def tanh_clip(x, drive=1.5):
    """Soft saturation for grit/punch."""
    return [math.tanh(v * drive) for v in x]


def fade_edges(x, in_s=0.005, out_s=0.01):
    """Short fades to kill clicks at file boundaries."""
    n = len(x)
    fi = max(1, int(in_s * SR))
    fo = max(1, int(out_s * SR))
    out = list(x)
    for i in range(min(fi, n)):
        out[i] *= i / fi
    for i in range(min(fo, n)):
        out[n - 1 - i] *= i / fo
    return out


def make_loop(x, fade_s=0.25):
    """Crossfade tail into head so the buffer loops seamlessly."""
    f = max(2, int(fade_s * SR))
    n = len(x)
    out = x[: n - f]
    for i in range(f):
        k = i / f
        out[i] = x[i] * k + x[n - f + i] * (1.0 - k)
    return out


def write_wav(name, x):
    """Clamp, convert to 16-bit mono, write WAV, print result."""
    x = [max(-1.0, min(1.0, v)) for v in x]
    data = struct.pack("<%dh" % len(x), *[int(v * 32767) for v in x])
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)
    print("wrote %-22s %7d samples  %7.1f KB" % (name + ".wav", len(x), len(data) / 1024.0))


# ----------------------------------------------------------------------------
# Shared recipes
# ----------------------------------------------------------------------------

def gunshot(dur, crack_gain, crack_cut, thump_f0, thump_f1, body_gain,
            body_cut, seed, tail=0.22):
    """MW2-style gunshot: sharp noise crack + low thump + noise body."""
    n = _n(dur)
    x = [0.0] * n
    # Crack: very short highpassed noise transient.
    c = white(0.014, seed)
    c = amod(c, exp_decay(len(c), 0.004))
    c = highpass(c, crack_cut)
    place(x, c, 0.0, crack_gain)
    # Thump: sine dropping through the low end.
    t = tone(thump_f0, thump_f1, dur, "sine")
    t = amod(t, exp_decay(len(t), dur * tail))
    place(x, t, 0.0, 0.95)
    # Body: lowpassed noise wash.
    b = white(dur, seed + 7)
    b = lowpass(b, body_cut)
    b = amod(b, exp_decay(len(b), dur * tail * 0.8))
    place(x, b, 0.0, body_gain)
    return fade_edges(normalize(tanh_clip(x, 1.25), 0.95))


def gunshot_v2(dur, crack_gain, crack_cut, thump_f0, thump_f1, thump_tau,
               body_gain, body_cut, mech_freq, seed, slap=None, peak=0.95):
    """Goal 2 (SOUND): richer gunshot — crack + low thump + noise body +
    bolt/slide mech tick + optional early-reflection slap(s).
    slap: list of (delay_s, gain, lowpass_cutoff)."""
    n = _n(dur)
    x = [0.0] * n
    # Crack: very short highpassed noise transient.
    c = white(0.014, seed)
    c = amod(c, exp_decay(len(c), 0.004))
    c = highpass(c, crack_cut)
    place(x, c, 0.0, crack_gain)
    # Thump: sine dropping through the low end.
    t = tone(thump_f0, thump_f1, dur, "sine")
    t = amod(t, exp_decay(len(t), thump_tau))
    place(x, t, 0.0, 0.95)
    # Body: lowpassed noise wash.
    b = white(dur, seed + 7)
    b = lowpass(b, body_cut)
    b = amod(b, exp_decay(len(b), thump_tau * 0.8))
    place(x, b, 0.0, body_gain)
    # Mech: bolt/slide metallic tick just after the crack.
    m = click(0.05, mech_freq, seed=seed + 3, body_f=mech_freq * 0.25)
    place(x, m, 0.008, 0.35)
    # Early reflections: distant slap(s) give the shot space.
    if slap:
        for delay, gain, cut in slap:
            s = white(0.20, seed + 11)
            s = lowpass(s, cut)
            s = amod(s, exp_decay(len(s), 0.07))
            place(x, s, delay, gain)
    return fade_edges(normalize(tanh_clip(x, 1.25), peak))


def energy_zap(dur=0.35, seed=21):
    """Goal 2: Raptor physics-gun zap — pure energy, NO powder crack
    (that is what makes it distinct from every gunshot + the turret).
    Rising saw whine + zap crackle + sub punch + descending discharge tail."""
    n = _n(dur)
    x = [0.0] * n
    w = tone(280, 2600, dur * 0.7, "saw")
    w = lowpass(w, 3200.0)
    w = amod(w, amod(attack(len(w), 0.02), exp_decay(len(w), 0.12)))
    place(x, w, 0.0, 0.55)
    z = white(0.09, seed)
    z = highpass(z, 3000.0)
    z = amod(z, exp_decay(len(z), 0.02))
    place(x, z, 0.02, 0.9)
    t = tone(150, 50, dur, "sine")
    t = amod(t, exp_decay(len(t), 0.08))
    place(x, t, 0.0, 0.7)
    d = tone(2400, 300, dur * 0.6, "sine")
    d = amod(d, exp_decay(len(d), 0.10))
    place(x, d, dur * 0.35, 0.30)
    return fade_edges(normalize(tanh_clip(x, 1.3), 0.92))


def reload_seq(clicks, dur, seed, bed_gain=0.10, rattle=False):
    """Goal 2: staged reload sequence — one file played ONCE at reload
    start (weapon_base), clicks placed at that weapon's stage boundaries
    (Arsenal reload_stages, used here as timing reference only).
    clicks: [(time_s, freq, body_f, gain)]."""
    n = _n(dur)
    x = [0.0] * n
    bed = white(dur, seed)
    bed = lowpass(bed, 500.0)
    bed = amod(bed, [bed_gain + 0.05 * math.sin(2 * math.pi * 1.5 * i / SR)
                     for i in range(len(bed))])
    place(x, bed, 0.0, 0.5)
    for i, (at, freq, body_f, gain) in enumerate(clicks):
        place(x, click(0.08, freq, seed=seed + 10 + i, body_f=body_f), at, gain)
    if rattle:
        # Belt/link rattle: sparse tiny ticks across the sequence.
        rng = random.Random(seed + 99)
        t = 0.15
        while t < dur - 0.15:
            place(x, click(0.03, 3200.0, seed=int(t * 1000) + seed, body_f=900.0), t, 0.25)
            t += rng.uniform(0.12, 0.30)
    return fade_edges(normalize(x, 0.92))


def explosion_v2(dur, sub_f0, sub_f1, sub_tau, wash_cut, wash_tau, crack_gain,
                 seed, second=None, peak=0.95):
    """Goal 2: layered explosion — sub sine (real low-end punch) + noise
    wash + initial crack + slow rumble LFO + optional delayed secondary
    boom (second = (delay_s, gain))."""
    n = _n(dur)
    x = [0.0] * n
    sub = tone(sub_f0, sub_f1, dur, "sine")
    sub = amod(sub, exp_decay(len(sub), sub_tau))
    place(x, sub, 0.0, 1.0)
    wash = white(dur, seed)
    wash = lowpass(wash, wash_cut)
    wash = amod(wash, amod(attack(len(wash), 0.01), exp_decay(len(wash), wash_tau)))
    place(x, wash, 0.0, 0.85)
    crack = white(0.03, seed + 1)
    crack = highpass(crack, 500.0)
    place(x, crack, 0.0, crack_gain)
    rumble = [0.8 + 0.2 * math.sin(2 * math.pi * 9.0 * i / SR) for i in range(n)]
    x = amod(x, rumble)
    if second:
        delay, gain = second
        s2 = tone(55, 30, dur - delay, "sine")
        s2 = amod(s2, exp_decay(len(s2), 0.35))
        place(x, s2, delay, gain)
        w2 = white(dur - delay, seed + 5)
        w2 = lowpass(w2, 300.0)
        w2 = amod(w2, exp_decay(len(w2), 0.3))
        place(x, w2, delay, gain * 0.7)
    return fade_edges(normalize(tanh_clip(x, 1.15), peak))


def click(dur=0.06, freq=2000.0, seed=1, body_f=300.0):
    """Mechanical click: filtered noise snap + small sine ping."""
    n = _n(dur)
    x = white(dur, seed)
    x = amod(x, exp_decay(n, 0.007))
    x = highpass(x, 900.0)
    p = tone(freq, freq * 0.7, dur, "sine")
    p = amod(p, exp_decay(n, 0.018))
    q = tone(body_f, body_f * 0.8, dur, "sine")
    q = amod(q, exp_decay(n, 0.03))
    out = [a * 0.55 + b * 0.3 + c * 0.35 for a, b, c in zip(x, p, q)]
    return fade_edges(normalize(out, 0.9))


def metallic_ding(freqs, dur, decay, seed=1):
    """Inharmonic partials = metallic ding."""
    n = _n(dur)
    x = [0.0] * n
    for i, f in enumerate(freqs):
        p = tone(f, f * 0.998, dur, "sine")
        p = amod(p, exp_decay(n, decay / (1.0 + i * 0.5)))
        place(x, p, 0.0, 1.0 / (1.0 + i * 0.6))
    s = white(0.01, seed)
    s = highpass(s, 4000.0)
    place(x, s, 0.0, 0.5)
    return fade_edges(normalize(x, 0.9))


def horn(dur, freqs, cutoff, drive, seed=3):
    """Brass-ish horn: stacked detuned saws through a lowpass."""
    n = _n(dur)
    x = [0.0] * n
    for f in freqs:
        s = tone(f, f * 1.003, dur, "saw", phase=random.Random(seed).random() * 6.28)
        place(x, s, 0.0, 1.0 / len(freqs))
    x = lowpass(x, cutoff)
    x = tanh_clip(x, drive)
    env = amod(attack(n, 0.08), exp_decay(n, dur * 0.55, delay_s=0.08))
    x = amod(x, env)
    return fade_edges(normalize(x, 0.92))


def note_seq(notes, note_dur, gap, wave="sine", cutoff=6000.0, decay_mul=1.0):
    """Sequence of (freq, gain) notes -> one buffer."""
    total = gap * (len(notes) - 1) + note_dur
    n = _n(total)
    x = [0.0] * n
    for i, (f, g) in enumerate(notes):
        t = tone(f, f, note_dur, wave)
        t = amod(t, exp_decay(len(t), note_dur * 0.6 * decay_mul))
        if wave == "square":
            t = lowpass(t, cutoff)
        place(x, t, i * gap, g)
    return fade_edges(normalize(x, 0.9))


# ----------------------------------------------------------------------------
# Sound definitions
# ----------------------------------------------------------------------------

def build_all():
    sounds = {}

    # --- Shots (Goal 2: each weapon distinct in weight/attack/decay) ----
    # AR: mid crack, tight thump, short room slap. The 0 dB reference.
    sounds["shot_ar"] = gunshot_v2(0.38, 1.00, 1600, 140, 42, 0.09,
                                   0.50, 950, 2100, seed=11,
                                   slap=[(0.09, 0.18, 1500)])
    # Sniper: heavy crack, deep slow thump, long tail + double echo.
    sounds["shot_sniper"] = gunshot_v2(1.05, 1.15, 1100, 90, 28, 0.30,
                                       0.50, 550, 1500, seed=12,
                                       slap=[(0.18, 0.30, 1200), (0.36, 0.15, 900)])
    # Shotgun: 4 staggered cracks = 8-pellet feel, wide slow boom.
    sg = [0.0] * _n(0.70)
    for i, at in enumerate([0.0, 0.012, 0.024, 0.036]):
        c = white(0.016, 20 + i)
        c = amod(c, exp_decay(len(c), 0.005))
        c = highpass(c, 900.0)
        place(sg, c, at, 0.9 - i * 0.12)
    t = tone(105, 30, 0.70, "sine")
    t = amod(t, exp_decay(len(t), 0.20))
    place(sg, t, 0.0, 1.0)
    b = white(0.70, 27)
    b = lowpass(b, 650.0)
    b = amod(b, exp_decay(len(b), 0.17))
    place(sg, b, 0.0, 0.75)
    place(sg, click(0.06, 1400.0, seed=23, body_f=300.0), 0.010, 0.4)  # pump mech
    sounds["shot_shotgun"] = fade_edges(normalize(tanh_clip(sg, 1.25), 0.95))

    # SMG: fast/light — bright crack, high short thump, quick decay.
    sounds["shot_smg"] = gunshot_v2(0.22, 0.65, 2400, 220, 80, 0.05,
                                    0.32, 1600, 2800, seed=13)
    # Pistol: snappy — bright crack, mid thump, short body.
    sounds["shot_pistol"] = gunshot_v2(0.30, 0.85, 1900, 170, 65, 0.07,
                                       0.40, 1300, 2400, seed=14)
    # LMG: sustained thump — low crack, deep body, longer sustain.
    sounds["shot_lmg"] = gunshot_v2(0.48, 0.95, 950, 100, 35, 0.16,
                                    0.75, 700, 1700, seed=15,
                                    slap=[(0.11, 0.20, 1000)])

    # Turret: electric zap-pop over a light gunshot (distinct from all
    # handheld shots: the zap leads, the crack is smaller).
    zt = tone(1100, 180, 0.18, "square")
    zt = lowpass(zt, 3500.0)
    zt = amod(zt, exp_decay(len(zt), 0.05))
    zc = gunshot_v2(0.32, 0.6, 1800, 160, 60, 0.07, 0.35, 1200, 2600, seed=16)
    place(zc, zt, 0.0, 0.7)
    sounds["shot_turret"] = fade_edges(normalize(zc, 0.92))

    # Raptor physics gun: pure energy zap, no powder crack.
    sounds["shot_raptor"] = energy_zap(0.35, seed=21)

    # Goal 3 CONTENT: BR-3 TRIDENT burst shot — crisper and brighter than
    # the AR (higher crack cutoff, shorter thump) so a 3-round burst reads
    # as a tight staccato, not an auto spray.
    sounds["shot_burst"] = gunshot_v2(0.30, 0.90, 2600, 180, 70, 0.06,
                                      0.38, 1500, 3000, seed=17)
    # Goal 3 CONTENT: HV-44 JUDGE revolver — the heaviest handheld shot:
    # deep slow thump, long tail, a late echo. Distinct from the sniper
    # (lower crack, fatter body) and the shotgun (single crack, no stack).
    sounds["shot_revolver"] = gunshot_v2(0.85, 1.10, 1300, 100, 30, 0.28,
                                         0.55, 650, 1600, seed=18,
                                         slap=[(0.15, 0.25, 1000)])

    # --- Impacts (Goal 2: bullet-impact sound by surface) ---------------
    ic = [0.0] * _n(0.14)
    icn = white(0.05, 120)
    icn = highpass(icn, 1200.0)
    icn = amod(icn, exp_decay(len(icn), 0.02))
    place(ic, icn, 0.0, 1.0)
    ict = tone(160, 70, 0.14, "sine")
    ict = amod(ict, exp_decay(len(ict), 0.05))
    place(ic, ict, 0.0, 0.8)
    icb = white(0.14, 121)
    icb = lowpass(icb, 900.0)
    icb = amod(icb, exp_decay(len(icb), 0.05))
    place(ic, icb, 0.0, 0.5)
    sounds["impact_concrete"] = fade_edges(normalize(ic, 0.85))
    sounds["impact_metal"] = metallic_ding([2800.0, 4100.0, 5900.0], 0.22, 0.10, seed=122)
    idirt_n = white(0.16, 123)
    idirt_n = lowpass(idirt_n, 600.0)
    idirt_n = amod(idirt_n, exp_decay(len(idirt_n), 0.06))
    idirt_t = tone(110, 55, 0.16, "sine")
    idirt_t = amod(idirt_t, exp_decay(len(idirt_t), 0.07))
    sounds["impact_dirt"] = fade_edges(normalize(add(idirt_n, amod(idirt_t, [0.7] * len(idirt_t))), 0.8))
    iflesh_t = tone(130, 55, 0.15, "sine")
    iflesh_t = amod(iflesh_t, exp_decay(len(iflesh_t), 0.06))
    iflesh_n = white(0.15, 124)
    iflesh_n = lowpass(iflesh_n, 900.0)
    iflesh_n = highpass(iflesh_n, 250.0)
    iflesh_n = amod(iflesh_n, exp_decay(len(iflesh_n), 0.05))
    sounds["impact_flesh"] = fade_edges(normalize(add(amod(iflesh_t, [0.9] * len(iflesh_t)), amod(iflesh_n, [0.6] * len(iflesh_n))), 0.85))

    # Cover fracture: voxel crumble — noise crash + staggered chunk clicks
    # + low thud. (destructible_cover already plays "cover_break".)
    cb = [0.0] * _n(0.55)
    crash = white(0.30, 95)
    crash = lowpass(crash, 1800.0)
    crash = amod(crash, exp_decay(len(crash), 0.10))
    place(cb, crash, 0.0, 0.9)
    for i, at in enumerate([0.02, 0.07, 0.13, 0.20]):
        place(cb, click(0.05, 1500.0 - i * 250.0, seed=96 + i, body_f=350.0), at, 0.7)
    cthud = tone(90, 40, 0.40, "sine")
    cthud = amod(cthud, exp_decay(len(cthud), 0.12))
    place(cb, cthud, 0.0, 0.8)
    sounds["cover_break"] = fade_edges(normalize(cb, 0.92))

    # --- Reload / handling (Goal 2) -------------------------------------
    # One file per reload, played ONCE at reload start (weapon_base).
    # Clicks sit at the weapon's stage boundaries (Arsenal reload_stages
    # as timing reference): mag-out | mag-in | chamber.
    # AR [0.45, 0.85, 0.35] = 1.65 s. SMG/pistol reuse this file pitched
    # up in weapon_base (shorter reloads) — no extra WAVs needed.
    sounds["reload_ar"] = reload_seq(
        [(0.08, 1800.0, 500.0, 1.0), (0.50, 900.0, 220.0, 1.0),
         (1.35, 2400.0, 700.0, 1.0)], 1.65, seed=40)
    # Sniper [0.60, 1.20, 0.50] = 2.30 s: slow bolt, heavy clicks.
    sounds["reload_sniper"] = reload_seq(
        [(0.10, 1400.0, 400.0, 1.0), (0.65, 750.0, 180.0, 1.0),
         (1.85, 2000.0, 600.0, 1.0)], 2.30, seed=46)
    # Shotgun [0.50, 1.00, 0.40] = 1.90 s: shell insert + pump rack.
    sounds["reload_shotgun"] = reload_seq(
        [(0.08, 1600.0, 450.0, 1.0), (0.55, 1000.0, 250.0, 1.0),
         (1.30, 1100.0, 300.0, 0.7), (1.62, 2600.0, 700.0, 1.0)], 1.90, seed=47)
    # LMG [0.70, 1.30, 0.50] = 2.50 s: belt rattle + heavy clicks.
    sounds["reload_lmg"] = reload_seq(
        [(0.10, 1200.0, 350.0, 1.0), (0.75, 800.0, 200.0, 1.0),
         (2.05, 2200.0, 650.0, 1.0)], 2.50, seed=48, rattle=True)
    # Goal 3 CONTENT: BR-3 [0.50, 0.90, 0.35] = 1.75 s: crisp mag clicks.
    sounds["reload_burst"] = reload_seq(
        [(0.10, 2000.0, 550.0, 1.0), (0.60, 950.0, 240.0, 1.0),
         (1.45, 2500.0, 700.0, 1.0)], 1.75, seed=49)
    # Goal 3 CONTENT: HV-44 [0.60, 1.10, 0.40] = 2.10 s: cylinder out,
    # speedloader clatter, cylinder snap shut.
    sounds["reload_revolver"] = reload_seq(
        [(0.10, 1500.0, 400.0, 1.0), (0.70, 1000.0, 250.0, 1.0),
         (1.50, 1300.0, 300.0, 0.8), (1.95, 2400.0, 650.0, 1.0)], 2.10, seed=50)

    # Dryfire: sharper hammer snap (click + metallic tick).
    sounds["dryfire"] = click(0.10, 2600.0, seed=45, body_f=420.0)

    wr = white(0.45, 50)
    wr = highpass(wr, 600.0)
    wr = lowpass(wr, 4500.0)
    wr = amod(wr, amod(attack(len(wr), 0.18), exp_decay(len(wr), 0.12, delay_s=0.18)))
    place(wr, click(0.06, 1500.0, seed=51, body_f=400.0), 0.36, 0.8)
    sounds["weapon_raise"] = fade_edges(normalize(wr, 0.85))

    # --- Hit feedback ------------------------------------------------------
    # Hitmarker: crisper tick (content only — HUD still owns playback).
    hm = tone(2800, 2600, 0.07, "sine")
    hm = amod(hm, exp_decay(len(hm), 0.015))
    place(hm, click(0.03, 3400.0, seed=60), 0.0, 0.6)
    sounds["hitmarker"] = fade_edges(normalize(hm, 0.9))

    sounds["headshot_ding"] = metallic_ding([3520.0, 5315.0, 7365.0], 0.50, 0.22, seed=61)

    sounds["kill_confirm"] = note_seq([(659.25, 0.8), (987.77, 1.0)], 0.30, 0.22,
                                      wave="square", cutoff=4000.0)

    # --- Explosives (Goal 2: real low-end punch, sized variants) ---------
    # Standard big (barrels, generic detonate): deeper sub, longer rumble.
    sounds["explosion_big"] = explosion_v2(1.4, 65, 26, 0.55, 480, 0.5,
                                           0.9, seed=70)
    # Grenade-scale: shorter, tighter, still punchy.
    sounds["explosion_small"] = explosion_v2(0.8, 75, 35, 0.28, 600, 0.28,
                                             0.8, seed=72)
    # Barrel: mid size + delayed secondary cook-off boom.
    sounds["explosion_barrel"] = explosion_v2(1.2, 60, 28, 0.45, 450, 0.42,
                                              1.0, seed=73, second=(0.18, 0.5))
    # Airstrike: biggest — lowest sub, longest rumble, late secondary.
    sounds["explosion_airstrike"] = explosion_v2(2.2, 55, 24, 0.80, 380, 0.70,
                                                 1.0, seed=74, second=(0.35, 0.6))

    # Grenade beep: brighter + sharper attack (telegraph must cut through).
    beep = tone(1250, 1250, 0.12, "sine")
    beep = amod(beep, amod(attack(len(beep), 0.003), exp_decay(len(beep), 0.05, delay_s=0.01)))
    place(beep, click(0.02, 4000.0, seed=75), 0.0, 0.4)
    sounds["grenade_beep"] = fade_edges(normalize(beep, 0.85))

    # --- Grapple / portal -----------------------------------------------------
    gf = [0.0] * _n(0.45)
    air = white(0.16, 80)
    air = highpass(air, 400.0)
    air = lowpass(air, 6000.0)
    air = amod(air, amod(attack(len(air), 0.01), exp_decay(len(air), 0.06)))
    place(gf, air, 0.0, 1.0)
    th = tone(180, 70, 0.40, "sine")
    th = amod(th, exp_decay(len(th), 0.10))
    place(gf, th, 0.02, 0.8)
    sw = tone(600, 200, 0.20, "sine")
    sw = amod(sw, exp_decay(len(sw), 0.08))
    place(gf, sw, 0.0, 0.4)
    sounds["grapple_fire"] = fade_edges(normalize(gf, 0.92))

    gz = white(0.9, 81)
    gz = highpass(gz, 300.0)
    gz = lowpass(gz, 3500.0)
    n = len(gz)
    sweep = [0.3 + 0.7 * math.sin(math.pi * i / n) for i in range(n)]
    gz = amod(gz, sweep)
    sounds["grapple_zip"] = normalize(make_loop(gz, 0.20), 0.85)

    po = [0.0] * _n(1.0)
    hum = tone(80, 400, 1.0, "saw")
    hum = lowpass(hum, 1200.0)
    hum = amod(hum, attack(len(hum), 0.7))
    place(po, hum, 0.0, 0.7)
    shim = tone(2000, 4200, 1.0, "sine")
    trem = [0.5 + 0.5 * math.sin(2 * math.pi * 14.0 * i / SR) for i in range(len(shim))]
    shim = amod(shim, trem)
    shim = amod(shim, attack(len(shim), 0.5))
    place(po, shim, 0.0, 0.35)
    sounds["portal_open"] = fade_edges(normalize(po, 0.9))

    ph = [0.0] * _n(2.0)
    for i, (f, g) in enumerate([(55.0, 0.55), (110.0, 0.35), (165.0, 0.22), (220.0, 0.14)]):
        p = tone(f, f, 2.0, "sine", phase=i * 1.3)
        place(ph, p, 0.0, g)
    sh2 = tone(880, 880, 2.0, "sine")
    lfo = [0.5 + 0.5 * math.sin(2 * math.pi * 0.5 * i / SR) for i in range(len(sh2))]
    sh2 = amod(sh2, lfo)
    place(ph, sh2, 0.0, 0.10)
    sounds["portal_hum_loop"] = normalize(make_loop(ph, 0.40), 0.75)

    tp = tone(200, 2400, 0.35, "sine")
    tp = amod(tp, exp_decay(len(tp), 0.18))
    tp2 = tone(2400, 80, 0.35, "sine")
    tp2 = amod(tp2, exp_decay(len(tp2), 0.18))
    z = add(tp, tp2)
    sp = white(0.70, 82)
    sp = highpass(sp, 3000.0)
    sp = amod(sp, exp_decay(len(sp), 0.15))
    z = add(z, amod(sp, [0.5] * len(sp)))
    sounds["portal_teleport"] = fade_edges(normalize(z, 0.9))

    # --- Horns ------------------------------------------------------------------
    sounds["wave_horn"] = horn(1.5, [98.0, 104.0, 147.0, 196.0], 750.0, 1.6)
    sounds["juggernaut_horn"] = horn(1.8, [55.0, 58.27, 82.5, 110.0], 520.0, 2.2, seed=4)

    # --- Player body ---------------------------------------------------------------
    dt = tone(70, 40, 0.35, "sine")
    dt = amod(dt, exp_decay(len(dt), 0.09))
    dn = white(0.35, 90)
    dn = lowpass(dn, 300.0)
    dn = amod(dn, exp_decay(len(dn), 0.07))
    sounds["damage_thud"] = fade_edges(normalize(add(dt, dn), 0.92))

    hb = [0.0] * _n(1.0)
    lub = tone(58, 45, 0.22, "sine")
    lub = amod(lub, exp_decay(len(lub), 0.07))
    place(hb, lub, 0.00, 1.0)
    dub = tone(65, 50, 0.20, "sine")
    dub = amod(dub, exp_decay(len(dub), 0.06))
    place(hb, dub, 0.32, 0.85)
    sounds["heartbeat_loop"] = normalize(make_loop(hb, 0.15), 0.85)

    fc = white(0.16, 100)
    fc = highpass(fc, 900.0)
    fc = lowpass(fc, 5200.0)
    fc = amod(fc, exp_decay(len(fc), 0.028))
    knock = tone(210, 150, 0.10, "sine")
    knock = amod(knock, exp_decay(len(knock), 0.03))
    sounds["footstep_concrete"] = fade_edges(normalize(add(fc, amod(knock, [0.5] * len(knock))), 0.8))

    fd = white(0.18, 101)
    fd = lowpass(fd, 700.0)
    fd = amod(fd, exp_decay(len(fd), 0.05))
    sounds["footstep_dirt"] = fade_edges(normalize(fd, 0.8))

    fm = white(0.28, 102)
    fm = highpass(fm, 1500.0)
    fm = amod(fm, exp_decay(len(fm), 0.05))
    for f, g in [(420.0, 0.5), (630.0, 0.3)]:
        p = tone(f, f * 0.99, 0.28, "sine")
        p = amod(p, exp_decay(len(p), 0.12))
        place(fm, p, 0.0, g)
    sounds["footstep_metal"] = fade_edges(normalize(fm, 0.8))

    jl = tone(80, 45, 0.35, "sine")
    jl = amod(jl, exp_decay(len(jl), 0.10))
    jn = white(0.35, 103)
    jn = lowpass(jn, 400.0)
    jn = amod(jn, exp_decay(len(jn), 0.09))
    sounds["jump_land"] = fade_edges(normalize(add(jl, amod(jn, [0.7] * len(jn))), 0.88))

    # --- UI -------------------------------------------------------------------------
    sounds["ui_click"] = click(0.07, 3000.0, seed=110, body_f=600.0)
    hv = tone(1800, 1800, 0.06, "sine")
    hv = amod(hv, exp_decay(len(hv), 0.02))
    sounds["ui_hover"] = fade_edges(normalize(hv, 0.6))
    sounds["ui_confirm"] = note_seq([(523.25, 0.8), (783.99, 1.0)], 0.16, 0.12)
    sounds["forge_success"] = note_seq(
        [(523.25, 0.7), (659.25, 0.7), (783.99, 0.7), (1046.50, 1.0)],
        0.30, 0.13, decay_mul=1.6)
    ff = add(tone(110, 105, 0.55, "square"), tone(116.5, 111, 0.55, "square"))
    ff = lowpass(ff, 800.0)
    ff = amod(ff, amod(attack(len(ff), 0.02), exp_decay(len(ff), 0.3)))
    sounds["forge_fail"] = fade_edges(normalize(ff, 0.85))
    sounds["killstreak_ready"] = note_seq([(880.0, 0.9), (1174.66, 1.0)], 0.28, 0.24,
                                          wave="square", cutoff=5000.0)
    uv = tone(1200, 1800, 0.45, "sine")
    uv = amod(uv, [0.6 + 0.4 * math.sin(2 * math.pi * 6.0 * i / SR) for i in range(len(uv))])
    uv = amod(uv, exp_decay(len(uv), 0.3))
    sounds["uav_online"] = fade_edges(normalize(uv, 0.85))
    sounds["pickup"] = note_seq([(659.25, 0.8), (987.77, 1.0)], 0.20, 0.13)

    # --- Ambience / music ---------------------------------------------------------------
    wind = white(8.0, 200)
    wind = lowpass(wind, 350.0)
    n = len(wind)
    swell = [0.55 + 0.30 * math.sin(2 * math.pi * 0.125 * i / SR + 1.0)
             + 0.15 * math.sin(2 * math.pi * 0.07 * i / SR) for i in range(n)]
    wind = amod(wind, swell)
    sounds["ambient_wind_loop"] = normalize(make_loop(wind, 1.0), 0.55)

    dr = [0.0] * _n(16.0)
    for i, f in enumerate([55.0, 55.6, 82.4, 110.2]):
        s = tone(f, f * 1.001, 16.0, "saw", phase=i * 2.1)
        place(dr, s, 0.0, 0.22)
    sub = tone(27.5, 27.5, 16.0, "sine")
    place(dr, sub, 0.0, 0.35)
    dr = lowpass(dr, 250.0)
    lfo2 = [0.7 + 0.3 * math.sin(2 * math.pi * 0.0625 * i / SR) for i in range(len(dr))]
    dr = amod(dr, lfo2)
    dr = tanh_clip(dr, 1.4)
    sounds["music_drone_loop"] = normalize(make_loop(dr, 2.0), 0.6)

    return sounds


def main():
    sounds = build_all()
    for name, data in sounds.items():
        write_wav(name, data)
    print("\nDone: %d files -> %s" % (len(sounds), OUT_DIR))


if __name__ == "__main__":
    main()
