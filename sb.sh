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
  C_ERR=$(printf '\033[31m'); C_INFO=$(printf '\033[36m')
  C_BOLD=$(printf '\033[1m')
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

Installs sing-box and starts inbound protocols with manual port, SNI, and Reality destination port configuration.

Usage:
  ./sb.sh             install (or repair) and start (interactive setup)
  ./sb.sh --show      print the share links for an existing install
  ./sb.sh --uninstall stop and remove everything this script created

Environment variables for non-interactive automation:
  SNI, REALITY_DEST_PORT, VLESS_PORT, TROJAN_PORT, ANYTLS_PORT,
  HY2_PORT, TUIC_PORT, SNELL_PORT, SNELL_V6_PORT
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
    if [ -f "$1" ]; then
      dpkg -i "$@" >/dev/null
    fi
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
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v openssl >/dev/null 2>&1 || die "openssl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
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
    CANDIDATES="$ARCH-musl$ARCH"
  else
    CANDIDATES="$ARCH $ARCH-glibc$ARCH-musl"
  fi

  for variant in $CANDIDATES; do
    URL="$BASE/sing-box-${SING_BOX_VERSION}-linux-${variant}.tar.gz"
    log "downloading sing-box $SING_BOX_VERSION ($variant)"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/sb.tar.gz" "$URL" 2>/dev/null; then
      warn "no release asset for $variant"
      continue
    fi
    if ! tar -xzf "$TMP/sb.tar.gz" -C "$TMP" 2>/dev/null; then
      warn "could not extract $variant archive"
      continue
    fi
    CANDIDATE=$(find "$TMP" -type f -name sing-box | head -n 1)
    [ -n "$CANDIDATE" ] || { warn "no binary in $variant archive"; continue; }
    chmod +x "$CANDIDATE"
    if RUNERR=$("$CANDIDATE" version 2>&1 >/dev/null); then
      install -m 0755 "$CANDIDATE" "$BIN_PATH"
      rm -rf "$TMP"
      ok "installed $BIN_PATH ($variant)"
      return 0
    fi
    warn "$variant binary does not run on this system:$RUNERR"
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
    warn "could not resolve the latest sing-box release; keeping the installed binary"
    return 0
  fi
  if [ -x "$BIN_PATH" ]; then
    CURRENT=$("$BIN_PATH" version 2>/dev/null | awk '/^sing-box version/{print $3}') || CURRENT=""
    if [ "$CURRENT" = "$SING_BOX_VERSION" ]; then
      ok "sing-box $CURRENT already installed"
      return 0
    fi
    log "replacing sing-box ${CURRENT:-unknown} with$SING_BOX_VERSION"
  fi
  fetch_binary
}

ensure_dirs() {
  install -d -m 0755 "$CONF_DIR" "$LOG_DIR"
  chmod 0755 "$BASE_DIR"
}

prompt_config() {
  [ -t 0 ] || {
    # 非交互式且未通过环境变量传值时报错
    [ -n "$SNI" ] || die "SNI is required (set SNI env or run interactively)"
    [ -n "$REALITY_DEST_PORT" ] || die "REALITY_DEST_PORT is required"
    [ -n "$VLESS_PORT" ] || die "VLESS_PORT is required"
    [ -n "$TROJAN_PORT" ] || die "TROJAN_PORT is required"
    [ -n "$ANYTLS_PORT" ] || die "ANYTLS_PORT is required"
    [ -n "$HY2_PORT" ] || die "HY2_PORT is required"
    [ -n "$TUIC_PORT" ] || die "TUIC_PORT is required"
    [ -n "$SNELL_PORT" ] || die "SNELL_PORT is required"
    [ -n "$SNELL_V6_PORT" ] || die "SNELL_V6_PORT is required"
    return 0
  }

  printf '\n%s=== 请手动输入配置参数 ===%s\n' "$C_BOLD" "$C_RESET"
  
  while [ -z "$SNI" ]; do
    printf '请输入 SNI 域名 (例如: www.bing.com): '
    read -r SNI
  done

  while [ -z "$REALITY_DEST_PORT" ]; do
    printf '请输入 REALITY 回源目标端口 (例如: 443): '
    read -r REALITY_DEST_PORT
  done

  while [ -z "$VLESS_PORT" ]; do
    printf 'VLESS + REALITY 监听端口: '
    read -r VLESS_PORT
  done

  while [ -z "$TROJAN_PORT" ]; do
    printf 'Trojan 监听端口: '
    read -r TROJAN_PORT
  done

  while [ -z "$ANYTLS_PORT" ]; do
    printf 'AnyTLS 监听端口: '
    read -r ANYTLS_PORT
  done

  while [ -z "$HY2_PORT" ]; do
    printf 'Hysteria2 监听端口: '
    read -r HY2_PORT
  done

  while [ -z "$TUIC_PORT" ]; do
    printf 'TUIC v5 监听端口: '
    read -r TUIC_PORT
  done

  while [ -z "$SNELL_PORT" ]; do
    printf 'Snell v5 监听端口: '
    read -r SNELL_PORT
  done

  while [ -z "$SNELL_V6_PORT" ]; do
    printf 'Snell v6 监听端口: '
    read -r SNELL_V6_PORT
  done
  
  printf '%s==========================%s\n\n' "$C_BOLD" "$C_RESET"
}

