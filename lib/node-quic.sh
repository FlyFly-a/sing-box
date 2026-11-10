# ================================================================
#  Hysteria2 / TUIC (QUIC)
# ================================================================

# Hysteria2
create_hysteria2() {
  local tag port password sni tls json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "hy2-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    password=""
    sni=""
  fi

  [ -n "$password" ] || password=$(gen_hex 16)
  WIZ_PORT=$port; ask_port udp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  tls=$(tls_cert_json "$sni" h3) || return 1
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  # 自签证书固定 insecure=1，见 ensure_cert 的说明
  save_node "$tag" "hysteria2" "$json" "" 1
}

# TUIC
# congestion_control 交由核心默认值处理(官方默认 cubic，仅影响服务端发送方向)
create_tuic() {
  local tag port uuid password sni tls json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    uuid=$(node_get "$tag" '.users[0].uuid')
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "tuic-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    uuid=""
    password=""
    sni=""
  fi

  [ -n "$uuid" ] || uuid=$(gen_uuid)
  [ -n "$password" ] || password=$(gen_hex 16)
  WIZ_PORT=$port; ask_port udp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  tls=$(tls_cert_json "$sni" h3) || return 1
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" '
    {type:"tuic",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",uuid:$uuid,password:$password}],tls:$tls}')
  save_node "$tag" "tuic" "$json" "" 1
}
