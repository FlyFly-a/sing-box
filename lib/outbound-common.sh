# ================================================================
#  出站管理
# ================================================================
outbound_type_display() {
  case "${1:-}" in
    direct)      printf '直连' ;;
    socks)       printf 'SOCKS5' ;;
    http)        printf 'HTTP' ;;
    shadowsocks) printf 'Shadowsocks' ;;
    vmess)       printf 'VMess' ;;
    vless)       printf 'VLESS' ;;
    trojan)      printf 'Trojan' ;;
    hysteria2)   printf 'Hysteria2' ;;
    tuic)        printf 'TUIC' ;;
    snell)       printf 'Snell' ;;
    *)           printf '%s' "${1:-未知}" ;;
  esac
}

prompt_out_tag() {
  local def=$1 v
  while true; do
    ask v "出站名称" "$def"
    if ! [[ $v =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "仅支持字母、数字、点、下划线、短横线"
      continue
    fi
    if [ "$v" = "direct" ]; then
      warn "direct 是保留名称"
      continue
    fi
    if [ -e "$NODE_DIR/$v.json" ]; then
      warn "该名称与节点名称冲突"
      continue
    fi
    if [ -e "$OUT_DIR/$v.json" ]; then
      warn "出站 $v 已存在"
      continue
    fi
    OUT_TAG=$v
    return 0
  done
}

prompt_server() {
  local def=${1:-} s
  while true; do
    ask s "服务器地址 (IP/域名)" "$def"
    if [ -z "$s" ]; then
      warn "服务器地址不能为空"
      continue
    fi
    SERVER_VAL=$s
    return 0
  done
}

ask_rport() {
  local def=${1:-443} v
  while true; do
    ask v "服务器端口" "$def"
    if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ]; then
      RPORT=$((10#$v))
      return 0
    fi
    warn "服务器端口范围 1-65535"
  done
}

client_tls_json() {
  local sni=$1 insecure=$2 pub=${3:-} sid=${4:-} bool="false" tls
  [ "$insecure" = "1" ] && bool="true"
  tls=$(jq -n --arg sni "$sni" --argjson insecure "$bool" '
    {enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},insecure:$insecure}')
  if [ -n "$pub" ]; then
    tls=$(jq --arg pub "$pub" --arg sid "$sid" '. + {reality:{enabled:true,public_key:$pub,short_id:$sid}}' <<<"$tls")
  fi
  printf '%s' "$tls"
}

ask_out_transport() {
  local c path svc
  printf '  1) TCP\n  2) WebSocket\n  3) gRPC\n'
  ask c "传输方式" "1"
  OUT_PATH=""
  OUT_SVC=""
  case "$c" in
    2)
      ask path "WebSocket 路径" "/ws"
      [[ $path == /* ]] || path="/$path"
      OUT_PATH=$path
      OUT_TRANSPORT_JSON=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
      ;;
    3)
      ask svc "gRPC 服务名" "grpc"
      OUT_SVC=$svc
      OUT_TRANSPORT_JSON=$(jq -n --arg s "$svc" '{type:"grpc",service_name:$s}')
      ;;
    *)
      OUT_TRANSPORT_JSON=""
      ;;
  esac
}

save_outbound() {
  local tag=$1 json=$2
  if ! printf '%s\n' "$json" | jq . > "$OUT_DIR/$tag.json"; then
    error "出站配置写入失败"
    return 1
  fi
  chmod 600 "$OUT_DIR/$tag.json"
  info "出站 [$tag] 已保存"
  return 0
}

finish_outbound() {
  local tag=$1 final
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  if [ "$final" != "$tag" ]; then
    if confirm "是否将 [$tag] 设为默认出站?" "n"; then
      printf '%s\n' "$tag" > "$FINAL_FILE"
      info "默认出站已设为 [$tag]"
    fi
  fi
  apply_changes
}

