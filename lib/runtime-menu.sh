# ================================================================
#  运行管理
# ================================================================
menu_runtime() {
  local c
  while true; do
    printf '\n%s\n' "------------- 运行管理 -------------"
    printf ' 1) 启动核心\n'
    printf ' 2) 停止核心\n'
    printf ' 3) 重启核心\n'
    printf ' 4) 查看日志\n'
    printf ' 5) 查看运行状态\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) start_core; pause ;;
      2) stop_core; pause ;;
      3) restart_core; pause ;;
      4) show_logs ;;
      5) show_status; pause ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

