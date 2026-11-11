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
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk '{print $4}' | grep -qE "[:.]${port}$"
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
