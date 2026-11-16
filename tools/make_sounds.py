"""Synthesize the game's sounds (soft piano loop, footsteps, jump, landing) as mono 16-bit WAVs.

Run:  python3 tools/make_sounds.py
Then: godot --headless --path . --import

Needs numpy (the stdlib-only version would take minutes for the music). Seeded, so re-running gives
identical files. The music is rendered circularly: note tails and the reverb that run past the end wrap
around to the start, so the loop is seamless by construction. A WAV 'smpl' chunk marks the whole file
as a forward loop, which Godot's importer picks up ("Detect From WAV").
"""
import os
import struct
import wave

import numpy as np

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sounds")
RATE = 22050

# --- music ------------------------------------------------------------------------------------------
BPM = 56
BEAT = 60.0 / BPM
BARS = 16  # 8 chords x 2 bars, 4/4 → 68.6 s

# Left hand voicings (MIDI), two bars each, F major.
CHORDS = [
    [41, 48, 52, 57],      # Fmaj7
    [45, 52, 55, 60],      # Am7
    [38, 45, 53, 60, 64],  # Dm9
    [46, 53, 57, 62],      # Bbmaj7
    [43, 50, 53, 58],      # Gm7
    [46, 53, 57, 60],      # Bbmaj9 (no 3rd)
    [41, 48, 52, 57],      # Fmaj7
    [48, 55, 60, 65],      # Csus4 (bar 16 resolves to C, see below)
]
# Melody per chord: (beat within the 8-beat span, MIDI, velocity).
MELODY = [
    [(1, 69, .55), (2.5, 72, .5), (4, 76, .6), (7, 74, .45)],
    [(0, 72, .55), (3, 67, .4), (4, 69, .5), (6, 64, .4)],
    [(1, 65, .45), (2, 69, .5), (3, 72, .5), (4, 76, .6), (6, 74, .45)],
    [(0, 69, .5), (4, 65, .4), (6, 67, .45)],
    [(0, 70, .5), (2, 74, .55), (3, 72, .45), (4, 70, .5), (6, 69, .45)],
    [(0, 72, .55), (3, 77, .5), (4, 76, .55), (6, 72, .45)],
    [(0, 69, .5), (2, 67, .4), (3, 69, .45), (4, 72, .55)],
    [(0, 72, .5), (2, 65, .4), (4, 64, .45), (6, 67, .4)],  # G leads back to the opening A
]


def piano_note(midi, vel, hold):
    """Additive piano: inharmonic partials, two slightly detuned strings, fast attack, exponential decay,
    damper after `hold` seconds. Softer notes are darker (high partials fall off faster)."""
    f0 = 440.0 * 2 ** ((midi - 69) / 12)
    t1 = np.interp(midi, [36, 84], [5.0, 1.6])  # fundamental decay time (s), shorter up high
    length = min(hold + 1.5, 6.0)
    t = np.arange(int(length * RATE)) / RATE
    out = np.zeros_like(t)
    inharm = 0.0004
    for n in range(1, 11):
        f = f0 * n * np.sqrt(1 + inharm * n * n)
        if f > RATE / 2 * 0.9:
            break
        amp = n ** -1.4 * (0.35 + vel) ** (n - 1) * 0.6  # brightness with velocity
        decay = np.exp(-t / (t1 / (1 + 0.7 * (n - 1))))
        out += amp * decay * (np.sin(2 * np.pi * f * t) + 0.6 * np.sin(2 * np.pi * f * 1.0008 * t + n))
    attack = np.minimum(t / 0.004, 1.0)
    release = np.where(t < hold, 1.0, np.exp(-(t - hold) / 0.25))
    return out * attack * release * vel


def render_music():
    rng = np.random.default_rng(7)
    n = int(BARS * 4 * BEAT * RATE)
    mix = np.zeros(n)

    def add(beat, midi, vel, hold_beats):
        start = int((beat * BEAT + rng.normal(0, 0.012)) * RATE) % n  # slight human timing
        note = piano_note(midi, vel * rng.uniform(0.92, 1.05), hold_beats * BEAT)
        idx = (start + np.arange(len(note))) % n  # circular: tails past the end wrap to the start
        np.add.at(mix, idx, note)

    for c, chord in enumerate(CHORDS):
        b0 = c * 8
        for bar in range(2):
            b = b0 + bar * 4
            voicing = chord if not (c == 7 and bar == 1) else [48, 55, 60, 64]  # Csus4 → C
            add(b, voicing[0] - (12 if voicing[0] > 44 else 0), .42, 4)  # bass, lower octave
            if bar == 0:
                add(b + 1, voicing[1], .3, 3)
            for i, m in enumerate(voicing[2:]):  # soft rolled upper chord tones
                add(b + 2 + i * 0.08, m, .27, 2)
        for beat, midi, vel in MELODY[c]:
            add(b0 + beat, midi, vel, 2)

    # Reverb + echo as one impulse response, applied by circular FFT convolution (keeps the loop seamless).
    ir_t = np.arange(int(2.5 * RATE)) / RATE
    noise = rng.normal(0, 1, len(ir_t))
    noise = np.convolve(noise, np.ones(6) / 6, mode="same")  # darken the tail
    ir = noise * np.exp(-ir_t / 0.45) * 0.02
    for k, d in enumerate([0.32, 0.64, 0.96]):  # soft echoes
        ir[int(d * RATE)] += 0.18 * 0.5 ** k
    ir_full = np.zeros(n)
    ir_full[:len(ir)] = ir
    wet = np.fft.irfft(np.fft.rfft(mix) * np.fft.rfft(ir_full), n)
    out = mix + wet
    return out / np.max(np.abs(out)) * 0.5  # -6 dBFS peak; in-game volume trims it further


