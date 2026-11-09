# ================================================================
#  配置生成
# ================================================================
ensure_dirs() {
  mkdir -p "$SB_DIR" "$NODE_DIR" "$OUT_DIR" "$CERT_DIR" "$LOG_DIR" "$SB_DIR/routes"
  chmod 700 "$CERT_DIR" 2>/dev/null || true
  [ -f "$LOG_FILE" ] || touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  [ -s "$FINAL_FILE" ] || printf 'direct\n' > "$FINAL_FILE"
}

count_nodes() {
  find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

count_outbounds() {
  find "$OUT_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

rebuild_config() {
  local tmp rc=0 final f route_dir tag rf out
  tmp=$(mktemp) || { error "创建临时文件失败"; return 1; }
  jq -n --arg logfile "$LOG_FILE" '{
      log: { level: "info", timestamp: true, output: $logfile },
      inbounds: [],
      outbounds: [ { type: "direct", tag: "direct" } ],
      route: { rules: [], final: "direct", auto_detect_interface: true }
    }' > "$tmp" || { rm -f "$tmp"; error "初始化配置模板失败"; return 1; }

  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    if ! jq --slurpfile inc "$f" '
      .inbounds += (if (($inc|length) == 1 and (($inc[0]|type) == "array"))
                    then $inc[0] else $inc end)
    ' "$tmp" > "$tmp.next"; then
      rc=1; break
    fi
    mv -f "$tmp.next" "$tmp"
  done
  if [ "$rc" -eq 0 ]; then
    for f in "$OUT_DIR"/*.json; do
      if ! jq --slurpfile inc "$f" '
        .outbounds += (if (($inc|length) == 1 and (($inc[0]|type) == "array"))
                       then $inc[0] else $inc end)
      ' "$tmp" > "$tmp.next"; then
        rc=1; break
      fi
      mv -f "$tmp.next" "$tmp"
    done
  fi

  if [ "$rc" -eq 0 ]; then
    route_dir="$SB_DIR/routes"
    if [ -d "$route_dir" ]; then
      for rf in "$route_dir"/*.outbound; do
        [ -e "$rf" ] || continue
        tag=$(basename "$rf" .outbound)
        [ -f "$NODE_DIR/$tag.json" ] || continue
        out=$(head -n1 "$rf" 2>/dev/null || true)
        [ -n "$out" ] || continue
        if jq -e --arg t "$out" '.outbounds[] | select(.tag == $t)' "$tmp" >/dev/null 2>&1; then
          if ! jq --arg in "$tag" --arg out "$out" \
            '.route.rules += [{inbound: [$in], outbound: $out}]' "$tmp" > "$tmp.next"; then
            rc=1
            break
          fi
          mv -f "$tmp.next" "$tmp"
        else
          warn "节点 [$tag] 绑定的出站 [$out] 不存在，已忽略"
        fi
      done
    fi
  fi
  shopt -u nullglob

  if [ "$rc" -eq 0 ]; then
    if [ -s "$FINAL_FILE" ]; then
      final=$(head -n1 "$FINAL_FILE")
    else
      final="direct"
    fi
    if ! jq --arg final "$final" '.route.final = $final' "$tmp" > "$tmp.next"; then
      rc=1
    else
      mv -f "$tmp.next" "$tmp"
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mv -f "$tmp" "$CONF"
    chmod 600 "$CONF"
  else
    rm -f "$tmp" "$tmp.next"
    error "生成 config.json 失败，请检查节点/出站文件是否为合法 JSON"
    return 1
  fi
  return 0
}

check_config() {
  local out
  ensure_dirs
  rebuild_config || return 1
  out=$("$BIN" check -c "$CONF" 2>&1) || {
    error "配置校验失败:"
    printf '%s\n' "$out" >&2
    return 1
  }
  return 0
}

