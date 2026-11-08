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
    ask v "节点名称(tag)" "$def"
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
      warn "该名称与出站标签冲突"
      continue
    fi
    TAG_VAL=$v
    return 0
  done
}

suggest_port() {
  local transport=${1:-tcp} p i
  for p in 443 8443 2053 2083 2087 2096; do
    if ! port_in_use "$p" "$transport"; then
      printf '%s' "$p"
      return 0
    fi
  done
  for ((i=10000; i<60000; i+=7)); do
    if ! port_in_use "$i" "$transport"; then
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
    type=$(jq -r 'if type=="array" then .[-1].type else .type end' "$f" 2>/dev/null || true)
    case "$type" in
      hysteria2|tuic) t="udp" ;;
      *)              t="tcp" ;;
    esac
    if [ -n "$transport" ] && [ "$t" != "$transport" ]; then
      continue
    fi
    if jq -e --argjson p "$port" \
      'if type=="array" then any(.[]; .listen_port == $p) else .listen_port == $p end' \
      "$f" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

ask_port() {
  local def=$1 transport=${2:-tcp} v
  while true; do
    ask v "端口" "$def"
    if ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
      warn "端口范围 1-65535"
      continue
    fi
    if port_in_use "$v" "$transport"; then
      warn "端口 $v 已被同类型节点占用，请更换"
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
  jq -c 'if type=="array" then .[-1] else . end' "$NODE_DIR/$1.json" 2>/dev/null
}

n_get() {
  local tag=$1 filter=$2 def=${3:-}
  node_obj "$tag" | jq -r --arg d "$def" "$filter // \$d" 2>/dev/null || printf '%s' "$def"
}

list_nodes_table() {
  local f tag proto port domain i=0
  printf '%-4s %-28s %-24s %-7s %s\n' "序号" "节点名称" "协议" "端口" "域名/伪装"
  printf '%s\n' "-------------------------------------------------------------------------------"
  shopt -s nullglob
  for f in "$NODE_DIR"/*.json; do
    i=$((i+1))
    tag=$(basename "$f" .json)
    proto=$(meta_get "$tag" proto)
    port=$(jq -r 'if type=="array" then .[-1].listen_port else .listen_port end' "$f" 2>/dev/null || echo '-')
    domain=$(jq -r 'if type=="array" then (.[-1].tls.server_name // .[-1].handshake.server // "-") else (.tls.server_name // .handshake.server // "-") end' "$f" 2>/dev/null || echo '-')
    printf '%-4s %-28s %-24s %-7s %s\n' "$i" "$tag" "${proto:-未知}" "$port" "$domain"
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
  info "节点 [$tag] 已保存"
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    return 0
  fi
  apply_changes
}

# ================================================================
#  证书处理
# ================================================================
cert_file_base() {
  printf '%s' "${1//\*/_}" | tr -c 'A-Za-z0-9._-' '_'
}

ensure_cert() {
  local domain=$1 base crt key cnf c k
  base=$(cert_file_base "$domain")
  crt="$CERT_DIR/$base.crt"
  key="$CERT_DIR/$base.key"
  if [ -s "$crt" ] && [ -s "$key" ]; then
    CERT_FILE=$crt
    KEY_FILE=$key
    if [ -f "$CERT_DIR/$base.selfsigned" ]; then
      CERT_INSECURE=1
    else
      CERT_INSECURE=0
    fi
    info "使用已有证书: $crt"
    return 0
  fi
  warn "未找到域名 $domain 对应的证书"
  if confirm "是否生成自签证书? 自用可以，对外服务建议上传真实证书"; then
    mkdir -p "$CERT_DIR"
    cnf="$CERT_DIR/$base.cnf"
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
      info "自签证书已生成: $crt"
      return 0
    fi
    error "自签证书生成失败"
    return 1
  fi
  while true; do
    ask c "证书 crt 文件路径" ""
    ask k "私钥 key 文件路径" ""
    if [ -s "$c" ] && [ -s "$k" ]; then
      CERT_FILE=$c
      KEY_FILE=$k
      CERT_INSECURE=0
      return 0
    fi
    warn "证书或私钥文件不存在"
    confirm "是否重新输入?" || return 1
  done
}

prompt_domain_cert() {
  if [ "${BATCH_MODE:-0}" = "1" ]; then
    if [ -z "${BATCH_DOMAIN:-}" ]; then
      error "批量创建缺少统一域名"
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
  alpn=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq -n --arg sni "$domain" --arg crt "$CERT_FILE" --arg key "$KEY_FILE" --argjson alpn "$alpn" \
    '{enabled:true,server_name:$sni,alpn:$alpn,certificate_path:$crt,key_path:$key}'
}

