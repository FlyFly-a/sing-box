new_node() {
  local preset=$1 id=$2 port=$3 address=$4 public_port=$5 uuid password path private='' public='' sid='' keys
  valid_id "$id" && valid_port "$port" && valid_port "$public_port" && valid_address "$address" || { err '名称、端口或连接地址格式无效。'; return 1; }
  protocol_field "$preset" name >/dev/null || return 1
  uuid=$(new_uuid) && password=$(random_hex) && path=$(random_hex 6) || return 1
  if [[ $preset == ss2022 ]]; then password=$(openssl rand -base64 32) || return 1; fi
  if [[ $preset == reality ]]; then
    keys=$("$SB_BIN" generate reality-keypair) || return 1
    private=$(sed -n 's/^PrivateKey: *//p' <<< "$keys")
    public=$(sed -n 's/^PublicKey: *//p' <<< "$keys")
    [[ -n $private && -n $public ]] || return 1
    sid=$(random_hex 4) || return 1
  fi
  jq -n --arg preset "$preset" --arg id "$id" --argjson port "$((10#$port))" --arg a "$address" --argjson p "$((10#$public_port))" \
    --arg uuid "$uuid" --arg password "$password" --arg path "/$path" --arg private "$private" --arg public "$public" --arg sid "$sid" '
    {id:$id,preset:$preset,listen:"0.0.0.0",port:$port,
     endpoint:{addresses:[$a],port:$p,mode:"direct",sni:"",host:""},
     auth:{uuid:$uuid,password:$password,username:"user",private_key:$private,public_key:$public,short_id:$sid},
     tls:{kind:"none"},ws_path:$path,reality:{server:"",port:443},outbound:"direct"}'
}
render_config() {
  jq --argjson protocols "$(protocols)" '
    def inbound:
      . as $n | ($protocols[]|select(.id==$n.preset)) as $p |
      {tag:.id,listen:(if .listen=="dual" then "::" else .listen end),listen_port:.port} +
      (if .preset=="reality" then {type:"vless",users:[{uuid:.auth.uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:.endpoint.sni,reality:{enabled:true,handshake:{server:.reality.server,server_port:.reality.port},private_key:.auth.private_key,short_id:[.auth.short_id]}}}
       elif .preset=="vless-ws" then {type:"vless",users:[{uuid:.auth.uuid}]}
       elif .preset=="vmess-ws" then {type:"vmess",users:[{uuid:.auth.uuid}]}
       elif .preset=="ss2022" then {type:"shadowsocks",method:"2022-blake3-aes-256-gcm",password:.auth.password}
       elif .preset=="snell" then {type:"snell",version:6,psk:.auth.password}
       elif .preset=="socks" then {type:"socks",users:[{username:.auth.username,password:.auth.password}]}
       elif .preset=="tuic" then {type:"tuic",users:[{uuid:.auth.uuid,password:.auth.password}],congestion_control:"bbr"}
       else {type:(if .preset=="trojan-ws" then "trojan" else .preset end),users:[{password:.auth.password}]} end) +
      (if ($p.tls|not) then {} else
        {tls:{enabled:true,server_name:.endpoint.sni,certificate:.tls.certificate,key:.tls.key,
         alpn:(if $p.network=="udp" then ["h3"] elif $p.ws then ["http/1.1"] else [] end)}} end) +
      (if $p.ws then {transport:{type:"ws",path:.ws_path}} else {} end);
    {log:{disabled:true},
     inbounds:[.nodes[] | . as $n | inbound | .,
       (if $n.listen=="dual" then .+{tag:($n.id+"--v4"),listen:"0.0.0.0"} else empty end)],
     outbounds:([{type:"direct",tag:"direct"}]+.outbounds),
     route:{final:"direct",rules:[.nodes[]|select(.outbound!="direct")|
       {inbound:([.id]+(if .listen=="dual" then [.id+"--v4"] else [] end)),action:"route",outbound:.outbound}]}}
  ' "$1" > "$2"
}
