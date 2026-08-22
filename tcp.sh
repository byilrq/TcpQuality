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

TCPQUALITY_BUILD_ID="threecity-menu-v12"

RAW_BASE="${TCPQUALITY_RAW_BASE:-https://raw.githubusercontent.com/byilrq/TcpQuality/main}"
case "$RAW_BASE" in
  http://*|https://*) ;;
  *)
    echo "[!] TCPQUALITY_RAW_BASE 非法，已回退到官方 GitHub 源" >&2
    RAW_BASE="https://raw.githubusercontent.com/byilrq/TcpQuality/main"
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
INTERACTIVE_MENU=0
MENU_EXIT=0

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
  MENU_EXIT=0
  CORE_ARGS=()
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
    IFS= read -r choice || { MENU_EXIT=1; return 0; }
    case "$choice" in
      1) CORE_ARGS=(--only-domestic-latency); return 0 ;;
      2) CORE_ARGS=(--route -v4); return 0 ;;
      3) CORE_ARGS=(--route-hops -v4); return 0 ;;
      4) CORE_ARGS=(--only-intl); return 0 ;;
      5) CORE_ARGS=(--only-speedtest); return 0 ;;
      0) MENU_EXIT=1; return 0 ;;
      *) printf '\n[!] 无效选项，请重新选择。\n'; sleep 1 ;;
    esac
  done
}

verify_bundle_file() {
  local f="$1" marker="TCPQUALITY_BUILD_ID=\"${TCPQUALITY_BUILD_ID}\""
  [ -f "$f" ] && grep -Fq "$marker" "$f"
}

prepare_bundle() {
  local core_url rootfs_url

  # 完整解压运行时优先使用同目录文件；bash <(curl ...) 时 /dev/fd 下没有配套文件，
  # 自动把同版本 core/rootfs 拉到临时目录后继续执行。
  if verify_bundle_file "$LOCAL_CORE" && verify_bundle_file "$LOCAL_ROOTFS"; then
    return 0
  fi

  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-entry.XXXXXX")
  LOCAL_CORE="$TEMP_DIR/runTcpQuality-core.sh"
  LOCAL_ROOTFS="$TEMP_DIR/runTcpQuality-rootfs.sh"
  core_url="$RAW_BASE/runTcpQuality-core.sh"
  rootfs_url="$RAW_BASE/runTcpQuality-rootfs.sh"

  echo "[i] 单文件在线运行：正在获取同版本 core/rootfs..."
  curl -fL --retry 3 --connect-timeout 15 --max-time 120 "$core_url" -o "$LOCAL_CORE" || {
    echo "[X] 下载失败: $core_url" >&2
    exit 1
  }
  curl -fL --retry 3 --connect-timeout 15 --max-time 120 "$rootfs_url" -o "$LOCAL_ROOTFS" || {
    echo "[X] 下载失败: $rootfs_url" >&2
    exit 1
  }
  chmod 0755 "$LOCAL_CORE" "$LOCAL_ROOTFS"

  if ! verify_bundle_file "$LOCAL_CORE" || ! verify_bundle_file "$LOCAL_ROOTFS"; then
    echo "[X] 在线获取的 TcpQuality 文件版本与入口不一致。" >&2
    echo "[i] 当前入口版本: $TCPQUALITY_BUILD_ID；请确认 GitHub 三个脚本已一起更新。" >&2
    exit 1
  fi
}

trap cleanup EXIT
prepare_bundle

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
  INTERACTIVE_MENU=1
fi

run_selected_once() {
  local rc=0
  local -a rootfs_args=()

  if [ "$NO_ROOTFS" -eq 1 ] || [ "${TCPQUALITY_INSIDE_ROOTFS:-0}" -eq 1 ]; then
    bash "$LOCAL_CORE" "${CORE_ARGS[@]}"
    return $?
  fi

  if [ "$(uname -s)" != Linux ]; then
    echo "[!] rootfs/chroot 仅支持 Linux，当前系统将直接运行 core" >&2
    bash "$LOCAL_CORE" "${CORE_ARGS[@]}"
    return $?
  fi

  rootfs_args+=(--distro "$ROOTFS_DISTRO")
  [ "$KEEP_ROOTFS" -eq 1 ] && rootfs_args+=(--keep)
  rootfs_args+=(--core "$LOCAL_CORE")

  if [ "$(id -u)" -eq 0 ]; then
    bash "$LOCAL_ROOTFS" "${rootfs_args[@]}" -- "${CORE_ARGS[@]}"
    return $?
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo -E bash "$LOCAL_ROOTFS" "${rootfs_args[@]}" -- "${CORE_ARGS[@]}"
    return $?
  fi

  echo "[X] 默认 rootfs 模式需要 root 权限；请使用 root 运行，或加 --no-rootfs 直接运行宿主模式" >&2
  return 1
}

if [ "$INTERACTIVE_MENU" -eq 1 ]; then
  while true; do
    show_menu
    [ "$MENU_EXIT" -eq 1 ] && exit 0

    run_rc=0
    run_selected_once || run_rc=$?
    echo
    if [ "$run_rc" -ne 0 ]; then
      echo "[!] 本次测试返回状态: $run_rc"
    fi
    printf '按回车返回主菜单...'
    IFS= read -r _ || exit "$run_rc"
  done
fi

run_selected_once
exit $?
