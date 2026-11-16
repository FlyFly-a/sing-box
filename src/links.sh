# Link contents are credentials. Output only when explicitly requested.
link_export() {
  local node=$1 override=${2:-}
  jq -r --arg address "$override" '
    def enc: @uri;
    . as $n | (if $address!="" then [$address] else .endpoint.addresses end)[] as $a |
    (if ($a|contains(":")) then "["+$a+"]" else $a end) as $host |
    ($host+":"+($n.endpoint.port|tostring)) as $hp |
    ($n.endpoint.sni|enc) as $sni | ($n.id|enc) as $name |
    ("security=tls&sni="+$sni) as $tls |
    ("&type=ws&host="+($n.endpoint.host|enc)+"&path="+($n.ws_path|enc)) as $ws |
    if $n.preset=="reality" then "vless://"+$n.auth.uuid+"@"+$hp+"?security=reality&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni="+$sni+"&pbk="+$n.auth.public_key+"&sid="+$n.auth.short_id+"#"+$name
    elif $n.preset=="vless-ws" then "vless://"+$n.auth.uuid+"@"+$hp+"?"+$tls+$ws+"#"+$name
    elif $n.preset=="vmess-ws" then "vmess://"+({v:"2",ps:$n.id,add:$a,port:$n.endpoint.port,id:$n.auth.uuid,aid:0,scy:"auto",net:"ws",type:"none",tls:"tls",sni:$n.endpoint.sni,host:$n.endpoint.host,path:$n.ws_path}|tojson|@base64)
    elif $n.preset=="ss2022" then "ss://"+(("2022-blake3-aes-256-gcm:"+$n.auth.password)|@base64)+"@"+$hp+"#"+$name
    elif $n.preset=="snell" then $n.id+" = snell, "+$a+", "+($n.endpoint.port|tostring)+", psk="+$n.auth.password+", version=6, mode=default, reuse=false"
    elif $n.preset=="socks" then "socks://"+(($n.auth.username+":"+$n.auth.password)|@base64)+"@"+$hp+"#"+$name
    elif $n.preset=="tuic" then "tuic://"+$n.auth.uuid+":"+($n.auth.password|enc)+"@"+$hp+"?sni="+$sni+"&alpn=h3&congestion_control=bbr&udp_relay_mode=native#"+$name
    elif ($n.preset=="trojan" or $n.preset=="trojan-ws") then "trojan://"+($n.auth.password|enc)+"@"+$hp+"?"+$tls+(if $n.preset=="trojan-ws" then $ws else "&type=tcp" end)+"#"+$name
    else $n.preset+"://"+($n.auth.password|enc)+"@"+$hp+"?sni="+$sni+"#"+$name end
  ' "$node"
  if [[ $(jq -r .tls.kind "$node") == self ]]; then
    say '自签证书：链接未跳过验证；客户端必须另行导入此节点证书为信任锚。' >&2
  fi
}
parse_authority() {
  local authority=$1
  authority=${authority%/}
  if [[ $authority =~ ^\[([0-9a-fA-F:.]+)\]:([0-9]+)$ ]]; then
    LINK_HOST=${BASH_REMATCH[1]}; LINK_PORT=${BASH_REMATCH[2]}
  elif [[ $authority =~ ^([^:]+):([0-9]+)$ ]]; then
    LINK_HOST=${BASH_REMATCH[1]}; LINK_PORT=${BASH_REMATCH[2]}
  else return 1; fi
  valid_address "$LINK_HOST" && valid_port "$LINK_PORT" || return 1
  LINK_PORT=$((10#$LINK_PORT))
}
link_parse() {
  local url=$1 tag=$2 scheme body auth authority user query='' pair k v raw type='tcp' security='' sni='' host='' path='/' pbk='' sid='' flow='' cc=bbr relay=native fp=chrome method='' password='' username='' uuid='' tls='null' transport='null' alpn='[]'
  local -A params=()
  valid_id "$tag" || return 1
  [[ $url == *://* && ${#url} -le 32768 ]] || { err '分享链接格式或长度无效。'; return 1; }
  scheme=${url%%://*}; body=${url#*://}; body=${body%%#*}
  case "$scheme" in vless|trojan|hysteria2|hy2|tuic|anytls|ss|vmess|socks) ;; *) err '不支持此分享链接协议。'; return 1;; esac
  if [[ $scheme == vmess ]]; then
    raw=$(b64_decode "$body") || return 1
    jq -e 'type=="object" and (.aid//0|tonumber)==0 and (.net|IN("tcp","ws")) and (.tls|IN("tls","","none",null))' <<< "$raw" >/dev/null 2>&1 || { err 'VMess 数据或传输不受支持。'; return 1; }
    LINK_HOST=$(jq -r .add <<< "$raw"); LINK_HOST=${LINK_HOST#\[}; LINK_HOST=${LINK_HOST%\]}
    LINK_PORT=$(jq -r .port <<< "$raw"); valid_address "$LINK_HOST" && valid_port "$LINK_PORT" || return 1
    uuid=$(jq -r .id <<< "$raw"); type=$(jq -r '.net//"tcp"' <<< "$raw")
    security=$(jq -r '.tls//"none"' <<< "$raw")
    sni=$(jq -r '[.sni,.host,.add]|map(select(type=="string" and length>0))|first' <<< "$raw")
    host=$(jq -r '[.host,.sni,.add]|map(select(type=="string" and length>0))|first' <<< "$raw")
    path=$(jq -r '.path//"/"' <<< "$raw")
    if ! jq -e '[.allowInsecure,.insecure,.allow_insecure,."skip-cert-verify"]|all(.[];.==null or .==false or .==0 or .=="0" or .=="false")' <<< "$raw" >/dev/null; then err '链接要求跳过证书验证；请改为可信证书或显式信任 CA 后导入 JSON。'; return 1; fi
  else
    if [[ $body == *\?* ]]; then query=${body#*\?}; body=${body%%\?*}; fi
    if [[ $scheme == ss && $body != *@* ]]; then body=$(b64_decode "$body") || return 1; fi
    [[ $body == *@* ]] || return 1
    auth=${body%@*}; authority=${body##*@}
    parse_authority "$authority" || { err '服务器地址或端口无效；IPv6 请使用 [地址]:端口。'; return 1; }
    local IFS='&'
    for pair in $query; do
      [[ $pair == *=* ]] || return 1
      k=${pair%%=*}; v=${pair#*=}
      [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ && ! ${params[$k]+set} ]] || return 1
      case "$k" in type|security|sni|host|path|pbk|sid|flow|congestion_control|udp_relay_mode|fp|alpn|encryption|insecure|allowInsecure|allow_insecure|plugin|obfs) ;; *) err '链接含未支持的参数；请显式导入完整 JSON，避免丢失配置。'; return 1;; esac
      params[$k]=$(url_decode "$v") || return 1
    done
    for k in insecure allowInsecure allow_insecure skip-cert-verify; do
      [[ ${params[$k]:-0} == 0 || ${params[$k]:-false} == false ]] || { err '链接要求跳过 TLS 验证；请导入可信证书配置。'; return 1; }
    done
    [[ -z ${params[plugin]:-} && -z ${params[obfs]:-} ]] || { err '不支持插件或混淆链接。'; return 1; }
    type=${params[type]:-tcp}; security=${params[security]:-}; sni=${params[sni]:-$LINK_HOST}
    host=${params[host]:-$sni}; path=${params[path]:-/}; pbk=${params[pbk]:-}; sid=${params[sid]:-}; flow=${params[flow]:-}
    cc=${params[congestion_control]:-bbr}; relay=${params[udp_relay_mode]:-native}; fp=${params[fp]:-chrome}
    [[ ${params[encryption]:-none} == none ]] || return 1
    user=$(url_decode "$auth") || return 1
    case "$scheme" in
      ss)
        if [[ $user != *:* ]]; then user=$(b64_decode "$user") || return 1; fi
        [[ $user == *:* ]] || return 1
        method=${user%%:*}; password=${user#*:};;
      socks)
        if [[ $user != *:* ]]; then user=$(b64_decode "$user") || return 1; fi
        [[ $user == *:* ]] || return 1; username=${user%%:*}; password=${user#*:};;
      tuic) [[ $user == *:* ]] || return 1; uuid=${user%%:*}; password=${user#*:}; security=tls;;
      vless) uuid=$user; security=${security:-none};;
      *) password=$user; security=tls;;
    esac
  fi
  case "$type" in tcp|'') ;; ws) transport=$(jq -cn --arg p "$path" --arg h "$host" '{type:"ws",path:$p,headers:{Host:$h}}');; *) err '仅支持已验证的 TCP 或 WebSocket 传输。'; return 1;; esac
  case "$scheme" in
    vless|vmess|tuic) [[ $uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1;;
  esac
  if [[ $scheme == hy2 ]]; then scheme=hysteria2; fi
  if [[ $scheme == hysteria2 || $scheme == tuic ]]; then
    [[ $type == tcp ]] || return 1; alpn='["h3"]'
  fi
  if [[ -n ${params[alpn]:-} ]]; then alpn=$(jq -cn --arg a "${params[alpn]}" '$a|split(",")'); fi
  case "$security" in
    tls|reality)
      tls=$(jq -cn --arg sni "$sni" --argjson alpn "$alpn" '{enabled:true,server_name:$sni,alpn:$alpn}')
      if [[ $security == tls && -n ${params[fp]:-} ]]; then
        [[ $scheme != hysteria2 && $scheme != tuic ]] || return 1
        tls=$(jq -c --arg f "$fp" '.+{utls:{enabled:true,fingerprint:$f}}' <<< "$tls")
      fi
      if [[ $security == reality ]]; then
        [[ $scheme == vless && $type == tcp && -n $pbk ]] || return 1
        tls=$(jq -c --arg p "$pbk" --arg s "$sid" --arg f "$fp" '.+{utls:{enabled:true,fingerprint:$f},reality:{enabled:true,public_key:$p,short_id:$s}}' <<< "$tls")
        flow=${flow:-xtls-rprx-vision}
      fi;;
    ''|none) ;; *) return 1;;
  esac
  [[ $cc == bbr || $cc == cubic || $cc == new_reno ]] || return 1
  [[ $relay == native || $relay == quic ]] || return 1
  jq -n --arg tag "$tag" --arg type "$scheme" --arg host "$LINK_HOST" --argjson port "$((10#$LINK_PORT))" --arg uuid "$uuid" --arg pass "$password" --arg user "$username" --arg method "$method" --arg flow "$flow" --arg cc "$cc" --arg relay "$relay" --argjson tls "$tls" --argjson transport "$transport" '
    {type:(if $type=="ss" then "shadowsocks" else $type end),tag:$tag,server:$host,server_port:$port} +
    (if ($type|IN("vless","vmess","tuic")) then {uuid:$uuid} else {} end) +
    (if ($type|IN("trojan","anytls","hysteria2","tuic","ss","socks")) then {password:$pass} else {} end) +
    (if $type=="ss" then {method:$method} elif $type=="socks" then {version:"5",username:$user} elif $type=="vmess" then {security:"auto"} elif $type=="tuic" then {congestion_control:$cc,udp_relay_mode:$relay} else {} end) +
    (if $flow!="" then {flow:$flow} else {} end) +
    (if $tls!=null then {tls:$tls} else {} end) +
    (if $transport!=null then {transport:$transport} else {} end)'
}
