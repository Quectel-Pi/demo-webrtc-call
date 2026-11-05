#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""信令服务器自检（不需要浏览器）

验证：HTTP 静态资源 → WS 握手 → join/welcome → 房间广播 peer-join →
      大报文（8 KB，模拟 SDP）转发 → 双向信号 → 断开广播 peer-leave。

用法：
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

    print(f"\n[1] HTTP 静态资源 {base}/healthz")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        health = json.load(urllib.request.urlopen(f"{base}/healthz", context=ctx, timeout=6))
        check(health.get("ok") is True, f"/healthz 返回 ok=True，tls={health.get('tls')}")
    except Exception as e:                                            # noqa: BLE001
        check(False, f"/healthz 失败：{e}")
        return 1

    print(f"\n[2] WS 握手与加入房间（{args.tls and 'wss' or 'ws'}）")
    a = WSClient(args.host, args.port, "/ws", tls=args.tls).connect()
    a.send({"type": "join", "room": args.room, "name": "test-A"})
    wa = a.recv_json({"welcome"})
    check(wa["type"] == "welcome" and wa["room"] == args.room,
          f"A 收到 welcome id={wa['id']} 房间={wa['room']} 上限={wa.get('limit')}")

    b = WSClient(args.host, args.port, "/ws", tls=args.tls).connect()
    b.send({"type": "join", "room": args.room, "name": "test-B"})
    wb = b.recv_json({"welcome"})
    check(len(wb["peers"]) == 1 and wb["peers"][0]["name"] == "test-A",
          f"B 的 welcome 里看到已有对端 {[p['name'] for p in wb['peers']]}")

    pj = a.recv_json({"peer-join"})
    check(pj["peer"]["name"] == "test-B", f"A 收到 peer-join 广播：{pj['peer']['name']}")

    print("\n[3] 大报文转发（模拟 SDP 8 KB）")
    fake_sdp = json.dumps({"description": {"type": "offer", "sdp": "v=0\r\n" + "a=x" * 4000}})
    check(len(fake_sdp) > 8000, f"构造报文 {len(fake_sdp)} 字节")
    a.send({"type": "signal", "to": wb["id"], "data": {"description": {"type": "offer", "sdp": "x" * 8000}}})
    got = b.recv_json({"signal"})
    check(got.get("from") == wa["id"] and len(got["data"]["description"]["sdp"]) == 8000,
          f"B 收到 A({got.get('from')}) 的 {len(got['data']['description']['sdp'])} 字节 SDP")

    b.send({"type": "signal", "to": wa["id"], "data": {"candidate": {"candidate": "candidate:1 1 udp 2113 1.2.3.4 5000 typ host", "sdpMid": "0"}}})
    back = a.recv_json({"signal"})
    check(back.get("from") == wb["id"] and "candidate" in back["data"], "反向 ICE candidate 转发正常")

    print("\n[4] 状态广播与离开")
    b.send({"type": "state", "mic": False, "cam": True})
    st = a.recv_json({"peer-state"})
    check(st["mic"] is False and st["cam"] is True, "peer-state（静音/关摄像头）广播正常")

    b.close()
    left = a.recv_json({"peer-leave"})
    check(left["id"] == wb["id"], f"A 收到 peer-leave：{left['id']}")
    a.close()

    print("\n[5] 房间占用已释放")
    try:
        h2 = json.load(urllib.request.urlopen(f"{base}/healthz", context=ctx, timeout=6))
        check(args.room not in h2.get("rooms", {}), "房间已清空")
    except Exception as e:                                            # noqa: BLE001
        check(False, f"/healthz 复查失败：{e}")

    bad = [m for ok, m in results if not ok]
    print()
    if bad:
        print(f"\033[31m失败 {len(bad)}/{len(results)}\033[0m")
        return 1
    print(f"\033[32m全部通过 {len(results)}/{len(results)}\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
