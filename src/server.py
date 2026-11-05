#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
信令服务器 + 静态文件服务，只转发 SDP / ICE，不处理媒体。

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
MAX_FRAME = 1 << 20          # 单帧上限 1 MiB（SDP 通常 3~10 KB）
MAX_ROOM_PEERS = 4           # 一个房间最多几路（mesh demo，板子 CPU 有限）
PING_INTERVAL = 25           # 秒；防止 NAT/中间设备把空闲连接掐掉

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


# ---------------------------- 最小 WebSocket 实现（RFC 6455） ----------------------------
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
    """返回 (opcode, payload)；控制帧的 opcode 原样返回。"""
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
# 房间 / 参与者
# --------------------------------------------------------------------------
class Client:
    def __init__(self, cid: str, name: str, send):
        self.id = cid
        self.name = name
        self.send = send          # thread-safe 发送函数
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
                raise RuntimeError("房间已满（上限 %d 路）" % MAX_ROOM_PEERS)
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
# HTTP + WS 处理器
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
            # 返回当前隧道地址，页面顶部会显示“手机访问”
            tf = os.path.normpath(os.path.join(HERE, "..", "local", "tunnel-url.txt"))
            url = ""
            try:
                with open(tf, "r", encoding="utf-8") as f:
                    url = (f.read().strip().splitlines() or [""])[0]
            except OSError:
                url = ""
            if not url.startswith("http"):
                return self._json(404, {"error": "no tunnel url"})
            # 只接受 Cloudflare 快速隧道的随机域名，防止残留的脏数据/错误行被当成地址
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
                        send_obj({"type": "error", "message": "已经加入房间"})
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
                    send_obj({"type": "error", "message": "请先 join"})
                    continue

                if mtype == "signal":
                    target = msg.get("to")
                    peer = HUB.get(client.room, str(target)) if target else None
                    if peer is None:
                        send_obj({"type": "error", "message": "对端不存在或已离开"})
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


Hub.snapshot_peers = _snapshot_peers     # 小工具：同房间的其他参与者


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv=None):
    global VERBOSE
    ap = argparse.ArgumentParser(description="WebRTC demo 信令服务器（零依赖）")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=0, help="默认 8443 (--tls) / 8080")
    ap.add_argument("--tls", action="store_true", help="启用 HTTPS/WSS（自签/本地 CA 证书）")
    ap.add_argument("--http-port", type=int, default=0,
                    help="额外再监听一个明文 HTTP 端口（localhost 本来就是安全上下文，"
                         "板端浏览器用它可绕过一切证书问题）")
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
            log("找不到证书：%s / %s" % (args.cert, args.key))
            log("先跑： bash scripts/make-cert.sh")
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
        log("额外明文端口已启动  http://%s:%d   （板端浏览器用 http://localhost:%d 可免证书）"
            % (args.host, args.http_port, args.http_port))

    log("信令服务器已启动  %s://%s:%d   (web root: %s)" % (scheme, args.host, port, WEB_DIR))
    for ip in ips:
        log("  → %s://%s:%d" % (scheme, ip, port))
    log("  房间上限 %d 路 / 房间；Ctrl+C 退出" % MAX_ROOM_PEERS)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("bye")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
