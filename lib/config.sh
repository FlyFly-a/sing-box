# ================================================================
#  配置生成与校验
# ================================================================

ensure_dirs() {
  mkdir -p "$SB_DIR" "$NODE_DIR" "$OUT_DIR" "$ROUTE_DIR" "$CERT_DIR" "$LOG_DIR"
  chmod 700 "$CERT_DIR" 2>/dev/null || true
  [ -f "$LOG_FILE" ] || touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}

count_nodes() {
  find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

count_outbounds() {
  find "$OUT_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# 合并节点/出站/路由为最终 config.json
# route.final 固定 direct: 本机自身流量不绕出口，出口只由节点绑定决定
rebuild_config() {
  local tmp rc=0 f rf tag out inb
  ensure_dirs
  tmp=$(mktemp "$SB_DIR/.config.XXXXXX") || { error "创建临时文件失败"; return 1; }

  jq -n --arg logfile "$LOG_FILE" '{
      log: { level: "info", timestamp: true, output: $logfile },
      inbounds: [],
      outbounds: [ { type: "direct", tag: "direct" } ],
      route: { rules: [], final: "direct", auto_detect_interface: true }
    }' > "$tmp" || { rm -f "$tmp"; error "初始化配置模板失败"; return 1; }

  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    if ! jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' "$f" >/dev/null 2>&1; then
      error "节点文件不是合法的 inbound 对象: $f"
      rc=1
      break
    fi
    if ! jq --slurpfile inc "$f" '
        .inbounds += ($inc | map(del(._meta)))
        | .inbounds += ($inc | map(._meta.extra_inbounds // []) | add // [])
      ' "$tmp" > "$tmp.next"; then
      rc=1
      break
    fi
    mv -f "$tmp.next" "$tmp"
  done
  shopt -u nullglob

  if [ "$rc" -eq 0 ]; then
    shopt -s nullglob
    for f in "$OUT_DIR"/*.json; do
      if ! jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' "$f" >/dev/null 2>&1; then
        error "出站文件不是合法的 outbound 对象: $f"
        rc=1
        break
      fi
      if ! jq --slurpfile inc "$f" '.outbounds += $inc' "$tmp" > "$tmp.next"; then
        rc=1
        break
      fi
      mv -f "$tmp.next" "$tmp"
    done
    shopt -u nullglob
  fi

  if [ "$rc" -eq 0 ]; then
    shopt -s nullglob
    for rf in "$ROUTE_DIR"/*.outbound; do
      tag=$(basename "$rf" .outbound)
      [ -f "$NODE_DIR/$tag.json" ] || continue
      out=$(head -n1 "$rf" 2>/dev/null || true)
      [ -n "$out" ] || continue
      if ! jq -e --arg t "$out" '.outbounds[] | select(.tag == $t)' "$tmp" >/dev/null 2>&1; then
        warn "节点 [$tag] 的出口 [$out] 不存在，已忽略"
        continue
      fi
      inb=$(jq -c --arg t "$tag" '[$t] + (._meta.extra_inbounds // [] | map(.tag))' \
        "$NODE_DIR/$tag.json" 2>/dev/null || true)
      [ -n "$inb" ] || inb=$(jq -cn --arg t "$tag" '[$t]')
      if ! jq --argjson inb "$inb" --arg out "$out" \
        '.route.rules += [{inbound: $inb, outbound: $out}]' "$tmp" > "$tmp.next"; then
        rc=1
        break
      fi
      mv -f "$tmp.next" "$tmp"
    done
    shopt -u nullglob
  fi

  if [ "$rc" -eq 0 ]; then
    if ! jq -e '
        ([.inbounds[].tag] | length) == ([.inbounds[].tag] | unique | length)
        and ([.outbounds[].tag] | length) == ([.outbounds[].tag] | unique | length)
      ' "$tmp" >/dev/null 2>&1; then
      error "存在重复的 inbound/outbound tag，请检查节点或出站名称"
      rc=1
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp" "$tmp.next"
    error "生成 config.json 失败，请检查节点/出站文件是否为合法 JSON"
    return 1
  fi

  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$CONF"; then
    rm -f "$tmp" "$tmp.next"
    error "写入 config.json 失败"
    return 1
  fi
  chmod 600 "$CONF" 2>/dev/null || true
  return 0
}

# 生成并校验; 校验失败回滚到原配置
check_config() {
  local out
  local backup=''
  ensure_dirs
  if [ -s "$CONF" ]; then
    backup=$(mktemp "$SB_DIR/.config.bak.XXXXXX") || backup=''
    if [ -n "$backup" ]; then
      cp -f "$CONF" "$backup" 2>/dev/null || { rm -f "$backup"; backup=''; }
    fi
  fi

  if ! rebuild_config; then
    [ -n "$backup" ] && rm -f "$backup"
    return 1
  fi

  if ! out=$("$BIN" check -c "$CONF" 2>&1); then
    if [ -n "$backup" ]; then
      cp -f "$backup" "$CONF" 2>/dev/null || true
      rm -f "$backup"
    else
      rm -f "$CONF"
    fi
    error "配置校验失败:"
    printf '%s\n' "$out" >&2
    return 1
  fi

  [ -n "$backup" ] && rm -f "$backup"
  return 0
}
