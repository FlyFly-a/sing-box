# ================================================================
#  Snell
# ================================================================
create_snell() {
  local edit=${1:-} tag port psk json
  if ! core_supports_snell; then
    error "Snell v6 需要 sing-box 1.14.0 或更高版本，请先在“核心管理”中更新核心"
    return 1
  fi

  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 6160)
    psk=$(n_get "$tag" '.psk')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "snell-v6-$(gen_hex 2)"
    tag=$TAG_VAL
    port=""
    psk=$(gen_hex 16)
  fi

  ask_port "$port" tcp
  port=$PORT_VAL

  ask_snell_psk "$psk"
  psk=$SNELL_PSK_VAL

  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg psk "$psk" '
    {type:"snell",tag:$tag,listen:$listen,listen_port:$port,
     version:6,psk:$psk,mode:"default"}')
  save_node "$tag" "snell-v6" "$json" "" 0
}
