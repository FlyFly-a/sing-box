# ================================================================
#  出站协议创建: SOCKS5 / HTTP / Shadowsocks / VMess / VLESS / Trojan / Hysteria2 / TUIC / Snell
# ================================================================
create_out_socks() {
  local mode=$1 prefix type tag server user pass port json
  if [ "$mode" = "http" ]; then
    prefix="http-out"
    type="http"
  else
    prefix="socks-out"
    type="socks"
  fi
  prompt_out_tag "${prefix}-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 1080
  port=$RPORT
  ask user "用户名 (留空则无认证)" ""
  pass=""
  if [ -n "$user" ]; then
    ask pass "密码" ""
  fi
  if [ "$type" = "socks" ]; then
    json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" '
      {type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}')
  else
    json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" '
      {type:"http",tag:$tag,server:$server,server_port:$port}')
  fi
  if [ -n "$user" ]; then
    json=$(jq --arg u "$user" --arg p "$pass" '. + {username:$u,password:$p}' <<<"$json")
  fi
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_ss() {
  local tag server port method pass bytes json
  prompt_out_tag "ss-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 8388
  port=$RPORT
  printf '  1) aes-256-gcm\n  2) aes-128-gcm\n  3) chacha20-ietf-poly1305\n'
  printf '  4) 2022-blake3-aes-128-gcm\n  5) 2022-blake3-aes-256-gcm\n'
  local c
  ask c "加密方式" "1"
  bytes=""
  case "$c" in
    2) method="aes-128-gcm" ;;
    3) method="chacha20-ietf-poly1305" ;;
    4) method="2022-blake3-aes-128-gcm"; bytes=16 ;;
    5) method="2022-blake3-aes-256-gcm"; bytes=32 ;;
    *) method="aes-256-gcm" ;;
  esac
  if [ -n "$bytes" ]; then
    pass=$(gen_b64 "$bytes")
    while true; do
      ask pass "密码 (Base64 编码的 ${bytes} 字节密钥)" "$pass"
      if valid_ss2022_key "$bytes" "$pass"; then
        break
      fi
      warn "密钥无效，已重新生成默认值"
      pass=$(gen_b64 "$bytes")
    done
  else
    pass=$(gen_hex 16)
    ask pass "密码" "$pass"
  fi
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg method "$method" --arg pass "$pass" '
    {type:"shadowsocks",tag:$tag,server:$server,server_port:$port,
     method:$method,password:$pass}')
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_vmess() {
  local tag server port uuid sni insecure tls transport json
  prompt_out_tag "vmess-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  uuid=$(gen_uuid)
  ask_uuid "$uuid"
  uuid=$UUID_VAL
  sni=""
  insecure=0
  tls=""
  if confirm "是否启用 TLS?" "y"; then
    ask sni "TLS SNI (可直接用服务器地址)" "$server"
    if confirm "是否跳过证书验证? 自签证书选是" "n"; then
      insecure=1
    fi
    tls=$(client_tls_json "$sni" "$insecure")
  fi
  ask_out_transport
  transport=$OUT_TRANSPORT_JSON
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg uuid "$uuid" '
    {type:"vmess",tag:$tag,server:$server,server_port:$port,
     uuid:$uuid,security:"auto"}')
  [ -n "$tls" ] && json=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$json")
  [ -n "$transport" ] && json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_vless() {
  local tag server port uuid security flow sni insecure pub sid tls transport json
  prompt_out_tag "vless-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  uuid=$(gen_uuid)
  ask_uuid "$uuid"
  uuid=$UUID_VAL
  printf '  1) 无 TLS\n  2) TLS\n  3) REALITY\n'
  ask security "TLS 模式" "2"
  case "$security" in
    1|2|3) ;;
    *) warn "无效选择，已使用 TLS"; security=2 ;;
  esac
  flow=""
  ask flow "流控 flow (例如 xtls-rprx-vision，可留空)" ""
  [ "$security" = "1" ] && flow=""
  tls=""
  if [ "$security" = "3" ]; then
    ask sni "REALITY 伪装域名 (SNI)" "$server"
    ask pub "REALITY 公钥 (pbk)" ""
    ask sid "Short ID (十六进制)" ""
    if [ -z "$pub" ] || { [ -n "$sid" ] && ! valid_short_id "$sid"; }; then
      error "REALITY 公钥不能为空，Short ID 必须是最多 16 位的十六进制字符串（可留空）"
      return 1
    fi
    tls=$(client_tls_json "$sni" 0 "$pub" "$sid")
  elif [ "$security" = "2" ]; then
    ask sni "TLS SNI (可直接用服务器地址)" "$server"
    insecure=0
    if confirm "是否跳过证书验证? 自签证书选是" "n"; then
      insecure=1
    fi
    tls=$(client_tls_json "$sni" "$insecure")
  fi
  ask_out_transport
  transport=$OUT_TRANSPORT_JSON
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg uuid "$uuid" '
    {type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid}')
  if [ -n "$flow" ]; then
    json=$(jq --arg f "$flow" '. + {flow:$f}' <<<"$json")
  fi
  [ -n "$tls" ] && json=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$json")
  [ -n "$transport" ] && json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_trojan() {
  local tag server port password sni insecure tls transport json
  prompt_out_tag "trojan-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  password=$(gen_hex 16)
  ask password "Trojan 密码" "$password"
  ask sni "TLS SNI (可直接用服务器地址)" "$server"
  insecure=0
  if confirm "是否跳过证书验证? 自签证书选是" "n"; then
    insecure=1
  fi
  tls=$(client_tls_json "$sni" "$insecure")
  ask_out_transport
  transport=$OUT_TRANSPORT_JSON
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"trojan",tag:$tag,server:$server,server_port:$port,
     password:$password,tls:$tls}')
  [ -n "$transport" ] && json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_hysteria2() {
  local tag server port password sni insecure bool tls json
  prompt_out_tag "hy2-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  password=$(gen_hex 16)
  ask password "认证密码" "$password"
  ask sni "TLS SNI (可直接用服务器地址)" "$server"
  insecure=0
  if confirm "是否跳过证书验证? 自签证书选是" "n"; then
    insecure=1
  fi
  bool="false"
  [ "$insecure" = "1" ] && bool="true"
  tls=$(jq -n --arg sni "$sni" --argjson insecure "$bool" '
    {enabled:true,server_name:$sni,alpn:["h3"],insecure:$insecure}')
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"hysteria2",tag:$tag,server:$server,server_port:$port,
     password:$password,tls:$tls}')
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_tuic() {
  local tag server port uuid password sni insecure cc bool tls json
  prompt_out_tag "tuic-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  uuid=$(gen_uuid)
  ask_uuid "$uuid"
  uuid=$UUID_VAL
  password=$(gen_hex 16)
  ask password "密码" "$password"
  ask sni "TLS SNI (可直接用服务器地址)" "$server"
  ask cc "拥塞控制 (bbr/cubic/new_reno)" "bbr"
  case "$cc" in
    bbr|cubic|new_reno) ;;
    *) warn "未知拥塞控制算法，已改用 bbr"; cc="bbr" ;;
  esac
  insecure=0
  if confirm "是否跳过证书验证? 自签证书选是" "n"; then
    insecure=1
  fi
  bool="false"
  [ "$insecure" = "1" ] && bool="true"
  tls=$(jq -n --arg sni "$sni" --argjson insecure "$bool" '
    {enabled:true,server_name:$sni,alpn:["h3"],insecure:$insecure}')
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" --arg cc "$cc" '
    {type:"tuic",tag:$tag,server:$server,server_port:$port,
     uuid:$uuid,password:$password,congestion_control:$cc,tls:$tls}')
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_snell() {
  local tag server port psk json
  if ! core_supports_snell; then
    error "Snell v6 需要 sing-box 1.14.0 或更高版本，请先在“核心管理”中更新核心"
    return 1
  fi
  prompt_out_tag "snell-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 6160
  port=$RPORT
  psk=$(gen_hex 16)
  ask_snell_psk "$psk"
  psk=$SNELL_PSK_VAL
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg psk "$psk" '
    {type:"snell",tag:$tag,server:$server,server_port:$port,
     version:6,psk:$psk,reuse:false,mode:"default"}')
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_custom() {
  local f tag tmp prev_final
  ask f "JSON 文件路径" ""
  f=${f/#\~/$HOME}
  if [ ! -s "$f" ]; then
    error "文件不存在: $f"
    return 1
  fi
  if ! jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' "$f" >/dev/null 2>&1; then
    error "JSON 必须是一个包含 type 和 tag 字段的出站对象"
    return 1
  fi
  tag=$(jq -r '.tag' "$f")
  if ! [[ $tag =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]; then
    error "出站名称含非法字符，且不能以点开头: $tag"
    return 1
  fi
  if [ "$tag" = "direct" ] || [ -e "$NODE_DIR/$tag.json" ] || [ -e "$OUT_DIR/$tag.json" ]; then
    error "tag [$tag] 已存在或与节点冲突"
    return 1
  fi
  tmp="$OUT_DIR/$tag.json.tmp.$$"
  if ! jq . "$f" > "$tmp"; then
    rm -f "$tmp"
    error "导入失败"
    return 1
  fi
  chmod 600 "$tmp"
  if ! mv -f "$tmp" "$OUT_DIR/$tag.json"; then
    rm -f "$tmp"
    error "导入失败"
    return 1
  fi
  info "自定义出站 [$tag] 已导入"
  prev_final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  if ! finish_outbound "$tag"; then
    printf '%s\n' "$prev_final" > "$FINAL_FILE"
    rm -f "$OUT_DIR/$tag.json"
    rebuild_config >/dev/null 2>&1 || true
    error "出站配置校验失败，已删除导入的 [$tag]"
    return 1
  fi
}

