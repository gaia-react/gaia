#!/usr/bin/env bash
# SessionStart hook (startup, resume, clear, compact): keeps dev servers
# attributable and stops the ones nobody owns any more.
#
# Every source registers this session's host process, so a server the session
# launches can later be attributed to it. Only a real session start (startup or
# resume) stops anything: /clear and compaction fire this hook inside a live
# session, and a crash fires nothing, so cleanup of a dead session's servers and
# of servers left running from removed worktrees happens at the next real start,
# in any tree including the main checkout. On clear and compact in a linked
# worktree the hook re-emits the tree's ports context line, because worktree
# provisioning does not run on those sources.
#
# Cleanup order: behind a stat-level gate that spawns no process probe, the
# ledger is reclaimed under the lock; the lock is released before any process is
# signalled, so a concurrent provisioning run is never starved while this hook
# waits on a server. A lock timeout skips the reclaim and carries on.
#
# Output: only the report lines the process library prints (one per stopped
# server) and, on clear and compact, the context line. Diagnostics go to stderr.
# Every path exits 0: any failure means no cleanup and no output.

set -uo pipefail
trap 'exit 0' ERR

[ -n "${GITHUB_ACTIONS:-}" ] && exit 0

here="${BASH_SOURCE[0]}"
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
scripts="$here/../../.gaia/scripts"

payload=$(cat) || exit 0
[ -n "$payload" ] || exit 0

session_id="" source="" cwd=""
if command -v jq >/dev/null 2>&1; then
  fields=$(jq -r '
    def s(f): (try (f | strings) catch null) // "";
    [ s(.session_id), s(.source), s(.cwd) ] | join("\u001f")' <<<"$payload") || exit 0
  IFS=$'\037' read -r -d '' session_id source cwd <<<"$fields" || true
  cwd="${cwd%$'\n'}"
else
  session_id=$(printf '%s\n' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | sed -n 1p)
  source=$(printf '%s\n' "$payload" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | sed -n 1p)
  cwd=$(printf '%s\n' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p)
fi

# The libraries are loaded with the error trap disarmed: an unparseable library
# must end in a quiet exit, not abort from inside the source.
trap - ERR
set +e
# shellcheck source=/dev/null
. "$scripts/worktree-ports-lib.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$scripts/server-process-lib.sh" 2>/dev/null || exit 0
trap 'exit 0' ERR

[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

main_root="$(gaia_resolve_main_root "$cwd" 2>/dev/null)" || exit 0
[ -n "$main_root" ] || exit 0
state="$(gaia_ports_state_directory "$cwd" 2>/dev/null)" || exit 0
[ -n "$state" ] || exit 0

if [ -n "$session_id" ]; then
  gaia_server_session_register "$state" "$session_id" 2>/dev/null || true
fi

case "$source" in
  startup | resume)
    if gaia_server_cleanup_needed "$state"; then
      if gaia_ports_lock "$state"; then
        # Reclaim answers 1 for "nothing to do" as well as for a failed git
        # listing; neither may end the hook. Its stdout names removed entries
        # that the tombstone reap below reports, so it is discarded here.
        gaia_ports_reclaim "$state" "$main_root" >/dev/null 2>&1 || true
        gaia_ports_unlock "$state"
      else
        printf 'GAIA ports: could not take the slot lock, skipping the ledger reclaim this session start.\n' >&2
      fi
      gaia_server_reap_tombstones "$state" || true
      gaia_server_reap_dead_sessions "$state" || true
    fi
    ;;
  clear | compact)
    if gaia_is_linked_worktree "$cwd"; then
      tree_root="$(gaia_resolve_tree_root "$cwd" 2>/dev/null)" || exit 0
      port_file="$(gaia_ports_file_path "$tree_root" 2>/dev/null)" || exit 0
      if record="$(gaia_ports_read_file "$port_file" 2>/dev/null)"; then
        IFS=$'\t' read -r slot _ storybook site_url <<<"$record"
        gaia_ports_context_line "$slot" "$site_url" "$storybook"
      fi
    fi
    ;;
esac
exit 0
