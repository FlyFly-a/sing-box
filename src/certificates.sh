certificate_check() {
  local cert=$1 key=$2 domain=$3 kind=$4 a b
  valid_domain "$domain" || { err '证书预期域名无效。'; return 1; }
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 &&
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || { err '证书已过期或域名不匹配。'; return 1; }
  a=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) &&
    b=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) && [[ $a == "$b" ]] || { err '私钥无法读取或与证书不匹配。'; return 1; }
  # Each trust mode verifies both time bounds, key usage and hostname.
  if [[ $kind == public ]]; then
    openssl verify -purpose sslserver -verify_hostname "$domain" -untrusted "$cert" "$cert" >/dev/null 2>&1 || { err '公开证书链未通过系统 CA 校验；请提供完整链。'; return 1; }
  elif [[ $kind == origin ]]; then
    # Publicly distributed Cloudflare trust roots are bundled, so creation is offline.
    local roots
    roots=$(mktemp "${SB_TXN:-${TMPDIR:-/tmp}}/origin-ca.XXXXXXXX") || return 1
    origin_ca_bundle > "$roots" || { rm -f "$roots"; return 1; }
    if ! openssl verify -CAfile "$roots" -no-CApath -purpose sslserver -verify_hostname "$domain" -untrusted "$cert" "$cert" >/dev/null 2>&1; then
      rm -f "$roots"; err '源站证书未通过 Cloudflare Origin CA 签发链校验。'; return 1
    fi
    rm -f "$roots"
  else
    [[ $kind == self ]] || return 1
    # Explicit leaf trust only for self: verifies both validity bounds without
    # GNU date parsing, which is unavailable in minimal BusyBox containers.
    openssl verify -partial_chain -trusted "$cert" -purpose sslserver -verify_hostname "$domain" "$cert" >/dev/null 2>&1 || { err '证书尚未生效、已过期或用途不正确。'; return 1; }
  fi
}
certificate_attach() {
  local node=$1 kind=$2 domain=$3 cert=${4:-} key=${5:-} dir
  [[ $kind == public || $kind == origin || $kind == self ]] || return 1
  dir=$(mktemp -d "$SB_TXN/cert.XXXXXXXX") || return 1
  if [[ $kind == self ]]; then
    cert=$dir/cert.pem; key=$dir/key.pem
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" -keyout "$key" -out "$cert" >/dev/null 2>&1 || { rm -rf "$dir"; return 1; }
  fi
  certificate_check "$cert" "$key" "$domain" "$kind" || { rm -rf "$dir"; return 1; }
  jq --arg kind "$kind" --arg sni "$domain" --rawfile cert "$cert" --rawfile key "$key" \
    '.endpoint.sni=$sni | .tls={kind:$kind,certificate:[$cert],key:[$key]}' "$node" > "$node.next" && mv -f "$node.next" "$node"
  local rc=$?; rm -rf "$dir"; return "$rc"
}
validate_node_certificates() {
  local state=$1 item kind domain addr dir preset mode value
  value=$(jq -r '.defaults.domain' "$state")
  [[ -z $value ]] || valid_domain "$value" || { err '默认分享域名无效。'; return 1; }
  dir=$(mktemp -d "$SB_TXN/verify.XXXXXXXX") || return 1
  while IFS= read -r item; do
    printf '%s\n' "$item" > "$dir/node.json"
    while IFS= read -r addr; do
      valid_address "$addr" || { rm -rf "$dir"; err '连接地址格式无效。'; return 1; }
    done < <(jq -r '.endpoint.addresses[]' "$dir/node.json")
    kind=$(jq -r .tls.kind "$dir/node.json")
    preset=$(jq -r .preset "$dir/node.json")
    if is_ws "$preset"; then
      value=$(jq -r .endpoint.host "$dir/node.json")
      valid_domain "$value" || { rm -rf "$dir"; err 'WS Host 必须是域名。'; return 1; }
    fi
    if [[ $preset == reality ]]; then
      value=$(jq -r .endpoint.sni "$dir/node.json")
      valid_domain "$value" || { rm -rf "$dir"; return 1; }
      value=$(jq -r .reality.server "$dir/node.json")
      valid_address "$value" || { rm -rf "$dir"; return 1; }
    fi
    [[ $kind != none ]] || continue
    domain=$(jq -r .endpoint.sni "$dir/node.json")
    jq -r '.tls.certificate[]' "$dir/node.json" > "$dir/cert.pem" && jq -r '.tls.key[]' "$dir/node.json" > "$dir/key.pem" || { rm -rf "$dir"; return 1; }
    certificate_check "$dir/cert.pem" "$dir/key.pem" "$domain" "$kind" || { rm -rf "$dir"; return 1; }
  done < <(jq -c '.nodes[]' "$state")
  rm -rf "$dir"
}
