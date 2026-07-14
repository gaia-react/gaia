#!/usr/bin/env bash
# mentorship-cleanup-sweep.sh: one-time, idempotent, best-effort destruction of
# the mentorship residue a checkout carries.
#
# Usage: mentorship-cleanup-sweep.sh <repo_root>
#
# GAIA has no mentorship layer and no structured event pipeline. A checkout that
# ran an earlier release still carries their state, and nothing else reaps it:
#
#   off-repo, under the Claude projects directory
#     gaia/telemetry/mentorship/  the raw event store
#     gaia/profile.md             the computed profile
#     gaia/install-id.txt         the install id
#     memory/feedback_mentorship_display.md
#                                 a display-rule memory file Claude auto-loads
#                                 into context every session, indexed by a
#                                 pointer line in memory/MEMORY.md
#
#   in-repo, under .gaia/local/
#     mentorship.json             the opt-in config (plus a linked worktree's
#                                 symlink to it)
#     telemetry/cloud/            the cloud projection event stream
#     telemetry/analytics/        the analytics reports
#
# Two things make the sweep unconditional rather than opt-in-gated. The memory
# file instructs Claude to protect a subtree that does not exist and to reach for
# commands that do not exist, and it loads into context every session until
# something deletes it. And the cloud stream is not opt-in state: it accumulates
# for every checkout, including one that declines mentorship, so a sweep keyed on
# "did this checkout opt in?" would walk straight past it.
#
# Deliberately destructive: no confirmation, no dry run, no backup, no restore.
# The data is disposable working state and the sweep is the only thing that
# reaps it.
#
# Sentinel: <repo_root>/.gaia/local/.mentorship-swept, per checkout. Present is a
# silent no-op. Written even when there was nothing to delete, so the second run
# costs nothing. Per checkout, not per repository, so a linked worktree still
# gets its own run to drop its own symlink. It sits at the root of .gaia/local/,
# where the janitor's rmdir-only empty-dir sweep can never reach it.
#
# Every real-file deletion targets the MAIN checkout, resolved through
# --git-common-dir, so a run from inside a linked worktree reaps the real files
# rather than following a symlink into them. The only path taken relative to the
# calling checkout is its own mentorship.json symlink, which `rm -f` unlinks
# without following.
#
# The deletion set is closed. Every path below is a literal, fully derived
# string: no glob, no `find`, no recursion into anything the list does not name.
# .gaia/local/telemetry/ survives as a directory: it also holds the token/cost
# ledger (cost.jsonl) and the /gaia-spec pacing log (spec-pacing.jsonl), neither
# of which this sweep touches. Only its cloud/ and analytics/ children die.
#
# Best-effort / advisory: exits 0 always, on every path, so it can never block a
# session start. Each deletion stands alone; a failure of one does not abort the
# rest. stdout stays empty; diagnostics go to stderr.
set -uo pipefail

log() {
  printf '%s\n' "$*" >&2
}

if [ "$#" -ne 1 ]; then
  log "usage: mentorship-cleanup-sweep.sh <repo_root>"
  exit 0
fi

repo_root="$(cd "${1%/}" 2>/dev/null && pwd -P)" || exit 0
[ -n "$repo_root" ] || exit 0

sentinel="$repo_root/.gaia/local/.mentorship-swept"
[ -e "$sentinel" ] && exit 0

