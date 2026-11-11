# ================================================================
#  节点管理菜单
# ================================================================

# 按协议 ID 分派创建函数
create_node_by_id() {
  local id=$1
  case "$id" in
    vless-reality-vision) create_vless_reality ;;
    vless-ws)             create_vless_ws ;;
    hysteria2)            create_hysteria2 ;;
    tuic)                 create_tuic ;;
    trojan)               create_trojan tcp ;;
    trojan-ws)            create_trojan ws ;;
    anytls)               create_anytls ;;
    shadowsocks-2022)     create_ss2022 ;;
    vmess-ws)             create_vmess ;;
    snell-v6)             create_snell ;;
    socks5)               create_socks5 ;;
    *)
      error "未知协议: $id"
      return 1
      ;;
  esac
}

# 解析协议编号输入，支持空格/逗号分隔的批量
# 结果写入 PROTOCOL_PICKS, 无效项写入 PROTOCOL_INVALID
# 返回 0=有有效项 1=取消 2=无有效项
parse_protocol_choices() {
  PROTOCOL_PICKS=()
  PROTOCOL_INVALID=""
  local raw token i dup add=0 n
  local -a tokens=()
  n=$(proto_count)

  raw=$(printf '%s' "${1:-}" | tr ',' ' ' | tr '\n\t' '  ')
  raw=${raw//，/ }
  raw=${raw//、/ }
  read -r -a tokens <<<"$raw"
  [ ${#tokens[@]} -eq 0 ] && return 2

  for token in "${tokens[@]}"; do
    [ "$token" = "0" ] && return 1
    if ! [[ $token =~ ^[0-9]{1,3}$ ]]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    token=$((10#$token))
    if [ "$token" -lt 1 ] || [ "$token" -gt "$n" ]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    dup=0
    for i in "${PROTOCOL_PICKS[@]:-}"; do
      [ "$i" = "$token" ] && dup=1
    done
    if [ "$dup" -eq 0 ]; then
      PROTOCOL_PICKS+=("$token")
      add=1
    fi
  done
  [ "$add" -eq 1 ] && return 0
  return 2
}

# ---------------- 单节点创建 ----------------
create_single_node() {
  local idx=$1 id name loc
  id=$(proto_id_by_index "$idx") || return 1
  name=$(proto_name_by_index "$idx")

  info "正在获取服务器国家码 ..."
  loc=$(get_server_country_code)
  info "服务器国家码: $loc"

  reset_wizard
  WIZ_TAG=$(make_node_tag "$loc" "$name")
  create_node_by_id "$id"
}

# ---------------- 批量创建 ----------------
batch_create_nodes() {
  local -a picks=("$@")
  local idx id name transport port v loc ok=0 fail=0
  local need_sni=0 need_reality_port=0

  reset_wizard
  reset_batch
  CREATED_TAGS=()

  printf '%s\n' "------------- 批量新增节点 -------------"
  info "共选择 ${#picks[@]} 个协议"

  info "正在获取服务器国家码 ..."
  loc=$(get_server_country_code)
  info "服务器国家码: $loc"
  ask loc "节点名称前缀（两位国家码）" "$loc"
  loc=$(normalize_country_code "$loc")

  # 汇总需要的共享参数
  for idx in "${picks[@]}"; do
    id=$(proto_id_by_index "$idx")
    proto_needs_sni "$id" && need_sni=1
    proto_needs_reality_port "$id" && need_reality_port=1
  done

  BATCH_SNI=""
  if [ "$need_sni" -eq 1 ]; then
    info "所选节点共用同一 SNI域名"
    while true; do
      ask BATCH_SNI "SNI域名" ""
      valid_sni "$BATCH_SNI" && break
      warn "SNI域名不能为空，且只能包含字母、数字、点、下划线和短横线"
      BATCH_SNI=""
    done
  fi

  BATCH_REALITY_PORT=""
  if [ "$need_reality_port" -eq 1 ]; then
    while true; do
      ask BATCH_REALITY_PORT "回源端口" "443"
      valid_port "$BATCH_REALITY_PORT" && { BATCH_REALITY_PORT=$((10#$BATCH_REALITY_PORT)); break; }
      warn "回源端口范围 1-65535"
      BATCH_REALITY_PORT=""
    done
  fi

  # 逐个询问监听端口，避免批次内冲突
  info "请依次设置各协议的监听端口，直接回车使用随机端口"
  idx=0
  for id in "${picks[@]}"; do
    idx=$((idx + 1))
    name=$(proto_name_by_index "$id")
    transport=$(proto_transport "$(proto_id_by_index "$id")")
    while true; do
      ask v "[$idx/${#picks[@]}] $name 监听端口（回车随机）" ""
      if [ -z "$v" ]; then
        v=$(random_free_port "$transport")
        printf '\n'
        info "  -> $name 使用随机监听端口: $v/$(transport_label "$transport")"
        break
      fi
      if ! valid_port "$v"; then
        warn "监听端口范围 1-65535"
        continue
      fi
      v=$((10#$v))
      if system_port_in_use "$v" "$transport"; then
        warn "监听端口 $v 已被系统服务占用，请更换"
        continue
      fi
      if node_port_in_use "$v" "$transport"; then
        warn "监听端口 $v 已被其他节点占用，请更换"
        continue
      fi
      if batch_port_in_use "$v" "$transport"; then
        warn "监听端口 $v 已在本批次中使用，请更换"
        continue
      fi
      break
    done
    BATCH_PORT_LIST+=("$v")
    BATCH_PORT_TYPES+=("$transport")
  done

  info "UUID、密码、PSK 和路径将自动生成"
  BATCH_MODE=1
  idx=0
  for id in "${picks[@]}"; do
    name=$(proto_name_by_index "$id")
    id=$(proto_id_by_index "$id")
    BATCH_TAG=$(make_node_tag "$loc" "$name")
    BATCH_PORT=${BATCH_PORT_LIST[$idx]}
    printf '>>> 创建节点: %s (监听端口 %s/%s)\n' \
      "$BATCH_TAG" "$BATCH_PORT" "$(transport_label "${BATCH_PORT_TYPES[$idx]}")"
    if create_node_by_id "$id"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      warn "协议 [$name] 创建失败"
    fi
    idx=$((idx + 1))
  done

  reset_batch
  reset_wizard

  if [ "$ok" -gt 0 ]; then
    info "批量创建完成: 成功 $ok 个，失败 $fail 个"
    apply_changes || error "配置校验失败，请检查刚创建的节点"
  else
    error "没有节点创建成功"
  fi
}

# ---------------- 菜单 ----------------
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
  [ -n "$PROTOCOL_INVALID" ] && warn "已忽略无效编号:${PROTOCOL_INVALID}"

  if [ ${#PROTOCOL_PICKS[@]} -eq 1 ]; then
    create_single_node "${PROTOCOL_PICKS[0]}" || warn "节点创建未完成，请检查上方错误"
    print_created_links
    apply_changes
  else
    batch_create_nodes "${PROTOCOL_PICKS[@]}"
    print_created_links
  fi

  CREATED_TAGS=()
  pause
}

edit_node() {
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  local tag=$SELECTED id
  id=$(meta_get "$tag" proto)
  if ! proto_known "$id"; then
    warn "节点 [$tag] 的协议 [${id:-空}] 无法识别，请删除后重建"
    pause
    return 0
  fi
  warn "编辑会覆盖节点 [$tag] 的现有配置"
  if ! confirm "继续编辑?" "n"; then
    info "已取消"
    pause
    return 0
  fi

  reset_wizard
  reset_batch
  WIZ_EDIT_TAG=$tag
  create_node_by_id "$id"
  WIZ_EDIT_TAG=""
  reset_wizard
  apply_changes
  pause
}

menu_nodes() {
  local c
  while true; do
    printf '\n%s\n' "------------- 节点管理 -------------"
    printf ' 1) 新增节点\n'
    printf ' 2) 查看节点 / 分享链接\n'
    printf ' 3) 编辑节点\n'
    printf ' 4) 删除节点\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) menu_add_node ;;
      2) view_nodes ;;
      3) edit_node ;;
      4) delete_node ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}
