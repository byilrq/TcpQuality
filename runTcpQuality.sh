#!/usr/bin/env bash
#
# TcpQuality 上海三网精简版入口（保留国际互连与回程线路）。
# 旧命令保持不变：
#   bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)
#   bash <(curl -fsSL https://tcpquality.ibsgss.uk/run)
# fish/zsh 不支持或不稳定时可用：
#   curl -fsSL https://tcpquality.ibsgss.uk/run | env TERM=xterm bash
#
# 默认进入临时 Debian rootfs + chroot 后运行 runTcpQuality-core.sh。
# 使用 --no-rootfs 可直接在宿主环境运行 core，便于调试。
#

set -Eeuo pipefail

RAW_BASE="${TCPQUALITY_RAW_BASE:-https://raw.githubusercontent.com/ibsgss/TcpQuality/main}"
case "$RAW_BASE" in
  http://*|https://*) ;;
  *)
    echo "[!] TCPQUALITY_RAW_BASE 非法，已回退到官方 GitHub 源" >&2
    RAW_BASE="https://raw.githubusercontent.com/ibsgss/TcpQuality/main"
    ;;
esac
RAW_BASE="${RAW_BASE%/}"
if [ -z "${TCPQUALITY_ROOTFS_SOURCE_ORDER:-}" ]; then
  case "$RAW_BASE" in
    *tcpquality.ibsgss.uk*)
      export TCPQUALITY_ROOTFS_SOURCE_ORDER="ibsgss github"
      ;;
    *githubusercontent.com*|*github.com*)
      export TCPQUALITY_ROOTFS_SOURCE_ORDER="github ibsgss"
      ;;
    *)
      export TCPQUALITY_ROOTFS_SOURCE_ORDER="ibsgss github"
      ;;
  esac
fi
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || printf '.')
LOCAL_ROOTFS="$SCRIPT_DIR/runTcpQuality-rootfs.sh"
LOCAL_CORE="$SCRIPT_DIR/runTcpQuality-core.sh"
ORIGINAL_ARGS=("$@")
NO_ROOTFS=0
KEEP_ROOTFS=0
ROOTFS_DEBUG=0
ROOTFS_DISTRO="${TCPQUALITY_ROOTFS_DISTRO:-debian}"
ROOTFS_EXTRA_ARGS=()
CORE_ARGS=()
TEMP_DIR=""
FORCE_MENU=0

usage() {
  cat <<'EOF'
用法:
  bash runTcpQuality.sh [入口选项] [主脚本参数]

入口选项:
  --no-rootfs          不使用 rootfs，直接在宿主环境运行检测 core
  --rootfs-distro NAME rootfs 类型：debian 或 alpine，默认 debian
  --debug-rootfs       保留临时 rootfs，便于调试
  --menu               显示交互式测试菜单

主脚本参数:
  其余参数会原样透传给 runTcpQuality-core.sh。例如 -v4、--speedtest、--route。默认运行含上海三网回程线路与国际互连。
EOF
}

cleanup() {
  [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ] && rm -rf -- "$TEMP_DIR" || true
  return 0
}

show_menu() {
  local choice=""
  while true; do
    clear 2>/dev/null || true
    printf '%s
'       ''       '============================================================'       '  TcpQuality - 上海三网精简测试菜单'       '============================================================'       '  1. 上海三网 TCP 质量 / 丢包 / 延迟'       '  2. 上海三网 回程路由 + 延迟'       '  3. 上海三网 仅回程路由'       '  4. 国际互联测试'       '  5. 上海三网 单线程测速'       '  6. 全部测试'       '  0. 退出'       '============================================================'       ''
    printf '请选择 [0-6]: '
    IFS= read -r choice || exit 1
    case "$choice" in
      1) CORE_ARGS=(--only-domestic-latency); break ;;
      2) CORE_ARGS=(--only-domestic); break ;;
      3) CORE_ARGS=(--route); break ;;
      4) CORE_ARGS=(--only-intl); break ;;
      5) CORE_ARGS=(--only-speedtest); break ;;
      6) CORE_ARGS=(); break ;;
      0) exit 0 ;;
      *) printf '
