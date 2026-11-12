#!/usr/bin/env bash
# ================================================================
#  sing-box 一键部署管理脚本（单文件构建版）
#  由 build.sh 自动生成，请勿直接编辑；源码见 lib/ 目录
# ================================================================

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
LOG_MAX_KB=5120
LOG_LEVEL="info"
LOW_MEMORY=0
CORE_MIN_FREE_KB=81920
MEMINFO_FILE="/proc/meminfo"
MEM_TOTAL_KB=0
CGROUP_MEM_MAX_FILE="/sys/fs/cgroup/memory.max"
CGROUP_MEM_LIMIT_FILE="/sys/fs/cgroup/memory/memory.limit_in_bytes"
PROC_NET_DIR="/proc/net"
CONF="$SB_DIR/config.json"
BIN="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
OPENRC_FILE="/etc/init.d/sing-box"
PID_FILE="$SB_DIR/sing-box.pid"
IP4_FILE="$SB_DIR/server_ip4"
IP6_FILE="$SB_DIR/server_ip6"
SERVER_HOST_FILE="$SB_DIR/server_host"
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
SERVER_HOST=""
NODE_LISTEN="::"
IPV6_V6ONLY=0
CERT_FILE=""
KEY_FILE=""

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

# ================================================================
#  依赖与核心安装
# ================================================================
jq_version_supported() {
  command -v jq >/dev/null 2>&1 || return 1
  local v major minor rest
  v=$(jq --version 2>/dev/null) || return 1
  v=${v#jq-}
  major=${v%%.*}
  rest=${v#*.}
  minor=${rest%%[!0-9]*}
  [ -n "$major" ] && [ -n "$minor" ] || return 1
  if [ "$major" -gt 1 ]; then
    return 0
  fi
  [ "$major" -eq 1 ] && [ "$minor" -ge 6 ]
}

ensure_deps() {
  local missing=()
  local cmd fail=0
  if ! jq_version_supported; then
    missing+=("jq")
  fi
  for cmd in curl openssl tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ! -s /etc/ssl/certs/ca-certificates.crt ] && \
     [ ! -s /etc/pki/tls/certs/ca-bundle.crt ] && \
     [ ! -s /etc/ssl/cert.pem ] && \
     [ ! -s /etc/ssl/ca-bundle.pem ]; then
    missing+=("ca-certificates")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    info "缺少依赖: ${missing[*]}，正在自动安装 ..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null 2>&1 || true
      apt-get clean >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y --setopt=install_weak_deps=False "${missing[@]}" >/dev/null 2>&1 || true
      dnf clean all >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y "${missing[@]}" >/dev/null 2>&1 || true
      yum clean all >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache "${missing[@]}" >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive --no-recommends install "${missing[@]}" >/dev/null 2>&1 || true
      zypper clean -a >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Sy --noconfirm --needed "${missing[@]}" >/dev/null 2>&1 || true
      pacman -Sc --noconfirm >/dev/null 2>&1 || true
    else
      warn "无法识别包管理器，尝试静态安装 jq"
    fi
    hash -r 2>/dev/null || true
  fi

  if ! jq_version_supported; then
    install_jq_static || return 1
  fi

  for cmd in curl openssl tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || fail=1
  done
  jq_version_supported || fail=1
  if [ "$fail" -ne 0 ]; then
    error "依赖安装失败，请手动安装缺少的依赖"
    return 1
  fi
  [ ${#missing[@]} -gt 0 ] && info "依赖安装完成"
  return 0
}

install_jq_static() {
  local asset='' tmp
  if [ -z "${ARCH:-}" ]; then
    detect_arch >/dev/null 2>&1 || true
  fi
  case "${ARCH:-}" in
    amd64)       asset="jq-linux-amd64" ;;
    arm64)       asset="jq-linux-arm64" ;;
    armv7)       asset="jq-linux-armhf" ;;
    armv6|armv5) asset="jq-linux-armel" ;;
    386)         asset="jq-linux-i386" ;;
    ppc64le)     asset="jq-linux-ppc64el" ;;
    riscv64)     asset="jq-linux-riscv64" ;;
    s390x)       asset="jq-linux-s390x" ;;
    *)
      error "当前架构暂无预编译 jq，请用系统包管理器安装 jq"
      return 1
      ;;
  esac
  info "尝试安装静态 jq (${asset}) ..."
  tmp=$(mktemp -d) || return 1
  if download_file "https://github.com/jqlang/jq/releases/download/jq-1.7.1/${asset}" "$tmp/jq"; then
    chmod 755 "$tmp/jq"
    mkdir -p /usr/local/bin
    if mv -f "$tmp/jq" /usr/local/bin/jq; then
      hash -r 2>/dev/null || true
      rm -rf "$tmp"
      if jq_version_supported; then
        info "静态 jq 安装完成: $(jq --version)"
        return 0
      fi
    fi
  fi
  rm -rf "$tmp"
  error "静态 jq 安装失败，请手动安装 jq"
  return 1
}

detect_arch() {
  local m bits
  m=$(uname -m 2>/dev/null || echo unknown)
  bits=$(getconf LONG_BIT 2>/dev/null || echo 64)
  case "$m" in
    x86_64|amd64)
      if [ "$bits" = "32" ]; then ARCH="386"; else ARCH="amd64"; fi
      ;;
    aarch64|arm64)
      if [ "$bits" = "32" ]; then ARCH="armv7"; else ARCH="arm64"; fi
      ;;
    armv7l|armv7|armv8l) ARCH="armv7" ;;
    armv6l|armv6)        ARCH="armv6" ;;
    armv5l|armv5)        ARCH="armv5" ;;
    arm*)                ARCH="armv7" ;;
    i386|i486|i586|i686) ARCH="386" ;;
    riscv64)             ARCH="riscv64" ;;
    s390x)               ARCH="s390x" ;;
    ppc64le)             ARCH="ppc64le" ;;
    loongarch64|loong64) ARCH="loong64" ;;
    *)
      error "暂不支持的架构: $m"
      return 1
      ;;
  esac
  info "系统架构: $m (${bits} 位) -> linux-$ARCH"
  return 0
}

