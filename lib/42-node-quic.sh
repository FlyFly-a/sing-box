# ================================================================
#  Hysteria2 / TUIC
# ================================================================
create_hysteria2() {
  local edit=${1:-} tag port password domain masq tls json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    password=$(n_get "$tag" '.users[0].password')
    domain=$(n_get "$tag" '.tls.server_name')
    masq=$(n_get "$tag" '.masquerade' 'https://www.bing.com')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "hysteria2-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port udp)
    password=$(gen_hex 16)
    domain=""
    masq="https://www.bing.com"
  fi
  ask_port "$port" udp
  port=$PORT_VAL
  ask password "认证密码" "$password"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask masq "伪装网站 (留空则不设置)" "$masq"
  if [ -z "$password" ]; then
    error "密码不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h3)
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" --arg masq "$masq" '
    ({type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,
      users:[{name:"user",password:$password}],
      tls:$tls}
     + (if $masq != "" then {masquerade:$masq} else {} end))')
  save_node "$tag" "hysteria2" "$json" "" "$CERT_INSECURE"
}

create_tuic() {
  local edit=${1:-} tag port uuid password domain cc tls json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    password=$(n_get "$tag" '.users[0].password')
    domain=$(n_get "$tag" '.tls.server_name')
    cc=$(n_get "$tag" '.congestion_control' 'bbr')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "tuic-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port udp)
    uuid=$(gen_uuid)
    password=$(gen_hex 16)
    domain=""
    cc="bbr"
  fi
  ask_port "$port" udp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  ask password "密码" "$password"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask cc "拥塞控制 (bbr/cubic/new_reno)" "$cc"
  case "$cc" in
    bbr|cubic|new_reno) ;;
    *) warn "未知拥塞控制算法，已改用 bbr"; cc="bbr" ;;
  esac
  if [ -z "$uuid" ] || [ -z "$password" ]; then
    error "UUID 或密码不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h3)
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" --arg cc "$cc" '
    {type:"tuic",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid,password:$password}],
     congestion_control:$cc,tls:$tls}')
  save_node "$tag" "tuic" "$json" "" "$CERT_INSECURE"
}

