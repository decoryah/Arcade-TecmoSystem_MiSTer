#!/usr/bin/env python3
"""Compares the Z80's writes to the sound chips, MAME (tools/lua/sndlog.lua) against the bench (sim/run.sh +SNDLOG=): the sequence of
(port, data) in order, then the frame each write falls in.

  python tools/cmp_sndlog.py <mame log> <rtl log> [--offset K] [--mame-start F]     (RTL frame = MAME frame + K; default 0)
"""
import argparse
import collections


def load(p, start):
    out = []
    for line in open(p):
        x = line.split()
        if len(x) != 3:
            continue                                  # (a line cut short when the run ended)
        f, port, d = int(x[0]), int(x[1], 16), int(x[2], 16)
        if out and f < out[-1][0]:
            break                                     # (MAME's Lua output can come back out of order at its exit: keep the ordered part)
        if f >= start:
            out.append((f, port, d))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mame')
    ap.add_argument('rtl')
    ap.add_argument('--offset', type=int, default=0)
    ap.add_argument('--mame-start', type=int, default=0, help='the first MAME frame to compare (e.g. its watchdog reset, 399)')
    a = ap.parse_args()
    m = load(a.mame, a.mame_start)
    r = load(a.rtl, a.mame_start + a.offset)
    last = min(m[-1][0] if m else 0, (r[-1][0] - a.offset) if r else 0)
    m = [x for x in m if x[0] <= last]
    r = [x for x in r if x[0] - a.offset <= last]
    print('writes up to MAME frame %d: MAME %d, RTL %d' % (last, len(m), len(r)))
    names = {0: 'opl', 1: 'opl', 2: 'opl', 3: 'opl', 0x10: 'oki', 0x20: 'okibank', 0x30: 'z80bank', 0x50: 'nmi', 0x60: 'ymz', 0x61: 'ymz'}
    cm = collections.Counter(names[p] for _, p, _ in m)
    cr = collections.Counter(names[p] for _, p, _ in r)
    for k in sorted(set(cm) | set(cr)):
        print('  %-8s MAME %6d  RTL %6d' % (k, cm[k], cr[k]))
    n = min(len(m), len(r))
    first = next((i for i in range(n) if m[i][1:] != r[i][1:]), None)
    if first is None and len(m) == len(r):
        print('the same %d writes in the same order' % n)
    else:
        i = first if first is not None else n
        print('sequences part at write %d:' % i)
        for k in range(max(0, i - 3), min(n, i + 4)):
            print('   %6d  MAME f%5d %02x %02x   RTL f%5d %02x %02x' % (k, m[k][0], m[k][1], m[k][2], r[k][0] - a.offset, r[k][1], r[k][2]))
    same_frame = sum(1 for i in range(min(n, first if first is not None else n)) if m[i][0] == r[i][0] - a.offset)
    print('of the matching writes, %d fall in the same frame' % same_frame)


if __name__ == '__main__':
    main()
