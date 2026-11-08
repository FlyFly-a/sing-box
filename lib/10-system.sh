# ================================================================
#  依赖与核心安装
# ================================================================
ensure_deps() {
  local missing=() cmd
  for cmd in curl jq openssl tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ! -s /etc/ssl/certs/ca-certificates.crt ] && \
     [ ! -s /etc/pki/tls/certs/ca-bundle.crt ] && \
     [ ! -s /etc/ssl/cert.pem ] && \
     [ ! -s /etc/ssl/ca-bundle.pem ]; then
    missing+=("ca-certificates")
  fi
  if [ ${#missing[@]} -eq 0 ]; then
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
  local fail=0
  for cmd in curl jq openssl tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || fail=1
  done
  if [ "$fail" -ne 0 ]; then
    error "依赖安装失败，请手动安装: ${missing[*]}"
    return 1
  fi
  info "依赖安装完成"
  return 0
}

detect_arch() {
  local m
  m=$(uname -m 2>/dev/null || echo unknown)
  case "$m" in
    x86_64|amd64)        ARCH="amd64" ;;
    aarch64|arm64)       ARCH="arm64" ;;
    armv7l|armv7|armv8l) ARCH="armv7" ;;
    armv6l|armv6)        ARCH="armv6" ;;
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
  info "系统架构: $m -> linux-$ARCH"
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
  local version=${1:-} tmp extract url
  ensure_deps || return 1
  detect_arch || return 1
  if [ -z "$version" ]; then
    info "正在查询 sing-box 最新版本 ..."
    version=$(get_latest_version) || true
    if [ -z "$version" ]; then
      error "获取最新版本失败，请检查网络连接"
      return 1
    fi
  fi
  info "准备安装 sing-box v${version} (linux-${ARCH})"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
  tmp=$(mktemp -d) || { error "创建临时目录失败"; return 1; }
  if ! download_file "$url" "$tmp/sing-box.tar.gz"; then
    error "核心下载失败，请检查网络或稍后重试"
    rm -rf "$tmp"
    return 1
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
  mv -f "${BIN}.new" "$BIN" || { error "替换核心失败"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  if ! "$BIN" version >/dev/null 2>&1; then
    error "核心已下载但无法运行，请确认系统架构或依赖环境"
    return 1
  fi
  info "核心安装完成: $("$BIN" version 2>/dev/null | head -n1)"
  return 0
}

write_service() {
  if ! has_systemd; then
    warn "未检测到 systemd，将使用后台进程方式运行"
    return 0
  fi
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable sing-box >/dev/null 2>&1 || true
  info "systemd 服务已写入并设置开机自启"
}

