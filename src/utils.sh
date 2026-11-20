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
