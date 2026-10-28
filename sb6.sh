#!/bin/sh

set -eu

SING_BOX_VERSION=""
SERVICE_NAME=sing-box

# ==============================================================================
# 用户自定义配置
# ==============================================================================
SNI="${SNI:-}"
REALITY_DEST_PORT="${REALITY_DEST_PORT:-}"

VLESS_PORT="${VLESS_PORT:-}"
TROJAN_PORT="${TROJAN_PORT:-}"
ANYTLS_PORT="${ANYTLS_PORT:-}"
HY2_PORT="${HY2_PORT:-}"
TUIC_PORT="${TUIC_PORT:-}"
SNELL_PORT="${SNELL_PORT:-}"
SNELL_V6_PORT="${SNELL_V6_PORT:-}"
# ==============================================================================

VLESS_UUID=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
REALITY_SHORT_ID=""
TROJAN_PASSWORD=""
HY2_PASSWORD=""
SNELL_PSK=""

BASE_DIR="${SING_BOX_HOME:-/root/sing-box}"
BIN_PATH="$BASE_DIR/sing-box"

CONF_DIR="$BASE_DIR/conf"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/sing-box.log"
PID_FILE="$BASE_DIR/sing-box.pid"
ROTATOR_PID_FILE="$BASE_DIR/log-rotator.pid"

LOG_MAX_BYTES=$((10 * 1024 * 1024))
LOG_KEEP_BYTES=$((5 * 1024 * 1024))

CONF_FILE="$CONF_DIR/config.json"
REALITY_PUBLIC_FILE="$CONF_DIR/reality-public.key"
TLS_CERT_FILE="$CONF_DIR/tls-cert.pem"
TLS_KEY_FILE="$CONF_DIR/tls-key.pem"

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

usage() {
  cat << 'USAGE'
sing-box installer for Alpine Linux and Debian/Ubuntu.

Installs sing-box and starts seven inbounds with auto-geolocated node naming.

Usage:
  ./sb.sh             install (or repair) and start (interactive setup)
  ./sb.sh --show      print the share links for an existing install
  ./sb.sh --uninstall stop and remove everything this script created
USAGE
}

MODE=install
case "${1:-}" in
  ""|--install)         MODE=install ;;
  --show)               MODE=show ;;
  --uninstall|--remove) MODE=uninstall ;;
  -h|--help)            usage; exit 0 ;;
  *) die "unknown option: $1 (try --show or --uninstall)" ;;
esac

if [ "$MODE" != show ]; then
  [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0)"
fi

DISTRO=unknown
if [ -r /etc/os-release ]; then
  DISTRO=$(. /etc/os-release && printf '%s' "${ID:-unknown}")
