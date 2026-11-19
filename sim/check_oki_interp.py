#!/usr/bin/env python3
"""Checks sim/tb_oki_interp.sv's log (c s0 s1 s2 s3 y per output) against MAME 0.289's audio_resampler_lofi formula in floating point:
y = -s0 f0(1-p) + s1 f1(1-p) + s2 f1(p) - s3 f0(p), p = c / 6336, f0(t) = (t - t^3) / 6, f1(t) = t + (t^2 - t^3) / 2; the RTL's y is Q16.

  (WSL, in a scratch directory)  verilator --cc --exe --build -Wno-fatal -Wno-WIDTH --top-module tb_oki_interp -Mdir obj \\
                                     <mister>/rtl/ts_audio48.sv <mister>/sim/tb_oki_interp.sv <mister>/sim/tb_oki_interp.cpp && obj/Vtb_oki_interp
  python sim/check_oki_interp.py <oki_interp.txt>
"""
import sys


def f0(t):
    return (t - t ** 3) / 6


def f1(t):
    return t + (t * t - t ** 3) / 2


def main():
    worst, n, total = 0.0, 0, 0.0
    for line in open(sys.argv[1]):
        c, s0, s1, s2, s3, y = (int(x) for x in line.split())
        p = c / 6336
        ref = -s0 * f0(1 - p) + s1 * f1(1 - p) + s2 * f1(p) - s3 * f0(p)
        err = abs(y / 65536 - ref)
        worst = max(worst, err)
        total += err
        n += 1
    print('%d outputs: largest error %.4f, mean %.4f (OKI units: 1 = 1/8192 of full scale)' % (n, worst, total / n))
    sys.exit(0 if worst < 1.0 else 1)


main()
