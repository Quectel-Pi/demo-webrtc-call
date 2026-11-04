#!/usr/bin/env bash
# 环境部署：装依赖、下载 cloudflared、生成证书、修复摄像头节点。
# 用法： sudo bash install.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$APP_DIR/local"
mkdir -p "$LOG_DIR"

# This script is written for Debian/Ubuntu systems using apt.
if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script requires apt (Debian/Ubuntu). Aborting."
  exit 1
fi

# 长任务心跳：每 15 秒打一行，避免用户以为卡死
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
  echo "请用 root 运行： sudo bash install.sh"
  exit 1
fi

ARCH="$(uname -m)"
echo "=============================================================="
echo " WebRTC A/V Call Demo - install"
echo " 板子: $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo unknown)  ARCH=$ARCH"
echo " 路径: $APP_DIR"
echo "=============================================================="

# ---------------------------------------------------------------- [1/6] 检查
echo
echo "[1/6] 环境检查"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "❌ 没有 python3"; exit 1; }
PYV="$($PY -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
echo "  python3 $PYV ($PY)"
$PY - <<'PYEOF'
import sys
if sys.version_info < (3, 8):
    sys.exit("需要 Python >= 3.8")
PYEOF
echo "  OK: Debian/Ubuntu + python3 $PYV"

# ------------------------------------------------------------ [2/6] apt 依赖
echo
echo "[2/6] 安装系统依赖（apt）"
need=()
for c in curl openssl v4l2-ctl lsof qrencode; do
  command -v "$c" >/dev/null 2>&1 || need+=("$c")
done
command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1 || need+=(firefox-esr)
if [ ${#need[@]} -eq 0 ]; then
  echo "  依赖已齐全，跳过"
else
  echo "  需要补装：${need[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt_ok=1
  heartbeat "apt-get update" apt-get update -qq || apt_ok=0
  # 注意包名：Debian/Ubuntu 里提供 v4l2-ctl 的包叫 v4l-utils（不是 v4l2-utils）
  pkgs=(curl ca-certificates openssl v4l-utils lsof qrencode)
  command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1 || pkgs+=(firefox-esr)
  if [ "$apt_ok" = 1 ]; then
    heartbeat "apt-get install ${pkgs[*]}" apt-get install -y -qq --no-install-recommends "${pkgs[@]}" \
      || echo "  ⚠️ 部分包安装失败，可稍后手动执行： apt-get install -y ${pkgs[*]}"
  else
    echo "  ⚠️ apt 源不可用（热点或网关拦截 http 源、需要代理）。缺少的包不影响通话，有网后补装："
    echo "     sudo apt-get update && sudo apt-get install -y ${pkgs[*]}"
  fi
fi

# --------------------------------------------------------- [3/6] cloudflared
echo
echo "[3/6] 检查 cloudflared（Cloudflare 快速隧道，给手机一个真证书 HTTPS 地址）"
if command -v cloudflared >/dev/null 2>&1; then
  echo "  已安装：$(cloudflared --version 2>&1 | head -1)"
else
  case "$ARCH" in
    aarch64|arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64";;
    x86_64|amd64)  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64";;
    armv7l|armv6l) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm";;
    *) echo "  ❌ 不支持的架构 $ARCH，请手动安装 cloudflared"; CF_URL="";;
  esac
  if [ -n "$CF_URL" ]; then
    echo "  下载：$CF_URL"
    tmp="$(mktemp)"
    if heartbeat "下载 cloudflared（约 35 MB）" curl -fL --retry 2 -o "$tmp" "$CF_URL"; then
      install -m 0755 "$tmp" /usr/local/bin/cloudflared
      rm -f "$tmp"
      echo "  已安装到 /usr/local/bin/cloudflared"
    else
      rm -f "$tmp"
      echo "  ⚠️ 下载失败。可以在一台联网的电脑上下载后拷到板子上："
      echo "     $CF_URL"
      echo "     scp cloudflared-linux-arm64 <user>@<板子IP>:/tmp/cloudflared && sudo install -m755 /tmp/cloudflared /usr/local/bin/cloudflared"
      echo "     没有 cloudflared 也能跑（局域网直连），只是手机访问会缺真证书。"
    fi
  fi
fi

# ------------------------------------------------------------ [4/6] 证书
echo
echo "[4/6] 生成本地 CA + 服务器证书（https 端口 8443 用）"
FORCE="${FORCE:-0}" bash "$APP_DIR/src/tools/make_cert.sh" || echo "  ⚠️ 证书生成失败（板端用 http://localhost:8080 不受影响）"

# ------------------------------------------------------ [5/6] 摄像头节点修复
echo
echo "[5/6] 摄像头节点（libwebrtc 只枚举 /dev/video0..63）"
bash "$APP_DIR/src/tools/camera_node.sh" --check && CAM_OK=0 || CAM_OK=1
if [ "$CAM_OK" = 0 ]; then
  echo "  无需修复"
else
  bash "$APP_DIR/src/tools/camera_node.sh" --target 63 || true
  # 做成开机自启，避免重启后失效
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
  echo "  已安装开机自启：webrtc-camlink.service"
fi

# ------------------------------------------------------------- [6/6] 自检
echo
echo "[6/6] 自检"
$PY -m py_compile "$APP_DIR/src/server.py" && echo "  OK: src/server.py 语法检查通过"
for f in wsclient.py test_signaling.py edge_probe.py; do
  $PY -m py_compile "$APP_DIR/src/tools/$f" && echo "  OK: src/tools/$f"
done
chmod +x "$APP_DIR"/*.sh "$APP_DIR"/src/tools/*.sh 2>/dev/null || true

# root 创建的目录交还给调用者，否则用户态 start.sh 写不进日志
if [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" \
    "$APP_DIR/local" "$APP_DIR/src/certs" 2>/dev/null || true
  echo "  OK: local/ 与 src/certs/ 属主已改为 $SUDO_USER"
fi

if bash "$APP_DIR/src/tools/camera_node.sh" --check | grep -q '^ok'; then
  echo "  OK: 摄像头可被浏览器枚举"
else
  echo "  ⚠️ 摄像头当前不可被浏览器枚举 —— 页面会自动使用合成测试画面，插好 USB 摄像头后重跑本脚本"
fi

echo
echo "=============================================================="
echo " Deployment complete"
echo "=============================================================="
echo " 下一步： bash $APP_DIR/start.sh"
echo " 停止：   bash $APP_DIR/stop.sh"
echo "=============================================================="
