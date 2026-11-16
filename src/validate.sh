validate_state() {
  jq -e --argjson protocols "$(protocols)" '
    def id: type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") and .!="direct" and (endswith("--v4")|not);
    def port: type=="number" and floor==. and .>=1 and .<=65535;
    def host: type=="string" and length>0 and (test("[[:space:]/\\\\\\[\\]?#@]")|not);
    def text: type=="string" and length>0 and all(explode[];.>=32 and .!=127);
    def uuid: type=="string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
    def walkchain($outs;$tag;$seen):
      if $tag=="direct" then true
      elif ($seen|index($tag))!=null then false
      else ([$outs[]|select(.tag==$tag)]|first) as $o |
        if $o==null then false else
          all(([$o.detour//"direct"]+($o.outbounds//[]))[];walkchain($outs;.;$seen+[$tag])) end end;
    . as $s |
    type=="object" and (.nodes|type=="array") and (.outbounds|type=="array") and (.defaults.domain|type=="string") and
    ([.nodes[].id,.outbounds[].tag]|length)==([.nodes[].id,.outbounds[].tag]|unique|length) and
    all(.nodes[];
      . as $n | ([$protocols[]|select(.id==$n.preset)]|first) as $p |
      (.id|id) and $p!=null and
      (.port|port) and (.endpoint.port|port) and (.endpoint.addresses|type=="array" and length>0 and length<=2 and length==(unique|length)) and all(.endpoint.addresses[];host) and
      (.listen|IN("0.0.0.0","::","127.0.0.1","::1","dual")) and
      (.endpoint.mode|IN("direct","cdn")) and
      (if .endpoint.mode=="cdn" then $p.ws and (.endpoint.port|IN(443,2053,2083,2087,2096,8443)) and (.tls.kind|IN("public","origin")) and
        (.endpoint.addresses==[.endpoint.sni]) and .endpoint.host==.endpoint.sni else .tls.kind!="origin" end) and
      (if $p.tls then (.tls.kind|IN("public","origin","self")) and
        (.tls.certificate|type=="array" and length>0 and all(.[];type=="string" and length>0)) and
        (.tls.key|type=="array" and length>0 and all(.[];type=="string" and length>0)) else .tls.kind=="none" end) and
      (if $p.ws then (.ws_path|text and startswith("/") and (test("[[:space:]#]")|not)) and (.endpoint.host|host) else true end) and
      (if (.preset|IN("reality","vless-ws","vmess-ws","tuic")) then (.auth.uuid|uuid) else true end) and
      (if (.preset|IN("hysteria2","tuic","trojan","trojan-ws","anytls","socks")) then (.auth.password|text) else true end) and
      (if .preset=="socks" then (.auth.username|text) else true end) and
      (if .preset=="snell" then (.auth.password|text and utf8bytelength>=12 and utf8bytelength<=255 and (test("[[:space:],]")|not)) else true end) and
      (if .preset=="ss2022" then (.auth.password|type=="string" and test("^[A-Za-z0-9+/]{43}=$")) else true end) and
      (if .preset=="reality" then (.reality.port|port) and (.reality.server|host) and
        (.auth.private_key|type=="string" and test("^[A-Za-z0-9_-]{43}$")) and
        (.auth.public_key|type=="string" and test("^[A-Za-z0-9_-]{43}$")) and
        (.auth.short_id|type=="string" and test("^([0-9a-fA-F]{2}){1,8}$")) else true end) and
      walkchain($s.outbounds;.outbound;[])) and
    all(.outbounds[]; (.tag|id) and (.type|text) and (.tls.insecure//false|not) and walkchain($s.outbounds;.tag;[])) and
    ([.nodes[]|. as $n|{port,network:($protocols[]|select(.id==$n.preset)|.network)}] as $p |
      all(range(0;$p|length); . as $i | all(range($i+1;$p|length); . as $j |
        $p[$i].port!=$p[$j].port or ($p[$i].network!=$p[$j].network and $p[$i].network!="both" and $p[$j].network!="both"))))
  ' "$1" >/dev/null 2>&1 || err '状态不合法：检查字段、端口冲突、CDN 组合、出站引用或循环。'
}
check_core() {
  local diagnostic rc
  [[ -x $SB_BIN ]] || { err '尚未安装官方核心；配置未保存。'; return 1; }
  root_guard && mkdir -p "$SB_ROOT" && chmod 700 "$SB_ROOT" || return 1
  diagnostic=$(mktemp "$SB_ROOT/.check.XXXXXXXX") || return 1
  # Keep only the latest failure, separately from ordinary logs. It may contain secrets.
  if "$SB_BIN" check -c "$1" > "$diagnostic" 2>&1; then
    rm -f "$diagnostic"
  else
    rc=$?
    if chmod 600 "$diagnostic" && mv -f "$diagnostic" "$SB_ROOT/last-check-error.log"; then
      err '官方核心校验失败；使用 check-private failed 在私密终端查看本次错误。'
    else
      rm -f "$diagnostic"
      err '官方核心校验失败，且无法保存私密诊断。'
    fi
    return "$rc"
  fi
}
