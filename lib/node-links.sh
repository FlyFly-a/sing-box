# ================================================================
#  节点详情 / 分享链接
# ================================================================

uri_host() {
  case "${1:-}" in
    *:*) printf '[%s]' "$1" ;;
    *)   printf '%s' "${1:-}" ;;
  esac
}

# 输出单个节点的分享链接
print_node_link() {
  local tag=$1
  local ip_override=${2:-}
  local name="$tag${3:-}"
  local proto ip host port f obj
  local domain uuid pass method path pbk sid insecure psk
  local link userinfo payload tlsq

  proto=$(meta_get "$tag" proto)
  if ! proto_known "$proto"; then
    warn "节点 [$tag] 的协议 [${proto:-空}] 无法识别，请删除后重建"
    return 1
  fi

  f="$NODE_DIR/$tag.json"
  if [ ! -s "$f" ]; then
    error "节点文件不存在: $f"
    return 1
  fi

  if [ -n "$ip_override" ]; then
    ip=$ip_override
  else
    load_server_ip
    ip=${SERVER_IP:-}
  fi
  [ -n "$ip" ] || warn "未能获取公网 IP，请手动替换链接中的服务器地址"
  host=$(uri_host "$ip")
  insecure=$(meta_get "$tag" insecure)

  if ! obj=$(jq -c . "$f" 2>/dev/null); then
    error "节点配置不是合法 JSON: $f"
    return 1
  fi
  port=$(jq -r '.listen_port // empty' <<<"$obj")
  if [ -z "$port" ]; then
    error "节点配置缺少监听端口: $f"
    return 1
  fi

  case "$proto" in
    vless-reality-vision)
      uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      sid=$(jq -r '.tls.reality.short_id[0] // empty' <<<"$obj")
      pbk=$(meta_get "$tag" pbk)
      if [ -z "$uuid" ] || [ -z "$domain" ] || [ -z "$pbk" ]; then
        error "节点 [$tag] 缺少 UUID / SNI域名 / 公钥，无法生成链接"
        return 1
      fi
      link="vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlenc "$domain")&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#$(urlenc "$name")"
      ;;

    vless-ws)
      uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      path=$(jq -r '.transport.path // empty' <<<"$obj")
      tlsq=$(tls_query "$domain" "$insecure")
      link="vless://${uuid}@${host}:${port}?encryption=none&${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#$(urlenc "$name")"
      ;;

    vmess-ws)
      uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      path=$(jq -r '.transport.path // empty' <<<"$obj")
      payload=$(jq -cn --arg ps "$name" --arg add "$ip" --argjson port "$port" \
        --arg id "$uuid" --arg host "$domain" --arg path "$path" --arg sni "$domain" \
        --argjson insecure "$([ "$insecure" = "1" ] && printf true || printf false)" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,scy:"auto",
         net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni}
        + (if $insecure then {allowInsecure:true} else {} end)')
      link="vmess://$(printf '%s' "$payload" | base64 | tr -d '[:space:]')"
      ;;

    trojan)
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      tlsq=$(tls_query "$domain" "$insecure")
      link="trojan://$(urlenc "$pass")@${host}:${port}?${tlsq}&type=tcp#$(urlenc "$name")"
      ;;

    trojan-ws)
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      path=$(jq -r '.transport.path // empty' <<<"$obj")
      tlsq=$(tls_query "$domain" "$insecure")
      link="trojan://$(urlenc "$pass")@${host}:${port}?${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#$(urlenc "$name")"
      ;;

    shadowsocks-2022)
      method=$(jq -r '.method // empty' <<<"$obj")
      pass=$(jq -r '.password // empty' <<<"$obj")
      userinfo=$(b64url "$method:$pass")
      link="ss://${userinfo}@${host}:${port}#$(urlenc "$name")"
      ;;

    hysteria2)
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      link="hysteria2://$(urlenc "$pass")@${host}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#$(urlenc "$name")"
      ;;

    tuic)
      uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      link="tuic://${uuid}:$(urlenc "$pass")@${host}:${port}?alpn=h3&sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&allow_insecure=1"
      link="$link#$(urlenc "$name")"
      ;;

    anytls)
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      link="anytls://$(urlenc "$pass")@${host}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#$(urlenc "$name")"
      ;;

    socks5)
      userinfo=$(b64url "$(jq -r '.users[0].username // empty' <<<"$obj"):$(jq -r '.users[0].password // empty' <<<"$obj")")
      link="socks://${userinfo}@${host}:${port}#$(urlenc "$name")"
      ;;

    snell-v6)
      # Sub-Store 不支持 snell:// 输入，直接输出 Surge 格式
      psk=$(jq -r '.psk // empty' <<<"$obj")
      printf '%s = snell, %s, %s, psk=%s, version=6, mode=default, reuse=false\n' \
        "$name" "$ip" "$port" "$psk"
      return 0
      ;;

    *)
      warn "该协议暂不生成分享链接"
      return 0
      ;;
  esac

  printf '%s\n' "$link"
}