# --- effects ----------------------------------------------------------------------------------------
def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / RATE)
    y = np.zeros_like(x)
    acc = 0.0
    for i, v in enumerate(x):  # short buffers, a Python loop is fine
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def env(t, attack, decay):
    return np.minimum(t / attack, 1.0) * np.exp(-t / decay)


def footstep(seed):
    """Grass/dirt step: low heel thump + lowpassed crunch, then a softer toe crunch."""
    rng = np.random.default_rng(100 + seed)
    t = np.arange(int(0.22 * RATE)) / RATE
    thump = np.sin(2 * np.pi * rng.uniform(70, 95) * t) * env(t, 0.003, 0.03) * 0.6
    heel = lowpass(rng.normal(0, 1, len(t)), rng.uniform(900, 1400)) * env(t, 0.002, 0.035)
    toe_at = rng.uniform(0.045, 0.07)
    tt = np.clip(t - toe_at, 0, None)
    toe = lowpass(rng.normal(0, 1, len(t)), rng.uniform(1500, 2400)) * env(tt, 0.002, 0.025) * (t > toe_at) * 0.6
    return thump + heel + toe


def jump():
    """Push-off scuff followed by a short airy whoosh."""
    rng = np.random.default_rng(200)
    t = np.arange(int(0.35 * RATE)) / RATE
    scuff = lowpass(rng.normal(0, 1, len(t)), 1200) * env(t, 0.002, 0.04) * 1.2
    thump = np.sin(2 * np.pi * 85 * t) * env(t, 0.003, 0.04) * 0.6
    whoosh = lowpass(rng.normal(0, 1, len(t)), 2500) * np.sin(np.pi * np.clip(t / 0.3, 0, 1)) ** 2 * 0.25
    return scuff + thump + whoosh


def land():
    """Soft thud: pitch-dropping low sine + dull crunch."""
    rng = np.random.default_rng(300)
    t = np.arange(int(0.4 * RATE)) / RATE
    f = 75 * np.exp(-t / 0.15) + 45
    thud = np.sin(2 * np.pi * np.cumsum(f) / RATE) * env(t, 0.004, 0.09)
    crunch = lowpass(rng.normal(0, 1, len(t)), 800) * env(t, 0.003, 0.06) * 1.5
    return thud + crunch


# --- output -----------------------------------------------------------------------------------------
def write(name, x, peak, loop=False):
    x = x / np.max(np.abs(x)) * peak
    pcm = np.round(x * 32767).astype("<i2")
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    if loop:  # append a 'smpl' chunk: one forward loop over the whole file
        smpl = struct.pack("<9I", 0, 0, round(1e9 / RATE), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, 0, len(pcm), 0, 0)  # spec says inclusive; Godot reads it as exclusive
        with open(path, "r+b") as f:
            f.seek(0, 2)
            f.write(b"smpl" + struct.pack("<I", len(smpl)) + smpl)
            size = f.tell()
            f.seek(4)
            f.write(struct.pack("<I", size - 8))
    rms = np.sqrt(np.mean(x ** 2))
    print(f"{name:16s} {len(pcm) / RATE:6.2f} s  peak {20 * np.log10(np.max(np.abs(x))):6.1f} dBFS  "
          f"rms {20 * np.log10(rms):6.1f} dBFS  {os.path.getsize(path) / 1024:7.0f} KiB")
    return pcm


def main():
    os.makedirs(OUT, exist_ok=True)
    pcm = write("piano_loop.wav", render_music(), 0.5, loop=True).astype(float)
    # Loop seam check: the wrap-around step must look like any other step between neighbouring samples.
    seam = abs(pcm[0] - pcm[-1])
    typical = np.percentile(np.abs(np.diff(pcm)), 99)
    print(f"loop seam jump {seam:.0f} vs 99th percentile sample step {typical:.0f}")
    assert seam <= typical, "loop seam would click"
    for i in range(4):
        write(f"step_{i + 1}.wav", footstep(i), 0.8)
    write("jump.wav", jump(), 0.7)
    write("land.wav", land(), 0.8)


if __name__ == "__main__":
    main()
