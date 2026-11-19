#!/usr/bin/env python3
"""Runs MAME 0.289 headless on a Tecmo System set and dumps frame states + MAME's pixels (tools/lua/dump_state.lua).

    capture.py <set> <frames> [outdir] [--play] [--seed N] [--test]

  <frames>   machine frames to capture, e.g. 300  or  150,300,600  or  60-600/60 (first-last/step)
  outdir     default work/states/<set>
  --play     scripted inputs (coin at 300, start at 400, random joystick / buttons from 480); default: no inputs
  --test     hold the test switch for the first 120 frames (test mode)
  --poke A:V:F  write byte V to 68000 address A every frame from frame F on (hex, hex, decimal)
  --hold "F@a-b,..."  hold MAME input fields over frame ranges (e.g. "Service@600-660,P1 Button 1@700-705"; P1 "Service" is the test switch)
  --keep-nvram  start from the 93C46 MAME saved last time (default: a blank one, as the core's bench starts: the first boot initialises it,
                which takes the games a while)

MAME's nvram goes to work/nvram (a fresh 93C46 the first time: the game initialises it).  (After the owner's supduck-mister tools/capture.py.)
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths  # noqa: E402

WORK = os.path.join(paths.BASE, 'work')
LUA = os.path.join(paths.REPO, 'tools', 'lua')


def main(argv):
    opts, args, i = {}, [], 1
    while i < len(argv):
        a = argv[i]
        if a in ('--seed', '--poke', '--hold'):
            opts[a] = argv[i + 1]; i += 2; continue
        if a.startswith('--'):
            opts[a] = True
        else:
            args.append(a)
        i += 1
    if len(args) < 2:
        print(__doc__)
        return 2
    setname, frames = args[0], args[1]
    out = os.path.abspath(args[2]) if len(args) > 2 else os.path.join(WORK, 'states', setname)
    os.makedirs(out, exist_ok=True)
    for sub in ('cfg', 'nvram'):
        os.makedirs(os.path.join(WORK, sub), exist_ok=True)
    nv = os.path.join(WORK, 'nvram', setname)
    if '--keep-nvram' not in opts and os.path.isdir(nv):
        import shutil
        shutil.rmtree(nv)
    env = dict(os.environ, DUMPDIR=out, DUMPFRAMES=frames, SCHEDULE='play' if '--play' in opts else 'none')
    if '--seed' in opts:
        env['SEED'] = opts['--seed']
    if '--test' in opts:
        env['TEST'] = '1'
    if '--poke' in opts:
        env['POKE'] = opts['--poke']
    if '--hold' in opts:
        env['HOLD'] = opts['--hold']
    last = max(int(x) for part in frames.split(',') for x in
               ((part.split('-')[1].split('/')[0],) if '-' in part else (part,)))
    cmd = [paths.MAME, setname, '-rompath', paths.ROMS, '-cfg_directory', os.path.join(WORK, 'cfg'),
           '-nvram_directory', os.path.join(WORK, 'nvram'), '-video', 'none', '-sound', 'none', '-nothrottle',
           '-skip_gameinfo', '-autoboot_script', os.path.join(LUA, 'dump_state.lua'),
           '-seconds_to_run', str(last // 57 + 30)]
    r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    for line in r.stdout.splitlines():
        if line.startswith('PIXELS') or 'rror' in line:
            print(line)
    n = sum(1 for f in os.listdir(out) if f.endswith('.regs'))
    print('%s: %d states in %s (MAME exit %d)' % (setname, n, out, r.returncode))
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
