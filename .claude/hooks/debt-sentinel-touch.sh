#!/bin/bash
# PostToolUse Bash hook: after a real `gh pr merge` for THIS repo, set the
# debt-count staleness sentinel so the open `tech-debt` count recomputes
# on the next statusline tick instead of waiting on the refresher's own TTL.
# This is the second of the two deterministic first-party sentinel-set events
# (the first is the audit filing a `tech-debt` issue); a `/gaia-debt` PR usually
# merges via the orchestrator/human after the skill has left the conversation,
# so this hook is the reliable trigger rather than the skill's best-effort
# in-conversation touch.
#
# Fire-and-forget: it NEVER blocks or denies a merge (PostToolUse, always
# exit 0). It does not confirm the merge actually closed a `tech-debt` issue,
# touching the sentinel only schedules a recompute on the next tick, which is
# cheap and always correct; over-touching is harmless.
#
# See wiki/concepts/Audit Disposition and Debt Drain.md for the debt-count sentinel contract.

# -e is intentionally omitted; all error-prone commands are individually
# guarded (|| true, 2>/dev/null) so this hook can never fail a merge.
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Avoid the name `command`: it would shadow bash's `command` builtin.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match `gh pr merge` only when it appears as an actual shell invocation, either
# at the very start of the command or immediately after a shell separator. Same
# matcher as pr-merge-audit-check.sh / the deny hook.
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  : # match at command start
elif [[ "$cmd" =~ $sep_re ]]; then
  : # match after a shell separator (incl. newline)
else
  exit 0
fi

# Repo-scope: a `gh pr merge` aimed at a sibling repo must not touch THIS repo's
# sentinel.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Create the parent dir first (every sentinel writer owns its mkdir; on a
# fresh clone or in CI no statusline tick has run, so .gaia/local/debt/ may not
# exist yet and a bare touch would fail silently), then touch the sentinel.
mkdir -p .gaia/local/debt 2>/dev/null || true
: > .gaia/local/debt/refresh-requested 2>/dev/null || true

exit 0
