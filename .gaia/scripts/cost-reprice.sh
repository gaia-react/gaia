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
# Usage: cost-reprice.sh [--ledger <path>] [--rate-table <path>] [--dry-run]
#
# The two resolvers this pairs do NOT answer about the same tree, which is why
# the run refuses a linked worktree outright:
#   - `gaia_resolve_ledger_path` goes through `gaia_resolve_main_root`, so it
#     always returns the MAIN checkout's cost.jsonl. There is one ledger; no
#     checkout has its own.
#   - `gaia_resolve_rate_table` is a bare `git rev-parse --show-toplevel`, so it
#     returns the CURRENT tree's token-rates.json.
# From a worktree those disagree, and the run would rewrite main's shared ledger
# under a table main is not on. A worktree branch predating a rate addition would
# re-price the corrected rows straight back down, stamp its own table id, and
# report success. So the guard is a refusal rather than a re-resolution: pricing
# against a table the operator is not looking at is the thing to avoid, not a
# detail to paper over.
#
# It takes no <repo_root> positional and refuses one rather than accepting an
# argument it would then ignore. Both paths are overridable for tests and for a
# deliberate run against another table (`--ledger`, `--rate-table`).
#
# Guarantees:
#   - A row whose recomputed figure equals its stored one is passed through
#     BYTE-identical. Only rows that actually change are re-serialized.
#   - A line that does not parse as JSON is passed through byte-identical. No
#     row is ever dropped or reordered; the output has the same line count, and
#     that count is CHECKED rather than assumed. jq reports a per-input runtime
#     error on stderr, emits nothing for that input, and still exits 0, so one
#     malformed bucket value would otherwise delete its row and report success.
#     A record count that disagrees with the ledger's line count refuses the
#     whole rewrite and prints what jq said.
#   - Two kinds of row that cannot be fully recomputed are passed through
#     byte-identical rather than rewritten, both because a partial recomputation
#     would overwrite a real stored figure with a confident-looking wrong one:
#       * a row whose own `ts` cannot anchor a rate window. `priced_row` reports
#         it as `missing_anchor` with a dollars of 0, which is an "unknown" and
#         not a recomputed zero.
#       * a row carrying any non-`claude-` bucket in `by_model`. `priced_row`
#         silently discards those buckets and still returns `unpriced: []`,
#         asserting a completeness it does not have.
#     No current writer emits either shape; a hand-edited, foreign, or legacy
#     ledger can, and that is exactly the population this script exists for.
#   - Classify, back up, and replace all run inside the shared cost mutex as ONE
#     critical section. The read half has to be in there too: a tally appending
#     between an unlocked classify and the replace is dropped outright, because
#     the rewrite emits only the lines classify saw, and a backup taken before
#     that window would not hold the lost row either. When the mutex helper is
#     unavailable the same section runs unlocked, which is the pre-existing
#     fallback, not a second design.
#   - The pre-rewrite ledger is copied to `<ledger>.bak.<UTC-timestamp>` before
#     the replace, with a numeric suffix appended if that path is already taken,
#     so a second run inside the same second cannot clobber the first run's copy.
#     The ledger is machine-local and gitignored, so this backup is the only undo
#     that exists.
#   - The replace is atomic: write a temp file in the same directory, then mv.
#   - Exit is non-zero on a real failure (unresolvable ledger or table, write
#     failure, lock timeout). An empty ledger is a success with nothing to do.
#     Unlike the advisory cost-backfill.sh this is invoked by hand, so a silent
#     failure would be read as "nothing needed changing".
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/token-pricing-lib.sh
. "$SELF_DIR/token-pricing-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$SELF_DIR/ledger-path-lib.sh" 2>/dev/null || true
# shellcheck source=.specify/extensions/gaia/lib/with-ledger-lock.sh
. "$SELF_DIR/../../.specify/extensions/gaia/lib/with-ledger-lock.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/main-only-lib.sh
. "$SELF_DIR/main-only-lib.sh" 2>/dev/null || true

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
ledger_override=""
rate_table_override=""
dry_run=false

usage() { log "Usage: cost-reprice.sh [--ledger <path>] [--rate-table <path>] [--dry-run]"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    # Each option checks its own operand is present before `shift 2`. Without
    # that check a trailing bare `--ledger` makes `shift 2` fail silently (there
    # is no `set -e`), leaving `$1` unchanged and the loop re-testing it forever:
    # a mute, output-free spin at 100% CPU from an ordinary typo.
    --ledger)
      [ "$#" -ge 2 ] || { log "cost-reprice: --ledger needs a path"; usage; exit 1; }
      ledger_override="$2"; shift 2 ;;
    --rate-table)
      [ "$#" -ge 2 ] || { log "cost-reprice: --rate-table needs a path"; usage; exit 1; }
      rate_table_override="$2"; shift 2 ;;
    --dry-run)    dry_run=true; shift ;;
    *)
      # No positional is accepted. Neither resolver below takes a root argument,
      # so a <repo_root> this script cannot honor gets refused rather than parsed
      # and dropped: a run that names one checkout, reports success, and rewrites
      # a different one is the worst outcome on offer, and this is the single
      # remediation step adopters are told to run by hand.
      log "cost-reprice: unexpected argument: $1"
      usage
      exit 1 ;;
  esac
