# ================================================================
#  Trojan
# ================================================================

# Trojan + TCP + TLS
create_trojan() {
  local tag port password sni tls json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "trojan-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    password=""
    sni=""
  fi

  [ -n "$password" ] || password=$(gen_hex 16)
  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  tls=$(tls_cert_json "$sni" h2 http/1.1) || return 1
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"trojan",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  save_node "$tag" "trojan" "$json" "" 1
}
