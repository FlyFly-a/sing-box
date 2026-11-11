# ================================================================
#  分享链接解析 -> 出站配置
#  支持 vless / vmess / trojan / hysteria2 / tuic / ss / anytls
#  Snell 与 SOCKS5 无标准链接，走手动填写
# ================================================================

PARSED_HOST=""
PARSED_PORT=""

# 从查询串取参数
query_get() {
  local qs=${1:-} key=$2 def=${3:-} pair k v
  [ -n "$qs" ] || { printf '%s' "$def"; return 0; }
  local IFS='&'
  for pair in $qs; do
    k=${pair%%=*}
    case "$k" in "$key") ;; *) continue ;; esac
    v=${pair#*=}
    [ "$v" = "$pair" ] && v=""
    printf '%s' "$(urldec "$v")"
    return 0
  done
  printf '%s' "$def"
}

# 从链接的 #fragment 取名称
link_fragment() {
  local u=${1:-}
  case "$u" in
    *'#'*) urldec "${u#*#}" ;;
    *)     printf '' ;;
  esac
}

# 去掉 fragment
link_no_fragment() {
  local u=${1:-}
  printf '%s' "${u%%#*}"
}

# 解析 host:port / [ipv6]:port / host（使用默认端口）
# 结果写入 PARSED_HOST / PARSED_PORT；失败返回 1
parse_host_port() {
  local hp=${1:-} def=${2:-}
  PARSED_HOST=""
  PARSED_PORT=""
  [ -n "$hp" ] || return 1
  hp=${hp%%/*}
  if [[ $hp == \[*\]:* ]]; then
    PARSED_HOST=${hp#\[}
    PARSED_HOST=${PARSED_HOST%%\]*}
    PARSED_PORT=${hp##*\]:}
  elif [[ $hp == \[*\] ]]; then
    PARSED_HOST=${hp#\[}
    PARSED_HOST=${PARSED_HOST%\]}
    PARSED_PORT=$def
  elif [[ $hp == *:*:* ]]; then
    # 未加方括号的 IPv6 无法可靠拆分端口
    return 1
  elif [[ $hp == *:* ]]; then
    PARSED_HOST=${hp%:*}
    PARSED_PORT=${hp##*:}
  else
    PARSED_HOST=$hp
    PARSED_PORT=$def
  fi
  [ -n "$PARSED_HOST" ] || return 1
  if [ -n "$PARSED_PORT" ]; then
    valid_port "$PARSED_PORT" || return 1
    PARSED_PORT=$((10#$PARSED_PORT))
  fi
  return 0
}

# 解析单个分享链接，成功时设置 OUT_JSON
# 失败时返回非零并输出原因到 OUT_ERROR
parse_share_link() {
  local url=${1:-} scheme rest body
  OUT_JSON=""
  OUT_ERROR=""
  OUT_SUGGEST_TAG=""

  url=${url#"${url%%[![:space:]]*}"}
  url=${url%"${url##*[![:space:]]}"}
  [ -n "$url" ] || { OUT_ERROR="链接为空"; return 1; }

  scheme=${url%%://*}
  if [ "$scheme" = "$url" ]; then
    OUT_ERROR="无法识别的链接格式，缺少 :// 前缀"
    return 1
  fi
  scheme=${scheme,,}
  rest=${url#*://}
  OUT_SUGGEST_TAG=$(link_fragment "$rest")
  body=$(link_no_fragment "$rest")

  case "$scheme" in
    vless|trojan|hysteria2|tuic|anytls|ss|vmess) ;;
    *)
      OUT_ERROR="暂不支持的链接协议: $scheme"
      return 1
      ;;
  esac

  case "$scheme" in
    vmess) parse_link_vmess "$body" ;;
    ss)    parse_link_ss "$body" ;;
    *)     parse_link_standard "$scheme" "$body" ;;
  esac
}

# userinfo@host:port?query
parse_link_standard() {
  local scheme=$1 body=$2
  local userinfo hostport query host port user
  local sni pbk sid path hosthdr security flow cc type ws_host
  local tls='' transport='' default_port=''

  case "$body" in
    *'?'*) userinfo=${body%%\?*}; query=${body#*\?} ;;
    *)     userinfo=$body; query="" ;;
  esac

  hostport=${userinfo##*@}
  if [ "$hostport" = "$userinfo" ]; then
    OUT_ERROR="链接缺少 用户信息@地址 结构"
    return 1
  fi
  userinfo=${userinfo%@*}
  user=$(urldec_raw "$userinfo")

  [ "$scheme" = "anytls" ] && default_port=443
  if ! parse_host_port "$hostport" "$default_port"; then
    OUT_ERROR="链接中的服务器地址或端口无效: $hostport"
    return 1
  fi
  host=$PARSED_HOST
  port=$PARSED_PORT
  if [ -z "$port" ]; then
    OUT_ERROR="链接缺少服务器端口: $hostport"
    return 1
  fi

  sni=$(query_get "$query" sni)
  pbk=$(query_get "$query" pbk)
  sid=$(query_get "$query" sid)
  path=$(query_get "$query" path)
  hosthdr=$(query_get "$query" host)
  security=$(query_get "$query" security)
  flow=$(query_get "$query" flow)
  cc=$(query_get "$query" congestion_control)
  type=$(query_get "$query" type)
  security=${security,,}
  type=${type,,}

  case "$scheme" in
    vless)
      valid_uuid "$user" || { OUT_ERROR="VLESS 链接中的 UUID 无效: $user"; return 1; }

      # REALITY: security=reality 或带 pbk；TLS: security=tls；
      # security 为空/none 时保持明文，绝不因为存在 host/sni 就猜测 TLS。
      if [ "$security" = "reality" ] || { [ -n "$pbk" ] && [ "$security" != "tls" ]; }; then
        [ -n "$sni" ] || sni=$hosthdr
        [ -n "$sni" ] || { OUT_ERROR="REALITY 链接缺少 sni 参数"; return 1; }
        [ -n "$pbk" ] || { OUT_ERROR="REALITY 链接缺少 pbk 参数"; return 1; }
        tls=$(client_tls_json "$sni" "$pbk" "$sid")
        [ -n "$flow" ] || flow="xtls-rprx-vision"
      elif [ "$security" = "tls" ]; then
        [ -n "$sni" ] || sni=$hosthdr
        [ -n "$sni" ] || { OUT_ERROR="TLS 链接缺少 sni 参数"; return 1; }
        tls=$(client_tls_json "$sni")
      elif [ -z "$security" ] || [ "$security" = "none" ]; then
        tls=""
      else
        OUT_ERROR="不支持的 security: $security"
        return 1
      fi

      ws_host=${hosthdr:-$sni}
      case "$type" in
        ''|tcp) ;;
        ws)
          [ -n "$ws_host" ] || ws_host=$host
          transport=$(jq -n --arg p "${path:-/}" --arg h "$ws_host" \
            '{type:"ws",path:$p} + (if $h == "" then {} else {headers:{Host:$h}} end)')
          ;;
        *)
          OUT_ERROR="暂不支持的传输类型: $type"
          return 1
          ;;
      esac

      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg uuid "$user" --arg flow "$flow" \
        '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid}
         + (if $flow == "" then {} else {flow:$flow} end)')
      ;;

    trojan)
      [ -n "$user" ] || { OUT_ERROR="Trojan 链接缺少密码"; return 1; }
      [ -n "$sni" ] || sni=$hosthdr
      [ -n "$sni" ] || { OUT_ERROR="Trojan 链接缺少 sni 参数"; return 1; }
      tls=$(client_tls_json "$sni")

      ws_host=${hosthdr:-$sni}
      case "$type" in
        ''|tcp) ;;
        ws)
          [ -n "$ws_host" ] || ws_host=$host
          transport=$(jq -n --arg p "${path:-/}" --arg h "$ws_host" \
            '{type:"ws",path:$p} + (if $h == "" then {} else {headers:{Host:$h}} end)')
          ;;
        *)
          OUT_ERROR="暂不支持的传输类型: $type"
          return 1
          ;;
      esac

      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg password "$user" \
        '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password}')
      ;;

    hysteria2)
      [ -n "$user" ] || { OUT_ERROR="Hysteria2 链接缺少密码"; return 1; }
      [ -n "$(query_get "$query" obfs)" ] && { OUT_ERROR="暂不支持带 obfs 的 Hysteria2 链接"; return 1; }
      [ -n "$sni" ] || sni=$hosthdr
      [ -n "$sni" ] || { OUT_ERROR="Hysteria2 链接缺少 sni 参数"; return 1; }
      tls=$(jq -n --arg sni "$sni" \
        '{enabled:true,server_name:$sni,alpn:["h3"],insecure:true}')
      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg password "$user" \
        '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password}')
      ;;

    tuic)
      local tuser tpass urm
      tuser=${user%%:*}
      if [ "$tuser" = "$user" ]; then tpass=""; else tpass=${user#*:}; fi
      valid_uuid "$tuser" || { OUT_ERROR="TUIC 链接中的 UUID 无效: $tuser"; return 1; }
      [ -n "$sni" ] || sni=$hosthdr
      [ -n "$sni" ] || { OUT_ERROR="TUIC 链接缺少 sni 参数"; return 1; }

      cc=${cc,,}
      cc=${cc:-bbr}
      case "$cc" in
        cubic|new_reno|bbr) ;;
        *) OUT_ERROR="不支持的 TUIC congestion_control: $cc"; return 1 ;;
      esac

      urm=$(query_get "$query" udp_relay_mode)
      urm=${urm,,}
      case "$urm" in
        ''|native|quic) ;;
        *) OUT_ERROR="不支持的 TUIC udp_relay_mode: $urm"; return 1 ;;
      esac
      [ -n "$urm" ] || urm="native"

      tls=$(jq -n --arg sni "$sni" \
        '{enabled:true,server_name:$sni,alpn:["h3"],insecure:true}')
      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg uuid "$tuser" --arg password "$tpass" --arg cc "$cc" --arg urm "$urm" \
        '{type:"tuic",tag:$tag,server:$server,server_port:$port,
          uuid:$uuid,password:$password,
          congestion_control:$cc,udp_relay_mode:$urm}')
      ;;

    anytls)
      [ -n "$user" ] || { OUT_ERROR="AnyTLS 链接缺少密码"; return 1; }
      [ -n "$sni" ] || sni=$hosthdr
      [ -n "$sni" ] || sni=$host
      tls=$(client_tls_json "$sni")
      OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$host" --argjson port "$port" \
        --arg password "$user" \
        '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password}')
      ;;
  esac

  [ -n "$OUT_JSON" ] || { OUT_ERROR="链接解析失败"; return 1; }
  [ -n "$tls" ] && OUT_JSON=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$OUT_JSON")
  [ -n "$transport" ] && OUT_JSON=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$OUT_JSON")
  return 0
}

# vmess://base64(json)
_vmess_decode() {
  local body=$1 clean cand out
  clean=$(printf '%s' "$body" | tr -d '\r\n\t')
  for cand in "$clean" "${clean// /+}"; do
    out=$(b64decode "$cand" || true)
    [ -n "$out" ] || continue
    if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$out"
      return 0
    fi
  done
  return 1
}

parse_link_vmess() {
  local body=$1 raw json
  raw=$(_vmess_decode "$body") || {
    OUT_ERROR="VMess 链接内容不是合法的 Base64 JSON"
    return 1
  }
  json=$raw

  local add port uuid host path net ttls sni
  add=$(jq -r '.add // empty' <<<"$json")
  port=$(jq -r '.port // empty' <<<"$json")
  uuid=$(jq -r '.id // empty' <<<"$json")
  host=$(jq -r '.host // empty' <<<"$json")
  path=$(jq -r '.path // "/"' <<<"$json")
  net=$(jq -r '.net // "tcp"' <<<"$json")
  ttls=$(jq -r '.tls // ""' <<<"$json")
  sni=$(jq -r '.sni // empty' <<<"$json")

  # 部分客户端会给 IPv6 地址加方括号
  if [[ $add == \[*\] ]]; then
    add=${add#\[}
    add=${add%\]}
  fi

  if [ -z "$add" ] || ! valid_port "$port"; then
    OUT_ERROR="VMess 链接缺少有效的服务器地址或端口"
    return 1
  fi
  if ! valid_uuid "$uuid"; then
    OUT_ERROR="VMess 链接中的 UUID 无效: $uuid"
    return 1
  fi

  net=${net,,}
  ttls=${ttls,,}
  [ -n "$sni" ] || sni=$host

  local tls="" transport=""
  case "$ttls" in
    ''|none) ;;
    tls)
      [ -n "$sni" ] || { OUT_ERROR="VMess TLS 链接缺少 sni/host 参数"; return 1; }
      tls=$(client_tls_json "$sni")
      ;;
    *)
      OUT_ERROR="暂不支持的 VMess TLS 类型: $ttls"
      return 1
      ;;
  esac

  case "$net" in
    ''|tcp) ;;
    ws)
      transport=$(jq -n --arg p "$path" --arg h "$host" \
        '{type:"ws",path:$p} + (if $h == "" then {} else {headers:{Host:$h}} end)')
      ;;
    *)
      OUT_ERROR="暂不支持的 VMess 传输类型: $net"
      return 1
      ;;
  esac

  OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$add" --argjson port "$((10#$port))" \
    --arg uuid "$uuid" \
    '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:"auto"}')
  [ -n "$tls" ] && OUT_JSON=$(jq --argjson t "$tls" '. + {tls:$t}' <<<"$OUT_JSON")
  [ -n "$transport" ] && OUT_JSON=$(jq --argjson t "$transport" '. + {transport:$t}' <<<"$OUT_JSON")
  return 0
}

# ss://base64(method:password)@host:port 或 ss://base64(整套) 或 SIP002
parse_link_ss() {
  local body=$1 userinfo hostport decoded method pass query plugin

  case "$body" in
    *'?'*) query=${body#*\?}; body=${body%%\?*} ;;
    *)     query="" ;;
  esac
  plugin=$(query_get "$query" plugin)
  [ -z "$plugin" ] || { OUT_ERROR="暂不支持带 plugin 的 Shadowsocks 链接"; return 1; }

  userinfo=${body%%@*}
  hostport=${body##*@}
  if [ "$hostport" = "$body" ]; then
    OUT_ERROR="Shadowsocks 链接缺少 地址:端口"
    return 1
  fi

  decoded=$(b64decode "$userinfo" || true)
  if [ -n "$decoded" ] && [[ $decoded == *:* ]]; then
    method=${decoded%%:*}
    pass=${decoded#*:}
  else
    method=${userinfo%%:*}
    pass=${userinfo#*:}
    [ "$pass" = "$userinfo" ] && pass=""
    pass=$(urldec_raw "$pass")
  fi

  if ! parse_host_port "$hostport"; then
    OUT_ERROR="Shadowsocks 链接缺少加密方式、地址或端口"
    return 1
  fi
  if [ -z "$method" ] || [ -z "$PARSED_PORT" ]; then
    OUT_ERROR="Shadowsocks 链接缺少加密方式、地址或端口"
    return 1
  fi
  case "$method" in
    2022-blake3-aes-128-gcm)
      pass=$(b64norm "$pass") || {
        OUT_ERROR="Shadowsocks-2022 密钥必须是 16 字节 Base64"
        return 1
      }
      valid_ss2022_key 16 "$pass" || {
        OUT_ERROR="Shadowsocks-2022 密钥必须是 16 字节 Base64"
        return 1
      }
      ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      pass=$(b64norm "$pass") || {
        OUT_ERROR="Shadowsocks-2022 密钥必须是 32 字节 Base64"
        return 1
      }
      valid_ss2022_key 32 "$pass" || {
        OUT_ERROR="Shadowsocks-2022 密钥必须是 32 字节 Base64"
        return 1
      }
      ;;
  esac

  OUT_JSON=$(jq -n --arg tag "PENDING" --arg server "$PARSED_HOST" --argjson port "$PARSED_PORT" \
    --arg method "$method" --arg pass "$pass" \
    '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,
      method:$method,password:$pass}')
  return 0
}

# 从链接创建出站
create_out_from_link() {
  local url tag
  ask url "分享链接" ""
  [ -n "$url" ] || { warn "已取消"; return 1; }

  if ! parse_share_link "$url"; then
    error "解析失败: $OUT_ERROR"
    return 1
  fi

  local def=${OUT_SUGGEST_TAG:-out-$(gen_hex 2)}
  if [ "$def" = "direct" ] || [ -e "$NODE_DIR/$def.json" ] || [ -e "$OUT_DIR/$def.json" ]; then
    def="out-$(gen_hex 2)"
  fi
  prompt_out_tag "$def" || return 1
  tag=$SELECTED_OUT

  local json
  json=$(jq --arg t "$tag" '.tag = $t' <<<"$OUT_JSON")
  save_outbound "$tag" "$json" || return 1
  info "出站 [$tag] 已创建（$(outbound_type_display "$(jq -r '.type' <<<"$json")")）"
  return 0
}
