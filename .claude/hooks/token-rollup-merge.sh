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

# Match `gh pr merge` as a real shell invocation, at command start or right
# after a shell separator (&&, ;, ||, |, newline), not when mentioned mid-line
# in prose or a quoted string (e.g. a commit message). The newline separator
# does match a heredoc body line that begins with the command; that edge is
# benign (a spurious readout with no merge) and accepted.
# Mirrors pr-merge-audit-check.sh's command match.
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  :
elif [[ "$cmd" =~ $sep_re ]]; then
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
if [ -f .claude/hooks/lib/gaia-active-plan.sh ]; then
  . .claude/hooks/lib/gaia-active-plan.sh
  plan_dir="$(resolve_active_plan_dir)" || true
  if [ -n "$plan_dir" ]; then
    feature_key="$(resolve_feature_key "$plan_dir")" || true
  fi
fi

# Fallback: best-effort, for a fresh session with no active plan folder in
# view (e.g. a worktree-continuation merge). Keys to the most-recent execute
# record in the ledger, resolved the same way token-tally.sh / token-rollup.sh
# resolve it (the main checkout, even when run from a linked worktree). This
# is not guaranteed to be the merging feature (an interleaved prior feature's
# execute row could be newer), so it is labeled at render time.
if [ -z "$feature_key" ]; then
  if [ -f .gaia/scripts/ledger-path-lib.sh ]; then
    . .gaia/scripts/ledger-path-lib.sh
    ledger="$(gaia_resolve_ledger_path 2>/dev/null || true)"
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
