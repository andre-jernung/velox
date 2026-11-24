#!/usr/bin/env python3
"""Compare what Velox decoded (DIR/NAME.argb: width.l, height.l, ARGB
pixels, big-endian) with PIL's decoding of DIR/NAME.  Lossless formats
must match exactly; lossy ones (JPEG, lossy WebP) within a tolerance."""
import glob
import os
import struct
import sys

from PIL import Image

d = sys.argv[1] if len(sys.argv) > 1 else "build/img"
fail = 0
for out in sorted(glob.glob(os.path.join(d, "*.argb"))):
    src = out[:-5]
    name = os.path.basename(src)
    data = open(out, "rb").read()
    w, h = struct.unpack(">II", data[:8])
    ref = Image.open(src)
    ref.seek(0)
    if ref.mode in ("I;16", "I;16B", "I"):
        # 16-bit grey: PNG means the high byte (PIL would clip)
        ref = ref.point(lambda v: v / 256).convert("L")
    ref = ref.convert("RGBA")
    if ref.size != (w, h):
        # a scaled decode: compare with PIL's own scaling
        ref = ref.resize((w, h), Image.BOX)
    rp = ref.tobytes()
    lossy = name.endswith((".jpg", ".jpeg")) or name.startswith("wl")
    diff = 0
    worst = 0
    n = 0
    for i in range(w * h):
        a, r, g, b = data[8 + 4 * i:12 + 4 * i]
        R, G, B, A = rp[4 * i:4 * i + 4]
        if A == 0 and a == 0:
            continue
        e = max(abs(r - R), abs(g - G), abs(b - B), abs(a - A))
        diff += e
        worst = max(worst, e)
        n += 1
    mean = diff / max(n, 1)
    ok = (mean <= 3.0 and worst <= 60) if lossy else worst == 0
    print("%s %s %dx%d mean %.2f max %d" % ("PASS" if ok else "FAIL", name, w, h, mean, worst))
    fail |= not ok
sys.exit(fail)