get_latest_version() {
  local ver=''
  if command -v curl >/dev/null 2>&1; then
    ver=$(curl -fsSL --connect-timeout 10 --max-time 25 \
      https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null || true)
    if [ -z "$ver" ]; then
      ver=$(curl -fsSIL -o /dev/null -w '%{url_effective}' --connect-timeout 10 --max-time 25 \
        https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
        | sed -n 's#.*/tag/v##p' || true)
    fi
  fi
  ver=${ver#v}
  if [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    printf '%s' "$ver"
    return 0
  fi
  return 1
}

download_file() {
  local url=$1 dest=$2 attempt
  local urls=()
  [ -n "${SB_GH_PROXY:-}" ] && urls+=("${SB_GH_PROXY}${url}")
  urls+=("$url")
  urls+=("https://ghfast.top/${url}")
  for attempt in "${urls[@]}"; do
    [ -n "$attempt" ] || continue
    if curl -fL --retry 2 --connect-timeout 20 --max-time 300 -o "$dest" "$attempt"; then
      return 0
    fi
    warn "下载失败，尝试其他线路: $attempt"
  done
  return 1
}

# 流式下载 + 解压，不把 tar.gz 落到磁盘
download_stream_extract() {
  local url=$1 dest=$2 attempt
  local urls=()
  [ -n "${SB_GH_PROXY:-}" ] && urls+=("${SB_GH_PROXY}${url}")
  urls+=("$url")
  urls+=("https://ghfast.top/${url}")
  for attempt in "${urls[@]}"; do
    [ -n "$attempt" ] || continue
    if curl -fL --retry 2 --connect-timeout 20 --max-time 300 "$attempt" \
        | tar -xzf - -C "$dest"; then
      return 0
    fi
    warn "下载/解压失败，尝试其他线路: $attempt"
  done
  return 1
}

# 流式失败时回退到压缩包下载；压缩包解压后立即删除
fetch_core_to_dir() {
  local url=$1 tmp=$2
  rm -rf "$tmp"
  mkdir -p "$tmp" || return 1
  if download_stream_extract "$url" "$tmp"; then
    return 0
  fi
  warn "流式解压失败，回退到压缩包下载 ..."
  rm -rf "$tmp"
  mkdir -p "$tmp" || return 1
  download_file "$url" "$tmp/sing-box.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  rm -f "$tmp/sing-box.tar.gz"
  return 0
}

install_core() {
  local version=${1:-}
  local tmp extract url base_url
  local asset_suffix=''
  local verr old_backup=0
  local bin_dir
  detect_arch || return 1
  ensure_dirs
  check_core_space || return 1
  ensure_deps || return 1
  check_core_space || return 1
  if [ -z "$version" ]; then
    info "正在查询 sing-box 最新版本 ..."
    version=$(get_latest_version) || true
    if [ -z "$version" ]; then
      error "获取最新版本失败，请检查网络连接"
      return 1
    fi
  fi
  case "$ARCH" in
    amd64|arm64|386|armv7|riscv64|loong64) asset_suffix="-musl" ;;
  esac
  base_url="https://github.com/SagerNet/sing-box/releases/download/v${version}"
  url="${base_url}/sing-box-${version}-linux-${ARCH}${asset_suffix}.tar.gz"
  info "准备安装 sing-box v${version} (linux-${ARCH}${asset_suffix})"

  bin_dir=$(dirname "$BIN")
  mkdir -p "$bin_dir" || { error "创建核心目录失败"; return 1; }
  # 解压目录放在目标文件系统内，避免 /tmp 为 tmpfs 时占用内存
  tmp=$(mktemp -d "$bin_dir/.sing-box-install.XXXXXX") || {
    error "创建临时目录失败"
    return 1
  }
  if ! fetch_core_to_dir "$url" "$tmp"; then
    if [ -n "$asset_suffix" ]; then
      warn "musl 静态版下载失败，尝试通用版 ..."
      url="${base_url}/sing-box-${version}-linux-${ARCH}.tar.gz"
      if ! fetch_core_to_dir "$url" "$tmp"; then
        error "核心下载失败，请检查网络或稍后重试"
        rm -rf "$tmp"
        return 1
      fi
    else
      error "核心下载失败，请检查网络或稍后重试"
      rm -rf "$tmp"
      return 1
    fi
  fi
  extract=$(find "$tmp" -type f -name sing-box 2>/dev/null | head -n1)
  if [ -z "$extract" ]; then
    error "未在压缩包中找到 sing-box 可执行文件"
    rm -rf "$tmp"
    return 1
  fi
  if ! mv -f "$extract" "${BIN}.new"; then
    error "写入核心失败"
    rm -rf "$tmp"
    return 1
  fi
  chmod 755 "${BIN}.new"
  rm -rf "$tmp"

  if [ -e "$BIN" ]; then
    if mv -f "$BIN" "${BIN}.old"; then
      old_backup=1
    else
      error "备份旧核心失败"
      rm -f "${BIN}.new"
      return 1
    fi
  fi
  if ! mv -f "${BIN}.new" "$BIN"; then
    rm -f "${BIN}.new"
    if [ "$old_backup" = "1" ]; then
      mv -f "${BIN}.old" "$BIN"
      warn "已恢复旧核心: $BIN"
    fi
    error "替换核心失败"
    return 1
  fi
  if ! verr=$("$BIN" version 2>&1); then
    error "核心已下载但无法运行:"
    printf '%s\n' "$verr" >&2
    rm -f "$BIN"
    if [ "$old_backup" = "1" ]; then
      mv -f "${BIN}.old" "$BIN"
      warn "已恢复旧核心: $BIN"
    fi
    return 1
  fi
  [ "$old_backup" = "1" ] && rm -f "${BIN}.old"
  info "核心安装完成: $("$BIN" version 2>/dev/null | head -n1)"
  return 0
}

write_service() {
  if has_systemd; then
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable sing-box >/dev/null 2>&1 || true
    info "systemd 服务已写入并设置开机自启"
    return 0
  fi

  if has_openrc; then
    cat > "$OPENRC_FILE" <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/etc/sing-box/log/sing-box.log"
error_log="/etc/sing-box/log/sing-box.log"

depend() {
    need net
}
EOF
    chmod 755 "$OPENRC_FILE"
    if command -v rc-update >/dev/null 2>&1; then
      rc-update add sing-box default >/dev/null 2>&1 || true
    fi
    info "OpenRC 服务已写入并设置开机自启"
    return 0
  fi

  warn "未检测到 systemd/OpenRC，将使用后台进程方式运行"
}

# ================================================================
#  配置生成与校验
# ================================================================

ensure_dirs() {
  mkdir -p "$SB_DIR" "$NODE_DIR" "$OUT_DIR" "$ROUTE_DIR" "$CERT_DIR" "$LOG_DIR"
  chmod 700 "$CERT_DIR" 2>/dev/null || true
  [ -f "$LOG_FILE" ] || touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}

count_nodes() {
  find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

count_outbounds() {
  find "$OUT_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# 合并节点/出站/路由为最终 config.json
# route.final 固定 direct: 本机自身流量不绕出口，出口只由节点绑定决定
rebuild_config() {
  local tmp rc=0 f rf tag out inb
  ensure_dirs
  tmp=$(mktemp "$SB_DIR/.config.XXXXXX") || { error "创建临时文件失败"; return 1; }

  jq -n --arg logfile "$LOG_FILE" --arg level "${LOG_LEVEL:-info}" '{
      log: { level: $level, timestamp: true, output: $logfile },
      inbounds: [],
      outbounds: [ { type: "direct", tag: "direct" } ],
      route: { rules: [], final: "direct", auto_detect_interface: true }
    }' > "$tmp" || { rm -f "$tmp"; error "初始化配置模板失败"; return 1; }

  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    if ! jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' "$f" >/dev/null 2>&1; then
      error "节点文件不是合法的 inbound 对象: $f"
      rc=1
      break
    fi
    if ! jq --slurpfile inc "$f" '
        .inbounds += ($inc | map(del(._meta)))
        | .inbounds += ($inc | map(._meta.extra_inbounds // []) | add // [])
      ' "$tmp" > "$tmp.next"; then
      rc=1
      break
    fi
    mv -f "$tmp.next" "$tmp"
  done
  shopt -u nullglob

  if [ "$rc" -eq 0 ]; then
    shopt -s nullglob
    for f in "$OUT_DIR"/*.json; do
      if ! jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' "$f" >/dev/null 2>&1; then
        error "出站文件不是合法的 outbound 对象: $f"
        rc=1
        break
      fi
      if ! jq --slurpfile inc "$f" '.outbounds += $inc' "$tmp" > "$tmp.next"; then
        rc=1
        break
      fi
      mv -f "$tmp.next" "$tmp"
    done
    shopt -u nullglob
  fi

  if [ "$rc" -eq 0 ]; then
    shopt -s nullglob
    for rf in "$ROUTE_DIR"/*.outbound; do
      tag=$(basename "$rf" .outbound)
      [ -f "$NODE_DIR/$tag.json" ] || continue
      out=$(head -n1 "$rf" 2>/dev/null || true)
      [ -n "$out" ] || continue
      if ! jq -e --arg t "$out" '.outbounds[] | select(.tag == $t)' "$tmp" >/dev/null 2>&1; then
        warn "节点 [$tag] 的出口 [$out] 不存在，已忽略"
        continue
      fi
      inb=$(jq -c --arg t "$tag" '[$t] + (._meta.extra_inbounds // [] | map(.tag))' \
        "$NODE_DIR/$tag.json" 2>/dev/null || true)
      [ -n "$inb" ] || inb=$(jq -cn --arg t "$tag" '[$t]')
      if ! jq --argjson inb "$inb" --arg out "$out" \
        '.route.rules += [{inbound: $inb, outbound: $out}]' "$tmp" > "$tmp.next"; then
        rc=1
        break
      fi
      mv -f "$tmp.next" "$tmp"
    done
    shopt -u nullglob
  fi

  if [ "$rc" -eq 0 ]; then
    if ! jq -e '
        ([.inbounds[].tag] | length) == ([.inbounds[].tag] | unique | length)
        and ([.outbounds[].tag] | length) == ([.outbounds[].tag] | unique | length)
      ' "$tmp" >/dev/null 2>&1; then
      error "存在重复的 inbound/outbound tag，请检查节点或出站名称"
      rc=1
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp" "$tmp.next"
    error "生成 config.json 失败，请检查节点/出站文件是否为合法 JSON"
    return 1
  fi

  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$CONF"; then
    rm -f "$tmp" "$tmp.next"
    error "写入 config.json 失败"
    return 1
  fi
  chmod 600 "$CONF" 2>/dev/null || true
  return 0
}

# 生成并校验; 校验失败回滚到原配置
check_config() {
  local out
  local backup=''
  ensure_dirs
  if [ -s "$CONF" ]; then
    backup=$(mktemp "$SB_DIR/.config.bak.XXXXXX") || backup=''
    if [ -n "$backup" ]; then
      cp -f "$CONF" "$backup" 2>/dev/null || { rm -f "$backup"; backup=''; }
    fi
  fi

  if ! rebuild_config; then
    [ -n "$backup" ] && rm -f "$backup"
    return 1
  fi

  if ! out=$("$BIN" check -c "$CONF" 2>&1); then
    if [ -n "$backup" ]; then
      cp -f "$backup" "$CONF" 2>/dev/null || true
      rm -f "$backup"
    else
      rm -f "$CONF"
    fi
    error "配置校验失败:"
    printf '%s\n' "$out" >&2
    return 1
  fi

  [ -n "$backup" ] && rm -f "$backup"
  return 0
}

# ================================================================
#  随机值生成 / 核心能力检测 / 公网信息 / 编码工具
# ================================================================

# ---------------- 随机值 ----------------
trim_space() {
  local s=${1:-}
  printf '%s' "${s//[[:space:]]/}"
}

gen_uuid() {
  local u
  u=$(trim_space "$("$BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || true)")
  if [ -n "$u" ]; then
    printf '%s' "$u"
    return 0
  fi
  u=$(openssl rand -hex 16 2>/dev/null || true)
  [ -n "$u" ] || return 1
  printf '%s-%s-%s-%s-%s' "${u:0:8}" "${u:8:4}" "${u:12:4}" "${u:16:4}" "${u:20:12}"
}

gen_hex() {
  local bytes=${1:-8} v
  v=$( ("$BIN" generate rand --hex "$bytes" 2>/dev/null || openssl rand -hex "$bytes") | tr -d '[:space:]' )
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

gen_b64() {
  local bytes=${1:-16} v
  while true; do
    v=$( ("$BIN" generate rand --base64 "$bytes" 2>/dev/null || \
        openssl rand -base64 "$bytes" 2>/dev/null) | tr -d '[:space:]' )
    [ -n "$v" ] || return 1
    case "$v" in /*) continue ;; esac
    printf '%s' "$v"
    return 0
  done
}

gen_reality_keypair() {
  "$BIN" generate reality-keypair 2>/dev/null
}

# ---------------- 核心版本 ----------------
singbox_version() {
  [ -x "$BIN" ] || return 0
  "$BIN" version 2>/dev/null | head -n1 | awk '{print $3}'
}

core_at_least() {
  local want_major=$1 want_minor=$2 ver major rest minor
  ver=$(singbox_version)
  ver=${ver#v}
  [ -n "$ver" ] || return 1
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -gt "$want_major" ] && return 0
  [ "$major" -eq "$want_major" ] && [ "$minor" -ge "$want_minor" ]
}

core_supports_snell()  { core_at_least 1 14; }
core_supports_anytls() { core_at_least 1 12; }

# ---------------- 低资源适配 ----------------
detect_resources() {
  local mem=0 cg=0 f val
  if [ -r "$MEMINFO_FILE" ]; then
    mem=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO_FILE" 2>/dev/null || echo 0)
  fi
  case "$mem" in ''|*[!0-9]*) mem=0 ;; esac

  # LXC 里 /proc/meminfo 可能是宿主机内存，优先取更小的 cgroup 限制
  for f in "$CGROUP_MEM_MAX_FILE" "$CGROUP_MEM_LIMIT_FILE"; do
    [ -r "$f" ] || continue
    val=$(cat "$f" 2>/dev/null || true)
    [ "$val" = "max" ] && continue
    case "$val" in ''|*[!0-9]*) continue ;; esac
    val=$((val / 1024))
    if [ "$val" -gt 0 ] && { [ "$cg" -eq 0 ] || [ "$val" -lt "$cg" ]; }; then
      cg=$val
    fi
  done
  if [ "$cg" -gt 0 ] && { [ "$mem" -eq 0 ] || [ "$cg" -lt "$mem" ]; }; then
    mem=$cg
  fi
  MEM_TOTAL_KB=$mem

  if [ "$mem" -gt 0 ] && [ "$mem" -lt 262144 ]; then
    LOW_MEMORY=1
  else
    LOW_MEMORY=0
  fi

  if [ -n "${SB_LOG_LEVEL:-}" ]; then
    LOG_LEVEL=$SB_LOG_LEVEL
  elif [ "$LOW_MEMORY" = "1" ]; then
    LOG_LEVEL=warn
  else
    LOG_LEVEL=info
  fi
  case "$LOG_LEVEL" in
    trace|debug|info|warn|error|fatal|panic) ;;
    *) LOG_LEVEL=info ;;
  esac

  if [ -n "${SB_LOG_MAX_KB:-}" ] && [[ $SB_LOG_MAX_KB =~ ^[1-9][0-9]*$ ]]; then
    LOG_MAX_KB=$SB_LOG_MAX_KB
  fi
  if [ -n "${SB_CORE_MIN_FREE_KB:-}" ] && [[ $SB_CORE_MIN_FREE_KB =~ ^[1-9][0-9]*$ ]]; then
    CORE_MIN_FREE_KB=$SB_CORE_MIN_FREE_KB
  fi
}

free_kb_for_path() {
  local p=${1:-/}
  df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4; exit}'
}

# 安装/升级前检查目标文件系统空间
# 旧核心已占用空间，free 已反映；这里只要求新核心和缓冲所需空间
check_core_space() {
  local dir need free1 free2 free=''
  dir=$(dirname "$BIN")
  mkdir -p "$dir" 2>/dev/null || true
  need=$CORE_MIN_FREE_KB
  free1=$(free_kb_for_path "$dir")
  free2=$(free_kb_for_path "$SB_DIR" 2>/dev/null || true)
  for x in "$free1" "$free2"; do
    case "$x" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$free" ] || [ "$x" -lt "$free" ]; then
      free=$x
    fi
  done
  [ -n "$free" ] || return 0
  if [ "$free" -lt "$need" ]; then
    error "磁盘空间不足: 需要约 $((need / 1024))MB，当前可用 $((free / 1024))MB"
    error "请清理磁盘后重试；可用 SB_CORE_MIN_FREE_KB 调整阈值"
    return 1
  fi
  return 0
}

# ---------------- 网络环境 ----------------
# 只有 IPv6 内核可用时才监听 ::；否则监听 0.0.0.0。
# bindv6only=1 时 :: 不接收 IPv4，save_node 会额外生成一个 0.0.0.0 入站。
detect_net_env() {
  local disabled=0
  IPV6_V6ONLY=0
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
    disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)
  fi
  if [ -r /proc/sys/net/ipv6/bindv6only ]; then
    IPV6_V6ONLY=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 0)
  fi
  if [ "$disabled" = "1" ]; then
    NODE_LISTEN="0.0.0.0"
    IPV6_V6ONLY=0
  else
    NODE_LISTEN="::"
  fi
}

has_ipv6_local() {
  [ -s /proc/net/if_inet6 ]
}

# ---------------- 分享域名 ----------------
# 动态 IP / DDNS: 设置后分享链接优先使用域名，不再输出 IP
load_server_host() {
  local h=${SB_SERVER_HOST:-}
  if [ -z "$h" ] && [ -s "$SERVER_HOST_FILE" ]; then
    h=$(head -n1 "$SERVER_HOST_FILE" 2>/dev/null || true)
  fi
  h=$(printf '%s' "$h" | tr -d '[:space:]')
  if [ -n "$h" ] && ! valid_sni "$h"; then
    h=""
  fi
  SERVER_HOST=$h
}

# ---------------- 公网信息 ----------------
load_server_ip4() {
  local ip='' url
  if [ -n "${SERVER_IP4:-}" ]; then
    return 0
  fi
  if [ -s "$IP4_FILE" ]; then
    ip=$(head -n1 "$IP4_FILE" 2>/dev/null || true)
  fi
  if [ -z "$ip" ]; then
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
      ip=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)
      [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip=''
      [ -n "$ip" ] && break
    done
  fi
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1 || true)
  fi
  SERVER_IP4=$ip
  [ -n "$ip" ] && printf '%s\n' "$ip" > "$IP4_FILE" 2>/dev/null || true
}

load_server_ip6() {
  local ip='' url
  if [ -n "${SERVER_IP6:-}" ]; then
    return 0
  fi
  if [ "$NODE_LISTEN" != "::" ]; then
    return 0
  fi
  if [ -s "$IP6_FILE" ]; then
    ip=$(head -n1 "$IP6_FILE" 2>/dev/null || true)
  fi
  if [ -z "$ip" ] && has_ipv6_local; then
    for url in https://api6.ipify.org https://ipv6.icanhazip.com; do
      ip=$(curl -6 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)
      [[ $ip == *:* ]] || ip=''
      [ -n "$ip" ] && break
    done
  fi
  if [ -z "$ip" ] && has_ipv6_local; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' \
      | grep ':' | grep -v '^fe80:' | grep -v '^::1$' | sed 's/%.*//' | head -n1 || true)
  fi
  SERVER_IP6=$ip
  [ -n "$ip" ] && printf '%s\n' "$ip" > "$IP6_FILE" 2>/dev/null || true
}

# load_server_ip 选择主地址：IPv4 优先，IPv6 兜底。
load_server_ip() {
  if [ "${SERVER_IP_LOADED:-0}" = "1" ]; then
    return 0
  fi
  load_server_ip4
  load_server_ip6
  if [ -n "${SERVER_IP4:-}" ]; then
    SERVER_IP=$SERVER_IP4
  elif [ -n "${SERVER_IP6:-}" ]; then
    SERVER_IP=$SERVER_IP6
  else
    SERVER_IP=''
  fi
  SERVER_IP_LOADED=1
}

country_code_valid() {
  [[ ${1:-} =~ ^[A-Z]{2}$ ]]
}

normalize_country_code() {
  local c
  c=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
  if country_code_valid "$c"; then printf '%s' "$c"; else printf 'XX'; fi
}

get_server_country_code() {
  local cc='' json=''
  if [ -s "$COUNTRY_FILE" ]; then
    cc=$(head -n1 "$COUNTRY_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' || true)
    if country_code_valid "$cc" && [ "$cc" != "XX" ]; then
      printf '%s' "$cc"
      return 0
    fi
  fi

  load_server_ip
  if [ -n "${SERVER_IP:-}" ] && command -v jq >/dev/null 2>&1; then
    json=$(curl -fsS --connect-timeout 5 --max-time 8 \
      "http://ip-api.com/json/${SERVER_IP}?fields=status,countryCode" 2>/dev/null || true)
    [ "$(jq -r '.status // empty' <<<"$json" 2>/dev/null || true)" = "success" ] && \
      cc=$(jq -r '.countryCode // empty' <<<"$json" 2>/dev/null || true)
    if ! country_code_valid "$(printf '%s' "$cc" | tr '[:lower:]' '[:upper:]')"; then
      json=$(curl -fsS --connect-timeout 5 --max-time 8 "https://ipwho.is/${SERVER_IP}" 2>/dev/null || true)
      [ "$(jq -r '.success // false' <<<"$json" 2>/dev/null || true)" = "true" ] && \
        cc=$(jq -r '.country_code // empty' <<<"$json" 2>/dev/null || true)
    fi
  fi
  cc=$(normalize_country_code "$cc")
  if [ "$cc" != "XX" ]; then
    printf '%s\n' "$cc" > "$COUNTRY_FILE" 2>/dev/null || true
  fi
  printf '%s' "$cc"
}

# ---------------- 编码 ----------------
urlenc() {
  jq -rn --arg v "${1:-}" '$v|@uri'
}

# 百分号解码: 只处理合法的 %HH，保留字面反斜杠和损坏的百分号。
# urldec_raw 不把 + 当空格，适合 URL userinfo / 密码 / Base64 密钥。
urldec_raw() {
  local s=${1:-} out='' prefix hex ch
  while [[ $s == *%* ]]; do
    prefix=${s%%%*}
    out+=$prefix
    s=${s#*%}
    if [[ $s =~ ^([0-9A-Fa-f]{2})(.*)$ ]]; then
      hex=${BASH_REMATCH[1]}
      printf -v ch '%b' "\\x$hex"
      out+=$ch
      s=${BASH_REMATCH[2]}
    else
      out+='%'
    fi
  done
  out+=$s
  printf '%s' "$out"
}

# 查询串/ fragment 语义: + 表示空格
urldec() {
  urldec_raw "${1//+/ }"
}

# 统一 Base64: 去掉空白、URL-safe 转标准字符、按长度补齐 padding
b64norm() {
  local s=${1:-}
  s=$(printf '%s' "$s" | tr -d '[:space:]' | tr '_-' '/+')
  case $(( ${#s} % 4 )) in
    0) ;;
    2) s+='==' ;;
    3) s+='=' ;;
    *) return 1 ;;
  esac
  printf '%s' "$s"
}

b64decode() {
  local s
  s=$(b64norm "${1:-}") || return 1
  printf '%s' "$s" | base64 -d 2>/dev/null
}

b64url() {
  printf '%s' "${1:-}" | base64 | tr -d '[:space:]' | tr '+/' '-_' | tr -d '='
}

# ================================================================
#  运行管理: 启动 / 停止 / 重启 / 状态 / 日志 / 菜单
# ================================================================

pid_is_singbox() {
  local pid=${1:-} comm=''
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/comm" ]; then
    IFS= read -r comm < "/proc/$pid/comm" || true
    [ "$comm" = "sing-box" ]
    return $?
  fi
  command -v ps >/dev/null 2>&1 || return 1
  comm=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ' || true)
  [ "$comm" = "sing-box" ]
}

core_running() {
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl is-active --quiet sing-box 2>/dev/null && return 0
  fi
  if has_openrc && [ -f "$OPENRC_FILE" ]; then
    rc-service sing-box status >/dev/null 2>&1 && return 0
  fi
  if [ -f "$PID_FILE" ]; then
    pid_is_singbox "$(cat "$PID_FILE" 2>/dev/null || true)" && return 0
  fi
  return 1
}

# 日志超过上限时轮转；保留一份 .1，避免小存储被日志写满
rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local size max
  max=$((LOG_MAX_KB * 1024))
  size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -gt "$max" ] || return 0
  if mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null; then
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    info "日志超过 $((LOG_MAX_KB / 1024))MB，已轮转到 $LOG_FILE.1"
  else
    : > "$LOG_FILE" 2>/dev/null || true
    warn "日志超过上限，已截断: $LOG_FILE"
  fi
}

start_core() {
  [ -x "$BIN" ] || { error "未安装 sing-box 核心，请先安装"; return 1; }
  if core_running; then
    info "sing-box 已在运行"
    return 0
  fi
  ensure_dirs
  rotate_log
  check_config || return 1

  if has_systemd; then
    [ -f "$SERVICE_FILE" ] || write_service
    systemctl daemon-reload 2>/dev/null || true
    systemctl start sing-box 2>/dev/null || true
    sleep 1
    if core_running; then
      info "sing-box 已启动"
      return 0
    fi
    error "启动失败，最近日志:"
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
    return 1
  fi

  if has_openrc; then
    [ -f "$OPENRC_FILE" ] || write_service
    rc-service sing-box start >/dev/null 2>&1 || true
    sleep 1
    if core_running; then
      info "sing-box 已启动 (OpenRC)"
      return 0
    fi
    error "启动失败，最近日志:"
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
    return 1
  fi

  nohup "$BIN" run -c "$CONF" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    info "sing-box 已启动 (PID $pid)"
    return 0
  fi
  error "启动失败，请查看日志: $LOG_FILE"
  rm -f "$PID_FILE"
  return 1
}

stop_core() {
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl stop sing-box 2>/dev/null || true
  fi
  if has_openrc && [ -f "$OPENRC_FILE" ]; then
    rc-service sing-box stop >/dev/null 2>&1 || true
  fi
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if pid_is_singbox "$pid"; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  info "sing-box 已停止"
}

restart_core() {
  [ -x "$BIN" ] || { error "未安装 sing-box 核心"; return 1; }
  check_config || return 1
  rotate_log

  if has_systemd; then
    [ -f "$SERVICE_FILE" ] || write_service
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart sing-box 2>/dev/null || true
    sleep 1
    core_running && { info "sing-box 已重启"; return 0; }
    error "重启失败，最近日志:"
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
    return 1
  fi

  if has_openrc; then
    [ -f "$OPENRC_FILE" ] || write_service
    rc-service sing-box restart >/dev/null 2>&1 || true
    sleep 1
    core_running && { info "sing-box 已重启 (OpenRC)"; return 0; }
    error "重启失败，最近日志:"
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
    return 1
  fi

  stop_core >/dev/null 2>&1 || true
  start_core
}

# 配置变更后应用: 校验 + 按需重启
apply_changes() {
  if [ -x "$BIN" ]; then
    check_config || return 1
  else
    rebuild_config || return 1
  fi
  if [ -x "$BIN" ]; then
    if core_running; then
      if confirm "配置已更新，是否重启核心使其生效?"; then
        restart_core || return 1
      else
        warn "未重启，新配置尚未生效"
      fi
    else
      if confirm "核心当前未运行，是否立即启动?" "n"; then
        start_core || return 1
      fi
    fi
  fi
  return 0
}

show_status() {
  local ver mem_total=0 mem_avail=0 disk_free='' log_kb=0
  ver=$(singbox_version)
  printf '%s\n' "-------------- 运行状态 --------------"
  printf '核心版本 : %s\n' "${ver:-未安装}"
  if core_running; then
    printf '运行状态 : %s运行中%s\n' "$C_GRN" "$C_RESET"
  else
    printf '运行状态 : %s已停止%s\n' "$C_RED" "$C_RESET"
  fi
  printf '节点数量 : %s\n' "$(count_nodes)"
  printf '出站数量 : %s\n' "$(count_outbounds)"
  load_server_host
  printf '分享域名 : %s\n' "${SERVER_HOST:-未设置（使用公网 IP）}"
  load_server_ip4
  load_server_ip6
  printf '公网 IPv4 : %s\n' "${SERVER_IP4:-无}"
  printf '公网 IPv6 : %s\n' "${SERVER_IP6:-无}"
  printf '监听地址 : %s%s\n' "$NODE_LISTEN" \
    "$([ "$NODE_LISTEN" = "::" ] && [ "$IPV6_V6ONLY" = "1" ] && printf ' (bindv6only=1，节点会附加 IPv4 入站)')"
  printf '配置文件 : %s\n' "$CONF"
  printf '日志文件 : %s\n' "$LOG_FILE"
  if [ -f "$LOG_FILE" ]; then
    log_kb=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
    case "$log_kb" in ''|*[!0-9]*) log_kb=0 ;; esac
    log_kb=$((log_kb / 1024))
  fi
  printf '日志级别 : %s%s\n' "${LOG_LEVEL:-info}" \
    "$([ "${LOW_MEMORY:-0}" = "1" ] && printf ' (低内存模式)')"
  printf '日志大小 : %s KB (上限 %s KB)\n' "$log_kb" "${LOG_MAX_KB:-0}"
  mem_total=${MEM_TOTAL_KB:-0}
  if [ -r "$MEMINFO_FILE" ]; then
    [ "$mem_total" -gt 0 ] || \
      mem_total=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO_FILE" 2>/dev/null || echo 0)
    mem_avail=$(awk '/^MemAvailable:/ {print $2}' "$MEMINFO_FILE" 2>/dev/null || echo 0)
    case "$mem_total" in ''|*[!0-9]*) mem_total=0 ;; esac
    case "$mem_avail" in ''|*[!0-9]*) mem_avail=0 ;; esac
  fi
  if [ "$mem_total" -gt 0 ]; then
    printf '内存     : %s MB / 可用 %s MB\n' "$((mem_total / 1024))" "$((mem_avail / 1024))"
  fi
  disk_free=$(free_kb_for_path "$SB_DIR")
  case "$disk_free" in ''|*[!0-9]*) disk_free='' ;; esac
  [ -n "$disk_free" ] && printf '磁盘剩余 : %s MB\n' "$((disk_free / 1024))"
  printf '%s\n' "--------------------------------------"
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl status sing-box --no-pager -l 2>/dev/null | head -n 25 || true
  elif has_openrc && [ -f "$OPENRC_FILE" ]; then
    rc-service sing-box status 2>/dev/null || true
  elif [ -f "$PID_FILE" ]; then
    printf '后台进程 PID: %s\n' "$(cat "$PID_FILE" 2>/dev/null || true)"
  fi
  if command -v ss >/dev/null 2>&1; then
    printf '\n监听端口:\n'
    ss -lntup 2>/dev/null | awk 'NR==1 || /sing-box/' || true
  fi
}

