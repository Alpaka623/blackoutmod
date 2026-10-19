"""Generates Mods/BlackoutMod/Sounds/flicker.wav: electrical crackle while the
lights flicker, then a relay clunk and a mains hum winding down (power cut).

The game's own sounds can't be played audibly from UE4SS, so the mod plays this
file through Windows. Run from the repo root:  python tools/make_flicker_sound.py
"""
import wave
from pathlib import Path

import numpy as np

RATE = 44100
LENGTH = 1.8  # seconds
VOLUME = 0.5  # peak level; Windows playback ignores the in-game volume

rng = np.random.default_rng(1337)
t = np.arange(int(RATE * LENGTH)) / RATE
out = np.zeros_like(t)


def envelope(start, end, attack=0.005, release=0.03):
    """1 between start and end with short fades, 0 elsewhere."""
    env = np.clip((t - start) / attack, 0, 1) * np.clip((end - t) / release, 0, 1)
    return env * ((t >= start) & (t <= end))


# Mains hum (50 Hz + harmonics, slightly clipped = buzzy transformer sound)
def hum(freq):
    wave_ = sum(np.sin(2 * np.pi * freq * k * t) / k for k in (1, 2, 3, 5, 7))
    return np.tanh(2.5 * wave_)


# Crackle bursts roughly matching the flicker "off" steps (0, 300, 700 ms)
for start, end in [(0.0, 0.14), (0.30, 0.44), (0.70, 0.82)]:
    env = envelope(start, end)
    noise = rng.standard_normal(len(t))
    # Sparse sharp clicks on top of the noise = sparks
    clicks = (rng.random(len(t)) > 0.9985) * rng.choice([-1, 1], len(t)) * 4
    # Amplitude modulated at 100 Hz like arcing on AC power
    arc = 0.5 + 0.5 * np.abs(np.sin(2 * np.pi * 50 * t))
    out += env * (0.35 * noise * arc + clicks) * 0.6
    out += env * 0.35 * hum(50)

# Relay clunk when the power is cut
clunk_t = t - 1.2
clunk = (clunk_t >= 0) * np.exp(-np.clip(clunk_t, 0, None) * 30) * np.sin(2 * np.pi * 70 * clunk_t)
out += 1.2 * clunk

# Hum winding down after the cut: pitch and level drop
down = t >= 1.2
fall = np.clip((t - 1.2) / 0.6, 0, 1)
freq = 50 * (1 - 0.6 * fall)
phase = 2 * np.pi * np.cumsum(freq) / RATE
wind_down = np.tanh(2.5 * (np.sin(phase) + 0.5 * np.sin(2 * phase) + 0.33 * np.sin(3 * phase)))
out += down * (1 - fall) ** 2 * 0.45 * wind_down

# Normalize, short fade at both ends against clicks
out /= np.max(np.abs(out))
out *= VOLUME
fade = int(0.003 * RATE)
out[:fade] *= np.linspace(0, 1, fade)
out[-fade:] *= np.linspace(1, 0, fade)

target = Path(__file__).resolve().parent.parent / "Mods" / "BlackoutMod" / "Sounds" / "flicker.wav"
target.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(target), "wb") as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(RATE)
    f.writeframes((out * 32767).astype("<i2").tobytes())

print(f"Wrote {target} ({LENGTH}s)")
