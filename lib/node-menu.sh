# ================================================================
#  节点菜单
# ================================================================
print_protocol_menu() {
  printf '%2d) %-22s %2d) %s\n' 1 'VLESS-Reality-Vision' 2 'VLESS-WS-TLS'
  printf '%2d) %-22s %2d) %s\n' 3 'Hysteria2' 4 'TUIC'
  printf '%2d) %-22s %2d) %s\n' 5 'Trojan-TLS' 6 'Trojan-WS-TLS'
  printf '%2d) %-22s %2d) %s\n' 7 'AnyTLS-TLS' 8 'Shadowsocks-2022'
  printf '%2d) %-22s %2d) %s\n' 9 'VMess-WS-TLS' 10 'Snell-v6'
  printf '%2d) %s\n' 11 'SOCKS5'
  printf '%2d) 返回\n' 0
}

protocol_display_name() {
  case "${1:-}" in
    1)  printf 'VLESS-Reality-Vision' ;;
    2)  printf 'VLESS-WS-TLS' ;;
    3)  printf 'Hysteria2' ;;
    4)  printf 'TUIC' ;;
    5)  printf 'Trojan-TLS' ;;
    6)  printf 'Trojan-WS-TLS' ;;
    7)  printf 'AnyTLS-TLS' ;;
    8)  printf 'Shadowsocks-2022' ;;
    9)  printf 'VMess-WS-TLS' ;;
    10) printf 'Snell-v6' ;;
    11) printf 'SOCKS5' ;;
    *)  printf 'NODE' ;;
  esac
}

# 左侧为节点 .meta 中保存的内部协议 ID，右侧为界面显示名称。
proto_meta_display() {
  case "${1:-}" in
    vless-reality-vision)   printf 'VLESS-Reality-Vision' ;;
    vless-ws-tls)           printf 'VLESS-WS-TLS' ;;
    hysteria2-quic)         printf 'Hysteria2' ;;
    tuic-quic)              printf 'TUIC' ;;
    trojan-tls)             printf 'Trojan-TLS' ;;
    trojan-ws-tls)          printf 'Trojan-WS-TLS' ;;
    anytls-tls)             printf 'AnyTLS-TLS' ;;
    shadowsocks-2022)       printf 'Shadowsocks-2022' ;;
    vmess-ws-tls)           printf 'VMess-WS-TLS' ;;
    snell-v6)               printf 'Snell-v6' ;;
    socks5)                 printf 'SOCKS5' ;;
    *)                      printf '%s' "${1:-未知}" ;;
  esac
}

protocol_needs_cert() {
  case "${1:-}" in
    2|3|4|5|6|7|9) return 0 ;;
    *) return 1 ;;
  esac
}

create_node_by_choice() {
  local choice=${1:-} loc name
  case "$choice" in
    1|2|3|4|5|6|7|8|9|10|11) ;;
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
    2)  create_vless_ws ;;
    3)  create_hysteria2 ;;
    4)  create_tuic ;;
    5)  create_trojan tcp ;;
    6)  create_trojan ws ;;
    7)  create_anytls ;;
    8)  create_ss2022 ;;
    9)  create_vmess ;;
    10) create_snell ;;
    11) create_socks5 ;;
  esac
}

parse_protocol_choices() {
  PROTOCOL_PICKS=()
  PROTOCOL_INVALID=""
  local raw token p dup add=0
  raw=$(printf '%s' "${1:-}" | tr ',' ' ' | tr '\n\t' '  ')
  raw=${raw//，/ }
  raw=${raw//、/ }
  for token in $raw; do
    case "$token" in
      0) return 1 ;;
    esac
    if ! [[ $token =~ ^[0-9]+$ ]]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    token=${token#"${token%%[!0]*}"}
    if [ -z "$token" ]; then
      return 1
    fi
    if [ "${#token}" -gt 2 ]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    if [ "$token" -lt 1 ] || [ "$token" -gt 11 ]; then
      PROTOCOL_INVALID+=" $token"
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
  CREATED_TAGS=()

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
  info "请为每个协议单独设置监听端口，直接回车使用随机监听端口"
  idx=0
  for p in "${picks[@]}"; do
    name=$(protocol_display_name "$p")
    case "$p" in
      3|4) transport="udp" ;;
      *)   transport="tcp" ;;
    esac
    while true; do
      ask v "[$((idx + 1))/${#picks[@]}] $name 监听端口（回车随机）" ""
      if [ -z "$v" ]; then
        v=$(random_free_port "$transport")
        printf '\n'
        info "  -> $name 使用随机监听端口: $v/$transport"
        break
      fi
      if ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
        warn "监听端口范围 1-65535"
        continue
      fi
      v=$((10#$v))
      if ! port_available "$v" "$transport"; then
        warn "监听端口 $v 已被同类型节点或系统服务占用，请更换"
        continue
      fi
      if port_in_batch "$v" "$transport"; then
        warn "监听端口 $v 已在本批次中使用，请更换"
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
        BATCH_REALITY_HSPORT=$((10#$BATCH_REALITY_HSPORT))
        break
      fi
      warn "回源端口无效，请输入 1-65535"
    done
    info "REALITY 回源端口: $BATCH_REALITY_HSPORT"
  fi

  info "UUID、密码、PSK 和传输路径将自动生成，监听端口使用上面的设置"
  BATCH_MODE=1
  idx=0
  for p in "${picks[@]}"; do
    name=$(protocol_display_name "$p")
    BATCH_TAG=$(make_batch_tag "$loc" "$name")
    BATCH_PORT=${BATCH_PORT_LIST[$idx]}
    printf '>>> 创建节点: %s (监听端口 %s/%s)\n' "$BATCH_TAG" "$BATCH_PORT" "${BATCH_PORT_TYPES[$idx]}"
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
}

menu_add_node() {
  local c rc
  CREATED_TAGS=()
  printf '%s\n' "------------- 新增节点 -------------"
  print_protocol_menu
  printf '%s\n' "(批量添加请用空格或逗号分隔，例如 1 3 10)"
  ask c "请选择协议" ""
  parse_protocol_choices "$c"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    if [ -n "$PROTOCOL_INVALID" ]; then
      warn "无效协议编号:${PROTOCOL_INVALID}"
    else
      warn "未选择有效协议"
    fi
    pause
    return 0
  fi
  if [ -n "$PROTOCOL_INVALID" ]; then
    warn "已忽略无效编号:${PROTOCOL_INVALID}"
  fi
  if [ ${#PROTOCOL_PICKS[@]} -eq 1 ]; then
    create_node_by_choice "${PROTOCOL_PICKS[0]}"
  else
    batch_create_nodes "${PROTOCOL_PICKS[@]}"
  fi
  print_created_links
  CREATED_TAGS=()
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