show_logs() {
  local c
  printf '1) 最近 100 行日志\n2) 实时跟踪日志 (Ctrl+C 返回)\n3) systemd 日志 (仅 systemd)\n0) 返回\n'
  ask c "请选择" "1"
  case "$c" in
    1)
      if [ -s "$LOG_FILE" ]; then
        tail -n 100 "$LOG_FILE"
      elif has_systemd; then
        warn "暂无日志文件，读取 systemd 日志"
        journalctl -u sing-box -n 100 --no-pager 2>/dev/null || true
      else
        warn "暂无日志文件"
      fi
      pause
      ;;
    2)
      [ -f "$LOG_FILE" ] || { warn "暂无日志文件"; return 0; }
      info "实时跟踪日志 (Ctrl+C 返回菜单)"
      trap ':' INT
      tail -f "$LOG_FILE" || true
      trap - INT
      ;;
    3)
      if has_systemd; then
        info "实时查看 systemd 日志 (Ctrl+C 返回菜单)"
        trap ':' INT
        journalctl -u sing-box -f --no-pager 2>/dev/null || true
        trap - INT
      else
        warn "当前系统不是 systemd，请使用第 2 项"
        pause
      fi
      ;;
    0|*) ;;
  esac
}

menu_runtime() {
  local c
  while true; do
    printf '\n%s\n' "------------- 运行管理 -------------"
    printf ' 1) 启动核心\n'
    printf ' 2) 停止核心\n'
    printf ' 3) 重启核心\n'
    printf ' 4) 查看日志\n'
    printf ' 5) 查看运行状态\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) start_core; pause ;;
      2) stop_core; pause ;;
      3) restart_core; pause ;;
      4) show_logs ;;
      5) show_status; pause ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ================================================================
#  节点公共逻辑: 命名、端口、参数校验、证书、持久化
#  节点文件结构:
#    { ...sing-box inbound 字段..., "_meta": {proto, pbk, insecure} }
#  生成 config.json 时会删除 _meta。
# ================================================================

