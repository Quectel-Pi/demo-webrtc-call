#!/usr/bin/env bash
# Open the demo page with a dedicated Firefox profile (the user's own browser settings stay untouched).
#
#   bash src/tools/open_browser.sh                # room=demo, name Board
#   bash src/tools/open_browser.sh "<url>" kiosk  # full screen
#   NO_BROWSER=1 bash ...                         # print only, do not open
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/../.." && pwd)"
URL="${1:-http://localhost:8080/?room=demo&name=Board&autostart=1}"
MODE="${2:-window}"
PROFILE="${FIREFOX_PROFILE:-$APP_DIR/local/firefox-profile}"

if ! command -v firefox >/dev/null 2>&1 && ! command -v firefox-esr >/dev/null 2>&1; then
  echo "  ⚠️ firefox not found, skipping the board browser (the phone can still open the URL directly)"
  exit 0
fi

mkdir -p "$PROFILE"
cat > "$PROFILE/user.js" <<'EOF'
// Disable mDNS obfuscation of host candidates: on LAN/hotspot links there is no mDNS service,
// so obfuscated xxx.local candidates never resolve ("connected" but no media flows).
user_pref("media.peerconnection.ice.obfuscate_host_addresses", false);
// Autoplay (the demo needs remote audio immediately; if iOS blocks it the page shows an "Enable sound" button)
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.block-webaudio", false);
// Demo machine: skip camera/microphone permission prompts
user_pref("media.navigator.permission.disabled", true);
user_pref("media.navigator.streams.fake", false);
// Allow ICE candidates on private/link-local addresses (needed for hotspot and USB-direct links)
user_pref("media.peerconnection.ice.link_local", true);
user_pref("media.peerconnection.ice.default_address_only", false);
user_pref("media.peerconnection.ice.no_host", false);
// First-run noise
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("dom.security.https_first", false);
EOF

# Launching a GUI app over SSH needs these environment variables (absent in systemd system services, present in the desktop session)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"
export MOZ_ENABLE_WAYLAND=1
export MOZ_NO_REMOTE=1

KIOSK=""
[ "$MODE" = "kiosk" ] && KIOSK="--kiosk"

if [ "${NO_BROWSER:-0}" = "1" ]; then
  echo "  Board browser (not launched, NO_BROWSER=1): $URL"
  exit 0
fi

FF="$(command -v firefox || command -v firefox-esr)"
echo "==> Launching board browser (profile=$PROFILE)"
nohup "$FF" --new-instance -profile "$PROFILE" $KIOSK "$URL" > "$APP_DIR/local/firefox.log" 2>&1 &
echo "    PID=$!  URL=$URL"
