# ================================================================
#  节点查看 / 分享链接
# ================================================================
print_node_link() {
  local tag=$1 proto ip port f obj domain uuid pass method path pbk sid insecure
  local link userinfo payload tlsq tagurl psk
  proto=$(meta_get "$tag" proto)
  ip=$(get_server_ip)
  insecure=$(meta_get "$tag" insecure)
  f="$NODE_DIR/$tag.json"
  if [ ! -s "$f" ]; then
    error "节点文件不存在: $f"
    return 1
  fi
  if [ -z "$ip" ]; then
    warn "未能获取公网 IP，请手动替换链接中的服务器地址"
  fi

  obj=$(jq -c . "$f")
  port=$(jq -r '.listen_port // empty' <<<"$obj")
  domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
  uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
  pass=$(jq -r '.users[0].password // .password // empty' <<<"$obj")
  method=$(jq -r '.method // empty' <<<"$obj")
  path=$(jq -r '.transport.path // empty' <<<"$obj")
  pbk=$(meta_get "$tag" pbk)
  sid=$(jq -r '.tls.reality.short_id[0] // empty' <<<"$obj")
  tagurl=$(urlenc "$tag")

  if [ "$proto" = "snell-v6" ]; then
    psk=$(jq -r '.psk // empty' <<<"$obj")
    link="snell://$(urlenc "$psk")@${ip}:${port}?version=6&mode=default#${tagurl}"
    printf '%s\n' "$link"
    printf '\n%s\n' "Sub-Store / Surge:"
    printf '%s = snell, %s, %s, psk=%s, version=6, mode=default, reuse=false\n' \
      "$tag" "$ip" "$port" "$psk"
    return 0
  fi

  tlsq="security=tls&sni=$(urlenc "$domain")"
  if [ "$insecure" = "1" ]; then
    tlsq="$tlsq&allowInsecure=1"
  fi

  case "$proto" in
    vless-reality-vision)
      link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlenc "$domain")&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#${tagurl}"
      ;;
    vless-ws-tls)
      link="vless://${uuid}@${ip}:${port}?encryption=none&${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#${tagurl}"
      ;;
    trojan-tls)
      link="trojan://$(urlenc "$pass")@${ip}:${port}?${tlsq}&type=tcp#${tagurl}"
      ;;
    trojan-ws-tls)
      link="trojan://$(urlenc "$pass")@${ip}:${port}?${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#${tagurl}"
      ;;
    shadowsocks-2022)
      userinfo=$(b64url "$method:$pass")
      link="ss://${userinfo}@${ip}:${port}#${tagurl}"
      ;;
    hysteria2-quic)
      link="hysteria2://$(urlenc "$pass")@${ip}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#${tagurl}"
      ;;
    tuic-quic)
      link="tuic://${uuid}:$(urlenc "$pass")@${ip}:${port}?congestion_control=bbr&alpn=h3&sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&allow_insecure=1"
      link="$link#${tagurl}"
      ;;
    anytls-tls)
      link="anytls://$(urlenc "$pass")@${ip}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#${tagurl}"
      ;;
    socks5)
      userinfo=$(b64url "$(jq -r '.users[0].username // empty' <<<"$obj"):$(jq -r '.users[0].password // empty' <<<"$obj")")
      link="socks://${userinfo}@${ip}:${port}#${tagurl}"
      ;;
    vmess-ws-tls)
      payload=$(jq -cn --arg ps "$tag" --arg add "$ip" --argjson port "$port" \
        --arg id "$uuid" --arg host "$domain" --arg path "$path" --arg sni "$domain" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,scy:"auto",
         net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni}')
      link="vmess://$(printf '%s' "$payload" | base64 | tr -d '\n')"
      ;;
    *)
      warn "该协议暂不生成分享链接，请参考上方 JSON 配置"
      return 0
      ;;
  esac

  printf '%s\n' "$link"
}

print_created_links() {
  local tag display i=0
  [ ${#CREATED_TAGS[@]} -gt 0 ] || return 0
  printf '\n%s\n' "================ 新节点分享链接 ================"
  for tag in "${CREATED_TAGS[@]}"; do
    [ -f "$NODE_DIR/$tag.json" ] || continue
    i=$((i + 1))
    display=$(proto_meta_display "$(meta_get "$tag" proto)")
    printf '\n[%s] %s  (%s)\n' "$i" "$tag" "$display"
    printf '%s\n' "--------------------------------------------------"
    print_node_link "$tag"
  done
  [ "$i" -gt 0 ] && printf '\n共 %s 个新节点\n' "$i"
}

show_node_details() {
  local tag=$1 proto
  proto=$(meta_get "$tag" proto)
  printf '%s\n' "=============================================="
  printf '节点名称 : %s\n' "$tag"
  printf '协议类型 : %s\n' "$(proto_meta_display "$proto")"
  printf '配置路径 : %s\n' "$NODE_DIR/$tag.json"
  printf '%s\n' "=============================================="
  jq . "$NODE_DIR/$tag.json"
  printf '\n%s\n' "---------- 分享链接 / 客户端配置 ----------"
  print_node_link "$tag"
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
  local f tag proto display count=0 i=0
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点，请先新增节点"
    pause
    return 0
  fi
  printf '%s\n' "================ 所有节点分享链接 ================"
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tag=$(basename "$f" .json)
    proto=$(meta_get "$tag" proto)
    display=$(proto_meta_display "$proto")
    i=$((i + 1))
    printf '\n[%s] %s  (%s)\n' "$i" "$tag" "$display"
    printf '%s\n' "--------------------------------------------------"
    print_node_link "$tag"
    count=$((count + 1))
  done
  shopt -u nullglob
  printf '\n共 %s 个节点\n' "$count"
  pause
}

delete_node() {
  local tag
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  tag=$SELECTED
  warn "即将删除节点 [$tag]，此操作不可恢复"
  if ! confirm "确定删除该节点?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  rm -f "$NODE_DIR/$tag.json" "$NODE_DIR/$tag.meta" "$SB_DIR/routes/$tag.outbound"
  info "节点 [$tag] 已删除"
  apply_changes
  pause
}

edit_node() {
  local tag proto
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  tag=$SELECTED
  proto=$(meta_get "$tag" proto)
  warn "编辑会覆盖节点 [$tag] 的现有配置"
  if ! confirm "继续编辑?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  EXCLUDE_TAG="$tag"
  case "$proto" in
    vless-reality-vision)  create_vless_reality "$tag" ;;
    vless-ws-tls)          create_vless_ws "$tag" ;;
    hysteria2-quic)        create_hysteria2 "$tag" ;;
    tuic-quic)             create_tuic "$tag" ;;
    trojan-tls)            create_trojan tcp "$tag" ;;
    trojan-ws-tls)         create_trojan ws "$tag" ;;
    anytls-tls)            create_anytls "$tag" ;;
    shadowsocks-2022)      create_ss2022 "$tag" ;;
    vmess-ws-tls)          create_vmess "$tag" ;;
    snell-v6)              create_snell "$tag" ;;
    socks5)                create_socks5 "$tag" ;;
    *)
      warn "未知协议类型: ${proto:-空}，无法编辑"
      pause
      ;;
  esac
  EXCLUDE_TAG=""
  pause
}
