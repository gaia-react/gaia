#!/usr/bin/env bash
# cost-unpriced-scan.sh: name every model the cost ledger cannot price under the
# card in force right now, and say whether the machine-local overlay already
# covers it.
#
# This is the DETECTION half of the rate-overlay auto-heal. It is deliberately
# deterministic and it never invents a rate. It cannot: the Models API returns
# no pricing field, so a rate is only available from a docs page, and a name or
# tier heuristic would be actively wrong (it would price claude-fable-5 at
# Opus-tier, and it could never produce a time-windowed introductory rate). A
# confidently wrong rate is worse than a zero, which is the whole lesson of the
# condition this scan exists to find. Sourcing the number is the caller's job,
# and the caller is expected to be a human-gated /gaia-fitness Fixer.
#
# Usage: cost-unpriced-scan.sh [--ledger <path>] [--rate-table <path>]
#
# Prints one JSON object on stdout:
#   {
#     "unpriced":      ["claude-x"],   distinct, sorted; models with no window
#     "rows_affected": 3,              rows whose figure is a lower bound
#     "overlay_path":  "/abs/path",    where a rate would be added ("" if no repo)
#     "overlay_active":["claude-y"]    models the overlay is already pricing
#   }
#
# Detection recomputes each row's unpriced set from its raw `by_model` and its
# own `ts` rather than reading the row's stored `unpriced` field. The stored
# field records what the table was missing WHEN THE ROW WAS WRITTEN, so a row
# written before a rate landed still carries a name that is now priceable, and a
# row written before that field existed carries nothing at all. Recomputing
# answers the question actually being asked: what can this machine not price
# today.
#
# A row that cannot anchor a rate window is not counted. `priced_row` reports it
# as missing_anchor with a dollars of 0, which is an unknown rather than a
# missing rate, and no overlay entry would fix it.
#
# Exit 0 whether or not anything is unpriced: this is a report, not a gate. A
# non-zero exit means the scan itself could not run (no readable ledger or table).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/token-pricing-lib.sh
. "$SELF_DIR/token-pricing-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$SELF_DIR/ledger-path-lib.sh" 2>/dev/null || true

log() { printf '%s\n' "$*" >&2; }

ledger_override=""
rate_table_override=""

usage() { log "Usage: cost-unpriced-scan.sh [--ledger <path>] [--rate-table <path>]"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    # Each option checks its own operand before `shift 2`. A trailing bare
    # `--ledger` would otherwise leave $1 unchanged and spin the loop forever.
    --ledger)
      [ "$#" -ge 2 ] || { log "cost-unpriced-scan: --ledger needs a path"; usage; exit 1; }
      ledger_override="$2"; shift 2 ;;
    --rate-table)
      [ "$#" -ge 2 ] || { log "cost-unpriced-scan: --rate-table needs a path"; usage; exit 1; }
      rate_table_override="$2"; shift 2 ;;
    *)
      log "cost-unpriced-scan: unexpected argument: $1"
      usage
      exit 1 ;;
  esac
done

if ! declare -f gaia_load_rate_table >/dev/null 2>&1; then
  log "cost-unpriced-scan: token-pricing-lib.sh is unavailable; cannot scan"
  exit 1
fi

ledger="$(gaia_resolve_ledger_path "$ledger_override" 2>/dev/null)"
if [ -z "$ledger" ]; then
  log "cost-unpriced-scan: could not resolve the cost ledger"
  exit 1
fi

rt="$(gaia_resolve_rate_table "$rate_table_override" 2>/dev/null)"
if [ -z "$rt" ]; then
  log "cost-unpriced-scan: could not resolve a rate table"
  exit 1
fi
if ! rates="$(gaia_load_rate_table "$rt")"; then
  log "cost-unpriced-scan: rate table unreadable or malformed: $rt"
  exit 1
fi
# Bare call, never `$( )`: it assigns GAIA_EFFECTIVE_RATES and the overlay
# globals, which a subshell would drop. The scan has to answer about the card in
# force, overlay included, or it would keep reporting a model the operator
# already fixed.
gaia_apply_rate_overlay "$rates" "$rate_table_override"
rates="$GAIA_EFFECTIVE_RATES"

overlay_path="$(gaia_resolve_rate_overlay 2>/dev/null || true)"

# An absent or empty ledger is a well-formed ledger with nothing to report, not a
# failure: it is the ordinary fresh-checkout state.
scan='{"unpriced":[],"rows_affected":0}'
if [ -s "$ledger" ]; then
  scan="$(jq -R -s -c --argjson rates "$rates" \
    "$GAIA_PRICING_JQ_DEFS"'
      # -R -s reads the whole file as one string so a line that does not parse
      # can be skipped by this pass rather than raising a per-input error that
      # empties the whole result.
      split("\n")
      | map(select(length > 0))
      | map(try fromjson catch null)
      | map(select(type == "object" and ((.by_model // {}) | type) == "object"
                   and ((.by_model // {}) | length) > 0))
      | map(priced_row(.))
      | map(select(.missing_anchor | not))
      | { unpriced: (map(.unpriced) | flatten | unique | sort),
          rows_affected: (map(select((.unpriced | length) > 0)) | length) }
    ' "$ledger" 2>/dev/null || true)"
  if [ -z "$scan" ]; then
    log "cost-unpriced-scan: could not read $ledger"
    exit 1
  fi
fi

# GAIA_RATE_OVERLAY_MODELS is space-separated; `split` on the empty string yields
# [""], so the empty case is handled before the split rather than filtered after.
jq -c -n --argjson scan "$scan" --arg overlay "${overlay_path:-}" --arg active "${GAIA_RATE_OVERLAY_MODELS:-}" \
  '$scan + { overlay_path: $overlay,
             overlay_active: (if ($active | length) == 0 then [] else ($active | split(" ") | sort) end) }'
