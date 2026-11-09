# ================================================================
#  Snell
# ================================================================
create_snell() {
  local edit=${1:-} tag port psk mode choice len json
  if ! core_supports_snell; then
    error "Snell v6 需要 sing-box 1.14.0 或更高版本，请先在“核心管理”中更新核心"
    return 1
  fi

  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 6160)
    psk=$(n_get "$tag" '.psk')
    mode=$(n_get "$tag" '.mode' 'default')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "snell-v6-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    psk=$(gen_hex 16)
    mode="default"
  fi

  ask_port "$port" tcp
  port=$PORT_VAL

  while true; do
    ask psk "PSK (12-255 字节)" "$psk"
    len=$(printf '%s' "$psk" | wc -c | tr -d ' ')
    if [ "$len" -ge 12 ] && [ "$len" -le 255 ]; then
      break
    fi
    warn "PSK 长度必须是 12-255 字节"
    psk=$(gen_hex 16)
    warn "已生成新的随机 PSK，请直接回车使用"
  done

  case "$mode" in
    unshaped)   choice="2" ;;
    unsafe-raw) choice="3" ;;
    *)          choice="1" ;;
  esac
  printf '  1) default\n  2) unshaped\n  3) unsafe-raw\n'
  ask choice "Snell 模式 (客户端需一致)" "$choice"
  case "$choice" in
    2) mode="unshaped" ;;
    3) mode="unsafe-raw" ;;
    *) mode="default" ;;
  esac

  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg psk "$psk" --arg mode "$mode" '
    {type:"snell",tag:$tag,listen:$listen,listen_port:$port,
     version:6,psk:$psk,mode:$mode}')
  save_node "$tag" "snell-v6" "$json" "" 0
}
