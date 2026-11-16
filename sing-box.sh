#!/usr/bin/env bash
SB_SOURCE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while IFS= read -r module; do
  [[ -n $module && $module != \#* ]] || continue
  # shellcheck source=/dev/null
  source "$SB_SOURCE/src/$module" || exit 1
done < "$SB_SOURCE/src/modules.list"
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
