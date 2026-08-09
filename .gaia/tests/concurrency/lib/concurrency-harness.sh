#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared fixture builder for the INV-7 concurrency meter (see ../README.md).
# Sourced by ../concurrency.bats. Builds a real main checkout plus N real
# linked worktrees off one base, seeds .gaia/local/, copies the real registry
# and whichever hooks/scripts/libs a scenario drives into the fixture at their
# real repo-relative paths (so their own internal `source`/relative-path calls
# resolve exactly as they do in the real repo), and provides the run_in /
# run_with runners plus the suite's one hook-delivery idiom, gaia_deliver_hook.
#
# GAIA_REPO_ROOT_REAL is resolved once from this file's own location:
# lib/ -> concurrency/ -> tests/ -> .gaia/ -> repo root (four levels up).
GAIA_REPO_ROOT_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export GAIA_REPO_ROOT_REAL

# Registered for teardown. Bats-core forks a fresh subshell per @test, so these
# start empty in every test and never leak state across tests.
_GAIA_ROOTS=()
_GAIA_WORKTREES=()

# gaia_mk_tmp <prefix>: mktemp -d, canonicalize via cd + pwd -P (byte-exact
# path comparisons, matching main-root-lib.sh's own physical-resolution
# convention), register for teardown, echo the path.
gaia_mk_tmp() {
  local prefix="$1" raw resolved
  raw="$(mktemp -d -t "${prefix}-XXXXXX")"
  resolved="$(cd "$raw" && pwd -P)"
  _GAIA_ROOTS+=("$resolved")
  printf '%s\n' "$resolved"
}

# gaia_new_main <prefix>: a real main checkout. git init, seeded identity,
# commit.gpgsign false, a .gitignore excluding .gaia/local/ (written BEFORE any
# .gaia/local content exists, so a later gaia_commit_all never accidentally
# tracks per-tree working state), one initial commit, .gaia/local/ seeded.
# Echoes the absolute main root.
gaia_new_main() {
  local prefix="$1" main
  main="$(gaia_mk_tmp "$prefix")"
  git -C "$main" init -q --initial-branch=main
  git -C "$main" config user.email test@example.com
  git -C "$main" config user.name Test
  git -C "$main" config commit.gpgsign false
  printf '.gaia/local/\n' > "$main/.gitignore"
  printf 'init\n' > "$main/README.md"
  git -C "$main" add -A
  git -C "$main" commit -q -m init
  mkdir -p "$main/.gaia/local"
  printf '%s\n' "$main"
}

# gaia_copy_registry <main>: copies the real .gaia/state-registry.json (and its
# schema, when present) into the fixture at the same repo-relative path.
gaia_copy_registry() {
  local main="$1"
  mkdir -p "$main/.gaia"
  cp "$GAIA_REPO_ROOT_REAL/.gaia/state-registry.json" "$main/.gaia/state-registry.json"
  if [ -f "$GAIA_REPO_ROOT_REAL/.gaia/state-registry.schema.json" ]; then
    cp "$GAIA_REPO_ROOT_REAL/.gaia/state-registry.schema.json" "$main/.gaia/state-registry.schema.json"
  fi
}

# gaia_copy_real <main> <relpath> [<relpath> ...]: copies one or more real
# files from the real repo into the fixture at the SAME repo-relative path
# (mkdir -p the parent first), so a copied script's own relative `source` /
# BASH_SOURCE-derived sibling lookups resolve exactly as they do in the real
# repo. Marks a copied *.sh executable.
gaia_copy_real() {
  local main="$1"
  shift
  local rel
  for rel in "$@"; do
    mkdir -p "$main/$(dirname "$rel")"
    cp "$GAIA_REPO_ROOT_REAL/$rel" "$main/$rel"
    case "$rel" in
      *.sh) chmod +x "$main/$rel" ;;
    esac
  done
}

