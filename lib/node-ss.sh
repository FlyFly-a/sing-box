# ================================================================
#  Shadowsocks 系列
# ================================================================
SS_METHOD=""

choose_ss_method() {
  local def=${1:-aes-256-gcm} c
  printf '  1) aes-256-gcm (推荐)\n  2) aes-128-gcm\n  3) chacha20-ietf-poly1305\n'
  case "$def" in
    aes-128-gcm)             c="2" ;;
    chacha20-ietf-poly1305)  c="3" ;;
    *)                       c="1" ;;
  esac
  ask c "选择加密方式" "$c"
  case "$c" in
    2) SS_METHOD="aes-128-gcm" ;;
    3) SS_METHOD="chacha20-ietf-poly1305" ;;
    *) SS_METHOD="aes-256-gcm" ;;
  esac
}

valid_ss2022_key() {
  local bytes=$1 key=$2 len
  len=$(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c | tr -d ' ' || true)
  [ "$len" = "$bytes" ]
}

create_ss() {
  local kind=$1 edit=${2:-} tag port method password proto prefix bytes json
  bytes=""
  case "$kind" in
    aead)
      prefix="ss-aead"
      proto="shadowsocks-aead"
      ;;
    2022-128)
      prefix="ss2022-128"
      proto="shadowsocks-2022-128"
      bytes=16
      method="2022-blake3-aes-128-gcm"
      ;;
    2022-256)
      prefix="ss2022-256"
      proto="shadowsocks-2022-256"
      bytes=32
      method="2022-blake3-aes-256-gcm"
      ;;
    *)
      error "未知 Shadowsocks 类型"
      return 1
      ;;
  esac

  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 8388)
    method=$(n_get "$tag" '.method' "$method")
    password=$(n_get "$tag" '.password')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "${prefix}-$(gen_hex 2)"
    tag=$TAG_VAL
    if port_in_use 8388 tcp; then
      port=$(suggest_port tcp)
    else
      port=8388
    fi
    if [ "$kind" = "aead" ]; then
      choose_ss_method "aes-256-gcm"
      method=$SS_METHOD
      password=$(gen_hex 16)
    else
      password=$(gen_b64 "$bytes")
    fi
  fi

  ask_port "$port" tcp
  port=$PORT_VAL

  if [ "$kind" = "aead" ]; then
    choose_ss_method "$method"
    method=$SS_METHOD
    ask password "密码" "$password"
    if [ -z "$password" ]; then
      error "密码不能为空"
      return 1
    fi
  else
    while true; do
      ask password "密码 (Base64 编码的 ${bytes} 字节密钥)" "$password"
      if valid_ss2022_key "$bytes" "$password"; then
        break
      fi
      warn "密钥无效，必须是 ${bytes} 字节的 Base64 编码"
      password=$(gen_b64 "$bytes")
      warn "已重新生成合法密钥作为默认值，请直接回车使用"
    done
  fi

  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg method "$method" --arg password "$password" '
    {type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,
     method:$method,password:$password}')
  save_node "$tag" "$proto" "$json" "" 0
}

create_ss_shadowtls() {
  local edit=${1:-} tag port stpass hs ssmethod sspass sport inner_tag cand i json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    stpass=$(n_get "$tag" '.users[0].password')
    hs=$(n_get "$tag" '.handshake.server' 'www.apple.com')
    ssmethod=$(jq -r '.[0].method // empty' "$NODE_DIR/$tag.json" 2>/dev/null)
    sspass=$(jq -r '.[0].password // empty' "$NODE_DIR/$tag.json" 2>/dev/null)
    sport=$(jq -r '.[0].listen_port // empty' "$NODE_DIR/$tag.json" 2>/dev/null)
    inner_tag=$(jq -r '.[0].tag // empty' "$NODE_DIR/$tag.json" 2>/dev/null)
    [ -n "$inner_tag" ] || inner_tag="${tag}-inner"
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "ss-shadowtls-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    hs="www.apple.com"
    stpass=$(gen_hex 8)
    ssmethod="aes-256-gcm"
    sspass=$(gen_hex 16)
    inner_tag="${tag}-ss-$(gen_hex 2)"
    while [ -e "$NODE_DIR/$inner_tag.json" ] || [ -e "$OUT_DIR/$inner_tag.json" ]; do
      inner_tag="${tag}-ss-$(gen_hex 2)"
    done
    sport=""
  fi

  ask_port "$port" tcp
  port=$PORT_VAL
  ask stpass "ShadowTLS 认证密码" "$stpass"
  ask hs "ShadowTLS 伪装域名" "$hs"
  choose_ss_method "$ssmethod"
  ssmethod=$SS_METHOD
  ask sspass "内层 Shadowsocks 密码" "$sspass"

  if [ -z "$sport" ]; then
    sport=""
    for ((i=0; i<100; i++)); do
      cand=$((20000 + RANDOM % 20000))
      [ "$cand" = "$port" ] && continue
      if ! port_in_use "$cand" tcp && ! port_in_batch "$cand" tcp; then
        sport=$cand
        break
      fi
    done
    [ -n "$sport" ] || sport=$((20000 + RANDOM % 20000))
  fi

  if [ "$port" = "$sport" ]; then
    error "ShadowTLS 外层端口不能与内层端口相同"
    return 1
  fi

  if [ -z "$stpass" ] || [ -z "$sspass" ] || [ -z "$hs" ]; then
    error "密码或伪装域名不能为空"
    return 1
  fi

  json=$(jq -n --arg tag "$tag" --arg inner "$inner_tag" --arg listen "$LISTEN_ADDR" \
    --argjson port "$port" --argjson sport "$sport" --arg method "$ssmethod" \
    --arg sspass "$sspass" --arg stpass "$stpass" --arg hs "$hs" '
    [
      {type:"shadowsocks",tag:$inner,listen:"127.0.0.1",listen_port:$sport,
       method:$method,password:$sspass},
      {type:"shadowtls",tag:$tag,listen:$listen,listen_port:$port,version:3,
       users:[{name:"user",password:$stpass}],
       handshake:{server:$hs,server_port:443},detour:$inner}
    ]')
  save_node "$tag" "shadowtls" "$json" "" 0
}

