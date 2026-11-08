#!/usr/bin/env bash
# ================================================================
#  构建单文件版本
#  将 lib/ 下的模块按 modules.list 顺序拼接为:
#    dist/sing-box-oneclick.sh
# ================================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODULE_LIST="$SCRIPT_DIR/lib/modules.list"
OUT_DIR="$SCRIPT_DIR/dist"
OUT_FILE="$OUT_DIR/sing-box-oneclick.sh"

if [ ! -r "$MODULE_LIST" ]; then
  printf '[错误] 模块清单不存在: %s\n' "$MODULE_LIST" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# ================================================================'
  printf '%s\n' '#  sing-box 一键部署管理脚本（单文件构建版）'
  printf '%s\n' '#  由 build.sh 自动生成，请勿直接编辑；源码见 lib/ 目录'
  printf '#  构建时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n' '# ================================================================'
  printf '\n'
  while IFS= read -r module || [ -n "$module" ]; do
    case "$module" in
      ''|'#'*) continue ;;
    esac
    module_path="$SCRIPT_DIR/lib/$module"
    if [ ! -r "$module_path" ]; then
      printf '[错误] 缺少模块: %s\n' "$module_path" >&2
      exit 1
    fi
    cat "$module_path"
    printf '\n'
  done < "$MODULE_LIST"
  printf '%s\n' 'main "$@"'
} > "$OUT_FILE"

chmod +x "$OUT_FILE"
bash -n "$OUT_FILE"

printf '[完成] 已生成单文件版: %s\n' "$OUT_FILE"
