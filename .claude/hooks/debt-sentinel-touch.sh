#!/bin/bash
# PostToolUse Bash hook: after a real debt-count-mutating `gh` command for THIS
# repo, set the debt-count staleness sentinel so the open `tech-debt` count
# recomputes on the next statusline tick instead of waiting on the refresher's
# own TTL. Four commands mutate the count: `gh issue create` (a new issue, e.g. a
# tech-debt issue filed by hand in the main session), `gh pr merge` (a
# `/gaia-debt` fix PR closing its `Closes #N` issue), `gh issue close` (a
# tech-debt issue closed directly, e.g. decided wontfix or obsolete), and
# `gh issue reopen` (which raises the count again). These usually land via the
# orchestrator/human after the skill has left the conversation, so this hook is
# the reliable trigger rather than a best-effort in-conversation touch.
#
# This complements two in-flow touches that are best-effort belt-and-suspenders,
# not replacements: the audit's own touch after it files an issue (E.8, which
# runs inside the audit subagent), and the `/gaia-debt` skill's touch after it
# opens a fix PR. A main-session `gh issue create`/`close` is caught only here.
# The SessionStart reconcile hook (debt-session-reconcile.sh) backstops closes
# that never reach any hook at all.
#
# The matcher does not resolve whether the issue actually carries the `tech-debt`
# label: touching the sentinel only schedules a recompute, and over-touching is
# harmless (see below), so a broad match on any `gh issue create`/`close`/`reopen`
# costs nothing and keeps the matcher simple.
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

# Match a debt-count-mutating `gh` invocation, `gh pr merge`, `gh issue close`,
# or `gh issue reopen`, only when it appears as an actual shell invocation, either
# at the very start of the command or immediately after a shell separator. The
# `gh pr merge` arm is the same matcher as pr-merge-audit-check.sh / the deny
# hook.
gh_verb='gh[[:space:]]+(pr[[:space:]]+merge|issue[[:space:]]+(create|close|reopen))([[:space:]]|$)'
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*'"$gh_verb"
start_re='^[[:space:]]*'"$gh_verb"
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
