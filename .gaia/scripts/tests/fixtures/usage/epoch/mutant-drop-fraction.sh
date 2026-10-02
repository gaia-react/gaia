#!/usr/bin/env bash
# Mutant for usage-memo-identity.bats: copies a usage-resolve-lib.sh with the
# fraction term of the usage_epoch fast path dropped, so a whole-second Z stamp
# still agrees with the slow path and every stamp carrying a fraction does not.
# Usage: mutant-drop-fraction.sh <source-library> <destination-library>. Exits 1 when the
# substitution did not happen, so a reworded fast path cannot leave the guard
# comparing a copy of the lib with itself.
set -eu
source_library="$1" destination_library="$2"
sed 's@(if length > 20 then ("0" + \.\[19:-1\] | tonumber) else 0 end)@0@' "$source_library" >"$destination_library"
if cmp -s "$source_library" "$destination_library"; then
  printf 'mutant-drop-fraction: the fast-path fraction term is not in %s\n' "$source_library" >&2
  exit 1
fi
