outbound_wizard() {
  local edit=${1:-} choice tag type server port user='' password='' psk file=$SB_TXN/outbound.json source link detour='' value field
  if [[ -n $edit ]]; then
    jq -e --arg id "$edit" '.outbounds[]|select(.tag==$id)' "$SB_TXN/state.json" > "$file" || return 1
    tag=$edit
    say '编辑：1 修改服务器/端口/认证（保留其他字段）；2 用新分享链接替换；3 用 JSON 替换'
    ask choice '选择' 1 || return 130
  else
    ask_valid tag '出站名称，例如 exit-us' "exit-$(random_hex 2)" valid_id || return 130
    say '1 手动 SOCKS5 / HTTP / Snell；2 分享链接；3 自定义 JSON'
    ask choice '选择' 2 || return 130
  fi
  case "$choice" in
    1)
      if [[ -n $edit ]]; then type=$(jq -r .type "$file"); server=$(jq -r .server "$file"); port=$(jq -r .server_port "$file")
      else
        ask type '协议：socks / http / snell' socks || return 130
        case "$type" in socks|http|snell) ;; *) return 1;; esac
        server=''; port=1080
        jq -n --arg tag "$tag" --arg type "$type" '{tag:$tag,type:$type}' > "$file"
      fi
      ask_valid server '出口服务器地址（裸 IPv6 / IP / 域名）' "$server" valid_address || return 130
      ask_valid port '出口服务器端口' "$port" valid_port || return 130
      node_set "$file" '.server=$s | .server_port=$p' --arg s "$server" --argjson p "$((10#$port))" || return 1
      case "$type" in
        socks|http)
          user=$(jq -r '.username//""' "$file")
          ask user '认证用户名（- 为无认证）' "${user:--}" || return 130
          if [[ $user != - ]]; then
            password=$(jq -r '.password//""' "$file")
            ask_secret password '出口认证密码' "$password" || return 130
            node_set "$file" '.username=$u|.password=$p' --arg u "$user" --arg p "$password" || return 1
          else node_set "$file" 'del(.username,.password)' || return 1; fi
          [[ $type != socks ]] || node_set "$file" '.version="5"' || return 1;;
        snell)
          psk=$(jq -r '.psk//""' "$file"); [[ -n $psk ]] || psk=$(random_hex)
          ask_secret psk 'Snell v6 PSK（12–255 字节）' "$psk" || return 130
          node_set "$file" '.version=6|.psk=$p' --arg p "$psk" || return 1;;
        *)
          for field in uuid password; do
            value=$(jq -r --arg f "$field" '.[$f]//""' "$file")
            [[ -n $value ]] || continue
            ask_secret value "$field" "$value" || return 130
            node_set "$file" '.[$f]=$v' --arg f "$field" --arg v "$value" || return 1
          done;;
      esac;;
    2) ask_secret link '粘贴分享链接（不回显）' '' || return 130; link_parse "$link" "$tag" > "$file" || return 1;;
    3)
      ask_valid source '单个出站 JSON 文件路径' '' valid_nonempty || return 130
      jq --arg tag "$tag" '.tag=$tag' "$source" > "$file" || return 1;;
    *) return 1;;
  esac
  detour=$(jq -r '.detour//"direct"' "$file")
  ask detour '通过哪个已有出口连接此服务器？direct 直接连接，或填写出站名称' "$detour" || return 130
  if [[ $detour == direct ]]; then node_set "$file" 'del(.detour)' || return 1
  else node_set "$file" '.detour=$d' --arg d "$detour" || return 1; fi
  if [[ -n $edit ]]; then put_outbound "$file" edit; else put_outbound "$file" add; fi
  local rc=$?; rm -f "$file"; return "$rc"
}
outbound_menu() {
  local choice id out raw
  local -a ids=()
  list_outbounds
  say '1 新增出口；2 修改出口；3 删除出口；4 绑定节点；5 恢复直连；0 返回'
  ask choice '选择' '' || return 130
  case "$choice" in
    1) txn_begin && outbound_wizard && confirm '保存出站' && txn_commit;;
    2) ask_valid id '出站名称' '' valid_id && txn_begin && outbound_wizard "$id" && confirm '保存出站修改' && txn_commit;;
    3) ask_valid id '出站名称' '' valid_id && confirm '删除出口；引用此出口的节点会恢复直连' && mutate delete_resource outbound "$id";;
    4|5)
      list_nodes
      ask raw '节点名称（空格/逗号分隔；all 全部；回车取消）' '' || return 130
      [[ -n $raw ]] || return 0; raw=${raw//,/ }; raw=${raw//，/ }; read -r -a ids <<< "$raw"
      out=direct
      [[ $choice != 4 ]] || ask out '出口名称' '' || return 130
      confirm "将所选节点绑定到 $out" && mutate bind_nodes "$out" "${ids[@]}";;
  esac
}