fi
case "$DISTRO" in
  alpine)               DISTRO_FAMILY=alpine ;;
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
    DEPS_TMP=$(mktemp -d /tmp/sing-box-deps.XXXXXX)
    trap 'rm -rf "$DEPS_TMP"' 0
    chmod 0755 "$DEPS_TMP"
    install -d -m 0755 "$DEPS_TMP/lists" "$DEPS_TMP/archives"
    set -- -o "Dir::State::lists=$DEPS_TMP/lists" \
      -o "Dir::Cache::archives=$DEPS_TMP/archives" \
      -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= \
      -o Acquire::Languages=none -o Acquire::GzipIndexes=true \
      -o Acquire::CompressionTypes::Order::=gz -o APT::Cache-Start=8388608
    apt-get "$@" update -qq >/dev/null
    apt-get "$@" install --download-only --no-install-recommends --no-upgrade \
      -y -qq ca-certificates curl openssl jq >/dev/null
    set -- "$DEPS_TMP"/archives/*.deb
    if [ -f "$1" ]; then dpkg -i "$@" >/dev/null; fi
  else
    die "no supported package manager found; install curl, openssl and jq manually"
  fi
  ok "ca-certificates, curl, openssl, jq"
)

ensure_deps() {
  missing=0
  for c in curl openssl jq; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  [ -d /etc/ssl/certs ] || missing=1
  [ "$missing" -eq 1 ] && install_deps
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)        echo amd64 ;;
    aarch64|arm64)       echo arm64 ;;
    armv7l|armv7)        echo armv7 ;;
    armv6l|armv6)        echo armv6 ;;
    armv5l|armv5)        echo armv5 ;;
    i386|i486|i586|i686) echo 386 ;;
    riscv64)             echo riscv64 ;;
    loongarch64|loong64) echo loong64 ;;
    s390x)               echo s390x ;;
    ppc64le)             echo ppc64le ;;
    mips64el)            echo mips64le ;;
    mipsel)              echo mipsle ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

fetch_binary() {
  ARCH=$(detect_arch)
  BASE="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}"
  install -d -m 0755 "$BASE_DIR"
  TMP=$(mktemp -d "$BASE_DIR/dl.XXXXXX")

  if [ "$DISTRO_FAMILY" = alpine ]; then
    CANDIDATES="$ARCH-musl $ARCH"
  else
    CANDIDATES="$ARCH $ARCH-glibc $ARCH-musl"
  fi

  for variant in $CANDIDATES; do
    URL="$BASE/sing-box-${SING_BOX_VERSION}-linux-${variant}.tar.gz"
    log "downloading sing-box $SING_BOX_VERSION ($variant)"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/sb.tar.gz" "$URL" 2>/dev/null; then continue; fi
    if ! tar -xzf "$TMP/sb.tar.gz" -C "$TMP" 2>/dev/null; then continue; fi
    CANDIDATE=$(find "$TMP" -type f -name sing-box | head -n 1)
    [ -n "$CANDIDATE" ] || continue
    chmod +x "$CANDIDATE"
    if RUNERR=$("$CANDIDATE" version 2>&1 >/dev/null); then
      install -m 0755 "$CANDIDATE" "$BIN_PATH"
      rm -rf "$TMP"
      ok "installed $BIN_PATH ($variant)"
      return 0
    fi
  done
  rm -rf "$TMP"
  die "could not obtain a working sing-box binary for $ARCH"
}

resolve_version() {
  log "resolving latest sing-box release"
  LATEST_URL=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 --connect-timeout 15 \
    https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null) || LATEST_URL=""
  SING_BOX_VERSION=${LATEST_URL##*/v}
  case "$SING_BOX_VERSION" in
    ''|*[!0-9.]*) SING_BOX_VERSION=""; return 1 ;;
  esac
  ok "latest sing-box is $SING_BOX_VERSION"
}

ensure_binary() {
  if ! resolve_version; then
    [ -x "$BIN_PATH" ] || die "could not resolve the latest sing-box release"
    return 0
  fi
  if [ -x "$BIN_PATH" ]; then
    CURRENT=$("$BIN_PATH" version 2>/dev/null | awk '/^sing-box version/{print $3}') || CURRENT=""
    if [ "$CURRENT" = "$SING_BOX_VERSION" ]; then
      ok "sing-box $CURRENT already installed"
      return 0
    fi
  fi
  fetch_binary
}

ensure_dirs() {
  install -d -m 0755 "$CONF_DIR" "$LOG_DIR"
  chmod 0755 "$BASE_DIR"
}

