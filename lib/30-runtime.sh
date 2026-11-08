# ================================================================
#  运行管理
# ================================================================
core_running() {
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl is-active --quiet sing-box 2>/dev/null && return 0
    return 1
  fi
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

start_core() {
  [ -x "$BIN" ] || { error "未安装 sing-box 核心，请先安装"; return 1; }
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
  else
    nohup "$BIN" run -c "$CONF" >>"$LOG_FILE" 2>&1 &
    local pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      info "sing-box 已启动 (PID $pid)"
      return 0
    fi
    error "启动失败，请查看日志文件: $LOG_FILE"
    rm -f "$PID_FILE"
    return 1
  fi
}

stop_core() {
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl stop sing-box 2>/dev/null || true
  fi
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
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
    if core_running; then
      info "sing-box 已重启"
      return 0
    fi
    error "重启失败，最近日志:"
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
    return 1
  else
    stop_core >/dev/null 2>&1 || true
    start_core
  fi
}

apply_changes() {
  rebuild_config || return 1
  if core_running; then
    if confirm "配置已更新，是否重启核心使其生效?"; then
      restart_core
    else
      warn "未重启，新配置尚未生效"
    fi
  else
    if confirm "核心当前未运行，是否立即启动?" "n"; then
      start_core
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
  printf '出站数量 : %s (默认: %s)\n' "$(count_outbounds)" "$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)"
  printf '配置文件 : %s\n' "$CONF"
  printf '日志文件 : %s\n' "$LOG_FILE"
  printf '%s\n' "--------------------------------------"
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl status sing-box --no-pager -l 2>/dev/null | head -n 25 || true
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
  printf '1) 最近 100 行日志\n2) 实时跟踪日志 (Ctrl+C 返回)\n3) systemd 日志\n0) 返回\n'
  ask c "请选择" "1"
  case "$c" in
    1)
      if [ -s "$LOG_FILE" ]; then
        tail -n 100 "$LOG_FILE"
      else
        warn "暂无日志，尝试读取 systemd 日志"
        journalctl -u sing-box -n 100 --no-pager 2>/dev/null || true
      fi
      pause
      ;;
    2)
      if [ ! -f "$LOG_FILE" ]; then
        warn "暂无日志文件"
        return 0
      fi
      info "实时跟踪日志 (Ctrl+C 返回菜单)"
      trap ':' INT
      tail -f "$LOG_FILE" || true
      trap - INT
      ;;
    3)
      info "实时查看 systemd 日志 (Ctrl+C 返回菜单)"
      trap ':' INT
      journalctl -u sing-box -f --no-pager 2>/dev/null || true
      trap - INT
      ;;
    0|*)
      ;;
  esac
}

