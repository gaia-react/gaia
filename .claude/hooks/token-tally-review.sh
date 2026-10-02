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
  command=$(jq -r '.tool_input.command // ""' <<<"$payload")

  # Shared arming decision; see .claude/hooks/lib/verb-arming.sh. A quoted
  # verb inside prose still arms here, fail-closed, with no safe narrowing.
  _hook_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
  # shellcheck source=/dev/null
  [ -n "${_hook_library_directory:-}" ] && [ -f "$_hook_library_directory/verb-arming.sh" ] && . "$_hook_library_directory/verb-arming.sh"
  type gaia_verb_armed >/dev/null 2>&1 || exit 0

  verb_pattern='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
  if gaia_verb_armed "$verb_pattern" 'gh pr merge' "$command"; then
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

session_id=$(jq -r '.session_id // ""' <<<"$payload")
[ -n "$session_id" ] || exit 0

# GAIA_TALLY_PROJECTS_ROOT is a documented test seam: unset in production, so
# this resolves to the SAME default token-tally.sh falls back to. This hook
# only mirrors that default for its own cheap gate; it does not resolve it
# via token-tally-git-op.sh, which merely forwards the env var and never
# resolves the default itself.
projects_root="${GAIA_TALLY_PROJECTS_ROOT:-$HOME/.claude/projects}"

_hook_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Cheap negative gate (the spurious guard): before paying for
# token-tally.sh, confirm the session actually ran a code-review-audit
# sub-agent. This sidecar-meta glob is new; no existing hook models it, so
# it is authored fresh with a nullglob + per-file -f guard.
#
# A review run is any Code Audit Team member, read from this checkout's
# roster, because the merge gate can dispatch a member other than the default
# without the default. The roster is parsed only once a sidecar exists, so a
# Stop in a session with no sub-agents pays nothing. An unreadable roster
# falls back to the default member's name, the member the gate falls back to
# spawning, and must agree with the same fallback in audit-window-lib.sh.
has_review=0
review_agents=""
shopt -s nullglob
for meta in "$projects_root"/*/"$session_id"/subagents/agent-*.meta.json; do
  [ -f "$meta" ] || continue
  if [ -z "$review_agents" ]; then
    review_agents=$(
      . "$_hook_directory/lib/audit-scope.sh" 2>/dev/null \
        && audit_roster_member_names "$_hook_directory/../../.gaia/audit-ci.yml" 2>/dev/null
    ) || review_agents=""
    [ -n "$review_agents" ] || review_agents="code-audit-frontend"
  fi
  atype=$(jq -r '.agentType // ""' "$meta" 2>/dev/null || printf '')
  [ -n "$atype" ] || continue
  if grep -qxF -- "$atype" <<<"$review_agents"; then
    has_review=1
    break
  fi
done
shopt -u nullglob
[ "$has_review" -eq 1 ] || exit 0

# Resolve association through the same shared resolver the execute-time
# tally uses, loaded from this file's own directory rather than from the
# process working directory: a cwd anywhere under the repository root would
# otherwise lose attribution silently. This hook still differs from the
# execute-time one on the second axis, which is deliberate: that hook
# parse-checks before sourcing where this one does not, which it can afford to
# skip because it runs without errexit, so a source that fails, whether the
# file is missing or unparseable, reaches the ERR trap above and exits 0.
. "$_hook_directory/lib/gaia-active-plan.sh"

plan_directory="$(resolve_active_plan_directory)" || true
feature_key=""
if [ -n "$plan_directory" ]; then
  feature_key="$(resolve_feature_key "$plan_directory")" || true
fi

# Route the feature key to the flag matching its shape. An unclassifiable or
# absent key routes to no id flag at all (ad-hoc null/null), UNLESS the
# running-but-unclassifiable guard below recovers a SPEC id from the path.
case "$feature_key" in
  SPEC-*) id_flag=(--spec-id "$feature_key") ;;
  PLAN-*) id_flag=(--plan-id "$feature_key") ;;
  *)
    # Running-but-unclassifiable guard: resolve_feature_key falls back to
    # basename(plan_directory), so a colocated plan whose Source SPEC parse fails
    # returns a bare `plan`/`plan-2` basename that matches neither prefix
    # above, even though a plan IS running on the branch. A review row
    # cannot carry `partial`, so unlike the execute path (which lets
    # token-tally mark such a row partial), there is no degraded-attribution
    # signal to fall back on. Recover the id from the plan-dir PATH itself
    # instead: this reuses resolve_active_plan_directory's own output, not a new
    # active-spec marker. Only when the path also yields nothing does the
    # review land as a true ad-hoc null/null record (still findable by its
    # source tag).
    path_spec=""
    if [ -n "$plan_directory" ]; then
      path_spec=$(printf '%s' "$plan_directory" | sed -nE 's#.*/\.gaia/local/specs/(SPEC-[0-9]+)/plan.*#\1#p')
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
bash "$_hook_directory/../../.gaia/scripts/token-tally.sh" \
  --action review ${id_flag[@]+"${id_flag[@]}"} --session-id "$session_id" \
  ${GAIA_TALLY_PROJECTS_ROOT:+--projects-root "$GAIA_TALLY_PROJECTS_ROOT"} >/dev/null 2>&1 || true

exit 0
