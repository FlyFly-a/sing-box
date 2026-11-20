# ================================================================
#  出站手动创建 (SOCKS5 / 自定义 JSON)
#  其余协议请用"粘贴分享链接"
# ================================================================

create_out_socks() {
  local tag server port user pass json

  prompt_out_tag "socks-out-$(gen_hex 2)"
  tag=$SELECTED_OUT
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 1080
  port=$RPORT

  ask user "用户名（留空则无认证）" ""
  pass=""
  [ -n "$user" ] && ask pass "密码" ""

  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}')
  if [ -n "$user" ]; then
    json=$(jq --arg u "$user" --arg p "$pass" '. + {username:$u,password:$p}' <<<"$json")
  fi
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
  printf ' 1) 粘贴分享链接（vless / hysteria2 / ss，仅 SS-2022）\n'
  printf ' 2) 手动填写（SOCKS5）\n'
  printf ' 3) 导入自定义 JSON\n'
  printf ' 0) 返回上层\n'
  menu_read c "请选择" || return 1
  case "$c" in
    1) create_out_from_link; return $? ;;
    2) menu_add_outbound_manual; return $? ;;
    3) create_out_custom; return $? ;;
    0) return 1 ;;
    *) warn "无效选项"; return 0 ;;
  esac
}

menu_add_outbound_manual() {
  local c
  printf '%s\n' "------------- 手动新增出站 -------------"
  printf ' 1) SOCKS5\n 0) 返回上层\n'
  menu_read c "请选择" || return 1
  case "$c" in
    1) create_out_socks; return 0 ;;
    0) return 1 ;;
    *) warn "无效选项"; return 0 ;;
  esac
}
