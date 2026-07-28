#!/usr/bin/env bash
# ledger-title-repair.sh: one-off, best-effort, idempotent repair of EXISTING
# ledger rows the U2/U3 go-forward stamping fixes do not touch (U2 + U3
# existing-row repair).
#
# Usage: ledger-title-repair.sh <repo_root>
#
# Part A -- re-derives each specs-ledger row's `intent` from its SPEC.md
#   (folder or archived/folder), through the shared title-normalize rule.
# Part B -- re-derives each plans-ledger row's `subject` from its recoverable
#   consolidated SUMMARY.md H1, PROGRESS.md, or README.md (folder or
#   archived/folder, the archived candidate being the legacy live-ledger
#   shape), else word-safe-trims the stored subject in place.
# Part C -- stamps `status: "merged"` on every plans-ledger row that is
#   already archived on disk but not yet marked merged, deriving
#   `merged_at` only from a real `cost.md` "generated <ts>" stamp; never
#   fabricated from the current time or from `allocated_at`.
#
# Guarantees:
#   - Exit code is ALWAYS 0 (advisory / fail-open); never blocks a caller.
#   - Prints one summary line per repaired/stamped row to stdout;
#     diagnostics go to stderr only.
#   - Best-effort and idempotent: a row already matching its derived value
#     (or already `merged`) is left untouched, so re-running produces no
#     further change.
#   - Never corrupts a row it cannot confidently repair: a row with no
#     recoverable source is skipped (specs) or word-safe-trimmed from its own
#     stored value in place (plans), never blanked.
set -uo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: ledger-title-repair.sh <repo_root>" >&2
  exit 0
fi

repo_root="${1%/}"

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./title-normalize.sh
. "${_lib_dir}/title-normalize.sh"
# shellcheck source=../../../../.gaia/scripts/ledger-path-lib.sh
. "${_lib_dir}/../../../../.gaia/scripts/ledger-path-lib.sh" 2>/dev/null || true

# repo_root names the tree this repair runs in; the ledgers and folders it
# reads are main's, because the state registry declares specs/ and plans/
# main-only. Best-effort by contract: an unresolvable main is one diagnostic
# and exit 0, nothing touched.
if ! specs_dir="$(gaia_resolve_specs_dir "$repo_root" 2>/dev/null)" || [ -z "$specs_dir" ]; then
  echo "ledger-title-repair: cannot resolve the main checkout for '$repo_root'; nothing repaired" >&2
  exit 0
fi
if ! plans_dir="$(gaia_resolve_plans_dir "$repo_root" 2>/dev/null)" || [ -z "$plans_dir" ]; then
  echo "ledger-title-repair: cannot resolve the main checkout for '$repo_root'; nothing repaired" >&2
  exit 0
fi

specs_ledger="$specs_dir/ledger.json"
plans_ledger="$plans_dir/ledger.json"

# ---------- Part A: specs `intent` repair ----------------------------------

repair_specs_intent() {
  [ -f "$specs_ledger" ] || return 0

  local ids id spec_md raw new_intent stored patch
  ids="$(jq -r '.specs[].id' "$specs_ledger" 2>/dev/null)"

  while IFS= read -r id; do
    [ -n "$id" ] || continue

    spec_md="$specs_dir/$id/SPEC.md"
    if [ ! -f "$spec_md" ]; then
      spec_md="$specs_dir/archived/$id/SPEC.md"
      [ -f "$spec_md" ] || continue
    fi

    # Byte-identical to the finalize-stamp snippet's rewritten awk (the
    # version WITHOUT the exit on the indented-line arm) so a SPEC's
    # go-forward stamp and its one-off repair stamp can never diverge.
    raw="$(awk '
      /^intent:[[:space:]]*\|/ { in_block=1; next }
      /^intent:[[:space:]]*[^|[:space:]]/ {
        sub(/^intent:[[:space:]]*/, ""); print; exit
      }
      in_block && /^[a-zA-Z_]+:/ { exit }
      in_block && /^[[:space:]]+[^[:space:]]/ {
        sub(/^[[:space:]]+/, ""); print
      }
    ' "$spec_md" 2>/dev/null || echo "")"

    new_intent="$(gaia_normalize_title "$raw")"
    [ -n "$new_intent" ] || continue

    stored="$(jq -r --arg id "$id" '.specs[] | select(.id == $id) | .intent // ""' "$specs_ledger" 2>/dev/null)"
    if [ "$new_intent" != "$stored" ]; then
      patch="$(jq -nc --arg i "$new_intent" '{intent: $i}')"
      bash "${_lib_dir}/ledger-update.sh" "$repo_root" "$id" "$patch" >/dev/null 2>&1 || true
      printf 'repaired specs intent: %s\n' "$id"
    fi
  done <<<"$ids"
}

# ---------- Part B: plans `subject` repair ----------------------------------

