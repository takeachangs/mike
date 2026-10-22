# Renders the cue sounds in this folder: soft detuned sines in D major with a 25 ms fade-in, a 0.10 s decay and a
# small room, every cue about 0.7 s. Built on earshot's DSP (https://github.com/Leonxlnx/earshot, MIT); it is not a
# dependency of the bridge or the recorder, only of this script. Run it with an earshot install's Python:
#   <earshot>/.venv/bin/python app/scripts/make-sounds.py
from pathlib import Path

import numpy as np
import soundfile as sf
from earshot.forge import dsp, fx
from earshot.forge.sfx import check

SR = dsp.SR
N = {"D5": 587.33, "F#5": 739.99, "A5": 880.0, "D6": 1174.66}
TAU, ATTACK, GAP = 0.10, 0.025, 0.045
CUES = {  # file: notes, gap between note starts (s)
    "start": (["D5", "A5"], GAP),  # also played on resume
    "pause": (["A5", "D5"], GAP),
    "stop": (["A5", "F#5", "D5"], 0.05),
    "wait": (["A5"], 0.0),
    "ready": (["D5", "F#5", "A5", "D6"], 0.04),
}


def tone(f, dur):
    """sine + a 3-cent detuned twin (slow shimmer) + a quiet octave; raised-cosine fade in and out, exponential decay."""
    t = np.arange(dsp.n_of(dur)) / SR
    x = np.sin(2 * np.pi * f * t) + 0.5 * np.sin(2 * np.pi * f * 2 ** (3 / 1200) * t + 1.0) + 0.12 * np.sin(4 * np.pi * f * t)
    env = np.exp(-np.maximum(t - ATTACK, 0) / TAU)
    a, b = dsp.n_of(ATTACK), dsp.n_of(0.08)
    env[:a] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    env[-b:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, b))
    return x * env


for name, (notes, gap) in CUES.items():
    dur = gap + 6 * TAU
    y = np.zeros(dsp.n_of(dur + gap * len(notes) + 0.4))
    for i, n in enumerate(notes):
        dsp.place(y, tone(N[n], dur), i * gap, gain=0.85 ** i)  # later notes slightly softer
    y = fx.reverb(dsp.butter(y, "low", 5000), dsp.rng(7), rt60=0.4, size=0.7, damp=0.6, wet=0.15, width=1.0)
    y = dsp.normalize(dsp.fade(dsp.trim_tail(y, floor_db=-60), fin=0.002, fout=0.05), -1.0)
    sf.write(Path(__file__).resolve().parent.parent / "Sources/MikeKit/Resources/sounds" / f"{name}.wav", y, SR, subtype="PCM_16")
    print(f"{name:6s} {len(y) / SR:4.2f} s  {check(y, SR)['summary']}")
