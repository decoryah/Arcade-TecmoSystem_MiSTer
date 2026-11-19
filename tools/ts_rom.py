#!/usr/bin/env python3
"""The Tecmo System sets (MAME 0.289 tecmosys.cpp ROM_START blocks) and the two images built from them:

  * the MRA ROM stream (MRA index 0, what the core's loader receives; tools/make_mra.py writes the MRA that assembles it), and
  * the SDRAM image the loader makes of it (rtl/ts_mem.sv's map; the simulation benches preload it).

  python tools/ts_rom.py <set> [--stream out.bin] [--sdram out.bin] [--hdr out.bin] [--romdir DIR]

Stream (TecmoSys.sv):
  0x0000000  0x100      header: byte 0 = protection table (0 deroon, 1 tkdensho, 2 tkdenshoa); bytes 2 + 2s / 3 + 2s = sprite slot s
                        (mode | half << 2, SDRAM base in MB above 0x1000000); the rest 0
  0x0000100  0xA00000   SDRAM image 0x0000000-0x09FFFFF:
                          0x000000 maincpu 1 MB (ROM_LOAD16_BYTE pairs: even file = high byte)   0x200000 layer0 1 MB (512 KB sets twice)
                          0x100000 audiocpu 256 KB (128 KB sets twice, MAME's ROM_RELOAD)        0x300000 layer1 / 0x400000 layer2 / 0x500000 layer3,
                          0x140000 oki 512 KB                                                    1 MB each (deroon's layer1: zeros)
                          0x1C0000 256 KB of zeros                                               0x600000 ymz 4 MB (2 MB sets twice: MAME mirrors)
  0x0A00100  ...        the sprite slots in slot order, each where its table entry says (SDRAM 0x1000000 + base MB):
                          mode 2 (8 bpp): the two ROMs of the slot interleaved word by word (A, B): MAME's ROM_LOAD32_WORD_SWAP pair at 0 / 2
                          mode 1 (4 bpp): the one ROM MAME loads at offset 2 of the slot (the high nibbles are 0)
                        "half": the slot's ROMs fill only its first 4 M pixels.  deroon's 32 M pixel region: slots 4-7 repeat 0-3.
The loader writes the BG tile ROMs (image 0x300000-0x5FFFFF) with each 16 x 16 tile's rows contiguous (byte o of a 128-byte tile ->
{o[6], o[4:2], o[5], o[1:0]}); the SDRAM image here has that order.
"""
import argparse
import os
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402

MB = 1 << 20
IMG_LEN = 0xA00000
SPR_SDRAM = 0x1000000
HDR_LEN = 0x100

# (name, crc32, length)
def R(name, crc, length):
    return (name, crc, length)


# sprite slot: (mode, half, A rom or None, B rom or None)
DEROON_SPR = [
    (2, 1, R('t101.uah1', 0x74baf845, 0x200000), R('t102.ual1', 0x1a02c4a3, 0x200000)),
    (1, 0, None, R('t103.ubl1', 0x84e7da88, 0x400000)),
    (1, 1, None, R('t104.ucl1', 0x66eb611a, 0x200000)),
    (0, 0, None, None),
]
DEROON_COMMON = dict(
    audiocpu=[R('t003.uz1', 0x8bdfafa0, 0x40000)],
    layer0=[R('t301.ubd1', 0x8b026177, 0x100000)],
    layer1=None,
    layer2=[R('t201.ubb1', 0xd5a087ac, 0x100000)],
    layer3=[R('t202.ubc1', 0xf051dae1, 0x100000)],
    ymz=[R('t401.uya1', 0x92111992, 0x200000), R('t401.uya1', 0x92111992, 0x200000)],
    oki=R('t501.uad1', 0x2fbcfe27, 0x80000),
    sprites=DEROON_SPR + DEROON_SPR,          # MAME's mask: the 32 M pixel region repeats
    game=0, year='1995', zip='deroon.zip',
)
TKD_SPR = [
    (2, 0, R('ae100h.ah1', 0x06be252b, 0x400000), R('ae100.al1', 0x009cdff4, 0x400000)),
    (2, 0, R('ae101h.bh1', 0xf2469eff, 0x400000), R('ae101.bl1', 0xdb7791bb, 0x400000)),
    (2, 1, R('ae102h.ch1', 0xf9d2a343, 0x200000), R('ae102.cl1', 0x681be889, 0x200000)),
    (0, 0, None, None),
    (1, 0, None, R('ae104.el1', 0xe431b798, 0x400000)),
    (1, 0, None, R('ae105.fl1', 0xb7f9ebc1, 0x400000)),
    (1, 1, None, R('ae106.gl1', 0x7c50374b, 0x200000)),
    (0, 0, None, None),
]
TKD_COMMON = dict(
    audiocpu=[R('aesprg-2.z1', 0x43550ab6, 0x20000), R('aesprg-2.z1', 0x43550ab6, 0x20000)],
    layer0=[R('ae300w36.bd1', 0xe829f29e, 0x80000), R('ae300w36.bd1', 0xe829f29e, 0x80000)],
    layer1=[R('ae200w74.ba1', 0xc1645041, 0x100000)],
    layer2=[R('ae201w75.bb1', 0x3f63bdff, 0x100000)],
    layer3=[R('ae202w76.bc1', 0x5cc857ca, 0x100000)],
    ymz=[R('ae400t23.ya1', 0xc6ffb043, 0x200000), R('ae401t24.yb1', 0xd83f1a73, 0x200000)],
    oki=R('ae500w07.ad1', 0x3734f92c, 0x80000),
    sprites=TKD_SPR,
    year='1996', zip='tkdensho.zip',
)

