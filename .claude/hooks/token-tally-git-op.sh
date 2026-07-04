#!/usr/bin/env bash
# PreToolUse Bash hook: records this execution session's ground-truth token
# tally on the orchestrator's per-phase git commit/push, so a resumed or
# worktree session is captured deterministically instead of depending on a
# session-scoped prose instruction. Gated on an active plan folder (a
# RUNNING sentinel whose branch matches the current branch) and keyed to
# that plan's feature. This hook only performs a side effect: it never
# blocks the git operation and never emits a permission decision.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

# Match `git commit` or `git push` as a real shell invocation, at command
# start or right after a shell separator (&&, ;, ||, |, newline), not when
# mentioned mid-line in prose or a quoted string (e.g. a commit message).
# Bash `=~` gives whole-string semantics; `grep` is line-oriented and would
# match every heredoc body line. The newline separator here still matches a
# heredoc body line that begins with the command; that edge is benign (one
# extra tally row the per-session dedup collapses) and accepted.
start_re='^[[:space:]]*git[[:space:]]+(commit|push)([[:space:]]|$)'
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*git[[:space:]]+(commit|push)([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  :
elif [[ "$cmd" =~ $sep_re ]]; then
  :
else
  exit 0
fi

# Cheap negative gate: no live plan RUNNING sentinel at all, skip before
# sourcing the resolver lib or paying for token-tally.sh's transcript parse.
has_plan=0
for rf in .gaia/local/plans/*/RUNNING .gaia/local/specs/*/plan/RUNNING .gaia/local/specs/*/plan-*/RUNNING; do
  [ -f "$rf" ] || continue
  has_plan=1
  break
done
[ "$has_plan" -eq 1 ] || exit 0

. .claude/hooks/lib/gaia-active-plan.sh
plan_dir="$(resolve_active_plan_dir)"
[ -n "$plan_dir" ] || exit 0

feature_key="$(resolve_feature_key "$plan_dir")"
slug="$(basename "$plan_dir")"
sid=$(jq -r '.session_id // ""' <<<"$payload")

# Route the feature key to the flag matching its shape. An unclassifiable key
# (neither SPEC- nor PLAN-, e.g. a bare `plan`/`plan-2` basename from a failed
# `## Source SPEC` parse) gets no id flag at all, so token-tally marks the row
# partial instead of binding a mistyped value into plan_id.
case "$feature_key" in
  SPEC-*) id_flag=(--spec-id "$feature_key") ;;
  PLAN-*) id_flag=(--plan-id "$feature_key") ;;
  *)      id_flag=() ;;
esac

# GAIA_TALLY_PROJECTS_ROOT is a documented test seam: unset in production
# (token-tally.sh falls back to its $HOME/.claude/projects default), set by
# bats to point at a fixture so no test run ever touches a real session's
# transcript search path.
bash .gaia/scripts/token-tally.sh \
  --action execute "${id_flag[@]}" --plan-slug "$slug" \
  --out-dir "$plan_dir" --session-id "$sid" \
  ${GAIA_TALLY_PROJECTS_ROOT:+--projects-root "$GAIA_TALLY_PROJECTS_ROOT"} >/dev/null 2>&1 || true

exit 0