# ---------------- 节点名称 ----------------
# 名称是否已被节点、出站或内部附加入站 tag 占用
node_tag_in_use() {
  local t=$1
  local exclude=${2:-}
  local f base
  [ -e "$NODE_DIR/$t.json" ] && return 0
  [ -e "$OUT_DIR/$t.json" ] && return 0
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    base=$(basename "$f" .json)
    [ "$base" = "$exclude" ] && continue
    if jq -e --arg t "$t" '._meta.extra_inbounds // [] | any(.tag == $t)' \
        "$f" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

prompt_tag() {
  local def=${1:-node} v
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    [ -n "${BATCH_TAG:-}" ] || { error "批量模式缺少节点名称"; return 1; }
    WIZ_TAG=$BATCH_TAG
    return 0
  fi
  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    WIZ_TAG=$WIZ_EDIT_TAG
    return 0
  fi
  # 单节点创建时 create_single_node 已经按“国家码-协议”算好默认名
  [ -n "${WIZ_TAG:-}" ] && def=$WIZ_TAG
  while true; do
    ask v "节点名称" "$def"
    case "$v" in
      '')             warn "名称不能为空"; continue ;;
      direct)         warn "direct 是保留名称"; continue ;;
      *" "*|*"	"*|*/*|*\\*|.*|*,*|*=*) warn "名称不能包含空格、逗号、等号或斜杠，且不能以点开头"; continue ;;
    esac
    if node_tag_in_use "$v"; then
      warn "名称 [$v] 已被节点或出站占用"
      continue
    fi
    WIZ_TAG=$v
    return 0
  done
}

# 生成“国家码-协议”名称，已存在时追加 -2、-3 ...
make_node_tag() {
  local loc=$1
  local name=$2
  local base="${loc}-${name}"
  local t=$base
  local n=2
  while node_tag_in_use "$t"; do
    t="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$t"
}

# ---------------- 数据传输类型 ----------------
transport_label() {
  case "${1:-tcp}" in
    both) printf 'tcp+udp' ;;
    *)    printf '%s' "${1:-tcp}" ;;
  esac
}

transports_conflict() {
  local a=${1:-tcp} b=${2:-tcp}
  [ "$a" = "both" ] || [ "$b" = "both" ] || [ "$a" = "$b" ]
}

# ---------------- 端口占用 ----------------
# LXC 里可能没有 ss/netstat，直接解析 /proc/net
proc_port_in_use() {
  local port=$1 transport=${2:-tcp} hex f state
  local -a files=()
  if [ "$transport" = "both" ]; then
    proc_port_in_use "$port" tcp && return 0
    proc_port_in_use "$port" udp && return 0
    return 1
  fi
  [ -d "$PROC_NET_DIR" ] || return 1
  hex=$(printf '%04X' "$port")
  if [ "$transport" = "udp" ]; then
    files=("$PROC_NET_DIR/udp" "$PROC_NET_DIR/udp6")
    state="07"
  else
    files=("$PROC_NET_DIR/tcp" "$PROC_NET_DIR/tcp6")
    state="0A"
  fi
  for f in "${files[@]}"; do
    [ -r "$f" ] || continue
    if awk -v p=":$hex" -v st="$state" \
        '$2 ~ p"$" && $4 == st {found=1} END {exit !found}' "$f"; then
      return 0
    fi
  done
  return 1
}

system_port_in_use() {
  local port=$1 transport=${2:-tcp} out=''
  if [ "$transport" = "both" ]; then
    system_port_in_use "$port" tcp && return 0
    system_port_in_use "$port" udp && return 0
    return 1
  fi
  if command -v ss >/dev/null 2>&1; then
    if [ "$transport" = "udp" ]; then
      out=$(ss -lnu 2>/dev/null || true)
    else
      out=$(ss -lnt 2>/dev/null || true)
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if [ "$transport" = "udp" ]; then
      out=$(netstat -lnu 2>/dev/null || true)
    else
      out=$(netstat -lnt 2>/dev/null || true)
    fi
  fi
  if [ -n "$out" ] && printf '%s\n' "$out" | awk '{print $4}' | grep -qE "[:.]${port}$"; then
    return 0
  fi
  proc_port_in_use "$port" "$transport"
}

# 节点 JSON 的传输类型按实际 type 判断
node_transport() {
  local t
  case "${1:-}" in
    hysteria2|tuic) t="udp" ;;
    shadowsocks)    t="both" ;;
    *)              t="tcp" ;;
  esac
  printf '%s' "$t"
}

node_port_in_use() {
  local port=$1 transport=${2:-} f base type t
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    base=$(basename "$f" .json)
    [ "$base" = "${WIZ_EDIT_TAG:-}" ] && continue
    if [ -n "$transport" ]; then
      type=$(jq -r '.type // empty' "$f" 2>/dev/null || true)
      t=$(node_transport "$type")
      transports_conflict "$t" "$transport" || continue
    fi
    if jq -e --argjson p "$port" '.listen_port == $p' "$f" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

batch_port_in_use() {
  local port=$1 transport=${2:-tcp} i
  [ ${#BATCH_PORT_LIST[@]} -gt 0 ] || return 1
  for i in "${!BATCH_PORT_LIST[@]}"; do
    if [ "${BATCH_PORT_LIST[$i]}" = "$port" ] && \
       transports_conflict "${BATCH_PORT_TYPES[$i]:-tcp}" "$transport"; then
      return 0
    fi
  done
  return 1
}

port_available() {
  local port=$1 transport=${2:-tcp}
  node_port_in_use "$port" "$transport" && return 1
  system_port_in_use "$port" "$transport" && return 1
  batch_port_in_use "$port" "$transport" && return 1
  return 0
}

random_free_port() {
  local transport=${1:-tcp} cand i
  for ((i = 0; i < 200; i++)); do
    cand=$((RANDOM % 50000 + 10000))
    if port_available "$cand" "$transport"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  for ((cand = 10000; cand < 60000; cand++)); do
    if port_available "$cand" "$transport"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  printf '%s' "$((10000 + RANDOM % 50000))"
}

valid_port() {
  local v=${1:-}
  [[ $v =~ ^[0-9]{1,5}$ ]] || return 1
  v=$((10#$v))
  [ "$v" -ge 1 ] && [ "$v" -le 65535 ]
}

# 向导唯一的端口询问入口。编辑时回车保留原值，新建时回车随机。
ask_port() {
  local transport=${1:-tcp} def=${WIZ_PORT:-} prompt="监听端口" v
  if [ "${BATCH_MODE:-0}" = "1" ] && [ -n "${BATCH_PORT:-}" ]; then
    WIZ_PORT=$BATCH_PORT
    return 0
  fi
  if [ -z "${WIZ_EDIT_TAG:-}" ]; then
    def=""
    prompt="监听端口（回车随机）"
  fi
  while true; do
    ask v "$prompt" "$def"
    if [ -z "$v" ]; then
      v=$(random_free_port "$transport")
      printf '\n'
      info "使用随机监听端口: $v/$(transport_label "$transport")"
    elif ! valid_port "$v"; then
      warn "监听端口范围 1-65535"
      continue
    else
      v=$((10#$v))
    fi
    if [ -z "${WIZ_EDIT_TAG:-}" ] || [ "$v" != "$def" ]; then
      if ! port_available "$v" "$transport"; then
        warn "监听端口 $v 已被其他节点或系统服务占用，请更换"
        continue
      fi
    fi
    WIZ_PORT=$v
    return 0
  done
}

# ---------------- 参数校验 ----------------
valid_uuid() {
  [[ ${1:-} =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

valid_short_id() {
  local v=${1:-}
  [ "${#v}" -le 16 ] && [[ $v =~ ^([0-9a-fA-F]{2})*$ ]]
}

valid_sni() {
  [ -n "${1:-}" ] && [[ ${1:-} =~ ^[A-Za-z0-9._-]+$ ]]
}

valid_psk() {
  local v=${1:-} len
  case "$v" in *[[:space:],]*) return 1 ;; esac
  len=$(printf '%s' "$v" | wc -c | tr -d ' ')
  [ "$len" -ge 12 ] && [ "$len" -le 255 ]
}

valid_ss2022_key() {
  local bytes=$1 key=$2 len
  len=$(b64decode "$key" | wc -c | tr -d ' ' || true)
  [ "$len" = "$bytes" ]
}

# ---------------- 节点读取 ----------------
meta_get() {
  local tag=$1
  local key=$2
  local file="$NODE_DIR/$tag.json"
  [ -s "$file" ] || return 0
  jq -r --arg k "$key" '._meta[$k] // empty' "$file" 2>/dev/null || true
}

node_get() {
  local tag=$1 filter=$2 def=${3:-}
  [ -s "$NODE_DIR/$tag.json" ] || { printf '%s' "$def"; return 0; }
  jq -r --arg d "$def" "$filter // \$d" "$NODE_DIR/$tag.json" 2>/dev/null || printf '%s' "$def"
}

# ---------------- 保存 ----------------
save_node() {
  local tag=$1 proto=$2 json=$3 pbk=${4:-} insecure=${5:-0}
  local tmp extra='[]' extra_tag normalized
  case "$insecure" in 0|1) ;; *) insecure=0 ;; esac

  # 监听地址由当前环境决定；bindv6only=1 时额外生成 IPv4 入站
  if ! normalized=$(jq --arg listen "$NODE_LISTEN" '.listen=$listen' <<<"$json" 2>/dev/null); then
    error "写入节点配置失败"
    return 1
  fi
  json=$normalized
  if [ "${NODE_LISTEN:-::}" = "::" ] && [ "${IPV6_V6ONLY:-0}" = "1" ]; then
    extra_tag="${tag}-v4"
    while node_tag_in_use "$extra_tag" "$tag"; do
      extra_tag="${extra_tag}-2"
    done
    if ! extra=$(jq -n --arg t "$extra_tag" --argjson base "$json" \
        '[$base + {tag:$t, listen:"0.0.0.0"}]'); then
      error "生成 IPv4 入站失败"
      return 1
    fi
  fi

  tmp=$(mktemp "$NODE_DIR/.node.XXXXXX") || { error "创建临时文件失败"; return 1; }
  if ! printf '%s\n' "$json" | jq --arg proto "$proto" --arg pbk "$pbk" --argjson insecure "$insecure" \
      --argjson extra "$extra" \
      '. + {_meta:{proto:$proto,pbk:$pbk,insecure:$insecure,extra_inbounds:$extra}}' > "$tmp"; then
    rm -f "$tmp"
    error "写入节点配置失败"
    return 1
  fi
  chmod 600 "$tmp"
  if ! mv -f "$tmp" "$NODE_DIR/$tag.json"; then
    rm -f "$tmp"
    error "写入节点配置失败"
    return 1
  fi
  CREATED_TAGS+=("$tag")
  info "节点 [$tag] 已保存"
}

# ---------------- 证书 ----------------
cert_base() { printf '%s/cert.crt' "$CERT_DIR"; }
key_base()  { printf '%s/cert.key' "$CERT_DIR"; }

generate_selfsigned_cert() {
  local domain=$1 crt key cnf
  crt=$(cert_base)
  key=$(key_base)
  cnf="$CERT_DIR/cert.cnf"
  mkdir -p "$CERT_DIR"
  cat > "$cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = $domain

[v3_req]
subjectAltName = @alt_names
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $domain
EOF
  if ! openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -sha256 \
    -keyout "$key" -out "$crt" -config "$cnf" >/dev/null 2>&1; then
    error "自签证书生成失败"
    return 1
  fi
  chmod 600 "$key" 2>/dev/null || true
  chmod 644 "$crt" 2>/dev/null || true
  CERT_FILE=$crt
  KEY_FILE=$key
  return 0
}

# 已有证书则复用；SNI 变化不重签。
# tls_cert_json 只返回 JSON；各协议保存节点时直接传 insecure=1。
ensure_cert() {
  local domain=$1
  if [ -s "$(cert_base)" ] && [ -s "$(key_base)" ]; then
    CERT_FILE=$(cert_base)
    KEY_FILE=$(key_base)
    return 0
  fi
  generate_selfsigned_cert "$domain"
}

ask_sni() {
  local def=${WIZ_SNI:-} d
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    [ -n "${BATCH_SNI:-}" ] || { error "批量创建缺少 SNI域名"; return 1; }
    WIZ_SNI=$BATCH_SNI
    return 0
  fi
  while true; do
    ask d "SNI域名" "$def"
    if valid_sni "$d"; then
      WIZ_SNI=$d
      return 0
    fi
    warn "SNI域名不能为空，且只能包含字母、数字、点、下划线和短横线"
    def=""
  done
}

ask_reality_port() {
  local def=${WIZ_REALITY_PORT:-443} v
  if [ "${BATCH_MODE:-0}" = "1" ] && [ -n "${BATCH_REALITY_PORT:-}" ]; then
    WIZ_REALITY_PORT=$BATCH_REALITY_PORT
    return 0
  fi
  while true; do
    ask v "回源端口" "$def"
    if valid_port "$v"; then
      WIZ_REALITY_PORT=$((10#$v))
      return 0
    fi
    warn "回源端口范围 1-65535"
    def=443
  done
}

tls_cert_json() {
  local domain=$1
  shift
  local alpn='[]'
  ensure_cert "$domain" || return 1
  if [ "$#" -gt 0 ]; then
    alpn=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  fi
  jq -n --arg sni "$domain" --arg crt "$CERT_FILE" --arg key "$KEY_FILE" --argjson alpn "$alpn" \
    '{enabled:true,server_name:$sni,alpn:$alpn,certificate_path:$crt,key_path:$key}'
}

# ================================================================
#  VLESS 系列
# ================================================================

# VLESS + TCP + Vision + REALITY
create_vless_reality() {
  local tag port uuid sni sid rport priv pub kp json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    uuid=$(node_get "$tag" '.users[0].uuid')
    sni=$(node_get "$tag" '.tls.server_name')
    sid=$(node_get "$tag" '.tls.reality.short_id[0]')
    rport=$(node_get "$tag" '.tls.reality.handshake.server_port' 443)
    priv=$(node_get "$tag" '.tls.reality.private_key')
    pub=$(meta_get "$tag" pbk)
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "reality-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    uuid=""
    sni=""
    sid=""
    rport=""
    priv=""
    pub=""
  fi

  [ -n "$uuid" ] || uuid=$(gen_uuid)
  if [ -z "$sid" ] || ! valid_short_id "$sid"; then
    sid=$(gen_hex 4)
  fi
  [ -n "$sid" ] || { error "short_id 生成失败"; return 1; }

  if [ -z "$priv" ] || [ -z "$pub" ]; then
    info "正在生成 REALITY 密钥对 ..."
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
    [ -n "$priv" ] && [ -n "$pub" ] || { error "REALITY 密钥对生成失败"; return 1; }
  fi

  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;        sni=$WIZ_SNI
  WIZ_REALITY_PORT=$rport; ask_reality_port; rport=$WIZ_REALITY_PORT
  WIZ_TAG=$tag

  if [ -n "${WIZ_EDIT_TAG:-}" ] && confirm "是否重新生成 REALITY 密钥对?" "n"; then
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
    [ -n "$priv" ] && [ -n "$pub" ] || { error "REALITY 密钥对生成失败"; return 1; }
  fi

  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" \
    --argjson rport "$rport" '
    {type:"vless",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",uuid:$uuid,flow:"xtls-rprx-vision"}],
     tls:{enabled:true,server_name:$sni,
          reality:{enabled:true,handshake:{server:$sni,server_port:$rport},
                   private_key:$priv,short_id:[$sid]}}}')
  save_node "$tag" "vless-reality-vision" "$json" "$pub" 0
}

# VLESS + WebSocket + TLS
create_vless_ws() {
  local tag port uuid sni path tls transport json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    uuid=$(node_get "$tag" '.users[0].uuid')
    sni=$(node_get "$tag" '.tls.server_name')
    path=$(node_get "$tag" '.transport.path')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-ws-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    uuid=""
    sni=""
    path=""
  fi

  [ -n "$uuid" ] || uuid=$(gen_uuid)
  WIZ_PORT=$port; ask_port tcp;  port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;        sni=$WIZ_SNI
  WIZ_TAG=$tag

  [ -n "$path" ] || path="/$(gen_hex 6)"
  tls=$(tls_cert_json "$sni" h2 http/1.1) || return 1
  transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vless",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vless-ws" "$json" "" 1
}

# ================================================================
#  Hysteria2 / TUIC (QUIC)
# ================================================================

# Hysteria2
create_hysteria2() {
  local tag port password sni tls json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "hysteria2-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    password=""
    sni=""
  fi

  [ -n "$password" ] || password=$(gen_hex 16)
  WIZ_PORT=$port; ask_port udp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  tls=$(tls_cert_json "$sni" h3) || return 1
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  # 自签证书固定 insecure=1，见 ensure_cert 的说明
  save_node "$tag" "hysteria2" "$json" "" 1
}

# TUIC
# 默认 congestion_control=bbr，仅影响服务端发送方向。
# udp_relay_mode 是客户端出站参数，服务端 inbound 没有这个字段。
create_tuic() {
  local tag port uuid password sni tls json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    uuid=$(node_get "$tag" '.users[0].uuid')
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "tuic-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    uuid=""
    password=""
    sni=""
  fi

  [ -n "$uuid" ] || uuid=$(gen_uuid)
  [ -n "$password" ] || password=$(gen_hex 16)
  WIZ_PORT=$port; ask_port udp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  tls=$(tls_cert_json "$sni" h3) || return 1
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" '
    {type:"tuic",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",uuid:$uuid,password:$password}],
     congestion_control:"bbr",tls:$tls}')
  save_node "$tag" "tuic" "$json" "" 1
}

# ================================================================
#  Shadowsocks-2022
# ================================================================
# 固定使用 2022-blake3-aes-256-gcm，密钥必须为 32 字节 Base64

create_ss2022() {
  local tag port password json
  local method="2022-blake3-aes-256-gcm"
  local bytes=32

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 8388)
    password=$(node_get "$tag" '.password')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "ss-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    password=""
  fi

  WIZ_PORT=$port; ask_port both; port=$WIZ_PORT
  WIZ_TAG=$tag

  if ! valid_ss2022_key "$bytes" "$password"; then
    password=$(gen_b64 "$bytes") || { error "Shadowsocks 密钥生成失败"; return 1; }
    valid_ss2022_key "$bytes" "$password" || { error "Shadowsocks 密钥无效"; return 1; }
  fi

  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg method "$method" --arg password "$password" '
    {type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,
     method:$method,password:$password}')
  save_node "$tag" "shadowsocks-2022" "$json" "" 0
}

# ================================================================
#  Trojan / VMess
# ================================================================

# Trojan (TCP) 与 Trojan-WS，由 kind 区分
create_trojan() {
  local kind=$1 tag port password sni path tls transport json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    path=$(node_get "$tag" '.transport.path')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    case "$kind" in
      ws) prompt_tag "trojan-ws-$(gen_hex 2)" || return 1 ;;
      *)  prompt_tag "trojan-$(gen_hex 2)" || return 1 ;;
    esac
    tag=$WIZ_TAG
    port=""
    password=""
    sni=""
    path=""
  fi

  [ -n "$password" ] || password=$(gen_hex 16)
  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  transport=""
  if [ "$kind" = "ws" ]; then
    [ -n "$path" ] || path="/$(gen_hex 6)"
    transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  fi

  tls=$(tls_cert_json "$sni" h2 http/1.1) || return 1
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"trojan",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  if [ -n "$transport" ]; then
    json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  fi
  if [ "$kind" = "ws" ]; then
    save_node "$tag" "trojan-ws" "$json" "" 1
  else
    save_node "$tag" "trojan" "$json" "" 1
  fi
}

# VMess + WebSocket + TLS
create_vmess() {
  local tag port uuid sni path tls transport json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    uuid=$(node_get "$tag" '.users[0].uuid')
    sni=$(node_get "$tag" '.tls.server_name')
    path=$(node_get "$tag" '.transport.path')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vmess-ws-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    uuid=""
    sni=""
    path=""
  fi

  [ -n "$uuid" ] || uuid=$(gen_uuid)
  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  [ -n "$path" ] || path="/$(gen_hex 6)"
  tls=$(tls_cert_json "$sni" h2 http/1.1) || return 1
  transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vmess",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vmess-ws" "$json" "" 1
}

# ================================================================
#  AnyTLS / SOCKS5
# ================================================================

# AnyTLS
create_anytls() {
  local tag port password sni tls json

  if [ -x "$BIN" ] && ! core_supports_anytls; then
    error "AnyTLS 需要 sing-box 1.12 或更高版本，请先更新核心"
    return 1
  fi

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 443)
    password=$(node_get "$tag" '.users[0].password')
    sni=$(node_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "anytls-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    password=""
    sni=""
  fi

  [ -n "$password" ] || password=$(gen_hex 16)
  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_SNI=$sni;   ask_sni;      sni=$WIZ_SNI
  WIZ_TAG=$tag

  tls=$(tls_cert_json "$sni" h2 http/1.1) || return 1
  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"anytls",tag:$tag,listen:"::",listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  save_node "$tag" "anytls" "$json" "" 1
}

# SOCKS5，凭据自动生成，不询问
create_socks5() {
  local tag port username password json

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 1080)
    username=$(node_get "$tag" '.users[0].username' 'user')
    password=$(node_get "$tag" '.users[0].password')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "socks5-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    username="user"
    password=""
  fi

  [ -n "$username" ] || username="user"
  [ -n "$password" ] || password=$(gen_hex 8)
  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_TAG=$tag

  json=$(jq -n --arg tag "$tag" --argjson port "$port" \
    --arg username "$username" --arg password "$password" '
    {type:"socks",tag:$tag,listen:"::",listen_port:$port,
     users:[{username:$username,password:$password}]}')
  save_node "$tag" "socks5" "$json" "" 0
}

# ================================================================
#  Snell v6
# ================================================================
# PSK 自动生成，mode 固定 default

create_snell() {
  local tag port psk json

  if [ -x "$BIN" ] && ! core_supports_snell; then
    error "Snell v6 需要 sing-box 1.14 或更高版本，请先更新核心"
    return 1
  fi

  if [ -n "${WIZ_EDIT_TAG:-}" ]; then
    tag=$WIZ_EDIT_TAG
    port=$(node_get "$tag" '.listen_port' 6160)
    psk=$(node_get "$tag" '.psk')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "snell-$(gen_hex 2)" || return 1
    tag=$WIZ_TAG
    port=""
    psk=""
  fi

  WIZ_PORT=$port; ask_port tcp; port=$WIZ_PORT
  WIZ_TAG=$tag

  if ! valid_psk "$psk"; then
    psk=$(gen_b64 16) || { error "Snell PSK 生成失败"; return 1; }
    valid_psk "$psk" || { error "Snell PSK 无效"; return 1; }
  fi
  json=$(jq -n --arg tag "$tag" --argjson port "$port" --arg psk "$psk" '
    {type:"snell",tag:$tag,listen:"::",listen_port:$port,
     version:6,psk:$psk}')
  save_node "$tag" "snell-v6" "$json" "" 0
}

# ================================================================
#  节点详情 / 分享链接
# ================================================================

uri_host() {
  case "${1:-}" in
    *:*) printf '[%s]' "$1" ;;
    *)   printf '%s' "${1:-}" ;;
  esac
}

# 输出单个节点的分享链接
print_node_link() {
  local tag=$1
  local ip_override=${2:-}
  local name="$tag${3:-}"
  local proto ip host port f obj
  local domain uuid pass method path pbk sid insecure psk
  local link userinfo payload tlsq

  proto=$(meta_get "$tag" proto)
  if ! proto_known "$proto"; then
    warn "节点 [$tag] 的协议 [${proto:-空}] 无法识别，请删除后重建"
    return 1
  fi

  f="$NODE_DIR/$tag.json"
  if [ ! -s "$f" ]; then
    error "节点文件不存在: $f"
    return 1
  fi

  if [ -n "$ip_override" ]; then
    ip=$ip_override
  else
    load_server_host
    if [ -n "${SERVER_HOST:-}" ]; then
      ip=$SERVER_HOST
    else
      load_server_ip
      ip=${SERVER_IP:-}
    fi
  fi
  [ -n "$ip" ] || warn "未能获取公网 IP，请手动替换链接中的服务器地址"
  host=$(uri_host "$ip")
  insecure=$(meta_get "$tag" insecure)

  if ! obj=$(jq -c . "$f" 2>/dev/null); then
    error "节点配置不是合法 JSON: $f"
    return 1
  fi
  port=$(jq -r '.listen_port // empty' <<<"$obj")
  if [ -z "$port" ]; then
    error "节点配置缺少监听端口: $f"
    return 1
  fi

  case "$proto" in
    vless-reality-vision)
      uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      sid=$(jq -r '.tls.reality.short_id[0] // empty' <<<"$obj")
      pbk=$(meta_get "$tag" pbk)
      if [ -z "$uuid" ] || [ -z "$domain" ] || [ -z "$pbk" ]; then
        error "节点 [$tag] 缺少 UUID / SNI域名 / 公钥，无法生成链接"
        return 1
      fi
      link="vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlenc "$domain")&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#$(urlenc "$name")"
      ;;

    vless-ws)
      uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      path=$(jq -r '.transport.path // empty' <<<"$obj")
      tlsq=$(tls_query "$domain" "$insecure")
      link="vless://${uuid}@${host}:${port}?encryption=none&${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#$(urlenc "$name")"
      ;;

    vmess-ws)
      uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      path=$(jq -r '.transport.path // empty' <<<"$obj")
      payload=$(jq -cn --arg ps "$name" --arg add "$ip" --argjson port "$port" \
        --arg id "$uuid" --arg host "$domain" --arg path "$path" --arg sni "$domain" \
        --argjson insecure "$([ "$insecure" = "1" ] && printf true || printf false)" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,scy:"auto",
         net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni}
        + (if $insecure then {allowInsecure:true} else {} end)')
      link="vmess://$(printf '%s' "$payload" | base64 | tr -d '[:space:]')"
      ;;

    trojan)
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      tlsq=$(tls_query "$domain" "$insecure")
      link="trojan://$(urlenc "$pass")@${host}:${port}?${tlsq}&type=tcp#$(urlenc "$name")"
      ;;

    trojan-ws)
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      path=$(jq -r '.transport.path // empty' <<<"$obj")
      tlsq=$(tls_query "$domain" "$insecure")
      link="trojan://$(urlenc "$pass")@${host}:${port}?${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#$(urlenc "$name")"
      ;;

    shadowsocks-2022)
      method=$(jq -r '.method // empty' <<<"$obj")
      pass=$(jq -r '.password // empty' <<<"$obj")
      userinfo=$(b64url "$method:$pass")
      link="ss://${userinfo}@${host}:${port}#$(urlenc "$name")"
      ;;

    hysteria2)
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      link="hysteria2://$(urlenc "$pass")@${host}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#$(urlenc "$name")"
      ;;

    tuic)
      uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      link="tuic://${uuid}:$(urlenc "$pass")@${host}:${port}?alpn=h3&sni=$(urlenc "$domain")&congestion_control=bbr&udp_relay_mode=native"
      [ "$insecure" = "1" ] && link="$link&allow_insecure=1"
      link="$link#$(urlenc "$name")"
      ;;

    anytls)
      pass=$(jq -r '.users[0].password // empty' <<<"$obj")
      domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
      link="anytls://$(urlenc "$pass")@${host}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#$(urlenc "$name")"
      ;;

    socks5)
      userinfo=$(b64url "$(jq -r '.users[0].username // empty' <<<"$obj"):$(jq -r '.users[0].password // empty' <<<"$obj")")
      link="socks://${userinfo}@${host}:${port}#$(urlenc "$name")"
      ;;

    snell-v6)
      # Sub-Store 不支持 snell:// 输入，直接输出 Surge 格式
      psk=$(jq -r '.psk // empty' <<<"$obj")
      printf '%s = snell, %s, %s, psk=%s, version=6, mode=default, reuse=false\n' \
        "$name" "$ip" "$port" "$psk"
      return 0
      ;;

    *)
      warn "该协议暂不生成分享链接"
      return 0
      ;;
  esac

  printf '%s\n' "$link"
}

# 按环境输出一套或两套链接；设置了分享域名时只输出一条域名链接
print_node_links() {
  local tag=$1
  local ip4 ip6
  load_server_host
  if [ -n "${SERVER_HOST:-}" ]; then
    print_node_link "$tag" "$SERVER_HOST"
    return 0
  fi
  load_server_ip4
  ip4=${SERVER_IP4:-}
  ip6=''
  if [ "$NODE_LISTEN" = "::" ]; then
    load_server_ip6
    ip6=${SERVER_IP6:-}
  fi
  if [ -n "$ip4" ] && [ -n "$ip6" ]; then
    printf '# IPv4\n'
    print_node_link "$tag" "$ip4" "-v4"
    printf '# IPv6\n'
    print_node_link "$tag" "$ip6" "-v6"
    return 0
  fi
  if [ -n "$ip4" ]; then
    print_node_link "$tag" "$ip4"
    return 0
  fi
  if [ -n "$ip6" ]; then
    print_node_link "$tag" "$ip6"
    return 0
  fi
  print_node_link "$tag"
}

tls_query() {
  local domain=$1 insecure=$2
  local q="security=tls&sni=$(urlenc "$domain")"
  [ "$insecure" = "1" ] && q="$q&allowInsecure=1"
  printf '%s' "$q"
}

print_created_links() {
  local tag i=0
  [ ${#CREATED_TAGS[@]} -gt 0 ] || return 0
  printf '\n%s\n' "================ 新节点分享链接 ================"
  for tag in "${CREATED_TAGS[@]}"; do
    [ -f "$NODE_DIR/$tag.json" ] || continue
    i=$((i + 1))
    printf '\n[%s] %s  (%s)\n' "$i" "$tag" "$(proto_display "$(meta_get "$tag" proto)")"
    printf '%s\n' "--------------------------------------------------"
    print_node_links "$tag"
  done
  [ "$i" -gt 0 ] && printf '\n共 %s 个新节点\n' "$i"
  return 0
}

show_node_details() {
  local tag=$1
  printf '%s\n' "=============================================="
  printf '节点名称 : %s\n' "$tag"
  printf '协议类型 : %s\n' "$(proto_display "$(meta_get "$tag" proto)")"
  printf '配置路径 : %s\n' "$NODE_DIR/$tag.json"
  printf '%s\n' "=============================================="
  jq 'del(._meta)' "$NODE_DIR/$tag.json"
  printf '\n%s\n' "---------- 分享链接 / 客户端配置 ----------"
  print_node_links "$tag"
}

view_nodes() {
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点，请先新增节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  show_node_details "$SELECTED"
  pause
}

show_all_links() {
  local -a tags=()
  mapfile -t tags < <(collect_node_tags)
  if [ ${#tags[@]} -eq 0 ]; then
    warn "暂无节点，请先新增节点"
    pause
    return 0
  fi
  printf '%s\n' "================ 所有节点分享链接 ================"
  local i tag
  for ((i = 0; i < ${#tags[@]}; i++)); do
    tag=${tags[$i]}
    printf '\n[%s] %s  (%s)\n' "$((i + 1))" "$tag" "$(proto_display "$(meta_get "$tag" proto)")"
    printf '%s\n' "--------------------------------------------------"
    print_node_links "$tag"
  done
  printf '\n共 %s 个节点\n' "${#tags[@]}"
  pause
}

delete_node() {
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  local tag=$SELECTED
  warn "即将删除节点 [$tag]，此操作不可恢复"
  if ! confirm "确定删除该节点?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  rm -f "$NODE_DIR/$tag.json" "$ROUTE_DIR/$tag.outbound"
  info "节点 [$tag] 已删除"
  apply_changes
  pause
}

# ---------------- 分享域名 / DDNS ----------------
set_server_host() {
  local cur host
  load_server_host
  cur=${SERVER_HOST:-}
  ask host "分享域名" "$cur"
  host=$(printf '%s' "$host" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  if [ -z "$host" ]; then
    info "未输入域名，已取消"
    return 0
  fi
  if ! valid_sni "$host"; then
    error "域名格式无效，只能包含字母、数字、点、下划线和短横线"
    return 1
  fi
  mkdir -p "$SB_DIR"
  if ! printf '%s\n' "$host" > "$SERVER_HOST_FILE"; then
    error "写入分享域名失败"
    return 1
  fi
  chmod 600 "$SERVER_HOST_FILE" 2>/dev/null || true
  SERVER_HOST=$host
  info "分享域名已设置为: $host"
  warn "请重新查看/复制分享链接；旧链接不会自动改写"
  return 0
}

clear_server_host() {
  if ! confirm "清除分享域名，恢复使用公网 IP?" "n"; then
    info "已取消"
    return 0
  fi
  rm -f "$SERVER_HOST_FILE"
  SERVER_HOST=""
  info "分享域名已清除，分享链接将使用公网 IP"
  warn "请重新查看/复制分享链接；旧链接不会自动改写"
  return 0
}

menu_domain() {
  local c
  while true; do
    load_server_host
    printf '\n%s\n' "------------- 解析域名 -------------"
    if [ -n "${SERVER_HOST:-}" ]; then
      printf '当前分享域名: %s\n' "$SERVER_HOST"
    else
      printf '当前分享域名: 未设置（使用公网 IP）\n'
    fi
    printf '%s\n' "作用:"
    printf '  用于动态 IP / DDNS 环境。设置后分享链接使用该域名，不再写公网 IP。\n'
    printf '  IP 变化时只需 DDNS 更新解析，客户端重新解析即可。\n'
    printf '  双栈环境只输出一条域名链接。\n'
    printf ' 1) 设置 / 修改域名\n'
    printf ' 2) 清除域名（恢复使用公网 IP）\n'
    printf ' 0) 返回\n'
    ask c "请选择" ""
    case "$c" in
      1) set_server_host; pause ;;
      2) clear_server_host; pause ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ================================================================
#  节点管理菜单
# ================================================================

# 按协议 ID 分派创建函数
create_node_by_id() {
  local id=$1
  case "$id" in
    vless-reality-vision) create_vless_reality ;;
    vless-ws)             create_vless_ws ;;
    hysteria2)            create_hysteria2 ;;
    tuic)                 create_tuic ;;
    trojan)               create_trojan tcp ;;
    trojan-ws)            create_trojan ws ;;
    anytls)               create_anytls ;;
    shadowsocks-2022)     create_ss2022 ;;
    vmess-ws)             create_vmess ;;
    snell-v6)             create_snell ;;
    socks5)               create_socks5 ;;
    *)
      error "未知协议: $id"
      return 1
      ;;
  esac
}

# 解析协议编号输入，支持空格/逗号分隔的批量
# 结果写入 PROTOCOL_PICKS, 无效项写入 PROTOCOL_INVALID
# 返回 0=有有效项 1=取消 2=无有效项
parse_protocol_choices() {
  PROTOCOL_PICKS=()
  PROTOCOL_INVALID=""
  local raw token i dup add=0 n
  local -a tokens=()
  n=$(proto_count)

  raw=$(printf '%s' "${1:-}" | tr ',' ' ' | tr '\n\t' '  ')
  raw=${raw//，/ }
  raw=${raw//、/ }
  read -r -a tokens <<<"$raw"
  [ ${#tokens[@]} -eq 0 ] && return 2

  for token in "${tokens[@]}"; do
    [ "$token" = "0" ] && return 1
    if ! [[ $token =~ ^[0-9]{1,3}$ ]]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    token=$((10#$token))
    if [ "$token" -lt 1 ] || [ "$token" -gt "$n" ]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    dup=0
    for i in "${PROTOCOL_PICKS[@]:-}"; do
      [ "$i" = "$token" ] && dup=1
    done
    if [ "$dup" -eq 0 ]; then
      PROTOCOL_PICKS+=("$token")
      add=1
    fi
  done
  [ "$add" -eq 1 ] && return 0
  return 2
}

# ---------------- 单节点创建 ----------------
create_single_node() {
  local idx=$1 id name loc
  id=$(proto_id_by_index "$idx") || return 1
  name=$(proto_name_by_index "$idx")

  info "正在获取服务器国家码 ..."
  loc=$(get_server_country_code)
  info "服务器国家码: $loc"

  reset_wizard
  WIZ_TAG=$(make_node_tag "$loc" "$name")
  create_node_by_id "$id"
}

# ---------------- 批量创建 ----------------
batch_create_nodes() {
  local -a picks=("$@")
  local idx id name transport port v loc ok=0 fail=0
  local need_sni=0 need_reality_port=0

  reset_wizard
  reset_batch
  CREATED_TAGS=()

  printf '%s\n' "------------- 批量新增节点 -------------"
  info "共选择 ${#picks[@]} 个协议"

  info "正在获取服务器国家码 ..."
  loc=$(get_server_country_code)
  info "服务器国家码: $loc"
  ask loc "节点名称前缀（两位国家码）" "$loc"
  loc=$(normalize_country_code "$loc")

  # 汇总需要的共享参数
  for idx in "${picks[@]}"; do
    id=$(proto_id_by_index "$idx")
    proto_needs_sni "$id" && need_sni=1
    proto_needs_reality_port "$id" && need_reality_port=1
  done

  BATCH_SNI=""
  if [ "$need_sni" -eq 1 ]; then
    info "所选节点共用同一 SNI域名"
    while true; do
      ask BATCH_SNI "SNI域名" ""
      valid_sni "$BATCH_SNI" && break
      warn "SNI域名不能为空，且只能包含字母、数字、点、下划线和短横线"
      BATCH_SNI=""
    done
  fi

  BATCH_REALITY_PORT=""
  if [ "$need_reality_port" -eq 1 ]; then
    while true; do
      ask BATCH_REALITY_PORT "回源端口" "443"
      valid_port "$BATCH_REALITY_PORT" && { BATCH_REALITY_PORT=$((10#$BATCH_REALITY_PORT)); break; }
      warn "回源端口范围 1-65535"
      BATCH_REALITY_PORT=""
    done
  fi

  # 逐个询问监听端口，避免批次内冲突
  info "请依次设置各协议的监听端口，直接回车使用随机端口"
  idx=0
  for id in "${picks[@]}"; do
    idx=$((idx + 1))
    name=$(proto_name_by_index "$id")
    transport=$(proto_transport "$(proto_id_by_index "$id")")
    while true; do
      ask v "[$idx/${#picks[@]}] $name 监听端口（回车随机）" ""
      if [ -z "$v" ]; then
        v=$(random_free_port "$transport")
        printf '\n'
        info "  -> $name 使用随机监听端口: $v/$(transport_label "$transport")"
        break
      fi
      if ! valid_port "$v"; then
        warn "监听端口范围 1-65535"
        continue
      fi
      v=$((10#$v))
      if system_port_in_use "$v" "$transport"; then
        warn "监听端口 $v 已被系统服务占用，请更换"
        continue
      fi
      if node_port_in_use "$v" "$transport"; then
        warn "监听端口 $v 已被其他节点占用，请更换"
        continue
      fi
      if batch_port_in_use "$v" "$transport"; then
        warn "监听端口 $v 已在本批次中使用，请更换"
        continue
      fi
      break
    done
    BATCH_PORT_LIST+=("$v")
    BATCH_PORT_TYPES+=("$transport")
  done

  info "UUID、密码、PSK 和路径将自动生成"
  BATCH_MODE=1
  idx=0
  for id in "${picks[@]}"; do
    name=$(proto_name_by_index "$id")
    id=$(proto_id_by_index "$id")
    BATCH_TAG=$(make_node_tag "$loc" "$name")
    BATCH_PORT=${BATCH_PORT_LIST[$idx]}
    printf '>>> 创建节点: %s (监听端口 %s/%s)\n' \
      "$BATCH_TAG" "$BATCH_PORT" "$(transport_label "${BATCH_PORT_TYPES[$idx]}")"
    if create_node_by_id "$id"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      warn "协议 [$name] 创建失败"
    fi
    idx=$((idx + 1))
  done

  reset_batch
  reset_wizard

  if [ "$ok" -gt 0 ]; then
    info "批量创建完成: 成功 $ok 个，失败 $fail 个"
    apply_changes || error "配置校验失败，请检查刚创建的节点"
  else
    error "没有节点创建成功"
  fi
}

# ---------------- 菜单 ----------------
menu_add_node() {
  local c rc
  CREATED_TAGS=()
  printf '%s\n' "------------- 新增节点 -------------"
  print_protocol_menu
  printf '%s\n' "(批量添加请用空格或逗号分隔，例如 1 3 10)"
  ask c "请选择协议" ""
  parse_protocol_choices "$c"
  rc=$?

  if [ "$rc" -eq 1 ]; then
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    if [ -n "$PROTOCOL_INVALID" ]; then
      warn "无效协议编号:${PROTOCOL_INVALID}"
    else
      warn "未选择有效协议"
    fi
    pause
    return 0
  fi
  [ -n "$PROTOCOL_INVALID" ] && warn "已忽略无效编号:${PROTOCOL_INVALID}"

  if [ ${#PROTOCOL_PICKS[@]} -eq 1 ]; then
    create_single_node "${PROTOCOL_PICKS[0]}" || warn "节点创建未完成，请检查上方错误"
    print_created_links
    apply_changes
  else
    batch_create_nodes "${PROTOCOL_PICKS[@]}"
    print_created_links
  fi

  CREATED_TAGS=()
  pause
}

edit_node() {
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  local tag=$SELECTED id
  id=$(meta_get "$tag" proto)
  if ! proto_known "$id"; then
    warn "节点 [$tag] 的协议 [${id:-空}] 无法识别，请删除后重建"
    pause
    return 0
  fi
  warn "编辑会覆盖节点 [$tag] 的现有配置"
  if ! confirm "继续编辑?" "n"; then
    info "已取消"
    pause
    return 0
  fi

  reset_wizard
  reset_batch
  WIZ_EDIT_TAG=$tag
  create_node_by_id "$id"
  WIZ_EDIT_TAG=""
  reset_wizard
  apply_changes
  pause
}

menu_nodes() {
  local c
  while true; do
    printf '\n%s\n' "------------- 节点管理 -------------"
    printf ' 1) 新增节点\n'
    printf ' 2) 查看节点 / 分享链接\n'
    printf ' 3) 编辑节点\n'
    printf ' 4) 删除节点\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) menu_add_node ;;
      2) view_nodes ;;
      3) edit_node ;;
      4) delete_node ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ================================================================
#  出站公共逻辑
# ================================================================

outbound_type_display() {
  case "${1:-}" in
    direct)      printf '直连' ;;
    socks)       printf 'SOCKS5' ;;
    http)        printf 'HTTP' ;;
    shadowsocks) printf 'Shadowsocks' ;;
    vmess)       printf 'VMess' ;;
    vless)       printf 'VLESS' ;;
    trojan)      printf 'Trojan' ;;
    hysteria2)   printf 'Hysteria2' ;;
    tuic)        printf 'TUIC' ;;
    snell)       printf 'Snell' ;;
    anytls)      printf 'AnyTLS' ;;
    *)           printf '%s' "${1:-未知}" ;;
  esac
}

valid_tag() {
  [[ ${1:-} =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]
}

prompt_out_tag() {
  local def=$1 v
  while true; do
    ask v "出站名称" "$def"
    if ! valid_tag "$v"; then
      warn "仅支持字母、数字、点、下划线、短横线，且不能以点开头"
      continue
    fi
    if [ "$v" = "direct" ]; then
      warn "direct 是保留名称"
      continue
    fi
    if node_tag_in_use "$v"; then
      warn "名称 [$v] 已被节点或出站占用"
      continue
    fi
    SELECTED_OUT=$v
    return 0
  done
}

prompt_server() {
  local def=${1:-} s
  while true; do
    ask s "服务器地址" "$def"
    [ -n "$s" ] || { warn "服务器地址不能为空"; continue; }
    SERVER_VAL=$s
    return 0
  done
}

ask_rport() {
  local def=${1:-443} v
  while true; do
    ask v "服务器端口" "$def"
    if valid_port "$v"; then
      RPORT=$((10#$v))
      return 0
    fi
    warn "服务器端口范围 1-65535"
  done
}

# 出站 TLS: insecure 固定开启(对端多为自签证书)，REALITY 时附带 public_key
client_tls_json() {
  local sni=$1 pub=${2:-} sid=${3:-} tls
  tls=$(jq -n --arg sni "$sni" '
    {enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},insecure:true}')
  if [ -n "$pub" ]; then
    tls=$(jq --arg pub "$pub" --arg sid "$sid" \
      '. + {reality:{enabled:true,public_key:$pub,short_id:$sid}}' <<<"$tls")
  fi
  printf '%s' "$tls"
}

save_outbound() {
  local tag=$1
  local json=$2
  local tmp
  local smethod spass
  valid_tag "$tag" || { error "出站名称非法: $tag"; return 1; }
  [ "$tag" = "direct" ] && { error "direct 是保留名称"; return 1; }

  # Shadowsocks-2022 的 password 必须是 16/32 字节 Base64 密钥
  smethod=$(jq -r '.method // empty' <<<"$json" 2>/dev/null || true)
  if [ -n "$smethod" ]; then
    spass=$(jq -r '.password // empty' <<<"$json" 2>/dev/null || true)
    if [ -n "$spass" ]; then
      case "$smethod" in
        2022-blake3-aes-128-gcm)
          spass=$(b64norm "$spass") || {
            error "Shadowsocks-2022 密钥必须是 16 字节 Base64"
            return 1
          }
          valid_ss2022_key 16 "$spass" || {
            error "Shadowsocks-2022 密钥必须是 16 字节 Base64"
            return 1
          }
          ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
          spass=$(b64norm "$spass") || {
            error "Shadowsocks-2022 密钥必须是 32 字节 Base64"
            return 1
          }
          valid_ss2022_key 32 "$spass" || {
            error "Shadowsocks-2022 密钥必须是 32 字节 Base64"
            return 1
          }
          ;;
      esac
      json=$(jq --arg p "$spass" '.password = $p' <<<"$json") || {
        error "出站配置写入失败"
        return 1
      }
    fi
  fi

  mkdir -p "$OUT_DIR" 2>/dev/null || true
  tmp=$(mktemp "$OUT_DIR/.out.XXXXXX") || { error "创建临时文件失败"; return 1; }
  if ! printf '%s\n' "$json" | jq . > "$tmp"; then
    rm -f "$tmp"
    error "出站配置写入失败"
    return 1
  fi
  chmod 600 "$tmp"
  if ! mv -f "$tmp" "$OUT_DIR/$tag.json"; then
    rm -f "$tmp"
    error "出站配置写入失败"
    return 1
  fi
  info "出站 [$tag] 已保存"
  return 0
}

# ================================================================
#  分享链接解析 -> 出站配置
#  支持 vless / vmess / trojan / hysteria2 / tuic / ss / anytls
#  Snell 与 SOCKS5 无标准链接，走手动填写
# ================================================================

PARSED_HOST=""
PARSED_PORT=""

# 从查询串取参数
query_get() {
  local qs=${1:-} key=$2 def=${3:-} pair k v
  [ -n "$qs" ] || { printf '%s' "$def"; return 0; }
  local IFS='&'
  for pair in $qs; do
    k=${pair%%=*}
    case "$k" in "$key") ;; *) continue ;; esac
    v=${pair#*=}
    [ "$v" = "$pair" ] && v=""
    printf '%s' "$(urldec "$v")"
    return 0
  done
  printf '%s' "$def"
}

# 从链接的 #fragment 取名称
link_fragment() {
  local u=${1:-}
  case "$u" in
    *'#'*) urldec "${u#*#}" ;;
    *)     printf '' ;;
  esac
}

# 去掉 fragment
link_no_fragment() {
  local u=${1:-}
  printf '%s' "${u%%#*}"
}

# 解析 host:port / [ipv6]:port / host（使用默认端口）
# 结果写入 PARSED_HOST / PARSED_PORT；失败返回 1
parse_host_port() {
  local hp=${1:-} def=${2:-}
  PARSED_HOST=""
  PARSED_PORT=""
  [ -n "$hp" ] || return 1
  hp=${hp%%/*}
  if [[ $hp == \[*\]:* ]]; then
    PARSED_HOST=${hp#\[}
    PARSED_HOST=${PARSED_HOST%%\]*}
    PARSED_PORT=${hp##*\]:}
  elif [[ $hp == \[*\] ]]; then
    PARSED_HOST=${hp#\[}
    PARSED_HOST=${PARSED_HOST%\]}
    PARSED_PORT=$def
  elif [[ $hp == *:*:* ]]; then
    # 未加方括号的 IPv6 无法可靠拆分端口
    return 1
  elif [[ $hp == *:* ]]; then
    PARSED_HOST=${hp%:*}
    PARSED_PORT=${hp##*:}
  else
    PARSED_HOST=$hp
    PARSED_PORT=$def
  fi
  [ -n "$PARSED_HOST" ] || return 1
  if [ -n "$PARSED_PORT" ]; then
    valid_port "$PARSED_PORT" || return 1
    PARSED_PORT=$((10#$PARSED_PORT))
  fi
  return 0
}

# 解析单个分享链接，成功时设置 OUT_JSON
# 失败时返回非零并输出原因到 OUT_ERROR
parse_share_link() {
  local url=${1:-} scheme rest body
  OUT_JSON=""
  OUT_ERROR=""
  OUT_SUGGEST_TAG=""

  url=${url#"${url%%[![:space:]]*}"}
  url=${url%"${url##*[![:space:]]}"}
  [ -n "$url" ] || { OUT_ERROR="链接为空"; return 1; }

  scheme=${url%%://*}
  if [ "$scheme" = "$url" ]; then
    OUT_ERROR="无法识别的链接格式，缺少 :// 前缀"
    return 1
  fi
  scheme=${scheme,,}
  rest=${url#*://}
  OUT_SUGGEST_TAG=$(link_fragment "$rest")
  body=$(link_no_fragment "$rest")

  case "$scheme" in
    vless|trojan|hysteria2|tuic|anytls|ss|vmess) ;;
    *)
      OUT_ERROR="暂不支持的链接协议: $scheme"
      return 1
      ;;
  esac

  case "$scheme" in
    vmess) parse_link_vmess "$body" ;;
    ss)    parse_link_ss "$body" ;;
    *)     parse_link_standard "$scheme" "$body" ;;
  esac
}

# userinfo@host:port?query
parse_link_standard() {
  local scheme=$1 body=$2
  local userinfo hostport query host port user
  local sni pbk sid path hosthdr security flow cc type ws_host
  local tls='' transport='' default_port=''

  case "$body" in
    *'?'*) userinfo=${body%%\?*}; query=${body#*\?} ;;
    *)     userinfo=$body; query="" ;;
  esac

  hostport=${userinfo##*@}
  if [ "$hostport" = "$userinfo" ]; then
    OUT_ERROR="链接缺少 用户信息@地址 结构"
    return 1
  fi
  userinfo=${userinfo%@*}
  user=$(urldec_raw "$userinfo")

  [ "$scheme" = "anytls" ] && default_port=443
  if ! parse_host_port "$hostport" "$default_port"; then
    OUT_ERROR="链接中的服务器地址或端口无效: $hostport"
    return 1
  fi
  host=$PARSED_HOST
  port=$PARSED_PORT
  if [ -z "$port" ]; then
    OUT_ERROR="链接缺少服务器端口: $hostport"
    return 1
  fi

  sni=$(query_get "$query" sni)
  pbk=$(query_get "$query" pbk)
  sid=$(query_get "$query" sid)
  path=$(query_get "$query" path)
  hosthdr=$(query_get "$query" host)
  security=$(query_get "$query" security)
  flow=$(query_get "$query" flow)
  cc=$(query_get "$query" congestion_control)
  type=$(query_get "$query" type)
  security=${security,,}
  type=${type,,}

  case "$scheme" in
    vless)
      valid_uuid "$user" || { OUT_ERROR="VLESS 链接中的 UUID 无效: $user"; return 1; }

      # REALITY: security=reality 或带 pbk；TLS: security=tls；
      # security 为空/none 时保持明文，绝不因为存在 host/sni 就猜测 TLS。
      if [ "$security" = "reality" ] || { [ -n "$pbk" ] && [ "$security" != "tls" ]; }; then
        [ -n "$sni" ] || sni=$hosthdr
        [ -n "$sni" ] || { OUT_ERROR="REALITY 链接缺少 sni 参数"; return 1; }
        [ -n "$pbk" ] || { OUT_ERROR="REALITY 链接缺少 pbk 参数"; return 1; }
        tls=$(client_tls_json "$sni" "$pbk" "$sid")
        [ -n "$flow" ] || flow="xtls-rprx-vision"
      elif [ "$security" = "tls" ]; then
        [ -n "$sni" ] || sni=$hosthdr
        [ -n "$sni" ] || { OUT_ERROR="TLS 链接缺少 sni 参数"; return 1; }
        tls=$(client_tls_json "$sni")
      elif [ -z "$security" ] || [ "$security" = "none" ]; then
        tls=""
      else
        OUT_ERROR="不支持的 security: $security"
        return 1
      fi

      ws_host=${hosthdr:-$sni}
      case "$type" in
        ''|tcp) ;;
        ws)
          [ -n "$ws_host" ] || ws_host=$host
          transport=$(jq -n --arg p "${path:-/}" --arg h "$ws_host" \
            '{type:"ws",path:$p} + (if $h == "" then {} else {headers:{Host:$h}} end)')
          ;;
        *)
          OUT_ERROR="暂不支持的传输类型: $type"
          return 1
          ;;
      esac

      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg uuid "$user" --arg flow "$flow" \
        '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid}
         + (if $flow == "" then {} else {flow:$flow} end)')
      ;;

    trojan)
      [ -n "$user" ] || { OUT_ERROR="Trojan 链接缺少密码"; return 1; }
      [ -n "$sni" ] || sni=$hosthdr
      [ -n "$sni" ] || { OUT_ERROR="Trojan 链接缺少 sni 参数"; return 1; }
      tls=$(client_tls_json "$sni")

      ws_host=${hosthdr:-$sni}
      case "$type" in
        ''|tcp) ;;
        ws)
          [ -n "$ws_host" ] || ws_host=$host
          transport=$(jq -n --arg p "${path:-/}" --arg h "$ws_host" \
            '{type:"ws",path:$p} + (if $h == "" then {} else {headers:{Host:$h}} end)')
          ;;
        *)
          OUT_ERROR="暂不支持的传输类型: $type"
          return 1
          ;;
      esac

      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg password "$user" \
        '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password}')
      ;;

    hysteria2)
      [ -n "$user" ] || { OUT_ERROR="Hysteria2 链接缺少密码"; return 1; }
      [ -n "$(query_get "$query" obfs)" ] && { OUT_ERROR="暂不支持带 obfs 的 Hysteria2 链接"; return 1; }
      [ -n "$sni" ] || sni=$hosthdr
      [ -n "$sni" ] || { OUT_ERROR="Hysteria2 链接缺少 sni 参数"; return 1; }
      tls=$(jq -n --arg sni "$sni" \
        '{enabled:true,server_name:$sni,alpn:["h3"],insecure:true}')
      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg password "$user" \
        '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password}')
      ;;

    tuic)
      local tuser tpass urm
      tuser=${user%%:*}
      if [ "$tuser" = "$user" ]; then tpass=""; else tpass=${user#*:}; fi
      valid_uuid "$tuser" || { OUT_ERROR="TUIC 链接中的 UUID 无效: $tuser"; return 1; }
      [ -n "$sni" ] || sni=$hosthdr
      [ -n "$sni" ] || { OUT_ERROR="TUIC 链接缺少 sni 参数"; return 1; }

      cc=${cc,,}
      cc=${cc:-bbr}
      case "$cc" in
        cubic|new_reno|bbr) ;;
        *) OUT_ERROR="不支持的 TUIC congestion_control: $cc"; return 1 ;;
      esac

      urm=$(query_get "$query" udp_relay_mode)
      urm=${urm,,}
      case "$urm" in
        ''|native|quic) ;;
        *) OUT_ERROR="不支持的 TUIC udp_relay_mode: $urm"; return 1 ;;
      esac
      [ -n "$urm" ] || urm="native"

      tls=$(jq -n --arg sni "$sni" \
        '{enabled:true,server_name:$sni,alpn:["h3"],insecure:true}')
      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg uuid "$tuser" --arg password "$tpass" --arg cc "$cc" --arg urm "$urm" \
        '{type:"tuic",tag:$tag,server:$server,server_port:$port,
          uuid:$uuid,password:$password,
          congestion_control:$cc,udp_relay_mode:$urm}')
      ;;

    anytls)
      [ -n "$user" ] || { OUT_ERROR="AnyTLS 链接缺少密码"; return 1; }
      [ -n "$sni" ] || sni=$hosthdr
      [ -n "$sni" ] || sni=$host
      tls=$(client_tls_json "$sni")
      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg password "$user" \
        '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password}')
      ;;
  esac

  [ -n "$OUT_JSON" ] || { OUT_ERROR="链接解析失败"; return 1; }
  [ -n "$tls" ] && OUT_JSON=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$OUT_JSON")
  [ -n "$transport" ] && OUT_JSON=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$OUT_JSON")
  return 0
}

# vmess://base64(json)
_vmess_decode() {
  local body=$1 clean cand out
  clean=$(printf '%s' "$body" | tr -d '\r\n\t')
  for cand in "$clean" "${clean// /+}"; do
    out=$(b64decode "$cand" || true)
    [ -n "$out" ] || continue
    if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$out"
      return 0
    fi
  done
  return 1
}

parse_link_vmess() {
  local body=$1 raw json
  raw=$(_vmess_decode "$body") || {
    OUT_ERROR="VMess 链接内容不是合法的 Base64 JSON"
    return 1
  }
  json=$raw

  local add port uuid host path net ttls sni
  add=$(jq -r '.add // empty' <<<"$json")
  port=$(jq -r '.port // empty' <<<"$json")
  uuid=$(jq -r '.id // empty' <<<"$json")
  host=$(jq -r '.host // empty' <<<"$json")
  path=$(jq -r '.path // "/"' <<<"$json")
  net=$(jq -r '.net // "tcp"' <<<"$json")
  ttls=$(jq -r '.tls // ""' <<<"$json")
  sni=$(jq -r '.sni // empty' <<<"$json")

  # 部分客户端会给 IPv6 地址加方括号
  if [[ $add == \[*\] ]]; then
    add=${add#\[}
    add=${add%\]}
  fi

  if [ -z "$add" ] || ! valid_port "$port"; then
    OUT_ERROR="VMess 链接缺少有效的服务器地址或端口"
    return 1
  fi
  if ! valid_uuid "$uuid"; then
    OUT_ERROR="VMess 链接中的 UUID 无效: $uuid"
    return 1
  fi

  net=${net,,}
  ttls=${ttls,,}
  [ -n "$sni" ] || sni=$host

  local tls="" transport=""
  case "$ttls" in
    ''|none) ;;
    tls)
      [ -n "$sni" ] || { OUT_ERROR="VMess TLS 链接缺少 sni/host 参数"; return 1; }
      tls=$(client_tls_json "$sni")
      ;;
    *)
      OUT_ERROR="暂不支持的 VMess TLS 类型: $ttls"
      return 1
      ;;
  esac

  case "$net" in
    ''|tcp) ;;
    ws)
      transport=$(jq -n --arg p "$path" --arg h "$host" \
        '{type:"ws",path:$p} + (if $h == "" then {} else {headers:{Host:$h}} end)')
      ;;
    *)
      OUT_ERROR="暂不支持的 VMess 传输类型: $net"
      return 1
      ;;
  esac

  OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$add" --argjson port "$((10#$port))" \
    --arg uuid "$uuid" \
    '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:"auto"}')
  [ -n "$tls" ] && OUT_JSON=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$OUT_JSON")
  [ -n "$transport" ] && OUT_JSON=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$OUT_JSON")
  return 0
}

# ss://base64(method:password)@host:port 或 ss://base64(整套) 或 SIP002
parse_link_ss() {
  local body=$1 userinfo hostport decoded method pass query plugin

  case "$body" in
    *'?'*) query=${body#*\?}; body=${body%%\?*} ;;
    *)     query="" ;;
  esac
  plugin=$(query_get "$query" plugin)
  [ -z "$plugin" ] || { OUT_ERROR="暂不支持带 plugin 的 Shadowsocks 链接"; return 1; }

  userinfo=${body%%@*}
  hostport=${body##*@}
  if [ "$hostport" = "$body" ]; then
    OUT_ERROR="Shadowsocks 链接缺少 地址:端口"
    return 1
  fi

  decoded=$(b64decode "$userinfo" || true)
  if [ -n "$decoded" ] && [[ $decoded == *:* ]]; then
    method=${decoded%%:*}
    pass=${decoded#*:}
  else
    method=${userinfo%%:*}
    pass=${userinfo#*:}
    [ "$pass" = "$userinfo" ] && pass=""
    pass=$(urldec_raw "$pass")
  fi

  if ! parse_host_port "$hostport"; then
    OUT_ERROR="Shadowsocks 链接缺少加密方式、地址或端口"
    return 1
  fi
  if [ -z "$method" ] || [ -z "$PARSED_PORT" ]; then
    OUT_ERROR="Shadowsocks 链接缺少加密方式、地址或端口"
    return 1
  fi
  case "$method" in
    2022-blake3-aes-128-gcm)
      pass=$(b64norm "$pass") || {
        OUT_ERROR="Shadowsocks-2022 密钥必须是 16 字节 Base64"
        return 1
      }
      valid_ss2022_key 16 "$pass" || {
        OUT_ERROR="Shadowsocks-2022 密钥必须是 16 字节 Base64"
        return 1
      }
      ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      pass=$(b64norm "$pass") || {
        OUT_ERROR="Shadowsocks-2022 密钥必须是 32 字节 Base64"
        return 1
      }
      valid_ss2022_key 32 "$pass" || {
        OUT_ERROR="Shadowsocks-2022 密钥必须是 32 字节 Base64"
        return 1
      }
      ;;
  esac

  OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$PARSED_HOST" --argjson port "$PARSED_PORT" \
    --arg method "$method" --arg pass "$pass" \
    '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,
      method:$method,password:$pass}')
  return 0
}

# 从链接创建出站
create_out_from_link() {
  local url tag
  ask url "分享链接" ""
  [ -n "$url" ] || { warn "已取消"; return 1; }

  if ! parse_share_link "$url"; then
    error "解析失败: $OUT_ERROR"
    return 1
  fi

  local def=${OUT_SUGGEST_TAG:-out-$(gen_hex 2)}
  if [ "$def" = "direct" ] || [ -e "$NODE_DIR/$def.json" ] || [ -e "$OUT_DIR/$def.json" ]; then
    def="out-$(gen_hex 2)"
  fi
  prompt_out_tag "$def" || return 1
  tag=$SELECTED_OUT

  local json
  json=$(jq --arg t "$tag" '.tag = $t' <<<"$OUT_JSON")
  save_outbound "$tag" "$json" || return 1
  info "出站 [$tag] 已创建（$(outbound_type_display "$(jq -r '.type' <<<"$json")")）"
  return 0
}

# ================================================================
#  出站手动创建 (SOCKS5 / Snell / 自定义 JSON)
#  其余协议请用"粘贴分享链接"
# ================================================================

create_out_socks() {
  local mode=$1
  local type
  local tag
  local server
  local port
  local user
  local pass
  local json

  if [ "$mode" = "http" ]; then
    type="http"
    prompt_out_tag "http-out-$(gen_hex 2)"
  else
    type="socks"
    prompt_out_tag "socks-out-$(gen_hex 2)"
  fi
  tag=$SELECTED_OUT
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 1080
  port=$RPORT

  ask user "用户名（留空则无认证）" ""
  pass=""
  [ -n "$user" ] && ask pass "密码" ""

  if [ "$type" = "socks" ]; then
    json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
      '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}')
  else
    json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
      '{type:"http",tag:$tag,server:$server,server_port:$port}')
  fi
  if [ -n "$user" ]; then
    json=$(jq --arg u "$user" --arg p "$pass" '. + {username:$u,password:$p}' <<<"$json")
  fi
  save_outbound "$tag" "$json"
}

create_out_snell() {
  local tag server port psk json
  if ! core_supports_snell; then
    error "Snell v6 需要 sing-box 1.14.0 或更高版本，请先在核心管理中更新核心"
    return 1
  fi
  prompt_out_tag "snell-out-$(gen_hex 2)"
  tag=$SELECTED_OUT
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 6160
  port=$RPORT

  ask psk "PSK" "$(gen_b64 16)"
  while ! valid_psk "$psk"; do
    warn "PSK 长度必须是 12-255 字节，且不能包含空格或逗号"
    psk=$(gen_b64 16)
    ask psk "PSK" "$psk"
  done

  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg psk "$psk" '
    {type:"snell",tag:$tag,server:$server,server_port:$port,version:6,psk:$psk}')
  save_outbound "$tag" "$json"
}

create_out_custom() {
  local f tag json
  ask f "JSON 文件路径" ""
  f=${f/#\~/$HOME}
  [ -s "$f" ] || { error "文件不存在: $f"; return 1; }

  if ! jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' "$f" >/dev/null 2>&1; then
    error "JSON 必须是一个包含 type 和 tag 字段的出站对象"
    return 1
  fi
  tag=$(jq -r '.tag' "$f")
  if ! valid_tag "$tag" || [ "$tag" = "direct" ]; then
    error "出站名称非法或与保留名称冲突: $tag"
    return 1
  fi
  if node_tag_in_use "$tag"; then
    error "名称 [$tag] 已被节点或出站占用"
    return 1
  fi

  json=$(jq . "$f") || { error "导入失败"; return 1; }
  save_outbound "$tag" "$json"
}

# ---------------- 新增出站入口 ----------------
menu_add_outbound() {
  local c
  printf '%s\n' "------------- 新增出站 -------------"
  printf ' 1) 粘贴分享链接（vless / vmess / trojan / hysteria2 / tuic / ss / anytls）\n'
  printf ' 2) 手动填写（SOCKS5 / HTTP / Snell）\n'
  printf ' 3) 导入自定义 JSON\n'
  printf ' 0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1) create_out_from_link ;;
    2) menu_add_outbound_manual ;;
    3) create_out_custom ;;
    0) return 0 ;;
    *) warn "无效选项"; return 0 ;;
  esac
}

menu_add_outbound_manual() {
  local c
  printf '%s\n' "------------- 手动新增出站 -------------"
  printf ' 1) SOCKS5\n 2) HTTP 代理\n 3) Snell-v6\n 0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1) create_out_socks socks ;;
    2) create_out_socks http ;;
    3) create_out_snell ;;
    0) return 0 ;;
    *) warn "无效选项"; return 0 ;;
  esac
}

# ================================================================
#  出站管理菜单 + 出口路由
# ================================================================

# ---------------- 通用序号选择 ----------------
# select_index_from <结果变量> <显示函数> <候选值...>
select_index_from() {
  local __result=$1
  local __display=$2
  shift 2
  local -a __values=("$@")
  local i n choice idx
  n=${#__values[@]}
  if [ "$n" -eq 0 ]; then
    error "没有可选项"
    return 1
  fi
  for ((i = 0; i < n; i++)); do
    "$__display" "$((i + 1))" "${__values[$i]}"
  done
  ask choice "请输入序号" ""
  if ! [[ $choice =~ ^[0-9]{1,4}$ ]]; then
    error "序号无效"
    return 1
  fi
  choice=$((10#$choice))
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "$n" ]; then
    error "序号无效"
    return 1
  fi
  printf -v "$__result" '%s' "${__values[$idx]}"
  return 0
}

# 输出所有出站名称(含 direct)
collect_outbound_tags() {
  local f
  printf 'direct\n'
  shopt -s nullglob
  for f in "$OUT_DIR"/*.json; do
    printf '%s\n' "$(basename "$f" .json)"
  done
  shopt -u nullglob
}

# 输出所有节点名称
collect_node_tags() {
  local f
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    printf '%s\n' "$(basename "$f" .json)"
  done
  shopt -u nullglob
}

_disp_outbound() {
  local i=$1 tag=$2 type='内置直连'
  [ "$tag" = "direct" ] || type=$(jq -r '.type // "?"' "$OUT_DIR/$tag.json" 2>/dev/null || echo '?')
  [ "$tag" = "direct" ] || type=$(outbound_type_display "$type")
  printf '%-4s %-26s %s\n' "$i" "$tag" "$type"
}

_disp_node() {
  local i=$1 tag=$2 proto
  proto=$(meta_get "$tag" proto)
  printf '%-4s %-30s %s\n' "$i" "$tag" "$(proto_display "$proto")"
}

select_outbound() {
  local -a tags=()
  mapfile -t tags < <(collect_outbound_tags)
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "---------------------------------------------------"
  select_index_from SELECTED_OUT _disp_outbound "${tags[@]}"
}

# 只列出真实出站（不含 direct），用于“绑定 / 修改出口”
select_outbound_real() {
  local -a tags=()
  mapfile -t tags < <(collect_outbound_tags)
  tags=("${tags[@]:1}")
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无自定义出站，请先在「出站管理」中新增"
    return 1
  fi
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "---------------------------------------------------"
  select_index_from SELECTED_OUT _disp_outbound "${tags[@]}"
}

select_node() {
  local -a tags=()
  mapfile -t tags < <(collect_node_tags)
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无节点"
    return 1
  fi
  printf '%-4s %-30s %s\n' "序号" "节点名称" "协议"
  printf '%s\n' "---------------------------------------------------------------"
  select_index_from SELECTED _disp_node "${tags[@]}"
}

_disp_node_route() {
  local i=$1
  local tag=$2
  local proto out
  proto=$(meta_get "$tag" proto)
  out=$(route_of_node "$tag")
  printf '%-4s %-30s %-22s %s\n' "$i" "$tag" "$(proto_display "$proto")" "$out"
}

# 多选节点：支持单个、多个、0=全部；回车取消
select_nodes_multi() {
  local -a tags=() tokens=() picks=()
  local i raw token dup bad
  SELECTED_NODES=()
  mapfile -t tags < <(collect_node_tags)
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无节点"
    return 1
  fi
  printf '%-4s %-30s %-22s %s\n' "序号" "节点名称" "协议" "当前出口"
  printf '%s\n' "-----------------------------------------------------------------------------------"
  for ((i = 0; i < ${#tags[@]}; i++)); do
    _disp_node_route "$((i + 1))" "${tags[$i]}"
  done
  while true; do
    ask raw "请输入序号（空格/逗号分隔，0=全部节点，回车取消）" ""
    [ -n "$raw" ] || { warn "已取消"; return 1; }
    raw=${raw//,/ }
    raw=${raw//，/ }
    raw=${raw//、/ }
    read -r -a tokens <<<"$raw"
    [ ${#tokens[@]} -eq 0 ] && { warn "请输入至少一个序号"; continue; }
    picks=()
    bad=""
    for token in "${tokens[@]}"; do
      if [ "$token" = "0" ]; then
        SELECTED_NODES=("${tags[@]}")
        return 0
      fi
      if ! [[ $token =~ ^[0-9]{1,4}$ ]]; then
        bad+=" $token"
        continue
      fi
      token=$((10#$token))
      if [ "$token" -lt 1 ] || [ "$token" -gt ${#tags[@]} ]; then
        bad+=" $token"
        continue
      fi
      dup=0
      for i in "${picks[@]:-}"; do
        [ "$i" = "$token" ] && dup=1
      done
      [ "$dup" -eq 0 ] && picks+=("$token")
    done
    if [ -n "$bad" ]; then
      warn "无效序号:$bad"
      continue
    fi
    if [ ${#picks[@]} -eq 0 ]; then
      warn "未选择有效节点"
      continue
    fi
    SELECTED_NODES=()
    for i in "${picks[@]}"; do
      SELECTED_NODES+=("${tags[$((i - 1))]}")
    done
    return 0
  done
}

# ---------------- 查看 ----------------
view_outbound() {
  select_outbound || { pause; return 0; }
  printf '==============================================\n'
  if [ "$SELECTED_OUT" = "direct" ]; then
    jq -n '{type:"direct",tag:"direct"}'
  else
    jq . "$OUT_DIR/$SELECTED_OUT.json"
  fi
  pause
}

delete_outbound() {
  local -a tags=()
  mapfile -t tags < <(collect_outbound_tags)
  if [ ${#tags[@]} -le 1 ]; then
    warn "暂无可删除的出站"
    pause
    return 0
  fi
  tags=("${tags[@]:1}")
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "---------------------------------------------------"
  if ! select_index_from SELECTED_OUT _disp_outbound "${tags[@]}"; then
    pause
    return 0
  fi
  local tag=$SELECTED_OUT removed=0 rf
  warn "即将删除出站 [$tag]"
  if ! confirm "确定删除?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  rm -f "$OUT_DIR/$tag.json"
  shopt -s nullglob
  for rf in "$ROUTE_DIR"/*.outbound; do
    if [ "$(head -n1 "$rf" 2>/dev/null || true)" = "$tag" ]; then
      rm -f "$rf"
      removed=$((removed + 1))
    fi
  done
  shopt -u nullglob
  [ "$removed" -gt 0 ] && warn "已清除 $removed 个节点对该出站的绑定，这些节点回到直连"
  info "出站 [$tag] 已删除"
  apply_changes
  pause
}

edit_outbound_file() {
  local file=$1 ed='' c
  [ -n "${EDITOR:-}" ] && ed=$EDITOR
  if [ -z "$ed" ]; then
    for c in nano vim vi; do
      command -v "$c" >/dev/null 2>&1 && { ed=$c; break; }
    done
  fi
  if [ -n "$ed" ]; then
    # shellcheck disable=SC2086
    $ed "$file"
  else
    warn "未找到文本编辑器，请手动编辑: $file"
    read -r -p "编辑保存后按回车继续校验..." _ || true
  fi
}

edit_outbound() {
  local -a tags=()
  mapfile -t tags < <(collect_outbound_tags)
  if [ ${#tags[@]} -le 1 ]; then
    warn "暂无可编辑的出站"
    pause
    return 0
  fi
  tags=("${tags[@]:1}")
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "---------------------------------------------------"
  select_index_from SELECTED_OUT _disp_outbound "${tags[@]}" || { pause; return 0; }

  local tag=$SELECTED_OUT
  local file="$OUT_DIR/$SELECTED_OUT.json"
  local backup="$OUT_DIR/$SELECTED_OUT.json.bak"
  local newtag
  cp -f "$file" "$backup" || { error "备份失败"; pause; return 0; }
  edit_outbound_file "$file"

  if ! jq -e 'type=="object" and (.tag|type=="string") and (.type|type=="string")' "$file" >/dev/null 2>&1; then
    error "JSON 校验失败，已恢复原配置"
    mv -f "$backup" "$file"
    pause
    return 0
  fi
  newtag=$(jq -r '.tag' "$file")
  if [ "$newtag" != "$tag" ]; then
    error "不允许修改 tag (${tag} -> ${newtag})，已恢复原配置"
    mv -f "$backup" "$file"
    pause
    return 0
  fi
  if ! apply_changes; then
    warn "配置校验失败，已恢复原配置"
    mv -f "$backup" "$file"
    rebuild_config >/dev/null 2>&1 || true
    pause
    return 0
  fi
  rm -f "$backup"
  info "出站 [$tag] 已更新"
  pause
}

# ================================================================
#  出口路由: 节点 -> 落地
# ================================================================
route_of_node() {
  local tag=$1
  if [ -s "$ROUTE_DIR/$tag.outbound" ]; then
    head -n1 "$ROUTE_DIR/$tag.outbound" 2>/dev/null || printf 'direct'
  else
    printf 'direct'
  fi
}

view_routes() {
  local -a tags=()
  mapfile -t tags < <(collect_node_tags)
  if [ ${#tags[@]} -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  local i tag proto out
  printf '%-4s %-28s %-22s %s\n' "序号" "节点名称" "协议" "出口"
  printf '%s\n' "-----------------------------------------------------------------------------------"
  for ((i = 0; i < ${#tags[@]}; i++)); do
    tag=${tags[$i]}
    proto=$(meta_get "$tag" proto)
    out=$(route_of_node "$tag")
    if [ "$out" != "direct" ] && [ ! -f "$OUT_DIR/$out.json" ]; then
      out="$out [缺失]"
    fi
    printf '%-4s %-28s %-22s %s\n' "$((i + 1))" "$tag" "$(proto_display "$proto")" "$out"
  done
  pause
}

set_route() {
  local tag=$1 out=$2
  mkdir -p "$ROUTE_DIR"
  if [ "$out" = "direct" ]; then
    rm -f "$ROUTE_DIR/$tag.outbound"
  else
    printf '%s\n' "$out" > "$ROUTE_DIR/$tag.outbound"
  fi
}

bind_nodes_route() {
  local -a nodes=()
  local out node
  if [ -x "$BIN" ]; then
    check_config || { error "当前配置校验失败，请先修复出站配置"; pause; return 0; }
  fi
  select_nodes_multi || { pause; return 0; }
  nodes=("${SELECTED_NODES[@]}")
  select_outbound_real || { pause; return 0; }
  out=$SELECTED_OUT
  if ! confirm "将 ${#nodes[@]} 个节点的出口设置为 [$out]?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  for node in "${nodes[@]}"; do
    set_route "$node" "$out"
  done
  info "已设置 ${#nodes[@]} 个节点的出口为 [$out]"
  apply_changes
  pause
}

reset_nodes_direct() {
  local -a nodes=()
  local node count changed=0
  if [ -x "$BIN" ]; then
    check_config || { error "当前配置校验失败，请先修复出站配置"; pause; return 0; }
  fi
  select_nodes_multi || { pause; return 0; }
  nodes=("${SELECTED_NODES[@]}")
  count=${#nodes[@]}
  for node in "${nodes[@]}"; do
    [ "$(route_of_node "$node")" = "direct" ] || changed=$((changed + 1))
  done
  if [ "$changed" -eq 0 ]; then
    info "所选节点都已经是直连"
    pause
    return 0
  fi
  if ! confirm "将 $count 个节点改为直连? 其中 $changed 个当前有出口绑定。" "n"; then
    info "已取消"
    pause
    return 0
  fi
  for node in "${nodes[@]}"; do
    set_route "$node" "direct"
  done
  info "已处理 $count 个节点，所选节点全部为直连"
  apply_changes
  pause
}

menu_routes() {
  local c
  while true; do
    printf '\n%s\n' "------------- 出口路由 -------------"
    printf ' 1) 查看节点出口\n'
    printf ' 2) 为节点绑定 / 修改出口\n'
    printf ' 3) 为节点取消 / 恢复直连\n'
    printf ' 0) 返回\n'
    ask c "请选择" ""
    case "$c" in
      1) view_routes ;;
      2) bind_nodes_route ;;
      3) reset_nodes_direct ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

menu_outbounds() {
  local c
  while true; do
    printf '\n%s\n' "------------- 出站管理 -------------"
    printf ' 1) 新增出站\n'
    printf ' 2) 查看出站\n'
    printf ' 3) 编辑出站\n'
    printf ' 4) 删除出站\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) menu_add_outbound; pause ;;
      2) view_outbound ;;
      3) edit_outbound ;;
      4) delete_outbound ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ================================================================
#  核心管理
# ================================================================
update_core() {
  local cur latest was=0
  if [ ! -x "$BIN" ]; then
    warn "尚未安装核心，开始安装"
    install_core && write_service
    return $?
  fi
  cur=$(singbox_version)
  info "当前核心版本: ${cur:-未知}"
  latest=$(get_latest_version) || true
  if [ -z "$latest" ]; then
    error "获取最新版本失败，请检查网络"
    return 1
  fi
  info "最新核心版本: $latest"
  if [ "$cur" = "$latest" ]; then
    if ! confirm "当前已是最新版本，是否强制重新安装?" "n"; then
      return 0
    fi
  else
    if ! confirm "是否更新到 v${latest} ?" "y"; then
      info "已取消"
      return 0
    fi
  fi
  if core_running; then
    was=1
    stop_core
  fi
  if install_core "$latest"; then
    write_service
    if [ "$was" = "1" ]; then
      start_core || return 1
    fi
    info "核心更新完成"
  else
    error "核心更新失败"
    if [ "$was" = "1" ]; then
      start_core
    fi
    return 1
  fi
}

uninstall_core() {
  local keep=1
  warn "卸载将停止服务并删除核心文件: $BIN"
  if ! confirm "确定卸载 sing-box 核心?" "n"; then
    info "已取消"
    return 0
  fi
  if confirm "是否保留节点、证书和配置文件? (推荐保留)" "y"; then
    keep=1
  else
    keep=0
  fi
  stop_core
  if has_systemd; then
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
  fi
  if has_openrc && [ -f "$OPENRC_FILE" ]; then
    if command -v rc-update >/dev/null 2>&1; then
      rc-update del sing-box default >/dev/null 2>&1 || true
    fi
    rm -f "$OPENRC_FILE"
  fi
  rm -f "$BIN" "${BIN}.new" "${BIN}.old"
  info "核心已卸载"
  if [ "$keep" = "0" ]; then
    if confirm "再次确认: 删除整个目录 $SB_DIR ? 此操作不可恢复" "n"; then
      rm -rf "$SB_DIR"
      info "配置目录已删除"
      return 0
    fi
    info "已保留配置目录"
  else
    info "配置目录已保留: $SB_DIR"
  fi
}

show_core_version() {
  if [ -x "$BIN" ]; then
    "$BIN" version
  else
    warn "未安装 sing-box 核心"
  fi
}

menu_core() {
  local c
  while true; do
    printf '\n%s\n' "------------- 核心管理 -------------"
    printf ' 1) 更新核心\n'
    printf ' 2) 卸载核心\n'
    printf ' 3) 查看核心版本\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) update_core; pause ;;
      2) uninstall_core; pause ;;
      3) show_core_version; pause ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

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
  场景: 设备 -> 服务器A(节点) -> 服务器B(节点) -> 目标网站

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

# ================================================================
#  主菜单
# ================================================================
print_header() {
  local ver state
  ver=$(singbox_version)
  [ -n "$ver" ] || ver="未安装"
  if core_running; then
    state="${C_GRN}运行中${C_RESET}"
  else
    state="${C_YEL}已停止${C_RESET}"
  fi
  printf '%s\n' "=================================================="
  printf '           sing-box 一键管理脚本\n'
  printf ' 核心: %s   状态: %s   节点: %s   出站: %s\n' \
    "$ver" "$state" "$(count_nodes)" "$(count_outbounds)"
  printf '%s\n' "=================================================="
}

main_menu() {
  local c
  while true; do
    ensure_dirs
    clear 2>/dev/null || true
    print_header
    printf ' 1) 节点管理        2) 出站管理\n'
    printf ' 3) 出口路由        4) 运行管理\n'
    printf ' 5) 核心管理        6) 分享链接\n'
    printf ' 7) 解析域名        8) 使用帮助\n'
    printf ' 0) 退出\n'
    printf '%s\n' "--------------------------------------------------"
    ask c "请选择" ""
    case "$c" in
      1) menu_nodes ;;
      2) menu_outbounds ;;
      3) menu_routes ;;
      4) menu_runtime ;;
      5) menu_core ;;
      6) show_all_links ;;
      7) menu_domain ;;
      8) menu_help ;;
      0)
        info "已退出"
        exit 0
        ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ================================================================
#  入口: 命令行参数、首次安装、菜单启动
# ================================================================
usage() {
  cat <<EOF
sing-box 一键部署管理脚本

用法:
  bash $0            启动交互式管理菜单
  bash $0 install    安装/更新核心并注册系统服务
  bash $0 status     查看运行状态
  bash $0 help       显示帮助

说明:
  需要 root 权限运行。
  数据目录: $SB_DIR
EOF
}

require_bash4() {
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    error "需要 bash 4.0 或更高版本"
    exit 1
  fi
}

# 首次运行: 无核心则自动按架构下载安装，不询问
bootstrap_core() {
  [ -x "$BIN" ] && return 0
  printf '%s\n' "=================================================="
  printf '%s\n' "         sing-box 一键部署管理脚本"
  printf '%s\n' "=================================================="
  printf '未检测到 sing-box 核心，开始自动安装 ...\n\n'
  if ! install_core; then
    error "核心安装失败，请检查网络后重试"
    return 1
  fi
  write_service
  rebuild_config || true
  info "安装完成"
  return 0
}

main() {
  require_bash4

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  need_root
  ensure_dirs
  detect_resources
  detect_net_env

  case "${1:-}" in
    install)
      ensure_deps || exit 1
      install_core || exit 1
      write_service
      rebuild_config || exit 1
      info "安装完成，执行 bash $0 进入管理菜单"
      exit 0
      ;;
    status)
      show_status
      exit 0
      ;;
  esac

  ensure_deps || { error "依赖不可用，脚本无法运行"; exit 1; }

  bootstrap_core || { pause; exit 1; }

  if ! "$BIN" version >/dev/null 2>&1; then
    warn "当前核心无法运行，请进入核心管理重新安装"
  fi

  # 系统服务缺失时补写
  if has_systemd && [ ! -f "$SERVICE_FILE" ]; then
    write_service
  elif has_openrc && [ ! -f "$OPENRC_FILE" ]; then
    write_service
  fi

  [ -f "$CONF" ] || rebuild_config || true

  main_menu
}

main "$@"
