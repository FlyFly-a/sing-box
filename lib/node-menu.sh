# ================================================================
#  节点菜单
# ================================================================
print_protocol_menu() {
  printf ' 1) VLESS-REALITY          2) VLESS-Vision-TLS\n'
  printf ' 3) VLESS-TLS              4) VLESS-gRPC-TLS\n'
  printf ' 5) VLESS-WS-TLS           6) VLESS-HTTPUpgrade-TLS\n'
  printf ' 7) Hysteria2-QUIC         8) TUIC-QUIC\n'
  printf ' 9) Shadowsocks-AEAD      10) Shadowsocks-2022-128\n'
  printf '11) Shadowsocks-2022-256  12) Shadowsocks-ShadowTLS\n'
  printf '13) Trojan-TLS            14) Trojan-gRPC-TLS\n'
  printf '15) Trojan-WS-TLS         16) VMess-TCP\n'
  printf '17) VMess-TCP-TLS         18) VMess-WS-TLS\n'
  printf '19) VMess-gRPC-TLS        20) AnyTLS-TLS\n'
  printf '21) SOCKS5\n'
  printf ' 0) 返回\n'
}

protocol_display_name() {
  case "${1:-}" in
    1)  printf 'VLESS-REALITY' ;;
    2)  printf 'VLESS-Vision-TLS' ;;
    3)  printf 'VLESS-TLS' ;;
    4)  printf 'VLESS-gRPC-TLS' ;;
    5)  printf 'VLESS-WS-TLS' ;;
    6)  printf 'VLESS-HTTPUpgrade-TLS' ;;
    7)  printf 'Hysteria2-QUIC' ;;
    8)  printf 'TUIC-QUIC' ;;
    9)  printf 'Shadowsocks-AEAD' ;;
    10) printf 'Shadowsocks-2022-128' ;;
    11) printf 'Shadowsocks-2022-256' ;;
    12) printf 'Shadowsocks-ShadowTLS' ;;
    13) printf 'Trojan-TLS' ;;
    14) printf 'Trojan-gRPC-TLS' ;;
    15) printf 'Trojan-WS-TLS' ;;
    16) printf 'VMess-TCP' ;;
    17) printf 'VMess-TCP-TLS' ;;
    18) printf 'VMess-WS-TLS' ;;
    19) printf 'VMess-gRPC-TLS' ;;
    20) printf 'AnyTLS-TLS' ;;
    21) printf 'SOCKS5' ;;
    *)  printf 'NODE' ;;
  esac
}

proto_meta_display() {
  case "${1:-}" in
    vless-reality)            printf 'VLESS-REALITY' ;;
    vless-vision-tls)         printf 'VLESS-Vision-TLS' ;;
    vless-tls)                printf 'VLESS-TLS' ;;
    vless-grpc-tls)           printf 'VLESS-gRPC-TLS' ;;
    vless-ws-tls)             printf 'VLESS-WS-TLS' ;;
    vless-httpupgrade-tls)    printf 'VLESS-HTTPUpgrade-TLS' ;;
    hysteria2)                printf 'Hysteria2-QUIC' ;;
    tuic)                     printf 'TUIC-QUIC' ;;
    shadowsocks-aead)         printf 'Shadowsocks-AEAD' ;;
    shadowsocks-2022-128)     printf 'Shadowsocks-2022-128' ;;
    shadowsocks-2022-256)     printf 'Shadowsocks-2022-256' ;;
    shadowtls)                printf 'Shadowsocks-ShadowTLS' ;;
    trojan-tls)               printf 'Trojan-TLS' ;;
    trojan-grpc-tls)          printf 'Trojan-gRPC-TLS' ;;
    trojan-ws-tls)            printf 'Trojan-WS-TLS' ;;
    vmess-tcp)                printf 'VMess-TCP' ;;
    vmess-tcp-tls)            printf 'VMess-TCP-TLS' ;;
    vmess-ws-tls)             printf 'VMess-WS-TLS' ;;
    vmess-grpc-tls)           printf 'VMess-gRPC-TLS' ;;
    anytls-tls)               printf 'AnyTLS-TLS' ;;
    socks5)                   printf 'SOCKS5' ;;
    *)                        printf '%s' "${1:-未知}" ;;
  esac
}

protocol_needs_cert() {
  case "${1:-}" in
    2|3|4|5|6|7|8|13|14|15|17|18|19|20) return 0 ;;
    *) return 1 ;;
  esac
}

