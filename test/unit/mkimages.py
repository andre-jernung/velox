#!/usr/bin/env python3
"""Make the test images for test/unit/images.vt in DIR (default build/img)
with PIL: the same pictures in each format and its variants."""
import os
import random
import sys

from PIL import Image, ImageDraw

d = sys.argv[1] if len(sys.argv) > 1 else "build/img"
os.makedirs(d, exist_ok=True)
random.seed(7)


def picture(w, h, alpha=False):
    """Gradients, shapes, some noise and sharp edges."""
    im = Image.new("RGBA", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            a = 255 if not alpha else (x * 255 // (w - 1) if y < h // 2 else (0 if (x // 4 + y // 4) % 2 else 255))
            px[x, y] = (x * 255 // (w - 1), y * 255 // (h - 1), (x * y) & 255, a)
    dr = ImageDraw.Draw(im)
    dr.ellipse((w // 4, h // 4, w * 3 // 4, h * 3 // 4), fill=(200, 30, 60, 255))
    dr.rectangle((2, 2, w // 3, h // 5), fill=(20, 220, 90, 255))
    dr.line((0, h - 1, w - 1, 0), fill=(255, 255, 0, 255), width=3)
    for _ in range(w * h // 20):
        px[random.randrange(w), random.randrange(h)] = (random.randrange(256), random.randrange(256), random.randrange(256), 255)
    return im


def save(im, name, **kw):
    im.save(os.path.join(d, name), **kw)


# GIF: palette images, interlaced or not, transparency, few colours,
# an image smaller than its screen
p = picture(64, 48).convert("RGB")
save(p.quantize(256), "g256.gif", interlace=False)
save(p.quantize(256), "g256i.gif", interlace=True)
save(p.quantize(2), "g2.gif", interlace=False)
save(p.quantize(16), "g16i.gif", interlace=True)
t = p.quantize(32)
save(t, "gtrans.gif", transparency=5, interlace=False)
big = picture(301, 201).convert("RGB").quantize(200)
save(big, "gbig.gif", interlace=False)

# PNG: every colour type and depth, interlaced or not, palettes with
# tRNS, colour keys, filters of all kinds (PIL picks them per row)
from PIL import PngImagePlugin  # noqa: E402,F401
pic = picture(53, 37, alpha=True)
save(pic, "prgba.png")
save(pic, "prgbai.png", interlace=True)
save(pic.convert("RGB"), "prgb.png")
save(pic.convert("RGB"), "prgbi.png", interlace=True)
save(pic.convert("L"), "pgrey.png")
save(pic.convert("LA"), "pga.png")
save(pic.convert("RGB").quantize(256), "ppal8.png")
save(pic.convert("RGB").quantize(16), "ppal4.png", bits=4)
save(pic.convert("RGB").quantize(4), "ppal2.png", bits=2)
save(pic.convert("1"), "pmono.png")
save(pic.convert("RGB").quantize(16), "ppal4i.png", bits=4, interlace=True)
q = pic.quantize(64)                        # palette with alpha (tRNS)
save(q, "ppaltrns.png")
save(pic.convert("RGB"), "pkey.png", transparency=(255, 255, 0))
save(pic.convert("L"), "pgreykey.png", transparency=0)
# 16 bits per sample (I;16 grey, and 48/64-bit colour through raw data)
g16 = Image.new("I;16", (31, 29))
g16.putdata([(x * 2113 + y * 977) & 0xffff for y in range(29) for x in range(31)])
save(g16, "pgrey16.png")
# a big one, compressed hard (dynamic Huffman codes, long matches)
save(picture(400, 300).convert("RGB"), "pbig.png", optimize=True)
save(picture(400, 300).convert("RGB"), "pfast.png", compress_level=1)
save(picture(64, 64).convert("RGB"), "pstored.png", compress_level=0)
w16 = pic.convert("RGBA")


def png16(name, mode, w, h, px):
    """A 16-bit colour PNG, written by hand (PIL cannot)."""
    import struct, zlib
    ctype = {"RGB": 2, "RGBA": 6}[mode]
    raw = b"".join(b"\0" + b"".join(struct.pack(">" + "H" * len(p), *p) for p in px[y * w:(y + 1) * w]) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 16, ctype, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    open(os.path.join(d, name), "wb").write(data)


px = [((x * 2311) & 0xffff, (y * 4099) & 0xffff, (x * y * 37) & 0xffff, ((x + y) * 3001) & 0xffff) for y in range(21) for x in range(27)]
png16("prgba16.png", "RGBA", 27, 21, px)
png16("prgb16.png", "RGB", 27, 21, [p[:3] for p in px])

# broken files: cut short, and with bytes overwritten; decoding them
# must not crash (their output is not compared: ".bad")
random.seed(11)
for name in sorted(os.listdir(d)):
    if "." not in name or name.endswith((".argb", ".bad")) or name.startswith(("cut", "bad")):
        continue
    data = open(os.path.join(d, name), "rb").read()
    for frac in (0.3, 0.7, 0.97):
        open(os.path.join(d, "cut%d-%s" % (int(frac * 100), name)), "wb").write(data[:int(len(data) * frac)])
    for k in range(3):
        b = bytearray(data)
        for _ in range(8):
            i = random.randrange(16, len(b))
            b[i] = random.randrange(256)
        open(os.path.join(d, "bad%d-%s" % (k, name)), "wb").write(bytes(b))
