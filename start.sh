#!/usr/bin/env bash
# 一键启动：起服务 → 起隧道并打印手机地址 → 打开板端浏览器。
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
      sed -n '2,8p' "$0"; echo "  参数: --no-browser  --no-tunnel"; exit 0;;
  esac
done
mkdir -p "$LOCAL"
PY="$(command -v python3)"

# local/ 可能是 root 属主（install.sh 建的），先确保可写
ensure_local_writable() {
  [ -w "$LOCAL" ] && return 0
  echo "  local/ 当前不可写，尝试修复属主…"
  sudo chown -R "$(id -un):$(id -gn)" "$LOCAL" 2>/dev/null || true
  [ -w "$LOCAL" ] && return 0
  echo "❌ $LOCAL 不可写，请执行： sudo chown -R \$(id -un) $APP_DIR && bash $APP_DIR/start.sh"
  exit 1
}
ensure_local_writable

echo "=============================================================="
echo " WebRTC A/V Call Demo - start"
echo "=============================================================="

# ---------------------------------------------------------------- 1. 前置检查
echo
echo "[1/4] 前置检查"
[ -x "$PY" ] || { echo "❌ 没找到 python3，请先运行 ./install.sh"; exit 1; }
if [ ! -f "$APP_DIR/src/certs/cert.pem" ]; then
  echo "  证书缺失，正在生成…"
  bash "$APP_DIR/src/tools/make_cert.sh" || echo "  ⚠️ 证书生成失败，https 端口不可用（不影响 localhost 访问）"
fi

CAM_MSG="$(bash "$APP_DIR/src/tools/camera_node.sh" --check || true)"
case "$CAM_MSG" in
  ok:*)        echo "  摄像头：${CAM_MSG#ok: }";;
  need-map:*)
    echo "  摄像头：${CAM_MSG#need-map: }"
    if sudo -n true 2>/dev/null; then
      sudo bash "$APP_DIR/src/tools/camera_node.sh" --target 63
    else
      echo "  ⚠️ 需要 root： sudo bash $APP_DIR/src/tools/camera_node.sh（不修也能跑，会用合成画面）"
    fi;;
  no-camera:*) echo "  摄像头：${CAM_MSG#no-camera: }";;
  *)           echo "  摄像头：$CAM_MSG";;
esac

# ------------------------------------------------------------- 2. 启动服务
echo
echo "[2/4] 启动信令 + 静态服务（:$HTTP_PORT 明文 / :$PORT https）"
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
  echo "❌ 服务启动失败，日志："; tail -20 "$SERVER_LOG"; exit 1
fi
if curl -sf -o /dev/null "http://127.0.0.1:$HTTP_PORT/healthz"; then
  echo "  ✅ 服务已就绪   http://localhost:$HTTP_PORT"
else
  echo "❌ /healthz 不通，日志："; tail -20 "$SERVER_LOG"; exit 1
fi

# ------------------------------------------------------------- 3. 隧道 + 地址
echo
echo "[3/4] 生成手机访问地址"
LAN_IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^$|:' | grep -v '^169\.254\.' | head -3 | tr '\n' ' ')"
PHONE_URL=""
# 清掉上一轮的地址，避免隧道失败时仍然打印过期/错误的链接
rm -f "$LOCAL/tunnel-url.txt" "$LOCAL/qrcode.png"
if [ "$USE_TUNNEL" = 1 ]; then
  bash "$APP_DIR/src/tools/tunnel.sh" || true
  if [ -f "$LOCAL/tunnel-url.txt" ]; then
    BASE="$(head -1 "$LOCAL/tunnel-url.txt" 2>/dev/null)"
    case "$BASE" in
      https://*-*-*.trycloudflare.com) PHONE_URL="$BASE/?room=$ROOM";;
      *) echo "  ⚠️ 隧道地址异常（$BASE），已忽略";;
    esac
  fi
fi
if [ -z "$PHONE_URL" ]; then
  echo
  echo "  ⚠️ 隧道未建立，暂无手机地址。局域网可用（手机会先弹证书警告）："
  for ip in $LAN_IPS; do echo "     https://$ip:$PORT/?room=$ROOM"; done
  echo "     让板子连上能出网的 WiFi 后重跑 bash start.sh"
fi

# ------------------------------------------------------------- 4. 板端浏览器
echo
echo "[4/4] 板端浏览器"
if [ "$OPEN_BROWSER" = 1 ]; then
  bash "$APP_DIR/src/tools/open_browser.sh" \
    "http://localhost:$HTTP_PORT/?room=$ROOM&name=$NAME&autostart=1" window || true
else
  echo "  跳过（--no-browser）"
fi

# ------------------------------------------------------------------ 总结
echo
echo "=============================================================="
echo " 就绪"
echo "--------------------------------------------------------------"
echo " 板端（本机）: http://localhost:$HTTP_PORT/?room=$ROOM&name=$NAME"
[ -n "$PHONE_URL" ] && echo " 手机访问:    $PHONE_URL"
[ -n "$PHONE_URL" ] && echo " 二维码图片:  $LOCAL/qrcode.png"
echo
echo " 手机：打开上面的地址（或扫码）→ 点「加入房间」→ 允许摄像头和麦克风"
echo "--------------------------------------------------------------"
echo " 日志: tail -f $SERVER_LOG      停止: bash $APP_DIR/stop.sh"
echo "=============================================================="
