# ================================================================
#  VLESS 系列
# ================================================================

# VLESS + TCP + Vision + REALITY
create_vless_reality() {
  local tag port uuid sni sid rport priv pub kp json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    uuid=$(node_get "$tag" '.users[0].uuid')
    sni=$(node_get "$tag" '.tls.server_name')
    sid=$(node_get "$tag" '.tls.reality.short_id[0]')
    rport=$(node_get "$tag" '.tls.reality.handshake.server_port' 443)
    priv=$(node_get "$tag" '.tls.reality.private_key')
    pub=$(meta_get "$tag" pbk)
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "reality-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    uuid=""
    sni=""
    sid=""
    rport=""
    priv=""
    pub=""
  fi

  [ -n "$uuid" ] || uuid=$(gen_uuid)
  [ -n "$sid" ] || sid=$(gen_hex 4)

  if [ -z "$priv" ] || [ -z "$pub" ]; then
    info "正在生成 REALITY 密钥对 ..."
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
    [ -n "$priv" ] && [ -n "$pub" ] || { error "REALITY 密钥对生成失败"; return 1; }
  fi

  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;        sni=$WIZ_SNI
  WIZ_REALITY_PORT=$rport; ask_reality_port; rport=$WIZ_REALITY_PORT
  WIZ_TAG=$tag

  if [ -n "${WIZ_EDIT_TAG:-}" ] && confirm "是否重新生成 REALITY 密钥对?" "n"; then
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
    [ -n "$priv" ] && [ -n "$pub" ] || { error "REALITY 密钥对生成失败"; return 1; }
  fi

  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" \
    --argjson rport "$rport" '
    {type:"vless",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",uuid:$uuid,flow:"xtls-rprx-vision"}],
     tls:{enabled:true,server_name:$sni,
          reality:{enabled:true,handshake:{server:$sni,server_port:$rport},
                   private_key:$priv,short_id:[$sid]}}}')
  save_node "$tag" "vless-reality-vision" "$json" "$pub" 0
}

# VLESS + WebSocket + TLS
create_vless_ws() {
  local tag port uuid sni path tls transport json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    uuid=$(node_get "$tag" '.users[0].uuid')
    sni=$(node_get "$tag" '.tls.server_name')
    path=$(node_get "$tag" '.transport.path')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-ws-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    uuid=""
    sni=""
    path=""
  fi

  [ -n "$uuid" ] || uuid=$(gen_uuid)
  WIZ_PORT=$port; ask_port tcp;  port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;        sni=$WIZ_SNI
  WIZ_TAG=$tag

  [ -n "$path" ] || path="/$(gen_hex 6)"
  tls=$(tls_cert_json "$sni" h2 http/1.1) || return 1
  transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vless",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vless-ws" "$json" "" 1
}
