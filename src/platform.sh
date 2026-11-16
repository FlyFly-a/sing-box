detect_arch() {
  local machine=${1:-$(uname -m)} bits=${2:-$(getconf LONG_BIT 2>/dev/null || printf 64)}
  case "$machine" in
    x86_64|amd64) if [[ $bits == 32 ]]; then printf 386; else printf amd64; fi;;
    aarch64|arm64) if [[ $bits == 32 ]]; then printf armv7; else printf arm64; fi;;
    i386|i486|i586|i686) printf 386;; armv7*|armv8l) printf armv7;; armv6*) printf armv6;; armv5*) printf armv5;;
    riscv64|s390x|ppc64le) printf '%s' "$machine";; loongarch64|loong64) printf loong64;; *) return 1;;
  esac
}
network_default() {
  if [[ -f $SB_PROC/net/if_inet6 && $(cat "$SB_PROC/sys/net/ipv6/conf/all/disable_ipv6" 2>/dev/null) != 1 ]]; then
    if [[ $(cat "$SB_PROC/sys/net/ipv6/bindv6only" 2>/dev/null) == 1 ]]; then printf dual; else printf '::'; fi
  else printf 0.0.0.0; fi
}
port_busy() {
  local port=$1 network=$2 file hex seen=0
  hex=$(printf '%04X' "$port")
  for file in "$SB_PROC/net/tcp" "$SB_PROC/net/tcp6" "$SB_PROC/net/udp" "$SB_PROC/net/udp6"; do
    [[ -r $file ]] || continue
    case "$network:$file" in tcp:*/udp*|udp:*/tcp*) continue;; esac
    seen=1
    awk -v port=":$hex" '$2~port"$" && ($4=="0A" || FILENAME~/udp/) {found=1} END {exit !found}' "$file" && return 0
  done
  if [[ $seen == 0 ]] && command -v ss >/dev/null 2>&1; then
    local flags=-lnt
    [[ $network != udp ]] || flags=-lnu
    [[ $network != both ]] || flags=-lntu
    local sockets
    sockets=$(ss "$flags" 2>/dev/null) || return 2
    awk -v p=":$port" '$4~p"$" {found=1} END {exit !found}' <<< "$sockets" && return 0
    return 1
  fi
  [[ $seen != 0 ]] || return 2
  return 1
}
port_free() {
  local port=$1 preset=$2 exclude=${3:-} state=${4:-$SB_TXN/state.json} network rc=0
  network=$(node_network "$preset") || return 2
  if [[ -f $state ]] && jq -e --argjson protocols "$(protocols)" --argjson p "$port" --arg n "$network" --arg ex "$exclude" '
    any(.nodes[]; .id!=$ex and .port==$p and
      (.preset as $p | ($protocols[]|select(.id==$p)|.network) as $t | $t==$n or $t=="both" or $n=="both"))' "$state" >/dev/null; then return 1; fi
  port_busy "$port" "$network" || rc=$?
  case "$rc" in 0) return 1;; 1) return 0;; *) return 2;; esac
}
free_port() {
  local preset=$1 p rc start=${SB_PORT_MIN:-10000} end=${SB_PORT_MAX:-59999}
  for ((p=start; p<=end; p++)); do
    rc=0; port_free "$p" "$preset" || rc=$?
    [[ $rc != 0 ]] || { printf '%s' "$p"; return 0; }
    [[ $rc != 2 ]] || { err '无法检查监听端口：/proc/net 和 ss 均不可用。'; return 1; }
  done
  err '没有可用监听端口。'; return 1
}
free_kb() { df -Pk "$1" | awk 'NR==2 {print $4}'; }
space_check() {
  local dir=$1 need=$2 available
  available=$(free_kb "$dir") || return 1
  [[ $available =~ ^[0-9]+$ ]] || { err '无法读取文件系统剩余空间。'; return 1; }
  ((available >= need)) || { err "安全操作需要剩余 ${need} KiB，实际 ${available} KiB；已中止。"; return 1; }
}
resources() {
  local f limit hostmem _group path controller rest dir effective cpu='unknown' quota period ratio
  hostmem=$(awk '/^MemTotal:/ {printf "%.0f",$2*1024}' "$SB_PROC/meminfo" 2>/dev/null)
  effective=$hostmem
  say "主机/容器视图 MemTotal(bytes): ${hostmem:-未知}"
  # Paths from /proc/self/cgroup cover non-root cgroup membership. Also inspect ancestors.
  if [[ -r $SB_PROC/self/cgroup ]]; then
    while IFS=: read -r _group controller path; do
      [[ $path != *..* ]] || continue
      if [[ -z $controller ]]; then dir=$SB_CGROUP$path
      elif [[ ,$controller, == *,memory,* ]]; then dir=$SB_CGROUP/memory$path
      elif [[ ,$controller, == *,cpu,* ]]; then
        dir=$SB_CGROUP/cpu$path
        [[ -d $dir ]] || dir=$SB_CGROUP/cpu,cpuacct$path
      else continue; fi
      while [[ $dir == "$SB_CGROUP"* ]]; do
        for f in memory.max memory.limit_in_bytes cpu.max cpu.cfs_quota_us cpu.cfs_period_us memory.current memory.usage_in_bytes; do
          if [[ -r $dir/$f ]]; then
            read -r limit rest < "$dir/$f"; say "$dir/$f = $limit ${rest:-}"
            if [[ $f == memory.max || $f == memory.limit_in_bytes ]] && [[ $limit =~ ^[0-9]{1,18}$ ]]; then
              if [[ -z $effective ]] || ((limit<effective)); then effective=$limit; fi
            fi
          fi
        done
        quota=''; period=''
        if [[ -r $dir/cpu.max ]]; then read -r quota period < "$dir/cpu.max"
        elif [[ -r $dir/cpu.cfs_quota_us && -r $dir/cpu.cfs_period_us ]]; then
          read -r quota < "$dir/cpu.cfs_quota_us"; read -r period < "$dir/cpu.cfs_period_us"
        fi
        if [[ $quota =~ ^[0-9]+$ && $period =~ ^[0-9]+$ ]] && ((period>0)); then
          ratio=$(awk -v q="$quota" -v p="$period" -v old="$cpu" 'BEGIN {v=q/p; if(old!="unknown" && old+0<v) v=old; printf "%.4f",v}')
          cpu=$ratio
        fi
        [[ $dir != "$SB_CGROUP" ]] || break
        dir=${dir%/*}
      done
    done < "$SB_PROC/self/cgroup"
  fi
  say "检测到的有效内存上限(bytes): ${effective:-未知}；CPU 配额(核): $cpu（不包含 cpuset 的进一步限制）"
  say '文件系统容量/已用/剩余（不保证等同 LXC 项目配额）：'
  df -Pk "$SB_ROOT" 2>/dev/null || true
  say '数据目录所在挂载（tmpfs 会占用内存；另核实宿主机磁盘配额）：'
  if command -v findmnt >/dev/null 2>&1; then findmnt -T "$SB_ROOT" -o TARGET,FSTYPE,OPTIONS; else say 'findmnt 不可用，请核查 /proc/self/mountinfo。'; fi
  [[ ! -f $SB_BIN ]] || { printf '核心文件字节数: '; wc -c < "$SB_BIN"; }
  say '以上仅为资源检测；没有测量吞吐或证明 128 MB 总配额可用。'
}
refresh_network() {
  local ip4='' ip6='' country='' data
  lock_acquire || return 1
  ip4=$(curl -4 -fsS --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null) || ip4=''
  ip6=$(curl -6 -fsS --connect-timeout 3 --max-time 6 https://api6.ipify.org 2>/dev/null) || ip6=''
  valid_address "$ip4" || ip4=''; valid_address "$ip6" || ip6=''
  data=$(curl -fsS --connect-timeout 3 --max-time 6 https://ipwho.is/ 2>/dev/null) || data='{}'
  country=$(jq -r '.country_code//"XX"' <<< "$data" 2>/dev/null) || country=XX
  [[ $country =~ ^[A-Z]{2}$ ]] || country=XX
  jq -n --arg v4 "$ip4" --arg v6 "$ip6" --arg country "$country" --arg at "$(date -u +%FT%TZ)" '{ipv4:$v4,ipv6:$v6,country:$country,queried_at:$at}' > "$SB_ROOT/network.next" && mv -f "$SB_ROOT/network.next" "$SB_ROOT/network.json"
  lock_release
  say '查询已结束（空地址表示失败），缓存不影响核心管理。'
}
