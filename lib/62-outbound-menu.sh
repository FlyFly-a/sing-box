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

delete_outbound() {
  local tag final
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
    printf ' 4) 更改出站 (设置默认出站)\n'
    printf ' 5) 查看出站\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) menu_add_outbound ;;
      2) delete_outbound ;;
      3) edit_outbound ;;
      4) change_outbound ;;
      5) view_outbounds ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

menu_add_outbound() {
  local c
  printf '%s\n' "------------- 新增出站 -------------"
  printf ' 1) direct 直连        2) SOCKS5\n'
  printf ' 3) HTTP 代理          4) Shadowsocks\n'
  printf ' 5) VMess              6) VLESS\n'
  printf ' 7) Trojan             8) Hysteria2\n'
  printf ' 9) TUIC              10) 自定义 JSON\n'
  printf ' 0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1) create_out_direct ;;
    2) create_out_socks socks ;;
    3) create_out_socks http ;;
    4) create_out_ss ;;
    5) create_out_vmess ;;
    6) create_out_vless ;;
    7) create_out_trojan ;;
    8) create_out_hy2 ;;
    9) create_out_tuic ;;
    10) create_out_custom ;;
    0) return 0 ;;
    *) warn "无效选项" ;;
  esac
  pause
}

