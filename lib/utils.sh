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
  if [ -n "$SERVER_IP" ]; then
    printf '%s\n' "$SERVER_IP" > "$IP_FILE" 2>/dev/null || true
  fi
}

get_server_ip() {
  load_server_ip
  printf '%s' "${SERVER_IP:-}"
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

# 百分号解码: 只处理合法的 %HH，保留字面反斜杠和损坏的百分号
urldec() {
  local s=${1//+/ } out='' prefix hex ch
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

b64url() {
  printf '%s' "${1:-}" | base64 | tr -d '[:space:]' | tr '+/' '-_' | tr -d '='
}