prompt_config() {
  [ -t 0 ] || {
    [ -n "$SNI" ] && [ -n "$REALITY_DEST_PORT" ] && [ -n "$VLESS_PORT" ] && return 0
    die "Missing required environment variables."
  }

  printf '\n%s=== 请手动输入所有配置参数 ===%s\n' "$C_BOLD" "$C_RESET"
  while [ -z "$SNI" ]; do printf '请输入 SNI 域名 (例如: www.bing.com): '; read -r SNI; done
  while [ -z "$REALITY_DEST_PORT" ]; do printf '请输入 REALITY 回源目标端口 (例如: 443): '; read -r REALITY_DEST_PORT; done
  while [ -z "$VLESS_PORT" ]; do printf 'VLESS + REALITY 监听端口: '; read -r VLESS_PORT; done
  while [ -z "$TROJAN_PORT" ]; do printf 'Trojan 监听端口: '; read -r TROJAN_PORT; done
  while [ -z "$ANYTLS_PORT" ]; do printf 'AnyTLS 监听端口: '; read -r ANYTLS_PORT; done
  while [ -z "$HY2_PORT" ]; do printf 'Hysteria2 监听端口: '; read -r HY2_PORT; done
  while [ -z "$TUIC_PORT" ]; do printf 'TUIC v5 监听端口: '; read -r TUIC_PORT; done
  while [ -z "$SNELL_PORT" ]; do printf 'Snell v5 监听端口: '; read -r SNELL_PORT; done
  while [ -z "$SNELL_V6_PORT" ]; do printf 'Snell v6 监听端口: '; read -r SNELL_V6_PORT; done
  printf '%s=============================%s\n\n' "$C_BOLD" "$C_RESET"
}

generate_credentials() {
  log "generating fresh credentials"
  VLESS_UUID=$("$BIN_PATH" generate uuid)
  reality_keypair=$("$BIN_PATH" generate reality-keypair)
  REALITY_PRIVATE=$(printf '%s\n' "$reality_keypair" | awk '/^PrivateKey:/{print $2}')
  REALITY_PUBLIC=$(printf '%s\n' "$reality_keypair" | awk '/^PublicKey:/{print $2}')
  REALITY_SHORT_ID=$(openssl rand -hex 8)
  TROJAN_PASSWORD=$(openssl rand -hex 16)
  HY2_PASSWORD=$(openssl rand -hex 16)
  SNELL_PSK=$(openssl rand -hex 32)
}

write_config() (
  umask 077
  touch "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  chmod 600 "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" -days 3650 \
    -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1

  jq . > "$CONF_FILE" << CONFIG
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "servers": [{ "type": "local", "tag": "dns-local" }], "final": "dns-local", "strategy": "prefer_ipv4" },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality-in", "listen": "::", "listen_port": $VLESS_PORT,
      "users": [{ "name": "default", "uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision" }],
      "tls": { "enabled": true, "server_name": "$SNI", "reality": { "enabled": true, "handshake": { "server": "$SNI", "server_port": $REALITY_DEST_PORT }, "private_key": "$REALITY_PRIVATE", "short_id": ["$REALITY_SHORT_ID"] } },
      "multiplex": { "enabled": true }
    },
    { "type": "trojan", "tag": "trojan-in", "listen": "::", "listen_port": $TROJAN_PORT, "users": [{ "name": "default", "password": "$TROJAN_PASSWORD" }], "tls": { "enabled": true, "server_name": "$SNI", "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" } },
    { "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": $ANYTLS_PORT, "users": [{ "name": "default", "password": "$TROJAN_PASSWORD" }], "tls": { "enabled": true, "server_name": "$SNI", "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" } },
    { "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT, "users": [{ "name": "default", "password": "$HY2_PASSWORD" }], "tls": { "enabled": true, "server_name": "$SNI", "alpn": ["h3"], "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" } },
    { "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": $TUIC_PORT, "users": [{ "name": "default", "uuid": "$VLESS_UUID", "password": "$HY2_PASSWORD" }], "congestion_control": "bbr", "tls": { "enabled": true, "server_name": "$SNI", "alpn": ["h3"], "certificate_path": "$TLS_CERT_FILE", "key_path": "$TLS_KEY_FILE" } },
    { "type": "snell", "tag": "snell-in", "listen": "::", "listen_port": $SNELL_PORT, "version": 5, "psk": "$SNELL_PSK" },
    { "type": "snell", "tag": "snell-v6-in", "listen": "::", "listen_port": $SNELL_V6_PORT, "version": 6, "psk": "$SNELL_PSK", "mode": "default" }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct", "default_domain_resolver": { "server": "dns-local", "strategy": "prefer_ipv4" } }
}
CONFIG
  printf '%s\n' "$REALITY_PUBLIC" > "$REALITY_PUBLIC_FILE"
)

