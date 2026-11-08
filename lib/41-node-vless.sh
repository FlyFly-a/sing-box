# ================================================================
#  VLESS 系列
# ================================================================
create_vless_reality() {
  local edit=${1:-} tag port uuid sni sid priv pub kp json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    sni=$(n_get "$tag" '.tls.server_name' 'www.microsoft.com')
    sid=$(n_get "$tag" '.tls.reality.short_id[0]')
    priv=$(n_get "$tag" '.tls.reality.private_key')
    pub=$(meta_get "$tag" pbk)
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-reality-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    sni="www.microsoft.com"
    sid=$(gen_hex 4)
    info "正在生成 REALITY 密钥对 ..."
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  ask sni "REALITY 伪装域名" "$sni"
  [ -n "$sid" ] || sid=$(gen_hex 4)
  ask sid "Short ID (十六进制)" "$sid"
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
    --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" '
    {type:"vless",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid,flow:"xtls-rprx-vision"}],
     tls:{enabled:true,server_name:$sni,
          reality:{enabled:true,handshake:{server:$sni,server_port:443},
                   private_key:$priv,short_id:[$sid]}}}')
  save_node "$tag" "vless-reality" "$json" "$pub" 0
}

create_vless_tls() {
  local mode=$1 edit=${2:-} tag port uuid domain tls user proto json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    domain=$(n_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    if [ "$mode" = "vision" ]; then
      prompt_tag "vless-vision-$(gen_hex 2)"
    else
      prompt_tag "vless-tls-$(gen_hex 2)"
    fi
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    domain=""
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  if [ -z "$uuid" ]; then
    error "UUID 不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h2 http/1.1)
  if [ "$mode" = "vision" ]; then
    user=$(jq -n --arg u "$uuid" '{name:"user",uuid:$u,flow:"xtls-rprx-vision"}')
    proto="vless-vision-tls"
  else
    user=$(jq -n --arg u "$uuid" '{name:"user",uuid:$u}')
    proto="vless-tls"
  fi
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --argjson user "$user" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[$user],tls:$tls}')
  save_node "$tag" "$proto" "$json" "" "$CERT_INSECURE"
}

create_vless_grpc() {
  local edit=${1:-} tag port uuid domain svc tls transport json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    domain=$(n_get "$tag" '.tls.server_name')
    svc=$(n_get "$tag" '.transport.service_name' 'grpc')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-grpc-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    domain=""
    svc="grpc"
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask svc "gRPC 服务名" "$svc"
  if [ -z "$uuid" ] || [ -z "$svc" ]; then
    error "UUID 或 gRPC 服务名不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h2 http/1.1)
  transport=$(jq -n --arg s "$svc" '{type:"grpc",service_name:$s}')
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vless",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vless-grpc-tls" "$json" "" "$CERT_INSECURE"
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
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    domain=""
    path="/ws-$(gen_hex 2)"
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
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

create_vless_httpupgrade() {
  local edit=${1:-} tag port uuid domain path tls transport json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    domain=$(n_get "$tag" '.tls.server_name')
    path=$(n_get "$tag" '.transport.path' '/upgrade')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-hu-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    domain=""
    path="/upgrade-$(gen_hex 2)"
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask path "HTTPUpgrade 路径" "$path"
  [[ $path == /* ]] || path="/$path"
  if [ -z "$uuid" ]; then
    error "UUID 不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h2 http/1.1)
  transport=$(jq -n --arg p "$path" --arg h "$domain" '{type:"httpupgrade",path:$p,host:$h}')
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vless",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vless-httpupgrade-tls" "$json" "" "$CERT_INSECURE"
}

