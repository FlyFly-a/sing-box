# One capability table drives menus, validation, rendering and port checks.
protocols() {
  cat <<'JSON'
[
 {"id":"reality","name":"VLESS-Reality-Vision","network":"tcp","tls":false,"ws":false},
 {"id":"vless-ws","name":"VLESS-WS","network":"tcp","tls":true,"ws":true},
 {"id":"hysteria2","name":"Hysteria2","network":"udp","tls":true,"ws":false},
 {"id":"tuic","name":"TUIC","network":"udp","tls":true,"ws":false},
 {"id":"trojan","name":"Trojan","network":"tcp","tls":true,"ws":false},
 {"id":"trojan-ws","name":"Trojan-WS","network":"tcp","tls":true,"ws":true},
 {"id":"anytls","name":"AnyTLS","network":"tcp","tls":true,"ws":false},
 {"id":"ss2022","name":"Shadowsocks-2022","network":"both","tls":false,"ws":false},
 {"id":"vmess-ws","name":"VMess-WS","network":"tcp","tls":true,"ws":true},
 {"id":"snell","name":"Snell-v6","network":"tcp","tls":false,"ws":false},
 {"id":"socks","name":"SOCKS5","network":"tcp","tls":false,"ws":false}
]
JSON
}
protocol_field() { protocols | jq -er --arg p "$1" --arg f "$2" '.[]|select(.id==$p)|.[$f]'; }
is_ws() { protocol_field "$1" ws >/dev/null; }
node_network() { protocol_field "$1" network; }
valid_nonempty() { [[ -n $1 && $1 != *$'\r'* && $1 != *$'\n'* ]]; }
valid_listen() { case "$1" in 0.0.0.0|::|127.0.0.1|::1|dual) return 0;; *) return 1;; esac; }
valid_mode() { [[ $1 == direct || $1 == cdn ]]; }
valid_path() { [[ $1 == /* && $1 != *[[:space:]]* && $1 != *'#'* ]]; }
valid_cdn_port() { case "$1" in 443|2053|2083|2087|2096|8443) return 0;; *) return 1;; esac; }
node_set() {
  local file=$1 filter=$2; shift 2
  jq "$@" "$filter" "$file" > "$file.next" && mv -f "$file.next" "$file"
}
