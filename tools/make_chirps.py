"""Synthesize the three bird calls (stdlib only) as mono 16-bit WAVs for Godot.

Run:  python3 tools/make_chirps.py
Then: godot --headless --path . --import

Writes assets/sounds/birds/<species>.wav (see birds.gd for the species):
  azure: thin, high "tsee-tsee-tsee" (rising 6-7 kHz notes) and a lower closing note
  gold:  liquid warble, eight quick vibrato notes hopping between 2.5 and 4.5 kHz
  dusk:  two harsh, buzzy descending "chrrk" calls (3.2 -> 1.7 kHz, 70 Hz rasp), for the flock
Seeded, so re-running gives the same files.
"""
import math
import os
import random
import struct
import wave

RATE = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sounds", "birds")


def note(f0, f1, dur, vibrato=(0.0, 0.0), rasp=0.0, harmonics=(1.0,), noise=0.0, rng=None):
    """Sine sweep f0 -> f1 (Hz) over `dur` s with a soft attack/decay. vibrato = (rate Hz, depth Hz);
    rasp = depth of a 70 Hz amplitude buzz; harmonics = amplitudes of partials 1, 2, 3..."""
    out = []
    phase = 0.0
    n = int(dur * RATE)
    for i in range(n):
        t = i / RATE
        x = i / n
        f = f0 + (f1 - f0) * x + vibrato[1] * math.sin(2 * math.pi * vibrato[0] * t)
        phase += 2 * math.pi * f / RATE
        s = sum(a * math.sin(phase * (k + 1)) for k, a in enumerate(harmonics))
        if rasp:
            s *= 1 - rasp * (0.5 + 0.5 * math.copysign(1, math.sin(2 * math.pi * 70 * t)))
        if noise:
            s += noise * rng.uniform(-1, 1)
        env = min(1.0, x / 0.15) * min(1.0, (1 - x) / 0.35)  # quick attack, longer fade
        out.append(s * env)
    return out


def silence(dur):
    return [0.0] * int(dur * RATE)


def azure(rng):
    s = []
    for k in range(3):
        s += note(6000 + 150 * k, 7200 + 150 * k, 0.07, harmonics=(1.0, 0.15)) + silence(0.05)
    return s + note(4600, 3800, 0.13, vibrato=(40, 120), harmonics=(1.0, 0.2))


def gold(rng):
    s = []
    for _ in range(8):
        f = rng.uniform(2500, 4500)
        s += note(f, f * rng.uniform(0.8, 1.25), rng.uniform(0.045, 0.075), vibrato=(rng.uniform(25, 45), 250),
                  harmonics=(1.0, 0.3, 0.1)) + silence(0.015)
    return s


def dusk(rng):
    s = []
    for f0 in (3200, 3000):
        s += note(f0, 1700, 0.18, rasp=0.7, harmonics=(1.0, 0.5, 0.3), noise=0.15, rng=rng) + silence(0.09)
    return s


def save(name, samples):
    peak = max(abs(x) for x in samples) or 1.0
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(32767 * 0.8 * x / peak)) for x in samples))
    print(f"{name}: {len(samples) / RATE:.2f} s")


os.makedirs(OUT, exist_ok=True)
for seed, (name, fn) in enumerate([("azure", azure), ("gold", gold), ("dusk", dusk)]):
    save(name, fn(random.Random(seed)))
