#!/usr/bin/env bash
# Stop the signaling server and the tunnel (close the board browser window manually)
set -uo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL="$APP_DIR/local"
SERVER_PID="$LOCAL/server.pid"

echo "==> Stopping tunnel"
pkill -f "cloudflared[ ]tunnel" 2>/dev/null && echo "  cloudflared stopped" || echo "  (tunnel not running)"
rm -f "$LOCAL/tunnel-url.txt"

echo "==> Stopping signaling server"
if [ -f "$SERVER_PID" ] && kill -0 "$(cat "$SERVER_PID")" 2>/dev/null; then
  kill "$(cat "$SERVER_PID")" 2>/dev/null
  echo "  server stopped (pid $(cat "$SERVER_PID"))"
fi
pkill -f "src/server[.]py" 2>/dev/null || true
rm -f "$SERVER_PID"

echo "==> Done"
