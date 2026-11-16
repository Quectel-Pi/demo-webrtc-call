#!/usr/bin/env python3
"""Local CDP probe: attach to the Edge/Chrome remote-debugging port, evaluate JS in the page and print the result.

Use case: when the PC browser must open http://169.254.x.x (board over USB), read state / assert from inside the page.
Usage:
  python edge_probe.py --list
  python edge_probe.py --eval "JSON.stringify(window.__selftest)"
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wsclient import WSClient  # noqa: E402


def targets(port: int):
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9222)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--eval", default=None)
    ap.add_argument("--match", default=None, help="only run on pages whose URL contains this substring")
    ap.add_argument("--out", default=None, help="write the returned string to a file (used for dataURL frame grabs)")
    ap.add_argument("--shot", default=None, help="screenshot at phone viewport size into this file (checks mobile layout)")
    ap.add_argument("--width", type=int, default=390, help="viewport width for --shot (iPhone logical width by default)")
    ap.add_argument("--height", type=int, default=844)
    args = ap.parse_args()

    ts = [t for t in targets(args.port) if t.get("type") == "page"]
    if args.list:
        for t in ts:
            print(f"{t['id'][:8]}  {t.get('url')}  |  {t.get('title')}")
        return 0
    if args.match:
        ts = [t for t in ts if args.match in (t.get("url") or "")]
    if not ts:
        print("no matching page target")
        return 2

    t = ts[-1]
    ws = WSClient("127.0.0.1", args.port, t["webSocketDebuggerUrl"].split(str(args.port), 1)[1], tls=False).connect()

    def rpc(mid: int, method: str, params: dict | None = None) -> dict:
        ws.send({"id": mid, "method": method, "params": params or {}})
        while True:
            op, data = ws.recv()
            if op not in (0x1, 0x2):
                continue
            msg = json.loads(data)
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})

    # --- phone viewport screenshot: verifies the mobile layout ---
    if args.shot:
        import base64, time
        rpc(1, "Emulation.setDeviceMetricsOverride",
            {"width": args.width, "height": args.height, "deviceScaleFactor": 2, "mobile": True})
        rpc(2, "Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5})
        time.sleep(1.5)
        res = rpc(3, "Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
        with open(args.shot, "wb") as f:
            f.write(base64.b64decode(res["data"]))
        print(f"Saved screenshot {args.shot} ({args.width}x{args.height} @2x)")
        return 0

    res = rpc(1, "Runtime.evaluate",
              {"expression": args.eval, "awaitPromise": True, "returnByValue": True})
    if "exceptionDetails" in res:
        print("JS exception:", json.dumps(res["exceptionDetails"], ensure_ascii=False)[:800])
        return 1
    v = res.get("result", {}).get("value")
    if args.out and isinstance(v, str):
        with open(args.out, "wb") as f:
            if v.startswith("data:"):
                import base64
                f.write(base64.b64decode(v.split(",", 1)[1]))
            else:
                f.write(v.encode())
        print(f"Wrote {args.out} ({len(v)} chars)")
    else:
        print(json.dumps(v, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
