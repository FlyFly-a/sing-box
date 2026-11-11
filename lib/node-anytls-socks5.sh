# ================================================================
#  AnyTLS / SOCKS5
# ================================================================

# AnyTLS
create_anytls() {
  local tag port password sni tls json

  if [ -x "$BIN" ] && ! core_supports_anytls; then
    error "AnyTLS 需要 sing-box 1.12 或更高版本，请先更新核心"
    return 1
  fi

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "anytls-$(gen_hex 2)" || return 1
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
    {type:"anytls",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  save_node "$tag" "anytls" "$json" "" 1
}

# SOCKS5，凭据自动生成，不询问
create_socks5() {
  local tag port username password json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 1080)
    username=$(node_get "$tag" '.users[0].username' 'user')
    password=$(node_get "$tag" '.users[0].password')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "socks5-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    username="user"
    password=""
  fi

  [ -n "$username" ] || username="user"
  [ -n "$password" ] || password=$(gen_hex 8)
  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_TAG=$tag

  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg username "$username" --arg password "$password" '
    {type:"socks",tag:$tag,listen:"::",listen_port:$port,
     users:[{username:$username,password:$password}]}')
  save_node "$tag" "socks5" "$json" "" 0
}
