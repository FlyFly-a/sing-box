# ================================================================
#  Shadowsocks 系列
# ================================================================
valid_ss2022_key() {
  local bytes=$1 key=$2 len
  len=$(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c | tr -d ' ' || true)
  [ "$len" = "$bytes" ]
}

create_ss2022() {
  local edit=${1:-} tag port method password bytes choice json
  bytes=32
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 8388)
    method=$(n_get "$tag" '.method' '2022-blake3-aes-256-gcm')
    password=$(n_get "$tag" '.password')
    case "$method" in
      2022-blake3-aes-128-gcm) bytes=16 ;;
      *) method="2022-blake3-aes-256-gcm"; bytes=32 ;;
    esac
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "ss2022-$(gen_hex 2)"
    tag=$TAG_VAL
    if port_in_use 8388 tcp; then
      port=$(suggest_port tcp)
    else
      port=8388
    fi
    method=""
    password=""
  fi

  ask_port "$port" tcp
  port=$PORT_VAL

  if [ -z "$method" ]; then
    printf '  1) 2022-128 (16 字节密钥)\n  2) 2022-256 (32 字节密钥，推荐)\n'
    ask choice "Shadowsocks-2022 密钥长度" "2"
    case "$choice" in
      1) method="2022-blake3-aes-128-gcm"; bytes=16 ;;
      *) method="2022-blake3-aes-256-gcm"; bytes=32 ;;
    esac
  fi

  [ -n "$password" ] || password=$(gen_b64 "$bytes")
  while true; do
    ask password "密码 (Base64 编码的 ${bytes} 字节密钥)" "$password"
    if valid_ss2022_key "$bytes" "$password"; then
      break
    fi
    warn "密钥无效，必须是 ${bytes} 字节的 Base64 编码"
    password=$(gen_b64 "$bytes")
    warn "已重新生成合法密钥作为默认值，请直接回车使用"
  done

  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg method "$method" --arg password "$password" '
    {type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,
     method:$method,password:$password}')
  save_node "$tag" "shadowsocks-2022" "$json" "" 0
}
