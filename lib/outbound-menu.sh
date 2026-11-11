# ================================================================
#  出站管理菜单 + 出口路由
# ================================================================

# ---------------- 通用序号选择 ----------------
# select_index_from <结果变量> <显示函数> <候选值...>
select_index_from() {
  local __result=$1
  local __display=$2
  shift 2
  local -a __values=("$@")
  local i n choice idx
  n=${#__values[@]}
  if [ "$n" -eq 0 ]; then
    error "没有可选项"
    return 1
  fi
  for ((i = 0; i < n; i++)); do
    "$__display" "$((i + 1))" "${__values[$i]}"
  done
  ask choice "请输入序号" ""
  if ! [[ $choice =~ ^[0-9]{1,4}$ ]]; then
    error "序号无效"
    return 1
  fi
  choice=$((10#$choice))
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "$n" ]; then
    error "序号无效"
    return 1
  fi
  printf -v "$__result" '%s' "${__values[$idx]}"
  return 0
}

# 输出所有出站名称(含 direct)
collect_outbound_tags() {
  local f
  printf 'direct\n'
  shopt -s nullglob
  for f in "$OUT_DIR"/*.json; do
    printf '%s\n' "$(basename "$f" .json)"
  done
  shopt -u nullglob
}

# 输出所有节点名称
collect_node_tags() {
  local f
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    printf '%s\n' "$(basename "$f" .json)"
  done
  shopt -u nullglob
}

_disp_outbound() {
  local i=$1 tag=$2 type='内置直连'
  [ "$tag" = "direct" ] || type=$(jq -r '.type // "?"' "$OUT_DIR/$tag.json" 2>/dev/null || echo '?')
  [ "$tag" = "direct" ] || type=$(outbound_type_display "$type")
  printf '%-4s %-26s %s\n' "$i" "$tag" "$type"
}

_disp_node() {
  local i=$1 tag=$2 proto
  proto=$(meta_get "$tag" proto)
  printf '%-4s %-30s %s\n' "$i" "$tag" "$(proto_display "$proto")"
}

select_outbound() {
  local -a tags=()
  mapfile -t tags < <(collect_outbound_tags)
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "---------------------------------------------------"
  select_index_from SELECTED_OUT _disp_outbound "${tags[@]}"
}

# 只列出真实出站（不含 direct），用于“绑定 / 修改出口”
select_outbound_real() {
  local -a tags=()
  mapfile -t tags < <(collect_outbound_tags)
  tags=("${tags[@]:1}")
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无自定义出站，请先在「出站管理」中新增"
    return 1
  fi
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "---------------------------------------------------"
  select_index_from SELECTED_OUT _disp_outbound "${tags[@]}"
}

select_node() {
  local -a tags=()
  mapfile -t tags < <(collect_node_tags)
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无节点"
    return 1
  fi
  printf '%-4s %-30s %s\n' "序号" "节点名称" "协议"
  printf '%s\n' "---------------------------------------------------------------"
  select_index_from SELECTED _disp_node "${tags[@]}"
}

_disp_node_route() {
  local i=$1
  local tag=$2
  local proto out
  proto=$(meta_get "$tag" proto)
  out=$(route_of_node "$tag")
  printf '%-4s %-30s %-22s %s\n' "$i" "$tag" "$(proto_display "$proto")" "$out"
}

# 多选节点：支持单个、多个、0=全部；回车取消
select_nodes_multi() {
  local -a tags=() tokens=() picks=()
  local i raw token dup bad
  SELECTED_NODES=()
  mapfile -t tags < <(collect_node_tags)
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无节点"
    return 1
  fi
  printf '%-4s %-30s %-22s %s\n' "序号" "节点名称" "协议" "当前出口"
  printf '%s\n' "-----------------------------------------------------------------------------------"
  for ((i = 0; i < ${#tags[@]}; i++)); do
    _disp_node_route "$((i + 1))" "${tags[$i]}"
  done
  while true; do
    ask raw "请输入序号（空格/逗号分隔，0=全部节点，回车取消）" ""
    [ -n "$raw" ] || { warn "已取消"; return 1; }
    raw=${raw//,/ }
    raw=${raw//，/ }
    raw=${raw//、/ }
    read -r -a tokens <<<"$raw"
    [ ${#tokens[@]} -eq 0 ] && { warn "请输入至少一个序号"; continue; }
    picks=()
    bad=""
    for token in "${tokens[@]}"; do
      if [ "$token" = "0" ]; then
        SELECTED_NODES=("${tags[@]}")
        return 0
      fi
      if ! [[ $token =~ ^[0-9]{1,4}$ ]]; then
        bad+=" $token"
        continue
      fi
      token=$((10#$token))
      if [ "$token" -lt 1 ] || [ "$token" -gt ${#tags[@]} ]; then
        bad+=" $token"
        continue
      fi
      dup=0
      for i in "${picks[@]:-}"; do
        [ "$i" = "$token" ] && dup=1
      done
      [ "$dup" -eq 0 ] && picks+=("$token")
    done
    if [ -n "$bad" ]; then
      warn "无效序号:$bad"
      continue
    fi
    if [ ${#picks[@]} -eq 0 ]; then
      warn "未选择有效节点"
      continue
    fi
    SELECTED_NODES=()
    for i in "${picks[@]}"; do
      SELECTED_NODES+=("${tags[$((i - 1))]}")
    done
    return 0
  done
}

# ---------------- 查看 ----------------
view_outbound() {
  select_outbound || { pause; return 0; }
  printf '==============================================\n'
  if [ "$SELECTED_OUT" = "direct" ]; then
    jq -n '{type:"direct",tag:"direct"}'
  else
    jq . "$OUT_DIR/$SELECTED_OUT.json"
  fi
  pause
}

delete_outbound() {
  local -a tags=()
  mapfile -t tags < <(collect_outbound_tags)
  if [ ${#tags[@]} -le 1 ]; then
    warn "暂无可删除的出站"
    pause
    return 0
  fi
  tags=("${tags[@]:1}")
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "---------------------------------------------------"
  if ! select_index_from SELECTED_OUT _disp_outbound "${tags[@]}"; then
    pause
    return 0
  fi
  local tag=$SELECTED_OUT removed=0 rf
  warn "即将删除出站 [$tag]"
  if ! confirm "确定删除?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  rm -f "$OUT_DIR/$tag.json"
  shopt -s nullglob
  for rf in "$ROUTE_DIR"/*.outbound; do
    if [ "$(head -n1 "$rf" 2>/dev/null || true)" = "$tag" ]; then
      rm -f "$rf"
      removed=$((removed + 1))
    fi
  done
  shopt -u nullglob
  [ "$removed" -gt 0 ] && warn "已清除 $removed 个节点对该出站的绑定，这些节点回到直连"
  info "出站 [$tag] 已删除"
  apply_changes
  pause
}

edit_outbound_file() {
  local file=$1 ed='' c
  [ -n "${EDITOR:-}" ] && ed=$EDITOR
  if [ -z "$ed" ]; then
    for c in nano vim vi; do
      command -v "$c" >/dev/null 2>&1 && { ed=$c; break; }
    done
  fi
  if [ -n "$ed" ]; then
    # shellcheck disable=SC2086
    $ed "$file"
  else
    warn "未找到文本编辑器，请手动编辑: $file"
    read -r -p "编辑保存后按回车继续校验..." _ || true
  fi
}

edit_outbound() {
  local -a tags=()
  mapfile -t tags < <(collect_outbound_tags)
  if [ ${#tags[@]} -le 1 ]; then
    warn "暂无可编辑的出站"
    pause
    return 0
  fi
  tags=("${tags[@]:1}")
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "---------------------------------------------------"
  select_index_from SELECTED_OUT _disp_outbound "${tags[@]}" || { pause; return 0; }

  local tag=$SELECTED_OUT
  local file="$OUT_DIR/$SELECTED_OUT.json"
  local backup="$OUT_DIR/$SELECTED_OUT.json.bak"
  local newtag
  cp -f "$file" "$backup" || { error "备份失败"; pause; return 0; }
  edit_outbound_file "$file"

  if ! jq -e 'type=="object" and (.tag|type=="string") and (.type|type=="string")' "$file" >/dev/null 2>&1; then
    error "JSON 校验失败，已恢复原配置"
    mv -f "$backup" "$file"
    pause
    return 0
  fi
  newtag=$(jq -r '.tag' "$file")
  if [ "$newtag" != "$tag" ]; then
    error "不允许修改 tag (${tag} -> ${newtag})，已恢复原配置"
    mv -f "$backup" "$file"
    pause
    return 0
  fi
  if ! apply_changes; then
    warn "配置校验失败，已恢复原配置"
    mv -f "$backup" "$file"
    rebuild_config >/dev/null 2>&1 || true
    pause
    return 0
  fi
  rm -f "$backup"
  info "出站 [$tag] 已更新"
  pause
}

# ================================================================
#  出口路由: 节点 -> 落地
# ================================================================
route_of_node() {
  local tag=$1
  if [ -s "$ROUTE_DIR/$tag.outbound" ]; then
    head -n1 "$ROUTE_DIR/$tag.outbound" 2>/dev/null || printf 'direct'
  else
    printf 'direct'
  fi
}

view_routes() {
  local -a tags=()
  mapfile -t tags < <(collect_node_tags)
  if [ ${#tags[@]} -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  local i tag proto out
  printf '%-4s %-28s %-22s %s\n' "序号" "节点名称" "协议" "出口"
  printf '%s\n' "-----------------------------------------------------------------------------------"
  for ((i = 0; i < ${#tags[@]}; i++)); do
    tag=${tags[$i]}
    proto=$(meta_get "$tag" proto)
    out=$(route_of_node "$tag")
    if [ "$out" != "direct" ] && [ ! -f "$OUT_DIR/$out.json" ]; then
      out="$out [缺失]"
    fi
    printf '%-4s %-28s %-22s %s\n' "$((i + 1))" "$tag" "$(proto_display "$proto")" "$out"
  done
  pause
}

set_route() {
  local tag=$1 out=$2
  mkdir -p "$ROUTE_DIR"
  if [ "$out" = "direct" ]; then
    rm -f "$ROUTE_DIR/$tag.outbound"
  else
    printf '%s\n' "$out" > "$ROUTE_DIR/$tag.outbound"
  fi
}

bind_nodes_route() {
  local -a nodes=()
  local out node
  select_nodes_multi || { pause; return 0; }
  nodes=("${SELECTED_NODES[@]}")
  select_outbound_real || { pause; return 0; }
  out=$SELECTED_OUT
  if ! confirm "将 ${#nodes[@]} 个节点的出口设置为 [$out]?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  for node in "${nodes[@]}"; do
    set_route "$node" "$out"
  done
  info "已设置 ${#nodes[@]} 个节点的出口为 [$out]"
  apply_changes
  pause
}

reset_nodes_direct() {
  local -a nodes=()
  local node count changed=0
  select_nodes_multi || { pause; return 0; }
  nodes=("${SELECTED_NODES[@]}")
  count=${#nodes[@]}
  for node in "${nodes[@]}"; do
    [ "$(route_of_node "$node")" = "direct" ] || changed=$((changed + 1))
  done
  if [ "$changed" -eq 0 ]; then
    info "所选节点都已经是直连"
    pause
    return 0
  fi
  if ! confirm "将 $count 个节点改为直连? 其中 $changed 个当前有出口绑定。" "n"; then
    info "已取消"
    pause
    return 0
  fi
  for node in "${nodes[@]}"; do
    set_route "$node" "direct"
  done
  info "已处理 $count 个节点，所选节点全部为直连"
  apply_changes
  pause
}

menu_routes() {
  local c
  while true; do
    printf '\n%s\n' "------------- 出口路由 -------------"
    printf ' 1) 查看节点出口\n'
    printf ' 2) 为节点绑定 / 修改出口\n'
    printf ' 3) 为节点取消 / 恢复直连\n'
    printf ' 0) 返回\n'
    ask c "请选择" ""
    case "$c" in
      1) view_routes ;;
      2) bind_nodes_route ;;
      3) reset_nodes_direct ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

menu_outbounds() {
  local c
  while true; do
    printf '\n%s\n' "------------- 出站管理 -------------"
    printf ' 1) 新增出站\n'
    printf ' 2) 查看出站\n'
    printf ' 3) 编辑出站\n'
    printf ' 4) 删除出站\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) menu_add_outbound; pause ;;
      2) view_outbound ;;
      3) edit_outbound ;;
      4) delete_outbound ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}
