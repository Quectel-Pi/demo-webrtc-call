#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Signaling server + static file server; forwards SDP / ICE only, never handles media.

  python3 src/server.py                             # http://0.0.0.0:8080
  python3 src/server.py --tls --port 8443 --http-port 8080
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import ssl
import struct
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 1 << 20          # Max frame size 1 MiB (SDP is usually 3-10 KB)
MAX_ROOM_PEERS = 4           # Max peers per room (mesh demo, the board CPU is limited)
PING_INTERVAL = 25           # seconds; stops NAT / middleboxes from dropping idle connections

HERE = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(HERE, "web")
CERT_DIR = os.path.join(HERE, "certs")
VERBOSE = False
START_TS = time.time()
REPORTS: dict[str, dict] = {}
REPORT_LOCK = threading.Lock()


def log(*a):
    sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), " ".join(str(x) for x in a)))
    sys.stderr.flush()


def vlog(*a):
    if VERBOSE:
        log(*a)


# ---------------------------- Minimal WebSocket implementation (RFC 6455) ----------------------------
def ws_accept_key(client_key: str) -> str:
    return base64.b64encode(
        hashlib.sha1((client_key + WS_GUID).encode()).digest()
    ).decode()


def ws_encode(opcode: int, payload: bytes) -> bytes:
    n = len(payload)
    head = struct.pack("!BB", 0x80 | opcode, n if n < 126 else (126 if n < 65536 else 127))
    if n >= 126:
        head = struct.pack("!BB", 0x80 | opcode, 126) + struct.pack("!H", n) if n < 65536 else \
               struct.pack("!BB", 0x80 | opcode, 127) + struct.pack("!Q", n)
    return head + payload


