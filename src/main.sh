usage() {
  cat <<'HELP'
sing-box 部署与节点管理
bash sing-box.sh                     交互菜单；q 取消，EOF 退出
bash sing-box.sh deps                安装发行版依赖（明确确认）
bash sing-box.sh install             官方固定稳定核心安装/更新
bash sing-box.sh status|resources|logs|refresh-network
bash sing-box.sh start|stop|restart|run-core
bash sing-box.sh list|outbounds|links [节点名|all]
bash sing-box.sh certificate 节点名   导出公开证书（不输出私钥）
bash sing-box.sh client-config 节点名 导出完整客户端 JSON（含认证信息、自签证书信任）
bash sing-box.sh check               校验当前配置
bash sing-box.sh check-private       私密终端检查当前配置
bash sing-box.sh check-private failed|clear  查看 / 清除最近一次失败诊断
bash sing-box.sh node-import 文件    批量导入节点对象数组
bash sing-box.sh outbound-import 文件
bash sing-box.sh link-import 名称    从标准输入读取一条分享链接
bash sing-box.sh bind 出口 节点...   direct 恢复直连；all 选择全部
bash sing-box.sh detour 出站 出口   修改出站链路（循环会拒绝）
bash sing-box.sh delete-node|delete-outbound 名称  需要明确确认
bash sing-box.sh domain 域名|-       DDNS 分享地址；- 清除
bash sing-box.sh uninstall keep|purge
bash sing-box.sh unlock              确认无管理进程后解除中断遗留锁
bash sing-box.sh recover             恢复中断的配置/核心事务

推荐 VLESS REALITY/Vision、VLESS WS TLS、Hysteria 2。
CDN 首版向导面向 Cloudflare：DNS 橙云、WebSocket、Full(strict)，
公网 HTTPS 端口 443/2053/2083/2087/2096/8443，另核对源站 NAT/防火墙。
源站证书仅供对应 CDN 信任；自签证书须在客户端导入信任，链接不跳过验证。
SOCKS5 有认证但没有传输加密；监听公网地址时注意网络可达范围。
默认不持续写核心流量日志；logs 查看有上限的管理日志。
故障排查：check-private；停止服务后可用 debug 在终端观察前台核心。
保存、check、启动、外网连通是不同状态；本工具不宣称自动验证外网。
HELP
}
show_logs() {
  local file
  for file in "$SB_ROOT/events.log.1" "$SB_ROOT/events.log"; do [[ ! -f $file ]] || tail -n 100 "$file"; done
  say '核心流量日志默认关闭，避免无上限写盘。使用 check-private 或前台 debug 排查。'
}
unlock() {
  local pid
  [[ -d $SB_ROOT/lock ]] || return 0
  if [[ -r $SB_ROOT/lock/pid ]]; then
    read -r pid < "$SB_ROOT/lock/pid"
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then err '锁中的 PID 仍存活，拒绝解除。'; return 1; fi
  fi
  confirm '确认没有其他管理进程，删除遗留锁' || return 130
  rm -f "$SB_ROOT/lock/pid" && rmdir "$SB_ROOT/lock"
}
main() {
  local command=${1:-menu} file link rc=0 out
  shift || true
  [[ ${BASH_VERSINFO[0]} -ge 4 ]] || { err '需要 Bash 4 或更高版本。'; return 1; }
  case "$command" in help|-h|--help) usage; return 0;; esac
  if [[ $command == menu && ! -t 0 ]]; then
    if ! { exec 0</dev/tty; } 2>/dev/null; then
      err '菜单需要交互终端；自动化请使用明确的子命令。'; return 1
    fi
  fi
  if [[ $SB_ROOT == /etc/sb-manager && $(id -u) != 0 ]]; then err '管理系统部署需要 root。'; return 1; fi
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  case "$command" in
    deps) install_dependencies; return $?;; run-core) run_core; return $?;;
    menu) interactive_menu; return $?;;
    logs) show_logs; return $?;;
    stop) lock_acquire && service_stop; return $?;;
    check-private)
      case "${1:-current}" in
        failed)
          [[ -f $SB_ROOT/last-check-error.log ]] || { err '没有已保存的失败诊断。'; return 1; }
          say '最近一次核心检查失败的诊断（可能含认证信息；不代表当前配置状态）：'
          cat "$SB_ROOT/last-check-error.log"; return $?;;
        clear) rm -f "$SB_ROOT/last-check-error.log"; return $?;;
        current) ;;
        *) err '用法：check-private [current|failed|clear]'; return 1;;
      esac;;
  esac
  dependencies || return 1
  case "$command" in
    install) install_core;; status) show_status;; resources) resources;; refresh-network) refresh_network;;
    list) list_nodes;; outbounds) list_outbounds;; links) show_links "${1:-all}";; certificate) export_certificate "${1:-}";;
    client-config) client_config "${1:-}";;
    start) lock_acquire && service_start;; restart) lock_acquire && service_restart;;
    check|check-private)
      file=$(current_generation) || return 1
      if [[ $command == check ]]; then check_core "$file/config.json"
      else "$SB_BIN" check -c "$file/config.json"; fi;;
    node-import) root_guard && mutate import_nodes "${1:-}";;
    outbound-import) root_guard && mutate put_outbound "${1:-}";;
    link-import)
      valid_id "${1:-}" || return 1
      IFS= read -r link || return 130
      root_guard && txn_begin && link_parse "$link" "$1" > "$SB_TXN/import.json" && put_outbound "$SB_TXN/import.json" && rm -f "$SB_TXN/import.json" && txn_commit;;
    bind) out=${1:-}; shift || return 1; mutate bind_nodes "$out" "$@";;
    detour) mutate set_detour "${1:-}" "${2:-}";;
    domain) local d=${1:-}; [[ $d != - ]] || d=''; mutate set_domain "$d";;
    delete-node) confirm "删除节点 ${1:-}" && mutate delete_resource node "${1:-}";;
    delete-outbound) confirm "删除出口 ${1:-}，引用节点恢复直连" && mutate delete_resource outbound "${1:-}";;
    uninstall) uninstall_core "${1:-keep}";; unlock) unlock;; recover) recover;;
    debug)
      lock_acquire || return 1
      service_running && { err '请先停止服务再前台诊断。'; return 1; }
      file=$(current_generation) || return 1
      jq '.log={level:"info",timestamp:true}' "$file/config.json" > "$SB_ROOT/debug.json" || return 1
      "$SB_BIN" run -c "$SB_ROOT/debug.json"; rc=$?; rm -f "$SB_ROOT/debug.json"; return "$rc";;
    *) err '未知命令；使用 help 查看用法。'; return 1;;
  esac
}
