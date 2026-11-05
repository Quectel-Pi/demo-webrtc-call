#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Signaling server self-test (no browser required)

Checks: HTTP static assets -> WS handshake -> join/welcome -> peer-join broadcast ->
      large frame (8 KB, simulated SDP) relay -> bidirectional signals -> peer-leave broadcast.

Usage:
  python3 scripts/test_signaling.py                             # http://127.0.0.1:8080
  python3 scripts/test_signaling.py --port 8443 --tls           # https/wss
  python3 scripts/test_signaling.py --host 169.254.114.200 --port 8443 --tls
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wsclient import WSClient          # noqa: E402

OK, FAIL = "\033[32m✓\033[0m", "\033[31m✗\033[0m"
results: list[tuple[bool, str]] = []


def check(cond: bool, msg: str) -> bool:
    results.append((bool(cond), msg))
    print(f"  {OK if cond else FAIL} {msg}")
    return bool(cond)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--tls", action="store_true")
    ap.add_argument("--room", default="selftest-signal")
    args = ap.parse_args()

    scheme = "https" if args.tls else "http"
    base = f"{scheme}://{args.host}:{args.port}"

    print(f"\n[1] HTTP static assets {base}/healthz")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        health = json.load(urllib.request.urlopen(f"{base}/healthz", context=ctx, timeout=6))
        check(health.get("ok") is True, f"/healthz returned ok=True, tls={health.get('tls')}")
    except Exception as e:                                            # noqa: BLE001
        check(False, f"/healthz failed: {e}")
        return 1

    print(f"\n[2] WS handshake and room join ({args.tls and 'wss' or 'ws'})")
    a = WSClient(args.host, args.port, "/ws", tls=args.tls).connect()
    a.send({"type": "join", "room": args.room, "name": "test-A"})
    wa = a.recv_json({"welcome"})
    check(wa["type"] == "welcome" and wa["room"] == args.room,
          f"A received welcome id={wa['id']} room={wa['room']} limit={wa.get('limit')}")

    b = WSClient(args.host, args.port, "/ws", tls=args.tls).connect()
    b.send({"type": "join", "room": args.room, "name": "test-B"})
    wb = b.recv_json({"welcome"})
    check(len(wb["peers"]) == 1 and wb["peers"][0]["name"] == "test-A",
          f"B welcome lists existing peers {[p['name'] for p in wb['peers']]}")

    pj = a.recv_json({"peer-join"})
    check(pj["peer"]["name"] == "test-B", f"A received peer-join broadcast: {pj['peer']['name']}")

    print("\n[3] Large frame relay (simulated SDP, 8 KB)")
    fake_sdp = json.dumps({"description": {"type": "offer", "sdp": "v=0\r\n" + "a=x" * 4000}})
    check(len(fake_sdp) > 8000, f"built a {len(fake_sdp)}-byte frame")
    a.send({"type": "signal", "to": wb["id"], "data": {"description": {"type": "offer", "sdp": "x" * 8000}}})
    got = b.recv_json({"signal"})
    check(got.get("from") == wa["id"] and len(got["data"]["description"]["sdp"]) == 8000,
          f"B received {len(got['data']['description']['sdp'])} bytes of SDP from A({got.get('from')})")

    b.send({"type": "signal", "to": wa["id"], "data": {"candidate": {"candidate": "candidate:1 1 udp 2113 1.2.3.4 5000 typ host", "sdpMid": "0"}}})
    back = a.recv_json({"signal"})
    check(back.get("from") == wb["id"] and "candidate" in back["data"], "reverse ICE candidate relay works")

    print("\n[4] State broadcast and leave")
    b.send({"type": "state", "mic": False, "cam": True})
    st = a.recv_json({"peer-state"})
    check(st["mic"] is False and st["cam"] is True, "peer-state (mute / camera off) broadcast works")

    b.close()
    left = a.recv_json({"peer-leave"})
    check(left["id"] == wb["id"], f"A received peer-leave: {left['id']}")
    a.close()

    print("\n[5] Room slot released")
    try:
        h2 = json.load(urllib.request.urlopen(f"{base}/healthz", context=ctx, timeout=6))
        check(args.room not in h2.get("rooms", {}), "room is empty")
    except Exception as e:                                            # noqa: BLE001
        check(False, f"/healthz re-check failed: {e}")

    bad = [m for ok, m in results if not ok]
    print()
    if bad:
        print(f"\033[31mFAILED {len(bad)}/{len(results)}\033[0m")
        return 1
    print(f"\033[32mALL PASSED {len(results)}/{len(results)}\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