def _read_exact(rfile, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = rfile.read(n - len(buf))
        if not chunk:
            raise ConnectionError("socket closed")
        buf += chunk
    return bytes(buf)


def ws_read(rfile):
    """Return (opcode, payload); control frames keep their own opcode."""
    h = _read_exact(rfile, 2)
    opcode = h[0] & 0x0F
    masked = bool(h[1] & 0x80)
    n = h[1] & 0x7F
    if n == 126:
        n = struct.unpack("!H", _read_exact(rfile, 2))[0]
    elif n == 127:
        n = struct.unpack("!Q", _read_exact(rfile, 8))[0]
    if n > MAX_FRAME:
        raise ConnectionError("frame too large (%d)" % n)
    key = _read_exact(rfile, 4) if masked else b""
    data = _read_exact(rfile, n) if n else b""
    if masked:
        data = bytes(b ^ key[i & 3] for i, b in enumerate(data))
    return opcode, data


# --------------------------------------------------------------------------
# Rooms / participants
# --------------------------------------------------------------------------
class Client:
    def __init__(self, cid: str, name: str, send):
        self.id = cid
        self.name = name
        self.send = send          # thread-safe send function
        self.room = None
        self.mic = True
        self.cam = True

    def info(self):
        return {"id": self.id, "name": self.name, "mic": self.mic, "cam": self.cam}


class Hub:
    def __init__(self):
        self.lock = threading.RLock()
        self.rooms: dict[str, dict[str, Client]] = {}

    def join(self, client: Client, room: str) -> list[Client]:
        with self.lock:
            peers = self.rooms.setdefault(room, {})
            if len(peers) >= MAX_ROOM_PEERS:
                raise RuntimeError("Room is full (limit %d peers)" % MAX_ROOM_PEERS)
            existing = list(peers.values())
            peers[client.id] = client
            client.room = room
            return existing

    def leave(self, client: Client) -> list[Client]:
        with self.lock:
            peers = self.rooms.get(client.room or "", {})
            peers.pop(client.id, None)
            remaining = list(peers.values())
            if not peers and client.room in self.rooms:
                del self.rooms[client.room]
            client.room = None
            return remaining

    def get(self, room: str, cid: str):
        with self.lock:
            return self.rooms.get(room, {}).get(cid)

    def snapshot(self):
        with self.lock:
            return {r: [c.info() for c in ps.values()] for r, ps in self.rooms.items()}


HUB = Hub()


# --------------------------------------------------------------------------
# HTTP + WS handler
# --------------------------------------------------------------------------
MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".webmanifest": "application/manifest+json",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "demo-webrtc-call/1.0"

    # ---------------------------------------------------------------- utils
    def log_message(self, fmt, *args):
        vlog("[http]", self.address_string(), fmt % args)

    def _send_body(self, code: int, body: bytes, ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code: int, obj):
        self._send_body(code, json.dumps(obj, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    # ---------------------------------------------------------------- routes
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/ws":
            return self._ws_upgrade()
        if path == "/tunnel":
            # Return the current tunnel URL; the page shows a "Phone" banner at the top
            tf = os.path.normpath(os.path.join(HERE, "..", "local", "tunnel-url.txt"))
            url = ""
            try:
                with open(tf, "r", encoding="utf-8") as f:
                    url = (f.read().strip().splitlines() or [""])[0]
            except OSError:
                url = ""
            if not url.startswith("http"):
                return self._json(404, {"error": "no tunnel url"})
            # Only accept the random Cloudflare quick-tunnel hostname, so stale or error lines are never used as a URL
            if not re.match(r"^https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com$", url):
                return self._json(404, {"error": "invalid tunnel url"})
            return self._json(200, {"url": url})
        if path == "/healthz":
            with REPORT_LOCK:
                reports = dict(REPORTS)
            return self._json(200, {
                "ok": True,
                "uptime_s": round(time.time() - START_TS, 1),
                "tls": isinstance(self.connection, ssl.SSLSocket),
                "rooms": HUB.snapshot(),
                "reports": reports,
            })
        return self._serve_static(path)

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/report":
            return self._json(405, {"error": "method not allowed"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > 64 * 1024:
                return self._json(400, {"error": "bad length"})
            payload = json.loads(_read_exact(self.rfile, n).decode("utf-8", "replace"))
        except Exception as e:                                    # noqa: BLE001
            return self._json(400, {"error": "bad json: %s" % e})
        key = str(payload.get("name") or payload.get("id") or "anon")[:48]
        with REPORT_LOCK:
            REPORTS[key] = {"at": round(time.time(), 1), "from": self.address_string(), "state": payload}
            if len(REPORTS) > 32:
                for k in sorted(REPORTS, key=lambda k: REPORTS[k]["at"])[:-32]:
                    REPORTS.pop(k, None)
        vlog("[report]", key, json.dumps(payload, ensure_ascii=False)[:400])
        self._json(200, {"ok": True})

    def _serve_static(self, path: str):
        if path in ("", "/"):
            path = "/index.html"
        rel = unquote(path).lstrip("/")
        full = os.path.normpath(os.path.join(WEB_DIR, rel))
        if not full.startswith(WEB_DIR) or not os.path.isfile(full):
            return self._send_body(404, ("404 %s not found" % rel).encode())
        ext = os.path.splitext(full)[1].lower()
        with open(full, "rb") as f:
            data = f.read()
        self._send_body(200, data, MIME.get(ext, "application/octet-stream"))

    # ------------------------------------------------------------ websocket
    def _ws_upgrade(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            return self._send_body(400, b"missing Sec-WebSocket-Key")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", ws_accept_key(key))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        try:
            self._ws_session()
        except (ConnectionError, OSError, ssl.SSLError):
            pass
        except Exception as e:                                    # noqa: BLE001
            vlog("ws session error:", repr(e))

    def _ws_session(self):
        wlock = threading.Lock()
        closed = threading.Event()

        def send_obj(obj) -> bool:
            if closed.is_set():
                return False
            payload = json.dumps(obj, ensure_ascii=False).encode()
            try:
                with wlock:
                    self.wfile.write(ws_encode(0x1, payload))
                    self.wfile.flush()
                return True
            except (OSError, ValueError):
                closed.set()
                return False

        client: Client | None = None
        stop_ping = threading.Event()

        def ping_loop():
            while not stop_ping.wait(PING_INTERVAL):
                try:
                    with wlock:
                        self.wfile.write(ws_encode(0x9, b""))
                        self.wfile.flush()
                except (OSError, ValueError):
                    return

        threading.Thread(target=ping_loop, daemon=True).start()
        try:
            while True:
                opcode, data = ws_read(self.rfile)
                if opcode == 0x8:                                   # close
                    break
                if opcode == 0x9:                                   # ping → pong
                    with wlock:
                        self.wfile.write(ws_encode(0xA, data))
                        self.wfile.flush()
                    continue
                if opcode == 0xA:                                   # pong
                    continue
                if opcode not in (0x1, 0x2):
                    continue
                try:
                    msg = json.loads(data.decode("utf-8", "replace"))
                except json.JSONDecodeError:
                    continue
                if not isinstance(msg, dict):
                    continue

                mtype = msg.get("type")

                if mtype == "join":
                    if client:
                        send_obj({"type": "error", "message": "Already in a room"})
                        continue
                    room = str(msg.get("room") or "demo")[:32]
                    name = str(msg.get("name") or "anonymous")[:32]
                    c = Client(uuid.uuid4().hex[:8], name, send_obj)
                    try:
                        existing = HUB.join(c, room)
                    except RuntimeError as e:
                        send_obj({"type": "error", "message": str(e)})
                        break
                    client = c
                    log("join room=%s id=%s name=%s peers=%d" % (room, c.id, name, len(existing)))
                    send_obj({
                        "type": "welcome",
                        "id": c.id,
                        "room": room,
                        "peers": [e.info() for e in existing],
                        "limit": MAX_ROOM_PEERS,
                    })
                    for e in existing:
                        e.send({"type": "peer-join", "peer": c.info()})
                    continue

                if not client:
                    send_obj({"type": "error", "message": "Join a room first"})
                    continue

                if mtype == "signal":
                    target = msg.get("to")
                    peer = HUB.get(client.room, str(target)) if target else None
                    if peer is None:
                        send_obj({"type": "error", "message": "Peer does not exist or has already left"})
                        continue
                    peer.send({"type": "signal", "from": client.id, "data": msg.get("data")})
                    continue

                if mtype == "state":
                    client.mic = bool(msg.get("mic", True))
                    client.cam = bool(msg.get("cam", True))
                    for e in HUB.snapshot_peers(client):
                        e.send({"type": "peer-state", "id": client.id, "mic": client.mic, "cam": client.cam})
                    continue

                if mtype == "bye":
                    break
        finally:
            stop_ping.set()
            closed.set()
            if client:
                for e in HUB.leave(client):
                    e.send({"type": "peer-leave", "id": client.id})
                log("leave room=%s id=%s" % (client.room or "-", client.id))
            try:
                with wlock:
                    self.wfile.write(ws_encode(0x8, b""))
                    self.wfile.flush()
            except (OSError, ValueError):
                pass


def _snapshot_peers(self, client):
    with self.lock:
        return [c for c in self.rooms.get(client.room or "", {}).values() if c.id != client.id]


Hub.snapshot_peers = _snapshot_peers     # Helper: other participants in the same room


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv=None):
    global VERBOSE
    ap = argparse.ArgumentParser(description="WebRTC demo signaling server (zero dependencies)")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=0, help="default 8443 (--tls) / 8080")
    ap.add_argument("--tls", action="store_true", help="enable HTTPS/WSS (self-signed or local CA certificate)")
    ap.add_argument("--http-port", type=int, default=0,
                    help="also listen on a plain HTTP port (localhost is already a secure context,"
                         " so the board browser bypasses every certificate issue)")
    ap.add_argument("--cert", default=os.path.join(CERT_DIR, "cert.pem"))
    ap.add_argument("--key", default=os.path.join(CERT_DIR, "key.pem"))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    VERBOSE = args.verbose
    port = args.port or (8443 if args.tls else 8080)

    httpd = Server((args.host, port), Handler)
    scheme = "http"

    if args.tls:
        if not (os.path.isfile(args.cert) and os.path.isfile(args.key)):
            log("Certificate not found: %s / %s" % (args.cert, args.key))
            log("Run this first: bash src/tools/make_cert.sh")
            return 2
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.cert, args.key)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    ips = []
    try:
        for line in os.popen("hostname -I 2>/dev/null").read().split():
            if ":" not in line:
                ips.append(line)
    except Exception:                                   # noqa: BLE001
        pass

    if args.http_port:
        plain = Server((args.host, args.http_port), Handler)
        threading.Thread(target=plain.serve_forever, daemon=True).start()
        log("Extra plain-HTTP port listening  http://%s:%d   (board browser: http://localhost:%d, no certificate needed)"
            % (args.host, args.http_port, args.http_port))

    log("Signaling server started  %s://%s:%d   (web root: %s)" % (scheme, args.host, port, WEB_DIR))
    for ip in ips:
        log("  → %s://%s:%d" % (scheme, ip, port))
    log("  Limit %d peers per room; Ctrl+C to quit" % MAX_ROOM_PEERS)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("bye")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
