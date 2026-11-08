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

