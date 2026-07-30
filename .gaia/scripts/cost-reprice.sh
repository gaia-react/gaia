#!/usr/bin/env bash
# cost-reprice.sh: one-off re-price of already-written cost.jsonl rows under the
# current rate table.
#
# A model absent from the rate table resolves to a null rate window, which
# `priced_row` maps to 0 for every one of that model's buckets while still
# returning a well-formed row. Rows written during such a gap therefore carry a
# `dollars` that is confidently wrong: zero when the run used only the missing
# model, and a plausible non-zero figure silently missing that model's share when
# the run mixed models. Adding the row to the table fixes the next run, not the
# rows already on disk.
#
# The correction needs no transcript: every row persists its raw per-model
# `by_model` buckets alongside its own `ts`, which is the pairing token-tally.sh
# documents as existing precisely so a reader can re-price under a different
# card. Each row resolves its rate window from its OWN `ts`, so running this
# after an introductory window has closed still prices each row at the rate that
# was in force when it was written; no date-freezing logic is involved.
#
# Usage: cost-reprice.sh [<repo_root>] [--ledger <path>] [--rate-table <path>] [--dry-run]
#
# Guarantees:
#   - A row whose recomputed figure equals its stored one is passed through
#     BYTE-identical. Only rows that actually change are re-serialized.
#   - A line that does not parse as JSON is passed through byte-identical. No
#     row is ever dropped or reordered; the output has the same line count.
#   - The pre-rewrite ledger is copied to `<ledger>.bak.<epoch>` before the
#     replace. The ledger is machine-local and gitignored, so this backup is the
#     only undo that exists.
#   - The replace is atomic (write temp in the same dir, then mv) and runs under
#     the shared cost mutex when available, since a rewrite is a genuine
#     read-modify-write against a file concurrent tallies append to.
#   - Exit is non-zero on a real failure (unresolvable ledger or table, write
#     failure). Unlike the advisory cost-backfill.sh this is invoked by hand, so
#     a silent failure would be read as "nothing needed changing".
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/token-pricing-lib.sh
. "$SELF_DIR/token-pricing-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$SELF_DIR/ledger-path-lib.sh" 2>/dev/null || true
# shellcheck source=.specify/extensions/gaia/lib/with-ledger-lock.sh
. "$SELF_DIR/../../.specify/extensions/gaia/lib/with-ledger-lock.sh" 2>/dev/null || true

log() { printf '%s\n' "$*" >&2; }

# hash16 / rate_table_id mirror token-tally.sh's own definitions (which live
# inside that executable, not in a sourceable lib) so a re-priced row's
# rate_table_id is computed exactly the way the writer computes it.
hash16() {
  local out
  if out="$(shasum -a 256 2>/dev/null)"; then :;
  elif out="$(sha256sum 2>/dev/null)"; then :;
  else return 1; fi
  out="${out%% *}"
  [ -z "$out" ] && return 1
  printf '%s' "${out:0:16}"
}

rate_table_id() {
  local path="$1" h
  [ -f "$path" ] || return 1
  h="$(hash16 <"$path")" || return 1
  [ -z "$h" ] && return 1
  printf 'sha256:%s' "$h"
}

# ---------- args ----------
repo_root=""
ledger_override=""
rate_table_override=""
dry_run=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger)     ledger_override="${2:-}"; shift 2 ;;
    --rate-table) rate_table_override="${2:-}"; shift 2 ;;
    --dry-run)    dry_run=true; shift ;;
    *)
      if [ -z "$repo_root" ]; then repo_root="$1"; else log "cost-reprice: ignoring unexpected argument: $1"; fi
      shift ;;
  esac
done

