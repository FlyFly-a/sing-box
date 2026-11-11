# ================================================================
#  运行管理: 启动 / 停止 / 重启 / 状态 / 日志 / 菜单
# ================================================================

pid_is_singbox() {
  local pid=${1:-} comm=''
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/comm" ]; then
    IFS= read -r comm < "/proc/$pid/comm" || true
    [ "$comm" = "sing-box" ]
    return $?
  fi
  command -v ps >/dev/null 2>&1 || return 1
  comm=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ' || true)
  [ "$comm" = "sing-box" ]
}

core_running() {
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl is-active --quiet sing-box 2>/dev/null && return 0
  fi
  if has_openrc && [ -f "$OPENRC_FILE" ]; then
    rc-service sing-box status >/dev/null 2>&1 && return 0
  fi
  if [ -f "$PID_FILE" ]; then
    pid_is_singbox "$(cat "$PID_FILE" 2>/dev/null || true)" && return 0
  fi
  return 1
}

start_core() {
  [ -x "$BIN" ] || { error "未安装 sing-box 核心，请先安装"; return 1; }
  if core_running; then
    info "sing-box 已在运行"
    return 0
  fi
  ensure_dirs
  check_config || return 1

  if has_systemd; then
    [ -f "$SERVICE_FILE" ] || write_service
    systemctl daemon-reload 2>/dev/null || true
    systemctl start sing-box 2>/dev/null || true
    sleep 1
    if core_running; then
      info "sing-box 已启动"
      return 0
    fi
    error "启动失败，最近日志:"
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
    return 1
  fi

  if has_openrc; then
    [ -f "$OPENRC_FILE" ] || write_service
    rc-service sing-box start >/dev/null 2>&1 || true
    sleep 1
    if core_running; then
      info "sing-box 已启动 (OpenRC)"
      return 0
    fi
    error "启动失败，最近日志:"
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
    return 1
  fi

  nohup "$BIN" run -c "$CONF" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    info "sing-box 已启动 (PID $pid)"
    return 0
  fi
  error "启动失败，请查看日志: $LOG_FILE"
  rm -f "$PID_FILE"
  return 1
}

stop_core() {
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl stop sing-box 2>/dev/null || true
  fi
  if has_openrc && [ -f "$OPENRC_FILE" ]; then
    rc-service sing-box stop >/dev/null 2>&1 || true
  fi
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if pid_is_singbox "$pid"; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  info "sing-box 已停止"
}

restart_core() {
  [ -x "$BIN" ] || { error "未安装 sing-box 核心"; return 1; }
  check_config || return 1

  if has_systemd; then
    [ -f "$SERVICE_FILE" ] || write_service
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart sing-box 2>/dev/null || true
    sleep 1
    core_running && { info "sing-box 已重启"; return 0; }
    error "重启失败，最近日志:"
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
    return 1
  fi

  if has_openrc; then
    [ -f "$OPENRC_FILE" ] || write_service
    rc-service sing-box restart >/dev/null 2>&1 || true
    sleep 1
    core_running && { info "sing-box 已重启 (OpenRC)"; return 0; }
    error "重启失败，最近日志:"
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
    return 1
  fi

  stop_core >/dev/null 2>&1 || true
  start_core
}

# 配置变更后应用: 校验 + 按需重启
apply_changes() {
  if [ -x "$BIN" ]; then
    check_config || return 1
  else
    rebuild_config || return 1
  fi
  if [ -x "$BIN" ]; then
    if core_running; then
      if confirm "配置已更新，是否重启核心使其生效?"; then
        restart_core || return 1
      else
        warn "未重启，新配置尚未生效"
      fi
    else
      if confirm "核心当前未运行，是否立即启动?" "n"; then
        start_core || return 1
      fi
    fi
  fi
  return 0
}

show_status() {
  local ver
  ver=$(singbox_version)
  printf '%s\n' "-------------- 运行状态 --------------"
  printf '核心版本 : %s\n' "${ver:-未安装}"
  if core_running; then
    printf '运行状态 : %s运行中%s\n' "$C_GRN" "$C_RESET"
  else
    printf '运行状态 : %s已停止%s\n' "$C_RED" "$C_RESET"
  fi
  printf '节点数量 : %s\n' "$(count_nodes)"
  printf '出站数量 : %s\n' "$(count_outbounds)"
  load_server_ip4
  load_server_ip6
  printf '公网 IPv4 : %s\n' "${SERVER_IP4:-无}"
  printf '公网 IPv6 : %s\n' "${SERVER_IP6:-无}"
  printf '监听地址 : %s%s\n' "$NODE_LISTEN" \
    "$([ "$NODE_LISTEN" = "::" ] && [ "$IPV6_V6ONLY" = "1" ] && printf ' (bindv6only=1，节点会附加 IPv4 入站)')"
  printf '配置文件 : %s\n' "$CONF"
  printf '日志文件 : %s\n' "$LOG_FILE"
  printf '%s\n' "--------------------------------------"
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl status sing-box --no-pager -l 2>/dev/null | head -n 25 || true
  elif has_openrc && [ -f "$OPENRC_FILE" ]; then
    rc-service sing-box status 2>/dev/null || true
  elif [ -f "$PID_FILE" ]; then
    printf '后台进程 PID: %s\n' "$(cat "$PID_FILE" 2>/dev/null || true)"
  fi
  if command -v ss >/dev/null 2>&1; then
    printf '\n监听端口:\n'
    ss -lntup 2>/dev/null | awk 'NR==1 || /sing-box/' || true
  fi
}

show_logs() {
  local c
  printf '1) 最近 100 行日志\n2) 实时跟踪日志 (Ctrl+C 返回)\n3) systemd 日志 (仅 systemd)\n0) 返回\n'
  ask c "请选择" "1"
  case "$c" in
    1)
      if [ -s "$LOG_FILE" ]; then
        tail -n 100 "$LOG_FILE"
      elif has_systemd; then
        warn "暂无日志文件，读取 systemd 日志"
        journalctl -u sing-box -n 100 --no-pager 2>/dev/null || true
      else
        warn "暂无日志文件"
      fi
      pause
      ;;
    2)
      [ -f "$LOG_FILE" ] || { warn "暂无日志文件"; return 0; }
      info "实时跟踪日志 (Ctrl+C 返回菜单)"
      trap ':' INT
      tail -f "$LOG_FILE" || true
      trap - INT
      ;;
    3)
      if has_systemd; then
        info "实时查看 systemd 日志 (Ctrl+C 返回菜单)"
        trap ':' INT
        journalctl -u sing-box -f --no-pager 2>/dev/null || true
        trap - INT
      else
        warn "当前系统不是 systemd，请使用第 2 项"
        pause
      fi
      ;;
    0|*) ;;
  esac
}

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
