# ================================================================
#  节点菜单
# ================================================================
menu_add_node() {
  local c
  printf '%s\n' "------------- 新增节点 -------------"
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
  printf '21) SOCKS5                 0) 返回\n'
  ask c "请选择" ""
  case "$c" in
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
    0)  return 0 ;;
    *)  warn "无效选项" ;;
  esac
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

