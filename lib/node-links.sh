# ================================================================
#  节点查看 / 分享链接
# ================================================================
print_node_link() {
  local tag=$1 proto ip port f obj domain uuid pass method path svc pbk sid insecure
  local link userinfo payload net tlsf tlsq tagurl ssmethod sspass stpass hs inner outer client
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

  if [ "$proto" = "shadowtls" ]; then
    inner=$(jq -c '.[0]' "$f")
    outer=$(jq -c '.[1]' "$f")
    ssmethod=$(jq -r '.method // empty' <<<"$inner")
    sspass=$(jq -r '.password // empty' <<<"$inner")
    stpass=$(jq -r '.users[0].password // empty' <<<"$outer")
    hs=$(jq -r '.handshake.server // empty' <<<"$outer")
    port=$(jq -r '.listen_port' <<<"$outer")
    client=$(jq -n --arg ip "$ip" --argjson port "$port" --arg method "$ssmethod" \
      --arg sspass "$sspass" --arg stpass "$stpass" --arg hs "$hs" '
      {outbounds:[
        {type:"shadowsocks",tag:"proxy",server:"127.0.0.1",server_port:1080,
         method:$method,password:$sspass,detour:"shadowtls-out"},
        {type:"shadowtls",tag:"shadowtls-out",server:$ip,server_port:$port,version:3,
         password:$stpass,
         tls:{enabled:true,server_name:$hs,utls:{enabled:true,fingerprint:"chrome"}}}
      ]}')
    warn "ShadowTLS 没有通用的分享链接，请使用以下 sing-box 客户端出站配置："
    printf '%s\n' "$client" | jq .
    return 0
  fi

  obj=$(jq -c 'if type=="array" then .[-1] else . end' "$f")
  port=$(jq -r '.listen_port // empty' <<<"$obj")
  domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
  uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
  pass=$(jq -r '.users[0].password // .password // empty' <<<"$obj")
  method=$(jq -r '.method // empty' <<<"$obj")
  path=$(jq -r '.transport.path // empty' <<<"$obj")
  svc=$(jq -r '.transport.service_name // empty' <<<"$obj")
  pbk=$(meta_get "$tag" pbk)
  sid=$(jq -r '.tls.reality.short_id[0] // empty' <<<"$obj")
  tagurl=$(urlenc "$tag")

  tlsq="security=tls&sni=$(urlenc "$domain")"
  if [ "$insecure" = "1" ]; then
    tlsq="$tlsq&allowInsecure=1"
  fi

  case "$proto" in
    vless-reality)
      link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlenc "$domain")&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#${tagurl}"
      ;;
    vless-vision-tls)
      link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&${tlsq}&type=tcp#${tagurl}"
      ;;
    vless-tls)
      link="vless://${uuid}@${ip}:${port}?encryption=none&${tlsq}&type=tcp#${tagurl}"
      ;;
    vless-grpc-tls)
      link="vless://${uuid}@${ip}:${port}?encryption=none&${tlsq}&type=grpc&serviceName=$(urlenc "$svc")#${tagurl}"
      ;;
    vless-ws-tls)
      link="vless://${uuid}@${ip}:${port}?encryption=none&${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#${tagurl}"
      ;;
    vless-httpupgrade-tls)
      link="vless://${uuid}@${ip}:${port}?encryption=none&${tlsq}&type=httpupgrade&path=$(urlenc "$path")&host=$(urlenc "$domain")#${tagurl}"
      ;;
    trojan-tls)
      link="trojan://$(urlenc "$pass")@${ip}:${port}?${tlsq}&type=tcp#${tagurl}"
      ;;
    trojan-grpc-tls)
      link="trojan://$(urlenc "$pass")@${ip}:${port}?${tlsq}&type=grpc&serviceName=$(urlenc "$svc")#${tagurl}"
      ;;
    trojan-ws-tls)
      link="trojan://$(urlenc "$pass")@${ip}:${port}?${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#${tagurl}"
      ;;
    shadowsocks-aead|shadowsocks-2022-128|shadowsocks-2022-256)
      userinfo=$(b64url "$method:$pass")
      link="ss://${userinfo}@${ip}:${port}#${tagurl}"
      ;;
    hysteria2)
      link="hysteria2://$(urlenc "$pass")@${ip}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#${tagurl}"
      ;;
    tuic)
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
    vmess-tcp|vmess-tcp-tls|vmess-ws-tls|vmess-grpc-tls)
      net="tcp"
      tlsf=""
      path=""
      case "$proto" in
        vmess-tcp-tls)
          tlsf="tls"
          ;;
        vmess-ws-tls)
          net="ws"
          tlsf="tls"
          path=$(jq -r '.transport.path // empty' <<<"$obj")
          ;;
        vmess-grpc-tls)
          net="grpc"
          tlsf="tls"
          path=$(jq -r '.transport.service_name // empty' <<<"$obj")
          ;;
      esac
      payload=$(jq -cn --arg ps "$tag" --arg add "$ip" --argjson port "$port" \
        --arg id "$uuid" --arg net "$net" --arg host "$domain" --arg path "$path" \
        --arg tls "$tlsf" --arg sni "$domain" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,scy:"auto",
         net:$net,type:"none",host:$host,path:$path,tls:$tls,sni:$sni}')
      link="vmess://$(printf '%s' "$payload" | base64 | tr -d '\n')"
      ;;
    *)
      warn "该协议暂不生成分享链接，请参考上方 JSON 配置"
      return 0
      ;;
  esac

  printf '%s\n' "$link"
}

