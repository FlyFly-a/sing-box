# ================================================================
#  入口主流程: 命令行参数、首次安装引导与菜单启动
# ================================================================
usage() {
  cat <<EOF
sing-box 一键部署管理脚本

用法:
  bash $0            启动交互式管理菜单
  bash $0 install    安装/更新 sing-box 核心并生成服务
  bash $0 status     查看运行状态
  bash $0 help       显示帮助

说明:
  需要 root 权限运行。
  所有节点、出站和证书均保存在 $SB_DIR 下。
EOF
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  need_root
  ensure_dirs
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

  if [ ! -x "$BIN" ]; then
    clear 2>/dev/null || true
    printf '%s\n' "=================================================="
    printf '%s\n' "        欢迎使用 sing-box 一键部署管理脚本"
    printf '%s\n' "=================================================="
    printf '脚本将自动识别系统架构并安装 sing-box。\n'
    printf '安装完成后可在菜单中管理节点、出站和运行状态。\n\n'
    if confirm "未检测到 sing-box 核心，是否立即自动安装?" "y"; then
      if install_core; then
        write_service
        rebuild_config || true
        info "安装完成，请进入“节点管理”添加节点"
      else
        error "安装失败，请检查网络后重试"
      fi
      pause
    fi
  fi

  if [ -x "$BIN" ]; then
    if ! "$BIN" version >/dev/null 2>&1; then
      warn "当前核心无法运行，请进入“核心管理 -> 更新核心”重新安装"
    fi
    if has_systemd && [ ! -f "$SERVICE_FILE" ]; then
      write_service
    elif has_openrc && [ ! -f /etc/init.d/sing-box ]; then
      write_service
    fi
  fi

  if [ ! -f "$CONF" ]; then
    rebuild_config || true
  fi

  main_menu
}
