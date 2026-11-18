# Score + sound effects for the example video. Replace the cue section for a new video.
# usage: python3 audio/audio.py build/audio.wav
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audiolib import *

B = beats(); cue = B['cues']; D = B['duration']
mx = Mix(D)

# ---------------- music: light and open, F major, 104 bpm ----------------
bar = 60 / 104 * 4
F, Bb, C, Dm = 65, 70, 60, 62
prog = [(0.2 + i * bar, bar, r, q) for i, (r, q) in enumerate([(F, 'add9'), (Bb, 'M7'), (Dm, 'm7'), (C, 'sus4'), (F, 'add9')]) if 0.2 + i * bar < D]
mx.pads(prog, 0.28, cut=1500)
mx.arp([p for p in prog if p[0] >= bar * 0.9], bar / 8, 0.18, marimba, 65, 84, (0, 2, 1, 3, 2, 4, 3, 1))
mx.bassline([p for p in prog if p[0] >= bar * 0.9], 0.42, every=bar / 4, dec=5)
for i in range(int((D - bar) / (bar / 8))):          # soft shaker on the eighths once the tune gets going
    mx.music(bar + i * bar / 8, shaker(0.5 if i % 2 else 0.8), 0.5, 0.28)
mx.music(cue['title'], bell(mf(77), 3.0), 0.4); mx.music(cue['title'] + 0.08, bell(mf(84), 3.0), 0.28)

# ---------------- ambience + sound effects on the story cues ----------------
mx.bed(0, D, meadow, 0.5, fi=0.8, fo=1.2)
for k in range(6): mx.sfx(0.8 + k * 1.7 + rng.uniform(0, 0.6), chirp(0.5), 1, rng.uniform(-0.8, 0.8))
walk_end = cue['throw'] - 0.8
mx.steps(cue['walk-start'] + 0.2, walk_end, 0.45, 'grass', 0.26)
mx.sfx(cue['throw'] - 0.15, whoosh(0.5, True, 0.35), 1, 0.22)
mx.sfx(cue['ball-lands'], boing(220, 0.5), 1, 0.4)
for j, dt in enumerate([0.4, 0.72, 0.98]): mx.sfx(cue['ball-lands'] + dt, boing(260 + 30 * j, 0.32 - j * 0.08, 0.3), 1, 0.45)
mx.sfx(cue['roll-end'], pop(0.5), 1, 0.25)
mx.music(cue['wave'], bell(mf(81), 2.2), 0.35)

mx.write(sys.argv[1] if len(sys.argv) > 1 else 'build/audio.wav', fade_out=0.9)