SETS = {
    'deroon':    dict(DEROON_COMMON, parent=None, title='Deroon DeroDero (earlier, set 1)',
                      maincpu=(R('t001.upau1', 0x14b92c18, 0x80000), R('t002.upal1', 0x0fb05c68, 0x80000))),
    'deroona':   dict(DEROON_COMMON, parent='deroon', title='Deroon DeroDero (earlier, set 2)', year='1996',
                      maincpu=(R('t01.upau1', 0x7ad6c740, 0x80000), R('t02.upal1', 0xe44f4430, 0x80000))),
    'deroon2':   dict(DEROON_COMMON, parent='deroon', title='Deroon DeroDero - Tecmo Stackers', year='1996',
                      maincpu=(R('stk_t01.upau1', 0x90c794df, 0x80000), R('stk_t02.upal1', 0xcca9f87c, 0x80000))),
    'tkdensho':  dict(TKD_COMMON, parent=None, title='Toukidenshou - Angel Eyes (VER. 960614)', game=1,
                      maincpu=(R('aeprge-2.pal', 0x25e453d6, 0x80000), R('aeprgo-2.pau', 0x22d59510, 0x80000))),
    'tkdenshoa': dict(TKD_COMMON, parent='tkdensho', title='Toukidenshou - Angel Eyes (VER. 960427)', game=2,
                      maincpu=(R('aeprge.pal', 0x17a209ff, 0x80000), R('aeprgo.pau', 0xd265e6a1, 0x80000))),
}


def slot_layout(s):
    """Per slot: (mode, half, base MB, A, B, bytes); slots whose entry repeats an earlier one (deroon) share its data."""
    out, base, seen = [], 0, {}
    for mode, half, a, b in s['sprites']:
        key = (mode, half, a, b)
        if mode == 0:
            out.append((0, 0, 0, None, None, 0))
            continue
        if key in seen:
            out.append(seen[key][:5] + (0,))
            continue
        size = (4 * MB if half else 8 * MB) if mode == 2 else (2 * MB if half else 4 * MB)
        e = (mode, half, base, a, b, size)
        seen[key] = e
        out.append(e)
        base += size // MB
    return out


def header(s):
    h = bytearray(HDR_LEN)
    h[0] = s['game']
    for i, (mode, half, base, _a, _b, _n) in enumerate(slot_layout(s)):
        h[2 + 2 * i] = mode | (half << 2)
        h[3 + 2 * i] = base
    return bytes(h)


