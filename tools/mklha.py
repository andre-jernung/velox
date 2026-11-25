#!/usr/bin/env python3
"""Write an LHA archive (method -lh0-: stored, which every LhA reads)
of the files under a directory, paths kept ("Velox/Velox.info").

usage: mklha.py archive.lha dir
"""
import os
import sys
import time


def crc16(data):
    """CRC-16/ARC, as LHA uses"""
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def dostime(t):
    lt = time.localtime(t)
    tm = (lt.tm_hour << 11) | (lt.tm_min << 5) | (lt.tm_sec // 2)
    dt = ((lt.tm_year - 1980) << 9) | (lt.tm_mon << 5) | lt.tm_mday
    return tm | (dt << 16)


def entry(name, data, mtime):
    """a level 0 header and the data"""
    n = name.encode("latin-1")
    body = (b"-lh0-" + len(data).to_bytes(4, "little")
            + len(data).to_bytes(4, "little")
            + dostime(mtime).to_bytes(4, "little")
            + bytes([0x20, 0, len(n)]) + n
            + crc16(data).to_bytes(2, "little"))
    return bytes([len(body), sum(body) & 0xFF]) + body + data


def main():
    out, top = sys.argv[1], sys.argv[2]
    base = os.path.dirname(os.path.abspath(top))
    parts = []
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            name = os.path.relpath(p, base).replace(os.sep, "/")
            with open(p, "rb") as fh:
                parts.append(entry(name, fh.read(), os.path.getmtime(p)))
    with open(out, "wb") as fh:
        fh.write(b"".join(parts) + b"\0")


if __name__ == "__main__":
    main()