# Recovers a clean human title's raw prose from a consolidated SUMMARY.md,
# PROGRESS.md, or README.md. A leading closed "---" ... "---" YAML
# frontmatter block (the consolidated shape) is skipped first; the "# "
# H1 immediately following it is the recovered title, matching the same
# line wiki-promote reads (DP-004/CG-001), so title recovery and
# wiki-promote never disagree on the same artifact. Without frontmatter
# (the legacy live-ledger / archived shape has no consolidated H1), the
# original rule applies: skip any leading heading lines (e.g.
# "# PLAN-001 Summary") and blank lines, then collect the first paragraph
# of body prose that follows, stopping at the next blank line or heading
# (so a heading right after the paragraph, with no blank line between,
# does not pull in the next section).
_extract_plan_prose() {
  awk '
    NR == 1 && /^---$/ { in_fm = 1; has_fm = 1; next }
    in_fm { if ($0 ~ /^---$/) in_fm = 0; next }
    has_fm && !h1_done {
      if ($0 ~ /^[[:space:]]*$/) next
      h1_done = 1
      if ($0 ~ /^# /) {
        line = $0
        sub(/^# /, "", line)
        print line
        exit
      }
    }
    /^#/ { if (started) exit; next }
    /^Commit:[[:space:]]/ { if (started) exit; next }
    /^[[:space:]]*$/ { if (started) exit; next }
    { started = 1; print }
  ' "$1" 2>/dev/null
}

# Prints the recovered raw prose for <id> from the first candidate source
# that yields non-empty text; exit 1 if none is recoverable.
_recover_plan_source_text() {
  local id="$1" candidate raw
  for candidate in \
    "$plans_dir/$id/SUMMARY.md" \
    "$plans_dir/$id/PROGRESS.md" \
    "$plans_dir/$id/README.md" \
    "$plans_dir/archived/$id/SUMMARY.md" \
    "$plans_dir/archived/$id/README.md"; do
    [ -f "$candidate" ] || continue
    raw="$(_extract_plan_prose "$candidate")"
    if [ -n "$raw" ]; then
      printf '%s' "$raw"
      return 0
    fi
  done
  return 1
}

repair_plans_subject() {
  [ -f "$plans_ledger" ] || return 0

  local ids id raw new_subject stored patch
  ids="$(jq -r '.plans[].id' "$plans_ledger" 2>/dev/null)"

  while IFS= read -r id; do
    [ -n "$id" ] || continue

    stored="$(jq -r --arg id "$id" '.plans[] | select(.id == $id) | .subject // ""' "$plans_ledger" 2>/dev/null)"

    if raw="$(_recover_plan_source_text "$id")"; then
      new_subject="$(gaia_normalize_title "$raw")"
    else
      # No recoverable source: word-safe-trim the stored value itself. This
      # cannot re-grow lost text, but it never corrupts, and it removes a
      # mid-word cut by re-applying the bounded rule.
      new_subject="$(gaia_normalize_title "$stored")"
    fi

    if [ -n "$new_subject" ] && [ "$new_subject" != "$stored" ]; then
      patch="$(jq -nc --arg s "$new_subject" '{subject: $s}')"
      bash "${_lib_dir}/plan-ledger-update.sh" "$repo_root" "$id" "$patch" >/dev/null 2>&1 || true
      printf 'repaired plans subject: %s\n' "$id"
    fi
  done <<<"$ids"
}

# ---------- Part C: status stamp on existing archived PLAN rows ------------

# Prints the "generated <ts>" value of the LAST matching cost.md line (the
# last section's stamp), or empty if none is present.
_last_generated_ts() {
  awk '
    {
      gidx = index($0, "generated ")
      if (gidx > 0) ts = substr($0, gidx + length("generated "))
    }
    END { print ts }
  ' "$1" 2>/dev/null
}

repair_plans_status() {
  [ -f "$plans_ledger" ] || return 0

  local ids id status archived_dir cost_md merged_at patch
  ids="$(jq -r '.plans[].id' "$plans_ledger" 2>/dev/null)"

  while IFS= read -r id; do
    [ -n "$id" ] || continue

    case "$id" in
      PLAN-[0-9]*) ;;
      *) continue ;;
    esac

    archived_dir="$plans_dir/archived/$id"
    [ -d "$archived_dir" ] || continue

    status="$(jq -r --arg id "$id" '.plans[] | select(.id == $id) | .status // ""' "$plans_ledger" 2>/dev/null)"
    [ "$status" = "merged" ] && continue

    merged_at=""
    cost_md="$archived_dir/cost.md"
    if [ -f "$cost_md" ]; then
      merged_at="$(_last_generated_ts "$cost_md")"
    fi

    # Never fabricate a timestamp: if no cost.md "generated" stamp is
    # present, merged_at degrades to omitted, not allocated_at or "now".
    if [ -n "$merged_at" ]; then
      patch="$(jq -nc --arg st merged --arg ts "$merged_at" '{status: $st, merged_at: $ts}')"
    else
      patch="$(jq -nc --arg st merged '{status: $st}')"
    fi
    bash "${_lib_dir}/plan-ledger-update.sh" "$repo_root" "$id" "$patch" >/dev/null 2>&1 || true
    printf 'stamped plans status merged: %s\n' "$id"
  done <<<"$ids"
}

repair_specs_intent
repair_plans_subject
repair_plans_status

exit 0
