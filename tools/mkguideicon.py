#!/usr/bin/env python3
"""Draw the MagicWB image of Velox.guide's icon: a page with a folded
corner and lines of text, the Velox globe on it, a shadow to the lower
right.

usage: mkguideicon.py GLOBE.png OUTPUT.png

GLOBE is the globe as a small MagicWB image (tools/mwbicon.py
gfx/icon-hires.png GLOBE.png 24).

OUTPUT is an indexed PNG with the MagicWB palette (pen 0 the
background), as tools/mkicon.py takes it; OUTPUT-x8.png is an enlarged
preview.
"""
import sys

from PIL import Image

MWB = [
    (149, 149, 149),  # 0 grey (background)
    (0, 0, 0),        # 1 black
    (255, 255, 255),  # 2 white
    (59, 103, 162),   # 3 blue
    (123, 123, 123),  # 4 dark grey
    (175, 175, 175),  # 5 light grey
    (170, 144, 124),  # 6 beige
    (255, 169, 151),  # 7 pink
]
W, H = 44, 40
L, T, R, B = 4, 1, 31, 36       # the page
FOLD = 7                        # its folded corner


def main():
    globe_src, out = sys.argv[1], sys.argv[2]
    px = [[0] * W for _ in range(H)]

    def put(x, y, pen):
        if 0 <= x < W and 0 <= y < H:
            px[y][x] = pen

    # the shadow, then the page: white, light grey at its right and
    # bottom edges, black outline, the corner folded down
    for y in range(T + 2, B + 3):
        for x in range(L + 2, R + 3):
            put(x, y, 4)
    for y in range(T, B + 1):
        for x in range(L, R + 1):
            if x - (R - FOLD) > y - T:          # the corner: cut off
                put(x, y, 0)
                continue
            edge = x in (L, R) or y in (T, B)
            put(x, y, 1 if edge else (5 if x == R - 1 or y == B - 1 else 2))
    for y in range(T, T + FOLD + 1):             # the fold: light grey,
        for x in range(R - FOLD, R + 1):         # black edges
            dx, dy = x - (R - FOLD), y - T
            if dx <= dy:
                put(x, y, 1 if dx in (0, dy) or dy == FOLD else 5)
    # lines of text, shorter ones now and then
    lens = [14, 18, 11, 18, 16, 9, 18, 13, 17, 15]
    y = T + 4
    for n in lens:
        if y > B - 4:
            break
        x0 = L + 3
        if y < T + FOLD + 2:
            n = min(n, R - FOLD - x0 - 2)
        for x in range(x0, x0 + n):
            put(x, y, 4 if (x - x0) % 5 != 4 else 2)
        y += 3
    # the globe, on the lower right of the page
    g = Image.open(globe_src)
    gp = g.load()
    gw, gh = g.size
    ox, oy = W - gw, H - gh
    for y in range(gh):
        for x in range(gw):
            if gp[x, y]:
                put(ox + x, oy + y, gp[x, y])
    im = Image.new("P", (W, H))
    im.putpalette([c for rgb in MWB for c in rgb])
    im.putdata([p for row in px for p in row])
    im.save(out)
    im.convert("RGB").resize((W * 8, H * 8), Image.NEAREST).save(out.replace(".png", "-x8.png"))


if __name__ == "__main__":
    main()
