#!/usr/bin/env python3
"""Check the RAMs Quartus actually built against the depths the RTL declares (the owner's supduck-mister tool, this core's list).

    check_ram_depth.py <TecmoSys.fit.rpt> [--list]

A simulator evaluates an array exactly as declared; Quartus 17 does not always (a two-dimensional unpacked array was once built half as deep,
invisible in every bench and broken on the board).  Run this on every fit report; it exits 1 if a listed memory is shallower than its
minimum, or is missing.
"""
import re
import sys

# (instance name fragment, minimum words, minimum width)
EXPECT = [
    # the 68000 board (ts_main): work RAM and line RAMs (ts_spram: two byte-wide halves), the video RAMs / palettes / sprite RAM (ts_tdpram)
    ("ts_main:u_main|ts_spram:u_wram|altsyncram:mem_h", 32768, 8),
    ("ts_main:u_main|ts_spram:u_wram|altsyncram:mem_l", 32768, 8),
    ("ts_main:u_main|ts_spram:u_l1|altsyncram:mem_h", 512, 8),
    ("ts_main:u_main|ts_spram:u_l3|altsyncram:mem_l", 512, 8),
    ("ts_main:u_main|ts_tdpram:u_bg1|altsyncram", 2048, 16),
    ("ts_main:u_main|ts_tdpram:u_bg2|altsyncram", 2048, 16),
    ("ts_main:u_main|ts_tdpram:u_bg3|altsyncram", 2048, 16),
    ("ts_main:u_main|ts_tdpram:u_tx|altsyncram", 8192, 16),
    ("ts_main:u_main|ts_tdpram:u_spr|altsyncram", 32768, 16),
    ("ts_main:u_main|ts_tdpram:u_spal|altsyncram", 16384, 16),
    ("ts_main:u_main|ts_tdpram:u_tpal|altsyncram", 2048, 16),
    # the video: line buffers (two banks of 512), the sprite engine's tables (1024 sprites)
    ("ts_video:u_video|ts_tdpram:u_lbt|altsyncram", 1024, 16),
    ("ts_video:u_video|ts_tdpram:u_lbs|altsyncram", 1024, 16),
    ("ts_sprites:u_spr|ts_sdpram_w:u_st|altsyncram", 1024, 31),
    ("ts_sprites:u_spr|ts_sdpram_w:u_g|altsyncram", 1024, 20),
    ("ts_sprites:u_spr|ts_sdpram_w:u_d|altsyncram", 1024, 87),
    # the sound board: Z80 RAM (8 KB window), the YMZ280B's write queue
    ("ts_sound:u_sound|ts_spram8:u_ram|altsyncram", 8192, 8),
    ("ts_ymz280b:u_ymz|altsyncram:fifo", 64, 16),
    # the program caches
    ("ts_rcache:u_mc|altsyncram:dat_ram", 1024, 16),
    ("ts_rcache:u_mc|altsyncram:tag_ram", 128, 9),
    ("ts_zcache:u_zc|ts_rcache:u_c|altsyncram:dat_ram", 1024, 16),
]


def main():
    path = sys.argv[1]
    ram = []
    for line in open(path, errors="replace"):
        if "|ALTSYNCRAM" not in line or not line.startswith(";"):
            continue
        f = [c.strip() for c in line.split(";")]
        # ; name ; type ; mode ; clocks ; words ; width ; words ; width ; ...
        try:
            ram.append((f[1], int(f[5]), int(f[6])))
        except (IndexError, ValueError):
            continue
    if "--list" in sys.argv:
        for n, w, b in ram:
            print("%6d x %-3d %s" % (w, b, n))
    bad = 0
    for frag, wmin, bmin in EXPECT:
        hits = [(n, w, b) for n, w, b in ram if frag in n]
        if not hits:
            print("MISSING  %-52s (expected >= %d x %d)" % (frag, wmin, bmin))
            bad += 1
            continue
        for n, w, b in hits:
            # a wide RAM may be split into several blocks side by side; only depth matters here
            ok = w >= wmin
            if not ok:
                bad += 1
            print("%s  %-52s %6d x %-3d (>= %d)" % ("ok     " if ok else "TOO SHALLOW", frag, w, b, wmin))
    print("%d problem(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
