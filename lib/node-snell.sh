# ================================================================
#  Snell v6
# ================================================================
# PSK 自动生成，mode 固定 default

create_snell() {
  local tag port psk json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 6160)
    psk=$(node_get "$tag" '.psk')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "snell-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    psk=""
  fi

  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_TAG=$tag

  if ! valid_psk "$psk"; then
    psk=$(gen_b64 16) || { error "Snell PSK 生成失败"; return 1; }
    valid_psk "$psk" || { error "Snell PSK 无效"; return 1; }
  fi
  json=$(jq -n --arg tag "$tag" --argjson port "$port" --arg psk "$psk" '
    {type:"snell",tag:$tag,listen:"::",listen_port:$port,
     version:6,psk:$psk}')
  save_node "$tag" "snell-v6" "$json" "" 0
}
