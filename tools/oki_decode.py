# Decode one OKI M6295 phrase from the core's SDRAM image with MAME's ADPCM (okim6295.cpp / oki_adpcm_state), and compare it with the bench.
#   python tools/oki_decode.py <image.sdram> <phrase> <okb0> <okb1> chips  <chips.txt> <from_s> <to_s>   (+CHIPS log: column 5 per 48 kHz sample)
#   python tools/oki_decode.py <image.sdram> <phrase> <okb0> <okb1> okilog <oki.txt> <frame>            (+OKILOG: "frame sound" per OKI sample;
#                                                                                                    the phrase starts at or after <frame>)
# The phrase is assumed to play alone on one channel at attenuation 0 (jt6295 `sound` = the decoder's 12-bit signal).
import math
import sys

SHIFT = [-1, -1, -1, -1, 2, 4, 6, 8]
NB = [[1, 0, 0, 0], [1, 0, 0, 1], [1, 0, 1, 0], [1, 0, 1, 1], [1, 1, 0, 0], [1, 1, 0, 1], [1, 1, 1, 0], [1, 1, 1, 1],
      [-1, 0, 0, 0], [-1, 0, 0, 1], [-1, 0, 1, 0], [-1, 0, 1, 1], [-1, 1, 0, 0], [-1, 1, 0, 1], [-1, 1, 1, 0], [-1, 1, 1, 1]]
DIFF = []
for step in range(49):
    sv = int(math.floor(16.0 * pow(11.0 / 10.0, step)))
    for n in range(16):
        b = NB[n]
        DIFF.append(b[0] * (sv * b[1] + sv // 2 * b[2] + sv // 4 * b[3] + sv // 8))


def decode(rom, start, stop):
    sig, step, out = -2, 0, []
    for a in range(start, stop + 1):
        byte = rom(a)
        for nib in (byte >> 4, byte & 15):
            sig = max(-2048, min(2047, sig + DIFF[step * 16 + nib]))
            step = max(0, min(48, step + SHIFT[nib & 7]))
            out.append(sig)
    return out


def table(ref, bs, g):
    w = 758  # 50 ms
    print('   t(ms)   MAME mean  MAME rms  |  bench mean  bench rms')
    for s in range(0, min(len(ref), len(bs)), w):
        rr, bb = ref[s:s + w], [v / g for v in bs[s:s + w]]
        n = min(len(rr), len(bb))
        rr, bb = rr[:n], bb[:n]
        print('  %6.0f  %9.1f %9.1f  |  %9.1f %9.1f' % (s / 15.1515, sum(rr) / n, math.sqrt(sum(x * x for x in rr) / n),
                                                       sum(bb) / n, math.sqrt(sum(x * x for x in bb) / n)))


def main():
    img, phrase, okb0, okb1, mode, path = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
    data = open(img, 'rb').read()
    base = 0x140000

    def rom(oa):                             # the OKI's 18-bit address through the two 128 KB page registers
        pa = ((okb1 if oa & 0x20000 else okb0) << 17) | (oa & 0x1FFFF)
        return data[base + pa]
    t = phrase * 8
    start = ((rom(t) << 16) | (rom(t + 1) << 8) | rom(t + 2)) & 0x3FFFF
    stop = ((rom(t + 3) << 16) | (rom(t + 4) << 8) | rom(t + 5)) & 0x3FFFF
    ref = decode(rom, start, stop)
    print('phrase %d: %05x-%05x, %d samples (%.3f s at 15151.5 Hz)' % (phrase, start, stop, len(ref), len(ref) / 15151.5))

    if mode == 'chips':
        a, b = float(sys.argv[7]), float(sys.argv[8])
        bench = []
        with open(path) as f:
            for i, line in enumerate(f):
                if i < int(a * 48000):
                    continue
                if i >= int(b * 48000):
                    break
                bench.append(int(line.split()[4]))
        i0 = next(i for i, v in enumerate(bench) if v != 0)
        print('bench: first nonzero OKI sample at %.4f s' % (a + i0 / 48000))
        r = 48000 / 15151.5
        n = min(len(ref), int((len(bench) - i0) / r) - 2)
        bs = [bench[i0 + int((k + 0.5) * r)] for k in range(n)]
        num = sum(x * y for x, y in zip(ref[:300], bs[:300]))
        g = num / (sum(x * x for x in ref[:300]) or 1)
        print('scale bench / MAME over the first 300 samples: %.4f' % g)
        table(ref, bs, g)
        return

    frame = int(sys.argv[7])
    log = []
    with open(path) as f:
        for line in f:
            fr, v = line.split()
            if int(fr) >= frame:
                log.append(int(v))
    i0 = next(i for i, v in enumerate(log) if v != 0)
    # the decoder's first outputs can be zero-crossing small values: align on the best of a few offsets around the first nonzero sample
    best = None
    for off in range(-4, 5):
        s = i0 + off
        if s < 0:
            continue
        seg = log[s:s + len(ref)]
        bad = sum(1 for x, y in zip(ref, seg) if x != y)
        if best is None or bad < best[0]:
            best = (bad, s)
    bad, s = best
    seg = log[s:s + len(ref)]
    n = min(len(ref), len(seg))
    print('bench: phrase aligned at OKI sample %d after frame %d; compared %d samples' % (s, frame, n))
    diffs = [k for k in range(n) if ref[k] != seg[k]]
    if diffs:
        k = diffs[0]
        print('DIFFERENT: %d of %d samples; the first at %d (%.2f ms): MAME %d, bench %d' % (len(diffs), n, k, k / 15.1515, ref[k], seg[k]))
    else:
        print('IDENTICAL: all %d samples equal MAME\'s decode' % n)
    tail = log[s + n:s + n + 200]
    print('after the phrase: %d of the next %d samples are 0' % (sum(1 for v in tail if v == 0), len(tail)))
    table(ref, seg, 1.0)


main()
