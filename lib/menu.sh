# ================================================================
#  主菜单
# ================================================================
print_header() {
  local ver state
  ver=$(singbox_version)
  [ -n "$ver" ] || ver="未安装"
  if core_running; then
    state="${C_GRN}运行中${C_RESET}"
  else
    state="${C_YEL}已停止${C_RESET}"
  fi
  printf '%s\n' "=================================================="
  printf '           sing-box 一键管理脚本\n'
  printf ' 核心: %s   状态: %s   节点: %s   出站: %s\n' \
    "$ver" "$state" "$(count_nodes)" "$(count_outbounds)"
  printf '%s\n' "=================================================="
}

main_menu() {
  local c
  while true; do
    ensure_dirs
    clear 2>/dev/null || true
    print_header
    printf ' 1) 节点管理        2) 出站管理\n'
    printf ' 3) 出口路由        4) 运行管理\n'
    printf ' 5) 核心管理        6) 分享链接\n'
    printf ' 7) 解析域名        8) 使用帮助\n'
    printf ' 0) 退出\n'
    printf '%s\n' "--------------------------------------------------"
    ask c "请选择" ""
    case "$c" in
      1) menu_nodes ;;
      2) menu_outbounds ;;
      3) menu_routes ;;
      4) menu_runtime ;;
      5) menu_core ;;
      6) show_all_links ;;
      7) menu_domain ;;
      8) menu_help ;;
      0)
        info "已退出"
        exit 0
        ;;
      *) warn "无效选项" ;;
    esac
  done
}