done

# Main-checkout-only, for the resolver asymmetry the header describes: the ledger
# always resolves to the main checkout while the rate table resolves to whatever
# tree this is, so from a worktree the run would price main's shared ledger with a
# table main is not on. Skipped when both paths are given explicitly, since then
# neither resolver runs and there is no asymmetry to guard. Fails open on an
# unresolvable main root, which is the shared helper's own documented posture.
if [ -z "$ledger_override" ] || [ -z "$rate_table_override" ]; then
  if declare -f gaia_refuse_if_worktree >/dev/null 2>&1; then
    gaia_refuse_if_worktree "cost-reprice.sh" || exit 1
  fi
fi

ledger="$(gaia_resolve_ledger_path "$ledger_override" 2>/dev/null)"
if [ -z "$ledger" ] || [ ! -f "$ledger" ]; then
  log "cost-reprice: no readable ledger (${ledger:-unresolved}); nothing to do"
  exit 1
fi
if [ ! -s "$ledger" ]; then
  # Distinct from the classify failure below: an empty ledger is a well-formed
  # ledger with no rows, so it is a success with nothing to do. Exiting non-zero
  # here would report "a real failure" for the ordinary fresh-checkout case.
  printf 'cost-reprice: ledger is empty (%s); nothing to do.\n' "$ledger"
  exit 0
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

# ---------- the whole read-modify-write, as one critical section ----------
telemetry_dir="$(dirname "$ledger")"

# Classify, report, back up, and replace all live in here, because all four are
# one read-modify-write against a file concurrent tallies append to.
#
# This function emits every message it needs itself and lets only its return code
# cross back: with_ledger_lock's flock path runs its callback in a SUBSHELL, so a
# variable assigned in here (the row counts, the backup path) is invisible to the
# caller. Printing the summary outside would print counts from an unset variable
# on exactly the platforms that have flock.
#
# `-R` reads each line as a raw string, so a line this pass leaves alone is
# reproduced from the ORIGINAL bytes rather than re-serialized by jq. A row is a
# candidate only when it parses, carries attribution, already holds a numeric
# dollars, and can anchor a rate window; anything else passes through untouched.
# Surfaces the diagnostic jq wrote about a row it could not process. Without it
# the only trace of a dropped row is a record count that looks self-consistent.
_cost_reprice_report_jq_err() {
  local err="$1" total
  [ -s "$err" ] || return 0
  total="$(awk 'END{print NR}' "$err")"
  log "cost-reprice: jq reported $total diagnostic line(s), first 10:"
  head -n 10 "$err" >&2
  return 0
}

