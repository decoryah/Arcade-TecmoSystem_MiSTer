#!/usr/bin/env python3
"""MAME flaw 1 (docs/status.md): the screen flip.  Two MAME runs of the same play, one with the game's screen-invert flag poked on
(tools/capture.py --poke 2005b3:1:<frame>, tkdensho), give states that differ only in what the game writes for the inverted screen: every
scroll register + 0x20 / + 0x116, the flip words (3, text 0x13), the sprite offsets + 0x30 / + 0xf4 with bit 15 set.  The inverted picture
must be the normal one turned 180 degrees.  This renders the inverted state with the flip model below and compares it with MAME's normal
picture turned around.

The model (constants from the game's compensation offsets):
  tilemaps   not flipped: logical = screen + scroll + offset (BG1 104 / 16, BG2 and BG3 106 / 17); the text layer: logical = screen
             flipped:     logical = FX - x + scroll + offset, FY - y + scroll + offset (FX = 319 - 0x20 = 287, FY = 239 - 0x116 = -39);
                          the text layer: 319 - x, 239 - y
             (the text layer's scroll registers -- 018e / 01ee in tkdensho, 018e / 01ef in deroon -- applied with offsets 114 / 18 would
             rotate as well: this test cannot tell; ignoring them keeps MAME's unflipped picture of both games)
  sprites    880000 bit 15: every sprite pixel's x (MAME's formula, the offset's low 10 bits) is mirrored: x' = SX - x (SX = 319 - 0x30 = 271)
             880002 bit 15: every pixel's line likewise: y' = SY - y (SY = 239 - 0xf4 = -5)

  python tools/flip_study.py <normal states dir> <inverted states dir> <frames> [--png DIR]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pngio  # noqa: E402
import ts_ref as R  # noqa: E402

W, H = 320, 240
OFFS = {1: (104, 16), 2: (106, 17), 3: (106, 17)}
FX, FY = 319 - 0x20, 239 - 0x116
SX, SY = 319 - 0x30, 239 - 0xf4


def draw_tilemap(g, layer, vram, sc):
    big = layer != 0
    ts = 16 if big else 8
    cols = 32 if big else 64
    fx, fy = sc[2] & 1, (sc[2] >> 1) & 1
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        if layer == 0:
            ly = (H - 1 - y) if fy else y
        else:
            ly = (((FY - y) if fy else y) + sc[1] + OFFS[layer][1]) & 511
        for x in range(W):
            if layer == 0:
                lx = (W - 1 - x) if fx else x
            else:
                lx = (((FX - x) if fx else x) + sc[0] + OFFS[layer][0]) & 511
            idx = (ly // ts) * cols + (lx // ts)
            attr, code = vram[2 * idx], vram[2 * idx + 1]
            px, py = lx % ts, ly % ts
            if attr & 0x40:
                px = ts - 1 - px
            if attr & 0x80:
                py = ts - 1 - py
            pen = g.tile(layer, code, px, py)
            if pen:
                out[y][x] = ((attr & 0x3f) * 16 + pen) | (0x400 if layer == 0 else 0)
    return out


def render_sprites(g, spr, r88):
    """MAME's drawing into a bitmap wide enough for the mirrored windows, then the mirror."""
    mx, my = r88[0] >> 15, r88[1] >> 15
    x0 = (SX - (W - 1)) if mx else 0          # the window of MAME-formula positions that land on the screen
    y0 = (SY - (H - 1)) if my else 0
    bm = [[0] * W for _ in range(H)]
    extrax, extray = r88[0] & 0x7fff, r88[1] & 0x7fff
    lst = r88[4] & 3
    for i in range(lst * 0x2000, (lst + 1) * 0x2000, 8):
        if spr[i + 4] & 0x8000:
            continue
        x = (spr[i + 0] + 386 - extrax) & 0x3ff
        y = (spr[i + 1] + 1 - extray) & 0x1ff
        if x & 0x200:
            x -= 0x400
        if y & 0x100:
            y -= 0x200
        x -= x0
        y -= y0
        address = (spr[i + 5] | ((spr[i + 4] & 0xf) << 16)) << 8
        flipx, flipy = (spr[i + 4] >> 6) & 1, (spr[i + 4] >> 7) & 1
        zx, zy = spr[i + 2] & 0xfff, spr[i + 3] & 0xfff
        ysize, xsize = (spr[i + 6] & 0xff) * 16, (spr[i + 6] >> 8) * 16
        colour, priority = spr[i + 4] & 0x3f00, (spr[i + 4] & 0x30) << 10
        if not (zx > 0 and zy > 0):
            continue
        for ycnt in range(ysize):
            dy = (y << 8) + ycnt * zy
            if dy < 0 or dy >= H << 8:
                continue
            ressy = (ysize - 1 - ycnt) if flipy else ycnt
            for xcnt in range(xsize):
                dx = (x << 8) + xcnt * zx
                if dx < 0 or dx >= W << 8:
                    continue
                ressx = (xsize - 1 - xcnt) if flipx else xcnt
                d = g.spr(address + ressy * xsize + ressx)
                if d:
                    sx_, sy_ = dx >> 8, dy >> 8
                    if mx:
                        sx_ = W - 1 - sx_
                    if my:
                        sy_ = H - 1 - sy_
                    bm[sy_][sx_] = (d + colour) | priority
    return bm


