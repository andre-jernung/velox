#!/usr/bin/env python3
"""Deterministic HTTP test server for the Velox emulator tests.

usage: server.py PORT [DOCROOT] [TLSPORT CERT KEY]

Fixed routes are below; anything else is served from DOCROOT (test/www).
"""
import http.server
import os
import sys
import time

BIG = bytes((i * 7 + 13) % 251 for i in range(100000))
HELLO = b"Hello from the Velox test server\n"
SLOW_HITS = {}                  # requests for each /slow/ image
CACHED = {"v": 1, "200": 0, "304": 0}  # /cached: version, replies
DOCROOT = sys.argv[2] if len(sys.argv) > 2 else "test/www"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("server: [%d] %s\n" % (self.client_address[1], fmt % args))

    def send(self, code, body, ctype="text/plain", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path
        if p == "/hello":
            self.send(200, HELLO)
        elif p == "/chunked":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (b"chunk one, ", b"chunk two, ", b"chunk three\n"):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
            self.wfile.write(b"0\r\n\r\n")
        elif p == "/setcookie":
            self.send(302, b"", headers=[("Location", "/echo/cookie"),
                                         ("Set-Cookie", "test=42; Path=/"),
                                         ("Set-Cookie", "other=x; Path=/nowhere")])
        elif p == "/setcookie2":
            self.send(302, b"", headers=[("Location", "/echo/cookie"),
                                         ("Set-Cookie", "sess=2; Path=/"),
                                         ("Set-Cookie", "keep=1; Max-Age=86400; Path=/"),
                                         ("Set-Cookie", "far=3; Expires=Mon, 01 Jan 2060 00:00:00 GMT; Path=/")])
        elif p == "/auth":
            if self.headers.get("Authorization") == "Basic dXNlcjpwdw==":
                self.send(200, b"auth ok\n")
            else:
                self.send(401, b"<title>Login</title><p>Who are you?",
                          "text/html", headers=[("WWW-Authenticate", 'Basic realm="test"')])
        elif p.startswith("/slowcount/"):
            # requests for /slow/ images whose names start with this
            n = p[len("/slowcount/"):]
            self.send(200, b"%d" % sum(v for k, v in SLOW_HITS.items() if k.startswith(n)))
        elif p == "/cached":
            # a page with a validator: 304 when the browser has it
            tag = '"v%d"' % CACHED["v"]
            if self.headers.get("If-None-Match") == tag:
                CACHED["304"] += 1
                self.send_response(304)
                self.send_header("ETag", tag)
                self.end_headers()
            else:
                CACHED["200"] += 1
                self.send(200, b"<title>Cached v%d</title><p>Version %d of the page." % (CACHED["v"], CACHED["v"]),
                          "text/html", headers=[("ETag", tag)])
        elif p == "/cached-bump":
            CACHED["v"] += 1
            self.send(200, b"%d" % CACHED["v"])
        elif p == "/cached-count":
            self.send(200, b"200:%d 304:%d" % (CACHED["200"], CACHED["304"]))
        elif p == "/trickle":
            # a page in three parts, 5 s apart (chunked): shown as it
            # comes; its style sheet is fetched in the middle of it
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            para = "".join("<p>Paragraph %d of the page that trickles in, with a few words.</p>\n" % i for i in range(60))
            parts = ['<html><head><title>Trickle</title><link rel="stylesheet" href="css/trickle.css"></head>'
                     '<body><p><a href="#late">To the late part</a></p>\n' + para,
                     "<h2>Second part</h2>\n" + para,
                     '<h2 id="late">The late part</h2>\n' + para + "</body></html>"]
            for i, part in enumerate(parts):
                if i:
                    time.sleep(5)
                data = part.encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        elif p == "/slowpage":
            time.sleep(12)
            self.send(200, b"<title>Slow</title><p>A slow page.", "text/html")
        elif p.startswith("/slow/"):
            # a slow image: the browser must stay usable meanwhile
            SLOW_HITS[p[6:]] = SLOW_HITS.get(p[6:], 0) + 1
            time.sleep(8)
            with open(os.path.join(DOCROOT, "test.iff"), "rb") as f:
                self.send(200, f.read(), "image/x-ilbm")
        elif p == "/redirect":
            self.send(302, b"", headers=[("Location", "/hello")])
        elif p == "/redirect-rel":
            self.send(301, b"moved", headers=[("Location", "sub/../hello")])
        elif p == "/loop":
            self.send(302, b"", headers=[("Location", "/loop")])
        elif p == "/big":
            self.send(200, BIG, "application/octet-stream")
        elif p.startswith("/echo"):
            # body = request line + headers as received
            lines = [self.requestline] + [f"{k}: {v}" for k, v in self.headers.items()]
            self.send(200, ("\n".join(lines) + "\n").encode("latin-1"))
        else:
            path = os.path.normpath(p.split("?")[0]).lstrip("/")
            full = os.path.join(DOCROOT, path)
            if os.path.isdir(full):
                full = os.path.join(full, "index.html")
            if os.path.isfile(full) and os.path.realpath(full).startswith(os.path.realpath(DOCROOT)):
                ctype = "text/html; charset=utf-8" if full.endswith(".html") else "application/octet-stream"
                with open(full, "rb") as f:
                    self.send(200, f.read(), ctype)
            else:
                self.send(404, b"not found\n")


    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        sys.stderr.write("server: POST %s body=%s\n" % (self.path, body.decode("latin-1")))
        if self.path.startswith("/echo"):
            text = "%s\n%s\n" % (self.requestline, body.decode("latin-1"))
            self.send(200, text.encode("latin-1"))
        else:
            self.send(404, b"not found\n")


if __name__ == "__main__":
    import ssl
    import threading
    port = int(sys.argv[1])
    if len(sys.argv) > 5:  # the same site over TLS as well; also on
        # 127.0.0.2, which the certificate does not name
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(sys.argv[4], sys.argv[5])
        for addr in ("127.0.0.1", "127.0.0.2"):
            tls = http.server.ThreadingHTTPServer((addr, int(sys.argv[3])), Handler)
            tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
            threading.Thread(target=tls.serve_forever, daemon=True).start()
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
