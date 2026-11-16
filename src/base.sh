# Runtime requirements: Bash >=4, jq >=1.6. No eval or sourced user state.
umask 077
set -o pipefail
SB_CORE_VERSION=1.14.4
SB_ROOT=${SB_ROOT:-/etc/sb-manager}
SB_BIN=${SB_BIN:-$SB_ROOT/bin/sing-box}
SB_PROC=${SB_PROC:-/proc}
SB_CGROUP=${SB_CGROUP:-/sys/fs/cgroup}
SB_LOCKED=0
SB_TXN=''
SB_OLD=''
SB_SWITCHED=0
SB_WAS_RUNNING=0
SB_INSTALL_TMP=''
SB_CORE_PENDING=0
say() { printf '%s\n' "$*"; }
err() { printf '错误：%s\n' "$*" >&2; return 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "缺少 $1；请先执行 deps 或按文档安装依赖。"; }
jq_read() { jq -er "$@"; }
random_hex() { openssl rand -hex "${1:-16}"; }
new_uuid() { "$SB_BIN" generate uuid; }
valid_id() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && [[ $1 != direct && $1 != *--v4 ]]; }
valid_port() { [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && ((10#$1 > 0 && 10#$1 < 65536)); }
valid_domain() {
  local label d=${1:-}
  [[ ${#d} -le 253 && $d == *.* && $d != *[!A-Za-z0-9.-]* && ! $d =~ ^[0-9.]+$ ]] || return 1
  local IFS=.
  for label in $d; do
    [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
  [[ $d != .* && $d != *. && $d != *..* ]]
}
valid_address() {
  local a=${1:-} part
  [[ -n $a && $a != *[[:space:]/\\\[\]?#@]* ]] || return 1
  if [[ $a == *:* ]]; then
    valid_ipv6 "$a"
  elif [[ $a =~ ^[0-9.]+$ ]]; then
    [[ $a =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local IFS=.
    for part in $a; do [[ ${#part} -le 3 ]] && ((10#$part <= 255)) || return 1; done
  else valid_domain "$a"; fi
}
valid_ipv6() {
  local a=$1 tail group count=0 compressed=0
  [[ $a != *[!0-9a-fA-F:.]* && $a != *:::* ]] || return 1
  [[ $a != :* || $a == ::* ]] && [[ $a != *: || $a == *:: ]] || return 1
  if [[ $a == *.* ]]; then
    tail=${a##*:}; valid_address "$tail" || return 1
    a=${a%:*}:0000:0000
  fi
  if [[ $a == *::* ]]; then
    compressed=1; tail=${a#*::}; [[ $tail != *::* ]] || return 1
  else [[ $a != :* && $a != *: ]] || return 1; fi
  local IFS=:
  for group in $a; do
    [[ -n $group ]] || continue
    [[ $group =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    count=$((count+1))
  done
  if [[ $compressed == 1 ]]; then ((count<8)); else ((count==8)); fi
}
url_encode() { jq -rn --arg x "$1" '$x|@uri'; }
url_decode() {
  local s=$1 out='' hex ch
  while [[ -n $s ]]; do
    if [[ $s == %* ]]; then
      hex=${s:1:2}
      [[ $hex =~ ^[0-9A-Fa-f]{2}$ && $hex != 00 ]] || return 1
      printf -v ch '%b' "\\x$hex"; out+=$ch; s=${s:3}
    else out+=${s:0:1}; s=${s:1}; fi
  done
  printf '%s' "$out"
}
b64_encode() { printf '%s' "$1" | openssl base64 -A; }
b64_decode() {
  local s=${1//-/+}; s=${s//_/\/}
  [[ $s != *[!A-Za-z0-9+/=]* ]] || return 1
  case $((${#s}%4)) in 2) s+='==';; 3) s+='=';; 1) return 1;; esac
  printf '%s' "$s" | openssl base64 -d -A
}
event() {
  [[ -d $SB_ROOT ]] || return 0
  local size=0
  [[ ! -f $SB_ROOT/events.log ]] || size=$(wc -c < "$SB_ROOT/events.log")
  if ((size > 12000)); then mv -f "$SB_ROOT/events.log" "$SB_ROOT/events.log.1" || return 1; fi
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$SB_ROOT/events.log"
}
# Only prompts use this function. EOF and q never become a default value.
ask() {
  local __ask_name=$1 __ask_prompt=$2 __ask_default=${3:-} __ask_input
  printf '%s%s（q 取消）: ' "$__ask_prompt" "${__ask_default:+ [$__ask_default]}" >&2
  IFS= read -r __ask_input || return 130
  [[ $__ask_input != q ]] || return 130
  printf -v "$__ask_name" '%s' "${__ask_input:-$__ask_default}"
}
ask_valid() {
  local __valid_name=$1 __valid_prompt=$2 __valid_default=$3 __valid_check=$4 __valid_value
  while :; do
    ask __valid_value "$__valid_prompt" "$__valid_default" || return 130
    if "$__valid_check" "$__valid_value"; then printf -v "$__valid_name" '%s' "$__valid_value"; return 0; fi
    say '格式无效，请修正。' >&2
  done
}
confirm() { local answer; ask answer "$1，输入 yes 确认" '' || return 130; [[ $answer == yes ]]; }
ask_secret() {
  local __secret_name=$1 __secret_prompt=$2 __secret_existing=${3:-} __secret_value
  printf '%s（回车保留已有值，q 取消）: ' "$__secret_prompt" >&2
  if [[ -t 0 ]]; then IFS= read -rs __secret_value || return 130; printf '\n' >&2
  else IFS= read -r __secret_value || return 130; fi
  [[ $__secret_value != q ]] || return 130
  __secret_value=${__secret_value:-$__secret_existing}
  [[ -n $__secret_value ]] || { err '密码不能为空。'; return 1; }
  printf -v "$__secret_name" '%s' "$__secret_value"
}
