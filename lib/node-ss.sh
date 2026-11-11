# ================================================================
#  Shadowsocks-2022
# ================================================================
# 固定使用 2022-blake3-aes-256-gcm，密钥必须为 32 字节 Base64

create_ss2022() {
  local tag port password json
  local method="2022-blake3-aes-256-gcm"
  local bytes=32

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 8388)
    password=$(node_get "$tag" '.password')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "ss-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    password=""
  fi

  WIZ_PORT=$port; ask_port both; port=$WIZ_PORT
  WIZ_TAG=$tag

  if ! valid_ss2022_key "$bytes" "$password"; then
    password=$(gen_b64 "$bytes") || { error "Shadowsocks 密钥生成失败"; return 1; }
    valid_ss2022_key "$bytes" "$password" || { error "Shadowsocks 密钥无效"; return 1; }
  fi

  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg method "$method" --arg password "$password" '
    {type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,
     method:$method,password:$password}')
  save_node "$tag" "shadowsocks-2022" "$json" "" 0
}