def render(g, st, stp):
    sc, _ = R.regs(st + '.regs')
    _, r88p = R.regs(stp + '.regs')
    comp = [[0] * W for _ in range(H)]
    for layer, vf, pri in ((1, '.bg1', 0x0000), (2, '.bg2', 0x4000), (3, '.bg3', 0x8000), (0, '.tx', 0xc000)):
        tm = draw_tilemap(g, layer, R.words(st + vf), sc[layer])
        for y in range(H):
            for x in range(W):
                if tm[y][x] & 0xf:
                    comp[y][x] = (tm[y][x] & 0x7ff) | pri
    sb = render_sprites(g, R.words(stp + '.spr'), r88p)
    tpal, pal = R.words(st + '.tpal'), R.words(st + '.pal')
    out = bytearray(W * H * 3)
    for y in range(H):
        for x in range(W):
            c, s = comp[y][x], sb[y][x]
            tc, bgc = R.rgb(tpal[c & 0x7ff]), R.rgb(pal[0x3f00])
            if not (s & 0xff):
                px = tc if (c & 0xf) else bgc
            elif (c & 0xf) and (tpal[c & 0x7ff] & 0x8000) and (pal[s & 0x3fff] & 0x8000):
                px = tuple((a + b) >> 1 for a, b in zip(tc, R.rgb(pal[s & 0x3fff])))
            elif (s & 0xc000) >= (c & 0xc000):
                px = R.rgb(pal[s & 0x3fff])
            else:
                px = tc
            out[(y * W + x) * 3:(y * W + x) * 3 + 3] = bytes(px)
    return bytes(out)


def rot180(img):
    out = bytearray(len(img))
    for i in range(W * H):
        j = W * H - 1 - i
        out[j * 3:j * 3 + 3] = img[i * 3:i * 3 + 3]
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('norm')
    ap.add_argument('inv')
    ap.add_argument('frames')
    ap.add_argument('--png')
    a = ap.parse_args()
    g = R.Gfx('tkdensho')
    bad = 0
    for f in [int(x) for x in a.frames.split(',')]:
        n, i = os.path.join(a.norm, 'f%05d' % f), os.path.join(a.inv, 'f%05d' % f)
        ip = os.path.join(a.inv, 'f%05d' % (f - 1))
        mame_n = open(n + '.rgb', 'rb').read()[:W * H * 3]
        ours_n = render(g, n, os.path.join(a.norm, 'f%05d' % (f - 1)))
        dn = sum(1 for k in range(0, W * H * 3, 3) if ours_n[k:k + 3] != mame_n[k:k + 3])
        want = rot180(mame_n)
        got = render(g, i, ip)
        d = sum(1 for k in range(0, W * H * 3, 3) if got[k:k + 3] != want[k:k + 3])
        mame_i = open(i + '.rgb', 'rb').read()[:W * H * 3]
        dm = sum(1 for k in range(0, W * H * 3, 3) if mame_i[k:k + 3] != want[k:k + 3])
        print('frame %d: model, normal vs MAME: %d px; model, inverted vs MAME normal turned 180: %d px (MAME\'s own inverted: %d px)' % (f, dn, d, dm))
        bad += (d != 0) or (dn != 0)
        if a.png:
            os.makedirs(a.png, exist_ok=True)
            img = bytearray(W * 3 * H * 3)
            for y in range(H):
                for k, im in enumerate((want, got, mame_i)):
                    o = (y * W * 3 + k * W) * 3
                    img[o:o + W * 3] = im[y * W * 3:(y + 1) * W * 3]
            pngio.write(os.path.join(a.png, 'flip_%05d.png' % f), W * 3, H, bytes(img[:W * 3 * H * 3]))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
