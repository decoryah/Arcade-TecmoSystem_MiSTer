#!/usr/bin/env python3
"""Fits the sound mixer's three gains (rtl/ts_audio48.sv) to MAME's recording of the same run.

The bench (sim/run.sh +CHIPS=<file>) logs the three chips' outputs at each 48 kHz output sample -- the values ts_audio48 mixes: YMZ280B left /
right, YMF262 left / right (16-bit), OKI (14-bit).  MAME's -wavwrite file is its final mix.  The chips are not sample-identical to MAME's
(opl3_fpga is not ymfm; MAME resamples), so the fit is on power: over 50 ms windows, MAME's mean square against each chip's, assuming the
chips' signals are uncorrelated (their cross terms average out):

    P_mame(w) = sum_i  g_i^2 * P_i(w)          (i = YMZ280B, YMF262, OKI; g_i in the mixer's own units: out = sum g_i * chip_i)

solved by non-negative least squares over the windows with sound, after lining the two files up (the envelope shift that correlates best,
as tools/cmp_audio.py).  Prints the fitted gains, the current ones (ts_audio48's G_* / 256) and their ratio in dB, and each chip's share of
the power (a chip that is nearly silent in the run is not fitted well).

  python tools/fit_mix.py <mame.wav> <chips.txt> [--mame-skip S] [--max-shift-ms 500] [--win-ms 50] [--from S] [--to S]
"""
import argparse
import math
import struct
import wave

CUR = {'ymz': 77 / 256, 'opl': 128 / 256, 'oki': 1024 / 256}


