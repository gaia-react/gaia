#!/usr/bin/env bash
# GAIA worktree shared-state symlink hook (SPEC-005).
#
# A linked worktree's whole .gaia/local is ONE symlink to the main checkout's
# own .gaia/local, so nothing under it diverges per-worktree: the registry's
# per-tree entries (red-ledger/, worthiness-ledger/, forensics/, handoff/)
# address themselves under a subdirectory keyed by gaia_tree_key
# (.gaia/scripts/main-root-lib.sh) so they stay private to the tree that
# wrote them even though the physical directory is now shared. Also symlinks
# any gitignored checkout-root .env / .env.* files (excluding the committed
# .env.example), so neither diverges per-worktree either:
#
#   <worktree>/.gaia/local -> <main>/.gaia/local
#   <worktree>/.env, <worktree>/.env.* -> <main>/.env, <main>/.env.*
#
# Behavior:
#   - Idempotent: re-running on an already-linked worktree is a no-op.
#   - A pre-existing plain .gaia/local (file or directory) is moved to
#     .gaia/local.bak.<ts> first; nothing under it is inspected or merged.
#   - No-op when invoked from the main checkout (not a linked worktree).
#   - Always exits 0; a broken hook MUST NOT break worktree creation.
#     Failures (e.g. Windows symlink permission errors) log to stderr.
#
# DO NOT add `set -e`; each path is independent and one failure must not
# abort the rest of the operations.

# Frozen log labels (consumed by the CLI subcommand parser):
#   linked: <abs-path>
#   already-linked: <abs-path>
#   linked-after-backup: <abs-path> (backup: <abs-backup-path>)
#   skipped-no-target: <abs-path>
#   failed: <abs-path>: <reason>
#   not a linked worktree
#   not a git repo

log() {
  printf '%s\n' "$1" >&2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/main-root-lib.sh"

# ---------- detect worktree vs main checkout ----------
# gaia_resolve_main_root is the one canonical main-root derivation; this hook
# no longer re-derives it from git-common-dir by hand.
main_root="$(gaia_resolve_main_root)" || {
  log "not a git repo"
  exit 0
}

current_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$current_root" ]; then
  log "not a git repo"
  exit 0
fi

if [ "$main_root" = "$current_root" ]; then
  log "not a linked worktree"
  exit 0
fi

worktree_root="$current_root"
ts="$(date +%Y%m%d-%H%M%S)"

# ---------- ensure the main-side target exists (so the symlink doesn't dangle) ----------
mkdir -p "$main_root/.gaia/local" 2>/dev/null

# ---------- helper: link one path ----------
# $1 - relative path (e.g. ".gaia/local/setup-state.json")
# $2 - parent dir on the worktree side that must exist (e.g. ".gaia/local")
link_one() {
  rel="$1"
  parent_rel="$2"
  src="$worktree_root/$rel"
  target="$main_root/$rel"

  # Ensure the worktree-side parent exists for the symlink we're about to
  # create. (`.gaia/local/` and `.gaia/` may not exist on a fresh worktree.)
  mkdir -p "$worktree_root/$parent_rel" 2>/dev/null

  # Already a symlink?
  if [ -L "$src" ]; then
    existing="$(readlink "$src" 2>/dev/null)"
    if [ "$existing" = "$target" ]; then
      log "already-linked: $src"
      return 0
    fi
    # Wrong target; back up the broken/incorrect symlink.
    backup="$src.bak.$ts"
    if mv "$src" "$backup" 2>/dev/null; then
      if ln -s "$target" "$src" 2>/dev/null; then
        log "linked-after-backup: $src (backup: $backup)"
      else
        log "failed: $src: ln -s after backup failed"
      fi
    else
      log "failed: $src: mv to backup failed"
    fi
    return 0
  fi

  # Plain file / directory present?
  if [ -e "$src" ]; then
    backup="$src.bak.$ts"
    if mv "$src" "$backup" 2>/dev/null; then
      if ln -s "$target" "$src" 2>/dev/null; then
        log "linked-after-backup: $src (backup: $backup)"
      else
        log "failed: $src: ln -s after backup failed"
      fi
    else
      log "failed: $src: mv to backup failed"
    fi
    return 0
  fi

  # Missing: create the symlink.
  if ln -s "$target" "$src" 2>/dev/null; then
    log "linked: $src"
  else
    log "failed: $src: ln -s failed (symlink permission?)"
  fi
}

# The one shared path: .gaia/local itself. parent_rel is ".gaia" (the parent
# directory that must exist on the worktree side before the symlink lands).
link_one ".gaia/local" ".gaia"

# ---------- share gitignored root .env / .env.* files ----------
# Vite (`pnpm dev`) and Playwright's dotenv `config()` read .env / .env.* from
# the checkout root. They are gitignored, so a fresh worktree has none; symlink
# whatever the main checkout holds so the worktree app sees the same secrets.
# .env.example is committed (already present in the worktree) and is never linked.
link_env_files() {
  local f base
  local re='^\.env(\.[A-Za-z0-9_-]+)*$'
  for f in "$main_root"/.env "$main_root"/.env.*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = ".env.example" ] && continue
    [[ "$base" =~ $re ]] || continue   # identical set to CLI ENV_BASENAME_RE + read guard
    link_one "$base" "."
  done
}

link_env_files

exit 0