[!] 无效选项，请重新选择。
'; sleep 1 ;;
    esac
  done
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-rootfs)
      NO_ROOTFS=1
      shift
      ;;
    --rootfs-distro)
      [ "$#" -ge 2 ] || { echo "[X] --rootfs-distro 缺少参数" >&2; exit 1; }
      ROOTFS_DISTRO="$2"
      shift 2
      ;;
    --debug-rootfs)
      ROOTFS_DEBUG=1
      KEEP_ROOTFS=1
      shift
      ;;
    --menu)
      FORCE_MENU=1
      shift
      ;;
    --rootfs-help)
      if [ -f "$LOCAL_ROOTFS" ]; then
        exec bash "$LOCAL_ROOTFS" --help
      fi
      usage
      exit 0
      ;;
    -h|--help)
      CORE_ARGS+=("--help")
      NO_ROOTFS=1
      shift
      ;;
    --)
      shift
      CORE_ARGS+=("$@")
      break
      ;;
    *)
      CORE_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$ROOTFS_DISTRO" in
  debian|alpine) ;;
  *) echo "[X] --rootfs-distro 只能是 debian 或 alpine" >&2; exit 1 ;;
esac

if [ "$FORCE_MENU" -eq 1 ] || [ "${#CORE_ARGS[@]}" -eq 0 ]; then
  show_menu
fi

run_core_direct() {
  local core="$LOCAL_CORE"
  if [ ! -f "$core" ]; then
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-entry.XXXXXX")
    core="$TEMP_DIR/runTcpQuality-core.sh"
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
      "$RAW_BASE/runTcpQuality-core.sh" -o "$core"
    chmod 0755 "$core"
  fi
  exec bash "$core" "${CORE_ARGS[@]}"
}

if [ "$NO_ROOTFS" -eq 1 ] || [ "${TCPQUALITY_INSIDE_ROOTFS:-0}" -eq 1 ]; then
  run_core_direct
fi

if [ "$(uname -s)" != Linux ]; then
  echo "[!] rootfs/chroot 仅支持 Linux，当前系统将直接运行 core" >&2
  run_core_direct
fi

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-entry.XXXXXX")
    temp_entry="$TEMP_DIR/runTcpQuality.sh"
    cat "$0" > "$temp_entry"
    chmod 0755 "$temp_entry"
    exec sudo -E bash -c '
      dir=$1
      script=$2
      shift 2
      trap "rm -rf -- \"$dir\"" EXIT
      exec bash "$script" "$@"
    ' bash "$TEMP_DIR" "$temp_entry" "${ORIGINAL_ARGS[@]}"
  fi
  echo "[X] 默认 rootfs 模式需要 root 权限；请使用 root 运行，或加 --no-rootfs 直接运行宿主模式" >&2
  exit 1
fi

ROOTFS_EXTRA_ARGS+=(--distro "$ROOTFS_DISTRO")
[ "$KEEP_ROOTFS" -eq 1 ] && ROOTFS_EXTRA_ARGS+=(--keep)

if [ -f "$LOCAL_ROOTFS" ] && [ -f "$LOCAL_CORE" ]; then
  export TCPQUALITY_CORE_SCRIPT="$LOCAL_CORE"
  exec bash "$LOCAL_ROOTFS" "${ROOTFS_EXTRA_ARGS[@]}" -- "${CORE_ARGS[@]}"
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-entry.XXXXXX")
rootfs_runner="$TEMP_DIR/runTcpQuality-rootfs.sh"
core_script="$TEMP_DIR/runTcpQuality-core.sh"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
  "$RAW_BASE/runTcpQuality-rootfs.sh" -o "$rootfs_runner"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
  "$RAW_BASE/runTcpQuality-core.sh" -o "$core_script"
chmod 0755 "$rootfs_runner" "$core_script"
export TCPQUALITY_CORE_SCRIPT="$core_script"
exec bash "$rootfs_runner" "${ROOTFS_EXTRA_ARGS[@]}" -- "${CORE_ARGS[@]}"
