#!/usr/bin/env bash
# Environment setup: install dependencies, download cloudflared, generate certificates, fix the camera node.
# Usage: sudo bash install.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$APP_DIR/local"
mkdir -p "$LOG_DIR"

# This script is written for Debian/Ubuntu systems using apt.
if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script requires apt (Debian/Ubuntu). Aborting."
  exit 1
fi

# Heartbeat for long tasks: print a line every 15 s so the user knows it is not stuck
heartbeat() {
  local label="$1"; shift
  local start rc
  echo "==> $label"
  "$@" &
  local pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    if kill -0 "$pid" 2>/dev/null && [ $(((SECONDS - start) % 15)) -eq 0 ]; then
      echo "  [$(date +%H:%M:%S)] still running... $((SECONDS - start)) s elapsed"
    fi
  done
  wait "$pid"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "  done in $((SECONDS - start)) s"
  else echo "  FAILED with exit code $rc after $((SECONDS - start)) s"; fi
  return "$rc"
}

if [ "$(id -u)" != "0" ]; then
  echo "Run as root: sudo bash install.sh"
  exit 1
fi

ARCH="$(uname -m)"
echo "=============================================================="
echo " WebRTC A/V Call Demo - install"
echo " Board: $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo unknown)  ARCH=$ARCH"
echo " Path: $APP_DIR"
echo "=============================================================="

# ---------------------------------------------------------------- [1/6] Environment check
echo
echo "[1/6] Environment check"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "❌ python3 not found"; exit 1; }
PYV="$($PY -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
echo "  python3 $PYV ($PY)"
$PY - <<'PYEOF'
import sys
if sys.version_info < (3, 8):
    sys.exit("Python >= 3.8 is required")
PYEOF
echo "  OK: Debian/Ubuntu + python3 $PYV"

# ------------------------------------------------------------ [2/6] apt dependencies
echo
echo "[2/6] Installing system dependencies (apt)"
need=()
for c in curl openssl v4l2-ctl lsof qrencode; do
  command -v "$c" >/dev/null 2>&1 || need+=("$c")
done
command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1 || need+=(firefox-esr)
if [ ${#need[@]} -eq 0 ]; then
  echo "  All dependencies present, skipping"
else
  echo "  Missing: ${need[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt_ok=1
  heartbeat "apt-get update" apt-get update -qq || apt_ok=0
  # Package name matters: on Debian/Ubuntu the package providing v4l2-ctl is v4l-utils (not v4l2-utils)
  pkgs=(curl ca-certificates openssl v4l-utils lsof qrencode)
  command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1 || pkgs+=(firefox-esr)
  if [ "$apt_ok" = 1 ]; then
    heartbeat "apt-get install ${pkgs[*]}" apt-get install -y -qq --no-install-recommends "${pkgs[@]}" \
      || echo "  ⚠️ Some packages failed to install; retry later with: apt-get install -y ${pkgs[*]}"
  else
    echo "  ⚠️ apt sources unavailable (hotspot or gateway blocking plain http, proxy required). Missing packages do not break the call; install them later when online:"
    echo "     sudo apt-get update && sudo apt-get install -y ${pkgs[*]}"
  fi
fi

# --------------------------------------------------------- [3/6] cloudflared
echo
echo "[3/6] Checking cloudflared (Cloudflare quick tunnel, gives the phone a trusted HTTPS URL)"
if command -v cloudflared >/dev/null 2>&1; then
  echo "  Installed: $(cloudflared --version 2>&1 | head -1)"
else
  case "$ARCH" in
    aarch64|arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64";;
    x86_64|amd64)  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64";;
    armv7l|armv6l) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm";;
    *) echo "  ❌ Unsupported architecture $ARCH, please install cloudflared manually"; CF_URL="";;
  esac
  if [ -n "$CF_URL" ]; then
    echo "  Downloading: $CF_URL"
    tmp="$(mktemp)"
    if heartbeat "Downloading cloudflared (~35 MB)" curl -fL --retry 2 -o "$tmp" "$CF_URL"; then
      install -m 0755 "$tmp" /usr/local/bin/cloudflared
      rm -f "$tmp"
      echo "  Installed to /usr/local/bin/cloudflared"
    else
      rm -f "$tmp"
      echo "  ⚠️ Download failed. Fetch it on a networked PC and copy it to the board:"
      echo "     $CF_URL"
      echo "     scp cloudflared-linux-arm64 <user>@<board-ip>:/tmp/cloudflared && sudo install -m755 /tmp/cloudflared /usr/local/bin/cloudflared"
      echo "     The demo still runs without cloudflared (direct LAN access); the phone just loses the trusted certificate."
    fi
  fi
fi

# ------------------------------------------------------------ [4/6] Certificates
echo
echo "[4/6] Generating local CA + server certificate (for the HTTPS port 8443)"
FORCE="${FORCE:-0}" bash "$APP_DIR/src/tools/make_cert.sh" || echo "  ⚠️ Certificate generation failed (the board page on http://localhost:8080 is unaffected)"

# ------------------------------------------------------ [5/6] Camera node fix
echo
echo "[5/6] Camera node (libwebrtc only enumerates /dev/video0..63)"
bash "$APP_DIR/src/tools/camera_node.sh" --check && CAM_OK=0 || CAM_OK=1
if [ "$CAM_OK" = 0 ]; then
  echo "  No fix needed"
else
  bash "$APP_DIR/src/tools/camera_node.sh" --target 63 || true
  # Install as a boot service so the mapping survives reboots
  cat > /etc/systemd/system/webrtc-camlink.service <<EOF
[Unit]
Description=Map USB camera to /dev/video63 for WebRTC capture
DefaultDependencies=no
After=systemd-udev-settle.service local-fs.target
Wants=systemd-udev-settle.service
Before=graphical.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $APP_DIR/src/tools/camera_node.sh --target 63

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable webrtc-camlink.service >/dev/null 2>&1 || true
  systemctl restart webrtc-camlink.service || true
  echo "  Boot service installed: webrtc-camlink.service"
fi

# ------------------------------------------------------------- [6/6] Self-check
echo
echo "[6/6] Self-check"
$PY -m py_compile "$APP_DIR/src/server.py" && echo "  OK: src/server.py syntax check passed"
for f in wsclient.py test_signaling.py edge_probe.py; do
  $PY -m py_compile "$APP_DIR/src/tools/$f" && echo "  OK: src/tools/$f"
done
chmod +x "$APP_DIR"/*.sh "$APP_DIR"/src/tools/*.sh 2>/dev/null || true

# Hand root-created directories back to the invoking user, otherwise start.sh (run as user) cannot write logs
if [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" \
    "$APP_DIR/local" "$APP_DIR/src/certs" 2>/dev/null || true
  echo "  OK: ownership of local/ and src/certs/ changed to $SUDO_USER"
fi

if bash "$APP_DIR/src/tools/camera_node.sh" --check | grep -q '^ok'; then
  echo "  OK: camera is enumerable by the browser"
else
  echo "  ⚠️ Camera not enumerable by the browser — the page falls back to a synthetic test pattern. Plug in the USB camera and re-run this script."
fi

echo
echo "=============================================================="
echo " Deployment complete"
echo "=============================================================="
echo " Next:  bash $APP_DIR/start.sh"
echo " Stop:  bash $APP_DIR/stop.sh"
echo "=============================================================="
