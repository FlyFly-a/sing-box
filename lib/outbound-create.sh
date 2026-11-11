# ================================================================
#  出站手动创建 (SOCKS5 / Snell / 自定义 JSON)
#  其余协议请用"粘贴分享链接"
# ================================================================

create_out_socks() {
  local mode=$1
  local type
  local tag
  local server
  local port
  local user
  local pass
  local json

  if [ "$mode" = "http" ]; then
    type="http"
    prompt_out_tag "http-out-$(gen_hex 2)"
  else
    type="socks"
    prompt_out_tag "socks-out-$(gen_hex 2)"
  fi
  tag=$SELECTED_OUT
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 1080
  port=$RPORT

  ask user "用户名（留空则无认证）" ""
  pass=""
  [ -n "$user" ] && ask pass "密码" ""

  if [ "$type" = "socks" ]; then
    json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
      '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}')
  else
    json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
      '{type:"http",tag:$tag,server:$server,server_port:$port}')
  fi
  if [ -n "$user" ]; then
    json=$(jq --arg u "$user" --arg p "$pass" '. + {username:$u,password:$p}' <<<"$json")
  fi
  save_outbound "$tag" "$json"
}

create_out_snell() {
  local tag server port psk json
  if ! core_supports_snell; then
    error "Snell v6 需要 sing-box 1.14.0 或更高版本，请先在核心管理中更新核心"
    return 1
  fi
  prompt_out_tag "snell-out-$(gen_hex 2)"
  tag=$SELECTED_OUT
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 6160
  port=$RPORT

  ask psk "PSK" "$(gen_b64 16)"
  while ! valid_psk "$psk"; do
    warn "PSK 长度必须是 12-255 字节，且不能包含空格或逗号"
    psk=$(gen_b64 16)
    ask psk "PSK" "$psk"
  done

  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg psk "$psk" '
    {type:"snell",tag:$tag,server:$server,server_port:$port,version:6,psk:$psk}')
  save_outbound "$tag" "$json"
}

create_out_custom() {
  local f tag json
  ask f "JSON 文件路径" ""
  f=${f/#\~/$HOME}
  [ -s "$f" ] || { error "文件不存在: $f"; return 1; }

  if ! jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' "$f" >/dev/null 2>&1; then
    error "JSON 必须是一个包含 type 和 tag 字段的出站对象"
    return 1
  fi
  tag=$(jq -r '.tag' "$f")
  if ! valid_tag "$tag" || [ "$tag" = "direct" ]; then
    error "出站名称非法或与保留名称冲突: $tag"
    return 1
  fi
  if node_tag_in_use "$tag"; then
    error "名称 [$tag] 已被节点或出站占用"
    return 1
  fi

  json=$(jq . "$f") || { error "导入失败"; return 1; }
  save_outbound "$tag" "$json"
}

# ---------------- 新增出站入口 ----------------
menu_add_outbound() {
  local c
  printf '%s\n' "------------- 新增出站 -------------"
  printf ' 1) 粘贴分享链接（vless / vmess / trojan / hysteria2 / tuic / ss / anytls）\n'
  printf ' 2) 手动填写（SOCKS5 / HTTP / Snell）\n'
  printf ' 3) 导入自定义 JSON\n'
  printf ' 0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1) create_out_from_link ;;
    2) menu_add_outbound_manual ;;
    3) create_out_custom ;;
    0) return 0 ;;
    *) warn "无效选项"; return 0 ;;
  esac
}

menu_add_outbound_manual() {
  local c
  printf '%s\n' "------------- 手动新增出站 -------------"
  printf ' 1) SOCKS5\n 2) HTTP 代理\n 3) Snell-v6\n 0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1) create_out_socks socks ;;
    2) create_out_socks http ;;
    3) create_out_snell ;;
    0) return 0 ;;
    *) warn "无效选项"; return 0 ;;
  esac
}
