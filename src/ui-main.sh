interactive_menu() {
  root_guard || return 1
  if ! dependencies; then
    say '首次使用需要先补齐依赖。'
    install_dependencies || return $?
  fi
  if [[ ! -x $SB_BIN ]]; then
    confirm '尚未安装核心，立即安装官方核心' || return 130
    install_core || return $?
  fi
  local initial_state
  initial_state=$(state_file) || initial_state=''
  if [[ -z $initial_state ]] || jq -e '.nodes|length==0' "$initial_state" >/dev/null; then
    say '尚无节点，接下来创建第一个节点；q 可取消并进入菜单。'
    if create_wizard && initial_state=$(state_file) && jq -e '.nodes|length>0' "$initial_state" >/dev/null; then
      if confirm '立即启动服务'; then
        lock_acquire && service_start
      fi
    fi
    cleanup
  fi
  main_menu
}
main_menu() {
  local choice id action
  while :; do
    say ''; say 'sing-box 部署与节点管理'
    say '1 创建节点'; say '2 查看节点和连接信息'; say '3 修改或删除节点'; say '4 设置中转和出口'; say '5 服务状态与故障检查'; say '6 核心与脚本管理'; say '7 使用帮助'; say '0 退出'
    ask choice '请选择' '' || return 0
    case "$choice" in
      1) create_wizard;;
      2)
        list_nodes; say '1 分享单个/全部；2 设置 DDNS 分享域名；3 清除分享域名；4 导出客户端 JSON；0 返回'
        ask action '选择' '' || return 0
        case "$action" in
          1) ask id '节点名称，all 全部' all && show_links "$id";;
          2) ask_valid id 'DDNS 域名（自行维护解析，CDN 节点不受全局域名覆盖）' '' valid_domain && mutate set_domain "$id";;
          3) confirm '清除全局分享域名' && mutate set_domain '';;
          4) ask_valid id '节点名称' '' valid_id && client_config "$id";;
        esac;;
      3)
        list_nodes; ask_valid id '节点名称' '' valid_id || return 0
        ask action '1 修改；2 删除；0 返回' '' || return 0
        case "$action" in
          1) txn_begin && node_wizard '' "$id" && confirm '保存节点修改' && txn_commit;;
          2) confirm "删除节点 $id" && mutate delete_resource node "$id";;
        esac;;
      4) outbound_menu;;
      5)
        show_status
        say '1 启动；2 停止；3 重启；4 日志；5 资源诊断；6 刷新公网缓存；0 返回'
        ask action '选择' '' || return 0
        case "$action" in
          1) lock_acquire && service_start;; 2) lock_acquire && service_stop;; 3) lock_acquire && service_restart;;
          4) show_logs;; 5) resources;; 6) refresh_network;;
        esac;;
      6)
        say '1 安装/更新固定稳定核心；2 卸载保留配置；3 卸载清理配置；4 核心版本；5 安装当前管理脚本；0 返回'
        ask action '选择' '' || return 0
        case "$action" in
          1) install_core;; 2) uninstall_core keep;; 3) uninstall_core purge;;
          4) [[ ! -x $SB_BIN ]] || "$SB_BIN" version;; 5) lock_acquire && save_manager && service_register;;
        esac;;
      7) usage;; 0) return 0;; '') ;; *) say '无效选项。';;
    esac
    cleanup
  done
}