def mame_power(path, skip_s, win):
    w = wave.open(path, 'rb')
    rate, n = w.getframerate(), w.getnframes()
    assert rate == 48000 and w.getsampwidth() == 2 and w.getnchannels() == 2
    w.readframes(int(skip_s * rate))
    d = w.readframes(n - int(skip_s * rate))
    w.close()
    v = struct.unpack('<%dh' % (len(d) // 2), d)
    out = []
    for i in range(0, len(v) // 2 - win, win):
        s = 0
        for j in range(2 * i, 2 * (i + win)):
            s += v[j] * v[j]
        out.append(s / (2 * win))
    return out


def chip_power(path, win):
    ymz, opl, oki = [], [], []
    a = [0, 0, 0]
    k = 0
    for line in open(path):
        x = line.split()
        if len(x) != 5:
            continue
        yl, yr, ol, or_, ok = (int(t) for t in x)
        a[0] += yl * yl + yr * yr
        a[1] += ol * ol + or_ * or_
        a[2] += 2 * ok * ok
        k += 1
        if k == win:
            ymz.append(a[0] / (2 * win)); opl.append(a[1] / (2 * win)); oki.append(a[2] / (2 * win))
            a = [0, 0, 0]
            k = 0
    return ymz, opl, oki


def corr(x, y):
    n = len(x)
    mx, my = sum(x) / n, sum(y) / n
    num = sum((a - mx) * (b - my) for a, b in zip(x, y))
    den = math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y)) or 1
    return num / den


def nnls3(rows, target):
    """Least squares of target ~ rows . c with c >= 0, three unknowns: every subset of the free variables, the best feasible one."""
    import itertools
    best = None
    for k in range(1, 4):
        for sub in itertools.combinations(range(3), k):
            # normal equations on the subset
            m = [[sum(r[i] * r[j] for r in rows) for j in sub] for i in sub]
            b = [sum(r[i] * t for r, t in zip(rows, target)) for i in sub]
            c = solve(m, b)
            if c is None or min(c) < 0:
                continue
            full = [0.0, 0.0, 0.0]
            for i, ci in zip(sub, c):
                full[i] = ci
            err = sum((sum(r[i] * full[i] for i in range(3)) - t) ** 2 for r, t in zip(rows, target))
            if best is None or err < best[0]:
                best = (err, full)
    return best[1] if best else [0.0, 0.0, 0.0]


def solve(m, b):
    n = len(b)
    a = [row[:] + [bb] for row, bb in zip(m, b)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(a[r][c]))
        if abs(a[p][c]) < 1e-30:
            return None
        a[c], a[p] = a[p], a[c]
        for r in range(n):
            if r != c:
                f = a[r][c] / a[c][c]
                for k in range(c, n + 1):
                    a[r][k] -= f * a[c][k]
    return [a[i][n] / a[i][i] for i in range(n)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mame')
    ap.add_argument('chips')
    ap.add_argument('--mame-skip', type=float, default=0.0)
    ap.add_argument('--max-shift-ms', type=int, default=500)
    ap.add_argument('--win-ms', type=int, default=50)
    ap.add_argument('--from', dest='t0', type=float, default=0.0, help='bench seconds to start the fit at')
    ap.add_argument('--to', dest='t1', type=float, default=1e9)
    a = ap.parse_args()
    win = 48 * a.win_ms
    pm = mame_power(a.mame, a.mame_skip, win)
    py, po, pk = chip_power(a.chips, win)
    cur = [CUR['ymz'] ** 2 * y + CUR['opl'] ** 2 * o + CUR['oki'] ** 2 * k for y, o, k in zip(py, po, pk)]
    # line the envelopes up (RMS, as cmp_audio.py)
    em, ec = [math.sqrt(x) for x in pm], [math.sqrt(x) for x in cur]
    n = min(len(em), len(ec))
    best = None
    for sh in range(-a.max_shift_ms // a.win_ms, a.max_shift_ms // a.win_ms + 1):
        idx = [i for i in range(n) if 0 <= i + sh < len(ec)]
        c = corr([em[i] for i in idx], [ec[i + sh] for i in idx])
        if best is None or c > best[0]:
            best = (c, sh)
    c, sh = best
    print('windows: MAME %d, bench %d (%d ms); best envelope correlation %.3f at bench shift %+d ms' % (len(pm), len(py), a.win_ms, c, sh * a.win_ms))
    lo, hi = int(a.t0 * 1000 / a.win_ms), int(a.t1 * 1000 / a.win_ms)
    rows, tgt = [], []
    for i in range(n):
        j = i + sh
        if not (0 <= j < len(py)) or not (lo <= j < hi):
            continue
        if pm[i] < 1e4 and cur[j] < 1e4:              # silence (RMS < 100)
            continue
        rows.append((py[j], po[j], pk[j]))
        tgt.append(pm[i])
    if not rows:
        print('no sound to fit')
        return
    g2 = nnls3(rows, tgt)
    names = ('ymz', 'opl', 'oki')
    tot = [sum(r[i] for r in rows) for i in range(3)]
    print('%d windows with sound' % len(rows))
    print('  chip   fitted gain   current     ratio      share of the fitted power')
    fit_pow = [g2[i] * tot[i] for i in range(3)]
    s = sum(fit_pow) or 1
    for i, nm in enumerate(names):
        g = math.sqrt(g2[i])
        r = g / CUR[nm]
        print('  %-4s   %9.4f   %9.4f   %+6.2f dB   %5.1f %%' % (nm, g, CUR[nm], 20 * math.log10(r) if r > 0 else -99, 100 * fit_pow[i] / s))
    pm_sum = sum(tgt)
    cur_sum = sum(CUR[nm] ** 2 * tot[i] for i, nm in enumerate(names))
    fit_sum = sum(fit_pow)
    print('total power: MAME / current mix %+.2f dB, MAME / fitted mix %+.2f dB' % (10 * math.log10(pm_sum / cur_sum), 10 * math.log10(pm_sum / fit_sum)))
    # how well the fit follows MAME window by window
    fe = [math.sqrt(sum(g2[i] * r[i] for i in range(3))) for r in rows]
    print('envelope correlation over the fitted windows: %.3f' % corr([math.sqrt(t) for t in tgt], fe))


if __name__ == '__main__':
    main()
