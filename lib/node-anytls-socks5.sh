# ================================================================
#  AnyTLS / SOCKS5
# ================================================================
create_anytls() {
  local edit=${1:-} tag port password domain tls json
  if ! core_supports_anytls; then
    error "AnyTLS 需要 sing-box 1.12.0 或更高版本，请先在“核心管理”中更新核心"
    return 1
  fi
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    password=$(n_get "$tag" '.users[0].password')
    domain=$(n_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "anytls-$(gen_hex 2)"
    tag=$TAG_VAL
    port=""
    password=$(gen_hex 16)
    domain=""
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask password "AnyTLS 密码" "$password"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  if [ -z "$password" ]; then
    error "密码不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h2 http/1.1)
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"anytls",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  save_node "$tag" "anytls-tls" "$json" "" "$CERT_INSECURE"
}

create_socks5() {
  local edit=${1:-} tag port username password json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 1080)
    username=$(n_get "$tag" '.users[0].username' 'user')
    password=$(n_get "$tag" '.users[0].password')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "socks5-$(gen_hex 2)"
    tag=$TAG_VAL
    port=""
    username="user"
    password=$(gen_hex 8)
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask username "用户名" "$username"
  ask password "密码" "$password"
  if [ -z "$username" ] || [ -z "$password" ]; then
    error "用户名或密码不能为空"
    return 1
  fi
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg username "$username" --arg password "$password" '
    {type:"socks",tag:$tag,listen:$listen,listen_port:$port,
     users:[{username:$username,password:$password}]}')
  save_node "$tag" "socks5" "$json" "" 0
}