show_node_details() {
  local tag=$1 proto
  proto=$(meta_get "$tag" proto)
  printf '%s\n' "=============================================="
  printf '节点名称 : %s\n' "$tag"
  printf '协议类型 : %s\n' "${proto:-未知}"
  printf '配置路径 : %s\n' "$NODE_DIR/$tag.json"
  printf '%s\n' "=============================================="
  jq . "$NODE_DIR/$tag.json"
  printf '\n%s\n' "---------- 分享链接 / 客户端配置 ----------"
  print_node_link "$tag"
  if [ "$(meta_get "$tag" insecure)" = "1" ]; then
    warn "该节点使用自签证书，客户端需要开启“允许不安全连接”。"
  fi
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
    vless-reality)          create_vless_reality "$tag" ;;
    vless-vision-tls)       create_vless_tls vision "$tag" ;;
    vless-tls)              create_vless_tls plain "$tag" ;;
    vless-grpc-tls)         create_vless_grpc "$tag" ;;
    vless-ws-tls)           create_vless_ws "$tag" ;;
    vless-httpupgrade-tls)  create_vless_httpupgrade "$tag" ;;
    hysteria2)              create_hysteria2 "$tag" ;;
    tuic)                   create_tuic "$tag" ;;
    shadowsocks-aead)       create_ss aead "$tag" ;;
    shadowsocks-2022-128)   create_ss 2022-128 "$tag" ;;
    shadowsocks-2022-256)   create_ss 2022-256 "$tag" ;;
    shadowtls)              create_ss_shadowtls "$tag" ;;
    trojan-tls)             create_trojan tcp "$tag" ;;
    trojan-grpc-tls)        create_trojan grpc "$tag" ;;
    trojan-ws-tls)          create_trojan ws "$tag" ;;
    vmess-tcp)              create_vmess 0 tcp "$tag" ;;
    vmess-tcp-tls)          create_vmess 1 tcp "$tag" ;;
    vmess-ws-tls)           create_vmess 1 ws "$tag" ;;
    vmess-grpc-tls)         create_vmess 1 grpc "$tag" ;;
    anytls-tls)             create_anytls "$tag" ;;
    socks5)                 create_socks "$tag" ;;
    *)
      warn "未知协议类型: ${proto:-空}，无法编辑"
      pause
      ;;
  esac
  EXCLUDE_TAG=""
  pause
}