create_node_by_choice() {
  local choice=${1:-} loc name
  case "$choice" in
    1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21) ;;
    0) return 0 ;;
    *) warn "无效选项"; return 1 ;;
  esac

  if [ "${BATCH_MODE:-0}" != "1" ]; then
    name=$(protocol_display_name "$choice")
    info "正在获取服务器国家码 ..."
    loc=$(get_server_country_code)
    info "服务器国家码: $loc"
    AUTO_TAG_DEFAULT=$(make_batch_tag "$loc" "$name")
  fi

  case "$choice" in
    1)  create_vless_reality ;;
    2)  create_vless_tls vision ;;
    3)  create_vless_tls plain ;;
    4)  create_vless_grpc ;;
    5)  create_vless_ws ;;
    6)  create_vless_httpupgrade ;;
    7)  create_hysteria2 ;;
    8)  create_tuic ;;
    9)  create_ss aead ;;
    10) create_ss 2022-128 ;;
    11) create_ss 2022-256 ;;
    12) create_ss_shadowtls ;;
    13) create_trojan tcp ;;
    14) create_trojan grpc ;;
    15) create_trojan ws ;;
    16) create_vmess 0 tcp ;;
    17) create_vmess 1 tcp ;;
    18) create_vmess 1 ws ;;
    19) create_vmess 1 grpc ;;
    20) create_anytls ;;
    21) create_socks ;;
  esac
}

