#!/usr/bin/env python3
"""Compares the RTL bench's pictures (sim/run.sh +SNAPS: <prefix>.pNNNNN.ppm) with MAME's (tools/capture.py: f<N>.rgb) and writes a side-by-side
PNG per pair (MAME | RTL | differences in red).

  python tools/cmp_frame.py <mame states dir> <rtl prefix> <frames> [--offset K] [--out DIR]

  <frames>   MAME frame numbers (a,b,c or a-b/s); the RTL picture compared with MAME's frame N is picture N + K (default K = 0)
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pngio  # noqa: E402

W, H = 320, 240


def frames(spec):
    out = []
    for part in spec.split(','):
        if '-' in part:
            a, rest = part.split('-')
            b, s = rest.split('/')
            out += list(range(int(a), int(b) + 1, int(s)))
        else:
            out.append(int(part))
    return out


def read_ppm(path):
    d = open(path, 'rb').read()
    parts = d.split(b'\n', 3)
    assert parts[0] == b'P6' and parts[1] == b'320 240'
    return parts[3][:W * H * 3]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mame')
    ap.add_argument('rtl')
    ap.add_argument('frames')
    ap.add_argument('--offset', type=int, default=0)
    ap.add_argument('--out', default=None)
    a = ap.parse_args()
    out = a.out or os.path.join(os.path.dirname(a.rtl), 'cmp')
    os.makedirs(out, exist_ok=True)
    for f in frames(a.frames):
        mp = os.path.join(a.mame, 'f%05d.rgb' % f)
        rp = '%s.p%05d.ppm' % (a.rtl, f + a.offset)
        if not (os.path.exists(mp) and os.path.exists(rp)):
            print('frame %d: missing %s' % (f, mp if not os.path.exists(mp) else rp))
            continue
        m = open(mp, 'rb').read()[:W * H * 3]
        r = read_ppm(rp)
        img = bytearray(W * 3 * H * 3)
        nd = 0
        for y in range(H):
            for x in range(W):
                i = (y * W + x) * 3
                o = (y * W * 3 + x) * 3
                img[o:o + 3] = m[i:i + 3]
                img[o + W * 3:o + W * 3 + 3] = r[i:i + 3]
                if m[i:i + 3] != r[i:i + 3]:
                    nd += 1
                    img[o + 2 * W * 3:o + 2 * W * 3 + 3] = b'\xff\x00\x00'
        pngio.write(os.path.join(out, 'cmp_%05d.png' % f), W * 3, H, bytes(img))
        print('frame %5d: %6d of %d pixels differ' % (f, nd, W * H))


if __name__ == '__main__':
    main()
