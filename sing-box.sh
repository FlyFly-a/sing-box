#!/usr/bin/env bash
# ================================================================
#  sing-box 一键安装 / 多协议节点 / 出站 / 运行管理脚本
#  模块化入口文件
#
#  适用系统: Debian / Ubuntu / CentOS / RHEL / Fedora / Alpine / openSUSE
#  适用架构: x86_64 / aarch64 / armv7 / armv6 / i386 / riscv64 / s390x / ppc64le
#
#  使用方式:
#    bash sing-box.sh              交互式管理
#    bash sing-box.sh install      安装核心并生成服务
#    bash sing-box.sh status       查看运行状态
#    bash build.sh                 打包为单文件版 dist/sing-box-oneclick.sh
# ================================================================

SCRIPT_PATH="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  resolved_path=$(readlink -f "$SCRIPT_PATH" 2>/dev/null || true)
  [ -n "$resolved_path" ] && SCRIPT_PATH=$resolved_path
fi
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" && pwd)
MODULE_LIST="$SCRIPT_DIR/lib/modules.list"

if [ ! -r "$MODULE_LIST" ]; then
  printf '[错误] 模块清单不存在: %s\n' "$MODULE_LIST" >&2
  printf '请确认 lib/ 目录与 sing-box.sh 位于同一目录。\n' >&2
  exit 1
fi

while IFS= read -r module || [ -n "$module" ]; do
  case "$module" in
    ''|'#'*) continue ;;
  esac
  module_path="$SCRIPT_DIR/lib/$module"
  if [ ! -r "$module_path" ]; then
    printf '[错误] 缺少模块: %s\n' "$module_path" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$module_path"
done < "$MODULE_LIST"

main "$@"