# Main-checkout root, so a run from inside a linked worktree reaps the real
# files rather than following a symlink into them. Same derivation as
# .gaia/scripts/ledger-path-lib.sh and .claude/hooks/lib/gaia-active-plan.sh.
common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)" || exit 0
case "$common_dir" in
  /*) abs="$common_dir" ;;
  *)  abs="$repo_root/$common_dir" ;;
esac
main_root="$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P)" || exit 0
[ -n "$main_root" ] || exit 0

# The MEMORY.md pointer line, matched as a whole line, exactly. It is the index
# entry for the display-rule memory file, and it is dead weight the moment that
# file is gone.
pointer_line='- [Mentorship raw events are off-limits](feedback_mentorship_display.md): never display, summarize, or tail mentorship event files'

# strip_memory_pointer <memory_index>: drop the pointer line from MEMORY.md,
# leaving every sibling line byte-identical. Rewrites through a temp file beside
# the target (same filesystem, so the mv is atomic). A MEMORY.md whose sole
# occupant is the pointer is unlinked rather than left as an empty index.
# A missing file, or one that does not carry the line, is a no-op.
strip_memory_pointer() {
  local memory_index="$1" tmp rc
  [ -f "$memory_index" ] || return 0
  grep -qxF -- "$pointer_line" "$memory_index" 2>/dev/null || return 0

  tmp="$(mktemp "${memory_index}.XXXXXX" 2>/dev/null)" || {
    log "mentorship-cleanup-sweep: cannot stage a rewrite of $memory_index"
    return 0
  }
  grep -vxF -- "$pointer_line" "$memory_index" > "$tmp" 2>/dev/null
  rc=$?
  # grep exits 1 when it selects no lines, which here means the pointer is the
  # file's only line. That is a real, empty result, not a failure; 2 and above
  # is the error tier, and leaves the original untouched.
  if [ "$rc" -gt 1 ]; then
    rm -f -- "$tmp"
    log "mentorship-cleanup-sweep: cannot rewrite $memory_index"
    return 0
  fi
  mv -- "$tmp" "$memory_index" 2>/dev/null || {
    rm -f -- "$tmp"
    log "mentorship-cleanup-sweep: cannot replace $memory_index"
    return 0
  }

  grep -q '[^[:space:]]' "$memory_index" 2>/dev/null \
    || rm -f -- "$memory_index" 2>/dev/null \
    || true
}

# --- Off-repo residue, under the Claude projects directory ------------------
# The slug mirrors the CLI's deriveClaudeSlug: the main-checkout path with every
# `/` replaced by `-`, so the leading `/` becomes a leading `-`. $HOME is read
# from the environment (the bats lane fixtures it).
#
# Guarded as a unit. An unresolvable home or an absent project directory means
# there is no off-repo tree to name; the in-repo deletions below stand on their
# own, so this is a skip rather than a bail.
home_dir="${HOME:-}"
slug="${main_root//\//-}"

if [ -n "$home_dir" ] && [ -n "$slug" ] \
   && [ -d "$home_dir/.claude/projects/$slug" ]; then
  project_dir="$home_dir/.claude/projects/$slug"

  # GAIA's own subtree, whole. Its three occupants (the mentorship event store,
  # the computed profile, the install id) all die with it. The <slug> parent is
  # Claude Code's directory, not GAIA's, and is never touched.
  rm -rf -- "${project_dir:?}/gaia" 2>/dev/null || true

  rm -f -- "$project_dir/memory/feedback_mentorship_display.md" 2>/dev/null || true
  strip_memory_pointer "$project_dir/memory/MEMORY.md"
fi

# --- In-repo residue, under the main checkout's .gaia/local/ ----------------
rm -f -- "$main_root/.gaia/local/mentorship.json" 2>/dev/null || true

# The calling checkout's symlink to that file, when this run is inside a linked
# worktree. `rm -f` unlinks a symlink without following it, so the target is out
# of reach here; the line above already reaped the real file anyway.
if [ "$repo_root" != "$main_root" ] \
   && [ -L "$repo_root/.gaia/local/mentorship.json" ]; then
  rm -f -- "$repo_root/.gaia/local/mentorship.json" 2>/dev/null || true
fi

# Both children of telemetry/, named literally. telemetry/ itself survives: it
# holds cost.jsonl and spec-pacing.jsonl, and both outlive this sweep.
rm -rf -- "${main_root:?}/.gaia/local/telemetry/cloud" 2>/dev/null || true
rm -rf -- "${main_root:?}/.gaia/local/telemetry/analytics" 2>/dev/null || true

# --- Sentinel --------------------------------------------------------------
# Written last, and written even when nothing above matched, so a checkout that
# never enabled mentorship also stops re-running this. No mkdir: .gaia/local is
# the janitor's own precondition, and a checkout without it has nothing to sweep.
if ! printf 'mentorship-cleanup-sweep %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     > "$sentinel" 2>/dev/null; then
  log "mentorship-cleanup-sweep: cannot write the sentinel at $sentinel"
fi

exit 0
