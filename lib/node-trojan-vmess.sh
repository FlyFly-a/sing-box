# ================================================================
#  Trojan / VMess
# ================================================================

# Trojan (TCP) 与 Trojan-WS，由 kind 区分
create_trojan() {
  local kind=$1 tag port password sni path tls transport json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    path=$(node_get "$tag" '.transport.path')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    case "$kind" in
      ws) prompt_tag "trojan-ws-$(gen_hex 2)" || return 1 ;;
      *)  prompt_tag "trojan-$(gen_hex 2)" || return 1 ;;
    esac
    tag=$WIZ_TAG
    port=""
    password=""
    sni=""
    path=""
  fi

  [ -n "$password" ] || password=$(gen_hex 16)
  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  transport=""
  if [ "$kind" = "ws" ]; then
    [ -n "$path" ] || path="/$(gen_hex 6)"
    transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  fi

  tls=$(tls_cert_json "$sni" h2 http/1.1) || return 1
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"trojan",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  if [ -n "$transport" ]; then
    json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  fi
  if [ "$kind" = "ws" ]; then
    save_node "$tag" "trojan-ws" "$json" "" 1
  else
    save_node "$tag" "trojan" "$json" "" 1
  fi
}

# VMess + WebSocket + TLS
create_vmess() {
  local tag port uuid sni path tls transport json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    uuid=$(node_get "$tag" '.users[0].uuid')
    sni=$(node_get "$tag" '.tls.server_name')
    path=$(node_get "$tag" '.transport.path')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vmess-ws-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    uuid=""
    sni=""
    path=""
  fi

  [ -n "$uuid" ] || uuid=$(gen_uuid)
  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  [ -n "$path" ] || path="/$(gen_hex 6)"
  tls=$(tls_cert_json "$sni" h2 http/1.1) || return 1
  transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vmess",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vmess-ws" "$json" "" 1
}
