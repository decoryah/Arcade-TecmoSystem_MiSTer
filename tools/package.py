#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository (from the owner's cojag-mister tools/package.py):

  _Arcade/<title>.mra                              the MRAs, with their _alternatives/ folders   (mra/**/*.mra)
  _Arcade/cores/tecmosys_<YYYYMMDD>.rbf            the core                                      (releases/tecmosys_<YYYYMMDD>.rbf)

  python tools/package.py [YYYYMMDD]        (default: the newest RBF in releases/)

Writes dist/TecmoSys_MiSTer_<YYYYMMDD>.zip (dist/ is not in the repository: attach the zip to the GitHub release) and prints the
SHA-256 of the zip and the RBF for the release notes (dist/RELEASE_NOTES_<YYYYMMDD>.md, written by hand).  dist/ keeps only the
latest release: the zips and release notes of other dates are removed.  Unzip the zip over the root of the SD card.  No ROMs are in
it: the MAME 0.289 romsets (deroon.zip, tkdensho.zip) go to /media/fat/games/mame/.
"""
import glob
import hashlib
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DIST = os.path.join(REPO, 'dist')
CORE = 'tecmosys'
ZIP = 'TecmoSys_MiSTer_%s.zip'


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def main(argv):
    rbfs = sorted(glob.glob(os.path.join(REPO, 'releases', CORE + '_*.rbf')))
    rbfs = [r for r in rbfs if re.search(CORE + r'_\d{8}[a-z]?\.rbf$', r)]
    if argv:
        rbfs = [r for r in rbfs if r.endswith('%s_%s.rbf' % (CORE, argv[0]))]
    if not rbfs:
        print('no releases/%s_YYYYMMDD.rbf' % CORE)
        return 1
    rbf = rbfs[-1]
    date = re.search(CORE + r'_(\d{8}[a-z]?)\.rbf$', rbf).group(1)
    mra_root = os.path.join(REPO, 'mra')
    mras = sorted(glob.glob(os.path.join(mra_root, '**', '*.mra'), recursive=True),
                  key=lambda p: (os.path.dirname(p).lower(), os.path.basename(p).lower()))
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, ZIP % date)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full in mras:
            z.write(full, '_Arcade/' + os.path.relpath(full, mra_root).replace(os.sep, '/'))
        z.write(rbf, '_Arcade/cores/' + os.path.basename(rbf))
    print('%s: %d MRAs + %s' % (out, len(mras), os.path.basename(rbf)))
    with zipfile.ZipFile(out) as z:
        for n in z.namelist():
            print('  ' + n)
    # dist/ holds the latest release only
    for old in glob.glob(os.path.join(DIST, ZIP % '*')) + glob.glob(os.path.join(DIST, 'RELEASE_NOTES_*.md')):
        if not re.search(r'_%s\.(zip|md)$' % re.escape(date), old):
            os.remove(old)
            print('removed older %s' % os.path.basename(old))
    notes = os.path.join(DIST, 'RELEASE_NOTES_%s.md' % date)
    if not os.path.exists(notes):
        print('(no %s yet: write it)' % os.path.relpath(notes, REPO))
    print('SHA-256:')
    for p in (out, rbf):
        print('%s  %s' % (sha256(p), os.path.basename(p)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
