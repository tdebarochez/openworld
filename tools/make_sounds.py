"""Synthesize the game's sounds (one music loop per season, footsteps, jump, landing, wing flap) as mono 16-bit WAVs.

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


# --- instruments: (midi, velocity, hold seconds) → mono samples ---------------------------------------
def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def piano(midi, vel, hold):
    """Additive piano: inharmonic partials, two slightly detuned strings, fast attack, exponential decay,
    damper after `hold` seconds. Softer notes are darker (high partials fall off faster)."""
    f0 = hz(midi)
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


def harp(midi, vel, hold):
    """Plucked string: bright pluck that mellows quickly, rings freely, muted after `hold`."""
    f0 = hz(midi)
    t1 = np.interp(midi, [36, 84], [3.5, 1.4])
    length = min(hold + 0.8, 6.0)
    t = np.arange(int(length * RATE)) / RATE
    out = np.zeros_like(t)
    for n in range(1, 13):
        if f0 * n > RATE / 2 * 0.9:
            break
        amp = abs(np.sin(n * np.pi * 0.2)) / n  # plucked at 1/5 of the string
        out += amp * np.exp(-t * (1 + 1.1 * (n - 1)) / t1) * np.sin(2 * np.pi * f0 * n * t + n)
    attack = np.minimum(t / 0.002, 1.0)
    release = np.where(t < hold, 1.0, np.exp(-(t - hold) / 0.3))
    return out * attack * release * vel


def celesta(midi, vel, hold):
    """Celesta / soft bell: near-pure tone (resonator) plus the struck bar's inharmonic partials, which fade
    fast. Rings ~3 s whatever `hold`."""
    f0 = hz(midi)
    t = np.arange(int(3.5 * RATE)) / RATE
    out = np.zeros_like(t)
    for ratio, amp, decay in [(1, 1.0, 1.4), (2.756, 0.22, 0.3), (5.404, 0.07, 0.1)]:
        if f0 * ratio < RATE / 2 * 0.9:
            out += amp * np.exp(-t / decay) * np.sin(2 * np.pi * f0 * ratio * t)
    return out * np.minimum(t / 0.002, 1.0) * vel


def pad(midi, vel, hold):
    """Soft string pad: few harmonics, two detuned voices (slow chorus), slow swell and release."""
    f0 = hz(midi)
    t = np.arange(int((hold + 2.0) * RATE)) / RATE
    out = np.zeros_like(t)
    for n in range(1, 7):
        out += n ** -2 * (np.sin(2 * np.pi * f0 * n * t) + np.sin(2 * np.pi * f0 * n * 1.003 * t + n))
    swell = np.sin(np.pi / 2 * np.minimum(t / 1.5, 1.0)) ** 2
    release = np.where(t < hold, 1.0, np.exp(-(t - hold) / 0.6))
    return out * swell * release * vel * 0.5


# --- music ------------------------------------------------------------------------------------------
def render(bpm, beats, notes, seed, tail):
    """Mixes (beat, midi, velocity, hold beats, instrument) notes into a loop of `beats` beats, then adds
    reverb (`tail` = its decay time constant, s) and soft echoes."""
    beat_s = 60.0 / bpm
    rng = np.random.default_rng(seed)
    n = int(beats * beat_s * RATE)
    mix = np.zeros(n)
    for beat, midi, vel, hold, inst in notes:
        start = int((beat * beat_s + rng.normal(0, 0.012)) * RATE) % n  # slight human timing
        note = inst(midi, vel * rng.uniform(0.92, 1.05), hold * beat_s)
        idx = (start + np.arange(len(note))) % n  # circular: tails past the end wrap to the start
        np.add.at(mix, idx, note)

    # Reverb + echo as one impulse response, applied by circular FFT convolution (keeps the loop seamless).
    ir_t = np.arange(int(2.5 * RATE)) / RATE
    noise = rng.normal(0, 1, len(ir_t))
    noise = np.convolve(noise, np.ones(6) / 6, mode="same")  # darken the tail
    ir = noise * np.exp(-ir_t / tail) * 0.02
    for k, d in enumerate([0.32, 0.64, 0.96]):  # soft echoes
        ir[int(d * RATE)] += 0.18 * 0.5 ** k
    ir_full = np.zeros(n)
    ir_full[:len(ir)] = ir
    wet = np.fft.irfft(np.fft.rfft(mix) * np.fft.rfft(ir_full), n)
    return mix + wet


def melody(lines, span, inst, hold):
    """Per chord, (beat within its `span` beats, midi, velocity) → notes."""
    return [(c * span + b, m, v, hold, inst) for c, line in enumerate(lines) for b, m, v in line]


def summer():
    """F major, 56 BPM, 4/4: warm mid-register piano (the original loop). 8 chords x 2 bars → 68.6 s."""
    chords = [  # left hand voicings (MIDI)
        [41, 48, 52, 57],      # Fmaj7
        [45, 52, 55, 60],      # Am7
        [38, 45, 53, 60, 64],  # Dm9
        [46, 53, 57, 62],      # Bbmaj7
        [43, 50, 53, 58],      # Gm7
        [46, 53, 57, 60],      # Bbmaj9 (no 3rd)
        [41, 48, 52, 57],      # Fmaj7
        [48, 55, 60, 65],      # Csus4 (bar 16 resolves to C, see below)
    ]
    tune = [
        [(1, 69, .55), (2.5, 72, .5), (4, 76, .6), (7, 74, .45)],
        [(0, 72, .55), (3, 67, .4), (4, 69, .5), (6, 64, .4)],
        [(1, 65, .45), (2, 69, .5), (3, 72, .5), (4, 76, .6), (6, 74, .45)],
        [(0, 69, .5), (4, 65, .4), (6, 67, .45)],
        [(0, 70, .5), (2, 74, .55), (3, 72, .45), (4, 70, .5), (6, 69, .45)],
        [(0, 72, .55), (3, 77, .5), (4, 76, .55), (6, 72, .45)],
        [(0, 69, .5), (2, 67, .4), (3, 69, .45), (4, 72, .55)],
        [(0, 72, .5), (2, 65, .4), (4, 64, .45), (6, 67, .4)],  # G leads back to the opening A
    ]
    notes = []
    for c, chord in enumerate(chords):
        b0 = c * 8
        for bar in range(2):
            b = b0 + bar * 4
            voicing = chord if not (c == 7 and bar == 1) else [48, 55, 60, 64]  # Csus4 → C
            notes.append((b, voicing[0] - (12 if voicing[0] > 44 else 0), .42, 4, piano))  # bass, lower octave
            if bar == 0:
                notes.append((b + 1, voicing[1], .3, 3, piano))
            for i, m in enumerate(voicing[2:]):  # soft rolled upper chord tones
                notes.append((b + 2 + i * 0.08, m, .27, 2, piano))
        notes += [(b0 + b, m, v, 2, piano) for b, m, v in tune[c]]
    return render(56, 64, notes, 7, 0.45)


def autumn():
    """D minor, 50 BPM, 3/4 (slow waltz): lower, darker piano over a warm string pad. 8 chords x 2 bars
    → 57.6 s."""
    chords = [
        [38, 45, 53, 57, 64],  # Dm9
        [34, 41, 50, 57],      # Bbmaj7
        [41, 48, 52, 57],      # Fmaj7
        [36, 43, 52, 55, 62],  # Cadd9
        [43, 50, 53, 58],      # Gm7
        [41, 50, 53, 57, 60],  # Dm7/F
        [34, 46, 53, 57, 62],  # Bbmaj7
        [33, 45, 52, 57, 62],  # Asus4 (bar 16 resolves to A, see below)
    ]
    tune = [
        [(1, 69, .5), (2, 72, .45), (3, 74, .55), (5, 72, .4)],
        [(0, 70, .5), (2, 69, .4), (3, 65, .45)],
        [(1, 69, .5), (2, 67, .4), (3, 65, .45), (4, 64, .4)],
        [(0, 67, .5), (3, 62, .4), (4, 64, .45)],
        [(1, 65, .45), (2, 67, .45), (3, 70, .55), (5, 69, .4)],
        [(0, 69, .5), (3, 65, .4), (4, 62, .4)],
        [(0, 65, .45), (2, 62, .4), (3, 67, .5), (5, 65, .4)],
        [(0, 64, .5), (3, 61, .4), (4, 64, .45)],  # C# then E lead back to D minor
    ]
    notes = []
    for c, chord in enumerate(chords):
        b0 = c * 6
        notes += [(b0, m, .15, 5.7, pad) for m in chord[1:]]  # pad holds the chord
        for bar in range(2):
            b = b0 + bar * 3
            voicing = chord if not (c == 7 and bar == 1) else [33, 45, 52, 57, 61]  # Asus4 → A
            notes.append((b, voicing[0], .4, 3, piano))  # bass
            notes.append((b + 1, voicing[1], .25, 2, piano))
            for i, m in enumerate(voicing[2:]):
                notes.append((b + 2 + i * 0.1, m, .22, 1, piano))
    notes += melody(tune, 6, piano, 2)
    return render(50, 48, notes, 8, 0.6)


def winter():
    """E major (Lydian colour), 48 BPM, 4/4: sparse high celesta over a low sustained pad, long reverb.
    6 chords x 2 bars → 60 s."""
    chords = [
        [40, 47, 54, 56, 63],  # Emaj9
        [37, 44, 52, 56, 59],  # C#m7
        [33, 45, 52, 56, 63],  # Amaj7#11
        [44, 51, 54, 59, 63],  # G#m7
        [42, 49, 52, 57, 64],  # F#m7
        [35, 47, 52, 54, 59],  # Bsus4
    ]
    tune = [
        [(0, 83, .5), (1.5, 80, .4), (3, 78, .4), (4, 75, .45)],
        [(0, 76, .45), (2, 80, .45), (4, 83, .5), (6, 85, .4)],
        [(0, 81, .45), (1.5, 87, .35), (3, 85, .45), (4, 80, .45), (6, 76, .4)],
        [(0, 78, .45), (2, 75, .4), (4, 80, .5), (6, 83, .4)],
        [(0, 81, .45), (2, 85, .45), (4, 88, .45), (6, 85, .4)],
        [(0, 83, .45), (2, 78, .4), (4, 76, .45), (6, 78, .4)],
    ]
    notes = []
    for c, chord in enumerate(chords):
        notes += [(c * 8, m, .18, 7.7, pad) for m in chord]
        notes += [(c * 8 + b - 0.5, m - 12, v * 0.35, 1, celesta) for b, m, v in tune[c][1::2]]  # soft echo below
    notes += melody(tune, 8, celesta, 4)
    return render(48, 48, notes, 9, 0.9)


def spring():
    """G major, 72 BPM, 4/4: rolling harp arpeggios in eighths under a light, higher piano tune.
    8 chords x 2 bars → 53.3 s."""
    chords = [
        [43, 50, 54, 57, 62],  # Gmaj7(9)
        [40, 47, 54, 55, 59],  # Em9
        [36, 43, 52, 55, 59],  # Cmaj7
        [38, 45, 50, 52, 57],  # Dsus2
        [35, 42, 50, 54, 57],  # Bm7
        [40, 47, 50, 55, 59],  # Em7
        [45, 52, 55, 60, 64],  # Am7
        [38, 45, 50, 55, 57],  # Dsus4 (bar 16 resolves to D, see below)
    ]
    tune = [
        [(0, 74, .5), (2, 78, .5), (3, 76, .45), (4, 74, .5), (6, 71, .45)],
        [(0, 71, .45), (2, 74, .5), (4, 79, .55), (6, 78, .45)],
        [(0, 76, .5), (2, 72, .45), (3, 74, .45), (4, 76, .5), (6, 79, .45)],
        [(0, 76, .5), (2, 74, .45), (4, 69, .45), (6, 71, .4)],
        [(0, 74, .5), (2, 78, .5), (3, 81, .5), (4, 78, .45), (6, 76, .4)],
        [(0, 74, .45), (2, 71, .4), (4, 79, .5), (6, 76, .45)],
        [(0, 72, .5), (2, 76, .5), (4, 79, .5), (5, 81, .45), (6, 76, .45)],
        [(0, 74, .5), (2, 72, .45), (5, 76, .4), (6, 78, .45)],  # F# leads back to the opening D
    ]
    notes = []
    for c, chord in enumerate(chords):
        for bar in range(2):
            b = c * 8 + bar * 4
            voicing = chord if not (c == 7 and bar == 1) else [38, 45, 50, 54, 57]  # Dsus4 → D
            for k, i in enumerate([0, 1, 2, 3, 4, 3, 2, 1]):  # up and back down
                notes.append((b + k * 0.5, voicing[i], .35 if k == 0 else .22, 3 if k == 0 else 1.5, harp))
    notes += melody(tune, 8, piano, 2)
    return render(72, 64, notes, 10, 0.45)


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


def flap():
    """Hen wing beat: three quick soft feathery swishes (twice-lowpassed noise), fading."""
    rng = np.random.default_rng(600)
    t = np.arange(int(0.3 * RATE)) / RATE
    swish = lowpass(lowpass(rng.normal(0, 1, len(t)), 1600), 1600)
    beats = sum(a * np.exp(-((t - at) / 0.022) ** 2) for at, a in [(0.035, 1.0), (0.115, 0.7), (0.195, 0.45)])
    return swish * beats


def rumble(rng, t, cutoff, bumps):
    """Thunder roll: twice-lowpassed noise swelling and fading in random bumps (echoes off the clouds and
    hills), the whole thing dying away over a few seconds."""
    x = lowpass(lowpass(rng.normal(0, 1, len(t)), cutoff), cutoff)
    swell = np.zeros_like(t)
    for _ in range(bumps):
        at, width = rng.uniform(0.0, t[-1] * 0.6), rng.uniform(0.2, 0.9)
        swell += rng.uniform(0.3, 1.0) * np.exp(-((t - at) / width) ** 2)
    return x * (0.4 + swell) * np.exp(-t / (t[-1] * 0.35))


def thunder_near():
    """Close strike: a sharp tearing crack with crackles, then a deep roll."""
    rng = np.random.default_rng(400)
    t = np.arange(int(6.0 * RATE)) / RATE
    noise = rng.normal(0, 1, len(t))
    crack = (noise - lowpass(noise, 1500)) * env(t, 0.001, 0.06) * 2.5
    for _ in range(6):  # crackles along the channel
        at = rng.uniform(0.03, 0.5)
        tt = np.clip(t - at, 0, None)
        crack += lowpass(rng.normal(0, 1, len(t)), 3000) * env(tt, 0.001, 0.03) * (t > at) * rng.uniform(0.4, 1.0)
    boom = np.sin(2 * np.pi * np.cumsum(55 * np.exp(-t / 0.4) + 30) / RATE) * env(t, 0.01, 0.5) * 0.8
    return crack + boom + rumble(rng, t, 250, 6) * 6


def thunder_far():
    """Distant strike: only the low roll is left, slow to build."""
    rng = np.random.default_rng(500)
    t = np.arange(int(5.0 * RATE)) / RATE
    return rumble(rng, t, 120, 5) * np.minimum(t / 0.5, 1.0)


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
    for name, piece in [("summer", summer), ("autumn", autumn), ("winter", winter), ("spring", spring)]:
        pcm = write(f"music_{name}.wav", piece(), 0.5, loop=True).astype(float)  # -6 dBFS; in-game volume trims it
        # Loop seam check: the wrap-around step must look like any other step between neighbouring samples.
        seam = abs(pcm[0] - pcm[-1])
        typical = np.percentile(np.abs(np.diff(pcm)), 99)
        print(f"  loop seam jump {seam:.0f} vs 99th percentile sample step {typical:.0f}")
        assert seam <= typical, "loop seam would click"
    for i in range(4):
        write(f"step_{i + 1}.wav", footstep(i), 0.8)
    write("jump.wav", jump(), 0.7)
    write("land.wav", land(), 0.8)
    write("flap.wav", flap(), 0.6)
    write("thunder_near.wav", thunder_near(), 0.9)
    write("thunder_far.wav", thunder_far(), 0.7)


if __name__ == "__main__":
    main()
