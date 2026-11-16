download() { curl --proto '=https' --tlsv1.2 -fL --connect-timeout 10 --max-time 300 --retry 2 -o "$2" "$1"; }
fetch_core_stream() (
  local url=$1 dest=$2 member=$3 maximum=$4 digest=$5 hash_pid='' actual rc=0
  # A short-lived checksum pipe avoids retaining the compressed archive on disk.
  # Only the exact member is emitted; archive paths are never extracted.
  trap '[[ -z $hash_pid ]] || kill "$hash_pid" 2>/dev/null || true' EXIT
  mkfifo "$SB_INSTALL_TMP/hash.pipe" || return 1
  sha256sum < "$SB_INSTALL_TMP/hash.pipe" > "$SB_INSTALL_TMP/digest" & hash_pid=$!
  curl --proto '=https' --tlsv1.2 -fL --connect-timeout 10 --max-time 300 "$url" |
    tee "$SB_INSTALL_TMP/hash.pipe" |
    (ulimit -f "$(((maximum+1023)/1024))" || exit 1; tar -xOzf - "$member") > "$dest" || rc=1
  wait "$hash_pid" || rc=1
  hash_pid=''
  [[ $rc == 0 ]] || return 1
  actual=$(cat "$SB_INSTALL_TMP/digest"); actual=${actual%% *}
  [[ $actual == "${digest#sha256:}" ]] || { err '官方资产摘要不匹配。'; return 1; }
  actual=$(wc -c < "$dest")
  ((actual>0 && actual<=maximum)) || return 1
  rm -f "$SB_INSTALL_TMP/hash.pipe" "$SB_INSTALL_TMP/digest"
)
dependencies() {
  local c missing=0 features
  for c in jq openssl curl tar gzip mkfifo tee sha256sum; do need "$c" || missing=1; done
  [[ $missing == 0 ]] || return 1
  jq -en '1|IN(1,2)' >/dev/null 2>&1 || { err '需要 jq 1.6 或更高版本。'; return 1; }
  features=$(openssl req -help 2>&1 || true)
  [[ $features == *-addext* ]] || { err 'OpenSSL 缺少 req -addext（通常需要 1.1.1+）；请使用受支持的发行版软件包。'; return 1; }
  features=$(openssl x509 -help 2>&1 || true)
  [[ $features == *-checkhost* ]] || { err 'OpenSSL 缺少 x509 -checkhost，无法安全检查证书域名。'; return 1; }
}
install_dependencies() {
  say '将安装 bash/jq/curl/openssl/tar/gzip/CA 证书。包管理器所需空间由发行版决定；不会清理其他软件缓存。'
  confirm '继续安装依赖' || return 130
  if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y --no-install-recommends bash jq curl openssl tar gzip ca-certificates
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache bash jq curl openssl tar gzip ca-certificates
  elif command -v dnf >/dev/null 2>&1; then dnf install -y --setopt=install_weak_deps=False bash jq curl openssl tar gzip ca-certificates
  elif command -v yum >/dev/null 2>&1; then yum install -y bash jq curl openssl tar gzip ca-certificates
  elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install --no-recommends bash jq curl openssl tar gzip ca-certificates
  elif command -v pacman >/dev/null 2>&1; then pacman -S --needed bash jq curl openssl tar gzip ca-certificates
  else err '未识别包管理器，请按发行版文档手动安装依赖。'; return 1; fi
  dependencies
}
save_manager() {
  if [[ ${SB_BUNDLED:-0} == 1 ]]; then
    [[ -n ${SB_BUNDLE_PAYLOAD:-} ]] || { err '单文件内容不完整，请重新下载脚本。'; return 1; }
    write_bundle "$SB_BUNDLE_PAYLOAD" > "$SB_ROOT/manager.next" || return 1
  else
    "$BASH" "$SB_SOURCE/build.sh" "$SB_ROOT/manager.next" >/dev/null || return 1
  fi
  "$BASH" -n "$SB_ROOT/manager.next" || return 1
  chmod 700 "$SB_ROOT/manager.next" && mv -f "$SB_ROOT/manager.next" "$SB_ROOT/manager.sh"
}
core_rollback() {
  service_stop || return 1
  if [[ -f $SB_BIN.old ]]; then mv -f "$SB_BIN.old" "$SB_BIN" || return 1
  elif [[ ${SB_INSTALL_HAD_CORE:-0} == 0 ]]; then rm -f "$SB_BIN"; fi
  SB_CORE_PENDING=0
  if [[ ${SB_INSTALL_RUNNING:-0} == 1 ]]; then service_start || return 1; fi
}
install_core() {
  local arch asset version=$SB_CORE_VERSION meta url digest size bound member unpacked generation tmpbin
  [[ $(uname -s) == Linux ]] || { err '安装只支持 Linux；开发机可用官方平台核心执行 check。'; return 1; }
  root_guard && dependencies && lock_acquire || return 1
  mkdir -p "$SB_ROOT/bin" || return 1
  arch=$(detect_arch) || { err '不支持当前架构。'; return 1; }
  [[ ! -e $SB_BIN.old && ! -e $SB_ROOT/pending ]] || { err '存在中断事务，请先执行 recover。'; return 1; }
  case "$arch" in amd64|arm64|386|armv7|riscv64|loong64) asset="sing-box-$version-linux-$arch-musl.tar.gz";; *) asset="sing-box-$version-linux-$arch.tar.gz";; esac
  SB_INSTALL_TMP=$(mktemp -d "$SB_ROOT/bin/.install.XXXXXXXX") || return 1
  meta=$SB_INSTALL_TMP/release.json
  download "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$version" "$meta" || return 1
  jq -e --arg v "v$version" '.tag_name==$v and .prerelease==false and .draft==false' "$meta" >/dev/null || { err '版本不是已选定的官方稳定发布。'; return 1; }
  url=$(jq -er --arg a "$asset" '.assets[]|select(.name==$a)|.browser_download_url' "$meta") || { err '官方未提供此平台资产；不自动换第三方核心。'; return 1; }
  digest=$(jq -er --arg a "$asset" '.assets[]|select(.name==$a)|.digest|select(startswith("sha256:"))' "$meta") || { err '发布资产无 SHA256 摘要，已停止安装。'; return 1; }
  size=$(jq -er --arg a "$asset" '.assets[]|select(.name==$a)|.size' "$meta") || return 1
  [[ $size =~ ^[0-9]{1,10}$ && $digest =~ ^sha256:[a-f0-9]{64}$ && $url == "https://github.com/SagerNet/sing-box/releases/download/v$version/$asset" ]] || { err '发布元数据格式不符合预期。'; return 1; }
  # amd64 musl measured from the checksum-verified 1.14.4 official archive.
  # Other architectures use a conservative 4x archive bound and a hard file limit.
  if [[ $arch == amd64 && $version == 1.14.4 ]]; then unpacked=92070560; else unpacked=$((size*4)); fi
  bound=$(((unpacked+1023)/1024+8192))
  # Remote du samples exceeded the logical-file model. Provision 128 MiB for
  # candidate allocation plus 8 MiB headroom pending finer filesystem evidence.
  # This is a preflight policy, not a guaranteed peak or a change to the file cap.
  if [[ $arch == amd64 && $version == 1.14.4 ]]; then bound=139264; fi
  space_check "$SB_ROOT/bin" "$bound" || return 1
  say "下载前空间门槛：额外 $bound KiB（候选核心及分配余量；压缩包不落盘、旧核心保留；非峰值保证）。"
  member=${asset%.tar.gz}/sing-box
  tmpbin=$SB_INSTALL_TMP/sing-box
  fetch_core_stream "$url" "$tmpbin" "$member" "$unpacked" "$digest" || { err '流式下载、解压或摘要校验失败；有效核心保留。'; return 1; }
  chmod 700 "$tmpbin" || return 1
  "$tmpbin" version >/dev/null 2>&1 || { err '核心无法在当前架构/用户态运行；旧核心未替换。'; return 1; }
  generation=$(current_generation) || generation=''
  if [[ -n $generation ]]; then "$tmpbin" check -c "$generation/config.json" >/dev/null 2>&1 || { err '新核心不接受现有配置；旧核心未替换。'; return 1; }; fi
  save_manager || return 1
  service_register || return 1
  SB_INSTALL_RUNNING=0; service_running && SB_INSTALL_RUNNING=1
  if [[ $SB_INSTALL_RUNNING == 1 ]]; then service_stop || return 1; fi
  [[ ! -e $SB_BIN.old ]] || { err '发现未完成更新备份；请先恢复。'; return 1; }
  SB_INSTALL_HAD_CORE=0; [[ ! -f $SB_BIN ]] || SB_INSTALL_HAD_CORE=1
  SB_CORE_PENDING=1
  if [[ -f $SB_BIN ]]; then mv "$SB_BIN" "$SB_BIN.old" || return 1; fi
  mv "$tmpbin" "$SB_BIN" || { core_rollback; return 1; }
  if [[ $SB_INSTALL_RUNNING == 1 ]] && ! service_start; then core_rollback; err '新核心启动失败，已尝试恢复旧核心。'; return 1; fi
  SB_CORE_PENDING=0
  rm -f "$SB_BIN.old"
  rm -rf "$SB_INSTALL_TMP"; SB_INSTALL_TMP=''
  event 'official core installed/updated'
  lock_release
  say "官方核心 $version 已安装。已有运行服务已尝试恢复；新安装不会自动创建节点或启动服务。"
}
uninstall_core() {
  local mode=$1
  [[ $mode == keep || $mode == purge ]] || return 1
  confirm "卸载核心（$mode：keep 保留配置，purge 删除托管数据）" || return 130
  lock_acquire || return 1
  service_stop && service_unregister || return 1
  [[ $SB_BIN == "$SB_ROOT/bin/sing-box" ]] || { err '拒绝删除非托管核心路径。'; return 1; }
  rm -f "$SB_BIN" "$SB_BIN.old" "$SB_ROOT/manager.sh" || return 1
  lock_release
  if [[ $mode == purge ]]; then
    [[ $SB_ROOT == /etc/sb-manager ]] || { err '自定义目录不自动递归删除；核心已卸载，配置保留。'; return 1; }
    rm -rf -- "$SB_ROOT" || return 1
  fi
  say '卸载完成。'
}
