#!/usr/bin/env python3
"""Write canned HTTP responses for the vtest 'http' tests into DIR."""
import os
import sys

d = sys.argv[1]
os.makedirs(d, exist_ok=True)

big = bytes((i * 7 + 13) % 251 for i in range(40000))
chunks = b"".join(b"%x\r\n" % len(c) + c + b"\r\n"
                  for c in (big[:5000], big[5000:5001], big[5001:23000], big[23000:]))

cases = {
    "length": b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
              b"Content-Length: 11\r\n\r\nhello world",
    "chunked": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
               b"5\r\nhello\r\n7;ext=1\r\n, world\r\n0\r\nX-Trailer: y\r\n\r\n",
    "redirect": b"HTTP/1.1 301 Moved Permanently\r\nLocation:  /new/place?a=1 \r\n"
                b"Content-Length: 0\r\n\r\n",
    "eof": b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nline1\nline2\n",
    "continue": b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 404 Not Found\r\n"
                b"content-length: 3\r\n\r\nnop",
    "notmodified": b"HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n",
    "lfonly": b"HTTP/1.1 200 OK\nContent-Length: 2\n\nhi",
    "short": b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly this",
    "garbage": b"SSH-2.0-OpenSSH_9.6\r\n",
    "empty": b"",
    "biglength": b"HTTP/1.1 200 OK\r\nContent-Length: 40000\r\n\r\n" + big,
    "bigchunked": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n" + chunks + b"0\r\n\r\n",
    "bigeof": b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" + big,
}
for name, data in cases.items():
    with open(os.path.join(d, name + ".txt"), "wb") as f:
        f.write(data)

# checksum used by vtest httpinfo: sum of byte * (1-based position), 32 bit
s = sum(b * (i + 1) for i, b in enumerate(big)) & 0xFFFFFFFF
if s >= 0x80000000:
    s -= 0x100000000
with open(os.path.join(d, "bigsum.txt"), "w") as f:
    f.write(str(s))
