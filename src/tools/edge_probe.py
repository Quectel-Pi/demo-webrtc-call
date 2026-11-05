#!/usr/bin/env python3
"""本机 CDP 探针：连上 Edge/Chrome 的 remote-debugging 端口，在页面里执行 JS 并打印结果。

用途：PC 端浏览器要访问 http://169.254.x.x（板子 USB 直连）时，用它在页面里读状态/断言。
用法：
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
    ap.add_argument("--match", default=None, help="只对 URL 含该子串的页面执行")
    ap.add_argument("--out", default=None, help="把返回的字符串写到文件（用于 dataURL 抓帧）")
    ap.add_argument("--shot", default=None, help="按手机视口截图到该文件（验证移动端布局）")
    ap.add_argument("--width", type=int, default=390, help="--shot 的视口宽（默认 iPhone 逻辑宽）")
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
        print("没有匹配的页面 target")
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

    # --- 手机视口截图：验证移动端布局 ---
    if args.shot:
        import base64, time
        rpc(1, "Emulation.setDeviceMetricsOverride",
            {"width": args.width, "height": args.height, "deviceScaleFactor": 2, "mobile": True})
        rpc(2, "Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5})
        time.sleep(1.5)
        res = rpc(3, "Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
        with open(args.shot, "wb") as f:
            f.write(base64.b64decode(res["data"]))
        print(f"已截图 {args.shot}（{args.width}x{args.height} @2x）")
        return 0

    res = rpc(1, "Runtime.evaluate",
              {"expression": args.eval, "awaitPromise": True, "returnByValue": True})
    if "exceptionDetails" in res:
        print("JS 异常:", json.dumps(res["exceptionDetails"], ensure_ascii=False)[:800])
        return 1
    v = res.get("result", {}).get("value")
    if args.out and isinstance(v, str):
        with open(args.out, "wb") as f:
            if v.startswith("data:"):
                import base64
                f.write(base64.b64decode(v.split(",", 1)[1]))
            else:
                f.write(v.encode())
        print(f"已写入 {args.out} ({len(v)} chars)")
    else:
        print(json.dumps(v, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
