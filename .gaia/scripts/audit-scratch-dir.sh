#!/usr/bin/env bash
# shellcheck shell=bash
#
# Per-member scratch directory for a Code Audit Team member that needs real
# bytes on disk.
#
# The contract this exists to serve: every member returns the audited working
# tree unchanged, while establishing that a guard is not hollow means breaking
# the construct the guard names and watching a check go red. Those two compose
# into an obligation no member definition used to state -- the mutation has to
# happen on a copy, somewhere outside the tree under review -- and the only
# writable space a dispatched subagent is handed is the session scratchpad,
# which every member of one parallel wave shares. A member improvising a name
# there picks the name its co-dispatched siblings also pick, and one member's
# pristine copy lands over another's mutated one. Neither direction announces
# itself: a pristine tree over a mutated one makes the mutation look like it
# did not red (a fabricated hollow-assertion finding), and a mutated tree over
# a pristine one reds a test that has nothing to do with the change under
# review.
#
# So the path is minted here rather than described in prose. The key is the
# audit key PLUS the member name, the same pairing the findings sidecar
# already publishes under (.gaia/local/audit/<audit-key>.<member>.findings.json):
# the audit key alone is NOT enough, because every member of one wave resolves
# the same key, and it is exactly the member half that makes the name
# wave-safe by construction.
#
# Layout, under the MAIN checkout (.gaia/local/cache is main-anchored, the
# same root gh-artifact-lib.sh resolves):
#
#   <main_root>/.gaia/local/cache/mutation-scratch/<audit-key>.<member>/
#
# Registered as `audit-mutation-scratch` in .gaia/state-registry.json
# (cache/mutation-scratch/, prefix, dir, ephemeral). Two reapers, in that
# order of preference: gaia_audit_scratch_release, which a member calls when
# it is done, and the janitor's stale cache sweep
# (.claude/hooks/local-janitor.sh sweep #5b), which ages out a directory a
# member died before releasing. The release path is the real one; the sweep is
# the backstop for a member that never got there.
#
# Every function below prints nothing and returns 0 when it cannot resolve a
# path, the same fail-open rule audit-key-lib.sh and gh-artifact-lib.sh
# already apply: a caller that cannot be given a private directory must fall
# back to its own judgment, never to a shared path this file invented.
#
# Usage, sourced:
#   . .gaia/scripts/audit-scratch-dir.sh
#   SCRATCH="$(gaia_audit_scratch_dir code-audit-frontend "$BASE_SHA")"
#   gaia_audit_scratch_release code-audit-frontend "$BASE_SHA"
#
# Usage, run directly (what a member definition points at):
#   bash .gaia/scripts/audit-scratch-dir.sh <member> [<base-sha>]
#   bash .gaia/scripts/audit-scratch-dir.sh --release <member> [<base-sha>]

# gaia_audit_scratch_root
# Echoes <main_root>/.gaia/local/cache/mutation-scratch, or nothing when the
# shared main-root resolver (.gaia/scripts/main-root-lib.sh) cannot resolve a
# main checkout. Honors $GAIA_AUDIT_SCRATCH_ROOT when set (test seam).
# Always returns 0.
gaia_audit_scratch_root() {
  if [[ -n "${GAIA_AUDIT_SCRATCH_ROOT:-}" ]]; then
    printf '%s' "$GAIA_AUDIT_SCRATCH_ROOT"
    return 0
  fi
  local script_dir main_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$script_dir/main-root-lib.sh"
  main_root="$(gaia_resolve_main_root)" || return 0
  printf '%s' "$main_root/.gaia/local/cache/mutation-scratch"
  return 0
}

