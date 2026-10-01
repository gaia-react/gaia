#!/usr/bin/env bash
# Mutant for usage-memo-identity.bats: copies a usage-resolve-lib.sh with the
# fraction term of the usage_epoch fast path dropped, so a whole-second Z stamp
# still agrees with the slow path and every stamp carrying a fraction does not.
# Usage: mutant-drop-fraction.sh <src-lib> <dst-lib>. Exits 1 when the
# substitution did not happen, so a reworded fast path cannot leave the guard
# comparing a copy of the lib with itself.
set -eu
src="$1" dst="$2"
sed 's@(if length > 20 then ("0" + \.\[19:-1\] | tonumber) else 0 end)@0@' "$src" >"$dst"
if cmp -s "$src" "$dst"; then
  printf 'mutant-drop-fraction: the fast-path fraction term is not in %s\n' "$src" >&2
  exit 1
fi