load_credentials() {
  client_settings=$(jq -er '
    (.inbounds[] | select(.type == "vless")) as $vless |
    (.inbounds[] | select(.type == "trojan")) as $trojan |
    (.inbounds[] | select(.type == "anytls")) as $anytls |
    (.inbounds[] | select(.type == "hysteria2")) as $hy2 |
    (.inbounds[] | select(.type == "tuic")) as $tuic |
    (.inbounds[] | select(.type == "snell" and .version == 5)) as $snell5 |
    (.inbounds[] | select(.type == "snell" and .version == 6)) as $snell6 |
    [$vless.users[0].uuid, $vless.tls.server_name,
     $vless.tls.reality.short_id[0], $trojan.users[0].password, $hy2.users[0].password, $snell5.psk,
     ($vless.listen_port|tostring), ($trojan.listen_port|tostring), ($anytls.listen_port|tostring),
     ($hy2.listen_port|tostring), ($tuic.listen_port|tostring), ($snell5.listen_port|tostring), ($snell6.listen_port|tostring)] |
    if all(.[]; type == "string" and length > 0) then @tsv else error("missing client settings") end
  ' "$CONF_FILE")
  IFS="$(printf '\t')" read -r VLESS_UUID SNI REALITY_SHORT_ID TROJAN_PASSWORD HY2_PASSWORD SNELL_PSK \
    VLESS_PORT TROJAN_PORT ANYTLS_PORT HY2_PORT TUIC_PORT SNELL_PORT SNELL_V6_PORT << SETTINGS
$client_settings
SETTINGS
  REALITY_PUBLIC=$(cat "$REALITY_PUBLIC_FILE")
}

public_ip() {
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --connect-timeout 8 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    case "$ip" in *[!0-9a-fA-F:.]*|"") continue ;; *) printf '%s' "$ip"; return 0 ;; esac
  . done
  return 1
}

public_ipv6() {
  for url in https://api6.ipify.org https://ifconfig.me/ip; do
    ip6=$(curl -6 -fsS --connect-timeout 3 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    case "$ip6" in *:*) printf '%s' "$ip6"; return 0 ;; esac
  done
  return 1
}

# 自动通过 IP 获取国家/地区代码（如 hk, us, sg）
get_geo_prefix() {
  geo=$(curl -fsS --connect-timeout 5 "http://ip-api.com/line/?fields=countryCode" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]') || geo=""
  [ -n "$geo" ] && [ "${#geo}" -eq 2 ] && printf '%s' "$geo" || printf 'vps'
}

