#!/usr/bin/env python3
"""Write a Workbench tool icon (.info) for Velox.

usage: mkicon.py OUTPUT.info [TOOLTYPE ...]

A 4 colour (2 plane) image of a globe, as the standard Workbench palette
shows it (grey, black, white, blue).  Without TOOLTYPE arguments the icon
gets the documented tool types, disabled with parentheses.
"""
import math
import struct
import sys

W, H = 46, 23
DEFAULT_TOOLTYPES = [
    "(PROXY=192.168.1.10:8888)",
    "(HOME=about:velox)",
    "(URL=http://frogfind.com/)",
    "(DOWNLOADDIR=RAM:)",
    "(NOIMAGES)",
]


def pixel(x, y):
    """0 grey, 1 black, 2 white, 3 blue"""
    # pixels are about twice as high as wide on a 640x256 screen
    cx, cy, r = W / 2 - 0.5, H / 2 - 0.5, 10.5
    dx, dy = (x - cx) / 2.0, y - cy
    d = math.hypot(dx, dy)
    if d > r + 0.5:
        return 0
    if d > r - 0.7:
        return 1                      # outline
    # meridians and parallels
    lon = math.asin(max(-1, min(1, dx / math.sqrt(max(r * r - dy * dy, 0.01)))))
    if abs(dy) < 0.5 or abs(abs(dy) - r / 2) < 0.5:
        return 2
    for m in (-math.pi / 4, 0, math.pi / 4):
        if abs(lon - m) < 0.09:
            return 2
    return 3


def planes():
    rowbytes = ((W + 15) // 16) * 2
    out = b""
    for p in range(2):
        for y in range(H):
            row = bytearray(rowbytes)
            for x in range(W):
                if pixel(x, y) >> p & 1:
                    row[x // 8] |= 0x80 >> (x % 8)
            out += bytes(row)
    return out


def main():
    path = sys.argv[1]
    tooltypes = sys.argv[2:] or DEFAULT_TOOLTYPES
    gadget = struct.pack(
        ">IhhhhHHHIIIIIHI",
        0, 0, 0, W, H + 1,
        0x0005,          # GFLG_GADGIMAGE | GFLG_GADGBACKFILL
        0x0003,          # RELVERIFY | GADGIMMEDIATE
        0x0001,          # BOOLGADGET
        1, 0, 0, 0, 0,   # GadgetRender (follows), no select image
        0, 1)            # UserData 1: OS 2.x icon revision
    dobj = struct.pack(">HH", 0xE310, 1) + gadget + struct.pack(
        ">BBIIiiIIi",
        3, 0,            # WBTOOL
        0, 1,            # no default tool; tool types follow
        -0x80000000, -0x80000000,  # NO_ICON_POSITION
        0, 0, 16384)     # no drawer data / tool window, stack
    image = struct.pack(">hhhhhIBBI", 0, 0, W, H, 2, 1, 3, 0, 0) + planes()
    tt = struct.pack(">I", (len(tooltypes) + 1) * 4)
    for t in tooltypes:
        b = t.encode("latin-1") + b"\0"
        tt += struct.pack(">I", len(b)) + b
    with open(path, "wb") as f:
        f.write(dobj + image + tt)


if __name__ == "__main__":
    main()
