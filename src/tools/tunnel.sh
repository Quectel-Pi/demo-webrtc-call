#!/usr/bin/env bash
# Cloudflare 快速隧道：给手机一个受信任的 HTTPS 地址。
# 手机浏览器只在受信任的 HTTPS 下才给摄像头，板子的自签证书装不进手机。
# 不需要注册账号；隧道只承担信令，音视频仍是 P2P 直连。
#
#   bash src/tools/tunnel.sh            # 启动并打印地址/二维码
#   bash src/tools/tunnel.sh --url      # 查看当前地址
#   bash src/tools/tunnel.sh --stop     # 停止
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
  --stop) stop_tunnel; echo "隧道已停止"; exit 0;;
  --url)  [ -f "$URLFILE" ] && cat "$URLFILE" || echo "(还没有地址，先运行 bash start.sh)"; exit 0;;
  -h|--help) sed -n '2,15p' "$0"; exit 0;;
esac

find_bin || {
  echo "❌ 找不到 cloudflared，请先运行 ./install.sh（会下载并安装它）"
  exit 1
}

# 后端必须先活着，否则隧道起来也是 502
if ! curl -sf -o /dev/null "http://127.0.0.1:$PORT/healthz"; then
  echo "❌ 后端 http://127.0.0.1:$PORT 未运行，请先运行 bash start.sh"
  exit 1
fi

# 快速隧道需要在 Cloudflare 那边建隧道，板子必须能上外网
if ! curl -sf -m 8 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace; then
  echo "❌ 板子当前没有外网，无法建立 Cloudflare 隧道"
  echo "   检查： ping -c2 223.5.5.5 ；  nmcli -t -f NAME,DEVICE,STATE connection show --active"
  echo "   没有外网时仍可局域网内使用（手机需要信任 src/certs/ca.pem，不好操作，建议先修好外网）"
  exit 1
fi

stop_tunnel
: > "$LOG"
echo "==> 正在建立 Cloudflare 快速隧道 ..."
setsid nohup "$BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate > "$LOG" 2>&1 < /dev/null &

URL=""
for _ in $(seq 1 40); do
  # 只认随机三段式域名，排除日志里出现的 https://api.trycloudflare.com
  URL="$(grep -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' "$LOG" 2>/dev/null \
        | grep -v '^https://api\.' | head -1)"
  [ -n "$URL" ] && break
  grep -q "failed to request quick Tunnel" "$LOG" 2>/dev/null && break
  sleep 1
done

if [ -z "$URL" ]; then
  echo "❌ 没能拿到隧道地址，日志里的原因："
  grep -E "failed|ERR" "$LOG" | tail -5 | sed 's/^/   /'
  echo "   常见原因：板子没有外网 / 公司网络限制出站 / Cloudflare 临时故障（等一会重试）"
  exit 1
fi

PHONE_URL="$URL/?room=demo"
printf '%s\n' "$URL" > "$URLFILE"

# 二维码：终端里直接显示 + 存一张 PNG 方便投到大屏
QR_OK=0
if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "$QRFILE" -s 8 -m 2 "$PHONE_URL" 2>/dev/null && QR_OK=1
fi

echo
echo "==================== 手机访问地址 ===================="
echo "  $PHONE_URL"
echo "======================================================"
echo "  手机操作：连上跟板子相同的网络 → 打开上面的地址/扫码 → 点「加入房间」→ 允许摄像头和麦克风"
echo "  板端会自动以 Board 身份加入同一房间（见 start.sh 输出）"
echo "  地址已写入 $URLFILE ；二维码：${QRFILE}"
echo
if [ "$QR_OK" = 1 ]; then
  echo "  手机扫这个码（或直接输入上面的网址）："
  qrencode -t ANSIUTF8 "$PHONE_URL"
else
  echo "  （没装 qrencode，终端不显示二维码；sudo apt install -y qrencode 后可显示）"
fi
