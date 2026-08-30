#!/usr/bin/env bash
# SC2016 is intentional: the awk program below is single-quoted so its field
# references reach awk as literal program text.
# shellcheck disable=SC2016
#
# stub-guard.sh: a fixture adopting the shared guard library by sourcing alone.
# It detects one trivial class, the literal token STUBCLASS, and carries no
# fixture discrimination and no pragma parsing of its own: every answer about
# whether a line is data, whether a pragma covers it, and whether the file was
# readable to the end comes from guard-awk-lib.sh. Its non-boilerplate body is
# budgeted at forty lines and the sibling suite asserts the count, so an adopter
# needing more machinery than this reds a test instead of quietly re-inventing a
# tokenizer.
#
# It calls gaia_scan_reset, gaia_scan_feed, gaia_scan_skip, gaia_scan_suppressed
# and gaia_scan_end. It deliberately does NOT call gaia_scan_prepass,
# gaia_scan_prepass_end, gaia_scan_pragma_here or gaia_scan_run_only: a
# single-pass adopter needs no prepass, reports on one surface so it has no
# off-surface pragma to name, and detects a class errexit arming does not reach.
# The conformance check is written against exactly that split.
#
# Usage: stub-guard.sh [file ...]. With no argument it takes the tracked bats
# set from the library, which is also what exercises the empty-surface error.

set -euo pipefail

_gaia_guard_lib_dir="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_lib_dir" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_lib_dir="."; fi
# This fixture sits two directories below the library, where a real guard sits
# beside it. Only the resolved directory differs from the block a guard carries.
_gaia_guard_lib_dir="$_gaia_guard_lib_dir/../.."
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_bats_files >/dev/null 2>&1 || {
  printf 'stub-guard: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}

readonly OWN_AWK='
BEGIN { gaia_scan_reset() }
{
  gaia_scan_feed($0, is_bats)
  if (gaia_scan_skip()) next
  if (index($0, "STUBCLASS") == 0) next
  if (gaia_scan_suppressed("stub-guard")) next
  printf "%s:%d: STUBCLASS\n", file, FNR
}
END { gaia_scan_end(file, is_bats, "stub-guard", 0, 1) }
'

if [ "$#" -eq 0 ]; then
  gaia_guard_bats_files stub-guard || exit 1
  set -- ${GAIA_GUARD_BATS_FILES[@]+"${GAIA_GUARD_BATS_FILES[@]}"}
fi

report=""
for f in "$@"; do
  [ -f "$f" ] || continue
  hits="$(awk -v file="$f" -v is_bats=1 -v scripts_dir="$_gaia_guard_lib_dir" \
              "$GAIA_GUARD_AWK$OWN_AWK" "$f")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  exit 1
fi

echo "stub-guard: clean" >&2
exit 0
