#!/bin/sh

set -eu

SING_BOX_VERSION=""
SERVICE_NAME=sing-box

# ==================== 【用户自定义端口配置区】 ====================
VLESS_PORT=443
VLESS_TLS_PORT=8443
VLESS_WS_PORT=2053
VMESS_PORT=2083
TROJAN_TLS_PORT=2087
TROJAN_WS_PORT=2095
HY2_PORT=50000
TUIC_PORT=50001
SS_PORT=50002
SS2022_128_PORT=50003
SS2022_256_PORT=50004
SOCKS5_PORT=50005
SNELL_PORT=50006
SNELL_V6_PORT=50007
# ================================================================

# ==================== 【自定义 SNI 配置】 ====================
SNI=www.tencentcloud.com
REALITY_DEST_PORT=443
# ============================================================

VLESS_UUID=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
REALITY_SHORT_ID=""
HY2_PASSWORD=""
SNELL_PSK=""
TROJAN_PASSWORD=""
SS_PASSWORD=""
SS2022_128_PSK=""
SS2022_256_PSK=""
SOCKS5_USER=""
SOCKS5_PASS=""

BASE_DIR="${SING_BOX_HOME:-/root/sing-box}"
BIN_PATH="$BASE_DIR/sing-box"

CONF_DIR="$BASE_DIR/conf"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/sing-box.log"
PID_FILE="$BASE_DIR/sing-box.pid"
CONF_FILE="$CONF_DIR/config.json"
REALITY_PUBLIC_FILE="$CONF_DIR/reality-public.key"
TLS_CERT_FILE="$CONF_DIR/tls-cert.pem"
TLS_KEY_FILE="$CONF_DIR/tls-key.pem"

GO_MEMORY_LIMIT=48MiB
TCP_BUFFER_MAX=4194304

SERVER=""
SERVER_IPV4=""
SERVER_IPV6=""

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RESET=$(printf '\033[0m'); C_OK=$(printf '\033[32m')
  C_ERR=$(printf '\033[31m'); C_INFO=$(printf '\033[36m'); C_BOLD=$(printf '\033[1m')
else
  C_RESET=''; C_OK=''; C_ERR=''; C_INFO=''; C_BOLD=''
fi

log()  { printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

DISTRO=unknown
if [ -r /etc/os-release ]; then
  DISTRO=$(. /etc/os-release && printf '%s' "${ID:-unknown}")
fi
case "$DISTRO" in
  alpine)                 DISTRO_FAMILY=alpine ;;
  debian|ubuntu|raspbian) DISTRO_FAMILY=debian ;;
  *)
    if command -v apk >/dev/null 2>&1; then DISTRO_FAMILY=alpine
    elif command -v apt-get >/dev/null 2>&1; then DISTRO_FAMILY=debian
    else DISTRO_FAMILY=unknown; fi
    ;;
esac

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  INIT=systemd
elif command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then
  INIT=openrc
else
  INIT=none
fi

install_deps() (
  log "installing dependencies"
  if [ "$DISTRO_FAMILY" = alpine ]; then
    apk add --no-cache ca-certificates curl openssl jq >/dev/null
  elif [ "$DISTRO_FAMILY" = debian ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq ca-certificates curl openssl jq >/dev/null
  else
    die "install curl, openssl and jq manually"
  fi
  ok "dependencies installed"
)

ensure_deps() {
  for c in curl openssl jq; do
    command -v "$c" >/dev/null 2>&1 || { install_deps; break; }
  done
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    i386|i686) echo 386 ;;
    riscv64) echo riscv64 ;;
    *) echo amd64 ;;
  esac
}

fetch_binary() {
  ARCH=$(detect_arch)
  [ -n "$SING_BOX_VERSION" ] || SING_BOX_VERSION="1.11.4"
  BASE="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}"
  install -d -m 0755 "$BASE_DIR"
  TMP=$(mktemp -d "$BASE_DIR/dl.XXXXXX")
  URL="$BASE/sing-box-${SING_BOX_VERSION}-linux-$ARCH.tar.gz"
  
  curl -fsSL --retry 3 -o "$TMP/sb.tar.gz" "$URL" 2>/dev/null || die "download failed"
  tar -xzf "$TMP/sb.tar.gz" -C "$TMP" 2>/dev/null || die "extract failed"
  CANDIDATE=$(find "$TMP" -type f -name sing-box | head -n 1)
  install -m 0755 "$CANDIDATE" "$BIN_PATH"
  rm -rf "$TMP"
  ok "installed sing-box binary"
}

