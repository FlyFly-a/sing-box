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
  路由目录  : $ROUTE_DIR
  证书目录  : $CERT_DIR
  日志文件  : $LOG_FILE
  核心程序  : $BIN

【基本流程】
  1. 首次运行会自动识别架构并安装 sing-box 核心，无需确认。
  2. 节点管理 -> 新增节点，选择协议后只需填写:
       - 监听端口   本机监听的端口，直接回车随机分配
       - SNI域名    TLS 与 REALITY 共用，创建时统一填写
       - 回源端口    仅 REALITY 需要，默认 443
     UUID、密码、PSK、传输路径全部自动生成。
     节点默认命名为“国家码-协议”，直接回车接受或手动修改。
     输入多个编号(空格或逗号分隔，如 1 3 10)进入批量创建。
  3. 所有需要证书的协议共用一套自签证书，客户端需开启
     “允许不安全连接 / allowInsecure”。
  4. 配置变更后按提示重启核心生效。
  5. 双栈环境会同时输出 IPv4/IPv6 两套分享链接；
     只有一种协议栈时只输出对应的一套。

【动态 IP / DDNS】
  主菜单 7) 解析域名:
    - 设置后分享链接使用该域名，不再写公网 IP
    - IP 变化时只需 DDNS 更新解析，客户端重新解析即可
    - 双栈环境只输出一条域名链接
    - 清除域名后恢复使用公网 IP
    - REALITY 的 SNI 与服务器地址相互独立，设置域名不影响
    - 自签证书仍需客户端开启“允许不安全连接”

【协议说明】
  VLESS-Reality-Vision  : 无需证书，Vision + REALITY，推荐优先使用
  VLESS-WS              : WebSocket + TLS
  Hysteria2             : 基于 QUIC，UDP 端口，需要证书
  TUIC                  : 基于 QUIC，UDP 端口，需要证书，默认 BBR + native
  Trojan                : TCP + TLS，需要证书
  Trojan-WS             : WebSocket + TLS
  AnyTLS                : 需要 sing-box 1.12 及以上核心
  Shadowsocks-2022      : 固定 2022-blake3-aes-256-gcm，同时监听 TCP 与 UDP
  VMess-WS              : WebSocket + TLS
  Snell-v6              : 需要 sing-box 1.14 及以上核心，无需证书
  SOCKS5                : 用户名密码认证

【链式落地: 用另一台服务器做出口】
  场景: 手机 -> 服务器A(节点) -> 服务器B(节点) -> 目标网站

  1. 在服务器 B 上用本脚本建好节点，复制它的分享链接。
  2. 在服务器 A 上执行:
       出站管理 -> 新增出站 -> 粘贴分享链接
     粘贴 B 的链接，命名后即完成出站创建。
     SOCKS5 / Snell 这类没有分享链接的，用“手动填写”。
  3. 在服务器 A 上执行:
       出口路由 -> 绑定 / 修改某个节点的出口
     选择 A 上的节点，再选择刚建的出站，即可让该节点走 B 落地。
  4. 需要撤销时: 出口路由 -> 为节点取消 / 恢复直连。
     可输入一个或多个节点序号；输入 0 表示全部节点。

  多个落地: 每个节点的出口独立保存，可分别指向不同出站。
  批量设置: 出口路由 -> 为节点绑定 / 修改出口，可输入多个序号，0 表示全部。

【端口与防火墙】
  连接不通时请确认云厂商安全组与本机防火墙已放行对应端口。
  TCP:
    ufw allow 443/tcp
    firewall-cmd --permanent --add-port=443/tcp && firewall-cmd --reload
  UDP (Hysteria2 / TUIC):
    ufw allow 443/udp
    firewall-cmd --permanent --add-port=443/udp && firewall-cmd --reload
  Shadowsocks-2022 同时监听 TCP 与 UDP:
    ufw allow 8388/tcp && ufw allow 8388/udp

【服务管理】
  systemd:
    systemctl status|start|stop|restart sing-box
    journalctl -u sing-box -f
  OpenRC (Alpine):
    rc-service sing-box status|start|stop|restart

【常见问题】
  1. 启动失败: 查看“运行管理 -> 查看日志”，多为端口占用或证书问题。
  2. 自签证书: 客户端必须开启“允许不安全连接 / allowInsecure”。
  3. REALITY 的 SNI域名建议选择支持 TLS 1.3 的境外站点。
  4. AnyTLS 报错: 升级核心到 1.12 或更高。
  5. Snell 报错: 升级核心到 1.14 或更高。
     Sub-Store 不支持 snell:// 输入，分享页直接输出 Surge 格式，
     输出 sing-box 时请加 target=sing-box&includeUnsupportedProxy=true。
  6. Shadowsocks-2022 报错: 密码必须是 16 或 32 字节 Base64 密钥。
  7. 配置未生效: 执行“运行管理 -> 重启核心”。
  8. 本机自身流量不受出口路由影响，始终直连。

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
      1) show_help; pause ;;
      2)
        rm -f "$IP4_FILE" "$IP6_FILE" "$COUNTRY_FILE"
        SERVER_IP=""
        SERVER_IP4=""
        SERVER_IP6=""
        SERVER_IP_LOADED=0
        load_server_ip4
        load_server_ip6
        if [ -n "${SERVER_IP4:-}" ]; then
          info "当前公网 IPv4: $SERVER_IP4"
        else
          warn "未获取到公网 IPv4"
        fi
        if [ -n "${SERVER_IP6:-}" ]; then
          info "当前公网 IPv6: $SERVER_IP6"
        else
          warn "未获取到公网 IPv6"
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