_cost_reprice_run() {
  local classified changed_count total_count expected_lines jq_err backup tmp n

  # The record count is an INVARIANT here, not a statistic. jq does not abort on
  # a runtime error raised for a single input: it reports the error on stderr,
  # emits nothing for that input, moves to the next one, and still exits 0. One
  # row whose by_model holds a quoted number is enough, and the resulting stream
  # is one entry short. A rewrite from that stream deletes the row outright,
  # while the summary, counted from the same short stream, reads as a clean
  # success. Checking jq's exit status cannot catch this; comparing the record
  # count against the ledger's own line count can. `awk END{print NR}` is the
  # right counter because it counts a final line with no trailing newline, which
  # is exactly what `jq -R` also reads as an input.
  #
  # Both counts are validated as digits before being compared. `[ x -ne y ]` on a
  # non-numeric operand does not fail the comparison, it errors and returns 2,
  # which `if` reads as false and falls straight through to the rewrite with no
  # count check at all. Every other guard in this script defaults to refusing, and
  # the one guarding against dropped rows must not be the exception.
  expected_lines="$(awk 'END{print NR}' "$ledger")"
  case "$expected_lines" in
    '' | *[!0-9]*)
      log "cost-reprice: could not count $ledger's lines (got '${expected_lines}'); refusing to rewrite"
      return 1 ;;
  esac

  if ! jq_err="$(mktemp "$telemetry_dir/.cost-reprice-err.XXXXXX")"; then
    log "cost-reprice: could not create a temp file in $telemetry_dir"
    return 1
  fi

  classified="$(jq -R -c --argjson rates "$rates" --arg rtid "$rtid" \
    "$GAIA_PRICING_JQ_DEFS"'
      # priced_row keeps only the `^claude-` buckets and neither prices nor
      # reports the rest: it returns `unpriced: []`, asserting completeness. So a
      # row carrying any non-claude bucket cannot be fully recomputed, and
      # re-pricing it would drop that bucket share while stamping the row with
      # the current rate_table_id, which is the silently-plausible figure this
      # whole change exists to remove. Such a row passes through untouched, its
      # stored figure and original table id intact, exactly like every other row
      # this script cannot fully price.
      # The `type` test comes first because `//` defaults only on null and false:
      # a by_model that is a string or an array reaches `keys` as a non-object and
      # raises a per-input jq error, which the record-count invariant below turns
      # into a refusal of the WHOLE rewrite. Per-row pass-through is the design,
      # so one hand-mangled row must not block every other row from re-pricing.
      def fully_priceable($bm):
        ($bm | type) == "object"
        and (($bm | keys) as $k
             | ($k | length) > 0
               and (($k | map(select(test("^claude-"))) | length) == ($k | length)));

      . as $raw
      | (try ($raw | fromjson) catch null) as $row
      | if ($row | type) != "object"
           or (fully_priceable($row.by_model // {}) | not)
           or (($row.dollars | type) != "number")
        then {changed: false, line: $raw}
        else
          priced_row($row) as $p
          | if $p.missing_anchor
               or ($p.dollars == $row.dollars and ($row.unpriced // []) == $p.unpriced)
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
    ' "$ledger" 2>"$jq_err")"

  if [ -z "$classified" ]; then
    log "cost-reprice: could not classify ledger rows; leaving $ledger untouched"
    _cost_reprice_report_jq_err "$jq_err"
    rm -f "$jq_err"
    return 1
  fi

  total_count="$(printf '%s\n' "$classified" | jq -s 'length')"
  case "$total_count" in
    '' | *[!0-9]*)
      log "cost-reprice: could not count the classified records (got '${total_count}'); refusing to rewrite"
      _cost_reprice_report_jq_err "$jq_err"
      rm -f "$jq_err"
      return 1 ;;
  esac
  if [ "$total_count" -ne "$expected_lines" ]; then
    log "cost-reprice: classify returned $total_count record(s) for $expected_lines ledger line(s)."
    log "cost-reprice: refusing to rewrite, which would drop $((expected_lines - total_count)) row(s). $ledger is untouched."
    _cost_reprice_report_jq_err "$jq_err"
    rm -f "$jq_err"
    return 1
  fi
  rm -f "$jq_err"

  changed_count="$(printf '%s\n' "$classified" | jq -s '[.[] | select(.changed)] | length')"

  printf '%s\n' "$classified" \
    | jq -r 'select(.changed) | "  reprice: \(.ts) \(.kind)  $\(.before) -> $\(.after)"'

  if [ "$changed_count" -eq 0 ]; then
    printf 'cost-reprice: 0 row(s) re-priced (%s scanned); ledger already current.\n' "$total_count"
    return 0
  fi

  if [ "$dry_run" = "true" ]; then
    printf 'cost-reprice: %s row(s) would be re-priced of %s scanned (dry run: nothing written).\n' \
      "$changed_count" "$total_count"
    return 0
  fi

  backup="$ledger.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -e "$backup" ]; then
    # Second granularity: two runs inside the same second would otherwise have
    # the second one overwrite the only copy of the first one's pre-image.
    n=2
    while [ -e "$backup.$n" ]; do n=$((n + 1)); done
    backup="$backup.$n"
  fi
  if ! cp "$ledger" "$backup" 2>/dev/null; then
    log "cost-reprice: could not write backup $backup; refusing to rewrite"
    return 1
  fi

  if ! tmp="$(mktemp "$telemetry_dir/.cost-reprice.XXXXXX")"; then
    log "cost-reprice: could not create a temp file in $telemetry_dir; ledger is intact. Backup at $backup"
    return 1
  fi
  if ! printf '%s\n' "$classified" | jq -r '.line' > "$tmp"; then
    rm -f "$tmp"
    log "cost-reprice: rewrite failed; original ledger is intact. Backup at $backup"
    return 1
  fi
  # Same-directory rename: atomic, so a reader never observes a partial ledger.
  if ! mv "$tmp" "$ledger"; then
    rm -f "$tmp"
    log "cost-reprice: replace failed; original ledger is intact. Backup at $backup"
    return 1
  fi

  printf 'cost-reprice: %s row(s) re-priced of %s scanned. Backup: %s\n' \
    "$changed_count" "$total_count" "$backup"
  return 0
}

rc=0
if declare -f with_ledger_lock >/dev/null 2>&1; then
  with_ledger_lock "$telemetry_dir" _cost_reprice_run || rc=$?
  if [ "$rc" -eq 75 ]; then
    log "cost-reprice: cost lock timed out; the ledger was neither read nor written."
    exit 1
  fi
else
  _cost_reprice_run || rc=$?
fi

exit "$rc"