ensure_binary() {
  [ -x "$BIN_PATH" ] || fetch_binary
}

ensure_dirs() {
  install -d -m 0755 "$CONF_DIR" "$LOG_DIR"
  chmod 0755 "$BASE_DIR"
}

generate_credentials() {
  [ -s "$CONF_FILE" ] && [ -s "$REALITY_PUBLIC_FILE" ] && return 0
  log "generating fresh credentials"
  VLESS_UUID=$("$BIN_PATH" generate uuid)
  reality_keypair=$("$BIN_PATH" generate reality-keypair)
  REALITY_PRIVATE=$(printf '%s\n' "$reality_keypair" | awk '/^PrivateKey:/{print $2}')
  REALITY_PUBLIC=$(printf '%s\n' "$reality_keypair" | awk '/^PublicKey:/{print $2}')
  REALITY_SHORT_ID=$(openssl rand -hex 8)
  HY2_PASSWORD=$(openssl rand -hex 16)
  SNELL_PSK=$(openssl rand -hex 32)
  TROJAN_PASSWORD=$(openssl rand -hex 12)
  SS_PASSWORD=$(openssl rand -base64 16)
  SS2022_128_PSK=$(openssl rand -base64 16)
  SS2022_256_PSK=$(openssl rand -base64 32)
  SOCKS5_USER="user_$(openssl rand -hex 3)"
  SOCKS5_PASS="$(openssl rand -hex 6)"
}

