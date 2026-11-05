#!/usr/bin/env bash
# Map the UVC camera to /dev/video63.
#
# Browser capture only enumerates /dev/video0..63, while RK3576 platform nodes occupy 0..72,
# so a USB camera at /dev/video73 is invisible to the browser (getUserMedia throws NotFoundError).
# This script removes one idle debug node (rkvpss_scale2 by default) and points it at the camera node;
# if the camera already sits within 0..63 it does nothing.
#
#   sudo bash src/tools/camera_node.sh              # apply the mapping
#   bash src/tools/camera_node.sh --check           # check: 0=usable 1=mapping needed
#   bash src/tools/camera_node.sh --show            # show nodes
#   sudo bash src/tools/camera_node.sh --uninstall  # restore
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
    *) echo "Unknown option $1"; exit 1;;
  esac
done

if [ "$MODE" = uninstall ]; then
  sudo rm -f "/dev/video$TARGET_NUM"
  sudo udevadm trigger --subsystem-match=video4linux 2>/dev/null || true
  echo "Removed the /dev/video$TARGET_NUM symlink and re-triggered udev"
  exit 0
fi

# Only a real capture node reports a format (metadata nodes of the same model fail VIDIOC_G_FMT)
is_capture_node() { v4l2-ctl -d "/dev/video$1" --get-fmt-video >/dev/null 2>&1; }
is_usb_camera()   { v4l2-ctl -d "/dev/video$1" --info 2>/dev/null | grep -qiE 'USB Camera|USB camera|UVC'; }

show_state() {
  echo "=== /dev/video$TARGET_NUM ==="
  ls -l "/dev/video$TARGET_NUM" 2>/dev/null | sed 's/^/  /' || echo "  (absent)"
  v4l2-ctl -d "/dev/video$TARGET_NUM" --info 2>/dev/null | grep -E "Card type" | sed 's/^/  /'
  echo "=== Nodes above 63 ==="
  for n in $(ls /dev/video* 2>/dev/null | sed 's#/dev/video##' | grep -E '^[0-9]+$' | sort -n); do
    [ "$n" -lt 64 ] && continue
    printf "  video%-3s %-28s %s\n" "$n" \
      "$(cat /sys/class/video4linux/video$n/name 2>/dev/null)" \
      "$(v4l2-ctl -d "/dev/video$n" --get-fmt-video 2>/dev/null | grep -m1 'Pixel Format' | tr -s ' \t' ' ' || echo '(metadata)')"
  done
}

# Whether a browser-enumerable capture node exists within 0..63
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
    echo "need-map: UVC camera is at /dev/video$SRC (>63, not enumerable by the browser)"
    exit 1
  fi
  if camera_visible_to_browser; then
    echo "ok: a browser-enumerable capture node already exists, no mapping needed"
    exit 0
  fi
  echo "no-camera: no camera found (the page will fall back to a synthetic test pattern)"
  exit 0
fi

# ---- Apply mode (root required) ----
if [ "$(id -u)" != "0" ]; then
  echo "root required: sudo bash $0 $*"
  exit 1
fi

SRC_NUM="$(find_camera_above_63 || true)"
if [ -z "${SRC_NUM:-}" ]; then
  if camera_visible_to_browser; then
    echo "✅ A browser-usable capture node already exists, no mapping needed"
  else
    echo "⚠️ No UVC camera found (USB capture node above /dev/video63). Plug it in and confirm with lsusb."
  fi
  exit 0
fi

SRC="/dev/video$SRC_NUM"
TARGET="/dev/video$TARGET_NUM"
echo "==> Camera node $SRC -> mapped to $TARGET"

if [ "$(readlink -f "$TARGET" 2>/dev/null)" = "$(readlink -f "$SRC" 2>/dev/null)" ]; then
  echo "    Already mapped as requested, nothing to do"
  exit 0
fi

if [ -e "$TARGET" ] && command -v lsof >/dev/null 2>&1 && lsof "$TARGET" >/dev/null 2>&1; then
  echo "    ⚠️ $TARGET is in use:"; lsof "$TARGET" | sed 's/^/       /'
  for alt in 62 61 60 59; do
    if ! lsof "/dev/video$alt" >/dev/null 2>&1; then
      TARGET_NUM=$alt; TARGET="/dev/video$alt"; echo "    Using $TARGET instead"; break
    fi
  done
fi

rm -f "$TARGET"
ln -sfn "video$SRC_NUM" "$TARGET"
echo "    ✅ $(ls -l "$TARGET")"
v4l2-ctl -d "$TARGET" --info 2>/dev/null | grep -E "Card type" | sed 's/^/       /'
