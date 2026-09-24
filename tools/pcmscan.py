#!/usr/bin/env python3
"""pcmscan.py - what is in a testbench sound dump, window by window.

    pcmscan.py FILE.pcm [--from MS] [--window MS] [--min RMS] [--skew]

The dump is the testbench's +WAV= output: raw signed 16-bit little-endian
stereo, one pair an I2S frame - 50625 a second (64.8 MHz / 40 / 32),
not the 44100 of the sample clock, which --rate sets - from +WAV_FROM=
on.  --skew repairs a dump written by the testbench before 24 Sep 2026,
whose receiver took each word a bit early: the low fifteen bits are the
word's top fifteen and the sign is the other side's last bit.  For each window (default 250 ms)
it prints the time (with --from, the machine time the dump started at),
the RMS of each side, the DC offset, the strongest frequency of each side
and its share of the window's power; a window quieter than --min on both
sides (default 100) is folded into "quiet" lines.  That is enough to tell
a 430 Hz sine from a ramp, a square wave from noise, a left-only source
from a right-only one, and silence from any of them.
"""

import argparse

import numpy as np


def scan(path, start_ms, win_ms, min_rms, rate, skew):
    raw = np.fromfile(path, dtype="<i2")
    if len(raw) < 2:
        print("empty")
        return
    if skew:
        raw = ((raw.astype(np.int32) & 0x7FFF) ^ 0x4000) - 0x4000    # the top fifteen bits, signed
        raw = raw * 2                                               # back in place; the LSB is lost
    st = raw[: len(raw) // 2 * 2].reshape(-1, 2).astype(np.float64)
    n = int(rate * win_ms / 1000)
    quiet_from = None
    for i in range(0, len(st) - n + 1, n):
        t = start_ms + i * 1000 / rate
        w = st[i:i + n]
        rms = np.sqrt((w ** 2).mean(axis=0))
        dc = w.mean(axis=0)
        if rms.max() < min_rms:
            if quiet_from is None:
                quiet_from = t
            continue
        if quiet_from is not None:
            print(f"{quiet_from:8.0f} - {t:6.0f} ms  quiet")
            quiet_from = None
        peaks = []
        for side in range(2):
            x = w[:, side] - dc[side]
            spec = np.abs(np.fft.rfft(x * np.hanning(n))) ** 2
            spec[0] = 0
            k = int(spec.argmax())
            share = spec[k - 1:k + 2].sum() / spec.sum() if spec.sum() > 0 else 0
            peaks.append((k * rate / n, share))
        print(f"{t:8.0f} ms  L rms {rms[0]:6.0f} dc {dc[0]:6.0f} peak {peaks[0][0]:6.0f} Hz ({peaks[0][1] * 100:3.0f}%)"
              f"   R rms {rms[1]:6.0f} dc {dc[1]:6.0f} peak {peaks[1][0]:6.0f} Hz ({peaks[1][1] * 100:3.0f}%)")
    if quiet_from is not None:
        print(f"{quiet_from:8.0f} - {start_ms + len(st) * 1000 / rate:6.0f} ms  quiet")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("pcm")
    ap.add_argument("--from", dest="start", type=float, default=0, help="the dump's +WAV_FROM, ms")
    ap.add_argument("--window", type=float, default=250)
    ap.add_argument("--min", type=float, default=100)
    ap.add_argument("--rate", type=float, default=50625, help="pairs a second in the dump")
    ap.add_argument("--skew", action="store_true", help="repair a dump of the old receiver")
    a = ap.parse_args()
    scan(a.pcm, a.start, a.window, a.min, a.rate, a.skew)


if __name__ == "__main__":
    main()
