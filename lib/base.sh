# ================================================================
#  基础模块: 常量、协议注册表、运行状态、交互与权限
# ================================================================

set -uo pipefail
umask 077

# ---------------- 路径 ----------------
SB_DIR="/etc/sing-box"
NODE_DIR="$SB_DIR/nodes"
OUT_DIR="$SB_DIR/outbounds"
ROUTE_DIR="$SB_DIR/routes"
CERT_DIR="$SB_DIR/cert"
LOG_DIR="$SB_DIR/log"
LOG_FILE="$LOG_DIR/sing-box.log"
CONF="$SB_DIR/config.json"
BIN="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
OPENRC_FILE="/etc/init.d/sing-box"
PID_FILE="$SB_DIR/sing-box.pid"
IP_FILE="$SB_DIR/server_ip"
IP4_FILE="$SB_DIR/server_ip4"
IP6_FILE="$SB_DIR/server_ip6"
COUNTRY_FILE="$SB_DIR/server_country"

# ---------------- 协议注册表 ----------------
# 唯一数据源: 新增协议只需在这里加一行，菜单/显示名/传输类型随之生效。
# 显示名刻意不带 -TLS 后缀: Sub-Store 会把 TL 识别成东帝汶国家码。
PROTO_IDS=(
  vless-reality-vision
  vless-ws
  hysteria2
  tuic
  trojan
  trojan-ws
  anytls
  shadowsocks-2022
  vmess-ws
  snell-v6
  socks5
)
PROTO_NAMES=(
  "VLESS-Reality-Vision"
  "VLESS-WS"
  "Hysteria2"
  "TUIC"
  "Trojan"
  "Trojan-WS"
  "AnyTLS"
  "Shadowsocks-2022"
  "VMess-WS"
  "Snell-v6"
  "SOCKS5"
)
# 传输类型: tcp / udp / both，用于端口占用判定
PROTO_TRANSPORTS=(
  tcp tcp udp udp
  tcp tcp tcp both tcp
  tcp tcp
)

# ---------------- 向导状态 ----------------
WIZ_TAG=""
WIZ_PORT=""
WIZ_SNI=""
WIZ_REALITY_PORT=""
WIZ_EDIT_TAG=""

# ---------------- 批量状态 ----------------
BATCH_MODE=0
BATCH_TAG=""
BATCH_SNI=""
BATCH_REALITY_PORT=""
BATCH_PORT=""
BATCH_PORT_LIST=()
BATCH_PORT_TYPES=()

# ---------------- 运行期缓存 ----------------
SERVER_IP=""
SERVER_IP4=""
SERVER_IP6=""
SERVER_IP_LOADED=0
NODE_LISTEN="::"
IPV6_V6ONLY=0
CERT_FILE=""
KEY_FILE=""
CERT_INSECURE=0

# ---------------- 选择结果 ----------------
SELECTED=""
SELECTED_OUT=""
SELECTED_NODES=()
CREATED_TAGS=()

reset_wizard() {
  WIZ_TAG=""
  WIZ_PORT=""
  WIZ_SNI=""
  WIZ_REALITY_PORT=""
  WIZ_EDIT_TAG=""
}

reset_batch() {
  BATCH_MODE=0
  BATCH_TAG=""
  BATCH_SNI=""
  BATCH_REALITY_PORT=""
  BATCH_PORT=""
  BATCH_PORT_LIST=()
  BATCH_PORT_TYPES=()
}

# ---------------- 颜色 ----------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'
  C_BOLD=$'\033[1m'
else
  C_RESET=''
  C_RED=''
  C_GRN=''
  C_YEL=''
  C_BLU=''
  C_BOLD=''
fi

# ================================================================
#  基础输出与交互
# ================================================================
info()  { printf '%s %s\n' "${C_GRN}[信息]${C_RESET}" "$*"; }
warn()  { printf '%s %s\n' "${C_YEL}[注意]${C_RESET}" "$*"; }
error() { printf '%s %s\n' "${C_RED}[错误]${C_RESET}" "$*" >&2; }
pause() { read -r -p "按回车键返回..." _ || true; }

# ask <变量名> <提示> [默认值]
ask() {
  local __name=$1
  local __prompt=$2
  local __default=${3-}
  local __input=''
  if [ "${BATCH_MODE:-0}" = "1" ] && [ "$__prompt" != "节点名称" ]; then
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
  local __prompt=$1
  local __def=${2:-y}
  local __ans=''
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
    *)     return 1 ;;
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
