#!/usr/bin/env python3
"""Runs the frozen-state video bench (sim/run_video.sh) on captured MAME states and reports, per frame, the pixels that differ from MAME.

  python tools/bench_video.py <set> <states dir> <frames> [--build] [--rt4k]

--rt4k runs the RT4K DV1 raster (the OSD's Video Timing; ts_cen.sv) instead of the Original.

Needs the set's images in work/rom (tools/ts_rom.py <set> --sdram work/rom/<set>.sdram --hdr work/rom/<set>.hdr) and states N - 1 and N
of every frame N (tools/capture.py).  The pictures go to work/sim/video/<set>_fNNNNN.ppm.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402

WORK = os.path.join(paths.BASE, 'work')


def frames(spec):
    out = []
    for part in spec.split(','):
        if '-' in part:
            a, rest = part.split('-'); b, s = rest.split('/')
            out += list(range(int(a), int(b) + 1, int(s)))
        else:
            out.append(int(part))
    return out


def main():
    if len(sys.argv) < 4:
        print(__doc__); return 2
    setname, sdir, spec = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
    build = '--build' in sys.argv
    rt4k = '--rt4k' in sys.argv
    w = paths.wsl(WORK)
    os.makedirs(os.path.join(WORK, 'sim', 'video'), exist_ok=True)
    bad = 0
    for i, f in enumerate(frames(spec)):
        st, ss = paths.wsl(os.path.join(sdir, 'f%05d' % f)), paths.wsl(os.path.join(sdir, 'f%05d' % (f - 1)))
        args = ['+IMAGE=%s/rom/%s.sdram' % (w, setname), '+HDR=%s/rom/%s.hdr' % (w, setname), '+STATE=' + st, '+SPRSTATE=' + ss,
                '+MAMERGB=' + st + '.rgb', '+OUT=%s/sim/video/%s_f%05d%s.ppm' % (w, setname, f, '_rt4k' if rt4k else '')]
        if rt4k:
            args.append('+VMODE=1')
        env = '' if (build and i == 0) else 'NOBUILD=1 '
        cmd = ['wsl', 'bash', '-c', '%sbash %s/sim/run_video.sh %s' % (env, paths.wsl(paths.REPO), ' '.join(args))]
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        res = [l for l in r.stdout.splitlines() if l.startswith('RESULT') or l.startswith('first') or 'longest' in l or 'rror' in l]
        print('%s %5d: %s' % (setname, f, ' | '.join(res)))
        if r.returncode != 0:
            bad += 1
    print('%d of %d frames differ' % (bad, len(frames(spec))))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
