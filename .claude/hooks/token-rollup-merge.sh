#!/usr/bin/env bash
# PostToolUse Bash hook on `gh pr merge`. Renders the full-cycle token-cost
# roll-up (spec / plan / execute / total) for the merging feature into the
# session's context. Session-independent: resolves the feature key from
# on-disk state only, the active plan folder or, failing that, the ledger's
# most recent execute record, so it renders from any session that runs the
# merge, including a fresh top-level session that never ran the plan itself.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

# Shared arming decision; see .claude/hooks/lib/verb-arming.sh. A quoted verb
# inside prose still arms here, fail-closed, with no safe narrowing.
#
# This load runs before the arming gate, on every Bash tool call, so whatever
# guards it is paid on every call. Measured on this machine rather than assumed:
# `bash -n` on the real verb-arming.sh costs ~3.1ms on bash 3.2.57 and ~5.7ms
# on 5.3.15, and as a whole extra hook process that is +2.5ms and +5.7ms
# against a ~16-21ms hook. A surcharge, not a doubling, and worth paying.
#
# The cheaper `{ . lib || true; }` arm was the first spelling here and is not
# enough. It closes the bash 5 half only: under `set -e` an unparseable
# verb-arming.sh still abandons the shell ahead of the arm on a stock 3.2 at
# exit 2, and it suppresses the syntax error that would name the broken file,
# so what survives is a denial with no stated reason. The parse check removes
# both, which is why the cost above is spent here.
#
# What the check does not reach: verb-arming.sh lazily sources
# verb-arming-walk.sh on a raw match, and `bash -n` does not recurse into a
# sourced file, so an unparseable walk lib still denies on 3.2. That load lives
# inside verb-arming.sh, so no consumer hook can guard it from out here; it is
# gaia-react/gaia#1556.
_va_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_va_lib:-}" ] && "${BASH:-bash}" -n "$_va_lib/verb-arming.sh" 2>/dev/null && . "$_va_lib/verb-arming.sh" 2>/dev/null || true
type gaia_verb_armed >/dev/null 2>&1 || exit 0

frag='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if gaia_verb_armed "$frag" 'gh pr merge' "$cmd"; then
  :
else
  exit 0
fi

feature_key=""
fallback=0

# Primary: the active plan folder for this branch, keyed the same way the
# plan's own execute records are (the RUNNING sentinel + README Source SPEC).
# Present at merge time because the plan's self-cleanup runs only after the
# merge is confirmed, so this resolves correctly for the normal in-session
# merge.
# Past the arming gate, so the load parse-checks rather than resting on the
# `-f` test: an existence test proves the file opens, not that it parses, and
# under `set -e` an unparseable lib abandons the shell at exit 2 with the ERR
# trap never reached. `bash -n` subsumes the existence test; the `type` check
# is what degrades when the lib never defined its functions.
if "${BASH:-bash}" -n .claude/hooks/lib/gaia-active-plan.sh 2>/dev/null; then
  . .claude/hooks/lib/gaia-active-plan.sh 2>/dev/null || true
  # Degrades INTO the fallback below rather than out of the hook: a lib that
  # never defined its functions is the same situation as no active plan folder,
  # and the ledger path can still answer.
  if type resolve_active_plan_dir >/dev/null 2>&1; then
    plan_dir="$(resolve_active_plan_dir)" || true
    if [ -n "$plan_dir" ]; then
      feature_key="$(resolve_feature_key "$plan_dir")" || true
    fi
  fi
fi

# Fallback: best-effort, for a fresh session with no active plan folder in
# view (e.g. a worktree-continuation merge). Keys to the most-recent execute
# record in the ledger, resolved the same way token-tally.sh / token-rollup.sh
# resolve it (the main checkout, even when run from a linked worktree). This
# is not guaranteed to be the merging feature (an interleaved prior feature's
# execute row could be newer), so it is labeled at render time.
if [ -z "$feature_key" ]; then
  # Parse-checked for the same reason the plan-folder load above is.
  if "${BASH:-bash}" -n .gaia/scripts/ledger-path-lib.sh 2>/dev/null; then
    . .gaia/scripts/ledger-path-lib.sh 2>/dev/null || true
    ledger=""
    if type gaia_resolve_ledger_path >/dev/null 2>&1; then
      ledger="$(gaia_resolve_ledger_path 2>/dev/null || true)"
    fi
    if [ -n "$ledger" ] && [ -f "$ledger" ]; then
      feature_key=$(jq -R -s -r '
        split("\n") | map(select(length > 0))
        | map(try fromjson catch empty)
        | map(select(type == "object" and .kind == "execute"
              and (((.spec_id // "") != "") or ((.plan_id // "") != ""))))
        | sort_by(.ts // "")
        | last
        | (.spec_id // .plan_id // empty)
      ' "$ledger" 2>/dev/null || true)
      [ -n "$feature_key" ] && fallback=1
    fi
  fi
fi

[ -n "$feature_key" ] || exit 0

rollup=$(bash .gaia/scripts/token-rollup.sh --spec-id "$feature_key" 2>/dev/null || true)
[ -n "$rollup" ] || exit 0

if [ "$fallback" -eq 1 ]; then
  printf '[cycle cost at merge - feature key resolved from the ledger'"'"'s most recent execution; no active plan folder was found]\n%s\n' "$rollup"
else
  printf '[cycle cost at merge]\n%s\n' "$rollup"
fi

exit 0
