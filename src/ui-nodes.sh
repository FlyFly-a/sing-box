certificate_wizard() {
  local file=$1 domain=$2 mode=$3 kind cert='' key=''
  if [[ $mode == cdn ]]; then
    say 'CDN 源站证书：1 公开可信完整链；2 Cloudflare Origin CA（仅源站使用）。'
  else
    say '直连证书：1 公开可信完整链；3 自签（客户端必须另行导入信任）。'
  fi
  while :; do
    ask kind '证书类型' 1 || return 130
    case "$mode:$kind" in
      *:1) kind=public; break;; cdn:2) kind=origin; break;; direct:3) kind=self; break;;
      *) say '此模式不支持该证书类型。';;
    esac
  done
  if [[ $kind != self ]]; then
    ask_valid cert '完整证书链 PEM 路径' '' valid_nonempty || return 130
    ask_valid key '未加密私钥 PEM 路径' '' valid_nonempty || return 130
  fi
  certificate_attach "$file" "$kind" "$domain" "$cert" "$key"
}

node_wizard() {
  local preset=$1 edit=${2:-} file=$SB_TXN/node.json id port public_port address second='' sni='' host='' path='' mode=direct listen old_sni='' oldmode=direct oldport='' prefix=XX change target target_port advanced oldpublic=''
  if [[ -n $edit ]]; then
    jq -e --arg id "$edit" '.nodes[]|select(.id==$id)' "$SB_TXN/state.json" > "$file" || return 1
    preset=$(jq -r .preset "$file"); id=$edit
    oldport=$(jq -r .port "$file"); oldpublic=$(jq -r .endpoint.port "$file")
    old_sni=$(jq -r .endpoint.sni "$file"); oldmode=$(jq -r .endpoint.mode "$file")
    second=$(jq -r '.endpoint.addresses[1]//""' "$file")
  else
    [[ ! -r $SB_ROOT/network.json ]] || prefix=$(jq -r '.country//"XX"' "$SB_ROOT/network.json")
    ask_valid id '节点名称（字母/数字/点/短横线）' "$prefix-$preset-$(random_hex 2)" valid_id || return 130
  fi
  protocol_field "$preset" name >/dev/null || return 1
  if is_ws "$preset"; then
    say '1 直连 TLS；2 Cloudflare CDN（需要自己管理的域名）。'
    change=1; [[ $oldmode != cdn ]] || change=2
    while :; do
      ask change '连接方式' "$change" || return 130
      case "$change" in 1) mode=direct; break;; 2) mode=cdn; break;; *) say '请选择 1 或 2。'; change=1;; esac
    done
  fi
  address=$(jq -r '.defaults.domain//""' "$SB_TXN/state.json")
  if [[ -z $address && -r $SB_ROOT/network.json ]]; then address=$(jq -r '[.ipv4,.ipv6]|map(select(.!=""))|first//""' "$SB_ROOT/network.json"); fi
  [[ -z $edit ]] || address=$(jq -r '.endpoint.addresses[0]' "$file")
  if [[ $mode == cdn ]]; then
    valid_domain "$address" || address=''
    say '域名需解析到源站并开启 Cloudflare 代理、WebSocket，SSL/TLS 使用 Full (strict)。'
    ask_valid address 'CDN 业务域名（例如 proxy.example.com）' "$address" valid_domain || return 130
    public_port=443; [[ $oldmode != cdn ]] || public_port=${oldpublic:-443}
    ask_valid public_port '客户端连接 CDN 的 HTTPS 端口' "$public_port" valid_cdn_port || return 130
    port=${oldport:-$public_port}
    say '默认源站端口与 CDN 端口相同；只有已配置 Origin Rule、NAT 或反向代理映射时才使用不同端口。'
  else
    ask_valid address '客户端连接地址（公网 IP / 域名 / 裸 IPv6）' "$address" valid_address || return 130
    port=$oldport; [[ -n $port ]] || port=$(free_port "$preset") || return 1
  fi
  while :; do
    ask_valid port '服务端监听端口' "$port" valid_port || return 130
    port=$((10#$port))
    [[ $port == "$oldport" ]] && break
    port_free "$port" "$preset" "$id" && break
    say '端口已占用或无法检查，请选择可用端口。'
  done
  if [[ $mode == direct ]]; then
    public_port=${oldpublic:-$port}
    ask_valid public_port '客户端连接端口（NAT 映射端口）' "$public_port" valid_port || return 130
  elif [[ $port != "$public_port" ]]; then
    confirm "CDN $public_port 到监听 $port 的端口映射已配置" || return 130
  fi
  [[ -n $edit ]] || new_node "$preset" "$id" "$port" "$address" "$public_port" > "$file" || return 1
  node_set "$file" '.port=$p|.endpoint.port=$pp|.endpoint.addresses=[$a]|.endpoint.mode=$m' --argjson p "$port" --argjson pp "$((10#$public_port))" --arg a "$address" --arg m "$mode" || return 1
  if [[ $mode == direct && -n $second ]]; then node_set "$file" '.endpoint.addresses+=[$a]' --arg a "$second" || return 1; fi
  listen=$(network_default); [[ -z $edit ]] || listen=$(jq -r .listen "$file")
  ask advanced "监听默认为 $listen；输入 yes 展开监听范围和备用连接地址" no || return 130
  if [[ $advanced == yes ]]; then
    ask_valid listen '监听：0.0.0.0 / :: / dual / 127.0.0.1 / ::1' "$listen" valid_listen || return 130
    if [[ $mode == direct ]]; then
      ask second '备用连接地址（回车保留，- 清除）' "$second" || return 130
      if [[ -n $second && $second != - ]]; then
        valid_address "$second" || { err '备用地址无效。'; return 1; }
        node_set "$file" '.endpoint.addresses=[$a,$b]' --arg a "$address" --arg b "$second" || return 1
      else node_set "$file" '.endpoint.addresses=[$a]' --arg a "$address" || return 1; fi
    fi
  fi
  node_set "$file" '.listen=$l' --arg l "$listen" || return 1
  case "$preset" in
    reality)
      ask_valid sni 'REALITY 握手目标 SNI' "$old_sni" valid_domain || return 130
      target=$(jq -r .reality.server "$file"); target_port=$(jq -r .reality.port "$file")
      ask_valid target 'REALITY 握手目标地址' "${target:-$sni}" valid_address || return 130
      ask_valid target_port '目标握手端口' "$target_port" valid_port || return 130
      node_set "$file" '.endpoint.sni=$s|.reality={server:$h,port:$p}' --arg s "$sni" --arg h "$target" --argjson p "$((10#$target_port))" || return 1;;
    ss2022|snell|socks) ;;
    *)
      if [[ $mode == cdn ]]; then sni=$address
      else
        sni=$old_sni; [[ -n $sni ]] || { valid_domain "$address" && sni=$address; }
        ask_valid sni 'TLS 证书域名 / 客户端 SNI（必须与证书匹配）' "$sni" valid_domain || return 130
      fi
      change=yes
      if [[ -n $edit && $sni == "$old_sni" && $oldmode == "$mode" ]]; then
        ask change '替换证书？yes 替换；回车保留' no || return 130
      fi
      if [[ $change == yes ]]; then certificate_wizard "$file" "$sni" "$mode" || return $?; fi;;
  esac
  if is_ws "$preset"; then
    path=$(jq -r .ws_path "$file")
    ask_valid path 'WebSocket 路径（客户端和源站一致）' "$path" valid_path || return 130
    if [[ $mode == cdn ]]; then host=$address
    else
      host=$(jq -r .endpoint.host "$file")
      ask_valid host 'WebSocket Host' "${host:-$sni}" valid_domain || return 130
    fi
    node_set "$file" '.ws_path=$p|.endpoint.host=$h' --arg p "$path" --arg h "$host" || return 1
  fi
  if [[ -n $edit ]]; then
    ask change '重新生成认证信息（UUID / 密码 / REALITY 密钥）？yes 更新；回车保留' no || return 130
    if [[ $change == yes ]]; then
      new_node "$preset" "$id" "$port" "$address" "$public_port" > "$SB_TXN/auth.json" || return 1
      node_set "$file" '.auth=$n[0].auth' --slurpfile n "$SB_TXN/auth.json" || return 1
      rm -f "$SB_TXN/auth.json"
    fi
  fi
  say "$id / $preset / $mode"
  say "客户端 $address:$public_port → 监听 $listen:$port；SNI=${sni:-无}；Host=${host:-无}"
  [[ $mode != cdn ]] || say '请先完成 DNS、CDN、证书及源站端口映射；工具不代替 CDN 控制台配置。'
  if [[ -n $edit ]]; then put_node "$file" edit; else put_node "$file" add; fi
  local rc=$?; CREATED_NODE_ID=$id; rm -f "$file"; return "$rc"
}

create_wizard() {
  local choice token preset rc
  local -a selected=() presets=() created=()
  protocols | jq -r 'to_entries[]|"\(.key+1)) \(.value.name)"'
  say '0) 返回；空格/逗号多选；整批校验后统一保存。'
  ask choice '请选择协议' '' || return 130
  [[ -n $choice && $choice != 0 ]] || return 0
  choice=${choice//,/ }; choice=${choice//，/ }; read -r -a selected <<< "$choice"
  for token in "${selected[@]}"; do
    [[ $token =~ ^([1-9]|10|11)$ ]] || { err '无效协议序号。'; return 1; }
    preset=$(protocols | jq -r --argjson i "$token" '.[$i-1].id') || return 1
    presets+=("$preset")
  done
  txn_begin || return 1
  for preset in "${presets[@]}"; do
    node_wizard "$preset" || { rc=$?; txn_abort; return "$rc"; }
    created+=("$CREATED_NODE_ID")
  done
  confirm "保存以上 ${#presets[@]} 个节点" && txn_commit || { rc=$?; txn_abort; return "$rc"; }
  for token in "${created[@]}"; do show_links "$token" || return 1; done
}
