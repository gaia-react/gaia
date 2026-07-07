#!/usr/bin/env bash
# Captures a code-review-audit run as a standalone kind:"review" cost.jsonl
# record. One script serves BOTH end-of-context triggers so the review-tally
# logic lives in one place:
#   1. PostToolUse Bash hook on `gh pr merge` (the pre-merge gate run).
#   2. Stop hook (ad-hoc / quality-gate runs that end without a merge).
#
# Both call token-tally.sh --action review, which owns window detection,
# per-run dedup by review_id, the spurious no-op when no code-review-audit
# ran, and the standalone record write. This hook only cheap-gates and
# resolves association; it never parses transcripts and never dedups.
#
# Both triggers can fire in one merge session: the merge trigger records the
# run first, the Stop trigger's tally call finds it already recorded (by
# review_id) and writes nothing. That guarantee lives inside token-tally.sh,
# not here. This hook always exits 0; it never blocks and never emits a
# permission decision.

set -uo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)

tool_name=$(jq -r '.tool_name // ""' <<<"$payload")

if [ "$tool_name" = "Bash" ]; then
  # PostToolUse `gh pr merge` path.
  cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

  # Match `gh pr merge` as a real shell invocation, at command start or right
  # after a shell separator (&&, ;, ||, |, newline), not when mentioned
  # mid-line in prose or a quoted string. Mirrors token-rollup-merge.sh's
  # command match exactly.
  start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
  sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
  if [[ "$cmd" =~ $start_re ]]; then
    :
  elif [[ "$cmd" =~ $sep_re ]]; then
    :
  else
    exit 0
  fi
else
  # Stop path: no tool_name, hook_event_name == "Stop". Guard against a
  # Stop-hook loop, mirroring wiki-session-stop.sh's re-entry handling.
  stop_active=$(jq -r '.stop_hook_active // false' <<<"$payload")
  [ "$stop_active" = "true" ] && exit 0
fi

sid=$(jq -r '.session_id // ""' <<<"$payload")
[ -n "$sid" ] || exit 0

# GAIA_TALLY_PROJECTS_ROOT is a documented test seam: unset in production, so
# this resolves to the SAME default token-tally.sh falls back to. This hook
# only mirrors that default for its own cheap gate; it does not resolve it
# via token-tally-git-op.sh, which merely forwards the env var and never
# resolves the default itself.
projects_root="${GAIA_TALLY_PROJECTS_ROOT:-$HOME/.claude/projects}"

# Cheap negative gate (the spurious guard): before paying for
# token-tally.sh, confirm the session actually ran a code-review-audit
# sub-agent. This sidecar-meta glob is new; no existing hook models it, so
# it is authored fresh with a nullglob + per-file -f guard.
has_review=0
shopt -s nullglob
for meta in "$projects_root"/*/"$sid"/subagents/agent-*.meta.json; do
  [ -f "$meta" ] || continue
  atype=$(jq -r '.agentType // ""' "$meta" 2>/dev/null || printf '')
  if [ "$atype" = "code-review-audit" ]; then
    has_review=1
    break
  fi
done
shopt -u nullglob
[ "$has_review" -eq 1 ] || exit 0

# Resolve association the same way the execute-time tally does.
. .claude/hooks/lib/gaia-active-plan.sh

plan_dir="$(resolve_active_plan_dir)" || true
feature_key=""
if [ -n "$plan_dir" ]; then
  feature_key="$(resolve_feature_key "$plan_dir")" || true
fi

# Route the feature key to the flag matching its shape. An unclassifiable or
# absent key routes to no id flag at all (ad-hoc null/null), UNLESS the
# running-but-unclassifiable guard below recovers a SPEC id from the path.
case "$feature_key" in
  SPEC-*) id_flag=(--spec-id "$feature_key") ;;
  PLAN-*) id_flag=(--plan-id "$feature_key") ;;
  *)
    # Running-but-unclassifiable guard: resolve_feature_key falls back to
    # basename(plan_dir), so a colocated plan whose Source SPEC parse fails
    # returns a bare `plan`/`plan-2` basename that matches neither prefix
    # above, even though a plan IS running on the branch. A review row
    # cannot carry `partial`, so unlike the execute path (which lets
    # token-tally mark such a row partial), there is no degraded-attribution
    # signal to fall back on. Recover the id from the plan-dir PATH itself
    # instead: this reuses resolve_active_plan_dir's own output, not a new
    # active-spec marker. Only when the path also yields nothing does the
    # review land as a true ad-hoc null/null record (still findable by its
    # source tag).
    path_spec=""
    if [ -n "$plan_dir" ]; then
      path_spec=$(printf '%s' "$plan_dir" | sed -nE 's#.*/\.gaia/local/specs/(SPEC-[0-9]+)/plan.*#\1#p')
    fi
    if [ -n "$path_spec" ]; then
      id_flag=(--spec-id "$path_spec")
    else
      id_flag=()
    fi
    ;;
esac

# id_flag is empty in the ad-hoc case (the case `*)` branch above with no
# recoverable path spec). The offset-guard `${id_flag[@]+"${id_flag[@]}"}`
# keeps that empty expansion from firing bare: on stock macOS /bin/bash 3.2
# a bare "${id_flag[@]}" over an empty array aborts with `unbound variable`
# under `set -u`; bash 4.4+ tolerates it. The tally owns window detection,
# per-run dedup by review_id, the spurious no-op, and the record write; this
# hook does not parse or dedup.
bash .gaia/scripts/token-tally.sh \
  --action review ${id_flag[@]+"${id_flag[@]}"} --session-id "$sid" \
  ${GAIA_TALLY_PROJECTS_ROOT:+--projects-root "$GAIA_TALLY_PROJECTS_ROOT"} >/dev/null 2>&1 || true

exit 0