# gaia_link_real <main> <repo-rel-path> [<repo-rel-path> ...]: symlinks one or
# more real directories from the real repo into the fixture at the SAME
# repo-relative path (mkdir -p the parent first, mirroring gaia_copy_real's own
# signature). Reserved for the node helper dirs whose own
# createRequire(import.meta.url) resolves `node_modules` from THEIR OWN
# on-disk location: a gaia_copy_real copy would carry no node_modules of its
# own and fail to resolve `typescript`, but a symlink's realpath lands back in
# the real repo, where `typescript` is actually installed, so the copied hook
# resolves it exactly as it does in production.
gaia_link_real() {
  local main="$1"
  shift
  local rel
  for rel in "$@"; do
    mkdir -p "$main/$(dirname "$rel")"
    ln -s "$GAIA_REPO_ROOT_REAL/$rel" "$main/$rel"
  done
}

# gaia_commit_all <main> <message>: stage and commit everything currently on
# disk in <main> (copied scripts, fixture content). .gaia/local/ is excluded
# by the .gitignore gaia_new_main wrote.
gaia_commit_all() {
  local main="$1" message="$2"
  git -C "$main" add -A
  git -C "$main" commit -q -m "$message"
}

# gaia_add_worktree <main> <name> <branch> [<base-ref>]: a real linked
# worktree at <main>/.claude/worktrees/<name> on a new <branch>, off
# <base-ref> (default: main's current HEAD) -- mirroring how GAIA creates
# plan/debt worktrees. Registers it for teardown removal. Echoes the absolute,
# physically-resolved worktree path.
gaia_add_worktree() {
  local main="$1" name="$2" branch="$3" base="${4:-HEAD}" wt resolved
  wt="$main/.claude/worktrees/$name"
  mkdir -p "$(dirname "$wt")"
  git -C "$main" worktree add -q "$wt" -b "$branch" "$base"
  resolved="$(cd "$wt" && pwd -P)"
  _GAIA_WORKTREES+=("$main"$'\t'"$resolved")
  printf '%s\n' "$resolved"
}

# gaia_link_worktree <worktree>: runs the fixture's own copy of
# link-worktree.sh inside <worktree>. Requires main-root-lib.sh,
# state-registry-lib.sh, and link-worktree.sh already copied (gaia_copy_real)
# and committed (gaia_commit_all) on main before the worktree was added.
gaia_link_worktree() {
  local wt="$1"
  ( cd "$wt" && bash .gaia/scripts/link-worktree.sh ) >/dev/null 2>&1
}

# run_in <dir> [--] <cmd...>: run <cmd...> with <dir> as cwd, in a subshell so
# the caller's own cwd is never disturbed. The `--` separator is optional.
run_in() {
  local dir="$1"
  shift
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  ( cd "$dir" && "$@" )
}

# run_with <VAR=VALUE> [...] -- <cmd...>: run <cmd...> with the given
# environment assignments applied, in a subshell so the caller's own
# environment is never disturbed. The environment analogue of run_in, and the
# `--` separator is REQUIRED here rather than optional, because an assignment
# list is otherwise indistinguishable from the command that follows it.
#
# It exists for one reason: `env` is an external binary and cannot invoke a
# shell function, so a scenario needing both an environment override and
# gaia_deliver_hook below has no way to compose the two without this.
# Every misuse fails with status 64 and runs no command, and the checks are not
# decoration. Under bats' `run` errexit is off, so a bare `shift` on an empty list
# and a `"$@"` that expands to zero words both yield status 0: dropping the `--`
# would eat the command as assignments, never invoke the hook, and leave `status` 0
# with the scenario green. That is the vacuous pass this whole primitive exists to
# prevent, so every arm is enforced rather than merely documented.
#
# On the status: `exit` ends run_with's OWN subshell, so run_with then RETURNS 64 to
# its caller. Under `run` that is captured into `$status`; at an unwrapped call site
# it is bats' own errexit that makes it fatal. `exit` rather than `return` is still
# the right verb, because it cannot be swallowed by the `||` it sits behind.
run_with() {
  (
    # The separator is checked BEFORE anything is exported, by an exact scan
    # rather than a pattern over "$*", so that a missing `--` reports itself
    # instead of surfacing as whichever later word first failed to parse as an
    # assignment, and so that no word is exported on the way to that refusal.
    _rw_found=0
    for _rw_arg in "$@"; do
      if [ "$_rw_arg" = "--" ]; then
        _rw_found=1
        break
      fi
    done
    [ "$_rw_found" -eq 1 ] || { printf 'run_with: missing -- separator\n' >&2; exit 64; }

    while [ "$1" != "--" ]; do
      # A bare name carrying no `=` is the one malformed shape `export` accepts:
      # `export STUBVAR` succeeds and applies nothing, so the command would run
      # with the override silently absent. Refuse it here rather than let it
      # through. This also catches the empty string, which matches no `*=*`.
      case "$1" in
        *=*) ;;
        *) printf 'run_with: not an assignment: %s\n' "$1" >&2; exit 64 ;;
      esac
      # `${1?}` rather than a bare `$1` is shellcheck's own documented way to
      # quiet SC2163 on a deliberate export-by-word. It asserts nothing here:
      # the `case` above is what validates, and `|| exit 64` is what catches an
      # export that still fails (a value-carrying but invalid name, `1FOO=x`).
      export "${1?}" || exit 64
      shift
    done
    shift
    [ "$#" -gt 0 ] || { printf 'run_with: no command after --\n' >&2; exit 64; }
    "$@"
  )
}

