# ================================================================
#  出站查看、选择、删除、编辑与菜单
# ================================================================
# ---------------- 出站查看 / 选择 ----------------
list_outbounds_table() {
  local f final tag type i=0 mark
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  printf '%-4s %-26s %-18s %s\n' "序号" "出站名称" "类型" "备注"
  printf '%s\n' "----------------------------------------------------------------"
  i=$((i+1))
  mark=""
  [ "$final" = "direct" ] && mark="<- 默认"
  printf '%-4s %-26s %-18s %s\n' "$i" "direct" "内置直连" "$mark"
  shopt -s nullglob
  for f in "$OUT_DIR"/*.json; do
    i=$((i+1))
    tag=$(basename "$f" .json)
    type=$(jq -r '.type // "?"' "$f" 2>/dev/null || echo '?')
    mark=""
    [ "$final" = "$tag" ] && mark="<- 默认"
    printf '%-4s %-26s %-18s %s\n' "$i" "$tag" "$type" "$mark"
  done
  shopt -u nullglob
}

select_outbound() {
  local -a tags=("direct")
  local f choice idx
  shopt -s nullglob
  for f in "$OUT_DIR"/*.json; do
    tags+=("$(basename "$f" .json)")
  done
  shopt -u nullglob
  list_outbounds_table
  ask choice "请输入序号" ""
  if ! [[ $choice =~ ^[0-9]+$ ]]; then
    error "序号无效"
    return 1
  fi
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#tags[@]} ]; then
    error "序号无效"
    return 1
  fi
  SELECTED_OUT=${tags[$idx]}
  return 0
}

select_custom_outbound() {
  local -a tags=()
  local f choice idx i=0
  shopt -s nullglob
  for f in "$OUT_DIR"/*.json; do
    tags+=("$(basename "$f" .json)")
  done
  shopt -u nullglob
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无自定义出站"
    return 1
  fi
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "----------------------------------------------"
  for f in "${tags[@]}"; do
    i=$((i+1))
    printf '%-4s %-26s %s\n' "$i" "$f" "$(jq -r '.type // "?"' "$OUT_DIR/$f.json" 2>/dev/null || echo '?')"
  done
  ask choice "请输入序号" ""
  if ! [[ $choice =~ ^[0-9]+$ ]]; then
    error "序号无效"
    return 1
  fi
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#tags[@]} ]; then
    error "序号无效"
    return 1
  fi
  SELECTED_OUT=${tags[$idx]}
  return 0
}

view_outbounds() {
  local file final
  select_outbound || { pause; return 0; }
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  printf '%s\n' "=============================================="
  printf '当前默认出站: %s\n' "$final"
  printf '%s\n' "=============================================="
  if [ "$SELECTED_OUT" = "direct" ]; then
    jq -n '{type:"direct",tag:"direct"}'
  else
    file="$OUT_DIR/$SELECTED_OUT.json"
    jq . "$file"
  fi
  pause
}

change_outbound() {
  local final
  select_outbound || { pause; return 0; }
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  if [ "$SELECTED_OUT" = "$final" ]; then
    info "[$final] 已经是默认出站"
    pause
    return 0
  fi
  if ! confirm "确定将默认出站改为 [$SELECTED_OUT] ?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  printf '%s\n' "$SELECTED_OUT" > "$FINAL_FILE"
  info "默认出站已设置为 [$SELECTED_OUT]"
  apply_changes
  pause
}

select_node_protocol() {
  local -a protos=()
  local f tag proto choice p dup count idx i=0
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tag=$(basename "$f" .json)
    proto=$(meta_get "$tag" proto)
    [ -n "$proto" ] || continue
    dup=0
    if [ ${#protos[@]} -gt 0 ]; then
      for p in "${protos[@]}"; do
        if [ "$p" = "$proto" ]; then
          dup=1
        fi
      done
    fi
    if [ "$dup" -eq 0 ]; then
      protos+=("$proto")
    fi
  done
  shopt -u nullglob
  if [ ${#protos[@]} -eq 0 ]; then
    error "暂无节点"
    return 1
  fi

  printf '%-4s %-28s %s\n' "序号" "协议" "节点数"
  printf '%s\n' "----------------------------------------------"
  for p in "${protos[@]}"; do
    i=$((i + 1))
    count=0
    shopt -s nullglob
    for f in "$NODE_DIR"/*.json; do
      tag=$(basename "$f" .json)
      if [ "$(meta_get "$tag" proto)" = "$p" ]; then
        count=$((count + 1))
      fi
    done
    shopt -u nullglob
    printf '%-4s %-28s %s\n' "$i" "$(proto_meta_display "$p")" "$count"
  done
  ask choice "请输入协议序号" ""
  if ! [[ $choice =~ ^[0-9]+$ ]]; then
    error "序号无效"
    return 1
  fi
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#protos[@]} ]; then
    error "序号无效"
    return 1
  fi
  SELECTED_PROTO=${protos[$idx]}
  return 0
}

assign_node_outbound() {
  local node out
  select_node || { pause; return 0; }
  node=$SELECTED
  select_outbound || { pause; return 0; }
  out=$SELECTED_OUT
  if ! confirm "将节点 [$node] 的出站设置为 [$out] ?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  mkdir -p "$SB_DIR/routes"
  printf '%s\n' "$out" > "$SB_DIR/routes/$node.outbound"
  info "节点 [$node] 已绑定出站 [$out]"
  apply_changes
  pause
}

assign_protocol_outbound() {
  local proto out f tag count=0 written=0 display
  select_node_protocol || { pause; return 0; }
  proto=$SELECTED_PROTO
  display=$(proto_meta_display "$proto")
  select_outbound || { pause; return 0; }
  out=$SELECTED_OUT

  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tag=$(basename "$f" .json)
    if [ "$(meta_get "$tag" proto)" = "$proto" ]; then
      count=$((count + 1))
    fi
  done
  shopt -u nullglob
  if [ "$count" -eq 0 ]; then
    warn "该协议暂无节点"
    pause
    return 0
  fi
  if ! confirm "将 [$display] 的 $count 个节点绑定到出站 [$out] ?" "n"; then
    info "已取消"
    pause
    return 0
  fi

  mkdir -p "$SB_DIR/routes"
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tag=$(basename "$f" .json)
    if [ "$(meta_get "$tag" proto)" = "$proto" ]; then
      printf '%s\n' "$out" > "$SB_DIR/routes/$tag.outbound"
      written=$((written + 1))
    fi
  done
  shopt -u nullglob
  info "已为 $written 个 [$display] 节点绑定出站 [$out]"
  apply_changes
  pause
}

view_node_routes() {
  local f tag proto out final i=0
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  printf '%-4s %-30s %-24s %s\n' "序号" "节点" "协议" "出站"
  printf '%s\n' "--------------------------------------------------------------------------"
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    i=$((i + 1))
    tag=$(basename "$f" .json)
    proto=$(meta_get "$tag" proto)
    if [ -s "$SB_DIR/routes/$tag.outbound" ]; then
      out=$(head -n1 "$SB_DIR/routes/$tag.outbound" 2>/dev/null || true)
      if [ -z "$out" ]; then
        out="默认 ($final)"
      elif [ "$out" != "direct" ] && [ ! -f "$OUT_DIR/$out.json" ]; then
        out="$out [缺失]"
      fi
    else
      out="默认 ($final)"
    fi
    printf '%-4s %-30s %-24s %s\n' "$i" "$tag" "$(proto_meta_display "$proto")" "$out"
  done
  shopt -u nullglob
  pause
}

clear_node_routes() {
  local c tag rf removed=0
  printf '1) 清除指定节点的出站绑定\n2) 清除全部节点出站绑定\n0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1)
      select_node || { pause; return 0; }
      tag=$SELECTED
      if [ ! -s "$SB_DIR/routes/$tag.outbound" ]; then
        info "节点 [$tag] 没有出站绑定"
        pause
        return 0
      fi
      if ! confirm "清除节点 [$tag] 的出站绑定?" "n"; then
        info "已取消"
        pause
        return 0
      fi
      rm -f "$SB_DIR/routes/$tag.outbound"
      info "已清除节点 [$tag] 的出站绑定"
      apply_changes
      pause
      ;;
    2)
      if ! confirm "清除所有节点的出站绑定?" "n"; then
        info "已取消"
        pause
        return 0
      fi
      shopt -s nullglob
      for rf in "$SB_DIR/routes"/*.outbound; do
        rm -f "$rf"
        removed=$((removed + 1))
      done
      shopt -u nullglob
      info "已清除 $removed 个节点的出站绑定"
      apply_changes
      pause
      ;;
    0) return 0 ;;
    *) warn "无效选项" ;;
  esac
}

menu_change_outbound() {
  local c
  while true; do
    printf '\n%s\n' "------------- 更改出站 -------------"
    printf ' 1) 设置默认出站\n'
    printf ' 2) 为指定节点分配出站\n'
    printf ' 3) 按协议批量分配出站\n'
    printf ' 4) 查看节点出站分配\n'
    printf ' 5) 清除节点出站分配\n'
    printf ' 0) 返回\n'
    ask c "请选择" ""
    case "$c" in
      1) change_outbound ;;
      2) assign_node_outbound ;;
      3) assign_protocol_outbound ;;
      4) view_node_routes ;;
      5) clear_node_routes ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

delete_outbound() {
  local tag final rf removed=0
  select_custom_outbound || { pause; return 0; }
  tag=$SELECTED_OUT
  warn "即将删除出站 [$tag]"
  if ! confirm "确定删除?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  rm -f "$OUT_DIR/$tag.json"
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  if [ "$final" = "$tag" ]; then
    printf 'direct\n' > "$FINAL_FILE"
    warn "该出站是默认出站，已自动切换回 direct"
  fi
  shopt -s nullglob
  for rf in "$SB_DIR/routes"/*.outbound; do
    if [ "$(head -n1 "$rf" 2>/dev/null || true)" = "$tag" ]; then
      rm -f "$rf"
      removed=$((removed + 1))
    fi
  done
  shopt -u nullglob
  if [ "$removed" -gt 0 ]; then
    warn "已清除 $removed 个节点对该出站的绑定"
  fi
  info "出站 [$tag] 已删除"
  apply_changes
  pause
}

edit_file_with_editor() {
  local file=$1 ed=''
  if [ -n "${EDITOR:-}" ]; then
    ed=$EDITOR
  fi
  if [ -z "$ed" ]; then
    local c
    for c in nano vim vi; do
      if command -v "$c" >/dev/null 2>&1; then
        ed=$c
        break
      fi
    done
  fi
  if [ -n "$ed" ]; then
    # shellcheck disable=SC2086
    $ed "$file"
  else
    warn "未找到文本编辑器，请手动编辑文件: $file"
    read -r -p "编辑保存后按回车继续校验..." _ || true
  fi
}

edit_outbound() {
  local tag file backup newtag
  select_custom_outbound || { pause; return 0; }
  tag=$SELECTED_OUT
  file="$OUT_DIR/$tag.json"
  backup="$file.bak"
  cp -f "$file" "$backup" || { error "备份失败"; pause; return 0; }
  edit_file_with_editor "$file"
  if ! jq -e 'type=="object" and (.tag|type=="string") and (.type|type=="string")' "$file" >/dev/null 2>&1; then
    error "JSON 校验失败，已恢复原配置"
    mv -f "$backup" "$file"
    pause
    return 0
  fi
  newtag=$(jq -r '.tag' "$file")
  if [ "$newtag" != "$tag" ]; then
    error "不允许在编辑时修改 tag (${tag} -> ${newtag})，已恢复原配置"
    mv -f "$backup" "$file"
    pause
    return 0
  fi
  rm -f "$backup"
  info "出站 [$tag] 已更新"
  apply_changes
  pause
}

menu_outbounds() {
  local c
  while true; do
    printf '\n%s\n' "------------- 出站管理 -------------"
    printf ' 1) 新增出站\n'
    printf ' 2) 删除出站\n'
    printf ' 3) 编辑出站\n'
    printf ' 4) 更改出站 / 节点分流\n'
    printf ' 5) 查看出站\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) menu_add_outbound ;;
      2) delete_outbound ;;
      3) edit_outbound ;;
      4) menu_change_outbound ;;
      5) view_outbounds ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

menu_add_outbound() {
  local c
  printf '%s\n' "------------- 新增出站 -------------"
  printf ' 1) SOCKS5             2) HTTP 代理\n'
  printf ' 3) Shadowsocks        4) VMess\n'
  printf ' 5) VLESS              6) Trojan\n'
  printf ' 7) Hysteria2          8) TUIC\n'
  printf ' 9) 自定义 JSON        0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1) create_out_socks socks ;;
    2) create_out_socks http ;;
    3) create_out_ss ;;
    4) create_out_vmess ;;
    5) create_out_vless ;;
    6) create_out_trojan ;;
    7) create_out_hy2 ;;
    8) create_out_tuic ;;
    9) create_out_custom ;;
    0) return 0 ;;
    *) warn "无效选项" ;;
  esac
  pause
}

