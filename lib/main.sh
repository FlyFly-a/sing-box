# ================================================================
#  入口: 命令行参数、首次安装、菜单启动
# ================================================================
usage() {
  cat <<EOF
sing-box 一键部署管理脚本

用法:
  bash $0            启动交互式管理菜单
  bash $0 install    安装/更新核心并注册系统服务
  bash $0 status     查看运行状态
  bash $0 help       显示帮助

说明:
  需要 root 权限运行。
  数据目录: $SB_DIR
EOF
}

require_bash4() {
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    error "需要 bash 4.0 或更高版本"
    exit 1
  fi
}

# 首次运行: 无核心则自动按架构下载安装，不询问
bootstrap_core() {
  [ -x "$BIN" ] && return 0
  printf '%s\n' "=================================================="
  printf '%s\n' "         sing-box 一键部署管理脚本"
  printf '%s\n' "=================================================="
  printf '未检测到 sing-box 核心，开始自动安装 ...\n\n'
  if ! install_core; then
    error "核心安装失败，请检查网络后重试"
    return 1
  fi
  write_service
  rebuild_config || true
  info "安装完成"
  return 0
}

main() {
  require_bash4

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  need_root
  ensure_dirs
  detect_net_env

  case "${1:-}" in
    install)
      ensure_deps || exit 1
      install_core || exit 1
      write_service
      rebuild_config || exit 1
      info "安装完成，执行 bash $0 进入管理菜单"
      exit 0
      ;;
    status)
      show_status
      exit 0
      ;;
  esac

  ensure_deps || { error "依赖不可用，脚本无法运行"; exit 1; }

  bootstrap_core || { pause; exit 1; }

  if ! "$BIN" version >/dev/null 2>&1; then
    warn "当前核心无法运行，请进入核心管理重新安装"
  fi

  # 系统服务缺失时补写
  if has_systemd && [ ! -f "$SERVICE_FILE" ]; then
    write_service
  elif has_openrc && [ ! -f "$OPENRC_FILE" ]; then
    write_service
  fi

  [ -f "$CONF" ] || rebuild_config || true

  main_menu
}
