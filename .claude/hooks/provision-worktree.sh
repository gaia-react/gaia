#!/usr/bin/env bash
# Provision the linked worktree a session is working in: re-link the shared
# state the registry declares, and regenerate the typed routes the worktree's
# own branch needs.
#
# Provisioning is a property a worktree must HOLD, not an event that happened
# once when it was created. A worktree whose symlinks were broken by hand, one
# made with plain `git worktree add` outside GAIA's own machinery, and one made
# before a newly-shared registry entry existed are all under-provisioned in the
# same way, and none of them is fixed by anything that runs at creation time.
# So this runs on entry instead, is idempotent, and repairs whatever it finds.
#
# Two triggers, because one entry path does not cover the other and each was
# measured rather than assumed:
#
#   SessionStart (startup|resume)   a session that STARTS inside a worktree,
#                                   including `claude --worktree` and any tree
#                                   opened directly.
#   PostToolUse  (EnterWorktree)    a RUNNING session that enters one. Entering
#                                   a worktree continues the session rather than
#                                   starting a new one, so SessionStart does not
#                                   fire for it, and this repository's own
#                                   instructions make EnterWorktree the way to
#                                   resume worktree work -- the common path, not
#                                   the exotic one. The PostToolUse payload is
#                                   emitted after the switch: its `cwd` is
#                                   already the worktree and its tool_response
#                                   names the path outright.
#
# Also callable directly with the worktree path as an argument, which is how
# worktree creation provisions the tree it just made without synthesizing a
# hook payload. One definition, three callers.
#
# Always exits 0. Provisioning repairs a worktree; failing to provision must
# never block the session that asked for one.
#
# DO NOT add `set -e`: the link step and the typegen step are independent and
# one failing must not skip the other.

log() {
  printf 'provision-worktree: %s\n' "$1" >&2
}

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# shellcheck disable=SC1091
source "$self_dir/../../.gaia/scripts/main-root-lib.sh" 2>/dev/null || exit 0

# ---------- which tree ----------
# An explicit argument wins (the direct-call form). Otherwise read the hook
# payload: tool_response.worktreePath is EnterWorktree's own statement of the
# tree it just switched into, and `cwd` is the payload-anchored identity every
# other hook in this repository uses. The process cwd is the last fallback.
tree="${1:-}"
if [ -z "$tree" ] && [ ! -t 0 ]; then
  payload="$(cat)"
  if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    tree="$(jq -r '.tool_response.worktreePath // .cwd // empty' <<<"$payload" 2>/dev/null)"
  fi
fi
[ -n "$tree" ] || tree="$PWD"

