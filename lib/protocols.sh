# ================================================================
#  协议注册表访问层
#  所有协议相关的查询都走这里，避免多处 switch 分散维护。
# ================================================================

proto_count() {
  printf '%s' "${#PROTO_IDS[@]}"
}

# 协议编号(1-based) -> 内部 ID
proto_id_by_index() {
  local i=${1:-0}
  [ "$i" -ge 1 ] && [ "$i" -le ${#PROTO_IDS[@]} ] || return 1
  printf '%s' "${PROTO_IDS[$((i - 1))]}"
}

# 协议编号(1-based) -> 显示名
proto_name_by_index() {
  local i=${1:-0}
  [ "$i" -ge 1 ] && [ "$i" -le ${#PROTO_NAMES[@]} ] || return 1
  printf '%s' "${PROTO_NAMES[$((i - 1))]}"
}

# 内部 ID -> 协议编号，找不到输出 0
proto_index_by_id() {
  local id=${1:-} i
  for i in "${!PROTO_IDS[@]}"; do
    if [ "${PROTO_IDS[$i]}" = "$id" ]; then
      printf '%s' "$((i + 1))"
      return 0
    fi
  done
  printf '0'
}

# 内部 ID -> 显示名
proto_display() {
  local i
  i=$(proto_index_by_id "${1:-}")
  if [ "$i" -eq 0 ]; then
    printf '未知'
    return 1
  fi
  printf '%s' "${PROTO_NAMES[$((i - 1))]}"
}

# 内部 ID -> 传输类型 (tcp/udp/both)
proto_transport() {
  local i
  i=$(proto_index_by_id "${1:-}")
  if [ "$i" -eq 0 ]; then
    printf 'tcp'
    return 0
  fi
  printf '%s' "${PROTO_TRANSPORTS[$((i - 1))]}"
}

# 内部 ID 是否属于已知协议
proto_known() {
  [ "$(proto_index_by_id "${1:-}")" != "0" ]
}

# ---------------- 协议能力 ----------------
# TLS 类协议: 需要 SNI 域名 + 自签证书
proto_needs_cert() {
  case "${1:-}" in
    vless-ws|hysteria2|tuic|trojan|trojan-ws|anytls|vmess-ws) return 0 ;;
    *) return 1 ;;
  esac
}

# REALITY: 需要 SNI 域名 + 回源端口，不需要证书
proto_needs_reality() {
  [ "${1:-}" = "vless-reality-vision" ]
}

# 是否需要 SNI 域名（TLS 与 REALITY 共用同一提示）
proto_needs_sni() {
  proto_needs_cert "${1:-}" || proto_needs_reality "${1:-}"
}

# 是否需要回源端口（仅 REALITY）
proto_needs_reality_port() {
  proto_needs_reality "${1:-}"
}

# ---------------- 菜单输出 ----------------
print_protocol_menu() {
  local i n
  n=$(proto_count)
  for ((i = 1; i <= n; i++)); do
    printf '%2d) %s\n' "$i" "${PROTO_NAMES[$((i - 1))]}"
  done
  printf '%2d) 返回\n' 0
}
