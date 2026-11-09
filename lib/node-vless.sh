# ================================================================
#  VLESS 系列
# ================================================================
create_vless_reality() {
  local edit=${1:-} tag port uuid sni sid hsport priv pub kp json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    sni=$(n_get "$tag" '.tls.server_name' 'www.microsoft.com')
    sid=$(n_get "$tag" '.tls.reality.short_id[0]')
    hsport=$(n_get "$tag" '.tls.reality.handshake.server_port' 443)
    priv=$(n_get "$tag" '.tls.reality.private_key')
    pub=$(meta_get "$tag" pbk)
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-reality-$(gen_hex 2)"
    tag=$TAG_VAL
    port=""
    uuid=$(gen_uuid)
    sni="${BATCH_REALITY_SNI:-www.microsoft.com}"
    sid=$(gen_hex 4)
    hsport="${BATCH_REALITY_HSPORT:-443}"
    info "正在生成 REALITY 密钥对 ..."
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask_uuid "$uuid"
  uuid=$UUID_VAL
  while true; do
    ask sni "REALITY 伪装域名" "$sni"
    if [[ $sni =~ ^[A-Za-z0-9._-]+$ ]]; then
      break
    fi
    warn "伪装域名格式不正确"
  done
  ask hsport "REALITY 回源端口 (伪装站点端口)" "$hsport"
  if ! [[ $hsport =~ ^[0-9]+$ ]] || [ "$hsport" -lt 1 ] || [ "$hsport" -gt 65535 ]; then
    warn "回源端口无效，已使用 443"
    hsport=443
  fi
  hsport=$((10#$hsport))
  [ "$hsport" = "443" ] || warn "非 443 回源端口需要伪装站点在该端口提供 TLS"
  [ -n "$sid" ] || sid=$(gen_hex 4)
  ask_short_id "$sid"
  sid=$SHORT_ID_VAL
  if [ -n "$edit" ] && confirm "是否重新生成 REALITY 密钥对?" "n"; then
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
  fi
  if [ -z "$uuid" ] || [ -z "$sni" ] || [ -z "$sid" ] || [ -z "$priv" ] || [ -z "$pub" ]; then
    error "REALITY 参数不完整，已取消保存"
    return 1
  fi
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" \
    --argjson hsport "$hsport" '
    {type:"vless",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid,flow:"xtls-rprx-vision"}],
     tls:{enabled:true,server_name:$sni,
          reality:{enabled:true,handshake:{server:$sni,server_port:$hsport},
                   private_key:$priv,short_id:[$sid]}}}')
  save_node "$tag" "vless-reality-vision" "$json" "$pub" 0
}

create_vless_ws() {
  local edit=${1:-} tag port uuid domain path tls transport json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    domain=$(n_get "$tag" '.tls.server_name')
    path=$(n_get "$tag" '.transport.path' '/ws')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-ws-$(gen_hex 2)"
    tag=$TAG_VAL
    port=""
    uuid=$(gen_uuid)
    domain=""
    path="/ws-$(gen_hex 2)"
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask_uuid "$uuid"
  uuid=$UUID_VAL
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask path "WebSocket 路径" "$path"
  [[ $path == /* ]] || path="/$path"
  if [ -z "$uuid" ]; then
    error "UUID 不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h2 http/1.1)
  transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vless",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vless-ws-tls" "$json" "" "$CERT_INSECURE"
}
