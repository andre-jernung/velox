#!/usr/bin/env python3
"""Write a Workbench tool, drawer or project icon (.info) for Velox.

usage: mkicon.py [--drawer | --project TOOL] IMAGE.png OUTPUT.info
                 [TOOLTYPE ...]

The picture is an indexed PNG: pen numbers as they are, as many planes
as its highest pen needs (Velox's are 3 planes for MagicWB, made by
tools/mwbicon.py and tools/mkdrawer.py).  Without TOOLTYPE arguments
the icon gets the documented tool types, disabled with parentheses.
--drawer makes a
drawer icon (no tool types; its window opens at 80,40, 300x100, until
the user snapshots it).  --project TOOL makes a project icon opened by
TOOL (its default tool: SYS:Utilities/MultiView for Velox.guide), with
the tool types given, or none.
"""
import struct
import sys

from PIL import Image

DEFAULT_TOOLTYPES = [
    "(PROXY=192.168.1.10:8888)",
    "(HOME=about:velox)",
    "(URL=http://frogfind.com/)",
    "(DOWNLOADDIR=RAM:)",
    "(NOIMAGES)",
]


def planes(w, h, depth, pen):
    rowbytes = ((w + 15) // 16) * 2
    out = b""
    for p in range(depth):
        for y in range(h):
            row = bytearray(rowbytes)
            for x in range(w):
                if pen(x, y) >> p & 1:
                    row[x // 8] |= 0x80 >> (x % 8)
            out += bytes(row)
    return out


def main():
    args = sys.argv[1:]
    drawer = args[0] == "--drawer"
    if drawer:
        args = args[1:]
    tool = None
    if args[0] == "--project":
        tool = args[1]
        args = args[2:]
    im = Image.open(args[0])
    if im.mode != "P":
        sys.exit(f"{args[0]}: not an indexed image")
    w, h = im.size
    px = im.load()
    depth = max(1, max(px[x, y] for x in range(w) for y in range(h)).bit_length())
    path = args[1]
    tooltypes = [] if drawer else args[2:] if tool else args[2:] or DEFAULT_TOOLTYPES
    gadget = struct.pack(
        ">IhhhhHHHIIIIIHI",
        0, 0, 0, w, h + 1,
        0x0005,          # GFLG_GADGIMAGE | GFLG_GADGBACKFILL
        0x0003,          # RELVERIFY | GADGIMMEDIATE
        0x0001,          # BOOLGADGET
        1, 0, 0, 0, 0,   # GadgetRender (follows), no select image
        0, 1)            # UserData 1: OS 2.x icon revision
    dobj = struct.pack(">HH", 0xE310, 1) + gadget + struct.pack(
        ">BBIIiiIIi",
        2 if drawer else 4 if tool else 3, 0,  # WBDRAWER / WBPROJECT / WBTOOL
        1 if tool else 0,          # a default tool follows (project)
        1 if tooltypes else 0,     # tool types follow
        -0x80000000, -0x80000000,  # NO_ICON_POSITION
        1 if drawer else 0, 0,     # drawer data follows, no tool window
        0 if drawer else 16384 if tool else 65536)  # stack (Velox: 64 KB)
    if drawer:
        # DrawerData: a NewWindow (the drawer's window) and the scroll
        # position of its contents
        dobj += struct.pack(
            ">hhhhBBIIIIIIIhhhhHii",
            80, 40, 300, 100,      # place and size
            255, 255,              # default pens
            0, 0, 0, 0, 0, 0, 0,   # flags, gadgets, title, screen: Workbench's
            90, 40, -1, -1,        # min and max size
            1,                     # WBENCHSCREEN
            0, 0)                  # CurrentX/Y
    image = struct.pack(">hhhhhIBBI", 0, 0, w, h, depth, 1, (1 << depth) - 1, 0, 0) \
        + planes(w, h, depth, lambda x, y: px[x, y])
    tt = b""
    if tool:
        b = tool.encode("latin-1") + b"\0"
        tt += struct.pack(">I", len(b)) + b
    if tooltypes:
        tt += struct.pack(">I", (len(tooltypes) + 1) * 4)
    for t in tooltypes:
        b = t.encode("latin-1") + b"\0"
        tt += struct.pack(">I", len(b)) + b
    if drawer:
        # OS 2.x drawer data (icon revision 1): flags, view modes (both
        # default: show icons, view by icon)
        tt += struct.pack(">IH", 0, 0)
    with open(path, "wb") as f:
        f.write(dobj + image + tt)


if __name__ == "__main__":
    main()