# gaia_audit_scratch_path <member> [<base_sha>] [<dir>]
# Echoes the directory this member owns for this audit, WITHOUT creating it.
# Echoes nothing when <member> is empty or the root is unresolvable.
# Always returns 0.
#
# The member name is run through gaia_key_slug rather than interpolated raw.
# That is not cosmetic: the slug's percent-encoding of every byte outside
# [A-Za-z0-9_-] is what makes a member argument containing `/` or `..`
# incapable of escaping the scratch root, and this function's one caller
# class is an LLM-driven agent passing its own name through.
#
# An unresolvable audit key degrades to the literal `nokey` rather than
# declining outright, which is the one place this file's fail-open rule reads
# differently from the findings sidecar's. The sidecar declines its write
# because a report nobody can find under the expected key is worse than no
# report. A scratch directory has no reader but its own member, so the
# property that actually matters is the member half, and that half is intact
# with or without a key. Two sessions whose key is undeterminable can still
# collide on `nokey.<member>`; that is a strictly smaller population than the
# wave collision this exists to remove, and declining here would put the
# member back to improvising the name.
gaia_audit_scratch_path() {
  local member="${1:-}" base_sha="${2:-}" dir="${3:-.}"
  [[ -n "$member" ]] || return 0
  local root
  root="$(gaia_audit_scratch_root)" || return 0
  [[ -n "$root" ]] || return 0

  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$self_dir/audit-key-lib.sh"

  # Each slug is captured and status-checked instead of being interpolated
  # into the printf: a command substitution discards its own status, so a
  # failing member slug inside the format arguments would still print
  # "<key>." -- a path with the discriminator silently gone, which is the
  # collision this file exists to remove.
  local member_slug
  member_slug="$(gaia_key_slug "$member")" || return 0
  [[ -n "$member_slug" ]] || return 0

  local key
  key="$(gaia_audit_key "$base_sha" "$dir")" || key="nokey"
  # Containment is asserted on the key too, not only on the member name.
  # gaia_audit_key percent-encodes its branch half but interpolates the base
  # sha RAW, and that value is concatenated into a path this file passes to
  # both `mkdir -p` and `rm -rf`. A base carrying a separator therefore
  # escapes exactly as an unslugged member name would: `../../victim` mints
  # and later removes a directory a level above the scratch root. Neutralise
  # it here rather than in the shared key lib, whose `<base>.<slug>` format
  # the findings-sidecar globs depend on. Falling back to the same `nokey`
  # the unresolvable case uses keeps one degraded path instead of two.
  case "$key" in
    '' | */* | *..*) key="nokey" ;;
  esac

  printf '%s' "$root/$key.$member_slug"
  return 0
}

# gaia_audit_scratch_dir <member> [<base_sha>] [<dir>]
# Echoes the member's scratch directory, creating it if it is not already
# there. Echoes nothing (and creates nothing) when the path is unresolvable
# or the directory cannot be created. Always returns 0.
#
# IDEMPOTENT, never destructive, and that is the load-bearing choice. The
# path is deterministic, so an agent that asks a second time is asking "where
# is my directory", not "give me a clean one" -- and an agent runs its shell
# commands in separate invocations, so asking twice is the ordinary case
# rather than the exceptional one. A mint that cleared the directory would
# therefore delete the half-finished mutation tree of the member that asked,
# which is the same silent loss of evidence this file exists to prevent,
# merely self-inflicted instead of inflicted by a sibling.
#
# A member that genuinely wants a fresh baseline releases first and mints
# again. That is two calls rather than one, and it is the right two: the
# destructive step is the one the caller had to name.
gaia_audit_scratch_dir() {
  local path
  path="$(gaia_audit_scratch_path "$@")" || return 0
  [[ -n "$path" ]] || return 0
  mkdir -p -- "$path" 2>/dev/null || return 0
  printf '%s' "$path"
  return 0
}

# gaia_audit_scratch_release <member> [<base_sha>] [<dir>]
# Removes the member's scratch directory. A no-op when the path is
# unresolvable or nothing is there. Always returns 0: a member finishing its
# review must never fail on cleanup.
gaia_audit_scratch_release() {
  local path
  path="$(gaia_audit_scratch_path "$@")" || return 0
  [[ -n "$path" ]] || return 0
  rm -rf -- "$path" 2>/dev/null
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  gaia_scratch_mode=mint
  if [[ "${1:-}" == "--release" ]]; then
    gaia_scratch_mode=release
    shift
  fi

  # Refuse a `--`-prefixed token in ANY remaining position, not just the
  # first. No legitimate member name, base sha, or directory begins with
  # `--`, and every position that accepts one silently absorbs a misplaced
  # flag into a value: `<member> <base> --release` binds --release to <dir>,
  # so gaia_audit_key fails against it, the key degrades to `nokey`, and the
  # command MINTS `nokey.<member>` and exits 0 while the directory the caller
  # asked to release is still there. That is the same silent
  # mint-instead-of-release this guard exists to prevent, reached through a
  # position rather than through a typo.
  for gaia_scratch_arg in "$@"; do
    if [[ "$gaia_scratch_arg" == --* ]]; then
      printf 'audit-scratch-dir: unknown option "%s" (usage: <member> [<base-sha>], or --release <member> [<base-sha>])\n' \
        "$gaia_scratch_arg" >&2
      exit 2
    fi
  done

  # Both modes refuse an empty member name out loud. Releasing nothing is
  # indistinguishable from releasing successfully, so a silent exit 0 here
  # would tell a caller its scratch tree was cleaned up when it was not.
  if [[ -z "${1:-}" ]]; then
    printf 'audit-scratch-dir: %s needs a member name\n' \
      "$([[ "$gaia_scratch_mode" == release ]] && printf -- '--release' || printf 'mint')" >&2
    exit 2
  fi

  if [[ "$gaia_scratch_mode" == release ]]; then
    gaia_audit_scratch_release "$@"
    exit 0
  fi

  # Resolve first, create second, so the two failures report as two failures.
  # An empty return from gaia_audit_scratch_dir means either that no path
  # could be resolved or that the path resolved and `mkdir -p` failed, and
  # those send a caller to opposite places: the first to its checkout, the
  # second to a full disk, a read-only mount, or a stale root-owned directory
  # under the scratch root. One message for both sends every unwritable-root
  # case to look at a checkout that is intact.
  gaia_scratch_path="$(gaia_audit_scratch_path "$@")"
  if [[ -z "$gaia_scratch_path" ]]; then
    printf 'audit-scratch-dir: could not resolve a scratch directory (no main checkout)\n' >&2
    exit 1
  fi
  out="$(gaia_audit_scratch_dir "$@")"
  if [[ -z "$out" ]]; then
    printf 'audit-scratch-dir: resolved %s but could not create it\n' "$gaia_scratch_path" >&2
    exit 1
  fi

  # The mint and the populate fail in different places, and saying so here is
  # the only moment either half is legible. A linked worktree's whole
  # .gaia/local is ONE symlink to the main checkout's (link-worktree.sh), so
  # every path under it resolves out of the acting tree. `mkdir -p` above runs
  # from Bash and succeeds; the caller's next step is an Edit or a Write, and
  # the runtime's own worktree confinement refuses a file_path that leaves the
  # tree. A caller told only the path reads a success and hits a refusal it
  # cannot place, whose stated remedy (edit the worktree copy) does not exist
  # here, and whose most plausible-looking repair is widening a guard that is
  # not the one refusing.
  #
  # Nothing in this repository can make that Write succeed: the refusal is the
  # runtime's, and .claude/hooks/block-worktree-path-mismatch.sh already
  # permits the path -- the registry classifies it `ephemeral`, and that hook
  # exempts every scope but per-tree. So the note names the tool rather than
  # promising a fix. Bash reaches the directory normally, which is what the
  # working copy is taken with in the first place.
  #
  # Advisory: an unresolvable predicate skips the note rather than failing a
  # mint that worked, matching this file's fail-open rule.
  gaia_scratch_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/main-root-lib.sh"
  if [[ -r "$gaia_scratch_lib" ]]; then
    # shellcheck disable=SC1090
    . "$gaia_scratch_lib" 2>/dev/null || true
  fi
  if type gaia_is_linked_worktree >/dev/null 2>&1 && gaia_is_linked_worktree 2>/dev/null; then
    printf 'audit-scratch-dir: populate and mutate %s with Bash (cp, sed -i, redirection).\n' "$out" >&2
    printf 'audit-scratch-dir: Write/Edit into it is refused -- this is a linked worktree, .gaia/local is one symlink to the main checkout, so the path leaves this tree. That confinement is enforced by the runtime, not by a GAIA guard, so there is nothing here to widen.\n' >&2
  fi

  printf '%s\n' "$out"
  exit 0
fi
