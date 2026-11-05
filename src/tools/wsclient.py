#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Minimal WebSocket client (standard library only)

Used by:
  * src/tools/test_signaling.py -- verify the signaling server without a browser
  * gst/webrtc_send.py         -- GStreamer native endpoint on the same JSON signaling
"""
from __future__ import annotations

import base64
import json
import os
import socket
import ssl
import struct

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WSClient:
    def __init__(self, host: str, port: int, path: str = "/ws", tls: bool = False, timeout: float = 10.0):
        self.host, self.port, self.path, self.tls = host, port, path, tls
        self.timeout = timeout
        self.sock: socket.socket | None = None
        self.buf = b""

    # ------------------------------------------------------------- connect
    def connect(self, extra_headers: dict | None = None) -> "WSClient":
        raw = socket.create_connection((self.host, self.port), timeout=self.timeout)
        if self.tls:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            raw = ctx.wrap_socket(raw, server_hostname=self.host)
        self.sock = raw
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            f"GET {self.path} HTTP/1.1",
            f"Host: {self.host}:{self.port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        for k, v in (extra_headers or {}).items():
            lines.append(f"{k}: {v}")
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = self._read_until(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode(errors="replace")
        if "101" not in status:
            raise ConnectionError("WebSocket handshake failed: " + status)
        accept = base64.b64encode(
            __import__("hashlib").sha1((key + WS_GUID).encode()).digest()
        ).decode()
        if accept.lower() not in head.decode(errors="replace").lower():
            raise ConnectionError("Sec-WebSocket-Accept validation failed")
        self.sock.settimeout(self.timeout)
        return self

    # ------------------------------------------------------------- send / receive
    def _read_until(self, marker: bytes) -> bytes:
        assert self.sock
        while marker not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("Connection closed")
            self.buf += chunk
        head, _, self.buf = self.buf.partition(marker)
        return head + marker

    def _read_exact(self, n: int) -> bytes:
        assert self.sock
        while len(self.buf) < n:
            chunk = self.sock.recv(max(4096, n - len(self.buf)))
            if not chunk:
                raise ConnectionError("Connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, payload) -> None:
        assert self.sock
        data = json.dumps(payload, ensure_ascii=False).encode() if not isinstance(payload, (bytes, str)) \
            else (payload.encode() if isinstance(payload, str) else payload)
        n = len(data)
        head = struct.pack("!BB", 0x81, 0x80 | (n if n < 126 else 126))
        if n >= 126:
            head = struct.pack("!BBH", 0x81, 0x80 | 126, n) if n < 65536 else \
                   struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        key = os.urandom(4)
        masked = bytes(b ^ key[i & 3] for i, b in enumerate(data))
        self.sock.sendall(head + key + masked)

    def recv(self) -> tuple[int, bytes]:
        """Return (opcode, payload). 0x1/0x2 are data frames, 0x8 is close."""
        h = self._read_exact(2)
        opcode = h[0] & 0x0F
        masked = bool(h[1] & 0x80)
        n = h[1] & 0x7F
        if n == 126:
            n = struct.unpack("!H", self._read_exact(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", self._read_exact(8))[0]
        key = self._read_exact(4) if masked else b""
        data = self._read_exact(n) if n else b""
        if masked:
            data = bytes(b ^ key[i & 3] for i, b in enumerate(data))
        return opcode, data

    def recv_json(self, want: set[str] | None = None) -> dict:
        while True:
            opcode, data = self.recv()
            if opcode == 0x8:
                raise ConnectionError("Server closed the connection")
            if opcode not in (0x1, 0x2):
                continue
            msg = json.loads(data.decode("utf-8", "replace"))
            if not want or msg.get("type") in want:
                return msg

    def close(self) -> None:
        try:
            if self.sock:
                self.sock.sendall(struct.pack("!BB", 0x88, 0x82) + b"\x00\x00\x00\x00" + b"\x03\xe8")
        except OSError:
            pass
        try:
            if self.sock:
                self.sock.close()
        except OSError:
            pass
        self.sock = None