if [ -z "$repo_root" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$repo_root" ] || repo_root="$PWD"
fi
repo_root="${repo_root%/}"

ledger="$(gaia_resolve_ledger_path "$ledger_override" 2>/dev/null)"
if [ -z "$ledger" ] || [ ! -f "$ledger" ]; then
  log "cost-reprice: no readable ledger (${ledger:-unresolved}); nothing to do"
  exit 1
fi

rt="$(gaia_resolve_rate_table "$rate_table_override" 2>/dev/null)"
if [ -z "$rt" ]; then
  log "cost-reprice: could not resolve a rate table"
  exit 1
fi
if ! rates="$(gaia_load_rate_table "$rt")"; then
  log "cost-reprice: rate table unreadable or malformed: $rt"
  exit 1
fi
rtid="$(rate_table_id "$rt" 2>/dev/null || true)"
if [ -z "$rtid" ]; then
  log "cost-reprice: could not compute the rate table's identity: $rt"
  exit 1
fi

# ---------- classify every line in one pass ----------
# -R reads each line as a raw string, so a line this pass leaves alone is
# reproduced from the ORIGINAL bytes rather than re-serialized by jq. A row is a
# candidate only when it parses, carries attribution, and already holds a
# numeric dollars; anything else is passed through untouched.
classified="$(jq -R -c --argjson rates "$rates" --arg rtid "$rtid" \
  "$GAIA_PRICING_JQ_DEFS"'
    . as $raw
    | (try ($raw | fromjson) catch null) as $row
    | if ($row | type) != "object"
         or (($row.by_model // {}) | length) == 0
         or (($row.dollars | type) != "number")
      then {changed: false, line: $raw}
      else
        priced_row($row) as $p
        | if $p.dollars == $row.dollars and ($row.unpriced // []) == $p.unpriced
          then {changed: false, line: $raw}
          else
            { changed: true,
              ts: ($row.ts // ""),
              kind: ($row.kind // "?"),
              before: $row.dollars,
              after: $p.dollars,
              line: ( ($row + {dollars: $p.dollars, rate_table_id: $rtid})
                      | if ($p.unpriced | length) > 0 then .unpriced = $p.unpriced else del(.unpriced) end
                      | tojson )
            }
          end
      end
  ' "$ledger" 2>/dev/null)"

if [ -z "$classified" ]; then
  log "cost-reprice: could not classify ledger rows; leaving $ledger untouched"
  exit 1
fi

changed_count="$(printf '%s\n' "$classified" | jq -s '[.[] | select(.changed)] | length')"
total_count="$(printf '%s\n' "$classified" | jq -s 'length')"

printf '%s\n' "$classified" \
  | jq -r 'select(.changed) | "  reprice: \(.ts) \(.kind)  $\(.before) -> $\(.after)"'

if [ "$changed_count" -eq 0 ]; then
  printf 'cost-reprice: 0 row(s) re-priced (%s scanned); ledger already current.\n' "$total_count"
  exit 0
fi

if [ "$dry_run" = "true" ]; then
  printf 'cost-reprice: %s row(s) would be re-priced of %s scanned (dry run: nothing written).\n' \
    "$changed_count" "$total_count"
  exit 0
fi

# ---------- back up, then replace atomically under the cost mutex ----------
telemetry_dir="$(dirname "$ledger")"
backup="$ledger.bak.$(date -u +%Y%m%dT%H%M%SZ)"
if ! cp "$ledger" "$backup" 2>/dev/null; then
  log "cost-reprice: could not write backup $backup; refusing to rewrite"
  exit 1
fi

_cost_reprice_write() {
  local tmp
  tmp="$(mktemp "$telemetry_dir/.cost-reprice.XXXXXX")" || return 1
  if ! printf '%s\n' "$classified" | jq -r '.line' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # Same-directory rename: atomic, so a reader never observes a partial ledger.
  mv "$tmp" "$ledger" || { rm -f "$tmp"; return 1; }
  return 0
}

rc=0
if declare -f with_ledger_lock >/dev/null 2>&1; then
  with_ledger_lock "$telemetry_dir" _cost_reprice_write || rc=$?
  if [ "$rc" -eq 75 ]; then
    log "cost-reprice: cost lock timed out; refusing to rewrite unlocked. Backup kept at $backup"
    exit 1
  fi
else
  _cost_reprice_write || rc=$?
fi

if [ "$rc" -ne 0 ]; then
  log "cost-reprice: rewrite failed; original ledger is intact. Backup at $backup"
  exit 1
fi

printf 'cost-reprice: %s row(s) re-priced of %s scanned. Backup: %s\n' \
  "$changed_count" "$total_count" "$backup"
exit 0
