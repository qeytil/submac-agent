"""Generates android_native/res/raw/telesia_chime.wav: Telesia's light notification sound (2026-11-05).

A soft two-tone chime, 880 Hz then 1320 Hz (a fifth up), each a sine with a little second harmonic, a gentle
attack (12 ms) and a long exponential decay, overlapping slightly, at a low level (peak about -14 dBFS).
0.52 s, 44.1 kHz, mono, 16-bit. Run: python3 tools/notif_chime.py
"""
import math
import struct
import wave

RATE = 44100
LENGTH = 0.52
PEAK = 0.2  # about -14 dBFS: soft, never harsh


def note(t, start, freq, dur):
    x = t - start
    if x < 0 or x > dur:
        return 0.0
    attack = 0.012
    env = (x / attack) if x < attack else math.exp(-(x - attack) * 7.5)
    # A fade at the very end so nothing clicks.
    tail = min(1.0, (dur - x) / 0.03)
    s = math.sin(2 * math.pi * freq * x) + 0.18 * math.sin(2 * math.pi * freq * 2 * x)
    return s * env * tail


def main(path="android_native/res/raw/telesia_chime.wav"):
    n = int(RATE * LENGTH)
    raw = []
    for i in range(n):
        t = i / RATE
        v = 0.55 * note(t, 0.0, 880.0, 0.30) + 0.5 * note(t, 0.11, 1320.0, LENGTH - 0.11)
        raw.append(v)
    top = max(abs(v) for v in raw) or 1.0
    frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v / top * PEAK)) * 32767)) for v in raw)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)
    print(path, n / RATE, "s")


if __name__ == "__main__":
    main()
