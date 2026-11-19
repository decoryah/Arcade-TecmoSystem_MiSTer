#!/usr/bin/env python3
"""Synthetic stress states for the frozen-state video bench: a captured MAME state with what the attract modes never show switched on at
random -- zoomed sprites (zoom X / Y 0x80..0x300 independently), flips, positions partly off every edge, priorities, palette blend flags
on both palettes, tilemap scroll and flip, the sprite layer's flip (880000 / 880002 bit 15) -- and the core's model's picture of it as the
expected result: tools/flip_study.py's renderer, which is MAME's (tools/ts_ref.py) plus the screen flip of docs/status.md flaw 1.

  python tools/stress.py <set> <states dir> <base frame N> <out dir> <count> [--seed S] [--zmin 0x80] [--zmax 0x300]

Writes <out dir>/f<K>.* and f<K-1>.* for K = 1001, 1003, ... (state K - 1 holds the sprite list, K the rest), f<K>.rgb = the reference
picture.  Then: tools/bench_video.py <set> <out dir> 1001-...
"""
import argparse
import os
import random
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ts_ref as R  # noqa: E402
import flip_study as F  # noqa: E402


def wr(path, ws):
    open(path, 'w').write('\n'.join('%04x' % (w & 0xffff) for w in ws) + '\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('dir')
    ap.add_argument('frame', type=int)
    ap.add_argument('out')
    ap.add_argument('count', type=int)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--zmin', type=lambda s: int(s, 0), default=0x80)
    ap.add_argument('--zmax', type=lambda s: int(s, 0), default=0x300)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    os.makedirs(a.out, exist_ok=True)
    g = R.Gfx(a.set)
    base, basep = os.path.join(a.dir, 'f%05d' % a.frame), os.path.join(a.dir, 'f%05d' % (a.frame - 1))
    for n in range(a.count):
        k = 1001 + 2 * n
        dst, dstp = os.path.join(a.out, 'f%05d' % k), os.path.join(a.out, 'f%05d' % (k - 1))
        for ext in ('.tx', '.bg1', '.bg2', '.bg3'):
            shutil.copy(base + ext, dst + ext)
            shutil.copy(basep + ext, dstp + ext)
        # palettes: blend flags at random
        for ext in ('.pal', '.tpal'):
            ws = R.words(base + ext)
            ws = [(w | 0x8000) if rnd.random() < 0.3 else (w & 0x7fff) for w in ws]
            wr(dst + ext, ws)
            shutil.copy(basep + ext, dstp + ext)
        # scroll / flip of the tilemaps
        lines = open(base + '.regs').read().splitlines()
        sc = [[int(x, 16) for x in l.split()] for l in lines[:4]]
        for t in range(4):
            sc[t][0], sc[t][1], sc[t][2] = rnd.randrange(0x10000), rnd.randrange(0x10000), rnd.randrange(4)
        lines[:4] = [' '.join('%04x' % v for v in s) for s in sc]
        open(dst + '.regs', 'w').write('\n'.join(lines) + '\n')
        # the sprite list (state K - 1): every live entry zoomed / flipped / moved; a few more entries switched on
        lp = open(basep + '.regs').read().splitlines()
        r88 = [int(x, 16) for x in lp[4].split()]
        r88[0], r88[1] = rnd.randrange(0x400) | (0x8000 if rnd.random() < 0.5 else 0), rnd.randrange(0x200) | (0x8000 if rnd.random() < 0.5 else 0)
        lp[4] = ' '.join('%04x' % v for v in r88)
        open(dstp + '.regs', 'w').write('\n'.join(lp) + '\n')
        spr = R.words(basep + '.spr')
        lst = r88[4] & 3
        live = [i for i in range(lst * 0x2000, (lst + 1) * 0x2000, 8) if not spr[i + 4] & 0x8000 and spr[i + 6]]
        for i in live[:48]:
            spr[i + 0] = rnd.randrange(0x400)
            spr[i + 1] = rnd.randrange(0x200)
            spr[i + 2] = rnd.randrange(a.zmin, a.zmax + 1) if rnd.random() < 0.8 else 0x100
            spr[i + 3] = rnd.randrange(a.zmin, a.zmax + 1) if rnd.random() < 0.8 else 0x100
            spr[i + 4] = (spr[i + 4] & 0x3f0f) | (rnd.randrange(4) << 6) | (rnd.randrange(4) << 4)
        for i in live[48:]:
            spr[i + 4] |= 0x8000
        wr(dstp + '.spr', spr)
        shutil.copy(base + '.spr', dst + '.spr')
        img = F.render(g, dst, dstp)
        open(dst + '.rgb', 'wb').write(img)
        print('stress state %d: %d sprites' % (k, min(len(live), 48)))


if __name__ == '__main__':
    main()
