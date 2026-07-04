#!/usr/bin/env bash
# spec-abandon-empty.sh: Guarded sweep that retires a never-authored SPEC
# draft to the terminal `abandoned` ledger status. A ghost draft (a row
# allocated but never touched: no SPEC.md, no draft cache, no gate-1 snapshot)
# would otherwise re-surface on every /gaia-spec resume prompt forever; this
# pass gives it a terminal home once it is unambiguously never-authored.
#
# Double guard, BOTH required:
#   - Emptiness (primary): no SPEC.md, no draft-<id>.md cache, no
#     gate1-<id>.json snapshot. Any one of these present means authored
#     content exists; never sweep it, this is what keeps a paused-but-authored
#     session safe (SPEC never-boundary).
#   - Age (secondary): allocated_at is older than the guard age (~1 day). A
#     session paused moments after allocation is briefly "empty" too; age is
#     what tells that apart from a genuinely abandoned draft. An unparseable
#     or missing allocated_at is treated as NOT aged, never guessed.
#
# Epoch math is jq-only (`now`, `fromdateiso8601`), never `date -d`/`date -j`,
# mirroring token-tally.sh's cross-platform rule (see its header comment): the
# `date` binary parses no timestamp here, so behavior is identical on macOS
# and Linux CI.
#
# Usage:
#   spec-abandon-empty.sh <repo_root>
#
# Best-effort and fail-open, exactly like spec-reconcile.sh: a missing jq /
# ledger, an unparseable timestamp, or a ledger-update failure never blocks a
# caller. Prints one summary line to stdout when it flips any row, silent
# otherwise; diagnostics go to stderr.
#
# Exit: always 0 (advisory).
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: spec-abandon-empty.sh <repo_root>" >&2
  exit 0
fi

repo_root="${1%/}"
ledger_path="${repo_root}/.gaia/local/specs/ledger.json"
specs_dir="${repo_root}/.gaia/local/specs"
cache_dir="${repo_root}/.gaia/local/cache"
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GUARD_AGE_SECONDS=86400

# No ledger or no jq → nothing to do.
[ -f "$ledger_path" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Aged draft ids only (local, cheap): status == draft AND allocated_at parses
# to older than the guard age. An unparseable/missing allocated_at is
# excluded here rather than guessed at.
aged_ids="$(jq -r --argjson guard "$GUARD_AGE_SECONDS" '
  def toe: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  now as $now
  | .specs[]
  | select(.status == "draft")
  | select(
      (.allocated_at // "") as $ts
      | ($ts | try toe catch null) as $epoch
      | $epoch != null and ($now - $epoch) > $guard
    )
  | .id
' "$ledger_path" 2>/dev/null || true)"
[ -n "$aged_ids" ] || exit 0

now_ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
abandoned_list=""

while IFS= read -r id; do
  [ -n "$id" ] || continue

  # Emptiness guard: no SPEC.md, no draft cache, no gate-1 snapshot. Any one
  # present means authored content exists; leave the row alone.
  [ -f "${specs_dir}/${id}/SPEC.md" ] && continue
  [ -f "${cache_dir}/draft-${id}.md" ] && continue
  [ -f "${cache_dir}/gate1-${id}.json" ] && continue

  patch="$(jq -nc --arg ts "$now_ts" '{status: "abandoned", abandoned_at: $ts}')"
  if bash "${_lib_dir}/ledger-update.sh" "$repo_root" "$id" "$patch" >/dev/null 2>&1; then
    abandoned_list="${abandoned_list:+$abandoned_list, }${id}"
  fi
done <<EOF
$aged_ids
EOF

[ -n "$abandoned_list" ] || exit 0

count="$(printf '%s' "$abandoned_list" | awk -F', ' '{print NF}')"
printf 'Abandoned %s never-authored draft(s): %s\n' "$count" "$abandoned_list"

exit 0