# 按环境输出一套或两套链接
print_node_links() {
  local tag=$1
  local ip4 ip6
  load_server_ip4
  ip4=${SERVER_IP4:-}
  ip6=''
  if [ "$NODE_LISTEN" = "::" ]; then
    load_server_ip6
    ip6=${SERVER_IP6:-}
  fi
  if [ -n "$ip4" ] && [ -n "$ip6" ]; then
    printf '# IPv4\n'
    print_node_link "$tag" "$ip4" "-v4"
    printf '# IPv6\n'
    print_node_link "$tag" "$ip6" "-v6"
    return 0
  fi
  if [ -n "$ip4" ]; then
    print_node_link "$tag" "$ip4"
    return 0
  fi
  if [ -n "$ip6" ]; then
    print_node_link "$tag" "$ip6"
    return 0
  fi
  print_node_link "$tag"
}

tls_query() {
  local domain=$1 insecure=$2
  local q="security=tls&sni=$(urlenc "$domain")"
  [ "$insecure" = "1" ] && q="$q&allowInsecure=1"
  printf '%s' "$q"
}

print_created_links() {
  local tag i=0
  [ ${#CREATED_TAGS[@]} -gt 0 ] || return 0
  printf '\n%s\n' "================ 新节点分享链接 ================"
  for tag in "${CREATED_TAGS[@]}"; do
    [ -f "$NODE_DIR/$tag.json" ] || continue
    i=$((i + 1))
    printf '\n[%s] %s  (%s)\n' "$i" "$tag" "$(proto_display "$(meta_get "$tag" proto)")"
    printf '%s\n' "--------------------------------------------------"
    print_node_links "$tag"
  done
  [ "$i" -gt 0 ] && printf '\n共 %s 个新节点\n' "$i"
  return 0
}

show_node_details() {
  local tag=$1
  printf '%s\n' "=============================================="
  printf '节点名称 : %s\n' "$tag"
  printf '协议类型 : %s\n' "$(proto_display "$(meta_get "$tag" proto)")"
  printf '配置路径 : %s\n' "$NODE_DIR/$tag.json"
  printf '%s\n' "=============================================="
  jq 'del(._meta)' "$NODE_DIR/$tag.json"
  printf '\n%s\n' "---------- 分享链接 / 客户端配置 ----------"
  print_node_links "$tag"
}

view_nodes() {
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点，请先新增节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  show_node_details "$SELECTED"
  pause
}

show_all_links() {
  local -a tags=()
  mapfile -t tags < <(collect_node_tags)
  if [ ${#tags[@]} -eq 0 ]; then
    warn "暂无节点，请先新增节点"
    pause
    return 0
  fi
  printf '%s\n' "================ 所有节点分享链接 ================"
  local i tag
  for ((i = 0; i < ${#tags[@]}; i++)); do
    tag=${tags[$i]}
    printf '\n[%s] %s  (%s)\n' "$((i + 1))" "$tag" "$(proto_display "$(meta_get "$tag" proto)")"
    printf '%s\n' "--------------------------------------------------"
    print_node_links "$tag"
  done
  printf '\n共 %s 个节点\n' "${#tags[@]}"
  pause
}

delete_node() {
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  local tag=$SELECTED
  warn "即将删除节点 [$tag]，此操作不可恢复"
  if ! confirm "确定删除该节点?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  rm -f "$NODE_DIR/$tag.json" "$NODE_DIR/$tag.meta" "$ROUTE_DIR/$tag.outbound"
  info "节点 [$tag] 已删除"
  apply_changes
  pause
}
