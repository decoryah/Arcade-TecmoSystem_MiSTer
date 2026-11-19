#!/usr/bin/env python3
"""Reference renderer of the Tecmo System video: MAME 0.289 tecmosys_v.cpp (screen_update, render_sprites_to_bitmap, tilemap_copy_to_compose,
do_final_mix) transcribed, drawing from the states tools/capture.py dumps, graphics read from tools/ts_rom.py's SDRAM image the way the core
reads them (tools/check_gfx.py checks that against MAME's decode).

MAME's picture of frame N = the tilemaps and palettes of state N + the sprite bitmap drawn at frame N - 1 (from the sprite RAM and 880000
registers of state N - 1): capture both frames.

  python tools/ts_ref.py <set> <states dir> <frames> [--png DIR]       compares with MAME's own pixels (f<N>.rgb)
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import pngio  # noqa: E402
import ts_rom as T  # noqa: E402
from check_gfx import core_sprite_pixel  # noqa: E402

W, H = 320, 240


def words(path):
    return [int(x, 16) for x in open(path).read().split()]


def regs(path):
    lines = open(path).read().splitlines()
    sc = [[int(x, 16) for x in l.split()] for l in lines[:4]]
    r88 = [int(x, 16) for x in lines[4].split()]
    return sc, r88


def pal5(v):
    return (v << 3) | (v >> 2)


def rgb(v):
    return (pal5((v >> 5) & 31), pal5((v >> 10) & 31), pal5(v & 31))


class Gfx:
    def __init__(self, setname):
        s = T.SETS[setname]
        rs = T.RomSet(paths.ROMS, s['zip'])
        self.sd = T.sdram(s, rs)
        self.hdr = T.header(s)
        self.mask = (1 << 25) - 1 if s['sprites'][:4] == s['sprites'][4:] else (1 << 26) - 1
        self.cache = {}

    def spr(self, p):
        p &= self.mask
        v = self.cache.get(p)
        if v is None:
            v = self.cache[p] = core_sprite_pixel(self.sd, self.hdr, p)
        return v

    def tile(self, layer, code, x, y):
        if layer == 0:
            b = self.sd[0x200000 + (code & 0x7fff) * 32 + y * 4 + x // 2]
        else:
            b = self.sd[0x200000 + layer * 0x100000 + (code & 0x1fff) * 128 + y * 8 + x // 2]
        return (b >> 4) if x % 2 == 0 else (b & 15)


def draw_tilemap(g, layer, vram, sc):
    """MAME's tilemap draw into a 320 x 240 ind16 bitmap: 0 = transparent, else colour * 16 + pen (+ the gfx base, masked away later)."""
    big = layer != 0
    ts = 16 if big else 8
    cols = 32 if big else 64
    if layer == 0:
        sx, sy = 0, 0
    elif layer == 1:
        sx, sy = sc[0] + 104, sc[1] + 16
    else:
        sx, sy = sc[0] + 106, sc[1] + 17
    fx, fy = sc[2] & 1, (sc[2] >> 1) & 1
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        ly = ((511 - y + sy) if fy else (y + sy)) & 511
        for x in range(W):
            lx = ((511 - x + sx) if fx else (x + sx)) & 511
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
    """render_sprites_to_bitmap with the full visible area as clip."""
    bm = [[0] * W for _ in range(H)]
    extrax, extray = r88[0], r88[1]
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
        address = (spr[i + 5] | ((spr[i + 4] & 0xf) << 16)) << 8
        flipx = (spr[i + 4] >> 6) & 1
        flipy = (spr[i + 4] >> 7) & 1
        zoomx = spr[i + 2] & 0xfff
        zoomy = spr[i + 3] & 0xfff
        ysize = (spr[i + 6] & 0xff) * 16
        xsize = (spr[i + 6] >> 8) * 16
        colour = spr[i + 4] & 0x3f00
        priority = (spr[i + 4] & 0x30) << 10
        if zoomx == 0x100 and zoomy == 0x100:
            zx = zy = 0x100
        elif zoomx > 0 and zoomy > 0:
            zx, zy = zoomx, zoomy
        else:
            continue
        # (the unzoomed path of MAME is the zoomed one with 0x100: same clipping, same pixels)
        dxb = x << 8
        srcx = 0
        while dxb < 0:
            dxb += zx
            srcx += 1
            if srcx >= xsize:
                break
        if srcx >= xsize or dxb >= W << 8:
            continue
        dy = y << 8
        srcy = 0
        while dy < 0:
            dy += zy
            srcy += 1
            if srcy >= ysize:
                break
        if srcy >= ysize or dy >= H << 8:
            continue
        ycnt = srcy
        while dy < H << 8 and ycnt < ysize:
            ressy = (ysize - 1 - ycnt) if flipy else ycnt
            srcoffs = address + ressy * xsize
            row = bm[dy >> 8]
            dx, xcnt = dxb, srcx
            while dx < W << 8 and xcnt < xsize:
                ressx = (xsize - 1 - xcnt) if flipx else xcnt
                d = g.spr(srcoffs + ressx)
                if d:
                    row[dx >> 8] = (d + colour) | priority
                xcnt += 1
                dx += zx
            ycnt += 1
            dy += zy
    return bm


