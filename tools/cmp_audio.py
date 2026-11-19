#!/usr/bin/env python3
"""Compares two 16-bit stereo WAVs (MAME's -wavwrite and the bench's +WAV=) by their loudness envelopes: RMS per 50 ms window, the time
offset that lines the envelopes up best, and the level ratio after that.  (Not sample-identical by design: the YMF262 is opl3_fpga, not
ymfm, and MAME mixes in floating point; this checks that the same sounds start at the same moments at the same levels.)

  python tools/cmp_audio.py <mame.wav> <rtl.wav> [--max-shift-ms 500] [--mame-skip S]
"""
import argparse
import math
import struct
import sys
import wave


def env(path, win_ms=50, skip_s=0.0):
    w = wave.open(path, 'rb')
    ch, sw, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    w.readframes(int(skip_s * rate))
    n -= int(skip_s * rate)
    data = w.readframes(n)
    w.close()
    assert sw == 2
    vals = struct.unpack('<%dh' % (len(data) // 2), data)
    win = rate * win_ms // 1000
    out = []
    for i in range(0, n - win, win):
        s = 0.0
        for j in range(i * ch, (i + win) * ch):
            s += vals[j] * vals[j]
        out.append(math.sqrt(s / (win * ch)))
    return out, rate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mame')
    ap.add_argument('rtl')
    ap.add_argument('--max-shift-ms', type=int, default=500)
    ap.add_argument('--mame-skip', type=float, default=0.0, help='seconds of the MAME file to skip (e.g. a bench run with a shorter watchdog)')
    a = ap.parse_args()
    m, rm = env(a.mame, skip_s=a.mame_skip)
    r, rr = env(a.rtl)
    print('MAME %d Hz %.1f s, RTL %d Hz %.1f s' % (rm, len(m) * 0.05, rr, len(r) * 0.05))
    n = min(len(m), len(r))
    best = None
    for sh in range(-a.max_shift_ms // 50, a.max_shift_ms // 50 + 1):
        pairs = [(m[i], r[i + sh]) for i in range(n) if 0 <= i + sh < len(r)]
        mm = sum(p[0] for p in pairs) / len(pairs)
        rv = sum(p[1] for p in pairs) / len(pairs)
        num = sum((p[0] - mm) * (p[1] - rv) for p in pairs)
        den = math.sqrt(sum((p[0] - mm) ** 2 for p in pairs) * sum((p[1] - rv) ** 2 for p in pairs)) or 1
        c = num / den
        if best is None or c > best[0]:
            best = (c, sh, mm, rv)
    c, sh, mm, rv = best
    print('best envelope correlation %.3f at RTL shift %+d ms; mean RMS MAME %.0f RTL %.0f (ratio %.2f, %.1f dB)' %
          (c, sh * 50, mm, rv, rv / mm if mm else 0, 20 * math.log10(rv / mm) if mm and rv else 0))
    for t in range(0, n, 20):
        print('  %5.1f s  MAME %6.0f  RTL %6.0f' % (t * 0.05, m[t], r[t + sh] if 0 <= t + sh < len(r) else -1))


if __name__ == '__main__':
    main()
