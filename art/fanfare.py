#!/usr/bin/env python3
"""Synthesize the level-up fanfare: Poor/Sounds/levelup.mp3.

A soft electric-piano line over a IV - V - I cadence in D major, with a warm
pad, a little bass and a roomy reverb. Needs numpy and ffmpeg.

    python3 art/fanfare.py
"""
import os, subprocess, tempfile, wave
import numpy as np

SR = 44100
LENGTH = 6.2
rng = np.random.default_rng(7)
mix = np.zeros(int(SR * LENGTH))

def hz(note):  # "A4" -> 440.0
    names = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
    return 440.0 * 2 ** ((names[note[:-1]] + 12 * (int(note[-1]) - 4) - 9) / 12)

def add(sig, start, gain):
    i = int(start * SR)
    sig = sig[: len(mix) - i]
    mix[i : i + len(sig)] += sig * gain

def keys(note, dur):
    """Electric piano: a sine pushed by a quickly fading overtone, slow decay."""
    t = np.arange(int(dur * SR)) / SR
    f = hz(note)
    bite = np.exp(-t * 9)
    tone = np.sin(2 * np.pi * f * t + 1.6 * bite * np.sin(2 * np.pi * 2 * f * t))
    tone += 0.12 * np.exp(-t * 14) * np.sin(2 * np.pi * 4 * f * t)   # the tine
    env = np.minimum(t / 0.006, 1) * np.exp(-t * 2.2 / max(dur, 0.6) * 1.3)
    env *= np.minimum((dur - t) / 0.08, 1)
    return tone * env

def pad(notes, dur):
    """Slow, slightly detuned sines: the cushion under the melody."""
    t = np.arange(int(dur * SR)) / SR
    out = np.zeros_like(t)
    for n in notes:
        f = hz(n)
        for cents in (-6, 0, 6):
            out += np.sin(2 * np.pi * f * 2 ** (cents / 1200) * t + rng.uniform(0, 6.28))
            out += 0.25 * np.sin(2 * np.pi * 2 * f * 2 ** (cents / 1200) * t + rng.uniform(0, 6.28))
    env = np.minimum(t / 0.35, 1) * np.minimum((dur - t) / 0.9, 1)
    return out * env / (3 * len(notes))

def bass(note, dur):
    t = np.arange(int(dur * SR)) / SR
    env = np.minimum(t / 0.02, 1) * np.minimum((dur - t) / 0.3, 1) * np.exp(-t * 0.5)
    return np.sin(2 * np.pi * hz(note) * t) * env

# The call: ta, ta-ta, taaa -- then a step down home.
for note, start, dur, gain in [
    ("A4", 0.00, 0.50, 0.50), ("D5", 0.42, 0.45, 0.52), ("F#5", 0.70, 0.55, 0.55),
    ("A5", 1.12, 1.30, 0.62),
    ("G5", 2.10, 0.50, 0.50), ("F#5", 2.45, 0.50, 0.50), ("E5", 2.80, 0.60, 0.52),
    # home: a rolled Dmaj9
    ("D4", 3.30, 2.8, 0.45), ("A4", 3.36, 2.7, 0.40), ("C#5", 3.42, 2.7, 0.36),
    ("E5", 3.48, 2.6, 0.38), ("F#5", 3.54, 2.6, 0.42), ("A5", 3.66, 2.5, 0.34), ("E6", 3.95, 2.2, 0.20),
]:
    add(keys(note, dur), start, gain)

add(pad(["G3", "B3", "D4", "F#4"], 1.45), 0.00, 0.50)      # IV
add(pad(["A3", "C#4", "E4", "G4"], 2.20), 1.10, 0.50)      # V
add(pad(["D3", "A3", "F#4", "C#5"], 2.90), 3.20, 0.55)     # I
add(bass("G2", 1.2), 0.00, 0.35)
add(bass("A2", 2.0), 1.12, 0.35)
add(bass("D2", 2.8), 3.30, 0.40)

def room(seed):
    """A made-up room: fading noise, darker as it fades."""
    r = np.random.default_rng(seed)
    n = int(2.2 * SR)
    t = np.arange(n) / SR
    ir = r.standard_normal(n) * np.exp(-t * 3.2)
    spec = np.fft.rfft(ir)
    spec *= 1 / (1 + (np.fft.rfftfreq(n, 1 / SR) / 3500) ** 2)  # roll the top off
    ir = np.fft.irfft(spec, n)
    ir[: int(0.012 * SR)] = 0                                    # a breath before the room answers
    return ir / np.sqrt((ir ** 2).sum())

def wet(dry, ir):
    n = len(dry) + len(ir)
    return np.fft.irfft(np.fft.rfft(dry, n) * np.fft.rfft(ir, n), n)[: len(dry)]

stereo = np.stack([mix + 0.33 * wet(mix, room(1)), mix + 0.33 * wet(mix, room(2))], axis=1)
fade = int(1.2 * SR)
stereo[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 2
stereo *= 0.70 / np.abs(stereo).max()                           # gentle: well under full scale

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Poor", "Sounds", "levelup.mp3")
os.makedirs(os.path.dirname(out), exist_ok=True)
with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
    with wave.open(tmp, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((stereo * 32767).astype("<i2").tobytes())
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp.name, "-codec:a", "libmp3lame", "-b:a", "160k",
                "-map_metadata", "-1", out], check=True)
os.unlink(tmp.name)
print("wrote", os.path.normpath(out), "%.1fs" % LENGTH)
