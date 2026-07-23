#!/bin/bash
# SessionStart hook: reconcile a currently-shown `Run /gaia-debt` nudge against
# GitHub on session start/resume.
#
# The debt count invalidates promptly only through first-party sentinel events
# (the audit filing a `tech-debt` issue; a `gh pr merge` / `gh issue close` /
# `gh issue reopen` caught by debt-sentinel-touch.sh). A close that never reaches
# one of those hooks, the GitHub web UI, a teammate, or a plain `gh issue close`
# in a non-hooked shell, drops no sentinel, so the stale nudge would otherwise
# linger until the refresher's own 6h TTL. This hook arms the sentinel on the
# next session start so the following statusline tick recomputes the count.
#
# Guarded on openCount > 0: an empty backlog (the common case) stays fully
# network-free, no sentinel is armed and no `gh` call fires. It therefore
# reconciles the count DOWNWARD only. A `tech-debt` issue OPENED externally while
# the local count is 0 still surfaces on the next TTL, not this session start;
# that direction is the rarer case and not the stale-nudge problem this closes.
#
# Fire-and-forget: it NEVER blocks or delays session start (always exit 0). The
# recompute itself is the refresher's job, run detached from the statusline; this
# hook only touches a local marker file after a local read.
#
# See wiki/concepts/Audit Disposition and Debt Fix.md for the debt-count
# sentinel contract.

# -e is intentionally omitted; every step is guarded so this hook can never fail
# a session start.
set -uo pipefail

# SessionStart delivers a JSON payload on stdin; drain it so the writer never
# stalls on a full pipe. We do not read any field from it.
cat >/dev/null 2>&1 || true

command -v jq >/dev/null 2>&1 || exit 0

# The shared main-root resolver, sourced from this hook's own on-disk
# location (never cwd): the debt count cache is main-anchored shared state
# (SPEC-061 scope=shared), so this reconcile reads and re-arms main's copy,
# never a worktree's discarded one.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
if [ -n "$gaia_scripts" ] && [ -f "$gaia_scripts/.gaia/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$gaia_scripts/.gaia/scripts/main-root-lib.sh"
fi
main_root=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  main_root="$(gaia_resolve_main_root 2>/dev/null || true)"
fi
[ -n "$main_root" ] || exit 0

CACHE="$main_root/.gaia/local/debt/count.json"

# No cache yet: nothing is being shown, and the refresher's own missing-cache
# branch will seed a count on the next tick. Nothing to reconcile here.
[ -f "$CACHE" ] || exit 0

open_count=$(jq -r '.openCount // 0' "$CACHE" 2>/dev/null)
case "$open_count" in
  ''|*[!0-9]*) exit 0 ;;
esac

# Only arm the sentinel when a nudge is actually showing (count > 0). This is the
# network-free guard: an empty backlog never triggers a `gh` recompute.
[ "$open_count" -gt 0 ] 2>/dev/null || exit 0

# Create the parent dir first (every sentinel writer owns its mkdir; the dir is
# not assumed to pre-exist on a fresh clone or in CI), then touch the sentinel.
mkdir -p "$main_root/.gaia/local/debt" 2>/dev/null || true
: > "$main_root/.gaia/local/debt/refresh-requested" 2>/dev/null || true

exit 0
