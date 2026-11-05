#!/usr/bin/env bash
# 用独立的 Firefox profile 打开演示页（不改动用户自己的浏览器配置）。
#
#   bash src/tools/open_browser.sh                # room=demo，名字 Board
#   bash src/tools/open_browser.sh "<url>" kiosk  # 全屏
#   NO_BROWSER=1 bash ...                         # 只打印不打开
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/../.." && pwd)"
URL="${1:-http://localhost:8080/?room=demo&name=Board&autostart=1}"
MODE="${2:-window}"
PROFILE="${FIREFOX_PROFILE:-$APP_DIR/local/firefox-profile}"

if ! command -v firefox >/dev/null 2>&1 && ! command -v firefox-esr >/dev/null 2>&1; then
  echo "  ⚠️ 没有找到 firefox，跳过板端浏览器（仍可用手机直接访问地址）"
  exit 0
fi

mkdir -p "$PROFILE"
cat > "$PROFILE/user.js" <<'EOF'
// 关掉 host candidate 的 mDNS 混淆：局域网/热点直连时没有 mDNS 服务，
// 混淆后的 xxx.local 候选解析不出来，会出现“connected 但拿不到媒体”
user_pref("media.peerconnection.ice.obfuscate_host_addresses", false);
// 自动播放（演示场景需要远端声音直接出声；被 iOS 拦时页面会显示「开启声音」按钮）
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.block-webaudio", false);
// 演示机：免摄像头/麦克风授权弹窗
user_pref("media.navigator.permission.disabled", true);
user_pref("media.navigator.streams.fake", false);
// 允许私有/链路本地地址的 ICE 候选（热点、USB 直连都用得到）
user_pref("media.peerconnection.ice.link_local", true);
user_pref("media.peerconnection.ice.default_address_only", false);
user_pref("media.peerconnection.ice.no_host", false);
// 首次启动的一堆干扰
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("dom.security.https_first", false);
EOF

# 从 SSH 启动 GUI 程序需要这些环境变量（systemd 系统服务里没有，桌面会话里有）
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"
export MOZ_ENABLE_WAYLAND=1
export MOZ_NO_REMOTE=1

KIOSK=""
[ "$MODE" = "kiosk" ] && KIOSK="--kiosk"

if [ "${NO_BROWSER:-0}" = "1" ]; then
  echo "  板端浏览器（未启动，NO_BROWSER=1）：$URL"
  exit 0
fi

FF="$(command -v firefox || command -v firefox-esr)"
echo "==> 打开板端浏览器（profile=$PROFILE）"
nohup "$FF" --new-instance -profile "$PROFILE" $KIOSK "$URL" > "$APP_DIR/local/firefox.log" 2>&1 &
echo "    PID=$!  URL=$URL"
