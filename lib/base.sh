# ================================================================
#  基础模块: 常量、颜色、交互输入、权限与 systemd 检测
# ================================================================

set -uo pipefail
umask 077

SCRIPT_VERSION="2026.11.10"

# ---------------- 路径 ----------------
SB_DIR="/etc/sing-box"
NODE_DIR="$SB_DIR/nodes"
OUT_DIR="$SB_DIR/outbounds"
CERT_DIR="$SB_DIR/cert"
LOG_DIR="$SB_DIR/log"
LOG_FILE="$LOG_DIR/sing-box.log"
CONF="$SB_DIR/config.json"
BIN="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
PID_FILE="$SB_DIR/sing-box.pid"
FINAL_FILE="$SB_DIR/final_outbound"
IP_FILE="$SB_DIR/server_ip"
COUNTRY_FILE="$SB_DIR/server_country"

# ---------------- 全局变量 ----------------
if [ -f /proc/net/if_inet6 ]; then
  LISTEN_ADDR="::"
else
  LISTEN_ADDR="0.0.0.0"
fi
EXCLUDE_TAG=""
TAG_VAL=""
PORT_VAL=""
DOMAIN_VAL=""
UUID_VAL=""
SHORT_ID_VAL=""
SNELL_PSK_VAL=""
SERVER_IP_CACHE=""
SERVER_IP_LOADED=0
CERT_FILE=""
KEY_FILE=""
CERT_INSECURE=0
SELECTED=""
SELECTED_PROTO=""
OUT_TAG=""
RPORT=""
BATCH_MODE=0
BATCH_TAG=""
BATCH_DOMAIN=""
BATCH_REALITY_SNI=""
BATCH_REALITY_HSPORT=""
AUTO_TAG_DEFAULT=""
PROTOCOL_PICKS=()
PROTOCOL_INVALID=""
CREATED_TAGS=()
BATCH_PORT=""
BATCH_PORT_LIST=()
BATCH_PORT_TYPES=()

# ---------------- 颜色 ----------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'
  C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BOLD=''
fi

# ================================================================
#  基础函数
# ================================================================
info()  { printf '%s %s\n' "${C_GRN}[信息]${C_RESET}" "$*"; }
warn()  { printf '%s %s\n' "${C_YEL}[注意]${C_RESET}" "$*"; }
error() { printf '%s %s\n' "${C_RED}[错误]${C_RESET}" "$*" >&2; }
pause() { read -r -p "按回车键返回..." _ || true; }

ask() {
  local __name=$1 __prompt=$2 __default=${3-} __input=''
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    printf -v "$__name" '%s' "$__default"
    return 0
  fi
  if [ -n "$__default" ]; then
    read -r -p "$__prompt [$__default]: " __input || true
    __input=${__input:-$__default}
  else
    read -r -p "$__prompt: " __input || true
  fi
  printf -v "$__name" '%s' "$__input"
}

confirm() {
  local __prompt=$1 __def=${2:-y} __ans=''
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    [ "$__def" = "y" ]
    return $?
  fi
  if [ "$__def" = "y" ]; then
    read -r -p "$__prompt [Y/n]: " __ans || true
    __ans=${__ans:-y}
  else
    read -r -p "$__prompt [y/N]: " __ans || true
    __ans=${__ans:-n}
  fi
  case "$__ans" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 用户运行此脚本"
    exit 1
  fi
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

has_openrc() {
  command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]
}