generate_credentials() {
  log "generating fresh credentials"
  VLESS_UUID=$("$BIN_PATH" generate uuid) || die "could not generate VLESS UUID"
  reality_keypair=$("$BIN_PATH" generate reality-keypair) || die "could not generate REALITY key pair"
  REALITY_PRIVATE=$(printf '%s\n' "$reality_keypair" | awk '/^PrivateKey:/{print $2}')
  REALITY_PUBLIC=$(printf '%s\n' "$reality_keypair" | awk '/^PublicKey:/{print $2}')
  [ -n "$VLESS_UUID" ] && [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || die "invalid generated credentials"
  REALITY_SHORT_ID=$(openssl rand -hex 8) || die "could not generate REALITY short ID"
  TROJAN_PASSWORD=$(openssl rand -hex 16) || die "could not generate Trojan password"
  HY2_PASSWORD=$(openssl rand -hex 16) || die "could not generate Hysteria2 password"
  SNELL_PSK=$(openssl rand -hex 32) || die "could not generate Snell key"
}

write_config() (
  umask 077
  touch "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  chmod 600 "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" -days 3650 \
    -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1 \
    || die "could not generate the TLS certificate"

  jq . > "$CONF_FILE" << CONFIG
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local"
      }
    ],
    "final": "dns-local",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "name": "default",
          "uuid": "$VLESS_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": $REALITY_DEST_PORT
          },
          "private_key": "$REALITY_PRIVATE",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      },
      "multiplex": {
        "enabled": true
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": $TROJAN_PORT,
      "users": [
        {
          "name": "default",
          "password": "$TROJAN_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $ANYTLS_PORT,
      "users": [
        {
          "name": "default",
          "password": "$TROJAN_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "name": "default",
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": [
          "h3"
        ],
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [
        {
          "name": "default",
          "uuid": "$VLESS_UUID",
          "password": "$HY2_PASSWORD"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": [
          "h3"
        ],
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    },
    {
      "type": "snell",
      "tag": "snell-in",
      "listen": "::",
      "listen_port": $SNELL_PORT,
      "version": 5,
      "psk": "$SNELL_PSK"
    },
    {
      "type": "snell",
      "tag": "snell-v6-in",
      "listen": "::",
      "listen_port": $SNELL_V6_PORT,
      "version": 6,
      "psk": "$SNELL_PSK",
      "mode": "default"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct",
    "default_domain_resolver": {
      "server": "dns-local",
      "strategy": "prefer_ipv4"
    }
  }
}
CONFIG
  printf '%s\n' "$REALITY_PUBLIC" > "$REALITY_PUBLIC_FILE"
)

load_credentials() {
  command -v jq >/dev/null 2>&1 || die "jq is required to read the saved configuration"
  
  client_settings=$(jq -er '
    (.inbounds[] | select(.type == "vless")) as $vless |
    (.inbounds[] | select(.type == "trojan")) as $trojan |
    (.inbounds[] | select(.type == "anytls")) as $anytls |
    (.inbounds[] | select(.type == "hysteria2")) as $hy2 |
    (.inbounds[] | select(.type == "tuic")) as $tuic |
    (.inbounds[] | select(.type == "snell" and .version == 5)) as $snell5 |
    (.inbounds[] | select(.type == "snell" and .version == 6)) as $snell6 |
    [$vless.users[0].uuid,$vless.tls.server_name,
     $vless.tls.reality.short_id[0],$trojan.users[0].password, $hy2.users[0].password,$snell5.psk,
     ($vless.listen_port|tostring), ($trojan.listen_port|tostring), ($anytls.listen_port|tostring),
     ($hy2.listen_port|tostring), ($tuic.listen_port|tostring), ($snell5.listen_port|tostring), ($snell6.listen_port|tostring)] |
    if all(.[]; type == "string" and length > 0) then @tsv
    else error("missing client settings") end
  ' "$CONF_FILE") || die "could not read credentials from $CONF_FILE"
  
  [ -n "$client_settings" ] || die "no client credentials found in $CONF_FILE"
  
  IFS="$(printf '\t')" read -r VLESS_UUID SNI REALITY_SHORT_ID TROJAN_PASSWORD HY2_PASSWORD SNELL_PSK \
    VLESS_PORT TROJAN_PORT ANYTLS_PORT HY2_PORT TUIC_PORT SNELL_PORT SNELL_V6_PORT << SETTINGS
$client_settings
SETTINGS

  [ -s "$REALITY_PUBLIC_FILE" ] || die "missing $REALITY_PUBLIC_FILE; re-run sb.sh to generate credentials"
  REALITY_PUBLIC=$(cat "$REALITY_PUBLIC_FILE")
}

check_reality_dest() {
  # 注意：由于 REALITY_DEST_PORT 现在需要从配置里读取或在安装前记录，我们确保它可用
  # 如果在 load_credentials 阶段，我们可以从配置文件重新提取 REALITY_DEST_PORT
  r_dest=$(jq -er '.inbounds[] | select(.type == "vless") | .tls.reality.handshake.server_port' "$CONF_FILE" 2>/dev/null || echo "$REALITY_DEST_PORT")
  log "checking REALITY destination $SNI:$r_dest"
  if command -v timeout >/dev/null 2>&1; then
    REALITY_CHECK=$(timeout 10 openssl s_client -connect "$SNI:$r_dest" \
        -servername "$SNI" -alpn h2 </dev/null 2>/dev/null || true)
  else
    REALITY_CHECK=$(openssl s_client -connect "$SNI:$r_dest" \
        -servername "$SNI" -alpn h2 </dev/null 2>/dev/null || true)
  fi
  case "$REALITY_CHECK" in
    *TLSv1.3*) ok "destination speaks TLS 1.3" ;;
    *) warn "could not confirm TLS 1.3 from $SNI -- REALITY clients may fail" ;;
  esac
}

rotate_logs() {
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
  if tail -c "$LOG_KEEP_BYTES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null; then
    cat "$LOG_FILE.tmp" > "$LOG_FILE"
  fi
  rm -f "$LOG_FILE.tmp"
}

start_rotator() {
  if [ -f "$ROTATOR_PID_FILE" ] && kill -0 "$(cat "$ROTATOR_PID_FILE")" 2>/dev/null; then
    return 0
  fi
  nohup sh -c '
    while :; do
      sleep 600
      [ -f "$1" ] || continue
      size=$(wc -c < "$1" 2>/dev/null || echo 0)
      [ "$size" -gt "$2" ] || continue
      if tail -c "$3" "$1" > "$1.tmp" 2>/dev/null; then
        cat "$1.tmp" > "$1"
      fi
      rm -f "$1.tmp"
    done
  ' log-rotator "$LOG_FILE" "$LOG_MAX_BYTES" "$LOG_KEEP_BYTES" >/dev/null 2>&1 &
  echo $! > "$ROTATOR_PID_FILE"
  rotate_logs
}

stop_rotator() {
  if [ -f "$ROTATOR_PID_FILE" ]; then
    kill "$(cat "$ROTATOR_PID_FILE")" 2>/dev/null || true
    rm -f "$ROTATOR_PID_FILE"
  fi
}

stop_existing() {
  case "$INIT" in
    systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
    openrc)  rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
  esac
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  stop_rotator
}

install_service() {
  case "$INIT" in
    systemd)
