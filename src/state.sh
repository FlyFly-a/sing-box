root_guard() {
  [[ $SB_ROOT == /* && $SB_ROOT != / && $SB_ROOT != /etc && $SB_ROOT != *$'\n'* ]] || { err '数据目录必须是独立绝对路径。'; return 1; }
}
lock_acquire() {
  mkdir -p "$SB_ROOT" || return 1
  chmod 700 "$SB_ROOT" || return 1
  if ! mkdir "$SB_ROOT/lock" 2>/dev/null; then err '另一操作或中断留下的锁存在。确认无管理进程后执行 unlock。'; return 1; fi
  SB_LOCKED=1
  printf '%s\n' "$$" > "$SB_ROOT/lock/pid"
}
lock_release() {
  if [[ $SB_LOCKED == 1 ]]; then rm -f "$SB_ROOT/lock/pid"; rmdir "$SB_ROOT/lock"; SB_LOCKED=0; fi
}
current_generation() {
  local generation
  [[ -f $SB_ROOT/current ]] || return 1
  IFS= read -r generation < "$SB_ROOT/current" || return 1
  [[ $generation =~ ^g\.[A-Za-z0-9]+$ && -d $SB_ROOT/generations/$generation ]] || return 1
  printf '%s' "$SB_ROOT/generations/$generation"
}
state_file() { local d; d=$(current_generation) || return 1; printf '%s/state.json' "$d"; }
empty_state() { printf '%s\n' '{"nodes":[],"outbounds":[],"defaults":{"domain":""}}'; }
txn_begin() {
  root_guard || return 1
  lock_acquire || return 1
  mkdir -p "$SB_ROOT/generations" || { lock_release; return 1; }
  if [[ -e $SB_ROOT/pending || -e $SB_BIN.old ]]; then
    err '存在中断的配置或核心事务；先执行 recover 恢复。'; lock_release; return 1
  fi
  SB_OLD=$(current_generation) || SB_OLD=''
  if [[ -e $SB_ROOT/current && -z $SB_OLD ]]; then err 'current 指针损坏；拒绝初始化覆盖，请恢复备份。'; lock_release; return 1; fi
  SB_TXN=$(mktemp -d "$SB_ROOT/generations/g.XXXXXXXX") || { lock_release; return 1; }
  if [[ -n $SB_OLD ]]; then cp "$SB_OLD/state.json" "$SB_TXN/state.json" || return 1
  else empty_state > "$SB_TXN/state.json"; fi
}
point_to() {
  printf '%s\n' "${1##*/}" > "$SB_ROOT/current.next" && mv -f "$SB_ROOT/current.next" "$SB_ROOT/current"
}
txn_abort() {
  if [[ $SB_SWITCHED == 1 ]]; then
    if [[ -n $SB_OLD ]]; then point_to "$SB_OLD" || return 1; else rm -f "$SB_ROOT/current"; fi
    SB_SWITCHED=0
    if [[ $SB_WAS_RUNNING == 1 ]]; then service_restart || { err '旧配置已恢复，但服务恢复失败，请检查端口与资源。'; return 1; }; fi
  fi
  if [[ $SB_LOCKED == 1 && -n $SB_TXN ]]; then rm -f "$SB_ROOT/pending" "$SB_ROOT/current.next"; fi
  if [[ -n $SB_TXN && $SB_TXN == "$SB_ROOT"/generations/g.* ]]; then rm -rf -- "$SB_TXN"; fi
  SB_TXN=''; SB_OLD=''; SB_WAS_RUNNING=0
  lock_release
}
cleanup() {
  # Remove private debug material while this process still owns the lock.
  if [[ $SB_LOCKED == 1 ]]; then rm -f "$SB_ROOT/debug.json"; fi
  if [[ $SB_CORE_PENDING == 1 ]]; then core_rollback || true; fi
  txn_abort || true
  if [[ -n $SB_INSTALL_TMP && $SB_INSTALL_TMP == "$SB_ROOT"/bin/.install.* ]]; then rm -rf -- "$SB_INSTALL_TMP"; fi
  SB_INSTALL_TMP=''
}
txn_commit() {
  local old=$SB_OLD candidate=$SB_TXN g
  validate_state "$candidate/state.json" && validate_node_certificates "$candidate/state.json" && render_config "$candidate/state.json" "$candidate/config.json" && check_core "$candidate/config.json" || { txn_abort; return 1; }
  chmod 600 "$candidate/state.json" "$candidate/config.json" || { txn_abort; return 1; }
  SB_WAS_RUNNING=0
  service_running && SB_WAS_RUNNING=1
  printf '%s\n' "${old##*/}" > "$SB_ROOT/pending" || { txn_abort; return 1; }
  SB_SWITCHED=1
  point_to "$candidate" || { txn_abort; return 1; }
  if [[ $SB_WAS_RUNNING == 1 ]] && ! service_restart; then
    err '服务应用失败，正在恢复上一代。'; txn_abort; return 1
  fi
  if [[ -n $old ]]; then printf '%s\n' "${old##*/}" > "$SB_ROOT/previous"; fi
  rm -f "$SB_ROOT/pending" || return 1
  SB_SWITCHED=0; SB_TXN=''; SB_OLD=''
  for g in "$SB_ROOT"/generations/g.*; do
    [[ -d $g && $g != "$candidate" && $g != "$old" ]] || continue
    rm -rf -- "$g"
  done
  event 'configuration committed; core check passed'
  say '配置已保存；官方核心校验通过。'
  if [[ $SB_WAS_RUNNING == 1 ]]; then say '服务已重新启动；外网连通未验证。'; else say '服务未启动；外网连通未验证。'; fi
  SB_WAS_RUNNING=0
  lock_release
}
recover() {
  local prior running=0
  confirm '恢复中断事务到先前配置/核心；当前服务将重启' || return 130
  lock_acquire || return 1
  service_running && running=1
  service_stop || return 1
  if [[ -f $SB_ROOT/pending ]]; then
    IFS= read -r prior < "$SB_ROOT/pending" || prior=''
    if [[ -n $prior ]]; then
      [[ $prior =~ ^g\.[A-Za-z0-9]+$ && -f $SB_ROOT/generations/$prior/config.json ]] || { err '恢复指针非法；保留所有文件，请人工检查。'; return 1; }
      point_to "$SB_ROOT/generations/$prior" || return 1
    else rm -f "$SB_ROOT/current"; fi
    rm -f "$SB_ROOT/pending"
  fi
  if [[ -f $SB_BIN.old ]]; then mv -f "$SB_BIN.old" "$SB_BIN" || return 1; fi
  if [[ $running == 1 ]]; then service_start || return 1; fi
  event 'interrupted transaction recovered'
  lock_release
}
state_change() {
  local filter=$1; shift
  jq "$@" "$filter" "$SB_TXN/state.json" > "$SB_TXN/next.json" && mv -f "$SB_TXN/next.json" "$SB_TXN/state.json"
}
