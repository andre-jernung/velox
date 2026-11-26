#!/usr/bin/env python3
"""Write an LHA archive of files and the files under directories, paths
kept from their parent ("Velox/Velox.info", "Velox.info").  Each file is
compressed with -lh5- (LhA's usual method: an 8 KB window, Huffman
tables a block), or stored (-lh0-) if that is not smaller.

usage: mklha.py archive.lha dir|file ...
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


# -lh5-: as LHa's huf.c writes it
DICBIT, MAXMATCH, THRESHOLD = 13, 256, 3
NC, NT, NP = 256 + MAXMATCH - THRESHOLD + 1, 19, DICBIT + 1
CBIT, TBIT, PBIT = 9, 5, 4
BLOCK = 16000                   # symbols a block


class Bits:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def put(self, n, v):
        """n bits of v, the highest first"""
        if n == 0:
            return
        self.acc = (self.acc << n) | (v & ((1 << n) - 1))
        self.n += n
        while self.n >= 8:
            self.n -= 8
            self.out.append((self.acc >> self.n) & 0xFF)
        self.acc &= (1 << self.n) - 1

    def done(self):
        if self.n:
            self.out.append((self.acc << (8 - self.n)) & 0xFF)
        return bytes(self.out)


def huff_lengths(freq, limit=16):
    """code lengths (a complete code) for the symbols with freq > 0"""
    import heapq
    f = list(freq)
    while True:
        heap = [(c, i, (i,)) for i, c in enumerate(f) if c]
        lens = [0] * len(f)
        if len(heap) == 1:
            return lens
        heapq.heapify(heap)
        k = len(f)
        while len(heap) > 1:
            a, b = heapq.heappop(heap), heapq.heappop(heap)
            for s in a[2] + b[2]:
                lens[s] += 1
            heapq.heappush(heap, (a[0] + b[0], k, a[2] + b[2]))
            k += 1
        if max(lens) <= limit:
            return lens
        f = [(c + 1) // 2 if c else 0 for c in f]      # flatter, again


def huff_codes(lens):
    """canonical codes: shorter first, then by symbol"""
    codes, code = [0] * len(lens), 0
    for n in range(1, 17):
        for s, l in enumerate(lens):
            if l == n:
                codes[s] = code
                code += 1
        code <<= 1
    return codes


def table(bits, freq, nbit):
    """a code table: n = 0 and the one symbol if only one is used;
    Out: lengths, codes, n (symbols up to the last used)"""
    used = [i for i, c in enumerate(freq) if c]
    if len(used) <= 1:
        return None, used[0] if used else 0
    lens = huff_lengths(freq)
    return lens, huff_codes(lens)


def write_pt_len(bits, lens, nbit, special):
    n = len(lens)
    while n > 0 and lens[n - 1] == 0:
        n -= 1
    bits.put(nbit, n)
    i = 0
    while i < n:
        k = lens[i]
        i += 1
        if k <= 6:
            bits.put(3, k)
        else:
            bits.put(k - 3, (1 << (k - 3)) - 2)        # 1s, then a 0
        if i == special:
            while i < 6 and lens[i] == 0:
                i += 1
            bits.put(2, (i - 3) & 3)


def c_runs(c_len):
    """the C lengths as T symbols (0-2: runs of zeros) with their bits"""
    n = len(c_len)
    while n > 0 and c_len[n - 1] == 0:
        n -= 1
    out, i = [], 0
    while i < n:
        k = c_len[i]
        i += 1
        if k:
            out.append((k + 2, 0, 0))
            continue
        count = 1
        while i < n and c_len[i] == 0:
            i += 1
            count += 1
        if count <= 2:
            out += [(0, 0, 0)] * count
        elif count <= 18:
            out.append((1, 4, count - 3))
        elif count == 19:
            out += [(0, 0, 0), (1, 4, 15)]
        else:
            out.append((2, CBIT, count - 20))
    return n, out


def send_block(bits, syms):
    c_freq, p_freq = [0] * NC, [0] * NP
    for s in syms:
        if s[0] < 256:
            c_freq[s[0]] += 1
        else:
            c_freq[s[0]] += 1
            p_freq[s[1].bit_length()] += 1
    bits.put(16, len(syms))
    c_len, c_code = table(bits, c_freq, CBIT)
    if c_len is None:
        bits.put(TBIT, 0)
        bits.put(TBIT, 0)
        bits.put(CBIT, 0)
        bits.put(CBIT, c_code)
    else:
        n, runs = c_runs(c_len)
        t_freq = [0] * NT
        for r in runs:
            t_freq[r[0]] += 1
        t_len, t_code = table(bits, t_freq, TBIT)
        if t_len is None:
            bits.put(TBIT, 0)
            bits.put(TBIT, t_code)
            t_len, t_code = [0] * NT, [0] * NT
        else:
            write_pt_len(bits, t_len, TBIT, 3)
        bits.put(CBIT, n)
        for t, nb, v in runs:
            bits.put(t_len[t], t_code[t])
            bits.put(nb, v)
    p_len, p_code = table(bits, p_freq, PBIT)
    if p_len is None:
        bits.put(PBIT, 0)
        bits.put(PBIT, p_code)
        p_len, p_code = [0] * NP, [0] * NP
    else:
        write_pt_len(bits, p_len, PBIT, -1)
    for s in syms:
        bits.put(c_len[s[0]] if c_len else 0, c_code[s[0]] if c_len else 0)
        if s[0] >= 256:
            p = s[1]
            c = p.bit_length()
            bits.put(p_len[c], p_code[c])
            if c > 1:
                bits.put(c - 1, p)


def lh5(data):
    """data compressed: (char,) and (256 + len - 3, distance - 1)"""
    syms, chains, i, n = [], {}, 0, len(data)
    win = 1 << DICBIT
    while i < n:
        best, bpos = 0, 0
        if i + THRESHOLD <= n:
            key = data[i:i + THRESHOLD]
            cand = chains.get(key)
            if cand:
                lim = min(MAXMATCH, n - i)
                for j in reversed(cand[-48:]):
                    if i - j > win - 1:
                        break
                    if data[j + best] != data[i + best] if best < lim else True:
                        if best >= lim:
                            break
                        continue
                    k = 0
                    while k < lim and data[j + k] == data[i + k]:
                        k += 1
                    if k > best:
                        best, bpos = k, j
                        if k == lim:
                            break
        if best >= THRESHOLD:
            syms.append((256 + best - THRESHOLD, i - bpos - 1))
            step = best
        else:
            syms.append((data[i],))
            step = 1
        for k in range(i, min(i + step, n - THRESHOLD + 1)):
            chains.setdefault(data[k:k + THRESHOLD], []).append(k)
        i += step
    bits = Bits()
    for b in range(0, len(syms), BLOCK):
        send_block(bits, syms[b:b + BLOCK])
    return bits.done()


def entry(name, data, mtime):
    """a level 0 header and the data (compressed, if that is smaller)"""
    n = name.encode("latin-1")
    packed, method = (lh5(data), b"-lh5-") if data else (b"", b"-lh0-")
    if len(packed) >= len(data):
        packed, method = data, b"-lh0-"
    body = (method + len(packed).to_bytes(4, "little")
            + len(data).to_bytes(4, "little")
            + dostime(mtime).to_bytes(4, "little")
            + bytes([0x20, 0, len(n)]) + n
            + crc16(data).to_bytes(2, "little"))
    return bytes([len(body), sum(body) & 0xFF]) + body + packed


def main():
    out = sys.argv[1]
    parts = []
    for top in sys.argv[2:]:
        base = os.path.dirname(os.path.abspath(top))
        if os.path.isdir(top):
            paths = []
            for root, dirs, files in os.walk(top):
                dirs.sort()
                paths += [os.path.join(root, f) for f in sorted(files)]
        else:
            paths = [top]
        for p in paths:
            name = os.path.relpath(p, base).replace(os.sep, "/")
            with open(p, "rb") as fh:
                parts.append(entry(name, fh.read(), os.path.getmtime(p)))
    with open(out, "wb") as fh:
        fh.write(b"".join(parts) + b"\0")


if __name__ == "__main__":
    main()
