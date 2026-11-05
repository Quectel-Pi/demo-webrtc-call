#!/usr/bin/env bash
# 把 UVC 摄像头映射到 /dev/video63。
#
# 浏览器采集只枚举 /dev/video0..63，而 RK3576 的平台节点占满了 0~72，
# USB 摄像头在 /dev/video73 时浏览器看不到（getUserMedia 报 NotFoundError）。
# 本脚本删掉一个空闲调试节点（默认 rkvpss_scale2）改成指向相机节点；
# 相机本来就在 0~63 时自动跳过。
#
#   sudo bash src/tools/camera_node.sh              # 映射
#   bash src/tools/camera_node.sh --check           # 检查：0=可用 1=需要映射
#   bash src/tools/camera_node.sh --show            # 查看节点
#   sudo bash src/tools/camera_node.sh --uninstall  # 还原
set -uo pipefail

TARGET_NUM=63
MODE=apply
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift;;
    --show) MODE=show; shift;;
    --uninstall) MODE=uninstall; shift;;
    --target) TARGET_NUM="$2"; shift 2;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "未知参数 $1"; exit 1;;
  esac
done

if [ "$MODE" = uninstall ]; then
  sudo rm -f "/dev/video$TARGET_NUM"
  sudo udevadm trigger --subsystem-match=video4linux 2>/dev/null || true
  echo "已删除 /dev/video$TARGET_NUM 的软链并重新触发 udev"
  exit 0
fi

# 能读出采集格式 = 真正的采集节点（同型号的 metadata 节点会 VIDIOC_G_FMT 失败）
is_capture_node() { v4l2-ctl -d "/dev/video$1" --get-fmt-video >/dev/null 2>&1; }
is_usb_camera()   { v4l2-ctl -d "/dev/video$1" --info 2>/dev/null | grep -qiE 'USB Camera|USB camera|UVC'; }

show_state() {
  echo "=== /dev/video$TARGET_NUM ==="
  ls -l "/dev/video$TARGET_NUM" 2>/dev/null | sed 's/^/  /' || echo "  (不存在)"
  v4l2-ctl -d "/dev/video$TARGET_NUM" --info 2>/dev/null | grep -E "Card type" | sed 's/^/  /'
  echo "=== 64 号以上的节点 ==="
  for n in $(ls /dev/video* 2>/dev/null | sed 's#/dev/video##' | grep -E '^[0-9]+$' | sort -n); do
    [ "$n" -lt 64 ] && continue
    printf "  video%-3s %-28s %s\n" "$n" \
      "$(cat /sys/class/video4linux/video$n/name 2>/dev/null)" \
      "$(v4l2-ctl -d "/dev/video$n" --get-fmt-video 2>/dev/null | grep -m1 'Pixel Format' | tr -s ' \t' ' ' || echo '(metadata)')"
  done
}

# 0~63 里是否存在能被浏览器枚举的采集节点
camera_visible_to_browser() {
  for n in $(ls /dev/video* 2>/dev/null | sed 's#/dev/video##' | grep -E '^[0-9]+$' | sort -n); do
    [ "$n" -ge 64 ] && continue
    is_capture_node "$n" && return 0
  done
  return 1
}

find_camera_above_63() {
  for n in $(ls /dev/video* 2>/dev/null | sed 's#/dev/video##' | grep -E '^[0-9]+$' | sort -n); do
    [ "$n" -lt 64 ] && continue
    is_usb_camera "$n" || continue
    is_capture_node "$n" && { echo "$n"; return 0; }
  done
  return 1
}

[ "$MODE" = show ] && { show_state; exit 0; }

if [ "$MODE" = check ]; then
  if is_capture_node "$TARGET_NUM" && is_usb_camera "$TARGET_NUM"; then
    echo "ok: /dev/video$TARGET_NUM -> $(readlink "/dev/video$TARGET_NUM" 2>/dev/null)"
    exit 0
  fi
  if SRC="$(find_camera_above_63)"; then
    echo "need-map: UVC 相机在 /dev/video$SRC（>63，浏览器枚举不到）"
    exit 1
  fi
  if camera_visible_to_browser; then
    echo "ok: 已有浏览器可枚举的采集节点，无需映射"
    exit 0
  fi
  echo "no-camera: 没找到摄像头（页面会使用合成测试画面）"
  exit 0
fi

# ---- 应用模式（需要 root）----
if [ "$(id -u)" != "0" ]; then
  echo "需要 root：sudo bash $0 $*"
  exit 1
fi

SRC_NUM="$(find_camera_above_63 || true)"
if [ -z "${SRC_NUM:-}" ]; then
  if camera_visible_to_browser; then
    echo "✅ 已有浏览器可用的采集节点，无需映射"
  else
    echo "⚠️ 没找到 UVC 摄像头（/dev/video64 以上的 USB 采集节点）。插好摄像头后用 lsusb 确认。"
  fi
  exit 0
fi

SRC="/dev/video$SRC_NUM"
TARGET="/dev/video$TARGET_NUM"
echo "==> 相机节点 $SRC → 映射为 $TARGET"

if [ "$(readlink -f "$TARGET" 2>/dev/null)" = "$(readlink -f "$SRC" 2>/dev/null)" ]; then
  echo "    已经是目标映射，无需改动"
  exit 0
fi

if [ -e "$TARGET" ] && command -v lsof >/dev/null 2>&1 && lsof "$TARGET" >/dev/null 2>&1; then
  echo "    ⚠️ $TARGET 正被占用："; lsof "$TARGET" | sed 's/^/       /'
  for alt in 62 61 60 59; do
    if ! lsof "/dev/video$alt" >/dev/null 2>&1; then
      TARGET_NUM=$alt; TARGET="/dev/video$alt"; echo "    改用 $TARGET"; break
    fi
  done
fi

rm -f "$TARGET"
ln -sfn "video$SRC_NUM" "$TARGET"
echo "    ✅ $(ls -l "$TARGET")"
v4l2-ctl -d "$TARGET" --info 2>/dev/null | grep -E "Card type" | sed 's/^/       /'
