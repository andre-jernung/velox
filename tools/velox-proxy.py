#!/usr/bin/env python3
"""velox-proxy - let Velox (or any old browser) reach https:// sites.

Run this on a modern machine on the same network as the Amiga:

    python3 velox-proxy.py --bind 192.168.1.10 --port 8888

and tell Velox about it, either on the command line

    velox PROXY=192.168.1.10:8888

or for good, in the Amiga Shell:

    SetEnv SAVE Velox/Proxy 192.168.1.10:8888

Velox then sends every request to the proxy with the full URL
("GET https://example.com/ HTTP/1.1").  The proxy fetches it, with TLS
where needed, and returns the plain HTTP response.  Redirects are passed
back to the browser and responses are never compressed.

This is an open proxy for anyone who can reach the port.  By default it
only listens on localhost; use --bind for your LAN and --allow to name
the clients that may use it.
"""
import argparse
import http.client
import http.server
import ipaddress
import ssl
import sys
import threading
import time
import urllib.parse

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade", "proxy-connection"}
MAX_BODY = 32 * 1024 * 1024
IDLE_MAX = 4        # idle connections kept a server
IDLE_SECS = 30      # dropped when idle longer than this

# Upstream connections are kept alive and reused.  Opening a new one for
# every request (each image of a page) makes some servers refuse
# connections for a while: the Wayback Machine does after about 50 in a
# minute or two, and the rest of a page's images then fail.
pool = {}
pool_lock = threading.Lock()


def pool_get(key):
    """An idle connection to key, or None."""
    now = time.monotonic()
    with pool_lock:
        idle = pool.get(key, [])
        while idle:
            c, t = idle.pop()
            if now - t < IDLE_SECS:
                return c
            c.close()
    return None


def pool_put(key, c):
    with pool_lock:
        idle = pool.setdefault(key, [])
        if len(idle) < IDLE_MAX:
            idle.append((c, time.monotonic()))
            return
    c.close()


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "velox-proxy"
    ctx = None
    allow = None

    def log_message(self, fmt, *args):
        sys.stderr.write("velox-proxy: " + fmt % args + "\n")

    def reply(self, code, text):
        body = text.encode("latin-1", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        if self.allow and not any(ipaddress.ip_address(self.client_address[0]) in n
                                  for n in self.allow):
            return self.reply(403, "not allowed\n")
        u = urllib.parse.urlsplit(self.path)
        if u.scheme not in ("http", "https") or not u.hostname:
            return self.reply(400, "velox-proxy: send absolute http:// or https:// URLs\n")
        body = None
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            body = self.rfile.read(min(n, MAX_BODY))
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP and k.lower() != "host"}
        headers["Accept-Encoding"] = "identity"
        target = urllib.parse.urlunsplit(("", "", u.path or "/", u.query, ""))
        key = (u.scheme, u.hostname, u.port)
        try:
            for attempt in (0, 1):
                c = pool_get(key) if attempt == 0 else None
                reused = c is not None
                if c is None:
                    if u.scheme == "https":
                        c = http.client.HTTPSConnection(u.hostname, u.port or 443,
                                                        timeout=60, context=self.ctx)
                    else:
                        c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=60)
                try:
                    c.request(self.command, target, body=body, headers=headers)
                    r = c.getresponse()
                    data = r.read(MAX_BODY)
                    break
                except (http.client.RemoteDisconnected, ConnectionError):
                    c.close()
                    if not reused:      # a kept connection the server closed: once more
                        raise
        except Exception as e:
            c.close()
            return self.reply(502, "velox-proxy: %s: %s\n" % (u.hostname, e))
        if r.will_close or not r.isclosed():
            c.close()
        else:
            pool_put(key, c)
        self.log_request(r.status)
        self.send_response_only(r.status, r.reason)
        for k, v in r.getheaders():
            if k.lower() in HOP_BY_HOP or k.lower() in ("content-length", "content-encoding"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    do_GET = do_POST = do_HEAD = do_PUT = do_DELETE = handle_any


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bind", default="127.0.0.1", help="address to listen on")
    ap.add_argument("--port", type=int, default=8888)
    ap.add_argument("--allow", action="append", default=[],
                    help="client network allowed to connect (CIDR), may repeat")
    ap.add_argument("--insecure", action="store_true",
                    help="do not verify server certificates (testing only)")
    a = ap.parse_args()
    Proxy.ctx = ssl.create_default_context()
    if a.insecure:
        Proxy.ctx.check_hostname = False
        Proxy.ctx.verify_mode = ssl.CERT_NONE
    Proxy.allow = [ipaddress.ip_network(n, strict=False) for n in a.allow] or None
    srv = http.server.ThreadingHTTPServer((a.bind, a.port), Proxy)
    sys.stderr.write("velox-proxy listening on %s:%d\n" % (a.bind, a.port))
    srv.serve_forever()


if __name__ == "__main__":
    main()
