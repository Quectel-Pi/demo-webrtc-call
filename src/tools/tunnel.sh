#!/usr/bin/env bash
# Cloudflare quick tunnel: gives the phone a trusted HTTPS URL.
# Mobile browsers only expose the camera on a trusted HTTPS origin, and the board's self-signed CA cannot be installed on the phone.
# No account needed; the tunnel carries signaling only, audio/video stays peer-to-peer.
#
#   bash src/tools/tunnel.sh            # start and print URL / QR code
#   bash src/tools/tunnel.sh --url      # show the current URL
#   bash src/tools/tunnel.sh --stop     # stop
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/../.." && pwd)"
LOCAL="$APP_DIR/local"
PORT="${PORT:-8080}"
LOG="$LOCAL/cloudflared.log"
URLFILE="$LOCAL/tunnel-url.txt"
QRFILE="$LOCAL/qrcode.png"
mkdir -p "$LOCAL"

find_bin() {
  if [ -n "${CLOUDFLARED:-}" ] && [ -x "${CLOUDFLARED}" ]; then BIN="$CLOUDFLARED"; return 0; fi
  local c
  for c in /usr/local/bin/cloudflared "$HOME/bin/cloudflared"; do
    [ -x "$c" ] && { BIN="$c"; return 0; }
  done
  c="$(command -v cloudflared 2>/dev/null || true)"
  [ -n "$c" ] && [ -x "$c" ] && { BIN="$c"; return 0; }
  return 1
}

stop_tunnel() {
  pkill -f "cloudflared[ ]tunnel" 2>/dev/null || true
  rm -f "$URLFILE"
}

case "${1:-}" in
  --stop) stop_tunnel; echo "Tunnel stopped"; exit 0;;
  --url)  [ -f "$URLFILE" ] && cat "$URLFILE" || echo "(no URL yet, run bash start.sh first)"; exit 0;;
  -h|--help) sed -n '2,15p' "$0"; exit 0;;
esac

find_bin || {
  echo "❌ cloudflared not found. Run ./install.sh first (it downloads and installs it)"
  exit 1
}

# The backend must be up first, otherwise the tunnel only returns 502
if ! curl -sf -o /dev/null "http://127.0.0.1:$PORT/healthz"; then
  echo "❌ Backend http://127.0.0.1:$PORT is not running. Run bash start.sh first"
  exit 1
fi

# A quick tunnel is created on Cloudflare's side, so the board needs internet access
if ! curl -sf -m 8 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace; then
  echo "❌ The board has no internet access; cannot create the Cloudflare tunnel"
  echo "   Check: ping -c2 1.1.1.1 ;  nmcli -t -f NAME,DEVICE,STATE connection show --active"
  echo "   LAN access still works without internet (the phone would have to trust src/certs/ca.pem, which is painful; fixing internet is easier)"
  exit 1
fi

stop_tunnel
: > "$LOG"
echo "==> Creating Cloudflare quick tunnel ..."
setsid nohup "$BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate > "$LOG" 2>&1 < /dev/null &

URL=""
for _ in $(seq 1 40); do
  # Only accept the random three-part hostname; ignore https://api.trycloudflare.com in the log
  URL="$(grep -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' "$LOG" 2>/dev/null \
        | grep -v '^https://api\.' | head -1)"
  [ -n "$URL" ] && break
  grep -q "failed to request quick Tunnel" "$LOG" 2>/dev/null && break
  sleep 1
done

if [ -z "$URL" ]; then
  echo "❌ Could not obtain a tunnel URL. Reason from the log:"
  grep -E "failed|ERR" "$LOG" | tail -5 | sed 's/^/   /'
  echo "   Common causes: no internet / corporate egress filtering / temporary Cloudflare outage (retry in a minute)"
  exit 1
fi

PHONE_URL="$URL/?room=demo"
printf '%s\n' "$URL" > "$URLFILE"

# QR code: printed in the terminal and saved as a PNG for a big screen
QR_OK=0
if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "$QRFILE" -s 8 -m 2 "$PHONE_URL" 2>/dev/null && QR_OK=1
fi

echo
echo "==================== Phone URL ===================="
echo "  $PHONE_URL"
echo "======================================================"
echo "  On the phone: join the same network -> open the URL / scan the code -> "Join room" -> allow camera and microphone"
echo "  The board joins the same room as "Board" automatically (see start.sh output)"
echo "  URL saved to $URLFILE ; QR: ${QRFILE}"
echo
if [ "$QR_OK" = 1 ]; then
  echo "  Scan this code with the phone (or type the URL above):"
  qrencode -t ANSIUTF8 "$PHONE_URL"
else
  echo "  (qrencode not installed, so no QR in the terminal; install it with: sudo apt install -y qrencode)"
fi
