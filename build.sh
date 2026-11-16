#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
output=${1:-$root/dist/sing-box-oneclick.sh}
mkdir -p "$(dirname "$output")"
temp=$(mktemp "${output}.XXXXXXXX")
trap 'rm -f "$temp"' EXIT
payload=$(
  printf '%s\n' 'SB_BUNDLED=1'
  while IFS= read -r module; do
    [[ -n $module && $module != \#* ]] || continue
    cat "$root/src/$module"
    printf '\n'
  done < "$root/src/modules.list"
)
source "$root/src/bundle.sh"
write_bundle "$payload" > "$temp"
bash -n "$temp"
chmod 755 "$temp"
mv -f "$temp" "$output"
printf 'Built %s\n' "$output"
