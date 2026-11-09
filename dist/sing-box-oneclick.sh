#!/usr/bin/env bash
# ================================================================
#  sing-box 一键部署管理脚本（单文件构建版）
#  由 build.sh 自动生成，请勿直接编辑；源码见 lib/ 目录
#  构建时间: 2026-11-09 21:58:23
# ================================================================

# ================================================================
#  基础模块: 常量、颜色、交互输入、权限与 systemd 检测
# ================================================================

set -uo pipefail
umask 077

SCRIPT_VERSION="2026.11.09"

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
  local missing=() cmd need_jq=0
  if ! jq_version_supported; then
    need_jq=1
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
  if [ ${#missing[@]} -eq 0 ]; then
    if [ "$need_jq" -eq 1 ]; then
      install_jq_static || return 1
    fi
    return 0
  fi
  info "缺少依赖: ${missing[*]}，正在自动安装 ..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${missing[@]}" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${missing[@]}" >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${missing[@]}" >/dev/null 2>&1 || true
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${missing[@]}" >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "${missing[@]}" >/dev/null 2>&1 || true
  else
    error "无法识别包管理器，请手动安装: ${missing[*]}"
    return 1
  fi
  hash -r 2>/dev/null || true
  if [ "$need_jq" -eq 1 ]; then
    install_jq_static || true
  fi
  local fail=0
  for cmd in curl openssl tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || fail=1
  done
  if ! jq_version_supported; then
    fail=1
  fi
  if [ "$fail" -ne 0 ]; then
    error "依赖安装失败，请手动安装: ${missing[*]}"
    return 1
  fi
  info "依赖安装完成"
  return 0
}

install_jq_static() {
  local asset='' tmp
  if [ -z "${ARCH:-}" ]; then
    detect_arch >/dev/null 2>&1 || true
  fi
  case "${ARCH:-}" in
    amd64)   asset="jq-linux-amd64" ;;
    arm64)   asset="jq-linux-arm64" ;;
    armv7)   asset="jq-linux-armhf" ;;
    armv6|armv5) asset="jq-linux-armel" ;;
    386)     asset="jq-linux-i386" ;;
    ppc64le) asset="jq-linux-ppc64el" ;;
    riscv64) asset="jq-linux-riscv64" ;;
    s390x)   asset="jq-linux-s390x" ;;
    *)
      error "当前架构暂无预编译 jq，请手动安装 jq"
      return 1
      ;;
  esac
  info "尝试安装静态 jq (${asset}) ..."
  tmp=$(mktemp -d) || return 1
  if download_file "https://github.com/jqlang/jq/releases/download/jq-1.7.1/${asset}" "$tmp/jq"; then
    chmod 755 "$tmp/jq"
    mkdir -p /usr/local/bin
    mv -f "$tmp/jq" /usr/local/bin/jq
    hash -r 2>/dev/null || true
    rm -rf "$tmp"
    if jq_version_supported; then
      info "静态 jq 安装完成: $(jq --version)"
      return 0
    fi
  else
    rm -rf "$tmp"
  fi
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

install_core() {
  local version=${1:-} tmp extract url base_url asset_suffix='' verr old_backup=''
  detect_arch || return 1
  ensure_deps || return 1
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
  tmp=$(mktemp -d) || { error "创建临时目录失败"; return 1; }
  if ! download_file "$url" "$tmp/sing-box.tar.gz"; then
    if [ -n "$asset_suffix" ]; then
      warn "musl 静态版下载失败，尝试通用版 ..."
      url="${base_url}/sing-box-${version}-linux-${ARCH}.tar.gz"
      if ! download_file "$url" "$tmp/sing-box.tar.gz"; then
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
  if ! tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"; then
    error "核心压缩包解压失败"
    rm -rf "$tmp"
    return 1
  fi
  extract=$(find "$tmp" -type f -name sing-box 2>/dev/null | head -n1)
  if [ -z "$extract" ]; then
    error "未在压缩包中找到 sing-box 可执行文件"
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$(dirname "$BIN")" 2>/dev/null || true
  cp -f "$extract" "${BIN}.new" || { error "写入核心失败"; rm -rf "$tmp"; return 1; }
  chmod 755 "${BIN}.new"
  if [ -x "$BIN" ]; then
    if cp -f "$BIN" "${BIN}.old"; then
      old_backup="${BIN}.old"
    else
      warn "旧核心备份失败，继续安装"
    fi
  fi
  if ! mv -f "${BIN}.new" "$BIN"; then
    if [ -n "$old_backup" ] && [ -x "$old_backup" ]; then
      mv -f "$old_backup" "$BIN"
      warn "已恢复旧核心: $BIN"
    fi
    error "替换核心失败"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  if ! verr=$("$BIN" version 2>&1); then
    error "核心已下载但无法运行:"
    printf '%s\n' "$verr" >&2
    if [ -n "$old_backup" ] && [ -x "$old_backup" ]; then
      mv -f "$old_backup" "$BIN"
      warn "已恢复旧核心: $BIN"
    fi
    if command -v apk >/dev/null 2>&1; then
      warn "如确认是 musl 兼容问题，可尝试: apk add --no-cache gcompat"
    fi
    return 1
  fi
  [ -n "$old_backup" ] && rm -f "$old_backup"
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
    cat > /etc/init.d/sing-box <<'EOF'
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
    chmod 755 /etc/init.d/sing-box
    if command -v rc-update >/dev/null 2>&1; then
      rc-update add sing-box default >/dev/null 2>&1 || true
    fi
    info "OpenRC 服务已写入并设置开机自启"
    return 0
  fi

  warn "未检测到 systemd/OpenRC，将使用后台进程方式运行"
}


# ================================================================
#  配置生成
# ================================================================
ensure_dirs() {
  mkdir -p "$SB_DIR" "$NODE_DIR" "$OUT_DIR" "$CERT_DIR" "$LOG_DIR" "$SB_DIR/routes"
  chmod 700 "$CERT_DIR" 2>/dev/null || true
  [ -f "$LOG_FILE" ] || touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  [ -s "$FINAL_FILE" ] || printf 'direct\n' > "$FINAL_FILE"
}

