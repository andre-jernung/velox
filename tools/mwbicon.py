#!/usr/bin/env python3
"""Turn a high-resolution RGBA picture into a MagicWB icon image.

usage: mwbicon.py INPUT.png OUTPUT.png [WIDTH]

Crops to the opaque part, scales down to WIDTH (default 48) pixels with
square pixels (MagicWB is drawn for 640x512/480 screens), and maps it to
the 8 colour MagicWB palette with serpentine Floyd-Steinberg dithering.
The transparent background becomes pen 0 and the picture gets a black
outline, MagicWB style. The picture itself uses pens 1-7: pen 0 stays
background (transparent on OS 3.2 icons). The error spreads at 80%, so
smooth areas get fewer stray dots, and only inside the picture.
OUTPUT is an indexed PNG with the MagicWB palette; OUTPUT-x8.png is an
enlarged preview.
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
PENS = range(1, 8)
STRENGTH = 0.8


def nearest(rgb):
    """closest pen by a luma-weighted distance (red-mean)"""
    r, g, b = rgb
    best, bd = 0, None
    for i in PENS:
        pr, pg, pb = MWB[i]
        rm = (r + pr) / 2
        dr, dg, db = r - pr, g - pg, b - pb
        d = (2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db
        if bd is None or d < bd:
            best, bd = i, d
    return best


def dither(src, width):
    """the picture in SRC as WIDTH pixels wide pens. Out: (rows of pens,
    rows of mask): pen 0 outside, the outline (pen 1) is in the mask."""
    im = Image.open(src).convert("RGBA")
    # crop to the clearly opaque part (the edges have a faint halo)
    im = im.crop(im.getchannel("A").point(lambda a: 255 if a > 64 else 0).getbbox())
    # one pixel each side for the outline
    height = round(im.height * (width - 2) / im.width) + 2
    # Pillow premultiplies alpha when resizing RGBA
    im = im.resize((width - 2, height - 2), Image.LANCZOS)
    pic = Image.new("RGBA", (width, height))
    pic.paste(im, (1, 1))
    px = pic.load()
    rgb = [[list(px[x, y][:3]) for x in range(width)] for y in range(height)]
    mask = [[px[x, y][3] >= 128 for x in range(width)] for y in range(height)]
    out = [[0] * width for _ in range(height)]
    for y in range(height):
        d = 1 if y % 2 == 0 else -1
        for x in range(width) if d == 1 else range(width - 1, -1, -1):
            if not mask[y][x]:
                continue
            old = [max(0, min(255, c)) for c in rgb[y][x]]
            p = nearest(old)
            out[y][x] = p
            err = [(o - n) * STRENGTH for o, n in zip(old, MWB[p])]
            for dx, dy, w in ((d, 0, 7), (-d, 1, 3), (0, 1, 5), (d, 1, 1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and ny < height and mask[ny][nx]:
                    t = rgb[ny][nx]
                    for k in range(3):
                        t[k] += err[k] * w / 16
    edge = [[not mask[y][x] and any(
        0 <= x + a < width and 0 <= y + b < height and mask[y + b][x + a]
        for a, b in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        for x in range(width)] for y in range(height)]
    for y in range(height):
        for x in range(width):
            if edge[y][x]:
                out[y][x] = 1
                mask[y][x] = True
    return out, mask


def save(rows, palette, dst):
    """write ROWS of pens as an indexed PNG, and DST-x8.png enlarged"""
    w, h = len(rows[0]), len(rows)
    res = Image.new("P", (w, h))
    res.putpalette([c for pen in palette for c in pen])
    res.putdata([p for row in rows for p in row])
    res.save(dst)
    res.resize((w * 8, h * 8), Image.NEAREST).save(dst.rsplit(".", 1)[0] + "-x8.png")


def main():
    args = sys.argv[1:]
    src, dst = args[0], args[1]
    width = int(args[2]) if len(args) > 2 else 48
    out, _ = dither(src, width)
    save(out, MWB, dst)
    print(f"{dst}: {width}x{len(out)}, MagicWB 8 colours")


if __name__ == "__main__":
    main()