def render(g, st, st_prev):
    sc, _r88 = regs(st + '.regs')
    _scp, r88p = regs(st_prev + '.regs')
    comp = [[0] * W for _ in range(H)]
    for layer, vf, pri in ((1, '.bg1', 0x0000), (2, '.bg2', 0x4000), (3, '.bg3', 0x8000), (0, '.tx', 0xc000)):
        tm = draw_tilemap(g, layer, words(st + vf), sc[layer])
        for y in range(H):
            for x in range(W):
                v = tm[y][x]
                if v & 0xf:
                    comp[y][x] = (v & 0x7ff) | pri
    sb = render_sprites(g, words(st_prev + '.spr'), r88p)
    tpal = words(st + '.tpal')
    pal = words(st + '.pal')
    out = bytearray(W * H * 3)
    for y in range(H):
        for x in range(W):
            c, s = comp[y][x], sb[y][x]
            pri, pri2 = c & 0xc000, s & 0xc000
            penvalue = tpal[c & 0x7ff]
            colour = rgb(penvalue)
            if s & 0xff:
                penvalue2, colour2, mask, transp = pal[s & 0x3fff], rgb(pal[s & 0x3fff]), s & 0xff, False
            elif c & 0xf:
                penvalue2, colour2, mask, transp = penvalue, colour, c & 0xf, False
            else:
                penvalue2, colour2, mask, transp = pal[0x3f00], rgb(pal[0x3f00]), 0, True
            bgc = colour if (c & 0xf) else rgb(pal[0x3f00])
            if transp:
                if (penvalue & 0x8000) and (c & 0xf) and (penvalue2 & 0x8000):
                    px = tuple((a + b) >> 1 for a, b in zip(colour, colour2))
                else:
                    px = bgc
            else:
                if (penvalue & 0x8000) and (c & 0xf) and (penvalue2 & 0x8000) and mask:
                    px = tuple((a + b) >> 1 for a, b in zip(colour, colour2))
                elif pri2 >= pri and mask:
                    px = colour2
                else:
                    px = bgc
            out[(y * W + x) * 3:(y * W + x) * 3 + 3] = bytes(px)
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('dir')
    ap.add_argument('frames')
    ap.add_argument('--png')
    a = ap.parse_args()
    g = Gfx(a.set)
    fl = []
    for part in a.frames.split(','):
        if '-' in part:
            lo, rest = part.split('-'); hi, st = rest.split('/')
            fl += list(range(int(lo), int(hi) + 1, int(st)))
        else:
            fl.append(int(part))
    bad = 0
    for f in fl:
        st, sp = os.path.join(a.dir, 'f%05d' % f), os.path.join(a.dir, 'f%05d' % (f - 1))
        if not (os.path.exists(st + '.regs') and os.path.exists(sp + '.regs')):
            print('frame %d: needs states %d and %d' % (f, f - 1, f))
            continue
        img = render(g, st, sp)
        m = open(st + '.rgb', 'rb').read()[:W * H * 3]
        nd = sum(1 for i in range(0, W * H * 3, 3) if img[i:i + 3] != m[i:i + 3])
        bad += nd != 0
        print('frame %5d: %6d pixels differ from MAME' % (f, nd))
        if a.png:
            os.makedirs(a.png, exist_ok=True)
            pngio.write(os.path.join(a.png, 'ref_%05d.png' % f), W, H, img)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
