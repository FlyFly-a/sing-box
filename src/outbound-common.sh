# ================================================================
#  出站公共逻辑
# ================================================================

outbound_type_display() {
  case "${1:-}" in
    direct)      printf '直连' ;;
    socks)       printf 'SOCKS5' ;;
    shadowsocks) printf 'Shadowsocks-2022' ;;
    vless)       printf 'VLESS' ;;
    hysteria2)   printf 'Hysteria2' ;;
    *)           printf '%s' "${1:-未知}" ;;
  esac
}

# 出站协议白名单: 只保留低开销且常用的组合
outbound_type_supported() {
  case "${1:-}" in
    socks|shadowsocks|vless|hysteria2) return 0 ;;
    *) return 1 ;;
  esac
}

# Shadowsocks 仅支持 2022 系列方法
ss2022_method_supported() {
  case "${1:-}" in
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) return 0 ;;
    *) return 1 ;;
  esac
}

# 校验出站 JSON 的协议类型和必要约束
outbound_validate_json() {
  local json=$1 otype smethod sver
  otype=$(jq -r '.type // empty' <<<"$json" 2>/dev/null || true)
  if ! outbound_type_supported "$otype"; then
    error "不支持的出站协议: ${otype:-空}"
    return 1
  fi
  if uses_ws_transport <<<"$json"; then
    error "不支持 WebSocket 传输的出站"
    return 1
  fi

  case "$otype" in
    shadowsocks)
      smethod=$(jq -r '.method // empty' <<<"$json" 2>/dev/null || true)
      if ! ss2022_method_supported "$smethod"; then
        error "Shadowsocks 出站仅支持 2022 方法: ${smethod:-空}"
        return 1
      fi
      ;;
    vless|hysteria2)
      if ! jq -e '.tls.enabled == true' <<<"$json" >/dev/null 2>&1; then
        error "$(outbound_type_display "$otype") 出站必须启用 TLS"
        return 1
      fi
      ;;
    socks)
      sver=$(jq -r '.version // "5"' <<<"$json" 2>/dev/null || true)
      if [ "${sver:-5}" != "5" ]; then
        error "仅支持 SOCKS5 出站"
        return 1
      fi
      ;;
  esac
  return 0
}

valid_tag() {
  [[ ${1:-} =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]
}

prompt_out_tag() {
  local def=$1 v
  while true; do
    ask v "出站名称" "$def"
    if ! valid_tag "$v"; then
      warn "仅支持字母、数字、点、下划线、短横线，且不能以点开头"
      continue
    fi
    if [ "$v" = "direct" ]; then
      warn "direct 是保留名称"
      continue
    fi
    if node_tag_in_use "$v"; then
      warn "名称 [$v] 已被节点或出站占用"
      continue
    fi
    SELECTED_OUT=$v
    return 0
  done
}

prompt_server() {
  local def=${1:-} s
  while true; do
    ask s "服务器地址" "$def"
    [ -n "$s" ] || { warn "服务器地址不能为空"; continue; }
    SERVER_VAL=$s
    return 0
  done
}

ask_rport() {
  local def=${1:-443} v
  while true; do
    ask v "服务器端口" "$def"
    if valid_port "$v"; then
      RPORT=$((10#$v))
      return 0
    fi
    warn "服务器端口范围 1-65535"
  done
}

# 出站 TLS: insecure 固定开启(对端多为自签证书)，REALITY 时附带 public_key
client_tls_json() {
  local sni=$1 pub=${2:-} sid=${3:-} tls
  tls=$(jq -n --arg sni "$sni" '
    {enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},insecure:true}')
  if [ -n "$pub" ]; then
    tls=$(jq --arg pub "$pub" --arg sid "$sid" \
      '. + {reality:{enabled:true,public_key:$pub,short_id:$sid}}' <<<"$tls")
  fi
  printf '%s' "$tls"
}

save_outbound() {
  local tag=$1
  local json=$2
  local tmp
  local smethod spass
  valid_tag "$tag" || { error "出站名称非法: $tag"; return 1; }
  [ "$tag" = "direct" ] && { error "direct 是保留名称"; return 1; }

  outbound_validate_json "$json" || return 1

  # Shadowsocks-2022 的 password 必须是 16/32 字节 Base64 密钥
  smethod=$(jq -r '.method // empty' <<<"$json" 2>/dev/null || true)
  if [ -n "$smethod" ]; then
    spass=$(jq -r '.password // empty' <<<"$json" 2>/dev/null || true)
    if [ -n "$spass" ]; then
      case "$smethod" in
        2022-blake3-aes-128-gcm)
          spass=$(b64norm "$spass") || {
            error "Shadowsocks-2022 密钥必须是 16 字节 Base64"
            return 1
          }
          valid_ss2022_key 16 "$spass" || {
            error "Shadowsocks-2022 密钥必须是 16 字节 Base64"
            return 1
          }
          ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
          spass=$(b64norm "$spass") || {
            error "Shadowsocks-2022 密钥必须是 32 字节 Base64"
            return 1
          }
          valid_ss2022_key 32 "$spass" || {
            error "Shadowsocks-2022 密钥必须是 32 字节 Base64"
            return 1
          }
          ;;
      esac
      json=$(jq --arg p "$spass" '.password = $p' <<<"$json") || {
        error "出站配置写入失败"
        return 1
      }
    fi
  fi

  mkdir -p "$OUT_DIR" 2>/dev/null || true
  tmp=$(mktemp "$OUT_DIR/.out.XXXXXX") || { error "创建临时文件失败"; return 1; }
  if ! printf '%s\n' "$json" | jq . > "$tmp"; then
    rm -f "$tmp"
    error "出站配置写入失败"
    return 1
  fi
  chmod 600 "$tmp"
  if ! mv -f "$tmp" "$OUT_DIR/$tag.json"; then
    rm -f "$tmp"
    error "出站配置写入失败"
    return 1
  fi
  info "出站 [$tag] 已保存"
  return 0
}
