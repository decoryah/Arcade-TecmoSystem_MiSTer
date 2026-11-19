#!/usr/bin/env python3
"""Contact sheet of 320 x 240 pictures (bench PPMs or MAME .rgb dumps) in a grid, for looking at runs.

  python tools/sheet.py <out.png> <cols> <picture> [<picture> ...]     (a picture: file.ppm, file.rgb, or "-" for an empty cell)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pngio  # noqa: E402

W, H = 320, 240


def load(p):
    if p == '-' or not os.path.exists(p):
        return bytes(W * H * 3)
    d = open(p, 'rb').read()
    if d[:2] == b'P6':
        return d.split(b'\n', 3)[3][:W * H * 3]
    return d[:W * H * 3]


def main():
    out, cols, pics = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    rows = (len(pics) + cols - 1) // cols
    img = bytearray(W * cols * H * rows * 3)
    for k, p in enumerate(pics):
        im = load(p)
        ox, oy = (k % cols) * W, (k // cols) * H
        for y in range(H):
            o = ((oy + y) * W * cols + ox) * 3
            img[o:o + W * 3] = im[y * W * 3:(y + 1) * W * 3]
    pngio.write(out, W * cols, H * rows, bytes(img))


if __name__ == '__main__':
    main()
