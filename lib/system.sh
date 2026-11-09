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
  if ! jq_version_supported; then
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

