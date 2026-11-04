#!/usr/bin/env bash
# 开机自启管理
#   sudo bash setup_autostart.sh install [--with-kiosk]
#   sudo bash setup_autostart.sh uninstall
#   bash setup_autostart.sh status
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="$(command -v python3 || echo /usr/bin/python3)"
SYS_DIR=/etc/systemd/system
SVC_SERVER=webrtc-av-call
SVC_TUNNEL=webrtc-av-call-tunnel
SVC_CAM=webrtc-camlink
KIOSK_USER_UNIT="webrtc-av-call-kiosk"
PORT="${PORT:-8443}"
HTTP_PORT="${HTTP_PORT:-8080}"
ROOM="${ROOM:-demo}"
WITH_KIOSK=0

for a in "$@"; do
  if [ "$a" = "--with-kiosk" ]; then WITH_KIOSK=1; fi
done
ACTION="${1:-status}"

need_root() { [ "$(id -u)" = 0 ] || { echo "请用 root 运行： sudo bash $0 $ACTION"; exit 1; }; }

# ----------------------------------------------------------------- 单元文件
write_units() {
  cat > "$SYS_DIR/$SVC_SERVER.service" <<EOF
[Unit]
Description=WebRTC A/V Call Demo - signaling + web server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$PYTHON_BIN $APP_DIR/src/server.py --tls --port $PORT --http-port $HTTP_PORT
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  # 隧道：cloudflared 前台常驻，起来后用 ExecStartPost 把地址写进 local/ 并生成二维码
  cat > "$SYS_DIR/$SVC_TUNNEL.service" <<EOF
[Unit]
Description=Cloudflare quick tunnel for WebRTC A/V Call Demo
After=network-online.target $SVC_SERVER.service
Wants=network-online.target
Requires=$SVC_SERVER.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$HTTP_PORT --no-autoupdate --logfile $APP_DIR/local/cloudflared.log
ExecStartPost=/bin/bash -c 'sleep 6; ROOM=$ROOM /bin/bash $APP_DIR/src/tools/publish_url.sh || true'
Restart=on-failure
RestartSec=8
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SYS_DIR/$SVC_CAM.service" <<EOF
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
  echo "  [OK] 已写入 $SYS_DIR/$SVC_SERVER.service"
  echo "  [OK] 已写入 $SYS_DIR/$SVC_TUNNEL.service"
  echo "  [OK] 已写入 $SYS_DIR/$SVC_CAM.service"
}

install_kiosk_user_unit() {
  local owner="${SUDO_USER:-$(id -un)}"
  local home; home="$(getent passwd "$owner" | cut -d: -f6)"
  local dir="$home/.config/systemd/user"
  mkdir -p "$dir" "$APP_DIR/local"
  chown -R "$owner:$owner" "$dir" "$APP_DIR/local" 2>/dev/null || true
  cat > "$dir/$KIOSK_USER_UNIT.service" <<EOF
[Unit]
Description=WebRTC A/V Call Demo - kiosk browser on the board display
After=graphical-session.target
PartOf=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-0
Environment=DISPLAY=:0
Environment=MOZ_ENABLE_WAYLAND=1
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 20); do curl -sf -o /dev/null http://127.0.0.1:$HTTP_PORT/healthz && exit 0; sleep 1; done'
ExecStart=/bin/bash $APP_DIR/src/tools/open_browser.sh "http://localhost:$HTTP_PORT/?room=$ROOM&name=Board&autostart=1" kiosk
Restart=always
RestartSec=8

[Install]
WantedBy=graphical-session.target
EOF
  chown "$owner:$owner" "$dir/$KIOSK_USER_UNIT.service" 2>/dev/null || true
  echo "  [OK] 已写入 $dir/$KIOSK_USER_UNIT.service (用户: $owner)"
  su - "$owner" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$owner") systemctl --user daemon-reload && XDG_RUNTIME_DIR=/run/user/$(id -u "$owner") systemctl --user enable $KIOSK_USER_UNIT 2>&1 | tail -2" || true
  echo "  [TIP] 让用户服务在未登录时也能跑： loginctl enable-linger $owner"
}

install_all() {
  need_root
  mkdir -p "$APP_DIR/local"
  echo "==> 安装开机自启"
  write_units
  systemctl daemon-reload
  systemctl enable "$SVC_SERVER" "$SVC_TUNNEL" "$SVC_CAM" >/dev/null 2>&1 || true
  systemctl restart "$SVC_CAM" || true
  systemctl restart "$SVC_SERVER" || true
  sleep 2
  systemctl restart "$SVC_TUNNEL" || true
  sleep 8
  echo
  for s in "$SVC_SERVER" "$SVC_TUNNEL" "$SVC_CAM"; do
    printf "  %-26s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
  done
  if [ -f "$APP_DIR/local/tunnel-url.txt" ]; then
    echo "  手机访问： $(cat "$APP_DIR/local/tunnel-url.txt")/?room=$ROOM"
  fi
  if [ "$WITH_KIOSK" = 1 ]; then
    install_kiosk_user_unit
  fi
  echo "  [OK] 已启用开机自启（关闭： sudo bash setup_autostart.sh uninstall）"
}

uninstall_all() {
  need_root
  echo "==> 卸载开机自启"
  for s in "$SVC_TUNNEL" "$SVC_SERVER" "$SVC_CAM"; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
    rm -f "$SYS_DIR/$s.service"
    echo "  [OK] 已移除 $s"
  done
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
  local owner="${SUDO_USER:-$(id -un)}"
  local home; home="$(getent passwd "$owner" | cut -d: -f6)"
  if [ -f "$home/.config/systemd/user/$KIOSK_USER_UNIT.service" ]; then
    su - "$owner" -c "systemctl --user disable --now $KIOSK_USER_UNIT" 2>/dev/null || true
    rm -f "$home/.config/systemd/user/$KIOSK_USER_UNIT.service"
    echo "  [OK] 已移除 kiosk 用户服务"
  fi
}

show_status() {
  echo "==> 自启状态"
  for s in "$SVC_SERVER" "$SVC_TUNNEL" "$SVC_CAM"; do
    printf "  %-26s %-10s %s\n" "$s" "$(systemctl is-enabled "$s" 2>/dev/null || echo -)" "$(systemctl is-active "$s" 2>/dev/null || echo -)"
  done
  [ -f "$APP_DIR/local/tunnel-url.txt" ] && echo "  手机访问： $(cat "$APP_DIR/local/tunnel-url.txt")/?room=$ROOM"
  [ -f "$APP_DIR/local/qrcode.png" ] && echo "  二维码：   $APP_DIR/local/qrcode.png"
  echo
  echo "  查看日志： journalctl -u $SVC_SERVER -n 30 --no-pager"
  echo "            journalctl -u $SVC_TUNNEL -n 30 --no-pager"
}

case "$ACTION" in
  install)   install_all;;
  uninstall) uninstall_all;;
  status)    show_status;;
  *) echo "用法: sudo bash $0 [install|uninstall|status] [--with-kiosk]"; exit 1;;
esac