parse_protocol_choices() {
  PROTOCOL_PICKS=()
  local raw token p dup add=0
  raw=$(printf '%s' "${1:-}" | tr ',' ' ' | tr '\n\t' '  ')
  raw=${raw//，/ }
  raw=${raw//、/ }
  for token in $raw; do
    case "$token" in
      0) return 1 ;;
    esac
    if ! [[ $token =~ ^[0-9]+$ ]]; then
      continue
    fi
    if [ "$token" -lt 1 ] || [ "$token" -gt 21 ]; then
      continue
    fi
    dup=0
    if [ ${#PROTOCOL_PICKS[@]} -gt 0 ]; then
      for p in "${PROTOCOL_PICKS[@]}"; do
        if [ "$p" = "$token" ]; then
          dup=1
          break
        fi
      done
    fi
    if [ "$dup" -eq 0 ]; then
      PROTOCOL_PICKS+=("$token")
      add=1
    fi
  done
  if [ "$add" -eq 1 ]; then
    return 0
  fi
  return 2
}

make_batch_tag() {
  local loc=$1 name=$2 base t n=2
  base="${loc}-${name}"
  t=$base
  while [ -e "$NODE_DIR/$t.json" ] || [ -e "$OUT_DIR/$t.json" ]; do
    t="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$t"
}

batch_create_nodes() {
  local p need_cert=0 need_domain=0 has_reality=0 ok=0 fail=0 loc name detected
  local idx=0 transport v
  local -a picks=()

  if [ "$#" -gt 0 ]; then
    picks=("$@")
  elif [ ${#PROTOCOL_PICKS[@]} -gt 0 ]; then
    picks=("${PROTOCOL_PICKS[@]}")
  else
    warn "未选择有效协议"
    return 1
  fi

  printf '%s\n' "------------- 批量新增节点 -------------"
  info "共选择 ${#picks[@]} 个协议: ${picks[*]}"
  info "正在获取服务器国家码 ..."
  detected=$(get_server_country_code)
  info "服务器国家码: $detected"
  ask loc "节点名称前缀（两位国家码，如 JP/US/SG）" "$detected"
  loc=$(normalize_country_code "$loc")
  if [ "$loc" = "XX" ]; then
    warn "国家码格式不正确，使用检测结果: $detected"
    loc=$detected
  fi

  for p in "${picks[@]}"; do
    if protocol_needs_cert "$p"; then
      need_cert=1
      need_domain=1
    fi
    if [ "$p" = "1" ]; then
      has_reality=1
      need_domain=1
    fi
  done

  BATCH_DOMAIN=""
  if [ "$need_domain" -eq 1 ]; then
    if [ "$need_cert" -eq 1 ] && [ "$has_reality" -eq 1 ]; then
      info "所选 TLS 节点和 REALITY 节点将共用同一伪装域名"
    elif [ "$need_cert" -eq 1 ]; then
      info "所选 TLS 节点将共用同一伪装域名"
    else
      info "REALITY 节点将使用该域名作为伪装域名"
    fi
    if [ "$need_cert" -eq 1 ]; then
      info "真实证书请放到 $CERT_DIR/<域名>.crt 和 <域名>.key；找不到时自动生成自签证书"
    fi
    while [ -z "$BATCH_DOMAIN" ]; do
      ask BATCH_DOMAIN "伪装域名" ""
      if [ -z "$BATCH_DOMAIN" ]; then
        warn "伪装域名不能为空"
        continue
      fi
      if ! [[ $BATCH_DOMAIN =~ ^[A-Za-z0-9.*_-]+$ ]]; then
        warn "域名格式不正确"
        BATCH_DOMAIN=""
      fi
    done
  fi

  BATCH_PORT_LIST=()
  BATCH_PORT_TYPES=()
  info "请为每个协议单独设置监听端口，直接回车使用随机端口"
  idx=0
  for p in "${picks[@]}"; do
    name=$(protocol_display_name "$p")
    case "$p" in
      7|8) transport="udp" ;;
      *)   transport="tcp" ;;
    esac
    while true; do
      ask v "[$((idx + 1))/${#picks[@]}] $name 监听端口（回车随机）" ""
      if [ -z "$v" ]; then
        v=$(random_free_port "$transport")
        printf '\n'
        info "  -> $name 使用随机端口: $v/$transport"
        break
      fi
      if ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
        warn "端口范围 1-65535"
        continue
      fi
      if port_in_use "$v" "$transport"; then
        warn "端口 $v 已被同类型节点占用，请更换"
        continue
      fi
      if port_in_batch "$v" "$transport"; then
        warn "端口 $v 已在本批次中使用，请更换"
        continue
      fi
      break
    done
    BATCH_PORT_LIST+=("$v")
    BATCH_PORT_TYPES+=("$transport")
    idx=$((idx + 1))
  done

  BATCH_REALITY_SNI=""
  BATCH_REALITY_HSPORT=""
  if [ "$has_reality" -eq 1 ]; then
    BATCH_REALITY_SNI=$BATCH_DOMAIN
    BATCH_REALITY_HSPORT=443
    while true; do
      ask BATCH_REALITY_HSPORT "REALITY 回源端口 (伪装站点端口)" "443"
      printf '\n'
      if [[ $BATCH_REALITY_HSPORT =~ ^[0-9]+$ ]] && \
         [ "$BATCH_REALITY_HSPORT" -ge 1 ] && [ "$BATCH_REALITY_HSPORT" -le 65535 ]; then
        break
      fi
      warn "回源端口无效，请输入 1-65535"
    done
    info "REALITY 回源端口: $BATCH_REALITY_HSPORT"
  fi

  info "UUID、密码和传输路径将自动生成，监听端口使用上面的设置"
  BATCH_MODE=1
  idx=0
  for p in "${picks[@]}"; do
    name=$(protocol_display_name "$p")
    BATCH_TAG=$(make_batch_tag "$loc" "$name")
    BATCH_PORT=${BATCH_PORT_LIST[$idx]}
    printf '>>> 创建节点: %s (端口 %s/%s)\n' "$BATCH_TAG" "$BATCH_PORT" "${BATCH_PORT_TYPES[$idx]}"
    if create_node_by_choice "$p"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      warn "协议 [$name] 创建失败"
    fi
    BATCH_PORT=""
    idx=$((idx + 1))
  done
  BATCH_MODE=0
  BATCH_TAG=""
  BATCH_DOMAIN=""
  BATCH_REALITY_SNI=""
  BATCH_REALITY_HSPORT=""
  BATCH_PORT=""
  BATCH_PORT_LIST=()
  BATCH_PORT_TYPES=()

  if [ "$ok" -gt 0 ]; then
    info "批量创建完成: 成功 $ok 个，失败 $fail 个"
    apply_changes
  else
    error "没有节点创建成功"
  fi
  pause
}

menu_add_node() {
  local c rc
  printf '%s\n' "------------- 新增节点 -------------"
  print_protocol_menu
  printf '%s\n' "(批量添加请用空格或逗号分隔，例如 1 7 20)"
  ask c "请选择协议" ""
  parse_protocol_choices "$c"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    warn "未选择有效协议"
    pause
    return 0
  fi
  if [ ${#PROTOCOL_PICKS[@]} -eq 1 ]; then
    create_node_by_choice "${PROTOCOL_PICKS[0]}"
  else
    batch_create_nodes "${PROTOCOL_PICKS[@]}"
  fi
  pause
}

menu_nodes() {
  local c
  while true; do
    printf '\n%s\n' "------------- 节点管理 -------------"
    printf ' 1) 新增节点\n'
    printf ' 2) 删除节点\n'
    printf ' 3) 编辑节点\n'
    printf ' 4) 查看节点\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) menu_add_node ;;
      2) delete_node ;;
      3) edit_node ;;
      4) view_nodes ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}
