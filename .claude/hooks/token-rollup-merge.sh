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
# after a shell separator (&&, ;, ||, |, newline), never inside a heredoc
# body or a quoted string (e.g. a commit message mentioning it in prose).
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
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
  if [ -n "$common_dir" ]; then
    case "$common_dir" in
      /*) abs="$common_dir" ;;
      *) abs="$PWD/$common_dir" ;;
    esac
    main_root=$(cd "$(dirname "$abs")" 2>/dev/null && pwd || true)
    if [ -n "$main_root" ]; then
      ledger="$main_root/.gaia/local/telemetry/tokens.jsonl"
      if [ -f "$ledger" ]; then
        feature_key=$(jq -R -s -r '
          split("\n") | map(select(length > 0))
          | map(try fromjson catch empty)
          | map(select(type == "object" and .action == "execute" and (.spec_id // "") != ""))
          | sort_by(.ts // "")
          | last
          | .spec_id // empty
        ' "$ledger" 2>/dev/null || true)
        [ -n "$feature_key" ] && fallback=1
      fi
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
