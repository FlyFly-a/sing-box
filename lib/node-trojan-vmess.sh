# ================================================================
#  Trojan / VMess
# ================================================================
create_trojan() {
  local kind=$1 edit=${2:-} tag port password domain tls transport proto prefix path json
  case "$kind" in
    tcp) prefix="trojan";    proto="trojan-tls" ;;
    ws)  prefix="trojan-ws"; proto="trojan-ws-tls" ;;
    *)
      error "未知 Trojan 类型"
      return 1
      ;;
  esac

  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    password=$(n_get "$tag" '.users[0].password')
    domain=$(n_get "$tag" '.tls.server_name')
    path=$(n_get "$tag" '.transport.path' '/ws')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "${prefix}-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    password=$(gen_hex 16)
    domain=""
    path="/ws-$(gen_hex 2)"
  fi

  ask_port "$port" tcp
  port=$PORT_VAL
  ask password "Trojan 密码" "$password"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL

  transport=""
  if [ "$kind" = "ws" ]; then
    ask path "WebSocket 路径" "$path"
    [[ $path == /* ]] || path="/$path"
    transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  fi

  if [ -z "$password" ]; then
    error "Trojan 密码不能为空"
    return 1
  fi

  tls=$(tls_cert_json "$domain" h2 http/1.1)
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"trojan",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  if [ -n "$transport" ]; then
    json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  fi
  save_node "$tag" "$proto" "$json" "" "$CERT_INSECURE"
}

create_vmess() {
  local edit=${1:-} tag port uuid domain path tls transport json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 10086)
    uuid=$(n_get "$tag" '.users[0].uuid')
    domain=$(n_get "$tag" '.tls.server_name')
    path=$(n_get "$tag" '.transport.path' '/ws')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vmess-ws-$(gen_hex 2)"
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
    {type:"vmess",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vmess-ws-tls" "$json" "" "$CERT_INSECURE"
}
