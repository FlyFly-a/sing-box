service_backend() {
  if [[ $SB_ROOT != /etc/sb-manager ]]; then printf process; return 0; fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then printf systemd
  elif command -v rc-service >/dev/null 2>&1 && [[ -d /run/openrc ]]; then printf openrc
  else printf process; fi
}
service_ownership() {
  local file
  [[ $SB_ROOT == /etc/sb-manager ]] || return 0
  for file in /etc/systemd/system/sb-manager.service /etc/init.d/sb-manager; do
    [[ ! -e $file ]] || grep -q '^# sb-manager-owned$' "$file" || return 1
  done
}
process_start_time() {
  local pid=$1 value
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  # The process can exit between checking /proc and opening stat. Treat that as
  # no longer running, without printing a spurious error during normal shutdown.
  # comm is parenthesized and may contain spaces or parentheses; strip it first.
  value=$(awk '{sub(/^.*\) /, ""); print $20}' "$SB_PROC/$pid/stat" 2>/dev/null) || return 1
  [[ $value =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$value"
}
pid_owned() {
  local pid token actual executable
  [[ -r $SB_ROOT/run.pid && -r $SB_ROOT/run.start ]] || return 1
  read -r pid < "$SB_ROOT/run.pid"; read -r token < "$SB_ROOT/run.start"
  [[ $pid =~ ^[0-9]+$ && -r $SB_PROC/$pid/stat && -e $SB_PROC/$pid/exe ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  actual=$(process_start_time "$pid") || return 1
  [[ $actual == "$token" ]] || return 1
  executable=$(readlink "$SB_PROC/$pid/exe" 2>/dev/null) || return 1
  [[ $executable == "$SB_BIN" ]]
}
service_running() {
  service_ownership || return 1
  case "$(service_backend)" in
    systemd) systemctl is-active --quiet sb-manager 2>/dev/null;;
    openrc) rc-service sb-manager status >/dev/null 2>&1;;
    process) pid_owned;;
  esac
}
run_core() {
  local generation
  generation=$(current_generation) || { err '尚无已校验配置。'; return 1; }
  exec "$SB_BIN" run -c "$generation/config.json"
}
service_start() {
  local generation pid
  service_ownership || { err 'sb-manager 服务名称已被非托管服务占用，拒绝操作。'; return 1; }
  service_running && return 0
  generation=$(current_generation) || return 1
  check_core "$generation/config.json" || return 1
  case "$(service_backend)" in
    systemd) systemctl start sb-manager || return 1;;
    openrc) rc-service sb-manager start || return 1;;
    process)
      [[ -d $SB_PROC/self ]] || { err '后台运行需要 Linux /proc；当前环境仅可进行配置校验。'; return 1; }
      nohup "$SB_BIN" run -c "$generation/config.json" </dev/null >/dev/null 2>&1 &
      pid=$!
      printf '%s\n' "$pid" > "$SB_ROOT/run.pid"
      process_start_time "$pid" > "$SB_ROOT/run.start" || return 1
      say '当前使用后台模式；容器重启后需手动启动或由宿主机 init 调用。';;
  esac
  sleep 1
  service_running || { err '服务没有保持运行；检查监听端口、证书和可用内存。'; return 1; }
  event 'service started (external connectivity not verified)'
}
service_stop() {
  local pid i
  service_ownership || { err '拒绝停止非托管同名服务。'; return 1; }
  case "$(service_backend)" in
    systemd) systemctl stop sb-manager || return 1;;
    openrc) rc-service sb-manager stop || return 1;;
    process)
      if pid_owned; then
        read -r pid < "$SB_ROOT/run.pid"
        kill "$pid" || return 1
        for ((i=0;i<30;i++)); do pid_owned || break; sleep 0.1; done
        if pid_owned; then err '核心未退出，保留 PID 信息；请检查，不强制杀死未知进程。'; return 1; fi
      fi
      rm -f "$SB_ROOT/run.pid" "$SB_ROOT/run.start";;
  esac
  event 'service stopped'
}
service_restart() { service_stop && service_start; }
service_register() {
  # System services use a fixed, separately owned location; custom roots are for tests/foreground use.
  [[ $SB_ROOT == /etc/sb-manager && $SB_BIN == /etc/sb-manager/bin/sing-box ]] || { say '自定义目录：不注册系统服务，可前台运行。'; return 0; }
  local file
  case "$(service_backend)" in
    systemd)
      file=/etc/systemd/system/sb-manager.service
      if [[ -e $file ]] && ! grep -q '^# sb-manager-owned$' "$file"; then err '服务文件已被其他安装占用。'; return 1; fi
      cat > "$file" <<'UNIT'
# sb-manager-owned
[Unit]
Description=sing-box managed by sb-manager
After=network.target
ConditionPathExists=/etc/sb-manager/current
[Service]
Type=simple
ExecStart=/bin/bash /etc/sb-manager/manager.sh run-core
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
UNIT
      chmod 644 "$file" && systemctl daemon-reload && systemctl enable sb-manager || return 1;;
    openrc)
      file=/etc/init.d/sb-manager
      if [[ -e $file ]] && ! grep -q '^# sb-manager-owned$' "$file"; then err '服务文件已被其他安装占用。'; return 1; fi
      cat > "$file" <<'UNIT'
#!/sbin/openrc-run
# sb-manager-owned
name="sb-manager"
command="/bin/bash"
command_args="/etc/sb-manager/manager.sh run-core"
command_background="yes"
pidfile="/run/sb-manager.pid"
output_log="/dev/null"
error_log="/dev/null"
start_pre() { test -f /etc/sb-manager/current; }
depend() { need net; }
UNIT
      chmod 755 "$file" && rc-update add sb-manager default || return 1;;
    *) say '无 systemd/OpenRC：不伪造开机自启；请配置宿主机启动钩子。';;
  esac
}
service_unregister() {
  local f
  [[ $SB_ROOT == /etc/sb-manager ]] || return 0
  for f in /etc/systemd/system/sb-manager.service /etc/init.d/sb-manager; do
    [[ -f $f ]] || continue
    grep -q '^# sb-manager-owned$' "$f" || return 1
    if [[ $f == *.service ]]; then systemctl disable sb-manager || return 1
    else rc-update del sb-manager default || return 1; fi
    rm -f "$f" || return 1
  done
  [[ $(service_backend) != systemd ]] || systemctl daemon-reload
}
show_status() {
  [[ ! -x $SB_BIN ]] || "$SB_BIN" version
  if service_running; then say '服务：运行中（未验证外网连通）'; else say '服务：未运行'; fi
  local file
  if file=$(state_file); then jq -r '"节点 \(.nodes|length)，出站 \(.outbounds|length)"' "$file"; else say '尚无配置。'; fi
}
