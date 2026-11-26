#!/usr/bin/env python3
"""Draw Velox's drawer icon image: the standard MagicWB drawer with the
globe on its right, as programs mark their drawers.

usage: mkdrawer.py HIRES.png OUTPUT.png

OUTPUT is an indexed PNG in the 8 MagicWB colours for mkicon.py, and
OUTPUT-x8.png an enlarged preview. The drawer is drawn pixel by pixel;
the globe is the logotype, dithered by mwbicon.py.
"""
import sys

from mwbicon import MWB, dither, save

BG, BLACK, WHITE, BLUE, DARK, LIGHT, BEIGE, PINK = range(8)
GW = 18                       # the globe's width


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[BG] * w for _ in range(h)]

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = c

    def hline(self, x0, x1, y, c):
        for x in range(x0, x1 + 1):
            self.set(x, y, c)

    def vline(self, x, y0, y1, c):
        for y in range(y0, y1 + 1):
            self.set(x, y, c)

    def paste(self, rows, mask, ox, oy):
        for y, row in enumerate(rows):
            for x, p in enumerate(row):
                if mask[y][x]:
                    self.set(ox + x, oy + y, p)


def drawer(src):
    """MagicWB: the drawer's front, a bevelled panel lighter in the
    middle, the handle a slot on the left; the globe on the right.
    Workbench draws the frame around it."""
    w, h = 53, 18
    c = Canvas(w, h)
    # the front: black edge, white bevel top and left, blue and dark
    # grey bottom and right
    x0, y0, x1, y1 = 0, 0, w - 1, h - 1
    c.hline(x0, x1, y0, BLACK)
    c.hline(x0, x1, y1, BLACK)
    c.vline(x0, y0, y1, BLACK)
    c.vline(x1, y0, y1, BLACK)
    px0, py0, px1, py1 = x0 + 1, y0 + 1, x1 - 1, y1 - 1
    mid = (px0 + px1) / 2
    # lighter towards the middle: checkerboards of dark grey at the
    # ends, of light grey in the middle
    steps = [DARK, BG, LIGHT, LIGHT]
    for y in range(py0, py1 + 1):
        for x in range(px0, px1 + 1):
            t = 1 - abs(x - mid) / (mid - px0)          # 0 ends, 1 middle
            c.set(x, y, steps[min(3, int(t * 4))] if (x + y) & 1 else BG)
    c.hline(px0, px1, py0, WHITE)
    c.vline(px0, py0, py1, WHITE)
    for x in range(px0 + 1, px1 + 1):
        c.set(x, py1, DARK if x & 1 else BLUE)
    for y in range(py0 + 1, py1):
        c.set(px1, y, BLUE if y & 1 else DARK)
    # the handle: a slot, lit from the top left
    hx, hy = px0 + 7, (py0 + py1) // 2 - 1
    slot = ["ddddddddddd",
            "dwwlllllllb",
            "dpw#######b",
            "dbbbbbbbbbd"]
    pens = {"d": DARK, "w": WHITE, "l": LIGHT, "p": PINK, "#": BLACK, "b": BLUE}
    for y, row in enumerate(slot):
        for x, ch in enumerate(row):
            c.set(hx + x, hy + y, pens[ch])
    # the globe on the right, as high as the front's inside
    rows, mask = dither(src, GW)
    c.paste(rows, mask, px1 - GW - 2, (py0 + py1 + 1 - len(rows)) // 2)
    return c.px


def main():
    src, dst = sys.argv[1], sys.argv[2]
    rows = drawer(src)
    save(rows, MWB, dst)
    print(f"{dst}: {len(rows[0])}x{len(rows)}")


if __name__ == "__main__":
    main()
