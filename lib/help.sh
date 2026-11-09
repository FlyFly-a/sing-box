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
  2. 在“节点管理 -> 新增节点”选择协议，按提示填写监听端口、域名等信息。
     节点名称默认使用“国家码-协议”，可直接回车或手动修改。
     输入一个编号进入单节点向导；输入多个编号进入批量创建，
     编号用空格或逗号分隔，例如 1 3 10，
     节点会按国家码自动命名，例如 JP-VLESS-Reality-Vision、GB-Hysteria2。
     新增节点会询问监听端口，直接回车使用随机监听端口；
     编辑节点时直接回车保留原端口。
     批量创建只需输入一次伪装域名，TLS 节点和 REALITY 共用；
     REALITY 回源端口会单独询问，默认 443；
     每种协议还会单独询问监听端口，直接回车使用随机监听端口，
     监听端口会自动避开已有节点和本批次内的重复占用。
     国家码查询失败时显示 XX，可直接输入两位国家码。
  3. TLS 节点统一自动使用同一个自签证书：
     - 证书文件名随机生成，保存在 /etc/sing-box/cert/ 下；
     - 所有需要证书的协议自动复用这一套证书，不再询问证书路径；
     - 客户端需要开启“允许不安全连接 / allowInsecure”。
  4. 添加完成后，用“运行管理 -> 启动/重启核心”使配置生效。
  5. 节点创建完成后会自动显示新节点的分享链接；
     也可在“查看节点”中复制，主菜单选择 5) 分享链接可一次查看全部节点。

【协议说明】
  VLESS-Reality-Vision    : 无需证书，Vision + REALITY，推荐优先使用
  VLESS-WS-TLS            : WebSocket + TLS，适合 CDN 中转
  Hysteria2               : 基于 QUIC，UDP 端口，需要证书，速度快
  TUIC                    : 基于 QUIC，UDP 端口，需要证书
  Trojan-TLS              : Trojan + TLS，需要证书
  Trojan-WS-TLS           : WebSocket + TLS，适合 CDN 中转
  AnyTLS-TLS              : 需要 sing-box 1.12 及以上核心
  Shadowsocks-2022        : 新一代加密，密码必须是 Base64 密钥
  VMess-WS-TLS            : WebSocket + TLS，兼容旧客户端
  Snell-v6                : 需要 sing-box 1.14 及以上核心，无需证书
  SOCKS5                  : 用户名密码认证的 SOCKS5 代理

【出站分流】
  出站管理 -> 更改出站 / 节点分流
  1) 设置默认出站
  2) 为指定节点分配出站
  3) 按协议批量分配出站
  4) 查看节点出站分配
  5) 清除节点出站分配
  示例: AnyTLS-TLS 节点使用 HK 出站，Hysteria2 节点使用 UK 出站。

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
  5. Snell 报错：升级核心到 1.14 或更高版本；Snell 没有标准分享链接，分享页会输出 Surge 配置和 sing-box 出站 JSON。
     Surge 格式: 节点名 = snell, 服务器, 端口, psk=密钥, version=6, reuse=true
  6. Shadowsocks 2022 报错：密码必须是 16 或 32 字节的 Base64 密钥。
  7. 修改配置后未生效：执行“重启核心”。
  8. 节点分流：出站管理 -> 更改出站，可设置默认出站，也可为指定节点或协议单独绑定出站。
  9. 出站列表中的 direct 是内置直连，不需要重复新增。

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

