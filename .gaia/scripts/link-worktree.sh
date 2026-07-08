#!/usr/bin/env bash
# GAIA worktree shared-state symlink hook (SPEC-005).
#
# Creates symlinks from the current linked worktree into the main checkout:
# the six fixed .gaia/local/ shared-state paths (setup-state.json,
# mentorship.json, cache/, audit/, telemetry/, debt/) plus any gitignored
# checkout-root .env / .env.* files (excluding the committed .env.example),
# so neither diverges per-worktree:
#
#   <worktree>/.gaia/local/setup-state.json -> <main>/.gaia/local/setup-state.json
#   <worktree>/.gaia/local/mentorship.json  -> <main>/.gaia/local/mentorship.json
#   <worktree>/.gaia/local/cache/shared/      -> <main>/.gaia/local/cache/shared/
#   <worktree>/.gaia/local/audit/            -> <main>/.gaia/local/audit/
#   <worktree>/.gaia/local/telemetry/        -> <main>/.gaia/local/telemetry/
#   <worktree>/.gaia/local/debt/             -> <main>/.gaia/local/debt/
#   <worktree>/.env, <worktree>/.env.*       -> <main>/.env, <main>/.env.*
#
# Behavior:
#   - Idempotent: re-running on an already-linked worktree is a no-op.
#   - Pre-existing plain files / dirs are moved to <path>.bak.<ts> first.
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

# ---------- detect worktree vs main checkout ----------
common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -z "$common_dir" ]; then
  log "not a git repo"
  exit 0
fi

case "$common_dir" in
  /*) absolute_common_dir="$common_dir" ;;
  *)  absolute_common_dir="$(pwd)/$common_dir" ;;
esac

main_root="$(cd "$(dirname "$absolute_common_dir")" 2>/dev/null && pwd)"
current_root="$(git rev-parse --show-toplevel 2>/dev/null)"

if [ -z "$main_root" ] || [ -z "$current_root" ]; then
  log "not a git repo"
  exit 0
fi

if [ "$main_root" = "$current_root" ]; then
  log "not a linked worktree"
  exit 0
fi

worktree_root="$current_root"
ts="$(date +%Y%m%d-%H%M%S)"

# ---------- ensure main-side targets exist (so symlinks don't dangle) ----------
mkdir -p "$main_root/.gaia/local" 2>/dev/null
mkdir -p "$main_root/.gaia/local/audit" 2>/dev/null
mkdir -p "$main_root/.gaia/local/telemetry" 2>/dev/null
mkdir -p "$main_root/.gaia/local/cache/shared" 2>/dev/null
mkdir -p "$main_root/.gaia/local/debt" 2>/dev/null
# `setup-state.json` and `mentorship.json` are files: do NOT pre-create them.
# If one doesn't exist on main, the symlink will dangle until the main checkout
# writes it via the normal setup flow; that's fine. Readers gracefully treat
# missing as "no setup state / no mentorship decision yet".

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

link_one ".gaia/local/setup-state.json" ".gaia/local"
link_one ".gaia/local/mentorship.json"  ".gaia/local"
link_one ".gaia/local/cache/shared"     ".gaia/local/cache"
link_one ".gaia/local/audit"            ".gaia/local"
link_one ".gaia/local/telemetry"        ".gaia/local"
link_one ".gaia/local/debt"             ".gaia/local"

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
