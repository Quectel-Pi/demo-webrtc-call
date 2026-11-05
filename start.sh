#!/usr/bin/env bash
# One-shot start: run the server -> start the tunnel and print the phone URL -> open the board browser.
#   bash start.sh [--no-browser] [--no-tunnel]
set -uo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL="$APP_DIR/local"
PORT="${PORT:-8443}"
HTTP_PORT="${HTTP_PORT:-8080}"
ROOM="${ROOM:-demo}"
NAME="${NAME:-Board}"
SERVER_LOG="$LOCAL/server.log"
SERVER_PID="$LOCAL/server.pid"
OPEN_BROWSER=1
USE_TUNNEL=1

for a in "$@"; do
  case "$a" in
    --no-browser) OPEN_BROWSER=0;;
    --no-tunnel) USE_TUNNEL=0;;
    -h|--help)
      sed -n '2,8p' "$0"; echo "  Options: --no-browser  --no-tunnel"; exit 0;;
  esac
done
mkdir -p "$LOCAL"
PY="$(command -v python3)"

# local/ may be owned by root (created by install.sh); make sure it is writable
ensure_local_writable() {
  [ -w "$LOCAL" ] && return 0
  echo "  local/ is not writable, trying to fix ownership..."
  sudo chown -R "$(id -un):$(id -gn)" "$LOCAL" 2>/dev/null || true
  [ -w "$LOCAL" ] && return 0
  echo "❌ $LOCAL is not writable. Run: sudo chown -R \$(id -un) $APP_DIR && bash $APP_DIR/start.sh"
  exit 1
}
ensure_local_writable

echo "=============================================================="
echo " WebRTC Video Call Demo - start"
echo "=============================================================="

# ---------------------------------------------------------------- 1. Pre-flight checks
echo
echo "[1/4] Pre-flight checks"
[ -x "$PY" ] || { echo "❌ python3 not found. Run ./install.sh first"; exit 1; }
if [ ! -f "$APP_DIR/src/certs/cert.pem" ]; then
  echo "  Certificate missing, generating..."
  bash "$APP_DIR/src/tools/make_cert.sh" || echo "  ⚠️ Certificate generation failed; the HTTPS port is unavailable (localhost access unaffected)"
fi

CAM_MSG="$(bash "$APP_DIR/src/tools/camera_node.sh" --check || true)"
case "$CAM_MSG" in
  ok:*)        echo "  Camera: ${CAM_MSG#ok: }";;
  need-map:*)
    echo "  Camera: ${CAM_MSG#need-map: }"
    if sudo -n true 2>/dev/null; then
      sudo bash "$APP_DIR/src/tools/camera_node.sh" --target 63
    else
      echo "  ⚠️ root required: sudo bash $APP_DIR/src/tools/camera_node.sh (runs without it, using a synthetic pattern)"
    fi;;
  no-camera:*) echo "  Camera: ${CAM_MSG#no-camera: }";;
  *)           echo "  Camera: $CAM_MSG";;
esac

# ------------------------------------------------------------- 2. Start the server
echo
echo "[2/4] Starting signaling + static server (: $HTTP_PORT plain / :$PORT https)"
if [ -f "$SERVER_PID" ] && kill -0 "$(cat "$SERVER_PID")" 2>/dev/null; then
  kill "$(cat "$SERVER_PID")" 2>/dev/null; sleep 0.6
fi
pkill -f "src/server[.]py" 2>/dev/null || true
: > "$SERVER_LOG"
nohup "$PY" "$APP_DIR/src/server.py" --tls --port "$PORT" --http-port "$HTTP_PORT" --verbose \
  > "$SERVER_LOG" 2>&1 &
echo $! > "$SERVER_PID"
sleep 1.2
if ! kill -0 "$(cat "$SERVER_PID")" 2>/dev/null; then
  echo "❌ Server failed to start. Log:"; tail -20 "$SERVER_LOG"; exit 1
fi
if curl -sf -o /dev/null "http://127.0.0.1:$HTTP_PORT/healthz"; then
  echo "  ✅ Server ready   http://localhost:$HTTP_PORT"
else
  echo "❌ /healthz not responding. Log:"; tail -20 "$SERVER_LOG"; exit 1
fi

# ------------------------------------------------------------- 3. Tunnel + URL
echo
echo "[3/4] Generating the phone URL"
LAN_IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^$|:' | grep -v '^169\.254\.' | head -3 | tr '\n' ' ')"
PHONE_URL=""
# Drop the previous URL so a failed tunnel does not print a stale link
rm -f "$LOCAL/tunnel-url.txt" "$LOCAL/qrcode.png"
if [ "$USE_TUNNEL" = 1 ]; then
  bash "$APP_DIR/src/tools/tunnel.sh" || true
  if [ -f "$LOCAL/tunnel-url.txt" ]; then
    BASE="$(head -1 "$LOCAL/tunnel-url.txt" 2>/dev/null)"
    case "$BASE" in
      https://*-*-*.trycloudflare.com) PHONE_URL="$BASE/?room=$ROOM";;
      *) echo "  ⚠️ Unexpected tunnel URL ($BASE), ignored";;
    esac
  fi
fi
if [ -z "$PHONE_URL" ]; then
  echo
  echo "  ⚠️ Tunnel not established, no phone URL yet. LAN access still works (the phone shows a certificate warning first):"
  for ip in $LAN_IPS; do echo "     https://$ip:$PORT/?room=$ROOM"; done
  echo "     Connect the board to a Wi-Fi network with internet, then re-run bash start.sh"
fi

# ------------------------------------------------------------- 4. Board browser
echo
echo "[4/4] Board browser"
if [ "$OPEN_BROWSER" = 1 ]; then
  bash "$APP_DIR/src/tools/open_browser.sh" \
    "http://localhost:$HTTP_PORT/?room=$ROOM&name=$NAME&autostart=1" window || true
else
  echo "  Skipped (--no-browser)"
fi

# ------------------------------------------------------------------ Summary
echo
echo "=============================================================="
echo " Ready"
echo "--------------------------------------------------------------"
echo " Board (local): http://localhost:$HTTP_PORT/?room=$ROOM&name=$NAME"
[ -n "$PHONE_URL" ] && echo " Phone:        $PHONE_URL"
[ -n "$PHONE_URL" ] && echo " QR image:     $LOCAL/qrcode.png"
echo
echo " Phone: open the URL above (or scan the code) -> "Join room" -> allow camera and microphone"
echo "--------------------------------------------------------------"
echo " Log: tail -f $SERVER_LOG      Stop: bash $APP_DIR/stop.sh"
echo "=============================================================="
