# ================================================================
#  使用帮助
# ================================================================
show_help() {
  cat <<EOF
================================ 使用帮助 ================================

【目录结构】
  主配置    : $CONF
  节点目录  : $NODE_DIR
  出站目录  : $OUT_DIR
  证书目录  : $CERT_DIR
  日志文件  : $LOG_FILE
  核心程序  : $BIN

【基本流程】
  1. 先在“核心管理”确认核心版本（建议保持最新）。
  2. 在“节点管理 -> 新增节点”选择协议，按提示填写端口、域名等信息。
     节点名称默认使用“国家码-协议”，可直接回车或手动修改。
     输入一个编号进入单节点向导；输入多个编号进入批量创建，
     编号用空格或逗号分隔，例如 1 7 20，
     节点会按国家码自动命名，例如 JP-VLESS-REALITY、GB-Hysteria2-QUIC。
     批量创建只需输入一次伪装域名，TLS 节点和 REALITY 共用；
     REALITY 回源端口会单独询问，默认 443；
     每种协议还会单独询问监听端口，直接回车使用建议值，
     端口会自动避开已有节点和本批次内的重复占用。
     国家码查询失败时显示 XX，可直接输入两位国家码。
  3. TLS 类协议需要域名证书：
     - 有真实证书时，直接填写 crt 和 key 的绝对路径；
     - 没有证书时，可让脚本生成自签证书（客户端需允许不安全连接）；
     - 批量创建找不到证书时会自动生成自签证书，不再额外确认；
     - 建议使用真实域名并申请 Let's Encrypt 证书，兼容性最好。
  4. 添加完成后，用“运行管理 -> 启动/重启核心”使配置生效。
  5. 在“查看节点”中复制分享链接或客户端配置到手机/电脑。
     主菜单选择 5) 分享链接，可一次查看全部节点。

【协议说明】
  VLESS-REALITY      : 无需域名证书，依赖伪装域名，默认回源 443，推荐优先使用
  VLESS-Vision-TLS   : VLESS + XTLS Vision + TLS，需要证书
  VLESS-TLS          : VLESS + 普通 TLS，需要证书
  VLESS-gRPC-TLS     : gRPC 传输，需要证书，适合 CDN 中转
  VLESS-WS-TLS       : WebSocket 传输，需要证书，适合 CDN 中转
  VLESS-HTTPUpgrade  : HTTPUpgrade 传输，需要证书
  Hysteria2-QUIC     : 基于 QUIC，UDP 端口，需要证书，速度快
  TUIC-QUIC          : 基于 QUIC，UDP 端口，需要证书
  Shadowsocks-AEAD   : 传统 AEAD 加密，无需证书
  Shadowsocks-2022   : 新一代加密，密码必须是 Base64 密钥
  Shadowsocks-ShadowTLS : ShadowTLS v3 + 内层 Shadowsocks
  Trojan / VMess     : 支持 TCP、WS、gRPC 等组合
  AnyTLS-TLS         : 需要 sing-box 1.12 及以上核心
  SOCKS5             : 用户名密码认证的 SOCKS5 代理

【出站分流】
  出站管理 -> 更改出站 / 节点分流
  1) 设置默认出站
  2) 为指定节点分配出站
  3) 按协议批量分配出站
  4) 查看节点出站分配
  5) 清除节点出站分配
  示例: AnyTLS-TLS 节点使用 HK 出站，Hysteria2-QUIC 节点使用 UK 出站。

【端口与防火墙】
  如果无法连接，请确认云厂商安全组和本机防火墙已放行对应端口。
  TCP 协议示例:
    ufw allow 443/tcp
    firewall-cmd --permanent --add-port=443/tcp && firewall-cmd --reload
  UDP 协议 (Hysteria2 / TUIC) 示例:
    ufw allow 443/udp
    firewall-cmd --permanent --add-port=443/udp && firewall-cmd --reload

【服务管理】
  systemd 系统:
    systemctl status sing-box
    systemctl start sing-box
    systemctl stop sing-box
    systemctl restart sing-box
    journalctl -u sing-box -f
  OpenRC 系统 (Alpine):
    rc-service sing-box status
    rc-service sing-box start
    rc-service sing-box stop
    rc-service sing-box restart

【常见问题】
  1. 启动失败：查看“运行管理 -> 查看日志”，多数是端口占用或证书路径错误。
  2. 自签证书：客户端必须开启“允许不安全连接 / allowInsecure”。
  3. REALITY 伪装域名：批量创建时与 TLS 节点共用同一个伪装域名，单节点可自定义。
     建议选择支持 TLS 1.3 的境外网站，如 www.microsoft.com。
     回源端口默认 443，会单独询问，可自定义。
  4. AnyTLS 报错：升级核心到 1.12 或更高版本。
  5. Shadowsocks 2022 报错：密码必须是 16 或 32 字节的 Base64 密钥。
  6. 修改配置后未生效：执行“重启核心”。
  7. 节点分流：出站管理 -> 更改出站，可设置默认出站，也可为指定节点或协议单独绑定出站。
  8. 出站列表中的 direct 是内置直连，不需要重复新增。

======================================================================
EOF
}

menu_help() {
  local c ip cc
  while true; do
    printf '\n%s\n' "------------- 使用帮助 -------------"
    printf ' 1) 查看使用帮助\n'
    printf ' 2) 刷新公网 IP 与国家码缓存\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1)
        show_help
        pause
        ;;
      2)
        rm -f "$IP_FILE" "$COUNTRY_FILE" "$SB_DIR/server_location"
        ip=$(get_server_ip)
        if [ -n "$ip" ]; then
          info "当前公网 IP: $ip"
        else
          warn "获取公网 IP 失败，请检查网络"
        fi
        cc=$(get_server_country_code)
        info "当前服务器国家码: $cc"
        pause
        ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

