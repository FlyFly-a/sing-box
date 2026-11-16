put_node() {
  local file=$1 mode=${2:-add} id preset port oldport oldpreset
  id=$(jq -er .id "$file") && valid_id "$id" || return 1
  preset=$(jq -er .preset "$file") && port=$(jq -er .port "$file") && valid_port "$port" || return 1
  if [[ $mode == add ]]; then
    jq -e --arg id "$id" 'any(.nodes[];.id==$id) or any(.outbounds[];.tag==$id)' "$SB_TXN/state.json" >/dev/null && { err '名称已存在。'; return 1; }
  else
    jq -e --arg id "$id" 'any(.nodes[];.id==$id)' "$SB_TXN/state.json" >/dev/null || return 1
  fi
  oldport=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.port' "$SB_TXN/state.json")
  oldpreset=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.preset' "$SB_TXN/state.json")
  if [[ $port != "$oldport" || $preset != "$oldpreset" ]]; then
    port_free "$port" "$preset" "$id" || { err '监听端口与已有节点或系统服务冲突。'; return 1; }
  fi
  state_change '.nodes = ([.nodes[]|select(.id!=$n[0].id)]+$n)' --slurpfile n "$file"
}
put_outbound() {
  local file=$1 mode=${2:-add} id
  jq -e 'type=="object" and (.tag|type=="string") and (.type|type=="string") and (.tls.insecure//false|not)' "$file" >/dev/null || { err '需要包含 type/tag 的单个出站对象；TLS 不能跳过校验。'; return 1; }
  id=$(jq -er .tag "$file"); valid_id "$id" || return 1
  if [[ $mode == add ]]; then
    jq -e --arg id "$id" 'any(.nodes[];.id==$id) or any(.outbounds[];.tag==$id)' "$SB_TXN/state.json" >/dev/null && { err '名称已存在。'; return 1; }
  else jq -e --arg id "$id" 'any(.outbounds[];.tag==$id)' "$SB_TXN/state.json" >/dev/null || return 1; fi
  state_change '.outbounds=([.outbounds[]|select(.tag!=$o[0].tag)]+$o)' --slurpfile o "$file"
}
delete_resource() {
  local kind=$1 id=$2
  valid_id "$id" || return 1
  if [[ $kind == node ]]; then
    jq -e --arg id "$id" 'any(.nodes[];.id==$id)' "$SB_TXN/state.json" >/dev/null || return 1
    state_change '.nodes|=map(select(.id!=$id))' --arg id "$id"
  elif [[ $kind == outbound ]]; then
    jq -e --arg id "$id" 'any(.outbounds[];.tag==$id)' "$SB_TXN/state.json" >/dev/null || return 1
    if jq -e --arg id "$id" 'any(.outbounds[];.detour==$id or ((.outbounds//[])|index($id))!=null)' "$SB_TXN/state.json" >/dev/null; then err '其他出站引用了此出口；请先修改链式/选择器关系。'; return 1; fi
    state_change '.outbounds|=map(select(.tag!=$id)) | .nodes|=map(if .outbound==$id then .outbound="direct" else . end)' --arg id "$id"
  else return 1; fi
}
bind_nodes() {
  local out=$1; shift
  local selected id
  [[ $out == direct ]] || valid_id "$out" || return 1
  if [[ $out != direct ]]; then jq -e --arg o "$out" 'any(.outbounds[];.tag==$o)' "$SB_TXN/state.json" >/dev/null || return 1; fi
  (($#>0)) || return 1
  if [[ $1 == all && $# == 1 ]]; then selected=$(jq -c '[.nodes[].id]' "$SB_TXN/state.json")
  else
    for id in "$@"; do valid_id "$id" && jq -e --arg id "$id" 'any(.nodes[];.id==$id)' "$SB_TXN/state.json" >/dev/null || return 1; done
    selected=$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]|unique')
  fi
  state_change '.nodes|=map(. as $n|if ($ids|index($n.id))!=null then .outbound=$o else . end)' --arg o "$out" --argjson ids "$selected"
}
list_nodes() {
  local file
  file=$(state_file) || { say '暂无节点。'; return 0; }
  jq -r '.nodes[]|"\(.id)  \(.preset)\n  监听 \(.listen):\(.port) → 公网 \(.endpoint.addresses|join(",")):\(.endpoint.port)\n  出口 \(.outbound)；证书 \(.tls.kind)；模式 \(.endpoint.mode)"' "$file"
}
list_outbounds() {
  local file; file=$(state_file) || return 0
  jq -r '.outbounds[]|"\(.tag)  \(.type)  \(.server):\(.server_port)  detour=\(.detour//"direct")"' "$file"
}
show_links() {
  local id=${1:-all} file node domain temp
  file=$(state_file) || return 1
  jq -e --arg id "$id" 'any(.nodes[];$id=="all" or .id==$id)' "$file" >/dev/null || { err '没有匹配的节点。'; return 1; }
  domain=$(jq -r '.defaults.domain//""' "$file")
  temp=$(mktemp) || return 1
  while IFS= read -r node; do
    printf '%s\n' "$node" > "$temp"
    if [[ $(jq -r .endpoint.mode "$temp") == cdn ]]; then link_export "$temp" || { rm -f "$temp"; return 1; }
    else link_export "$temp" "$domain" || { rm -f "$temp"; return 1; }; fi
  done < <(jq -c --arg id "$id" '.nodes[]|select($id=="all" or .id==$id)' "$file")
  rm -f "$temp"
}
client_config() (
  # A complete minimal sing-box client; explicit export contains credentials.
  local id=$1 file temp link domain preset
  valid_id "$id" || return 1
  file=$(state_file) || return 1
  temp=$(mktemp -d) || return 1
  trap 'rm -rf "$temp"' EXIT
  jq -e --arg id "$id" '.nodes[]|select(.id==$id)' "$file" > "$temp/node.json" || return 1
  domain=$(jq -r '.defaults.domain' "$file")
  [[ $(jq -r .endpoint.mode "$temp/node.json") != cdn ]] || domain=''
  node_set "$temp/node.json" '.endpoint.addresses=[.endpoint.addresses[0]]' || return 1
  preset=$(jq -r .preset "$temp/node.json")
  if [[ $preset == snell ]]; then
    jq --arg d "$domain" '{type:"snell",tag:"proxy",server:(if $d!="" then $d else .endpoint.addresses[0] end),server_port:.endpoint.port,version:6,psk:.auth.password}' "$temp/node.json" > "$temp/out.json" || return 1
  else
    link=$(link_export "$temp/node.json" "$domain") || return 1
    link_parse "$link" proxy > "$temp/out.json" || return 1
  fi
  if [[ $(jq -r .tls.kind "$temp/node.json") == self ]]; then
    node_set "$temp/out.json" '.tls.certificate=$n[0].tls.certificate' --slurpfile n "$temp/node.json" || return 1
  fi
  jq -n --slurpfile o "$temp/out.json" '{log:{disabled:true},inbounds:[{type:"mixed",tag:"local",listen:"127.0.0.1",listen_port:2080}],outbounds:$o,route:{final:"proxy"}}' > "$temp/client.json" || return 1
  check_core "$temp/client.json" || return 1
  cat "$temp/client.json"
)
export_certificate() {
  local id=$1 file; valid_id "$id" || return 1; file=$(state_file) || return 1
  jq -er --arg id "$id" '.nodes[]|select(.id==$id)|.tls.certificate[]' "$file"
}
set_domain() {
  local domain=$1
  [[ -z $domain ]] || valid_domain "$domain" || return 1
  state_change '.defaults.domain=$d' --arg d "$domain"
}
mutate() {
  txn_begin || return 1
  "$@" && txn_commit || { txn_abort; return 1; }
}
import_nodes() {
  local file=$1 item
  jq -e 'type=="array" and length>0' "$file" >/dev/null || return 1
  while IFS= read -r item; do
    printf '%s\n' "$item" > "$SB_TXN/import-node.json"
    put_node "$SB_TXN/import-node.json" || return 1
  done < <(jq -c '.[]' "$file")
  rm -f "$SB_TXN/import-node.json"
}
set_detour() {
  local id=$1 target=$2
  valid_id "$id" || return 1
  [[ $target == direct ]] || valid_id "$target" || return 1
  jq -e --arg id "$id" 'any(.outbounds[];.tag==$id)' "$SB_TXN/state.json" >/dev/null || return 1
  state_change '.outbounds|=map(if .tag==$id then (if $target=="direct" then del(.detour) else .detour=$target end) else . end)' --arg id "$id" --arg target "$target"
}
