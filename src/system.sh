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
