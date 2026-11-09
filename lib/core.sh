# ================================================================
#  核心管理
# ================================================================
update_core() {
  local cur latest was=0
  if [ ! -x "$BIN" ]; then
    warn "尚未安装核心，开始安装"
    install_core && write_service
    return $?
  fi
  cur=$(singbox_version)
  info "当前核心版本: ${cur:-未知}"
  latest=$(get_latest_version) || true
  if [ -z "$latest" ]; then
    error "获取最新版本失败，请检查网络"
    return 1
  fi
  info "最新核心版本: $latest"
  if [ "$cur" = "$latest" ]; then
    if ! confirm "当前已是最新版本，是否强制重新安装?" "n"; then
      return 0
    fi
  else
    if ! confirm "是否更新到 v${latest} ?" "y"; then
      info "已取消"
      return 0
    fi
  fi
  if core_running; then
    was=1
    stop_core
  fi
  if install_core "$latest"; then
    write_service
    if [ "$was" = "1" ]; then
      start_core || return 1
    fi
    info "核心更新完成"
  else
    error "核心更新失败"
    if [ "$was" = "1" ]; then
      start_core
    fi
    return 1
  fi
}

uninstall_core() {
  local keep=1
  warn "卸载将停止服务并删除核心文件: $BIN"
  if ! confirm "确定卸载 sing-box 核心?" "n"; then
    info "已取消"
    return 0
  fi
  if confirm "是否保留节点、证书和配置文件? (推荐保留)" "y"; then
    keep=1
  else
    keep=0
  fi
  stop_core
  if has_systemd; then
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
  fi
  if has_openrc && [ -f /etc/init.d/sing-box ]; then
    if command -v rc-update >/dev/null 2>&1; then
      rc-update del sing-box default >/dev/null 2>&1 || true
    fi
    rm -f /etc/init.d/sing-box
  fi
  rm -f "$BIN" "${BIN}.new" "${BIN}.old"
  info "核心已卸载"
  if [ "$keep" = "0" ]; then
    if confirm "再次确认: 删除整个目录 $SB_DIR ? 此操作不可恢复" "n"; then
      rm -rf "$SB_DIR"
      info "配置目录已删除"
      return 0
    fi
    info "已保留配置目录"
  else
    info "配置目录已保留: $SB_DIR"
  fi
}

show_core_version() {
  if [ -x "$BIN" ]; then
    "$BIN" version
  else
    warn "未安装 sing-box 核心"
  fi
}

menu_core() {
  local c
  while true; do
    printf '\n%s\n' "------------- 核心管理 -------------"
    printf ' 1) 更新核心\n'
    printf ' 2) 卸载核心\n'
    printf ' 3) 查看核心版本\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) update_core; pause ;;
      2) uninstall_core; pause ;;
      3) show_core_version; pause ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