class RomSet:
    """Files by CRC from the merged zip (clones' files may sit in a subfolder) or a directory."""

    def __init__(self, romdir, zipname):
        self.files = {}
        p = os.path.join(romdir, zipname)
        if os.path.isdir(p):
            for root, _d, fs in os.walk(p):
                for f in fs:
                    data = open(os.path.join(root, f), 'rb').read()
                    self.files[zlib.crc32(data) & 0xffffffff] = data
        else:
            with zipfile.ZipFile(p) as z:
                for info in z.infolist():
                    if not info.is_dir():
                        self.files[info.CRC] = z.read(info)

    def get(self, rom):
        name, crc, length = rom
        if crc not in self.files:
            sys.exit('missing ROM %s (crc %08x)' % (name, crc))
        d = self.files[crc]
        if len(d) != length:
            sys.exit('ROM %s: %d bytes, expected %d' % (name, len(d), length))
        return d


def interleave16(even, odd):
    out = bytearray(len(even) * 2)
    out[0::2] = even
    out[1::2] = odd
    return bytes(out)


def interleave32(a, b):
    """MRA <interleave output="32">: A map "0021", B map "2100": A0 A1 B0 B1 per 32-bit unit."""
    out = bytearray(len(a) * 2)
    out[0::4] = a[0::2]
    out[1::4] = a[1::2]
    out[2::4] = b[0::2]
    out[3::4] = b[1::2]
    return bytes(out)


def low_image(s, rs):
    img = bytearray(IMG_LEN)
    img[0x000000:0x100000] = interleave16(rs.get(s['maincpu'][0]), rs.get(s['maincpu'][1]))
    img[0x100000:0x140000] = b''.join(rs.get(r) for r in s['audiocpu'])
    img[0x140000:0x1C0000] = rs.get(s['oki'])
    for name, at in (('layer0', 0x200000), ('layer1', 0x300000), ('layer2', 0x400000), ('layer3', 0x500000)):
        if s[name]:
            img[at:at + MB] = b''.join(rs.get(r) for r in s[name])
    img[0x600000:0xA00000] = b''.join(rs.get(r) for r in s['ymz'])
    return img


def sprite_area(s, rs):
    lay = slot_layout(s)
    total = max((b * MB + n for (_m, _h, b, _a, _bb, n) in lay), default=0)
    area = bytearray(total)
    for mode, half, base, a, b, n in lay:
        if n == 0:
            continue
        data = interleave32(rs.get(a), rs.get(b)) if mode == 2 else rs.get(b)
        assert len(data) == n
        area[base * MB:base * MB + n] = data
    return bytes(area)


def stream(s, rs):
    return header(s) + bytes(low_image(s, rs)) + sprite_area(s, rs)


def bg_remap(o):
    """Byte o of a 128-byte MAME 16 x 16 tile (TL, TR, BL, BR blocks of 32 bytes) -> its place with the tile's rows contiguous."""
    return (o & ~0x7f) | (o & 0x40) | ((o & 0x1c) << 1) | ((o & 0x20) >> 3) | (o & 0x03)


def sdram(s, rs):
    img = low_image(s, rs)
    out = bytearray(SPR_SDRAM)
    out[0:0x300000] = img[0:0x300000]
    perm = [bg_remap(o) for o in range(128)]
    for t in range(0x300000, 0x600000, 128):
        tile = img[t:t + 128]
        for o in range(128):
            out[t + perm[o]] = tile[o]
    out[0x600000:IMG_LEN] = img[0x600000:IMG_LEN]
    return bytes(out) + sprite_area(s, rs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set', choices=sorted(SETS))
    ap.add_argument('--stream')
    ap.add_argument('--sdram')
    ap.add_argument('--hdr', help='the 256-byte header of the stream alone (the simulation bench reads it)')
    ap.add_argument('--romdir', default=paths.ROMS)
    a = ap.parse_args()
    s = SETS[a.set]
    rs = RomSet(a.romdir, s['zip'])
    if a.stream:
        open(a.stream, 'wb').write(stream(s, rs))
    if a.sdram:
        open(a.sdram, 'wb').write(sdram(s, rs))
    if a.hdr:
        open(a.hdr, 'wb').write(header(s))
    for i, e in enumerate(slot_layout(s)):
        print('slot %d: mode %d half %d base %2d MB  %s %s' % (i, e[0], e[1], e[2], e[3][0] if e[3] else '-', e[4][0] if e[4] else '-'))


if __name__ == '__main__':
    main()