count_nodes() {
  find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

count_outbounds() {
  find "$OUT_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

rebuild_config() {
  local tmp rc=0 final f route_dir tag rf out
  tmp=$(mktemp) || { error "创建临时文件失败"; return 1; }
  jq -n --arg logfile "$LOG_FILE" '{
      log: { level: "info", timestamp: true, output: $logfile },
      inbounds: [],
      outbounds: [ { type: "direct", tag: "direct" } ],
      route: { rules: [], final: "direct", auto_detect_interface: true }
    }' > "$tmp" || { rm -f "$tmp"; error "初始化配置模板失败"; return 1; }

  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    if ! jq --slurpfile inc "$f" '.inbounds += $inc' "$tmp" > "$tmp.next"; then
      rc=1; break
    fi
    mv -f "$tmp.next" "$tmp"
  done
  if [ "$rc" -eq 0 ]; then
    for f in "$OUT_DIR"/*.json; do
      if ! jq --slurpfile inc "$f" '.outbounds += $inc' "$tmp" > "$tmp.next"; then
        rc=1; break
      fi
      mv -f "$tmp.next" "$tmp"
    done
  fi

  if [ "$rc" -eq 0 ]; then
    route_dir="$SB_DIR/routes"
    if [ -d "$route_dir" ]; then
      for rf in "$route_dir"/*.outbound; do
        [ -e "$rf" ] || continue
        tag=$(basename "$rf" .outbound)
        [ -f "$NODE_DIR/$tag.json" ] || continue
        out=$(head -n1 "$rf" 2>/dev/null || true)
        [ -n "$out" ] || continue
        if jq -e --arg t "$out" '.outbounds[] | select(.tag == $t)' "$tmp" >/dev/null 2>&1; then
          if ! jq --arg in "$tag" --arg out "$out" \
            '.route.rules += [{inbound: [$in], outbound: $out}]' "$tmp" > "$tmp.next"; then
            rc=1
            break
          fi
          mv -f "$tmp.next" "$tmp"
        else
          warn "节点 [$tag] 绑定的出站 [$out] 不存在，已忽略"
        fi
      done
    fi
  fi
  shopt -u nullglob

  if [ "$rc" -eq 0 ]; then
    if [ -s "$FINAL_FILE" ]; then
      final=$(head -n1 "$FINAL_FILE")
    else
      final="direct"
    fi
    if ! jq --arg final "$final" '.route.final = $final' "$tmp" > "$tmp.next"; then
      rc=1
    else
      mv -f "$tmp.next" "$tmp"
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mv -f "$tmp" "$CONF"
    chmod 600 "$CONF"
  else
    rm -f "$tmp" "$tmp.next"
    error "生成 config.json 失败，请检查节点/出站文件是否为合法 JSON"
    return 1
  fi
  return 0
}

check_config() {
  local out
  ensure_dirs
  rebuild_config || return 1
  out=$("$BIN" check -c "$CONF" 2>&1) || {
    error "配置校验失败:"
    printf '%s\n' "$out" >&2
    return 1
  }
  return 0
}


# ================================================================
#  随机值生成
# ================================================================
gen_uuid() {
  "$BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16
}

gen_hex() {
  local bytes=${1:-8}
  "$BIN" generate rand --hex "$bytes" 2>/dev/null || openssl rand -hex "$bytes"
}

gen_b64() {
  local bytes=${1:-16}
  "$BIN" generate rand --base64 "$bytes" 2>/dev/null || openssl rand -base64 "$bytes" | tr -d '\n'
}

gen_reality_keypair() {
  "$BIN" generate reality-keypair 2>/dev/null
}

singbox_version() {
  [ -x "$BIN" ] || { printf ''; return 0; }
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

core_supports_anytls() {
  core_at_least 1 12
}

core_supports_snell() {
  core_at_least 1 14
}

get_server_ip() {
  local ip='' url
  if [ -s "$IP_FILE" ]; then
    ip=$(head -n1 "$IP_FILE" 2>/dev/null || true)
    if [ -n "$ip" ]; then
      printf '%s' "$ip"
      return 0
    fi
  fi
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$ip" ] && break
  done
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  if [ -n "$ip" ]; then
    printf '%s\n' "$ip" > "$IP_FILE"
  fi
  printf '%s' "$ip"
}

country_code_valid() {
  [[ ${1:-} =~ ^[A-Z]{2}$ ]]
}

normalize_country_code() {
  local c
  c=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  if country_code_valid "$c"; then
    printf '%s' "$c"
  else
    printf 'XX'
  fi
}

get_server_country_code() {
  local ip='' json='' cc=''
  if [ -s "$COUNTRY_FILE" ]; then
    cc=$(head -n1 "$COUNTRY_FILE" 2>/dev/null || true)
    cc=$(printf '%s' "$cc" | tr '[:lower:]' '[:upper:]')
    if country_code_valid "$cc"; then
      printf '%s' "$cc"
      return 0
    fi
  fi
  ip=$(get_server_ip)
  if [ -z "$ip" ]; then
    printf 'XX'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    json=$(curl -fsS --connect-timeout 5 --max-time 8 \
      "http://ip-api.com/json/${ip}?fields=status,countryCode" 2>/dev/null || true)
    if [ -n "$json" ] && [ "$(jq -r '.status // empty' <<<"$json" 2>/dev/null || true)" = "success" ]; then
      cc=$(jq -r '.countryCode // empty' <<<"$json" 2>/dev/null || true)
    fi
    if ! country_code_valid "$(printf '%s' "$cc" | tr '[:lower:]' '[:upper:]')"; then
      json=$(curl -fsS --connect-timeout 5 --max-time 8 \
        "https://ipwho.is/${ip}" 2>/dev/null || true)
      if [ -n "$json" ] && [ "$(jq -r '.success // false' <<<"$json" 2>/dev/null || true)" = "true" ]; then
        cc=$(jq -r '.country_code // empty' <<<"$json" 2>/dev/null || true)
      fi
    fi
    if ! country_code_valid "$(printf '%s' "$cc" | tr '[:lower:]' '[:upper:]')"; then
      json=$(curl -fsS --connect-timeout 5 --max-time 8 \
        "https://ipinfo.io/${ip}/json" 2>/dev/null || true)
      cc=$(jq -r '.country // empty' <<<"$json" 2>/dev/null || true)
    fi
  fi
  cc=$(normalize_country_code "$cc")
  printf '%s\n' "$cc" > "$COUNTRY_FILE"
  printf '%s' "$cc"
}

urlenc() {
  jq -rn --arg v "$1" '$v|@uri'
}

b64url() {
  printf '%s' "$1" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}


# ================================================================
#  运行管理
# ================================================================
core_running() {
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl is-active --quiet sing-box 2>/dev/null && return 0
  fi
  if has_openrc && [ -f /etc/init.d/sing-box ]; then
    rc-service sing-box status >/dev/null 2>&1 && return 0
  fi
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

start_core() {
  [ -x "$BIN" ] || { error "未安装 sing-box 核心，请先安装"; return 1; }
  ensure_dirs
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
  elif has_openrc; then
    [ -f /etc/init.d/sing-box ] || write_service
    rc-service sing-box start >/dev/null 2>&1 || true
    sleep 1
    if core_running; then
      info "sing-box 已启动 (OpenRC)"
      return 0
    fi
    error "启动失败，最近日志:"
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
    return 1
  else
    nohup "$BIN" run -c "$CONF" >>"$LOG_FILE" 2>&1 &
    local pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      info "sing-box 已启动 (PID $pid)"
      return 0
    fi
    error "启动失败，请查看日志文件: $LOG_FILE"
    rm -f "$PID_FILE"
    return 1
  fi
}

stop_core() {
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl stop sing-box 2>/dev/null || true
  fi
  if has_openrc && [ -f /etc/init.d/sing-box ]; then
    rc-service sing-box stop >/dev/null 2>&1 || true
  fi
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
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
  if has_systemd; then
    [ -f "$SERVICE_FILE" ] || write_service
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart sing-box 2>/dev/null || true
    sleep 1
    if core_running; then
      info "sing-box 已重启"
      return 0
    fi
    error "重启失败，最近日志:"
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
    return 1
  elif has_openrc; then
    [ -f /etc/init.d/sing-box ] || write_service
    rc-service sing-box restart >/dev/null 2>&1 || true
    sleep 1
    if core_running; then
      info "sing-box 已重启 (OpenRC)"
      return 0
    fi
    error "重启失败，最近日志:"
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
    return 1
  else
    stop_core >/dev/null 2>&1 || true
    start_core
  fi
}

apply_changes() {
  rebuild_config || return 1
  if core_running; then
    if confirm "配置已更新，是否重启核心使其生效?"; then
      restart_core
    else
      warn "未重启，新配置尚未生效"
    fi
  else
    if confirm "核心当前未运行，是否立即启动?" "n"; then
      start_core
    fi
  fi
  return 0
}

show_status() {
  local ver
  ver=$(singbox_version)
  printf '%s\n' "-------------- 运行状态 --------------"
  printf '核心版本 : %s\n' "${ver:-未安装}"
  if core_running; then
    printf '运行状态 : %s运行中%s\n' "$C_GRN" "$C_RESET"
  else
    printf '运行状态 : %s已停止%s\n' "$C_RED" "$C_RESET"
  fi
  printf '节点数量 : %s\n' "$(count_nodes)"
  printf '出站数量 : %s (默认: %s)\n' "$(count_outbounds)" "$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)"
  printf '配置文件 : %s\n' "$CONF"
  printf '日志文件 : %s\n' "$LOG_FILE"
  printf '%s\n' "--------------------------------------"
  if has_systemd && [ -f "$SERVICE_FILE" ]; then
    systemctl status sing-box --no-pager -l 2>/dev/null | head -n 25 || true
  elif has_openrc && [ -f /etc/init.d/sing-box ]; then
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
  printf '1) 最近 100 行日志\n2) 实时跟踪日志 (Ctrl+C 返回)\n3) systemd 日志 (仅 systemd 系统)\n0) 返回\n'
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
      if [ ! -f "$LOG_FILE" ]; then
        warn "暂无日志文件"
        return 0
      fi
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
        warn "当前系统不是 systemd，请使用第 2 项查看日志文件"
        pause
      fi
      ;;
    0|*)
      ;;
  esac
}


# ================================================================
#  节点基础工具
# ================================================================
prompt_tag() {
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    if [ -z "${BATCH_TAG:-}" ]; then
      error "批量模式缺少节点名称"
      return 1
    fi
    TAG_VAL=$BATCH_TAG
    return 0
  fi
  local def=${AUTO_TAG_DEFAULT:-$1} v
  while true; do
    ask v "节点名称" "$def"
    if [ -z "$v" ]; then
      warn "名称不能为空"
      continue
    fi
    case "$v" in
      *" "*|*$'\t'*|*/*|*\\*|.*)
        warn "名称不能包含空格或斜杠，且不能以点开头"
        continue
        ;;
    esac
    if [ -e "$NODE_DIR/$v.json" ]; then
      warn "节点 $v 已存在"
      continue
    fi
    if [ -e "$OUT_DIR/$v.json" ]; then
      warn "该名称与出站名称冲突"
      continue
    fi
    TAG_VAL=$v
    return 0
  done
}

