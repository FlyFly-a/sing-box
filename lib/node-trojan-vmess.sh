# ================================================================
#  Trojan / VMess
# ================================================================
create_trojan() {
  local kind=$1 edit=${2:-} tag port password domain tls transport proto prefix path svc json
  case "$kind" in
    tcp)  prefix="trojan";      proto="trojan-tls" ;;
    grpc) prefix="trojan-grpc"; proto="trojan-grpc-tls" ;;
    ws)   prefix="trojan-ws";   proto="trojan-ws-tls" ;;
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
    svc=$(n_get "$tag" '.transport.service_name' 'grpc')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "${prefix}-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    password=$(gen_hex 16)
    domain=""
    path="/ws-$(gen_hex 2)"
    svc="grpc"
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
  elif [ "$kind" = "grpc" ]; then
    ask svc "gRPC 服务名" "$svc"
    transport=$(jq -n --arg s "$svc" '{type:"grpc",service_name:$s}')
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
  local tlsflag=$1 kind=$2 edit=${3:-} tag port uuid domain tls transport proto prefix path svc json
  case "$tlsflag-$kind" in
    0-tcp) prefix="vmess-tcp";     proto="vmess-tcp" ;;
    1-tcp) prefix="vmess-tcp-tls"; proto="vmess-tcp-tls" ;;
    1-ws)  prefix="vmess-ws";      proto="vmess-ws-tls" ;;
    1-grpc) prefix="vmess-grpc";   proto="vmess-grpc-tls" ;;
    *)
      error "未知 VMess 类型"
      return 1
      ;;
  esac

  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 10086)
    uuid=$(n_get "$tag" '.users[0].uuid')
    domain=$(n_get "$tag" '.tls.server_name')
    path=$(n_get "$tag" '.transport.path' '/ws')
    svc=$(n_get "$tag" '.transport.service_name' 'grpc')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "${prefix}-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    domain=""
    path="/ws-$(gen_hex 2)"
    svc="grpc"
  fi

  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  if [ "$tlsflag" = "1" ]; then
    prompt_domain_cert "$domain" || return 1
    domain=$DOMAIN_VAL
  fi

  transport=""
  if [ "$kind" = "ws" ]; then
    ask path "WebSocket 路径" "$path"
    [[ $path == /* ]] || path="/$path"
    transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  elif [ "$kind" = "grpc" ]; then
    ask svc "gRPC 服务名" "$svc"
    transport=$(jq -n --arg s "$svc" '{type:"grpc",service_name:$s}')
  fi

  if [ -z "$uuid" ]; then
    error "UUID 不能为空"
    return 1
  fi

  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" '
    {type:"vmess",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid}]}')
  if [ "$tlsflag" = "1" ]; then
    tls=$(tls_cert_json "$domain" h2 http/1.1)
    json=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$json")
  fi
  if [ -n "$transport" ]; then
    json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  fi
  if [ "$tlsflag" = "1" ]; then
    save_node "$tag" "$proto" "$json" "" "$CERT_INSECURE"
  else
    save_node "$tag" "$proto" "$json" "" 0
  fi
}

