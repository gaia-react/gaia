#!/usr/bin/env bash
# GAIA worktree shared-state symlink hook (SPEC-005).
#
# Creates symlinks from the current linked worktree into the main checkout:
# the shared set the state registry declares (.gaia/state-registry.json, read
# via .gaia/scripts/state-registry-lib.sh) plus any gitignored checkout-root
# .env / .env.* files (excluding the committed .env.example), so neither
# diverges per-worktree:
#
#   <worktree>/.gaia/local/<registry-declared shared path> -> <main>/.gaia/local/<same path>
#   <worktree>/.env, <worktree>/.env.*                     -> <main>/.env, <main>/.env.*
#
# Behavior:
#   - Idempotent: re-running on an already-linked worktree is a no-op.
#   - Pre-existing plain files / dirs are moved to <path>.bak.<ts> first.
#   - No-op when invoked from the main checkout (not a linked worktree).
#   - Always exits 0; a broken hook MUST NOT break worktree creation.
#     Failures (e.g. Windows symlink permission errors, an unreadable state
#     registry) log to stderr.
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
# shellcheck disable=SC1091
source "$script_dir/state-registry-lib.sh"

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

# ---------- read the shared set from the state registry ----------
# gaia_registry_linkable_paths is the ONE definition of which .gaia/local/
# paths are shared into main; this hook no longer hand-maintains its own copy.
shared_paths_output="$(gaia_registry_linkable_paths)"
registry_rc=$?

shared_paths=()
if [ "$registry_rc" -eq 0 ]; then
  while IFS= read -r shared_path; do
    [ -n "$shared_path" ] && shared_paths+=("$shared_path")
  done <<<"$shared_paths_output"
else
  log "failed: $worktree_root/.gaia/local: state registry unavailable, no shared paths linked"
fi

# ---------- ensure main-side targets exist (so symlinks don't dangle) ----------
mkdir -p "$main_root/.gaia/local" 2>/dev/null
for shared_path in "${shared_paths[@]}"; do
  # A path containing a dot is the registry's one file entry
  # (setup-state.json): do NOT pre-create it. If it doesn't exist on main,
  # the symlink will dangle until the main checkout writes it via the normal
  # setup flow; that's fine. Readers gracefully treat missing as "no setup
  # state yet". Every other shared path is a directory.
  case "$shared_path" in
    *.*) continue ;;
  esac
  mkdir -p "$main_root/.gaia/local/$shared_path" 2>/dev/null
done

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

# Symlink every registry-declared shared path, in the registry's own stable
# order. parent_rel is ".gaia/local" for a top-level entry (setup-state.json,
# audit, telemetry, debt) and ".gaia/local/<dir>" for a nested one
# (cache/shared).
for shared_path in "${shared_paths[@]}"; do
  parent="$(dirname "$shared_path")"
  if [ "$parent" = "." ]; then
    parent_rel=".gaia/local"
  else
    parent_rel=".gaia/local/$parent"
  fi
  link_one ".gaia/local/$shared_path" "$parent_rel"
done

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
