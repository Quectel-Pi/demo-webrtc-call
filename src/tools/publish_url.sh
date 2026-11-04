#!/usr/bin/env bash
# 从 cloudflared 日志取出隧道地址，写入 local/tunnel-url.txt 并生成二维码。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/../.." && pwd)"
LOCAL="$APP_DIR/local"
LOG="$LOCAL/cloudflared.log"
ROOM="${ROOM:-demo}"
mkdir -p "$LOCAL"

URL="$(grep -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' "$LOG" 2>/dev/null \
      | grep -v '^https://api\.' | head -1)"
[ -n "$URL" ] || exit 1

PHONE_URL="$URL/?room=$ROOM"
printf '%s\n' "$URL" > "$LOCAL/tunnel-url.txt"

if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "$LOCAL/qrcode.png" -s 8 -m 2 "$PHONE_URL" 2>/dev/null || true
fi

echo "$PHONE_URL"
