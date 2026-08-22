#!/usr/bin/env bash
#
# TcpQuality 三城市三网精简版入口（北京 / 上海 / 广州，保留国际互连与回程线路）。
# 旧命令保持不变：
# fish/zsh 不支持或不稳定时可用：
#   curl -fsSL https://tcpquality.ibsgss.uk/run | env TERM=xterm bash
#
# 默认进入临时 Debian rootfs + chroot 后运行 runTcpQuality-core.sh。
# 使用 --no-rootfs 可直接在宿主环境运行 core，便于调试。
#

set -Eeuo pipefail

TCPQUALITY_BUILD_ID="threecity-menu-v10"

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
  其余参数会原样透传给 runTcpQuality-core.sh。例如 -v4、--speedtest、--route。默认交互菜单按项目运行，不会自动全部测试。
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
    printf '%s\n' \
      '' \
      '============================================================' \
      '  TcpQuality - 三网精简测试菜单' \
      '============================================================' \
      '  1. 三网 TCP 质量 / 丢包 / 延迟' \
      '  2. 三网 线路类型识别（IPv4）' \
      '  3. 三网 逐跳回程测试（IPv4）' \
      '  4. 国际互联测试' \
      '  5. 三网 单线程测速' \
      '  0. 退出' \
      '============================================================' \
      ''
    printf '请选择 [0-5]: '
    IFS= read -r choice || exit 1
    case "$choice" in
      1) CORE_ARGS=(--only-domestic-latency); break ;;
      2) CORE_ARGS=(--route -v4); break ;;
      3) CORE_ARGS=(--route-hops -v4); break ;;
      4) CORE_ARGS=(--only-intl); break ;;
      5) CORE_ARGS=(--only-speedtest); break ;;
      0) exit 0 ;;
      *) printf '\n[!] 无效选项，请重新选择。\n'; sleep 1 ;;
    esac
  done
}

verify_local_bundle() {
  local f marker="TCPQUALITY_BUILD_ID=\"${TCPQUALITY_BUILD_ID}\""
  for f in "$LOCAL_CORE" "$LOCAL_ROOTFS"; do
    if [ ! -f "$f" ]; then
      echo "[X] 缺少同版本文件: $f" >&2
      echo "[i] 请完整解压压缩包后，在同一目录运行 runTcpQuality.sh；不要只替换入口脚本。" >&2
      exit 1
    fi
    if ! grep -Fq "$marker" "$f"; then
      echo "[X] TcpQuality 三文件版本不一致: $(basename "$f")" >&2
      echo "[i] 当前入口版本: $TCPQUALITY_BUILD_ID。请删除旧文件后完整解压新版压缩包。" >&2
      exit 1
    fi
  done
}

verify_local_bundle
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
  exec bash "$LOCAL_CORE" "${CORE_ARGS[@]}"
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
    cp "$0" "$temp_entry"
    cp "$LOCAL_CORE" "$TEMP_DIR/runTcpQuality-core.sh"
    cp "$LOCAL_ROOTFS" "$TEMP_DIR/runTcpQuality-rootfs.sh"
    chmod 0755 "$temp_entry" "$TEMP_DIR/runTcpQuality-core.sh" "$TEMP_DIR/runTcpQuality-rootfs.sh"
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

ROOTFS_EXTRA_ARGS+=(--core "$LOCAL_CORE")
exec bash "$LOCAL_ROOTFS" "${ROOTFS_EXTRA_ARGS[@]}" -- "${CORE_ARGS[@]}"