# An absolute path is required before this value reaches `cd`, which would
# option-parse a leading dash and succeed into the wrong directory.
case "$tree" in
  /*) ;;
  *) exit 0 ;;
esac
[ -d "$tree" ] || exit 0

# ---------- carry forward per-tree ledger/report data under the tree key ----------
# Four .gaia/local segments moved one path segment deeper, keyed by this
# tree's own gaia_tree_key, so multiple trees stop shadowing each other's
# data at one shared unkeyed path: red-ledger/observations.jsonl,
# worthiness-ledger/worthiness.jsonl, forensics/<file>, handoff/<file>.
# Every reader looks at the keyed path only -- this is the one place that
# migrates the old data, so anything left behind here is gone from its own
# reader's point of view.
#
# Runs for EVERY tree, main included, and runs BEFORE the linked-worktree
# gate below on purpose. The move shadows main's own unkeyed data exactly
# the way it shadows a worktree's, and nothing else runs at main's session
# start to rescue it. The gate below is unchanged by this: only the re-link
# and typegen steps after it stay worktree-only.

# carry_forward_file <dir> <file>: moves the one old unkeyed file at
# .gaia/local/<dir>/<file> to .gaia/local/<dir>/<tree_key>/<file>, only when
# the old file exists and the keyed file does not, so a second run, or a
# keyed file a live session already wrote, is left untouched and unkeyed
# content never overwrites keyed content. Nothing to move is a silent
# no-op; a tree key that could not be resolved, or a move that fails, is
# not -- a stranded red-ledger or worthiness-ledger file is exactly the
# condition that silently blocks the next commit gate, so both are logged
# loudly enough to act on.
carry_forward_file() {
  local dir="$1"
  local file="$2"
  local old="$tree/.gaia/local/$dir/$file"
  [ -f "$old" ] || return 0
  if [ -z "$tree_key" ]; then
    log "CARRY-FORWARD FAILED: $dir/$file has no resolvable tree key for $tree -- move it to $dir/<tree-key>/$file by hand, or a stranded ledger will silently block the next commit gate"
    return 0
  fi
  local new="$tree/.gaia/local/$dir/$tree_key/$file"
  [ -e "$new" ] && return 0
  if mkdir -p "$tree/.gaia/local/$dir/$tree_key" 2>/dev/null && mv "$old" "$new" 2>/dev/null; then
    log "carried forward $dir/$file -> $dir/$tree_key/$file"
  else
    log "CARRY-FORWARD FAILED: $dir/$file -> $dir/$tree_key/$file -- move it by hand, or a stranded ledger will silently block the next commit gate"
  fi
}

# carry_forward_dir_contents <dir>: the forensics/ and handoff/ shape --
# any number of loosely-named files sitting directly in the old unkeyed
# directory, never a subdirectory (which is how an already-migrated keyed
# subdir is left alone). Same existence and never-overwrite rules as
# carry_forward_file, applied file by file.
carry_forward_dir_contents() {
  local dir="$1"
  local old_dir="$tree/.gaia/local/$dir"
  [ -d "$old_dir" ] || return 0
  local f base new
  while IFS= read -r f; do
    base="$(basename "$f")"
    if [ -z "$tree_key" ]; then
      log "CARRY-FORWARD FAILED: $dir/$base has no resolvable tree key for $tree -- move it to $dir/<tree-key>/$base by hand, or a stranded ledger will silently block the next commit gate"
      continue
    fi
    new="$tree/.gaia/local/$dir/$tree_key/$base"
    [ -e "$new" ] && continue
    if mkdir -p "$tree/.gaia/local/$dir/$tree_key" 2>/dev/null && mv "$f" "$new" 2>/dev/null; then
      log "carried forward $dir/$base -> $dir/$tree_key/$base"
    else
      log "CARRY-FORWARD FAILED: $dir/$base -> $dir/$tree_key/$base -- move it by hand, or a stranded ledger will silently block the next commit gate"
    fi
  done < <(find "$old_dir" -maxdepth 1 -type f 2>/dev/null)
}

# migrate_keyed_subtrees_to_main: the second half of the same migration, and
# the one the cutover itself forces.
#
# A linked worktree still holding a REAL .gaia/local is a tree that predates
# the single-symlink cutover. The linker's next act is to move that whole
# directory aside to .gaia/local.bak.<ts> and put one symlink in its place,
# and its contract is explicit that nothing under the backup is inspected or
# merged. So without this step the four per-tree entries -- including the ones
# the carry-forward above has just keyed correctly -- end up inside a backup
# nobody reads. A stranded RED observation is not a missing file: it silently
# BLOCKS a commit the gate should pass, which is precisely the failure the
# cutover's back-off condition names.
#
# So the keyed subtree moves to main's .gaia/local before the linker runs.
# It is safe to move rather than merge: the destination is keyed by THIS
# tree's key, so it cannot collide with the main checkout's own data or with
# any peer worktree's. A destination that already exists is left alone and
# said out loud rather than merged -- two sources for one tree's ledger is a
# state to be told about, not one to resolve by guessing.
#
# Self-retiring, exactly like the carry-forward above: the moment the linker
# has run once, .gaia/local is a symlink and the whole block is skipped.
migrate_keyed_subtrees_to_main() {
  [ -n "$tree_key" ] || return 0
  gaia_is_linked_worktree "$tree" || return 0

  local main_root
  main_root="$(gaia_resolve_main_root "$tree" 2>/dev/null)" || return 0
  [ -n "$main_root" ] || return 0
  [ "$main_root" = "$tree" ] && return 0

  local dir src dest
  for dir in red-ledger worthiness-ledger forensics handoff; do
    src="$tree/.gaia/local/$dir/$tree_key"
    [ -d "$src" ] || continue
    dest="$main_root/.gaia/local/$dir/$tree_key"
    if [ -e "$dest" ]; then
      log "CUTOVER MIGRATION SKIPPED: $dir/$tree_key exists in both this worktree and the main checkout -- merge them by hand; the worktree's copy is about to be moved aside to .gaia/local.bak.* and nothing reads it there"
      continue
    fi
    if mkdir -p "$main_root/.gaia/local/$dir" 2>/dev/null && mv "$src" "$dest" 2>/dev/null; then
      log "migrated $dir/$tree_key into the main checkout's .gaia/local"
    else
      log "CUTOVER MIGRATION FAILED: $dir/$tree_key -- move it into the main checkout's .gaia/local/$dir/ by hand, or a stranded ledger will silently block the next commit gate"
    fi
  done
}

# Skipped outright when .gaia/local is itself a symlink. Once the single-symlink
# cutover has run for this tree, the "old unkeyed path" a worktree sees through
# that symlink IS main's own data, and moving it under the WORKTREE's own key
# would steal main's ledger out from under it. Gating on the symlink keeps both
# steps correct on either side of the cutover, without this hook needing to know
# which state it is in.
if [ ! -L "$tree/.gaia/local" ]; then
  tree_key="$(gaia_tree_key "$tree" 2>/dev/null)" || tree_key=""
  carry_forward_file "red-ledger" "observations.jsonl"
  carry_forward_file "worthiness-ledger" "worthiness.jsonl"
  carry_forward_dir_contents "forensics"
  carry_forward_dir_contents "handoff"
  migrate_keyed_subtrees_to_main
fi

# ---------- only a linked worktree is provisioned ----------
# gaia_is_linked_worktree is the one predicate for this question, so the main
# checkout costs a single resolver call and nothing else. It answers "no" for
# an indeterminate tree too, which is the right direction here: provisioning a
# tree whose identity is unknown could write symlinks into a checkout that
# owns its own state.
gaia_is_linked_worktree "$tree" || exit 0

# ---------- re-link the shared state ----------
# link-worktree.sh reads the shared set from the state registry and is
# idempotent per path, so a correct worktree is a no-op and a broken one is
# repaired. It derives the tree it acts on from its own process cwd, so it is
# invoked with cwd at the worktree, in a subshell that cannot disturb ours.
linker="$tree/.gaia/scripts/link-worktree.sh"
if [ -f "$linker" ]; then
  if (cd "$tree" && bash "$linker") 2>/dev/null; then
    log "linked shared state in $tree"
  else
    log "link step failed (non-fatal) for $tree"
  fi
else
  log "no linker found at $linker"
fi

# ---------- regenerate the typed routes ----------
# `.react-router/types` is gitignored, so it exists only where it was generated
# and a worktree never receives it. Without it every app file importing
# `./+types/*` resolves to `error` typed values and a lint run inside the
# worktree reports unsafe-assignment errors against code its branch never
# touched.
#
# Generate rather than share main's copy: the types derive from the worktree's
# OWN route files, so main's would hand a branch that adds or renames a route a
# silently wrong answer in place of a loud one. Regenerating on every entry is
# what keeps them current rather than merely present, which is the property a
# create-time run cannot hold once the branch moves.
#
# Borrow the main checkout's installed CLI rather than installing into the
# worktree: the worktree sits under that root, so Node's upward node_modules
# traversal resolves both the CLI and the app's imports from there. A checkout
# with nothing installed has no CLI to borrow, which is nothing to do rather
# than a failure worth reporting.
main_root="$(gaia_resolve_main_root "$tree" 2>/dev/null)" || main_root=""
if [ -n "$main_root" ]; then
  cli="$main_root/node_modules/.bin/react-router"
  if [ -x "$cli" ]; then
    if (cd "$tree" && "$cli" typegen) >/dev/null; then
      log "generated typed routes in $tree"
    else
      log "typegen skipped (non-fatal) for $tree"
    fi
  fi
fi

exit 0
