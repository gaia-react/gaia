#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared fixture builder for the INV-7 concurrency meter (see ../README.md).
# Sourced by ../concurrency.bats. Builds a real main checkout plus N real
# linked worktrees off one base, seeds .gaia/local/, copies the real registry
# and whichever hooks/scripts/libs a scenario drives into the fixture at their
# real repo-relative paths (so their own internal `source`/relative-path calls
# resolve exactly as they do in the real repo), and provides a run_in helper.
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