# gaia_deliver_hook <payload> <hook>: deliver <payload> on stdin to <hook>.
# This is the ONE hook-invocation idiom for this suite; reach for it rather
# than hand-rolling a delivery, and compose it with whichever runner the
# scenario needs. It calls neither bats' `run` nor `cd` itself, so the caller
# supplies that:
#
#   run gaia_deliver_hook "$json" "$hook"                    status + output
#   run run_in "$B" -- gaia_deliver_hook "$json" "$hook"     ... from a tree
#   run run_with HOME="$h" -- gaia_deliver_hook "$json" "$hook"   ... with env
#   out="$(run_in "$B" -- gaia_deliver_hook "$json" "$hook")"     stdout alone
#   run_in "$B" -- gaia_deliver_hook "$json" "$hook" >/dev/null   side effect
#
# WHY THE PAYLOAD IS POSITIONAL, which is not a style preference. The payload
# and the hook path are ARGUMENTS to the inner `bash -c`, never interpolated
# into its script. A payload spliced into a quoted string terminates that
# string early the moment a fixture carries a quote of its own, and the hook
# then reads a DIFFERENT payload than the one the fixture spells: it denies for
# the wrong reason, or never parses the payload at all, and the scenario greens
# having proved nothing about the property it is named for. This suite is the
# hardest place to notice that, because its assertions are about WHICH TREE a
# guard attributes a write to rather than about payload text.
#
# THE TWIN, deliberately not shared. .gaia/tests/hooks/helpers/run-hook.sh's
# `invoke_hook` is the same one-line idiom for the .gaia/tests/hooks/ suites.
# It calls `run` itself, which those suites want and this one cannot use: only
# one scenario here invokes a hook with no runner wrapped around it, while the
# rest need run_in, run_with, a `$( )` capture, or no capture at all. Two
# implementations of one line is the accepted cost of two harnesses with
# different composition needs; keep them in step by name.
gaia_deliver_hook() {
  bash -c 'printf %s "$1" | bash "$2"' _ "$1" "$2"
}

# gaia_teardown: remove every registered worktree (force, best-effort), then
# rm -rf every registered tmp root (which, for a worktree nested under
# <main>/.claude/worktrees/, also removes the worktree's own files -- the
# explicit `worktree remove` first is belt-and-braces so a leftover
# .git/worktrees/ registration in an already-deleted checkout is never left
# dangling). Always returns 0 so a bats teardown() built on this never fails
# the run over cleanup.
gaia_teardown() {
  local entry main wt
  if [ "${#_GAIA_WORKTREES[@]}" -gt 0 ]; then
    for entry in "${_GAIA_WORKTREES[@]}"; do
      main="${entry%%$'\t'*}"
      wt="${entry#*$'\t'}"
      git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || true
    done
  fi
  _GAIA_WORKTREES=()

  local root
  if [ "${#_GAIA_ROOTS[@]}" -gt 0 ]; then
    for root in "${_GAIA_ROOTS[@]}"; do
      rm -rf "$root"
    done
  fi
  _GAIA_ROOTS=()

  return 0
}
