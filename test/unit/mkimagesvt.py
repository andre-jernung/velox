#!/usr/bin/env python3
"""Write test/unit/images.vt: decode every image mkimages.py makes."""
import os
import subprocess
import sys

d = "build/img"
subprocess.run([sys.executable, "test/unit/mkimages.py", d], check=True)
names = sorted(n for n in os.listdir(d) if not n.endswith((".argb", ".bad")))
lines = ["# Velox's own image decoders; test/unit/cmpimages.py compares the",
         "# pixels with PIL's (the images are made by test/unit/mkimages.py,",
         "# this list by mkimagesvt.py); cut*/bad* are broken files, which",
         "# must not crash the decoders"]
for n in names:
    ext = ".bad" if n.startswith(("cut", "bad")) else ".argb"
    lines.append("decode %s/%s %s/%s%s" % (d, n, d, n, ext))
open("test/unit/images.vt", "w").write("\n".join(lines) + "\n")