print_section() {
  section_head="-- $1  $2 "
  section_fill=$((56 - ${#section_head}))
  section_rule=$(printf '%s' '--------------------------------------------------------' | cut -c1-"$section_fill")
  printf '\n%s%s%s%s\n' "$C_BOLD" "$section_head" "$section_rule" "$C_RESET"
}

show_links() {
  load_credentials
  SERVER_IPV4=$(public_ip) || SERVER_IPV4=""
  SERVER_IPV6=$(public_ipv6) || SERVER_IPV6=""
  SERVER="${SERVER_IPV4:-${SERVER_IPV6:-<your-server-ip>}}"
  URI_SERVER=$SERVER
  case "$URI_SERVER" in *:*) URI_SERVER="[$URI_SERVER]" ;; esac

  # 获取地理位置前缀（如 hk, us 等）
  NODE_PREFIX=$(get_geo_prefix)

  printf '\n%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '%s  sing-box is running (Location Tag: %s)%s\n' "$C_BOLD" "$(printf '%s' "$NODE_PREFIX" | tr '[:lower:]' '[:upper:]')" "$C_RESET"
  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"

  print_section "VLESS + REALITY" "$VLESS_PORT/tcp"
  printf '  vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-reality\n' \
    "$VLESS_UUID" "$URI_SERVER" "$VLESS_PORT" "$SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$NODE_PREFIX"

  print_section "Trojan" "$TROJAN_PORT/tcp"
  printf '  trojan://%s@%s:%s?security=tls&sni=%s&allow_insecure=1#%s-trojan\n' \
    "$TROJAN_PASSWORD" "$URI_SERVER" "$TROJAN_PORT" "$SNI" "$NODE_PREFIX"

  print_section "AnyTLS" "$ANYTLS_PORT/tcp"
  printf '  anytls://%s@%s:%s?sni=%s&insecure=1#%s-anytls\n' \
    "$TROJAN_PASSWORD" "$URI_SERVER" "$ANYTLS_PORT" "$SNI" "$NODE_PREFIX"

  print_section "Hysteria2" "$HY2_PORT/udp"
  printf '  hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=1#%s-hy2\n' \
    "$HY2_PASSWORD" "$URI_SERVER" "$HY2_PORT" "$SNI" "$NODE_PREFIX"

  print_section "TUIC v5" "$TUIC_PORT/udp"
  printf '  tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#%s-tuic\n' \
    "$VLESS_UUID" "$HY2_PASSWORD" "$URI_SERVER" "$TUIC_PORT" "$SNI" "$NODE_PREFIX"

  print_section "Snell v5" "$SNELL_PORT/tcp"
  printf '  snell-v5 = snell, %s, %s, psk=%s, version=4, reuse=true, name=%s-snell5\n' \
    "$SERVER" "$SNELL_PORT" "$SNELL_PSK" "$NODE_PREFIX"

  print_section "Snell v6" "$SNELL_V6_PORT/tcp"
  printf '  snell-v6 = snell, %s, %s, psk=%s, version=6, reuse=true, name=%s-snell6\n' \
    "$SERVER" "$SNELL_V6_PORT" "$SNELL_PSK" "$NODE_PREFIX"

  printf '\n%s========================================================%s\n\n' "$C_BOLD" "$C_RESET"
}

uninstall() {
  log "stopping and removing sing-box"
  case "$INIT" in
    systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/${SERVICE_NAME}.service" ;;
    openrc) rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true; rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true; rm -f "/etc/init.d/$SERVICE_NAME" ;;
  esac
  rm -rf "$CONF_DIR" "$LOG_DIR" "$BIN_PATH" "$PID_FILE" "$ROTATOR_PID_FILE" "$BASE_DIR"/dl.*
  ok "removed sing-box, its configuration, and its service"
}

do_install() {
  ensure_deps; ensure_binary; ensure_dirs; prompt_config; generate_credentials
  write_config
  "$BIN_PATH" check -c "$CONF_FILE" >/dev/null 2>&1 || die "generated configuration failed validation"
  stop_existing() { case "$INIT" in systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;; openrc) rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;; esac; }
  stop_existing
  # 简化的安装/启动逻辑
  case "$INIT" in
    systemd) cat > "/etc/systemd/system/${SERVICE_NAME}.service" << UNIT
[Unit]
Description=sing-box
After=network.target
[Service]
Type=simple
ExecStart=$BIN_PATH run -c $CONF_FILE
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload && systemctl enable --now "$SERVICE_NAME" ;;
    openrc) rc-service "$SERVICE_NAME" start >/dev/null 2>&1 || true ;;
    *) nohup "$BIN_PATH" run -c "$CONF_FILE" >>"$LOG_FILE" 2>&1 & ;;
  esac
  show_links
}

case "${1:-}" in
  install|"") do_install ;;
  show) show_links ;;
  uninstall) uninstall ;;
esac