write_config() (
  umask 077
  touch "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  chmod 600 "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -batch \
    -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" -days 3650 \
    -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1

  jq . > "$CONF_FILE" << CONFIG
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-local", "address": "local" }
    ],
    "final": "dns-local"
  },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality-in", "listen": "::", "listen_port": $VLESS_PORT,
      "users": [{ "name": "default", "uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision" }],
      "tls": { "enabled": true, "server_name": "$SNI", "reality": { "enabled": true, "handshake": { "server": "$SNI", "server_port": 443 }, "private_key": "$REALITY_PRIVATE", "short_id": ["$REALITY_SHORT_ID"] } }
    },
    {
      "type": "vless", "tag": "vless-tls-in", "listen": "::", "listen_port": $VLESS_TLS_PORT,
      "users": [{ "name": "default", "uuid": "$VLESS_UUID" }],
      "tls": { "enabled": true, "server_name": "$SNI", "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" }
    },
    {
      "type": "vless", "tag": "vless-ws-in", "listen": "::", "listen_port": $VLESS_WS_PORT,
      "users": [{ "name": "default", "uuid": "$VLESS_UUID" }],
      "transport": { "type": "ws", "path": "/vless-ws" },
      "tls": { "enabled": true, "server_name": "$SNI", "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" }
    },
    {
      "type": "vmess", "tag": "vmess-in", "listen": "::", "listen_port": $VMESS_PORT,
      "users": [{ "name": "default", "uuid": "$VLESS_UUID" }],
      "tls": { "enabled": true, "server_name": "$SNI", "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" }
    },
    {
      "type": "trojan", "tag": "trojan-tls-in", "listen": "::", "listen_port": $TROJAN_TLS_PORT,
      "users": [{ "name": "default", "password": "$TROJAN_PASSWORD" }],
      "tls": { "enabled": true, "server_name": "$SNI", "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" }
    },
    {
      "type": "trojan", "tag": "trojan-ws-in", "listen": "::", "listen_port": $TROJAN_WS_PORT,
      "users": [{ "name": "default", "password": "$TROJAN_PASSWORD" }],
      "transport": { "type": "ws", "path": "/trojan-ws" },
      "tls": { "enabled": true, "server_name": "$SNI", "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT,
      "users": [{ "name": "default", "password": "$HY2_PASSWORD" }],
      "tls": { "enabled": true, "server_name": "$SNI", "alpn": ["h3"], "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" }
    },
    {
      "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": $TUIC_PORT,
      "users": [{ "name": "default", "uuid": "$VLESS_UUID", "password": "$HY2_PASSWORD" }],
      "congestion_control": "bbr",
      "tls": { "enabled": true, "server_name": "$SNI", "alpn": ["h3"], "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" }
    },
    {
      "type": "shadowsocks", "tag": "ss-in", "listen": "::", "listen_port": $SS_PORT, "method": "aes-256-gcm", "password": "$SS_PASSWORD"
    },
    {
      "type": "shadowsocks", "tag": "ss-2022-128-in", "listen": "::", "listen_port": $SS2022_128_PORT, "method": "2022-blake3-aes-128-gcm", "password": "$SS2022_128_PSK"
    },
    {
      "type": "shadowsocks", "tag": "ss-2022-256-in", "listen": "::", "listen_port": $SS2022_256_PORT, "method": "2022-blake3-aes-256-gcm", "password": "$SS2022_256_PSK"
    },
    {
      "type": "socks5", "tag": "socks5-in", "listen": "::", "listen_port": $SOCKS5_PORT,
      "users": [{ "username": "$SOCKS5_USER", "password": "$SOCKS5_PASS" }]
    },
    {
      "type": "snell", "tag": "snell-in", "listen": "::", "listen_port": $SNELL_PORT, "version": 5, "psk": "$SNELL_PSK"
    },
    {
      "type": "snell", "tag": "snell-v6-in", "listen": "::", "listen_port": $SNELL_V6_PORT, "version": 6, "psk": "$SNELL_PSK", "mode": "default"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
CONFIG
  printf '%s\n' "$REALITY_PUBLIC" > "$REALITY_PUBLIC_FILE"
)

public_ip() {
  curl -4 -fsS --connect-timeout 3 https://api.ipify.org 2>/dev/null || echo ""
}

show_links() {
  SERVER=$(public_ip)
  [ -n "$SERVER" ] || SERVER="<your-server-ip>"
  
  printf '\n========================================================\n'
  printf '  Custom Port sing-box Share Links\n'
  printf '========================================================\n'
  printf '  VLESS-Reality       : %s\n' "$VLESS_PORT"
  printf '  VLESS-TLS           : %s\n' "$VLESS_TLS_PORT"
  printf '  VLESS-WS-TLS        : %s\n' "$VLESS_WS_PORT"
  printf '  VMess-TCP-TLS       : %s\n' "$VMESS_PORT"
  printf '  Trojan-TLS          : %s\n' "$TROJAN_TLS_PORT"
  printf '  Trojan-WS-TLS       : %s\n' "$TROJAN_WS_PORT"
  printf '  Hysteria2-TLS       : %s (UDP)\n' "$HY2_PORT"
  printf '  TUIC-TLS            : %s (UDP)\n' "$TUIC_PORT"
  printf '  Shadowsocks         : %s\n' "$SS_PORT"
  printf '  SS-2022-128         : %s\n' "$SS2022_128_PORT"
  printf '  SS-2022-256         : %s\n' "$SS2022_256_PORT"
  printf '  SOCKS5              : %s\n' "$SOCKS5_PORT"
  printf '  Snell v5            : %s\n' "$SNELL_PORT"
  printf '  Snell v6            : %s\n' "$SNELL_V6_PORT"
  printf '========================================================\n\n'
}

stop_existing() {
  if [ "$INIT" = systemd ]; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}

start_service() {
  if [ "$INIT" = systemd ]; then
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << UNIT
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH run -c $CONF_FILE
Restart=always
RestartSec=3s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1
  else
    nohup "$BIN_PATH" run -c "$CONF_FILE" >>"$LOG_FILE" 2>&1 &
  fi
  ok "sing-box service started successfully"
}

uninstall() {
  stop_existing
  rm -rf "$CONF_DIR" "$LOG_DIR" "$BIN_PATH" "$BASE_DIR"
  ok "uninstalled completely"
}

do_install() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo sh $0)"
  ensure_deps
  ensure_binary
  ensure_dirs
  generate_credentials
  write_config
  "$BIN_PATH" check -c "$CONF_FILE" || die "config check failed"
  stop_existing
  start_service
  show_links
}

# ==================== 【交互式选择菜单】 ====================
show_menu() {
  clear
  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '%s       sing-box 多协议管理脚本 (14协议)                 %s\n' "$C_BOLD" "$C_RESET"
  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '  1. 安装 / 更新 / 重置配置 并启动服务\n'
  printf '  2. 查看当前节点的分享链接\n'
  printf '  3. 卸载并删除 sing-box 服务\n'
  printf '  0. 退出脚本\n'
  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '请输入选择 [0-3]: '
  read -r choice
  case "$choice" in
    1)
      do_install
      ;;
    2)
      [ -f "$CONF_FILE" ] || { warn "尚未安装或找不到配置文件！"; exit 1; }
      show_links
      ;;
    3)
      uninstall
      ;;
    0)
      exit 0
      ;;
    *)
      warn "无效的选择，请重新运行脚本！"
      ;;
  esac
}

show_menu
