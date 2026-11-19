#!/usr/bin/env python3
"""Writes the core's MRA files (mister/mra/<title>.mra for the parents, mra/_alternatives/_<parent title>/ for the clones) from the set
tables of tools/ts_rom.py, which also builds the simulation images: the MRAs and the images cannot disagree.  No ROM file is read.

  python tools/make_mra.py [set ...]          (default: every set)
  python tools/make_mra.py --check <romdir>   (assembles every MRA with tools/mra_build.py and compares it with ts_rom.stream())

The ROM stream (MRA index 0) is described in tools/ts_rom.py and TecmoSys.sv.  Interleaves use the MRA convention that tools/mra_build.py and
mra-tools-c share: each `map` digit is one byte of the output word, the RIGHTMOST digit being the word's first (even) byte, the digit's
value the 1-based byte of that part.  No DIP switches: the board keeps its settings in the 93C46 (MRA nvram index 2, 128 bytes).
"""
import os
import sys
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import ts_rom as T  # noqa: E402

OUTDIR = os.path.join(paths.REPO, 'mra')


def ref(rom):
    return 'name=%s crc="%08x"' % (quoteattr(rom[0]), rom[1])


def parts(s):
    out = []
    hdr = T.header(s)
    out.append('<!-- header: protection table %d, sprite slot table -->' % s['game'])
    out.append('<part>%s</part>' % ' '.join('%02X' % b for b in hdr[:32]))
    out.append('<part repeat="0x%X">00</part>' % (T.HDR_LEN - 32))
    out.append('')
    out.append('<!-- maincpu (68000 program: the even ROM is the high byte) -->')
    out.append('<interleave output="16">')
    out.append('    <part %s map="01"/>' % ref(s['maincpu'][0]))
    out.append('    <part %s map="10"/>' % ref(s['maincpu'][1]))
    out.append('</interleave>')
    out.append('<!-- audiocpu (Z80, 256 KB) -->')
    for r in s['audiocpu']:
        out.append('<part %s/>' % ref(r))
    out.append('<!-- oki (M6295 samples) -->')
    out.append('<part %s/>' % ref(s['oki']))
    out.append('<part repeat="0x40000">00</part>')
    for name in ('layer0', 'layer1', 'layer2', 'layer3'):
        out.append('<!-- %s -->' % name)
        if s[name]:
            for r in s[name]:
                out.append('<part %s/>' % ref(r))
        else:
            out.append('<part repeat="0x100000">00</part>')
    out.append('<!-- ymz (YMZ280B samples, 4 MB) -->')
    for r in s['ymz']:
        out.append('<part %s/>' % ref(r))
    out.append('')
    out.append('<!-- sprites: the slots of the header table -->')
    for i, (mode, half, base, a, b, n) in enumerate(T.slot_layout(s)):
        if n == 0:
            continue
        out.append('<!-- slot %d: %s, SDRAM 0x%07X -->' % (i, '8 bpp' if mode == 2 else '4 bpp', T.SPR_SDRAM + base * T.MB))
        if mode == 2:
            out.append('<interleave output="32">')
            out.append('    <part %s map="0021"/>' % ref(a))
            out.append('    <part %s map="2100"/>' % ref(b))
            out.append('</interleave>')
        else:
            out.append('<part %s/>' % ref(b))
    return out


# The buttons by their function in each game (the board has four: MAME's buttons 1 - 4, the games' own I/O tests' PUSH1 - 3 / A - D):
#   Deroon: "ボタン左右で、左右回転" (the how-to-play: the left / right button turns the piece left / right; in MAME button 2 turns a
#           standing pair clockwise), button 3 throws a bomb; the I/O test has no fourth button.
#   Angel Eyes: A - D light punch, heavy punch, light kick, heavy kick (KLOV's panel; in MAME A jabs, B punches straight, C kicks low,
#           D kicks high).  Pad defaults: punches on the top face buttons, kicks on the bottom ones.
# The seventh, Start 1P+2P (the core's joystick bit 10), presses both starts in one frame: Angel Eyes' I/O check exits only that way
# (TecmoSys.sv).  Deroon's exits on start 1 and button 1, so its MRAs hide it.
# A "-" name hides a button, and Main_MiSTer's defaults list only the shown ones (joymapping.cpp skips "-" names without using up a
# default), so `default` has no entry for a hidden button: with one, every later default moves up a button.
BUTTONS = [
    '    <buttons names="Rotate Left,Rotate Right,Bomb,-,Start,Coin,-" default="A,B,X,Start,Select" count="3"/>',
    '    <buttons names="Light Punch,Heavy Punch,Light Kick,Heavy Kick,Start,Coin,Start 1P+2P" default="Y,X,B,A,Start,Select,R" count="4"/>',
]


def mra(setname):
    s = T.SETS[setname]
    zips = s['zip'] if s['parent'] is None else '%s.zip|%s' % (setname, s['zip'])
    lines = [
        '<misterromdescription>',
        '    <rotation>horizontal</rotation>',
        '    <name>%s</name>' % s['title'],
        '    <setname>%s</setname>' % setname,
        '    <mameversion>0289</mameversion>',
        '    <year>%s</year>' % s['year'],
        '    <manufacturer>Tecmo</manufacturer>',
        '    <players>2</players>',
        '    <joystick>8</joystick>',
        '    <rbf>tecmosys</rbf>',
        '    <platform>Tecmo System</platform>',
        '',
        '    <!--',
        '      ROM stream for the Tecmo System core (tools/make_mra.py from tools/ts_rom.py; TecmoSys.sv describes it): a 256-byte header',
        '      (protection table, sprite slot table), the SDRAM image 0x0000000-0x09FFFFF, then the sprite slots.',
        '      Expects the MAME 0.289 merged romset or the split sets: parts are found by name and CRC.',
        '      No DIP switches: the game keeps its settings in the 93C46 (saved by the core, nvram index 2).',
        "      Test mode: press the test switch (F2, or the OSD's Service Mode) with no credits in.",
        '    -->',
        '',
        BUTTONS[s['game'] != 0],
        '',
        '    <rom index="0" zip="%s" md5="None" address="0x32000000">' % zips,
    ]
    for p in parts(s):
        lines.append(('        ' + p) if p else '')
    lines += [
        '    </rom>',
        '',
        '    <nvram index="2" size="128"/>',
        '</misterromdescription>',
        '',
    ]
    return '\n'.join(lines)


def out_path(setname):
    s = T.SETS[setname]
    fname = s['title'].replace('/', '-') + '.mra'
    if s['parent'] is None:
        return os.path.join(OUTDIR, fname)
    return os.path.join(OUTDIR, '_alternatives', '_' + T.SETS[s['parent']]['title'].replace('/', '-'), fname)


def check(romdir):
    import mra_build
    ok = True
    for setname in T.SETS:
        s = T.SETS[setname]
        rs = T.RomSet(romdir, s['zip'])
        want = T.stream(s, rs)
        got, _md5 = mra_build.build(out_path(setname), os.path.join(romdir, s["zip"]))
        same = (got == want)
        ok &= same
        print('%-10s %s (%d bytes)' % (setname, 'MRA stream == ts_rom.stream()' if same else 'DIFFERENT', len(got)))
    return ok


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--check':
        sys.exit(0 if check(sys.argv[2] if len(sys.argv) > 2 else paths.ROMS) else 1)
    sets = sys.argv[1:] or list(T.SETS)
    for setname in sets:
        p = out_path(setname)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w', encoding='utf-8', newline='\n').write(mra(setname))
        print(p)


if __name__ == '__main__':
    main()
