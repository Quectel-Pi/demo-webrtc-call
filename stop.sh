#!/usr/bin/env bash
# 停止信令服务和隧道（板端浏览器窗口手动关闭）
set -uo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL="$APP_DIR/local"
SERVER_PID="$LOCAL/server.pid"

echo "==> 停止隧道"
pkill -f "cloudflared[ ]tunnel" 2>/dev/null && echo "  已停止 cloudflared" || echo "  （隧道未在运行）"
rm -f "$LOCAL/tunnel-url.txt"

echo "==> 停止信令服务"
if [ -f "$SERVER_PID" ] && kill -0 "$(cat "$SERVER_PID")" 2>/dev/null; then
  kill "$(cat "$SERVER_PID")" 2>/dev/null
  echo "  已停止 server (pid $(cat "$SERVER_PID"))"
fi
pkill -f "src/server[.]py" 2>/dev/null || true
rm -f "$SERVER_PID"

echo "==> 完成"
