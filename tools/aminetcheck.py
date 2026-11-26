#!/usr/bin/env python3
"""Check an upload for Aminet (wiki.aminet.net/Uploading_instructions,
The_Readme_file): the readme's fields (Short: first, at most 40
characters; Uploader, Type, Architecture there), its lines (78
characters at most, LF only), the file names (30 characters at most,
letters, digits, ". _ -", the same base name), and the archive (7z
tests it, if there is 7z).

usage: aminetcheck.py archive.lha archive.readme
"""
import os
import re
import shutil
import subprocess
import sys

lha, readme = sys.argv[1], sys.argv[2]
bad = []
for p in (lha, readme):
    n = os.path.basename(p)
    if len(n) > 30:
        bad.append("%s: longer than 30 characters" % n)
    if not re.fullmatch(r"[A-Za-z0-9._-]+", n):
        bad.append("%s: characters other than letters, digits, . _ -" % n)
if os.path.splitext(os.path.basename(lha))[0] != os.path.splitext(os.path.basename(readme))[0]:
    bad.append("the archive and the readme have different base names")
data = open(readme, "rb").read()
if b"\r" in data:
    bad.append("CR in the readme (LF only)")
lines = data.decode("latin-1").split("\n")
if not lines[0].startswith("Short:"):
    bad.append("Short: is not the first line")
fields = {}
for l in lines:
    if not l.strip():
        break
    m = re.match(r"([A-Za-z]+):\s*(.*)", l)
    if not m:
        bad.append("not a field: %r" % l)
        continue
    fields[m.group(1)] = m.group(2)
if len(fields.get("Short", "")) > 40:
    bad.append("Short: longer than 40 characters")
for f in ("Short", "Uploader", "Type", "Architecture"):
    if not fields.get(f):
        bad.append("no %s:" % f)
if "@" in data.decode("latin-1") and "@AUTHOR@" in data.decode("latin-1"):
    bad.append("@AUTHOR@ not filled in")
for i, l in enumerate(lines, 1):
    if len(l) > 78:
        bad.append("line %d: %d characters" % (i, len(l)))
if shutil.which("7z"):
    r = subprocess.run(["7z", "t", lha], capture_output=True, text=True)
    if "Everything is Ok" not in r.stdout:
        bad.append("7z t %s: %s" % (lha, r.stdout[-300:]))
for b in bad:
    print("aminetcheck:", b)
sys.exit(1 if bad else 0)