port_in_batch() {
  local port=$1 transport=${2:-} i
  [ ${#BATCH_PORT_LIST[@]} -gt 0 ] || return 1
  for i in "${!BATCH_PORT_LIST[@]}"; do
    [ "${BATCH_PORT_TYPES[$i]:-}" = "$transport" ] || continue
    if [ "${BATCH_PORT_LIST[$i]}" = "$port" ]; then
      return 0
    fi
  done
  return 1
}

system_port_in_use() {
  local port=$1 transport=${2:-tcp} out=''
  if command -v ss >/dev/null 2>&1; then
    if [ "$transport" = "udp" ]; then
      out=$(ss -lnu 2>/dev/null || true)
    else
      out=$(ss -lnt 2>/dev/null || true)
    fi
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | awk '{print $4}' | grep -qE "[:.]${port}$"
      return $?
    fi
  fi
  if command -v netstat >/dev/null 2>&1; then
    if [ "$transport" = "udp" ]; then
      out=$(netstat -lnu 2>/dev/null || true)
    else
      out=$(netstat -lnt 2>/dev/null || true)
    fi
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | awk '{print $4}' | grep -qE "[:.]${port}$"
      return $?
    fi
  fi
  return 1
}

port_available() {
  local port=$1 transport=${2:-tcp} skip_system=${3:-0}
  port_in_use "$port" "$transport" && return 1
  [ "$skip_system" = "1" ] && return 0
  system_port_in_use "$port" "$transport" && return 1
  return 0
}

random_free_port() {
  local transport=${1:-tcp} i cand
  for ((i=0; i<200; i++)); do
    cand=$(( (RANDOM * 32768 + RANDOM) % 50000 + 10000 ))
    if port_available "$cand" "$transport" && ! port_in_batch "$cand" "$transport"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  for ((cand=10000; cand<60000; cand++)); do
    if port_available "$cand" "$transport" && ! port_in_batch "$cand" "$transport"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  printf '%s' "$((10000 + RANDOM % 50000))"
}

suggest_port() {
  local transport=${1:-tcp} p i
  for p in 443 8443 2053 2083 2087 2096; do
    if port_available "$p" "$transport" && ! port_in_batch "$p" "$transport"; then
      printf '%s' "$p"
      return 0
    fi
  done
  for ((i=10000; i<60000; i+=7)); do
    if port_available "$i" "$transport" && ! port_in_batch "$i" "$transport"; then
      printf '%s' "$i"
      return 0
    fi
  done
  printf '443'
}

port_in_use() {
  local port=$1 transport=${2:-} f base type t
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    base=$(basename "$f" .json)
    if [ -n "${EXCLUDE_TAG:-}" ] && [ "$base" = "$EXCLUDE_TAG" ]; then
      continue
    fi
    type=$(jq -r '.type' "$f" 2>/dev/null || true)
    case "$type" in
      hysteria2|tuic) t="udp" ;;
      *)              t="tcp" ;;
    esac
    if [ -n "$transport" ] && [ "$t" != "$transport" ]; then
      continue
    fi
    if jq -e --argjson p "$port" '.listen_port == $p' "$f" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

ask_port() {
  local def=$1 transport=${2:-tcp} v prompt="监听端口"
  if [ "${BATCH_MODE:-0}" = "1" ] && [ -n "${BATCH_PORT:-}" ]; then
    PORT_VAL=$BATCH_PORT
    return 0
  fi
  if [ -z "${EXCLUDE_TAG:-}" ]; then
    def=""
    prompt="监听端口（回车随机）"
  fi
  while true; do
    ask v "$prompt" "$def"
    if [ -z "$v" ]; then
      v=$(random_free_port "$transport")
      printf '\n'
      info "使用随机监听端口: $v/$transport"
    fi
    if ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
      warn "监听端口范围 1-65535"
      continue
    fi
    v=$((10#$v))
    if [ -n "${EXCLUDE_TAG:-}" ] && [ "$v" = "$def" ]; then
      if port_in_use "$v" "$transport"; then
        warn "监听端口 $v 已被同类型节点占用，请更换"
        continue
      fi
    elif ! port_available "$v" "$transport"; then
      warn "监听端口 $v 已被同类型节点或系统服务占用，请更换"
      continue
    fi
    PORT_VAL=$v
    return 0
  done
}

meta_get() {
  local tag=$1 key=$2
  [ -f "$NODE_DIR/$tag.meta" ] || { printf ''; return 0; }
  sed -n "s/^${key}=//p" "$NODE_DIR/$tag.meta" | head -n1
}

node_obj() {
  jq -c . "$NODE_DIR/$1.json" 2>/dev/null
}

n_get() {
  local tag=$1 filter=$2 def=${3:-}
  node_obj "$tag" | jq -r --arg d "$def" "$filter // \$d" 2>/dev/null || printf '%s' "$def"
}

list_nodes_table() {
  local f tag proto display port domain i=0
  printf '%-4s %s%20s %s%20s %-8s %s\n' "序号" "节点名称" "" "协议" "" "监听端口" "域名/伪装域名"
  printf '%s\n' "--------------------------------------------------------------------------------"
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    i=$((i+1))
    tag=$(basename "$f" .json)
    proto=$(meta_get "$tag" proto)
    display=$(proto_meta_display "$proto")
    port=$(jq -r '.listen_port' "$f" 2>/dev/null || echo '-')
    domain=$(jq -r '.tls.server_name // .handshake.server // "-"' "$f" 2>/dev/null || echo '-')
    printf '%-4s %-28s %-24s %-8s %s\n' "$i" "$tag" "${display:-未知}" "$port" "$domain"
  done
  shopt -u nullglob
  if [ "$i" -eq 0 ]; then
    warn "暂无节点"
  fi
  return 0
}

select_node() {
  local -a tags=()
  local f choice idx
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tags+=("$(basename "$f" .json)")
  done
  shopt -u nullglob
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无节点"
    SELECTED=""
    return 1
  fi
  list_nodes_table
  ask choice "请输入序号" ""
  if ! [[ $choice =~ ^[0-9]+$ ]]; then
    error "序号无效"
    return 1
  fi
  choice=$((10#$choice))
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#tags[@]} ]; then
    error "序号无效"
    return 1
  fi
  SELECTED=${tags[$idx]}
  return 0
}

save_node() {
  local tag=$1 proto=$2 json=$3 pbk=${4:-} insecure=${5:-0}
  if ! printf '%s\n' "$json" | jq . > "$NODE_DIR/$tag.json"; then
    error "写入节点配置失败"
    return 1
  fi
  chmod 600 "$NODE_DIR/$tag.json"
  {
    printf 'proto=%s\n' "$proto"
    printf 'pbk=%s\n' "$pbk"
    printf 'insecure=%s\n' "$insecure"
    printf 'created=%s\n' "$(date '+%F %T')"
  } > "$NODE_DIR/$tag.meta"
  chmod 600 "$NODE_DIR/$tag.meta"
  CREATED_TAGS+=("$tag")
  info "节点 [$tag] 已保存"
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    return 0
  fi
  apply_changes
}

# ================================================================
#  证书处理
# ================================================================
generate_selfsigned_cert() {
  local domain=$1 base=$2 crt key cnf
  crt="$CERT_DIR/$base.crt"
  key="$CERT_DIR/$base.key"
  cnf="$CERT_DIR/$base.cnf"
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
  if openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -sha256 \
    -keyout "$key" -out "$crt" -config "$cnf" >/dev/null 2>&1; then
    touch "$CERT_DIR/$base.selfsigned"
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$crt" 2>/dev/null || true
    CERT_FILE=$crt
    KEY_FILE=$key
    CERT_INSECURE=1
    return 0
  fi
  error "自签证书生成失败"
  return 1
}

load_active_cert() {
  local ref="$CERT_DIR/.active_cert" base crt key
  [ -s "$ref" ] || return 1
  base=$(head -n1 "$ref" 2>/dev/null || true)
  [ -n "$base" ] || return 1
  case "$base" in */*|..*) return 1 ;; esac
  crt="$CERT_DIR/$base.crt"
  key="$CERT_DIR/$base.key"
  [ -s "$crt" ] && [ -s "$key" ] || return 1
  CERT_FILE=$crt
  KEY_FILE=$key
  if [ -f "$CERT_DIR/$base.selfsigned" ]; then
    CERT_INSECURE=1
  else
    CERT_INSECURE=0
  fi
  return 0
}

ensure_cert() {
  local ref="$CERT_DIR/.active_cert" domain=$1 base crt key
  if load_active_cert; then
    return 0
  fi
  while true; do
    base="cert-$(gen_hex 8)"
    crt="$CERT_DIR/$base.crt"
    key="$CERT_DIR/$base.key"
    [ ! -e "$crt" ] && [ ! -e "$key" ] && break
  done
  generate_selfsigned_cert "$domain" "$base" || return 1
  if ! printf '%s\n' "$base" > "$ref"; then
    error "写入证书索引失败: $ref"
    return 1
  fi
  chmod 600 "$ref" 2>/dev/null || true
  return 0
}

prompt_domain_cert() {
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    if [ -z "${BATCH_DOMAIN:-}" ]; then
      error "批量创建缺少伪装域名"
      return 1
    fi
    DOMAIN_VAL=$BATCH_DOMAIN
    ensure_cert "$DOMAIN_VAL"
    return $?
  fi
  local def=${1:-} d
  while true; do
    ask d "域名 (用于证书与 SNI)" "$def"
    if [ -z "$d" ]; then
      warn "域名不能为空"
      continue
    fi
    if ! [[ $d =~ ^[A-Za-z0-9.*_-]+$ ]]; then
      warn "域名格式不正确"
      def=""
      continue
    fi
    DOMAIN_VAL=$d
    break
  done
  ensure_cert "$DOMAIN_VAL"
}

tls_cert_json() {
  local domain=$1
  shift
  local alpn
  if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ]; then
    ensure_cert "$domain" || return 1
  fi
  alpn=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq -n --arg sni "$domain" --arg crt "$CERT_FILE" --arg key "$KEY_FILE" --argjson alpn "$alpn" \
    '{enabled:true,server_name:$sni,alpn:$alpn,certificate_path:$crt,key_path:$key}'
}


# ================================================================
#  VLESS 系列
# ================================================================
create_vless_reality() {
  local edit=${1:-} tag port uuid sni sid hsport priv pub kp json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    sni=$(n_get "$tag" '.tls.server_name' 'www.microsoft.com')
    sid=$(n_get "$tag" '.tls.reality.short_id[0]')
    hsport=$(n_get "$tag" '.tls.reality.handshake.server_port' 443)
    priv=$(n_get "$tag" '.tls.reality.private_key')
    pub=$(meta_get "$tag" pbk)
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-reality-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    sni="${BATCH_REALITY_SNI:-www.microsoft.com}"
    sid=$(gen_hex 4)
    hsport="${BATCH_REALITY_HSPORT:-443}"
    info "正在生成 REALITY 密钥对 ..."
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  ask sni "REALITY 伪装域名" "$sni"
  ask hsport "REALITY 回源端口 (伪装站点端口)" "$hsport"
  if ! [[ $hsport =~ ^[0-9]+$ ]] || [ "$hsport" -lt 1 ] || [ "$hsport" -gt 65535 ]; then
    warn "回源端口无效，已使用 443"
    hsport=443
  fi
  hsport=$((10#$hsport))
  [ "$hsport" = "443" ] || warn "非 443 回源端口需要伪装站点在该端口提供 TLS"
  [ -n "$sid" ] || sid=$(gen_hex 4)
  ask sid "Short ID (十六进制)" "$sid"
  if [ -n "$edit" ] && confirm "是否重新生成 REALITY 密钥对?" "n"; then
    kp=$(gen_reality_keypair)
    priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
  fi
  if [ -z "$uuid" ] || [ -z "$sni" ] || [ -z "$sid" ] || [ -z "$priv" ] || [ -z "$pub" ]; then
    error "REALITY 参数不完整，已取消保存"
    return 1
  fi
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" \
    --argjson hsport "$hsport" '
    {type:"vless",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid,flow:"xtls-rprx-vision"}],
     tls:{enabled:true,server_name:$sni,
          reality:{enabled:true,handshake:{server:$sni,server_port:$hsport},
                   private_key:$priv,short_id:[$sid]}}}')
  save_node "$tag" "vless-reality-vision" "$json" "$pub" 0
}

create_vless_ws() {
  local edit=${1:-} tag port uuid domain path tls transport json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    domain=$(n_get "$tag" '.tls.server_name')
    path=$(n_get "$tag" '.transport.path' '/ws')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vless-ws-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    domain=""
    path="/ws-$(gen_hex 2)"
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask path "WebSocket 路径" "$path"
  [[ $path == /* ]] || path="/$path"
  if [ -z "$uuid" ]; then
    error "UUID 不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h2 http/1.1)
  transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vless",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vless-ws-tls" "$json" "" "$CERT_INSECURE"
}

# ================================================================
#  Hysteria2 / TUIC
# ================================================================
create_hysteria2() {
  local edit=${1:-} tag port password domain masq tls json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    password=$(n_get "$tag" '.users[0].password')
    domain=$(n_get "$tag" '.tls.server_name')
    masq=$(n_get "$tag" '.masquerade' 'https://www.bing.com')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "hysteria2-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port udp)
    password=$(gen_hex 16)
    domain=""
    masq="https://www.bing.com"
  fi
  ask_port "$port" udp
  port=$PORT_VAL
  ask password "认证密码" "$password"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask masq "伪装网站 (留空则不设置)" "$masq"
  if [ -z "$password" ]; then
    error "密码不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h3)
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" --arg masq "$masq" '
    ({type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,
      users:[{name:"user",password:$password}],
      tls:$tls}
     + (if $masq != "" then {masquerade:$masq} else {} end))')
  save_node "$tag" "hysteria2-quic" "$json" "" "$CERT_INSECURE"
}

create_tuic() {
  local edit=${1:-} tag port uuid password domain cc tls json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    uuid=$(n_get "$tag" '.users[0].uuid')
    password=$(n_get "$tag" '.users[0].password')
    domain=$(n_get "$tag" '.tls.server_name')
    cc=$(n_get "$tag" '.congestion_control' 'bbr')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "tuic-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port udp)
    uuid=$(gen_uuid)
    password=$(gen_hex 16)
    domain=""
    cc="bbr"
  fi
  ask_port "$port" udp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  ask password "密码" "$password"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask cc "拥塞控制 (bbr/cubic/new_reno)" "$cc"
  case "$cc" in
    bbr|cubic|new_reno) ;;
    *) warn "未知拥塞控制算法，已改用 bbr"; cc="bbr" ;;
  esac
  if [ -z "$uuid" ] || [ -z "$password" ]; then
    error "UUID 或密码不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h3)
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" --arg cc "$cc" '
    {type:"tuic",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid,password:$password}],
     congestion_control:$cc,tls:$tls}')
  save_node "$tag" "tuic-quic" "$json" "" "$CERT_INSECURE"
}


# ================================================================
#  Shadowsocks 系列
# ================================================================
valid_ss2022_key() {
  local bytes=$1 key=$2 len
  len=$(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c | tr -d ' ' || true)
  [ "$len" = "$bytes" ]
}

create_ss2022() {
  local edit=${1:-} tag port method password bytes choice json
  bytes=32
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 8388)
    method=$(n_get "$tag" '.method' '2022-blake3-aes-256-gcm')
    password=$(n_get "$tag" '.password')
    case "$method" in
      2022-blake3-aes-128-gcm) bytes=16 ;;
      *) method="2022-blake3-aes-256-gcm"; bytes=32 ;;
    esac
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "ss2022-$(gen_hex 2)"
    tag=$TAG_VAL
    if port_in_use 8388 tcp; then
      port=$(suggest_port tcp)
    else
      port=8388
    fi
    method=""
    password=""
  fi

  ask_port "$port" tcp
  port=$PORT_VAL

  if [ -z "$method" ]; then
    printf '  1) 2022-128 (16 字节密钥)\n  2) 2022-256 (32 字节密钥，推荐)\n'
    ask choice "Shadowsocks-2022 密钥长度" "2"
    case "$choice" in
      1) method="2022-blake3-aes-128-gcm"; bytes=16 ;;
      *) method="2022-blake3-aes-256-gcm"; bytes=32 ;;
    esac
  fi

  [ -n "$password" ] || password=$(gen_b64 "$bytes")
  while true; do
    ask password "密码 (Base64 编码的 ${bytes} 字节密钥)" "$password"
    if valid_ss2022_key "$bytes" "$password"; then
      break
    fi
    warn "密钥无效，必须是 ${bytes} 字节的 Base64 编码"
    password=$(gen_b64 "$bytes")
    warn "已重新生成合法密钥作为默认值，请直接回车使用"
  done

  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg method "$method" --arg password "$password" '
    {type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,
     method:$method,password:$password}')
  save_node "$tag" "shadowsocks-2022" "$json" "" 0
}

# ================================================================
#  Trojan / VMess
# ================================================================
create_trojan() {
  local kind=$1 edit=${2:-} tag port password domain tls transport proto prefix path json
  case "$kind" in
    tcp) prefix="trojan";    proto="trojan-tls" ;;
    ws)  prefix="trojan-ws"; proto="trojan-ws-tls" ;;
    *)
      error "未知 Trojan 类型"
      return 1
      ;;
  esac

  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    password=$(n_get "$tag" '.users[0].password')
    domain=$(n_get "$tag" '.tls.server_name')
    path=$(n_get "$tag" '.transport.path' '/ws')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "${prefix}-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    password=$(gen_hex 16)
    domain=""
    path="/ws-$(gen_hex 2)"
  fi

  ask_port "$port" tcp
  port=$PORT_VAL
  ask password "Trojan 密码" "$password"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL

  transport=""
  if [ "$kind" = "ws" ]; then
    ask path "WebSocket 路径" "$path"
    [[ $path == /* ]] || path="/$path"
    transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  fi

  if [ -z "$password" ]; then
    error "Trojan 密码不能为空"
    return 1
  fi

  tls=$(tls_cert_json "$domain" h2 http/1.1)
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"trojan",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  if [ -n "$transport" ]; then
    json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  fi
  save_node "$tag" "$proto" "$json" "" "$CERT_INSECURE"
}

create_vmess() {
  local edit=${1:-} tag port uuid domain path tls transport json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 10086)
    uuid=$(n_get "$tag" '.users[0].uuid')
    domain=$(n_get "$tag" '.tls.server_name')
    path=$(n_get "$tag" '.transport.path' '/ws')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "vmess-ws-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    uuid=$(gen_uuid)
    domain=""
    path="/ws-$(gen_hex 2)"
  fi

  ask_port "$port" tcp
  port=$PORT_VAL
  ask uuid "UUID" "$uuid"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  ask path "WebSocket 路径" "$path"
  [[ $path == /* ]] || path="/$path"

  if [ -z "$uuid" ]; then
    error "UUID 不能为空"
    return 1
  fi

  tls=$(tls_cert_json "$domain" h2 http/1.1)
  transport=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"vmess",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",uuid:$uuid}],tls:$tls,transport:$transport}')
  save_node "$tag" "vmess-ws-tls" "$json" "" "$CERT_INSECURE"
}

# ================================================================
#  AnyTLS / SOCKS5
# ================================================================
create_anytls() {
  local edit=${1:-} tag port password domain tls json
  if ! core_supports_anytls; then
    error "AnyTLS 需要 sing-box 1.12.0 或更高版本，请先在“核心管理”中更新核心"
    return 1
  fi
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 443)
    password=$(n_get "$tag" '.users[0].password')
    domain=$(n_get "$tag" '.tls.server_name')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "anytls-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    password=$(gen_hex 16)
    domain=""
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask password "AnyTLS 密码" "$password"
  prompt_domain_cert "$domain" || return 1
  domain=$DOMAIN_VAL
  if [ -z "$password" ]; then
    error "密码不能为空"
    return 1
  fi
  tls=$(tls_cert_json "$domain" h2 http/1.1)
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"anytls",tag:$tag,listen:$listen,listen_port:$port,
     users:[{name:"user",password:$password}],tls:$tls}')
  save_node "$tag" "anytls-tls" "$json" "" "$CERT_INSECURE"
}

create_socks5() {
  local edit=${1:-} tag port username password json
  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 1080)
    username=$(n_get "$tag" '.users[0].username' 'user')
    password=$(n_get "$tag" '.users[0].password')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "socks5-$(gen_hex 2)"
    tag=$TAG_VAL
    if port_in_use 1080 tcp; then
      port=$(suggest_port tcp)
    else
      port=1080
    fi
    username="user"
    password=$(gen_hex 8)
  fi
  ask_port "$port" tcp
  port=$PORT_VAL
  ask username "用户名" "$username"
  ask password "密码" "$password"
  if [ -z "$username" ] || [ -z "$password" ]; then
    error "用户名或密码不能为空"
    return 1
  fi
  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg username "$username" --arg password "$password" '
    {type:"socks",tag:$tag,listen:$listen,listen_port:$port,
     users:[{username:$username,password:$password}]}')
  save_node "$tag" "socks5" "$json" "" 0
}


# ================================================================
#  Snell
# ================================================================
create_snell() {
  local edit=${1:-} tag port psk mode choice len json
  if ! core_supports_snell; then
    error "Snell v6 需要 sing-box 1.14.0 或更高版本，请先在“核心管理”中更新核心"
    return 1
  fi

  if [ -n "$edit" ]; then
    tag=$edit
    port=$(n_get "$tag" '.listen_port' 6160)
    psk=$(n_get "$tag" '.psk')
    mode=$(n_get "$tag" '.mode' 'default')
    info "编辑节点 [$tag]，直接回车保留原值"
  else
    prompt_tag "snell-v6-$(gen_hex 2)"
    tag=$TAG_VAL
    port=$(suggest_port tcp)
    psk=$(gen_hex 16)
    mode="default"
  fi

  ask_port "$port" tcp
  port=$PORT_VAL

  while true; do
    ask psk "PSK (12-255 字节)" "$psk"
    len=$(printf '%s' "$psk" | wc -c | tr -d ' ')
    if [ "$len" -ge 12 ] && [ "$len" -le 255 ]; then
      break
    fi
    warn "PSK 长度必须是 12-255 字节"
    psk=$(gen_hex 16)
    warn "已生成新的随机 PSK，请直接回车使用"
  done

  case "$mode" in
    unshaped)   choice="2" ;;
    unsafe-raw) choice="3" ;;
    *)          choice="1" ;;
  esac
  printf '  1) default\n  2) unshaped\n  3) unsafe-raw\n'
  ask choice "Snell 模式" "$choice"
  case "$choice" in
    2) mode="unshaped" ;;
    3) mode="unsafe-raw" ;;
    *) mode="default" ;;
  esac

  json=$(jq -n --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" \
    --arg psk "$psk" --arg mode "$mode" '
    {type:"snell",tag:$tag,listen:$listen,listen_port:$port,
     version:6,psk:$psk,mode:$mode}')
  save_node "$tag" "snell-v6" "$json" "" 0
}

# ================================================================
#  节点查看 / 分享链接
# ================================================================
print_node_link() {
  local tag=$1 proto ip port f obj domain uuid pass method path pbk sid insecure
  local link userinfo payload tlsq tagurl psk mode client
  proto=$(meta_get "$tag" proto)
  ip=$(get_server_ip)
  insecure=$(meta_get "$tag" insecure)
  f="$NODE_DIR/$tag.json"
  if [ ! -s "$f" ]; then
    error "节点文件不存在: $f"
    return 1
  fi
  if [ -z "$ip" ]; then
    warn "未能获取公网 IP，请手动替换链接中的服务器地址"
  fi

  obj=$(jq -c . "$f")
  port=$(jq -r '.listen_port // empty' <<<"$obj")
  domain=$(jq -r '.tls.server_name // empty' <<<"$obj")
  uuid=$(jq -r '.users[0].uuid // empty' <<<"$obj")
  pass=$(jq -r '.users[0].password // .password // empty' <<<"$obj")
  method=$(jq -r '.method // empty' <<<"$obj")
  path=$(jq -r '.transport.path // empty' <<<"$obj")
  pbk=$(meta_get "$tag" pbk)
  sid=$(jq -r '.tls.reality.short_id[0] // empty' <<<"$obj")
  tagurl=$(urlenc "$tag")

  if [ "$proto" = "snell-v6" ]; then
    psk=$(jq -r '.psk // empty' <<<"$obj")
    mode=$(jq -r '.mode // "default"' <<<"$obj")
    client=$(jq -n --arg tag "$tag" --arg ip "$ip" --argjson port "$port" \
      --arg psk "$psk" '
      {type:"snell",tag:$tag,server:$ip,server_port:$port,
       version:6,psk:$psk,reuse:true}')
    info "Snell 没有通用分享链接，请使用以下 Surge 配置或 sing-box 出站配置："
    if [ "$mode" = "default" ]; then
      printf '%s = snell, %s, %s, psk=%s, version=6, reuse=true\n' \
        "$tag" "$ip" "$port" "$psk"
    else
      printf '%s = snell, %s, %s, psk=%s, version=6, mode=%s, reuse=true\n' \
        "$tag" "$ip" "$port" "$psk" "$mode"
      client=$(jq --arg mode "$mode" '. + {mode:$mode}' <<<"$client")
    fi
    printf '\n'
    printf '%s\n' "$client" | jq .
    return 0
  fi

  tlsq="security=tls&sni=$(urlenc "$domain")"
  if [ "$insecure" = "1" ]; then
    tlsq="$tlsq&allowInsecure=1"
  fi

  case "$proto" in
    vless-reality-vision)
      link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlenc "$domain")&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#${tagurl}"
      ;;
    vless-ws-tls)
      link="vless://${uuid}@${ip}:${port}?encryption=none&${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#${tagurl}"
      ;;
    trojan-tls)
      link="trojan://$(urlenc "$pass")@${ip}:${port}?${tlsq}&type=tcp#${tagurl}"
      ;;
    trojan-ws-tls)
      link="trojan://$(urlenc "$pass")@${ip}:${port}?${tlsq}&type=ws&path=$(urlenc "$path")&host=$(urlenc "$domain")#${tagurl}"
      ;;
    shadowsocks-2022)
      userinfo=$(b64url "$method:$pass")
      link="ss://${userinfo}@${ip}:${port}#${tagurl}"
      ;;
    hysteria2-quic)
      link="hysteria2://$(urlenc "$pass")@${ip}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#${tagurl}"
      ;;
    tuic-quic)
      link="tuic://${uuid}:$(urlenc "$pass")@${ip}:${port}?congestion_control=bbr&alpn=h3&sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&allow_insecure=1"
      link="$link#${tagurl}"
      ;;
    anytls-tls)
      link="anytls://$(urlenc "$pass")@${ip}:${port}/?sni=$(urlenc "$domain")"
      [ "$insecure" = "1" ] && link="$link&insecure=1"
      link="$link#${tagurl}"
      ;;
    socks5)
      userinfo=$(b64url "$(jq -r '.users[0].username // empty' <<<"$obj"):$(jq -r '.users[0].password // empty' <<<"$obj")")
      link="socks://${userinfo}@${ip}:${port}#${tagurl}"
      ;;
    vmess-ws-tls)
      payload=$(jq -cn --arg ps "$tag" --arg add "$ip" --argjson port "$port" \
        --arg id "$uuid" --arg host "$domain" --arg path "$path" --arg sni "$domain" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,scy:"auto",
         net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni}')
      link="vmess://$(printf '%s' "$payload" | base64 | tr -d '\n')"
      ;;
    *)
      warn "该协议暂不生成分享链接，请参考上方 JSON 配置"
      return 0
      ;;
  esac

  printf '%s\n' "$link"
}

print_created_links() {
  local tag display i=0
  [ ${#CREATED_TAGS[@]} -gt 0 ] || return 0
  printf '\n%s\n' "================ 新节点分享链接 ================"
  for tag in "${CREATED_TAGS[@]}"; do
    [ -f "$NODE_DIR/$tag.json" ] || continue
    i=$((i + 1))
    display=$(proto_meta_display "$(meta_get "$tag" proto)")
    printf '\n[%s] %s  (%s)\n' "$i" "$tag" "$display"
    printf '%s\n' "--------------------------------------------------"
    print_node_link "$tag"
  done
  [ "$i" -gt 0 ] && printf '\n共 %s 个新节点\n' "$i"
}

show_node_details() {
  local tag=$1 proto
  proto=$(meta_get "$tag" proto)
  printf '%s\n' "=============================================="
  printf '节点名称 : %s\n' "$tag"
  printf '协议类型 : %s\n' "$(proto_meta_display "$proto")"
  printf '配置路径 : %s\n' "$NODE_DIR/$tag.json"
  printf '%s\n' "=============================================="
  jq . "$NODE_DIR/$tag.json"
  printf '\n%s\n' "---------- 分享链接 / 客户端配置 ----------"
  print_node_link "$tag"
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
  local f tag proto display count=0 i=0
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点，请先新增节点"
    pause
    return 0
  fi
  printf '%s\n' "================ 所有节点分享链接 ================"
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tag=$(basename "$f" .json)
    proto=$(meta_get "$tag" proto)
    display=$(proto_meta_display "$proto")
    i=$((i + 1))
    printf '\n[%s] %s  (%s)\n' "$i" "$tag" "$display"
    printf '%s\n' "--------------------------------------------------"
    print_node_link "$tag"
    count=$((count + 1))
  done
  shopt -u nullglob
  printf '\n共 %s 个节点\n' "$count"
  pause
}

delete_node() {
  local tag
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  tag=$SELECTED
  warn "即将删除节点 [$tag]，此操作不可恢复"
  if ! confirm "确定删除该节点?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  rm -f "$NODE_DIR/$tag.json" "$NODE_DIR/$tag.meta" "$SB_DIR/routes/$tag.outbound"
  info "节点 [$tag] 已删除"
  apply_changes
  pause
}

edit_node() {
  local tag proto
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  select_node || { pause; return 0; }
  tag=$SELECTED
  proto=$(meta_get "$tag" proto)
  warn "编辑会覆盖节点 [$tag] 的现有配置"
  if ! confirm "继续编辑?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  EXCLUDE_TAG="$tag"
  case "$proto" in
    vless-reality-vision)  create_vless_reality "$tag" ;;
    vless-ws-tls)          create_vless_ws "$tag" ;;
    hysteria2-quic)        create_hysteria2 "$tag" ;;
    tuic-quic)             create_tuic "$tag" ;;
    trojan-tls)            create_trojan tcp "$tag" ;;
    trojan-ws-tls)         create_trojan ws "$tag" ;;
    anytls-tls)            create_anytls "$tag" ;;
    shadowsocks-2022)      create_ss2022 "$tag" ;;
    vmess-ws-tls)          create_vmess "$tag" ;;
    snell-v6)              create_snell "$tag" ;;
    socks5)                create_socks5 "$tag" ;;
    *)
      warn "未知协议类型: ${proto:-空}，无法编辑"
      pause
      ;;
  esac
  EXCLUDE_TAG=""
  pause
}

# ================================================================
#  节点菜单
# ================================================================
print_protocol_menu() {
  printf '%2d) %-22s %2d) %s\n' 1 'VLESS-Reality-Vision' 2 'VLESS-WS-TLS'
  printf '%2d) %-22s %2d) %s\n' 3 'Hysteria2' 4 'TUIC'
  printf '%2d) %-22s %2d) %s\n' 5 'Trojan-TLS' 6 'Trojan-WS-TLS'
  printf '%2d) %-22s %2d) %s\n' 7 'AnyTLS-TLS' 8 'Shadowsocks-2022'
  printf '%2d) %-22s %2d) %s\n' 9 'VMess-WS-TLS' 10 'Snell-v6'
  printf '%2d) %s\n' 11 'SOCKS5'
  printf '%2d) 返回\n' 0
}

protocol_display_name() {
  case "${1:-}" in
    1)  printf 'VLESS-Reality-Vision' ;;
    2)  printf 'VLESS-WS-TLS' ;;
    3)  printf 'Hysteria2' ;;
    4)  printf 'TUIC' ;;
    5)  printf 'Trojan-TLS' ;;
    6)  printf 'Trojan-WS-TLS' ;;
    7)  printf 'AnyTLS-TLS' ;;
    8)  printf 'Shadowsocks-2022' ;;
    9)  printf 'VMess-WS-TLS' ;;
    10) printf 'Snell-v6' ;;
    11) printf 'SOCKS5' ;;
    *)  printf 'NODE' ;;
  esac
}

# 左侧为节点 .meta 中保存的内部协议 ID，右侧为界面显示名称。
proto_meta_display() {
  case "${1:-}" in
    vless-reality-vision)   printf 'VLESS-Reality-Vision' ;;
    vless-ws-tls)           printf 'VLESS-WS-TLS' ;;
    hysteria2-quic)         printf 'Hysteria2' ;;
    tuic-quic)              printf 'TUIC' ;;
    trojan-tls)             printf 'Trojan-TLS' ;;
    trojan-ws-tls)          printf 'Trojan-WS-TLS' ;;
    anytls-tls)             printf 'AnyTLS-TLS' ;;
    shadowsocks-2022)       printf 'Shadowsocks-2022' ;;
    vmess-ws-tls)           printf 'VMess-WS-TLS' ;;
    snell-v6)               printf 'Snell-v6' ;;
    socks5)                 printf 'SOCKS5' ;;
    *)                      printf '%s' "${1:-未知}" ;;
  esac
}

protocol_needs_cert() {
  case "${1:-}" in
    2|3|4|5|6|7|9) return 0 ;;
    *) return 1 ;;
  esac
}

create_node_by_choice() {
  local choice=${1:-} loc name
  case "$choice" in
    1|2|3|4|5|6|7|8|9|10|11) ;;
    0) return 0 ;;
    *) warn "无效选项"; return 1 ;;
  esac

  if [ "${BATCH_MODE:-0}" != "1" ]; then
    name=$(protocol_display_name "$choice")
    info "正在获取服务器国家码 ..."
    loc=$(get_server_country_code)
    info "服务器国家码: $loc"
    AUTO_TAG_DEFAULT=$(make_batch_tag "$loc" "$name")
  fi

  case "$choice" in
    1)  create_vless_reality ;;
    2)  create_vless_ws ;;
    3)  create_hysteria2 ;;
    4)  create_tuic ;;
    5)  create_trojan tcp ;;
    6)  create_trojan ws ;;
    7)  create_anytls ;;
    8)  create_ss2022 ;;
    9)  create_vmess ;;
    10) create_snell ;;
    11) create_socks5 ;;
  esac
}

parse_protocol_choices() {
  PROTOCOL_PICKS=()
  PROTOCOL_INVALID=""
  local raw token p dup add=0
  raw=$(printf '%s' "${1:-}" | tr ',' ' ' | tr '\n\t' '  ')
  raw=${raw//，/ }
  raw=${raw//、/ }
  for token in $raw; do
    case "$token" in
      0) return 1 ;;
    esac
    if ! [[ $token =~ ^[0-9]+$ ]]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    token=${token#"${token%%[!0]*}"}
    if [ -z "$token" ]; then
      return 1
    fi
    if [ "${#token}" -gt 2 ]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    if [ "$token" -lt 1 ] || [ "$token" -gt 11 ]; then
      PROTOCOL_INVALID+=" $token"
      continue
    fi
    dup=0
    if [ ${#PROTOCOL_PICKS[@]} -gt 0 ]; then
      for p in "${PROTOCOL_PICKS[@]}"; do
        if [ "$p" = "$token" ]; then
          dup=1
          break
        fi
      done
    fi
    if [ "$dup" -eq 0 ]; then
      PROTOCOL_PICKS+=("$token")
      add=1
    fi
  done
  if [ "$add" -eq 1 ]; then
    return 0
  fi
  return 2
}

make_batch_tag() {
  local loc=$1 name=$2 base t n=2
  base="${loc}-${name}"
  t=$base
  while [ -e "$NODE_DIR/$t.json" ] || [ -e "$OUT_DIR/$t.json" ]; do
    t="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$t"
}

batch_create_nodes() {
  local p need_cert=0 need_domain=0 has_reality=0 ok=0 fail=0 loc name detected
  local idx=0 transport v
  local -a picks=()
  CREATED_TAGS=()

  if [ "$#" -gt 0 ]; then
    picks=("$@")
  elif [ ${#PROTOCOL_PICKS[@]} -gt 0 ]; then
    picks=("${PROTOCOL_PICKS[@]}")
  else
    warn "未选择有效协议"
    return 1
  fi

  printf '%s\n' "------------- 批量新增节点 -------------"
  info "共选择 ${#picks[@]} 个协议: ${picks[*]}"
  info "正在获取服务器国家码 ..."
  detected=$(get_server_country_code)
  info "服务器国家码: $detected"
  ask loc "节点名称前缀（两位国家码，如 JP/US/SG）" "$detected"
  loc=$(normalize_country_code "$loc")
  if [ "$loc" = "XX" ]; then
    warn "国家码格式不正确，使用检测结果: $detected"
    loc=$detected
  fi

  for p in "${picks[@]}"; do
    if protocol_needs_cert "$p"; then
      need_cert=1
      need_domain=1
    fi
    if [ "$p" = "1" ]; then
      has_reality=1
      need_domain=1
    fi
  done

  BATCH_DOMAIN=""
  if [ "$need_domain" -eq 1 ]; then
    if [ "$need_cert" -eq 1 ] && [ "$has_reality" -eq 1 ]; then
      info "所选 TLS 节点和 REALITY 节点将共用同一伪装域名"
    elif [ "$need_cert" -eq 1 ]; then
      info "所选 TLS 节点将共用同一伪装域名"
    else
      info "REALITY 节点将使用该域名作为伪装域名"
    fi
    while [ -z "$BATCH_DOMAIN" ]; do
      ask BATCH_DOMAIN "伪装域名" ""
      if [ -z "$BATCH_DOMAIN" ]; then
        warn "伪装域名不能为空"
        continue
      fi
      if ! [[ $BATCH_DOMAIN =~ ^[A-Za-z0-9.*_-]+$ ]]; then
        warn "域名格式不正确"
        BATCH_DOMAIN=""
      fi
    done
  fi

  BATCH_PORT_LIST=()
  BATCH_PORT_TYPES=()
  info "请为每个协议单独设置监听端口，直接回车使用随机监听端口"
  idx=0
  for p in "${picks[@]}"; do
    name=$(protocol_display_name "$p")
    case "$p" in
      3|4) transport="udp" ;;
      *)   transport="tcp" ;;
    esac
    while true; do
      ask v "[$((idx + 1))/${#picks[@]}] $name 监听端口（回车随机）" ""
      if [ -z "$v" ]; then
        v=$(random_free_port "$transport")
        printf '\n'
        info "  -> $name 使用随机监听端口: $v/$transport"
        break
      fi
      if ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
        warn "监听端口范围 1-65535"
        continue
      fi
      v=$((10#$v))
      if ! port_available "$v" "$transport"; then
        warn "监听端口 $v 已被同类型节点或系统服务占用，请更换"
        continue
      fi
      if port_in_batch "$v" "$transport"; then
        warn "监听端口 $v 已在本批次中使用，请更换"
        continue
      fi
      break
    done
    BATCH_PORT_LIST+=("$v")
    BATCH_PORT_TYPES+=("$transport")
    idx=$((idx + 1))
  done

  BATCH_REALITY_SNI=""
  BATCH_REALITY_HSPORT=""
  if [ "$has_reality" -eq 1 ]; then
    BATCH_REALITY_SNI=$BATCH_DOMAIN
    BATCH_REALITY_HSPORT=443
    while true; do
      ask BATCH_REALITY_HSPORT "REALITY 回源端口 (伪装站点端口)" "443"
      printf '\n'
      if [[ $BATCH_REALITY_HSPORT =~ ^[0-9]+$ ]] && \
         [ "$BATCH_REALITY_HSPORT" -ge 1 ] && [ "$BATCH_REALITY_HSPORT" -le 65535 ]; then
        BATCH_REALITY_HSPORT=$((10#$BATCH_REALITY_HSPORT))
        break
      fi
      warn "回源端口无效，请输入 1-65535"
    done
    info "REALITY 回源端口: $BATCH_REALITY_HSPORT"
  fi

  info "UUID、密码、PSK 和传输路径将自动生成，监听端口使用上面的设置"
  BATCH_MODE=1
  idx=0
  for p in "${picks[@]}"; do
    name=$(protocol_display_name "$p")
    BATCH_TAG=$(make_batch_tag "$loc" "$name")
    BATCH_PORT=${BATCH_PORT_LIST[$idx]}
    printf '>>> 创建节点: %s (监听端口 %s/%s)\n' "$BATCH_TAG" "$BATCH_PORT" "${BATCH_PORT_TYPES[$idx]}"
    if create_node_by_choice "$p"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      warn "协议 [$name] 创建失败"
    fi
    BATCH_PORT=""
    idx=$((idx + 1))
  done
  BATCH_MODE=0
  BATCH_TAG=""
  BATCH_DOMAIN=""
  BATCH_REALITY_SNI=""
  BATCH_REALITY_HSPORT=""
  BATCH_PORT=""
  BATCH_PORT_LIST=()
  BATCH_PORT_TYPES=()

  if [ "$ok" -gt 0 ]; then
    info "批量创建完成: 成功 $ok 个，失败 $fail 个"
    apply_changes
  else
    error "没有节点创建成功"
  fi
}

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
  if [ -n "$PROTOCOL_INVALID" ]; then
    warn "已忽略无效编号:${PROTOCOL_INVALID}"
  fi
  if [ ${#PROTOCOL_PICKS[@]} -eq 1 ]; then
    create_node_by_choice "${PROTOCOL_PICKS[0]}"
  else
    batch_create_nodes "${PROTOCOL_PICKS[@]}"
  fi
  print_created_links
  CREATED_TAGS=()
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

# ================================================================
#  出站管理
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
    *)           printf '%s' "${1:-未知}" ;;
  esac
}

prompt_out_tag() {
  local def=$1 v
  while true; do
    ask v "出站名称" "$def"
    if ! [[ $v =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "仅支持字母、数字、点、下划线、短横线"
      continue
    fi
    if [ "$v" = "direct" ]; then
      warn "direct 是保留名称"
      continue
    fi
    if [ -e "$NODE_DIR/$v.json" ]; then
      warn "该名称与节点名称冲突"
      continue
    fi
    if [ -e "$OUT_DIR/$v.json" ]; then
      warn "出站 $v 已存在"
      continue
    fi
    OUT_TAG=$v
    return 0
  done
}

prompt_server() {
  local def=${1:-} s
  while true; do
    ask s "服务器地址 (IP/域名)" "$def"
    if [ -z "$s" ]; then
      warn "服务器地址不能为空"
      continue
    fi
    SERVER_VAL=$s
    return 0
  done
}

ask_rport() {
  local def=${1:-443} v
  while true; do
    ask v "服务器端口" "$def"
    if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ]; then
      RPORT=$((10#$v))
      return 0
    fi
    warn "服务器端口范围 1-65535"
  done
}

client_tls_json() {
  local sni=$1 insecure=$2 pub=${3:-} sid=${4:-} bool="false" tls
  [ "$insecure" = "1" ] && bool="true"
  tls=$(jq -n --arg sni "$sni" --argjson insecure "$bool" '
    {enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},insecure:$insecure}')
  if [ -n "$pub" ]; then
    tls=$(jq --arg pub "$pub" --arg sid "$sid" '. + {reality:{enabled:true,public_key:$pub,short_id:$sid}}' <<<"$tls")
  fi
  printf '%s' "$tls"
}

ask_out_transport() {
  local c path svc
  printf '  1) TCP\n  2) WebSocket\n  3) gRPC\n'
  ask c "传输方式" "1"
  OUT_PATH=""
  OUT_SVC=""
  case "$c" in
    2)
      ask path "WebSocket 路径" "/ws"
      [[ $path == /* ]] || path="/$path"
      OUT_PATH=$path
      OUT_TRANSPORT_JSON=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
      ;;
    3)
      ask svc "gRPC 服务名" "grpc"
      OUT_SVC=$svc
      OUT_TRANSPORT_JSON=$(jq -n --arg s "$svc" '{type:"grpc",service_name:$s}')
      ;;
    *)
      OUT_TRANSPORT_JSON=""
      ;;
  esac
}

save_outbound() {
  local tag=$1 json=$2
  if ! printf '%s\n' "$json" | jq . > "$OUT_DIR/$tag.json"; then
    error "出站配置写入失败"
    return 1
  fi
  chmod 600 "$OUT_DIR/$tag.json"
  info "出站 [$tag] 已保存"
  return 0
}

finish_outbound() {
  local tag=$1 final
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  if [ "$final" != "$tag" ]; then
    if confirm "是否将 [$tag] 设为默认出站?" "n"; then
      printf '%s\n' "$tag" > "$FINAL_FILE"
      info "默认出站已设为 [$tag]"
    fi
  fi
  apply_changes
}


# ================================================================
#  出站协议创建: SOCKS5 / HTTP / Shadowsocks / VMess / VLESS / Trojan / Hysteria2 / TUIC / Snell
# ================================================================
create_out_socks() {
  local mode=$1 prefix type tag server user pass port json
  if [ "$mode" = "http" ]; then
    prefix="http-out"
    type="http"
  else
    prefix="socks-out"
    type="socks"
  fi
  prompt_out_tag "${prefix}-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 1080
  port=$RPORT
  ask user "用户名 (留空则无认证)" ""
  pass=""
  if [ -n "$user" ]; then
    ask pass "密码" ""
  fi
  if [ "$type" = "socks" ]; then
    json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" '
      {type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}')
  else
    json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" '
      {type:"http",tag:$tag,server:$server,server_port:$port}')
  fi
  if [ -n "$user" ]; then
    json=$(jq --arg u "$user" --arg p "$pass" '. + {username:$u,password:$p}' <<<"$json")
  fi
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_ss() {
  local tag server port method pass bytes json
  prompt_out_tag "ss-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 8388
  port=$RPORT
  printf '  1) aes-256-gcm\n  2) aes-128-gcm\n  3) chacha20-ietf-poly1305\n'
  printf '  4) 2022-blake3-aes-128-gcm\n  5) 2022-blake3-aes-256-gcm\n'
  local c
  ask c "加密方式" "1"
  bytes=""
  case "$c" in
    2) method="aes-128-gcm" ;;
    3) method="chacha20-ietf-poly1305" ;;
    4) method="2022-blake3-aes-128-gcm"; bytes=16 ;;
    5) method="2022-blake3-aes-256-gcm"; bytes=32 ;;
    *) method="aes-256-gcm" ;;
  esac
  if [ -n "$bytes" ]; then
    pass=$(gen_b64 "$bytes")
    while true; do
      ask pass "密码 (Base64 编码的 ${bytes} 字节密钥)" "$pass"
      if valid_ss2022_key "$bytes" "$pass"; then
        break
      fi
      warn "密钥无效，已重新生成默认值"
      pass=$(gen_b64 "$bytes")
    done
  else
    pass=$(gen_hex 16)
    ask pass "密码" "$pass"
  fi
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg method "$method" --arg pass "$pass" '
    {type:"shadowsocks",tag:$tag,server:$server,server_port:$port,
     method:$method,password:$pass}')
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_vmess() {
  local tag server port uuid sni insecure tls transport json
  prompt_out_tag "vmess-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  uuid=$(gen_uuid)
  ask uuid "UUID" "$uuid"
  sni=""
  insecure=0
  tls=""
  if confirm "是否启用 TLS?" "y"; then
    ask sni "TLS SNI (可直接用服务器地址)" "$server"
    if confirm "是否跳过证书验证? 自签证书选是" "n"; then
      insecure=1
    fi
    tls=$(client_tls_json "$sni" "$insecure")
  fi
  ask_out_transport
  transport=$OUT_TRANSPORT_JSON
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg uuid "$uuid" '
    {type:"vmess",tag:$tag,server:$server,server_port:$port,
     uuid:$uuid,security:"auto"}')
  [ -n "$tls" ] && json=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$json")
  [ -n "$transport" ] && json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_vless() {
  local tag server port uuid security flow sni insecure pub sid tls transport json
  prompt_out_tag "vless-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  uuid=$(gen_uuid)
  ask uuid "UUID" "$uuid"
  printf '  1) 无 TLS\n  2) TLS\n  3) REALITY\n'
  ask security "TLS 模式" "2"
  flow=""
  ask flow "流控 flow (例如 xtls-rprx-vision，可留空)" ""
  tls=""
  if [ "$security" = "3" ]; then
    ask sni "REALITY 伪装域名 (SNI)" "$server"
    ask pub "REALITY 公钥 (pbk)" ""
    ask sid "Short ID (十六进制)" ""
    tls=$(client_tls_json "$sni" 0 "$pub" "$sid")
  elif [ "$security" = "2" ]; then
    ask sni "TLS SNI (可直接用服务器地址)" "$server"
    insecure=0
    if confirm "是否跳过证书验证? 自签证书选是" "n"; then
      insecure=1
    fi
    tls=$(client_tls_json "$sni" "$insecure")
  fi
  ask_out_transport
  transport=$OUT_TRANSPORT_JSON
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg uuid "$uuid" '
    {type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid}')
  if [ -n "$flow" ]; then
    json=$(jq --arg f "$flow" '. + {flow:$f}' <<<"$json")
  fi
  [ -n "$tls" ] && json=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$json")
  [ -n "$transport" ] && json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_trojan() {
  local tag server port password sni insecure tls transport json
  prompt_out_tag "trojan-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  password=$(gen_hex 16)
  ask password "Trojan 密码" "$password"
  ask sni "TLS SNI (可直接用服务器地址)" "$server"
  insecure=0
  if confirm "是否跳过证书验证? 自签证书选是" "n"; then
    insecure=1
  fi
  tls=$(client_tls_json "$sni" "$insecure")
  ask_out_transport
  transport=$OUT_TRANSPORT_JSON
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"trojan",tag:$tag,server:$server,server_port:$port,
     password:$password,tls:$tls}')
  [ -n "$transport" ] && json=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$json")
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_hysteria2() {
  local tag server port password sni insecure bool tls json
  prompt_out_tag "hy2-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  password=$(gen_hex 16)
  ask password "认证密码" "$password"
  ask sni "TLS SNI (可直接用服务器地址)" "$server"
  insecure=0
  if confirm "是否跳过证书验证? 自签证书选是" "n"; then
    insecure=1
  fi
  bool="false"
  [ "$insecure" = "1" ] && bool="true"
  tls=$(jq -n --arg sni "$sni" --argjson insecure "$bool" '
    {enabled:true,server_name:$sni,alpn:["h3"],insecure:$insecure}')
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg password "$password" --argjson tls "$tls" '
    {type:"hysteria2",tag:$tag,server:$server,server_port:$port,
     password:$password,tls:$tls}')
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_tuic() {
  local tag server port uuid password sni insecure cc bool tls json
  prompt_out_tag "tuic-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 443
  port=$RPORT
  uuid=$(gen_uuid)
  ask uuid "UUID" "$uuid"
  password=$(gen_hex 16)
  ask password "密码" "$password"
  ask sni "TLS SNI (可直接用服务器地址)" "$server"
  ask cc "拥塞控制 (bbr/cubic/new_reno)" "bbr"
  case "$cc" in
    bbr|cubic|new_reno) ;;
    *) warn "未知拥塞控制算法，已改用 bbr"; cc="bbr" ;;
  esac
  insecure=0
  if confirm "是否跳过证书验证? 自签证书选是" "n"; then
    insecure=1
  fi
  bool="false"
  [ "$insecure" = "1" ] && bool="true"
  tls=$(jq -n --arg sni "$sni" --argjson insecure "$bool" '
    {enabled:true,server_name:$sni,alpn:["h3"],insecure:$insecure}')
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" --arg cc "$cc" '
    {type:"tuic",tag:$tag,server:$server,server_port:$port,
     uuid:$uuid,password:$password,congestion_control:$cc,tls:$tls}')
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_snell() {
  local tag server port psk mode choice len json
  if ! core_supports_snell; then
    error "Snell v6 需要 sing-box 1.14.0 或更高版本，请先在“核心管理”中更新核心"
    return 1
  fi
  prompt_out_tag "snell-out-$(gen_hex 2)"
  tag=$OUT_TAG
  prompt_server ""
  server=$SERVER_VAL
  ask_rport 6160
  port=$RPORT
  psk=$(gen_hex 16)
  while true; do
    ask psk "PSK (12-255 字节)" "$psk"
    len=$(printf '%s' "$psk" | wc -c | tr -d ' ')
    if [ "$len" -ge 12 ] && [ "$len" -le 255 ]; then
      break
    fi
    warn "PSK 长度必须是 12-255 字节"
    psk=$(gen_hex 16)
    warn "已生成新的随机 PSK，请直接回车使用"
  done
  printf '  1) default\n  2) unshaped\n  3) unsafe-raw\n'
  ask choice "Snell 模式" "1"
  case "$choice" in
    2) mode="unshaped" ;;
    3) mode="unsafe-raw" ;;
    *) mode="default" ;;
  esac
  json=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
    --arg psk "$psk" --arg mode "$mode" '
    {type:"snell",tag:$tag,server:$server,server_port:$port,
     version:6,psk:$psk,reuse:true,mode:$mode}')
  save_outbound "$tag" "$json" || return 1
  finish_outbound "$tag"
}

create_out_custom() {
  local f tag json
  ask f "JSON 文件路径" ""
  f=${f/#\~/$HOME}
  if [ ! -s "$f" ]; then
    error "文件不存在: $f"
    return 1
  fi
  if ! jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' "$f" >/dev/null 2>&1; then
    error "JSON 必须是一个包含 type 和 tag 字段的出站对象"
    return 1
  fi
  tag=$(jq -r '.tag' "$f")
  if ! [[ $tag =~ ^[A-Za-z0-9._-]+$ ]]; then
    error "出站名称含非法字符: $tag"
    return 1
  fi
  if [ "$tag" = "direct" ] || [ -e "$NODE_DIR/$tag.json" ] || [ -e "$OUT_DIR/$tag.json" ]; then
    error "tag [$tag] 已存在或与节点冲突"
    return 1
  fi
  jq . "$f" > "$OUT_DIR/$tag.json" || { error "导入失败"; return 1; }
  chmod 600 "$OUT_DIR/$tag.json"
  info "自定义出站 [$tag] 已导入"
  finish_outbound "$tag"
}


# ================================================================
#  出站查看、选择、删除、编辑与菜单
# ================================================================
# ---------------- 出站查看 / 选择 ----------------
list_outbounds_table() {
  local f final tag type i=0 mark
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  printf '%-4s %-26s %-18s %s\n' "序号" "出站名称" "类型" "备注"
  printf '%s\n' "----------------------------------------------------------------"
  i=$((i+1))
  mark=""
  [ "$final" = "direct" ] && mark="<- 默认"
  printf '%-4s %-26s %-18s %s\n' "$i" "direct" "内置直连" "$mark"
  shopt -s nullglob
  for f in "$OUT_DIR"/*.json; do
    i=$((i+1))
    tag=$(basename "$f" .json)
    type=$(jq -r '.type // "?"' "$f" 2>/dev/null || echo '?')
    type=$(outbound_type_display "$type")
    mark=""
    [ "$final" = "$tag" ] && mark="<- 默认"
    printf '%-4s %-26s %-18s %s\n' "$i" "$tag" "$type" "$mark"
  done
  shopt -u nullglob
}

select_outbound() {
  local -a tags=("direct")
  local f choice idx
  shopt -s nullglob
  for f in "$OUT_DIR"/*.json; do
    tags+=("$(basename "$f" .json)")
  done
  shopt -u nullglob
  list_outbounds_table
  ask choice "请输入序号" ""
  if ! [[ $choice =~ ^[0-9]+$ ]]; then
    error "序号无效"
    return 1
  fi
  choice=$((10#$choice))
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#tags[@]} ]; then
    error "序号无效"
    return 1
  fi
  SELECTED_OUT=${tags[$idx]}
  return 0
}

select_custom_outbound() {
  local -a tags=()
  local f choice idx i=0
  shopt -s nullglob
  for f in "$OUT_DIR"/*.json; do
    tags+=("$(basename "$f" .json)")
  done
  shopt -u nullglob
  if [ ${#tags[@]} -eq 0 ]; then
    error "暂无自定义出站"
    return 1
  fi
  printf '%-4s %-26s %s\n' "序号" "出站名称" "类型"
  printf '%s\n' "----------------------------------------------"
  for f in "${tags[@]}"; do
    i=$((i+1))
    printf '%-4s %-26s %s\n' "$i" "$f" "$(outbound_type_display "$(jq -r '.type // "?"' "$OUT_DIR/$f.json" 2>/dev/null || echo '?')")"
  done
  ask choice "请输入序号" ""
  if ! [[ $choice =~ ^[0-9]+$ ]]; then
    error "序号无效"
    return 1
  fi
  choice=$((10#$choice))
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#tags[@]} ]; then
    error "序号无效"
    return 1
  fi
  SELECTED_OUT=${tags[$idx]}
  return 0
}

view_outbounds() {
  local file final
  select_outbound || { pause; return 0; }
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  printf '%s\n' "=============================================="
  printf '当前默认出站: %s\n' "$final"
  printf '%s\n' "=============================================="
  if [ "$SELECTED_OUT" = "direct" ]; then
    jq -n '{type:"direct",tag:"direct"}'
  else
    file="$OUT_DIR/$SELECTED_OUT.json"
    jq . "$file"
  fi
  pause
}

change_outbound() {
  local final
  select_outbound || { pause; return 0; }
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  if [ "$SELECTED_OUT" = "$final" ]; then
    info "[$final] 已经是默认出站"
    pause
    return 0
  fi
  if ! confirm "确定将默认出站改为 [$SELECTED_OUT] ?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  printf '%s\n' "$SELECTED_OUT" > "$FINAL_FILE"
  info "默认出站已设置为 [$SELECTED_OUT]"
  apply_changes
  pause
}

select_node_protocol() {
  local -a protos=()
  local f tag proto choice p dup count idx i=0
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tag=$(basename "$f" .json)
    proto=$(meta_get "$tag" proto)
    [ -n "$proto" ] || continue
    dup=0
    if [ ${#protos[@]} -gt 0 ]; then
      for p in "${protos[@]}"; do
        if [ "$p" = "$proto" ]; then
          dup=1
        fi
      done
    fi
    if [ "$dup" -eq 0 ]; then
      protos+=("$proto")
    fi
  done
  shopt -u nullglob
  if [ ${#protos[@]} -eq 0 ]; then
    error "暂无节点"
    return 1
  fi

  printf '%-4s %-28s %s\n' "序号" "协议" "节点数"
  printf '%s\n' "----------------------------------------------"
  for p in "${protos[@]}"; do
    i=$((i + 1))
    count=0
    shopt -s nullglob
    for f in "$NODE_DIR"/*.json; do
      tag=$(basename "$f" .json)
      if [ "$(meta_get "$tag" proto)" = "$p" ]; then
        count=$((count + 1))
      fi
    done
    shopt -u nullglob
    printf '%-4s %-28s %s\n' "$i" "$(proto_meta_display "$p")" "$count"
  done
  ask choice "请输入协议序号" ""
  if ! [[ $choice =~ ^[0-9]+$ ]]; then
    error "序号无效"
    return 1
  fi
  choice=$((10#$choice))
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#protos[@]} ]; then
    error "序号无效"
    return 1
  fi
  SELECTED_PROTO=${protos[$idx]}
  return 0
}

assign_node_outbound() {
  local node out
  select_node || { pause; return 0; }
  node=$SELECTED
  select_outbound || { pause; return 0; }
  out=$SELECTED_OUT
  if ! confirm "将节点 [$node] 的出站设置为 [$out] ?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  mkdir -p "$SB_DIR/routes"
  printf '%s\n' "$out" > "$SB_DIR/routes/$node.outbound"
  info "节点 [$node] 已绑定出站 [$out]"
  apply_changes
  pause
}

assign_protocol_outbound() {
  local proto out f tag count=0 written=0 display
  select_node_protocol || { pause; return 0; }
  proto=$SELECTED_PROTO
  display=$(proto_meta_display "$proto")
  select_outbound || { pause; return 0; }
  out=$SELECTED_OUT

  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tag=$(basename "$f" .json)
    if [ "$(meta_get "$tag" proto)" = "$proto" ]; then
      count=$((count + 1))
    fi
  done
  shopt -u nullglob
  if [ "$count" -eq 0 ]; then
    warn "该协议暂无节点"
    pause
    return 0
  fi
  if ! confirm "将 [$display] 的 $count 个节点绑定到出站 [$out] ?" "n"; then
    info "已取消"
    pause
    return 0
  fi

  mkdir -p "$SB_DIR/routes"
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    tag=$(basename "$f" .json)
    if [ "$(meta_get "$tag" proto)" = "$proto" ]; then
      printf '%s\n' "$out" > "$SB_DIR/routes/$tag.outbound"
      written=$((written + 1))
    fi
  done
  shopt -u nullglob
  info "已为 $written 个 [$display] 节点绑定出站 [$out]"
  apply_changes
  pause
}

view_node_routes() {
  local f tag proto out final i=0
  if [ "$(count_nodes)" -eq 0 ]; then
    warn "暂无节点"
    pause
    return 0
  fi
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  printf '%-4s %s%22s %s%20s %s\n' "序号" "节点名称" "" "协议" "" "出站"
  printf '%s\n' "--------------------------------------------------------------------------"
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    i=$((i + 1))
    tag=$(basename "$f" .json)
    proto=$(meta_get "$tag" proto)
    if [ -s "$SB_DIR/routes/$tag.outbound" ]; then
      out=$(head -n1 "$SB_DIR/routes/$tag.outbound" 2>/dev/null || true)
      if [ -z "$out" ]; then
        out="默认 ($final)"
      elif [ "$out" != "direct" ] && [ ! -f "$OUT_DIR/$out.json" ]; then
        out="$out [缺失]"
      fi
    else
      out="默认 ($final)"
    fi
    printf '%-4s %-30s %-24s %s\n' "$i" "$tag" "$(proto_meta_display "$proto")" "$out"
  done
  shopt -u nullglob
  pause
}

clear_node_routes() {
  local c tag rf removed=0
  printf '1) 清除指定节点的出站绑定\n2) 清除全部节点出站绑定\n0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1)
      select_node || { pause; return 0; }
      tag=$SELECTED
      if [ ! -s "$SB_DIR/routes/$tag.outbound" ]; then
        info "节点 [$tag] 没有出站绑定"
        pause
        return 0
      fi
      if ! confirm "清除节点 [$tag] 的出站绑定?" "n"; then
        info "已取消"
        pause
        return 0
      fi
      rm -f "$SB_DIR/routes/$tag.outbound"
      info "已清除节点 [$tag] 的出站绑定"
      apply_changes
      pause
      ;;
    2)
      if ! confirm "清除所有节点的出站绑定?" "n"; then
        info "已取消"
        pause
        return 0
      fi
      shopt -s nullglob
      for rf in "$SB_DIR/routes"/*.outbound; do
        rm -f "$rf"
        removed=$((removed + 1))
      done
      shopt -u nullglob
      info "已清除 $removed 个节点的出站绑定"
      apply_changes
      pause
      ;;
    0) return 0 ;;
    *) warn "无效选项" ;;
  esac
}

menu_change_outbound() {
  local c
  while true; do
    printf '\n%s\n' "------------- 更改出站 -------------"
    printf ' 1) 设置默认出站\n'
    printf ' 2) 为指定节点分配出站\n'
    printf ' 3) 按协议批量分配出站\n'
    printf ' 4) 查看节点出站分配\n'
    printf ' 5) 清除节点出站分配\n'
    printf ' 0) 返回\n'
    ask c "请选择" ""
    case "$c" in
      1) change_outbound ;;
      2) assign_node_outbound ;;
      3) assign_protocol_outbound ;;
      4) view_node_routes ;;
      5) clear_node_routes ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

delete_outbound() {
  local tag final rf removed=0
  select_custom_outbound || { pause; return 0; }
  tag=$SELECTED_OUT
  warn "即将删除出站 [$tag]"
  if ! confirm "确定删除?" "n"; then
    info "已取消"
    pause
    return 0
  fi
  rm -f "$OUT_DIR/$tag.json"
  final=$(head -n1 "$FINAL_FILE" 2>/dev/null || echo direct)
  if [ "$final" = "$tag" ]; then
    printf 'direct\n' > "$FINAL_FILE"
    warn "该出站是默认出站，已自动切换回 direct"
  fi
  shopt -s nullglob
  for rf in "$SB_DIR/routes"/*.outbound; do
    if [ "$(head -n1 "$rf" 2>/dev/null || true)" = "$tag" ]; then
      rm -f "$rf"
      removed=$((removed + 1))
    fi
  done
  shopt -u nullglob
  if [ "$removed" -gt 0 ]; then
    warn "已清除 $removed 个节点对该出站的绑定"
  fi
  info "出站 [$tag] 已删除"
  apply_changes
  pause
}

edit_file_with_editor() {
  local file=$1 ed=''
  if [ -n "${EDITOR:-}" ]; then
    ed=$EDITOR
  fi
  if [ -z "$ed" ]; then
    local c
    for c in nano vim vi; do
      if command -v "$c" >/dev/null 2>&1; then
        ed=$c
        break
      fi
    done
  fi
  if [ -n "$ed" ]; then
    # shellcheck disable=SC2086
    $ed "$file"
  else
    warn "未找到文本编辑器，请手动编辑文件: $file"
    read -r -p "编辑保存后按回车继续校验..." _ || true
  fi
}

edit_outbound() {
  local tag file backup newtag
  select_custom_outbound || { pause; return 0; }
  tag=$SELECTED_OUT
  file="$OUT_DIR/$tag.json"
  backup="$file.bak"
  cp -f "$file" "$backup" || { error "备份失败"; pause; return 0; }
  edit_file_with_editor "$file"
  if ! jq -e 'type=="object" and (.tag|type=="string") and (.type|type=="string")' "$file" >/dev/null 2>&1; then
    error "JSON 校验失败，已恢复原配置"
    mv -f "$backup" "$file"
    pause
    return 0
  fi
  newtag=$(jq -r '.tag' "$file")
  if [ "$newtag" != "$tag" ]; then
    error "不允许在编辑时修改 tag (${tag} -> ${newtag})，已恢复原配置"
    mv -f "$backup" "$file"
    pause
    return 0
  fi
  rm -f "$backup"
  info "出站 [$tag] 已更新"
  apply_changes
  pause
}

menu_outbounds() {
  local c
  while true; do
    printf '\n%s\n' "------------- 出站管理 -------------"
    printf ' 1) 新增出站\n'
    printf ' 2) 删除出站\n'
    printf ' 3) 编辑出站\n'
    printf ' 4) 更改出站 / 节点分流\n'
    printf ' 5) 查看出站\n'
    printf ' 0) 返回主菜单\n'
    ask c "请选择" ""
    case "$c" in
      1) menu_add_outbound ;;
      2) delete_outbound ;;
      3) edit_outbound ;;
      4) menu_change_outbound ;;
      5) view_outbounds ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

menu_add_outbound() {
  local c
  printf '%s\n' "------------- 新增出站 -------------"
  printf ' 1) SOCKS5             2) HTTP 代理\n'
  printf ' 3) Shadowsocks        4) VMess\n'
  printf ' 5) VLESS              6) Trojan\n'
  printf ' 7) Hysteria2          8) TUIC\n'
  printf ' 9) Snell-v6          10) 自定义 JSON\n'
  printf ' 0) 返回\n'
  ask c "请选择" ""
  case "$c" in
    1) create_out_socks socks ;;
    2) create_out_socks http ;;
    3) create_out_ss ;;
    4) create_out_vmess ;;
    5) create_out_vless ;;
    6) create_out_trojan ;;
    7) create_out_hysteria2 ;;
    8) create_out_tuic ;;
    9) create_out_snell ;;
    10) create_out_custom ;;
    0) return 0 ;;
    *) warn "无效选项" ;;
  esac
  pause
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
      start_core
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
  if has_openrc && [ -f /etc/init.d/sing-box ]; then
    if command -v rc-update >/dev/null 2>&1; then
      rc-update del sing-box default >/dev/null 2>&1 || true
    fi
    rm -f /etc/init.d/sing-box
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
#  运行管理
# ================================================================
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


# ================================================================
#  主菜单 / 入口
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
  printf '           sing-box 一键管理脚本  v%s\n' "$SCRIPT_VERSION"
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
    printf ' 1) 节点管理\n'
    printf ' 2) 出站管理\n'
    printf ' 3) 运行管理\n'
    printf ' 4) 核心管理\n'
    printf ' 5) 分享链接\n'
    printf ' 6) 使用帮助\n'
    printf ' 0) 退出\n'
    printf '%s\n' "--------------------------------------------------"
    ask c "请选择" ""
    case "$c" in
      1) menu_nodes ;;
      2) menu_outbounds ;;
      3) menu_runtime ;;
      4) menu_core ;;
      5) show_all_links ;;
      6) menu_help ;;
      0)
        info "已退出"
        exit 0
        ;;
      *) warn "无效选项" ;;
    esac
  done
}


# ================================================================
#  入口主流程: 命令行参数、首次安装引导与菜单启动
# ================================================================
usage() {
  cat <<EOF
sing-box 一键部署管理脚本

用法:
  bash $0            启动交互式管理菜单
  bash $0 install    安装/更新 sing-box 核心并生成服务
  bash $0 status     查看运行状态
  bash $0 help       显示帮助

说明:
  需要 root 权限运行。
  所有节点、出站和证书均保存在 $SB_DIR 下。
EOF
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  need_root
  ensure_dirs
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

  if [ ! -x "$BIN" ]; then
    clear 2>/dev/null || true
    printf '%s\n' "=================================================="
    printf '%s\n' "        欢迎使用 sing-box 一键部署管理脚本"
    printf '%s\n' "=================================================="
    printf '脚本将自动识别系统架构并安装 sing-box。\n'
    printf '安装完成后可在菜单中管理节点、出站和运行状态。\n\n'
    if confirm "未检测到 sing-box 核心，是否立即自动安装?" "y"; then
      if install_core; then
        write_service
        rebuild_config || true
        info "安装完成，请进入“节点管理”添加节点"
      else
        error "安装失败，请检查网络后重试"
      fi
      pause
    fi
  fi

  if [ -x "$BIN" ]; then
    if ! "$BIN" version >/dev/null 2>&1; then
      warn "当前核心无法运行，请进入“核心管理 -> 更新核心”重新安装"
    fi
    if has_systemd && [ ! -f "$SERVICE_FILE" ]; then
      write_service
    elif has_openrc && [ ! -f /etc/init.d/sing-box ]; then
      write_service
    fi
  fi

  if [ ! -f "$CONF" ]; then
    rebuild_config || true
  fi

  main_menu
}

main "$@"
