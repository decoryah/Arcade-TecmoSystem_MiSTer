#!/usr/bin/env python3
"""Checks the core's graphics fetch formats against MAME's own decode of the same ROMs.

MAME side: the regions as tecmosys.cpp loads them (ROM_LOAD32_WORD_SWAP for the sprites) decoded with MAME's generic gfx_element::decode
semantics (bit b of the region = byte b / 8, mask 0x80 >> (b % 8); plane 0 is the pixel's top bit) and the driver's layouts:
gfx_sprite (16 x 1, 8 planes {0-3, 16-19}, x offsets STEP4(0,4) STEP4(32,4) STEP4(64,4) STEP4(96,4), 128 bits / element: the descrambled
sprite pixel array), gfx_8x8x4_packed_msb (text) and gfx_8x8x4_row_2x2_group_packed_msb (BG).

Core side: the SDRAM image of tools/ts_rom.py read the way rtl/ts_sprites.sv (slot table, word pairs / single words, nibble order) and
rtl/ts_tiles.sv (a tile row = 2 / 4 words, high nibble first) read it.

  python tools/check_gfx.py <set> [--samples N]
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import ts_rom as T  # noqa: E402


def mame_sprite_region(s, rs):
    """The "sprites" region: ROM_LOAD32_WORD_SWAP of A at slot * 8 MB + 0, B at + 2 (deroon's region is 32 MB, tkdensho's 64 MB)."""
    nslots = 4 if s['sprites'][:4] == s['sprites'][4:] else 8
    reg = bytearray(nslots * 8 * T.MB)
    for i, (mode, half, a, b) in enumerate(s['sprites'][:nslots]):
        for rom, off in ((a, 0), (b, 2)):
            if rom is None:
                continue
            d = rs.get(rom)
            base = i * 8 * T.MB + off
            # ROM_LOAD32_WORD_SWAP: two bytes per 4, swapped
            reg[base + 0:base + 2 * len(d):4] = d[1::2]
            reg[base + 1:base + 1 + 2 * len(d):4] = d[0::2]
    return reg


def bit(reg, b):
    return (reg[b >> 3] >> (7 - (b & 7))) & 1


def mame_sprite_pixel(reg, p):
    """Pixel p of MAME's descrambled array: element p // 16, pixel x = p % 16 of its one row."""
    planes = [0, 1, 2, 3, 16, 17, 18, 19]
    xoff = [0, 4, 8, 12, 32, 36, 40, 44, 64, 68, 72, 76, 96, 100, 104, 108]
    e, x = divmod(p, 16)
    v = 0
    for pl, po in enumerate(planes):
        if bit(reg, e * 128 + po + xoff[x]):
            v |= 1 << (7 - pl)
    return v


def core_sprite_pixel(sd, hdr, p):
    s = (p >> 23) & 7
    mode, half, base = hdr[2 + 2 * s] & 3, (hdr[2 + 2 * s] >> 2) & 1, hdr[3 + 2 * s]
    q = p & 0x7fffff
    if mode == 0 or (half and (q >> 22) & 1):
        return 0
    g, sub = divmod(q, 4)
    bw = T.SPR_SDRAM + base * T.MB

    def word(w):
        return (sd[w * 2] << 8) | sd[w * 2 + 1]
    if mode == 2:
        a, b = word(bw // 2 + 2 * g), word(bw // 2 + 2 * g + 1)
    else:
        a, b = 0, word(bw // 2 + g)
    sh = [4, 0, 12, 8][sub]
    return (((a >> sh) & 15) << 4) | ((b >> sh) & 15)


def mame_tile_pixel(reg, code, x, y, big):
    if big:
        xoff = [0, 4, 8, 12, 16, 20, 24, 28, 256, 260, 264, 268, 272, 276, 280, 284]
        yoff = [i * 32 for i in range(8)] + [512 + i * 32 for i in range(8)]
        inc = 1024
    else:
        xoff = [0, 4, 8, 12, 16, 20, 24, 28]
        yoff = [i * 32 for i in range(8)]
        inc = 256
    v = 0
    for pl in range(4):
        if bit(reg, code * inc + pl + yoff[y] + xoff[x]):
            v |= 1 << (3 - pl)
    return v


def core_tile_pixel(sd, base, code, x, y, big):
    if big:
        row = base + code * 128 + y * 8
        b = sd[row + x // 2]
    else:
        row = base + code * 32 + y * 4
        b = sd[row + x // 2]
    return (b >> 4) if x % 2 == 0 else (b & 15)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set', choices=sorted(T.SETS))
    ap.add_argument('--samples', type=int, default=200000)
    ap.add_argument('--romdir', default=paths.ROMS)
    a = ap.parse_args()
    s = T.SETS[a.set]
    rs = T.RomSet(a.romdir, s['zip'])
    sd = T.sdram(s, rs)
    hdr = T.header(s)
    reg = mame_sprite_region(s, rs)
    rnd = random.Random(1)
    bad = 0
    n = len(reg)
    for _ in range(a.samples):
        p = rnd.randrange(n)
        m, c = mame_sprite_pixel(reg, p), core_sprite_pixel(sd, hdr, p)
        if m != c:
            bad += 1
            if bad < 10:
                print('sprite pixel %07x: MAME %02x core %02x' % (p, m, c))
    print('sprites: %d random pixels of %d M, %d differ' % (a.samples, n >> 20, bad))
    tb = 0
    for name, big, base in (('layer0', False, 0x200000), ('layer1', True, 0x300000), ('layer2', True, 0x400000), ('layer3', True, 0x500000)):
        if not s[name]:
            continue
        r = b''.join(rs.get(x) for x in s[name])
        r = (r * 2)[:T.MB] if len(r) < T.MB else r
        ntiles = T.MB // (128 if big else 32)
        for _ in range(a.samples // 10):
            code, x, y = rnd.randrange(ntiles), rnd.randrange(16 if big else 8), rnd.randrange(16 if big else 8)
            m, c = mame_tile_pixel(r, code, x, y, big), core_tile_pixel(sd, base, code, x, y, big)
            if m != c:
                tb += 1
                if tb < 10:
                    print('%s tile %d (%d, %d): MAME %x core %x' % (name, code, x, y, m, c))
    print('tiles: %d differ' % tb)
    sys.exit(1 if bad or tb else 0)


if __name__ == '__main__':
    main()
